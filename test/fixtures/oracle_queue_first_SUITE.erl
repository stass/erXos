%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
-module(oracle_queue_first_SUITE).
-moduledoc false.
-export([all/0, first/1]).
all() -> [first].
first(_Config) ->
    case os:getenv("ERX_ABORT_SELECTION") of
        "true" -> {ok, _Controller} = gen_server:call(test_server_ctrl, {finish, abort});
        _ -> ok
    end,
    ok.
