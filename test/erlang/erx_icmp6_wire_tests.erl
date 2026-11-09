%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_icmp6_wire_tests).
-moduledoc """
EUnit cases of erx_icmp6_wire over hand-built messages: the codes and
lengths each known type accepts, the neighbour-discovery option rules of
nd6_options and nd6_ra_input, and encode/decode agreement.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip6.hrl").

-define(TARGET, <<16#fe80:16, 0:48, 2:64>>).
-define(MAC, <<2, 0, 0, 0, 0, 1>>).

-define(SRC, <<16#fe80:16, 0:48, 1:64>>).

msg(Type, Code, Body) -> <<Type, Code, 0:16, Body/binary>>.

pseudo(Len) -> erx_ip6_wire:pseudo_sum(?SRC, ?TARGET, Len, ?IPPROTO_ICMPV6).

%% Decodes Message from ?SRC to ?TARGET with its checksum set right.
decode(<<Type, Code, _:16, Body/binary>> = Message) ->
    Sum = bnot erx_bytes:inet_csum(pseudo(byte_size(Message)), <<Type, Code, 0:16, Body/binary>>) band 16#ffff,
    erx_icmp6_wire:decode(pseudo(byte_size(Message)), <<Type, Code, Sum:16, Body/binary>>);
decode(Message) ->
    erx_icmp6_wire:decode(0, Message).

checksum_is_checked_first_test() ->
    Echo = #icmp6{type = ?ICMP6_ECHO_REQUEST, code = 0, msg = {echo, 7, 9}},
    Sealed = iolist_to_binary(erx_icmp6_wire:encode(Echo, <<>>, {?SRC, ?TARGET})),
    ?assertEqual({ok, Echo, <<>>}, erx_icmp6_wire:decode(pseudo(8), Sealed)),
    <<Head:2/binary, Sum:16, Tail/binary>> = Sealed,
    ?assertEqual({error, bad_sum}, erx_icmp6_wire:decode(pseudo(8), <<Head/binary, (Sum bxor 1):16, Tail/binary>>)),
    %% The pseudo-header counts: the sum is wrong for other addresses.
    Other = erx_ip6_wire:pseudo_sum(?TARGET, ?TARGET, 8, ?IPPROTO_ICMPV6),
    ?assertEqual({error, bad_sum}, erx_icmp6_wire:decode(Other, Sealed)).

%% A neighbour solicitation for ?TARGET with the given options.
ns(Opts) -> msg(?ND_NEIGHBOR_SOLICIT, 0, <<0:32, ?TARGET/binary, Opts/binary>>).

slla(Mac) -> <<1, 1, Mac/binary>>.
mtu(Len, Mtu) -> <<5, Len, 0:16, Mtu:32, 0:((Len - 1) * 64)>>.
prefix(Len, Plen) -> <<3, Len, Plen, 16#c0, 100:32, 50:32, 0:32, ?TARGET/binary, 0:((Len - 4) * 64)>>.

echo_test() ->
    ?assertEqual({ok, #icmp6{type = ?ICMP6_ECHO_REQUEST, code = 0, msg = {echo, 7, 9}}, <<"data">>},
                 decode(msg(?ICMP6_ECHO_REQUEST, 0, <<7:16, 9:16, "data">>))),
    ?assertEqual({error, bad_code}, decode(msg(?ICMP6_ECHO_REPLY, 1, <<0:32>>))),
    ?assertEqual({error, too_short}, decode(<<128, 0, 0:16, 0:24>>)).

error_messages_test() ->
    Invoking = <<6:4, 0:316>>,
    ?assertEqual({ok, #icmp6{type = ?ICMP6_PACKET_TOO_BIG, code = 0, msg = {error, 1280}}, Invoking},
                 decode(msg(?ICMP6_PACKET_TOO_BIG, 0, <<1280:32, Invoking/binary>>))),
    ?assertEqual({error, bad_length},
                 decode(msg(?ICMP6_DST_UNREACH, 4, <<0:32, 0:(39 * 8)>>))),
    ?assertEqual({error, bad_code}, decode(msg(?ICMP6_DST_UNREACH, 5, <<0:32, Invoking/binary>>))),
    ?assertEqual({error, bad_code}, decode(msg(?ICMP6_PARAM_PROB, 3, <<0:32, Invoking/binary>>))),
    %% An error type icmp6_input does not know is passed on with any code.
    ?assertMatch({ok, #icmp6{type = 100, code = 9, msg = {error, 0}}, _},
                 decode(msg(100, 9, <<0:32, Invoking/binary>>))).

neighbour_solicitation_test() ->
    ?assertEqual({ok, #icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, ?TARGET, #{slla => ?MAC}}}, <<>>},
                 decode(ns(slla(?MAC)))),
    ?assertEqual({error, bad_length}, decode(binary:part(ns(<<>>), 0, 23))),
    ?assertEqual({error, bad_code},
                 decode(msg(?ND_NEIGHBOR_SOLICIT, 1, <<0:32, ?TARGET/binary>>))).

malformed_options_refuse_the_message_test() ->
    ?assertEqual({error, bad_option}, decode(ns(<<1, 0, 0:48>>))),
    ?assertEqual({error, bad_option}, decode(ns(<<1, 2, 0:48>>))),
    ?assertEqual({error, bad_option}, decode(ns(<<(slla(?MAC))/binary, 1>>))).

option_rules_test() ->
    Other = <<2, 0, 0, 0, 0, 2>>,
    %% The first of each single option counts.
    ?assertMatch({ok, #icmp6{msg = {ns, _, #{slla := ?MAC}}}, <<>>},
                 decode(ns(<<(slla(?MAC))/binary, (slla(Other))/binary>>))),
    %% A first MTU option of the wrong length hides a later good one.
    Ra = fun(Opts) -> msg(?ND_ROUTER_ADVERT, 0, <<64, 16#80, 1800:16, 0:32, 0:32, Opts/binary>>) end,
    ?assertEqual({ok, #icmp6{type = ?ND_ROUTER_ADVERT, code = 0,
                             msg = {ra, 64, 16#80, 1800, 0, 0, #{}}}, <<>>},
                 decode(Ra(<<(mtu(2, 9000))/binary, (mtu(1, 1500))/binary>>))),
    %% Every prefix option of length 4 counts, in order; others are skipped.
    {ok, #icmp6{msg = {ra, _, _, _, _, _, #{mtu := 1500, prefixes := Prefixes}}}, <<>>} =
        decode(Ra(<<(prefix(4, 64))/binary, (prefix(5, 48))/binary,
                                   (mtu(1, 1500))/binary, (prefix(4, 56))/binary>>)),
    ?assertEqual([64, 56], [Len || #{len := Len} <- Prefixes]).

options_past_the_count_are_ignored_test() ->
    Eleven = binary:copy(<<99, 1, 0:48>>, 10),
    ?assertMatch({ok, #icmp6{msg = {ns, _, #{slla := ?MAC}}}, <<>>},
                 decode(ns(<<Eleven/binary, (slla(?MAC))/binary, 1, 0>>))),
    ?assertMatch({ok, #icmp6{msg = {ns, _, #{}}}, <<>>},
                 decode(ns(<<Eleven/binary, 99, 1, 0:48, (slla(?MAC))/binary>>))).

redirect_and_other_test() ->
    Packet = <<6:4, 0:316>>,
    Redirect = msg(?ND_REDIRECT, 0, <<0:32, ?TARGET/binary, ?TARGET/binary,
                                      4, 6, 0:48, Packet/binary>>),
    ?assertMatch({ok, #icmp6{msg = {redirect, ?TARGET, ?TARGET, #{redirected := Packet}}}, <<>>},
                 decode(Redirect)),
    ?assertEqual({error, bad_length}, decode(binary:part(Redirect, 0, 39))),
    ?assertEqual({ok, #icmp6{type = 130, code = 0, msg = other}, <<0:32, "mld">>},
                 decode(msg(130, 0, <<0:32, "mld">>))).

encode_decode_agree_test() ->
    Opts = #{slla => ?MAC, tlla => <<1, 2, 3, 4, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0>>,
             prefixes => [#{len => 64, flags => 16#c0, valid => 1, preferred => 2, prefix => ?TARGET}],
             mtu => 1500, redirected => <<0:64>>, nonce => <<1, 2, 3, 4, 5, 6>>},
    Messages = [{#icmp6{type = ?ND_ROUTER_ADVERT, code = 0, msg = {ra, 64, 8, 9, 10, 11, Opts}}, <<>>},
                {#icmp6{type = ?ND_NEIGHBOR_ADVERT, code = 0, msg = {na, 5, ?TARGET, #{tlla => ?MAC}}}, <<>>},
                {#icmp6{type = ?ND_ROUTER_SOLICIT, code = 0, msg = {rs, #{}}}, <<>>},
                {#icmp6{type = ?ND_REDIRECT, code = 0, msg = {redirect, ?TARGET, ?TARGET, #{}}}, <<>>},
                {#icmp6{type = ?ICMP6_ECHO_REPLY, code = 0, msg = {echo, 1, 2}}, <<"x">>},
                {#icmp6{type = ?ICMP6_TIME_EXCEEDED, code = 1, msg = {error, 0}}, <<0:320>>},
                {#icmp6{type = 200, code = 3, msg = other}, <<"opaque">>}],
    [?assertEqual({ok, Message, Rest},
                  erx_icmp6_wire:decode(pseudo(iolist_size(erx_icmp6_wire:encode(Message, Rest, {?SRC, ?TARGET}))),
                                        iolist_to_binary(erx_icmp6_wire:encode(Message, Rest, {?SRC, ?TARGET}))))
     || {Message, Rest} <- Messages].
