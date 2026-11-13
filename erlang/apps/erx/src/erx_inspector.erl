%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspector).
-moduledoc """
The inspector (docs/design-live.md, "Inspection"): it answers a query for
a path of abi/inspection.txt with the record of that path, each attribute
from its reporter, and keeps from it only what the caller's scope may see.
No caller outside the system domain names a scope: erx:i/0,1, the shell's
commands, `/proc` and the web line's views ask through inspect/1,2,
entries/1 and overview/0, which go through the domain's inspect facet,
whose scope the system domain fixed when it minted it
(docs/design-live.md, "How a query travels").

* inspect/1,2, entries/1 and overview/0 answer the caller's own domain
  as it may see the machine. inspect/2 takes the query's options:
  `offset`, for a path the schema marks append-only, is the sequence
  number its entries start from, 0 when it is left out
  (docs/design-live.md, "Paths").
* inspect/3 and entries/2 are the core a query worker and a domain's
  agent run at a given scope: the record of one path, and the records of
  a listing's entries, the listing's own status beside them.
* A scope is `all` or a list of domain ids. A path's owner is decided by
  construction: `[domains, D | _]` and `[processes, {pid, D, N, S}]` are
  D's, and every other path is the machine's. A path the
  schema marks `visible all` needs scope `all`, a domain's path needs its
  domain in the scope, and a path outside the scope gets the answer of a
  path that names nothing, `{error, scope}`, so a scoped caller cannot
  learn whether it exists.
* Of a record it may reach, the caller sees the attributes whose
  visibility class its scope admits (scoped/3): `any` always, `owner`
  with scope `all` or its owner's domain in the scope, `all` with scope
  `all`; `system_shell` never, since no query here presents the
  system-shell facet.

In Phase 1 the processes the scoped core lists and describes, through
erx_process_records, are its own runtime's, as the domain this runtime
is (runtime_domain/0), so in a session domain `[processes]` lists the
session's processes. In the system domain inspect/1 and entries/1 run
in a query worker at scope `all` (erx_inspect_worker), which adds the
processes of every other living domain from that domain's agent
(erx_inspect_agent); `[domains, D]` of another domain carries its
runtime attributes from the agent and every other attribute
`unsupported`. Kernel objects, through
erx_kernel_records on the root's own capabilities, and the domain record,
through erx_runtime_records, are the system domain's only; the kernel
log, through erx_log_records, is read in the system domain only, and the
start table, through erx_app_records, from the start service of the
system domain, `{error, unsupported}` where none runs. To the
scoped core, a process of another runtime, and any other domain's path,
name nothing it can
reach and are answered `{error, scope}`; a path the schema declares
that has no collector here is
`{error, unsupported}`.
""".

-export([inspect/1, inspect/2, entries/1, overview/0]).
-export([inspect/3, entries/2, route/3, proc_id/1, runtime_domain/0]).
-export([scoped/3, declared_reachable/3, listing/2, collects_domain/2]).
-export([page/0, page_add/2, page_full/1, page_entries/2, view/1]).
-export_type([scope/0, query_scope/0, answer/0, entries/0, page/0]).

-include("generated/erx_abi.hrl").

-type scope() :: all | [non_neg_integer()].
%% A query's scope as an inspect facet holds it: {principal, P} is P's
%% domains, which the query worker resolves to a scope() at each query.
-type query_scope() :: scope() | {principal, pos_integer()}.
-type answer() :: {ok, erx_schema:record()}
                  | {error, scope | unsupported | invalid | failed | no_facet | busy | badarg}.
-type options() :: #{offset => non_neg_integer()}.
-type entries() :: {ok | partial, [erx_schema:record()]}
                   | {error, scope | unsupported | failed | no_facet | busy | badarg}.
%% Whose a path is: the machine's, or a domain's by its id.
-type owner() :: machine | {domain, non_neg_integer()}.
%% A listing's page while it is built: its records, newest first, their
%% count, the bytes their answer encodes to, and whether a record was
%% refused for want of room.
-opaque page() :: #{records := [erx_schema:record()], count := non_neg_integer(),
                    bytes := non_neg_integer(), full := boolean()}.

%% What an answer {partial, [...]} encodes to beyond its records' own
%% encodings: the version byte, the tuple, the atom and the list's header
%% and tail, rounded up. Each record's external_size/1 counts a version
%% byte of its own besides, so the sum is a bound, never short.
-define(ANSWER_OVERHEAD, 32).
%% The machine's paths a scoped caller reaches: the machine's record, with
%% only the attributes the schema marks `visible any`, and the
%% processes, listing only its own domains' (docs/design-live.md, "Scopes").
-define(SCOPED_MACHINE_PATHS, [[], [processes]]).
%% How much longer than a query's own deadline a caller waits for the facet's
%% answer, for the frames' way between the domains.
-define(FACET_MARGIN, 1000).

-doc """
The record of Path as the caller's domain may see it, with no scope of the
caller's own (docs/design-live.md, "How a query travels"). In the system
domain it runs in a query worker at scope `all` (erx_inspect_worker), which
asks other domains' agents for what only their runtimes know, and a worker
that fails, at its heap limit for one, is `{error, failed}`. In any other
runtime it calls the domain's inspect facet (erx:cap(inspect)), whose
scope the system domain fixed when it minted the facet, and returns its
answer: `{error, no_facet}` when the domain holds none or its facet has
ended, revoked with its grant, and `{error, failed}` when the facet does
not answer within inspect_query_max and a margin. A query the facet holds
as it ends follows the facet's exit reason: `no_facet` for `noproc`,
`failed` for any other.
""".
-spec inspect(term()) -> answer().
inspect(Path) ->
    inspect(Path, #{}).

-doc """
The record of Path as inspect/1 asks for it, for the query's Options,
which only an append-only path reads (inspect/3).
""".
-spec inspect(term(), options()) -> answer().
inspect(Path, Options) ->
    query({inspect, Path, Options}).

-doc "The records of the entries of the listing at Path, as inspect/1 asks.".
-spec entries(term()) -> entries().
entries(Path) ->
    query({entries, Path}).

query(Query) ->
    route(is_system_runtime(), erx:cap(inspect), Query).

-doc """
Where a query goes: in the system domain (System true) to a local query
worker at scope `all`; in any other runtime to the domain's inspect
facet, Facet, or nowhere, `{error, no_facet}`, when it holds none or
holds one that has ended: a revoked facet admits no query after its end
(docs/design-live.md, "The /proc tree"), and a call to it exits `noproc`,
as a call to a process of another domain that does not exist does. No
runtime but the system domain's answers a query itself, so none decides
a scope. The facet decodes the request and refuses what the interface
does not take, so a path that is no data is `{error, badarg}` here too,
and a request past its requests in flight is `{error, busy}`.
""".
-spec route(boolean(), pid() | undefined, term()) -> answer() | entries().
route(true, _Facet, Query) ->
    erx_inspect_worker:call(Query, all, #{view => fun view/1});
route(false, undefined, _Query) ->
    {error, no_facet};
route(false, Facet, Query) ->
    try gen_server:call(Facet, Query, ?ERX_INSPECT_QUERY_MAX + ?FACET_MARGIN)
    catch
        exit:{noproc, _} -> {error, no_facet};
        exit:_ -> {error, failed}
    end.

-doc """
The other domains a query worker may ask, from the domain service on
erXos; a host runtime stands for the system domain alone and knows no
other. A service that does not answer leaves the worker without a view,
which it reports as partial, never as an empty machine. The worker's
default view, the system domain's own and its facets'.
""".
-spec view(all | {principal, pos_integer()}) -> {ok, erx_inspect_worker:view()} | unavailable.
view(Scope) ->
    case erlang:system_info(os_type) of
        {unix, erxos} ->
            try {ok, erx_domain:inspect_view(Scope)}
            catch exit:_ -> unavailable
            end;
        _ ->
            {ok, []}
    end.

-doc """
The record of Path as Scope may see it, for the query's Options, which
only an append-only path reads: there an offset that is not a sequence
number, and options that are not a map, are `{error, invalid}`, and any
other path ignores them.
""".
-spec inspect(term(), scope(), options()) -> answer().
inspect(Path, Scope, Options) ->
    within(Path, Scope, fun(Owner) -> project(collect(Path, Scope, Options), Owner, Scope) end).

-doc """
The records of the entries of the listing at Path as Scope may see them,
`partial` when the listing stopped short; `{error, unsupported}` for a
path that is not a listing this inspector can enumerate.
""".
-spec entries(term(), scope()) -> entries().
entries(Path, Scope) ->
    within(Path, Scope, fun(_Owner) -> seen(enumerate(Path, Scope), Scope) end).

%% Each entry as Scope may see it, under the owner of its own path.
seen({Status, Records}, Scope) when is_list(Records) ->
    {Status, [scoped(Record, owner(Path), Scope) || #{path := Path} = Record <- Records]};
seen(Error, _Scope) ->
    Error.

-doc """
What erx:i/0 shows, in its order: the machine, the CPUs, the group and
budget of the domain this runtime is (runtime_domain/0), its threads and
the processes, each section asked as inspect/1 and entries/1 ask.
""".
-spec overview() -> [{[erx_schema:segment()], answer() | entries()}].
overview() ->
    Domain = runtime_domain(),
    [{[], inspect([])},
     {[cpus], entries([cpus])},
     {[domains, Domain, group], inspect([domains, Domain, group])},
     {[domains, Domain, budget], inspect([domains, Domain, budget])},
     {[domains, Domain, threads], entries([domains, Domain, threads])},
     {[processes], entries([processes])}].

%%% Scope: pure decisions.

%% Runs Answer with the path's owner when Scope reaches Path, and answers
%% {error, scope} otherwise, as for a path that names nothing.
within(Path, Scope, Answer) ->
    case declared_reachable(Path, erx_schema:resolve(Path), Scope) of
        {ok, Owner} -> Answer(Owner);
        error -> {error, scope}
    end.

-doc """
The owner of Path when Scope reaches it, given erx_schema:resolve/1's
answer for it; `error` for a path outside the scope and one that names no
declared path.
""".
-spec declared_reachable(term(), {ok, erx_schema:declaration()} | {error, unknown_path}, scope()) ->
          {ok, owner()} | error.
declared_reachable(_Path, {error, unknown_path}, _Scope) ->
    error;
declared_reachable(Path, {ok, #{visible := Visible}}, Scope) when Scope =/= all ->
    case lists:member(all, Visible) of
        true -> error;
        false -> reachable(Path, Scope)
    end;
declared_reachable(Path, {ok, _Declaration}, Scope) ->
    reachable(Path, Scope).

%% A path no declaration closes to a scoped caller: a domain's when its
%% domain is in the scope; the machine's only when it is one a scoped
%% caller may read, so a machine-wide path declared later is closed to
%% scoped callers until it is named here.
reachable(Path, Scope) ->
    case owner(Path) of
        {domain, Domain} = Owner -> answer(covered(Scope, Domain), Owner);
        machine -> answer(Scope =:= all orelse lists:member(Path, ?SCOPED_MACHINE_PATHS), machine)
    end.

answer(true, Owner) -> {ok, Owner};
answer(false, _Owner) -> error.

covered(all, _Domain) -> true;
covered(Domains, Domain) -> lists:member(Domain, Domains).

%% A path's owner, by construction from the path: a process is the domain
%% its proc_id() names.
owner([domains, Domain | _]) -> {domain, Domain};
owner([processes, {pid, Domain, _Number, _Serial}]) -> {domain, Domain};
owner(_Path) -> machine.

-doc """
The record with only the attributes whose visibility class Scope admits
for a record of Owner.
""".
-spec scoped(erx_schema:record(), owner(), scope()) -> erx_schema:record().
scoped(#{kind := Kind, attrs := Attrs} = Record, Owner, Scope) ->
    Record#{attrs := maps:filter(fun(Key, _Attr) -> visible(class(Kind, Key), Owner, Scope) end,
                                 Attrs)}.

class(Kind, Key) ->
    {ok, #{visible := Class}} = erx_schema:attribute(Kind, Key),
    Class.

visible(system_shell, _Owner, _Scope) -> false;
visible(any, _Owner, _Scope) -> true;
visible(_Class, _Owner, all) -> true;
visible(owner, {domain, Domain}, Domains) -> covered(Domains, Domain);
visible(_Class, _Owner, _Domains) -> false.

project({ok, Record}, Owner, Scope) -> {ok, scoped(Record, Owner, Scope)};
project(Error, _Owner, _Scope) -> Error.

%%% Collection: each path from its reporter.

-doc """
Whether a runtime of domain Runtime collects Domain's records: only the
system domain's, the one whose objects the root names, and only in the system
domain's own runtime. Another runtime's counters are its own domain's
(erx_runtime_records), and so are its group, budget and threads where the
kernel reports them to it (erx_kernel_records reads them on its own
capabilities), so it collects none rather than show its own as the system
domain's, whatever its scope.
""".
-spec collects_domain(non_neg_integer(), non_neg_integer()) -> boolean().
collects_domain(Domain, Runtime) ->
    Domain =:= Runtime andalso Domain =:= erx_kernel_records:system_domain().

%% One clause per path shape this inspector collects; a domain path is
%% collected only for the system domain, in its own runtime
%% (collects_domain/2), and every other domain names nothing it reaches.
collect([kernel, log], _Scope, Options) ->
    case Options of
        #{offset := Offset} -> erx_log_records:log(Offset);
        #{} -> erx_log_records:log(0);
        _ -> {error, invalid}
    end;
collect(Path, Scope, _Options) ->
    collect(Path, Scope).

collect([], _Scope) ->
    {ok, erx_kernel_records:machine()};
collect([processes, ProcId], _Scope) ->
    Domain = runtime_domain(),
    case erx_process_records:local_pid(ProcId, Domain) of
        {ok, Pid} -> found(erx_process_records:process(Pid, Domain));
        error -> {error, scope}
    end;
collect([cpus, _Index] = Path, Scope) ->
    entry(Path, enumerate([cpus], Scope));
collect([domains, Domain | Rest] = Path, Scope) ->
    case collects_domain(Domain, runtime_domain()) of
        true -> system_domain(Path, Rest, Scope);
        false -> {error, scope}
    end;
collect([kernel] = Path, _Scope) ->
    literals(Path);
collect([apps | _] = Path, _Scope) ->
    erx_app_records:collect(Path);
collect(Path, Scope) ->
    listing(Path, enumerate(Path, Scope)).

%% The record of a listing the schema extends by literal segments: those
%% segments, from the declaration alone.
literals(Path) ->
    {ok, #{children := {literals, Children}}} = erx_schema:resolve(Path),
    erx_schema:validate_record(#{schema => erx_schema:schema(), path => Path, kind => listing,
                                 id => lists:last(Path), attrs => #{}, children => Children}).

system_domain(_Path, [], _Scope) ->
    erx_runtime_records:domain(erx_kernel_records:system_domain());
system_domain(_Path, [group], _Scope) ->
    {ok, erx_kernel_records:group()};
system_domain(_Path, [budget], _Scope) ->
    {ok, erx_kernel_records:budget()};
system_domain([domains, Domain, threads, _Thread] = Path, _Rest, Scope) ->
    entry(Path, enumerate([domains, Domain, threads], Scope));
system_domain(Path, _Rest, Scope) ->
    listing(Path, enumerate(Path, Scope)).

%% The records of a listing's entries.
enumerate([cpus], _Scope) ->
    erx_kernel_records:cpus();
enumerate([domains, Domain, threads], _Scope) ->
    case Domain =:= erx_kernel_records:system_domain() of
        true -> erx_kernel_records:threads();
        false -> {error, scope}
    end;
enumerate([processes], Scope) ->
    Domain = runtime_domain(),
    {Status, Pids} = first_page(case covered(Scope, Domain) of
                                    true -> erlang:processes();
                                    false -> []
                                end),
    Records = [Record || Pid <- Pids, {ok, Record} <- [erx_process_records:process(Pid, Domain)]],
    page_entries(page_add(Records, page()), Status);
enumerate(_Path, _Scope) ->
    {error, unsupported}.

-doc """
The `proc_id()` of Pid as this runtime names it (docs/design-live.md,
"Names travel as data"), so a caller that holds a live pid asks for its
record by data: `[processes, erx_inspector:proc_id(Pid)]`.
""".
-spec proc_id(pid()) -> erx_schema:proc_id().
proc_id(Pid) ->
    erx_process_records:proc_id(Pid, runtime_domain()).

-doc "The domain this runtime is, the one its boot page names (boot/0).".
-spec runtime_domain() -> non_neg_integer().
runtime_domain() ->
    element(1, boot()).

%% Whether this runtime is the system domain's: the one whose boot page names the system
%% domain's id and no system connection, so a runtime with only one of the two, a misread
%% boot page, is another domain and asks its inspect facet rather than its own worker.
is_system_runtime() ->
    boot() =:= {erx_kernel_records:system_domain(), none}.

%% The boot page (erx_dist:boot/0) on erXos; a runtime that is not erXos's, as on a
%% development host, is one trusted runtime standing for the system domain.
boot() ->
    case erlang:system_info(os_type) of
        {unix, erxos} -> erx_dist:boot();
        _ -> {erx_kernel_records:system_domain(), none}
    end.

first_page(Items) when length(Items) =< ?ERX_INSPECT_PAGE_MAX -> {ok, Items};
first_page(Items) -> {partial, lists:sublist(Items, ?ERX_INSPECT_PAGE_MAX)}.

%%% A listing's page: the inspector's rules of cutting (docs/design-live.md,
%%% "Bounds"), shared by this runtime's listings, a domain's agent and the
%%% query worker that merges agents' answers.

-doc "An empty page.".
-spec page() -> page().
page() ->
    #{records => [], count => 0, bytes => ?ANSWER_OVERHEAD, full => false}.

-doc """
Page with Records added in order while each fits: at most `inspect_page_max` entries,
and an answer whose encoding stays within inspect_reply_max. The first
record that does not fit fills the page, and it and every record after it
are dropped, so every entry the page holds is whole.
""".
-spec page_add([erx_schema:record()], page()) -> page().
page_add([], Page) ->
    Page;
page_add(_Records, #{full := true} = Page) ->
    Page;
page_add([Record | Rest], #{records := Records, count := Count, bytes := Bytes} = Page) ->
    Size = erlang:external_size(Record),
    case Count < ?ERX_INSPECT_PAGE_MAX andalso Bytes + Size =< ?ERX_INSPECT_REPLY_MAX of
        true -> page_add(Rest, Page#{records := [Record | Records], count := Count + 1,
                                     bytes := Bytes + Size});
        false -> Page#{full := true}
    end.

-doc "Whether Page takes no more entries: one was refused, or it holds a page's count.".
-spec page_full(page()) -> boolean().
page_full(#{full := Full, count := Count}) ->
    Full orelse Count >= ?ERX_INSPECT_PAGE_MAX.

-doc """
The listing's answer from Page: its entries in the order they were added,
`partial` when a record was refused or Status, what the entries' source
said of itself, is `partial`.
""".
-spec page_entries(page(), ok | partial) -> {ok | partial, [erx_schema:record()]}.
page_entries(#{records := Records, full := Full}, Status) ->
    {case Full orelse Status =:= partial of
         true -> partial;
         false -> ok
     end, lists:reverse(Records)}.

%% The first record of a listing's entries whose path is Path. An entry
%% the listing does not hold names nothing, as a process that is gone.
entry(Path, {_Status, Records}) ->
    case [Record || #{path := P} = Record <- Records, P =:= Path] of
        [Record | _] -> {ok, Record};
        [] -> {error, scope}
    end;
entry(_Path, Error) ->
    Error.

-doc """
The record of the listing at Path from its entries: their ids as its
children. A listing read an index at a time can meet an entry twice when
entries come and go between reads; it keeps the first and is partial,
since what it holds is no longer one snapshot.
""".
-spec listing([erx_schema:segment()], entries()) -> answer().
listing(Path, {Status, Records}) when is_list(Records) ->
    Ids = [Id || #{id := Id} <- Records],
    Distinct = distinct(Ids),
    Children = case Status =:= ok andalso length(Distinct) =:= length(Ids) of
                   true -> Ids;
                   false -> {partial, Distinct}
               end,
    {ok, _} = erx_schema:validate_record(#{schema => erx_schema:schema(), path => Path,
                                           kind => listing, id => lists:last(Path),
                                           attrs => #{}, children => Children});
listing(_Path, Error) ->
    Error.

distinct(Ids) ->
    {Kept, _Seen} = lists:foldl(fun(Id, {Kept, Seen}) ->
                                        case sets:is_element(Id, Seen) of
                                            true -> {Kept, Seen};
                                            false -> {[Id | Kept], sets:add_element(Id, Seen)}
                                        end
                                end, {[], sets:new([{version, 2}])}, Ids),
    lists:reverse(Kept).

%% A process that is gone names nothing.
found({ok, Record}) -> {ok, Record};
found(none) -> {error, scope}.
