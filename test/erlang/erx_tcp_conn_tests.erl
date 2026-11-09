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
ending the process and its entry, and a close through TIME-WAIT.
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
      {"reading opens the window", fun reading_opens_the_window/0},
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
              mtu => 1500, mtu6 => 1500, hlim => 64, driver => Me, driver_credit => Tx,
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

%% The handshake: SYN out, SYN-ACK in, connect answered, ACK out.
established() ->
    {Req, #tcp{sport = Port, seq = Iss}} = start_connect(),
    [{_, Conn, _}] = ets:lookup(erx_net_demux, key(Port)),
    hand(Conn, Port, #{seq => ?PEER_ISS, ack => Iss + 1, flags => ?TH_SYN bor ?TH_ACK,
                       opts => #tcp_opts{mss = 1460}}, <<>>),
    {reply, {ok, Sock}} = gen_server:receive_response(Req, ?WAIT),
    [{#tcp{flags = ?TH_ACK, ack = Ack}, <<>>}] = segments(),
    ?assertEqual(?PEER_ISS + 1, Ack),
    #{sock => Sock, conn => Conn, port => Port, snd => Iss + 1, rcv => ?PEER_ISS + 1}.

%% The loop's invariant: a hint is armed no later than the step's earliest deadline.
assert_armed(Conn) ->
    {state, Tcb, _Socket, _Key, _Credit, _Owner, _Ref, _Active, _Mode, _Q, _N, _Eof, _Error,
     _Ended, _Told, _Finished, _Connect, _Recv, _Path, _Route, _Gen, _Rand, Armed, _Counters}
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
