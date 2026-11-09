%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_proto_tests).
-moduledoc """
The Erlang side of test/host/erx_web_proto_test.rb and the generator of
tools/fuzz/erx_web_proto.rb. random/2 builds a random term of any web.txt
type from erx_web_proto:type/1, the table the codec itself reads, so every
case of every union is reachable without a list of them here. corpus/3
writes random messages as "MESSAGE HEX" lines; reencode/2 decodes such
lines and writes "ok HEX" with the bytes the encoder writes back, or
"refused REASON".
""".
-export([corpus/3, reencode/2, random/2, random_message/1]).

%% Lists and sized values stay short so a message fits its bound, but reach
%% their bound now and then.
-define(SHORT, 4).
-define(AT_BOUND, 24).

-spec corpus(file:filename(), pos_integer(), pos_integer()) -> ok.
corpus(Path, Seed, Count) ->
    rand:seed(exsss, Seed),
    Lines = [message_line() || _ <- lists:seq(1, Count)],
    ok = file:write_file(Path, Lines).

message_line() ->
    {Message, Bytes} = random_message(erx_web_proto:messages()),
    [atom_to_binary(Message), $\s, binary:encode_hex(Bytes), $\n].

%% A random message of one of MESSAGES that the encoder accepts.
-spec random_message([atom()]) -> {atom(), binary()}.
random_message(Messages) ->
    Message = lists:nth(rand:uniform(length(Messages)), Messages),
    case erx_web_proto:encode(Message, random(Message, 1)) of
        {ok, Bytes} -> {Message, Bytes};
        {error, {too_long, _}} -> random_message(Messages)
    end.

-spec reencode(file:filename(), file:filename()) -> ok.
reencode(In, Out) ->
    {ok, Text} = file:read_file(In),
    Lines = [reencode_line(Line) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])],
    ok = file:write_file(Out, Lines).

reencode_line(Line) ->
    [Name, Hex] = binary:split(Line, <<" ">>),
    [Message] = [Known || Known <- erx_web_proto:messages(), atom_to_binary(Known) =:= Name],
    case erx_web_proto:decode(Message, binary:decode_hex(Hex)) of
        {ok, Term} ->
            {ok, Bytes} = erx_web_proto:encode(Message, Term),
            [<<"ok ">>, binary:encode_hex(Bytes), $\n];
        {error, {Reason, Type}} ->
            io_lib:format("refused ~s ~s~n", [Reason, Type])
    end.

%% A random term of TYPE at LEVEL of the depth union.
-spec random(atom(), pos_integer()) -> term().
random(Type, Level) ->
    random_form(erx_web_proto:type(Type), Level).

random_form(boolean, _Level) ->
    rand:uniform(2) =:= 1;
random_form({integer, _Bits, Min, Max}, _Level) ->
    case rand:uniform(4) of
        1 -> Min;
        2 -> Max;
        _ -> Min + rand:uniform(Max - Min + 1) - 1
    end;
random_form({bytes, Max, exact}, _Level) ->
    rand:bytes(Max);
random_form({bytes, Max, upto}, _Level) ->
    rand:bytes(length_upto(Max));
random_form({text, Max}, _Level) ->
    rand:bytes(length_upto(Max));
random_form({digits, Max}, _Level) ->
    %% A 128-bit integer's text is at most 40 bytes, the protocol's bound.
    40 = Max,
    integer_to_binary(rand:uniform(1 bsl 128) - (1 bsl 127));
random_form(stopgap, _Level) ->
    Names = erx_web_proto:stopgaps(),
    lists:nth(rand:uniform(length(Names)), Names);
random_form({ui_record, Max}, _Level) ->
    Body = rand:bytes(max(1, length_upto(Max))),
    <<(byte_size(Body)):32/little, Body/binary>>;
random_form({list, Element, Max}, Level) ->
    [random(Element, Level) || _ <- lists:seq(1, count_upto(Max))];
random_form({tuple, Fields}, Level) ->
    list_to_tuple([random(Field, Level) || Field <- Fields]);
random_form({map, Fields}, Level) ->
    maps:from_list([{Key, random(Field, Level)} || {Key, Field} <- Fields]);
random_form({union, Depth, Cases}, Level) ->
    %% A recursive case only below the depth, and seldom, so terms stay small.
    Open = [Case || {_, _, _, Recursive} = Case <- Cases,
                    not Recursive orelse (Level < Depth andalso rand:uniform(3) =:= 1)],
    {_Tag, Name, Fields, Recursive} = lists:nth(rand:uniform(length(Open)), Open),
    Inner = case Recursive of true -> Level + 1; false -> Level end,
    case Fields of
        [] -> Name;
        _ -> list_to_tuple([Name | [random(Field, Inner) || Field <- Fields]])
    end.

length_upto(Max) ->
    case rand:uniform(?AT_BOUND) of
        1 when Max =< 4096 -> Max;
        _ -> rand:uniform(min(Max, ?SHORT) + 1) - 1
    end.

count_upto(Max) ->
    rand:uniform(min(Max, ?SHORT) + 1) - 1.
