%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(erx_lvgl_screen).
-moduledoc """
A model screen for erx-lvgl on the host: it plays erx_ui_lvgl, the widget
server and the display over the program's two pipes and the window's
buffer, a file both map (docs/design-display.md, "The widget server" and
"Kiosks and glasses"). It starts the program with the file as descriptor 3
through test/fixtures/erx_lvgl_buffer.rb, sends the screen record and a
widget tree, and answers each damage report with `presented` once it has
checked it. It checks what erx_ui_lvgl and the display rely on:

* every rectangle of a report lies within the size the report names, the
  size it was drawn at, and no report comes before the last one is
  answered;
* the program draws nothing between a report and its `presented`: the
  buffer's bytes are compared at both ends of that interval, and once with
  a tree change written into it, as erx_ui_lvgl writes one it sent before
  it read the report;
* after the first frame the label's band is not all background, so the
  tree was drawn where the layout puts it;
* a tree change that invalidates three areas apart from each other comes
  as one report of three rectangles: the program answers a refresh's first
  two flushes at once and only the last waits on `presented`, and one that
  holds every flush until `presented` stops at the second area;
* a press and release on the button comes back as `on_click` on the
  button's node, and on nothing else;
* the program falls silent after each change, so an idle program reports
  nothing;
* a repaint is reported as the whole screen's area;
* after a smaller screen record the next report lies within the new size;
* a report that sits unread while a resize's screen record is written
  names the old size, so it is dropped, presented as nothing and
  answered, and the next report covers the new size: once shrinking,
  where the old report's rectangles leave the new size, and once
  growing, where they fit it but its rows have the old stride.

refused/2 checks that the program stops, with status 1, at a screen whose
rows at its stride do not fit the buffer (LVGL would draw past the
mapping), and at a presented record that answers no report.

run/2 raises at the first check that fails and otherwise returns a
summary.
""".

-export([run/2, refused/2]).

-define(WIDTH, 240).
-define(HEIGHT, 160).
%% Plan 9's channel descriptors (draw(2)): x8r8g8b8 and r5g6b5.
-define(X8R8G8B8, 16#68081828).
-define(R5G6B5, 16#051625).
%% The column's padding, odd so that areas start off a 32-bit word.
-define(PAD, 5).
%% The tree: a column of a label, a button, and two more labels, each after
%% a spacer, so that the three labels lie apart from each other.
-define(LABEL, 2).
-define(BUTTON, 3).
-define(MIDDLE, 5).
-define(BOTTOM, 7).
-define(LABEL_HEIGHT, 30).
-define(BUTTON_HEIGHT, 40).
-define(SMALL_HEIGHT, 20).
-define(GAP, 10).
%% How long the program must stay silent, once a change is shown, for the
%% change to count as complete, and how long a change may take in all, from
%% the request until the program is silent again. A sanitized program on a
%% loaded host is slow to show a change, so the wait for the change has the
%% long bound, and only the silence after it is a fixed window.
-define(QUIET_MS, 500).
-define(SETTLE_MS, 60000).
%% How long each report stays unanswered while the buffer is watched.
-define(HOLD_MS, 200).

-doc """
Runs the scenario against the erx-lvgl at `program`, started by `ruby`
running `launcher` (test/fixtures/erx_lvgl_buffer.rb), on a screen of
channel `x8r8g8b8` or `r5g6b5`. The buffer is the file `buffer` in the
current directory.
""".
-spec run(#{program := file:filename(), ruby := file:filename(), launcher := file:filename()},
          x8r8g8b8 | r5g6b5) -> map().
run(#{program := Program, ruby := Ruby, launcher := Launcher}, Channel) ->
    {Chan, Depth} = case Channel of
                        x8r8g8b8 -> {?X8R8G8B8, 32};
                        r5g6b5 -> {?R5G6B5, 16}
                    end,
    Buffer = filename:absname("buffer"),
    ok = file:write_file(Buffer, binary:copy(<<0>>, stride(?WIDTH, Depth) * ?HEIGHT)),
    Port = open_port({spawn_executable, Ruby},
                     [binary, stream, use_stdio, exit_status, {args, [Launcher, Buffer, Program]}]),
    Screen = #{port => Port, buffer => Buffer, depth => Depth, size => {?WIDTH, ?HEIGHT}},
    send(Screen, [{screen, ?WIDTH, ?HEIGHT, Chan} | ops()]),
    {First, []} = settle(Screen, [], fun(Reports, _) -> Reports =/= [] end),
    true = label_drawn(Screen) orelse error(label_not_drawn),
    Y = ?PAD + ?LABEL_HEIGHT + ?BUTTON_HEIGHT div 2,
    send(Screen, [{input, {pointer, ?WIDTH div 2, Y, 1}},
                  {input, {pointer, ?WIDTH div 2, Y, 0}}]),
    {Pressed, Events} = settle(Screen, [], fun(_, Es) -> Es =/= [] end),
    [{event, ?BUTTON, on_click, none}] = Events,
    send(Screen, [{set, Node, #{text => <<"changed">>}, []} || Node <- [?LABEL, ?MIDDLE, ?BOTTOM]] ++ [commit]),
    {[Three], []} = settle(Screen, [], fun(Rs, _) -> Rs =/= [] end),
    3 = length(Three),
    %% The label starts at the odd pixel PAD, so its change is an area off a
    %% word. The late change is written while the first report is open.
    Late = [{set, ?LABEL, #{text => <<"late">>}, []}, commit],
    send(Screen, [{set, ?LABEL, #{text => <<"pressed">>}, []}, commit]),
    {Changed, []} = settle(Screen, Late, fun(Rs, _) -> length(Rs) >= 2 end),
    send(Screen, [repaint]),
    {Repaint, []} = settle(Screen, [], fun(Rs, _) -> area(Rs) >= ?WIDTH * ?HEIGHT end),
    ?WIDTH * ?HEIGHT = area(Repaint),
    Smaller = Screen#{size := {?WIDTH div 2, ?HEIGHT div 2}},
    send(Smaller, [{screen, ?WIDTH div 2, ?HEIGHT div 2, Chan}]),
    {Resized, []} = settle(Smaller, [], fun(Rs, _) -> Rs =/= [] end),
    Stale = [stale(Smaller, {?WIDTH div 4, ?HEIGHT div 4}, Chan),
             stale(Smaller#{size := {?WIDTH div 4, ?HEIGHT div 4}}, {?WIDTH, ?HEIGHT}, Chan)],
    port_close(Port),
    #{first => First, pressed => length(Pressed), three => Three, changed => length(Changed),
      repaint => Repaint, resized => Resized, stale => Stale, events => Events}.

-doc """
Starts the program as run/2 does and returns its exit status after one
case it must refuse: `short_buffer`, a buffer one row short of the screen
record sent, or `stray_presented`, a presented record sent with the screen
record, before any report.
""".
-spec refused(#{program := file:filename(), ruby := file:filename(), launcher := file:filename()},
              short_buffer | stray_presented) -> non_neg_integer().
refused(#{program := Program, ruby := Ruby, launcher := Launcher}, Case) ->
    Rows = case Case of short_buffer -> ?HEIGHT - 1; stray_presented -> ?HEIGHT end,
    Buffer = filename:absname("buffer"),
    ok = file:write_file(Buffer, binary:copy(<<0>>, stride(?WIDTH, 32) * Rows)),
    Port = open_port({spawn_executable, Ruby},
                     [binary, stream, use_stdio, exit_status, {args, [Launcher, Buffer, Program]}]),
    Records = [{screen, ?WIDTH, ?HEIGHT, ?X8R8G8B8} | [presented || Case =:= stray_presented]],
    send(#{port => Port}, Records),
    exit_status(Port, erlang:monotonic_time(millisecond) + ?SETTLE_MS).

exit_status(Port, Deadline) ->
    receive
        {Port, {data, _}} -> exit_status(Port, Deadline);
        {Port, {exit_status, Status}} -> Status
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        error(never_stopped)
    end.

%% The tree, as erx_ui_model:delta/2 makes it from the empty tree.
ops() ->
    Small = fun(Node, Index, Text) ->
                    {insert, Node, 1, Index, label, #{height => ?SMALL_HEIGHT, text => Text}}
            end,
    Tree = [{insert, 1, 0, 0, column, #{pad => ?PAD}},
            {insert, ?LABEL, 1, 0, label,
             #{height => ?LABEL_HEIGHT, text => <<"erXos kiosk">>}},
            {insert, ?BUTTON, 1, 1, button,
             #{height => ?BUTTON_HEIGHT, text => <<"Press">>, on_click => pressed}},
            {insert, 4, 1, 2, spacer, #{height => ?GAP}},
            Small(?MIDDLE, 3, <<"middle">>),
            {insert, 6, 1, 4, spacer, #{height => ?GAP}},
            Small(?BOTTOM, 5, <<"bottom">>),
            commit],
    {ok, Realised} = erx_ui_model:apply_ops(Tree, erx_ui_model:empty()),
    erx_ui_model:delta(erx_ui_model:empty(), Realised).

send(#{port := Port}, Records) ->
    Present = fun(_Type, _Value) -> error(no_presentations) end,
    true = port_command(Port, [erx_ui_wire:encode(R, Present) || R <- Records]).

%% What the program sends for a change: its damage reports, each checked
%% and answered (answer/5), and its events. Late is written while the first
%% report is open. It waits, up to SETTLE_MS in all, until
%% Shown(Reports, Events) holds of what has arrived, the condition that
%% says the change is on screen, and then until the program is silent for
%% QUIET_MS. Silence alone cannot say the change is shown: a slow program
%% stays silent before its first report.
settle(Screen, Late, Shown) ->
    settle(Screen, Late, Shown, <<>>).

settle(Screen, Late, Shown, Unread) ->
    Deadline = erlang:monotonic_time(millisecond) + ?SETTLE_MS,
    settle(Screen, Late, Shown, Unread, [], [], Deadline).

settle(#{port := Port} = Screen, Late, Shown, Unread, Reports, Events, Deadline) ->
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
            case records(<<Unread/binary, Data/binary>>, [], Events) of
                {[], Es, Rest} ->
                    settle(Screen, Late, Shown, Rest, Reports, Es, Deadline);
                {[{_Drawn, Rects} = Report], Es, Rest} ->
                    %% Only stale/3 writes a screen record while a report is
                    %% unread, so here every report names the current size.
                    {presented, Es1, Rest1} = answer(Screen, Report, Late, Rest, Es),
                    settle(Screen, [], Shown, Rest1, Reports ++ [Rects], Es1, Deadline);
                {[_, _ | _], _, _} ->
                    error(report_before_presented)
            end;
        {Port, {exit_status, Status}} ->
            error({renderer_down, Status})
    after Wait ->
        case IsShown andalso Wait =:= ?QUIET_MS of
            true ->
                <<>> = Unread,
                {Reports, Events};
            false ->
                error(never_settled(IsShown, Reports, Events))
        end
    end.

%% A resize written while a report sits unread: a repaint's report has
%% arrived, and the model, which has decoded it, acts as a server that has
%% not read it yet: it writes a screen record of Size first, as erx_ui_lvgl
%% does when it reads a resize before the report. The report names
%% the size it was drawn at, which is not Size, so it is dropped; the next
%% report covers the whole new screen. Returns the dropped report's size.
stale(#{port := Port} = Screen, {W, H} = Size, Chan) ->
    send(Screen, [repaint]),
    {{Drawn, _Rects} = Report, Rest} = await_report(Port, <<>>, erlang:monotonic_time(millisecond) + ?SETTLE_MS),
    Resized = Screen#{size := Size},
    send(Resized, [{screen, W, H, Chan}]),
    {dropped, [], Rest1} = answer(Resized, Report, [], Rest, []),
    {_Next, []} = settle(Resized, [], fun(Rs, _) -> area(Rs) >= W * H end, Rest1),
    Drawn.

%% The program's first record, which must be a damage report, and the bytes
%% after it, waiting up to Deadline for it to arrive whole.
await_report(Port, Bytes, Deadline) ->
    case records(Bytes, [], []) of
        {[Report], [], Rest} -> {Report, Rest};
        {[_, _ | _], _, _} -> error(report_before_presented);
        {_, [_ | _] = Events, _} -> error({unexpected_events, Events});
        {[], [], _} ->
            receive
                {Port, {data, Data}} -> await_report(Port, <<Bytes/binary, Data/binary>>, Deadline);
                {Port, {exit_status, Status}} -> error({renderer_down, Status})
            after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
                error(never_reported)
            end
    end.

never_settled(true, Reports, _Events) -> {never_idle, length(Reports)};
never_settled(false, Reports, Events) -> {never_shown, length(Reports), length(Events)}.

%% A damage report, whose rectangles the reader checked against the size
%% the report names: held open for HOLD_MS with Late written to the
%% program, and answered with presented unless the buffer changed meanwhile
%% or another report came. It is `presented` when it names the size of the
%% last screen record written, and `dropped`, shown as nothing, when it was
%% drawn at another size, whose stride the buffer's rows no longer have.
answer(#{size := Size} = Screen, {Drawn, _Rects}, Late, Unread, Events) ->
    Before = snapshot(Screen),
    send(Screen, Late),
    {Es, Rest} = hold(Screen, Unread, Events, erlang:monotonic_time(millisecond) + ?HOLD_MS),
    Before =:= snapshot(Screen) orelse error(drew_while_report_open),
    send(Screen, [presented]),
    Outcome = case Drawn of
                  Size -> presented;
                  _ -> dropped
              end,
    {Outcome, Es, Rest}.

hold(#{port := Port} = Screen, Unread, Events, Until) ->
    receive
        {Port, {data, Data}} ->
            case records(<<Unread/binary, Data/binary>>, [], Events) of
                {[], Es, Rest} -> hold(Screen, Rest, Es, Until);
                {[_ | _], _, _} -> error(report_before_presented)
            end;
        {Port, {exit_status, Status}} ->
            error({renderer_down, Status})
    after max(0, Until - erlang:monotonic_time(millisecond)) ->
        {Events, Unread}
    end.

%% The whole records of Bytes: the damage reports in order, each as the size
%% it was drawn at and its rectangles, the events after Events, and the
%% bytes left.
records(Bytes, Reports, Events) ->
    case erx_ui_wire:read(Bytes) of
        {ok, {damage, W, H, Rects}, Rest} ->
            records(Rest, [{{W, H}, Rects} | Reports], Events);
        {ok, {event, _, _, _} = Event, Rest} ->
            records(Rest, Reports, Events ++ [Event]);
        more ->
            {lists:reverse(Reports), Events, Bytes};
        {error, Reason} ->
            error({bad_record, Reason})
    end.

snapshot(#{buffer := Buffer}) ->
    {ok, Bytes} = file:read_file(Buffer),
    Bytes.

%% Whether the label's band of the buffer is not all background, taken to
%% be the colour of the screen's last pixel.
label_drawn(#{depth := Depth} = Screen) ->
    Bytes = snapshot(Screen),
    Background = pixel(Bytes, ?WIDTH - 1, ?HEIGHT - 1, Depth),
    lists:any(fun({X, Y}) -> pixel(Bytes, X, Y, Depth) =/= Background end,
              [{X, Y} || Y <- lists:seq(?PAD, ?PAD + ?LABEL_HEIGHT - 1),
                         X <- lists:seq(0, ?WIDTH - 1)]).

area(Reports) -> lists:sum([W * H || Rects <- Reports, {_, _, W, H} <- Rects]).

%% A buffer's rows (docs/design-display.md, "Windows and buffers"): the
%% row's bits rounded up to 32.
stride(Width, Depth) -> 4 * ((Width * Depth + 31) div 32).

pixel(Bytes, X, Y, Depth) ->
    binary:part(Bytes, Y * stride(?WIDTH, Depth) + X * Depth div 8, Depth div 8).
