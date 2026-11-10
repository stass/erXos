%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_tcp_input's stages 9-12 (ack, process_ack, step6, data, fin) and of
%% header prediction, each named for the lines of sys/netinet/tcp_input.c it checks, and the
%% property that every segment header prediction takes gets the same result from the
%% general stages. Sequence numbers sit just below the 2^32 wrap of their wire values, so
%% every case crosses it.

-module(erx_tcp_input_ack_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
-define(MS0, (?T0 div 1000)).
%% Our ISS and the peer's next byte, both a little below 2^32, so data wraps the wire.
-define(ISS, (16#100000000 - 3000)).
-define(RCV, (16#100000000 - 100)).
-define(OFFSET, 7).

ctx() -> ctx(?T0).
ctx(Now) -> #tcp_ctx{now = Now, credit = 64, mtu = 1500}.

new() ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => erx_tcp_seq:wire(?ISS),
                       ts_offset => ?OFFSET, cc => erx_tcp_cc_newreno,
                       loss => erx_tcp_loss_dupack, snd_hiwat => 65536, rcv_hiwat => 65536,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

%% An established connection with Out bytes sent and unacknowledged from snd_una, which
%% the send buffer holds with Extra more, the retransmission timer running, and a window
%% of 10,000 bytes each way.
est() -> est(0, 0).
est(Out, Extra) ->
    Una = ?ISS + 1,
    Log = case Out of
              0 -> erx_tcp_sendlog:new(Una);
              _ -> erx_tcp_sendlog:sent(erx_tcp_sendlog:new(Una), Una, Una + Out, 1000, ?T0 - 50000)
          end,
    Timer = case Out of
                0 -> none;
                _ -> {rexmt, ?T0 + 1000000}
            end,
    (new())#tcb{state = established, irs = ?RCV - 1, rcv_nxt = ?RCV, rcv_adv = ?RCV + 10000,
                rcv_up = ?RCV, last_ack_sent = ?RCV, rcv_hiwat = 10000, rcv_wnd = 10000,
                iss = ?ISS, snd_una = Una, snd_nxt = Una + Out, snd_max = Una + Out,
                snd_wl1 = ?RCV, snd_wl2 = Una, snd_wnd = 10000, max_sndwnd = 10000,
                snd_recover = Una, wscale = {0, 0}, ts = off, sack = off, maxseg = 1000,
                sendlog = Log, send_timer = Timer,
                sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(), binary:copy(<<"d">>, Out + Extra))}.

with_ts(Tcb) -> Tcb#tcb{ts = #ts{recent = 500, recent_age = ?T0, offset = ?OFFSET}}.

wire(Seq, Ack, Flags) -> wire(Seq, Ack, Flags, <<>>, #tcp_opts{}).
wire(Seq, Ack, Flags, Data) -> wire(Seq, Ack, Flags, Data, #tcp_opts{}).
wire(Seq, Ack, Flags, Data, Opts) -> wire(Seq, Ack, Flags, Data, Opts, 10000, 0).
wire(Seq, Ack, Flags, Data, Opts, Win, Urp) ->
    {#tcp{sport = 80, dport = 4000, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = Win, urp = Urp, opts = Opts}, Data, 0, unicast}.

input(Segments, Tcb) -> input(Segments, Tcb, ctx()).
input(Segments, Tcb, Ctx) -> erx_tcp_input:segments(Segments, Tcb, Ctx).

-define(ACK, ?TH_ACK).
-define(FIN_ACK, (?TH_FIN bor ?TH_ACK)).

%% --- ack, tcp_input.c:2458-2527 and 2869-2883: leaving SYN-RECEIVED ----------------------

%% A simultaneous open: our SYN out, the peer's SYN in, then its ACK of our SYN.
simultaneous_open_completes_on_the_ack_of_our_syn_test() ->
    Log = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(?ISS), ?ISS, ?ISS + 1, 1000, ?T0),
    SynSent = (new())#tcb{state = syn_sent, snd_nxt = ?ISS + 1, snd_max = ?ISS + 1,
                          sendlog = Log, send_timer = {rexmt, ?T0 + 3000000}},
    {T1, _} = input([wire(?RCV - 1, 0, ?TH_SYN)], SynSent),
    ?assertEqual({syn_received, true}, {T1#tcb.state, T1#tcb.need_syn}),
    {T2, []} = input([wire(?RCV, ?ISS + 1, ?ACK)], T1#tcb{ack_now = false}),
    ?assertEqual({established, false}, {T2#tcb.state, T2#tcb.need_syn}),
    ?assertEqual({?ISS + 1, ?ISS + 1}, {T2#tcb.snd_una, erx_tcp_sendlog:snd_una(T2#tcb.sendlog)}),
    %% The ACK of the SYN takes the window and stops nothing it should not.
    ?assertEqual({10000, ?RCV, ?ISS + 1}, {T2#tcb.snd_wnd, T2#tcb.snd_wl1, T2#tcb.snd_wl2}),
    ?assertNotEqual(infinity, (T2#tcb.deadlines)#deadlines.keep).

syn_received_with_a_queued_fin_goes_to_fin_wait_1_test() ->
    Log = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(?ISS), ?ISS, ?ISS + 1, 1000, ?T0),
    T0 = (est())#tcb{state = syn_received, snd_una = ?ISS, sendlog = Log, fin = queued},
    {T, []} = input([wire(?RCV, ?ISS + 1, ?ACK)], T0),
    ?assertEqual({fin_wait_1, queued, ?ISS + 1}, {T#tcb.state, T#tcb.fin, T#tcb.snd_una}).

%% --- ack, tcp_input.c:2546-2548: an acknowledgement of what was never sent ----------------

ack_of_unsent_data_is_dropped_with_an_ack_test() ->
    T0 = est(100, 0),
    {T, []} = input([wire(?RCV, ?ISS + 1 + 101, ?ACK)], T0),
    ?assert(T#tcb.ack_now),
    ?assertEqual({?ISS + 1, 10000, erx_tcp_sndbuf:size(T0#tcb.sndbuf)},
                 {T#tcb.snd_una, T#tcb.snd_wnd, erx_tcp_sndbuf:size(T#tcb.sndbuf)}).

%% --- process_ack, tcp_input.c:2887-3022 -------------------------------------------------

partial_ack_advances_and_restarts_the_timer_test() ->
    T0 = (est(3000, 0))#tcb{rtt_probe = {?ISS + 1, ?T0 - 30000}, rxtshift = 2},
    {T, []} = input([wire(?RCV, ?ISS + 1 + 1000, ?ACK)], T0),
    ?assertEqual({?ISS + 1001, 2000}, {T#tcb.snd_una, erx_tcp_sndbuf:size(T#tcb.sndbuf)}),
    ?assertEqual(?ISS + 1001, erx_tcp_sendlog:snd_una(T#tcb.sendlog)),
    %% The probe's sample resets the backoff (tcp_xmit_timer); the timer restarts at the new RTO.
    ?assertEqual({0, none}, {T#tcb.rxtshift, T#tcb.rtt_probe}),
    ?assertEqual({rexmt, ?T0 + 1000 * erx_tcp_rtt:rto(T#tcb.rtt)}, T#tcb.send_timer),
    %% The window's right edge is unchanged: process_ack takes the bytes off, step6 takes the
    %% segment's window, newer than the last one.
    ?assertEqual({10000, ?ISS + 1001}, {T#tcb.snd_wnd, T#tcb.snd_wl2}),
    ?assertEqual(1, (T#tcb.ccv)#ccv.rtt_updated).

full_ack_stops_the_timer_test() ->
    {T, []} = input([wire(?RCV, ?ISS + 1 + 3000, ?ACK)], est(3000, 500)),
    ?assertEqual({none, 500}, {T#tcb.send_timer, erx_tcp_sndbuf:size(T#tcb.sndbuf)}).

timestamp_echo_is_the_rtt_sample_test() ->
    Ecr = erx_tcp_seq:wire(?MS0 - 40 + ?OFFSET),
    T0 = (with_ts(est(1000, 0)))#tcb{rxtshift = 3},
    {T, []} = input([wire(?RCV, ?ISS + 1001, ?ACK, <<>>, #tcp_opts{ts = {501, Ecr}})], T0),
    ?assertEqual(erx_tcp_rtt:sample(T0#tcb.rtt, 41, 3), T#tcb.rtt),
    ?assertEqual(0, T#tcb.rxtshift).

%% CC_RTO_ERR, :2911-2919: an echo from before the retransmission undoes the timeout.
spurious_timeout_is_undone_test_() ->
    Prev = #rexmt_prev{cwnd = 20000, ssthresh = 30000, recover = ?ISS + 1, fast = false,
                       cong = false, badrxtwin = ?MS0 - 10},
    T0 = (with_ts(est(2000, 0)))#tcb{rxtshift = 1, rexmt_prev = Prev,
                                     ccv = ((est())#tcb.ccv)#ccv{cwnd = 1000, ssthresh = 2000}},
    Run = fun(EchoMs) ->
              Ecr = erx_tcp_seq:wire(EchoMs + ?OFFSET),
              {T, []} = input([wire(?RCV, ?ISS + 1001, ?ACK, <<>>, #tcp_opts{ts = {501, Ecr}})], T0),
              {(T#tcb.ccv)#ccv.ssthresh, T#tcb.rexmt_prev}
          end,
    [?_assertEqual({30000, none}, Run(?MS0 - 11)),
     %% At badrxtwin the echo answers the retransmission: nothing is undone.
     ?_assertEqual({2000, Prev}, Run(?MS0 - 10))].

%% The undo also takes the timeout's marks out of the send log: the original transmissions
%% are in flight again, so output does not count them out of the pipe and burst.
undone_timeout_restores_the_pipe_test() ->
    Prev = #rexmt_prev{cwnd = 20000, ssthresh = 30000, recover = ?ISS + 1, fast = false,
                       cong = false, badrxtwin = ?MS0 - 10},
    T0 = (with_ts(est(4000, 0)))#tcb{rxtshift = 1, rexmt_prev = Prev},
    T1 = T0#tcb{sendlog = erx_tcp_sendlog:timeout(T0#tcb.sendlog, keep)},
    Ecr = erx_tcp_seq:wire(?MS0 - 11 + ?OFFSET),
    {T, []} = input([wire(?RCV, ?ISS + 1001, ?ACK, <<>>, #tcp_opts{ts = {501, Ecr}})], T1),
    ?assertEqual(none, T#tcb.rexmt_prev),
    ?assertEqual({3000, 3000}, {erx_tcp_sendlog:pipe(T#tcb.sendlog),
                                erx_tcp_sendlog:flight(T#tcb.sendlog)}).

%% tcp_output.c:848-849: output records when the first retransmission goes out.
output_records_the_first_retransmission_time_test() ->
    Prev = #rexmt_prev{cwnd = 20000, ssthresh = 30000, recover = ?ISS + 1, fast = false,
                       cong = false, badrxtwin = none},
    T0 = (with_ts(est(1000, 0)))#tcb{rxtshift = 1, rexmt_prev = Prev, snd_nxt = ?ISS + 1,
                                     sendlog = erx_tcp_sendlog:timeout(
                                                 (est(1000, 0))#tcb.sendlog, keep)},
    {T, [_ | _]} = erx_tcp_output:output(T0, ctx(?T0 + 5000)),
    ?assertEqual(?MS0 + 5, (T#tcb.rexmt_prev)#rexmt_prev.badrxtwin),
    %% A later segment, such as a pure ACK, does not move it past the retransmission's own
    %% timestamp, which the peer's acknowledgement of it echoes.
    {T2, _} = erx_tcp_output:output(T#tcb{ack_now = true}, ctx(?T0 + 9000)),
    ?assertEqual(?MS0 + 5, (T2#tcb.rexmt_prev)#rexmt_prev.badrxtwin).

%% :1530: a duplicate ACK carries no data as it arrived. Data the peer sends again, which trim
%% removes entirely, does not count, so three of them start no recovery.
resent_data_is_no_duplicate_ack_test() ->
    T0 = (est(3000, 0))#tcb{rcv_nxt = ?RCV + 3000, last_ack_sent = ?RCV + 3000,
                            snd_wl1 = ?RCV + 3000},
    Dup = fun(N) -> wire(?RCV + N * 1000, ?ISS + 1, ?ACK, binary:copy(<<"r">>, 1000)) end,
    {T, _} = input([Dup(0), Dup(1), Dup(2)], T0),
    ?assertEqual({false, none}, {(T#tcb.ccv)#ccv.fast_recovery, T#tcb.allowance}).

%% :3024-3078: the transitions when our FIN is acknowledged.
fin_acknowledged_test_() ->
    Fin = fun(State, Rcv) ->
              T0 = (est(101, 0))#tcb{state = State, fin = {sent, ?ISS + 101},
                                     sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(),
                                                                    binary:copy(<<"d">>, 100)),
                                     rcv_closed = Rcv},
              {T, []} = input([wire(?RCV, ?ISS + 102, ?ACK)], T0),
              {T#tcb.state, T#tcb.ended, (T#tcb.deadlines)#deadlines.msl2}
          end,
    [?_assertEqual({fin_wait_2, false, infinity}, Fin(fin_wait_1, false)),
     ?_assertMatch({fin_wait_2, false, At} when At =:= ?T0 + 8 * 75000000, Fin(fin_wait_1, true)),
     ?_assertEqual({time_wait, false, ?T0 + 60000000}, Fin(closing, false)),
     ?_assertMatch({_, true, _}, Fin(last_ack, false))].

%% --- step6, tcp_input.c:3081-3101: SND.WL1 and SND.WL2 -----------------------------------

window_update_test_() ->
    T0 = (est(2000, 0))#tcb{snd_wl1 = ?RCV, snd_wl2 = ?ISS + 1001, snd_una = ?ISS + 1001,
                            sendlog = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(?ISS + 1001),
                                                           ?ISS + 1001, ?ISS + 2001, 1000, ?T0)},
    Win = fun(Ack, W) ->
              {T, _} = input([wire(?RCV, Ack, ?ACK, <<>>, #tcp_opts{}, W, 0)], T0),
              {T#tcb.snd_wnd, T#tcb.snd_wl2}
          end,
    %% An old acknowledgement, reordered behind a newer one, never moves the window.
    [?_assertEqual({10000, ?ISS + 1001}, Win(?ISS + 501, 30000)),
     %% The same acknowledgement moves it only to widen it.
     ?_assertEqual({20000, ?ISS + 1001}, Win(?ISS + 1001, 20000)),
     ?_assertEqual({10000, ?ISS + 1001}, Win(?ISS + 1001, 5000)),
     ?_assertEqual({5000, ?ISS + 1501}, Win(?ISS + 1501, 5000))].

%% --- step6, tcp_input.c:3105-3163: the urgent pointer ------------------------------------

urgent_byte_is_kept_out_of_the_stream_test() ->
    {T, [{deliver, Data}]} =
        input([wire(?RCV, ?ISS + 1, ?ACK bor ?TH_URG, <<"abcdef">>, #tcp_opts{}, 10000, 3)], est()),
    ?assertEqual(<<"abdef">>, iolist_to_binary(Data)),
    ?assertEqual({?RCV + 6, ?RCV + 3, 5}, {T#tcb.rcv_nxt, T#tcb.rcv_up, T#tcb.rcv_buffered}).

%% The same byte stays out when its segment waits in the reassembly queue.
urgent_byte_out_of_order_is_kept_out_too_test() ->
    Urg = wire(?RCV + 3, ?ISS + 1, ?ACK bor ?TH_URG, <<"def">>, #tcp_opts{}, 10000, 2),
    {T1, []} = input([Urg], est()),
    {T2, [{deliver, Data}]} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"abc">>)], T1),
    ?assertEqual(<<"abcdf">>, iolist_to_binary(Data)),
    ?assertEqual({?RCV + 6, 5, none}, {T2#tcb.rcv_nxt, T2#tcb.rcv_buffered, T2#tcb.rcv_oob}).

urgent_pointer_past_any_buffer_is_ignored_test() ->
    T0 = (est())#tcb{rcv_buffered = 2 * 1024 * 1024},
    {T, [{deliver, [<<"abc">>]}]} =
        input([wire(?RCV, ?ISS + 1, ?ACK bor ?TH_URG, <<"abc">>, #tcp_opts{}, 10000, 2)], T0),
    ?assertEqual(?RCV, T#tcb.rcv_up).

%% --- data, tcp_input.c:3165-3290 --------------------------------------------------------

in_order_data_is_delivered_with_a_delayed_ack_test() ->
    {T1, [{deliver, [<<"abc">>]}]} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"abc">>)], est()),
    ?assertEqual({?RCV + 3, 3, false, ?T0 + 40000},
                 {T1#tcb.rcv_nxt, T1#tcb.rcv_buffered, T1#tcb.ack_now,
                  (T1#tcb.deadlines)#deadlines.delack}),
    %% With a delayed ACK already pending, the next segment is acknowledged at once.
    {T2, [{deliver, [<<"de">>]}]} = input([wire(?RCV + 3, ?ISS + 1, ?ACK, <<"de">>)], T1),
    ?assert(T2#tcb.ack_now).

ack_after_a_zero_window_is_not_delayed_test() ->
    {T, _} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"a">>)], (est())#tcb{rxwin0_sent = true}),
    ?assert(T#tcb.ack_now).

out_of_order_data_waits_and_is_sacked_test() ->
    T0 = (est())#tcb{sack = on, loss_state = erx_tcp_loss_dupack:init(#{sack => true})},
    {T1, []} = input([wire(?RCV + 3, ?ISS + 1, ?ACK, <<"def">>)], T0),
    ?assertEqual({?RCV, true}, {T1#tcb.rcv_nxt, T1#tcb.ack_now}),
    ?assertMatch({[{S, E}], _} when S =:= ?RCV + 3 andalso E =:= ?RCV + 6, erx_tcp_sack:ack(T1#tcb.rcv_sack)),
    {T2, [{deliver, Data}]} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"abc">>)], T1#tcb{ack_now = false}),
    ?assertEqual(<<"abcdef">>, iolist_to_binary(Data)),
    ?assertEqual({?RCV + 6, 6}, {T2#tcb.rcv_nxt, T2#tcb.rcv_buffered}),
    ?assertMatch({[], _}, erx_tcp_sack:ack(T2#tcb.rcv_sack)).

duplicate_data_is_reported_as_dsack_test() ->
    T0 = (est())#tcb{sack = on, rcv_nxt = ?RCV + 10, loss_state = erx_tcp_loss_dupack:init(#{sack => true})},
    {T, []} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"0123456789">>)], T0),
    ?assertMatch({[{S, E}], _} when S =:= ?RCV andalso E =:= ?RCV + 10, erx_tcp_sack:ack(T#tcb.rcv_sack)).

%% The reassembly queue holds no more than the receive buffer's free room.
reassembly_is_bounded_by_the_buffer_test() ->
    T0 = (est())#tcb{rcv_buffered = 9000},
    {T, []} = input([wire(?RCV + 10, ?ISS + 1, ?ACK, binary:copy(<<"x">>, 1000))], T0),
    ?assert(erx_tcp_reass:is_empty(T#tcb.reass)).

data_after_shutdown_of_the_receive_side_is_discarded_test() ->
    {T, []} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"abc">>)], (est())#tcb{rcv_closed = true}),
    ?assertEqual({?RCV + 3, 0}, {T#tcb.rcv_nxt, T#tcb.rcv_buffered}).

%% --- fin, tcp_input.c:3315-3369 ---------------------------------------------------------

fin_transitions_test_() ->
    Fin = fun(State) ->
              {T, A} = input([wire(?RCV, ?ISS + 1, ?FIN_ACK, <<"z">>)], (est())#tcb{state = State}),
              {T#tcb.state, T#tcb.rcv_nxt, T#tcb.ack_now, A}
          end,
    Eof = [{deliver, [<<"z">>]}, {notify, eof}],
    [?_assertEqual({close_wait, ?RCV + 2, true, Eof}, Fin(established)),
     ?_assertEqual({closing, ?RCV + 2, true, Eof}, Fin(fin_wait_1)),
     ?_assertEqual({time_wait, ?RCV + 2, true, Eof}, Fin(fin_wait_2)),
     ?_assertEqual({close_wait, ?RCV + 2, true, Eof},
                   begin
                       Log = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(?ISS), ?ISS, ?ISS + 1, 1000, ?T0),
                       T0 = (est())#tcb{state = syn_received, snd_una = ?ISS, sendlog = Log},
                       {T, A} = input([wire(?RCV, ?ISS + 1, ?FIN_ACK, <<"z">>)], T0),
                       {T#tcb.state, T#tcb.rcv_nxt, T#tcb.ack_now, A}
                   end)].

second_fin_is_ignored_test() ->
    {T, []} = input([wire(?RCV, ?ISS + 1, ?FIN_ACK)], (est())#tcb{state = close_wait}),
    ?assertEqual({close_wait, ?RCV}, {T#tcb.state, T#tcb.rcv_nxt}).

out_of_order_fin_waits_for_the_data_before_it_test() ->
    {T1, []} = input([wire(?RCV + 2, ?ISS + 1, ?FIN_ACK, <<"cd">>)], est()),
    ?assertEqual(established, T1#tcb.state),
    {T2, A} = input([wire(?RCV, ?ISS + 1, ?ACK, <<"ab">>)], T1),
    ?assertMatch([{deliver, _}, {notify, eof}], A),
    ?assertEqual({close_wait, ?RCV + 5}, {T2#tcb.state, T2#tcb.rcv_nxt}).

%% --- header prediction, tcp_input.c:1731-1950 -------------------------------------------

header_prediction_takes_the_common_cases_test_() ->
    Hp = fun(Wire, Tcb) ->
             [{lift, Lift}, {timestamps, Ts}, {header_prediction, Fun} | _] = erx_tcp_input:stages(),
             {continue, T1, S1} = Lift(Wire, Tcb, ctx()),
             {continue, T2, S2} = Ts(S1, T1, ctx()),
             element(1, Fun(S2, T2, ctx()))
         end,
    [?_assertEqual(done, Hp(wire(?RCV, ?ISS + 501, ?ACK), est(1000, 0))),
     ?_assertEqual(done, Hp(wire(?RCV, ?ISS + 1, ?ACK, <<"abc">>), est(1000, 0))),
     %% A changed window, an ACK at snd_una without data, and data with a new ACK go the
     %% general way.
     ?_assertEqual(continue, Hp(wire(?RCV, ?ISS + 501, ?ACK, <<>>, #tcp_opts{}, 9000, 0),
                                est(1000, 0))),
     ?_assertEqual(continue, Hp(wire(?RCV, ?ISS + 1, ?ACK), est(1000, 0))),
     ?_assertEqual(continue, Hp(wire(?RCV, ?ISS + 501, ?ACK, <<"abc">>), est(1000, 0)))].

%% Header prediction and the general stages give the same control block and actions for
%% every generated segment the fast path takes, and it takes a good share of them.
header_prediction_agrees_with_the_general_stages_test() ->
    {Taken, Mismatches, _} =
        lists:foldl(fun(_, {N, Bad, R0}) ->
                            {Tcb, Wire, R} = generate(R0),
                            case compare(Tcb, Wire) of
                                declined -> {N, Bad, R};
                                same -> {N + 1, Bad, R};
                                Diff -> {N + 1, [{Tcb, Wire, Diff} | Bad], R}
                            end
                    end, {0, [], rand:seed_s(exsss, {16, 32, 48})}, lists:seq(1, 10000)),
    ?assertEqual([], [{Wire, Diff} || {_, Wire, Diff} <- lists:sublist(Mismatches, 3)]),
    ?assertMatch(N when N > 300, Taken).

%% Lift and timestamps, then header prediction finishing its case, against every stage after
%% header prediction.
compare(Tcb, Wire) ->
    Stages = erx_tcp_input:stages(),
    [{lift, Lift}, {timestamps, Ts}, {header_prediction, Hp} | General] = Stages,
    Ctx = ctx(),
    case Lift(Wire, Tcb, Ctx) of
        {continue, T1, S1} ->
            {continue, T2, S2} = Ts(S1, T1, Ctx),
            case Hp(S2, T2, Ctx) of
                {done, T3, Actions} ->
                    Fast = {T3, Actions},
                    case erx_tcp_input:run(General, S2, T2, Ctx) of
                        Fast -> same;
                        Slow -> diff(Fast, Slow)
                    end;
                {continue, _, _} ->
                    declined
            end;
        _ ->
            declined
    end.

%% The fields that differ, by name, and the actions of each path when they differ.
diff({F, FA}, {S, SA}) ->
    Fields = [{Name, X, Y} || {Name, X, Y} <- lists:zip3(record_info(fields, tcb),
                                                         tl(tuple_to_list(F)),
                                                         tl(tuple_to_list(S))), X =/= Y],
    {Fields, [{FA, SA} || FA =/= SA]}.

%% A random connection, mostly established, near a likely fast-path segment, and the segment.
%% Each choice is drawn from its list, so a value listed several times is that much likelier;
%% the lists lean toward the two cases header prediction takes, and the rest are the near
%% misses: other states, a closed owner, RST and SYN, old timestamps and acknowledgements.
generate(R0) ->
    {C, R1} = picks(#{state => [established, established, established, established,
                                close_wait, fin_wait_1],
                      out => [0, 500, 3000, 3000], extra => [0, 1000],
                      rewound => [false, false, false, false, false, false, true],
                      snd_wnd => [10000, 10000, 10000, 4000, 0], wl1 => [0, 0, -500, 3],
                      wl2 => [0, -200], ts => [off, recent, recent, invalid],
                      sack => [false, true], recovery => [none, none, none, none, none, fast, cong],
                      timer => [none, rexmt, persist], probe => [false, true],
                      queued => [false, false, false, false, false, true],
                      buffered => [0, 0, 9500], delack => [false, true], shift => [0, 0, 1],
                      closed => [false, false, false, false, false, true]}, R0),
    Una = ?ISS + 1,
    Out = get(out, C),
    Max = Una + Out,
    Log = case Out of
              0 -> erx_tcp_sendlog:new(Una);
              _ -> erx_tcp_sendlog:sent(erx_tcp_sendlog:new(Una), Una, Max, 1000, ?T0 - 30000)
          end,
    Base = est(),
    Recovery = get(recovery, C),
    Ccv = (Base#tcb.ccv)#ccv{cwnd = 8000, ssthresh = 4000, fast_recovery = Recovery =:= fast,
                             cong_recovery = Recovery =/= none},
    Tcb0 = Base#tcb{state = get(state, C), user_closed = get(closed, C),
                    snd_nxt = case get(rewound, C) of true -> Una; false -> Max end,
                    snd_max = Max, sendlog = Log, snd_wnd = get(snd_wnd, C), max_sndwnd = 10000,
                    snd_wl1 = ?RCV + get(wl1, C), snd_wl2 = Una + get(wl2, C),
                    sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(),
                                                   binary:copy(<<"d">>, Out + get(extra, C))),
                    ccv = Ccv, snd_recover = Una + Out div 2,
                    send_timer = case {get(timer, C), Out} of
                                     {none, _} -> none;
                                     {_, 0} -> none;
                                     {Kind, _} -> {Kind, ?T0 + 500000}
                                 end,
                    rtt_probe = case get(probe, C) andalso Out > 0 of
                                    true -> {Una, ?T0 - 20000};
                                    false -> none
                                end,
                    reass = queued(get(queued, C)), rcv_buffered = get(buffered, C),
                    rxtshift = get(shift, C),
                    rexmt_prev = case get(shift, C) of
                                     1 -> #rexmt_prev{cwnd = 9000, ssthresh = 9000,
                                                      recover = Una, fast = false, cong = false,
                                                      badrxtwin = ?MS0 - 5};
                                     0 -> none
                                 end,
                    deadlines = case get(delack, C) of
                                    true -> #deadlines{delack = ?T0 + 10000};
                                    false -> #deadlines{}
                                end},
    Tcb1 = case get(ts, C) of
               off -> Tcb0;
               recent -> with_ts(Tcb0);
               %% ts_recent invalidated after 24 idle days (PAWS has nothing to compare).
               invalid -> Tcb0#tcb{ts = #ts{recent = 0, recent_age = ?T0, offset = ?OFFSET}}
           end,
    Tcb = case get(sack, C) of
              true -> Tcb1#tcb{sack = on, loss_state = erx_tcp_loss_dupack:init(#{sack => true})};
              false -> Tcb1
          end,
    {S, R} = picks(#{seq => [0, 0, 0, 0, 0, 0, 0, 0, 1, -1],
                     ack => [new, new, all, una, una, old, beyond, ancient],
                     len => [0, 0, 1, 100, 1000, 1200],
                     flag => [0, 0, 0, 0, ?TH_PUSH, ?TH_ECE, ?TH_CWR, ?TH_FIN, ?TH_URG, ?TH_RST,
                              ?TH_SYN],
                     same_window => [true, true, true, true, true, true, false],
                     tsval => [500, 501, 501, 499, 0], echo => [none, 0, 20, 4],
                     ecn => [0, 0, 1, 3], sack => [false, false, false, false, false, true]}, R1),
    Len = get(len, S),
    Ack = case aim(get(ack, S), Len) of
              new -> Una + max(1, Out div 2);
              una -> Una;
              old -> Una - 1;
              beyond -> Max + 1;
              all -> Max;
              %% Below RFC 5961's acceptable floor.
              ancient -> Una - 20000
          end,
    Opts = #tcp_opts{ts = case {Tcb#tcb.ts, get(echo, S)} of
                              {off, _} -> none;
                              {_, none} -> {get(tsval, S), 0};
                              {_, Echo} -> {get(tsval, S), erx_tcp_seq:wire(?MS0 - Echo + ?OFFSET)}
                          end,
                     sacks = case get(sack, S) andalso Out > 0 of
                                 true -> [{erx_tcp_seq:wire(Max - 100), erx_tcp_seq:wire(Max)}];
                                 false -> []
                             end},
    Win = case get(same_window, S) of
              true -> get(snd_wnd, C);
              false -> 7000
          end,
    {Header, Data, _, _} = wire(?RCV + get(seq, S), Ack, ?ACK bor get(flag, S),
                             binary:copy(<<"p">>, Len), Opts, Win, 1),
    {Tcb, {Header, Data, get(ecn, S), unicast}, R}.

get(Key, Choices) -> maps:get(Key, Choices).

queued(false) ->
    erx_tcp_reass:new();
queued(true) ->
    {queued, Q} = erx_tcp_reass:insert(erx_tcp_reass:new(),
                                       #{seq => ?RCV + 2000, data => [<<"q">>], fin => false}, ?RCV,
                                       #{established => true, room => 10000, hiwat => 10000,
                                         mss => 1000}),
    Q.

%% Most pure ACKs acknowledge new data and most data segments acknowledge nothing new, the
%% two cases header prediction takes.
aim(new, 0) -> new;
aim(una, 0) -> new;
aim(new, _) -> una;
aim(all, Len) when Len > 0 -> una;
aim(Choice, _) -> Choice.

%% One value from each list, in the order of the sorted keys, so a seed gives one sequence.
picks(Lists, R0) ->
    {Pairs, R} = lists:mapfoldl(fun({Key, List}, R1) ->
                                        {I, R2} = rand:uniform_s(length(List), R1),
                                        {{Key, lists:nth(I, List)}, R2}
                                end, R0, lists:sort(maps:to_list(Lists))),
    {maps:from_list(Pairs), R}.
