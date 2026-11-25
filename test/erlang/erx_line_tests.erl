%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The line tree and its keeper (docs/design-bluetooth.md, "The controller's line";
%% docs/design-files.md, "Waiting requests"): erx_line_fs served by a real erx_fs grant,
%% over erx_line, whose driver is a model the test drives. Each wait the cases assert on
%% has a deadline of 1 s.
-module(erx_line_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(NOFID, 16#ffffffff).
-define(O_RDONLY, 0).
-define(O_WRONLY, 1).
-define(O_RDWR, 2).
%% The off and on times of the power line powered/1 gives a line.
-define(OFF_MS, 60).
-define(ON_MS, 90).

%% Fixtures --------------------------------------------------------------

%% A line and a grant of its tree, with fid 1 at the root, fids 2 and 3 opened on data
%% for reading and for writing, fid 4 on ctl and fid 5 on the root for reading. The
%% model driver reports itself to the test as {driver, Pid} at each start.
line() ->
    Test = self(),
    {ok, Line} = erx_line:start_link(fun(L, grant) -> {ok, spawn_link(fun() -> driver(L, Test) end)} end, none),
    unlink(Line),
    Driver = driver_started(),
    #{line => Line, grant => tree(Line), driver => Driver}.

%% A grant of Line's tree, with the fids line/0 describes.
tree(Line) ->
    {ok, Grant, _} = erx_fs:start_link(erx_line_fs, Line, rw),
    unlink(Grant),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_LINE_TREE_BYTES, 0}),
    {ok, _} = call(Grant, {walk, 1, 2, [<<"data">>]}),
    {ok, _} = call(Grant, {walk, 1, 3, [<<"data">>]}),
    {ok, _} = call(Grant, {walk, 1, 4, [<<"ctl">>]}),
    {ok, _} = call(Grant, {walk, 1, 5, []}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_WRONLY}),
    {ok, _, _} = call(Grant, {lopen, 4, ?O_WRONLY}),
    {ok, _, _} = call(Grant, {lopen, 5, ?O_RDONLY}),
    Grant.

%% A start function whose starts answer Answers in turn, each a refusal or ok, which
%% starts the model driver.
starts(Answers) ->
    Test = self(),
    Starts = spawn_link(fun() -> lists:foreach(fun(Answer) -> receive {next, From} -> From ! {start, Answer} end end, Answers) end),
    fun(L, _Flow) ->
        Starts ! {next, self()},
        receive
            {start, ok} -> {ok, spawn_link(fun() -> driver(L, Test) end)};
            {start, Refused} -> Refused
        end
    end.

stop(#{line := Line, grant := Grant}) ->
    exit(Grant, kill),
    exit(Line, kill),
    persistent_term:erase({erx, serves}).

%% The model driver: what the line sends it goes to the test, and the test makes it
%% deliver input or answer a write. It tells the test once it has handed input to the
%% line, so a case that needs the bytes in the line before its next request waits for
%% that (input/2); a request through the grant would otherwise race the driver's send.
driver(Line, Test) ->
    Test ! {driver, self()},
    driver_loop(Line, Test).

driver_loop(Line, Test) ->
    receive
        {erx_console_output, Ref, Bytes} -> Test ! {output, self(), Ref, Bytes};
        {input, Bytes} -> Line ! {erx_console_input, Bytes}, Test ! {delivered, self()};
        {written, Ref} -> Line ! {erx_console_written, Ref}
    end,
    driver_loop(Line, Test).

%% Hands Bytes to the line through Driver and returns once Driver has sent them.
input(Driver, Bytes) ->
    Driver ! {input, Bytes},
    receive {delivered, Driver} -> ok after 1000 -> erlang:error(not_delivered) end.

driver_started() ->
    receive {driver, Driver} -> Driver after 1000 -> erlang:error(no_driver) end.

%% What the driver was handed to write, as {Ref, Bytes}, within 1 s, or none.
output(Driver, Timeout) ->
    receive {output, Driver, Ref, Bytes} -> {Ref, Bytes} after Timeout -> none end.

call(Grant, Request) ->
    Alias = send(Grant, Request),
    case reply_within(Alias, 1000) of
        none -> erlang:error({no_reply, Request});
        Reply -> Reply
    end.

send(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    Alias.

reply_within(Alias, Timeout) ->
    receive {erx_9p, Alias, Reply} -> Reply after Timeout -> none end.

%% Waiting reads -----------------------------------------------------------

%% The regression: a read of data that waits for the controller holds up no write of
%% data, no read of another file and no clunk of another fid; the controller's bytes
%% then answer it, once.
a_waiting_read_blocks_no_other_request_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Write = send(Grant, {write, 3, 0, <<"cmd">>}),
    ?assertMatch({_, <<"cmd">>}, output(Driver, 1000)),
    ?assertMatch({ok, _}, call(Grant, {readdir, 5, 0, 4096})),
    ?assertEqual(ok, call(Grant, {clunk, 5})),
    ?assertEqual(none, reply_within(Read, 0)),
    ?assertEqual(none, reply_within(Write, 0)),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, reply_within(Read, 1000)),
    ?assertEqual(none, reply_within(Read, 100)),
    stop(Line).

%% A write is answered with its count once the driver has written it, not before.
a_write_is_answered_once_the_driver_wrote_it_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Write = send(Grant, {write, 3, 7, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Driver, 1000),
    ?assertEqual(none, reply_within(Write, 100)),
    Driver ! {written, Ref},
    ?assertEqual({ok, 3, 7}, reply_within(Write, 1000)),
    stop(Line).

%% Writes reach the driver one at a time, in order.
writes_reach_the_driver_one_at_a_time_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    First = send(Grant, {write, 3, 0, <<"a">>}),
    Second = send(Grant, {write, 3, 0, <<"b">>}),
    {Ref, <<"a">>} = output(Driver, 1000),
    ?assertEqual(none, output(Driver, 100)),
    Driver ! {written, Ref},
    ?assertEqual({ok, 1, 0}, reply_within(First, 1000)),
    {Ref2, <<"b">>} = output(Driver, 1000),
    Driver ! {written, Ref2},
    ?assertEqual({ok, 1, 0}, reply_within(Second, 1000)),
    stop(Line).

%% Buffered bytes answer a read at once, at most its count; the rest waits for the
%% next read, and waiting reads take bytes in the order they arrived.
reads_take_buffered_bytes_in_order_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    {ok, _} = call(Grant, {walk, 1, 6, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 6, ?O_RDONLY}),
    First = send(Grant, {read, 2, 0, 2}),
    Second = send(Grant, {read, 6, 0, 16}),
    Driver ! {input, <<"abcde">>},
    ?assertEqual({ok, <<"ab">>}, reply_within(First, 1000)),
    ?assertEqual({ok, <<"cde">>}, reply_within(Second, 1000)),
    Driver ! {input, <<"xyz">>},
    ?assertEqual({ok, <<"x">>}, call(Grant, {read, 2, 0, 1})),
    ?assertEqual({ok, <<"yz">>}, call(Grant, {read, 6, 0, 16})),
    stop(Line).

%% A flush of a waiting read answers it eintr, then the flush; the bytes that come
%% later go to the next reader.
a_flush_answers_a_waiting_read_eintr_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Flush = send(Grant, {flush, Read}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Flush, 1000)),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% A clunk of the reading fid answers its waiting read eintr, then the clunk, and
%% takes no byte the next reader should have.
a_clunk_settles_a_waiting_read_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Clunk = send(Grant, {clunk, 2}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Clunk, 1000)),
    {ok, _} = call(Grant, {walk, 1, 2, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% The keeper's end answers every request it held eio, a waiting read and a write the
%% driver holds, and the grant goes on serving.
the_keepers_end_answers_its_requests_eio_test() ->
    #{grant := Grant, line := Keeper, driver := Driver} = Line = line(),
    Read = send(Grant, {read, 2, 0, 16}),
    Write = send(Grant, {write, 3, 0, <<"cmd">>}),
    {_, <<"cmd">>} = output(Driver, 1000),
    exit(Keeper, kill),
    ?assertEqual({error, eio}, reply_within(Read, 1000)),
    ?assertEqual({error, eio}, reply_within(Write, 1000)),
    ?assertMatch({ok, _}, call(Grant, {readdir, 5, 0, 4096})),
    stop(Line).

%% Resets ------------------------------------------------------------------

%% A reset ends the driver, which answers the write it held and the waiting read eio,
%% drops what was buffered and starts the driver afresh, then answers; a write sent
%% during the reset waits for it and goes to the new driver.
a_reset_ends_the_driver_and_starts_it_afresh_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    Held = send(Grant, {write, 3, 0, <<"stuck">>}),
    {_, <<"stuck">>} = output(Driver, 1000),
    Read = send(Grant, {read, 2, 0, 16}),
    Reset = send(Grant, {write, 4, 0, <<"reset\n">>}),
    ?assertEqual({error, eio}, reply_within(Held, 1000)),
    ?assertEqual({error, eio}, reply_within(Read, 1000)),
    Fresh = driver_started(),
    ?assertEqual({ok, 6, 0}, reply_within(Reset, 1000)),
    ?assertNot(is_process_alive(Driver)),
    After = send(Grant, {write, 3, 0, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Fresh, 1000),
    Fresh ! {written, Ref},
    ?assertEqual({ok, 3, 0}, reply_within(After, 1000)),
    stop(Line).

%% A reset goes ahead of the writes before it: with one write held by the driver and
%% another waiting behind it, the reset still begins, both writes answer eio, and the
%% fresh driver is handed neither.
a_reset_goes_ahead_of_waiting_writes_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    {ok, _} = call(Grant, {walk, 1, 6, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 6, ?O_WRONLY}),
    Held = send(Grant, {write, 3, 0, <<"stuck">>}),
    {_, <<"stuck">>} = output(Driver, 1000),
    Behind = send(Grant, {write, 6, 0, <<"next">>}),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    ?assertEqual({error, eio}, reply_within(Held, 1000)),
    ?assertEqual({error, eio}, reply_within(Behind, 1000)),
    Fresh = driver_started(),
    ?assertEqual({ok, 5, 0}, reply_within(Reset, 1000)),
    ?assertEqual(none, output(Fresh, 100)),
    stop(Line).

%% Bytes the old driver delivered before a reset are not read after it.
a_reset_drops_what_the_old_driver_read_test() ->
    #{grant := Grant, line := Keeper, driver := Driver} = Line = line(),
    ok = input(Driver, <<"old">>),
    _ = sys:get_state(Keeper),
    ?assertEqual({ok, 5, 0}, call(Grant, {write, 4, 0, <<"reset">>})),
    Fresh = driver_started(),
    Fresh ! {input, <<"new">>},
    ?assertEqual({ok, <<"new">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% A driver that does not start, as on an empty transport, leaves the line broken with
%% no driver rather than ending it, so its supervisor restarts nothing: reads and writes
%% of data answer eio, a reset whose fresh driver does not start answers eio, and the
%% next reset whose driver starts mends the line.
a_driver_that_does_not_start_leaves_the_line_broken_test() ->
    %% A line whose start crashed would take the test with it; trapping makes it a failure.
    Trap = process_flag(trap_exit, true),
    Started = erx_line:start_link(starts([{error, no_device}, {error, ebusy}, ok]), none),
    process_flag(trap_exit, Trap),
    {ok, Keeper} = Started,
    unlink(Keeper),
    Grant = tree(Keeper),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({error, eio}, call(Grant, {write, 3, 0, <<"cmd">>})),
    ?assertEqual({error, eio}, call(Grant, {write, 4, 0, <<"reset">>})),
    ?assert(is_process_alive(Keeper)),
    ?assertEqual({ok, 5, 0}, call(Grant, {write, 4, 0, <<"reset">>})),
    Driver = driver_started(),
    ok = input(Driver, <<"up">>),
    ?assertEqual({ok, <<"up">>}, call(Grant, {read, 2, 0, 16})),
    stop(#{line => Keeper, grant => Grant}).

%% A driver that ends outside a reset, as a broken queue ends one, leaves the line broken
%% with no driver as well, and the line lives on: data answers eio until a reset starts
%% a fresh driver.
a_driver_s_end_leaves_the_line_broken_until_a_reset_test() ->
    #{grant := Grant, line := Keeper, driver := Driver} = Line = line(),
    Monitor = monitor(process, Driver),
    exit(Driver, broken_queue),
    receive {'DOWN', Monitor, process, Driver, _} -> ok end,
    _ = sys:get_state(Keeper),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({error, eio}, call(Grant, {write, 3, 0, <<"cmd">>})),
    ?assertEqual({ok, 5, 0}, call(Grant, {write, 4, 0, <<"reset">>})),
    Fresh = driver_started(),
    ok = input(Fresh, <<"up">>),
    ?assertEqual({ok, <<"up">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% Resets queued behind one whose fresh driver does not start each begin in turn, the
%% ones with no driver to end at once, so none is left waiting.
resets_queued_behind_a_failed_start_each_run_test() ->
    Trap = process_flag(trap_exit, true),
    Started = erx_line:start_link(starts([ok, {error, no_device}, {error, no_device}, ok]), none),
    process_flag(trap_exit, Trap),
    {ok, Keeper} = Started,
    unlink(Keeper),
    _ = driver_started(),
    Grant = tree(Keeper),
    Resets = [send(Grant, {write, 4, 0, <<"reset">>}) || _ <- [1, 2, 3]],
    ?assertEqual([{error, eio}, {error, eio}, {ok, 5, 0}], [reply_within(Reset, 1000) || Reset <- Resets]),
    _ = driver_started(),
    stop(#{line => Keeper, grant => Grant}).

%% Power cycles (docs/design-bluetooth.md, "A reset", "A reset that fails") -----------

ms() -> erlang:monotonic_time(millisecond).

%% A line with a power line of ?OFF_MS off and ?ON_MS on, over a model device service,
%% whose starts answer Starts in turn (starts/1). Each start reports {started, Flow, Ms} to
%% the test before it answers, and each notification {notified, State, Ms, From}, then
%% waits for the test's answer (notified/0, answer/2). The fixture takes the line's first
%% start, with the grant's flow.
powered(Starts) ->
    Test = self(),
    Start = starts(Starts),
    Notify = fun(State) -> Test ! {notified, State, ms(), self()}, receive {answer, Answer} -> Answer end end,
    {ok, Line} = erx_line:start_link(fun(L, Flow) -> Test ! {started, Flow, ms()}, Start(L, Flow) end,
                                     #{notify => Notify, off => ?OFF_MS, on => ?ON_MS}),
    unlink(Line),
    ?assertMatch({grant, _}, started()),
    #{line => Line, grant => tree(Line)}.

started() ->
    receive {started, Flow, Ms} -> {Flow, Ms} after 1000 -> erlang:error(no_start) end.

notified() ->
    receive {notified, State, Ms, From} -> {State, Ms, From} after 1000 -> erlang:error(no_notification) end.

answer(From, Answer) ->
    From ! {answer, Answer}.

%% Waits until the line has taken every request sent to the grant before: the grant answers a
%% readdir after handing those on.
settled(#{line := Line, grant := Grant}) ->
    {ok, _} = call(Grant, {readdir, 5, 0, 4096}),
    _ = sys:get_state(Line),
    ok.

%% The regression: a reset is a power cycle between two fresh starts. The old driver has
%% ended when the driver is started with flow none, before the off notification; the off
%% time passes before the on notification, and the on time before the driver is started
%% with the grant's flow, once the holding driver has ended; only then does the reset
%% answer.
a_reset_power_cycles_between_two_fresh_starts_test() ->
    #{grant := Grant} = Line = powered([ok, ok, ok]),
    Old = driver_started(),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    {none, Held} = started(),
    ?assertNot(is_process_alive(Old)),
    Holding = driver_started(),
    {off, Off, OffFrom} = notified(),
    ?assert(Held =< Off),
    answer(OffFrom, ok),
    {on, On, OnFrom} = notified(),
    ?assert(On - Off >= ?OFF_MS),
    ?assertEqual(none, reply_within(Reset, 0)),
    answer(OnFrom, ok),
    {grant, Granted} = started(),
    ?assert(Granted - On >= ?ON_MS),
    ?assertNot(is_process_alive(Holding)),
    Fresh = driver_started(),
    ?assertEqual({ok, 5, 0}, reply_within(Reset, 1000)),
    After = send(Grant, {write, 3, 0, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Fresh, 1000),
    Fresh ! {written, Ref},
    ?assertEqual({ok, 3, 0}, reply_within(After, 1000)),
    stop(Line).

%% What the controller sends during the power cycle never reaches a reader: a read
%% during the reset answers eio, and after it the reader gets the fresh driver's bytes
%% alone.
a_power_cycle_s_input_never_reaches_a_reader_test() ->
    #{grant := Grant} = Line = powered([ok, ok, ok]),
    _ = driver_started(),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    {none, _} = started(),
    Holding = driver_started(),
    {off, _, OffFrom} = notified(),
    ok = input(Holding, <<"powering">>),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    answer(OffFrom, ok),
    {on, _, OnFrom} = notified(),
    ok = input(Holding, <<"powered">>),
    answer(OnFrom, ok),
    {grant, _} = started(),
    Fresh = driver_started(),
    ?assertEqual({ok, 5, 0}, reply_within(Reset, 1000)),
    ok = input(Fresh, <<"up">>),
    ?assertEqual({ok, <<"up">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% A notification answered with an error, the off one or the on one, fails the reset by
%% one transition: the reset answers eio before its next step, the holding driver has
%% ended, the line is broken with no driver, and a write that arrived during the reset
%% answers eio without reaching the holding driver. The next reset begins with no driver
%% to stop and mends the line.
a_failed_notification_fails_the_reset_test_() ->
    [{atom_to_list(Failing), fun() -> failed_notification(Failing) end} || Failing <- [off, on]].

failed_notification(Failing) ->
    #{grant := Grant} = Line = powered([ok, ok, ok, ok]),
    _ = driver_started(),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    {none, _} = started(),
    Holding = driver_started(),
    Write = send(Grant, {write, 3, 0, <<"cmd">>}),
    ok = settled(Line),
    ?assertEqual(none, reply_within(Write, 0)),
    {off, _, OffFrom} = notified(),
    case Failing of
        off ->
            answer(OffFrom, {error, enotsup});
        on ->
            answer(OffFrom, ok),
            {on, _, OnFrom} = notified(),
            answer(OnFrom, {error, enotsup})
    end,
    ?assertEqual({error, eio}, reply_within(Reset, 1000)),
    ?assertNot(is_process_alive(Holding)),
    ?assertEqual({error, eio}, reply_within(Write, 1000)),
    ?assertEqual(none, output(Holding, 0)),
    ?assertEqual(none, receive {notified, _, _, _} = Next -> Next after 100 -> none end),
    ?assertEqual(none, receive {started, _, _} = Next -> Next after 0 -> none end),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({error, eio}, call(Grant, {write, 3, 0, <<"cmd">>})),
    Again = send(Grant, {write, 4, 0, <<"reset">>}),
    {none, _} = started(),
    _ = driver_started(),
    {off, _, Off} = notified(),
    answer(Off, ok),
    {on, _, On} = notified(),
    answer(On, ok),
    {grant, _} = started(),
    Fresh = driver_started(),
    ?assertEqual({ok, 5, 0}, reply_within(Again, 1000)),
    ok = input(Fresh, <<"up">>),
    ?assertEqual({ok, <<"up">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% A holding start that fails ends the reset there: it answers eio, no notification is
%% asked, and the line is broken with no driver.
a_holding_start_that_fails_fails_the_reset_test() ->
    #{grant := Grant} = Line = powered([ok, {error, no_device}]),
    _ = driver_started(),
    ?assertEqual({error, eio}, call(Grant, {write, 4, 0, <<"reset">>})),
    {none, _} = started(),
    ?assertEqual(none, receive {notified, _, _, _} = Next -> Next after 100 -> none end),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({error, eio}, call(Grant, {write, 3, 0, <<"cmd">>})),
    stop(Line).

%% A start with the grant's flow that fails after a power cycle fails the reset: it
%% answers eio within 1 s, the keeper goes on answering, and the line is broken with no
%% driver.
a_fresh_start_that_fails_after_the_power_cycle_fails_the_reset_test() ->
    #{grant := Grant} = Line = powered([ok, ok, {error, no_device}]),
    _ = driver_started(),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    {none, _} = started(),
    Holding = driver_started(),
    {off, _, Off} = notified(),
    answer(Off, ok),
    {on, _, On} = notified(),
    answer(On, ok),
    {grant, _} = started(),
    ?assertEqual({error, eio}, reply_within(Reset, 1000)),
    ?assertNot(is_process_alive(Holding)),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({error, eio}, call(Grant, {write, 3, 0, <<"cmd">>})),
    stop(Line).

%% A holding driver that ends during the power cycle is not a failure: the power cycle
%% goes on, and the driver is started with the grant's flow after the on time.
a_holding_driver_that_ends_early_leaves_the_power_cycle_going_test() ->
    #{grant := Grant} = Line = powered([ok, ok, ok]),
    _ = driver_started(),
    Reset = send(Grant, {write, 4, 0, <<"reset">>}),
    {none, _} = started(),
    Holding = driver_started(),
    {off, _, Off} = notified(),
    Monitor = monitor(process, Holding),
    exit(Holding, ended),
    receive {'DOWN', Monitor, process, Holding, _} -> ok end,
    answer(Off, ok),
    {on, _, On} = notified(),
    answer(On, ok),
    {grant, _} = started(),
    Fresh = driver_started(),
    ?assertEqual({ok, 5, 0}, reply_within(Reset, 1000)),
    ok = input(Fresh, <<"up">>),
    ?assertEqual({ok, <<"up">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% ctl takes reset alone; anything else is einval, and ctl does not open for reading.
ctl_takes_reset_alone_test() ->
    #{grant := Grant} = Line = line(),
    ?assertEqual({error, einval}, call(Grant, {write, 4, 0, <<"off">>})),
    ?assertEqual({error, einval}, call(Grant, {write, 4, 0, <<"reset\n\n">>})),
    {ok, _} = call(Grant, {walk, 1, 6, [<<"ctl">>]}),
    ?assertEqual({error, eacces}, call(Grant, {lopen, 6, ?O_RDONLY})),
    stop(Line).

%% Input past line_rx_max breaks the line: what was buffered is dropped and reads
%% answer eio until a reset, after which the new driver's bytes are read.
a_broken_line_answers_reads_eio_until_a_reset_test() ->
    #{grant := Grant, driver := Driver} = Line = line(),
    ok = input(Driver, <<"kept">>),
    ok = input(Driver, binary:copy(<<0>>, ?ERX_LINE_RX_MAX)),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 16})),
    ?assertEqual({ok, 5, 0}, call(Grant, {write, 4, 0, <<"reset">>})),
    Fresh = driver_started(),
    Fresh ! {input, <<"new">>},
    ?assertEqual({ok, <<"new">>}, call(Grant, {read, 2, 0, 16})),
    stop(Line).

%% parse/1 makes no atom and takes exactly reset, with at most one newline.
parse_test() ->
    ?assertEqual({ok, reset}, erx_line_fs:parse(<<"reset">>)),
    ?assertEqual({ok, reset}, erx_line_fs:parse(<<"reset\n">>)),
    ?assertEqual({error, einval}, erx_line_fs:parse(<<>>)),
    ?assertEqual({error, einval}, erx_line_fs:parse(<<"Reset">>)),
    ?assertEqual({error, einval}, erx_line_fs:parse(binary:copy(<<"reset">>, 4))).

%% The keeper and the tree's grants (docs/design-bluetooth.md, "The shared line 153") ---

%% The tree's grants, the process the line is linked to besides its driver.
grants(#{line := Line, driver := Driver}) ->
    {links, Links} = process_info(Line, links),
    [Grants] = Links -- [Driver],
    Grants.

%% The line starts its tree's grants, and a grant of them reads and writes data through
%% the line.
the_line_starts_its_trees_grants_test() ->
    #{driver := Driver} = Fixture = line(),
    {ok, {Grant, rw}} = erx_fs_grants:own(grants(Fixture)),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_LINE_TREE_BYTES, 0}),
    {ok, _} = call(Grant, {walk, 1, 2, [<<"data">>]}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDWR}),
    Write = send(Grant, {write, 2, 0, <<"cmd">>}),
    {Ref, <<"cmd">>} = output(Driver, 1000),
    Driver ! {written, Ref},
    ?assertMatch({ok, 3, _}, reply_within(Write, 1000)),
    Read = send(Grant, {read, 2, 0, 16}),
    Driver ! {input, <<"evt">>},
    ?assertEqual({ok, <<"evt">>}, reply_within(Read, 1000)),
    stop(Fixture).

%% The line names its tree's grants, the erx_fs_grants the domain service starts a grant
%% of for each domain the manifest grants line, as the system domain's line service.
the_line_serves_its_trees_grants_test() ->
    Fixture = line(),
    try
        ?assertEqual(#{line => grants(Fixture)}, persistent_term:get({erx, serves}))
    after
        stop(Fixture)
    end.

%% The keeper's end ends its grants, and a read it held answers eio; the grants' end
%% ends the keeper, so its group restarts both together.
the_keeper_and_its_grants_end_together_test() ->
    #{line := Line, grant := Grant} = First = line(),
    Grants = grants(First),
    Watch = monitor(process, Grants),
    Held = send(Grant, {read, 2, 0, 16}),
    exit(Line, kill),
    ?assertEqual({error, eio}, reply_within(Held, 1000)),
    receive {'DOWN', Watch, process, Grants, _} -> ok after 1000 -> erlang:error(grants_kept) end,
    exit(Grant, kill),
    #{line := Again} = Second = line(),
    Keeper = monitor(process, Again),
    exit(grants(Second), kill),
    receive {'DOWN', Keeper, process, Again, {grants_ended, killed}} -> ok after 1000 -> erlang:error(keeper_kept) end,
    exit(maps:get(grant, Second), kill).

%% Report ------------------------------------------------------------------

%% A crash report and sys:get_status/1 show the keeper's state, the message it handled and
%% a crash's reason as sizes and counts, never as the controller's bytes (a Bluetooth line
%% carries keys). The buffer, the write in flight and a write waiting behind it hold the
%% secrets.
the_status_shows_no_byte_of_the_line_test() ->
    #{grant := Grant, driver := Driver, line := Line} = Fixture = line(),
    _ = send(Grant, {write, 3, 0, <<"WRITE-IN-FLIGHT-SECRET">>}),
    {_Ref, _} = output(Driver, 1000),
    _ = send(Grant, {write, 3, 0, <<"WRITE-WAITING-SECRET">>}),
    input(Driver, <<"RECEIVED-SECRET">>),
    {status, Line, _, Items} = sys:get_status(Line),
    Shown = lists:flatten(io_lib:format("~0tp", [Items])),
    [?assertEqual(nomatch, string:find(Shown, Secret))
     || Secret <- ["WRITE-IN-FLIGHT-SECRET", "WRITE-WAITING-SECRET", "RECEIVED-SECRET",
                   "87,82,73,84,69", "82,69,67,69,73"]],
    ?assertNotEqual(nomatch, string:find(Shown, "rx => {bytes,")),
    stop(Fixture).

%% The message, the log and the reason of a report: one never carries the bytes of the
%% message that was being handled, a write's or an input's, and a reason is its atom.
format_status_hides_the_message_the_log_and_the_reason_test() ->
    Secret = <<"MESSAGE-SECRET">>,
    Wait = {self(), make_ref()},
    Status = erx_line:format_status(
               #{message => {erx_fs_wait, Wait, {write, 0, Secret}},
                 log => [{in, {erx_console_input, Secret}}],
                 reason => {grants_ended, {badmatch, Secret}}}),
    ?assertEqual(nomatch, string:find(lists:flatten(io_lib:format("~0tp", [Status])), "MESSAGE-SECRET")),
    ?assertEqual(grants_ended, maps:get(reason, Status)),
    ?assertEqual([], maps:get(log, Status)),
    ?assertMatch({erx_console_input, {bytes, 14}}, maps:get(message, erx_line:format_status(
        #{message => {erx_console_input, Secret}}))).

%% The keeper's exit reason, which every report of its end quotes, names why and holds no
%% term of the grants' reason. A driver's end does not end the keeper (above).
the_keepers_exit_reason_holds_no_term_of_the_grants_test() ->
    #{line := Line, grant := Grant} = Fixture = line(),
    Keeper = monitor(process, Line),
    ok = sys:terminate(grants(Fixture), {boom, <<"GRANTS-SECRET">>}),
    receive {'DOWN', Keeper, process, Line, Reason} -> ?assertEqual({grants_ended, boom}, Reason)
    after 1000 -> erlang:error(keeper_kept) end,
    exit(Grant, kill).
