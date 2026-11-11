%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_local).
-moduledoc """
The portable runtime (docs/design-network-stack.md, "Two places, four seams"), built only
outside erXos, so a network domain can never be configured with it. No message outside
erXos comes from another domain, so `serve/1` has no envelope to ask for and no lane to
limit, and doing nothing is correct, not merely harmless.
""".

-behaviour(erx_net_runtime).

-export([serve/1, start_grant/2, start_mint/0]).

-doc "Nothing to do: every request comes from the node's own processes.".
-spec serve(pos_integer()) -> ok.
serve(MaxRequest) when is_integer(MaxRequest), MaxRequest > 0 ->
    ok.

-doc """
Starts the node's grant, `local`, linked to the caller (erx_net_sup); a grant for another
domain has no meaning outside erXos.
""".
-spec start_grant(local | {pos_integer(), port(), module()}, map()) -> {ok, pid()} | {error, term()}.
start_grant(local, Limits) ->
    erx_net_grant:start_link(local, Limits);
start_grant(_Grantee, _Limits) ->
    {error, enotsup}.

-doc "No mint: outside erXos no domain service asks for a grant.".
-spec start_mint() -> ignore.
start_mint() ->
    ignore.
