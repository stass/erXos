%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The socket backends' supervisor: erx_inet's resolver loader, restarted after a crash.
%% A restarted loader finds the grant again and reloads inet_db from its answer.
-module(erx_net_client_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Loader = #{id => erx_inet,
               start => {erx_inet, start_link, []},
               restart => permanent,
               shutdown => 2000,
               type => worker,
               modules => [erx_inet]},
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [Loader]}}.
