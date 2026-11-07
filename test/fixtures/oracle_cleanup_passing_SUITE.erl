%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_cleanup_passing_SUITE).
-moduledoc false.
-export([all/0, reads_data/1, writes_priv/1]).

all() -> [reads_data, writes_priv].

%% Passes only when the suite's _data copy is in place when it runs.
reads_data(Config) ->
    Data = proplists:get_value(data_dir, Config),
    {ok, <<"payload\n">>} = file:read_file(filename:join(Data, "payload.txt")),
    ok.

%% Leaves a file in priv_dir, as OTP's suites do.
writes_priv(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    ok = file:write_file(filename:join(Priv, "scratch"), <<0:8192>>).
