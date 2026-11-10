%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_erl).
-moduledoc """
`erl`: runs an Erlang shell on the shell's terminal until it ends, and succeeds then.

The shell runs on a group of its own above the command shell, through
the run_shell of the terminal in the context (erx_console:run_shell/1),
which waits in this command and reads on once it ends: `q()` and
`exit()` end it, while `init:stop()` and `halt()` still stop the system. Its banner names no `Ctrl-G`, which on the console opens
the console's menu, never the Erlang shell's job control. A shell that
ends with a reason other than `normal` fails the command with that reason;
with no terminal, as in a script, it fails with `no_terminal`.
""".

-behaviour(erx_cmd).
-erx_command(erl).
-erx_usage("erl").

-export([run/2]).

run([], #{run_shell := RunShell}) ->
    case RunShell({shell, start, [true]}) of
        ok -> ok;
        {error, Reason} -> {error, {shell_ended, Reason}}
    end;
run([], _Ctx) ->
    {error, no_terminal};
run(_Args, _Ctx) ->
    {error, usage}.
