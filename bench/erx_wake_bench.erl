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
wrong answer, and one that has not come a second after its deadline is a lost
wake; either fails the cell, which keeps the samples taken before. Each cell runs
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
    {Pid, Monitor} = spawn_opt(fun() -> Parent ! {self(), deadlines(Samples)} end, [{priority, Priority}, monitor]),
    {Counts, Taken} = receive
                          {Pid, Run} ->
                              erlang:demonitor(Monitor, [flush]),
                              Run;
                          {'DOWN', Monitor, process, Pid, _} ->
                              {raised, []}
                      end,
    summary(Priority, Counts, Taken, Clock).

%% Samples deadlines from one LEAD_MS ahead: the lost, early and missed counts, and
%% each on-time receipt's lateness in the order taken.
deadlines(Samples) ->
    First = erlang:monotonic_time(millisecond) + ?LEAD_MS,
    wait(First, 0, Samples, #{lost => 0, early => 0, missed => 0}, []).

%% Waits on deadline K with Left receipts still to take; Taken is newest first.
wait(_First, _K, 0, Counts, Taken) ->
    {Counts, lists:reverse(Taken)};
wait(First, K, Left, Counts, Taken) ->
    Deadline = First + K,
    Timer = erlang:start_timer(Deadline, self(), K, [{abs, true}]),
    receive
        {timeout, Timer, K} ->
            Received = erlang:monotonic_time(),
            Late = Received - erlang:convert_time_unit(Deadline, millisecond, native),
            Next = next(First, K, Received),
            Counted = maps:update_with(missed, fun(Missed) -> Missed + Next - K - 1 end, Counts),
            case Late < 0 of
                true -> wait(First, Next, Left - 1, maps:update_with(early, fun(Early) -> Early + 1 end, Counted), Taken);
                false -> wait(First, Next, Left - 1, Counted, [Late | Taken])
            end
    after max(0, Deadline - erlang:monotonic_time(millisecond)) + ?LOST_MS ->
        erlang:cancel_timer(Timer),
        {Counts#{lost := 1}, lists:reverse(Taken)}
    end.

%% The first deadline after a receipt at Received, at least the one after K.
next(First, K, Received) ->
    Unit = erlang:convert_time_unit(1, millisecond, native),
    max(K + 1, (Received - erlang:convert_time_unit(First, millisecond, native)) div Unit + 1).

summary(Priority, Counts, Taken, Clock) ->
    {Status, Reason, Counted} =
        case Counts of
            raised -> {<<"failed">>, #{reason => <<"the timed process raised an exception">>},
                       #{lost => 0, early => 0, missed => 0}};
            #{lost := Lost} when Lost > 0 -> {<<"failed">>, #{reason => <<"a timer message did not come">>}, Counts};
            #{early := Early} when Early > 0 ->
                {<<"failed">>, #{reason => <<"a timer message came before its deadline">>}, Counts};
            _ -> {<<"measured">>, #{}, Counts}
        end,
    Conditions = #{load => <<"idle">>, placement => <<"runtime">>, clock => maps:get(clock, Clock), batch => 1,
                   parameters => #{priority => atom_to_binary(Priority)}},
    Fields = #{benchmark => ?BENCHMARK, operation => ?OPERATION, conditions => Conditions,
               frequency_hz => maps:get(frequency_hz, Clock), status => Status, counts => Counted},
    erx_bench_hist:cell(maps:merge(Fields, Reason), Taken).
