%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The grant's sockets and their buffer reservations (erx_net_grant_core;
%% docs/design-network-stack.md, "Sockets act for one domain", the `sockets` and `buffers`
%% limits of "The grant").
-module(erx_net_grant_core_tests).

-include_lib("eunit/include/eunit.hrl").

%% A socket opens with both buffers reserved, within the limit; the limit is inclusive.
open_within_the_limit_test() ->
    B0 = new(#{buffers => 1000}),
    ?assertEqual(1000, erx_net_grant_core:room(B0)),
    {ok, B1} = erx_net_grant_core:open(a, make_ref(), #{snd => 300, rcv => 400}, B0),
    ?assertEqual(300, erx_net_grant_core:room(B1)),
    ?assertEqual({error, enobufs},
                 erx_net_grant_core:open(b, make_ref(), #{snd => 200, rcv => 101}, B1)),
    {ok, B2} = erx_net_grant_core:open(b, make_ref(), #{snd => 200, rcv => 100}, B1),
    ?assertEqual(0, erx_net_grant_core:room(B2)).

%% Growing a buffer charges only the difference, and a refusal changes nothing; shrinking
%% always fits and gives the difference back.
reserve_charges_the_difference_test() ->
    T = make_ref(),
    {ok, B0} = erx_net_grant_core:open(a, T, #{snd => 300, rcv => 400},
                                       new(#{buffers => 1000})),
    {ok, B1} = erx_net_grant_core:reserve(a, T, snd, 600, B0),
    ?assertEqual(0, erx_net_grant_core:room(B1)),
    ?assertEqual({error, enobufs}, erx_net_grant_core:reserve(a, T, rcv, 401, B1)),
    {ok, B2} = erx_net_grant_core:reserve(a, T, rcv, 100, B1),
    ?assertEqual(300, erx_net_grant_core:room(B2)).

%% Only the token a socket opened with reserves or releases for it: another token, or a
%% socket the grant did not open, changes nothing and is refused with badarg, as is a second
%% open of a socket already open.
only_the_socket_token_acts_test() ->
    T = make_ref(),
    B0 = new(#{buffers => 1000}),
    ?assertEqual({error, badarg}, erx_net_grant_core:reserve(a, T, snd, 1, B0)),
    {ok, B1} = erx_net_grant_core:open(a, T, #{snd => 300, rcv => 400}, B0),
    ?assertEqual({error, badarg}, erx_net_grant_core:open(a, T, #{snd => 1, rcv => 1}, B1)),
    ?assertEqual({error, badarg}, erx_net_grant_core:reserve(a, make_ref(), snd, 0, B1)),
    ?assertEqual({error, badarg}, erx_net_grant_core:reserve(b, T, snd, 0, B1)),
    ?assertEqual({error, badarg}, erx_net_grant_core:release(a, make_ref(), B1)),
    ?assertEqual({error, badarg}, erx_net_grant_core:release(b, T, B1)),
    ?assertEqual(300, erx_net_grant_core:room(B1)).

%% A socket that gives its buffers back frees both and its place among the grant's sockets,
%% as a connection in TIME-WAIT whose socket process is gone is none of them: the grant
%% forgets it, so its token reserves nothing more and its later exit changes nothing. The
%% exit of an open socket frees what it holds, and that of a socket never opened nothing.
release_and_exit_free_both_buffers_test() ->
    T = make_ref(),
    {ok, B0} = erx_net_grant_core:open(a, T, #{snd => 300, rcv => 400},
                                       new(#{buffers => 1000, sockets => 1})),
    {ok, B1} = erx_net_grant_core:release(a, T, B0),
    ?assertEqual(1000, erx_net_grant_core:room(B1)),
    ?assertEqual({error, badarg}, erx_net_grant_core:reserve(a, T, snd, 100, B1)),
    ?assertEqual({error, badarg}, erx_net_grant_core:release(a, T, B1)),
    ?assertEqual(B1, erx_net_grant_core:exited(a, B1)),
    {ok, B2} = erx_net_grant_core:open(b, make_ref(), #{snd => 300, rcv => 400}, B1),
    B3 = erx_net_grant_core:exited(b, B2),
    ?assertEqual(1000, erx_net_grant_core:room(B3)),
    ?assertEqual(B3, erx_net_grant_core:exited(c, B3)),
    ?assertMatch({ok, _}, erx_net_grant_core:open(c, make_ref(), #{snd => 0, rcv => 0}, B3)).

%% The `sockets` limit counts every open socket, one that holds no buffer too, and is
%% inclusive. Past it an open is refused emfile and records nothing, ahead of a buffer
%% refusal, as a FreeBSD socket's descriptor is allocated before its buffers are reserved.
%% An exit gives the place back.
sockets_limit_test() ->
    None = #{snd => 0, rcv => 0},
    B0 = new(#{sockets => 2, buffers => 100}),
    ?assertEqual(ok, erx_net_grant_core:admits(None, B0)),
    {ok, B1} = erx_net_grant_core:open(a, make_ref(), None, B0),
    ?assertEqual({error, enobufs}, erx_net_grant_core:admits(#{snd => 50, rcv => 51}, B1)),
    {ok, B2} = erx_net_grant_core:open(b, make_ref(), #{snd => 50, rcv => 50}, B1),
    ?assertEqual({error, emfile}, erx_net_grant_core:admits(None, B2)),
    ?assertEqual({error, emfile}, erx_net_grant_core:open(c, make_ref(), None, B2)),
    B3 = erx_net_grant_core:exited(b, B2),
    ?assertEqual({error, emfile}, erx_net_grant_core:open(c, make_ref(), #{snd => 101, rcv => 0},
                                                          new(#{sockets => 0, buffers => 100}))),
    ?assertEqual(ok, erx_net_grant_core:admits(None, B3)),
    {ok, B4} = erx_net_grant_core:open(c, make_ref(), None, B3),
    ?assertEqual({error, emfile}, erx_net_grant_core:admits(None, B4)).

%% The design's defaults: 16 MiB across the grant's sockets, and 1,024 sockets.
default_limit_test() ->
    ?assertEqual(16 * 1024 * 1024, erx_net_grant_core:room(new(#{}))),
    None = #{snd => 0, rcv => 0},
    Open = fun(N, B) -> {ok, B1} = erx_net_grant_core:open(N, make_ref(), None, B), B1 end,
    Full = lists:foldl(Open, new(#{}), lists:seq(1, 1024)),
    ?assertEqual({error, emfile}, erx_net_grant_core:admits(None, Full)).

%% A `sockets` or `buffers` limit that is not a non-negative integer is refused.
malformed_limits_refused_test() ->
    [?assertEqual({error, badarg}, erx_net_grant_core:new(Limits))
     || Limits <- [#{sockets => -1}, #{sockets => x}, #{buffers => 1.5}, #{buffers => -1}]].

%% --- bind_ports/3----------------------------------------------------------------

bind_ports_defaults_test() ->
    ?assertEqual({ok, [{1024, 65535}]}, erx_net_grant_core:bind_ports(tcp_listen, any, #{})),
    ?assertEqual({ok, [{1024, 65535}]}, erx_net_grant_core:bind_ports(udp, {10, 0, 2, 15}, #{})).

bind_ports_listen_narrows_ports_test() ->
    Limits = #{ports => [{22, 22}, {8000, 8999}], listen => [{1, 100}, {8080, 9100}]},
    ?assertEqual({ok, [{22, 22}, {8080, 8999}]}, erx_net_grant_core:bind_ports(tcp_listen, any, Limits)),
    %% A datagram socket's bind is not a listen.
    ?assertEqual({ok, [{22, 22}, {8000, 8999}]}, erx_net_grant_core:bind_ports(udp, any, Limits)),
    ?assertEqual({ok, []}, erx_net_grant_core:bind_ports(tcp_listen, any, Limits#{listen := [{9000, 9100}]})),
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(tcp_listen, any, Limits#{listen := false})),
    ?assertEqual({ok, [{22, 22}, {8000, 8999}]}, erx_net_grant_core:bind_ports(udp, any, Limits#{listen := false})).

bind_ports_addresses_test() ->
    Limits = #{addresses => [{10, 0, 2, 15}]},
    ?assertEqual({ok, [{1024, 65535}]}, erx_net_grant_core:bind_ports(tcp_listen, {10, 0, 2, 15}, Limits)),
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(tcp_listen, {10, 0, 2, 16}, Limits)),
    %% The wildcard would reach addresses the grant was not given.
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(tcp_listen, any, Limits)),
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(udp, any, Limits)).

bind_ports_malformed_limits_fail_closed_test() ->
    ?assertEqual({ok, [{8000, 8001}]},
                 erx_net_grant_core:bind_ports(udp, any, #{ports => [{8000, 8001}, {0, 5}, {9, 3}, {1, 65536}, x]})),
    ?assertEqual({ok, []}, erx_net_grant_core:bind_ports(udp, any, #{ports => [{1, 2} | x]})),
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(tcp_listen, any, #{listen => maybe_not})),
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(udp, {10, 0, 2, 15}, #{addresses => none})),
    ?assertEqual({error, eacces}, erx_net_grant_core:bind_ports(udp, {10, 0, 2, 15}, #{addresses => [{10, 0, 2, 15} | x]})).

%% A core of Limits, which the case knows are well formed.
new(Limits) ->
    {ok, Sockets} = erx_net_grant_core:new(Limits),
    Sockets.
