%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_domain_links, the domain service's pure core for the
%% connection protocol: a few named scenarios, then an exhaustive
%% exploration of the scope of specs/tla/Connection.tla.
%%
%% The explorer drives the core from a model of its environment written
%% independently of it, after the model's actions for domain A and its
%% peers: one domain A, the survivor, and two incarnations of a peer node
%% name, peer 1 and peer 2, which starts once the service has learnt that
%% peer 1 ended. Connection C joins A and peer C. Each party reads the
%% records the core sends it in order, answers as the runtime's connection
%% agent does, and the peer writes up to two frames that A delivers and
%% drains. Every step the model allows is taken from every reachable state,
%% breadth first, and these hold in every state:
%%
%% * one_control_record: at most one record the core sent a party is
%%   unanswered, which the reserve of the party's lane holds;
%% * one_entry: A never maps two connections of the peer name at once;
%% * no_use_after_delete: no party maps a connection whose objects the core
%%   deleted, and the core deletes each connection once;
%% * let_go_deleted: a connection both parties have let go is deleted;
%% * every record goes to a party that is ready and not ended, and a
%%   connection_down only to a party that was sent the connection_up;
%% * a connection_up carries what connect/4 was given for its party, and
%%   a connection_down the reason of the step that closed the connection;
%% * an honest party's answers are all applied, none dropped.
%%
%% A party that cannot map a connection_up answers it with connection_lost
%% alone; told connection_down about it all the same, as only a hostile
%% party's answer can make the core do, it answers connection_unmapped at
%% once, having mapped nothing, which an honest run would count as dropped.
%%
%% A state with no step left is the end of a run: there every connection is
%% deleted and forgotten, and nothing is queued or owed. The hostile runs
%% let one side also send, once, any well-formed answer at any moment, as
%% well as every honest one, and check what the other, honest side relies
%% on: its own properties, and that none of its answers is dropped.
-module(erx_domain_links_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, 10).
-define(A_NAME, 'a@host').
-define(PEER_NAME, 'p@host').
-define(FRAMES, 2).
-define(HOSTILE_ANSWERS, 1).

peer_id(C) -> ?A + C.

%% Scenarios.

nothing_goes_before_ready_test() ->
    S0 = core([?A, 11]),
    {Connected, S1} = erx_domain_links:connect(c1, {?A, up_a}, {11, up_p}, S0),
    ?assertEqual([], Connected),
    ?assertEqual(up_pending, erx_domain_links:phase(?A, 11, S1)),
    {Ready, _} = erx_domain_links:ready(?A, S1),
    ?assertEqual([{send, ?A, 0, {connection_up, 11, ?PEER_NAME, up_a}}], Ready).

%% A later domain of a name reaches A only once A has answered the earlier
%% connection's connection_down; the earlier connection is deleted first.
later_incarnation_waits_for_the_earlier_down_test() ->
    S0 = ready_all(core([?A, 11]), [?A, 11]),
    {_, S1} = erx_domain_links:connect(c1, {?A, up_a1}, {11, up_p1}, S0),
    {[], S2} = erx_domain_links:answer(?A, {connection_mapped, 11}, S1),
    {[], S3} = erx_domain_links:answer(11, {connection_mapped, ?A}, S2),
    ?assertEqual(up, erx_domain_links:phase(?A, 11, S3)),

    {Down, S4} = erx_domain_links:ended(11, crash, S3),
    ?assertEqual([{send, ?A, 0, {connection_down, 11, {domain_down, 11, crash}}}], Down),
    S5 = erx_domain_links:add_party(12, ?PEER_NAME, 4, S4),
    {Ready, S6} = erx_domain_links:ready(12, S5),
    {Connected, S7} = erx_domain_links:connect(c2, {?A, up_a2}, {12, up_p2}, S6),
    ?assertEqual([], Ready),
    ?assertEqual([{send, 12, 0, {connection_up, ?A, ?A_NAME, up_p2}}], Connected),
    ?assertEqual(2, erx_domain_links:held(?A, S7)),

    {Unmapped, S8} = erx_domain_links:answer(?A, {connection_unmapped, 11}, S7),
    ?assertEqual([{disconnect, c1}, {send, ?A, 0, {connection_up, 12, ?PEER_NAME, up_a2}}],
                 Unmapped),
    ?assertEqual(none, erx_domain_links:phase(?A, 11, S8)),
    ?assertEqual(1, erx_domain_links:held(?A, S8)).

%% A connection whose objects are deleted still counts against a party
%% that owes its connection_down an answer, which the reserve of its lane
%% still holds.
deleted_connection_counts_until_answered_test() ->
    S0 = ready_all(core([?A, 11]), [?A, 11]),
    {_, S1} = erx_domain_links:connect(c1, {?A, a}, {11, p}, S0),
    {_, S2} = erx_domain_links:answer(?A, {connection_mapped, 11}, S1),
    {_, S3} = erx_domain_links:answer(11, {connection_mapped, ?A}, S2),
    {_, S4} = erx_domain_links:close(?A, 11, S3),
    {[], S5} = erx_domain_links:answer(?A, {connection_lost, 11, malformed}, S4),
    {Deleted, S6} = erx_domain_links:answer(11, {connection_unmapped, ?A}, S5),
    ?assertEqual([{disconnect, c1}], Deleted),
    ?assertEqual({gone, 1, 0}, {erx_domain_links:phase(?A, 11, S6), erx_domain_links:held(?A, S6),
                                erx_domain_links:held(11, S6)}),
    {[], S7} = erx_domain_links:answer(?A, {connection_unmapped, 11}, S6),
    ?assertEqual({none, 0}, {erx_domain_links:phase(?A, 11, S7), erx_domain_links:held(?A, S7)}).

%% The init's ready report may arrive after the fault gate's end.
ready_after_end_is_nothing_test() ->
    S0 = core([?A, 11]),
    {[], S1} = erx_domain_links:ended(11, crash, S0),
    ?assertEqual({[], S1}, erx_domain_links:ready(11, S1)).

%% A survivor that never answers its connection_down keeps the connection
%% closing, with its objects, whatever else happens.
survivor_that_never_answers_keeps_the_connection_test() ->
    S0 = ready_all(core([?A, 11]), [?A, 11]),
    {_, S1} = erx_domain_links:connect(c1, {?A, a}, {11, p}, S0),
    {_, S2} = erx_domain_links:answer(?A, {connection_mapped, 11}, S1),
    {_, S3} = erx_domain_links:answer(11, {connection_mapped, ?A}, S2),
    {_, S4} = erx_domain_links:ended(11, stopped, S3),
    {Again, S5} = erx_domain_links:close(?A, 11, S4),
    ?assertEqual([], Again),
    ?assertEqual(closing, erx_domain_links:phase(?A, 11, S5)).

%% Answers out of turn (connection_unmapped while connection_up is
%% unanswered among them), about connections that do not exist, malformed,
%% or from a party not held change nothing but the count.
unexpected_answers_are_dropped_and_counted_test() ->
    S0 = ready_all(core([?A, 11]), [?A, 11]),
    {_, S1} = erx_domain_links:connect(c1, {?A, a}, {11, p}, S0),
    Stray = [{connection_unmapped, 11}, {connection_mapped, 12}, {connection_mapped, ?A},
             {connection_lost, 11}, {connection_lost, 12, early}, {connection_mapped, 11, extra}, junk,
             {connection_mapped, binary:copy(<<"x">>, 64)}],
    S2 = lists:foldl(fun(Answer, S) -> {[], Next} = erx_domain_links:answer(?A, Answer, S), Next end,
                     S1, Stray),
    {[], S3} = erx_domain_links:answer(99, {connection_mapped, ?A}, S2),
    ?assertEqual(#{?A => length(Stray), 11 => 0, unknown => 1}, erx_domain_links:dropped(S3)),
    ?assertEqual(up_pending, erx_domain_links:phase(?A, 11, S3)),
    {[], S4} = erx_domain_links:answer(?A, {connection_mapped, 11}, S3),
    ?assertEqual(#{?A => length(Stray), 11 => 0, unknown => 1}, erx_domain_links:dropped(S4)).

core(Parties) ->
    lists:foldl(fun(?A, S) -> erx_domain_links:add_party(?A, ?A_NAME, 4, S);
                   (P, S) -> erx_domain_links:add_party(P, ?PEER_NAME, 4, S)
                end, erx_domain_links:new(), Parties).

ready_all(S0, Parties) ->
    lists:foldl(fun(P, S) -> {[], Next} = erx_domain_links:ready(P, S), Next end, S0, Parties).

%% A party that cannot map its connection_up answers connection_lost alone,
%% which frees its slot and closes the connection: the peer that mapped is
%% told connection_down, and the objects go once it has unmapped.
failed_map_closes_the_connection_test() ->
    S0 = ready_all(core([?A, 11]), [?A, 11]),
    {[{send, ?A, 0, _}, {send, 11, 0, _}], S1} = erx_domain_links:connect(c1, {?A, up_a}, {11, up_p}, S0),
    {[], S2} = erx_domain_links:answer(?A, {connection_mapped, 11}, S1),
    {Lost, S3} = erx_domain_links:answer(11, {connection_lost, ?A, {map, enomem}}, S2),
    ?assertEqual([{send, ?A, 0, {connection_down, 11, noconnection}}], Lost),
    ?assertEqual(closing, erx_domain_links:phase(?A, 11, S3)),
    ?assertEqual(0, erx_domain_links:held(11, S3)),
    ?assertEqual(#{?A => 0, 11 => 0, unknown => 0}, erx_domain_links:dropped(S3)),
    {Unmapped, S4} = erx_domain_links:answer(?A, {connection_unmapped, 11}, S3),
    ?assertEqual([{disconnect, c1}], Unmapped),
    ?assertEqual(none, erx_domain_links:phase(?A, 11, S4)).

%% Exhaustive exploration.

explore_honest_test_() ->
    {timeout, 600, fun() -> explore_and_report(honest) end}.

explore_hostile_survivor_test_() ->
    {timeout, 600, fun() -> explore_and_report({hostile, a}) end}.

explore_hostile_peers_test_() ->
    {timeout, 600, fun() -> explore_and_report({hostile, peers}) end}.

%% Every property holds in every reachable state, and the runs reach the
%% cases the properties are about: a later incarnation's connection up at A
%% after the earlier one's end, a connection that closes before A is told
%% of it, A ending a connection while its connection_down is on the way, and
%% A failing to map a connection_up.
explore_and_report(Mode) ->
    case explore(Mode) of
        {ok, #{states := States, transitions := Transitions, ends := Ends, depth := Depth,
               witnesses := Witnesses}} ->
            io:format(user, "~nerx_domain_links ~p: ~b states, ~b transitions, ~b ends, depth ~b~n",
                      [Mode, States, Transitions, Ends, Depth]),
            ?assertEqual([a_lost_with_down_sent, later_up_at_a, map_failed_at_a, untold_at_a],
                         lists:sort(maps:keys(Witnesses)));
        {violation, Name, Trace} ->
            io:format(user, "~nerx_domain_links ~p: violation ~p after~n~p~n", [Mode, Name, Trace]),
            ?assertEqual(no_violation, Name)
    end.

explore(Mode) ->
    Init = initial(Mode),
    Stats = #{states => 1, transitions => 0, ends => 0, depth => 0, witnesses => #{}},
    try
        check(Init, Mode),
        bfs([{Init, []}], [], #{Init => true}, Stats, Mode)
    catch
        throw:{violation, Name, Trace} -> {violation, Name, Trace}
    end.

%% Breadth first over Level, the states at one depth with the reversed
%% trace that reached each, collecting the next depth's new states in Next.
bfs([], [], _Seen, Stats, _Mode) ->
    {ok, Stats};
bfs([], Next, Seen, #{depth := Depth} = Stats, Mode) ->
    bfs(Next, [], Seen, Stats#{depth := Depth + 1}, Mode);
bfs([{State, Trace} | Level], Next0, Seen0, Stats0, Mode) ->
    case steps(State, Mode) of
        [] ->
            run_end(State, Trace),
            bfs(Level, Next0, Seen0, maps:update_with(ends, fun(N) -> N + 1 end, Stats0), Mode);
        Steps ->
            {Next, Seen, Stats} =
                lists:foldl(fun(Step, Acc) -> visit(Step, State, Trace, Mode, Acc) end,
                            {Next0, Seen0, Stats0}, Steps),
            bfs(Level, Next, Seen, Stats, Mode)
    end.

%% Take one step from State, check the state it leads to, and queue it if
%% it is new.
visit({Label, Step}, State, Trace, Mode, {Next, Seen, #{transitions := T} = Stats}) ->
    Here = [Label | Trace],
    After = within(fun() -> Step(State) end, Here),
    within(fun() -> check(After, Mode) end, Here),
    Counted = Stats#{transitions := T + 1},
    case is_map_key(After, Seen) of
        true ->
            {Next, Seen, Counted};
        false ->
            #{states := N, witnesses := Witnesses} = Counted,
            Found = maps:from_keys(witnesses(After), true),
            {[{After, Here} | Next], Seen#{After => true},
             Counted#{states := N + 1, witnesses := maps:merge(Witnesses, Found)}}
    end.

%% Run Fun for a step reached by Trace; a violation or a crash of the core
%% names the trace to it.
within(Fun, Trace) ->
    try
        Fun()
    catch
        throw:{violation, Name} -> throw({violation, Name, lists:reverse(Trace)});
        error:Reason:Stack -> throw({violation, {crash, Reason, Stack}, lists:reverse(Trace)})
    end.

violation(Name) -> throw({violation, Name}).

%% The environment's state.

%% The fields, after Connection.tla's variables. Connections are named by
%% their index C, 1 or 2, which is also the handle connect/4 is given;
%% parties by their ids, ?A and peer_id(C).
%%
%% * core: the core under test.
%% * a: domain A. ready: its init reported ready; inbox: the records sent to
%%   it, unread, in order; conn: its view of C, none, mapped, draining
%%   (told connection_down, delivering up to drainto), gone (answered
%%   connection_unmapped), lost (ended C itself) or failed (could not map
%%   C's connection_up and answered connection_lost); deliv: frames of C's
%%   lane delivered; drainto: the wpos A read at C's connection_down.
%% * peers: peer C. life: unborn, alive or ended; learnt: the service
%%   learnt of its end; ready, inbox: as for A; answer: its last answer,
%%   none, mapped, unmapped, lost or failed (connection_lost to the
%%   connection_up, which it could not map); sent: frames it wrote to A; introduced,
%%   deleted: connect/4 was called for C, its disconnect performed; policy:
%%   policy closed C; closed: false, or the reason connection_down must
%%   carry, from the first environment step that closed C.
%% * owed: per party, records sent to it that it has not answered.
%% * told: {Party, C} => up or down, the last record about C sent to Party.
%% * hostile: answers the hostile side may still send.
%% * mode: honest or {hostile, a | peers}, constant.
initial(Mode) ->
    Core = core([?A, peer_id(1)]),
    Peer = #{life => unborn, learnt => false, ready => false, inbox => [], answer => none,
             sent => 0, introduced => false, closed => false, policy => false, deleted => false},
    #{core => Core,
      a => #{ready => false, inbox => [], conn => #{1 => none, 2 => none},
             deliv => #{1 => 0, 2 => 0}, drainto => #{1 => 0, 2 => 0}},
      peers => #{1 => Peer#{life := alive}, 2 => Peer},
      owed => #{?A => 0, peer_id(1) => 0, peer_id(2) => 0},
      told => #{},
      hostile => case Mode of honest -> 0; {hostile, _} -> ?HOSTILE_ANSWERS end,
      mode => Mode}.

peer(C, #{peers := Peers}) -> maps:get(C, Peers).

set_peer(C, Fields, #{peers := Peers} = S) ->
    S#{peers := Peers#{C := maps:merge(maps:get(C, Peers), Fields)}}.

set_a(Fields, #{a := A} = S) -> S#{a := maps:merge(A, Fields)}.

a_conn(C, #{a := #{conn := Conn}}) -> maps:get(C, Conn).

set_a_conn(C, Value, #{a := #{conn := Conn}} = S) -> set_a(#{conn => Conn#{C := Value}}, S).

answered(Party, #{owed := Owed} = S) ->
    S#{owed := Owed#{Party := maps:get(Party, Owed) - 1}}.

%% Calls into the core, then performs the actions it returned as the
%% domain service would, checking each.
call(Fun, #{core := Core} = S) ->
    {Actions, Next} = Fun(Core),
    lists:foldl(fun perform/2, S#{core := Next}, Actions).

perform({send, Party, Slot, Record}, S) ->
    Slot >= 0 andalso Slot < 4 orelse violation({slot_out_of_table, Party, Slot}),
    C = record_connection(Party, Record),
    check_recipient(Party, S),
    Told = told(Party, C, Record, S),
    #{owed := Owed} = S,
    Delivered = case Party of
                    ?A -> set_a(#{inbox => maps:get(inbox, maps:get(a, S)) ++ [Record]}, S);
                    _ -> set_peer(C, #{inbox => maps:get(inbox, peer(C, S)) ++ [Record]}, S)
                end,
    Delivered#{owed := Owed#{Party := maps:get(Party, Owed) + 1}, told := Told};
perform({disconnect, C}, S) ->
    case peer(C, S) of
        #{introduced := true, deleted := false} -> set_peer(C, #{deleted => true}, S);
        #{} -> violation({deleted_twice_or_unknown, C})
    end.

record_connection(?A, Record) -> element(2, Record) - ?A;
record_connection(Party, _Record) -> Party - ?A.

check_recipient(?A, #{a := #{ready := true}}) -> ok;
check_recipient(?A, _) -> violation({sent_before_ready, ?A});
check_recipient(Party, S) ->
    case peer(Party - ?A, S) of
        #{learnt := true} -> violation({sent_after_end, Party});
        #{ready := false} -> violation({sent_before_ready, Party});
        #{} -> ok
    end.

%% connection_up goes once per party and connection and carries what
%% connect/4 was given for that party; connection_down follows it, once.
told(Party, C, {connection_up, _, _, _} = Record, #{told := Told}) ->
    Record =:= expected_up(Party, C) orelse violation({wrong_up, Record}),
    case Told of
        #{{Party, C} := _} -> violation({second_up, Party, C});
        #{} -> Told#{{Party, C} => up}
    end;
told(Party, C, {connection_down, _, Reason}, #{told := Told} = S) ->
    check_reason(Party, C, Reason, S),
    case Told of
        #{{Party, C} := up} -> Told#{{Party, C} := down};
        #{} -> violation({unexpected_down, Party, C})
    end.

expected_up(?A, C) -> {connection_up, peer_id(C), ?PEER_NAME, {up, a, C}};
expected_up(_Peer, C) -> {connection_up, ?A, ?A_NAME, {up, p, C}}.

%% The reason is the one the first close called for. A hostile answer can
%% close a connection unseen by the environment, so only honest runs check.
check_reason(Party, C, Reason, #{mode := honest} = S) ->
    case peer(C, S) of
        #{closed := Reason} -> ok;
        #{closed := Expected} -> violation({wrong_reason, Party, C, Reason, Expected})
    end;
check_reason(_Party, _C, _Reason, _S) ->
    ok.

%% Steps.

steps(S, Mode) ->
    lists:append([survivor_steps(S), peer_steps(S), service_steps(S), hostile_steps(S, Mode)]).

%% Domain A's connection agent and lane ports.
survivor_steps(#{a := #{ready := false}}) ->
    [{a_ready, fun(S) -> call(fun(Core) -> erx_domain_links:ready(?A, Core) end,
                              set_a(#{ready => true}, S)) end}];
survivor_steps(#{a := #{inbox := Inbox}} = S) ->
    read_steps(Inbox) ++ lists:append([lane_steps(C, S) || C <- [1, 2]]).

read_steps([]) ->
    [];
read_steps([{connection_up, Peer, _, _} | _]) ->
    C = Peer - ?A,
    [{{a_map, C}, fun(S) -> a_answer({connection_mapped, Peer}, pop_a(set_a_conn(C, mapped, S))) end},
     {{a_map_fails, C}, fun(S) -> a_answer({connection_lost, Peer, {map, enomem}},
                                           pop_a(set_a_conn(C, failed, close_env(C, noconnection, S)))) end}];
read_steps([{connection_down, Peer, Reason} | _]) ->
    C = Peer - ?A,
    [{{a_down, C}, fun(S) ->
                           case a_conn(C, S) of
                               Unmapped when Unmapped =:= lost; Unmapped =:= failed ->
                                   a_answer({connection_unmapped, Peer}, pop_a(S));
                               mapped -> start_drain(C, Reason, pop_a(S))
                           end
                   end}].

start_drain(C, _Reason, #{a := #{drainto := DrainTo}} = S) ->
    #{sent := Sent} = peer(C, S),
    set_a_conn(C, draining, set_a(#{drainto => DrainTo#{C := Sent}}, S)).

lane_steps(C, #{a := #{deliv := Deliv, drainto := DrainTo}} = S) ->
    #{sent := Sent} = peer(C, S),
    Delivered = maps:get(C, Deliv),
    Target = maps:get(C, DrainTo),
    Deliver = [{{a_deliver, C}, fun(St) -> set_a(#{deliv => Deliv#{C := Delivered + 1}}, St) end}
               || lists:member(a_conn(C, S), [mapped, draining]), Delivered < Sent,
                  a_conn(C, S) =/= draining orelse Delivered < Target],
    Finish = [{{a_finish, C}, fun(St) -> a_answer({connection_unmapped, peer_id(C)},
                                                  set_a_conn(C, gone, St)) end}
              || a_conn(C, S) =:= draining, Delivered =:= Target],
    Lose = [{{a_lose, C}, fun(St) -> a_answer({connection_lost, peer_id(C), malformed},
                                              set_a_conn(C, lost, close_env(C, noconnection, St))) end}
            || a_conn(C, S) =:= mapped],
    Deliver ++ Finish ++ Lose.

pop_a(#{a := #{inbox := [_ | Rest]}} = S) -> set_a(#{inbox => Rest}, S).

%% Only an answer to a record settles it: connection_lost answers a
%% connection_up the party could not map, which it answers with that alone
%% (docs/design-domains.md, "Messages between the domain service and a
%% runtime"), and nothing otherwise.
a_answer({connection_lost, _, {map, _}} = Answer, S) ->
    call(fun(Core) -> erx_domain_links:answer(?A, Answer, Core) end, answered(?A, S));
a_answer({connection_lost, _, _} = Answer, S) ->
    call(fun(Core) -> erx_domain_links:answer(?A, Answer, Core) end, S);
a_answer(Answer, S) ->
    call(fun(Core) -> erx_domain_links:answer(?A, Answer, Core) end, answered(?A, S)).

%% Each peer's connection agent: it maps on connection_up, writes its
%% frames, may end the connection itself, unmaps on connection_down, and
%% may end at any moment, after which it does nothing.
peer_steps(S) ->
    lists:append([one_peer_steps(C, peer(C, S)) || C <- [1, 2]]).

one_peer_steps(C, #{life := alive} = Peer) ->
    #{ready := Ready, inbox := Inbox, answer := Answer, sent := Sent} = Peer,
    [{{p_ready, C}, fun(S) -> call(fun(Core) -> erx_domain_links:ready(peer_id(C), Core) end,
                                   set_peer(C, #{ready => true}, S)) end} || not Ready]
        ++ peer_read_steps(C, Inbox, Answer)
        ++ [{{p_write, C}, fun(S) -> set_peer(C, #{sent => Sent + 1}, S) end}
            || Answer =:= mapped, Sent < ?FRAMES]
        ++ [{{p_lose, C}, fun(S) -> p_answer(C, {connection_lost, ?A, malformed},
                                             set_peer(C, #{answer => lost}, close_env(C, noconnection, S))) end}
            || Answer =:= mapped]
        ++ [{{p_end, C}, fun(S) -> set_peer(C, #{life => ended}, S) end}];
one_peer_steps(_C, _Peer) ->
    [].

peer_read_steps(_C, [], _Answer) ->
    [];
peer_read_steps(C, [{connection_up, ?A, _, _} | Rest], none) ->
    [{{p_map, C}, fun(S) -> p_answer(C, {connection_mapped, ?A},
                                     set_peer(C, #{inbox => Rest, answer => mapped}, S)) end},
     {{p_map_fails, C}, fun(S) -> p_answer(C, {connection_lost, ?A, {map, enomem}},
                                           set_peer(C, #{inbox => Rest, answer => failed},
                                                    close_env(C, noconnection, S))) end}];
peer_read_steps(C, [{connection_down, ?A, _} | Rest], Unmapped) when Unmapped =:= lost; Unmapped =:= failed ->
    [{{p_down, C}, fun(S) -> p_answer(C, {connection_unmapped, ?A}, set_peer(C, #{inbox => Rest}, S)) end}];
peer_read_steps(C, [{connection_down, ?A, _} | Rest], mapped) ->
    [{{p_unmap, C}, fun(S) -> p_answer(C, {connection_unmapped, ?A},
                                       set_peer(C, #{inbox => Rest, answer => unmapped}, S)) end}].

p_answer(C, {connection_lost, _, {map, _}} = Answer, S) ->
    call(fun(Core) -> erx_domain_links:answer(peer_id(C), Answer, Core) end,
         answered(peer_id(C), S));
p_answer(C, {connection_lost, _, _} = Answer, S) ->
    call(fun(Core) -> erx_domain_links:answer(peer_id(C), Answer, Core) end, S);
p_answer(C, Answer, S) ->
    call(fun(Core) -> erx_domain_links:answer(peer_id(C), Answer, Core) end,
         answered(peer_id(C), S)).

%% C closed, with the reason its connection_down carries, unless an earlier
%% step closed it already. It is set before the core is called, so the
%% record it sends is checked against it.
close_env(C, Reason, S) ->
    case peer(C, S) of
        #{closed := false} -> set_peer(C, #{closed => Reason}, S);
        #{} -> S
    end.

%% The domain service's own events: introductions, a peer's end learnt
%% through the fault gate, the later incarnation's start, and policy.
service_steps(S) ->
    lists:append([connection_service_steps(C, peer(C, S)) || C <- [1, 2]])
        ++ [{p_start, fun(St) -> set_peer(2, #{life => alive},
                                          St#{core := erx_domain_links:add_party(
                                                          peer_id(2), ?PEER_NAME, 4, maps:get(core, St))})
                      end}
            || maps:get(learnt, peer(1, S)), maps:get(life, peer(2, S)) =:= unborn].

connection_service_steps(C, Peer) ->
    #{life := Life, learnt := Learnt, introduced := Introduced, deleted := Deleted,
      policy := Policy} = Peer,
    Id = peer_id(C),
    [{{introduce, C}, fun(S) -> call(fun(Core) -> erx_domain_links:connect(
                                                    C, {?A, {up, a, C}}, {Id, {up, p, C}}, Core) end,
                                     set_peer(C, #{introduced => true}, S)) end}
     || Life =/= unborn, not Learnt, not Introduced]
        ++ [{{learn_end, C}, fun(S) -> call(fun(Core) -> erx_domain_links:ended(Id, crash, Core) end,
                                            close_env(C, {domain_down, Id, crash}, set_peer(C, #{learnt => true}, S))) end}
            || Life =:= ended, not Learnt]
        ++ [{{policy, C}, fun(S) -> call(fun(Core) -> erx_domain_links:close(?A, Id, Core) end,
                                         close_env(C, noconnection, set_peer(C, #{policy => true}, S))) end}
            || Introduced, not Deleted, not Policy].

%% A hostile party may also send any of these answers at any moment.
hostile_steps(_S, honest) ->
    [];
hostile_steps(#{hostile := 0}, _Mode) ->
    [];
hostile_steps(#{hostile := Left}, {hostile, Who}) ->
    [{{hostile, From, Answer},
      fun(S) -> call(fun(Core) -> erx_domain_links:answer(From, Answer, Core) end,
                     S#{hostile := Left - 1}) end}
     || {From, To} <- hostile_pairs(Who),
        Answer <- [{connection_mapped, To}, {connection_unmapped, To}, {connection_lost, To, x}]].

hostile_pairs(a) -> [{?A, peer_id(1)}, {?A, peer_id(2)}];
hostile_pairs(peers) -> [{peer_id(1), ?A}, {peer_id(2), ?A}].

%% Properties.

%% The ids of the honest parties: all of them, or all but the hostile side.
honest(honest) -> [?A, peer_id(1), peer_id(2)];
honest({hostile, a}) -> [peer_id(1), peer_id(2)];
honest({hostile, peers}) -> [?A].

%% Each check raises its violation, or returns ok.
check(S, Mode) ->
    Honest = honest(Mode),
    one_control_record(S, Honest),
    one_entry(S, Honest),
    no_use_after_delete(S, Honest),
    nothing_dropped(S, Honest),
    case Mode of
        honest -> let_go_deleted(S);
        {hostile, _} -> ok
    end.

one_control_record(#{owed := Owed}, Honest) ->
    case [{Party, N} || Party <- Honest, N <- [maps:get(Party, Owed)], N > 1] of
        [] -> ok;
        [{Party, N} | _] -> violation({one_control_record, Party, N})
    end.

one_entry(S, Honest) ->
    Up = [C || C <- [1, 2], a_maps(C, S)],
    case lists:member(?A, Honest) andalso length(Up) > 1 of
        true -> violation({one_entry, Up});
        false -> ok
    end.

no_use_after_delete(S, Honest) ->
    Used = [{Party, C} || C <- [1, 2], maps:get(deleted, peer(C, S)),
                          {Party, Maps} <- [{?A, a_maps(C, S)}, {peer_id(C), p_maps(C, S)}],
                          lists:member(Party, Honest), Maps],
    case Used of
        [] -> ok;
        [{Party, C} | _] -> violation({no_use_after_delete, Party, C})
    end.

let_go_deleted(S) ->
    case [C || C <- [1, 2], maps:get(introduced, peer(C, S)), not maps:get(deleted, peer(C, S)),
               a_let_go(C, S), p_let_go(C, S)] of
        [] -> ok;
        [C | _] -> violation({let_go_not_deleted, C})
    end.

%% A party the core no longer holds has no count, which is 0.
nothing_dropped(#{core := Core}, Honest) ->
    Dropped = erx_domain_links:dropped(Core),
    case [{Party, N} || Party <- Honest, N <- [maps:get(Party, Dropped, 0)], N > 0] of
        [] -> ok;
        [{Party, N} | _] -> violation({honest_answer_dropped, Party, N})
    end.

a_maps(C, S) -> lists:member(a_conn(C, S), [mapped, draining]).

p_maps(C, S) ->
    case peer(C, S) of
        #{life := alive, answer := mapped} -> true;
        #{} -> false
    end.

%% A party has let go of a connection once it answered connection_unmapped
%% or connection_lost, or ended, or once the connection closed before the
%% party was told of it, as it then never is.
a_let_go(C, S) ->
    lists:member(a_conn(C, S), [gone, lost, failed]) orelse untold(?A, C, S).

p_let_go(C, S) ->
    case peer(C, S) of
        #{learnt := true} -> true;
        #{answer := Answer} when Answer =:= unmapped; Answer =:= lost; Answer =:= failed -> true;
        #{} -> untold(peer_id(C), C, S)
    end.

untold(Party, C, #{told := Told} = S) ->
    maps:get(closed, peer(C, S)) =/= false andalso not is_map_key({Party, C}, Told).

witnesses(#{told := Told} = S) ->
    [later_up_at_a || lists:member(a_conn(1, S), [gone, lost, failed]), a_conn(2, S) =:= mapped]
        ++ [map_failed_at_a || C <- [1, 2], a_conn(C, S) =:= failed]
        ++ [untold_at_a || C <- [1, 2], maps:get(introduced, peer(C, S)), untold(?A, C, S)]
        ++ [a_lost_with_down_sent || C <- [1, 2], a_conn(C, S) =:= lost,
                                     maps:get({?A, C}, Told, none) =:= down].

%% At the end of a run every peer has ended, every connection is deleted and
%% forgotten, and nothing is queued for A or owed by it. A record an ended
%% peer never answered is moot.
run_end(#{core := Core, owed := Owed, a := #{inbox := Inbox}} = S, Trace) ->
    Fail = fun(Name) -> throw({violation, {run_end, Name}, lists:reverse(Trace)}) end,
    [Fail({not_deleted, C}) || C <- [1, 2], maps:get(introduced, peer(C, S)),
                               not maps:get(deleted, peer(C, S))],
    [Fail({not_forgotten, C}) || C <- [1, 2], erx_domain_links:phase(?A, peer_id(C), Core) =/= none],
    Inbox =:= [] orelse Fail(queued),
    maps:get(?A, Owed) =:= 0 orelse Fail({owed, Owed}),
    ok.

%% The control slots (docs/design-domains.md, "The control table"): a record takes the
%% lowest slot no outstanding record of its party holds, and its side keeps it until the
%% answer the record waits for; connection_lost while a connection_down waits frees
%% nothing, since the party may not have taken the record yet. room/2 counts the
%% connections not done against the party's slots, and connect/4 refuses a party without room.
control_slots_test() ->
    S0 = lists:foldl(fun({P, Name}, S) -> erx_domain_links:add_party(P, Name, 2, S) end,
                     erx_domain_links:new(), [{?A, ?A_NAME}, {11, 'p1@erxos'}, {12, 'p2@erxos'},
                                              {13, 'p3@erxos'}]),
    S1 = ready_all(S0, [?A, 11, 12]),
    {[{send, ?A, 0, _}, {send, 11, 0, _}], S2} = erx_domain_links:connect(c1, {?A, u}, {11, u}, S1),
    {[{send, ?A, 1, _}, {send, 12, 0, _}], S3} = erx_domain_links:connect(c2, {?A, u}, {12, u}, S2),
    ?assertNot(erx_domain_links:room(?A, S3)),
    ?assert(erx_domain_links:room(11, S3)),
    ?assertNot(erx_domain_links:room(99, S3)),
    {[], S4} = erx_domain_links:answer(?A, {connection_mapped, 11}, S3),
    {[], S5} = erx_domain_links:answer(11, {connection_mapped, ?A}, S4),
    %% A's slot 0 is free, but both its connections still count against it, so
    %% connect/4 refuses a third rather than trust its caller's room/2.
    ?assertError({badmatch, {false, true}}, erx_domain_links:connect(c3, {?A, u}, {13, u}, S5)),
    %% A's slot 0 is free again: the down about 11 takes it while slot 1 still waits.
    {[{send, ?A, 0, {connection_down, 11, noconnection}}, {send, 11, 0, _}], S6} =
        erx_domain_links:close(?A, 11, S5),
    {[], S7} = erx_domain_links:answer(?A, {connection_lost, 11, disconnect}, S6),
    {[], S8} = erx_domain_links:answer(?A, {connection_mapped, 12}, S7),
    {[], S9} = erx_domain_links:answer(12, {connection_mapped, ?A}, S8),
    %% Slot 0 still holds the down about 11, so the down about 12 takes slot 1.
    {[{send, ?A, 1, {connection_down, 12, noconnection}}, {send, 12, 0, _}], _} =
        erx_domain_links:close(?A, 12, S9).
