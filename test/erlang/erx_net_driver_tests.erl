%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the driver and the pipe (docs/design-network-stack.md, "The stack on a
%% development host", "The driver and the clock"), the test process standing in for the
%% interface. This module is also the stub transport the credit cases drive: its events are
%% whatever the test sends as {stub, Events}, and it takes frames while it has room.
%% test/host/erx_net_effect_test.rb seeds the faults these cases exist for.
-module(erx_net_driver_tests).

-behaviour(erx_net_driver).

-include_lib("eunit/include/eunit.hrl").

-export([init/1, event/2, transmit/2]).
-export([log/2]).

-define(MAC, <<2, 0, 0, 0, 0, 1>>).

%% --- The stub transport ----------------------------------------------------------

init(#{nothing_to_drive := true}) ->
    ignore;
init(#{nothing_at_restart := Key} = Config) ->
    case persistent_term:get(Key, first) of
        first -> persistent_term:put(Key, again), init(maps:remove(nothing_at_restart, Config));
        again -> ignore
    end;
init(#{test := Test, room := Room, tx_limit := Limit}) ->
    {ok, #{link => ethernet, lladdr => ?MAC, mtu => 1500, state => up, tx_limit => Limit},
     #{test => Test, room => Room}}.

event({stub, room, Room}, T) -> {[writable], T#{room := Room}};
event({stub, Events}, T) -> {Events, T};
event(_Msg, T) -> {[], T}.

transmit(_Frame, #{room := 0} = T) -> {full, T};
transmit(Frame, #{test := Test, room := Room} = T) ->
    Test ! {sent, iolist_to_binary(Frame)},
    {ok, T#{room := Room - 1}}.

%% --- Fixtures --------------------------------------------------------------------

with_tables(Test) ->
    {setup,
     fun() -> {ok, Pid} = erx_net_tables:start_link(), unlink(Pid), Pid end,
     fun(Pid) -> exit(Pid, kill) end,
     fun(_) -> Test end}.

stub(Room, TxLimit) ->
    flush(),
    {ok, Driver} = erx_net_driver:start_link(en0, ?MODULE, #{test => self(), room => Room,
                                                              tx_limit => TxLimit}),
    unlink(Driver),
    Driver.

attached(Driver, RxLimit) ->
    Rx = erx_net_credit:new(RxLimit),
    {ok, _Info, Tx} = erx_net_driver:attach(Driver, Rx),
    {Rx, Tx}.

%% Forgets what an earlier case left in the mailbox.
flush() -> receive _ -> flush() after 0 -> ok end.

%% Waits until the driver has handled every message sent before this call.
settle(Driver) -> _ = erx_net_driver:counters(Driver), ok.

nothing(Pattern) ->
    receive Msg when element(1, Msg) =:= Pattern -> {unexpected, Msg} after 50 -> nothing end.

%% --- Receiving -------------------------------------------------------------------

driver_test_() ->
    with_tables([fun refused_batch_is_dropped_whole/0,
                 fun flap_while_full_is_not_told/0,
                 fun silent_link_is_told_once_room_returns/0,
                 fun backlog_never_exceeds_the_transmit_credit/0,
                 fun detached_frames_are_counted/0,
                 fun process_end_counts_a_frame_that_is_not_a_binary/0,
                 fun process_end_reports_the_far_end_down/0,
                 fun udp_end_bounds_the_driver_queue_against_a_stranger/0]).

refused_batch_is_dropped_whole() ->
    Driver = stub(0, 4),
    {Rx, _} = attached(Driver, 2),
    Driver ! {stub, [{frames, [<<"a">>]}]},
    Driver ! {stub, [{frames, [<<"b">>, <<"c">>]}]},
    settle(Driver),
    receive {frames, Driver, [<<"a">>]} -> ok end,
    ?assertEqual(nothing, nothing(frames)),
    ?assertEqual(#{no_room => 2}, erx_net_driver:counters(Driver)),
    ?assertEqual(1, erx_net_credit:free(Rx)).

flap_while_full_is_not_told() ->
    Driver = stub(0, 4),
    {Rx, _} = attached(Driver, 1),
    Driver ! {stub, [{frames, [<<"a">>]}]},
    Driver ! {stub, [{link, down}, {link, up}]},
    settle(Driver),
    ok = erx_net_credit:take(Rx, 1),
    Driver ! {stub, []},
    settle(Driver),
    ?assertEqual(nothing, nothing(link)).

silent_link_is_told_once_room_returns() ->
    Driver = stub(0, 4),
    {Rx, _} = attached(Driver, 1),
    Driver ! {stub, [{frames, [<<"a">>]}]},
    Driver ! {stub, [{link, down}]},
    settle(Driver),
    ok = erx_net_credit:take(Rx, 1),
    %% No message follows: only the driver's own retry can tell the interface.
    receive {link, Driver, down} -> ok after 1000 -> ?assert(false) end,
    ?assertEqual(nothing, nothing(link)).

backlog_never_exceeds_the_transmit_credit() ->
    Driver = stub(0, 4),
    {_, Tx} = attached(Driver, 4),
    Frames = [<<N>> || N <- lists:seq(1, 4)],
    ok = erx_net_credit:hand(Driver, Tx, 4, {transmit, Frames}),
    settle(Driver),
    ?assertEqual(full, erx_net_credit:hand(Driver, Tx, 1, {transmit, [<<5>>]})),
    Driver ! {stub, room, 10},
    ?assertEqual(Frames, [receive {sent, F} -> F end || _ <- Frames]),
    settle(Driver),
    ?assertEqual(4, erx_net_credit:free(Tx)).

detached_frames_are_counted() ->
    Driver = stub(0, 4),
    Driver ! {stub, [{frames, [<<"a">>, <<"b">>]}]},
    ?assertEqual(#{detached => 2}, erx_net_driver:counters(Driver)).

%% --- The pipe's ends -------------------------------------------------------------

pipe(Far) ->
    flush(),
    {ok, Driver} = erx_net_driver:start_link(en0, erx_net_pipe, #{far => Far, lladdr => ?MAC}),
    unlink(Driver),
    Driver.

process_end_counts_a_frame_that_is_not_a_binary() ->
    Driver = pipe({process, self()}),
    _ = attached(Driver, 4),
    Driver ! {erx_net_pipe, self(), [<<"not">>, <<"a binary">>]},
    Driver ! {erx_net_pipe, self(), <<"frame">>},
    receive {frames, Driver, Frames} -> ?assertEqual([<<"frame">>], Frames) after 1000 -> ?assert(false) end,
    ?assertEqual(#{malformed => 1}, erx_net_driver:counters(Driver)).

process_end_reports_the_far_end_down() ->
    Far = spawn(fun() -> receive stop -> ok end end),
    Driver = pipe({process, Far}),
    _ = attached(Driver, 4),
    Far ! stop,
    receive {link, Driver, down} -> ok after 1000 -> ?assert(false) end.

udp_end_bounds_the_driver_queue_against_a_stranger() ->
    Loopback = {127, 0, 0, 1},
    {ok, Peer} = gen_udp:open(0, [binary, {ip, Loopback}]),
    {ok, PeerPort} = inet:port(Peer),
    {ok, Stranger} = gen_udp:open(0, [binary, {ip, Loopback}, {sndbuf, 1 bsl 20}]),
    Driver = pipe({udp, {Loopback, 0}, {Loopback, PeerPort}}),
    _ = attached(Driver, 64),
    {ok, [{_, DriverPort}]} = erx_net_driver_ports(Driver),
    %% The driver takes nothing while the stranger sends, so only the socket's own
    %% {active, 64} bounds what reaches its mailbox: 64 datagrams and one udp_passive.
    ok = sys:suspend(Driver),
    [ok = gen_udp:send(Stranger, Loopback, DriverPort, <<0:480>>) || _ <- lists:seq(1, 10000)],
    timer:sleep(200),
    {message_queue_len, Most} = process_info(Driver, message_queue_len),
    ok = sys:resume(Driver),
    ?assert(Most =< 65),
    settle(Driver),
    ?assertMatch(#{stranger := N} when N > 0, erx_net_driver:counters(Driver)),
    ?assertEqual(nothing, nothing(frames)).

%% The local port of the driver's socket, from the ports it holds.
erx_net_driver_ports(Driver) ->
    {links, Links} = process_info(Driver, links),
    {ok, [{P, Port} || P <- Links, is_port(P), {ok, Port} <- [inet:port(P)]]}.

%% --- The clock -------------------------------------------------------------------

%% An earlier deadline replaces the pending timer instead of adding one: a far deadline,
%% a nearer one, and the far one armed again after the first hint give two hints, not three.
clock_keeps_one_timer_per_caller_test() ->
    flush(),
    Now = erx_net_clock:now(),
    Armed0 = erx_net_clock:arm_by(Now + 120000, infinity),
    Armed1 = erx_net_clock:arm_by(Now + 30000, Armed0),
    receive {erx_net_clock, hint} -> ok end,
    _ = erx_net_clock:arm_by(Now + 120000, infinity),
    timer:sleep(250),
    ?assertEqual(1, length([x || {erx_net_clock, hint} <- element(2, process_info(self(), messages))])),
    ?assertMatch({_, _}, Armed1).

%% --- A transport with nothing to drive ---------------------------------------------

%% The stack starts without a link whose transport answers ignore, as erXos boots without
%% its network device: no driver registers, and no interface or DHCP client starts
%% looking for one.
nothing_to_drive_is_no_interface_test() ->
    wait_gone(erx_net_tables),
    Link = #{name => en0, ip4 => dhcp, transport => {?MODULE, #{nothing_to_drive => true}}},
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [Link]}),
    unlink(Stack),
    [Interfaces] = [Pid || {interfaces, Pid, supervisor, _} <- supervisor:which_children(Stack)],
    ?assertMatch([{en0, undefined, supervisor, _}], supervisor:which_children(Interfaces)),
    ?assertEqual(none, erx_net_tables:driver(en0)),
    ok = proc_lib:stop(Stack, shutdown, infinity).

%% A driver's end restarts its whole link through the one start that decides ignore, so a
%% restarted driver that finds nothing leaves no interface starting without it: no child
%% of the link fails to start, and the link is ignored.
nothing_at_restart_is_no_interface_test() ->
    wait_gone(erx_net_tables),
    Key = {?MODULE, nothing_at_restart},
    _ = persistent_term:erase(Key),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
    Transport = {?MODULE, #{nothing_at_restart => Key, test => self(), room => 64, tx_limit => 4}},
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [#{name => en0, ip4 => dhcp,
                                                            transport => Transport}]}),
    unlink(Stack),
    [Interfaces] = [Pid || {interfaces, Pid, supervisor, _} <- supervisor:which_children(Stack)],
    [{en0, Link, supervisor, _}] = supervisor:which_children(Interfaces),
    [Driver] = [Pid || {driver, Pid, worker, _} <- supervisor:which_children(Link)],
    exit(Driver, kill),
    ?assertEqual(ignored, ignored(Interfaces, 100)),
    ok = proc_lib:stop(Stack, shutdown, infinity),
    ok = logger:remove_handler(?MODULE),
    _ = persistent_term:erase(Key),
    ?assertEqual(nothing, nothing(supervisor_report_start_error)).

%% Waits until the interfaces supervisor holds en0's link as ignored.
ignored(_Interfaces, 0) ->
    timeout;
ignored(Interfaces, Tries) ->
    case supervisor:which_children(Interfaces) of
        [{en0, undefined, supervisor, _}] -> ignored;
        _ -> timer:sleep(10), ignored(Interfaces, Tries - 1)
    end.

%% The logger handler of nothing_at_restart_is_no_interface_test: a supervisor's report that
%% a child failed to start reaches the test.
log(#{msg := {report, #{label := {supervisor, start_error}}}}, #{config := #{test := Test}}) ->
    Test ! {supervisor_report_start_error};
log(_Event, _Config) ->
    ok.

wait_gone(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> Ref = monitor(process, Pid), receive {'DOWN', Ref, _, _, _} -> ok end
    end.
