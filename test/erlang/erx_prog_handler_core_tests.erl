%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_core_tests).
-moduledoc """
erx_prog_handler_core, the handler's decisions: the descriptors are
reserved one at a time in order and the start follows; a refusal at any
step undoes exactly what was reserved; reports queue behind the start and
one is out at a time, an owed one waiting for room; a hand-off report is
installed before it is sent and a refused install becomes the pipe
server's install_failed; notices name the program; a stop is asked once;
and the exit status tells the starter and ends the handler. A bounded
exhaustive walk over every sequence of the running phase's events checks
that at most one frame is ever out, that frames reach the program in the
order they were queued, and that nothing follows the end.
""".

-include_lib("eunit/include/eunit.hrl").

-define(PID, 21).
-define(HAND(N), {pipe_hand, N, {pipe, read, {9, N}, #{lock => {hand, 1}}}}).

new_refuses_bad_specs_test_() ->
    [?_assertEqual({error, einval}, erx_prog_handler_core:new(1, [])),
     ?_assertEqual({error, einval}, erx_prog_handler_core:new(?PID, [{0, {pipe, a}}, {0, {pipe, b}}])),
     ?_assertEqual({error, einval}, erx_prog_handler_core:new(?PID, [{1024, {pipe, a}}])),
     ?_assertEqual({error, einval}, erx_prog_handler_core:new(?PID, [{3, {buffer, 1, 4096}}, {4, {buffer, 1, 4096}}])),
     ?_assertEqual({error, einval}, erx_prog_handler_core:new(?PID, [{3, {mem, 1, 1}}])),
     ?_assertMatch({ok, _, [holder]}, erx_prog_handler_core:new(?PID, []))].

reserves_in_order_then_starts_test() ->
    {ok, C0, [holder]} = erx_prog_handler_core:new(?PID, [{0, {pipe, r}}, {3, {buffer, 5, 8192}}, {1, {pipe, w}}]),
    {C1, [{inherit, r}]} = erx_prog_handler_core:step(C0, {holder, ok}),
    {C2, [{lend, 5, 8192}]} = erx_prog_handler_core:step(C1, {reserved, ?HAND(1)}),
    {C3, [{inherit, w}]} = erx_prog_handler_core:step(C2, {reserved, {mem, 77, 2, 4096}}),
    {C4, [{start, Fds}]} = erx_prog_handler_core:step(C3, {reserved, ?HAND(2)}),
    ?assertEqual([{0, ?HAND(1)}, {3, {mem, 77, 2}}, {1, ?HAND(2)}], Fds),
    {C5, [{answer, {ok, [{3, 4096}]}}]} = erx_prog_handler_core:step(C4, started),
    ?assertEqual(running, erx_prog_handler_core:phase(C5)).

refused_start_undoes_everything_test() ->
    {ok, C0, _} = erx_prog_handler_core:new(?PID, [{0, {pipe, r}}, {3, {buffer, 5, 8192}}, {1, {pipe, w}}]),
    C3 = run(C0, [{holder, ok}, {reserved, ?HAND(1)}, {reserved, {mem, 77, 2, 4096}}, {reserved, ?HAND(2)}]),
    {C4, Actions} = erx_prog_handler_core:step(C3, {refused, enomem}),
    ?assertEqual([{hand_drop, 1}, {hand_drop, 2}, {unlend, 77}, holder_drop, {answer, {error, enomem}}, exit],
                 Actions),
    ?assertEqual(ended, erx_prog_handler_core:phase(C4)).

refused_reservation_undoes_what_came_before_test_() ->
    {ok, C0, _} = erx_prog_handler_core:new(?PID, [{0, {pipe, r}}, {1, {pipe, w}}]),
    C1 = run(C0, [{holder, ok}, {reserved, ?HAND(1)}]),
    {_, Actions} = erx_prog_handler_core:step(C1, {refused, ebadf}),
    {_, Refused} = erx_prog_handler_core:step(run(C0, []), {holder, {error, eexist}}),
    {_, NoMemory} = erx_prog_handler_core:step(run(C0, []), {holder, {error, enomem}}),
    [?_assertEqual([{hand_drop, 1}, holder_drop, {answer, {error, ebadf}}, exit], Actions),
     %% Another handler's entry is not this handler's to drop.
     ?_assertEqual([{answer, {error, einval}}, exit], Refused),
     ?_assertEqual([{answer, {error, enomem}}, exit], NoMemory)].

reports_wait_for_the_start_test() ->
    {ok, C0, _} = erx_prog_handler_core:new(?PID, [{0, {pipe, r}}]),
    C1 = run(C0, [{holder, ok}, {report, {pipe_lost, 9, 1}}, {reserved, ?HAND(1)}]),
    {_, Actions} = erx_prog_handler_core:step(C1, started),
    ?assertEqual([{answer, {ok, []}}, {send, {erx_prog, 1, {pipe_lost, 9, 1}}}], Actions).

owed_frame_waits_for_room_test() ->
    C0 = running(),
    {C1, [{send, F1}]} = erx_prog_handler_core:step(C0, {report, {pipe_lost, 9, 1}}),
    {C2, []} = erx_prog_handler_core:step(C1, {report, {pipe_lost, 9, 2}}),
    {C3, []} = erx_prog_handler_core:step(C2, {sent, busy}),
    {C4, []} = erx_prog_handler_core:step(C3, {report, {pipe_lost, 9, 3}}),
    {C5, [{send, F1}]} = erx_prog_handler_core:step(C4, room),
    {_, [{send, F2}]} = erx_prog_handler_core:step(C5, {sent, ok}),
    ?assertEqual({erx_prog, 1, {pipe_lost, 9, 2}}, F2).

hand_off_is_installed_then_sent_test_() ->
    Report = {pipe_reader, 9, 1, 2, {hand, 1}, open},
    C0 = running(),
    {C1, [{install, {pipe_hand, 4, Report}}]} = erx_prog_handler_core:step(C0, {report, {pipe_hand, 4, Report}}),
    {_, Sent} = erx_prog_handler_core:step(C1, {installed, {pipe_reader, 9, 1, 2, 500, open}}),
    {C2, Refused} = erx_prog_handler_core:step(C1, {install_refused, einval}),
    [?_assertEqual([{send, {erx_prog, 1, {pipe_reader, 9, 1, 2, 500, open}}}], Sent),
     ?_assertEqual([{forward, {install_failed, {program, ?PID}, 9, 1}}], Refused),
     ?_assertEqual(running, erx_prog_handler_core:phase(C2))].

notices_name_the_program_test_() ->
    C = running(),
    [?_assertEqual({C, [{forward, {closed, {program, ?PID}, 9, 1}}]},
                   erx_prog_handler_core:step(C, {frame, {erx_prog, 1, {closed, 9, 1}}})),
     ?_assertEqual({C, [{forward, {drained, {program, ?PID}, 9, 1, 3}}]},
                   erx_prog_handler_core:step(C, {frame, {erx_prog, 1, {drained, 9, 1, 3}}})),
     ?_assertEqual({C, []}, erx_prog_handler_core:step(C, {frame, {erx_prog, 1, 0, anything}}))].

stop_once_then_exit_test() ->
    {C1, [{stop, 265}]} = erx_prog_handler_core:step(running(), stop),
    {C2, []} = erx_prog_handler_core:step(C1, stop),
    {C3, [{tell_starter, 265}, exit]} = erx_prog_handler_core:step(C2, {exit_status, 265}),
    ?assertEqual(ended, erx_prog_handler_core:phase(C3)),
    ?assertEqual({C3, []}, erx_prog_handler_core:step(C3, {report, {pipe_lost, 9, 1}})).

refused_send_stops_the_program_test() ->
    {C1, [{send, _}]} = erx_prog_handler_core:step(running(), {report, {pipe_lost, 9, 1}}),
    {C2, []} = erx_prog_handler_core:step(C1, {report, {pipe_lost, 9, 2}}),
    {C3, Actions} = erx_prog_handler_core:step(C2, {sent, {error, enomem}}),
    ?assertEqual([{stop, 265}], Actions),
    %% Nothing queued behind the lost frame reaches the program.
    ?assertEqual({C3, []}, erx_prog_handler_core:step(C3, room)),
    %% Nor does a report that arrives after it, while the stop takes effect.
    ?assertMatch({_, []}, erx_prog_handler_core:step(C3, {report, {pipe_lost, 9, 3}})).

%% Every sequence of up to DEPTH running-phase events, the driver's answers
%% included wherever they may come.
-define(DEPTH, 7).

exhaustive_running_walk_test() ->
    Count = walk(running(), #{out => none, queued => [], sent => [], next => 1, ended => false}, ?DEPTH, 0),
    ?assert(Count > 10000).

walk(_C, _M, 0, Count) ->
    Count + 1;
walk(C, M, Depth, Count) ->
    lists:foldl(fun(Event, Acc) ->
                        {C1, Actions} = erx_prog_handler_core:step(C, Event),
                        M1 = check(Event, Actions, M),
                        walk(C1, M1, Depth - 1, Acc)
                end, Count + 1, events(M)).

%% The reports are numbered so the order they reach the program can be checked.
events(#{next := N}) ->
    [{report, {pipe_lost, 9, N}}, {sent, ok}, {sent, busy}, room, stop, {exit_status, 0},
     {frame, {erx_prog, 1, {closed, 9, 1}}}].

%% The model: each report is queued; a send takes the oldest unsent; at most
%% one send is out; after the end nothing happens.
check(_Event, Actions, #{ended := true} = M) ->
    ?assertEqual([], Actions),
    M;
check(Event, Actions, M0) ->
    M1 = case {Event, maps:get(out, M0)} of
             {{report, {pipe_lost, _, N}}, _} -> M0#{queued := maps:get(queued, M0) ++ [N], next := N + 1};
             {{sent, ok}, sending} ->
                 [_ | Rest] = maps:get(queued, M0),
                 M0#{out := none, queued := Rest};
             %% busy keeps the head owed; room lets the same head go again.
             {{sent, busy}, sending} -> M0#{out := owed};
             {room, owed} -> M0#{out := none};
             {{exit_status, _}, _} -> M0#{ended := true};
             _ -> M0
         end,
    lists:foldl(fun({send, {erx_prog, 1, {pipe_lost, 9, N}}}, M) ->
                        ?assertEqual(none, maps:get(out, M)),
                        [Oldest | _] = maps:get(queued, M),
                        ?assertEqual(Oldest, N),
                        M#{out := sending, sent := maps:get(sent, M) ++ [N]};
                   (_, M) ->
                        M
                end, M1, Actions).

running() ->
    {ok, C0, _} = erx_prog_handler_core:new(?PID, []),
    run(C0, [{holder, ok}, started]).

run(C, Events) ->
    lists:foldl(fun(E, Acc) -> element(1, erx_prog_handler_core:step(Acc, E)) end, C, Events).
