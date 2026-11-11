%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_runtime).
-moduledoc """
The runtime's seam (docs/design-network-stack.md, "Two places, four seams"): what a stack
process asks of the runtime it runs on. `erx_net_erxos` implements it in a network domain,
`erx_net_local` (in `portable/`) outside erXos; the stack's `runtime` key chooses one.

A grant and every socket call `serve/1` as they start; minting a grant calls
`start_grant/2`; the stack's supervisor starts the runtime's own children, which
`children/0` names, after its tables, grants and interfaces.
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
The runtime's own children of the stack's supervisor, each an id and the function that
starts it linked to the caller, started in the order given after the tables, grants and
interfaces: the node's grant `local`, and where a domain service asks the stack for
grants, the mints of the services it provides. erx_net_sup makes each a permanent worker
under a supervisor that restarts no child, so the end of any of them ends the stack.
""".
-callback children() -> [{Id :: atom(), Start :: {module(), atom(), [term()]}}].
