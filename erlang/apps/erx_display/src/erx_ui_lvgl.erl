%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_lvgl).
-behaviour(gen_statem).
-moduledoc """
The LVGL renderer (docs/design-display.md, "The widget server"): the
process that runs the program erx-lvgl over its two pipes and performs
what erx_ui_lvgl_core decides. It writes the core's records to the
program's standard input, reads the program's damage reports and events
with erx_ui_wire:read/1, presents a report through the window, answers an
apply, hands the widget server each hit, and ends the UI as
`renderer_down` when the core stops the program. It decides nothing
itself: every judgement is the core's.

Its options:

* `width`, `height` and `chan`: the window's size and channel.
* `open`: starts the program with the window's buffer as descriptor 3 and
  returns its port, opened `binary`, `stream` and `exit_status`. On erXos
  the session starts it as any program, with the buffer as the startup
  message's `mem` descriptor (docs/design-programs.md, "The startup
  message"); on the host test/fixtures/erx_lvgl_buffer.rb hands it a file.
* `present`: presents rectangles of the buffer, drawn at a width and
  height, through the window. The display's answer comes back as shown/1.
* `present_text`: the canonical text of a `present` property
  (erx_ui_wire:present()).
* `ui` and `id`: the widget server, which is sent `{ui_hit, Node, Event,
  Value}` for each hit and `{ui_down, Id, renderer_down}` when the program
  is stopped.

The shell takes the window's input and resizes, window/2 and resize/3,
only while erx_ui_lvgl_core:reads_window/1 holds: in any other state they
stay queued, postponed, until the open report is answered, so the core
holds at most one apply's operations. close/1 closes the program and ends
the shell without consulting the core, so the program's end then is no
fault. A fault ends the shell, and with it an apply/2 that waits. A write
that finds the program gone is dropped, and the program's exit status, or
the port's exit when the write failed it, stops the program as the core
says. A program that stops reading its input blocks the shell in
port_command/2, and with it every call (a residual, TODO.md).
""".

-export([start_link/1, apply/2, window/2, resize/3, shown/1, close/1]).
-export([init/1, callback_mode/0, handle_event/4]).

-type opts() :: #{width := 1..65535, height := 1..65535, chan := 0..16#ffffffff,
                  open := fun(() -> port()),
                  present := fun((1..65535, 1..65535, [erx_ui_lvgl_core:rect(), ...]) -> ok),
                  present_text := erx_ui_wire:present(),
                  ui := pid(), id := term()}.

-doc "Starts the renderer of a window and its program, linked to the caller.".
-spec start_link(opts()) -> gen_statem:start_ret().
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-doc "Applies a tree's operations; returns once they are written to the program.".
-spec apply(pid(), [erx_ui_model:diff_op()]) -> ok.
apply(Shell, Ops) ->
    gen_statem:call(Shell, {apply, Ops}).

-doc "The window's next input record, or a repaint of the whole window.".
-spec window(pid(), {input, term()} | repaint) -> ok.
window(Shell, Record) ->
    gen_statem:cast(Shell, {window, Record}).

-doc "The window's new size.".
-spec resize(pid(), 1..65535, 1..65535) -> ok.
resize(Shell, Width, Height) ->
    gen_statem:cast(Shell, {resize, Width, Height}).

-doc "The display's answer to the last present: the buffer's rectangles are shown.".
-spec shown(pid()) -> ok.
shown(Shell) ->
    gen_statem:cast(Shell, shown).

-doc "Closes the program and ends the renderer; the program's end is then no fault.".
-spec close(pid()) -> ok.
close(Shell) ->
    gen_statem:call(Shell, close).

%% The state is erx_ui_lvgl_core:reads_window/1 of the core: `reading` or
%% `holding`, so the window's records are postponed exactly while the core
%% would hold them. The data holds the core, the port and the bytes of the
%% program's output not yet a whole record.
callback_mode() -> handle_event_function.

init(#{width := W, height := H, chan := Chan, open := Open} = Opts) ->
    %% The port's death without an exit status (a write that found the
    %% program gone fails the port with epipe) reaches the core as `lost`.
    process_flag(trap_exit, true),
    Port = Open(),
    {Core, Actions} = erx_ui_lvgl_core:start(W, H, Chan),
    Data = maps:merge(maps:with([present, present_text, ui, id, chan], Opts),
                      #{core => Core, port => Port, unread => <<>>}),
    {ok, reading, perform(Actions, Data)}.

handle_event({call, From}, {apply, Ops}, _State, Data) ->
    step({apply, Ops, From}, Data);
handle_event(cast, {window, _Record}, holding, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event(cast, {window, Record}, reading, Data) ->
    step({window, Record}, Data);
handle_event(cast, {resize, _W, _H}, holding, _Data) ->
    {keep_state_and_data, [postpone]};
handle_event(cast, {resize, W, H}, reading, #{chan := Chan} = Data) ->
    step({resize, W, H, Chan}, Data);
handle_event(cast, shown, _State, Data) ->
    step(shown, Data);
handle_event(info, {Port, {data, Bytes}}, _State, #{port := Port, unread := Unread} = Data) ->
    output(Data#{unread := <<Unread/binary, Bytes/binary>>});
handle_event(info, {Port, {exit_status, Status}}, _State, #{port := Port} = Data) ->
    step({exit, Status}, Data);
handle_event(info, {'EXIT', Port, Reason}, _State, #{port := Port} = Data) ->
    step({lost, Reason}, Data);
handle_event({call, From}, close, _State, #{port := Port}) ->
    close_port(Port),
    {stop_and_reply, normal, [{reply, From, ok}]}.

%% Each whole record of the program's output, in order, through the core.
output(#{unread := Unread} = Data) ->
    case erx_ui_wire:read(Unread) of
        {ok, Report, Rest} ->
            case step(Report, Data#{unread := Rest}) of
                {next_state, _State, Data1} -> output(Data1);
                Stop -> Stop
            end;
        more ->
            {next_state, state_of(Data), Data};
        {error, Reason} ->
            step({refused, Reason}, Data)
    end.

%% One event through the core: its actions performed and the state it
%% leaves, or the program stopped and the UI ended.
step(Event, #{core := Core} = Data) ->
    case erx_ui_lvgl_core:step(Event, Core) of
        {ok, Core1, Actions} ->
            Data1 = perform(Actions, Data#{core := Core1}),
            {next_state, state_of(Data1), Data1};
        {stop, Reason} ->
            down(Reason, Data)
    end.

state_of(#{core := Core}) ->
    case erx_ui_lvgl_core:reads_window(Core) of
        true -> reading;
        false -> holding
    end.

perform(Actions, Data) ->
    lists:foreach(fun(Action) -> perform_one(Action, Data) end, Actions),
    Data.

%% A write to a port the program's end has closed is dropped: the exit
%% status or the port's exit, queued behind the event, brings the stop.
perform_one({write, Records}, #{port := Port, present_text := Text}) ->
    try port_command(Port, [erx_ui_wire:encode(Record, Text) || Record <- Records])
    catch error:badarg -> true
    end;
perform_one({present, W, H, Rects}, #{present := Present}) ->
    ok = Present(W, H, Rects);
perform_one({reply, From}, _Data) ->
    gen_statem:reply(From, ok);
perform_one({hit, Node, Event, Value}, #{ui := Ui}) ->
    Ui ! {ui_hit, Node, Event, Value}.

%% The core stopped the program: the reason, which names a fault's kind
%% and never the program's bytes, goes to the log, and the UI ends.
down(Reason, #{port := Port, ui := Ui, id := Id}) ->
    logger:warning("erx_ui_lvgl: erx-lvgl stopped: ~p", [Reason]),
    close_port(Port),
    Ui ! {ui_down, Id, renderer_down},
    {stop, {shutdown, {renderer_down, Reason}}}.

%% Closes the port, which is closed already when the program ended.
close_port(Port) ->
    try port_close(Port) catch error:badarg -> true end.
