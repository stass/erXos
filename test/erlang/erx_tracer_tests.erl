%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_tracer's merger (docs/design-live.md, "Tracing"): ordering, the
%% 100 ms hold, late entries, clock conversion and its bound, unknown events, overwritten
%% counts and the kernel row unsupported. test/host/erx_tracer_test.rb runs them on stock's
%% emulator, and runs each seed there, which must make the case it names fail.

-module(erx_tracer_tests).
-include_lib("eunit/include/eunit.hrl").

-define(MS, 1000000).

%% A ring record: park (1) of slot 2 with deadline 9 on CPU 1.
park(Time) -> {Time, 1, 1, 0, 6, 1, {2, 9, 0}}.

ok(Records) -> {ok, Records, 0, 0}.

times(Entries) -> [Time || #{time := Time} <- Entries].

ordering_test() ->
    M0 = erx_tracer:new([{erts, 4}, backend]),
    {M1, []} = erx_tracer:ring(M0, backend, ok([park(10), park(30)]), 40),
    {M2, []} = erx_tracer:erts(M1, 4, [{trace_ts, self(), in, {m, f, 1}, 20}], {0, 0}, 40),
    %% A trace session's batch shows its time only with the session's next batch.
    ?assertMatch({_, []}, erx_tracer:release(M2, 40)),
    {M3, []} = erx_tracer:erts(M2, 4, [], {0, 0}, 45),
    {M4, Out} = erx_tracer:release(M3, 45),
    ?assertEqual([10, 20], times(Out)),
    {M5, []} = erx_tracer:erts(M4, 4, [], {0, 0}, 50),
    ?assertEqual([30], times(element(2, erx_tracer:release(M5, 50)))).

%% Each CPU's ring is its own source: one CPU's records wait for the other's read.
per_source_test() ->
    M0 = erx_tracer:new([{kernel, 0}, {kernel, 1}]),
    {M1, []} = erx_tracer:ring(M0, {kernel, 0}, ok([park(10), park(20)]), 25),
    {M2, []} = erx_tracer:release(M1, 25),
    {M3, []} = erx_tracer:ring(M2, {kernel, 1}, ok([park(15)]), 26),
    {_, Out} = erx_tracer:release(M3, 26),
    %% CPU 1 has shown 15, so 20 waits for its next read.
    ?assertEqual([{10, false}, {15, false}], [{T, L} || #{time := T, late := L} <- Out]).

%% A source's shown time never moves back.
shown_time_is_monotone_test() ->
    M0 = erx_tracer:new([backend, {erts, 4}]),
    {M1, []} = erx_tracer:erts(M0, 4, [], {0, 0}, 1000),
    {M2, []} = erx_tracer:erts(M1, 4, [], {0, 0}, 1001),
    {M3, []} = erx_tracer:erts(M2, 4, [{trace_ts, self(), in, {m, f, 1}, 500}], {0, 0}, 1002),
    {M4, []} = erx_tracer:erts(M3, 4, [], {0, 0}, 1003),
    {M5, []} = erx_tracer:ring(M4, backend, ok([park(900)]), 1004),
    ?assertEqual([500, 900], times(element(2, erx_tracer:release(M5, 1004)))).

hold_test() ->
    M0 = erx_tracer:new([{erts, 4}, backend]),
    {M1, []} = erx_tracer:ring(M0, backend, ok([park(10)]), 20),
    ?assertMatch({_, []}, erx_tracer:release(M1, 10 + 100 * ?MS - 1)),
    ?assertMatch({_, [#{time := 10, late := false}]}, erx_tracer:release(M1, 10 + 100 * ?MS)).

late_test() ->
    M0 = erx_tracer:new([{erts, 4}, backend]),
    {M1, []} = erx_tracer:ring(M0, backend, ok([park(500)]), 600),
    {M2, [#{time := 500}]} = erx_tracer:release(M1, 500 + 100 * ?MS),
    {_, Late} = erx_tracer:erts(M2, 4, [{trace_ts, self(), out, {m, f, 1}, 100}], {0, 0}, 700),
    ?assertMatch([#{time := 100, late := true, event := out}], Late).

clock_conversion_test() ->
    ?assertEqual(1500, erx_tracer:convert(-500, {-1000, 1000})),
    %% A monotonic clock slewed by 1 % after the pair: the error is at most 1 % of the distance.
    Pair = {-1000000, 5000000},
    Distance = 10 * ?MS,
    Slewed = element(1, Pair) + Distance + Distance div 100,
    Error = abs(erx_tracer:convert(Slewed, Pair) - (element(2, Pair) + Distance)),
    ?assert(Error =< Distance div 100),
    M0 = erx_tracer:new([{erts, 4}]),
    {M1, []} = erx_tracer:erts(M0, 4, [{trace_ts, self(), in, {m, f, 1}, -500}], {-1000, 1000}, 2000),
    {M2, []} = erx_tracer:erts(M1, 4, [], {-1000, 1000}, 2001),
    ?assertMatch({_, [#{time := 1500, row := erts, reporter := runtime, fields := #{domain := 4, mfa := {m, f, 1}}}]},
                 erx_tracer:release(M2, 2001)).

unknown_and_named_events_test() ->
    M0 = erx_tracer:new([backend]),
    Wake = {20, 2, 0, 1, 4, 1, {2, 1 bsl 64 - 12, 0}},
    End = {30, 5, 0, 1, 0, 1, {3, 1 bsl 64 - 1, 0}},
    {M1, []} = erx_tracer:ring(M0, backend, ok([park(10), Wake, End, {40, 99, 0, 0, 0, 0, {7, 7, 7}}]), 50),
    {_, [P, W, E, U]} = erx_tracer:release(M1, 50),
    ?assertMatch(#{event := park, reporter := {stopgap, liberx_trace},
                   fields := #{slot := 2, deadline := 9, cpu := 1, thread := 6, space := 1}}, P),
    ?assertMatch(#{event := wake, fields := #{result := notsup, cpu := unknown}}, W),
    ?assertMatch(#{event := space_end, fields := #{target := 3, status := -1}}, E),
    ?assertEqual(#{time => 40, row => backend, event => {unknown, 99}, reporter => {stopgap, liberx_trace},
                   late => false, fields => #{cpu => 0, thread => 0, space => 0}}, U).

overwritten_test() ->
    M0 = erx_tracer:new([backend]),
    {M1, []} = erx_tracer:ring(M0, backend, {ok, [park(10)], 5, 3}, 20),
    {_, Out} = erx_tracer:release(M1, 20),
    ?assertMatch([#{event := overwritten, fields := #{count := 3}, time := 10}, #{event := park}], Out).

kernel_unsupported_test() ->
    M0 = erx_tracer:new([{erts, 4}, backend, {kernel, 0}, {kernel, 1}]),
    {M1, Now} = erx_tracer:ring(M0, {kernel, 0}, {error, unsupported}, 5),
    ?assertEqual([#{time => 5, row => kernel, event => unsupported, fields => #{}, reporter => kernel, late => false}], Now),
    %% Once for the row, whichever CPU's read answers it again.
    {M2, []} = erx_tracer:ring(M1, {kernel, 1}, {error, unsupported}, 5),
    {M3, []} = erx_tracer:ring(M2, {kernel, 0}, {error, unsupported}, 5),
    %% A stopgap's row that does not run is left out, and no such source is waited for.
    {M4, []} = erx_tracer:ring(M3, backend, {error, unsupported}, 6),
    {M5, []} = erx_tracer:erts(M4, 4, [{trace_ts, self(), in, {m, f, 1}, 7}], {0, 0}, 8),
    {M6, []} = erx_tracer:erts(M5, 4, [], {0, 0}, 9),
    ?assertMatch({_, [#{time := 7}]}, erx_tracer:release(M6, 9)).

%% A read refused with a status other than unsupported shows one error entry for its ring,
%% with the status and the row's reporter, and that ring is no longer waited for.
refused_read_test() ->
    M0 = erx_tracer:new([backend, {kernel, 0}, {kernel, 1}]),
    {M1, Now} = erx_tracer:ring(M0, {kernel, 1}, {error, limit}, 5),
    ?assertEqual([#{time => 5, row => kernel, event => error, fields => #{status => limit, cpu => 1},
                    reporter => kernel, late => false}], Now),
    {M2, Backend} = erx_tracer:ring(M1, backend, {error, inval}, 6),
    ?assertMatch([#{row := backend, event := error, fields := #{status := inval},
                    reporter := {stopgap, liberx_trace}}], Backend),
    %% Once for the ring: a second refusal of it adds nothing.
    {M3, []} = erx_tracer:ring(M2, backend, {error, inval}, 7),
    %% Neither refused ring holds the stream: the remaining ring's record goes out on its own.
    {M4, []} = erx_tracer:ring(M3, {kernel, 0}, ok([park(8)]), 9),
    ?assertMatch({_, [#{time := 8}]}, erx_tracer:release(M4, 9)).

emit_test() ->
    Ref = make_ref(),
    ok = erx_tracer:emit(self(), Ref, [#{time => 1}]),
    ?assertEqual({erx_trace, Ref, #{time => 1}}, receive Message -> Message after 0 -> none end).
