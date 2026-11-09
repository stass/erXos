%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% What a BeamAsm domain of the native_domain suite runs (guest.c's jit_*
%% cases; docs/design-runtime.md, "BeamAsm", R4).
%%
%% run(reload): jit_probe is loaded ?ROUNDS times, its three versions in turn,
%% while one caller bound to each scheduler calls it without pause. A phase
%% counter orders the two: 2K once load K has returned, 2K+1 while load K+1
%% runs. A call that reads the same even phase before and after it ran wholly
%% after load K's code was published and before load K+1 began, so it must
%% answer load K's version; any other answer is stale code, counted. Each
%% load waits until every caller has made such a call, so every scheduler
%% runs every version. The old code is soft-purged before each load, so its
%% memory goes back to the code space and a later load may reuse it, which is
%% where a missing instruction barrier would show: the memory freed before load
%% K held load K-2, whose version differs from load K's with three versions. Ends with
%% {jit_reload_passed,jit,Schedulers} and halt(0), or {jit_reload_stale,Count} and
%% halt(1).
%%
%% run(write_rx), run(run_rw): a block of the code space runs through its
%% executable alias, which says jit_alias_runs, and then is written through
%% that alias, or run through its writable one, which faults and ends the
%% domain.
-module(jit_reload).
-export([run/1]).

-define(ROUNDS, 40).
-define(DIRECTORY, "/test/").

-spec run(reload | write_rx | run_rw) -> no_return().
run(reload) ->
    Binaries = {read(1), read(2), read(3)},
    {module, jit_probe} = erlang:load_module(jit_probe, element(1, Binaries)),
    Phase = atomics:new(1, []),
    ok = atomics:put(Phase, 1, 2),
    Schedulers = erlang:system_info(schedulers_online),
    Seen = atomics:new(Schedulers, []),
    Stale = atomics:new(1, []),
    Callers = [spawn_opt(fun() -> call(Phase, Seen, Index, Stale) end, [link, {scheduler, Index}])
               || Index <- lists:seq(1, Schedulers)],
    reload(2, Binaries, Phase, Seen, Schedulers),
    unlink_all(Callers),
    case atomics:get(Stale, 1) of
        0 ->
            erlang:display({jit_reload_passed, erlang:system_info(emu_flavor), Schedulers}),
            erlang:halt(0);
        Count ->
            erlang:display({jit_reload_stale, Count}),
            erlang:halt(1)
    end;
run(Alias) when Alias =:= write_rx; Alias =:= run_rw ->
    erts_debug:set_internal_state(available_internal_state, true),
    ok = erts_debug:set_internal_state(jit_alias, run_rx),
    erlang:display(jit_alias_runs),
    _ = erts_debug:set_internal_state(jit_alias, Alias),
    erlang:display(jit_alias_survived),
    erlang:halt(1).

read(Version) ->
    {ok, Binary} = erl_prim_loader:read_file(?DIRECTORY ++ "jit_probe_" ++ integer_to_list(Version) ++ ".beam"),
    Binary.

%% Load K's version: 1, 2, 3, 1, ...
version(K) -> (K - 1) rem 3 + 1.

reload(K, _Binaries, _Phase, _Seen, _Schedulers) when K > ?ROUNDS ->
    ok;
reload(K, Binaries, Phase, Seen, Schedulers) ->
    ok = atomics:put(Phase, 1, 2 * K - 1),
    purge(),
    {module, jit_probe} = erlang:load_module(jit_probe, element(version(K), Binaries)),
    ok = atomics:put(Phase, 1, 2 * K),
    seen_wait(Seen, Schedulers, 2 * K),
    K rem 10 =:= 0 andalso erlang:display({jit_reload_round, K}),
    reload(K + 1, Binaries, Phase, Seen, Schedulers).

%% A soft purge fails while a caller is inside the old code; it is out again at once.
purge() ->
    case erts_code_purger:soft_purge(jit_probe) of
        true ->
            ok;
        false ->
            erlang:yield(),
            purge()
    end.

seen_wait(Seen, Schedulers, Phase) ->
    case lists:all(fun(Index) -> atomics:get(Seen, Index) >= Phase end, lists:seq(1, Schedulers)) of
        true ->
            ok;
        false ->
            erlang:yield(),
            seen_wait(Seen, Schedulers, Phase)
    end.

call(Phase, Seen, Index, Stale) ->
    Before = atomics:get(Phase, 1),
    Version = jit_probe:version(),
    After = atomics:get(Phase, 1),
    check(Before, After, Version, {Seen, Index, Stale}),
    call(Phase, Seen, Index, Stale).

check(Phase, Phase, Version, {Seen, Index, Stale}) when Phase rem 2 =:= 0 ->
    case version(Phase div 2) of
        Version -> ok;
        _ -> atomics:add(Stale, 1, 1)
    end,
    atomics:put(Seen, Index, Phase);
check(_Before, _After, _Version, _Where) ->
    ok.

unlink_all(Callers) ->
    lists:foreach(fun(Caller) -> unlink(Caller), exit(Caller, kill) end, Callers).
