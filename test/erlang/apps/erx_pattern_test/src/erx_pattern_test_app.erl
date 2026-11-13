%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pattern_test_app).
-moduledoc """
The test-only application erx_pattern_test, which only a test image's domain
boot script boots (tools/lib/erx/erlang_apps.rb, TEST_ONLY): the client of
the display suite (tools/lib/erx/display_domain.rb). Its one process,
erx_pattern_test:show/0, opens a window, presents the pattern once and then
waits, holding the window, until the session is ended from outside.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, spawn_link(erx_pattern_test, show, [])}.

stop(_State) ->
    ok.
