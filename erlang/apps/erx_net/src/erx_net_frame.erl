%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/in_pcb.c
%% Copyright (c) 1982, 1986, 1991, 1993, 1995
%% The Regents of the University of California.
%% Copyright (c) 2007-2009 Robert N. M. Watson
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% Copyright (c) 2021-2022 Gleb Smirnoff <glebius@FreeBSD.org>
%% All rights reserved.
%%
%% Portions of this software were developed by Robert N. M. Watson under
%% contract to Juniper Networks, Inc.
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
%% FreeBSD: sys/netinet6/ip6_output.c
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
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
%% FreeBSD: sys/netinet6/in6_src.c
%% Copyright (C) 1995, 1996, 1997, and 1998 WIDE Project.
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
%% FreeBSD: sys/net/if_ethersubr.c
%% Copyright (c) 1982, 1989, 1993
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

-module(erx_net_frame).
-moduledoc """
Framing for every owner that sends IP (docs/design-network-stack.md, "Framing"): the
header-building and next-hop parts of FreeBSD's `in_pcbladdr`, `ip_output`, `ip6_output`,
`in6_selectif`, `ether_output` and `arpresolve_addr` at the commit NOTICE-freebsd records.

Everything here is pure. What it needs from the published tables reaches it as values
the caller reads:

* `snapshot/3` turns the rows of the interface, address and route tables into one
  `snapshot()`, keeping an address or route row only when the pid it names is the one its
  interface's row holds, so no row of a stopped incarnation is ever used.
* `path/3` gives the way to one destination: the interface, the next hop and how its link
  address is found, the source and the header fields. The sender keeps the path with the
  configuration generation it read the rows at.
* `tcp/3`, `udp/5` and `ip/4` build IP packets over a path, each the `[Header, Payload]`
  iodata `erx_ip4:output/4` and `erx_ip6:output/4` return, and refuse with `emsgsize` what
  IP would refuse; none of them raises.
* `address/3` turns packets into frames with the path's fixed link address or the next
  hop's neighbour row, or hands them back for the interface to resolve; `link/3` frames
  packets on an interface with a link address the interface found itself.

A destination is zoned (`zoned()`): an IPv6 address of interface- or link-local scope
travels with the name of its interface, every other address is its bytes alone
("Zones"). On the loopback interface a frame is the packet with that zone in front of it,
`{Zone, Packet}`, where Zone is the name of the interface whose address the packet is
sent to.

A TCP segment's checksum is delayed when the interface's driver finishes checksums
(its row's `finish` is not `none`) and IP does not fragment the segment ("Checksums in
the copy"). Its packet is then `{csum, Start, Field, Packet}`: the segment starts at byte
`Start` of Packet and its checksum field at byte `Field` of the segment, and the field
holds the pseudo-header's sum, not complemented. The transport's copy finishes it as
`finish/1` does. `link/3` moves `Start` past the link header it puts in front.
""".

-include("erx_net_eth.hrl").
-include("erx_net_frame.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_udp_wire.hrl").

-export([snapshot/3, addresses/1, is_own/2, path/3, tcp/3, tcp/4, no_template/0, template/2, cut/1,
         run_tail/2, frames/1, units/1, udp/5, ip/4, address/3, link/3, finish/1,
         finishable/2]).

-export_type([iface/0, zoned/0, snapshot/0, opts/0, path/0, packet/0, frame/0, delayed/0,
              run/0, template_cache/0]).

-define(IPPROTO_TCP, 6).
-define(IPPROTO_UDP, 17).
-define(TCP_HDR_LEN, 20).
%% The offset of th_sum in the TCP header.
-define(TCP_SUM_OFFSET, 16).
-define(IS_EVEN(N), (is_integer(N) andalso N >= 0 andalso N band 1 =:= 0)).
-define(UDP_HDR_LEN, 8).
-define(IP_MAXPACKET, 16#ffff).
-define(IP_HDR_LEN, 20).
%% The timestamps option as a run carries it, after its two NOPs: NOP NOP TS 10.
-define(TS_LEAD, 1, 1, 8, 10).
%% IPDEFTTL (ip_var.h), and IP_DEFAULT_MULTICAST_TTL and ip6_defmcasthlim (in.h:535,
%% in6.h:521).
-define(IPDEFTTL, 64).
-define(MULTICAST_HLIM, 1).
-define(ETHER_BROADCAST, <<16#ffffffffffff:48>>).

-doc """
An interface's row of `erx_net_ifs`: its name; the pid of the incarnation that wrote it;
its link, `ethernet` or `none` for the loopback interface; its link-layer address; its MTU;
its IPv6 link MTU (`IN6_LINKMTU`); its IPv6 hop limit; who finishes a delayed checksum
(`finish`, from its driver's `erx_net_driver:link_info()`); and its driver's pid. The row's
other fields, its credits among them, pass through to the path untouched.
""".
-type iface() :: #{name := term(), pid := pid(), link := ethernet | none,
                   lladdr := <<_:48>> | none, mtu := pos_integer(), mtu6 := pos_integer(),
                   hlim := 0..255, finish := erx_net_driver:finisher(),
                   driver := pid() | none, atom() => term()}.

-doc """
A destination as the stack holds it: an IPv6 address of interface- or link-local scope
with its interface's name, any other address as its bytes.
""".
-type zoned() :: erx_net_addr:addr() | {erx_net_addr:addr6(), Ifname :: term()}.

-doc """
The configuration a path is built from: the interfaces by name, the current addresses in
the order their interfaces added them, and the current routes.
""".
-opaque snapshot() :: #{ifs := #{term() => iface()},
                        addrs := [erx_net_addr:row()],
                        routes := erx_net_route:table()}.

-doc """
What a sender asks of a path: a source it already holds (`src`, which only the interface
gives as `0.0.0.0` or `::`); the interface a multicast or the limited broadcast leaves
through (`via`); the hop limit (`ttl` for IPv4, `hlim` for IPv6); the type of service or
traffic class (`tos`, `tclass`); the IPv6 flow label (`flow`); and whether an IPv4
broadcast destination is allowed (`broadcast`, false unless given: a socket's
`SO_BROADCAST`, which `ip_output` reads as `IP_ALLOWBROADCAST`).
""".
-type opts() :: #{src => erx_net_addr:addr(), via => term(), ttl => 0..255, hlim => 0..255,
                  tos => 0..255, tclass => 0..255, flow => 0..16#fffff,
                  broadcast => boolean()}.

-doc """
The way to one destination. `iface` is the interface the frames leave through, `next_hop`
the address its link address is found for, and `link` either `{fixed, LinkAddr}` (a
broadcast or multicast address, or the zone on the loopback interface) or `neighbour`, when
the next hop's neighbour row gives it. `mtu` is the interface's MTU for IPv4 and its IPv6
link MTU for IPv6; `hlim` is the TTL or hop limit; `tos` the type of service or traffic
class, whose low two bits a TCP segment's ECN field replaces. `broadcast` says the
destination is an IPv4 broadcast address of the interface, which is never fragmented.
""".
-type path() :: #{family := inet | inet6, iface := iface(),
                  src := erx_net_addr:addr(), dst := erx_net_addr:addr(),
                  next_hop := erx_net_addr:addr(), link := {fixed, term()} | neighbour,
                  mtu := pos_integer(), hlim := 0..255, tos := 0..255, flow := 0..16#fffff,
                  broadcast := boolean()}.

-doc """
An IP packet, as `erx_ip4:output/4` and `erx_ip6:output/4` build it, or a TCP segment's
packet with its checksum delayed (`delayed()`).
""".
-type packet() :: iodata() | delayed() | run().

-doc """
An Ethernet frame, a delayed segment's Ethernet frame, or on the loopback interface a
packet with its zone.
""".
-type frame() :: iodata() | delayed() | run() | {Zone :: term(), packet()}.

-doc """
Bytes holding a TCP segment whose checksum is delayed: the segment starts at byte `Start`,
and its checksum field, which holds the pseudo-header's sum, at byte `Start + Field`.
""".
-type delayed() :: {csum, Start :: non_neg_integer(), Field :: non_neg_integer(), iodata()}.

-doc "A run of TCP segments (erx_net_frame.hrl), cut by `cut/1` or by the driver's transport.".
-type run() :: #run{}.

-doc "A connection's template cache (`tcp/4`): none yet, or the last template with its key.".
-type template_cache() :: none | {term(), binary()}.

%% --- The configuration --------------------------------------------------------

-doc """
The configuration of the rows read from `erx_net_ifs`, `erx_net_addrs` and
`erx_net_routes`. An address row (`erx_net_addr:published()`) or route row
(`erx_net_route:published()`) is kept only when the pid it carries is the pid of its
interface's row; the addresses are kept in the order their interfaces added them.
""".
-spec snapshot([iface()], [erx_net_addr:published()], [erx_net_route:published()]) ->
          snapshot().
snapshot(Ifs, Addrs, Routes) ->
    ByName = maps:from_list([{Name, If} || #{name := Name} = If <- Ifs]),
    Current = fun(Ifname, Pid) ->
                      case ByName of
                          #{Ifname := #{pid := Pid}} -> true;
                          #{} -> false
                      end
              end,
    Ordered = lists:sort([{Order, Ifname, Row}
                          || {Pid, Order, #{ifname := Ifname} = Row} <- Addrs,
                             Current(Ifname, Pid)]),
    Table = lists:foldl(fun erx_net_route:put/2, erx_net_route:new(),
                        [Row || {Pid, #{ifname := Ifname} = Row} <- Routes, Current(Ifname, Pid)]),
    #{ifs => ByName, addrs => [Row || {_, _, Row} <- Ordered], routes => Table}.

-doc """
The stack's addresses in a snapshot, every interface's, the loopback interface's
included, in the order their interfaces added them: the addresses the weak end-system
model of `ip_input` accepts a packet to on any interface (`ip_input.c:696-720`, with
`ip_strong_es` off by default).
""".
-spec addresses(snapshot()) -> [erx_net_addr:addr()].
addresses(#{addrs := Addrs}) ->
    [Addr || #{addr := Addr} <- Addrs].

-doc """
Whether Addr, zoned as a key holds it, is one of the stack's addresses in the snapshot,
compared with its zone, as `in_localip` and `in6_localip` decide it (`in.c:154-166`,
`in6.c:1844-1859`): the addresses a path reaches through the loopback interface.
""".
-spec is_own(zoned(), snapshot()) -> boolean().
is_own(Addr, #{addrs := Addrs} = Snap) ->
    case destination(Addr, #{}, Snap) of
        {ok, Dst, Zone} -> own(Dst, Zone, Addrs) =/= none;
        {error, _} -> false
    end.

%% --- Paths --------------------------------------------------------------------

-doc """
The path to Dst under Opts over the configuration, or `enetunreach` when no interface
leads there and `eaddrnotavail` when the interface has no usable source address
(`in_pcbladdr`, `in6_selectsrc`). An IPv4 broadcast destination is `eaddrnotavail` on
the loopback interface, which cannot broadcast, and `eacces` unless Opts allow it
(`ip_output.c:661-668`). The interface is the first of these that applies:

* the loopback interface for an address of the stack, compared with its zone;
* `via` for a multicast destination or the limited broadcast, and an interface- or
  link-local multicast's zone, without a route;
* the route `erx_net_route:lookup/2` gives, or `lookup/3` on the zone's interface for a
  zoned destination.

A scoped IPv6 address without its zone leads nowhere, except `::1`, which is the loopback
interface's, and a multicast sent `via` an interface, which takes that zone. A zone that
contradicts `via` leads nowhere either, so nothing a peer sends can steer a path to
another interface.
""".
-spec path(zoned(), opts(), snapshot()) ->
          {ok, path()} | {error, enetunreach | eaddrnotavail | eacces}.
path(Dst0, Opts, #{} = Snap) when is_map(Opts) ->
    maybe
        {ok, Dst, Zone} ?= destination(Dst0, Opts, Snap),
        {ok, Way} ?= way(Dst, Zone, Opts, Snap),
        ok ?= allowed(Way, Opts),
        {ok, Src} ?= source(Dst, Way, Opts, Snap),
        {ok, header(Dst, Src, Way, Opts)}
    else
        {error, _} = Error -> Error
    end;
path(_Dst, _Opts, _Snap) ->
    {error, enetunreach}.

%% The destination's bytes and zone: an interface name for a scoped IPv6 address, `none`
%% for every other.
destination({<<_:128>> = Addr, Ifname}, Opts, _Snap) ->
    case scoped(Addr) of
        false -> {ok, Addr, none};
        true ->
            case Opts of
                #{via := Via} when Via =/= Ifname -> {error, enetunreach};
                #{} -> {ok, Addr, Ifname}
            end
    end;
destination(<<_:32>> = Addr, _Opts, _Snap) ->
    {ok, Addr, none};
destination(<<_:128>> = Addr, Opts, #{ifs := Ifs}) ->
    Multicast = erx_net_addr:is_multicast(Addr),
    case {scoped(Addr), Opts} of
        {false, _} -> {ok, Addr, none};
        {true, #{via := Via}} when Multicast -> {ok, Addr, Via};
        {true, _} when Addr =:= <<1:128>> -> loopback_zone(Addr, Ifs);
        {true, _} -> {error, enetunreach}
    end;
destination(_Dst, _Opts, _Snap) ->
    {error, enetunreach}.

%% Interface-local (1) or link-local (2) scope: the scopes whose zone is an interface
%% (erx_net_addr:zone/2).
scoped(Addr) -> erx_net_addr:scope(Addr) =< 2.

loopback_zone(Addr, Ifs) ->
    case loopback(Ifs) of
        {ok, #{name := Name}} -> {ok, Addr, Name};
        error -> {error, enetunreach}
    end.

loopback(Ifs) ->
    case [If || #{link := none} = If <- maps:values(Ifs)] of
        [If | _] -> {ok, If};
        [] -> error
    end.

%% How the packets leave: through which interface, to which next hop, with which link
%% address, and which interface's addresses the source is chosen among.
way(Dst, Zone, Opts, #{ifs := Ifs, addrs := Addrs, routes := Routes}) ->
    case own(Dst, Zone, Addrs) of
        {ok, Owner} ->
            maybe
                {ok, Lo} ?= ok_or(loopback(Ifs), enetunreach),
                {ok, #{iface => Lo, next_hop => Dst, link => {fixed, Owner}, out => Owner,
                       loopback => true, broadcast => false}}
            end;
        none ->
            Unrouted = erx_net_addr:is_multicast(Dst) orelse Dst =:= <<16#ffffffff:32>>,
            Named = case Zone of
                        none -> maps:get(via, Opts, none);
                        _ -> Zone
                    end,
            case Unrouted andalso Named =/= none of
                true -> unrouted(Dst, Named, Ifs);
                false -> routed(Dst, Zone, Ifs, Addrs, Routes)
            end
    end.

%% The interface that owns Dst as an address of the stack, compared with its zone.
own(Dst, Zone, Addrs) ->
    case [If || #{addr := A, ifname := If} <- Addrs, A =:= Dst, Zone =:= none orelse If =:= Zone] of
        [Owner | _] -> {ok, Owner};
        [] -> none
    end.

%% Interface-local multicast never leaves the node: on Ethernet it leads nowhere
%% (ip6_output.c:929-933).
unrouted(<<16#ff, _:4, 1:4, _:112>>, Ifname, Ifs)
  when map_get(link, map_get(Ifname, Ifs)) =:= ethernet ->
    {error, enetunreach};
unrouted(Dst, Ifname, Ifs) ->
    case Ifs of
        #{Ifname := If} ->
            {ok, #{iface => If, next_hop => Dst, link => {fixed, link_addr(If, Dst)}, out => Ifname,
                   loopback => false, broadcast => Dst =:= <<16#ffffffff:32>>}};
        #{} ->
            {error, enetunreach}
    end.

routed(Dst, Zone, Ifs, Addrs, Routes) ->
    Lookup = case Zone of
                 none -> erx_net_route:lookup(Dst, Routes);
                 _ -> erx_net_route:lookup(Dst, Zone, Routes)
             end,
    case Lookup of
        {ok, #{ifname := Ifname, gateway := Gateway}} when is_map_key(Ifname, Ifs) ->
            If = map_get(Ifname, Ifs),
            Broadcast = byte_size(Dst) =:= 4 andalso erx_net_addr:is_broadcast(Dst, Ifname, Addrs),
            Link = if
                       Broadcast -> {fixed, link_addr(If, <<16#ffffffff:32>>)};
                       true -> case erx_net_addr:is_multicast(Dst) of
                                   true -> {fixed, link_addr(If, Dst)};
                                   false -> unicast_link(If)
                               end
                   end,
            %% Only a next hop addressed by its neighbour row is the gateway; a broadcast
            %% or multicast link address is fixed by the destination itself.
            Hop = case {Link, Gateway} of
                      {neighbour, <<_/binary>>} -> Gateway;
                      _ -> Dst
                  end,
            {ok, #{iface => If, next_hop => Hop, link => Link, out => Ifname, loopback => false,
                   broadcast => Broadcast}};
        _ ->
            {error, enetunreach}
    end.

%% A broadcast leaves only an interface that can broadcast, and only when the sender
%% allows it (ip_output.c:661-668); the loopback interface has no IFF_BROADCAST.
allowed(#{broadcast := false}, _Opts) -> ok;
allowed(#{iface := #{link := none}}, _Opts) -> {error, eaddrnotavail};
allowed(#{}, #{broadcast := true}) -> ok;
allowed(#{}, #{}) -> {error, eacces}.

%% A unicast next hop on Ethernet is addressed by its neighbour row; on the loopback
%% interface the link header is the interface's own name.
unicast_link(#{link := ethernet}) -> neighbour;
unicast_link(#{link := none, name := Name}) -> {fixed, Name}.

%% The fixed link address of a broadcast or multicast destination (arpresolve_addr,
%% ETHER_MAP_IP_MULTICAST and ETHER_MAP_IPV6_MULTICAST), or on the loopback interface its
%% name.
link_addr(#{link := none, name := Name}, _Dst) -> Name;
link_addr(#{link := ethernet}, <<16#ffffffff:32>>) -> ?ETHER_BROADCAST;
link_addr(#{link := ethernet}, <<_:9, Low:23>>) -> <<16#01005e:24, 0:1, Low:23>>;
link_addr(#{link := ethernet}, <<_:96, Low:32>>) -> <<16#3333:16, Low:32>>.

%% The source: the one given, else for the loopback interface IPv4's own destination, else
%% in6_selectsrc over the outgoing interface for IPv6, and for IPv4 that interface's
%% address whose prefix holds the next hop, else its first. A given scoped source must be
%% an address of the outgoing interface, so no link-local source leaves its zone
%% (ip6_output.c:824-854).
source(Dst, #{out := Out}, #{src := Src}, #{addrs := Addrs}) ->
    SameFamily = byte_size(Src) =:= byte_size(Dst),
    InZone = byte_size(Src) =/= 16 orelse not scoped(Src)
        orelse lists:any(fun(#{addr := A, ifname := If}) -> A =:= Src andalso If =:= Out end, Addrs),
    case SameFamily andalso InZone of
        true -> {ok, Src};
        false -> {error, eaddrnotavail}
    end;
source(<<_:32>> = Dst, #{loopback := true}, _Opts, _Snap) ->
    {ok, Dst};
source(<<_:128>> = Dst, #{out := Out}, _Opts, #{addrs := Addrs}) ->
    case erx_in6_src:select(Dst, Out, Addrs) of
        {ok, #{addr := Src}} -> {ok, Src};
        {error, eaddrnotavail} = Error -> Error
    end;
source(<<_:32>>, #{out := Out, next_hop := Hop}, _Opts, #{addrs := Addrs}) ->
    Own = [Row || #{addr := <<_:32>>, ifname := If} = Row <- Addrs, If =:= Out],
    case [A || #{addr := A, plen := Plen} <- Own,
               erx_net_addr:masked(A, Plen) =:= erx_net_addr:masked(Hop, Plen)] ++
         [A || #{addr := A} <- Own] of
        [Src | _] -> {ok, Src};
        [] -> {error, eaddrnotavail}
    end.

header(Dst, Src, #{iface := If, next_hop := Hop, link := Link, broadcast := Broadcast}, Opts) ->
    Multicast = erx_net_addr:is_multicast(Dst),
    {Family, Mtu, HlimKey, TosKey, Default} =
        case byte_size(Dst) of
            4 -> {inet, map_get(mtu, If), ttl, tos, ?IPDEFTTL};
            16 -> {inet6, map_get(mtu6, If), hlim, tclass, map_get(hlim, If)}
        end,
    Hlim = case Opts of
               #{HlimKey := Given} -> Given;
               #{} when Multicast -> ?MULTICAST_HLIM;
               #{} -> Default
           end,
    #{family => Family, iface => If, src => Src, dst => Dst, next_hop => Hop, link => Link,
      mtu => Mtu, hlim => Hlim, tos => maps:get(TosKey, Opts, 0), flow => maps:get(flow, Opts, 0),
      broadcast => Broadcast}.

ok_or({ok, _} = Ok, _Reason) -> Ok;
ok_or(error, Reason) -> {error, Reason}.

%% --- Packets ------------------------------------------------------------------

-doc """
The packets of a connection's segments over Path, with the identification generator
advanced: each segment encoded over the path's pseudo-header, its ECN field in the low
bits of the type of service or traffic class and don't-fragment as it says. `emsgsize`
when any segment is over 65535 bytes or IP refuses it, and then no packet is returned.
A segment's checksum is delayed when the path's interface has a finisher and IP sends
the segment whole, and finished here otherwise.

A run, an `erx_tcp:outgoing()` with `seg` in its marks, is one `#run{}` packet over the
template its headers share (`template/2`) when the interface has a finisher, which then
cuts it, and the packets of `cut/1` otherwise; either way the bytes are those of its
segments encoded one by one. A run whose headers no template holds, whose full frames IP
would not send whole, or which with its headers is over 65535 bytes goes as its segments.
""".
-spec tcp(path(), [erx_tcp:outgoing()], erx_net_rand:gen()) ->
          {ok, [packet()], erx_net_rand:gen()} | {error, emsgsize}.
tcp(Path, Segments, Gen0) ->
    case tcp(Path, Segments, Gen0, no_template()) of
        {ok, Packets, Gen, _Cache} -> {ok, Packets, Gen};
        {error, emsgsize} = Error -> Error
    end.

-doc """
As `tcp/3`, with the template cache a connection keeps between calls ("The header
template"): the template is built again only when the path, the ports, the ECN field or
the timestamps' presence differ from those it was built for. A connection keeps its path
until the configuration generation moves, so the path compares as the same term.
""".
-spec tcp(path(), [erx_tcp:outgoing()], erx_net_rand:gen(), template_cache()) ->
          {ok, [packet()], erx_net_rand:gen(), template_cache()} | {error, emsgsize}.
tcp(Path, Segments, Gen, Cache) ->
    tcp_each(Path, Segments, Gen, Cache, []).

tcp_each(_Path, [], Gen, Cache, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), Gen, Cache};
tcp_each(Path, [{_, #{seg := Seg}, _} = Segment | Segments], Gen, Cache0, Acc)
  when is_integer(Seg), Seg > 0 ->
    case run(Path, Segment, Cache0) of
        {ok, Packets, Cache} -> tcp_each(Path, Segments, Gen, Cache, [Packets | Acc]);
        segments -> tcp_each(Path, segments(Segment) ++ Segments, Gen, Cache0, Acc)
    end;
tcp_each(Path, [Segment | Segments], Gen0, Cache, Acc) ->
    case segment(Path, Segment, Gen0) of
        {ok, Packets, Gen} -> tcp_each(Path, Segments, Gen, Cache, [Packets | Acc]);
        {error, emsgsize} = Error -> Error
    end.

-doc "A template cache that holds no template yet.".
-spec no_template() -> template_cache().
no_template() -> none.

%% A run's packets, or `segments` when it goes as its segments: its options are not a
%% run's, a full frame does not fit the MTU (where IPv4 under don't-fragment refuses it and
%% IPv6 fragments it), or the run with its headers does not fit one IP packet. So the
%% bytes are always those of per-segment encoding. (IPv6 fragments a multicast packet at
%% 1280 bytes whatever the MTU, but TCP sends none.)
run(#{mtu := Mtu, iface := #{finish := Finish}} = Path,
    {#tcp{seq = Seq, ack = Ack, flags = Flags, win = Win, urp = 0, opts = Opts}, #{seg := Seg},
     Payload} = Segment, Cache0) ->
    case cached_template(Path, Segment, Cache0) of
        {ok, Template, Cache} when byte_size(Template) + Seg =< Mtu,
                                   length(Payload) =< ?RUN_PIECES ->
            Run = #run{template = Template, seq = Seq, ack = Ack, flags = Flags, win = Win,
                       ts = Opts#tcp_opts.ts, seg = Seg, payload = Payload},
            case {byte_size(Template) + iolist_size(Payload) =< ?IP_MAXPACKET, Finish} of
                {false, _} -> segments;
                {true, none} -> {ok, cut(Run), Cache};
                {true, _} -> {ok, [Run], Cache}
            end;
        _ ->
            segments
    end;
run(_Path, _Segment, _Cache) ->
    segments.

%% The key is everything template/2 reads, the timestamp values aside, which it does not
%% store, so a cached template is the one template/2 would build.
cached_template(Path, {#tcp{sport = Sport, dport = Dport, opts = #tcp_opts{ts = Ts} = Opts},
                       #{ecn := Ecn, df := Df}, _} = Segment, Cache) ->
    Key = {Path, Sport, Dport, Ecn, Df, Opts#tcp_opts{ts = Ts =/= none}},
    case Cache of
        {Key, Template} ->
            {ok, Template, Cache};
        _ ->
            case template(Path, Segment) of
                {ok, Template} -> {ok, Template, {Key, Template}};
                none -> none
            end
    end.

-doc """
The IP and TCP headers every frame of a run of Segment over Path shares, with each field
the cut stores zero: the IP length, the IPv4 header checksum, the sequence and
acknowledgement numbers, the flags, the window, the checksum, the urgent
pointer and the timestamp values. An IPv4 template carries don't-fragment and
identification zero, as `erx_ip4:output/4` sends a segment under don't-fragment. `none`
when Segment's options are not a run's, the timestamps alone or none, or when it is IPv4
without don't-fragment.
""".
-spec template(path(), erx_tcp:outgoing()) -> {ok, binary()} | none.
template(#{family := Family, src := Src, dst := Dst, hlim := Hlim, tos := Tos} = Path,
         {#tcp{sport = Sport, dport = Dport, opts = Opts}, #{ecn := Ecn, df := Df}, _}) ->
    Tclass = tos(Tos, Ecn),
    Tcp = case Opts of
              #tcp_opts{mss = none, wscale = none, sack_permitted = false, ts = none,
                        sacks = []} ->
                  {ok, <<Sport:16, Dport:16, 0:64, 5:4, 0:60>>};
              #tcp_opts{mss = none, wscale = none, sack_permitted = false, ts = {_, _},
                        sacks = []} ->
                  {ok, <<Sport:16, Dport:16, 0:64, 8:4, 0:60, ?TS_LEAD, 0:64>>};
              #tcp_opts{} ->
                  none
          end,
    case {Family, Df, Tcp} of
        {_, _, none} ->
            none;
        {inet, true, {ok, Header}} ->
            {ok, <<4:4, 5:4, Tclass, 0:16, 0:16, 0:1, 1:1, 0:14, Hlim, ?IPPROTO_TCP, 0:16,
                   Src/binary, Dst/binary, Header/binary>>};
        {inet, false, _} ->
            none;
        {inet6, _, {ok, Header}} ->
            #{flow := Flow} = Path,
            {ok, <<6:4, Tclass, Flow:20, 0:16, ?IPPROTO_TCP, Hlim, Src/binary, Dst/binary,
                   Header/binary>>}
    end.

-doc """
The frames of Run, as per-segment encoding gives them, with Run's link header in front and
every checksum finished: the reference a native cut is judged by, and the cut of every
transport that cuts nothing itself. Frame i is the template with the fields the cut
stores written, the payload slice `slices/2` gives it, its IP length and IPv4 header
checksum, and its TCP checksum over the pseudo-header with the frame's TCP length, as
`erx_tcp_wire:encode/4` and the IP encoders compute them.
""".
-spec cut(run()) -> [iodata()].
cut(#run{link = Link, template = Template, seq = Seq, ack = Ack, flags = Flags, win = Win,
         ts = Ts, seg = Seg, payload = Payload}) ->
    {Ip, Pseudo, <<Sport:16, Dport:16, _:64, Off:4, _:28, _:32, Opts/binary>>} =
        template_ip(Template),
    Options = case {Opts, Ts} of
                  {<<>>, none} -> <<>>;
                  {<<?TS_LEAD, _:64>>, {TsVal, TsEcr}} -> <<?TS_LEAD, TsVal:32, TsEcr:32>>
              end,
    Tail = <<0:16, Options/binary>>,
    Slices = slices(Payload, Seg),
    Last = length(Slices) - 1,
    [begin
         Len = Off * 4 + iolist_size(Slice),
         Head = <<Sport:16, Dport:16, ((Seq + I * Seg) band 16#ffffffff):32, Ack:32, Off:4,
                  (frame_flags(I, Last, Flags)):12, Win:16>>,
         Sum = bnot erx_bytes:inet_csum(Pseudo, [<<Len:16>>, Head, Tail, Slice]) band 16#ffff,
         [Link, Ip(Len), Head, <<Sum:16>>, Tail | Slice]
     end || {I, Slice} <- lists:enumerate(0, Slices)].

%% PSH and FIN ride only on a run's last frame.
frame_flags(Last, Last, Flags) -> Flags;
frame_flags(_I, _Last, Flags) -> Flags band bnot (?TH_PUSH bor ?TH_FIN).

%% A template's IP header as a function of the TCP length, the pseudo-header's sum without
%% the length, and the template's TCP header.
template_ip(<<4:4, 5:4, Tos, _Len:16, IdFrag:32, Ttl, Proto, _Sum:16, Src:4/binary, Dst:4/binary,
     Tcp/binary>>) ->
    Ip = fun(TcpLen) ->
                 Head = <<4:4, 5:4, Tos, (?IP_HDR_LEN + TcpLen):16, IdFrag:32, Ttl, Proto>>,
                 Sum = bnot erx_bytes:inet_csum(0, [Head, Src, Dst]) band 16#ffff,
                 <<Head/binary, Sum:16, Src/binary, Dst/binary>>
         end,
    {Ip, erx_ip4_wire:pseudo_sum(Src, Dst, 0, Proto), Tcp};
template_ip(<<6:4, ClassFlow:28, _Plen:16, Proto, Hlim, Src:16/binary, Dst:16/binary, Tcp/binary>>) ->
    Ip = fun(TcpLen) ->
                 <<6:4, ClassFlow:28, TcpLen:16, Proto, Hlim, Src/binary, Dst/binary>>
         end,
    {Ip, erx_ip6_wire:pseudo_sum(Src, Dst, 0, Proto), Tcp}.

%% The payload slices of a run's frames: Seg bytes each but the last, which holds the rest,
%% at least one byte; one empty slice for a run without payload.
slices(Payload, Seg) -> slices(Payload, Seg, iolist_size(Payload)).

slices(Payload, Seg, Left) when Left =< Seg ->
    [Payload];
slices(Payload, Seg, Left) ->
    {Slice, Rest} = split(Payload, Seg),
    [Slice | slices(Rest, Seg, Left - Seg)].

%% The first N bytes of a list of binaries, and the rest, as sub-binaries.
split(Bins, N) -> split(Bins, N, []).

split(Rest, 0, Acc) ->
    {lists:reverse(Acc), Rest};
split([Bin | Bins], N, Acc) when byte_size(Bin) =< N ->
    split(Bins, N - byte_size(Bin), [Bin | Acc]);
split([Bin | Bins], N, Acc) ->
    <<Head:N/binary, Tail/binary>> = Bin,
    {lists:reverse([Head | Acc]), [Tail | Bins]}.

%% The segments a run stands for, encoded one by one when the run cannot go whole.
segments({#tcp{seq = Seq, flags = Flags} = Header, #{seg := Seg} = Marks0, Payload}) ->
    Marks = maps:remove(seg, Marks0),
    Slices = slices(Payload, Seg),
    Last = length(Slices) - 1,
    [{Header#tcp{seq = (Seq + I * Seg) band 16#ffffffff, flags = frame_flags(I, Last, Flags)},
      Marks, Slice}
     || {I, Slice} <- lists:enumerate(0, Slices)].

-doc """
Run less its first N frames, 0 < N < `frames(Run)`: the sequence number advanced by
`N * seg` modulo 2^32 and the payload starting `N * seg` bytes later, so its frames are
the last frames of Run (`cut/1`). A transport that took N frames of a run leaves the tail
in the driver's backlog.
""".
-spec run_tail(run(), pos_integer()) -> run().
run_tail(#run{seq = Seq, seg = Seg, payload = Payload} = Run, N) when is_integer(N), N > 0 ->
    true = N < frames(Run),
    {_Taken, Rest} = split(Payload, N * Seg),
    Run#run{seq = (Seq + N * Seg) band 16#ffffffff, payload = Rest}.

-doc """
The frames a frame or packet stands for, which the transmit credit counts: a run's, at
least one, and one for anything else.
""".
-spec frames(frame() | packet()) -> pos_integer().
frames(#run{seg = Seg, payload = Payload}) -> max(1, (iolist_size(Payload) + Seg - 1) div Seg);
frames(_Frame) -> 1.

-doc "The frames a list of frames or packets stands for, each counted as `frames/1` counts it.".
-spec units([frame() | packet()]) -> non_neg_integer().
units(Frames) -> lists:foldl(fun(Frame, N) -> N + frames(Frame) end, 0, Frames).

segment(#{iface := #{finish := Finish}} = Path, {#tcp{opts = Opts}, _, Payload} = Segment, Gen) ->
    Len = ?TCP_HDR_LEN + erx_tcp_wire:optlen(Opts) + iolist_size(Payload),
    if
        Len > ?IP_MAXPACKET -> {error, emsgsize};
        Finish =:= none -> packets(Path, Segment, sender, Gen);
        true -> delayed(Path, Segment, Len, Gen)
    end.

%% IP fragments a datagram over the MTU into two fragments at least, so a segment that comes
%% back as one packet went whole, with the segment at its end: its checksum stays delayed.
%% A fragmented one is encoded again with its checksum finished, from the same generator.
delayed(Path, Segment, Len, Gen0) ->
    case packets(Path, Segment, driver, Gen0) of
        {ok, [Packet], Gen} ->
            {ok, [{csum, iolist_size(Packet) - Len, ?TCP_SUM_OFFSET, Packet}], Gen};
        {ok, _Fragments, _} ->
            packets(Path, Segment, sender, Gen0);
        {error, emsgsize} = Error ->
            Error
    end.

packets(#{tos := Tos} = Path, {Header, #{ecn := Ecn, df := Df}, Payload}, SummedBy, Gen) ->
    Encoded = erx_tcp_wire:encode(Header, Payload, pseudo_sum(Path, ?IPPROTO_TCP), SummedBy),
    output(Path, ?IPPROTO_TCP, Encoded, tos(Tos, Ecn), Df, Gen).

%% A segment's type of service or traffic class: the path's, its ECN field the segment's.
tos(Tos, Ecn) -> (Tos band 16#fc) bor Ecn.

-doc """
The packets of a UDP datagram from port Sport to port Dport over Path, fragmented when
it is over the MTU (`udp_output`, `ip_output`). `emsgsize` when it is over 65535 bytes,
or over the MTU to a broadcast destination, which is never fragmented
(`ip_output.c:669-673`).
""".
-spec udp(path(), 0..16#ffff, 0..16#ffff, iodata(), erx_net_rand:gen()) ->
          {ok, [packet()], erx_net_rand:gen()} | {error, emsgsize}.
udp(#{tos := Tos} = Path, Sport, Dport, Payload, Gen) ->
    case ?UDP_HDR_LEN + iolist_size(Payload) =< ?IP_MAXPACKET of
        true ->
            Datagram = erx_udp_wire:encode(#udp{sport = Sport, dport = Dport}, Payload,
                                           pseudo_sum(Path, ?IPPROTO_UDP)),
            output(Path, ?IPPROTO_UDP, Datagram, Tos, false, Gen);
        false ->
            {error, emsgsize}
    end.

-doc """
The packets of a datagram of protocol Proto over Path, whose payload, an ICMP message
among them, the caller encoded; `emsgsize` as for `udp/5`.
""".
-spec ip(path(), 0..255, iodata(), erx_net_rand:gen()) ->
          {ok, [packet()], erx_net_rand:gen()} | {error, emsgsize}.
ip(#{tos := Tos} = Path, Proto, Payload, Gen) ->
    output(Path, Proto, Payload, Tos, false, Gen).

pseudo_sum(#{family := inet, src := Src, dst := Dst}, Proto) ->
    erx_ip4_wire:pseudo_sum(Src, Dst, 0, Proto);
pseudo_sum(#{family := inet6, src := Src, dst := Dst}, Proto) ->
    erx_ip6_wire:pseudo_sum(Src, Dst, 0, Proto).

output(#{family := inet, src := Src, dst := Dst, hlim := Ttl, mtu := Mtu, broadcast := Broadcast},
       Proto, Payload, Tos, Df, Gen) ->
    case Broadcast andalso ?IP_HDR_LEN + iolist_size(Payload) > Mtu of
        true ->
            {error, emsgsize};
        false ->
            erx_ip4:output(#{src => Src, dst => Dst, proto => Proto, ttl => Ttl, tos => Tos,
                             df => Df}, Payload, Mtu, Gen)
    end;
output(#{family := inet6, src := Src, dst := Dst, hlim := Hlim, flow := Flow, mtu := Mtu}, Proto,
       Payload, Tclass, Df, Gen) ->
    erx_ip6:output(#{src => Src, dst => Dst, proto => Proto, hlim => Hlim, tclass => Tclass,
                     flow => Flow, df => Df}, Payload, Mtu, Gen).

%% --- Frames -------------------------------------------------------------------

-doc """
The frames of Packets over Path: with the path's fixed link address, or with the
link-layer address of the next hop's neighbour row, which may be `fresh` or `stale`; with
no row the packets go back as `resolve`, for the interface to resolve the next hop.
""".
-spec address(path(), none | {term(), fresh | stale}, [packet()]) ->
          {send, [frame()]} | {resolve, [packet()]}.
address(#{link := {fixed, LinkAddr}, iface := If}, _Neighbour, Packets) ->
    {send, link(If, LinkAddr, Packets)};
address(#{link := neighbour}, none, Packets) ->
    {resolve, lists:flatmap(fun held/1, Packets)};
address(#{link := neighbour, iface := If}, {LinkAddr, _Freshness}, Packets) ->
    {send, link(If, LinkAddr, Packets)}.

-doc """
The frames of IP Packets on interface If to link address LinkAddr: an Ethernet header from
the interface's address, with the EtherType of each packet's IP version, in front of it,
a delayed packet's `Start` moved past the header and a run's link header set; on the
loopback interface, each finished packet with LinkAddr as its zone, a run's cut, since
nothing below the loopback finishes or cuts.
""".
-spec link(iface(), term(), [packet()]) -> [frame()].
link(#{link := ethernet, lladdr := Src}, <<_:48>> = Dst, Packets) ->
    [ethernet(erx_net_eth:encode(#eth{dst = Dst, src = Src, type = ethertype(P)}), P)
     || P <- Packets];
link(#{link := none}, Zone, Packets) ->
    [{Zone, Finished} || P <- Packets, Finished <- finished(P)].

%% A packet as resolution holds it: a run as its packets, so the neighbour's hold, which
%% counts packets, keeps the segments per-segment output would have kept.
held(#run{} = Run) -> cut(Run);
held(Packet) -> [Packet].

%% The finished packets a packet stands for.
finished({csum, _Start, _Field, _Packet} = Delayed) -> [finish(Delayed)];
finished(#run{} = Run) -> cut(Run);
finished(Packet) -> [Packet].

ethernet(Header, #run{} = Run) ->
    Run#run{link = Header};
ethernet(Header, {csum, Start, Field, Packet}) ->
    {csum, byte_size(Header) + Start, Field, [Header, Packet]};
ethernet(Header, Packet) ->
    [Header, Packet].

ethertype(#run{template = Template}) ->
    ethertype(Template);
ethertype({csum, _Start, _Field, Packet}) ->
    ethertype(Packet);
ethertype(Packet) ->
    case first_byte(Packet) of
        <<6:4, _:4>> -> ?ETHERTYPE_IPV6;
        <<4:4, _:4>> -> ?ETHERTYPE_IP
    end.

first_byte(<<Byte:1/binary, _/binary>>) -> Byte;
first_byte([Byte | _]) when is_integer(Byte) -> <<Byte>>;
first_byte([Head | Tail]) ->
    case first_byte(Head) of
        none -> first_byte(Tail);
        Byte -> Byte
    end;
first_byte(_) -> none.

-doc """
The bytes of a delayed frame with its checksum finished, as a transport that finishes
checksums puts them on its medium: the sum of the bytes from `Start` to the end, the field
included, complemented into the field. Raises `badarg` when the frame is not
`finishable/2`.
""".
-spec finish(delayed()) -> binary().
finish({csum, Start, Field, Frame} = Delayed) ->
    Bytes = iolist_to_binary(Frame),
    finishable(Delayed, byte_size(Bytes)) orelse error(badarg),
    <<Head:Start/binary, Summed/binary>> = Bytes,
    <<Before:Field/binary, _:16, After/binary>> = Summed,
    Sum = bnot erx_bytes:inet_csum(0, Summed) band 16#ffff,
    <<Head/binary, Before/binary, Sum:16, After/binary>>;
finish(_) ->
    error(badarg).

-doc """
Whether a delayed frame of `Size` bytes can be finished: `Start` and `Field` even and the
field inside the frame. A transport that finishes drops a frame that is not as
`malformed` before it reaches the copy, whose own check refuses it as `badarg`.
""".
-spec finishable(delayed(), non_neg_integer()) -> boolean().
finishable({csum, Start, Field, _Frame}, Size) ->
    ?IS_EVEN(Start) andalso ?IS_EVEN(Field) andalso Start + Field + 2 =< Size.
