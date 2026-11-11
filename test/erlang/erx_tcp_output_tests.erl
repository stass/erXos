%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_tcp_output, each named for the part of sys/netinet/tcp_output.c
%% (tcp_default_output, tcp_setpersist) it pins.
-module(erx_tcp_output_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
-define(S(Ms), ((Ms) * 1000)).

ctx(Credit) -> #tcp_ctx{now = ?T0, credit = Credit, mtu = 1500}.

out(Tcb) -> erx_tcp_output:output(Tcb, ctx(64)).

new() ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => 1000, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => 1 bsl 20, rcv_hiwat => 65536,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

%% An established connection with `Bytes` unsent, a 1000-byte MSS, windows open, and the
%% last window it advertised still standing.
est(Bytes) ->
    #tcb{ccv = Ccv} = T = new(),
    T#tcb{state = established, irs = 5000, rcv_nxt = 5001, rcv_adv = 5001 + 65536,
          snd_una = 1001, snd_nxt = 1001, snd_max = 1001, snd_wnd = 65535, max_sndwnd = 65535,
          maxseg = 1000, ccv = Ccv#ccv{cwnd = 10000, maxseg = 1000},
          sendlog = erx_tcp_sendlog:new(1001), wscale = {0, 0}, ts = off, sack = off,
          sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(), binary:copy(<<"x">>, Bytes))}.

%% `est(Bytes)` with the first `Sent` bytes in flight, sent as one range.
in_flight(Bytes, Sent) ->
    T = est(Bytes),
    T#tcb{snd_nxt = 1001 + Sent, snd_max = 1001 + Sent,
          sendlog = erx_tcp_sendlog:sent(T#tcb.sendlog, 1001, 1001 + Sent, 1000, ?T0),
          send_timer = {rexmt, ?T0 + ?S(1000)}}.

%% The segments on the wire, each run cut as the frame layer cuts it.
wire(Out) -> lists:flatmap(fun erx_tcp_output:segments/1, Out).

lens(Out) -> [iolist_size(Payload) || {_, _, Payload} <- wire(Out)].
seqs(Out) -> [Seq || {#tcp{seq = Seq}, _, _} <- wire(Out)].

%% tcp_output.c:274-275, 412-425, 587-625: the peer's window and the congestion window bound
%% the data; a remainder under a segment that the window, not the buffer, cut is held.
windows_limit_data_test() ->
    {T1, Out1} = out((est(5000))#tcb{snd_wnd = 2500, max_sndwnd = 2500}),
    ?assertEqual({[1000, 1000], [1001, 2001]}, {lens(Out1), seqs(Out1)}),
    ?assertEqual({3001, 3001}, {T1#tcb.snd_nxt, T1#tcb.snd_max}),
    ?assertMatch({{rexmt, _}, 0}, {T1#tcb.send_timer, T1#tcb.rxtshift}),
    #tcb{ccv = Ccv} = T = est(5000),
    {_, Out2} = out(T#tcb{ccv = Ccv#ccv{cwnd = 1500}}),
    ?assertEqual([1000], lens(Out2)).

%% tcp_output.c:611-616: Nagle holds a small segment while data is outstanding, unless
%% TF_NODELAY; an idle connection sends it, with PSH as the last of the data (:1122-1124).
nagle_test() ->
    T = in_flight(600, 500),
    ?assertEqual([], element(2, out(T))),
    {_, [{#tcp{flags = Flags}, _, Payload}]} = out(T#tcb{nodelay = true}),
    ?assertEqual({100, ?TH_ACK bor ?TH_PUSH}, {iolist_size(Payload), Flags}),
    ?assertEqual([100], lens(element(2, out(est(100))))).

%% tcp_output.c:619-620: half the largest window the peer offered goes without a full segment.
sender_sws_half_window_test() ->
    T = (in_flight(1300, 500))#tcb{max_sndwnd = 1600},
    ?assertEqual([800], lens(element(2, out(T)))).

%% tcp_output.c:655-692 and 1270-1295: a window update goes only when the window grows by
%% enough; an advertised window under a quarter of the buffer and a segment is 0.
receiver_sws_test() ->
    Full = (est(0))#tcb{rcv_buffered = 65536, rcv_adv = 5001},
    ?assertEqual([], element(2, out(Full))),
    ?assertEqual([], element(2, out(Full#tcb{rcv_buffered = 65536 - 1000}))),
    {T, [{#tcp{win = Win}, _, []}]} = out(Full#tcb{rcv_buffered = 65536 - 40000}),
    ?assertEqual({40000, 5001 + 40000}, {Win, T#tcb.rcv_adv}),
    {_, [{#tcp{win = Small}, _, []}]} = out(Full#tcb{rcv_buffered = 65536 - 500, ack_now = true}),
    ?assertEqual(0, Small).

%% tcp_output.c:479-506, 747-751, 1744-1767: a zero window with data waiting starts the
%% persist timer at count 0; :370-395, 1621-1634: the probe sends one byte and moves only
%% snd_max; an open window sends from snd_una again and turns persist into retransmission.
persist_test() ->
    {T1, []} = out((est(3000))#tcb{snd_wnd = 0}),
    ?assertEqual({{persist, ?T0 + ?S(5000)}, 1}, {T1#tcb.send_timer, T1#tcb.rxtshift}),
    {T2, Probe} = out(T1#tcb{force_data = true}),
    ?assertEqual({[1], [1001]}, {lens(Probe), seqs(Probe)}),
    ?assertEqual({1001, 1002, false}, {T2#tcb.snd_nxt, T2#tcb.snd_max, T2#tcb.force_data}),
    {T3, Again} = out(T2#tcb{force_data = true}),
    ?assertEqual({[1], [1001], 1002}, {lens(Again), seqs(Again), T3#tcb.snd_max}),
    {T4, Open} = out(T3#tcb{snd_wnd = 65535}),
    ?assertEqual([1001, 2001, 3001], seqs(Open)),
    ?assertMatch({{rexmt, _}, 0}, {T4#tcb.send_timer, T4#tcb.rxtshift}).

%% tcp_fsm.h tcp_outflags, tcp_output.c:567-570, 1192-1193, 1537-1544: the FIN goes on the
%% segment that ends the data, and again on later segments of FIN-WAIT-1 at its own number;
%% CLOSED sends the RST|ACK of a dropped connection, and nothing otherwise.
fin_and_rst_test() ->
    {T1, [{#tcp{flags = Flags, seq = 1001}, _, Payload}]} =
        out((est(500))#tcb{state = fin_wait_1, fin = queued}),
    ?assertEqual({?TH_FIN bor ?TH_ACK bor ?TH_PUSH, 500}, {Flags, iolist_size(Payload)}),
    ?assertEqual({{sent, 1501}, 1502, 1502}, {T1#tcb.fin, T1#tcb.snd_nxt, T1#tcb.snd_max}),
    {T2, [{#tcp{flags = Again, seq = 1501}, _, []}]} = out(T1#tcb{ack_now = true}),
    ?assertEqual({?TH_FIN bor ?TH_ACK, 1502, 1502}, {Again, T2#tcb.snd_nxt, T2#tcb.snd_max}),
    Dropped = (est(0))#tcb{state = closed, reset_peer = true, snd_max = 1301},
    {T3, [{#tcp{flags = Rst, seq = 1301, ack = 5001, win = 0}, _, []}]} = out(Dropped),
    ?assertEqual({?TH_RST bor ?TH_ACK, false}, {Rst, T3#tcb.reset_peer}),
    ?assertEqual([], element(2, out((est(0))#tcb{state = closed, ack_now = true}))).

%% tcp_output.c:290-353, 1237-1245, 1641-1645: in SACK recovery the lost range goes first,
%% cut to the window's room over the pipe, and snd_nxt stays where it was. Room for more
%% sends nothing else: the only unSACKed range is at or below HighRxt, so RFC 6675's rescue
%% (section 4, rule 4) does not resend it.
sack_retransmission_test() ->
    Log0 = lists:foldl(fun(Start, L) -> erx_tcp_sendlog:sent(L, Start, Start + 1000, 1000, ?T0) end,
                       erx_tcp_sendlog:new(1001), [1001, 2001, 3001, 4001, 5001]),
    {Log1, _} = erx_tcp_sendlog:ack(Log0, 1001, [{2001, 6001}]),
    {Log, 1000} = erx_tcp_sendlog:mark_lost(Log1, 3, 1000),
    #tcb{ccv = Ccv} = T = est(5000),
    Recovering = T#tcb{sack = on, sendlog = Log, snd_nxt = 6001, snd_max = 6001,
                       snd_recover = 6001, send_timer = {rexmt, ?T0 + ?S(1000)},
                       ccv = Ccv#ccv{cwnd = 3000, fast_recovery = true}},
    {T1, Out} = out(Recovering),
    ?assertEqual({[1000], [1001]}, {lens(Out), seqs(Out)}),
    ?assertEqual(6001, T1#tcb.snd_nxt),
    ?assertEqual(1000, erx_tcp_sendlog:pipe(T1#tcb.sendlog)).

%% tcp_output.c:774-842 (tcp_addoptions) and 1286-1295: a SYN asks for the MSS of the path,
%% the window scale, SACK and timestamps with an unscaled window; once synchronized,
%% segments carry the timestamp echo and a scaled window.
options_test() ->
    {_, [{#tcp{flags = ?TH_SYN, seq = 1000, win = 65535, opts = SynOpts}, _, []}]} =
        out((new())#tcb{state = syn_sent}),
    ?assertMatch(#tcp_opts{mss = 1460, wscale = 6, sack_permitted = true, ts = {_, 0}}, SynOpts),
    Ts = #ts{recent = 99, offset = 7},
    {_, [{#tcp{win = Win, opts = Opts}, _, []}]} =
        out((est(0))#tcb{ts = Ts, wscale = {2, 3}, ack_now = true}),
    ?assertEqual({65536 bsr 3, {erx_tcp:ts_now(7, ctx(0)), 99}}, {Win, Opts#tcp_opts.ts}).

%% tcp_output.c:885-940: options come out of the segment's room, and the clamped segment
%% leaves the FIN for a later one.
mss_clamp_test() ->
    T = (est(2000))#tcb{ts = #ts{recent = 1, offset = 0}, state = fin_wait_1, fin = queued},
    {T1, Out} = out(T),
    ?assertEqual([988, 988, 24], lens(Out)),
    ?assertEqual([0, 0, ?TH_FIN], [F band ?TH_FIN || {#tcp{flags = F}, _, _} <- wire(Out)]),
    ?assertEqual({sent, 3001}, T1#tcb.fin).

%% tcp_output.c:1690-1693: past the credit nothing is sent, the congestion window drops to
%% one segment, and a send timer stays armed.
credit_exhaustion_test() ->
    {T1, Out} = erx_tcp_output:output(est(5000), ctx(2)),
    ?assertEqual([1000, 1000], lens(Out)),
    ?assertEqual(1000, T1#tcb.ccv#ccv.cwnd),
    {T2, []} = erx_tcp_output:output(est(5000), ctx(0)),
    ?assertMatch({1000, {rexmt, _}, 1001}, {T2#tcb.ccv#ccv.cwnd, T2#tcb.send_timer,
                                               T2#tcb.snd_max}).

%% The loss module's window (erx_tcp_loss, allowance/3) bounds one pass, measured against
%% the pipe, and its kept window stays afterwards.
allowance_test() ->
    {T1, Out} = out((in_flight(5000, 1000))#tcb{allowance = {3000, 7000}}),
    ?assertEqual([1000, 1000], lens(Out)),
    ?assertEqual({7000, none}, {T1#tcb.ccv#ccv.cwnd, T1#tcb.allowance}).

%% tcp_output.c:479-506: a window that shrinks to zero with data in flight sends from
%% snd_una again once it reopens; the rewound bytes are what the send log resends, so the
%% pipe does not hold the window shut.
shrink_and_reopen_test() ->
    {T1, []} = out((in_flight(20000, 10000))#tcb{snd_wnd = 0}),
    ?assertMatch({1001, {persist, _}, 1}, {T1#tcb.snd_nxt, T1#tcb.send_timer, T1#tcb.rxtshift}),
    {T2, Out} = out(T1#tcb{snd_wnd = 65535}),
    ?assertMatch([1001, 2001 | _], seqs(Out)),
    ?assertMatch({{rexmt, _}, 0}, {T2#tcb.send_timer, T2#tcb.rxtshift}).

%% tcp_output.c:370-395: a probe into a zero window takes its byte at snd_nxt even when the
%% send log holds SACK information.
probe_with_sack_holes_test() ->
    Log0 = lists:foldl(fun(Start, L) -> erx_tcp_sendlog:sent(L, Start, Start + 1000, 1000, ?T0) end,
                       erx_tcp_sendlog:new(1001), lists:seq(1001, 9001, 1000)),
    {Log, _} = erx_tcp_sendlog:ack(Log0, 1001, [{5001, 6001}]),
    T = (est(20000))#tcb{sack = on, sendlog = Log, snd_nxt = 1001, snd_max = 10001,
                         snd_wnd = 0, force_data = true, send_timer = {persist, ?T0}, rxtshift = 1},
    {_, Probe} = out(T),
    ?assertEqual({[1], [1001]}, {lens(Probe), seqs(Probe)}).

%% tcp_output.c:1192-1193: the FIN an ACK of FIN-WAIT-1 carries again is not a
%% retransmission the send log counts, so SACK recovery still finds the holes below it.
fin_resend_keeps_the_holes_test() ->
    Log0 = lists:foldl(fun(Start, L) -> erx_tcp_sendlog:sent(L, Start, Start + 1000, 1000, ?T0) end,
                       erx_tcp_sendlog:new(1001), lists:seq(1001, 5001, 1000)),
    Log1 = erx_tcp_sendlog:sent(Log0, 6001, 6002, 1000, ?T0),
    T = (est(5000))#tcb{state = fin_wait_1, fin = {sent, 6001}, sendlog = Log1, sack = on,
                        snd_nxt = 6002, snd_max = 6002, ack_now = true,
                        send_timer = {rexmt, ?T0 + ?S(1000)}},
    {T1, [{#tcp{seq = 6001}, _, []}]} = out(T),
    {Log, _} = erx_tcp_sendlog:ack(T1#tcb.sendlog, 1001, [{3001, 6002}]),
    ?assertEqual({retransmit, 1001, 2001},
                 erx_tcp_sendlog:next_seg(Log, #{mss => 1000, recover => 6002,
                                                 new_data => false, rescue => true})).

%% An acknowledgement of a probe byte leaves snd_nxt behind snd_una; output sends from
%% snd_una (FreeBSD's input moves snd_nxt up, tcp_input.c:2047).
snd_nxt_behind_snd_una_test() ->
    {Log, _} = erx_tcp_sendlog:ack(erx_tcp_sendlog:sent(erx_tcp_sendlog:new(1001), 1001, 1002, 1000, ?T0),
                                   1002, []),
    T = (est(5000))#tcb{snd_una = 1002, snd_nxt = 1001, snd_max = 1002, sendlog = Log},
    {T1, Out} = out(T#tcb{sndbuf = erx_tcp_sndbuf:drop(T#tcb.sndbuf, 1)}),
    ?assertMatch([1002 | _], seqs(Out)),
    ?assert(T1#tcb.snd_nxt > 1002).

%% With no route the segment is lost as on the wire: nothing goes out, snd_nxt stays, the
%% retransmission timer runs, and the error becomes the connection's soft error.
no_route_test() ->
    T = est(3000),
    {T1, Out} = erx_tcp_output:output(T, (ctx(64))#tcp_ctx{route = {error, ehostunreach}}),
    ?assertEqual([], Out),
    ?assertEqual({1001, 1001 + 1000}, {T1#tcb.snd_nxt, T1#tcb.snd_max}),
    ?assertMatch({rexmt, _}, T1#tcb.send_timer),
    ?assertEqual(ehostunreach, T1#tcb.soft_error),
    %% The route back, the next pass sends from snd_nxt again.
    {_, Again} = out(T1),
    ?assertEqual([1001, 2001, 3001], seqs(Again)).

unreachable(Tcb) -> erx_tcp_output:output(Tcb, (ctx(64))#tcp_ctx{route = {error, ehostunreach}}).

%% tcp_output.c:1722-1735: a pure ACK lost for want of a route settles neither the window
%% advertised, the last ACK sent nor the pending and delayed ACK, so the next pass sends it.
no_route_keeps_the_ack_owed_test() ->
    #tcb{deadlines = D} = T0 = est(0),
    T = T0#tcb{ack_now = true, rcv_adv = 5001, last_ack_sent = 4000,
               deadlines = D#deadlines{delack = ?T0 + ?S(40)}},
    {T1, []} = unreachable(T),
    ?assertEqual({true, 5001, 4000, ?T0 + ?S(40)},
                 {T1#tcb.ack_now, T1#tcb.rcv_adv, T1#tcb.last_ack_sent,
                  T1#tcb.deadlines#deadlines.delack}),
    %% The window already advertised, so only the owed ACK sends the next segment.
    {T2, [{#tcp{flags = ?TH_ACK, ack = 5001}, _, []}]} = out(T1#tcb{rcv_adv = 5001 + 65535}),
    ?assertEqual({false, 5001 + 65535, 5001, infinity},
                 {T2#tcb.ack_now, T2#tcb.rcv_adv, T2#tcb.last_ack_sent,
                  T2#tcb.deadlines#deadlines.delack}).

%% tcp_output.c:1711-1714: an ACK the credit does not cover (ENOBUFS) stays owed, as
%% TF_ACKNOW stays set on every error return, and the next pass with credit sends it.
enobufs_keeps_the_ack_owed_test() ->
    T = (est(0))#tcb{ack_now = true, rcv_adv = 5001 + 65535},
    {T1, []} = erx_tcp_output:output(T, ctx(0)),
    ?assert(T1#tcb.ack_now),
    {T2, [{#tcp{flags = ?TH_ACK, ack = 5001}, _, []}]} = out(T1),
    ?assertNot(T2#tcb.ack_now).

%% tcp_output.c:1635-1641: the D-SACK block an ACK lost for want of a route reported is
%% reported again by the next ACK, and cleared only once one has left.
no_route_keeps_the_dsack_block_test() ->
    Dsack = erx_tcp_sack:arrived(erx_tcp_sack:new(), {4001, 5001}, 5001, []),
    T = (est(0))#tcb{sack = on, rcv_sack = Dsack, ack_now = true},
    {T1, []} = unreachable(T),
    ?assertEqual(Dsack, T1#tcb.rcv_sack),
    {T2, [{#tcp{opts = #tcp_opts{sacks = [{4001, 5001}]}}, _, []}]} = out(T1),
    ?assertEqual({[], T2#tcb.rcv_sack}, erx_tcp_sack:ack(T2#tcb.rcv_sack)).

%% tcp_output.c:1651-1678: a SACK retransmission lost for want of a route leaves snd_nxt and
%% the send log as they were, so the next pass resends the same range.
no_route_sack_retransmission_test() ->
    Log0 = lists:foldl(fun(Start, L) -> erx_tcp_sendlog:sent(L, Start, Start + 1000, 1000, ?T0) end,
                       erx_tcp_sendlog:new(1001), [1001, 2001, 3001, 4001, 5001]),
    {Log1, _} = erx_tcp_sendlog:ack(Log0, 1001, [{2001, 6001}]),
    {Log, 1000} = erx_tcp_sendlog:mark_lost(Log1, 3, 1000),
    #tcb{ccv = Ccv} = T = est(5000),
    Recovering = T#tcb{sack = on, sendlog = Log, snd_nxt = 6001, snd_max = 6001,
                       snd_recover = 6001, send_timer = {rexmt, ?T0 + ?S(1000)},
                       ccv = Ccv#ccv{cwnd = 3000, fast_recovery = true}},
    {T1, []} = unreachable(Recovering),
    ?assertEqual({6001, 6001, ehostunreach}, {T1#tcb.snd_nxt, T1#tcb.snd_max, T1#tcb.soft_error}),
    {_, Out} = out(T1),
    ?assertEqual({[1000], [1001]}, {lens(Out), seqs(Out)}).

%% tcp_output.c:1651-1678: a lost SYN keeps its sequence advance and its timer, and in
%% SYN-SENT, which has received no SYN, the error is not kept as the soft error.
no_route_syn_test() ->
    {T1, []} = unreachable((new())#tcb{state = syn_sent}),
    ?assertMatch({1001, 1001, {rexmt, _}, none},
                 {T1#tcb.snd_nxt, T1#tcb.snd_max, T1#tcb.send_timer, T1#tcb.soft_error}).

%% tcp_output.c:1651-1678: a persist probe lost for want of a route keeps its advance of
%% snd_max, as a probe that left would, and the persist timer.
no_route_persist_probe_test() ->
    {T1, []} = out((est(3000))#tcb{snd_wnd = 0}),
    {T2, []} = unreachable(T1#tcb{force_data = true}),
    ?assertMatch({1001, 1002, {persist, _}, ehostunreach},
                 {T2#tcb.snd_nxt, T2#tcb.snd_max, T2#tcb.send_timer, T2#tcb.soft_error}).

%% A window that shrank to zero after data went into it, and a retransmission timeout, each
%% move snd_nxt back through the loss module's one rewind callback (erx_tcp:rewind/3).
spied(Tcb) -> Tcb#tcb{loss = erx_tcp_loss_spy, loss_state = erx_tcp_loss_spy:init(#{sack => false})}.

zero_window_rewinds_through_the_loss_module_test() ->
    {T1, []} = out(spied((in_flight(3000, 2000))#tcb{snd_wnd = 0})),
    ?assertEqual({1001, [{window, 1001, 3001}]}, {T1#tcb.snd_nxt, erx_tcp_loss_spy:causes(T1#tcb.loss_state)}).

timeout_rewinds_through_the_loss_module_test() ->
    T = spied((in_flight(2000, 2000))#tcb{send_timer = {rexmt, ?T0}}),
    {T1, _} = erx_tcp_timer:expired(T, ctx(64)),
    ?assertEqual({1001, [{timeout, 1}]}, {T1#tcb.snd_nxt, erx_tcp_loss_spy:causes(T1#tcb.loss_state)}).

%% --- Runs (docs/design-network-fastpath.md, "Output makes runs") --------------

%% Output with runs and output without them over the same state: the frames the runs are cut
%% into, header and payload, are per-segment output's, and the control block after the pass
%% is the same in every field. Random states cover windows, the congestion window, the
%% credit, outstanding data, timestamps, MSS and MTU, Nagle, a FIN owed, SACK and D-SACK
%% blocks to report, and urgent data.
%% Its 3000 states take a few seconds alone and longer on a loaded host, past
%% EUnit's default 5 s, so the case carries its own limit.
runs_equal_per_segment_output_test_() ->
    {timeout, 120, fun runs_equal_per_segment_output/0}.

runs_equal_per_segment_output() ->
    rand:seed(exsss, {6, 6, 6}),
    Made = lists:sum([differential(random_state()) || _ <- lists:seq(1, 3000)]),
    %% The property is not vacuous: most states make a run.
    ?assert(Made > 1000).

differential({Tcb, Ctx}) ->
    {T1, Out1} = erx_tcp_output:output(Tcb, Ctx, true),
    {T2, Out2} = erx_tcp_output:output(Tcb, Ctx, false),
    %% The state is in the assertion, so a failure names its case.
    ?assertEqual({{Tcb, Ctx}, T2, Out2}, {{Tcb, Ctx}, T1, wire(Out1)}),
    %% A run's frames fill the credit as its segments would.
    ?assert(length(wire(Out1)) =< Ctx#tcp_ctx.credit),
    %% No run lies in more binaries than the cut walks (ERX_TCP_CUT_PIECES_MAX).
    ?assertEqual([], [P || {_, #{seg := _}, P} <- Out1, length(P) > 64]),
    length(several(Out1)).

%% The runs of several frames among outgoing segments.
several(Out) -> [run || {_, #{seg := Seg}, P} <- Out, iolist_size(P) > Seg].

random_state() ->
    Mss = pick([536, 1000, 1448, 1460, 8960]),
    %% Half the states hold whole segments after what is in flight, so runs end the data.
    {Bytes, Sent} = case pick([any, whole]) of
                        any ->
                            B = rand:uniform(70000) - 1,
                            {B, rand:uniform(min(B, 20000) + 1) - 1};
                        whole ->
                            S = rand:uniform(20001) - 1,
                            {S + (Mss - pick([0, 12])) * rand:uniform(40), S}
                    end,
    T0 = case Sent of
             0 -> est(Bytes);
             _ -> in_flight(Bytes, Sent)
         end,
    %% Some buffers hold the data in several binaries, so frames cross binary boundaries,
    %% and some in binaries so small that 64 of them end a run or hold less than a segment.
    Buf = case pick([one, many, tiny]) of
              one -> T0#tcb.sndbuf;
              many -> append_all(pieces(Bytes, 3000));
              tiny -> append_all(pieces(Bytes, 40))
          end,
    #tcb{ccv = Ccv} = T0,
    T1 = T0#tcb{maxseg = Mss, ccv = Ccv#ccv{cwnd = rand:uniform(80000), maxseg = Mss},
                snd_wnd = rand:uniform(65536) - 1, nodelay = pick([true, false]),
                ts = pick([off, #ts{recent = 77, offset = 5}])},
    T2 = case pick([plain, plain, fin, sack, dsack, urgent, recovery, ecn, cwr]) of
             plain -> T1;
             fin -> T1#tcb{state = fin_wait_1, fin = queued};
             sack -> T1#tcb{sack = on, rcv_sack = erx_tcp_sack:arrived(erx_tcp_sack:new(),
                                                                         {6001, 7001}, 5001, [])};
             dsack -> T1#tcb{sack = on, rcv_sack = erx_tcp_sack:arrived(erx_tcp_sack:new(),
                                                                          {4001, 5001}, 5001, [])};
             urgent -> T1#tcb{snd_up = 1001 + Sent + rand:uniform(Bytes - Sent + 1)};
             recovery when Sent >= 2 * Mss -> recovering(T1, Sent);
             recovery -> T1;
             ecn -> T1#tcb{ecn = erx_tcp_ecn:input_syn_sent(?TH_ECE, off)};
             cwr -> T1#tcb{ecn = erx_tcp_ecn:signal_cwr(erx_tcp_ecn:input_syn_sent(?TH_ECE, off))}
         end,
    Route = pick([ok, ok, ok, {error, ehostunreach}]),
    {T2#tcb{sndbuf = Buf}, #tcp_ctx{now = ?T0, credit = rand:uniform(70) - 1,
                                    mtu = pick([1500, 9000]), route = Route}}.

%% Bytes of "x" as binaries of random sizes up to Max.
pieces(0, _Max) -> [];
pieces(Bytes, Max) ->
    N = min(Bytes, rand:uniform(Max)),
    [binary:copy(<<"x">>, N) | pieces(Bytes - N, Max)].

append_all(Bins) ->
    lists:foldl(fun(B, Acc) -> erx_tcp_sndbuf:append(Acc, B) end, erx_tcp_sndbuf:new(), Bins).

%% SACK fast recovery after the peer SACKed the upper half of what is in flight.
recovering(#tcb{maxseg = Mss, ccv = Ccv} = T, Sent) ->
    Half = 1001 + (Sent div 2 div Mss) * Mss,
    {Log, _} = erx_tcp_sendlog:ack(T#tcb.sendlog, 1001, [{Half, 1001 + Sent}]),
    T#tcb{sack = on, sendlog = Log, snd_recover = 1001 + Sent,
          ccv = Ccv#ccv{fast_recovery = true}}.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% tcp_output.c:916-962: a run takes the whole segments the windows allow, ten here; every
%% frame carries the timestamps, the sequence number advances by the segment size, only the
%% last frame carries PSH, and the control block moves as after ten segments.
run_of_full_segments_test() ->
    T = (est(10000))#tcb{ts = #ts{recent = 99, offset = 7}},
    {T1, [{#tcp{seq = 1001, flags = ?TH_ACK}, #{seg := 988}, Payload} | _] = Out} = out(T),
    ?assertEqual(9880, iolist_size(Payload)),
    Wire = wire(Out),
    ?assertEqual([988 || _ <- lists:seq(1, 10)] ++ [120], lens(Out)),
    ?assertEqual([1001 + I * 988 || I <- lists:seq(0, 10)], seqs(Out)),
    ?assertEqual([?TH_ACK || _ <- lists:seq(1, 10)] ++ [?TH_ACK bor ?TH_PUSH],
                 [F || {#tcp{flags = F}, _, _} <- Wire]),
    ?assert(lists:all(fun({#tcp{opts = #tcp_opts{ts = {_, 99}}}, _, _}) -> true end, Wire)),
    ?assertEqual({11001, 11001}, {T1#tcb.snd_nxt, T1#tcb.snd_max}).

%% A run is bounded by the credit, one unit a frame, and by IP_MAXPACKET with its headers;
%% a window of less than two segments makes no run of several frames.
run_bounds_test() ->
    {_, [{_, #{seg := 1000}, P3} | _]} = erx_tcp_output:output(est(10000), ctx(3)),
    ?assertEqual(3000, iolist_size(P3)),
    Big = (est(200000))#tcb{snd_wnd = 65535 * 4, wscale = {2, 2},
                            ccv = (est(0))#tcb.ccv#ccv{cwnd = 200000}},
    {_, [{_, #{seg := 1000}, P65} | _]} = erx_tcp_output:output(Big, ctx(100)),
    ?assertEqual(65000, iolist_size(P65)),
    {_, Two} = out((est(10000))#tcb{snd_wnd = 1999}),
    ?assertEqual([], several(Two)).

%% The FIN rides on the last frame of a run that sends the data's end (the per-segment
%% wire, where FreeBSD sends it apart after a TSO burst, tcp_output.c:965-969).
run_ends_with_the_fin_test() ->
    T = (est(3000))#tcb{state = fin_wait_1, fin = queued},
    {T1, [{#tcp{flags = Flags}, #{seg := 1000}, _}] = Out} = out(T),
    ?assertEqual(?TH_ACK bor ?TH_PUSH bor ?TH_FIN, Flags),
    ?assertEqual([0, 0, ?TH_FIN], [F band ?TH_FIN || {#tcp{flags = F}, _, _} <- wire(Out)]),
    ?assertEqual({sent, 4001}, T1#tcb.fin).

%% During SACK recovery every pass asks the send log first (source/3), so a pass whose bytes
%% follow snd_max sends no run of several frames: per-segment output turns to a hole once the new data passes
%% the window's right edge over the pipe (NextSeg's rules 3 and 4).
no_run_in_recovery_test() ->
    #tcb{ccv = Ccv} = T0 = in_flight(40000, 10000),
    {Log, _} = erx_tcp_sendlog:ack(T0#tcb.sendlog, 1001, [{6001, 11001}]),
    T = T0#tcb{sendlog = Log, sack = on, snd_recover = 11001,
               ccv = Ccv#ccv{cwnd = 12000, fast_recovery = true}},
    {_, Out} = out(T),
    ?assertEqual([11001, 12001, 1001, 2001, 3001, 4001, 5001], seqs(Out)),
    ?assertEqual([], several(Out)).

%% A run ends where its 64th binary does (ERX_TCP_CUT_PIECES_MAX): of the ten segments of
%% 1,000 bytes the congestion window allows, in binaries of 100, a run takes the six whole
%% segments that 64 binaries hold, and the next pass sends the other four.
run_ends_at_its_64th_binary_test() ->
    T = (est(0))#tcb{sndbuf = append_all(lists:duplicate(105, binary:copy(<<"y">>, 100)))},
    {_, [{_, #{seg := 1000}, Run} | _] = Out} = out(T),
    ?assertEqual({6000, 60}, {iolist_size(Run), length(Run)}),
    ?assertEqual(lists:seq(1001, 10001, 1000), seqs(Out)),
    ?assertEqual(binary:copy(<<"y">>, 10000), iolist_to_binary([P || {_, _, P} <- wire(Out)])).

%% A segment of more than 64 binaries is no run, not even of one: the cut refuses it, so it
%% is encoded as per-segment output encodes it.
segment_of_more_than_64_binaries_is_no_run_test() ->
    T = (est(0))#tcb{sndbuf = append_all(lists:duplicate(300, <<"z">>))},
    {_, [{_, Marks, Payload}]} = out(T),
    ?assertEqual({300, false}, {length(Payload), is_map_key(seg, Marks)}).

%% A segment whose header is a run's goes as a run of one: a pure ACK, a short segment and a
%% retransmission each carry the segment size; a SYN and an ACK reporting a D-SACK block do not
%% (docs/design-network-fastpath.md, "Output makes runs").
runs_of_one_test() ->
    {_, [{_, #{seg := 1000}, []}]} = out((est(0))#tcb{ack_now = true}),
    {_, [{_, #{seg := 1000}, Short}]} = out(est(300)),
    ?assertEqual(300, iolist_size(Short)),
    %% After a timeout rewinds snd_nxt, each segment sent again is a run of one.
    {_, Again} = out((in_flight(2000, 2000))#tcb{snd_nxt = 1001}),
    ?assertEqual([{1001, 1000, 1000}, {2001, 1000, 1000}],
                 [{Seq, Seg, iolist_size(P)} || {#tcp{seq = Seq}, #{seg := Seg}, P} <- Again]),
    {_, [{#tcp{flags = Syn}, SynMarks, _}]} = out((new())#tcb{state = syn_sent}),
    ?assertEqual({?TH_SYN, false}, {Syn band ?TH_SYN, is_map_key(seg, SynMarks)}),
    Sack = (est(0))#tcb{sack = on, ack_now = true,
                        rcv_sack = erx_tcp_sack:arrived(erx_tcp_sack:new(), {4001, 5001}, 5001, [])},
    {_, [{#tcp{opts = #tcp_opts{sacks = [_ | _]}}, SackMarks, []}]} = out(Sack),
    ?assertNot(is_map_key(seg, SackMarks)).

%% The bound is exact: a run reads at most 64 binaries of the send buffer, and keeps the whole
%% frames in them. After N binaries of one byte and binaries of 1,000, they hold 64 - N of
%% the large ones: 3 frames for N = 61, 2 for 62, 1 for 63, and for 64 not even one, so that
%% segment is no run and goes in its 65 binaries as per-segment output sends it.
run_bound_is_exact_test() ->
    Out1 = fun(N) ->
                   Bins = lists:duplicate(N, <<"o">>) ++ lists:duplicate(10, binary:copy(<<"b">>, 1000)),
                   {_, [{_, Marks, Payload} | _]} = out((est(0))#tcb{sndbuf = append_all(Bins)}),
                   {maps:get(seg, Marks, none), iolist_size(Payload), length(Payload)}
           end,
    ?assertEqual({1000, 3000, 64}, Out1(61)),
    ?assertEqual({1000, 2000, 64}, Out1(62)),
    ?assertEqual({1000, 1000, 64}, Out1(63)),
    ?assertEqual({none, 1000, 65}, Out1(64)).

%% The segments that are not a run's go as they are: with urgent data ahead and as a persist
%% probe the header is no run's, and with an ECN state that changes, or a segment on an IPv4
%% path that does not set don't-fragment (an MSS at or below tcp_minmss, 216), the marks say so.
%% Where ECN stays as it was, a run of one carries the ECT codepoint.
runs_of_one_irregular_test() ->
    {_, [{#tcp{urp = Urp}, UrgentMarks, _}]} = out((est(300))#tcb{snd_up = 1001 + 100}),
    ?assertNotEqual(0, Urp),
    ?assertNot(is_map_key(seg, UrgentMarks)),
    Probing = (est(3000))#tcb{snd_wnd = 0, force_data = true, send_timer = {persist, ?T0}, rxtshift = 1},
    {_, [{_, ProbeMarks, Probe}]} = out(Probing),
    ?assertEqual(1, iolist_size(Probe)),
    ?assertNot(is_map_key(seg, ProbeMarks)),
    Ecn = erx_tcp_ecn:input_syn_sent(?TH_ECE, off),
    {_, [{_, #{ecn := IpEcn} = EcnMarks, _}]} = out((est(300))#tcb{ecn = Ecn}),
    ?assertEqual({true, true}, {is_map_key(seg, EcnMarks), IpEcn =/= 0}),
    {_, [{_, CwrMarks, _}]} = out((est(300))#tcb{ecn = erx_tcp_ecn:signal_cwr(Ecn)}),
    ?assertNot(is_map_key(seg, CwrMarks)),
    #tcb{ccv = Ccv} = Small = est(100),
    {_, [{_, SmallMarks, Bytes}]} = out(Small#tcb{maxseg = 216, ccv = Ccv#ccv{maxseg = 216}}),
    ?assertEqual(100, iolist_size(Bytes)),
    ?assertEqual({false, false}, {maps:get(df, SmallMarks), is_map_key(seg, SmallMarks)}).

%% segments/1 by hand: a run over three binaries cut at 1000 bytes, each frame's bytes, its
%% sequence number across the wrap and its flags.
segments_by_hand_test() ->
    Bytes = << <<(I rem 251)>> || I <- lists:seq(0, 2499) >>,
    <<A:700/binary, B:1100/binary, C/binary>> = Bytes,
    Run = {#tcp{sport = 1, dport = 2, seq = 16#ffffff00, ack = 3,
                flags = ?TH_ACK bor ?TH_PUSH bor ?TH_FIN, win = 4, urp = 0,
                opts = #tcp_opts{ts = {5, 6}}}, #{ecn => 0, df => true, seg => 1000}, [A, B, C]},
    Wire = erx_tcp_output:segments(Run),
    ?assertEqual([binary:part(Bytes, 0, 1000), binary:part(Bytes, 1000, 1000),
                  binary:part(Bytes, 2000, 500)],
                 [iolist_to_binary(P) || {_, _, P} <- Wire]),
    ?assertEqual([16#ffffff00, 16#ffffff00 + 1000 - 16#100000000, 1744],
                 [Seq || {#tcp{seq = Seq}, _, _} <- Wire]),
    ?assertEqual([?TH_ACK, ?TH_ACK, ?TH_ACK bor ?TH_PUSH bor ?TH_FIN],
                 [F || {#tcp{flags = F}, _, _} <- Wire]),
    ?assertEqual([#{ecn => 0, df => true}], lists:usort([M || {_, M, _} <- Wire])),
    ?assertEqual([{5, 6}], lists:usort([Ts || {#tcp{opts = #tcp_opts{ts = Ts}}, _, _} <- Wire])).

%% --- tcp_sndbuf_autoscale (tcp_output.c:2123-2178) ---

%% FreeBSD's sb_max_adj for the default sb_max (uipc_sockbuf.c:66-69): the largest buffer
%% sbreserve grants, 2 MiB * MCLBYTES / (MSIZE + MCLBYTES).
-define(SB_MAX_ADJ, 1864135).

%% A connection whose buffer of `Hiwat` holds `Bytes` unsent, with the peer's window and the
%% congestion window at `Wnd` and `Cwnd`.
autosizing(Hiwat, Bytes, Wnd, Cwnd) ->
    #tcb{ccv = Ccv} = T = est(Bytes),
    T#tcb{snd_hiwat = Hiwat, snd_wnd = Wnd, max_sndwnd = Wnd, ccv = Ccv#ccv{cwnd = Cwnd}}.

autoscale(Tcb) -> erx_tcp_output:sndbuf_autoscale(Tcb, ctx(64)).

grows(Tcb) ->
    case autoscale(Tcb) of
        {Tcb, [{reserve_buffer, snd, Bytes}]} -> Bytes;
        {Tcb, []} -> none
    end.

%% tcp_output.c:2167-2176: the buffer grows one tcp_autosndbuf_inc when the peer's window,
%% with its 5/4 fudge, covers it, it is 7/8 full, and the window covers what is unsent;
%% each bound is exact.
autoscale_grows_a_full_buffer_test() ->
    ?assertEqual(16000 + 8192, grows(autosizing(16000, 14000, 65535, 20000))),
    ?assertEqual(none, grows(autosizing(16000, 13999, 65535, 20000))),
    ?assertEqual(none, grows(autosizing(16000, 14000, 65535, 13999))),
    %% What is in flight does not count against the window.
    ?assertEqual(16000 + 8192, grows(sent(autosizing(16000, 14000, 65535, 13999), 1000))),
    %% The peer's window covers the buffer from 12800 on, with 4000 in flight so that the
    %% window still covers what is unsent.
    ?assertEqual(16000 + 8192, grows(sent(autosizing(16000, 14000, 12800, 20000), 4000))),
    ?assertEqual(none, grows(sent(autosizing(16000, 14000, 12799, 20000), 4000))).

%% Tcb with its first Bytes in flight, sent as one range.
sent(#tcb{snd_una = Una, sendlog = Log} = Tcb, Bytes) ->
    Tcb#tcb{snd_nxt = Una + Bytes, snd_max = Una + Bytes,
            sendlog = erx_tcp_sendlog:sent(Log, Una, Una + Bytes, 1000, ?T0),
            send_timer = {rexmt, ?T0 + ?S(1000)}}.

%% A FIN in flight, which the buffer does not hold, keeps the buffer as it is, as the
%% unsigned difference FreeBSD takes wraps past every window.
autoscale_not_with_a_fin_in_flight_test() ->
    T = sent(autosizing(16000, 14000, 65535, 20000), 14000),
    ?assertEqual(16000 + 8192, grows(T)),
    ?assertEqual(none, grows(T#tcb{snd_nxt = 1001 + 14001, snd_max = 1001 + 14001})).

%% The step asks for the growth after its segments, and only while autosizing is on.
autoscale_is_asked_of_the_grant_by_the_step_test() ->
    T = autosizing(16000, 14000, 65535, 20000),
    {_, Actions} = erx_tcp:step({user, {rcvd, 0}}, T, ctx(64)),
    ?assertMatch([{transmit, _}, {reserve_buffer, snd, 24192}], Actions),
    {_, Off} = erx_tcp:step({user, {rcvd, 0}}, T#tcb{snd_autosize = false}, ctx(64)),
    ?assertMatch([{transmit, _}], Off).

%% sbreserve refuses past sb_max_adj, and the refusal turns autosizing off (SB_AUTOSIZE
%% cleared, tcp_output.c:2173-2176): the largest buffer is the last step at or under it.
autoscale_stops_at_the_largest_buffer_test() ->
    Last = ?SB_MAX_ADJ - 8192,
    Big = 4 * ?SB_MAX_ADJ,
    ?assertEqual(?SB_MAX_ADJ, grows(autosizing(Last, Last, Big, Big))),
    T = autosizing(Last + 1, Last + 1, Big, Big),
    ?assertMatch({#tcb{snd_autosize = false, snd_hiwat = H}, []} when H =:= Last + 1,
                 autoscale(T)).

%% A reservation the grant refuses leaves the buffer as it is and turns autosizing off, so
%% no later step asks again; one it grants sets the buffer, and a waiting writer moves into
%% the new room in the same step.
autoscale_refused_leaves_the_buffer_test() ->
    T = autosizing(16000, 14000, 65535, 20000),
    {T1, _} = erx_tcp:step({buffer, snd, refused}, T, ctx(64)),
    ?assertEqual({16000, false}, {T1#tcb.snd_hiwat, T1#tcb.snd_autosize}),
    {_, Actions} = erx_tcp:step({user, {rcvd, 0}}, T1, ctx(64)),
    ?assertEqual([], [A || {reserve_buffer, _, _} = A <- Actions]).

autoscale_granted_takes_the_waiting_writer_test() ->
    T = (autosizing(16000, 16000, 65535, 20000))#tcb{send_waiter = {{self(), w}, binary:copy(<<"y">>, 10000)}},
    {T1, _} = erx_tcp:step({buffer, snd, 24192}, T, ctx(64)),
    ?assertEqual({24192, 24192}, {T1#tcb.snd_hiwat, erx_tcp_sndbuf:size(T1#tcb.sndbuf)}),
    ?assertMatch({_, <<_:1808/binary>>}, T1#tcb.send_waiter).

%% Growth only grows: every size asked is above the buffer and at most sb_max_adj, so the
%% buffer never falls below what it holds.
autoscale_never_shrinks_test() ->
    Big = 4 * ?SB_MAX_ADJ,
    Asked = [{H, grows(autosizing(H, H, Big, Big))}
             || H <- [8, 1000, 33304, 65536, 1 bsl 20, ?SB_MAX_ADJ - 8192]],
    ?assertEqual([], [{H, A} || {H, A} <- Asked, not (A > H andalso A =< ?SB_MAX_ADJ)]).
