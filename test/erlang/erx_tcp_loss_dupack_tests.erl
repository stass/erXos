%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_tcp_loss_dupack against the branches of tcp_do_segment, tcp_do_prr_ack and
%% tcp_newreno_partial_ack (sys/netinet/tcp_input.c) it translates: limited transmit, the
%% third duplicate, RFC 6675's SACKed-bytes trigger, PRR, NewReno's partial acknowledgement,
%% what is not a duplicate, and the timeout's choice.
-module(erx_tcp_loss_dupack_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp_cc.hrl").
-include("erx_tcp_loss.hrl").

-define(MSS, 100).

ccv(Cwnd, Ssthresh) ->
    #ccv{cwnd = Cwnd, ssthresh = Ssthresh, maxseg = ?MSS, rxtshift = 0}.

%% Ten segments [0, 1000) sent.
log() ->
    lists:foldl(fun(I, L) -> erx_tcp_sendlog:sent(L, I * ?MSS, (I + 1) * ?MSS, I) end,
                erx_tcp_sendlog:new(0), lists:seq(0, 9)).

dup(Log, Ccv) ->
    #loss_ack{ack = 0, una = 0, snd_nxt = erx_tcp_sendlog:snd_max(Log), recover = -1, pure = true,
              rexmt_armed = true, ccv = Ccv}.

newreno_limited_transmit_then_recovery_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => false}),
    Ccv = ccv(1000, 64000),
    Log0 = log(),
    {drop, Log1, S1, [{ack_received, dupack}]} = erx_tcp_loss_dupack:ack(dup(Log0, Ccv), Log0, S0, 0),
    ?assertEqual({1100, 1000}, erx_tcp_loss_dupack:allowance(Log1, S1, Ccv)),
    Log2 = erx_tcp_sendlog:sent(Log1, 1000, 1100, 1),
    {drop, Log3, S2, _} = erx_tcp_loss_dupack:ack(dup(Log2, Ccv), Log2, S1, 0),
    ?assertEqual({1200, 1000}, erx_tcp_loss_dupack:allowance(Log3, S2, Ccv)),
    Log4 = erx_tcp_sendlog:sent(Log3, 1100, 1200, 2),
    {drop, Log5, S3, Events} = erx_tcp_loss_dupack:ack(dup(Log4, Ccv), Log4, S2, 0),
    ?assertEqual([{cong_signal, ndupack}, {ack_received, dupack}, stop_rexmt], Events),
    %% The segment at snd_una is to be retransmitted; after the signal, ssthresh is 600 and
    %% the kept window inflates by the one duplicate limited transmit did not use.
    ?assertEqual({retransmit, 0, 100},
                 erx_tcp_sendlog:next_seg(Log5, #{mss => ?MSS, recover => 1200, new_data => false,
                                                  rescue => false})),
    Signalled = (ccv(1000, 600))#ccv{fast_recovery = true},
    ?assertEqual({1200, 900}, erx_tcp_loss_dupack:allowance(Log5, S3, Signalled)),
    %% A partial acknowledgement retransmits the next segment and deflates the window.
    Log6 = erx_tcp_sendlog:sent(Log5, 0, 100, 3),
    Partial = #loss_ack{ack = 100, una = 0, snd_nxt = 1200, recover = 1200, pure = true,
                        rexmt_armed = true, ccv = Signalled#ccv{cwnd = 700}},
    {continue, Log7, S4, [stop_rexmt, ack_now]} = erx_tcp_loss_dupack:ack(Partial, Log6, S3, 0),
    ?assertEqual({1100, 700}, erx_tcp_loss_dupack:allowance(Log7, S4, Signalled)).

not_a_duplicate_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => false}),
    Log = log(),
    A = dup(Log, ccv(1000, 64000)),
    Ccv = A#loss_ack.ccv,
    {drop, _, S1, _} = erx_tcp_loss_dupack:ack(A, Log, S0, 0),
    %% Data or a window update: no duplicate, the count stays at one, so the next duplicate
    %% is the second and lets two segments go (none went after the first).
    {continue, _, S2, []} = erx_tcp_loss_dupack:ack(A#loss_ack{pure = false}, Log, S1, 0),
    ?assertEqual(none, erx_tcp_loss_dupack:allowance(Log, S2, Ccv)),
    {drop, _, S3, _} = erx_tcp_loss_dupack:ack(A, Log, S2, 0),
    ?assertEqual({1200, 1000}, erx_tcp_loss_dupack:allowance(Log, S3, Ccv)),
    %% Nothing outstanding to time: the count is cleared, and the next is the first again.
    {continue, _, S4, []} = erx_tcp_loss_dupack:ack(A#loss_ack{rexmt_armed = false}, Log, S3, 0),
    {drop, _, S5, _} = erx_tcp_loss_dupack:ack(A, Log, S4, 0),
    ?assertEqual({1100, 1000}, erx_tcp_loss_dupack:allowance(Log, S5, Ccv)).

%% With SACK, more than (DupThresh - 1) * SMSS SACKed bytes begin recovery on the first
%% duplicate (RFC 6675 section 5); PRR then paces the retransmissions (RFC 6937).
sack_recovery_and_prr_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => true}),
    Log0 = log(),
    A = (dup(Log0, ccv(1000, 64000)))#loss_ack{sack_opt = true, sack_blocks = [{300, 600}], pure = false},
    {drop, Log1, S1, Events} = erx_tcp_loss_dupack:ack(A, Log0, S0, 0),
    ?assertEqual([{cong_signal, ndupack}, {ack_received, dupack}, stop_rexmt, resume_at_max], Events),
    %% [0, 300) is lost: 300 bytes SACKed above it. The pipe is 1000 - 300 - 300.
    ?assertEqual(400, erx_tcp_sendlog:pipe(Log1)),
    Ccv = (ccv(1000, 500))#ccv{fast_recovery = true},
    ?assertEqual({500, 500}, erx_tcp_loss_dupack:allowance(Log1, S1, Ccv)),
    Log2 = erx_tcp_sendlog:sent(Log1, 0, 100, 1),
    %% A duplicate SACKing [600, 700): DeliveredData 100, pipe 400 below ssthresh 500, so
    %% PRR-SSRB: prr_delivered 200, prr_out 100, sndcnt min(100, 200) is one segment.
    B = A#loss_ack{sack_blocks = [{600, 700}], recover = 1000, ccv = Ccv},
    {drop, Log3, S2, [{ack_received, dupack}]} = erx_tcp_loss_dupack:ack(B, Log2, S1, 0),
    ?assertEqual(400, erx_tcp_sendlog:pipe(Log3)),
    ?assertEqual({500, 500}, erx_tcp_loss_dupack:allowance(Log3, S2, Ccv)),
    %% The first timeout keeps the SACKed bytes, the second forgets them.
    {Kept, _} = erx_tcp_loss_dupack:rewind({timeout, 1}, Log3, S2, 0),
    ?assertEqual(400, erx_tcp_sendlog:sacked_bytes(Kept)),
    {Gone, _} = erx_tcp_loss_dupack:rewind({timeout, 2}, Log3, S2, 0),
    ?assertEqual(0, erx_tcp_sendlog:sacked_bytes(Gone)),
    %% A smaller path MTU forgets the SACKed bytes and keeps the duplicate count
    %% (tcp_mtudisc); a zero window loses what was sent into it.
    ?assertMatch({_, S2}, erx_tcp_loss_dupack:rewind(mtu, Log3, S2, 0)),
    ?assertEqual(0, erx_tcp_sendlog:sacked_bytes(element(1, erx_tcp_loss_dupack:rewind(mtu, Log3, S2, 0)))),
    {Lost, S2} = erx_tcp_loss_dupack:rewind({window, 100, 1100}, Log3, S2, 0),
    ?assertEqual(erx_tcp_sendlog:lose(Log3, 1100), Lost),
    ?assertEqual({Log3, S2}, erx_tcp_loss_dupack:rewind({window, 1100, 1100}, Log3, S2, 0)).

%% An acknowledgement without SACK blocks that fills the last hole is not a duplicate: SACK
%% recovery is asked after the scoreboard update (tcp_input.c's second
%% tcp_is_sack_recovery), so two more SACK duplicates with 2 * SMSS SACKed stay in limited
%% transmit.
filled_hole_is_not_a_duplicate_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => true}),
    Ccv = ccv(1000, 64000),
    Log0 = log(),
    Sack = fun(Ack, Blocks) ->
                   (dup(Log0, Ccv))#loss_ack{ack = Ack, sack_opt = Blocks =/= [],
                                             sack_blocks = Blocks, pure = false}
           end,
    {drop, Log1, S1, _} = erx_tcp_loss_dupack:ack(Sack(0, [{200, 300}]), Log0, S0, 0),
    {continue, Log2, S2, []} = erx_tcp_loss_dupack:ack(Sack(300, []), Log1, S1, 0),
    {drop, Log3, S3, [{ack_received, dupack}]} =
        erx_tcp_loss_dupack:ack(Sack(300, [{400, 500}]), Log2, S2, 0),
    {drop, _, _, [{ack_received, dupack}]} =
        erx_tcp_loss_dupack:ack(Sack(300, [{400, 600}]), Log3, S3, 0).

module_table_test() ->
    ?assertEqual({ok, erx_tcp_loss_dupack}, erx_tcp_loss:module(<<"dupack">>)),
    ?assertEqual({error, unknown}, erx_tcp_loss:module(<<"rack">>)),
    ?assertError(badarg, erx_tcp_loss_dupack:init(#{})).

%% snd_limited counts what limited transmit itself sent (tcp_input.c:2782-2793): after the
%% first duplicate's segment and an advancing acknowledgement that counts as the first
%% duplicate again (RFC 6675), three segments the window let go do not use up the second
%% duplicate's segment.
limited_transmit_counts_its_own_output_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => true}),
    Ccv = ccv(1000, 64000),
    Log0 = log(),
    Sack = fun(Log, Ack, Blocks) ->
                   (dup(Log, Ccv))#loss_ack{ack = Ack, sack_opt = true, sack_blocks = Blocks,
                                            pure = false}
           end,
    {drop, Log1, S1, _} = erx_tcp_loss_dupack:ack(Sack(Log0, 0, [{900, 1000}]), Log0, S0, 0),
    ?assertEqual({1000, 1000}, erx_tcp_loss_dupack:allowance(Log1, S1, Ccv)),
    Log2 = erx_tcp_sendlog:sent(Log1, 1000, 1100, 1),
    {continue, Log3, S2, []} = erx_tcp_loss_dupack:ack(Sack(Log2, 100, [{900, 1000}]), Log2, S1, 0),
    ?assertEqual(1, erx_tcp_loss_dupack:dupacks(S2)),
    Log4 = lists:foldl(fun(I, L) -> erx_tcp_sendlog:sent(L, I * ?MSS, (I + 1) * ?MSS, 2) end,
                       Log3, lists:seq(11, 13)),
    {drop, Log5, S3, [{ack_received, dupack}]} =
        erx_tcp_loss_dupack:ack(Sack(Log4, 100, [{900, 1000}, {1300, 1400}]), Log4, S2, 0),
    %% The flight 1300 and one segment for the duplicate limited transmit has not used,
    %% measured against the pipe 1100.
    ?assertEqual({1200, 1000}, erx_tcp_loss_dupack:allowance(Log5, S3, Ccv)).

%% ECN's window reduction runs PRR on counters of its own (cc_post_recovery zeroes them when
%% fast recovery ends, tcp_input.c:497-499), here after the acknowledgement that ended a
%% NewReno recovery: nothing delivered and nothing sent, so PRR-CRB lets one segment go.
ecn_reduction_starts_prr_afresh_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => false}),
    Log0 = log(),
    Dup = fun(Log, Ccv) -> dup(Log, Ccv) end,
    {drop, Log1, S1, _} = erx_tcp_loss_dupack:ack(Dup(Log0, ccv(1000, 64000)), Log0, S0, 0),
    {drop, Log2, S2, _} = erx_tcp_loss_dupack:ack(Dup(Log1, ccv(1000, 64000)), Log1, S1, 0),
    {drop, Log3, S3, _} = erx_tcp_loss_dupack:ack(Dup(Log2, ccv(1000, 64000)), Log2, S2, 0),
    Fast = (ccv(1000, 500))#ccv{fast_recovery = true},
    Log4 = erx_tcp_sendlog:sent(Log3, 0, 100, 1),
    Full = #loss_ack{ack = 1000, snd_nxt = 1000, recover = 1000, pure = true, rexmt_armed = true,
                     ccv = Fast},
    {continue, Log5, S4, []} = erx_tcp_loss_dupack:ack(Full, Log4, S3, 0),
    Log6 = lists:foldl(fun(I, L) -> erx_tcp_sendlog:sent(L, I * ?MSS, (I + 1) * ?MSS, 2) end,
                       Log5, lists:seq(10, 19)),
    Cong = (ccv(1000, 500))#ccv{cong_recovery = true},
    Ecn = #loss_ack{ack = 1100, snd_nxt = 2000, recover = 2001, pure = true, rexmt_armed = true,
                    ccv = Cong},
    {continue, Log7, S5, []} = erx_tcp_loss_dupack:ack(Ecn, Log6, S4, 0),
    %% prr_delivered 100 against recover_fs 1000 (FreeBSD keeps it from the last recovery):
    %% sndcnt is (50 + 99) div 100, one segment over the pipe of 900.
    ?assertEqual({1000, 1000}, erx_tcp_loss_dupack:allowance(Log7, S5, Cong)).

%% A partial acknowledgement without SACK blocks that clears the scoreboard leaves PRR outside
%% SACK recovery; its window is still sndcnt segments over the pipe output measures against,
%% not the flight before the acknowledgement, which would let the acknowledged bytes go again
%% as a burst.
prr_window_is_over_the_pipe_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => true}),
    Log0 = log(),
    A = (dup(Log0, ccv(1000, 64000)))#loss_ack{sack_opt = true, sack_blocks = [{300, 600}],
                                               pure = false},
    {drop, Log1, S1, _} = erx_tcp_loss_dupack:ack(A, Log0, S0, 0),
    Log2 = erx_tcp_sendlog:sent(Log1, 0, 100, 1),
    Fast = (ccv(1000, 500))#ccv{fast_recovery = true},
    Partial = #loss_ack{ack = 600, snd_nxt = 1000, recover = 1000, pure = true, rexmt_armed = true,
                        ccv = Fast},
    {continue, Log3, S2, [stop_rexmt, ack_now]} = erx_tcp_loss_dupack:ack(Partial, Log2, S1, 0),
    ?assertNot(erx_tcp_sendlog:has_holes(Log3)),
    ?assertEqual(400, erx_tcp_sendlog:pipe(Log3)),
    %% prr_delivered 200 and prr_out 100: sndcnt (100 - 100 + 99) div 100 is none.
    ?assertEqual({400, 400}, erx_tcp_loss_dupack:allowance(Log3, S2, Fast)).

%% A timeout ends the recovery episode (CC_RTO's EXIT_RECOVERY), so an ECN signal on the next
%% acknowledgement starts PRR afresh even though the module never saw the flags clear.
ecn_after_timeout_starts_prr_afresh_test() ->
    S0 = erx_tcp_loss_dupack:init(#{sack => false}),
    Log0 = log(),
    Dup = fun(Log) -> dup(Log, ccv(1000, 64000)) end,
    {drop, Log1, S1, _} = erx_tcp_loss_dupack:ack(Dup(Log0), Log0, S0, 0),
    {drop, Log2, S2, _} = erx_tcp_loss_dupack:ack(Dup(Log1), Log1, S1, 0),
    {drop, Log3, S3, _} = erx_tcp_loss_dupack:ack(Dup(Log2), Log2, S2, 0),
    {Log4, S4} = erx_tcp_loss_dupack:rewind({timeout, 1}, Log3, S3, 0),
    Cong = (ccv(1000, 500))#ccv{cong_recovery = true},
    Ecn = #loss_ack{ack = 100, snd_nxt = 1000, recover = 1001, pure = true, rexmt_armed = true,
                    ccv = Cong},
    {continue, Log5, S5, []} = erx_tcp_loss_dupack:ack(Ecn, Log4, S4, 0),
    %% Everything is lost, so the pipe is 0: PRR-SSRB's limit max(100 - 0, 100) + 100 is two
    %% segments; the fast recovery's prr_delivered would have made it three.
    ?assertEqual(0, erx_tcp_sendlog:pipe(Log5)),
    ?assertEqual({200, 200}, erx_tcp_loss_dupack:allowance(Log5, S5, Cong)).
