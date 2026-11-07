%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_cleanup_trailing_SUITE).
-moduledoc false.
-export([all/0, init_per_suite/1, end_per_suite/1, never/1]).

all() -> [never].

%% Runs last and fails after leaving a file in priv_dir, so Common Test skips the case
%% and end_per_suite.
init_per_suite(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    ok = file:write_file(filename:join(Priv, "scratch"), <<0:8192>>),
    {fail, deliberate}.

end_per_suite(_Config) -> ok.

never(_Config) -> ok.
