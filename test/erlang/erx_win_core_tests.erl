%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_win_core (test/host/erx_win_test.rb): the readers of what a
%% display answers a client, with the formats erx_window and erx_wctl write, and the
%% buffer layout and lines a client writes.

-module(erx_win_core_tests).
-include_lib("eunit/include/eunit.hrl").

ctl_test() ->
    ?assertMatch({ok, #{text := <<"x8r8g8b8">>, code := 16#68081828, depth := 32}},
                 erx_win_core:ctl(<<"x8r8g8b8\n">>)),
    ?assertMatch({ok, #{depth := 16}}, erx_win_core:ctl(<<"r5g6b5\n">>)),
    [?assertEqual({error, eio}, erx_win_core:ctl(Bad))
     || Bad <- [<<>>, <<"\n">>, <<"x8r8g8b8">>, <<"x8r8g8b8\n\n">>, <<"q8\n">>,
                <<"x8r8g8b8a8\n">>, <<"r3\n">>, not_a_binary]].

wctl_test() ->
    Read = erx_wctl:format({-5, 0, 1920, 1080}, true, shown),
    ?assertEqual({ok, #{rect => {-5, 0, 1920, 1080}, current => true, state => shown}},
                 erx_win_core:wctl(Read)),
    ?assertEqual({ok, #{rect => {0, 0, 8, 4}, current => false, state => hidden}},
                 erx_win_core:wctl(erx_wctl:format({0, 0, 8, 4}, false, hidden))),
    %% A rectangle upside down, too large, a word out of place, a field not right-aligned,
    %% a short read and a long one.
    Bad = [erx_wctl:format({9, 0, 8, 4}, true, shown),
           erx_wctl:format({0, 0, 16385, 4}, true, shown),
           swap_words(Read),
           <<"0          ", (binary:part(Read, 11, 61))/binary>>,
           binary:part(Read, 0, 71),
           <<Read/binary, " ">>],
    [?assertEqual({error, eio}, erx_win_core:wctl(B)) || B <- Bad].

mouse_test() ->
    Record = iolist_to_binary(io_lib:format("~c~11B ~11B ~11B ~11B ", [$m, -3, 7, 1, 2147483647])),
    ?assertEqual({ok, {mouse, -3, 7, 1, 2147483647}}, erx_win_core:mouse(Record)),
    <<_, Rest/binary>> = Record,
    ?assertEqual({ok, {resized, -3, 7, 1, 2147483647}}, erx_win_core:mouse(<<$r, Rest/binary>>)),
    Negative = iolist_to_binary(io_lib:format("~c~11B ~11B ~11B ~11B ", [$m, 0, 0, -1, 0])),
    [?assertEqual({error, eio}, erx_win_core:mouse(B))
     || B <- [<<$x, Rest/binary>>, Negative, binary:part(Record, 0, 48), <<Record/binary, 0>>,
              <<>>]].

kbd_test() ->
    ?assertEqual({ok, {typed, $a}}, erx_win_core:kbd(<<"ca", 0>>)),
    ?assertEqual({ok, {typed, 16#4e16}}, erx_win_core:kbd(<<$c, 16#4e16/utf8, 0>>)),
    ?assertEqual({ok, {down, "ab"}}, erx_win_core:kbd(<<"kab", 0>>)),
    ?assertEqual({ok, {up, []}}, erx_win_core:kbd(<<"K", 0>>)),
    [?assertEqual({error, eio}, erx_win_core:kbd(B))
     || B <- [<<"c", 0>>, <<"cab", 0>>, <<"ca">>, <<"ca", 0, 0>>, <<"xa", 0>>, <<"c", 16#ff, 0>>,
              <<"k", 16#ed, 16#a0, 16#80, 0>>, <<>>, <<"c">>]].

layout_test() ->
    ?assertEqual(32, erx_win_core:stride(8, 32)),
    ?assertEqual(4, erx_win_core:stride(1, 16)),
    ?assertEqual({ok, 8294400}, erx_win_core:bytes(1920, 1080, 32)),
    ?assertEqual({ok, 1 bsl 30}, erx_win_core:bytes(16384, 16384, 32)),
    [?assertEqual({error, einval}, erx_win_core:bytes(W, H, 32))
     || {W, H} <- [{0, 1}, {1, 0}, {16385, 1}, {1, 16385}, {-1, -1}]],
    ?assertEqual({0, 0, 8, 4}, erx_win_core:image_rect({10, 10, 30, 30}, {8, 4})),
    ?assertEqual({0, 0, 5, 3}, erx_win_core:image_rect({10, 10, 15, 13}, {8, 4})).

lines_test() ->
    ?assertEqual(<<"present 4096 8 4\n">>, erx_win_core:present(4096, 8, 4, [])),
    ?assertEqual(<<"present 0 8 4 0 0 1 1\n">>, erx_win_core:present(0, 8, 4, [{0, 0, 1, 1}])),
    Many = [{I, I, I + 1, I + 1} || I <- lists:seq(0, 16)],
    ?assertEqual(<<"present 0 20 20 0 0 17 17\n">>, erx_win_core:present(0, 20, 20, Many)),
    ?assertEqual({ok, #{offset => 0, width => 20, height => 20, rects => [{0, 0, 17, 17}]}},
                 erx_winctl:parse(erx_win_core:present(0, 20, 20, Many))),
    ?assertEqual({ok, {resize, {0, -1, 5, 6}}}, erx_wctl:parse(erx_win_core:resize({0, -1, 5, 6}))).

swap_words(Read) ->
    <<Numbers:48/binary, Focus:12/binary, State:12/binary>> = Read,
    <<Numbers/binary, State/binary, Focus/binary>>.
