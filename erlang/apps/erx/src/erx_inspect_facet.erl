%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspect_facet).
-moduledoc """
The inspect facet (docs/design-live.md, "The inspect service", "How a query
travels"): the erx_facet callback the domain service mints, in the system
domain, for each grantee of the `inspect` service, in front of
erx_inspect_srv.

* **Its scope.** The grant's `scope`, `all` or `{principal, P}`, is fixed
  at the mint by erx_domain_core:inspect_scope/3 and lives only here. A
  request carries a path and its options and nothing else
  (erx_inspect_query), so no holder can name or widen a scope;
  `{principal, P}` is resolved to P's domains by the worker at each query,
  so a domain the principal starts later is in scope from its start.
* **Its work.** admit/3 decodes the request and refuses anything the
  interface does not take with `{error, badarg}`. Each request it admits
  runs in a query worker of its own (erx_inspect_worker:serve/3), started
  at the facet's scope, which the facet forwards the query to and whose
  answer it passes back; the grant's limit in flight, 2 in the default manifests, bounds
  the workers one grantee has at once. So a query that waits on a slow
  domain's agent holds up no other query, the facet's own included.
* **Its ends.** It ends with the grantee's domain pid and with
  erx_inspect_srv; a worker monitors the facet and ends with it, and a
  worker that ends without answering answers the grantee `{error, failed}`
  (erx_facet).

The grant's `worker` key, the worker's options (erx_inspect_worker:options()),
is for host tests, which stand fake agents and a view in for the domain
service; the domain service names none, and the worker then reads the
domain service's view (erx_inspector:view/1). It implements erx_facet's
callbacks without naming the behaviour, which a build that compiles erx's
modules in one pass cannot load first.
""".

-export([init/1, admit/3]).

-doc "The facet's state: the grant's scope and the options its workers run with.".
-spec init(erx_facet:grant()) -> {ok, #{scope := erx_inspector:query_scope(), worker := erx_inspect_worker:options()}}.
init(#{scope := Scope} = Grant) ->
    true = scope(Scope),
    {ok, #{scope => Scope, worker => maps:get(worker, Grant, #{view => fun erx_inspector:view/1})}}.

scope(all) -> true;
scope({principal, Principal}) -> is_integer(Principal) andalso Principal > 0;
scope(_Scope) -> false.

-doc """
A query the interface takes is forwarded to a worker started for it at the
facet's scope; anything else is refused with `{error, badarg}`.
""".
-spec admit(term(), pid(), map()) -> {forward, pid(), erx_inspect_worker:query(), map()} | {refuse, badarg, map()}.
admit(Request, _From, #{scope := Scope, worker := Options} = State) ->
    case erx_inspect_query:decode(Request) of
        {ok, Query} -> {forward, erx_inspect_worker:serve(self(), Scope, Options), Query, State};
        {error, badarg} -> {refuse, badarg, State}
    end.
