%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
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
%%
%% FreeBSD: sys/netinet/cc/cc_newreno.h
%% Copyright (c) 2017 Tom Jones <tj@enoti.me>
%% All rights reserved.
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
%% ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%% SUCH DAMAGE.

-module(erx_tcp_cc_newreno).
-moduledoc """
NewReno congestion control (RFC 5681, RFC 6582), an `erx_tcp_cc` module translated from
sys/netinet/cc/cc_newreno.c at the commit NOTICE-freebsd records (docs/design-network-stack.md,
"Loss detection and congestion control"), with Hystart++ from erx_tcp_cc.

`init/1` takes `beta` and `beta_ecn`, percentages from 1 to 100 that default to FreeBSD's
50 and 80, and `abe`, FreeBSD's `net.inet.tcp.cc.abe` (RFC 8511), off by default. An ECN
mark backs off by `beta_ecn` when `abe` is on or when `beta_ecn` was given, as setting it
through `TCP_CCALGOOPT` enables it (`newreno_ctl_output`).

One departure: `newreno_cong_signal` would scale ssthresh by `beta / beta_ecn` on a loss
during ECN congestion recovery when `abe` and `abe_frlossreduce` are on, but its condition
is parenthesised so that it never holds (`IN_CONGRECOVERY(t_flags && V_cc_do_abe &&
V_cc_abe_frlossreduce)`); this module leaves that branch and its setting out.
""".
-behaviour(erx_tcp_cc).

-include("erx_tcp_cc.hrl").

-export([init/1, conn_init/1, ack_received/3, cong_signal/3, post_recovery/1, after_idle/1,
         newround/2, rtt_sample/2]).

%% FreeBSD's struct newreno, with Hystart++'s fields in erx_tcp_cc's state.
-record(newreno, {
    beta :: 1..100,
    beta_ecn :: 1..100,
    ecn_backoff :: boolean(),          % V_cc_do_abe or CC_NEWRENO_BETA_ECN_ENABLED
    hystart :: erx_tcp_cc:hystart()
}).

-doc "`newreno_cb_init`: the module's state from its parameters; an unknown one raises.".
-spec init(erx_tcp_cc:params()) -> #newreno{}.
init(Params) ->
    case maps:keys(maps:without([beta, beta_ecn, abe], Params)) of
        [] -> ok;
        _Unknown -> error(badarg, [Params])
    end,
    #newreno{beta = beta(maps:get(beta, Params, ?NEWRENO_BETA)),
             beta_ecn = beta(maps:get(beta_ecn, Params, ?NEWRENO_BETA_ECN)),
             ecn_backoff = maps:is_key(beta_ecn, Params) orelse flag(maps:get(abe, Params, false)),
             hystart = erx_tcp_cc:hystart_new()}.

%% The sysctl handler, newreno_beta_handler, refuses 0 and more than 100; newreno_ctl_output
%% stores any value, and this refuses those too.
beta(Beta) when is_integer(Beta), Beta >= 1, Beta =< 100 -> Beta;
beta(Beta) -> error(badarg, [Beta]).

flag(Flag) when is_boolean(Flag) -> Flag;
flag(Flag) -> error(badarg, [Flag]).

-doc "NewReno has no `conn_init`.".
-spec conn_init(erx_tcp_cc:ccv()) -> erx_tcp_cc:ccv().
conn_init(Ccv) -> Ccv.

-doc """
`newreno_ack_received`: an in-sequence acknowledgement outside recovery, while the window
limits sending, opens the window in slow start or congestion avoidance.
""".
-spec ack_received(erx_tcp_cc:ccv(), erx_tcp_cc:ack_type(), erx_tcp_cc:ack()) -> erx_tcp_cc:ccv().
ack_received(#ccv{fast_recovery = false, cong_recovery = false, cwnd = Cw, ssthresh = Ss,
                  data = Data} = Ccv0, ack,
             #cc_ack{cwnd_limited = true}) when Cw > Ss ->
    {Cwnd, Ccv} = erx_tcp_cc:cwnd_in_cong_avoid(Ccv0),
    Ccv#ccv{cwnd = Cwnd, data = Data#newreno{hystart = erx_tcp_cc:hystart_leave_css(Data#newreno.hystart)}};
ack_received(#ccv{fast_recovery = false, cong_recovery = false, data = Data} = Ccv, ack,
             #cc_ack{cwnd_limited = true} = Ack) ->
    {Cwnd, Hystart} = erx_tcp_cc:slow_start(Ccv, Ack, Data#newreno.hystart),
    Ccv#ccv{cwnd = Cwnd, data = Data#newreno{hystart = Hystart}};
ack_received(#ccv{} = Ccv, _Type, #cc_ack{}) ->
    Ccv.

-doc """
`newreno_cong_signal`: a loss sets ssthresh to the window times beta and enters recovery; an
ECN mark cuts the window as well; a first timeout sets ssthresh from the flight, and every
timeout drops the window to one segment.
""".
-spec cong_signal(erx_tcp_cc:ccv(), erx_tcp_cc:signal(), integer() | none) -> erx_tcp_cc:ccv().
cong_signal(#ccv{cwnd = Cw, maxseg = Mss, data = Data} = Ccv, Signal, _CurAck) ->
    Factor = case Signal of
                 ecn when Data#newreno.ecn_backoff -> Data#newreno.beta_ecn;
                 _ -> Data#newreno.beta
             end,
    signal(Signal, Factor, erx_tcp_cc:multiplicative_decrease(Cw, Factor, Mss), Ccv).

signal(ndupack, _Factor, _Cwin, #ccv{fast_recovery = true} = Ccv) ->
    hystart_loss(Ccv);
signal(ndupack, _Factor, _Cwin, #ccv{cong_recovery = true} = Ccv) ->
    (hystart_loss(Ccv))#ccv{fast_recovery = true};
signal(ndupack, _Factor, Cwin, Ccv) ->
    (hystart_loss(Ccv))#ccv{ssthresh = Cwin, fast_recovery = true, cong_recovery = true};
signal(ecn, _Factor, _Cwin, #ccv{cong_recovery = true} = Ccv) ->
    hystart_loss(Ccv);
signal(ecn, _Factor, Cwin, Ccv) ->
    (hystart_loss(Ccv))#ccv{ssthresh = Cwin, cwnd = Cwin, cong_recovery = true};
signal(rto, Factor, _Cwin, #ccv{rxtshift = 1, snd_wnd = Wnd, pipe = Pipe, maxseg = Mss} = Ccv) ->
    Ccv#ccv{ssthresh = max(2, min(Wnd, Pipe) * Factor div (100 * Mss)) * Mss, cwnd = Mss};
signal(rto, _Factor, _Cwin, #ccv{maxseg = Mss} = Ccv) ->
    Ccv#ccv{cwnd = Mss};
signal(rto_err, _Factor, _Cwin, Ccv) ->
    Ccv.

hystart_loss(#ccv{data = Data} = Ccv) ->
    Ccv#ccv{data = Data#newreno{hystart = erx_tcp_cc:hystart_loss(Data#newreno.hystart)}}.

-doc "`newreno_cc_post_recovery`, through erx_tcp_cc.".
-spec post_recovery(erx_tcp_cc:ccv()) -> erx_tcp_cc:ccv().
post_recovery(Ccv) -> erx_tcp_cc:post_recovery(Ccv).

-doc "`newreno_after_idle`: the restart window, and Hystart++ may run again.".
-spec after_idle(erx_tcp_cc:ccv()) -> erx_tcp_cc:ccv().
after_idle(#ccv{data = Data} = Ccv) ->
    (erx_tcp_cc:after_idle(Ccv))#ccv{data = Data#newreno{hystart = erx_tcp_cc:hystart_idle(Data#newreno.hystart)}}.

-doc "`newreno_newround`, through erx_tcp_cc.".
-spec newround(erx_tcp_cc:ccv(), non_neg_integer()) -> erx_tcp_cc:ccv().
newround(#ccv{data = Data} = Ccv0, Round) ->
    {Ccv, Hystart} = erx_tcp_cc:hystart_newround(Ccv0, Round, Data#newreno.hystart),
    Ccv#ccv{data = Data#newreno{hystart = Hystart}}.

-doc "`newreno_rttsample`, through erx_tcp_cc.".
-spec rtt_sample(erx_tcp_cc:ccv(), erx_tcp_cc:rtt_sample()) -> erx_tcp_cc:ccv().
rtt_sample(#ccv{data = Data} = Ccv, Sample) ->
    Ccv#ccv{data = Data#newreno{hystart = erx_tcp_cc:hystart_rtt_sample(Sample, Data#newreno.hystart)}}.
