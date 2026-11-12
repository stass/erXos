%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspector).
-moduledoc """
The inspector (docs/design-live.md, "Inspection"): it answers a query for
a path of abi/inspection.txt with the record of that path, each attribute
from its reporter, and keeps from it only what the caller's scope may see.
erx:i/0,1 and the shell's commands ask it with the scope of the session's
inspect facet, whose value is that scope; `/proc` and the host link ask
it with the scope of the inspect facet they serve.

* inspect/1, entries/1 and overview/0 answer the caller's own domain
  as it may see the machine, and are what erx:i/0,1 call. inspect/2
  answers the record of one path at a given scope; entries/2 the
  records of a listing's entries, the listing's own status beside
  them. inspect/3
  takes the query's options: `offset`, for a path the schema marks
  append-only, is the sequence number its entries start from, 0 when
  it is left out (docs/design-live.md, "Paths").
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
log, through erx_log_records, is read in the system domain, by a session
that holds the `log` facet too. To the scoped core, a process of
another runtime, and any other domain's path, name nothing it can
reach and are answered `{error, scope}`; a path the schema declares
that has no collector here is
`{error, unsupported}`.
""".

-export([inspect/1, entries/1, overview/0]).
-export([inspect/2, inspect/3, entries/2, overview/1, proc_id/1, runtime_domain/0]).
-export([scoped/3, declared_reachable/3, listing/2, collects_domain/2]).
-export([page/0, page_add/2, page_full/1, page_entries/2]).
-export_type([scope/0, query_scope/0, answer/0, entries/0, page/0]).

-include("generated/erx_abi.hrl").

-type scope() :: all | [non_neg_integer()].
%% A query's scope as an inspect facet holds it: {principal, P} is P's
%% domains, which the query worker resolves to a scope() at each query.
-type query_scope() :: scope() | {principal, pos_integer()}.
-type answer() :: {ok, erx_schema:record()} | {error, scope | unsupported | invalid | failed}.
-type options() :: #{offset => non_neg_integer()}.
-type entries() :: {ok | partial, [erx_schema:record()]} | {error, scope | unsupported | failed}.
%% Whose a path is: the machine's, or a domain's by its id.
-type owner() :: machine | {domain, non_neg_integer()}.
%% A listing's page while it is built: its records, newest first, their
%% count, the bytes their answer encodes to, and whether a record was
%% refused for want of room.
-opaque page() :: #{records := [erx_schema:record()], count := non_neg_integer(),
                    bytes := non_neg_integer(), full := boolean()}.

%% The most entries one listing gives: erx_schema's page.
-define(PAGE, 1000).
%% What an answer {partial, [...]} encodes to beyond its records' own
%% encodings: the version byte, the tuple, the atom and the list's header
%% and tail, rounded up. Each record's external_size/1 counts a version
%% byte of its own besides, so the sum is a bound, never short.
-define(ANSWER_OVERHEAD, 32).
%% The machine's paths a scoped caller reaches: the machine's record, with
%% only the attributes the schema marks `visible any`, and the
%% processes, listing only its own domains' (docs/design-live.md, "Scopes").
-define(SCOPED_MACHINE_PATHS, [[], [processes]]).

-doc """
The record of Path as the caller's domain may see it, with no scope of the
caller's own (docs/design-live.md, "How a query travels"). In the system
domain it runs in a query worker at scope `all` (erx_inspect_worker), which
asks other domains' agents for what only their runtimes know, and a worker
that fails, at its heap limit for one, is `{error, failed}`. In any other
runtime it answers from that runtime alone at its local scope
(erx_facets:domain/0).
""".
-spec inspect(term()) -> answer().
inspect(Path) ->
    query({inspect, Path, #{}}).

-doc "The records of the entries of the listing at Path, as inspect/1 asks.".
-spec entries(term()) -> entries().
entries(Path) ->
    query({entries, Path}).

query(Query) ->
    case erx_facets:domain() of
        #{inspect := all} -> erx_inspect_worker:call(Query, all, #{view => fun view/1});
        #{inspect := Scope} -> local(Query, Scope)
    end.

local({inspect, Path, Options}, Scope) -> inspect(Path, Scope, Options);
local({entries, Path}, Scope) -> entries(Path, Scope).

%% The other domains a worker may ask, from the domain service on erXos; a
%% host runtime stands for the system domain alone and knows no other. A
%% service that does not answer leaves the worker without a view, which it
%% reports as partial, never as an empty machine.
view(Scope) ->
    case erlang:system_info(os_type) of
        {unix, erxos} ->
            try {ok, erx_domain:inspect_view(Scope)}
            catch exit:_ -> unavailable
            end;
        _ ->
            {ok, []}
    end.

-doc "The record of Path as Scope may see it.".
-spec inspect(term(), scope()) -> answer().
inspect(Path, Scope) ->
    inspect(Path, Scope, #{}).

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
What erx:i/0 shows, in its order: the machine, the CPUs, the system
domain's group and budget, its threads and the processes, each as
inspect/2 or entries/2 answers it for Scope.
""".
-spec overview(scope()) -> [{[erx_schema:segment()], answer() | entries()}].
overview(Scope) ->
    sections(fun(Path) -> inspect(Path, Scope) end, fun(Path) -> entries(Path, Scope) end).

-doc "What erx:i/0 shows, each section asked as inspect/1 and entries/1 ask.".
-spec overview() -> [{[erx_schema:segment()], answer() | entries()}].
overview() ->
    sections(fun inspect/1, fun entries/1).

sections(Inspect, Entries) ->
    Domain = erx_kernel_records:system_domain(),
    [{[], Inspect([])},
     {[cpus], Entries([cpus])},
     {[domains, Domain, group], Inspect([domains, Domain, group])},
     {[domains, Domain, budget], Inspect([domains, Domain, budget])},
     {[domains, Domain, threads], Entries([domains, Domain, threads])},
     {[processes], Entries([processes])}].

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

-doc """
The domain this runtime is: the one its boot page names (erx_dist:boot/0)
on erXos, and on a development host, where one trusted runtime stands for
the system domain, the system domain's id, as erx_facets:domain/0 reads it.
""".
-spec runtime_domain() -> non_neg_integer().
runtime_domain() ->
    case erlang:system_info(os_type) of
        {unix, erxos} -> element(1, erx_dist:boot());
        _ -> erx_kernel_records:system_domain()
    end.

first_page(Items) when length(Items) =< ?PAGE -> {ok, Items};
first_page(Items) -> {partial, lists:sublist(Items, ?PAGE)}.

%%% A listing's page: the inspector's rules of cutting (docs/design-live.md,
%%% "Bounds"), shared by this runtime's listings, a domain's agent and the
%%% query worker that merges agents' answers.

-doc "An empty page.".
-spec page() -> page().
page() ->
    #{records => [], count => 0, bytes => ?ANSWER_OVERHEAD, full => false}.

-doc """
Page with Records added in order while each fits: at most 1,000 entries,
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
    case Count < ?PAGE andalso Bytes + Size =< ?ERX_INSPECT_REPLY_MAX of
        true -> page_add(Rest, Page#{records := [Record | Records], count := Count + 1,
                                     bytes := Bytes + Size});
        false -> Page#{full := true}
    end.

-doc "Whether Page takes no more entries: one was refused, or it holds a page's count.".
-spec page_full(page()) -> boolean().
page_full(#{full := Full, count := Count}) ->
    Full orelse Count >= ?PAGE.

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
