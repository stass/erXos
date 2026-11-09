%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_sup).
-moduledoc """
The domain service's supervisor (docs/design-system.md, "System services"):
the table holder first, then the service, rest for one. The holder is the heir
of the service's table, so a crash of the service hands the table back to it
and the restarted service serves on from it. The holder is significant and
never restarted: its end loses the table while the library's domains live
on, so a new service would boot the manifest again and hand out ids the
library still holds. Its end shuts the supervisor down instead, which ends
the permanent application and the system domain with it, as any fault of
the system domain does.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Table = #{id => erx_domain_table, start => {erx_domain_table, start_link, []},
              restart => temporary, significant => true, shutdown => 2000, type => worker,
              modules => [erx_domain_table]},
    Service = #{id => erx_domain_srv, start => {erx_domain_srv, start_link, []},
                restart => permanent, shutdown => 5000, type => worker, modules => [erx_domain_srv]},
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10, auto_shutdown => any_significant},
          [Table, Service]}}.
