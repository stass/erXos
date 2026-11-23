%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_tty_tests).
-moduledoc """
A session's ttys, erx_session_tty, each with the command shell on it, driven by
a terminal relay of its own (erx_session_relay), and a fake master in the same
node: a process that hands the test every message the tty sends it, while the
test takes each output, answering `{tty_taken, N}` as the console does, and
types into the tty with `{tty_input, N, Bytes}`. On one tty, `echo hi` and `erl`
return, `exit` starts the command shell again, an answer the master never sends
is asked for again within the resend second, and a hangup ends the tty. Two
masters each get a tty of their own, whose relays hold no name: the relay of the
domain's line alone holds erx_tty_owner. One master's end ends its tty only,
leaving the other tty and the line's `user` running.
""".
-behaviour(supervisor).

-include_lib("eunit/include/eunit.hrl").

-export([init/1]).

-define(WAIT_MS, 10000).
%% Two execs that never end on their own: a pipeline whose first stage loops, and a
%% subshell that loops. The loop is braced, since `|` binds tighter than `while`, as in
%% rc: unbraced, each pass would run a pipeline whose stages come and go at once.
-define(PIPELINE, <<"echo looping; { while (true) { x = 1 } } | cat">>).
-define(SUBSHELL, <<"echo looping; @ { while (true) { x = 1 } }">>).
%% Two execs that end of themselves while an `&` block they started runs on: one that
%% loops, and one that writes as fast as its output is taken.
-define(LEFT_RUNNING, <<"{ while (true) { x = 1 } & }; exit 0">>).
-define(LEFT_WRITING, <<"{ while (true) { echo left } & }; echo done; exit 0">>).

%% A session with a home starts its shells and its execs there, with $home its path
%% (docs/design-files.md, "A user's home"), and the shell's runner takes that working
%% directory; a session without one starts them at /, and its terminal sets no $home,
%% so rc keeps its default, /.
home_test() ->
    Home = {ok, {<<"/root">>, [{tree, <<"home">>}, rw]}},
    Write = fun(_) -> ok end,
    {erx_shell, server, [{erx_shell_runner, #{vars := #{<<"home">> := [<<"/root">>]}, cwd := <<"/root">>} = At}]} =
        erx_session_tty:shell_of(shell, #{write => Write}, Home),
    {_Runner, #{cwd := <<"/root">>}} = erx_shell_runner:new(At),
    {erx_shell_script, command, [<<"pwd">>, #{<<"home">> := [<<"/root">>], <<"x">> := [<<"1">>]}, <<"/root">>]} =
        erx_session_tty:shell_of({exec, <<"pwd">>}, #{vars => #{<<"x">> => [<<"1">>]}}, Home),
    {erx_shell, server, [{erx_shell_runner, Plain}]} = erx_session_tty:shell_of(shell, #{write => Write}, none),
    ?assertNot(maps:is_key(cwd, Plain)),
    {_, #{cwd := <<"/">>}} = erx_shell_runner:new(Plain),
    {erx_shell_script, command, [<<"pwd">>, Vars, <<"/">>]} =
        erx_session_tty:shell_of({exec, <<"pwd">>}, #{vars => #{}}, none),
    ?assertEqual(#{}, Vars).

%% One process drives a tty throughout, so the steps run in order in it.
relay_test_() ->
    {timeout, 60, fun() -> in_session(fun relay/1) end}.

masters_test_() ->
    {timeout, 60, fun() -> in_session(fun two_masters/1) end}.

channel_test_() ->
    {timeout, 60, fun() -> in_session(fun channel_exits/1) end}.

%% A channel's tty (erx_session_tty:start_channel/3, which open_channel/3 starts under
%% the session's supervisor) is not started again when its shell ends: the console
%% reports the shell's exit status, rc's as a program, once the master has taken the
%% tty's last output, and ends, the relay with it. Here the master is of this node,
%% since the host's emulator names no process of another domain.
channel_exits(_Sup) ->
    ?assertEqual({exited, 4}, exits(shell, <<"echo bye; exit 4\r">>, <<"bye">>)),
    ?assertEqual({exited, 0}, exits(shell, <<"echo fine; exit\r">>, <<"fine">>)),
    ?assertEqual({exited, 3}, exits({exec, <<"echo hi; exit 3">>}, none, <<"hi">>)),
    ?assertEqual({exited, 1}, exits({exec, <<"false">>}, none, <<>>)),
    %% The channel's vars set the first variables of the shell and of an exec.
    ?assertEqual({exited, 5}, exits(shell, <<"echo term=$TERM; exit 5\r">>, <<"term=xterm-256color">>)),
    ?assertEqual({exited, 6},
                 exits({exec, <<"echo term=$TERM; exit 6">>}, none, <<"term=xterm-256color">>)),
    ?assertEqual({signaled, sigint}, looping_exec_ends(?PIPELINE, fun(Tty) -> type(Tty, <<3>>) end)),
    ?assertEqual(none, looping_exec_ends(?PIPELINE, fun(Tty) -> Tty ! tty_hangup end)),
    ?assertEqual({signaled, sigint}, looping_exec_ends(?SUBSHELL, fun(Tty) -> type(Tty, <<3>>) end)),
    ?assertEqual(none, looping_exec_ends(?SUBSHELL, fun(Tty) -> Tty ! tty_hangup end)),
    %% An exec that ends of itself ends its `&` blocks first: none is led when the
    %% report comes, and none of their output follows it.
    ?assertEqual({{exited, 0}, [], none}, leftovers_end_first(?LEFT_RUNNING)),
    ?assertEqual({{exited, 0}, [], none}, leftovers_end_first(?LEFT_WRITING)).

%% The report of an exec that ends of itself while `&` blocks it started still run,
%% with the job leaders that lead a process when the console reports, and the output
%% that comes in the 300 ms after it, or none.
leftovers_end_first(Command) ->
    Test = self(),
    Master = master(),
    Channel = #{run => {exec, Command}, size => {24, 80}, vars => #{}},
    Notify = fun(Ending) -> Test ! {notified, Ending, led_by_leaders()} end,
    {ok, Console} = erx_session_tty:start_channel(Master, Channel, Notify),
    Tty = opened(Master),
    Ended = monitor(process, Console),
    Report = report_then_output(Master, Tty),
    _ = ended(Ended, Console),
    unlink(Master),
    exit(Master, kill),
    Report.

report_then_output(Master, Tty) ->
    receive
        {notified, Ending, Led} ->
            Late = receive {Master, {tty_output, _N, Bytes}} -> Bytes after 300 -> none end,
            {Ending, Led, Late};
        {Master, {tty_output, N, _Bytes}} ->
            Tty ! {tty_taken, N},
            report_then_output(Master, Tty);
        {Master, _Other} ->
            report_then_output(Master, Tty)
    after ?WAIT_MS ->
            error(no_report)
    end.

%% How an exec that never ends on its own ends when End acts on its tty: Ctrl-C ends it
%% as SIGINT ends `sh -c`, by that signal, and a hangup with no report. Either
%% way every process the exec started ends with it: its evaluator and what that started,
%% the stages of a pipeline and a subshell, all led by the exec's job leader.
looping_exec_ends(Command, End) ->
    Test = self(),
    Master = master(),
    Channel = #{run => {exec, Command}, size => {24, 80}, vars => #{}},
    {ok, Console} = erx_session_tty:start_channel(Master, Channel, fun(Status) -> Test ! {notified, Status} end),
    Tty = opened(Master),
    Ended = monitor(process, Console),
    {ok, _} = await(Master, Tty, <<"looping">>),
    %% The evaluator, and the stages or the subshell it started, run under the leader.
    {Leader, Led} = running_job(Master, Tty, ?WAIT_MS div 50),
    End(Tty),
    Status = receive_status(Master, Tty, Ended, Console),
    ?assertEqual([], still_alive(Led, 40)),
    ?assertNot(is_process_alive(Leader)),
    unlink(Master),
    exit(Master, kill),
    Status.

%% The status the console reports before it ends, answering each output, or none if it
%% ends with no report.
receive_status(Master, Tty, Ended, Console) ->
    receive
        {notified, Status} -> _ = ended(Ended, Console), Status;
        {'DOWN', Ended, process, Console, _} -> none;
        {Master, {tty_output, N, _Bytes}} -> Tty ! {tty_taken, N}, receive_status(Master, Tty, Ended, Console);
        {Master, _Other} -> receive_status(Master, Tty, Ended, Console)
    after ?WAIT_MS -> error(no_end)
    end.

%% Each job leader that leads a process, with the processes it leads. A leader waits in
%% erx_shell_leader's forward loop; any other process that leads none is not one.
led_by_leaders() ->
    Leaders = [Pid || Pid <- processes(),
                      process_info(Pid, current_function) =:= {current_function, {erx_shell_leader, forward, 3}}],
    [{Leader, Led} || Leader <- Leaders,
                      Led <- [[Pid || Pid <- processes(),
                                      process_info(Pid, group_leader) =:= {group_leader, Leader}]],
                      Led =/= []].

%% The one job leader and the processes it leads once it leads two or more, looking up
%% to Tries times 50 ms apart, since the stages start after the echo and then run on,
%% and taking each output meanwhile, since the echo waits until its output is taken.
running_job(Master, Tty, Tries) ->
    case led_by_leaders() of
        [{Leader, Led}] when length(Led) >= 2 -> {Leader, Led};
        Other when Tries =:= 0 -> error({no_running_job, Other});
        _ -> take_outputs(Master, Tty), running_job(Master, Tty, Tries - 1)
    end.

take_outputs(Master, Tty) ->
    receive {Master, {tty_output, N, _Bytes}} -> Tty ! {tty_taken, N}, take_outputs(Master, Tty)
    after 50 -> ok
    end.

%% The processes of Pids still alive after up to Tries looks 50 ms apart.
still_alive(Pids, 0) -> [Pid || Pid <- Pids, is_process_alive(Pid)];
still_alive(Pids, Tries) ->
    case [Pid || Pid <- Pids, is_process_alive(Pid)] of
        [] -> [];
        _ -> timer:sleep(50), still_alive(Pids, Tries - 1)
    end.

%% The status the console reports for Run once Input, if any, is typed at the prompt:
%% the report comes only after the output that holds Last has been taken, and after it
%% the tty and its console end. The tty starts at the size the channel was opened with,
%% and its shell with the channel's TERM.
exits(Run, Input, Last) ->
    Test = self(),
    Master = master(),
    Channel = #{run => Run, size => {30, 100}, vars => #{<<"TERM">> => [<<"xterm-256color">>]}},
    {ok, Console} = erx_session_tty:start_channel(Master, Channel,
                                                  fun(Status) -> Test ! {notified, Status} end),
    Tty = opened(Master),
    {ok, Probe} = erx_session_relay:open_writer(Tty, size_probe),
    ?assertEqual({ok, {30, 100}}, erx_session_relay:tty(Probe, winsize)),
    Ended = monitor(process, Console),
    TtyEnded = monitor(process, Tty),
    [begin {ok, _} = await(Master, Tty, <<"% ">>), type(Tty, Input) end || Input =/= none],
    Status = notified_after(Master, Tty, Last, <<>>),
    ?assertEqual(normal, ended(Ended, Console)),
    _ = ended(TtyEnded, Tty),
    unlink(Master),
    exit(Master, kill),
    Status.

%% Takes each output; the one that completes Last is held a while first, during which
%% no report may come, since that output is not yet taken.
notified_after(Master, Tty, Last, Seen) ->
    receive
        {notified, Status} ->
            ?assert(holds(Seen, Last)),
            Status;
        {Master, {tty_output, N, Bytes}} ->
            All = <<Seen/binary, Bytes/binary>>,
            [receive {notified, Early} -> error({notified_before_taken, Early}) after 300 -> ok end
             || Last =/= <<>>, not holds(Seen, Last), holds(All, Last)],
            Tty ! {tty_taken, N},
            notified_after(Master, Tty, Last, All);
        {Master, _Other} ->
            notified_after(Master, Tty, Last, Seen)
    after ?WAIT_MS ->
            error({no_report, Seen})
    end.

holds(_Seen, <<>>) -> true;
holds(Seen, Last) -> binary:match(Seen, Last) =/= nomatch.

%% A session's domain starts with -nouser, so no `user` is registered but its line's:
%% the node's is set aside for the run. This module stands in for erx_session_sup, with
%% the session's console tty as its one child at the start; on the host erx:cap(console)
%% names no master, so that tty is stopped, and its console holds `user`.
in_session(Test) ->
    process_flag(trap_exit, true),
    Host = whereis(user),
    true = unregister(user),
    {ok, Sup} = supervisor:start_link({local, erx_session_sup}, ?MODULE, []),
    try Test(Sup) after
        Ended = monitor(process, Sup),
        unlink(Sup),
        exit(Sup, shutdown),
        receive {'DOWN', Ended, process, Sup, _} -> ok end,
        %% The line's `user` ends after its console, and may free its name meanwhile.
        try unregister(user) catch error:badarg -> ok end,
        register(user, Host)
    end.

-doc false.
init([]) ->
    Line = #{id => erx_session_tty, start => {erx_session_tty, start_link, []}, restart => transient},
    {ok, {#{strategy => one_for_one}, [Line]}}.

relay(_Sup) ->
    Master = master(),
    {ok, Console} = erx_session_tty:open(Master),
    Tty = opened(Master),
    ?assertMatch({erx_session_relay, init, _}, proc_lib:initial_call(Tty)),
    {ok, _} = await(Master, Tty, <<"% ">>),
    echo_and_erl_return(Master, Tty),
    exit_starts_the_shell_again(Master, Tty),
    a_taken_output_asks_nothing_more(Master, Tty),
    a_lost_answer_is_asked_for_again(Master, Tty),
    a_hangup_ends_the_tty(Master, Tty, Console).

%% A hangup while the Erlang shell runs ends that shell, the command shell then
%% reads the end of its input, and the tty and its console end with it, normally,
%% leaving the runtime running.
a_hangup_ends_the_tty(Master, Tty, Console) ->
    type(Tty, <<"erl\r">>),
    {ok, _} = await(Master, Tty, <<"1> ">>),
    ConsoleEnded = monitor(process, Console),
    TtyEnded = monitor(process, Tty),
    Tty ! tty_hangup,
    ?assertEqual(normal, ended(ConsoleEnded, Console)),
    _ = ended(TtyEnded, Tty),
    exit(Master, kill).

echo_and_erl_return(Master, Tty) ->
    type(Tty, <<"echo hi\r">>),
    {ok, _} = await(Master, Tty, <<"hi\n% ">>),
    type(Tty, <<"erl\r">>),
    {ok, _} = await(Master, Tty, <<"1> ">>),
    %% The Erlang shell's group ends, so run_shell/1 returns and `erl` with it.
    type(Tty, <<"exit(group_leader(), kill).\r">>),
    {ok, Seen} = await(Master, Tty, <<"% ">>),
    ?assertNotEqual(nomatch, binary:match(Seen, <<"killed">>)).

exit_starts_the_shell_again(Master, Tty) ->
    type(Tty, <<"exit\r">>),
    {ok, _} = await(Master, Tty, <<"exit ends it\n% ">>),
    type(Tty, <<"echo again\r">>),
    {ok, _} = await(Master, Tty, <<"again\n% ">>).

%% With every output answered at once, the tty names itself again only with a resend:
%% the timer of an output already taken sends nothing. A tty that named itself at each
%% such timer would send a burst of tty_open a second after a burst of output, such as
%% a line editor's echo of a pasted line, which fills the console facet's limit in
%% flight, so the facet drops the output sent among it and the console takes that
%% output's empty resend as its bytes lost.
a_taken_output_asks_nothing_more(Master, Tty) ->
    _ = flush_opens(Master),
    type(Tty, <<"echo quiet\r">>),
    {ok, _} = await(Master, Tty, <<"quiet\n% ">>),
    {Opens, Resends} = answer_until(Master, Tty, erlang:monotonic_time(millisecond) + 1500, 0, 0),
    ?assert(Opens =< Resends, {opens, Opens, resends, Resends}).

a_lost_answer_is_asked_for_again(Master, Tty) ->
    type(Tty, <<"echo lost\r">>),
    %% The first output's answer is lost: the tty names itself again and sends the
    %% output again, empty, and the master answers that.
    N = receive {Master, {tty_output, Number, <<_, _/binary>>}} -> Number after ?WAIT_MS -> error(no_output) end,
    Started = erlang:monotonic_time(millisecond),
    receive {Master, {tty_open, Tty}} -> ok after 3000 -> error(no_open) end,
    receive {Master, {tty_output, N, <<>>}} -> ok after 3000 -> error(no_resend) end,
    ?assert(erlang:monotonic_time(millisecond) - Started >= 900),
    Tty ! {tty_taken, N},
    {ok, _} = await(Master, Tty, <<"lost\n% ">>).

%% Two masters open ttys under the session's supervisor. What is typed at one tty
%% reaches only its own master, and when one master ends, its tty hangs up and ends,
%% while the other tty, the line and the line's `user` run on.
two_masters(Sup) ->
    User = whereis(user),
    One = master(),
    Two = master(),
    {ok, ConsoleOne} = erx_session_tty:open(One),
    {ok, _ConsoleTwo} = erx_session_tty:open(Two),
    TtyOne = opened(One),
    TtyTwo = opened(Two),
    ?assertNotEqual(TtyOne, TtyTwo),
    Line = whereis(erx_tty_owner),
    ?assertMatch({erx_session_relay, init, _}, proc_lib:initial_call(Line)),
    ?assertNot(lists:member(Line, [TtyOne, TtyTwo])),
    {ok, _} = await(One, TtyOne, <<"% ">>),
    {ok, _} = await(Two, TtyTwo, <<"% ">>),

    type(TtyOne, <<"echo one\r">>),
    {ok, _} = await(One, TtyOne, <<"one\n% ">>),
    type(TtyTwo, <<"echo two\r">>),
    {ok, SeenTwo} = await(Two, TtyTwo, <<"two\n% ">>),
    ?assertEqual(nomatch, binary:match(SeenTwo, <<"one">>)),

    ConsoleEnded = monitor(process, ConsoleOne),
    TtyEnded = monitor(process, TtyOne),
    exit(One, kill),
    ?assertEqual(normal, ended(ConsoleEnded, ConsoleOne)),
    _ = ended(TtyEnded, TtyOne),
    type(TtyTwo, <<"echo still\r">>),
    {ok, _} = await(Two, TtyTwo, <<"still\n% ">>),
    ?assert(is_pid(User) andalso whereis(user) =:= User),
    ?assertEqual(Line, whereis(erx_tty_owner)),
    Children = supervisor:which_children(Sup),
    ?assertEqual(2, length(Children)),
    ?assertMatch([_], [Id || {Id = {erx_session_tty, _}, _, worker, _} <- Children]),
    exit(Two, kill).

%% How Pid, monitored by Monitor, ended.
ended(Monitor, Pid) ->
    receive {'DOWN', Monitor, process, Pid, Reason} -> Reason after ?WAIT_MS -> error({runs_on, Pid}) end.

%%% The fake master

%% A master that hands the test, as {Master, Message}, every message it gets.
master() ->
    Test = self(),
    spawn_link(fun() -> forward(Test) end).

forward(Test) ->
    receive Message -> Test ! {self(), Message} end,
    forward(Test).

%% The tty that names itself to Master.
opened(Master) ->
    receive {Master, {tty_open, Tty}} -> Tty after ?WAIT_MS -> error(no_tty_open) end.

type(Tty, Bytes) ->
    N = case get({typed, Tty}) of undefined -> 0; Typed -> Typed end,
    put({typed, Tty}, N + 1),
    Tty ! {tty_input, N, Bytes}.

%% The tty_open messages waiting, which the tty sent as it named itself.
flush_opens(Master) ->
    receive {Master, {tty_open, Tty}} -> [Tty | flush_opens(Master)] after 0 -> [] end.

%% Answers every output until Deadline, counting the tty_open messages and the empty
%% resends that came.
answer_until(Master, Tty, Deadline, Opens, Resends) ->
    receive
        {Master, {tty_open, _}} ->
            answer_until(Master, Tty, Deadline, Opens + 1, Resends);
        {Master, {tty_output, N, Bytes}} ->
            Tty ! {tty_taken, N},
            answer_until(Master, Tty, Deadline, Opens, Resends + case Bytes of <<>> -> 1; _ -> 0 end)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
            {Opens, Resends}
    end.

%% Takes every output until what it took, carriage returns aside, contains Pattern,
%% and returns it. A command's newline reaches the master as CR CR LF while its job
%% holds the terminal (docs/todo-session.md, "a command's output through the console"), so no
%% pattern names a CR.
await(Master, Tty, Pattern) ->
    await(Master, Tty, Pattern, <<>>).

await(Master, Tty, Pattern, Seen) ->
    receive
        {Master, {tty_output, N, Bytes}} ->
            Tty ! {tty_taken, N},
            All = <<Seen/binary, Bytes/binary>>,
            case binary:match(binary:replace(All, <<"\r">>, <<>>, [global]), Pattern) of
                nomatch -> await(Master, Tty, Pattern, All);
                _ -> {ok, All}
            end
    after ?WAIT_MS ->
            {timeout, Pattern, Seen}
    end.
