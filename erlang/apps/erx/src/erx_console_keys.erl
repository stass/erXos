%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_keys).
-moduledoc """
Which BEL bytes of a console line's input are a typed Ctrl-G
(docs/design-live.md, "The console", Input): a pure decision over the line's
bytes as they are read, with the input's escape state carried between reads.

A terminal answers some queries with a string control: an OSC reply, such as
the colour report `ESC ] 11 ; rgb:... BEL`, which may end in BEL as the
query did, or a DCS, APC, PM or SOS reply, which ends in ST (`ESC \`). Ctrl-G
is also BEL, 0x07, so a session that makes the operator's terminal answer a
query would otherwise have its reply open the console's menu. The rule
follows the escape parser of a VT500-series terminal, ECMA-48's, over the
input instead of the output:

* `ESC` followed by `]`, `P`, `_`, `^` or `X` (OSC, DCS, APC, PM, SOS) opens a
  string, and so do those controls' 8-bit forms written as UTF-8 (U+009D,
  U+0090, U+009F, U+009E, U+0098), which a terminal told to answer in 8-bit
  controls (S8C1T) sends in UTF-8 mode; a BEL inside an open string ends it
  and is no Ctrl-G, and so do ST, `ESC \`, and its 8-bit form U+009C;
* `ESC [`, or U+009B, opens a control sequence, such as a cursor or device
  report, which its final byte (0x40 to 0x7E) ends, so the menu knows a
  reply's parameters for what they are (erx_console_menu);
* `ESC`, inside a string or not, starts an escape, and `CAN` or `SUB` cancels a
  string or a sequence, as either cancels a sequence at a terminal;
* any other BEL is a typed Ctrl-G, `ESC BEL` included, which a Meta-Ctrl-G
  sends.

A raw 8-bit control byte (0x9D alone) is not recognized: the line is UTF-8,
in which such a byte is only ever a continuation byte of a character.
Nobody types those code points, but a paste may hold one.

A person who types `Alt-]` (which sends `ESC ]`) opens a string too, and the
next Ctrl-G only ends it: the one after opens the menu. No reply a terminal
sends opens the menu, since each is a whole control. A terminal that
reports text the session chose, such as xterm's title report when the
terminal allows it, can still type anything at the line, and a session that
switches the terminal's keyboard mode can make Ctrl-G arrive as something else;
both are residuals (TODO.md).
""".

-export([new/0, split/2, next/2]).
-export_type([state/0, piece/0]).

-define(BEL, 16#07).
-define(ESC, 16#1B).
-define(CAN, 16#18).
-define(SUB, 16#1A).

%% Where the input is: in no control (ground), just after an ESC (escape), inside a string
%% control the terminal has not ended yet (string), inside a control sequence before its
%% final byte (csi), or just after the 0xC2 that begins an 8-bit control written as UTF-8,
%% in the ground state or a string (c2).
-type state() :: ground | escape | string | csi | {c2, ground | string}.
%% A part of a read: bytes as they were read, a terminator's BEL included, or a typed
%% Ctrl-G, which the bytes no longer contain.
-type piece() :: binary() | ctrl_g.

-doc "The escape state of a line from which nothing has been read.".
-spec new() -> state().
new() -> ground.

-doc """
Bytes, read at a line in State, as its pieces in order, and the state after them:
each typed Ctrl-G is taken out as `ctrl_g`, and every other byte stays, in pieces that
are never empty.
""".
-spec split(binary(), state()) -> {[piece()], state()}.
split(Bytes, State) when is_binary(Bytes) ->
    split(Bytes, 0, 0, State, []).

%% Start is where the piece being read begins, and At the next byte.
split(Bytes, Start, At, State, Pieces) when At =:= byte_size(Bytes) ->
    {lists:reverse(piece(Bytes, Start, At, Pieces)), State};
split(Bytes, Start, At, State, Pieces) ->
    case next(binary:at(Bytes, At), State) of
        {ctrl_g, Next} -> split(Bytes, At + 1, At + 1, Next, [ctrl_g | piece(Bytes, Start, At, Pieces)]);
        {byte, Next} -> split(Bytes, Start, At + 1, Next, Pieces)
    end.

piece(_Bytes, At, At, Pieces) -> Pieces;
piece(Bytes, Start, End, Pieces) -> [binary:part(Bytes, Start, End - Start) | Pieces].

-doc """
What Byte, read in State, is, and the state after it: a typed Ctrl-G, or a byte that
stays in the input.
""".
-spec next(byte(), state()) -> {ctrl_g | byte, state()}.
next(Byte, {c2, ground}) when Byte =:= 16#90; Byte =:= 16#98; Byte =:= 16#9D; Byte =:= 16#9E; Byte =:= 16#9F ->
    {byte, string};
next(16#9B, {c2, ground}) -> {byte, csi};
next(16#9C, {c2, string}) -> {byte, ground};
next(Byte, {c2, Before}) -> next(Byte, Before);
next(?BEL, string) -> {byte, ground};
next(?BEL, _State) -> {ctrl_g, ground};
next(?ESC, _State) -> {byte, escape};
next(16#C2, State) when State =:= ground; State =:= string -> {byte, {c2, State}};
next($[, escape) -> {byte, csi};
next(Byte, escape) when Byte =:= $]; Byte =:= $P; Byte =:= $_; Byte =:= $^; Byte =:= $X -> {byte, string};
next(_Byte, escape) -> {byte, ground};
next(Byte, State) when Byte =:= ?CAN, State =/= ground; Byte =:= ?SUB, State =/= ground -> {byte, ground};
next(Byte, csi) when Byte >= 16#40, Byte =< 16#7E -> {byte, ground};
next(_Byte, State) -> {byte, State}.
