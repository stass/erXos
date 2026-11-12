%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock_test_app).
-moduledoc """
The test-only application erx_clock_test, which only a test image's domain boot
script boots (tools/lib/erx/erlang_apps.rb, TEST_ONLY): the app of the apps
suite (tools/lib/erx/apps.rb). Its one process, erx_clock_test:report/0, logs
once what the session holds and then waits, so the session runs until it is
ended from outside.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, spawn_link(erx_clock_test, report, [])}.

stop(_State) ->
    ok.
