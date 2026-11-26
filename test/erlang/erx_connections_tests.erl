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
-include("generated/erx_abi.hrl").

%% The system domain's id, the peer an introduction names and the peer's node.
-define(SYSTEM, 4).
-define(PEER, 7).
-define(PEER_NODE, 'peer@erxos').
%% A connection_up's words after the peer's node: the domain's side, the peer's side
%% and bell, the label, and the sizes of the ring the domain writes and of the one it reads.
-define(UP_WORDS, 11, 12, 13, 9, 4096, 8192, none).
%% A pixel area the stand-in maps, and one it refuses.
-define(AREA, {21, 8192, write}).
-define(BAD_AREA, {0, 8192, read}).

agent_test_() ->
    [{atom_to_list(Name), fun() -> with_agent(Case) end}
     || {Name, Case} <- [{mapped_then_lost, fun mapped_then_lost/1}, {ended_before_up, fun ended_before_up/1},
                         {owner_ended, fun owner_ended/1}, {refused_hand_over, fun refused_hand_over/1},
                         {refused_open, fun refused_open/1}, {down, fun down/1}, {forged, fun forged/1},
                         {facets, fun facets/1}, {app, fun app/1}, {installs, fun installs/1},
                         {untyped_facets_are_dropped, fun untyped_facets_are_dropped/1},
                         {drive_installs, fun drive_installs/1}, {connection, fun connection/1},
                         {area_down, fun area_down/1}, {area_lost, fun area_lost/1},
                         {area_lost_then_down, fun area_lost_then_down/1}, {area_refused, fun area_refused/1},
                         {malformed_calls, fun malformed_calls/1}]]
    %% area_collected starts its own agent, with erx_area:map/4 in place of the stand-in fun.
    ++ [{"area_collected", fun area_collected/0}].

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
    start(Open, map_area(self())).

start(Open, MapArea) ->
    Test = self(),
    Agent = spawn(fun() ->
                          process_flag(trap_exit, true),
                          true = register(erx_connections, self()),
                          Test ! {registered, self()},
                          erx_connections:introduced(Test, ?SYSTEM, Test, Open, MapArea)
                  end),
    receive {registered, Agent} -> Agent end.

%% The stand-in for erx_area:map/4: tells the test the mapping's tag and answers a term
%% naming it, or refuses slot 0. The test plays the area's destructor: it sends the agent
%% {erx_area_unmapped, Tag} when a case says the last reference is gone.
map_area(Test) ->
    fun(0, _Bytes, _Mode, _Tag) -> {error, einval};
       (Slot, Bytes, Mode, Tag) -> Test ! {area_mapped, Slot, Bytes, Mode, Tag}, {ok, {area, Tag}}
    end.

area_mapped() ->
    receive {area_mapped, 21, 8192, write, Tag} -> Tag after 2000 -> timeout end.

%% A connection with ?AREA brought up as mapped/1 brings one up, and the area's tag.
mapped_area(Agent) ->
    record(Agent, {erx_connection_up, ?PEER, ?PEER_NODE, 11, 12, 13, 9, 4096, 8192, ?AREA}),
    Tag = area_mapped(),
    {_Command, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    {erx_connection_mapped, ?PEER} = answer(),
    {Port, Tag}.

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
    %% atom, a facet of a tree as the pid with its tree, a plain name, and its grant's
    %% rights, ro, rw or rx, each with its service's interface number; one of a tree
    %% without its tree, or whose tree is no plain name, is left out. One a peer
    %% sends, one sent bare, one that is not a map and one wrapped twice are dropped and
    %% counted, so no domain but the system domain names init's facets.
    %% The answer's names of the facets the manifest grants the domain, which come later
    %% by installation, are kept for erx:granted/0,1, the {Name, Interface} pairs alone, before init hears
    %% of the facets, so a domain mounts only what it is granted; a forged answer
    %% changes them no more than it changes the facets.
    Init = whereis(init),
    Facet = spawn(fun() -> receive stop -> ok end end),
    erlang:trace(Init, true, ['receive']),
    try
        Agent ! {erx_origin, ?PEER, {erx_facets, #{forged => Facet}, [forged]}},
        Agent ! {erx_facets, #{forged => Facet}, [forged]},
        Agent ! {erx_origin, ?SYSTEM, {erx_facets, [forged], [forged]}},
        Agent ! {erx_origin, ?SYSTEM, {erx_origin, ?PEER, {erx_facets, #{forged => Facet}, [forged]}}},
        record(Agent, {erx_facets, #{echo => {?ERX_SERVICE_CONSOLE, Facet}, tree => {?ERX_SERVICE_FILES, {Facet, <<"tree">>, ro}},
                                     <<"bin">> => {?ERX_SERVICE_CONSOLE, Facet}, bad => {?ERX_SERVICE_CONSOLE, 3},
                                     wide => {?ERX_SERVICE_FILES, {Facet, <<"wide">>, rwx}},
                                     nopid => {?ERX_SERVICE_FILES, {3, <<"nopid">>, rw}},
                                     no_tree =>{?ERX_SERVICE_FILES, {Facet, ro}},
                                     climbing => {?ERX_SERVICE_FILES, {Facet, <<"../x">>, ro}}},
                       [{data, 5}, data, {<<"bin">>, 5}, {data, files}, 3 | tail]}),
        ?assertEqual(4, erx_connections:dropped()),
        First = init_facets(2000),
        erlang:trace(Init, false, ['receive']),
        ?assertEqual([#{echo => {?ERX_SERVICE_CONSOLE, Facet}, tree => {?ERX_SERVICE_FILES, {Facet, <<"tree">>, ro}}}],
                     First ++ init_facets(100)),
        ?assertEqual(Facet, erx:cap(tree)),
        ?assertEqual(#{echo => Facet, tree => Facet}, erx:caps()),
        ?assertEqual([data], erx:granted()),
        ?assertEqual([data], erx:granted(5)),
        ?assertEqual([], erx:granted(15))
    after
        persistent_term:erase({erx, granted}),
        persistent_term:erase({erx, facets}),
        Facet ! stop
    end.

app(Agent) ->
    %% erx_app asks the agent for the app's record (erx:app/0), which the agent answers
    %% once the record has come in the system connection's envelope: a question asked
    %% before it waits for it, and one asked after is answered with the record the agent
    %% kept. A record a peer sends, or one sent bare, is dropped and counted, and answers
    %% no one; so is a second record, which leaves the first one kept. erx_ns asks the
    %% agent what it holds (erx_connections:app_held/0), which never waits: enoent
    %% before the record, the record after.
    Test = self(),
    Record = #{place => {packages, [<<"clock.app">>]}, layout => #{}, start => {applications, [<<"clock">>]}},
    Early = spawn(fun() -> Test ! {early, erx:app()} end),
    asking(Early),
    ?assertEqual({error, enoent}, erx_connections:app_held()),
    Agent ! {erx_origin, ?PEER, {erx_app, #{place => <<"forged">>}}},
    Agent ! {erx_app, #{place => <<"forged">>}},
    ?assertEqual(2, erx_connections:dropped()),
    ?assertEqual(timeout, receive {early, Early1} -> Early1 after 0 -> timeout end),
    record(Agent, {erx_app, Record}),
    ?assertEqual({ok, Record}, receive {early, Answer} -> Answer after 2000 -> timeout end),
    record(Agent, {erx_app, #{place => <<"second">>}}),
    ?assertEqual(3, erx_connections:dropped()),
    ?assertEqual({ok, Record}, erx:app()),
    ?assertEqual({ok, Record}, erx_connections:app_held()).

%% Waits until Pid waits in its call, its question queued at the agent, or has ended,
%% answered at once.
asking(Pid) ->
    case erlang:process_info(Pid, status) of
        {status, waiting} -> ok;
        undefined -> ok;
        _ -> erlang:yield(), asking(Pid)
    end.

installs(Agent) ->
    %% A facet a configured domain minted for this domain is installed in its registry,
    %% beside the answer's facets, and acknowledged to the domain pid with its tag, only
    %% from the system connection's envelope: one a peer sends, one sent bare and one
    %% with a name that is no atom, with rights other than ro, rw and rx, or with a tree
    %% that is no plain name or no tree at all, are dropped and counted, and install
    %% nothing. A files facet is installed with the tree and the rights the installation
    %% carries, which erx:cap/1 leaves out. A later installation under a name
    %% replaces the older pid.
    Answer = spawn(fun() -> receive stop -> ok end end),
    [Old, New] = [spawn(fun() -> receive stop -> ok end end) || _ <- [1, 2]],
    try
        record(Agent, {erx_facets, #{echo => {?ERX_SERVICE_CONSOLE, Answer}}, []}),
        Agent ! {erx_origin, ?PEER, {erx_facets_install, 1, data, ?ERX_SERVICE_FILES, {Old, <<"data">>, rx}}},
        Agent ! {erx_facets_install, 2, data, ?ERX_SERVICE_FILES, {Old, <<"data">>, rx}},
        record(Agent, {erx_facets_install, 3, <<"data">>, ?ERX_SERVICE_FILES, {Old, <<"data">>, rw}}),
        record(Agent, {erx_facets_install, 6, data, ?ERX_SERVICE_FILES, {Old, <<"data">>, rwx}}),
        record(Agent, {erx_facets_install, 7, data, ?ERX_SERVICE_FILES, {Old, <<"a/b">>, rw}}),
        record(Agent, {erx_facets_install, 8, data, ?ERX_SERVICE_FILES, {Old, rw}}),
        %% Every dropped installation comes before tag 4, so an answer for 4 first proves
        %% that none of them was acknowledged.
        record(Agent, {erx_facets_install, 4, data, ?ERX_SERVICE_FILES, {Old, <<"data">>, rw}}),
        ?assertEqual({erx_facets_installed, 4}, answer()),
        ?assertEqual(6, erx_connections:dropped()),
        ?assertEqual({2, #{echo => {?ERX_SERVICE_CONSOLE, Answer}, data => {?ERX_SERVICE_FILES, {Old, <<"data">>, rw}}}},
                     persistent_term:get({erx, facets})),
        ?assertEqual(Old, erx:cap(data)),
        record(Agent, {erx_facets_install, 5, data, ?ERX_SERVICE_FILES, {New, <<"data">>, ro}}),
        ?assertEqual({erx_facets_installed, 5}, answer()),
        ?assertEqual({3, #{echo => {?ERX_SERVICE_CONSOLE, Answer}, data => {?ERX_SERVICE_FILES, {New, <<"data">>, ro}}}},
                     persistent_term:get({erx, facets}))
    after
        persistent_term:erase({erx, facets}),
        [Pid ! stop || Pid <- [Answer, Old, New]]
    end.

untyped_facets_are_dropped(Agent) ->
    %% An installation that names no interface number, sent as {Tag, Name, Facet}, or
    %% that names none or 0, is dropped and counted and installs nothing; an entry of the
    %% ready answer that is a facet alone, a files facet's included, or whose interface
    %% is none or 0, is left out of the registry: every facet the registry holds carries the
    %% interface that keeps a display from the domain's programs
    %% (erx_facets:program_table/1).
    Facet = spawn(fun() -> receive stop -> ok end end),
    try
        record(Agent, {erx_facets, #{bare => Facet, files => {Facet, <<"files">>, rw}, untyped => {none, Facet},
                                     zero => {0, {Facet, <<"zero">>, rw}}}, []}),
        [record(Agent, Install) || Install <- [{erx_facets_install, 1, data, {Facet, <<"data">>, rw}},
                                               {erx_facets_install, 2, data, none, {Facet, <<"data">>, rw}},
                                               {erx_facets_install, 3, data, 0, {Facet, <<"data">>, rw}}]],
        record(Agent, {erx_facets_install, 4, echo, ?ERX_SERVICE_FILES, {Facet, <<"echo">>, rw}}),
        ?assertEqual({erx_facets_installed, 4}, answer()),
        ?assertEqual(3, erx_connections:dropped()),
        ?assertEqual({2, #{echo => {?ERX_SERVICE_FILES, {Facet, <<"echo">>, rw}}}}, persistent_term:get({erx, facets}))
    after
        persistent_term:erase({erx, facets}),
        Facet ! stop
    end.

drive_installs(Agent) ->
    %% A drive's grant is installed under its installed name, {drive, N}
    %% (docs/design-drives.md, "How the grant reaches the media domain"), and erx:cap/1
    %% finds it there; every other name that is no atom, a {drive, N} whose N is no
    %% drive number among them, is dropped and counted, and installs nothing.
    Facet = spawn(fun() -> receive stop -> ok end end),
    try
        record(Agent, {erx_facets, #{}, []}),
        [record(Agent, {erx_facets_install, 1, Name, ?ERX_SERVICE_DRIVE, Facet})
         || Name <- [{drive, -1}, {drive, x}, {drive, 1.0}, {disk, 0}, {drive, 0, 1}, {0, drive}]],
        record(Agent, {erx_facets_install, 2, {drive, 3}, ?ERX_SERVICE_DRIVE, Facet}),
        ?assertEqual({erx_facets_installed, 2}, answer()),
        ?assertEqual(6, erx_connections:dropped()),
        ?assertEqual({2, #{{drive, 3} => {?ERX_SERVICE_DRIVE, Facet}}}, persistent_term:get({erx, facets})),
        ?assertEqual(Facet, erx:cap({drive, 3})),
        ?assertEqual(undefined, erx:cap({drive, 4}))
    after
        persistent_term:erase({erx, facets}),
        Facet ! stop
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
                         {sides_only_from_service, fun sides_only_from_service/1},
                         {malformed_calls, fun malformed_calls/1}]].

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
      system_lane => 3, ctl_slots => 4, domain_pid_number => 40, domain_pid_serial => 0, supervised => false}.

%% open_side for the peer from a caller standing for the domain service, which makes
%% itself the agent's installer first, as the service does as it starts.
open_side() ->
    Test = self(),
    spawn(fun() ->
                  ok = erx_connections:become_installer(),
                  Test ! {side, erx_connections:open_side(?PEER, side_values())},
                  forward(Test)
          end).

%% Passes what the agent sends to the test, and closes the side when the test asks.
forward(Test) ->
    receive
        {close, Reason} -> Test ! {side, erx_connections:close_side(?PEER, Reason)}, forward(Test);
        Msg -> Test ! {side, Msg}, forward(Test)
    end.

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
    ?assertEqual({system_side_ended, ?PEER, killed}, side_answer(2000)).

sides_only_from_service(Agent) ->
    %% The system domain's agent opens and closes a side only for its installer, as it
    %% installs: open_side/2 and close_side/2 from any other process of its runtime are
    %% answered badarg, before any process is the installer and while one is, and open
    %% or end nothing, so no slip ends a domain's system connection. The installer's own
    %% close ends the side.
    ?assertEqual({error, badarg}, erx_connections:open_side(?PEER, side_values())),
    ?assertEqual(none, receive {opened, _, _} = Opened -> Opened after 200 -> none end),
    Service = open_side(),
    {_Command, Port} = opened(),
    {Port, _Owner} = accept(Agent, owner),
    Agent ! {erx_connection_inserted, ?PEER, Port},
    ?assertEqual({ok, Port}, side_answer(2000)),
    ?assertEqual({error, badarg}, erx_connections:close_side(?PEER, stopped)),
    ?assertEqual({error, badarg}, erx_connections:open_side(?PEER + 1, side_values())),
    ?assertEqual(none, side_answer(200)),
    ?assertNotEqual(undefined, erlang:port_info(Port)),
    Service ! {close, stopped},
    ?assertEqual(ok, side_answer(2000)),
    ?assertEqual(undefined, erlang:port_info(Port)).

malformed_calls(Agent) ->
    %% A call whose From is no pair is no call the agent takes, whatever it asks: it is
    %% dropped and counted, and the agent goes on serving, where a reply to it would end
    %% the agent, and so the runtime.
    Dropped = erx_connections:dropped(),
    Requests = [dropped, app, app_held, {connection, ?PEER}, {area, ?PEER}, {changed, 0},
                {grant, #{}}, become_installer, {close_side, ?PEER, stopped}, nothing],
    [Agent ! {'$gen_call', From, Request} || From <- [not_a_from, {self(), make_ref(), extra}], Request <- Requests],
    ?assertEqual(Dropped + 2 * length(Requests), erx_connections:dropped()),
    ?assert(is_process_alive(Agent)).

area_down(Agent) ->
    %% The agent maps the area with the connection and hands it out on open; on
    %% connection_down it ends the port at once but answers connection_unmapped only once
    %% the area is unmapped, which here the test says in the destructor's place; open
    %% answers none from the record on.
    {Port, Tag} = mapped_area(Agent),
    ?assertEqual({ok, {area, Tag}, 8192}, erx_connections:area(?PEER)),
    ?assertEqual({error, none}, erx_connections:area(99)),
    Watch = monitor(port, Port),
    record(Agent, {erx_connection_down, ?PEER, noconnection}),
    ?assertEqual(noconnection, receive {'DOWN', Watch, port, Port, R} -> R after 2000 -> timeout end),
    ?assertEqual(none, silent()),
    ?assertEqual({error, none}, erx_connections:area(?PEER)),
    Agent ! {erx_area_unmapped, make_ref()},
    ?assertEqual(none, silent()),
    Agent ! {erx_area_unmapped, Tag},
    ?assertEqual({erx_connection_unmapped, ?PEER}, answer()),
    ?assertEqual(0, erx_connections:dropped()).

area_lost(Agent) ->
    %% A port that ends by itself is answered connection_lost once the area is unmapped.
    {Port, Tag} = mapped_area(Agent),
    exit(Port, erx_lane_malformed),
    ?assertEqual(none, silent()),
    Agent ! {erx_area_unmapped, Tag},
    ?assertEqual({erx_connection_lost, ?PEER, malformed}, answer()).

area_lost_then_down(Agent) ->
    %% A connection_down that comes while connection_lost waits for the area is answered
    %% instead of it, with connection_unmapped, once the area is unmapped.
    {Port, Tag} = mapped_area(Agent),
    Watch = monitor(port, Port),
    exit(Port, erx_lane_malformed),
    receive {'DOWN', Watch, port, Port, _} -> ok end,
    record(Agent, {erx_connection_down, ?PEER, noconnection}),
    ?assertEqual(none, silent()),
    Agent ! {erx_area_unmapped, Tag},
    ?assertEqual({erx_connection_unmapped, ?PEER}, answer()),
    ?assertEqual(none, silent()).

area_collected() ->
    %% With erx_area:map/4 itself, over the host's stand-in NIF, the area is a real
    %% resource and nothing here plays its destructor: connection_unmapped comes only
    %% once the agent's collection between records has dropped the agent's own
    %% reference. The test drops the one open gave it before the connection goes down.
    %% The area is whole host pages, 16 KiB on some hosts.
    Test = self(),
    Agent = start(fun(Command) ->
                          Port = open_port({spawn, "cat"}, [binary]),
                          Test ! {opened, Command, Port},
                          Port
                  end, fun erx_area:map/4),
    try
        record(Agent, {erx_connection_up, ?PEER, ?PEER_NODE, 11, 12, 13, 9, 4096, 8192, {21, 65536, write}}),
        {_Command, Port} = opened(),
        {Port, _Owner} = accept(Agent, owner),
        Agent ! {erx_connection_inserted, ?PEER, Port},
        ?assertEqual({erx_connection_mapped, ?PEER}, answer()),
        ?assertMatch({ok, _Area, 65536}, erx_connections:area(?PEER)),
        erlang:garbage_collect(),
        record(Agent, {erx_connection_down, ?PEER, noconnection}),
        ?assertEqual({erx_connection_unmapped, ?PEER}, answer())
    after
        stop(Agent)
    end.

area_refused(Agent) ->
    %% An area the NIF refuses, or one of the wrong shape, refuses the connection before
    %% its port opens; one mapped before an open that fails waits for its unmap.
    record(Agent, {erx_connection_up, ?PEER, ?PEER_NODE, 11, 12, 13, 9, 4096, 8192, ?BAD_AREA}),
    ?assertEqual({erx_connection_lost, ?PEER, {map, refused}}, answer()),
    record(Agent, {erx_connection_up, ?PEER, ?PEER_NODE, 11, 12, 13, 9, 4096, 8192, {21, 8192, rw}}),
    ?assertEqual({erx_connection_lost, ?PEER, {map, refused}}, answer()),
    ?assertEqual(timeout, opened()),
    stop(Agent),
    Refusing = start(fun(_Command) -> error(badarg) end),
    try
        record(Refusing, {erx_connection_up, ?PEER, ?PEER_NODE, 11, 12, 13, 9, 4096, 8192, ?AREA}),
        Tag = area_mapped(),
        ?assertEqual(none, silent()),
        Refusing ! {erx_area_unmapped, Tag},
        ?assertEqual({erx_connection_lost, ?PEER, {map, refused}}, answer())
    after
        stop(Refusing)
    end.

%% The registry wait (docs/design-system.md, "Waiting for a grant"): the agent, the one
%% writer of the facet registry in every domain, answers each process waiting for an
%% installation (erx_facets:changed/1) after every one, and erx_facets:await/3 waits on
%% that in the caller. Each case runs on a domain's agent, installing as the system
%% domain's domain pid does, and those that hold in every domain also on the system
%% domain's, installing as the domain service does (erx_connections:grant/1). The
%% registry and the granted names start and end empty.
wait_test_() ->
    Both = [{answered_after_installation, fun answered_after_installation/2},
            {installed_before_request, fun installed_before_request/2},
            {second_request_answers_first, fun second_request_answers_first/2},
            {waiter_monitored, fun waiter_monitored/2}, {await_successor, fun await_successor/2},
            {await_timeout, fun await_timeout/2}],
    [{atom_to_list(Name), fun() -> with_registry(fun() -> with_agent(fun(A) -> Case(A, domain_install(A)) end) end) end}
     || {Name, Case} <- Both]
    ++ [{"system_" ++ atom_to_list(Name), fun() -> with_registry(fun() -> with_service(fun(A) -> Case(A, fun system_install/2) end) end) end}
        || {Name, Case} <- Both]
    ++ [{"granted_before_wake", fun() -> with_registry(fun() -> with_agent(fun granted_before_wake/1) end) end},
        {"empty_answer_raises", fun() -> with_registry(fun() -> with_agent(fun empty_answer_raises/1) end) end},
        {"install_refused_in_a_domain", fun() -> with_registry(fun() -> with_agent(fun install_refused/1) end) end},
        {"install_enveloped_refused", fun() -> with_registry(fun() -> with_service(fun install_enveloped_refused/1) end) end},
        {"install_only_from_domain_service", fun() -> with_registry(fun() -> with_sides(fun install_only_from_service/1) end) end}].

%% The system domain's agent, with the test process playing the domain service, the
%% agent's installer (erx_connections:become_installer/0).
with_service(Case) ->
    with_sides(fun(Agent) ->
                       ?assertEqual(ok, erx_connections:become_installer()),
                       Case(Agent)
               end).

with_registry(Case) ->
    Clear = fun() -> [persistent_term:erase(Key) || Key <- [{erx, facets}, {erx, granted}]] end,
    Clear(),
    try Case() after Clear() end.

%% An installation of Facet under Name as the system domain's domain pid sends one to a
%% domain's agent, returned once the agent has acknowledged it.
domain_install(Agent) ->
    fun(Name, Facet) ->
            Tag = erlang:unique_integer([positive]),
            record(Agent, {erx_facets_install, Tag, Name, ?ERX_SERVICE_CONSOLE, Facet}),
            ?assertEqual({erx_facets_installed, Tag}, answer())
    end.

%% An installation of Facet under Name as the domain service asks the system domain's agent.
system_install(Name, Facet) ->
    ?assertEqual(ok, erx_connections:grant(#{Name => {?ERX_SERVICE_CONSOLE, Facet}})).

%% A process that stands for a facet's server until the case kills it.
facet() ->
    spawn(fun() -> receive after infinity -> ok end end).

%% Whether Request's answer has come, without taking it or dropping the request. The
%% agent has acted on every message the test sent before, since it answers dropped/0 after
%% them.
answered(Request) ->
    _ = erx_connections:dropped(),
    {messages, Messages} = process_info(self(), messages),
    lists:any(fun(Message) -> gen:check_response(Message, Request) =/= no_reply end, Messages).

%% Waits until the agent monitors Pid, or no longer does when Monitored is false.
monitoring(Agent, Pid, Monitored) ->
    monitoring(Agent, Pid, Monitored, erlang:monotonic_time(millisecond) + 2000).

monitoring(Agent, Pid, Monitored, Deadline) ->
    {monitors, Monitors} = process_info(Agent, monitors),
    case lists:member({process, Pid}, Monitors) of
        Monitored -> ok;
        _ ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline),
            timer:sleep(5),
            monitoring(Agent, Pid, Monitored, Deadline)
    end.

answered_after_installation(_Agent, Install) ->
    %% A request for the current generation waits for the next installation.
    Facet = facet(),
    Request = erx_facets:changed(erx_facets:generation()),
    ?assertNot(answered(Request)),
    Install(data, Facet),
    ?assertEqual({reply, ok}, gen:receive_response(Request, 2000)),
    exit(Facet, kill).

installed_before_request(_Agent, Install) ->
    %% An installation between the waiter's read and its request answers the request at
    %% once: the agent compares the generation the request names with the registry's.
    Facet = facet(),
    Seen = erx_facets:generation(),
    Install(data, Facet),
    ?assertEqual({reply, ok}, gen:receive_response(erx_facets:changed(Seen), 1000)),
    exit(Facet, kill).

second_request_answers_first(_Agent, Install) ->
    %% One process's second request answers its first at once, and the second waits on.
    Facet = facet(),
    Seen = erx_facets:generation(),
    First = erx_facets:changed(Seen),
    Second = erx_facets:changed(Seen),
    ?assertEqual({reply, ok}, gen:receive_response(First, 1000)),
    ?assertNot(answered(Second)),
    Install(data, Facet),
    ?assertEqual({reply, ok}, gen:receive_response(Second, 2000)),
    exit(Facet, kill).

waiter_monitored(Agent, Install) ->
    %% The agent monitors each waiting asker and no longer once it has answered it, and
    %% takes an unanswered asker's end without counting it as dropped.
    Test = self(),
    Facet = facet(),
    Seen = erx_facets:generation(),
    Waiter = spawn(fun() -> Test ! {woke, gen:receive_response(erx_facets:changed(Seen), infinity)} end),
    monitoring(Agent, Waiter, true),
    Install(data, Facet),
    ?assertEqual({reply, ok}, receive {woke, Woke} -> Woke after 2000 -> timeout end),
    monitoring(Agent, Waiter, false),
    Asker = spawn(fun() -> gen:receive_response(erx_facets:changed(erx_facets:generation()), infinity) end),
    monitoring(Agent, Asker, true),
    Dropped = erx_connections:dropped(),
    exit(Asker, kill),
    monitoring(Agent, Asker, false),
    ?assertEqual(Dropped, erx_connections:dropped()),
    exit(Facet, kill).

await_successor(Agent, Install) ->
    %% await/3 with Seen the facet it followed is not answered while the registry holds
    %% that facet, nor by an installation of another name, and is answered with the
    %% successor's; with none, a facet in place answers at once.
    Test = self(),
    [Old, New, Other] = [facet() || _ <- [1, 2, 3]],
    Install(data, Old),
    ?assertEqual({ok, Old}, erx_facets:await(data, none, 0)),
    Waiter = spawn(fun() -> Test ! {awaited, erx_facets:await(data, Old, 5000)} end),
    monitoring(Agent, Waiter, true),
    Install(other, Other),
    monitoring(Agent, Waiter, true),
    ?assertEqual(none, receive {awaited, Early} -> Early after 0 -> none end),
    Install(data, New),
    ?assertEqual({ok, New}, receive {awaited, Awaited} -> Awaited after 2000 -> timeout end),
    [exit(Pid, kill) || Pid <- [Old, New, Other]].

await_timeout(_Agent, Install) ->
    %% await/3 answers timeout at its deadline, in milliseconds or absolute, and an
    %% installation after it leaves nothing in the caller's mailbox.
    Facet = facet(),
    ?assertEqual(timeout, erx_facets:await(data, none, 50)),
    ?assertEqual(timeout, erx_facets:await(data, none, {abs, erlang:monotonic_time(millisecond) + 50})),
    Install(data, Facet),
    _ = erx_connections:dropped(),
    ?assertEqual({messages, []}, process_info(self(), messages)),
    exit(Facet, kill).

granted_before_wake(Agent) ->
    %% The ready answer writes its granted names before the installation that wakes a
    %% waiter, so a waiter woken by it reads them. The agent's writes and sends are
    %% traced to the test in the order the agent makes them, which makes the order
    %% checkable whatever the schedulers do.
    Test = self(),
    Seen = erx_facets:generation(),
    Waiter = spawn(fun() ->
                           {reply, ok} = gen:receive_response(erx_facets:changed(Seen), infinity),
                           Test ! {granted, erx:granted()}
                   end),
    monitoring(Agent, Waiter, true),
    erlang:trace_pattern({persistent_term, put, 2}, true, [global]),
    erlang:trace(Agent, true, [call, send]),
    try
        record(Agent, {erx_facets, #{}, [{data, 5}]}),
        ?assertEqual({granted, [data]}, receive {granted, _} = Granted -> Granted after 2000 -> timeout end),
        ?assertMatch([{put, {erx, granted}}, {put, {erx, facets}}, woke | _], agent_effects())
    after
        erlang:trace(Agent, false, [call, send]),
        erlang:trace_pattern({persistent_term, put, 2}, false, [global])
    end.

%% The agent's persistent_term writes and its answers, in order, from the trace: every
%% send but init's facets is the answer to the one waiter, which goes to its request's
%% alias rather than to its pid.
agent_effects() ->
    receive
        {trace, _, call, {persistent_term, put, [Key, _]}} -> [{put, Key} | agent_effects()];
        {trace, _, send, {erx_facets, _}, _} -> agent_effects();
        {trace, _, send, _, _} -> [woke | agent_effects()]
    after 200 -> []
    end.

empty_answer_raises(Agent) ->
    %% A ready answer that installs no facet is an installation still: it raises the
    %% generation, so a waiter on the granted names alone is answered.
    Seen = erx_facets:generation(),
    record(Agent, {erx_facets, #{}, [{data, 5}]}),
    ?assertEqual({reply, ok}, gen:receive_response(erx_facets:changed(Seen), 1000)),
    ?assertEqual(Seen + 1, erx_facets:generation()).

install_refused(_Agent) ->
    %% A domain's installations come from the system domain over its connection, so its
    %% agent answers grant/1, and the claim to be its installer, badarg and installs
    %% nothing.
    Facet = facet(),
    ?assertEqual({error, badarg}, erx_connections:become_installer()),
    ?assertEqual({error, badarg}, erx_connections:grant(#{forged => Facet})),
    ?assertEqual(undefined, erx_facets:find(forged)),
    ?assertEqual(0, erx_facets:generation()),
    exit(Facet, kill).

install_enveloped_refused(Agent) ->
    %% The system domain's agent installs what the domain service asks and answers after;
    %% the same request, and a request to hear of an installation, in another domain's
    %% envelope are no calls it takes: dropped and counted, installing and answering
    %% nothing. A generation that is no non-negative integer is answered badarg.
    Facet = facet(),
    ?assertEqual(ok, erx_connections:grant(#{echo => {?ERX_SERVICE_CONSOLE, Facet}})),
    ?assertEqual(Facet, erx_facets:find(echo)),
    Dropped = erx_connections:dropped(),
    Agent ! {erx_origin, ?PEER, {'$gen_call', {self(), make_ref()}, {install, #{forged => Facet}}}},
    Agent ! {erx_origin, ?PEER, {'$gen_call', {self(), make_ref()}, {changed, 0}}},
    ?assertEqual(Dropped + 2, erx_connections:dropped()),
    ?assertEqual(undefined, erx_facets:find(forged)),
    ?assertEqual(1, erx_facets:generation()),
    ?assertEqual({messages, []}, process_info(self(), messages)),
    ?assertEqual({reply, {error, badarg}}, gen:receive_response(erx_facets:changed(-1), 1000)),
    ?assertEqual({reply, {error, badarg}}, gen:receive_response(erx_facets:changed(none), 1000)),
    exit(Facet, kill).

install_only_from_service(Agent) ->
    %% The system domain's agent installs only what its installer asks: grant/1 from any
    %% other process of its runtime, the raw call and one naming no pid included, is
    %% answered badarg and installs nothing, before any process is the installer and while
    %% one is. No second process becomes the installer, while the first lives or after
    %% it has ended, since the domain service is never restarted.
    Facet = facet(),
    Refused = fun() ->
                      ?assertEqual({error, badarg}, erx_connections:grant(#{forged => Facet})),
                      Tag = make_ref(),
                      Agent ! {'$gen_call', {self(), Tag}, {install, #{forged => Facet}}},
                      receive {Tag, Reply} -> ?assertEqual({error, badarg}, Reply) end
              end,
    Refused(),
    Agent ! {'$gen_call', {undefined, make_ref()}, {install, #{forged => Facet}}},
    Test = self(),
    {Service, Ended} = spawn_monitor(fun() ->
                                             ok = erx_connections:become_installer(),
                                             Test ! {service, self()},
                                             receive install -> Test ! {installed, erx_connections:grant(#{echo => {?ERX_SERVICE_CONSOLE, Facet}})} end
                                     end),
    receive {service, Service} -> ok end,
    ?assertEqual({error, badarg}, erx_connections:become_installer()),
    Refused(),
    ?assertEqual(undefined, erx_facets:find(forged)),
    ?assertEqual(0, erx_facets:generation()),
    Service ! install,
    receive {installed, Installed} -> ?assertEqual(ok, Installed) end,
    ?assertEqual(Facet, erx_facets:find(echo)),
    receive {'DOWN', Ended, process, Service, normal} -> ok end,
    ?assertEqual({error, badarg}, erx_connections:become_installer()),
    Refused(),
    exit(Facet, kill).
