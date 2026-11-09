%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/ip_input.c
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
%%
%% FreeBSD: sys/netinet/ip_options.c
%% Copyright (c) 1982, 1986, 1988, 1993
%%      The Regents of the University of California.
%% Copyright (c) 2005 Andre Oppermann, Internet Business Solutions AG.
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
%%
%% FreeBSD: sys/netinet/ip_output.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993
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
%%
%% FreeBSD: sys/netinet/ip_id.c
%% Copyright (c) 2008 Michael J. Silbersack.
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice unmodified, this list of conditions, and the following
%%    disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-module(erx_ip4).
-moduledoc """
The IPv4 input and output decisions (docs/design-network-stack.md, "IPv4 and ARP"),
translated from `ip_input`, `ip_dooptions`, `ip_output`, `ip_fragment` and `ip_fillid` in
FreeBSD's sys/netinet at the commit NOTICE-freebsd records. Pure: the interface calls
`input/3` for each IPv4 packet, received or reassembled, and `output/4` for each datagram
it or a socket sends.

`input/3` decodes the packet with erx_ip4_wire and makes `ip_input`'s decisions with
FreeBSD's defaults: no forwarding, the weak end-system model (`ip_strong_es` 0) and
source address validation (`ip_sav` 1). It returns the datagram for the layer above, a
fragment for erx_ip4_reass, the pointer of the parameter problem to answer a malformed
option with, or a drop with its reason. It also drops a TCP segment from 0.0.0.0, the
check `tcp_input_with_port` makes, since this is the one place that sees both headers
before the TCP lookup.

Departures, each changing only which packets draw an answer:

* A packet carrying a source-route option is dropped, whatever the option holds; FreeBSD's
  defaults (`ip_dosourceroute` and `ip_acceptsourceroute` 0) drop one that reaches a host,
  but answer a strict route not addressed to the host with source route failed.
* A malformed option is answered with a parameter problem only in a packet addressed to
  one of the stack's addresses in a unicast frame. `ip_dooptions` runs before the address
  checks and answers any packet; a host that forwards nothing has no reason to answer a
  packet it then drops.
* `ip_fragment` cuts a datagram over a 4,096-byte fragment into page-sized pieces
  (`PAGE_SIZE`); every fragment here carries as much as the MTU allows.
""".

-include("erx_ip4_wire.hrl").

-export([input/3, output/4, addr_class/1]).

-export_type([view/0, cast/0, reply/0, result/0, reason/0, out/0, class/0]).

-define(IPPROTO_TCP, 6).
-define(IP_HDR_LEN, 20).
%% IPDEFTTL (netinet/ip.h).
-define(IPDEFTTL, 64).
-define(INADDR_ANY, <<0, 0, 0, 0>>).
-define(INADDR_BROADCAST, <<255, 255, 255, 255>>).

-doc """
What `input/3` needs of the interface's published view: every IPv4 address of the stack
(the weak end-system model accepts a packet to any of them on any interface), the
broadcast addresses of the receiving interface, and whether it is the loopback interface.
""".
-type view() :: #{addrs := [<<_:32>>], broadcasts := [<<_:32>>], loopback := boolean()}.

-doc """
How a packet was addressed: to one host, or to a broadcast or multicast address. Given to
`input/3` as the frame's link-layer destination (FreeBSD's `M_BCAST` and `M_MCAST`), and
returned with a datagram as its IP destination's class, which chooses between delivering
it to one socket and to every socket bound to it, as `udp_input` chooses.
""".
-type cast() :: unicast | broadcast | multicast.

-doc """
Whether the stack may answer a datagram (an echo or timestamp reply, an ICMP error, a TCP
reset), decided here once for every responder: only a datagram addressed to one of the
stack's addresses, in a unicast frame, from a source that can be answered. That source is
not multicast, 240.0.0.0/4, 0.0.0.0/8 (`icmp_reflect`'s refusals), the limited broadcast
or a broadcast address of the interface (which `ip_output` refuses to send to); a
loopback source can be answered, since only the loopback interface delivers one. An
answer goes from the datagram's destination to its source.
""".
-type reply() :: boolean().

-doc """
Why `input/3` dropped a packet: the codec's reason, or the `ipstat` counter `ip_input`
raises: `bad_addr` (`ips_badaddr`) for a loopback address off the loopback interface, a
destination 0.0.0.0, a source that is one of the stack's own addresses, or a TCP segment
from 0.0.0.0; `not_ours` (`ips_cantforward`) for a destination that is not the stack's;
`source_route` for a source-route option; `bad_options` for a malformed option not
answered (see the module's departures).
""".
-type reason() :: erx_ip4_wire:error_reason() | bad_addr | not_ours | source_route | bad_options.

-doc """
A datagram for the protocol in its header, with its destination's class and whether it may
be answered; a fragment for erx_ip4_reass, whose completed datagram comes back through
`input/3`; a parameter problem to answer with `erx_icmp4:error/4` at the pointer given,
returned only for a packet that may be answered; or a drop.
""".
-type result() :: {ours, cast(), reply(), #ip4{}, Payload :: binary()}
                | {fragment, #ip4{}, Payload :: binary()}
                | {param_problem, Pointer :: 21..60}
                | {drop, reason()}.

-doc """
A datagram to send: its addresses and protocol, and optionally its TTL (64), type of
service (0) and don't-fragment flag (false). Sent datagrams carry no options.
""".
-type out() :: #{src := <<_:32>>, dst := <<_:32>>, proto := 0..255,
                 ttl => 0..255, tos => 0..255, df => boolean()}.

-doc """
An address's class by its leading bits (netinet/in.h): `zero` for 0.0.0.0/8
(`IN_ZERONET`), `loopback` for 127.0.0.0/8, `multicast` for 224.0.0.0/4, `experimental`
for 240.0.0.0/4 with 255.255.255.255 among them (`IN_EXPERIMENTAL`), `unicast` otherwise.
""".
-type class() :: zero | loopback | multicast | experimental | unicast.

-doc "The decisions `ip_input` makes on Packet, which arrived in a frame addressed as LinkCast.".
-spec input(binary(), cast(), view()) -> result().
input(Packet, LinkCast, View) ->
    case erx_ip4_wire:decode(Packet) of
        {ok, Ip, Payload} -> checks(Ip, Payload, LinkCast, View);
        {error, {bad_options, Pointer}} -> bad_options(Packet, Pointer, LinkCast, View);
        {error, Reason} -> {drop, Reason}
    end.

checks(#ip4{src = Src, dst = Dst} = Ip, Payload, LinkCast, View) ->
    maybe
        ok ?= addresses(Src, Dst, View),
        ok ?= source_route(erx_ip4_wire:options(Ip)),
        {ok, Cast, Reply} ?= ours(Src, Dst, LinkCast, View),
        ok ?= tcp_source(Ip),
        case Ip of
            #ip4{mf = 0, off = 0} -> {ours, Cast, Reply, Ip, Payload};
            _ -> {fragment, Ip, Payload}
        end
    end.

%% The header has passed its checksum before the options were walked, so its addresses
%% can be read from the packet.
bad_options(<<_:96, Src:4/binary, Dst:4/binary, _/binary>>, Pointer, LinkCast, View) ->
    maybe
        ok ?= addresses(Src, Dst, View),
        {ok, _, true} ?= ours(Src, Dst, LinkCast, View),
        {param_problem, Pointer}
    else
        {drop, _} = Drop -> Drop;
        {ok, _, false} -> {drop, bad_options}
    end.

%% RFC 1122: a loopback address never appears on the wire; the unspecified address is
%% never a destination.
addresses(Src, Dst, #{loopback := Loopback}) ->
    Wire = addr_class(Src) =:= loopback orelse addr_class(Dst) =:= loopback,
    if
        Wire, not Loopback -> {drop, bad_addr};
        Dst =:= ?INADDR_ANY -> {drop, bad_addr};
        true -> ok
    end.

source_route(Options) ->
    case [T || {T, _} <- Options, T =:= ?IPOPT_LSRR orelse T =:= ?IPOPT_SSRR] of
        [] -> ok;
        _ -> {drop, source_route}
    end.

%% ip_input's search for the destination, in its order: one of the stack's addresses
%% (refused when the source claims to be one too, ip_sav), a multicast group (each
%% protocol filters its own), the limited broadcast, any unicast packet while the stack
%% has no address at all, and the interface's broadcast address. Only the first may be
%% answered (reply()).
ours(Src, Dst, LinkCast, #{addrs := Addrs, broadcasts := Bcasts, loopback := Loopback}) ->
    Mine = lists:member(Dst, Addrs),
    Sav = not Loopback andalso lists:member(Src, Addrs),
    if
        Mine, Sav -> {drop, bad_addr};
        Mine -> {ok, unicast, LinkCast =:= unicast andalso answerable(Src, Bcasts)};
        true -> not_mine(Dst, LinkCast, Addrs, Bcasts)
    end.

not_mine(Dst, LinkCast, Addrs, Bcasts) ->
    Multicast = addr_class(Dst) =:= multicast,
    Broadcast = Dst =:= ?INADDR_BROADCAST orelse lists:member(Dst, Bcasts),
    if
        Multicast -> {ok, multicast, false};
        Broadcast -> {ok, broadcast, false};
        Addrs =:= [], LinkCast =:= unicast -> {ok, unicast, false};
        true -> {drop, not_ours}
    end.

answerable(Src, Bcasts) ->
    Class = addr_class(Src),
    (Class =:= unicast orelse Class =:= loopback) andalso not lists:member(Src, Bcasts).

%% tcp_input_with_port drops a segment from the unspecified address.
tcp_source(#ip4{p = ?IPPROTO_TCP, src = ?INADDR_ANY}) -> {drop, bad_addr};
tcp_source(_) -> ok.

-doc "The class of an IPv4 address.".
-spec addr_class(<<_:32>>) -> class().
addr_class(<<0, _:24>>) -> zero;
addr_class(<<127, _:24>>) -> loopback;
addr_class(<<2#1110:4, _:28>>) -> multicast;
addr_class(<<2#1111:4, _:28>>) -> experimental;
addr_class(<<_:32>>) -> unicast.

-doc """
The packets that carry Payload to its destination over a link of MTU bytes, with the
generator advanced past what it drew. One packet when the datagram fits; otherwise, unless
don't-fragment is set, fragments of `(Mtu - 20) band bnot 7` bytes of data each but the
last, as `ip_fragment` cuts them, all with one identification. `emsgsize` when the
datagram is over 65535 bytes, or does not fit and may not be fragmented, or the MTU leaves fewer than 8 bytes of
data. The identification follows `ip_fillid` with RFC 6864 on: zero for a datagram with
don't-fragment set, two random bytes from Gen otherwise (see the design's departure from
FreeBSD's counter).
""".
-spec output(out(), iodata(), pos_integer(), erx_net_rand:gen()) ->
          {ok, [iodata()], erx_net_rand:gen()} | {error, emsgsize}.
output(Out, Payload, Mtu, Gen0) ->
    Df = maps:get(df, Out, false),
    Len = iolist_size(Payload),
    Total = ?IP_HDR_LEN + Len,
    Fits = Total =< Mtu,
    FragLen = (Mtu - ?IP_HDR_LEN) band bnot 7,
    if
        Total > 16#ffff ->
            {error, emsgsize};
        Fits, Df ->
            {ok, [packet(header(Out, 0), Payload, Len, 0, 0)], Gen0};
        Fits ->
            {Id, Gen} = fillid(Gen0),
            {ok, [packet(header(Out, Id), Payload, Len, 0, 0)], Gen};
        Df orelse FragLen < 8 ->
            {error, emsgsize};
        true ->
            {Id, Gen} = fillid(Gen0),
            {ok, fragments(header(Out, Id), iolist_to_binary(Payload), FragLen, 0), Gen}
    end.

fillid(Gen0) ->
    {<<Id:16>>, Gen} = erx_net_rand:bytes(2, Gen0),
    {Id, Gen}.

header(#{src := Src, dst := Dst, proto := P} = Out, Id) ->
    #ip4{tos = maps:get(tos, Out, 0), id = Id, df = df(maps:get(df, Out, false)),
         ttl = maps:get(ttl, Out, ?IPDEFTTL), p = P, src = Src, dst = Dst}.

df(true) -> 1;
df(false) -> 0.

fragments(Ip, Data, FragLen, Off) when byte_size(Data) > FragLen ->
    <<Piece:FragLen/binary, Rest/binary>> = Data,
    [packet(Ip, Piece, FragLen, 1, Off) | fragments(Ip, Rest, FragLen, Off + FragLen div 8)];
fragments(Ip, Data, _, Off) ->
    [packet(Ip, Data, byte_size(Data), 0, Off)].

packet(Ip, Data, Len, Mf, Off) ->
    [erx_ip4_wire:encode(Ip#ip4{len = ?IP_HDR_LEN + Len, mf = Mf, off = Off}), Data].
