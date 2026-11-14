%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_timewait.c
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

-module(erx_tcp_timewait).
-moduledoc """
TIME-WAIT (docs/design-network-stack.md, "TIME-WAIT"), the translation of
sys/netinet/tcp_timewait.c. TIME-WAIT is a state of the full control block, as in FreeBSD
15: `start/2` (`tcp_twstart`) enters it, and `check/3` (`tcp_twcheck`) answers every segment
that reaches the connection in it, in place of the segment pipeline (erx_tcp_input hands
them over). The connection ends when the 2MSL deadline passes (erx_tcp_timer) or when a new
SYN recycles it.

`check/3` keeps `tcp_twcheck`'s rules, in its order:

* a RST is dropped, never obeyed, so a stray or forged RST cannot end TIME-WAIT early and
  let an old duplicate reach a new incarnation (RFC 1337, "TIME-WAIT assassination");
* a SYN without ACK that RFC 6191 allows ends the old connection: one whose timestamp is
  newer than `ts_recent`, where both ends use timestamps, or whose sequence number is past
  `rcv_nxt`. The step closes the control block and hands the SYN back with a
  `{reinject, Segment}` action, so the interface looks it up by the listener keys alone, as
  `tcp_input` starts over when `tcp_twcheck` returns true;
* any other segment without ACK is dropped;
* a retransmitted FIN, the one whose sequence number ends just before `rcv_nxt`, re-arms
  the 2MSL deadline;
* every segment but a bare duplicate ACK is acknowledged with `rcv_nxt` and `snd_nxt`
  (`tcp_respond`), so a peer that lost our last ACK gets it again.

FreeBSD's switches are taken at their defaults and not translated: `drop_synfin` 0, so a SYN
with FIN is judged as a SYN; `tcp_tolerate_missing_ts` 1, so a segment without a timestamp
on a connection that negotiated them is not dropped, and a SYN with a timestamp to one that
did not is not a reason to recycle. The check that the UDP encapsulation port is unchanged
has nothing to compare, as the stack does not tunnel TCP over UDP.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([start/2, check/3]).

%% tcp_timer.h: TCPTV_MSL and TCPTV_MSL_LOCAL, the maximum segment lifetime, and the one
%% for a peer on one of the machine's own addresses, in milliseconds.
-define(TCPTV_MSL, 30000).
-define(TCPTV_MSL_LOCAL, 10).

-doc """
`tcp_twstart` (tcp_timewait.c:148-186): the connection enters TIME-WAIT with nothing left to
retransmit or keep alive and the 2MSL deadline armed; the step's output then sends the ACK
owed.
""".
-spec start(#tcb{}, #tcp_ctx{}) -> #tcb{}.
start(#tcb{deadlines = D} = Tcb, Ctx) ->
    Tcb#tcb{state = time_wait, send_timer = none,
            deadlines = D#deadlines{keep = infinity, msl2 = msl2(Ctx)}}.

-doc """
`tcp_twcheck` (tcp_timewait.c:197-354): one segment reaching the connection in TIME-WAIT
(see the module documentation). The segment is as the interface handed it, before any
lifting; its numbers are compared with the connection's as FreeBSD's modular comparisons
do.
""".
-spec check(erx_tcp:segment(), #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
check({#tcp{flags = Flags} = Th, Payload, _, _} = Segment, #tcb{state = time_wait} = Tcb, Ctx) ->
    if
        Flags band ?TH_RST =/= 0 ->
            {Tcb, []};
        Flags band (?TH_SYN bor ?TH_ACK) =:= ?TH_SYN ->
            case new_incarnation(Th, Tcb) of
                true -> {erx_tcp_user:close(Tcb), [{reinject, Segment}]};
                false -> {Tcb, []}
            end;
        Flags band ?TH_ACK =:= 0 ->
            {Tcb, []};
        true ->
            {_, Len, _} = erx_tcp_payload:from_wire(Payload),
            acknowledge(Th, Len, Tcb, Ctx)
    end.

%% RFC 6191 as tcp_twcheck reads it (:262-287): a SYN may reuse the four-tuple when its
%% timestamp is newer than the last one recorded, with timestamps negotiated, or when it
%% starts past everything received, whatever its timestamp, as FreeBSD ORs the two where
%% RFC 6191 would let the timestamp alone decide. tcp_twcheck's middle case, a timestamp on
%% a SYN to a connection that negotiated none, applies only when missing timestamps are not
%% tolerated. A timestamp exactly 2^31 ahead is not newer here, where TSTMP_LT calls it
%% newer; the one value differs on the side of keeping TIME-WAIT.
new_incarnation(#tcp{seq = Seq, opts = #tcp_opts{ts = SegTs}}, #tcb{ts = Ts, rcv_nxt = RcvNxt}) ->
    newer_timestamp(SegTs, Ts) orelse erx_tcp_seq:lift(Seq, RcvNxt) > RcvNxt.

newer_timestamp({Val, _}, #ts{recent = Recent}) -> erx_tcp_seq:lift(Val, Recent) > Recent;
newer_timestamp(_, _) -> false.

%% :326-347: an acceptable segment restarts TIME-WAIT when it is the peer's FIN again, and
%% draws an ACK unless it is a bare duplicate ACK at rcv_nxt for snd_nxt.
acknowledge(#tcp{flags = Flags, seq = Seq, ack = Ack} = Th, Tlen,
            #tcb{rcv_nxt = RcvNxt, snd_nxt = SndNxt} = Tcb0, Ctx) ->
    Tcb = restart_on_fin(Th, Tlen, Tcb0, Ctx),
    DuplicateAck = Flags band (?TH_SYN bor ?TH_FIN) =:= 0 andalso Tlen =:= 0
        andalso Seq =:= erx_tcp_seq:wire(RcvNxt) andalso Ack =:= erx_tcp_seq:wire(SndNxt),
    case DuplicateAck of
        true -> {Tcb, []};
        false -> {Tcb, [{transmit, [erx_tcp:respond(Tcb, Ctx, SndNxt, RcvNxt, ?TH_ACK)]}]}
    end.

%% A FIN ending just before rcv_nxt is the one already taken, so the peer lost our ACK of
%% it: the 2MSL period starts again.
restart_on_fin(#tcp{flags = Flags, seq = Seq}, Tlen, #tcb{rcv_nxt = RcvNxt, deadlines = D} = Tcb,
               Ctx) when Flags band ?TH_FIN =/= 0 ->
    Syn = case Flags band ?TH_SYN of
              0 -> 0;
              _ -> 1
          end,
    case erx_tcp_seq:lift(Seq, RcvNxt) + Tlen + Syn + 1 =:= RcvNxt of
        true -> Tcb#tcb{deadlines = D#deadlines{msl2 = msl2(Ctx)}};
        false -> Tcb
    end;
restart_on_fin(_, _, Tcb, _) ->
    Tcb.

%% The 2MSL deadline from now, with tcp_eff_msl's lifetime: TCPTV_MSL_LOCAL for a peer on
%% one of the machine's own addresses, the step's path being `loopback`, TCPTV_MSL
%% otherwise. FreeBSD asks in_localip at tcp_twstart and at a FIN's restart (:184, :332),
%% and the step's path is built over the configuration of the step.
msl2(#tcp_ctx{now = Now, loopback = Loopback}) ->
    Msl = case Loopback of
              true -> ?TCPTV_MSL_LOCAL;
              false -> ?TCPTV_MSL
          end,
    Now + ms(2 * Msl).

ms(Millis) -> Millis * 1000.
