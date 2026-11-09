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

-module(erx_tcp_input).
-moduledoc """
A connection's segment pipeline (docs/design-network-stack.md, "Events and the step"),
the translation of `tcp_do_segment` (sys/netinet/tcp_input.c) split by stage. Each segment
runs through `stages/0` in order. A stage returns:

* `{continue, Tcb, Seg}` or `{continue, Tcb, Seg, Actions}` to pass the segment on,
  possibly changed (lifted into the connection's sequence space, trimmed to the window);
* `{goto, Stage, Tcb, Seg, Actions}` to pass it to a later stage, skipping those between,
  as `tcp_do_segment` jumps to its `process_ACK` and `step6` labels;
* `{done, Tcb, Actions}` where `tcp_do_segment` finishes with it: at its `drop`,
  `dropafterack` and `dropwithreset` exits, or after the last stage.

The stages, in the order `tcp_do_segment` takes them, since the order is visible on the
wire, are `lift`, `timestamps`, `header_prediction`, `syn_sent`, `check_rst`, `check_syn`,
`paws`, `trim`, `check_ack`, `ack`, `process_ack` (the `process_ACK` label), `step6`
(the window update and the urgent pointer), `data` and `fin`. `header_prediction`, `ack`,
`process_ack`, `step6`, `data`
and `fin` pass every segment on unchanged here; their translations replace them.

A stage ends the connection with erx_tcp_user:drop/2 (`tcp_drop`) or close/1 (`tcp_close`).
The segments of one event are processed in order. Once one ends the connection, the rest
are for a connection that no longer exists, so each goes back to the interface in a
`reinject` action to be demultiplexed again, as FreeBSD looks each segment up anew.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([segments/3, stages/0]).

-export_type([stage/0, result/0]).

-doc "What a stage returns (see the module documentation).".
-type result() :: {continue, #tcb{}, #seg{}}
                | {continue, #tcb{}, #seg{}, [erx_tcp:action()]}
                | {goto, Stage :: atom(), #tcb{}, #seg{}, [erx_tcp:action()]}
                | {done, #tcb{}, [erx_tcp:action()]}.

-doc """
A named stage: the segment as the previous stage passed it on (the segment as the interface
handed it before `lift`, a #seg{} after), the control block and the context.
""".
-type stage() :: {Name :: atom(),
                  fun((Segment :: erx_tcp:segment() | #seg{}, #tcb{}, #tcp_ctx{}) -> result())}.

-define(TCP_MAXWIN, 16#ffff).
%% tcp_timer.h: TCPTV_DELACK (hz / 25), tcp_delacktime, in milliseconds.
-define(TCPTV_DELACK, 40).
%% tcp_seq.h: TCP_PAWS_IDLE, 24 days in milliseconds.
-define(TCP_PAWS_IDLE, (24 * 24 * 60 * 60 * 1000)).
%% sys/sockbuf.h: SB_MAX, the default sb_max, the largest socket buffer and the bound on the
%% window shift a SYN asks for.
-define(SB_MAX, (2 * 1024 * 1024)).
-define(TCP_MAX_WINSHIFT, 14).

-doc "Runs each segment through the stages, in order (see the module documentation).".
-spec segments([erx_tcp:segment()], #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
segments(Segments, Tcb, Ctx) ->
    segments(Segments, Tcb, Ctx, stages(), []).

segments([], Tcb, _, _, Actions) ->
    {Tcb, Actions};
segments(Rest, #tcb{ended = true} = Tcb, _, _, Actions) ->
    {Tcb, Actions ++ [{reinject, Segment} || Segment <- Rest]};
segments([Segment | Rest], Tcb0, Ctx, Stages, Actions) ->
    {Tcb, More} = pipeline(Stages, Segment, Tcb0, Ctx, []),
    segments(Rest, Tcb, Ctx, Stages, Actions ++ More).

pipeline([], _, Tcb, _, Actions) ->
    {Tcb, Actions};
pipeline([{_, Stage} | Rest], Segment0, Tcb0, Ctx, Actions) ->
    case Stage(Segment0, Tcb0, Ctx) of
        {continue, Tcb, Segment} -> pipeline(Rest, Segment, Tcb, Ctx, Actions);
        {continue, Tcb, Segment, More} -> pipeline(Rest, Segment, Tcb, Ctx, Actions ++ More);
        {goto, Label, Tcb, Segment, More} ->
            pipeline(later(Label, Rest), Segment, Tcb, Ctx, Actions ++ More);
        {done, Tcb, More} -> {Tcb, Actions ++ More}
    end.

%% The stages from Label on. A jump goes only forward, to a stage that exists.
later(Label, Rest) ->
    case lists:dropwhile(fun({Name, _}) -> Name =/= Label end, Rest) of
        [] -> error({no_later_stage, Label});
        Stages -> Stages
    end.

-doc "The stages, in `tcp_do_segment`'s order.".
-spec stages() -> [stage()].
stages() ->
    [{lift, fun lift/3}, {timestamps, fun timestamps/3}, {header_prediction, fun pass/3},
     {syn_sent, fun syn_sent/3}, {check_rst, fun check_rst/3}, {check_syn, fun check_syn/3},
     {paws, fun paws/3}, {trim, fun trim/3}, {check_ack, fun check_ack/3},
     {ack, fun pass/3}, {process_ack, fun pass/3}, {step6, fun pass/3}, {data, fun pass/3},
     {fin, fun pass/3}].

pass(Seg, Tcb, _) -> {continue, Tcb, Seg}.

%% ---------------------------------------------------------------------------------------
%% 1. lift (tcp_input.c:1511-1690): the segment into the connection's sequence space; a
%% SYN-ACK in SYN-SENT that acknowledges something we never sent answered with a RST
%% (:1556-1561); t_rcvtime; the window scaled (:1584); the timestamp echo back on our clock
%% (:1624-1629). FreeBSD reads the segment's ECN here (:1592-1595), before any check; the
%% stack reads it in `check_ack`, once the segment has passed them all, so a blind segment
%% can neither cut the congestion window with ECE nor make us echo CE or stop echoing it.
%%
%% FreeBSD also takes a SYN's options here in SYN-SENT (:1636-1690), before it knows whether
%% the segment is acceptable; the `syn_sent` stage takes them once it has accepted the SYN,
%% so a RST or SYN that SYN-SENT drops cannot change what the connection asks for.
%%
%% TIME-WAIT is tcp_twcheck's, not tcp_do_segment's, and a control block that has not
%% connected has no four-tuple to receive on, so the pipeline takes neither's segments.
lift(_, #tcb{state = State} = Tcb, _) when State =:= closed; State =:= time_wait ->
    {done, Tcb, []};
lift({#tcp{seq = Seq0, ack = Ack0, flags = Flags, win = Win, urp = Urp, opts = Opts},
      Payload, IpEcn}, Tcb0, #tcp_ctx{now = Now} = Ctx)
  when is_binary(Payload), is_integer(IpEcn), IpEcn >= 0, IpEcn =< 3 ->
    #tcb{state = State, rcv_nxt = RcvNxt, snd_una = Una, iss = Iss, snd_max = SndMax} = Tcb0,
    %% In SYN-SENT nothing has been received to measure against: the SYN's own number is
    %% the initial receive sequence number, its wire value as the ISS is ours.
    Seq = case State of
              syn_sent -> Seq0;
              _ -> erx_tcp_seq:lift(Seq0, RcvNxt)
          end,
    Ack = erx_tcp_seq:lift(Ack0, Una),
    First = Seq + syn_len(Flags),
    Seg = #seg{seq = Seq, ack = Ack, flags = Flags, hdr_flags = Flags,
               win = Win bsl snd_scale(Tcb0), urp = Urp, data = Payload,
               arrived = {First, First + byte_size(Payload)},
               ts = ts_option(Opts#tcp_opts.ts, Tcb0#tcb.ts, Ctx),
               mss = Opts#tcp_opts.mss, wscale = Opts#tcp_opts.wscale,
               sack_permitted = Opts#tcp_opts.sack_permitted,
               sacks = sack_blocks(Opts#tcp_opts.sacks, Tcb0), ip_ecn = IpEcn},
    BadAck = State =:= syn_sent andalso has(Flags, ?TH_ACK) andalso (Ack =< Iss orelse Ack > SndMax),
    case BadAck of
        true ->
            dropwithreset(Seg, Tcb0, Ctx);
        false ->
            {continue, Tcb0#tcb{rcvtime = Now}, Seg}
    end.

%% TSval against the last one recorded; TSecr, unless 0, less our offset and lifted onto our
%% millisecond clock, `none` when it lands at 0 or in the future. A connection that asked
%% for or negotiated no timestamps keeps the option for the `timestamps` stage to judge.
ts_option(none, _, _) ->
    none;
ts_option({Val, Ecr}, Ts, Ctx) ->
    {Recent, Offset} = case Ts of
                           #ts{recent = R, offset = O} -> {R, O};
                           {requested, O} -> {0, O};
                           off -> {0, 0}
                       end,
    {erx_tcp_seq:lift(Val, Recent), echo(Ecr, Offset, Ctx)}.

echo(0, _, _) ->
    none;
echo(Ecr, Offset, #tcp_ctx{now = Now}) ->
    Clock = Now div 1000,
    case erx_tcp_seq:wire(Ecr - Offset) of
        0 -> none;
        Ours ->
            case erx_tcp_seq:lift(Ours, Clock) of
                Later when Later > Clock -> none;
                Sent -> Sent
            end
    end.

%% TF2_PROC_SACK_PROHIBIT: a peer whose segments are too small to keep a scoreboard for has
%% its SACK blocks ignored (erx_tcp_mss:sack_prohibited/1).
sack_blocks(Blocks, #tcb{maxseg = Maxseg, snd_una = Una}) ->
    case erx_tcp_mss:sack_prohibited(Maxseg) of
        true -> [];
        false -> [{erx_tcp_seq:lift(S, Una), erx_tcp_seq:lift(E, Una)} || {S, E} <- Blocks]
    end.

%% ---------------------------------------------------------------------------------------
%% 2. timestamps (tcp_input.c:1692-1729): RFC 7323 section 3.2. On a connection that
%% negotiated timestamps a segment without one is processed when it is a RST or when
%% tcp_tolerate_missing_ts allows it, and dropped otherwise. On one that did not, a
%% segment's timestamp is ignored: FreeBSD logs it and still records it as ts_recent and
%% checks PAWS against it; here the later stages do not see it.
timestamps(#seg{ts = none, flags = Flags} = Seg, #tcb{ts = #ts{}} = Tcb, _) ->
    case has(Flags, ?TH_RST) orelse tolerate_missing_ts() of
        true -> {continue, Tcb, Seg};
        false -> {done, Tcb, []}
    end;
timestamps(Seg, #tcb{ts = off} = Tcb, _) ->
    {continue, Tcb, Seg#seg{ts = none}};
timestamps(Seg, Tcb, _) ->
    {continue, Tcb, Seg}.

%% tcp_tolerate_missing_ts (tcp_subr.c:219): FreeBSD's default of 1.
tolerate_missing_ts() -> true.

%% ---------------------------------------------------------------------------------------
%% 3. syn_sent (tcp_input.c:1952-2140): the receive window, at least what was advertised
%% (:1958-1961), then the handshake states of tcp_do_segment's switch. SYN-RECEIVED answers
%% an ACK of something other than our SYN with a RST (:1969-1980). SYN-SENT ends the
%% connection on a RST that acknowledges our SYN (ECONNREFUSED), drops any other RST and
%% anything without a SYN, and otherwise takes the SYN: its options, the initial receive
%% sequence number, and either ESTABLISHED (FIN-WAIT-1 when the owner has already shut
%% down) on a SYN-ACK or SYN-RECEIVED on a simultaneous open.
syn_sent(Seg, #tcb{rcv_adv = RcvAdv, rcv_nxt = RcvNxt} = Tcb0, Ctx) ->
    Tcb = Tcb0#tcb{rcv_wnd = max(erx_tcp:rcv_space(Tcb0), RcvAdv - RcvNxt)},
    case Tcb#tcb.state of
        syn_received -> syn_received(Seg, Tcb, Ctx);
        syn_sent -> syn_sent_segment(Seg, Tcb, Ctx);
        _ -> {continue, Tcb, Seg}
    end.

syn_received(#seg{flags = Flags, ack = Ack} = Seg, #tcb{snd_una = Una, snd_max = SndMax} = Tcb,
             Ctx) ->
    case not has(Flags, ?TH_RST) andalso has(Flags, ?TH_ACK)
        andalso (Ack =< Una orelse Ack > SndMax) of
        true -> dropwithreset(Seg, Tcb, Ctx);
        false -> {continue, Tcb, Seg}
    end.

syn_sent_segment(#seg{flags = Flags} = Seg, Tcb, Ctx) ->
    case {has(Flags, ?TH_RST), has(Flags, ?TH_ACK), has(Flags, ?TH_SYN)} of
        {true, true, _} -> {done, erx_tcp_user:drop(Tcb, econnrefused), []};
        {true, false, _} -> {done, Tcb, []};
        {false, _, false} -> {done, Tcb, []};
        {false, _, true} -> take_syn(Seg, Tcb, Ctx)
    end.

take_syn(#seg{seq = Irs, flags = Flags0, win = Win, data = Data0} = Seg0, Tcb0, Ctx) ->
    {Tcb1, Buffers} = negotiate(Seg0, Tcb0, Ctx),
    %% tcp_rcvseqinit.
    Tcb2 = Tcb1#tcb{irs = Irs, rcv_nxt = Irs + 1, rcv_adv = Irs + 1},
    {Tcb3, Flags1} = case has(Flags0, ?TH_ACK) of
                         true -> synack(Seg0, Tcb2, Ctx);
                         %% A simultaneous open: the SYN-ACK goes out now, and the SYN's
                         %% retransmission timer stops (its count stays).
                         false -> {Tcb2#tcb{ack_now = true, send_timer = none,
                                            state = syn_received}, Flags0}
                     end,
    %% The data after the SYN, trimmed to the window, which drops a FIN past it.
    Seq = Irs + 1,
    RcvWnd = Tcb3#tcb.rcv_wnd,
    {Data, Flags} = case byte_size(Data0) > RcvWnd of
                        true -> {binary:part(Data0, 0, RcvWnd), Flags1 band bnot ?TH_FIN};
                        false -> {Data0, Flags1}
                    end,
    Tcb = Tcb3#tcb{snd_wl1 = Seq - 1, rcv_up = Seq, snd_wnd = Win},
    Seg = Seg0#seg{seq = Seq, data = Data, flags = Flags},
    case has(Flags, ?TH_ACK) of
        true -> {goto, process_ack, Tcb, Seg, Buffers};
        false -> {goto, step6, Tcb, Seg, Buffers}
    end.

%% The SYN's options (tcp_input.c:1636-1672), taken against what our SYN asked for: window
%% scaling with the shift we asked for (applied by both sides once each has sent its SYN),
%% timestamps with the SYN's TSval as ts_recent, SACK, which restarts the loss module with
%% SACK on, the parallel-SYN ECN rule, and the MSS from the option when there is one
%% (tcp_mss), whose rounded buffer sizes are asked of the grant.
negotiate(#seg{wscale = PeerShift, ts = SegTs, sack_permitted = SackOk, mss = Mss,
               flags = Flags},
          #tcb{wscale = Wscale0, ts = Ts0, sack = Sack0, loss = Loss} = Tcb0,
          #tcp_ctx{now = Now} = Ctx) ->
    Wscale = case {PeerShift, Wscale0} of
                 {Shift, requested} when is_integer(Shift) -> {Shift, request_r_scale()};
                 _ -> off
             end,
    Ts = case {SegTs, Ts0} of
             {{Val, _}, {requested, Offset}} ->
                 #ts{recent = erx_tcp_seq:wire(Val), recent_age = Now, offset = Offset};
             _ -> off
         end,
    Tcb1 = Tcb0#tcb{wscale = Wscale, ts = Ts,
                    ecn = erx_tcp_ecn:input_parallel_syn(Flags, Tcb0#tcb.ecn)},
    Tcb2 = case Sack0 =:= requested andalso SackOk of
               true -> Tcb1#tcb{sack = on, loss_state = Loss:init(#{sack => true})};
               false -> Tcb1#tcb{sack = off}
           end,
    case Mss of
        none -> {Tcb2, []};
        _ -> tcp_mss(Mss, Tcb2, Ctx)
    end.

%% tcp_mss: the MSS from the peer's offer and the path; buffers rounded up to whole segments
%% are asked of the grant, whose answer sets them ({buffer, Kind, Bytes}).
tcp_mss(Offer, #tcb{family = Family, snd_hiwat = Snd0, rcv_hiwat = Rcv0} = Tcb,
        #tcp_ctx{mtu = Mtu}) ->
    {Maxseg, Snd, Rcv} = erx_tcp_mss:mss(Family, Offer, {Mtu, 0}, {Snd0, Rcv0}, ?SB_MAX),
    {Tcb#tcb{maxseg = Maxseg},
     [{reserve_buffer, snd, Snd} || Snd =/= Snd0] ++ [{reserve_buffer, rcv, Rcv} || Rcv =/= Rcv0]}.

%% The window shift our SYN asks for (tcp_connect, tcp_usrreq.c): the smallest that lets the
%% largest socket buffer, sb_max, be advertised.
request_r_scale() -> request_r_scale(0).

request_r_scale(Shift) when Shift < ?TCP_MAX_WINSHIFT, ?TCP_MAXWIN bsl Shift < ?SB_MAX ->
    request_r_scale(Shift + 1);
request_r_scale(Shift) ->
    Shift.

%% A SYN-ACK accepted in SYN-SENT (tcp_input.c:2047-2104): our SYN is acknowledged, the
%% advertised edge moves by the window, data on it waits for a delayed ACK and anything else
%% is acknowledged at once, ECN follows the SYN-ACK, and the connection is established, or
%% in FIN-WAIT-1 owing its FIN when the owner shut down first, the SYN then taken out of
%% the flags. An established connection initialises its congestion window and starts the
%% keepalive's idle time.
synack(#seg{flags = Flags, data = Data}, Tcb0, #tcp_ctx{now = Now} = Ctx) ->
    #tcb{rcv_adv = RcvAdv, rcv_wnd = RcvWnd, snd_una = Una0, snd_nxt = SndNxt,
         deadlines = D} = Tcb0,
    Una = Una0 + 1,
    Tcb1 = Tcb0#tcb{rcv_adv = RcvAdv + min(RcvWnd, ?TCP_MAXWIN bsl rcv_scale(Tcb0)),
                    snd_una = Una, snd_nxt = max(SndNxt, Una),
                    ecn = erx_tcp_ecn:input_syn_sent(Flags, Tcb0#tcb.ecn)},
    Tcb2 = case Data =/= <<>> andalso delay_ack(Tcb1, byte_size(Data)) of
               true -> Tcb1#tcb{deadlines = D#deadlines{delack = Now + ms(?TCPTV_DELACK)}};
               false -> Tcb1#tcb{ack_now = true}
           end,
    case Tcb2#tcb.fin of
        queued ->
            {Tcb2#tcb{state = fin_wait_1}, Flags band bnot ?TH_SYN};
        _ ->
            Tcb3 = cc_conn_init(Tcb2#tcb{state = established}, Ctx),
            Keep = Now + ms(Tcb3#tcb.keep_idle),
            {Tcb3#tcb{deadlines = (Tcb3#tcb.deadlines)#deadlines{keep = Keep}}, Flags}
    end.

%% DELAY_ACK (tcp_input.c:511): no delayed ACK pending, a segment no larger than t_maxseg,
%% and tcp_delack_enabled, FreeBSD's default of 1. Its TF_RXWIN0SENT term is false in
%% SYN-SENT, where we have sent only SYNs.
delay_ack(#tcb{deadlines = #deadlines{delack = Delack}, maxseg = Maxseg}, Tlen) ->
    Delack =:= infinity andalso Tlen =< Maxseg.

%% cc_conn_init (tcp_input.c:361) without a host cache: the initial window, or one segment
%% when the SYN had to be retransmitted (the window the retransmission left), then the
%% congestion module's own conn_init.
cc_conn_init(#tcb{cc = Cc, ccv = Ccv0, maxseg = Maxseg0, ts = Ts} = Tcb, Ctx) ->
    Maxseg = erx_tcp_mss:maxseg(Maxseg0, {synchronized, is_record(Ts, ts), 0}),
    Initwnd = erx_tcp_mss:initwnd(Maxseg),
    Cwnd = case Ccv0#ccv.cwnd of
               1 -> Maxseg;
               _ -> Initwnd
           end,
    Ccv = erx_tcp:ccv(Tcb#tcb{ccv = Ccv0#ccv{cwnd = Cwnd, initwnd = Initwnd}}, Ctx),
    Tcb#tcb{ccv = Cc:conn_init(Ccv)}.

%% ---------------------------------------------------------------------------------------
%% 4. check_rst (tcp_input.c:2148-2194): RFC 5961 section 3, measured from last_ack_sent so
%% that a delayed ACK does not move the target. A RST at exactly last_ack_sent ends the
%% connection (ECONNREFUSED in SYN-RECEIVED, ECONNRESET after); one elsewhere in the window
%% draws a challenge ACK; with the window closed only the exact match counts; any other RST
%% is dropped. tcp_insecure_rst is FreeBSD's default of 0.
check_rst(#seg{flags = Flags, seq = Seq} = Seg, Tcb, Ctx) ->
    #tcb{last_ack_sent = LastAck, rcv_wnd = RcvWnd, state = State} = Tcb,
    case has(Flags, ?TH_RST) of
        false ->
            {continue, Tcb, Seg};
        true when Seq =:= LastAck ->
            Error = case State of
                        syn_received -> econnrefused;
                        _ -> econnreset
                    end,
            {done, erx_tcp_user:close(Tcb#tcb{error = Error}), []};
        true when Seq > LastAck, Seq < LastAck + RcvWnd ->
            challenge_ack(rst, Tcb, Ctx);
        true ->
            {done, Tcb, []}
    end.

%% ---------------------------------------------------------------------------------------
%% 5. check_syn (tcp_input.c:2196-2215): RFC 5961 section 4. A SYN in a synchronized state
%% draws a challenge ACK and is dropped; tcp_insecure_syn is FreeBSD's default of 0. FreeBSD
%% also lets the SYN's ECE turn ECN on here (tcp_ecn_input_syn_sent); a SYN that passed no
%% sequence check changes nothing here.
check_syn(#seg{flags = Flags} = Seg, #tcb{state = State} = Tcb, Ctx) ->
    case has(Flags, ?TH_SYN) andalso State =/= syn_sent andalso State =/= syn_received of
        true -> challenge_ack(syn, Tcb, Ctx);
        false -> {continue, Tcb, Seg}
    end.

%% ---------------------------------------------------------------------------------------
%% 6. paws (tcp_input.c:2218-2245): RFC 7323 PAWS. A TSval older than a valid ts_recent
%% drops the segment, acknowledging it if it carries data; once ts_recent is more than 24
%% days old it is invalidated instead, and the segment goes on.
paws(#seg{ts = {Val, _}, data = Data} = Seg,
     #tcb{ts = #ts{recent = Recent, recent_age = Age} = Ts} = Tcb, #tcp_ctx{now = Now} = Ctx)
  when Recent =/= 0, Val < Recent ->
    case Now - Age > ms(?TCP_PAWS_IDLE) of
        true -> {continue, Tcb#tcb{ts = Ts#ts{recent = 0}}, Seg};
        false when Data =/= <<>> -> dropafterack(Seg, Tcb, Ctx);
        false -> {done, Tcb, []}
    end;
paws(Seg, Tcb, _) ->
    {continue, Tcb, Seg}.

%% ---------------------------------------------------------------------------------------
%% 7. trim (tcp_input.c:2247-2389): a segment before IRS in SYN-RECEIVED is answered with a
%% RST (the LAND check); what lies before rcv_nxt is cut off, a SYN with it, and a segment
%% entirely before it is acknowledged at once and keeps only its ACK; data after the owner
%% closed resets the connection; what lies past the window is cut off with PUSH and FIN,
%% and a segment entirely past it is acknowledged and dropped, unless the window is closed
%% and it starts at rcv_nxt; then ts_recent is taken from a segment that covers
%% last_ack_sent.
trim(#seg{seq = Seq} = Seg, #tcb{state = syn_received, irs = Irs} = Tcb, Ctx) when Seq < Irs ->
    dropwithreset(Seg, Tcb, Ctx);
trim(Seg0, Tcb0, Ctx) ->
    {Seg1, Tcb1} = trim_front(Seg0, Tcb0),
    #tcb{user_closed = Closed, state = State} = Tcb1,
    case Closed andalso Seg1#seg.data =/= <<>> andalso not erx_tcp:have_rcvd_fin(State) of
        true ->
            dropwithreset(Seg1, erx_tcp_user:close(Tcb1), Ctx);
        false ->
            case trim_back(Seg1, Tcb1) of
                {ok, Seg, Tcb} -> {continue, ts_recent(Seg, Tcb, Ctx), Seg};
                past_window -> dropafterack(Seg1, Tcb1, Ctx)
            end
    end.

%% tcp_input.c:2259-2312. With a SYN before rcv_nxt the SYN goes, and the urgent pointer
%% moves with it. A segment that holds nothing new (all of it before rcv_nxt, or exactly up
%% to it without a FIN) loses a duplicate FIN and asks for an ACK now; so does dropping any
%% data on a SACK connection, whose D-SACK block (erx_tcp_sack:arrived/4) the next ACK must
%% carry.
trim_front(#seg{seq = Seq, flags = Flags0, urp = Urp0, data = Data} = Seg,
           #tcb{rcv_nxt = RcvNxt, sack = Sack} = Tcb) when RcvNxt > Seq ->
    {Seq1, Flags1, Urp1, Todrop1} =
        case has(Flags0, ?TH_SYN) of
            false -> {Seq, Flags0, Urp0, RcvNxt - Seq};
            true when Urp0 > 1 -> {Seq + 1, Flags0 band bnot ?TH_SYN, Urp0 - 1, RcvNxt - Seq - 1};
            true -> {Seq + 1, Flags0 band bnot (?TH_SYN bor ?TH_URG), Urp0, RcvNxt - Seq - 1}
        end,
    Tlen = byte_size(Data),
    Duplicate = Todrop1 > Tlen orelse (Todrop1 =:= Tlen andalso not has(Flags1, ?TH_FIN)),
    {Todrop, Flags2} = case Duplicate of
                           true -> {Tlen, Flags1 band bnot ?TH_FIN};
                           false -> {Todrop1, Flags1}
                       end,
    {Urp, Flags} = case Urp1 > Todrop of
                       true -> {Urp1 - Todrop, Flags2};
                       false -> {0, Flags2 band bnot ?TH_URG}
                   end,
    AckNow = Tcb#tcb.ack_now orelse Duplicate orelse (Todrop > 0 andalso Sack =:= on),
    {Seg#seg{seq = Seq1 + Todrop, flags = Flags, urp = Urp,
             data = binary:part(Data, Todrop, Tlen - Todrop)},
     Tcb#tcb{ack_now = AckNow}};
trim_front(Seg, Tcb) ->
    {Seg, Tcb}.

%% tcp_input.c:2335-2357: the part past rcv_nxt + rcv_wnd.
trim_back(#seg{seq = Seq, data = Data, flags = Flags} = Seg,
          #tcb{rcv_nxt = RcvNxt, rcv_wnd = RcvWnd} = Tcb) ->
    Tlen = byte_size(Data),
    Todrop = Seq + Tlen - (RcvNxt + RcvWnd),
    Cut = Flags band bnot (?TH_PUSH bor ?TH_FIN),
    if
        Todrop =< 0 ->
            {ok, Seg, Tcb};
        Todrop < Tlen ->
            {ok, Seg#seg{data = binary:part(Data, 0, Tlen - Todrop), flags = Cut}, Tcb};
        RcvWnd =:= 0, Seq =:= RcvNxt ->
            {ok, Seg#seg{data = <<>>, flags = Cut}, Tcb#tcb{ack_now = true}};
        true ->
            past_window
    end.

%% tcp_input.c:2385-2389: the boundary check Last.ACK.Sent <= SEG.SEQ + SEG.LEN, counting a
%% SYN or FIN once, rather than RFC 1323's strict one.
ts_recent(#seg{ts = {Val, _}, seq = Seq, data = Data, flags = Flags},
          #tcb{ts = #ts{} = Ts, last_ack_sent = LastAck} = Tcb, #tcp_ctx{now = Now}) ->
    Control = case Flags band (?TH_SYN bor ?TH_FIN) of
                  0 -> 0;
                  _ -> 1
              end,
    case Seq =< LastAck andalso LastAck =< Seq + byte_size(Data) + Control of
        true -> Tcb#tcb{ts = Ts#ts{recent = erx_tcp_seq:wire(Val), recent_age = Now}};
        false -> Tcb
    end;
ts_recent(_, Tcb, _) ->
    Tcb.

%% ---------------------------------------------------------------------------------------
%% 8. check_ack (tcp_input.c:2397-2450). Without ACK, SYN-RECEIVED keeps the data for later
%% (step6) and any other state drops the segment, acknowledging it if an ACK was asked for.
%% With ACK, RFC 5961 section 5: an acknowledgement below the acceptable floor draws a
%% challenge ACK and is dropped (tcp_insecure_ack is FreeBSD's default of 0).
check_ack(#seg{flags = Flags} = Seg, #tcb{state = State, ack_now = AckNow} = Tcb, Ctx) ->
    LowestAck = ack_floor(Tcb),
    case has(Flags, ?TH_ACK) of
        false when State =:= syn_received -> {goto, step6, ecn(Seg, Tcb, Ctx), Seg, []};
        false when AckNow -> dropafterack(Seg, Tcb, Ctx);
        false -> {done, Tcb, []};
        true when Seg#seg.ack < LowestAck -> challenge_ack(ack, Tcb, Ctx);
        true -> {continue, ecn(Seg, Tcb, Ctx), Seg}
    end.

%% tcp_ecn_input_segment and its CC_ECN (tcp_input.c:1592-1595) for an accepted segment: the
%% peer's ECE signals congestion, its CWR asks for an ACK now, and CE owes the peer ECE.
ecn(#seg{flags = Flags, ip_ecn = IpEcn, ack = Ack}, #tcb{ecn = Ecn0, ack_now = AckNow0} = Tcb0,
    Ctx) ->
    {Echo, AckNow, Ecn} = erx_tcp_ecn:input_segment(Flags, IpEcn, Ecn0),
    Tcb = Tcb0#tcb{ecn = Ecn, ack_now = AckNow0 orelse AckNow},
    case Echo of
        true -> erx_tcp:cong_signal(Tcb, ecn, Ack, Ctx);
        false -> Tcb
    end.

%% The lowest acceptable acknowledgement (design: "Packets become checked records once").
%% Until snd_una is a maximal window past the ISS, an ACK of the ISS or below acknowledges
%% nothing ever sent (the ghost-ACK check), unless the too-old bound is higher; after it,
%% FreeBSD's TF2_NO_ISS_CHECK, only the too-old bound of RFC 5961 section 5.2 counts.
ack_floor(#tcb{snd_una = Una, max_sndwnd = MaxSndWnd, iss = Iss} = Tcb) ->
    case Una >= Iss + (?TCP_MAXWIN bsl snd_scale(Tcb)) of
        true -> Una - MaxSndWnd;
        false -> max(Iss + 1, Una - MaxSndWnd)
    end.

%% ---------------------------------------------------------------------------------------
%% The exits.

%% A challenge ACK (erx_tcp:challenge_ack/3), then drop.
challenge_ack(Cause, Tcb0, Ctx) ->
    {Tcb, Actions} = erx_tcp:challenge_ack(Cause, Tcb0, Ctx),
    {done, Tcb, Actions}.

%% dropafterack (tcp_input.c:3384-3395): in SYN-RECEIVED an ACK outside snd_una..snd_max is
%% answered with a RST; otherwise an ACK goes out with this step's output.
dropafterack(#seg{flags = Flags, ack = Ack} = Seg,
             #tcb{state = syn_received, snd_una = Una, snd_max = SndMax} = Tcb, Ctx)
  when Flags band ?TH_ACK =/= 0, Una > Ack; Flags band ?TH_ACK =/= 0, Ack > SndMax ->
    dropwithreset(Seg, Tcb, Ctx);
dropafterack(_, Tcb, _) ->
    {done, Tcb#tcb{ack_now = true}, []}.

%% tcp_dropwithreset (tcp_input.c:3437): never a RST for a RST; for an ACK, a RST at the
%% acknowledged number; otherwise a RST acknowledging everything the segment occupied. The
%% header's own flags decide, with the segment's number and length as the stages left them.
%% The interface sends it within its RST rate limit and never to a broadcast or multicast
%% address.
dropwithreset(#seg{hdr_flags = Flags, ack = Ack, seq = Seq, data = Data}, Tcb, Ctx) ->
    if
        Flags band ?TH_RST =/= 0 ->
            {done, Tcb, []};
        Flags band ?TH_ACK =/= 0 ->
            {done, Tcb, [{reset, erx_tcp:respond(Tcb, Ctx, Ack, 0, ?TH_RST)}]};
        true ->
            Len = byte_size(Data) + syn_len(Flags) + fin_len(Flags),
            {done, Tcb, [{reset, erx_tcp:respond(Tcb, Ctx, 0, Seq + Len, ?TH_RST bor ?TH_ACK)}]}
    end.

%% ---------------------------------------------------------------------------------------

has(Flags, Flag) -> Flags band Flag =/= 0.

syn_len(Flags) -> (Flags band ?TH_SYN) div ?TH_SYN.

fin_len(Flags) -> Flags band ?TH_FIN.

snd_scale(#tcb{wscale = {Snd, _}}) -> Snd;
snd_scale(_) -> 0.

rcv_scale(#tcb{wscale = {_, Rcv}}) -> Rcv;
rcv_scale(_) -> 0.

ms(Millis) -> Millis * 1000.
