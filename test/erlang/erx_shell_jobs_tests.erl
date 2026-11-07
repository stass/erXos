%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_jobs_tests).
-moduledoc """
EUnit cases of the job table (erx_shell_jobs): an exhaustive exploration of
every table reachable within a few events from the empty one, checking the
table's invariants and that each effect agrees with the table before and
after the event that made it, and cases of the reports, job specifications
and `kill`'s arguments.
""".

-include_lib("eunit/include/eunit.hrl").

%% Tags, waiters and the depth the exploration reaches.
-define(TAGS, [a, b, c]).
-define(DEPTH, 6).

%%% The exhaustive exploration

exhaustive_test_() ->
    {timeout, 120, fun() -> explore() end}.

%% Breadth first, each table once: every event applies to every table seen,
%% and check/4 judges each step.
explore() ->
    Start = erx_shell_jobs:new(),
    Seen = explore([Start], #{key(Start) => Start}, 0),
    %% The exploration reaches stopped, running and done jobs, and a job
    %% in the foreground with the line.
    Views = [erx_shell_jobs:view(J) || J <- maps:values(Seen)],
    States = lists:usort([Run || #{jobs := Jobs} <- Views, {_, Run, _} <- maps:values(Jobs)]),
    ?assertEqual([done, running, stopped], States),
    ?assert(lists:any(fun(#{fg := Fg}) -> Fg =/= none end, Views)).

explore(_Frontier, Seen, ?DEPTH) ->
    Seen;
explore(Frontier, Seen, Depth) ->
    Next = [J1 || J <- Frontier, Event <- events(J, Depth), J1 <- [step(Event, J)]],
    {Frontier1, Seen1} = lists:foldl(fun(J, {F, S}) ->
                                             K = key(J),
                                             case S of
                                                 #{K := _} -> {F, S};
                                                 _ -> {[J | F], S#{K => J}}
                                             end
                                     end, {[], Seen}, Next),
    explore(Frontier1, Seen1, Depth + 1).

%% The whole table: order, the signal ending a job and the waiter all
%% change what later events do.
key(J) -> J.

%% Every event that can reach the table: a tag starts only once while it is
%% held, as erx_shell tags each job with a process of its own.
events(J, Depth) ->
    #{line := Line, jobs := Jobs} = erx_shell_jobs:view(J),
    Held = [T || T <- [Line], T =/= none] ++ [T || {T, _, _} <- maps:values(Jobs)],
    Free = ?TAGS -- Held,
    Specs = [current, previous, {id, 1}, {id, 2}, {id, 9}],
    [{start_line, T} || T <- Free, Line =:= none]
        ++ [{start_background, T} || T <- Free]
        ++ [suspend, interrupt, reap, list]
        ++ [{ended, T, R} || T <- ?TAGS, R <- [{exited, <<>>}, {exited, <<"1">>}, failed]]
        ++ [{fg, S, {w, Depth}} || S <- Specs]
        ++ [{bg, S} || S <- Specs]
        ++ [{signal, Sig, S} || S <- Specs,
                                Sig <- [{terminate, <<"TERM">>}, {stop, <<"STOP">>},
                                        {continue, <<"CONT">>}]].

step(Event, J) ->
    {Effects, J1} = apply_event(Event, J),
    ok = check(Event, J, Effects, J1),
    J1.

apply_event({start_line, T}, J) -> {[], erx_shell_jobs:start_line(T, <<"line">>, J)};
apply_event({start_background, T}, J) ->
    {_Id, E, J1} = erx_shell_jobs:start_background(T, <<"bg">>, J),
    {E, J1};
apply_event(suspend, J) -> erx_shell_jobs:suspend(J);
apply_event(interrupt, J) -> erx_shell_jobs:interrupt(J);
apply_event(reap, J) -> erx_shell_jobs:reap(J);
apply_event(list, J) ->
    {_Text, J1} = erx_shell_jobs:list(J),
    {[], J1};
apply_event({ended, T, R}, J) -> erx_shell_jobs:ended(T, R, J);
apply_event({fg, S, W}, J) -> drop_reply(erx_shell_jobs:foreground(S, W, J));
apply_event({bg, S}, J) -> drop_reply(erx_shell_jobs:background(S, J));
apply_event({signal, Sig, S}, J) -> drop_reply(erx_shell_jobs:signal(Sig, S, J)).

drop_reply({_Reply, Effects, J}) -> {Effects, J}.

%% The invariants hold after every event, and each effect agrees with the
%% tables on either side of it.
check(Event, J0, Effects, J1) ->
    ?assertEqual({Event, true}, {Event, erx_shell_jobs:invariant(J1)}),
    V0 = erx_shell_jobs:view(J0),
    V1 = erx_shell_jobs:view(J1),
    [check_effect(E, V0, V1) || E <- Effects],
    check_event(Event, V0, Effects, V1),
    ok.

%% Stopping pauses a running job, which is stopped after; resuming one that
%% was stopped leaves it running; the answer goes to the waiter of the job
%% in the foreground, which then is not; only a held tag is ended.
check_effect({stop, T}, V0, V1) ->
    ?assert(is_line(T, V0) orelse run_of(T, V0) =:= running),
    ?assertEqual(stopped, run_of(T, V1));
check_effect({resume, T}, V0, V1) ->
    ?assertEqual(stopped, run_of(T, V0)),
    ?assertEqual(running, run_of(T, V1));
check_effect({terminate, T}, V0, _V1) ->
    ?assert(is_line(T, V0) orelse run_of(T, V0) =/= none);
check_effect({release, T, _Fate}, V0, _V1) ->
    ?assert(is_line(T, V0) orelse run_of(T, V0) =/= none);
check_effect({finish_line, T}, V0, V1) ->
    ?assert(is_line(T, V0)),
    ?assertEqual(none, maps:get(line, V1));
check_effect({answer, _W, {ok, Status}}, V0 = #{fg := Fg}, #{fg := Fg1}) ->
    ?assert(is_binary(Status)),
    ?assertNotEqual(none, Fg),
    ?assertEqual(none, Fg1),
    ?assertMatch({_, running, true}, maps:get(Fg, maps:get(jobs, V0)));
check_effect({say, Bytes}, _V0, _V1) ->
    ?assert(is_binary(iolist_to_binary(Bytes))).

check_event(interrupt, _V0, _Effects, V1) ->
    ?assertMatch(#{line := none, fg := none}, V1);
check_event(suspend, #{line := Line, fg := Fg}, Effects, V1) when Line =/= none ->
    %% The job in the foreground stops first; otherwise the line does.
    case Fg of
        none -> ?assertMatch(#{line := none}, V1);
        _ -> ?assertMatch(#{line := Line, fg := none}, V1)
    end,
    ?assertMatch([{stop, _} | _], Effects);
check_event({ended, T, _R}, V0, Effects, V1) ->
    case is_line(T, V0) orelse run_of(T, V0) =/= none of
        true -> ?assertEqual(1, length([E || E = {release, T1, _} <- Effects, T1 =:= T]));
        false -> ?assertEqual({[], V0}, {Effects, V1})
    end;
check_event(_Event, _V0, _Effects, _V1) ->
    ok.

is_line(T, #{line := Line}) -> T =:= Line.

run_of(T, #{jobs := Jobs}) ->
    case [Run || {T1, Run, _} <- maps:values(Jobs), T1 =:= T] of
        [Run] -> Run;
        [] -> none
    end.

%%% Cases

%% A line that Ctrl-Z stops takes the lowest free number and is reported,
%% and `fg` brings it back with its command shown.
stop_and_continue_test() ->
    J0 = erx_shell_jobs:start_line(l, <<"sleep">>, erx_shell_jobs:new()),
    {E1, J1} = erx_shell_jobs:suspend(J0),
    ?assertMatch([{stop, l}, {say, _}], E1),
    [_, {say, Shown}] = E1,
    ?assertEqual(<<"^Z\n[1] + Suspended               sleep\n">>, iolist_to_binary(Shown)),
    ?assertEqual(idle, erx_shell_jobs:line(J1)),
    J2 = erx_shell_jobs:start_line(m, <<"fg">>, J1),
    {wait, E3, J3} = erx_shell_jobs:foreground(current, w, J2),
    ?assertEqual([{say, [<<"sleep">>, $\n]}, {resume, l}], E3),
    %% Ctrl-Z stops the job in the foreground, not the line waiting for it.
    {E4, J4} = erx_shell_jobs:suspend(J3),
    ?assertMatch([{stop, l}, {say, _}, {answer, w, {ok, <<"sigtstp">>}}], E4),
    ?assertEqual(busy, erx_shell_jobs:line(J4)).

%% Ctrl-C ends the line and the job it waits for, never a background job.
interrupt_spares_background_test() ->
    {1, _, J0} = erx_shell_jobs:start_background(b, <<"spin">>, erx_shell_jobs:new()),
    {2, _, J1} = erx_shell_jobs:start_background(f, <<"other">>, J0),
    J2 = erx_shell_jobs:start_line(l, <<"fg %2">>, J1),
    {wait, _, J3} = erx_shell_jobs:foreground({id, 2}, w, J2),
    {E4, J4} = erx_shell_jobs:interrupt(J3),
    ?assertEqual([{terminate, f}, {terminate, l}, {say, <<"^C\n">>}], E4),
    ?assertMatch(#{line := none, fg := none, jobs := #{1 := {b, running, false}}},
                 erx_shell_jobs:view(J4)),
    ?assertEqual(1, map_size(maps:get(jobs, erx_shell_jobs:view(J4)))).

%% `kill` ends a job, which is reported with the signal's name once its
%% first process has ended, and leaves the table with the report.
kill_and_report_test() ->
    {1, [{say, Started}], J0} = erx_shell_jobs:start_background(b, <<"spin">>, erx_shell_jobs:new()),
    ?assertEqual(<<"[1]\n">>, iolist_to_binary(Started)),
    {ok, [{terminate, b}], J1} = erx_shell_jobs:signal({terminate, <<"TERM">>}, {id, 1}, J0),
    {[{release, b, kill}], J2} = erx_shell_jobs:ended(b, failed, J1),
    ?assertEqual(none, erx_shell_jobs:line_tag(J2)),
    {Listed, J3} = erx_shell_jobs:list(J2),
    ?assertEqual(<<"[1] + Terminated              spin\n">>, iolist_to_binary(Listed)),
    ?assertEqual({[], J3}, erx_shell_jobs:reap(J3)),
    ?assertEqual({{error, <<"no current job">>}, [], J3}, erx_shell_jobs:background(current, J3)).

%% A job's command and status reach the terminal escaped.
report_escapes_test() ->
    {1, _, J0} = erx_shell_jobs:start_background(b, <<"echo \e[2J">>, erx_shell_jobs:new()),
    {_, J1} = erx_shell_jobs:ended(b, {exited, <<"bad\e]0;x\^G">>}, J0),
    {[{say, Report}], _} = erx_shell_jobs:reap(J1),
    Bytes = iolist_to_binary(Report),
    ?assertEqual(nomatch, binary:match(Bytes, [<<"\e">>, <<"\^G">>])).

%% Requests from any process are checked whole before the table sees them.
valid_request_test_() ->
    [?_assert(erx_shell_jobs:valid_request({jobs})),
     ?_assert(erx_shell_jobs:valid_request({fg, {id, 2}})),
     ?_assert(erx_shell_jobs:valid_request({signal, {stop, <<"TSTP">>}, previous})),
     ?_assert(erx_shell_jobs:valid_request({background, fun() -> <<>> end})),
     ?_assertNot(erx_shell_jobs:valid_request({fg, bogus})),
     ?_assertNot(erx_shell_jobs:valid_request({fg, {id, 0}})),
     ?_assertNot(erx_shell_jobs:valid_request({signal, {terminate, 1}, current})),
     ?_assertNot(erx_shell_jobs:valid_request({signal, {stop, <<"TERM">>}, current})),
     ?_assertNot(erx_shell_jobs:valid_request({background, fun(_) -> ok end})),
     ?_assertNot(erx_shell_jobs:valid_request(jobs))].

specs_test_() ->
    [?_assertEqual({ok, current}, erx_shell_jobs:parse_spec(<<"%%">>)),
     ?_assertEqual({ok, current}, erx_shell_jobs:parse_spec(<<"%+">>)),
     ?_assertEqual({ok, current}, erx_shell_jobs:parse_spec(<<"%">>)),
     ?_assertEqual({ok, previous}, erx_shell_jobs:parse_spec(<<"%-">>)),
     ?_assertEqual({ok, {id, 12}}, erx_shell_jobs:parse_spec(<<"%12">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%0">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%1234567">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%-1">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"%sleep">>)),
     ?_assertEqual(error, erx_shell_jobs:parse_spec(<<"12">>))].

kill_args_test_() ->
    [?_assertEqual({ok, {terminate, <<"TERM">>}, [<<"%1">>]}, erx_shell_jobs:parse_kill([<<"%1">>])),
     ?_assertEqual({ok, {terminate, <<"KILL">>}, [<<"%1">>]},
                   erx_shell_jobs:parse_kill([<<"-9">>, <<"%1">>])),
     ?_assertEqual({ok, {stop, <<"STOP">>}, [<<"%1">>]},
                   erx_shell_jobs:parse_kill([<<"-s">>, <<"sigstop">>, <<"%1">>])),
     ?_assertEqual({ok, {continue, <<"CONT">>}, [<<"%1">>, <<"%2">>]},
                   erx_shell_jobs:parse_kill([<<"-CONT">>, <<"%1">>, <<"%2">>])),
     ?_assertEqual({ok, {terminate, <<"TERM">>}, [<<"-1">>]},
                   erx_shell_jobs:parse_kill([<<"--">>, <<"-1">>])),
     ?_assertEqual(list, erx_shell_jobs:parse_kill([<<"-l">>])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([<<"-9">>])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([<<"-WINCH">>, <<"%1">>])),
     ?_assertEqual(usage, erx_shell_jobs:parse_kill([<<"-999">>, <<"%1">>])),
     ?_assertEqual(<<"HUP INT QUIT KILL TERM STOP TSTP CONT\n">>, erx_shell_jobs:signal_names())].
