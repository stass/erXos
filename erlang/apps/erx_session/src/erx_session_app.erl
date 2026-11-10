%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The session domain's application: the release's boot script starts it after erx, as it
%% starts every application of tools/lib/erx/erlang_apps.rb, and it starts erx_session_sup.

-module(erx_session_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_session_sup:start_link().

stop(_State) ->
    ok.
