%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the drive grant (erx_blk_drive): its pure step/2, the cases by name and
%% then every sequence of events up to a length over two windows, two occupants and two
%% holders' asks, held to the grant's rules; and its process, against a stand-in window
%% and the test as the medium's issuing process. test/host/erx_blk_test.rb runs them on
%% stock's emulator.
%%
%% In the pure cases an issuer is {Pid, Medium} and an occupant {Pid, Monitor}, atoms
%% standing for the pids: window w1 is served by issuer {p1, e1}, w2 by {p2, e2}, and the
%% occupant {p1, o1} is the function whose medium w1 is.

-module(erx_blk_drive_tests).
-include_lib("eunit/include/eunit.hrl").

%% ---------------------------------------------------------------------------
%% The pure core, by name
%% ---------------------------------------------------------------------------

-define(SERVE1, {serve, w1, m1, {p1, e1}}).
-define(SERVE2, {serve, w2, m2, {p2, e2}}).

no_medium_is_answered_no_medium_test() ->
    ?assertMatch({_, [{answer, a, {error, no_medium}}]}, erx_blk_drive:step({ask, a}, erx_blk_drive:new())).

the_first_ask_answers_the_window_test() ->
    ?assertMatch({_, [{answer, a, {ok, w1}}]}, run([?SERVE1, {ask, a}])).

%% The second ask ends the medium and answers nothing until the old window has ended.
an_answered_window_asked_again_ends_its_medium_first_test() ->
    {State, Actions} = run([?SERVE1, {ask, a}, {ask, b}]),
    ?assertEqual([{end_medium, {p1, e1}}], Actions),
    ?assertMatch({_, []}, erx_blk_drive:step({ask, c}, State)),
    ?assertMatch({_, [{answer, b, {error, no_medium}}, {answer, c, {error, no_medium}}]},
                 erx_blk_drive:step({ended, m1}, element(1, erx_blk_drive:step({ask, c}, State)))).

%% A block device's next block service starts before the old window's end is seen: the
%% held ask is answered the new window once the old one has ended, never before.
the_next_window_is_answered_only_after_the_old_one_ends_test() ->
    {Served, []} = run([?SERVE1, {ask, a}, {ask, b}, ?SERVE2]),
    ?assertMatch({_, [{answer, b, {ok, w2}}]}, erx_blk_drive:step({ended, m1}, Served)),
    {Answered, _} = erx_blk_drive:step({ended, m1}, Served),
    ?assertMatch({_, [{end_medium, {p2, e2}}]}, erx_blk_drive:step({ask, c}, Answered)).

an_ended_window_is_forgotten_test() ->
    ?assertMatch({_, [{answer, a, {error, no_medium}}]}, run([?SERVE1, {ended, m1}, {ask, a}])).

the_end_of_a_window_the_grant_no_longer_holds_changes_nothing_test() ->
    {State, []} = run([?SERVE1, ?SERVE2]),
    ?assertEqual({State, []}, erx_blk_drive:step({ended, m1}, State)).

%% A free grant takes one occupant; a second is refused and its monitor forgotten.
a_free_grant_takes_one_occupant_test() ->
    {Taken, [{answer, f1, ok}]} = erx_blk_drive:step({occupy, f1, {p1, o1}}, erx_blk_drive:new()),
    ?assertEqual({Taken, [{answer, f2, taken}, {forget, o2}]}, erx_blk_drive:step({occupy, f2, {p2, o2}}, Taken)).

%% The occupant's end frees the grant before it serves any medium.
an_occupant_s_end_frees_the_grant_test() ->
    ?assertMatch({_, [{answer, f2, ok}]}, run([{occupy, f1, {p1, o1}}, {ended, o1}, {occupy, f2, {p2, o2}}])).

%% The end of the medium served under an occupant frees the grant, though the occupant
%% lives on: its monitor is forgotten, so its later end changes nothing.
a_medium_s_end_frees_the_grant_test() ->
    {Served, []} = run([{occupy, f1, {p1, o1}}, ?SERVE1]),
    {Freed, Forgot} = erx_blk_drive:step({ended, m1}, Served),
    ?assertEqual([{forget, o1}], Forgot),
    ?assertMatch({_, [{answer, f2, ok}]}, erx_blk_drive:step({occupy, f2, {p2, o2}}, Freed)),
    ?assertEqual({Freed, []}, erx_blk_drive:step({ended, o1}, Freed)).

%% A grant that holds a medium is taken, whether or not an occupant took it, so the
%% medium's window is never handed to a second medium.
a_grant_holding_a_medium_is_taken_test() ->
    ?assertMatch({_, [{answer, f1, taken}, {forget, o1}]}, run([?SERVE1, {occupy, f1, {p1, o1}}])),
    ?assertMatch({_, [{answer, f2, taken}, {forget, o2}]},
                 run([{occupy, f1, {p1, o1}}, ?SERVE1, {ended, o1}, {occupy, f2, {p2, o2}}])).

%% An occupied drive takes a medium only from its occupant: a serve from any other
%% issuer, a function that lost the drive among them, is dropped and its window's
%% monitor forgotten, so a holder is never handed a medium that did not take the drive.
an_occupied_grant_drops_a_serve_from_another_issuer_test() ->
    {Occupied, _} = run([{occupy, f1, {p1, o1}}]),
    {Dropped, Forgot} = erx_blk_drive:step(?SERVE2, Occupied),
    ?assertEqual({Occupied, [{forget, m2}]}, {Dropped, Forgot}),
    ?assertMatch({_, [{answer, a, {error, no_medium}}]}, erx_blk_drive:step({ask, a}, Dropped)),
    ?assertMatch({_, [{answer, a, {ok, w1}}]}, run([{occupy, f1, {p1, o1}}, ?SERVE2, ?SERVE1, {ask, a}])).

%% ---------------------------------------------------------------------------
%% The pure core, every sequence
%% ---------------------------------------------------------------------------

%% Each window is served at most once and ends at most once, after its serve, as a block
%% service's window does; each occupant asks to take the drive at most once, and its end
%% comes only while the grant still monitors it; asks come from two holders in any
%% order; and an end the grant made no monitor for, as a forged one, may come at any time.
-define(LENGTH, 8).
-define(WINDOWS, [{w1, m1, {p1, e1}}, {w2, m2, {p2, e2}}]).
-define(OCCUPANTS, [{f1, {p1, o1}}, {f2, {p2, o2}}]).

every_sequence_keeps_the_grant_s_rules_test() ->
    Count = explore(erx_blk_drive:new(), world(), ?LENGTH),
    ?assert(Count > 1000000).

%% What the sequence has done so far, as the rules need it: windows served and ended, the
%% ones answered to a holder, the ends asked for and not yet seen, the asks not yet
%% answered; the occupants that asked and those still monitored; and, as the grant's
%% rules define them, the occupant holding the drive and the medium it holds (the window
%% of the last serve the grant could take).
world() ->
    #{served => [], ended => [], answered => [], ending => [], asks => [],
      occupied => [], monitored => [], occupant => none, medium => none}.

explore(_State, _World, 0) ->
    1;
explore(State, World, Left) ->
    lists:foldl(fun(Event, Count) ->
                        {Next, Actions} = erx_blk_drive:step(Event, State),
                        Count + explore(Next, check(Event, Actions, World), Left - 1)
                end, 1, events(World)).

events(#{served := Served, ended := Ended, asks := Asks, occupied := Occupied, monitored := Monitored}) ->
    [{ask, Holder} || Holder <- [a, b], not lists:member(Holder, Asks)]
        ++ [{serve, Window, Monitor, Issuer} || {Window, Monitor, Issuer} <- ?WINDOWS, not lists:member(Window, Served)]
        ++ [{ended, monitor_of(Window)} || Window <- Served, not lists:member(Window, Ended)]
        ++ [{occupy, From, Occupant} || {From, Occupant} <- ?OCCUPANTS, not lists:member(From, Occupied)]
        ++ [{ended, Monitor} || {From, {_Pid, Monitor}} <- ?OCCUPANTS, lists:member(From, Monitored)]
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
observe({serve, Window, _Monitor, {Pid, _Medium}}, World = #{served := Served, occupant := Occupant}) ->
    Taken = Occupant =:= none orelse Occupant =:= Pid,
    Medium = case Taken of
                 true -> Window;
                 false -> maps:get(medium, World)
             end,
    World#{served := [Window | Served], medium := Medium};
observe({occupy, From, _Occupant}, World = #{occupied := Occupied, monitored := Monitored}) ->
    World#{occupied := [From | Occupied], monitored := [From | Monitored]};
observe({ended, forged}, World) -> World;
observe({ended, Monitor}, World = #{ended := Ended, ending := Ending, medium := Medium, occupant := Occupant}) ->
    case {lists:keyfind(Monitor, 2, ?WINDOWS), [From || {From, {_, M}} <- ?OCCUPANTS, M =:= Monitor]} of
        {{Window, Monitor, _Issuer}, []} ->
            Freed = case Medium of
                        Window -> World#{medium := none, occupant := none};
                        _Other -> World
                    end,
            Freed#{ended := [Window | Ended], ending := lists:delete(Window, Ending)};
        {false, [From]} ->
            Pid = pid_of(From),
            Left = World#{monitored := lists:delete(From, maps:get(monitored, World))},
            case Occupant of
                Pid -> Left#{occupant := none};
                _Other -> Left
            end
    end.

pid_of(From) -> element(1, element(2, lists:keyfind(From, 1, ?OCCUPANTS))).

%% No answer while an end the grant asked for is unseen; only an ask held is answered; no
%% window is handed out after it ended, twice, or other than the medium the drive holds,
%% so never one whose serve came from an issuer other than the drive's occupant; an end
%% is asked only of a window handed out, not ended and not already ending. A drive is
%% taken only while it has no occupant and holds no medium. Every rule sees the world
%% before the step, so the held asks one step answers may share a window.
rule({answer, From, Reply}, World = #{occupant := Occupant, medium := Medium}) when Reply =:= ok; Reply =:= taken ->
    ?assertEqual(Reply =:= ok, Occupant =:= none andalso Medium =:= none),
    ?assert(lists:keymember(From, 1, ?OCCUPANTS)),
    World;
rule({answer, Holder, Reply},
     World = #{ending := Ending, asks := Asks, ended := Ended, answered := Answered, medium := Medium}) ->
    ?assertEqual([], Ending),
    ?assert(lists:member(Holder, Asks)),
    case Reply of
        {ok, Window} ->
            ?assertNot(lists:member(Window, Ended)),
            ?assertNot(lists:member(Window, Answered)),
            ?assertEqual(Medium, Window);
        {error, no_medium} ->
            ok
    end,
    World;
rule({end_medium, Issuer}, World = #{answered := Answered, ended := Ended, ending := Ending}) ->
    {Window, _Monitor, Issuer} = lists:keyfind(Issuer, 3, ?WINDOWS),
    ?assert(lists:member(Window, Answered)),
    ?assertNot(lists:member(Window, Ended)),
    ?assertNot(lists:member(Window, Ending)),
    World;
rule({forget, Monitor}, World = #{occupant := Occupant}) ->
    %% An occupant is forgotten only once it no longer holds the drive (refused, or freed by
    %% its medium's end), since a forgotten occupant that still held it would never free it.
    ?assertEqual([], [From || {From, {Pid, M}} <- ?OCCUPANTS, M =:= Monitor, Pid =:= Occupant]),
    World.

apply_action({answer, From, ok}, World) ->
    World#{occupant := pid_of(From)};
apply_action({answer, _From, taken}, World) ->
    World;
apply_action({answer, Holder, Reply}, World = #{asks := Asks, answered := Answered}) ->
    Handed = case Reply of
                 {ok, Window} -> [Window | Answered];
                 {error, no_medium} -> Answered
             end,
    World#{asks := lists:delete(Holder, Asks), answered := Handed};
apply_action({end_medium, Issuer}, World = #{ending := Ending}) ->
    {Window, _Monitor, Issuer} = lists:keyfind(Issuer, 3, ?WINDOWS),
    World#{ending := [Window | Ending]};
%% A forgotten occupant's end never comes; a forgotten window's monitor is one the grant
%% dropped with its serve, and that window's end changes nothing it holds.
apply_action({forget, Monitor}, World = #{monitored := Monitored}) ->
    World#{monitored := [From || From <- Monitored, element(2, element(2, lists:keyfind(From, 1, ?OCCUPANTS))) =/= Monitor]}.

run(Events) ->
    lists:foldl(fun(Event, {State, _Actions}) -> erx_blk_drive:step(Event, State) end,
                {erx_blk_drive:new(), []}, Events).

%% ---------------------------------------------------------------------------
%% The process
%% ---------------------------------------------------------------------------

%% A stand-in process: a window, or an occupant, that waits to be ended.
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

%% A drive another process occupies takes no medium the test serves; the occupant's own
%% serve is taken.
a_grant_takes_a_medium_only_from_its_occupant_test() ->
    {ok, Grant} = erx_blk_drive:start_link(),
    Occupant = window(),
    ?assertEqual(ok, erx_blk_drive:occupy(Grant, Occupant)),
    Stray = window(),
    ok = erx_blk_drive:serve(Grant, Stray, {self(), stray_medium}),
    ?assertEqual({error, no_medium}, erx_blk_drive:window(Grant)),
    Window = window(),
    ok = erx_blk_drive:serve(Grant, Window, {Occupant, its_medium}),
    ?assertEqual({ok, Window}, erx_blk_drive:window(Grant)),
    lists:foreach(fun end_window/1, [Stray, Window, Occupant]),
    unlink(Grant),
    exit(Grant, kill).
