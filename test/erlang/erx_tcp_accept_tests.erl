%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tcp_accept_tests).
-moduledoc """
An accepted connection's start and its queued phase (docs/design-network-stack.md, "A
connection from the syncache", "The listener"), with the test process standing in for the
interface that calls erx_tcp_conn:accept/1, its driver, the listener whose entry it is and
the socket process an accept binds the connection to. The cases check that the accept unit
has one holder at a time: kept by a queued connection, released at `abandon` and at a
refused adoption, which hands the interface its RST; that a queued connection pushes nothing
and keeps the peer's bytes until its socket process's first message; that its
listener's exit aborts it with a RST; that a `bind` from any process but its listener, or a
second one, ends it; that a `bind` to a socket process already gone aborts it with a
RST and an end at once; and that the segment completing the handshake is its first event,
so it sends the peer no second SYN-ACK, and sees the receive buffer rounded to the MSS.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_tcp.hrl").

-define(OURS, <<10, 0, 2, 15>>).
-define(PEER, <<10, 0, 2, 2>>).
-define(PORT, 80).
-define(PEER_PORT, 7777).
-define(CONN, {?OURS, ?PORT, ?PEER, ?PEER_PORT}).
-define(KEY, {tcp, inet, ?OURS, ?PORT, ?PEER, ?PEER_PORT}).
-define(ISS, 1000).
-define(IRS, 5000).
-define(WAIT, 3000).

accept_test_() ->
    [{Name, fun() -> Setup = setup(), try Case() after cleanup(Setup) end end}
     || {Name, Case} <-
     [{"a queued connection keeps its unit and its bytes until the first contact",
       fun queued_connection_waits_for_the_first_contact/0},
      {"a held four-tuple makes the connection abandon and release its unit",
       fun abandon_releases_the_unit/0},
      {"a refused adoption releases the unit and hands the interface its RST",
       fun refused_adoption_resets/0},
      {"a grant at its sockets limit refuses the adoption, which resets the connection",
       fun sockets_limit_resets/0},
      {"a grant without room for the rounded buffers refuses the adoption",
       fun rounded_buffers_past_the_limit_reset/0},
      {"the listener's exit aborts a queued connection with a RST",
       fun listener_exit_aborts_a_queued_connection/0},
      {"a full accept credit starts nothing", fun full_credit_starts_nothing/0},
      {"a bind that does not name its listener ends the connection",
       fun bind_from_another_process_ends_the_connection/0},
      {"a second bind ends the connection", fun second_bind_ends_the_connection/0},
      {"a bind to a socket process already gone sends no bound and aborts",
       fun bind_to_a_gone_socket_process_aborts/0},
      {"the completing segment is the first step, so no second SYN-ACK goes out",
       fun no_second_syn_ack/0},
      {"the completing segment's ACK advertises the receive buffer rounded to the MSS",
       fun completing_segment_sees_the_rounded_buffer/0}]].

%% --- The stand-ins ---------------------------------------------------------------

setup() ->
    %% The connections link to the test process as listener and owner; their exits during
    %% a case must not end it. cleanup/1 keeps their exits at the cleanup from ending it.
    process_flag(trap_exit, true),
    ok = persistent_term:put({erx_net_sup, runtime}, erx_net_local),
    {ok, Tables} = erx_net_tables:start_link(),
    unlink(Tables),
    Me = self(),
    Iface = #{name => en0, pid => Me, link => ethernet, lladdr => <<2, 0, 0, 0, 0, 1>>,
              mtu => 1500, mtu6 => 1500, hlim => 64, finish => none,
              driver => Me, driver_credit => erx_net_credit:new(256),
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
    {Tables, Grant}.

%% Every connection still running is linked to its grant, which it links first, and those
%% a case queued on the test process are linked to it as listener or owner. The cleanup
%% kills them with the grant and the tables and waits for each one's DOWN before the test
%% process stops trapping exits. A dying process sends its link exits before its DOWNs, so
%% by then each exit signal is a message for flush/0. One that arrived after trapping
%% stopped would kill the test process and cancel the cases after it, a seeded fault's
%% failing case among them.
cleanup({Tables, _Grant}) ->
    Grant = whereis(erx_net_grant),
    Procs = [P || P <- [Tables, Grant | linked(Grant)], is_pid(P), P =/= self()],
    Refs = [monitor(process, P) || P <- Procs],
    [exit(P, kill) || P <- Procs],
    [receive {'DOWN', Ref, _, _, _} -> ok end || Ref <- Refs],
    flush(),
    process_flag(trap_exit, false).

linked(Pid) when is_pid(Pid) ->
    case process_info(Pid, links) of
        {links, Links} -> Links;
        undefined -> []
    end;
linked(undefined) -> [].

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% What the interface hands accept/1 for a handshake completed by an ACK carrying Payload,
%% for a listener Listener whose accept credit is Unit.
accept(Listener, Unit, Payload) ->
    Entry = #{pid => Listener, credit => Unit, grant => whereis(erx_net_grant), origin => local,
              accept => #{cc => erx_tcp_cc_cubic, loss => erx_tcp_loss_dupack,
                          snd_hiwat => 32768, rcv_hiwat => 65536}},
    Handshake = #{iss => ?ISS, irs => ?IRS, rcv_wnd => 65535, peer_mss => 1460, wscale => none,
                  sack => false, ts => none, ecn => false, rxmits => 0, challenge => none},
    Ack = #tcp{sport = ?PEER_PORT, dport = ?PORT, seq = ?IRS + 1, ack = ?ISS + 1,
               flags = ?TH_ACK, win = 65535, urp = 0},
    #{entry => Entry, conn => ?CONN, handshake => Handshake, segment => {Ack, Payload, 0, unicast},
      gen => erx_net_rand:new(<<9:128>>), interface => self(), sender => erx_net_credit:new(16)}.

%% Waits until the accept credit has Free units free.
await_free(Unit, Free) -> await_free(Unit, Free, 300).
await_free(Unit, Free, 0) -> ?assertEqual(Free, erx_net_credit:free(Unit));
await_free(Unit, Free, N) ->
    case erx_net_credit:free(Unit) of
        Free -> ok;
        _ -> receive after 10 -> await_free(Unit, Free, N - 1) end
    end.

%% A listener standing in its own process, so that its exit can be planted; it hands the
%% test what it takes.
listener() ->
    Test = self(),
    spawn(fun Loop() -> receive Msg -> Test ! {listener, Msg}, Loop() end end).

%% --- Cases -----------------------------------------------------------------------

%% The control block starts in SYN-RECEIVED, whose output carries SYN and ACK
%% (tcp_output.c:432-443, :700-702), and every step ends in output. So its first event is
%% the segment that completed the handshake, as tcp_input hands that segment to
%% tcp_do_segment straight after syncache_expand (tcp_input.c:1081-1160), and nothing is
%% stepped before it. A pure ACK completes this handshake: the connection is established
%% at the sizes accepted/3 rounds to the MSS, 23 and 45 segments of 1460 bytes, and has
%% sent nothing.
no_second_syn_ack() ->
    Conn = queued(),
    #tcb{state = State, snd_hiwat = Snd, rcv_hiwat = Rcv} = element(2, sys:get_state(Conn)),
    ?assertEqual({established, 33580, 65700}, {State, Snd, Rcv}),
    ?assertEqual(none, receive {transmit, Frames} -> [decode(iolist_to_binary(F)) || F <- Frames]
                       after 200 -> none end).

%% syncache_socket reserves the buffers tcp_mss rounds to the MSS before tcp_input hands the
%% completing segment to tcp_do_segment (tcp_syncache.c:938, tcp_input.c:1081-1160), so that
%% segment sees the rounded receive buffer. Here it carries 1000 bytes and a FIN, whose ACK
%% goes out in the same step: its window is the rounded 65700 bytes less the 1000 held, not
%% the listener's 65536 less them.
completing_segment_sees_the_rounded_buffer() ->
    Unit = erx_net_credit:new(2),
    #{segment := {Ack, <<>>, Ecn, Cast}} = Accept = accept(self(), Unit, <<>>),
    Fin = Ack#tcp{flags = ?TH_ACK bor ?TH_FIN},
    ok = erx_tcp_conn:accept(Accept#{segment := {Fin, binary:copy(<<"x">>, 1000), Ecn, Cast}}),
    receive {queued, _} -> ok after ?WAIT -> error(not_queued) end,
    receive
        {transmit, [Frame | _]} ->
            {#tcp{flags = Flags, win = Win}, <<>>} = decode(iolist_to_binary(Frame)),
            ?assertEqual({?TH_ACK, 65700 - 1000}, {Flags, Win})
    after ?WAIT -> error(no_ack)
    end.

queued_connection_waits_for_the_first_contact() ->
    Unit = erx_net_credit:new(2),
    ok = erx_tcp_conn:accept(accept(self(), Unit, <<"hello">>)),
    Conn = receive {queued, C} -> C after ?WAIT -> error(not_queued) end,
    %% The notice carries the unit: still reserved, now the listener's.
    ?assertEqual(1, erx_net_credit:free(Unit)),
    ?assertMatch([#{pid := Conn}], erx_net_tables:demux(?KEY)),
    #{owner := {listener, _}} = owner(Conn),
    Conn ! {bind, self(), self()},
    receive {bound, Conn} -> ok after ?WAIT -> error(not_bound) end,
    %% Bound, but nothing crosses before the socket process's first message.
    receive {erx_net, Conn, Early} -> error({pushed_before_contact, Early}) after 100 -> ok end,
    Conn ! {erx_net, self(), {credit, 65536}},
    receive {erx_net, Conn, {data, Data}} -> ?assertEqual(<<"hello">>, iolist_to_binary(Data))
    after ?WAIT -> error(no_data)
    end,
    #{owner := Me} = owner(Conn),
    ?assertEqual(self(), Me).

abandon_releases_the_unit() ->
    Holder = spawn(fun() -> receive stop -> ok end end),
    ok = erx_net_bind:insert(?KEY, Holder, #{pid => Holder, credit => none, grant => Holder}),
    Unit = erx_net_credit:new(2),
    ok = erx_tcp_conn:accept(accept(self(), Unit, <<>>)),
    await_free(Unit, 2),
    receive {queued, _} -> error(queued) after 100 -> ok end,
    %% The key stays its holder's.
    ?assertMatch([#{pid := Holder}], erx_net_tables:demux(?KEY)),
    Holder ! stop.

refused_adoption_resets() ->
    refused_adoption_resets(#{buffers => 0}).

%% Decision 20: a connection past its grant's sockets limit is counted nowhere and reset at
%% its handshake, so accept never answers emfile.
sockets_limit_resets() ->
    refused_adoption_resets(#{sockets => 0}).

%% The grant reserves the buffers rounded to the MSS at the adoption, 33580 and 65700 bytes:
%% a grant with room for the listener's 32768 and 65536 but not for those refuses the
%% connection, where FreeBSD ignores the failed sbreserve in tcp_mss (tcp_input.c:3935,
%% :3968) and keeps the listener's sizes.
rounded_buffers_past_the_limit_reset() ->
    refused_adoption_resets(#{buffers => 32768 + 65536}).

%% A grant of Limits that refuses the adoption: the connection releases its unit, hands the
%% interface the RST, deletes its key and is never queued.
refused_adoption_resets(Limits) ->
    Old = whereis(erx_net_grant),
    Ref = monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, Grant} = erx_net_grant:start_link(local, Limits),
    unlink(Grant),
    Unit = erx_net_credit:new(2),
    #{sender := Sender} = Accept = accept(self(), Unit, <<>>),
    ok = erx_tcp_conn:accept(Accept),
    receive
        {accept_refused, ?CONN, {#tcp{seq = Seq}, <<>>, 0, unicast}} -> ?assertEqual(?IRS + 1, Seq)
    after ?WAIT -> error(no_refusal)
    end,
    ?assertEqual(15, erx_net_credit:free(Sender)),
    await_free(Unit, 2),
    receive {queued, _} -> error(queued) after 100 -> ok end,
    ?assertEqual([], erx_net_tables:demux(?KEY)).

listener_exit_aborts_a_queued_connection() ->
    Listener = listener(),
    Unit = erx_net_credit:new(2),
    ok = erx_tcp_conn:accept(accept(Listener, Unit, <<>>)),
    Conn = receive {listener, {queued, C}} -> C after ?WAIT -> error(not_queued) end,
    Ref = monitor(process, Conn),
    exit(Listener, kill),
    await_rst(),
    receive {'DOWN', Ref, process, Conn, normal} -> ok after ?WAIT -> error(still_running) end,
    ?assertEqual([], erx_net_tables:demux(?KEY)).

full_credit_starts_nothing() ->
    Unit = erx_net_credit:new(1),
    ok = erx_net_credit:reserve(Unit, 1),
    ?assertEqual(full, erx_tcp_conn:accept(accept(self(), Unit, <<>>))),
    ?assertEqual([], erx_net_tables:demux(?KEY)).

bind_from_another_process_ends_the_connection() ->
    Conn = queued(),
    Ref = monitor(process, Conn),
    Other = spawn(fun() -> receive stop -> ok end end),
    Conn ! {bind, Other, self()},
    receive {'DOWN', Ref, process, Conn, Reason} -> ?assertMatch({unexpected, {bind, _, _}}, Reason)
    after ?WAIT -> error(still_running)
    end,
    receive {bound, Conn} -> error(bound) after 0 -> ok end,
    Other ! stop.

second_bind_ends_the_connection() ->
    Conn = queued(),
    Ref = monitor(process, Conn),
    Conn ! {bind, self(), self()},
    receive {bound, Conn} -> ok after ?WAIT -> error(not_bound) end,
    Conn ! {bind, self(), self()},
    receive {'DOWN', Ref, process, Conn, Reason} -> ?assertMatch({unexpected, {bind, _, _}}, Reason)
    after ?WAIT -> error(still_running)
    end.

%% The socket process an accept names has ended before the bind: the connection's link
%% meets `noproc`, so it answers nothing and aborts, a RST and its end at once, and its
%% listener answers the accept `{error, econnaborted}` at that end, not after a graceful
%% close has run its course.
bind_to_a_gone_socket_process_aborts() ->
    Conn = queued(),
    ConnRef = monitor(process, Conn),
    Gone = spawn(fun() -> ok end),
    Ref = monitor(process, Gone),
    receive {'DOWN', Ref, process, Gone, _} -> ok end,
    Conn ! {bind, self(), Gone},
    await_rst(),
    receive {'DOWN', ConnRef, process, Conn, normal} -> ok after ?WAIT -> error(still_running) end,
    receive {bound, Conn} -> error(bound) after 0 -> ok end,
    ?assertEqual([], erx_net_tables:demux(?KEY)).

%% A connection queued on the test process as its listener, with its unit.
queued() ->
    Unit = erx_net_credit:new(2),
    ok = erx_tcp_conn:accept(accept(self(), Unit, <<>>)),
    receive {queued, C} -> C after ?WAIT -> error(not_queued) end.

%% Waits for the RST the connection hands the driver, past the ACKs before it.
await_rst() -> await_flag(?TH_RST).

%% Waits for a segment carrying Flag among the frames the connection hands the driver.
await_flag(Flag) ->
    receive
        {transmit, Frames} ->
            Flags = [Tcp#tcp.flags || F <- Frames, {Tcp, _} <- [decode(iolist_to_binary(F))]],
            case lists:any(fun(Fl) -> Fl band Flag =/= 0 end, Flags) of
                true -> ok;
                false -> await_flag(Flag)
            end
    after ?WAIT -> error({no_segment_with, Flag})
    end.

decode(<<_Eth:14/binary, Packet/binary>>) ->
    {ok, #ip4{src = ?OURS, dst = ?PEER}, Seg} = erx_ip4_wire:decode(Packet),
    {ok, Tcp, Payload} = erx_tcp_wire:decode(erx_ip4_wire:pseudo_sum(?OURS, ?PEER, byte_size(Seg), 6),
                                             Seg),
    {Tcp, Payload}.

%% The connection's owner, read from its state.
owner(Conn) ->
    State = sys:get_state(Conn),
    #{owner => element(5, State)}.
