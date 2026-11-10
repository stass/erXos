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

lens(Out) -> [iolist_size(Payload) || {_, _, Payload} <- Out].
seqs(Out) -> [Seq || {#tcp{seq = Seq}, _, _} <- Out].

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
    ?assertEqual([0, 0, ?TH_FIN], [F band ?TH_FIN || {#tcp{flags = F}, _, _} <- Out]),
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
