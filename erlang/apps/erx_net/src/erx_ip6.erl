%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/ip6_input.c
%% FreeBSD: sys/netinet6/ip6_output.c
%% FreeBSD: sys/netinet6/scope6.c
%%
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
%% Copyright (C) 2000 WIDE Project.
%% All rights reserved.
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
%%
%% Copyright (c) 1982, 1986, 1988, 1990, 1993
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

-module(erx_ip6).
-moduledoc """
The IPv6 input and output decisions (docs/design-network-stack.md, "IPv6, neighbour
discovery and autoconfiguration"), translated from `ip6_input` and `ip6_output` in
FreeBSD's sys/netinet6 and the scope checks of `in6_clearscope` and `in6_setscope` at the
commit NOTICE-freebsd records. Pure: the interface calls `input/4` for each IPv6 packet,
received or reassembled, and `output/4` for each datagram it or a socket sends. It reads
as erx_ip4 does, and returns the same shapes.

`input/4` decodes the packet with erx_ip6_wire, which walks the extension headers, and
makes `ip6_input`'s address checks with FreeBSD's defaults: no forwarding, the weak
end-system model and source address validation (`ip6_sav` 1). It returns the datagram for
the layer above, a fragment for erx_ip6_reass, the code and pointer of the parameter
problem to answer a malformed header with, or a drop with its reason. Like erx_ip4 it
drops a TCP segment from `::`, the check `tcp_input_with_port` makes, since this is the
one place that sees both headers before the TCP lookup.

It also drops a neighbour-discovery message (router solicitation and advertisement,
neighbour solicitation and advertisement, redirect) that came in fragments: one rebuilt by
erx_ip6_reass, or one carrying an atomic fragment header. That is RFC 6980's rule, which
FreeBSD applies through the `M_FRAGMENTED` flag `ip6_deletefraghdr` sets; here the caller
says which packets reassembly rebuilt (`origin()`), and the rule lives in one place, before
erx_nd6, erx_nd6_rtr and erx_icmp6 see a message. The type is read before the ICMPv6
checksum is: a corrupt type can only turn a drop by the checksum into this drop.

Departures, each changing only which packets draw an answer:

* A malformed header is answered with a parameter problem only in a packet addressed to
  one of the stack's addresses in a unicast frame, as erx_ip4 answers a malformed option.
  FreeBSD answers an unrecognised option whose type asks for it (`ip6_unknown_opt`'s
  type 10) also in a packet to a multicast address; a host has no reason to.
* Nothing is answered for a packet to a multicast address, so no echo reply either, where
  FreeBSD answers an echo request to a multicast group from an address it selects. The
  design's rule is no reply to a broadcast or multicast.
""".

-include("erx_ip6.hrl").

-export([input/4, output/4]).

-export_type([view/0, cast/0, reply/0, origin/0, result/0, reason/0, out/0]).

-define(FIXED_LEN, 40).
-define(FRAG_LEN, 8).
%% IPV6_DEFHLIM and IPV6_MMTU (netinet/ip6.h, netinet6/in6.h).
-define(IPV6_DEFHLIM, 64).
-define(IPV6_MMTU, 1280).
-define(IPV6_MAXPACKET, 16#ffff).
-define(UNSPECIFIED, <<0:128>>).
-define(LOOPBACK, <<1:128>>).
%% IN6_IS_ADDR_MULTICAST, usable in guards.
-define(IS_MC(Addr), (binary_part(Addr, 0, 1) =:= <<16#ff>>)).
%% Multicast scopes (IPV6_ADDR_SCOPE_*).
-define(SCOPE_RESERVED, 0).
-define(SCOPE_INTFACELOCAL, 1).
-define(SCOPE_LINKLOCAL, 2).

-doc """
What `input/4` needs of the interface's view: every IPv6 address of the stack that is
ready (neither tentative nor duplicated) and every one that is not, on every interface
(the weak end-system model), each zoned (`erx_net_addr:zoned/0`); whether the receiving
interface is the loopback interface; and the zone the packet's addresses take, the
receiving interface's or, on the loopback interface, the one the looped packet carries.
A link-local or interface-local address therefore matches only in its own zone, as
`in6_setscope` makes each interface its own zone.
""".
-type view() :: #{addrs := [erx_net_addr:zoned()], notready := [erx_net_addr:zoned()],
                  loopback := boolean(), zone := term()}.

-doc """
How a packet was addressed, erx_ip4's `cast()`: given to `input/4` as the frame's
link-layer destination, and returned with a datagram as its IP destination's class
(`unicast` or `multicast`; IPv6 has no broadcast address).
""".
-type cast() :: unicast | broadcast | multicast.

-doc """
Whether the stack may answer a datagram (an echo reply, an ICMPv6 error, a TCP reset),
decided here once for every responder: only a datagram addressed to one of the stack's
ready addresses, in a unicast frame, from a source other than `::` (`icmp6_error` and
`icmp6_reflect` refuse it; a multicast source is dropped before). An answer goes from the
datagram's destination to its source.
""".
-type reply() :: boolean().

-doc """
Whether a packet arrived as it is (`received`) or was rebuilt by erx_ip6_reass
(`reassembled`), FreeBSD's `M_FRAGMENTED`.
""".
-type origin() :: received | reassembled.

-doc """
Why `input/4` dropped a packet: the codec's reason (a parameter problem among them when
the packet may not be answered), or `bad_addr` (`ifs6_in_addrerr`) for a multicast or
v4-mapped source, a v4-mapped, unspecified, reserved-scope or (off the loopback interface)
interface-local multicast destination, a link-local address carrying a zone in its second
word, a loopback address off the loopback interface, a source that is one of the stack's
own addresses, or a TCP segment from `::`; `not_ready` for a destination that is a
tentative or duplicated address; `not_ours` (`ip6s_cantforward`) for a destination that is
not the stack's; `fragmented_nd` for a neighbour-discovery message that came in fragments.
""".
-type reason() :: erx_ip6_wire:reason() | bad_addr | not_ready | not_ours | fragmented_nd.

-doc """
A datagram for the protocol that ended the header walk, with its destination's class and
whether it may be answered; a fragment for erx_ip6_reass, whose completed datagram comes
back through `input/4` as `reassembled`; a parameter problem to answer with
`erx_icmp6:error/4`, returned only for a packet that may be answered; or a drop.
""".
-type result() :: {ours, cast(), reply(), #ip6{}, Payload :: binary()}
                | {fragment, #ip6{}, Payload :: binary()}
                | {param_problem, Code :: 0..3, Pointer :: non_neg_integer()}
                | {drop, reason()}.

-doc """
A datagram to send: its addresses and protocol, and optionally its hop limit (64,
`IPV6_DEFHLIM`; the interface gives the hop limit routers advertise), traffic class (0),
flow label (0) and don't-fragment flag (false, `IPV6_DONTFRAG`). Sent datagrams carry no
extension headers but the fragment header.
""".
-type out() :: #{src := <<_:128>>, dst := <<_:128>>, proto := 0..255,
                 hlim => 0..255, tclass => 0..255, flow => 0..16#fffff, df => boolean()}.

-doc """
The decisions `ip6_input` makes on Packet, which arrived as Origin says in a frame
addressed as LinkCast.
""".
-spec input(binary(), origin(), cast(), view()) -> result().
input(Packet, Origin, LinkCast, View) ->
    case erx_ip6_wire:decode(Packet) of
        {ok, Ip, Payload} -> checks(Ip, Payload, Origin, LinkCast, View);
        {error, {param_problem, _, _} = Problem} -> malformed(Packet, Problem, LinkCast, View);
        {error, {param_problem_unicast, _, _} = Problem} -> malformed(Packet, Problem, LinkCast, View);
        {error, Reason} -> {drop, Reason}
    end.

checks(#ip6{src = Src, dst = Dst} = Ip, Payload, Origin, LinkCast, View) ->
    maybe
        {ok, Cast, Reply} ?= addresses(Src, Dst, LinkCast, View),
        ok ?= tcp_source(Ip),
        ok ?= nd_fragments(Ip, Payload, Origin),
        case Ip of
            #ip6{fragment = none} -> {ours, Cast, Reply, Ip, Payload};
            _ -> {fragment, Ip, Payload}
        end
    end.

%% ip6_input makes its address checks before it reads the hop-by-hop options, so a
%% malformed header is answered only in a packet those checks keep, and one that may be
%% answered (see the module's departures). The codec has checked the version and the
%% payload length before it walked the headers, so the addresses can be read from the
%% packet.
malformed(<<_:64, Src:16/binary, Dst:16/binary, _/binary>>, {_, Code, Pointer} = Problem,
          LinkCast, View) ->
    case addresses(Src, Dst, LinkCast, View) of
        {ok, _, true} -> {param_problem, Code, Pointer};
        {ok, _, false} -> {drop, Problem};
        {drop, _} = Drop -> Drop
    end.

%% ip6_input's checks against spoofed and corrupt addresses, in its order, then its search
%% for the destination: a multicast group (each protocol filters its own), one of the
%% stack's addresses (refused when it is not ready, or when the source claims to be one
%% too, ip6_sav). Only the second may be answered (reply()). The order matters: a
%% multicast destination is accepted before the source check, so a duplicate address
%% detection advertisement to all nodes from an address this stack also holds as
%% tentative still reaches erx_nd6.
addresses(Src, Dst, LinkCast, #{addrs := Addrs, notready := NotReady, loopback := Loopback,
                                 zone := Zone}) ->
    Bad = ?IS_MC(Src)
        orelse (mc_scope(Dst) =:= ?SCOPE_INTFACELOCAL andalso not Loopback)
        orelse mc_scope(Dst) =:= ?SCOPE_RESERVED
        orelse erx_net_addr:is_v4mapped(Src) orelse erx_net_addr:is_v4mapped(Dst)
        orelse Dst =:= ?UNSPECIFIED
        orelse embeds_zone(Src) orelse embeds_zone(Dst)
        orelse ((Src =:= ?LOOPBACK orelse Dst =:= ?LOOPBACK) andalso not Loopback),
    ZSrc = erx_net_addr:zoned(Src, Zone),
    Sav = not Loopback andalso (lists:member(ZSrc, Addrs) orelse lists:member(ZSrc, NotReady)),
    if
        Bad -> {drop, bad_addr};
        ?IS_MC(Dst) -> {ok, multicast, false};
        Sav -> {drop, bad_addr};
        true -> unicast(Src, erx_net_addr:zoned(Dst, Zone), LinkCast, Addrs, NotReady)
    end.

%% Dst is zoned, as the lists are.
unicast(Src, Dst, LinkCast, Addrs, NotReady) ->
    case lists:member(Dst, Addrs) of
        true -> {ok, unicast, LinkCast =:= unicast andalso Src =/= ?UNSPECIFIED};
        false ->
            case lists:member(Dst, NotReady) of
                true -> {drop, not_ready};
                false -> {drop, not_ours}
            end
    end.

%% A multicast address's scope field, or none for any other address.
mc_scope(<<16#ff, _:4, Scope:4, _:112>>) -> Scope;
mc_scope(_) -> none.

%% in6_clearscope's refusal: a link-local unicast or multicast address, or an
%% interface-local multicast one, with a nonzero second word, which is where FreeBSD keeps
%% a zone inside the kernel and so must never arrive.
embeds_zone(<<16#3fa:10, _:6, Zone:16, _:96>>) -> Zone =/= 0;
embeds_zone(<<16#ff, _:4, Scope:4, Zone:16, _:96>>)
  when Scope =:= ?SCOPE_INTFACELOCAL; Scope =:= ?SCOPE_LINKLOCAL -> Zone =/= 0;
embeds_zone(_) -> false.

%% tcp_input_with_port drops a segment from the unspecified address.
tcp_source(#ip6{proto = ?IPPROTO_TCP, src = ?UNSPECIFIED}) -> {drop, bad_addr};
tcp_source(_) -> ok.

%% RFC 6980: a neighbour-discovery message that came in fragments is dropped, whether
%% reassembly rebuilt it or it carried an atomic fragment header (FreeBSD's M_FRAGMENTED
%% checks in nd6_rs_input, nd6_ra_input, nd6_ns_input, nd6_na_input and
%% icmp6_redirect_input). A fragment waiting for reassembly is checked once it is whole.
nd_fragments(#ip6{proto = ?IPPROTO_ICMPV6, fragment = none, exthdrs = ExtHdrs}, <<Type, _/binary>>, Origin)
  when Type >= ?ND_ROUTER_SOLICIT, Type =< ?ND_REDIRECT ->
    case Origin =:= reassembled orelse lists:keymember(fragment, 1, ExtHdrs) of
        true -> {drop, fragmented_nd};
        false -> ok
    end;
nd_fragments(_, _, _) ->
    ok.

-doc """
The packets that carry Payload to its destination over a path of MTU bytes, with the
generator advanced past what it drew, as `ip6_output` sends them. A datagram to a
multicast address is sent at the minimum MTU, 1280 bytes, as `ip6_output` sends it by
default. One packet when the datagram fits, or when don't-fragment is set and it fits the
MTU given; otherwise, unless don't-fragment is set, fragments of
`(Mtu - 48) band bnot 7` bytes of data each but the last, all with one random 32-bit
identification (`ip6_randomid`, drawn from Gen). `emsgsize` when the payload is over
65535 bytes, or the datagram does not fit and may not be fragmented, or the MTU is under
1280 bytes. One MTU serves as both the path and the link MTU, where `ip6_output` lets a
don't-fragment datagram go up to the link MTU even when the path MTU is smaller.
""".
-spec output(out(), iodata(), pos_integer(), erx_net_rand:gen()) ->
          {ok, [iodata()], erx_net_rand:gen()} | {error, emsgsize}.
output(#{dst := Dst} = Out, Payload, Mtu, Gen0) ->
    Df = maps:get(df, Out, false),
    Len = iolist_size(Payload),
    Total = ?FIXED_LEN + Len,
    PathMtu = case ?IS_MC(Dst) of
                  true -> min(Mtu, ?IPV6_MMTU);
                  false -> Mtu
              end,
    if
        Len > ?IPV6_MAXPACKET ->
            {error, emsgsize};
        Total =< PathMtu; Df, Total =< Mtu ->
            %% ip6_output's case 1-a, it fits; or case 2-a, a multicast datagram over the
            %% minimum MTU that may not be fragmented goes whole when the link takes it.
            {ok, [erx_ip6_wire:encode(header(Out), Payload)], Gen0};
        Df; PathMtu < ?IPV6_MMTU ->
            %% Case 2-b, or a path MTU under the minimum, which ip6_output refuses.
            {error, emsgsize};
        true ->
            %% Case 1-b: fragment.
            FragLen = (min(PathMtu, ?IPV6_MAXPACKET) - ?FIXED_LEN - ?FRAG_LEN) band bnot 7,
            {<<Id:32>>, Gen} = erx_net_rand:bytes(4, Gen0),
            {ok, fragments(header(Out), Id, iolist_to_binary(Payload), FragLen, 0), Gen}
    end.

header(#{src := Src, dst := Dst, proto := P} = Out) ->
    #ip6{tclass = maps:get(tclass, Out, 0), flow = maps:get(flow, Out, 0),
         hlim = maps:get(hlim, Out, ?IPV6_DEFHLIM), src = Src, dst = Dst, proto = P}.

%% ip6_fragment: every fragment but the last carries FragLen bytes, a multiple of 8.
fragments(Ip, Id, Data, FragLen, Off) when byte_size(Data) > FragLen ->
    <<Piece:FragLen/binary, Rest/binary>> = Data,
    [erx_ip6_wire:encode(Ip#ip6{fragment = {Off, true, Id}}, Piece)
     | fragments(Ip, Id, Rest, FragLen, Off + FragLen)];
fragments(Ip, Id, Data, _, Off) ->
    [erx_ip6_wire:encode(Ip#ip6{fragment = {Off, false, Id}}, Data)].
