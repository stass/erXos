%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_tcp_ecn: RFC 3168's negotiation in FreeBSD's mode 2 and the ECE/CWR exchange.
-module(erx_tcp_ecn_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp_wire.hrl").

-define(CE, 3).
-define(ECT0, 2).

%% A listener grants ECN to a SYN with ECE and CWR, AccECN's included, and says so with ECE
%% on its SYN-ACK; it stops after a second SYN-ACK retransmission.
passive_open_test() ->
    ?assert(erx_tcp_ecn:syncache_add(?TH_SYN bor ?TH_ECE bor ?TH_CWR)),
    ?assert(erx_tcp_ecn:syncache_add(?TH_SYN bor ?TH_ECE bor ?TH_CWR bor ?TH_AE)),
    ?assertNot(erx_tcp_ecn:syncache_add(?TH_SYN bor ?TH_ECE)),
    ?assertEqual(?TH_SYN bor ?TH_ACK bor ?TH_ECE,
                 erx_tcp_ecn:syncache_respond(?TH_SYN bor ?TH_ACK, true)),
    ?assertEqual(?TH_SYN bor ?TH_ACK, erx_tcp_ecn:syncache_respond(?TH_SYN bor ?TH_ACK, false)),
    ?assert(erx_tcp_ecn:syncache_retransmit(1, true)),
    ?assertNot(erx_tcp_ecn:syncache_retransmit(2, true)),
    ?assert(erx_tcp_ecn:enabled(erx_tcp_ecn:syncache_socket(true))),
    ?assertNot(erx_tcp_ecn:enabled(erx_tcp_ecn:syncache_socket(false))).

%% An active open starts without ECN; a SYN-ACK with ECE alone turns it on, one with ECE and
%% CWR does not.
active_open_test() ->
    New = erx_tcp_ecn:new(),
    ?assertNot(erx_tcp_ecn:enabled(New)),
    ?assert(erx_tcp_ecn:enabled(erx_tcp_ecn:input_syn_sent(?TH_SYN bor ?TH_ACK bor ?TH_ECE, New))),
    ?assertNot(erx_tcp_ecn:enabled(
                 erx_tcp_ecn:input_syn_sent(?TH_SYN bor ?TH_ACK bor ?TH_ECE bor ?TH_CWR, New))),
    ?assertEqual({0, 0, New}, erx_tcp_ecn:output(data(#{}), New)),
    ?assertEqual({false, false, New}, erx_tcp_ecn:input_segment(?TH_ECE, ?CE, New)).

%% A simultaneous open's SYN with ECE and CWR owes one ECE, sent on the SYN-ACK.
parallel_syn_test() ->
    On = erx_tcp_ecn:input_parallel_syn(?TH_SYN bor ?TH_ECE bor ?TH_CWR, erx_tcp_ecn:new()),
    SynAck = data(#{len => 0, phase => syn_received}),
    {?TH_ECE, 0, After} = erx_tcp_ecn:output(SynAck, On),
    ?assertMatch({0, 0, _}, erx_tcp_ecn:output(SynAck, After)),
    ?assertNot(erx_tcp_ecn:enabled(
                 erx_tcp_ecn:input_parallel_syn(?TH_SYN bor ?TH_ACK bor ?TH_ECE bor ?TH_CWR,
                                                erx_tcp_ecn:new()))).

%% The receiver: a CE mark makes it send ECE until the sender's CWR, which also forces an ACK.
receiver_test() ->
    On = erx_tcp_ecn:syncache_socket(true),
    {false, false, Marked} = erx_tcp_ecn:input_segment(?TH_ACK, ?CE, On),
    ?assertMatch({?TH_ECE, ?ECT0, _}, erx_tcp_ecn:output(data(#{}), Marked)),
    ?assertMatch({?TH_ECE, 0, _}, erx_tcp_ecn:output(data(#{len => 0}), Marked)),
    {false, true, Cleared} = erx_tcp_ecn:input_segment(?TH_ACK bor ?TH_CWR, ?ECT0, Marked),
    ?assertMatch({0, ?ECT0, _}, erx_tcp_ecn:output(data(#{}), Cleared)).

%% The sender: an echoed ECE (not on a SYN) is a congestion signal; after the window
%% reduction CWR goes on the next new data only, not on a retransmission or window probe.
sender_test() ->
    On = erx_tcp_ecn:syncache_socket(true),
    ?assertMatch({true, false, _}, erx_tcp_ecn:input_segment(?TH_ACK bor ?TH_ECE, ?ECT0, On)),
    ?assertMatch({false, false, _},
                 erx_tcp_ecn:input_segment(?TH_SYN bor ?TH_ACK bor ?TH_ECE, ?ECT0, On)),
    Reduced = erx_tcp_ecn:signal_cwr(On),
    {0, 0, Reduced} = erx_tcp_ecn:output(data(#{snd_nxt => 900}), Reduced),
    {0, 0, Reduced} = erx_tcp_ecn:output(data(#{len => 1, forced => true}), Reduced),
    {?TH_CWR, ?ECT0, Said} = erx_tcp_ecn:output(data(#{}), Reduced),
    ?assertMatch({0, ?ECT0, _}, erx_tcp_ecn:output(data(#{}), Said)),
    ?assertEqual(erx_tcp_ecn:new(), erx_tcp_ecn:signal_cwr(erx_tcp_ecn:new())).

%% A segment of 100 new bytes on a synchronized connection, with Overrides.
data(Overrides) ->
    maps:merge(#{len => 100, snd_nxt => 1000, snd_max => 1000, retransmit => false,
                 forced => false, phase => synchronized}, Overrides).
