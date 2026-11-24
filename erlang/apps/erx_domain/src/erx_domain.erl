%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain).
-moduledoc """
Creating and stopping domains (docs/design-domains.md, "Erlang interface").

create/1 asks the domain service for a domain and returns {ok, Domain} once
the domain's init reports ready to its domain pid, after the boot script has
started every application and before any -eval runs (edit 65 of
docs/design-runtime.md); a domain with no system connection, which has no way
to report, is ready when its first thread runs. Spec names the domain, an
identifier, and its boot script, boot, an identifier naming
bin/<boot>.boot of the boot image's domain release, may set boot_timeout,
how long in milliseconds init has to report (by default the machine's boot
timeout, the system manifest's boot_timeout_s, or infinity),
and gives the domain library's request fields directly (TODO.md, the
request fields item): runtime, release and release_files (the boot image's
indexes of the domain release's run), memory, outer, grant, lane, args,
env, and optionally connections, flags, spaces and limits (erx_domain_lib's
spec(), less id and principal, which the service sets). The service passes
args to the library with -boot /bin/<boot> -- as init's first arguments, after
the emulator flags, so args that name -boot are refused. Every domain is the system principal's.

introduce/2 makes a connection between two domains (docs/design-domains.md,
"Introduction and connection down"), for processes of the system domain,
the only callers the domain service has: another domain's request reaches
it only through a facet. It answers ok once the connection is up at both
ends, each domain's connection agent having mapped it, which waits for a
domain whose init has not reported ready yet; ok at once for two domains
already joined. {error, system_limit} when either domain is at its
connections limit or cannot fund its side, {error, badarg} for a domain
that does not exist or has ended, or for one domain twice, {error,
closing} while the pair's last connection is still going down,
{error, noconnection} when the connection closed before it came up,
{error, timeout} when it is not up at both ends within ten seconds, the
connection being left as it is, and the domain library's own refusal
otherwise.

stop/2 is exit(pid(Domain), Reason): any reason but normal stops the domain,
and kill ends the domain pid at once, after which the service stops the
domain. Monitoring the domain pid watches the domain: it ends with
{domain_down, Id, Info}, Info one of {halt, Status}, crash, {fault, Kind}
or stopped.
""".

-export([create/1, start_session/2, start_session_request/2, start_app/2, info/1, introduce/2, line/4,
         line_request/4, stop/2, id/1, node/1, pid/1]).
-export([system_principal/0, system_principal_request/0, system_namespace/0, server_settled/1,
         await_grant/2, release_held/0]).
-export([inspect_view/1]).
-export_type([domain/0, spec/0, start/0]).

-include("generated/erx_abi.hrl").

-opaque domain() :: {erx_domain, Id :: pos_integer(), Node :: node(), Pid :: pid()}.
-type spec() :: #{name := binary(), atom() => term()}.
%% A session's start (start_session/2).
-type start() :: #{console => term(), display => atom(), default_display => atom(), ends_with => [pid()]}.

-doc """
Creates a domain: {ok, Domain}, or {error, Reason}, Reason bad_identifier,
name_taken, quota, system_limit, no_memory, badarg (a field of the wrong
shape), {bad_spec, Key} (a key the spec does not take, a boot_timeout
that is no timeout, a boot that is missing or no identifier or args that
name -boot, as {bad_spec, boot}, or facets that are not a map of names to processes of
the system domain, each of which the domain gets a facet in front of),
{system_side, Error} (the system side of its system connection did not
open: noproc where the system domain is no node),
{export, Error} (the export table refused the domain pid's), {start, Error},
timeout (init did not report ready within boot_timeout, and the service
stopped the domain), {boot, Info} (the domain ended before it reported,
Info as in {domain_down, Id, Info}), or the domain library's own refusal.
On every error nothing of the domain is charged but what a peer still
maps, and its id is never reused: the error comes once the domain has
ended and been retired, at its end, and a domain introduced before it
reported ready leaves only the outer budget its peers' connections are
carved from, its principal's until each peer has unmapped.
""".
-spec create(spec()) -> {ok, domain()} | {error, term()}.
create(Spec) ->
    gen_server:call(erx_domain_srv, {create, Spec}, infinity).

-doc """
What Domain's domain pid holds: connections, the connection agent its init's
ready report named (none before the report), and dropped, how many messages
it dropped as none its domain may send it. {error, badarg} for a domain that
has ended. The domain pid answers itself, behind whatever its mailbox holds,
so a caller waits at most five seconds and exits with timeout past that.
""".
-spec info(domain()) -> {ok, #{connections := pid() | none, inspect := pid() | none,
                                         dropped := non_neg_integer()}} | {error, badarg}.
info({erx_domain, Id, _, _}) ->
    gen_server:call(erx_domain_srv, {info, Id}, 5000).

-doc """
Starts a session of principal Principal (docs/design-domains.md, "Principals,
sessions and quotas"; docs/design-apps.md, "Starting a session"): {ok,
Domain} once its init has reported ready and its namespace is in place, each
files grant of its template installed or failed (docs/design-system.md, "A
session takes the console"), and an error as create/1's if it ends before
then. The domain is made from the principal's session template alone, its
runtime, release, arguments, environment and limits, which the domain
library judges against the principal's ceilings, share, budget and domain
quota. Start names, each optional:

* console, the session's one facet, a grant as a create's spec takes it,
  which names the line the session starts at;
* display, a display (a windows service) the template is granted, which is
  the session's default display, its `display` variable, and makes the
  session that display's session: the session's grant on it carries the
  session mark in every mint (docs/design-system.md, "Facets a configured
  domain serves");
* default_display, a display the template is granted, which is only the
  session's default display, and no mint carries;
* ends_with, a list of processes the session ends with, which only the login
  service passes (docs/design-login.md, "A session ends with what it was
  started for"): the service monitors each as it admits the start, before the
  start is held or the domain made, answers {error, ended} when one has ended
  before the session's namespace is in place, the session stopped if it was
  made, and stops the session when one ends after, whoever is left to hear it.

display and default_display exclude each other, and either one naming a
display the template is not granted refuses the start with {bad_spec, Key};
ends_with that is no list of pids refuses it with {bad_spec, ends_with}, and
any other key is no facet the funnel lets through, {bad_spec, facets}. The
session's name is its principal's name in the system manifest, root for the
system principal, and the lowest number no living session of the principal
holds: root_1 and root_2 beside it, or clock_1 for principal clock. {error,
no_template} for a principal with no template, {error, no_name} for one
the manifest does not name, and every error of create/1 else.

The service holds the start until the system release's boot has ended
(erx_domain_srv), so an application's start must never wait on it: the
boot would never end.
""".
-spec start_session(pos_integer(), start()) -> {ok, domain()} | {error, term()}.
start_session(Principal, Start) when is_integer(Principal), Principal > 0, is_map(Start) ->
    gen_server:call(erx_domain_srv, {start_session, Principal, Start}, infinity).

-doc """
start_session/2 sent, not waited on: the caller takes its answer as a message with
gen_server:check_response/2 or receive_response/2 on the returned id, so the login
service goes on answering its front ends while sessions start
(docs/design-login.md, "A row's states"). The start is the same, its ends_with
bonded as the service admits it, whatever becomes of the caller.
""".
-spec start_session_request(pos_integer(), start()) -> gen_server:request_id().
start_session_request(Principal, Start) when is_integer(Principal), Principal > 0, is_map(Start) ->
    gen_server:send_request(erx_domain_srv, {start_session, Principal, Start}).

-doc """
Starts a session of the app Name, a package registered in this boot
(docs/design-packaging.md, "An app's session"), with Start as for
start_session/2 but no console: the domain library plans the app template
under the app's entry with the memory its record holds, the session holds
the template's packages row and the rows the app's admission kept and no
other, its name is Name_N, and once its namespace is in place it is handed
the app's record, from which erx_app mounts /app and starts the app. The
start service's keepers are its only callers (PK7, the build check
app-starters), since an app principal has no credentials and no login
starts its session (AP2). {error, no_app} for a name not registered, a
display the session does not hold refuses it as start_session/2 does, and
every error of create/1 else. The service holds it, as start_session/2's
start, until the system release's boot has ended.
""".
-spec start_app(binary(), #{display => atom(), default_display => atom()}) -> {ok, domain()} | {error, term()}.
start_app(Name, Start) when is_binary(Name), is_map(Start) ->
    gen_server:call(erx_domain_srv, {start_app, Name, Start}, infinity).

-doc """
The domains Scope covers, `all` or `{principal, P}`, each with its
inspection agent, `none` or `ended`, and the service's report of it
(erx_domain_core:inspect_view/2), for
the inspector's query worker in the system domain. It waits at most
inspect_agent_wait milliseconds, the worker's wait for one agent, and
exits like gen_server:call/3 when the service does not answer.
""".
-spec inspect_view(all | {principal, pos_integer()}) -> [erx_domain_core:inspect_entry()].
inspect_view(Scope) ->
    gen_server:call(erx_domain_srv, {inspect_view, Scope}, ?ERX_INSPECT_AGENT_WAIT).

-doc """
The system principal, the one the system manifest's root.system_principal
names, which the domain service read as it started and charges its own creates
to: the principal the system console logs in at the system domain's line
(erx_console:login/0). {error, enotsup} in a runtime with no domain library,
which has none. It waits, as start_session/2 does, while the service builds
the boot's configured domains, and exits like gen_server:call/3 when the
service is not running or ends.
""".
-spec system_principal() -> {ok, pos_integer()} | {error, enotsup}.
system_principal() ->
    gen_server:call(erx_domain_srv, system_principal, infinity).

-doc """
system_principal/0 without waiting: the request's id, whose answer the caller
takes with gen_server:check_response/2 or receive_response/2, as
system_principal/0's reply. {error, enotsup} while the domain service is not
running.
""".
-spec system_principal_request() -> {ok, gen_server:request_id()} | {error, enotsup}.
system_principal_request() ->
    case whereis(erx_domain_srv) of
        undefined -> {error, enotsup};
        Service -> {ok, gen_server:send_request(Service, system_principal)}
    end.

-doc """
Asks the domain service to answer once the system domain's namespace is in
place, by the rule a session's start waits on (docs/design-system.md, "A
session takes the console"): each files grant to the system domain installed
or failed, or with no operation while its server is not starting. The answer
is ok; the grant's deadline and its server's boot timeout bound the wait. The
request is sent, not waited on: the caller takes the answer as a message with
gen_server:check_response/2 on the returned id, so it goes on answering its
own callers meanwhile. The start table waits on it before its first read of
rc.conf (docs/design-apps.md, "Failure handling, diagnostics and
debuggability").
""".
-spec system_namespace() -> gen_server:request_id().
system_namespace() ->
    gen_server:send_request(erx_domain_srv, {settled, namespace}).

-doc """
Asks the domain service to answer once the server of service Name has
settled (docs/design-system.md, "Waiting for a grant", and "A session takes
the console", a display's row): no configured row that serves Name is
starting, so its server is ready, was stopped for its boot timeout, ended,
or was refused its start. The answer is ok; the server row's boot timeout
bounds the wait, and a name no configured row serves is answered at once.
The request is sent, not waited on, as system_namespace/0's is: the start
table takes the answer with gen_server:check_response/2 and starts the row
that names the display then, whether its display came up or not
(docs/design-apps.md, "Keeping a session").
""".
-spec server_settled(binary()) -> gen_server:request_id().
server_settled(Name) when is_binary(Name) ->
    gen_server:send_request(erx_domain_srv, {settled, {server, Name}}).

-doc """
Asks the domain service to answer once the system domain's grant of service
Name has settled for incarnation Id of its server (docs/design-system.md, "A
session takes the console", one incarnation's grant): {ok, Facet} once the
grant is installed with Id as its server, Facet the system domain's facet of
that incarnation; {error, failed} once it failed with Id as its server;
{error, ended} once Id has ended or the grant carries another server; and
{error, unprovided} once Id is ready and provides no Name, or the system
domain is granted no Name. The mint core's deadline bounds a wait for an
operation in progress, and the server row's boot timeout one before Id's
ready report, for an Id that is an incarnation of the grant's server row,
as the domain a PCIe domain's envelope names is. The request is sent, not waited on, as system_namespace/0's
is: the device service takes the answer with gen_server:check_response/2 and
answers a PCIe domain's report, Id the domain its envelope names, only on it
(docs/design-pcie.md, "Facets").
""".
-spec await_grant(atom(), pos_integer()) -> gen_server:request_id().
await_grant(Name, Id) when is_atom(Name), is_integer(Id), Id > 0 ->
    gen_server:send_request(erx_domain_srv, {settled, {grant, Name, Id}}).

-doc """
Releases the configured rows the device service holds at boot, which the
domain service then starts in boot order (docs/design-system.md, "Waiting
for a grant", "The rows held at boot"); with nothing held it changes
nothing. It is a cast, so the device service, which waits on the domain
service through await_grant/2, never blocks on it.
""".
-spec release_held() -> ok.
release_held() ->
    gen_server:cast(erx_domain_srv, release_held).

-doc "Introduces domains A and B: ok once their connection is up at both ends.".
-spec introduce(domain(), domain()) -> ok | {error, term()}.
introduce({erx_domain, A, _, _}, {erx_domain, B, _, _}) ->
    gen_server:call(erx_domain_srv, {introduce, A, B}, infinity).

-doc """
Session's line Name, minted as a facet for the domain Peer (docs/design-system.md,
"A session's lines"): `web_line`, the erx_web_line the host link's `web` facet
hands the web domain as it opens (docs/design-web.md, "Logging in and the
line"), or `tty_line`, the erx_tty_line a login hands the SSH domain
(docs/design-ssh.md, "Logging in"). Opening, a process of the system domain,
bounds the grant: the facet ends when it does. One call, answered once by the
mint core's line operation within its deadline: {ok, Facet}, or {error,
no_line} when the session is not live or provides no line under Name (a Name
outside ?ERX_LINES included), busy while a request for the session's Name is
pending, ended when Peer ended first, the introduction's refusal as
introduce/2 answers it, refused when the session refused or answered with
something other than a facet of its own, and unavailable at the deadline.
""".
-spec line(atom(), pos_integer(), pos_integer(), pid()) -> {ok, pid()} | {error, term()}.
line(Name, Session, Peer, Opening) when is_atom(Name), is_integer(Session), Session > 0,
                                        is_integer(Peer), Peer > 0, is_pid(Opening) ->
    gen_server:call(erx_domain_srv, {line, Name, Session, Peer, Opening}, infinity).

-doc """
line/4 sent, not waited on, as start_session_request/2 is: the answer, the same as
line/4's, arrives as a message to the returned id.
""".
-spec line_request(atom(), pos_integer(), pos_integer(), pid()) -> gen_server:request_id().
line_request(Name, Session, Peer, Opening) when is_atom(Name), is_integer(Session), Session > 0,
                                                is_integer(Peer), Peer > 0, is_pid(Opening) ->
    gen_server:send_request(erx_domain_srv, {line, Name, Session, Peer, Opening}).

-doc "exit(pid(Domain), Reason).".
-spec stop(domain(), term()) -> ok.
stop({erx_domain, _, _, Pid}, Reason) ->
    exit(Pid, Reason),
    ok.

-spec id(domain()) -> pos_integer().
id({erx_domain, Id, _, _}) -> Id.

-spec node(domain()) -> node().
node({erx_domain, _, Node, _}) -> Node.

-spec pid(domain()) -> pid().
pid({erx_domain, _, _, Pid}) -> Pid.
