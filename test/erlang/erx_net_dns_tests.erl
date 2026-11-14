%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_dns_tests).
-moduledoc """
EUnit cases of name resolution's stack side and client side
(docs/design-network-stack.md, "Name resolution", "The backend"):

* the grant's `resolver` operation, read from the interfaces' rows, within
  resolv.conf's limits, with one subscriber that a change of the rows reaches;
* erx_gen_udp through the grant to erx_udp_sock: open, connect, send, receive, the
  connected socket's filter on its peer, the socket's end with its owner, and the
  requests refused;
* erx_inet's check of the grant's answer and its load into inet_db.

Each interface is a stand-in process that answers `erx_net_if:admin(Pid, status)` from
what the case set; its rows are written by hand, and the test process is the driver
that frames are handed to, as in erx_tcp_conn_tests.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_udp_wire.hrl").

-define(OURS, <<10, 0, 2, 15>>).
-define(DNS, <<10, 0, 2, 3>>).
-define(WAIT, 3000).
-define(QUIET, 200).

dns_test_() ->
    [{Name, fun() -> Setup = setup(), try Case() after cleanup(Setup) end end}
     || {Name, Case} <-
     [{"the grant answers the interfaces' name servers and search list", fun resolver_reads_rows/0},
      {"the answer keeps resolv.conf's limits and drops repeats", fun resolver_is_bounded/0},
      {"a change of the rows reaches the subscriber once", fun resolver_change_is_sent/0},
      {"a second subscriber replaces the first", fun resolver_has_one_subscriber/0},
      {"a reader does not displace the subscriber", fun resolver_read_keeps_subscriber/0},
      {"an interface that crashes in its status call is passed over", fun interfaces_pass_over_crash/0},
      {"a socket that crashes in a call answers closed", fun udp_crash_is_closed/0},
      {"a datagram goes to the connected peer and its answer back", fun udp_exchange/0},
      {"a connected socket takes only its peer's datagrams", fun udp_connected_filters/0},
      {"a socket ends with its owner", fun udp_ends_with_owner/0},
      {"bad requests and options are refused", fun udp_refusals/0},
      {"a bind meets the keys it overlaps, the machine's addresses and the allowed ports",
       fun udp_bind_checks/0}]].

config_test_() ->
    [{"a well-formed answer is taken", fun config_accepted/0},
     {"a malformed answer is refused", fun config_refused/0},
     {"a bad search domain is dropped and the rest kept", fun config_drops_bad_domains/0},
     {"an answer loads into inet_db", fun config_loads/0},
     {"inet_db's resolv.conf check keeps a loaded answer", fun config_outlives_resolv_conf/0}].

%% --- The stand-in interface ------------------------------------------------------

setup() ->
    ok = persistent_term:put({erx_net_sup, runtime}, erx_net_local),
    {ok, Tables} = erx_net_tables:start_link(),
    unlink(Tables),
    Me = interface(en0, [?DNS], [<<"erxos.test">>]),
    Tx = erx_net_credit:new(256),
    true = ets:insert(erx_net_ifs, {en0, Me, iface(en0, Me, Tx)}),
    true = ets:insert(erx_net_addrs, {{Me, ?OURS}, Me, 0,
                                      #{addr => ?OURS, plen => 24, ifname => en0, flags => [],
                                        broadcast => <<10, 0, 2, 255>>}}),
    true = ets:insert(erx_net_routes, {{Me, <<10, 0, 2, 0>>, 24}, Me,
                                       #{prefix => <<10, 0, 2, 0>>, plen => 24, gateway => none,
                                         ifname => en0, metric => 0}}),
    true = ets:insert(erx_net_neigh, {{Me, ?DNS}, <<2, 0, 0, 0, 0, 3>>, fresh, 0}),
    _ = ets:update_counter(erx_net_gen, gen, 1),
    {ok, Grant} = erx_net_grant:start_link(local, #{}),
    unlink(Grant),
    put(tx, Tx),
    {Tables, Grant}.

iface(Name, Pid, Tx) ->
    #{name => Name, pid => Pid, link => ethernet, lladdr => <<2, 0, 0, 0, 0, 1>>, mtu => 1500,
      mtu6 => 1500, hlim => 64, finish => none, driver => self(), driver_credit => Tx,
      rx_credit => erx_net_credit:new(256), credit => erx_net_credit:new(256)}.

%% A stand-in interface: it answers the status request with its name servers and search
%% list, and takes {set, Dns, Search} to change them.
interface(Name, Dns, Search) ->
    spawn(fun() -> interface_loop(#{name => Name, lladdr => <<2, 0, 0, 0, 0, 1>>, mtu => 1500,
                                    link => up, config => dhcp, addrs => [], routes => [],
                                    dns => Dns, search => Search})
          end).

interface_loop(Status) ->
    receive
        {'$gen_call', From, {admin, status}} ->
            gen_server:reply(From, {ok, Status}),
            interface_loop(Status);
        {set, Dns, Search, From} ->
            From ! set,
            interface_loop(Status#{dns := Dns, search := Search});
        stop ->
            ok
    end.

cleanup({Tables, Grant}) ->
    [begin Ref = monitor(process, P), exit(P, kill), receive {'DOWN', Ref, _, _, _} -> ok end end
     || P <- [Grant, Tables | [Pid || {_, Pid, _} <- ets:tab2list(erx_net_ifs)]]],
    flush().

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% Rewrites interface Name's resolver fields, as an interface publishes a new lease.
republish(Name, Dns, Search) ->
    [{Name, Pid, _Row}] = ets:lookup(erx_net_ifs, Name),
    Pid ! {set, Dns, Search, self()},
    receive set -> ok after ?WAIT -> error(interface_not_set) end,
    erx_net_tables:resolver_moved().

%% --- The resolver operation --------------------------------------------------------

resolver_reads_rows() ->
    ?assertEqual({ok, #{nameservers => [{{10, 0, 2, 3}, 53}], search => [<<"erxos.test">>]}},
                 gen_server:call(erx_net_grant, resolver)).

resolver_is_bounded() ->
    Servers = [<<10, 0, 3, N>> || N <- [1, 2, 3, 4]],
    Domains = [<<"d", (integer_to_binary(N))/binary, ".test">> || N <- lists:seq(1, 7)],
    En1 = interface(en1, [?DNS | Servers], [<<"erxos.test">> | Domains]),
    true = ets:insert(erx_net_ifs, {en1, En1, iface(en1, En1, get(tx))}),
    {ok, #{nameservers := Ns, search := Search}} = gen_server:call(erx_net_grant, resolver),
    ?assertEqual([{{10, 0, 2, 3}, 53}, {{10, 0, 3, 1}, 53}, {{10, 0, 3, 2}, 53}], Ns),
    ?assertEqual([<<"erxos.test">> | lists:sublist(Domains, 5)], Search).

resolver_change_is_sent() ->
    {ok, _} = gen_server:call(erx_net_grant, watch_resolver),
    Grant = whereis(erx_net_grant),
    ok = republish(en0, [<<10, 0, 2, 4>>], []),
    receive
        {erx_net_resolver, Grant, Config} ->
            ?assertEqual(#{nameservers => [{{10, 0, 2, 4}, 53}], search => []}, Config)
    after ?WAIT -> error(no_change_message)
    end,
    ok = republish(en0, [<<10, 0, 2, 4>>], []),
    receive {erx_net_resolver, _, _} = Again -> error({sent_without_a_change, Again})
    after ?QUIET -> ok
    end.

resolver_has_one_subscriber() ->
    Me = self(),
    First = spawn_link(fun() ->
                               {ok, _} = gen_server:call(erx_net_grant, watch_resolver),
                               Me ! subscribed,
                               receive Msg -> Me ! {first_got, Msg} end
                       end),
    receive subscribed -> ok after ?WAIT -> error(first_did_not_subscribe) end,
    {ok, _} = gen_server:call(erx_net_grant, watch_resolver),
    ok = republish(en0, [<<10, 0, 2, 5>>], []),
    receive {erx_net_resolver, _, #{nameservers := [{{10, 0, 2, 5}, 53}]}} -> ok
    after ?WAIT -> error(no_change_message)
    end,
    receive {first_got, Msg} -> error({replaced_subscriber_got, Msg})
    after ?QUIET -> ok
    end,
    unlink(First),
    exit(First, kill).

resolver_read_keeps_subscriber() ->
    {ok, _} = gen_server:call(erx_net_grant, watch_resolver),
    Me = self(),
    Reader = spawn_link(fun() -> Me ! {read, gen_server:call(erx_net_grant, resolver)} end),
    receive {read, {ok, #{nameservers := [{{10, 0, 2, 3}, 53}]}}} -> ok
    after ?WAIT -> error(no_read_answer)
    end,
    unlink(Reader),
    Grant = whereis(erx_net_grant),
    ok = republish(en0, [<<10, 0, 2, 6>>], []),
    receive {erx_net_resolver, Grant, #{nameservers := [{{10, 0, 2, 6}, 53}]}} -> ok
    after ?WAIT -> error(subscriber_displaced)
    end.

interfaces_pass_over_crash() ->
    Crash = spawn(fun() -> receive {'$gen_call', _, _} -> exit(boom) end end),
    true = ets:insert(erx_net_ifs, {en1, Crash, iface(en1, Crash, get(tx))}),
    {ok, Ifs} = erx_net:interfaces(),
    ?assertEqual([en0], [Name || #{name := Name} <- Ifs]).

%% --- erx_gen_udp ------------------------------------------------------------------

udp_crash_is_closed() ->
    Sock = spawn(fun() -> receive {'$gen_call', _, _} -> exit(boom) end end),
    ?assertEqual({error, closed}, erx_gen_udp:recv({'$inet', erx_gen_udp, Sock}, 0, 1000)).

%% Datagrams the socket handed its driver, as {#udp{}, Payload}, their units taken.
datagrams() ->
    receive
        {transmit, Frames} ->
            ok = erx_net_credit:take(get(tx), length(Frames)),
            [decode(iolist_to_binary(F)) || F <- Frames]
    after ?WAIT -> error({no_datagram, process_info(self(), messages)})
    end.

decode(<<_Eth:14/binary, Packet/binary>>) ->
    {ok, #ip4{src = ?OURS, dst = Dst}, Seg} = erx_ip4_wire:decode(Packet),
    {ok, Udp, Payload} = erx_udp_wire:decode(inet, erx_ip4_wire:pseudo_sum(?OURS, Dst, byte_size(Seg), 17),
                                             Seg),
    {Udp, Payload}.

%% The datagram socket in the stack behind the socket process of S, and its credit.
datagram_socket(S) ->
    {ok, {_, Port}} = erx_gen_udp:sockname(S),
    [#{pid := Sock, credit := Credit}] = erx_net_tables:demux({udp, inet, any, Port}),
    {Sock, Credit}.

%% A datagram from From, handed to the datagram socket as an interface hands it.
hand(S, From, Data) ->
    {Sock, Credit} = datagram_socket(S),
    ok = erx_net_credit:hand(Sock, Credit, 1, {items, self(), [{datagram, From, ?OURS, Data}]}).

udp_exchange() ->
    {ok, S} = erx_gen_udp:open(-1, [{active, false}, binary, inet]),
    {ok, {{0, 0, 0, 0}, Port}} = erx_gen_udp:sockname(S),
    ?assert(Port > 0),
    ok = erx_gen_udp:connect(S, {10, 0, 2, 3}, 53),
    ok = erx_gen_udp:send(S, [<<"que">>, "ry"]),
    ?assertMatch([{#udp{sport = Port, dport = 53}, <<"query">>}], datagrams()),
    ok = hand(S, {?DNS, 53}, <<"answer">>),
    ?assertEqual({ok, {{10, 0, 2, 3}, 53, <<"answer">>}}, erx_gen_udp:recv(S, 0, ?WAIT)),
    ok = erx_gen_udp:close(S),
    ?assertEqual([], erx_net_tables:demux({udp, inet, any, Port})),
    ?assertEqual(ok, erx_gen_udp:close(S)).

udp_connected_filters() ->
    {ok, S} = erx_gen_udp:open(0, [{active, false}, binary]),
    ok = erx_gen_udp:connect(S, {10, 0, 2, 3}, 53),
    ok = hand(S, {<<10, 0, 2, 9>>, 53}, <<"spoofed">>),
    ok = hand(S, {?DNS, 5353}, <<"other port">>),
    ok = hand(S, {?DNS, 53}, <<"real">>),
    ?assertEqual({ok, {{10, 0, 2, 3}, 53, <<"real">>}}, erx_gen_udp:recv(S, 0, ?WAIT)),
    ?assertEqual({error, timeout}, erx_gen_udp:recv(S, 0, ?QUIET)),
    ok = erx_gen_udp:close(S).

udp_ends_with_owner() ->
    Me = self(),
    Owner = spawn(fun() ->
                          {ok, S} = erx_gen_udp:open(0, [{active, false}]),
                          Me ! {opened, S},
                          receive stop -> ok end
                  end),
    S = receive {opened, Opened} -> Opened after ?WAIT -> error(not_opened) end,
    {ok, {_, Port}} = erx_gen_udp:sockname(S),
    {Sock, _} = datagram_socket(S),
    Ref = monitor(process, Sock),
    exit(Owner, kill),
    receive {'DOWN', Ref, process, Sock, _} -> ok after ?WAIT -> error(socket_outlived_owner) end,
    ?assertEqual([], erx_net_tables:demux({udp, inet, any, Port})).

%% An explicit bind runs erx_net_bind:avail/2 with its insertion: a socket bound to one of
%% the machine's addresses meets one bound to any address on the port, an address not the
%% machine's is refused, and so is a port the grant does not allow (below 1024 by default).
udp_bind_checks() ->
    {ok, Any} = erx_gen_udp:open(20000, [{active, false}]),
    ?assertEqual({error, eaddrinuse}, erx_gen_udp:open(20000, [{ip, {10, 0, 2, 15}}])),
    ok = erx_gen_udp:close(Any),
    {ok, Ours} = erx_gen_udp:open(20000, [{ip, {10, 0, 2, 15}}]),
    ?assertEqual({error, eaddrinuse}, erx_gen_udp:open(20000, [])),
    ok = erx_gen_udp:close(Ours),
    ?assertEqual({error, eaddrnotavail}, erx_gen_udp:open(0, [{ip, {10, 0, 2, 99}}])),
    ?assertEqual({error, eacces}, erx_gen_udp:open(53, [])).

udp_refusals() ->
    ?assertEqual({error, eafnosupport}, erx_gen_udp:open(0, [inet6])),
    ?assertEqual({error, einval}, erx_gen_udp:open(0, [{recbuf, 9000}])),
    ?assertEqual({error, badarg}, gen_server:call(erx_net_grant, {udp_open, inet, any, 70000, []})),
    ?assertEqual({error, badarg}, gen_server:call(erx_net_grant, {udp_open, inet, {1, 2, 3}, 0, []})),
    {ok, {'$inet', erx_gen_udp, Sock} = S} = erx_gen_udp:open(0, [{active, false}]),
    ?assertEqual({error, edestaddrreq}, erx_gen_udp:send(S, <<"x">>)),
    ?assertEqual({error, einval}, gen_server:call(Sock, {send_to, {10, 0, 2, 3}, 53, not_binary})),
    ?assertEqual({error, einval}, gen_server:call(Sock, {recv, -1})),
    ?assertEqual({error, einval}, gen_server:call(Sock, {connect, {10, 0, 2, 3}, 0})),
    ?assertEqual({error, einval}, gen_server:call(Sock, nonsense)),
    ok = erx_gen_udp:close(S).

%% --- erx_inet -------------------------------------------------------------------

config_accepted() ->
    ?assertEqual({ok, #{nameservers => [{{10, 0, 2, 3}, 53}], search => ["erxos.test", "a-b.c9", "corp.example"]}},
                 erx_inet:resolver_config(#{nameservers => [{{10, 0, 2, 3}, 53}],
                                            search => [<<"erxos.test">>, <<"a-b.c9">>, <<"corp.example.">>]})),
    ?assertEqual({ok, #{nameservers => [], search => []}},
                 erx_inet:resolver_config(#{nameservers => [], search => []})).

config_refused() ->
    Ns = [{{10, 0, 2, 3}, 53}],
    Bad = [not_a_map,
           #{nameservers => Ns},
           #{nameservers => Ns, search => [], extra => 1},
           #{nameservers => [{{10, 0, 2, N}, 53} || N <- [1, 2, 3, 4]], search => []},
           #{nameservers => [{{10, 0, 2, 3}, 54}], search => []},
           #{nameservers => [{{256, 0, 0, 1}, 53}], search => []},
           #{nameservers => [{{10, 0, 2, 3}, 53} | improper], search => []},
           #{nameservers => Ns, search => [<<"d", (integer_to_binary(N))/binary>> || N <- lists:seq(1, 7)]},
           #{nameservers => Ns, search => [<<"lan">> | improper]}],
    [?assertEqual({error, badarg}, erx_inet:resolver_config(Term)) || Term <- Bad].

%% Each search domain is checked alone, by erx_dhcp4_wire's rules: one that fails is
%% dropped, and the name servers and the other domains are kept.
config_drops_bad_domains() ->
    Ns = [{{10, 0, 2, 3}, 53}],
    Bad = [<<"bad domain">>, <<"a..b">>, <<".">>, <<>>, <<"a_b">>, <<"-lan">>, <<"lan-">>,
           <<"esc\e[31m">>, binary:copy(<<"a">>, 64), <<(binary:copy(<<"a.">>, 127))/binary, "a">>,
           "a string"],
    [?assertEqual({ok, #{nameservers => Ns, search => ["lan"]}},
                  erx_inet:resolver_config(#{nameservers => Ns, search => [Name, <<"lan">>]}))
     || Name <- Bad].

config_loads() ->
    Saved = [{Opt, inet_db:res_option(Opt)} || Opt <- [nameservers, search, lookup]],
    try
        ok = inet_db:res_option(lookup, [file]),
        {ok, Config} = erx_inet:resolver_config(#{nameservers => [{{10, 0, 2, 3}, 53}],
                                                  search => [<<"erxos.test">>]}),
        ok = erx_inet:load(Config),
        ?assertEqual([{{10, 0, 2, 3}, 53}], inet_db:res_option(nameservers)),
        ?assertEqual(["erxos.test"], inet_db:res_option(search)),
        ?assertEqual([file, dns], inet_db:res_option(lookup)),
        ok = erx_inet:load(Config),
        ?assertEqual([file, dns], inet_db:res_option(lookup))
    after
        [ok = inet_db:res_option(Opt, Value) || {Opt, Value} <- Saved]
    end.

%% inet_db watches resolv.conf, and a check that finds no file, as on erXos, clears the
%% name servers and the search list; a loaded answer takes the file's place.
config_outlives_resolv_conf() ->
    Saved = [{Opt, inet_db:res_option(Opt)} || Opt <- [resolv_conf, nameservers, search, lookup]],
    try
        ok = inet_db:res_option(resolv_conf, "/nonexistent/resolv.conf"),
        {ok, Config} = erx_inet:resolver_config(#{nameservers => [{{10, 0, 2, 3}, 53}],
                                                  search => [<<"erxos.test">>]}),
        ok = gen_server:call(inet_db, {set_resolv_conf_tm, erlang:monotonic_time(second) - 10}),
        ok = erx_inet:load(Config),
        ok = inet_db:res_update_conf(),
        ?assertEqual([{{10, 0, 2, 3}, 53}], inet_db:res_option(nameservers)),
        ?assertEqual(["erxos.test"], inet_db:res_option(search))
    after
        [ok = inet_db:res_option(Opt, Value) || {Opt, Value} <- Saved, Value =/= undefined]
    end.
