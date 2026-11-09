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
runs through `stages/0` in order; a stage returns `{continue, Tcb, Segment}` to pass the
segment on, possibly changed (lifted into the connection's sequence space, trimmed to the
window), or `{done, Tcb, Actions}` where `tcp_do_segment` finishes with it: at its `drop`,
`dropafterack` and `dropwithreset` exits, or after the last stage. A segment that passes
every stage has been fully processed and has nothing more to say.

The stages, in the order `tcp_do_segment` takes them, since the order is visible on the
wire, are `lift`, `timestamps`, header prediction, `syn_sent`, `check_rst`, `check_syn`,
`paws`, `trim`, `check_ack`, `ack`, `urgent`, `data` and `fin`; `stages/0` lists the ones
this module has.

The segments of one event are processed in order. Once one ends the connection, the rest
are for a connection that no longer exists, so each goes back to the interface in a
`reinject` action to be demultiplexed again, as FreeBSD looks each segment up anew.
""".

-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-export([segments/3, stages/0]).

-export_type([stage/0, result/0]).

-doc "What a stage returns (see the module documentation).".
-type result() :: {continue, #tcb{}, Segment :: term()} | {done, #tcb{}, [erx_tcp:action()]}.

-doc """
A stage: the segment as the previous stage passed it on (a decoded header and payload
before `lift`), the control block and the context.
""".
-type stage() :: fun((Segment :: term(), #tcb{}, #tcp_ctx{}) -> result()).

-doc "Runs each segment through the stages, in order (see the module documentation).".
-spec segments([{#tcp{}, binary()}], #tcb{}, #tcp_ctx{}) -> {#tcb{}, [erx_tcp:action()]}.
segments(Segments, Tcb, Ctx) ->
    segments(Segments, Tcb, Ctx, stages(), []).

segments([], Tcb, _, _, Actions) ->
    {Tcb, Actions};
segments(Rest, #tcb{ended = true} = Tcb, _, _, Actions) ->
    {Tcb, Actions ++ [{reinject, Segment} || Segment <- Rest]};
segments([Segment | Rest], Tcb0, Ctx, Stages, Actions) ->
    {Tcb, More} = pipeline(Stages, Segment, Tcb0, Ctx),
    segments(Rest, Tcb, Ctx, Stages, Actions ++ More).

pipeline([], _, Tcb, _) ->
    {Tcb, []};
pipeline([Stage | Rest], Segment0, Tcb0, Ctx) ->
    case Stage(Segment0, Tcb0, Ctx) of
        {continue, Tcb, Segment} -> pipeline(Rest, Segment, Tcb, Ctx);
        {done, Tcb, Actions} -> {Tcb, Actions}
    end.

-doc "The stages, in `tcp_do_segment`'s order.".
-spec stages() -> [stage()].
stages() -> [].
