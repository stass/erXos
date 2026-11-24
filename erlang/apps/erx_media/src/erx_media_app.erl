%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_app).
-moduledoc """
The media domain's application (docs/design-drives.md): it starts erx_media_sup, under
which each drive of the registry gets its drive process at the first ask for it. It
mounts no facet in the namespace (erx_ns:mount_facets/1): the domain's facets are its
drives, `{drive, N}`, which are no files facet and have no mount point.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc false.
start(_Type, _Args) ->
    erx_media_sup:start_link().

-doc false.
stop(_State) ->
    ok.
