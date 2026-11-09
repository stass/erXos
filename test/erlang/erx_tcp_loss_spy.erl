%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_loss_spy).
-moduledoc """
A loss module for the tests: erx_tcp_loss_dupack, with the cause of every `rewind/4` recorded
in its state, newest first, so a test can see that a path moving `snd_nxt` back told the loss
module.
""".

-behaviour(erx_tcp_loss).

-export([init/1, ack/4, rewind/4, allowance/3, deadline/1, expired/3, causes/1]).

init(Params) -> {[], erx_tcp_loss_dupack:init(Params)}.

ack(Ack, Log0, {Causes, State0}, Now) ->
    {Verdict, Log, State, Events} = erx_tcp_loss_dupack:ack(Ack, Log0, State0, Now),
    {Verdict, Log, {Causes, State}, Events}.

rewind(Cause, Log0, {Causes, State0}, Now) ->
    {Log, State} = erx_tcp_loss_dupack:rewind(Cause, Log0, State0, Now),
    {Log, {[Cause | Causes], State}}.

allowance(Log, {_, State}, Ccv) -> erx_tcp_loss_dupack:allowance(Log, State, Ccv).

deadline({_, State}) -> erx_tcp_loss_dupack:deadline(State).

expired(Log0, {Causes, State0}, Now) ->
    {Log, State, Events} = erx_tcp_loss_dupack:expired(Log0, State0, Now),
    {Log, {Causes, State}, Events}.

-doc "The causes of the rewinds so far, newest first.".
causes({Causes, _}) -> Causes.
