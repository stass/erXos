%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_reload_probe).

-moduledoc """
The guest's half of the reload check (docs/plan.md, M4: "a module reloaded in a loop on four
CPUs never runs stale code"; tools/lib/erx/reload_guest.rb is the host's half). The host
installs it with the first version of `erx_reload_subject` through the install facet, then
loads `?LOADS` more versions one at a time; version G's `tag/0` returns G.

Stale means what stock OTP's code loading promises: once a load has returned, every
fully qualified call made after it runs the new code. So a call that starts after load G
was committed must return G or a later tag, never an earlier one. The purge of a version
comes one load after it stopped being current, so this also holds after every purge.

Each worker checks two bounds, read before its call:

* **Stale**: the tag is below the count of committed loads. When a load was committed is
  learnt independently of the loader under test: an observer polls `erx_code:history/2`,
  whose reply the code service sends only after `activate/1` returned and the load was
  entered in the history, and publishes the count of loads it has seen in an atomics cell.
  The observer lags the commit by a poll and a call, so this bound is sound but late.
* **Behind**: the tag is below the newest tag any worker has already returned. ERTS makes a
  load current with one store of the active code index, and atomics are full barriers, so
  once one CPU has run version G no call started later on any CPU may run an older one.
  This bound closes the observer's lag to the time between two calls.

Counts live in atomics, so a worker that a purge ends, as stock OTP ends a process still
running old code, loses none; the probe starts another on its scheduler. A worker that
finds itself on another scheduler than the one it was bound to fails the run.

The probe reports on the debug log, which the console shows: a `ready` line once its
workers run, naming the number of loads it waits for, a `done` line once the observer has
seen them all, and a `failed` line if anything of the probe crashes.
""".

-export([run/0]).

-define(SUBJECT, erx_reload_subject).
-define(SYSTEM_DOMAIN, 4).
%% The reloads after the first version; the host reads the number from the ready line.
-define(LOADS, 32).
%% The observer's poll interval and the time the workers go on after the last load, in ms.
-define(POLL_MS, 1).
-define(SETTLE_MS, 200).

%% Cells of the shared atomics: the committed count and the newest tag returned, then per
%% scheduler S its calls, stale calls, calls behind the newest tag, calls that straddled a
%% change of the count, and the purge kills.
-define(COMMITTED, 1).
-define(NEWEST, 2).
-define(SHARED_CELLS, 2).
-define(CELLS_PER_WORKER, 5).
-define(CALLS, 0).
-define(STALE, 1).
-define(BEHIND, 2).
-define(STRADDLED, 3).
-define(KILLED, 4).

-doc "Runs the check and reports it; returns once the `done` or `failed` line is written.".
-spec run() -> ok.
run() ->
    try
        check()
    catch
        Class:Reason ->
            report("failed ~0p:~0P", [Class, Reason, 12])
    end.

check() ->
    process_flag(trap_exit, true),
    Schedulers = erlang:system_info(schedulers_online),
    Counts = atomics:new(?SHARED_CELLS + Schedulers * ?CELLS_PER_WORKER, [{signed, false}]),
    %% Which tags each worker saw: one cell per scheduler and tag.
    Seen = atomics:new(Schedulers * (?LOADS + 1), [{signed, false}]),
    {Head, Committed} = initial_history(),
    atomics:put(Counts, ?COMMITTED, Committed),
    atomics:put(Counts, ?NEWEST, Committed),
    Workers = maps:from_list([start_worker(S, Counts, Seen) || S <- lists:seq(1, Schedulers)]),
    report("ready schedulers ~b loads ~b", [Schedulers, ?LOADS]),
    Probe = self(),
    Observer = spawn_link(fun() -> observe(Probe, Counts, Head, Committed) end),
    Running = supervise(Workers, Counts, Seen, Observer),
    timer:sleep(?SETTLE_MS),
    stop(Running),
    summarize(Schedulers, Counts, Seen).

%% The history of the subject when the probe starts: the probe is loaded in one batch with
%% the first version, so exactly one load is committed.
initial_history() ->
    {ok, [Head | _] = History} = erx_code:history(?SYSTEM_DOMAIN, ?SUBJECT),
    {Head, length(History)}.

start_worker(Scheduler, Counts, Seen) ->
    {Pid, Ref} = spawn_opt(fun() -> placed(Scheduler), work(Scheduler, Counts, Seen) end,
                           [{scheduler, Scheduler}, monitor]),
    {Ref, {Pid, Scheduler}}.

%% A worker bound to Scheduler runs there, or the run's claim of one worker per CPU fails.
placed(Scheduler) ->
    case erlang:system_info(scheduler_id) of
        Scheduler -> ok;
        Other -> exit({misplaced, Scheduler, Other})
    end.

%% Waits for the observer to see every load, starting another worker on the scheduler of
%% each worker a purge ended. Returns the workers then running.
supervise(Workers, Counts, Seen, Observer) ->
    receive
        {observed, Observer} ->
            Workers;
        {'EXIT', Observer, Reason} ->
            exit({observer, Reason});
        {'DOWN', Ref, process, _Pid, killed} when is_map_key(Ref, Workers) ->
            {{_Old, Scheduler}, Rest} = maps:take(Ref, Workers),
            atomics:add(Counts, cell(Scheduler, ?KILLED), 1),
            {NewRef, Worker} = start_worker(Scheduler, Counts, Seen),
            supervise(Rest#{NewRef => Worker}, Counts, Seen, Observer);
        {'DOWN', Ref, process, _Pid, Reason} when is_map_key(Ref, Workers) ->
            exit({worker, Reason})
    end.

work(Scheduler, Counts, Seen) ->
    Newest = atomics:get(Counts, ?NEWEST),
    Before = atomics:get(Counts, ?COMMITTED),
    Tag = ?SUBJECT:tag(),
    After = atomics:get(Counts, ?COMMITTED),
    atomics:add(Counts, cell(Scheduler, ?CALLS), 1),
    Tag < Before andalso atomics:add(Counts, cell(Scheduler, ?STALE), 1),
    Tag < Newest andalso atomics:add(Counts, cell(Scheduler, ?BEHIND), 1),
    After =/= Before andalso atomics:add(Counts, cell(Scheduler, ?STRADDLED), 1),
    Tag > Newest andalso raise_newest(Counts, Newest, Tag),
    atomics:put(Seen, (Scheduler - 1) * (?LOADS + 1) + Tag, 1),
    work(Scheduler, Counts, Seen).

%% Raises the newest tag returned to Tag, unless another worker raised it as far already.
raise_newest(Counts, Expected, Tag) ->
    case atomics:compare_exchange(Counts, ?NEWEST, Expected, Tag) of
        ok -> ok;
        Current when Current < Tag -> raise_newest(Counts, Current, Tag);
        _Current -> ok
    end.

%% Polls the history until LOADS more loads are seen, publishing each count as it grows.
%% The history keeps the newest 16 loads, so the head last seen must still be among them.
observe(Probe, _Counts, _Head, Committed) when Committed > ?LOADS ->
    Probe ! {observed, self()};
observe(Probe, Counts, Head, Committed) ->
    timer:sleep(?POLL_MS),
    {ok, [Newest | _] = History} = erx_code:history(?SYSTEM_DOMAIN, ?SUBJECT),
    case lists:splitwith(fun(Entry) -> Entry =/= Head end, History) of
        {New, [Head | _]} ->
            Next = Committed + length(New),
            atomics:put(Counts, ?COMMITTED, Next),
            observe(Probe, Counts, Newest, Next);
        {_, []} ->
            exit(observer_behind_history)
    end.

stop(Workers) ->
    maps:foreach(fun(Ref, {Pid, _}) ->
                         erlang:demonitor(Ref, [flush]),
                         exit(Pid, kill)
                 end, Workers).

summarize(Schedulers, Counts, Seen) ->
    Field = fun(Which) -> [atomics:get(Counts, cell(S, Which)) || S <- lists:seq(1, Schedulers)] end,
    Distinct = [length([T || T <- lists:seq(1, ?LOADS + 1),
                             atomics:get(Seen, (S - 1) * (?LOADS + 1) + T) =:= 1])
                || S <- lists:seq(1, Schedulers)],
    report("done committed ~b stale ~b behind ~b calls ~s straddled ~b killed ~b tags ~s",
           [atomics:get(Counts, ?COMMITTED), lists:sum(Field(?STALE)), lists:sum(Field(?BEHIND)),
            join(Field(?CALLS)), lists:sum(Field(?STRADDLED)), lists:sum(Field(?KILLED)), join(Distinct)]).

cell(Scheduler, Which) ->
    ?SHARED_CELLS + (Scheduler - 1) * ?CELLS_PER_WORKER + Which + 1.

join(Numbers) ->
    lists:join($,, [integer_to_list(N) || N <- Numbers]).

report(Format, Arguments) ->
    erx_log:debug(["reload-probe ", io_lib:format(Format, Arguments)]).
