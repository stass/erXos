%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_net_frame (docs/design-network-stack.md, "Classification and
%% framing"): paths over fixed configurations, the route-free paths of the interface's own
%% packets, hop limits and MTUs, frames that decode back through the codecs, and a
%% connection whose MTU drops in mid-transfer; and frames fed to erx_net_input:classify/2 as
%% the receiving interface sees them: a segment to its peer's connection, the copies of
%% broadcasts and multicasts the stack loops, and an ICMPv6 error through the loopback
%% interface in its address's zone.

-module(erx_net_frame_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_udp_wire.hrl").
-include("erx_net_eth.hrl").
-include("erx_net_frame.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_ip6.hrl").

-define(T0, 1000000000).
-define(MAC0, <<2, 0, 0, 0, 0, 1>>).
-define(MAC1, <<2, 0, 0, 0, 0, 2>>).
-define(PEER, <<2, 0, 0, 0, 0, 9>>).

v4(Text) ->
    {ok, Tuple} = inet:parse_ipv4strict_address(Text),
    list_to_binary(tuple_to_list(Tuple)).

v6(Text) ->
    {ok, Tuple} = inet:parse_ipv6strict_address(Text),
    << <<W:16>> || W <- tuple_to_list(Tuple) >>.

iface(Name, Pid, Mac, Extra) ->
    maps:merge(#{name => Name, pid => Pid, link => ethernet, lladdr => Mac, mtu => 1500,
                 mtu6 => 1500, hlim => 64, finish => none, driver => Pid}, Extra).

addr(Name, Addr, Plen) -> #{addr => Addr, plen => Plen, ifname => Name, flags => []}.

route(Name, Prefix, Plen, Gateway) ->
    #{prefix => Prefix, plen => Plen, ifname => Name, gateway => Gateway, metric => 0}.

%% lo0, eth0 (10.0.0.5/24 and fe80::5, default routes through 10.0.0.1 and fe80::1), eth1
%% (10.1.0.5/16, 10.1.2.0/24 through 10.1.0.254, an IPv6 link MTU of 1280 and a hop limit
%% of 63), and eth2 with no address and no route.
config() ->
    P = self(),
    Ifs = [iface(lo0, P, none, #{link => none, mtu => 16384, mtu6 => 16384}),
           iface(eth0, P, ?MAC0, #{}),
           iface(eth1, P, ?MAC1, #{mtu6 => 1280, hlim => 63}),
           iface(eth2, P, <<2, 0, 0, 0, 0, 3>>, #{})],
    Addrs = [{P, 1, addr(lo0, v4("127.0.0.1"), 8)},
             {P, 1, (addr(eth0, v4("10.0.0.5"), 24))#{broadcast => v4("10.0.0.255")}},
             {P, 2, addr(eth0, v6("fe80::5"), 64)},
             {P, 3, addr(eth0, v6("2001:db8::5"), 64)},
             {P, 1, addr(eth1, v4("10.1.0.5"), 16)},
             {P, 2, addr(eth1, v6("fe80::15"), 64)}],
    Routes = [{P, route(lo0, v4("127.0.0.0"), 8, none)},
              {P, route(eth0, v4("10.0.0.0"), 24, none)},
              {P, route(eth0, v4("0.0.0.0"), 0, v4("10.0.0.1"))},
              {P, route(eth0, v6("fe80::"), 64, none)},
              {P, route(eth0, v6("2001:db8::"), 64, none)},
              {P, route(eth0, v6("::"), 0, v6("fe80::1"))},
              {P, route(eth1, v4("10.1.0.0"), 16, none)},
              {P, route(eth1, v4("10.1.2.0"), 24, v4("10.1.0.254"))},
              {P, route(eth1, v6("fe80::"), 64, none)}],
    erx_net_frame:snapshot(Ifs, Addrs, Routes).

path(Dst) -> path(Dst, #{}).
path(Dst, Opts) ->
    {ok, Path} = erx_net_frame:path(Dst, Opts, config()),
    Path.

via(#{iface := #{name := Name}, next_hop := Hop, link := Link, src := Src}) ->
    {Name, Hop, Link, Src}.

%% --- Paths --------------------------------------------------------------------

gateway_and_longest_match_test() ->
    ?assertEqual({eth0, v4("10.0.0.1"), neighbour, v4("10.0.0.5")}, via(path(v4("8.8.8.8")))),
    ?assertEqual({eth0, v4("10.0.0.9"), neighbour, v4("10.0.0.5")}, via(path(v4("10.0.0.9")))),
    %% 10.1.2.0/24 through a gateway beats eth1's on-link /16.
    ?assertEqual({eth1, v4("10.1.0.254"), neighbour, v4("10.1.0.5")}, via(path(v4("10.1.2.3")))),
    ?assertEqual({eth1, v4("10.1.9.9"), neighbour, v4("10.1.0.5")}, via(path(v4("10.1.9.9")))),
    ?assertEqual({eth0, v6("fe80::1"), neighbour, v6("2001:db8::5")},
                 via(path(v6("2001:db8:9::1")))).

loopback_for_an_address_of_the_stack_test() ->
    %% The link header on the loopback interface is the zone of the address.
    ?assertEqual({lo0, v4("10.0.0.5"), {fixed, eth0}, v4("10.0.0.5")}, via(path(v4("10.0.0.5")))),
    ?assertEqual({lo0, v6("fe80::5"), {fixed, eth0}, v6("fe80::5")},
                 via(path({v6("fe80::5"), eth0}))),
    %% The same address in another zone is no address of the stack.
    ?assertEqual({eth1, v6("fe80::5"), neighbour, v6("fe80::15")},
                 via(path({v6("fe80::5"), eth1}))),
    #{iface := #{mtu := 16384}} = path(v4("127.0.0.1")).

zoned_destinations_take_their_zone_test() ->
    ?assertEqual({eth1, v6("fe80::9"), neighbour, v6("fe80::15")}, via(path({v6("fe80::9"), eth1}))),
    ?assertEqual({eth0, v6("fe80::9"), neighbour, v6("fe80::5")}, via(path({v6("fe80::9"), eth0}))),
    Snap = config(),
    %% A scoped address without its zone, or with a zone that contradicts `via`, leads nowhere.
    ?assertEqual({error, enetunreach}, erx_net_frame:path(v6("fe80::9"), #{}, Snap)),
    ?assertEqual({error, enetunreach},
                 erx_net_frame:path({v6("ff02::1"), eth0}, #{via => eth1}, Snap)),
    ?assertEqual({error, enetunreach}, erx_net_frame:path({v6("fe80::9"), eth2}, #{}, Snap)),
    %% eth0's link-local source does not leave through eth1, and interface-local
    %% multicast does not reach the wire.
    ?assertEqual({error, eaddrnotavail},
                 erx_net_frame:path({v6("fe80::9"), eth1}, #{src => v6("fe80::5")}, Snap)),
    ?assertEqual({error, enetunreach}, erx_net_frame:path(v6("ff01::1"), #{via => eth0}, Snap)).

refusals_test() ->
    Snap = config(),
    P = self(),
    %% No IPv6 route through eth1 off its link, and a route on eth2 with no address there.
    Bare = erx_net_frame:snapshot([iface(eth2, P, ?MAC0, #{})], [],
                                  [{P, route(eth2, v4("0.0.0.0"), 0, v4("10.9.0.1"))}]),
    ?assertEqual({error, enetunreach}, erx_net_frame:path(v6("2001:db8::1"), #{}, Bare)),
    ?assertEqual({error, eaddrnotavail}, erx_net_frame:path(v4("8.8.8.8"), #{}, Bare)),
    ?assertEqual({error, enetunreach}, erx_net_frame:path(<<1, 2, 3>>, #{}, Snap)).

snapshot_keeps_only_the_current_incarnation_test() ->
    Old = spawn(fun() -> ok end),
    P = self(),
    Snap = erx_net_frame:snapshot([iface(eth0, P, ?MAC0, #{})],
                                  [{Old, 1, addr(eth0, v4("10.0.0.7"), 24)},
                                   {P, 2, addr(eth0, v4("10.0.0.5"), 24)}],
                                  [{Old, route(eth0, v4("0.0.0.0"), 0, v4("10.0.0.1"))},
                                   {P, route(eth0, v4("10.0.0.0"), 24, none)}]),
    {ok, Path} = erx_net_frame:path(v4("10.0.0.9"), #{}, Snap),
    ?assertEqual(v4("10.0.0.5"), maps:get(src, Path)),
    ?assertEqual({error, enetunreach}, erx_net_frame:path(v4("8.8.8.8"), #{}, Snap)).

route_free_paths_of_the_interface_test() ->
    Dhcp = path(v4("255.255.255.255"), #{via => eth2, src => v4("0.0.0.0"), broadcast => true}),
    ?assertEqual({eth2, v4("255.255.255.255"), {fixed, <<16#ffffffffffff:48>>}, v4("0.0.0.0")},
                 via(Dhcp)),
    Rs = path(v6("ff02::2"), #{via => eth2, src => v6("::"), hlim => 255}),
    ?assertEqual({eth2, v6("ff02::2"), {fixed, <<16#33, 16#33, 0, 0, 0, 2>>}, v6("::")}, via(Rs)),
    ?assertEqual(255, maps:get(hlim, Rs)),
    Dad = path(v6("ff02::1:ff12:3456"), #{via => eth2, src => v6("::"), hlim => 255}),
    ?assertEqual({fixed, <<16#33, 16#33, 16#ff, 16#12, 16#34, 16#56>>}, maps:get(link, Dad)),
    %% A socket's limited broadcast takes a route, and eth2 alone has none.
    P = self(),
    Eth2 = erx_net_frame:snapshot([iface(eth2, P, ?MAC0, #{})], [], []),
    ?assertEqual({error, enetunreach}, erx_net_frame:path(v4("255.255.255.255"), #{broadcast => true}, Eth2)).

%% ip_output.c:661-673: a broadcast needs the sender's SO_BROADCAST, an interface that can
%% broadcast, and fits the MTU unfragmented, where a unicast datagram is fragmented.
broadcast_refusals_test() ->
    ?assertEqual({error, eacces}, erx_net_frame:path(v4("10.0.0.255"), #{}, config())),
    ?assertEqual({error, eacces}, erx_net_frame:path(v4("255.255.255.255"), #{}, config())),
    ?assertEqual({error, eacces},
                 erx_net_frame:path(v4("255.255.255.255"), #{via => eth2}, config())),
    P = self(),
    Lo = erx_net_frame:snapshot([iface(lo0, P, none, #{link => none, mtu => 16384})],
                                [{P, 1, addr(lo0, v4("127.0.0.1"), 8)}],
                                [{P, route(lo0, v4("0.0.0.0"), 0, none)}]),
    ?assertEqual({error, eaddrnotavail},
                 erx_net_frame:path(v4("255.255.255.255"), #{broadcast => true}, Lo)),
    Bcast = path(v4("10.0.0.255"), #{broadcast => true}),
    ?assert(maps:get(broadcast, Bcast)),
    ?assertNot(maps:get(broadcast, path(v4("10.0.0.9")))),
    Big = binary:copy(<<0>>, 1600),
    ?assertEqual({error, emsgsize}, erx_net_frame:udp(Bcast, 1, 2, Big, gen())),
    ?assertEqual({error, emsgsize}, erx_net_frame:ip(Bcast, 1, Big, gen())),
    {ok, [_], _} = erx_net_frame:udp(Bcast, 1, 2, binary:copy(<<0>>, 1472), gen()),
    {ok, [_, _], _} = erx_net_frame:udp(path(v4("10.0.0.9")), 1, 2, Big, gen()).

hop_limits_mtus_and_first_address_test() ->
    Group = path(v4("224.0.0.251"), #{via => eth0}),
    ?assertEqual({1, 1500, {fixed, <<1, 0, 16#5e, 0, 0, 16#fb>>}},
                 {maps:get(hlim, Group), maps:get(mtu, Group), maps:get(link, Group)}),
    %% eth1's own hop limit is 63; a multicast takes 1 all the same.
    ?assertEqual(1, maps:get(hlim, path({v6("ff02::1"), eth1}))),
    #{hlim := 63, mtu := 1280} = path({v6("fe80::9"), eth1}),
    #{hlim := 64, mtu := 1500} = path(v4("10.1.9.9")),
    %% 23 bits of the group: 239.255.0.1 maps to 01:00:5e:7f:00:01.
    ?assertEqual({fixed, <<1, 0, 16#5e, 16#7f, 0, 1>>},
                 maps:get(link, path(v4("239.255.0.1"), #{via => eth0}))),
    ?assertEqual({fixed, <<16#ffffffffffff:48>>}, maps:get(link, path(v4("10.0.0.255"), #{broadcast => true}))),
    %% No prefix of eth0 holds the gateway: the first address eth0 added.
    P = self(),
    Snap = erx_net_frame:snapshot([iface(eth0, P, ?MAC0, #{})],
                                  [{P, 2, addr(eth0, v4("192.168.9.9"), 24)},
                                   {P, 1, addr(eth0, v4("10.0.0.5"), 24)}],
                                  [{P, route(eth0, v4("0.0.0.0"), 0, v4("172.16.0.1"))},
                                   {P, route(eth0, v4("192.168.9.0"), 24, none)}]),
    {ok, #{src := First}} = erx_net_frame:path(v4("8.8.8.8"), #{}, Snap),
    ?assertEqual(v4("10.0.0.5"), First),
    {ok, #{src := Matching}} = erx_net_frame:path(v4("192.168.9.1"), #{}, Snap),
    ?assertEqual(v4("192.168.9.9"), Matching).

%% --- Packets and frames -------------------------------------------------------

segment(Payload, Ecn, Df) ->
    {#tcp{sport = 4000, dport = 80, seq = 1, ack = 2, flags = ?TH_ACK, win = 100, urp = 0,
          opts = #tcp_opts{ts = {5, 6}}},
     #{ecn => Ecn, df => Df}, Payload}.

gen() -> erx_net_rand:new(<<7:128>>).

%% The Ethernet header and the IP packet of a frame.
eth(Frame) ->
    {ok, Eth, Packet} = erx_net_eth:decode(iolist_to_binary(Frame)),
    {Eth, Packet}.

tcp_frames_decode_back_test() ->
    Path = path(v4("8.8.8.8"), #{tos => 16#b8}),
    Data = [<<"abc">>, <<"defg">>],
    {ok, [P1, P2], Gen} = erx_net_frame:tcp(Path, [segment(Data, 2, true), segment([], 1, false)],
                                            gen()),
    %% The payload binaries go into the packet as they were given.
    ?assert(lists:member(<<"abc">>, lists:flatten(P1))),
    {send, [F1, F2]} = erx_net_frame:address(Path, {?PEER, stale}, [P1, P2]),
    {#eth{dst = ?PEER, src = ?MAC0, type = ?ETHERTYPE_IP}, B1} = eth(F1),
    {ok, #ip4{tos = Tos1, df = 1, id = 0, ttl = 64, p = 6, src = Src, dst = Dst}, S1} =
        erx_ip4_wire:decode(B1),
    ?assertEqual({16#b8 bor 2, v4("10.0.0.5"), v4("8.8.8.8")}, {Tos1, Src, Dst}),
    {ok, Tcp, <<"abcdefg">>} = erx_tcp_wire:decode(erx_ip4_wire:pseudo_sum(Src, Dst, byte_size(S1), 6), S1),
    ?assertEqual(element(1, segment(Data, 2, true)), Tcp),
    {_, B2} = eth(F2),
    {ok, #ip4{tos = Tos2, df = 0, id = Id}, _} = erx_ip4_wire:decode(B2),
    ?assertEqual(16#b8 bor 1, Tos2),
    {<<Expected:16>>, Gen} = erx_net_rand:bytes(2, gen()),
    ?assertEqual(Expected, Id),
    %% With no neighbour row the packets go to the interface unchanged.
    ?assertEqual({resolve, [P1, P2]}, erx_net_frame:address(Path, none, [P1, P2])).

ipv6_and_udp_frames_decode_back_test() ->
    Path = path(v6("2001:db8:9::1"), #{tclass => 16#20, flow => 5}),
    {ok, [P], _} = erx_net_frame:tcp(Path, [segment([<<"x">>], 3, false)], gen()),
    {send, [F]} = erx_net_frame:address(Path, {?PEER, fresh}, [P]),
    {#eth{type = ?ETHERTYPE_IPV6}, B} = eth(F),
    {ok, #ip6{tclass = 16#23, flow = 5, hlim = 64, src = Src, dst = Dst, proto = 6}, S} =
        erx_ip6_wire:decode(B),
    {ok, _, <<"x">>} = erx_tcp_wire:decode(erx_ip6_wire:pseudo_sum(Src, Dst, byte_size(S), 6), S),
    Mdns = path({v6("ff02::fb"), eth0}),
    {ok, [U], _} = erx_net_frame:udp(Mdns, 5353, 5353, [<<"q">>], gen()),
    {send, [G]} = erx_net_frame:address(Mdns, none, [U]),
    {#eth{dst = <<16#33, 16#33, 0, 0, 0, 16#fb>>}, UB} = eth(G),
    {ok, #ip6{hlim = 1, src = USrc, dst = UDst, proto = 17}, UD} = erx_ip6_wire:decode(UB),
    ?assertEqual(v6("fe80::5"), USrc),
    {ok, #udp{sport = 5353, dport = 5353}, <<"q">>} =
        erx_udp_wire:decode(inet6, erx_ip6_wire:pseudo_sum(USrc, UDst, byte_size(UD), 17), UD).

loopback_frames_carry_the_zone_test() ->
    %% An ICMPv6 error to the stack's own link-local address crosses the loopback
    %% interface in that address's zone.
    Path = path({v6("fe80::5"), eth0}),
    {ok, [P], _} = erx_net_frame:ip(Path, 58, <<1, 3, 0, 0>>, gen()),
    ?assertEqual({send, [{eth0, P}]}, erx_net_frame:address(Path, none, [P])).

emsgsize_never_raises_test() ->
    Path = path({v6("fe80::9"), eth1}),
    Over = path(v4("8.8.8.8")),
    Big = binary:copy(<<0>>, 1600),
    ?assertEqual({error, emsgsize}, erx_net_frame:tcp(Over, [segment([Big], 0, true)], gen())),
    ?assertEqual({error, emsgsize},
                 erx_net_frame:tcp(Over, [segment([binary:copy(<<0>>, 70000)], 0, false)], gen())),
    ?assertEqual({error, emsgsize},
                 erx_net_frame:udp(Over, 1, 2, binary:copy(<<0>>, 65530), gen())),
    %% IPv6 without don't-fragment fragments a segment over its 1280-byte link MTU.
    {ok, [_, _], _} = erx_net_frame:tcp(Path, [segment([Big], 0, false)], gen()).

%% --- Delayed checksums ----------------------------------------------------------

%% Path with its interface's driver finishing checksums in its copy.
finishing(#{iface := If} = Path) -> Path#{iface := If#{finish := copy}}.

%% Over an interface that finishes, each segment's packet is delayed, with the segment
%% after the IP header and th_sum 16 bytes into it, and its field holding the
%% pseudo-header's sum with the segment's length; finished, packet and frame are the bytes
%% the sender's own checksum gives, from the same generator. Payloads of odd and even
%% lengths, in pieces, over IPv4 and IPv6.
delayed_segments_finish_to_the_senders_bytes_test() ->
    Segments = [segment([<<"abc">>, <<"defg">>], 2, true), segment([], 1, false),
                segment([<<"x">>, <<>>, <<"yz">>], 0, true)],
    [begin
         Path = path(Dst),
         {ok, Plain, Gen} = erx_net_frame:tcp(Path, Segments, gen()),
         {ok, Delayed, Gen} = erx_net_frame:tcp(finishing(Path), Segments, gen()),
         [begin
              {csum, Start, 16, Bytes} = D,
              ?assertEqual(Header, Start),
              <<_:Start/binary, Segment/binary>> = iolist_to_binary(Bytes),
              <<_:16/binary, Field:16, _/binary>> = Segment,
              ?assertEqual(erx_net_sum:add(pseudo(Path), byte_size(Segment)), Field),
              ?assertEqual(iolist_to_binary(P), erx_net_frame:finish(D))
          end || {P, D} <- lists:zip(Plain, Delayed)],
         {send, PlainFrames} = erx_net_frame:address(Path, {?PEER, stale}, Plain),
         {send, Frames} = erx_net_frame:address(finishing(Path), {?PEER, stale}, Delayed),
         ?assertEqual([{csum, 14 + Header, 16} || _ <- Frames],
                      [{csum, Start, Field} || {csum, Start, Field, _} <- Frames]),
         ?assertEqual([iolist_to_binary(F) || F <- PlainFrames],
                      [erx_net_frame:finish(F) || F <- Frames])
     end || {Dst, Header} <- [{v4("8.8.8.8"), 20}, {v6("2001:db8:9::1"), 40}]].

%% The loopback interface has nothing below it that finishes, so link/3 hands it a delayed
%% packet finished.
loopback_gets_delayed_packets_finished_test() ->
    Path = path(v4("8.8.8.8")),
    {ok, [P], _} = erx_net_frame:tcp(Path, [segment([<<"lo">>], 0, true)], gen()),
    {ok, [D], _} = erx_net_frame:tcp(finishing(Path), [segment([<<"lo">>], 0, true)], gen()),
    ?assertEqual([{lo0, iolist_to_binary(P)}], erx_net_frame:link(#{link => none}, lo0, [D])).

pseudo(#{family := inet, src := Src, dst := Dst}) -> erx_ip4_wire:pseudo_sum(Src, Dst, 0, 6);
pseudo(#{family := inet6, src := Src, dst := Dst}) -> erx_ip6_wire:pseudo_sum(Src, Dst, 0, 6).

%% A segment that IP fragments leaves with its checksum finished, since no transport can
%% finish it across fragments: the fragments are those of an interface that does not finish.
fragmented_segments_are_finished_by_the_sender_test() ->
    Path = path({v6("fe80::9"), eth1}),
    Segments = [segment([binary:copy(<<"z">>, 1600)], 0, false)],
    {ok, [_, _] = Fragments, Gen} = erx_net_frame:tcp(Path, Segments, gen()),
    ?assertEqual({ok, Fragments, Gen}, erx_net_frame:tcp(finishing(Path), Segments, gen())).

%% finish/1 takes only even offsets with the field inside the frame.
finish_refusals_test() ->
    Frame = binary:copy(<<1>>, 40),
    ?assertEqual(<<1, 1, 16#fc, 16#fc, 1, 1>>,
                 erx_net_frame:finish({csum, 0, 2, binary:copy(<<1>>, 6)})),
    [?assertError(badarg, erx_net_frame:finish({csum, Start, Field, Frame}))
     || {Start, Field} <- [{1, 2}, {2, 1}, {38, 2}, {40, 0}, {42, 0}, {0, 39}, {-2, 2}]].

%% --- A connection over a path ------------------------------------------------

conn(Family, Local, Remote, Bytes) ->
    T0 = erx_tcp_user:new(#{family => Family, local => {Local, 4000}, remote => {Remote, 80},
                            iss => 1000, ts_offset => 7, cc => erx_tcp_cc_newreno,
                            loss => erx_tcp_loss_dupack, snd_hiwat => 1 bsl 20,
                            rcv_hiwat => 65536, gen => erx_net_rand:new(<<0:128>>), now => ?T0}),
    #tcb{ccv = Ccv} = T0,
    T0#tcb{state = established, irs = 5000, rcv_nxt = 5001, rcv_adv = 5001 + 65536,
           snd_una = 1001, snd_nxt = 1001, snd_max = 1001, snd_wnd = 65535,
           max_sndwnd = 65535, maxseg = 1460, ccv = Ccv#ccv{cwnd = 100000, maxseg = 1460},
           sendlog = erx_tcp_sendlog:new(1001), wscale = {0, 0}, ts = off, sack = off,
           sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(), binary:copy(<<"x">>, Bytes))}.

mtu_drop_mid_transfer_test() ->
    Small = erx_net_frame:snapshot([iface(eth0, self(), ?MAC0, #{mtu => 1280})],
                                   [{self(), 1, addr(eth0, v4("10.0.0.5"), 24)}],
                                   [{self(), route(eth0, v4("10.0.0.0"), 24, none)}]),
    {ok, Path} = erx_net_frame:path(v4("10.0.0.2"), #{}, Small),
    {T1, Out1} = erx_tcp_output:output(conn(inet, v4("10.0.0.5"), v4("10.0.0.2"), 2920),
                                       #tcp_ctx{now = ?T0, credit = 4, mtu = 1500}),
    ?assertEqual([1460, 1460], [iolist_size(D) || {_, _, D} <- lists:flatmap(fun erx_tcp_output:segments/1, Out1)]),
    %% The interface's MTU drops to 1280: the next full segment is 1280 less the headers.
    More = T1#tcb{sndbuf = erx_tcp_sndbuf:append(T1#tcb.sndbuf, binary:copy(<<"y">>, 2480))},
    {T2, Out2} = erx_tcp_output:output(More, #tcp_ctx{now = ?T0, credit = 4, mtu = 1280}),
    ?assertEqual([1240, 1240], [iolist_size(D) || {_, _, D} <- lists:flatmap(fun erx_tcp_output:segments/1, Out2)]),
    ?assertEqual(1240, T2#tcb.maxseg),
    {ok, Packets, _} = erx_net_frame:tcp(Path, Out2, gen()),
    ?assertEqual([1280, 1280], [iolist_size(P) || P <- Packets]).

ipv6_segments_carry_no_dont_fragment_test() ->
    T = conn(inet6, v6("2001:db8::5"), v6("2001:db8::9"), 100),
    {_, [{_, #{df := false}, _}]} = erx_tcp_output:output(T, #tcp_ctx{now = ?T0, credit = 1,
                                                                       mtu = 1500}).

%% --- Frames classified by the interface that receives them -------------------

%% The interface that receives a frame: its link-layer address, addresses and groups, and
%% the demultiplexing table of the sockets and connections it holds, key to credit.
rx_view(Link, Mac, Ip4, Ip6, Groups, Table) ->
    Loop = Link =:= none,
    Zone = case Loop of
               true -> lo0;
               false -> eth0
           end,
    #{link => Link, lladdr => Mac,
      ip4 => #{addrs => Ip4, broadcasts => [v4("10.0.0.255")], loopback => Loop},
      ip6 => #{addrs => Ip6, notready => [], loopback => Loop, zone => Zone},
      groups => Groups, dhcp => false,
      demux => fun(Key) -> [#{pid => self(), credit => Credit} || {K, Credit} <- Table, K =:= Key] end}.

frame_then_classify_round_trip_test() ->
    Data = [<<"abc">>, <<"defg">>],
    lists:foreach(
      fun({Dst, Family}) ->
              Path = path(Dst),
              #{src := Src} = Path,
              {ok, [P], _} = erx_net_frame:tcp(Path, [segment(Data, 2, true)], gen()),
              {send, [Frame]} = erx_net_frame:address(Path, {?PEER, fresh}, [P]),
              %% The peer's own view: its address, and the connection from this host.
              View = rx_view(ethernet, ?PEER, [Dst], [Dst], [], [{{tcp, Family, Dst, 80, Src, 4000}, peer}]),
              {owned, [{_, peer}], Pending} = erx_net_input:classify({frame, iolist_to_binary(Frame), none}, View),
              ?assertEqual({ok, {element(1, segment(Data, 2, true)), <<"abcdefg">>, 2, unicast}},
                           erx_net_input:verify(Pending))
      end, [{v4("10.0.0.9"), inet}, {v6("2001:db8:9::1"), inet6}]).

%% The copy of a socket's broadcast or multicast the stack hands back to the interface it
%% went out through, as a frame from its driver, finds the local socket bound to the port.
looped_broadcast_and_multicast_find_a_local_socket_test() ->
    Addrs6 = [v6("2001:db8::5"), {v6("fe80::5"), eth0}],
    lists:foreach(
      fun({Dst, Opts, Family, Groups}) ->
              Path = path(Dst, Opts),
              {ok, [P], _} = erx_net_frame:udp(Path, 5353, 5353, [<<"q">>], gen()),
              {send, [Frame]} = erx_net_frame:address(Path, none, [P]),
              Bytes = iolist_to_binary(Frame),
              Table = [{{udp, Family, any, 5353}, socket}],
              Joined = rx_view(ethernet, ?MAC0, [v4("10.0.0.5")], Addrs6, Groups, Table),
              {owned, [{_, socket}], Pending} = erx_net_input:classify({frame, Bytes, none}, Joined),
              #{src := Src, dst := To} = Path,
              Zone = fun(Addr) -> erx_net_addr:zoned(Addr, eth0) end,
              ?assertEqual({ok, {datagram, {Zone(Src), 5353}, Zone(To), <<"q">>}}, erx_net_input:verify(Pending)),
              %% A group the interface has not joined is dropped from the copy as from the wire.
              Unjoined = rx_view(ethernet, ?MAC0, [v4("10.0.0.5")], Addrs6, [], Table),
              case Groups of
                  [] -> ok;
                  [_] -> ?assertEqual({drop, not_member}, erx_net_input:classify({frame, Bytes, none}, Unjoined))
              end
      end, [{v4("10.0.0.255"), #{broadcast => true}, inet, []},
            {v4("224.0.0.251"), #{via => eth0}, inet, [v4("224.0.0.251")]},
            {{v6("ff02::fb"), eth0}, #{}, inet6, [v6("ff02::fb")]}]).

%% An ICMPv6 error to one of the stack's own link-local addresses crosses the loopback
%% interface in that address's zone and finds the socket its quote names.
looped_icmpv6_error_finds_the_socket_its_quote_names_test() ->
    Local = v6("fe80::5"),
    Peer = v6("fe80::9"),
    {ok, [Sent], _} = erx_net_frame:udp(path({Peer, eth0}), 4000, 53, [<<"q">>], gen()),
    Quote = binary:part(iolist_to_binary(Sent), 0, 48),
    Out = path({Local, eth0}),
    #{src := Local, dst := Local} = Out,
    Message = erx_icmp6_wire:encode(#icmp6{type = 1, code = 4, msg = {error, 0}}, Quote, {Local, Local}),
    {ok, [P], _} = erx_net_frame:ip(Out, 58, Message, gen()),
    {send, [{Zone, Packet}]} = erx_net_frame:address(Out, none, [P]),
    View = rx_view(none, none, [v4("10.0.0.5")], [v6("2001:db8::5"), {Local, eth0}, {v6("fe80::15"), eth1}], [],
                   [{{udp, inet6, {Local, eth0}, 4000, {Peer, eth0}, 53}, socket}]),
    {owned, [{_, socket}], Pending} = erx_net_input:classify({frame, Zone, iolist_to_binary(Packet)}, View),
    ?assertMatch({ok, {report, #icmp6{type = 1, code = 4}, #{proto := 17}}}, erx_net_input:verify(Pending)),
    %% The same bytes in another zone are an error to no address of the stack.
    ?assertMatch({drop, _}, erx_net_input:classify({frame, eth1, iolist_to_binary(Packet)}, View)).

%% A run (docs/design-network-fastpath.md, "A run") gives the bytes of its segments encoded
%% one by one, as erx_tcp_output:segments/1 cuts it: over IPv4 and IPv6, with and without
%% timestamps, PSH and FIN, payloads in random pieces and the last frame short, as one
%% #run{} that cut/1 cuts when the interface has a finisher and as cut/1's packets when it
%% has none, through link/3 to Ethernet frames and to the loopback; and fragmented as its
%% segments would be when a frame is over the MTU, or refused as they would be.
runs_give_the_bytes_of_their_segments_test() ->
    rand:seed(exsss, {6, 2, 1}),
    lists:foreach(fun(_) -> run_case(random_run()) end, lists:seq(1, 600)).

run_case({Path, Run}) ->
    Segments = erx_tcp_output:segments(Run),
    case {erx_net_frame:tcp(Path, Segments, gen()), erx_net_frame:tcp(Path, [Run], gen())} of
        {{ok, Expected, _}, {ok, Got, _}} ->
            ?assertEqual(finished(Expected), finished(Got)),
            ?assertEqual(erx_net_frame:units(Expected), erx_net_frame:units(Got)),
            If = maps:get(iface, Path),
            ?assertEqual(finished(erx_net_frame:link(If, <<2, 0, 0, 0, 0, 9>>, Expected)),
                         finished(erx_net_frame:link(If, <<2, 0, 0, 0, 0, 9>>, Got))),
            Loop = fun(Packets) -> [{Z, iolist_to_binary(P)}
                                    || {Z, P} <- erx_net_frame:link(If#{link := none}, eth0, Packets)]
                   end,
            ?assertEqual(Loop(Expected), Loop(Got));
        {Expected, Got} ->
            ?assertEqual(Expected, Got)
    end.

%% A random run over a random path: the family, the finisher, the MTU (a frame over it
%% sometimes), the type of service and ECN, the flags, the timestamps or none, the segment
%% size and a payload of 1 to 5 frames in up to 8 pieces.
random_run() ->
    Family = pick([inet, inet6]),
    Dst = case Family of inet -> v4("8.8.8.8"); inet6 -> v6("2001:db8:9::1") end,
    Path0 = path(Dst, #{tos => pick([0, 16#b8, 16#ff])}),
    #{iface := If} = Path0,
    Seg = rand:uniform(1460),
    Path = Path0#{iface := If#{finish := pick([none, copy])},
                  mtu := pick([1500, 1500, 1500, 9000, 39 + Seg, 60 + Seg - 1])},
    Frames = rand:uniform(5),
    Size = (Frames - 1) * Seg + rand:uniform(Seg),
    Flags = ?TH_ACK bor pick([0, ?TH_PUSH, ?TH_FIN, ?TH_PUSH bor ?TH_FIN, ?TH_CWR bor ?TH_ECE]),
    Ts = pick([none, {rand:uniform(1 bsl 32) - 1, rand:uniform(1 bsl 32) - 1}]),
    Header = #tcp{sport = rand:uniform(65535), dport = 80, seq = rand:uniform(1 bsl 32) - 1,
                  ack = rand:uniform(1 bsl 32) - 1, flags = Flags, win = rand:uniform(65536) - 1,
                  urp = 0, opts = #tcp_opts{ts = Ts}},
    Marks = #{ecn => pick([0, 1, 2]), df => Family =:= inet orelse pick([true, false]), seg => Seg},
    {Path, {Header, Marks, pieces(crypto:strong_rand_bytes(Size), rand:uniform(8))}}.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

pieces(Bin, 1) -> [Bin];
pieces(Bin, N) ->
    At = rand:uniform(byte_size(Bin) + 1) - 1,
    <<Head:At/binary, Tail/binary>> = Bin,
    [Head | pieces(Tail, N - 1)].

%% The bytes of packets or frames, each run cut and each delayed checksum finished.
finished(Packets) ->
    lists:flatmap(fun(#run{} = Run) -> [iolist_to_binary(F) || F <- erx_net_frame:cut(Run)];
                     ({csum, _, _, _} = Delayed) -> [erx_net_frame:finish(Delayed)];
                     (Packet) -> [iolist_to_binary(Packet)]
                  end, Packets).

%% A run's tail cuts to the run's last frames, and the credit counts a run by its frames.
run_tail_cuts_to_the_last_frames_test() ->
    rand:seed(exsss, {6, 2, 2}),
    lists:foreach(
      fun(_) ->
              {Path, Segment} = random_run(),
              case erx_net_frame:tcp(Path#{iface := (maps:get(iface, Path))#{finish := copy},
                                           mtu := 9000}, [Segment], gen()) of
                  {ok, [#run{} = Run], _} ->
                      Frames = erx_net_frame:cut(Run),
                      K = erx_net_frame:frames(Run),
                      ?assertEqual(length(Frames), K),
                      [?assertEqual([iolist_to_binary(F) || F <- lists:nthtail(N, Frames)],
                                    [iolist_to_binary(F)
                                     || F <- erx_net_frame:cut(erx_net_frame:run_tail(Run, N))])
                       || N <- lists:seq(1, K - 1)],
                      ?assertError(_, erx_net_frame:run_tail(Run, K));
                  {ok, _, _} ->
                      ok
              end
      end, lists:seq(1, 200)),
    ?assertEqual(1, erx_net_frame:frames(<<"plain">>)).

%% The template is built once for a connection's path, ports, ECN field and timestamps, and
%% again when one of them differs; a run with options other than the timestamps, or with an
%% urgent pointer, goes as its segments.
template_cache_and_irregular_runs_test() ->
    Path0 = path(v4("8.8.8.8"), #{}),
    #{iface := If} = Path0,
    Path = Path0#{iface := If#{finish := copy}},
    {Header, Marks, _} = segment([], 0, true),
    Run = {Header, Marks#{seg => 100}, [binary:copy(<<"x">>, 250)]},
    {ok, [#run{template = T1}], _, Cache} = erx_net_frame:tcp(Path, [Run], gen(), erx_net_frame:no_template()),
    {ok, [#run{template = T2}], _, Cache} = erx_net_frame:tcp(Path, [Run], gen(), Cache),
    ?assert(T1 =:= T2),
    {ok, [#run{template = T3}], _, Cache3} =
        erx_net_frame:tcp(Path, [setelement(2, Run, Marks#{seg => 100, ecn => 2})], gen(), Cache),
    ?assertNotEqual(T1, T3),
    ?assertNotEqual(Cache, Cache3),
    Sacked = setelement(1, Run, Header#tcp{opts = #tcp_opts{ts = {5, 6}, sacks = [{1, 2}]}}),
    Urgent = setelement(1, Run, Header#tcp{urp = 7}),
    [?assertMatch({ok, [_, _, _], _}, erx_net_frame:tcp(Path, [Irregular], gen()))
     || Irregular <- [Sacked, Urgent]],
    [?assertNot(lists:any(fun(P) -> is_record(P, run) end,
                          element(2, erx_net_frame:tcp(Path, [Irregular], gen()))))
     || Irregular <- [Sacked, Urgent]],
    %% A cached template serves only a run of the same shape: with the cache of a regular
    %% run, one with SACK blocks or an IPv4 one without don't-fragment goes as segments.
    Fragmentable = setelement(2, Run, Marks#{seg => 100, df => false}),
    [?assertNot(lists:any(fun(P) -> is_record(P, run) end,
                          element(2, erx_net_frame:tcp(Path, [Irregular], gen(), Cache))))
     || Irregular <- [Sacked, Fragmentable]],
    %% Resolution holds a run as its packets, which the neighbour's hold counts.
    {ok, [#run{} = Whole], _} = erx_net_frame:tcp(Path, [Run], gen()),
    {resolve, Held} = erx_net_frame:address(Path#{link := neighbour}, none, [Whole]),
    ?assertEqual([iolist_to_binary(P) || P <- erx_net_frame:cut(Whole)],
                 [iolist_to_binary(P) || P <- Held]).
