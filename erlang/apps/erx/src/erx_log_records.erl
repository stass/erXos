%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_log_records).
-moduledoc """
The collector of `[kernel, log]` (docs/design-live.md, "Inspection
records"): the kernel log's lines from a sequence number on, read with
erx_log:read/1 from a cursor of the inspector's own, so nothing the
console or another reader sees moves. A session that holds the `log`
facet, root's in a development build, makes each read through the system
domain, which alone reads the log on the stopgap kernel (erx_log_facet).

The record's entries are `{Sequence, Line}`, each line as the log core
rendered it, without its newline, so every byte of it is already escaped.
A record's sequence number is its place in the log, which is the cursor
erx_log:read/1 takes: a read from Cursor that lost Lost records returns
the records from Cursor + Lost on, in order, so the Nth line is record
Cursor + Lost + N - 1. A read that stopped at a record failing the
reader's checks (`corrupt`) still moves its cursor past that record, so
the numbers between the last line and the read's next cursor are records
the log holds and the read could not show. Lost and unreadable records
are left out, and the gap in the sequence numbers, which a renderer shows
as missing, is what says so; no line stands in for them.

A query gives at most a page of entries, erx_schema's 1,000, and makes at
most a page of reads. It ends `ok` at a read that finds nothing past its
cursor, the log's end, and `partial` when it stops before that: its page
is full, its reads are spent, or a read after the first is refused. Every
read but the last moves the cursor at least one record, so a log that
grows while it is read still ends the query.

record/2, the core, takes the read as a function, so every case is tested
with made-up reads.
""".

-export([log/1, record/2]).
-export_type([read/0]).

-include("generated/erx_abi.hrl").

%% The most entries, and the most reads, of one query: erx_schema's page.
-define(PAGE, 1000).
-define(U64, 16#ffffffffffffffff).

-type read() :: fun((non_neg_integer()) -> erx_log:lines()).
-type refusal() :: invalid | unsupported | failed.

-doc """
The record of `[kernel, log]` from the sequence number Offset on, read
from the kernel log, through the `log` facet where this domain holds one;
see record/2.
""".
-spec log(non_neg_integer()) -> {ok, erx_schema:record()} | {error, refusal()}.
log(Offset) ->
    record(Offset, erx_log_facet:read_fun(maps:get(log, erx_facets:domain(), undefined))).

-doc """
The record of `[kernel, log]` from Offset on, as Read answers: its
entries the lines from Offset on, each with its sequence number, and Next
the number the following query starts from. An Offset past the log's
newest record is `{error, invalid}`, a log this domain cannot read
`{error, unsupported}`, and any other refusal of the first read, or a
read whose counts do not add up, `{error, failed}`. A refusal after the
first read ends the entries there, as `partial`.
""".
-spec record(non_neg_integer(), read()) -> {ok, erx_schema:record()} | {error, refusal()}.
record(Offset, Read) when is_integer(Offset), Offset >= 0, Offset =< ?U64 ->
    case Read(Offset) of
        {error, Status} ->
            {error, refusal(Status)};
        Answer ->
            case fold(Offset, Answer, Read, ?PAGE, ?PAGE - 1, []) of
                {ok, Entries} ->
                    {ok, _} = erx_schema:validate_record(#{schema => erx_schema:schema(),
                                                           path => [kernel, log], kind => log, id => log,
                                                           attrs => #{}, children => [],
                                                           entries => Entries});
                {error, failed} = Error ->
                    Error
            end
    end;
record(_Offset, _Read) ->
    {error, invalid}.

%% Folds the read Answer from Cursor into Kept, the entries so far, newest
%% first, with Room entries and Reads more reads left; the entries, oldest
%% first, with their status and Next, or {error, failed} for a read whose
%% counts do not add up.
fold(Cursor, {Whole, Next, Lost, Lines}, Read, Room, Reads, Kept)
  when Whole =:= ok orelse Whole =:= corrupt, is_integer(Next), is_integer(Lost), Lost >= 0,
       is_list(Lines), Cursor + Lost + length(Lines) =< Next, Next =< ?U64 ->
    First = Cursor + Lost,
    Taken = lists:sublist(Lines, Room),
    Numbered = lists:zip(lists:seq(First, First + length(Taken) - 1), [line(Line) || Line <- Taken]),
    Entries = lists:reverse(Numbered, Kept),
    Left = Room - length(Taken),
    case stop(Cursor, Next, length(Taken) < length(Lines), Left, Reads) of
        page_full -> {ok, {partial, First + length(Taken), lists:reverse(Entries)}};
        log_end -> {ok, {ok, Next, lists:reverse(Entries)}};
        short -> {ok, {partial, Next, lists:reverse(Entries)}};
        continue -> fold(Next, Read(Next), Read, Left, Reads - 1, Entries)
    end;
fold(Cursor, {error, _Status}, _Read, _Room, _Reads, Kept) ->
    {ok, {partial, Cursor, lists:reverse(Kept)}};
fold(_Cursor, _Answer, _Read, _Room, _Reads, _Kept) ->
    {error, failed}.

%% Why a query stops after a read from Cursor that ended at Next, if it
%% does: its page filled in the middle of the read (Cut is true), so it stops past
%% the last line kept; the read found nothing, the log's end; or its page
%% is full or its reads are spent at Next, short of the end.
stop(_Cursor, _Next, true, _Left, _Reads) -> page_full;
stop(Cursor, Cursor, false, _Left, _Reads) -> log_end;
stop(_Cursor, _Next, false, Left, Reads) when Left =:= 0; Reads =:= 0 -> short;
stop(_Cursor, _Next, false, _Left, _Reads) -> continue.

%% A line without the newline the log core ends it with.
line(Line) when is_binary(Line), byte_size(Line) > 0, binary_part(Line, byte_size(Line) - 1, 1) =:= <<"\n">> ->
    binary_part(Line, 0, byte_size(Line) - 1);
line(Line) when is_binary(Line) ->
    Line.

refusal(?ERX_EINVAL) -> invalid;
refusal(?ERX_ENOTSUP) -> unsupported;
refusal(_Status) -> failed.
