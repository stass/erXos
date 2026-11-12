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
how long in milliseconds init has to report (default 60000, the system
manifest's boot_timeout_default_s, or infinity),
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

-export([create/1, start_session/2, info/1, introduce/2, web_line/2, stop/2, id/1, node/1, pid/1]).
-export([inspect_view/1]).
-export_type([domain/0, spec/0]).

-include("generated/erx_abi.hrl").

-opaque domain() :: {erx_domain, Id :: pos_integer(), Node :: node(), Pid :: pid()}.
-type spec() :: #{name := binary(), atom() => term()}.

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
* display, a service the template is granted, which makes the session that
  display's session: the session's grant on it carries the session mark in
  every mint (docs/design-system.md, "Facets a configured domain serves");
* default_display, a service the template is granted, which the session's
  record keeps as its default display and no mint carries.

display and default_display exclude each other, and either one naming a
service the template is not granted refuses the start with {bad_spec, Key};
any other key is no facet the funnel lets through, {bad_spec, facets}. The
session's name is its principal's name in the system manifest, root for the
system principal, and the lowest number no living session of the principal
holds: root_1 and root_2 beside it, or clock_1 for principal clock. {error,
no_template} for a principal with no template, {error, no_name} for one
the manifest does not name, and every error of create/1 else.
""".
-spec start_session(pos_integer(), #{console => term(), display => atom(), default_display => atom()}) ->
          {ok, domain()} | {error, term()}.
start_session(Principal, Start) when is_integer(Principal), Principal > 0 ->
    gen_server:call(erx_domain_srv, {start_session, Principal, Start}, infinity).

-doc """
The domains Scope covers, `all` or `{principal, P}`, each with its
inspection agent, `none` or `ended` (erx_domain_core:inspect_view/2), for
the inspector's query worker in the system domain. It waits at most
inspect_agent_wait milliseconds, the worker's wait for one agent, and
exits like gen_server:call/3 when the service does not answer.
""".
-spec inspect_view(all | {principal, pos_integer()}) -> [{pos_integer(), pid() | none | ended}].
inspect_view(Scope) ->
    gen_server:call(erx_domain_srv, {inspect_view, Scope}, ?ERX_INSPECT_AGENT_WAIT).

-doc "Introduces domains A and B: ok once their connection is up at both ends.".
-spec introduce(domain(), domain()) -> ok | {error, term()}.
introduce({erx_domain, A, _, _}, {erx_domain, B, _, _}) ->
    gen_server:call(erx_domain_srv, {introduce, A, B}, infinity).

-doc """
Session's line to the web domain Web (docs/design-web.md, "Logging in and the
line"), for the host link's `web` facet as it opens: the erx_web_line the
session's ready report named, once the service has introduced the two domains
and the line, asked in the system domain's envelope, has exported itself to Web
with send. Each is its own domain's act: the service makes the connection, the
session's runtime the export, so no domain reaches the line before the facet
opens. {error, no_line} for a session that named no line or has ended, the
introduction's refusal as introduce/2 answers it, by the service's own deadline,
and {error, unavailable} when the line did not answer within five seconds,
{error, refused} when it refused.
""".
-spec web_line(pos_integer(), pos_integer()) -> {ok, pid()} | {error, term()}.
web_line(Session, Web) when is_integer(Session), Session > 0, is_integer(Web), Web > 0 ->
    maybe
        {ok, Line} ?= gen_server:call(erx_domain_srv, {web_line, Session}),
        ok ?= gen_server:call(erx_domain_srv, {introduce, Session, Web}, infinity),
        ok ?= export_line(Line, Web),
        {ok, Line}
    end.

%% The line's answer, which its session wrote, is taken only as ok; anything else is
%% refused, so no term of the session's reaches the caller.
export_line(Line, Web) ->
    try gen_server:call(Line, {export, Web}, 5000) of
        ok -> ok;
        _Refused -> {error, refused}
    catch
        exit:_ -> {error, unavailable}
    end.

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
