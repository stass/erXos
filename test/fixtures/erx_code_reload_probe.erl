%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Reloads one module in a loop through the code service while a caller on each of four
%% schedulers calls it, and counts every call that ran code older than the last load that
%% had returned when the call began (docs/plan.md, M4's exit criteria: "a module reloaded
%% in a loop on four CPUs never runs stale code").
%%
%% Each version of erx_code_reload_target returns its number from version/0. The loader
%% sends each version's blob to erx_code, loads it by hash and, once load/1 returns, writes
%% the version's number into an atomic. A caller reads the atomic, then calls version/0 by
%% its remote name; a call that returns less than the number it read ran stale code. The
%% callers make thousands of calls per load, so each load lands among calls on every
%% scheduler. Purging old code ends a caller still inside a version two loads old, as stock
%% does; the answer counts the callers that ran to the end.

-module(erx_code_reload_probe).
-export([run/1]).

-define(TARGET, erx_code_reload_target).
-define(CALLERS, 4).

run(Loads) ->
    Schedulers = erlang:system_info(schedulers_online),
    Blobs = [beam(Version) || Version <- lists:seq(0, Loads)],
    [ok = send(Blob) || Blob <- Blobs],
    ok = load(hd(Blobs)),
    Published = atomics:new(1, []),
    Stale = atomics:new(1, []),
    Stop = atomics:new(1, []),
    Callers = [spawn_opt(fun() -> call_loop(Published, Stale, Stop, 0) end,
                         [monitor, {scheduler, Scheduler}])
               || Scheduler <- lists:seq(1, ?CALLERS)],
    [begin ok = load(Blob), atomics:put(Published, 1, Version) end
     || {Version, Blob} <- tl(lists:enumerate(0, Blobs))],
    atomics:put(Stop, 1, 1),
    Ends = [receive {'DOWN', Ref, process, Pid, End} -> End end || {Pid, Ref} <- Callers],
    Calls = [N || {calls, N} <- Ends],
    {reload, Schedulers, Loads, atomics:get(Stale, 1), length(Calls), lists:all(fun(N) -> N > Loads end, Calls),
     ?TARGET:version()}.

call_loop(Published, Stale, Stop, Calls) ->
    case atomics:get(Stop, 1) of
        0 ->
            Loaded = atomics:get(Published, 1),
            case ?TARGET:version() < Loaded of
                true -> atomics:add(Stale, 1, 1);
                false -> ok
            end,
            call_loop(Published, Stale, Stop, Calls + 1);
        _ ->
            exit({calls, Calls})
    end.

beam(Version) ->
    Forms = [{attribute, 1, module, ?TARGET},
             {attribute, 2, export, [{version, 0}]},
             {function, 3, version, 0, [{clause, 3, [], [], [{integer, 3, Version}]}]}],
    {ok, ?TARGET, Bytes} = compile:forms(Forms, [binary]),
    Bytes.

%% A target's blob is far below one 64 KiB piece.
send(Bytes) ->
    {ok, stored} = erx_code:put_piece(erx_bytes:sha256(Bytes), byte_size(Bytes), 0, Bytes),
    ok.

load(Bytes) ->
    erx_code:load([{atom_to_binary(?TARGET), erx_bytes:sha256(Bytes)}]).
