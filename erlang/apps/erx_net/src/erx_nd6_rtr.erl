%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/nd6_rtr.c
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
%% $KAME: nd6_rtr.c,v 1.111 2001/04/27 01:37:15 jinmei Exp $
%%
%% FreeBSD: sys/netinet6/in6_ifattach.c
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
%% $KAME: in6_ifattach.c,v 1.118 2001/05/24 07:44:00 itojun Exp $
%%
%% FreeBSD: sys/netinet6/nd6.c
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
%% $KAME: nd6.c,v 1.144 2001/05/24 07:44:00 itojun Exp $
%%
%% FreeBSD: sys/netinet6/nd6_nbr.c
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
%% $KAME: nd6_nbr.c,v 1.86 2002/01/21 02:33:04 jinmei Exp $

-module(erx_nd6_rtr).
-moduledoc """
Routers, prefixes and stateless address autoconfiguration (RFC 4861,
RFC 4862) for one interface, translated from FreeBSD's nd6_rtr.c and
in6_ifattach.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "IPv6, neighbour discovery and
autoconfiguration"). The interface process keeps one state and hands it
router advertisements that erx_icmp6_wire decoded, the answers to its
interface-identifier requests, the outcomes of duplicate address
detection and the clock; each of those steps returns the actions the
process performs (`action()`) and the next state. `dad_done/3` and
`select_router/2` return only the next state, and the process reads
what to publish from `addresses/1` and `routes/1` and when to call
`tick/2` from `next_deadline/1` after each step.

What it keeps:

* The default-router list, at most 16 routers, ordered by preference and,
  within one preference, by arrival, as `defrtrlist_update` orders it.
  `select_router/2` picks the router the default route uses, as
  `defrouter_select_fib` does, from the neighbour cache's reachability.
* The prefix list, at most 16 prefixes, with their on-link and autonomous
  flags and valid lifetimes (`prelist_update`). An expired prefix stays,
  off link, while an address formed from it lives, as `nd6_timer` keeps
  it while `ndpr_addrcnt` is not zero.
* The addresses it formed: the link-local address, and one address per
  autonomous /64 prefix, with RFC 4862's rule that an advertisement
  lowers a remaining valid lifetime only down to two hours.
* The link's parameters an advertisement sets: base and current
  reachable time, retransmission timer, hop limit and MTU.

A router advertisement or prefix that would grow a list past its bound is
ignored and counted, and listed entries keep refreshing, a departure from
FreeBSD for requirement N4 that the design states.

Interface identifiers are RFC 7217's (`in6_get_stableifid`). The secret
never enters this module: it asks for the HMAC-SHA-256 of a message
(`{ifid_request, Ref, Message}`), which the vault's key facet computes,
and `ifid/4` takes the digest. The message is FreeBSD's without the
secret, which is the HMAC key: the prefix's bytes, the interface's name,
the duplicate-address-detection failures as 8 little-endian bytes and an
offset byte. A digest whose first 8 bytes are a reserved identifier
(`validate_ifid`) asks again with the next offset. While the vault is
unavailable, `ifid_unavailable/3` forms the address from random bytes of
the state's generator and returns `{random_ifid, Prefix}` for the log.

Router solicitations follow RFC 4861 section 6.3.7: after a random delay
of up to one second, at most 3, 4 seconds apart, stopping once an
advertisement with a router lifetime arrives. FreeBSD leaves them to
`rtsold`.

Times are milliseconds on the caller's clock; lifetimes on the wire are
seconds, 0xffffffff meaning infinity.
""".

-include("erx_ip6.hrl").

-export([new/1, start/2, ra/4, ifid/4, ifid_unavailable/3, dad_done/3, tick/2,
         next_deadline/1, select_router/2, addresses/1, routes/1, routers/1,
         prefixes/1, params/1, stats/1]).

-export_type([state/0, action/0, ref/0, packet/0, address/0]).

-define(MAX_ROUTERS, 16).
-define(MAX_PREFIXES, 16).
-define(INFINITE, 16#ffffffff).
-define(TWOHOUR, 7200).
-define(MAX_REACHABLE_TIME, 3600000).
-define(REACHABLE_TIME, 30000).
-define(RETRANS_TIMER, 1000).
-define(IPV6_DEFHLIM, 64).
-define(IPV6_MMTU, 1280).
-define(MAX_RTR_SOLICITATION_DELAY, 1000).
-define(RTR_SOLICITATION_INTERVAL, 4000).
-define(MAX_RTR_SOLICITATIONS, 3).
-define(STABLEADDR_MAXRETRIES, 3).
-define(IFID_OFFSETS, 255).
-define(ETHER_ADDR_LEN, 6).
-define(ND_RA_FLAG_RTPREF_MASK, 16#18).
-define(ND_OPT_PI_FLAG_ONLINK, 16#80).
-define(ND_OPT_PI_FLAG_AUTO, 16#40).
-define(LINK_LOCAL, <<16#fe80:16, 0:112>>).

-doc """
What the interface process does for a step: send a router solicitation;
ask the vault for the HMAC of Message and answer with `ifid/4` under Ref;
start duplicate address detection of a new address (erx_nd6); hand
erx_nd6 the router's link-layer address (`none` when the advertisement
carried none), as `nd6_cache_lladdr` takes it; log that an address was
formed from a random identifier.
""".
-type action() :: send_rs
                | {ifid_request, ref(), Message :: binary()}
                | {dad, address()}
                | {cache_lladdr, Router :: erx_net_addr:addr6(), binary() | none}
                | {random_ifid, Prefix :: erx_net_addr:addr6()}.

-doc """
An address the interface formed: the fields of its row of the address table, and its
preferred and valid deadlines, which stay here (docs/design-network-stack.md, "What owners
publish").
""".
-type address() :: #{addr := erx_net_addr:addr6(), plen := 0..128, ifname := term(),
                     flags := [erx_net_addr:flag()], preferred := erx_net_addr:deadline(),
                     valid := erx_net_addr:deadline()}.

-doc "An identifier request: the /64 prefix it is for and the offset tried.".
-type ref() :: {Prefix :: erx_net_addr:addr6(), Offset :: 0..254}.

-doc """
The IPv6 header fields of a router advertisement: its source, destination
and hop limit, and whether it arrived in fragments (RFC 6980).
""".
-type packet() :: #{src := erx_net_addr:addr6(), dst := erx_net_addr:addr6(),
                    hlim := 0..255, fragmented := boolean()}.

-type router() :: #{addr := erx_net_addr:addr6(), pref := -1..1, flags := 0..255,
                    expire := integer()}.

-type prefix() :: #{prefix := erx_net_addr:addr6(), plen := 0..128, onlink := boolean(),
                    auto := boolean(), valid := erx_net_addr:deadline()}.

-opaque state() :: #{ifname := binary(), if_mtu := pos_integer(),
                     gen := erx_net_rand:gen(),
                     routers := [router()], installed := erx_net_addr:addr6() | none,
                     prefixes := [prefix()], addrs := [address()],
                     pending := #{erx_net_addr:addr6() =>
                                      {erx_net_addr:deadline(), erx_net_addr:deadline()}},
                     failures := non_neg_integer(),
                     params := #{atom() => non_neg_integer()},
                     rs_left := non_neg_integer(), rs_next := integer() | none,
                     stats := #{atom() => non_neg_integer()}}.

%% --- Lifecycle ------------------------------------------------------------

-doc """
The state of interface Ifname (its name as the bytes the identifier
message hashes), whose link MTU is IfMtu, drawing from Gen. Its
parameters are `nd6_ifattach`'s defaults, the reachable time drawn from
the base.
""".
-spec new(#{ifname := binary(), if_mtu := pos_integer(), gen := erx_net_rand:gen()}) -> state().
new(#{ifname := Ifname, if_mtu := IfMtu, gen := Gen0}) when is_binary(Ifname) ->
    {Reachable, Gen} = reachable(?REACHABLE_TIME, Gen0),
    #{ifname => Ifname, if_mtu => IfMtu, gen => Gen,
      routers => [], installed => none, prefixes => [], addrs => [], pending => #{},
      failures => 0,
      params => #{base_reachable => ?REACHABLE_TIME, reachable => Reachable,
                  retrans => ?RETRANS_TIMER, cur_hlim => ?IPV6_DEFHLIM, link_mtu => IfMtu},
      rs_left => 0, rs_next => none,
      stats => #{bad_ra => 0, routers_ignored => 0, prefixes_ignored => 0,
                 ifid_exhausted => 0}}.

-doc """
Brings the interface up at Now: asks for the link-local address's
identifier and schedules the first router solicitation.
""".
-spec start(integer(), state()) -> {[action()], state()}.
start(Now, #{gen := Gen0} = S) ->
    {Delay, Gen} = erx_net_rand:uniform(?MAX_RTR_SOLICITATION_DELAY + 1, Gen0),
    request(?LINK_LOCAL, infinity, infinity,
            S#{gen := Gen, rs_left := ?MAX_RTR_SOLICITATIONS, rs_next := Now + Delay}).

%% --- Router advertisements --------------------------------------------------

-doc """
Takes a router advertisement, its header fields Pkt and its decoded
message, at Now, as `nd6_ra_input` takes it. One that arrived in
fragments is ignored; one with a hop limit other than 255 or a source
that is not link-local is counted as `bad_ra` and dropped.
""".
-spec ra(packet(), erx_icmp6_wire:msg(), integer(), state()) -> {[action()], state()}.
ra(#{fragmented := true}, _Ra, _Now, S) ->
    {[], S};
ra(#{hlim := Hlim}, _Ra, _Now, S) when Hlim =/= 255 ->
    {[], count(bad_ra, S)};
ra(#{src := Src}, {ra, CurHop, Flags, Lifetime, Reachable, Retrans, Opts}, Now, S0) ->
    case erx_net_addr:is_link_local(Src) of
        false ->
            {[], count(bad_ra, S0)};
        true ->
            S1 = router_update(Src, Flags, Lifetime, Now, S0),
            S2 = link_params(Reachable, Retrans, CurHop, S1),
            {Actions, S3} = lists:foldl(fun(Pi, Acc) -> prefix_info(Pi, Now, Acc) end,
                                        {[], S2}, maps:get(prefixes, Opts, [])),
            S4 = link_mtu(maps:get(mtu, Opts, none), S3),
            lladdr(Src, maps:get(slla, Opts, none), lists:reverse(Actions), S4)
    end.

%% defrtrlist_update: a lifetime of zero removes the router; a listed
%% router is refreshed and, unless it is installed with an unchanged
%% preference, moved to the end of its preference group; a new router
%% joins at the end of its group while the list has room.
router_update(Src, _Flags, 0, _Now, #{routers := Routers} = S) ->
    S#{routers := [R || #{addr := A} = R <- Routers, A =/= Src]};
router_update(Src, Flags, Lifetime, Now, #{routers := Routers, installed := Installed} = S0) ->
    S = S0#{rs_left := 0, rs_next := none},
    New = #{addr => Src, pref => rtpref(Flags), flags => Flags, expire => Now + Lifetime * 1000},
    case lists:partition(fun(#{addr := A}) -> A =:= Src end, Routers) of
        {[#{pref := Pref}], _} when Installed =:= Src, Pref =:= map_get(pref, New) ->
            S#{routers := [replace_router(R, New) || R <- Routers]};
        {[_], Rest} ->
            S#{routers := insert_router(New, Rest)};
        {[], _} when length(Routers) >= ?MAX_ROUTERS ->
            count(routers_ignored, S);
        {[], _} ->
            S#{routers := insert_router(New, Routers)}
    end.

replace_router(#{addr := A}, #{addr := A} = New) -> New;
replace_router(R, _New) -> R.

insert_router(#{pref := P} = New, Routers) ->
    {Before, After} = lists:splitwith(fun(#{pref := Q}) -> P =< Q end, Routers),
    Before ++ [New | After].

%% rtpref: the reserved value counts as medium.
rtpref(Flags) ->
    case Flags band ?ND_RA_FLAG_RTPREF_MASK of
        16#08 -> 1;
        16#18 -> -1;
        _ -> 0
    end.

%% The reachable time, retransmission timer and hop limit of
%% nd6_ra_input: a base reachable time within MAX_REACHABLE_TIME that
%% differs draws a new reachable time; a hop limit only ever rises.
link_params(Reachable, Retrans, CurHop, #{params := P0, gen := Gen0} = S) ->
    {P1, Gen} = case Reachable of
                    0 -> {P0, Gen0};
                    _ when Reachable > ?MAX_REACHABLE_TIME -> {P0, Gen0};
                    _ when Reachable =:= map_get(base_reachable, P0) -> {P0, Gen0};
                    _ ->
                        {R, G} = reachable(Reachable, Gen0),
                        {P0#{base_reachable := Reachable, reachable := R}, G}
                end,
    P2 = case Retrans of
             0 -> P1;
             _ -> P1#{retrans := Retrans}
         end,
    P3 = case CurHop > map_get(cur_hlim, P2) of
             true -> P2#{cur_hlim := CurHop};
             false -> P2
         end,
    S#{params := P3, gen := Gen}.

%% ND_COMPUTE_RTIME's interval, half to one and a half times the base,
%% drawn uniformly.
reachable(Base, Gen) ->
    Low = Base div 2,
    {Draw, Gen2} = erx_net_rand:uniform(Base * 3 div 2 - Low + 1, Gen),
    {Low + Draw, Gen2}.

%% An MTU option within IPV6_MMTU and the interface's MTU sets the link MTU.
link_mtu(Mtu, #{if_mtu := IfMtu, params := P} = S) when is_integer(Mtu), Mtu >= ?IPV6_MMTU,
                                                         Mtu =< IfMtu ->
    S#{params := P#{link_mtu := Mtu}};
link_mtu(_Mtu, S) ->
    S.

%% The source link-layer address must have an Ethernet address's option
%% length; a wrong one counts the advertisement bad after its other
%% fields took effect, as nd6_ra_input orders it.
lladdr(_Src, LL, Actions, S) when is_binary(LL), byte_size(LL) =/= ?ETHER_ADDR_LEN ->
    {Actions, count(bad_ra, S)};
lladdr(Src, LL, Actions, S) ->
    {Actions ++ [{cache_lladdr, Src, LL}], S}.

%% --- Prefixes -------------------------------------------------------------

%% One prefix information option, as the loop of nd6_ra_input checks it
%% and prelist_update applies it.
prefix_info(#{len := Plen}, _Now, Acc) when Plen > 128 ->
    Acc;
prefix_info(#{prefix := Prefix0, len := Plen, flags := Flags, valid := Vl, preferred := Pl},
            Now, {Actions, S0}) ->
    Prefix = erx_net_addr:masked(Prefix0, Plen),
    case erx_net_addr:is_multicast(Prefix0) orelse erx_net_addr:is_link_local(Prefix0) of
        true ->
            {Actions, S0};
        false ->
            Onlink = Flags band ?ND_OPT_PI_FLAG_ONLINK =/= 0,
            Auto = Flags band ?ND_OPT_PI_FLAG_AUTO =/= 0,
            %% RFC 4862 section 5.5.3 (a) and (c): only an autonomous option
            %% whose preferred lifetime is within its valid one forms addresses.
            case prefix_update(Prefix, Plen, Onlink, Auto, Vl, Now, S0) of
                {listed, S1} when Auto, Pl =< Vl ->
                    autoconf(Prefix, Plen, Vl, Pl, Now, Actions, S1);
                {_, S1} ->
                    {Actions, S1}
            end
    end.

prefix_update(Prefix, Plen, Onlink, Auto, Vl, Now, #{prefixes := Prefixes} = S) ->
    case lists:partition(fun(P) -> same_prefix(P, Prefix, Plen) end, Prefixes) of
        {[Old], _} ->
            Updated = refresh(Old#{onlink := Onlink orelse map_get(onlink, Old),
                                   auto := Auto orelse map_get(auto, Old)},
                              Onlink, Vl, Now),
            {listed, S#{prefixes := [replace_prefix(P, Updated) || P <- Prefixes]}};
        {[], _} when Vl =:= 0; not Onlink andalso not Auto ->
            {ignored, S};
        {[], _} when length(Prefixes) >= ?MAX_PREFIXES ->
            {ignored, count(prefixes_ignored, S)};
        {[], _} ->
            New = #{prefix => Prefix, plen => Plen, onlink => Onlink, auto => Auto,
                    valid => deadline(Now, Vl)},
            Added = case Onlink of
                        true -> New;
                        false -> New#{valid := Now}
                    end,
            {listed, S#{prefixes := Prefixes ++ [Added]}}
    end.

%% An on-link option refreshes the prefix's lifetime; an autonomous-only
%% one leaves it.
refresh(P, true, Vl, Now) -> P#{valid := deadline(Now, Vl)};
refresh(P, false, _Vl, _Now) -> P.

replace_prefix(#{prefix := P, plen := L}, #{prefix := P, plen := L} = New) -> New;
replace_prefix(Old, _New) -> Old.

same_prefix(#{prefix := P, plen := L}, P, L) -> true;
same_prefix(_, _, _) -> false.

%% The address part of prelist_update: every autoconfigured address of
%% the prefix takes the new preferred lifetime and a valid lifetime by
%% RFC 4862 section 5.5.3 (e); with no usable address left and a valid
%% lifetime, a /64 prefix asks for a new identifier. A duplicated address
%% is not usable while failures remain within STABLEADDR_MAXRETRIES.
autoconf(Prefix, Plen, Vl, Pl, Now, Actions, #{addrs := Addrs, failures := Failures} = S) ->
    Refresh = fun(#{valid := V} = Row) ->
                      case autoconf_of(Row, Prefix, Plen) of
                          true -> Row#{valid := deadline(Now, valid_lifetime(remaining(V, Now), Vl)),
                                       preferred := deadline(Now, Pl)};
                          false -> Row
                      end
              end,
    Addrs2 = lists:map(Refresh, Addrs),
    Usable = [R || R <- Addrs2, autoconf_of(R, Prefix, Plen), usable(R, Failures)],
    S1 = S#{addrs := Addrs2},
    case Usable =:= [] andalso Vl =/= 0 andalso Plen =:= 64 of
        true ->
            {More, S2} = request(Prefix, deadline(Now, Vl), deadline(Now, Pl), S1),
            {lists:reverse(More, Actions), S2};
        false ->
            {Actions, S1}
    end.

%% Whether an address of the prefix counts as its address: a duplicated
%% one does not while retries remain, so that another is formed.
usable(#{flags := Flags}, Failures) ->
    Failures > ?STABLEADDR_MAXRETRIES orelse not lists:member(duplicated, Flags).

%% Whether Row is an address autoconfiguration formed in Prefix/Plen;
%% only a /64 forms addresses.
autoconf_of(#{addr := Addr, flags := Flags}, Prefix, Plen) ->
    Plen =:= 64 andalso lists:member(autoconf, Flags) andalso not lists:member(anycast, Flags)
        andalso erx_net_addr:masked(Addr, 64) =:= Prefix.

%% RFC 4862 section 5.5.3 (e) as prelist_update applies it, with no
%% authenticated advertisements: a new valid lifetime above two hours or
%% above the remaining one is taken; otherwise a remaining lifetime above
%% two hours drops to two hours and one within two hours stays.
valid_lifetime(Remaining, New) when New > ?TWOHOUR; Remaining < New -> New;
valid_lifetime(Remaining, _New) when Remaining =< ?TWOHOUR -> Remaining;
valid_lifetime(_Remaining, _New) -> ?TWOHOUR.

remaining(infinity, _Now) -> ?INFINITE;
remaining(Deadline, Now) -> max(0, (Deadline - Now) div 1000).

deadline(_Now, ?INFINITE) -> infinity;
deadline(Now, Secs) -> Now + Secs * 1000.

%% --- Interface identifiers ----------------------------------------------

%% Asks for the identifier of an address in Prefix, unless a request for
%% it is pending, whose lifetimes then become the latest advertised.
%% Every request must be answered with ifid/4 or ifid_unavailable/3.
request(Prefix, Valid, Preferred, #{pending := Pending} = S) when is_map_key(Prefix, Pending) ->
    {[], S#{pending := Pending#{Prefix := {Valid, Preferred}}}};
request(Prefix, Valid, Preferred, #{pending := Pending} = S) ->
    S1 = S#{pending := Pending#{Prefix => {Valid, Preferred}}},
    {[{ifid_request, {Prefix, 0}, message(Prefix, 0, S1)}], S1}.

message(<<Prefix:8/binary, _/binary>>, Offset, #{ifname := Ifname, failures := Failures}) ->
    <<Prefix/binary, Ifname/binary, Failures:64/little, Offset:8>>.

-doc """
Takes the HMAC-SHA-256 Digest the vault computed for request Ref at Now.
A digest naming a reserved identifier asks again with the next offset.
""".
-spec ifid(ref(), binary(), integer(), state()) -> {[action()], state()}.
ifid({Prefix, Offset} = Ref, <<Id:8/binary, _/binary>>, Now, #{pending := Pending} = S)
  when is_map_key(Prefix, Pending) ->
    case valid_ifid(Id) of
        true -> form_address(Ref, Id, Now, S);
        false when Offset + 1 < ?IFID_OFFSETS ->
            {[{ifid_request, {Prefix, Offset + 1}, message(Prefix, Offset + 1, S)}], S};
        false ->
            {[], count(ifid_exhausted, S#{pending := maps:remove(Prefix, Pending)})}
    end;
ifid(_Ref, _Digest, _Now, S) ->
    {[], S}.

-doc """
The vault could not answer request Ref: forms the address from random
bytes of the state's generator, as RFC 8981 forms a temporary
identifier.
""".
-spec ifid_unavailable(ref(), integer(), state()) -> {[action()], state()}.
ifid_unavailable({Prefix, _} = Ref, Now, #{pending := Pending, gen := Gen0} = S)
  when is_map_key(Prefix, Pending) ->
    {Id, Gen} = random_ifid(Gen0),
    {Actions, S2} = form_address(Ref, Id, Now, S#{gen := Gen}),
    {[{random_ifid, Prefix} | Actions], S2};
ifid_unavailable(_Ref, _Now, S) ->
    {[], S}.

random_ifid(Gen0) ->
    {Id, Gen} = erx_net_rand:bytes(8, Gen0),
    case valid_ifid(Id) of
        true -> {Id, Gen};
        false -> random_ifid(Gen)
    end.

%% validate_ifid: not all zero (RFC 4291's subnet-router anycast), not in
%% IANA's Ethernet block (02-00-5e-ff-fe), not a reserved subnet anycast
%% identifier (RFC 2526).
valid_ifid(<<0:64>>) -> false;
valid_ifid(<<16#02, 16#00, 16#5e, 16#ff, 16#fe, _:24>>) -> false;
valid_ifid(<<16#fdffffffffffff:56, Last>>) when Last >= 16#80 -> false;
valid_ifid(<<_:64>>) -> true.

%% in6_ifadd: the new address, tentative until duplicate address
%% detection passes. The prefix must still be listed (or be the
%% link-local prefix).
form_address({Prefix, _}, Id, Now, #{pending := Pending, prefixes := Prefixes, addrs := Addrs} = S) ->
    #{Prefix := {Valid, Preferred}} = Pending,
    S1 = S#{pending := maps:remove(Prefix, Pending)},
    Flags = case Prefix of
                ?LINK_LOCAL -> [tentative];
                _ -> [tentative, autoconf]
            end,
    Listed = Prefix =:= ?LINK_LOCAL orelse lists:any(fun(P) -> same_prefix(P, Prefix, 64) end, Prefixes),
    Expired = Valid =/= infinity andalso Valid < Now,
    case Listed andalso not Expired of
        true ->
            Row = #{addr => <<(binary_part(Prefix, 0, 8))/binary, Id/binary>>, plen => 64,
                    ifname => map_get(ifname, S), flags => Flags,
                    preferred => Preferred, valid => Valid},
            {[{dad, Row}], S1#{addrs := Addrs ++ [Row]}};
        false ->
            {[], S1}
    end.

-doc """
The outcome of duplicate address detection for Addr: `ok` clears its
tentative flag and resets the failure count, as `nd6_dad_timer` does;
`duplicated` marks it and counts a failure while they
are within STABLEADDR_MAXRETRIES, as `nd6_dad_duplicated` does, so the
next advertisement of its prefix forms another address.
""".
-spec dad_done(erx_net_addr:addr6(), ok | duplicated, state()) -> state().
dad_done(Addr, Outcome, #{addrs := Addrs, failures := Failures} = S) ->
    case lists:any(fun(#{addr := A}) -> A =:= Addr end, Addrs) of
        false ->
            S;
        true ->
            Mark = fun(#{addr := A, flags := F} = Row) when A =:= Addr ->
                           F1 = lists:delete(tentative, F),
                           Row#{flags := case Outcome of
                                             ok -> F1;
                                             duplicated -> [duplicated | F1]
                                         end};
                      (Row) -> Row
                   end,
            S1 = S#{addrs := lists:map(Mark, Addrs)},
            case Outcome of
                ok -> S1#{failures := 0};
                duplicated when Failures =< ?STABLEADDR_MAXRETRIES -> S1#{failures := Failures + 1};
                duplicated -> S1
            end
    end.

%% --- Time -----------------------------------------------------------------

-doc """
Advances to Now: sends a due router solicitation, removes routers and
addresses whose lifetime ended before Now (`nd6_defrouter_timer`,
`nd6_timer`), takes expired prefixes off link and removes those with
no address of theirs and no identifier request pending.
""".
-spec tick(integer(), state()) -> {[action()], state()}.
tick(Now, S0) ->
    {Actions, S1} = solicit(Now, S0),
    #{routers := Routers, addrs := Addrs, prefixes := Prefixes} = S1,
    Live = [R || #{expire := E} = R <- Routers, E >= Now],
    Addrs2 = [A || #{valid := V} = A <- Addrs, not passed(V, Now)],
    Prefixes2 = lists:filtermap(fun(P) -> expire_prefix(P, Addrs2, map_get(pending, S1), Now) end,
                                Prefixes),
    {Actions, S1#{routers := Live, addrs := Addrs2, prefixes := Prefixes2}}.

%% A prefix whose lifetime ended goes off link and stays only while an
%% address of its own lives or an identifier request for it is pending, as
%% nd6_timer keeps it while ndpr_addrcnt is not zero.
expire_prefix(#{prefix := Prefix, plen := Plen, valid := V} = P, Addrs, Pending, Now) ->
    case passed(V, Now) of
        false -> true;
        true ->
            Held = lists:any(fun(A) -> autoconf_of(A, Prefix, Plen) end, Addrs)
                orelse is_map_key(Prefix, Pending),
            Held andalso {true, P#{onlink := false}}
    end.

passed(infinity, _Now) -> false;
passed(Deadline, Now) -> Deadline < Now.

solicit(Now, #{rs_next := Next, rs_left := Left} = S) when is_integer(Next), Next =< Now ->
    case Left - 1 of
        0 -> {[send_rs], S#{rs_left := 0, rs_next := none}};
        More -> {[send_rs], S#{rs_left := More, rs_next := Now + ?RTR_SOLICITATION_INTERVAL}}
    end;
solicit(_Now, S) ->
    {[], S}.

-doc """
The earliest time `tick/2` has work: the next solicitation, or the
first moment after a router's, an address's or an on-link prefix's
lifetime; `none` when nothing is timed.
""".
-spec next_deadline(state()) -> integer() | none.
next_deadline(#{rs_next := Rs, routers := Routers, addrs := Addrs, prefixes := Prefixes}) ->
    Ends = [E + 1 || #{expire := E} <- Routers]
        ++ [V + 1 || #{valid := V} <- Addrs, V =/= infinity]
        ++ [V + 1 || #{valid := V, onlink := true} <- Prefixes, V =/= infinity],
    case [T || T <- [Rs | Ends], is_integer(T)] of
        [] -> none;
        Times -> lists:min(Times)
    end.

%% --- Router selection -----------------------------------------------------

-doc """
Chooses the router the default route uses, as `defrouter_select_fib`
does. The interface process calls it after every step that can change
the router list and whenever the neighbour cache's reachability of a
router changes; until then `routes/1` has no default route through a
router that left the list. The rule: the first reachable router in the list, unless the installed one
is reachable and not of lower preference; with none reachable, the one
after the installed router, round robin. IsReachable answers from the
neighbour cache.
""".
-spec select_router(fun((erx_net_addr:addr6()) -> boolean()), state()) -> state().
select_router(_IsReachable, #{routers := []} = S) ->
    S#{installed := none};
select_router(IsReachable, #{routers := Routers, installed := Installed0} = S) ->
    Installed = lists:search(fun(#{addr := A}) -> A =:= Installed0 end, Routers),
    Reachable = lists:search(fun(#{addr := A}) -> IsReachable(A) end, Routers),
    Selected = case {Reachable, Installed} of
                   %% None reachable: the router after the installed one.
                   {false, {value, I}} -> next_router(I, Routers);
                   {false, false} -> hd(Routers);
                   %% The installed router stays while reachable, unless the
                   %% first reachable one has a higher preference.
                   {{value, #{pref := P} = R}, {value, #{addr := IA, pref := IP} = I}} ->
                       case IsReachable(IA) andalso P =< IP of
                           true -> I;
                           false -> R
                       end;
                   {{value, R}, false} -> R
               end,
    S#{installed := map_get(addr, Selected)}.

next_router(Installed, Routers) ->
    case lists:dropwhile(fun(R) -> R =/= Installed end, Routers) of
        [_, Next | _] -> Next;
        _ -> hd(Routers)
    end.

%% --- Views ----------------------------------------------------------------

-doc """
The addresses the interface formed, each a row of the address table with the preferred
and valid deadlines its owner keeps, which the published row does not carry.
""".
-spec addresses(state()) -> [address()].
addresses(#{addrs := Addrs}) -> Addrs.

-doc """
The routes the interface learnt, as rows of the route table: the
link-local prefix and each on-link prefix directly on the link, and the
default route through the installed router.
""".
-spec routes(state()) -> [erx_net_route:row()].
routes(#{ifname := If, prefixes := Prefixes, routers := Routers, installed := Installed}) ->
    OnLink = [#{prefix => ?LINK_LOCAL, plen => 64, ifname => If, gateway => none, metric => 0}
              | [#{prefix => P, plen => L, ifname => If, gateway => none, metric => 0}
                 || #{prefix := P, plen := L, onlink := true} <- Prefixes]],
    case lists:any(fun(#{addr := A}) -> A =:= Installed end, Routers) of
        false -> OnLink;
        true -> OnLink ++ [#{prefix => <<0:128>>, plen => 0, ifname => If,
                               gateway => Installed, metric => 0}]
    end.

-doc "The default-router list, in order, for the inspector.".
-spec routers(state()) -> [router()].
routers(#{routers := Routers}) -> Routers.

-doc "The prefix list, for the inspector.".
-spec prefixes(state()) -> [prefix()].
prefixes(#{prefixes := Prefixes}) -> Prefixes.

-doc """
The link's parameters: base and current reachable time and
retransmission timer in milliseconds, hop limit and MTU.
""".
-spec params(state()) -> #{atom() => non_neg_integer()}.
params(#{params := P}) -> P.

-doc """
The counters: advertisements dropped as bad, routers and prefixes
ignored past their bounds, identifier requests that ran out of offsets.
""".
-spec stats(state()) -> #{atom() => non_neg_integer()}.
stats(#{stats := Stats}) -> Stats.

count(Key, #{stats := Stats} = S) -> S#{stats := maps:update_with(Key, fun(N) -> N + 1 end, Stats)}.
