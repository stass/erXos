%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_lvgl_core).
-moduledoc """
The decisions of the LVGL renderer, erx_ui_lvgl, about the two pipes it
shares with the program erx-lvgl (docs/design-display.md, "The widget
server"): what it writes to the program, when it presents the window's
buffer, and when the program has broken the protocol. A pure state
machine: step/2 takes the renderer's state and one event and returns the
next state and the actions erx_ui_lvgl performs, in order, or a reason to
stop the program.

The program draws a frame into the window's buffer and reports it with
one `damage` record that names the width and height it drew at and the
rectangles it drew. Until that report is answered with `presented` the
program draws nothing. So the renderer is either `idle`, with no report
open, or `open`, presenting one report; in both it knows the size of the
last `screen` record it wrote, the only size whose stride the buffer's
rows have.

* A report read while idle is judged at its own size. When that is the
  last screen record's size, the renderer presents its rectangles at that
  width and height and is open until the display answers the present
  (`shown`); then it writes `presented`. A report of another size was
  drawn before the program read a later screen record, at a stride the
  buffer no longer has: it is presented as nothing and answered at once.
* While a report is open the renderer writes the program nothing but a
  resize's `screen` record, at once, and at the answer `presented`: the
  operations of a tree (whose apply is answered only then) and the
  window's input and repaint records wait in order and follow the
  `presented`. A screen record changes no pixel, so the open report is
  still shown at the size it was judged at, clipped by the display as a
  present for a stale size is; the screen record invalidates the
  program's whole screen, so its next report covers the new size.
* A report read while one is open, a record the reader refuses, and the
  program's exit stop the program (erx_ui_lvgl ends the UI with
  `{ui_down, Window, renderer_down}`).
* An event the program reports is passed to the widget server as a hit,
  in any state.

erx_ui_lvgl reads the window's `mouse` and `kbd` only while
reads_window/1 says so, which is while idle, so what waits is at most
the operations of one apply and the records of the reads that were in
flight when the report arrived; a resize comes as the `r` record of a
`mouse` read, so one that arrives while a report is open came from such
a read. A second apply before the
first is answered, and a `shown` with no report open, are the caller's
bugs, raised as errors.
""".

-export([start/3, step/2, size/1, reads_window/1]).
-export_type([state/0, event/0, action/0, stop_reason/0]).

-type size() :: {Width :: 1..65535, Height :: 1..65535}.
-type rect() :: {X :: 0..65535, Y :: 0..65535, Width :: 1..65535, Height :: 1..65535}.
-type token() :: term().
-type held() :: erx_ui_model:diff_op() | {input, term()} | repaint.

-doc """
The renderer's state. `Size` is the last screen record written. An open
report holds the records that wait for its answer, newest first, and the
token of the apply whose operations are among them, or `none`.
""".
-opaque state() :: {idle, size()}
                 | {open, size(), Held :: [held()], Waiter :: token() | none}.

-doc """
What happens to the renderer. `apply` and `window` come from the widget
server and the window, `resize` from the window, `damage`, `event` and
`refused` from the generated reader of the program's output, `shown`
from the display's answer to a present, and `exit` from the program's
end.
""".
-type event() :: {apply, [erx_ui_model:diff_op()], token()}
               | {window, {input, term()} | repaint}
               | {resize, 1..65535, 1..65535, Chan :: 0..16#ffffffff}
               | {damage, 0..65535, 0..65535, [rect(), ...]}
               | {event, erx_ui_model:node_id(), atom(), term()}
               | shown
               | {refused, term()}
               | {exit, non_neg_integer()}.

-doc """
What erx_ui_lvgl does: write records to the program's standard input,
present rectangles of the window's buffer drawn at a width and height,
answer an apply by its token, or hand the widget server a hit as
`{ui_hit, Node, Event, Value}`.
""".
-type action() :: {write, [erx_ui_wire:wire_record()]}
                | {present, 1..65535, 1..65535, [rect(), ...]}
                | {reply, token()}
                | {hit, erx_ui_model:node_id(), atom(), term()}.

-doc "Why the program is stopped, for the log; the UI ends as `renderer_down`.".
-type stop_reason() :: report_before_presented | {refused, term()} | {exit, non_neg_integer()}.

-doc """
The renderer of a window of `Width` by `Height` in channel `Chan`, and
the screen record it writes first, before any other record.
""".
-spec start(1..65535, 1..65535, 0..16#ffffffff) -> {state(), [action()]}.
start(Width, Height, Chan) ->
    {{idle, {Width, Height}}, [{write, [{screen, Width, Height, Chan}]}]}.

-doc "The size of the last screen record written.".
-spec size(state()) -> size().
size({idle, Size}) -> Size;
size({open, Size, _Held, _Waiter}) -> Size.

-doc "Whether erx_ui_lvgl may read the window's next input: only while no report is open.".
-spec reads_window(state()) -> boolean().
reads_window({idle, _Size}) -> true;
reads_window({open, _Size, _Held, _Waiter}) -> false.

-doc """
`{ok, State, Actions}`, the next state and the actions for `Event`, or
`{stop, Reason}` when the program broke the protocol or ended.
""".
-spec step(event(), state()) -> {ok, state(), [action()]} | {stop, stop_reason()}.
step({damage, W, H, Rects}, {idle, {W, H}} = Idle) ->
    {ok, open(Idle), [{present, W, H, Rects}]};
step({damage, _W, _H, _Rects}, {idle, _Size} = Idle) ->
    {ok, Idle, [{write, [presented]}]};
step({damage, _W, _H, _Rects}, {open, _, _, _}) ->
    {stop, report_before_presented};
step(shown, {open, Size, Held, Waiter}) ->
    {ok, {idle, Size}, [{write, [presented | lists:reverse(Held)]} | reply(Waiter)]};
step(shown, {idle, _Size}) ->
    error(no_present_open);
step({apply, Ops, Token}, {idle, _Size} = Idle) ->
    {ok, Idle, [{write, Ops}, {reply, Token}]};
step({apply, Ops, Token}, {open, Size, Held, none}) ->
    {ok, {open, Size, lists:reverse(Ops, Held), Token}, []};
step({apply, _Ops, _Token}, {open, _Size, _Held, _Waiter}) ->
    error(apply_in_flight);
step({window, Record}, {idle, _Size} = Idle) ->
    {ok, Idle, [{write, [Record]}]};
step({window, Record}, {open, Size, Held, Waiter}) ->
    {ok, {open, Size, [Record | Held], Waiter}, []};
step({resize, W, H, Chan}, State) ->
    {ok, resized(State, {W, H}), [{write, [{screen, W, H, Chan}]}]};
step({event, Node, Name, Value}, State) ->
    {ok, State, [{hit, Node, Name, Value}]};
step({refused, Reason}, _State) ->
    {stop, {refused, Reason}};
step({exit, Status}, _State) ->
    {stop, {exit, Status}}.

open({idle, Size}) -> {open, Size, [], none}.

resized({idle, _Old}, Size) -> {idle, Size};
resized({open, _Old, Held, Waiter}, Size) -> {open, Size, Held, Waiter}.

reply(none) -> [];
reply(Token) -> [{reply, Token}].
