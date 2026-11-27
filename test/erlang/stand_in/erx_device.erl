%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A recording stand-in for the device NIF's register calls, for host tests of the effect
%% functions over it (test/erlang/erx_blk_sd_issue_tests.erl): every read, write and command
%% the calling process makes is recorded with its monotonic time in microseconds, and each
%% read answers from a script the test sets, the last value of a register's script repeating.
%% Everything lives in the calling process's dictionary, so tests do not share state.
%%
%% A device the test process plays instead, for host tests of a process that calls the NIF
%% from its own process (test/erlang/erx_xhci_tests.erl, test/erlang/erx_mini_uart_tests.erl,
%% test/erlang/erx_pl011_tests.erl):
%% open(#{stand_in => Player}) answers {stand_in, Player}, and every call on that device, the TRB ring form's post/4,
%% complete/2, negotiate/2 and queue_state/2 among them, is sent to Player as
%% {erx_device, Caller, Call}, the call returning the Answer Player sends back as
%% {erx_device, Answer}; queue_create/4 among them, as the block driver's tests
%% (test/erlang/erx_blk_virtio_tests.erl) play a virtio-blk device. queue_state/2 is the shape the controller process assumes until
%% the NIF states its own.

-module(erx_device).

-export([open/1, read/2, write/3, read_field/3, write_field/4, field/4, command/2]).
-export([elements/2, negotiate/2, queue_create/4, post/4, complete/2, queue_state/2]).
-export([script/1, calls/0, play/2]).

%% Sets the reads' answers, Register => [Value, ...], and clears the record.
script(Reads) ->
    put(erx_device_reads, Reads),
    put(erx_device_calls, []),
    ok.

%% The calls made since script/1, oldest first: {Us, {read, R}}, {Us, {write, R, V}},
%% {Us, {write_field, R, F, V}} and {Us, {command, Word}}.
calls() ->
    lists:reverse(get(erx_device_calls)).

%% A played record opens as its player's device; any other, as the device the script
%% answers for.
open(#{stand_in := Player}) -> {ok, {stand_in, Player}};
open(_Spec) -> {ok, dev}.

elements({stand_in, Player}, Register) -> play(Player, {elements, Register}).
negotiate({stand_in, Player}, Wanted) when is_integer(Wanted); Wanted =:= continue ->
    play(Player, {negotiate, Wanted}).
queue_create({stand_in, Player}, Queue, Size, BufferSize) -> play(Player, {queue_create, Queue, Size, BufferSize}).
post({stand_in, Player}, Queue, Tag, Item) -> play(Player, {post, Queue, Tag, Item}).
complete({stand_in, Player}, Ring) -> play(Player, {complete, Ring}).
queue_state({stand_in, Player}, Queue) -> play(Player, {queue_state, Queue}).

%% Sends Call to Player and answers what Player answers.
play(Player, Call) ->
    Player ! {erx_device, self(), Call},
    receive {erx_device, Answer} -> Answer end.

read({stand_in, Player}, Register) ->
    play(Player, {read, Register});
read(_Dev, Register) ->
    record({read, Register}),
    answer(Register).

read_field({stand_in, Player}, Register, Field) ->
    play(Player, {read_field, Register, Field});
read_field(_Dev, Register, Field) ->
    record({read_field, Register, Field}),
    answer({Register, Field}).

write({stand_in, Player}, Register, Value) ->
    play(Player, {write, Register, Value});
write(_Dev, Register, Value) ->
    record({write, Register, Value}).

write_field({stand_in, Player}, Register, Field, Value) ->
    play(Player, {write_field, Register, Field, Value});
write_field(_Dev, Register, Field, Value) ->
    record({write_field, Register, Field, Value}).

%% Only on a played device: the player decodes the word, from the register's generated header.
field({stand_in, Player}, Register, Field, Word) ->
    play(Player, {field, Register, Field, Word}).

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
