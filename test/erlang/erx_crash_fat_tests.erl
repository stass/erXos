%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The landing gate's crash-state suite (docs/design-crash-states.md, "The
%% generator", the landing row): every FAT seq-1 workload and a fixed sample of
%% seq-2, over fsimg's FAT16 and FAT32 volumes, in `atomic` mode at 4,096 states an
%% epoch, through erx_crash_run's checks 1 to 3. Each run prints its workloads'
%% coverage, a line per cell with each epoch's, and its time. ERX_FAT_IMAGES as
%% erx_media_volume_tests; ERX_CRASH_OUT the directory the host test prepared for
%% failure records, holding `seq-1` and `seq-2`.

-module(erx_crash_fat_tests).
-include_lib("eunit/include/eunit.hrl").

-define(BOUND, 4096).
-define(SEED, 20261127).
-define(SEQ2_SAMPLE, 400).

fat_seq_1_test_() ->
    {timeout, 1800, fun() -> passed("seq-1", "all", [{erx_crash_workloads:name(1, P), erx_crash_workloads:workload(1, P)}
                                                     || P <- lists:seq(1, erx_crash_workloads:count(1))]) end}.

fat_seq_2_sample_test_() ->
    {timeout, 1800, fun() ->
                            Count = erx_crash_workloads:count(2),
                            Positions = sample(Count, ?SEQ2_SAMPLE, ?SEED),
                            passed("seq-2", io_lib:format("sampled ~b of ~b, seed ~b,", [length(Positions), Count, ?SEED]),
                                   [{erx_crash_workloads:name(2, P), erx_crash_workloads:workload(2, P)} || P <- Positions])
                    end}.

%% K distinct positions of 1..N drawn from Seed, in order.
sample(N, K, Seed) ->
    Keyed = lists:sort(element(1, lists:mapfoldl(fun(P, R) -> {U, R1} = rand:uniform_s(R), {{U, P}, R1} end,
                                                 rand:seed_s(exsss, {Seed, 2, 0}), lists:seq(1, N)))),
    lists:sort([P || {_, P} <- lists:sublist(Keyed, K)]).

passed(Label, Coverage, Workloads) ->
    Started = erlang:monotonic_time(millisecond),
    Images = [{list_to_binary(Name), image(Name)} || Name <- ["fat16.img", "fat32.img"]],
    Out = filename:join(os:getenv("ERX_CRASH_OUT"), Label),
    true = filelib:is_dir(Out),
    io:format(user, "~ncrash states, FAT ~s: ~s ~b workloads of ~s, generator ~s, workloads ~s~n",
              [Label, Coverage, length(Workloads), Label, erx_crash_states:version(), erx_crash_workloads:version()]),
    #{states := States, timed_out := TimedOut, failures := Failures, records := Records} =
        erx_crash_run:run(#{images => Images, workloads => Workloads, bound => ?BOUND, seed => ?SEED, out => Out}),
    io:format(user, "crash states, FAT ~s: ~b states checked, ~b timed_out, ~b failing, records ~p, ~b ms~n",
              [Label, States, TimedOut, length(Failures), Records, erlang:monotonic_time(millisecond) - Started]),
    ?assert(States > 0),
    ?assertEqual({0, 0}, {length(Failures), TimedOut}).

image(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    Bytes.
