%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_sup).
-moduledoc """
The system console's supervisor (docs/design-live.md, "Failure handling,
diagnostics and debuggability"), which user_sup starts as kernel_sup's `user`
child. Its one child is the console (erx_console), which it starts again
whenever it ends: the restarted console writes the slogan and starts its
command shell on the line, and registers a new `user` group, which every
application's processes reach by name: their application master's group
leader is init, and the master and init look `user` up for each request.
When the console ends more often than the intensity allows, the supervisor
gives up and ends, and with it user_sup, kernel_sup's `temporary` child,
which kernel_sup neither restarts nor counts (otp/lib/kernel/src/kernel.erl),
as for erx_syslog_sup (docs/design-log.md, "Service lifetime and restart"):
the machine runs on without a console, and a request to `user` then waits
for ever (TODO.md).
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-doc "Starts the supervisor, registered as erx_console_sup, and the console under it.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Console = #{id => erx_console,
                start => {erx_console, start_link, []},
                restart => permanent,
                shutdown => 2000,
                type => worker,
                modules => [erx_console]},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Console]}}.
