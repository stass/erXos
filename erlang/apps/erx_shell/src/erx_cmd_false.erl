%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_false).
-moduledoc "`false`: fails with the status `1`, as a program that exits 1 does.".

-behaviour(erx_cmd).
-erx_command(false).
-erx_usage("false").

-export([run/2]).

run(_Args, _Ctx) -> {error, {reported, <<"1">>}}.
