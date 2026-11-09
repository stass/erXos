%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/ip_reass.c
%% Copyright (c) 2015 Gleb Smirnoff <glebius@FreeBSD.org>
%% Copyright (c) 2015 Adrian Chadd <adrian@FreeBSD.org>
%% Copyright (c) 1982, 1986, 1988, 1993
%%	The Regents of the University of California.  All rights reserved.
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

-module(erx_ip4_reass).
-moduledoc """
IPv4 reassembly, translated from FreeBSD's ip_reass.c at the commit
NOTICE-freebsd records (docs/design-network-stack.md, "IPv4 and ARP").
The interface process keeps one table and hands it every fragment that
erx_ip4_wire decoded and erx_ip4 accepted for this host; the table, its
caps and the steps it takes for a fragment are erx_ip_reass's.

`input/5` first makes `ip_reass`'s checks of the fragment alone: it
carries data, a multiple of 8 bytes unless it is the last. A completed
datagram comes back with the zone `none` and the link cast of its
fragment at offset 0, whose `M_BCAST` and `M_MCAST` `ip_reass` keeps.
It comes back as a packet, its header the first fragment's with
the total length of the whole, no fragment offset or more-fragments flag
and CE set if any fragment carried it, so that it goes through
erx_ip4_wire's decoder and erx_ip4's input as any packet does. An expired
datagram is dropped without an answer, as `ipq_timeout` drops it.
""".

-include("erx_ip4_wire.hrl").

-export([new/0, new/1, input/5, expire/2, next_deadline/1, held/1]).

-export_type([reason/0]).

-type reason() :: too_small | erx_ip_reass:reason().

-doc "An empty table with FreeBSD's caps.".
-spec new() -> erx_ip_reass:table().
new() -> new(#{}).

-doc "An empty table, Limits overriding FreeBSD's caps (erx_ip_reass:limits()).".
-spec new(#{atom() => pos_integer()}) -> erx_ip_reass:table().
new(Limits) -> erx_ip_reass:new(inet, Limits).

-doc """
Takes fragment Ip, with Payload its data as erx_ip4_wire:decode/1 cut it
and LinkCast the cast of its frame (erx_net_input:link_cast()), at time
Now in milliseconds. Ip must be a fragment: more fragments follow it or
its offset is not zero. A completed datagram comes back with IPv4's
zone, `none`, and the link cast of its fragment at offset 0, as
erx_ip6_reass returns one.
""".
-spec input(#ip4{}, binary(), erx_net_input:link_cast(), integer(), erx_ip_reass:table()) ->
          {done, none, erx_net_input:link_cast(), Packet :: binary(), erx_ip_reass:table()}
        | {held, erx_ip_reass:table()}
        | {drop, reason(), erx_ip_reass:table()}.
input(#ip4{mf = Mf, off = Off} = Ip, Payload, LinkCast, Now, T) when Mf =:= 1; Off > 0 ->
    case byte_size(Payload) of
        0 -> {drop, too_small, T};
        Len when Mf =:= 1, Len rem 8 =/= 0 -> {drop, too_small, T};
        _ -> packet(erx_ip_reass:input(piece(Ip, Payload, LinkCast), Now, T))
    end.

piece(#ip4{src = Src, dst = Dst, p = P, id = Id, mf = Mf, off = Off, tos = Tos, options = Options} = Ip,
      Payload, LinkCast) ->
    Head = case Off of
               0 -> {20 + byte_size(Options), {Ip, LinkCast}};
               _ -> none
           end,
    #{key => {Src, Dst, P, Id}, off => Off * 8, more => Mf =:= 1, ecn => Tos band 3,
      data => Payload, head => Head}.

packet({done, {HdrLen, {Ip, LinkCast}}, Ecn, Data, T}) ->
    Tos = case Ecn of
              3 -> Ip#ip4.tos bor 3;
              _ -> Ip#ip4.tos
          end,
    Header = erx_ip4_wire:encode(Ip#ip4{len = HdrLen + iolist_size(Data), mf = 0, off = 0, tos = Tos}),
    {done, none, LinkCast, iolist_to_binary([Header | Data]), T};
packet(Result) ->
    Result.

-doc "Drops every datagram whose lifetime ended at or before Now.".
-spec expire(integer(), erx_ip_reass:table()) -> erx_ip_reass:table().
expire(Now, T) ->
    {_FirstFragments, T2} = erx_ip_reass:expire(Now, T),
    T2.

-doc "When the oldest datagram's lifetime ends, or `none`.".
-spec next_deadline(erx_ip_reass:table()) -> integer() | none.
next_deadline(T) -> erx_ip_reass:next_deadline(T).

-doc "What the table holds.".
-spec held(erx_ip_reass:table()) -> map().
held(T) -> erx_ip_reass:held(T).
