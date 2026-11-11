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
-include("erx_net_frame.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_tcp_wire.hrl").

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
init(#{crash_at_start := true} = Config) ->
    self() ! {stub, crash},
    init(maps:remove(crash_at_start, Config));
init(#{test := Test, room := Room, tx_limit := Limit}) ->
    {ok, #{link => ethernet, lladdr => ?MAC, mtu => 1500, state => up, tx_limit => Limit,
           finish => none},
     #{test => Test, room => Room}}.

event({stub, crash}, _T) -> error(crash_at_start);
event({stub, room, Room}, T) -> {[writable], T#{room := Room}};
event({stub, Events}, T) -> {Events, T};
event(_Msg, T) -> {[], T}.

transmit(_Frame, #{room := 0} = T) -> {full, T};
%% A run takes the frames there is room for, as a tap that fills in the middle of one.
transmit(#run{} = Run, #{test := Test, room := Room} = T) ->
    Frames = erx_net_frame:cut(Run),
    N = min(Room, length(Frames)),
    [Test ! {sent, iolist_to_binary(F)} || F <- lists:sublist(Frames, N)],
    Answer = case N =:= length(Frames) of
                 true -> ok;
                 false -> {ok, N}
             end,
    {Answer, T#{room := Room - N}};
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
                 fun batches_are_cut_to_the_merge_limit/0,
                 fun flap_while_full_is_not_told/0,
                 fun a_run_taken_in_part_waits_with_its_units/0,
                 fun silent_link_is_told_once_room_returns/0,
                 fun backlog_never_exceeds_the_transmit_credit/0,
                 fun queued_transmits_leave_together/0,
                 fun detached_frames_are_counted/0,
                 fun process_end_counts_a_frame_that_is_not_a_binary/0,
                 fun process_end_ends_the_driver_after_its_hold/0,
                 fun linked_exit_ends_the_driver_after_its_hold/0,
                 %% A thousand loopback sends outlast eunit's 5 s default on a loaded
                 %% host, and a timeout would hide the bound's own failure.
                 {timeout, 60, fun udp_end_bounds_the_driver_queue_against_a_stranger/0}]).

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

%% One event of a thousand minimum-size frames, then one of 300 jumbo frames with their sums
%% and one too long for any MTU: every batch the interface takes is within the merge's limit,
%% so the merge refuses none, and every frame but the long one reaches it once, in order.
batches_are_cut_to_the_merge_limit() ->
    Driver = stub(0, 4),
    {_Rx, _} = attached(Driver, 2000),
    {MaxFrames, MaxBytes} = erx_bytes:tcp_merge_limit(),
    Small = [<<N:32, 0:(56 * 8)>> || N <- lists:seq(1, 1000)],
    Jumbo = [{sum, 0, <<N:32, 0:(9010 * 8)>>} || N <- lists:seq(1, 300)],
    Driver ! {stub, [{frames, Small}]},
    Driver ! {stub, [{frames, Jumbo ++ [binary:copy(<<0>>, MaxBytes + 1)]}]},
    settle(Driver),
    Batches = taken_batches([]),
    Size = fun({sum, _, Bytes}) -> byte_size(Bytes); (Bytes) -> byte_size(Bytes) end,
    [begin
         ?assert(length(Batch) =< MaxFrames),
         ?assert(lists:sum([Size(F) || F <- lists:droplast(Batch)]) < MaxBytes),
         ?assertMatch([_ | _], erx_bytes:tcp_merge(Batch))
     end || Batch <- Batches],
    ?assertEqual(Small ++ Jumbo, lists:append(Batches)),
    ?assert(length(Batches) > 2),
    ?assertEqual(#{too_long => 1}, erx_net_driver:counters(Driver)).

taken_batches(Taken) ->
    receive {frames, _Driver, Batch} -> taken_batches([Batch | Taken])
    after 0 -> lists:reverse(Taken)
    end.

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

%% A run counts its frames against the credit; a transport with room for two of five takes
%% those, the run's tail waits with its three units held, and leaves when room comes.
a_run_taken_in_part_waits_with_its_units() ->
    Driver = stub(2, 8),
    {_, Tx} = attached(Driver, 4),
    Run = #run{template = <<4:4, 5:4, 0, 0:32, 16#4000:16, 64, 6, 0:16, 10, 0, 0, 1, 10, 0, 0, 2,
                            1:16, 2:16, 0:64, 5:4, 0:60>>,
               seq = 16#ffffff00, ack = 7, flags = 16#18, win = 100, ts = none, seg = 100,
               payload = [binary:copy(<<"p">>, 250), binary:copy(<<"q">>, 230)]},
    Frames = [iolist_to_binary(F) || F <- erx_net_frame:cut(Run)],
    ?assertEqual(5, erx_net_frame:units([Run])),
    ok = erx_net_credit:hand(Driver, Tx, erx_net_frame:units([Run]), {transmit, [Run]}),
    {First, Rest} = lists:split(2, Frames),
    ?assertEqual(First, [receive {sent, F} -> F after 1000 -> none end || _ <- First]),
    settle(Driver),
    ?assertEqual(nothing, nothing(sent)),
    ?assertEqual(5, erx_net_credit:free(Tx)),
    Driver ! {stub, room, 10},
    ?assertEqual(Rest, [receive {sent, F} -> F after 1000 -> none end || _ <- Rest]),
    settle(Driver),
    ?assertEqual(8, erx_net_credit:free(Tx)).

%% Every transmit waiting at the driver joins the backlog before the transport is handed
%% anything, in arrival order: a second transmit queued behind a message that leaves the
%% transport no room still leaves with the first.
queued_transmits_leave_together() ->
    Driver = stub(10, 4),
    {_, Tx} = attached(Driver, 4),
    ok = sys:suspend(Driver),
    ok = erx_net_credit:hand(Driver, Tx, 1, {transmit, [<<1>>]}),
    Driver ! {stub, room, 0},
    ok = erx_net_credit:hand(Driver, Tx, 1, {transmit, [<<2>>]}),
    ok = sys:resume(Driver),
    settle(Driver),
    ?assertEqual([<<1>>, <<2>>], [receive {sent, F} -> F after 1000 -> none end || _ <- [1, 2]]).

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

%% The far end's end ends the driver, quietly (a shutdown), once it has lived its hold.
%% The end is waited for without a deadline of its own: eunit's timeout is the hang guard.
process_end_ends_the_driver_after_its_hold() ->
    Far = spawn(fun() -> receive stop -> ok end end),
    Started = erlang:monotonic_time(millisecond),
    Driver = pipe({process, Far}),
    Ref = monitor(process, Driver),
    Far ! stop,
    receive {'DOWN', Ref, process, Driver, Reason} -> ?assertEqual({shutdown, {far_end, normal}}, Reason)
    end,
    ?assert(erlang:monotonic_time(millisecond) - Started >= 1000).

%% An exit signal from what the driver is linked to, a port or socket of its medium
%% failing, ends it the same way, after its hold, and not at once; eunit's timeout is the
%% hang guard.
linked_exit_ends_the_driver_after_its_hold() ->
    Started = erlang:monotonic_time(millisecond),
    Driver = stub(0, 4),
    Ref = monitor(process, Driver),
    _ = spawn(fun() -> link(Driver), exit(epipe) end),
    receive {'DOWN', Ref, process, Driver, Reason} -> ?assertEqual({shutdown, {linked, epipe}}, Reason)
    end,
    ?assert(erlang:monotonic_time(millisecond) - Started >= 1000).

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
    [ok = gen_udp:send(Stranger, Loopback, DriverPort, <<0:480>>) || _ <- lists:seq(1, 1000)],
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
%% Each hint is waited for, not slept for; the replaced far timer was due with the second,
%% so a third hint would follow it at once.
clock_keeps_one_timer_per_caller_test() ->
    flush(),
    Now = erx_net_clock:now(),
    Armed0 = erx_net_clock:arm_by(Now + 120000, infinity),
    Armed1 = erx_net_clock:arm_by(Now + 30000, Armed0),
    receive {erx_net_clock, hint} -> ok end,
    _ = erx_net_clock:arm_by(Now + 120000, infinity),
    receive {erx_net_clock, hint} -> ok end,
    timer:sleep(100),
    ?assertEqual(0, length([x || {erx_net_clock, hint} <- element(2, process_info(self(), messages))])),
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
    [Interfaces] = [Pid || {erx_net_interfaces, Pid, supervisor, _} <- supervisor:which_children(Stack)],
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
    [Interfaces] = [Pid || {erx_net_interfaces, Pid, supervisor, _} <- supervisor:which_children(Stack)],
    [{en0, Link, supervisor, _}] = supervisor:which_children(Interfaces),
    [Driver] = [Pid || {driver, Pid, worker, _} <- supervisor:which_children(Link)],
    exit(Driver, kill),
    %% A hang guard of 2 s at the least, short of eunit's 5 s so that a hang is named.
    ?assertEqual(ignored, ignored(Interfaces, 200)),
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

%% --- A far end's end -------------------------------------------------------------

-define(FAR, erx_net_driver_tests_far).
-define(ME4, <<10, 0, 2, 15>>).
-define(PEER4, <<10, 0, 2, 2>>).
-define(PEER_MAC, <<2, 0, 0, 0, 0, 9>>).
-define(PEER_PORT, 7777).

far_end_test_() ->
    [{timeout, 20, fun far_end_end_restarts_the_link/0},
     {timeout, 30, fun far_end_never_there_spins_no_supervisor/0},
     {timeout, 30, fun crash_at_start_spins_no_supervisor/0},
     {timeout, 20, fun queued_batches_reach_a_holder_as_one_message/0},
     {timeout, 20, fun a_burst_reaches_its_connection_as_one_segment/0},
     {timeout, 20, fun credit_counts_segments/0},
     {timeout, 20, fun offload_pipe_finishes_the_stacks_segments/0}].

%% A pipe whose far end ends ends its driver, and the link supervisor starts the link
%% again: a new driver, over the far end now registered under the same name, answers ARP.
far_end_end_restarts_the_link() ->
    wait_gone(erx_net_tables),
    flush(),
    Old = far_end(),
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [static_pipe()]}),
    unlink(Stack),
    try
        Driver = answers_arp(Old, 50),
        ?assert(is_pid(Driver)),
        Ref = monitor(process, Old),
        exit(Old, kill),
        receive {'DOWN', Ref, process, Old, killed} -> ok end,
        New = far_end(),
        NewDriver = answers_arp(New, 50),
        ?assert(is_pid(NewDriver)),
        ?assertNotEqual(Driver, NewDriver)
    after
        ok = proc_lib:stop(Stack, shutdown, infinity),
        stop_far()
    end.

%% Batches of frames that wait at the interface while it is busy are classified in one
%% pass, so a holder gets one `{items, ...}` message for all of them
%% (docs/design-network-fastpath.md, "Processes and batching"). The test claims a
%% four-tuple as its holder, and three segments the far end sends, each its own batch at
%% the driver, reach it as one message of three items, in order.
queued_batches_reach_a_holder_as_one_message() ->
    wait_gone(erx_net_tables),
    flush(),
    Far = far_end(),
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [static_pipe()]}),
    unlink(Stack),
    try
        Driver = answers_arp(Far, 50),
        [{en0, If, _}] = ets:lookup(erx_net_ifs, en0),
        KeyOf = fun(P) -> {tcp, inet, ?ME4, P, ?PEER4, ?PEER_PORT} end,
        Entry = #{pid => self(), credit => erx_net_credit:new(16)},
        {ok, Port, _, _} = erx_net_bind:claim_tcp(KeyOf, 49152, self(), Entry, erx_net_clock:now()),
        ok = sys:suspend(If),
        [Driver ! {erx_net_pipe, Far, peer_segment(Port, Seq)} || Seq <- [1, 2, 3]],
        settle(Driver),
        ok = sys:resume(If),
        receive
            {items, If, Items} ->
                ?assertEqual([1, 2, 3], [Seq || {#tcp{seq = Seq}, _, _, _} <- Items])
        after 3000 -> error(no_items)
        end,
        ?assertEqual(nothing, nothing(items))
    after
        ok = proc_lib:stop(Stack, shutdown, infinity),
        stop_far()
    end.

%% A burst of in-order segments the far end hands up as one batch is merged by the
%% interface (docs/design-network-fastpath.md, "The merge, before classification"): the
%% holder gets one segment, the first frame's sequence number with the last's
%% acknowledgement, holding every payload in order, and its eight units.
a_burst_reaches_its_connection_as_one_segment() ->
    with_holder(64, fun(Far, Driver, If, Port, Credit) ->
        Far ! {inject, Driver, {frames, burst(Port, 1000, 8)}},
        receive
            {items, If, [{#tcp{seq = 1000, ack = 7}, {merged, 8, Pieces}, 0, unicast}]} ->
                ?assertEqual(iolist_to_binary([payload(I) || I <- lists:seq(0, 7)]),
                             iolist_to_binary(Pieces))
        after 3000 -> error(no_items)
        end,
        ?assertEqual(64 - 8, erx_net_credit:free(Credit))
    end).

%% Test 8 of the design: a connection slower than the peer's bursts never has more than
%% its credit's limit of frames waiting for it, merged or not, since a merged segment takes
%% a unit for each segment it holds. The holder, the test, takes no unit back while ten
%% bursts of eight arrive, and the interface hands it 16 frames' worth and no more.
credit_counts_segments() ->
    with_holder(16, fun(Far, Driver, If, Port, Credit) ->
        [Far ! {inject, Driver, {frames, burst(Port, 1000 + B * 800, 8)}} || B <- lists:seq(0, 9)],
        settle(Driver),
        _ = sys:get_state(If),
        Held = lists:sum([frames_held(Item) || Item <- held_items(If)]),
        ?assertEqual(16, Held),
        ?assertEqual(0, erx_net_credit:free(Credit))
    end).

%% The stack over a pipe with the test as the holder of a four-tuple whose credit has Limit
%% units; Fun gets the far end, the driver, the interface, the local port and the credit.
with_holder(Limit, Fun) ->
    wait_gone(erx_net_tables),
    flush(),
    Far = far_end(),
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [static_pipe()]}),
    unlink(Stack),
    try
        Driver = answers_arp(Far, 50),
        [{en0, If, _}] = ets:lookup(erx_net_ifs, en0),
        KeyOf = fun(P) -> {tcp, inet, ?ME4, P, ?PEER4, ?PEER_PORT} end,
        Credit = erx_net_credit:new(Limit),
        Entry = #{pid => self(), credit => Credit},
        {ok, Port, _, _} = erx_net_bind:claim_tcp(KeyOf, 49152, self(), Entry, erx_net_clock:now()),
        Fun(Far, Driver, If, Port, Credit)
    after
        ok = proc_lib:stop(Stack, shutdown, infinity),
        stop_far()
    end.

%% N in-order data segments of 100 bytes from Seq, their acknowledgements advancing.
burst(Port, Seq, N) ->
    [peer_segment(Port, Seq + 100 * I, I, payload(I)) || I <- lists:seq(0, N - 1)].

payload(I) -> binary:copy(<<($a + I rem 26)>>, 100).

held_items(If) ->
    receive {items, If, Items} -> Items ++ held_items(If) after 200 -> [] end.

frames_held({_, {merged, N, _}, _, _}) -> N;
frames_held(_) -> 1.

%% The stack over a pipe in its offload mode and over a plain one: the interface's row
%% names the driver's finisher, and a segment to a closed port, which reaches the stack
%% with its network sum in the offload mode, is answered with a RST whose checksum the
%% far end's decoder accepts, finished by the pipe or by the frame layer.
offload_pipe_finishes_the_stacks_segments() ->
    [begin
         wait_gone(erx_net_tables),
         flush(),
         Far = far_end(),
         #{transport := {erx_net_pipe, Config}} = Link = static_pipe(),
         Piped = Link#{transport := {erx_net_pipe, Config#{offload => Offload}}},
         {ok, Stack} = erx_net_sup:start_link(#{interfaces => [Piped]}),
         unlink(Stack),
         try
             Driver = answers_arp(Far, 50),
             ?assertMatch([{en0, _, #{finish := Finish}}], ets:lookup(erx_net_ifs, en0)),
             Far ! {inject, Driver, peer_segment(9, 1)},
             receive
                 {far, Far, Driver, <<_:12/binary, 16#0800:16, Packet/binary>>} ->
                     {ok, #ip4{p = 6, src = Src, dst = Dst}, Segment} = erx_ip4_wire:decode(Packet),
                     Pseudo = erx_ip4_wire:pseudo_sum(Src, Dst, byte_size(Segment), 6),
                     ?assertMatch({Offload, {ok, #tcp{dport = ?PEER_PORT, flags = ?TH_RST}, <<>>}},
                                  {Offload, erx_tcp_wire:decode(Pseudo, Segment)})
             after 3000 -> error({no_rst, Offload})
             end
         after
             ok = proc_lib:stop(Stack, shutdown, infinity),
             stop_far()
         end
     end || {Offload, Finish} <- [{true, copy}, {false, none}]].

%% The pipe alone: without the offload mode a delayed frame is dropped as `malformed` and
%% frames come up bare; with it a delayed frame reaches the far end finished and each frame
%% comes up with its network sum. Only a process end has the mode.
pipe_offload_mode_test() ->
    flush(),
    Config = #{far => {process, self()}, lladdr => ?MAC},
    Delayed = {csum, 14, 2, [<<0:112>>, <<1, 2, 3>>, <<4, 5, 6>>]},
    Frame = <<0:112, 1, 2, 3>>,
    {ok, #{finish := none}, Plain} = erx_net_pipe:init(Config),
    ?assertMatch({{drop, malformed}, _}, erx_net_pipe:transmit(Delayed, Plain)),
    ?assertEqual({[{frames, [Frame]}], Plain}, erx_net_pipe:event({erx_net_pipe, self(), Frame}, Plain)),
    {ok, #{finish := copy}, Offload} = erx_net_pipe:init(Config#{offload => true}),
    ?assertMatch({{drop, malformed}, _}, erx_net_pipe:transmit({csum, 13, 2, Frame}, Offload)),
    ?assertMatch({ok, _}, erx_net_pipe:transmit(Delayed, Offload)),
    receive {erx_net_pipe, _, Sent} -> ?assertEqual(erx_net_frame:finish(Delayed), Sent)
    after 1000 -> error(nothing_sent)
    end,
    ?assertEqual({[{frames, [{sum, erx_bytes:inet_csum(0, <<1, 2, 3>>), Frame}]}], Offload},
                 erx_net_pipe:event({erx_net_pipe, self(), Frame}, Offload)),
    Udp = {udp, {{127, 0, 0, 1}, 0}, {{127, 0, 0, 1}, 9}},
    ?assertEqual({error, {offload, true}}, erx_net_pipe:init(Config#{far := Udp, offload => true})),
    ?assertEqual({error, {offload, yes}}, erx_net_pipe:init(Config#{offload => yes})).

%% A frame from the peer to ?ME4's Port: a TCP segment with sequence number Seq.
peer_segment(Port, Seq) ->
    peer_segment(Port, Seq, 0, <<"batch">>).

peer_segment(Port, Seq, Ack, Payload) ->
    Tcp = #tcp{sport = ?PEER_PORT, dport = Port, seq = Seq, ack = Ack, flags = ?TH_ACK,
               win = 65535, urp = 0},
    Seg = iolist_to_binary(erx_tcp_wire:encode(Tcp, Payload,
                                               erx_ip4_wire:pseudo_sum(?PEER4, ?ME4, 0, 6), sender)),
    Ip = erx_ip4_wire:encode(#ip4{len = 20 + byte_size(Seg), ttl = 64, p = 6, src = ?PEER4,
                                  dst = ?ME4}),
    <<?MAC/binary, ?PEER_MAC/binary, 16#0800:16, Ip/binary, Seg/binary>>.

%% A far end that is never there ends every driver at its start: each lives out its hold,
%% so the link restarts about once a second and no supervisor above it gives up.
far_end_never_there_spins_no_supervisor() ->
    stop_far(),
    spins_no_supervisor(static_pipe()).

%% A transport that crashes at once at every start, as a device that breaks its queue at
%% once: the stack starts all the same, though the link's first driver ends under its
%% interface's start, and the link restarts about once a second as above.
crash_at_start_spins_no_supervisor() ->
    spins_no_supervisor(#{name => en0, ip4 => dhcp,
                          transport => {?MODULE, #{crash_at_start => true, test => self(),
                                                   room => 64, tx_limit => 4}}}).

%% Starts the stack with Link, whose driver ends at every start, and checks that its link
%% restarts, no faster than each driver's hold allows, and the supervisors above it stay.
%% The third driver cannot start before two holds have passed since the stack's start, so
%% the bound holds however slow the host is; the wait for it is only a hang guard.
spins_no_supervisor(Link) ->
    wait_gone(erx_net_tables),
    flush(),
    %% Trapped, so that a start that fails is this case's failure, not its process's end.
    process_flag(trap_exit, true),
    Before = erlang:monotonic_time(millisecond),
    Started = erx_net_sup:start_link(#{interfaces => [Link]}),
    process_flag(trap_exit, false),
    ?assertMatch({ok, _}, Started),
    {ok, Stack} = Started,
    unlink(Stack),
    %% Stopped whatever the verdict, so that the next case does not wait on its tables.
    try
        Interfaces = interfaces(Stack),
        {third_driver_at, At} = third_driver(erlang:monotonic_time(millisecond) + 20000, []),
        ?assert(is_process_alive(Stack)),
        ?assertEqual(Interfaces, interfaces(Stack)),
        %% Two of erx_net_driver's 1000 ms holds, copied rather than read from the module,
        %% so that a seeded shorter hold fails here.
        ?assert(At - Before >= 2 * 1000)
    after
        stop_stack(Stack)
    end.

%% Stops Stack, which a seeded fault may already have ended.
stop_stack(Stack) ->
    try proc_lib:stop(Stack, shutdown, infinity) catch exit:noproc -> ok end.

%% Ends the far end registered as ?FAR, if any, and waits until the name is free.
stop_far() ->
    case whereis(?FAR) of
        undefined -> ok;
        Far -> exit(Far, kill), wait_gone(?FAR)
    end.

static_pipe() ->
    #{name => en0, ip4 => #{addr => ?ME4, plen => 24, gateway => ?PEER4},
      transport => {erx_net_pipe, #{far => {process, ?FAR}, lladdr => ?MAC}}}.

interfaces(Stack) ->
    [Interfaces] = [Pid || {erx_net_interfaces, Pid, supervisor, _} <- supervisor:which_children(Stack)],
    Interfaces.

%% Polls the driver registered for en0 until a third distinct one is seen, and answers
%% when; a link that stops restarting fails the case as hung at Deadline.
third_driver(_Deadline, Seen) when length(Seen) >= 3 ->
    {third_driver_at, erlang:monotonic_time(millisecond)};
third_driver(Deadline, Seen) ->
    erlang:monotonic_time(millisecond) =< Deadline orelse error({hung_short_of_a_third_driver, Seen}),
    timer:sleep(20),
    case erx_net_tables:driver(en0) of
        {ok, Pid} -> third_driver(Deadline, lists:usort([Pid | Seen]));
        none -> third_driver(Deadline, Seen)
    end.

%% A far end registered as ?FAR: it hands the test what a driver sends it and sends a
%% driver what the test asks.
far_end() ->
    Test = self(),
    Far = spawn(fun() ->
                        true = register(?FAR, self()),
                        Test ! {registered, self()},
                        far_loop(Test)
                end),
    receive {registered, Far} -> Far end.

far_loop(Test) ->
    receive
        {erx_net_pipe, Driver, Frame} -> Test ! {far, self(), Driver, Frame};
        {inject, Driver, Frame} -> Driver ! {erx_net_pipe, self(), Frame}
    end,
    far_loop(Test).

%% Asks en0's registered driver, through Far, who has ?ME4, until an ARP reply comes back;
%% answers the driver that sent it.
answers_arp(_Far, 0) ->
    no_answer;
answers_arp(Far, Tries) ->
    case erx_net_tables:driver(en0) of
        {ok, Driver} -> Far ! {inject, Driver, arp_request()};
        none -> ok
    end,
    receive
        {far, Far, From, <<Dst:6/binary, _:6/binary, 16#0806:16, _:6/binary, 2:16, _/binary>>}
          when Dst =:= ?PEER_MAC ->
            From
    after 100 ->
        answers_arp(Far, Tries - 1)
    end.

arp_request() ->
    <<16#ffffffffffff:48, ?PEER_MAC/binary, 16#0806:16, 1:16, 16#0800:16, 6, 4, 1:16,
      ?PEER_MAC/binary, ?PEER4/binary, 0:48, ?ME4/binary, 0:144>>.
