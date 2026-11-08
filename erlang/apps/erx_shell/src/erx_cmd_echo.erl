%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_echo).
-moduledoc "`echo [-n] [arg ...]`: writes its arguments separated by spaces, and a newline unless `-n`.".

-behaviour(erx_cmd).
-erx_command(echo).
-erx_usage("echo [-n] [arg ...]").

-export([run/2]).

run([<<"-n">> | Args], Ctx) ->
    erx_cmd:write(Ctx, lists:join($\s, Args));
run(Args, Ctx) ->
    erx_cmd:write(Ctx, [lists:join($\s, Args), $\n]).
