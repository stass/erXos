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

* inspect/2 answers the record of one path; entries/2 the records of a
  listing's entries, the listing's own status beside them.
* A scope is `all` or a list of domain ids. A path's owner is decided by
  construction: `[domains, D | _]` is D's, `[processes, Pid]` is the
  domain of the pid, and every other path is the machine's. A path the
  schema marks `visible all` needs scope `all`, a domain's path needs its
  domain in the scope, and a path outside the scope gets the answer of a
  path that names nothing, `{error, scope}`, so a scoped caller cannot
  learn whether it exists.
* Of a record it may reach, the caller sees the attributes whose
  visibility class its scope admits (scoped/3): `any` always, `owner`
  with scope `all` or its owner's domain in the scope, `all` with scope
  `all`; `system_shell` never, since no query here presents the
  system-shell facet.

In Phase 1 the inspector answers for the system domain only: its kernel
objects through erx_kernel_records, on the root's own capabilities, its
domain record through erx_runtime_records and its processes through
erx_process_records. A pid of another runtime, and
a domain other than the system domain, name nothing it can reach and are
answered `{error, scope}`; a path the schema declares that has no
collector here is `{error, unsupported}`.
""".

-export([inspect/2, entries/2, overview/1]).
-export([scoped/3, declared_reachable/3, listing/2]).
-export_type([scope/0, answer/0, entries/0]).

-type scope() :: all | [non_neg_integer()].
-type answer() :: {ok, erx_schema:record()} | {error, scope | unsupported}.
-type entries() :: {ok | partial, [erx_schema:record()]} | {error, scope | unsupported}.
%% Whose a path is: the machine's, or a domain's by its id.
-type owner() :: machine | {domain, non_neg_integer()}.

%% The most entries one listing gives: erx_schema's page.
-define(PAGE, 1000).
%% The machine's paths a scoped caller reaches: the machine's record, with
%% only the attributes the schema marks `visible any`, and the
%% processes, listing only its own domains' (docs/design-live.md, "Scopes").
-define(SCOPED_MACHINE_PATHS, [[], [processes]]).

-doc "The record of Path as Scope may see it.".
-spec inspect(term(), scope()) -> answer().
inspect(Path, Scope) ->
    within(Path, Scope, fun(Owner) -> project(collect(Path, Scope), Owner, Scope) end).

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
    Domain = erx_kernel_records:system_domain(),
    [{[], inspect([], Scope)},
     {[cpus], entries([cpus], Scope)},
     {[domains, Domain, group], inspect([domains, Domain, group], Scope)},
     {[domains, Domain, budget], inspect([domains, Domain, budget], Scope)},
     {[domains, Domain, threads], entries([domains, Domain, threads], Scope)},
     {[processes], entries([processes], Scope)}].

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
answer for it; `error` for a path outside the scope, one that names no
declared path, and a pid of a runtime this inspector does not reach.
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
        none -> error;
        {domain, Domain} = Owner -> answer(covered(Scope, Domain), Owner);
        machine -> answer(Scope =:= all orelse lists:member(Path, ?SCOPED_MACHINE_PATHS), machine)
    end.

answer(true, Owner) -> {ok, Owner};
answer(false, _Owner) -> error.

covered(all, _Domain) -> true;
covered(Domains, Domain) -> lists:member(Domain, Domains).

%% A path's owner, by construction from the path. A pid is its runtime's;
%% this inspector reaches only its own runtime, the system domain's.
owner([domains, Domain | _]) -> {domain, Domain};
owner([processes, Pid]) when node(Pid) =:= node() -> {domain, erx_kernel_records:system_domain()};
owner([processes, _Pid]) -> none;
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

%% One clause per path shape this inspector collects; a domain path is
%% collected only for the system domain, the one whose objects the root
%% names, and every other domain names nothing it reaches.
collect([], _Scope) ->
    {ok, erx_kernel_records:machine()};
collect([processes, Pid], _Scope) ->
    found(erx_process_records:process(Pid, erx_kernel_records:system_domain()));
collect([cpus, _Index] = Path, Scope) ->
    entry(Path, enumerate([cpus], Scope));
collect([domains, Domain | Rest] = Path, Scope) ->
    case Domain =:= erx_kernel_records:system_domain() of
        true -> system_domain(Path, Rest, Scope);
        false -> {error, scope}
    end;
collect(Path, Scope) ->
    listing(Path, enumerate(Path, Scope)).

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
    Domain = erx_kernel_records:system_domain(),
    {Status, Pids} = page(case covered(Scope, Domain) of
                              true -> erlang:processes();
                              false -> []
                          end),
    {Status, [Record || Pid <- Pids, {ok, Record} <- [erx_process_records:process(Pid, Domain)]]};
enumerate(_Path, _Scope) ->
    {error, unsupported}.

page(Items) when length(Items) =< ?PAGE -> {ok, Items};
page(Items) -> {partial, lists:sublist(Items, ?PAGE)}.

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
