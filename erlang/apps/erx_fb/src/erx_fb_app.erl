%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The display drivers' application: its supervisor, erx_fb_sup, starts the driver of the
%% domain's display device and the screen over it.

-module(erx_fb_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Arguments) ->
    erx_fb_sup:start_link().

stop(_State) ->
    ok.
