%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_sup).
-moduledoc """
The stack's supervisors (docs/design-network-stack.md, "The process tree"), one module for
its three levels:

```text
erx_net_sup  (one_for_one, intensity 0)
 |- erx_net_tables
 |- erx_net_grants  (simple_one_for_one): the minted grants, temporary
 |- erx_net_interfaces  (one_for_one)
 |   |- link supervisor per interface, its id the interface's name  (rest_for_one)
 |       |- erx_net_driver over its transport
 |       |- erx_net_if
 |       |- erx_dhcp4, when the interface is configured for DHCP
 |- the runtime's children (erx_net_runtime:children/0): the node's grant `local`, and
    on erXos the mints of `net` and `network_ctl`
```

Every child of `erx_net_sup` is permanent and none is restarted: the end of any of them,
the interfaces supervisor giving up included, ends the stack and every grant with it.
Where the application is permanent, as in the network domain, the domain ends with it,
and the domain service's restart grants every client anew; where it is temporary, as in
the system domain, the node runs on without a stack. A restart at the top
would leave the minted grants dead, since they are temporary and not made again, and a
restarted mint would name itself after the domain's ready report, which no report
carries. The supervisors
are registered, `erx_net_grants` for erx_net:mint_grant/4 and `erx_net_interfaces` for the
driver-control facet, whose units name a link by its interface (erx_net_erxos).

Ordinary failures stay below the top. A link supervisor is a permanent child of
`erx_net_interfaces` under its interface's name, so a link restarts there, and a stop
through the driver-control facet (supervisor:terminate_child/2) keeps its place for the
start that builds it again (supervisor:restart_child/2).

A link is started by `start_link_sup/1` alone, at the stack's start and at every restart:
its driver first, then, once the driver runs, its interface and DHCP client. A driver whose
transport has nothing to drive answers `ignore`, and so does its link, so the stack runs
without that interface and no interface ever starts without its driver. The driver is the
link's significant child: its end, for any reason, ends the link (`auto_shutdown`), and the
interfaces supervisor starts the link again through `start_link_sup/1`, which resets the
device and restarts the interface and its DHCP client, which lose only soft state. An
interface's or DHCP client's crash is the link supervisor's to restart, and leaves the
driver running.

A driver lives a second at the least (erx_net_driver, "The hold"), so a link whose medium
fails at every start restarts once a second, and the interfaces supervisor's intensity is
what its links can reach that way, `erx_net_driver:starts_within/1` for each over its
period: a dead device or far end never makes it give up. What ends a link faster adds to
the count, and once the interfaces supervisor gives up, the stack ends: a transport whose
`init` fails at a restart, or an interface or DHCP client crashing past the link's own
intensity.

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
-define(LINKS_PERIOD_S, 5).

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
                #{id => erx_net_grants, type => supervisor,
                  start => {supervisor, start_link, [{local, erx_net_grants}, ?MODULE, grants]}},
                #{id => erx_net_interfaces, type => supervisor,
                  start => {supervisor, start_link, [{local, erx_net_interfaces}, ?MODULE,
                                                     {interfaces, Interfaces}]}}
                | [#{id => Id, start => Start, restart => permanent}
                   || {Id, Start} <- (runtime()):children()]],
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, Children}};
init(grants) ->
    Grant = #{id => grant, start => {runtime(), start_grant, []}, restart => temporary},
    {ok, {#{strategy => simple_one_for_one}, [Grant]}};
init({interfaces, Interfaces}) ->
    Children = [#{id => Name, type => supervisor, start => {?MODULE, start_link_sup, [If]},
                  restart => permanent}
                || #{name := Name} = If <- Interfaces],
    Intensity = length(Interfaces) * erx_net_driver:starts_within(?LINKS_PERIOD_S),
    {ok, {#{strategy => one_for_one, intensity => Intensity, period => ?LINKS_PERIOD_S},
          Children}};
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
            [{driver, Driver, worker, _}] when is_pid(Driver) -> start_children(Sup, Driver, Rest);
            [] -> stop_link(Sup, ignore)
        end
    end.

%% The link's children after its driver, in order; one that fails ends the link, and its
%% reason is the link's. A child that failed because the driver ended under it, a driver
%% crashing in its first second, leaves a link that is ending already: it is answered as
%% started, and its parent restarts it as any link whose driver ended, so that a driver's
%% end never fails a link's start, the stack's own start included.
start_children(Sup, _Driver, []) ->
    {ok, Sup};
start_children(Sup, Driver, [Child | Rest]) ->
    case start_child(Sup, Child) of
        {ok, _Pid} ->
            start_children(Sup, Driver, Rest);
        %% The driver is the link supervisor's significant child, so with the driver gone
        %% the supervisor is ending or has ended, which is why its child failed or its
        %% call did; its parent sees it end.
        {error, _Reason} = Error ->
            case is_process_alive(Driver) of
                true -> stop_link(Sup, Error);
                false -> {ok, Sup}
            end
    end.

%% supervisor:start_child/2, with a supervisor that ended under the call, after its driver,
%% answered as an error rather than raised.
start_child(Sup, Child) ->
    try supervisor:start_child(Sup, Child)
    catch exit:Reason -> {error, Reason}
    end.

%% Ends a link supervisor the caller, its parent, has not taken as a child, unlinked first
%% so that its end reaches the parent as no exit signal, and answers Answer.
stop_link(Sup, Answer) ->
    unlink(Sup),
    ok = proc_lib:stop(Sup),
    Answer.
