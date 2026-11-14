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
(the window update and the urgent pointer), `data` and `fin`.

`header_prediction` is FreeBSD's fast path: for its two common cases, a pure ACK of new data
and pure in-order data, it decides that the checks from `syn_sent` to `check_ack` would pass
the segment, applies what they would set, and finishes the case itself (pure_ack/3 and
in_order/3), doing what the stages from `ack` on do for it, with fewer copies of the control
block and without the stages that have nothing to do. FreeBSD's fast path does less than its
general stages, which leaves different state behind (`snd_wl1` and `rcv_up` after a pure
ACK, `t_dupacks`, the spurious-timeout rule); the finished cases do what the general stages
do instead (docs/design-network-fastpath.md, "Header prediction finishes its cases"). So
each effect of the two cases has two implementations and one meaning: a property test
requires the general stages' control block and actions for every segment the fast path
takes, and the explorer checks the same in every state it reaches.

A stage ends the connection with erx_tcp_user:drop/2 (`tcp_drop`) or close/1 (`tcp_close`).
The segments of one event are processed in order. Once one ends the connection, the rest
are for a connection that no longer exists, so each goes back to the interface in a
`reinject` action to be demultiplexed again, as FreeBSD looks each segment up anew.
A segment that reaches the connection in TIME-WAIT takes none of the stages: it is
erx_tcp_timewait's (`tcp_twcheck`), and TIME-WAIT begins in erx_tcp_timewait:start/2.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_tcp_loss.hrl").

-export([segments/3, stages/0, run/4, tcp_mss/3]).

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

-doc "Runs each segment through the stages, in order (see the module documentation).".
-spec segments([erx_tcp:segment()], #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
segments(Segments, Tcb, Ctx) ->
    segments(Segments, Tcb, Ctx, stages(), []).

%% `Actions` holds each segment's actions, newest segment first, joined once at the end, so
%% a batch of many segments costs no more per segment than one.
segments([], Tcb, _, _, Actions) ->
    {Tcb, lists:append(lists:reverse(Actions))};
segments(Rest, #tcb{ended = true} = Tcb, _, _, Actions) ->
    segments([], Tcb, none, none, [[{reinject, Segment} || Segment <- Rest] | Actions]);
segments([Segment | Rest], #tcb{state = time_wait} = Tcb0, Ctx, Stages, Actions) ->
    {Tcb, More} = erx_tcp_timewait:check(Segment, Tcb0, Ctx),
    segments(Rest, Tcb, Ctx, Stages, [More | Actions]);
segments([Segment | Rest], Tcb0, Ctx, Stages, Actions) ->
    {Tcb, More} = run(Stages, Segment, Tcb0, Ctx),
    segments(Rest, Tcb, Ctx, Stages, [More | Actions]).

-doc """
Runs one segment through the given stages, a suffix of `stages/0` (the segment as the first
of them takes it), as `segments/3` runs each segment through all of them. The property test
of header prediction runs the stages after it with this.
""".
-spec run([stage()], erx_tcp:segment() | #seg{}, #tcb{}, #tcp_ctx{}) ->
    {#tcb{}, [erx_tcp:action()]}.
run(Stages, Segment, Tcb, Ctx) ->
    pipeline(Stages, Segment, Tcb, Ctx, []).

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
    [{lift, fun lift/3}, {timestamps, fun timestamps/3},
     {header_prediction, fun header_prediction/3}, {syn_sent, fun syn_sent/3},
     {check_rst, fun check_rst/3}, {check_syn, fun check_syn/3}, {paws, fun paws/3},
     {trim, fun trim/3}, {check_ack, fun check_ack/3}, {ack, fun ack/3},
     {process_ack, fun process_ack/3}, {step6, fun step6/3}, {data, fun data/3},
     {fin, fun fin/3}].

%% ---------------------------------------------------------------------------------------
%% 1. lift (tcp_input.c:1511-1690): the segment into the connection's sequence space; a
%% SYN-ACK in SYN-SENT that acknowledges something we never sent answered with a RST
%% (:1556-1561); the window scaled (:1584); the timestamp echo back on our clock
%% (:1624-1629). FreeBSD refreshes t_rcvtime and reads the segment's ECN here (:1566,
%% :1592-1595), before any check; the stack does both in `accepted/3`, once the segment has
%% passed them all, so a blind segment can neither keep a dead peer's connection from its
%% keepalive timeout (FreeBSD's own XXX at :1566), nor cut the congestion window with ECE,
%% nor make us echo CE or stop echoing it.
%%
%% FreeBSD also takes a SYN's options here in SYN-SENT (:1636-1690), before it knows whether
%% the segment is acceptable; the `syn_sent` stage takes them once it has accepted the SYN,
%% so a RST or SYN that SYN-SENT drops cannot change what the connection asks for.
%%
%% A control block that has not connected has no four-tuple to receive on, so the pipeline
%% takes none of its segments. TIME-WAIT's are tcp_twcheck's: `segments/3` hands them to
%% erx_tcp_timewait, and the pipeline refuses any that reach it another way.
lift(_, #tcb{state = State} = Tcb, _) when State =:= closed; State =:= time_wait ->
    {done, Tcb, []};
lift({#tcp{seq = Seq0, ack = Ack0, flags = Flags, win = Win, urp = Urp, opts = Opts},
      Wire, IpEcn, LinkCast}, Tcb0, Ctx)
  when is_integer(IpEcn), IpEcn >= 0, IpEcn =< 3,
       LinkCast =:= unicast orelse LinkCast =:= broadcast orelse LinkCast =:= multicast ->
    #tcb{state = State, rcv_nxt = RcvNxt, snd_una = Una, iss = Iss, snd_max = SndMax} = Tcb0,
    %% In SYN-SENT nothing has been received to measure against: the SYN's own number is
    %% the initial receive sequence number, its wire value as the ISS is ours.
    Seq = case State of
              syn_sent -> Seq0;
              _ -> erx_tcp_seq:lift(Seq0, RcvNxt)
          end,
    Ack = erx_tcp_seq:lift(Ack0, Una),
    First = Seq + syn_len(Flags),
    {Payload, Len, NSegs} = erx_tcp_payload:from_wire(Wire),
    Seg = #seg{seq = Seq, ack = Ack, flags = Flags, hdr_flags = Flags,
               win = Win bsl snd_scale(Tcb0), urp = Urp, data = Payload, len = Len,
               nsegs = NSegs, arrived = {First, First + Len},
               ts = ts_option(Opts#tcp_opts.ts, Tcb0#tcb.ts, Ctx),
               mss = Opts#tcp_opts.mss, wscale = Opts#tcp_opts.wscale,
               sack_permitted = Opts#tcp_opts.sack_permitted,
               sacks = sack_blocks(Opts#tcp_opts.sacks, Tcb0), ip_ecn = IpEcn,
               link_cast = LinkCast},
    BadAck = State =:= syn_sent andalso has(Flags, ?TH_ACK) andalso (Ack =< Iss orelse Ack > SndMax),
    case BadAck of
        true ->
            dropwithreset(Seg, Tcb0, Ctx);
        false ->
            {continue, Tcb0, Seg}
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
%% Header prediction (tcp_input.c:1731-1950), FreeBSD's preconditions: ESTABLISHED, the
%% segment at rcv_nxt with ACK the only one of SYN, FIN, RST, URG and ACK, nothing being
%% resent (snd_nxt at snd_max), the peer's window unchanged and open, no SYN or FIN owed, an
%% empty reassembly queue and a timestamp no older than ts_recent; and TF_CLOSED clear, which
%% FreeBSD never sees in ESTABLISHED. Then a pure ACK of new data, not beyond snd_max, outside
%% recovery, without SACK blocks or a scoreboard (:1771-1775), or data that acknowledges
%% nothing new and fits the receive buffer (:1863-1864). Recovery is judged after the
%% segment's ECN, which FreeBSD reads before the fast path. A segment taken here has what
%% `syn_sent`, `trim` and `check_ack` would set (the receive window, ts_recent, ECN), and its
%% case is finished here (see the module documentation). A pure ACK also acknowledges no more
%% than the send buffer holds, which with no FIN sent is everything outstanding, so no FIN is
%% acknowledged on the fast path.
header_prediction(#seg{seq = Seq, ack = Ack, flags = Flags, win = Win, len = Len,
                       ts = SegTs, sacks = Sacks} = Seg, Tcb0, Ctx) ->
    #tcb{state = State, rcv_nxt = RcvNxt, snd_una = Una, snd_nxt = SndNxt, snd_max = SndMax,
         snd_wnd = SndWnd, need_syn = NeedSyn, fin = Fin, reass = Reass, ts = Ts,
         user_closed = Closed, sendlog = Log} = Tcb0,
    Candidate = State =:= established andalso Seq =:= RcvNxt
        andalso Flags band (?TH_SYN bor ?TH_FIN bor ?TH_RST bor ?TH_URG bor ?TH_ACK) =:= ?TH_ACK
        andalso SndNxt =:= SndMax andalso Win =/= 0 andalso Win =:= SndWnd
        andalso not NeedSyn andalso Fin =:= none andalso erx_tcp_reass:is_empty(Reass)
        andalso not_older(SegTs, Ts) andalso not Closed,
    case Candidate of
        false ->
            {continue, Tcb0, Seg};
        true ->
            Tcb = accepted(Seg, ts_recent(Seg, Tcb0#tcb{rcv_wnd = rcv_wnd(Tcb0)}, Ctx), Ctx),
            #ccv{fast_recovery = Fast, cong_recovery = Cong} = Tcb#tcb.ccv,
            PureAck = Len =:= 0 andalso Ack > Una andalso Ack =< SndMax
                andalso not Fast andalso not Cong andalso Sacks =:= []
                andalso not erx_tcp_sendlog:has_holes(Log)
                andalso Ack =< erx_tcp_sendlog:snd_max(Log)
                andalso Ack - Una =< erx_tcp_sndbuf:size(Tcb0#tcb.sndbuf),
            InOrder = Len > 0 andalso Ack =:= Una andalso Len =< erx_tcp:rcv_space(Tcb0),
            if
                PureAck -> pure_ack(Seg, Tcb, Ctx);
                InOrder -> in_order(Seg, Tcb, Ctx);
                true -> {continue, Tcb0, Seg}
            end
    end.

%% The pure ACK of new data, finished: what `ack`, `process_ack` and `step6` do for it (the
%% loss module's acknowledgement, a spurious timeout undone, the RTT sample, the
%% retransmission timer, cc_ack_received, the send buffer's drop, snd_una, the end of
%% recovery, the window and rcv_up), with the acknowledgement's own fields set in one update.
%% `data` and `fin` have nothing to do for a segment without data or FIN. The loss module
%% stays the judge of every acknowledgement: what it ends (`drop`) ends here too.
pure_ack(#seg{ack = Ack, nsegs = NSegs} = Seg, Tcb0, Ctx) ->
    case sent_acknowledged(Seg, Tcb0, Ctx, []) of
        {continue, #tcb{sendlog = Log} = Tcb1, _, []} ->
            #tcb{snd_una = Una} = Tcb2 =
                rexmt_after_ack(Ack, rtt(Seg, spurious_rto(Seg, Tcb1#tcb{sendlog = ack_log(Log, Ack)},
                                                           Ctx), Ctx), Ctx),
            Acked = Ack - Una,
            #tcb{sndbuf = Buf, snd_wnd = SndWnd, snd_nxt = Nxt, ccv = Ccv} = Tcb3 =
                cc_ack(Acked, Ack, NSegs, Tcb2, Ctx),
            Tcb4 = Tcb3#tcb{sndbuf = erx_tcp_sndbuf:drop(Buf, Acked), snd_wnd = max(0, SndWnd - Acked),
                            snd_una = Ack, snd_nxt = max(Nxt, Ack)},
            Tcb5 = case Ccv#ccv.fast_recovery orelse Ccv#ccv.cong_recovery of
                       true -> end_recovery(Ack, Tcb4, Ctx);
                       false -> Tcb4#tcb{snd_recover = max(Tcb4#tcb.snd_recover, Ack)}
                   end,
            {done, window(Seg, Tcb5), []};
        Other ->
            Other
    end.

%% In-order data that acknowledges nothing new, finished: the loss module's acknowledgement
%% (`ack`), the window and rcv_up (`step6`), and `data`, which for a segment at rcv_nxt with
%% nothing queued takes the delayed ACK or the ACK now, rcv_nxt, the delivery and the SACK
%% blocks' record of what arrived, called directly. `fin` has nothing to do for a segment
%% without FIN.
in_order(Seg, Tcb0, Ctx) ->
    case sent_acknowledged(Seg, Tcb0, Ctx, []) of
        {goto, step6, Tcb1, _, []} ->
            {continue, Tcb2, _, Actions} = data(Seg, window(Seg, Tcb1), Ctx),
            {done, Tcb2, Actions};
        Other ->
            Other
    end.

%% step6 itself, for a segment with ACK and without URG, which it always passes on: the
%% window when it is newer, and rcv_up pulled along to rcv_nxt.
window(Seg, Tcb0) ->
    {continue, Tcb, _} = step6(Seg, Tcb0, none),
    Tcb.

not_older({Val, _}, #ts{recent = Recent}) -> Val >= Recent;
not_older(_, _) -> true.

%% ---------------------------------------------------------------------------------------
%% 3. syn_sent (tcp_input.c:1952-2140): the receive window, at least what was advertised
%% (:1958-1961), then the handshake states of tcp_do_segment's switch. SYN-RECEIVED answers
%% an ACK of something other than our SYN with a RST (:1969-1980). SYN-SENT ends the
%% connection on a RST that acknowledges our SYN (ECONNREFUSED), drops any other RST and
%% anything without a SYN, and otherwise takes the SYN: its options, the initial receive
%% sequence number, and either ESTABLISHED (FIN-WAIT-1 when the owner has already shut
%% down) on a SYN-ACK or SYN-RECEIVED on a simultaneous open.
syn_sent(Seg, Tcb0, Ctx) ->
    Tcb = Tcb0#tcb{rcv_wnd = rcv_wnd(Tcb0)},
    case Tcb#tcb.state of
        syn_received -> syn_received(Seg, Tcb, Ctx);
        syn_sent -> syn_sent_segment(Seg, Tcb, Ctx);
        _ -> {continue, Tcb, Seg}
    end.

%% The receive window for the segment (tcp_input.c:1958-1961): the buffer's free space, or
%% what was already advertised, if more.
rcv_wnd(#tcb{rcv_adv = RcvAdv, rcv_nxt = RcvNxt} = Tcb) ->
    max(erx_tcp:rcv_space(Tcb), RcvAdv - RcvNxt).

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

take_syn(#seg{seq = Irs, flags = Flags0, win = Win, data = Data0, len = Len0} = Seg0, Tcb0,
         Ctx) ->
    {Tcb1, Buffers} = negotiate(Seg0, Tcb0, Ctx),
    %% tcp_rcvseqinit.
    Tcb2 = Tcb1#tcb{irs = Irs, rcv_nxt = Irs + 1, rcv_adv = Irs + 1},
    {Tcb3, Flags1} = case has(Flags0, ?TH_ACK) of
                         true -> synack(Seg0, Tcb2, Ctx);
                         %% A simultaneous open (:2094-2100): the SYN-ACK goes out now, the
                         %% SYN's retransmission timer stops (its count stays), and our SYN
                         %% is owed until the peer acknowledges it (TF_NEEDSYN).
                         false -> {Tcb2#tcb{ack_now = true, send_timer = none,
                                            state = syn_received, need_syn = true}, Flags0}
                     end,
    %% The data after the SYN, trimmed to the window, which drops a FIN past it.
    Seq = Irs + 1,
    RcvWnd = Tcb3#tcb.rcv_wnd,
    {Data, Len, Flags} = case Len0 > RcvWnd of
                             true ->
                                 {erx_tcp_payload:part(Data0, 0, RcvWnd), RcvWnd,
                                  Flags1 band bnot ?TH_FIN};
                             false ->
                                 {Data0, Len0, Flags1}
                         end,
    %% An acceptable SYN passed SYN-SENT's checks: t_rcvtime (tcp_input.c:1566).
    Tcb = Tcb3#tcb{snd_wl1 = Seq - 1, rcv_up = Seq, snd_wnd = Win, rcvtime = Ctx#tcp_ctx.now},
    Seg = Seg0#seg{seq = Seq, data = Data, len = Len, flags = Flags},
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
                 {Shift, requested} when is_integer(Shift) ->
                     {Shift, erx_tcp_output:request_r_scale()};
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

-doc """
The MSS from the peer's offer and the path (`tcp_mss`), for a SYN taken here and for a
connection made from the syncache (erx_tcp_user:accepted/3); the send and receive buffers
rounded up to whole segments are asked of the grant, whose answer sets them (`{buffer, Kind,
Bytes}`).
""".
-spec tcp_mss(erx_tcp_mss:offer(), #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
tcp_mss(Offer, #tcb{family = Family, snd_hiwat = Snd0, rcv_hiwat = Rcv0} = Tcb,
        #tcp_ctx{mtu = Mtu}) ->
    {Maxseg, Snd, Rcv} = erx_tcp_mss:mss(Family, Offer, {Mtu, 0}, {Snd0, Rcv0}, ?SB_MAX),
    {Tcb#tcb{maxseg = Maxseg},
     [{reserve_buffer, snd, Snd} || Snd =/= Snd0] ++ [{reserve_buffer, rcv, Rcv} || Rcv =/= Rcv0]}.

%% A SYN-ACK accepted in SYN-SENT (tcp_input.c:2047-2104): our SYN is acknowledged, the
%% advertised edge moves by the window, data on it waits for a delayed ACK and anything else
%% is acknowledged at once, ECN follows the SYN-ACK, and the connection is established, or
%% in FIN-WAIT-1 owing its FIN when the owner shut down first, the SYN then taken out of
%% the flags. An established connection initialises its congestion window and starts the
%% keepalive's idle time.
synack(#seg{flags = Flags, len = Len}, Tcb0, #tcp_ctx{now = Now} = Ctx) ->
    #tcb{rcv_adv = RcvAdv, rcv_wnd = RcvWnd, snd_una = Una0, snd_nxt = SndNxt,
         deadlines = D} = Tcb0,
    Una = Una0 + 1,
    Tcb1 = Tcb0#tcb{rcv_adv = RcvAdv + min(RcvWnd, ?TCP_MAXWIN bsl rcv_scale(Tcb0)),
                    snd_una = Una, snd_nxt = max(SndNxt, Una),
                    ecn = erx_tcp_ecn:input_syn_sent(Flags, Tcb0#tcb.ecn)},
    Tcb2 = case Len > 0 andalso delay_ack(Tcb1, Len) of
               true -> Tcb1#tcb{deadlines = D#deadlines{delack = Now + ms(?TCPTV_DELACK)}};
               false -> Tcb1#tcb{ack_now = true}
           end,
    case Tcb2#tcb.fin of
        queued -> {Tcb2#tcb{state = fin_wait_1}, Flags band bnot ?TH_SYN};
        _ -> {establish(Tcb2, Ctx), Flags}
    end.

%% ESTABLISHED, from SYN-SENT or SYN-RECEIVED: the congestion window's start and the
%% keepalive's idle time.
establish(Tcb0, #tcp_ctx{now = Now} = Ctx) ->
    Tcb = cc_conn_init(Tcb0#tcb{state = established}, Ctx),
    Tcb#tcb{deadlines = (Tcb#tcb.deadlines)#deadlines{keep = Now + ms(Tcb#tcb.keep_idle)}}.

%% DELAY_ACK (tcp_input.c:511): no delayed ACK pending, our last window not zero
%% (TF_RXWIN0SENT, so the ACK that reopens it is not delayed), a segment no larger than
%% t_maxseg, and tcp_delack_enabled, FreeBSD's default of 1.
delay_ack(#tcb{deadlines = #deadlines{delack = Delack}, maxseg = Maxseg, rxwin0_sent = Win0},
          Tlen) ->
    Delack =:= infinity andalso not Win0 andalso Tlen =< Maxseg.

%% DELAY_ACK's two outcomes: TF_DELACK, whose timer check_delack starts, or TF_ACKNOW.
delay_or_ack(Tcb, Tlen, Ctx) ->
    case delay_ack(Tcb, Tlen) of
        true -> delack(Tcb, Ctx);
        false -> Tcb#tcb{ack_now = true}
    end.

delack(#tcb{deadlines = D} = Tcb, #tcp_ctx{now = Now}) ->
    Tcb#tcb{deadlines = D#deadlines{delack = Now + ms(?TCPTV_DELACK)}}.

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
%%
%% FreeBSD lets every SYN through in SYN-RECEIVED, where the peer's SYN may come again; trim
%% strips it, since it lies before rcv_nxt. A SYN at or past rcv_nxt names another initial
%% sequence number. Kept, as FreeBSD keeps it, its data would be taken one byte early,
%% since the byte at its sequence number is the SYN. RFC 9293 section 3.10.7.4 treats
%% SYN-RECEIVED after an active open as a synchronized state, so such a SYN is challenged.
%% A passive open's SYN-RECEIVED (erx_tcp_user:accepted/3) is challenged alike; it lasts only
%% for the step of the ACK that completed the handshake, whose acknowledgement, sequence
%% number and timestamp the syncache has already checked, so that step leaves it.
check_syn(#seg{flags = Flags, seq = Seq} = Seg, #tcb{state = State, rcv_nxt = RcvNxt} = Tcb,
          Ctx) ->
    Challenged = case State of
                     syn_sent -> false;
                     syn_received -> Seq >= RcvNxt;
                     _ -> true
                 end,
    case has(Flags, ?TH_SYN) andalso Challenged of
        true -> challenge_ack(syn, Tcb, Ctx);
        false -> {continue, Tcb, Seg}
    end.

%% ---------------------------------------------------------------------------------------
%% 6. paws (tcp_input.c:2218-2245): RFC 7323 PAWS. A TSval older than a valid ts_recent
%% drops the segment, acknowledging it if it carries data; once ts_recent is more than 24
%% days old it is invalidated instead, and the segment goes on.
paws(#seg{ts = {Val, _}, len = Len} = Seg,
     #tcb{ts = #ts{recent = Recent, recent_age = Age} = Ts} = Tcb, #tcp_ctx{now = Now} = Ctx)
  when Recent =/= 0, Val < Recent ->
    case Now - Age > ms(?TCP_PAWS_IDLE) of
        true -> {continue, Tcb#tcb{ts = Ts#ts{recent = 0}}, Seg};
        false when Len > 0 -> dropafterack(Seg, Tcb, Ctx);
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
    case Closed andalso Seg1#seg.len > 0 andalso not erx_tcp:have_rcvd_fin(State) of
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
trim_front(#seg{seq = Seq, flags = Flags0, urp = Urp0, data = Data, len = Tlen} = Seg,
           #tcb{rcv_nxt = RcvNxt, sack = Sack} = Tcb) when RcvNxt > Seq ->
    {Seq1, Flags1, Urp1, Todrop1} =
        case has(Flags0, ?TH_SYN) of
            false -> {Seq, Flags0, Urp0, RcvNxt - Seq};
            true when Urp0 > 1 -> {Seq + 1, Flags0 band bnot ?TH_SYN, Urp0 - 1, RcvNxt - Seq - 1};
            true -> {Seq + 1, Flags0 band bnot (?TH_SYN bor ?TH_URG), Urp0, RcvNxt - Seq - 1}
        end,
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
             data = erx_tcp_payload:part(Data, Todrop, Tlen - Todrop), len = Tlen - Todrop},
     Tcb#tcb{ack_now = AckNow}};
trim_front(Seg, Tcb) ->
    {Seg, Tcb}.

%% tcp_input.c:2335-2357: the part past rcv_nxt + rcv_wnd.
trim_back(#seg{seq = Seq, data = Data, len = Tlen, flags = Flags} = Seg,
          #tcb{rcv_nxt = RcvNxt, rcv_wnd = RcvWnd} = Tcb) ->
    Todrop = Seq + Tlen - (RcvNxt + RcvWnd),
    Cut = Flags band bnot (?TH_PUSH bor ?TH_FIN),
    if
        Todrop =< 0 ->
            {ok, Seg, Tcb};
        Todrop < Tlen ->
            {ok, Seg#seg{data = erx_tcp_payload:part(Data, 0, Tlen - Todrop), len = Tlen - Todrop,
                         flags = Cut}, Tcb};
        RcvWnd =:= 0, Seq =:= RcvNxt ->
            {ok, Seg#seg{data = [], len = 0, flags = Cut}, Tcb#tcb{ack_now = true}};
        true ->
            past_window
    end.

%% tcp_input.c:2385-2389: the boundary check Last.ACK.Sent <= SEG.SEQ + SEG.LEN, counting a
%% SYN or FIN once, rather than RFC 1323's strict one.
ts_recent(#seg{ts = {Val, _}, seq = Seq, len = Len, flags = Flags},
          #tcb{ts = #ts{} = Ts, last_ack_sent = LastAck} = Tcb, #tcp_ctx{now = Now}) ->
    Control = case Flags band (?TH_SYN bor ?TH_FIN) of
                  0 -> 0;
                  _ -> 1
              end,
    case Seq =< LastAck andalso LastAck =< Seq + Len + Control of
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
        false when State =:= syn_received -> {goto, step6, accepted(Seg, Tcb, Ctx), Seg, []};
        false when AckNow -> dropafterack(Seg, Tcb, Ctx);
        false -> {done, Tcb, []};
        true when Seg#seg.ack < LowestAck -> challenge_ack(ack, Tcb, Ctx);
        %% An acknowledgement of what was never sent is dropped by the `ack` stage
        %% (tcp_input.c:2546); it is not accepted, so it refreshes neither t_rcvtime nor
        %% ECN, and a blind sender must hit both windows to keep a connection alive.
        true when Seg#seg.ack > Tcb#tcb.snd_max -> {continue, Tcb, Seg};
        true -> {continue, accepted(Seg, Tcb, Ctx), Seg}
    end.

%% What a segment that passed every check changes before the ACK and data stages: t_rcvtime
%% (tcp_input.c:1566), and tcp_ecn_input_segment with its CC_ECN (:1592-1595): the peer's ECE
%% signals congestion, its CWR asks for an ACK now unless the handshake is not over or
%% the peer has sent its FIN, and CE owes the peer ECE.
accepted(#seg{flags = Flags, ip_ecn = IpEcn, ack = Ack},
         #tcb{state = TcpState, ecn = Ecn0, ack_now = AckNow0} = Tcb0,
         #tcp_ctx{now = Now} = Ctx) ->
    {Echo, AckNow, Ecn} = erx_tcp_ecn:input_segment(Flags, IpEcn, TcpState, Ecn0),
    Tcb = Tcb0#tcb{ecn = Ecn, ack_now = AckNow0 orelse AckNow, rcvtime = Now},
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
%% 9. ack (tcp_input.c:2452-2886). SYN-RECEIVED is left first. Then, in every synchronized
%% state, an acknowledgement of something never sent is dropped with an ACK (:2546-2548),
%% and the loss module takes the duplicate-acknowledgement block (erx_tcp_loss), whose events
%% the connection applies before asking it for the next output's window. Its `drop` is
%% FreeBSD's `goto drop`: the segment ends there, with snd_una and the send buffer where the
%% log put them. An acknowledgement of nothing new goes on at step6, FreeBSD's `break` out of
%% the switch; one of new data goes on to process_ack.
ack(Seg, #tcb{state = syn_received} = Tcb0, Ctx) ->
    {Tcb, Actions} = leave_syn_received(Seg, Tcb0, Ctx),
    acknowledgement(Seg, Tcb, Ctx, Actions);
ack(Seg, Tcb, Ctx) ->
    acknowledgement(Seg, Tcb, Ctx, []).

%% SYN-RECEIVED (:2458-2527): the peer's window, then ESTABLISHED, or FIN-WAIT-1 when the
%% owner has already shut down (TF_NEEDFIN, whose FIN output then sends). The acknowledgement
%% covers our SYN, which `syn_sent` checked, so snd_una moves past it here: the SYN takes a
%% sequence number but is not data, and process_ack counts only what lies beyond it. FreeBSD
%% does the same in two places, `incforsyn` (:2514-2515, :2897-2898) for a SYN-RECEIVED made by
%% a listener (erx_tcp_user:accepted/3, which leaves snd_una at the ISS) and the
%% TF_NEEDSYN block of :2869-2883 for a simultaneous open; both leave snd_una one past the
%% SYN before the bytes acknowledged are counted, and the window shifts were fixed when the
%% SYN was taken. Data queued before ESTABLISHED is handed over now unless this segment
%% brings more, which `data` then handles.
leave_syn_received(#seg{seq = Seq, win = Win, len = Len, flags = Flags},
                   #tcb{snd_una = Una} = Tcb0, Ctx) ->
    Tcb1 = Tcb0#tcb{snd_wnd = Win, snd_una = Una + 1, need_syn = false, snd_wl1 = Seq - 1},
    Tcb2 = case Tcb1#tcb.fin of
               queued -> Tcb1#tcb{state = fin_wait_1};
               _ -> establish(Tcb1, Ctx)
           end,
    case Len =:= 0 andalso not has(Flags, ?TH_FIN) of
        true ->
            {Tcb, _Fin, Actions} = reassembled(erx_tcp_reass:present(Tcb2#tcb.reass,
                                                                     Tcb2#tcb.rcv_nxt), Tcb2),
            %% FreeBSD discards tcp_reass's answer here (:2521), so a FIN queued behind the
            %% data waits for the peer to send it again.
            {Tcb, Actions};
        false ->
            {Tcb2, []}
    end.

%% The bound is the send log's snd_max, the one the loss module and the log check against.
acknowledgement(#seg{ack = Ack} = Seg, #tcb{sendlog = Log} = Tcb, Ctx, Actions) ->
    case Ack > erx_tcp_sendlog:snd_max(Log) of
        true ->
            {done, Tcb1, More} = dropafterack(Seg, Tcb, Ctx),
            {done, Tcb1, Actions ++ More};
        false ->
            sent_acknowledged(Seg, Tcb, Ctx, Actions)
    end.

sent_acknowledged(#seg{ack = Ack, flags = Flags, arrived = {First, End}, win = Win,
                       sacks = Sacks} = Seg,
                  Tcb0, #tcp_ctx{now = Now} = Ctx, Actions) ->
    #tcb{snd_nxt = SndNxt, snd_recover = Recover, snd_wnd = SndWnd, state = State,
         send_timer = Timer, loss = Loss, loss_state = LossState0, sendlog = Log0} = Tcb0,
    LossAck = #loss_ack{ack = Ack, snd_nxt = SndNxt, recover = Recover,
                        sack_opt = Sacks =/= [], sack_blocks = Sacks,
                        %% no_data is the length as the segment arrived (:1530), so a
                        %% duplicate whose data trim removed is no duplicate ACK.
                        pure = First =:= End andalso Win =:= SndWnd,
                        new_fin = has(Flags, ?TH_FIN) andalso not erx_tcp:have_rcvd_fin(State),
                        rexmt_armed = is_tuple(Timer) andalso element(1, Timer) =:= rexmt,
                        ccv = erx_tcp:ccv(Tcb0, Ctx)},
    %% Whether the acknowledgement is new is measured against the log, which still holds our
    %% SYN when SYN-RECEIVED is being left: #tcb.snd_una has already moved past it.
    LogUna0 = erx_tcp_sendlog:snd_una(Log0),
    {Verdict, Log, LossState, Events} = Loss:ack(LossAck, Log0, LossState0, Now),
    Tcb1 = erx_tcp:loss_events(Events, Tcb0#tcb{sendlog = Log, loss_state = LossState}, Ack, Ctx),
    Tcb = Tcb1#tcb{allowance = Loss:allowance(Log, LossState, erx_tcp:ccv(Tcb1, Ctx))},
    if
        Verdict =:= drop -> {done, follow_log(erx_tcp_sendlog:snd_una(Log), Tcb), Actions};
        Ack =< LogUna0 -> {goto, step6, Tcb, Seg, Actions};
        true -> {continue, Tcb, Seg, Actions}
    end.

%% After the loss module's `drop`, snd_una follows what the log acknowledged.
follow_log(LogUna, #tcb{snd_una = Una} = Tcb) when LogUna > Una ->
    {Followed, _FinAcked} = take_ack(LogUna, Tcb),
    Followed;
follow_log(_, Tcb) ->
    Tcb.

%% ---------------------------------------------------------------------------------------
%% 10. process_ack (tcp_input.c:2887-3079), FreeBSD's process_ACK label, which a SYN-ACK
%% accepted in SYN-SENT jumps to with snd_una already past our SYN. The acknowledgement goes
%% into the send log (the loss module has already put it there unless the segment jumped
%% here). In FreeBSD's order: a spurious first timeout is undone; an RTT sample is taken;
%% the retransmission timer stops once everything sent is acknowledged and restarts
%% otherwise, unless persist runs; with no data acknowledged (only our SYN) the rest is
%% skipped. Then the congestion module's ack_received, the acknowledged bytes leave the send
%% buffer and the window, snd_una advances, recovery ends at snd_recover, and an
%% acknowledged FIN moves FIN-WAIT-1 to FIN-WAIT-2, CLOSING to TIME-WAIT, and ends LAST-ACK.
%% FreeBSD's `snd_recover = th_ack - 1` for a snd_una that wrapped past it (:3013-3016)
%% cannot apply to unwrapped numbers.
process_ack(#seg{ack = Ack, nsegs = NSegs} = Seg, #tcb{snd_una = Una, sendlog = Log} = Tcb0,
            Ctx) ->
    Tcb1 = Tcb0#tcb{sendlog = ack_log(Log, Ack)},
    Tcb2 = rexmt_after_ack(Ack, rtt(Seg, spurious_rto(Seg, Tcb1, Ctx), Ctx), Ctx),
    case Ack - Una of
        Acked when Acked > 0 ->
            {Tcb3, FinAcked} = take_ack(Ack, cc_ack(Acked, Ack, NSegs, Tcb2, Ctx)),
            fin_acked(FinAcked, Seg, end_recovery(Ack, Tcb3, Ctx), Ctx);
        _ ->
            {goto, step6, Tcb2, Seg, []}
    end.

ack_log(Log, Ack) ->
    case Ack > erx_tcp_sendlog:snd_una(Log) andalso Ack =< erx_tcp_sendlog:snd_max(Log) of
        true -> element(1, erx_tcp_sendlog:ack(Log, Ack, []));
        false -> Log
    end.

%% CC_RTO_ERR (:2911-2919): the first retransmission was needless when the acknowledgement
%% echoes a timestamp from before it (badrxtwin, which output records), so the window and
%% recovery state the timeout saved come back.
spurious_rto(#seg{ts = {_, Ecr}, ack = Ack},
             #tcb{rxtshift = 1, rexmt_prev = #rexmt_prev{badrxtwin = Win}} = Tcb, Ctx)
  when is_integer(Ecr), is_integer(Win), Ecr < Win ->
    erx_tcp:cong_signal(Tcb, rto_err, Ack, Ctx);
spurious_rto(_, Tcb, _) ->
    Tcb.

%% The RTT sample (:2934-2946): from the echoed timestamp, which lift brought onto our clock,
%% plus one tick, as TCP_TS_TO_TICKS(t) + 1 is with 1 ms ticks; otherwise from the timed
%% segment once the acknowledgement passes its first byte.
rtt(#seg{ts = {_, Ecr}}, Tcb, #tcp_ctx{now = Now}) when is_integer(Ecr) ->
    xmit_timer(Now div 1000 - Ecr + 1, Tcb);
rtt(#seg{ack = Ack}, #tcb{rtt_probe = {Seq, SentAt}} = Tcb, #tcp_ctx{now = Now}) when Ack > Seq ->
    xmit_timer((Now - SentAt) div 1000, Tcb);
rtt(_, Tcb, _) ->
    Tcb.

%% tcp_xmit_timer (:3639-3708): the estimator takes the sample against the backoff before
%% it, and then the backoff count restarts (Karn), the timed segment is done, and the last
%% soft error is forgotten. This is the one place an RTT sample resets rxtshift.
xmit_timer(Ticks, #tcb{rtt = Rtt, rxtshift = Shift, ccv = #ccv{rtt_updated = N} = Ccv} = Tcb) ->
    Tcb#tcb{rtt = erx_tcp_rtt:sample(Rtt, max(0, Ticks), Shift), rxtshift = 0,
            rtt_probe = none, soft_error = none, ccv = Ccv#ccv{rtt_updated = min(N + 1, 255)}}.

%% :2964-2971: everything sent acknowledged stops the retransmission timer; otherwise it
%% restarts at the current, possibly backed-off, timeout unless persist holds it.
rexmt_after_ack(Ack, #tcb{snd_max = Ack, send_timer = {rexmt, _}} = Tcb, _) ->
    Tcb#tcb{send_timer = none};
rexmt_after_ack(Ack, #tcb{snd_max = Ack} = Tcb, _) ->
    Tcb;
rexmt_after_ack(_, #tcb{send_timer = {persist, _}} = Tcb, _) ->
    Tcb;
rexmt_after_ack(_, #tcb{rtt = Rtt} = Tcb, #tcp_ctx{now = Now}) ->
    Tcb#tcb{send_timer = {rexmt, Now + ms(erx_tcp_rtt:rto(Rtt))}}.

%% cc_ack_received with CC_ACK (:290-339): appropriate byte counting above ssthresh marks a
%% window's worth acknowledged (CCF_ABC_SENTAWND), then the congestion module's ack_received.
cc_ack(Bytes, Ack, NSegs, #tcb{cc = Cc, bytes_acked = Counted0} = Tcb, Ctx) ->
    #ccv{cwnd = Cwnd, ssthresh = Ssthresh, snd_wnd = SndWnd} = Ccv0 = erx_tcp:ccv(Tcb, Ctx),
    {Counted, Ccv} = if
                         Cwnd > Ssthresh, Counted0 + Bytes >= Cwnd ->
                             {Counted0 + Bytes - Cwnd, Ccv0#ccv{abc_sentawnd = true}};
                         Cwnd > Ssthresh ->
                             {Counted0 + Bytes, Ccv0};
                         true ->
                             {0, Ccv0#ccv{abc_sentawnd = false}}
                     end,
    CcAck = #cc_ack{bytes = Bytes, nsegs = NSegs, cwnd_limited = Cwnd =< SndWnd, curack = Ack},
    Tcb#tcb{bytes_acked = Counted, ccv = Cc:ack_received(Ccv, ack, CcAck)}.

%% :2990-3022: snd_una moves to Ack. The acknowledged data leaves the send buffer and the
%% peer's window, whose right edge stays where it was; an acknowledgement past the buffered
%% data also covers our FIN, the one byte after them (`ourfinisacked`). snd_nxt is held at
%% or above snd_una.
take_ack(Ack, #tcb{snd_una = Una, sndbuf = Buf, snd_wnd = SndWnd, snd_nxt = Nxt} = Tcb) ->
    Acked = Ack - Una,
    Cut = min(Acked, erx_tcp_sndbuf:size(Buf)),
    {Tcb#tcb{sndbuf = erx_tcp_sndbuf:drop(Buf, Cut), snd_wnd = max(0, SndWnd - Cut),
             snd_una = Ack, snd_nxt = max(Nxt, Ack)},
     Acked > Cut}.

%% cc_post_recovery (:482-500) once the acknowledgement reaches snd_recover during recovery,
%% then snd_recover is held at or above snd_una.
end_recovery(Ack, #tcb{cc = Cc, snd_recover = Recover, ccv = Ccv0} = Tcb0, Ctx) ->
    Tcb = case (Ccv0#ccv.fast_recovery orelse Ccv0#ccv.cong_recovery) andalso Ack >= Recover of
              true ->
                  Ccv = Cc:post_recovery(erx_tcp:ccv(Tcb0, Ctx)),
                  Tcb0#tcb{ccv = Ccv#ccv{fast_recovery = false, cong_recovery = false},
                           bytes_acked = 0};
              false ->
                  Tcb0
          end,
    Tcb#tcb{snd_recover = max(Tcb#tcb.snd_recover, Tcb#tcb.snd_una)}.

%% :3024-3078. FIN-WAIT-2 after our FIN, with the 2MSL deadline at TP_MAXIDLE when the
%% receive side is already closed, since a peer that never sends its FIN would otherwise
%% hold the connection forever (tcp_fast_finwait2_recycle is FreeBSD's default of 0).
fin_acked(true, Seg, #tcb{state = fin_wait_1, rcv_closed = RcvClosed} = Tcb,
          #tcp_ctx{now = Now}) ->
    #tcb{deadlines = D, keep_cnt = Cnt, keep_intvl = Intvl} = Tcb,
    Msl2 = case RcvClosed of
               true -> Now + ms(Cnt * Intvl);
               false -> D#deadlines.msl2
           end,
    {continue, Tcb#tcb{state = fin_wait_2, deadlines = D#deadlines{msl2 = Msl2}}, Seg};
fin_acked(true, _, #tcb{state = closing} = Tcb, Ctx) ->
    {done, erx_tcp_timewait:start(Tcb, Ctx), []};
fin_acked(true, _, #tcb{state = last_ack} = Tcb, _) ->
    {done, erx_tcp_user:close(Tcb), []};
fin_acked(_, Seg, Tcb, _) ->
    {continue, Tcb, Seg}.

%% ---------------------------------------------------------------------------------------
%% 11. step6 (tcp_input.c:3081-3163). The send window is taken from a segment with ACK only
%% when it is newer than the last one taken (SND.WL1, SND.WL2, RFC 9293 section 3.10.7.4),
%% or equally new and wider. Then the urgent pointer.
step6(#seg{flags = Flags, seq = Seq, ack = Ack, win = Win} = Seg,
      #tcb{max_sndwnd = MaxSndWnd} = Tcb0, _) ->
    Tcb = case has(Flags, ?TH_ACK) andalso newer_window(Seg, Tcb0) of
              true -> Tcb0#tcb{snd_wnd = Win, snd_wl1 = Seq, snd_wl2 = Ack,
                               max_sndwnd = max(MaxSndWnd, Win)};
              false -> Tcb0
          end,
    urgent(Seg, Tcb).

newer_window(#seg{seq = Seq, ack = Ack, win = Win},
             #tcb{snd_wl1 = Wl1, snd_wl2 = Wl2, snd_wnd = SndWnd}) ->
    Wl1 < Seq orelse (Wl1 =:= Seq andalso (Wl2 < Ack orelse (Wl2 =:= Ack andalso Win > SndWnd))).

%% :3105-3163. Before the peer's FIN, an urgent pointer moves rcv_up forward, unless it
%% points past what any receive buffer could hold, which drops the URG; the urgent byte, when
%% this segment carries it, is kept out of the stream (tcp_pulloutofband; SO_OOBINLINE is not
%% offered, and gen_tcp, like stock, cannot read the byte). It is kept out by its sequence
%% number (#tcb.rcv_oob), whether the segment is delivered now or from the reassembly queue.
%% Without URG, rcv_up follows rcv_nxt.
urgent(#seg{flags = Flags, urp = Urp, seq = Seq, len = Len} = Seg,
       #tcb{state = State, rcv_up = RcvUp, rcv_buffered = Buffered, rcv_oob = Oob0} = Tcb)
  when Flags band ?TH_URG =/= 0, Urp =/= 0 ->
    case erx_tcp:have_rcvd_fin(State) of
        true ->
            {continue, pull_rcv_up(Tcb), Seg};
        false when Urp + Buffered > ?SB_MAX ->
            {continue, Tcb, Seg#seg{urp = 0, flags = Flags band bnot ?TH_URG}};
        false ->
            Oob = case Urp =< Len of
                      true -> Seq + Urp - 1;
                      false -> Oob0
                  end,
            {continue, Tcb#tcb{rcv_up = max(RcvUp, Seq + Urp), rcv_oob = Oob}, Seg}
    end;
urgent(Seg, Tcb) ->
    {continue, pull_rcv_up(Tcb), Seg}.

pull_rcv_up(#tcb{rcv_up = RcvUp, rcv_nxt = RcvNxt} = Tcb) -> Tcb#tcb{rcv_up = max(RcvUp, RcvNxt)}.

%% ---------------------------------------------------------------------------------------
%% 12a. data (tcp_input.c:3165-3290). Before the peer's FIN, data or a FIN is taken: at
%% rcv_nxt with nothing queued, once established, it goes to the owner with a delayed or
%% immediate ACK; anything else goes through the reassembly queue, which may complete the
%% stream up to a queued FIN, and is acknowledged at once so that the peer's fast
%% retransmit works. After the peer's FIN, data and a FIN again are dropped. Then the SACK
%% blocks: every segment that reached here, its range as it arrived, so a duplicate trimmed
%% away entirely is reported as D-SACK too (FreeBSD records that one in its trim,
%% :2296-2299, and the rest here, :3237-3268).
data(#seg{len = Len, flags = Flags} = Seg, #tcb{state = State} = Tcb0, Ctx) ->
    Takes = (Len > 0 orelse has(Flags, ?TH_FIN)) andalso not erx_tcp:have_rcvd_fin(State),
    {Tcb1, Fin, Actions} = case Takes of
                               true -> take_data(Seg, Tcb0, Ctx);
                               false -> {Tcb0, false, []}
                           end,
    Tcb = sack_arrived(Seg, Tcb0#tcb.rcv_nxt, Tcb1),
    FinFlag = case Fin of
                  true -> ?TH_FIN;
                  false -> 0
              end,
    {continue, Tcb, Seg#seg{flags = (Flags band bnot ?TH_FIN) bor FinFlag}, Actions}.

take_data(#seg{seq = Seq, data = Data, len = Tlen, flags = Flags},
          #tcb{rcv_nxt = RcvNxt, reass = Reass, state = State} = Tcb0, Ctx) ->
    Fin = has(Flags, ?TH_FIN),
    case Seq =:= RcvNxt andalso erx_tcp_reass:is_empty(Reass)
        andalso erx_tcp:have_established(State) of
        true ->
            Tcb1 = delay_or_ack(Tcb0, Tlen, Ctx),
            {Tcb, Actions} = deliver(Data, RcvNxt, Tcb1#tcb{rcv_nxt = RcvNxt + Tlen}),
            {Tcb, Fin, Actions};
        false ->
            Segment = #{seq => Seq, data => Data, fin => Fin},
            Result = erx_tcp_reass:insert(Reass, Segment, RcvNxt, reass_context(Tcb0)),
            reassembled(Result, Tcb0#tcb{ack_now = true})
    end.

reass_context(#tcb{state = State, rcv_hiwat = Hiwat, maxseg = Mss} = Tcb) ->
    #{established => erx_tcp:have_established(State), room => erx_tcp:rcv_space(Tcb),
      hiwat => max(1, Hiwat), mss => Mss}.

%% What the reassembly queue answered: the data now in order goes to the owner, and whether
%% the peer's FIN follows it.
reassembled({delivered, Data, RcvNxt, Fin, Queue}, #tcb{rcv_nxt = From} = Tcb0) ->
    {Tcb, Actions} = deliver(Data, From, Tcb0#tcb{reass = Queue, rcv_nxt = RcvNxt}),
    {Tcb, Fin, Actions};
reassembled({queued, Queue}, Tcb) ->
    {Tcb#tcb{reass = Queue}, false, []};
reassembled({dropped, _Why, Queue}, Tcb) ->
    {Tcb#tcb{reass = Queue}, false, []}.

%% sbappendstream for the bytes from sequence number From on: the urgent byte among them is
%% left out, the rest go to the owner and count against the receive buffer until it reads
%% them; after the owner shut the receive side down (SBS_CANTRCVMORE) they are discarded,
%% though rcv_nxt has passed them.
deliver(Data0, From, Tcb0) ->
    {Data, Tcb} = without_urgent(Data0, From, Tcb0),
    case {Tcb#tcb.rcv_closed, erx_tcp_payload:size(Data)} of
        {true, _} -> {Tcb, []};
        {false, 0} -> {Tcb, []};
        {false, Size} -> {Tcb#tcb{rcv_buffered = Tcb#tcb.rcv_buffered + Size}, [{deliver, Data}]}
    end.

without_urgent(Data, From, #tcb{rcv_oob = Oob} = Tcb) when is_integer(Oob), Oob >= From ->
    Offset = Oob - From,
    Size = erx_tcp_payload:size(Data),
    case Offset < Size of
        true ->
            Before = erx_tcp_payload:part(Data, 0, Offset),
            After = erx_tcp_payload:part(Data, Offset + 1, Size - Offset - 1),
            {Before ++ After, Tcb#tcb{rcv_oob = none}};
        false ->
            {Data, Tcb}
    end;
without_urgent(Data, _, Tcb) ->
    {Data, Tcb}.

%% erx_tcp_sack:arrived/4 for a segment with data on a synchronized SACK connection, against
%% rcv_nxt before the segment and the ranges held after it.
sack_arrived(#seg{arrived = {First, End}}, RcvNxtBefore,
             #tcb{sack = on, state = State, rcv_sack = Sack, reass = Reass} = Tcb)
  when End > First ->
    case erx_tcp:have_established(State) of
        true ->
            Held = maps:get(ranges, erx_tcp_reass:held(Reass)),
            Tcb#tcb{rcv_sack = erx_tcp_sack:arrived(Sack, {First, End}, RcvNxtBefore, Held)};
        false ->
            Tcb
    end;
sack_arrived(_, _, Tcb) ->
    Tcb.

%% ---------------------------------------------------------------------------------------
%% 12b. fin (tcp_input.c:3315-3369). The peer's FIN, once in order: the receive side ends,
%% which the owner learns after the data before it ({notify, eof}, socantrcvmore), and the
%% FIN takes its sequence number and is acknowledged at once; then SYN-RECEIVED and
%% ESTABLISHED go to CLOSE-WAIT, FIN-WAIT-1 to CLOSING, and FIN-WAIT-2 to TIME-WAIT. `data`
%% has already cleared a FIN after the peer's first. FreeBSD delays the ACK while
%% TF_NEEDSYN holds; no FIN gets here then, since a FIN before ESTABLISHED waits in the
%% reassembly queue and an ACK of our SYN has already cleared need_syn.
fin(#seg{flags = Flags} = Seg, #tcb{state = State, rcv_nxt = RcvNxt} = Tcb0, Ctx)
  when Flags band ?TH_FIN =/= 0 ->
    Tcb = Tcb0#tcb{rcv_closed = true, rcv_nxt = RcvNxt + 1, ack_now = true},
    Eof = [{notify, eof}],
    case State of
        syn_received -> {continue, Tcb#tcb{state = close_wait}, Seg, Eof};
        established -> {continue, Tcb#tcb{state = close_wait}, Seg, Eof};
        fin_wait_1 -> {continue, Tcb#tcb{state = closing}, Seg, Eof};
        fin_wait_2 -> {done, erx_tcp_timewait:start(Tcb, Ctx), Eof};
        _ -> {continue, Tcb, Seg, Eof}
    end;
fin(Seg, Tcb, _) ->
    {continue, Tcb, Seg}.

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

%% tcp_dropwithreset (tcp_input.c:3437): never a RST for a RST or for a segment whose frame
%% was link broadcast or multicast (:3450-3451); for an ACK, a RST at the acknowledged
%% number; otherwise a RST acknowledging everything the segment occupied. The header's own
%% flags decide, with the segment's number and length as the stages left them. The
%% interface sends it within its RST rate limit.
dropwithreset(#seg{hdr_flags = Flags, ack = Ack, seq = Seq, len = Tlen, link_cast = LinkCast},
              Tcb, Ctx) ->
    if
        Flags band ?TH_RST =/= 0; LinkCast =/= unicast ->
            {done, Tcb, []};
        Flags band ?TH_ACK =/= 0 ->
            {done, Tcb, [{reset, erx_tcp:respond(Tcb, Ctx, Ack, 0, ?TH_RST)}]};
        true ->
            Len = Tlen + syn_len(Flags) + fin_len(Flags),
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
