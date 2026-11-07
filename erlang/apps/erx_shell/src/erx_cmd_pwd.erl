%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_pwd).
-moduledoc "`pwd`: writes the shell's working directory.".

-behaviour(erx_cmd).
-erx_command(pwd).
-erx_usage("pwd").

-export([run/2]).

run([], Ctx) -> erx_cmd:emit(Ctx, [erx_cmd:cwd(Ctx), $\n]);
run(_Args, _Ctx) -> {error, usage}.
