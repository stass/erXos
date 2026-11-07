%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_cleanup_passing_SUITE).
-moduledoc false.
-export([all/0, reads_data/1, writes_priv/1, priv_dir_under_cwd/1]).

all() -> [reads_data, writes_priv, priv_dir_under_cwd].

%% Passes only when the suite's _data copy is in place when it runs.
reads_data(Config) ->
    Data = proplists:get_value(data_dir, Config),
    {ok, <<"payload\n">>} = file:read_file(filename:join(Data, "payload.txt")),
    ok.

%% Leaves a file in priv_dir, as OTP's suites do.
writes_priv(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    ok = file:write_file(filename:join(Priv, "scratch"), <<0:8192>>).

%% Makes a directory in priv_dir by its path relative to the current
%% directory, as tar_SUITE:borderline does to keep its names short: in
%% stock Common Test the current directory is the run directory and
%% priv_dir is its log_private.
priv_dir_under_cwd(Config) ->
    {ok, Cwd} = file:get_cwd(),
    Priv = proplists:get_value(priv_dir, Config),
    Relative = string:prefix(filename:join(Priv, "short"), Cwd ++ "/"),
    true = is_list(Relative),
    ok = file:make_dir(Relative).
