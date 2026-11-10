%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_core).
-moduledoc """
The domain service's pure core (docs/design-system.md, "The domain service's
record"; docs/design-domains.md, "Domain ids, pids and references"): ids,
names, each domain's life, death records and configured restarts. It makes
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
?NAMES_QUOTA names by request, which bounds the node-name atoms admit/4 makes
(D5): the atom is made once, when the name is first bound and after the
quota check, and every later domain of the name reuses it. The configured
domains bind theirs at boot outside the quota, since the checked manifest
bounds them.

A domain's life: building (admitted, the library not yet asked) -> built
(the library made it) -> running (its first thread started) -> ended (its
end arrived) -> retired (its record is gone). A creation the library refuses
goes from building to nothing, freeing its name. A transition from any other
state is a bug of the caller and fails with a badmatch.
""".

-export([new/1, host/1, admit/4, built/5, running/2, failed/2, ended/5, retired/2,
         restart/5, fetch/2, find_pid/2, deaths/2, domains/1, info/1]).
-export_type([state/0, domain/0, origin/0, info/0, slogan/0]).

-define(SYSTEM_ID, 4).
-define(ID_MAX, 16#ffffffff).
-define(NAMES_QUOTA, 64).
-define(DEATHS_KEPT, 16).

-type origin() :: request | {configured, Row :: non_neg_integer()}.
-type life() :: building | built | running | ended.
-type info() :: {halt, integer()} | crash | {fault, integer()} | stopped.
-type domain() :: #{id := pos_integer(), name := erx_ident:t(), node := node(),
                    principal := pos_integer(), origin := origin(), state := life(),
                    pid := pid() | undefined, ref := reference() | undefined,
                    connection := non_neg_integer(), ended := undefined | {info(), integer()}}.
-type binding() :: #{principal := pos_integer(), node := node(), holder := none | pos_integer()}.
-type death() :: #{id := pos_integer(), name := erx_ident:t(), info := info(), at := integer(),
                   slogan => slogan()}.
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
    case Names of
        #{Bytes := #{principal := Principal, holder := none} = Binding} ->
            take(Name, Binding, Principal, Origin, State);
        #{Bytes := _} ->
            {error, name_taken};
        #{} when Origin =:= request, Count >= ?NAMES_QUOTA ->
            {error, quota};
        #{} ->
            Node = binary_to_atom(<<Bytes/binary, $@, (host(State))/binary>>, latin1),
            Binding = #{principal => Principal, node => Node, holder => none},
            take(Name, Binding, Principal, Origin, State#{bound := Bound#{Principal => Count + 1}})
    end.

take(Name, #{node := Node} = Binding, Principal, Origin,
     #{next_id := Id, names := Names, domains := Domains} = State) ->
    Domain = #{id => Id, name => Name, node => Node, principal => Principal, origin => Origin,
               state => building, pid => undefined, ref => undefined, connection => 0, ended => undefined},
    Next = State#{next_id := Id + 1, names := Names#{erx_ident:to_binary(Name) => Binding#{holder := Id}},
                  domains := Domains#{Id => Domain}},
    {ok, Domain, Next}.

-doc "The library built domain Id, with system connection Connection; Pid and Ref are its domain pid's.".
-spec built(pos_integer(), non_neg_integer(), pid(), reference(), state()) -> state().
built(Id, Connection, Pid, Ref, State) ->
    update(Id, building, #{state => built, connection => Connection, pid => Pid, ref => Ref}, State).

-doc "Domain Id's first thread started.".
-spec running(pos_integer(), state()) -> state().
running(Id, State) ->
    update(Id, built, #{state => running}, State).

-doc "The library refused to build domain Id: its record goes and its name is free. Its id stays spent.".
-spec failed(pos_integer(), state()) -> state().
failed(Id, #{domains := Domains} = State) ->
    #{Id := #{state := building} = Domain} = Domains,
    free_name(Domain, State#{domains := maps:remove(Id, Domains)}).

-doc """
Domain Id ended with End, the library's {Kind, Status}, at Now: the domain's
Info for {domain_down, Id, Info}, the domain as it was, and the state with the
domain ended, its name free and its death recorded, the last ?DEATHS_KEPT per
principal. Slogan is what the domain service read from a crash's crash
area, which the crash's death record keeps; none for any other end. The end
of an unknown id, or of a domain neither built nor running, is none.
""".
-spec ended(pos_integer(), {atom(), integer()}, slogan() | none, integer(), state()) ->
          {info(), domain(), state()} | none.
ended(Id, End, Slogan, Now, #{domains := Domains, deaths := Deaths} = State) ->
    case Domains of
        #{Id := #{state := Life, principal := Principal, name := Name} = Domain}
          when Life =:= built; Life =:= running ->
            Info = info(End),
            Death = death(#{id => Id, name => Name, info => Info, at => Now}, Slogan),
            Kept = lists:sublist([Death | maps:get(Principal, Deaths, [])], ?DEATHS_KEPT),
            Next = State#{domains := Domains#{Id := Domain#{state := ended, ended := {Info, Now}}},
                          deaths := Deaths#{Principal => Kept}},
            {Info, Domain, free_name(Domain, Next)};
        #{} ->
            none
    end.

-doc "The library retired ended domain Id: its record goes.".
-spec retired(pos_integer(), state()) -> state().
retired(Id, #{domains := Domains} = State) ->
    #{Id := #{state := ended}} = Domains,
    State#{domains := maps:remove(Id, Domains)}.

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
