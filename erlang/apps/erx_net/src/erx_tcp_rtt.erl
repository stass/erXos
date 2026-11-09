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
%%
%% FreeBSD: sys/netinet/tcp_var.h
%% Copyright (c) 1982, 1986, 1993, 1994, 1995
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

-module(erx_tcp_rtt).
-moduledoc """
The round-trip time estimator and retransmission timeout of a connection
(docs/design-network-stack.md, "Events and the step" stage `ack`, and "Timers"), translated
from `tcp_xmit_timer` (sys/netinet/tcp_input.c), the timeout computation of
`tcp_timer_rexmt` (sys/netinet/tcp_timer.c) and `TCP_REXMTVAL` (sys/netinet/tcp_var.h) at the
commit NOTICE-freebsd records.

It keeps FreeBSD's fixed-point state: the smoothed RTT scaled by 32 and its smoothed mean
deviation scaled by 16, which together follow RFC 6298's estimator (alpha 1/8, beta 1/4,
RTO = SRTT + 4 * RTTVAR) with the half-tick biases FreeBSD's comments describe. Times are in
ticks of one millisecond, FreeBSD's default `hz` of 1000; the connection measures RTT samples
from the monotonic clock or the timestamp echo and passes them in. The retransmission
backoff count (`t_rxtshift`) belongs to the connection's timers, which persist and
retransmission share, so it is an argument here, not state.
""".

-export([new/0, sample/3, backoff/3, rto/1, rexmtval/1, srtt/1]).

-export_type([rtt/0]).

%% tcp_var.h: srtt has 5 fraction bits, rttvar 4; deltas are computed with 2.
-define(TCP_RTT_SHIFT, 5).
-define(TCP_RTTVAR_SHIFT, 4).
-define(TCP_DELTA_SHIFT, 2).
%% tcp_timer.h, in milliseconds: the RTO before any sample, the least and greatest RTO, and
%% the backoff count past which an old estimate is no longer trusted (TCP_MAXRXTSHIFT / 4).
-define(TCPTV_RTOBASE, 1000).
-define(TCPTV_SRTTBASE, 0).
-define(TCPTV_MIN, 30).
-define(TCPTV_REXMTMAX, 64000).
-define(TCP_RTT_INVALIDATE, 3).
%% tcp_subr.c: tcp_rexmit_slop = TCPTV_CPU_VAR, the 200 ms TCPT_RANGESET adds to every RTO
%% it sets, so a timeout never undercuts a peer's delayed ACK.
-define(TCPTV_CPU_VAR, 200).
%% tcp_timer.c: tcp_backoff, indexed by the backoff count 0..TCP_MAXRXTSHIFT (12).
-define(TCP_BACKOFF, {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 512, 512, 512}).

-record(rtt, {srtt :: non_neg_integer(),   % t_srtt, ticks * 32; 0 until the first sample
              rttvar :: non_neg_integer(), % t_rttvar, ticks * 16
              rttmin :: pos_integer(),     % t_rttmin, the least RTO
              rxtcur :: pos_integer()}).   % t_rxtcur, the current RTO

-opaque rtt() :: #rtt{}.

-doc """
A new connection's estimator, as `tcp_newtcpcb` (tcp_subr.c) starts it: no smoothed RTT, a
deviation that makes the first RTO `tcp_rexmit_initial` (1 s), and FreeBSD's defaults for the
least RTO (`tcp_rexmit_min`, 30 ms).
""".
-spec new() -> rtt().
new() ->
    #rtt{srtt = ?TCPTV_SRTTBASE,
         rttvar = ((?TCPTV_RTOBASE - ?TCPTV_SRTTBASE) bsl ?TCP_RTTVAR_SHIFT) div 4,
         rttmin = ?TCPTV_MIN,
         rxtcur = ?TCPTV_RTOBASE}.

-doc """
Takes one RTT sample of `Ticks` milliseconds (`tcp_xmit_timer`). The first sample, or one
taken after more than `TCP_RTT_INVALIDATE` backoffs (`Rxtshift`, the connection's backoff
count before the acknowledgement), sets the estimate outright with a deviation of half the
sample; later samples smooth into it. The RTO becomes `TCP_REXMTVAL`, held between the least
RTO (at least the sample plus two ticks) and 64 s after `TCPT_RANGESET` adds its 200 ms. The caller resets its backoff count to 0,
as `tcp_xmit_timer` does.
""".
-spec sample(rtt(), non_neg_integer(), non_neg_integer()) -> rtt().
sample(#rtt{srtt = Srtt0, rttvar = Rttvar0, rttmin = Rttmin} = Rtt, Ticks, Rxtshift)
  when is_integer(Ticks), Ticks >= 0, is_integer(Rxtshift), Rxtshift >= 0 ->
    {Srtt, Rttvar} =
        case Srtt0 =/= 0 andalso Rxtshift =< ?TCP_RTT_INVALIDATE of
            true ->
                %% srtt = rtt/8 + srtt*7/8 in fixed point, with rtt taken from origin 0.
                Delta = ((Ticks - 1) bsl ?TCP_DELTA_SHIFT)
                    - (Srtt0 bsr (?TCP_RTT_SHIFT - ?TCP_DELTA_SHIFT)),
                %% rttvar = rttvar*3/4 + |delta|/4.
                VarDelta = abs(Delta) - (Rttvar0 bsr (?TCP_RTTVAR_SHIFT - ?TCP_DELTA_SHIFT)),
                {at_least_one(Srtt0 + Delta), at_least_one(Rttvar0 + VarDelta)};
            false ->
                {Ticks bsl ?TCP_RTT_SHIFT, Ticks bsl (?TCP_RTTVAR_SHIFT - 1)}
        end,
    Next = Rtt#rtt{srtt = Srtt, rttvar = Rttvar},
    Next#rtt{rxtcur = rangeset(rexmtval(Next), max(Rttmin, Ticks + 2), ?TCPTV_REXMTMAX)}.

-doc """
The RTO after the retransmission timer fires for the `Rxtshift`th time, 1 to 12 (the
timeout computation of `tcp_timer_rexmt`): during the handshake the initial RTO, otherwise
`TCP_REXMTVAL`, times `tcp_backoff[Rxtshift]`, plus 200 ms, held between the least RTO and
64 s. The
retry limit and what is retransmitted are the timer's decisions.
""".
-spec backoff(rtt(), handshake | synchronized, 1..12) -> rtt().
backoff(#rtt{rttmin = Rttmin} = Rtt, Phase, Rxtshift)
  when is_integer(Rxtshift), Rxtshift >= 1, Rxtshift =< 12 ->
    Base = case Phase of
               handshake -> ?TCPTV_RTOBASE;
               synchronized -> rexmtval(Rtt)
           end,
    Rexmt = Base * element(Rxtshift + 1, ?TCP_BACKOFF),
    Rtt#rtt{rxtcur = rangeset(Rexmt, Rttmin, ?TCPTV_REXMTMAX)}.

-doc "The current retransmission timeout in milliseconds (`t_rxtcur`).".
-spec rto(rtt()) -> pos_integer().
rto(#rtt{rxtcur = Rxtcur}) -> Rxtcur.

-doc """
`TCP_REXMTVAL`: the smoothed RTT plus four deviations, in milliseconds, and at least the
least RTO; the base the timers back off from.
""".
-spec rexmtval(rtt()) -> pos_integer().
rexmtval(#rtt{srtt = Srtt, rttvar = Rttvar, rttmin = Rttmin}) ->
    max(Rttmin, ((Srtt bsr (?TCP_RTT_SHIFT - ?TCP_DELTA_SHIFT)) + Rttvar) bsr ?TCP_DELTA_SHIFT).

-doc """
The smoothed RTT as FreeBSD keeps `t_srtt`, in milliseconds scaled by 32, 0 before the first
sample; what the loss and congestion modules read where FreeBSD reads `t_srtt`.
""".
-spec srtt(rtt()) -> non_neg_integer().
srtt(#rtt{srtt = Srtt}) -> Srtt.

%% TCPT_RANGESET (tcp_timer.h): Value plus tcp_rexmit_slop, raised to Min and then lowered to
%% Max, so the result never exceeds Max even when Min does.
rangeset(Value, Min, Max) ->
    min(max(Value + ?TCPTV_CPU_VAR, Min), Max).

at_least_one(Value) when Value =< 0 -> 1;
at_least_one(Value) -> Value.
