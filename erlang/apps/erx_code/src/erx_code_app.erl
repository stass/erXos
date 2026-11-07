%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The code service's application: the release's boot script starts it after erx, as it
%% starts every application of tools/lib/erx/erlang_apps.rb, and it starts erx_code_sup.

-module(erx_code_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_code_sup:start_link().

stop(_State) ->
    ok.
