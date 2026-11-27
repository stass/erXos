%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The virtio-blk device process's deadlines (docs/design-storage.md, "Data model": every
%% request is answered within the wait limit and the in-flight bound of its acceptance),
%% over a virtio-blk device the test plays (test/erlang/stand_in/erx_device.erl): a device
%% that takes a request and never completes it ends the process at the in-flight bound,
%% with its caller answered; a request the full queue holds is answered at the wait limit
%% without being posted; and a request the device completes drops its deadline. The runner
%% (test/host/erx_blk_virtio_test.rb) compiles erx_blk_virtio with both bounds shortened
%% and defines them here as SHORT_WAIT_LIMIT_MS and SHORT_IN_FLIGHT_MS, so a case waits a fraction of a second, not 28 s.

-module(erx_blk_virtio_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% How long a call waits before the case fails: well past both shortened bounds.
-define(CALL_MS, 5000).

%% A device that takes every request and completes none: the request is answered
%% in_flight_bound once the bound passes, and the process ends.
silent_device_ends_at_the_in_flight_bound_test_() ->
    {timeout, 10, fun() ->
        {Pid, _Player} = start(silent),
        Started = now_ms(),
        ?assertEqual({error, {device, in_flight_bound}}, gen_server:call(Pid, flush, ?CALL_MS)),
        ?assert(now_ms() - Started >= ?SHORT_IN_FLIGHT_MS),
        ?assertEqual({shutdown, in_flight_bound}, ended(Pid))
    end}.

%% Every request the silent device holds and every one waiting behind its full queue is
%% answered when the bound passes, not only the first. The four held requests arrive late
%% enough that their wait limit falls after the posted ones' in-flight bound.
every_held_request_is_answered_at_the_bound_test_() ->
    {timeout, 10, fun() ->
        {Pid, _Player} = start(silent),
        Self = self(),
        Call = fun() -> spawn_link(fun() -> Self ! {answer, self(), gen_server:call(Pid, flush, ?CALL_MS)} end) end,
        Posted = [Call() || _ <- lists:seq(1, 16)],
        timer:sleep(?SHORT_IN_FLIGHT_MS - ?SHORT_WAIT_LIMIT_MS div 2),
        Callers = Posted ++ [Call() || _ <- lists:seq(1, 4)],
        Until = now_ms() + ?CALL_MS,
        Answers = [receive {answer, Caller, Answer} -> Answer after max(0, Until - now_ms()) -> no_answer end
                   || Caller <- Callers],
        ?assertEqual(lists:duplicate(20, {error, {device, in_flight_bound}}), Answers),
        ?assertEqual({shutdown, in_flight_bound}, ended(Pid))
    end}.

%% A request the full queue holds past the wait limit is answered deadline without being
%% posted, and the process goes on.
held_request_is_answered_at_the_wait_limit_test_() ->
    {timeout, 10, fun() ->
        {Pid, Player} = start(full),
        Started = now_ms(),
        ?assertEqual({error, {device, deadline}}, gen_server:call(Pid, flush, ?CALL_MS)),
        ?assert(now_ms() - Started >= ?SHORT_WAIT_LIMIT_MS),
        ?assertMatch({ok, #{transport := virtio_mmio}}, gen_server:call(Pid, info, ?CALL_MS)),
        stop(Pid, Player)
    end}.

%% A request the device completes is answered ok, and its deadline goes with it: the
%% process outlives the bound.
completed_request_drops_its_deadline_test_() ->
    {timeout, 10, fun() ->
        {Pid, Player} = start(completing),
        ?assertEqual(ok, gen_server:call(Pid, flush, ?CALL_MS)),
        timer:sleep(2 * ?SHORT_IN_FLIGHT_MS),
        ?assertMatch({ok, #{transport := virtio_mmio}}, gen_server:call(Pid, info, ?CALL_MS)),
        stop(Pid, Player)
    end}.

%% The device process over a played device whose posts answer as Mode says, after any a
%% failed case left registered, so each case runs on its own.
start(Mode) ->
    process_flag(trap_exit, true),
    case whereis(erx_blk) of
        undefined -> ok;
        Left -> Ref = monitor(process, Left), exit(Left, kill), receive {'DOWN', Ref, _, _, _} -> ok end
    end,
    Player = spawn_link(fun() -> player(Mode, []) end),
    {ok, Pid} = erx_blk_virtio:start_link(#{stand_in => Player}),
    {Pid, Player}.

stop(Pid, Player) ->
    unlink(Pid),
    exit(Pid, kill),
    unlink(Player),
    exit(Player, kill),
    ok.

ended(Pid) ->
    receive {'EXIT', Pid, Reason} -> Reason after ?CALL_MS -> still_running end.

%% The played virtio-blk device: silent takes posts while its 16 queue entries last, refuses
%% the rest as a full queue does, and completes none; full refuses
%% every post as a full queue does; completing takes each post and interrupts at once,
%% completing it with status ok on the next drain.
player(Mode, Posted) ->
    receive
        {erx_device, Driver, {post, _Queue, Tag, _Segments}} when Mode =:= silent ->
            Driver ! {erx_device, case length(Posted) < 16 of true -> ok; false -> {error, full} end},
            player(Mode, [Tag | Posted]);
        {erx_device, Driver, {post, _Queue, Tag, _Segments}} when Mode =:= completing ->
            Driver ! {erx_device, ok},
            Driver ! {erx_irq, {stand_in, self()}, 0},
            player(Mode, [Tag | Posted]);
        {erx_device, Driver, {complete, _Queue}} ->
            Driver ! {erx_device, {ok, [{Tag, <<?ERX_VIRTIO_BLK_S_OK>>} || Tag <- lists:reverse(Posted)]}},
            player(Mode, []);
        {erx_device, Driver, Call} ->
            Driver ! {erx_device, answer(Mode, Call)},
            player(Mode, Posted)
    end.

answer(_Mode, {read, magic}) -> ?ERX_VIRTIO_MMIO_MAGIC;
answer(_Mode, {read, version}) -> ?ERX_VIRTIO_MMIO_VERSION;
answer(_Mode, {read, device_id}) -> ?ERX_VIRTIO_ID_BLOCK;
answer(_Mode, {read, capacity_low}) -> 64;
answer(_Mode, {read, interrupt_status}) -> 1;
answer(_Mode, {read, _Register}) -> 0;
answer(_Mode, {write, _Register, _Value}) -> ok;
answer(_Mode, {ack, _Line}) -> ok;
answer(_Mode, {queue_create, _Queue, _Size, _BufferSize}) -> {ok, queue};
answer(_Mode, {negotiate, Wanted}) -> {ok, Wanted};
answer(full, {post, _Queue, _Tag, _Segments}) -> {error, full}.

now_ms() ->
    erlang:monotonic_time(millisecond).
