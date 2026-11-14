%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random streams of input records through erx_input_codec:decode/1 (docs/design-abi.md,
%% "Input records"), the reader of what a driver in another domain writes. Whatever
%% arrives, the decoder returns without raising; it splits the bytes into 9-byte records
%% and a shorter rest, and for each record it keeps exactly what reference/1 keeps,
%% written from the bounds of record() in docs/design-display.md ("Input events") and
%% the layout of abi/formats/input.txt, and drops and counts the rest. Each record it
%% keeps encodes back to its own bytes. Random terms go through valid/1 and encode/1,
%% which agree with reference_valid/1. Most records are well formed, with one field
%% moved to the edge of its bound or past it, or a padding byte set, on the rest. The
%% seed comes from make check-fuzz.
-module(erx_input_codec_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(SIZE, 9).
-define(KEY_MAX, 16#2ff).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    {Kept, Dropped} = lists:foldl(fun(_, Counts) -> add(round_of(), Counts) end, {0, 0},
                                  lists:seq(1, ?ROUNDS)),
    lists:foreach(fun(_) -> term_round() end, lists:seq(1, ?ROUNDS)),
    case Kept > ?ROUNDS andalso Dropped > ?ROUNDS div 4 of
        true -> io:format("fuzz: ~p rounds ok, ~p kept, ~p dropped~n", [?ROUNDS, Kept, Dropped]);
        false -> error({too_few, Kept, Dropped})
    end.

add({Kept, Dropped}, {AllKept, AllDropped}) -> {AllKept + Kept, AllDropped + Dropped}.

round_of() ->
    Bytes = stream(),
    Said = try erx_input_codec:decode(Bytes)
           catch Class:Exception -> error({raised, Bytes, Class, Exception})
           end,
    Whole = byte_size(Bytes) div ?SIZE * ?SIZE,
    <<Records:Whole/binary, Rest/binary>> = Bytes,
    Expected = [{reference(Record), Record} || <<Record:?SIZE/binary>> <= Records],
    Kept = [Term || {{ok, Term}, _Record} <- Expected],
    Dropped = length(Expected) - length(Kept),
    case Said of
        {Kept, Dropped, Rest} -> ok;
        _ -> error({disagrees_with_reference, Bytes, Said})
    end,
    [Record = erx_input_codec:encode(Term) || {{ok, Term}, Record} <- Expected],
    {length(Kept), Dropped}.

%% A few records, with a partial one after them on some streams.
stream() ->
    Records = << <<(record_bytes())/binary>> || _ <- lists:seq(1, rand:uniform(4)) >>,
    case rand:uniform(6) of
        1 -> <<Records/binary, (rand:bytes(rand:uniform(?SIZE - 1)))/binary>>;
        _ -> Records
    end.

record_bytes() ->
    case rand:uniform(10) of
        1 -> rand:bytes(?SIZE);
        2 -> pad(<<(rand:uniform(256) - 1), (rand:bytes(rand:uniform(?SIZE - 1) - 1))/binary>>);
        _ -> well_formed(rand:uniform(6))
    end.

%% A record of the tag's kind, its fields at their edges or past them on some, and a
%% padding byte set on a few.
well_formed(1) -> pad(<<1, (rel()):32/little-signed, (rel()):32/little-signed>>);
well_formed(2) -> pad(<<2, (axis()):16/little, (axis()):16/little>>);
well_formed(3) -> pad(<<3, (pick([0, 9, 10, 255], 0, 9)), (pick([0, 2, 3, 255], 0, 2)),
                        (axis()):16/little, (axis()):16/little>>);
well_formed(4) -> pad(<<4, (pick([0, 1, 2, 255], 0, 1)),
                        (pick([0, ?KEY_MAX, ?KEY_MAX + 1, 16#ffff], 0, ?KEY_MAX)):16/little>>);
well_formed(5) -> pad(<<5, (rand:uniform(256) - 1)>>);
well_formed(6) -> pad(<<6>>).

rel() -> pick([-16#80000000, -1, 0, 16#7fffffff], -16#80000000, 16#7fffffff).
axis() -> pick([0, 65535], 0, 65535).

%% One of the edge values on some, any value from Low to High on the rest.
pick(Edges, Low, High) ->
    case rand:uniform(4) of
        1 -> lists:nth(rand:uniform(length(Edges)), Edges);
        _ -> Low + rand:uniform(High - Low + 1) - 1
    end.

%% Zero bytes to the record size, and a padding byte set on a few.
pad(Bytes) ->
    Padding = ?SIZE - byte_size(Bytes),
    case Padding > 0 andalso rand:uniform(20) =:= 1 of
        true -> <<Bytes/binary, 0:((Padding - 1) * 8), (rand:uniform(255))>>;
        false -> <<Bytes/binary, 0:(Padding * 8)>>
    end.

%% A record's bytes as the design and the declaration read them: the tag, the fields
%% little-endian, every padding byte zero, and every field within its bound.
reference(<<1, Dx:32/little-signed, Dy:32/little-signed>>) -> {ok, {pointer, rel, Dx, Dy}};
reference(<<2, X:16/little, Y:16/little, 0, 0, 0, 0>>) -> {ok, {pointer, abs, X, Y}};
reference(<<3, Slot, Phase, X:16/little, Y:16/little, 0, 0>>) when Slot =< 9, Phase =< 2 ->
    {ok, {touch, Slot, lists:nth(Phase + 1, [down, move, up]), X, Y}};
reference(<<4, Edge, Code:16/little, 0, 0, 0, 0, 0>>) when Edge =< 1, Code =< ?KEY_MAX ->
    {ok, {key, lists:nth(Edge + 1, [down, up]), Code}};
reference(<<5, Steps:8/signed, 0, 0, 0, 0, 0, 0, 0>>) -> {ok, {wheel, Steps}};
reference(<<6, 0, 0, 0, 0, 0, 0, 0, 0>>) -> {ok, release};
reference(_Bytes) -> drop.

%% A random term near record(), through valid/1 and encode/1.
term_round() ->
    Term = term(),
    Valid = reference_valid(Term),
    case {erx_input_codec:valid(Term), Valid} of
        {Valid, true} -> {[Term], 0, <<>>} = erx_input_codec:decode(erx_input_codec:encode(Term));
        {Valid, false} -> badarg = try erx_input_codec:encode(Term) catch error:badarg -> badarg end;
        Said -> error({valid_disagrees, Term, Said})
    end.

term() ->
    Int = fun() -> pick([-16#80000001, -16#80000000, -129, -128, -1, 0, 9, 10, 127, 128, 65535, 65536,
                         ?KEY_MAX, ?KEY_MAX + 1, 16#7fffffff, 16#80000000], -70000, 70000) end,
    Atom = fun() -> lists:nth(rand:uniform(7), [down, move, up, repeat, rel, abs, pointer]) end,
    case rand:uniform(8) of
        1 -> {pointer, rel, Int(), Int()};
        2 -> {pointer, abs, Int(), Int()};
        3 -> {touch, Int(), Atom(), Int(), Int()};
        4 -> {key, Atom(), Int()};
        5 -> {wheel, Int()};
        6 -> release;
        7 -> {pointer, Atom(), Int(), Int()};
        8 -> lists:nth(rand:uniform(4), [{release}, {wheel, 1.0}, {key, down}, {touch, 0, down, 0, 0, 0}])
    end.

%% The bounds of record() as docs/design-display.md writes them.
reference_valid({pointer, rel, Dx, Dy}) -> in(Dx, -16#80000000, 16#7fffffff) andalso in(Dy, -16#80000000, 16#7fffffff);
reference_valid({pointer, abs, X, Y}) -> in(X, 0, 65535) andalso in(Y, 0, 65535);
reference_valid({touch, Slot, Phase, X, Y}) ->
    in(Slot, 0, 9) andalso lists:member(Phase, [down, move, up]) andalso in(X, 0, 65535) andalso in(Y, 0, 65535);
reference_valid({key, Edge, Code}) -> lists:member(Edge, [down, up]) andalso in(Code, 0, ?KEY_MAX);
reference_valid({wheel, Steps}) -> in(Steps, -128, 127);
reference_valid(release) -> true;
reference_valid(_Term) -> false.

in(Value, Low, High) -> is_integer(Value) andalso Value >= Low andalso Value =< High.
