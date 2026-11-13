%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_winctl).
-moduledoc """
The text of a write to a window's `ctl` file (docs/design-display.md, "The
window tree"): parse/1 reads a present, the one command the file takes,
from the window's client.

A write is one command on one line of at most 1,024 bytes:

```text
present OFFSET WIDTH HEIGHT [X0 Y0 X1 Y1]...
```

OFFSET is the buffer's offset in the client's pixel area, WIDTH and HEIGHT
its size in pixels, and the rectangles, from none to 16, are what changed,
in the buffer's coordinates and half-open as Plan 9's. Tokens are separated
by spaces or tabs, which may also lead and trail, and the line may end in
one newline, as erx_wctl's lines do. Every number is decimal: OFFSET, WIDTH
and HEIGHT are digits alone, and a coordinate may have a leading `-`; a
number has at most 19 digits, leading zeros included.

The parser checks what the line alone decides: OFFSET fits a file offset,
below 2^63; WIDTH and HEIGHT are from 1 to 16,384; a coordinate fits
draw(3)'s 32 bits; each rectangle is well formed, its X0 at most its X1 and
its Y0 at most its Y1. It returns the rectangles clipped to the buffer,
those that clip to nothing dropped, and for a line with none the whole
buffer, so the caller never sees the line's "none". What needs the client's
grant, that OFFSET is a multiple of the page size and that the buffer ends
within the pixel area, the window checks.

The bytes come from a client and are untrusted: anything outside the
grammar or the checks, including a byte that is not ASCII, a line longer
than 1,024 bytes or a number out of range, is `{error, einval}`, and the
parser creates no atom and does no work beyond a few passes over at most
1,024 bytes.
""".

-export([parse/1]).
-export_type([present/0]).

-doc "A coordinate: draw(3)'s 32-bit signed integer.".
-type coord() :: -16#80000000..16#7fffffff.
-doc "A half-open rectangle `{X0, Y0, X1, Y1}` in the buffer's coordinates.".
-type rect() :: {coord(), coord(), coord(), coord()}.
-doc """
A parsed present: the buffer's offset and size, and the rectangles that
changed, each inside the buffer and none empty.
""".
-type present() :: #{offset := 0..16#7fffffffffffffff,
                     width := 1..16384, height := 1..16384,
                     rects := [rect()]}.

-define(MAX_LINE, 1024).
-define(MAX_OFFSET, 16#7fffffffffffffff).
-define(MAX_SIZE, 16384).
-define(MAX_RECTS, 16).
-define(MIN_COORD, -16#80000000).
-define(MAX_COORD, 16#7fffffff).
%% The digits of a number, leading zeros included: as many as 2^63 - 1 has,
%% so a number of 20 digits is refused whatever its value.
-define(MAX_DIGITS, 19).

-doc """
Parses one write to `ctl`. Returns the present, or `{error, einval}` for
anything outside the grammar or the checks.
""".
-spec parse(binary()) -> {ok, present()} | {error, einval}.
parse(Bytes) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_LINE ->
    case words(strip_newline(Bytes)) of
        {ok, [<<"present">>, Offset, Width, Height | Coords]} ->
            present(natural(Offset, ?MAX_OFFSET), natural(Width, ?MAX_SIZE),
                    natural(Height, ?MAX_SIZE), rects(Coords, []));
        _ ->
            {error, einval}
    end;
parse(_) ->
    {error, einval}.

%% Internal functions

present({ok, Offset}, {ok, Width}, {ok, Height}, {ok, Rects}) when Width >= 1, Height >= 1 ->
    Buffer = {0, 0, Width, Height},
    Changed = case Rects of
                  [] -> [Buffer];
                  _ -> [R || R <- [intersect(R, Buffer) || R <- Rects], not is_empty(R)]
              end,
    {ok, #{offset => Offset, width => Width, height => Height, rects => Changed}};
present(_, _, _, _) ->
    {error, einval}.

%% One newline may end the line; the words of what is left must not hold
%% another.
strip_newline(Bytes) ->
    case Bytes of
        <<Line:(byte_size(Bytes) - 1)/binary, $\n>> -> Line;
        _ -> Bytes
    end.

%% The line's words, split at runs of spaces and tabs. Every byte must be
%% printable ASCII or a separator, so a control byte, a second newline or a
%% byte above 0x7e refuses the line before any word is read.
words(Line) ->
    case lists:all(fun(Byte) -> word_byte(Byte) orelse separator(Byte) end,
                   binary_to_list(Line)) of
        true -> {ok, binary:split(Line, [<<" ">>, <<"\t">>], [global, trim_all])};
        false -> error
    end.

word_byte(Byte) -> Byte > $\s andalso Byte < 16#7f.

separator(Byte) -> Byte =:= $\s orelse Byte =:= $\t.

%% The rectangles of the words after HEIGHT, four coordinates each, in the
%% line's order: at most 16, each well formed.
rects([], Acc) ->
    {ok, lists:reverse(Acc)};
rects(_, Acc) when length(Acc) >= ?MAX_RECTS ->
    error;
rects([A, B, C, D | Rest], Acc) ->
    case [coordinate(Word) || Word <- [A, B, C, D]] of
        [{ok, X0}, {ok, Y0}, {ok, X1}, {ok, Y1}] when X0 =< X1, Y0 =< Y1 ->
            rects(Rest, [{X0, Y0, X1, Y1} | Acc]);
        _ ->
            error
    end;
rects(_, _) ->
    error.

%% Digits alone, at most Max.
natural(Word, Max) ->
    case digits(Word) of
        {ok, N} when N =< Max -> {ok, N};
        _ -> error
    end.

%% `-` then at least one digit, or digits alone, within draw(3)'s 32 bits.
coordinate(<<$-, Digits/binary>>) -> in_range(digits(Digits), -1);
coordinate(Digits) -> in_range(digits(Digits), 1).

in_range({ok, Magnitude}, Sign) when Sign * Magnitude >= ?MIN_COORD,
                                     Sign * Magnitude =< ?MAX_COORD ->
    {ok, Sign * Magnitude};
in_range(_, _) ->
    error.

digits(<<>>) -> error;
digits(Digits) when byte_size(Digits) > ?MAX_DIGITS -> error;
digits(Digits) ->
    case lists:all(fun(Byte) -> Byte >= $0 andalso Byte =< $9 end,
                   binary_to_list(Digits)) of
        true -> {ok, binary_to_integer(Digits)};
        false -> error
    end.

intersect({AX0, AY0, AX1, AY1}, {BX0, BY0, BX1, BY1}) ->
    {max(AX0, BX0), max(AY0, BY0), min(AX1, BX1), min(AY1, BY1)}.

is_empty({X0, Y0, X1, Y1}) -> X0 >= X1 orelse Y0 >= Y1.
