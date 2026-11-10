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
identifier, may set boot_timeout, how long in milliseconds init has to report
(default 10000, or infinity), and gives the domain library's request fields directly (TODO.md, the request
fields item): runtime, release and release_files (the boot image's
indexes), memory, outer, grant, lane, args, env, and optionally
connections, flags, spaces and limits (erx_domain_lib's spec(), less id and
principal, which the service sets). Every domain is the system principal's.

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

-export([create/1, info/1, introduce/2, stop/2, id/1, node/1, pid/1]).
-export_type([domain/0, spec/0]).

-opaque domain() :: {erx_domain, Id :: pos_integer(), Node :: node(), Pid :: pid()}.
-type spec() :: #{name := binary(), atom() => term()}.

-doc """
Creates a domain: {ok, Domain}, or {error, Reason}, Reason bad_identifier,
name_taken, quota, system_limit, no_memory, badarg (a field of the wrong
shape), {bad_spec, Key} (a key the spec does not take, or a boot_timeout
that is no timeout), {system_side, Error} (the system side of its system
connection did not open: noproc where the system domain is no node),
{export, Error} (the export table refused the domain pid's), {start, Error},
timeout (init did not report ready within boot_timeout, and the service
stopped the domain), {boot, Info} (the domain ended before it reported,
Info as in {domain_down, Id, Info}), or the domain library's own refusal.
On every error nothing of the domain remains but its id, which is never
reused.
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
-spec info(domain()) -> {ok, #{connections := pid() | none, dropped := non_neg_integer()}} | {error, badarg}.
info({erx_domain, Id, _, _}) ->
    gen_server:call(erx_domain_srv, {info, Id}, 5000).

-doc "Introduces domains A and B: ok once their connection is up at both ends.".
-spec introduce(domain(), domain()) -> ok | {error, term()}.
introduce({erx_domain, A, _, _}, {erx_domain, B, _, _}) ->
    gen_server:call(erx_domain_srv, {introduce, A, B}, infinity).

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
