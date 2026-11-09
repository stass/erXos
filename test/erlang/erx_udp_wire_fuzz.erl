%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_udp_wire_fuzz).
-moduledoc """
The fuzz target of erx_udp_wire:decode/3 (docs/design-network-stack.md,
"Codecs: fuzz targets"), run by tools/fuzz/erx_net_codec.rb. Each round builds a UDP
datagram over IPv4 or IPv6 with a UDP length of an edge value, sometimes trailing bytes
past it, a zero port or a corrupted byte, and checks that the decoder never raises; that it
accepts exactly what `judge/1` accepts, which sums the pseudo-header written out whole with
the UDP length; that encoding an accepted datagram and decoding it again gives it back; and
that ports and length agree with pkt's (erx_net_pkt_oracle). Most datagrams carry the right
checksum, some none and the rest a wrong one. `run/1` prints `fuzz: N rounds ok, M
accepted`, or the first failure's tag and halts with status 1.
""".

-include("erx_udp_wire.hrl").

-export([judge/2, run/1]).

-define(ROUNDS, 20000).
-define(IPPROTO_UDP, 17).
-define(SRC4, <<192, 0, 2, 1>>).
-define(DST4, <<198, 51, 100, 7>>).
-define(SRC6, <<16#2001:16, 16#db8:16, 0:80, 1:16>>).
-define(DST6, <<16#2001:16, 16#db8:16, 0:80, 2:16>>).

-doc "Runs the target from the seed, the command line's one argument.".
-spec run([string()]) -> ok.
run([Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 16#11, 16#68}),
    try
        Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), check(datagram()) =:= accepted]),
        io:format("fuzz: ~b rounds ok, ~b accepted~n", [?ROUNDS, Accepted])
    catch
        throw:{fail, Tag, Detail} ->
            io:format("fuzz: ~p ~P~n", [Tag, Detail, 40]),
            halt(1)
    end.

check({Family, Bytes}) ->
    Result = try erx_udp_wire:decode(Family, pseudo(Family, byte_size(Bytes)), Bytes)
             catch Class:Reason:Stack -> fail(raised, {Family, Bytes, Class, Reason, Stack})
             end,
    case {Result, judge(Family, Bytes)} of
        {{ok, Udp, Payload}, accept} ->
            round_trip(Family, Udp, Payload),
            agree_with_pkt(Bytes, Udp, Payload),
            accepted;
        {{error, _}, refuse} ->
            refused;
        {_, Judged} ->
            fail(disagrees_with_reference, {Family, Bytes, Result, Judged})
    end.

round_trip(Family, Udp, Payload) ->
    Encoded = iolist_to_binary(erx_udp_wire:encode(Udp, Payload, pseudo(Family, 0))),
    case erx_udp_wire:decode(Family, pseudo(Family, byte_size(Encoded)), Encoded) of
        {ok, Udp, Payload} -> ok;
        Other -> fail(round_trip_differs, {Family, Udp, Payload, Encoded, Other})
    end.

agree_with_pkt(Bytes, #udp{sport = Sport, dport = Dport}, Payload) ->
    Ours = #{sport => Sport, dport => Dport, ulen => 8 + byte_size(Payload)},
    case erx_net_pkt_oracle:udp(Bytes) of
        {ok, Theirs, _} when map_get(sport, Theirs) =:= Sport, map_get(dport, Theirs) =:= Dport,
                             map_get(ulen, Theirs) =:= 8 + byte_size(Payload) -> ok;
        Other -> fail(disagrees_with_pkt, {Bytes, Ours, Other})
    end.

fail(Tag, Detail) -> throw({fail, Tag, Detail}).

-doc """
The reference judge, from RFC 768 with `udp_input`'s rules: an 8-byte header, a UDP length
from 8 to the bytes delivered (over IPv6 equal to them, and a nonzero checksum field, as
RFC 8200 requires), the checksum (when nonzero) over the pseudo-header written
out whole with the UDP length and the datagram cut at it, and a nonzero destination port.
""".
-spec judge(inet | inet6, binary()) -> accept | refuse.
judge(_, Bytes) when byte_size(Bytes) < 8; byte_size(Bytes) > 16#ffff ->
    refuse;
judge(inet6, <<_:32, Ulen:16, Sum:16, _/binary>> = Bytes) when Ulen =/= byte_size(Bytes); Sum =:= 0 ->
    refuse;
judge(Family, <<_:16, Dport:16, Ulen:16, Sum:16, _/binary>> = Bytes) ->
    Summed = Ulen >= 8 andalso Ulen =< byte_size(Bytes) andalso
        (Sum =:= 0 orelse full_sum(Family, Ulen, Bytes) =:= 16#ffff),
    case Summed andalso Dport =/= 0 of
        true -> accept;
        false -> refuse
    end.

%% The sum over the pseudo-header written out whole and the first Ulen bytes, in two calls,
%% since inet_csum/2 sums at most 64 KiB a call.
full_sum(Family, Ulen, Bytes) ->
    erx_bytes:inet_csum(erx_bytes:inet_csum(0, header(Family, Ulen)), binary:part(Bytes, 0, Ulen)).

header(inet, Ulen) -> <<?SRC4/binary, ?DST4/binary, 0, ?IPPROTO_UDP, Ulen:16>>;
header(inet6, Ulen) -> <<?SRC6/binary, ?DST6/binary, Ulen:32, 0:24, ?IPPROTO_UDP>>.

%% No IP packet delivers more than 65535 bytes, and the decoder refuses such a datagram before
%% it reads the sum.
pseudo(_, Len) when Len > 16#ffff -> 0;
pseudo(inet, Len) -> erx_ip4_wire:pseudo_sum(?SRC4, ?DST4, Len, ?IPPROTO_UDP);
pseudo(inet6, Len) -> erx_ip6_wire:pseudo_sum(?SRC6, ?DST6, Len, ?IPPROTO_UDP).

%% A datagram whose UDP length is an edge value against its payload, with trailing bytes
%% (an Ethernet frame's padding, or garbage) about a third of the time.
datagram() ->
    Family = oneof([inet, inet6]),
    Payload = bytes(payload_size()),
    Ulen = 8 + byte_size(Payload) + oneof([0, 0, 0, 0, 0, -1, 1, -8, -9]),
    Trailing = bytes(oneof([0, 0, 1, 4, rand:uniform(40)])),
    Dport = oneof([53, 5353, rand:uniform(16#ffff), 0]),
    Header = <<(rand:uniform(16#10000) - 1):16, Dport:16, (Ulen band 16#ffff):16>>,
    Datagram = seal(Family, Ulen, <<Header/binary, 0:16, Payload/binary>>),
    {Family, mutate(<<Datagram/binary, Trailing/binary>>)}.

%% Mostly short payloads; one in a hundred near the largest UDP length, so the high byte of
%% the length and a delivered length of 16#ffff and beyond are reached.
payload_size() ->
    case rand:uniform(100) of
        1 -> 16#ffff - 8 - oneof([0, 0, 1, 40, -1]);
        _ -> oneof([0, 1, 2, 7, 8, rand:uniform(200)])
    end.

%% The checksum over the first Ulen bytes when that is a sane length: right, absent or wrong.
seal(Family, Ulen, <<Head:6/binary, _:16, Payload/binary>> = Datagram) when Ulen >= 8, Ulen =< byte_size(Datagram) ->
    Right = bnot full_sum(Family, Ulen, Datagram) band 16#ffff,
    Sum = case rand:uniform(10) of
              1 -> 0;
              2 -> Right bxor rand:uniform(16#ffff);
              _ -> Right
          end,
    <<Head/binary, Sum:16, Payload/binary>>;
seal(_, _, Datagram) ->
    Datagram.

mutate(Bytes) ->
    case rand:uniform(20) of
        1 -> binary:part(Bytes, 0, rand:uniform(byte_size(Bytes)) - 1);
        2 ->
            At = rand:uniform(byte_size(Bytes)) - 1,
            <<Before:At/binary, Byte, After/binary>> = Bytes,
            <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>;
        _ -> Bytes
    end.

oneof(List) -> lists:nth(rand:uniform(length(List)), List).

bytes(N) -> rand:bytes(N).
