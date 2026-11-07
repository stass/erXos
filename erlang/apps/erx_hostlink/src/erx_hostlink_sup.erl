%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The host link's supervisor: erx_hostlink, restarted after a crash. A restart ends the
%% session and its facets, as a machine reset does for the host: the tool sees no reply to
%% its calls, opens a new session with a hello, and reports the outcome of calls whose
%% replies never arrived as unknown (docs/design-live.md, "The host link"). A machine
%% without a host link starts nothing: erx_hostlink's init/1 returns ignore.
-module(erx_hostlink_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Link = #{id => erx_hostlink,
             start => {erx_hostlink, start_link, []},
             restart => permanent,
             shutdown => 2000,
             type => worker,
             modules => [erx_hostlink]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [Link]}}.
