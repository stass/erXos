%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_basic_runner).
-moduledoc """
A small runner for erx_shell's tests (test/erlang/erx_shell_tests.erl):
rc's language at a terminal with no file system and no command
namespace, so the interactive layer is tested apart from
erx_shell_runner, the runner the shell runs by default.

Its commands are `echo` (with `-n`), `true` and `false`; `start NAME`,
which starts a process registered as NAME that starts another registered
as NAME_child, both of which wait forever, and returns; and `hang`, which
waits forever; and `spin NAME`, which registers itself as NAME and waits
forever. Descriptors 1 and 2 are the terminal, written as bytes.
Globbing finds nothing, so a pattern stays as written. A background
block runs as erx_shell_runner runs one: on the shell's own line it is a
job of its own (erx_shell:background/2), and inside a job it runs apart
in that job; `jobs`, `fg`, `bg` and `kill` are erx_shell:builtin/3's.
Redirections, pipelines, substitutions and subshells are refused with a
fault, which ends the line with a diagnostic, and a command it does not
know gives the status `not found`. erx_shell builds it with new/1, as it
builds any runner.
""".

-export([new/1]).

-define(JOB_BUILTINS, [<<"jobs">>, <<"fg">>, <<"bg">>, <<"kill">>]).

-doc "The runner and its state, over the terminal the shell runs on.".
-spec new(erx_shell:terminal()) -> {erx_shell_eval:runner(), erx_shell:terminal()}.
new(Terminal = #{write := _}) ->
    JobControl = case Terminal of
                     #{job_control := Shell} -> {Shell, line};
                     _ -> none
                 end,
    {fun request/2, Terminal#{job_control => JobControl}}.

request({run, [Name | Args], _Vars}, Terminal = #{job_control := JobControl}) ->
    case lists:member(Name, ?JOB_BUILTINS) of
        true ->
            {Status, Out, Err} = erx_shell:builtin(Name, Args, JobControl),
            [ok = write(Bytes, Terminal) || Bytes <- [Out, Err], iolist_size(Bytes) > 0],
            {Status, Terminal};
        false ->
            {command(Name, Args, Terminal), Terminal}
    end;
request({background, Body}, Terminal = #{job_control := JobControl}) ->
    Apart = Terminal#{job_control := apart(JobControl)},
    Run = fun() -> {Status, _} = Body(Apart), Status end,
    case JobControl of
        {Shell, line} ->
            case erx_shell:background(Shell, Run) of
                {ok, _Id} -> ok;
                {error, _Reason} -> _ = spawn(Run)
            end;
        _ ->
            _ = spawn(Run)
    end,
    {<<>>, Terminal};
request({write, _Fd, Bytes}, Terminal) ->
    {write(Bytes, Terminal), Terminal};
request({glob, _Pattern}, Terminal) ->
    {[], Terminal};
request({whatis, Name}, Terminal) ->
    case lists:member(Name, [<<"echo">>, <<"true">>, <<"false">>, <<"start">>, <<"hang">>,
                             <<"spin">> | ?JOB_BUILTINS]) of
        true -> {{found, Name}, Terminal};
        false -> {not_found, Terminal}
    end;
request(_Unsupported, Terminal) ->
    {{fault, <<"the test runner runs no redirection, pipeline, substitution "
              "or subshell">>},
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
command(<<"start">>, [Name], _Terminal) ->
    Parent = binary_to_atom(Name),
    Child = binary_to_atom(<<Name/binary, "_child">>),
    Self = self(),
    _ = spawn(fun() ->
                      true = register(Parent, self()),
                      _ = spawn(fun() -> true = register(Child, self()), Self ! Name, wait() end),
                      wait()
              end),
    receive Name -> <<>> end;
command(<<"hang">>, [], _Terminal) ->
    wait();
command(<<"spin">>, [Name], _Terminal) ->
    true = register(binary_to_atom(Name), self()),
    wait();
command(_Name, _Args, Terminal) ->
    %% The name is not echoed: it may come from a variable or a substitution,
    %% and this runner has no escaper to show it through.
    ok = write(<<"rc: command not found\n">>, Terminal),
    <<"not found">>.

write(Bytes, #{write := Write}) ->
    Write(Bytes).

wait() ->
    receive after infinity -> ok end.

%% A piece run apart may list and signal jobs, but not start or move them.
apart({Shell, _Where}) -> {Shell, apart};
apart(none) -> none.
