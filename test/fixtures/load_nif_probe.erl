%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Asks to load a NIF library from a module's own code, as load_nif/2 requires.
-module(load_nif_probe).
-export([go/1]).

go(Path) -> erlang:load_nif(Path, 0).
