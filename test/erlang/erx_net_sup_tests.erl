%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the stack's tree and its failure policy (docs/design-network-stack.md,
%% "The process tree"): the end of any child of erx_net_sup ends the stack, which restarts
%% none; a link's end stays under erx_net_interfaces, which starts the link again, and a
%% minted grant outlives it; and network_ctl's controlled object, erx_net_erxos's units
%% map acted on through erx_driver_ctl, is a link that a stop leaves stopped and a start
%% builds again, with the grant intact.
%%
%% This module is also the stack's runtime in these cases: it starts a grant for any
%% grantee, which erx_net_local refuses, so that a minted grant exists outside erXos, and
%% takes its own children from erx_net_local. It is the export table's stand-in too, and
%% a minted grant's connection is a port of the test's own (mint/0).
-module(erx_net_sup_tests).

-include_lib("eunit/include/eunit.hrl").

-behaviour(erx_net_runtime).

-export([serve/1, start_grant/2, children/0, export/3]).

-define(FAR, erx_net_sup_tests_far).
-define(GRANTEE, 7).
-define(MAC, <<2, 0, 0, 0, 0, 1>>).

-doc false.
serve(_MaxRequest) ->
    ok.

-doc false.
start_grant(Grantee, Limits) ->
    erx_net_grant:start_link(Grantee, Limits).

-doc false.
children() ->
    erx_net_local:children().

-doc false.
export(_Grant, [send], ?GRANTEE) ->
    ok.

%% --- Cases ------------------------------------------------------------------------------

stack_test_() ->
    {foreach, fun start_stack/0, fun stop_stack/1,
     [fun(Stack) -> {"the end of " ++ atom_to_list(Name) ++ " ends the stack",
                     ?_test(top_child_end_ends_the_stack(Stack, Name))} end
      || Name <- [erx_net_tables, erx_net_grants, erx_net_interfaces, erx_net_grant]] ++
     [fun(Stack) -> {"a link's end keeps the grants", ?_test(link_end_keeps_grants(Stack))} end,
      fun(Stack) -> {"network_ctl restarts the link", ?_test(control_restart_keeps_grants(Stack))} end,
      fun(Stack) -> {"network_ctl stops and starts the link", ?_test(control_stop_then_start(Stack))} end]}.

%% Killing the registered child Name of erx_net_sup ends the stack once, with nothing
%% restarted: a top-level restart would leave the minted grants dead or name a mint after
%% the ready report.
top_child_end_ends_the_stack({Stack, _Far}, Name) ->
    Ref = monitor(process, Stack),
    exit(whereis(Name), kill),
    receive
        {'DOWN', Ref, process, Stack, Reason} -> ?assertEqual(shutdown, Reason)
    after 5000 ->
        error({stack_outlived, Name})
    end,
    ?assertEqual(undefined, whereis(Name)).

%% A link supervisor's end is erx_net_interfaces' to restart: a new link comes up under the
%% same supervisor, and the stack and a minted grant are untouched.
link_end_keeps_grants({Stack, _Far}) ->
    {ok, Grant} = mint(),
    Interfaces = whereis(erx_net_interfaces),
    Link = vtnet0_link(),
    exit(Link, kill),
    New = until(fun() -> another_link(Link) end),
    ?assertNotEqual(Link, New),
    ?assertEqual(Interfaces, whereis(erx_net_interfaces)),
    ?assert(is_process_alive(Grant)),
    ?assert(is_process_alive(Stack)).

%% erx_driver_ctl's restart of the unit `net`, through the units map erXos's runtime gives
%% network_ctl, rebuilds vtnet0's link, its driver included, and leaves the grant.
control_restart_keeps_grants({Stack, _Far}) ->
    Units = erxos_units(),
    {ok, Grant} = mint(),
    Link = vtnet0_link(),
    {ok, Driver} = erx_net_tables:driver(vtnet0),
    ?assertEqual({reply, ok, Units}, erx_driver_ctl:admit({restart, net}, from, Units)),
    New = vtnet0_link(),
    ?assert(is_pid(New)),
    ?assertNotEqual(Link, New),
    NewDriver = until(fun() -> case erx_net_tables:driver(vtnet0) of
                                   {ok, Driver} -> false;
                                   {ok, Other} -> Other;
                                   none -> false
                               end end),
    ?assertNotEqual(Driver, NewDriver),
    ?assert(is_process_alive(Grant)),
    ?assert(is_process_alive(Stack)).

%% A stop leaves the link stopped, its driver gone; a start builds it again, and a second
%% start answers running. Neither touches the grant.
control_stop_then_start({Stack, _Far}) ->
    Units = erxos_units(),
    {ok, Grant} = mint(),
    {ok, Driver} = erx_net_tables:driver(vtnet0),
    ?assertEqual({reply, ok, Units}, erx_driver_ctl:admit({stop, net}, from, Units)),
    ?assertEqual(undefined, vtnet0_link()),
    ?assertNot(is_process_alive(Driver)),
    ?assertEqual({reply, ok, Units}, erx_driver_ctl:admit({start, net}, from, Units)),
    ?assert(is_pid(vtnet0_link())),
    until(fun() -> case erx_net_tables:driver(vtnet0) of
                       {ok, New} -> New =/= Driver andalso is_process_alive(New);
                       none -> false
                   end end),
    ?assertEqual({reply, {error, running}, Units}, erx_driver_ctl:admit({start, net}, from, Units)),
    ?assert(is_process_alive(Grant)),
    ?assert(is_process_alive(Stack)).

%% A grant of ?GRANTEE, minted as erx_net_erxos's mint does, over a stand-in of
%% the connection to the grantee: a port the case owns, which outlives the case's checks.
mint() ->
    erx_net:mint_grant(?GRANTEE, open_port({spawn, "cat"}, [binary]), #{}, ?MODULE).

%% --- The stack and its far end ----------------------------------------------------------

%% The stack over one pipe interface, vtnet0 as on erXos, whose far end drops every frame.
start_stack() ->
    wait_gone(erx_net_tables),
    Test = self(),
    Far = spawn(fun() -> true = register(?FAR, self()), Test ! {far, self()}, drop() end),
    receive {far, Far} -> ok end,
    Pipe = #{name => vtnet0, ip4 => #{addr => <<10, 0, 2, 15>>, plen => 24, gateway => <<10, 0, 2, 2>>},
             transport => {erx_net_pipe, #{far => {process, ?FAR}, lladdr => ?MAC}}},
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [Pipe], runtime => ?MODULE}),
    unlink(Stack),
    {Stack, Far}.

%% Stops the stack, which a case may have ended already, then its far end.
stop_stack({Stack, Far}) ->
    try proc_lib:stop(Stack, shutdown, infinity) catch exit:noproc -> ok end,
    wait_gone(erx_net_tables),
    exit(Far, kill),
    wait_gone(?FAR).

drop() ->
    receive _ -> drop() end.

%% The units map of network_ctl in erXos's runtime, read from its children, the mints of
%% net and network_ctl and then the grant local; the host test's seeded fault edits this map.
erxos_units() ->
    [{net, _}, {network_ctl, {erx_driver_ctl, start_mint, [network_ctl, Units]}},
     {erx_net_grant, _}] = erx_net_erxos:children(),
    Units.

%% vtnet0's link supervisor, or undefined while it is stopped.
vtnet0_link() ->
    [{vtnet0, Link, supervisor, _}] = supervisor:which_children(erx_net_interfaces),
    Link.

%% vtnet0's link supervisor once it is a process other than Link, else false.
another_link(Link) ->
    case vtnet0_link() of
        Other when is_pid(Other), Other =/= Link -> Other;
        _StoppedOrSame -> false
    end.

%% Polls Fun until it answers other than false, for at most five seconds.
until(Fun) ->
    until(Fun, 250).

until(_Fun, 0) ->
    error(timed_out);
until(Fun, Tries) ->
    case Fun() of
        false -> timer:sleep(20), until(Fun, Tries - 1);
        Answer -> Answer
    end.

wait_gone(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> Ref = monitor(process, Pid), receive {'DOWN', Ref, _, _, _} -> ok end
    end.
