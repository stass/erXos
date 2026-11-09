%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
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

-module(erx_tcp).
-moduledoc """
The step of a TCP connection (docs/design-network-stack.md, "Events and the step" and
"Deadlines, not timers"): `step/3` is the only entry. It hands the event to the module that
translates the FreeBSD code for it, then runs output, as `tcp_do_segment` ends by calling
`tcp_output`, and then settles what follows from the resulting state:

* a connection that has ended (`tcp_close`, the `ended` field) runs its closing output only
  when it was dropped after receiving a SYN (`tcp_drop`, sys/netinet/tcp_subr.c), so that output is the
  RST; its owner is told how it ended, every waiting caller is answered with the error, and
  the last action is `finish`;
* otherwise output runs, a `connect` caller is answered once the connection is established,
  and a waiting `send` moves the rest of its bytes into the buffer whenever its free space
  reaches the low watermark (`sowriteable`) and is answered once they are all in.

Because those answers follow from the state after every step, no stage has to remember to
give them. The event modules are erx_tcp_input (segments), erx_tcp_user (requests),
erx_tcp_timer (expirations) and erx_tcp_output (output).

The module also holds what those modules share: the state order of `tcp_fsm.h`, the
connection's side of `cc_cong_signal` and `cc_ack_received` (sys/netinet/tcp_input.c), the
calls a loss module returns, `tcp_respond` for a connection (sys/netinet/tcp_subr.c) and the
receive window it advertises.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([step/3, next_deadline/1]).
-export([have_rcvd_syn/1, have_established/1, have_rcvd_fin/1, rank/1]).
-export([cong_signal/4, loss_events/4, ccv/2, rxtshift/1, respond/5, challenge_ack/3,
         rcv_space/1, ts_now/2]).

-export_type([state/0, event/0, action/0, request/0, segment/0, outgoing/0]).

-doc "`t_state`, in the order of `tcp_fsm.h`.".
-type state() :: closed | syn_sent | syn_received | established | close_wait | fin_wait_1
               | closing | last_ack | fin_wait_2 | time_wait.

-doc "A request from the connection's owner (erx_tcp_user).".
-type request() :: erx_tcp_user:request().

-doc """
What the step is handed: segments from the interface, in order, as erx_tcp_wire decoded
them; a request; a timer message, whose time is only a hint, since the context's time is
the one the step uses; or the buffer size the grant reserved.
""".
-type event() :: {segments, [segment()]}
               | {user, request()}
               | {expired, Hint :: integer()}
               | {buffer, snd | rcv, Bytes :: non_neg_integer()}.

-doc """
A received segment as the interface hands it on: the header and payload erx_tcp_wire
decoded, and the ECN field of its IP header (the low two bits of the IPv4 TOS or IPv6
traffic class byte, tcp_do_segment's `iptos`).
""".
-type segment() :: {#tcp{}, Payload :: binary(), IpEcn :: 0..3}.

-doc """
A segment to send: its TCP header with the values on the wire, and its payload, which
erx_net_frame encodes with the path's headers.
""".
-type outgoing() :: {#tcp{}, Payload :: [binary()]}.

-doc """
What the step asks its process to do, in order. `{reset, Segment}` is a RST answering a
segment (`tcp_dropwithreset`), which the interface sends only within its RST rate limit
(`badport_bandlim`); `charge_rst` counts one RST against that limit without sending one
(see challenge_ack/3).
""".
-type action() :: {transmit, [outgoing()]}
                | {deliver, iodata()}
                | {notify, closed | {error, atom()} | {ready, [atom()]}}
                | {reply, gen_server:from(), term()}
                | {reserve_buffer, snd | rcv, Bytes :: non_neg_integer()}
                | {reset, outgoing()}
                | charge_rst
                | {reinject, segment()}
                | finish.

%% TCP_MAXWIN, the largest unscaled window.
-define(TCP_MAXWIN, 16#ffff).
%% tcp_subr.c: tcp_ack_war_time_window (ms) and tcp_ack_war_cnt, FreeBSD's defaults.
-define(ACK_WAR_TIME_WINDOW, 1000).
-define(ACK_WAR_CNT, 5).

-doc """
One event: dispatch, output, and the answers that follow from the state (see the module
documentation). An exception leaves the caller's state as it was.
""".
-spec step(event(), #tcb{}, #tcp_ctx{}) -> {#tcb{}, [action()]}.
step(Event, Tcb0, #tcp_ctx{} = Ctx) ->
    {Tcb, Actions} = dispatch(Event, Tcb0, Ctx),
    settle(Tcb, Actions, Ctx).

dispatch({segments, Segments}, Tcb, Ctx) when is_list(Segments) ->
    erx_tcp_input:segments(Segments, Tcb, Ctx);
dispatch({user, Request}, Tcb, Ctx) ->
    erx_tcp_user:request(Request, Tcb, Ctx);
dispatch({expired, Hint}, Tcb, Ctx) when is_integer(Hint) ->
    erx_tcp_timer:expired(Tcb, Ctx);
dispatch({buffer, snd, Bytes}, Tcb, _) when is_integer(Bytes), Bytes >= 0 ->
    {Tcb#tcb{snd_hiwat = Bytes}, []};
dispatch({buffer, rcv, Bytes}, Tcb, _) when is_integer(Bytes), Bytes >= 0 ->
    {Tcb#tcb{rcv_hiwat = Bytes}, []}.

settle(#tcb{ended = true} = Tcb0, Actions, Ctx) ->
    {Tcb, Out} = case Tcb0#tcb.reset_peer of
                     true -> erx_tcp_output:output(Tcb0, Ctx);
                     false -> {Tcb0, []}
                 end,
    {Reason, Told} = case Tcb#tcb.error of
                         none -> {closed, [{notify, closed}]};
                         Error -> {Error, [{notify, {error, Error}}, {notify, closed}]}
                     end,
    Waiters = [W || W <- [Tcb#tcb.connect_waiter], W =/= none]
        ++ [From || {From, _} <- [Tcb#tcb.send_waiter]],
    {Tcb#tcb{connect_waiter = none, send_waiter = none, deadlines = #deadlines{},
             send_timer = none},
     Actions ++ transmit(Out) ++ [{reply, W, {error, Reason}} || W <- Waiters] ++ Told ++ [finish]};
settle(Tcb0, Actions, Ctx) ->
    {Tcb1, Out} = erx_tcp_output:output(Tcb0, Ctx),
    {Tcb2, Connected} = answer_connect(Tcb1),
    {Tcb, Sent} = answer_send(Tcb2),
    {Tcb, Actions ++ transmit(Out) ++ Connected ++ Sent}.

transmit([]) -> [];
transmit(Segments) -> [{transmit, Segments}].

answer_connect(#tcb{connect_waiter = none} = Tcb) -> {Tcb, []};
answer_connect(#tcb{connect_waiter = From} = Tcb) ->
    case have_established(Tcb#tcb.state) of
        true -> {Tcb#tcb{connect_waiter = none}, [{reply, From, ok}]};
        false -> {Tcb, []}
    end.

answer_send(#tcb{send_waiter = none} = Tcb) ->
    {Tcb, []};
answer_send(#tcb{send_waiter = {From, Rest}, sndbuf = Buf, snd_hiwat = Hiwat,
                  snd_lowat = Lowat} = Tcb) ->
    Space = max(0, Hiwat - erx_tcp_sndbuf:size(Buf)),
    %% sowriteable: a writer wakes when the free space reaches the low watermark, held to
    %% the buffer's size, or when what it still has to write fits.
    case Space >= min(min(Lowat, Hiwat), byte_size(Rest)) andalso Space > 0 of
        false -> {Tcb, []};
        true -> erx_tcp_user:fill(From, Rest, Tcb)
    end.

-doc """
The earliest deadline of the connection, `infinity` when none is armed: the retransmission
or persist timer, delayed ACK, keepalive, 2MSL and the loss module's own
(`tcp_timer_next`, sys/netinet/tcp_timer.c).
""".
-spec next_deadline(#tcb{}) -> integer() | infinity.
next_deadline(#tcb{send_timer = Send, deadlines = #deadlines{delack = D, keep = K, msl2 = M},
                   loss = Loss, loss_state = LossState}) ->
    SendAt = case Send of
                 none -> infinity;
                 {_, At} -> At
             end,
    %% Numbers order before atoms, so `infinity` loses every comparison.
    lists:min([SendAt, D, K, M, Loss:deadline(LossState)]).

-doc "The position of a state in `tcp_fsm.h`'s order, CLOSED 0 to TIME-WAIT 10.".
-spec rank(state()) -> 0..10.
rank(closed) -> 0;
rank(syn_sent) -> 2;
rank(syn_received) -> 3;
rank(established) -> 4;
rank(close_wait) -> 5;
rank(fin_wait_1) -> 6;
rank(closing) -> 7;
rank(last_ack) -> 8;
rank(fin_wait_2) -> 9;
rank(time_wait) -> 10.

-doc "`TCPS_HAVERCVDSYN`: SYN-RECEIVED or later.".
-spec have_rcvd_syn(state()) -> boolean().
have_rcvd_syn(State) -> rank(State) >= rank(syn_received).

-doc "`TCPS_HAVEESTABLISHED`: ESTABLISHED or later.".
-spec have_established(state()) -> boolean().
have_established(State) -> rank(State) >= rank(established).

-doc "`TCPS_HAVERCVDFIN`: CLOSE-WAIT, CLOSING, LAST-ACK or TIME-WAIT.".
-spec have_rcvd_fin(state()) -> boolean().
have_rcvd_fin(State) ->
    State =:= close_wait orelse State =:= closing orelse State =:= last_ack
        orelse State =:= time_wait.

-doc """
`t_rxtshift`: the timeouts in a row of the retransmission or persist timer, kept when the
timer stops, until an RTT sample, an undone spurious timeout or the end of persist resets it.
""".
-spec rxtshift(#tcb{}) -> non_neg_integer().
rxtshift(#tcb{rxtshift = Shift}) -> Shift.

-doc """
The congestion module's view refreshed from the control block, as FreeBSD's `CCV()` reads
`struct tcpcb` live: the peer's window and shift, the pipe, the backoff count, the smoothed
RTT in microseconds, whether a timeout's retransmission is under way, and the time.
""".
-spec ccv(#tcb{}, #tcp_ctx{}) -> #ccv{}.
ccv(#tcb{ccv = Ccv, snd_wnd = SndWnd, wscale = Wscale, sendlog = Log, rtt = Rtt,
         snd_nxt = SndNxt, snd_max = SndMax, maxseg = Maxseg} = Tcb, #tcp_ctx{now = Now}) ->
    SndScale = case Wscale of
                   {Snd, _} -> Snd;
                   _ -> 0
               end,
    %% t_srtt is milliseconds scaled by 32; TCP_TMR_GRANULARITY_USEC unscales it.
    Ccv#ccv{snd_wnd = SndWnd, snd_scale = SndScale, pipe = erx_tcp_sendlog:pipe(Log),
            rxtshift = rxtshift(Tcb), srtt = erx_tcp_rtt:srtt(Rtt) * 1000 div 32,
            rexmit = SndNxt =/= SndMax, maxseg = Maxseg, now = Now}.

-doc """
The connection's side of `cc_cong_signal` (sys/netinet/tcp_input.c), then the congestion
module's `cong_signal/3` with the acknowledgement that caused it, or `none` from a timer.
""".
-spec cong_signal(#tcb{}, erx_tcp_cc:signal(), integer() | none, #tcp_ctx{}) -> #tcb{}.
cong_signal(Tcb0, Signal, CurAck, Ctx) ->
    #tcb{ccv = Ccv0} = Tcb = signal_state(Signal, Tcb0, CurAck),
    Ccv = (Tcb#tcb.cc):cong_signal(ccv(Tcb#tcb{ccv = Ccv0}, Ctx), Signal, CurAck),
    Tcb#tcb{ccv = Ccv}.

signal_state(ndupack, #tcb{ccv = #ccv{fast_recovery = true}} = Tcb, _) ->
    Tcb;
signal_state(ndupack, #tcb{snd_max = SndMax, ecn = Ecn} = Tcb, _) ->
    Tcb#tcb{snd_recover = SndMax, ecn = erx_tcp_ecn:signal_cwr(Ecn)};
signal_state(ecn, #tcb{ccv = Ccv, snd_recover = Recover, snd_max = SndMax, ecn = Ecn} = Tcb,
             CurAck) ->
    AtRecover = is_integer(CurAck) andalso CurAck >= Recover,
    case not Ccv#ccv.cong_recovery orelse AtRecover of
        true ->
            Tcb#tcb{ccv = Ccv#ccv{cong_recovery = false}, snd_recover = SndMax + 1,
                    ecn = erx_tcp_ecn:signal_cwr(Ecn)};
        false ->
            Tcb
    end;
signal_state(rto, #tcb{ccv = Ccv, ecn = Ecn} = Tcb, _) ->
    %% t_dupacks and t_bytes_acked are the loss module's, which its rto/4 resets.
    Tcb#tcb{ccv = Ccv#ccv{fast_recovery = false, cong_recovery = false},
            ecn = erx_tcp_ecn:signal_cwr(Ecn)};
signal_state(rto_err, #tcb{rexmt_prev = none} = Tcb, _) ->
    Tcb;
signal_state(rto_err, #tcb{ccv = Ccv, rexmt_prev = Prev, snd_max = SndMax} = Tcb, _) ->
    #rexmt_prev{cwnd = Cwnd, ssthresh = Ssthresh, recover = Recover, fast = Fast,
                cong = Cong} = Prev,
    Tcb#tcb{ccv = Ccv#ccv{cwnd = Cwnd, ssthresh = Ssthresh,
                          fast_recovery = Ccv#ccv.fast_recovery orelse Fast,
                          cong_recovery = Ccv#ccv.cong_recovery orelse Cong},
            snd_recover = Recover, snd_nxt = SndMax, rexmt_prev = none, rxtshift = 0}.

-doc """
Makes the calls a loss module returned (erx_tcp_loss), in order: congestion signals, a
duplicate acknowledgement for the congestion module (`cc_ack_received` with `CC_DUPACK`),
stopping the retransmission timer and the RTT measurement, an immediate ACK, and resuming
at `snd_max`. `CurAck` is the acknowledgement being processed, or `none` from a timer.
""".
-spec loss_events([erx_tcp_loss:event()], #tcb{}, integer() | none, #tcp_ctx{}) -> #tcb{}.
loss_events(Events, Tcb0, CurAck, Ctx) ->
    lists:foldl(fun(Event, Tcb) -> loss_event(Event, Tcb, CurAck, Ctx) end, Tcb0, Events).

loss_event({cong_signal, Signal}, Tcb, CurAck, Ctx) ->
    cong_signal(Tcb, Signal, CurAck, Ctx);
loss_event({ack_received, dupack}, #tcb{cc = Cc, snd_una = Una} = Tcb, CurAck, Ctx) ->
    #ccv{cwnd = Cwnd, snd_wnd = SndWnd} = Ccv = ccv(Tcb, Ctx),
    Ack = #cc_ack{bytes = 0, nsegs = 1, cwnd_limited = Cwnd =< SndWnd,
                  curack = case CurAck of none -> Una; _ -> CurAck end},
    Tcb#tcb{ccv = Cc:ack_received(Ccv, dupack, Ack)};
loss_event(stop_rexmt, #tcb{send_timer = {rexmt, _}} = Tcb, _, _) ->
    Tcb#tcb{send_timer = none, rtt_probe = none};
loss_event(stop_rexmt, Tcb, _, _) ->
    Tcb#tcb{rtt_probe = none};
loss_event(ack_now, Tcb, _, _) ->
    Tcb#tcb{ack_now = true};
loss_event(resume_at_max, #tcb{snd_max = SndMax} = Tcb, _, _) ->
    Tcb#tcb{snd_nxt = SndMax}.

-doc """
`sbspace(&so->so_rcv)`: the receive buffer's free bytes, the window before scaling.
""".
-spec rcv_space(#tcb{}) -> non_neg_integer().
rcv_space(#tcb{rcv_hiwat = Hiwat, rcv_buffered = Buffered}) -> max(0, Hiwat - Buffered).

-doc """
Our timestamp clock (`tcp_ts_getticks() + ts_offset`): milliseconds of the monotonic time
plus the connection's offset, as the option carries it.
""".
-spec ts_now(erx_tcp_seq:wire(), #tcp_ctx{}) -> erx_tcp_seq:wire().
ts_now(Offset, #tcp_ctx{now = Now}) -> erx_tcp_seq:wire(Now div 1000 + Offset).

-doc """
`tcp_send_challenge_ack` with `tcp_challenge_ack_check` (sys/netinet/tcp_subr.c): an ACK of
`rcv_nxt` at `snd_nxt`, after which `last_ack_sent` is `rcv_nxt`, at most
`tcp_ack_war_cnt` (5) in each `tcp_ack_war_time_window` (1,000 ms) of the connection, so
blind segments cannot turn the connection into an ACK flood. A challenge ACK sent is the
ACK the segment owed, so none is left owed for output.

`Cause` is the segment's kind. For a SYN or an ACK every attempt, sent or not, counts one
RST against the interface's rate limit (`charge_rst`), as FreeBSD charges `badport_bandlim`:
had the segment named no connection it would have drawn a RST, so the limit does not tell a
blind sender whether it did. For a RST nothing is charged: a RST that names no connection
draws nothing, so charging one that does would tell the sender it hit a window, where
FreeBSD charges it too.
""".
-spec challenge_ack(rst | syn | ack, #tcb{}, #tcp_ctx{}) -> {#tcb{}, [action()]}.
challenge_ack(Cause, #tcb{challenge = War, rcv_nxt = RcvNxt, snd_nxt = SndNxt} = Tcb,
              #tcp_ctx{now = Now} = Ctx) when Cause =:= rst; Cause =:= syn; Cause =:= ack ->
    Charge = [charge_rst || Cause =/= rst],
    {End, Sent} = case War of
                      {End0, Sent0} when End0 >= Now -> {End0, Sent0};
                      _ -> {Now + ?ACK_WAR_TIME_WINDOW * 1000, 0}
                  end,
    case Sent < ?ACK_WAR_CNT of
        true ->
            {Tcb#tcb{challenge = {End, Sent + 1}, last_ack_sent = RcvNxt, ack_now = false},
             Charge ++ [{transmit, [respond(Tcb, Ctx, SndNxt, RcvNxt, ?TH_ACK)]}]};
        false ->
            {Tcb#tcb{challenge = {End, Sent}}, Charge}
    end.

-doc """
`tcp_respond` for a connection (sys/netinet/tcp_subr.c): a bare segment with `Seq`, `Ack`
and `Flags`, the window `sbspace(&so->so_rcv) >> rcv_scale` and, on a connection that
negotiated timestamps, the timestamp option echoing `ts_recent`. The keepalive probe, the
challenge ACK and the ACK of a segment the connection drops are such segments. A window
past 16 bits is sent as the largest one, where FreeBSD's cast would truncate it. A RST
carries a window of 0 and no options, as `tcp_respond` sends it.
""".
-spec respond(#tcb{}, #tcp_ctx{}, integer(), integer(), 0..16#fff) -> outgoing().
respond(#tcb{local = {_, LPort}, remote = {_, RPort}, wscale = Wscale, ts = Ts} = Tcb, Ctx,
        Seq, Ack, Flags) ->
    RcvShift = case Wscale of
                   {_, Rcv} -> Rcv;
                   _ -> 0
               end,
    Reset = Flags band ?TH_RST =/= 0,
    Opts = case Ts of
               #ts{recent = Recent, offset = Offset} when not Reset ->
                   #tcp_opts{ts = {ts_now(Offset, Ctx), Recent}};
               _ -> #tcp_opts{}
           end,
    Win = case Reset of
              true -> 0;
              false -> min(rcv_space(Tcb) bsr RcvShift, ?TCP_MAXWIN)
          end,
    {#tcp{sport = LPort, dport = RPort, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = Win, urp = 0,
          opts = Opts},
     []}.
