%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stand-in for the interrupt line's attach and acknowledge, for host tests of the SD
%% device process's start over the recording stand-in for the device NIF
%% (test/erlang/erx_blk_sd_start_tests.erl): the attach always succeeds and no interrupt
%% is ever delivered.

-module(erx_irq_line).

-export([attach/2, ack/1]).

attach(_Dev, Line) -> {ok, {line, Line}}.

ack(_Handle) -> ok.
