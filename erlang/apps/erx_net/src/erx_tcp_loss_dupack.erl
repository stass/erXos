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

-module(erx_tcp_loss_dupack).
-moduledoc """
The default loss module (docs/design-network-stack.md, "Loss detection and congestion
control"): FreeBSD's default stack's duplicate-acknowledgement processing, translated from
`tcp_do_segment`, `tcp_do_prr_ack` and `tcp_newreno_partial_ack` in
sys/netinet/tcp_input.c and the timeout's choice in `tcp_timer_rexmt`
(sys/netinet/tcp_timer.c), at the commit NOTICE-freebsd records. What FreeBSD does in
sys/netinet/tcp_sack.c, which erXos does not read, is written from the RFCs: the scoreboard
is erx_tcp_sendlog's (RFC 6675), and a partial acknowledgement without SACK blocks in SACK
recovery takes PRR's path (RFC 6937) where FreeBSD calls `tcp_sack_partialack`.

FreeBSD's defaults are fixed, as erXos has no sysctl for them: RFC 6675 recovery
(`tcp_do_newsack`), PRR (`tcp_do_prr`, RFC 6937) and limited transmit (`tcp_do_rfc3042`,
RFC 3042) are on, and the duplicate threshold is 3 (`tcprexmtthresh`). Branches that only
those settings switched off reach are not translated. FreeBSD's lost-retransmission
detection (`tcp_do_lrd`) is not built: no RFC specifies it and its code is in tcp_sack.c.

Departures, each from the send log's model: FreeBSD sets `snd_cwnd`, calls `tcp_output` and
restores it; here the module returns the window for the output and the one to keep
(erx_tcp_loss, `allowance/3`). NewReno's retransmission of the segment at `snd_una`, which
FreeBSD makes by moving `snd_nxt` back, is a range marked lost in the log, which output
retransmits first. The number of segments limited transmit sent (`snd_limited`) and PRR's
bytes sent (`prr_out`) are taken from the log instead of counted in `tcp_output`. In SACK
recovery PRR's window is RFC 6937's pipe plus `sndcnt` over the log's pipe after this
acknowledgement, where FreeBSD writes `pipe - del_data` with `snd_una` not yet advanced.
""".

-behaviour(erx_tcp_loss).

-include("erx_tcp_cc.hrl").
-include("erx_tcp_loss.hrl").

-export([init/1, ack/4, rewind/4, allowance/3, deadline/1, expired/3]).

%% tcprexmtthresh (tcp_input.c).
-define(REXMT_THRESH, 3).
%% The bound tcp_do_prr_ack puts on t_dupacks before multiplying it by maxseg.
-define(DUPACKS_CAP, 32767).

%% What allowance/3 returns for the output after the last acknowledgement. The entries
%% compute their windows there, since they need ssthresh after the connection applied the
%% congestion signal.
-type pending() :: none | {window, Send :: non_neg_integer(), Keep :: non_neg_integer()}
                 | sack_entry | newreno_entry.

-record(dupack, {
    sack :: boolean(),                         % TF_SACK_PERMIT
    dupacks = 0 :: non_neg_integer(),          % t_dupacks
    limited_base = none :: none | integer(),   % snd_max at the first duplicate (RFC 3042)
    prr_delivered = 0 :: integer(),            % sackhint.prr_delivered
    prr_base = 0 :: non_neg_integer(),         % the log's sent_bytes when recovery began
    recover_fs = 0 :: non_neg_integer(),       % sackhint.recover_fs
    pending = none :: pending()
}).

-doc "A connection's state; `sack` is whether it negotiated SACK.".
-spec init(erx_tcp_loss:params()) -> #dupack{}.
init(#{sack := Sack}) when is_boolean(Sack) -> #dupack{sack = Sack};
init(_) -> erlang:error(badarg).

-doc """
Translates the acknowledgement processing of `tcp_do_segment` for the synchronized states:
the scoreboard update (`tcp_sack_doack`'s role, RFC 6675 section 5 `Update()`), a
duplicate acknowledgement (RFC 6675 section 2's definition when SACK was negotiated,
RFC 5681's otherwise), limited transmit, entering recovery on the third duplicate or on more
than `(DupThresh - 1) * SMSS` SACKed bytes (RFC 6675 section 5), PRR on each acknowledgement
during recovery, and NewReno's partial acknowledgement (RFC 6582).
""".
-spec ack(erx_tcp_loss:ack(), erx_tcp_sendlog:log(), #dupack{}, integer()) ->
    {erx_tcp_loss:verdict(), erx_tcp_sendlog:log(), #dupack{}, [erx_tcp_loss:event()]}.
ack(#loss_ack{ack = Ack} = A0, Log0, State0, _Now) ->
    State = State0#dupack{pending = none},
    Una = erx_tcp_sendlog:snd_una(Log0),
    A = A0#loss_ack{una = Una},
    %% tcp_is_sack_recovery is asked before the scoreboard update and again after it, when
    %% holes the acknowledgement filled no longer count.
    {Log, Change, Delivered} = scoreboard(sack_recovery(A, Log0, State), A, Log0),
    SackRecovery = sack_recovery(A, Log, State),
    if
        Ack < Una -> {continue, Log, State, []};
        Ack =:= Una -> duplicate(A, Log, State, Change, Delivered, SackRecovery);
        true -> advancing(A, Log, State, Change, Delivered, SackRecovery)
    end.

-doc """
Sending goes back to `snd_una` (erx_tcp_loss:cause()). On a retransmission timeout the
first keeps the SACK information and resends the holes, later ones forget it
(`tcp_timer_rexmt`: `tcp_resend_sackholes` when `t_rxtshift` is 1, `tcp_free_sackholes`
otherwise), and `t_dupacks` is cleared, as `cc_cong_signal` does for `CC_RTO`. A smaller path
MTU forgets the SACK information and keeps `t_dupacks` (`tcp_mtudisc`'s
`tcp_free_sackholes`). A window that shrank to zero loses what was sent into it, so the pipe
leaves it out and the log resends it once the window opens.
""".
-spec rewind(erx_tcp_loss:cause(), erx_tcp_sendlog:log(), #dupack{}, integer()) ->
    {erx_tcp_sendlog:log(), #dupack{}}.
rewind({timeout, 1}, Log, State, _Now) ->
    {erx_tcp_sendlog:timeout(Log, keep), timed_out(State)};
rewind({timeout, _}, Log, State, _Now) ->
    {erx_tcp_sendlog:timeout(Log, expunge), timed_out(State)};
rewind(mtu, Log, State, _Now) ->
    {erx_tcp_sendlog:timeout(Log, expunge), State};
rewind({window, Una, Max}, Log, State, _Now) when Max > Una ->
    {erx_tcp_sendlog:lose(Log, Una, Max), State};
rewind({window, _, _}, Log, State, _Now) ->
    {Log, State}.

timed_out(State) -> State#dupack{dupacks = 0, limited_base = none, pending = none}.

-doc """
The window for the output after the last acknowledgement (erx_tcp_loss). Entering SACK
recovery sends one segment and keeps ssthresh; entering NewReno recovery retransmits the
segment at `snd_una` and keeps `ssthresh + maxseg * t_dupacks`, as `snd_limited` is cleared
first.
""".
-spec allowance(erx_tcp_sendlog:log(), #dupack{}, erx_tcp_cc:ccv()) -> erx_tcp_loss:allowance().
allowance(_, #dupack{pending = none}, _) ->
    none;
allowance(_, #dupack{pending = {window, Send, Keep}}, _) ->
    {Send, Keep};
allowance(Log, #dupack{pending = sack_entry}, #ccv{maxseg = Mss, ssthresh = Ssthresh}) ->
    {erx_tcp_sendlog:pipe(Log) + Mss, Ssthresh};
allowance(Log, #dupack{pending = newreno_entry}, #ccv{maxseg = Mss, ssthresh = Ssthresh}) ->
    %% FreeBSD clears snd_limited before this assignment, so the kept window is always
    %% ssthresh plus three segments.
    {erx_tcp_sendlog:pipe(Log) + Mss, Ssthresh + Mss * ?REXMT_THRESH}.

-doc "The module keeps no deadline of its own.".
-spec deadline(#dupack{}) -> infinity.
deadline(_) -> infinity.

-doc "Never called, since `deadline/1` is `infinity`; changes nothing.".
-spec expired(erx_tcp_sendlog:log(), #dupack{}, integer()) ->
    {erx_tcp_sendlog:log(), #dupack{}, [erx_tcp_loss:event()]}.
expired(Log, State, _Now) -> {Log, State, []}.

%% tcp_is_sack_recovery: SACK negotiated, and SACK blocks on this segment or holes kept.
sack_recovery(#loss_ack{sack_opt = Opt}, Log, #dupack{sack = Sack}) ->
    Sack andalso (Opt orelse erx_tcp_sendlog:has_holes(Log)).

%% Applies the acknowledgement to the log. With SACK, the blocks are applied and IsLost
%% marked (RFC 6675 section 5, Update()), and the change is classified as FreeBSD's
%% sackstatus_t: nochange, change (new SACKed bytes, or holes cut from the left by the
%% cumulative acknowledgement), or newloss (bytes newly lost, RFC 6937 section 3's further
%% loss). Without SACK only the cumulative acknowledgement is applied.
scoreboard(true, #loss_ack{ack = Ack, sack_blocks = Blocks, ccv = #ccv{maxseg = Mss}}, Log0) ->
    HadHoles = erx_tcp_sendlog:has_holes(Log0),
    Advances = Ack > erx_tcp_sendlog:snd_una(Log0),
    {Log1, #{delivered := Delivered, sacked := Newly}} = erx_tcp_sendlog:ack(Log0, Ack, Blocks),
    {Log2, NewlyLost} = erx_tcp_sendlog:mark_lost(Log1, ?REXMT_THRESH, Mss),
    Change = if
        NewlyLost > 0 -> newloss;
        Newly > 0; Advances andalso HadHoles -> change;
        true -> nochange
    end,
    {Log2, Change, Delivered};
scoreboard(false, #loss_ack{ack = Ack}, Log0) ->
    {Log1, #{delivered := Delivered}} = erx_tcp_sendlog:ack(Log0, Ack, []),
    {Log1, nochange, Delivered}.

%% th_ack == snd_una: whether this is a duplicate, then its processing.
duplicate(#loss_ack{pure = Pure, new_fin = NewFin, rexmt_armed = Armed} = A, Log, State, Change,
          Delivered, SackRecovery) ->
    IsDuplicate = case State#dupack.sack of
        true -> Change =/= nochange;
        false -> Pure
    end,
    if
        not IsDuplicate -> {continue, Log, State, []};
        NewFin -> {continue, Log, State#dupack{dupacks = 0}, []};
        not Armed -> {continue, Log, State#dupack{dupacks = 0}, []};
        true -> counted(A, Log, State#dupack{dupacks = State#dupack.dupacks + 1}, Change,
                        Delivered, SackRecovery)
    end.

counted(#loss_ack{ccv = #ccv{fast_recovery = Fast, maxseg = Mss, cwnd = Cwnd}} = A, Log,
        #dupack{dupacks = Dupacks, sack = Sack} = State, Change, Delivered, SackRecovery) ->
    if
        Dupacks > ?REXMT_THRESH; Fast ->
            State1 = case Fast andalso Sack of
                true -> prr(A, Log, State, Change, Delivered);
                false -> State#dupack{pending = {window, Cwnd + Mss, Cwnd + Mss}}
            end,
            {drop, Log, State1, [{ack_received, dupack}]};
        Dupacks =:= ?REXMT_THRESH ->
            enter_recovery(A, Log, State, SackRecovery);
        Sack ->
            case erx_tcp_sendlog:sacked_bytes(Log) > (?REXMT_THRESH - 1) * Mss of
                true -> enter_recovery(A, Log, State, SackRecovery);
                false -> limited_transmit(A, Log, State)
            end;
        true ->
            limited_transmit(A, Log, State)
    end.

%% enter_recovery in tcp_do_segment.
enter_recovery(#loss_ack{ack = Ack, una = Una, snd_nxt = SndNxt, recover = Recover,
                         ccv = #ccv{fast_recovery = Fast, maxseg = Mss}},
               Log, State0, SackRecovery) ->
    State = State0#dupack{dupacks = ?REXMT_THRESH},
    AlreadyRecovering = case SackRecovery of
        true -> Fast;
        false -> Ack =< Recover
    end,
    case AlreadyRecovering of
        true ->
            {continue, Log, State#dupack{dupacks = 0}, []};
        false ->
            Limited = snd_limited(Log, State, Mss),
            PrrDelivered = case SackRecovery of
                true -> min(erx_tcp_sendlog:snd_max(Log) - Ack, (Limited + 1) * Mss);
                false -> Mss
            end,
            State1 = State#dupack{prr_delivered = PrrDelivered, recover_fs = max(1, SndNxt - Una),
                                  prr_base = erx_tcp_sendlog:sent_bytes(Log),
                                  limited_base = none},
            Events = [{cong_signal, ndupack}, {ack_received, dupack}, stop_rexmt],
            case SackRecovery of
                true ->
                    {drop, erx_tcp_sendlog:resend_holes(Log), State1#dupack{pending = sack_entry},
                     Events ++ [resume_at_max]};
                false ->
                    {drop, erx_tcp_sendlog:lose(Log, Ack, Ack + 1),
                     State1#dupack{pending = newreno_entry}, Events}
            end
    end.

%% The first and second duplicates (RFC 3042): each lets one new segment go. The window is
%% FreeBSD's, the flight plus a segment for each duplicate not yet used, moved from the
%% flight to the pipe, which already leaves out SACKed bytes (FreeBSD subtracts
%% tcp_sack_adjust instead).
limited_transmit(#loss_ack{una = Una, snd_nxt = SndNxt,
                           ccv = #ccv{maxseg = Mss, cwnd = Cwnd, rxtshift = Shift}},
                 Log, #dupack{dupacks = Dupacks} = State0) ->
    SndMax = erx_tcp_sendlog:snd_max(Log),
    State = case Dupacks of
        1 -> State0#dupack{limited_base = SndMax};
        _ -> State0
    end,
    Base = case SndNxt =:= SndMax andalso Shift =:= 0 of
        true -> SndNxt - Una;
        false -> Cwnd
    end,
    Window = Base + (Dupacks - snd_limited(Log, State, Mss)) * Mss,
    Send = max(0, Window - erx_tcp_sendlog:flight(Log) + erx_tcp_sendlog:pipe(Log)),
    {drop, Log, State#dupack{pending = {window, Send, Cwnd}}, [{ack_received, dupack}]}.

%% snd_limited: the segments limited transmit sent since the first duplicate, at most 2.
snd_limited(_, #dupack{limited_base = none}, _) ->
    0;
snd_limited(Log, #dupack{limited_base = Base}, Mss) ->
    Sent = erx_tcp_sendlog:snd_max(Log) - Base,
    if
        Sent > Mss -> 2;
        Sent > 0 -> 1;
        true -> 0
    end.

%% th_ack > snd_una. With SACK, an acknowledgement that also changes the scoreboard counts
%% as a duplicate (RFC 6675 section 5) and may begin recovery; below snd_recover it is a
%% partial acknowledgement.
advancing(#loss_ack{snd_nxt = SndNxt, ccv = #ccv{rxtshift = Shift, fast_recovery = Fast,
                                                  maxseg = Mss}} = A,
          Log, State0, Change, Delivered, SackRecovery) ->
    Counts = SackRecovery
        andalso ((Shift =:= 0 andalso Change =/= nochange) orelse (Shift > 0 andalso Change =:= newloss))
        andalso SndNxt =:= erx_tcp_sendlog:snd_max(Log),
    State = State0#dupack{dupacks = case Counts of true -> 1; false -> 0 end},
    case Counts andalso not Fast andalso erx_tcp_sendlog:sacked_bytes(Log) > (?REXMT_THRESH - 1) * Mss of
        true -> enter_recovery(A, Log, State, SackRecovery);
        false -> partial(A, Log, State, Change, Delivered)
    end.

partial(#loss_ack{ack = Ack, una = Una, recover = Recover,
                  ccv = #ccv{fast_recovery = Fast, cong_recovery = Cong}} = A,
        Log, #dupack{sack = Sack} = State, Change, Delivered) ->
    if
        Ack >= Recover ->
            {continue, Log, State, []};
        Fast, Sack ->
            {continue, Log, prr(A, Log, State, Change, Delivered), [stop_rexmt, ack_now]};
        Fast ->
            newreno_partial_ack(A, Log, State);
        Cong ->
            %% ECN's window reduction always uses PRR-SSRB, with this acknowledgement's bytes.
            {continue, Log, prr(A, Log, State, change, Ack - Una), []};
        true ->
            {continue, Log, State, []}
    end.

%% tcp_newreno_partial_ack: retransmit the next unacknowledged segment and deflate the
%% window by the bytes acknowledged, plus a segment.
newreno_partial_ack(#loss_ack{ack = Ack, una = Una, ccv = #ccv{maxseg = Mss, cwnd = Cwnd}}, Log,
                    State) ->
    Log1 = erx_tcp_sendlog:lose(Log, Ack, Ack + 1),
    Keep = max(Cwnd - (Ack - Una), 0) + Mss,
    {continue, Log1, State#dupack{pending = {window, erx_tcp_sendlog:pipe(Log1) + Mss, Keep}},
     [stop_rexmt, ack_now]}.

%% tcp_do_prr_ack: PRR's window for this acknowledgement (RFC 6937 section 3), kept as the
%% pending window with the PRR counters it updates.
prr(#loss_ack{una = Una, snd_nxt = SndNxt, recover = Recover,
              ccv = #ccv{maxseg = Mss, ssthresh = Ssthresh, cwnd = Cwnd,
                         fast_recovery = Fast, cong_recovery = Cong}} = A,
    Log, #dupack{dupacks = Dupacks, prr_delivered = PrrDelivered0, prr_base = PrrBase,
                 recover_fs = RecoverFs0} = State,
    Change, Delivered) ->
    SndMax = erx_tcp_sendlog:snd_max(Log),
    SackRecovery = sack_recovery(A, Log, State),
    {Del, Pipe} = case SackRecovery orelse (Cong andalso not Fast) of
        true ->
            {Delivered, erx_tcp_sendlog:pipe(Log)};
        false ->
            D = case PrrDelivered0 < ?REXMT_THRESH * Mss + Recover - Una of
                true -> Mss;
                false -> 0
            end,
            {D, max(0, SndMax - Una - min(?DUPACKS_CAP, Dupacks) * Mss)}
    end,
    PrrDelivered = PrrDelivered0 + Del,
    PrrOut = erx_tcp_sendlog:sent_bytes(Log) - PrrBase,
    {SndCnt0, RecoverFs} = case Pipe >= Ssthresh of
        true ->
            Fs = case RecoverFs0 of
                0 -> max(1, SndNxt - Una);
                _ -> RecoverFs0
            end,
            {ceil_div(PrrDelivered * Ssthresh, Fs) - PrrOut + Mss - 1, Fs};
        false ->
            Limit = case Change =:= newloss orelse Del =:= 0 of
                true -> PrrDelivered - PrrOut;
                false -> max(PrrDelivered - PrrOut, Del) + Mss
            end,
            {min(Ssthresh - Pipe, Limit), RecoverFs0}
    end,
    SndCnt = max(SndCnt0, 0) div Mss,
    Window = if
        Fast, SackRecovery -> Pipe + SndCnt * Mss;
        Fast -> (SndMax - Una) + SndCnt * Mss;
        Cong -> Pipe + SndCnt * Mss;
        true -> Cwnd
    end,
    W = max(Mss, Window),
    State#dupack{prr_delivered = PrrDelivered, recover_fs = RecoverFs, pending = {window, W, W}}.

ceil_div(N, D) -> (N + D - 1) div D.
