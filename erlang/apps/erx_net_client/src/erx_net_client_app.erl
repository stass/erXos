%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The socket backends' application: it starts erx_net_client_sup, whose one child is
%% erx_inet's resolver loader. The backends themselves are library modules and need no
%% process.
-module(erx_net_client_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_net_client_sup:start_link().

stop(_State) ->
    ok.
