%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_fill_SUITE).
-moduledoc false.
-export([all/0, init_per_suite/1, end_per_suite/1, after_fill/1]).

all() -> [after_fill].

%% Fills priv_dir's tree and goes on.
init_per_suite(Config) ->
    ok = oracle_fill:fill(proplists:get_value(priv_dir, Config)),
    Config.

end_per_suite(_Config) -> ok.

%% Passes once Common Test can still log the case the full tree follows.
after_fill(_Config) -> ok.
