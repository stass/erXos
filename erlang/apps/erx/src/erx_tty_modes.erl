%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_modes).
-moduledoc """
The two termios a session's terminal moves between (docs/design-shell.md,
"The foreground rule"): the cooked termios commands run under, and the
console's editing setting made from it. Both are pure functions of termios
maps, which the terminal relay applies in the step that gives the console
the terminal.

adopt/2 is libedit's rule for the setting it edits under, read from FreeBSD
15.1.0's contrib/libedit/tty.c:71-78, :957-979 and :1005-1063, as the design
states it: the speeds always follow what the terminal holds, and only a
termios with ICANON set gives its flags, character size and special
characters, through masks that keep some flags set and others clear, so a
job that left the tty raw leaves nothing. libedit
keeps one speed for both directions (tty.c:611-616, :1017-1025); a termios
keeps the two it was given, which differ only after a program sets them
apart, and a pseudo-terminal acts on neither. editing/1 is the design's
setting for the console's line editor: ICANON, ECHO and OPOST clear, ISIG
and ICRNL set, VMIN 1 and VTIME 0. libedit's own editing setting keeps ISIG
and ICRNL set too (tty.c:79-84) and sets the same VMIN and VTIME
(tty.c:107-116); it keeps OPOST, which the console clears to write its own
CR-LF.
""".

-export([adopt/2, editing/1]).

%% libedit's masks for the cooked setting, word by word: the flags kept set
%% and the flags kept clear (tty.c:71-78), less EXTPROC and FLUSHO, which the
%% termios table does not name and no termios can hold.
-define(COOKED_MASKS,
        #{iflag => {[icrnl], [igncr, inlcr]},
          oflag => {[onlcr, opost], [onlret]},
          lflag => {[echo, echoctl, echoe, icanon, iexten, isig],
                    [echonl, noflsh]}}).
%% The editing setting's masks, the design's rather than libedit's.
-define(EDITING_MASKS,
        #{iflag => {[icrnl], []},
          oflag => {[], [opost]},
          lflag => {[isig], [echo, icanon]}}).

-doc """
The cooked termios after a holder that left `Left`: the speeds of `Left`,
and when `Left` has ICANON set its flags, character size and special
characters too, with libedit's masks applied; otherwise `Cooked`'s.
""".
-spec adopt(erx_tty:termios(), erx_tty:termios()) -> erx_tty:termios().
adopt(Cooked, #{lflag := Local, ispeed := In, ospeed := Out} = Left) ->
    Base = case lists:member(icanon, Local) of
               true -> masked(?COOKED_MASKS, Left);
               false -> Cooked
           end,
    Base#{ispeed := In, ospeed := Out}.

-doc "The console's editing setting made from the cooked termios `Cooked`.".
-spec editing(erx_tty:termios()) -> erx_tty:termios().
editing(#{cc := Chars} = Cooked) ->
    (masked(?EDITING_MASKS, Cooked))#{cc := Chars#{vmin := 1, vtime := 0}}.

%% Each word of the masks with its set flags added and its clear flags gone.
masked(Masks, Termios) ->
    maps:fold(fun(Word, {Set, Clear}, Acc) ->
                      Kept = [Flag || Flag <- maps:get(Word, Acc),
                                      not lists:member(Flag, Clear)],
                      Acc#{Word := lists:usort(Kept ++ Set)}
              end, Termios, Masks).
