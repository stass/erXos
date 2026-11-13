%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_ui_lvgl_core, the LVGL renderer's decisions about its
%% program's pipes (docs/design-display.md, "The widget server"). A
%% protocol state machine, so it is explored exhaustively: from the start,
%% every event in every reachable state, up to ?DEPTH events, over two
%% screen sizes. A shell beside the core plays erx_ui_lvgl: it performs
%% each action, keeps what was written to the program, and checks after
%% every step what the program and the widget server rely on:
%%
%% * a present is made only of a report drawn at the size of the last
%%   screen record written, and a report of another size read while idle
%%   is answered at once with `presented` and nothing else;
%% * while a present is outstanding the program is written nothing but
%%   screen records, and a resize's screen record is written at once, in
%%   any state;
%% * every report is answered exactly once: `presented` is written as many
%%   times as reports were read, less one while a present is outstanding,
%%   and the answer to a present is the first record written at `shown`;
%% * the operations of each apply and the window's records reach the
%%   program in the order they came, nothing waits while idle, and an apply
%%   is answered only after its operations were written, at once when idle
%%   and at the answer to the open report otherwise;
%% * a report read while one is open, a refused record and the program's
%%   exit stop it, and an event is passed on as a hit in any state.
%%
%% The two events the shell never sends, `shown` with no present
%% outstanding and an apply before the last is answered, raise in every
%% reachable state.
-module(erx_ui_lvgl_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DEPTH, 6).
-define(BIG, {4, 3}).
-define(SMALL, {2, 2}).
-define(CHAN, 16#68081828).
-define(RECTS, [{0, 0, 1, 1}]).

%% The shell's view: the core's state, everything written to the program
%% in order, the present outstanding or none, the applies not yet answered,
%% the records submitted to the program in order (operations and window
%% records), the number of reports read, and the number of events stepped,
%% which makes each apply's operations and token unique.
-record(shell, {core, written = [], present = none, waiting = [], submitted = [],
                reports = 0, serial = 0}).

every_reachable_state_keeps_the_protocol_test_() ->
    {timeout, 300, fun() ->
                           {Core, Actions} = erx_ui_lvgl_core:start(4, 3, ?CHAN),
                           Shell = perform(Actions, #shell{core = Core}),
                           [{screen, 4, 3, ?CHAN}] = Shell#shell.written,
                           States = explore(?DEPTH, Shell),
                           ?debugFmt("~b states explored", [States])
                   end}.

a_resize_during_a_present_is_written_at_once_and_the_report_still_shown_test() ->
    {Idle, _} = erx_ui_lvgl_core:start(4, 3, ?CHAN),
    {ok, Open, [{present, 4, 3, ?RECTS}]} = erx_ui_lvgl_core:step({damage, 4, 3, ?RECTS}, Idle),
    {ok, Resized, [{write, [{screen, 2, 2, ?CHAN}]}]} = erx_ui_lvgl_core:step({resize, 2, 2, ?CHAN}, Open),
    {ok, Again, [{write, [presented]}]} = erx_ui_lvgl_core:step(shown, Resized),
    {2, 2} = erx_ui_lvgl_core:size(Again),
    %% The program's next report, drawn after it read the screen record.
    {ok, _, [{present, 2, 2, ?RECTS}]} = erx_ui_lvgl_core:step({damage, 2, 2, ?RECTS}, Again).

held_records_follow_the_answer_in_order_test() ->
    {Idle, _} = erx_ui_lvgl_core:start(4, 3, ?CHAN),
    {ok, Open, _} = erx_ui_lvgl_core:step({damage, 4, 3, ?RECTS}, Idle),
    {ok, Open1, []} = erx_ui_lvgl_core:step({window, {input, {wheel, 1}}}, Open),
    Ops = [{set, 2, #{text => <<"a">>}, []}, commit],
    {ok, Open2, []} = erx_ui_lvgl_core:step({apply, Ops, from}, Open1),
    {ok, Open3, []} = erx_ui_lvgl_core:step({window, repaint}, Open2),
    {ok, _, [{write, Written}, {reply, from}]} = erx_ui_lvgl_core:step(shown, Open3),
    [presented, {input, {wheel, 1}} | Rest] = Written,
    Rest = Ops ++ [repaint].

%% Depth-first over every event in every state; returns the number of
%% states visited.
explore(0, _Shell) ->
    1;
explore(Depth, Shell) ->
    lists:foldl(fun(Event, Count) ->
                        case try_step(Event, Shell) of
                            {next, Shell1} -> Count + explore(Depth - 1, Shell1);
                            stopped -> Count + 1
                        end
                end, 1, events(Shell)).

events(#shell{serial = N}) ->
    {BW, BH} = ?BIG,
    {SW, SH} = ?SMALL,
    [{apply, [{set, N + 1, #{}, []}, commit], {apply, N}},
     {window, {input, {wheel, N rem 100}}},
     {window, repaint},
     {resize, BW, BH, ?CHAN},
     {resize, SW, SH, ?CHAN},
     {damage, BW, BH, ?RECTS},
     {damage, SW, SH, ?RECTS},
     {event, 2, on_click, none},
     shown,
     {refused, {bad_tag, 1}},
     {exit, 1},
     {lost, epipe}].

%% Steps the core with Event and checks the result. An event the shell
%% never sends must raise.
try_step(shown, #shell{present = none, core = Core}) ->
    ?assertError(no_present_open, erx_ui_lvgl_core:step(shown, Core)),
    stopped;
try_step({apply, _, _} = Event, #shell{waiting = [_ | _], core = Core}) ->
    ?assertError(apply_in_flight, erx_ui_lvgl_core:step(Event, Core)),
    stopped;
try_step(Event, #shell{core = Core} = Shell) ->
    Result = erx_ui_lvgl_core:step(Event, Core),
    case expected_stop(Event, Shell) of
        none ->
            {ok, Core1, Actions} = Result,
            Shell1 = perform(Actions, record(Event, Shell#shell{core = Core1,
                                                               serial = Shell#shell.serial + 1})),
            check(Event, Actions, Shell, Shell1),
            {next, Shell1};
        Reason ->
            ?assertEqual({stop, Reason}, Result),
            stopped
    end.

expected_stop({damage, _, _, _}, #shell{present = {_, _, _}}) -> report_before_presented;
expected_stop({refused, _} = Reason, _Shell) -> Reason;
expected_stop({exit, _} = Reason, _Shell) -> Reason;
expected_stop({lost, _} = Reason, _Shell) -> Reason;
expected_stop(_Event, _Shell) -> none.

%% What the shell learns from the event itself, before the actions.
record({apply, Ops, Token}, Shell) ->
    Shell#shell{waiting = [Token], submitted = Shell#shell.submitted ++ Ops};
record({window, Record}, Shell) ->
    Shell#shell{submitted = Shell#shell.submitted ++ [Record]};
record({damage, _, _, _}, Shell) ->
    Shell#shell{reports = Shell#shell.reports + 1};
record(shown, Shell) ->
    Shell#shell{present = none};
record(_Event, Shell) ->
    Shell.

perform(Actions, Shell) ->
    lists:foldl(fun perform_one/2, Shell, Actions).

perform_one({write, Records}, Shell) ->
    Shell#shell{written = Shell#shell.written ++ Records};
perform_one({present, W, H, Rects}, #shell{present = none} = Shell) ->
    Shell#shell{present = {W, H, Rects}};
perform_one({reply, {apply, N} = Token}, #shell{waiting = [Token]} = Shell) ->
    %% An apply is answered only after its operations were written, so the
    %% order of the actions within one step counts too.
    lists:member({set, N + 1, #{}, []}, Shell#shell.written) orelse error({reply_before_ops, Token}),
    Shell#shell{waiting = []};
perform_one({hit, _, _, _}, Shell) ->
    Shell.

%% Each property of the moduledoc's list, checked after every step; New
%% is what the step wrote.
check(Event, Actions, Before, After) ->
    Fail = fun(What) -> error({What, Event, Actions, Before#shell.core}) end,
    New = lists:nthtail(length(Before#shell.written), After#shell.written),
    present_only_at_last_screen(Event, Actions, last_screen(Before#shell.written), Fail),
    only_screens_while_open(Before, After, New, Fail),
    resize_written_at_once(Event, New, Fail),
    each_report_answered_once(Event, After, New, Fail),
    submitted_in_order(After, Fail),
    event_is_a_hit(Event, Actions, Fail),
    erx_ui_lvgl_core:size(After#shell.core) =:= last_screen(After#shell.written)
        orelse Fail(size_is_not_last_screen),
    erx_ui_lvgl_core:reads_window(After#shell.core) =:= (After#shell.present =:= none)
        orelse Fail(reads_window_while_open).

%% A present only of a report at the last screen record's size; one of
%% another size read while idle is answered at once and alone.
present_only_at_last_screen({damage, W, H, R}, Actions, LastScreen, Fail) ->
    case Actions of
        [{present, W, H, R}] when {W, H} =:= LastScreen -> ok;
        [{write, [presented]}] when {W, H} =/= LastScreen -> ok;
        _ -> Fail(misjudged_report)
    end;
present_only_at_last_screen(_Event, Actions, _LastScreen, Fail) ->
    case [A || {present, _, _, _} = A <- Actions] of
        [] -> ok;
        _ -> Fail(present_without_report)
    end.

%% Nothing but screen records while a present is outstanding.
only_screens_while_open(#shell{present = {_, _, _}}, #shell{present = {_, _, _}}, New, Fail) ->
    case [R || R <- New, not is_screen(R)] of
        [] -> ok;
        _ -> Fail(wrote_while_open)
    end;
only_screens_while_open(_Before, _After, _New, _Fail) ->
    ok.

resize_written_at_once({resize, W, H, Chan}, New, Fail) ->
    case New of
        [{screen, W, H, Chan}] -> ok;
        _ -> Fail(resize_not_written)
    end;
resize_written_at_once(_Event, _New, _Fail) ->
    ok.

%% `presented` written as many times as reports were read, less one while
%% a present is outstanding, and first at the answer to a present.
each_report_answered_once(Event, After, New, Fail) ->
    Presented = length([R || R <- After#shell.written, R =:= presented]),
    Open = case After#shell.present of none -> 0; _ -> 1 end,
    case Presented =:= After#shell.reports - Open of
        true -> ok;
        false -> Fail(answers_do_not_match_reports)
    end,
    case {Event, New} of
        {shown, [presented | _]} -> ok;
        {shown, _} -> Fail(answer_not_first);
        _ -> ok
    end.

%% The submitted records reach the program in order, nothing waits while
%% idle, and every apply is answered by then.
submitted_in_order(After, Fail) ->
    Passed = [R || R <- After#shell.written, R =/= presented, not is_screen(R)],
    lists:prefix(Passed, After#shell.submitted) orelse Fail(out_of_order),
    case After of
        #shell{present = none, submitted = Submitted} when Passed =/= Submitted -> Fail(held_while_idle);
        #shell{present = none, waiting = [_ | _]} -> Fail(apply_unanswered_while_idle);
        _ -> ok
    end.

event_is_a_hit({event, Node, Name, Value}, Actions, Fail) ->
    case Actions of
        [{hit, Node, Name, Value}] -> ok;
        _ -> Fail(event_not_hit)
    end;
event_is_a_hit(_Event, _Actions, _Fail) ->
    ok.

last_screen(Written) ->
    {screen, W, H, _} = lists:last([R || {screen, _, _, _} = R <- Written]),
    {W, H}.

is_screen({screen, _, _, _}) -> true;
is_screen(_Record) -> false.
