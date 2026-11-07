%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_fill_fail_SUITE).
-moduledoc false.
-export([all/0, init_per_suite/1, end_per_suite/1, never/1]).

all() -> [never].

%% Runs after oracle_fill_SUITE, by name, fills priv_dir's tree and fails,
%% so Common Test skips the case and end_per_suite, and the suite after it
%% starts with the tree still full unless the hook deletes the priv_dir.
init_per_suite(Config) ->
    ok = oracle_fill:fill(proplists:get_value(priv_dir, Config)),
    {fail, deliberate}.

end_per_suite(_Config) -> ok.

never(_Config) -> ok.
