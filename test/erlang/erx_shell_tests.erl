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
    Prompt = [<<"; ">>, <<"> ">>],
    [?_assertEqual(<<"; ">>, erx_shell:prompt(Prompt, erx_shell:reader(<<>>))),
     ?_assertEqual(<<"> ">>, erx_shell:prompt(Prompt, erx_shell:reader(<<"{\n">>))),
     ?_assertEqual(<<>>, erx_shell:prompt([<<"% ">>], erx_shell:reader(<<"{\n">>))),
     ?_assertEqual(<<>>, erx_shell:prompt([], erx_shell:reader(<<>>)))].

%%% The process, through a scripted group

session_test_() ->
    {timeout, 30,
     [?_assertEqual(
         [{prompt, <<"; ">>}, {out, <<"a b c\n">>},
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
         [{prompt, <<"; ">>}, {prompt, <<>>}, {out, <<"\n">>},
          {prompt, <<"; ">>}, {out, <<"after\n">>}, {prompt, <<"; ">>}],
         session([{line, <<"{ echo before\n">>}, interrupted,
                  {line, <<"echo after\n">>}, eof])),
      %% Ctrl-C while a unit runs ends the unit, not the shell, which keeps
      %% what it had before the unit.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {prompt, <<"; ">>}, {out, <<"^C\n">>},
          {prompt, <<"; ">>}, {out, <<"kept\n">>}, {prompt, <<"; ">>}],
         session([{line, <<"y=kept\n">>},
                  {interrupt, 1, <<"y=lost; while(true) true\n">>},
                  {line, <<"echo $y\n">>}, eof])),
      %% The input ending inside a unit reports what is missing.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {prompt, <<>>},
          {out, <<"rc: syntax error at line 2, column 1: expected '}'\n">>}],
         session([{line, <<"{\n">>}, eof])),
      %% A line the end of input ended, as the group's editor ends one when
      %% its input ends, has no newline: it runs, and the shell ends.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {out, <<"last\n">>}],
         session([{line, <<"echo last">>}])),
      ?_assertEqual([{prompt, <<"; ">>}], session([{line, <<>>}])),
      %% A second Ctrl-C while the first ends the line comes before the next line
      %% is read, and ends nothing.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {out, <<"^C\n">>},
          {prompt, <<"; ">>}, {out, <<"after\n">>}, {prompt, <<"; ">>}],
         session([{interrupt, 2, <<"while(true) true\n">>},
                  {line, <<"echo after\n">>}, eof])),
      %% After an `if`, a unit starting `if not` may follow; a bad one is reported
      %% with what is wrong with it, which `$status` then holds.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {prompt, <<"; ">>}, {out, <<"b\n">>},
          {prompt, <<"; ">>}, {prompt, <<"; ">>},
          {out, <<"rc: syntax error at line 1, column 14: unexpected ')'\n">>},
          {prompt, <<"; ">>}, {out, <<"unexpected ')'\n">>}, {prompt, <<"; ">>}],
         session([{line, <<"if(false) echo a\n">>}, {line, <<"if not echo b\n">>},
                  {line, <<"if(true) true\n">>}, {line, <<"if not echo b)\n">>},
                  {line, <<"echo $status\n">>}, eof])),
      %% A line that passes its heap limit ends with a diagnostic, and the shell
      %% keeps what it had before the line.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {out, <<"rc: the line passed its heap limit\n">>},
          {prompt, <<"; ">>}, {out, <<"\n">>}, {prompt, <<"; ">>}],
         session([{line, <<"x=a; while(true) x=($x $x)\n">>},
                  {line, <<"echo $x\n">>}, eof])),
      %% A line whose runner crashes ends with a diagnostic, and the shell reads on.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {out, <<"rc: the line crashed\n">>}, {prompt, <<"; ">>}],
         session([{line, <<"crash\n">>}, eof], ?MODULE)),
      %% A runner that crashes while the shell reports a unit that does not
      %% parse ends that report alone, and the shell reads on.
      ?_assertEqual(
         [{prompt, <<"; ">>}, {out, <<"rc: the line crashed\n">>}, {prompt, <<"; ">>}],
         session([{line, <<"echo a)\n">>}, eof], ?MODULE)),
      %% Neither crash reaches a log: a crash's reason and stack would carry
      %% the shell's variables and the runner's state.
      ?_assertEqual([], logged_by(fun() ->
                                          session([{line, <<"secret=hidden; crash\n">>},
                                                   {line, <<"echo a)\n">>}, eof], ?MODULE)
                                  end))]}.

%% Every process a line starts, and those they start, ends with the line
%% when Ctrl-C ends it; those a line leaves running when it ends of itself
%% stay, under the session's group. `start` returns once both of its
%% processes run, before `hang`, so the interrupt finds them.
line_processes_test_() ->
    {timeout, 30,
     fun() ->
             {Group, Shown} = session_group([{interrupt, 1, <<"start a; hang\n">>},
                                             {line, <<"start b\n">>}, eof],
                                            erx_shell_basic_runner),
             Left = [whereis(b), whereis(b_child)],
             Leaders = [process_info(Pid, group_leader) || Pid <- Left],
             [exit(Pid, kill) || Pid <- Left, is_pid(Pid)],
             ?assertEqual([{prompt, <<"; ">>}, {out, <<"^C\n">>},
                           {prompt, <<"; ">>}, {prompt, <<"; ">>}], Shown),
             ?assertEqual([undefined, undefined], [whereis(a), whereis(a_child)]),
             ?assertEqual([{group_leader, Group}, {group_leader, Group}], Leaders)
     end}.

%% A process the line leaves may end before it is handed over to the
%% session's group; handing it over then is no fault of the shell's.
hand_over_ended_test() ->
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    ?assertEqual(ok, erx_shell:hand_over(self(), Pid)).

%% Runs the shell over Script, a list of what each get_line gets: `{line,
%% Bytes}`, `interrupted`, `eof`, or `{interrupt, Count, Bytes}`, a line
%% after which the group interrupts the shell Count times. Returns what the
%% shell showed once it has ended.
session(Script) ->
    session(Script, erx_shell_basic_runner).

session(Script, Runner) ->
    {_Group, Shown} = session_group(Script, Runner),
    Shown.

%% session/2 that also returns the group the shell ran on.
session_group(Script, Runner) ->
    Parent = self(),
    Group = spawn_link(fun() -> group(Parent, Script, Runner) end),
    receive {Group, Shown} -> {Group, Shown} end.

group(Parent, Script, Runner) ->
    process_flag(trap_exit, true),
    group_leader(self(), self()),
    Me = self(),
    Write = fun(Bytes) ->
                    Ref = make_ref(),
                    Me ! {write, self(), Ref, iolist_to_binary(Bytes)},
                    receive Ref -> ok end
            end,
    Shell = erx_shell:server({Runner, #{write => Write}}),
    link(Shell),
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
            [Step | Rest] = Script,
            From ! {io_reply, ReplyAs, answer(Step)},
            %% As OTP's group: an interrupt while no line is read goes to the shell.
            [erlang:send_after(300, self(), {interrupt, Count}) || {interrupt, Count, _} <- [Step]],
            serve(Shell, Rest, Shown1);
        {interrupt, Count} ->
            [exit(Shell, interrupt) || _ <- lists:seq(1, Count)],
            serve(Shell, Script, Shown);
        {'EXIT', Shell, normal} ->
            lists:reverse(Shown)
    end.

answer({line, Bytes}) -> unicode:characters_to_list(Bytes);
answer({interrupt, _Count, Bytes}) -> unicode:characters_to_list(Bytes);
answer(interrupted) -> {error, interrupted};
answer(eof) -> eof.

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
