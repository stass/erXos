%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_irq_line_core).
-moduledoc """
The decisions of a shared interrupt line's owner (docs/design-shared-devices.md, "Lines
inside a domain"): a pure state machine from one event of the line to the next state and
the actions erx_irq_line performs, in the order given. It decides every notice to a driver
and every acknowledgement of the line, so the line is acknowledged once per round, only
after every member told of the round has answered or gone down, and no firing goes untold.

**Members.** A member is the reference of the monitor the owner set on a joining driver:
the join carries it, the driver's done names it, and the monitor's down removes it. The
core keeps each member with the driver's pid and the device record the driver joined for,
and hands both back in the member's notices. The core learns of a member only from a join,
which the owner answers by monitoring first, so every member's exit reaches the core as a
down, whatever the phase.

**Phases.**

    idle                 no round is in progress
    {round, W, Again}    the line fired; every member in W, an ordset that is never
                         empty, was told and has neither answered nor gone down; Again
                         is true when the line has fired since the round began
    held                 the line fired with no member to tell; it stays unacknowledged
                         until a member joins and answers or goes down

A member that joins during a round is told in the next one. A round ends when W empties:
the core acknowledges the line and, when Again is set, acts as on a firing in idle, so the
next round tells every member, those that joined during the last round included, or with
no member left holds the line.
""".

-export([new/0, step/2, members/1, phase/1]).

-export_type([core/0, member/0, event/0, action/0, phase/0]).

-doc "A member: the reference of the owner's monitor on the driver that joined.".
-type member() :: reference().

-doc """
What the owner hands the core: the line's delivery (`fire`), a driver's join for one of
its device records (`Dev`, which the core only carries), a member's answer, and the down
message of a member's monitor.
""".
-type event() :: fire
               | {join, member(), pid(), Dev :: term()}
               | {done, member()}
               | {down, member()}.

-doc "What the owner performs: tell a driver of a firing, or acknowledge the line.".
-type action() :: {notify, pid(), Dev :: term()} | ack.

-doc "The round in progress, as the moduledoc's table states it.".
-type phase() :: idle
               | {round, Waiting :: ordsets:ordset(member()), Again :: boolean()}
               | held.

-record(core, {members = #{} :: #{member() => {pid(), Dev :: term()}},
               phase = idle :: phase()}).

-opaque core() :: #core{}.

-doc "An owner's core before any driver joins: no member, no round.".
-spec new() -> core().
new() -> #core{}.

-doc """
One event in, the actions to perform in order and the next core out. A done or a down
naming no member changes nothing. A join of a member the core already holds is a fault
of the owner, which made the monitor, and fails with `function_clause`.
""".
-spec step(event(), core()) -> {[action()], core()}.
step(fire, #core{phase = idle} = Core) ->
    start_round(Core);
step(fire, #core{phase = {round, Waiting, _}} = Core) ->
    {[], Core#core{phase = {round, Waiting, true}}};
step(fire, #core{phase = held} = Core) ->
    {[], Core};
step({join, M, Pid, Dev}, #core{members = Members, phase = held} = Core)
  when not is_map_key(M, Members) ->
    Joined = Core#core{members = Members#{M => {Pid, Dev}}},
    {[{notify, Pid, Dev}], Joined#core{phase = {round, [M], false}}};
step({join, M, Pid, Dev}, #core{members = Members} = Core)
  when not is_map_key(M, Members) ->
    {[], Core#core{members = Members#{M => {Pid, Dev}}}};
step({done, M}, #core{phase = {round, Waiting, Again}} = Core) ->
    answered(M, Waiting, Again, Core);
step({done, _}, Core) ->
    {[], Core};
step({down, M}, #core{members = Members, phase = Phase} = Core) ->
    Left = Core#core{members = maps:remove(M, Members)},
    case Phase of
        {round, Waiting, Again} -> answered(M, Waiting, Again, Left);
        _ -> {[], Left}
    end.

-doc "The members the core holds, in order.".
-spec members(core()) -> [member()].
members(#core{members = Members}) -> lists:sort(maps:keys(Members)).

-doc "The round in progress.".
-spec phase(core()) -> phase().
phase(#core{phase = Phase}) -> Phase.

%% M answered or went down during a round: it leaves W, and the round ends when no one is
%% left to wait for. An M not in W (a member that joined during the round) changes
%% nothing, and W, which is not empty, stays so.
answered(M, Waiting, Again, Core) ->
    case ordsets:del_element(M, Waiting) of
        [] -> end_round(Again, Core);
        Rest -> {[], Core#core{phase = {round, Rest, Again}}}
    end.

%% Acknowledge the line; if it fired during the round, start the next round.
end_round(false, Core) ->
    {[ack], Core#core{phase = idle}};
end_round(true, Core) ->
    {Notices, Next} = start_round(Core#core{phase = idle}),
    {[ack | Notices], Next}.

%% A firing in idle: tell every member, or hold the line when there is none.
start_round(#core{members = Members} = Core) when map_size(Members) =:= 0 ->
    {[], Core#core{phase = held}};
start_round(#core{members = Members} = Core) ->
    Told = lists:sort(maps:to_list(Members)),
    Notices = [{notify, Pid, Dev} || {_, {Pid, Dev}} <- Told],
    Waiting = ordsets:from_list([M || {M, _} <- Told]),
    {Notices, Core#core{phase = {round, Waiting, false}}}.
