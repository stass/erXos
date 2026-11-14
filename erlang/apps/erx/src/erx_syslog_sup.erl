%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_syslog_sup).
-moduledoc """
The log service's supervisor (docs/design-log.md, "Service lifetime and
restart"): it restarts erx_syslog at most four times an hour, as
kernel_safe_sup restarts its children, and past that it ends. It is a
temporary child of kernel_sup, started after the watchdog and before
user_sup, so the service's first take precedes the console driver's first
write, and its end is neither restarted nor counted by kernel_sup: the
machine runs on without a log service, as it runs on without erx_console.

It is also what the log facets end with: it names itself the server of the
`log` interface (erx_facet:serve/2), so each log facet the domain service
mints stands in front of it and outlives the service's restarts, finding
erx_syslog by its name at each request (erx_log_facet).
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-doc """
Starts the supervisor, registered as erx_syslog_sup, and the service under it,
in the system domain's runtime, the one whose `user` is the system console
(user_sup's rule); in every other domain kernel_sup's child is ignored, and
erx_log_h sends that domain's records to its proxy.
""".
-spec start_link() -> supervisor:startlink_ret() | ignore.
start_link() ->
    case lists:member({user, ["erx_console"]}, init:get_arguments()) of
        true -> supervisor:start_link({local, ?MODULE}, ?MODULE, []);
        false -> ignore
    end.

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    ok = erx_facet:serve(log, self()),
    {ok, {#{strategy => one_for_one, intensity => 4, period => 3600},
          [#{id => erx_syslog,
             start => {erx_syslog, start_link, []},
             restart => permanent,
             shutdown => 2000,
             type => worker,
             modules => [erx_syslog]}]}}.
