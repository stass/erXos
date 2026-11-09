%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-3-Clause
%%
%% FreeBSD: sys/netinet6/nd6_nbr.c
%%
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

-module(erx_nd6_dad).
-moduledoc """
Duplicate address detection for the tentative addresses of one interface (RFC 4862 section
5.4, with RFC 7527's enhanced detection; docs/design-network-stack.md, "IPv6, neighbour
discovery and autoconfiguration"), translated from `nd6_dad_start`, `nd6_dad_stop`,
`nd6_dad_timer`, `nd6_dad_find`, `nd6_dad_ns_output`, `nd6_dad_ns_input` and
`nd6_dad_na_input` of FreeBSD's `sys/netinet6/nd6_nbr.c` and the delay of
`in6_broadcast_ifa` of `sys/netinet6/in6.c`, at commit 975e3605
(erlang/apps/erx_net/NOTICE-freebsd). The state is a pure value in the interface process's
state; `expired/3` returns the next state and the actions the process performs, in order.

`erx_nd6_rtr` forms an address tentative and asks for its detection (`{dad, Row}`); the
interface process calls `start/3`. After a random delay of up to a second, one neighbour
solicitation goes out from the unspecified address to the address's solicited-node group
(`ip6_dad_count`, 1), with a fresh 6-byte nonce, and one retransmission interval later the
detection decides. Messages about the address that `erx_nd6` hands on as `dad` actions go
to `input/2`. A solicitation for the address carrying the last probe's nonce is the
interface's own probe come back, as a looping link or a hub returns it (RFC 7527); any
other solicitation for it, or an advertisement of it, means another node uses or wants the
address.

The decision mirrors `nd6_dad_timer`:

* another node answered or probed: `{dad_done, Addr, duplicated}`;
* only the interface's own probes came back, more of them than at the last decision: two
  more probes (`nd6_mmaxtries` less one), then a new decision;
* otherwise: `{dad_done, Addr, ok}`.

The process hands the outcome to `erx_nd6_rtr:dad_done/3`, which clears the tentative flag
or marks the address duplicated. Like FreeBSD, the detection decides only at its end, where
RFC 4862 5.4.3 lets an implementation decide at the first answer, and it remembers only the
last probe's nonce. A link that returns every probe, or a host that echoes every nonce,
keeps the address tentative, one probe per retransmission interval, as in FreeBSD and RFC
7527; any host on the link can as well make the address duplicated with one advertisement.

Departures. Every detection starts after the random delay, where FreeBSD delays only
link-local addresses and those formed from a multicast router advertisement
(`IN6_IFAUPDATE_DADDELAY`): the delay costs an address formed from a solicited
advertisement up to a second, and keeps one rule. FreeBSD's lower bound for the delay, the
pending MLD report's timer, is counted in other units than its upper bound and is zero
under MLDv2, so the delay is drawn from the whole second here. The nonce is `none` until the
first probe goes out, where FreeBSD compares received nonces with its zero-filled buffer,
so a solicitation whose nonce is six zero bytes counts as looped back. The interface
process stops the detection of an address it removes (`stop/2`) and, as RFC 4862 5.4 asks
of an interface that is enabled again, of every tentative address when its link goes down,
and starts them again when the link comes up; FreeBSD instead keeps a detection running
while the interface is down, counting probes it cannot send (`dad_ns_tcount`,
`dad_maxtry`). RFC 4862 5.4.5's disabling of IPv6 when a link-local address formed from the
hardware address is duplicated does not arise: identifiers are RFC 7217's, never the
hardware address. Anycast addresses, which take no detection, are never started.

Time is milliseconds of the monotonic clock. Addresses are sixteen-byte binaries.
""".

-include("erx_ip6.hrl").

-export([new/1, start/3, stop/2, input/2, expired/3, next_deadline/1, probing/2]).

-export_type([dad/0, action/0]).

-define(IP6_DAD_COUNT, 1).                % ip6_dad_count, DupAddrDetectTransmits
-define(ND6_MMAXTRIES, 3).                % nd6_mmaxtries
-define(MAX_DELAY, 1000).                 % MAX_RTR_SOLICITATION_DELAY, in milliseconds
-define(NONCE_LEN, 6).                    % ND_OPT_NONCE_LEN
-define(UNSPECIFIED, <<0:128>>).

-doc """
What the interface process does: send a neighbour solicitation with a hop limit of 255, as
it sends `erx_nd6`'s; hand the outcome of a detection to `erx_nd6_rtr:dad_done/3`.
""".
-type action() :: {send_nd, Src :: <<_:128>>, Dst :: <<_:128>>, #icmp6{}}
                | {dad_done, Addr :: <<_:128>>, ok | duplicated}.

%% One detection, FreeBSD's struct dadq: `deadline' when expired/3 next looks at it;
%% `count' the probes to send (dad_count), `sent' those sent (dad_ns_ocount); `ns' and `na'
%% the solicitations and advertisements from other nodes (dad_ns_icount, dad_na_icount);
%% `looped' the probes that came back (dad_ns_lcount) and `looped_seen' their count when
%% probes were last extended (dad_loopbackprobe); `nonce' the last probe's.
-record(probe, {deadline :: integer(),
                count = ?IP6_DAD_COUNT :: pos_integer(),
                sent = 0 :: non_neg_integer(),
                ns = 0 :: non_neg_integer(),
                na = 0 :: non_neg_integer(),
                looped = 0 :: non_neg_integer(),
                looped_seen = 0 :: non_neg_integer(),
                nonce = none :: none | <<_:48>>}).

%% `probes' holds one detection per tentative address, at most one per address the
%% interface has; `gen' draws the delays and nonces.
-record(dad, {probes = #{} :: #{<<_:128>> => #probe{}},
              gen :: erx_net_rand:gen()}).

-opaque dad() :: #dad{}.

-doc """
No detection running, with its own generator `Gen`, which the interface splits from its
own.
""".
-spec new(erx_net_rand:gen()) -> dad().
new(Gen) ->
    #dad{gen = Gen}.

-doc """
Starts the detection of the tentative address `Addr` at `Now` (`nd6_dad_start`), its first
probe after a delay drawn uniformly up to a second (`in6_broadcast_ifa`). A detection
already running for `Addr` is left to finish.
""".
-spec start(<<_:128>>, integer(), dad()) -> dad().
start(Addr, _Now, #dad{probes = Probes} = D) when is_map_key(Addr, Probes) ->
    D;
start(<<_:128>> = Addr, Now, #dad{probes = Probes, gen = Gen} = D) ->
    {Delay, Gen1} = erx_net_rand:uniform(?MAX_DELAY, Gen),
    D#dad{probes = Probes#{Addr => #probe{deadline = Now + Delay}}, gen = Gen1}.

-doc "Ends the detection of `Addr`, if one is running, with no outcome (`nd6_dad_stop`).".
-spec stop(<<_:128>>, dad()) -> dad().
stop(Addr, #dad{probes = Probes} = D) ->
    D#dad{probes = maps:remove(Addr, Probes)}.

-doc "Whether a detection of `Addr` is running.".
-spec probing(<<_:128>>, dad()) -> boolean().
probing(Addr, #dad{probes = Probes}) ->
    is_map_key(Addr, Probes).

-doc """
A message about a tentative address of the interface, as `erx_nd6` hands it on in a `dad`
action: a solicitation from the unspecified address with its nonce option, or an
advertisement. A message for an address under no detection changes nothing.
""".
-spec input({ns, <<_:128>>, none | binary()} | {na, <<_:128>>}, dad()) -> dad().
input({ns, Addr, Nonce}, #dad{probes = Probes} = D) ->
    case Probes of
        #{Addr := #probe{nonce = Last} = P} when Last =/= none, Nonce =:= Last ->
            D#dad{probes = Probes#{Addr := P#probe{looped = P#probe.looped + 1}}};
        #{Addr := P} ->
            D#dad{probes = Probes#{Addr := P#probe{ns = P#probe.ns + 1}}};
        #{} ->
            D
    end;
input({na, Addr}, #dad{probes = Probes} = D) ->
    case Probes of
        #{Addr := P} -> D#dad{probes = Probes#{Addr := P#probe{na = P#probe.na + 1}}};
        #{} -> D
    end.

-doc """
Runs every detection whose deadline is at or before `Now` (`nd6_dad_timer`), in address
order; `Retrans` is the interface's retransmission interval in milliseconds. Each gives
one action, a probe or an outcome.
""".
-spec expired(integer(), pos_integer(), dad()) -> {dad(), [action()]}.
expired(Now, Retrans, #dad{probes = Probes} = D) ->
    Due = lists:sort([Addr || Addr := #probe{deadline = Deadline} <- Probes, Deadline =< Now]),
    {Actions, D1} = lists:mapfoldl(fun(Addr, Dn) -> timer(Addr, Now, Retrans, Dn) end, D, Due),
    {D1, Actions}.

-doc "The earliest deadline of any detection, or `infinity`.".
-spec next_deadline(dad()) -> integer() | infinity.
next_deadline(#dad{probes = Probes}) ->
    case [Deadline || _Addr := #probe{deadline = Deadline} <- Probes] of
        [] -> infinity;
        Deadlines -> lists:min(Deadlines)
    end.

%% nd6_dad_timer for one detection whose deadline has come: a probe while some remain to
%% send; then the decision, or more probes while looped-back probes keep coming.
timer(Addr, Now, Retrans, #dad{probes = Probes} = D) ->
    #{Addr := P} = Probes,
    if
        P#probe.sent < P#probe.count ->
            send(Addr, P, Now, Retrans, D);
        P#probe.ns > 0; P#probe.na > 0 ->
            {{dad_done, Addr, duplicated}, D#dad{probes = maps:remove(Addr, Probes)}};
        P#probe.looped > P#probe.looped_seen ->
            P1 = P#probe{looped_seen = P#probe.looped,
                         count = P#probe.sent + ?ND6_MMAXTRIES - 1},
            send(Addr, P1, Now, Retrans, D);
        true ->
            {{dad_done, Addr, ok}, D#dad{probes = maps:remove(Addr, Probes)}}
    end.

%% nd6_dad_ns_output: a probe with a fresh nonce from the unspecified address to the
%% address's solicited-node group, and the next look one retransmission interval later.
send(Addr, P, Now, Retrans, #dad{probes = Probes, gen = Gen} = D) ->
    {Nonce, Gen1} = erx_net_rand:bytes(?NONCE_LEN, Gen),
    P1 = P#probe{sent = P#probe.sent + 1, nonce = Nonce, deadline = Now + Retrans},
    Ns = #icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, Addr, #{nonce => Nonce}}},
    {{send_nd, ?UNSPECIFIED, solicited_node(Addr), Ns},
     D#dad{probes = Probes#{Addr := P1}, gen = Gen1}}.

solicited_node(<<_:104, Low:24>>) ->
    <<16#FF02:16, 0:64, 1:16, 16#FF:8, Low:24>>.
