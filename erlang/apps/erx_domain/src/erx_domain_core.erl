%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_core).
-moduledoc """
The domain service's pure core (docs/design-system.md, "The domain service's
record"; docs/design-domains.md, "Domain ids, pids and references"): ids,
names, each domain's life, death records, configured restarts, the scope
of a domain's inspect facet (inspect_scope/3) and the plan of an app's
session (app_session/4). It makes
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
         restart/5, intensity/4, fetch/2, find_pid/2, deaths/2, domains/1, info/1, fault_where/2, session_prefix/3,
         session_name/3, session_reserved/1, names_quota/0, system_user/0, app_session/4]).
-export([inspect_scope/3, inspect_view/2]).
-export_type([state/0, domain/0, origin/0, info/0, slogan/0, inspect_scope/0, inspect_entry/0,
              app_session/0, template_row/0, session_row/0, intensity/0, reached/0, restart/0]).

-include("generated/erx_abi.hrl").

-define(ID_MAX, 16#ffffffff).
-define(NAMES_QUOTA, 64).
%% The prefix of the system principal's session names.
-define(SYSTEM_PREFIX, <<"root">>).
-define(DEATHS_KEPT, 16).

-type origin() :: request | {configured, Row :: non_neg_integer()} | {session, Template :: non_neg_integer()}.
-type life() :: building | built | running | ready | stopping.
-type info() :: {halt, integer()} | crash | {fault, integer()} | stopped.
%% A restart intensity (intensity/4): at most restarts restarts that still count.
-type intensity() :: #{restarts := non_neg_integer(), period_s := non_neg_integer()}.
%% How far the boot of what ended got: stopped at its boot timeout, ended before its
%% init reported ready, or ended after.
-type reached() :: timed_out | before_ready | ready.
%% A restart a history keeps: timed_out for one after a boot timeout, which no time
%% ages, or the monotonic second of any other.
-type restart() :: timed_out | integer().
-type domain() :: #{id := pos_integer(), name := erx_ident:t(), node := node(),
                    principal := pos_integer(), origin := origin(), state := life(),
                    pid := pid() | undefined, ref := reference() | undefined,
                    connection := non_neg_integer(),
                    ctl_slots := non_neg_integer(), reader := non_neg_integer(),
                    facets := #{atom() => {pid(), map()}}, start := start(), inspect := pid() | none,
                    rows := [session_row()], app := erx:app_record() | none}.
%% A session's facet row, decided once as the session is planned (erx_domain_srv): the
%% service's name, its server, a configured row or system, and the grant's limits; a
%% domain of no session holds none. An app's session alone carries the app's record.
-type session_row() :: {atom(), non_neg_integer() | system, map()}.
%% A session's start beyond its console (erx_domain:start_session/2): the display it is
%% the session of, or the display it only takes as its default; a domain of no session has
%% none.
-type start() :: #{display => atom(), default_display => atom()}.
-type binding() :: #{principal := pos_integer(), node := node(), holder := none | pos_integer()}.
-type death() :: #{id := pos_integer(), name := erx_ident:t(), info := info(), at := integer(),
                   slogan => slogan()}.
%% Every domain, or the domains of one principal (inspect_scope/3).
-type inspect_scope() :: all | {principal, pos_integer()}.
%% A domain of the inspect view (inspect_view/2): its id, its inspection
%% agent, and this service's report of it, none for a domain that ended.
-type inspect_entry() :: {pos_integer(), pid() | none | ended,
                          #{name := binary(), principal := pos_integer(),
                            state := booting | running | ending} | none}.
%% The plan of an app's session (app_session/4): the app's entry and principal, the
%% prefix of the session's name, the session's own memory and the app template's
%% facet rows the session holds, each as the caller gave it but the ble row, whose
%% services the plan narrows.
-type app_session() :: #{entry := non_neg_integer(), principal := pos_integer(),
                         prefix := binary(),
                         memory := pos_integer(), rows := [template_row()]}.
%% A facet row of the app template as the domain service keeps it: its service's
%% name, its server, and its limits, each parameter among them under its
%% abi/services name (erx_domain_lib:configured/0).
-type template_row() :: {atom(), non_neg_integer() | system, map()}.
%% A crash's slogan as the domain wrote it, untrusted text, or why its crash area could not be read.
-type slogan() :: binary() | {unreadable, atom() | {status, integer()}}.
-opaque state() :: #{host := binary(), next_id := pos_integer(),
                     names := #{binary() => binding()},
                     bound := #{pos_integer() => non_neg_integer()},
                     domains := #{pos_integer() => domain()},
                     deaths := #{pos_integer() => [death()]},
                     restarts := #{non_neg_integer() => [restart()]}}.

-doc "The state of a boot whose machine is named Host, an identifier.".
-spec new(binary()) -> state().
new(Host) when is_binary(Host) ->
    #{host => Host, next_id => ?ERX_SYSTEM_DOMAIN_ID + 1, names => #{}, bound => #{}, domains => #{},
      deaths => #{}, restarts => #{}}.

-spec host(state()) -> binary().
host(#{host := Host}) -> Host.

-doc """
Admits a domain named Name for Principal: spends the next id, binds the name
and records the domain as building. It refuses with system_limit, name_taken
or quota, leaving the state as it was. A name session naming keeps
(session_reserved/1) is name_taken for every origin but a session, which the
service names (session_name/3), so one funnel keeps each prefix's session names
for its own principal's sessions.
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
    Reserved = not is_session(Origin) andalso session_reserved(Bytes),
    case Names of
        %% First, so a request cannot take even a session name that is bound and free.
        #{} when Reserved ->
            {error, name_taken};
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

is_session({session, _Template}) -> true;
is_session(_Origin) -> false.

-doc "How many names each principal binds, its app principals included.".
-spec names_quota() -> pos_integer().
names_quota() -> ?NAMES_QUOTA.

-doc """
The system principal's user name, root, the prefix of its session names and
the name its grants carry (docs/design-files.md, "A user's home").
""".
-spec system_user() -> binary().
system_user() -> ?SYSTEM_PREFIX.

-doc """
The prefix of Principal's session names (docs/design-apps.md, "Starting a
session"): root for the system principal System, so its sessions stay
root_1, root_2 and on, and for any other principal its name in the system
manifest, of Names, the manifest's principal names by number, so a session
of principal clock is clock_1. error for a principal Names does not name.
""".
-spec session_prefix(pos_integer(), pos_integer() | unknown, #{pos_integer() => binary()}) ->
          {ok, binary()} | error.
session_prefix(System, System, _Names) -> {ok, ?SYSTEM_PREFIX};
session_prefix(Principal, _System, Names) -> maps:find(Principal, Names).

-doc """
The plan of a session of the app Name (docs/design-packaging.md, "An app's
session"), from App, Name's record in the registry of app principals
(erx_principal:app/2), Apps, the app entries the domain library placed
(erx_domain_lib:apps/0), and TemplateRows, the app template's facet rows,
each {Index, Row} by its index in the manifest's facet table:

* the principal is the app's entry, Apps' first + the record's entry, and
  every facet's parameters, its inspect scope among them, are computed from
  it, as any session's are from its principal;
* the session's names are drawn from the app's own pool, Name_N;
* the entry is what the library plans the session under: it plans the app
  template for an app entry and no other (erx_dom_plan_app_session), so the
  plan names no template, and no grant keyed by the template's whole row
  set follows from it;
* the memory is the declared one the record holds, the session's own budget;
* the rows are those of TemplateRows whose index the record kept, the
  `packages` row and one for each need, each whole, and the `ble` row when
  the record holds one, its `services` replaced by the intersection of the
  row's set and the record's GATT services, so the grant never names a
  service the row does not offer, whatever the record holds, and names only
  the services admission gave the app (PK13); and no other.

Nothing of the plan depends on the record's signer, so one header admitted
as an image package and as an installed one gives one plan (PK10). The
record is the domain service's own (erx_principal:register/2), written
in the entry erx_app_admit:entry/4 gives below the registry's max, Apps'
count, from an admission against the same manifest, so its rows are the
template's.
""".
-spec app_session(binary(), erx_principal:app(), erx_domain_lib:apps(), [{non_neg_integer(), template_row()}]) ->
          app_session().
app_session(Name, #{entry := Entry, memory := Memory, rows := Kept, ble := Ble}, #{first := First}, TemplateRows) ->
    #{entry => Entry, principal => First + Entry, prefix => Name, memory => Memory,
      rows => [Granted || {Index, Row} <- TemplateRows, Granted <- granted(Index, Row, Kept, Ble)]}.

%% A template row as the session holds it: the ble row narrowed to the record's
%% services, a kept row whole, any other not at all. The ble index is never in
%% Kept, so a ble row without its services parameter is granted to no session.
granted(Index, {Name, Server, #{services := Offered} = Limits}, _Kept, #{row := Index, gatt := Gatt}) ->
    [{Name, Server, Limits#{services := [Service || Service <- Offered, lists:member(Service, Gatt)]}}];
granted(Index, Row, Kept, _Ble) ->
    [Row || lists:member(Index, Kept)].

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

-doc """
Whether session naming keeps Name: root, the system principal's prefix, or a
name of a session name's form, an identifier's bytes, `_` and decimal digits.
Only a session takes either (admit/4), and no app is named either
(erx_app_admit). Name is an identifier's bytes.
""".
-spec session_reserved(binary()) -> boolean().
session_reserved(?SYSTEM_PREFIX) ->
    true;
session_reserved(Name) ->
    case string:split(Name, <<"_">>, trailing) of
        [Prefix, Digits] when Prefix =/= <<>>, Digits =/= <<>> ->
            lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits));
        _ ->
            false
    end.

take(Name, #{node := Node} = Binding, Principal, Origin,
     #{next_id := Id, names := Names, domains := Domains} = State) ->
    Domain = #{id => Id, name => Name, node => Node, principal => Principal, origin => Origin,
               state => building, pid => undefined, ref => undefined, connection => 0,
               ctl_slots => 0, reader => 0, facets => #{}, start => #{}, inspect => none, rows => [], app => none},
    Next = State#{next_id := Id + 1, names := Names#{erx_ident:to_binary(Name) => Binding#{holder := Id}},
                  domains := Domains#{Id => Domain}},
    {ok, Domain, Next}.

-doc """
The library built domain Id, with system connection Connection, whose control table has
CtlSlots slots, one per connection the domain may hold, and whose rings it reads have
Reader bytes of data each; Pid and Ref are its domain pid's.
Facets, if given, are the processes the domain gets a facet in front of when it reports
ready (erx_domain_srv), and Start, if given, is a session's start beyond its console.
""".
-spec built(pos_integer(), #{connection := non_neg_integer(), ctl_slots := non_neg_integer(),
                             reader := non_neg_integer(), atom() => term()},
            pid(), reference(), state()) -> state().
built(Id, #{connection := Connection, ctl_slots := CtlSlots, reader := Reader} = Created, Pid, Ref, State) ->
    update(Id, building, #{state => built, connection => Connection, ctl_slots => CtlSlots, reader => Reader,
                           pid => Pid, ref => Ref, facets => maps:get(facets, Created, #{}),
                           start => maps:get(start, Created, #{}), rows => maps:get(rows, Created, []),
                           app => maps:get(app, Created, none)}, State).

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
Whether configured row Row restarts at Now, in seconds, within Intensity
(intensity/4), after one of its domains ended in life Life (ended/5),
recording this restart if it does.
""".
-spec restart(non_neg_integer(), intensity(), life(), integer(), state()) -> {yes | no, state()}.
restart(Row, Intensity, Life, Now, #{restarts := History} = State) ->
    {Answer, Kept} = intensity(maps:get(Row, History, []), Intensity, reached(Life), Now),
    {Answer, State#{restarts := History#{Row => Kept}}}.

%% How far an ended domain's boot got, from its life at its end: a stopping domain is
%% one stopped at its boot timeout (stopping/2).
reached(stopping) -> timed_out;
reached(ready) -> ready;
reached(Life) when Life =:= built; Life =:= running -> before_ready.

-doc """
The restart intensity, as OTP's supervisors count it, except for boots that
time out. It decides whether something with the earlier restarts Earlier
restarts at Now, in seconds, after an end whose boot reached Reached: yes
while fewer than restarts of them still count, with this restart kept beside
them; no with those alone. A configured row's restarts (restart/5) and the
console's login (erx_console) are counted here.

A restart after a boot timeout counts until a boot that reached ready ends,
however long that takes and however briefly that boot was ready; a restart
after any other end counts for period_s seconds. A boot that hangs is stopped
only at each timeout, so its restarts come a boot timeout apart, and counting
them by time would restart it without end on a machine whose boot timeout is
long against period_s / restarts. Counted this way, a boot that hangs every
time is left down after restarts restarts in a row, whatever the boot timeout.
""".
-spec intensity([restart()], intensity(), reached(), integer()) -> {yes | no, [restart()]}.
intensity(Earlier, #{restarts := Restarts, period_s := PeriodS}, Reached, Now) ->
    Counted = [Restart || Restart <- Earlier, counts(Restart, Reached, Now, PeriodS)],
    case length(Counted) < Restarts of
        true -> {yes, [record(Reached, Now) | Counted]};
        false -> {no, Counted}
    end.

%% Whether an earlier restart still counts at an end whose boot reached Reached.
counts(timed_out, Reached, _Now, _PeriodS) -> Reached =/= ready;
counts(At, _Reached, Now, PeriodS) -> Now - At < PeriodS.

%% The restart a history keeps for one at Now after an end whose boot reached Reached.
record(timed_out, _Now) -> timed_out;
record(_Reached, Now) -> Now.

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
Where a fault struck, as the tail of a configured domain's end line: the fault record of
the stop that ended the domain, which erx_domain_lib reports as the exit record's fault, as
" at pc 0xP, cause 0xC, addr 0xA". These are the kernel's own record of the fault, nothing
read from the domain's memory. Only a memory, deleted or alignment fault names an
address; any other reads "addr unknown" rather than a number the kernel did not report.
An asynchronous error (an SError on AArch64) is taken at a later return to user mode, on
whatever thread runs then, so its thread is only presumed to be the source and its pc is
where that thread was: its tail begins "presumed at pc". "" for any other end, and for a
record without the fault.
""".
-spec fault_where({atom(), integer()}, map()) -> iodata().
fault_where({fault, _Kind}, #{fault := #{kind := Kind, cause := Cause, addr := Addr, pc := Pc}}) ->
    [fault_at(Kind), hex(Pc), ", cause ", hex(Cause), ", addr ", fault_addr(Kind, Addr)];
fault_where(_End, _Record) ->
    "".

fault_at(?ERX_FAULT_ASYNC_ERROR) -> " presumed at pc ";
fault_at(_Kind) -> " at pc ".

fault_addr(Kind, Addr) when Kind =:= ?ERX_FAULT_MEMORY; Kind =:= ?ERX_FAULT_DELETED;
                            Kind =:= ?ERX_FAULT_ALIGNMENT ->
    hex(Addr);
fault_addr(_Kind, _Addr) ->
    "unknown".

hex(N) -> ["0x", string:lowercase(integer_to_list(N, 16))].

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
`none` while it has none, and this service's report of it, its name,
principal and state; and each domain whose death record is kept, `ended`
with no report. `{principal, P}` covers P's domains, living and ended, so
the inspector resolves a principal's scope from these records at each
query.
""".
-spec inspect_view(inspect_scope(), state()) -> [inspect_entry()].
inspect_view(Scope, #{domains := Domains, deaths := Deaths}) ->
    Living = [{Id, Agent, #{name => erx_ident:to_binary(Name), principal => Principal,
                            state => inspect_state(Life)}}
              || Id := #{principal := Principal, inspect := Agent, name := Name, state := Life} <- Domains,
                 covers(Scope, Principal)],
    Ended = [{Id, ended, none} || Principal := Kept <- Deaths, covers(Scope, Principal),
                                  #{id := Id} <- Kept, not is_map_key(Id, Domains)],
    lists:usort(Living ++ Ended).

%% A domain's life as the inspection schema's domain_state names it: booting
%% until its init reports ready, and ending once it is stopping.
inspect_state(building) -> booting;
inspect_state(built) -> booting;
inspect_state(running) -> booting;
inspect_state(ready) -> running;
inspect_state(stopping) -> ending.

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
