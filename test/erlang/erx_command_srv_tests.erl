%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_command_srv_tests).
-moduledoc """
erx_command_srv, the command server's effect process, over its calls:
a handler it spawns waits for its starter's start, outside the caller,
and its end, or its starter's before the start, drops its row, whose id
is never given again; a reservation's row lasts while its caller lives;
an await is answered when the last row of its tag goes, or at once; a
job's action and a kill reach the rows' speakers; read/2 gives each
row's values as its speaker answers, and `missing` for one that ends or
does not answer in time; and where no server runs, handler/1 is
`enotsup` and programs/0 `[]`.
""".

-include_lib("eunit/include/eunit.hrl").

srv_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun a_handler_is_spawned_outside_the_caller/1,
      fun a_handler_ends_with_its_starter_before_the_start/1,
      fun a_handler_takes_no_start_without_its_key/1,
      fun an_ended_handlers_id_is_not_given_again/1,
      fun a_reservation_lasts_while_its_caller_lives/1,
      fun await_answers_when_the_last_row_goes/1,
      fun job_and_kill_reach_the_speakers/1,
      fun read_gives_missing_for_a_silent_or_ended_speaker/1]}.

setup() ->
    {ok, Srv} = erx_command_srv:start_link(),
    unlink(Srv),
    Srv.

cleanup(Srv) ->
    Ref = monitor(process, Srv),
    exit(Srv, kill),
    receive {'DOWN', Ref, process, Srv, _} -> ok end.

a_handler_is_spawned_outside_the_caller(_) ->
    {ok, H, Pid} = erx_command_srv:handler({process, job_a}, make_ref()),
    Rows = erx_command_srv:programs(),
    {links, Links} = process_info(H, links),
    exit(H, kill),
    [?_assertEqual(2, Pid),
     ?_assertEqual([#{pid => 2, ppid => 1, job => job_a, pgid => 2, handler => H}], Rows),
     ?_assertEqual([], Links)].

a_handler_ends_with_its_starter_before_the_start(_) ->
    Self = self(),
    Starter = spawn(fun() -> Self ! {handler, erx_command_srv:handler({process, job_a}, make_ref())},
                             receive stop -> ok end
                    end),
    {ok, H, _} = receive {handler, Answer} -> Answer end,
    Watch = monitor(process, H),
    Starter ! stop,
    Ended = receive {'DOWN', Watch, process, H, Reason} -> Reason after 2000 -> timeout end,
    [?_assertEqual(normal, Ended),
     ?_assertEqual([], gone())].

%% A handler that takes a start goes on to erx_prog_handler:init/2, whatever then
%% becomes of this spec, so the case traces H's calls of it instead of waiting a
%% time; the starter's end then ends a handler that took nothing, and its exit
%% (or the first call) settles the case.
a_handler_takes_no_start_without_its_key(_) ->
    Self = self(),
    Starter = spawn(fun() -> Self ! {handler, erx_command_srv:handler({process, job_a}, make_ref())},
                             receive stop -> ok end
                    end),
    {ok, H, _} = receive {handler, Answer} -> Answer end,
    Watch = monitor(process, H),
    {module, erx_prog_handler} = code:ensure_loaded(erx_prog_handler),
    1 = erlang:trace_pattern({erx_prog_handler, init, 2}, true, [local]),
    1 = erlang:trace(H, true, [call]),
    H ! {start, #{image => <<"bin/x">>}},
    H ! {start, make_ref(), #{image => <<"bin/x">>}},
    Starter ! stop,
    Built = program_built(H, Watch),
    erlang:trace_pattern({erx_prog_handler, init, 2}, false, [local]),
    [?_assertEqual(false, Built)].

%% Whether H began building a program: its first call of init/2 that
%% this sees, or, after H ended, any it made (trace_delivered orders the last).
program_built(H, Watch) ->
    receive
        {trace, H, call, {erx_prog_handler, init, _}} ->
            exit(H, kill),
            true;
        {'DOWN', Watch, process, H, _} ->
            Delivered = erlang:trace_delivered(H),
            receive {trace_delivered, H, Delivered} -> ok end,
            receive {trace, H, call, {erx_prog_handler, init, _}} -> true
            after 0 -> false end
    end.

an_ended_handlers_id_is_not_given_again(_) ->
    {ok, H1, Pid1} = erx_command_srv:handler({process, job_a}, make_ref()),
    exit(H1, kill),
    [] = gone(),
    {ok, H2, Pid2} = erx_command_srv:handler({process, job_a}, make_ref()),
    Rows = erx_command_srv:programs(),
    exit(H2, kill),
    [?_assertEqual({2, 3}, {Pid1, Pid2}),
     ?_assertMatch([#{pid := 3, pgid := 3, handler := H2}], Rows)].

a_reservation_lasts_while_its_caller_lives(_) ->
    {Relay, {ok, Pid, Pgid}} = speaker(fun() -> erx_command_srv:reserve({process, job_a}) end),
    {ok, H, _} = erx_command_srv:handler({process, job_a}, make_ref()),
    Both = erx_command_srv:programs(),
    stop(Relay),
    exit(H, kill),
    [?_assertEqual({2, 2}, {Pid, Pgid}),
     ?_assertMatch([#{pid := 2, handler := Relay}, #{pid := 3, pgid := 2, handler := H}], Both),
     ?_assertEqual([], gone())].

await_answers_when_the_last_row_goes(_) ->
    ok = erx_command_srv:await(job_b),
    AtOnce = receive {programs_ended, job_b} -> ok after 2000 -> timeout end,
    {ok, H1, _} = erx_command_srv:handler({process, job_a}, make_ref()),
    {ok, H2, _} = erx_command_srv:handler({process, job_a}, make_ref()),
    ok = erx_command_srv:await(job_a),
    exit(H1, kill),
    [_] = settled(1),
    Early = receive {programs_ended, job_a} -> early after 100 -> ok end,
    exit(H2, kill),
    Last = receive {programs_ended, job_a} -> ok after 2000 -> timeout end,
    [?_assertEqual(ok, AtOnce), ?_assertEqual(ok, Early), ?_assertEqual(ok, Last)].

job_and_kill_reach_the_speakers(_) ->
    {Relay, {ok, Pid, _}} = speaker(fun() -> erx_command_srv:reserve({process, job_a}) end),
    ok = erx_command_srv:job(job_a, pause),
    Paused = heard(Relay),
    Killed = erx_command_srv:kill({job, job_a}, Pid, sigterm, 9),
    Signal = heard(Relay),
    Outside = erx_command_srv:kill({job, job_b}, Pid, sigterm, 9),
    Probe = erx_command_srv:probe(session, Pid),
    stop(Relay),
    [?_assertEqual({erx_job, pause}, Paused),
     ?_assertEqual(ok, Killed),
     ?_assertEqual({erx_signal, sigterm, 9}, Signal),
     ?_assertEqual({error, esrch}, Outside),
     ?_assertEqual(ok, Probe)].

read_gives_missing_for_a_silent_or_ended_speaker(_) ->
    {Answering, {ok, 2, _}} = speaker(fun() -> erx_command_srv:reserve({process, job_a}) end),
    {Silent, {ok, 3, _}} = speaker(fun() -> erx_command_srv:reserve({process, job_a}) end),
    Answering ! answer,
    Rows = erx_command_srv:read([state, command], 300),
    stop(Answering),
    stop(Silent),
    [?_assertMatch([#{pid := 2, state := running, command := missing},
                    #{pid := 3, state := missing, command := missing}], Rows),
     ?_assertNot(lists:any(fun(Row) -> maps:is_key(extra, Row) end, Rows))].

no_server_test() ->
    ?assertEqual({error, enotsup}, erx_command_srv:handler({process, job_a}, make_ref())),
    ?assertEqual([], erx_command_srv:programs()),
    ?assertEqual({error, einval}, erx_prog_handler:start(#{image => <<"bin/x">>, pid => 5})),
    ?assertEqual({error, enotsup}, erx_prog_handler:start(#{image => <<"bin/x">>})).

%% A process that runs Call, tells the test its answer and then forwards
%% what reaches it; on `answer` it answers a read with a state and a key no
%% read asked for.
speaker(Call) ->
    Self = self(),
    P = spawn(fun() -> Self ! {speaker, self(), Call()}, forward(Self, silent) end),
    receive {speaker, P, Answer} -> {P, Answer} end.

forward(Test, Mode) ->
    receive
        stop -> ok;
        answer -> forward(Test, answering);
        {erx_read, Alias, _Keys} when Mode =:= answering ->
            Alias ! {erx_values, Alias, self(), #{state => running, extra => 1}},
            forward(Test, Mode);
        {erx_read, _, _} -> forward(Test, Mode);
        Other -> Test ! {heard, self(), Other}, forward(Test, Mode)
    end.

heard(P) ->
    receive {heard, P, Message} -> Message after 2000 -> timeout end.

stop(P) ->
    Ref = monitor(process, P),
    P ! stop,
    receive {'DOWN', Ref, process, P, _} -> ok end.

%% The rows once the server has taken every 'DOWN' sent so far: a call
%% queues behind them.
gone() ->
    settled(0).

settled(N) ->
    Rows = erx_command_srv:programs(),
    case length(Rows) of
        N -> Rows;
        _ -> timer:sleep(10), settled(N)
    end.
