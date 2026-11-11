%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_sup).
-moduledoc """
The domain service's supervisor (docs/design-system.md, "System services").
The service is its one child, temporary and significant, so it is never
restarted: its end, however it comes, kill included, shuts the supervisor
down, which ends the permanent application and the system domain with it,
outside an ordered end, as any fault of the system domain does. The
service's records of every domain live in its own heap, and no successor
needs them, since no domain outlives the system domain.

Beside it runs `/dev`'s control tree, erx_devfs, a permanent child that
mounts itself at `/dev` in the system domain's namespace; it keeps no
state, so a restarted one serves the same tree.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Service = #{id => erx_domain_srv, start => {erx_domain_srv, start_link, []},
                restart => temporary, significant => true, shutdown => 5000, type => worker,
                modules => [erx_domain_srv]},
    Dev = #{id => erx_devfs, start => {erx_devfs, start_link, []},
            restart => permanent, shutdown => brutal_kill, type => worker,
            modules => [erx_devfs]},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant},
          [Service, Dev]}}.
