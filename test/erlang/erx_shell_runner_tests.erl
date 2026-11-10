%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_runner_tests).
-moduledoc """
EUnit cases of the command shell's runner and what it stands on: the
pipe's bounds and ends, the command namespace, the renderer, the
command context and the runner's commands, statuses and globbing. The
module is also a command module of its own, for commands that misbehave
on purpose: `crashy`, `yes` and `hog`.
""".

-include_lib("eunit/include/eunit.hrl").

-erx_command(testcmd).
-erx_usage("testcmd crash | yes | hog").

-export([run/2]).

%%% The test command

run([<<"crash">>], _Ctx) -> error(on_purpose);
run([<<"yes">>], Ctx) -> yes(Ctx);
run([<<"marker">>], _Ctx) -> runner_tests_marker ! {marker, self()}, ok;
run([<<"hog">>], _Ctx) -> {error, length(lists:seq(1, 1 bsl 26))};
run(_Args, _Ctx) -> {error, usage}.

yes(Ctx) -> erx_cmd:write(Ctx, <<"y\n">>), yes(Ctx).

%%% The pipe

pipe_lines_test() ->
    Pipe = erx_shell_pipe:new(),
    writer(Pipe, [<<"one\ntw">>, <<"o\nlast">>]),
    ?assertEqual({line, <<"one\n">>}, erx_shell_pipe:get(Pipe)),
    ?assertEqual({line, <<"two\n">>}, erx_shell_pipe:get(Pipe)),
    ?assertEqual({line, <<"last">>}, erx_shell_pipe:get(Pipe)),
    ?assertEqual(eof, erx_shell_pipe:get(Pipe)).

%% Bytes written one at a time make one line.
pipe_merges_bytes_test() ->
    Pipe = erx_shell_pipe:new(),
    writer(Pipe, lists:duplicate(300, <<"x">>) ++ [<<"\n">>]),
    ?assertEqual({line, binary:copy(<<"x">>, 300)}, strip(erx_shell_pipe:get(Pipe))),
    ?assertEqual(eof, erx_shell_pipe:get(Pipe)).

pipe_line_too_long_test() ->
    Pipe = erx_shell_pipe:new(),
    writer(Pipe, [binary:copy(<<"x">>, 70000)]),
    ?assertEqual({error, line_too_long}, erx_shell_pipe:get(Pipe)).

%% A writer of 1 MiB to a reader that takes nothing holds at most 64 KiB
%% in flight, and each read takes at most that.
pipe_bounds_bytes_in_flight_test() ->
    Pipe = erx_shell_pipe:new(),
    Self = self(),
    writer(Pipe, [binary:copy(<<"x">>, 1 bsl 20)], fun() -> Self ! all_put end),
    ?assertEqual(nothing, receive all_put -> put_all after 200 -> nothing end),
    {bytes, First} = erx_shell_pipe:get_bytes(Pipe),
    ?assertEqual(65536, byte_size(First)),
    Rest = drain_bytes(Pipe, 0),
    ?assertEqual(put_all, receive all_put -> put_all after 5000 -> nothing end),
    ?assertEqual(1 bsl 20, byte_size(First) + Rest).

drain_bytes(Pipe, Total) ->
    case erx_shell_pipe:get_bytes(Pipe) of
        {bytes, Bytes} when byte_size(Bytes) =< 65536 -> drain_bytes(Pipe, Total + byte_size(Bytes));
        eof -> Total
    end.

pipe_epipe_when_reader_ends_test() ->
    Pipe = erx_shell_pipe:new(),
    Reader = spawn(fun() -> receive stop -> ok end end),
    erx_shell_pipe:attach(Pipe, read, Reader),
    ?assertEqual(ok, erx_shell_pipe:put(Pipe, <<"a\n">>)),
    Ref = monitor(process, Reader),
    Reader ! stop,
    receive {'DOWN', Ref, _, _, _} -> ok end,
    ?assertEqual({error, epipe}, erx_shell_pipe:put(Pipe, <<"b\n">>)).

pipe_here_document_test() ->
    Pipe = erx_shell_pipe:from_binary(<<"a\nb\n">>),
    ?assertEqual([{line, <<"a\n">>}, {line, <<"b\n">>}, eof],
                 [erx_shell_pipe:get(Pipe) || _ <- [1, 2, 3]]).

pipe_from_missing_file_test() ->
    ?assertEqual({error, enoent}, erx_shell_pipe:from_file(<<"/nonexistent/erx/file">>)).

writer(Pipe, Items) -> writer(Pipe, Items, fun() -> ok end).

writer(Pipe, Items, Done) ->
    Pid = spawn(fun() -> receive go -> ok end,
                         [ok = erx_shell_pipe:put(Pipe, Item) || Item <- Items],
                         Done()
                end),
    erx_shell_pipe:attach(Pipe, write, Pid),
    Pid ! go.

strip({line, Line}) -> {line, string:trim(Line, trailing, "\n")}.

%%% The namespace

attributes(Command, Usage) -> [{erx_command, [Command]}, {erx_usage, Usage}].

namespace_entries_and_conflicts_test() ->
    {Table, Problems} = erx_shell_namespace:build(
                          [{m_echo, attributes(echo, "echo"), [{run, 2}]},
                           {m_one, attributes(dup, "dup"), [{run, 2}]},
                           {m_two, attributes(dup, "dup"), [{run, 2}]},
                           {m_cd, attributes(cd, "cd"), [{run, 2}]},
                           {m_plain, [{vsn, [1]}], []}]),
    ?assertEqual([], Problems),
    ?assertMatch({erlang, #{module := m_echo, usage := <<"echo">>, needs := []}},
                 erx_shell_namespace:lookup(<<"echo">>, Table)),
    ?assertEqual({conflict, [m_one, m_two]}, erx_shell_namespace:lookup(<<"dup">>, Table)),
    ?assertEqual({found, <<"dup: unresolved, declared by m_one and m_two">>},
                 erx_shell_namespace:whatis(<<"dup">>, Table)),
    ?assertEqual({builtin, cd}, erx_shell_namespace:lookup(<<"cd">>, Table)),
    ?assertEqual(not_found, erx_shell_namespace:lookup(<<"./echo">>, Table)),
    ?assertEqual(not_found, erx_shell_namespace:whatis(<<"nosuch">>, Table)).

namespace_refuses_malformed_metadata_test() ->
    {Table, Problems} = erx_shell_namespace:build(
                          [{m_nousage, [{erx_command, [a]}], [{run, 2}]},
                           {m_norun, attributes(b, "b"), [{run, 1}]},
                           {m_needs, attributes(c, "c") ++ [{erx_needs, ["x"]}], [{run, 2}]}]),
    ?assertEqual([{m_nousage, malformed_metadata}, {m_norun, no_run},
                  {m_needs, malformed_metadata}], Problems),
    ?assertEqual(#{<<"cd">> => {builtin, cd}, <<"jobs">> => {builtin, jobs},
                   <<"fg">> => {builtin, fg}, <<"bg">> => {builtin, bg},
                   <<"kill">> => {builtin, kill}}, Table).

%%% The renderer and the context

render_statuses_test() ->
    ?assertEqual([<<"7">>, <<"[partial]">>, <<"[unknown]">>, <<"[unsupported]">>,
                  <<"[timeout 500]">>, <<"[error]">>],
                 [erx_render:value({runtime, V})
                  || V <- [{ok, 7}, {partial, 1}, unknown, unsupported, {timeout, 500}, {error, x}]]).

cmd_path_test() ->
    ?assertEqual(<<"/a/c">>, erx_cmd:path(<<"/a/b">>, <<"../c">>)),
    ?assertEqual(<<"/">>, erx_cmd:path(<<"/a">>, <<"../../..">>)),
    ?assertEqual(<<"/x/y">>, erx_cmd:path(<<"/a">>, <<"/x/./y/">>)).

cmd_getopt_test() ->
    ?assertEqual({ok, "rf", [<<"a">>]}, erx_cmd:getopt([<<"-r">>, <<"-f">>, <<"a">>], "rf")),
    ?assertEqual({ok, "", [<<"-x">>]}, erx_cmd:getopt([<<"--">>, <<"-x">>], "rf")),
    ?assertEqual({error, usage}, erx_cmd:getopt([<<"-x">>], "rf")),
    ?assertEqual({ok, [$n, {$k, <<"2">>}, {$k, <<"3,3">>}], [<<"f">>]},
                 erx_cmd:getopt([<<"-nk2">>, <<"-k">>, <<"3,3">>, <<"f">>], "nk:")),
    ?assertEqual({error, usage}, erx_cmd:getopt([<<"-k">>], "nk:")).

%%% The runner

runner_state(Facets, Err) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [?MODULE, erx_cmd_ps, erx_cmd_echo, erx_cmd_true, erx_cmd_cp, erx_cmd_mv, erx_cmd_rm]]
                    ++ [{needy, attributes(needy, "needy") ++ [{erx_needs, [inspect]}], [{run, 2}]}]),
    erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => null, 2 => Err},
                           table => Table, facets => Facets}).

run_status(Argv, State) ->
    {Status, _} = (erx_shell_runner:runner())({run, Argv, #{}}, State),
    Status.

runner_statuses_test() ->
    Pipe = erx_shell_pipe:new(),
    erx_shell_pipe:attach(Pipe, read, self()),
    State = runner_state(#{}, {pipe, Pipe}),
    ?assertEqual(<<"no_facet">>, run_status([<<"needy">>], State)),
    ?assertEqual(<<"not found">>, run_status([<<"nosuch">>], State)),
    ?assertEqual(<<"usage">>, run_status([<<"testcmd">>], State)),
    ?assertMatch(<<"{error,on_purpose}">>, run_status([<<"testcmd">>, <<"crash">>], State)),
    ?assertEqual([{line, <<"needy: no_facet\n">>}, {line, <<"nosuch: not found\n">>},
                  {line, <<"usage: testcmd crash | yes | hog\n">>},
                  {line, <<"testcmd: crashed: {error,on_purpose}\n">>}],
                 [erx_shell_pipe:get(Pipe) || _ <- [1, 2, 3, 4]]).

%% A command past its heap limit is killed and the shell goes on.
runner_heap_limit_test_() ->
    {timeout, 60, fun() ->
        ?assertEqual(<<"killed">>, run_status([<<"testcmd">>, <<"hog">>], runner_state(#{}, null)))
    end}.

%% A writer whose reader ended stops with `broken pipe`, whatever it writes.
runner_pipeline_epipe_test() ->
    {ok, Shell} = run_source(<<"testcmd yes | true">>),
    ?assertEqual(<<"broken pipe|">>, erx_shell_eval:status(Shell)).

runner_glob_test() ->
    Dir = scratch_dir(),
    [ok = file:write_file(filename:join(Dir, Name), <<>>) || Name <- ["a1", "a2", "b1", ".a3"]],
    Cwd = list_to_binary(Dir),
    ?assertEqual([<<"a1">>, <<"a2">>], erx_shell_runner:glob([{src, <<"a*">>}], Cwd)),
    ?assertEqual([<<".a3">>], erx_shell_runner:glob([{src, <<".a*">>}], Cwd)),
    ?assertEqual([], erx_shell_runner:glob([{lit, <<"a">>}, {src, <<"9*">>}], Cwd)),
    Absolute = [<<Cwd/binary, "/b1">>],
    ?assertEqual(Absolute, erx_shell_runner:glob([{lit, Cwd}, {src, <<"/b*">>}], <<"/">>)).

run_source(Source) ->
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), runner_state(#{}, null)),
    erx_shell_eval:run_source(Source, Shell).

scratch_dir() ->
    Dir = filename:join(filename:basedir(user_cache, "erx_shell_runner_tests"),
                        integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    Dir.

%% A copy onto itself is refused, and the file keeps its bytes.
runner_cp_onto_itself_test() ->
    Dir = list_to_binary(scratch_dir()),
    {ok, Shell} = run_source(<<"echo x > ", Dir/binary, "/f; cp ", Dir/binary, "/f ", Dir/binary>>),
    ?assertEqual(<<"identical">>, erx_shell_eval:status(Shell)),
    ?assertEqual({ok, <<"x\n">>}, file:read_file(filename:join(Dir, "f"))).

%% rm refuses an operand whose last component is `.` or `..`.
runner_rm_dot_test() ->
    Dir = list_to_binary(scratch_dir()),
    {ok, Shell} = run_source(<<"rm -r ", Dir/binary, "/.">>),
    ?assertEqual(<<"invalid argument">>, erx_shell_eval:status(Shell)),
    ?assert(filelib:is_dir(Dir)).

%% A state with no job control, as a script's, has the job builtins refuse,
%% each with its diagnostic, and kill reports a malformed job by name,
%% escaped.
runner_no_job_control_test() ->
    Me = self(),
    State = runner_state(#{}, {tty, fun(Bytes) -> Me ! {err, iolist_to_binary(Bytes)}, ok end}),
    ?assertEqual([<<"no job control">>, <<"no job control">>, <<"no job control">>,
                  <<"no job control">>],
                 [run_status(Argv, State) || Argv <- [[<<"jobs">>], [<<"fg">>], [<<"bg">>, <<"%1">>],
                                                      [<<"kill">>, <<"%1">>]]]),
    ?assertEqual(<<"jobs: no job control\nfg: no job control\nbg: no job control\n"
                   "kill: no job control\n">>, drain(<<>>)),
    {Status, _Out, Err} = erx_shell:builtin(<<"kill">>, [<<"%\e[2J">>], {self(), apart}),
    ?assertEqual(<<"%<U+001B>[2J: no such job">>, Status),
    ?assertEqual(nomatch, binary:match(iolist_to_binary(Err), <<"\e">>)).

%% In a session that holds none of the facets of the system domain's
%% services, each command that reaches one fails with `no_facet` and its
%% name before it starts, its arguments unread: ifconfig never reaches the
%% network stack, which a session's release does not ship and which is not
%% loaded here, so it would crash with `undef`, and ping and host, run
%% without the operand they need, never come to their usage line. ps lists
%% the session's own table, and dmesg reads only what its namespace's /proc
%% holds, so neither needs a facet.
session_commands_without_facets_test() ->
    Me = self(),
    Err = {tty, fun(Bytes) -> Me ! {err, iolist_to_binary(Bytes)}, ok end},
    Modules = [erx_cmd_ifconfig, erx_cmd_ping, erx_cmd_host, erx_cmd_ps, erx_cmd_dmesg],
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)} || Module <- Modules]),
    Session = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => null, 2 => Err},
                                       table => Table, facets => erx_facets:facets({domain, 7}, #{})}),
    Needy = [[<<"ifconfig">>], [<<"ping">>], [<<"host">>]],
    ?assertEqual([<<"no_facet">>, <<"no_facet">>, <<"no_facet">>], [run_status(Argv, Session) || Argv <- Needy]),
    ?assertEqual(<<"ifconfig: no_facet\nping: no_facet\nhost: no_facet\n">>, drain(<<>>)),
    ?assertEqual(<<>>, run_status([<<"ps">>], Session)),
    ?assertNotEqual(<<"no_facet">>, run_status([<<"dmesg">>], Session)),
    _ = drain(<<>>).

%% The system domain's session holds every facet any command of the shell
%% declares, so the system shell refuses none of them.
system_facets_cover_every_command_test() ->
    Dir = filename:dirname(code:which(erx_cmd)),
    Modules = [list_to_atom(filename:basename(File, ".beam")) || File <- filelib:wildcard("erx_cmd_*.beam", Dir)],
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)} || Module <- Modules]),
    ?assert(lists:member(erx_cmd_ifconfig, Modules)),
    System = erx_facets:facets(system, #{}),
    ?assertEqual([], [Name || {erlang, #{name := Name, needs := Needs}} <- maps:values(Table),
                              Need <- Needs, not is_map_key(Need, System)]).

drain(Acc) ->
    receive
        {err, Bytes} -> drain(<<Acc/binary, Bytes/binary>>)
    after 0 ->
        Acc
    end.

%% A background block whose request the shell refuses, as when Ctrl-Z has
%% just stopped the line that sent it, runs in place in the line's job
%% instead of failing the line.
runner_background_refused_runs_in_place_test() ->
    true = register(runner_tests_marker, self()),
    Shell = spawn_link(fun() ->
                               receive
                                   {erx_shell, From, Ref, {background, _Run}} ->
                                       From ! {Ref, {error, <<"no job control">>}}
                               end
                       end),
    State = (runner_state(#{}, null))#{job_control => {Shell, line}},
    Sh = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, _} = erx_shell_eval:run_source(<<"{ testcmd marker } &">>, Sh),
    receive {marker, Pid} -> ?assert(is_pid(Pid)) after 5000 -> error(not_run) end,
    true = unregister(runner_tests_marker).

%% A background block leaves no message in the evaluator's mailbox.
runner_background_leaves_no_message_test() ->
    {ok, _} = run_source(<<"{true} &">>),
    timer:sleep(100),
    ?assertEqual({messages, []}, process_info(self(), messages)).
