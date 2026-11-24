%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_dist's connection owner at the runtime's ordered end. The test
%% plays net_kernel: a process that asks erx_dist for a connection's owner, so the owner
%% is linked to it as to net_kernel, and then ends as its supervisor ends it in an ordered
%% stop. An owner of the system connection that took that end for a lost connection would
%% halt this runtime with EX_UNAVAILABLE, which ends the run instead of failing a case.
-module(erx_dist_tests).
-include_lib("eunit/include/eunit.hrl").

%% The system domain's id and node, the system connection's peer.
-define(SYSTEM, 4).
-define(SYSTEM_NODE, 'system@erxos').

%% The owner's decision over every origin, the reasons it tells apart and others, the
%% ones erts_do_net_exits gives a port and net_kernel's remarked among them, and
%% net_kernel alive or not. Two cases do not end the connection: net_kernel's own
%% shutdown once it is gone, which the owner follows, and another's net_kernel_terminated
%% once it is gone, at which the owner awaits net_kernel's exit.
exit_action_is_exhaustive_test() ->
    Reasons = [shutdown, net_kernel_terminated, no_network, {shutdown, shutdown}, remarked,
               normal, killed],
    Kept = #{{kernel, shutdown, false} => follow,
             {other, net_kernel_terminated, false} => await_kernel},
    [?assertEqual({Case, maps:get(Case, Kept, ended)},
                  {Case, erx_dist:exit_action(Origin, Reason, Alive)})
     || Origin <- [kernel, other], Reason <- Reasons, Alive <- [true, false],
        Case <- [{Origin, Reason, Alive}]].

owner_follows_an_ordered_end_before_the_controller_test() ->
    {Kernel, Owner, Port} = owner(true),
    Monitor = erlang:monitor(process, Owner),
    Kernel ! stop,
    ?assertEqual(shutdown, down(Monitor, Owner)),
    port_close(Port).

%% net_kernel's end kills each dist port with net_kernel_terminated, and that exit can
%% reach the owner before net_kernel's own: the owner, suspended until both are queued,
%% meets the port's first, and still follows the ordered end rather than halt the runtime.
owner_awaits_net_kernel_after_its_port_ends_test() ->
    {Kernel, Owner, Port} = owner(true),
    Monitor = erlang:monitor(process, Owner),
    KernelMonitor = erlang:monitor(process, Kernel),
    true = erlang:suspend_process(Owner),
    Owner ! {'EXIT', Port, net_kernel_terminated},
    Kernel ! stop,
    shutdown = down(KernelMonitor, Kernel),
    true = erlang:resume_process(Owner),
    ?assertEqual(shutdown, down(Monitor, Owner)),
    port_close(Port).

%% An 'EXIT' message in net_kernel's name from a process other than an ending net_kernel
%% ends the connection like any other exit and never ends the owner quietly. The
%% connection is to a domain other than the system domain, so that end is the owner's
%% exit, not a halt of this runtime.
owner_ends_the_connection_at_a_forged_kernel_shutdown_test() ->
    {Kernel, Owner, Port} = owner(false),
    Monitor = erlang:monitor(process, Owner),
    Owner ! {'EXIT', Kernel, shutdown},
    ?assertEqual({shutdown, shutdown}, down(Monitor, Owner)),
    Kernel ! stop,
    port_close(Port).

%% net_kernel's stand-in, the owner it was handed and the connection's port.
owner(System) ->
    Port = open_port({spawn, "cat"}, []),
    Test = self(),
    Kernel = spawn(fun() -> kernel(Test, Port, System) end),
    Owner = receive {Kernel, owner, Pid} -> Pid after 2000 -> error(no_owner) end,
    {Kernel, Owner, Port}.

down(Monitor, Pid) ->
    receive
        {'DOWN', Monitor, process, Pid, Reason} -> Reason
    after 2000 -> error(lives)
    end.

%% net_kernel's part: it accepts a connection, the system connection when System, so the
%% owner it is handed is linked to it, and ends with shutdown when told, as net_sup ends
%% it in an ordered stop.
kernel(Test, Port, System) ->
    Peer = case System of
               true -> #{node => ?SYSTEM_NODE, id => ?SYSTEM};
               false -> #{node => 'app@erxos', id => ?SYSTEM + 1}
           end,
    Connection = Peer#{port => Port, system => System},
    Owner = erx_dist:accept_connection(self(), Connection, node(), [], []),
    Test ! {self(), owner, Owner},
    receive stop -> exit(shutdown) end.
