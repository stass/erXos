%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx:trace's merger (docs/design-live.md, "Tracing"): the pure core that turns the
%% sources' reads into one stream of entry() ordered by erx_clock_ns. It reads no clock and
%% sends nothing itself; its caller reads the rings with erx_trace_ring:read/3, takes the
%% time with erx_trace_ring:clocks/0, feeds each batch here and sends what comes back with
%% emit/3.
%%
%% A source is one ring (backend, or {kernel, Cpu}) or one runtime's trace session
%% ({erts, Domain}); a row groups sources (erts, backend, kernel). Data flow: ring/4 and
%% erts/5 decode a batch into entries and hold them, and record the latest time the source
%% has shown: a ring is in time order, so a batch shows its latest record, or the read's
%% time when it had nothing new; a trace session's messages from different schedulers
%% arrive in no order, so a batch shows only what the session's previous batch did. A held
%% entry goes out once every source still waited for has shown its time, or once it is
%% 100 ms old. An entry older than one already sent goes out at once, marked late, never
%% dropped. A source whose read answers unsupported stops being waited for: a row the
%% kernel reports shows one unsupported entry, a stopgap's row is left out. A ring whose
%% read is refused with any other status shows one error entry with that status and stops
%% being waited for, and the trace goes on with the other sources. Every reporter
%% comes from erx_schema:trace_row/1, and every event name from erx_abi_events, so nothing
%% here makes an atom from a record.

-module(erx_tracer).
-moduledoc "erx:trace's merger: the sources' reads into one stream ordered by erx_clock_ns.".

-export([new/1, ring/4, erts/5, hold/2, release/2, flush/1, dropped/3, emit/3, convert/2]).
-export_type([merger/0, row/0, source/0, entry/0, clock_pair/0]).

-define(HOLD_NS, 100000000).

-type row() :: erts | backend | kernel.
-type source() :: backend | {kernel, non_neg_integer()} | {erts, non_neg_integer()}.
-type clock_pair() :: {Monotonic :: integer(), Clock :: non_neg_integer()}.
-type entry() :: #{time := non_neg_integer(),
                   row := row(),
                   event := atom() | {unknown, non_neg_integer()},
                   fields := #{atom() => term()},
                   reporter := erx_schema:reporter(),
                   late := boolean()}.

%% waiting: each source still waited for, as {Shown, Next}: Shown the latest time it has
%% shown (none before it has shown one), Next the time a trace session's last batch will
%% show with its next one. held: entries not yet sent, in time order. sent: the time of the
%% latest entry sent, or none. reported: the rows already shown as unsupported.
-record(merger, {waiting :: #{source() => {non_neg_integer() | none, non_neg_integer() | none}},
                 held = [] :: [entry()],
                 sent = none :: non_neg_integer() | none,
                 reported = [] :: [row()]}).
-opaque merger() :: #merger{}.

-doc "A merger waiting for each of Sources, the sources the trace's Spec selects.".
-spec new([source()]) -> merger().
new(Sources) ->
    lists:foreach(fun(Source) -> {ok, _} = erx_schema:trace_row(row(Source)) end, Sources),
    #merger{waiting = maps:from_keys(Sources, {none, none})}.

-doc """
Takes one erx_trace_ring:read/3 result of a ring, read at Now (erx_clock_ns, taken before
the read), and returns the entries that go out at once (late ones, a row's one unsupported
entry, and a ring's one error entry). A refused ring is no longer waited for; its caller
reads it no more.
""".
-spec ring(merger(), backend | {kernel, non_neg_integer()},
           {ok, [erx_trace_ring:ring_record()], non_neg_integer(), non_neg_integer()}
           | {error, atom()}, non_neg_integer()) -> {merger(), [entry()]}.
ring(#merger{waiting = Waiting, reported = Reported} = Merger, Source, {error, unsupported}, Now) ->
    Row = row(Source),
    Rest = Merger#merger{waiting = maps:remove(Source, Waiting)},
    case {reporter(Row), maps:is_key(Source, Waiting) andalso not lists:member(Row, Reported)} of
        {kernel, true} -> {Rest#merger{reported = [Row | Reported]}, [entry(Now, Row, unsupported, #{}, false)]};
        {_Reporter, _First} -> {Rest, []}
    end;
ring(#merger{waiting = Waiting} = Merger, Source, {error, Status}, Now) when is_atom(Status) ->
    %% Any other refusal (inval, limit, ...): one entry with the status and the row's
    %% reporter, whichever reporter it is, and the trace goes on without this ring.
    Rest = Merger#merger{waiting = maps:remove(Source, Waiting)},
    case maps:is_key(Source, Waiting) of
        true -> {Rest, [entry(Now, row(Source), error, refusal_fields(Source, Status), false)]};
        false -> {Rest, []}
    end;
ring(Merger, Source, {ok, Records, _Next, Overwritten}, Now) ->
    Row = row(Source),
    Entries = [record_entry(Row, Record) || Record <- Records],
    take(Merger, Source, overwritten(Row, Overwritten, Entries, Now) ++ Entries, Now).

-doc """
Takes one batch of OTP trace messages of Domain's processes, read with the clock pair
Pair taken for the batch, at Now (erx_clock_ns, taken before the batch was drained).
""".
-spec erts(merger(), non_neg_integer(), [tuple()], clock_pair(), non_neg_integer()) ->
          {merger(), [entry()]}.
erts(Merger, Domain, Messages, Pair, Now) ->
    take(Merger, {erts, Domain}, [erts_entry(Domain, Message, Pair) || Message <- Messages], Now).

-doc """
Holds Entries, a source's batch or entries of no source such as a trace's dropped
entries: an entry older than one already sent goes out at once, marked late, and the
rest join the held entries in time order. No source's shown time moves.
""".
-spec hold(merger(), [entry()]) -> {merger(), [entry()]}.
hold(#merger{held = Held, sent = Sent} = Merger, Entries) ->
    {Late, OnTime} = lists:partition(fun(#{time := Time}) -> Sent =/= none andalso Time < Sent end, Entries),
    {Merger#merger{held = lists:merge(fun before/2, Held, lists:sort(fun before/2, OnTime))},
     [Entry#{late := true} || Entry <- Late]}.

-doc "Every held entry, in time order, for a trace that ends: nothing is left behind.".
-spec flush(merger()) -> {merger(), [entry()]}.
flush(#merger{held = Held} = Merger) ->
    {Merger#merger{held = [], sent = latest(Merger#merger.sent, Held)}, Held}.

-doc "The dropped entry of Row at Time: Count of its entries were not delivered.".
-spec dropped(row(), pos_integer(), non_neg_integer()) -> entry().
dropped(Row, Count, Time) ->
    entry(Time, Row, dropped, #{count => Count}, false).

-doc "The held entries that may go out at Now, in time order.".
-spec release(merger(), non_neg_integer()) -> {merger(), [entry()]}.
release(#merger{held = Held} = Merger, Now) ->
    {Out, Kept} = lists:splitwith(fun(Entry) -> releasable(Merger, Entry, Now) end, Held),
    {Merger#merger{held = Kept, sent = latest(Merger#merger.sent, Out)}, Out}.

-doc "Sends each entry to Receiver as {erx_trace, Ref, Entry}.".
-spec emit(pid(), reference(), [entry()]) -> ok.
emit(Receiver, Ref, Entries) ->
    lists:foreach(fun(Entry) -> Receiver ! {erx_trace, Ref, Entry} end, Entries).

-doc """
An OTP monotonic timestamp in erx_clock_ns, by the difference of the batch's clock pair.
ERTS may slew its monotonic time after the wall clock is set, so the result is off by at
most that slew of the timestamp's distance from the pair.
""".
-spec convert(integer(), clock_pair()) -> integer().
convert(Monotonic, {PairMonotonic, PairClock}) ->
    Monotonic + (PairClock - PairMonotonic).

%% Holds a batch of Source (hold/2) and moves the source's shown time.
take(#merger{waiting = Waiting} = Merger, Source, Entries, Now) ->
    hold(Merger#merger{waiting = shown(Waiting, Source, batch_time(Entries, Now))}, Entries).

%% The time a batch shows of its source: its latest entry, or the read's time if empty.
batch_time([], Now) -> Now;
batch_time(Entries, _Now) -> lists:max([Time || #{time := Time} <- Entries]).

%% A ring shows its batch's time at once; a trace session shows it with its next batch.
%% A shown time never moves back. A source no longer waited for stays out.
shown(Waiting, Source, Time) ->
    case Waiting of
        #{Source := {Shown, Next}} ->
            {Shows, Pending} = case Source of
                               {erts, _Domain} -> {Next, Time};
                               _Ring -> {Time, none}
                           end,
            Waiting#{Source := {later(Shown, Shows), Pending}};
        #{} ->
            Waiting
    end.

later(none, Time) -> Time;
later(Shown, none) -> Shown;
later(Shown, Time) -> max(Shown, Time).

before(#{time := A}, #{time := B}) -> A =< B.

%% An entry goes out once it is 100 ms old, or once every source still waited for has
%% shown a time at or past it.
releasable(#merger{waiting = Waiting}, #{time := Time}, Now) ->
    Now - Time >= ?HOLD_NS orelse
        lists:all(fun({Shown, _Next}) -> Shown =/= none andalso Shown >= Time end, maps:values(Waiting)).

latest(Sent, []) -> Sent;
latest(_Sent, Out) -> maps:get(time, lists:last(Out)).

%% The overwritten entry of a read that lost records, at the time of its first kept record,
%% or of the read when it kept none.
overwritten(_Row, 0, _Entries, _Now) -> [];
overwritten(Row, Count, [], Now) -> [entry(Now, Row, overwritten, #{count => Count}, false)];
overwritten(Row, Count, [#{time := Time} | _], _Now) -> [entry(Time, Row, overwritten, #{count => Count}, false)].

%% The fields of a ring's error entry: the status, and the CPU of a kernel ring.
refusal_fields({kernel, Cpu}, Status) -> #{status => Status, cpu => Cpu};
refusal_fields(backend, Status) -> #{status => Status}.

row({kernel, _Cpu}) -> kernel;
row({erts, _Domain}) -> erts;
row(backend) -> backend.

entry(Time, Row, Event, Fields, Late) ->
    #{time => Time, row => Row, event => Event, fields => Fields, reporter => reporter(Row), late => Late}.

reporter(Row) ->
    {ok, Reporter} = erx_schema:trace_row(Row),
    Reporter.

%% A ring record, named by the generated tables: the event and its typed arguments, the
%% cpu (unknown when the record says so), the thread and the space.
record_entry(Row, {Time, Event, Cpu, Flags, Thread, Space, {A0, A1, A2}}) ->
    Base = #{cpu => cpu(Cpu, Flags), thread => Thread, space => Space},
    case erx_abi_events:describe(trace_event, Event) of
        unknown ->
            entry(Time, Row, {unknown, Event}, Base, false);
        {Name, Arguments} ->
            Named = lists:zip(Arguments, lists:sublist([A0, A1, A2], length(Arguments))),
            Fields = maps:merge(Base, maps:from_list([{Key, argument(Type, Word)} || {{Key, Type}, Word} <- Named])),
            entry(Time, Row, Name, Fields, false)
    end.

cpu(Cpu, Flags) ->
    {cpu_unknown, Mask} = lists:keyfind(cpu_unknown, 1, erx_abi_events:flags(trace_record_flags)),
    case Flags band Mask of
        0 -> Cpu;
        _ -> unknown
    end.

argument(u64, Word) -> Word;
argument(i64, Word) -> signed(Word);
argument(status, Word) ->
    case erx_abi_events:status(signed(Word)) of
        unknown -> {unknown, signed(Word)};
        Status -> Status
    end.

signed(Word) when Word >= 1 bsl 63 -> Word - (1 bsl 64);
signed(Word) -> Word.

%% An OTP trace message with a monotonic timestamp: its tag is the event, and its pid, the
%% domain and its other elements the fields; in and out and their kin carry mfa.
erts_entry(Domain, Message, Pair) ->
    [trace_ts, Pid, Tag | Rest] = tuple_to_list(Message),
    {Info, [Timestamp]} = lists:split(length(Rest) - 1, Rest),
    Fields = case {running(Tag), Info} of
                 {true, [Mfa]} -> #{pid => Pid, domain => Domain, mfa => Mfa};
                 {_, _} -> #{pid => Pid, domain => Domain, info => Info}
             end,
    entry(convert(Timestamp, Pair), erts, Tag, Fields, false).

running(Tag) -> lists:member(Tag, [in, out, in_exiting, out_exiting, out_exited]).
