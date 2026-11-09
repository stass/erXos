%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp6_wire_fuzz).
-moduledoc """
The fuzz target of erx_icmp6_wire:decode/2 (docs/design-network-stack.md,
"Codecs: fuzz targets"), run by tools/fuzz/erx_icmp6_wire.rb. Each round
builds an ICMPv6 message of a known or random type, with fixed parts and
neighbour-discovery options of edge lengths and sometimes a corrupted byte,
and checks that the decoder never raises; that it accepts exactly what
`judge/1` accepts; that encoding an accepted message and decoding it again
gives it back; and that type, code and second word agree with pkt's
(erx_net_pkt_oracle) where pkt decodes them. Most messages carry the right checksum
over the pseudo-header and the rest a wrong one. `run/1` prints `fuzz: N rounds ok`, or the first failure's tag
and halts with status 1.
""".

-include("erx_ip6.hrl").

-export([judge/1, run/1]).

-define(ROUNDS, 20000).
-define(SRC, <<16#fe80:16, 0:48, 1:64>>).
-define(DST, <<16#ff02:16, 0:96, 1:16>>).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#2c, 16#71}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(message()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check(Message) ->
    Result = try erx_icmp6_wire:decode(pseudo(byte_size(Message)), Message)
             catch Class:Reason:Stack -> fail(decoder_raised, {Message, Class, Reason, Stack})
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
    Encoded = iolist_to_binary(erx_icmp6_wire:encode(Decoded, Rest, {?SRC, ?DST})),
    case erx_icmp6_wire:decode(pseudo(byte_size(Encoded)), Encoded) of
        {ok, Decoded, Rest} -> ok;
        Other -> fail(round_trip_differs, {Decoded, Rest, Encoded, Other})
    end.

%% pkt decodes the second word only for some types; compare what it gives.
agree_with_pkt(Message, #icmp6{type = Type, code = Code, msg = Msg}) ->
    case erx_net_pkt_oracle:icmp6(Message) of
        {error, rejected} ->
            ok;
        {ok, Theirs, _} ->
            Ours = maps:merge(#{type => Type, code => pkt_code(Type, Code)}, word(Type, Msg)),
            case maps:with(maps:keys(Ours), Theirs) of
                Ours -> ok;
                _ -> fail(disagrees_with_pkt, {Message, Ours, Theirs})
            end
    end.

%% pkt reads an MLDv2 report's second byte as reserved and gives code 0.
pkt_code(143, _) -> 0;
pkt_code(_, Code) -> Code.

word(_, {echo, Id, Seq}) -> #{id => Id, seq => Seq};
word(?ICMP6_PACKET_TOO_BIG, {error, Mtu}) -> #{mtu => Mtu};
word(?ICMP6_PARAM_PROB, {error, Pointer}) -> #{pointer => Pointer};
word(_, _) -> #{}.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 4443's and RFC 4861's rules with the limits
the design adopts from FreeBSD (8-byte header, the codes FreeBSD accepts,
eleven options read): accept or refuse.
""".
-spec judge(binary()) -> accept | refuse.
judge(Message) when byte_size(Message) < 8 ->
    refuse;
judge(Message) when byte_size(Message) > 16#ffff ->
    refuse;
judge(Message) ->
    case erx_bytes:inet_csum(pseudo(byte_size(Message)), Message) of
        16#ffff -> fields(Message);
        _ -> refuse
    end.

%% The fields of a message whose sum is right.
fields(<<Type, Code, _:16, Body/binary>>) when Type < 128 ->
    Codes = #{1 => 4, 3 => 1, 4 => 2},
    case Code =< maps:get(Type, Codes, 255) andalso byte_size(Body) >= 4 + 40 of
        true -> accept;
        false -> refuse
    end;
fields(<<Type, Code, _:16, Body/binary>>) when Type =:= 128; Type =:= 129 ->
    case Code of 0 when byte_size(Body) >= 4 -> accept; _ -> refuse end;
fields(<<Type, Code, _:16, Body/binary>>) when Type >= 133, Type =< 137 ->
    Fixed = element(Type - 132, {4, 12, 20, 20, 36}),
    case {Code, Body} of
        {0, <<_:Fixed/binary, Options/binary>>} -> options(Options, 0);
        _ -> refuse
    end;
fields(_) ->
    accept.

%% Every option has a nonzero length that keeps it inside the message, up
%% to the eleventh; what follows that is not read.
options(<<>>, _) -> accept;
options(_, 11) -> accept;
options(<<_, Len, Rest/binary>>, Read) when Len > 0, Len * 8 - 2 =< byte_size(Rest) ->
    options(binary:part(Rest, Len * 8 - 2, byte_size(Rest) - (Len * 8 - 2)), Read + 1);
options(_, _) -> refuse.

%% A random message of a weighted type with a fixed part of an edge length.
message() ->
    Type = oneof([1, 2, 3, 4, 128, 129, 133, 134, 135, 135, 136, 137, 130, 143,
                  rand:uniform(256) - 1]),
    Code = oneof([0, 0, 0, 0, 0, 1, 2, 3, 4, 5, rand:uniform(256) - 1]),
    Body = body(Type),
    seal(mutate(<<Type, Code, 0:16, Body/binary>>)).

body(Type) when Type < 128 ->
    bytes(4 + oneof([39, 40, 41, 48, rand:uniform(100)]));
body(Type) when Type >= 133, Type =< 137 ->
    Fixed = element(Type - 132, {4, 12, 20, 20, 36}),
    iolist_to_binary([bytes(Fixed + oneof([0, 0, 0, 0, 0, -1, 1])),
                      [option() || _ <- lists:seq(1, oneof([0, 1, 2, 3, 5, 12]))]]);
body(_) ->
    bytes(oneof([0, 3, 4, 5, rand:uniform(40)])).

option() ->
    case rand:uniform(10) of
        1 -> <<1, 1, (bytes(6))/binary>>;
        2 -> <<2, (oneof([1, 2])), (bytes(6))/binary, 0:(oneof([0, 0, 8]) * 8)>>;
        3 -> Len = oneof([1, 1, 2]), <<5, Len, 0:16, (rand:uniform(9000)):32, 0:((Len - 1) * 64)>>;
        4 -> Len = oneof([4, 4, 4, 3, 5]), <<3, Len, (bytes(Len * 8 - 2))/binary>>;
        5 -> Units = oneof([1, 2, 6]), <<4, Units, (bytes(Units * 8 - 2))/binary>>;
        6 -> <<14, 1, (bytes(6))/binary>>;
        7 -> <<(rand:uniform(256) - 1), 0, (bytes(6))/binary>>;     % length 0
        8 -> <<(rand:uniform(256) - 1), 3, (bytes(6))/binary>>;     % past the end
        _ -> Units = oneof([1, 2]), <<(oneof([24, 25, 31, 99])), Units, (bytes(Units * 8 - 2))/binary>>
    end.

mutate(Message) ->
    case rand:uniform(20) of
        1 -> binary:part(Message, 0, rand:uniform(byte_size(Message)) - 1);
        N when N =< 4 ->
            At = rand:uniform(byte_size(Message)) - 1,
            <<Before:At/binary, Byte, After/binary>> = Message,
            <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>;
        _ -> Message
    end.

%% Most messages get the right checksum, so the fields behind it are reached;
%% the rest a wrong one, which decoder and judge must both refuse.
seal(<<Type, Code, _:16, Body/binary>> = Message) ->
    Right = bnot erx_bytes:inet_csum(pseudo(byte_size(Message)), <<Type, Code, 0:16, Body/binary>>) band 16#ffff,
    Sum = case rand:uniform(10) of 1 -> Right bxor rand:uniform(16#ffff); _ -> Right end,
    <<Type, Code, Sum:16, Body/binary>>;
seal(Message) ->
    Message.

pseudo(Len) -> erx_ip6_wire:pseudo_sum(?SRC, ?DST, Len, ?IPPROTO_ICMPV6).

oneof(List) -> lists:nth(rand:uniform(length(List)), List).

bytes(N) -> rand:bytes(N).
