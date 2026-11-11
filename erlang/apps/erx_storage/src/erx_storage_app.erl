%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_storage_app).
-moduledoc "The storage domain's application: its supervisor (erx_storage_sup).".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_storage_sup:start_link().

stop(_State) ->
    ok.
