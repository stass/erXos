%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ip4_decisions_tests).
-moduledoc """
EUnit cases for the IPv4, ICMPv4 and UDP decisions (erx_ip4, erx_icmp4, erx_udp) and the
rate limits (erx_net_bandlim), one per FreeBSD branch they translate; a property that
fragmentation followed by erx_ip4_reass gives back the datagram; and a property that the
limits hold under virtual time (docs/design-network-stack.md, "IPv4 and ARP").
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").
-include("erx_icmp4_wire.hrl").

-define(ME, <<10, 0, 0, 2>>).
-define(PEER, <<10, 0, 0, 1>>).
-define(BCAST, <<10, 0, 0, 255>>).
-define(VIEW, #{addrs => [?ME], broadcasts => [?BCAST], loopback => false}).
-define(CTX(Now), #{now => Now, time_of_day => 1234}).

gen() -> erx_net_rand:new(<<7:128>>).
lim() -> erx_net_bandlim:new(gen()).

packet(Fields) -> packet(Fields, <<0:64>>).
packet(Fields, Payload) ->
    Ip = maps:fold(fun set/3, #ip4{ttl = 64, p = 17, src = ?PEER, dst = ?ME}, Fields),
    iolist_to_binary([erx_ip4_wire:encode(Ip#ip4{len = 20 + byte_size(Ip#ip4.options) + byte_size(Payload)}),
                      Payload]).

set(src, V, Ip) -> Ip#ip4{src = V};
set(dst, V, Ip) -> Ip#ip4{dst = V};
set(p, V, Ip) -> Ip#ip4{p = V};
set(mf, V, Ip) -> Ip#ip4{mf = V};
set(rf, V, Ip) -> Ip#ip4{rf = V};
set(off, V, Ip) -> Ip#ip4{off = V};
set(options, V, Ip) -> Ip#ip4{options = V}.

%% erx_ip4:input/3

delivers_unicast_to_an_own_address_test() ->
    ?assertMatch({ours, unicast, true, #ip4{p = 17}, <<0:64>>}, erx_ip4:input(packet(#{}), unicast, ?VIEW)).

loopback_address_off_loopback_interface_dropped_test() ->
    ?assertEqual({drop, bad_addr}, erx_ip4:input(packet(#{src => <<127, 0, 0, 1>>}), unicast, ?VIEW)),
    ?assertMatch({ours, _, _, _, _}, erx_ip4:input(packet(#{src => <<127, 0, 0, 1>>, dst => <<127, 0, 0, 1>>}),
                                                unicast, #{addrs => [<<127, 0, 0, 1>>], broadcasts => [],
                                                           loopback => true})).

unspecified_destination_dropped_test() ->
    ?assertEqual({drop, bad_addr}, erx_ip4:input(packet(#{dst => <<0:32>>}), unicast, ?VIEW)).

source_claiming_an_own_address_dropped_test() ->
    ?assertEqual({drop, bad_addr}, erx_ip4:input(packet(#{src => ?ME}), unicast, ?VIEW)).

broadcast_and_multicast_are_ours_and_marked_test() ->
    ?assertMatch({ours, broadcast, false, _, _}, erx_ip4:input(packet(#{dst => ?BCAST}), unicast, ?VIEW)),
    ?assertMatch({ours, broadcast, false, _, _},
                 erx_ip4:input(packet(#{dst => <<255, 255, 255, 255>>}), unicast, ?VIEW)),
    ?assertMatch({ours, multicast, false, _, _}, erx_ip4:input(packet(#{dst => <<224, 0, 0, 1>>}), unicast, ?VIEW)),
    ?assertMatch({ours, unicast, false, _, _}, erx_ip4:input(packet(#{}), broadcast, ?VIEW)).

%% Nothing answers a source that is a broadcast or multicast address, the limited broadcast
%% or 0.0.0.0/8; a loopback source on the loopback interface is answered.
reply_only_to_an_answerable_source_test() ->
    [?assertMatch({ours, unicast, false, _, _}, erx_ip4:input(packet(#{src => Src}), unicast, ?VIEW))
     || Src <- [?BCAST, <<255, 255, 255, 255>>, <<224, 0, 0, 1>>, <<240, 0, 0, 1>>, <<0, 1, 2, 3>>]],
    Lo = <<127, 0, 0, 1>>,
    ?assertMatch({ours, unicast, true, _, _}, erx_ip4:input(packet(#{src => Lo, dst => Lo}), unicast,
                                                           #{addrs => [Lo], broadcasts => [], loopback => true})).

not_ours_dropped_and_no_address_accepts_unicast_test() ->
    ?assertEqual({drop, not_ours}, erx_ip4:input(packet(#{dst => <<10, 0, 0, 9>>}), unicast, ?VIEW)),
    Empty = #{addrs => [], broadcasts => [], loopback => false},
    ?assertMatch({ours, unicast, false, _, _}, erx_ip4:input(packet(#{dst => <<10, 0, 0, 9>>}), unicast, Empty)),
    ?assertEqual({drop, not_ours}, erx_ip4:input(packet(#{dst => <<10, 0, 0, 9>>}), broadcast, Empty)).

fragment_goes_to_reassembly_test() ->
    ?assertMatch({fragment, #ip4{mf = 1}, _}, erx_ip4:input(packet(#{mf => 1}), unicast, ?VIEW)),
    ?assertMatch({fragment, #ip4{off = 3}, _}, erx_ip4:input(packet(#{off => 3}), unicast, ?VIEW)).

tcp_from_unspecified_address_dropped_test() ->
    ?assertEqual({drop, bad_addr}, erx_ip4:input(packet(#{p => 6, src => <<0:32>>}), unicast, ?VIEW)),
    ?assertMatch({ours, _, _, _, _}, erx_ip4:input(packet(#{p => 17, src => <<0:32>>}), unicast, ?VIEW)).

source_route_dropped_test() ->
    Lsrr = <<131, 7, 4, 1, 2, 3, 4, 1>>,
    ?assertEqual({drop, source_route}, erx_ip4:input(packet(#{options => Lsrr}), unicast, ?VIEW)).

%% erx_ip4_wire:encode/1 refuses a malformed option, so the packet is built here: a record
%% route option whose length byte, at offset 21, is 1.
bad_option(Fields) ->
    <<Head:10/binary, _:16, Addrs:8/binary, _:4/binary, Payload/binary>> =
        packet(Fields#{options => <<1, 1, 1, 1>>}),
    Sum = bnot erx_bytes:inet_csum(0, <<Head/binary, 0:16, Addrs/binary, 7, 1, 0, 0>>) band 16#ffff,
    <<Head/binary, Sum:16, Addrs/binary, 7, 1, 0, 0, Payload/binary>>.

malformed_option_answered_only_when_unicast_to_us_test() ->
    ?assertEqual({param_problem, 21}, erx_ip4:input(bad_option(#{}), unicast, ?VIEW)),
    ?assertEqual({drop, bad_options}, erx_ip4:input(bad_option(#{}), broadcast, ?VIEW)),
    ?assertEqual({drop, bad_options}, erx_ip4:input(bad_option(#{dst => ?BCAST}), unicast, ?VIEW)),
    ?assertEqual({drop, bad_addr}, erx_ip4:input(bad_option(#{src => <<127, 0, 0, 1>>}), unicast, ?VIEW)).

%% erx_ip4:output/4

output_with_df_has_zero_id_and_without_a_random_one_test() ->
    Out = #{src => ?ME, dst => ?PEER, proto => 17},
    {ok, [P1], G} = erx_ip4:output(Out#{df => true}, <<1, 2, 3>>, 1500, gen()),
    ?assertEqual(gen(), G),
    {ok, #ip4{id = 0, df = 1, ttl = 64}, <<1, 2, 3>>} = erx_ip4_wire:decode(iolist_to_binary(P1)),
    {ok, [P2], G2} = erx_ip4:output(Out, <<1, 2, 3>>, 1500, gen()),
    {<<Id:16>>, G2} = erx_net_rand:bytes(2, gen()),
    ?assertMatch({ok, #ip4{id = Id, df = 0}, _}, erx_ip4_wire:decode(iolist_to_binary(P2))).

output_refuses_what_cannot_go_test() ->
    Out = #{src => ?ME, dst => ?PEER, proto => 17},
    ?assertEqual({error, emsgsize}, erx_ip4:output(Out#{df => true}, <<0:1481/unit:8>>, 1500, gen())),
    ?assertEqual({error, emsgsize}, erx_ip4:output(Out, <<0:100/unit:8>>, 27, gen())),
    ?assertEqual({error, emsgsize}, erx_ip4:output(Out, <<0:65516/unit:8>>, 1500, gen())).

%% Property: every datagram fragmented for a random MTU, into at most the 16 fragments
%% erx_ip4_reass holds of a datagram, comes back whole from erx_ip4_reass,
%% each fragment fits the MTU, and every fragment but the last carries a multiple of 8.
fragmentation_then_reassembly_gives_the_datagram_test() ->
    _ = rand:seed(exsss, {9, 9, 9}),
    lists:foreach(fun(_) -> refragment(rand:uniform(4000), 275 + rand:uniform(1300)) end, lists:seq(1, 300)).

refragment(Len, Mtu) ->
    Data = rand:bytes(Len),
    {ok, Packets, _} = erx_ip4:output(#{src => ?ME, dst => ?PEER, proto => 17}, Data, Mtu, gen()),
    Bins = [iolist_to_binary(P) || P <- Packets],
    ?assert(lists:all(fun(B) -> byte_size(B) =< Mtu end, Bins)),
    ?assert(lists:all(fun(B) -> (byte_size(B) - 20) rem 8 =:= 0 end, lists:droplast(Bins))),
    Whole = case Bins of
                [One] -> One;
                _ -> reassemble(shuffle(Bins), erx_ip4_reass:new())
            end,
    ?assertMatch({ok, #ip4{mf = 0, off = 0}, Data}, erx_ip4_wire:decode(Whole)).

reassemble([Bin | Rest], T) ->
    {fragment, Ip, Payload} = erx_ip4:input(Bin, unicast, #{addrs => [?PEER], broadcasts => [], loopback => false}),
    case erx_ip4_reass:input(Ip, Payload, unicast, 0, T) of
        {held, T1} -> reassemble(Rest, T1);
        {done, none, unicast, Whole, _} when Rest =:= [] -> Whole
    end.

shuffle(List) -> [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

%% erx_icmp4:input/6

echo(Dst) ->
    Msg = iolist_to_binary(erx_icmp4_wire:encode(#icmp4{type = 8, code = 0, msg = {echo, 5, 6}}, <<"ping">>)),
    {ok, Icmp, Rest} = erx_icmp4_wire:decode(Msg),
    {#ip4{len = 0, ttl = 64, p = 1, src = ?PEER, dst = Dst, tos = 16}, Icmp, Rest}.

echo_request_answered_test() ->
    {Ip, Icmp, Rest} = echo(?ME),
    {[{send, Out, Reply}], _} = erx_icmp4:input(Ip, true, Icmp, Rest, ?CTX(0), lim()),
    ?assertEqual(#{src => ?ME, dst => ?PEER, proto => 1, tos => 16}, Out),
    ?assertMatch({ok, #icmp4{type = 0, msg = {echo, 5, 6}}, <<"ping">>},
                 erx_icmp4_wire:decode(iolist_to_binary(Reply))).

echo_that_may_not_be_answered_unanswered_test() ->
    {Ip, Icmp, Rest} = echo(?BCAST),
    ?assertMatch({[], _}, erx_icmp4:input(Ip, false, Icmp, Rest, ?CTX(0), lim())).

timestamp_answered_with_time_of_day_test() ->
    Msg = iolist_to_binary(erx_icmp4_wire:encode(#icmp4{type = 13, code = 0, msg = {timestamp, 1, 2, 99, 0, 0}},
                                                 <<>>)),
    {ok, Icmp, Rest} = erx_icmp4_wire:decode(Msg),
    {[{send, _, Reply}], _} = erx_icmp4:input(element(1, echo(?ME)), true, Icmp, Rest, ?CTX(0), lim()),
    ?assertMatch({ok, #icmp4{type = 14}, <<1:16, 2:16, 99:32, 1234:32, 1234:32>>},
                 erx_icmp4_wire:decode(iolist_to_binary(Reply))).

address_mask_request_unanswered_test() ->
    {Ip, _, _} = echo(?ME),
    ?assertMatch({[], _}, erx_icmp4:input(Ip, true, #icmp4{type = 17, code = 0, msg = other}, <<0:32>>,
                                          ?CTX(0), lim())).

error_reported_with_its_quote_and_redirect_passed_on_test() ->
    Quoted = packet(#{src => ?ME, dst => ?PEER}, <<1000:16, 53:16, 0:32>>),
    {Ip, _, _} = echo(?ME),
    Unreach = #icmp4{type = 3, code = 3, msg = {error, 0}},
    ?assertMatch({[{report, Unreach, #{proto := 17, src := ?ME, dst := ?PEER, upper := <<1000:16, 53:16, _:32>>}}], _},
                 erx_icmp4:input(Ip, true, Unreach, Quoted, ?CTX(0), lim())),
    Redirect = #icmp4{type = 5, code = 1, msg = {redirect, <<10, 0, 0, 7>>}},
    ?assertMatch({[{redirect, ?PEER, <<10, 0, 0, 7>>, ?PEER}], _},
                 erx_icmp4:input(Ip, true, Redirect, Quoted, ?CTX(0), lim())).

decode_quoted_checks_test() ->
    ?assertEqual({error, bad_length}, erx_icmp4:decode_quoted(<<16#45, 0:(26 * 8)>>)),
    ?assertEqual({error, bad_length}, erx_icmp4:decode_quoted(<<16#44, 0:(40 * 8)>>)),
    ?assertEqual({error, bad_addr}, erx_icmp4:decode_quoted(packet(#{dst => <<224, 0, 0, 1>>}))),
    ?assertEqual({error, bad_addr}, erx_icmp4:decode_quoted(packet(#{src => <<0:32>>}))),
    ?assertMatch({ok, #{upper := <<0:64>>}}, erx_icmp4:decode_quoted(packet(#{options => <<1, 1, 1, 1>>}))).

errno_follows_icmp_errmap_test() ->
    E = fun(T, C) -> erx_icmp4:errno(#icmp4{type = T, code = C, msg = {error, 0}}) end,
    ?assertEqual([ehostunreach, ehostunreach, econnrefused, econnrefused, emsgsize, ehostunreach],
                 [E(3, C) || C <- [0, 1, 2, 3, 4, 5]]),
    ?assertEqual([econnrefused, ehostunreach, ehostunreach], [E(3, 13), E(3, 15), E(11, 0)]),
    ?assertEqual([none, enoprotoopt, none], [E(11, 1), E(12, 0), E(12, 2)]).

%% erx_icmp4:error/5

error_quotes_header_and_up_to_548_bytes_test() ->
    Packet = packet(#{}, <<0:1000/unit:8>>),
    {[{send, Out, Msg}], _} = erx_icmp4:error({unreach, 3}, Packet, ?CTX(0), lim()),
    ?assertEqual(#{src => ?ME, dst => ?PEER, proto => 1}, Out),
    {ok, #icmp4{type = 3, code = 3}, Quote} = erx_icmp4_wire:decode(iolist_to_binary(Msg)),
    ?assertEqual(binary:part(Packet, 0, 20 + 548), Quote),
    {[{send, _, Pp}], _} = erx_icmp4:error({param_problem, 21}, Packet, ?CTX(0), lim()),
    ?assertMatch({ok, #icmp4{type = 12, code = 0, msg = {error, 21 bsl 24}}, _},
                 erx_icmp4_wire:decode(iolist_to_binary(Pp))).

no_error_where_icmp_error_sends_none_test() ->
    IcmpErr = packet(#{p => 1}, <<3, 3, 0:48>>),
    IcmpEcho = packet(#{p => 1}, <<8, 0, 0:48>>),
    %% A datagram of 4 payload bytes padded to 28 by its frame: its total length decides.
    Padded = <<(packet(#{}, <<1, 2, 3, 4>>))/binary, 0:32>>,
    Cases = [packet(#{off => 1}), packet(#{rf => 1}), IcmpErr, binary:part(packet(#{}), 0, 27), Padded],
    [?assertMatch({[], _}, erx_icmp4:error({unreach, 3}, P, ?CTX(0), lim())) || P <- Cases],
    ?assertMatch({[_], _}, erx_icmp4:error({unreach, 3}, IcmpEcho, ?CTX(0), lim())),
    ?assertMatch({[_], _}, erx_icmp4:error({unreach, 3}, packet(#{mf => 1}), ?CTX(0), lim())).

%% erx_net_bandlim

%% Property under virtual time: in every one-second window the answers allowed stay within
%% icmplim and its jitter, a window that went over is followed by one with a new jitter,
%% and a quiet second lets answers through again.
limits_hold_under_virtual_time_test() ->
    _ = rand:seed(exsss, {3, 1, 4}),
    lists:foreach(fun(Key) -> windows(erx_net_bandlim:new(erx_net_rand:new(<<Key:128>>))) end, lists:seq(1, 20)).

windows(Lim0) ->
    {Counts, _} = lists:mapfoldl(fun(Second, Lim) -> burst(Second * 1000, 400, Lim) end, Lim0, lists:seq(0, 9)),
    [?assert(C >= 184 andalso C =< 216) || C <- Counts],
    ?assert(length(lists:usort(Counts)) > 1).

burst(Start, N, Lim0) ->
    lists:foldl(fun(I, {Allowed, Lim}) ->
                        case erx_net_bandlim:check(icmp_echo, Start + I * 900 div N, Lim) of
                            {allow, Lim1} -> {Allowed + 1, Lim1};
                            {deny, Lim1} -> {Allowed, Lim1}
                        end
                end, {0, Lim0}, lists:seq(0, N - 1)).

kinds_are_limited_separately_test() ->
    {_, Lim} = burst(0, 400, lim()),
    ?assertMatch({deny, _}, erx_net_bandlim:check(icmp_echo, 950, Lim)),
    ?assertMatch({allow, _}, erx_net_bandlim:check(icmp_unreach, 950, Lim)),
    ?assertMatch({allow, _}, erx_net_bandlim:check(icmp_echo, 1950, Lim)).

%% erx_udp

udp_delivery_and_port_unreachable_test() ->
    ?assertEqual({deliver, [a]}, erx_udp:input(unicast, true, [a, b])),
    ?assertEqual({deliver, [a]}, erx_udp:input(unicast, false, [a, b])),
    ?assertEqual(port_unreach, erx_udp:input(unicast, true, [])),
    ?assertEqual({drop, no_port}, erx_udp:input(unicast, false, [])),
    ?assertEqual({drop, no_port}, erx_udp:input(broadcast, false, [])),
    ?assertEqual({deliver, [a, b]}, erx_udp:input(broadcast, false, [a, b])),
    ?assertEqual({notify, econnrefused}, erx_udp:report(#icmp4{type = 3, code = 3, msg = {error, 0}})),
    ?assertEqual(ignore, erx_udp:report(#icmp4{type = 11, code = 1, msg = {error, 0}})).
