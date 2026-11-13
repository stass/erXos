%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_irq_line).
-moduledoc """
Every driver's way to its interrupt lines, and the owner of a shared one
(docs/design-shared-devices.md, "Lines inside a domain").

**A driver** attaches each of its lines with attach/2 and answers each delivery with ack/1.
The record's mark decides the rest: a direct line is bound to the driver with
erx_device:irq_bind/2 and acknowledged with erx_device:irq_ack/2; a shared line is joined
to its owner, and ack/1 tells the owner the driver is done. Either way the driver receives
`{erx_irq, Dev, Line}` with its own record and line, so its receive and service code does
not depend on the mark. A driver acknowledges once per delivery, and only after it has
received the delivery: the owner takes an answer from a member it is not waiting on as
nothing (erx_irq_line_core), so a stray answer is ignored, but a second answer to one
notice would count for the next round.

**An owner** (start_owner/2) opens the record of the first driver on its line, binds the
line through it with erx_device:irq_bind_owner/2, which acknowledges it once, and then
performs, in order, the actions erx_irq_line_core returns for each event: a delivery of the
line, a driver's join, a member's answer, a member's down. A member is the reference of the
monitor the owner sets on a joining driver, so every member's exit reaches the core.

**Its starter** starts the owners of the shared lines its drivers name before the drivers,
and treats an owner's end as it treats a driver's: owners/1 says which owners from the
drivers' records, and start_owners/1 starts them linked to the caller. This module and
erx_device are the only modules that bind a line or acknowledge one
(chokepoint device-callers).
""".

-export([attach/2, ack/1, owners/1, start_owners/1, start_owner/2]).
-export([init/2]).

-export_type([handle/0]).

-doc "A driver's attachment of one line of one record, which ack/1 answers through.".
-opaque handle() :: {direct, erx_device:device(), non_neg_integer()}
                  | {shared, Owner :: pid(), Member :: reference()}.

-record(owner, {dev :: erx_device:device(), line :: non_neg_integer(),
                core :: erx_irq_line_core:core()}).

-doc """
Attaches line Line, an index in the record's `lines`, of the opened record Dev. A direct
line binds to the caller. A shared line joins the process erx_device:irq_holder/2 names,
in a call that monitors it: `{error, unbound}` when no process holds the line or the holder
ends before it answers, and the owner's `{error, badarg}` for a record or line that is not
its own. Other errors are erx_device:irq_bind/2's.
""".
-spec attach(erx_device:device(), non_neg_integer()) ->
    {ok, handle()} | {error, unbound | badarg | atom() | {status, integer()}}.
attach(Dev, Line) ->
    case erx_device:irq_bind(Dev, Line) of
        ok -> {ok, {direct, Dev, Line}};
        {error, shared} -> join(Dev, Line);
        {error, _} = Error -> Error
    end.

-doc "Answers the delivery the driver serviced: the line's acknowledgement, or the owner's done.".
-spec ack(handle()) -> ok.
ack({direct, Dev, Line}) ->
    erx_device:irq_ack(Dev, Line);
ack({shared, Owner, Member}) ->
    Owner ! {erx_irq_done, Member},
    ok.

-doc """
The owners one starter starts, from the records of its drivers in the order it starts
them: each shared line any record names, once, with the first record that names it and the
line's index there. Pure.
""".
-spec owners([{Driver :: module(), [erx_device:spec()]}]) -> [{erx_device:spec(), non_neg_integer()}].
owners(Drivers) ->
    Named = [{Line, {Spec, Index}}
             || {_Driver, Specs} <- Drivers, Spec <- Specs,
                {Index, {shared, Line}} <- lists:enumerate(0, maps:get(lines, Spec))],
    first_of_each(Named, #{}, []).

first_of_each([], _Seen, Owners) ->
    lists:reverse(Owners);
first_of_each([{Line, _} | Rest], Seen, Owners) when is_map_key(Line, Seen) ->
    first_of_each(Rest, Seen, Owners);
first_of_each([{Line, Owner} | Rest], Seen, Owners) ->
    first_of_each(Rest, Seen#{Line => true}, [Owner | Owners]).

-doc """
Starts, linked to the caller, the owners owners/1 names for Drivers, in that order. The
first that fails to start stops the rest: the owners already started stay linked to the
caller, whose own failure ends them.
""".
-spec start_owners([{module(), [erx_device:spec()]}]) -> {ok, [pid()]} | {error, term()}.
start_owners(Drivers) ->
    lists:foldl(fun({Spec, Line}, {ok, Pids}) ->
                        case start_owner(Spec, Line) of
                            {ok, Pid} -> {ok, Pids ++ [Pid]};
                            {error, _} = Error -> Error
                        end;
                   (_Owner, {error, _} = Error) ->
                        Error
                end, {ok, []}, owners(Drivers)).

-doc """
Starts the owner of line Line of record Spec, linked to the caller: it opens the record and
binds the line with erx_device:irq_bind_owner/2, and fails to start with that bind's error,
`{error, ebusy}` when another owner holds the line through another record.
""".
-spec start_owner(erx_device:spec(), non_neg_integer()) -> {ok, pid()} | {error, term()}.
start_owner(Spec, Line) ->
    proc_lib:start_link(?MODULE, init, [Spec, Line]).

-doc false.
-spec init(erx_device:spec(), non_neg_integer()) -> no_return().
init(Spec, Line) ->
    maybe
        {ok, Dev} ?= erx_device:open(Spec),
        ok ?= erx_device:irq_bind_owner(Dev, Line),
        proc_lib:init_ack({ok, self()}),
        loop(#owner{dev = Dev, line = Line, core = erx_irq_line_core:new()})
    else
        {error, _} = Error ->
            proc_lib:init_fail(Error, {exit, normal})
    end.

%% A shared attach: the holder's join answers on an alias of the call's monitor, so an owner
%% that ends before it answers is the monitor's down, never a wait.
join(Dev, Line) ->
    case erx_device:irq_holder(Dev, Line) of
        {ok, Owner} ->
            Call = erlang:monitor(process, Owner, [{alias, demonitor}]),
            Owner ! {erx_irq_join, Call, self(), Dev, Line},
            receive
                {Call, {ok, Member}} ->
                    erlang:demonitor(Call, [flush]),
                    {ok, {shared, Owner, Member}};
                {Call, {error, _} = Error} ->
                    erlang:demonitor(Call, [flush]),
                    Error;
                {'DOWN', Call, process, _, _} ->
                    {error, unbound}
            end;
        {error, unbound} ->
            {error, unbound}
    end.

loop(Owner = #owner{dev = Dev, line = Line}) ->
    receive
        {erx_irq, Dev, Line} ->
            loop(step(fire, Owner));
        {erx_irq_join, Call, Pid, JoinDev, JoinLine} when is_reference(Call), is_pid(Pid) ->
            loop(admit(Call, Pid, JoinDev, JoinLine, Owner));
        {erx_irq_done, Member} when is_reference(Member) ->
            loop(step({done, Member}, Owner));
        {'DOWN', Member, process, _, _} ->
            loop(step({down, Member}, Owner));
        _Other ->
            loop(Owner)
    end.

%% A join is for a record whose line this owner holds: the NIF names the holder of the
%% record's line, which is this process only for a record on its own line. The member is the
%% monitor, set before the core hears of it, so its exit reaches the core in every phase.
admit(Call, Pid, JoinDev, JoinLine, Owner) ->
    Self = self(),
    case holder(JoinDev, JoinLine) of
        {ok, Self} ->
            Member = erlang:monitor(process, Pid),
            Call ! {Call, {ok, Member}},
            step({join, Member, Pid, {JoinDev, JoinLine}}, Owner);
        _ ->
            Call ! {Call, {error, badarg}},
            Owner
    end.

holder(Dev, Line) ->
    try erx_device:irq_holder(Dev, Line)
    catch error:badarg -> {error, badarg}
    end.

step(Event, Owner = #owner{core = Core}) ->
    {Actions, Next} = erx_irq_line_core:step(Event, Core),
    lists:foreach(fun(Action) -> perform(Action, Owner) end, Actions),
    Owner#owner{core = Next}.

perform({notify, Pid, {Dev, Line}}, _Owner) ->
    Pid ! {erx_irq, Dev, Line};
perform(ack, #owner{dev = Dev, line = Line}) ->
    ok = erx_device:irq_ack(Dev, Line).
