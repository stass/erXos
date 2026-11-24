%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the drive grant (erx_blk_drive): its pure step/2, the cases by name and
%% then every sequence of events up to a length over two windows and two holders' asks,
%% held to the grant's rules; and its process, against a stand-in window and the test as
%% the medium's issuing process. test/host/erx_blk_test.rb runs them on stock's emulator.

-module(erx_blk_drive_tests).
-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% The pure core, by name
%% ---------------------------------------------------------------------------

no_medium_is_answered_no_medium_test() ->
    ?assertMatch({_, [{answer, a, {error, no_medium}}]}, erx_blk_drive:step({ask, a}, erx_blk_drive:new())).

the_first_ask_answers_the_window_test() ->
    ?assertMatch({_, [{answer, a, {ok, w1}}]}, run([{serve, w1, m1, e1}, {ask, a}])).

%% The second ask ends the medium and answers nothing until the old window has ended.
an_answered_window_asked_again_ends_its_medium_first_test() ->
    {State, Actions} = run([{serve, w1, m1, e1}, {ask, a}, {ask, b}]),
    ?assertEqual([{end_medium, e1}], Actions),
    ?assertMatch({_, []}, erx_blk_drive:step({ask, c}, State)),
    ?assertMatch({_, [{answer, b, {error, no_medium}}, {answer, c, {error, no_medium}}]},
                 erx_blk_drive:step({ended, m1}, element(1, erx_blk_drive:step({ask, c}, State)))).

%% A block device's next block service starts before the old window's end is seen: the
%% held ask is answered the new window once the old one has ended, never before.
the_next_window_is_answered_only_after_the_old_one_ends_test() ->
    {Served, []} = run([{serve, w1, m1, e1}, {ask, a}, {ask, b}, {serve, w2, m2, e2}]),
    ?assertMatch({_, [{answer, b, {ok, w2}}]}, erx_blk_drive:step({ended, m1}, Served)),
    {Answered, _} = erx_blk_drive:step({ended, m1}, Served),
    ?assertMatch({_, [{end_medium, e2}]}, erx_blk_drive:step({ask, c}, Answered)).

an_ended_window_is_forgotten_test() ->
    ?assertMatch({_, [{answer, a, {error, no_medium}}]}, run([{serve, w1, m1, e1}, {ended, m1}, {ask, a}])).

the_end_of_a_window_the_grant_no_longer_holds_changes_nothing_test() ->
    {State, []} = run([{serve, w1, m1, e1}, {serve, w2, m2, e2}]),
    ?assertEqual({State, []}, erx_blk_drive:step({ended, m1}, State)).

%% A free grant takes one occupant; a second is refused and its monitor forgotten.
a_free_grant_takes_one_occupant_test() ->
    {Taken, [{answer, f1, ok}]} = erx_blk_drive:step({occupy, f1, o1}, erx_blk_drive:new()),
    ?assertEqual({Taken, [{answer, f2, taken}, {forget, o2}]}, erx_blk_drive:step({occupy, f2, o2}, Taken)).

%% The occupant's end frees the grant before it serves any medium.
an_occupant_s_end_frees_the_grant_test() ->
    ?assertMatch({_, [{answer, f2, ok}]}, run([{occupy, f1, o1}, {ended, o1}, {occupy, f2, o2}])).

%% The end of the medium served under an occupant frees the grant, though the occupant
%% lives on: its monitor is forgotten, so its later end changes nothing.
a_medium_s_end_frees_the_grant_test() ->
    {Served, []} = run([{occupy, f1, o1}, {serve, w1, m1, e1}]),
    {Freed, Forgot} = erx_blk_drive:step({ended, m1}, Served),
    ?assertEqual([{forget, o1}], Forgot),
    ?assertMatch({_, [{answer, f2, ok}]}, erx_blk_drive:step({occupy, f2, o2}, Freed)),
    ?assertEqual({Freed, []}, erx_blk_drive:step({ended, o1}, Freed)).

%% A grant that holds a medium is taken, whether or not an occupant took it, so the
%% medium's window is never handed to a second medium.
a_grant_holding_a_medium_is_taken_test() ->
    ?assertMatch({_, [{answer, f1, taken}, {forget, o1}]}, run([{serve, w1, m1, e1}, {occupy, f1, o1}])),
    ?assertMatch({_, [{answer, f2, taken}, {forget, o2}]},
                 run([{occupy, f1, o1}, {serve, w1, m1, e1}, {ended, o1}, {occupy, f2, o2}])).

%% ---------------------------------------------------------------------------
%% The pure core, every sequence
%% ---------------------------------------------------------------------------

%% Each window is served at most once and ends at most once, after its serve, as a block
%% service's window does; asks come from two holders in any order; and an end the grant
%% made no monitor for, as a forged one, may come at any time.
-define(LENGTH, 8).
-define(WINDOWS, [{w1, m1, e1}, {w2, m2, e2}]).

every_sequence_keeps_the_grant_s_rules_test() ->
    Count = explore(erx_blk_drive:new(), world(), ?LENGTH),
    ?assert(Count > 10000).

%% What the sequence has done so far, as the rules need it: windows served and ended, the
%% ones answered to a holder, the ends asked for and not yet seen, and the asks not yet
%% answered, and the window served last.
world() ->
    #{served => [], ended => [], answered => [], ending => [], asks => [], latest => none}.

explore(_State, _World, 0) ->
    1;
explore(State, World, Left) ->
    lists:foldl(fun(Event, Count) ->
                        {Next, Actions} = erx_blk_drive:step(Event, State),
                        Count + explore(Next, check(Event, Actions, World), Left - 1)
                end, 1, events(World)).

events(#{served := Served, ended := Ended, asks := Asks}) ->
    [{ask, Holder} || Holder <- [a, b], not lists:member(Holder, Asks)]
        ++ [{serve, Window, Monitor, End} || {Window, Monitor, End} <- ?WINDOWS, not lists:member(Window, Served)]
        ++ [{ended, monitor_of(Window)} || Window <- Served, not lists:member(Window, Ended)]
        ++ [{ended, forged}].

monitor_of(Window) -> element(2, lists:keyfind(Window, 1, ?WINDOWS)).

%% The world after Event and the grant's Actions on it, each rule asserted on the way.
check(Event, Actions, World0) ->
    World = observe(Event, World0),
    lists:foldl(fun(Action, W) -> rule(Action, W) end, World, Actions),
    Next = lists:foldl(fun apply_action/2, World, Actions),
    %% No ask is held unless an end the grant asked for is still unseen.
    case Next of
        #{ending := []} -> ?assertEqual([], maps:get(asks, Next));
        #{} -> ok
    end,
    Next.

observe({ask, Holder}, World = #{asks := Asks}) -> World#{asks := Asks ++ [Holder]};
observe({serve, Window, _Monitor, _End}, World = #{served := Served}) ->
    World#{served := [Window | Served], latest := Window};
observe({ended, forged}, World) -> World;
observe({ended, Monitor}, World = #{ended := Ended, ending := Ending}) ->
    {Window, Monitor, _End} = lists:keyfind(Monitor, 2, ?WINDOWS),
    World#{ended := [Window | Ended], ending := lists:delete(Window, Ending)}.

%% No answer while an end the grant asked for is unseen; only an ask held is answered; no
%% window is handed out after it ended, twice or while a later one was served; an end is asked only of a window handed
%% out, not ended and not already ending. Every rule sees the world before the step, so
%% the held asks one step answers may share a window.
rule({answer, Holder, Reply},
     World = #{ending := Ending, asks := Asks, ended := Ended, answered := Answered, latest := Latest}) ->
    ?assertEqual([], Ending),
    ?assert(lists:member(Holder, Asks)),
    case Reply of
        {ok, Window} ->
            ?assertNot(lists:member(Window, Ended)),
            ?assertNot(lists:member(Window, Answered)),
            ?assertEqual(Latest, Window);
        {error, no_medium} ->
            ok
    end,
    World;
rule({end_medium, End}, World = #{answered := Answered, ended := Ended, ending := Ending}) ->
    {Window, _Monitor, End} = lists:keyfind(End, 3, ?WINDOWS),
    ?assert(lists:member(Window, Answered)),
    ?assertNot(lists:member(Window, Ended)),
    ?assertNot(lists:member(Window, Ending)),
    World.

apply_action({answer, Holder, Reply}, World = #{asks := Asks, answered := Answered}) ->
    Handed = case Reply of
                 {ok, Window} -> [Window | Answered];
                 {error, no_medium} -> Answered
             end,
    World#{asks := lists:delete(Holder, Asks), answered := Handed};
apply_action({end_medium, End}, World = #{ending := Ending}) ->
    {Window, _Monitor, End} = lists:keyfind(End, 3, ?WINDOWS),
    World#{ending := [Window | Ending]}.

run(Events) ->
    lists:foldl(fun(Event, {State, _Actions}) -> erx_blk_drive:step(Event, State) end,
                {erx_blk_drive:new(), []}, Events).

%% ---------------------------------------------------------------------------
%% The process
%% ---------------------------------------------------------------------------

%% A stand-in window: a process that waits to be ended.
window() ->
    spawn(fun() -> receive stop -> ok end end).

end_window(Window) ->
    Monitor = monitor(process, Window),
    Window ! stop,
    receive {'DOWN', Monitor, process, Window, _} -> ok end.

%% The test is the medium's issuing process: the grant's end reaches it as a message, and
%% the held ask is answered only once the old window has ended.
a_grant_asked_again_waits_for_the_old_window_s_end_test() ->
    {ok, Grant} = erx_blk_drive:start_link(),
    ?assertEqual({error, no_medium}, erx_blk_drive:window(Grant)),
    Old = window(),
    ok = erx_blk_drive:serve(Grant, Old, {self(), old_medium}),
    ?assertEqual({ok, Old}, erx_blk_drive:window(Grant)),
    Ask = gen_server:send_request(Grant, window),
    receive {erx_blk_drive, end_medium, Medium} -> ?assertEqual(old_medium, Medium)
    after 5000 -> ?assert(false)
    end,
    _ = sys:get_state(Grant),
    ?assertEqual(timeout, gen_server:wait_response(Ask, 0)),
    New = window(),
    ok = erx_blk_drive:serve(Grant, New, {self(), new_medium}),
    _ = sys:get_state(Grant),
    ?assertEqual(timeout, gen_server:wait_response(Ask, 0)),
    end_window(Old),
    ?assertEqual({reply, {ok, New}}, gen_server:receive_response(Ask, 5000)),
    end_window(New),
    _ = sys:get_state(Grant),
    ?assertEqual({error, no_medium}, erx_blk_drive:window(Grant)),
    unlink(Grant),
    exit(Grant, kill).
