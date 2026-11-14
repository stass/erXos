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
ending the process and its entry, a close through TIME-WAIT. Each connection is opened
through its socket process (erx_gen_tcp), owned by the test, so they also check the socket
protocol end to end: the recv results stock gen_tcp gives (a recv longer than the buffer
completes, a timed-out recv keeps its bytes, a short tail at the peer's FIN answers
closed), active-mode delivery to the owner as stock `{tcp, S, Data}`, and a request in
the envelope of a domain that is not the grantee's dropped and counted.
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
      {"a read sends its window update", fun a_read_sends_its_window_update/0},
      {"a recv of the whole buffer completes", fun recv_of_the_whole_buffer_completes/0},
      {"a recv that times out keeps what it held", fun recv_that_times_out_keeps_what_it_held/0},
      {"a short tail at the FIN answers closed and stays",
       fun short_tail_at_the_fin_answers_closed_and_stays/0},
      {"a RST ends the connection", fun rst_ends_the_connection_and_its_entry/0},
      {"active mode delivers to the owner", fun active_mode_delivers_to_the_owner/0},
      {"another domain's envelope is dropped and counted",
       fun a_non_grantee_envelope_is_dropped_and_counted/0},
      {"close runs FIN both ways into TIME-WAIT", fun close_reaches_time_wait_with_its_timer/0},
      {"buffers are reserved at the grant", fun buffers_are_reserved_at_the_grant/0},
      {"short connections give their buffers back",
       fun short_connections_give_their_buffers_back/0},
      {"an open socket in TIME-WAIT keeps its buffers",
       fun an_open_socket_in_time_wait_keeps_its_buffers/0}]].

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

%% Starts a connect through a socket process owned by the test process, and returns its
%% request, its SYN and the socket process.
start_connect() ->
    start_connect([binary, {active, false}]).

start_connect(Opts) ->
    {ok, SockProc} = gen_statem:start(erx_gen_tcp, self(), []),
    Req = gen_statem:send_request(SockProc, connect_request(Opts)),
    [{#tcp{flags = ?TH_SYN} = Syn, <<>>}] = segments(),
    put(sock_proc, SockProc),
    {Req, Syn}.

%% The handshake: SYN out, SYN-ACK in, connect answered, ACK out. The SYN-ACK's options
%% decide whether the connection scales its window.
established() ->
    established(#tcp_opts{mss = 1460}).

established(SynAckOpts) ->
    established(SynAckOpts, [binary, {active, false}]).

established(SynAckOpts, Opts) ->
    {Req, #tcp{sport = Port, seq = Iss}} = start_connect(Opts),
    [{_, Conn, _}] = ets:lookup(erx_net_demux, key(Port)),
    hand(Conn, Port, #{seq => ?PEER_ISS, ack => Iss + 1, flags => ?TH_SYN bor ?TH_ACK,
                       opts => SynAckOpts}, <<>>),
    {reply, ok} = gen_statem:receive_response(Req, ?WAIT),
    Sock = {'$inet', erx_gen_tcp, get(sock_proc)},
    [{#tcp{flags = ?TH_ACK, ack = Ack}, <<>>}] = segments(),
    ?assertEqual(?PEER_ISS + 1, Ack),
    #{sock => Sock, conn => Conn, port => Port, snd => Iss + 1, rcv => ?PEER_ISS + 1}.

%% The loop's invariant: a hint is armed no later than the step's earliest deadline.
assert_armed(Conn) ->
    State = sys:get_state(Conn),
    {Tcb, Armed} = {element(2, State), element(tuple_size(State) - 1, State)},
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
    {'$inet', erx_gen_tcp, SockProc} = Sock,
    ?assertNotEqual(Conn, SockProc),
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

%% Bytes past what the passive socket process holds, its target of 64 KiB, stay in the
%% receive buffer and keep the window closed; reading them grants credit again, and the
%% connection pushes them and sends the update that opens the window.
reading_opens_the_window() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    Data = pattern(120000),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH}, binary:part(Data, 0, 60000)),
    _ = window_acking(Rcv + 60000),
    hand(Conn, Port, #{seq => Rcv + 60000, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 60000, 60000)),
    ?assert(window_acking(Rcv + 120000) < 20000),
    ?assertEqual({ok, binary:part(Data, 0, 65536)}, erx_gen_tcp:recv(Sock, 0, ?WAIT)),
    window_opens_past(Rcv + 120000, 60000),
    ?assertEqual({ok, binary:part(Data, 65536, 120000 - 65536)}, erx_gen_tcp:recv(Sock, 0, ?WAIT)).

%% The window update a read makes due goes with the read, as FreeBSD's tcp_usr_rcvd calls
%% tcp_output. Once the full buffer is acknowledged, the clock hint the connection armed
%% earlier is waited out, and no deadline is left within the wait: only the read's own step
%% can send the update.
a_read_sends_its_window_update() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    Data = pattern(120000),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH}, binary:part(Data, 0, 60000)),
    _ = window_acking(Rcv + 60000),
    hand(Conn, Port, #{seq => Rcv + 60000, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 60000, 60000)),
    ?assert(window_acking(Rcv + 120000) < 20000),
    nothing_due_within(Conn, 2 * ?WAIT),
    ?assertEqual({ok, binary:part(Data, 0, 65536)}, erx_gen_tcp:recv(Sock, 0, ?WAIT)),
    ?assert(window_opens_past(Rcv + 120000, 60000) > 60000).

%% Waits until neither a deadline of the connection nor its armed clock hint, which can be
%% earlier than any deadline left, falls within the next Ms milliseconds.
nothing_due_within(Conn, Ms) ->
    State = sys:get_state(Conn),
    Hint = case element(tuple_size(State) - 1, State) of
               infinity -> infinity;
               {At, _Timer} -> At
           end,
    Limit = erx_net_clock:now() + Ms * 1000,
    case erx_tcp:next_deadline(element(2, State)) > Limit andalso Hint > Limit of
        true -> ok;
        false -> timer:sleep(100), nothing_due_within(Conn, Ms)
    end.

%% A recv for 64 KiB, the receive buffer's size before it is rounded up to whole segments,
%% then one for twice that, each get exactly that, as on stock: the bytes a recv waits for
%% leave the buffer as they arrive, pushed to the socket process, which grants the credit
%% the recv's length needs, as FreeBSD's soreceive copies them out under MSG_WAITALL. Held
%% in the buffer instead, they would leave the last part of a segment free, which a
%% sender's silly window avoidance never fills but by persist probes. A recv past stock's
%% 64 MiB is refused.
recv_of_the_whole_buffer_completes() ->
    Shift = erx_tcp_output:request_r_scale(),
    #{sock := Sock, rcv := Rcv} = C = established(#tcp_opts{mss = 1460, wscale = 0}),
    {'$inet', erx_gen_tcp, SockProc} = Sock,
    Stream = pattern(4 * 65536),
    First = gen_statem:send_request(SockProc, {recv, 65536, 2000}),
    _ = sys:get_state(SockProc),
    {Reply1, Sent1, Edge1} = feed(C, First, Shift, Stream, 0, Rcv + 65536),
    ?assertEqual({ok, binary:part(Stream, 0, 65536)}, Reply1),
    Second = gen_statem:send_request(SockProc, {recv, 2 * 65536, 2000}),
    {Reply2, Sent, _} = feed(C, Second, Shift, Stream, Sent1, Edge1),
    ?assertEqual({ok, binary:part(Stream, 65536, 2 * 65536)}, Reply2),
    case Sent - 3 * 65536 of
        0 -> ok;
        More -> ?assertEqual({ok, binary:part(Stream, 3 * 65536, More)}, erx_gen_tcp:recv(Sock, 0, ?WAIT))
    end,
    ?assertEqual({error, enomem}, erx_gen_tcp:recv(Sock, 64 * 1024 * 1024 + 1, 0)).

%% A recv that times out leaves what it held for the next one, as stock does: the 30000
%% bytes it waited with are the first of the next recv's 40000, and the rest stays for a
%% recv of what is there.
recv_that_times_out_keeps_what_it_held() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    {'$inet', erx_gen_tcp, SockProc} = Sock,
    Data = pattern(51448),
    Req = gen_statem:send_request(SockProc, {recv, 65536, 100}),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 0, 30000)),
    ?assertEqual({reply, {error, timeout}}, gen_statem:receive_response(Req, ?WAIT)),
    hand(Conn, Port, #{seq => Rcv + 30000, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 30000, 20000)),
    ?assertEqual({ok, binary:part(Data, 0, 40000)}, erx_gen_tcp:recv(Sock, 40000, ?WAIT)),
    hand(Conn, Port, #{seq => Rcv + 50000, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH},
         binary:part(Data, 50000, 1448)),
    _ = sys:get_state(Conn),
    ?assertEqual({ok, binary:part(Data, 40000, 11448)}, erx_gen_tcp:recv(Sock, 11448, ?WAIT)).

%% Fewer bytes than a recv waits for when the peer's FIN comes: the recv answers
%% `{error, closed}` and the bytes are discarded, as stock's does (inet_drv's
%% tcp_recv_closed), and the next recv answers `{error, enotconn}`.
short_tail_at_the_fin_answers_closed_and_stays() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
    Data = pattern(3000),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK}, Data),
    ?assertEqual({ok, binary:part(Data, 0, 1460)}, erx_gen_tcp:recv(Sock, 1460, ?WAIT)),
    ?assertEqual({ok, binary:part(Data, 1460, 1460)}, erx_gen_tcp:recv(Sock, 1460, ?WAIT)),
    {'$inet', erx_gen_tcp, SockProc} = Sock,
    Req = gen_statem:send_request(SockProc, {recv, 1460, ?WAIT}),
    _ = sys:get_state(SockProc),
    hand(Conn, Port, #{seq => Rcv + 3000, ack => Snd, flags => ?TH_ACK bor ?TH_FIN}, <<>>),
    ?assertEqual({reply, {error, closed}}, gen_statem:receive_response(Req, ?WAIT)),
    ?assertEqual({error, enotconn}, erx_gen_tcp:recv(Sock, 0, ?WAIT)).

%% The peer's side of a transfer: it sends Stream from offset Sent on in full segments of
%% 1448 bytes, an Ethernet MSS less timestamps, each only when it fits below the right edge
%% of the window the connection last advertised. That is a FreeBSD sender's silly window
%% avoidance while more data waits than the window takes: it sends no segment shorter than
%% the MSS into a window of 64 KiB, but for its persist probes, which come 5 s apart at the least. It stops once the recv Req is
%% answered or no segment fits for half a second, and returns the reply or `stalled`, the
%% bytes sent and the right edge.
feed(#{conn := Conn, port := Port, snd := Snd, rcv := Rcv} = C, Req, Shift, Stream, Sent, Edge) ->
    Size = min(1448, byte_size(Stream) - Sent),
    case gen_statem:wait_response(Req, 0) of
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

%% The window of the first segment the connection hands its driver that acknowledges Seq,
%% skipping those before it.
window_acking(Seq) ->
    case [Win || {#tcp{ack = Ack, win = Win}, _} <- segments(), Ack =:= Seq] of
        [Win | _] -> Win;
        [] -> window_acking(Seq)
    end.

%% Waits for a segment acknowledging Seq whose window is past Min, and returns that window;
%% earlier updates, sent before the bytes left the receive buffer, are passed over.
window_opens_past(Seq, Min) ->
    case [Win || {#tcp{ack = Ack, win = Win}, _} <- segments(), Ack =:= Seq, Win > Min] of
        [Win | _] -> Win;
        [] -> window_opens_past(Seq, Min)
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
    %% The recv after the one that met the end, as stock's after tcp_recv_error.
    ?assertEqual({error, enotconn}, erx_gen_tcp:recv(Sock, 0, 0)).

%% In active mode the owner receives stock's messages, built by the socket process with
%% the socket term: the data, then at the peer's FIN `{tcp_closed, S}`.
active_mode_delivers_to_the_owner() ->
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} =
        established(#tcp_opts{mss = 1460}, [binary, {active, true}]),
    hand(Conn, Port, #{seq => Rcv, ack => Snd, flags => ?TH_ACK bor ?TH_PUSH}, <<"hello">>),
    receive {tcp, Sock, Data} -> ?assertEqual(<<"hello">>, Data) after ?WAIT -> error(no_data) end,
    hand(Conn, Port, #{seq => Rcv + 5, ack => Snd, flags => ?TH_ACK bor ?TH_FIN}, <<>>),
    receive {tcp_closed, Sock} -> ok after ?WAIT -> error(no_close) end.

%% A request in the envelope of a domain that is not the grantee's, which is `local`
%% here, names the socket process as its sender but is not its: the connection drops it,
%% answers no one and counts it, and the socket goes on.
a_non_grantee_envelope_is_dropped_and_counted() ->
    #{conn := Conn, sock := Sock} = established(),
    {'$inet', erx_gen_tcp, SockProc} = Sock,
    Conn ! {erx_origin, 7, {erx_net, SockProc, {call, 900, peername}}},
    Conn ! {erx_net, self(), {call, 901, peername}},
    Counters = element(tuple_size(sys:get_state(Conn)), sys:get_state(Conn)),
    ?assertEqual(2, maps:get(unknown, Counters, 0)),
    ?assertEqual({ok, {{10, 0, 2, 2}, ?PEER_PORT}}, erx_gen_tcp:peername(Sock)),
    receive {erx_net, Conn, Stray} -> error({answered, Stray}) after 0 -> ok end.

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

%% The grant reserves a connection's buffers (docs/design-network-stack.md, "Sockets act for
%% one domain"): with room for only the initial ones, tcp_mss's rounding up to whole segments
%% is refused and leaves them as they were, a second connect is refused with ENOBUFS, an
%% `EXIT` message naming the live connection frees nothing, and the first connection's
%% real exit gives its reservation back.
buffers_are_reserved_at_the_grant() ->
    Initial = 32768 + 65536,
    Grant = restart_grant(#{buffers => Initial}),
    try
        #{conn := Conn} = established(),
        #tcb{snd_hiwat = Snd, rcv_hiwat = Rcv} = element(2, sys:get_state(Conn)),
        ?assertEqual({32768, 65536}, {Snd, Rcv}),
        %% An exit in the name of a connection still alive frees nothing.
        Grant ! {'EXIT', Conn, normal},
        ?assertEqual({error, enobufs}, refused_connect()),
        Ref = monitor(process, Conn),
        exit(Conn, kill),
        receive {'DOWN', Ref, _, _, _} -> ok end,
        _ = sys:get_state(Grant),
        {_, #tcp{flags = ?TH_SYN}} = start_connect()
    after
        unlink(Grant),
        exit(Grant, kill)
    end.

%% The setup's grant replaced by one with Limits, under the same name.
restart_grant(Limits) ->
    Old = whereis(erx_net_grant),
    Ref = monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, Grant} = erx_net_grant:start_link(local, Limits),
    Grant.

%% Short connections, each closed by its owner into TIME-WAIT, give their buffers back as
%% they reach it: a grant with room for one connection's buffers takes connection after
%% connection, though each closed one waits out 2MSL.
short_connections_give_their_buffers_back() ->
    Grant = restart_grant(#{buffers => 32768 + 65536}),
    try
        [begin
             #{conn := Conn} = closed_into_time_wait(),
             _ = sys:get_state(Conn)
         end || _ <- lists:seq(1, 3)],
        {_, #tcp{flags = ?TH_SYN}} = start_connect()
    after
        unlink(Grant),
        exit(Grant, kill)
    end.

%% A connection in TIME-WAIT whose owner still holds the socket, with the peer's bytes not
%% yet read, keeps its buffers; the owner's close gives them back.
an_open_socket_in_time_wait_keeps_its_buffers() ->
    Grant = restart_grant(#{buffers => 32768 + 65536}),
    try
        #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = established(),
        ok = erx_gen_tcp:shutdown(Sock, write),
        [{#tcp{flags = Fin, seq = Snd}, <<>>}] = segments(),
        ?assert(Fin band ?TH_FIN =/= 0),
        hand(Conn, Port, #{seq => Rcv, ack => Snd + 1, flags => ?TH_ACK bor ?TH_FIN bor ?TH_PUSH},
             <<"hello">>),
        [{#tcp{flags = ?TH_ACK, ack = Ack}, <<>>}] = segments(),
        ?assertEqual(Rcv + 6, Ack),
        #tcb{state = time_wait} = element(2, sys:get_state(Conn)),
        ?assertEqual({error, enobufs}, refused_connect()),
        ok = erx_gen_tcp:close(Sock),
        _ = sys:get_state(Conn),
        {_, #tcp{flags = ?TH_SYN}} = start_connect()
    after
        unlink(Grant),
        exit(Grant, kill)
    end.

%% An established connection closed by its owner: our FIN, the peer's ACK and FIN, our ACK.
closed_into_time_wait() ->
    Established = established(),
    #{conn := Conn, port := Port, sock := Sock, snd := Snd, rcv := Rcv} = Established,
    ok = erx_gen_tcp:close(Sock),
    [{#tcp{flags = Fin, seq = Snd}, <<>>}] = segments(),
    ?assert(Fin band ?TH_FIN =/= 0),
    hand(Conn, Port, #{seq => Rcv, ack => Snd + 1, flags => ?TH_ACK bor ?TH_FIN}, <<>>),
    [{#tcp{flags = ?TH_ACK}, <<>>}] = segments(),
    Established.

%% The answer to a connect the grant cannot start.
refused_connect() ->
    {ok, SockProc} = gen_statem:start(erx_gen_tcp, self(), []),
    Req = gen_statem:send_request(SockProc, connect_request([binary, {active, false}])),
    {reply, Reply} = gen_statem:receive_response(Req, ?WAIT),
    Reply.

%% The socket process's open call for a connect to the peer with gen_tcp's options Opts,
%% as erx_gen_tcp:connect/4 makes it.
connect_request(Opts) ->
    {ok, Own, Fwd} = erx_gen_tcp_core:options(Opts, #{mode => list, active => true}),
    {open, {tcp_connect, inet, {10, 0, 2, 2}, ?PEER_PORT, Fwd, 10000}, Own}.

%% A connection that dies before it answers still leaves no connect caller waiting: its
%% grant, which the death reaches by the link, answers in its place.
connect_is_answered_when_the_connection_dies() ->
    {Req, #tcp{sport = Port}} = start_connect(),
    [{_, Conn, _}] = ets:lookup(erx_net_demux, key(Port)),
    exit(Conn, kill),
    ?assertEqual({reply, {error, closed}}, gen_statem:receive_response(Req, ?WAIT)).
