%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(erx_lvgl_screen).
-moduledoc """
A model screen for erx-lvgl on the host: it plays erx_ui_kiosk and the
widget server over the program's two pipes (docs/design-display.md,
"The widget server" and "Kiosks and glasses"). It sends the screen
record, a small widget tree, a press on the tree's button and a
repaint, keeps the pixels it is sent on a canvas, and checks what a
screen owner relies on:

* every report lies within the screen and holds exactly its rectangle's
  rows in the channel, Plan 9's bytesperline each, as erx_ui_kiosk:flush/2
  checks; the tree's padding is odd, so on a 16-bit channel this fails
  unless each area starts on a 32-bit word;
* after the first frame the label's band is not all background, so the
  tree was rendered where the layout puts it;
* a press and release on the button comes back as `on_click` on the
  button's node, and on nothing else;
* the program falls silent after each change, so an idle program
  reports nothing;
* a repaint is reported as the whole screen's area.

run/2 raises at the first check that fails and otherwise returns a
summary.
""".

-export([run/2]).

-define(WIDTH, 240).
-define(HEIGHT, 160).
%% Plan 9's channel descriptors (draw(2)): x8r8g8b8 and r5g6b5.
-define(X8R8G8B8, 16#68081828).
-define(R5G6B5, 16#051625).
%% The column's padding, odd so that areas start off a 32-bit word.
-define(PAD, 5).
-define(LABEL, 2).
-define(BUTTON, 3).
-define(LABEL_HEIGHT, 40).
-define(BUTTON_HEIGHT, 60).
%% How long the program must stay silent, once a change is shown, for the
%% change to count as complete, and how long a change may take in all, from
%% the request until the program is silent again. A sanitized program on a
%% loaded host is slow to show a change, so the wait for the change has the
%% long bound, and only the silence after it is a fixed window.
-define(QUIET_MS, 500).
-define(SETTLE_MS, 60000).

-doc "Runs the scenario against the erx-lvgl at Program on a screen of channel `x8r8g8b8` or `r5g6b5`.".
-spec run(file:filename(), x8r8g8b8 | r5g6b5) -> map().
run(Program, Channel) ->
    {Chan, Depth} = case Channel of
                        x8r8g8b8 -> {?X8R8G8B8, 32};
                        r5g6b5 -> {?R5G6B5, 16}
                    end,
    Port = open_port({spawn_executable, Program},
                     [binary, stream, use_stdio, exit_status]),
    send(Port, [{screen, ?WIDTH, ?HEIGHT, Chan}
               | ops()]),
    {First, []} = settle(Port, Depth, fun(Reports, _) -> label_drawn(Reports, Depth) end),
    true = label_drawn(First, Depth) orelse error(label_not_drawn),
    Y = ?PAD + ?LABEL_HEIGHT + ?BUTTON_HEIGHT div 2,
    send(Port, [{input, {pointer, ?WIDTH div 2, Y, 1}},
                {input, {pointer, ?WIDTH div 2, Y, 0}}]),
    {Pressed, Events} = settle(Port, Depth, fun(_, Es) -> Es =/= [] end),
    [{event, ?BUTTON, on_click, none}] = Events,
    %% The label starts at the odd pixel PAD, so its change is an area off a word.
    send(Port, [{set, ?LABEL, #{text => <<"pressed">>}, []}, commit]),
    {Changed, []} = settle(Port, Depth, fun(Rs, _) -> Rs =/= [] end),
    [_ | _] = Changed,
    send(Port, [repaint]),
    {Repaint, []} = settle(Port, Depth, fun(Rs, _) -> area(Rs) >= ?WIDTH * ?HEIGHT end),
    ?WIDTH * ?HEIGHT = area(Repaint),
    port_close(Port),
    #{first => length(First), pressed => length(Pressed),
      changed => [{X, W} || {pixels, X, _, W, _, _} <- Changed],
      repaint => length(Repaint), events => Events}.

%% A column holding a label and a button of fixed heights, as
%% erx_ui_model:delta/2 makes them from the empty tree.
ops() ->
    Tree = [{insert, 1, 0, 0, column, #{pad => ?PAD}},
            {insert, ?LABEL, 1, 0, label,
             #{height => ?LABEL_HEIGHT, text => <<"erXos kiosk">>}},
            {insert, ?BUTTON, 1, 1, button,
             #{height => ?BUTTON_HEIGHT, text => <<"Press">>, on_click => pressed}},
            commit],
    {ok, Realised} = erx_ui_model:apply_ops(Tree, erx_ui_model:empty()),
    erx_ui_model:delta(erx_ui_model:empty(), Realised).

send(Port, Records) ->
    Present = fun(_Type, _Value) -> error(no_presentations) end,
    true = port_command(Port, [erx_ui_wire:encode(R, Present) || R <- Records]).

%% What the program sends for a change: its pixels reports, each checked
%% against the screen, and its events. It waits, up to SETTLE_MS in all,
%% until Shown(Reports, Events) holds of what has arrived, the condition
%% that says the change is on screen, and then until the program is silent
%% for QUIET_MS. Silence alone cannot say the change is shown: a slow
%% program stays silent before its first report.
settle(Port, Depth, Shown) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SETTLE_MS,
    settle(Port, Depth, Shown, <<>>, [], [], Deadline).

settle(Port, Depth, Shown, Buffer, Reports, Events, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    IsShown = Shown(Reports, Events),
    %% Checked on every pass, so a program that never stops writing fails too.
    Remaining > 0 orelse error(never_settled(IsShown, Reports, Events)),
    Wait = case IsShown of
               true -> min(?QUIET_MS, Remaining);
               false -> Remaining
           end,
    receive
        {Port, {data, Data}} ->
            {Rs, Es, Rest} = records(<<Buffer/binary, Data/binary>>, Depth, [], []),
            settle(Port, Depth, Shown, Rest, Reports ++ Rs, Events ++ Es, Deadline);
        {Port, {exit_status, Status}} ->
            error({renderer_down, Status})
    after Wait ->
        case IsShown andalso Wait =:= ?QUIET_MS of
            true ->
                <<>> = Buffer,
                {Reports, Events};
            false ->
                error(never_settled(IsShown, Reports, Events))
        end
    end.

never_settled(true, Reports, _Events) -> {never_idle, length(Reports)};
never_settled(false, Reports, Events) -> {never_shown, length(Reports), length(Events)}.

%% Whether the label's band of the screen painted by Reports is not all
%% background, taken to be the colour of the screen's last pixel.
label_drawn(Reports, Depth) ->
    Canvas = paint(blank(Depth), Reports, Depth),
    Background = pixel(Canvas, ?WIDTH - 1, ?HEIGHT - 1, Depth),
    lists:any(fun({X, Y}) -> pixel(Canvas, X, Y, Depth) =/= Background end,
              [{X, Y} || Y <- lists:seq(?PAD, ?PAD + ?LABEL_HEIGHT - 1),
                         X <- lists:seq(0, ?WIDTH - 1)]).

area(Reports) -> lists:sum([W * H || {pixels, _, _, W, H, _} <- Reports]).

records(Bytes, Depth, Reports, Events) ->
    case erx_ui_wire:read(Bytes) of
        {ok, {pixels, _, _, _, _, _} = Report, Rest} ->
            records(Rest, Depth, [check(Report, Depth) | Reports], Events);
        {ok, {event, _, _, _} = Event, Rest} ->
            records(Rest, Depth, Reports, [Event | Events]);
        more ->
            {lists:reverse(Reports), lists:reverse(Events), Bytes};
        {error, Reason} ->
            error({bad_record, Reason})
    end.

%% erx_ui_kiosk:flush/2's checks: within the screen, exactly its rows.
check({pixels, X, Y, W, H, Pixels} = Report, Depth) ->
    true = W > 0 andalso H > 0 andalso X + W =< ?WIDTH andalso Y + H =< ?HEIGHT
        orelse error({outside_screen, X, Y, W, H}),
    true = byte_size(Pixels) =:= bytes_per_line(X, W, Depth) * H
        orelse error({bad_size, X, Y, W, H, byte_size(Pixels)}),
    Report.

%% Plan 9's bytesperline: the 32-bit words covering the row's bits.
bytes_per_line(X, W, Depth) ->
    4 * (((X + W) * Depth + 31) div 32 - X * Depth div 32).

%% The canvas: the screen's rows, by row number. Depth is 16 or 32, so a
%% report starts its rows at its left edge, which check/2 verified.
blank(Depth) ->
    maps:from_list([{Y, binary:copy(<<0:Depth>>, ?WIDTH)}
                    || Y <- lists:seq(0, ?HEIGHT - 1)]).

paint(Canvas, Reports, Depth) ->
    lists:foldl(fun(Report, Acc) -> paint_report(Report, Acc, Depth div 8) end, Canvas, Reports).

paint_report({pixels, X, Y, W, H, Pixels}, Canvas, Bytes) ->
    Stride = bytes_per_line(X, W, Bytes * 8),
    Width = W * Bytes,
    lists:foldl(
      fun(Row, Acc) ->
              <<Left:(X * Bytes)/binary, _:Width/binary, Right/binary>> = maps:get(Y + Row, Acc),
              Line = binary:part(Pixels, Row * Stride, Width),
              Acc#{Y + Row => <<Left/binary, Line/binary, Right/binary>>}
      end, Canvas, lists:seq(0, H - 1)).

pixel(Canvas, X, Y, Depth) -> binary:part(maps:get(Y, Canvas), X * Depth div 8, Depth div 8).
