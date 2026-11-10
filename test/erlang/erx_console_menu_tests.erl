%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_menu_tests).
-moduledoc """
The Ctrl-G menu's core (erx_console_menu), exhaustively over its small state
space: every set of up to three sessions, each of either principal and live or
not, every entry the line may return to, both principals at the line, and every
read of one byte and a few longer ones. Each read does what the menu's rule
says, no read connects a session the menu does not list, and the menu lists
exactly the line principal's live sessions. Its text shows each name only
through the line escape.
""".

-include_lib("eunit/include/eunit.hrl").

-define(ESC, 16#1B).
-define(BEL, 16#07).

every_state_and_read_test() ->
    Reads = [<<Byte>> || Byte <- lists:seq(0, 255)] ++ [<<>>, <<"12">>, <<"s1">>, <<?ESC, "[A">>, <<?ESC, ?ESC>>],
    Count = lists:sum([check(Principal, Sessions, Back, Reads)
                       || Sessions <- session_sets(), Principal <- [1, 2], Back <- backs()]),
    ?assertEqual(125 * 2 * 5, Count).

%% Each set of sessions with domain ids from 1 to 3, each absent or present with
%% principal 1 or 2, live or not.
session_sets() ->
    Choices = [absent | [{P, Live} || P <- [1, 2], Live <- [true, false]]],
    [[#{domain => D, name => name(D), principal => P, live => Live}
      || {D, {P, Live}} <- lists:zip([1, 2, 3], [C1, C2, C3])]
     || C1 <- Choices, C2 <- Choices, C3 <- Choices].

backs() ->
    [system, {session, 1}, {session, 2}, {session, 3}, {session, 9}].

name(D) -> <<"s", (integer_to_binary(D))/binary>>.

check(Principal, Sessions, Back, Reads) ->
    Menu = erx_console_menu:open(Principal, Sessions, Back),
    Listed = lists:sort([D || #{domain := D, principal := P, live := true} <- Sessions, P =:= Principal]),
    Keys = lists:zip(lists:sublist(binary_to_list(erx_console_menu:keys()), length(Listed)), Listed),
    lists:foreach(fun(Read) ->
                          {Action, After} = erx_console_menu:key(Read, ground, Menu),
                          ?assertEqual(element(2, erx_console_keys:split(Read, ground)), After),
                          %% Inside a string, an escape or a sequence a terminal is sending, no
                          %% read is a key but Esc after an escape, which no terminal sends.
                          [?assertMatch({bell, _}, erx_console_menu:key(Read, Before, Menu))
                           || Before <- [escape, string, csi, {c2, ground}, {c2, string}],
                              {Read, Before} =/= {<<?ESC>>, escape}],
                          ?assertEqual(expected(<<?ESC>>, Keys, Back),
                                       element(1, erx_console_menu:key(<<?ESC>>, escape, Menu))),
                          ?assertEqual({Principal, Sessions, Back, Read, expected(Read, Keys, Back)},
                                       {Principal, Sessions, Back, Read, Action}),
                          %% The menu reaches only the sessions it lists.
                          case Action of
                              {connect, D} -> ?assert(lists:member(D, Listed));
                              _ -> ok
                          end
                  end, Reads),
    Text = iolist_to_binary(erx_console_menu:text(Menu)),
    [?assertEqual({D, true}, {D, binary:match(Text, [<<"  ", K, (mark({session, D} =:= Back)), " ", (name(D))/binary>>])
                                 =/= nomatch})
     || {K, D} <- Keys],
    [?assertEqual({D, nomatch}, {D, binary:match(Text, name(D))})
     || #{domain := D} <- Sessions, not lists:member(D, Listed)],
    ?assertEqual(expected(<<?ESC>>, Keys, Back) =:= system,
                 binary:match(Text, <<"  s* system shell\r\n">>) =/= nomatch),
    %% A session the menu shows is an entry or the one Esc returns to; no other.
    [?assertEqual(lists:member(D, Listed) orelse Back =:= {session, D}, erx_console_menu:shows(D, Menu))
     || D <- [1, 2, 3, 9]],
    1.

%% The menu's rule: only a read of one byte is a key; `s` is the system shell and `n`
%% starts a session; Esc and Ctrl-G return to the session that had the line while it is
%% listed, and otherwise to the system shell; a listed session's key connects it; any other
%% read rings the bell.
expected(<<$s>>, _Keys, _Back) -> system;
expected(<<$n>>, _Keys, _Back) -> start;
expected(<<B>>, Keys, Back) when B =:= ?ESC; B =:= ?BEL ->
    case Back of
        {session, D} ->
            case lists:keymember(D, 2, Keys) of
                true -> {connect, D};
                false -> system
            end;
        system ->
            system
    end;
expected(<<K>>, Keys, _Back) ->
    case lists:keyfind(K, 1, Keys) of
        {K, D} -> {connect, D};
        false -> bell
    end;
expected(_Read, _Keys, _Back) ->
    bell.

mark(true) -> $*;
mark(false) -> $\s.

%% The keys are distinct and none is the menu's own.
keys_test() ->
    Keys = binary_to_list(erx_console_menu:keys()),
    ?assertEqual(length(Keys), length(lists:usort(Keys))),
    ?assertEqual([], [K || K <- Keys, lists:member(K, [$s, $n, ?ESC, ?BEL])]).

%% More live sessions than keys: each key reaches one, and the rest are counted.
more_sessions_than_keys_test() ->
    Keys = erx_console_menu:keys(),
    N = byte_size(Keys) + 7,
    Sessions = [#{domain => D, name => name(D), principal => 1, live => true} || D <- lists:seq(1, N)],
    Menu = erx_console_menu:open(1, Sessions, system),
    ?assertEqual([{connect, D} || D <- lists:seq(1, byte_size(Keys))],
                 [element(1, erx_console_menu:key(<<K>>, ground, Menu)) || <<K>> <= Keys]),
    Text = iolist_to_binary(erx_console_menu:text(Menu)),
    ?assertMatch({_, _}, binary:match(Text, <<"7 more sessions, not listed">>)),
    ?assertEqual(nomatch, binary:match(Text, name(N))).

%% A name holding controls and escape sequences reaches the text only through the line
%% escape: the text holds no control but each line's CR-LF.
names_are_escaped_test() ->
    Hostile = [<<"\e]0;owned", ?BEL>>, <<"\e[2J\e[H">>, <<"a\r\nfake">>, <<16#9B, "31m">>,
               <<"\xe2\x80\xae", "rtl">>, <<"\xc2\x9d", "8;;x">>, <<0, 1, 127>>],
    Sessions = [#{domain => D, name => Name, principal => 1, live => true}
                || {D, Name} <- lists:zip(lists:seq(1, length(Hostile)), Hostile)],
    Text = iolist_to_binary(erx_console_menu:text(erx_console_menu:open(1, Sessions, {session, 1}))),
    Lines = binary:split(Text, <<"\r\n">>, [global]),
    ?assertEqual([], [C || Line <- Lines, <<C>> <= Line, C < 16#20 orelse C =:= 16#7F]),
    [?assertEqual(nomatch, binary:match(Text, Raw)) || Raw <- [<<"\xe2\x80\xae">>, <<"\xc2\x9d">>]],
    [?assertMatch({_, _}, binary:match(Text, erx_text:escape_line(Name))) || Name <- Hostile].
