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

-module(erx_tcp_output).
-moduledoc """
A connection's output (docs/design-network-stack.md, "Output"): what to send and when,
translated from `tcp_default_output` and `tcp_setpersist` (sys/netinet/tcp_output.c) at
the commit NOTICE-freebsd records. erx_tcp:step/3 calls `output/2` once after every event,
as FreeBSD calls `tcp_output` at the end of each input, timer and user request.
""".

-include("erx_tcp.hrl").

-export([output/2, setpersist/2]).

-doc """
The segments the connection sends now, at most the context's credit, and the control
block after sending them. It reads the requests the step left (`ack_now`, `force_data`)
and clears them, sends the RST of a dropped connection in CLOSED (`tcp_outflags`), and arms
the retransmission timer when it sends what must be acknowledged.

The segment decisions of `tcp_default_output` (sending data, the SYN and the FIN, window
updates, Nagle, silly-window avoidance, probes, options, what the loss module retransmits,
the credit-limited ENOBUFS rule) are not translated here, so it sends nothing and leaves
the requests set.
""".
-spec output(#tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:outgoing()]}.
output(Tcb, #tcp_ctx{}) ->
    {Tcb, []}.

-doc """
`tcp_setpersist`: arms the persist timer for its next probe, backed off by the timeouts so
far (erx_tcp_rtt:persist/2), and counts one more up to `tcp_retries`. Arming persist
replaces the retransmission timer, which FreeBSD asserts is not armed, and forgets the
first timeout's snapshot (TF_PREVVALID).
""".
-spec setpersist(#tcb{}, #tcp_ctx{}) -> #tcb{}.
setpersist(#tcb{rtt = Rtt} = Tcb, #tcp_ctx{now = Now}) ->
    Shift = erx_tcp:rxtshift(Tcb),
    Timeout = erx_tcp_rtt:persist(Rtt, Shift),
    Tcb#tcb{send_timer = {persist, Now + Timeout * 1000, min(Shift + 1, 12)}, rexmt_prev = none}.
