%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_window).
-moduledoc """
One window (docs/design-display.md, "The window process" and "The window
tree"): it serves the window's `ctl`, `mouse`, `kbd` and `label` files to
the tree's callbacks in `erx_winfs`, holds the window's pending input and
its last present, and is told its rectangle and state by `erx_winfs`.

**ctl.** A read answers the display's channel descriptor. A write is one
`present` line, read by `erx_winctl:parse/1` and checked against the
client's pixel area: the offset a multiple of the page size, and the
buffer's bytes, `erx_chan:stride(width, depth) * height`, ending at or
before the area's end.
Erlang's integers do not overflow, so the sums are exact whatever the
line's numbers. A line outside the grammar or the checks is `EINVAL`, a
grant without an area `ENXIO`, and neither is shown.

**Presents.** At most one is in flight to `erx_screen`, through
`erx_screen:present_request/2`, which returns at once; the write that
asked for it is held until the answer, so the window still takes input.
On `ok` the buffer becomes the last present and the write is answered;
the screen's refusal answers the write with it, and the screen's end with
`EIO`. A write that arrives while one is in flight queues behind it. A
request to present again (`{erx_screen, present_again}`) presents the last
buffer whole, as if the client had, with no write to answer: it waits for
the present in flight to be answered, goes before queued writes, and does
nothing while there is no last buffer.

**Input.** A pointer event is a 49-byte `mouse` record
`m%11d %11d %11d %11d `, x, y, buttons and milliseconds. A key's down
is a `kbd` record `k` and its up a `K`, each followed by the set of
runes held, in UTF-8, and a NUL: the unshifted runes of the keys whose
downs the window received and whose ups it has not, with the modifiers
held on the display, the event's `Mods`. A down or a repeat that types a
rune is then a `c` record, the rune and a NUL. A wheel step is not
encoded here. Each queue holds at most 4 KiB of
records; past that the oldest is dropped and counted. A change of the
window's size sets `resized`, which the next `mouse` read answers with an
`r` record at the last pointer position. A read takes one record, waits
for one when there is none, and is `EINVAL` when its count cannot hold one.

**label.** Read at any offset; a write replaces the label, and one at a
nonzero offset is `EINVAL`, which is erXos's choice: the label is one
line written whole.
""".

-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% A queue of records, its bytes and its count of dropped records.
-record(records, {queue = queue:new() :: queue:queue(binary()),
                  bytes = 0 :: non_neg_integer(),
                  dropped = 0 :: non_neg_integer(),
                  readers = queue:new() :: queue:queue(gen_server:from())}).

-record(window, {id :: pos_integer(),
                 chan :: binary(),
                 depth :: pos_integer(),
                 area :: none | {term(), pos_integer()},
                 rect = none :: none | erx_wm:rect(),
                 state = hidden :: shown | hidden,
                 label = <<>> :: binary(),
                 %% The last present's buffer, or none.
                 buffer = none :: none | map(),
                 resized = false :: boolean(),
                 pointer = {0, 0, 0, 0} :: {integer(), integer(), integer(), integer()},
                 mouse = #records{} :: #records{},
                 kbd = #records{} :: #records{},
                 %% The unshifted rune of each key whose down the window received and
                 %% whose up it has not, or none for a key that has none.
                 keys = #{} :: #{non_neg_integer() => erx_wm:rune() | none},
                 %% The present in flight, its buffer and whose write it answers.
                 in_flight = none :: none | {gen_server:request_id(), map(), gen_server:from() | again},
                 waiting = queue:new() :: queue:queue({gen_server:from(), map()}),
                 again = false :: boolean()}).

-doc """
Starts window Id's process, linked to the caller, `erx_winfs`: Chan is the
display's channel descriptor and Depth its bits a pixel, Area the client's
pixel area and its bytes, or none.
""".
-spec start_link(#{id := pos_integer(), chan := binary(), depth := pos_integer(),
                   area := none | {term(), pos_integer()}}) -> {ok, pid()}.
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-doc false.
init(#{id := Id, chan := Chan, depth := Depth, area := Area}) ->
    {ok, #window{id = Id, chan = Chan, depth = Depth, area = Area}}.

-doc false.
handle_call({read, ctl, Offset, Count}, _From, #window{chan = Chan} = W) ->
    {reply, slice(<<Chan/binary, "\n">>, Offset, Count), W};
handle_call({read, wctl, Offset, Count}, _From, #window{rect = Rect, state = State} = W) ->
    Text = erx_wctl:format(case Rect of none -> {0, 0, 0, 0}; _ -> Rect end, State =:= shown, State),
    {reply, slice(Text, Offset, Count), W};
handle_call({read, label, Offset, Count}, _From, #window{label = Label} = W) ->
    {reply, slice(Label, Offset, Count), W};
handle_call({read, mouse, _Offset, Count}, _From, W) when Count < ?ERX_WINDOWS_MOUSE_RECORD ->
    {reply, {error, einval}, W};
handle_call({read, mouse, _Offset, _Count}, From, #window{mouse = Mouse} = W) ->
    {noreply, serve(W#window{mouse = wait(From, Mouse)})};
handle_call({read, kbd, _Offset, Count}, _From, W) when Count < 6 ->
    %% A kbd record is at most 6 bytes: c, four of UTF-8 and the NUL.
    {reply, {error, einval}, W};
handle_call({read, kbd, _Offset, _Count}, From, #window{kbd = Kbd} = W) ->
    {noreply, serve(W#window{kbd = wait(From, Kbd)})};
handle_call({write, ctl, _Offset, Line}, From, W) ->
    case check(Line, W) of
        {ok, Present} ->
            {noreply, pump(W#window{waiting = queue:in({From, Present}, W#window.waiting)})};
        {error, Reason} = Refused ->
            _ = erx_log:debug(["erx_window ", integer_to_binary(W#window.id),
                               ": present refused: ", atom_to_binary(Reason)]),
            {reply, Refused, W}
    end;
handle_call({write, label, 0, Label}, _From, W) when is_binary(Label) ->
    {reply, ok, W#window{label = Label}};
handle_call(_Request, _From, W) ->
    {reply, {error, einval}, W}.

-doc false.
handle_cast({placed, Rect, State}, #window{rect = Old, resized = Resized} = W) ->
    Changed = Old =/= none andalso extent(Old) =/= extent(Rect),
    {noreply, serve(W#window{rect = Rect, state = State, resized = Resized orelse Changed})};
handle_cast({input, #{event := Event, at := At}}, W) ->
    {noreply, serve(encode(Event, At, W))};
handle_cast(_Request, W) ->
    {noreply, W}.

-doc false.
handle_info({erx_screen, present_again}, #window{buffer = none} = W) ->
    {noreply, W};
handle_info({erx_screen, present_again}, W) ->
    {noreply, pump(W#window{again = true})};
handle_info(Message, #window{in_flight = {Request, Present, Who}} = W) ->
    case gen_server:check_response(Message, Request) of
        no_reply ->
            {noreply, W};
        {reply, ok} ->
            ok = answer(Who, ok),
            {noreply, pump(W#window{in_flight = none, buffer = maps:without([rects], Present)})};
        {reply, {error, _} = Refused} ->
            ok = answer(Who, Refused),
            {noreply, pump(W#window{in_flight = none})};
        {error, {_Reason, _Screen}} ->
            ok = answer(Who, {error, eio}),
            {noreply, pump(W#window{in_flight = none})}
    end;
handle_info(_Message, W) ->
    {noreply, W}.

%% ctl -----------------------------------------------------------------------

check(Line, #window{area = Area, depth = Depth}) ->
    case {erx_winctl:parse(Line), Area} of
        {{error, einval}, _} -> {error, einval};
        {{ok, _}, none} -> {error, enxio};
        {{ok, #{offset := Offset, width := Width, height := Height} = Present}, {_, Bytes}} ->
            Stride = erx_chan:stride(Width, Depth),
            case Offset rem ?ERX_PAGE_SIZE =:= 0 andalso Offset + Stride * Height =< Bytes of
                true -> {ok, Present};
                false -> {error, einval}
            end
    end.

%% Sends the next present when none is in flight: a deferred present-again first,
%% then the oldest held write. A screen that cannot be reached answers eio.
pump(#window{in_flight = none, again = true, buffer = Buffer} = W) when Buffer =/= none ->
    send(again, Buffer#{rects => []}, W#window{again = false});
pump(#window{in_flight = none, waiting = Waiting} = W) ->
    case queue:out(Waiting) of
        {{value, {From, Present}}, Rest} -> send(From, Present, W#window{waiting = Rest});
        {empty, _} -> W#window{again = false}
    end;
pump(W) ->
    W.

send(Who, Present, #window{id = Id, area = {Area, _}} = W) ->
    case erx_screen:present_request(Id, Present#{area => Area}) of
        {ok, Request} ->
            W#window{in_flight = {Request, Present, Who}};
        {error, eio} = Refused ->
            ok = answer(Who, Refused),
            pump(W)
    end.

answer(again, _Reply) -> ok;
answer(From, Reply) -> gen_server:reply(From, Reply).

%% Input ---------------------------------------------------------------------

encode({pointer, X, Y, Buttons}, At, #window{mouse = Mouse} = W)
  when is_integer(X), is_integer(Y), is_integer(Buttons), is_integer(At) ->
    Msec = abs(At) rem 16#80000000,
    W#window{mouse = push(record($m, {X, Y, Buttons, Msec}), Mouse), pointer = {X, Y, Buttons, Msec}};
encode({key, down, Code, Typed, Unshifted, Mods}, _At, #window{keys = Keys} = W) ->
    Held = W#window{keys = Keys#{Code => Unshifted}},
    typed(Typed, held_record($k, Mods, Held));
encode({key, repeat, _Code, Typed, _Unshifted, _Mods}, _At, W) ->
    typed(Typed, W);
encode({key, up, Code, _Typed, _Unshifted, Mods}, _At, #window{keys = Keys} = W) ->
    held_record($K, Mods, W#window{keys = maps:remove(Code, Keys)});
encode(_Event, _At, W) ->
    W.

%% A k or K record: the runes of the keys held for the window with the modifiers held
%% on the display, each once, in UTF-8.
held_record(Kind, Mods, #window{keys = Keys, kbd = Kbd} = W) ->
    Runes = lists:usort([Rune || Rune <- maps:values(Keys), Rune =/= none] ++ Mods),
    W#window{kbd = push(<<Kind, (unicode:characters_to_binary(Runes))/binary, 0>>, Kbd)}.

typed(none, W) -> W;
typed(Rune, #window{kbd = Kbd} = W) -> W#window{kbd = push(<<$c, Rune/utf8, 0>>, Kbd)}.

record(Kind, {X, Y, Buttons, Msec}) ->
    W = ?ERX_WINDOWS_FIELD,
    iolist_to_binary(io_lib:format("~c~*B ~*B ~*B ~*B ", [Kind, W, X, W, Y, W, Buttons, W, Msec])).

push(Record, #records{queue = Queue, bytes = Bytes, dropped = Dropped} = Records) ->
    Size = byte_size(Record),
    case Bytes + Size > ?ERX_WINDOWS_QUEUE_BYTES of
        true ->
            {{value, Oldest}, Rest} = queue:out(Queue),
            push(Record, Records#records{queue = Rest, bytes = Bytes - byte_size(Oldest),
                                         dropped = Dropped + 1});
        false ->
            Records#records{queue = queue:in(Record, Queue), bytes = Bytes + Size}
    end.

wait(From, #records{readers = Readers} = Records) ->
    Records#records{readers = queue:in(From, Readers)}.

%% Answers waiting readers while records are pending; a mouse reader takes the
%% resize record before any queued one.
serve(#window{resized = true, mouse = #records{readers = Readers} = Mouse, pointer = Pointer} = W) ->
    case queue:out(Readers) of
        {{value, From}, Rest} ->
            gen_server:reply(From, {ok, record($r, Pointer)}),
            serve(W#window{resized = false, mouse = Mouse#records{readers = Rest}});
        {empty, _} ->
            serve_queues(W)
    end;
serve(W) ->
    serve_queues(W).

serve_queues(#window{mouse = Mouse, kbd = Kbd} = W) ->
    W#window{mouse = serve_records(Mouse), kbd = serve_records(Kbd)}.

serve_records(#records{queue = Queue, readers = Readers, bytes = Bytes} = Records) ->
    case {queue:out(Queue), queue:out(Readers)} of
        {{{value, Record}, RestQueue}, {{value, From}, RestReaders}} ->
            gen_server:reply(From, {ok, Record}),
            serve_records(Records#records{queue = RestQueue, readers = RestReaders,
                                          bytes = Bytes - byte_size(Record)});
        _ ->
            Records
    end.

%% Text files ----------------------------------------------------------------

slice(Text, Offset, _Count) when Offset >= byte_size(Text) ->
    {ok, <<>>};
slice(Text, Offset, Count) ->
    {ok, binary:part(Text, Offset, min(Count, byte_size(Text) - Offset))}.

extent({X0, Y0, X1, Y1}) -> {X1 - X0, Y1 - Y0}.
