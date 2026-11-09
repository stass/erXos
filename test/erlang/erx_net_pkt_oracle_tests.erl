%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_net_pkt_oracle: hand-built headers decode to the neutral
%% fields, and pkt's failures come back as values, never as exceptions.
-module(erx_net_pkt_oracle_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MAC_A, <<2, 0, 0, 0, 0, 1>>).
-define(MAC_B, <<2, 0, 0, 0, 0, 2>>).

tcp_header(Options) ->
    Off = 5 + byte_size(Options) div 4,
    <<1234:16, 80:16, 16#fffffffe:32, 7:32, Off:4, 0:3, 2#000010010:9, 65535:16, 16#abcd:16, 0:16,
      Options/binary>>.

ipv4_header(Payload) ->
    <<4:4, 5:4, 0, (20 + byte_size(Payload)):16, 99:16, 0:1, 1:1, 0:1, 0:13, 64, 6, 16#1234:16,
      10, 0, 0, 1, 10, 0, 0, 2>>.

frame_layers_test() ->
    Tcp = <<(tcp_header(<<2, 4, 5, 180, 1, 3, 3, 7, 4, 2, 0, 0>>))/binary, "data">>,
    Ip = <<(ipv4_header(Tcp))/binary, Tcp/binary>>,
    Frame = <<?MAC_B/binary, ?MAC_A/binary, 16#0800:16, Ip/binary>>,
    ?assertEqual({ok, #{dst => ?MAC_B, src => ?MAC_A, type => 16#0800}, Ip}, erx_net_pkt_oracle:ether(Frame)),
    {ok, IpFields, Tcp} = erx_net_pkt_oracle:ipv4(Ip),
    ?assertMatch(#{v := 4, hl := 5, len := 56, id := 99, df := 1, mf := 0, off := 0, ttl := 64, p := 6,
                   sum := 16#1234, src := <<10, 0, 0, 1>>, dst := <<10, 0, 0, 2>>, options := <<>>}, IpFields),
    ?assertEqual({ok, #{sport => 1234, dport => 80, seq => 16#fffffffe, ack => 7, off => 8, flags => 2#000010010,
                        win => 65535, sum => 16#abcd, urp => 0,
                        options => [{mss, 1460}, nop, {wscale, 7}, sack_permitted, eol]},
                  <<"data">>},
                 erx_net_pkt_oracle:tcp(Tcp)).

%% pkt raises on what it cannot decode; the oracle returns a value.
rejections_test() ->
    ?assertEqual({error, rejected}, erx_net_pkt_oracle:tcp(<<1, 2, 3>>)),
    ?assertEqual({error, rejected}, erx_net_pkt_oracle:ipv4(<<4:4, 15:4, 0:152>>)),
    {ok, #{options := rejected}, <<>>} = erx_net_pkt_oracle:tcp(tcp_header(<<99, 4, 0, 0>>)).

%% pkt does not cut at the stated length: the oracle passes that on.
uncut_payload_test() ->
    ?assertEqual({ok, #{sport => 53, dport => 9, ulen => 9, sum => 0}, <<"xy">>},
                 erx_net_pkt_oracle:udp(<<53:16, 9:16, 9:16, 0:16, "xy">>)).

icmp_test() ->
    ?assertEqual({ok, #{type => 128, code => 0, sum => 1, id => 2, seq => 3}, <<"p">>},
                 erx_net_pkt_oracle:icmp6(<<128, 0, 1:16, 2:16, 3:16, "p">>)),
    ?assertEqual({ok, #{type => 2, code => 0, sum => 1, mtu => 1280}, <<>>},
                 erx_net_pkt_oracle:icmp6(<<2, 0, 1:16, 1280:32>>)),
    %% pkt leaves its own copy of the word at zero for a router solicitation.
    ?assertEqual({ok, #{type => 133, code => 0, sum => 1, unused => <<1, 2, 3, 4>>}, <<>>},
                 erx_net_pkt_oracle:icmp6(<<133, 0, 1:16, 1, 2, 3, 4>>)),
    ?assertEqual({ok, #{type => 3, code => 4, sum => 1, unused => <<0:16, 1500:16>>}, <<>>},
                 erx_net_pkt_oracle:icmp4(<<3, 4, 1:16, 0:16, 1500:16>>)).

ipv6_arp_test() ->
    Src = <<16#fe80:16, 0:96, 1:16>>,
    Dst = <<16#ff02:16, 0:96, 1:16>>,
    ?assertEqual({ok, #{v => 6, class => 0, flow => 5, plen => 0, nxt => 59, hlim => 255, src => Src, dst => Dst},
                  <<>>},
                 erx_net_pkt_oracle:ipv6(<<6:4, 0:8, 5:20, 0:16, 59, 255, Src/binary, Dst/binary>>)),
    ?assertEqual({ok, #{hrd => 1, pro => 16#0800, hln => 6, pln => 4, op => 1, sha => ?MAC_A,
                        spa => <<10, 0, 0, 1>>, tha => <<0:48>>, tpa => <<10, 0, 0, 2>>}, <<>>},
                 erx_net_pkt_oracle:arp(<<1:16, 16#0800:16, 6, 4, 1:16, ?MAC_A/binary, 10, 0, 0, 1, 0:48,
                                          10, 0, 0, 2>>)).
