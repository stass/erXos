%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% erx_draw_codec, generated from abi/formats/draw.txt, and erx_draw_image
%% (docs/design-display.md, "Draw messages"). The EUnit cases pin the
%% decoder's errors and offsets, the coded points at the edges of their two
%% forms, 9front's bytesperline left of 0 and image(6)'s back-references.
%% corpus/3 and decode_corpus/2 are the Erlang side of the differential
%% test against the C twin (test/host/erx_draw_codec_test.rb): the corpus
%% holds random messages of every letter the table declares, compressed
%% payloads with back-references, and mutants of both.
-module(erx_draw_codec_tests).
-include_lib("eunit/include/eunit.hrl").
-export([corpus/3, decode_corpus/2, corpus_case/0, depth_fun/1]).

-define(DEPTH_IDS, 8).

%% The decoder's view of the depths of ids 0 to 7 that a case's first bytes give.
depth_fun(Depths) ->
    fun(Id) when Id < ?DEPTH_IDS ->
            case binary:at(Depths, Id) rem 33 of 0 -> none; Depth -> Depth end;
       (_) -> none
    end.

all_depths(_) -> 8.

errors_test() ->
    D = fun all_depths/1,
    ?assertEqual({error, einval, 0}, erx_draw_codec:decode(<<>>, D)),
    ?assertEqual({error, einval, 0}, erx_draw_codec:decode(<<"A", 0:32>>, D)),
    ?assertEqual({error, einval, 5}, erx_draw_codec:decode(<<"d", 1:32/little, 2:16>>, D)),
    ?assertEqual({error, enoent, 21},
                 erx_draw_codec:decode(<<"y", 9:32/little, 0:128>>, depth_fun(<<0:64>>))),
    ?assertEqual({error, einval, 21}, erx_draw_codec:decode(<<"y", 1:32/little, 0:128>>, D)),
    %% One byte short of a 2x2 load at depth 8.
    Rect = << <<V:32/little-signed>> || V <- [0, 0, 2, 2] >>,
    ?assertEqual({error, einval, 21}, erx_draw_codec:decode(<<"y", 1:32/little, Rect/binary, 0:24>>, D)),
    ?assertMatch({ok, {load, 1, {0, 0, 2, 2}, <<0:32>>}, <<"v">>},
                 erx_draw_codec:decode(<<"y", 1:32/little, Rect/binary, 0:32, "v">>, D)).

%% 9front's bytesperline, dividing toward zero: a row wholly left of 0 can
%% count a byte more than it covers, and the sign of min.x matters.
bytes_per_line_test() ->
    Cases = [{{-16, 0, -8, 1}, 8, 9}, {{-9, 0, -8, 1}, 1, 2}, {{-3, 0, 5, 1}, 8, 8}, {{3, 0, 10, 1}, 4, 4},
             {{-1, 0, 0, 1}, 1, 1}, {{0, 0, 1, 1}, 32, 4}, {{-7, 0, 9, 1}, 24, 48}, {{1, 0, 2, 1}, 1, 1}],
    [?assertEqual({R, Depth, Want}, {R, Depth, erx_draw_image:bytes_per_line(R, Depth)})
     || {R, Depth, Want} <- Cases].

%% Each coordinate at the edges of the one-byte difference and the
%% three-byte value, as fixed bytes after a poly's header of one point.
coded_points_test() ->
    Head = <<"p", 1:32/little, 0:16, 0:32, 0:32, 0:32, 2:32/little, 0:64>>,
    Cases = [{<<16#3f, 16#40>>, {63, -64}}, {<<16#01, 16#7f>>, {1, -1}},
             {<<16#ff, 16#ff, 16#7f, 16#80, 0, 16#80>>, {4194303, -4194304}},
             {<<16#80, 0, 16#40, 16#81, 1, 0>>, {2097152, 129}}],
    [?assertEqual({ok, {poly, 1, 0, 0, 0, 2, {0, 0}, [Point]}, <<>>},
                  erx_draw_codec:decode(<<Head/binary, Bytes/binary>>, fun all_depths/1))
     || {Bytes, Point} <- Cases],
    %% A difference counts from the previous coordinate, the first from 0.
    Two = <<"p", 1:32/little, 1:16/little, 0:32, 0:32, 0:32, 2:32/little, 0:64, 5, 16#7b, 16#3f, 16#3f>>,
    ?assertMatch({ok, {poly, _, _, _, _, _, _, [{5, -5}, {68, 58}]}, <<>>},
                 erx_draw_codec:decode(Two, fun all_depths/1)),
    %% x 64 is a difference of 1 from 63; y 0 is 64 from -64, past the one-byte form.
    ?assertEqual(<<16#3f, 16#40, 16#01, 16#80, 0, 0>>,
                 binary:part(erx_draw_codec:encode({poly, 1, 0, 0, 0, 2, {0, 0}, [{63, -64}, {64, 0}]}), 31, 6)).

%% A literal, a back-reference nearer than its length, one reaching before
%% the output (zeros), and the codes that cross a row's end or stop short.
image_test() ->
    R = {0, 0, 6, 1},
    ?assertEqual({ok, <<7, 7, 7, 7, 7, 9>>, <<"rest">>},
                 erx_draw_image:decode(<<128, 7, 4, 0, 128, 9, "rest">>, R, 8)),
    ?assertEqual({ok, <<0, 0, 0, 1, 2, 3>>, <<>>}, erx_draw_image:decode(<<0, 5, 130, 1, 2, 3>>, R, 8)),
    ?assertEqual({ok, <<1, 2, 1, 2>>, <<>>}, erx_draw_image:decode(<<129, 1, 2, 129, 1, 2>>, {0, 0, 2, 2}, 8)),
    ?assertEqual(error, erx_draw_image:decode(<<130, 1, 2, 3>>, {0, 0, 2, 2}, 8)),
    ?assertEqual(error, erx_draw_image:decode(<<128, 1, 0, 0>>, {0, 0, 3, 1}, 8)),
    ?assertEqual(error, erx_draw_image:decode(<<131, 1, 2, 3>>, R, 8)),
    ?assertEqual(error, erx_draw_image:decode(<<>>, {0, 0, 0, 1}, 8)).

round_trip_test() ->
    rand:seed(exsss, {3, 5, 7}),
    D = fun all_depths/1,
    [begin
         {Message, Bytes} = random_message(D),
         ?assertEqual({ok, Message, <<"tail">>}, erx_draw_codec:decode(<<Bytes/binary, "tail">>, D))
     end || _ <- lists:seq(1, 3000)].

letters() -> [Letter || Letter <- lists:seq(0, 255), erx_draw_codec:layout(Letter) =/= unknown].

%% A random message of a random letter and its encoding.
random_message(Depth) ->
    {Name, Fields} = erx_draw_codec:layout(pick(letters())),
    Values = lists:foldl(fun(Field, Acc) -> Acc ++ [value(Field, Acc, Depth)] end, [], Fields),
    Message = case [Value || {Field, Value} <- lists:zip(Fields, Values), Field =/= count] of
                  [] -> Name;
                  Carried -> list_to_tuple([Name | Carried])
              end,
    {Message, erx_draw_codec:encode(Message)}.

value(u8, _, _) -> rand:uniform(256) - 1;
value(u16, _, _) -> rand:uniform(65536) - 1;
value(count, _, _) -> pick([0, 1, 2, 5]);
value(Type, _, _) when Type =:= u32; Type =:= i32 ->
    V = pick([0, 1, 16#7fffffff, rand:uniform(16#100000000) - 1]),
    case Type of u32 -> V; i32 -> V - 16#80000000 end;
value(id, _, _) -> rand:uniform(10) - 1;
value(point, _, _) -> {coord(), coord()};
value(rect, _, _) ->
    {X0, Y0} = {rand:uniform(41) - 21, rand:uniform(41) - 21},
    {X0, Y0, X0 + rand:uniform(12), Y0 + rand:uniform(3)};
value({points, Count}, Acc, _) ->
    [{pick([rand:uniform(129) - 65, rand:uniform(16#800000) - 16#400001]), rand:uniform(129) - 65}
     || _ <- lists:seq(0, lists:nth(Count, Acc))];
value({indices, Count}, Acc, _) -> [rand:uniform(65536) - 1 || _ <- lists:seq(1, lists:nth(Count, Acc))];
value({_, Id, Rect}, Acc, Depth) ->
    Bits = case Depth(lists:nth(Id, Acc)) of none -> 8; Known -> Known end,
    {_, Y0, _, Y1} = R = lists:nth(Rect, Acc),
    rand:bytes(erx_draw_image:bytes_per_line(R, Bits) * (Y1 - Y0)).

coord() -> pick([0, -1, 16#7fffffff, -16#80000000, rand:uniform(201) - 101]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% Valid image(6) codes for Rows rows of Line bytes, with back-references.
codes(_Line, 0) -> <<>>;
codes(Line, Rows) -> <<(row_codes(Line))/binary, (codes(Line, Rows - 1))/binary>>.

row_codes(0) -> <<>>;
row_codes(Left) when Left >= 3 ->
    case rand:uniform(2) of
        1 -> Count = rand:uniform(min(34, Left) - 2) + 2,
             Back = rand:uniform(1024) - 1,
             <<(((Count - 3) bsl 2) bor (Back bsr 8)), (Back band 255), (row_codes(Left - Count))/binary>>;
        2 -> literal(Left)
    end;
row_codes(Left) -> literal(Left).

literal(Left) ->
    Count = rand:uniform(min(128, Left)),
    <<(Count + 127), (rand:bytes(Count))/binary, (row_codes(Left - Count))/binary>>.

%% Writes Count cases to File, each a u32 length and its bytes: 8 depth
%% bytes, then messages; a third of them broken.
corpus(File, Seed, Count) ->
    rand:seed(exsss, {Seed, 17, 19}),
    Cases = [corpus_case() || _ <- lists:seq(1, Count)],
    ok = file:write_file(File, [[<<(byte_size(Case)):32/little>>, Case] || Case <- Cases]).

corpus_case() ->
    Depths = rand:bytes(?DEPTH_IDS),
    Depth = depth_fun(Depths),
    Messages = iolist_to_binary([corpus_message(Depth) || _ <- lists:seq(1, rand:uniform(5))]),
    case rand:uniform(3) of
        1 -> <<Depths/binary, (break(Messages))/binary>>;
        _ -> <<Depths/binary, Messages/binary>>
    end.

corpus_message(Depth) ->
    case rand:uniform(6) of
        1 -> Id = rand:uniform(8) - 1,
             {X0, Y0} = {rand:uniform(41) - 21, rand:uniform(41) - 21},
             R = {X0, Y0, X0 + rand:uniform(40), Y0 + rand:uniform(4)},
             Bits = case Depth(Id) of none -> 8; Known -> Known end,
             {_, _, _, Y1} = R,
             <<"Y", Id:32/little, << <<V:32/little-signed>> || V <- tuple_to_list(R) >>/binary,
               (codes(erx_draw_image:bytes_per_line(R, Bits), Y1 - Y0))/binary>>;
        _ -> element(2, random_message(Depth))
    end.

break(<<>>) -> rand:bytes(rand:uniform(16));
break(Bytes) ->
    Size = byte_size(Bytes),
    case rand:uniform(4) of
        1 -> flip(Bytes, rand:uniform(4));
        2 -> binary:part(Bytes, 0, rand:uniform(Size) - 1);
        3 -> Cut = rand:uniform(Size) - 1,
             <<(binary:part(Bytes, 0, Cut))/binary, (rand:bytes(rand:uniform(8)))/binary,
               (binary:part(Bytes, Cut, Size - Cut))/binary>>;
        4 -> rand:bytes(rand:uniform(64))
    end.

flip(Bytes, 0) -> Bytes;
flip(Bytes, N) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Bytes,
    flip(<<Before/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1))), After/binary>>, N - 1).

%% Decodes every case of Corpus as the C harness does and writes its lines to Out.
decode_corpus(Corpus, Out) ->
    {ok, Bytes} = file:read_file(Corpus),
    ok = file:write_file(Out, cases(Bytes)).

cases(<<Size:32/little, Case:Size/binary, Rest/binary>>) ->
    {Depths, Messages} = case Case of
                             <<D:?DEPTH_IDS/binary, M/binary>> -> {D, M};
                             _ -> {<<Case/binary, 0:((?DEPTH_IDS - byte_size(Case)) * 8)>>, <<>>}
                         end,
    [messages(Messages, byte_size(Messages), depth_fun(Depths)), "end\n" | cases(Rest)];
cases(<<>>) -> [].

messages(<<>>, _, _) -> [];
messages(Bytes, Size, Depth) ->
    At = Size - byte_size(Bytes),
    case erx_draw_codec:decode(Bytes, Depth) of
        {ok, Message, Rest} -> [line(Message, Size - byte_size(Rest)) | messages(Rest, Size, Depth)];
        {error, Errno, Offset} -> [io_lib:format("error ~s ~b~n", [Errno, At + Offset])]
    end.

line(Message, Next) ->
    [Name | Carried] = case Message of _ when is_atom(Message) -> [Message]; _ -> tuple_to_list(Message) end,
    {Name, Fields} = erx_draw_codec:layout(erx_draw_codec:letter(Name)),
    Shown = [show(Field, Value) || {Field, Value} <- lists:zip([F || F <- Fields, F =/= count], Carried)],
    [atom_to_list(Name), [[$\s, Text] || Text <- Shown], io_lib:format(" @~b~n", [Next])].

show(point, {X, Y}) -> io_lib:format("~b,~b", [X, Y]);
show(rect, {X0, Y0, X1, Y1}) -> io_lib:format("~b,~b,~b,~b", [X0, Y0, X1, Y1]);
show({points, _}, Points) -> lists:join(";", [io_lib:format("~b,~b", [X, Y]) || {X, Y} <- Points]);
show({indices, _}, []) -> "-";
show({indices, _}, Indices) -> lists:join(";", [integer_to_list(Index) || Index <- Indices]);
show({pixels, _, _}, Pixels) -> integer_to_list(byte_size(Pixels));
show({compressed, _, _}, _) -> "-";
show(_, Value) -> integer_to_list(Value).
