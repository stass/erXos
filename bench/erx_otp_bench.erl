%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_otp_bench).
-moduledoc "Host OTP microbenchmarks with explicit iterations and samples.".

-export([run/3]).

-doc "Measures the named workload after one unreported warm-up batch.".
-spec run(pingpong | spawn, pos_integer(), pos_integer()) -> map().
run(Name, Iterations, Samples) ->
    workload(Name, min(Iterations, 1000)),
    Values = [sample(Name, Iterations) || _ <- lists:seq(1, Samples)],
    #{workload => atom_to_binary(Name, utf8), iterations => Iterations,
      samples => Samples, ns_per_operation => Values,
      emu_flavor => atom_to_binary(erlang:system_info(emu_flavor), utf8),
      schedulers => erlang:system_info(schedulers_online),
      wordsize => erlang:system_info(wordsize)}.

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
    spawn_loop(Iterations).

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
