%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the pipe's `port` end (docs/design-network-stack.md, "The pipe", "The tap
%% helper") on a host without a tap device, run by test/host/erx_net_tap_test.rb, which
%% builds the helper into erx_net's priv/ beside the compiled modules. A named pipe opened
%% for reading and writing stands in for the tap: the helper reads back each frame it
%% writes, so one frame sent comes back as one frame received. The helper's own framing
%% is the Ruby test's.
-module(erx_net_pipe_port_tests).

-include_lib("eunit/include/eunit.hrl").

-define(LLADDR, <<2, 0, 0, 0, 0, 1>>).
-define(WAIT_MS, 5000).

config(Device) -> #{far => {port, Device}, lladdr => ?LLADDR}.

%% A helper that cannot open its device exits; the port's close stops the pipe, which
%% ends its driver, and a frame sent before the driver has seen it is refused.
missing_device_stops_the_pipe_test() ->
    {ok, #{state := up}, T0} = erx_net_pipe:init(config("/nonexistent/erx_net_tap")),
    Down = receive {'DOWN', _, port, _, _} = M -> M after ?WAIT_MS -> timeout end,
    ?assertEqual({stop, {far_end, normal}}, erx_net_pipe:event(Down, T0)),
    ?assertMatch({{drop, refused}, _}, erx_net_pipe:transmit(frame(60), T0)).

%% The driver keeps sending while the helper exits: a frame that meets the port after the
%% helper is gone but before the port has closed would make ERTS end the port with epipe,
%% which the helper prevents by closing its output and reading its input until the port
%% has closed. The pipe stops once the port has closed, and the process that owns the
%% port lives on.
transmit_while_the_helper_exits_test() ->
    Test = self(),
    {Owner, Ref} = spawn_monitor(fun() ->
        {ok, _, T} = erx_net_pipe:init(config("/nonexistent/erx_net_tap")),
        Test ! {self(), keep_sending(T, erlang:monotonic_time(millisecond) + ?WAIT_MS)}
    end),
    Result = receive {Owner, R} -> R; {'DOWN', Ref, process, Owner, Why} -> {died, Why} end,
    ?assertMatch({down, {{drop, refused}, _}}, Result).

%% Sends frames until a message to the pipe stops it, then one frame more.
keep_sending(T0, Deadline) ->
    {_, T1} = erx_net_pipe:transmit(frame(60), T0),
    receive
        Msg ->
            case erx_net_pipe:event(Msg, T1) of
                {stop, _} -> {down, erx_net_pipe:transmit(frame(60), T1)};
                {_, T2} -> keep_sending(T2, Deadline)
            end
    after 0 ->
        case erlang:monotonic_time(millisecond) > Deadline of
            true -> timeout;
            false -> keep_sending(T1, Deadline)
        end
    end.

%% The port closes when its owner, the driver, ends.
the_port_ends_with_its_owner_test() ->
    Fifo = fifo(),
    Test = self(),
    try
        {Owner, Ref} = spawn_monitor(fun() ->
            {ok, _, _} = erx_net_pipe:init(config(Fifo)),
            [Port] = [P || P <- erlang:ports(), erlang:port_info(P, connected) =:= {connected, self()}],
            Test ! {self(), Port},
            receive stop -> ok end
        end),
        Port = receive {Owner, P} -> P after ?WAIT_MS -> error(no_port) end,
        PortRef = erlang:monitor(port, Port),
        exit(Owner, kill),
        receive {'DOWN', Ref, process, Owner, killed} -> ok end,
        ?assertEqual(closed, receive {'DOWN', PortRef, port, Port, _} -> closed after ?WAIT_MS -> open end)
    after
        file:delete(Fifo)
    end.

%% A frame sent through the helper comes back unchanged as one port message, which is one
%% frame; one longer than the MTU and its header is dropped as too_long either way.
loopback_through_the_helper_test() ->
    Fifo = fifo(),
    try
        {ok, #{state := up}, T0} = erx_net_pipe:init(config(Fifo)),
        Frame = frame(60),
        {ok, T1} = erx_net_pipe:transmit([binary:part(Frame, 0, 14), binary:part(Frame, 14, 46)], T0),
        Data = receive {P, {data, _}} = M when is_port(P) -> M after ?WAIT_MS -> timeout end,
        ?assertMatch({_, {data, Frame}}, Data),
        ?assertEqual({[{frames, [Frame]}], T1}, erx_net_pipe:event(Data, T1)),
        {Port, _} = Data,
        ?assertMatch({[{dropped, too_long}], _}, erx_net_pipe:event({Port, {data, frame(1515)}}, T1)),
        ?assertMatch({{drop, too_long}, _}, erx_net_pipe:transmit(frame(1515), T1)),
        port_close(Port)
    after
        file:delete(Fifo)
    end.

frame(Bytes) -> <<<<(N rem 251)>> || N <- lists:seq(1, Bytes)>>.

%% A named pipe in the working directory, which the Ruby test makes a fresh temporary one.
fifo() ->
    Path = filename:absname("tap-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Mkfifo = open_port({spawn_executable, os:find_executable("mkfifo")},
                       [{args, [Path]}, exit_status]),
    receive {Mkfifo, {exit_status, 0}} -> Path after ?WAIT_MS -> error(mkfifo) end.
