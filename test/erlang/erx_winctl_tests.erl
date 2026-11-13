%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_winctl, the parser of a present written to a window's
%% ctl file (docs/design-display.md, "The window tree"): the grammar and its
%% white space, none rectangles meaning the whole buffer, clipping to the
%% buffer, the size, offset, coordinate and rectangle-count bounds, ill-formed
%% rectangles, the 1,024-byte line bound, and bytes outside printable ASCII.

-module(erx_winctl_tests).
-include_lib("eunit/include/eunit.hrl").

present(Offset, Width, Height, Rects) ->
    {ok, #{offset => Offset, width => Width, height => Height, rects => Rects}}.

a_present_without_rectangles_is_the_whole_buffer_test() ->
    ?assertEqual(present(4096, 640, 480, [{0, 0, 640, 480}]),
                 erx_winctl:parse(<<"present 4096 640 480">>)),
    ?assertEqual(present(0, 1, 1, [{0, 0, 1, 1}]),
                 erx_winctl:parse(<<" \tpresent  0\t1 1 \n">>)),
    ?assertEqual(present(7, 2, 2, [{0, 0, 2, 2}]),
                 erx_winctl:parse(<<"present 0007 2 2">>)).

rectangles_are_clipped_to_the_buffer_test() ->
    ?assertEqual(present(0, 100, 50, [{10, 10, 20, 20}, {0, 0, 100, 50}, {90, 0, 100, 5}]),
                 erx_winctl:parse(<<"present 0 100 50 10 10 20 20 -5 -5 200 200 90 -3 120 5\n">>)),
    %% A rectangle outside the buffer, or empty, is dropped; one that is all
    %% there was leaves nothing to copy, not the whole buffer.
    ?assertEqual(present(0, 100, 50, [{0, 0, 1, 1}]),
                 erx_winctl:parse(<<"present 0 100 50 200 0 300 10 5 5 5 9 0 0 1 1">>)),
    ?assertEqual(present(0, 100, 50, []),
                 erx_winctl:parse(<<"present 0 100 50 -10 -10 -1 -1">>)).

sizes_offsets_and_coordinates_are_bounded_test() ->
    ?assertMatch({ok, #{width := 16384, height := 16384}},
                 erx_winctl:parse(<<"present 0 16384 16384">>)),
    [?assertEqual({error, einval}, erx_winctl:parse(Line))
     || Line <- [<<"present 0 16385 1">>, <<"present 0 1 16385">>,
                 <<"present 0 0 1">>, <<"present 0 1 0">>,
                 <<"present -1 1 1">>, <<"present 0 -1 1">>, <<"present 0 +1 1">>,
                 <<"present 9223372036854775808 1 1">>,
                 <<"present 0 1 1 0 0 2147483648 1">>,
                 <<"present 0 1 1 -2147483649 0 1 1">>,
                 <<"present 00000000000000000001 1 1">>, <<"present 0 1 1 -00000000000000000001 0 1 1">>]],
    ?assertMatch({ok, #{offset := 9223372036854775807}},
                 erx_winctl:parse(<<"present 9223372036854775807 1 1">>)),
    ?assertMatch({ok, #{rects := [{0, 0, 1, 1}]}},
                 erx_winctl:parse(<<"present 0 1 1 -2147483648 -2147483648 2147483647 2147483647">>)).

at_most_sixteen_well_formed_rectangles_test() ->
    Rects = fun(N) -> iolist_to_binary([" 0 0 1 1" || _ <- lists:seq(1, N)]) end,
    ?assertMatch({ok, #{rects := [_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _]}},
                 erx_winctl:parse(<<"present 0 4 4", (Rects(16))/binary>>)),
    ?assertEqual({error, einval}, erx_winctl:parse(<<"present 0 4 4", (Rects(17))/binary>>)),
    [?assertEqual({error, einval}, erx_winctl:parse(Line))
     || Line <- [<<"present 0 4 4 2 0 1 1">>, <<"present 0 4 4 0 2 1 1">>,
                 <<"present 0 4 4 0 0 1">>, <<"present 0 4 4 0 0 1 1 2">>]].

a_line_is_at_most_1024_bytes_test() ->
    Pad = fun(N) -> binary:copy(<<" ">>, N) end,
    Line = <<"present 0 1 1">>,
    Fits = 1024 - byte_size(Line) - 1,
    ?assertMatch({ok, _}, erx_winctl:parse(<<Line/binary, (Pad(Fits))/binary, "\n">>)),
    ?assertEqual({error, einval}, erx_winctl:parse(<<Line/binary, (Pad(Fits + 1))/binary, "\n">>)),
    ?assertEqual({error, einval}, erx_winctl:parse(<<Line/binary, (Pad(Fits + 2))/binary>>)).

anything_outside_the_grammar_is_refused_test() ->
    [?assertEqual({error, einval}, erx_winctl:parse(Bytes))
     || Bytes <- [<<>>, <<"\n">>, <<"present">>, <<"present 0 1">>, <<"Present 0 1 1">>,
                  <<"present 0 1 1\n\n">>, <<"present 0 1 1\r\n">>, <<"present\v0 1 1">>,
                  <<"present 0 1 1 ", 16#c3, 16#a9>>, <<"present 0 1 1", 0>>,
                  <<"present 0x10 1 1">>, <<"present 0 1 1 0 0 1 1e">>, <<"present 0 1 1 - 0 1 1">>,
                  <<"flush 0 1 1">>, not_a_binary]].
