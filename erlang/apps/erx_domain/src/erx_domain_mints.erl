%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_mints).
-moduledoc """
The domain service's pure core for facets a configured domain serves
(docs/design-system.md, "Facets a configured domain serves"). It decides
which providers a server's ready report may name, when each configured grant
is minted, and what is installed where. It makes no call: step/2 returns the
actions to perform, in order, and erx_domain_srv performs them and feeds back
what they produce as events.

Rows and incarnations. A configured domain is named by its row in the
manifest, and each start of it is an incarnation, named by its domain id,
which no other domain takes within a boot, and reached at its node. The core
keeps, per row, the newest incarnation it has heard of: ready, with its node
and its accepted providers, or ended. A ready report of an id no newer than
that one is stale and provides nothing. The system domain, id 4, is always
ready.

Owned pids. A pid belongs to an incarnation when its node is the
incarnation's node and its creation, erx:owner/1, is the incarnation's id.
Both are checked: a send goes over the connection its node names, and the
creation is a field the pid's maker wrote, so a pid with one domain's
creation and another's node would carry the system domain's request to the
other.

Providers. A ready report's provides map is the server's own words. Only
names the row's service rows declare, each mapped to a pid the reporting
incarnation owns, are kept. Every other entry, and a value that is not a map
or is larger than the row's declarations, is refused, as a refused action
that erx_domain_srv logs and counts; the incarnation is ready all the same.

Sessions. A session is one incarnation, never restarted, named by its id.
Its rows, the facet rows of configured domains' services it holds, are
decided once, by the service, when the session is planned: a template's
session holds every row granted to its template, and an app's session the
app template's packages row and the rows its admission kept, and no other
(docs/design-packaging.md, "An app's session"). Its ready report,
{session_ready, Rows, Id, Node, Marked, Provides}, carries them and adds a grant keyed by
{session, Id} for each, so no session holds a row its plan did not give
it, whatever else its template is granted; its end,
{session_ended, Id}, cancels their operations and deletes them, so the
core holds entries only for live sessions, each its own. The service
passes a session's report on at most once and before its end, and takes
its rows from its own record of the domain, never from the report;
a second report of a live session is refused as stale, and an end of a
session the core does not hold changes nothing.

The session mark (docs/design-system.md, "Facets a configured domain
serves"). Each grant carries a mark, fixed when the grant is added and
never changed. A session's ready report names {display, Name} for the
display its start named, or none; the mark is true only for that
session's grant of Name, and false for every other grant, a configured
row's and the system domain's included. Every
mint of a grant carries its limits with session => true where it is
marked and with no session where it is not, the first mint and each one
after its server's restart alike, so no facet row's limits can set it and
no grant but the marked one ever carries it. A display the template does not
grant marks nothing, so the mark never adds a grant.

Grants. Each grant, keyed by its grantee (a row, system or a session)
and its service's name, has one state:

    idle | {introducing, Pair, Tag} | {minting, Pair, Tag}
         | {installing, Pair, Tag, Facet} | {installed, Pair, Facet}
         | {failed, Pair, Reason}

Pair is {ServerId, GranteeId}. A grant's current pair is its server row's
ready incarnation, if that provides the grant's name, and its grantee's
ready incarnation; its carried pair is the one its state names. After every
ready and end, reconcile/1 brings each grant whose carried pair differs from
its current one to the current one: the pending operation is cancelled and
its deadline disarmed, and a new operation starts if there is a current
pair. So a grant has at most one operation, every operation is bound to two
current incarnations, and a repeated trigger changes nothing. A failed pair
stays failed until an incarnation of it changes.

An operation has a tag, a number the core never reuses, and one deadline
for its whole introduction, mint and installation. Introducing is skipped
for the system domain as grantee, which every domain is connected to.

The pixel area (docs/design-display.md, "The pixel area"). A pixel area is
a fact of a pair of domains, not of an introduction: pair_area/3 decides it
from the two parties' origins alone, a configured row's by the manifest's
grants and a session's by the facet rows its plan gave it, so every
introduction that makes the pair's connection, a grant's or
erx_domain:introduce/2's, makes the same area. A pair one of whose parties
serves a service of the windows interface the other holds, a configured
row by its grant or a session by its row, has an area read by the server:
the grant's pixels, or windows_pixels_default where its limits state none,
rounded up to whole pages. Every other pair has none.

Replies are untrusted. A mint's reply counts only from the pair's server,
for the operation in minting with its tag; an acknowledgement only from the
pair's grantee, for the operation in installing with its tag. Anything else
is dropped, as a dropped action logged and counted. A reply that counts
settles its step: {ok, Facet}, Facet a pid the server's incarnation owns,
or for a service of an interface abi/services declares served_as tree
{ok, Facet, Tree}, Tree a plain name, moves to installing; any other reply
fails the operation (admitted/4). Since an operation
exists only while its pair is current, a reply after either domain's end
matches nothing. Refused, dropped and failed actions carry only bounded
terms: atoms, the service's own numbers, or a reason the core names.

Namespaces. A grantee's namespace is in place (docs/design-system.md, "A
session takes the console") when each of its grants of a files service,
the names config's files lists, has settled: installed, failed, or idle
while its server row is not starting. in_place/3 decides it from the
grants alone and the rows the service names as starting, so it needs no
state of its own, and a grant with an operation is bounded by its
deadline, a starting server by its boot timeout. A server has settled by
the same rule (server_settled/3): no starting row serves its service.

One incarnation's grant (docs/design-system.md, "A session takes the
console"). system_grant/4 answers a wait for the system domain's grant of a
service from one incarnation of its server row, from the grant's state and
that row's newest incarnation alone: the facet once the grant is installed
with that incarnation as its server, failed once it failed so, ended once the
incarnation has ended or the grant carries another server, and unprovided
once the incarnation is ready and the grant idle, since it provides no such
name and the core starts no operation for it. It answers wait otherwise:
while the grant's operation for the incarnation is pending, which its deadline
bounds, or while the core has not yet heard of the incarnation and the
server row is starting, which the row's boot timeout bounds, since a ready
report or an end follows; one not heard of once the row is not starting is
ended, since the core will hear of it no more. The grant is matched by the incarnation,
never by the service alone, so no wait is answered with a predecessor's facet.

The settlement wait (docs/design-system.md, "Waiting for a grant").
settled/3 answers each query of the closed set query() by one of the three
decisions above, namespace by in_place/3 for the system domain, {server, Name}
by server_settled/3 and {grant, Name, Id} by system_grant/4, or answers wait,
so the domain service keeps every waiter in one list and asks it again after
each change of the grants or the starting rows.

A session's lines (docs/design-system.md, "A session's lines"). A session's
ready report also carries its node and its provides, the mints of its lines,
each under a name of ?ERX_LINES. A name outside them refuses the map whole; a
value that is no pid the session owns refuses its entry alone, and the other
lines stand. Beside its grants the core keeps one line operation for each
session and line name it was asked for and has not answered:

    {introducing, Pair, Tag} | {minting, Pair, Tag}

Pair is {SessionId, PeerId}, fixed when the request makes the operation and
never reconciled. A request {line, Asker, Name, Session, Peer, Opening} is
answered at once with no_line when the session is not ready or has no accepted
mint under Name, with busy while an operation for the session's Name is
pending, and with ended when the peer is no domain whose end the core hears; otherwise it arms the deadline and introduces the two domains, which
is skipped for the system domain as peer, as for a grant. Once introduced, the
mint request goes to the session's mint of Name with the quantities ?ERX_LINES
gives Name and the opening, so no facet row can set either. A mint reply
counts only from the session, with the operation's tag, and settles it at
once: {ok, Facet} with Facet a pid the session owns answers {ok, Facet}, and
any other reply refused. The session's end answers no_line, the peer's end,
as a configured row's or a session's, ended, a refused introduction its
reason and the deadline unavailable. Each answer is the action {answer,
Asker, Reply}, its deadline disarmed unless the deadline answered, and nothing
of the operation is kept after it. Grants and line operations take their tags
from one counter, so a tag names one of them at most.
""".

-export([new/1, step/2, grants/1, granted/3, granted_names/2, granted_services/2, in_place/3, settled/3,
         pair_area/3]).
-export_type([state/0, config/0, event/0, action/0, grant/0, key/0, pair/0, query/0]).

-define(DEADLINE, 10000).

-include("generated/erx_abi.hrl").

-type row() :: non_neg_integer().
-type id() :: pos_integer().
-type name() :: atom().
-type tag() :: pos_integer().
-type template() :: non_neg_integer().
-type grantee() :: row() | system | {session, id()}.
%% The name a grant is installed under in its grantee's registry, the registry's own
%% name: its service's name, or for a drive window row's grant {drive, N}, N the row's
%% drive number.
-type installed() :: erx_facets:name().
-type key() :: {grantee(), installed()}.
-type pair() :: {ServerId :: id(), GranteeId :: id()}.
-type pending() :: introducing | minting | installing.
-type reason() :: {introduce, term()} | bad_reply | {deadline, pending()}.
%% The service whose grant a session's ready report marks, the display its start named.
-type marked() :: {display, name()} | none.
%% What a process of the system domain waits to see settle (settled/3), a closed set.
-type query() :: namespace | {server, name()} | {grant, name(), id()}.
-type grant() :: idle
               | {introducing, pair(), tag()}
               | {minting, pair(), tag()}
               | {installing, pair(), tag(), erx_facets:facet()}
               | {installed, pair(), erx_facets:facet()}
               | {failed, pair(), reason()}.
-type config() :: #{services := [{Server :: row(), name()}],
                    grants := [{Grantee :: row() | system | {template, template()}, name(), Server :: row(),
                                Limits :: map()}],
                    owner := fun((pid()) -> non_neg_integer()),
                    files => [name()],
                    windows => [name()],
                    inputs => [name()],
                    interfaces => #{{Server :: row(), name()} => pos_integer()},
                    drives => [{Server :: row(), Grantee :: row(), Drive :: non_neg_integer()}],
                    deadline => pos_integer()}.
%% ready carries the incarnation's node, which the service knows; the rest of the
%% untrusted events' fields are any term a domain sent.
-type event() :: {ready, row(), id(), node(), Provides :: term()}
               | {ended, row(), id()}
               | {session_ready, [{name(), row(), map()}], id(), node(), marked(), Provides :: term()}
               | {line, Asker :: term(), name(), Session :: id(), Peer :: id(), Opening :: pid()}
               | {session_ended, id()}
               | {introduced, tag(), ok | {error, term()}}
               | {minted, Origin :: non_neg_integer(), Tag :: term(), Reply :: term()}
               | {installed, Origin :: non_neg_integer(), Tag :: term()}
               | {deadline, tag()}.
-type action() :: {introduce, tag(), ServerId :: id(), GranteeId :: id()}
                | {mint, tag(), Mint :: pid(), name(), GranteeId :: id(), Limits :: map()}
                | {install, tag(), GranteeId :: id(), installed(), Interface :: pos_integer(), Facet :: erx_facets:facet()}
                | {arm, tag(), Milliseconds :: pos_integer()}
                | {disarm, tag()}
                | {refused, atom(), Detail :: tuple()}
                | {dropped, atom(), Detail :: tuple()}
                | {failed, key(), pair(), reason()}
                | {answer, Asker :: term(), line_reply()}.
%% A line operation's answer (erx_domain:line/4).
-type line_reply() :: {ok, pid()} | {error, no_line | busy | ended | refused | unavailable | term()}.
%% A pending line operation, keyed by its session and line name.
-type line_op() :: #{state := {introducing | minting, pair(), tag()}, asker := term(), opening := pid()}.
-type incarnation() :: {id(), ready, node(), Providers :: #{name() => pid()}} | {id(), ended}.
-opaque state() :: #{declared := #{row() => [name()]},
                     grants := #{key() => #{server := row(), service := name(), limits := map(), mark := boolean(),
                                            state := grant()}},
                     rows := #{row() => incarnation()},
                     sessions := sets:set(id()),
                     lines := #{id() => {node(), #{name() => pid()}}},
                     line_ops := #{{id(), name()} => line_op()},
                     next_tag := tag(),
                     owner := fun((pid()) -> non_neg_integer()),
                     files := [name()],
                     windows := [name()],
                     inputs := [name()],
                     interfaces := #{{row(), name()} => pos_integer()},
                     areas := #{row() => [area()]},
                     deadline := pos_integer()}.
%% A party of a pair as the domain service records it: its id and what it holds, a
%% configured row's grants by its row, a session's facet rows, those its plan gave it
%% (the session's record in erx_domain_core), or a request's domain nothing.
-type party() :: {id(), request | {configured, row()} | {rows, [erx_domain_core:session_row()]}}.
%% A windows grant's pixel area, as its grantee holds it: its server row and its bytes,
%% whole pages.
-type area() :: {Server :: row(), Bytes :: pos_integer()}.

-doc """
The state of a boot from the manifest's service rows, each a server row and a
name, and its facet rows served by configured domains, each a grantee, the
service's name, its server row and the grant's limits. A grantee
{template, T}'s grants are kept nowhere here: each session carries the facet
rows its plan gave it, in its ready report and as a party. Files names the
services of the interfaces whose parameters files_grant checks
(?ERX_FILES_GRANT_SERVICES), whose grants a namespace mounts, and Windows
those of the windows interface, whose grants size their pairs'
pixel areas (pair_area/3), and Inputs those of the input interface, whose
grants are read-only (grant_limits/2); none of any by default. Interfaces
gives each service row's interface number by its server row and name, the
manifest's, which each installation carries (interface/2); a grant
installed of a service it does not name is a bug of the caller. Drives are
the manifest's drive window rows, each its serving row, the configured row
whose units hold the drive's device, the media domain's row and the drive's
number: each is a grant of the drive interface under {drive, N}, whose
limits are the interface's (?ERX_DRIVE_GRANTS) and drive => N, and makes the
serving row declare drive, as if a service row named it (docs/design-system.md,
"A drive window as a grant"); none by default. A grant of a
service its server does not declare, a grant to its own server, two
grants of one name to one grantee, a service whose server is no row (the
system domain's, which the ready answers serve), a service named drive, a
drive number named twice, and a drive whose rows are no rows or one row
twice is a bug of the caller, which the manifest check and the caller's
filter rule out, and fails with badarg.
""".
-spec new(config()) -> state().
new(#{services := Services, grants := Grants, owner := Owner} = Config) when is_function(Owner, 1) ->
    Drives = maps:get(drives, Config, []),
    Declared = maps:groups_from_list(fun({Row, _}) -> Row end, fun({_, Name}) -> Name end,
                                     lists:usort(Services ++ [{Server, drive} || {Server, _, _} <- Drives])),
    Keys = [{Grantee, Name} || {Grantee, Name, _, _} <- Grants],
    Valid = lists:all(fun({Row, Name}) -> is_integer(Row) andalso Row >= 0 andalso Name =/= drive end, Services)
        andalso length(lists:usort(Keys)) =:= length(Grants)
        andalso lists:all(fun valid_drive/1, Drives)
        andalso length(lists:usort([N || {_, _, N} <- Drives])) =:= length(Drives)
        andalso lists:all(fun({Grantee, Name, Server, Limits}) ->
                                  Grantee =/= Server andalso is_map(Limits)
                                      andalso lists:member({Server, Name}, Services)
                          end, Grants),
    Valid orelse error(badarg),
    %% A template's grants are held by its sessions, each from its own ready report.
    Entries = maps:from_list([{{Grantee, Name}, entry(Server, Name, Limits, false)}
                              || {Grantee, Name, Server, Limits} <- Grants, not is_template(Grantee)]
                             ++ drive_entries(Drives)),
    Windows = maps:get(windows, Config, []),
    #{declared => Declared, grants => Entries, rows => #{}, sessions => sets:new([{version, 2}]),
          lines => #{}, line_ops => #{},
          next_tag => 1, owner => Owner, files => maps:get(files, Config, []), windows => Windows,
          inputs => maps:get(inputs, Config, []), interfaces => maps:get(interfaces, Config, #{}),
          areas => areas(Windows, Grants), deadline => maps:get(deadline, Config, ?DEADLINE)}.

%% A drive window row's grant, {Server, Grantee, N}: two distinct configured rows and a
%% drive number.
valid_drive({Server, Grantee, N}) ->
    is_integer(Server) andalso Server >= 0 andalso is_integer(Grantee) andalso Grantee >= 0
        andalso Server =/= Grantee andalso is_integer(N) andalso N >= 0;
valid_drive(_Drive) ->
    false.

%% Each drive's grant record: of the service drive, installed as {drive, N} beside its
%% grantee, with the interface's limits and drive => N, which its mint request carries.
drive_entries(Drives) ->
    Limits = maps:get(drive, ?ERX_DRIVE_GRANTS),
    [{{Grantee, {drive, N}}, entry(Server, drive, Limits#{drive => N}, false)} || {Server, Grantee, N} <- Drives].

%% A grant's record, its service fixed beside the installed name that keys it.
entry(Server, Service, Limits, Mark) ->
    #{server => Server, service => Service, limits => Limits, mark => Mark, state => idle}.

is_template({template, _}) -> true;
is_template(_Grantee) -> false.

-doc "Each grant's state, by its key.".
-spec grants(state()) -> #{key() => grant()}.
grants(#{grants := Grants}) ->
    #{Key => Grant || Key := #{state := Grant} <- Grants}.

-doc """
Whether a session of Rows, the facet rows its plan gave it, holds the
display Name, a service of the windows interface of a configured domain:
the services a session's start may name as its display (erx_domain_srv),
so a start names only a display the session holds.
""".
-spec granted([erx_domain_core:session_row()], term(), state()) -> boolean().
granted(Rows, Name, #{windows := Windows}) ->
    lists:member(Name, Windows) andalso lists:keymember(Name, 1, Rows).

-doc """
The names of the services of configured domains the manifest grants
Grantee, sorted: a configured row's or the system domain's; a session's
are its rows, which the service holds. Only
Grantee's own grants, so a domain's ready answer, which names them, says
nothing of another domain's (erx_domain_srv).
""".
-spec granted_names(row() | system, state()) -> [name()].
granted_names(Grantee, State) ->
    [Name || {Name, _Server} <- granted_services(Grantee, State)].

-doc """
The services of configured domains the manifest grants Grantee, as
granted_names/2 finds them, each its name and its server row, sorted by name: the
pair that names a service's interface, since two servers may each serve a service
of one name. A drive grant, installed under {drive, N} and no service's name, is
none of them: its grantee learns it from its registry.
""".
-spec granted_services(row() | system, state()) -> [{name(), row()}].
granted_services(Grantee, #{grants := Grants}) ->
    lists:usort([{Name, Server} || {Holder, Name} := #{server := Server, service := Service} <- Grants,
                                   Holder =:= Grantee, Name =:= Service]).

-doc """
Whether Grantee's namespace is in place: each of its grants of a files
service is installed or failed, or is idle while its server row is not
among Starting, the configured rows whose domain runs without having reported
ready. An idle grant whose server is ready does not provide the name,
so nothing more comes for it. A grantee that holds no such grant has its
namespace in place.
""".
-spec in_place(grantee(), Starting :: [row()], state()) -> boolean().
in_place(Grantee, Starting, #{grants := Grants, files := Files}) ->
    lists:all(fun({{_, Name}, #{server := Server, state := Grant}}) ->
                      not lists:member(Name, Files) orelse grant_settled(Grant, Server, Starting)
              end, [Entry || {{G, _}, _} = Entry <- maps:to_list(Grants), G =:= Grantee]).

-doc """
The answer to Query, a wait of a process of the system domain
(docs/design-system.md, "Waiting for a grant"), once its facts have settled,
and wait until then, from the grants and Starting alone, the configured rows
whose domain runs without having reported ready and those held at boot.
namespace is answered ok once the system domain's namespace is in place
(in_place/3), {server, Name} ok once Name's server has settled
(server_settled/3), and {grant, Name, Id} as system_grant/4 answers it.
""".
-spec settled(query(), Starting :: [row()], state()) ->
          wait | ok | {ok, erx_facets:facet()} | {error, failed | ended | unprovided}.
settled(namespace, Starting, State) ->
    ok_or_wait(in_place(system, Starting, State));
settled({server, Name}, Starting, State) ->
    ok_or_wait(server_settled(Name, Starting, State));
settled({grant, Name, Id}, Starting, State) ->
    system_grant(Name, Id, Starting, State).

ok_or_wait(true) -> ok;
ok_or_wait(false) -> wait.

%% Whether the server of service Name has settled (docs/design-system.md, "A
%% session takes the console", a display's row): no configured row among
%% Starting serves Name. Its server is then ready, stopped for its boot timeout,
%% ended, or refused its start. A name no configured row serves, such as one the
%% system domain serves, has no start to wait for and has settled.
server_settled(Name, Starting, #{declared := Declared}) ->
    not lists:any(fun(Row) -> lists:member(Name, maps:get(Row, Declared, [])) end, Starting).

%% The answer to a wait for the system domain's grant of service Name from Id,
%% an incarnation of the grant's server row: {ok, Facet} once the grant is
%% installed with Id as its server, Facet as the installation in the system
%% domain's registry carries it (admitted/4), {error, failed} once it failed
%% with Id as its server, {error, ended} once Id has ended or the grant carries
%% another server, {error, unprovided} once Id is ready and the grant is idle, and
%% wait while none of these holds. A name the system domain is granted by no row is
%% {error, unprovided}: nothing will ever be installed for it. An idle grant's Id the core
%% has not heard of, once its server row is not starting, is {error, ended}: nothing
%% comes for it, so no query waits past the row's boot timeout.
system_grant(Name, Id, Starting, #{grants := Grants, rows := Rows}) ->
    Key = {system, Name},
    case Grants of
        #{Key := #{state := {installed, {Id, _}, Facet}}} -> {ok, Facet};
        #{Key := #{state := {failed, {Id, _}, _Reason}}} -> {error, failed};
        #{Key := #{state := idle, server := Server}} ->
            idle_grant(heard(Id, maps:get(Server, Rows, none)), lists:member(Server, Starting));
        #{Key := #{state := Grant}} -> other_grant(Id, carried_pair(Grant));
        #{} -> {error, unprovided}
    end.

%% An idle grant: Id provides no such name once it is ready, nothing comes for it once
%% it has ended, and until the core hears of it there is nothing to decide while its
%% server row starts. With the row not starting, an Id the core has not heard of is an
%% incarnation stopping without a ready report, or none of the row's, and the core will
%% hear of it no more: nothing comes for it either.
idle_grant(ready, _Starting) -> {error, unprovided};
idle_grant(ended, _Starting) -> {error, ended};
idle_grant(unheard, true) -> wait;
idle_grant(unheard, false) -> {error, ended}.

%% A grant with an operation pending, or settled with another server than Id: a wait
%% for the operation's own server waits for it, and any other is another server's.
other_grant(Id, {Id, _GranteeId}) -> wait;
other_grant(_Id, _AnotherPair) -> {error, ended}.

%% Whether the core has heard incarnation Id of a row whose newest incarnation is
%% Newest ready, ended, or not at all: a row's incarnations follow one another, so one
%% older than the newest has ended.
heard(Id, {Id, ready, _Node, _Providers}) -> ready;
heard(Id, {Id, ended}) -> ended;
heard(Id, Newest) when is_tuple(Newest), element(1, Newest) > Id -> ended;
heard(_Id, _NewestOrNone) -> unheard.

%% Whether one grant has settled for a namespace (in_place/3): installed, failed, or
%% idle while its server row is not starting.
grant_settled({installed, _Pair, _Facet}, _Server, _Starting) -> true;
grant_settled({failed, _Pair, _Reason}, _Server, _Starting) -> true;
grant_settled(idle, Server, Starting) -> not lists:member(Server, Starting);
grant_settled(_Pending, _Server, _Starting) -> false.

-doc "The next state and the actions to perform for Event, in order.".
-spec step(event(), state()) -> {state(), [action()]}.
step(Event, State) ->
    {Actions, Next} = on_event(Event, State),
    {Next, Actions}.

%% Event's actions and the next state, as the decisions below build them.
on_event({ready, Row, Id, Node, Provides}, #{rows := Rows} = State) ->
    case Rows of
        #{Row := Newest} when Id =< element(1, Newest) ->
            {[{refused, stale_report, {Row, Id}}], State};
        #{} ->
            {Refusals, Accepted} = authenticate(Row, {Id, Node}, Provides, State),
            {Actions, Next} = reconcile(State#{rows := Rows#{Row => {Id, ready, Node, Accepted}}}),
            {[{refused, Reason, Detail} || {Reason, Detail} <- Refusals] ++ Actions, Next}
    end;
on_event({ended, Row, Id}, #{rows := Rows} = State) ->
    case Rows of
        #{Row := Newest} when Id < element(1, Newest) ->
            end_lines(Id, State);
        #{} ->
            {Actions, Next} = reconcile(State#{rows := Rows#{Row => {Id, ended}}}),
            {Ended, Last} = end_lines(Id, Next),
            {Actions ++ Ended, Last}
    end;
on_event({session_ready, Rows, Id, Node, Marked, Provides},
         #{sessions := Sessions, grants := Grants, lines := Lines} = State) ->
    case sets:is_element(Id, Sessions) of
        true ->
            {[{refused, stale_report, {session, Id}}], State};
        false ->
            Added = maps:from_list([{{{session, Id}, Name}, entry(Server, Name, Limits, {display, Name} =:= Marked)}
                                    || {Name, Server, Limits} <- Rows]),
            {Refusals, Accepted} = session_lines(Id, Node, Provides, State),
            {Actions, Next} = reconcile(State#{sessions := sets:add_element(Id, Sessions),
                                               grants := maps:merge(Grants, Added),
                                               lines := Lines#{Id => {Node, Accepted}}}),
            {[{refused, Reason, Detail} || {Reason, Detail} <- Refusals] ++ Actions, Next}
    end;
on_event({session_ended, Id}, #{sessions := Sessions} = State) ->
    case sets:is_element(Id, Sessions) of
        true ->
            %% With the session gone its grants have no pair, so reconcile cancels
            %% their operations, and its line operations are answered; then nothing
            %% of the session is kept.
            Rest = sets:del_element(Id, Sessions),
            {Actions, #{grants := Grants} = Next} = reconcile(State#{sessions := Rest}),
            {Ended, #{lines := Lines} = Last} = end_lines(Id, Next),
            {Actions ++ Ended,
             Last#{grants := maps:filter(fun({Grantee, _}, _) -> Grantee =/= {session, Id} end, Grants),
                   lines := maps:remove(Id, Lines)}};
        false ->
            %% A session the core never heard ready may still be a line's peer.
            end_lines(Id, State)
    end;
on_event({line, Asker, Name, Session, Peer, Opening}, State) ->
    request_line(Asker, Name, Session, Peer, Opening, State);
on_event({introduced, Tag, Result}, State) ->
    case find(Tag, State) of
        {Key, {introducing, Pair, Tag}} when Result =:= ok ->
            {[mint_request(Key, Pair, Tag, State)], set_grant(Key, {minting, Pair, Tag}, State)};
        {Key, {introducing, Pair, Tag}} ->
            fail_pending(Key, Pair, Tag, {introduce, Result}, State);
        {_Key, _Other} ->
            {[], State};
        none ->
            line_introduced(Tag, Result, State)
    end;
on_event({minted, Origin, Tag, Reply}, State) ->
    case find(Tag, State) of
        {Key, {minting, {Origin, GranteeId} = Pair, Tag}} ->
            case admitted(Reply, Origin, Key, State) of
                {ok, Facet} ->
                    {_, Installed} = Key,
                    {[{install, Tag, GranteeId, Installed, interface(Key, State), Facet}],
                     set_grant(Key, {installing, Pair, Tag, Facet}, State)};
                refused ->
                    fail_pending(Key, Pair, Tag, bad_reply, State)
            end;
        {_Key, {minting, _Pair, Tag}} ->
            drop(wrong_domain, {minted, Origin}, State);
        {_Key, _Other} ->
            drop(unexpected, {minted, Origin}, State);
        none ->
            line_minted(Origin, Tag, Reply, State)
    end;
on_event({installed, Origin, Tag}, State) ->
    case find(Tag, State) of
        {Key, {installing, {_, Origin} = Pair, Tag, Facet}} ->
            {[{disarm, Tag}], set_grant(Key, {installed, Pair, Facet}, State)};
        {_Key, {installing, _Pair, Tag, _Facet}} ->
            drop(wrong_domain, {installed, Origin}, State);
        {_Key, _Other} ->
            drop(unexpected, {installed, Origin}, State);
        none ->
            drop(unknown_tag, {installed, Origin}, State)
    end;
%% A deadline whose operation ended already was disarmed with its message on the way.
on_event({deadline, Tag}, State) ->
    case find(Tag, State) of
        {Key, Pending} ->
            fail_at_deadline(Key, carried_pair(Pending), {deadline, element(1, Pending)}, State);
        none ->
            line_deadline(Tag, State)
    end.

%% A request for session Session's line Name with Peer its grantee, within the life of
%% Opening: answered at once when the session has no such line, when one is pending, or
%% when Peer is no domain whose end the core hears (live_peer/2), started otherwise.
request_line(Asker, Name, Session, Peer, Opening, #{lines := Lines, line_ops := Ops} = State) ->
    Key = {Session, Name},
    case {Lines, Ops} of
        {_, #{Key := _}} ->
            {[{answer, Asker, {error, busy}}], State};
        {#{Session := {_Node, #{Name := _}}}, _} ->
            case live_peer(Peer, State) of
                true -> start_line(Asker, Key, Peer, Opening, State);
                false -> {[{answer, Asker, {error, ended}}], State}
            end;
        _ ->
            {[{answer, Asker, {error, no_line}}], State}
    end.

%% Whether Peer is a domain whose end the core hears, so no line operation outlives it:
%% the system domain, a ready session, or a configured row's ready incarnation.
live_peer(?ERX_SYSTEM_DOMAIN_ID, _State) ->
    true;
live_peer(Peer, #{sessions := Sessions, rows := Rows}) ->
    sets:is_element(Peer, Sessions)
        orelse lists:any(fun({Id, ready, _Node, _Providers}) -> Id =:= Peer; (_Ended) -> false end,
                         maps:values(Rows)).

%% The operation for Key, its deadline armed: minting at once for the system domain as
%% peer, which every domain is connected to, and introducing the two domains otherwise.
start_line(Asker, {Session, _Name} = Key, Peer, Opening,
           #{line_ops := Ops, next_tag := Tag, deadline := Deadline} = State) ->
    Pair = {Session, Peer},
    Armed = State#{next_tag := Tag + 1},
    Op = #{asker => Asker, opening => Opening},
    case Peer of
        ?ERX_SYSTEM_DOMAIN_ID ->
            {[{arm, Tag, Deadline}, line_mint(Key, Peer, Tag, Opening, State)],
             Armed#{line_ops := Ops#{Key => Op#{state => {minting, Pair, Tag}}}}};
        _ ->
            {[{arm, Tag, Deadline}, {introduce, Tag, Session, Peer}],
             Armed#{line_ops := Ops#{Key => Op#{state => {introducing, Pair, Tag}}}}}
    end.

%% The mint request for session Session's line Name, to its accepted mint, with the
%% grant's quantities ?ERX_LINES gives Name and the opening, which no facet row states.
line_mint({Session, Name}, Peer, Tag, Opening, #{lines := Lines}) ->
    #{Session := {_Node, #{Name := Mint}}} = Lines,
    {mint, Tag, Mint, Name, Peer, (maps:get(Name, ?ERX_LINES))#{opening => Opening}}.

line_introduced(Tag, Result, State) ->
    case find_line(Tag, State) of
        {Key, #{state := {introducing, {_Session, Peer} = Pair, Tag}, opening := Opening} = Op} when Result =:= ok ->
            {[line_mint(Key, Peer, Tag, Opening, State)], set_line(Key, Op#{state := {minting, Pair, Tag}}, State)};
        {Key, #{state := {introducing, _Pair, Tag}}} ->
            answer_line(Key, Result, [{disarm, Tag}], State);
        _ ->
            {[], State}
    end.

%% A mint reply counts only from the session, for the operation in minting with its tag.
line_minted(Origin, Tag, Reply, State) ->
    case find_line(Tag, State) of
        {{Origin, _Name} = Key, #{state := {minting, _Pair, Tag}}} ->
            answer_line(Key, line_reply(Origin, Reply, State), [{disarm, Tag}], State);
        {_Key, #{state := {minting, _Pair, Tag}}} ->
            drop(wrong_domain, {minted, Origin}, State);
        {_Key, _Introducing} ->
            drop(unexpected, {minted, Origin}, State);
        none ->
            drop(unknown_tag, {minted, Origin}, State)
    end.

%% The session's reply as the asker hears it: {ok, Facet} for a facet the session owns,
%% node and creation both, and refused for anything else.
line_reply(Session, {ok, Facet}, #{lines := Lines} = State) when is_pid(Facet) ->
    #{Session := {Node, _Mints}} = Lines,
    case is_owned(Facet, {Session, Node}, State) of
        true -> {ok, Facet};
        false -> {error, refused}
    end;
line_reply(_Session, _Reply, _State) ->
    {error, refused}.

%% A line operation's deadline answers it; one already answered was disarmed with its
%% message on the way.
line_deadline(Tag, State) ->
    case find_line(Tag, State) of
        {Key, _Op} -> answer_line(Key, {error, unavailable}, [], State);
        none -> {[], State}
    end.

%% The end of domain Id answers each line operation of a session Id with no_line and
%% each for a peer Id with ended.
end_lines(Id, #{line_ops := Ops} = State) ->
    Ended = lists:sort([{Key, Tag, Reply} || Key := #{state := {_, {Session, Peer}, Tag}} <- Ops,
                                             Reply <- ended_reply(Id, Session, Peer)]),
    lists:foldl(fun({Key, Tag, Reply}, {Actions, Acc}) ->
                        {More, Next} = answer_line(Key, Reply, [{disarm, Tag}], Acc),
                        {Actions ++ More, Next}
                end, {[], State}, Ended).

ended_reply(Id, Id, _Peer) -> [{error, no_line}];
ended_reply(Id, _Session, Id) -> [{error, ended}];
ended_reply(_Id, _Session, _Peer) -> [].

%% The answer Reply to line operation Key, after Disarm, and the operation deleted.
answer_line(Key, Reply, Disarm, #{line_ops := Ops} = State) ->
    #{Key := #{asker := Asker}} = Ops,
    {Disarm ++ [{answer, Asker, Reply}], State#{line_ops := maps:remove(Key, Ops)}}.

%% The line operation with tag Tag, and its record, or none. Tag may be any term a
%% domain sent.
find_line(Tag, #{line_ops := Ops}) ->
    case [{Key, Op} || Key := #{state := {_, _, OpTag}} = Op <- Ops, OpTag =:= Tag] of
        [Found] -> Found;
        [] -> none
    end.

set_line(Key, Op, #{line_ops := Ops} = State) ->
    State#{line_ops := Ops#{Key := Op}}.

%% The mints session Id's ready report names for its lines, at its node Node:
%% {Refusals, Accepted}. A name outside ?ERX_LINES refuses the map whole; a value
%% that is no pid the session owns refuses its entry alone.
session_lines(Id, Node, Provides, State) when is_map(Provides) ->
    case lists:all(fun(Name) -> is_map_key(Name, ?ERX_LINES) end, maps:keys(Provides)) of
        false ->
            {[{undeclared, {session, Id}}], #{}};
        true ->
            lists:foldl(fun({Name, Mint}, {Refusals, Accepted}) when not is_pid(Mint) ->
                                {Refusals ++ [{not_a_pid, {session, Id, Name}}], Accepted};
                           ({Name, Mint}, {Refusals, Accepted}) ->
                                case is_owned(Mint, {Id, Node}, State) of
                                    true -> {Refusals, Accepted#{Name => Mint}};
                                    false -> {Refusals ++ [{foreign_mint, {session, Id, Name}}], Accepted}
                                end
                        end, {[], #{}}, lists:sort(maps:to_list(Provides)))
    end;
session_lines(Id, _Node, _Provides, _State) ->
    {[{not_a_map, {session, Id}}], #{}}.

%% The providers Row's Incarnation, {Id, Node}, may name: {Refusals, Accepted}, each
%% refusal a reason and a bounded detail for the log. The name is checked first, so
%% only a declared name, an atom, reaches a later refusal's detail.
authenticate(Row, {Id, _} = Incarnation, Provides, #{declared := Declared} = State) ->
    Names = maps:get(Row, Declared, []),
    if
        not is_map(Provides) ->
            {[{not_a_map, {Row, Id}}], #{}};
        map_size(Provides) > length(Names) ->
            {[{oversized, {Row, Id, map_size(Provides)}}], #{}};
        true ->
            lists:foldl(fun({Name, Mint}, {Refusals, Accepted}) ->
                                case lists:member(Name, Names) of
                                    false ->
                                        {Refusals ++ [{undeclared, {Row, Id}}], Accepted};
                                    true when not is_pid(Mint) ->
                                        {Refusals ++ [{not_a_pid, {Row, Id, Name}}], Accepted};
                                    true ->
                                        case is_owned(Mint, Incarnation, State) of
                                            true -> {Refusals, Accepted#{Name => Mint}};
                                            false -> {Refusals ++ [{foreign_mint, {Row, Id, Name}}], Accepted}
                                        end
                                end
                        end, {[], #{}}, lists:sort(maps:to_list(Provides)))
    end.

%% Whether the incarnation {Id, Node} owns Pid: a send to Pid goes to Node, and its
%% creation names Id.
is_owned(Pid, {Id, Node}, #{owner := Owner}) ->
    node(Pid) =:= Node andalso Owner(Pid) =:= Id.

%% The facet a mint's reply for the grant Key installs, or refused (docs/design-system.md,
%% "the mint's reply"). The reply is untrusted. For a service of an interface
%% abi/services declares served_as tree it is {ok, Pid, Tree}, Tree a plain name (the 9P
%% grammar's is_name/1) and installed as {Pid, Tree, Rights} with the rights of the grant's
%% limits (grant_limits/2), which the manifest states and no reply sets; for any other
%% service it is {ok, Pid}, installed as the pid. Either way Pid is owned by the ready
%% server ServerId, and any other reply is refused.
admitted(Reply, ServerId, Key, State) ->
    case lists:member(interface(Key, State), ?ERX_TREE_SERVICES) of
        true -> admitted_tree(Reply, ServerId, Key, State);
        false -> admitted_message(Reply, ServerId, State)
    end.

admitted_tree({ok, Pid, Tree}, ServerId, Key, State) when is_pid(Pid) ->
    case is_owned_by(Pid, ServerId, State) andalso erx_9p_grammar:is_name(Tree) of
        true -> {ok, erx_fs_grants:facet(Pid, Tree, grant_limits(Key, State))};
        false -> refused
    end;
admitted_tree(_Reply, _ServerId, _Key, _State) ->
    refused.

admitted_message({ok, Pid}, ServerId, State) when is_pid(Pid) ->
    case is_owned_by(Pid, ServerId, State) of
        true -> {ok, Pid};
        false -> refused
    end;
admitted_message(_Reply, _ServerId, _State) ->
    refused.

%% Whether the ready server ServerId owns Pid.
is_owned_by(Pid, ServerId, #{rows := Rows} = State) ->
    [Node] = [Node || _Row := {Id, ready, Node, _} <- Rows, Id =:= ServerId],
    is_owned(Pid, {ServerId, Node}, State).

%% Each grant brought to its current pair.
reconcile(#{grants := Grants} = State) ->
    lists:foldl(fun(Key, {Actions, Acc}) ->
                        {More, Next} = follow(Key, Acc),
                        {Actions ++ More, Next}
                end, {[], State}, lists:sort(maps:keys(Grants))).

follow(Key, State) ->
    Want = current_pair(Key, State),
    #{state := Have} = grant_entry(Key, State),
    case carried_pair(Have) of
        Want -> {[], State};
        _ -> start(Key, Want, cancel(Have), State)
    end.

start(Key, none, Cancel, State) ->
    {Cancel, set_grant(Key, idle, State)};
start({Grantee, _Name} = Key, {ServerId, GranteeId} = Pair, Cancel,
      #{next_tag := Tag, deadline := Deadline} = State) ->
    Armed = State#{next_tag := Tag + 1},
    case Grantee of
        system ->
            {Cancel ++ [{arm, Tag, Deadline}, mint_request(Key, Pair, Tag, State)],
             set_grant(Key, {minting, Pair, Tag}, Armed)};
        _RowOrSession ->
            {Cancel ++ [{arm, Tag, Deadline}, {introduce, Tag, ServerId, GranteeId}],
             set_grant(Key, {introducing, Pair, Tag}, Armed)}
    end.

%% The pixel areas each configured row holds, by its grants of the windows services
%% Windows. A template's grants are its sessions' facet rows, which each session's party
%% carries as {rows, Rows} (party_areas/2), and property 18 refuses a windows grant to the system domain,
%% whose connections no introduction makes.
areas(Windows, Grants) ->
    ByGrantee = maps:groups_from_list(fun({Grantee, _, _, _}) -> Grantee end,
                                      fun({_, Name, Server, Limits}) -> {Name, Server, Limits} end,
                                      [Grant || {Grantee, _, _, _} = Grant <- Grants, is_integer(Grantee)]),
    maps:map(fun(_Grantee, Held) -> windows_areas(Held, Windows) end, ByGrantee).

%% The areas of the facet rows Rows that grant a windows service of Windows: each row's
%% pixels, or windows_pixels_default where its limits state none, rounded up to whole
%% pages. The manifest's reader bounds pixels.
windows_areas(Rows, Windows) ->
    [{Server, pages(maps:get(pixels, Limits, ?ERX_WINDOWS_PIXELS_DEFAULT))}
     || {Name, Server, Limits} <- Rows, is_integer(Server), lists:member(Name, Windows)].

pages(Bytes) -> (Bytes + ?ERX_PAGE_SIZE - 1) div ?ERX_PAGE_SIZE * ?ERX_PAGE_SIZE.

-doc """
The pixel area of the connection between parties A and B, each its id and what
it holds (party()), as {Bytes, ReaderId}: the area of a windows grant whose server is one
party's row and which the other holds, by the manifest's grants to its row or,
for a session, by the facet rows its plan gave it, read by the server; none for a
pair no windows grant joins, a request's domain always among them. It reads
only those grants and rows, all fixed before either domain is built, never which
incarnation is ready or which grant is installed, so every introduction of the
pair, made at any time, makes the same area. A domain serves at most one display
(property 18) and a grantee holds one grant of a name, so a pair has at most one
area in each direction; for two displays granted to each other, the lower server
row's is the pair's.
""".
-spec pair_area(party(), party(), state()) -> {Bytes :: pos_integer(), ReaderId :: id()} | none.
pair_area({IdA, HoldsA}, {IdB, HoldsB}, State) ->
    Found = lists:sort([{Server, Bytes, ReaderId}
                        || {ReaderId, {configured, Server}, Other} <- [{IdA, HoldsA, HoldsB}, {IdB, HoldsB, HoldsA}],
                           {AreaServer, Bytes} <- party_areas(Other, State), AreaServer =:= Server]),
    case Found of
        [{_Server, Bytes, ReaderId} | _] -> {Bytes, ReaderId};
        [] -> none
    end.

%% The pixel areas a party holds: a configured row's by the manifest's grants, a
%% session's by its facet rows, and a request's domain none.
party_areas({configured, Row}, #{areas := Areas}) -> maps:get(Row, Areas, []);
party_areas({rows, Rows}, #{windows := Windows}) -> windows_areas(Rows, Windows);
party_areas(request, _State) -> [].

%% The request to the server's mint for the grant Key and its operation Tag, with the
%% grant's limits as its mark has them (session_limits/2).
mint_request(Key, {ServerId, GranteeId}, Tag, #{rows := Rows} = State) ->
    #{mark := Mark, server := Server, service := Service} = grant_entry(Key, State),
    #{Server := {ServerId, ready, _Node, #{Service := Mint}}} = Rows,
    {mint, Tag, Mint, Service, GranteeId, session_limits(grant_limits(Key, State), Mark)}.

%% The limits of the grant Key as its server mints it and its grantee holds it: its facet
%% row's, and for a grant of an input service, which states no rights
%% (abi/services/input.txt), rights ro, so its server serves it read-only and its grantee
%% holds it so (admitted/4). Both read the record's service, never the key's
%% installed name, which for a drive is {drive, N}.
grant_limits(Key, #{inputs := Inputs} = State) ->
    #{service := Service, limits := Limits} = grant_entry(Key, State),
    case lists:member(Service, Inputs) of
        true -> Limits#{rights => ro};
        false -> Limits
    end.

%% A grant's limits as its mint carries them: session => true for the marked grant, and
%% no session for any other, whatever its facet row's limits hold.
session_limits(Limits, true) -> Limits#{session => true};
session_limits(Limits, false) -> maps:remove(session, Limits).


%% The interface number of the grant Key's service, which its installation carries and
%% the grantee's registry keeps (erx_facets:program_table/1): the drive interface for a
%% drive window's grant, else its service row's, which the manifest states and no reply
%% of the server's sets (docs/design-system.md, "Facets a configured domain serves").
interface(Key, #{interfaces := Interfaces} = State) ->
    case grant_entry(Key, State) of
        #{service := drive} -> ?ERX_SERVICE_DRIVE;
        #{server := Server, service := Service} -> maps:get({Server, Service}, Interfaces)
    end.

cancel(Grant) ->
    case tag(Grant) of
        none -> [];
        Tag -> [{disarm, Tag}]
    end.

%% An operation that failed before its deadline: its deadline is disarmed.
fail_pending(Key, Pair, Tag, Reason, State) ->
    {Failed, Next} = fail_at_deadline(Key, Pair, Reason, State),
    {[{disarm, Tag} | Failed], Next}.

%% An operation that failed as its deadline fired, which needs no disarm.
fail_at_deadline(Key, Pair, Reason, State) ->
    {[{failed, Key, Pair, Reason}], set_grant(Key, {failed, Pair, Reason}, State)}.

%% The pair the grant Key should have: its server's ready incarnation, if that provides
%% the grant's service, and its grantee's.
current_pair({Grantee, _Installed} = Key, #{rows := Rows} = State) ->
    #{server := Server, service := Service} = grant_entry(Key, State),
    case {Rows, ready_id(Grantee, State)} of
        {#{Server := {ServerId, ready, _, #{Service := _}}}, GranteeId} when GranteeId =/= none ->
            {ServerId, GranteeId};
        _ ->
            none
    end.

ready_id(system, _State) ->
    ?ERX_SYSTEM_DOMAIN_ID;
ready_id({session, Id}, #{sessions := Sessions}) ->
    case sets:is_element(Id, Sessions) of
        true -> Id;
        false -> none
    end;
ready_id(Row, #{rows := Rows}) ->
    case Rows of
        #{Row := {Id, ready, _, _}} -> Id;
        #{} -> none
    end.

%% The pair a grant's state names.
carried_pair(idle) -> none;
carried_pair(Grant) -> element(2, Grant).

tag({introducing, _, Tag}) -> Tag;
tag({minting, _, Tag}) -> Tag;
tag({installing, _, Tag, _}) -> Tag;
tag(_Settled) -> none.

%% The grant with a pending operation tagged Tag, and its state, or none. Tag may be any
%% term a domain sent.
find(Tag, #{grants := Grants}) ->
    case [{Key, Grant} || Key := #{state := Grant} <- Grants, tag(Grant) =/= none, tag(Grant) =:= Tag] of
        [Found] -> Found;
        [] -> none
    end.

grant_entry(Key, #{grants := Grants}) ->
    maps:get(Key, Grants).

set_grant(Key, Grant, #{grants := Grants} = State) ->
    State#{grants := Grants#{Key := (maps:get(Key, Grants))#{state := Grant}}}.

drop(Reason, Detail, State) ->
    {[{dropped, Reason, Detail}], State}.
