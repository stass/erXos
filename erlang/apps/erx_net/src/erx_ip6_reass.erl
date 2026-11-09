%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/frag6.c
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
%% All rights reserved.
%% Copyright (c) 2019 Netflix, Inc.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%% 3. Neither the name of the project nor the names of its contributors
%%    may be used to endorse or promote products derived from this software
%%    without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE PROJECT AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE PROJECT OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_ip6_reass).
-moduledoc """
IPv6 reassembly, translated from FreeBSD's frag6.c at the commit
NOTICE-freebsd records (docs/design-network-stack.md, "IPv6, neighbour
discovery and autoconfiguration"). The interface process keeps one table
and hands it every packet whose header erx_ip6_wire:decode/1 returned
with a `fragment`; that decoder has made `frag6_input`'s checks of the
fragment alone (data present, a multiple of 8 bytes unless it is the
last, the first fragment holding the whole header chain of RFC 7112). The
table, its caps and the steps it takes for a fragment are erx_ip_reass's,
with RFC 5722's rule that an overlap drops the whole datagram. A datagram
is keyed by its zoned source and destination (erx_net_addr:zoned/2, in
the zone its fragments' addresses took) and its identification, so
fragments that arrived in two zones never join, as FreeBSD's embedded
zone keeps them apart in `frag6_input`'s hash.

A fragment that would take the datagram past 65,535 bytes is answered
with a parameter problem at its fragment offset field, as `frag6_input`
answers it; `input/6` returns the code and pointer and erx_ip6 sends it.
A completed datagram comes back with the zone and link cast of its
fragment at offset 0 and as a packet: the first fragment's fixed
and unfragmentable headers, without the fragment header, followed by the
fragmentable part, with CE set if any fragment carried it. It goes
through erx_ip6_wire's decoder and erx_ip6's input as any packet does,
which walks the headers of the fragmentable part. An expired datagram
whose first fragment arrived is answered with a time-exceeded error, as
`frag6_freef` answers it; `expire/2` returns that fragment with its
zone when it came as a link-layer unicast, since `icmp6_error` answers
no packet that came as a broadcast or multicast (icmp6.c:309).
""".

-include("erx_ip6.hrl").

-export([new/0, new/1, input/6, expire/2, next_deadline/1, held/1]).

-export_type([reason/0]).

-type reason() :: {param_problem, ?ICMP6_PARAMPROB_HEADER, Pointer :: non_neg_integer()}
                | erx_ip_reass:reason().

%% The fragment header's fragment offset field follows its next-header and
%% reserved bytes.
-define(OFFLG_PTR, 2).
%% The fragment header's length, which the record's `hdrlen' includes.
-define(FRAG_LEN, 8).

-doc "An empty table with FreeBSD's caps.".
-spec new() -> erx_ip_reass:table().
new() -> new(#{}).

-doc "An empty table, Limits overriding FreeBSD's caps (erx_ip_reass:limits()).".
-spec new(#{atom() => pos_integer()}) -> erx_ip_reass:table().
new(Limits) -> erx_ip_reass:new(inet6, Limits).

-doc """
Takes fragment Ip, with Data the fragment's data as erx_ip6_wire:decode/1
returned it, Zone the zone its addresses took and LinkCast the cast of
its frame (erx_net_input:link_cast()), at time Now in milliseconds. A
completed datagram comes back with the zone and link cast of its
fragment at offset 0.
""".
-spec input(#ip6{}, binary(), Zone :: term(), erx_net_input:link_cast(), integer(),
            erx_ip_reass:table()) ->
          {done, Zone :: term(), erx_net_input:link_cast(), Packet :: binary(), erx_ip_reass:table()}
        | {held, erx_ip_reass:table()}
        | {drop, reason(), erx_ip_reass:table()}.
input(#ip6{src = Src, dst = Dst, tclass = Tclass, fragment = {Off, More, Id}, hdrlen = HdrLen,
           proto_ptr = FragPtr} = Ip, Data, Zone, LinkCast, Now, T) ->
    Head = case Off of
               0 -> {HdrLen - ?FRAG_LEN, {Ip, Zone, LinkCast}};
               _ -> none
           end,
    Key = {erx_net_addr:zoned(Src, Zone), erx_net_addr:zoned(Dst, Zone), Id},
    Piece = #{key => Key, off => Off, more => More, ecn => Tclass band 3, data => Data, head => Head},
    case erx_ip_reass:input(Piece, Now, T) of
        {drop, too_long, T2} ->
            {drop, {param_problem, ?ICMP6_PARAMPROB_HEADER, FragPtr + ?OFFLG_PTR}, T2};
        {done, {_, {First, FirstZone, FirstCast}}, Ecn, Fragments, T2} ->
            Tc = case Ecn of
                     3 -> First#ip6.tclass bor 3;
                     _ -> First#ip6.tclass
                 end,
            Packet = iolist_to_binary(erx_ip6_wire:encode(First#ip6{fragment = none, tclass = Tc}, Fragments)),
            {done, FirstZone, FirstCast, Packet, T2};
        Result ->
            Result
    end.

-doc """
Drops every datagram whose lifetime ended at or before Now, and returns
the zone, header and data of each such datagram's first fragment, if it
arrived as a link-layer unicast, for erx_ip6 to answer with a
time-exceeded error (code 1); one that came as a broadcast or multicast
is dropped unanswered (icmp6_error, icmp6.c:309).
""".
-spec expire(integer(), erx_ip_reass:table()) -> {[{Zone :: term(), #ip6{}, binary()}], erx_ip_reass:table()}.
expire(Now, T) ->
    {Firsts, T2} = erx_ip_reass:expire(Now, T),
    {[{Zone, Ip, Data} || {{Ip, Zone, unicast}, Data} <- Firsts], T2}.

-doc "When the oldest datagram's lifetime ends, or `none`.".
-spec next_deadline(erx_ip_reass:table()) -> integer() | none.
next_deadline(T) -> erx_ip_reass:next_deadline(T).

-doc "What the table holds.".
-spec held(erx_ip_reass:table()) -> map().
held(T) -> erx_ip_reass:held(T).
