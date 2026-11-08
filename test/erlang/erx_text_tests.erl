%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The EUnit cases of erx_text's line escape and field escape: every character class
%% of test/fixtures/line_escape_vectors.json (whose path ERX_TEXT_VECTORS
%% names), which the host tool's Erx::LineEscape answers too
%% (test/host/line_escape_test.rb), and the properties of each escape.
-module(erx_text_tests).

-include_lib("eunit/include/eunit.hrl").

vectors() ->
    {ok, Json} = file:read_file(os:getenv("ERX_TEXT_VECTORS")),
    #{<<"vectors">> := Vectors} = json:decode(Json),
    [{Class, binary:decode_hex(Input), Line, Field}
     || #{<<"class">> := Class, <<"input">> := Input, <<"line">> := Line, <<"field">> := Field} <- Vectors].

%%% The line escape

line_vectors_test() ->
    [?assertEqual({Class, Line}, {Class, erx_text:escape_line(Input)}) || {Class, Input, Line, _} <- vectors()].

%% The same text as a character list, where it is one, escapes alike.
line_vectors_as_character_lists_test() ->
    [?assertEqual({Class, Line}, {Class, erx_text:escape_line(unicode:characters_to_list(Input))})
     || {Class, Input, Line, _} <- vectors(), is_list(unicode:characters_to_list(Input))].

line_chardata_test() ->
    %% A surrogate code point exists only in a character list.
    ?assertEqual(<<"<U+D800>x<U+DFFF>">>, erx_text:escape_line([16#D800, $x, 16#DFFF])),
    ?assertEqual(<<"<U+009B>2J">>, erx_text:escape_line([16#9B, "2J"])),
    %% Nested lists, binaries among them, and an improper tail.
    ?assertEqual(<<"ab<U+001B>c<0xFF>d">>, erx_text:escape_line([$a, [<<"b">>, [27 | <<"c">>]], <<16#FF, "d">>])),
    ?assertEqual(<<>>, erx_text:escape_line([[], [[]], <<>>])),
    ?assertEqual(<<"<U+10FFFF>">>, erx_text:escape_line([16#10FFFF])),
    %% Deep nesting costs heap, not stack.
    Deep = lists:foldl(fun(_, Acc) -> [Acc] end, "x", lists:seq(1, 100000)),
    ?assertEqual(<<"x">>, erx_text:escape_line(Deep)).

line_refuses_what_is_not_chardata_test() ->
    [?assertError(badarg, erx_text:escape_line(Bad))
     || Bad <- [[-1], [16#110000], [atom], atom, 65, [<<1:1>>], 1.0, [$a | b], [$a | $b],
                [<<"x">> | 16#202E]]].

line_output_is_safe_test() ->
    rand:seed(exsss, {1, 2, 3}),
    [begin
         Out = erx_text:escape_line(Bytes),
         Points = unicode:characters_to_list(Out),
         ?assert(is_list(Points)),
         ?assertEqual([], [P || P <- Points, unsafe(P)]),
         ?assertEqual(Out, erx_text:escape_line(Out))
     end || Bytes <- random_binaries(500)].

%%% The field escape

field_vectors_test() ->
    [?assertEqual({Class, Field}, {Class, erx_text:escape_field(Input)}) || {Class, Input, _, Field} <- vectors()].

%% Injective: unescape_field/1 recovers every input, the vectors and
%% random binaries alike, and its output is untouched by the line escape.
field_round_trip_test() ->
    rand:seed(exsss, {4, 5, 6}),
    Inputs = [Input || {_, Input, _, _} <- vectors()] ++ random_binaries(2000),
    [begin
         Field = erx_text:escape_field(Bytes),
         ?assertEqual({ok, Bytes}, erx_text:unescape_field(Field)),
         ?assertEqual(Field, erx_text:escape_line(Field)),
         ?assertEqual(nomatch, binary:match(Field, [<<"\t">>, <<"\n">>]))
     end || Bytes <- Inputs].

field_refuses_what_it_does_not_write_test() ->
    [?assertEqual({error, malformed}, erx_text:unescape_field(Bad))
     || Bad <- [<<"\\">>, <<"a\\">>, <<"\\q">>, <<"\\x">>, <<"\\x1">>, <<"\\x1g">>, <<"\\x1b">>, <<"\\T">>]],
    [?assertEqual({error, noncanonical}, erx_text:unescape_field(Bad))
     || Bad <- [<<"\t">>, <<"\n">>, <<27>>, <<"\\x41">>, <<"\\x5C">>, <<"\\x09">>, <<16#FF>>,
                <<"\x{202e}"/utf8>>, <<"\\xC3\\xA9">>]],
    %% Invalid UTF-8 is written byte by byte, so its tokens are canonical.
    ?assertEqual({ok, <<16#E2, 16#80>>}, erx_text:unescape_field(<<"\\xE2\\x80">>)).

%%% Helpers

%% Random binaries weighted towards the bytes that steer UTF-8 decoding.
random_binaries(N) ->
    Steering = [0, 9, 10, 27, 16#5C, 16#7F, 16#80, 16#9B, 16#BF, 16#C0, 16#C2, 16#E0, 16#E2, 16#ED,
                16#EF, 16#F0, 16#F4, 16#F5, 16#FF],
    [<< <<(case rand:uniform(3) of
               1 -> lists:nth(rand:uniform(length(Steering)), Steering);
               _ -> rand:uniform(256) - 1
           end)>> || _ <- lists:seq(1, rand:uniform(48) - 1) >> || _ <- lists:seq(1, N)].

unsafe(Point) ->
    lists:any(fun({First, Last}) -> Point >= First andalso Point =< Last end,
              tuple_to_list(erx_text_tables:unicode_unsafe_ranges())).
