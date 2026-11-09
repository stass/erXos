%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/in.c
%% Copyright (c) 1982, 1986, 1991, 1993
%% The Regents of the University of California.  All rights reserved.
%% Copyright (C) 2001 WIDE Project.  All rights reserved.
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
%% FreeBSD: sys/netinet6/in6.c
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
%% $KAME: in6.c,v 1.259 2002/01/21 11:37:50 keiichi Exp $
%%
%% Copyright (c) 1982, 1986, 1991, 1993
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
%% FreeBSD: sys/netinet6/scope6.c
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
%% $KAME: scope6.c,v 1.10 2000/07/24 13:29:31 itojun Exp $

-module(erx_net_addr).
-moduledoc """
The address checks of FreeBSD's in.c, in6.c and scope6.c at the commit
NOTICE-freebsd records (docs/design-network-stack.md, "Addresses and
routes"), over the rows of the address table.

An address is its bytes: 4 for IPv4, 16 for IPv6. Every function here is
pure and total over well-formed rows and addresses; a function that takes
an address of either family dispatches on its size.

A row is one address an interface process owns and publishes, keyed by
the interface (`row()`). A row carries the address's flags and no
lifetimes: the owner keeps the preferred and valid deadlines in its own
state (`deadline()`, milliseconds on its clock or `infinity`), sets
`deprecated` when the preferred one passes, as `nd6_timer` sets
`IN6_IFF_DEPRECATED`, and deletes the row when the valid one passes
(docs/design-network-stack.md, "What owners publish"). The table holds each
row with the pid of the interface incarnation that wrote it and the place
that interface added it in (`published()`).
""".

-export([is_unspecified/1, is_loopback/1, is_multicast/1, is_link_local/1,
         is_v4mapped/1, scope/1, zone/2, is_broadcast/3, is_local/2, is_on_link/2,
         masked/2, matchlen/2]).

-export_type([addr/0, addr4/0, addr6/0, row/0, published/0, flag/0, deadline/0, scope/0]).

-type addr4() :: <<_:32>>.
-type addr6() :: <<_:128>>.
-type addr() :: addr4() | addr6().

-type deadline() :: integer() | infinity.

-doc """
An address's state, after FreeBSD's `ia6_flags`: `tentative` while
duplicate address detection runs, `duplicated` once it found another
holder, `deprecated` once its preferred lifetime has passed, `anycast`,
`detached`, `temporary` (RFC 8981) and `autoconf` (formed from a router
advertisement's prefix).
""".
-type flag() :: tentative | duplicated | deprecated | anycast | detached | temporary
              | autoconf.

-doc """
A row of the address table: the address, its prefix length, the interface
that owns it and its flags. An IPv4 row may carry `broadcast`, the subnet's
broadcast address, as `ia_broadaddr` does on a broadcast interface.
""".
-type row() :: #{addr := addr(), plen := 0..128, ifname := term(),
                 flags := [flag()], broadcast => addr4()}.

-doc """
A row as `erx_net_addrs` holds it: the pid of the interface incarnation
that wrote it, the place that interface added it in (`if_addrhead`'s
order, which IPv4 source selection follows), and the row.
""".
-type published() :: {pid(), Order :: non_neg_integer(), row()}.

-doc """
An IPv6 scope, as scope6.c numbers them: 1 interface-local, 2 link-local,
5 site-local, 14 global, other values of a multicast address's scope
field as they are.
""".
-type scope() :: 0..15.

%% The zoned form of an address, which every table, view and key inside the
%% stack holds (docs/design-network-stack.md, "Zones").
-export([zoned/2]).
-export_type([zoned/0]).

-define(SCOPE_INTFACELOCAL, 1).
-define(SCOPE_LINKLOCAL, 2).
-define(SCOPE_SITELOCAL, 5).
-define(SCOPE_GLOBAL, 14).

-doc "`INADDR_ANY` or `IN6_IS_ADDR_UNSPECIFIED`.".
-spec is_unspecified(addr()) -> boolean().
is_unspecified(<<0:32>>) -> true;
is_unspecified(<<0:128>>) -> true;
is_unspecified(_) -> false.

-doc "`IN_LOOPBACK` (127/8) or `IN6_IS_ADDR_LOOPBACK` (::1).".
-spec is_loopback(addr()) -> boolean().
is_loopback(<<127, _:24>>) -> true;
is_loopback(<<1:128>>) -> true;
is_loopback(_) -> false.

-doc "`IN_MULTICAST` (224/4) or `IN6_IS_ADDR_MULTICAST` (ff00::/8).".
-spec is_multicast(addr()) -> boolean().
is_multicast(<<14:4, _:28>>) -> true;
is_multicast(<<16#ff, _:120>>) -> true;
is_multicast(_) -> false.

-doc "`IN6_IS_ADDR_LINKLOCAL` (fe80::/10); false for IPv4.".
-spec is_link_local(addr()) -> boolean().
is_link_local(<<16#3fa:10, _:118>>) -> true;
is_link_local(_) -> false.

-doc "`IN6_IS_ADDR_V4MAPPED` (::ffff:0:0/96); false for IPv4.".
-spec is_v4mapped(addr()) -> boolean().
is_v4mapped(<<0:80, 16#ffff:16, _:32>>) -> true;
is_v4mapped(_) -> false.

-doc """
The scope of an IPv6 address, as `in6_addrscope` gives it: a multicast
address's scope field (15, reserved, counting as global), link-local for
fe80::/10 and the loopback address, site-local for fec0::/10, global
otherwise.
""".
-spec scope(addr6()) -> scope().
scope(<<16#ff, _:4, 16#f:4, _:112>>) -> ?SCOPE_GLOBAL;
scope(<<16#ff, _:4, Scope:4, _:112>>) -> Scope;
scope(<<16#3fa:10, _:118>>) -> ?SCOPE_LINKLOCAL;
scope(<<1:128>>) -> ?SCOPE_LINKLOCAL;
scope(<<16#3fb:10, _:118>>) -> ?SCOPE_SITELOCAL;
scope(<<_:128>>) -> ?SCOPE_GLOBAL.

-doc """
The zone an IPv6 address belongs to when used on interface Ifname, as
`in6_setscope` assigns it: the interface for an address of interface- or
link-local scope, since each interface is its own link, and one zone,
`global`, for every other scope, as the default scope-id list gives it.
""".
-spec zone(addr6(), term()) -> term().
zone(Addr, Ifname) ->
    case scope(Addr) of
        ?SCOPE_INTFACELOCAL -> {ifname, Ifname};
        ?SCOPE_LINKLOCAL -> {ifname, Ifname};
        _ -> global
    end.

-doc """
Whether IPv4 address Addr is a broadcast address on interface Ifname,
whose rows are among Rows, as `in_ifnet_broadcast` decides it: the limited
broadcast and `INADDR_ANY` always (`in_broadcast`), and the broadcast
address of one of the interface's rows whose mask is not all ones
(`in_ifaddr_broadcast`, with FreeBSD's default of no host-zero
broadcast).
""".
-spec is_broadcast(addr4(), term(), [row()]) -> boolean().
is_broadcast(<<16#ffffffff:32>>, _Ifname, _Rows) -> true;
is_broadcast(<<0:32>>, _Ifname, _Rows) -> true;
is_broadcast(<<_:32>> = Addr, Ifname, Rows) ->
    lists:any(fun(#{ifname := If, plen := Plen, broadcast := Broadcast}) ->
                      If =:= Ifname andalso Plen < 32 andalso Broadcast =:= Addr;
                 (_) -> false
              end, Rows).

-doc """
Whether Addr is one of the host's addresses, as `in_localip` and
`in6_localip` decide it.
""".
-spec is_local(addr(), [row()]) -> boolean().
is_local(Addr, Rows) ->
    lists:any(fun(#{addr := A}) -> A =:= Addr end, Rows).

-doc """
Whether Addr lies on a link the host is attached to, as `in_localaddr` and
`in6_localaddr` decide it: within the prefix of one of the rows of its
family, or for IPv6 a loopback or link-local address.
""".
-spec is_on_link(addr(), [row()]) -> boolean().
is_on_link(Addr, Rows) ->
    is_loopback(Addr) andalso byte_size(Addr) =:= 16
        orelse is_link_local(Addr)
        orelse lists:any(fun(#{addr := A, plen := Plen}) ->
                                 byte_size(A) =:= byte_size(Addr)
                                     andalso Plen =< bit_size(A)
                                     andalso masked(A, Plen) =:= masked(Addr, Plen)
                         end, Rows).

-doc "Addr with every bit past its first Plen cleared.".
-spec masked(addr(), non_neg_integer()) -> addr().
masked(Addr, Plen) when Plen >= bit_size(Addr) ->
    Addr;
masked(Addr, Plen) ->
    Rest = bit_size(Addr) - Plen,
    <<Prefix:Plen/bits, _:Rest>> = Addr,
    <<Prefix/bits, 0:Rest>>.

-doc "The number of leading bits A and B share, as `in6_matchlen` counts them.".
-spec matchlen(addr(), addr()) -> non_neg_integer().
matchlen(A, B) when byte_size(A) =:= byte_size(B) ->
    Bits = bit_size(A),
    <<X:Bits>> = A,
    <<Y:Bits>> = B,
    case X bxor Y of
        0 -> Bits;
        Diff -> Bits - bit_length(Diff)
    end.

bit_length(N) -> bit_length(N, 0).
bit_length(0, Len) -> Len;
bit_length(N, Len) -> bit_length(N bsr 1, Len + 1).


-doc """
An address as the stack holds it inside: an IPv6 address of link-local or
interface-local scope, unicast or multicast, with the name of the interface
it belongs to, as FreeBSD embeds the zone in the address (`in6_setscope`);
every other address its bytes alone.
""".
-type zoned() :: addr() | {addr6(), Ifname :: term()}.

-doc """
Addr in the zone of interface Ifname: the pair for an address that `zone/2`
puts in the interface's zone, the address itself otherwise.
""".
-spec zoned(addr(), term()) -> zoned().
zoned(<<_:128>> = Addr, Ifname) ->
    case zone(Addr, Ifname) of
        {ifname, _} -> {Addr, Ifname};
        global -> Addr
    end;
zoned(<<_:32>> = Addr, _Ifname) ->
    Addr.
