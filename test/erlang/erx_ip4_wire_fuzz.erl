%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random IPv4 packets with options through erx_ip4_wire:decode/1 (docs/design-network-stack.md,
%% "Codecs: fuzz targets"). Whatever arrives, the decoder returns without raising and refuses
%% only for one of its reasons; it accepts exactly the packets reference/1 accepts, written from
%% RFC 791 and RFC 1071 alone, with its own checksum; on what it accepts, the payload is the
%% bytes up to the total length, encoding the header and decoding it with that payload gives
%% the same record, and pkt (erx_net_pkt_oracle) reads the same fields. Most packets are well
%% formed with a correct checksum, so the checks behind the checksum are reached; the rest
%% move one field to its edge, carry a wrong checksum, or are cut short. The seed comes from
%% make check-fuzz.
-module(erx_ip4_wire_fuzz).
-export([run/1]).

-include("erx_ip4_wire.hrl").

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 4).
-define(REASONS, [too_short, bad_vers, bad_hlen, bad_sum, bad_len]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    Packet = packet(),
    Said = try erx_ip4_wire:decode(Packet)
           catch Class:Exception -> error({raised, Packet, Class, Exception})
           end,
    case {Said, reference(Packet)} of
        {{ok, #ip4{} = Ip4, Payload}, {accept, Payload}} ->
            {ok, Ip4, Payload} = erx_ip4_wire:decode(<<(erx_ip4_wire:encode(Ip4))/binary, Payload/binary>>),
            agrees_with_pkt(Packet, Ip4, Payload),
            accepted;
        {{error, {bad_options, Pointer}}, reject} when Pointer > 20, Pointer =< 60 ->
            refused;
        {{error, Reason}, reject} ->
            true = lists:member(Reason, ?REASONS),
            refused;
        _ ->
            error({disagrees_with_reference, Packet, Said})
    end.

%% A header of random fields and options, its length fields usually true, its checksum
%% usually correct, with up to 64 bytes of payload and a few of trailer.
packet() ->
    Options = options(),
    Hlen = 20 + byte_size(Options),
    PayloadLength = rand:uniform(65) - 1,
    Len = case rand:uniform(8) of
              1 -> rand:uniform(Hlen + 1) - 1;
              2 -> Hlen + PayloadLength + 1;
              3 -> rand:uniform(65536) - 1;
              _ -> Hlen + PayloadLength
          end,
    Version = edge(4, 16),
    Hl = edge(Hlen div 4, 16),
    Zero = <<Version:4, Hl:4, (rand:uniform(256) - 1), Len:16, (rand:bytes(4))/binary,
             (rand:uniform(256) - 1), (rand:uniform(256) - 1), 0:16, (rand:bytes(8))/binary,
             Options/binary>>,
    Sum = case rand:uniform(8) of
              1 -> rand:uniform(65536) - 1;
              _ -> bnot ones_sum(Zero) band 16#FFFF
          end,
    <<Head:10/binary, 0:16, Tail/binary>> = Zero,
    Whole = <<Head/binary, Sum:16, Tail/binary, (rand:bytes(PayloadLength + rand:uniform(4) - 1))/binary>>,
    case rand:uniform(10) of
        1 -> binary:part(Whole, 0, rand:uniform(byte_size(Whole) + 1) - 1);
        2 -> binary:part(Whole, 0, min(byte_size(Whole), max(0, Len - 1)));
        _ -> Whole
    end.

%% Usual on most packets, any value below Limit on the rest.
edge(Usual, Limit) ->
    case rand:uniform(16) of
        1 -> rand:uniform(Limit) - 1;
        _ -> Usual
    end.

%% Options padded to a multiple of four bytes, at most 40: none on half the packets, well
%% formed on most of the rest, and on a few a length below 2 or past the end.
options() ->
    case rand:uniform(2) of
        1 -> <<>>;
        2 -> pad(iolist_to_binary([option() || _ <- lists:seq(1, rand:uniform(4))]))
    end.

option() ->
    case rand:uniform(10) of
        1 -> <<?IPOPT_NOP>>;
        2 -> <<?IPOPT_EOL>>;
        3 -> <<(rand:uniform(256) - 1), (rand:uniform(3) - 1)>>;
        4 -> <<(rand:uniform(256) - 1), (rand:uniform(20) + 10)>>;
        _ -> Data = rand:bytes(rand:uniform(8) - 1),
             <<(lists:nth(rand:uniform(4), [?IPOPT_RR, ?IPOPT_TS, ?IPOPT_LSRR, 200])), (byte_size(Data) + 2), Data/binary>>
    end.

pad(Options) when byte_size(Options) > 40 -> binary:part(Options, 0, 40);
pad(Options) when byte_size(Options) rem 4 =:= 0 -> Options;
pad(Options) -> pad(<<Options/binary, ?IPOPT_EOL>>).

%% RFC 791's header: version 4, an IHL of at least 5 words within the packet, a total length
%% from the header length to the packet's end; RFC 1071's checksum over the header; and each
%% option either a single byte (0, end of list, or 1, no operation) or a type, a length of at
%% least 2 that stays within the header, and data. The payload is the bytes up to the total
%% length.
reference(<<4:4, Ihl:4, _:8, Total:16, _/binary>> = Packet)
  when Ihl >= 5, Ihl * 4 =< byte_size(Packet), Total >= Ihl * 4, Total =< byte_size(Packet) ->
    HeaderLength = Ihl * 4,
    <<Header:HeaderLength/binary, _/binary>> = Packet,
    <<_:20/binary, Options/binary>> = Header,
    case ones_sum(Header) =:= 16#FFFF andalso options_valid(Options) of
        true -> {accept, binary:part(Packet, HeaderLength, Total - HeaderLength)};
        false -> reject
    end;
reference(_Packet) ->
    reject.

options_valid(<<>>) -> true;
options_valid(<<0, _/binary>>) -> true;
options_valid(<<1, Rest/binary>>) -> options_valid(Rest);
options_valid(<<_, Length, Rest/binary>>) when Length >= 2, Length - 2 =< byte_size(Rest) ->
    options_valid(binary:part(Rest, Length - 2, byte_size(Rest) - (Length - 2)));
options_valid(_) -> false.

%% The ones' complement sum of 16-bit words, folded: 16#FFFF over a header whose checksum
%% is right.
ones_sum(Bytes) -> fold(lists:sum([Word || <<Word:16>> <= Bytes])).

fold(Sum) when Sum > 16#FFFF -> fold((Sum band 16#FFFF) + (Sum bsr 16));
fold(Sum) -> Sum.

%% pkt refuses a header with the reserved flag set, which FreeBSD and the decoder accept.
agrees_with_pkt(Packet, #ip4{rf = 1}, _Payload) ->
    case erx_net_pkt_oracle:ipv4(Packet) of
        {error, rejected} -> ok;
        Other -> error({disagrees_with_pkt, Packet, Other})
    end;
agrees_with_pkt(Packet, #ip4{tos = Tos, len = Len, id = Id, df = Df, mf = Mf, off = Off, ttl = Ttl, p = P,
                             src = Src, dst = Dst, options = Options}, Payload) ->
    Hl = 5 + byte_size(Options) div 4,
    <<_:10/binary, Sum:16, _/binary>> = Packet,
    case erx_net_pkt_oracle:ipv4(Packet) of
        {ok, #{v := 4, hl := Hl, tos := Tos, len := Len, id := Id, df := Df, mf := Mf, off := Off,
               ttl := Ttl, p := P, sum := Sum, src := Src, dst := Dst, options := Options}, Rest}
          when byte_size(Rest) >= byte_size(Payload) ->
            Payload = binary:part(Rest, 0, byte_size(Payload)),
            ok;
        Other ->
            error({disagrees_with_pkt, Packet, Other})
    end.
