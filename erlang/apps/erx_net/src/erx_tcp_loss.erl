%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_loss).
-moduledoc """
TCP loss detection's seam (docs/design-network-stack.md, "Loss detection and congestion
control"): the `erx_tcp_loss` behaviour, the loss-detection part of FreeBSD's
`struct tcp_function_block`, and the closed table of the modules a socket may choose.

A loss module reads and marks the send log (erx_tcp_sendlog) and decides what an
acknowledgement means: whether it is a duplicate, when recovery begins, and how much may be
sent during it. It never calls the congestion module; it returns the calls the connection
makes, in order, as events:

* `{cong_signal, Signal}`: `erx_tcp_cc`'s `cong_signal/3` (FreeBSD's `cc_cong_signal`),
* `{ack_received, dupack}`: `ack_received/3` with `CC_DUPACK`,
* `stop_rexmt`: stop the retransmission timer and the RTT measurement
  (`tcp_timer_activate(tp, TT_REXMT, 0)`, `t_rtttime = 0`),
* `ack_now`: send an acknowledgement now (`TF_ACKNOW`),
* `resume_at_max`: `snd_nxt = snd_max`.

`ack/4` also returns FreeBSD's control flow: `drop` where `tcp_do_segment` goes to `drop`
after processing a duplicate acknowledgement or entering recovery, so the rest of the
segment's processing is skipped, and `continue` otherwise. The log is the one authority for
`snd_una`: `ack/4` has applied the cumulative acknowledgement to it, and the connection's
`snd_una` and send buffer follow the log after `drop` as after `continue`. Where an
advancing acknowledgement enters recovery, FreeBSD's `goto drop` leaves `snd_una` behind
until the next acknowledgement; here it advances at once.

During recovery and limited transmit the loss module, not the congestion module, sets the
window, as `tcp_input.c` sets `snd_cwnd` around its calls to `tcp_output`. The connection
calls `allowance/3` once after each `ack/4`, after applying its events: `none` leaves the
window alone; `{Send, Keep}` means this step's output runs with `snd_cwnd` `Send`, measured
against the log's pipe, and the connection keeps `Keep` in `#ccv.cwnd` afterwards.
""".

-include("erx_tcp_loss.hrl").

-export([module/1]).
-export_type([ack/0, params/0, event/0, verdict/0, allowance/0]).

-doc "An acknowledgement and the control block fields a loss module reads (erx_tcp_loss.hrl).".
-type ack() :: #loss_ack{}.
-doc "A module's settings: whether the connection negotiated SACK (`TF_SACK_PERMIT`).".
-type params() :: #{sack := boolean()}.
-doc "A call the connection makes for the loss module, in the order returned.".
-type event() :: {cong_signal, erx_tcp_cc:signal()} | {ack_received, dupack} | stop_rexmt
               | ack_now | resume_at_max.
-doc "Whether the rest of the segment is processed (`continue`) or skipped (`drop`).".
-type verdict() :: continue | drop.
-doc "The window for this step's output and the one kept after it, or `none`.".
-type allowance() :: none | {Send :: non_neg_integer(), Keep :: non_neg_integer()}.

-callback init(params()) -> State :: term().
%% An acknowledgement arrived: mark ranges SACKed or lost, enter or leave recovery, and
%% return the calls the connection makes.
-callback ack(ack(), erx_tcp_sendlog:log(), State, Now :: integer()) ->
    {verdict(), erx_tcp_sendlog:log(), State, [event()]} when State :: term().
%% The retransmission timer expired; #ccv.rxtshift is already incremented.
-callback rto(erx_tcp_sendlog:log(), State, erx_tcp_cc:ccv(), Now :: integer()) ->
    {erx_tcp_sendlog:log(), State} when State :: term().
%% The window for the output that follows the last acknowledgement.
-callback allowance(erx_tcp_sendlog:log(), State :: term(), erx_tcp_cc:ccv()) -> allowance().
%% The module's own deadline, such as RACK's reordering timer.
-callback deadline(State :: term()) -> integer() | infinity.
-callback expired(erx_tcp_sendlog:log(), State, Now :: integer()) ->
    {erx_tcp_sendlog:log(), State, [event()]} when State :: term().

-doc """
The loss module a socket names with `{loss, Name}`, FreeBSD's `TCP_FUNCTION_BLK`. Names are
binaries looked up in this fixed table, so no client name becomes an atom.
""".
-spec module(binary()) -> {ok, module()} | {error, unknown}.
module(<<"dupack">>) -> {ok, erx_tcp_loss_dupack};
module(Name) when is_binary(Name) -> {error, unknown}.
