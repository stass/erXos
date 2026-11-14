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
and keeps the peer's bytes until its socket process's first message; and that its
listener's exit aborts it with a RST.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_tcp_wire.hrl").

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
      {"the listener's exit aborts a queued connection with a RST",
       fun listener_exit_aborts_a_queued_connection/0},
      {"a full accept credit starts nothing", fun full_credit_starts_nothing/0}]].

%% --- The stand-ins ---------------------------------------------------------------

setup() ->
    %% The connections link to the test process as listener and owner; their exits at
    %% the cleanup, which kills their grant, must not end it.
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

cleanup({Tables, _Grant}) ->
    Procs = [P || P <- [whereis(erx_net_grant), Tables], is_pid(P)],
    [begin Ref = monitor(process, P), exit(P, kill), receive {'DOWN', Ref, _, _, _} -> ok end end
     || P <- Procs],
    flush(),
    process_flag(trap_exit, false).

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

queued_connection_waits_for_the_first_contact() ->
    Unit = erx_net_credit:new(2),
    ok = erx_tcp_conn:accept(accept(self(), Unit, <<"hello">>)),
    Conn = receive {queued, C} -> C after ?WAIT -> error(not_queued) end,
    %% The notice carries the unit: still reserved, now the listener's.
    ?assertEqual(1, erx_net_credit:free(Unit)),
    ?assertMatch([#{pid := Conn}], erx_net_tables:demux(?KEY)),
    #{owner := {listener, _}} = owner(Conn),
    Conn ! {bind, self()},
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
    ok = erx_net_bind:insert(?KEY, Holder, #{pid => Holder, credit => none}),
    Unit = erx_net_credit:new(2),
    ok = erx_tcp_conn:accept(accept(self(), Unit, <<>>)),
    await_free(Unit, 2),
    receive {queued, _} -> error(queued) after 100 -> ok end,
    %% The key stays its holder's.
    ?assertMatch([#{pid := Holder}], erx_net_tables:demux(?KEY)),
    Holder ! stop.

refused_adoption_resets() ->
    Old = whereis(erx_net_grant),
    Ref = monitor(process, Old),
    exit(Old, kill),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    {ok, Grant} = erx_net_grant:start_link(local, #{buffers => 0}),
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

%% Waits for the RST the connection hands the driver, past the ACKs before it.
await_rst() ->
    receive
        {transmit, Frames} ->
            Flags = [Tcp#tcp.flags || F <- Frames, {Tcp, _} <- [decode(iolist_to_binary(F))]],
            case lists:any(fun(Fl) -> Fl band ?TH_RST =/= 0 end, Flags) of
                true -> ok;
                false -> await_rst()
            end
    after ?WAIT -> error(no_rst)
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
