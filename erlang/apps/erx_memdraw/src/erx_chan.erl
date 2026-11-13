%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_chan).
-moduledoc """
Plan 9 channel descriptors as text, such as `<<"x8r8g8b8">>`, read as
draw(2)'s `strtochan` reads one (docs/design-display.md, "Windows and
buffers"). It is the one reader of a descriptor on both sides of the
window system: the display reads its driver's channel with it, and a
client the channel a window's `ctl` answers, which is untrusted to the
client. It is pure and loads no NIF, so the fuzz target of erx_win_core
runs it on stock's emulator.
""".

-export([parse/1]).
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
outside `rgbkamx`, a channel of no bits or more than 8, or a depth that is
not a whole divisor or multiple of 8.
""".
-spec parse(text()) -> {ok, code(), depth()} | {error, einval}.
parse(Text) when is_binary(Text) ->
    parse(Text, 0, 0, 0);
parse(_) ->
    {error, einval}.

%% draw(2)'s channel types: CRed 0, CGreen 1, CBlue 2, CGrey 3, CAlpha 4, CMap 5,
%% CIgnore 6.
parse(<<Letter, Bits, Rest/binary>>, Code, Depth, Count)
  when Bits >= $1, Bits =< $8, Count < 4 ->
    case chan_type(Letter) of
        error -> {error, einval};
        Type -> parse(Rest, (Code bsl 8) bor (Type bsl 4) bor (Bits - $0),
                      Depth + Bits - $0, Count + 1)
    end;
parse(<<>>, Code, Depth, Count) when Count > 0, (Depth rem 8 =:= 0 orelse 8 rem Depth =:= 0) ->
    {ok, Code, Depth};
parse(_, _, _, _) ->
    {error, einval}.

chan_type($r) -> 0;
chan_type($g) -> 1;
chan_type($b) -> 2;
chan_type($k) -> 3;
chan_type($a) -> 4;
chan_type($m) -> 5;
chan_type($x) -> 6;
chan_type(_) -> error.
