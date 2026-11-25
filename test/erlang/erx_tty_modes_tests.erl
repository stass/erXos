%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_tty_modes, the cooked termios and the console's editing
%% setting (docs/design-shell.md, "The foreground rule"; the verification
%% case "The swap, by libedit's rule").

-module(erx_tty_modes_tests).
-include_lib("eunit/include/eunit.hrl").

cooked() -> erx_tty:termios(erx_tty:new()).

%% Cooked with flags set and cleared and characters changed.
changed(Set, Cleared, Chars, Termios) ->
    Words = maps:map(fun(Word, Flags) when is_list(Flags) ->
                             Known = erx_abi_termios:flags(Word),
                             lists:usort((Flags -- Cleared) ++ [F || F <- Set, lists:member(F, Known)]);
                        (_, Value) -> Value
                     end, Termios),
    Words#{cc := maps:merge(maps:get(cc, Termios), Chars)}.

has(Flag, Termios) ->
    lists:any(fun(Word) -> lists:member(Flag, maps:get(Word, Termios)) end,
              [iflag, oflag, cflag, lflag]).

%% libedit's cooked row as FreeBSD 15.1.0's contrib/libedit/tty.c:71-78
%% writes it, word by word: the flags it keeps set and the flags it keeps
%% clear (EXTPROC and FLUSHO are not in erx_tty's table).
-define(LIBEDIT_COOKED,
        [{iflag, [icrnl], [inlcr, igncr]},
         {oflag, [opost, onlcr], [onlret]},
         {cflag, [], []},
         {lflag, [isig, icanon, echo, echoe, echoctl, iexten],
          [noflsh, echonl]}]).

%% Every flag of erx_tty's table, set and cleared in what a holder left,
%% with ICANON set and clear: a cooked holder gives each word as libedit's
%% row makes it, a raw one gives the cooked termios, and both give their
%% speeds.
adopt_follows_libedits_row_for_every_flag_test() ->
    Cooked = changed([], [], #{vstatus => $\^X}, cooked()),
    Lefts = [Toggle([Flag], Canon)
             || {Word, _, _} <- ?LIBEDIT_COOKED,
                Flag <- erx_abi_termios:flags(Word),
                Toggle <- [fun(F, C) -> left(F, [], C) end,
                           fun(F, C) -> left([], F, C) end],
                Canon <- [true, false]],
    lists:foreach(fun(Left) -> ?assertEqual(expected(Cooked, Left),
                                            erx_tty_modes:adopt(Cooked, Left))
                  end, Lefts).

%% A holder's termios with Set set and Cleared clear, ICANON as Canon says
%% unless Set or Cleared names it, and speeds of its own.
left(Set, Cleared, Canon) ->
    {CanonSet, CanonCleared} = case Canon of
                                   true -> {[icanon], []};
                                   false -> {[], [icanon]}
                               end,
    Termios = changed(CanonSet, CanonCleared, #{}, cooked()),
    (changed(Set, Cleared, #{}, Termios))#{ispeed := 1200, ospeed := 2400}.

expected(Cooked, Left) ->
    Base = case has(icanon, Left) of
               true ->
                   lists:foldl(fun({Word, Kept, Clear}, Acc) ->
                                       Flags = maps:get(Word, Left),
                                       Acc#{Word := lists:usort(
                                                      (Flags -- Clear) ++ Kept)}
                               end, Left, ?LIBEDIT_COOKED);
               false ->
                   Cooked
           end,
    Base#{ispeed := 1200, ospeed := 2400}.

a_cooked_holder_gives_its_characters_but_not_its_echo_test() ->
    Left = (changed([], [echo], #{vstatus => $\^X}, cooked()))#{csize := 7},
    Adopted = erx_tty_modes:adopt(cooked(), Left),
    {ok, _, _} = erx_tty:set(Adopted, erx_tty:new()),
    ?assertMatch(#{csize := 7}, Adopted),
    ?assert(has(echo, Adopted)),
    ?assertMatch(#{cc := #{vstatus := $\^X}}, Adopted).

the_masks_keep_flags_set_and_clear_test() ->
    Left = changed([noflsh, echonl, inlcr, igncr, onlret, ixoff],
                   [isig, echoe, echoctl, iexten, icrnl, opost, onlcr], #{}, cooked()),
    Adopted = erx_tty_modes:adopt(cooked(), Left),
    {ok, _, _} = erx_tty:set(Adopted, erx_tty:new()),
    [?assert(has(Flag, Adopted)) || Flag <- [isig, icanon, echo, echoe, echoctl, iexten, icrnl, opost, onlcr]],
    [?assertNot(has(Flag, Adopted)) || Flag <- [noflsh, echonl, inlcr, igncr, onlret]],
    %% A flag outside the masks comes from the holder.
    ?assert(has(ixoff, Adopted)).

a_raw_holder_leaves_nothing_but_its_speed_test() ->
    Cooked = changed([], [], #{vstatus => $\^X}, cooked()),
    Left = (changed([], [icanon, echo, isig], #{vstatus => $\^Y}, cooked()))#{ispeed := 38400, ospeed := 38400},
    ?assertEqual(Cooked#{ispeed := 38400, ospeed := 38400}, erx_tty_modes:adopt(Cooked, Left)).

the_editing_setting_reads_each_key_with_signals_test() ->
    Cooked = changed([], [], #{vmin => 4, vtime => 2}, cooked()),
    Editing = erx_tty_modes:editing(Cooked),
    [?assertNot(has(Flag, Editing)) || Flag <- [icanon, echo]],
    [?assert(has(Flag, Editing)) || Flag <- [isig, icrnl, opost, onlcr]],
    ?assertMatch(#{cc := #{vmin := 1, vtime := 0}}, Editing),
    %% The tty takes both as they are.
    {ok, _, _} = erx_tty:set(Editing, erx_tty:new()),
    {ok, _, _} = erx_tty:set(erx_tty_modes:adopt(Cooked, Editing), erx_tty:new()).
