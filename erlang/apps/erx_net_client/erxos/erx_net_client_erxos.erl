%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_client_erxos).
-moduledoc """
The client's erXos module (docs/design-network-stack.md, "Answers from the grant", "Two
places, four seams"), built only into erXos's images: the one module of erx_net_client
that calls into erXos, so the modules in src/ stay portable.
""".

-export([grant/0]).

-doc """
The grant of a domain whose network service runs in another domain, for the `grant` key
as `{erx_net_client_erxos, grant, []}`: the `net` facet the domain holds (erx:cap/1),
with its owner, the network domain, as the origin whose envelope its messages arrive in
(erx:owner/1); `{error, enotconn}` while the domain holds no `net` facet, as
erx_net:local_grant/0 answers without a stack. Only erx_inet calls it, through the key.
""".
-spec grant() -> {ok, pid(), pos_integer()} | {error, enotconn}.
grant() ->
    case erx:cap(net) of
        undefined -> {error, enotconn};
        Grant -> {ok, Grant, erx:owner(Grant)}
    end.
