%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_app).
-moduledoc "The session application: its supervisor (erx_session_sup).".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_session_sup:start_link().

stop(_State) ->
    ok.
