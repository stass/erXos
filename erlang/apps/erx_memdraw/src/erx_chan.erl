%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_chan).
-moduledoc """
Plan 9 channel descriptors as text, such as `<<"x8r8g8b8">>`, read as
draw(2)'s `strtochan` reads one (docs/design-display.md, "Windows and
buffers"). It is the one reader of a descriptor on both sides of the
window system: the display reads its driver's channel with it, and a
client the channel a window's `ctl` answers, which is untrusted to the
client. `depth/1` is the one test of a channel's code, for a code read
as text here or as a number from a draw message, and `stride/2` the one
layout of a buffer's rows, which the display checks a present against
and a client allocates by. It is pure and loads no NIF, so the fuzz
target of erx_win_core runs it on stock's emulator.
""".

-export([parse/1, depth/1, stride/2]).
-export_type([text/0, code/0, depth/0]).

-doc "A channel descriptor as text.".
-type text() :: binary().
-doc """
The descriptor as `erx_memdraw` takes a channel: one byte of type and bits
for each channel, the first channel in the highest byte.
""".
-type code() :: 0..16#ffffffff.
-doc "The bits of a pixel.".
-type depth() :: 1..32.

-doc """
The format of channel descriptor `Text`: `{ok, Code, Depth}`, or
`{error, einval}` for a descriptor of no channel, more than four, a letter
outside `rgbkamx`, a channel of no bits or more than 8, or a code that
`depth/1` refuses.
""".
-spec parse(text()) -> {ok, code(), depth()} | {error, einval}.
parse(Text) when is_binary(Text) ->
    parse(Text, 0, 0);
parse(_) ->
    {error, einval}.

%% draw(2)'s channel types: CRed 0, CGreen 1, CBlue 2, CGrey 3, CAlpha 4, CMap 5,
%% CIgnore 6.
parse(<<Letter, Bits, Rest/binary>>, Code, Count) when Bits >= $1, Bits =< $8, Count < 4 ->
    case chan_type(Letter) of
        error -> {error, einval};
        Type -> parse(Rest, (Code bsl 8) bor (Type bsl 4) bor (Bits - $0), Count + 1)
    end;
parse(<<>>, Code, _Count) ->
    case depth(Code) of
        {ok, Depth} -> {ok, Code, Depth};
        {error, einval} -> {error, einval}
    end;
parse(_, _, _) ->
    {error, einval}.

chan_type($r) -> 0;
chan_type($g) -> 1;
chan_type($b) -> 2;
chan_type($k) -> 3;
chan_type($a) -> 4;
chan_type($m) -> 5;
chan_type($x) -> 6;
chan_type(_) -> error.

-doc """
The depth of channel code `Code`, as 9front's chantodepth reads one:
`{ok, Depth}` when each byte, from the low one, has a type below NChan (7)
in its high nibble and 1 to 8 bits in its low nibble, and the bits sum to
a whole divisor or multiple of 8, and `{error, einval}` otherwise, 0
included.
""".
-spec depth(term()) -> {ok, depth()} | {error, einval}.
depth(Code) when is_integer(Code), Code > 0, Code =< 16#ffffffff ->
    depth(Code, 0);
depth(_) ->
    {error, einval}.

%% A depth below 8 divides 8; one of 8 or more is a multiple of 8.
depth(0, Depth) when Depth rem 8 =:= 0; 8 rem Depth =:= 0 ->
    {ok, Depth};
depth(0, _Depth) ->
    {error, einval};
depth(Code, Depth) ->
    Byte = Code band 16#ff,
    Bits = Byte band 16#f,
    case Byte bsr 4 < 7 andalso Bits >= 1 andalso Bits =< 8 of
        true -> depth(Code bsr 8, Depth + Bits);
        false -> {error, einval}
    end.

-doc """
The bytes of one row of a buffer `Width` pixels wide at `Depth` bits a
pixel, whole 32-bit words as Plan 9 lays rows.
""".
-spec stride(pos_integer(), depth()) -> pos_integer().
stride(Width, Depth) ->
    4 * ((Width * Depth + 31) div 32).
