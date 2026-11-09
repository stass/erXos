%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% FreeBSD: sys/netinet/cc/cc.c
%% Copyright (c) 2007-2008
%% Swinburne University of Technology, Melbourne, Australia.
%% Copyright (c) 2009-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% All rights reserved.
%%
%% This software was developed at the Centre for Advanced Internet
%% Architectures, Swinburne University of Technology, by Lawrence Stewart and
%% James Healy, made possible in part by a grant from the Cisco University
%% Research Program Fund at Community Foundation Silicon Valley.
%%
%% Portions of this software were developed at the Centre for Advanced
%% Internet Architectures, Swinburne University of Technology, Melbourne,
%% Australia by David Hayes under sponsorship from the FreeBSD Foundation.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
%%
%% FreeBSD: sys/netinet/cc/cc.h
%% Copyright (c) 2007-2008
%% Swinburne University of Technology, Melbourne, Australia.
%% Copyright (c) 2009-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% All rights reserved.
%%
%% This software was developed at the Centre for Advanced Internet
%% Architectures, Swinburne University of Technology, by Lawrence Stewart and
%% James Healy, made possible in part by a grant from the Cisco University
%% Research Program Fund at Community Foundation Silicon Valley.
%%
%% Portions of this software were developed at the Centre for Advanced
%% Internet Architectures, Swinburne University of Technology, Melbourne,
%% Australia by David Hayes under sponsorship from the FreeBSD Foundation.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.
%%
%% FreeBSD: sys/netinet/cc/cc_newreno.c
%% Copyright (c) 1982, 1986, 1988, 1990, 1993, 1994, 1995
%% The Regents of the University of California.
%% Copyright (c) 2007-2008,2010,2014
%% Swinburne University of Technology, Melbourne, Australia.
%% Copyright (c) 2009-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% All rights reserved.
%%
%% This software was developed at the Centre for Advanced Internet
%% Architectures, Swinburne University of Technology, by Lawrence Stewart, James
%% Healy and David Hayes, made possible in part by a grant from the Cisco
%% University Research Program Fund at Community Foundation Silicon Valley.
%%
%% Portions of this software were developed at the Centre for Advanced
%% Internet Architectures, Swinburne University of Technology, Melbourne,
%% Australia by David Hayes under sponsorship from the FreeBSD Foundation.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%% ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_tcp_cc).
-moduledoc """
TCP congestion control's seam (docs/design-network-stack.md, "Loss detection and congestion
control"): the `erx_tcp_cc` behaviour, FreeBSD's `struct cc_algo` (sys/netinet/cc/cc.h), the
closed table of the modules a socket may choose, and what FreeBSD's modules share,
translated at the commit NOTICE-freebsd records: the NewReno helpers of sys/netinet/cc/cc.c
and Hystart++ (RFC 9406), written out alike in sys/netinet/cc/cc_newreno.c and cc_cubic.c.

Every callback is a pure function of a `#ccv{}` (erx_tcp_cc.hrl), FreeBSD's `struct cc_var`
with the `struct tcpcb` fields a module reads and, in its `data` field, the module's own
state, as `cc_data` holds it. The connection keeps the record for its life and refreshes
its inputs before each call (erx_tcp_cc.hrl). The callers translate `cc_conn_init`,
`cc_ack_received`, `cc_cong_signal`, `cc_post_recovery` (sys/netinet/tcp_input.c) and
`cc_after_idle` (sys/netinet/tcp_output.c), and with them what FreeBSD's callers do around
a module: they leave recovery after `post_recovery/1` (`EXIT_RECOVERY`) and before a
timeout's `cong_signal/3`, leave congestion recovery before an ECN mark at or past the
recovery point, and restore the window, ssthresh and recovery saved at the timeout before
`rto_err`. The window during recovery (PRR, partial acknowledgements) is the loss
module's to set, as `tcp_input.c` sets it in FreeBSD.

FreeBSD's defaults are fixed, as erXos has no sysctl for them: appropriate byte counting
(RFC 3465, `tcp_do_rfc3465`) is on with `tcp_abc_l_var` 2, and Hystart++ uses cc.c's
thresholds. Hystart++ runs only when the connection allows it in `#ccv.hystart`; FreeBSD's
default stack never does, only RACK.
""".

-include("erx_tcp_cc.hrl").

-export([module/1]).
-export([slow_start/3, cwnd_in_cong_avoid/1, cwnd_on_multiplicative_decrease/1,
         multiplicative_decrease/3, post_recovery/1, after_idle/1]).
-export([hystart_new/0, hystart_leave_css/1, hystart_loss/1, hystart_idle/1, hystart_newround/3,
         hystart_rtt_sample/2]).

-export_type([ccv/0, ack/0, ack_type/0, signal/0, params/0, hystart_mode/0,
              rtt_sample/0, ecn/0, hystart/0]).

-doc "FreeBSD's `struct cc_var` with the control block's fields its modules read.".
-type ccv() :: #ccv{}.
-doc "An acknowledgement as `cc_ack_received` reports it.".
-type ack() :: #cc_ack{}.
-doc "`ack_received/3`'s types: FreeBSD's `CC_ACK` and `CC_DUPACK` (cc/cc.h:119-120).".
-type ack_type() :: ack | dupack.
-doc "Congestion signals: `CC_NDUPACK`, `CC_ECN`, `CC_RTO` and `CC_RTO_ERR` (cc/cc.h:125-128).".
-type signal() :: ndupack | ecn | rto | rto_err.
-doc "A module's settings, FreeBSD's per-module sysctls and `TCP_CCALGOOPT` values.".
-type params() :: #{atom() => term()}.
-doc """
Whether the connection allows Hystart++ (`CCF_HYSTART_ALLOWED`), and what leaving its
conservative slow start does: `on` ends slow start at the current window; `shrink` cuts the
window back to the flight at entry with ssthresh at the flight of the lowest RTT
(`CCF_HYSTART_CAN_SH_CWND`); `shrink_mean` takes ssthresh halfway between the two
(`CCF_HYSTART_CONS_SSTH` as well).
""".
-type hystart_mode() :: off | on | shrink | shrink_mean.
-doc "An RTT sample: microseconds, the segment's transmissions, and the flight at its send.".
-type rtt_sample() :: {UsecRtt :: non_neg_integer(), RxtCnt :: non_neg_integer(), Fas :: non_neg_integer()}.
-doc "A received packet's ECN marks: `CCF_IPHDR_CE` and `CCF_TCPHDR_CWR`.".
-type ecn() :: #{ce := boolean(), cwr := boolean()}.

%% FreeBSD's struct cc_algo (cc/cc.h:141-200). cb_init is init/1 and returns the module's
%% state for #ccv.data; mod_init, cb_destroy and cc_data_sz have no work in Erlang, and
%% ctl_output's values arrive as init/1's parameters.
-callback init(params()) -> Data :: term().
-callback conn_init(ccv()) -> ccv().
-callback ack_received(ccv(), ack_type(), ack()) -> ccv().
%% CurAck is the acknowledgement that raised the signal, none for a timeout (cc_cong_signal's
%% th == NULL).
-callback cong_signal(ccv(), signal(), CurAck :: integer() | none) -> ccv().
-callback post_recovery(ccv()) -> ccv().
-callback after_idle(ccv()) -> ccv().
%% ecnpkt_handler: returns whether the receiver must acknowledge now (CCF_ACKNOW).
-callback ecn_pkt(ccv(), ecn()) -> {ccv(), AckNow :: boolean()}.
-callback newround(ccv(), Round :: non_neg_integer()) -> ccv().
-callback rtt_sample(ccv(), rtt_sample()) -> ccv().
-optional_callbacks([ecn_pkt/2]).

%% tcp.h:164.
-define(TCP_MAXWIN, 65535).
%% tcp_input.c:192, V_tcp_abc_l_var.
-define(TCP_ABC_L_VAR, 2).
%% cc.c:86-90.
-define(HYSTART_MINRTT_THRESH, 4000).
-define(HYSTART_MAXRTT_THRESH, 16000).
-define(HYSTART_N_RTTSAMPLES, 8).
-define(HYSTART_CSS_GROWTH_DIV, 4).
-define(HYSTART_CSS_ROUNDS, 5).

%% Hystart++'s per-connection state, the css_* fields and the HYSTART_ENABLED and
%% HYSTART_IN_CSS flags of struct newreno and struct cubic. An RTT of infinity is FreeBSD's
%% 0xffffffff, no sample yet; in_css implies enabled. css_last_fas, which FreeBSD only
%% logs, is not kept.
-record(hystart, {
    enabled = true :: boolean(),
    in_css = false :: boolean(),
    baseline_minrtt = infinity :: non_neg_integer() | infinity,
    current_round_minrtt = infinity :: non_neg_integer() | infinity,
    lastround_minrtt = infinity :: non_neg_integer() | infinity,
    rttsample_count = 0 :: non_neg_integer(),
    entered_at_round = 0 :: non_neg_integer(),
    current_round = 0 :: non_neg_integer(),
    fas_at_css_entry = 0 :: non_neg_integer(),
    lowrtt_fas = 0 :: non_neg_integer()
}).
-opaque hystart() :: #hystart{}.

-doc """
The module a socket's `{congestion, Name}` names, from the closed table of the modules the
build contains, as `cc_default_algo` looks names up in `cc_list` (cc/cc.c). A name never
becomes an atom.
""".
-spec module(binary()) -> {ok, module()} | {error, unknown}.
module(<<"cubic">>) -> {ok, erx_tcp_cc_cubic};
module(<<"newreno">>) -> {ok, erx_tcp_cc_newreno};
module(Name) when is_binary(Name) -> {error, unknown}.

-doc """
The window after a slow-start acknowledgement, with Hystart++'s state: the shared slow
start of `newreno_ack_received` (cc/cc_newreno.c) and `cubic_does_slow_start`
(cc/cc_cubic.c). Growth is the bytes acknowledged, at most `tcp_abc_l_var` segments per
segment, or one segment while resending after a timeout, and a quarter of that in
Hystart++'s conservative slow start.
""".
-spec slow_start(ccv(), ack(), hystart()) -> {Cwnd :: non_neg_integer(), hystart()}.
slow_start(#ccv{cwnd = Cw, maxseg = Mss, snd_scale = Scale, rexmit = Rexmit, labc = Labc,
                hystart = Mode}, #cc_ack{bytes = Bytes, nsegs = NSegs}, Hystart0) ->
    Abc = case Labc of
              none -> ?TCP_ABC_L_VAR;
              Local -> Local
          end,
    Hystart = css_entry(Mode, Hystart0),
    Incr = case Rexmit of
               false -> min(Bytes, NSegs * Abc * Mss);
               true -> min(Bytes, Mss)
           end,
    {grow(Cw, css_growth(Incr, Hystart), Scale), Hystart}.

%% Whether the last round's RTT rose enough over the one before it to enter conservative
%% slow start.
css_entry(off, Hystart) ->
    Hystart;
css_entry(_Mode, #hystart{enabled = true, in_css = false, rttsample_count = Count,
                          current_round_minrtt = Current, lastround_minrtt = Last} = Hystart)
  when Count >= ?HYSTART_N_RTTSAMPLES, is_integer(Current), is_integer(Last) ->
    Thresh = min(max(Last bsr 3, ?HYSTART_MINRTT_THRESH), ?HYSTART_MAXRTT_THRESH),
    case Current >= Last + Thresh of
        true ->
            Hystart#hystart{in_css = true, fas_at_css_entry = Hystart#hystart.lowrtt_fas,
                            baseline_minrtt = Current,
                            entered_at_round = Hystart#hystart.current_round};
        false ->
            Hystart
    end;
css_entry(_Mode, Hystart) ->
    Hystart.

css_growth(Incr, #hystart{in_css = true}) -> Incr div ?HYSTART_CSS_GROWTH_DIV;
css_growth(Incr, #hystart{}) -> Incr.

grow(Cw, Incr, Scale) when Incr > 0 -> min(Cw + Incr, ?TCP_MAXWIN bsl Scale);
grow(Cw, _Incr, _Scale) -> Cw.

-doc """
The window after a congestion-avoidance acknowledgement, `newreno_cc_cwnd_in_cong_avoid`
(cc/cc.c): one segment for each window's worth of bytes acknowledged, which the connection
marks in `abc_sentawnd` and this clears. Called only above ssthresh. The record returned
still holds the old window: CUBIC takes the result as its Reno-friendly estimate and may
not use it.
""".
-spec cwnd_in_cong_avoid(ccv()) -> {Cwnd :: non_neg_integer(), ccv()}.
cwnd_in_cong_avoid(#ccv{cwnd = Cw, ssthresh = Ss, maxseg = Mss, snd_scale = Scale,
                        abc_sentawnd = true} = Ccv) when Cw > Ss ->
    {grow(Cw, Mss, Scale), Ccv#ccv{abc_sentawnd = false}};
cwnd_in_cong_avoid(#ccv{cwnd = Cw, ssthresh = Ss} = Ccv) when Cw > Ss ->
    {Cw, Ccv}.

-doc """
NewReno's reduced window, `newreno_cc_cwnd_on_multiplicative_decrease` (cc/cc.c): the
window times `newreno_beta`, in whole segments and at least two.
""".
-spec cwnd_on_multiplicative_decrease(ccv()) -> pos_integer().
cwnd_on_multiplicative_decrease(#ccv{cwnd = Cw, maxseg = Mss}) ->
    multiplicative_decrease(Cw, ?NEWRENO_BETA, Mss).

-doc "`Cwnd` times `Factor` percent, in whole segments of `Mss` and at least two.".
-spec multiplicative_decrease(non_neg_integer(), 1..100, pos_integer()) -> pos_integer().
multiplicative_decrease(Cwnd, Factor, Mss) ->
    max(Cwnd * Factor div (100 * Mss), 2) * Mss.

-doc """
Leaving fast recovery, `newreno_cc_post_recovery` (cc/cc.c): the window becomes ssthresh,
or the flight plus a segment when less is in flight, so the connection does not burst
(RFC 6582).
""".
-spec post_recovery(ccv()) -> ccv().
post_recovery(#ccv{fast_recovery = true, pipe = Pipe, ssthresh = Ss, maxseg = Mss} = Ccv)
  when Pipe < Ss ->
    Ccv#ccv{cwnd = max(Pipe, Mss) + Mss};
post_recovery(#ccv{fast_recovery = true, ssthresh = Ss} = Ccv) ->
    Ccv#ccv{cwnd = Ss};
post_recovery(#ccv{} = Ccv) ->
    Ccv.

-doc """
Sending again after an idle period, `newreno_cc_after_idle` (cc/cc.c): the window drops to
the restart window (RFC 5681, 4.1) and ssthresh keeps three quarters of the old window
(RFC 2861, 2).
""".
-spec after_idle(ccv()) -> ccv().
after_idle(#ccv{cwnd = Cw, ssthresh = Ss, initwnd = Rw} = Ccv) ->
    Ccv#ccv{ssthresh = max(Ss, Cw - (Cw bsr 2)), cwnd = min(Rw, Cw)}.

-doc "Hystart++'s state for a new connection, as `newreno_cb_init` and `cubic_cb_init` set it.".
-spec hystart_new() -> hystart().
hystart_new() -> #hystart{}.

-doc "Slow start ended by the window passing ssthresh: Hystart++ is off until an idle period.".
-spec hystart_leave_css(hystart()) -> hystart().
hystart_leave_css(#hystart{in_css = true} = Hystart) -> Hystart#hystart{in_css = false, enabled = false};
hystart_leave_css(#hystart{} = Hystart) -> Hystart.

-doc "A loss or an ECN mark: Hystart++ is off until an idle period.".
-spec hystart_loss(hystart()) -> hystart().
hystart_loss(#hystart{} = Hystart) -> Hystart#hystart{in_css = false, enabled = false}.

-doc "An idle period: Hystart++ may run again.".
-spec hystart_idle(hystart()) -> hystart().
hystart_idle(#hystart{enabled = false} = Hystart) -> Hystart#hystart{enabled = true, in_css = false};
hystart_idle(#hystart{} = Hystart) -> Hystart.

-doc """
A new round begins, `newreno_newround` and `cubic_newround`: the round's lowest RTT becomes
the last round's, and after `hystart_css_rounds` rounds of conservative slow start the
connection leaves it as its `#ccv.hystart` says.
""".
-spec hystart_newround(ccv(), non_neg_integer(), hystart()) -> {ccv(), hystart()}.
hystart_newround(Ccv, Round, #hystart{current_round_minrtt = Current} = Hystart0) ->
    Hystart = Hystart0#hystart{lastround_minrtt = Current, current_round_minrtt = infinity,
                               rttsample_count = 0, current_round = Round},
    case Hystart of
        %% FreeBSD subtracts in 32 bits; rounds only count up, so this does not wrap.
        #hystart{in_css = true, entered_at_round = Entered}
          when Round - Entered >= ?HYSTART_CSS_ROUNDS ->
            css_exit(Ccv, Round, Hystart);
        #hystart{} ->
            {Ccv, Hystart}
    end.

css_exit(#ccv{hystart = shrink} = Ccv, Round, #hystart{lowrtt_fas = Low, fas_at_css_entry = Entry} = Hystart) ->
    {Ccv#ccv{ssthresh = Low, cwnd = Entry}, Hystart#hystart{entered_at_round = Round}};
css_exit(#ccv{hystart = shrink_mean} = Ccv, Round, #hystart{lowrtt_fas = Low, fas_at_css_entry = Entry} = Hystart) ->
    {Ccv#ccv{ssthresh = (Low + Entry) div 2, cwnd = Entry}, Hystart#hystart{entered_at_round = Round}};
css_exit(#ccv{cwnd = Cw} = Ccv, _Round, Hystart) ->
    {Ccv#ccv{ssthresh = Cw}, Hystart#hystart{in_css = false, enabled = false}}.

-doc """
An RTT sample, `newreno_rttsample` and `cubic_rttsample`: samples of retransmitted segments
are ambiguous and ignored; a round whose RTT falls below the baseline shows conservative
slow start was entered in error, and it is left.
""".
-spec hystart_rtt_sample(rtt_sample(), hystart()) -> hystart().
hystart_rtt_sample({_UsecRtt, RxtCnt, _Fas}, Hystart) when RxtCnt > 1 ->
    Hystart;
hystart_rtt_sample({UsecRtt, _RxtCnt, Fas}, #hystart{rttsample_count = Count} = Hystart0) ->
    Hystart1 = Hystart0#hystart{rttsample_count = Count + 1},
    Hystart = case Hystart1#hystart.current_round_minrtt > UsecRtt of
                  true -> Hystart1#hystart{current_round_minrtt = UsecRtt, lowrtt_fas = Fas};
                  false -> Hystart1
              end,
    case Hystart of
        #hystart{rttsample_count = N, current_round_minrtt = Current, baseline_minrtt = Baseline,
                 lastround_minrtt = Last}
          when N >= ?HYSTART_N_RTTSAMPLES, is_integer(Current), Current < Baseline, is_integer(Last) ->
            Hystart#hystart{in_css = false, baseline_minrtt = infinity};
        #hystart{} ->
            Hystart
    end.
