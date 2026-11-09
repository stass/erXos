%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net).
-moduledoc """
The stack's face towards its clients outside erXos (docs/design-network-stack.md,
"Running on a development host"): `local_grant/0` is what `erx_net_client`'s `grant` key
names on a node that runs the stack itself, `{erx_net, local_grant, []}`.
""".

-export([local_grant/0]).

-doc "The node's own grant, `local`, which erx_net_sup started.".
-spec local_grant() -> {ok, pid()} | {error, enotconn}.
local_grant() ->
    case whereis(erx_net_grant) of
        undefined -> {error, enotconn};
        Pid -> {ok, Pid}
    end.
