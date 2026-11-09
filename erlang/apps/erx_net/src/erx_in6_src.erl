%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
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
%% $KAME: in6_src.c,v 1.132 2003/08/26 04:42:27 keiichi Exp $

-module(erx_in6_src).
-moduledoc """
IPv6 source address selection, RFC 6724 section 5, translated from
`in6_selectsrc` of FreeBSD's in6_src.c at the commit NOTICE-freebsd records
(docs/design-network-stack.md, "IPv6, neighbour discovery and
autoconfiguration").

`select/4` takes the destination, the outgoing interface the route lookup
chose, the rows of the address table and the time, and returns the row
whose address is the source. It walks the rows in order as FreeBSD walks
its address list, keeping the best so far: a candidate replaces it or is
passed over by the first of these rules that tells them apart, and a
candidate no rule tells apart is passed over.

* Unusable rows are skipped: not IPv6, tentative, duplicated, anycast or
  detached, or whose address or the destination would leave its zone
  (an interface- or link-local address on another interface than the
  outgoing one). Deprecated addresses stay candidates, as FreeBSD's
  default `ip6_use_deprecated` of 1 keeps them.
* Rule 1, the same address as the destination, ends the walk.
* Rule 2, the appropriate scope; rule 3, avoid deprecated addresses;
  rule 5, prefer the outgoing interface; rule 6, prefer a label matching
  the destination's; rule 7, prefer public over temporary addresses;
  last, FreeBSD's rule 14, the longest prefix matching the destination.

Rule 4 (home addresses) is a TODO in FreeBSD too, and rules 8 to 10 rank
interfaces that are down, CARP's virtual addresses and `prefer_source`,
none of which this stack has. Rule 7 follows FreeBSD's default
`ip6_prefer_tempaddr` of 0, which prefers public addresses where RFC 6724
prefers temporary ones.

The labels are those of RFC 6724's default policy table, the table
FreeBSD's `rc.d/ip6addrctl` installs at boot on a host with IPv6.
""".

-export([select/4, label/1]).

%% RFC 6724 section 2.1, longest prefixes first: {Prefix, Plen, Label}.

-define(POLICY, [{<<1:128>>, 128, 0},
                 {<<0:80, 16#ffff:16, 0:32>>, 96, 4},
                 {<<0:128>>, 96, 3},
                 {<<16#2001:16, 0:112>>, 32, 5},
                 {<<16#2002:16, 0:112>>, 16, 2},
                 {<<16#3ffe:16, 0:112>>, 16, 12},
                 {<<16#fec0:16, 0:112>>, 10, 11},
                 {<<16#fc00:16, 0:112>>, 7, 13},
                 {<<0:128>>, 0, 1}]).

-doc """
The source for destination Dst leaving through interface OutIf, chosen
among Rows at time Now, or `{error, eaddrnotavail}` when no row is usable,
as `in6_selectsrc` fails.
""".
-spec select(erx_net_addr:addr6(), term(), [erx_net_addr:row()], integer()) ->
          {ok, erx_net_addr:row()} | {error, eaddrnotavail}.
select(<<_:128>> = Dst, OutIf, Rows, Now) ->
    Zone = erx_net_addr:zone(Dst, OutIf),
    Usable = [Row || Row <- Rows, usable(Row, Dst, Zone, OutIf)],
    walk(Usable, none, #{dst => Dst, out => OutIf, now => Now,
                         scope => erx_net_addr:scope(Dst), label => label(Dst)}).

usable(#{addr := <<_:128>> = Addr, ifname := If, flags := Flags}, Dst, Zone, OutIf) ->
    erx_net_addr:zone(Dst, If) =:= Zone
        andalso erx_net_addr:zone(Addr, OutIf) =:= erx_net_addr:zone(Addr, If)
        andalso not lists:any(fun(F) -> lists:member(F, Flags) end,
                              [tentative, duplicated, anycast, detached]);
usable(_Row, _Dst, _Zone, _OutIf) ->
    false.

walk([], none, _Ctx) ->
    {error, eaddrnotavail};
walk([], Best, _Ctx) ->
    {ok, Best};
walk([#{addr := Dst} = Row | _], _Best, #{dst := Dst}) ->
    {ok, Row};
walk([Row | Rows], none, Ctx) ->
    walk(Rows, Row, Ctx);
walk([Row | Rows], Best, Ctx) ->
    case prefer(Best, Row, Ctx) of
        candidate -> walk(Rows, Row, Ctx);
        best -> walk(Rows, Best, Ctx)
    end.

%% Which of the best row so far and a candidate the first rule that tells
%% them apart prefers; the best row when none does.
prefer(Best, Row, Ctx) ->
    Rules = [fun scope_rule/3, fun deprecated_rule/3, fun interface_rule/3,
             fun label_rule/3, fun temporary_rule/3, fun matchlen_rule/3],
    first_verdict(Rules, Best, Row, Ctx).

first_verdict([], _Best, _Row, _Ctx) ->
    best;
first_verdict([Rule | Rules], Best, Row, Ctx) ->
    case Rule(Best, Row, Ctx) of
        tie -> first_verdict(Rules, Best, Row, Ctx);
        Verdict -> Verdict
    end.

%% Rule 2: a scope smaller than the destination's loses to a larger one;
%% otherwise the smaller scope wins.
scope_rule(#{addr := B}, #{addr := C}, #{scope := D}) ->
    SB = erx_net_addr:scope(B),
    SC = erx_net_addr:scope(C),
    if
        SB < SC, SB < D -> candidate;
        SB < SC -> best;
        SC < SB, SC < D -> best;
        SC < SB -> candidate;
        true -> tie
    end.

%% Rule 3.
deprecated_rule(Best, Row, #{now := Now}) ->
    prefer_false(erx_net_addr:deprecated(Best, Now), erx_net_addr:deprecated(Row, Now)).

%% Rule 5.
interface_rule(#{ifname := B}, #{ifname := C}, #{out := Out}) ->
    prefer_false(B =/= Out, C =/= Out).

%% Rule 6.
label_rule(#{addr := B}, #{addr := C}, #{label := D}) ->
    prefer_false(label(B) =/= D, label(C) =/= D).

%% Rule 7, with ip6_prefer_tempaddr at 0.
temporary_rule(#{flags := B}, #{flags := C}, _Ctx) ->
    prefer_false(lists:member(temporary, B), lists:member(temporary, C)).

%% Rule 14.
matchlen_rule(#{addr := B}, #{addr := C}, #{dst := Dst}) ->
    MB = erx_net_addr:matchlen(B, Dst),
    MC = erx_net_addr:matchlen(C, Dst),
    if
        MB < MC -> candidate;
        MC < MB -> best;
        true -> tie
    end.

%% The verdict of a rule that prefers the row for which a property is false.
prefer_false(Same, Same) -> tie;
prefer_false(false, true) -> best;
prefer_false(true, false) -> candidate.

-doc "The label of Addr in RFC 6724's default policy table, by longest match.".
-spec label(erx_net_addr:addr6()) -> non_neg_integer().
label(Addr) ->
    hd([Label || {Prefix, Plen, Label} <- ?POLICY, erx_net_addr:masked(Addr, Plen) =:= Prefix]).
