%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ip6_wire_tests).
-moduledoc """
EUnit cases of erx_ip6_wire over hand-built packets: the payload-length cut,
each extension-header rule the walk enforces and the refusal it gives, and
encode/decode agreement over every header kind.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip6.hrl").

-define(SRC, <<16#fe80:16, 0:48, 1:64>>).
-define(DST, <<16#fe80:16, 0:48, 2:64>>).

%% An IPv6 packet whose payload length covers Payload exactly.
packet(Nxt, Payload) ->
    packet(Nxt, byte_size(Payload), Payload).

packet(Nxt, Plen, Payload) ->
    <<6:4, 0:8, 0:20, Plen:16, Nxt, 64, ?SRC/binary, ?DST/binary, Payload/binary>>.

%% An options header: Next, then the options, padded by the caller to 8n.
opts(Next, Options) ->
    Len = (2 + byte_size(Options)) div 8 - 1,
    <<Next, Len, Options/binary>>.

udp() -> <<1:16, 2:16, 8:16, 0:16>>.

plain_packet_cuts_trailing_bytes_test() ->
    Frame = <<(packet(?IPPROTO_UDP, udp()))/binary, "pad">>,
    ?assertMatch({ok, #ip6{proto = ?IPPROTO_UDP, proto_ptr = 6, hdrlen = 0,
                           exthdrs = [], hlim = 64, src = ?SRC, dst = ?DST}, <<1:16, 2:16, 8:16, 0:16>>},
                 erx_ip6_wire:decode(Frame)).

fixed_header_refusals_test() ->
    ?assertEqual({error, too_short}, erx_ip6_wire:decode(binary:part(packet(59, <<>>), 0, 39))),
    <<_:4, Rest/bits>> = packet(59, <<>>),
    ?assertEqual({error, bad_version}, erx_ip6_wire:decode(<<4:4, Rest/bits>>)),
    ?assertEqual({error, truncated}, erx_ip6_wire:decode(packet(?IPPROTO_UDP, 9, udp()))).

hop_by_hop_router_alert_test() ->
    Hbh = opts(?IPPROTO_UDP, <<5, 2, 0, 0, 1, 0>>),
    ?assertMatch({ok, #ip6{exthdrs = [{hopopts, [{5, <<0, 0>>}]}], proto = ?IPPROTO_UDP,
                           proto_ptr = 40, hdrlen = 8}, _},
                 erx_ip6_wire:decode(packet(?IPPROTO_HOPOPTS, <<Hbh/binary, (udp())/binary>>))),
    Bad = opts(?IPPROTO_UDP, <<5, 1, 0, 1, 1, 0>>),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_HEADER, 43}},
                 erx_ip6_wire:decode(packet(?IPPROTO_HOPOPTS, Bad))).

jumbograms_are_refused_test() ->
    Jumbo = opts(?IPPROTO_UDP, <<16#c2, 4, 70000:32>>),
    ?assertEqual({error, {param_problem_unicast, ?ICMP6_PARAMPROB_OPTION, 42}},
                 erx_ip6_wire:decode(packet(?IPPROTO_HOPOPTS, Jumbo))),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_HEADER, 4}},
                 erx_ip6_wire:decode(packet(?IPPROTO_HOPOPTS, 0, Jumbo))).

unknown_option_actions_test() ->
    Decode = fun(Type) ->
                     Dst = opts(?IPPROTO_NONE, <<1, 0, Type, 2, 0, 0>>),
                     erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, Dst))
             end,
    ?assertMatch({ok, #ip6{exthdrs = [{dstopts, [{16#3e, <<0, 0>>}]}]}, <<>>}, Decode(16#3e)),
    ?assertEqual({error, unknown_option}, Decode(16#7e)),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_OPTION, 44}}, Decode(16#be)),
    ?assertEqual({error, {param_problem_unicast, ?ICMP6_PARAMPROB_OPTION, 44}}, Decode(16#fe)),
    %% A router alert is a hop-by-hop option only: elsewhere its type's rule skips it.
    ?assertMatch({ok, #ip6{exthdrs = [{dstopts, [{5, <<0>>}]}]}, <<>>},
                 erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, opts(?IPPROTO_NONE, <<5, 1, 0, 1, 1, 0>>)))).

option_past_its_header_is_refused_test() ->
    ?assertEqual({error, bad_option},
                 erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, opts(?IPPROTO_NONE, <<1, 0, 16#3e, 3, 0, 0>>)))),
    ?assertEqual({error, header_too_long},
                 erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, <<?IPPROTO_NONE, 1, 1, 4, 0, 0, 0, 0>>))).

hop_by_hop_only_first_test() ->
    Dst = opts(?IPPROTO_HOPOPTS, <<1, 4, 0, 0, 0, 0>>),
    Hbh = opts(?IPPROTO_NONE, <<1, 4, 0, 0, 0, 0>>),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_NEXTHEADER, 40}},
                 erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, <<Dst/binary, Hbh/binary>>))).

routing_header_test() ->
    Rh0 = fun(SegLeft) -> <<?IPPROTO_NONE, 2, 0, SegLeft, 0:32, ?DST/binary>> end,
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_HEADER, 42}},
                 erx_ip6_wire:decode(packet(?IPPROTO_ROUTING, Rh0(1)))),
    ?assertMatch({ok, #ip6{exthdrs = [{routing, 0, <<0:32, _:16/binary>>}], proto = ?IPPROTO_NONE,
                           proto_ptr = 40, hdrlen = 24}, <<>>},
                 erx_ip6_wire:decode(packet(?IPPROTO_ROUTING, Rh0(0)))).

fragments_test() ->
    Frag = fun(Off, More) -> <<?IPPROTO_UDP, 0, (Off bor More):16, 7:32>> end,
    %% An atomic fragment is passed over and the walk goes on.
    ?assertMatch({ok, #ip6{exthdrs = [{fragment, 0, false, 7}], fragment = none, proto = ?IPPROTO_UDP,
                           proto_ptr = 40, hdrlen = 8}, <<1:16, _/binary>>},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT, <<(Frag(0, 0))/binary, (udp())/binary>>))),
    %% A later fragment ends the walk; its data is the payload.
    ?assertMatch({ok, #ip6{exthdrs = [], fragment = {16, false, 7}, proto = ?IPPROTO_UDP,
                           proto_ptr = 40, hdrlen = 8}, <<"abc">>},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT, <<(Frag(16, 0))/binary, "abc">>))),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_HEADER, 4}},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT, <<(Frag(16, 1))/binary, "abc">>))),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_HEADER, 4}},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT, Frag(16, 0)))),
    %% RFC 7112: a first fragment holds the header chain through the upper
    %% layer's header: 8 bytes of UDP, 20 of TCP.
    ?assertMatch({ok, #ip6{exthdrs = [], fragment = {0, true, 7}}, <<1:16, _:6/binary>>},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT, <<(Frag(0, 1))/binary, (udp())/binary>>))),
    Dst = opts(?IPPROTO_TCP, <<1, 4, 0, 0, 0, 0>>),
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_FIRSTFRAG, 0}},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT,
                                            <<?IPPROTO_DSTOPTS, 0, 1:16, 7:32, Dst/binary, 0:64>>))),
    Short = <<?IPPROTO_DSTOPTS, 0, 1:16, 7:32, ?IPPROTO_UDP, 1, 0:48>>,
    ?assertEqual({error, {param_problem, ?ICMP6_PARAMPROB_FIRSTFRAG, 0}},
                 erx_ip6_wire:decode(packet(?IPPROTO_FRAGMENT, Short))).

header_nesting_is_bounded_test() ->
    Chain = fun(N) ->
                    Pad = <<1, 4, 0, 0, 0, 0>>,
                    Headers = [opts(?IPPROTO_DSTOPTS, Pad) || _ <- lists:seq(1, N - 1)],
                    iolist_to_binary([Headers, opts(?IPPROTO_NONE, Pad)])
            end,
    %% FreeBSD counts each hand-off after the hop-by-hop header, the upper
    %% layer's included: 14 headers and the upper layer make 15.
    ?assertMatch({ok, #ip6{hdrlen = 112}, <<>>}, erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, Chain(14)))),
    ?assertEqual({error, too_many_headers}, erx_ip6_wire:decode(packet(?IPPROTO_DSTOPTS, Chain(15)))),
    Hbh = opts(?IPPROTO_DSTOPTS, <<1, 4, 0, 0, 0, 0>>),
    ?assertMatch({ok, #ip6{hdrlen = 120}, <<>>},
                 erx_ip6_wire:decode(packet(?IPPROTO_HOPOPTS, <<Hbh/binary, (Chain(14))/binary>>))).

encode_decode_agree_test() ->
    Header = #ip6{tclass = 16#b8, flow = 16#12345, hlim = 255, src = ?SRC, dst = ?DST,
                  exthdrs = [{hopopts, [{5, <<0, 0>>}, {16#1e, <<"abc">>}]},
                             {dstopts, []},
                             {routing, 4, <<0:32>>},
                             {fragment, 0, false, 99},
                             {dstopts, [{16#3f, <<>>}]}],
                  proto = ?IPPROTO_UDP},
    Frame = iolist_to_binary(erx_ip6_wire:encode(Header, udp())),
    {ok, Decoded, Payload} = erx_ip6_wire:decode(Frame),
    ?assertEqual(udp(), Payload),
    ?assertEqual(Header#ip6{proto_ptr = Decoded#ip6.proto_ptr, hdrlen = Decoded#ip6.hdrlen}, Decoded),
    ?assertEqual(byte_size(Frame) - 40 - 8, Decoded#ip6.hdrlen),
    Fragment = Header#ip6{fragment = {64, true, 5}},
    ?assertMatch({ok, #ip6{fragment = {64, true, 5}, proto = ?IPPROTO_UDP}, <<"8 bytes!">>},
                 erx_ip6_wire:decode(iolist_to_binary(erx_ip6_wire:encode(Fragment, <<"8 bytes!">>)))),
    ?assertError(badarg, erx_ip6_wire:encode(Header, <<0:(65536 * 8)>>)),
    ?assertError(badarg, erx_ip6_wire:encode(Header#ip6{exthdrs = [{dstopts, [{16#1e, <<0:2048>>}]}]}, <<>>)),
    ?assertError(badarg, erx_ip6_wire:encode(Header#ip6{exthdrs = [{dstopts, [{1, <<>>}]}]}, <<>>)).
