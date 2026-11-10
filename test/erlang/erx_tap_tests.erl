%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the tap transport and its NIF (docs/design-network-stack.md, "The tap
%% transport"; docs/design-network-fastpath.md, "Verification", test 10) on a host without a
%% tap device, run by test/host/erx_tap_test.rb, which builds the NIF into erx_net's priv/.
%% Two stand-ins take the device's place:
%%
%% * a connected pair of UNIX datagram sockets, which keeps one frame per read and write as
%%   a tap does. The NIF adopts the near end's descriptor, as it adopts a tap's that a
%%   privileged opener handed over; the test holds the far end. A full peer there answers
%%   ENOBUFS, which a tap gives too, so it is what tests a refused frame;
%% * a FIFO, which answers EAGAIN when full and wakes its writer once read, as a full tap
%%   does; the test reads back what the NIF wrote. Its frames are 60 bytes, below PIPE_BUF,
%%   so each write is whole or nothing. The NIF opens it by name, as it opens a tap.
-module(erx_tap_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LLADDR, <<2, 0, 0, 0, 0, 1>>).
-define(MTU, 1500).
-define(WAIT_MS, 2000).
-define(BUFFER, 262144).

%% --- The NIF over a datagram pair --------------------------------------------------

frames_cross_both_ways_test() ->
    with_pair(fun(H, Far) ->
        [begin
             Frame = frame(Size, Size),
             Pieces = [binary:part(Frame, 0, 14), binary:part(Frame, 14, Size - 14)],
             ?assertEqual({ok, 1}, erx_tap_nif:send(H, Pieces)),
             ?assertEqual({ok, Frame}, socket:recv(Far, 0, ?WAIT_MS))
         end || Size <- [14, 60, 1514]],
        Frames = [frame(I, Size) || {I, Size} <- [{1, 14}, {2, 60}, {3, 1514}, {5, 61}]],
        [ok = socket:send(Far, F) || F <- Frames],
        ?assertEqual({ok, summed(Frames), #{}, armed}, erx_tap_nif:recv(H)),
        %% The arm's message comes once a frame arrives, and not before.
        ?assertEqual(none, readable(0)),
        ok = socket:send(Far, frame(4, 60)),
        ?assertEqual(readable, readable(?WAIT_MS)),
        ?assertEqual({ok, summed([frame(4, 60)]), #{}, armed}, erx_tap_nif:recv(H))
    end).

%% One call reads at most 64 frames and answers `more`; the next reads the rest.
recv_batch_is_bounded_test() ->
    with_pair(fun(H, Far) ->
        Frames = [frame(I, 60) || I <- lists:seq(1, 70)],
        [ok = socket:send(Far, F) || F <- Frames],
        {First, Rest} = lists:split(64, Frames),
        ?assertEqual({ok, summed(First), #{}, more}, erx_tap_nif:recv(H)),
        ?assertEqual({ok, summed(Rest), #{}, armed}, erx_tap_nif:recv(H))
    end).

%% A frame shorter than the Ethernet header, or longer than the MTU and the header, is
%% dropped and counted, in each direction; the longest frame allowed passes.
short_and_long_frames_are_dropped_test() ->
    with_pair(fun(H, Far) ->
        [ok = socket:send(Far, F) || F <- [frame(1, 13), frame(2, ?MTU + 15), frame(3, ?MTU + 14)]],
        ?assertEqual({ok, summed([frame(3, ?MTU + 14)]), #{malformed => 1, too_long => 1}, armed},
                     erx_tap_nif:recv(H)),
        ?assertEqual({drop, malformed}, erx_tap_nif:send(H, frame(4, 13))),
        ?assertEqual({drop, too_long}, erx_tap_nif:send(H, [frame(5, ?MTU), frame(6, 15)])),
        ?assertEqual({error, timeout}, socket:recv(Far, 0, 100))
    end).

%% Iodata of many binaries, nested lists and byte integers goes out as one frame.
iodata_frames_are_written_whole_test() ->
    with_pair(fun(H, Far) ->
        Frame = frame(7, 200),
        Pieces = [binary:part(Frame, I, 2) || I <- lists:seq(0, 198, 2)],
        Nested = [[[binary:part(Frame, 0, 10)]], binary:bin_to_list(binary:part(Frame, 10, 20)) |
                  binary:part(Frame, 30, 170)],
        [begin
             ?assertEqual({ok, 1}, erx_tap_nif:send(H, Iodata)),
             ?assertEqual({ok, Frame}, socket:recv(Far, 0, ?WAIT_MS))
         end || Iodata <- [Pieces, Nested]],
        ?assertError(badarg, erx_tap_nif:send(H, [Frame, atom]))
    end).

%% A peer that takes no more answers ENOBUFS, and the frame is dropped as a wire loses one.
full_peer_refuses_test() ->
    with_pair(fun(H, _Far) ->
        Answers = [erx_tap_nif:send(H, frame(I, 1514)) || I <- lists:seq(1, 400)],
        ?assertMatch([{ok, 1} | _], Answers),
        ?assert(lists:member({drop, refused}, Answers))
    end).

%% --- The NIF over a FIFO -----------------------------------------------------------

%% Frames written until the device is full, the first answer `full`; once the reader has
%% made room, the arm's message comes and the frames after go out: every frame is read back
%% once, in order.
full_device_wakes_its_writer_test() ->
    with_fifo(fun(H, Fifo) ->
        Taken = fill(H, 0),
        ?assert(Taken > 0),
        ?assertEqual(frames(0, Taken), read_exactly(Fifo, Taken * 60)),
        ?assertEqual(writable, writable(?WAIT_MS)),
        [?assertEqual({ok, 1}, erx_tap_nif:send(H, frame(I, 60)))
         || I <- lists:seq(Taken, Taken + 9)],
        ?assertEqual(frames(Taken, 10), read_exactly(Fifo, 600))
    end).

%% --- The handle --------------------------------------------------------------------

%% Only the owner may use the handle; another process gets badarg.
another_process_gets_badarg_test() ->
    with_pair(fun(H, _Far) ->
        Test = self(),
        spawn(fun() ->
            Test ! {other, raised(fun() -> erx_tap_nif:recv(H) end),
                    raised(fun() -> erx_tap_nif:send(H, frame(1, 60)) end)}
        end),
        Got = receive {other, _, _} = M -> M after ?WAIT_MS -> timeout end,
        ?assertEqual({other, badarg, badarg}, Got)
    end).

%% The descriptor closes when its owner ends, whether or not it was armed: the FIFO's
%% reader, the NIF its only writer, then reads end of file.
owner_end_closes_the_descriptor_test() ->
    [with_fifo_path(fun(Path) ->
         Test = self(),
         {Owner, Ref} = spawn_monitor(fun() ->
             {ok, H} = erx_tap_nif:open(list_to_binary(Path), ?MTU),
             Test ! {opened, self()},
             receive go -> ok end,
             case Arm of
                 true -> {ok, [], #{}, armed} = erx_tap_nif:recv(H);
                 false -> ok
             end,
             exit(done)
         end),
         receive {opened, Owner} -> ok after ?WAIT_MS -> error(timeout) end,
         Reader = start_reader(Path),
         Owner ! go,
         receive {'DOWN', Ref, process, Owner, done} -> ok after ?WAIT_MS -> error(timeout) end,
         ?assertEqual(eof, reader_result(Reader, ?WAIT_MS))
     end) || Arm <- [false, true]].

%% The handle holds a copy of the descriptor it adopted: its owner's end closes the copy and
%% leaves the caller's socket working, and the caller can adopt it again. (The caller's own
%% close is not the test: OTP's socket:close makes the shared open file blocking first.)
adopted_descriptor_is_a_copy_test() ->
    with_socket_pair(fun(Near, Far) ->
        Test = self(),
        {Owner, Ref} = spawn_monitor(fun() ->
            {ok, H} = erx_tap_nif:adopt(near_fd(Near), ?MTU),
            {ok, 1} = erx_tap_nif:send(H, frame(1, 60)),
            Test ! {sent, self()},
            exit(done)
        end),
        receive {'DOWN', Ref, process, Owner, done} -> ok after ?WAIT_MS -> error(timeout) end,
        ?assertEqual({sent, Owner}, receive {sent, _} = M -> M after 0 -> none end),
        ?assertEqual({ok, frame(1, 60)}, socket:recv(Far, 0, ?WAIT_MS)),
        ?assertEqual(ok, socket:send(Near, frame(2, 60))),
        ?assertEqual({ok, frame(2, 60)}, socket:recv(Far, 0, ?WAIT_MS)),
        {ok, H} = erx_tap_nif:adopt(near_fd(Near), ?MTU),
        ?assertEqual({ok, 1}, erx_tap_nif:send(H, frame(3, 60))),
        ?assertEqual({ok, frame(3, 60)}, socket:recv(Far, 0, ?WAIT_MS))
    end).

%% A descriptor that is not an int's non-negative value, or an MTU out of range, is badarg;
%% one that is not open is the system's refusal. 16#7fffffff fits an int and is past any
%% descriptor limit, so it is never open.
adopt_refusals_test() ->
    ?assertEqual({error, {adopt, ebadf}}, erx_tap_nif:adopt(16#7fffffff, ?MTU)),
    [?assertError(badarg, erx_tap_nif:adopt(Fd, Mtu))
     || {Fd, Mtu} <- [{-1, ?MTU}, {1 bsl 31, ?MTU}, {fd, ?MTU}, {"3", ?MTU}, {3.0, ?MTU},
                      {0, 67}, {0, 9001}]].

open_refusals_test() ->
    ?assertEqual({error, {open, enoent}}, erx_tap_nif:open(<<"/nonexistent/erx_tap">>, ?MTU)),
    [?assertError(badarg, erx_tap_nif:open(Path, Mtu))
     || {Path, Mtu} <- [{<<>>, ?MTU}, {<<"/dev/null", 0>>, ?MTU}, {<<"/dev/null">>, 67},
                        {<<"/dev/null">>, 9001}, {"/dev/null", ?MTU}]].

%% --- The transport -----------------------------------------------------------------

%% init sends the first `more`; each later batch comes at the arm's message.
transport_receives_and_transmits_test() ->
    with_socket_pair(fun(Near, Far) ->
        {ok, #{link := ethernet, lladdr := ?LLADDR, mtu := ?MTU, state := up,
               tx_limit := 256}, T0} =
            erx_tap:init(#{fd => near_fd(Near), lladdr => ?LLADDR}),
        ok = socket:send(Far, frame(1, 60)),
        ok = socket:send(Far, frame(2, 13)),
        {Events, T1} = erx_tap:event(wake(more), T0),
        ?assertEqual([{dropped, malformed}, {frames, summed([frame(1, 60)])}], Events),
        ok = socket:send(Far, frame(3, 60)),
        ?assertMatch({[{frames, [_]}], _}, erx_tap:event(wake(readable), T1)),
        ?assertMatch({ok, _}, erx_tap:transmit([frame(4, 60)], T1)),
        ?assertEqual({ok, frame(4, 60)}, socket:recv(Far, 0, ?WAIT_MS)),
        ?assertMatch({{drop, malformed}, _}, erx_tap:transmit({zone, <<"packet">>}, T1))
    end).

%% A batch that reaches its bound sends the next `more`; the last one arms the device.
transport_rearms_after_a_full_batch_test() ->
    with_socket_pair(fun(Near, Far) ->
        {ok, _, T0} = erx_tap:init(#{fd => near_fd(Near), lladdr => ?LLADDR}),
        [ok = socket:send(Far, frame(I, 60)) || I <- lists:seq(1, 70)],
        {[{frames, First}], T1} = erx_tap:event(wake(more), T0),
        ?assertEqual(64, length(First)),
        {[{frames, Rest}], _} = erx_tap:event(wake(more), T1),
        ?assertEqual(6, length(Rest)),
        ?assertEqual(none, receive {erx_tap, more} -> more after 100 -> none end)
    end).

%% End of file on a read is the device gone, and stops the medium: /dev/null reads none.
transport_stops_when_the_device_ends_test() ->
    {ok, _, T} = erx_tap:init(#{device => "/dev/null", lladdr => ?LLADDR}),
    ?assertEqual({stop, {tap, eof}}, erx_tap:event(wake(more), T)).

transport_init_refusals_test() ->
    Config = #{device => "/dev/null", lladdr => ?LLADDR},
    Group = <<1, 0, 0, 0, 0, 1>>,
    ?assertEqual({error, {lladdr, Group}}, erx_tap:init(Config#{lladdr := Group})),
    ?assertEqual({error, {mtu, 1279}}, erx_tap:init(Config#{mtu => 1279})),
    ?assertEqual({error, {tx_limit, 0}}, erx_tap:init(Config#{tx_limit => 0})),
    ?assertEqual({error, {device, <<"/nonexistent/erx_tap">>, {open, enoent}}},
                 erx_tap:init(Config#{device := "/nonexistent/erx_tap"})),
    ?assertEqual({error, {device, 42}}, erx_tap:init(Config#{device := 42})),
    Lone = #{lladdr => ?LLADDR},
    ?assertEqual({error, {fd, -1}}, erx_tap:init(Lone#{fd => -1})),
    ?assertEqual({error, {fd, "3"}}, erx_tap:init(Lone#{fd => "3"})),
    ?assertEqual({error, {fd, 16#7fffffff, {adopt, ebadf}}},
                 erx_tap:init(Lone#{fd => 16#7fffffff})),
    ?assertEqual({error, {medium, #{device => "/dev/null", fd => 0}}},
                 erx_tap:init(Config#{fd => 0})),
    ?assertEqual({error, {medium, #{}}}, erx_tap:init(Lone)).

%% A full device's arm is the driver's `writable` event; a write that takes part of a frame
%% ends the medium through the one `failed` message, after which frames drop unsent.
transport_full_and_failed_test() ->
    with_fifo_path(fun(Path) ->
        {ok, _, T0} = erx_tap:init(#{device => Path, lladdr => ?LLADDR}),
        flush_more(),
        Taken = transport_fill(T0, 0),
        _ = read_exactly(Path, 600),
        ?assertEqual({[writable], T0}, erx_tap:event(wake(writable), T0)),
        %% Room for ten short frames is less than one long one: the write takes part of it.
        {{drop, refused}, T1} = erx_tap:transmit(frame(Taken, ?MTU + 14), T0),
        ?assertEqual({stop, {tap, partial}}, erx_tap:event(failed(), T1)),
        ?assertEqual({{drop, refused}, T1}, erx_tap:transmit(frame(0, 60), T1))
    end).

%% --- Helpers -----------------------------------------------------------------------

%% A frame of Size bytes whose first four bytes are I, so frames are told apart.
frame(I, Size) when Size >= 4 ->
    <<I:32, (binary:copy(<<(I band 16#ff)>>, Size - 4))/binary>>;
frame(I, Size) ->
    binary:part(<<I:32>>, 0, Size).

%% Each frame as the NIF hands it up: with its network sum, the sum of its bytes after the
%% Ethernet header, which must be what inet_csum/2 gives for them.
summed(Frames) ->
    [{sum, erx_bytes:inet_csum(0, binary:part(F, 14, byte_size(F) - 14)), F} || F <- Frames].

frames(From, N) ->
    iolist_to_binary([frame(I, 60) || I <- lists:seq(From, From + N - 1)]).

with_pair(Fun) ->
    with_socket_pair(fun(Near, Far) ->
        {ok, H} = erx_tap_nif:adopt(near_fd(Near), ?MTU),
        Fun(H, Far)
    end).

%% A connected pair of UNIX datagram sockets in a fresh directory: the near end, whose
%% descriptor the NIF adopts, and the far end for the test.
with_socket_pair(Fun) ->
    Dir = scratch_dir(),
    {ok, Near} = socket:open(local, dgram, default),
    {ok, Far} = socket:open(local, dgram, default),
    try
        NearAddr = #{family => local, path => filename:join(Dir, "n")},
        FarAddr = #{family => local, path => filename:join(Dir, "f")},
        ok = socket:bind(Near, NearAddr),
        ok = socket:bind(Far, FarAddr),
        ok = socket:connect(Near, FarAddr),
        ok = socket:connect(Far, NearAddr),
        [ok = socket:setopt(S, {socket, Opt}, ?BUFFER)
         || S <- [Near, Far], Opt <- [sndbuf, rcvbuf]],
        Fun(Near, Far)
    after
        _ = socket:close(Near),
        _ = socket:close(Far),
        _ = file:del_dir_r(Dir)
    end.

near_fd(Near) ->
    {ok, Fd} = socket:getopt(Near, {otp, fd}),
    Fd.

with_fifo(Fun) ->
    with_fifo_path(fun(Path) ->
        {ok, H} = erx_tap_nif:open(list_to_binary(Path), ?MTU),
        Fun(H, Path)
    end).

%% A FIFO in a fresh directory, which the NIF opens by name; the test reads it by the same
%% name.
with_fifo_path(Fun) ->
    Dir = scratch_dir(),
    Path = filename:join(Dir, "fifo"),
    Mkfifo = os:find_executable("mkfifo"),
    Port = open_port({spawn_executable, Mkfifo}, [{args, [Path]}, exit_status]),
    receive {Port, {exit_status, 0}} -> ok after ?WAIT_MS -> error(mkfifo) end,
    try
        Fun(Path)
    after
        _ = file:del_dir_r(Dir)
    end.

%% Reads exactly Bytes from the FIFO at Path, which opens at once since the NIF holds it open
%% for writing; what is not read stays in the FIFO while the NIF holds it.
read_exactly(Path, Bytes) ->
    {ok, File} = file:open(Path, [read, raw, binary]),
    try read_exactly(File, Bytes, [])
    after file:close(File)
    end.

read_exactly(_File, 0, Got) -> iolist_to_binary(lists:reverse(Got));
read_exactly(File, Left, Got) ->
    {ok, Data} = file:read(File, Left),
    read_exactly(File, Left - byte_size(Data), [Data | Got]).

fill(H, I) when I < 100000 ->
    case erx_tap_nif:send(H, frame(I, 60)) of
        {ok, 1} -> fill(H, I + 1);
        full -> I
    end.

transport_fill(T, I) when I < 100000 ->
    case erx_tap:transmit(frame(I, 60), T) of
        {ok, T} -> transport_fill(T, I + 1);
        {full, T} -> I
    end.

raised(Fun) ->
    try Fun() of Result -> {returned, Result}
    catch error:Reason -> Reason
    end.

readable(Ms) -> receive {erx_tap, readable} -> readable after Ms -> none end.
writable(Ms) -> receive {erx_tap, writable} -> writable after Ms -> none end.

wake(Which) -> receive {erx_tap, Which} = M -> M after ?WAIT_MS -> error({no_wake, Which}) end.
failed() -> receive {erx_tap, failed, _} = M -> M after ?WAIT_MS -> error(no_failed) end.

flush_more() -> receive {erx_tap, more} -> ok after ?WAIT_MS -> error(no_more) end.

scratch_dir() ->
    %% The emulator's pid too: unique integers restart with each node, and a node a
    %% deadline killed leaves its directories behind.
    Dir = filename:join("/tmp", "erx_tap_" ++ os:getpid() ++ "_" ++
                            integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    Dir.

%% A process that opens the FIFO, which a writer holds open, and reads one byte; a raw file
%% is read only by the process that opened it.
start_reader(Path) ->
    Test = self(),
    Pid = spawn(fun() ->
        {ok, File} = file:open(Path, [read, raw, binary]),
        Test ! {reader, self()},
        Test ! {read, self(), file:read(File, 1)}
    end),
    receive {reader, Pid} -> Pid after ?WAIT_MS -> error(no_reader) end.

%% The reader's result, or `blocked` when its read has not returned within Ms.
reader_result(Pid, Ms) ->
    receive {read, Pid, Result} -> Result after Ms -> exit(Pid, kill), blocked end.
