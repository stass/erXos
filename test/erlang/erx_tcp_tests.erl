%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The step's dispatch and settling (erx_tcp), the user requests (erx_tcp_user, from
%% tcp_usrreq.c and tcp_subr.c), the timer expirations (erx_tcp_timer, from tcp_timer.c)
%% and the send buffer (erx_tcp_sndbuf). Times are microseconds.
-module(erx_tcp_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
-define(S(Ms), ((Ms) * 1000)).
-define(FROM, {self(), tag}).

ctx(Now) -> #tcp_ctx{now = Now, credit = 64, mtu = 1500}.

new() ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => 1000, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => 100, rcv_hiwat => 65536,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

%% A connection in State with its handshake done at T0.
in(State) ->
    (new())#tcb{state = State, irs = 5000, rcv_nxt = 5001, rcv_adv = 5001 + 65536,
                snd_una = 1001, snd_nxt = 1001, snd_max = 1001,
                sendlog = erx_tcp_sendlog:new(1001), wscale = {0, 0}, ts = off, sack = off}.

step(Event, Tcb, Now) -> erx_tcp:step(Event, Tcb, ctx(Now)).

ended(Actions) -> lists:last(Actions) =:= finish.

%% The actions after the RST|ACK output sends first for a connection dropped after a SYN.
after_rst([{transmit, [{#tcp{flags = Flags, win = 0}, _, []}]} | Rest])
  when Flags =:= ?TH_RST bor ?TH_ACK ->
    Rest.

%% A timer expiry without the output that follows it in erx_tcp:step/3.
expire(Tcb, Now) -> erx_tcp_timer:expired(Tcb, ctx(Now)).

%% --- tcp_newtcpcb and tcp_connect ---

new_test() ->
    T = new(),
    ?assertEqual(closed, T#tcb.state),
    ?assertEqual({1000, 1000, 1000}, {T#tcb.snd_una, T#tcb.snd_nxt, T#tcb.snd_max}),
    ?assertEqual({{requested, 7}, requested, requested}, {T#tcb.ts, T#tcb.wscale, T#tcb.sack}),
    ?assertEqual(536, T#tcb.maxseg),
    ?assertEqual(1000, erx_tcp_rtt:rto(T#tcb.rtt)),
    ?assertEqual(infinity, erx_tcp:next_deadline(T)).

connect_arms_the_establishment_timer_test() ->
    {T, Actions} = step({user, {connect, ?FROM}}, new(), ?T0),
    ?assertEqual(syn_sent, T#tcb.state),
    ?assertEqual(?T0 + ?S(75000), T#tcb.deadlines#deadlines.keep),
    %% Output sent the SYN and armed its retransmission timer.
    ?assertMatch([{transmit, [{#tcp{flags = ?TH_SYN, seq = 1000}, _, []}]}], Actions),
    ?assertEqual(?T0 + ?S(1000), erx_tcp:next_deadline(T)),
    {_, Again} = step({user, {connect, ?FROM}}, T, ?T0),
    ?assertEqual([{reply, ?FROM, {error, ealready}}], Again).

connect_is_answered_once_established_test() ->
    {T0, [{transmit, _}]} = step({user, {connect, ?FROM}}, new(), ?T0),
    {T1, Actions} = step({user, {rcvd, 0}}, T0#tcb{state = established}, ?T0),
    ?assertEqual([{reply, ?FROM, ok}], Actions),
    ?assertEqual(none, T1#tcb.connect_waiter).

establishment_timeout_answers_connect_test() ->
    {T0, [{transmit, _}]} = step({user, {connect, ?FROM}}, new(), ?T0),
    {_, Actions} = step({expired, ?T0 + ?S(75000)}, T0, ?T0 + ?S(75000)),
    %% tcp_timer_keep before ESTABLISHED: dropped with ETIMEDOUT, no RST (no SYN received).
    ?assertEqual([{reply, ?FROM, {error, etimedout}}, {notify, {error, etimedout}},
                  {notify, closed}, finish], Actions).

%% --- tcp_usrclosed, tcp_disconnect, tcp_drop ---

usrclosed_test_() ->
    Cases = [{syn_sent, syn_sent, queued}, {syn_received, syn_received, queued},
             {established, fin_wait_1, queued}, {close_wait, last_ack, queued},
             {fin_wait_1, fin_wait_1, none}, {last_ack, last_ack, none}],
    [?_assertMatch(#tcb{state = To, fin = Fin},
                   erx_tcp_user:usrclosed(in(From), ctx(?T0)))
     || {From, To, Fin} <- Cases].

usrclosed_in_fin_wait_2_arms_maxidle_test() ->
    T = erx_tcp_user:usrclosed(in(fin_wait_2), ctx(?T0)),
    ?assertEqual(?T0 + ?S(8 * 75000), T#tcb.deadlines#deadlines.msl2).

close_before_established_ends_quietly_test() ->
    {T, Actions} = step({user, close}, in(syn_sent), ?T0),
    ?assertEqual(closed, T#tcb.state),
    ?assertNot(T#tcb.reset_peer),
    ?assertEqual([{notify, closed}, finish], Actions).

close_established_sends_fin_test() ->
    {T, Actions} = step({user, close}, in(established), ?T0),
    ?assertEqual({fin_wait_1, {sent, 1001}, true, true}, {T#tcb.state, T#tcb.fin, T#tcb.user_closed, T#tcb.snd_closed}),
    ?assertMatch([{transmit, [{#tcp{flags = ?TH_FIN bor ?TH_ACK, seq = 1001}, _, []}]}], Actions).

close_in_time_wait_changes_nothing_test() ->
    T = in(time_wait),
    ?assertEqual({T, []}, step({user, close}, T, ?T0)).

linger_zero_drops_with_rst_test() ->
    {T, Actions} = step({user, close}, (in(established))#tcb{linger = 0}, ?T0),
    ?assertEqual(none, T#tcb.error),
    ?assertEqual([{notify, closed}, finish], after_rst(Actions)).

abort_test() ->
    {T, Actions} = step({user, abort}, (in(established))#tcb{send_waiter = {?FROM, <<"x">>}}, ?T0),
    ?assertEqual([{reply, ?FROM, {error, econnaborted}}, {notify, {error, econnaborted}},
                  {notify, closed}, finish], after_rst(Actions)),
    ?assertEqual({none, infinity}, {T#tcb.send_waiter, erx_tcp:next_deadline(T)}).

drop_reports_the_soft_error_on_timeout_test() ->
    T = erx_tcp_user:drop((in(established))#tcb{soft_error = ehostunreach}, etimedout),
    ?assertEqual(ehostunreach, T#tcb.error),
    T2 = erx_tcp_user:drop((in(established))#tcb{soft_error = ehostunreach}, econnreset),
    ?assertEqual(econnreset, T2#tcb.error).

%% --- tcp_usr_send, tcp_usr_rcvd, tcp_usr_shutdown ---

send_test() ->
    {_, NotYet} = step({user, {send, ?FROM, <<"x">>}}, (new())#tcb{state = syn_sent}, ?T0),
    ?assertMatch([{reply, _, {error, enotconn}}, {transmit, _}], NotYet),
    {T1, Now} = step({user, {send, ?FROM, binary:copy(<<"a">>, 100)}}, in(established), ?T0),
    ?assertEqual([{reply, ?FROM, ok}], Now),
    %% The buffer is at its high watermark (100): the caller waits with its bytes, nothing
    %% past the watermark is buffered, and a second send is refused.
    {T2, Later} = step({user, {send, ?FROM, <<"bc">>}}, T1, ?T0),
    ?assertEqual({[], {?FROM, <<"bc">>}, 100},
                 {Later, T2#tcb.send_waiter, erx_tcp_sndbuf:size(T2#tcb.sndbuf)}),
    ?assertEqual([{reply, other, {error, ebusy}}],
                 element(2, step({user, {send, other, <<"d">>}}, T2, ?T0))),
    %% One byte acknowledged: not enough free space to wake the writer for its two bytes.
    {T3, []} = step({user, {rcvd, 0}}, T2#tcb{sndbuf = erx_tcp_sndbuf:drop(T2#tcb.sndbuf, 1)}, ?T0),
    ?assertMatch({_, <<"bc">>}, T3#tcb.send_waiter),
    {T4, Answered} = step({user, {rcvd, 0}}, T3#tcb{sndbuf = erx_tcp_sndbuf:drop(T3#tcb.sndbuf, 50)}, ?T0),
    ?assertEqual({[{reply, ?FROM, ok}], none, 51},
                 {Answered, T4#tcb.send_waiter, erx_tcp_sndbuf:size(T4#tcb.sndbuf)}).

%% An ACK that empties the send buffer moves the waiting writer's bytes in, and the same step
%% sends them: nothing else may follow to send them, since one batch can carry every ACK of
%% what was in flight (the tap transport reads a burst's ACKs in one call). The buffer keeps
%% its size, autosizing off, so the writer waits.
an_ack_that_frees_room_sends_the_waiting_writers_bytes_test() ->
    Open = (in(established))#tcb{snd_wnd = 65535, max_sndwnd = 65535, snd_autosize = false},
    T0 = Open#tcb{ccv = (Open#tcb.ccv)#ccv{cwnd = 65535}},
    {T1, First} = step({user, {send, ?FROM, binary:copy(<<"a">>, 100)}}, T0, ?T0),
    ?assertEqual({[1001], 100}, {seqs(First), payload_bytes(First)}),
    {T2, []} = step({user, {send, ?FROM, binary:copy(<<"b">>, 100)}}, T1, ?T0),
    Ack = {#tcp{sport = 80, dport = 4000, seq = 5001, ack = 1101, flags = ?TH_ACK, win = 65535,
                urp = 0, opts = #tcp_opts{}}, <<>>, 0, unicast},
    {T3, Second} = step({segments, [Ack]}, T2, ?T0 + ?S(1)),
    ?assertEqual({[1101], 100, true, none},
                 {seqs(Second), payload_bytes(Second), lists:member({reply, ?FROM, ok}, Second),
                  T3#tcb.send_waiter}).

%% A writer still waiting when the send side closes is answered EPIPE, as sosend answers
%% after its sbwait, and none of its bytes enter the buffer behind the FIN. The buffer keeps
%% its size, autosizing off, so the writer waits.
a_writer_waiting_when_the_send_side_closes_gets_epipe_test() ->
    Open = (in(established))#tcb{snd_wnd = 65535, max_sndwnd = 65535, snd_autosize = false},
    T0 = Open#tcb{ccv = (Open#tcb.ccv)#ccv{cwnd = 65535}},
    {T1, _} = step({user, {send, ?FROM, binary:copy(<<"a">>, 100)}}, T0, ?T0),
    {T2, []} = step({user, {send, ?FROM, binary:copy(<<"b">>, 100)}}, T1, ?T0),
    {T3, Closed} = step({user, {shutdown, other, write}}, T2, ?T0),
    ?assertEqual({true, none, 100},
                 {lists:member({reply, ?FROM, {error, epipe}}, Closed), T3#tcb.send_waiter,
                  erx_tcp_sndbuf:size(T3#tcb.sndbuf)}).

seqs(Actions) -> [Seq || {transmit, Segs} <- Actions, {#tcp{seq = Seq}, _, _} <- Segs].

payload_bytes(Actions) ->
    lists:sum([iolist_size(P) || {transmit, Segs} <- Actions, {_, _, P} <- Segs]).

send_after_shutdown_test() ->
    {T, [{reply, _, ok}, {transmit, _}]} = step({user, {shutdown, ?FROM, write}}, in(close_wait), ?T0),
    ?assertEqual(last_ack, T#tcb.state),
    ?assertEqual([{reply, ?FROM, {error, epipe}}],
                 element(2, step({user, {send, ?FROM, <<"x">>}}, T, ?T0))).

shutdown_read_flushes_the_receive_side_test() ->
    {T, [{reply, _, ok}]} =
        step({user, {shutdown, ?FROM, read}}, (in(established))#tcb{rcv_buffered = 10}, ?T0),
    ?assertEqual({established, true, 0}, {T#tcb.state, T#tcb.rcv_closed, T#tcb.rcv_buffered}).

rcvd_opens_the_window_test() ->
    {T, []} = step({user, {rcvd, 30}}, (in(established))#tcb{rcv_buffered = 20}, ?T0),
    ?assertEqual(0, T#tcb.rcv_buffered),
    ?assertEqual(65536, erx_tcp:rcv_space(T)).

%% tcp_usrreq.c:834-870, tcp_output.c:655-692: bytes leaving the receive buffer take a step
%% only when its output would send a window update on its own, at the update's exact
%% thresholds. A full 64 KiB buffer with nothing advertised and 1448-byte segments: two
%% segments of window, under an eighth of the buffer, are worth an update and a byte less is
%% not; in a 2000-byte buffer half the buffer is. Quiet calls add up, so a reader taking a
%% byte at a time still reaches the update, and draining the buffer always does: no stall.
%% No update goes while a delayed ACK will carry the window or once the peer's FIN came; an
%% ACK, or data, the driver's full queue held back is owed whatever the window.
rcvd_steps_only_for_a_window_update_test() ->
    Full = (in(established))#tcb{maxseg = 1448, rcv_buffered = 65536, rcv_adv = 5001},
    {quiet, Below} = erx_tcp:rcvd(2 * 1448 - 1, Full),
    ?assertEqual(65536 - (2 * 1448 - 1), Below#tcb.rcv_buffered),
    ?assertEqual(step, erx_tcp:rcvd(2 * 1448, Full)),
    ?assertEqual(step, erx_tcp:rcvd(1, Below)),
    ?assertEqual(step, erx_tcp:rcvd(65536, Full)),
    Small = Full#tcb{rcv_hiwat = 2000, rcv_buffered = 2000},
    ?assertMatch({quiet, #tcb{rcv_buffered = 1001}}, erx_tcp:rcvd(999, Small)),
    ?assertEqual(step, erx_tcp:rcvd(1000, Small)),
    Delack = Full#tcb{deadlines = #deadlines{delack = ?T0 + 40}},
    ?assertMatch({quiet, #tcb{rcv_buffered = 0}}, erx_tcp:rcvd(65536, Delack)),
    ?assertMatch({quiet, #tcb{rcv_buffered = 0}},
                 erx_tcp:rcvd(65536, Full#tcb{state = close_wait})),
    ?assertEqual(step, erx_tcp:rcvd(1, Full#tcb{ack_now = true})),
    ?assertEqual(step, erx_tcp:rcvd(1, Full#tcb{stopped_short = true})).

%% The step the caller takes at the threshold sends the update, with the whole window the
%% bytes opened; below it, the step sends nothing, which is what the quiet call skips.
rcvd_step_sends_the_update_test() ->
    Full = (in(established))#tcb{maxseg = 1448, rcv_buffered = 65536, rcv_adv = 5001},
    {T, [{transmit, [{#tcp{ack = 5001, win = Win}, _, []}]}]} =
        step({user, {rcvd, 2 * 1448}}, Full, ?T0),
    ?assertEqual({2 * 1448, 5001 + 2 * 1448}, {Win, T#tcb.rcv_adv}),
    ?assertMatch({_, []}, step({user, {rcvd, 2 * 1448 - 1}}, Full, ?T0)).

%% --- tcp_timer.c ---

next_deadline_is_the_earliest_test() ->
    T = (in(established))#tcb{send_timer = {rexmt, ?T0 + 50},
                               deadlines = #deadlines{delack = ?T0 + 40, keep = ?T0 + 10}},
    ?assertEqual(?T0 + 10, erx_tcp:next_deadline(T)).

early_timer_changes_nothing_test() ->
    T = (in(established))#tcb{deadlines = #deadlines{delack = ?T0 + 40}},
    ?assertEqual({T, []}, step({expired, ?T0}, T, ?T0)).

delack_requests_an_ack_test() ->
    T = (in(established))#tcb{deadlines = #deadlines{delack = ?T0 + 40}},
    {T1, []} = expire(T, ?T0 + 40),
    ?assert(T1#tcb.ack_now),
    ?assertEqual(infinity, erx_tcp:next_deadline(T1)).

keepalive_waits_out_the_idle_time_test() ->
    T = (in(established))#tcb{rcvtime = ?T0, deadlines = #deadlines{keep = ?T0 + ?S(1000)}},
    {T1, []} = step({expired, ?T0 + ?S(1000)}, T, ?T0 + ?S(1000)),
    ?assertEqual(?T0 + ?S(7200000), T1#tcb.deadlines#deadlines.keep).

keepalive_probe_test() ->
    Now = ?T0 + ?S(7200000),
    T = (in(established))#tcb{rcvtime = ?T0, deadlines = #deadlines{keep = Now}},
    {T1, [{transmit, [{Probe, _, []}]}]} = step({expired, Now}, T, Now),
    %% One byte below snd_una, acknowledging rcv_nxt: the peer must answer.
    ?assertMatch(#tcp{sport = 4000, dport = 80, seq = 1000, ack = 5001, flags = ?TH_ACK}, Probe),
    ?assertEqual(Now + ?S(75000), T1#tcb.deadlines#deadlines.keep).

keepalive_gives_up_test() ->
    Now = ?T0 + ?S(7200000 + 8 * 75000),
    T = (in(established))#tcb{rcvtime = ?T0, deadlines = #deadlines{keep = Now}},
    {_, Actions} = step({expired, Now}, T, Now),
    ?assertEqual([{notify, {error, etimedout}}, {notify, closed}, finish], after_rst(Actions)).

keepalive_in_fin_wait_2_rearms_test() ->
    Now = ?T0 + ?S(7200000 + 8 * 75000),
    T = (in(fin_wait_2))#tcb{rcvtime = ?T0, deadlines = #deadlines{keep = Now}},
    {T1, []} = step({expired, Now}, T, Now),
    ?assertEqual(Now + ?S(7200000), T1#tcb.deadlines#deadlines.keep).

msl2_test() ->
    Now = ?T0 + ?S(60000),
    {_, Ended} = step({expired, Now}, (in(time_wait))#tcb{deadlines = #deadlines{msl2 = Now}}, Now),
    ?assertEqual([{notify, closed}, finish], Ended),
    Idle = (in(fin_wait_2))#tcb{rcvtime = ?T0, deadlines = #deadlines{msl2 = Now}},
    {T1, []} = step({expired, Now}, Idle, Now),
    ?assertEqual(Now + ?S(75000), T1#tcb.deadlines#deadlines.msl2),
    Late = ?T0 + ?S(8 * 75000) + 1,
    {_, Gone} = step({expired, Late}, Idle#tcb{deadlines = #deadlines{msl2 = Late}}, Late),
    ?assertEqual([{notify, closed}, finish], Gone).

rexmt_in_syn_sent_test() ->
    {T0, [{transmit, _}]} = step({user, {connect, ?FROM}}, new(), ?T0),
    T = T0#tcb{snd_nxt = 1001, snd_max = 1001, send_timer = {rexmt, ?T0 + ?S(1000)}},
    Now = ?T0 + ?S(1000),
    {T1, []} = expire(T, Now),
    %% tcp_rexmit_initial * tcp_backoff[1] + 200 ms.
    ?assertEqual({{rexmt, Now + ?S(2200)}, 1}, {T1#tcb.send_timer, T1#tcb.rxtshift}),
    ?assertEqual({1000, 1001, 1, true}, {T1#tcb.snd_nxt, T1#tcb.snd_recover,
                                         T1#tcb.ccv#ccv.cwnd, T1#tcb.ack_now}).

rexmt_gives_up_after_tcp_retries_test() ->
    T = (in(established))#tcb{send_timer = {rexmt, ?T0}, rxtshift = 12, soft_error = ehostunreach,
                               connect_waiter = none},
    {_, Actions} = step({expired, ?T0}, T, ?T0),
    ?assertEqual([{notify, {error, ehostunreach}}, {notify, closed}, finish], after_rst(Actions)).

rexmt_first_timeout_keeps_a_snapshot_test() ->
    Ccv = (in(established))#tcb.ccv,
    T = (in(established))#tcb{snd_max = 3001, snd_recover = 900,
                               send_timer = {rexmt, ?T0},
                               ccv = Ccv#ccv{cwnd = 10000, ssthresh = 8000, fast_recovery = true,
                                             cong_recovery = true}},
    {T1, []} = expire(T, ?T0),
    ?assertMatch(#rexmt_prev{cwnd = 10000, ssthresh = 8000, recover = 900, fast = true,
                             cong = true}, T1#tcb.rexmt_prev),
    %% CC_RTO leaves recovery and NewReno's timeout response sets the window to one segment.
    ?assertMatch(#ccv{fast_recovery = false, cong_recovery = false, cwnd = 536}, T1#tcb.ccv),
    ?assertEqual({1001, 3001}, {T1#tcb.snd_nxt, T1#tcb.snd_recover}),
    %% The second timeout forgets the snapshot.
    {{rexmt, At}, 1} = {T1#tcb.send_timer, T1#tcb.rxtshift},
    {T2, []} = expire(T1, At),
    ?assertEqual({none, 2}, {T2#tcb.rexmt_prev, erx_tcp:rxtshift(T2)}),
    %% CC_RTO_ERR from the first restores it.
    T3 = erx_tcp:cong_signal(T1, rto_err, 1001, ctx(?T0)),
    ?assertMatch(#ccv{cwnd = 10000, ssthresh = 8000, fast_recovery = true}, T3#tcb.ccv),
    ?assertEqual({0, 3001, none}, {erx_tcp:rxtshift(T3), T3#tcb.snd_nxt, T3#tcb.rexmt_prev}).

persist_backs_off_test() ->
    T = (in(established))#tcb{send_timer = {persist, ?T0}},
    {T1, []} = expire(T, ?T0),
    %% No RTT sample yet: the base is under tcp_persmin, so 5 s.
    ?assertEqual({{persist, ?T0 + ?S(5000)}, 1}, {T1#tcb.send_timer, T1#tcb.rxtshift}),
    ?assert(T1#tcb.force_data).

persist_gives_up_test() ->
    Now = ?T0 + ?S(7200000),
    T = (in(established))#tcb{rcvtime = ?T0, send_timer = {persist, Now}, rxtshift = 12},
    {_, Actions} = step({expired, Now}, T, Now),
    ?assert(ended(Actions)),
    %% Past CLOSE-WAIT, idle for TCPTV_PERSMAX.
    Late = ?T0 + ?S(60000),
    Closing0 = (in(fin_wait_1))#tcb{rcvtime = ?T0, send_timer = {persist, Late}, rxtshift = 1},
    {_, Closing} = step({expired, Late}, Closing0, Late),
    ?assert(ended(Closing)).

timers_run_earliest_first_and_stop_at_the_end_test() ->
    %% Keepalive (due first) ends the connection; the later 2MSL deadline never runs.
    Now = ?T0 + ?S(7200000 + 8 * 75000),
    T = (in(established))#tcb{rcvtime = ?T0, deadlines = #deadlines{keep = Now - 1, delack = Now}},
    {T1, _} = step({expired, Now}, T, Now),
    ?assertNot(T1#tcb.ack_now).

%% --- the send buffer ---

sndbuf_test() ->
    B = lists:foldl(fun(D, Acc) -> erx_tcp_sndbuf:append(Acc, D) end, erx_tcp_sndbuf:new(),
                    [<<"abc">>, <<>>, <<"defg">>, <<"h">>]),
    ?assertEqual(8, erx_tcp_sndbuf:size(B)),
    ?assertEqual(<<"cdef">>, iolist_to_binary(erx_tcp_sndbuf:range(B, 2, 4, infinity))),
    ?assertEqual(<<"h">>, iolist_to_binary(erx_tcp_sndbuf:range(B, 7, 10, infinity))),
    ?assertEqual([], erx_tcp_sndbuf:range(B, 8, 1, infinity)),
    %% At most Max binaries: the range ends where the Max-th binary does.
    ?assertEqual([<<"c">>, <<"defg">>], erx_tcp_sndbuf:range(B, 2, 6, 2)),
    ?assertEqual([<<"c">>], erx_tcp_sndbuf:range(B, 2, 6, 1)),
    ?assertEqual([<<"de">>], erx_tcp_sndbuf:range(B, 3, 2, 1)),
    B1 = erx_tcp_sndbuf:drop(B, 4),
    ?assertEqual({4, <<"efgh">>}, {erx_tcp_sndbuf:size(B1), iolist_to_binary(erx_tcp_sndbuf:range(B1, 0, 8, infinity))}),
    ?assertEqual(0, erx_tcp_sndbuf:size(erx_tcp_sndbuf:drop(B1, 99))).

%% --- regressions from review ---

a_new_block_survives_events_before_connect_test() ->
    {T, Actions} = step({user, {send, ?FROM, <<"x">>}}, new(), ?T0),
    ?assertEqual([{reply, ?FROM, {error, enotconn}}], Actions),
    ?assertEqual({[], []}, {element(2, step({buffer, snd, 50}, T, ?T0)),
                            element(2, step({expired, ?T0}, T, ?T0))}).

a_timer_message_ahead_of_the_clock_ends_test() ->
    %% The event's time is a hint: 2MSL re-arms from the context's time and runs once.
    T = (in(fin_wait_2))#tcb{rcvtime = ?T0, deadlines = #deadlines{msl2 = ?T0}},
    {T1, []} = erx_tcp:step({expired, ?T0 + ?S(3600000)}, T, ctx(?T0)),
    ?assertEqual(?T0 + ?S(75000), T1#tcb.deadlines#deadlines.msl2).

keepalive_options_of_zero_are_the_defaults_test() ->
    T = erx_tcp_user:new(#{family => inet, local => {<<1, 1, 1, 1>>, 1}, remote => {<<2, 2, 2, 2>>, 2},
                           iss => 0, ts_offset => 0, cc => erx_tcp_cc_newreno,
                           loss => erx_tcp_loss_dupack, snd_hiwat => 1, rcv_hiwat => 1,
                           gen => erx_net_rand:new(<<0:128>>), now => 0, keep_idle => 0}),
    ?assertEqual(7200000, T#tcb.keep_idle),
    ?assertError(badarg, erx_tcp_user:new(#{family => inet, local => {<<>>, 1}, remote => {<<>>, 2},
                                            iss => 0, ts_offset => 0, cc => erx_tcp_cc_newreno,
                                            loss => erx_tcp_loss_dupack, snd_hiwat => 1,
                                            rcv_hiwat => 1, gen => erx_net_rand:new(<<0:128>>),
                                            now => 0, keep_intvl => -1})).

rexmt_in_syn_sent_takes_no_snapshot_test() ->
    {T0, [{transmit, _}]} = step({user, {connect, ?FROM}}, new(), ?T0),
    {T1, []} = expire(T0#tcb{send_timer = {rexmt, ?T0}}, ?T0),
    ?assertEqual(none, T1#tcb.rexmt_prev).

shutdown_after_fin_wait_2_is_enotconn_test() ->
    T = (in(fin_wait_2))#tcb{deadlines = #deadlines{msl2 = ?T0 + 5}},
    ?assertEqual({T, [{reply, ?FROM, {error, enotconn}}]},
                 step({user, {shutdown, ?FROM, write}}, T, ?T0)).
