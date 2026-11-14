%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp.h
%% Copyright (c) 1982, 1986, 1993
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
%% FreeBSD: sys/netinet/tcp_input.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1994, 1995
%% The Regents of the University of California.  All rights reserved.
%% Copyright (c) 2007-2008,2010
%% Swinburne University of Technology, Melbourne, Australia.
%% Copyright (c) 2009-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
%% All rights reserved.
%%
%% Portions of this software were developed at the Centre for Advanced Internet
%% Architectures, Swinburne University of Technology, by Lawrence Stewart,
%% James Healy and David Hayes, made possible in part by a grant from the Cisco
%% University Research Program Fund at Community Foundation Silicon Valley.
%%
%% Portions of this software were developed at the Centre for Advanced
%% Internet Architectures, Swinburne University of Technology, Melbourne,
%% Australia by David Hayes under sponsorship from the FreeBSD Foundation.
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
%% FreeBSD: sys/netinet/tcp_subr.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1995
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

-module(erx_tcp_mss).
-moduledoc """
The maximum segment size and the initial window (docs/design-network-stack.md, "Loss
detection and congestion control" and "ICMP and path MTU"), translated from `tcp_mss_update`,
`tcp_mss`, `tcp_mssopt` and `tcp_compute_initwnd` (sys/netinet/tcp_input.c), `tcp_maxseg`
(sys/netinet/tcp_subr.c) and the constants of sys/netinet/tcp.h, at the commit NOTICE-freebsd
records.

The path's MTU is the route's, which the caller looks up (FreeBSD's `tcp_maxmtu`, 0 when no
route is known); `CachedMtu` is the host cache's path MTU for the destination (`hc_mtu`), 0
when it has none, as the host cache is an extension the stack does not have yet
(design-network-stack.md, "Scope"). Path MTU discovery is always on and the stack has no UDP
encapsulation of TCP, so FreeBSD's branches for `path_mtu_discovery` off and for `t_port` are
not translated.
""".

-export([update/4, mtudisc/5, mss/5, mssopt/3, synack_mssopt/2, maxseg/2, initwnd/1,
         sack_prohibited/1]).

-export_type([family/0, offer/0, options/0]).

%% tcp.h: the default MSS of each family (tcp_mssdflt, tcp_v6mssdflt) and the least MSS a
%% peer may make us use (tcp_minmss).
-define(TCP_MSS, 536).
-define(TCP6_MSS, 1220).
-define(TCP_MINMSS, 216).
%% ip6.h: IPV6_MMTU, the least IPv6 MTU.
-define(IPV6_MMTU, 1280).
%% tcp_mss_update's floor under every MSS it computes.
-define(MSS_FLOOR, 64).
%% sizeof(struct tcpiphdr) and sizeof(struct ip6_hdr) + sizeof(struct tcphdr).
-define(MIN_PROTOH_INET, 40).
-define(MIN_PROTOH_INET6, 60).
%% tcp.h: option lengths, and the most option bytes a header holds.
-define(TCPOLEN_MAXSEG, 4).
-define(TCPOLEN_WINDOW, 3).
-define(TCPOLEN_SACK_PERMITTED, 2).
-define(TCPOLEN_SACKHDR, 2).
-define(TCPOLEN_SACK, 8).
-define(TCPOLEN_TSTAMP_APPA, 12).
-define(TCP_MAXOLEN, 40).
%% tcp_input.c: tcp_initcwnd_segments, RFC 6928's ten segments.
-define(TCP_INITCWND_SEGMENTS, 10).

-type family() :: inet | inet6.

-doc """
What the MSS is computed from: the MSS option of the peer's SYN as `erx_tcp_wire` gives it
(`none`, or 0, means the SYN carried none, and the family's default is assumed), or
`{mtu, Mtu}`, a path MTU an ICMP report gave (`tcp_mtudisc`'s `mtuoffer`). FreeBSD's offer of
-1, used before any SYN arrived by TCP Fast Open and implied connects, has no caller in the
stack and is not translated.
""".
-type offer() :: none | 0..16#ffff | {mtu, pos_integer()}.

-doc """
The options a segment of the connection would carry, for `maxseg/2`: `noopt` under
`TCP_NOOPT`; once synchronized, whether timestamps were negotiated and how many SACK blocks
the receiver reports (0 without SACK); during the handshake, whether the SYN asks for
timestamps, window scaling and SACK (the options the SYN requests).
""".
-type options() :: noopt
                 | {synchronized, Ts :: boolean(), SackBlocks :: non_neg_integer()}
                 | {handshake, Requested :: [ts | wscale | sack]}.

-doc """
The connection's MSS (`t_maxseg`) from an offer and the path (`tcp_mss_update`). With no
route the family's default; otherwise the path MTU, or the host cache's if smaller, less the
IP and TCP headers, no larger than the offer, which is raised to `tcp_minmss` (216) so a peer
cannot force tiny segments, and never below 64.
""".
-spec update(family(), offer(), non_neg_integer(), non_neg_integer()) -> pos_integer().
update(Family, Offer0, PathMtu, CachedMtu)
  when is_integer(PathMtu), PathMtu >= 0, is_integer(CachedMtu), CachedMtu >= 0 ->
    Default = default_mss(Family),
    ProtoH = min_protoh(Family),
    %% FreeBSD turns an MTU offer into an MSS offer first, so one that leaves 0 bytes reads
    %% as no option, as its switch on the offer reads it.
    Raw = case Offer0 of
              none -> 0;
              {mtu, Reported} when is_integer(Reported), Reported > 0 -> Reported - ProtoH;
              Mss when is_integer(Mss), Mss >= 0, Mss =< 16#ffff -> Mss
          end,
    Offer = case Raw of
                0 -> Default;
                _ -> max(Raw, ?TCP_MINMSS)
            end,
    case PathMtu of
        0 ->
            Default;
        _ ->
            Mtu = case CachedMtu of
                      0 -> PathMtu;
                      _ -> min(CachedMtu, PathMtu)
                  end,
            max(min(Mtu - ProtoH, Offer), ?MSS_FLOOR)
    end.

-doc """
The MSS for an MTU an ICMP error reported, or `keep` (`tcp_ctlinput_with_port`'s gate and
`tcp_mtudisc`, sys/netinet/tcp_subr.c:3152-3168 and 3594-3634). The reported MTU is first
raised to the least the stack accepts: `tcp_minmss` with the IPv4 and TCP headers, 256
bytes (`tcp_next_pmtu`), or `IPV6_MMTU`, 1,280 (`tcp6_next_pmtu`). Only an MTU below the
current MSS with its headers acts; the MSS is then `update/4`'s for it, no larger than the
send buffer (with the 64-byte floor of `update/4`, where FreeBSD would take a smaller
buffer as it is) and never above `Old`, which also holds when the path has no route and
`update/4` falls back to the family's default. So the MSS only ever goes down.
""".
-spec mtudisc(family(), non_neg_integer(), non_neg_integer(), pos_integer(),
              non_neg_integer()) -> {lower, pos_integer()} | keep.
mtudisc(Family, Reported, PathMtu, Old, SndHiwat)
  when is_integer(Reported), Reported >= 0, is_integer(Old), Old > 0,
       is_integer(SndHiwat), SndHiwat >= 0 ->
    ProtoH = min_protoh(Family),
    Mtu = max(Reported, least_mtu(Family)),
    case Mtu < Old + ProtoH of
        true ->
            Maxseg = min(update(Family, {mtu, Mtu}, PathMtu, 0), Old),
            {lower, min(Maxseg, max(SndHiwat, ?MSS_FLOOR))};
        false ->
            keep
    end.

least_mtu(inet) -> ?TCP_MINMSS + ?MIN_PROTOH_INET;
least_mtu(inet6) -> ?IPV6_MMTU.

-doc """
The MSS when a SYN's option is processed (`tcp_mss`): `update/4`'s result, lowered to the
send buffer if that is smaller, and the send and receive buffers rounded up to a whole number
of segments, no larger than `BufMax` (FreeBSD's `sb_max`) and never shrunk. Returns the MSS
and the two buffer sizes. The host cache's send and receive pipe sizes, which FreeBSD prefers
for a buffer still at its default, wait for the host cache.
""".
-spec mss(family(), offer(), {non_neg_integer(), non_neg_integer()},
          {SndBuf :: pos_integer(), RcvBuf :: non_neg_integer()}, BufMax :: pos_integer()) ->
          {pos_integer(), non_neg_integer(), non_neg_integer()}.
mss(Family, Offer, {PathMtu, CachedMtu}, {SndBuf, RcvBuf}, BufMax)
  when is_integer(SndBuf), SndBuf > 0, is_integer(RcvBuf), RcvBuf >= 0,
       is_integer(BufMax), BufMax > 0 ->
    Mss0 = update(Family, Offer, PathMtu, CachedMtu),
    {Mss, Snd} = case SndBuf < Mss0 of
                     true -> {SndBuf, SndBuf};
                     false -> {Mss0, grow(SndBuf, Mss0, BufMax)}
                 end,
    Maxseg = max(Mss, ?MSS_FLOOR),
    Rcv = case RcvBuf > Mss of
              true -> grow(RcvBuf, Mss, BufMax);
              false -> RcvBuf
          end,
    {Maxseg, Snd, Rcv}.

-doc """
The MSS option a SYN or SYN-ACK of ours carries (`tcp_mssopt`): the smaller of the path MTU
and the host cache's, less the headers, or whichever of them is known, or the family's
default when neither is.
""".
-spec mssopt(family(), non_neg_integer(), non_neg_integer()) -> integer().
mssopt(Family, PathMtu, CachedMtu)
  when is_integer(PathMtu), PathMtu >= 0, is_integer(CachedMtu), CachedMtu >= 0 ->
    ProtoH = min_protoh(Family),
    case {PathMtu, CachedMtu} of
        {0, 0} -> default_mss(Family);
        {_, 0} -> PathMtu - ProtoH;
        {0, _} -> CachedMtu - ProtoH;
        {_, _} -> min(PathMtu, CachedMtu) - ProtoH
    end.

-doc """
The MSS option a SYN-ACK of the syncache carries (`syncache_respond`,
tcp_syncache.c:1823-1827): `tcp_mssopt` over the MTU of the path the SYN-ACK leaves by, raised
to `tcp_minmss`, so a tiny MTU never makes us ask a peer for segments below it, and within
the option's 16 bits.
""".
-spec synack_mssopt(family(), non_neg_integer()) -> ?TCP_MINMSS..16#ffff.
synack_mssopt(Family, PathMtu) ->
    min(16#ffff, max(?TCP_MINMSS, mssopt(Family, PathMtu, 0))).

-doc """
The effective sender MSS of RFC 5681 (`tcp_maxseg`): `Maxseg` less the option bytes a
segment of the connection carries, padded as `tcp_addoptions` pads them and at most 40. Used
for congestion window and threshold estimates, as FreeBSD uses it.
""".
-spec maxseg(pos_integer(), options()) -> integer().
maxseg(Maxseg, noopt) ->
    Maxseg;
maxseg(Maxseg, {synchronized, Ts, SackBlocks}) when is_integer(SackBlocks), SackBlocks >= 0 ->
    TsLen = case Ts of
                true -> ?TCPOLEN_TSTAMP_APPA;
                false -> 0
            end,
    OptLen = case SackBlocks of
                 0 -> TsLen;
                 _ -> pad(TsLen + ?TCPOLEN_SACKHDR + SackBlocks * ?TCPOLEN_SACK)
             end,
    Maxseg - min(OptLen, ?TCP_MAXOLEN);
maxseg(Maxseg, {handshake, Requested}) when is_list(Requested) ->
    OptLen = case lists:member(ts, Requested) of
                 true -> ?TCPOLEN_TSTAMP_APPA;
                 false -> pad(?TCPOLEN_MAXSEG)
             end
        + flag_len(lists:member(wscale, Requested), pad(?TCPOLEN_WINDOW))
        + flag_len(lists:member(sack, Requested), pad(?TCPOLEN_SACK_PERMITTED)),
    Maxseg - min(OptLen, ?TCP_MAXOLEN).

-doc """
The initial window in bytes, also the restart window (`tcp_compute_initwnd` with FreeBSD's
default `tcp_initcwnd_segments` of 10, RFC 6928): ten segments, but no more than the larger
of two segments and 14,600 bytes.
""".
-spec initwnd(pos_integer()) -> pos_integer().
initwnd(Maxseg) when is_integer(Maxseg), Maxseg > 0 ->
    min(?TCP_INITCWND_SEGMENTS * Maxseg, max(2 * Maxseg, ?TCP_INITCWND_SEGMENTS * 1460)).

-doc """
Whether the receiver ignores SACK blocks (FreeBSD's `TF2_PROC_SACK_PROHIBIT`): when the MSS
is below `tcp_mssdflt` (536), which FreeBSD compares for both families, so that a peer with
tiny segments cannot make the scoreboard huge. A function of the MSS, so the control block
keeps no flag for it.
""".
-spec sack_prohibited(pos_integer()) -> boolean().
sack_prohibited(Maxseg) -> Maxseg < ?TCP_MSS.

default_mss(inet) -> ?TCP_MSS;
default_mss(inet6) -> ?TCP6_MSS.

min_protoh(inet) -> ?MIN_PROTOH_INET;
min_protoh(inet6) -> ?MIN_PROTOH_INET6.

%% A buffer that holds at least one segment, rounded up to whole segments within BufMax and
%% never shrunk, as tcp_mss reserves only when the rounded size is larger.
grow(Buf, Mss, BufMax) ->
    max(Buf, min(((Buf + Mss - 1) div Mss) * Mss, BufMax)).

%% PADTCPOLEN: an option length rounded up to whole 32-bit words.
pad(Len) -> ((Len + 3) div 4) * 4.

flag_len(true, Len) -> Len;
flag_len(false, _Len) -> 0.
