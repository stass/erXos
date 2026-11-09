%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases for erx_nd6_dad, duplicate address detection: a clean run with its delay and
%% nonce drawn from the generator, a duplicate found from another node's probe or
%% advertisement, and RFC 7527's looped-back probe.
-module(erx_nd6_dad_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip6.hrl").

-define(ADDR, <<16#FE80:16, 0:48, 16#0211:16, 16#22FF:16, 16#FE33:16, 16#4455:16>>).
-define(GROUP, <<16#FF02:16, 0:64, 1:16, 16#FF, 16#33, 16#44, 16#55>>).
-define(RETRANS, 1000).

gen() ->
    erx_net_rand:new(<<7:128>>).

%% The first probe goes out after a delay of up to a second, with a nonce; the delay and
%% the nonce are the generator's successive draws. Unanswered, the address is unique one
%% retransmission interval later.
clean_detection_test() ->
    {First, Gen1} = erx_net_rand:uniform(1000, gen()),
    {Nonce, _} = erx_net_rand:bytes(6, Gen1),
    D0 = erx_nd6_dad:start(?ADDR, 0, erx_nd6_dad:new(gen())),
    ?assertEqual(First, erx_nd6_dad:next_deadline(D0)),
    ?assertEqual({D0, []}, erx_nd6_dad:expired(First - 1, ?RETRANS, D0)),
    ?assertEqual(D0, erx_nd6_dad:start(?ADDR, 500, D0)),
    {D1, [Probe]} = erx_nd6_dad:expired(First, ?RETRANS, D0),
    ?assertEqual({send_nd, <<0:128>>, ?GROUP,
                  #icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, ?ADDR, #{nonce => Nonce}}}},
                 Probe),
    ?assertEqual(First + ?RETRANS, erx_nd6_dad:next_deadline(D1)),
    {D2, [{dad_done, ?ADDR, ok}]} = erx_nd6_dad:expired(First + ?RETRANS, ?RETRANS, D1),
    ?assertNot(erx_nd6_dad:probing(?ADDR, D2)),
    ?assertEqual(infinity, erx_nd6_dad:next_deadline(D2)).

%% Another node's probe, with no nonce or another one, or its advertisement makes the
%% address duplicated when the detection ends, not before; so does another node's probe
%% during the delay, before the interface's own probe has a nonce. A message about an
%% address under no detection, or a stopped detection, changes nothing.
duplicate_test() ->
    {D1, Decide, Nonce} = first_probe(),
    <<B, Rest/binary>> = Nonce,
    Other = <<(B bxor 1), Rest/binary>>,
    lists:foreach(fun(Msg) ->
                          D2 = erx_nd6_dad:input(Msg, D1),
                          ?assertEqual({D2, []}, erx_nd6_dad:expired(Decide - 1, ?RETRANS, D2)),
                          ?assertMatch({_, [{dad_done, ?ADDR, duplicated}]},
                                       erx_nd6_dad:expired(Decide, ?RETRANS, D2))
                  end, [{ns, ?ADDR, none}, {ns, ?ADDR, Other}, {na, ?ADDR}]),
    D0 = erx_nd6_dad:start(?ADDR, 0, erx_nd6_dad:new(gen())),
Early = erx_nd6_dad:input({ns, ?ADDR, none}, D0),
{Probed, [{send_nd, _, _, _}]} = erx_nd6_dad:expired(Decide - ?RETRANS, ?RETRANS, Early),
?assertMatch({_, [{dad_done, ?ADDR, duplicated}]}, erx_nd6_dad:expired(Decide, ?RETRANS, Probed)),
?assertEqual(D1, erx_nd6_dad:input({na, <<1:128>>}, D1)),
    Stopped = erx_nd6_dad:stop(?ADDR, erx_nd6_dad:input({na, ?ADDR}, D1)),
    ?assertEqual({Stopped, []}, erx_nd6_dad:expired(Decide, ?RETRANS, Stopped)).

%% The interface's own probe coming back is no duplicate: two more probes go out, and two
%% more again after the last one comes back, counted from the probes already sent; with no
%% other answer the address is unique (RFC 7527 4.1, nd6_dad_timer).
looped_back_probe_test() ->
    {D1, T, Nonce} = first_probe(),
    D2 = erx_nd6_dad:input({ns, ?ADDR, Nonce}, D1),
    {D3, [{send_nd, _, ?GROUP, _}]} = erx_nd6_dad:expired(T, ?RETRANS, D2),
    {D4, [{send_nd, _, ?GROUP, #icmp6{msg = {ns, ?ADDR, #{nonce := Third}}}}]} =
        erx_nd6_dad:expired(T + ?RETRANS, ?RETRANS, D3),
    D5 = erx_nd6_dad:input({ns, ?ADDR, Third}, D4),
    {D6, [{send_nd, _, ?GROUP, _}]} = erx_nd6_dad:expired(T + 2 * ?RETRANS, ?RETRANS, D5),
    {D7, [{send_nd, _, ?GROUP, _}]} = erx_nd6_dad:expired(T + 3 * ?RETRANS, ?RETRANS, D6),
    ?assertMatch({_, [{dad_done, ?ADDR, ok}]},
                 erx_nd6_dad:expired(T + 4 * ?RETRANS, ?RETRANS, D7)).

%% A detection after its first probe, when it decides, and the probe's nonce.
first_probe() ->
    D0 = erx_nd6_dad:start(?ADDR, 0, erx_nd6_dad:new(gen())),
    First = erx_nd6_dad:next_deadline(D0),
    {D1, [{send_nd, _, _, #icmp6{msg = {ns, ?ADDR, #{nonce := Nonce}}}}]} =
        erx_nd6_dad:expired(First, ?RETRANS, D0),
    {D1, First + ?RETRANS, Nonce}.
