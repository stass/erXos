%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp6_wire_fuzz).
-moduledoc """
The fuzz target of erx_icmp6_wire:decode/2 (docs/design-network-stack.md,
"Codecs: fuzz targets"), run by tools/fuzz/erx_net_codec.rb. Each round
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
        {{ok, Decoded, Rest}, {accept, Decoded, Rest}} ->
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
eleven options read, `nd6_options` keeping the first of each single option
and every prefix, `nd6_ra_input` taking an MTU option of length 1 and prefix
options of length 4). It reads the message by absolute offsets, where the
decoder matches binaries, and says what the decoder must return: the record
and the rest of an accepted message (an error's second word, which is a
parameter problem's pointer, an echo's identifier and sequence number, and
every fixed field and option value of neighbour discovery), or `refuse`.
""".
-spec judge(binary()) -> {accept, #icmp6{}, binary()} | refuse.
judge(Message) when byte_size(Message) < 8 ->
    refuse;
judge(Message) when byte_size(Message) > 16#ffff ->
    refuse;
judge(Message) ->
    case erx_bytes:inet_csum(pseudo(byte_size(Message)), Message) of
        16#ffff -> fields(Message, binary:at(Message, 0), binary:at(Message, 1));
        _ -> refuse
    end.

%% The fields of a message whose sum is right, by its type and code.
fields(M, Type, Code) when Type < 128 ->
    Codes = #{1 => 4, 3 => 1, 4 => 2},
    case Code =< maps:get(Type, Codes, 255) andalso byte_size(M) >= 8 + 40 of
        true -> {accept, #icmp6{type = Type, code = Code, msg = {error, u32(M, 4)}}, from(M, 8)};
        false -> refuse
    end;
fields(M, Type, 0) when Type =:= 128; Type =:= 129 ->
    {accept, #icmp6{type = Type, code = 0, msg = {echo, u16(M, 4), u16(M, 6)}}, from(M, 8)};
fields(M, Type, 0) when Type >= 133, Type =< 137 ->
    OptionsAt = 4 + nd_fixed(Type),
    case OptionsAt =< byte_size(M) andalso options(M, OptionsAt, 0, []) of
        false -> refuse;
        refuse -> refuse;
        Read ->
            Opts = nd_opts(M, Read),
            Msg = case Type of
                      133 -> {rs, Opts};
                      134 -> {ra, binary:at(M, 4), binary:at(M, 5), u16(M, 6), u32(M, 8),
                              u32(M, 12), Opts};
                      135 -> {ns, binary:part(M, 8, 16), Opts};
                      136 -> {na, binary:at(M, 4) bsr 5, binary:part(M, 8, 16), Opts};
                      137 -> {redirect, binary:part(M, 8, 16), binary:part(M, 24, 16), Opts}
                  end,
            {accept, #icmp6{type = Type, code = 0, msg = Msg}, <<>>}
    end;
fields(_, Type, _) when Type =:= 128; Type =:= 129; Type >= 133, Type =< 137 ->
    refuse;
fields(M, Type, Code) ->
    {accept, #icmp6{type = Type, code = Code, msg = other}, from(M, 4)}.

%% The options from offset At, as {Type, Units, Offset} in wire order: each has a
%% nonzero length that keeps it inside the message, up to the eleventh; what follows
%% that is not read.
options(M, At, _, Read) when At =:= byte_size(M) ->
    lists:reverse(Read);
options(_, _, 11, Read) ->
    lists:reverse(Read);
options(M, At, Count, Read) when At + 2 =< byte_size(M) ->
    Units = binary:at(M, At + 1),
    case Units > 0 andalso At + Units * 8 =< byte_size(M) of
        true -> options(M, At + Units * 8, Count + 1, [{binary:at(M, At), Units, At} | Read]);
        false -> refuse
    end;
options(_, _, _, _) ->
    refuse.

%% What the options say: the first source and target link-layer address, redirected
%% header and nonce; the first MTU option, taken only if it is one unit long; every
%% prefix information option four units long.
nd_opts(M, Read) ->
    First = fun(Type) -> lists:keyfind(Type, 1, Read) end,
    Body = fun({_, Units, At}, Skip) -> binary:part(M, At + Skip, Units * 8 - Skip) end,
    Single = [{Key, Body(Option, Skip)}
              || {Key, Type, Skip} <- [{slla, 1, 2}, {tlla, 2, 2}, {redirected, 4, 8}, {nonce, 14, 2}],
                 Option <- [First(Type)], Option =/= false],
    Mtu = [{mtu, u32(M, At + 4)} || {5, 1, At} <- [First(5)]],
    Prefixes = [#{len => binary:at(M, At + 2), flags => binary:at(M, At + 3), valid => u32(M, At + 4),
                  preferred => u32(M, At + 8), prefix => binary:part(M, At + 16, 16)}
                || {3, 4, At} <- Read],
    maps:from_list(Single ++ Mtu ++ [{prefixes, Prefixes} || Prefixes =/= []]).

%% The bytes of a neighbour-discovery message's fixed part after its first four.
nd_fixed(Type) -> element(Type - 132, {4, 12, 20, 20, 36}).

u16(M, At) -> binary:decode_unsigned(binary:part(M, At, 2)).
u32(M, At) -> binary:decode_unsigned(binary:part(M, At, 4)).
from(M, At) -> binary:part(M, At, byte_size(M) - At).

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
    Fixed = nd_fixed(Type),
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
