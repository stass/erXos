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

-export([serve/1, start_grant/2, start_mint/0]).
-export([mint_init/1]).

-doc "Nothing to do: every request comes from the system domain's own processes.".
-spec serve(pos_integer()) -> ok.
serve(MaxRequest) when is_integer(MaxRequest), MaxRequest > 0 ->
    ok.

-doc """
Starts the grant of `Grantee`, the system domain's own (`local`) or another domain's,
linked to the caller (erx_net_sup or its grant supervisor).
""".
-spec start_grant(local | pos_integer(), map()) -> {ok, pid()} | {error, term()}.
start_grant(Grantee, Limits) ->
    erx_net_grant:start_link(Grantee, Limits).

-doc """
Starts the network service's mint (docs/design-system.md, "Facets a configured domain
serves"): it names itself the mint of `net` (erx_facet:provide/2) and then, for each
request erx_net_admit:mint/2 takes from the system domain's envelope, starts the
grantee's grant with erx_net:mint_grant/2 and answers through erx_facet:minted/2, the
grant's pid or the refusal. Every other message is dropped. Until the network domain
exists the stack runs in the system domain, which no domain service asks for a grant.
""".
-spec start_mint() -> {ok, pid()}.
start_mint() ->
    proc_lib:start_link(?MODULE, mint_init, [self()]).

-doc false.
mint_init(Parent) ->
    ok = erx_facet:provide(net, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    mint(erx_kernel_records:system_domain()).

mint(System) ->
    receive
        Message ->
            case erx_net_admit:mint(System, Message) of
                {ok, Tag, Grantee, Limits} -> _ = erx_facet:minted(Tag, erx_net:mint_grant(Grantee, Limits));
                unknown -> ok
            end,
            mint(System)
    end.
