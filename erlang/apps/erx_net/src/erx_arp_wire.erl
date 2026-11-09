%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/if_ether.c
%% Copyright (c) 1982, 1986, 1988, 1993
%% The Regents of the University of California.  All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of the University nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_arp_wire).
-moduledoc """
The ARP codec for IPv4 over Ethernet (docs/design-network-stack.md, "IPv4 and ARP").
`decode/1` takes the payload of an Ethernet frame of type ARP and makes the checks of
`arpintr` and the first check of `in_arpinput`, translated from FreeBSD's
`sys/netinet/if_ether.c` at commit 95719d8a (erlang/apps/erx_net/NOTICE-freebsd); `encode/1`
writes a packet to send. Which packets create or update a neighbour entry, and which are
answered, is `erx_arp`'s decision.

One departure: `arpintr` also passes InfiniBand and FireWire hardware types to
`in_arpinput`, the FireWire one with any address length below 20. Neither can arrive on an
interface of this stack, which is Ethernet only, so both are refused with the other unknown
hardware types (docs/design-network-stack.md, "IPv4 and ARP").
""".

-include("erx_arp_wire.hrl").
-include("erx_net_eth.hrl").

-export([decode/1, encode/1]).

-export_type([error_reason/0]).

%% sizeof(struct arphdr): the fixed part ahead of the addresses.
-define(ARPHDR_LEN, 8).
-define(ETHER_ADDR_LEN, 6).
-define(IN_ADDR_LEN, 4).

-doc """
Why a packet is refused: `too_short` for fewer bytes than its header says it holds,
`bad_hardware` for a hardware type other than Ethernet's or an address length other than 6,
`bad_protocol` for a protocol other than IPv4 or an address length other than 4.
""".
-type error_reason() :: too_short | bad_hardware | bad_protocol.

-doc """
The packet in Payload and the bytes behind it (an Ethernet frame's padding), or why it is
refused. The checks run in `arpintr`'s order: the fixed header present, then all the
addresses its lengths announce (`arphdr_len`), then the hardware type and its address length,
then the protocol type (`arpintr`'s switch) and its address length (`in_arpinput`). Total
over binaries: it never raises.
""".
-spec decode(binary()) -> {ok, #arp{}, Rest :: binary()} | {error, error_reason()}.
decode(<<Hrd:16, Pro:16, Hln:8, Pln:8, Op:16, Addresses/binary>>) ->
    if
        byte_size(Addresses) < 2 * (Hln + Pln) -> {error, too_short};
        Hrd =/= ?ARPHRD_ETHER andalso Hrd =/= ?ARPHRD_IEEE802 -> {error, bad_hardware};
        Hln =/= ?ETHER_ADDR_LEN -> {error, bad_hardware};
        Pro =/= ?ETHERTYPE_IP -> {error, bad_protocol};
        Pln =/= ?IN_ADDR_LEN -> {error, bad_protocol};
        true ->
            <<Sha:6/binary, Spa:4/binary, Tha:6/binary, Tpa:4/binary, Rest/binary>> = Addresses,
            {ok, #arp{hrd = Hrd, op = Op, sha = Sha, spa = Spa, tha = Tha, tpa = Tpa}, Rest}
    end;
decode(Payload) when is_binary(Payload), byte_size(Payload) < ?ARPHDR_LEN ->
    {error, too_short}.

-doc "The 28-byte packet Arp, the inverse of `decode/1`.".
-spec encode(#arp{}) -> <<_:224>>.
encode(#arp{hrd = Hrd, op = Op, sha = <<_:48>> = Sha, spa = <<_:32>> = Spa,
            tha = <<_:48>> = Tha, tpa = <<_:32>> = Tpa})
  when (Hrd =:= ?ARPHRD_ETHER orelse Hrd =:= ?ARPHRD_IEEE802), is_integer(Op), Op >= 0, Op =< 16#FFFF ->
    <<Hrd:16, ?ETHERTYPE_IP:16, ?ETHER_ADDR_LEN, ?IN_ADDR_LEN, Op:16,
      Sha/binary, Spa/binary, Tha/binary, Tpa/binary>>.
