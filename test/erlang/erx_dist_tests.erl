%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_dist's connection owner at the runtime's ordered end. The test
%% plays net_kernel: a process that asks erx_dist for the system connection's owner, so
%% the owner is linked to it as to net_kernel, and then ends as its supervisor ends it in
%% an ordered stop. An owner that took that end for a lost system connection would halt
%% this runtime with EX_UNAVAILABLE, which ends the run instead of failing a case.
-module(erx_dist_tests).
-include_lib("eunit/include/eunit.hrl").

%% The system domain's id and node, the system connection's peer.
-define(SYSTEM, 4).
-define(SYSTEM_NODE, 'system@erxos').

owner_follows_an_ordered_end_before_the_controller_test() ->
    Port = open_port({spawn, "cat"}, []),
    Test = self(),
    Kernel = spawn(fun() -> kernel(Test, Port) end),
    Owner = receive {Kernel, owner, Pid} -> Pid after 2000 -> error(no_owner) end,
    Monitor = erlang:monitor(process, Owner),
    Kernel ! stop,
    ?assertEqual(shutdown, receive {'DOWN', Monitor, process, Owner, Reason} -> Reason
                           after 2000 -> error(owner_lives) end),
    port_close(Port).

%% net_kernel's part: it accepts the system connection, so the owner it is handed is
%% linked to it, and ends with shutdown when told, as net_sup ends it in an ordered stop.
kernel(Test, Port) ->
    Connection = #{port => Port, node => ?SYSTEM_NODE, id => ?SYSTEM, system => true},
    Owner = erx_dist:accept_connection(self(), Connection, node(), [], []),
    Test ! {self(), owner, Owner},
    receive stop -> exit(shutdown) end.
