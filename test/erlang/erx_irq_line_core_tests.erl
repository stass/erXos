%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_irq_line_core, the shared line owner's state machine
%% (docs/design-shared-devices.md, "Lines inside a domain" and the Verification row of
%% erx_irq_line_core): the design's named traces, then every sequence of up to eight
%% events over four members, checked against an independent model of the line's
%% guarantees. test/host/erx_irq_line_core_test.rb also runs them against seeded faults
%% of the module, each of which the cases named there must catch.

-module(erx_irq_line_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MEMBERS, 4).
-define(DEPTH, 8).
-define(STRANGER, (?MEMBERS + 1)).
-define(SEQUENCES, 1806982209).

%% ---------------------------------------------------------------------------
%% Fixtures
%% ---------------------------------------------------------------------------

step(Event, Core) -> erx_irq_line_core:step(Event, Core).

%% A core in idle whose members are the given {Ref, Dev} pairs, each joined by this
%% process.
joined(Members) ->
    lists:foldl(fun({Ref, Dev}, Core) ->
                        {[], Next} = step({join, Ref, self(), Dev}, Core),
                        Next
                end, erx_irq_line_core:new(), Members).

notice(Dev) -> {notify, self(), Dev}.

notices(Devs) -> lists:sort([notice(Dev) || Dev <- Devs]).

%% ---------------------------------------------------------------------------
%% The named traces
%% ---------------------------------------------------------------------------

%% A and B told; A answers, A's device raises the line again, B answers: the owner
%% acknowledges, then tells A and B again, so A services what its device raised.
a_firing_after_an_answer_tells_every_member_again_test() ->
    A = make_ref(),
    B = make_ref(),
    {Told, Round} = step(fire, joined([{A, dev_a}, {B, dev_b}])),
    ?assertEqual(notices([dev_a, dev_b]), lists:sort(Told)),
    {AfterA, AAnswered} = step({done, A}, Round),
    ?assertEqual([], AfterA),
    {AfterFire, Again} = step(fire, AAnswered),
    ?assertEqual([], AfterFire),
    {[First | Next], NextRound} = step({done, B}, Again),
    ?assertEqual(ack, First),
    ?assertEqual(notices([dev_a, dev_b]), lists:sort(Next)),
    ?assertEqual({round, lists:sort([A, B]), false}, erx_irq_line_core:phase(NextRound)).

%% Two members told: the first answer acknowledges nothing; the second does.
the_line_is_acknowledged_after_the_last_answer_test() ->
    A = make_ref(),
    B = make_ref(),
    {_, Round} = step(fire, joined([{A, dev_a}, {B, dev_b}])),
    {AfterA, AAnswered} = step({done, A}, Round),
    ?assertEqual([], AfterA),
    {AfterB, Ended} = step({done, B}, AAnswered),
    ?assertEqual([ack], AfterB),
    ?assertEqual(idle, erx_irq_line_core:phase(Ended)).

%% A firing with no member holds the line: nothing is told and nothing acknowledged.
a_firing_with_no_member_holds_the_line_test() ->
    {Actions, Held} = step(fire, erx_irq_line_core:new()),
    ?assertEqual([], Actions),
    ?assertEqual(held, erx_irq_line_core:phase(Held)),
    ?assertEqual({[], Held}, step(fire, Held)).

%% A member that joins during a round is not told of it, and is told of the next.
a_member_that_joins_during_a_round_is_told_in_the_next_test() ->
    A = make_ref(),
    B = make_ref(),
    {[_], Round} = step(fire, joined([{A, dev_a}])),
    {Join, Joined} = step({join, B, self(), dev_b}, Round),
    ?assertEqual([], Join),
    {[], Again} = step(fire, Joined),
    {[ack | Next], _} = step({done, A}, Again),
    ?assertEqual(notices([dev_a, dev_b]), lists:sort(Next)).

%% A join and then that member's down, in idle, in a round and in held, leaves no
%% member; from a round or held it acknowledges.
a_join_then_its_down_in_idle_changes_nothing_test() ->
    M = make_ref(),
    {[], Down} = step({down, M}, joined([{M, dev}])),
    ?assertEqual([], erx_irq_line_core:members(Down)),
    ?assertEqual(idle, erx_irq_line_core:phase(Down)).

a_join_then_its_down_in_a_round_acknowledges_test() ->
    M = make_ref(),
    {[_], Round} = step(fire, joined([{M, dev}])),
    {Actions, Down} = step({down, M}, Round),
    ?assertEqual([ack], Actions),
    ?assertEqual([], erx_irq_line_core:members(Down)),
    ?assertEqual(idle, erx_irq_line_core:phase(Down)).

a_join_then_its_down_in_held_acknowledges_test() ->
    M = make_ref(),
    {[], Held} = step(fire, erx_irq_line_core:new()),
    {Told, Round} = step({join, M, self(), dev}, Held),
    ?assertEqual([notice(dev)], Told),
    ?assertEqual([M], erx_irq_line_core:members(Round)),
    {Actions, Down} = step({down, M}, Round),
    ?assertEqual([ack], Actions),
    ?assertEqual([], erx_irq_line_core:members(Down)),
    ?assertEqual(idle, erx_irq_line_core:phase(Down)).

%% ---------------------------------------------------------------------------
%% Every sequence
%% ---------------------------------------------------------------------------

%% The independent model. It follows the line's guarantees as the design states them,
%% not the core's transition table, over member indices 1..?MEMBERS, and ?STRANGER, an
%% index that never joins. Each field says what it tracks and which check reads it:
%%
%%   joined       the members that ever joined; with alive, it decides which events
%%                may come next
%%   alive        those whose monitor has not fired: the members the core must hold
%%   outstanding  those told of the current round that have neither answered nor gone
%%                down: the round's W, and no ack while any is left
%%   told         those told since the last acknowledgement, the current round: each
%%                is told once, and an ack ends a round that told someone
%%   owed         those alive at a firing and not told since it: none may be left
%%                when the core waits for no one
%%   untold       a firing arrived and no round has started since: a round starts
%%                only for one, idle has none, held has one
%%
%% It checks guarantees, not every cell of the table: a core that told a joiner at
%% once during a round would satisfy it, and the named traces above pin that cell
%% and the other named ones.
-record(model, {joined = [] :: [pos_integer()],
                alive = [] :: [pos_integer()],
                outstanding = [] :: [pos_integer()],
                told = [] :: [pos_integer()],
                owed = [] :: [pos_integer()],
                untold = false :: boolean()}).

%% Index I's driver joins at its own pid, pid(I), for its own record, {dev, I}, and
%% its member is the I-th of the test's references, ref(I, Refs).
ref(I, Refs) -> element(I, Refs).

pid(I) -> list_to_pid("<0." ++ integer_to_list(100 + I) ++ ".0>").

%% Explores every sequence of up to ?DEPTH events level by level. A level maps each
%% distinct {core, model} pair to the number of sequences that reach it and one of
%% them, so equal pairs of one level are expanded once while every sequence is still
%% counted.
every_sequence_of_eight_events_over_four_members_test() ->
    Refs = list_to_tuple([make_ref() || _ <- lists:seq(1, ?STRANGER)]),
    Start = #{{erx_irq_line_core:new(), #model{}} => {1, []}},
    {States, Sequences} = explore(Start, 0, Refs, #{}, 0),
    io:format(user, "~nerx_irq_line_core: ~b distinct states, ~b event sequences~n",
              [States, Sequences]),
    %% Which events may come next depends on the model alone, never on the core, so
    %% the number of sequences is fixed: it pins the exploration's reach.
    ?assertEqual(?SEQUENCES, Sequences).

%% Distinct holds every pair met at any depth, only to count them.
explore(Level, Depth, Refs, Distinct, Sequences) ->
    Distinct1 = maps:merge(Distinct, maps:map(fun(_, _) -> true end, Level)),
    Sequences1 = Sequences + maps:fold(fun(_, {N, _}, Sum) -> Sum + N end, 0, Level),
    case Depth of
        ?DEPTH -> {map_size(Distinct1), Sequences1};
        _ ->
            Next = maps:fold(fun(Pair, Paths, Acc) ->
                                     successors(Pair, Paths, Refs, Acc)
                             end, #{}, Level),
            explore(Next, Depth + 1, Refs, Distinct1, Sequences1)
    end.

successors({Core, Model}, {Count, Trace}, Refs, Acc) ->
    lists:foldl(
      fun(Event, Acc1) ->
              Trace1 = [Event | Trace],
              {Actions, Core1} = step(core_event(Event, Refs), Core),
              Model1 = check(Event, Actions, Core1, Model, Refs, Trace1),
              maps:update_with({Core1, Model1}, fun({N, T}) -> {N + Count, T} end,
                               {Count, Trace1}, Acc1)
      end, Acc, events(Model)).

%% Any member not yet joined may join. A done or a down may name anyone, the
%% stranger and members already gone included: a stray answer or down must change
%% nothing.
events(#model{joined = Joined}) ->
    Anyone = lists:seq(1, ?STRANGER),
    [fire]
        ++ [{join, I} || I <- lists:seq(1, ?MEMBERS), not lists:member(I, Joined)]
        ++ [{done, I} || I <- Anyone]
        ++ [{down, I} || I <- Anyone].

core_event(fire, _) -> fire;
core_event({join, I}, Refs) -> {join, ref(I, Refs), pid(I), {dev, I}};
core_event({done, I}, Refs) -> {done, ref(I, Refs)};
core_event({down, I}, Refs) -> {down, ref(I, Refs)}.

%% The model takes the event, then each action in order; then the core's state is
%% compared with what the model says it must be.
check(Event, Actions, Core, Model, Refs, Trace) ->
    Observed = observe(Event, Model),
    After = lists:foldl(fun(Action, M) -> perform(Action, M, Trace) end,
                        Observed, Actions),
    settled(Core, Observed, After, Actions, Refs, Trace),
    After.

observe(fire, #model{alive = Alive, owed = Owed} = M) ->
    M#model{untold = true, owed = ordsets:union(Owed, Alive)};
observe({join, I}, #model{joined = Joined, alive = Alive} = M) ->
    M#model{joined = ordsets:add_element(I, Joined),
            alive = ordsets:add_element(I, Alive)};
observe({done, I}, #model{outstanding = Outstanding} = M) ->
    M#model{outstanding = ordsets:del_element(I, Outstanding)};
observe({down, I}, #model{alive = Alive, outstanding = Outstanding,
                          owed = Owed} = M) ->
    M#model{alive = ordsets:del_element(I, Alive),
            outstanding = ordsets:del_element(I, Outstanding),
            owed = ordsets:del_element(I, Owed)}.

perform(ack, #model{told = Told, outstanding = Outstanding} = M, Trace) ->
    holds(Told =/= [], an_ack_ends_a_round_that_told_someone, Trace),
    holds(Outstanding =:= [],
          no_ack_before_every_told_member_answered_or_went_down, Trace),
    M#model{told = []};
perform({notify, Pid, {dev, I}}, #model{told = Told} = M, Trace) ->
    holds(lists:member(I, M#model.alive) andalso Pid =:= pid(I),
          only_a_live_member_is_told_at_its_own_pid, Trace),
    holds(not lists:member(I, Told), a_member_is_told_once_per_round, Trace),
    RoundStart = Told =:= [],
    holds(not RoundStart orelse M#model.untold,
          a_round_starts_only_for_an_untold_firing, Trace),
    M#model{told = ordsets:add_element(I, Told),
            outstanding = ordsets:add_element(I, M#model.outstanding),
            owed = ordsets:del_element(I, M#model.owed),
            untold = M#model.untold andalso not RoundStart}.

settled(Core, Observed, After, Actions, Refs, Trace) ->
    RefsOf = fun(Indices) -> lists:sort([ref(I, Refs) || I <- Indices]) end,
    holds(erx_irq_line_core:members(Core) =:= RefsOf(After#model.alive),
          every_member_is_a_live_monitor_and_every_live_monitor_a_member, Trace),
    case erx_irq_line_core:phase(Core) of
        idle ->
            holds(After#model.told =:= [] andalso not After#model.untold,
                  idle_only_with_every_firing_told_and_acknowledged, Trace);
        held ->
            holds(After#model.alive =:= [] andalso After#model.told =:= []
                  andalso After#model.untold,
                  held_only_while_no_member_was_told, Trace);
        {round, Waiting, _} ->
            holds(Waiting =/= [] andalso Waiting =:= RefsOf(After#model.outstanding),
                  a_round_waits_for_exactly_the_told_members_yet_to_answer, Trace)
    end,
    holds(After#model.outstanding =/= [] orelse After#model.owed =:= [],
          no_firing_goes_untold, Trace),
    %% A round started in this step when none was in progress before its actions,
    %% or the round in progress ended in them, and someone has now been told.
    StartedRound = (Observed#model.told =:= [] orelse lists:member(ack, Actions))
        andalso After#model.told =/= [],
    holds(not StartedRound orelse After#model.told =:= After#model.alive,
          a_round_tells_every_member, Trace).

holds(true, _, _) -> ok;
holds(false, Property, Trace) ->
    erlang:error({property_broken, Property, {events, lists:reverse(Trace)}}).
