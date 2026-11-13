%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A recording stand-in for the device NIF's register calls, for host tests of the effect
%% functions over it (test/erlang/erx_blk_sd_issue_tests.erl): every read, write and command
%% the calling process makes is recorded with its monotonic time in microseconds, and each
%% read answers from a script the test sets, the last value of a register's script repeating.
%% Everything lives in the calling process's dictionary, so tests do not share state.

-module(erx_device).

-export([open/1, read/2, write/3, read_field/3, write_field/4, command/2]).
-export([script/1, calls/0]).

%% Sets the reads' answers, Register => [Value, ...], and clears the record.
script(Reads) ->
    put(erx_device_reads, Reads),
    put(erx_device_calls, []),
    ok.

%% The calls made since script/1, oldest first: {Us, {read, R}}, {Us, {write, R, V}},
%% {Us, {write_field, R, F, V}} and {Us, {command, Word}}.
calls() ->
    lists:reverse(get(erx_device_calls)).

%% Any record opens, as the device the script answers for.
open(_Spec) -> {ok, dev}.

read(_Dev, Register) ->
    record({read, Register}),
    answer(Register).

read_field(_Dev, Register, Field) ->
    record({read_field, Register, Field}),
    answer({Register, Field}).

write(_Dev, Register, Value) ->
    record({write, Register, Value}).

write_field(_Dev, Register, Field, Value) ->
    record({write_field, Register, Field, Value}).

command(_Dev, Word) ->
    record({command, Word}).

record(Call) ->
    put(erx_device_calls, [{erlang:monotonic_time(microsecond), Call} | get(erx_device_calls)]),
    ok.

answer(Key) ->
    Reads = get(erx_device_reads),
    case maps:get(Key, Reads, [0]) of
        [Last] ->
            Last;
        [Value | Rest] ->
            put(erx_device_reads, Reads#{Key => Rest}),
            Value
    end.
