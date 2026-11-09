%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_sup).
-moduledoc """
The stack's supervisors (docs/design-network-stack.md, "The process tree"), one module for
its three levels:

```text
erx_net_sup  (rest_for_one)
 |- erx_net_tables
 |- interfaces  (one_for_one)
 |   |- link supervisor per interface  (rest_for_one)
 |       |- erx_net_driver over its transport
 |       |- erx_net_if
 |       |- erx_dhcp4, when the interface is configured for DHCP
 |- erx_net_grant, the node's grant `local`, started through the runtime
```

`erx_net_tables` comes first, so that its crash restarts everything that wrote into its
tables. The grant comes last, so its restart, which ends the connections linked to it,
leaves the interfaces running.

A link is started by `start_link_sup/1` alone, at the stack's start and at every restart:
its driver first, then, once the driver runs, its interface and DHCP client. A driver whose
transport has nothing to drive answers `ignore`, and so does its link, so the stack runs
without that interface and no interface ever starts without its driver. The driver is the
link's significant child: its end, for any reason, ends the link (`auto_shutdown`), and the
interfaces supervisor starts the link again through `start_link_sup/1`, which resets the
device and restarts the interface and its DHCP client, which lose only soft state. An
interface's or DHCP client's crash is the link supervisor's to restart, and leaves the driver
running.
Listeners, datagram sockets under a grant and the port mapper join the tree as they are
written.

The configuration, a map: `interfaces`, a list of `#{name, transport := {Module, Config},
ip4, ingress}`; `clock` (`monotonic` when absent); `runtime`, the runtime seam's module
(`erx_net_local` when absent). The clock and the runtime are chosen before any process
starts; a module the build does not hold stops the start with `{error, {seam, Key,
Module}}`.
""".

-behaviour(supervisor).

-export([start_link/1, runtime/0]).
-export([init/1, start_link_sup/1]).

-define(RUNTIME, {?MODULE, runtime}).

-type interface() :: #{name := term(), transport := {module(), map()},
                       ip4 := dhcp | map(), ingress => map()}.

-doc "Chooses the seams and starts the stack with its interfaces.".
-spec start_link(#{interfaces := [interface()], clock => erx_net_clock:source(),
                   runtime => module()}) -> {ok, pid()} | {error, term()}.
start_link(#{interfaces := Interfaces} = Config) ->
    Runtime = maps:get(runtime, Config, erx_net_local),
    maybe
        ok ?= erx_net_clock:select(maps:get(clock, Config, monotonic)),
        {module, Runtime} ?= code:ensure_loaded(Runtime),
        ok = persistent_term:put(?RUNTIME, Runtime),
        supervisor:start_link(?MODULE, {stack, Interfaces})
    else
        {error, {seam, _, _}} = Seam -> Seam;
        {error, {clock, _}} = Clock -> Clock;
        {error, _} -> {error, {seam, runtime, Runtime}}
    end.

-doc "The runtime seam's module this node's stack runs on.".
-spec runtime() -> module().
runtime() ->
    persistent_term:get(?RUNTIME).

-doc false.
init({stack, Interfaces}) ->
    Children = [#{id => erx_net_tables, start => {erx_net_tables, start_link, []}},
                #{id => interfaces, type => supervisor,
                  start => {supervisor, start_link, [?MODULE, {interfaces, Interfaces}]}},
                #{id => grant, start => {runtime(), start_grant, [local, #{}]}}],
    {ok, {#{strategy => rest_for_one}, Children}};
init({interfaces, Interfaces}) ->
    Children = [#{id => Name, type => supervisor, start => {?MODULE, start_link_sup, [If]}}
                || #{name := Name} = If <- Interfaces],
    {ok, {#{strategy => one_for_one}, Children}};
init({link, #{name := Name, transport := {Transport, TransportConfig}}}) ->
    Driver = #{id => driver, start => {erx_net_driver, start_link, [Name, Transport, TransportConfig]},
               restart => temporary, significant => true},
    {ok, {#{strategy => rest_for_one, auto_shutdown => any_significant}, [Driver]}}.

-doc """
Starts one interface's link supervisor with its driver, then, once the driver runs, the
interface and its DHCP client after it, in the `rest_for_one` order of the design. A
driver that answered `ignore` is no child, which leaves nothing to run, and the link
answers `ignore`.
""".
-spec start_link_sup(interface()) -> {ok, pid()} | ignore | {error, term()}.
start_link_sup(#{name := Name, ip4 := Ip4} = If) ->
    IfConfig = maps:with([ip4, ingress], If),
    Rest = [#{id => interface, start => {erx_net_if, start_link, [Name, IfConfig]}}
            | [#{id => erx_dhcp4, start => {erx_dhcp4, start_link, [Name]}} || Ip4 =:= dhcp]],
    maybe
        {ok, Sup} ?= supervisor:start_link(?MODULE, {link, If}),
        case supervisor:which_children(Sup) of
            [{driver, Driver, worker, _}] when is_pid(Driver) -> start_children(Sup, Rest);
            [] -> stop_link(Sup, ignore)
        end
    end.

%% The link's children after its driver, in order; one that fails ends the link, and its
%% reason is the link's.
start_children(Sup, []) ->
    {ok, Sup};
start_children(Sup, [Child | Rest]) ->
    case supervisor:start_child(Sup, Child) of
        {ok, _Pid} -> start_children(Sup, Rest);
        {error, _Reason} = Error -> stop_link(Sup, Error)
    end.

%% Ends a link supervisor the caller, its parent, has not taken as a child, unlinked first
%% so that its end reaches the parent as no exit signal, and answers Answer.
stop_link(Sup, Answer) ->
    unlink(Sup),
    ok = proc_lib:stop(Sup),
    Answer.
