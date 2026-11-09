%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_draw_image).
-moduledoc """
image(6)'s compressed form, as a `Y` draw message carries it
(docs/design-display.md, "Draw messages"), and the row size of a rectangle
at a depth. decode/3 expands codes into exactly a rectangle's pixels: a
code is a literal run, a byte C of 128 or more and then C-127 bytes as
they are, or a back-reference, a byte C below 128 and a byte L, standing
for (C bsr 2)+3 bytes found ((C band 3) bsl 8)+L+1 bytes back in the
output. No code crosses the end of a row, and the codes end at the one
that completes the last row; anything else is malformed. As 9front's
cloadmemimage does, a back-reference may reach before the first output
byte; that reads zeros here, where cloadmemimage reads its window
uninitialised, so such a payload is framed alike and only its pixels are
undefined in Plan 9. Each code reads at least one byte, so decoding takes
no more steps than the input has bytes, and the output never passes the
rectangle.
""".
-export([decode/3, encode/2, bytes_per_line/2]).

%% The span a back-reference reaches.
-define(WINDOW, 1024).

-type rect() :: erx_draw_codec:rect().

-doc """
The bytes one row of R takes at Bits a pixel, as 9front's bytesperline counts
them: from the byte holding R's first pixel through the byte holding its last,
with bytes aligned at x = 0 on both sides of it.
""".
-spec bytes_per_line(rect(), 1..32) -> pos_integer().
bytes_per_line({X0, _, X1, _}, Bits) ->
    (X1 * Bits - ((X0 * Bits) band -8) + 7) div 8.

-doc "R's pixels from the codes at the start of Bytes, and the bytes after them.".
-spec decode(binary(), rect(), 1..32) -> {ok, Pixels :: binary(), Rest :: binary()} | error.
decode(Bytes, {X0, Y0, X1, Y1} = R, Bits) when is_integer(Bits), Bits >= 1, Bits =< 32, X1 > X0, Y1 > Y0 ->
    Line = bytes_per_line(R, Bits),
    codes(Bytes, Line, Line, Y1 - Y0, <<0:(?WINDOW * 8)>>);
decode(_, _, _) ->
    error.

%% Left is what the current row still needs and Rows the rows not yet
%% complete; Out is the output so far after ?WINDOW zero bytes.
codes(Rest, _Line, 0, 1, Out) ->
    {ok, binary:part(Out, ?WINDOW, byte_size(Out) - ?WINDOW), Rest};
codes(Bytes, Line, 0, Rows, Out) ->
    codes(Bytes, Line, Line, Rows - 1, Out);
codes(<<C, Rest/binary>>, Line, Left, Rows, Out) when C >= 128 ->
    Count = C - 127,
    case Rest of
        <<Run:Count/binary, After/binary>> when Count =< Left ->
            codes(After, Line, Left - Count, Rows, <<Out/binary, Run/binary>>);
        _ ->
            error
    end;
codes(<<C, Low, Rest/binary>>, Line, Left, Rows, Out) when (C bsr 2) + 3 =< Left ->
    Count = (C bsr 2) + 3,
    Back = ((C band 3) bsl 8) + Low + 1,
    codes(Rest, Line, Left - Count, Rows, <<Out/binary, (copy(Out, Back, Count))/binary>>);
codes(_, _, _, _, _) ->
    error.

%% Count bytes from Back bytes before the end of Out, byte by byte, so a
%% reference nearer than its length repeats its last Back bytes.
copy(Out, Back, Count) when Count =< Back ->
    binary:part(Out, byte_size(Out) - Back, Count);
copy(Out, Back, Count) ->
    Pattern = binary:part(Out, byte_size(Out) - Back, Back),
    binary:part(binary:copy(Pattern, Count div Back + 1), 0, Count).

-doc """
Pixels, exactly R's rows, as literal runs of at most 128 bytes, none
crossing a row's end.
""".
-spec encode(binary(), rect()) -> binary().
encode(Pixels, {_, Y0, _, Y1}) when Y1 > Y0, byte_size(Pixels) rem (Y1 - Y0) =:= 0, byte_size(Pixels) > 0 ->
    Line = byte_size(Pixels) div (Y1 - Y0),
    << <<(runs(Row))/binary>> || <<Row:Line/binary>> <= Pixels >>.

runs(<<Run:128/binary, Rest/binary>>) -> <<255, Run/binary, (runs(Rest))/binary>>;
runs(<<>>) -> <<>>;
runs(Run) -> <<(byte_size(Run) + 127), Run/binary>>.
