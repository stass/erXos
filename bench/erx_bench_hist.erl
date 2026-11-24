%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bench_hist).
-moduledoc """
The Erlang guests' histogram, clock calibration and lines (docs/design-bench.md,
"The histogram", "The one clock", "A benchmark"), the Erlang twin of the C
library of test/guest/bench/. An Erlang guest reads ERTS's monotonic time in its
native unit, which on erXos is erx_clock_ns, the system counter in nanoseconds
(otp/erts/emulator/sys/erxos/sys_time.c), so its clock is `counter` and its ticks
are nanoseconds.

A histogram's buckets are powers of two split into 64 equal parts: a value under
64 has a bucket of its own, and a larger one shares its bucket with the values
that agree with it in the six bits below its top bit. Each non-empty bucket is
reported as [low, last, count]. The host's Erx::BenchMeasurement is the lines'
one validator; this module only builds them. A cell's samples are the list the
caller timed, in the order it took them, so the summary is a pure function of
that list.
""".
-export([bucket/1, bounds/1, batch/2, cell/2, calibrate/0, clock_line/1, cell_line/1]).

%% Sub-buckets per octave, and the largest samples a line carries.
-define(SUB, 64).
-define(LARGEST, 16).
%% Back-to-back reads that calibrate the clock, and the ticks a batch must span.
-define(CALIBRATION_PAIRS, 10000).
-define(BATCH_SPAN, 100).

-doc "The index of the bucket holding a non-negative Value.".
-spec bucket(non_neg_integer()) -> non_neg_integer().
bucket(Value) when is_integer(Value), Value >= 0, Value < ?SUB ->
    Value;
bucket(Value) when is_integer(Value), Value >= ?SUB ->
    Shift = top_bit(Value) - 6,
    ?SUB + Shift * ?SUB + ((Value bsr Shift) band (?SUB - 1)).

-doc "The lowest and the last value bucket Index holds, both included.".
-spec bounds(non_neg_integer()) -> {non_neg_integer(), non_neg_integer()}.
bounds(Index) when is_integer(Index), Index >= 0, Index < ?SUB ->
    {Index, Index};
bounds(Index) when is_integer(Index), Index >= ?SUB ->
    Shift = (Index - ?SUB) div ?SUB,
    Low = (?SUB + (Index - ?SUB) rem ?SUB) bsl Shift,
    {Low, Low + (1 bsl Shift) - 1}.

%% The position of Value's top bit, for Value of at least one.
top_bit(Value) -> top_bit(Value bsr 1, 0).

top_bit(0, Bit) -> Bit;
top_bit(Rest, Bit) -> top_bit(Rest bsr 1, Bit + 1).

-doc """
The batch an operation is timed in from its warm-up median (docs/design-bench.md,
"The one clock", short operations): 1 when the median spans 100 of the clock's
steps, and otherwise the smallest power of two of operations that does. An Erlang
guest's ticks are nanoseconds of a coarser counter, so a step is the calibration's
increment, not one tick: the rule is the C guests', which count the counter's own
ticks.
""".
-spec batch(non_neg_integer(), pos_integer()) -> pos_integer().
batch(Median, Increment) when is_integer(Median), Median >= 0, is_integer(Increment), Increment > 0 ->
    span(max(Median, 1), ?BATCH_SPAN * Increment, 1).

span(Median, Span, Batch) when Median * Batch >= Span -> Batch;
span(Median, Span, Batch) -> span(Median, Span, Batch * 2).

-doc """
A cell's summary from the samples it took, in the order taken, as the fields a
BENCH line carries: samples, histogram, min and max (only with a sample), and the
sixteen largest as [sequence, value], or every sample where there are fewer, the
largest first. Conditions is the cell's benchmark, operation, conditions, status,
reason (absent when measured), counts and frequency, which the line carries as
given.
""".
-spec cell(map(), [non_neg_integer()]) -> map().
cell(Conditions, Samples) ->
    Count = fun(Value, Counts) -> maps:update_with(bucket(Value), fun(N) -> N + 1 end, 1, Counts) end,
    Counted = lists:foldl(Count, #{}, Samples),
    Histogram = [begin {Low, Last} = bounds(Index), [Low, Last, Count] end
                 || {Index, Count} <- lists:sort(maps:to_list(Counted))],
    Indexed = lists:zip(lists:seq(0, length(Samples) - 1), Samples),
    Largest = lists:sublist(lists:sort(fun({_, A}, {_, B}) -> A >= B end, Indexed), ?LARGEST),
    Extremes = case Samples of
                   [] -> #{};
                   _ -> #{min => lists:min(Samples), max => lists:max(Samples)}
               end,
    maps:merge(Conditions#{samples => length(Samples), histogram => Histogram,
                           largest => [[Sequence, Value] || {Sequence, Value} <- Largest]},
               Extremes).

-doc """
The calibration of the clock (docs/design-bench.md, "The one clock") as the fields
a CLOCK line carries: its frequency, the smallest increment of 10,000
back-to-back reads, the median of their differences as the read's cost, and the
rounding of a timed wait, whole milliseconds for ERTS's timers. An Erlang guest
reads no cycle counter and stamps no cell across CPUs, so cycles_per_tick is
unknown and pairs is empty.
""".
-spec calibrate() -> map().
calibrate() ->
    Differences = lists:sort([read_pair() || _ <- lists:seq(1, ?CALIBRATION_PAIRS)]),
    Increment = case [Difference || Difference <- Differences, Difference > 0] of
                    [Smallest | _] -> Smallest;
                    [] -> error(no_increment_observed)
                end,
    #{clock => <<"counter">>, frequency_hz => erlang:convert_time_unit(1, second, native),
      increment => Increment, read_cost => lists:nth((length(Differences) + 1) div 2, Differences),
      wait_rounding => erlang:convert_time_unit(1, millisecond, native),
      cycles_per_tick => <<"unknown">>, pairs => []}.

read_pair() ->
    First = erlang:monotonic_time(),
    erlang:monotonic_time() - First.

-doc "A CLOCK line from a calibration, without its line end.".
-spec clock_line(map()) -> binary().
clock_line(Clock) -> line(<<"CLOCK ">>, Clock).

-doc "A BENCH line from a cell, without its line end.".
-spec cell_line(map()) -> binary().
cell_line(Cell) -> line(<<"BENCH ">>, Cell).

line(Kind, Fields) -> iolist_to_binary([Kind, json:encode(Fields)]).
