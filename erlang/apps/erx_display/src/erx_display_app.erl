%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_display_app).
-moduledoc """
The application `erx_display` in a client domain's release, which starts it
as a permanent application wherever the domain holds a display's grant:
starts erx_display_sup, and so the allocator erx_pixels
(docs/design-display.md, "The pixel area"). The display domain's release only
loads the application, so no allocator runs over the display's read-only
mappings.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    erx_display_sup:start_link().

stop(_State) ->
    ok.
