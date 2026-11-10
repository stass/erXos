%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain).
-moduledoc """
Creating and stopping domains (docs/design-domains.md, "Erlang interface").

create/1 asks the domain service for a domain and returns {ok, Domain} once
the domain's first thread runs. Spec names the domain, an identifier, and
gives the domain library's request fields directly (TODO.md, the request
fields item): runtime, release and release_files (the boot image's
indexes), memory, outer, grant, lane, args, env, and optionally
connections, flags, spaces and limits (erx_domain_lib's spec(), less id and
principal, which the service sets). Every domain is the system principal's.

stop/2 is exit(pid(Domain), Reason): any reason but normal stops the domain,
and kill ends the domain pid at once, after which the service stops the
domain. Monitoring the domain pid watches the domain: it ends with
{domain_down, Id, Info}, Info one of {halt, Status}, crash, {fault, Kind}
or stopped.
""".

-export([create/1, stop/2, id/1, node/1, pid/1]).
-export_type([domain/0, spec/0]).

-opaque domain() :: {erx_domain, Id :: pos_integer(), Node :: node(), Pid :: pid()}.
-type spec() :: #{name := binary(), atom() => term()}.

-doc """
Creates a domain: {ok, Domain}, or {error, Reason}, Reason bad_identifier,
name_taken, quota, system_limit, no_memory, badarg (a field of the wrong
shape), {bad_spec, Key} (a key the spec does not take), {system_side,
Error} (the system side of its system connection did not open: noproc where
the system domain is no node), {start, Error}, or the domain library's own
refusal. On every error nothing of the domain
remains but its id, which is never reused.
""".
-spec create(spec()) -> {ok, domain()} | {error, term()}.
create(Spec) ->
    gen_server:call(erx_domain_srv, {create, Spec}, infinity).

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
