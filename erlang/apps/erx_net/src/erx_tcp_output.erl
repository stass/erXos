%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause AND BSD-3-Clause
%%
%% FreeBSD: sys/netinet/tcp_output.c
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
%% FreeBSD: sys/netinet/tcp_fsm.h
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
%% FreeBSD: sys/netinet/tcp_usrreq.c
%% Copyright (c) 1982, 1986, 1988, 1993
%% The Regents of the University of California.
%% Copyright (c) 2006-2007 Robert N. M. Watson
%% Copyright (c) 2010-2011 Juniper Networks, Inc.
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

-module(erx_tcp_output).
-moduledoc """
A connection's output (docs/design-network-stack.md, "Output"): what to send and when,
translated from `tcp_default_output` and `tcp_setpersist` (sys/netinet/tcp_output.c) at
the commit NOTICE-freebsd records. erx_tcp:step/3 calls `output/2` once after every event,
as FreeBSD calls `tcp_output` at the end of each input, timer and user request.

A pass is FreeBSD's `again` loop. `decide/3` translates `tcp_default_output` up to `send:`:
where the next bytes come from and how many the windows allow, sender and receiver
silly-window avoidance, Nagle, window updates, and the persist or retransmission timer it
starts when nothing goes. `transmit/3` translates what follows `send:`: the options, the
MSS clamp, the header and receive window, and the sequence and timer updates after the
segment. The pass goes round again while a segment was cut short (`sendalot`), and at most
the context's credit of segments leave it.

Departures, each from erXos's model:

* What to retransmit during recovery and after a timeout comes from the send log's
  `NextSeg` (erx_tcp_sendlog), where FreeBSD walks its SACK holes (`tcp_sack_output`) or
  has moved `snd_nxt` back. When the log has nothing to retransmit and holds SACK
  information, sending resumes at `snd_max`, as `tcp_sack_adjust` skips what was SACKed.
* The congestion window is measured against the log's pipe, where FreeBSD measures it
  against `snd_nxt - snd_una` outside SACK recovery; the two agree when nothing is SACKed,
  lost or retransmitted. Where FreeBSD moves `snd_nxt` back because the window shrank to
  zero, the rewound bytes are also marked lost in the log, so the pipe leaves them out as
  FreeBSD's offset does and the log resends them once the window opens. The peer's window is a right edge at `snd_una + snd_wnd`. The loss
  module's window (`allowance`) replaces the congestion window for one pass, as
  `tcp_input.c` sets `snd_cwnd` around its calls to `tcp_output`, and its kept window is
  the congestion window afterwards.
* The credit is the driver's queue. A segment it does not cover is neither sent nor
  recorded; the congestion window drops to one segment, as on `ENOBUFS`, and a segment that
  carried sequence space arms the retransmission timer if no send timer is armed, which
  FreeBSD asserts there (`TCP_XMIT_TIMER_ASSERT`). The requests are cleared as after every
  pass, where FreeBSD's error return leaves `TF_ACKNOW` set.
* A retransmission the log chose carries the FIN only when the log's range holds it. A
  sequential segment below `snd_max` (a probe sent again, the FIN an ACK of FIN-WAIT-1
  carries again) is recorded in the log only for what it adds at or past `snd_max`, so it
  does not move RFC 6675's HighRxt past holes recovery still has to resend.
* `snd_nxt` is held at or above `snd_una` at the start of each pass, where FreeBSD's input
  moves it up when an acknowledgement passes it.
* Not built, since erXos offers none of them: TCP Fast Open, segmentation offload, IP
  options, TCP-MD5 signatures, UDP tunnelling, `TF_NOOPT`, `TF_NOPUSH`, `TF_MORETOCOME`,
  send-buffer autoscaling and `TCP_MAXUNACKTIME`.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([output/2, setpersist/2, request_r_scale/0]).

%% TCP_MAXWIN and TCP_MAX_WINSHIFT (tcp.h).
-define(TCP_MAXWIN, 16#ffff).
-define(TCP_MAX_WINSHIFT, 14).
%% SB_MAX (sys/sys/sockbuf.h), kern.ipc.maxsockbuf's default, from which tcp_connect picks
%% the window scale it requests.
-define(SB_MAX, (2 * 1024 * 1024)).
%% V_tcp_retries (tcp_timer.c), where tcp_setpersist stops counting.
-define(TCP_RETRIES, 12).
%% V_tcp_minmss (tcp_subr.c): with path MTU discovery on, its default, a connection whose
%% MSS is above it sets DF on every segment (tcp_output.c:1494-1498).
-define(TCP_MINMSS, 216).
%% PADTCPOLEN(TCPOLEN_TIMESTAMP).
-define(TS_OPTLEN, 12).

%% The segment decide/3 chose: its first sequence number, its payload bytes, its flags,
%% where its bytes come from (`next`, sequentially from snd_nxt; `retransmit` or `rescue`, a
%% range the send log chose), and whether the pass goes round again after it (sendalot).
%% A range the send log chose to send again (NextSeg's rules 1, 3 and 4): its first sequence
%% number, the sequence space the window's room allows of it, and whether it was shorter
%% than that room, so the pass goes round again (sendalot).
-record(rxmt, {kind :: retransmit | rescue,
               start :: integer(),
               seq_len :: non_neg_integer(),
               more :: boolean()}).

-record(out_seg, {start :: integer(),
                  len :: non_neg_integer(),
                  flags :: 0..16#fff,
                  source :: next | retransmit | rescue,
                  sendalot :: boolean()}).

-doc """
The segments the connection sends now, at most the context's credit, and the control
block after sending them (see the module documentation). It clears the requests the step
left (`ack_now`, `force_data`, `allowance`). In CLOSED it sends only the RST|ACK of a
dropped connection that has received a SYN (`reset_peer`, `tcp_outflags[TCPS_CLOSED]`).
""".
-spec output(#tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:outgoing()]}.
output(#tcb{state = closed, reset_peer = true} = Tcb, Ctx) ->
    reset(Tcb, Ctx);
output(#tcb{state = closed} = Tcb, _) ->
    {done(Tcb), []};
output(#tcb{snd_una = Una, snd_max = Max, snd_nxt = Nxt} = Tcb0,
       #tcp_ctx{credit = Credit} = Ctx) ->
    Tcb = Tcb0#tcb{snd_nxt = max(Nxt, Una)},
    Idle = Max =:= Una,
    {Tcb1, Out} = again(after_idle(Idle, Tcb, Ctx), Idle, Credit, Ctx, []),
    {done(Tcb1), Out}.

-doc """
`tcp_setpersist` as the persist timer's next probe: arms it backed off by the timeouts so
far (erx_tcp_rtt:persist/2) and counts one more, up to `tcp_retries`. Arming persist
replaces the retransmission timer, which FreeBSD asserts is not armed, and forgets the
first timeout's snapshot (TF_PREVVALID). Output starts persist with a count of 0 instead.
""".
-spec setpersist(#tcb{}, #tcp_ctx{}) -> #tcb{}.
setpersist(Tcb, Ctx) ->
    persist(Tcb, erx_tcp:rxtshift(Tcb), Ctx).

-doc """
The window scale an active open requests (`request_r_scale`, tcp_connect): the least shift
that lets the window cover `SB_MAX`, at most `TCP_MAX_WINSHIFT`. Input sets the receive
shift to it when the peer's SYN-ACK agrees to scaling.
""".
-spec request_r_scale() -> 0..14.
request_r_scale() ->
    hd([Shift || Shift <- lists:seq(0, ?TCP_MAX_WINSHIFT - 1), ?TCP_MAXWIN bsl Shift >= ?SB_MAX]
       ++ [?TCP_MAX_WINSHIFT]).

%% The `again` loop. A segment beyond the credit is the ENOBUFS case.
again(Tcb0, Idle, Credit, Ctx, Acc) ->
    case decide(Tcb0, Idle, Ctx) of
        {stop, Tcb} ->
            {Tcb, lists:reverse(Acc)};
        {send, Seg, Tcb} when Credit =:= 0 ->
            {enobufs(Seg, Tcb, Ctx), lists:reverse(Acc)};
        {send, Seg, Tcb1} ->
            {Tcb, Out, More} = transmit(Seg, Tcb1, Ctx),
            case More of
                true -> again(Tcb, Idle, Credit - 1, Ctx, [Out | Acc]);
                false -> {Tcb, lists:reverse([Out | Acc])}
            end
    end.

%% The end of a pass: the loss module's kept window becomes the congestion window, and the
%% step's requests are cleared.
done(#tcb{allowance = {_, Keep}, ccv = Ccv} = Tcb) ->
    done(Tcb#tcb{allowance = none, ccv = Ccv#ccv{cwnd = Keep}});
done(Tcb) ->
    Tcb#tcb{ack_now = false, force_data = false, allowance = none}.

%% cc_after_idle: nothing outstanding and nothing received or sent for an RTO.
after_idle(true, #tcb{rcvtime = Rcvtime, sndtime = Sndtime, rtt = Rtt, cc = Cc} = Tcb,
           #tcp_ctx{now = Now} = Ctx) ->
    Rto = erx_tcp_rtt:rto(Rtt) * 1000,
    case Now - Rcvtime >= Rto orelse (is_integer(Sndtime) andalso Now - Sndtime >= Rto) of
        true -> Tcb#tcb{ccv = Cc:after_idle(erx_tcp:ccv(Tcb, Ctx))};
        false -> Tcb
    end;
after_idle(false, Tcb, _) ->
    Tcb.

%% tcp_default_output from `again:` to `send:` or `just_return:`.
decide(#tcb{state = State, snd_una = Una, snd_wnd = SndWnd, sndbuf = Buf,
            force_data = Force} = Tcb0, Idle, Ctx) ->
    Synced = erx_tcp:have_established(State),
    DataEnd = Una + erx_tcp_sndbuf:size(Buf),
    Cwnd = cwnd(Tcb0),
    SendWin0 = min(SndWnd, Cwnd),
    %% A probe into a zero window takes its byte at snd_nxt, whatever the log holds.
    Source = case Force andalso SendWin0 =:= 0 of
                 true -> {next, Tcb0#tcb.snd_nxt};
                 false -> source(Tcb0, Synced, SendWin0)
             end,
    Flags0 = outflags(Tcb0),
    %% TF_FORCEDATA: a window probe into a zero window takes one byte, and leaves the FIN
    %% off while data remains; into an open window the persist timer stops.
    {Tcb1, SendWin, Flags1} =
        case Force of
            true when SendWin0 =:= 0, Tcb0#tcb.snd_nxt < DataEnd ->
                {Tcb0, 1, Flags0 band bnot ?TH_FIN};
            true when SendWin0 =:= 0 -> {Tcb0, 1, Flags0};
            true -> {stop_persist(Tcb0), SendWin0, Flags0};
            false -> {Tcb0, SendWin0, Flags0}
        end,
    %% Where the payload starts and how long it may be; the header's sequence number, which
    %% differs for a SYN, a FIN sent again and a bare ACK, is segment/4's.
    {DataFrom, Len0} =
        case Source of
            {next, Nxt} when not Synced -> {Nxt, 0};
            {next, Nxt} when Force, SendWin0 =:= 0 -> {Nxt, min(DataEnd, Una + 1) - Nxt};
            {next, Nxt} -> {Nxt, next_len(Tcb1, Nxt, DataEnd, Cwnd)};
            #rxmt{start = S, seq_len = SeqLen} -> {S, max(0, min(S + SeqLen, DataEnd) - S)}
        end,
    Flags2 = syn_sent_once(State, Tcb1#tcb.snd_nxt > Una, Flags1),
    Len = max(0, Len0),
    Tcb2 = case Len0 =< 0 andalso SendWin =:= 0 andalso Synced
                    andalso Tcb1#tcb.snd_nxt < DataEnd andalso not persisting(Tcb1) of
               %% The window shrank to zero after we sent into it: back to snd_una, with the
               %% rewound bytes lost in the log, and persist.
               true -> start_persist(rewind(Tcb1), Ctx);
               false -> Tcb1
           end,
    Flags = fin_fits(Source, DataFrom, Len, DataEnd, Flags2),
    Seg = segment(Source, Len, Flags, Tcb2),
    case send_reason(Seg, Tcb2, Idle, DataEnd) of
        true -> {send, Seg, Tcb2};
        false -> {stop, nothing_sent(Tcb2, Ctx)}
    end.

%% The congestion window of this pass: the loss module's, or the congestion module's.
cwnd(#tcb{allowance = {Send, _}}) -> Send;
cwnd(#tcb{ccv = #ccv{cwnd = Cwnd}}) -> Cwnd.

%% Where the next bytes come from, tcp_sack_output's role. Once synchronized, during
%% recovery or while snd_nxt is behind snd_max, the send log's NextSeg is asked first. A
%% range it gives is cut to the room the window leaves over the pipe; a range shorter than
%% that room lets the pass go round again (sendalot). Otherwise the bytes follow snd_nxt,
%% or snd_max when the log holds SACK information (tcp_sack_adjust).
source(#tcb{snd_nxt = Nxt}, false, _) ->
    {next, Nxt};
source(#tcb{snd_nxt = Nxt, snd_max = Max, ccv = #ccv{fast_recovery = false}}, true, _)
  when Nxt >= Max ->
    {next, Nxt};
source(#tcb{snd_nxt = Nxt, snd_max = Max, snd_una = Una, ccv = #ccv{fast_recovery = Fast},
            sendlog = Log, sack = Sack, snd_recover = Recover, maxseg = Mss, sndbuf = Buf},
       true, SendWin) ->
    %% Outside recovery new data always qualifies, so NextSeg's rule 3 (holes not yet
    %% lost) never retransmits ahead of recovery.
    NewData = not Fast orelse (Una + erx_tcp_sndbuf:size(Buf) > Max andalso Una + SendWin > Max),
    Opts = #{mss => Mss, recover => case Fast of true -> Recover; false -> Max end,
             new_data => NewData, rescue => Fast andalso Sack =:= on},
    case erx_tcp_sendlog:next_seg(Log, Opts) of
        {Kind, S, E} ->
            Room = max(0, SendWin - erx_tcp_sendlog:pipe(Log)),
            #rxmt{kind = Kind, start = S, seq_len = min(E - S, Room), more = E - S < Room};
        _ when Nxt < Max ->
            {next, case erx_tcp_sendlog:has_holes(Log) of
                       true -> Max;
                       false -> Nxt
                   end};
        _ ->
            {next, Nxt}
    end.

%% The payload that may follow snd_nxt: what the buffer holds past it, within the peer's
%% window and the congestion window's room over the pipe.
next_len(#tcb{snd_una = Una, snd_wnd = SndWnd, sendlog = Log}, Nxt, DataEnd, Cwnd) ->
    lists:min([DataEnd - Nxt, Una + SndWnd - Nxt, Cwnd - erx_tcp_sendlog:pipe(Log)]).

%% tcp_outflags (tcp_fsm.h), with the FIN only while one is owed or sent (P14's `fin`).
outflags(#tcb{state = closed}) -> ?TH_RST bor ?TH_ACK;
outflags(#tcb{state = syn_sent}) -> ?TH_SYN;
outflags(#tcb{state = syn_received}) -> ?TH_SYN bor ?TH_ACK;
outflags(#tcb{state = State, fin = Fin})
  when State =:= fin_wait_1; State =:= closing; State =:= last_ack ->
    case Fin of
        none -> ?TH_ACK;
        _ -> ?TH_FIN bor ?TH_ACK
    end;
outflags(#tcb{}) -> ?TH_ACK.

%% A SYN already sent goes again only in SYN-RECEIVED (or once snd_nxt is back at snd_una).
syn_sent_once(syn_received, _, Flags) -> Flags;
syn_sent_once(_, true, Flags) -> Flags band bnot ?TH_SYN;
syn_sent_once(_, false, Flags) -> Flags.

%% The FIN goes only on a segment that reaches the end of the data; on a retransmission
%% the log chose, only when its range holds the FIN.
fin_fits({next, _}, DataFrom, Len, DataEnd, Flags) when DataFrom + Len < DataEnd ->
    Flags band bnot ?TH_FIN;
fin_fits({next, _}, _, _, _, Flags) ->
    Flags;
fin_fits(#rxmt{start = S, seq_len = SeqLen}, _, _, DataEnd, Flags) when S + SeqLen > DataEnd ->
    Flags;
fin_fits(_, _, _, _, Flags) ->
    Flags band bnot ?TH_FIN.

%% The segment's sequence number: the ISS for a SYN; the FIN's own number when it goes
%% again with nothing before it; snd_nxt for anything with a length, or in persist; and
%% otherwise snd_max, so an ACK names the next new byte.
segment({next, Nxt}, Len, Flags, #tcb{iss = Iss, snd_max = Max, fin = Fin} = Tcb) ->
    FinSent = fin_state(Fin) =:= sent,
    Start = if
                Flags band ?TH_SYN =/= 0 -> Iss;
                Flags band ?TH_FIN =/= 0, Len =:= 0, FinSent, Nxt =:= Max -> Nxt - 1;
                Len > 0; Flags band ?TH_FIN =/= 0 -> Nxt;
                true -> case persisting(Tcb) of
                            true -> Tcb#tcb.snd_nxt;
                            false -> Max
                        end
            end,
    #out_seg{start = Start, len = Len, flags = Flags, source = next, sendalot = false};
segment(#rxmt{kind = Kind, start = S, more = More}, Len, Flags, _) ->
    #out_seg{start = S, len = Len, flags = Flags, source = Kind, sendalot = More}.

%% Whether anything is worth a segment (the `goto send` lines), in FreeBSD's order: sender
%% silly-window avoidance and Nagle for data, a window update, then ACK, RST, a SYN (not
%% the one a simultaneous open owes, TF_NEEDSYN, which goes only with an ACK due), urgent
%% data and the FIN.
send_reason(#out_seg{len = Len, flags = Flags} = Seg, #tcb{} = Tcb, Idle, DataEnd) ->
    (Len > 0 andalso data_goes(Seg, Tcb, Idle, DataEnd))
        orelse window_update(Tcb)
        orelse Tcb#tcb.ack_now
        orelse Flags band ?TH_RST =/= 0
        orelse (Flags band ?TH_SYN =/= 0 andalso not Tcb#tcb.need_syn)
        orelse Tcb#tcb.snd_up > Tcb#tcb.snd_una
        orelse (Flags band ?TH_FIN =/= 0
                andalso (fin_state(Tcb#tcb.fin) =/= sent
                         orelse Tcb#tcb.snd_nxt =:= Tcb#tcb.snd_una)).

fin_state({sent, _}) -> sent;
fin_state(Fin) -> Fin.

%% Sender silly-window avoidance: a full segment, counting a timestamp; the last of the
%% data while idle or with TCP_NODELAY (Nagle); a probe; half the largest window the peer
%% offered; a retransmission.
data_goes(#out_seg{start = Start, len = Len, source = Source},
          #tcb{maxseg = Mss, ts = Ts, nodelay = NoDelay, force_data = Force,
               max_sndwnd = MaxSndWnd, snd_nxt = Nxt, snd_max = Max}, Idle, DataEnd) ->
    TsLen = case Ts of
                #ts{} -> ?TS_OPTLEN;
                _ -> 0
            end,
    Len >= Mss
        orelse TsLen + Len >= Mss
        orelse ((Idle orelse NoDelay) andalso Start + Len >= DataEnd)
        orelse Force
        orelse (MaxSndWnd > 0 andalso Len >= MaxSndWnd div 2)
        orelse Nxt < Max
        orelse Source =/= next.

%% Receiver silly-window avoidance for a window update on its own: only when the window
%% grows by two segments and by a quarter of the buffer (or the buffer is small or nearly
%% full), or by half the buffer; never while a delayed ACK will carry it, or once the peer
%% has sent its FIN, or while a simultaneous open's SYN is unacknowledged (TF_NEEDSYN).
window_update(#tcb{state = State, rcv_adv = Adv, rcv_nxt = RcvNxt, maxseg = Mss,
                   rcv_hiwat = Hiwat, deadlines = #deadlines{delack = Delack},
                   need_syn = NeedSyn} = Tcb) ->
    Shift = rcv_shift(Tcb),
    RecWin = recwin(Tcb),
    OldWin = max(0, Adv - RcvNxt),
    Growth = max(0, RecWin - OldWin),
    RecWin > 0 andalso not NeedSyn andalso Delack =:= infinity
        andalso not erx_tcp:have_rcvd_fin(State)
        andalso (OldWin bsr Shift) < ((Growth + OldWin) bsr Shift)
        andalso ((Growth >= 2 * Mss
                  andalso (Growth >= Hiwat div 4 orelse RecWin =< Hiwat div 8
                           orelse Hiwat =< 8 * Mss orelse Growth >= ?TCP_MAXWIN bsl Shift))
                 orelse 2 * Growth >= Hiwat).

%% `just_return`: with SACK, a retransmission timer for what is outstanding; otherwise the
%% persist timer while data waits and neither timer runs.
nothing_sent(#tcb{sack = Sack, snd_max = Max, snd_una = Una, send_timer = none} = Tcb, Ctx)
  when Sack =/= off, Max > Una ->
    arm_rexmt(Tcb, Ctx);
nothing_sent(#tcb{send_timer = none, sndbuf = Buf} = Tcb, Ctx) ->
    case erx_tcp_sndbuf:size(Buf) > 0 of
        true -> start_persist(Tcb, Ctx);
        false -> Tcb
    end;
nothing_sent(Tcb, _) ->
    Tcb.

%% From `send:` to the end of the pass: the options and the MSS clamp, the header, the
%% receive window, then the sequence numbers, the send log and the timers.
transmit(#out_seg{start = Start, flags = Flags0} = Seg0,
         #tcb{rcv_sack = RcvSack0, maxseg = Mss} = Tcb0, Ctx) ->
    Syn = Flags0 band ?TH_SYN =/= 0,
    {Sacks, RcvSack} = sack_blocks(Syn, Tcb0),
    Opts = (options(Syn, Tcb0, Ctx))#tcp_opts{sacks = Sacks},
    Optlen = erx_tcp_wire:optlen(Opts),
    Seg = case Seg0#out_seg.len + Optlen > Mss of
              true -> Seg0#out_seg{len = max(0, Mss - Optlen), flags = Flags0 band bnot ?TH_FIN,
                                   sendalot = true};
              false -> Seg0
          end,
    #out_seg{len = Len, flags = Flags1, sendalot = More} = Seg,
    Tcb1 = Tcb0#tcb{rcv_sack = case Sacks of [] -> RcvSack0; _ -> RcvSack end},
    {Flags, IpEcn, Tcb2} = ecn(Seg#out_seg{flags = Flags1 bor push(Seg, Tcb1)}, Tcb1),
    {Header, RecWin} = header(Seg#out_seg{flags = Flags}, Opts, Tcb2),
    Payload = case Len of
                  0 -> [];
                  _ -> erx_tcp_sndbuf:range(Tcb2#tcb.sndbuf, Start - Tcb2#tcb.snd_una, Len)
              end,
    %% snd_up is dragged along to snd_una unless it lies past this segment's snd_nxt.
    Up = case Tcb2#tcb.snd_up > Tcb2#tcb.snd_nxt of
             true -> Tcb2#tcb.snd_up;
             false -> Tcb2#tcb.snd_una
         end,
    Tcb3 = after_send(Seg#out_seg{flags = Flags}, Tcb2, Ctx),
    #tcb{rcv_nxt = RcvNxt, rcv_adv = Adv, deadlines = Deadlines} = Tcb3,
    Tcb = Tcb3#tcb{rcv_adv = max(Adv, RcvNxt + RecWin), last_ack_sent = RcvNxt,
                   ack_now = false, deadlines = Deadlines#deadlines{delack = infinity},
                   snd_up = Up, rxwin0_sent = Header#tcp.win =:= 0,
                   rexmt_prev = badrxtwin(Opts, Tcb3, Ctx)},
    {Tcb, {Header, #{ecn => IpEcn, df => Mss > ?TCP_MINMSS}, Payload}, More}.

%% t_badrxtwin (tcp_output.c:848-849): the first segment sent with a timestamp after the
%% first timeout, the retransmission, records our clock, without the offset, as the time
%% before which an echoed timestamp shows that an acknowledgement answers an original
%% transmission. FreeBSD moves it on every segment sent while the backoff is 1, so a pure ACK
%% sent after the retransmission makes the peer's ACK of it look like one of the original,
%% and a real timeout is undone; only the first is recorded here (RFC 3522's Eifel
%% detection, which compares with the retransmission's own timestamp).
badrxtwin(#tcp_opts{ts = {_, _}},
          #tcb{rxtshift = 1, rexmt_prev = #rexmt_prev{badrxtwin = none} = Prev},
          #tcp_ctx{now = Now}) ->
    Prev#rexmt_prev{badrxtwin = Now div 1000};
badrxtwin(_, #tcb{rexmt_prev = Prev}, _) ->
    Prev.

%% The SACK blocks an acknowledgement carries once synchronized with SACK negotiated, and
%% the receiver's SACK value with the D-SACK block reported.
sack_blocks(false, #tcb{sack = on, state = State, rcv_sack = RcvSack}) ->
    case erx_tcp:have_established(State) of
        true ->
            {Blocks, Next} = erx_tcp_sack:ack(RcvSack),
            {[{erx_tcp_seq:wire(L), erx_tcp_seq:wire(R)} || {L, R} <- Blocks], Next};
        false ->
            {[], RcvSack}
    end;
sack_blocks(_, #tcb{rcv_sack = RcvSack}) ->
    {[], RcvSack}.

%% The options before the SACK blocks: on a SYN the MSS (tcp_mssopt), the window scale and
%% SACK-permitted when asked for or negotiated; timestamps once negotiated, or on a SYN
%% that asks for them, echoing ts_recent.
options(Syn, #tcb{family = Family, wscale = Wscale, sack = Sack, ts = Ts},
        #tcp_ctx{mtu = Mtu} = Ctx) ->
    TsOpt = case {Ts, Syn} of
                {#ts{recent = Recent, offset = Offset}, _} -> {erx_tcp:ts_now(Offset, Ctx), Recent};
                {{requested, Offset}, true} -> {erx_tcp:ts_now(Offset, Ctx), 0};
                _ -> none
            end,
    case Syn of
        true ->
            #tcp_opts{mss = min(16#ffff, max(0, erx_tcp_mss:mssopt(Family, Mtu, 0))),
                      wscale = case Wscale of
                                   requested -> request_r_scale();
                                   {_, Rcv} -> Rcv;
                                   off -> none
                               end,
                      sack_permitted = Sack =/= off, ts = TsOpt};
        false ->
            #tcp_opts{ts = TsOpt}
    end.

%% PSH on the segment that sends the last of the data.
push(#out_seg{start = Start, len = Len, flags = Flags}, #tcb{snd_una = Una, sndbuf = Buf})
  when Len > 0, Flags band ?TH_SYN =:= 0 ->
    case Start + Len =:= Una + erx_tcp_sndbuf:size(Buf) of
        true -> ?TH_PUSH;
        false -> 0
    end;
push(_, _) ->
    0.

%% tcp_ecn_output_established, once a SYN has been received: the TCP flags and the IP
%% header's ECN codepoint.
ecn(#out_seg{len = Len, flags = Flags, source = Source},
    #tcb{state = State, ecn = Ecn0, snd_nxt = Nxt, snd_max = Max, force_data = Force} = Tcb) ->
    case erx_tcp:have_rcvd_syn(State) of
        true ->
            Phase = case State of
                        syn_received -> syn_received;
                        _ -> synchronized
                    end,
            {EcnFlags, IpEcn, Ecn} =
                erx_tcp_ecn:output(#{len => Len, snd_nxt => Nxt, snd_max => Max,
                                     retransmit => Source =/= next, forced => Force,
                                     phase => Phase}, Ecn0),
            {Flags bor EcnFlags, IpEcn, Tcb#tcb{ecn = Ecn}};
        false ->
            {Flags, 0, Tcb}
    end.

%% The TCP header and the window it advertises. The window is 0 on a RST, held at 0 below a
%% quarter of the buffer and one segment, never below what was offered before, rounded up
%% to the scale; a SYN's window is unscaled. The urgent pointer follows snd_up.
header(#out_seg{start = Start, flags = Flags0}, Opts,
       #tcb{local = {_, LPort}, remote = {_, RPort}, rcv_nxt = RcvNxt, rcv_adv = Adv,
            maxseg = Mss, rcv_hiwat = Hiwat, snd_up = Up, snd_nxt = Nxt} = Tcb) ->
    Shift = rcv_shift(Tcb),
    RecWin0 = recwin(Tcb),
    RecWin1 = case RecWin0 < Hiwat div 4 andalso RecWin0 < Mss of
                  true -> 0;
                  false -> RecWin0
              end,
    RecWin2 = max(RecWin1, Adv - RcvNxt),
    {Win, RecWin} = case Flags0 band ?TH_SYN of
                        0 ->
                            Rounded = ((RecWin2 + (1 bsl Shift) - 1) bsr Shift) bsl Shift,
                            {min(Rounded bsr Shift, ?TCP_MAXWIN), Rounded};
                        _ ->
                            {min(erx_tcp:rcv_space(Tcb), ?TCP_MAXWIN), RecWin2}
                    end,
    {Urp, Flags} = case Up > Nxt of
                       true -> {min(Up - Nxt, 16#ffff), Flags0 bor ?TH_URG};
                       false -> {0, Flags0}
                   end,
    {#tcp{sport = LPort, dport = RPort, seq = erx_tcp_seq:wire(Start),
          ack = erx_tcp_seq:wire(RcvNxt), flags = Flags, win = Win, urp = Urp, opts = Opts},
     RecWin}.

%% `sbspace(&so->so_rcv)` up to the largest window the scale can say.
recwin(Tcb) ->
    min(erx_tcp:rcv_space(Tcb), ?TCP_MAXWIN bsl rcv_shift(Tcb)).

rcv_shift(#tcb{wscale = {_, Shift}}) -> Shift;
rcv_shift(#tcb{}) -> 0.

%% After the segment (`out:`): snd_nxt moves past it unless it is a probe in persist, which
%% only moves snd_max; new data moves snd_max and starts an RTT measurement; the send log
%% records what the segment carried (see the module documentation for a sequential segment
%% below snd_max); the retransmission timer starts for what is outstanding, or the persist
%% timer when data waits and nothing went. A probe into an open window has already stopped
%% persist in decide/3, so only a probe into a zero window takes the first branch.
after_send(#out_seg{start = Start, len = Len, flags = Flags, source = Source},
           #tcb{snd_nxt = Nxt0, snd_max = Max0, snd_una = Una, sendlog = Log0,
                snd_recover = Recover, sndbuf = Buf, fin = Fin0} = Tcb0,
           #tcp_ctx{now = Now} = Ctx) ->
    SynLen = bit(Flags, ?TH_SYN),
    FinLen = bit(Flags, ?TH_FIN),
    End = Start + SynLen + Len + FinLen,
    Fin = case FinLen of
              1 -> {sent, Start + SynLen + Len};
              0 -> Fin0
          end,
    Log = if
              End =:= Start -> Log0;
              Source =:= rescue -> erx_tcp_sendlog:rescued(Log0, Start, End, Recover, Now);
              Source =:= retransmit -> erx_tcp_sendlog:sent(Log0, Start, End, Now);
              End > Max0 -> erx_tcp_sendlog:sent(Log0, max(Start, Max0), End, Now);
              true -> Log0
          end,
    Tcb1 = Tcb0#tcb{sendlog = Log, fin = Fin},
    case Tcb0#tcb.force_data andalso persisting(Tcb0) of
        true ->
            Tcb1#tcb{snd_max = max(Max0, End)};
        false ->
            Nxt = case {Source, End =:= Start} of
                      {next, true} -> Nxt0;
                      {next, false} -> End;
                      _ -> max(Nxt0, End)
                  end,
            Tcb2 = case Source =:= next andalso Nxt > Max0 of
                       true -> new_data_sent(Tcb1#tcb{snd_nxt = Nxt, snd_max = Nxt}, Start, Now);
                       false -> Tcb1#tcb{snd_nxt = Nxt}
                   end,
            Rexmt = case Tcb2#tcb.send_timer of
                        {rexmt, _} -> true;
                        _ -> false
                    end,
            Outstanding = (Source =/= next andalso Nxt =/= Tcb2#tcb.snd_max) orelse Nxt =/= Una,
            if
                not Rexmt, Outstanding ->
                    arm_rexmt(stop_persist(Tcb2), Ctx);
                Len =:= 0, Tcb2#tcb.send_timer =:= none ->
                    case erx_tcp_sndbuf:size(Buf) > 0 of
                        true -> start_persist(Tcb2, Ctx);
                        false -> Tcb2
                    end;
                true ->
                    Tcb2
            end
    end.

%% snd_nxt back to snd_una (tcp_output.c:500-502), the bytes after it lost in the log.
rewind(#tcb{snd_una = Una, snd_max = Max, sendlog = Log} = Tcb) when Max > Una ->
    Tcb#tcb{snd_nxt = Una, sendlog = erx_tcp_sendlog:lose(Log, Una, Max)};
rewind(#tcb{snd_una = Una} = Tcb) ->
    Tcb#tcb{snd_nxt = Una}.

new_data_sent(#tcb{rtt_probe = none} = Tcb, Start, Now) ->
    Tcb#tcb{sndtime = Now, rtt_probe = {Start, Now}};
new_data_sent(Tcb, _, Now) ->
    Tcb#tcb{sndtime = Now}.

bit(Flags, Bit) when Flags band Bit =/= 0 -> 1;
bit(_, _) -> 0.

%% ENOBUFS: the segment the credit does not cover is not sent; the congestion window drops
%% to one segment (tcp_maxseg) and a segment that carried sequence space leaves a send
%% timer armed.
enobufs(#out_seg{len = Len, flags = Flags}, #tcb{ccv = Ccv, maxseg = Mss, ts = Ts} = Tcb, Ctx) ->
    Tcb1 = Tcb#tcb{ccv = Ccv#ccv{cwnd = erx_tcp_mss:maxseg(Mss, {synchronized, is_record(Ts, ts), 0})}},
    case (Len > 0 orelse Flags band (?TH_SYN bor ?TH_FIN) =/= 0)
         andalso Tcb#tcb.send_timer =:= none of
        true -> arm_rexmt(Tcb1, Ctx);
        false -> Tcb1
    end.

%% The RST|ACK of a dropped connection (tcp_drop's tcp_output in CLOSED): at snd_max,
%% acknowledging rcv_nxt, as erx_tcp:respond/5 builds a RST.
reset(#tcb{} = Tcb, #tcp_ctx{credit = 0}) ->
    {done(Tcb#tcb{reset_peer = false}), []};
reset(#tcb{snd_max = Max, rcv_nxt = RcvNxt} = Tcb, Ctx) ->
    {done(Tcb#tcb{reset_peer = false}), [erx_tcp:respond(Tcb, Ctx, Max, RcvNxt, ?TH_RST bor ?TH_ACK)]}.

%% The send timer: the retransmission or the persist timer, never both (send_timer), with
%% the backoff count beside it (rxtshift, FreeBSD's t_rxtshift).
persisting(#tcb{send_timer = {persist, _}}) -> true;
persisting(#tcb{}) -> false.

%% tcp_timer_activate(tp, TT_PERSIST, 0) with t_rxtshift = 0.
stop_persist(#tcb{send_timer = {persist, _}} = Tcb) -> Tcb#tcb{send_timer = none, rxtshift = 0};
stop_persist(Tcb) -> Tcb.

%% tcp_timer_activate(tp, TT_REXMT, TP_RXTCUR(tp)), keeping the backoff count.
arm_rexmt(#tcb{rtt = Rtt} = Tcb, #tcp_ctx{now = Now}) ->
    Tcb#tcb{send_timer = {rexmt, Now + erx_tcp_rtt:rto(Rtt) * 1000}}.

%% Output's entries into persist stop the retransmission timer and its count first
%% (t_rxtshift = 0; tcp_setpersist).
start_persist(Tcb, Ctx) ->
    persist(Tcb#tcb{send_timer = none, rxtshift = 0}, 0, Ctx).

persist(#tcb{rtt = Rtt} = Tcb, Shift, #tcp_ctx{now = Now}) ->
    Timeout = erx_tcp_rtt:persist(Rtt, Shift),
    Tcb#tcb{send_timer = {persist, Now + Timeout * 1000}, rxtshift = min(Shift + 1, ?TCP_RETRIES),
            rexmt_prev = none}.
