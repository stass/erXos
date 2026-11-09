%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random ARP packets through erx_arp_wire:decode/1 (docs/design-network-stack.md, "Codecs:
%% fuzz targets"). Whatever arrives, the decoder returns without raising and refuses only for
%% one of its three reasons; it accepts exactly the packets reference/1 accepts, written from
%% RFC 826 alone: an Ethernet hardware type (1, or 6 for IEEE 802 networks, RFC 1042) with
%% 6-byte addresses, protocol IPv4 with 4-byte addresses, and every address present. On what
%% it accepts, encoding the packet and appending the rest gives the input back, and pkt
%% (erx_net_pkt_oracle) reads the same fields. Most packets are well formed, with one field
%% or the length moved to its edge on the rest. The seed comes from make check-fuzz.
-module(erx_arp_wire_fuzz).
-export([run/1]).

-include("erx_arp_wire.hrl").

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 4).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    Packet = packet(),
    Said = try erx_arp_wire:decode(Packet)
           catch Class:Exception -> error({raised, Packet, Class, Exception})
           end,
    case {Said, reference(Packet)} of
        {{ok, #arp{} = Arp, Rest}, accept} ->
            Packet = <<(erx_arp_wire:encode(Arp))/binary, Rest/binary>>,
            agrees_with_pkt(Packet, Arp),
            accepted;
        {{error, Reason}, reject} when Reason =:= too_short; Reason =:= bad_hardware; Reason =:= bad_protocol ->
            refused;
        _ ->
            error({disagrees_with_reference, Packet, Said})
    end.

packet() ->
    Hrd = pick([1, 6], fun() -> rand:uniform(65536) - 1 end),
    Pro = pick([16#0800], fun() -> rand:uniform(65536) - 1 end),
    Hln = pick([6], fun() -> rand:uniform(256) - 1 end),
    Pln = pick([4], fun() -> rand:uniform(256) - 1 end),
    Op = rand:uniform(4) - 1,
    Full = 2 * (Hln + Pln),
    Length = case rand:uniform(6) of
                 1 -> rand:uniform(Full + 1) - 1;
                 2 -> max(0, Full - 1);
                 3 -> Full + rand:uniform(32);
                 _ -> Full
             end,
    Bytes = <<Hrd:16, Pro:16, Hln, Pln, Op:16, (rand:bytes(Length))/binary>>,
    case rand:uniform(10) of
        1 -> binary:part(Bytes, 0, rand:uniform(8) - 1);
        _ -> Bytes
    end.

%% The usual value on most packets, any value on the rest.
pick(Usual, Any) ->
    case rand:uniform(8) of
        1 -> Any();
        _ -> lists:nth(rand:uniform(length(Usual)), Usual)
    end.

reference(<<Hrd:16, 16#0800:16, 6, 4, _Op:16, Addresses/binary>>)
  when (Hrd =:= 1 orelse Hrd =:= 6), byte_size(Addresses) >= 20 ->
    accept;
reference(_Packet) ->
    reject.

agrees_with_pkt(Packet, #arp{hrd = Hrd, op = Op, sha = Sha, spa = Spa, tha = Tha, tpa = Tpa}) ->
    case erx_net_pkt_oracle:arp(Packet) of
        {ok, #{hrd := Hrd, pro := 16#0800, hln := 6, pln := 4, op := Op,
               sha := Sha, spa := Spa, tha := Tha, tpa := Tpa}, _} -> ok;
        Other -> error({disagrees_with_pkt, Packet, Other})
    end.
