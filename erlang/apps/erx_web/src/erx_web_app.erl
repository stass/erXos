%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_app).
-moduledoc "The web domain's application: its supervisor (erx_web_sup).".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_web_sup:start_link().

stop(_State) ->
    ok.
