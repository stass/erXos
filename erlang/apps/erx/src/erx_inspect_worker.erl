%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspect_worker).
-moduledoc """
A query worker of the system domain (docs/design-live.md, "The query
worker"): one process per inspector query, which collects what its own
runtime knows through erx_inspector's core and asks other domains' agents
(erx_inspect_agent) for what only their runtimes know, then sends the one
answer and exits.

* **Bounds.** It is spawned with `max_heap_size` inspect_worker_heap
  words, shared binaries counted, so OTP ends it past that, and its caller
  answers `{error, failed}`. It lives at most inspect_query_max
  milliseconds: at that deadline it asks no more and answers with what it
  has, a listing `partial` and each runtime attribute it had not collected
  `{timeout, inspect_query_max}`.
* **The agent leg.** It asks one agent at a time, `{erx_inspect_ask,
  Alias, Query}` with a fresh `reply` alias, and waits 500 ms for
  `{erx_origin, D, {Alias, Answer}}` from the domain D it asked. Its
  receive takes every message in arrival order and keeps only that one,
  so nothing else stays queued on it. An answer that misses its wait is
  `{timeout, 500}` and its alias is ended, so a late one is never
  delivered. An answer whose decoded size passes inspect_message_heap_min
  words is dropped as the funnel would drop it, and so reads as a timeout.
* **What it believes** (check/3). An answer is taken only when it agrees
  with the question: for `inspect` its record's path is the path asked,
  for `entries` each record's path is one process of the asked domain;
  each record's id is its path's last segment; every attribute is one the
  schema lets `runtime` report, and the worker marks it `runtime`
  whatever the frame said; and the record passes
  erx_schema:validate_record/1, so it holds no pid, port, reference or fun
  (V10). Anything else is dropped whole and reads
  `{error, invalid}` for each runtime
  attribute it would have given. Of a record it takes, every `proc_id()`
  of another domain is dropped from the attributes (owned/2), so an agent
  can misname only its own processes. Attributes no runtime reports, a
  process's `domain`, it gives itself.
* **The page.** A listing across domains is built by erx_inspector's
  page: the system domain's own entries, then each agent's in id order,
  each answer merged as it arrives and the rest of it dropped once the
  page is full, after which no more agents are asked. So it holds at most
  the page and one agent's answer.

Every answer passes erx_schema:validate_record/1 before it leaves (V10).

The view, which domains a scope covers and their agents, is injected, so
the host tests stand fake agents for domains; erx_inspector passes the
domain service's (erx_domain:inspect_view/1).
""".

-export([call/3, start/3, await/1]).
-export([check/3, owned/2]).

-include("generated/erx_abi.hrl").

-type query() :: {inspect, [erx_schema:segment()], map()} | {entries, [erx_schema:segment()]}.
-type agent() :: pid() | none | ended.
-type view() :: [{non_neg_integer(), agent()}].
%% view gives the domains a scope covers, `all` or `{principal, P}`;
%% agent_wait and query_max narrow the interface's waits for a test.
-type options() :: #{view := fun((all | {principal, pos_integer()}) -> {ok, view()} | unavailable),
                     agent_wait => pos_integer(), query_max => pos_integer()}.
-type answer() :: erx_inspector:answer() | erx_inspector:entries().
-type worker() :: {pid(), reference(), reference()}.
-export_type([query/0, view/0, options/0]).

%% The most entries one listing gives: the inspector's page.
-define(PAGE, 1000).
%% How long a worker waits for one agent's answer.
-define(AGENT_WAIT, 500).

%%% The caller's side.

-doc """
Runs Query in a worker at Scope and returns its answer, `{error, failed}`
when the worker ends without one.
""".
-spec call(query(), erx_inspector:query_scope(), options()) -> answer().
call(Query, Scope, Options) ->
    await(start(Query, Scope, Options)).

-doc """
Starts a worker for Query, monitored, whose answer comes to a `reply`
alias of the caller's: the worker's pid, the monitor and the alias, which
await/1 takes.
""".
-spec start(query(), erx_inspector:query_scope(), options()) -> worker().
start(Query, Scope, Options) ->
    Reply = alias([reply]),
    {Pid, Monitor} = spawn_opt(fun() -> run(Query, Scope, Reply, Options) end,
                               [monitor, {fullsweep_after, 0}, {max_heap_size, #{size => ?ERX_INSPECT_WORKER_HEAP, kill => true,
                                                           error_logger => true,
                                                           include_shared_binaries => true}}]),
    {Pid, Monitor, Reply}.

-doc "The answer of a worker start/3 started; `{error, failed}` if it ended first.".
-spec await(worker()) -> answer().
await({Pid, Monitor, Reply}) ->
    %% The worker's answer precedes its 'DOWN', both being its own signals.
    receive
        {Reply, Answer} ->
            demonitor(Monitor, [flush]),
            Answer;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            unalias(Reply),
            {error, failed}
    end.

%%% The worker.

run(Query, Scope, Reply, Options) ->
    Context = context(Scope, Options),
    Reply ! {Reply, leaving(answer(Query, Context))}.

%% What the query runs under: its deadline, the scope resolved to domain
%% ids, the domains it may ask with their agents, and whether the view is
%% known; an unknown view makes every listing partial.
context(Scope, Options) ->
    QueryMax = maps:get(query_max, Options, ?ERX_INSPECT_QUERY_MAX),
    Until = clock() + QueryMax,
    #{view := View} = Options,
    {Resolved, Domains, Known} = resolve(Scope, View(view_scope(Scope))),
    #{until => Until, query_max => QueryMax, agent_wait => maps:get(agent_wait, Options, ?AGENT_WAIT),
      scope => Resolved, domains => Domains, known => Known, self => erx_inspector:runtime_domain()}.

view_scope({principal, _} = Scope) -> Scope;
view_scope(_Scope) -> all.

resolve(all, {ok, View}) -> {all, View, true};
resolve(all, unavailable) -> {all, [], false};
resolve({principal, _}, {ok, View}) -> {[Id || {Id, _Agent} <- View], View, true};
resolve({principal, _}, unavailable) -> {[], [], false};
resolve(Ids, {ok, View}) when is_list(Ids) -> {Ids, [Entry || {Id, _} = Entry <- View, lists:member(Id, Ids)], true};
resolve(Ids, unavailable) when is_list(Ids) -> {Ids, [], false}.

answer({entries, [processes]}, Context) ->
    processes(Context);
answer({inspect, [processes] = Path, _Options}, Context) ->
    erx_inspector:listing(Path, processes(Context));
answer({inspect, Path, Options}, #{scope := Scope} = Context) ->
    case agent_domain(Path, Context) of
        {ok, Domain} -> remote(Path, Options, Domain, Context);
        local -> erx_inspector:inspect(Path, Scope, Options)
    end;
answer({entries, Path}, #{scope := Scope}) ->
    erx_inspector:entries(Path, Scope).

%% The domain whose agent knows Path's runtime attributes: a process or the
%% record of a domain other than this runtime's, which the scope reaches.
%% Every other path is collected here.
agent_domain(Path, #{scope := Scope, self := Self}) ->
    case {Path, erx_inspector:declared_reachable(Path, erx_schema:resolve(Path), Scope)} of
        {[processes, {pid, Domain, _, _}], {ok, _Owner}} when Domain =/= Self -> {ok, Domain};
        {[domains, Domain], {ok, _Owner}} when Domain =/= Self -> {ok, Domain};
        _ -> local
    end.

%% The record of Path of another domain: its runtime attributes from the
%% domain's agent, the rest given here. A domain the view does not hold, or
%% one that ended, names nothing; one without an agent, or any domain when
%% the view is unknown, has every runtime attribute unknown.
remote(Path, Options, Domain, #{domains := Domains, known := Known} = Context) ->
    case lists:keyfind(Domain, 1, Domains) of
        false when not Known -> standin(Path, Domain, unknown, Context);
        false -> {error, scope};
        {Domain, ended} -> {error, scope};
        {Domain, none} -> standin(Path, Domain, unknown, Context);
        {Domain, Agent} ->
            Query = {inspect, Path, maps:with([offset], Options)},
            asked(Path, Domain, checked(Query, Domain, ask(Agent, Domain, Query, Context)), Context)
    end.

asked(_Path, Domain, {answer, {ok, Record}}, Context) ->
    {ok, scoped(given(Record, Domain), Domain, Context)};
asked(_Path, _Domain, {answer, {error, Reason}}, _Context) when Reason =:= scope; Reason =:= unsupported ->
    {error, Reason};
asked(Path, Domain, {answer, {error, failed}}, Context) ->
    standin(Path, Domain, {error, failed}, Context);
asked(Path, Domain, {timeout, Status}, Context) ->
    standin(Path, Domain, Status, Context);
asked(Path, Domain, invalid, Context) ->
    standin(Path, Domain, {error, invalid}, Context).

%% The record of Path with each runtime attribute Status, as when its agent
%% did not answer.
standin(Path, Domain, Status, Context) ->
    {ok, #{kind := Kind, children := Children}} = erx_schema:resolve(Path),
    {ok, Keys} = erx_schema:attributes(Kind),
    Runtime = maps:from_list([{Key, {runtime, Status}} || Key <- Keys, runtime_reports(Kind, Key)]),
    Record = #{schema => erx_schema:schema(), path => Path, kind => Kind, id => lists:last(Path),
               attrs => Runtime, children => literals(Children)},
    {ok, scoped(given(Record, Domain), Domain, Context)}.

literals({literals, Literals}) -> Literals;
literals(_Children) -> [].

%% Record with the attributes no runtime reports given here: a process's
%% domain is the one its proc_id() names, and the rest are `unsupported` for
%% another domain (TODO.md, the query worker's `[domains, D]`).
given(#{kind := Kind, attrs := Attrs} = Record, Domain) ->
    {ok, Keys} = erx_schema:attributes(Kind),
    Given = maps:from_list([{Key, local(Kind, Key, Domain)} || Key <- Keys, not runtime_reports(Kind, Key)]),
    Record#{attrs := maps:merge(Attrs, Given)}.

local(process, domain, Domain) ->
    {service, {ok, Domain}};
local(Kind, Key, _Domain) ->
    {ok, #{reporters := [Reporter | _]}} = erx_schema:attribute(Kind, Key),
    {Reporter, unsupported}.

scoped(Record, Domain, #{scope := Scope}) ->
    erx_inspector:scoped(Record, {domain, Domain}, Scope).

%% The processes listing across the scope: this runtime's own, then each
%% other living domain's from its agent, one at a time, while the page has
%% room. A domain without an agent, an answer not taken, a partial answer
%% and an unknown view each make the listing partial.
processes(#{scope := Scope, domains := Domains, self := Self, known := Known} = Context) ->
    {Status, Local} = erx_inspector:entries([processes], Scope),
    Start = {status(Status =:= ok andalso Known), erx_inspector:page_add(Local, erx_inspector:page())},
    Others = [{Domain, Agent} || {Domain, Agent} <- Domains, Domain =/= Self, Agent =/= ended],
    {Listing, Page} = lists:foldl(fun(Other, Acc) -> gather(Other, Acc, Context) end, Start, Others),
    erx_inspector:page_entries(Page, Listing).

gather({Domain, Agent}, {Status, Page}, Context) ->
    case erx_inspector:page_full(Page) orelse Agent =:= none of
        true -> {partial, Page};
        false -> merge(Domain, ask(Agent, Domain, {entries, [processes]}, Context), {Status, Page}, Context)
    end.

%% An agent's listing merged into the page record by record as it is taken,
%% each as the scope sees it; what does not fit is dropped with the answer,
%% and an answer with any record not taken leaves the page as it was.
merge(Domain, {answer, Answer}, {Status, Page}, Context) ->
    Seen = fun(Record) -> scoped(given(Record, Domain), Domain, Context) end,
    case entries_taken(Domain, Answer, Seen, Page) of
        {ok, Answered, Merged} -> {status(Status =:= ok andalso Answered =:= ok), Merged};
        invalid -> {partial, Page}
    end;
merge(_Domain, _Missed, {_Status, Page}, _Context) ->
    {partial, Page}.

status(true) -> ok;
status(false) -> partial.

%% Asks Agent of Domain Query and waits for its answer, within the agent's
%% wait and the query's deadline: `{answer, Answer}`, not yet checked, or
%% `{timeout, Status}`, Status the attribute status a missed answer gives.
ask(Agent, Domain, Query, #{until := Until, query_max := QueryMax, agent_wait := Wait}) ->
    case Until - clock() of
        Left when Left =< 0 ->
            {timeout, {timeout, QueryMax}};
        Left ->
            Alias = alias([reply]),
            Agent ! {erx_inspect_ask, Alias, Query},
            {Bound, Status} = case Left < Wait of
                                  true -> {Left, {timeout, QueryMax}};
                                  false -> {Wait, {timeout, Wait}}
                              end,
            sized(await_answer(Domain, Alias, clock() + Bound, Status), Status)
    end.

%% Takes the next message whatever it is, and keeps it only when it is the
%% answer of Domain to Alias; so the worker never scans its queue, and holds
%% nothing it does not want.
await_answer(Domain, Alias, Until, Status) ->
    receive
        {erx_origin, Domain, {Alias, Answer}} ->
            {answer, Answer};
        _Dropped ->
            case clock() >= Until of
                true -> unalias(Alias), {timeout, Status};
                false -> await_answer(Domain, Alias, Until, Status)
            end
    after max(0, Until - clock()) ->
        unalias(Alias),
        {timeout, Status}
    end.

%% An answer past the worker's request limit is dropped as the funnel
%% would drop it, and so reads as a timeout.
sized({answer, Answer} = Answered, Status) ->
    case erts_debug:flat_size(Answer) =< ?ERX_INSPECT_MESSAGE_HEAP_MIN of
        true -> Answered;
        false -> {timeout, Status}
    end;
sized(Timeout, _Status) ->
    Timeout.

%% An answer as check/3 takes it.
checked(Query, Domain, {answer, Answer}) ->
    case check(Query, Domain, Answer) of
        {ok, Taken} -> {answer, Taken};
        invalid -> invalid
    end;
checked(_Query, _Domain, Missed) ->
    Missed.

%%% What the worker believes: a pure check.

-doc """
Answer as the worker takes it from the agent of Domain asked Query, or
`invalid` when it disagrees with the question (docs/design-live.md, "What
the inspector believes"). A record is taken only when its path is the one
asked, or for `entries [processes]` a process of Domain; its id is its
path's last segment; its attributes are ones `runtime` may report, marked
`runtime`; and it passes erx_schema:validate_record/1. Every `proc_id()`
of another domain is dropped from a taken record's attributes (owned/2).
An error answer is taken as `scope`, `unsupported` or `failed`.
""".
-spec check(query(), non_neg_integer(), term()) -> {ok, answer()} | invalid.
check({inspect, Path, _Options}, Domain, {ok, Record}) ->
    case bound(Record, fun(P) -> P =:= Path end, Domain) of
        {ok, Taken} -> {ok, {ok, Taken}};
        invalid -> invalid
    end;
check(_Query, _Domain, {error, Reason}) when Reason =:= scope; Reason =:= unsupported; Reason =:= failed ->
    {ok, {error, Reason}};
check({entries, [processes]}, Domain, Answer) ->
    case entries_taken(Domain, Answer, fun(Record) -> Record end, erx_inspector:page()) of
        {ok, Status, Page} -> {ok, erx_inspector:page_entries(Page, Status)};
        invalid -> invalid
    end;
check(_Query, _Domain, _Answer) ->
    invalid.

%% The `entries [processes]` answer of Domain taken into Page, each record
%% as Seen makes it once it is taken: `{ok, Status, Page1}`, Status what
%% the answer said of itself, or `invalid` when any record is not taken.
%% So the worker holds the page and the one answer, never a second copy.
entries_taken(_Domain, {error, Reason}, _Seen, Page)
  when Reason =:= scope; Reason =:= unsupported; Reason =:= failed ->
    {ok, partial, Page};
entries_taken(Domain, {Status, Records}, Seen, Page) when Status =:= ok; Status =:= partial ->
    IsEntry = fun([processes, {pid, D, _, _}]) -> D =:= Domain;
                 (_Path) -> false
              end,
    case taken_into(Records, IsEntry, Domain, Seen, Page, 0) of
        {ok, Page1} -> {ok, Status, Page1};
        invalid -> invalid
    end;
entries_taken(_Domain, _Answer, _Seen, _Page) ->
    invalid.

%% A listing's records, a proper list of at most a page, each bound and
%% added; a record past the page's room is still checked, then dropped.
taken_into([], _IsPath, _Domain, _Seen, Page, _Count) ->
    {ok, Page};
taken_into([Record | Rest], IsPath, Domain, Seen, Page, Count) when Count < ?PAGE ->
    case bound(Record, IsPath, Domain) of
        {ok, Taken} -> taken_into(Rest, IsPath, Domain, Seen, erx_inspector:page_add([Seen(Taken)], Page), Count + 1);
        invalid -> invalid
    end;
taken_into(_Records, _IsPath, _Domain, _Seen, _Page, _Count) ->
    invalid.

bound(#{path := Path, id := Id, attrs := Attrs} = Record, IsPath, Domain) when is_map(Attrs), is_list(Path) ->
    case IsPath(Path) andalso Path =/= [] andalso Id =:= lists:last(Path) of
        true -> validated(Record#{attrs := maps:map(fun runtime/2, Attrs)}, Domain);
        false -> invalid
    end;
bound(_Record, _IsPath, _Domain) ->
    invalid.

%% An attribute as the worker takes it: reported by runtime, whatever the
%% frame says; a value of no reporter's shape is refused by the validation.
runtime(_Key, {_Reporter, Value}) -> {runtime, Value};
runtime(_Key, Malformed) -> Malformed.

validated(Record, Domain) ->
    case erx_schema:validate_record(Record) of
        {ok, #{attrs := Attrs} = Valid} ->
            {ok, Valid#{attrs := maps:map(fun(_Key, {runtime, Value}) -> {runtime, owned(Value, Domain)} end,
                                          Attrs)}};
        {error, _Reason} ->
            invalid
    end.

-doc """
An attribute's value with every `proc_id()` of a domain other than Domain
dropped: from a list, the elements that hold one, leaving the rest
`partial`; any other value that holds one becomes `unknown`.
""".
-spec owned(erx_schema:value(), non_neg_integer()) -> erx_schema:value().
owned({Status, List}, Domain) when (Status =:= ok orelse Status =:= partial), is_list(List) ->
    case [Element || Element <- List, not foreign(Element, Domain)] of
        List -> {Status, List};
        Kept -> {partial, Kept}
    end;
owned({Status, Term} = Value, Domain) when Status =:= ok; Status =:= partial ->
    case foreign(Term, Domain) of
        true -> unknown;
        false -> Value
    end;
owned(Value, _Domain) ->
    Value.

%% Whether Term holds a proc_id() of a domain other than Domain anywhere.
%% A value the schema validated is of bounded depth.
foreign({pid, D, N, S}, Domain) when is_integer(D), is_integer(N), is_integer(S) -> D =/= Domain;
foreign(Tuple, Domain) when is_tuple(Tuple) -> foreign(tuple_to_list(Tuple), Domain);
foreign([Head | Tail], Domain) -> foreign(Head, Domain) orelse foreign(Tail, Domain);
foreign(Map, Domain) when is_map(Map) -> foreign(maps:to_list(Map), Domain);
foreign(_Term, _Domain) -> false.

runtime_reports(Kind, Key) ->
    {ok, #{reporters := Reporters}} = erx_schema:attribute(Kind, Key),
    lists:member(runtime, Reporters).

%% The answer as it leaves: every record validated whole (V10). A record
%% that fails is a fault of the inspector's: a listing drops it and is
%% partial, and a single record is {error, failed}.
leaving({ok, Record}) when is_map(Record) ->
    case erx_schema:validate_record(Record) of
        {ok, Valid} -> {ok, Valid};
        {error, _Reason} -> {error, failed}
    end;
leaving({Status, Records}) when is_list(Records) ->
    Valid = [Record || Record <- Records, element(1, erx_schema:validate_record(Record)) =:= ok],
    case length(Valid) =:= length(Records) of
        true -> {Status, Valid};
        false -> {partial, Valid}
    end;
leaving({error, _Reason} = Error) ->
    Error.

clock() ->
    erlang:monotonic_time(millisecond).
