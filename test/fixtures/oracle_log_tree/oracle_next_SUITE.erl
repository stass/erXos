%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_next_SUITE).
-moduledoc false.
-export([all/0, writes_priv/1]).

all() -> [writes_priv].

%% Runs after the fill suites, by name, and passes only when their
%% priv_dirs are gone and this one's is writable.
writes_priv(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    ok = file:write_file(filename:join(Priv, "scratch"), <<0:8192>>).
