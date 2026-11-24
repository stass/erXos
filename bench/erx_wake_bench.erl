%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wake_bench).
-moduledoc """
The wake benchmark's Erlang guest (docs/design-bench.md, "1. `wake`: how late a
waiting thread runs"): erlang-timer, how late ERTS delivers a timer's message to
a process of a given priority. The process takes one timer with an absolute
deadline each millisecond (erlang:start_timer/4 with {abs, true}) and stamps its
message's receipt; a sample is that stamp less its deadline, in ticks of the
boot's CLOCK line. ERTS's absolute deadlines are whole milliseconds, so the cell
takes no phase sweep and its lateness includes ERTS's own rounding.

Deadline k is fixed before the run, the first deadline plus k milliseconds, and
the process always waits on the first deadline after its last receipt, so a
stall shows as missed periods and lateness and never moves the schedule
(docs/design-bench.md, "Profiles"). A message before its deadline is early, a
wrong answer that fails the cell and is not a sample. A message that has not
come a second after its deadline is a lost wake, which ends the run and fails
the cell with the samples taken before it. Missed periods are the deadlines
before the last one waited on that no wait took, as the C guests count them.
Each cell runs
in a process of its own at the cell's priority, so this module needs no
calibration across CPUs and its caller's priority does not matter.
""".
-export([cells/2]).

-define(BENCHMARK, <<"wake">>).
-define(OPERATION, <<"erlang-timer">>).
%% How long after its deadline a timer's message counts as lost, and how far
%% ahead of the run its first deadline lies, both in milliseconds.
-define(LOST_MS, 1000).
-define(LEAD_MS, 10).

-doc """
One erlang-timer cell for each of Priorities, each of Samples deadlines a
millisecond apart, as the fields of its BENCH line; Clock is the boot's
calibration (erx_bench_hist:calibrate/0).
""".
-spec cells(#{samples := pos_integer(), priorities := [erlang:priority_level()]}, map()) -> [map()].
cells(#{samples := Samples, priorities := Priorities}, Clock) ->
    [cell(Priority, Samples, Clock) || Priority <- Priorities].

%% One cell, timed in a process at Priority; a process that raises fails the cell.
cell(Priority, Samples, Clock) ->
    Parent = self(),
    {Pid, Monitor} = spawn_opt(fun() -> Parent ! {self(), deadlines(Samples)} end,
                               [{priority, Priority}, monitor]),
    Run = receive
              {Pid, Deadlines} ->
                  erlang:demonitor(Monitor, [flush]),
                  Deadlines;
              {'DOWN', Monitor, process, Pid, _} ->
                  {failed, <<"the timed process raised an exception">>, counts(), []}
          end,
    summary(Priority, Run, Clock).

counts() -> #{lost => 0, early => 0, missed => 0}.

%% Samples deadlines from one LEAD_MS ahead, as {Status, Reason, Counts, Taken}:
%% Taken is each on-time receipt's lateness in the order taken.
deadlines(Samples) ->
    First = erlang:monotonic_time(millisecond) + ?LEAD_MS,
    wait(First, 0, Samples, counts(), []).

%% Waits on deadline K with Left receipts still to take; Taken is newest first.
wait(_First, _K, 0, Counts, Taken) ->
    classified(Counts, lists:reverse(Taken));
wait(First, K, Left, Counts, Taken) ->
    Deadline = First + K,
    Timer = erlang:start_timer(Deadline, self(), K, [{abs, true}]),
    receive
        {timeout, Timer, K} ->
            Received = erlang:monotonic_time(),
            Late = Received - erlang:convert_time_unit(Deadline, millisecond, native),
            {Next, Skipped} = next(First, K, Received, Left),
            #{missed := Missed, early := Early} = Counts,
            case Late < 0 of
                true -> wait(First, Next, Left - 1, Counts#{missed := Missed + Skipped, early := Early + 1}, Taken);
                false -> wait(First, Next, Left - 1, Counts#{missed := Missed + Skipped}, [Late | Taken])
            end
    after max(0, Deadline - erlang:monotonic_time(millisecond)) + ?LOST_MS ->
        erlang:cancel_timer(Timer),
        {failed, <<"a timer message did not come">>, Counts#{lost := 1}, lists:reverse(Taken)}
    end.

%% The deadline to wait on after a receipt at Received of deadline K, the first
%% after the receipt and at least K + 1, and the deadlines it skips; after the
%% last receipt (Left 1) nothing is waited on, so nothing is skipped.
next(First, K, Received, Left) ->
    Unit = erlang:convert_time_unit(1, millisecond, native),
    Next = max(K + 1, (Received - erlang:convert_time_unit(First, millisecond, native)) div Unit + 1),
    {Next, case Left of 1 -> 0; _ -> Next - K - 1 end}.

classified(#{early := Early} = Counts, Taken) when Early > 0 ->
    {failed, <<"a timer message came before its deadline">>, Counts, Taken};
classified(Counts, Taken) ->
    {measured, none, Counts, Taken}.

summary(Priority, {Status, Reason, Counts, Taken}, Clock) ->
    Why = case Reason of
              none -> #{};
              _ -> #{reason => Reason}
          end,
    Conditions = #{load => <<"idle">>, placement => <<"runtime">>, clock => maps:get(clock, Clock), batch => 1,
                   parameters => #{priority => atom_to_binary(Priority)}},
    Fields = #{benchmark => ?BENCHMARK, operation => ?OPERATION, conditions => Conditions,
               frequency_hz => maps:get(frequency_hz, Clock), status => atom_to_binary(Status), counts => Counts},
    erx_bench_hist:cell(maps:merge(Fields, Why), Taken).
