%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_tcp_mss: FreeBSD's MSS decisions on the paths a connection meets, and
%% tcp_compute_initwnd's cases.
-module(erx_tcp_mss_tests).

-include_lib("eunit/include/eunit.hrl").

%% RFC 6928's ten segments, capped at max(2 segments, 14,600 bytes).
initwnd_test() ->
    ?assertEqual(14600, erx_tcp_mss:initwnd(1460)),
    ?assertEqual(5360, erx_tcp_mss:initwnd(536)),
    ?assertEqual(14400, erx_tcp_mss:initwnd(1440)),
    ?assertEqual(14600, erx_tcp_mss:initwnd(4000)),
    ?assertEqual(18000, erx_tcp_mss:initwnd(9000)).

update_test() ->
    %% The peer's offer, the path MTU less headers, whichever is smaller.
    ?assertEqual(1460, erx_tcp_mss:update(inet, 1460, 1500, 0)),
    ?assertEqual(1440, erx_tcp_mss:update(inet6, 9000, 1500, 0)),
    ?assertEqual(1000, erx_tcp_mss:update(inet, 1000, 1500, 0)),
    %% No MSS option: the family's default.
    ?assertEqual(536, erx_tcp_mss:update(inet, none, 1500, 0)),
    ?assertEqual(1220, erx_tcp_mss:update(inet6, 0, 1500, 0)),
    %% A tiny offer is raised to tcp_minmss.
    ?assertEqual(216, erx_tcp_mss:update(inet, 1, 1500, 0)),
    %% No route: the default, whatever the offer.
    ?assertEqual(536, erx_tcp_mss:update(inet, 1460, 0, 0)),
    %% The host cache's smaller MTU wins.
    ?assertEqual(1360, erx_tcp_mss:update(inet, 1460, 1500, 1400)),
    %% An ICMP report's MTU, and one leaving no room, which reads as no offer.
    ?assertEqual(1220, erx_tcp_mss:update(inet6, {mtu, 1280}, 1500, 0)),
    ?assertEqual(536, erx_tcp_mss:update(inet, {mtu, 40}, 1500, 0)).

%% tcp_mss: a send buffer below one segment lowers the MSS (never below 64); otherwise the
%% buffers round up to whole segments within the ceiling.
mss_test() ->
    ?assertEqual({1460, 65700, 131400}, erx_tcp_mss:mss(inet, 1460, {1500, 0}, {65536, 131072}, 1 bsl 21)),
    ?assertEqual({1460, 65536, 65536}, erx_tcp_mss:mss(inet, 1460, {1500, 0}, {65536, 65536}, 65536)),
    ?assertEqual({1000, 1000, 4000}, erx_tcp_mss:mss(inet, 1460, {1500, 0}, {1000, 3500}, 1 bsl 21)),
    ?assertEqual({64, 30, 60}, erx_tcp_mss:mss(inet, 1460, {1500, 0}, {30, 50}, 1 bsl 21)).

mssopt_test() ->
    ?assertEqual(1460, erx_tcp_mss:mssopt(inet, 1500, 0)),
    ?assertEqual(536, erx_tcp_mss:mssopt(inet, 0, 0)),
    ?assertEqual(1340, erx_tcp_mss:mssopt(inet6, 1500, 1400)),
    ?assertEqual(1340, erx_tcp_mss:mssopt(inet6, 0, 1400)).

%% tcp_maxseg's option overhead, padded as tcp_addoptions pads it.
maxseg_test() ->
    ?assertEqual(1460, erx_tcp_mss:maxseg(1460, noopt)),
    ?assertEqual(1460, erx_tcp_mss:maxseg(1460, {synchronized, false, 0})),
    ?assertEqual(1448, erx_tcp_mss:maxseg(1460, {synchronized, true, 0})),
    ?assertEqual(1420, erx_tcp_mss:maxseg(1460, {synchronized, true, 3})),
    ?assertEqual(1424, erx_tcp_mss:maxseg(1460, {synchronized, false, 4})),
    ?assertEqual(1420, erx_tcp_mss:maxseg(1460, {synchronized, true, 4})),
    ?assertEqual(1440, erx_tcp_mss:maxseg(1460, {handshake, [ts, wscale, sack]})),
    ?assertEqual(1448, erx_tcp_mss:maxseg(1460, {handshake, [wscale, sack]})).

sack_prohibited_test() ->
    ?assert(erx_tcp_mss:sack_prohibited(535)),
    ?assertNot(erx_tcp_mss:sack_prohibited(536)).
