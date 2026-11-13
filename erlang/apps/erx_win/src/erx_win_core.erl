%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win_core).
-moduledoc """
The pure decisions of `erx_win` (docs/design-display.md, "Erlang clients"):
the readers of what a client reads back from a display, a buffer's layout,
and the lines a client writes.

**Readers.** What a display answers a client is untrusted to the client,
so each reader takes the bytes of one read, holds them to their format
whole, and answers `{error, eio}` for anything else; none raises, makes an
atom or reads past its record. The formats are the window tree's:

* `ctl/1`, a read of `ctl`: the display's channel descriptor and one
  newline, read by `erx_chan:parse/1`;
* `wctl/1`, a read of `wctl`: rio's 72 bytes, four coordinates and two
  words, each right-aligned in a field of 11 and followed by a space; the
  rectangle must be well formed and at most 16,384 pixels on a side;
* `mouse/1`, a read of `mouse`: a 49-byte record, `m` or `r`, then x, y,
  buttons and milliseconds, each right-aligned in a field of 11 and
  followed by a space; x and y are draw(3) coordinates, buttons and
  milliseconds from 0 to 2^31 - 1;
* `kbd/1`, a read of `kbd`: a record of one kind byte, its runes in UTF-8
  and a NUL: `c` and exactly one rune, or `k` or `K` and any runes, none
  of them NUL.

**A buffer's layout.** `bytes/3` is `erx_chan:stride(Width, Depth)` times
the height, for a width and height from 1 to 16,384; Erlang's integers do
not overflow, and the sides are checked before any product is taken.

**Lines.** `present/4` writes a `present` line of at most 16 rectangles,
sending the bounding box of more, as Plan 9's `flushimage` does; `resize/1`
a `wctl` resize command.
""".

-include("generated/erx_abi.hrl").

-export([ctl/1, wctl/1, mouse/1, kbd/1]).
-export([bytes/3, image_rect/2, present/4, resize/1]).
-export_type([rect/0, chan/0, placed/0, pointer/0, key/0]).

%% A channel descriptor of four channels is 8 bytes; its line is 9.
-define(MAX_CTL, 9).
%% A field and the space after it.
-define(CELL, (?ERX_WINDOWS_FIELD + 1)).
%% A mouse record is its kind byte and four cells; the ABI states the sum apart.
-if(?ERX_WINDOWS_MOUSE_RECORD =/= 1 + 4 * ?CELL).
-error("windows_mouse_record is not a kind byte and four fields").
-endif.

-doc "A half-open rectangle `{X0, Y0, X1, Y1}`, as Plan 9's.".
-type rect() :: {integer(), integer(), integer(), integer()}.
-doc "The display's channel: its text, its code for erx_memdraw and its depth.".
-type chan() :: #{text := binary(), code := erx_chan:code(), depth := erx_chan:depth()}.
-doc "A window's place, as its `wctl` reads.".
-type placed() :: #{rect := rect(), current := boolean(), state := shown | hidden}.
-doc "A `mouse` record: a pointer event, or the resize mark at the last position.".
-type pointer() :: {mouse | resized, X :: integer(), Y :: integer(),
                    Buttons :: non_neg_integer(), Msec :: non_neg_integer()}.
-doc "A `kbd` record: a typed rune, the keys down, or the keys down after a release.".
-type key() :: {typed, char()} | {down, [char()]} | {up, [char()]}.

%% Readers --------------------------------------------------------------------

-doc "The channel a read of `ctl` answers.".
-spec ctl(binary()) -> {ok, chan()} | {error, eio}.
ctl(Bytes) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_CTL ->
    Size = byte_size(Bytes) - 1,
    case Bytes of
        <<Text:Size/binary, $\n>> ->
            case erx_chan:parse(Text) of
                {ok, Code, Depth} -> {ok, #{text => Text, code => Code, depth => Depth}};
                {error, einval} -> {error, eio}
            end;
        _ ->
            {error, eio}
    end;
ctl(_) ->
    {error, eio}.

-doc "The window's place a read of `wctl` answers.".
-spec wctl(binary()) -> {ok, placed()} | {error, eio}.
wctl(<<A:?CELL/binary, B:?CELL/binary, C:?CELL/binary, D:?CELL/binary, E:?CELL/binary, F:?CELL/binary>>) ->
    case {[number(Field, ?ERX_WINDOWS_COORD_MIN) || Field <- [A, B, C, D]], field(E), field(F)} of
        {[{ok, X0}, {ok, Y0}, {ok, X1}, {ok, Y1}], {ok, Focus}, {ok, Shown}} ->
            placed({X0, Y0, X1, Y1}, Focus, Shown);
        _ ->
            {error, eio}
    end;
wctl(_) ->
    {error, eio}.

-doc "The record a read of `mouse` answers.".
-spec mouse(binary()) -> {ok, pointer()} | {error, eio}.
mouse(<<Kind, X:?CELL/binary, Y:?CELL/binary, Buttons:?CELL/binary, Msec:?CELL/binary>>)
  when Kind =:= $m; Kind =:= $r ->
    case [number(X, ?ERX_WINDOWS_COORD_MIN), number(Y, ?ERX_WINDOWS_COORD_MIN), number(Buttons, 0), number(Msec, 0)] of
        [{ok, Px}, {ok, Py}, {ok, Pb}, {ok, Pm}] -> {ok, {pointer_kind(Kind), Px, Py, Pb, Pm}};
        _ -> {error, eio}
    end;
mouse(_) ->
    {error, eio}.

-doc "The record a read of `kbd` answers.".
-spec kbd(binary()) -> {ok, key()} | {error, eio}.
kbd(<<Kind, Rest/binary>>) when byte_size(Rest) >= 1 ->
    Size = byte_size(Rest) - 1,
    case {Kind, Rest} of
        {_, <<Text:Size/binary, 0>>} -> key(Kind, runes(Text));
        _ -> {error, eio}
    end;
kbd(_) ->
    {error, eio}.

%% Layout ---------------------------------------------------------------------

-doc """
The bytes of a buffer of `Width` by `Height` pixels at `Depth`, or
`{error, einval}` for a side outside 1 to 16,384.
""".
-spec bytes(integer(), integer(), erx_chan:depth()) -> {ok, pos_integer()} | {error, einval}.
bytes(Width, Height, Depth) when is_integer(Width), Width >= 1, Width =< ?ERX_WINDOWS_SIDE_MAX,
                                 is_integer(Height), Height >= 1, Height =< ?ERX_WINDOWS_SIDE_MAX ->
    {ok, erx_chan:stride(Width, Depth) * Height};
bytes(_, _, _) ->
    {error, einval}.

-doc """
The rectangle of the image a client draws in: the window's size, clipped to
its buffer's, at the buffer's origin.
""".
-spec image_rect(rect(), {pos_integer(), pos_integer()}) -> rect().
image_rect({X0, Y0, X1, Y1}, {Width, Height}) ->
    {0, 0, min(X1 - X0, Width), min(Y1 - Y0, Height)}.

%% Lines ----------------------------------------------------------------------

-doc """
The `present` line for the buffer at `Offset` of `Width` by `Height`
pixels and the rectangles `Rects` of it; more than 16 are sent as their
bounding box, and none means the whole buffer.
""".
-spec present(non_neg_integer(), pos_integer(), pos_integer(), [rect()]) -> binary().
present(Offset, Width, Height, Rects) ->
    Sent = case length(Rects) > ?ERX_WINDOWS_PRESENT_RECTS of
               true -> [bounding_box(Rects)];
               false -> Rects
           end,
    Numbers = [Offset, Width, Height | lists:append([tuple_to_list(R) || R <- Sent])],
    iolist_to_binary([<<"present">>, [[$\s, integer_to_binary(N)] || N <- Numbers], $\n]).

-doc "The `wctl` command that asks for the rectangle `Rect`.".
-spec resize(rect()) -> binary().
resize({X0, Y0, X1, Y1}) ->
    iolist_to_binary([<<"resize -r">>, [[$\s, integer_to_binary(N)] || N <- [X0, Y0, X1, Y1]], $\n]).

%% Internal functions ---------------------------------------------------------

%% A field of 12 bytes: spaces, then a token that fills the rest of 11, then one space.
token(<<Field:?ERX_WINDOWS_FIELD/binary, $\s>>) ->
    case binary:split(Field, <<" ">>, [global, trim_all]) of
        [Token] when binary_part(Field, ?ERX_WINDOWS_FIELD - byte_size(Token), byte_size(Token)) =:= Token ->
            {ok, Token};
        _ ->
            error
    end;
token(_) ->
    error.

%% A decimal integer from Min to 2^31 - 1, with a leading `-` only where Min is negative.
number(Field, Min) ->
    case token(Field) of
        {ok, <<$-, Digits/binary>>} when Min < 0 -> in_range(digits(Digits), -1, Min);
        {ok, Digits} -> in_range(digits(Digits), 1, Min);
        error -> error
    end.

digits(<<>>) -> error;
digits(Digits) ->
    case lists:all(fun(Byte) -> Byte >= $0 andalso Byte =< $9 end, binary_to_list(Digits)) of
        true -> {ok, binary_to_integer(Digits)};
        false -> error
    end.

in_range({ok, Magnitude}, Sign, Min) when Sign * Magnitude >= Min, Sign * Magnitude =< ?ERX_WINDOWS_COORD_MAX ->
    {ok, Sign * Magnitude};
in_range(_, _, _) ->
    error.

field(Field) ->
    case token(Field) of
        {ok, <<"current">>} -> {ok, true};
        {ok, <<"notcurrent">>} -> {ok, false};
        {ok, <<"visible">>} -> {ok, shown};
        {ok, <<"hidden">>} -> {ok, hidden};
        _ -> error
    end.

%% The fifth field is the focus and the sixth the state; a word in the other's
%% place is refused.
placed({X0, Y0, X1, Y1} = Rect, Focus, Shown)
  when is_boolean(Focus), (Shown =:= shown orelse Shown =:= hidden),
       X0 =< X1, Y0 =< Y1, X1 - X0 =< ?ERX_WINDOWS_SIDE_MAX, Y1 - Y0 =< ?ERX_WINDOWS_SIDE_MAX ->
    {ok, #{rect => Rect, current => Focus, state => Shown}};
placed(_, _, _) ->
    {error, eio}.

pointer_kind($m) -> mouse;
pointer_kind($r) -> resized.

%% The runes of valid UTF-8 holding no NUL, or error.
runes(Text) ->
    case unicode:characters_to_list(Text, utf8) of
        Runes when is_list(Runes) ->
            case lists:member(0, Runes) of
                true -> error;
                false -> {ok, Runes}
            end;
        _ ->
            error
    end.

key($c, {ok, [Rune]}) -> {ok, {typed, Rune}};
key($k, {ok, Runes}) -> {ok, {down, Runes}};
key($K, {ok, Runes}) -> {ok, {up, Runes}};
key(_, _) -> {error, eio}.

bounding_box([First | Rest]) ->
    lists:foldl(fun({X0, Y0, X1, Y1}, {A0, B0, A1, B1}) ->
                        {min(X0, A0), min(Y0, B0), max(X1, A1), max(Y1, B1)}
                end, First, Rest).
