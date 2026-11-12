%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_core).
-moduledoc """
The domain service's pure core (docs/design-system.md, "The domain service's
record"; docs/design-domains.md, "Domain ids, pids and references"): ids,
names, each domain's life, death records, configured restarts and the scope
of a domain's inspect facet (inspect_scope/3). It makes
no call; erx_domain_srv does the effects and keeps the state in its own heap.

Ids. The system domain is 4, since a domain's id is its node's creation and
stock ERTS gives no node a creation below 4. Every other domain takes the
next id from 5 on, once, whether or not its creation succeeds, so ids
increase and none is reused within a boot; past 2^32 - 1 admit/4 answers
system_limit. The manifest's configured domains are admitted first, in boot
order, so the domain at place P of it is 5 + P, as the manifest check's host
planner assumes.

Names. A name binds to the principal whose domain first takes it, for the
boot; at most one living domain holds it. Each principal binds at most
?NAMES_QUOTA names by request or session start, which bounds the node-name atoms admit/4 makes
(D5): the atom is made once, when the name is first bound and after the
quota check, and every later domain of the name reuses it. The configured
domains bind theirs at boot outside the quota, since the checked manifest
bounds them.

A domain's life: building (admitted, the library not yet asked) -> built
(the library made it) -> running (its first thread started) -> ready (its
init reported ready), and at its end the domain leaves the table, as the
library retires it then. A running domain whose boot timeout passed is stopping instead of
ready, so no late report makes it ready; a domain may end from built,
running, ready or stopping. A creation the library refuses
goes from building to nothing, freeing its name. A transition from any other
state is a bug of the caller and fails with a badmatch.
""".

-export([new/1, host/1, admit/4, built/5, running/2, ready/3, stopping/2, failed/2, ended/5,
         restart/5, fetch/2, find_pid/2, deaths/2, domains/1, info/1, session_name/3]).
-export([inspect_scope/3, inspect_view/2]).
-export_type([state/0, domain/0, origin/0, info/0, slogan/0, inspect_scope/0]).

-define(SYSTEM_ID, 4).
-define(ID_MAX, 16#ffffffff).
-define(NAMES_QUOTA, 64).
-define(DEATHS_KEPT, 16).

-type origin() :: request | {configured, Row :: non_neg_integer()} | {session, Template :: non_neg_integer()}.
-type life() :: building | built | running | ready | stopping.
-type info() :: {halt, integer()} | crash | {fault, integer()} | stopped.
-type domain() :: #{id := pos_integer(), name := erx_ident:t(), node := node(),
                    principal := pos_integer(), origin := origin(), state := life(),
                    pid := pid() | undefined, ref := reference() | undefined,
                    connection := non_neg_integer(),
                    ctl_slots := non_neg_integer(), reader := non_neg_integer(),
                    facets := #{atom() => {pid(), map()}}, inspect := pid() | none}.
-type binding() :: #{principal := pos_integer(), node := node(), holder := none | pos_integer()}.
-type death() :: #{id := pos_integer(), name := erx_ident:t(), info := info(), at := integer(),
                   slogan => slogan()}.
%% Every domain, or the domains of one principal (inspect_scope/3).
-type inspect_scope() :: all | {principal, pos_integer()}.
%% A crash's slogan as the domain wrote it, untrusted text, or why its crash area could not be read.
-type slogan() :: binary() | {unreadable, atom() | {status, integer()}}.
-opaque state() :: #{host := binary(), next_id := pos_integer(),
                     names := #{binary() => binding()},
                     bound := #{pos_integer() => non_neg_integer()},
                     domains := #{pos_integer() => domain()},
                     deaths := #{pos_integer() => [death()]},
                     restarts := #{non_neg_integer() => [integer()]}}.

-doc "The state of a boot whose machine is named Host, an identifier.".
-spec new(binary()) -> state().
new(Host) when is_binary(Host) ->
    #{host => Host, next_id => ?SYSTEM_ID + 1, names => #{}, bound => #{}, domains => #{},
      deaths => #{}, restarts => #{}}.

-spec host(state()) -> binary().
host(#{host := Host}) -> Host.

-doc """
Admits a domain named Name for Principal: spends the next id, binds the name
and records the domain as building. It refuses with system_limit, name_taken
or quota, leaving the state as it was.
""".
-spec admit(erx_ident:t(), pos_integer(), origin(), state()) ->
          {ok, domain(), state()} | {error, system_limit | name_taken | quota}.
admit(_Name, _Principal, _Origin, #{next_id := Id}) when Id > ?ID_MAX ->
    {error, system_limit};
admit(Name, Principal, Origin, #{names := Names, bound := Bound} = State) ->
    Bytes = erx_ident:to_binary(Name),
    Count = maps:get(Principal, Bound, 0),
    %% Only the configured domains, which the checked manifest bounds, bind outside it.
    Counted = case Origin of {configured, _} -> false; _ -> true end,
    case Names of
        #{Bytes := #{principal := Principal, holder := none} = Binding} ->
            take(Name, Binding, Principal, Origin, State);
        #{Bytes := _} ->
            {error, name_taken};
        #{} when Count >= ?NAMES_QUOTA, Counted ->
            {error, quota};
        #{} ->
            Node = binary_to_atom(<<Bytes/binary, $@, (host(State))/binary>>, latin1),
            Binding = #{principal => Principal, node => Node, holder => none},
            take(Name, Binding, Principal, Origin, State#{bound := Bound#{Principal => Count + 1}})
    end.

-doc """
The name Principal's next session takes: Prefix_N for the lowest N from 1 whose
name Principal may take without a new binding or, if none, the first one no
principal has bound. A refused or ended session's name is so taken again, and a
principal's session names are bounded by its living sessions, not by its starts.
""".
-spec session_name(binary(), pos_integer(), state()) -> binary().
session_name(Prefix, Principal, #{names := Names}) ->
    session_name(Prefix, Principal, Names, 1).

%% Ends: each step passes a name bound in the finite Names.
session_name(Prefix, Principal, Names, N) ->
    Name = <<Prefix/binary, $_, (integer_to_binary(N))/binary>>,
    case Names of
        #{Name := #{principal := Principal, holder := none}} -> Name;
        #{Name := _} -> session_name(Prefix, Principal, Names, N + 1);
        #{} -> Name
    end.

take(Name, #{node := Node} = Binding, Principal, Origin,
     #{next_id := Id, names := Names, domains := Domains} = State) ->
    Domain = #{id => Id, name => Name, node => Node, principal => Principal, origin => Origin,
               state => building, pid => undefined, ref => undefined, connection => 0,
               ctl_slots => 0, reader => 0, facets => #{}, inspect => none},
    Next = State#{next_id := Id + 1, names := Names#{erx_ident:to_binary(Name) => Binding#{holder := Id}},
                  domains := Domains#{Id => Domain}},
    {ok, Domain, Next}.

-doc """
The library built domain Id, with system connection Connection, whose control table has
CtlSlots slots, one per connection the domain may hold, and whose rings it reads have
Reader bytes of data each; Pid and Ref are its domain pid's.
Facets, if given, are the processes the domain gets a facet in front of when it reports
ready (erx_domain_srv).
""".
-spec built(pos_integer(), #{connection := non_neg_integer(), ctl_slots := non_neg_integer(),
                             reader := non_neg_integer(), atom() => term()},
            pid(), reference(), state()) -> state().
built(Id, #{connection := Connection, ctl_slots := CtlSlots, reader := Reader} = Created, Pid, Ref, State) ->
    update(Id, building, #{state => built, connection => Connection, ctl_slots => CtlSlots, reader => Reader,
                           pid => Pid, ref => Ref, facets => maps:get(facets, Created, #{})}, State).

-doc "Domain Id's first thread started.".
-spec running(pos_integer(), state()) -> state().
running(Id, State) ->
    update(Id, built, #{state => running}, State).

-doc """
Domain Id's init reported ready, naming Inspect as its inspection agent, which
the domain's pid kept only when the domain owns it, or none.
""".
-spec ready(pos_integer(), pid() | none, state()) -> state().
ready(Id, Inspect, State) ->
    update(Id, running, #{state => ready, inspect => Inspect}, State).

-doc "Domain Id's boot timeout passed before its init reported ready, and it is being stopped.".
-spec stopping(pos_integer(), state()) -> state().
stopping(Id, State) ->
    update(Id, running, #{state => stopping}, State).

-doc "The library refused to build domain Id: its record goes and its name is free. Its id stays spent.".
-spec failed(pos_integer(), state()) -> state().
failed(Id, #{domains := Domains} = State) ->
    #{Id := #{state := building} = Domain} = Domains,
    free_name(Domain, State#{domains := maps:remove(Id, Domains)}).

-doc """
Domain Id ended with End, the library's {Kind, Status}, at Now: the domain's
Info for {domain_down, Id, Info}, the domain as it was, and the state without
the domain, its name free and its death recorded, the last ?DEATHS_KEPT per
principal. Slogan is what the domain service read from a crash's crash
area, which the crash's death record keeps; none for any other end. The end
of an unknown id, or of a domain neither built, running, ready nor stopping,
is none.
""".
-spec ended(pos_integer(), {atom(), integer()}, slogan() | none, integer(), state()) ->
          {info(), domain(), state()} | none.
ended(Id, End, Slogan, Now, #{domains := Domains, deaths := Deaths} = State) ->
    case Domains of
        #{Id := #{state := Life, principal := Principal, name := Name} = Domain}
          when Life =:= built; Life =:= running; Life =:= ready; Life =:= stopping ->
            Info = info(End),
            Death = death(#{id => Id, name => Name, info => Info, at => Now}, Slogan),
            Kept = lists:sublist([Death | maps:get(Principal, Deaths, [])], ?DEATHS_KEPT),
            Next = State#{domains := maps:remove(Id, Domains),
                          deaths := Deaths#{Principal => Kept}},
            {Info, Domain, free_name(Domain, Next)};
        #{} ->
            none
    end.

-doc """
Whether configured row Row restarts at Now, in seconds: yes while fewer than
Restarts restarts of it fell within the last PeriodS seconds, recording this
one; no otherwise.
""".
-spec restart(non_neg_integer(), non_neg_integer(), non_neg_integer(), integer(), state()) ->
          {yes | no, state()}.
restart(Row, Restarts, PeriodS, Now, #{restarts := History} = State) ->
    Recent = [At || At <- maps:get(Row, History, []), Now - At < PeriodS],
    case length(Recent) < Restarts of
        true -> {yes, State#{restarts := History#{Row => [Now | Recent]}}};
        false -> {no, State#{restarts := History#{Row => Recent}}}
    end.

-doc "Domain Id's record, or none.".
-spec fetch(pos_integer(), state()) -> {ok, domain()} | none.
fetch(Id, #{domains := Domains}) ->
    case Domains of
        #{Id := Domain} -> {ok, Domain};
        #{} -> none
    end.

-doc "The domain whose domain pid is Pid, or none.".
-spec find_pid(pid(), state()) -> {ok, domain()} | none.
find_pid(Pid, #{domains := Domains}) ->
    case [Domain || #{pid := P} = Domain <- maps:values(Domains), P =:= Pid] of
        [Domain] -> {ok, Domain};
        [] -> none
    end.

-doc "Principal's last deaths, newest first.".
-spec deaths(pos_integer(), state()) -> [death()].
deaths(Principal, #{deaths := Deaths}) ->
    maps:get(Principal, Deaths, []).

-doc "Every domain the state keeps, by id.".
-spec domains(state()) -> [domain()].
domains(#{domains := Domains}) ->
    [Domain || {_, Domain} <- lists:sort(maps:to_list(Domains))].

-doc "The Info of {domain_down, D, Info} for the library's end {Kind, Status}.".
-spec info({atom(), integer()}) -> info().
info({halt, Status}) -> {halt, Status};
info({crash, _}) -> crash;
info({fault, Kind}) -> {fault, Kind};
info({stopped, _}) -> stopped.

-doc """
The scope of the inspect facet the service mints for a domain of Principal
(docs/design-live.md, "The inspect service"): `all`, every domain, for root
in a development build, and otherwise `{principal, Principal}`, the
principal's own domains, which the inspector resolves at each query. Root is
any of Roots, the system manifest's system-shell principals, and Development
is the manifest's development flag (erx_build:development/0); the caller
reads both, so no principal number is root by itself. This is the one
decision of an inspect facet's scope.
""".
-spec inspect_scope(pos_integer(), [pos_integer()], boolean()) -> inspect_scope().
inspect_scope(Principal, Roots, Development)
  when is_integer(Principal), Principal > 0, is_list(Roots), is_boolean(Development) ->
    case Development andalso lists:member(Principal, Roots) of
        true -> all;
        false -> {principal, Principal}
    end.

-doc """
The domains Scope covers, for the inspector's query worker
(docs/design-live.md, "The inspect service"), in id order: each living
domain of the scope with the inspection agent its ready report named,
`none` while it has none, and each domain whose death record is kept,
`ended`. `{principal, P}` covers P's domains, living and ended, so the
inspector resolves a principal's scope from these records at each query.
""".
-spec inspect_view(inspect_scope(), state()) -> [{pos_integer(), pid() | none | ended}].
inspect_view(Scope, #{domains := Domains, deaths := Deaths}) ->
    Living = [{Id, Agent} || Id := #{principal := Principal, inspect := Agent} <- Domains,
                             covers(Scope, Principal)],
    Ended = [{Id, ended} || Principal := Kept <- Deaths, covers(Scope, Principal),
                            #{id := Id} <- Kept, not is_map_key(Id, Domains)],
    lists:usort(Living ++ Ended).

covers(all, _Principal) -> true;
covers({principal, Principal}, Principal) -> true;
covers({principal, _Other}, _Principal) -> false.

%% Only a crash's death carries a slogan.
death(#{info := crash} = Death, Slogan) when Slogan =/= none -> Death#{slogan => Slogan};
death(Death, none) -> Death.

update(Id, From, Changes, #{domains := Domains} = State) ->
    #{Id := #{state := From} = Domain} = Domains,
    State#{domains := Domains#{Id := maps:merge(Domain, Changes)}}.

free_name(#{id := Id, name := Name}, #{names := Names} = State) ->
    Bytes = erx_ident:to_binary(Name),
    case Names of
        #{Bytes := #{holder := Id} = Binding} -> State#{names := Names#{Bytes := Binding#{holder := none}}};
        #{} -> State
    end.
