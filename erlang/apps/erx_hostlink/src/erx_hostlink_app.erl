%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The host link's application: the release's boot script starts it after erx_uart and erx_code,
%% which it needs, as tools/lib/erx/erlang_apps.rb orders them, and it starts erx_hostlink_sup.
-module(erx_hostlink_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_hostlink_sup:start_link().

stop(_State) ->
    ok.
