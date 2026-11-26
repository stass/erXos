%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_tests).
-moduledoc """
erx_shell's interactive layer: its pure decisions, and its process driven
through a scripted group that answers each `get_line` with the next step
of a script and keeps what the shell showed, prompts and output in order.
""".

-include_lib("eunit/include/eunit.hrl").

-export([new/1, log/2]).

%%% The functional core

after_parse_test_() ->
    {ok, [Echo], <<>>} = erx_shell_parse:next(<<"echo a\n">>, more),
    Fresh = erx_shell:reader(<<>>),
    Open = erx_shell:reader(<<"{\n">>),
    Bad = {syntax, {1, 2}, <<"x">>},
    [?_assertMatch({{run, [Echo]}, _}, erx_shell:after_parse({ok, [Echo], <<>>}, Fresh, open)),
     ?_assertMatch({read, _}, erx_shell:after_parse({incomplete, {1, 4}, <<"x">>}, Open, open)),
     %% The input ended inside a unit: it is refused with what the parser said.
     ?_assertEqual({{refuse, {incomplete, {1, 4}, <<"x">>}}, Fresh},
                   erx_shell:after_parse({incomplete, {1, 4}, <<"x">>}, Open, ended)),
     ?_assertMatch({stop, _}, erx_shell:after_parse(eof, Fresh, ended)),
     %% A bad unit is refused with its diagnostic, and the next line starts afresh.
     ?_assertEqual({{refuse, Bad}, Fresh},
                   erx_shell:after_parse({error, Bad, <<>>}, erx_shell:reader(<<"x(\n">>), open))].

prompt_test_() ->
    Prompt = [<<"% ">>, <<"> ">>],
    [?_assertEqual(<<"% ">>, erx_shell:prompt(Prompt, erx_shell:reader(<<>>))),
     ?_assertEqual(<<"> ">>, erx_shell:prompt(Prompt, erx_shell:reader(<<"{\n">>))),
     ?_assertEqual(<<>>, erx_shell:prompt([<<"% ">>], erx_shell:reader(<<"{\n">>))),
     ?_assertEqual(<<>>, erx_shell:prompt([], erx_shell:reader(<<>>)))].

%%% The process, through a scripted group

session_test_() ->
    {timeout, 30,
     [?_assertEqual(
         [{prompt, <<"% ">>}, {out, <<"a b c\n">>},
          {prompt, <<"; ">>}, {out, <<"1\n">>}, {out, <<"2\n">>},
          {prompt, <<"; ">>}, {prompt, <<"> ">>}, {out, <<"in braces\n">>},
          {prompt, <<"; ">>}, {out, <<"rc: syntax error at line 1, column 7: unexpected ')'\n">>},
          {prompt, <<"; ">>}, {out, <<"was unexpected ')'\n">>},
          {prompt, <<"; ">>}],
         session([{line, <<"x=(a b c); prompt=('; ' '> '); echo $x\n">>},
                  {line, <<"for(i in 1 2) echo $i\n">>},
                  {line, <<"{\n">>}, {line, <<"echo in braces}\n">>},
                  {line, <<"echo a)\n">>},
                  {line, <<"echo was $status\n">>},
                  {line, <<"exit\n">>}])),
      %% Ctrl-C while editing drops the unit read so far; the end of input ends
      %% the shell.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {prompt, <<>>}, {out, <<"\n">>},
          {prompt, <<"% ">>}, {out, <<"after\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"{ echo before\n">>}, interrupted,
                  {line, <<"echo after\n">>}, eof])),
      %% Ctrl-C while a unit runs ends the unit, not the shell, which keeps
      %% what it had before the unit.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {prompt, <<"% ">>}, {out, <<"^C\n">>},
          {prompt, <<"% ">>}, {out, <<"kept\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"y=kept\n">>},
                  {interrupt, 1, <<"y=lost; while(true) true\n">>},
                  {line, <<"echo $y\n">>}, eof])),
      %% The input ending inside a unit reports what is missing.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {prompt, <<>>},
          {out, <<"rc: syntax error at line 2, column 1: expected '}'\n">>}],
         session([{line, <<"{\n">>}, eof])),
      %% A line the end of input ended, as the group's editor ends one when
      %% its input ends, has no newline: it runs, and the shell ends.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {out, <<"last\n">>}],
         session([{line, <<"echo last">>}])),
      ?_assertEqual([{prompt, <<"% ">>}], session([{line, <<>>}])),
      %% A second Ctrl-C while the first ends the line comes before the next line
      %% is read, and ends nothing.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {out, <<"^C\n">>},
          {prompt, <<"% ">>}, {out, <<"after\n">>}, {prompt, <<"% ">>}],
         session([{interrupt, 2, <<"while(true) true\n">>},
                  {line, <<"echo after\n">>}, eof])),
      %% The line Ctrl-C ended leaves `$status` saying it was interrupted, its
      %% last command's status having been empty.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {prompt, <<"% ">>}, {out, <<"^C\n">>},
          {prompt, <<"% ">>}, {out, <<"sigint\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"true\n">>},
                  {interrupt, 1, <<"while(true) true\n">>},
                  {line, <<"echo $status\n">>}, eof])),
      %% After an `if`, a unit starting `if not` may follow; a bad one is reported
      %% with what is wrong with it, which `$status` then holds.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {prompt, <<"% ">>}, {out, <<"b\n">>},
          {prompt, <<"% ">>}, {prompt, <<"% ">>},
          {out, <<"rc: syntax error at line 1, column 14: unexpected ')'\n">>},
          {prompt, <<"% ">>}, {out, <<"unexpected ')'\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"if(false) echo a\n">>}, {line, <<"if not echo b\n">>},
                  {line, <<"if(true) true\n">>}, {line, <<"if not echo b)\n">>},
                  {line, <<"echo $status\n">>}, eof])),
      %% A line that passes its heap limit ends with a diagnostic, and the shell
      %% keeps what it had before the line.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {out, <<"rc: the line passed its heap limit\n">>},
          {prompt, <<"% ">>}, {out, <<"\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"x=a; while(true) x=($x $x)\n">>},
                  {line, <<"echo $x\n">>}, eof])),
      %% A line whose runner crashes ends with a diagnostic, and the shell reads on.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {out, <<"rc: the line crashed\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"crash\n">>}, eof], ?MODULE)),
      %% A runner that crashes while the shell reports a unit that does not
      %% parse ends that report alone, and the shell reads on.
      ?_assertEqual(
         [{prompt, <<"% ">>}, {out, <<"rc: the line crashed\n">>}, {prompt, <<"% ">>}],
         session([{line, <<"echo a)\n">>}, eof], ?MODULE)),
      %% Neither crash reaches a log: a crash's reason and stack would carry
      %% the shell's variables and the runner's state.
      ?_assertEqual([], logged_by(fun() ->
                                          session([{line, <<"secret=hidden; crash\n">>},
                                                   {line, <<"echo a)\n">>}, eof], ?MODULE)
                                  end))]}.

%% Every process a line starts, and those they start, ends with the line
%% when Ctrl-C ends it; those a line leaves running when it ends of itself
%% run on, still under the line's leader, until the session ends, and
%% then end with it. `start` returns once both of its processes run,
%% before `hang`, so the interrupt finds them.
line_processes_test_() ->
    {timeout, 30,
     fun() ->
             Leader = fun() -> element(2, process_info(whereis(b), group_leader)) end,
             {Group, Shown} = session_group([{interrupt, 1, <<"start a; hang\n">>},
                                             {line, <<"start b\n">>},
                                             {check, Leader, eof}],
                                            erx_shell_basic_runner),
             ?assertMatch([{prompt, <<"% ">>}, {out, <<"^C\n">>},
                           {prompt, <<"% ">>}, {prompt, <<"% ">>}, {checked, _}], Shown),
             [{checked, LineLeader}] = [C || C = {checked, _} <- Shown],
             ?assert(is_pid(LineLeader) andalso LineLeader =/= Group),
             ?assertEqual([undefined, undefined], [whereis(a), whereis(a_child)]),
             ?assertEqual(gone, gone([b, b_child]))
     end}.

%%% Job control

%% The exit criterion's case (docs/plan.md, track S): a job whose block
%% starts a block that starts a block, three generations of processes, is
%% stopped, continued and ended, and each generation is seen paused,
%% running and gone.
three_generations_test_() ->
    {timeout, 30,
     fun() ->
             Names = [a, b, c],
             Shown = session([{line, <<"{ { spin c & spin b } & spin a } &\n">>},
                              {check, fun() -> started(Names) end, {line, <<"kill -STOP %1\n">>}},
                              {check, fun() -> statuses(Names) end, {line, <<"jobs\n">>}},
                              {check, fun() -> statuses(Names) end, {line, <<"bg %1\n">>}},
                              {check, fun() -> statuses(Names) end, {line, <<"kill %1\n">>}},
                              {check, fun() -> gone(Names) end, {line, <<"jobs\n">>}},
                              eof]),
             Checked = [C || {checked, C} <- Shown],
             Text = <<"{ { spin c & spin b } & spin a } &">>,
             ?assertEqual([generations, [suspended, suspended, suspended],
                           [suspended, suspended, suspended], [waiting, waiting, waiting],
                           gone], Checked),
             Out = iolist_to_binary([O || {out, O} <- Shown]),
             ?assertEqual(<<"[1]\n",
                            "[1] + Suspended               ", Text/binary, "\n",
                            "[1] + Suspended               ", Text/binary, "\n",
                            "[1] ", Text/binary, "\n",
                            "[1] + Terminated              ", Text/binary, "\n">>, Out)
     end}.

%% Ctrl-Z stops the line in the foreground and numbers it; `fg` brings it
%% back, Ctrl-Z stops it again and `fg` returns that status; Ctrl-C ends a
%% job `fg` brought forward together with the line.
stop_line_test_() ->
    {timeout, 30,
     fun() ->
             Shown = session([{suspend, <<"spin z\n">>},
                              {check, fun() -> statuses([z]) end, {suspend, <<"fg\n">>}},
                              {check, fun() -> statuses([z]) end, {line, <<"echo $status\n">>}},
                              {interrupt, 1, <<"fg %1\n">>},
                              {check, fun() -> gone([z]) end, {line, <<"jobs\n">>}},
                              eof]),
             ?assertEqual([[suspended], [suspended], gone], [C || {checked, C} <- Shown]),
             ?assertEqual(<<"^Z\n[1] + Suspended               spin z\n",
                            "spin z\n^Z\n[1] + Suspended               spin z\n",
                            "sigtstp\n",
                            "spin z\n^C\n">>,
                          iolist_to_binary([O || {out, O} <- Shown]))
     end}.

%% Ctrl-C ends the line, while the job its `&` started runs on, as rc's `&`
%% jobs ignore the interrupt; the job ends when the session does.
background_ignores_interrupt_test_() ->
    {timeout, 30,
     fun() ->
             Shown = session([{interrupt, 1, <<"spin bgx & hang\n">>},
                              {check, fun() -> statuses([bgx]) end, {line, <<"jobs\n">>}},
                              eof]),
             ?assertEqual([[waiting]], [C || {checked, C} <- Shown]),
             ?assertEqual(<<"[1]\n^C\n[1] + Running                 spin bgx & hang\n">>,
                          iolist_to_binary([O || {out, O} <- Shown])),
             ?assertEqual(gone, gone([bgx]))
     end}.

%% A background job that ends is reported before the next prompt, and the
%% job builtins refuse what names no job.
reports_and_refusals_test_() ->
    {timeout, 30,
     fun() ->
             Shown = session([{line, <<"{ true } &\n">>},
                              {check, fun() -> jobs_ended() end, {line, <<"true\n">>}},
                              {line, <<"fg %3; kill %x; jobs extra; bg\n">>},
                              eof]),
             ?assertEqual([ended], [C || {checked, C} <- Shown]),
             ?assertEqual(<<"[1]\n[1] + Done                    { true } &\n",
                            "fg: no such job\nkill: %x: no such job\nusage: jobs\n",
                            "bg: no current job\n">>,
                          iolist_to_binary([O || {out, O} <- Shown]))
     end}.

%% A command that stops its own job with erx_cmd:stop/1 is reported stopped,
%% the prompt comes back, and the call returns only after `fg`: `continued`
%% follows the command `fg` shows. With no job table the call fails.
stop_own_job_test_() ->
    {timeout, 30,
     fun() ->
             Shown = session([{line, <<"tstp\n">>},
                              {line, <<"jobs\n">>},
                              {interrupt, 1, <<"fg\n">>},
                              eof]),
             Out = iolist_to_binary([O || {out, O} <- Shown]),
             ?assertEqual(<<"[1] + Suspended               tstp\n",
                            "[1] + Suspended               tstp\n",
                            "tstp\n",
                            "continued\n",
                            "^C\n">>, Out),
             ?assertEqual({error, enotsup}, erx_cmd:stop(#{}))
     end}.

%% A request whose sender is a process of another node is not the shell's to
%% serve: the shell ignores it and reads the next line, where asking that
%% process for its group leader would end the shell with badarg.
request_from_another_node_is_ignored_test_() ->
    {timeout, 30,
     fun() ->
             Forge = fun() -> get(shell) ! {erx_shell, other_node_pid(), make_ref(), {stop}} end,
             Shown = session([{check, Forge, {line, <<"echo alive\n">>}}, eof]),
             ?assertEqual(<<"alive\n">>, iolist_to_binary([O || {out, O} <- Shown]))
     end}.

%% A pid of the node other@nohost, from its external format (NEW_PID_EXT).
other_node_pid() ->
    Node = <<"other@nohost">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, 1:32>>).

%% The shell tells the relay who holds the terminal (docs/design-shell.md,
%% "The foreground rule"): each line takes it under the cooked termios
%% before it runs and the console takes it back when the line ends, every
%% request naming the shell's group; Ctrl-C at the prompt counts.
foreground_follows_lines_test_() ->
    {timeout, 30,
     fun() ->
             Parent = self(),
             Foreground = fun(Target, Signals) ->
                                  Parent ! {foreground, Target, Signals},
                                  {ok, left, element(2, Signals)}
                          end,
             {Group, _Shown} = session_group([{line, <<"true\n">>}, interrupted,
                                              {line, <<"true\n">>}, eof],
                                             erx_shell_basic_runner, #{foreground => Foreground}),
             Asked = collect_foreground([]),
             ?assertMatch([{{L1, cooked}, {Group, 0}}, {console, {Group, 0}},
                           {{L2, cooked}, {Group, 1}}, {console, {Group, 1}}]
                            when is_pid(L1) andalso is_pid(L2) andalso L1 =/= L2, Asked)
     end}.

%% A refused `foreground` ends the shell, its reason carrying the request
%% and the answer. Seeded: a shell that ignores the answer lives on.
refused_foreground_ends_the_shell_test_() ->
    {timeout, 30,
     fun() ->
             Refuse = fun(_Target, _Signals) -> {error, einval} end,
             {_Group, Shown} = session_group([{line, <<"true\n">>}, eof],
                                             erx_shell_basic_runner, #{foreground => Refuse}),
             ?assertMatch({exit, {shutdown, {foreground_refused, {_, cooked}, 0, {error, einval}}}},
                          lists:last(Shown))
     end}.

collect_foreground(Asked) ->
    receive
        {foreground, Target, Signals} -> collect_foreground([{Target, Signals} | Asked])
    after 0 ->
        lists:reverse(Asked)
    end.

%% A burst of size changes reaches the process of the foreground line that
%% asked for them as one or two messages, and nothing reaches its helper,
%% which did not ask.
winch_test_() ->
    {timeout, 30,
     fun() ->
             true = register(winch_counter, self()),
             try
                 _ = session([{winch, 10, <<"winch\n">>}, eof]),
                 Got = collect_winch([]),
                 Winched = [M || {winched, M} <- Got],
                 ?assertEqual([], [S || {stray, _} = S <- Got]),
                 ?assert(length(Winched) >= 1 andalso length(Winched) =< 2, Got),
                 ?assert(lists:all(fun(M) -> M =:= {erx_cmd, winch} end, Winched))
             after
                 unregister(winch_counter)
             end
     end}.

collect_winch(Got) ->
    receive
        {Kind, _} = M when Kind =:= winched; Kind =:= stray -> collect_winch([M | Got])
    after 0 -> lists:reverse(Got)
    end.

%% Waits until each named process runs, and returns `generations` once each
%% was started by the one before it.
started(Names) ->
    case [whereis(N) || N <- Names] of
        [A, B, C] when is_pid(A), is_pid(B), is_pid(C) ->
            {parent, A} = process_info(B, parent),
            {parent, B} = process_info(C, parent),
            generations;
        _ ->
            timer:sleep(10),
            started(Names)
    end.

statuses(Names) ->
    [element(2, process_info(whereis(N), status)) || N <- Names].

%% Waits until the shell monitors no process: every job it started has ended and its end
%% has reached the shell, which reports it before the next prompt. The tries, 20 s at the
%% least, are only a hang guard.
jobs_ended() -> jobs_ended(1000).

jobs_ended(0) -> {hung, process_info(get(shell), monitors)};
jobs_ended(Tries) ->
    case process_info(get(shell), monitors) of
        {monitors, []} -> ended;
        _ -> timer:sleep(20), jobs_ended(Tries - 1)
    end.

%% Waits until none of the named processes is left; the tries are only a hang guard.
gone(Names) -> gone(Names, 1000).

gone(Names, 0) -> {left, [N || N <- Names, whereis(N) =/= undefined]};
gone(Names, Tries) ->
    case [N || N <- Names, whereis(N) =/= undefined] of
        [] -> gone;
        _ -> timer:sleep(20), gone(Names, Tries - 1)
    end.

%% Starting or moving a job is the line's alone, and the shell refuses a
%% malformed request: neither reaches the table, and the shell runs on.
refused_requests_test_() ->
    {timeout, 30,
     fun() ->
             Ask = fun() ->
                           Shell = get(shell),
                           [ask(Shell, R) || R <- [{fg, current}, {fg, bogus},
                                                   {signal, {terminate, 1}, current}]]
                   end,
             Shown = session([{check, Ask, {line, <<"echo still here\n">>}}, eof]),
             ?assertEqual([[{error, <<"no job control">>}, {error, <<"malformed request">>},
                            {error, <<"malformed request">>}]],
                          [C || {checked, C} <- Shown]),
             ?assertEqual(<<"still here\n">>, iolist_to_binary([O || {out, O} <- Shown]))
     end}.

ask(Shell, Request) ->
    Ref = make_ref(),
    Shell ! {erx_shell, self(), Ref, Request},
    receive {Ref, Reply} -> Reply after 5000 -> timeout end.

%% Runs the shell over Script, a list of what each get_line gets: `{line,
%% Bytes}`, `interrupted`, `eof`, `{interrupt, Count, Bytes}`, a line
%% after which the group interrupts the shell Count times, `{suspend,
%% Bytes}`, a line after which the group stops the foreground job, or
%% `{check, Fun, Step}`, which calls Fun when the prompt for Step shows and
%% records its result as `{checked, Result}`. Returns what the shell showed
%% once it has ended.
session(Script) ->
    session(Script, erx_shell_basic_runner).

session(Script, Runner) ->
    {_Group, Shown} = session_group(Script, Runner),
    Shown.

%% session/2 that also returns the group the shell ran on.
session_group(Script, Runner) ->
    session_group(Script, Runner, #{}).

%% session_group/2 with Extra added to the shell's terminal.
session_group(Script, Runner, Extra) ->
    Parent = self(),
    Group = spawn_link(fun() -> group(Parent, Script, Runner, Extra) end),
    receive {Group, Shown} -> {Group, Shown} end.

group(Parent, Script, Runner, Extra) ->
    process_flag(trap_exit, true),
    group_leader(self(), self()),
    Me = self(),
    Write = fun(Bytes) ->
                    Ref = make_ref(),
                    Me ! {write, self(), Ref, iolist_to_binary(Bytes)},
                    receive Ref -> ok end
            end,
    Shell = erx_shell:server({Runner, maps:merge(#{write => Write}, Extra)}),
    link(Shell),
    %% For checks, which run in this process.
    put(shell, Shell),
    Shown = serve(Shell, Script, []),
    %% The banner comes first, and is the shell's own.
    [{out, <<"rc: ", _/binary>>} | Rest] = Shown,
    Parent ! {self(), Rest}.

serve(Shell, Script, Shown) ->
    receive
        {write, From, Ref, Bytes} ->
            From ! Ref,
            serve(Shell, Script, [{out, Bytes} | Shown]);
        {io_request, From, ReplyAs, {get_line, unicode, Prompt}} ->
            Shown1 = [{prompt, unicode:characters_to_binary(Prompt)} | Shown],
            {Step, Rest, Shown2} = case Script of
                                       [{check, Check, Then} | More] -> {Then, More, [{checked, Check()} | Shown1]};
                                       [Then | More] -> {Then, More, Shown1}
                                   end,
            From ! {io_reply, ReplyAs, answer(Step)},
            %% As OTP's group: an interrupt while no line is read goes to the
            %% shell, and so does the terminal's stop, which erx_console sends.
            [erlang:send_after(300, self(), {interrupt, Count}) || {interrupt, Count, _} <- [Step]],
            [erlang:send_after(300, self(), suspend) || {suspend, _} <- [Step]],
            %% A burst of size changes, as erx_console sends them through the
            %% group, and then the interrupt that ends the line.
            [erlang:send_after(300, self(), {winch, Count}) || {winch, Count, _} <- [Step]],
            [erlang:send_after(1000, self(), {interrupt, 1}) || {winch, _, _} <- [Step]],
            serve(Shell, Rest, Shown2);
        {interrupt, Count} ->
            [exit(Shell, interrupt) || _ <- lists:seq(1, Count)],
            serve(Shell, Script, Shown);
        suspend ->
            Shell ! {self(), suspend},
            serve(Shell, Script, Shown);
        {winch, Count} ->
            [Shell ! {self(), winch} || _ <- lists:seq(1, Count)],
            serve(Shell, Script, Shown);
        {'EXIT', Shell, normal} ->
            lists:reverse(Shown);
        {'EXIT', Shell, Reason} ->
            lists:reverse([{exit, Reason} | Shown])
    end.

answer({line, Bytes}) -> unicode:characters_to_list(Bytes);
answer({interrupt, _Count, Bytes}) -> unicode:characters_to_list(Bytes);
answer({suspend, Bytes}) -> unicode:characters_to_list(Bytes);
answer({winch, _Count, Bytes}) -> unicode:characters_to_list(Bytes);
answer(interrupted) -> {error, interrupted};
answer(eof) -> eof.

%% A script whose evaluator crashes ends as a fault whose status is a failure and
%% names nothing of the script's, and leaves no report: the crash's reason and stack
%% carry the shell's variables (erx_shell_script:run/2, and through the same evaluator
%% an exec, command/2). A raise in a builtin never gets this far, since the runner
%% makes it the unit's fault (erx_shell_runner:runner/0); here the evaluator crashes
%% on a variable whose value is a binary, not a list of words, a shape it never makes.
an_evaluator_crash_ends_a_script_unreported_test() ->
    Test = self(),
    Run = fun() ->
                  Test ! {ending, erx_shell_script:run(<<"echo $secret">>,
                                                       #{vars => #{<<"secret">> => <<"hidden-value">>},
                                                         fds => #{0 => null, 1 => null, 2 => null}})}
          end,
    Logged = logged_by(Run),
    {Ending, Status} = receive {ending, Ended} -> Ended after 5000 -> error(no_ending) end,
    ?assertEqual([], Logged),
    ?assertEqual(fault, Ending),
    ?assertNotEqual(0, erx_shell_jobs:exit_status(Status)),
    ?assertEqual(nomatch, binary:match(Status, <<"hidden-value">>)).

%% An evaluator that crashes in a process of its own, a pipeline's stage, a subshell, a
%% backquote or an `&` block, leaves no report either, and its status names nothing of
%% the script's: every process that runs evaluator code ends a crash the same way
%% (erx_shell_runner:spawn_evaluator/3).
a_crash_run_apart_is_unreported_test_() ->
    [{Source, ?_assertEqual({[], nomatch}, crash_run_apart(Source))}
     || Source <- [<<"echo $secret | cat">>, <<"@ { echo $secret }">>,
                   <<"x = `{ echo $secret }; echo $x">>, <<"{ echo $secret } &">>]].

%% What a script that runs Source logs, and where its status names the secret.
crash_run_apart(Source) ->
    Test = self(),
    Run = fun() ->
                  Test ! {ending, erx_shell_script:run(Source,
                                                       #{vars => #{<<"secret">> => <<"hidden-value">>},
                                                         fds => #{0 => null, 1 => null, 2 => null}})}
          end,
    Logged = logged_by(Run),
    {_Ending, Status} = receive {ending, Ended} -> Ended after 5000 -> error(no_ending) end,
    {Logged, binary:match(Status, <<"hidden-value">>)}.

%%% A runner whose every command crashes, built as the shell builds any runner

new(Terminal) ->
    {fun crashing_request/2, Terminal}.

%% A command's crash carries the shell's variables, and a write, as of a
%% diagnostic, matches no clause, so its crash carries the request.
crashing_request({run, _Argv, Vars}, _Terminal) -> error({crashed, Vars});
crashing_request({whatis, Name}, Terminal) -> {{found, Name}, Terminal}.

%%% What reaches the log

%% Runs Fun with a logger handler that sends this process every event, and
%% returns the events logged while it ran and for a short while after, since
%% the emulator logs a crash on its own schedule.
logged_by(Fun) ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => self()}),
    try
        Fun(),
        collect_logged([])
    after
        logger:remove_handler(?MODULE)
    end.

collect_logged(Events) ->
    receive
        {?MODULE, logged, Event} -> collect_logged([Event | Events])
    after 500 ->
        lists:reverse(Events)
    end.

-doc "The logger handler logged_by/1 adds: sends each event to the test process.".
log(Event, #{config := Pid}) ->
    Pid ! {?MODULE, logged, Event},
    ok.

%% Closing a job passes on to the terminal's group every output request its
%% processes sent before, here each of five members' io:format and two more members'
%% reads waiting at a leader held suspended until the close is under way, and ends the
%% members and the leader (erx_shell_leader:close/1). The group, here the test, is the
%% one that drops a read whose process the close ended (group:handle_info/3).
a_closed_job_passes_on_its_last_output_test() ->
    Group = self(),
    Leader = erx_shell_leader:start(Group),
    true = erlang:suspend_process(Leader),
    Bodies = [fun() -> io:format("line ~b~n", [N]) end || N <- lists:seq(1, 5)]
             ++ [fun() -> io:get_line("") end || _ <- [1, 2]],
    Members = [begin
                   {Pid, _Ref, Go} = erx_shell_leader:spawn_member(Leader, Body, 1 bsl 20),
                   ok = Go(),
                   Pid
               end || Body <- Bodies],
    ok = queued(Leader, 7, 100),
    {Closer, CloseRef} = spawn_monitor(fun() -> exit({closed, erx_shell_leader:close(Leader)}) end),
    ok = closing(Closer, 100),
    true = erlang:resume_process(Leader),
    ?assertEqual({closed, ok}, receive {'DOWN', CloseRef, process, _, Closed} -> Closed after 5000 -> none end),
    %% Each member's one request, whatever shape io:format gives it, among the
    %% members' DOWN messages.
    Requests = [Request || _ <- Members,
                           Request <- [receive {io_request, _, _, _} = Got -> Got after 0 -> none end],
                           Request =/= none],
    ?assertEqual(7, length(Requests)),
    ?assertEqual([], [Pid || Pid <- [Leader | Members], is_process_alive(Pid)]).

%% Waits until Closer waits in close/1 for the leader's end, or has ended, looking up to
%% Tries times 10 ms apart.
closing(Closer, Tries) ->
    case process_info(Closer, [current_function, status]) of
        [{current_function, {erx_shell_leader, close, 1}}, {status, waiting}] -> ok;
        undefined -> ok;
        _ when Tries =:= 0 -> error({not_closing, Closer});
        _ -> receive after 10 -> closing(Closer, Tries - 1) end
    end.

%% Waits until Pid holds Count messages, looking up to Tries times 10 ms apart.
queued(Pid, Count, Tries) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, Count} -> ok;
        _ when Tries =:= 0 -> error({not_queued, Pid});
        _ -> receive after 10 -> queued(Pid, Count, Tries - 1) end
    end.
