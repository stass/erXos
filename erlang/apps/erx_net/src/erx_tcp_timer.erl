%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_timer.c
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
%%
%% FreeBSD: sys/netinet/tcp_timer.h
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

-module(erx_tcp_timer).
-moduledoc """
A connection's timer expirations (docs/design-network-stack.md, "Timers" and "Deadlines,
not timers"), translated from sys/netinet/tcp_timer.c (`tcp_timer_delack`,
`tcp_timer_2msl`, `tcp_timer_keep`, `tcp_timer_persist`, `tcp_timer_rexmt`,
`tcp_timer_next`, `tcp_timer_enter`) and the constants of sys/netinet/tcp_timer.h at the
commit NOTICE-freebsd records.

`expired/2` runs each deadline at or before the context's time once, earliest first and, at
equal times, in the order of FreeBSD's `tt_which` (delayed ACK, retransmission, persist,
keepalive, 2MSL), with the loss module's own deadline last, as `tcp_timer_enter` takes the
earliest of `t_timers[]` and clears it before calling its handler. Which timers run is
decided once, at the start, and each still runs only if it is still due when its turn comes,
so the run ends whatever the handlers arm; a handler that ends the connection stops it. A deadline still in the
future is left alone, so a timer message that arrives early changes nothing.

The handlers that call `tcp_output` in FreeBSD set the flag output reads instead
(`TF_ACKNOW`, `TF_FORCEDATA`), and output runs once after the event in erx_tcp:step/3.
Path MTU black-hole detection is off by default in FreeBSD (`tcp_pmtud_blackhole_detect`
0) and is not translated here, nor is the progress timeout `TP_MAXUNACKTIME`, 0 by
default; `tcp_rexmit_drop_options`, 0 by default, is not either.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([expired/2]).

%% tcp_timer.c: V_tcp_retries = TCP_MAXRXTSHIFT; tcp_totbackoff, the sum of tcp_backoff[];
%% tcp_maxpersistidle = TCPTV_KEEP_IDLE (tcp_subr.c); tcp_timer.h: TCPTV_PERSMAX (ms).
-define(TCP_RETRIES, 12).
-define(TCP_TOTBACKOFF, 2559).
-define(TCPTV_PERSMAX, 60000).
-define(TCP_MAXPERSISTIDLE, (120 * 60 * 1000)).

-type timer() :: delack | rexmt | persist | keep | msl2 | loss.

-doc "Runs the deadlines due at the context's time (see the module documentation).".
-spec expired(#tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
expired(Tcb, #tcp_ctx{now = Now} = Ctx) ->
    lists:foldl(fun(Timer, {T, Actions}) -> run(Timer, T, Ctx, Actions) end,
                {Tcb, []}, due(Tcb, Now)).

run(_, #tcb{ended = true} = Tcb, _, Actions) ->
    {Tcb, Actions};
run(Timer, Tcb, #tcp_ctx{now = Now} = Ctx, Actions) ->
    case lists:member(Timer, due(Tcb, Now)) of
        true ->
            {Next, More} = fire(Timer, disarm(Timer, Tcb), Ctx),
            {Next, Actions ++ More};
        false ->
            {Tcb, Actions}
    end.

%% The armed deadlines at or before Now, earliest first; equal ones in tt_which order.
-spec due(#tcb{}, integer()) -> [timer()].
due(#tcb{send_timer = Send, deadlines = #deadlines{delack = D, keep = K, msl2 = M},
         loss = Loss, loss_state = LossState}, Now) ->
    {SendKind, SendAt} = case Send of
                             none -> {rexmt, infinity};
                             {Kind, At} -> {Kind, At}
                         end,
    Timers = [{delack, D}, {SendKind, SendAt}, {keep, K}, {msl2, M},
              {loss, Loss:deadline(LossState)}],
    [Timer || {_, _, Timer} <- lists:sort([{At, Order, Timer}
                                           || {Order, {Timer, At}} <- lists:enumerate(Timers),
                                              is_integer(At), At =< Now])].

%% tcp_timer_enter clears the timer it runs. The send timer is left armed: each of its
%% handlers re-arms it later or ends the connection.
disarm(delack, #tcb{deadlines = D} = Tcb) -> Tcb#tcb{deadlines = D#deadlines{delack = infinity}};
disarm(keep, #tcb{deadlines = D} = Tcb) -> Tcb#tcb{deadlines = D#deadlines{keep = infinity}};
disarm(msl2, #tcb{deadlines = D} = Tcb) -> Tcb#tcb{deadlines = D#deadlines{msl2 = infinity}};
disarm(_, Tcb) -> Tcb.

-spec fire(timer(), #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
fire(keep, Tcb, Ctx) ->
    keep(Tcb, Ctx);
fire(Timer, Tcb, Ctx) ->
    {fire_quiet(Timer, Tcb, Ctx), []}.

%% The handlers whose only output is through erx_tcp_output.
fire_quiet(delack, Tcb, _) ->
    Tcb#tcb{ack_now = true};
fire_quiet(msl2, Tcb, Ctx) ->
    msl2(Tcb, Ctx);
fire_quiet(persist, #tcb{send_timer = {persist, _}, rxtshift = Shift} = Tcb, Ctx) ->
    persist(Shift, Tcb, Ctx);
fire_quiet(rexmt, #tcb{send_timer = {rexmt, _}, rxtshift = Shift} = Tcb, Ctx) ->
    rexmt(Shift + 1, Tcb, Ctx);
fire_quiet(loss, #tcb{loss = Loss, loss_state = State0, sendlog = Log0} = Tcb, #tcp_ctx{now = Now} = Ctx) ->
    {Log, State, Events} = Loss:expired(Log0, State0, Now),
    erx_tcp:loss_events(Events, Tcb#tcb{sendlog = Log, loss_state = State}, none, Ctx).

%% tcp_timer_2msl: TIME-WAIT ends; otherwise (FIN-WAIT-2 after our FIN was acknowledged and
%% the receive side closed) the connection ends once idle for TP_MAXIDLE and is checked
%% again every TP_KEEPINTVL until then.
msl2(#tcb{state = time_wait} = Tcb, _) ->
    erx_tcp_user:close(Tcb);
msl2(#tcb{rcvtime = Rcvtime, keep_cnt = Cnt, keep_intvl = Intvl, deadlines = D} = Tcb,
     #tcp_ctx{now = Now}) ->
    case Now - Rcvtime =< ms(Cnt * Intvl) of
        true -> Tcb#tcb{deadlines = D#deadlines{msl2 = Now + ms(Intvl)}};
        false -> erx_tcp_user:close(Tcb)
    end.

%% tcp_timer_keep. Before ESTABLISHED it is the connection-establishment timeout. After it,
%% a connection idle for less than TP_KEEPIDLE waits out the rest; FreeBSD probes every
%% connection (tcp_always_keepalive 1) up to CLOSING, with a segment one byte below
%% snd_una that the peer must acknowledge, and drops it once idle for TP_KEEPIDLE plus
%% TP_MAXIDLE; LAST-ACK, FIN-WAIT-2 and TIME-WAIT only re-arm.
keep(#tcb{state = State, rcvtime = Rcvtime, deadlines = D} = Tcb, #tcp_ctx{now = Now} = Ctx) ->
    case keep_decision(State, Now - Rcvtime, Tcb) of
        {wait, After} ->
            {Tcb#tcb{deadlines = D#deadlines{keep = Now + After}}, []};
        drop ->
            {erx_tcp_user:drop(Tcb, etimedout), []};
        {probe, After} ->
            Probe = erx_tcp:respond(Tcb, Ctx, Tcb#tcb.snd_una - 1, Tcb#tcb.rcv_nxt, ?TH_ACK),
            {Tcb#tcb{deadlines = D#deadlines{keep = Now + After}}, [{transmit, [Probe]}]}
    end.

keep_decision(State, IdleFor, #tcb{keep_idle = IdleMs, keep_intvl = IntvlMs, keep_cnt = Cnt}) ->
    Idle = ms(IdleMs),
    MaxIdle = ms(Cnt * IntvlMs),
    Established = erx_tcp:have_established(State),
    Probing = Established andalso erx_tcp:rank(State) =< erx_tcp:rank(closing),
    if
        Established, IdleFor < Idle -> {wait, Idle - IdleFor};
        not Established -> drop;
        not Probing -> {wait, Idle};
        IdleFor >= Idle + MaxIdle -> drop;
        true -> {probe, ms(IntvlMs)}
    end.

%% tcp_timer_persist: the zero-window probe. The connection is dropped after the full
%% backoff once it has been idle for tcp_maxpersistidle or for the whole backoff time,
%% and, past CLOSE-WAIT, once idle for TCPTV_PERSMAX; otherwise tcp_setpersist re-arms the
%% timer with one more backoff and output forces a byte out.
persist(Shift, #tcb{state = State, rcvtime = Rcvtime, rtt = Rtt} = Tcb,
        #tcp_ctx{now = Now} = Ctx) ->
    IdleFor = Now - Rcvtime,
    GaveUp = Shift >= ?TCP_RETRIES
        andalso (IdleFor >= ms(?TCP_MAXPERSISTIDLE)
                 orelse IdleFor >= ms(erx_tcp_rtt:rexmtval(Rtt) * ?TCP_TOTBACKOFF)),
    Closing = erx_tcp:rank(State) > erx_tcp:rank(close_wait) andalso IdleFor >= ms(?TCPTV_PERSMAX),
    case GaveUp orelse Closing of
        true -> erx_tcp_user:drop(Tcb, etimedout);
        false -> (erx_tcp_output:setpersist(Tcb, Ctx))#tcb{force_data = true}
    end.

%% tcp_timer_rexmt, with t_rxtshift already incremented. Past tcp_retries the connection
%% is dropped. Otherwise, in this order: in SYN-SENT the window is one byte; outside it the
%% first timeout saves what
%% CC_RTO_ERR restores and keeps the SACK scoreboard, later ones forget both (the loss
%% module's rto/4); the RTO backs off; and sending restarts from snd_una with snd_recover
%% at snd_max, an immediate ACK and no RTT measurement, after CC_RTO outside SYN-SENT. The
%% timer is re-armed at the new RTO, where FreeBSD's output re-arms it.
rexmt(Shift, Tcb, _) when Shift > ?TCP_RETRIES ->
    erx_tcp_user:drop(Tcb, etimedout);
rexmt(Shift, #tcb{state = State, ccv = Ccv0, rtt = Rtt0, snd_una = Una, snd_max = SndMax,
                  loss = Loss, loss_state = LossState0, sendlog = Log0} = Tcb0,
      #tcp_ctx{now = Now} = Ctx) ->
    Ccv1 = case State of
               syn_sent -> Ccv0#ccv{cwnd = 1};
               _ -> Ccv0
           end,
    %% SYN-SENT takes no snapshot (FreeBSD's else-if after its snd_cwnd = 1).
    Prev = case {State, Shift} of
               {syn_sent, _} -> Tcb0#tcb.rexmt_prev;
               {_, 1} -> snapshot(Tcb0, Now);
               _ -> none
           end,
    Phase = case State of
                syn_sent -> handshake;
                syn_received -> handshake;
                _ -> synchronized
            end,
    Rtt = erx_tcp_rtt:backoff(Rtt0, Phase, Shift),
    Tcb1 = Tcb0#tcb{ccv = Ccv1, rexmt_prev = Prev, rtt = Rtt,
                    send_timer = {rexmt, Now + ms(erx_tcp_rtt:rto(Rtt))}, rxtshift = Shift},
    {Log, LossState} = Loss:rto(Log0, LossState0, erx_tcp:ccv(Tcb1, Ctx), Now),
    Tcb2 = Tcb1#tcb{sendlog = Log, loss_state = LossState, snd_nxt = Una, snd_recover = SndMax,
                    ack_now = true, rtt_probe = none},
    case State of
        syn_sent -> Tcb2;
        _ -> erx_tcp:cong_signal(Tcb2, rto, none, Ctx)
    end.

%% The first timeout's snapshot (TF_PREVVALID). Without timestamps a spurious timeout is
%% recognised by an acknowledgement within half an RTT (t_badrxtwin); t_srtt is ms * 32.
snapshot(#tcb{ccv = #ccv{cwnd = Cwnd, ssthresh = Ssthresh, fast_recovery = Fast,
                         cong_recovery = Cong},
              snd_recover = Recover, ts = Ts, rtt = Rtt}, Now) ->
    BadRxtWin = case Ts of
                    #ts{} -> none;
                    _ -> Now + ms(erx_tcp_rtt:srtt(Rtt) bsr 6)
                end,
    #rexmt_prev{cwnd = Cwnd, ssthresh = Ssthresh, recover = Recover, fast = Fast, cong = Cong,
                badrxtwin = BadRxtWin}.

ms(Millis) -> Millis * 1000.
