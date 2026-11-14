%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_fakes).
-moduledoc """
The answers of the stand-ins for the modules erx_prog_handler acts
through, in its tests (test/erlang/stand_in/): the program driver
(erx_program's start/1, send/2, install/2, stop/3) and the pixel
allocator (erx_pixels' alloc/2, lend/2, unlend/1). Every call is sent to
the test process as `{fake, Call}`; start/1 answers a real port of the
handler's that runs a shell command, `read x` (which ends when the port
closes) or the `Shell` of a `start` the test set to `{program, Shell}`,
and writes its exit status and closes as the driver's port does at a
program's end; or the error the test set. send/2, install/2 and stop/3
on a closed port raise `badarg`, as `port_control/3` does; send/2 answers each
of the answers the test queued, then `ok`; install/2 fills each `{hand, I}` with
`100 * I`, or answers the error the test set; alloc/2 fails with `undef`,
as a call of a module the release lacks does, when the test set
`pixels` to `absent`.
""".

-export([setup/1, set/2, start/1, send/2, install/2, stop/3, alloc/2, lend/2, unlend/1]).

-doc "Sends every later call to Pid, with the default answers.".
setup(Pid) ->
    persistent_term:put(?MODULE, #{test => Pid, start => port, sends => [], install => ok, pixels => present}).

-doc "Sets one answer: `start`, `sends` (a list), `install` or `pixels`.".
set(Key, Value) ->
    persistent_term:put(?MODULE, (persistent_term:get(?MODULE))#{Key => Value}).

start(Spec) ->
    Answer = case conf(start) of
                 port -> program_port("read x");
                 {program, Shell} -> program_port(Shell);
                 Error -> Error
             end,
    tell({start, Spec, Answer}),
    Answer.

send(Port, Frame) ->
    tell({send, Port, Frame}),
    open(Port),
    case conf(sends) of
        [Answer | Rest] -> set(sends, Rest), Answer;
        [] -> ok
    end.

install(Port, {pipe_hand, Number, Term}) ->
    tell({install, Port, Number}),
    open(Port),
    case conf(install) of
        ok -> {ok, fill(Term)};
        Error -> Error
    end.

stop(Port, anchor, Status) ->
    tell({stop, Port, Status}),
    open(Port),
    ok.

alloc(Peer, Bytes) ->
    tell({alloc, Peer, Bytes}),
    case conf(pixels) of
        present -> {ok, 4096};
        absent -> erlang:error(undef, [Peer, Bytes])
    end.

lend(Peer, Offset) ->
    tell({lend, Peer, Offset}),
    {ok, 77, 2}.

unlend(Lease) ->
    tell({unlend, Lease}),
    ok.

fill({hand, I}) -> 100 * I;
fill(T) when is_tuple(T) -> list_to_tuple(fill(tuple_to_list(T)));
fill(L) when is_list(L) -> [fill(E) || E <- L];
fill(M) when is_map(M) -> maps:map(fun(_, V) -> fill(V) end, M);
fill(X) -> X.

conf(Key) -> maps:get(Key, persistent_term:get(?MODULE)).

%% A port of the handler's that runs Shell and reports its exit status.
program_port(Shell) ->
    open_port({spawn_executable, "/bin/sh"}, [exit_status, {args, ["-c", Shell]}]).

%% port_control/3's refusal of a port that is closed.
open(Port) when is_port(Port) ->
    erlang:port_info(Port) =:= undefined andalso erlang:error(badarg, [Port]),
    ok;
open(_Port) ->
    ok.

tell(Call) -> conf(test) ! {fake, Call}.
