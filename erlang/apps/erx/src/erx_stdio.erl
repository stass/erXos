%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Hosted mode's console driver (docs/design-runtime.md, "The console and standard I/O"):
%% the process's own standard input and output, over erx_stdio_nif. It speaks the
%% driver's messages that erx_console documents. Input arrives as a software IRQ through
%% the event table, the path a device's interrupt takes, so nothing polls in a scheduler.
%% Natively this module is present and never started.
%%
%% The driver keeps one input message outstanding (docs/design-live.md, "One input message
%% outstanding per driver"): standard input can wait, so after sending bytes it reads no
%% more until the console's erx_console_taken, holding a readiness that came meanwhile, and
%% it serves output while it waits.

-module(erx_stdio).

-export([start_link/1, console_records/0]).
-export([init/1]).

-nifs([start_nif/0, take_nif/0, write_nif/1]).

%% The terminal of a hosted runtime is no device, so it has no record.
-spec console_records() -> [].
console_records() ->
    [].

-spec start_link(Console :: pid()) -> {ok, pid(), Terminal :: boolean()}.
start_link(Console) ->
    proc_lib:start_link(?MODULE, init, [Console]).

-spec init(pid()) -> no_return().
init(Console) ->
    ok = erlang:load_nif(atom_to_list(?MODULE), #{}),
    {ok, Terminal} = start_nif(),
    proc_lib:init_ack({ok, self(), Terminal}),
    loop(Console, idle).

%% Input is `idle`, `waiting` for the answer to the bytes last sent, or `ready` once
%% standard input became readable while it waited.
loop(Console, Input) ->
    receive
        erx_stdio_ready when Input =:= idle ->
            loop(Console, deliver(take_nif(), Console));
        erx_stdio_ready ->
            loop(Console, ready);
        erx_console_taken when Input =:= ready ->
            loop(Console, deliver(take_nif(), Console));
        erx_console_taken ->
            loop(Console, idle);
        {erx_console_output, From, Bytes} ->
            %% A write that fails has no reader to tell, as on a hung-up Unix terminal:
            %% the bytes go, and no writer waits on a line that is gone.
            _ = write_nif(Bytes),
            Console ! {erx_console_written, From},
            loop(Console, Input);
        _Other ->
            loop(Console, Input)
    end.

%% In the order they happened: the size may have changed at any time, and the end of
%% input comes after every byte read before it. The input then waits for its answer if
%% bytes were sent.
deliver({Bytes, Size, End}, Console) ->
    size_changed(Size, Console),
    [Console ! {erx_console_input, Bytes} || Bytes =/= <<>>],
    input_ended(End, Console),
    case Bytes of
        <<>> -> idle;
        _ -> waiting
    end.

size_changed(unchanged, _Console) -> ok;
size_changed({Rows, Columns}, Console) -> Console ! {erx_console_size, Rows, Columns}.

input_ended(none, _Console) ->
    ok;
input_ended(eof, Console) ->
    Console ! erx_console_eof;
input_ended({error, Reason}, _Console) ->
    erlang:display_string(stderr, "erx_stdio: reading standard input: " ++
                               atom_to_list(Reason) ++ "\r\n"),
    erlang:halt(1).

start_nif() ->
    erlang:nif_error(undef).
take_nif() ->
    erlang:nif_error(undef).
write_nif(_Bytes) ->
    erlang:nif_error(undef).
