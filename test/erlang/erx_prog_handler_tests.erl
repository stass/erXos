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
answers its errno; a buffer where the release lacks the allocator is refused
with everything undone, and one where its code is loaded and no allocator
runs with enodev; a refused start drops every hand-off, gives back the lease and
lets the holder entry go; a buffer is allocated and lent by the handler
and its offset answered; a start whose lend never answers is refused at
its deadline, its handler killed with what it held; the program's notice reaches the pipe server as
the program's; a request is answered on its slot and a frame the grammar
refuses stops the program; a report owed while the lane is busy waits for room; a
hand-off report is installed and sent filled; the program's end is the
starter's one message, the 'DOWN' of the monitor start/1 answered, with
the status as its reason: an exit, a stop, and an exit that a report and
a stop taken after it meet at the port the driver closed; a port closed
with no status ends the handler program_lost and a killed handler ends
killed, each with the program gone; the starter's exit stops the
program; and the pipe server's loss reaches the program. A program's table,
read at each resolution over the real facet registry, leaves out every
display's facet (erx_facets:program_table/1).
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The logger handler a case adds to see what the handler logs.
-export([log/2]).

%% The process id a fresh command server gives first.
-define(PID, 2).
-define(WAIT, 2000).

handler_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun start_hands_each_end_to_the_program/1,
      fun a_holder_entry_the_nif_cannot_make_is_its_errno/1,
      fun a_buffer_without_an_allocator_is_refused/1,
      fun a_buffer_where_no_allocator_runs_is_enodev/1,
      fun an_end_of_another_process_is_refused/1,
      fun refused_start_undoes_everything/1,
      fun buffer_is_lent_by_the_handler/1,
      fun a_start_past_its_deadline_frees_what_it_holds/1,
      fun notice_reaches_the_pipe_server/1,
      fun a_request_is_answered_on_its_slot/1,
      fun a_refused_frame_stops_the_program/1,
      fun a_pipe_is_made_and_installed/1,
      fun a_refused_install_undoes_the_pipe/1,
      fun owed_report_waits_for_room/1,
      fun hand_off_report_is_installed_then_sent/1,
fun ids_come_from_the_command_server/1,
fun exit_is_the_monitors_down/1,
fun a_stop_ends_signaled_sigkill/1,
fun an_end_behind_a_closed_port_keeps_its_status/1,
      fun a_port_closed_without_a_status_ends_the_handler/1,
      fun a_killed_handler_ends_its_program/1,
      fun starters_exit_stops_the_program/1,
      fun pipe_server_loss_reaches_the_program/1,
      fun a_window_without_a_display_is_enodev/1,
      fun a_refused_windowed_start_ends_what_it_made/1,
      fun a_first_draw_without_a_display_is_enodev_and_retried/1,
      fun a_first_draw_the_connection_refuses_ends_the_program/1,
      fun window_names_before_draw_are_enoent/1,
      fun opens_behind_the_first_draw_meet_its_tree/1,
      fun an_image_beneath_a_display_is_not_found/1,
      fun an_open_walks_no_display/1]}.

setup() ->
    erx_pipe_fake_nif:setup(self()),
    erx_prog_handler_fakes:setup(self()),
    {ok, Srv} = erx_pipe_srv:start_link(#{nif => erx_pipe_fake_nif}),
    unlink(Srv),
    {ok, Commands} = erx_command_srv:start_link(),
    unlink(Commands),
    [Srv, Commands].

cleanup(Servers) ->
    %% No handler outlives its case: one left running would answer a later
    %% case's pipe server loss, or send its stand-in calls into it.
    [ended(H) || H <- handlers()],
    %% Nor does the 'DOWN' of a start's monitor: it is not ordered against
    %% ended/1's own, and a handler that ended before cleanup still owes it,
    %% so it could arrive after the flush below, in the mailbox of a later
    %% case that checks it holds nothing. demonitor/2 guarantees none comes
    %% once it returns.
    [begin
         demonitor(Monitor, [flush]),
         erlang:erase(Key)
     end || {{monitor, _} = Key, Monitor} <- erlang:get()],
    [ended(Srv) || Srv <- Servers],
    flush().

%% Every live handler, found by the call its command server spawns it with.
handlers() ->
    [Pid || Pid <- processes(),
            {initial_call, {erx_prog_handler, serve, 1}} <- [process_info(Pid, initial_call)]].

%% Kills Pid and waits for its end, so every message it sent is in the
%% mailbox before cleanup/1 flushes it.
ended(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok end.

%% erx_prog_handler:start/1,2 for the test process, which keeps the monitor
%% a start answers for down/1 and for cleanup/1 to drop: the test process
%% starts a handler only through here. A start made by a process of its own
%% leaves that process the monitor.
start(Spec) -> kept(erx_prog_handler:start(Spec)).
start(Spec, Timeout) -> kept(erx_prog_handler:start(Spec, Timeout)).

kept({ok, H, Monitor, _} = Started) ->
    erlang:put({monitor, H}, Monitor),
    Started;
kept(Refused) ->
    Refused.

spec(Fds) ->
    #{image => <<"bin/pipeio">>, argv => [<<"pipeio">>], env => [],
      cwd => <<"/">>, spawn => false, sigmask => [], sigignore => [], umask => 8#022, fds => Fds}.

%% A started program: its handler, its fake port and the descriptors its start named.
started(Fds) ->
    {ok, H, _, _} = start(spec(Fds)),
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
    Answer = start(spec([{0, {pipe, R}}, {1, {pipe, OtherW}}])),
    Calls = nif_calls(),
    Other ! stop,
    [?_assertEqual({error, ebadf}, Answer),
     ?_assertMatch([_], [N || {hand_drop, N} <- Calls]),
     ?_assert(lists:member({holder_drop, ?PID}, Calls)),
     ?_assertEqual(none, erx_pipe_fake_nif:holder_owner(?PID))].

a_holder_entry_the_nif_cannot_make_is_its_errno(_) ->
    erx_pipe_fake_nif:fail([program_holder]),
    Answer = start(spec([])),
    Calls = nif_calls(),
    [?_assertEqual({error, enomem}, Answer),
     ?_assertNot(lists:member({holder_drop, ?PID}, Calls))].

a_buffer_without_an_allocator_is_refused(_) ->
    erx_prog_handler_fakes:set(pixels, absent),
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Answer = start(spec([{0, {pipe, R}}, {3, {buffer, 5, 8192}}])),
    Calls = nif_calls(),
    Started = receive {fake, {start, _, _}} = M -> M after 200 -> none end,
    [?_assertEqual({error, enodev}, Answer),
     ?_assertMatch([_], [N || {hand_drop, N} <- Calls]),
     ?_assert(lists:member({holder_drop, ?PID}, Calls)),
     ?_assertEqual(none, Started)].

%% erx_pixels's code loaded and no allocator running: the domain has no area to lend from.
a_buffer_where_no_allocator_runs_is_enodev(_) ->
    erx_prog_handler_fakes:set(pixels, stopped),
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Answer = start(spec([{0, {pipe, R}}, {3, {buffer, 5, 8192}}])),
    Calls = nif_calls(),
    Started = receive {fake, {start, _, _}} = M -> M after 200 -> none end,
    [?_assertEqual({error, enodev}, Answer),
     ?_assertMatch([_], [N || {hand_drop, N} <- Calls]),
     ?_assert(lists:member({holder_drop, ?PID}, Calls)),
     ?_assertEqual(none, Started)].

refused_start_undoes_everything(_) ->
    erx_prog_handler_fakes:set(start, {error, einval}),
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Answer = start(spec([{0, {pipe, R}}, {3, {buffer, 5, 8192}}])),
    {start, #{fds := [{0, {pipe_hand, Number, _}}, {3, {mem, 77, 2}}]}, _} = fake(start),
    Calls = nif_calls(),
    Unlent = fake(unlend),
    [?_assertEqual({error, einval}, Answer),
     ?_assert(lists:member({hand_drop, Number}, Calls)),
     ?_assertEqual({unlend, 77}, Unlent),
     ?_assert(lists:member({holder_drop, ?PID}, Calls))].

buffer_is_lent_by_the_handler(_) ->
    {ok, H, _, Offsets} = start(spec([{3, {buffer, 5, 8192}}])),
    Calls = [fake(alloc), fake(lend), fake(start)],
    [?_assertEqual([{3, 4096}], Offsets),
     ?_assertMatch([{alloc, 5, 8192, H}, {lend, 5, 4096}, {start, #{fds := [{3, {mem, 77, 2}}]}, _}], Calls),
     ?_assert(is_process_alive(H))].

%% A handler stuck in the pixel allocator's lend is killed at start/2's
%% deadline: the start answers timeout on time, the program never starts, and
%% the handler, the range's owner and the holder entry's, is gone, which is
%% what the allocator frees the range by and the NIF lets the entry go by.
a_start_past_its_deadline_frees_what_it_holds(_) ->
    erx_prog_handler_fakes:set(lend, never),
    {ok, R, _W} = erx_pipe_srv:pipe(),
    Began = erlang:monotonic_time(millisecond),
    Answer = start(spec([{0, {pipe, R}}, {3, {buffer, 5, 8192}}]), 300),
    Took = erlang:monotonic_time(millisecond) - Began,
    {alloc, 5, 8192, Owner} = fake(alloc),
    Lent = fake(lend),
    Holder = erx_pipe_fake_nif:holder_owner(?PID),
    Started = receive {fake, {start, _, _}} = M -> M after 200 -> none end,
    [?_assertEqual({error, timeout}, Answer),
     ?_assert(Took >= 300 andalso Took < 1300),
     ?_assertEqual({lend, 5, 4096}, Lent),
     ?_assertNot(is_process_alive(Owner)),
     ?_assertEqual({ok, Owner}, Holder),
     ?_assertEqual(none, Started)].

notice_reaches_the_pipe_server(_) ->
    {ok, R, W} = erx_pipe_srv:pipe(),
    {H, Port, [{1, {pipe_hand, _, {pipe, write, {1, End}, _}}}]} = started([{1, {pipe, W}}]),
    nif_calls(),
    H ! {erx_channel, Port, {erx_prog, 1, {closed, 1, End}}},
    %% The program's write end gone, the pipe server tells the starter's read
    %% end, which it applies first.
    Applied = nif_call(apply),
    ?_assertEqual({apply, R, {pipe_writer_gone, 1, 1, 2}}, Applied).

a_request_is_answered_on_its_slot(_) ->
    {H, Port, []} = started([]),
    H ! {erx_channel, Port, {erx_prog, 1, 4, {probe, ?PID}}},
    Probed = fake(send),
    H ! {erx_channel, Port, {erx_prog, 1, 9, {kill, ?PID + 1, sigterm}}},
    Killed = fake(send),
    [?_assertEqual({send, Port, {erx_prog, 1, 4, ok}}, Probed),
     ?_assertEqual({send, Port, {erx_prog, 1, 9, {error, esrch}}}, Killed),
     ?_assert(is_process_alive(H))].

a_pipe_is_made_and_installed(_) ->
    {H, Port, []} = started([]),
    H ! {erx_channel, Port, {erx_prog, 1, 4, {pipe, [cloexec]}}},
    Installs = [fake(install), fake(install)],
    Sent = fake(send),
    [?_assertMatch([{install, Port, _}, {install, Port, _}], Installs),
     ?_assertMatch({send, Port, {erx_prog, 1, 4, {ok, {pipe, read, {1, R}, #{lock := 100}},
                                                  {pipe, write, {1, W}, #{ring := 1100}}}}} when R =/= W, Sent),
     ?_assert(is_process_alive(H))].

a_refused_install_undoes_the_pipe(_) ->
    erx_prog_handler_fakes:set(install, [ok, {error, enomem}]),
    {H, Port, []} = started([]),
    H ! {erx_channel, Port, {erx_prog, 1, 4, {pipe, []}}},
    Sent = fake(send),
    Closes = [Call || {close, _} = Call <- nif_calls()],
    [?_assertEqual({send, Port, {erx_prog, 1, 4, {error, enomem}}}, Sent),
     ?_assertNotEqual([], Closes),
     ?_assert(is_process_alive(H))].

a_refused_frame_stops_the_program(_) ->
    {H, Port, []} = started([]),
    H ! {erx_channel, Port, {erx_prog, 1, 4, {kill, ?PID, 0}}},
    Stopped = fake(stop),
    [?_assertEqual({stop, Port, 256 + 12}, Stopped), ?_assert(is_process_alive(H))].

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

%% Each start takes its process id, parent and group from the command
%% server, never from its spec, and an id is not given again after its
%% program ends.
ids_come_from_the_command_server(_) ->
    {ok, H1, Ref, []} = start(spec([])),
    {start, Spec1, Port1} = fake(start),
    H1 ! {Port1, {exit_status, 0}},
    receive {'DOWN', Ref, process, H1, _} -> ok after ?WAIT -> timeout end,
    {ok, _, _, []} = start(spec([])),
    {start, Spec2, _} = fake(start),
    [?_assertEqual(#{pid => ?PID, ppid => 1, pgid => ?PID}, maps:with([pid, ppid, pgid], Spec1)),
     ?_assertEqual(#{pid => ?PID + 1, ppid => 1}, maps:with([pid, ppid], Spec2)),
     ?_assertEqual({error, einval}, start((spec([]))#{pid => 7}))].

exit_is_the_monitors_down(_) ->
    {H, Port, []} = started([]),
    H ! {Port, {exit_status, 3}},
    Down = down(H),
    Left = mailbox(),
    [?_assertEqual({shutdown, {program_exit, {exited, 3}}}, Down), ?_assertEqual([], Left)].

a_stop_ends_signaled_sigkill(_) ->
    {H, Port, []} = started([]),
    erx_prog_handler:stop(H),
    {stop, Port, Status} = fake(stop),
    H ! {Port, {exit_status, Status}},
    Down = down(H),
    ?_assertEqual({shutdown, {program_exit, {signaled, sigkill}}}, Down).

%% The driver writes the exit status and closes the port in one step, so a
%% report and a stop the handler takes ahead of the status meet a closed
%% port, and the stop changes nothing of the status read after it.
an_end_behind_a_closed_port_keeps_its_status(_) ->
    erx_prog_handler_fakes:set(start, {program, "read x; exit 3"}),
    {H, Port, []} = started([]),
    erlang:suspend_process(H),
    H ! {pipe_report, ?PID, {pipe_lost, 9, 1}},
    erx_prog_handler:stop(H),
    true = port_command(Port, <<"\n">>),
    Closed = closed(Port, 200),
    erlang:resume_process(H),
    Down = down(H),
    [?_assert(Closed), ?_assertEqual({shutdown, {program_exit, {exited, 3}}}, Down)].

%% A port the driver closes with no status, as it does when the program's
%% records may be lost, ends the handler, which reports no status it did not read.
a_port_closed_without_a_status_ends_the_handler(_) ->
    erx_prog_handler_fakes:set(start, {program, "read x"}),
    {H, Port, []} = started([]),
    true = port_close(Port),
    Down = down(H),
    ?_assertEqual(program_lost, Down).

%% The handler's crash ends the program with it: its port closes with its owner.
a_killed_handler_ends_its_program(_) ->
    erx_prog_handler_fakes:set(start, {program, "read x"}),
    {H, Port, []} = started([]),
    exit(H, kill),
    Down = down(H),
    Closed = closed(Port, 200),
    [?_assertEqual(killed, Down), ?_assert(Closed)].

%% The reason in the 'DOWN' of the monitor start/1 answered for H.
down(H) ->
    Monitor = erlang:get({monitor, H}),
    receive {'DOWN', Monitor, process, H, Why} -> Why after ?WAIT -> timeout end.

%% Every message waiting but the stand-ins' reports of their calls: once its
%% 'DOWN' came, none is for the starter.
mailbox() ->
    receive
        {Fake, _} when Fake =:= fake; Fake =:= nif -> mailbox();
        Message -> [Message | mailbox()]
    after 100 -> []
    end.

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
    {ok, _, _, []} = receive {started, A} -> A after ?WAIT -> timeout end,
    {start, _, Port} = fake(start),
    _ = Starter,
    Stopped = fake(stop),
    ?_assertEqual({stop, Port, 256 + 9}, Stopped).

pipe_server_loss_reaches_the_program([Srv, _Commands]) ->
    {_H, Port, []} = started([]),
    exit(Srv, kill),
    Sent = fake(send),
    ?_assertEqual({send, Port, {erx_prog, 1, pipe_server_lost}}, Sent).

%% A program's window (docs/design-files.md, "A program's window"), over the
%% stand-ins of test/erlang/stand_in for the window and the draw connection and
%% a real erx_fs grant of the program's /dev.
a_window_without_a_display_is_enodev(_) ->
    ?_assertEqual({error, enodev}, start((spec([]))#{window => nogrant})).

%% A start refused after the /dev tree's grant has started: the window, the
%% connection and the grant each end within 5 seconds of the handler's normal
%% exit, in any order, since each sees the handler's end on its own.
a_refused_windowed_start_ends_what_it_made(_) ->
    ok = erx_fs_version:init(),
    persistent_term:put(erx_win, self()),
    erx_prog_handler_fakes:set(start, {held, {error, enomem}}),
    Test = self(),
    spawn(fun() -> Test ! {answer, erx_prog_handler:start((spec([]))#{window => display})} end),
    {start_held, Handler} = fake(start_held),
    Made = [receive {erx_win, {opened, Window}} -> Window after 5000 -> none end,
            receive {erx_win, {conn, Conn}} -> Conn after 5000 -> none end
            | dev_grants()],
    Monitors = [monitor(process, Pid) || Pid <- Made, is_pid(Pid)],
    Handler ! go,
    Answer = receive {answer, A} -> A after 5000 -> none end,
    Ended = [receive {'DOWN', Ref, process, _, _} -> ended after 5000 -> alive end || Ref <- Monitors],
    persistent_term:erase(erx_win),
    [?_assertEqual({error, enomem}, Answer),
     ?_assertEqual(3, length(Monitors)),
     ?_assertEqual([ended, ended, ended], Ended)].

%% A window at a program's first open of /dev/draw (docs/design-programs.md, "The
%% handler"), over the stand-ins: the session's display is the facet `display` of its
%% registry, and every window, connection and open is told to the test.
-define(OPEN(Slot, Path), {erx_prog, 1, Slot, {file, lopen, Path, 2}}).
-define(REPLY(Slot, Reply), {erx_prog, 1, Slot, Reply}).

%% With no display, the open is enodev, the program runs on, and an open once the
%% session holds one opens the window and then draw on the program's own /dev.
a_first_draw_without_a_display_is_enodev_and_retried(_) ->
    first_draw(fun() ->
                       {H, Port, []} = started([]),
                       H ! {erx_channel, Port, ?OPEN(4, <<"/dev/draw">>)},
                       NoDisplay = fake(send),
                       Alive = is_process_alive(H) andalso not closed(Port, 5),
                       persistent_term:put({erx, facets}, {1, #{display => {?ERX_SERVICE_WINDOWS, {self(), ?ERX_WINDOWS_TREE_BYTES, rw}}}}),
                       H ! {erx_channel, Port, ?OPEN(5, <<"/dev/draw">>)},
                       Windows = told(opened),
                       Relayed = told(open),
                       [?_assertEqual({send, Port, ?REPLY(4, {error, enodev})}, NoDisplay),
                        ?_assert(Alive),
                        ?_assertMatch([_], Windows),
                        ?_assertMatch([{<<"/dev/draw">>, [#{provider := {grant, _, <<"export">>}}]}], Relayed)]
               end).

%% A display that grants the window and then refuses its draw connection ends the
%% handler, naming the errno, and the program with it; the window and its /dev end
%% with the handler, and the open is never answered. The handler logs the refusal
%% once, with its errno.
a_first_draw_the_connection_refuses_ends_the_program(_) ->
    first_draw(fun() ->
                       persistent_term:put({erx, facets}, {1, #{display => {?ERX_SERVICE_WINDOWS, {self(), ?ERX_WINDOWS_TREE_BYTES, rw}}}}),
                       persistent_term:put(erx_draw_conn, true),
                       ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{to => self()}}),
                       {H, Port, []} = started([]),
                       H ! {erx_channel, Port, ?OPEN(4, <<"/dev/draw">>)},
                       [Window] = told(opened),
                       Watch = monitor(process, Window),
                       Down = down(H),
                       WindowEnded = receive {'DOWN', Watch, process, Window, _} -> true after ?WAIT -> false end,
                       Closed = closed(Port, 200),
                       ok = logger:remove_handler(?MODULE),
                       Mailbox = mailbox_all(),
                       Logged = [Line || {logged, "erx_prog_handler: " ++ _ = Line} <- Mailbox],
                       [?_assertEqual({shutdown, {window, enomem}}, Down),
                        ?_assert(WindowEnded),
                        ?_assert(Closed),
                        ?_assertMatch([_], Logged),
                        ?_assertNotEqual(nomatch, string:find(lists:flatten(Logged), "enomem")),
                        ?_assertEqual([], [Sent || {fake, {send, _, _} = Sent} <- Mailbox])]
               end).

%% Before draw, ctl and kbd go to the shared /dev, which answers enoent, and open no
%% window.
window_names_before_draw_are_enoent(_) ->
    first_draw(fun() ->
                       persistent_term:put({erx, facets}, {1, #{display => {?ERX_SERVICE_WINDOWS, {self(), ?ERX_WINDOWS_TREE_BYTES, rw}}}}),
                       {H, Port, []} = started([]),
                       H ! {erx_channel, Port, ?OPEN(4, <<"/dev/ctl">>)},
                       Ctl = fake(send),
                       H ! {erx_channel, Port, ?OPEN(5, <<"/dev/kbd">>)},
                       Kbd = fake(send),
                       Windows = told(opened),
                       [?_assertEqual({send, Port, ?REPLY(4, {error, enoent})}, Ctl),
                        ?_assertEqual({send, Port, ?REPLY(5, {error, enoent})}, Kbd),
                        ?_assertEqual([], Windows)]
               end).

%% Opens sent behind the first open of draw, ctl and kbd as Doom sends them, wait
%% while its window opens and then go to the program's own /dev; a second draw opens
%% no second window.
opens_behind_the_first_draw_meet_its_tree(_) ->
    first_draw(fun() ->
                       persistent_term:put({erx, facets}, {1, #{display => {?ERX_SERVICE_WINDOWS, {self(), ?ERX_WINDOWS_TREE_BYTES, rw}}}}),
                       {H, Port, []} = started([]),
                       [H ! {erx_channel, Port, ?OPEN(Slot, Path)}
                        || {Slot, Path} <- [{4, <<"/dev/draw">>}, {5, <<"/dev/ctl">>}, {6, <<"/dev/kbd">>},
                                            {7, <<"/dev/draw">>}]],
                       Relayed = [told_one(open) || _ <- lists:seq(1, 4)],
                       Windows = told(opened),
                       [?_assertMatch([_], Windows),
                        ?_assertMatch([{<<"/dev/draw">>, [_]}, {<<"/dev/ctl">>, [_]}, {<<"/dev/kbd">>, [_]},
                                       {<<"/dev/draw">>, [_]}], Relayed),
                        ?_assertEqual(1, length(lists:usort([Dev || {_, Dev} <- Relayed])))]
               end).

%% A program's table at each resolution, the handler's image resolve and every open
%% of the program's (docs/design-files.md, "Narrowing for a program"), over the real
%% registry: an entry whose facet the registry holds as one of the windows interface
%% is left out, whenever it was installed and whatever its name, tree or point, while
%% a files facet's entry resolves to its grant.
program_table_test_() ->
    Clear = fun(_) -> persistent_term:erase({erx, facets}) end,
    {foreach, fun() -> Clear(none) end, Clear,
     [fun a_display_installed_after_the_start_is_left_out/1,
      fun a_files_facet_replaced_by_a_display_is_left_out/1,
      fun a_display_under_another_name_and_its_bind_are_left_out/1]}.

-define(FACET_ENTRY(Point, Name), #{point => Point, provider => {facet, Name}, root => [], rights => rw}).

%% The program's table is taken while the registry holds nothing under display: a
%% resolution then finds the entry ended, as the session's does, and once the
%% display's facet is installed no entry at all, from the same table.
a_display_installed_after_the_start_is_left_out(_) ->
    Table = [?FACET_ENTRY([<<"n">>, <<"display">>], display)],
    Before = erx_facets:program_table(erx_facets:program(Table)),
    ok = erx_facets:install(#{display => {?ERX_SERVICE_WINDOWS, {self(), ?ERX_WINDOWS_TREE_BYTES, rw}}}),
    After = erx_facets:program_table(erx_facets:program(Table)),
    [?_assertMatch([#{provider := ended}], Before),
     ?_assertEqual([], After)].

%% A files facet under data, which the program's entry reaches on its grant, replaced
%% under the same name by a display's: the next resolution has no entry there.
a_files_facet_replaced_by_a_display_is_left_out(_) ->
    Server = self(),
    Data = ?FACET_ENTRY([<<"data">>], data),
    ok = erx_facets:install(#{data => {?ERX_SERVICE_FILES, {Server, <<"data">>, rw}}}),
    Files = erx_facets:program_table(erx_facets:program([Data])),
    ok = erx_facets:install(#{data => {?ERX_SERVICE_WINDOWS, {Server, <<"data">>, rw}}}),
    Display = erx_facets:program_table(erx_facets:program([Data])),
    [?_assertEqual([Data#{provider := {grant, Server, <<"data">>}}], Files),
     ?_assertEqual([], Display)].

%% A display installed as notes, whose server names its tree notes, not the windows
%% tree, mounted at /n/notes and bound at /mnt/w: neither entry passes, and the files
%% facet beside it does.
a_display_under_another_name_and_its_bind_are_left_out(_) ->
    Server = self(),
    Notes = ?FACET_ENTRY([<<"n">>, <<"notes">>], notes),
    Bind = Notes#{point := [<<"mnt">>, <<"w">>], root := [<<"client">>]},
    Data = ?FACET_ENTRY([<<"data">>], data),
    ok = erx_facets:install(#{notes => {?ERX_SERVICE_WINDOWS, {Server, <<"notes">>, rw}},
                              data => {?ERX_SERVICE_FILES, {Server, <<"data">>, rw}}}),
    Granted = erx_facets:program_table(erx_facets:program([Notes, Bind, Data])),
    ?_assertEqual([Data#{provider := {grant, Server, <<"data">>}}], Granted).

%% A program's table with a display's facet at /n/display, beside the release slice
%% (docs/design-files.md, "Narrowing for a program"): the handler resolves the image
%% and every open over the table with no display's facet, so an image there is not
%% found, as in a table of nothing else, and an open there walks the release slice alone.
%% The stock emulator has no prim_file:erx_walk/2, so an image that is found cannot be
%% started here: the image case shows only that the display's entry is not walked.
-define(RELEASE_ENTRY, #{point => [], provider => release, root => [], rights => ro}).

an_image_beneath_a_display_is_not_found(_) ->
    on_a_display([], fun() ->
                         Answer = start((spec([]))#{image := <<"/n/display/prog">>}),
                         ?_assertEqual({error, enoent}, Answer)
                 end).

an_open_walks_no_display(_) ->
    on_a_display([?RELEASE_ENTRY], fun() ->
                         persistent_term:put(erx_win, self()),
                         {H, Port, []} = started([]),
                         H ! {erx_channel, Port, ?OPEN(4, <<"/n/display/w">>)},
                         Opened = receive {erx_win, {open, Path, Table}} -> {Path, Table}
                                  after ?WAIT -> none
                                  end,
                         ?_assertEqual({<<"/n/display/w">>, [?RELEASE_ENTRY]}, Opened)
                 end).

%% Case with the stand-in's table holding Entries and a display's facet at /n/display,
%% which the registry holds as one of the windows interface.
on_a_display(Entries, Case) ->
    Display = ?FACET_ENTRY([<<"n">>, <<"display">>], display),
    persistent_term:put({erx_file_description, table}, Entries ++ [Display]),
    ok = erx_facets:install(#{display => {?ERX_SERVICE_WINDOWS, {self(), ?ERX_WINDOWS_TREE_BYTES, rw}}}),
    try Case()
    after
        [persistent_term:erase(Key) || Key <- [{erx_file_description, table}, {erx, facets}, erx_win]]
    end.

%% Case with the stand-ins telling the test, and the registry and the connection's
%% refusal cleared after it.
first_draw(Case) ->
    ok = erx_fs_version:init(),
    persistent_term:put(erx_win, self()),
    try Case()
    after
        [persistent_term:erase(Key) || Key <- [erx_win, {erx, facets}, erx_draw_conn]]
    end.

%% Every event of Kind the stand-ins told within 200 ms, as the window opened or as
%% the open's path and the program's entries at /dev.
told(Kind) ->
    case told_one(Kind, 200) of
        none -> [];
        Event -> [Event | told(Kind)]
    end.

told_one(Kind) -> told_one(Kind, ?WAIT).

told_one(opened, Wait) ->
    receive {erx_win, {opened, Window}} -> Window after Wait -> none end;
told_one(open, Wait) ->
    receive
        {erx_win, {open, Path, Table}} -> {Path, [Entry || #{point := [<<"dev">>]} = Entry <- Table]}
    after Wait -> none
    end.

%% Every message waiting, the stand-ins' reports among them.
mailbox_all() ->
    receive Message -> [Message | mailbox_all()] after 100 -> [] end.

%% The logger handler: each event's text, to the case that added it.
log(#{msg := {Format, Args}}, #{config := #{to := To}}) when is_list(Format) ->
    To ! {logged, lists:flatten(io_lib:format(Format, Args))};
log(_Event, _Config) ->
    ok.

%% The live grants of erx_fs, found by their initial call.
dev_grants() ->
    [Pid || Pid <- processes(),
            {dictionary, Dictionary} <- [process_info(Pid, dictionary)],
            lists:member({'$initial_call', {erx_fs, init, 2}}, Dictionary)].

fake(Kind) ->
    receive {fake, Call} when element(1, Call) =:= Kind -> Call after ?WAIT -> {timeout, Kind} end.

nif_call(Kind) ->
    receive {nif, Call} when element(1, Call) =:= Kind -> Call after ?WAIT -> {timeout, Kind} end.

nif_calls() ->
    receive {nif, Call} -> [Call | nif_calls()] after 100 -> [] end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
