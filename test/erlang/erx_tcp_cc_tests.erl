%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases for the congestion modules (erx_tcp_cc, erx_tcp_cc_newreno, erx_tcp_cc_cubic):
%% each case drives a module through the callbacks a connection makes and checks the windows
%% FreeBSD's cc_newreno.c and cc_cubic.c compute for the same inputs, worked out by hand.
%% CUBIC's fixed-point functions are compared with FreeBSD's own by
%% test/host/erx_tcp_cc_cubic_oracle_test.rb.
-module(erx_tcp_cc_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp_cc.hrl").

-define(MSS, 1000).
-define(MODULES, [erx_tcp_cc_newreno, erx_tcp_cc_cubic]).

%% A new connection's record for Module: ten segments in slow start, nothing in flight.
base(Module) ->
    Module:conn_init(#ccv{cwnd = 10 * ?MSS, ssthresh = 64 * ?MSS, maxseg = ?MSS, initwnd = 10 * ?MSS,
                          snd_scale = 0, snd_wnd = 1000 * ?MSS, pipe = 0, rxtshift = 0, srtt = 0,
                          rtt_updated = 0, rexmit = false, now = 0, data = Module:init(#{})}).

ack(Bytes) -> #cc_ack{bytes = Bytes, cwnd_limited = true, curack = 0}.

cwnd_after(Module, Ccv, Ack) -> (Module:ack_received(Ccv, ack, Ack))#ccv.cwnd.

module_table_test() ->
    ?assertEqual({ok, erx_tcp_cc_cubic}, erx_tcp_cc:module(<<"cubic">>)),
    ?assertEqual({ok, erx_tcp_cc_newreno}, erx_tcp_cc:module(<<"newreno">>)),
    ?assertEqual({error, unknown}, erx_tcp_cc:module(<<"bbr">>)),
    ?assertEqual({error, unknown}, erx_tcp_cc:module(<<"erx_tcp_cc_cubic">>)).

params_test() ->
    ?assertError(badarg, erx_tcp_cc_newreno:init(#{beta => 0})),
    ?assertError(badarg, erx_tcp_cc_newreno:init(#{beta => 101})),
    ?assertError(badarg, erx_tcp_cc_newreno:init(#{abe => 1})),
    ?assertError(badarg, erx_tcp_cc_newreno:init(#{gamma => 1})),
    ?assertError(badarg, erx_tcp_cc_cubic:init(#{beta => 50})).

%% Slow start grows by the bytes acknowledged, at most tcp_abc_l_var (or labc) segments per
%% segment, and by one segment while resending after a timeout; nothing grows in recovery or
%% when the application, not the window, limits sending.
slow_start_test_() ->
    [{atom_to_list(Module), fun() ->
          Ccv = base(Module),
          ?assertEqual(11 * ?MSS, cwnd_after(Module, Ccv, ack(?MSS))),
          ?assertEqual(12 * ?MSS, cwnd_after(Module, Ccv, ack(5 * ?MSS))),
          ?assertEqual(13 * ?MSS, cwnd_after(Module, Ccv#ccv{labc = 3}, ack(5 * ?MSS))),
          ?assertEqual(11 * ?MSS, cwnd_after(Module, Ccv#ccv{rexmit = true}, ack(5 * ?MSS))),
          ?assertEqual(10 * ?MSS, cwnd_after(Module, Ccv#ccv{cong_recovery = true}, ack(?MSS))),
          ?assertEqual(10 * ?MSS, (Module:ack_received(Ccv, dupack, ack(?MSS)))#ccv.cwnd),
          ?assertEqual(10 * ?MSS, cwnd_after(Module, Ccv, (ack(?MSS))#cc_ack{cwnd_limited = false})),
          %% The window never passes TCP_MAXWIN << snd_scale.
          ?assertEqual(65535, cwnd_after(Module, Ccv#ccv{cwnd = 65000, ssthresh = 1 bsl 20}, ack(?MSS)))
      end} || Module <- ?MODULES].

%% NewReno's congestion avoidance grows one segment per window acknowledged, which the
%% connection marks in abc_sentawnd and the module clears.
newreno_avoidance_test() ->
    Ccv = (base(erx_tcp_cc_newreno))#ccv{ssthresh = 5 * ?MSS},
    ?assertEqual(10 * ?MSS, cwnd_after(erx_tcp_cc_newreno, Ccv, ack(?MSS))),
    Grown = erx_tcp_cc_newreno:ack_received(Ccv#ccv{abc_sentawnd = true}, ack, ack(?MSS)),
    ?assertMatch(#ccv{cwnd = 11000, abc_sentawnd = false}, Grown).

newreno_signals_test() ->
    Ccv = (base(erx_tcp_cc_newreno))#ccv{cwnd = 21 * ?MSS, pipe = 30 * ?MSS},
    %% A loss: ssthresh is half the window in whole segments, and recovery begins.
    Loss = erx_tcp_cc_newreno:cong_signal(Ccv, ndupack, 0),
    ?assertMatch(#ccv{cwnd = 21000, ssthresh = 10000, fast_recovery = true, cong_recovery = true}, Loss),
    %% A second loss in recovery changes nothing.
    ?assertMatch(#ccv{cwnd = 4000, ssthresh = 10000},
                 erx_tcp_cc_newreno:cong_signal(Loss#ccv{cwnd = 4 * ?MSS}, ndupack, 0)),
    %% A loss during ECN recovery enters fast recovery and keeps ssthresh.
    ?assertMatch(#ccv{ssthresh = 64000, fast_recovery = true, cong_recovery = true},
                 erx_tcp_cc_newreno:cong_signal(Ccv#ccv{cong_recovery = true}, ndupack, 0)),
    %% An ECN mark cuts the window as well, by beta_ecn only when enabled.
    ?assertMatch(#ccv{cwnd = 10000, ssthresh = 10000, fast_recovery = false, cong_recovery = true},
                 erx_tcp_cc_newreno:cong_signal(Ccv, ecn, 0)),
    Abe = Ccv#ccv{data = erx_tcp_cc_newreno:init(#{abe => true})},
    ?assertMatch(#ccv{cwnd = 16000}, erx_tcp_cc_newreno:cong_signal(Abe, ecn, 0)),
    %% An ECN mark past the recovery point in fast recovery: the connection has left
    %% congestion recovery, so the window is cut again and fast recovery stays.
    ?assertMatch(#ccv{cwnd = 10000, ssthresh = 10000, fast_recovery = true, cong_recovery = true},
                 erx_tcp_cc_newreno:cong_signal(Ccv#ccv{fast_recovery = true}, ecn, 0)),
    %% The first timeout takes ssthresh from the smaller of flight and peer window.
    ?assertMatch(#ccv{cwnd = 1000, ssthresh = 15000},
                 erx_tcp_cc_newreno:cong_signal(Ccv#ccv{rxtshift = 1}, rto, none)),
    ?assertMatch(#ccv{cwnd = 1000, ssthresh = 64000},
                 erx_tcp_cc_newreno:cong_signal(Ccv#ccv{rxtshift = 2}, rto, none)),
    %% Leaving recovery: ssthresh, or flight plus a segment when less is in flight.
    ?assertMatch(#ccv{cwnd = 10000}, erx_tcp_cc_newreno:post_recovery(Loss)),
    ?assertMatch(#ccv{cwnd = 4000}, erx_tcp_cc_newreno:post_recovery(Loss#ccv{pipe = 3 * ?MSS})),
    %% After idle: the restart window, and ssthresh keeps three quarters of the window.
    ?assertMatch(#ccv{cwnd = 10000, ssthresh = 15750},
                 erx_tcp_cc_newreno:after_idle(Ccv#ccv{ssthresh = 2 * ?MSS})).

%% CUBIC's loss: fast convergence lowers W_max below an earlier one (here the initial one,
%% above any window: 100000 * 217 >> 8 = 84765), ssthresh is the flight times beta, and
%% after recovery the window is W_max times beta.
cubic_signals_test() ->
    Ccv = (base(erx_tcp_cc_cubic))#ccv{cwnd = 100 * ?MSS, pipe = 100 * ?MSS},
    Loss = erx_tcp_cc_cubic:cong_signal(Ccv, ndupack, 0),
    ?assertMatch(#ccv{ssthresh = 69921, fast_recovery = true, cong_recovery = true}, Loss),
    ?assertMatch(#ccv{cwnd = 59269}, erx_tcp_cc_cubic:post_recovery(Loss)),
    ?assertMatch(#ccv{cwnd = 21000}, erx_tcp_cc_cubic:post_recovery(Loss#ccv{pipe = 20 * ?MSS})),
    %% An ECN mark: the same ssthresh, and the window cut to it.
    ?assertMatch(#ccv{cwnd = 69921, ssthresh = 69921, fast_recovery = false, cong_recovery = true},
                 erx_tcp_cc_cubic:cong_signal(Ccv, ecn, 0)),
    %% A timeout: one segment, ssthresh from the flight times beta.
    ?assertMatch(#ccv{cwnd = 1000, ssthresh = 69000},
                 erx_tcp_cc_cubic:cong_signal(Ccv#ccv{rxtshift = 1}, rto, none)).

%% A connection after a loss and recovery (W_max 84765, window 59269, ssthresh 34960) whose
%% first acknowledgement at 5 s started the epoch: K = cubic_k(84, 59) = 1008 (3.94 s), and
%% at t = 10 ms (the mean RTT) the cubic is 59765, so the window grew by
%% ((496 << 8) div 59269 * 1000) >> 8 = 7.
cubic_epoch() ->
    Ccv0 = (base(erx_tcp_cc_cubic))#ccv{cwnd = 100 * ?MSS, pipe = 50 * ?MSS, srtt = 10000,
                                        rtt_updated = 8, now = 5000000},
    Ccv1 = erx_tcp_cc_cubic:post_recovery(erx_tcp_cc_cubic:cong_signal(Ccv0, ndupack, 0)),
    First = erx_tcp_cc_cubic:ack_received(Ccv1#ccv{fast_recovery = false, cong_recovery = false},
                                          ack, ack(?MSS)),
    ?assertMatch(#ccv{cwnd = 59276, ssthresh = 34960}, First),
    First.

%% Congestion avoidance follows the cubic: 1 s into the epoch it is 74765, and the window
%% grows by ((15489 << 8) div 59276 * 1000) >> 8 = 257; 20 s in, far past K, the target is
%% held at 1.5 windows, 88914, and the window grows by ((29638 << 8) div 59276 * 1000) >> 8
%% = 500, half a segment.
cubic_avoidance_test() ->
    First = cubic_epoch(),
    ?assertEqual(59533, cwnd_after(erx_tcp_cc_cubic, First#ccv{now = 6000000}, ack(?MSS))),
    ?assertEqual(59776, cwnd_after(erx_tcp_cc_cubic, First#ccv{now = 25000000}, ack(?MSS))).

%% A timeout, slow start, and a new epoch with W_max at that window; then the timeout is
%% found spurious, the connection restores its window and ssthresh, and the epoch it had
%% comes back, so the cubic grows as if there had been no timeout.
cubic_spurious_timeout_test() ->
    First = cubic_epoch(),
    Rto = erx_tcp_cc_cubic:cong_signal(First#ccv{rxtshift = 1}, rto, none),
    ?assertMatch(#ccv{cwnd = 1000, ssthresh = 34000}, Rto),
    Slow = erx_tcp_cc_cubic:ack_received(Rto#ccv{now = 5200000}, ack, ack(?MSS)),
    Avoid = erx_tcp_cc_cubic:ack_received(Slow#ccv{cwnd = 40 * ?MSS, now = 5500000}, ack, ack(?MSS)),
    Undone = erx_tcp_cc_cubic:cong_signal(Avoid, rto_err, none),
    Restored = Undone#ccv{cwnd = First#ccv.cwnd, ssthresh = First#ccv.ssthresh, rxtshift = 0},
    ?assertEqual(59533, cwnd_after(erx_tcp_cc_cubic, Restored#ccv{now = 6000000}, ack(?MSS))).

%% After idle: the restart window, ssthresh keeps three quarters of the window.
cubic_after_idle_test() ->
    Idle = erx_tcp_cc_cubic:after_idle((cubic_epoch())#ccv{now = 9000000}),
    ?assertMatch(#ccv{cwnd = 10000, ssthresh = 44457}, Idle).

%% At t = K the cubic is at W_max; before and after it is below and above.
cubic_curve_test() ->
    K = erx_tcp_cc_cubic:cubic_k(100, 70),
    ?assertEqual(1080, K),
    Usecs = K * 1000000 bsr 8,
    ?assertEqual(100 * ?MSS, erx_tcp_cc_cubic:cubic_cwnd(Usecs, 100 * ?MSS, ?MSS, K)),
    ?assert(erx_tcp_cc_cubic:cubic_cwnd(0, 100 * ?MSS, ?MSS, K) < 100 * ?MSS),
    ?assert(erx_tcp_cc_cubic:cubic_cwnd(2 * Usecs, 100 * ?MSS, ?MSS, K) > 100 * ?MSS),
    ?assertEqual(0, erx_tcp_cc_cubic:cubic_k(70, 100)).

%% Hystart++: a round whose lowest RTT rose by the threshold enters conservative slow start,
%% which grows a quarter as fast, and hystart_css_rounds rounds later slow start ends as
%% #ccv.hystart says.
hystart_test_() ->
    [{atom_to_list(Module), fun() -> hystart(Module) end} || Module <- ?MODULES].

hystart(Module) ->
    Css = css(Module, on),
    ?assertEqual(10 * ?MSS + ?MSS div 2, Css#ccv.cwnd),
    %% Without Hystart++ allowed, or with only retransmitted samples, slow start runs at
    %% full speed.
    ?assertEqual(12 * ?MSS, cwnd_after(Module, (rising(Module, on))#ccv{hystart = off}, ack(2 * ?MSS))),
    Ambiguous = samples(Module, Module:newround(samples(Module, (base(Module))#ccv{hystart = on}, 10000, 1), 2),
                        {20000, 2, 12000}),
    ?assertEqual(12 * ?MSS, cwnd_after(Module, Ambiguous, ack(2 * ?MSS))),
    %% Five rounds on, slow start ends at the current window.
    Rounds = rounds(Module, Css),
    ?assertEqual(64 * ?MSS, Rounds#ccv.ssthresh),
    ?assertEqual(Css#ccv.cwnd, (Module:newround(Rounds, 7))#ccv.ssthresh),
    %% Or the window is cut back to the flight at entry, with ssthresh at the flight of the
    %% lowest RTT, or halfway between the two.
    ?assertMatch(#ccv{cwnd = 12000, ssthresh = 8000}, Module:newround(rounds(Module, css(Module, shrink)), 7)),
    ?assertMatch(#ccv{cwnd = 12000, ssthresh = 10000},
                 Module:newround(rounds(Module, css(Module, shrink_mean)), 7)),
    %% A round whose RTT falls below the baseline shows the entry was wrong: full speed again.
    Fallen = samples(Module, Module:newround(Css, 3), {15000, 1, 9000}),
    ?assertEqual(Css#ccv.cwnd + 2 * ?MSS, cwnd_after(Module, Fallen, ack(2 * ?MSS))),
    %% A loss turns Hystart++ off.
    Lost = (Module:cong_signal(Css, ndupack, 0))#ccv{fast_recovery = false, cong_recovery = false,
                                                     cwnd = 10 * ?MSS, ssthresh = 64 * ?MSS},
    ?assertEqual(12 * ?MSS, cwnd_after(Module, Lost, ack(2 * ?MSS))).

%% Two rounds of eight samples, 10 ms then 20 ms at a flight of 12 segments.
rising(Module, Mode) ->
    Round1 = samples(Module, Module:newround((base(Module))#ccv{hystart = Mode}, 1), 10000, 8),
    samples(Module, Module:newround(Round1, 2), {20000, 1, 12000}, 8).

%% The acknowledgement that enters conservative slow start.
css(Module, Mode) -> Module:ack_received(rising(Module, Mode), ack, ack(2 * ?MSS)).

%% Rounds 3 to 6, with eight samples of 25 ms in the last at a flight of 8 segments.
rounds(Module, Ccv) ->
    Round5 = lists:foldl(fun(Round, Acc) -> Module:newround(Acc, Round) end, Ccv, [3, 4, 5]),
    samples(Module, Module:newround(Round5, 6), {25000, 1, 8000}).

samples(Module, Ccv, Rtt, Count) when is_integer(Rtt) ->
    samples(Module, Ccv, {Rtt, 1, 10 * ?MSS}, Count);
samples(Module, Ccv, Sample, Count) ->
    lists:foldl(fun(_, Acc) -> Module:rtt_sample(Acc, Sample) end, Ccv, lists:seq(1, Count)).

samples(Module, Ccv, Sample) -> samples(Module, Ccv, Sample, 8).
