%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the interface core, erx_net_if_core (docs/design-network-stack.md, "The
%% interface core"), against canned frames: each event of its ARP, ICMP echo, DHCP and UDP
%% paths and the actions it answers, and the ingress bucket with the token a failed check
%% gives back (test/host/erx_net_effect_test.rb seeds a core that keeps it).
-module(erx_net_if_core_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_arp_wire.hrl").
-include("erx_dhcp4_wire.hrl").
-include("erx_icmp4_wire.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_net_eth.hrl").
-include("erx_udp_wire.hrl").

-define(MINE, <<2, 0, 0, 0, 0, 1>>).
-define(PEER_MAC, <<2, 0, 0, 0, 0, 9>>).
-define(BROADCAST_MAC, <<16#ffffffffffff:48>>).
-define(ME4, <<10, 0, 2, 15>>).
-define(PEER4, <<10, 0, 2, 2>>).
-define(NOW, 1000000000).

%% --- Fixtures --------------------------------------------------------------------

link() -> #{link => ethernet, lladdr => ?MINE, mtu => 1500, state => up, tx_limit => 16,
            finish => none}.

core(Config) ->
    erx_net_if_core:new(#{name => en0, link => link(), gen => erx_net_rand:new(<<7:128>>),
                          config => Config}).

static() -> static(#{}).
static(Extra) -> Extra#{ip4 => #{addr => ?ME4, plen => 24, gateway => ?PEER4}}.

%% A started core with its own rows as its configuration copy.
started(Config) ->
    {Core, [{publish, Rows} | _]} = step(start, core(Config)),
    configured(Rows, Core).

tcp_frame(Flags, Seq, Ack, Payload) ->
    Tcp = #tcp{sport = 4000, dport = 80, seq = Seq, ack = Ack, flags = Flags, win = 1024, urp = 0},
    Segment = iolist_to_binary(erx_tcp_wire:encode(Tcp, Payload, erx_ip4_wire:pseudo_sum(?PEER4, ?ME4, 0, 6), sender)),
    eth(?MINE, ?ETHERTYPE_IP, ip4(?PEER4, ?ME4, 6, Segment)).

rst_of(Frame) ->
    {_, Packet} = decode(Frame),
    {ok, #ip4{src = ?ME4, dst = ?PEER4}, Upper} = erx_ip4_wire:decode(Packet),
    {ok, Tcp, <<>>} = erx_tcp_wire:decode(erx_ip4_wire:pseudo_sum(?ME4, ?PEER4, byte_size(Upper), 6), Upper),
    Tcp.

%% tcp_dropwithreset without a connection: a SYN with data is answered RST|ACK past all it
%% occupied, an ACK with a RST at its acknowledgement, a RST with nothing; then the limit.
closed_tcp_port_draws_a_rst_within_the_limit_test() ->
    Core0 = started(static()),
    {Core1, _} = step(local(who_has_me(), Core0), Core0),
    {Core2, Syn} = step(local(tcp_frame(?TH_SYN, 100, 0, <<"abc">>), Core1), Core1),
    ?assertMatch([#tcp{sport = 80, dport = 4000, seq = 0, ack = 104, flags = ?TH_RST bor ?TH_ACK, win = 0}],
                 [rst_of(F) || F <- transmitted(Syn)]),
    {Core3, Ack} = step(local(tcp_frame(?TH_ACK, 100, 777, <<>>), Core2), Core2),
    ?assertMatch([#tcp{seq = 777, flags = ?TH_RST}], [rst_of(F) || F <- transmitted(Ack)]),
    {Core4, []} = step(local(tcp_frame(?TH_RST, 100, 0, <<>>), Core3), Core3),
    ?assertMatch(#{closed_port := 3}, counters(Core4)),
    Flood = lists:foldl(fun(_, C) -> element(1, step(local(tcp_frame(?TH_ACK, 1, 2, <<>>), C), C)) end,
                        Core4, lists:seq(1, 300)),
    ?assertMatch(#{rst_limited := _}, counters(Flood)).

configured(#{iface := Iface, addrs := Addrs, routes := Routes}, Core) ->
    Pid = self(),
    Snap = erx_net_frame:snapshot([Iface#{pid => Pid, driver => Pid}],
                                  [{Pid, Order, Row} || {Order, Row} <- Addrs],
                                  [{Pid, Row} || Row <- Routes]),
    {Core1, []} = step({config, 1, Snap}, Core),
    Core1.

step(Event, Core) -> step(Event, Core, ?NOW).
step(Event, Core, Now) -> erx_net_if_core:step(Event, Core, #{now => Now}).

%% A frame as the interface's loop gives it to the core: classified against its view.
local(Frame, Core) ->
    View = (erx_net_if_core:view(Core))#{demux => fun(_) -> [] end},
    {local, Pending} = erx_net_input:classify({frame, Frame, none}, View),
    {local, Pending}.

gen() -> erx_net_rand:new(<<9:128>>).

eth(Dst, Type, Payload) ->
    iolist_to_binary([erx_net_eth:encode(#eth{dst = Dst, src = ?PEER_MAC, type = Type}), Payload]).

ip4(Src, Dst, Proto, Upper) ->
    {ok, [Packet], _} = erx_ip4:output(#{src => Src, dst => Dst, proto => Proto, ttl => 64},
                                       Upper, 1500, gen()),
    iolist_to_binary(Packet).

arp(Op, Sha, Spa, Tha, Tpa) ->
    erx_arp_wire:encode(#arp{hrd = ?ARPHRD_ETHER, op = Op, sha = Sha, spa = Spa, tha = Tha, tpa = Tpa}).

who_has_me() -> eth(?BROADCAST_MAC, ?ETHERTYPE_ARP, arp(?ARPOP_REQUEST, ?PEER_MAC, ?PEER4, <<0:48>>, ?ME4)).
peer_is_at() -> eth(?MINE, ?ETHERTYPE_ARP, arp(?ARPOP_REPLY, ?PEER_MAC, ?PEER4, ?MINE, ?ME4)).

echo(Seq) ->
    Icmp = erx_icmp4_wire:encode(#icmp4{type = ?ICMP_ECHO, code = 0, msg = {echo, 7, Seq}}, <<"ping">>),
    eth(?MINE, ?ETHERTYPE_IP, ip4(?PEER4, ?ME4, 1, Icmp)).

%% The same echo request with its ICMP checksum broken.
bad_echo() ->
    <<Head:34/binary, Type, Code, Sum:16, Rest/binary>> = echo(1),
    <<Head/binary, Type, Code, (Sum bxor 1):16, Rest/binary>>.

udp_frame(Src, Dst, Sport, Dport, Payload) ->
    Sum = erx_ip4_wire:pseudo_sum(Src, Dst, 0, 17),
    Udp = iolist_to_binary(erx_udp_wire:encode(#udp{sport = Sport, dport = Dport}, Payload, Sum)),
    eth(?MINE, ?ETHERTYPE_IP, ip4(Src, Dst, 17, Udp)).

%% The frames of an action list, each flattened, and the decoded parts of one.
transmitted(Actions) -> [iolist_to_binary(F) || {transmit, Fs} <- Actions, F <- Fs].

decode(Frame) ->
    {ok, Eth, Ip} = erx_net_eth:decode(Frame),
    {Eth, Ip}.

icmp_of(Frame) ->
    {#eth{type = ?ETHERTYPE_IP} = Eth, Packet} = decode(Frame),
    {ok, Ip, Upper} = erx_ip4_wire:decode(Packet),
    {ok, Icmp, Rest} = erx_icmp4_wire:decode(Upper),
    {Eth, Ip, Icmp, Rest}.

arp_of(Frame) ->
    {#eth{type = ?ETHERTYPE_ARP} = Eth, Payload} = decode(Frame),
    {ok, Arp, _} = erx_arp_wire:decode(Payload),
    {Eth, Arp}.

counters(Core) ->
    {_, [{reply, from, {ok, Counters}}]} = step({admin, counters, from}, Core),
    Counters.

%% --- Start and publishing --------------------------------------------------------

start_publishes_the_static_configuration_and_announces_it_test() ->
    {_, [{publish, Rows} | Announce]} = step(start, core(static())),
    #{iface := #{name := en0, lladdr := ?MINE, mtu := 1500}, addrs := [{0, Addr}], routes := Routes} = Rows,
    ?assertMatch(#{addr := ?ME4, plen := 24, broadcast := <<10, 0, 2, 255>>}, Addr),
    ?assertEqual(lists:sort([{<<10, 0, 2, 0>>, 24, none}, {<<0:32>>, 0, ?PEER4}]),
                 lists:sort([{P, L, G} || #{prefix := P, plen := L, gateway := G} <- Routes])),
    [Gratuitous] = transmitted(Announce),
    ?assertMatch({#eth{dst = ?BROADCAST_MAC}, #arp{op = ?ARPOP_REQUEST, spa = ?ME4, tpa = ?ME4}},
                 arp_of(Gratuitous)).

view_lists_the_address_and_its_broadcast_test() ->
    #{ip4 := Ip4, dhcp := false} = erx_net_if_core:view(core(static())),
    ?assertEqual(#{addrs => [?ME4], broadcasts => [<<10, 0, 2, 255>>], loopback => false}, Ip4).

%% --- ARP -------------------------------------------------------------------------

arp_request_is_answered_and_its_sender_published_test() ->
    Core = started(static()),
    {_, Actions} = step(local(who_has_me(), Core), Core),
    ?assert(lists:member({neigh, publish, ?PEER4, ?PEER_MAC, fresh}, Actions)),
    [Reply] = transmitted(Actions),
    ?assertMatch({#eth{dst = ?PEER_MAC, src = ?MINE},
                  #arp{op = ?ARPOP_REPLY, sha = ?MINE, spa = ?ME4, tha = ?PEER_MAC, tpa = ?PEER4}},
                 arp_of(Reply)).

resolve_holds_packets_until_the_reply_and_hint_is_quiet_test() ->
    Core0 = started(static()),
    Packet = ip4(?ME4, ?PEER4, 17, <<"held">>),
    {Core1, Ask} = step({resolve, ?PEER4, ?ME4, [Packet]}, Core0),
    [Request] = transmitted(Ask),
    ?assertMatch({#eth{dst = ?BROADCAST_MAC}, #arp{op = ?ARPOP_REQUEST, tpa = ?PEER4}}, arp_of(Request)),
    ?assert(erx_net_if_core:next_deadline(Core1) > ?NOW),
    {Core2, Answer} = step(local(peer_is_at(), Core1), Core1),
    ?assert(lists:member({neigh, publish, ?PEER4, ?PEER_MAC, fresh}, Answer)),
    ?assertEqual([iolist_to_binary([erx_net_eth:encode(#eth{dst = ?PEER_MAC, src = ?MINE,
                                                            type = ?ETHERTYPE_IP}), Packet])],
                 transmitted(Answer)),
    ?assertMatch({_, []}, step({hint, ?PEER4}, Core2)).

expired_runs_the_table_deadlines_test() ->
    {Core, _} = step({resolve, ?PEER4, ?ME4, [ip4(?ME4, ?PEER4, 17, <<>>)]}, started(static())),
    %% An entry still incomplete at arpt_down (20 s) is freed with what it held.
    Down = ?NOW + 20000000,
    ?assertEqual(Down, erx_net_if_core:next_deadline(Core)),
    {Core1, []} = step({expired, Down}, Core, Down),
    ?assertEqual(infinity, erx_net_if_core:next_deadline(Core1)).

%% --- ICMP echo -------------------------------------------------------------------

echo_request_is_answered_to_a_known_neighbour_test() ->
    Core0 = started(static()),
    {Core1, _} = step(local(who_has_me(), Core0), Core0),
    {_, Actions} = step(local(echo(1), Core1), Core1),
    [Reply] = transmitted(Actions),
    {#eth{dst = ?PEER_MAC}, Ip, Icmp, Rest} = icmp_of(Reply),
    ?assertMatch(#ip4{src = ?ME4, dst = ?PEER4}, Ip),
    ?assertEqual(#icmp4{type = ?ICMP_ECHOREPLY, code = 0, msg = {echo, 7, 1}}, Icmp),
    ?assertEqual(<<"ping">>, Rest).

echo_request_from_an_unknown_neighbour_waits_for_arp_test() ->
    Core0 = started(static()),
    {Core1, Ask} = step(local(echo(1), Core0), Core0),
    ?assertMatch([{_, #arp{op = ?ARPOP_REQUEST, tpa = ?PEER4}}], [arp_of(F) || F <- transmitted(Ask)]),
    {_, Answer} = step(local(peer_is_at(), Core1), Core1),
    ?assertMatch([{_, _, #icmp4{type = ?ICMP_ECHOREPLY}, _}], [icmp_of(F) || F <- transmitted(Answer)]).

%% --- The ingress bucket ----------------------------------------------------------

bucket_refuses_past_its_burst_but_an_awaited_reply_passes_test() ->
    Core0 = started(static(#{ingress => #{rate => 1, burst => 2}})),
    {Core1, _} = step(local(echo(1), Core0), Core0),     % spends one, asks for the peer
    {Core2, _} = step(local(echo(2), Core1), Core1),     % spends the last
    {Core3, []} = step(local(echo(3), Core2), Core2),    % refused
    ?assertMatch(#{ingress := 1}, counters(Core3)),
    {_, Answer} = step(local(peer_is_at(), Core3), Core3),
    ?assertMatch([_, _], transmitted(Answer)).            % both held replies leave

bucket_refills_at_its_rate_test() ->
    Core0 = started(static(#{ingress => #{rate => 1, burst => 1}})),
    {Core1, _} = step(local(echo(1), Core0), Core0),
    {Core2, []} = step(local(echo(2), Core1), Core1, ?NOW + 500000),
    ?assertMatch(#{ingress := 1}, counters(Core2)),
    {Core3, _} = step(local(echo(3), Core2), Core2, ?NOW + 1000000),
    ?assertMatch(#{ingress := 1}, counters(Core3)).

failed_check_gives_its_token_back_test() ->
    Core0 = started(static(#{ingress => #{rate => 1, burst => 1}})),
    {Core1, []} = step(local(bad_echo(), Core0), Core0),
    ?assertMatch(#{bad_sum := 1}, counters(Core1)),
    {Core2, Ask} = step(local(echo(1), Core1), Core1),
    ?assertMatch([_], transmitted(Ask)),
    ?assertEqual(false, maps:is_key(ingress, counters(Core2))).

%% --- UDP to a closed port --------------------------------------------------------

closed_port_draws_port_unreachable_quoting_the_datagram_test() ->
    Core0 = started(static()),
    {Core1, _} = step(local(who_has_me(), Core0), Core0),
    Frame = udp_frame(?PEER4, ?ME4, 4000, 9, <<"anyone?">>),
    {Core2, Actions} = step(local(Frame, Core1), Core1),
    [Error] = transmitted(Actions),
    {#eth{dst = ?PEER_MAC}, _, #icmp4{type = ?ICMP_UNREACH, code = 3}, Quote} = icmp_of(Error),
    <<_:14/binary, Sent/binary>> = Frame,
    ?assertEqual(Sent, Quote),                           % under icmp_quotelen, whole
    ?assertMatch(#{port_unreach := 1}, counters(Core2)).

%% --- DHCP ------------------------------------------------------------------------

discover() -> #dhcp4{op = request, xid = 16#1234, chaddr = ?MINE, options = #{message_type => discover}}.

dhcp_broadcast_leaves_from_any_to_the_limited_broadcast_test() ->
    {_, Actions} = step({dhcp, {send, broadcast, <<0:32>>, discover()}}, started(#{ip4 => dhcp})),
    [Frame] = transmitted(Actions),
    {#eth{dst = ?BROADCAST_MAC, src = ?MINE}, Packet} = decode(Frame),
    {ok, Ip, Upper} = erx_ip4_wire:decode(Packet),
    ?assertMatch(#ip4{src = <<0:32>>, dst = <<255, 255, 255, 255>>, ttl = 16}, Ip),
    {ok, #udp{sport = 68, dport = 67}, Payload} =
        erx_udp_wire:decode(inet, erx_ip4_wire:pseudo_sum(<<0:32>>, <<255, 255, 255, 255>>,
                                                          byte_size(Upper), 17), Upper),
    ?assertMatch({ok, #dhcp4{xid = 16#1234}}, erx_dhcp4_wire:decode(Payload)).

dhcp_reply_is_passed_to_the_client_test() ->
    Core = started(#{ip4 => dhcp}),
    Offer = #dhcp4{op = reply, xid = 16#1234, yiaddr = ?ME4, chaddr = ?MINE,
                   options = #{message_type => offer, server_id => ?PEER4}},
    Frame = udp_frame(?PEER4, <<255, 255, 255, 255>>, 67, 68, erx_dhcp4_wire:encode(Offer)),
    {_, [{dhcp, {reply, #dhcp4{xid = 16#1234, yiaddr = ?ME4}}}]} = step(local(Frame, Core), Core).

lease_configures_and_unconfigure_withdraws_test() ->
    Lease = #{addr => ?ME4, mask => <<255, 255, 255, 0>>, mtu => 1400, dns => [<<10, 0, 2, 3>>],
              search => [], server => ?PEER4,
              routes => [#{prefix => <<0:32>>, plen => 0, gateway => ?PEER4}]},
    Core0 = started(#{ip4 => dhcp}),
    {Core1, [{publish, Rows} | Announce]} = step({dhcp, {configure, Lease}}, Core0),
    ?assertMatch(#{iface := #{mtu := 1400}, addrs := [{_, #{addr := ?ME4, plen := 24}}],
                   routes := [_, _]}, Rows),
    ?assertMatch([_], transmitted(Announce)),
    ?assertMatch({_, [{reply, f, {ok, Lease}}]}, step({admin, lease, f}, Core1)),
    {_, [{publish, Gone}]} = step({dhcp, unconfigure}, Core1),
    ?assertMatch(#{iface := #{mtu := 1500}, addrs := [], routes := []}, Gone).

%% The status netadmin and ifconfig read: the link from the driver's attach, then each
%% change; the addresses and routes configured; the lease's name servers under DHCP.
status_shows_the_link_addresses_and_lease_test() ->
    Static = started(static()),
    ?assertMatch({_, [{reply, f, {ok, #{name := en0, lladdr := ?MINE, mtu := 1500, link := up,
                                        config := static, dns := [], search := [],
                                        addrs := [#{addr := ?ME4, plen := 24,
                                                    broadcast := <<10, 0, 2, 255>>}],
                                        routes := [_ | _]}}}]},
                 step({admin, status, f}, Static)),
    {Down, []} = step({link, down}, Static),
    ?assertMatch({_, [{reply, f, {ok, #{link := down}}}]}, step({admin, status, f}, Down)),
    Lease = #{addr => ?ME4, mask => <<255, 255, 255, 0>>, mtu => 1400, dns => [<<10, 0, 2, 3>>],
              search => [<<"example.org">>], server => ?PEER4,
              routes => [#{prefix => <<0:32>>, plen => 0, gateway => ?PEER4}]},
    Dhcp0 = started(#{ip4 => dhcp}),
    ?assertMatch({_, [{reply, f, {ok, #{config := dhcp, addrs := [], dns := []}}}]},
                 step({admin, status, f}, Dhcp0)),
    {Dhcp1, _} = step({dhcp, {configure, Lease}}, Dhcp0),
    ?assertMatch({_, [{reply, f, {ok, #{config := dhcp, mtu := 1400, dns := [<<10, 0, 2, 3>>],
                                        search := [<<"example.org">>],
                                        addrs := [#{addr := ?ME4, plen := 24}]}}}]},
                 step({admin, status, f}, Dhcp1)).

link_change_goes_to_the_client_only_under_dhcp_test() ->
    ?assertMatch({_, [{dhcp, {link, up}}]}, step({link, up}, started(#{ip4 => dhcp}))),
    ?assertMatch({_, []}, step({link, up}, started(static()))).

%% --- Counting --------------------------------------------------------------------

drops_and_unsupported_events_are_counted_test() ->
    {Core1, []} = step({drop, other_host}, started(static())),
    {Core2, []} = step({ifid, make_ref(), unavailable}, Core1),
    ?assertMatch(#{other_host := 1, unsupported := 1}, counters(Core2)),
    ?assertMatch({_, [{reply, f, {error, enotsup}}]}, step({admin, routes, f}, Core2)).

no_path_without_a_configuration_copy_test() ->
    {Core, _} = step(start, core(static())),
    {Core1, _} = step(local(who_has_me(), Core), Core),
    {Core2, []} = step(local(echo(1), Core1), Core1),
    ?assertMatch(#{no_route := 1}, counters(Core2)).


%% --- The loopback interface ------------------------------------------------------

-define(LO4, <<127, 0, 0, 1>>).

lo_link() -> #{link => none, lladdr => none, mtu => 16384, state => up, tx_limit => 16,
               finish => none}.

lo_core() ->
    erx_net_if_core:new(#{name => lo0, link => lo_link(), gen => erx_net_rand:new(<<8:128>>),
                          config => #{ip4 => #{addr => ?LO4, plen => 8}}}).

%% Cores of the loopback interface and of en0, each with the configuration copy of both
%% interfaces' published rows.
lo_and_en0() ->
    {Lo0, [{publish, LoRows}]} = step(start, lo_core()),
    {En0, [{publish, EnRows} | _]} = step(start, core(static())),
    Snap = snapshot_of([LoRows, EnRows]),
    {Lo, []} = step({config, 1, Snap}, Lo0),
    {En, []} = step({config, 1, Snap}, En0),
    {Lo, En}.

snapshot_of(RowSets) ->
    Pid = self(),
    erx_net_frame:snapshot([Iface#{pid => Pid, driver => Pid} || #{iface := Iface} <- RowSets],
                           [{Pid, Order, Row} || #{addrs := Addrs} <- RowSets, {Order, Row} <- Addrs],
                           [{Pid, Row} || #{routes := Routes} <- RowSets, Row <- Routes]).

looped(Zone, Packet, Core) ->
    View = (erx_net_if_core:view(Core))#{demux => fun(_) -> [] end},
    {local, Pending} = erx_net_input:classify({looped, Zone, Packet}, View),
    {local, Pending}.

echo_packet(Src, Dst) ->
    Icmp = erx_icmp4_wire:encode(#icmp4{type = ?ICMP_ECHO, code = 0, msg = {echo, 7, 1}}, <<"ping">>),
    ip4(Src, Dst, 1, Icmp).

%% The looped frames of Actions, each a packet with its zone in front (if_simloop's input).
looped_out(Actions) -> [{Zone, iolist_to_binary(P)} || {transmit, Fs} <- Actions, {Zone, P} <- Fs].

echo_reply_of(Packet) ->
    {ok, Ip, Upper} = erx_ip4_wire:decode(Packet),
    {ok, Icmp, _} = erx_icmp4_wire:decode(Upper),
    {Ip, Icmp}.

%% The loopback interface publishes its link as `none`, with no link-layer address and
%% FreeBSD's LOMTU, and announces nothing: it has no ARP.
loopback_publishes_link_none_and_announces_nothing_test() ->
    {_, Actions} = step(start, lo_core()),
    ?assertMatch([{publish, #{iface := #{name := lo0, link := none, lladdr := none, mtu := 16384},
                              addrs := [{_, #{addr := ?LO4, plen := 8}}]}}],
                 Actions).

%% An echo request to 127.0.0.1 comes back through the loopback interface, from 127.0.0.1,
%% its zone the loopback interface's own name.
loopback_echo_is_answered_through_the_loopback_test() ->
    {Lo, _} = lo_and_en0(),
    {_, Actions} = step(looped(lo0, echo_packet(?LO4, ?LO4), Lo), Lo),
    [{lo0, Reply}] = looped_out(Actions),
    ?assertMatch({#ip4{src = ?LO4, dst = ?LO4}, #icmp4{type = ?ICMP_ECHOREPLY}}, echo_reply_of(Reply)).

%% A packet to another interface's address loops in that address's zone and is the
%% stack's on the loopback interface (ip_input's weak end-system model), and so is the
%% reply, which loops back in the same zone.
loopback_takes_a_packet_to_another_interfaces_address_test() ->
    {Lo, _} = lo_and_en0(),
    {_, Actions} = step(looped(en0, echo_packet(?ME4, ?ME4), Lo), Lo),
    [{en0, Reply}] = looped_out(Actions),
    ?assertMatch({#ip4{src = ?ME4, dst = ?ME4}, #icmp4{type = ?ICMP_ECHOREPLY}}, echo_reply_of(Reply)).

%% Every interface's view holds every IPv4 address of the stack, its own first; a loopback
%% address still never arrives off the loopback interface (erx_ip4's RFC 1122 check).
views_hold_every_address_of_the_stack_test() ->
    {Lo, En} = lo_and_en0(),
    ?assertMatch(#{link := none, ip4 := #{addrs := [?LO4, ?ME4], loopback := true}},
                 erx_net_if_core:view(Lo)),
    ?assertMatch(#{link := ethernet, ip4 := #{addrs := [?ME4, ?LO4], loopback := false}},
                 erx_net_if_core:view(En)),
    View = (erx_net_if_core:view(En))#{demux => fun(_) -> [] end},
    ?assertMatch({drop, _}, erx_net_input:classify({frame, eth(?MINE, ?ETHERTYPE_IP, echo_packet(?PEER4, ?LO4)), none},
                                                   View)).

%% The loopback interface takes no DHCP configuration: it has no link to broadcast on.
loopback_refuses_dhcp_test() ->
    ?assertError(function_clause,
                 erx_net_if_core:new(#{name => lo0, link => lo_link(), gen => erx_net_rand:new(<<8:128>>),
                                       config => #{ip4 => dhcp}})).
