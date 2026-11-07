%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_basic_runner).
-moduledoc """
The interactive shell's runner until the command namespace exists
(docs/design-shell.md, "Commands"): rc's language at a terminal, with the
commands `echo` (with `-n`), `true` and `false` and nothing else.

Descriptors 1 and 2 are the terminal, written as bytes. Globbing finds
nothing, so a pattern stays as written. Redirections, pipelines,
substitutions, background blocks and subshells are refused with a fault,
which ends the line with a diagnostic, and a command it does not know
gives the status `not found`. erx_shell builds it with new/1, as it
builds any runner.
""".

-export([new/1]).

-doc "The runner and its state, over the terminal the shell runs on.".
-spec new(erx_shell:terminal()) -> {erx_shell_eval:runner(), erx_shell:terminal()}.
new(Terminal = #{write := _}) ->
    {fun request/2, Terminal}.

request({run, [Name | Args], _Vars}, Terminal) ->
    {command(Name, Args, Terminal), Terminal};
request({write, _Fd, Bytes}, Terminal) ->
    {write(Bytes, Terminal), Terminal};
request({glob, _Pattern}, Terminal) ->
    {[], Terminal};
request({whatis, Name}, Terminal) ->
    case lists:member(Name, [<<"echo">>, <<"true">>, <<"false">>]) of
        true -> {{found, Name}, Terminal};
        false -> {not_found, Terminal}
    end;
request(_Unsupported, Terminal) ->
    {{fault, <<"the stand-in runner runs no redirection, pipeline, substitution, "
              "background block or subshell">>},
     Terminal}.

command(<<"echo">>, [<<"-n">> | Args], Terminal) ->
    ok = write(lists:join(<<" ">>, Args), Terminal),
    <<>>;
command(<<"echo">>, Args, Terminal) ->
    ok = write([lists:join(<<" ">>, Args), $\n], Terminal),
    <<>>;
command(<<"true">>, _Args, _Terminal) ->
    <<>>;
command(<<"false">>, _Args, _Terminal) ->
    <<"1">>;
command(_Name, _Args, Terminal) ->
    %% The name is not echoed: it may come from a variable or a substitution,
    %% and this runner has no escaper to show it through.
    ok = write(<<"rc: command not found\n">>, Terminal),
    <<"not found">>.

write(Bytes, #{write := Write}) ->
    Write(Bytes).
