%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx).
-moduledoc """
erXos's functions for a person at an Erlang shell in any domain
(docs/design-live.md, "Erlang, in every domain"). Each is a thin entry
to the module that does the work, with that module's authority and no
authority of its own.
""".

-export([source/1]).

-doc """
Prints the source lines around a process's current location, or around a
function's first line (erx_source). `{error, unsupported}` when the
module's source cannot be shown, `{error, scope}` for a pid that names no
live process, and `{error, unsupported}` for a pid of another runtime,
whose source only the inspector reaches.
""".
-spec source(pid() | mfa()) -> ok | {error, erx_source:reason()}.
source(Target) ->
    erx_source:print(Target).
