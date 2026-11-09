%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_app).
-moduledoc "The domain service's application: starts erx_domain_sup.".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_domain_sup:start_link().

stop(_State) ->
    ok.
