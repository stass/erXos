%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_runtime).
-moduledoc """
The runtime's seam (docs/design-network-stack.md, "Two places, four seams"): what a stack
process asks of the runtime it runs on. `erx_net_erxos` implements it in a network domain,
`erx_net_local` (in `portable/`) outside erXos; the stack's `runtime` key chooses one.

A grant and every socket call `serve/1` as they start; minting a grant calls
`start_grant/2`; the stack's supervisor starts the network service's mint with
`start_mint/0`.
""".

-doc """
The calling process takes requests from other domains: they arrive enveloped with their
origin, at most `MaxRequest` at once.
""".
-callback serve(MaxRequest :: pos_integer()) -> ok.

-doc "Starts a grant for `Grantee` with `Limits`.".
-callback start_grant(Grantee :: local | {pos_integer(), port(), module()}, Limits :: map()) ->
    {ok, pid()} | {error, Reason :: term()}.

-doc """
Starts the network service's mint, linked to the caller, the process that takes the
system domain's requests for a client's grant and starts each with erx_net:mint_grant/4;
`ignore` where no domain service sends any.
""".
-callback start_mint() -> {ok, pid()} | ignore.
