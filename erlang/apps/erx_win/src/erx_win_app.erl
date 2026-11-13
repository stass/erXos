%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_win_app).
-moduledoc """
The application `erx_win`, a display client's side of the window system,
which a release starts as a permanent application wherever its domain holds
a display's grant: starts erx_win_sup, and so the allocator erx_pixels
(docs/design-display.md, "The pixel area"). The display domain's release
does not hold the application, so no allocator runs over the display's
read-only mappings.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_win_sup:start_link().

stop(_State) ->
    ok.
