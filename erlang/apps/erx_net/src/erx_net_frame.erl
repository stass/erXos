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
""".

-include("erx_net_eth.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_udp_wire.hrl").

-export([snapshot/3, path/3, tcp/3, udp/5, ip/4, address/3, link/3]).

-export_type([iface/0, zoned/0, snapshot/0, opts/0, path/0, packet/0, frame/0]).

-define(IPPROTO_TCP, 6).
-define(IPPROTO_UDP, 17).
-define(TCP_HDR_LEN, 20).
-define(UDP_HDR_LEN, 8).
-define(IP_MAXPACKET, 16#ffff).
-define(IP_HDR_LEN, 20).
%% IPDEFTTL (ip_var.h), and IP_DEFAULT_MULTICAST_TTL and ip6_defmcasthlim (in.h:535,
%% in6.h:521).
-define(IPDEFTTL, 64).
-define(MULTICAST_HLIM, 1).
-define(ETHER_BROADCAST, <<16#ffffffffffff:48>>).

-doc """
An interface's row of `erx_net_ifs`: its name; the pid of the incarnation that wrote it;
its link, `ethernet` or `none` for the loopback interface; its link-layer address; its MTU;
its IPv6 link MTU (`IN6_LINKMTU`); its IPv6 hop limit; and its driver's pid. The row's other
fields, its credits among them, pass through to the path untouched.
""".
-type iface() :: #{name := term(), pid := pid(), link := ethernet | none,
                   lladdr := <<_:48>> | none, mtu := pos_integer(), mtu6 := pos_integer(),
                   hlim := 0..255, driver := pid() | none, atom() => term()}.

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

-doc "An IP packet, as `erx_ip4:output/4` and `erx_ip6:output/4` build it.".
-type packet() :: iodata().

-doc "An Ethernet frame, or on the loopback interface a packet with its zone.".
-type frame() :: iodata() | {Zone :: term(), packet()}.

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
""".
-spec tcp(path(), [erx_tcp:outgoing()], erx_net_rand:gen()) ->
          {ok, [packet()], erx_net_rand:gen()} | {error, emsgsize}.
tcp(Path, Segments, Gen) ->
    each(fun(Segment, G) -> segment(Path, Segment, G) end, Segments, Gen).

segment(#{tos := Tos} = Path, {#tcp{opts = Opts} = Header, #{ecn := Ecn, df := Df}, Payload},
        Gen) ->
    case ?TCP_HDR_LEN + erx_tcp_wire:optlen(Opts) + iolist_size(Payload) =< ?IP_MAXPACKET of
        true ->
            Segment = erx_tcp_wire:encode(Header, Payload, pseudo_sum(Path, ?IPPROTO_TCP)),
            output(Path, ?IPPROTO_TCP, Segment, (Tos band 16#fc) bor Ecn, Df, Gen);
        false ->
            {error, emsgsize}
    end.

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

%% Fun over each item in order, threading the generator; the first refusal refuses all.
each(Fun, Items, Gen) -> each(Fun, Items, Gen, []).

each(_Fun, [], Gen, Acc) ->
    {ok, lists:append(lists:reverse(Acc)), Gen};
each(Fun, [Item | Items], Gen0, Acc) ->
    case Fun(Item, Gen0) of
        {ok, Packets, Gen} -> each(Fun, Items, Gen, [Packets | Acc]);
        {error, emsgsize} = Error -> Error
    end.

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
    {resolve, Packets};
address(#{link := neighbour, iface := If}, {LinkAddr, _Freshness}, Packets) ->
    {send, link(If, LinkAddr, Packets)}.

-doc """
The frames of IP Packets on interface If to link address LinkAddr: an Ethernet header from
the interface's address, with the EtherType of each packet's IP version, in front of it;
on the loopback interface, the packet with LinkAddr as its zone.
""".
-spec link(iface(), term(), [packet()]) -> [frame()].
link(#{link := ethernet, lladdr := Src}, <<_:48>> = Dst, Packets) ->
    [[erx_net_eth:encode(#eth{dst = Dst, src = Src, type = ethertype(P)}), P] || P <- Packets];
link(#{link := none}, Zone, Packets) ->
    [{Zone, P} || P <- Packets].

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
