%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(oracle_abort_SUITE).
-moduledoc false.
-export([all/0, first/1, second/1]).

all() -> [first, second].
first(_Config) -> ok.
second(_Config) -> erlang:error(aborted_job_reached_second_case).
