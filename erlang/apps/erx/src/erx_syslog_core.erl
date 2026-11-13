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

Times are nanoseconds of a monotonic clock that does not go below zero,
such as os:perf_counter(nanosecond). Nothing here reads a clock, sends a
message or keeps state between calls.
""".

-include("generated/erx_abi.hrl").

-export([line/5, new/1, write/4, turn/3]).
-export_type([source/0, log_record/0, table/0]).

-define(NS_PER_S, 1000000000).
-define(NS_PER_US, 1000).

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
