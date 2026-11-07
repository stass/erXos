%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx:trace in the system domain (docs/design-live.md, "Tracing"): the request, the
%% process that runs a trace, and the shell's printer.
%%
%% Data flow: check/3 turns the caller's Spec into a request or a refusal, purely, from
%% the caller's scope and what it can learn of each selected pid. start/3 spawns the
%% trace process, which opens an OTP trace session over the selection (flags running and
%% monotonic_timestamp) and starts each ring at the present with erx_trace_ring:read/3.
%% Its loop takes every message as it arrives and classify/2, the one definition of what
%% the trace process accepts, names it: a session message joins the round's batch (at
%% most ?DRAIN of them, the rest counted as dropped), and every 10 ms a tick takes the
%% clock pair, reads the rings, feeds the batch and the reads to erx_tracer, and sends
%% what it releases to the receiver as {erx_trace, Ref, Entry} through the window.
%%
%% The window is the flow control: the trace has at most ?WINDOW entries out beyond those
%% the receiver acknowledged, and the receiver acknowledges with {erx_trace_ack, Ref}
%% after every ?ACK_EVERY entries it handled (handled/2). An entry that finds the window
%% shut is dropped and counted by row; once the window opens, the next round hands the
%% merger one dropped entry per row, with the count, at the round's time (report/3), and
%% it goes out in time order like any other entry. So a slow or stuck receiver holds at
%% most ?WINDOW entries, and the trace process keeps counters for it, never a queue.
%% What the trace process itself holds, the round's batch, the merger's held entries and
%% the session messages in its mailbox, is bounded by its heap: it runs with a
%% max_heap_size of ?MAX_HEAP_WORDS that kills it, and the receiver sees the end.
%%
%% The trace's reference is the trace process's alias, so stop/1 needs no table. The
%% trace ends when stop/1 is called, the receiver ends, or the caller dies before it has
%% the reference; the session ends with the process. The receiver learns the end from a
%% monitor of the trace process: it ends normal after a stop, and any other reason, a
%% heap past its bound (killed) included, is a failure. The trace process and the printer
%% are spawned with {erx_untraced, true} (OTP edit 52 of design-runtime.md), so no trace
%% session, theirs or another's, ever sees them run.
%%
%% Nothing from a traced process is trusted: a session message reaches erx_tracer only
%% in the shape ERTS sends for the running flag with a timestamp, and every field of
%% every entry is printed raw and then escaped once, as the whole line.

-module(erx_trace).
-moduledoc """
erx:trace/1 and erx:trace_stop/1 in the system domain: the request's check, the
trace process over an OTP trace session and the trace rings, its window towards the
receiver, and the shell's printer of its stream, one escaped line per entry.
""".

-export([check/3, start/3, stop/1, handled/2, print/2, line/1]).
%% The trace process's pure decisions, exported for test/erlang/erx_trace_tests.erl.
-export([classify/2, window/0, deliver/2, report/3, acked/1, buffer/3, cursor/3]).
%% The caller's wait for the trace process's answer, exported for the same tests.
-export([await_start/3]).
-export_type([spec/0, request/0, scope/0, domain_id/0, window/0]).

%% The system domain's id, its node's creation (docs/design-domains.md: no node has a
%% creation below 4). In Phase 1 every process this runtime sees is the system
%% domain's.
-define(SYSTEM_DOMAIN, 4).
-define(MAX_SELECT, 16).
-define(MAX_DOMAIN, 16#ffffffff).
-define(TICK_MS, 10).
%% Nanoseconds in a second: erx_clock_ns, the entries' time, printed as seconds.
-define(NS_PER_S, 1000000000).
%% The most records one read asks for, and the most reads of one ring in one round:
%% eight full reads cover the stopgap's whole ring of 4,096 records.
-define(READ_MAX, 512).
-define(READS_PER_ROUND, 8).
%% The most session messages one round's batch holds; the rest are dropped and counted.
-define(DRAIN, 4096).
%% The entries out beyond those acknowledged, and how many one acknowledgement covers.
-define(WINDOW, 256).
-define(ACK_EVERY, 64).
-define(FLAGS, [running, monotonic_timestamp]).
%% The trace's own processes are spawned untraced (OTP edit 52), so no session sees them.
-define(OWN, [{erx_untraced, true}]).
%% The trace process's heap, its on-heap mailbox included, in words (16 MiB with 64-bit
%% words): past it ERTS kills the process at a garbage collection, so neither a flood of
%% session messages nor the merger's held entries can exhaust the system domain. An
%% estimate, not a measurement: a full round is 4,096 session messages and 4,096 entries
%% per ring read, some 25 words an entry, and about two rounds are held, some 600,000
%% words for the erts row and the backend ring; each kernel ring adds about 200,000.
-define(MAX_HEAP_WORDS, 2097152).
-define(TRACE_OPTS, [{max_heap_size, #{size => ?MAX_HEAP_WORDS, kill => true}},
                     {message_queue_data, on_heap} | ?OWN]).

-type domain_id() :: 0..16#ffffffff.
-type spec() :: #{select => [pid() | domain_id()], frames => boolean(), kernel => boolean()}.
%% The caller's trace facet: none, scope all, or the domains of a scoped facet.
-type scope() :: none | all | [domain_id()].
-type request() :: #{select := [pid() | domain_id()], frames := boolean(), kernel := boolean()}.
-type reason() :: badarg | no_facet | scope.
%% A trace process that ended before it answered, with its exit reason.
-type failure() :: {failed, term()}.

%% The messages the trace process accepts, as classify/2 names them; it ignores any other.
%%   {timeout, Timer, tick}       its own round timer, the current one only
%%   {erx_trace_stop, Ref}        stop/1
%%   {erx_trace_ack, Ref}         the receiver handled ?ACK_EVERY more entries
%%   {'DOWN', Monitor, ...}       the receiver ended (its monitor only)
%%   {trace_ts, Pid, Tag, Mfa, T} its session's running event, Tag in, out or their kin
-type message() :: tick | stop | ack | receiver_down | {session, tuple()} | ignore.
%% What a message must match to be the trace process's: its reference, its round timer,
%% its monitor of the receiver, and whether it has a session.
-type expect() :: #{ref := reference(), timer := reference() | none, receiver := reference(),
                    session := boolean()}.

%% credit: entries the trace may still send. dropped: entries not sent, by row, since the
%% last report of them (report/3).
-record(window, {credit = ?WINDOW :: 0..?WINDOW,
                 dropped = #{} :: #{erx_tracer:row() => pos_integer()}}).
-opaque window() :: #window{}.
%% The round batch of session messages: their count and the messages, newest first.
-type batch() :: {0..?DRAIN, [tuple()]}.
-type cursor() :: present | non_neg_integer().

-doc """
The request for Spec under Scope, or the refusal: `badarg` for anything but a spec()
map, an unknown key, more than 16 selections, no selection with `kernel` false, or
`frames` with no selection; `no_facet` without a trace facet; `scope` for a selection
outside the scope, an unknown domain id or a pid that names no live process included,
or `kernel` without scope `all`. DomainOf answers the domain of a live pid, or error.
""".
-spec check(term(), scope(), fun((pid()) -> {ok, domain_id()} | error)) ->
          {ok, request()} | {error, reason()}.
check(Spec, Scope, DomainOf) ->
    case parse(Spec) of
        {ok, Request} -> admit(Request, Scope, DomainOf);
        error -> {error, badarg}
    end.

-doc """
Starts a trace of Spec under Scope whose entries go to Receiver as
`{erx_trace, Ref, Entry}`; Receiver acknowledges them with handled/2 and may monitor
the returned pid to learn when the trace ends. The trace ends when Receiver ends,
stop(Ref) is called, the caller dies before this returns, or the trace process passes
its heap bound (reason killed). `{error, {failed, Why}}` when the trace process ends
before it answers, `Why` its exit reason.
""".
-spec start(term(), scope(), pid()) -> {ok, reference(), pid()} | {error, reason() | failure()}.
start(Spec, Scope, Receiver) when is_pid(Receiver) ->
    run(Spec, Scope, Receiver).

-doc "Ends the trace whose reference is Ref; a trace already ended is left as it is.".
-spec stop(reference()) -> ok.
stop(Ref) when is_reference(Ref) ->
    Ref ! {erx_trace_stop, Ref},
    ok.

-doc """
A receiver's count of the entries of trace Ref it handled since its last
acknowledgement, after one more: every ?ACK_EVERY (64) it acknowledges them and the
count starts again. A receiver calls it once per entry, starting from 0.
""".
-spec handled(reference(), non_neg_integer()) -> non_neg_integer().
handled(Ref, Count) when Count + 1 >= ?ACK_EVERY ->
    Ref ! {erx_trace_ack, Ref},
    0;
handled(_Ref, Count) ->
    Count + 1.

-doc """
Starts a trace of Spec under Scope that prints in the caller's shell: the trace
process spawns a printer, which writes line/1 of each entry to the caller's group
leader, and one line naming the reason if the trace fails, and ends with the trace;
`{error, {failed, Why}}` as for start/3.
""".
-spec print(term(), scope()) -> {ok, reference()} | {error, reason() | failure()}.
print(Spec, Scope) ->
    case run(Spec, Scope, printer) of
        {ok, Ref, _Trace} -> {ok, Ref};
        {error, _Reason} = Error -> Error
    end.

-doc """
The printed line of an entry: the time in seconds, the row, the event, each field as
name=value (pid and domain first, cpu, thread and space last, the rest by name), the
reporter's label in brackets and `late` after a late entry; the whole line goes
through erx_text:escape_line/1, so no field can end it or carry a control character.
""".
-spec line(erx_tracer:entry()) -> binary().
line(#{time := Time, row := Row, event := Event, fields := Fields, reporter := Reporter, late := Late}) ->
    Text = [seconds(Time), $\s, atom_to_binary(Row), $\s, value(Event),
            [[$\s, atom_to_binary(Key), $=, value(maps:get(Key, Fields))] || Key <- field_order(Fields)],
            " [", label(Reporter), $], late(Late)],
    <<(erx_text:escape_line(Text))/binary, $\n>>.

%%% The trace process's pure decisions.

-doc """
What Message is to a trace process that expects Expect: its current round timer's
`tick`, a `stop` or an `ack` with its reference, `receiver_down` from its monitor of the
receiver, `{session, Message}` for a running event in the shape ERTS sends it (a pid,
`in`, `out` or their kin, an MFA or 0, and an integer timestamp) when it has a session,
and `ignore` for anything else, which it drops.
""".
-spec classify(term(), expect()) -> message().
classify({timeout, Timer, tick}, #{timer := Timer}) when is_reference(Timer) ->
    tick;
classify({erx_trace_stop, Ref}, #{ref := Ref}) ->
    stop;
classify({erx_trace_ack, Ref}, #{ref := Ref}) ->
    ack;
classify({'DOWN', Monitor, process, _Pid, _Why}, #{receiver := Monitor}) ->
    receiver_down;
classify({trace_ts, Pid, Tag, Mfa, Time} = Message, #{session := true})
  when is_pid(Pid), is_integer(Time),
       (Tag =:= in orelse Tag =:= out orelse Tag =:= in_exiting orelse Tag =:= out_exiting orelse
        Tag =:= out_exited) ->
    case running_mfa(Mfa) of
        true -> {session, Message};
        false -> ignore
    end;
classify(_Message, _Expect) ->
    ignore.

running_mfa(0) -> true;
running_mfa({Module, Function, Arity}) when is_atom(Module), is_atom(Function), is_integer(Arity), Arity >= 0 -> true;
running_mfa(_Other) -> false.

-doc "A window open for ?WINDOW (256) entries, with nothing dropped.".
-spec window() -> window().
window() ->
    #window{}.

-doc """
The entries to send of Entries and the window after them: as many as the window
allows; the rest are counted as dropped by row, a dropped entry with its count.
""".
-spec deliver(window(), [erx_tracer:entry()]) -> {window(), [erx_tracer:entry()]}.
deliver(#window{credit = Credit} = Window, Entries) ->
    {Send, Rest} = lists:split(min(Credit, length(Entries)), Entries),
    {lists:foldl(fun undelivered/2, Window#window{credit = Credit - length(Send)}, Rest), Send}.

undelivered(#{row := Row, event := dropped, fields := #{count := Count}}, Window) -> drop(Row, Count, Window);
undelivered(#{row := Row}, Window) -> drop(Row, 1, Window).

-doc """
Window's drops reported to Merger at Now: while the window is open, one dropped entry
per row, with the count and the time Now, joins the merger as any other entry does
(erx_tracer:hold/2), so it goes out in time order, after every entry held from before
Now. Returns the window without them, the merger, and what goes out at once.
""".
-spec report(window(), erx_tracer:merger(), non_neg_integer()) ->
          {window(), erx_tracer:merger(), [erx_tracer:entry()]}.
report(#window{credit = 0} = Window, Merger, _Now) ->
    {Window, Merger, []};
report(#window{dropped = Dropped} = Window, Merger, Now) ->
    {Merger1, Late} = erx_tracer:hold(Merger, dropped_entries(Dropped, Now)),
    {Window#window{dropped = #{}}, Merger1, Late}.

dropped_entries(Dropped, Now) ->
    [erx_tracer:dropped(Row, Count, Now) || {Row, Count} <- lists:sort(maps:to_list(Dropped))].

-doc """
The window after the receiver acknowledged ?ACK_EVERY (64) entries; it never opens
past ?WINDOW, however many acknowledgements arrive.
""".
-spec acked(window()) -> window().
acked(#window{credit = Credit} = Window) ->
    Window#window{credit = min(?WINDOW, Credit + ?ACK_EVERY)}.

-doc """
A session message added to the round's batch (a count and the messages, newest first),
or, once the batch holds ?DRAIN (4,096), counted as a dropped erts entry instead.
""".
-spec buffer(tuple(), batch(), window()) -> {batch(), window()}.
buffer(Message, {Count, Messages}, Window) when Count < ?DRAIN ->
    {{Count + 1, [Message | Messages]}, Window};
buffer(_Message, Batch, Window) ->
    {Batch, drop(erts, 1, Window)}.

-doc """
The rings still read after Source's read Result: a ring moves to the read's next
cursor, and is read again at once when the read returned the most it asked for
(?READ_MAX, 512); a refused ring is read no more.
""".
-spec cursor(#{erx_tracer:source() => cursor()}, erx_tracer:source(), term()) ->
          {Again :: boolean(), #{erx_tracer:source() => cursor()}}.
cursor(Cursors, Source, {ok, Records, Next, _Overwritten}) ->
    {length(Records) =:= ?READ_MAX, Cursors#{Source := Next}};
cursor(Cursors, Source, {error, _Status}) ->
    {false, maps:remove(Source, Cursors)}.

drop(Row, Count, #window{dropped = Dropped} = Window) ->
    Window#window{dropped = maps:update_with(Row, fun(Old) -> Old + Count end, Count, Dropped)}.

%%% The request.

parse(Spec) when is_map(Spec) ->
    Select = maps:get(select, Spec, []),
    Frames = maps:get(frames, Spec, false),
    Kernel = maps:get(kernel, Spec, false),
    Valid = maps:size(maps:without([select, frames, kernel], Spec)) =:= 0 andalso
        selection(Select, ?MAX_SELECT) andalso is_boolean(Frames) andalso is_boolean(Kernel),
    case Valid of
        true when Select =:= [], not Kernel -> error;
        true when Select =:= [], Frames -> error;
        true -> {ok, #{select => Select, frames => Frames, kernel => Kernel}};
        false -> error
    end;
parse(_Spec) ->
    error.

%% A proper list of at most Left pids and domain ids, walked no further than its bound.
selection([], _Left) -> true;
selection([_ | _], 0) -> false;
selection([Pid | Rest], Left) when is_pid(Pid) -> selection(Rest, Left - 1);
selection([Id | Rest], Left) when is_integer(Id), Id >= 0, Id =< ?MAX_DOMAIN -> selection(Rest, Left - 1);
selection(_Other, _Left) -> false.

admit(_Request, none, _DomainOf) ->
    {error, no_facet};
admit(#{kernel := true}, Scope, _DomainOf) when Scope =/= all ->
    {error, scope};
admit(#{select := Select} = Request, Scope, DomainOf) ->
    case lists:all(fun(Selection) -> visible(Selection, Scope, DomainOf) end, Select) of
        true -> {ok, Request};
        false -> {error, scope}
    end.

%% A selection is visible when it names a domain that exists, or a live process, and
%% that domain is within the scope; an unknown id answers as one outside the scope.
visible(Pid, Scope, DomainOf) when is_pid(Pid) ->
    case DomainOf(Pid) of
        {ok, Domain} -> in_scope(Domain, Scope);
        error -> false
    end;
visible(Domain, Scope, _DomainOf) ->
    lists:member(Domain, domains()) andalso in_scope(Domain, Scope).

in_scope(_Domain, all) -> true;
in_scope(Domain, Domains) -> lists:member(Domain, Domains).

%% The domains this runtime can trace: in Phase 1, its own.
domains() -> [?SYSTEM_DOMAIN].

%% A live process of this runtime is the system domain's; any other pid names nothing
%% this runtime can trace.
domain_of(Pid) when node(Pid) =:= node() ->
    case is_process_alive(Pid) of
        true -> {ok, ?SYSTEM_DOMAIN};
        false -> error
    end;
domain_of(_Pid) ->
    error.

%%% The trace process.

%% expect: what a message must match to be this trace's (classify/2). cursors: the rings
%% still read, each at its next cursor; a refused ring leaves the map. batch: the
%% round's session messages so far. window: the flow control towards the receiver.
-record(trace, {expect :: expect(),
                receiver :: pid(),
                session :: trace:session() | none,
                cursors :: #{erx_tracer:source() => cursor()},
                merger :: erx_tracer:merger(),
                batch = {0, []} :: batch(),
                window = window() :: window()}).

run(Spec, Scope, Target) ->
    case check(Spec, Scope, fun domain_of/1) of
        {ok, Request} -> spawn_trace(Request, Target);
        {error, _Reason} = Error -> Error
    end.

spawn_trace(Request, Target) ->
    Caller = self(),
    Tag = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() -> trace_init(Request, Target, Caller, Tag) end, [monitor | ?TRACE_OPTS]),
    await_start(Pid, Monitor, Tag).

%% The trace process's answer to its caller, who takes it. A trace process that ends
%% before it answers, killed at its heap bound or by a fault, has started nothing the
%% caller could stop, so the caller is told of the failure with its reason.
-doc false.
-spec await_start(pid(), reference(), reference()) ->
          {ok, reference(), pid()} | {error, reason() | failure()}.
await_start(Pid, Monitor, Tag) ->
    receive
        {Tag, Reply} ->
            erlang:demonitor(Monitor, [flush]),
            Pid ! {Tag, taken},
            Reply;
        {'DOWN', Monitor, process, Pid, Why} ->
            {error, {failed, Why}}
    end.

%% The session opens first, so a refusal leaves no printer behind. Then the receiver
%% exists and is monitored before the rings' first read, so their first entries have
%% somewhere to go, and a receiver already ended answers its monitor at once, which ends
%% the trace. The caller is watched until it has taken the reply: a caller that dies
%% during the start would leave a trace nobody can stop, so the trace closes instead.
trace_init(#{select := Select, kernel := Kernel}, Target, Caller, Tag) ->
    CallerMonitor = erlang:monitor(process, Caller),
    case open_session(Select) of
        {ok, Session} ->
            Ref = alias(),
            Receiver = receiver(Target, Ref),
            Rings = case Kernel of
                        true -> [backend | [{kernel, Cpu} || Cpu <- lists:seq(0, cpus() - 1)]];
                        false -> []
                    end,
            Erts = [{erts, ?SYSTEM_DOMAIN} || Select =/= []],
            Expect = #{ref => Ref, timer => none, receiver => erlang:monitor(process, Receiver),
                       session => Session =/= none},
            Trace0 = #trace{expect = Expect, receiver = Receiver, session = Session,
                            cursors = maps:from_keys(Rings, present), merger = erx_tracer:new(Erts ++ Rings)},
            %% One read of each ring from the present starts it, or shows its refusal.
            {_Monotonic, Now} = erx_trace_ring:clocks(),
            Trace = read_rings(Trace0, Now, 1),
            Caller ! {Tag, {ok, Ref, self()}},
            receive
                {Tag, taken} ->
                    erlang:demonitor(CallerMonitor, [flush]),
                    loop(arm(Trace));
                {'DOWN', CallerMonitor, process, Caller, _Why} ->
                    close(Trace)
            end;
        error ->
            Caller ! {Tag, {error, scope}}
    end.

receiver(printer, Ref) ->
    Trace = self(),
    spawn_opt(fun() -> printer(Ref, Trace) end, ?OWN);
receiver(Receiver, _Ref) when is_pid(Receiver) ->
    Receiver.

%% The trace session over the selection: each pid, and for the system domain every
%% process of this runtime, which leaves out the trace's own processes since they are
%% spawned untraced. A pid that ended since check/3 looked answers as one outside the scope.
open_session([]) ->
    {ok, none};
open_session(Select) ->
    Session = trace:session_create(erx_trace, self(), []),
    try
        lists:foreach(fun(Selection) -> select(Session, Selection) end, Select),
        {ok, Session}
    catch
        error:badarg ->
            trace:session_destroy(Session),
            error
    end.

select(Session, Pid) when is_pid(Pid) -> trace:process(Session, Pid, true, ?FLAGS);
select(Session, ?SYSTEM_DOMAIN) -> trace:process(Session, all, true, ?FLAGS).

%% The kernel's CPUs, one ring each, as ERTS counts them.
cpus() ->
    case erlang:system_info(logical_processors) of
        Count when is_integer(Count), Count > 0 -> Count;
        _Unknown -> 1
    end.

%% Every message is taken as it arrives and named once, so nothing waits in the mailbox
%% for a later receive to skip.
loop(#trace{expect = Expect} = Trace) ->
    receive
        Message ->
            case classify(Message, Expect) of
                tick -> loop(arm(step(Trace)));
                stop -> finish(Trace);
                receiver_down -> close(Trace);
                Other -> loop(absorb(Other, Trace))
            end
    end.

%% A session message joins the batch, an acknowledgement opens the window, and anything
%% else is dropped.
absorb({session, Message}, #trace{batch = Batch, window = Window} = Trace) ->
    {Batch1, Window1} = buffer(Message, Batch, Window),
    Trace#trace{batch = Batch1, window = Window1};
absorb(ack, #trace{window = Window} = Trace) ->
    Trace#trace{window = acked(Window)};
absorb(_Message, Trace) ->
    Trace.

arm(#trace{expect = Expect} = Trace) ->
    Trace#trace{expect = Expect#{timer := erlang:start_timer(?TICK_MS, self(), tick)}}.

%% One round: the clock pair for the batch, every ring read from its cursor, the batch,
%% the window's drops so far, and what the merger lets go out by now.
step(Trace0) ->
    {_Monotonic, Now} = Pair = erx_trace_ring:clocks(),
    #trace{batch = {_Count, Batch}} = Trace1 = read_rings(Trace0, Now, ?READS_PER_ROUND),
    Messages = lists:reverse(Batch),
    #trace{window = Window, merger = Merger} = Trace2 =
        merge(Trace1#trace{batch = {0, []}}, fun(M) -> erx_tracer:erts(M, ?SYSTEM_DOMAIN, Messages, Pair, Now) end),
    {Window1, Merger1, Late} = report(Window, Merger, Now),
    Trace3 = send(Trace2#trace{window = Window1, merger = Merger1}, Late),
    merge(Trace3, fun(M) -> erx_tracer:release(M, Now) end).

read_rings(#trace{cursors = Cursors} = Trace, Now, Reads) ->
    lists:foldl(fun(Source, Acc) -> read_ring(Acc, Source, Now, Reads) end, Trace, maps:keys(Cursors)).

read_ring(Trace, _Source, _Now, 0) ->
    Trace;
read_ring(#trace{cursors = Cursors} = Trace, Source, Now, Left) ->
    Result = erx_trace_ring:read(Source, maps:get(Source, Cursors), ?READ_MAX),
    {Again, Cursors1} = cursor(Cursors, Source, Result),
    Read = merge(Trace#trace{cursors = Cursors1}, fun(Merger) -> erx_tracer:ring(Merger, Source, Result, Now) end),
    case Again of
        true -> read_ring(Read, Source, Now, Left - 1);
        false -> Read
    end.

%% Feeds the merger and delivers what it lets out.
merge(#trace{merger = Merger} = Trace, Feed) ->
    {Merger1, Out} = Feed(Merger),
    send(Trace#trace{merger = Merger1}, Out).

send(#trace{expect = #{ref := Ref}, receiver = Receiver, window = Window} = Trace, Entries) ->
    {Window1, Send} = deliver(Window, Entries),
    erx_tracer:emit(Receiver, Ref, Send),
    Trace#trace{window = Window1}.

%% Stopped: the session ends first, the messages it already sent are taken, a last round
%% runs, and what is still held goes out, so the stream ends with the last events. Rows
%% still counting dropped entries are reported last, even past the window: at most one
%% entry per row more.
finish(#trace{session = Session} = Trace0) ->
    destroy(Session),
    #trace{expect = #{ref := Ref}, receiver = Receiver, window = Window} =
        merge(step(drain(Trace0, ?DRAIN)), fun erx_tracer:flush/1),
    {_Monotonic, Now} = erx_trace_ring:clocks(),
    erx_tracer:emit(Receiver, Ref, dropped_entries(Window#window.dropped, Now)),
    unalias(Ref),
    ok.

%% The receiver ended: there is nobody to deliver to.
close(#trace{expect = #{ref := Ref}, session = Session}) ->
    destroy(Session),
    unalias(Ref),
    ok.

%% At most Left messages already in the mailbox, each named as the loop names it.
drain(Trace, 0) ->
    Trace;
drain(#trace{expect = Expect} = Trace, Left) ->
    receive
        Message -> drain(absorb(classify(Message, Expect), Trace), Left - 1)
    after 0 ->
        Trace
    end.

destroy(none) -> ok;
destroy(Session) -> trace:session_destroy(Session).

%%% The shell's printer.

%% Prints each entry of trace Ref and acknowledges them; when the trace process ends it
%% ends too, after one line naming the reason if the trace failed.
printer(Ref, Trace) ->
    printer(Ref, erlang:monitor(process, Trace), 0).

printer(Ref, Monitor, Handled) ->
    receive
        {erx_trace, Ref, Entry} ->
            io:put_chars(line(Entry)),
            printer(Ref, Monitor, handled(Ref, Handled));
        {'DOWN', Monitor, process, _Trace, normal} ->
            ok;
        {'DOWN', Monitor, process, _Trace, noproc} ->
            %% The trace ended before this printer first ran, most likely after a
            %% stop, though a kill or a fault in that window looks the same: what it
            %% sent is printed above, and its reason is gone, so nothing is printed.
            ok;
        {'DOWN', Monitor, process, _Trace, Why} ->
            io:put_chars(failure(Why));
        _Other ->
            printer(Ref, Monitor, Handled)
    end.

failure(Why) ->
    <<(erx_text:escape_line(["erx:trace failed: ", io_lib:format("~tW", [Why, 12])]))/binary, $\n>>.

%%% The line.

%% erx_clock_ns as seconds with nine decimals, the seconds right-aligned in at least five
%% columns: a wider count widens the column, where io_lib's fixed width would print stars.
seconds(Time) ->
    [string:pad(integer_to_binary(Time div ?NS_PER_S), 5, leading), $., io_lib:format("~9..0w", [Time rem ?NS_PER_S])].

field_order(Fields) ->
    First = [Key || Key <- [pid, domain], is_map_key(Key, Fields)],
    Last = [Key || Key <- [cpu, thread, space], is_map_key(Key, Fields)],
    First ++ lists:sort(maps:keys(Fields) -- (First ++ Last)) ++ Last.

%% A value as written: an atom, a pid, an integer and an MFA raw, so the line escape
%% alone decides what reaches the terminal; any other term as io_lib writes it.
value(Atom) when is_atom(Atom) -> atom_to_binary(Atom);
value(Integer) when is_integer(Integer) -> integer_to_binary(Integer);
value(Pid) when is_pid(Pid) -> pid_to_list(Pid);
value({Module, Function, Arity}) when is_atom(Module), is_atom(Function), is_integer(Arity) ->
    [atom_to_binary(Module), $:, atom_to_binary(Function), $/, integer_to_binary(Arity)];
value({unknown, Value}) when is_integer(Value) -> ["unknown(", integer_to_binary(Value), $)];
value(Term) -> io_lib:format("~tw", [Term]).

label(Reporter) ->
    {ok, Label} = erx_schema:reporter_label(Reporter),
    Label.

late(true) -> " late";
late(false) -> [].
