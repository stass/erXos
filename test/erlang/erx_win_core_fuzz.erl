%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random reads through erx_win_core's readers of what a client reads back from a display
%% (docs/design-display.md, "Verification and testing", Windows): ctl/1, wctl/1, mouse/1
%% and kbd/1. Whatever arrives, each returns {ok, _} or {error, eio} and never raises, and
%% what it says agrees with a reference of the same format written as one regular
%% expression with the ranges checked apart, which shares no code with the readers. The
%% inputs are random bytes, valid records, records cut or padded by a byte, and valid
%% records with a byte changed. The seed comes from make check-fuzz.

-module(erx_win_core_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(FIELD, "( {0,10}-?[0-9]{1,11}) ").
-define(MOUSE, "\\A([mr])" ?FIELD ?FIELD ?FIELD ?FIELD "\\z").
-define(WCTL, "\\A" ?FIELD ?FIELD ?FIELD ?FIELD "( {0,10}[a-z]{1,11}) ( {0,10}[a-z]{1,11}) \\z").
-define(MIN, -16#80000000).
-define(MAX, 16#7fffffff).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    {ok, Mouse} = re:compile(?MOUSE),
    {ok, Wctl} = re:compile(?WCTL),
    References = #{ctl => fun ctl_reference/1, wctl => fun(B) -> wctl_reference(B, Wctl) end,
                   mouse => fun(B) -> mouse_reference(B, Mouse) end, kbd => fun kbd_reference/1},
    lists:foreach(fun(_) ->
                          [round_of(Reader, Input, References)
                           || Reader <- [ctl, wctl, mouse, kbd],
                              Input <- [random_bytes(), valid(Reader), cut(valid(Reader)),
                                        padded(valid(Reader)), mutated(valid(Reader))]]
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~b rounds ok~n", [?ROUNDS]).

round_of(Reader, Input, References) ->
    Got = try erx_win_core:Reader(Input)
          catch Class:Reason -> erlang:error({raised, Reader, Input, Class, Reason})
          end,
    Expected = (maps:get(Reader, References))(Input),
    case agrees(Reader, Got, Expected) of
        true -> ok;
        false -> erlang:error({disagrees_with_reference, Reader, Input, Got, Expected})
    end.

agrees(_, {error, eio}, error) -> true;
agrees(ctl, {ok, #{text := Text}}, {ok, Text}) -> true;
agrees(_, {ok, Value}, {ok, Value}) -> true;
agrees(_, _, _) -> false.

%% References -----------------------------------------------------------------

ctl_reference(Bytes) ->
    case re:run(Bytes, "\\A((?:[rgbkamx][1-8]){1,4})\\n\\z", [{capture, all_but_first, binary}]) of
        {match, [Text]} ->
            Depth = lists:sum([Bits - $0 || <<_, Bits>> <= Text]),
            case Depth rem 8 =:= 0 orelse 8 rem Depth =:= 0 of
                true -> {ok, Text};
                false -> error
            end;
        nomatch ->
            error
    end.

mouse_reference(Bytes, Mouse) ->
    case re:run(Bytes, Mouse, [{capture, all_but_first, binary}]) of
{match, [Kind | Fields]} when length(Fields) =:= 4 ->
[X, Y, B, M] = [binary_to_integer(string:trim(F)) || F <- Fields],
Unsigned = [binary:match(F, <<"-">>) =:= nomatch || F <- lists:nthtail(2, Fields)],
case lists:all(fun eleven/1, Fields) andalso Unsigned =:= [true, true]
     andalso lists:all(fun in_coord/1, [X, Y]) andalso lists:all(fun in_count/1, [B, M]) of
                true -> {ok, {case Kind of <<"m">> -> mouse; <<"r">> -> resized end, X, Y, B, M}};
                false -> error
            end;
        _ ->
            error
    end.

wctl_reference(Bytes, Wctl) ->
    case re:run(Bytes, Wctl, [{capture, all_but_first, binary}]) of
        {match, Fields} ->
            [X0, Y0, X1, Y1] = [binary_to_integer(string:trim(F)) || F <- lists:sublist(Fields, 4)],
            [Focus, State] = [string:trim(F) || F <- lists:nthtail(4, Fields)],
Rect = lists:all(fun eleven/1, Fields)
    andalso lists:all(fun in_coord/1, [X0, Y0, X1, Y1]) andalso X0 =< X1 andalso Y0 =< Y1
                andalso X1 - X0 =< 16384 andalso Y1 - Y0 =< 16384,
            case {Rect, Focus, State} of
                {true, F, S} when (F =:= <<"current">> orelse F =:= <<"notcurrent">>),
                                  (S =:= <<"visible">> orelse S =:= <<"hidden">>) ->
                    {ok, #{rect => {X0, Y0, X1, Y1}, current => F =:= <<"current">>,
                           state => case S of <<"visible">> -> shown; <<"hidden">> -> hidden end}};
                _ ->
                    error
            end;
        _ ->
            error
    end.

kbd_reference(<<Kind, Rest/binary>>) when Kind =:= $c; Kind =:= $k; Kind =:= $K ->
    case binary:split(Rest, <<0>>) of
        [Text, <<>>] ->
            case unicode:characters_to_list(Text) of
                Runes when is_list(Runes) ->
                    case {Kind, Runes} of
                        {$c, [Rune]} -> {ok, {typed, Rune}};
                        {$c, _} -> error;
                        {$k, _} -> {ok, {down, Runes}};
                        {$K, _} -> {ok, {up, Runes}}
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end;
kbd_reference(_) ->
    error.

%% Each field is right-aligned in exactly 11 bytes, which the expressions do not count.
eleven(Field) -> byte_size(Field) =:= 11.

in_coord(N) -> N >= ?MIN andalso N =< ?MAX.
in_count(N) -> N >= 0 andalso N =< ?MAX.

%% Inputs ---------------------------------------------------------------------

random_bytes() ->
    rand:bytes(rand:uniform(80) - 1).

valid(ctl) ->
    Channels = [<<(pick("rgbkamx")), (pick("12345678"))>> || _ <- lists:seq(1, rand:uniform(4))],
    <<(iolist_to_binary(Channels))/binary, "\n">>;
valid(wctl) ->
    [X0, Y0] = [number() || _ <- [1, 2]],
    Rect = [X0, Y0, X0 + rand:uniform(16400) - 9, Y0 + rand:uniform(16400) - 9],
    Words = [pick([<<"current">>, <<"notcurrent">>, <<"visible">>, <<"hidden">>]) || _ <- [1, 2]],
    iolist_to_binary([field(integer_to_binary(N)) || N <- Rect] ++ [field(W) || W <- Words]);
valid(mouse) ->
    Fields = [number(), number(), rand:uniform(8) - 2, number()],
    iolist_to_binary([pick("mr") | [field(integer_to_binary(N)) || N <- Fields]]);
valid(kbd) ->
    Runes = [pick([$a, 0, 16#e9, 16#4e16, 16#1f600, 16#10ffff]) || _ <- lists:seq(1, rand:uniform(3) - 1)],
    <<(pick("ckK")), (unicode:characters_to_binary(Runes))/binary, 0>>.

%% A number near the edges of a coordinate or anywhere between.
number() ->
    pick([?MIN, ?MIN - 1, ?MAX, ?MAX + 1, 0, -1, rand:uniform(4000) - 2000]).

field(Text) when byte_size(Text) =< 11 ->
    <<(binary:copy(<<" ">>, 11 - byte_size(Text)))/binary, Text/binary, " ">>;
field(Text) ->
    <<Text/binary, " ">>.

cut(<<>>) -> <<>>;
cut(Bytes) -> binary:part(Bytes, 0, byte_size(Bytes) - 1).

padded(Bytes) -> <<Bytes/binary, (pick(" \n0"))>>.

mutated(<<>>) -> <<>>;
mutated(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Front:At/binary, _, Back/binary>> = Bytes,
    <<Front/binary, (pick([$\s, $-, $0, $9, $a, $\n, 0, 16#ff])), Back/binary>>.

pick(List) when is_list(List) -> lists:nth(rand:uniform(length(List)), List).
