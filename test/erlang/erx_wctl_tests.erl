%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_wctl, the text of a window's wctl file
%% (docs/design-display.md, "Interfaces"): each command of the grammar,
%% the white space rio's parser allows, what it refuses, the 1,024-byte
%% bound, the coordinate range, and rio's 72-byte read layout.

-module(erx_wctl_tests).
-include_lib("eunit/include/eunit.hrl").

parses_each_command_test() ->
    ?assertEqual({ok, {resize, {0, 0, 640, 480}}}, erx_wctl:parse(<<"resize -r 0 0 640 480">>)),
    ?assertEqual({ok, {move, {-5, 10, 20, 30}}}, erx_wctl:parse(<<"move -r -5 10 20 30\n">>)),
    [?assertEqual({ok, Command}, erx_wctl:parse(atom_to_binary(Command)))
     || Command <- [hide, show, top, bottom]].

white_space_around_words_test() ->
    ?assertEqual({ok, top}, erx_wctl:parse(<<" \ttop \t\n">>)),
    ?assertEqual({ok, {resize, {1, 2, 3, 4}}},
                 erx_wctl:parse(<<"resize\t-r  1\t2 3    4 ">>)).

refuses_what_is_outside_the_grammar_test() ->
    [?assertEqual({error, einval}, erx_wctl:parse(Line))
     || Line <- [<<>>, <<"\n">>, <<"top\n\n">>, <<"top\r\n">>, <<"Top">>,
                 <<"top extra">>, <<"new">>, <<"delete">>, <<"current">>, <<"unhide">>,
                 <<"resize">>, <<"resize -r 1 2 3">>, <<"resize -r 1 2 3 4 5">>,
                 <<"resize -dx 10">>, <<"move -minx 10">>, <<"resize -r +1 2 3 4">>,
                 <<"resize -r 1 2 3 4x">>, <<"resize -r - 2 3 4">>, <<"resize -r 0x10 2 3 4">>,
                 <<"top", 0>>, <<"to", 16#c3, 16#a9>>, <<"top\nbottom">>, not_binary]].

coordinates_must_fit_32_bits_test() ->
    ?assertEqual({ok, {move, {-2147483648, 2147483647, 0, 0}}},
                 erx_wctl:parse(<<"move -r -2147483648 2147483647 0 0">>)),
    ?assertEqual({error, einval}, erx_wctl:parse(<<"move -r -2147483649 0 0 0">>)),
    ?assertEqual({error, einval}, erx_wctl:parse(<<"move -r 2147483648 0 0 0">>)),
    ?assertEqual({ok, {move, {7, 0, 0, 0}}}, erx_wctl:parse(<<"move -r 0000007 0 0 0">>)).

a_line_is_at_most_1024_bytes_test() ->
    Pad = fun(N) -> binary:copy(<<" ">>, N) end,
    ?assertEqual({ok, top}, erx_wctl:parse(<<"top", (Pad(1020))/binary, "\n">>)),
    ?assertEqual({error, einval}, erx_wctl:parse(<<"top", (Pad(1021))/binary, "\n">>)),
    ?assertEqual({error, einval}, erx_wctl:parse(<<"top", (Pad(1022))/binary>>)).

formats_rio_layout_test() ->
    Text = erx_wctl:format({0, -20, 640, 2147483647}, true, shown),
    ?assertEqual(<<"          0         -20         640  2147483647     current     visible ">>, Text),
    ?assertEqual(72, byte_size(erx_wctl:format({-2147483648, 0, 0, 0}, false, hidden))),
    ?assertEqual(<<"notcurrent      hidden ">>,
                 binary:part(erx_wctl:format({1, 1, 2, 2}, false, hidden), 49, 23)).
