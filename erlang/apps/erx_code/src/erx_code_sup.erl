%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The code service's supervisor: erx_code, restarted after a crash. A restarted service
%% starts with an empty store and no history, as after a reboot; the modules it loaded stay
%% loaded, and the host sends their blobs again with its next load.

-module(erx_code_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Service = #{id => erx_code,
                start => {erx_code, start_link, []},
                restart => permanent,
                shutdown => 2000,
                type => worker,
                modules => [erx_code]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [Service]}}.
