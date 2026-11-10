%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_srv).
-moduledoc """
The domain service (docs/design-system.md, "Creating a domain", "Ending a
domain", "System services"): the domain library's one registrant, which
creates the manifest's configured domains in boot order at its first start
and every requested domain after, keeps a domain pid for each, has the
system domain's connection agent (erx_connections) open the system side of
each domain's system connection before its first thread runs, answers a
create once the domain's init reports ready through its domain pid, stops a
domain that does not report within its boot timeout or whose side the agent
reports ended, and on each
{domain_ended, Id, End, Record} has the agent close that side, disconnects
the connection, ends its domain pid with {domain_down, Id, Info}, has the library
retire it at once, whatever its peers still map, and restarts a configured
domain within its restart intensity. It keeps the manifest's session templates by principal, from which each session of that
principal is made; a template is no configured domain, so the boot never
starts one and nothing restarts one.

It also introduces domains (docs/design-domains.md, "Introduction and
connection down"): introduce/2 has the library connect two domains and
erx_domain_links, the connection protocol's pure core, decide which
connection-control record goes to which domain, in which slot of its control
table, and when a connection's objects are deleted; the service performs
those actions, hands each record to the party's domain pid, which writes it,
and applies each answer the domain pid passes on. A party is added when its
domain is built, is ready when its init reports, and ends with its domain.

Its state, erx_domain_core's and erx_domain_links's, lives in its own heap and nowhere else. The
service is never restarted: its end, however it comes, ends the system
domain (erx_domain_sup), and no domain outlives that, so no successor needs
its records. Where the system domain has no domain library (a hosted
runtime, whose erx_domain_lib does not load, or a root that built none),
the service runs with none and every create is {error, enotsup}.

Callers are the system domain's own processes; requests from other domains
reach it only through facets, which arrive with the connections.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

%% Every domain is the system principal's, number 1, the one principal the library's
%% view has (include/erx/dom.h, erx_dom_principal_t).
-define(SYSTEM_PRINCIPAL, 1).
%% The keys of a request beyond its name and boot_timeout: erx_domain_lib:spec()'s, less
%% id, principal and domain_pid, which the service sets, and facets, the service's own.
-define(REQUEST_KEYS, [runtime, release, release_files, memory, outer, grant, lane, args, env,
                       connections, flags, spaces, limits, facets]).
%% How long a domain's init has to report ready, in milliseconds, unless its request
%% sets boot_timeout (docs/design-domains.md, "Erlang interface"); a configured domain
%% always has this long.
-define(BOOT_TIMEOUT, 10000).
%% How long an introduce/2 caller waits for the connection to come up at both ends, in
%% milliseconds, unless start_link/1's introduce_timeout sets it (docs/design-domains.md,
%% "Erlang interface").
-define(INTRODUCE_TIMEOUT, 10000).
%% The longest boot_timeout erlang:start_timer/3 takes.
-define(BOOT_TIMEOUT_MAX, 16#ffffffff).
%% A domain that has not ended, whose domain pid stands for it (erx_domain_core:ended/5).
-define(IS_LIVE(Life), (Life =:= built orelse Life =:= running orelse Life =:= ready orelse Life =:= stopping)).

start_link() ->
    start_link(#{}).

-doc """
Opts may name lib, the domain library's module (erx_domain_lib), agent, the
connection agent's (erx_connections), exports, the export table's
(erx_dist), and introduce_timeout, an introduce/2 caller's deadline in
milliseconds, for a host test's stand-ins.
""".
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Opts) ->
    process_flag(trap_exit, true),
    Lib = library(maps:get(lib, Opts, erx_domain_lib)),
    Agent = maps:get(agent, Opts, erx_connections),
    Exports = maps:get(exports, Opts, erx_dist),
    %% Whether the runtime is a node, as kernel's start left it, since net_kernel starts
    %% before any application and lives as long as the runtime (close_side/4). Waiting
    %% holds, by domain id, each create not yet answered (wait_created/4).
    %% Introducing holds, by the pair's key, each introduce/2 caller waiting for its
    %% connection to come up, with the timer of its deadline (settle_introductions/1).
    {ok, #{lib => Lib, agent => Agent, exports => Exports, node => erlang:is_alive(), core => undefined,
           configured => #{}, templates => #{}, waiting => #{}, links => erx_domain_links:new(),
           introducing => #{}, introduce_timeout => maps:get(introduce_timeout, Opts, ?INTRODUCE_TIMEOUT)},
     {continue, boot}}.

%% The library, registered with this process as the one that hears of every end, or none.
library(Lib) ->
    try Lib:register() of
        ok -> Lib;
        {error, Reason} -> error({domain_library, Reason})
    catch
        error:undef -> none
    end.

handle_continue(boot, #{lib := Lib} = State) ->
    case {configured(Lib), templates(Lib)} of
        {{ok, #{host := Host, domains := Rows}}, {ok, Templates}} ->
            Ordered = lists:sort(fun(#{place := A}, #{place := B}) -> A =< B end, Rows),
            Configured = maps:from_list([{Row, Entry} || #{row := Row} = Entry <- Ordered]),
            Booted = State#{core := erx_domain_core:new(Host), configured := Configured,
                            templates := maps:from_list([{P, T} || #{principal := P} = T <- Templates])},
            {noreply, lists:foldl(fun start_configured/2, Booted, Ordered)};
        {{error, _}, _} ->
            {noreply, State#{core := erx_domain_core:new(<<>>)}};
        {_, {error, _}} ->
            {noreply, State#{core := erx_domain_core:new(<<>>)}}
    end.

configured(none) -> {error, enotsup};
configured(Lib) -> Lib:configured().

%% The library's session templates, or none.
templates(none) -> {error, enotsup};
templates(Lib) -> Lib:templates().

handle_call({create, Spec}, From, State) ->
    case create(Spec, State) of
        {{waiting, Domain}, Next} ->
            %% Answered by ready/3, or by settle/2 once nothing of the domain remains.
            {noreply, wait_created(Domain, none, From, Next)};
        {{refused, Domain, Refusal}, Next} ->
            %% Answered Refusal by settle/2 once the stop has ended the domain and nothing
            %% of it remains.
            {noreply, wait_created(Domain, Refusal, From, Next)};
        {{ready, Domain}, Next} ->
            {reply, {ok, Domain}, Next};
        {{error, _} = Error, Next} ->
            {reply, Error, Next}
    end;
handle_call({info, Id}, From, #{core := Core} = State) ->
    %% The domain pid answers the caller itself, so a flood in its mailbox delays only
    %% this caller, never the service.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{pid := Pid, ref := Ref, state := Life}} when ?IS_LIVE(Life) ->
            Pid ! {Ref, info, From},
            {noreply, State};
        _ ->
            {reply, {error, badarg}, State}
    end;
handle_call({introduce, A, B}, From, State) when is_integer(A), is_integer(B) ->
    case introduce(A, B, State) of
        {wait, Next} ->
            {noreply, wait_introduced(A, B, From, Next)};
        {Reply, Next} ->
            {reply, Reply, Next}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({domain_ended, Id, End, _Record}, State) ->
    {noreply, ended(Id, End, State)};
handle_info({domain_ready, Ref, Id, _Agents}, State) ->
    {noreply, ready(Id, Ref, State)};
handle_info({domain_answer, Ref, Id, Answer}, State) ->
    {noreply, answer(Id, Ref, Answer, State)};
handle_info({timeout, Timer, {introduce_timeout, Key, From}}, State) ->
    {noreply, introduce_timed_out(Key, From, Timer, State)};
handle_info({timeout, _Timer, {boot_timeout, Id}}, #{core := Core} = State) ->
    %% Ids are never reused, so the timer of a domain that reported ready or ended finds
    %% it ready or gone. A domain stopping for its timeout takes no late report
    %% (ready/3), and its create is answered timeout once the stop's end arrives.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := running}} ->
            logger:notice("erx_domain: domain ~b did not report ready in time; stopping it", [Id]),
            stop(Id, State),
            {noreply, State#{core := erx_domain_core:stopping(Id, Core)}};
        _ ->
            {noreply, State}
    end;
handle_info({stop_request, Ref, Id}, #{core := Core} = State) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{ref := Ref, state := Life}} when ?IS_LIVE(Life) -> stop(Id, State);
        _ -> ok
    end,
    {noreply, State};
handle_info({system_side_ended, Id}, #{core := Core} = State) ->
    %% The agent's report that a side it opened for this service ended before the service
    %% closed it: this runtime ended the connection, for a malformed frame, a peer bound
    %% passed or its owner's end, so the domain goes (docs/design-system.md, "A lost
    %% system connection ends the domain"). Ids are never reused, so a late report for an
    %% ended domain finds no record.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := Life}} when ?IS_LIVE(Life) ->
            logger:notice("erx_domain: domain ~b's system side ended; stopping the domain", [Id]),
            stop(Id, State);
        _ ->
            ok
    end,
    {noreply, State};
handle_info({'EXIT', Pid, _Reason}, #{core := Core} = State) when Core =/= undefined ->
    %% A domain pid that died first, by a kill or a fault of its own, stops its domain.
    case erx_domain_core:find_pid(Pid, Core) of
        {ok, #{id := Id, state := Life}} when ?IS_LIVE(Life) -> stop(Id, State);
        _ -> ok
    end,
    {noreply, pid_ended(Pid, State)};
handle_info(_Message, State) ->
    {noreply, State}.

%% A request: its name and fields checked, then built as a configured row is. Its facets
%% name processes of the system domain, by facet name, each with its grant's limits or
%% none; the domain gets a facet in front of each once it reports ready (grant_facets/2),
%% and the library never sees them.
create(_Spec, #{lib := none} = State) ->
    {{error, enotsup}, State};
create(#{name := Name} = Spec, State) ->
    Timeout = maps:get(boot_timeout, Spec, ?BOOT_TIMEOUT),
    Facets = facets(maps:get(facets, Spec, #{})),
    ValidFacets = Facets =/= invalid,
    Fields = maps:without([name, boot_timeout], Spec),
    case [Key || Key <- maps:keys(Fields), not lists:member(Key, ?REQUEST_KEYS)] of
        [Key | _] ->
            {{error, {bad_spec, Key}}, State};
        [] when not (Timeout =:= infinity orelse
                     (is_integer(Timeout) andalso Timeout >= 0 andalso Timeout =< ?BOOT_TIMEOUT_MAX)) ->
            {{error, {bad_spec, boot_timeout}}, State};
        [] when not ValidFacets ->
            {{error, {bad_spec, facets}}, State};
        [] ->
            case erx_ident:new(Name) of
                {error, bad_identifier} = Error ->
                    {Error, State};
                Ident ->
                    #{lib := Lib} = State,
                    Make = fun(Id, Pid) ->
                                   Lib:create((maps:without([facets], Fields))#{id => Id, name => Name,
                                                                                principal => ?SYSTEM_PRINCIPAL,
                                                                                domain_pid => Pid})
                           end,
                    build(Ident, ?SYSTEM_PRINCIPAL, request, Make, Facets, Timeout, State)
            end
    end;
create(_Spec, State) ->
    {{error, {bad_spec, name}}, State}.

%% A spec's facets, each as {Behind, Limits}, or invalid: a map from facet names to live or
%% dead processes of the system domain, each alone or with the limits of its grant that
%% differ from erx_facet's defaults, max_request and in_flight.
facets(Facets) when is_map(Facets) ->
    Valid = maps:filtermap(fun(Name, Facet) when is_atom(Name) -> facet(Facet);
                              (_Name, _Facet) -> false
                           end, Facets),
    case map_size(Valid) =:= map_size(Facets) of
        true -> Valid;
        false -> invalid
    end;
facets(_Facets) ->
    invalid.

facet(Behind) when is_pid(Behind) ->
    facet({Behind, #{}});
facet({Behind, Limits}) when is_pid(Behind), node(Behind) =:= node(), is_map(Limits) ->
    Positive = fun(Key) -> is_integer(map_get(Key, Limits)) andalso map_get(Key, Limits) > 0 end,
    case lists:all(Positive, maps:keys(maps:with([max_request, in_flight], Limits))) andalso
         map_size(maps:without([max_request, in_flight], Limits)) =:= 0 of
        true -> {true, {Behind, Limits}};
        false -> false
    end;
facet(_Facet) ->
    false.

start_configured(#{row := Row, name := Name, principal := Principal}, #{lib := Lib} = State) ->
    case erx_ident:new(Name) of
        {error, bad_identifier} ->
            logger:error("erx_domain: configured row ~b has no identifier for a name", [Row]),
            State;
        Ident ->
            Make = fun(Id, Pid) -> Lib:configured(Id, Row, Pid) end,
            case build(Ident, Principal, {configured, Row}, Make, #{}, ?BOOT_TIMEOUT, State) of
                {{error, Reason}, Next} ->
                    logger:error("erx_domain: configured domain ~ts did not start: ~0p", [Name, Reason]),
                    Next;
                {{refused, _Domain, {error, Reason}}, Next} ->
                    logger:error("erx_domain: configured domain ~ts did not start: ~0p", [Name, Reason]),
                    Next;
                {_Started, Next} ->
                    Next
            end
    end.

%% Admits Ident, makes its domain pid, which its boot page names, has the library
%% make it with Make(Id, Pid) and starts its first thread once the system side of its
%% system connection is open and the pid is exported to the domain. A refused plan ends
%% the pid, unlinked first, so no domain is stopped for it; a domain the library made
%% whose side, export or start is refused is stopped, its end retires it as any end
%% does, and its create is refused once it has ended and been retired. A started domain
%% is waiting for its init's ready report, which Timeout bounds, unless it has no system connection,
%% the one path a report could take: then it is ready at its start. Facets are the
%% processes the domain gets a facet in front of when it reports ready; a domain with no
%% system connection never reports, so it gets none.
build(Ident, Principal, Origin, Make, Facets, Timeout, #{core := Core} = State) ->
    case erx_domain_core:admit(Ident, Principal, Origin, Core) of
        {error, _} = Error ->
            {Error, State};
        {ok, #{id := Id, node := Node}, Admitted} ->
            Ref = make_ref(),
            Pid = erx_domain_pid:start_link(self(), Id, Node, Ref),
            case made(Make, Id, Pid) of
                {ok, #{connection := Connection} = Created} ->
                    Built = erx_domain_core:built(Id, Created#{facets => Facets}, Pid, Ref, Admitted),
                    Next = State#{core := Built, links := add_party(Id, Node, Created, State)},
                    Domain = {erx_domain, Id, Node, Pid},
                    case started(Id, Pid, Ref, Created#{node => Node}, Next) of
                        ok when Connection =:= 0 ->
                            Ready = erx_domain_core:ready(Id, erx_domain_core:running(Id, Built)),
                            {{ready, Domain}, Next#{core := Ready}};
                        ok ->
                            boot_timer(Id, Timeout),
                            {{waiting, Domain}, Next#{core := erx_domain_core:running(Id, Built)}};
                        {error, _} = Refused ->
                            %% A stop the library refuses brings no end, so nothing would
                            %% answer the create later: it is refused now.
                            case stop(Id, Next) of
                                ok -> {{refused, Domain, Refused}, Next};
                                refused -> {Refused, Next}
                            end
                    end;
                {error, Reason} ->
                    unlink(Pid),
                    exit(Pid, kill),
                    {{error, refusal(Reason)}, State#{core := erx_domain_core:failed(Id, Admitted)}}
            end
    end.

%% Any other exception ends the domain pid before it reaches the service, so no pid
%% outlives a plan that was never made.
made(Make, Id, Pid) ->
    try Make(Id, Pid)
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stack ->
            unlink(Pid),
            exit(Pid, kill),
            erlang:raise(Class, Reason, Stack)
    end.

refusal(enomem) -> no_memory;
refusal(Reason) -> Reason.

%% A built domain is a party of the connection protocol, with one control slot per
%% connection it may hold. A domain with no system connection has no table and no agent
%% to read it, so it has no slots and is never ready: it can be introduced to no one.
add_party(Id, Node, #{connection := 0}, #{links := Links}) ->
    erx_domain_links:add_party(Id, Node, 0, Links);
add_party(Id, Node, #{ctl_slots := Slots}, #{links := Links}) ->
    erx_domain_links:add_party(Id, Node, Slots, Links).

%% A made domain's system side, opened with the library's values of it and the domain's
%% node, its port handed to the domain pid, which writes the domain's control records
%% through it, then the domain pid's export to it, then its first thread; a domain with no
%% system connection has no side. The domain gets send on its pid, its one way to report
%% ready and answer; its creator, a process of the system domain, which holds every
%% right on the system domain's own pids, needs no export.
started(Id, Pid, Ref, Values, #{lib := Lib, agent := Agent, exports := Exports}) ->
    first_refusal([{system_side, fun() -> open_side(Agent, Id, Pid, Ref, Values) end},
                   {export, fun() -> export(Exports, Pid, Id, Values) end},
                   {start, fun() -> Lib:start(Id) end}]).

%% Runs each step in turn: ok, or {error, {Step, Reason}} for the first that refuses.
first_refusal([]) ->
    ok;
first_refusal([{Step, Run} | Rest]) ->
    case Run() of
        ok -> first_refusal(Rest);
        {error, Reason} -> {error, {Step, Reason}}
    end.

%% A domain with no system connection has no way to message its pid, so needs no export.
export(_Exports, _Pid, _Id, #{connection := 0}) -> ok;
export(Exports, Pid, Id, _Values) -> Exports:export(Pid, [send], Id).

boot_timer(_Id, infinity) -> ok;
boot_timer(Id, Timeout) -> _ = erlang:start_timer(Timeout, self(), {boot_timeout, Id}), ok.

%% Domain Id's ready report, which its domain pid passed on with Ref: the domain is ready
%% and its create, if any, answered. A domain that ended while running, its end having
%% overtaken a report its pid passed on before the pid's own end, reported too, and its
%% create answers ok. A report for a domain that is ready already, or that ended stopping
%% for its boot timeout, changes nothing.
ready(Id, Ref, #{core := Core, waiting := Waiting} = State) ->
    case {erx_domain_core:fetch(Id, Core), Waiting} of
        {{ok, #{ref := Ref, state := running}}, _} ->
            {Actions, Links} = erx_domain_links:ready(Id, maps:get(links, State)),
            Ready = State#{core := erx_domain_core:ready(Id, Core), links := Links},
            answer_ready(Id, grant_facets(Id, perform(Actions, Ready)));
        {_, #{Id := #{ref := Ref, ended := {running, _Info}}}} ->
            answer_ready(Id, State);
        _ ->
            State
    end.

%% The answer to domain Id's ready report, its facets by name. Each is minted in front of
%% the process the spec named, bound to the domain and exported to it (erx_facet:start/3),
%% and ends with the domain pid or that process. The answer goes to the domain pid, which
%% hands it to the domain's agent for init (edit 65). Init waits for it, so every domain
%% that reported is answered, with no facets too.
grant_facets(Id, #{core := Core, exports := Exports} = State) ->
    {ok, #{pid := Pid, ref := Ref, facets := Facets}} = erx_domain_core:fetch(Id, Core),
    Minted = maps:filtermap(fun(Name, Facet) -> mint(Id, Pid, Name, Facet, Exports) end, Facets),
    Pid ! {Ref, facets, Minted},
    State.

mint(Id, DomainPid, Name, {Behind, Limits}, Exports) ->
    Grant = Limits#{grantee => Id, ends_with => [DomainPid, Behind], behind => Behind},
    case erx_facet:start(erx_domain_facet, Grant, #{exports => Exports}) of
        {ok, Facet} ->
            {true, Facet};
        %% The domain or the process behind ended while the service minted.
        {error, noproc} ->
            false;
        %% Left out, so erx:cap/1 in the domain finds none of that name.
        {error, Reason} ->
            logger:error("erx_domain: domain ~b's facet ~ts did not start: ~0p", [Id, Name, Reason]),
            false
    end.

answer_ready(Id, #{waiting := Waiting} = State) ->
    case maps:take(Id, Waiting) of
        {#{from := From, domain := Domain}, Rest} ->
            gen_server:reply(From, {ok, Domain}),
            State#{waiting := Rest};
        error ->
            State
    end.

%% A create waiting for domain Id: its caller, the domain, its domain pid's secret, that
%% pid until it ends and gone after, the life the domain ended in and its Info once it has
%% ended (ended/3), and the refusal to answer once nothing of it remains, none for a
%% domain that was started.
wait_created({erx_domain, Id, _, Pid} = Domain, Refusal, From, #{core := Core, waiting := Waiting} = State) ->
    {ok, #{ref := Ref}} = erx_domain_core:fetch(Id, Core),
    Waiter = #{from => From, domain => Domain, ref => Ref, pid => Pid, ended => none, refusal => Refusal},
    State#{waiting := Waiting#{Id => Waiter}}.

%% A create whose domain ended before its report reached the service waits for the
%% domain pid's end as well: the service tells the pid of the end only once the domain's
%% system side is closed, and the pid passes on every report the side delivered before it
%% ends (erx_domain_pid's finish), so no report is still to come once both have ended.
waiter_ended(Id, Life, Info, #{waiting := Waiting} = State) ->
    case Waiting of
        #{Id := Waiter} -> settle(Id, State#{waiting := Waiting#{Id := Waiter#{ended := {Life, Info}}}});
        #{} -> State
    end.

pid_ended(Pid, #{waiting := Waiting} = State) ->
    case [{Id, Waiter} || Id := #{pid := P} = Waiter <- Waiting, P =:= Pid] of
        [{Id, Waiter}] -> settle(Id, State#{waiting := Waiting#{Id := Waiter#{pid := gone}}});
        [] -> State
    end.

%% Answers the create of domain Id, which ended in life Life before it reported ready,
%% once nothing of the domain is charged but what a survivor still maps (A4 of
%% docs/design-system.md): it has ended, which ended/3 notes only after it asked the
%% library to retire it (a refusal is logged by retire/2), and its domain pid has ended. ended/3 and pid_ended/2 each call this, so
%% whichever of the two comes last answers.
settle(Id, #{waiting := Waiting} = State) ->
    case Waiting of
        #{Id := #{from := From, pid := gone, ended := {Life, Info}, refusal := Refusal}} ->
            gen_server:reply(From, create_error(Refusal, Life, Info)),
            State#{waiting := maps:remove(Id, Waiting)};
        #{} ->
            State
    end.

%% The create's answer: the refusal of a domain that was not started, or how one that
%% was started ended before it reported.
create_error(none, Life, Info) -> {error, unreported(Life, Info)};
create_error({error, _} = Refusal, _Life, _Info) -> Refusal.

%% Stopping for its boot timeout, the domain timed out; otherwise it ended by itself.
unreported(stopping, _Info) -> timeout;
unreported(_Life, Info) -> {boot, Info}.

open_side(_Agent, _Id, _Pid, _Ref, #{connection := 0}) ->
    ok;
open_side(Agent, Id, Pid, Ref, Values) ->
    case Agent:open_side(Id, Values) of
        {ok, Port} ->
            Pid ! {Ref, port, Port},
            ok;
        {error, _} = Refused ->
            Refused
    end.

%% Introducing domains A and B, both of them domains this service built that have not
%% ended. A pair already joined answers ok when its connection is up and waits while it
%% comes up; a pair whose connection is closing is refused until it is gone, since a pair
%% has at most one connection. Otherwise each domain must have room for one more
%% connection, which erx_domain_links counts until the domain's side is done, closing
%% included; then the library builds the connection, A reading a ring of its own lane and
%% B one of its, and the core records it and says which connection_up records go now.
%% The library's own refusals, a party at its limit or with an outer budget that cannot
%% fund its child for the connection, are system_limit too, and its einval for a domain
%% it has ended before the end reached the service is badarg, as for any ended domain.
introduce(_A, _B, #{lib := none} = State) ->
    {{error, enotsup}, State};
introduce(A, B, #{core := Core, links := Links, lib := Lib} = State) ->
    case {introducible(A, Core), introducible(B, Core)} of
        {{ok, ReaderA}, {ok, ReaderB}} when A =/= B ->
            case erx_domain_links:phase(A, B, Links) of
                up ->
                    {ok, State};
                up_pending ->
                    {wait, State};
                none ->
                    case erx_domain_links:room(A, Links) andalso erx_domain_links:room(B, Links) of
                        true -> connect(Lib:connect(A, B, ReaderA, ReaderB), A, B, ReaderA, ReaderB, State);
                        false -> {{error, system_limit}, State}
                    end;
                _Closing ->
                    {{error, closing}, State}
            end;
        _ ->
            {{error, badarg}, State}
    end.

%% A domain that can be introduced, with its lane: one built and not ended.
introducible(Id, Core) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := Life, reader := Reader}} when Life =:= built; Life =:= running; Life =:= ready ->
            {ok, Reader};
        _ ->
            none
    end.

%% The library's answer to connecting A and B. Each party's connection_up carries the
%% slots of its own side, its peer's side and its peer's bell, the label of its own bell,
%% and the data areas of the ring it writes, which its peer reads, and of the one it reads.
connect({ok, #{number := Number, a := PartyA, b := PartyB}}, A, B, ReaderA, ReaderB, #{links := Links} = State) ->
    UpA = up_values(PartyA, ReaderB, ReaderA),
    UpB = up_values(PartyB, ReaderA, ReaderB),
    {Actions, Next} = erx_domain_links:connect(Number, {A, UpA}, {B, UpB}, Links),
    {wait, perform(Actions, State#{links := Next})};
connect({error, Limit}, _A, _B, _ReaderA, _ReaderB, State) when Limit =:= elimit; Limit =:= enomem ->
    {{error, system_limit}, State};
connect({error, einval}, _A, _B, _ReaderA, _ReaderB, State) ->
    %% A domain the library has ended, whose end has not reached the service yet: an
    %% ended domain, as introducible/2 would find it once the end arrives.
    {{error, badarg}, State};
connect({error, _} = Refused, _A, _B, _ReaderA, _ReaderB, State) ->
    {Refused, State}.

up_values(#{side := Side, peer_side := PeerSide, peer_bell := PeerBell, label := Label}, OutSize, InSize) ->
    {Side, PeerSide, PeerBell, Label, OutSize, InSize}.

%% A caller waits at most the service's introduce_timeout, so neither a domain that never
%% answers its connection_up nor a caller that died first keeps an entry here for longer.
wait_introduced(A, B, From, #{introducing := Introducing, introduce_timeout := Timeout} = State) ->
    Key = {min(A, B), max(A, B)},
    Timer = erlang:start_timer(Timeout, self(), {introduce_timeout, Key, From}),
    Callers = maps:get(Key, Introducing, #{}),
    settle_introductions(State#{introducing := Introducing#{Key => Callers#{From => Timer}}}).

%% A caller's deadline passed with its connection still coming up: it is answered timeout,
%% and the connection is left as it is, so a later introduction answers ok once it is up.
%% A deadline whose caller was answered already finds no entry with its timer.
introduce_timed_out(Key, From, Timer, #{introducing := Introducing} = State) ->
    case Introducing of
        #{Key := #{From := Timer} = Callers} ->
            gen_server:reply(From, {error, timeout}),
            Rest = maps:remove(From, Callers),
            State#{introducing := case map_size(Rest) of
                                      0 -> maps:remove(Key, Introducing);
                                      _ -> Introducing#{Key := Rest}
                                  end};
        #{} ->
            State
    end.

%% Answers every introduce/2 caller whose connection has settled, and stops its deadline:
%% ok once it is up, and noconnection once it closed before it came up.
settle_introductions(#{introducing := Introducing, links := Links} = State) ->
    Pending = maps:filter(fun({A, B}, Callers) ->
                                  case erx_domain_links:phase(A, B, Links) of
                                      up_pending -> true;
                                      up -> answer_callers(Callers, ok);
                                      _ -> answer_callers(Callers, {error, noconnection})
                                  end
                          end, Introducing),
    State#{introducing := Pending}.

answer_callers(Callers, Reply) ->
    _ = [begin
             _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
             gen_server:reply(From, Reply)
         end || From := Timer <- Callers],
    false.

%% Performs erx_domain_links's actions in order: each record goes to its party's domain
%% pid, tagged with the secret the two share and the slot the core gave it, and the pid
%% writes it into that slot of the domain's control table at once (erx_domain_pid); a
%% disconnect destroys the connection's children, with its objects, and the remains of a
%% retired party whose last connection that was.
perform(Actions, State) ->
    settle_introductions(lists:foldl(fun act/2, State, Actions)).

act({send, P, Slot, Record}, #{core := Core} = State) ->
    %% The core sends only to a party it holds, and holds none whose domain has ended.
    {ok, #{pid := Pid, ref := Ref}} = erx_domain_core:fetch(P, Core),
    Pid ! {Ref, record, Slot, wire(Record)},
    State;
act({disconnect, Number}, #{lib := Lib} = State) ->
    case Lib:disconnect(Number) of
        ok -> State;
        {error, Reason} ->
            logger:error("erx_domain: the library refused to disconnect connection ~b: ~0p", [Number, Reason]),
            State
    end.

%% The records as a domain's connection agent reads them (docs/design-domains.md,
%% "Messages between the domain service and a runtime").
wire({connection_up, Peer, PeerNode, {Side, PeerSide, PeerBell, Label, OutSize, InSize}}) ->
    {erx_connection_up, Peer, PeerNode, Side, PeerSide, PeerBell, Label, OutSize, InSize};
wire({connection_down, Peer, Reason}) ->
    {erx_connection_down, Peer, Reason}.

%% Asks the library to retire ended domain Id, its crash area read and its system
%% connection disconnected: the library frees the domain's record and gives its principal
%% back the domain, keeping only the outer budget a survivor's connection still holds a
%% child of. A refusal, which only a bug of the service or the library makes (a system
%% connection whose disconnect was refused, say), leaves the record charged in the library,
%% and is logged; the create of the domain is answered all the same (TODO.md).
retire(Lib, Id) ->
    case Lib:retire(Id) of
        ok ->
            ok;
        {error, Reason} ->
            logger:error("erx_domain: the library refused to retire domain ~b: ~0p", [Id, Reason]),
            refused
    end.

%% An answer domain Id's pid passed on with Ref, applied by the protocol's core only when
%% it names a connection of the domain in the state that expects it; the core drops and
%% counts any other.
answer(Id, Ref, Answer, #{core := Core, links := Links} = State) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{ref := Ref}} ->
            {Actions, Next} = erx_domain_links:answer(Id, unwire(Answer), Links),
            perform(Actions, State#{links := Next});
        _ ->
            State
    end.

%% The pid passes on only the three answers (erx_domain_pid:is_answer/1).
unwire({erx_connection_mapped, Peer}) -> {connection_mapped, Peer};
unwire({erx_connection_unmapped, Peer}) -> {connection_unmapped, Peer};
unwire({erx_connection_lost, Peer, Reason}) -> {connection_lost, Peer, Reason};
unwire(Answer) -> Answer.

%% Asks the library to stop domain Id, whose end then arrives as domain_ended: ok, or
%% refused, logged, when no end will come.
stop(Id, #{lib := Lib}) ->
    case Lib:stop(Id, 0) of
        ok ->
            ok;
        {error, Reason} ->
            logger:error("erx_domain: the library refused to stop domain ~b: ~0p", [Id, Reason]),
            refused
    end.

%% A domain's end: its system side's port ends before its connection's objects are
%% destroyed and before its domain pid ends, so no driver callback touches them once they
%% are gone (the unmap itself may still trail the port's end: TODO.md). Every peer that
%% knows of a connection with it is told connection_down with {domain_down, Id, Info};
%% such a connection's objects go once the peer has answered. The domain is retired at
%% once, before its restart, and only the outer budget such a connection's child is
%% carved from outlives it, as the library's remains, until that disconnect.
ended(Id, End, #{lib := Lib, core := Core, links := Links} = State) ->
    case erx_domain_core:ended(Id, End, slogan(Lib, Id, End), erlang:system_time(second), Core) of
        none ->
            State;
        {Info, #{pid := Pid, ref := Ref, connection := Connection, origin := Origin, state := Life}, Ended} ->
            close_side(Id, Connection, {domain_down, Id, Info}, State),
            disconnect(Lib, Connection),
            Pid ! {Ref, domain_down, Info},
            {Actions, Unlinked} = erx_domain_links:ended(Id, Info, Links),
            Told = perform(Actions, State#{core := Ended, links := Unlinked}),
            _ = retire(Lib, Id),
            restart(Origin, waiter_ended(Id, Life, Info, Told))
    end.

%% A crash's slogan, from its crash area, which goes at the retire after it.
slogan(Lib, Id, {crash, _}) ->
    case Lib:crash(Id) of
        {ok, Slogan, _Dump, _Truncated} -> Slogan;
        {error, Reason} -> {unreadable, Reason}
    end;
slogan(_Lib, _Id, _End) ->
    none.

%% A domain with no system connection has no side, and a runtime that was no node at the
%% service's start, where no agent runs, opened none. In a node, the agent ends only as the
%% runtime ends: it halts it, or follows net_kernel's shutdown in an ordered end or once
%% kernel_sup gives up (erx_connections:kernel_ended/1), so noproc there finds that end
%% under way; the service ends rather than destroy objects a live port may map.
close_side(_Id, 0, _Reason, _State) ->
    ok;
close_side(Id, _Connection, Reason, #{agent := Agent, node := Node}) ->
    case {Agent:close_side(Id, Reason), Node} of
        {ok, _} -> ok;
        {{error, noproc}, false} -> ok;
        {{error, noproc}, true} -> error({connection_agent, noproc})
    end.

disconnect(_Lib, 0) -> ok;
disconnect(Lib, Connection) ->
    case Lib:disconnect(Connection) of
        ok -> ok;
        {error, Reason} ->
            logger:error("erx_domain: the library refused to disconnect connection ~b: ~0p", [Connection, Reason])
    end.

restart(request, State) ->
    State;
restart({configured, Row}, #{core := Core, configured := Configured} = State) ->
    #{Row := #{restarts := Restarts, restart_period_s := Period} = Entry} = Configured,
    case erx_domain_core:restart(Row, Restarts, Period, erlang:monotonic_time(second), Core) of
        {yes, Next} -> start_configured(Entry, State#{core := Next});
        {no, Next} -> State#{core := Next}
    end.
