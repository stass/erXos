%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_prog_handler_tests).
-moduledoc """
erx_prog_handler, the effect process, with the real pipe server over a
fake NIF (erx_pipe_fake_nif) and stand-ins for the program driver, the
pixel allocator (test/erlang/stand_in, answering from
erx_prog_handler_fakes). The test
process is the starter: it makes a pipe and starts a program with its
ends. A start hands the program an end of each kind with the starter as
holder; an end the starter does not hold is refused with everything
undone; a holder entry the NIF cannot make
answers its errno; a buffer where no allocator runs is refused with
everything undone; a refused start drops every hand-off, gives back the lease and
lets the holder entry go; a buffer is allocated and lent by the handler
and its offset answered; the program's notice reaches the pipe server as
the program's; a report owed while the lane is busy waits for room; a
hand-off report is installed and sent filled; the exit tells the
starter and ends the handler, also when a report or a stop meets the
port the driver closed at the program's end; a port closed with no
status ends the handler; the starter's exit stops the program; and the pipe server's
loss reaches the program.
""".

-include_lib("eunit/include/eunit.hrl").

-define(PID, 21).
-define(WAIT, 2000).

handler_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun start_hands_each_end_to_the_program/1,
      fun a_holder_entry_the_nif_cannot_make_is_its_errno/1,
      fun a_buffer_without_an_allocator_is_refused/1,
      fun an_end_of_another_process_is_refused/1,
      fun refused_start_undoes_everything/1,
      fun buffer_is_lent_by_the_handler/1,
      fun notice_reaches_the_pipe_server/1,
      fun owed_report_waits_for_room/1,
      fun hand_off_report_is_installed_then_sent/1,
      fun exit_tells_the_starter/1,
      fun an_end_behind_a_closed_port_still_tells_the_starter/1,
      fun a_port_closed_without_a_status_ends_the_handler/1,
      fun starters_exit_stops_the_program/1,
      fun pipe_server_loss_reaches_the_program/1]}.

setup() ->
    erx_pipe_fake_nif:setup(self()),
    erx_prog_handler_fakes:setup(self()),
    {ok, Srv} = erx_pipe_srv:start_link(#{nif => erx_pipe_fake_nif}),
    unlink(Srv),
    Srv.

cleanup(Srv) ->
    %% A handler left running would answer a later case's pipe server loss.
    [exit(H, kill) || H <- erlang:get_keys(handler)],
    [erlang:erase(H) || H <- erlang:get_keys(handler)],
    Ref = monitor(process, Srv),
    exit(Srv, kill),
    receive {'DOWN', Ref, process, Srv, _} -> ok end,
    flush().

spec(Fds) ->
    #{image => <<"bin/pipeio">>, pid => ?PID, ppid => 1, pgid => ?PID, argv => [<<"pipeio">>], env => [],
      cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022, fds => Fds}.

%% A started program: its handler, its fake port and the descriptors its start named.
started(Fds) ->
    {ok, H, _} = erx_prog_handler:start(spec(Fds)),
    erlang:put(H, handler),
    {start, #{fds := Named}, Port} = fake(start),
    {H, Port, Named}.

start_hands_each_end_to_the_program(_) ->
    {ok, R, W} = erx_pipe_srv:pipe(),
    {_H, _Port, Named} = started([{0, {pipe, R}}, {1, {pipe, W}}]),
    Calls = nif_calls(),
    [?_assertMatch([{0, {pipe_hand, _, {pipe, read, {1, 3}, _}}}, {1, {pipe_hand, _, {pipe, write, {1, 4}, _}}}],
                   Named),
     ?_assert(lists:member({program_holder, ?PID}, Calls))].

an_end_of_another_process_is_refused(_) ->
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Self = self(),
    Other = spawn(fun() -> {ok, _, OW} = erx_pipe_srv:pipe(), Self ! {other, OW}, receive stop -> ok end end),
    OtherW = receive {other, OW} -> OW end,
    Answer = erx_prog_handler:start(spec([{0, {pipe, R}}, {1, {pipe, OtherW}}])),
    Calls = nif_calls(),
    Other ! stop,
    [?_assertEqual({error, ebadf}, Answer),
     ?_assertMatch([_], [N || {hand_drop, N} <- Calls]),
     ?_assert(lists:member({holder_drop, ?PID}, Calls)),
     ?_assertEqual(none, erx_pipe_fake_nif:holder_owner(?PID))].

a_holder_entry_the_nif_cannot_make_is_its_errno(_) ->
    erx_pipe_fake_nif:fail([program_holder]),
    Answer = erx_prog_handler:start(spec([])),
    Calls = nif_calls(),
    [?_assertEqual({error, enomem}, Answer),
     ?_assertNot(lists:member({holder_drop, ?PID}, Calls))].

a_buffer_without_an_allocator_is_refused(_) ->
    erx_prog_handler_fakes:set(pixels, absent),
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Answer = erx_prog_handler:start(spec([{0, {pipe, R}}, {3, {buffer, 5, 8192}}])),
    Calls = nif_calls(),
    Started = receive {fake, {start, _, _}} = M -> M after 200 -> none end,
    [?_assertEqual({error, enodev}, Answer),
     ?_assertMatch([_], [N || {hand_drop, N} <- Calls]),
     ?_assert(lists:member({holder_drop, ?PID}, Calls)),
     ?_assertEqual(none, Started)].

refused_start_undoes_everything(_) ->
    erx_prog_handler_fakes:set(start, {error, einval}),
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Answer = erx_prog_handler:start(spec([{0, {pipe, R}}, {3, {buffer, 5, 8192}}])),
    {start, #{fds := [{0, {pipe_hand, Number, _}}, {3, {mem, 77, 2}}]}, _} = fake(start),
    Calls = nif_calls(),
    Unlent = fake(unlend),
    [?_assertEqual({error, einval}, Answer),
     ?_assert(lists:member({hand_drop, Number}, Calls)),
     ?_assertEqual({unlend, 77}, Unlent),
     ?_assert(lists:member({holder_drop, ?PID}, Calls))].

buffer_is_lent_by_the_handler(_) ->
    {ok, H, Offsets} = erx_prog_handler:start(spec([{3, {buffer, 5, 8192}}])),
    erlang:put(H, handler),
    Calls = [fake(alloc), fake(lend), fake(start)],
    [?_assertEqual([{3, 4096}], Offsets),
     ?_assertMatch([{alloc, 5, 8192}, {lend, 5, 4096}, {start, #{fds := [{3, {mem, 77, 2}}]}, _}], Calls),
     ?_assert(is_process_alive(H))].

notice_reaches_the_pipe_server(_) ->
    {ok, R, W} = erx_pipe_srv:pipe(),
    {H, Port, [{1, {pipe_hand, _, {pipe, write, {1, End}, _}}}]} = started([{1, {pipe, W}}]),
    nif_calls(),
    H ! {erx_channel, Port, {erx_prog, 1, {closed, 1, End}}},
    %% The program's write end gone, the pipe server tells the starter's read
    %% end, which it applies first.
    Applied = nif_call(apply),
    ?_assertEqual({apply, R, {pipe_writer_gone, 1, 1, 2}}, Applied).

owed_report_waits_for_room(_) ->
    erx_prog_handler_fakes:set(sends, [busy]),
    {H, Port, []} = started([]),
    H ! {pipe_report, ?PID, {pipe_lost, 9, 1}},
    H ! {pipe_report, ?PID, {pipe_lost, 9, 2}},
    First = fake(send),
    Nothing = receive {fake, {send, _, _}} = M -> M after 200 -> none end,
    H ! {erx_channel_room, Port},
    Again = fake(send),
    Second = fake(send),
    [?_assertEqual({send, Port, {erx_prog, 1, {pipe_lost, 9, 1}}}, First),
     ?_assertEqual(none, Nothing),
     ?_assertEqual(First, Again),
     ?_assertEqual({send, Port, {erx_prog, 1, {pipe_lost, 9, 2}}}, Second)].

hand_off_report_is_installed_then_sent(_) ->
    {H, Port, []} = started([]),
    H ! {pipe_report, ?PID, {pipe_hand, 8, {pipe_reader, 9, 1, 2, {hand, 1}, open}}},
    Calls = [fake(install), fake(send)],
    ?_assertEqual([{install, Port, 8}, {send, Port, {erx_prog, 1, {pipe_reader, 9, 1, 2, 100, open}}}], Calls).

exit_tells_the_starter(_) ->
    {H, Port, []} = started([]),
    Ref = monitor(process, H),
    H ! {Port, {exit_status, 42}},
    Told = receive {erx_prog_exit, H, S} -> S after ?WAIT -> timeout end,
    Down = receive {'DOWN', Ref, process, H, Why} -> Why after ?WAIT -> timeout end,
    [?_assertEqual({exited, 42}, Told), ?_assertEqual(normal, Down)].

%% The driver writes the exit status and closes the port in one step, so a
%% report and a stop the handler takes ahead of the status meet a closed port.
an_end_behind_a_closed_port_still_tells_the_starter(_) ->
    erx_prog_handler_fakes:set(start, {program, "read x; exit 42"}),
    {H, Port, []} = started([]),
    Ref = monitor(process, H),
    erlang:suspend_process(H),
    H ! {pipe_report, ?PID, {pipe_lost, 9, 1}},
    erx_prog_handler:stop(H),
    true = port_command(Port, <<"\n">>),
    Closed = closed(Port, 200),
    erlang:resume_process(H),
    Told = receive {erx_prog_exit, H, S} -> S after ?WAIT -> timeout end,
    Down = receive {'DOWN', Ref, process, H, Why} -> Why after ?WAIT -> timeout end,
    [?_assert(Closed), ?_assertEqual({exited, 42}, Told), ?_assertEqual(normal, Down)].

%% A port the driver closes with no status, as it does when the program's
%% records may be lost, ends the handler, which reports no status it did not read.
a_port_closed_without_a_status_ends_the_handler(_) ->
    erx_prog_handler_fakes:set(start, {program, "read x"}),
    {H, Port, []} = started([]),
    Ref = monitor(process, H),
    true = port_close(Port),
    Down = receive {'DOWN', Ref, process, H, Why} -> Why after ?WAIT -> timeout end,
    Told = receive {erx_prog_exit, H, S} -> S after 100 -> none end,
    [?_assertEqual(normal, Down), ?_assertEqual(none, Told)].

%% Whether Port closes within Tries waits of 10 ms.
closed(_Port, 0) -> false;
closed(Port, Tries) ->
    case erlang:port_info(Port) of
        undefined -> true;
        _ -> receive after 10 -> closed(Port, Tries - 1) end
    end.

starters_exit_stops_the_program(_) ->
    Self = self(),
    Starter = spawn(fun() -> Self ! {started, erx_prog_handler:start(spec([]))} end),
    {ok, H, []} = receive {started, A} -> A after ?WAIT -> timeout end,
    erlang:put(H, handler),
    {start, _, Port} = fake(start),
    _ = Starter,
    Stopped = fake(stop),
    ?_assertEqual({stop, Port, 256 + 9}, Stopped).

pipe_server_loss_reaches_the_program(Srv) ->
    {_H, Port, []} = started([]),
    exit(Srv, kill),
    Sent = fake(send),
    ?_assertEqual({send, Port, {erx_prog, 1, pipe_server_lost}}, Sent).

fake(Kind) ->
    receive {fake, Call} when element(1, Call) =:= Kind -> Call after ?WAIT -> {timeout, Kind} end.

nif_call(Kind) ->
    receive {nif, Call} when element(1, Call) =:= Kind -> Call after ?WAIT -> {timeout, Kind} end.

nif_calls() ->
    receive {nif, Call} -> [Call | nif_calls()] after 100 -> [] end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
