%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_sup).
-moduledoc """
The session's supervisor. Its children are the session's pipe server
(erx_pipe_srv), which a crash restarts for later pipes, and the session's tty relay
(erx_session_tty), which ends normally only when its line has hung up, with
every shell on it; the session then has no terminal, and nothing restarts it.
""".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Tty = #{id => erx_session_tty,
            start => {erx_session_tty, start_link, []},
            restart => transient,
            type => worker,
            modules => [erx_session_tty, erx_console]},
    Pipes = #{id => erx_pipe_srv,
              start => {erx_pipe_srv, start_link, []},
              restart => permanent,
              type => worker,
              modules => [erx_pipe_srv, erx_pipe]},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Pipes, Tty]}}.
