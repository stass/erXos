%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp4_wire_fuzz).
-moduledoc """
The fuzz target of erx_icmp4_wire:decode/1 (docs/design-network-stack.md,
"Codecs: fuzz targets"), run by tools/fuzz/erx_net_codec.rb. Each round builds an ICMPv4
message of a known or random type, an error quoting an IP header of an edge length and
sometimes a corrupted byte, and checks that the decoder never raises; that it accepts
exactly what `judge/1` accepts; that encoding an accepted message and decoding it again
gives it back; and that type, code and second word agree with pkt's (erx_net_pkt_oracle)
where pkt decodes them. Most messages carry the right checksum and the rest a wrong one.
`run/1` prints `fuzz: N rounds ok, M accepted`, or the first failure's tag and halts with
status 1.
""".

-include("erx_icmp4_wire.hrl").

-export([judge/1, run/1]).

-define(ROUNDS, 20000).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#1c, 16#4d}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(message()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check(Message) ->
    Result = try erx_icmp4_wire:decode(Message)
             catch Class:Reason:Stack -> fail(raised, {Message, Class, Reason, Stack})
             end,
    case {Result, judge(Message)} of
        {{ok, Decoded, Rest}, accept} ->
            round_trip(Decoded, Rest),
            agree_with_pkt(Message, Decoded),
            accepted;
        {{error, _}, refuse} ->
            refused;
        {_, Judged} ->
            fail(disagrees_with_reference, {Message, Result, Judged})
    end.

round_trip(Decoded, Rest) ->
    Encoded = iolist_to_binary(erx_icmp4_wire:encode(Decoded, Rest)),
    case erx_icmp4_wire:decode(Encoded) of
        {ok, Decoded, Rest} -> ok;
        Other -> fail(round_trip_differs, {Decoded, Rest, Encoded, Other})
    end.

agree_with_pkt(Message, #icmp4{type = Type, code = Code, msg = Msg}) ->
    case erx_net_pkt_oracle:icmp4(Message) of
        {error, rejected} ->
            ok;
        {ok, Theirs, _} ->
            Ours = maps:merge(#{type => Type, code => Code}, word(Type, Msg)),
            case maps:with(maps:keys(Ours), Theirs) of
                Ours -> ok;
                _ -> fail(disagrees_with_pkt, {Message, Ours, Theirs})
            end
    end.

word(_, {echo, Id, Seq}) -> #{id => Id, seq => Seq};
word(_, {redirect, Gateway}) -> #{gateway => Gateway};
word(?ICMP_PARAMPROB, {error, Word}) -> #{pointer => Word bsr 24};
word(_, _) -> #{}.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 792's layout with the limits `icmp_input` adopts (8-byte
header, the codes it accepts for each error type, an error quoting an IP header of at least
20 bytes and 8 more, a timestamp request of 20 bytes): accept or refuse.
""".
-spec judge(binary()) -> accept | refuse.
judge(Message) when byte_size(Message) < 8 ->
    refuse;
judge(Message) ->
    case erx_bytes:inet_csum(0, Message) of
        16#ffff -> fields(Message);
        _ -> refuse
    end.

fields(<<Type, Code, _:48, Quote/binary>>) when Type =:= 3; Type =:= 5; Type =:= 11; Type =:= 12 ->
    MaxCode = maps:get(Type, #{3 => 15, 5 => 3, 11 => 1, 12 => 2}),
    case Quote of
        <<_:4, Hl:4, _/binary>> when Code =< MaxCode, Hl >= 5, byte_size(Quote) >= Hl * 4 + 8 -> accept;
        _ -> refuse
    end;
fields(<<13, _/binary>> = Message) when byte_size(Message) < 20 ->
    refuse;
fields(_) ->
    accept.

%% A random message of a weighted type with a body of an edge length.
message() ->
    Type = oneof([0, 8, 8, 3, 3, 5, 11, 12, 13, 13, 4, 14, 17, rand:uniform(256) - 1]),
    Code = oneof([0, 0, 0, 0, 1, 2, 3, 4, 15, 16, rand:uniform(256) - 1]),
    seal(mutate(<<Type, Code, 0:16, (body(Type))/binary>>)).

body(Type) when Type =:= 3; Type =:= 5; Type =:= 11; Type =:= 12 ->
    Hl = oneof([5, 5, 5, 4, 6, 15, rand:uniform(16) - 1]),
    Quoted = Hl * 4 + oneof([8, 8, 7, 0, 20]),
    <<(rand:uniform(16#ffffffff)):32, 4:4, Hl:4, (bytes(max(Quoted - 1, 0)))/binary>>;
body(13) ->
    bytes(oneof([16, 16, 15, 11, 20]));
body(_) ->
    bytes(oneof([0, 3, 4, 5, rand:uniform(64)])).

mutate(Message) ->
    case rand:uniform(20) of
        1 -> binary:part(Message, 0, rand:uniform(byte_size(Message)) - 1);
        N when N =< 4 ->
            At = rand:uniform(byte_size(Message)) - 1,
            <<Before:At/binary, Byte, After/binary>> = Message,
            <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>;
        _ -> Message
    end.

%% Most messages get the right checksum, so the fields behind it are reached; the rest a
%% wrong one, which decoder and judge must both refuse.
seal(<<Type, Code, _:16, Body/binary>>) ->
    Right = bnot erx_bytes:inet_csum(0, <<Type, Code, 0:16, Body/binary>>) band 16#ffff,
    Sum = case rand:uniform(10) of 1 -> Right bxor rand:uniform(16#ffff); _ -> Right end,
    <<Type, Code, Sum:16, Body/binary>>;
seal(Message) ->
    Message.

oneof(List) -> lists:nth(rand:uniform(length(List)), List).

bytes(N) -> rand:bytes(N).
