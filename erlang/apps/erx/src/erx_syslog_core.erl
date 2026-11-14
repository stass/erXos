%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_syslog_core).
-moduledoc """
The log service's pure decisions (docs/design-log.md): the line each
domain's record renders to, and the rate that holds each domain to its
share of the log.

**The line.** line/5 is the one function that turns a domain's text into a
line (invariant L2):

```text
SECONDS.MICROSECONDS LEVEL domain ID principal P NAME: TEXT
```

The time is the service's, from the monotonic clock, and the level, id and
principal are the service's own text, ASCII by construction. The name and
the text go through the line escape, erx_text:escape_line/1, so every
control in them, tab and newline included, shows as a token and the line
holds no byte that escape would not pass. A line has no ending: the console
ends it in CR-LF and the store in LF.

**The rate.** Each domain may have ERX_LOG_RATE_BYTES (16 KiB) of lines
stored in a second, the rate erx_debug_log allows a space. A record is
charged its whole line as stored, head, escaped text and LF, so neither
empty records nor text that the escape lengthens write more than that.
Past it the record is dropped and counted, as is a record that is not a
level and a binary text. The rate keeps one table, the current second's,
with an entry for each domain that wrote in it: the bytes charged and the
records dropped. turn/3, at each of the service's ticks, finds whether the
clock has reached a later second; if it has, it renders one
`erx_syslog: domain ID: N records dropped` line for each entry with drops
and empties the table. So every drop is shown, a domain's that has since
ended included, and the table holds at most the domains of one second.

A second is as the ticks divide it: a write is charged to the table of the
last turn, whatever second its time is in, so across a turn that comes late
a domain can have up to twice the rate stored under one second's time.

The bound on a record's text, log_write_text_max (4 KiB), is upstream: the
log facet's decoder holds other domains to it and erx_log_h the system
domain's own records. The core charges a text of any length, so a text
whose escape is longer than the rate, such as 4 KiB of controls, is always
dropped and shows only in its domain's drops line.

**The consumers** (docs/design-log.md, "Consumers and backlogs"). The console
and the store each have a backlog of lines and a state, `idle` or
`{waiting, Requester}`, which is all the service knows of them. Every line
joins both backlogs (lines/4), each tagged with its family, `kernel` or
`messages`, for the store. A backlog holds at most BACKLOG_BYTES (1 MiB) of
lines, each counted with its LF; past that its oldest lines go, counted, and
its consumer's next batch begins with the note `erx_syslog: N lines missed`,
which joins that batch alone. A consumer asks for its next batch (ask/5); its
second request replaces its first, and another process's is refused while one
is kept. A batch is sent only as the answer to a
kept request (due/3): a waiting console's whole backlog as soon as it holds a
line, and a waiting store's oldest lines up to STORE_BATCH_BYTES (64 KiB) once
that many have gathered or the oldest has waited STORE_WAIT_NS (one second).
Once sent, the role is idle until its consumer asks again, so a consumer holds
at most one batch and a writer never waits on it. The answers are actions for
the service to do: `{send, Requester, Batch}` answers a request and forgets its
monitor, `{forget, Requester}` forgets a replaced one, and `{refuse, Requester}`
answers a refused one `{error, busy}` and forgets it.

Times are nanoseconds of a monotonic clock that does not go below zero,
such as os:perf_counter(nanosecond). Nothing here reads a clock, sends a
message or keeps state between calls.
""".

-include("generated/erx_abi.hrl").

-export([line/5, new/1, write/4, turn/3]).
-export([note/3, consumers/0, lines/4, ask/5, ended/2, due/3]).
-export_type([source/0, log_record/0, table/0]).
-export_type([family/0, role/0, requester/0, action/0, consumers/0]).

-define(NS_PER_S, 1000000000).
-define(NS_PER_US, 1000).
%% A backlog's bound, the store's batch and the store's longest wait for one.
-define(BACKLOG_BYTES, 1048576).
-define(STORE_BATCH_BYTES, 65536).
-define(STORE_WAIT_NS, ?NS_PER_S).

%% One of the logger's eight levels.
-define(IS_LEVEL(Level),
        (Level =:= emergency orelse Level =:= alert orelse
         Level =:= critical orelse Level =:= error orelse
         Level =:= warning orelse Level =:= notice orelse
         Level =:= info orelse Level =:= debug)).

%% Who wrote a record, as the service knows it: the grantee's domain id, its
%% principal's number, unknown for the system domain's own records until the
%% domain service has named the system principal, and the domain's name.
-type source() :: #{id := non_neg_integer(),
                    principal := non_neg_integer() | unknown,
                    name := unicode:chardata()}.
%% A record as `write` carries it: a level and the text.
-type log_record() :: {logger:level(), binary()}.
%% The rate's table: the second it is for, and for each domain that wrote in
%% it the bytes charged and the records dropped.
-opaque table() :: {Second :: non_neg_integer(),
                    #{non_neg_integer() =>
                          {Charged :: non_neg_integer(),
                           Dropped :: non_neg_integer()}}}.

%% Which of the store's files a line belongs to: the kernel's or the domains'.
-type family() :: kernel | messages.
%% A consumer of the log.
-type role() :: console | store.
%% A consumer's kept request: its gen_server reply target and the monitor the
%% service holds on its sender.
-type requester() :: {gen_server:from(), reference()}.
%% What the service does for the core: answer a request with a batch, the
%% console's lines or the store's lines with their families, or forget one.
-type action() :: {send, requester(), [binary()] | [{family(), binary()}]}
                | {forget, requester()}
                | {refuse, requester()}.
%% A role's backlog: its lines, oldest first, each with when it joined and its
%% family; their bytes, each counted with its LF; the lines dropped since its
%% last batch; and whether its consumer waits.
-record(backlog, {lines = queue:new() :: queue:queue({non_neg_integer(), family(), binary()}),
                  bytes = 0 :: non_neg_integer(),
                  missed = 0 :: non_neg_integer(),
                  waiting = idle :: idle | {waiting, requester()}}).
-opaque consumers() :: #{console := #backlog{}, store := #backlog{}}.

-doc """
The line of Record, which the domain Id, of principal Principal and named
Name, wrote at time Now: the time, the level, the id and the principal,
then the name and the text, each through the line escape.
""".
-spec line(non_neg_integer(), non_neg_integer(),
           non_neg_integer() | unknown, unicode:chardata(), log_record()) ->
          binary().
line(Now, Id, Principal, Name, {Level, Text})
  when is_integer(Now), Now >= 0, is_integer(Id), Id >= 0,
       ?IS_LEVEL(Level), is_binary(Text) ->
    iolist_to_binary(
      [integer_to_binary(Now div ?NS_PER_S), $., microseconds(Now),
       $\s, atom_to_binary(Level),
       <<" domain ">>, integer_to_binary(Id),
       <<" principal ">>, principal(Principal), $\s,
       erx_text:escape_line(Name), <<": ">>, erx_text:escape_line(Text)]).

-doc "An empty table for the second of time Now.".
-spec new(non_neg_integer()) -> table().
new(Now) when is_integer(Now), Now >= 0 ->
    {Now div ?NS_PER_S, #{}}.

-doc """
The lines that Records, written by Source at time Now, add to the log, in
order, and the next table: each record within its domain's rate is
rendered and charged, and each past it, or not a level and a binary text,
is dropped and counted. Records are charged to the table's second, the
second of the last turn, whatever second Now is in.
""".
-spec write(non_neg_integer(), source(), [term()], table()) ->
          {[binary()], table()}.
write(Now, #{id := Id} = Source, Records, {Second, Domains})
  when is_list(Records) ->
    Entry0 = maps:get(Id, Domains, {0, 0}),
    {Lines, Entry} = charge(Now, Source, Records, Entry0, []),
    {Lines, {Second, Domains#{Id => Entry}}}.

charge(_Now, _Source, [], Entry, Lines) ->
    {lists:reverse(Lines), Entry};
charge(Now, Source, [Record | Rest], {Charged, Dropped}, Lines) ->
    case rendered(Now, Source, Record) of
        {ok, Line, Cost} when Charged + Cost =< ?ERX_LOG_RATE_BYTES ->
            charge(Now, Source, Rest, {Charged + Cost, Dropped},
                   [Line | Lines]);
        {ok, _Line, _PastTheRate} ->
            charge(Now, Source, Rest, {Charged, Dropped + 1}, Lines);
        refused ->
            charge(Now, Source, Rest, {Charged, Dropped + 1}, Lines)
    end.

%% A record of the one shape, its line and what it costs: the line as the
%% store keeps it, with its LF.
rendered(Now, #{id := Id, principal := Principal, name := Name},
         {Level, Text} = Record)
  when ?IS_LEVEL(Level), is_binary(Text) ->
    Line = line(Now, Id, Principal, Name, Record),
    {ok, Line, byte_size(Line) + 1};
rendered(_Now, _Source, _Record) ->
    refused.

-doc """
The service's tick at time Now. If Now is in a later second than the
table's, the drops line of each domain that dropped records, in the order
of their ids, as records of the system domain, System, at level `notice`,
and an empty table for Now's second; otherwise no lines and the table as
it is. The drops lines are not charged, so none of them is dropped.
""".
-spec turn(non_neg_integer(), source(), table()) -> {[binary()], table()}.
turn(Now, #{id := Id, principal := Principal, name := Name},
     {Second, Domains})
  when is_integer(Now), Now div ?NS_PER_S > Second ->
    Lines = [line(Now, Id, Principal, Name,
                  {notice, drops_text(Domain, Dropped)})
             || {Domain, {_Charged, Dropped}}
                    <- lists:sort(maps:to_list(Domains)),
                Dropped > 0],
    {Lines, new(Now)};
turn(Now, #{}, {_Second, _Domains} = Table) when is_integer(Now), Now >= 0 ->
    {[], Table}.

drops_text(Domain, Count) ->
    iolist_to_binary([<<"erx_syslog: domain ">>, integer_to_binary(Domain),
                      <<": ">>, integer_to_binary(Count),
                      <<" records dropped">>]).

%% The six digits of the microseconds of Now, nanoseconds, within its second.
microseconds(Now) ->
    string:pad(integer_to_binary(Now rem ?NS_PER_S div ?NS_PER_US), 6,
               leading, $0).

principal(unknown) ->
    <<"unknown">>;
principal(Principal) when is_integer(Principal), Principal >= 0 ->
    integer_to_binary(Principal).

-doc """
A note of the service's own, as a line of the system domain, System, at time
Now and level `notice`: what the service says of the log itself, never
charged to the rate.
""".
-spec note(non_neg_integer(), source(), binary()) -> binary().
note(Now, #{id := Id, principal := Principal, name := Name}, Text) when is_binary(Text) ->
    line(Now, Id, Principal, Name, {notice, Text}).

-doc """
Both consumers, the console and the store, idle, with empty backlogs.
""".
-spec consumers() -> consumers().
consumers() ->
    #{console => #backlog{}, store => #backlog{}}.

-doc """
Lines join both backlogs at time Now, each with its family, oldest first:
`kernel` for a line the kernel's ring held, `messages` for every other. A
backlog past its bound drops its oldest lines, counted. The answer is the
batches that fall due, each `lines missed` note at their head a line of the
system domain, System, and the next consumers.
""".
-spec lines(non_neg_integer(), source(), [{family(), binary()}], consumers()) ->
          {[action()], consumers()}.
lines(_Now, _System, [], Consumers) ->
    {[], Consumers};
lines(Now, System, Lines, Consumers) ->
    Joined = maps:map(fun(_Role, Backlog) -> bounded(joined(Now, Lines, Backlog)) end, Consumers),
    due(Now, System, Joined).

-doc """
The role's consumer asks for its next batch with Requester, its request and
the monitor the service holds on its sender. A request kept for the role is
replaced only by its own sender's, and the service forgets the old monitor;
a request from any other process while one is kept is refused, so no other
process can take the role's batches from its consumer. The answer is the
refusal or the batch, if one falls due now, and the next consumers.
""".
-spec ask(role(), requester(), non_neg_integer(), source(), consumers()) ->
          {[action()], consumers()}.
ask(Role, {{Pid, _Tag}, Monitor} = Requester, Now, System, Consumers) when is_reference(Monitor) ->
    #{Role := Backlog} = Consumers,
    case Backlog#backlog.waiting of
        {waiting, {{Other, _}, _}} when Other =/= Pid ->
            {[{refuse, Requester}], Consumers};
        Waiting ->
            Forgotten = [{forget, Old} || {waiting, Old} <- [Waiting]],
            {Due, Next} = due(Now, System, Consumers#{Role := Backlog#backlog{waiting = {waiting, Requester}}}),
            {Forgotten ++ Due, Next}
    end.

-doc """
The sender whose request's monitor is Monitor has ended: its kept request,
if any, is dropped, and the role is idle.
""".
-spec ended(reference(), consumers()) -> consumers().
ended(Monitor, Consumers) ->
    maps:map(fun(_Role, #backlog{waiting = {waiting, {_From, M}}} = Backlog) when M =:= Monitor ->
                     Backlog#backlog{waiting = idle};
                (_Role, Backlog) ->
                     Backlog
             end, Consumers).

-doc """
The batches that fall due at time Now, with no line added: a waiting
console's once its backlog holds a line, and a waiting store's once
STORE_BATCH_BYTES have gathered or the oldest line has waited STORE_WAIT_NS.
Each batch is answered to its requester, which is then forgotten, and the
role is idle.
""".
-spec due(non_neg_integer(), source(), consumers()) -> {[action()], consumers()}.
due(Now, System, Consumers) ->
    lists:foldl(fun(Role, {Actions, Acc}) ->
                        #{Role := Backlog} = Acc,
                        case batch(Role, Now, System, Backlog) of
                            none -> {Actions, Acc};
                            {Action, Rest} -> {Actions ++ [Action], Acc#{Role := Rest}}
                        end
                end, {[], Consumers}, [console, store]).

%% The batch of a waiting role whose batch is due, and the backlog after it.
batch(_Role, _Now, _System, #backlog{waiting = idle}) ->
    none;
batch(_Role, _Now, _System, #backlog{bytes = 0}) ->
    none;
batch(console, Now, System, #backlog{waiting = {waiting, Requester}, lines = Lines} = Backlog) ->
    Batch = [Line || {_Joined, _Family, Line} <- queue:to_list(Lines)],
    {{send, Requester, missed(Now, System, Backlog) ++ Batch},
     #backlog{}};
batch(store, Now, System, #backlog{waiting = {waiting, Requester}, lines = Lines, bytes = Bytes} = Backlog) ->
    {value, {Oldest, _, _}} = queue:peek(Lines),
    case Bytes >= ?STORE_BATCH_BYTES orelse Now - Oldest >= ?STORE_WAIT_NS of
        true ->
            {Taken, Left, LeftBytes} = take_batch(Lines, Bytes, 0, []),
            Missed = [{messages, Line} || Line <- missed(Now, System, Backlog)],
            {{send, Requester, Missed ++ Taken},
             #backlog{lines = Left, bytes = LeftBytes}};
        false ->
            none
    end.

%% The oldest lines of a store's backlog within STORE_BATCH_BYTES, at least one, and
%% what remains.
take_batch(Lines, Bytes, Size, Taken) ->
    case queue:out(Lines) of
        {{value, {_Joined, Family, Line}}, Rest}
          when Taken =:= [] orelse Size + byte_size(Line) + 1 =< ?STORE_BATCH_BYTES ->
            Cost = byte_size(Line) + 1,
            take_batch(Rest, Bytes - Cost, Size + Cost, [{Family, Line} | Taken]);
        _ ->
            {lists:reverse(Taken), Lines, Bytes}
    end.

%% The note at the head of a batch whose backlog dropped lines since the last.
missed(_Now, _System, #backlog{missed = 0}) ->
    [];
missed(Now, System, #backlog{missed = Missed}) ->
    [note(Now, System, iolist_to_binary([<<"erx_syslog: ">>, integer_to_binary(Missed),
                                         <<" lines missed">>]))].

joined(Now, Lines, Backlog) ->
    lists:foldl(fun({Family, Line}, #backlog{lines = Q, bytes = Bytes} = B)
                      when (Family =:= kernel orelse Family =:= messages), is_binary(Line) ->
                        B#backlog{lines = queue:in({Now, Family, Line}, Q),
                                  bytes = Bytes + byte_size(Line) + 1}
                end, Backlog, Lines).

%% A backlog within BACKLOG_BYTES: past it, its oldest lines go, counted.
bounded(#backlog{bytes = Bytes} = Backlog) when Bytes =< ?BACKLOG_BYTES ->
    Backlog;
bounded(#backlog{lines = Lines, bytes = Bytes, missed = Missed} = Backlog) ->
    {{value, {_Joined, _Family, Line}}, Rest} = queue:out(Lines),
    bounded(Backlog#backlog{lines = Rest, bytes = Bytes - byte_size(Line) - 1, missed = Missed + 1}).
