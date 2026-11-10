%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_conn_tests).
-moduledoc """
The effects of erx_tcp_conn (docs/design-network-stack.md, "Receiving", "Transmitting",
"Deadlines, not timers"), with the test process standing in for the interface, its driver
and the remote peer: it publishes an interface row whose pid, driver and credits are its
own, reads the frames the connection hands its driver, and answers with segments it hands
the connection against the credit of its demultiplexing entry. The pure step is tested on
its own (erx_tcp_*_tests); these cases check the loop around it: the clock armed after
every step, the credit taken as items arrive, the window opened as the owner reads, a RST
ending the process and its entry, a close through TIME-WAIT, and the recv results stock
gen_tcp gives: a recv for the whole buffer completes, a timed-out recv keeps its bytes,
and a short tail at the peer's FIN answers closed.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_tcp.hrl").

-define(OURS, <<10, 0, 2, 15>>).
-define(PEER, <<10, 0, 2, 2>>).
-define(PEER_PORT, 7777).
-define(PEER_ISS, 5000).
-define(WAIT, 3000).

%% Each case runs in the process that set the stand-in up, since the frames come to it.
conn_test_() ->
    [{Name, fun() -> Setup = setup(), try Case() after cleanup(Setup) end end}
     || {Name, Case} <-
     [{"the SYN is retransmitted on the clock", fun syn_is_retransmitted_on_its_timer/0},
      {"connect answers once established", fun connect_answers_once_established/0},
      {"a connection's death answers its connect", fun connect_is_answered_when_the_connection_dies/0},
      {"the credit is taken as items arrive", fun credit_is_taken_as_items_arrive/0},
      {"queued items are stepped once", fun queued_items_are_stepped_once/0},
      {"reading opens the window", fun reading_opens_the_window/0},
      {"a recv of the whole buffer completes", fun recv_of_the_whole_buffer_completes/0},
      {"a recv that times out keeps what it held", fun recv_that_times_out_keeps_what_it_held/0},
      {"a short tail at the FIN answers closed and stays",
       fun short_tail_at_the_fin_answers_closed_and_stays/0},
      {"a RST ends the connection", fun rst_ends_the_connection_and_its_entry/0},
      {"close runs FIN both ways into TIME-WAIT", fun close_reaches_time_wait_with_its_timer/0}]].

%% --- The stand-in interface ------------------------------------------------------

setup() ->
    ok = persistent_term:put({erx_net_sup, runtime}, erx_net_local),
    {ok, Tables} = erx_net_tables:start_link(),
    unlink(Tables),
    Me = self(),
    Tx = erx_net_credit:new(256),
    Iface = #{name => en0, pid => Me, link => ethernet, lladdr => <<2, 0, 0, 0, 0, 1>>,
              mtu => 1500, mtu6 => 1500, hlim => 64, finish => none,
              driver => Me, driver_credit => Tx,
              rx_credit => erx_net_credit:new(256), credit => erx_net_credit:new(256)},
    true = ets:insert(erx_net_ifs, {en0, Me, Iface}),
    true = ets:insert(erx_net_addrs, {{Me, ?OURS}, Me, 0,
                                      #{addr => ?OURS, plen => 24, ifname => en0, flags => [],
                                        broadcast => <<10, 0, 2, 255>>}}),
    true = ets:insert(erx_net_routes, {{Me, <<10, 0, 2, 0>>, 24}, Me,
                                       #{prefix => <<10, 0, 2, 0>>, plen => 24, gateway => none,
                                         ifname => en0, metric => 0}}),
    true = ets:insert(erx_net_neigh, {{Me, ?PEER}, <<2, 0, 0, 0, 0, 2>>, fresh, 0}),
    _ = ets:update_counter(erx_net_gen, gen, 1),
    {ok, Grant} = erx_net_grant:start_link(local, #{}),
    unlink(Grant),
    put(tx, Tx),
    {Tables, Grant}.

cleanup({Tables, Grant}) ->
    [begin Ref = monitor(process, P), exit(P, kill), receive {'DOWN', Ref, _, _, _} -> ok end end
     || P <- [Grant, Tables]],
    flush().

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% Frames the connection handed its driver, as {Header, Payload}, their units taken.
segments() ->
    receive
        {transmit, Frames} ->
            ok = erx_net_credit:take(get(tx), length(Frames)),
            [decode(iolist_to_binary(F)) || F <- Frames]
    after ?WAIT -> error({no_segment, process_info(self(), messages)})
    end.

decode(<<_Eth:14/binary, Packet/binary>>) ->
    {ok, #ip4{src = ?OURS, dst = ?PEER}, Seg} = erx_ip4_wire:decode(Packet),
    {ok, Tcp, Payload} = erx_tcp_wire:decode(erx_ip4_wire:pseudo_sum(?OURS, ?PEER, byte_size(Seg), 6),
                                             Seg),
    {Tcp, Payload}.

%% A segment from the peer, handed as an interface hands it.
hand(Conn, Port, Fields, Payload) ->
    Tcp = maps:fold(fun(seq, V, T) -> T#tcp{seq = V};
                       (ack, V, T) -> T#tcp{ack = V};
                       (flags, V, T) -> T#tcp{flags = V};
                       (opts, V, T) -> T#tcp{opts = V}
                    end, #tcp{sport = ?PEER_PORT, dport = Port, seq = 0, ack = 0, flags = 0,
                              win = 65535, urp = 0}, Fields),
    [#{credit := Credit}] = erx_net_tables:demux(key(Port)),
    ok = erx_net_credit:hand(Conn, Credit, 1, {items, self(), [{Tcp, Payload, 0, unicast}]}).

key(Port) -> {tcp, inet, ?OURS, Port, ?PEER, ?PEER_PORT}.

%% Starts a connect as the owner, the test process, and returns its request and its SYN.
start_connect() ->
    Req = gen_server:send_request(erx_net_grant,
                                  {tcp_connect, inet, {10, 0, 2, 2}, ?PEER_PORT,
                                   [binary, {active, false}], 10000}),
    [{#tcp{flags = ?TH_SYN} = Syn, <<>>}] = segments(),
    {Req, Syn}.

%% The handshake: SYN out, SYN-ACK in, connect answered, ACK out. The SYN-ACK's options
%% decide whether the connection scales its window.
established() ->
    established(#tcp_opts{mss = 1460}).

established(SynAckOpts) ->
    {Req, #tcp{sport = Port, seq = Iss}} = start_connect(),
    [{_, Conn, _}] = ets:lookup(erx_net_demux, key(Port)),
    hand(Conn, Port, #{seq => ?PEER_ISS, ack => Iss + 1, flags => ?TH_SYN bor ?TH_ACK,
                       opts => SynAckOpts}, <<>>),
    {reply, {ok, Sock}} = gen_server:receive_response(Req, ?WAIT),
    [{#tcp{flags = ?TH_ACK, ack = Ack}, <<>>}] = segments(),
    ?assertEqual(?PEER_ISS + 1, Ack),
    #{sock => Sock, conn => Conn, port => Port, snd => Iss + 1, rcv => ?PEER_ISS + 1}.

%% The loop's invariant: a hint is armed no later than the step's earliest deadline.
assert_armed(Conn) ->
    {state, Tcb, _Socket, _Key, _Credit, _Owner, _Ref, _Active, _Mode, _Q, _N, _Held, _Eof,
     _Error, _Ended, _Told, _Finished, _Connect, _Recv, _Path, _Template, _Route, _Gen, _Rand, Armed,
     _Counters}
        = sys:get_state(Conn),
    case erx_tcp:next_deadline(Tcb) of
        infinity -> ok;
        Next -> ?assertMatch({At, _} when At =< Next, Armed)
    end,
    Tcb.

%% --- Cases -----------------------------------------------------------------------

%% A SYN nobody answers goes again when the retransmission timer the loop armed fires
%% (initial RTO 1 s), so the timer is armed and its hint is stepped.
syn_is_retransmitted_on_its_timer() ->
    {_Req, #tcp{seq = Iss, sport = Port}} = start_connect(),
    [{#tcp{flags = ?TH_SYN, seq = Again, sport = Port}, <<>>}] = segments(),
    ?assertEqual(Iss, Again).

connect_answers_once_established() ->
    #{conn := Conn, sock := Sock} = established(),
    ?assertMatch({'$inet', erx_gen_tcp, Conn}, Sock),
    ?assertEqual({ok, {{10, 0, 2, 2}, ?PEER_PORT}}, erx_gen_tcp:peername(Sock)),
    #tcb{state = established} = assert_armed(Conn).

%% Every item's unit comes back once the connection took the batch, so a peer's segments
%% never hold the credit after they were stepped.
credit_is_taken_as_items_arrive() ->
    #{conn := Conn, port := Port, snd := Snd, rcv := Rcv} = established(),
    [hand(Conn, Port, #{seq => Rcv + I * 100, ack => Snd, flags => ?TH_ACK}, binary:copy(<<"x">>, 100))
     || I <- lists:seq(0, 9)],
    _ = sys:get_state(Conn),
    [#{credit := Credit}] = erx_net_tables:demux(key(Port)),
    ?assertEqual(256, erx_net_credit:free(Credit)).

%% Five messages of one in-order segment each, queued while the connection is busy, are
%% stepped as one event (docs/design-network-fastpath.md, "One step per mailbox"): its one
%% output pass acknowledges all five in one ACK, where a step per message would acknowledge
%% every second segment and the fifth on the delayed-ACK timer, and each message's unit
%% comes back.
queued_items_are_stepped_once() ->
    #{conn := Conn, port := Port, snd := Snd, rcv := Rcv} = established(),
    ok = sys:suspend(Conn),
    [hand(Conn, Port, #{seq => Rcv + I * 100, ack => Snd, flags => ?TH_ACK}, binary:copy(<<"q">>, 100))
     || I <- lists:seq(0, 4)],
    ok = sys:resume(Conn),
    [{#tcp{flags = ?TH_ACK, ack = Acked}, <<>>}] = segments(),
    ?assertEqual(Rcv + 500, Acked),
    ?assertEqual(none, receive {transmit, _} -> another after 200 -> none end),
    [#{credit := Credit}] = erx_net_tables:demux(key(Port)),
    ?assertEqual(256, erx_net_credit:free(Credit)).

%% Bytes the owner has not read keep the window closed; reading them sends the update that
%% opens it again.
reading_opens_the_window() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    Data = binary:copy(<<"y">>, 60000),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH}, Data),
    [{#tcp{ack = Acked, win = Shut}, <<>>}] = segments(),
    ?assertEqual(Rcv + 60000, Acked),
    ?assert(Shut < 10000),
    ?assertEqual({ok, Data}, erx_gen_tcp:recv(Sock, 0, ?WAIT)),
    [{#tcp{win = Open}, <<>>}] = segments(),
    ?assert(Open > 60000).

%% Two recvs in a row for 64 KiB, the receive buffer's size before it is rounded up to
%% whole segments, each get exactly that, as on stock: the bytes a recv waits for leave the
%% buffer as they arrive, as FreeBSD's soreceive copies them out under MSG_WAITALL, so the
%% window reopens before the owner is answered. Counted against the buffer instead, they
%% would leave the last part of a segment free, which a sender's silly window avoidance
%% never fills but by persist probes. A recv longer than the buffer, which would hold more
%% than the buffer outside it, is refused.
recv_of_the_whole_buffer_completes() ->
    Shift = erx_tcp_output:request_r_scale(),
    #{conn := Conn, sock := Sock, rcv := Rcv} = C = established(#tcp_opts{mss = 1460, wscale = 0}),
    Stream = pattern(4 * 65536),
    First = gen_server:send_request(Conn, {recv, 65536, 2000}),
    _ = sys:get_state(Conn),
    {Reply1, Sent1, Edge1} = feed(C, First, Shift, Stream, 0, Rcv + 65536),
    ?assertEqual({ok, binary:part(Stream, 0, 65536)}, Reply1),
    Second = gen_server:send_request(Conn, {recv, 65536, 2000}),
    {Reply2, Sent, _} = feed(C, Second, Shift, Stream, Sent1, Edge1),
    ?assertEqual({ok, binary:part(Stream, 65536, 65536)}, Reply2),
    case Sent - 2 * 65536 of
        0 -> ok;
        More -> ?assertEqual({ok, binary:part(Stream, 2 * 65536, More)}, erx_gen_tcp:recv(Sock, 0, ?WAIT))
    end,
    #tcb{rcv_hiwat = Hiwat} = element(2, sys:get_state(Conn)),
    ?assertEqual({error, enomem}, erx_gen_tcp:recv(Sock, Hiwat + 1, 0)).

%% A recv that times out leaves what it held for the next one, as stock does. A later
%% take steps as read only what the buffer still counted, so the window keeps counting
%% what stays queued: the 30000 bytes held left the buffer once, and a recv of 40000 of
%% the 50000 bytes queued releases 10000 more, leaving 10000 counted, which the next
%% acknowledgement's window shows (the buffer is 64 KiB rounded up to whole segments).
recv_that_times_out_keeps_what_it_held() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    Data = pattern(51448),
    Req = gen_server:send_request(Conn, {recv, 65536, 100}),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 0, 30000)),
    ?assertEqual({reply, {error, timeout}}, gen_server:receive_response(Req, ?WAIT)),
    hand(Conn, Port, #{seq => Rcv + 30000, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 30000, 20000)),
    ?assertEqual({ok, binary:part(Data, 0, 40000)}, erx_gen_tcp:recv(Sock, 40000, ?WAIT)),
    hand(Conn, Port, #{seq => Rcv + 50000, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 50000, 1448)),
    #tcb{rcv_hiwat = Hiwat} = element(2, sys:get_state(Conn)),
    ?assertEqual(Hiwat - 10000 - 1448, window_acking(Rcv + 51448)),
    ?assertEqual({ok, binary:part(Data, 40000, 11448)}, erx_gen_tcp:recv(Sock, 0, ?WAIT)).

%% The window of the first segment the connection hands its driver that acknowledges Seq.
window_acking(Seq) ->
    case [Win || {#tcp{ack = Ack, win = Win}, _} <- segments(), Ack =:= Seq] of
        [Win | _] -> Win;
        [] -> window_acking(Seq)
    end.

%% Fewer bytes than a recv waits for when the peer's FIN comes: the recv answers
%% `{error, closed}`, as stock's does (inet_drv's tcp_recv_closed). Stock then discards the
%% bytes; the connection keeps them for a `recv(_, 0)`, after which it answers closed.
short_tail_at_the_fin_answers_closed_and_stays() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    Data = pattern(3000),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK}, Data),
    ?assertEqual({ok, binary:part(Data, 0, 1460)}, erx_gen_tcp:recv(Sock, 1460, ?WAIT)),
    ?assertEqual({ok, binary:part(Data, 1460, 1460)}, erx_gen_tcp:recv(Sock, 1460, ?WAIT)),
    Req = gen_server:send_request(Conn, {recv, 1460, ?WAIT}),
    _ = sys:get_state(Conn),
    hand(Conn, Port, #{seq => Rcv + 3000, ack => Snd, flags => ?TH_ACK bor ?TH_FIN}, <<>>),
    ?assertEqual({reply, {error, closed}}, gen_server:receive_response(Req, ?WAIT)),
    ?assertEqual({ok, binary:part(Data, 2920, 80)}, erx_gen_tcp:recv(Sock, 0, ?WAIT)),
    ?assertEqual({error, closed}, erx_gen_tcp:recv(Sock, 0, ?WAIT)).

%% The peer's side of a transfer: it sends Stream from offset Sent on in full segments of
%% 1448 bytes, an Ethernet MSS less timestamps, each only when it fits below the right edge
%% of the window the connection last advertised. That is a FreeBSD sender's silly window
%% avoidance while more data waits than the window takes: it sends no segment shorter than
%% the MSS into a window of 64 KiB, but for its persist probes, which come 5 s apart at the least. It stops once the recv Req is
%% answered or no segment fits for half a second, and returns the reply or `stalled`, the
%% bytes sent and the right edge.
feed(#{conn := Conn, port := Port, snd := Snd, rcv := Rcv} = C, Req, Shift, Stream, Sent, Edge) ->
    Size = min(1448, byte_size(Stream) - Sent),
    case gen_server:wait_response(Req, 0) of
        {reply, Reply} ->
            {Reply, Sent, Edge};
        timeout when Size > 0, Rcv + Sent + Size =< Edge ->
            hand(Conn, Port, #{seq => Rcv + Sent, ack => Snd, flags => ?TH_ACK},
                 binary:part(Stream, Sent, Size)),
            _ = sys:get_state(Conn),
            feed(C, Req, Shift, Stream, Sent + Size, right_edge(Edge, Shift, 0));
        timeout ->
            case right_edge(Edge, Shift, 500) of
                Edge -> {stalled, Sent, Edge};
                Further -> feed(C, Req, Shift, Stream, Sent, Further)
            end
    end.

%% The furthest right edge of the windows in the segments the connection has handed its
%% driver, waiting at most Wait ms for the first.
right_edge(Edge, Shift, Wait) ->
    receive
        {transmit, Frames} ->
            ok = erx_net_credit:take(get(tx), length(Frames)),
            Edges = [Ack + (Win bsl Shift) || F <- Frames,
                                              {#tcp{ack = Ack, win = Win}, _} <- [decode(iolist_to_binary(F))]],
            right_edge(lists:max([Edge | Edges]), Shift, 0)
    after Wait -> Edge
    end.

pattern(N) ->
    << <<(I rem 251)>> || I <- lists:seq(0, N - 1) >>.

rst_ends_the_connection_and_its_entry() ->
    #{conn := Conn, port := Port, sock := Sock, rcv := Rcv} = established(),
    Ref = monitor(process, Conn),
    Self = self(),
    Reader = spawn(fun() -> Self ! {read, erx_gen_tcp:recv(Sock, 0, ?WAIT)} end),
    _ = sys:get_state(Conn),
    hand(Conn, Port, #{seq => Rcv, flags => ?TH_RST}, <<>>),
    receive {'DOWN', Ref, process, Conn, normal} -> ok after ?WAIT -> error(still_running) end,
    receive {read, Read} -> ?assertEqual({error, econnreset}, Read) after ?WAIT -> error(Reader) end,
    ?assertEqual([], erx_net_tables:demux(key(Port))),
    ?assertEqual({error, closed}, erx_gen_tcp:recv(Sock, 0, 0)).

%% Our FIN, the peer's ACK and FIN, our ACK: TIME-WAIT, whose 2MSL deadline is armed.
close_reaches_time_wait_with_its_timer() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    ok = erx_gen_tcp:close(Sock),
    [{#tcp{flags = Fin, seq = Snd}, <<>>}] = segments(),
    ?assert(Fin band ?TH_FIN =/= 0),
    hand(Conn, Port, #{seq => Rcv, ack => Snd + 1, flags => ?TH_ACK bor ?TH_FIN}, <<>>),
    [{#tcp{flags = ?TH_ACK, ack = Ack}, <<>>}] = segments(),
    ?assertEqual(Rcv + 1, Ack),
    #tcb{state = time_wait} = assert_armed(Conn).

%% A connection that dies before it answers still leaves no connect caller waiting: its
%% grant, which the death reaches by the link, answers in its place.
connect_is_answered_when_the_connection_dies() ->
    {Req, #tcp{sport = Port}} = start_connect(),
    [{_, Conn, _}] = ets:lookup(erx_net_demux, key(Port)),
    exit(Conn, kill),
    ?assertEqual({reply, {error, closed}}, gen_server:receive_response(Req, ?WAIT)).
