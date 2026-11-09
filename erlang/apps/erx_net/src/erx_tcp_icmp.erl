%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
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

-module(erx_tcp_icmp).
-moduledoc """
ICMP and ICMPv6 errors for TCP (docs/design-network-stack.md, "ICMP and path MTU"), the
translation of `tcp_ctlinput_with_port` and `tcp6_ctlinput_with_port` with what they call in
sys/netinet/tcp_subr.c: `tcp_next_pmtu`, `tcp6_next_pmtu`, `tcp_notify`, `tcp_drop_syn_sent`
and `tcp_mtudisc`.

The interface hands a connection each error whose quote names its four-tuple
(erx_net_input's `{report, Icmp, Quoted}` item, here `{Icmp, Quoted}`), and the connection
steps on `{icmp, Report}` with `report/3`. A report acts only when the sequence number it
quotes is one the connection has sent and not had acknowledged, `snd_una` up to `snd_max`
(RFC 5927 section 4.1), so a blind sender must guess a number in flight, as for a RST. Then:

* fragmentation-needed and packet-too-big lower the MSS for the MTU they report, and only
  ever lower it (`tcp_mtudisc`): the flight is sent again from `snd_una` in the new size by
  the step's output, which takes the place of `tcp_mtudisc`'s call to `tcp_output`. A
  report's MTU is first raised to the least the stack accepts, 256 bytes for IPv4
  (`tcp_minmss` with its headers) and 1,280 for IPv6, so no report makes segments tinier;
* port unreachable and the other errors FreeBSD maps to ECONNREFUSED, and time exceeded in
  transit, end a connection in SYN-SENT with that error and leave any other alone
  (`tcp_drop_syn_sent`, with `icmp_may_rst` at its default of 1);
* every other error is a soft error (`tcp_notify`): ignored when established and a host
  is unreachable, a reason to give up on a handshake that has already timed out more than
  three times and had a soft error before, and otherwise kept for the connection's timeout
  to report in place of ETIMEDOUT.

The path MTU a report gives lives in the connection's MSS only; `tcp_hc_updatemtu`'s host
cache is an extension the stack does not build yet (`erx_tcp_hostcache`).

An error whose quote names no connection goes to the syncache when a listener exists
(`syncache_unreach`); `syncache/3` is that branch, for the interface.
""".

-include("erx_tcp.hrl").
-include("erx_icmp4_wire.hrl").
-include("erx_ip6.hrl").

-export([report/3, syncache/3]).

-export_type([report/0]).

-doc """
An error as the interface verified it: the decoded ICMP or ICMPv6 message and the datagram
it quotes, at least 8 bytes of whose TCP header (the ports and the sequence number) the
decoders guarantee. Its contents are untrusted: anyone can send an error.
""".
-type report() :: {#icmp4{}, erx_icmp4:quoted()} | {#icmp6{}, erx_icmp6:quoted()}.

-doc """
One report for the connection (`tcp_ctlinput_with_port`, tcp_subr.c:3091-3182, and
`tcp6_ctlinput_with_port`, :3242-3377; see the module documentation). It changes the control
block only; the step's output then sends what follows.
""".
-spec report(report(), #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
report({Icmp, #{upper := <<_:32, Seq:32, _/binary>>} = Quoted}, Tcb, Ctx) ->
    case errno(Icmp) of
        none ->
            {Tcb, []};
        Errno ->
            case in_flight(Seq, Tcb) of
                true -> {act(Errno, Icmp, Quoted, Tcb, Ctx), []};
                false -> {Tcb, []}
            end
    end;
report(_, Tcb, _) ->
    {Tcb, []}.

-doc """
The syncache's side of a report whose quote names no connection (tcp_subr.c:3170-3176):
an error for the half-open connection `Conn` quoting its sequence number, which
erx_tcp_syncache:unreach/3 checks against the entry's ISS.
""".
-spec syncache(report(), erx_tcp_syncache:conn(), erx_tcp_syncache:syncache()) ->
    erx_tcp_syncache:syncache().
syncache({Icmp, #{upper := <<_:32, Seq:32, _/binary>>}}, Conn, Cache) ->
    case errno(Icmp) of
        none -> Cache;
        _ -> erx_tcp_syncache:unreach(Conn, Seq, Cache)
    end;
syncache(_, _, Cache) ->
    Cache.

%% icmp_errmap and icmp6_errmap: the error a report means, or none to ignore it.
errno(#icmp4{} = Icmp) -> erx_icmp4:errno(Icmp);
errno(#icmp6{} = Icmp) -> erx_icmp6:errno(Icmp).

%% RFC 5927 section 4.1: SEQ_GEQ(seq, snd_una) && SEQ_LT(seq, snd_max).
in_flight(Seq, #tcb{snd_una = Una, snd_max = SndMax}) ->
    Lifted = erx_tcp_seq:lift(Seq, Una),
    Lifted >= Una andalso Lifted < SndMax.

%% What the error does, as the notify function tcp_ctlinput_with_port chooses for it
%% (:3102-3122) decides. ECONNREFUSED may end a handshake (icmp_may_rst), and so may
%% EHOSTUNREACH from time exceeded in transit. Of the four ICMPv6 errors
%% tcp6_ctlinput_with_port lets end a handshake, only time exceeded maps to EHOSTUNREACH;
%% the other three map to ECONNREFUSED and take that clause.
act(emsgsize, Icmp, Quoted, Tcb, Ctx) ->
    mtudisc(reported_mtu(Icmp, Quoted), Tcb, Ctx);
act(econnrefused, _, _, Tcb, _) ->
    drop_syn_sent(econnrefused, Tcb);
act(ehostunreach, #icmp4{type = ?ICMP_TIMXCEED}, _, Tcb, _) ->
    drop_syn_sent(ehostunreach, Tcb);
act(ehostunreach, #icmp6{type = ?ICMP6_TIME_EXCEEDED}, _, Tcb, _) ->
    drop_syn_sent(ehostunreach, Tcb);
act(Errno, _, _, Tcb, _) ->
    soft_error(Errno, Tcb).

%% The MTU the error reports, before erx_tcp_mss:mtudisc/5 raises it to the family's
%% least: tcp_next_pmtu (:3077-3089) takes the one a fragmentation-needed message proposes,
%% or when it proposes none ip_next_mtu's next smaller one below the quoted datagram's
%% length; tcp6_next_pmtu (:3228-3239) the MTU of a packet-too-big message.
reported_mtu(#icmp4{msg = {error, Word}}, #{len := Len}) ->
    case Word band 16#ffff of
        0 -> erx_icmp4:next_mtu(Len);
        NextMtu -> NextMtu
    end;
reported_mtu(#icmp6{msg = {error, Mtu}}, _) ->
    Mtu.

%% tcp_mtudisc (:3594-3651): a smaller MSS (erx_tcp_mss:mtudisc/5, which keeps it from
%% ever growing), then the flight goes again from snd_una as one that was lost: snd_nxt
%% back at snd_una, the SACK scoreboard dropped (tcp_free_sackholes), snd_recover at
%% snd_max, out of SACK fast recovery, no RTT sample pending. The step's output sends it.
mtudisc(Reported, #tcb{family = Family, maxseg = Old, snd_hiwat = SndHiwat} = Tcb,
        #tcp_ctx{mtu = PathMtu}) ->
    case erx_tcp_mss:mtudisc(Family, Reported, PathMtu, Old, SndHiwat) of
        {lower, Maxseg} -> resend_flight(Tcb#tcb{maxseg = Maxseg});
        keep -> Tcb
    end.

resend_flight(#tcb{snd_una = Una, snd_max = SndMax, sack = Sack, sendlog = Log,
                   ccv = Ccv} = Tcb) ->
    Tcb#tcb{rtt_probe = none, snd_nxt = Una, snd_recover = SndMax,
            sendlog = erx_tcp_sendlog:timeout(Log, expunge),
            ccv = case Sack of
                      on -> Ccv#ccv{fast_recovery = false};
                      _ -> Ccv
                  end}.

%% tcp_drop_syn_sent (:3559-3585): only a connection in SYN-SENT ends, with the error.
drop_syn_sent(Errno, #tcb{state = syn_sent} = Tcb) -> erx_tcp_user:drop(Tcb, Errno);
drop_syn_sent(_, Tcb) -> Tcb.

%% tcp_notify (:2580-2620). icmp_errmap never gives ENETUNREACH or EHOSTDOWN, the other two
%% errors an established connection ignores; FreeBSD also forgets the cached route there,
%% which the stack's path holds outside the control block.
soft_error(ehostunreach, #tcb{state = established} = Tcb) ->
    Tcb;
soft_error(Errno, #tcb{state = State, rxtshift = Shift, soft_error = Soft} = Tcb) ->
    Handshake = erx_tcp:rank(State) < erx_tcp:rank(established),
    case Handshake andalso Shift > 3 andalso Soft =/= none of
        true -> erx_tcp_user:drop(Tcb, Errno);
        false -> Tcb#tcb{soft_error = Errno}
    end.
