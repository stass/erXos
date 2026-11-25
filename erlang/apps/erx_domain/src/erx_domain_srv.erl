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

The boot holds the configured rows the device service names
(erx_devices:held_at_boot/1) until it casts erx_domain:release_held/0, or
until the fallback it names has passed since that server settled
(handle_continue/2; docs/design-system.md, "Waiting for a grant", "The rows
held at boot"); a held row counts as starting. The service names no PCIe
concept: it forwards every end with its origin (erx_devices:domain_ended/2)
and keeps the fallback's one timer.

A create or a session's start for a principal one of whose domains is
ending, its domain pid gone but its end not yet arrived, is held until that
end has retired the domain and answered then (start/3): the library still
counts such a domain against the principal's domain quota, while its pid's
end has already told the caller it is gone, so a login started again on a
killed session's end would otherwise be refused. The hold is bounded by
release_wait, after which the library answers the start as it stands.

A session's or an app's start is held, too, while the system release boots,
and runs once init reports the boot started (after_boot/3): the
services of the system domain a session is granted are those named by its
ready report (served/3), and an application started after the domain service,
as the start service is, names its own only as it starts. No application's
start waits on a session's, so the hold ends with the boot.

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
session's template, and the code_objects facet the service grants every
session by its own policy (code_objects_row/0), go in the domain's ready
answer, each in front of the
process its service named with erx_facet:serve/2 (served/2); the inspect
facet with the scope erx_domain_core:inspect_scope/3 gives the domain's
principal (system_facet/4); and for a service of an interface abi/services
declares served_as tree (?ERX_TREE_SERVICES), an
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
boot's step 5). erx_domain:server_settled/1 is answered ok once no starting
configured row serves the service it names, which the start table waits on
before it starts a row that names a display. erx_domain:await_grant/2 is
answered once the system domain's grant of the service it names has settled
for the incarnation it names, which the device service waits on before it
answers a PCIe domain's report (docs/design-pcie.md, "Facets"). These three
are the settlement wait (docs/design-system.md, "Waiting for a grant"): each
is a query, {settled, Query}, its caller waits in one list, settling, and each
is answered once erx_domain_mints:settled/3 no longer answers wait, checked at
every call of answer_in_place/1, so after each step of the mint core, each
stop for a boot timeout and the release of the rows held at boot, and at an
end before the ended row's successor starts (ended/4).

A session's ready report names its lines among its provides, each under a
name of the closed set ?ERX_LINES: its line to the web domain, web_line, and to
the SSH domain, tty_line. The mint core keeps them with the session's grants,
and erx_domain:line/4 is one line operation of the core, answered by the core
(docs/design-system.md, "A session's lines"): the session mints the line's
facet for the peer the system domain names, and no pid of a line process
leaves the service.

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
%% The boot timeout the service starts with, in milliseconds: the manifest's default
%% (abi/manifest.txt). booted/1 replaces it with the machine's, and it stays only when
%% the library cannot answer configured/0.
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
%% A domain that has not ended, whose domain pid stands for it (erx_domain_core:ended/5).
-define(IS_LIVE(Life), (Life =:= built orelse Life =:= running orelse Life =:= ready orelse Life =:= stopping)).

start_link() ->
    start_link(#{}).

-doc """
Opts names a host test's stand-ins: lib, the domain library's module
(erx_domain_lib by default); agent, the connection agent's (erx_connections);
exports, the export table's (erx_dist); introduce_timeout, an introduce/2
caller's deadline in milliseconds; release_wait, a held start's bound
(start/3); device_service, the device service's module (erx_devices), whose held_at_boot/1 and
domain_ended/2 the service calls; mints, the owner function (erx_dist:owner/1 by default) and
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
    %% The code_objects service is the domain service's own (code_objects_row/0). The
    %% PCIe services' facets stand in front of the service too, which outlives the device
    %% service's PCIe process their callbacks find at each request (erx_pci_facet).
    ok = erx_facet:serve(code_objects, self()),
    ok = erx_facet:serve(pci_bus, self()),
    ok = erx_facet:serve(pci, self()),
    ok = watch_release(),
    case principals(Lib, Opts) of
        {ok, Principals} ->
            State = state(Lib, Principals, Opts),
            ok = become_installer(State),
            {ok, booted(State), {continue, boot}};
        {error, Reason} ->
            logger:error("erx_domain_srv: cannot read the principals of the system manifest "
                         "(/manifest), which the domain library booted from: ~0p", [Reason]),
            {stop, {system_manifest, Reason}}
    end.

%% The service makes itself the system domain's agent's installer, the one process whose
%% installations the agent takes (erx_connections:become_installer/0), before it grants
%% anything. Where the runtime is no node no agent runs, and the system domain is granted
%% nothing (mint_act/2). A refusal, another process having claimed first, ends the start,
%% and with it the system domain, since the service is never restarted.
become_installer(#{agent := Agent}) ->
    case Agent:become_installer() of
        ok -> ok;
        {error, noproc} -> ok;
        {error, badarg} -> error({connection_agent, installer_claimed})
    end.

%% The service's state as it starts, with Lib its library and Principals the manifest's.
state(Lib, Principals, Opts) ->
    Agent = maps:get(agent, Opts, erx_connections),
    Exports = maps:get(exports, Opts, erx_dist),
    AppEntries = app_entries(Lib),
    %% Whether the runtime is a node, as kernel's start left it, since net_kernel starts
    %% before any application and lives as long as the runtime (close_side/4). Waiting
    %% holds, by domain id, each create or session's start not yet answered (wait_created/4),
    %% and settling, in arrival order, each settlement query not yet answered, with its
    %% caller (answer_settling/2). Bonds holds, by monitor, each process a session's start
    %% named in ends_with, with the held start or the session its end ends (bond/3).
    %% Introducing holds, by the pair's key, each introduce/2 caller, or {mints, Tag} for the mint core (reply/2), waiting for its
    %% connection to come up, with the timer of its deadline (settle_introductions/1).
    %% Held holds, by principal and in arrival order, each start waiting for the
    %% principal's ending domains to be retired, with the timer of its bound (start/3).
    %% Boot_held is the configured rows the device service holds at boot, in boot order,
    %% until they are released, and fallback the release's own bound (fallback/1), none
    %% once armed or released (handle_continue/2).
    %% Mints is erx_domain_mints' state, its pending operations' deadlines by tag in
    %% mint_timers, and mint_counts and mint_log what was refused or dropped (note/4).
    %% Served holds, by configured row, the facets of services the system domain serves
    %% that the manifest grants the row, each its service's name, its kind (served_kind/2)
    %% and the grant's limits; a session's are its own facet rows and its code_objects facet
    %% (served/3).
    %% Apps is the boot's registry of app principals (erx_principal), of the apps row's
    %% max entries, as the library placed them (app_entries/1, the library's apps/0).
    %% Facet_rows holds every facet row of the manifest by its index in the facet table,
    %% from which each session's rows are decided once, as it is planned (session_rows/2).
    %% Boot_timeout is the machine's boot timeout in milliseconds, which bounds every
    %% domain's wait for its init's ready report unless its request sets its own.
    %% Release is the system release's boot (watch_release/0): booting, with each
    %% session's or app's start that came early, newest first, or booted.
    MintConfig = maps:merge(#{owner => fun erx_dist:owner/1}, maps:with([owner, deadline], maps:get(mints, Opts, #{}))),
    #{lib => Lib, agent => Agent, exports => Exports, node => erlang:is_alive(), core => undefined,
      boot_timeout => ?BOOT_TIMEOUT, release => {booting, []},
      configured => #{}, templates => #{}, waiting => #{}, settling => [], bonds => #{},
      links => erx_domain_links:new(),
      introducing => #{}, introduce_timeout => maps:get(introduce_timeout, Opts, ?INTRODUCE_TIMEOUT),
      held => #{}, release_wait => maps:get(release_wait, Opts, ?RELEASE_WAIT),
      device_service => maps:get(device_service, Opts, erx_devices), boot_held => [], fallback => none,
      mint_config => MintConfig, mints => erx_domain_mints:new(MintConfig#{services => [], grants => []}),
      mint_timers => #{}, mint_counts => #{}, mint_log => {erlang:monotonic_time(millisecond), 0, 0},
      served => #{},
      facet_names => maps:get(facet_names, Opts, ?ERX_FACET_NAMES),
      inspect_policy => inspect_policy(Opts), principals => Principals,
      facet_rows => [], trees => [], interfaces => #{}, app_entries => AppEntries,
      apps => erx_principal:new(apps_max(AppEntries))}.

%% The app entries the library placed at boot (erx_domain_lib:apps/0), none with no
%% library or no apps row.
app_entries(none) ->
    none;
app_entries(Lib) ->
    {ok, Entries} = Lib:apps(),
    Entries.

%% The registry's bound: the apps row's max, as many app entries as the library placed
%% at boot, the one source of max, so the registry never names an entry the library does
%% not hold; 0 with no library or no apps row, under which nothing registers.
apps_max(#{max := Max}) -> Max;
apps_max(none) -> 0.

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
%% the service takes a call, but for the rows the device service holds (held_at_boot/3).
handle_continue(boot, #{lib := Lib, device_service := Devices, configured := Configured} = State) ->
    Ordered = lists:sort(fun(#{place := A}, #{place := B}) -> A =< B end, maps:values(Configured)),
    {Held, Fallback} = held_at_boot(Lib, Devices, [Row || #{row := Row} <- Ordered]),
    {BootHeld, Free} = lists:partition(fun(#{row := Row}) -> lists:member(Row, Held) end, Ordered),
    Holding = State#{boot_held := BootHeld, fallback := fallback(Fallback)},
    {noreply, answer_in_place(lists:foldl(fun start_configured/2, Holding, Free))}.

%% The rows held at boot among Rows, in boot order, and the fallback beside them, as the
%% device service answers (docs/design-system.md, "Waiting for a grant", "The rows held
%% at boot"); a runtime with no library has no device to wait for, and a call that fails
%% holds nothing.
held_at_boot(none, _Devices, _Rows) ->
    {[], none};
held_at_boot(_Lib, Devices, Rows) ->
    case Devices:held_at_boot(Rows) of
        {ok, Held, Fallback} -> {Held, Fallback};
        {error, Reason} ->
            logger:error("erx_domain: the device service did not say which rows wait at boot, so none is held: ~0p",
                         [Reason]),
            {[], none}
    end.

%% The fallback as the service keeps it: {until_settled, Query, Ms}, the settlement query
%% of its server and the milliseconds after which it releases the rows, until it is
%% armed; none once armed, released, or when nothing is held. A server with no atom is
%% no service and has settled, as settling_query/1 answers it, so its timer is armed now.
fallback({settled, Name, Ms}) ->
    case settling_query({server, Name}) of
        {ask, Query} -> {until_settled, Query, Ms};
        {answer, ok} -> armed(Ms)
    end;
fallback(none) ->
    none.

%% The fallback's one timer, armed the first time the settlement wait finds its server
%% settled (answer_in_place/1); nothing re-arms or extends it, and a release disarms
%% none, since its end then finds nothing held.
arm_fallback(Starting, #{fallback := {until_settled, Query, Ms}, mints := Mints} = State) ->
    case erx_domain_mints:settled(Query, Starting, Mints) of
        wait -> State;
        _Settled -> State#{fallback := armed(Ms)}
    end;
arm_fallback(_Starting, #{fallback := none} = State) ->
    State.

armed(Ms) ->
    _ = erlang:start_timer(Ms, self(), release_held),
    none.

%% The release of the rows held at boot: each starts, in boot order, and a release with
%% nothing held changes nothing. A held row counted as starting, so the waits are checked
%% again for any whose start was refused and left it starting no longer.
release_held(#{boot_held := []} = State) ->
    State;
release_held(#{boot_held := Held} = State) ->
    answer_in_place(lists:foldl(fun start_configured/2, State#{boot_held := [], fallback := none}, Held)).

%% The service's state once it has read from its library the manifest's configured
%% domains, session templates, services and facet rows. It runs in init/1, so that what
%% follows from the manifest is in place when start_link returns, the system domain's own
%% /data mount among it: the applications the release starts after erx_domain read /data
%% at once (erx_starter reads rc.conf there) and never call the service first. A library
%% that cannot say leaves no configured domain, no grant and an empty host.
booted(#{lib := Lib} = State) ->
    case {configured(Lib), templates(Lib)} of
        {{ok, #{host := Host, boot_timeout_s := Seconds, domains := Rows} = Boot}, {ok, Templates}} ->
            Configured = maps:from_list([{Row, Entry} || #{row := Row} = Entry <- Rows]),
            %% The manifest's service rows of configured domains and its facet rows,
            %% which the manifest check has proved consistent: a configured domain's
            %% service, and a grant to a session template's sessions, which only a
            %% configured domain serves, go to the mint core, the system domain's
            %% to the ready answers.
            {System, Minted} = lists:partition(fun({_Grantee, _Name, Server, _Limits}) -> Server =:= system end,
                                               maps:get(grants, Boot, [])),
            %% erx_domain_mints takes each configured domain's service as {Server,
            %% Name}; the interface number tells files services, of the files or the
            %% media interface, whose grants a namespace mounts and the mint core
            %% settles before a session's start answers. The services of interfaces
            %% abi/services declares served_as tree, ?ERX_TREE_SERVICES, are those the
            %% system domain serves as erx_fs grants (served_kind/2).
            Services = [{Server, Name} || {Server, Name, _Interface} <- maps:get(services, Boot, []), Server =/= system],
            Files = [Name || {_Server, Name, Interface} <- maps:get(services, Boot, []),
                             Interface =:= ?ERX_SERVICE_FILES orelse Interface =:= ?ERX_SERVICE_MEDIA],
            Windows = [Name || {_Server, Name, ?ERX_SERVICE_WINDOWS} <- maps:get(services, Boot, [])],
            Inputs = [Name || {_Server, Name, ?ERX_SERVICE_INPUT} <- maps:get(services, Boot, [])],
            Trees = [Name || {_Server, Name, Interface} <- maps:get(services, Boot, []),
                             lists:member(Interface, ?ERX_TREE_SERVICES)],
            %% Each drive window is a grant from the row whose placed devices carry it
            %% to the window row's holder (docs/design-drives.md, "How the grant
            %% reaches the media domain"): {ServingRow, Holder, N}, both of the
            %% window the manifest's.
            Drives = [{Serving, Holder, N} || #{row := Serving, drives := Ds} <- Rows, {N, Holder} <- Ds],
            Interfaces = maps:from_list([{{Server, Name}, Interface}
                                         || {Server, Name, Interface} <- maps:get(services, Boot, [])]),
            Mints = erx_domain_mints:new((maps:get(mint_config, State))#{services => Services,
                                           grants => Minted, files => Files, windows => Windows,
                                           inputs => Inputs, interfaces => Interfaces, drives => Drives}),
            %% Only configured rows, each its index, read Served: a {template, T}
            %% grant reaches each session through the session's own facet rows, and
            %% a grant to the system domain is planned by no ready answer.
            Served = maps:groups_from_list(fun({Row, _, _, _}) -> Row end,
                                           fun({_, Name, _, Limits}) -> {Name, served_kind(Name, Trees), Limits} end,
                                           [Grant || {Row, _, _, _} = Grant <- System, is_integer(Row)]),
            %% The system domain's own facets of configured domains: /data only where the
            %% manifest grants the system domain data (docs/design-files.md, "A facet's
            %% mount"), and the installed packages at their system place, /packages.
            Granted = erx_domain_mints:granted_names(system, Mints),
            ok = erx_ns:mount_facets(Granted),
            ok = mount_packages(Granted),
            State#{core := erx_domain_core:new(Host), boot_timeout := Seconds * 1000, configured := Configured,
                   mints := Mints, served := Served,
                   facet_rows := lists:enumerate(0, maps:get(grants, Boot, [])), trees := Trees,
                   interfaces := Interfaces,
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
    case bond(Start, From, State) of
        {ok, Bonded, Next} -> {noreply, after_boot({start_session, Principal, Bonded}, From, Next)};
        {error, _} = Refused -> {reply, Refused, State}
    end;
handle_call({start_app, Name, Start}, From, State) ->
    {noreply, after_boot({start_app, Name, Start}, From, State)};
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
handle_call({settled, Asked}, From, #{settling := Settling} = State) ->
    case settling_query(Asked) of
        {ask, Query} -> {noreply, answer_in_place(State#{settling := Settling ++ [{Query, From}]})};
        {answer, Reply} -> {reply, Reply, State}
    end;
handle_call({register_app, Package}, _From, #{apps := Apps} = State) ->
    case erx_principal:register(Package, Apps) of
        {ok, Registered} -> {reply, ok, State#{apps := Registered}};
        {error, _} = Refused -> {reply, Refused, State}
    end;
handle_call(app_registry, _From, #{apps := Apps} = State) ->
    {reply, erx_principal:registry(Apps), State};
handle_call(system_principal, _From, #{principals := #{system := System}} = State) ->
    Reply = case System of
                none -> {error, enotsup};
                _ -> {ok, System}
            end,
    {reply, Reply, State};
%% A line operation (erx_domain:line/4), answered by the mint core's {answer, From,
%% Reply} action (mint_act/2).
handle_call({line, Name, Session, Peer, Opening}, From, State) ->
    {noreply, mints({line, From, Name, Session, Peer, Opening}, State)};
handle_call({inspect_view, Scope}, _From, #{core := Core} = State)
  when Scope =:= all; is_tuple(Scope), tuple_size(Scope) =:= 2, element(1, Scope) =:= principal ->
    {reply, erx_domain_core:inspect_view(Scope, Core), State};
handle_call(mints, _From, #{mints := Mints, mint_counts := Counts} = State) ->
    %% Each grant's state, configured and per session, and how many of each refusal and drop were counted.
    {reply, #{grants => erx_domain_mints:grants(Mints), counts => Counts}, State};
%% A session's code objects, which its code_objects facet forwards with the session it was
%% minted for (erx_code_objects_facet): the library answers, and refuses a number that is
%% not that session's.
handle_call({code_object, Session, Size}, _From, #{lib := Lib} = State) ->
    {reply, Lib:code_object(Session, Size), State};
handle_call({code_drop, Session, Number}, _From, #{lib := Lib} = State) ->
    {reply, Lib:code_drop(Session, Number), State};
handle_call(_Request, _From, State) ->
    {reply, {error, badarg}, State}.

%% Tells the service release_booted (handle_info/2) once the system release's boot has
%% ended, after its last application has started: at once after the boot, and else
%% when init says so. A helper waits for init, so no {init, started} sits in the
%% service's own mailbox, where an init request of the service would take it.
watch_release() ->
    Service = self(),
    _ = spawn(fun() ->
                      ok = case init:notify_when_started(self()) of
                               started -> ok;
                               ok -> init:wait_until_started()
                           end,
                      Service ! release_booted
              end),
    ok.

%% A session's or an app's start from From: held while the system release's boot runs,
%% and run (start/3) once it has ended, so the domain service grants a session the
%% services of the system domain (served/3) only after every application of the
%% release has named its own (erx_facet:serve/2), whatever their order. A create is
%% not held: the manifest grants a domain created on request nothing (served/3).
after_boot(Start, From, #{release := {booting, Early}} = State) ->
    State#{release := {booting, [{Start, From} | Early]}};
after_boot(Start, From, #{release := booted} = State) ->
    start(Start, From, State).

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
principal({start_session, Principal, _Start}, _State) -> Principal;
principal({start_app, Name, _Start}, State) ->
    case app_plan(Name, State) of
        {ok, #{principal := Principal}} -> Principal;
        error -> none
    end.

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
run({start_session, Principal, #{ends_with := Ends} = Start}, From, State) ->
    Monitors = [Monitor || {Monitor, _Pid} <- Ends],
    case bond_state(Ends, State) of
        answered ->
            State;
        ended ->
            gen_server:reply(From, {error, ended}),
            unbond(Monitors, State);
        live ->
            answer_create(bound(Monitors, start_session(Principal, maps:remove(ends_with, Start), State)), From)
    end;
run({start_app, Name, Start}, From, State) ->
    answer_create(start_app(Name, Start, State), From).

%% A session's start bonded to what it ends with (docs/design-domains.md, "Principals,
%% sessions and quotas"): each process its ends_with names is monitored here, as the
%% service admits the start and before the start is held or its domain made, and Start
%% keeps each monitor beside its process. Bonds holds each monitor with what its 'DOWN'
%% ends: {start, From} while the start waits, then {session, Id} once its domain is made
%% (bound/2), until the session's end arrives (unbond_session/2). So no moment passes,
%% from the admission to the session's end, in which nothing watches what the session
%% ends with, whatever becomes of the start's caller. A start that names none is bonded
%% to nothing.
bond(Start, From, #{bonds := Bonds} = State) ->
    Pids = maps:get(ends_with, Start, []),
    case pids(Pids) of
        true ->
            Ends = [{monitor(process, Pid), Pid} || Pid <- Pids],
            Holders = maps:from_list([{Monitor, {start, From}} || {Monitor, _Pid} <- Ends]),
            {ok, Start#{ends_with => Ends}, State#{bonds := maps:merge(Bonds, Holders)}};
        false ->
            {error, {bad_spec, ends_with}}
    end.

%% Whether Term is a proper list of pids.
pids([Pid | Rest]) when is_pid(Pid) -> pids(Rest);
pids([]) -> true;
pids(_Term) -> false.

%% Where a start about to run stands with what it ends with: answered, when one of its
%% bonds ended while it was held (bond_ended/2); ended, when a process of this node it
%% names has ended though its 'DOWN' is not yet taken, so it is refused before its domain
%% is made, as a facet's start is (erx_facet); live else. A process of another domain is
%% learnt of only by its 'DOWN', which then stops the session the start made.
bond_state(Ends, #{bonds := Bonds}) ->
    case {[M || {M, _} <- Ends, not is_map_key(M, Bonds)], [P || {_, P} <- Ends, ended(P)]} of
        {[_ | _], _} -> answered;
        {[], [_ | _]} -> ended;
        {[], []} -> live
    end.

ended(Pid) -> node(Pid) =:= node() andalso not is_process_alive(Pid).

%% A start's bonds once it has run: the session's, if its domain was made, and none if it
%% was refused before.
bound(Monitors, {{error, _} = Error, Next}) ->
    {Error, unbond(Monitors, Next)};
bound(Monitors, {{waiting, Domain}, Next} = Built) -> rebound(Monitors, Domain, Built, Next);
bound(Monitors, {{ready, Domain}, Next} = Built) -> rebound(Monitors, Domain, Built, Next);
bound(Monitors, {{refused, Domain, _Refusal}, Next} = Built) -> rebound(Monitors, Domain, Built, Next).

rebound(Monitors, {erx_domain, Id, _, _}, {Answer, _}, #{bonds := Bonds} = Next) ->
    {Answer, Next#{bonds := maps:merge(Bonds, maps:from_keys(Monitors, {session, Id}))}}.

%% One of a start's or a session's ends_with has ended: a held start is answered ended,
%% and a session is stopped, its start answered ended if it is still waiting
%% (settle/2). Either way the bond's other monitors go.
bond_ended(Monitor, #{bonds := Bonds} = State) ->
    Holder = maps:get(Monitor, Bonds),
    Next = unbond([M || M := H <- Bonds, H =:= Holder], State),
    case Holder of
        {start, From} ->
            gen_server:reply(From, {error, ended}),
            Next;
        {session, Id} ->
            stop_bonded(Id, Next)
    end.

%% A waiting start is answered ended once its domain has ended (settle/2); if the library
%% refuses the stop, no end will come, so it is answered now, as build/7 answers a refused
%% stop, and the running domain is the refused stop's, logged by stop/2.
stop_bonded(Id, #{core := Core, waiting := Waiting} = State) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := Life}} when ?IS_LIVE(Life) ->
            case {stop(Id, State), Waiting} of
                {ok, #{Id := #{refusal := none} = Waiter}} ->
                    State#{waiting := Waiting#{Id := Waiter#{refusal := {error, ended}}}};
                {refused, #{Id := #{from := From}}} ->
                    gen_server:reply(From, {error, ended}),
                    State#{waiting := maps:remove(Id, Waiting)};
                _ ->
                    State
            end;
        _ ->
            State
    end.

%% Takes the bonds of Monitors away, with any 'DOWN' of theirs already queued.
unbond(Monitors, #{bonds := Bonds} = State) ->
    _ = [demonitor(Monitor, [flush]) || Monitor <- Monitors],
    State#{bonds := maps:without(Monitors, Bonds)}.

%% The bonds of session Id, which has ended, go with it.
unbond_session(Id, #{bonds := Bonds} = State) ->
    unbond([M || M := {session, I} <- Bonds, I =:= Id], State).

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

handle_cast(release_held, State) ->
    {noreply, release_held(State)};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({domain_ended, Id, End, Record}, #{device_service := Devices, core := Core} = State) ->
    %% The device service lowers the PCIe functions the domain held (docs/design-pcie.md,
    %% "A holder's end") and, at a PCIe row's end, releases the rows held at boot; it
    %% learns of the end, with the origin read before ended/4 retires the domain, before
    %% the service starts the domain's next incarnation below, which may hold them again.
    Origin = case erx_domain_core:fetch(Id, Core) of
                 {ok, #{origin := Known}} -> Known;
                 _ -> none
             end,
    ok = Devices:domain_ended(Id, Origin),
    {noreply, ended(Id, End, erx_domain_core:fault_where(End, Record), unbond_session(Id, State))};
handle_info({domain_ready, Ref, Id, Provides, Inspect}, State) ->
    {noreply, ready(Id, Ref, provided_atoms(Provides), Inspect, State)};
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
handle_info({timeout, _Timer, release_held}, State) ->
    {noreply, release_held(State)};
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
handle_info({system_side_ended, Id, Reason}, #{core := Core} = State) ->
    %% The agent's report that a side it opened for this service ended before the service
    %% closed it: this runtime ended the connection, for a malformed frame, a peer bound
    %% passed or its owner's end, so the domain goes (docs/design-system.md, "A lost
    %% system connection ends the domain"), and the log names why by the leading atom of
    %% the port's exit reason. Ids are never reused, so a late report for an ended domain
    %% finds no record.
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := Life}} when ?IS_LIVE(Life) ->
            logger:notice("erx_domain: domain ~b's system side ended, ~s; stopping the domain",
                          [Id, erx_report:reason_name(Reason)]),
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
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, #{bonds := Bonds} = State) when is_map_key(Monitor, Bonds) ->
    %% A process a session's start named in ends_with has ended, by any reason: noproc
    %% for one that had ended before the monitor, noconnection for one whose domain ended.
    {noreply, bond_ended(Monitor, State)};
handle_info(release_booted, #{release := {booting, Early}} = State) ->
    {noreply, lists:foldl(fun({Start, From}, Next) -> start(Start, From, Next) end,
                          State#{release := booted}, lists:reverse(Early))};
handle_info(_Message, State) ->
    {noreply, State}.

%% A request: its name and fields checked, then built as a configured row is. Its boot
%% names the domain release's boot script, bin/<boot>.boot, which the service binds
%% with -boot /bin/<boot> as init's first flag (boot_args/2), as the manifest's packer
%% does for a configured row and a session template (docs/design-fiasco.md, "The
%% production image"), so args that name -boot are refused. Its facets
%% name the system domain's grants, by facet name, each with its limits or none, which
%% facets/2 checks; the domain gets a facet in front of each once it reports ready
%% (grant_facets/3), and the library never sees them.
create(_Spec, #{lib := none} = State) ->
    {{error, enotsup}, State};
create(#{name := Name} = Spec, #{boot_timeout := Default} = State) ->
    Timeout = maps:get(boot_timeout, Spec, Default),
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
%% outside the table as a stopgap, a literal here; the
%% spec hands it on with a process of the system domain, live or dead, as its pid (local/1).
%% Every other name must be in the table of facet names (declared/2) and is handed on
%% only as an attenuating facet (attenuated/2).
facet(_Name, invalid, _State) ->
    false;
%% Stopgap: console, of the console interface (facet_interface/2), is handed on with the
%% system domain's process unattenuated, not as a facet of its table's name.
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
%% reaches a domain only from the manifest's rows, or as code_objects from the domain
%% service's own policy (served/3).
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
%% facet it hands, and a display, if Start names one, is kept in the session's record and
%% is the session's default display, its `display` variable, which the library sets when
%% it plans the session (docs/design-apps.md, "Starting a session", step 1). The
%% service chooses only the name, the principal's prefix (erx_domain_core:session_prefix/3)
%% and the lowest number no living session holds (erx_domain_core:session_name/3), so a
%% refused start binds no name for good. A principal the manifest's names do not name is
%% refused with no_name, and a name too long for an identifier with bad_identifier, as a
%% request's.
start_session(_Principal, _Start, #{lib := none} = State) ->
    {{error, enotsup}, State};
start_session(Principal, Start, #{templates := Templates, principals := #{system := System, names := Names},
                                  lib := Lib, core := Core, boot_timeout := Timeout} = State) ->
    maybe
        #{Principal := #{template := Template}} ?= Templates,
        Rows = session_rows(Template, State),
        {ok, #{start := Displays} = Record} ?= session_start(Rows, Start, State),
        {ok, Prefix} ?= erx_domain_core:session_prefix(Principal, System, Names),
        Name = erx_domain_core:session_name(Prefix, Principal, Core),
        Ident = erx_ident:new(Name),
        true ?= Ident =/= {error, bad_identifier},
        Display = default_display(Displays),
        Make = fun(Id, Pid) -> Lib:session(Id, Template, Name, Display, Pid) end,
        build(Ident, Principal, {session, Template}, Make, Record#{rows => Rows, app => none}, Timeout, State)
    else
        #{} -> {{error, no_template}, State};
        {error, _} = Refused -> {Refused, State};
        error -> {{error, no_name}, State};
        false -> {{error, bad_identifier}, State}
    end.

%% The rows of a session of template Template: every facet row granted to the template,
%% each {Name, Server, Limits}, Server a configured row or system. Decided once, as the
%% session is planned, and kept in its record, from which its ready answer and its mints
%% take them (ready/5), so nothing later looks its grants up by template.
session_rows(Template, #{facet_rows := Rows}) ->
    [{Name, Server, Limits} || {_Index, {{template, T}, Name, Server, Limits}} <- Rows, T =:= Template].

%% A session of the app Name (docs/design-packaging.md, "An app's session"), made as any
%% session is, from its plan (erx_domain_core:app_session/4): the library plans the app
%% template under the app's entry with the record's memory, the session's rows are the
%% template's packages row and the rows its admission kept, and its record carries the
%% app's record, sent after its ready answer, once its namespace is in place
%% (answer_sessions/2). Only the start service's keepers start one (PK7, erx_domain:start_app/2).
start_app(_Name, _Start, #{lib := none} = State) ->
    {{error, enotsup}, State};
start_app(Name, Start, #{lib := Lib, core := Core, boot_timeout := Timeout} = State) ->
    maybe
        {ok, #{entry := Entry, principal := Principal, prefix := Prefix, memory := Memory, rows := Rows,
               app := App}} ?= app_plan(Name, State),
        {ok, #{start := Displays} = Record} ?= session_start(Rows, Start, State),
        SessionName = erx_domain_core:session_name(Prefix, Principal, Core),
        Ident = erx_ident:new(SessionName),
        true ?= Ident =/= {error, bad_identifier},
        Display = default_display(Displays),
        Make = fun(Id, Pid) -> Lib:app_session(Id, Entry, Memory, SessionName, Display, Pid) end,
        #{app_entries := #{template := Template}} = State,
        build(Ident, Principal, {session, Template}, Make, Record#{rows => Rows, app => App}, Timeout, State)
    else
        error -> {{error, no_app}, State};
        {error, _} = Refused -> {Refused, State};
        false -> {{error, bad_identifier}, State}
    end.

%% The plan of a session of the app Name from its registry record, with the app's record
%% the registration kept beside it, or error for a name not registered in this boot.
app_plan(Name, #{apps := Apps, app_entries := #{template := Template} = Entries, facet_rows := Rows}) ->
    maybe
        {ok, #{app := App} = Record} ?= erx_principal:app(Name, Apps),
        TemplateRows = [{Index, {N, Server, Limits}}
                        || {Index, {{template, T}, N, Server, Limits}} <- Rows, T =:= Template],
        {ok, (erx_domain_core:app_session(Name, Record, Entries, TemplateRows))#{app => App}}
    end;
app_plan(_Name, #{app_entries := none}) ->
    error.

%% A session's Start split into what the session's record keeps: its facets, which the
%% funnel checks as a request's (facets/2), the console the only one it lets through; and
%% its start, display or default_display, a display among the session's Rows
%% (erx_domain_mints:granted/3), one of them at most. Either is the session's default
%% display (default_display/1); display also makes the session the display's session,
%% whose grant on it carries the session mark. So a start's display marks only a grant
%% the session holds, and adds none. The checks go in order: the facets, then two
%% displays at once, then a display the session does not hold.
session_start(Rows, Start, #{mints := Mints} = State) when is_map(Start) ->
    Displays = maps:with(?START_DISPLAYS, Start),
    Granted = maps:filter(fun(_Key, Display) ->
                                  is_atom(Display) andalso erx_domain_mints:granted(Rows, Display, Mints)
                          end, Displays),
    case {facets(maps:without(?START_DISPLAYS, Start), State), maps:keys(Displays)} of
        {invalid, _} -> {error, {bad_spec, facets}};
        {_, [_, _]} -> {error, {bad_spec, display}};
        {_, [Key]} when Granted =/= Displays -> {error, {bad_spec, Key}};
        {Facets, _} -> {ok, #{facets => Facets, start => Displays}}
    end;
session_start(_Rows, _Start, _State) ->
    {error, {bad_spec, facets}}.

%% The default display a session's checked start names, or none: a console login's start
%% names none (docs/design-display.md, "Choosing a display").
default_display(#{display := Display}) -> Display;
default_display(#{default_display := Display}) -> Display;
default_display(#{}) -> none.

%% A configured row, which reports ready within the machine's boot timeout as every
%% domain does.
start_configured(#{row := Row, name := Name, principal := Principal}, #{lib := Lib, boot_timeout := Timeout} = State) ->
    case erx_ident:new(Name) of
        {error, bad_identifier} ->
            logger:error("erx_domain: configured row ~b has no identifier for a name", [Row]),
            State;
        Ident ->
            Make = fun(Id, Pid) -> Lib:configured(Id, Row, Pid) end,
            case build(Ident, Principal, {configured, Row}, Make, #{}, Timeout, State) of
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
%% with its facet rows, the display its start named, if any (marked/1), and its provides,
%% its lines, at its node, after the answer
%% to the report, so the answer reaches the domain before any installation the report
%% starts. Only a running domain's report is taken, so the core hears a session's
%% report at most once and before its end (unprovide/3).
ready(Id, Ref, Provides, Inspect, #{core := Core, waiting := Waiting} = State) ->
    case {erx_domain_core:fetch(Id, Core), Waiting} of
        {{ok, #{ref := Ref, state := running, origin := Origin, node := Node, start := Start} = Domain}, _} ->
            {Links, Actions} = erx_domain_links:ready(Id, maps:get(links, State)),
            Ready = State#{core := erx_domain_core:ready(Id, Inspect, Core), links := Links},
            Answered = answer_ready(Id, grant_facets(Id, served(Origin, Domain, Ready), granted(Origin, Domain, Ready),
                                                     perform(Actions, Ready))),
            case Origin of
                {configured, Row} -> mints({ready, Row, Id, Node, Provides}, Answered);
                {session, _Template} -> mints({session_ready, minted_rows(Domain), Id, Node, marked(Start), Provides},
                                              Answered);
                request -> Answered
            end;
        {_, #{Id := #{ref := Ref, ended := {running, _Info}}}} ->
            answer_ready(Id, State);
        _ ->
            State
    end.

%% The grant a session's ready report marks (erx_domain_mints): the one on the display its
%% start named with display, and none for a default_display, which names only the
%% session's default display, or for no display at all.
marked(#{display := Display}) -> {display, Display};
marked(#{}) -> none.

%% The answer to domain Id's ready report, its facets by name: its spec's, and Served,
%% its grants of services the system domain serves (served/2). Each is bound to the
%% domain, exported to it and ends with the domain pid (mint/5). A spec's facet and a
%% message service's facet stand in front of the process the spec or the service
%% named (erx_facet:start/3) and end with it too; their callback is erx_domain_facet,
%% or the one system_facet/4 picks for the service. A tree service's grant is an
%% erx_fs grant its erx_fs_grants supervisor starts, and ends with that supervisor. The answer
%% goes to the domain pid, which hands it to the domain's agent for init (edit 65). Init
%% waits for it, so every domain that reported is answered, with no facets too. Granted,
%% the names and interfaces of the facets of configured domains the manifest grants the
%% domain (granted/3), goes with it, so the domain mounts what it is granted before the grants
%% are installed (docs/design-system.md, "Facets a configured domain serves"). Each facet goes
%% with its service's interface number (facet_interface/2).
grant_facets(Id, Served, Granted, #{core := Core, exports := Exports} = State) ->
    {ok, #{pid := Pid, ref := Ref, facets := Facets} = Domain} = erx_domain_core:fetch(Id, Core),
    Specs = maps:map(fun(_Name, {Behind, Limits}) -> {facet, erx_domain_facet, Behind, Limits#{behind => Behind}} end,
                     Facets),
    Systems = maps:map(fun(Name, Grant) -> system_facet(Name, Grant, Domain, State) end, Served),
    %% A spec never names a service of the table (facet/3), and the manifest grants a
    %% configured domain no spec, so the two never share a name.
    Minted = maps:filtermap(fun(Name, Facet) -> mint(Id, Pid, Name, Facet, Exports) end, maps:merge(Specs, Systems)),
    %% An app's record comes later, once the session's namespace is in place
    %% (answer_sessions/2), so the app's code never starts before its grants exist.
    Answer = #{Name => {facet_interface(Name, State), Facet} || Name := Facet <- Minted},
    Pid ! {Ref, facets, Answer, Granted},
    State.

%% The interface number the ready answer gives its facet Name, which the domain's registry
%% keeps and no server sets (erx_facets:program_table/1). A spec's one facet, console
%% (facet/3), stands in front of the console, the master of the session's tty, so it is
%% of the console interface; code_objects, which every session holds by the service's own
%% policy and no row (code_objects_row/0), is of its own; every other facet is of a
%% service the system domain serves, whose interface is its manifest row's.
facet_interface(console, _State) -> ?ERX_SERVICE_CONSOLE;
facet_interface(code_objects, _State) -> ?ERX_SERVICE_CODE_OBJECTS;
facet_interface(Name, #{interfaces := Interfaces}) -> map_get({system, Name}, Interfaces).

%% The facet of a service the system domain serves, for Domain, the domain service's
%% entry of the grantee: the inspect facet, whose scope erx_domain_core:inspect_scope/3
%% alone decides from the domain's principal (docs/design-live.md, "The inspect
%% service"), the login facet, an erx_domain_facet in front of the service's process,
%% or, for a tree service, the grant its erx_fs_grants supervisor starts (mint/5).
system_facet(inspect, {message, Behind, Limits}, #{principal := Principal},
             #{inspect_policy := #{roots := Roots, development := Development}}) ->
    {facet, erx_inspect_facet, Behind, Limits#{scope => erx_domain_core:inspect_scope(Principal, Roots, Development)}};
system_facet(login, {message, Behind, Limits}, #{name := Name}, _State) ->
    %% docs/design-login.md, "Who holds it": the row's line and logins, which the
    %% manifest check holds to the holder's entry, and the holder's manifest name, which
    %% names its terminals to the checker (G5); erx_login_facet:init/1 reads the line.
    {facet, erx_login_facet, Behind, Limits#{behind => Behind, holder => erx_ident:to_binary(Name)}};
system_facet(log, {message, Behind, Limits}, _Domain, _State) ->
    %% docs/design-log.md, "The log facet": Behind is erx_syslog_sup, and the callback
    %% finds erx_syslog at each request.
    {facet, erx_log_facet, Behind, Limits};
system_facet(clock, {message, Behind, Limits}, _Domain, _State) ->
    %% docs/design-time.md, "The clock facet": Behind is erx_clock_sup, and the
    %% callback finds erx_clock at each request and checks the grant's operations, sample
    %% or set, against what it decodes.
    {facet, erx_clock_facet, Behind, Limits};
system_facet(install, {message, Behind, Limits}, _Domain, _State) ->
    %% docs/design-live.md, "Code from the host": Behind is erx_code_sup, and the callback
    %% finds erx_code at each request and checks the grant's operations against what the
    %% code service's reader admits; the facet loads into the system domain alone.
    {facet, erx_code_facet, Behind, Limits};
system_facet(code_objects, {message, Behind, Limits}, _Domain, _State) ->
    {facet, erx_code_objects_facet, Behind, Limits#{behind => Behind}};
system_facet(pci_bus, {message, Behind, Limits}, _Domain, _State) ->
    %% docs/design-pcie.md, "Facets": the callback forwards each request, with its
    %% grantee, to the device service's PCIe process registered at that moment.
    {facet, erx_pci_bus_facet, Behind, Limits};
system_facet(pci, {message, Behind, Limits}, _Domain, _State) ->
    {facet, erx_pci_facet, Behind, Limits};
system_facet(_Name, {message, Behind, Limits}, _Domain, _State) ->
    {facet, erx_domain_facet, Behind, Limits#{behind => Behind}};
system_facet(machine, {tree, Grants, Limits}, #{principal := Principal}, State) ->
    %% docs/design-system.md, "A session's request": the grant's own argument is its
    %% grantee's user name, which the tree's ctl handler passes to the coordinator, so the
    %% log line names whoever the grant was made for and no request names anyone.
    {tree, Grants, user_name(Principal, State), Limits};
system_facet(_Name, {tree, Grants, Limits}, _Domain, _State) ->
    {tree, Grants, Limits}.

%% How the system domain serves its service Name to a grantee: tree, an erx_fs grant,
%% for a service of Trees, those of the interfaces abi/services declares served_as
%% tree, whose clients speak 9P (docs/design-system.md, "Facets of the system domain's
%% services"), and message, a facet in front of the service's process, for any other.
served_kind(Name, Trees) ->
    case lists:member(Name, Trees) of
        true -> tree;
        false -> message
    end.

%% A ready report's provides as the service reads them. Each name crosses as its text,
%% a binary, so the report makes no atom in the system domain (edit 9 of
%% docs/design-runtime.md), and is read here as the atom of that text where the system
%% domain has one. A binary it has no atom for stays a binary, and any other key, an
%% atom included, becomes {not_a_name, Key}: neither is an atom, so no manifest row
%% declares it and ?ERX_LINES names no line by it, so the mint core refuses it as
%% undeclared. A value that is no map passes untouched, for the core to refuse whole.
provided_atoms(Provides) when is_map(Provides) ->
    #{provided_atom(Name) => Mint || Name := Mint <- Provides};
provided_atoms(Provides) ->
    Provides.

provided_atom(Name) when is_binary(Name) ->
    try binary_to_existing_atom(Name)
    catch error:badarg -> Name
    end;
provided_atom(Key) ->
    {not_a_name, Key}.

mint(Id, DomainPid, Name, {tree, Grants, Limits}, Exports) ->
    mint_tree(Id, DomainPid, Name, Limits, fun(Binding) -> erx_fs_grants:grant(Grants, Limits, Binding) end, Exports);
mint(Id, DomainPid, Name, {tree, Grants, Args, Limits}, Exports) ->
    mint_tree(Id, DomainPid, Name, Limits, fun(Binding) -> erx_fs_grants:grant(Grants, Args, Limits, Binding) end,
              Exports);
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

%% A tree service's grant serves the domain alone, in its envelope and with its names,
%% and ends with its domain pid; its supervisor's end ends it too. Grant starts it,
%% with the grant's own argument where the service computed one at the mint
%% (system_facet/4); a supervisor that ended while the service minted is a refusal. The
%% facet goes to the domain with the rights of the row's Limits, those the grant serves
%% (docs/design-files.md, "Rights beneath an entry").
mint_tree(Id, DomainPid, Name, Limits, Grant, Exports) ->
    Binding = #{client => Id, ends_with => DomainPid, exports => Exports},
    case try Grant(Binding) catch exit:Exit -> {error, {exit, Exit}} end of
        {ok, Pid} ->
            {true, erx_fs_grants:facet(Pid, Limits)};
        {error, Reason} ->
            logger:error("erx_domain: domain ~b's tree grant ~ts did not start: ~0P", [Id, Name, Reason, 8]),
            false
    end.

%% The facets of services the system domain serves that the manifest grants a configured
%% domain's row or that a session's own rows hold, each {Kind, Behind, Limits} by its service's
%% name, with the code_objects facet every session holds by the domain service's own
%% policy (code_objects_row/0), and none for a domain a request made: Behind is the process the service
%% named for it with erx_facet:serve/2, which the system domain's services do as they
%% start. For a message service Limits are its row's: the limits erx_facet applies,
%% max_request and in_flight, checked as a spec's are (grant/1), its operations and
%% its parameters; for a tree service they
%% are the row's, which erx_fs_grants checks as it starts the grant. A service with no
%% living process, or a grant whose limits fail that check, is left out and logged, so
%% the domain finds the name absent,
%% as it finds any service that is unavailable, until it restarts. Each facet ends with
%% its process, and nothing grants a new one when the service restarts (TODO.md).
served({configured, Row}, _Domain, #{served := Served}) ->
    served(Row, maps:get(Row, Served, []));
served({session, _Template}, #{rows := Rows}, #{trees := Trees}) ->
    Granted = [{Name, served_kind(Name, Trees), Limits} || {Name, system, Limits} <- Rows],
    served(session, Granted ++ [code_objects_row()]);
served(request, _Domain, _State) ->
    #{}.

%% The code_objects facet every session holds, by the domain service's own policy and with
%% no facet row (docs/design-system.md, "Creating a domain", "The code_objects facet"): a
%% request's whole envelope fits ?ERX_CODE_OBJECTS_MAX_REQUEST, whose derivation
%% abi/services/code_objects.txt states, and in_flight lets a session's command server
%% fill a few programs' objects at once. It comes last in served/3's list, so its limits
%% stand whatever the rows hold; the manifest's check refuses a facet row of the service.
code_objects_row() ->
    {code_objects, message, #{max_request => ?ERX_CODE_OBJECTS_MAX_REQUEST, in_flight => 4}}.

%% The facets of configured domains the manifest grants a domain of Origin, sorted, each
%% {Name, Interface}, its name and its service's interface number (abi/services), by which
%% a domain tells, say, its input trees from its other grants (erx:granted/1): its row's,
%% or a session's own rows, and no other domain's; none for a domain created on request,
%% which the manifest grants nothing.
granted({configured, Row}, _Domain, #{mints := Mints} = State) ->
    with_interfaces(erx_domain_mints:granted_services(Row, Mints), State);
granted({session, _Template}, Domain, State) ->
    with_interfaces([{Name, Server} || {Name, Server, _Limits} <- minted_rows(Domain)], State);
granted(request, _Domain, _State) ->
    [].

%% Each service of Services, a name and its server row, as {Name, Interface}, sorted.
with_interfaces(Services, #{interfaces := Interfaces}) ->
    lists:usort([{Name, maps:get({Server, Name}, Interfaces)} || {Name, Server} <- Services]).

%% A session's rows of configured domains' services, which the mint core grants it.
minted_rows(#{rows := Rows}) ->
    [Row || {_Name, Server, _Limits} = Row <- Rows, Server =/= system].

served(Grantee, Rows) ->
    Servers = persistent_term:get({erx, serves}, #{}),
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
                     end, Rows)).

%% A message grant carries its row's operations, which the facet admits alone
%% (erx_facet:start/3), and the parameters its row states, each by its declared name
%% (erx_domain_lib:configured/0), as the login facet's line and logins; a tree grant's
%% row names no operations (dom_boot_view.c).
served_grant(message, Behind, Limits) ->
    case grant({Behind, maps:with([max_request, in_flight], Limits)}) of
        {ok, {Behind, _Checked}} -> {ok, {message, Behind, Limits#{operations => maps:get(operations, Limits, [])}}};
        invalid -> invalid
    end;
served_grant(tree, Grants, Limits) ->
    {ok, {tree, Grants, Limits}}.

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
%% The connection carries the pair's pixel area, which the mint core decides from the two
%% domains' origins alone, a session's with the facet rows its plan gave it
%% (erx_domain_mints:pair_area/3), so whichever introduction makes the connection, a
%% grant's or a request's, makes the same area.
introduce(_A, _B, #{lib := none} = State) ->
    {{error, enotsup}, State};
introduce(A, B, #{core := Core, links := Links, lib := Lib, mints := Mints} = State) ->
    case {introducible(A, Core), introducible(B, Core)} of
        {{ok, ReaderA, HoldsA}, {ok, ReaderB, HoldsB}} when A =/= B ->
            case erx_domain_links:phase(A, B, Links) of
                up ->
                    {ok, State};
                up_pending ->
                    {wait, State};
                none ->
                    case erx_domain_links:room(A, Links) andalso erx_domain_links:room(B, Links) of
                        true ->
                            {Area, AreaReader} = connection_area({A, HoldsA}, {B, HoldsB}, Mints),
                            Made = Lib:connect(A, B, ReaderA, ReaderB, Area, AreaReader),
                            connect(Made, A, B, ReaderA, ReaderB, State);
                        false -> {{error, system_limit}, State}
                    end;
                _Closing ->
                    {{error, closing}, State}
            end;
        _ ->
            {{error, badarg}, State}
    end.

%% The pair's pixel area as the library's connect takes it: its bytes and reader, or 0
%% and 0 for none.
connection_area(PartyA, PartyB, Mints) ->
    case erx_domain_mints:pair_area(PartyA, PartyB, Mints) of
        none -> {0, 0};
        {_Bytes, _Reader} = Area -> Area
    end.

%% A domain that can be introduced, with its lane and what it holds as the mint core's
%% pair_area/3 takes it: one built and not ended.
introducible(Id, Core) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := Life, reader := Reader, origin := Origin, rows := Rows}}
          when Life =:= built; Life =:= running; Life =:= ready ->
            {ok, Reader, holds(Origin, Rows)};
        _ ->
            none
    end.

%% A session holds the facet rows its plan gave it, not its template's, so an app's
%% session holds the pixel areas of the rows its admission kept and no other; any other
%% domain is named by its origin.
holds({session, _Template}, Rows) -> {rows, Rows};
holds(Origin, _Rows) -> Origin.

%% The library's answer to connecting A and B. Each party's connection_up carries the
%% slots of its own side, its peer's side and its peer's bell, the label of its own bell,
%% the data areas of the ring it writes, which its peer reads, and of the one it reads, and
%% its pixel area, none or {Slot, Bytes, write | read} as the library made it.
connect({ok, #{number := Number, a := PartyA, b := PartyB}}, A, B, ReaderA, ReaderB, #{links := Links} = State) ->
    UpA = up_values(PartyA, ReaderB, ReaderA),
    UpB = up_values(PartyB, ReaderA, ReaderB),
    {Next, Actions} = erx_domain_links:connect(Number, {A, UpA}, {B, UpB}, Links),
    {wait, perform(Actions, State#{links := Next})};
connect({error, Limit}, _A, _B, _ReaderA, _ReaderB, State) when Limit =:= elimit; Limit =:= enomem ->
    {{error, system_limit}, State};
connect({error, einval}, _A, _B, _ReaderA, _ReaderB, State) ->
    %% A domain the library has ended, whose end has not reached the service yet: an
    %% ended domain, as introducible/2 would find it once the end arrives.
    {{error, badarg}, State};
connect({error, _} = Refused, _A, _B, _ReaderA, _ReaderB, State) ->
    {Refused, State}.

up_values(#{side := Side, peer_side := PeerSide, peer_bell := PeerBell, label := Label, area := Area}, OutSize,
          InSize) ->
    {Side, PeerSide, PeerBell, Label, OutSize, InSize, Area}.

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
wire({connection_up, Peer, PeerNode, {Side, PeerSide, PeerBell, Label, OutSize, InSize, Area}}) ->
    {erx_connection_up, Peer, PeerNode, Side, PeerSide, PeerBell, Label, OutSize, InSize, Area};
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
                    {Next, Actions} = erx_domain_links:answer(Id, unwire(Answer), Links),
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
ended(Id, End, Where, #{lib := Lib, core := Core, links := Links} = State) ->
    case erx_domain_core:ended(Id, End, slogan(Lib, Id, End), erlang:system_time(second), Core) of
        none ->
            State;
        {Info, #{pid := Pid, ref := Ref, connection := Connection, origin := Origin, state := Life}, Ended} ->
            close_side(Id, Connection, {domain_down, Id, Info}, State),
            disconnect(Lib, Connection),
            Pid ! {Ref, domain_down, Info},
            {Unlinked, Actions} = erx_domain_links:ended(Id, Info, Links),
            Told = unprovide(Origin, Id, perform(Actions, State#{core := Ended, links := Unlinked})),
            _ = retire(Lib, Id),
            release(restart(Origin, Id, Life, Info, Where, waiter_ended(Id, Life, Info, Told)))
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
        {{error, noproc}, true} -> error({connection_agent, noproc});
        %% Not reached: a claim another process made first ends the service's start (become_installer/1).
        {{error, badarg}, _} -> error({connection_agent, not_installer})
    end.

disconnect(_Lib, 0) -> ok;
disconnect(Lib, Connection) ->
    case Lib:disconnect(Connection) of
        ok -> ok;
        {error, Reason} ->
            logger:error("erx_domain: the library refused to disconnect connection ~b: ~0p", [Connection, Reason])
    end.

%% A configured domain's end is one log line (docs/design-system.md, "Boot failure" and
%% the failure table): the domain's name and id, Info as in {domain_down, Id, Info}, for a
%% fault where it struck (Where, erx_domain_core:fault_where/2), and whether the service
%% starts it again or, its restart intensity spent, leaves it down, which is a warning,
%% since nothing starts it again. The restart intensity bounds the lines' rate. Life is the
%% domain's at its end, which says how far its boot got (erx_domain_core:restart/5).
restart(request, _Id, _Life, _Info, _Where, State) ->
    State;
restart({session, _Template}, _Id, _Life, _Info, _Where, State) ->
    State;
restart({configured, Row}, Id, Life, Info, Where, #{core := Core, configured := Configured} = State) ->
    #{Row := #{name := Name, restarts := Restarts, restart_period_s := Period} = Entry} = Configured,
    Intensity = #{restarts => Restarts, period_s => Period},
    case erx_domain_core:restart(Row, Intensity, Life, erlang:monotonic_time(second), Core) of
        {yes, Next} ->
            log_end(notice, Name, Id, Info, Where, "restarting it"),
            start_configured(Entry, State#{core := Next});
        {no, Next} ->
            log_end(warning, Name, Id, Info, Where, "left down"),
            State#{core := Next}
    end.

log_end(Level, Name, Id, Info, Where, Then) ->
    logger:log(Level, "erx_domain: configured domain ~ts (domain ~b) ended, ~0p~s; ~s",
               [Name, Id, Info, Where, Then]).

%% A configured domain's end, which the mint core hears before any restart: every
%% operation of its incarnation is cancelled, and a session waiting for its grant is
%% answered then, before the restart makes the row starting again (docs/design-system.md,
%% "A session takes the console": a session does not wait for a restart). A session's end cancels its grants'
%% operations and deletes the grants.
unprovide({configured, Row}, Id, State) -> mints({ended, Row, Id}, State);
unprovide({session, _Template}, Id, State) ->
    mints({session_ended, Id}, State);
unprovide(request, _Id, State) -> State.

%%% The facets configured domains serve (docs/design-system.md, "Facets a configured
%%% domain serves").

%% Event, for erx_domain_mints, and its actions performed in order. An action may feed
%% the core a further event at once (an installation in the system domain's own
%% registry); the core's state is already the step's next, so that event sees it.
mints(Event, #{mints := Mints} = State) ->
    {Next, Actions} = erx_domain_mints:step(Event, Mints),
    answer_in_place(lists:foldl(fun mint_act/2, State#{mints := Next}, Actions)).

%% Each session's start still waiting after its ready report, answered once its
%% namespace is in place (erx_domain_mints:in_place/3). The mint core hears of a session
%% only at its report, so only a ready session's grants are checked: before then it
%% holds none, which would read as in place. A session whose domain pid has died is
%% ending, and its end answers it with an error (settle/2).
%%
%% The settlement queries wait in settling until their facts settle, and are answered
%% with erx_domain_mints:settled/3's answer (answer_settling/2). The system domain holds
%% every grant it will have from the boot on, so its namespace is checked from the first
%% call. A starting row is one whose domain runs without having reported ready, or a row
%% held at boot, which stays starting until the release starts it; the same evaluation
%% arms the release's fallback once its server has settled (arm_fallback/2).
answer_in_place(#{core := Core, mints := Mints, boot_held := Held} = State) ->
    Starting = [Row || #{origin := {configured, Row}, state := running} <- erx_domain_core:domains(Core)]
        ++ [Row || #{row := Row} <- Held],
    InPlace = fun(Grantee) -> erx_domain_mints:in_place(Grantee, Starting, Mints) end,
    arm_fallback(Starting, answer_settling(Starting, answer_sessions(InPlace, State))).

answer_sessions(InPlace, #{waiting := Waiting, core := Core} = State) ->
    Ready = [Id || Id := #{answer_at := in_place, pid := Pid, refusal := none} <- Waiting, Pid =/= gone,
                   is_ready(Id, Core)],
    InPlaceIds = [Id || Id <- Ready, InPlace({session, Id})],
    lists:foreach(fun(Id) -> send_app(Id, Core) end, InPlaceIds),
    lists:foldl(fun answer_ok/2, State, InPlaceIds).

%% An app's session's record (docs/design-packaging.md, "An app's session"), sent once
%% its namespace is in place, its packages grant among it, and before its start is
%% answered; a session of a template has none.
send_app(Id, Core) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{app := none}} -> ok;
        {ok, #{app := App, pid := Pid, ref := Ref}} -> Pid ! {Ref, app, App}, ok
    end.

%% Each settlement query asked of the service, in arrival order, answered once its
%% answer is no longer wait; the rest keep waiting, each for its own query alone.
answer_settling(Starting, #{settling := Settling, mints := Mints} = State) ->
    Answers = [{Asker, erx_domain_mints:settled(Query, Starting, Mints)} || {Query, _From} = Asker <- Settling],
    {Waiting, Settled} = lists:partition(fun({_Asker, Answer}) -> Answer =:= wait end, Answers),
    lists:foreach(fun({{_Query, From}, Answer}) -> gen_server:reply(From, Answer) end, Settled),
    State#{settling := [Asker || {Asker, _Wait} <- Waiting]}.

%% A settlement query as the service keeps it, erx_domain_mints:query(), or the answer
%% given at once (docs/design-system.md, "Waiting for a grant"). The start table names a
%% server as the binary its rows hold, and the mint core a service by its atom, as the
%% library makes it; a name with no atom is no service, so nothing serves it and the
%% wait is answered at once. The atom is never made here. A query outside the closed
%% set is answered badarg.
settling_query(namespace) ->
    {ask, namespace};
settling_query({server, Name}) when is_binary(Name) ->
    try binary_to_existing_atom(Name) of
        Service -> {ask, {server, Service}}
    catch
        error:badarg -> {answer, ok}
    end;
settling_query({grant, Name, Id} = Query) when is_atom(Name), is_integer(Id), Id > 0 ->
    {ask, Query};
settling_query(_Asked) ->
    {answer, {error, badarg}}.

is_ready(Id, Core) ->
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := ready}} -> true;
        _ -> false
    end.

%% The user name of the principal of grantee GranteeId, which its mint carries
%% (docs/design-system.md, "Facets a configured domain serves"): the system principal's
%% for the system domain, and for any other the one its record names, a configured row's
%% or a session's template's. The core mints only for a grantee that is ready.
principal_name(?ERX_SYSTEM_DOMAIN_ID, #{principals := #{system := System}} = State) ->
    user_name(System, State);
principal_name(GranteeId, #{core := Core} = State) ->
    {ok, #{principal := Principal}} = erx_domain_core:fetch(GranteeId, Core),
    user_name(Principal, State).

%% The user name of Principal, the one name every grant carries, a mint request's and
%% the machine tree's alike: the prefix of the principal's sessions, root for the
%% system principal and its manifest name for any other principal of the manifest
%% (erx_domain_core:session_prefix/3), and the registry's for an app principal, the
%% app's name (docs/design-packaging.md, "An app's principal"). A domain lives only
%% under a principal of one or the other, so every grantee has a name, and a grant
%% rooted at a user's home is rooted where the user's login name says
%% (docs/design-files.md, "A user's home").
user_name(Principal, #{principals := #{system := System, names := Names}, apps := Apps,
                       app_entries := Entries}) ->
    case {erx_domain_core:session_prefix(Principal, System, Names), Entries} of
        {{ok, Name}, _} -> Name;
        {error, #{first := First}} -> erx_principal:fetch_name(Principal - First, Apps)
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
    Pid ! {Ref, mint, Mint, {erx_facet_mint, Tag, Name, GranteeId, principal_name(GranteeId, State), Limits}},
    State;
mint_act({install, Tag, ?ERX_SYSTEM_DOMAIN_ID, Name, Interface, Facet}, #{agent := Agent} = State) ->
    %% The system domain's agent writes its registry, as every domain's does, and answers
    %% the processes waiting for an installation before it answers here, so the
    %% installation is acknowledged only once its waiters have heard of it. A grant to
    %% the system domain comes from a configured server, so the runtime is a node and
    %% runs the agent.
    case Agent:grant(#{Name => {Interface, Facet}}) of
        ok -> ok;
        {error, Reason} -> error({connection_agent, Reason})
    end,
    mints({installed, ?ERX_SYSTEM_DOMAIN_ID, Tag}, State);
mint_act({install, Tag, GranteeId, Name, Interface, Facet}, #{core := Core} = State) ->
    %% The core installs only in a grantee that is ready and has not ended.
    {ok, #{pid := Pid, ref := Ref}} = erx_domain_core:fetch(GranteeId, Core),
    Pid ! {Ref, install, Tag, Name, Interface, Facet},
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
    %% One line per operation, so bounded by the restarts of its two domains. Name is
    %% the installed name, an atom or a drive's {drive, N}, so it is printed as a term.
    logger:warning("erx_domain: facet ~0p of domain ~b for ~0p (domain ~b) failed: ~0p",
                   [Name, ServerId, Grantee, GranteeId, Reason]),
    State;
mint_act({answer, Asker, Reply}, State) ->
    gen_server:reply(Asker, Reply),
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

%% The system domain's packages grant at its place (erx_ns:packages_place/0),
%% /packages, where erx_pkg_medium reads and deletes the installed packages
%% (docs/design-packaging.md, "Where a package lies"), when the manifest grants it, as a
%% board with an apps row does. Packages has no place a session mounts, so no session's
%% mount_facets/1 mounts it; this is its one mount.
mount_packages(Granted) ->
    case lists:member(packages, Granted) of
        true ->
            {Point, Options} = erx_ns:packages_place(),
            erx_ns:mount({facet, packages}, Point, Options);
        false ->
            ok
    end.
