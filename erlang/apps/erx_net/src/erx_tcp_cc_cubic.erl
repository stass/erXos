%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% FreeBSD: sys/netinet/cc/cc_cubic.c
%% Copyright (c) 2008-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% All rights reserved.
%%
%% This software was developed by Lawrence Stewart while studying at the Centre
%% for Advanced Internet Architectures, Swinburne University of Technology, made
%% possible in part by a grant from the Cisco University Research Program Fund
%% at Community Foundation Silicon Valley.
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
%% FreeBSD: sys/netinet/cc/cc_cubic.h
%% Copyright (c) 2008-2010 Lawrence Stewart <lstewart@freebsd.org>
%% Copyright (c) 2010 The FreeBSD Foundation
%% All rights reserved.
%%
%% This software was developed by Lawrence Stewart while studying at the Centre
%% for Advanced Internet Architectures, Swinburne University of Technology, made
%% possible in part by a grant from the Cisco University Research Program Fund
%% at Community Foundation Silicon Valley.
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

-module(erx_tcp_cc_cubic).
-moduledoc """
CUBIC congestion control (RFC 9438), the default `erx_tcp_cc` module, translated from
sys/netinet/cc/cc_cubic.c and the fixed-point functions of sys/netinet/cc/cc_cubic.h at the
commit NOTICE-freebsd records (docs/design-network-stack.md, "Loss detection and congestion
control"), with Hystart++ and the NewReno helpers from erx_tcp_cc. `cubic_k/2` and
`cubic_cwnd/4` are checked against FreeBSD's own, compiled on the host
(test/host/erx_tcp_cc_cubic_oracle_test.rb).

Time is the connection's monotonic clock in microseconds (`#ccv.now`) where FreeBSD counts
`ticks` at `hz`, so an epoch is timed to the microsecond. FreeBSD's arithmetic is in 32 and
64 bits; here it is in unbounded integers, which departs from FreeBSD only where FreeBSD's
would overflow:

* `cubic_k/2` shifts the window difference in 32 bits, which wraps at 65,536 segments;
  here it does not;
* `cubic_cwnd/4` returns its window as 32 bits, which wraps above 2^32 - 1 bytes; here the
  window is not cut;
* `cubic_ack_received` shifts the window increase left in 32 bits and `cubic_get_ssthresh`
  multiplies the flight by beta in 32 bits, which wrap for windows above 16 MiB; here they
  do not;
* the time since the epoch is held at `INT_MAX` microseconds, and the epoch dragged along,
  where FreeBSD's product of ticks and `tick` overflows past it, and adding the mean RTT to
  it does not overflow, where FreeBSD's `int` sum would turn negative and send the window
  into the Reno-friendly region;
* `cubic_conn_init`'s initial `W_max`, `UINT_MAX`, stands for a window larger than any;
  here it is `INT_MAX`, also larger than any window (`TCP_MAXWIN << 14`).
""".
-behaviour(erx_tcp_cc).

-include("erx_tcp_cc.hrl").

-export([init/1, conn_init/1, ack_received/3, cong_signal/3, post_recovery/1, after_idle/1,
         newround/2, rtt_sample/2]).
-export([cubic_k/2, cubic_cwnd/4]).

%% cc_cubic.h: fixed-point precision, beta, C and the fast-convergence factor, shifted.
-define(CUBIC_SHIFT, 8).
-define(CUBIC_SHIFT_4, 32).
-define(CUBIC_BETA, 179).
-define(CUBIC_C_FACTOR, 102).
-define(CUBIC_FC_FACTOR, 217).
-define(CUBIC_MIN_RTT_SAMPLES, 8).
-define(CUBED_ROOT_MAX_ULONG, 448845).
%% FreeBSD's hz * tick, microseconds in a second, and tick at the default hz of 1000.
-define(USECS_PER_SECOND, 1000000).
-define(TICK, 1000).
%% tcp_timer.h:78 and tcp_var.h:933.
-define(TCPTV_SRTTBASE, 0).
-define(TCP_RTT_SHIFT, 5).
-define(INT_MAX, 2147483647).

%% FreeBSD's struct cubic. Its CUBICFLAG_* bits are booleans; W_est and W_cubic, which
%% cubic_ack_received keeps in locals, are not kept.
-record(cubic, {
    k = 0 :: integer(),                  % K, seconds << CUBIC_SHIFT
    sum_rtt = 0 :: non_neg_integer(),    % sum_rtt_usecs over the epoch
    w_max = 0 :: non_neg_integer(),      % the window before the last reduction
    cwnd_epoch = 0 :: non_neg_integer(), % the window when the epoch began
    cong_event = false :: boolean(),
    in_slowstart = false :: boolean(),
    in_applimit = false :: boolean(),
    rto_event = false :: boolean(),
    in_tf = false :: boolean(),          % in the Reno-friendly region
    min_rtt = ?TCPTV_SRTTBASE :: non_neg_integer(),
    mean_rtt = 1 :: non_neg_integer(),
    epoch_ack_count = 0 :: non_neg_integer(),
    t_epoch = 0 :: integer(),            % microseconds
    undo_t_epoch = 0 :: integer(),
    undo_k = 0 :: integer(),
    undo_w_max = 0 :: non_neg_integer(),
    undo_cwnd_epoch = 0 :: non_neg_integer(),
    hystart :: erx_tcp_cc:hystart()
}).

-doc "`cubic_cb_init`: CUBIC takes no parameters.".
-spec init(erx_tcp_cc:params()) -> #cubic{}.
init(Params) when map_size(Params) =:= 0 -> #cubic{hystart = erx_tcp_cc:hystart_new()};
init(Params) -> error(badarg, [Params]).

-doc "`cubic_conn_init`: no reduction yet, so `W_max` is above any window.".
-spec conn_init(erx_tcp_cc:ccv()) -> erx_tcp_cc:ccv().
conn_init(#ccv{data = Cubic} = Ccv) -> Ccv#ccv{data = Cubic#cubic{w_max = ?INT_MAX}}.

-doc """
`cubic_ack_received`: an in-sequence acknowledgement outside recovery, while the window
limits sending, grows the window by slow start until ssthresh, and from then on toward
CUBIC's window at the time since the epoch, or the Reno-friendly one where that is larger
(RFC 9438, 4.2-4.5). One that arrives while the application limits sending starts a new
epoch at the next.
""".
-spec ack_received(erx_tcp_cc:ccv(), erx_tcp_cc:ack_type(), erx_tcp_cc:ack()) -> erx_tcp_cc:ccv().
ack_received(#ccv{data = Cubic} = Ccv, Type, Ack) ->
    ack(Ccv#ccv{data = record_rtt(Ccv, Cubic)}, Type, Ack).

ack(#ccv{fast_recovery = false, cong_recovery = false, cwnd = Cwin, ssthresh = Ss, data = Cubic} = Ccv, ack,
    #cc_ack{cwnd_limited = true} = Ack)
  when Cwin =< Ss; Cubic#cubic.min_rtt =:= ?TCPTV_SRTTBASE ->
    {Cwnd, Hystart} = erx_tcp_cc:slow_start(Ccv, Ack, Cubic#cubic.hystart),
    Ccv#ccv{cwnd = Cwnd, data = Cubic#cubic{in_slowstart = true, hystart = Hystart}};
ack(#ccv{fast_recovery = false, cong_recovery = false, data = Cubic} = Ccv, ack, #cc_ack{cwnd_limited = true}) ->
    avoid(Ccv#ccv{data = Cubic#cubic{hystart = erx_tcp_cc:hystart_leave_css(Cubic#cubic.hystart)}});
ack(#ccv{fast_recovery = false, cong_recovery = false, data = Cubic} = Ccv, ack, #cc_ack{cwnd_limited = false}) ->
    Ccv#ccv{data = Cubic#cubic{in_applimit = true}};
ack(#ccv{} = Ccv, _Type, #cc_ack{}) ->
    Ccv.

%% Congestion avoidance above ssthresh.
avoid(#ccv{cwnd = Cwin, maxseg = Mss, now = Now, data = Cubic0} = Ccv0) ->
    {Usecs, Cubic} = since_epoch(Now, epoch(Cwin, Mss, Now, Cubic0)),
    {WEst, Ccv} = erx_tcp_cc:cwnd_in_cong_avoid(Ccv0#ccv{data = Cubic}),
    WCubic = cubic_cwnd(Usecs + Cubic#cubic.mean_rtt, Cubic#cubic.w_max, Mss, Cubic#cubic.k),
    case WCubic < WEst of
        true ->
            Ccv#ccv{cwnd = WEst, data = Cubic#cubic{in_tf = true}};
        false ->
            Target = if
                         WCubic < Cwin -> Cwin;
                         WCubic > (Cwin * 3) bsr 1 -> (Cwin * 3) bsr 1;
                         true -> WCubic
                     end,
            Incr = (((Target - Cwin) bsl ?CUBIC_SHIFT) div Cwin * Mss) bsr ?CUBIC_SHIFT,
            Ccv#ccv{cwnd = Cwin + Incr}
    end.

%% A congestion-avoidance stage begins after slow start, a congestion event or an
%% application-limited period: the epoch restarts now from the current window, and after a
%% timeout W_max is that window (RFC 9438, 4.8).
epoch(Cwin, Mss, Now, #cubic{w_max = WMax} = Cubic0)
  when Cubic0#cubic.in_slowstart orelse Cubic0#cubic.cong_event orelse Cubic0#cubic.in_applimit ->
    Cubic = Cubic0#cubic{t_epoch = Now, cwnd_epoch = Cwin, k = cubic_k(WMax div Mss, Cwin div Mss),
                         in_slowstart = false, cong_event = false, in_applimit = false},
    case Cubic of
        #cubic{rto_event = true} -> Cubic#cubic{rto_event = false, w_max = Cwin, k = 0};
        #cubic{} -> Cubic
    end;
epoch(_Cwin, _Mss, _Now, Cubic) ->
    Cubic.

since_epoch(Now, #cubic{t_epoch = TEpoch} = Cubic) ->
    case Now - TEpoch of
        Usecs when Usecs >= 0, Usecs =< ?INT_MAX -> {Usecs, Cubic};
        _Overflow -> {?INT_MAX, Cubic#cubic{t_epoch = Now - ?INT_MAX}}
    end.

%% cubic_record_rtt: after CUBIC_MIN_RTT_SAMPLES samples, keep the lowest smoothed RTT, and
%% sum the samples for the epoch's mean.
record_rtt(#ccv{rtt_updated = Updated, srtt = Srtt}, #cubic{min_rtt = Min0, mean_rtt = Mean0} = Cubic0)
  when Updated >= ?CUBIC_MIN_RTT_SAMPLES ->
    Cubic = case Srtt < Min0 orelse Min0 =:= ?TCPTV_SRTTBASE of
                true ->
                    Min = max(?TICK bsr ?TCP_RTT_SHIFT, Srtt),
                    Cubic0#cubic{min_rtt = Min, mean_rtt = max(Mean0, Min)};
                false ->
                    Cubic0
            end,
    Cubic#cubic{sum_rtt = Cubic#cubic.sum_rtt + Srtt, epoch_ack_count = Cubic#cubic.epoch_ack_count + 1};
record_rtt(#ccv{}, Cubic) ->
    Cubic.

-doc """
`cubic_cong_signal`: a loss or an ECN mark outside recovery reduces ssthresh by beta, with
fast convergence (RFC 9438, 4.6-4.7), and starts a congestion event; a first timeout keeps
the epoch to undo and sets ssthresh from the flight; every timeout drops the window to one
segment; a timeout found spurious restores the epoch.
""".
-spec cong_signal(erx_tcp_cc:ccv(), erx_tcp_cc:signal(), integer() | none) -> erx_tcp_cc:ccv().
cong_signal(#ccv{fast_recovery = true} = Ccv, ndupack, _CurAck) ->
    hystart_loss(Ccv);
cong_signal(#ccv{cong_recovery = true} = Ccv, ndupack, _CurAck) ->
    (hystart_loss(Ccv))#ccv{fast_recovery = true};
cong_signal(#ccv{maxseg = Mss} = Ccv0, ndupack, _CurAck) ->
    Ccv = hystart_loss(Ccv0),
    {Ss, Cubic} = get_ssthresh(Ccv),
    Ccv#ccv{ssthresh = max(Ss, 2 * Mss), fast_recovery = true, cong_recovery = true,
            data = Cubic#cubic{cong_event = true}};
cong_signal(#ccv{cong_recovery = true} = Ccv, ecn, _CurAck) ->
    hystart_loss(Ccv);
cong_signal(#ccv{maxseg = Mss} = Ccv0, ecn, _CurAck) ->
    Ccv = hystart_loss(Ccv0),
    {Ss, Cubic} = get_ssthresh(Ccv),
    Ccv#ccv{ssthresh = max(Ss, 2 * Mss), cwnd = max(Ss, Mss), cong_recovery = true,
            data = Cubic#cubic{cong_event = true}};
cong_signal(#ccv{rxtshift = 1, snd_wnd = Wnd, pipe = Pipe, maxseg = Mss, data = Cubic} = Ccv, rto, _CurAck) ->
    Undo = Cubic#cubic{undo_t_epoch = Cubic#cubic.t_epoch, undo_cwnd_epoch = Cubic#cubic.cwnd_epoch,
                       undo_w_max = Cubic#cubic.w_max, undo_k = Cubic#cubic.k, rto_event = true},
    Ccv#ccv{ssthresh = max(2, ((min(Wnd, Pipe) * ?CUBIC_BETA) bsr ?CUBIC_SHIFT) div Mss) * Mss,
            cwnd = Mss, data = Undo};
cong_signal(#ccv{maxseg = Mss, data = Cubic} = Ccv, rto, _CurAck) ->
    Ccv#ccv{cwnd = Mss, data = Cubic#cubic{rto_event = true}};
cong_signal(#ccv{data = Cubic} = Ccv, rto_err, _CurAck) ->
    Ccv#ccv{data = Cubic#cubic{rto_event = false, k = Cubic#cubic.undo_k, w_max = Cubic#cubic.undo_w_max,
                               cwnd_epoch = Cubic#cubic.undo_cwnd_epoch,
                               t_epoch = Cubic#cubic.undo_t_epoch}}.

hystart_loss(#ccv{data = Cubic} = Ccv) ->
    Ccv#ccv{data = Cubic#cubic{hystart = erx_tcp_cc:hystart_loss(Cubic#cubic.hystart)}}.

%% cubic_get_ssthresh: W_max becomes the window, lowered by fast convergence when it is
%% below the last W_max; ssthresh is NewReno's in the Reno-friendly region, else the flight
%% times beta.
get_ssthresh(#ccv{cwnd = Cwnd, pipe = Pipe, data = #cubic{w_max = WMax, in_tf = InTf} = Cubic} = Ccv) ->
    Ss = case InTf of
             true -> erx_tcp_cc:cwnd_on_multiplicative_decrease(Ccv);
             false -> (Pipe * ?CUBIC_BETA) bsr ?CUBIC_SHIFT
         end,
    Max = case Cwnd < WMax of
              true -> (Cwnd * ?CUBIC_FC_FACTOR) bsr ?CUBIC_SHIFT;
              false -> Cwnd
          end,
    {Ss, Cubic#cubic{w_max = Max}}.

-doc """
`cubic_post_recovery`: leaving fast recovery sets the window to W_max times beta, or the
flight plus a segment when less is in flight (RFC 6582); the epoch's RTT samples become its
mean.
""".
-spec post_recovery(erx_tcp_cc:ccv()) -> erx_tcp_cc:ccv().
post_recovery(#ccv{fast_recovery = Fast, pipe = Pipe, ssthresh = Ss, maxseg = Mss, data = Cubic} = Ccv0) ->
    Ccv = if
              Fast andalso Pipe < Ss -> Ccv0#ccv{cwnd = max(Pipe, Mss) + Mss};
              Fast -> Ccv0#ccv{cwnd = max((Cubic#cubic.w_max * ?CUBIC_BETA) bsr ?CUBIC_SHIFT, 2 * Mss)};
              true -> Ccv0
          end,
    Mean = case Cubic of
               #cubic{epoch_ack_count = Count, sum_rtt = Sum} when Count > 0, Sum >= Count -> Sum div Count;
               #cubic{mean_rtt = Mean0} -> Mean0
           end,
    Ccv#ccv{data = Cubic#cubic{mean_rtt = Mean, epoch_ack_count = 0, sum_rtt = 0}}.

-doc """
`cubic_after_idle`: W_max keeps the larger of itself and the window, K is recomputed, the
window drops to the restart window, Hystart++ may run again, and the epoch restarts now.
""".
-spec after_idle(erx_tcp_cc:ccv()) -> erx_tcp_cc:ccv().
after_idle(#ccv{cwnd = Cw, maxseg = Mss, now = Now, data = Cubic} = Ccv) ->
    WMax = max(Cubic#cubic.w_max, Cw),
    (erx_tcp_cc:after_idle(Ccv))#ccv{
      data = Cubic#cubic{w_max = WMax, k = cubic_k(WMax div Mss, Cubic#cubic.cwnd_epoch div Mss),
                         hystart = erx_tcp_cc:hystart_idle(Cubic#cubic.hystart), t_epoch = Now}}.

-doc "`cubic_newround`, through erx_tcp_cc.".
-spec newround(erx_tcp_cc:ccv(), non_neg_integer()) -> erx_tcp_cc:ccv().
newround(#ccv{data = Cubic} = Ccv0, Round) ->
    {Ccv, Hystart} = erx_tcp_cc:hystart_newround(Ccv0, Round, Cubic#cubic.hystart),
    Ccv#ccv{data = Cubic#cubic{hystart = Hystart}}.

-doc "`cubic_rttsample`, through erx_tcp_cc.".
-spec rtt_sample(erx_tcp_cc:ccv(), erx_tcp_cc:rtt_sample()) -> erx_tcp_cc:ccv().
rtt_sample(#ccv{data = Cubic} = Ccv, Sample) ->
    Ccv#ccv{data = Cubic#cubic{hystart = erx_tcp_cc:hystart_rtt_sample(Sample, Cubic#cubic.hystart)}}.

-doc """
K, the seconds (shifted left by `CUBIC_SHIFT`) the window takes to grow from the epoch's
window back to W_max, both in segments: `cubic_k` (cc_cubic.h), the cube root of
`(W_max - cwnd_epoch) / C` by the polynomial of Apple's technical report KT-32 (RFC 9438,
figure 2).
""".
-spec cubic_k(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
cubic_k(WMaxSegs, EpochSegs) when WMaxSegs =< EpochSegs ->
    0;
cubic_k(WMaxSegs, EpochSegs) ->
    S0 = ((WMaxSegs - EpochSegs) bsl (2 * ?CUBIC_SHIFT)) div ?CUBIC_C_FACTOR,
    {S, P} = rebase(S0, 0),
    K = (((S * 275) bsr ?CUBIC_SHIFT) + 98) - (((S * S * 120) bsr ?CUBIC_SHIFT) bsr ?CUBIC_SHIFT),
    K bsl P.

%% Brings S below 1 << CUBIC_SHIFT by eighths, counting them, since the cube root of an
%% eighth is a half.
rebase(S, P) when S >= 256 -> rebase(S bsr 3, P + 1);
rebase(S, P) -> {S, P}.

-doc """
CUBIC's window in bytes `Usecs` microseconds into the epoch, `cubic_cwnd` (cc_cubic.h):
`C * (t - K)^3 * Smss + W_max` (RFC 9438, figure 1), at least 0, and `INT_MAX` once
`t - K` passes the range where FreeBSD's 64-bit cube is exact.
""".
-spec cubic_cwnd(non_neg_integer(), non_neg_integer(), pos_integer(), integer()) -> non_neg_integer().
cubic_cwnd(Usecs, WMax, Smss, K) ->
    case ((Usecs bsl ?CUBIC_SHIFT) - K * ?USECS_PER_SECOND) div ?USECS_PER_SECOND of
        T when T > ?CUBED_ROOT_MAX_ULONG -> ?INT_MAX;
        T when T < -?CUBED_ROOT_MAX_ULONG -> 0;
        T -> max(0, ((T * T * T * ?CUBIC_C_FACTOR) bsr ?CUBIC_SHIFT_4) * Smss + WMax)
    end.
