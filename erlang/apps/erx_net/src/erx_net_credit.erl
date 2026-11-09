%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_credit).
-moduledoc """
Credited hand-over between stack processes (docs/design-network-stack.md, "Credits" and
"Credited queues"): the one module that sends packet batches from one stack process to
another, over one `atomics` counter per receiver.

A sender adds the units of a message to the receiver's counter before it sends the
message, and refuses to send past the counter's limit; the receiver takes the units off as
it takes each message. The limit is part of the credit, fixed when the receiver made it,
so a sender never reads it from anywhere else, and the counter never goes below zero,
since every unit is added before its message is sent. What a receiver has waiting is
therefore never more than its limit, whoever sends.
""".

-export([new/1, hand/4, reserve/2, send/2, release/2, take/2, free/1]).

-export_type([credit/0]).

-doc "A receiver's counter of units in flight to it, and its limit.".
-opaque credit() :: {atomics:atomics_ref(), Limit :: pos_integer()}.

-doc "A credit of `Limit` units, none in flight.".
-spec new(pos_integer()) -> credit().
new(Limit) when is_integer(Limit), Limit > 0 ->
    {atomics:new(1, [{signed, true}]), Limit}.

-doc "Sends `Msg` to `Pid` when `Units` more fit under the credit's limit.".
-spec hand(pid(), credit(), pos_integer(), term()) -> ok | full.
hand(Pid, Credit, Units, Msg) ->
    case reserve(Credit, Units) of
        ok -> send(Pid, Msg);
        full -> full
    end.

-doc "Reserves `Units`, or answers `full` and reserves nothing.".
-spec reserve(credit(), pos_integer()) -> ok | full.
reserve({Ref, Limit}, Units) when is_integer(Units), Units > 0 ->
    case atomics:add_get(Ref, 1, Units) of
        InFlight when InFlight =< Limit ->
            ok;
        _ ->
            atomics:sub(Ref, 1, Units),
            full
    end.

-doc "Sends a message whose units the caller reserved.".
-spec send(pid(), term()) -> ok.
send(Pid, Msg) ->
    Pid ! Msg,
    ok.

-doc "Returns units the caller reserved and did not send.".
-spec release(credit(), pos_integer()) -> ok.
release({Ref, _Limit}, Units) when is_integer(Units), Units > 0 ->
    atomics:sub(Ref, 1, Units).

-doc "The receiver takes the units of a message, or of frames, it took.".
-spec take(credit(), non_neg_integer()) -> ok.
take(_Credit, 0) ->
    ok;
take({Ref, _Limit}, Units) when is_integer(Units), Units > 0 ->
    atomics:sub(Ref, 1, Units).

-doc "The room left under the limit.".
-spec free(credit()) -> non_neg_integer().
free({Ref, Limit}) ->
    max(0, Limit - atomics:get(Ref, 1)).
