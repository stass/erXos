%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_true).
-moduledoc "`true`: succeeds.".

-behaviour(erx_cmd).
-erx_command(true).
-erx_usage("true").

-export([run/2]).

run(_Args, _Ctx) -> ok.
