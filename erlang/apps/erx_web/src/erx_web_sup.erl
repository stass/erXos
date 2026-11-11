%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_sup).
-moduledoc """
The web domain's supervisor (docs/design-web.md, "Overview"). Its one child
is the relay of the host link's `web` facet (erx_web_relay), the mint of the
service `web` and its connections' owner, permanent under a restart
intensity of 0: the domain service holds the mint until the domain ends, so
its end ends this supervisor and erx_web, a permanent application, and so
the web domain, whose restart provides the service again.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    Relay = #{id => erx_web_relay,
              start => {erx_web_relay, start_link, [#{system => erx_kernel_records:system_domain()}]},
              restart => permanent,
              shutdown => brutal_kill,
              type => worker,
              modules => [erx_web_relay, erx_web_relay_conn]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, [Relay]}}.
