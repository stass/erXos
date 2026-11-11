%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a domain's connection agent, erx_connections, serving the
%% connection-control records of its domain pid (docs/design-domains.md,
%% "Messages between the domain service and a runtime"). The test process
%% plays the agent's whole environment: the system domain's domain pid, which
%% sends the records in their envelope and takes the answers, net_kernel, which
%% names each connection's owner or refuses it, and erx_dist's owner, which
%% says when the peer's entry is up. A stand-in opener gives the agent a port
%% of cat for each introduced connection in place of the lane driver's, and
%% tells the test the open command it was given. A cat port has no control
%% callback, so its finish is refused and the agent ends it at once
%% (erx_connections:finish/2); the lane driver's finish is the QEMU suites'.
-module(erx_connections_tests).
-include_lib("eunit/include/eunit.hrl").

%% The system domain's id, the peer an introduction names and the peer's node.
-define(SYSTEM, 4).
-define(PEER, 7).
-define(PEER_NODE, 'peer@erxos').
%% A connection_up's words after the peer's node: the domain's side, the peer's side
%% and bell, the label, and the sizes of the ring the domain writes and of the one it reads.
-define(UP_WORDS, 11, 12, 13, 9, 4096, 8192).

agent_test_() ->
    [{atom_to_list(Name), fun() -> with_agent(Case) end}
     || {Name, Case} <- [{mapped_then_lost, fun mapped_then_lost/1}, {ended_before_up, fun ended_before_up/1},
                         {owner_ended, fun owner_ended/1}, {refused_hand_over, fun refused_hand_over/1},
                         {refused_open, fun refused_open/1}, {down, fun down/1}, {forged, fun forged/1},
                         {facets, fun facets/1}, {installs, fun installs/1}, {connection, fun connection/1}]].

%% Runs Case with an agent started from the test's own process, which plays the
%% agent's environment, and ends the agent after.
with_agent(Case) ->
    Agent = start(),
    try Case(Agent) after stop(Agent) end.

%% The agent, registered as start/2 registers it, with the stand-in opener, once its
%% name is taken, so erx_connections:dropped/0 reaches it; the test is its net_kernel
%% and its domain pid.
start() ->
    Test = self(),
    start(fun(Command) ->
                  Port = open_port({spawn, "cat"}, [binary]),
                  Test ! {opened, Command, Port},
                  Port
          end).

start(Open) ->
    Test = self(),
    Agent = spawn(fun() ->
                          process_flag(trap_exit, true),
                          true = register(erx_connections, self()),
                          Test ! {registered, self()},
                          erx_connections:introduced(Test, ?SYSTEM, Test, Open)
                  end),
    receive {registered, Agent} -> Agent end.

%% Ends the agent and waits until its name is free for the next.
stop(Agent) ->
    Ref = monitor(process, Agent),
    exit(Agent, kill),
    receive {'DOWN', Ref, process, Agent, _} -> ok end.

%% The record from the system domain's domain pid, as the funnel delivers it.
record(Agent, Record) ->
    Agent ! {erx_origin, ?SYSTEM, Record}.

up(Agent) ->
    record(Agent, {erx_connection_up, ?PEER, ?PEER_NODE, ?UP_WORDS}).

%% The open command the agent gave the opener, and the port it got.
opened() ->
    receive {opened, Command, Port} -> {Command, Port} after 2000 -> timeout end.

%% net_kernel's accept: the connection the agent offered, then Reply: an owner that
%% takes the port as erx_dist's does, once the agent has handed it over, or the refusal.
accept(Agent, Reply) ->
    receive
        {accept, Agent, #{port := Port, node := ?PEER_NODE, id := ?PEER, system := false}, erx, erx} ->
            case Reply of
                owner ->
                    Test = self(),
                    Owner = spawn(fun() ->
                                          receive {Agent, controller} -> Test ! {owning, self()} end,
                                          receive after infinity -> ok end
                                  end),
                    Agent ! {self(), controller, Owner},
                    receive {owning, Owner} -> {Port, Owner} after 2000 -> timeout end;
                refuse ->
                    Agent ! {self(), unsupported_protocol},
                    Port
            end
    after 2000 ->
            timeout
    end.

%% A connection brought up as erx_dist's owner does it: the port handed over, then the
%% owner's word that the peer's entry is up, answered connection_mapped.
mapped(Agent) ->
    up(Agent),
    {_Command, Port} = opened(),
    {Port, Owner} = accept(Agent, owner),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    {erx_connection_mapped, ?PEER} = answer(),
    {Port, Owner}.

answer() ->
    receive
        {erx_connection_mapped, _} = Answer -> Answer;
        {erx_connection_unmapped, _} = Answer -> Answer;
        {erx_connection_lost, _, _} = Answer -> Answer;
        {erx_facets_installed, _} = Answer -> Answer
    after 2000 ->
            none
    end.

%% No answer within a short while.
silent() ->
    receive
        {erx_connection_mapped, _} = Answer -> Answer;
        {erx_connection_unmapped, _} = Answer -> Answer;
        {erx_connection_lost, _, _} = Answer -> Answer
    after 200 ->
            none
    end.

mapped_then_lost(Agent) ->
    %% The open command carries the record's words in its order, then the peer and its
    %% node (erx_lane_drv.c, lane_open_parse); the answer waits for the owner's word that
    %% the entry is up; the port's own end, here the lane driver's for a malformed
    %% frame, is answered connection_lost with the reason design-domains names for it.
    up(Agent),
    ?assertMatch({"erx_lane 11 12 13 9 4096 8192 7 peer@erxos", _}, opened()),
    {Port, _Owner} = accept(Agent, owner),
    ?assertEqual(none, silent()),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual({erx_connection_mapped, ?PEER}, answer()),
    exit(Port, erx_lane_malformed),
    ?assertEqual({erx_connection_lost, ?PEER, malformed}, answer()).

connection(Agent) ->
    %% The port of a connection is named only once the peer's entry is up, and no longer
    %% once the port has ended; a peer never introduced has none.
    ?assertEqual({error, noconnection}, erx_connections:connection(?PEER)),
    up(Agent),
    {_, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    ?assertEqual({error, noconnection}, erx_connections:connection(?PEER)),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual({erx_connection_mapped, ?PEER}, answer()),
    ?assertEqual({ok, Port}, erx_connections:connection(?PEER)),
    ?assertEqual({error, noconnection}, erx_connections:connection(?PEER + 1)),
    exit(Port, erx_lane_malformed),
    ?assertEqual({erx_connection_lost, ?PEER, malformed}, answer()),
    ?assertEqual({error, noconnection}, erx_connections:connection(?PEER)).

ended_before_up(Agent) ->
    %% A port that ends before the owner's word that its entry is up was never mapped:
    %% connection_lost with {map, Reason}, and the word arriving after it is nothing. The
    %% peer is then free for a later connection_up.
    up(Agent),
    {_, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    exit(Port, erx_lane_malformed),
    ?assertEqual({erx_connection_lost, ?PEER, {map, malformed}}, answer()),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual(none, silent()),
    {Again, _} = mapped(Agent),
    ?assertNotEqual(Port, Again).

owner_ended(Agent) ->
    %% erlang:disconnect_node/1 has net_kernel end the port, the entry's controller, with
    %% disconnect; here the owner, linked to the port, ends with that reason and takes it
    %% along. Any other end of the owner,
    %% whose reason may hold atoms the system domain lacks, is noconnection.
    {Port, Owner} = mapped(Agent),
    exit(Owner, disconnect),
    ?assertEqual({erx_connection_lost, ?PEER, disconnect}, answer()),
    ?assertEqual(undefined, erlang:port_info(Port)),
    {_, Crashed} = mapped(Agent),
    exit(Crashed, {owner_crashed, erx_connections_tests}),
    ?assertEqual({erx_connection_lost, ?PEER, noconnection}, answer()).

refused_hand_over(Agent) ->
    %% A port net_kernel refuses is ended before the answer, connection_lost with
    %% {map, refused}, so no refused port maps the connection.
    up(Agent),
    {_, Port} = opened(),
    Port = accept(Agent, refuse),
    ?assertEqual({erx_connection_lost, ?PEER, {map, refused}}, answer()),
    ?assertEqual(undefined, erlang:port_info(Port)).

refused_open(Agent) ->
    %% An open the lane driver refuses, here an opener that raises badarg as
    %% open_port/2 does, is connection_lost with {map, refused}; net_kernel hears nothing.
    stop(Agent),
    Refusing = start(fun(_Command) -> error(badarg) end),
    try
        up(Refusing),
        ?assertEqual({erx_connection_lost, ?PEER, {map, refused}}, answer()),
        ?assertEqual(timeout, accept(Refusing, refuse))
    after
        stop(Refusing)
    end.

down(Agent) ->
    %% connection_down finishes the port, here refused, as for a port gone already, so
    %% the agent ends it at once with the record's reason and answers
    %% connection_unmapped; normal, which would end nothing, ends it as noconnection. A
    %% connection_down about a peer the agent holds no port for is answered at once.
    {Port, _} = mapped(Agent),
    Watch = monitor(port, Port),
    record(Agent, {erx_connection_down, ?PEER, {domain_down, ?PEER, crash}}),
    ?assertEqual({erx_connection_unmapped, ?PEER}, answer()),
    ?assertEqual({domain_down, ?PEER, crash}, receive {'DOWN', Watch, port, Port, R} -> R after 2000 -> timeout end),
    {Normal, _} = mapped(Agent),
    WatchNormal = monitor(port, Normal),
    record(Agent, {erx_connection_down, ?PEER, normal}),
    ?assertEqual({erx_connection_unmapped, ?PEER}, answer()),
    ?assertEqual(noconnection, receive {'DOWN', WatchNormal, port, Normal, N} -> N after 2000 -> timeout end),
    record(Agent, {erx_connection_down, 99, noconnection}),
    ?assertEqual({erx_connection_unmapped, 99}, answer()).

forged(Agent) ->
    %% Only a record in the system connection's envelope is acted on: one a peer
    %% handed the agent's pid sends arrives in its own domain's envelope, and one a
    %% process of the domain sends arrives bare. A connection_up about a peer the agent
    %% holds a port for is no record the system domain sends. Each is dropped and
    %% counted, and the connection carries on.
    {Port, _} = mapped(Agent),
    ?assertEqual(0, erx_connections:dropped()),
    Agent ! {erx_origin, ?PEER, {erx_connection_down, ?PEER, noconnection}},
    Agent ! {erx_origin, ?PEER, {erx_connection_up, 8, 'other@erxos', ?UP_WORDS}},
    Agent ! {erx_connection_down, ?PEER, noconnection},
    ?assertEqual(3, erx_connections:dropped()),
    up(Agent),
    ?assertEqual(4, erx_connections:dropped()),
    ?assertEqual(none, silent()),
    ?assertEqual(timeout, opened()),
    ?assertMatch([_ | _], erlang:port_info(Port)),
    record(Agent, {erx_connection_down, ?PEER, noconnection}),
    ?assertEqual({erx_connection_unmapped, ?PEER}, answer()).

facets(Agent) ->
    %% The domain service's facets answer reaches init only in the system connection's
    %% envelope, and as a map, of which init gets the entries naming a facet's pid by an
    %% atom. One a peer sends, one sent bare, one that is not a map and one wrapped twice
    %% are dropped and counted, so no domain but the system domain names init's facets.
    Init = whereis(init),
    Facet = spawn(fun() -> receive stop -> ok end end),
    erlang:trace(Init, true, ['receive']),
    Agent ! {erx_origin, ?PEER, {erx_facets, #{forged => Facet}}},
    Agent ! {erx_facets, #{forged => Facet}},
    Agent ! {erx_origin, ?SYSTEM, {erx_facets, [forged]}},
    Agent ! {erx_origin, ?SYSTEM, {erx_origin, ?PEER, {erx_facets, #{forged => Facet}}}},
    record(Agent, {erx_facets, #{echo => Facet, <<"bin">> => Facet, bad => 3}}),
    ?assertEqual(4, erx_connections:dropped()),
    First = init_facets(2000),
    erlang:trace(Init, false, ['receive']),
    ?assertEqual([#{echo => Facet}], First ++ init_facets(100)),
    Facet ! stop.

installs(Agent) ->
    %% A facet a configured domain minted for this domain is installed in its registry,
    %% beside the answer's facets, and acknowledged to the domain pid with its tag, only
    %% from the system connection's envelope: one a peer sends, one sent bare and one
    %% with a name that is no atom are dropped and counted, and install nothing. A later
    %% installation under a name replaces the older pid.
    Answer = spawn(fun() -> receive stop -> ok end end),
    [Old, New] = [spawn(fun() -> receive stop -> ok end end) || _ <- [1, 2]],
    try
        record(Agent, {erx_facets, #{echo => Answer}}),
        Agent ! {erx_origin, ?PEER, {erx_facets_install, 1, data, Old}},
        Agent ! {erx_facets_install, 2, data, Old},
        record(Agent, {erx_facets_install, 3, <<"data">>, Old}),
        record(Agent, {erx_facets_install, 4, data, Old}),
        ?assertEqual({erx_facets_installed, 4}, answer()),
        ?assertEqual(3, erx_connections:dropped()),
        ?assertEqual(#{echo => Answer, data => Old}, persistent_term:get({erx, facets})),
        record(Agent, {erx_facets_install, 5, data, New}),
        ?assertEqual({erx_facets_installed, 5}, answer()),
        ?assertEqual(#{echo => Answer, data => New}, persistent_term:get({erx, facets}))
    after
        persistent_term:erase({erx, facets}),
        [Pid ! stop || Pid <- [Answer, Old, New]]
    end.

%% The facets answers init received, in order, from the trace of its receives, waiting
%% at most Ms for each. The first wait is long: the agent has answered dropped/0 once it
%% has sent the answer, but the trace of init's receive may come later on a loaded host.
init_facets(Ms) ->
    receive
        {trace, _, 'receive', {erx_facets, Facets}} -> [Facets | init_facets(100)];
        {trace, _, 'receive', _} -> init_facets(Ms)
    after Ms -> []
    end.

%% The system domain's agent, serving the domain service's open_side and close_side over
%% the same stand-in opener; the test is its net_kernel and the owner's word that the
%% side's entry is up. Each open_side runs in a caller of its own, which plays the domain
%% service: it passes the answer, and anything the agent sends it after, to the test.
side_test_() ->
    [{atom_to_list(Name), fun() -> with_sides(Case) end}
     || {Name, Case} <- [{side_answered_once_up, fun side_answered_once_up/1},
                         {side_ended_before_up, fun side_ended_before_up/1},
                         {side_ended_after_up, fun side_ended_after_up/1},
                         {side_closed_before_up, fun side_closed_before_up/1}]].

with_sides(Case) ->
    Test = self(),
    Opener = fun(Command) ->
                     Port = open_port({spawn, "cat"}, [binary]),
                     Test ! {opened, Command, Port},
                     Port
             end,
    Agent = spawn(fun() ->
                          process_flag(trap_exit, true),
                          true = register(erx_connections, self()),
                          Test ! {registered, self()},
                          erx_connections:system_sides(Test, Opener)
                  end),
    receive {registered, Agent} -> ok end,
    try Case(Agent) after stop(Agent) end.

%% The library's values of a domain's system connection, as erx_domain_lib:create/1 gives them.
side_values() ->
    #{node => ?PEER_NODE, connection => 9, side => 11, peer_side => 12, bell => 13, reader => 2,
      system_lane => 3, ctl_slots => 4, domain_pid_number => 40, domain_pid_serial => 0}.

%% open_side for the peer from a caller standing for the domain service.
open_side() ->
    Test = self(),
    spawn(fun() -> Test ! {side, erx_connections:open_side(?PEER, side_values())}, forward(Test) end).

forward(Test) ->
    receive Msg -> Test ! {side, Msg}, forward(Test) end.

side_answer(Ms) ->
    receive {side, Answer} -> Answer after Ms -> none end.

side_answered_once_up(Agent) ->
    %% The answer waits for the owner's word that the side's entry is up, so the domain
    %% service's export to the domain, which needs that entry, never runs before it.
    open_side(),
    {_Command, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    ?assertEqual(none, side_answer(200)),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual({ok, Port}, side_answer(2000)).

side_ended_before_up(Agent) ->
    %% A side whose port ends before its entry is up never opened: noconnection, and the
    %% service is told nothing more, since it holds no side to stop.
    open_side(),
    {_Command, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    exit(Port, kill),
    ?assertEqual({error, noconnection}, side_answer(2000)),
    ?assertEqual(none, side_answer(200)),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual(none, side_answer(200)).

side_ended_after_up(Agent) ->
    %% An open side's end by itself is the service's word to stop the domain.
    open_side(),
    {_Command, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual({ok, Port}, side_answer(2000)),
    exit(Port, kill),
    ?assertEqual({system_side_ended, ?PEER}, side_answer(2000)).

side_closed_before_up(Agent) ->
    %% close_side on a side still coming up ends it, and its opener hears noconnection.
    open_side(),
    {_Command, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    ?assertEqual(ok, erx_connections:close_side(?PEER, stopped)),
    ?assertEqual({error, noconnection}, side_answer(2000)),
    ?assertEqual(none, side_answer(200)).
