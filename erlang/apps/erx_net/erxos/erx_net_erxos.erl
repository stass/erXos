%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_erxos).
-moduledoc """
erXos's runtime (docs/design-network-stack.md, "Two places, four seams"), built only into
erXos's images.

The stack runs in the system domain in Phase 1, the stopgap placement of the network
domain, and no socket of it is exported to another domain: every request comes from the
system domain's own processes, so `serve/1` has no envelope to take off and no lane to
limit, as for the portable runtime. The network domain's runtime replaces this once that
domain exists: it takes requests out of their envelope, `{erx_origin, D, Request}`, and
runs each grant under its ERTS's request limit and `erx_facet`.
""".

-behaviour(erx_net_runtime).

-export([serve/1, start_grant/2]).

-doc "Nothing to do: every request comes from the system domain's own processes.".
-spec serve(pos_integer()) -> ok.
serve(MaxRequest) when is_integer(MaxRequest), MaxRequest > 0 ->
    ok.

-doc """
Starts the system domain's grant, `local`, linked to the caller (erx_net_sup); a grant for
another domain waits for the network domain.
""".
-spec start_grant(local | pos_integer(), map()) -> {ok, pid()} | {error, term()}.
start_grant(local, Limits) ->
    erx_net_grant:start_link(local, Limits);
start_grant(_Grantee, _Limits) ->
    {error, enotsup}.
