%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_keys_tests).
-moduledoc """
The rule that tells a typed Ctrl-G from the BEL that ends a terminal's string
reply (erx_console_keys): every byte in every state against the table of the
rule, and properties over random input in random reads. A reply never makes a
Ctrl-G, whatever it holds and however it is cut; a BEL outside a string always
does; no byte but a typed Ctrl-G's is lost; and the pieces do not depend on
where the reads are cut.
""".

-include_lib("eunit/include/eunit.hrl").

-define(BEL, 16#07).
-define(ESC, 16#1B).
-define(CAN, 16#18).
-define(SUB, 16#1A).
-define(ROUNDS, 3000).

%% Every byte in every state, against the rule's table as docs/design-live.md states it.
next_test() ->
    [?assertEqual({State, Byte, expected(Byte, State)}, {State, Byte, erx_console_keys:next(Byte, State)})
     || State <- [ground, escape, string, csi, {c2, ground}, {c2, string}], Byte <- lists:seq(0, 255)].

%% After 0xC2, an 8-bit string control written as UTF-8 opens a string, U+009C ends one,
%% and any other byte is read as it would have been without the 0xC2.
expected(Byte, {c2, ground}) when Byte =:= 16#90; Byte =:= 16#98; Byte =:= 16#9D; Byte =:= 16#9E;
                                  Byte =:= 16#9F -> {byte, string};
expected(16#9B, {c2, ground}) -> {byte, csi};
expected(16#9C, {c2, string}) -> {byte, ground};
expected(Byte, {c2, State}) -> expected(Byte, State);
expected(16#C2, State) when State =:= ground; State =:= string -> {byte, {c2, State}};
expected(?BEL, string) -> {byte, ground};
expected(?BEL, _) -> {ctrl_g, ground};
expected(?ESC, _) -> {byte, escape};
expected($[, escape) -> {byte, csi};
expected(Byte, escape) ->
    case lists:member(Byte, "]P_^X") of
        true -> {byte, string};
        false -> {byte, ground}
    end;
expected(Byte, State) when (Byte =:= ?CAN orelse Byte =:= ?SUB), (State =:= string orelse State =:= csi) ->
    {byte, ground};
expected(Byte, csi) when Byte >= 16#40, Byte =< 16#7E -> {byte, ground};
expected(_, State) -> {byte, State}.

%% Sequences a person or a terminal sends, and what the line makes of them.
cases_test() ->
    Cases = [{<<"ab", ?BEL, "c">>, [<<"ab">>, ctrl_g, <<"c">>], ground},
             %% A colour report ends in BEL, a DCS reply in ST: neither is a Ctrl-G.
             {<<"\e]11;rgb:0000/0000/0000", ?BEL>>, [<<"\e]11;rgb:0000/0000/0000", ?BEL>>], ground},
             {<<"\eP1$r0m\e\\", ?BEL>>, [<<"\eP1$r0m\e\\">>, ctrl_g], ground},
             %% A cursor report ends at its final byte: a BEL after it is typed.
             {<<"\e[?62;22">>, [<<"\e[?62;22">>], csi},
             {<<"\e[24;80R", ?BEL>>, [<<"\e[24;80R">>, ctrl_g], ground},
             %% Meta-Ctrl-G, and a BEL after a cancelled string, are typed.
             {<<?ESC, ?BEL>>, [<<?ESC>>, ctrl_g], ground},
             {<<"\e]0;x", ?CAN, ?BEL>>, [<<"\e]0;x", ?CAN>>, ctrl_g], ground},
             %% Alt-] opens a string: the next Ctrl-G only ends it, the one after is typed.
             {<<"\e]", ?BEL, ?BEL>>, [<<"\e]", ?BEL>>, ctrl_g], ground},
             %% A reply cut short leaves its string open for the next read.
             {<<"\e]52;c;QUJD">>, [<<"\e]52;c;QUJD">>], string},
             %% An 8-bit OSC reply written as UTF-8, and a DCS ended by the 8-bit ST.
             {<<16#C2, 16#9D, "11;rgb:0/0/0", ?BEL>>, [<<16#C2, 16#9D, "11;rgb:0/0/0", ?BEL>>], ground},
             {<<16#C2, 16#90, "1$r0m", 16#C2, 16#9C, ?BEL>>, [<<16#C2, 16#90, "1$r0m", 16#C2, 16#9C>>, ctrl_g], ground},
             %% A character that begins with 0xC2 is text.
             {<<"\xc2\xa9", ?BEL>>, [<<"\xc2\xa9">>, ctrl_g], ground},
             {<<>>, [], ground}],
    [?assertEqual({Bytes, {Pieces, State}}, {Bytes, erx_console_keys:split(Bytes, erx_console_keys:new())})
     || {Bytes, Pieces, State} <- Cases].

%% Whatever a terminal's string reply holds but its own terminator and the controls that
%% end or cancel a string, however its reads are cut, it makes no Ctrl-G, every byte of
%% it stays, and the line is back in the ground state after it.
replies_make_no_ctrl_g_test() ->
    rand:seed(exsss, {7, 3, 1}),
    lists:foreach(fun(_) ->
                          Reply = reply(),
                          {Pieces, State} = split_in_reads(Reply, ground),
                          ?assertEqual({Reply, ground}, {iolist_to_binary(Pieces), State})
                  end, lists:seq(1, ?ROUNDS)).

%% Over random input in random reads: putting each typed Ctrl-G back as a BEL gives the
%% input back, and the pieces are the same as from one read of it all.
no_byte_lost_and_reads_do_not_matter_test() ->
    rand:seed(exsss, {7, 3, 2}),
    lists:foreach(fun(_) ->
                          Bytes = random_input(),
                          {Pieces, State} = split_in_reads(Bytes, ground),
                          ?assertEqual(Bytes, iolist_to_binary([bel(Piece) || Piece <- Pieces])),
                          {Whole, WholeState} = erx_console_keys:split(Bytes, ground),
                          ?assertEqual({merge(Whole), WholeState}, {merge(Pieces), State})
                  end, lists:seq(1, ?ROUNDS)).

%% A BEL read outside a string is always a typed Ctrl-G: text with no ESC or 0xC2 in it keeps
%% the line in the ground state, so each BEL in it is one.
every_bel_outside_a_string_is_ctrl_g_test() ->
    rand:seed(exsss, {7, 3, 3}),
    lists:foreach(fun(_) ->
                          Bytes = << <<B>> || <<B>> <= random_input(), B =/= ?ESC, B =/= 16#C2 >>,
                          {Pieces, ground} = split_in_reads(Bytes, ground),
                          Bels = length([B || <<B>> <= Bytes, B =:= ?BEL]),
                          ?assertEqual(Bels, length([P || P <- Pieces, P =:= ctrl_g]))
                  end, lists:seq(1, ?ROUNDS)).

%% A string reply, its controls in 7-bit form or in 8-bit form written as UTF-8: an OSC
%% ended by BEL or ST, or a DCS, APC, PM or SOS ended by ST, whose body is any bytes but
%% BEL, ESC, CAN, SUB and the 0x9C of the 8-bit ST.
reply() ->
    Body = << <<B>> || <<B>> <= rand:bytes(rand:uniform(64) - 1), not lists:member(B, [?BEL, ?ESC, ?CAN, ?SUB, 16#9C]) >>,
    {Introducer, Osc} = lists:nth(rand:uniform(10), [{<<?ESC, $]>>, true}, {<<16#C2, 16#9D>>, true}
                                                    | [{I, false} || I <- [<<"\eP">>, <<"\e_">>, <<"\e^">>, <<"\eX">>,
                                                                          <<16#C2, 16#90>>, <<16#C2, 16#9F>>,
                                                                          <<16#C2, 16#9E>>, <<16#C2, 16#98>>]]]),
    Terminator = case {Osc, rand:uniform(3)} of
                     {true, 1} -> <<?BEL>>;
                     {_, 2} -> <<16#C2, 16#9C>>;
                     _ -> <<"\e\\">>
                 end,
    case rand:uniform(4) of
        1 -> csi_reply();
        _ -> <<Introducer/binary, Body/binary, Terminator/binary>>
    end.

%% A control sequence reply, such as a cursor or device report: parameters and
%% intermediates, then one final byte.
csi_reply() ->
    Parameters = << <<(16#20 + rand:uniform(32) - 1)>> || _ <- lists:seq(1, rand:uniform(12) - 1) >>,
    Final = 16#40 + rand:uniform(63) - 1,
    <<"\e[", Parameters/binary, Final>>.

%% Random input rich in the bytes the rule looks at.
random_input() ->
    Alphabet = [?BEL, ?ESC, ?CAN, ?SUB, $], $P, $_, $^, $X, $\\, $[, $a, $0, 16#9D, 16#9C, 16#C2, 16#C3],
    << <<(lists:nth(rand:uniform(length(Alphabet)), Alphabet))>> || _ <- lists:seq(1, rand:uniform(40) - 1) >>.

split_in_reads(Bytes, State) ->
    split_in_reads(Bytes, State, []).

split_in_reads(<<>>, State, Acc) ->
    {lists:append(lists:reverse(Acc)), State};
split_in_reads(Bytes, State, Acc) ->
    Size = rand:uniform(byte_size(Bytes)),
    <<Read:Size/binary, Rest/binary>> = Bytes,
    {Pieces, Next} = erx_console_keys:split(Read, State),
    ?assertEqual([], [P || P <- Pieces, P =:= <<>>]),
    split_in_reads(Rest, Next, [Pieces | Acc]).

bel(ctrl_g) -> <<?BEL>>;
bel(Bytes) -> Bytes.

%% Pieces with adjacent bytes joined, as one read would have them.
merge([A, B | Rest]) when is_binary(A), is_binary(B) -> merge([<<A/binary, B/binary>> | Rest]);
merge([P | Rest]) -> [P | merge(Rest)];
merge([]) -> [].
