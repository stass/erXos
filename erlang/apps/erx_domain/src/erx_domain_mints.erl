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

Sessions. A grant to a session template is a grant to every session made
from it. A session is one incarnation, never restarted, named by its id:
its ready report, {session_ready, Template, Id, Marked}, adds a grant keyed by
{session, Id} for each of the template's grants, and its end,
{session_ended, Id}, cancels their operations and deletes them, so the
core holds entries only for live sessions, each its own. The service
passes a session's report on at most once and before its end, and names
the template from its own record of the domain, never from the report;
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

Replies are untrusted. A mint's reply counts only from the pair's server,
for the operation in minting with its tag; an acknowledgement only from the
pair's grantee, for the operation in installing with its tag. Anything else
is dropped, as a dropped action logged and counted. A reply that counts
settles its step: {ok, Facet}, Facet a pid the server's incarnation owns,
moves to installing; any other reply fails the operation. Since an operation
exists only while its pair is current, a reply after either domain's end
matches nothing. Refused, dropped and failed actions carry only bounded
terms: atoms, the service's own numbers, or a reason the core names.

Namespaces. A grantee's namespace is in place (docs/design-system.md, "A
session takes the console") when each of its grants of a files service,
the names config's files lists, has settled: installed, failed, or idle
while its server row is not starting. in_place/3 decides it from the
grants alone and the rows the service names as starting, so it needs no
state of its own, and a grant with an operation is bounded by its
deadline, a starting server by its boot timeout.
""".

-export([new/1, step/2, grants/1, granted/3, granted_names/2, in_place/3]).
-export_type([state/0, config/0, event/0, action/0, grant/0, key/0, pair/0]).

-define(SYSTEM_ID, 4).
-define(DEADLINE, 10000).

-type row() :: non_neg_integer().
-type id() :: pos_integer().
-type name() :: atom().
-type tag() :: pos_integer().
-type template() :: non_neg_integer().
-type grantee() :: row() | system | {session, id()}.
-type key() :: {grantee(), name()}.
-type pair() :: {ServerId :: id(), GranteeId :: id()}.
-type pending() :: introducing | minting | installing.
-type reason() :: {introduce, term()} | bad_reply | {deadline, pending()}.
%% The service whose grant a session's ready report marks, the display its start named.
-type marked() :: {display, name()} | none.
-type grant() :: idle
               | {introducing, pair(), tag()}
               | {minting, pair(), tag()}
               | {installing, pair(), tag(), Facet :: pid()}
               | {installed, pair(), Facet :: pid()}
               | {failed, pair(), reason()}.
-type config() :: #{services := [{Server :: row(), name()}],
                    grants := [{Grantee :: row() | system | {template, template()}, name(), Server :: row(),
                                Limits :: map()}],
                    owner := fun((pid()) -> non_neg_integer()),
                    files => [name()],
                    deadline => pos_integer()}.
%% ready carries the incarnation's node, which the service knows; the rest of the
%% untrusted events' fields are any term a domain sent.
-type event() :: {ready, row(), id(), node(), Provides :: term()}
               | {ended, row(), id()}
               | {session_ready, template(), id(), marked()}
               | {session_ended, id()}
               | {introduced, tag(), ok | {error, term()}}
               | {minted, Origin :: non_neg_integer(), Tag :: term(), Reply :: term()}
               | {installed, Origin :: non_neg_integer(), Tag :: term()}
               | {deadline, tag()}.
-type action() :: {introduce, tag(), ServerId :: id(), GranteeId :: id()}
                | {mint, tag(), Mint :: pid(), name(), GranteeId :: id(), Limits :: map()}
                | {install, tag(), GranteeId :: id(), name(), Facet :: pid()}
                | {arm, tag(), Milliseconds :: pos_integer()}
                | {disarm, tag()}
                | {refused, atom(), Detail :: tuple()}
                | {dropped, atom(), Detail :: tuple()}
                | {failed, key(), pair(), reason()}.
-type incarnation() :: {id(), ready, node(), Providers :: #{name() => pid()}} | {id(), ended}.
-opaque state() :: #{declared := #{row() => [name()]},
                     grants := #{key() => #{server := row(), limits := map(), mark := boolean(),
                                            state := grant()}},
                     rows := #{row() => incarnation()},
                     templates := #{template() => [{name(), Server :: row(), Limits :: map()}]},
                     sessions := #{id() => template()},
                     next_tag := tag(),
                     owner := fun((pid()) -> non_neg_integer()),
                     files := [name()],
                     deadline := pos_integer()}.

-doc """
The state of a boot from the manifest's service rows, each a server row and a
name, and its facet rows served by configured domains, each a grantee, the
service's name, its server row and the grant's limits. A grantee
{template, T} grants each session made from template T. Files names the
services of the files interface, whose grants a namespace mounts; none by
default. A grant of a
service its server does not declare, a grant to its own server, two
grants of one name to one grantee, or a service whose server is no row (the
system domain's, which the ready answers serve) is a bug of the caller,
which the manifest check and the caller's filter rule out, and fails with
badarg.
""".
-spec new(config()) -> state().
new(#{services := Services, grants := Grants, owner := Owner} = Config) when is_function(Owner, 1) ->
    Declared = maps:groups_from_list(fun({Row, _}) -> Row end, fun({_, Name}) -> Name end, Services),
    Keys = [{Grantee, Name} || {Grantee, Name, _, _} <- Grants],
    Valid = lists:all(fun({Row, _Name}) -> is_integer(Row) andalso Row >= 0 end, Services)
        andalso length(lists:usort(Keys)) =:= length(Grants)
        andalso lists:all(fun({Grantee, Name, Server, Limits}) ->
                                  Grantee =/= Server andalso is_map(Limits)
                                      andalso lists:member(Name, maps:get(Server, Declared, []))
                          end, Grants),
    Valid orelse error(badarg),
    {ForTemplates, ForDomains} = lists:partition(fun({{template, _}, _, _, _}) -> true; (_) -> false end, Grants),
    Entries = maps:from_list([{{Grantee, Name}, entry(Server, Limits, false)}
                              || {Grantee, Name, Server, Limits} <- ForDomains]),
    Templates = maps:groups_from_list(fun({{template, T}, _, _, _}) -> T end,
                                      fun({_, Name, Server, Limits}) -> {Name, Server, Limits} end, ForTemplates),
    #{declared => Declared, grants => Entries, rows => #{}, templates => Templates, sessions => #{},
          next_tag => 1, owner => Owner, files => maps:get(files, Config, []),
          deadline => maps:get(deadline, Config, ?DEADLINE)}.

entry(Server, Limits, Mark) -> #{server => Server, limits => Limits, mark => Mark, state => idle}.

-doc "Each grant's state, by its key.".
-spec grants(state()) -> #{key() => grant()}.
grants(#{grants := Grants}) ->
    #{Key => Grant || Key := #{state := Grant} <- Grants}.

-doc """
Whether the manifest grants template Template's sessions the service Name
of a configured domain: the services a session's start may name as its
display (erx_domain_srv), so a start names only a grant its template has.
""".
-spec granted(template(), term(), state()) -> boolean().
granted(Template, Name, #{templates := Templates}) ->
    lists:keymember(Name, 1, maps:get(Template, Templates, [])).

-doc """
The names of the services of configured domains the manifest grants
Grantee, sorted: a configured row's, the system domain's, or, for
{template, T}, those of every session made from template T. Only
Grantee's own grants, so a domain's ready answer, which names them, says
nothing of another domain's (erx_domain_srv).
""".
-spec granted_names(row() | system | {template, template()}, state()) -> [name()].
granted_names({template, Template}, #{templates := Templates}) ->
    lists:usort([Name || {Name, _Server, _Limits} <- maps:get(Template, Templates, [])]);
granted_names(Grantee, #{grants := Grants}) ->
    lists:usort([Name || {Holder, Name} <- maps:keys(Grants), Holder =:= Grantee]).

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
                      not lists:member(Name, Files) orelse settled(Grant, Server, Starting)
              end, [Entry || {{G, _}, _} = Entry <- maps:to_list(Grants), G =:= Grantee]).

settled({installed, _Pair, _Facet}, _Server, _Starting) -> true;
settled({failed, _Pair, _Reason}, _Server, _Starting) -> true;
settled(idle, Server, Starting) -> not lists:member(Server, Starting);
settled(_Pending, _Server, _Starting) -> false.

-doc "The next state and the actions to perform for Event, in order.".
-spec step(event(), state()) -> {[action()], state()}.
step({ready, Row, Id, Node, Provides}, #{rows := Rows} = State) ->
    case Rows of
        #{Row := Newest} when Id =< element(1, Newest) ->
            {[{refused, stale_report, {Row, Id}}], State};
        #{} ->
            {Refusals, Accepted} = authenticate(Row, {Id, Node}, Provides, State),
            {Actions, Next} = reconcile(State#{rows := Rows#{Row => {Id, ready, Node, Accepted}}}),
            {[{refused, Reason, Detail} || {Reason, Detail} <- Refusals] ++ Actions, Next}
    end;
step({ended, Row, Id}, #{rows := Rows} = State) ->
    case Rows of
        #{Row := Newest} when Id < element(1, Newest) ->
            {[], State};
        #{} ->
            reconcile(State#{rows := Rows#{Row => {Id, ended}}})
    end;
step({session_ready, Template, Id, Marked}, #{sessions := Sessions, templates := Templates, grants := Grants} = State) ->
    case {Sessions, Templates} of
        {#{Id := _}, _} ->
            {[{refused, stale_report, {session, Id}}], State};
        {#{}, #{Template := Granted}} ->
            Added = maps:from_list([{{{session, Id}, Name}, entry(Server, Limits, {display, Name} =:= Marked)}
                                    || {Name, Server, Limits} <- Granted]),
            reconcile(State#{sessions := Sessions#{Id => Template}, grants := maps:merge(Grants, Added)});
        {#{}, #{}} ->
            {[], State}
    end;
step({session_ended, Id}, #{sessions := Sessions} = State) ->
    case maps:take(Id, Sessions) of
        {_Template, Rest} ->
            %% With the session gone its grants have no pair, so reconcile cancels
            %% their operations; then nothing of the session is kept.
            {Actions, #{grants := Grants} = Next} = reconcile(State#{sessions := Rest}),
            {Actions, Next#{grants := maps:filter(fun({Grantee, _}, _) -> Grantee =/= {session, Id} end, Grants)}};
        error ->
            {[], State}
    end;
step({introduced, Tag, Result}, State) ->
    case find(Tag, State) of
        {Key, {introducing, Pair, Tag}} when Result =:= ok ->
            {[mint_request(Key, Pair, Tag, State)], set_grant(Key, {minting, Pair, Tag}, State)};
        {Key, {introducing, Pair, Tag}} ->
            fail_pending(Key, Pair, Tag, {introduce, Result}, State);
        _ ->
            {[], State}
    end;
step({minted, Origin, Tag, Reply}, State) ->
    case find(Tag, State) of
        {Key, {minting, {Origin, GranteeId} = Pair, Tag}} ->
            case is_owned_reply(Reply, Origin, State) of
                true ->
                    {ok, Facet} = Reply,
                    {_, Name} = Key,
                    {[{install, Tag, GranteeId, Name, Facet}], set_grant(Key, {installing, Pair, Tag, Facet}, State)};
                false ->
                    fail_pending(Key, Pair, Tag, bad_reply, State)
            end;
        {_Key, {minting, _Pair, Tag}} ->
            drop(wrong_domain, {minted, Origin}, State);
        {_Key, _Other} ->
            drop(unexpected, {minted, Origin}, State);
        none ->
            drop(unknown_tag, {minted, Origin}, State)
    end;
step({installed, Origin, Tag}, State) ->
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
step({deadline, Tag}, State) ->
    case find(Tag, State) of
        {Key, Pending} ->
            fail_at_deadline(Key, carried_pair(Pending), {deadline, element(1, Pending)}, State);
        none ->
            {[], State}
    end.

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

%% Whether a mint's reply is {ok, Facet} with Facet owned by the ready server ServerId.
is_owned_reply({ok, Facet}, ServerId, #{rows := Rows} = State) when is_pid(Facet) ->
    [Node] = [Node || _Row := {Id, ready, Node, _} <- Rows, Id =:= ServerId],
    is_owned(Facet, {ServerId, Node}, State);
is_owned_reply(_Reply, _ServerId, _State) ->
    false.

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

%% The request to the server's mint for the grant Key and its operation Tag, with the
%% grant's limits as its mark has them (session_limits/2).
mint_request({_, Name} = Key, {ServerId, GranteeId}, Tag, #{rows := Rows} = State) ->
    #{limits := Limits, mark := Mark, server := Server} = grant_entry(Key, State),
    #{Server := {ServerId, ready, _Node, #{Name := Mint}}} = Rows,
    {mint, Tag, Mint, Name, GranteeId, session_limits(Limits, Mark)}.

%% A grant's limits as its mint carries them: session => true for the marked grant, and
%% no session for any other, whatever its facet row's limits hold.
session_limits(Limits, true) -> Limits#{session => true};
session_limits(Limits, false) -> maps:remove(session, Limits).

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
%% the name, and its grantee's.
current_pair({Grantee, Name} = Key, #{rows := Rows} = State) ->
    #{server := Server} = grant_entry(Key, State),
    case {Rows, ready_id(Grantee, State)} of
        {#{Server := {ServerId, ready, _, #{Name := _}}}, GranteeId} when GranteeId =/= none ->
            {ServerId, GranteeId};
        _ ->
            none
    end.

ready_id(system, _State) ->
    ?SYSTEM_ID;
ready_id({session, Id}, #{sessions := Sessions}) ->
    case Sessions of
        #{Id := _} -> Id;
        #{} -> none
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
