%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for the interrupt line's attach and acknowledge, for host tests of the SD
%% device process's start over the recording stand-in for the device NIF
%% (test/erlang/erx_blk_sd_start_tests.erl): the attach always succeeds and no interrupt
%% is ever delivered. On a device the test process plays (erx_device's stand-in), as the UART
%% drivers' tests do, each
%% acknowledgement is a call {ack, Line} the player answers, and the player delivers the
%% interrupts itself.

-module(erx_irq_line).

-export([attach/2, ack/1]).

attach({stand_in, Player}, Line) -> {ok, {stand_in, Player, Line}};
attach(_Dev, Line) -> {ok, {line, Line}}.

ack({stand_in, Player, Line}) -> erx_device:play(Player, {ack, Line});
ack(_Handle) -> ok.
