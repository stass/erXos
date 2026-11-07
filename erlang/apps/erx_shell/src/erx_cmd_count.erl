%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_count).
-moduledoc """
`count`: one record, `count`, of how many records or lines its input
held.
""".

-behaviour(erx_cmd).
-erx_command(count).
-erx_usage("count").
-erx_fields([count]).

-export([run/2]).

run([], Ctx) ->
    erx_cmd:emit(Ctx, #{count => {runtime, {ok, count(Ctx, 0)}}});
run(_Args, _Ctx) ->
    {error, usage}.

count(Ctx, Seen) ->
    case erx_cmd:read(Ctx) of
        eof -> Seen;
        _Item -> count(Ctx, Seen + 1)
    end.
