%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_client_erxos).
-moduledoc """
The client's erXos module (docs/design-network-stack.md, "Answers from the grant", "Two
places, four seams"), built only into erXos's images: the one module of erx_net_client
that calls into erXos, so the modules in src/ stay portable.
""".

-export([grant/0, expose/2]).

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

-doc """
Exposes `SockProc`, a socket process trapping exits, to `Origin`, the domain of its grant,
before its socket links to it: `Origin` comes to hold exactly `send` and `link` on it
(erx:export/3), so the socket can push to it and link to it, where a pid only handed out
holds `send` alone and a link to it fails as one to a dead process does
(docs/design-domains.md, "Exports"). Both rights are named, since erx:export/3 sets a
holder's rights to exactly the list given. Answers erx:export/3's refusal otherwise.
""".
-spec expose(pid(), pos_integer()) -> ok | {error, badarg | noconnection | system_limit}.
expose(SockProc, Origin) ->
    erx:export(SockProc, [send, link], Origin).
