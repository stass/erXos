%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_app).
-moduledoc """
The start service's application (docs/design-apps.md, "Keeping a
session"): starts erx_starter_sup. The system release starts it after
erx_domain, whose /data mount and domain service it uses.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_starter_sup:start_link().

stop(_State) ->
    ok.
