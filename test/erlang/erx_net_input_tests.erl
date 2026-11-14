%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_net_input:classify/2 and verify/1 (docs/design-network-stack.md,
%% "Classifying a frame"): one case per row of the verdict table, each asserting the
%% verdict and, where the frame is not dropped, the item verify/1 hands on.

-module(erx_net_input_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_udp_wire.hrl").
-include("erx_net_eth.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_ip6.hrl").
-include("erx_icmp4_wire.hrl").
-include("erx_arp_wire.hrl").

-define(MINE, <<2, 0, 0, 0, 0, 1>>).
-define(OTHER_MAC, <<2, 0, 0, 0, 0, 7>>).
-define(PEER_MAC, <<2, 0, 0, 0, 0, 9>>).
-define(BROADCAST_MAC, <<16#ffffffffffff:48>>).
-define(ME4, <<10, 0, 0, 1>>).
-define(ALSO4, <<10, 0, 0, 2>>).
-define(PEER4, <<10, 0, 0, 9>>).
-define(BCAST4, <<10, 0, 0, 255>>).
-define(FOREIGN4, <<192, 0, 2, 7>>).
-define(GROUP4, <<224, 0, 0, 251>>).
-define(ME6, <<16#2001:16, 16#db8:16, 0:80, 1:16>>).
-define(PEER6, <<16#2001:16, 16#db8:16, 0:80, 9:16>>).
-define(LL1, <<16#fe80:16, 0:96, 1:16>>).
-define(LLPEER, <<16#fe80:16, 0:96, 9:16>>).
-define(ALLNODES, <<16#ff02:16, 0:96, 1:16>>).
-define(MDNS6, <<16#ff02:16, 0:96, 16#fb:16>>).
-define(PROTO_ICMP, 1).
-define(PROTO_TCP, 6).
-define(PROTO_UDP, 17).
-define(PROTO_GRE, 47).
-define(PROTO_NONE, 59).
-define(PROTO_ICMPV6, 58).

%% --- Views and builders ------------------------------------------------------

%% The Ethernet interface em0: 10.0.0.1 and its broadcast address, 2001:db8::1 and a
%% link-local address, joined to the all-nodes group, not configured for DHCP.
view() ->
    view(#{}).

view(Extra) ->
    maps:merge(#{link => ethernet, lladdr => ?MINE,
                 ip4 => #{addrs => [?ME4], broadcasts => [?BCAST4], loopback => false},
                 ip6 => #{addrs => [?ME6, {?LL1, em0}], notready => [], loopback => false, zone => em0},
                 groups => [?ALLNODES], dhcp => false, demux => demux(#{})}, Extra).

%% The loopback interface, which holds every address of the stack.
loop_view(Demux) ->
    #{link => none, lladdr => none,
      ip4 => #{addrs => [?ME4, <<127, 0, 0, 1>>], broadcasts => [], loopback => true},
      ip6 => #{addrs => [?ME6, {?LL1, em0}], notready => [], loopback => true, zone => lo0},
      groups => [], dhcp => false, demux => demux(Demux)}.

demux(Map) -> fun(Key) -> maps:get(Key, Map, []) end.

%% A holder for the key of each credit given.
holders(Keys) ->
    maps:from_list([{Key, [entry(Key, Credit)]} || {Key, Credit} <- Keys]).

entry({tcp_listen, _, _, _}, Credit) ->
    #{pid => self(), credit => Credit, listener => #{rcv_buf => 0, rcv_scale => 0}};
entry(_, Credit) ->
    #{pid => self(), credit => Credit}.

gen() -> erx_net_rand:new(<<7:128>>).

ip4(Src, Dst, Proto, Upper) -> ip4(Src, Dst, Proto, Upper, 0, 1500).

ip4(Src, Dst, Proto, Upper, Tos, Mtu) ->
    {ok, [Packet | _], _} = erx_ip4:output(#{src => Src, dst => Dst, proto => Proto, ttl => 64, tos => Tos},
                                           Upper, Mtu, gen()),
    iolist_to_binary(Packet).

ip6(Src, Dst, Proto, Upper) ->
    {ok, [Packet], _} = erx_ip6:output(#{src => Src, dst => Dst, proto => Proto, hlim => 64}, Upper,
                                       1500, gen()),
    iolist_to_binary(Packet).

eth(Dst, Type, Packet) ->
    iolist_to_binary([erx_net_eth:encode(#eth{dst = Dst, src = ?PEER_MAC, type = Type}), Packet]).

pseudo(Src, Dst, Proto) when byte_size(Src) =:= 4 -> erx_ip4_wire:pseudo_sum(Src, Dst, 0, Proto);
pseudo(Src, Dst, Proto) -> erx_ip6_wire:pseudo_sum(Src, Dst, 0, Proto).

tcp(Src, Dst, Sport, Dport, Flags, Payload) ->
    Header = #tcp{sport = Sport, dport = Dport, seq = 1, ack = 2, flags = Flags, win = 100, urp = 0},
    iolist_to_binary(erx_tcp_wire:encode(Header, Payload, pseudo(Src, Dst, ?PROTO_TCP), sender)).

udp(Src, Dst, Sport, Dport, Payload) ->
    iolist_to_binary(erx_udp_wire:encode(#udp{sport = Sport, dport = Dport}, Payload,
                                         pseudo(Src, Dst, ?PROTO_UDP))).

icmp4(Type, Code, Msg, Rest) ->
    iolist_to_binary(erx_icmp4_wire:encode(#icmp4{type = Type, code = Code, msg = Msg}, Rest)).

icmp6(Src, Dst, Type, Code, Msg, Rest) ->
    iolist_to_binary(erx_icmp6_wire:encode(#icmp6{type = Type, code = Code, msg = Msg}, Rest, {Src, Dst})).

%% The datagram an error quotes: the stack's own, from ME4:4000 to PEER4:80, with its ports.
quote4(Proto) ->
    Upper = case Proto of
                ?PROTO_TCP -> tcp(?ME4, ?PEER4, 4000, 80, 2, <<>>);
                ?PROTO_UDP -> udp(?ME4, ?PEER4, 4000, 80, <<>>)
            end,
    binary:part(ip4(?ME4, ?PEER4, Proto, Upper), 0, 28).

%% A frame from the driver, {frame, Bytes}, is classified as it comes without its network sum,
%% and again with it, as a summing transport hands it up: both must classify and verify alike.
classify({frame, Bytes}, View) ->
    Verdict = erx_net_input:classify({frame, Bytes, none}, View),
    ?assertEqual(verified(Verdict), verified(erx_net_input:classify({frame, Bytes, network_sum(Bytes)}, View))),
    Verdict;
classify(Input, View) ->
    erx_net_input:classify(Input, View).

verified({owned, Holders, Pending}) -> {owned, Holders, erx_net_input:verify(Pending)};
verified({local, Pending}) -> {local, erx_net_input:verify(Pending)};
verified({drop, _} = Drop) -> Drop.

%% The sum a summing transport hands up with a frame: of its bytes after the link header.
network_sum(Frame) when byte_size(Frame) >= 14 -> erx_bytes:inet_csum(0, binary:part(Frame, 14, byte_size(Frame) - 14));
network_sum(_) -> none.

%% A frame to the interface's own address, from the peer.
unicast(Packet, Type) -> {frame, eth(?MINE, Type, Packet)}.

ip4_frame(Packet) -> unicast(Packet, ?ETHERTYPE_IP).
ip6_frame(Packet) -> unicast(Packet, ?ETHERTYPE_IPV6).

%% A local verdict, and what verify/1 makes of it.
local(Verdict) ->
    {local, Pending} = Verdict,
    erx_net_input:verify(Pending).

%% An owned verdict: the holders' credits, and what verify/1 makes of it.
owned(Verdict) ->
    {owned, Holders, Pending} = Verdict,
    {[Credit || {_, Credit} <- Holders], erx_net_input:verify(Pending)}.

%% --- Network sums ------------------------------------------------------------

%% The checksum above IP is checked from the frame's network sum: the sum of the bytes above
%% IP is the network sum less an IPv6 header's, extension headers included (a checked IPv4
%% header, options included, sums to zero), and less the padding's after the packet, here of an odd count from an odd offset. With a sum
%% off by one the segment is dropped as bad_sum, as a corrupted one is.
network_sum_behind_ip4_options_and_padding_test() ->
    Tcp = tcp(?PEER4, ?ME4, 4000, 80, 16, <<"odd">>),
    Header = erx_ip4_wire:encode(#ip4{len = 24 + byte_size(Tcp), df = 1, ttl = 64, p = ?PROTO_TCP,
                                      src = ?PEER4, dst = ?ME4, options = <<1, 1, 1, 0>>}),
    24 = byte_size(Header),
    summed_segment(unicast(<<Header/binary, Tcp/binary, 16#ab, 16#cd, 16#ef>>, ?ETHERTYPE_IP),
                   {tcp, inet, ?ME4, 80, ?PEER4, 4000}).

network_sum_behind_an_ip6_extension_header_test() ->
    Tcp = tcp(?PEER6, ?ME6, 4000, 80, 16, <<"odd">>),
    HopByHop = <<?PROTO_TCP, 0, 1, 4, 0:32>>,
    Header = <<6:4, 0:8, 0:20, (8 + byte_size(Tcp)):16, 0, 64, ?PEER6/binary, ?ME6/binary>>,
    summed_segment(unicast(<<Header/binary, HopByHop/binary, Tcp/binary, 16#ab>>, ?ETHERTYPE_IPV6),
                   {tcp, inet6, ?ME6, 80, ?PEER6, 4000}).

summed_segment({frame, Bytes} = Frame, Key) ->
    View = view(#{demux => demux(holders([{Key, conn}]))}),
    {[conn], {ok, {#tcp{sport = 4000, dport = 80}, <<"odd">>, 0, unicast}}} = owned(classify(Frame, View)),
    Wrong = erx_net_sum:add(network_sum(Bytes), 1),
    ?assertEqual({[conn], {drop, bad_sum}}, owned(erx_net_input:classify({frame, Bytes, Wrong}, View))).

%% A UDP datagram over IPv4 shorter than its IP payload, of an odd length, is checked over its
%% UDP length alone: its sum is the payload's less that of the bytes after it.
network_sum_of_a_udp_datagram_cut_at_its_length_test() ->
    Udp = udp(?PEER4, ?ME4, 4000, 80, <<"odd">>),
    11 = byte_size(Udp),
    Demux = holders([{{udp, inet, any, 80}, sock}]),
    ?assertMatch({[sock], {ok, {datagram, _, _, <<"odd">>}}},
                 owned(classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_UDP, <<Udp/binary, 16#ab, 16#cd, 16#ef>>)),
                                view(#{demux => demux(Demux)})))).

%% An all-zero ICMP message sums to 0, which no sum derived from a nonzero network sum is,
%% and is dropped as bad_sum with its network sum as without it, as FreeBSD's in_cksum drops it.
network_sum_of_an_all_zero_icmp_message_test() ->
    Demux = holders([{{icmp_echo, inet, 0}, pinger}]),
    ?assertEqual({[pinger], {drop, bad_sum}},
                 owned(classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, <<0:64>>)), view(#{demux => demux(Demux)})))).

%% --- Link --------------------------------------------------------------------

other_host_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_UDP, udp(?PEER4, ?ME4, 1, 2, <<>>)),
    ?assertEqual({drop, other_host}, classify({frame, eth(?OTHER_MAC, ?ETHERTYPE_IP, Packet)}, view())).

ethertype_test() ->
    ?assertEqual({drop, ethertype}, classify({frame, eth(?MINE, 16#88b5, <<0:64>>)}, view())).

loopback_frame_is_a_unicast_packet_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_UDP, udp(?PEER4, ?ME4, 1000, 53, <<"q">>)),
    Demux = holders([{{udp, inet, any, 53}, a}]),
    {[a], Verified} = owned(classify({looped, em0, Packet}, loop_view(Demux))),
    ?assertEqual({ok, {datagram, {?PEER4, 1000}, ?ME4, <<"q">>}}, Verified).

%% --- IP ----------------------------------------------------------------------

dhcp_comes_first_test() ->
    %% An offer unicast to an address that is not yet the stack's.
    Offer = ip4(?PEER4, ?FOREIGN4, ?PROTO_UDP, udp(?PEER4, ?FOREIGN4, 67, 68, <<"offer">>)),
    {ok, {dhcp, #ip4{dst = ?FOREIGN4}, #udp{dport = 68}, <<"offer">>}} =
        local(classify(ip4_frame(Offer), view(#{dhcp => true}))),
    %% Without DHCP configured it is one more packet to a stranger.
    ?assertMatch({drop, _}, classify(ip4_frame(Offer), view())).

ip_layer_drop_is_the_verdict_test() ->
    Packet = ip4(?PEER4, ?FOREIGN4, ?PROTO_UDP, udp(?PEER4, ?FOREIGN4, 1, 2, <<>>)),
    {drop, _} = Expected = erx_ip4:input(Packet, unicast, maps:get(ip4, view())),
    ?assertEqual(Expected, classify(ip4_frame(Packet), view())).

fragment_is_local_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_UDP, udp(?PEER4, ?ME4, 1, 2, binary:copy(<<"x">>, 200)), 0, 100),
    ?assertMatch({ok, {fragment, inet, none, unicast, #ip4{mf = 1}, _}},
                 local(classify(ip4_frame(Packet), view()))).

%% A fragmented SYN that came as a link-layer broadcast keeps that cast through reassembly,
%% so the listener row drops the rebuilt datagram as bcast_tcp (tcp_input.c:1288).
reassembled_keeps_the_link_cast_test() ->
    Syn = tcp(?PEER4, ?ME4, 4000, 80, 2, binary:copy(<<"x">>, 200)),
    {ok, Fragments, _} = erx_ip4:output(#{src => ?PEER4, dst => ?ME4, proto => ?PROTO_TCP, ttl => 64, tos => 0},
                                        Syn, 100, gen()),
    View = view(#{demux => demux(holders([{{tcp_listen, inet, ?ME4, 80}, listener}]))}),
    %% The accumulator is the table until the last fragment, then the rebuilt datagram.
    Reassemble = fun(Fragment, Table) ->
                         Frame = {frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, iolist_to_binary(Fragment))},
                         {ok, {fragment, inet, none, broadcast, Ip, Payload}} = local(classify(Frame, View)),
                         case erx_ip4_reass:input(Ip, Payload, broadcast, 0, Table) of
                             {held, Next} -> Next;
                             {done, none, broadcast, Whole, _} -> Whole
                         end
                 end,
    Whole = lists:foldl(Reassemble, erx_ip4_reass:new(), Fragments),
    ?assertEqual({drop, bcast_tcp}, classify({reassembled, inet, none, broadcast, Whole}, View)),
    ?assertMatch({ok, {tcp, _, #tcp{dport = 80}, _, #{credit := listener}}},
                 local(classify({reassembled, inet, none, unicast, Whole}, View))).

%% A rebuilt IPv6 datagram's addresses take the zone it carries, not the view's.
reassembled_takes_its_zone_test() ->
    Packet = ip6(?PEER6, ?LL1, ?PROTO_UDP, udp(?PEER6, ?LL1, 1000, 53, <<"q">>)),
    ?assertMatch({drop, _}, classify({reassembled, inet6, em1, unicast, Packet}, view())),
    ?assertMatch({local, _}, classify({reassembled, inet6, em0, unicast, Packet}, view())).

group_not_joined_is_dropped_test() ->
    Mdns6 = ip6(?LL1, ?MDNS6, ?PROTO_UDP, udp(?LL1, ?MDNS6, 5353, 5353, <<>>)),
    Mdns4 = ip4(?PEER4, ?GROUP4, ?PROTO_UDP, udp(?PEER4, ?GROUP4, 5353, 5353, <<>>)),
    ?assertEqual({drop, not_member},
                 classify({frame, eth(<<16#33, 16#33, 0, 0, 0, 16#fb>>, ?ETHERTYPE_IPV6, Mdns6)}, view())),
    ?assertEqual({drop, not_member},
                 classify({frame, eth(<<1, 0, 16#5e, 0, 0, 16#fb>>, ?ETHERTYPE_IP, Mdns4)}, view())).

%% --- TCP ---------------------------------------------------------------------

syn() -> tcp(?PEER4, ?ME4, 4000, 80, 2, <<>>).

tcp_to_a_connection_is_owned_test() ->
    Data = tcp(?PEER4, ?ME4, 4000, 80, 16, <<"hi">>),
    %% ECN-capable (ECT(0)) IP header: the field passes on with the frame's link cast.
    Packet = ip4(?PEER4, ?ME4, ?PROTO_TCP, Data, 2, 1500),
    Demux = holders([{{tcp, inet, ?ME4, 80, ?PEER4, 4000}, conn}]),
    {[conn], {ok, {#tcp{sport = 4000, dport = 80}, <<"hi">>, 2, unicast}}} =
        owned(classify(ip4_frame(Packet), view(#{demux => demux(Demux)}))).

%% A connection's segment in a link-layer broadcast frame says so, so that the connection's
%% dropwithreset answers it with no RST (tcp_input.c:3450-3451).
tcp_to_a_connection_by_link_broadcast_carries_the_cast_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_TCP, tcp(?PEER4, ?ME4, 4000, 80, 16, <<"hi">>)),
    Demux = holders([{{tcp, inet, ?ME4, 80, ?PEER4, 4000}, conn}]),
    Frame = {frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, Packet)},
    ?assertMatch({[conn], {ok, {#tcp{}, <<"hi">>, 0, broadcast}}},
                 owned(classify(Frame, view(#{demux => demux(Demux)})))).

tcp_to_a_listener_is_local_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_TCP, syn()),
    %% A listener on any address owns it too.
    Demux = holders([{{tcp_listen, inet, any, 80}, listener}]),
    {ok, {tcp, #{src := ?PEER4}, #tcp{dport = 80}, <<>>, #{credit := listener}}} =
        local(classify(ip4_frame(Packet), view(#{demux => demux(Demux)}))).

tcp_to_a_listener_by_link_broadcast_is_dropped_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_TCP, syn()),
    Demux = holders([{{tcp_listen, inet, ?ME4, 80}, listener}]),
    ?assertEqual({drop, bcast_tcp},
                 classify({frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, Packet)}, view(#{demux => demux(Demux)}))).

%% A unicast frame to the subnet's broadcast address finds a listener on any address, and is
%% dropped there too (tcp_input.c:1326-1338), so the syncache never sees it.
tcp_to_a_listener_at_a_broadcast_address_is_dropped_test() ->
    Packet = ip4(?PEER4, ?BCAST4, ?PROTO_TCP, tcp(?PEER4, ?BCAST4, 4000, 80, 2, <<>>)),
    Demux = holders([{{tcp_listen, inet, any, 80}, listener}]),
    ?assertEqual({drop, bcast_tcp}, classify(ip4_frame(Packet), view(#{demux => demux(Demux)}))).

tcp_to_a_closed_port_may_draw_a_reset_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_TCP, syn()),
    ?assertMatch({ok, {tcp, _, #tcp{dport = 80}, <<>>, none}}, local(classify(ip4_frame(Packet), view()))).

tcp_to_a_closed_port_by_broadcast_is_not_answered_test() ->
    Broadcast = ip4(?PEER4, ?BCAST4, ?PROTO_TCP, tcp(?PEER4, ?BCAST4, 4000, 80, 2, <<>>)),
    ?assertEqual({drop, no_reply},
                 classify({frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, Broadcast)}, view())).

%% --- UDP ---------------------------------------------------------------------

udp_packet(Dst) -> ip4(?PEER4, Dst, ?PROTO_UDP, udp(?PEER4, Dst, 1000, 53, <<"q">>)).

udp_to_the_holders_is_owned_test() ->
    %% A socket bound to this address and a socket bound to another: only the first holds it.
    Demux = holders([{{udp, inet, ?ME4, 53}, bound}, {{udp, inet, ?ALSO4, 53}, elsewhere}]),
    {[bound], {ok, {datagram, {?PEER4, 1000}, ?ME4, <<"q">>}}} =
        owned(classify(ip4_frame(udp_packet(?ME4)), view(#{demux => demux(Demux)}))).

udp_to_a_closed_port_may_draw_port_unreachable_test() ->
    ?assertMatch({ok, {udp, _, #udp{dport = 53}, <<1000:16, 53:16, 9:16, _:16, "q">>}}, local(classify(ip4_frame(udp_packet(?ME4)), view()))).

udp_broadcast_to_a_closed_port_is_dropped_test() ->
    ?assertEqual({drop, no_port},
                 classify({frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, udp_packet(?BCAST4))}, view())).

%% --- ICMP and ICMPv6 ---------------------------------------------------------

unreachable() -> icmp4(3, 3, {error, 0}, quote4(?PROTO_TCP)).

icmp_error_to_a_connection_is_owned_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_ICMP, unreachable()),
    Demux = holders([{{tcp, inet, ?ME4, 4000, ?PEER4, 80}, conn}]),
    {[conn], {ok, {report, #icmp4{type = 3}, #{proto := ?PROTO_TCP}}}} =
        owned(classify(ip4_frame(Packet), view(#{demux => demux(Demux)}))).

icmp_error_to_a_listener_is_local_test() ->
    Packet = ip4(?PEER4, ?ME4, ?PROTO_ICMP, unreachable()),
    Demux = holders([{{tcp_listen, inet, ?ME4, 4000}, listener}]),
    ?assertMatch({ok, {icmp, _, #icmp4{type = 3}, _}},
                 local(classify(ip4_frame(Packet), view(#{demux => demux(Demux)})))),
    %% A quote of a datagram no socket sent, or of a protocol with no sockets here.
    ?assertEqual({drop, no_socket}, classify(ip4_frame(Packet), view())),
    Raw = ip4(?PEER4, ?ME4, ?PROTO_ICMP, icmp4(3, 3, {error, 0}, binary:part(ip4(?ME4, ?PEER4, ?PROTO_GRE, <<0:64>>), 0, 28))),
    ?assertEqual({drop, no_socket}, classify(ip4_frame(Raw), view())).

icmp_echo_request_is_local_when_it_may_be_answered_test() ->
    Echo = icmp4(8, 0, {echo, 1, 1}, <<"ping">>),
    ?assertMatch({ok, {icmp, #{reply := true}, #icmp4{type = 8}, <<"ping">>}},
                 local(classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, Echo)), view()))),
    %% An echo to the broadcast address is not answered.
    ?assertEqual({drop, no_reply},
                 classify({frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, ip4(?PEER4, ?BCAST4, ?PROTO_ICMP, Echo))},
                          view())).

%% An echo reply goes to the echo socket holding its identifier, verified, with its
%% sender, TTL, sequence number and data; one for an identifier no socket holds, a
%% truncated one and one with a bad checksum go no further.
icmp_echo_reply_is_owned_by_its_identifier_test() ->
    Demux = holders([{{icmp_echo, inet, 16#e1}, pinger}, {{icmp_echo, inet, 16#e2}, other}]),
    Reply = icmp4(0, 0, {echo, 16#e1, 7}, <<"pong">>),
    ?assertMatch({[pinger], {ok, {echo_reply, ?PEER4, 64, 16#e1, 7, <<"pong">>}}},
                 owned(classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, Reply)),
                                view(#{demux => demux(Demux)})))),
    Stranger = icmp4(0, 0, {echo, 16#e3, 7}, <<"pong">>),
    ?assertEqual({drop, no_socket}, classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, Stranger)),
                                             view(#{demux => demux(Demux)}))),
    ?assertEqual({drop, too_short}, classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, <<0, 0, 0, 0, 0, 16#e1>>)),
                                             view(#{demux => demux(Demux)}))),
    <<Head:2/binary, Sum:16, Tail/binary>> = Reply,
    Corrupt = <<Head/binary, (Sum bxor 1):16, Tail/binary>>,
    ?assertMatch({[pinger], {drop, bad_sum}},
                 owned(classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, Corrupt)),
                                view(#{demux => demux(Demux)})))).

icmp_redirect_and_neighbour_messages_are_local_test() ->
    Redirect = icmp4(5, 0, {redirect, ?ALSO4}, quote4(?PROTO_UDP)),
    ?assertMatch({ok, {icmp, _, #icmp4{type = 5}, _}},
                 local(classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, Redirect)), view()))),
    Ns = icmp6(?LLPEER, ?LL1, 135, 0, {ns, ?LL1, #{}}, <<>>),
    ?assertMatch({ok, {icmp, _, #icmp6{type = 135}, _}},
                 local(classify(ip6_frame(ip6(?LLPEER, ?LL1, ?PROTO_ICMPV6, Ns)), view()))).

other_icmp_types_are_dropped_test() ->
    Advert = icmp4(9, 0, other, <<0:32>>),
    ?assertEqual({drop, icmp_type}, classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_ICMP, Advert)), view())),
    Mld = icmp6(?LLPEER, ?LL1, 143, 0, other, <<0:32>>),
    ?assertEqual({drop, icmp_type}, classify(ip6_frame(ip6(?LLPEER, ?LL1, ?PROTO_ICMPV6, Mld)), view())).

%% --- ARP and other protocols -------------------------------------------------

arp_is_local_test() ->
    Arp = #arp{hrd = 1, op = 1, sha = ?PEER_MAC, spa = ?PEER4, tha = <<0:48>>, tpa = ?ME4},
    ?assertMatch({ok, {arp, #arp{op = 1}}},
                 local(classify({frame, eth(?BROADCAST_MAC, ?ETHERTYPE_ARP, erx_arp_wire:encode(Arp))}, view()))).

other_protocols_draw_an_error_only_when_they_may_be_answered_test() ->
    Gre = ip4(?PEER4, ?ME4, ?PROTO_GRE, <<0:64>>),
    ?assertMatch({ok, {other, #{family := inet}, <<0:64>>}}, local(classify(ip4_frame(Gre), view()))),
    Broadcast = ip4(?PEER4, ?BCAST4, ?PROTO_GRE, <<0:64>>),
    ?assertEqual({drop, no_reply}, classify({frame, eth(?BROADCAST_MAC, ?ETHERTYPE_IP, Broadcast)}, view())),
    Gre6 = ip6(?PEER6, ?ME6, ?PROTO_GRE, <<0:64>>),
    ?assertMatch({ok, {other, #{family := inet6}, _}}, local(classify(ip6_frame(Gre6), view()))),
    %% IPv6's No Next Header is freed unanswered, with the bytes after it (an empty
    %% payload is a jumbogram, dropped before).
    None = ip6(?PEER6, ?ME6, ?PROTO_NONE, <<0:64>>),
    ?assertEqual({drop, no_next_header}, classify(ip6_frame(None), view())).

%% --- Units of the merge ------------------------------------------------------------
%% (docs/design-network-fastpath.md, "The merge, before classification", "What the stack
%% believes"): a unit is classified by its first frame, takes N units of credit, has its
%% first and last frames verified and becomes one segment; a unit whose own claims fail is
%% dropped as malformed.

-define(CONN, {tcp, inet, ?ME4, 80, ?PEER4, 4000}).

%% A frame of the peer's connection from port Sport to 80.
peer_seg(Sport, Seq, Ack, Flags, Payload) ->
    Header = #tcp{sport = Sport, dport = 80, seq = Seq, ack = Ack, flags = Flags, win = 100, urp = 0},
    Seg = iolist_to_binary(erx_tcp_wire:encode(Header, Payload, pseudo(?PEER4, ?ME4, ?PROTO_TCP), sender)),
    eth(?MINE, ?ETHERTYPE_IP, ip4(?PEER4, ?ME4, ?PROTO_TCP, Seg)).

summed(Frame) -> {sum, network_sum(Frame), Frame}.

conn_view() -> view(#{demux => demux(holders([{?CONN, conn}]))}).

three_frames() ->
    [peer_seg(4000, 1 + 100 * I, 2 + I, ?TH_ACK, binary:copy(<<($a + I)>>, 100)) || I <- [0, 1, 2]].

merged_unit_is_one_segment_of_its_connection_test() ->
    [{merged, 3, _, _, Pieces} = Unit] = erx_bytes:tcp_merge(three_frames()),
    {owned, [{_, conn}], Pending} = Verdict = erx_net_input:classify(Unit, conn_view()),
    ?assertEqual(3, erx_net_input:units(Pending)),
    {[conn], {ok, {#tcp{seq = 1, ack = 4, flags = ?TH_ACK}, {merged, 3, Pieces}, 0, unicast}}} = owned(Verdict),
    ?assertEqual(<<(binary:copy(<<"a">>, 100))/binary, (binary:copy(<<"b">>, 100))/binary,
                   (binary:copy(<<"c">>, 100))/binary>>, iolist_to_binary(Pieces)).

%% A frame on its own takes one unit.
lone_frame_takes_one_unit_test() ->
    {owned, _, Pending} = classify(ip4_frame(ip4(?PEER4, ?ME4, ?PROTO_TCP,
                                                  tcp(?PEER4, ?ME4, 4000, 80, 16, <<"x">>))),
                                   conn_view()),
    ?assertEqual(1, erx_net_input:units(Pending)).

%% A count that does not cover the pieces, or exceeds the merge's limit, is refused before
%% any credit is charged.
forged_count_is_malformed_test() ->
    [{merged, 3, First, Last, Pieces}] = erx_bytes:tcp_merge(three_frames()),
    [?assertEqual({drop, malformed}, erx_net_input:classify({merged, N, First, Last, Pieces}, conn_view()))
     || N <- [0, 1, 2, 257, -1, three]].

%% A last frame of another connection: refused at classification when its holders differ,
%% and at verification when one holder holds both.
last_frame_of_another_flow_is_malformed_test() ->
    [First, _, _] = three_frames(),
    Other = peer_seg(4001, 201, 4, ?TH_ACK, binary:copy(<<"c">>, 100)),
    Pieces = [binary:copy(<<"a">>, 100), binary:copy(<<"b">>, 100), binary:copy(<<"c">>, 100)],
    Unit = {merged, 3, summed(First), summed(Other), Pieces},
    Apart = demux(holders([{?CONN, conn}, {{tcp, inet, ?ME4, 80, ?PEER4, 4001}, other}])),
    ?assertEqual({drop, malformed}, erx_net_input:classify(Unit, view(#{demux => Apart}))),
    Entry = #{pid => self(), credit => conn},
    Together = demux(#{?CONN => [Entry], {tcp, inet, ?ME4, 80, ?PEER4, 4001} => [Entry]}),
    {owned, _, Pending} = erx_net_input:classify(Unit, view(#{demux => Together})),
    ?assertEqual({drop, malformed}, erx_net_input:verify(Pending)).

%% The unit's claims Erlang checks: the last frame where the pieces before it end, and its
%% first and last frames merge candidates.
inconsistent_unit_is_malformed_test() ->
    [{merged, 3, First, Last, [P1, P2, P3]}] = erx_bytes:tcp_merge(three_frames()),
    Short = {merged, 3, First, Last, [P1, binary:part(P2, 0, 99), P3]},
    {owned, _, Pending} = erx_net_input:classify(Short, conn_view()),
    ?assertEqual({drop, malformed}, erx_net_input:verify(Pending)),
    Syn = peer_seg(4000, 1, 2, ?TH_ACK bor ?TH_SYN, P1),
    {owned, _, SynPending} = erx_net_input:classify({merged, 3, summed(Syn), Last, [P1, P2, P3]}, conn_view()),
    ?assertEqual({drop, malformed}, erx_net_input:verify(SynPending)).

%% A last frame whose checksum fails drops the unit for its decoder's reason.
unit_with_a_bad_last_checksum_is_dropped_test() ->
    [{merged, 3, First, {sum, Sum, Last}, Pieces}] = erx_bytes:tcp_merge(three_frames()),
    Spoiled = {merged, 3, First, {sum, (Sum + 1) band 16#ffff, Last}, Pieces},
    {owned, _, Pending} = erx_net_input:classify(Spoiled, conn_view()),
    ?assertMatch({drop, _}, erx_net_input:verify(Pending)),
    ?assertNotEqual({drop, malformed}, erx_net_input:verify(Pending)).

%% A middle frame with a bad checksum is no candidate, as FreeBSD merges only frames whose
%% checksums were validated: it ends the unit before it, arrives alone and is dropped by its
%% decoder, and the frame after it arrives alone.
bad_middle_checksum_arrives_alone_test() ->
    [A, <<Head:60/binary, Byte, Rest/binary>>, C] = three_frames(),
    Units = erx_bytes:tcp_merge([A, <<Head/binary, (Byte bxor 1), Rest/binary>>, C]),
    ?assertMatch([{sum, _, _}, {sum, _, _}, {sum, _, _}], Units),
    Verified = [element(2, owned(erx_net_input:classify({frame, F, S}, conn_view()))) || {sum, S, F} <- Units],
    ?assertMatch([{ok, _}, {drop, _}, {ok, _}], Verified).

%% A unit no connection holds is taken as its last frame, whose acknowledgement FreeBSD's
%% merged segment carries, so a closed port answers it once.
unit_to_a_closed_port_is_its_last_frame_test() ->
    [{merged, 3, _, Last, _} = Unit] = erx_bytes:tcp_merge(three_frames()),
    {sum, Sum, LastFrame} = Last,
    ?assertEqual(erx_net_input:classify({frame, LastFrame, Sum}, view()),
                 erx_net_input:classify(Unit, view())),
    {local, Pending} = erx_net_input:classify(Unit, view()),
    ?assertMatch({ok, {tcp, _, #tcp{seq = 201, ack = 4}, _, none}}, erx_net_input:verify(Pending)).
