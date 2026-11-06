%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_otp_bench).
-moduledoc "Microbenchmarks with explicit iterations and samples, run on stock OTP and on erXos.".

-export([run/3]).

%% Processes in W1's ring (docs/design-scheduler.md, E-S1).
-define(RING_SIZE, 10000).

-doc "Measures the named workload after one unreported warm-up batch.".
-spec run(pingpong | ring | spawn | switch, pos_integer(), pos_integer()) -> map().
run(Name, Iterations, Samples) ->
    workload(Name, min(Iterations, 1000)),
    Values = [sample(Name, Iterations) || _ <- lists:seq(1, Samples)],
    #{workload => atom_to_binary(Name, utf8), iterations => Iterations,
      samples => Samples, ns_per_operation => Values,
      emu_flavor => atom_to_binary(erlang:system_info(emu_flavor), utf8),
      schedulers => erlang:system_info(schedulers_online),
      wordsize => erlang:system_info(wordsize)}.

%% A ring builds its processes before the clock starts: a sample is the rounds.
sample(ring, Hops) ->
    Rounds = max(1, Hops div (?RING_SIZE + 1)),
    Head = ring_start(?RING_SIZE),
    Start = erlang:monotonic_time(nanosecond),
    ring_rounds(Head, Rounds),
    Elapsed = erlang:monotonic_time(nanosecond) - Start,
    ring_stop(Head),
    Elapsed / (Rounds * (?RING_SIZE + 1));
sample(switch, Yields) ->
    Start = erlang:monotonic_time(nanosecond),
    workload(switch, Yields),
    %% Two processes yield alternately on one scheduler, so each yield is a switch.
    (erlang:monotonic_time(nanosecond) - Start) / (2 * Yields);
sample(Name, Iterations) ->
    Start = erlang:monotonic_time(nanosecond),
    workload(Name, Iterations),
    (erlang:monotonic_time(nanosecond) - Start) / Iterations.

workload(pingpong, Iterations) ->
    {Worker, Monitor} = spawn_monitor(fun ping_worker/0),
    ping_loop(Worker, Iterations, <<0:512>>),
    Worker ! stop,
    receive
        {'DOWN', Monitor, process, Worker, normal} -> ok
    after 5000 ->
        error(ping_worker_did_not_stop)
    end;
workload(spawn, Iterations) ->
    spawn_loop(Iterations);
workload(ring, Hops) ->
    Head = ring_start(?RING_SIZE),
    ring_rounds(Head, max(1, Hops div (?RING_SIZE + 1))),
    ring_stop(Head);
workload(switch, Yields) ->
    Yielders = [spawn_monitor(fun() -> yield_loop(Yields) end)
                || _ <- [1, 2]],
    [receive
         {'DOWN', Monitor, process, Pid, normal} -> ok
     after 60000 ->
         error(yielder_did_not_stop)
     end || {Pid, Monitor} <- Yielders],
    ok.

yield_loop(0) -> ok;
yield_loop(Remaining) ->
    erlang:yield(),
    yield_loop(Remaining - 1).

%% The ring is a chain of processes, each forwarding a token to the next; the last
%% hands it back to the process that runs the rounds. Its head is the first to run.
ring_start(Size) ->
    Home = self(),
    lists:foldl(fun(_, Next) -> spawn(fun() -> ring_member(Next) end) end, Home, lists:seq(1, Size)).

ring_member(Next) ->
    receive
        token -> Next ! token, ring_member(Next);
        stop -> Next ! stop
    end.

%% One round is a token through every member and back: ?RING_SIZE + 1 sends.
ring_rounds(Head, Rounds) ->
    lists:foreach(fun(_) ->
                          Head ! token,
                          receive
                              token -> ok
                          after 600000 ->
                              error(ring_token_lost)
                          end
                  end, lists:seq(1, Rounds)).

ring_stop(Head) ->
    Head ! stop,
    receive
        stop -> ok
    after 60000 ->
        error(ring_did_not_stop)
    end.
ping_loop(_Worker, 0, _Payload) -> ok;
ping_loop(Worker, Remaining, Payload) ->
    Worker ! {ping, self(), Remaining, Payload},
    receive
        {pong, Remaining} -> ping_loop(Worker, Remaining - 1, Payload)
    after 5000 ->
        error(ping_worker_did_not_reply)
    end.

ping_worker() ->
    receive
        {ping, Sender, Sequence, _Payload} ->
            Sender ! {pong, Sequence},
            ping_worker();
        stop -> ok
    end.

spawn_loop(0) -> ok;
spawn_loop(Remaining) ->
    {Worker, Monitor} = spawn_monitor(fun() -> ok end),
    receive
        {'DOWN', Monitor, process, Worker, normal} -> spawn_loop(Remaining - 1)
    after 5000 ->
        error(spawned_process_did_not_stop)
    end.
