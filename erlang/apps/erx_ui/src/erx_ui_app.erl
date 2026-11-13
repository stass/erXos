%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_app).
-moduledoc """
The application `erx_ui`, the widget toolkit (docs/design-display.md,
"The widget server"). The release of every domain that shows widgets
starts it as a permanent application, so the end of its supervisor
erx_ui_sup, under which erx_ui:open/1 starts each widget server, ends the
domain. The display domain's release does not hold the application (G9).
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_ui_sup:start_link().

stop(_State) ->
    ok.
