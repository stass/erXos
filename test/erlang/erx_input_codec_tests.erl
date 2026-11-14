%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The input records' codec, erx_input_codec, generated from abi/formats/input.txt
%% (docs/design-abi.md, "Input records"; docs/design-display.md, "The display device"):
%% every kind of record, release included, round trips at the edges of its bounds; a
%% term one past a bound is not a record and does not encode; the bytes of a record
%% with an unknown tag, a field past its bound or a nonzero padding byte are dropped
%% and counted, with the records around them kept; and the bytes after the last
%% whole record come back to be read with the next.
-module(erx_input_codec_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SIZE, 9).
-define(KEY_MAX, 16#2ff).

%% Every kind at each edge of each of its bounds.
edges() ->
    [{pointer, rel, Dx, Dy} || Dx <- [-16#80000000, 0, 16#7fffffff], Dy <- [-16#80000000, -1, 16#7fffffff]]
        ++ [{pointer, abs, X, Y} || X <- [0, 65535], Y <- [0, 1, 65535]]
        ++ [{touch, Slot, Phase, X, Y} || Slot <- [0, 9], Phase <- [down, move, up], X <- [0, 65535], Y <- [0, 65535]]
        ++ [{key, Edge, Code} || Edge <- [down, up], Code <- [0, 30, ?KEY_MAX]]
        ++ [{wheel, Steps} || Steps <- [-128, -1, 0, 1, 127]]
        ++ [release].

size_is_the_declared_one_test() ->
    ?assertEqual(?SIZE, erx_input_codec:size()).

every_kind_round_trips_at_its_edges_test() ->
    lists:foreach(
      fun(Record) ->
              Bytes = erx_input_codec:encode(Record),
              ?assertEqual(?SIZE, byte_size(Bytes)),
              ?assert(erx_input_codec:valid(Record)),
              ?assertEqual({[Record], 0, <<>>}, erx_input_codec:decode(Bytes))
      end, edges()).

a_stream_of_every_kind_round_trips_in_order_test() ->
    Bytes = << <<(erx_input_codec:encode(Record))/binary>> || Record <- edges() >>,
    ?assertEqual({edges(), 0, <<>>}, erx_input_codec:decode(Bytes)).

%% The layout pins: a tag, then the fields little-endian, then zero bytes.
the_bytes_are_the_declared_layout_test() ->
    ?assertEqual(<<1, 16#fe, 16#ff, 16#ff, 16#ff, 3, 0, 0, 0>>, erx_input_codec:encode({pointer, rel, -2, 3})),
    ?assertEqual(<<2, 16#34, 16#12, 16#ff, 16#ff, 0, 0, 0, 0>>, erx_input_codec:encode({pointer, abs, 16#1234, 65535})),
    ?assertEqual(<<3, 9, 1, 1, 0, 2, 0, 0, 0>>, erx_input_codec:encode({touch, 9, move, 1, 2})),
    ?assertEqual(<<4, 1, 16#ff, 2, 0, 0, 0, 0, 0>>, erx_input_codec:encode({key, up, ?KEY_MAX})),
    ?assertEqual(<<5, 16#80, 0, 0, 0, 0, 0, 0, 0>>, erx_input_codec:encode({wheel, -128})),
    ?assertEqual(<<6, 0, 0, 0, 0, 0, 0, 0, 0>>, erx_input_codec:encode(release)).

%% One past each bound, a wrong atom, a wrong type and a wrong shape.
outside() ->
    [{pointer, rel, -16#80000001, 0}, {pointer, rel, 0, 16#80000000}, {pointer, rel, 1.0, 0},
     {pointer, abs, -1, 0}, {pointer, abs, 0, 65536},
     {pointer, sideways, 0, 0}, {pointer, abs, 0},
     {touch, -1, down, 0, 0}, {touch, 10, down, 0, 0}, {touch, 0, held, 0, 0},
     {touch, 0, down, 65536, 0}, {touch, 0, down, 0, -1},
     {key, down, -1}, {key, down, ?KEY_MAX + 1}, {key, repeat, 30}, {key, 0, 30},
     {wheel, -129}, {wheel, 128}, {wheel, a},
     {release}, releases, {}, [], 6].

a_term_past_a_bound_is_no_record_and_does_not_encode_test() ->
    lists:foreach(
      fun(Term) ->
              ?assertNot(erx_input_codec:valid(Term)),
              ?assertError(badarg, erx_input_codec:encode(Term))
      end, outside()).

%% Bytes of the size whose tag, field or padding no record has.
bad_records() ->
    [<<0, 0:64>>, <<7, 0:64>>, <<255, 0:64>>,
     <<2, 0:32, 1, 0:24>>, <<3, 0, 0, 0:32, 0, 1>>, <<4, 0, 30, 0, 0:32, 1>>, <<5, 0, 1, 0:48>>, <<6, 0:56, 1>>,
     <<3, 10, 0, 0:48>>, <<3, 255, 0, 0:48>>, <<3, 0, 3, 0:48>>, <<3, 0, 255, 0:48>>,
     <<4, 2, 30, 0, 0:40>>, <<4, 0, (?KEY_MAX + 1):16/little, 0:40>>, <<4, 0, 16#ff, 16#ff, 0:40>>].

each_bad_record_is_dropped_and_counted_and_its_neighbours_kept_test() ->
    Good = erx_input_codec:encode({key, down, 30}),
    lists:foreach(
      fun(Bad) ->
              ?assertEqual(?SIZE, byte_size(Bad)),
              ?assertEqual({[], 1, <<>>}, erx_input_codec:decode(Bad)),
              ?assertEqual({[{key, down, 30}, {key, down, 30}], 1, <<>>},
                           erx_input_codec:decode(<<Good/binary, Bad/binary, Good/binary>>))
      end, bad_records()),
    All = << <<Bad/binary>> || Bad <- bad_records() >>,
    ?assertEqual({[], length(bad_records()), <<>>}, erx_input_codec:decode(All)).

the_bytes_after_the_last_whole_record_come_back_test() ->
    Good = erx_input_codec:encode({wheel, 1}),
    ?assertEqual({[], 0, <<>>}, erx_input_codec:decode(<<>>)),
    lists:foreach(
      fun(Length) ->
              Part = binary:part(Good, 0, Length),
              ?assertEqual({[], 0, Part}, erx_input_codec:decode(Part)),
              ?assertEqual({[{wheel, 1}], 0, Part}, erx_input_codec:decode(<<Good/binary, Part/binary>>))
      end, lists:seq(1, ?SIZE - 1)).
