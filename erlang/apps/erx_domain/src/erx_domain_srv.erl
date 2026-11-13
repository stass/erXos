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
domain within its restart intensity. It keeps the
manifest's session templates by principal and makes each session of a
principal from its template alone (start_session): the library builds the
domain from the template's row and judges it against the principal, and the
service chooses only its name, its facets and the display, if any, its
start names. A template is no configured
domain, so the boot never starts one, and nothing restarts one or a session.

A create or a session's start for a principal one of whose domains is
ending, its domain pid gone but its end not yet arrived, is held until that
end has retired the domain and answered then (start/3): the library still
counts such a domain against the principal's domain quota, while its pid's
end has already told the caller it is gone, so a login started again on a
killed session's end would otherwise be refused. The hold is bounded by
release_wait, after which the library answers the start as it stands.

It also introduces domains (docs/design-domains.md, "Introduction and
connection down"): introduce/2 has the library connect two domains and
erx_domain_links, the connection protocol's pure core, decide which
connection-control record goes to which domain, in which slot of its control
table, and when a connection's objects are deleted; the service performs
those actions, hands each record to the party's domain pid, which writes it,
and applies each answer the domain pid passes on. A party is added when its
domain is built, is ready when its init reports, and ends with its domain.

It mints the facets configured domains serve (docs/design-system.md,
"Facets a configured domain serves"): erx_domain_mints, that protocol's
pure core, takes each configured domain's ready report, with the provides
its domain pid passed on, and its end, and each session's ready report and
end, with the template its own record of the session names, and decides,
so every live session of a template holds its own grant of each of the
template's facets; the service performs
its actions and feeds back what they produce. Nothing in it waits on a
domain: an introduction the library cannot settle at once is answered later
as an introduce/2 caller is, the mint's request and the installation are
messages, the mint's reply arrives in its envelope and the grantee's
acknowledgement through its domain pid, and each operation's deadline is a
timer. A facet for the system domain goes into the system domain's own
registry, which erx:cap/1 reads, and is acknowledged there and then. Every
refusal and dropped message is counted (the call mints);
their log lines are rate-limited (throttle/2). The facets of services the
system domain serves that the manifest grants a configured domain or a
session's template go in the domain's ready answer, each in front of the
process its service named with erx_facet:serve/2 (served/2); the inspect
facet with the scope erx_domain_core:inspect_scope/3 gives the domain's
principal (system_facet/4); and for a service of the `files` interface, an
erx_fs grant that the process its service named, an erx_fs_grants
supervisor, starts bound to the domain and ending with it, in place of a
facet.

A session's start is answered only once its namespace is in place, each
files grant to it installed or settled as failed (docs/design-system.md, "A
session takes the console"), and the console connects its line only on that
answer. Its waiting entry outlives its ready report until
erx_domain_mints:in_place/3 holds for it, checked after every step of the mint
core (answer_in_place/1), or until it ends, when the start is answered with
an error. A configured row is starting while its domain runs without having
reported ready; the row's boot timeout bounds that. The system domain's
namespace is in place by the same rule, for the grants to the system domain,
and erx_domain:system_namespace/0 is answered ok once it is, which the start
table waits on before its first read of rc.conf (docs/design-system.md, the
boot's step 5).

A session's ready report names its line to the web domain among its provides;
the service keeps that pid until the session ends and hands it out only
through erx_domain:web_line/2, when the host opens its web facet.

Its state, erx_domain_core's and erx_domain_links's, lives in its own heap and nowhere else. The
service is never restarted: its end, however it comes, ends the system
domain (erx_domain_sup), and no domain outlives that, so no successor needs
its records. Where the system domain has no domain library (a hosted
runtime), erx_domain_lib's register/0 answers
{error, enotsup}, and the service runs with none and every create is
{error, enotsup}.

Callers are the system domain's own processes; requests from other domains
reach it only through facets, which arrive with the connections.
""".
-behaviour(gen_server).

-export([start_link/0, start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").
-include("generated/erx_facet_names.hrl").

%% The keys of a session's start beyond its console: the display the session is the
%% session of, or the one it only takes as its default (session_start/3).
-define(START_DISPLAYS, [display, default_display]).
%% The keys of a request beyond its name, boot and boot_timeout: erx_domain_lib:spec()'s, less
%% id, principal and domain_pid, which the service sets, and facets, the service's own.
-define(REQUEST_KEYS, [runtime, release, release_files, memory, outer, grant, lane, args, env,
                       connections, flags, spaces, limits, facets]).
%% How long a session's init has to report ready, in milliseconds, and a requested
%% domain's unless its request sets boot_timeout (docs/design-domains.md, "Erlang
%% interface"): the manifest's default for a configured row, so every domain the
%% machine boots has one default. A configured domain has its row's boot_timeout_s,
%% which the manifest's reader bounds (abi/manifest.txt).
-define(BOOT_TIMEOUT, (?ERX_BOOT_TIMEOUT_DEFAULT_S * 1000)).
%% How long an introduce/2 caller waits for the connection to come up at both ends, in
%% milliseconds, unless start_link/1's introduce_timeout sets it (docs/design-domains.md,
%% "Erlang interface").
-define(INTRODUCE_TIMEOUT, 10000).
%% How long a start waits for its principal's ending domains to be retired, in
%% milliseconds, unless start_link/1's release_wait sets it (start/3).
-define(RELEASE_WAIT, 10000).
%% The longest boot_timeout erlang:start_timer/3 takes.
-define(BOOT_TIMEOUT_MAX, 16#ffffffff).
%% At most this many log lines for refused and dropped mint messages within each window
%% of this many milliseconds; the rest are counted, and their number logged as the next
%% window opens (throttle/2).
-define(MINT_LOG_BURST, 10).
-define(MINT_LOG_WINDOW, 60000).
%% The system domain's id, a grantee whose registry is the service's own runtime's.
-define(SYSTEM_ID, 4).
%% A domain that has not ended, whose domain pid stands for it (erx_domain_core:ended/5).
-define(IS_LIVE(Life), (Life =:= built orelse Life =:= running orelse Life =:= ready orelse Life =:= stopping)).

start_link() ->
    start_link(#{}).

-doc """
Opts names a host test's stand-ins: lib, the domain library's module
(erx_domain_lib by default); agent, the connection agent's (erx_connections);
exports, the export table's (erx_dist); introduce_timeout, an introduce/2
caller's deadline in milliseconds; release_wait, a held start's bound
(start/3); mints, the owner function (erx_dist:owner/1 by default) and
deadline that erx_domain_mints:new/1 takes; facet_names, the table of
facet names that facets/2 checks (the generated ?ERX_FACET_NAMES by default);
inspect_policy, #{roots, development}, the system-shell principals and
development flag every inspect facet's scope is decided from (inspect_policy/1);
and principals, the manifest's system principal and principal names, which
name each principal's sessions (principals/2).
""".
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

init(Opts) ->
    process_flag(trap_exit, true),
    Lib = library(maps:get(lib, Opts, erx_domain_lib)),
    case principals(Lib, Opts) of
        {ok, Principals} ->
            {ok, booted(state(Lib, Principals, Opts)), {continue, boot}};
        {error, Reason} ->
            logger:error("erx_domain_srv: cannot read the principals of the system manifest "
                         "(/manifest), which the domain library booted from: ~0p", [Reason]),
            {stop, {system_manifest, Reason}}
    end.

%% The service's state as it starts, with Lib its library and Principals the manifest's.
state(Lib, Principals, Opts) ->
    Agent = maps:get(agent, Opts, erx_connections),
    Exports = maps:get(exports, Opts, erx_dist),
    %% Whether the runtime is a node, as kernel's start left it, since net_kernel starts
    %% before any application and lives as long as the runtime (close_side/4). Waiting
    %% holds, by domain id, each create or session's start not yet answered (wait_created/4),
    %% and system_waiting, newest first, each erx_domain:system_namespace/0 caller not yet
    %% answered (answer_in_place/1).
    %% Introducing holds, by the pair's key, each introduce/2 caller, or {mints, Tag} for the mint core (reply/2), waiting for its
    %% connection to come up, with the timer of its deadline (settle_introductions/1).
    %% Held holds, by principal and in arrival order, each start waiting for the
    %% principal's ending domains to be retired, with the timer of its bound (start/3).
    %% Mints is erx_domain_mints' state, its pending operations' deadlines by tag in
    %% mint_timers, and mint_counts and mint_log what was refused or dropped (note/4).
    %% Served holds, by configured row and by {template, T}, the facets of services the
    %% system domain serves that the manifest grants the row or the template's sessions,
    %% each its service's name, its kind (served_kind/2) and the grant's limits.
    MintConfig = maps:merge(#{owner => fun erx_dist:owner/1}, maps:with([owner, deadline], maps:get(mints, Opts, #{}))),
    #{lib => Lib, agent => Agent, exports => Exports, node => erlang:is_alive(), core => undefined,
      configured => #{}, templates => #{}, waiting => #{}, system_waiting => [], links => erx_domain_links:new(),
      introducing => #{}, introduce_timeout => maps:get(introduce_timeout, Opts, ?INTRODUCE_TIMEOUT),
      held => #{}, release_wait => maps:get(release_wait, Opts, ?RELEASE_WAIT),
      mint_config => MintConfig, mints => erx_domain_mints:new(MintConfig#{services => [], grants => []}),
      mint_timers => #{}, mint_counts => #{}, mint_log => {erlang:monotonic_time(millisecond), 0, 0},
      served => #{}, web_lines => #{},
      facet_names => maps:get(facet_names, Opts, ?ERX_FACET_NAMES),
      inspect_policy => inspect_policy(Opts), principals => Principals}.

%% What every inspect facet's scope is decided from (erx_domain_core:inspect_scope/3): the
%% system manifest's system-shell principals and its development flag, read once, as the
%% service starts, from the system domain's own copy of the manifest (erx_build); a host
%% test names its own.
inspect_policy(#{inspect_policy := #{roots := Roots, development := Development} = Policy})
  when is_list(Roots), is_boolean(Development) ->
    Policy;
inspect_policy(_Opts) ->
    #{roots => erx_build:shell_principals(), development => erx_build:development()}.

%% The system manifest's system principal and principal names, which name each
%% principal's sessions (erx_domain_core:session_prefix/3), read once, as the service
%% starts, as inspect_policy/1 reads its policy. The system principal is the one the
%% service charges its own creates to and the console logs in at the system domain's line
%% (erx_domain:system_principal/0): the packer numbers principals in name order, so it is
%% whichever the manifest's root.system_principal names, not principal 1.
%%
%% A host test, whose library is a stand-in with no manifest, names its own in Opts. A
%% runtime with no library makes no domain, so it reads no manifest and has no system
%% principal (none). With the library loaded the manifest must be read, since the library
%% booted from it: one the service cannot read means the system domain is broken, and the
%% read's error fails the service's start (init/1).
principals(_Lib, #{principals := #{system := System, names := Names} = Principals})
  when is_integer(System), is_map(Names) ->
    {ok, Principals};
principals(none, _Opts) ->
    {ok, #{system => none, names => #{}}};
principals(_Lib, _Opts) ->
    erx_build:principals().

%% The library, registered with this process as the one that hears of every end, or none
%% where the system domain has none. A module that does not load is not a missing
%% library: its undef ends the service, and with it the system domain.
library(Lib) ->
    case Lib:register() of
        ok -> Lib;
        {error, enotsup} -> none;
        {error, Reason} -> error({domain_library, Reason})
    end.

%% Boot step 4's first part: each configured domain starts, in its place's order, before
%% the service takes a call.
handle_continue(boot, #{configured := Configured} = State) ->
    Ordered = lists:sort(fun(#{place := A}, #{place := B}) -> A =< B end, maps:values(Configured)),
    {noreply, lists:foldl(fun start_configured/2, State, Ordered)}.

%% The service's state once it has read from its library the manifest's configured
%% domains, session templates, services and facet rows. It runs in init/1, so that what
%% follows from the manifest is in place when start_link returns, the system domain's own
%% /data mount among it: the applications the release starts after erx_domain read /data
%% at once (erx_starter reads rc.conf there) and never call the service first. A library
%% that cannot say leaves no configured domain, no grant and an empty host.
booted(#{lib := Lib} = State) ->
    case {configured(Lib), templates(Lib)} of
        {{ok, #{host := Host, domains := Rows} = Boot}, {ok, Templates}} ->
            Configured = maps:from_list([{Row, Entry} || #{row := Row} = Entry <- Rows]),
            %% The manifest's service rows of configured domains and its facet rows,
            %% which the manifest check has proved consistent: a configured domain's
            %% service, and a grant to a session template's sessions, which only a
            %% configured domain serves, go to the mint core, the system domain's
            %% to the ready answers.
            {System, Minted} = lists:partition(fun({_Grantee, _Name, Server, _Limits}) -> Server =:= system end,
                                               maps:get(grants, Boot, [])),
            %% erx_domain_mints takes each configured domain's service as {Server,
            %% Name}; the interface number tells files services, which the mint core
            %% settles before a session's start answers and which the system domain
            %% serves as erx_fs grants (served_kind/2).
            Services = [{Server, Name} || {Server, Name, _Interface} <- maps:get(services, Boot, []), Server =/= system],
            Files = [Name || {_Server, Name, ?ERX_SERVICE_FILES} <- maps:get(services, Boot, [])],
            Mints = erx_domain_mints:new((maps:get(mint_config, State))#{services => Services,
                                           grants => Minted, files => Files}),
            Served = maps:groups_from_list(fun({Grantee, _, _, _}) -> Grantee end,
                                           fun({_, Name, _, Limits}) -> {Name, served_kind(Name, Files), Limits} end,
                                           System),
            %% The system domain's own facets of configured domains: /data only where the
            %% manifest grants the system domain data (docs/design-files.md, "A facet's
            %% mount").
            ok = erx_ns:mount_facets(erx_domain_mints:granted_names(system, Mints)),
            State#{core := erx_domain_core:new(Host), configured := Configured, mints := Mints, served := Served,
                   templates := maps:from_list([{P, T} || #{principal := P} = T <- Templates])};
        {{error, _}, _} ->
            State#{core := erx_domain_core:new(<<>>)};
        {_, {error, _}} ->
            State#{core := erx_domain_core:new(<<>>)}
    end.

configured(none) -> {error, enotsup};
configured(Lib) -> Lib:configured().

%% The library's session templates, or none.
templates(none) -> {error, enotsup};
templates(Lib) -> Lib:templates().

handle_call({create, Spec}, From, State) ->
    {noreply, start({create, Spec}, From, State)};
handle_call({start_session, Principal, Start}, From, State) ->
    {noreply, start({start_session, Principal, Start}, From, State)};
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
handle_call(system_namespace, From, #{system_waiting := System} = State) ->
    {noreply, answer_in_place(State#{system_waiting := [From | System]})};
handle_call(system_principal, _From, #{principals := #{system := System}} = State) ->
    Reply = case System of
                none -> {error, enotsup};
                _ -> {ok, System}
            end,
    {reply, Reply, State};
handle_call({web_line, Id}, _From, #{web_lines := Lines} = State) ->
    case Lines of
        #{Id := Line} -> {reply, {ok, Line}, State};
        #{} -> {reply, {error, no_line}, State}
    end;
handle_call({inspect_view, Scope}, _From, #{core := Core} = State)
  when Scope =:= all; is_tuple(Scope), tuple_size(Scope) =:= 2, element(1, Scope) =:= principal ->
    {reply, erx_domain_core:inspect_view(Scope, Core), State};
handle_call(mints, _From, #{mints := Mints, mint_counts := Counts} = State) ->
    %% Each grant's state, configured and per session, and how many of each refusal and drop were counted.
    {reply, #{grants => erx_domain_mints:grants(Mints), counts => Counts}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

%% A create or a session's start from From: run now, or held while a domain of its
%% principal is ending (ending/2) or an earlier start of the principal is held, so the
%% principal's starts run in arrival order. A held start runs once none of the
%% principal's domains is ending (release/1), or at its bound, release_wait, when the
%% library answers it as it stands.
start(Start, From, #{held := Held, release_wait := Wait} = State) ->
    Principal = principal(Start, State),
    case maps:is_key(Principal, Held) orelse ending(Principal, State) =/= [] of
        false ->
            run(Start, From, State);
        true ->
            Timer = erlang:start_timer(Wait, self(), {release_wait, Principal}),
            State#{held := Held#{Principal => maps:get(Principal, Held, []) ++ [{Timer, Start, From}]}}
    end.

%% The principal a start is charged to: a create's is the system principal.
principal({create, _Spec}, #{principals := #{system := System}}) -> System;
principal({start_session, Principal, _Start}, _State) -> Principal.

%% Principal's domains whose domain pid has ended before their end arrived, so the
%% library has not yet retired them and each still counts against the principal's
%% domain quota. The pid's
%% liveness is read, not the 'EXIT' the service may not have taken yet: a caller acts
%% on the pid's end, so its next start must see that end.
ending(Principal, #{core := Core}) ->
    [Id || #{id := Id, principal := P, pid := Pid} <- erx_domain_core:domains(Core),
           P =:= Principal, is_pid(Pid), not is_process_alive(Pid)].

%% Runs, in arrival order, the held starts of every principal none of whose domains is
%% ending any longer. ended/3, the one place the service retires a domain, calls it, so
%% no retirement a held start waits for passes it by.
release(#{held := Held} = State) ->
    lists:foldl(fun release/2, State, [P || P := _ <- Held, ending(P, State) =:= []]).

release(Principal, #{held := Held} = State) ->
    {Starts, Rest} = maps:take(Principal, Held),
    lists:foldl(fun({Timer, Start, From}, Acc) ->
                        _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
                        run(Start, From, Acc)
                end, State#{held := Rest}, Starts).

%% A held start whose bound passed runs now; a timer whose start ran already finds none.
release_timed_out(Principal, Timer, #{held := Held} = State) ->
    case lists:keytake(Timer, 1, maps:get(Principal, Held, [])) of
        {value, {Timer, Start, From}, []} -> run(Start, From, State#{held := maps:remove(Principal, Held)});
        {value, {Timer, Start, From}, Rest} -> run(Start, From, State#{held := Held#{Principal := Rest}});
        false -> State
    end.

run({create, Spec}, From, State) ->
    answer_create(create(Spec, State), From);
run({start_session, Principal, Start}, From, State) ->
    answer_create(start_session(Principal, Start, State), From).

%% A create's or a session's start's answer to From, now or once the domain reports or
%% is retired.
answer_create(Built, From) ->
    case Built of
        {{waiting, Domain}, Next} ->
            %% Answered by ready/4, a session's by answer_in_place/1 after it, or by
            %% settle/2 once nothing of the domain remains.
            wait_created(Domain, none, From, Next);
        {{refused, Domain, Refusal}, Next} ->
            %% Answered Refusal by settle/2 once the stop has ended the domain and nothing
            %% of it remains.
            wait_created(Domain, Refusal, From, Next);
        {{ready, Domain}, Next} ->
            gen_server:reply(From, {ok, Domain}),
            Next;
        {{error, _} = Error, Next} ->
            gen_server:reply(From, Error),
            Next
    end.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({domain_ended, Id, End, _Record}, State) ->
    {noreply, ended(Id, End, State)};
handle_info({domain_ready, Ref, Id, Provides, Inspect}, State) ->
    {noreply, ready(Id, Ref, Provides, Inspect, State)};
handle_info({mint_introduced, Tag, Result}, State) ->
    {noreply, mints({introduced, Tag, Result}, State)};
handle_info({timeout, Timer, {mint_deadline, Tag}}, #{mint_timers := Timers} = State) ->
    %% A deadline that was disarmed while its message was on the way finds another timer
    %% or none.
    case Timers of
        #{Tag := Timer} -> {noreply, mints({deadline, Tag}, State#{mint_timers := maps:remove(Tag, Timers)})};
        #{} -> {noreply, State}
    end;
handle_info({domain_answer, Ref, Id, Answer}, State) ->
    {noreply, answer(Id, Ref, Answer, State)};
handle_info({timeout, Timer, {introduce_timeout, Key, From}}, State) ->
    {noreply, introduce_timed_out(Key, From, Timer, State)};
handle_info({timeout, Timer, {release_wait, Principal}}, State) ->
    {noreply, release_timed_out(Principal, Timer, State)};
handle_info({timeout, _Timer, {boot_timeout, Id}}, #{core := Core} = State) ->
    %% Ids are never reused, so the timer of a domain that reported ready or ended finds
    %% it ready or gone. A domain stopping for its timeout takes no late report
    %% (ready/4), and its create is answered timeout once the stop's end arrives.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := running}} ->
            logger:notice("erx_domain: domain ~b did not report ready in time; stopping it", [Id]),
            stop(Id, State),
            %% A configured row stopping is no longer starting, so a session waiting for
            %% its grant is answered now, even if the library refused the stop and no
            %% end will come.
            {noreply, answer_in_place(State#{core := erx_domain_core:stopping(Id, Core)})};
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

%% A request: its name and fields checked, then built as a configured row is. Its boot
%% names the domain release's boot script, bin/<boot>.boot, which the service binds
%% with -boot /bin/<boot> as init's first flag (boot_args/2), as the manifest's packer
%% does for a configured row and a session template (docs/design-stopgap.md, "The
%% production image"), so args that name -boot are refused. Its facets
%% name the system domain's grants, by facet name, each with its limits or none, which
%% facets/2 checks; the domain gets a facet in front of each once it reports ready
%% (grant_facets/3), and the library never sees them.
create(_Spec, #{lib := none} = State) ->
    {{error, enotsup}, State};
create(#{name := Name} = Spec, State) ->
    Timeout = maps:get(boot_timeout, Spec, ?BOOT_TIMEOUT),
    Facets = facets(maps:get(facets, Spec, #{}), State),
    ValidFacets = Facets =/= invalid,
    Fields = maps:without([name, boot, boot_timeout], Spec),
    Args = boot_args(maps:get(args, Fields, <<>>), maps:get(boot, Spec, none)),
    case [Key || Key <- maps:keys(Fields), not lists:member(Key, ?REQUEST_KEYS)] of
        [Key | _] ->
            {{error, {bad_spec, Key}}, State};
        [] when not (Timeout =:= infinity orelse
                     (is_integer(Timeout) andalso Timeout >= 0 andalso Timeout =< ?BOOT_TIMEOUT_MAX)) ->
            {{error, {bad_spec, boot_timeout}}, State};
        [] when not ValidFacets ->
            {{error, {bad_spec, facets}}, State};
        [] when Args =:= badarg ->
            {{error, badarg}, State};
        [] when Args =:= invalid ->
            {{error, {bad_spec, boot}}, State};
        [] ->
            case erx_ident:new(Name) of
                {error, bad_identifier} = Error ->
                    {Error, State};
                Ident ->
                    #{lib := Lib, principals := #{system := System}} = State,
                    Make = fun(Id, Pid) ->
                                   Lib:create((maps:without([facets], Fields))#{id => Id, name => Name, args => Args,
                                                                                principal => System,
                                                                                domain_pid => Pid})
                           end,
                    build(Ident, System, request, Make, #{facets => Facets}, Timeout, State)
            end
    end;
create(_Spec, State) ->
    {{error, {bad_spec, name}}, State}.

%% A request's args as its boot page holds them: its emulator flags (the NUL-ended words
%% before the first --), then -- -boot /bin/Boot --, then its init arguments (the words
%% after that --), as the manifest's packer binds a configured row's (Erx::Manifest
%% boot_args). The binding is init's first flag and the second -- closes its value, so
%% no later word (-extra, a final -S) can make it a plain argument and leave init to its
%% default script. Invalid when the request names no boot, when Boot is no identifier,
%% so the path is one name under /bin, or when the words name -boot themselves;
%% badarg when Args is no binary, a field of the wrong shape.
boot_args(Args, Boot) when is_binary(Args), is_binary(Boot) ->
    Words = binary:split(Args, <<0>>, [global, trim]),
    {Emulator, Rest} = lists:splitwith(fun(Word) -> Word =/= <<"--">> end, Words),
    Init = case Rest of
               [<<"--">> | After] -> After;
               [] -> []
           end,
    Bound = Emulator ++ [<<"--">>, <<"-boot">>, <<"/bin/", Boot/binary>>, <<"--">> | Init],
    case erx_ident:new(Boot) =/= {error, bad_identifier} andalso not lists:member(<<"-boot">>, Words) of
        true -> << <<Word/binary, 0>> || Word <- Bound >>;
        false -> invalid
    end;
boot_args(Args, _Boot) when not is_binary(Args) ->
    badarg;
boot_args(_Args, _Boot) ->
    invalid.

%% A spec's facets, each as {Behind, Limits}, or invalid. This is the domain service's
%% one funnel for a domain's facets, which every create spec and session start passes
%% (docs/design-domains.md, "Facets", the facet table). Facets maps each facet name to a
%% grant, a pid alone or with limits (grant/1). The starter is the system domain, since
%% the service's callers are its own processes. The spec is refused whole unless the
%% spec may hand each of its names on (facet/3).
facets(Facets, State) when is_map(Facets) ->
    Valid = maps:filtermap(fun(Name, Grant) -> facet(Name, grant(Grant), State) end, Facets),
    case map_size(Valid) =:= map_size(Facets) of
        true -> Valid;
        false -> invalid
    end;
facets(_Facets, _State) ->
    invalid.

%% Whether a spec may hand Name on with its grant, and as what. One name, console, stands
%% outside the table as a stopgap, a literal here that goes with its TODO.md item; the
%% spec hands it on with a process of the system domain, live or dead, as its pid (local/1).
%% Every other name must be in the table of facet names (declared/2) and is handed on
%% only as an attenuating facet (attenuated/2).
facet(_Name, invalid, _State) ->
    false;
%% Stopgap: console is of no declared interface. TODO.md, Bugs by subsystem, "two facets
%% of no declared interface", declares it and deletes this clause.
facet(console, {ok, Grant}, _State) ->
    local(Grant);
facet(Name, {ok, Grant}, State) ->
    declared(Name, State) andalso attenuated(Name, Grant).

%% Whether Name is in the table of facet names: the manifest's service names, the
%% generated ?ERX_FACET_NAMES unless the service was started with another (start_link/1).
%% The manifest's own facet rows are not looked up here: the build's facet table check
%% (FacetNames) checks them.
declared(Name, #{facet_names := Names}) ->
    lists:member(Name, Names).

%% The console stopgap's grant, whose pid is any process of this node, the system domain's;
%% which process is the caller's to get right, so console could stand in front of
%% any of the system domain's processes (the Phase 1 residual of TODO.md's facets item).
local({Pid, Limits}) ->
    node(Pid) =:= node() andalso {true, {Pid, Limits}}.

%% The attenuating facet of a name of the table, which the service would mint in front
%% of the starter's within the starter's grant record of that name's service
%% (docs/design-domains.md, "Facets", Handing a facet on). The service does not make it
%% (TODO.md's facets item), so a name of the table is refused, whatever the pid. Handing
%% on the starter's own facet instead would pass it on unattenuated, and attenuation alone
%% is not enough either: only the system domain holds a facet of driver control
%% (docs/design-system.md, "The manifest", property 8), so the hand-on must also keep to
%% the manifest's facet rows for the new domain. A system-served facet such as inspect
%% reaches a domain only from the manifest's rows (served/2).
attenuated(_Name, _Grant) ->
    false.

%% {ok, {Pid, Limits}}, or invalid: the limits are those of the grant that differ from
%% erx_facet's defaults, and may name max_request and in_flight, each a positive
%% integer, and nothing else.
grant(Pid) when is_pid(Pid) ->
    grant({Pid, #{}});
grant({Pid, Limits}) when is_pid(Pid), is_map(Limits) ->
    Positive = fun(Key) -> is_integer(map_get(Key, Limits)) andalso map_get(Key, Limits) > 0 end,
    case lists:all(Positive, maps:keys(maps:with([max_request, in_flight], Limits))) andalso
         map_size(maps:without([max_request, in_flight], Limits)) =:= 0 of
        true -> {ok, {Pid, Limits}};
        false -> invalid
    end;
grant(_Grant) ->
    invalid.

%% A session of Principal, made from its session template alone, with its Start checked
%% (session_start/3): the console names the line it starts the session at by the console
%% facet it hands, and a display, if Start names one, is kept in the session's record. The
%% service chooses only the name, the principal's prefix (erx_domain_core:session_prefix/3)
%% and the lowest number no living session holds (erx_domain_core:session_name/3), so a
%% refused start binds no name for good. A principal the manifest's names do not name is
%% refused with no_name, and a name too long for an identifier with bad_identifier, as a
%% request's.
start_session(_Principal, _Start, #{lib := none} = State) ->
    {{error, enotsup}, State};
start_session(Principal, Start, #{templates := Templates, principals := #{system := System, names := Names},
                                  lib := Lib, core := Core} = State) ->
    maybe
        #{Principal := #{template := Template}} ?= Templates,
        {ok, Record} ?= session_start(Template, Start, State),
        {ok, Prefix} ?= erx_domain_core:session_prefix(Principal, System, Names),
        Name = erx_domain_core:session_name(Prefix, Principal, Core),
        Ident = erx_ident:new(Name),
        true ?= Ident =/= {error, bad_identifier},
        Make = fun(Id, Pid) -> Lib:session(Id, Template, Name, Pid) end,
        build(Ident, Principal, {session, Template}, Make, Record, ?BOOT_TIMEOUT, State)
    else
        #{} -> {{error, no_template}, State};
        {error, _} = Refused -> {Refused, State};
        error -> {{error, no_name}, State};
        false -> {{error, bad_identifier}, State}
    end.

%% A session's Start split into what the session's record keeps: its facets, which the
%% funnel checks as a request's (facets/2), the console the only one it lets through; and
%% its start, display or default_display, a service name the session's template is
%% granted (erx_domain_mints:granted/3), one of them at most. display makes the session
%% the display's session, whose grant on it carries the session mark; default_display is
%% kept and not handed on. So a start's display marks only a grant of its template, and
%% adds none. The checks go in order: the facets, then two displays at once, then a
%% display the template is not granted.
session_start(Template, Start, #{mints := Mints} = State) when is_map(Start) ->
    Displays = maps:with(?START_DISPLAYS, Start),
    Granted = maps:filter(fun(_Key, Display) ->
                                  is_atom(Display) andalso erx_domain_mints:granted(Template, Display, Mints)
                          end, Displays),
    case {facets(maps:without(?START_DISPLAYS, Start), State), maps:keys(Displays)} of
        {invalid, _} -> {error, {bad_spec, facets}};
        {_, [_, _]} -> {error, {bad_spec, display}};
        {_, [Key]} when Granted =/= Displays -> {error, {bad_spec, Key}};
        {Facets, _} -> {ok, #{facets => Facets, start => Displays}}
    end;
session_start(_Template, _Start, _State) ->
    {error, {bad_spec, facets}}.

%% A configured row, which has its own boot_timeout_s to report ready in.
start_configured(#{row := Row, name := Name, principal := Principal, boot_timeout_s := Seconds},
                 #{lib := Lib} = State) ->
    case erx_ident:new(Name) of
        {error, bad_identifier} ->
            logger:error("erx_domain: configured row ~b has no identifier for a name", [Row]),
            State;
        Ident ->
            Make = fun(Id, Pid) -> Lib:configured(Id, Row, Pid) end,
            case build(Ident, Principal, {configured, Row}, Make, #{}, Seconds * 1000, State) of
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
%% the one path a report could take: then it is ready at its start. Record is what the
%% domain's record keeps beside the library's answer: its facets, the processes it gets a
%% facet in front of when it reports ready, and a session's start; a domain with no
%% system connection never reports, so it gets no facet.
build(Ident, Principal, Origin, Make, Record, Timeout, #{core := Core} = State) ->
    case erx_domain_core:admit(Ident, Principal, Origin, Core) of
        {error, _} = Error ->
            {Error, State};
        {ok, #{id := Id, node := Node}, Admitted} ->
            Ref = make_ref(),
            Pid = erx_domain_pid:start_link(self(), Id, Node, Ref),
            case made(Make, Id, Pid) of
                {ok, #{connection := Connection} = Created} ->
                    Built = erx_domain_core:built(Id, maps:merge(maps:with([connection, ctl_slots, reader], Created), Record),
                                                Pid, Ref, Admitted),
                    Next = State#{core := Built, links := add_party(Id, Node, Created, State)},
                    Domain = {erx_domain, Id, Node, Pid},
                    case started(Id, Pid, Ref, Created#{node => Node}, Next) of
                        ok when Connection =:= 0 ->
                            Ready = erx_domain_core:ready(Id, none, erx_domain_core:running(Id, Built)),
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
%% through it, then the domain pid's export to it, then its first thread. The side's open
%% answers once the domain's entry is up (erx_connections:open_side/2), so the export,
%% which needs that connection, finds it unless the side has ended since. A domain with
%% no system connection has no side. The domain gets send on its pid, its one way to
%% report ready and answer; its creator, a process of the system domain, which holds every
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

%% Domain Id's ready report, which its domain pid passed on with Ref and with the
%% inspection agent it kept, Inspect, which the domain's record holds for its life
%% (docs/design-live.md, "The runtime agent"): the domain is ready
%% and its create, if any, answered, a session's start only once its namespace is in
%% place (answer_in_place/1). A domain that ended while running, its end having
%% overtaken a report its pid passed on before the pid's own end, reported too, and its
%% create answers ok; a session's start, whose grants the mint core never heard of,
%% answers its end's error (settle/2). A report for a domain that is ready already, or
%% that ended stopping for its boot timeout, changes nothing. A configured domain's
%% report goes to the mint core with the provides it names, at its node, and a session's
%% with its template and the display its start named, if any (marked/1), after the answer
%% to the report, so the answer reaches the domain before any installation the report
%% starts. Only a running domain's report is taken, so the core hears a session's
%% report at most once and before its end (unprovide/3).
ready(Id, Ref, Provides, Inspect, #{core := Core, waiting := Waiting} = State) ->
    case {erx_domain_core:fetch(Id, Core), Waiting} of
        {{ok, #{ref := Ref, state := running, origin := Origin, node := Node, start := Start}}, _} ->
            {Actions, Links} = erx_domain_links:ready(Id, maps:get(links, State)),
            Ready = State#{core := erx_domain_core:ready(Id, Inspect, Core), links := Links},
            Answered = answer_ready(Id, grant_facets(Id, served(Origin, Ready), granted(Origin, Ready), perform(Actions, Ready))),
            case Origin of
                {configured, Row} -> mints({ready, Row, Id, Node, Provides}, Answered);
                {session, Template} -> mints({session_ready, Template, Id, marked(Start)},
                                             keep_web_line(Id, Node, Provides, Answered));
                request -> Answered
            end;
        {_, #{Id := #{ref := Ref, ended := {running, _Info}}}} ->
            answer_ready(Id, State);
        _ ->
            State
    end.

%% The grant a session's ready report marks (erx_domain_mints): the one on the display its
%% start named with display, and none for a default_display, which is kept and not
%% handed on, or for no display at all.
marked(#{display := Display}) -> {display, Display};
marked(#{}) -> none.

%% The answer to domain Id's ready report, its facets by name: its spec's, and Served,
%% its grants of services the system domain serves (served/2). Each is bound to the
%% domain, exported to it and ends with the domain pid (mint/5). A spec's facet and a
%% message service's facet stand in front of the process the spec or the service
%% named (erx_facet:start/3) and end with it too; their callback is erx_domain_facet,
%% or the one system_facet/4 picks for the service. A files service's grant is an
%% erx_fs grant its erx_fs_grants supervisor starts, and ends with that supervisor. The answer
%% goes to the domain pid, which hands it to the domain's agent for init (edit 65). Init
%% waits for it, so every domain that reported is answered, with no facets too. Granted,
%% the names of the facets of configured domains the manifest grants the domain
%% (granted/2), goes with it, so the domain mounts what it is granted before the grants
%% are installed (docs/design-system.md, "Facets a configured domain serves").
grant_facets(Id, Served, Granted, #{core := Core, exports := Exports} = State) ->
    {ok, #{pid := Pid, ref := Ref, facets := Facets, principal := Principal}} = erx_domain_core:fetch(Id, Core),
    Specs = maps:map(fun(_Name, {Behind, Limits}) -> {facet, erx_domain_facet, Behind, Limits#{behind => Behind}} end,
                     Facets),
    Systems = maps:map(fun(Name, Grant) -> system_facet(Name, Grant, Principal, State) end, Served),
    %% A spec never names a service of the table (facet/3), and the manifest grants a
    %% configured domain no spec, so the two never share a name.
    Minted = maps:filtermap(fun(Name, Facet) -> mint(Id, Pid, Name, Facet, Exports) end, maps:merge(Specs, Systems)),
    Pid ! {Ref, facets, Minted, Granted},
    State.

%% The facet of a service the system domain serves, for a domain of Principal: the
%% inspect facet, whose scope erx_domain_core:inspect_scope/3 alone decides
%% (docs/design-live.md, "The inspect service"), an erx_domain_facet in front of the
%% service's process, or, for a files service, the grant its erx_fs_grants supervisor
%% starts (mint/5).
system_facet(inspect, {message, Behind, Limits}, Principal,
             #{inspect_policy := #{roots := Roots, development := Development}}) ->
    {facet, erx_inspect_facet, Behind, Limits#{scope => erx_domain_core:inspect_scope(Principal, Roots, Development)}};
system_facet(_Name, {message, Behind, Limits}, _Principal, _State) ->
    {facet, erx_domain_facet, Behind, Limits#{behind => Behind}};
system_facet(_Name, {files, Grants, Limits}, _Principal, _State) ->
    {files, Grants, Limits}.

%% How the system domain serves its service Name to a grantee: an erx_fs grant for a
%% service of the files interface, whose clients speak 9P (docs/design-system.md,
%% "Facets of the system domain's services"), and a facet in front of the service's
%% process for any other.
served_kind(Name, Files) ->
    case lists:member(Name, Files) of
        true -> files;
        false -> message
    end.

%% A session's line to the web domain, which its ready report names among its provides as
%% web_line, a process of the session's own node (erx_web_line). The service keeps it
%% until the session ends, for erx_domain:web_line/2 to hand to the web domain when the
%% host opens the web facet; it hands the pid to no one before then.
keep_web_line(Id, Node, #{web_line := Line}, #{web_lines := Lines} = State) when is_pid(Line), node(Line) =:= Node ->
    State#{web_lines := Lines#{Id => Line}};
keep_web_line(_Id, _Node, _Provides, State) ->
    State.

mint(Id, DomainPid, Name, {files, Grants, Limits}, Exports) ->
    %% A files service's grant serves the domain alone, in its envelope and with its
    %% names, and ends with its domain pid; its supervisor's end ends it too.
    Binding = #{client => Id, ends_with => DomainPid, exports => Exports},
    case files_grant(Grants, Limits, Binding) of
        {ok, Grant} ->
            {true, Grant};
        {error, Reason} ->
            logger:error("erx_domain: domain ~b's files grant ~ts did not start: ~0P", [Id, Name, Reason, 8]),
            false
    end;
mint(Id, DomainPid, Name, {facet, Callback, Behind, Grant}, Exports) ->
    case erx_facet:start(Callback, Grant#{grantee => Id, ends_with => [DomainPid, Behind]}, #{exports => Exports}) of
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

%% The grant Grants starts, or the refusal; a supervisor that ended while the service
%% minted is a refusal too.
files_grant(Grants, Limits, Binding) ->
    try erx_fs_grants:grant(Grants, Limits, Binding)
    catch exit:Reason -> {error, {exit, Reason}}
    end.

%% The facets of services the system domain serves that the manifest grants a configured
%% domain's row or a session's template, each {Kind, Behind, Limits} by its service's
%% name, and none for a domain a request made: Behind is the process the service
%% named for it with erx_facet:serve/2, which the system domain's services do as they
%% start. For a message service Limits are the grant's limits that erx_facet applies,
%% max_request and in_flight, checked as a spec's are (grant/1); for a files service they
%% are the row's, which erx_fs_grants checks as it starts the grant. A service with no
%% living process, or a grant whose limits fail that check, is left out and logged, so
%% the domain finds the name absent,
%% as it finds any service that is unavailable, until it restarts. Each facet ends with
%% its process, and nothing grants a new one when the service restarts (TODO.md).
served(Origin, #{served := Served}) ->
    served(grantee(Origin), Served, persistent_term:get({erx, serves}, #{})).

%% The names of the facets of configured domains the manifest grants a domain of
%% Origin, its row's or its template's, and no other domain's; none for a domain created
%% on request, which the manifest grants nothing.
granted(Origin, #{mints := Mints}) ->
    case grantee(Origin) of
        none -> [];
        Grantee -> erx_domain_mints:granted_names(Grantee, Mints)
    end.

%% The key of Served an origin's grants are under: its row, or its template's.
grantee({configured, Row}) -> Row;
grantee({session, Template}) -> {template, Template};
grantee(request) -> none.

served(none, _Served, _Servers) ->
    #{};
served(Grantee, Served, Servers) ->
    maps:from_list(lists:filtermap(
                     fun({Name, Kind, Limits}) ->
                             Facet = case Servers of
                                         #{Name := Behind} -> is_process_alive(Behind) andalso
                                                                  served_grant(Kind, Behind, Limits);
                                         #{} -> false
                                     end,
                             case Facet of
                                 {ok, Grant} ->
                                     {true, {Name, Grant}};
                                 _NoFacet ->
                                     %% A manifest name and row: no text a domain wrote.
                                     logger:error("erx_domain: service ~ts of the system domain has no facet for grantee ~0p",
                                                  [Name, Grantee]),
                                     false
                             end
                     end, maps:get(Grantee, Served, []))).

served_grant(message, Behind, Limits) ->
    case grant({Behind, maps:with([max_request, in_flight], Limits)}) of
        {ok, {Behind, Checked}} -> {ok, {message, Behind, Checked}};
        invalid -> invalid
    end;
served_grant(files, Grants, Limits) ->
    {ok, {files, Grants, Limits}}.

%% Domain Id's create answered at its ready report; a session's start waits on for its
%% namespace (answer_in_place/1).
answer_ready(Id, #{waiting := Waiting} = State) ->
    case Waiting of
        #{Id := #{answer_at := ready}} -> answer_ok(Id, State);
        #{} -> State
    end.

answer_ok(Id, #{waiting := Waiting} = State) ->
    {#{from := From, domain := Domain}, Rest} = maps:take(Id, Waiting),
    gen_server:reply(From, {ok, Domain}),
    State#{waiting := Rest}.

%% A create waiting for domain Id: its caller, the domain, its domain pid's secret, that
%% pid until it ends and gone after, the life the domain ended in and its Info once it has
%% ended (ended/3), the refusal to answer once nothing of it remains, none for a domain
%% that was started, and when it is answered ok: at the ready report, or for a session
%% once its namespace is in place after it.
wait_created({erx_domain, Id, _, Pid} = Domain, Refusal, From, #{core := Core, waiting := Waiting} = State) ->
    {ok, #{ref := Ref, origin := Origin}} = erx_domain_core:fetch(Id, Core),
    AnswerAt = case Origin of
                   {session, _Template} -> in_place;
                   _ -> ready
               end,
    Waiter = #{from => From, domain => Domain, ref => Ref, pid => Pid, ended => none, refusal => Refusal,
               answer_at => AnswerAt},
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

%% Answers the create of domain Id, which ended in life Life before it reported ready, or
%% a session that ended before its namespace was in place, with an error, once nothing of
%% the domain is charged but what a survivor still maps (A4 of
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
%% was started ended before it reported, or a session before its namespace was in place.
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
            reply(From, {error, timeout}),
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
             reply(From, Reply)
         end || From := Timer <- Callers],
    false.

%% An introduction's answer: to an introduce/2 caller, or, for one the mint core asked
%% for, {mints, Tag}, to the service itself, which feeds it to the core (mint_act/2).
reply({mints, Tag}, Reply) -> self() ! {mint_introduced, Tag, Reply}, ok;
reply(From, Reply) -> gen_server:reply(From, Reply).

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
            case Answer of
                {erx_facets_installed, Tag} ->
                    mints({installed, Id, Tag}, State);
                %% A mint's reply, which the core takes only from the server its
                %% operation asked, for that operation's tag.
                {erx_facet_minted, Tag, Reply} ->
                    mints({minted, Id, Tag, Reply}, State);
                _ ->
                    {Actions, Next} = erx_domain_links:answer(Id, unwire(Answer), Links),
                    perform(Actions, State#{links := Next})
            end;
        _ ->
            State
    end.

%% The pid passes on only the three connection answers, the installation's
%% acknowledgement and a mint's reply (erx_domain_pid:is_answer/1).
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
            Told = unprovide(Origin, Id, perform(Actions, State#{core := Ended, links := Unlinked})),
            _ = retire(Lib, Id),
            release(restart(Origin, waiter_ended(Id, Life, Info, Told)))
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
restart({session, _Template}, State) ->
    State;
restart({configured, Row}, #{core := Core, configured := Configured} = State) ->
    #{Row := #{restarts := Restarts, restart_period_s := Period} = Entry} = Configured,
    case erx_domain_core:restart(Row, Restarts, Period, erlang:monotonic_time(second), Core) of
        {yes, Next} -> start_configured(Entry, State#{core := Next});
        {no, Next} -> State#{core := Next}
    end.

%% A configured domain's end, which the mint core hears before any restart: every
%% operation of its incarnation is cancelled, and a session waiting for its grant is
%% answered then, before the restart makes the row starting again (docs/design-system.md,
%% "A session takes the console": a session does not wait for a restart). A session's end cancels its grants'
%% operations and deletes the grants.
unprovide({configured, Row}, Id, State) -> mints({ended, Row, Id}, State);
unprovide({session, _Template}, Id, #{web_lines := Lines} = State) ->
    mints({session_ended, Id}, State#{web_lines := maps:remove(Id, Lines)});
unprovide(request, _Id, State) -> State.

%%% The facets configured domains serve (docs/design-system.md, "Facets a configured
%%% domain serves").

%% Event, for erx_domain_mints, and its actions performed in order. An action may feed
%% the core a further event at once (an installation in the system domain's own
%% registry); the core's state is already the step's next, so that event sees it.
mints(Event, #{mints := Mints} = State) ->
    {Actions, Next} = erx_domain_mints:step(Event, Mints),
    answer_in_place(lists:foldl(fun mint_act/2, State#{mints := Next}, Actions)).

%% Each session's start still waiting after its ready report, answered once its
%% namespace is in place (erx_domain_mints:in_place/3). The mint core hears of a session
%% only at its report, so only a ready session's grants are checked: before then it
%% holds none, which would read as in place. A session whose domain pid has died is
%% ending, and its end answers it with an error (settle/2).
%%
%% The system domain's own callers of erx_domain:system_namespace/0 wait in
%% system_waiting by the same rule, for the grants to the system domain: it holds every
%% grant it will have from the boot on, so its grants are checked from the first call.
answer_in_place(#{core := Core, mints := Mints} = State) ->
    Starting = [Row || #{origin := {configured, Row}, state := running} <- erx_domain_core:domains(Core)],
    InPlace = fun(Grantee) -> erx_domain_mints:in_place(Grantee, Starting, Mints) end,
    answer_system(InPlace, answer_sessions(InPlace, State)).

answer_sessions(InPlace, #{waiting := Waiting, core := Core} = State) ->
    Ready = [Id || Id := #{answer_at := in_place, pid := Pid} <- Waiting, Pid =/= gone, is_ready(Id, Core)],
    lists:foldl(fun answer_ok/2, State, [Id || Id <- Ready, InPlace({session, Id})]).

answer_system(_InPlace, #{system_waiting := []} = State) ->
    State;
answer_system(InPlace, #{system_waiting := System} = State) ->
    case InPlace(system) of
        true ->
            lists:foreach(fun(From) -> gen_server:reply(From, ok) end, lists:reverse(System)),
            State#{system_waiting := []};
        false ->
            State
    end.

is_ready(Id, Core) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := ready}} -> true;
        _ -> false
    end.

%% An introduction that settles at once is answered through the service's own queue as
%% one that settles later is (reply/2), so the core takes each in the same way.
mint_act({introduce, Tag, ServerId, GranteeId}, State) ->
    case introduce(ServerId, GranteeId, State) of
        {wait, Next} ->
            wait_introduced(ServerId, GranteeId, {mints, Tag}, Next);
        {Result, Next} ->
            ok = reply({mints, Tag}, Result),
            Next
    end;
mint_act({mint, Tag, Mint, Name, GranteeId, Limits}, #{core := Core, mint_config := #{owner := Owner}} = State) ->
    %% Sent by the server's domain pid, never by the service: a send carries its
    %% sender's pid, which the runtime then exports to the receiving domain, and the
    %% domain pid is the one process of the system domain its domain already holds.
    %% The request names no process to reply to either: the server replies through
    %% that domain pid (erx_facet:minted/2). The core asks only a mint its server's
    %% ready incarnation owns, so Owner(Mint) is that server, and it is ready.
    {ok, #{pid := Pid, ref := Ref}} = erx_domain_core:fetch(Owner(Mint), Core),
    Pid ! {Ref, mint, Mint, {erx_facet_mint, Tag, Name, GranteeId, Limits}},
    State;
mint_act({install, Tag, ?SYSTEM_ID, Name, Facet}, State) ->
    persistent_term:put({erx, facets}, (persistent_term:get({erx, facets}, #{}))#{Name => Facet}),
    mints({installed, ?SYSTEM_ID, Tag}, State);
mint_act({install, Tag, GranteeId, Name, Facet}, #{core := Core} = State) ->
    %% The core installs only in a grantee that is ready and has not ended.
    {ok, #{pid := Pid, ref := Ref}} = erx_domain_core:fetch(GranteeId, Core),
    Pid ! {Ref, install, Tag, Name, Facet},
    State;
mint_act({arm, Tag, Milliseconds}, #{mint_timers := Timers} = State) ->
    State#{mint_timers := Timers#{Tag => erlang:start_timer(Milliseconds, self(), {mint_deadline, Tag})}};
mint_act({disarm, Tag}, #{mint_timers := Timers} = State) ->
    case maps:take(Tag, Timers) of
        {Timer, Rest} ->
            _ = erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
            State#{mint_timers := Rest};
        error ->
            State
    end;
mint_act({failed, {Grantee, Name}, {ServerId, GranteeId}, Reason}, State) ->
    %% One line per operation, so bounded by the restarts of its two domains.
    logger:warning("erx_domain: facet ~ts of domain ~b for ~0p (domain ~b) failed: ~0p",
                   [Name, ServerId, Grantee, GranteeId, Reason]),
    State;
mint_act({Kind, Reason, Detail}, State) when Kind =:= refused; Kind =:= dropped ->
    note(Kind, Reason, Detail, State).

%% A refusal or a dropped message, counted by its kind and reason, and logged unless
%% throttle/2 holds the line back. Detail holds only atoms and the service's own
%% numbers, which the core chose, so nothing a domain wrote reaches the log.
note(Kind, Reason, Detail, #{mint_counts := Counts, mint_log := Log} = State) ->
    Key = {Kind, Reason},
    Counted = State#{mint_counts := Counts#{Key => maps:get(Key, Counts, 0) + 1}},
    {Verdict, Next} = throttle(erlang:monotonic_time(millisecond), Log),
    case Verdict of
        quiet -> ok;
        log -> logger:notice("erx_domain: facet mint ~ts ~ts: ~0p", [Kind, Reason, Detail]);
        {log, Held} ->
            logger:notice("erx_domain: ~b facet mint log lines held back", [Held]),
            logger:notice("erx_domain: facet mint ~ts ~ts: ~0p", [Kind, Reason, Detail])
    end,
    Counted#{mint_log := Next}.

%% Whether a line logged at Now passes the rate limit, Log being {Start, Lines, Held}:
%% the window that opened at Start, the lines logged in it and the lines held back.
%% A line in a window with room is logged; past ?MINT_LOG_BURST it is held back; the
%% first line of a new window is logged with the number held back in the last.
throttle(Now, {Start, _Lines, Held}) when Now - Start >= ?MINT_LOG_WINDOW ->
    {case Held of 0 -> log; _ -> {log, Held} end, {Now, 1, 0}};
throttle(_Now, {Start, Lines, Held}) when Lines < ?MINT_LOG_BURST ->
    {log, {Start, Lines + 1, Held}};
throttle(_Now, {Start, Lines, Held}) ->
    {quiet, {Start, Lines, Held + 1}}.
