%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ip6_decisions_tests).
-moduledoc """
EUnit cases for the IPv6 and ICMPv6 decisions (erx_ip6, erx_icmp6), one per FreeBSD branch
they translate; a property that fragmentation followed by erx_ip6_reass and `input/4`
gives back the datagram; and the ICMPv6 rate limits of erx_net_bandlim
(docs/design-network-stack.md, "IPv6, neighbour discovery and autoconfiguration").
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip6.hrl").

-define(ME, <<16#2001, 16#db8, 0:96, 2:16>>).
-define(PEER, <<16#2001, 16#db8, 0:96, 1:16>>).
-define(TENTATIVE, <<16#2001, 16#db8, 0:96, 3:16>>).
-define(LL_PEER, <<16#fe80:16, 0:96, 1:16>>).
-define(LL_ME, <<16#fe80:16, 0:96, 2:16>>).
-define(ALL_NODES, <<16#ff02:16, 0:96, 1:16>>).
-define(VIEW, #{addrs => [?ME, ?LL_ME], notready => [?TENTATIVE], loopback => false}).
-define(LO_VIEW, #{addrs => [<<1:128>>], notready => [], loopback => true}).
-define(CTX(Now), #{now => Now, loopback => false}).

gen() -> erx_net_rand:new(<<9:128>>).
lim() -> erx_net_bandlim:new(gen()).

ip(Fields) ->
    maps:fold(fun set/3, #ip6{tclass = 0, flow = 0, hlim = 64, src = ?PEER, dst = ?ME, proto = 17}, Fields).

set(src, V, Ip) -> Ip#ip6{src = V};
set(dst, V, Ip) -> Ip#ip6{dst = V};
set(hlim, V, Ip) -> Ip#ip6{hlim = V};
set(proto, V, Ip) -> Ip#ip6{proto = V};
set(exthdrs, V, Ip) -> Ip#ip6{exthdrs = V};
set(fragment, V, Ip) -> Ip#ip6{fragment = V}.

packet(Fields) -> packet(Fields, <<0:64>>).
packet(Fields, Payload) -> iolist_to_binary(erx_ip6_wire:encode(ip(Fields), Payload)).

input(Packet) -> erx_ip6:input(Packet, received, unicast, ?VIEW).

%% An ICMPv6 message from Src to Dst, with its checksum.
icmp6(Icmp, Rest, Src, Dst) -> iolist_to_binary(erx_icmp6_wire:encode(Icmp, Rest, {Src, Dst})).

ns() -> icmp6(#icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, ?ME, #{}}}, <<>>, ?LL_PEER, ?ME).

%% erx_ip6:input/4

delivers_unicast_to_an_own_address_test() ->
    ?assertMatch({ours, unicast, true, #ip6{proto = 17}, <<0:64>>}, input(packet(#{}))).

bad_addresses_dropped_test() ->
    Bad = [#{src => ?ALL_NODES},                                  % multicast source
           #{dst => <<16#ff01:16, 0:96, 1:16>>},                   % interface-local, off loopback
           #{dst => <<16#ff00:16, 0:96, 1:16>>},                   % reserved multicast scope
           #{src => <<0:80, 16#ffff:16, 10, 0, 0, 1>>},            % v4-mapped
           #{dst => <<0:128>>},
           #{src => <<16#fe80:16, 7:16, 0:80, 1:16>>},             % a zone in the second word
           #{dst => <<16#ff02:16, 7:16, 0:80, 1:16>>},
           #{src => <<1:128>>},                                    % loopback off loopback
           #{src => ?ME}],                                         % ip6_sav
    [?assertEqual({drop, bad_addr}, input(packet(F))) || F <- Bad].

loopback_interface_accepts_loopback_and_own_source_test() ->
    Lo = packet(#{src => <<1:128>>, dst => <<1:128>>}),
    ?assertMatch({ours, unicast, true, _, _}, erx_ip6:input(Lo, received, unicast, ?LO_VIEW)),
    Own = packet(#{src => <<1:128>>, dst => <<16#ff01:16, 0:96, 1:16>>}),
    ?assertMatch({ours, multicast, false, _, _}, erx_ip6:input(Own, received, unicast, ?LO_VIEW)).

destination_search_test() ->
    ?assertEqual({drop, not_ready}, input(packet(#{dst => ?TENTATIVE}))),
    ?assertEqual({drop, not_ours}, input(packet(#{dst => <<16#2001, 16#db8, 0:96, 9:16>>}))),
    ?assertMatch({ours, multicast, false, _, _}, input(packet(#{dst => ?ALL_NODES}))),
    ?assertMatch({ours, unicast, false, _, _}, erx_ip6:input(packet(#{}), received, multicast, ?VIEW)),
    ?assertMatch({ours, unicast, false, _, _}, input(packet(#{src => <<0:128>>}))).

tcp_from_unspecified_dropped_test() ->
    ?assertEqual({drop, bad_addr}, input(packet(#{src => <<0:128>>, proto => 6}))),
    ?assertMatch({ours, _, _, _, _}, input(packet(#{src => <<0:128>>, proto => 17}))).

malformed_header_answered_only_when_answerable_test() ->
    %% An option of type 10xxxxxx: answer with a parameter problem, code 2, at the option.
    Opt = #{proto => 17, exthdrs => [{dstopts, [{16#80, <<0, 0>>}]}]},
    ?assertEqual({param_problem, 2, 42}, input(packet(Opt))),
    ?assertEqual({drop, {param_problem, 2, 42}}, input(packet(Opt#{dst => ?ALL_NODES}))),
    ?assertEqual({drop, {param_problem, 2, 42}}, erx_ip6:input(packet(Opt), received, broadcast, ?VIEW)),
    ?assertEqual({drop, not_ours}, input(packet(Opt#{dst => <<16#2001, 16#db8, 0:96, 9:16>>}))),
    ?assertEqual({drop, bad_addr}, input(packet(Opt#{src => ?ALL_NODES}))).

fragment_goes_to_reassembly_test() ->
    Frag = packet(#{fragment => {8, false, 77}}),
    ?assertMatch({fragment, #ip6{fragment = {8, false, 77}}, <<0:64>>}, input(Frag)),
    %% Fragment data that happens to start with a neighbour-discovery type is not a message.
    Data = packet(#{proto => 58, fragment => {8, true, 77}}, <<135, 0:56>>),
    ?assertMatch({fragment, _, _}, input(Data)).

neighbour_discovery_in_fragments_dropped_test() ->
    Ns = packet(#{src => ?LL_PEER, hlim => 255, proto => 58}, ns()),
    ?assertMatch({ours, unicast, true, _, _}, input(Ns)),
    ?assertEqual({drop, fragmented_nd}, erx_ip6:input(Ns, reassembled, unicast, ?VIEW)),
    Atomic = packet(#{src => ?LL_PEER, hlim => 255, proto => 58, exthdrs => [{fragment, 0, false, 5}]}, ns()),
    ?assertEqual({drop, fragmented_nd}, input(Atomic)),
    Echo = packet(#{proto => 58}, icmp6(echo_request(), <<"x">>, ?PEER, ?ME)),
    ?assertMatch({ours, _, _, _, _}, erx_ip6:input(Echo, reassembled, unicast, ?VIEW)).

%% erx_ip6:output/4

output_test() ->
    Out = #{src => ?ME, dst => ?PEER, proto => 17},
    ?assertMatch({ok, [_], _}, erx_ip6:output(Out, <<0:(1460 * 8)>>, 1500, gen())),
    {ok, [One], _} = erx_ip6:output(Out#{hlim => 7, tclass => 3, flow => 9}, <<"abc">>, 1500, gen()),
    ?assertMatch({ok, #ip6{hlim = 7, tclass = 3, flow = 9, proto = 17}, <<"abc">>},
                 erx_ip6_wire:decode(iolist_to_binary(One))),
    ?assertEqual({error, emsgsize}, erx_ip6:output(Out#{df => true}, <<0:(1461 * 8)>>, 1500, gen())),
    ?assertEqual({error, emsgsize}, erx_ip6:output(Out, <<0:(1300 * 8)>>, 1279, gen())),
    ?assertEqual({error, emsgsize}, erx_ip6:output(Out, <<0:(65536 * 8)>>, 1500, gen())),
    %% A multicast datagram is sent at the minimum MTU unless it may not be fragmented.
    Mc = Out#{dst => ?ALL_NODES},
    {ok, Frags, _} = erx_ip6:output(Mc, <<0:(1400 * 8)>>, 1500, gen()),
    ?assertEqual(2, length(Frags)),
    ?assert(lists:all(fun(F) -> iolist_size(F) =< 1280 end, Frags)),
    ?assertMatch({ok, [_], _}, erx_ip6:output(Mc#{df => true}, <<0:(1400 * 8)>>, 1500, gen())).

%% Any datagram, cut by output/4 at any MTU and handed in any order to erx_ip6_reass,
%% comes back whole through input/4 as a reassembled packet.
fragmentation_then_reassembly_gives_the_datagram_test() ->
    _ = rand:seed(exsss, {6, 6, 6}),
    lists:foreach(
      fun(_) ->
              Payload = rand:bytes(rand:uniform(9000)),
              Mtu = 1280 + rand:uniform(1000),
              {ok, Packets, _} = erx_ip6:output(#{src => ?PEER, dst => ?ME, proto => 17}, Payload, Mtu,
                                                erx_net_rand:new(rand:bytes(16))),
              Bins = [iolist_to_binary(P) || P <- Packets],
              ?assert(lists:all(fun(B) -> byte_size(B) =< Mtu end, Bins)),
              Whole = case Bins of
                          [Bin] -> Bin;
                          _ -> reassemble(shuffle(Bins), erx_ip6_reass:new())
                      end,
              Origin = case Bins of [_] -> received; _ -> reassembled end,
              ?assertMatch({ours, unicast, true, #ip6{proto = 17}, Payload},
                           erx_ip6:input(Whole, Origin, unicast, ?VIEW))
      end, lists:seq(1, 200)).

reassemble([Bin | Rest], T0) ->
    {fragment, Ip, Data} = input(Bin),
    case erx_ip6_reass:input(Ip, Data, 0, T0) of
        {done, Packet, _} -> [] = Rest, Packet;
        {held, T} -> reassemble(Rest, T)
    end.

shuffle(List) -> [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

%% erx_icmp6:input/6

echo_request() -> #icmp6{type = ?ICMP6_ECHO_REQUEST, code = 0, msg = {echo, 7, 9}}.

echo_answered_only_when_answerable_test() ->
    Ip = ip(#{proto => 58}),
    {[{send, Out, Msg}], _} = erx_icmp6:input(Ip, true, echo_request(), <<"data">>, ?CTX(0), lim()),
    ?assertEqual(#{src => ?ME, dst => ?PEER, proto => 58}, Out),
    Bin = iolist_to_binary(Msg),
    Sum = erx_ip6_wire:pseudo_sum(?ME, ?PEER, byte_size(Bin), 58),
    ?assertMatch({ok, #icmp6{type = ?ICMP6_ECHO_REPLY, msg = {echo, 7, 9}}, <<"data">>},
                 erx_icmp6_wire:decode(Sum, Bin)),
    ?assertMatch({[], _}, erx_icmp6:input(Ip, false, echo_request(), <<>>, ?CTX(0), lim())).

udp_quote(Src, Dst) ->
    iolist_to_binary(erx_ip6_wire:encode(ip(#{src => Src, dst => Dst}), <<1:16, 2:16, 8:16, 0:16>>)).

error_reported_to_the_quoted_protocol_test() ->
    Unreach = #icmp6{type = ?ICMP6_DST_UNREACH, code = 4, msg = {error, 0}},
    Quote = udp_quote(?ME, ?PEER),
    {[{report, Unreach, Quoted}], _} = erx_icmp6:input(ip(#{}), false, Unreach, Quote, ?CTX(0), lim()),
    ?assertEqual(#{proto => 17, src => ?ME, dst => ?PEER, upper => <<1:16, 2:16, 8:16, 0:16>>}, Quoted),
    ?assertEqual({notify, econnrefused}, erx_udp:report(Unreach)),
    %% A quoted loopback address is genuine only on the loopback interface.
    Lo = udp_quote(<<1:128>>, <<1:128>>),
    ?assertMatch({[], _}, erx_icmp6:input(ip(#{}), false, Unreach, Lo, ?CTX(0), lim())),
    ?assertMatch({[{report, _, _}], _},
                 erx_icmp6:input(ip(#{}), false, Unreach, Lo, #{now => 0, loopback => true}, lim())).

redirect_test() ->
    Router = ?LL_PEER,
    Redirect = fun(Src, Hlim, Target, Dst) ->
                       Icmp = #icmp6{type = ?ND_REDIRECT, code = 0,
                                     msg = {redirect, Target, Dst, #{tlla => <<1, 2, 3, 4, 5, 6>>}}},
                       {Actions, _} = erx_icmp6:input(ip(#{src => Src, hlim => Hlim, proto => 58}), false,
                                                      Icmp, <<>>, ?CTX(0), lim()),
                       Actions
               end,
    Far = <<16#2001, 16#db9, 0:96, 1:16>>,
    ?assertEqual([{redirect, Far, ?LL_ME, Router, <<1, 2, 3, 4, 5, 6>>}], Redirect(Router, 255, ?LL_ME, Far)),
    ?assertMatch([{redirect, Far, Far, Router, _}], Redirect(Router, 255, Far, Far)),
    ?assertEqual([], Redirect(?PEER, 255, ?LL_ME, Far)),
    ?assertEqual([], Redirect(Router, 64, ?LL_ME, Far)),
    ?assertEqual([], Redirect(Router, 255, ?PEER, Far)),
    ?assertEqual([], Redirect(Router, 255, ?LL_ME, ?ALL_NODES)).

errno_test() ->
    ?assertEqual(emsgsize, erx_icmp6:errno(#icmp6{type = ?ICMP6_PACKET_TOO_BIG, code = 0, msg = {error, 1280}})),
    ?assertEqual(ehostunreach, erx_icmp6:errno(#icmp6{type = ?ICMP6_DST_UNREACH, code = 3, msg = {error, 0}})),
    ?assertEqual(enoprotoopt, erx_icmp6:errno(#icmp6{type = ?ICMP6_DST_UNREACH, code = 2, msg = {error, 0}})),
    ?assertEqual(econnrefused, erx_icmp6:errno(#icmp6{type = ?ICMP6_PARAM_PROB, code = 1, msg = {error, 0}})),
    ?assertEqual(none, erx_icmp6:errno(#icmp6{type = ?ICMP6_TIME_EXCEEDED, code = 1, msg = {error, 0}})),
    ?assertEqual(ignore, erx_udp:report(#icmp6{type = ?ICMP6_TIME_EXCEEDED, code = 1, msg = {error, 0}})).

%% erx_icmp6:error/4

error_quotes_and_answers_from_the_destination_test() ->
    Big = packet(#{}, <<0:(2000 * 8)>>),
    {[{send, Out, Msg}], _} = erx_icmp6:error({unreach, 4}, Big, ?CTX(0), lim()),
    ?assertEqual(#{src => ?ME, dst => ?PEER, proto => 58}, Out),
    Bin = iolist_to_binary(Msg),
    ?assertEqual(1280 - 40, byte_size(Bin)),
    Sum = erx_ip6_wire:pseudo_sum(?ME, ?PEER, byte_size(Bin), 58),
    ?assertMatch({ok, #icmp6{type = ?ICMP6_DST_UNREACH, code = 4}, <<_:1232/binary>>},
                 erx_icmp6_wire:decode(Sum, Bin)),
    {[{send, _, Pp}], _} = erx_icmp6:error({param_problem, 1, 6}, packet(#{}), ?CTX(0), lim()),
    ?assertMatch(<<4, 1, _:16, 6:32, _/binary>>, iolist_to_binary(Pp)).

no_error_about_an_icmp6_error_or_redirect_test() ->
    Error = icmp6(#icmp6{type = ?ICMP6_DST_UNREACH, code = 4, msg = {error, 0}}, udp_quote(?ME, ?PEER), ?PEER, ?ME),
    ?assertMatch({[], _}, erx_icmp6:error({param_problem, 1, 6}, packet(#{proto => 58}, Error), ?CTX(0), lim())),
    %% Found past extension headers, but not past a fragment header with an offset.
    Behind = packet(#{proto => 58, exthdrs => [{dstopts, [{16#1e, <<0>>}]}, {fragment, 0, false, 1}]}, Error),
    ?assertMatch({[], _}, erx_icmp6:error({unreach, 4}, Behind, ?CTX(0), lim())),
    Later = packet(#{proto => 58, fragment => {8, false, 1}}, Error),
    ?assertMatch({[_], _}, erx_icmp6:error({time_exceeded, 1}, Later, ?CTX(0), lim())),
    Echo = packet(#{proto => 58}, icmp6(echo_request(), <<>>, ?PEER, ?ME)),
    ?assertMatch({[_], _}, erx_icmp6:error({param_problem, 1, 6}, Echo, ?CTX(0), lim())).

%% The ICMPv6 limits: 100 a second each, moved by at most 8, kept apart from each other and
%% from the IPv4 limits, and refilled in the next window.
icmp6_limits_test() ->
    Sent = fun(Kind, Now, Lim0) ->
                   lists:foldl(fun(_, {N, L0}) ->
                                       {A, L} = erx_icmp6:error(Kind, packet(#{}), ?CTX(Now), L0),
                                       {N + length(A), L}
                               end, {0, Lim0}, lists:seq(1, 300))
           end,
    {Unreach, L1} = Sent({unreach, 4}, 0, lim()),
    ?assert(Unreach >= 92 andalso Unreach =< 108),
    {Param, L2} = Sent({param_problem, 0, 4}, 10, L1),
    ?assert(Param >= 92 andalso Param =< 108),
    {allow, L3} = erx_net_bandlim:check(icmp_unreach, 20, L2),
    {Again, _} = Sent({unreach, 4}, 1000, L3),
    ?assert(Again >= 92 andalso Again =< 108).

%% Review regressions: what must draw no answer.

no_error_about_a_datagram_to_a_multicast_group_test() ->
    %% A first fragment to all nodes that reassembly gives up on: every host on the link
    %% would answer it.
    First = packet(#{dst => ?ALL_NODES, fragment => {0, true, 3}}),
    ?assertMatch({fragment, _, _}, input(First)),
    ?assertMatch({[], _}, erx_icmp6:error({time_exceeded, 1}, First, ?CTX(0), lim())).

no_error_about_a_redirect_or_a_short_icmp6_header_test() ->
    Redirect = icmp6(#icmp6{type = ?ND_REDIRECT, code = 0, msg = {redirect, ?LL_ME, ?PEER, #{}}}, <<>>, ?LL_PEER, ?ME),
    ?assertMatch({[], _}, erx_icmp6:error({param_problem, 1, 6}, packet(#{proto => 58}, Redirect), ?CTX(0), lim())),
    ?assertMatch({[], _}, erx_icmp6:error({param_problem, 1, 6}, packet(#{proto => 58}, <<128, 0, 0>>), ?CTX(0), lim())).

redirect_in_fragments_dropped_test() ->
    Redirect = icmp6(#icmp6{type = ?ND_REDIRECT, code = 0, msg = {redirect, ?LL_ME, ?PEER, #{}}}, <<>>, ?LL_PEER, ?ME),
    Packet = packet(#{src => ?LL_PEER, hlim => 255, proto => 58}, Redirect),
    ?assertEqual({drop, fragmented_nd}, erx_ip6:input(Packet, reassembled, unicast, ?VIEW)).

redirect_with_a_wrong_link_address_length_ignored_test() ->
    Icmp = #icmp6{type = ?ND_REDIRECT, code = 0, msg = {redirect, ?LL_ME, ?PEER, #{tlla => <<0:(14 * 8)>>}}},
    ?assertMatch({[], _}, erx_icmp6:input(ip(#{src => ?LL_PEER, hlim => 255, proto => 58}), false, Icmp, <<>>,
                                          ?CTX(0), lim())).

packet_too_big_under_the_minimum_mtu_ignored_test() ->
    Ptb = fun(Mtu) -> #icmp6{type = ?ICMP6_PACKET_TOO_BIG, code = 0, msg = {error, Mtu}} end,
    Quote = udp_quote(?ME, ?PEER),
    ?assertMatch({[], _}, erx_icmp6:input(ip(#{}), false, Ptb(68), Quote, ?CTX(0), lim())),
    ?assertMatch({[{report, _, _}], _}, erx_icmp6:input(ip(#{}), false, Ptb(1280), Quote, ?CTX(0), lim())).
