%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_tcp_input's stages 1-8, lift through check_ack, each named for the
%% lines of sys/netinet/tcp_input.c it checks. Window edges are checked on both sides and
%% across the 2^32 wrap of the wire numbers.

-module(erx_tcp_input_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
-define(S(Ms), ((Ms) * 1000)).
-define(ISS, 1000).
%% A receive sequence that has wrapped: rcv_nxt is past 2^32, so its wire value is small.
-define(WRAPPED, (16#100000000 + 5)).

ctx() -> ctx(?T0).
ctx(Now) -> #tcp_ctx{now = Now, credit = 64, mtu = 1500}.

new() ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => ?ISS, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => 65536, rcv_hiwat => 65536,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

syn_sent() ->
    (new())#tcb{state = syn_sent, snd_nxt = ?ISS + 1, snd_max = ?ISS + 1}.

%% An established connection receiving at RcvNxt with a window of 1,000 bytes.
est() -> est(5001).
est(RcvNxt) ->
    (new())#tcb{state = established, irs = RcvNxt - 1, rcv_nxt = RcvNxt, rcv_adv = RcvNxt,
                last_ack_sent = RcvNxt, rcv_hiwat = 1000, rcv_wnd = 1000, snd_una = ?ISS + 1,
                snd_nxt = ?ISS + 1, snd_max = ?ISS + 1, wscale = {0, 0}, ts = off, sack = off,
                sendlog = erx_tcp_sendlog:new(?ISS + 1)}.

with_ts(Tcb, Recent) -> Tcb#tcb{ts = #ts{recent = Recent, recent_age = ?T0, offset = 7}}.

wire(Seq, Ack, Flags) -> wire(Seq, Ack, Flags, <<>>, #tcp_opts{}).
wire(Seq, Ack, Flags, Data, Opts) ->
    {#tcp{sport = 80, dport = 4000, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = 1000, urp = 0, opts = Opts}, Data, 0, unicast}.

input(Segments, Tcb) -> erx_tcp_input:segments(Segments, Tcb, ctx()).

%% One stage on a lifted segment, as the pipeline would call it.
stage(Name, Seg, Tcb) ->
    {Name, Fun} = lists:keyfind(Name, 1, erx_tcp_input:stages()),
    Fun(Seg, Tcb, ctx()).

seg(Seq, Flags, Data) ->
    #seg{seq = Seq, ack = ?ISS + 1, flags = Flags, hdr_flags = Flags, win = 1000, urp = 0,
         data = Data, arrived = {Seq, Seq + byte_size(Data)}, ip_ecn = 0, link_cast = unicast}.

%% The RST a {reset, _} action carries: {Seq, Ack, Flags, Win}.
resets(Actions) ->
    [{S, A, F, W} || {reset, {#tcp{seq = S, ack = A, flags = F, win = W}, _, []}} <- Actions].

challenges(Actions) ->
    [{S, A} || {transmit, [{#tcp{seq = S, ack = A, flags = ?TH_ACK}, _, []}]} <- Actions].

%% --- lift, tcp_input.c:1556-1561: a SYN-ACK for something never sent --------------------

syn_sent_bad_ack_is_reset_test_() ->
    [?_assertEqual({syn_sent, [{Ack, 0, ?TH_RST, 0}]},
                   begin
                       {T, A} = input([wire(9000, Ack, ?TH_SYN bor ?TH_ACK)], syn_sent()),
                       {T#tcb.state, resets(A)}
                   end)
     || Ack <- [?ISS, ?ISS - 1, ?ISS + 2]].

syn_sent_bad_ack_with_rst_is_silent_test() ->
    {T, A} = input([wire(9000, ?ISS + 2, ?TH_RST bor ?TH_ACK)], syn_sent()),
    ?assertEqual({syn_sent, false, []}, {T#tcb.state, T#tcb.ended, A}).

%% --- syn_sent, tcp_input.c:1636-1690 and 2017-2140 --------------------------------------

synack_establishes_with_its_options_test() ->
    Opts = #tcp_opts{mss = 1460, wscale = 7, sack_permitted = true, ts = {123456, 0}},
    {T, A} = input([wire(9000, ?ISS + 1, ?TH_SYN bor ?TH_ACK, <<>>, Opts)], syn_sent()),
    ?assertEqual(established, T#tcb.state),
    ?assertEqual({9000, 9001, 9001 + 65536}, {T#tcb.irs, T#tcb.rcv_nxt, T#tcb.rcv_adv}),
    ?assertEqual({?ISS + 1, ?ISS + 1}, {T#tcb.snd_una, T#tcb.snd_nxt}),
    %% The shift asked for lets sb_max (2 MiB) be advertised.
    ?assertEqual({7, 6}, T#tcb.wscale),
    ?assertMatch(#ts{recent = 123456, recent_age = ?T0, offset = 7}, T#tcb.ts),
    ?assertEqual(on, T#tcb.sack),
    ?assertEqual(erx_tcp_loss_dupack:init(#{sack => true}), T#tcb.loss_state),
    %% step6 takes the SYN-ACK's window: snd_wl1 is the first byte after the SYN.
    ?assertEqual({1460, 1000, 9001}, {T#tcb.maxseg, T#tcb.snd_wnd, T#tcb.snd_wl1}),
    %% Buffers rounded up to whole segments of the new MSS are asked of the grant.
    ?assertEqual([{reserve_buffer, snd, 65700}, {reserve_buffer, rcv, 65700}], A),
    ?assert(T#tcb.ack_now),
    ?assertEqual(?T0 + ?S(2 * 60 * 60 * 1000), T#tcb.deadlines#deadlines.keep),
    %% cc_conn_init: ten segments of the MSS less the timestamp option.
    ?assertEqual(erx_tcp_mss:initwnd(1460 - 12), T#tcb.ccv#ccv.cwnd).

synack_without_options_negotiates_none_test() ->
    {T, []} = input([wire(9000, ?ISS + 1, ?TH_SYN bor ?TH_ACK)], syn_sent()),
    ?assertEqual({established, off, off, off, 536},
                 {T#tcb.state, T#tcb.wscale, T#tcb.ts, T#tcb.sack, T#tcb.maxseg}).

synack_after_shutdown_enters_fin_wait_1_test() ->
    {T, _} = input([wire(9000, ?ISS + 1, ?TH_SYN bor ?TH_ACK)], (syn_sent())#tcb{fin = queued}),
    ?assertEqual({fin_wait_1, queued}, {T#tcb.state, T#tcb.fin}).

synack_data_past_the_window_drops_the_fin_test() ->
    Tcb = (syn_sent())#tcb{rcv_hiwat = 4, rcv_wnd = 4},
    Flags = ?TH_SYN bor ?TH_ACK bor ?TH_FIN,
    Seg = (seg(9000, Flags, <<"abcdef">>))#seg{ack = ?ISS + 1},
    {goto, process_ack, T, Taken, []} = stage(syn_sent, Seg, Tcb),
    ?assertEqual({9001, <<"abcd">>, ?TH_SYN bor ?TH_ACK},
                 {Taken#seg.seq, Taken#seg.data, Taken#seg.flags}),
    %% The data waits for a delayed ACK (DELAY_ACK).
    ?assertEqual({established, ?T0 + ?S(40)}, {T#tcb.state, T#tcb.deadlines#deadlines.delack}).

syn_sent_rst_test_() ->
    {Refused, RefusedActions} = input([wire(0, ?ISS + 1, ?TH_RST bor ?TH_ACK)], syn_sent()),
    {Bare, []} = input([wire(0, 0, ?TH_RST)], syn_sent()),
    {NoSyn, []} = input([wire(9000, ?ISS + 1, ?TH_ACK)], syn_sent()),
    [?_assertEqual({true, econnrefused, false}, {Refused#tcb.ended, Refused#tcb.error,
                                                 Refused#tcb.reset_peer}),
     ?_assertEqual([], RefusedActions),
     ?_assertEqual({syn_sent, false}, {Bare#tcb.state, Bare#tcb.ended}),
     ?_assertEqual({syn_sent, 0}, {NoSyn#tcb.state, NoSyn#tcb.irs})].

simultaneous_open_test() ->
    Tcb = (syn_sent())#tcb{send_timer = {rexmt, ?T0 + ?S(1000)}, rxtshift = 2},
    {T, []} = input([wire(9000, 0, ?TH_SYN)], Tcb),
    Syn = (seg(9000, ?TH_SYN, <<>>))#seg{ack = 0},
    ?assertMatch({goto, step6, _, _, []}, stage(syn_sent, Syn, Tcb)),
    ?assertEqual({syn_received, 9001, ?ISS}, {T#tcb.state, T#tcb.rcv_nxt, T#tcb.snd_una}),
    ?assertEqual({true, none, 2}, {T#tcb.ack_now, T#tcb.send_timer, T#tcb.rxtshift}).

%% --- syn_sent, tcp_input.c:1969-1980: SYN-RECEIVED's ACK check ---------------------------

syn_received_ack_outside_is_reset_test_() ->
    Tcb = (est())#tcb{state = syn_received, snd_max = ?ISS + 1, snd_una = ?ISS},
    [?_assertEqual([{Ack, 0, ?TH_RST, 0}],
                   resets(element(2, input([wire(5001, Ack, ?TH_ACK)], Tcb))))
     || Ack <- [?ISS, ?ISS + 2]].

%% --- check_rst, tcp_input.c:2148-2194: RFC 5961 section 3 --------------------------------

rst_at_last_ack_sent_resets_test_() ->
    Case = fun(Tcb) ->
                   {T, A} = input([wire(Tcb#tcb.last_ack_sent, 0, ?TH_RST),
                                   wire(Tcb#tcb.last_ack_sent, 0, ?TH_ACK)], Tcb),
                   {T#tcb.ended, T#tcb.error, T#tcb.reset_peer, length(A)}
           end,
    [?_assertEqual({true, econnreset, false, 1}, Case(est())),
     ?_assertEqual({true, econnreset, false, 1}, Case(est(?WRAPPED))),
     ?_assertEqual({true, econnrefused, false, 1}, Case((est())#tcb{state = syn_received}))].

rst_in_window_draws_a_challenge_ack_test_() ->
    Case = fun(Tcb, Seq) ->
                   {T, A} = input([wire(Seq, 0, ?TH_RST)], Tcb),
                   {T#tcb.ended, challenges(A), lists:member(charge_rst, A)}
           end,
    Las = 5001,
    Ack = erx_tcp_seq:wire(Las),
    %% No RST is charged: a RST naming no connection draws nothing, so a charge would tell.
    [?_assertEqual({false, [{?ISS + 1, Ack}], false}, Case(est(), Las + 1)),
     %% The window's last number, and across the wrap.
     ?_assertEqual({false, [{?ISS + 1, Ack}], false}, Case(est(), Las + 999)),
     ?_assertEqual({false, [{?ISS + 1, 5}], false}, Case(est(?WRAPPED), ?WRAPPED + 999)),
     %% Past the window, and before last_ack_sent: dropped without a word.
     ?_assertEqual({false, [], false}, Case(est(), Las + 1000)),
     ?_assertEqual({false, [], false}, Case(est(), Las - 1)),
     ?_assertEqual({false, [], false}, Case(est(?WRAPPED), ?WRAPPED - 6))].

rst_with_the_window_closed_counts_only_at_last_ack_sent_test_() ->
    Closed = (est())#tcb{rcv_hiwat = 0},
    {Reset, _} = input([wire(5001, 0, ?TH_RST)], Closed),
    {Kept, []} = input([wire(5002, 0, ?TH_RST)], Closed),
    [?_assert(Reset#tcb.ended), ?_assertNot(Kept#tcb.ended)].

%% tcp_challenge_ack_check: five a second per connection, each SYN or ACK attempt charging
%% the RST limit.
challenge_acks_are_limited_test() ->
    Syns = [wire(5002, 0, ?TH_SYN) || _ <- lists:seq(1, 7)],
    {T, A} = input(Syns, est()),
    ?assertEqual(5, length(challenges(A))),
    ?assertEqual(7, length([charge_rst || charge_rst <- A])),
    ?assertEqual(5001, T#tcb.last_ack_sent),
    {_, Later} = erx_tcp_input:segments([hd(Syns)], T, ctx(?T0 + ?S(1001))),
    ?assertEqual(1, length(challenges(Later))).

%% A challenge ACK is sent beside output, as tcp_respond is, so it settles no ACK owed:
%% only output's sent/4 clears ack_now, as only tcp_output clears TF_ACKNOW. In one batch
%% the SYN of a simultaneous open owes its SYN-ACK, and a SYN at rcv_nxt or an in-window
%% RST after it draws a challenge ACK that must not cancel it.
challenge_ack_keeps_the_owed_synack_test_() ->
    Syn = wire(9000, 0, ?TH_SYN),
    Batch = fun(Second) -> input([Syn, Second], syn_sent()) end,
    {AfterRst, Rst} = Batch(wire(9002, 0, ?TH_RST)),
    {AfterSyn, _} = Batch(wire(9001, 0, ?TH_SYN)),
    [?_assertEqual({1, true}, {length(challenges(Rst)), AfterRst#tcb.ack_now}),
     ?_assert(AfterSyn#tcb.ack_now)].

%% ECN is read only from a segment that passed every check (departure from :1592-1595).
ecn_from_accepted_segments_only_test() ->
    Tcb = (est())#tcb{ecn = erx_tcp_ecn:syncache_socket(true)},
    Ece = ?TH_ACK bor ?TH_ECE,
    {Blind, _} = input([wire(9000, ?ISS + 1, Ece, <<"x">>, #tcp_opts{})], Tcb),
    {Valid, _} = input([wire(5001, ?ISS + 1, Ece)], Tcb),
    Ssthresh = Tcb#tcb.ccv#ccv.ssthresh,
    ?assertEqual(Ssthresh, Blind#tcb.ccv#ccv.ssthresh),
    ?assertNotEqual(Ssthresh, Valid#tcb.ccv#ccv.ssthresh).

%% --- check_syn, tcp_input.c:2196-2215: RFC 5961 section 4 --------------------------------

%% In SYN-RECEIVED, a SYN at or past rcv_nxt names another initial sequence number: it is
%% challenged, not taken with its data one byte early (RFC 9293 section 3.10.7.4); the
%% peer's own SYN again, before rcv_nxt, is still trimmed and acknowledged.
syn_in_syn_received_test() ->
    Tcb = (syn_sent())#tcb{send_timer = {rexmt, ?T0 + ?S(1000)}},
    {Rcvd, []} = input([wire(9000, 0, ?TH_SYN)], Tcb),
    {New, A} = input([wire(9001, ?ISS + 1, ?TH_SYN bor ?TH_ACK, <<"xy">>, #tcp_opts{})], Rcvd),
    ?assertEqual({syn_received, 9001, 0, [{?ISS + 1, 9001}]},
                 {New#tcb.state, New#tcb.rcv_nxt, New#tcb.rcv_buffered, challenges(A)}),
    {Again, []} = input([wire(9000, 0, ?TH_SYN)], Rcvd),
    ?assertEqual({syn_received, 9001, true}, {Again#tcb.state, Again#tcb.rcv_nxt, Again#tcb.ack_now}),
    %% The peer's SYN-ACK, at its ISS, completes the simultaneous open.
    {Est, _} = input([wire(9000, ?ISS + 1, ?TH_SYN bor ?TH_ACK)], Rcvd),
    ?assertEqual({established, 9001, ?ISS + 1}, {Est#tcb.state, Est#tcb.rcv_nxt, Est#tcb.snd_una}).

syn_when_synchronized_draws_a_challenge_ack_test() ->
    Flags = ?TH_SYN bor ?TH_ECE,
    {T, A} = input([wire(5001, 0, Flags)], est()),
    ?assertEqual({established, false, [{?ISS + 1, 5001}]},
                 {T#tcb.state, T#tcb.ended, challenges(A)}),
    %% The SYN's ECE turns nothing on.
    ?assertEqual(off, T#tcb.ecn).

%% --- timestamps and paws, tcp_input.c:1692-1729 and 2218-2245 ----------------------------

paws_test_() ->
    Ts = fun(Val) -> #tcp_opts{ts = {Val, 0}} end,
    Tcb = with_ts(est(), 500),
    Old = fun(Data, T) -> input([wire(5001, ?ISS + 1, ?TH_ACK, Data, Ts(499))], T) end,
    {WithData, []} = Old(<<"x">>, Tcb),
    {Bare, []} = Old(<<>>, Tcb),
    %% Older than 24 days: ts_recent is invalidated and the segment goes on (here to take
    %% its TSval, since it covers last_ack_sent).
    Stale = Tcb#tcb{ts = (Tcb#tcb.ts)#ts{recent_age = ?T0 - ?S(24 * 24 * 60 * 60 * 1000) - 1}},
    {Revived, []} = Old(<<>>, Stale),
    %% Across the wrap of the timestamp clock, 5 is newer than 2^32 - 16.
    {Wrapped, []} = input([wire(5001, ?ISS + 1, ?TH_ACK, <<>>, Ts(5))],
                          with_ts(est(), 16#fffffff0)),
    [?_assertEqual({true, 500}, {WithData#tcb.ack_now, WithData#tcb.ts#ts.recent}),
     ?_assertEqual({false, 500}, {Bare#tcb.ack_now, Bare#tcb.ts#ts.recent}),
     ?_assertEqual(499, Revived#tcb.ts#ts.recent),
     ?_assertEqual(5, Wrapped#tcb.ts#ts.recent)].

missing_timestamp_is_tolerated_test() ->
    {T, []} = input([wire(5001, ?ISS + 1, ?TH_ACK)], with_ts(est(), 500)),
    ?assertEqual({500, false}, {T#tcb.ts#ts.recent, T#tcb.ended}).

unexpected_timestamp_is_ignored_test() ->
    {T, [{deliver, <<"x">>}]} =
        input([wire(5001, ?ISS + 1, ?TH_ACK, <<"x">>, #tcp_opts{ts = {1, 0}})], est()),
    ?assertEqual({off, false}, {T#tcb.ts, T#tcb.ack_now}).

%% --- trim, tcp_input.c:2247-2389 --------------------------------------------------------

land_check_test() ->
    Tcb = (est())#tcb{state = syn_received},
    ?assertMatch({done, _, [{reset, _}]}, stage(trim, seg(4999, ?TH_ACK, <<>>), Tcb)).

trim_front_test_() ->
    Tcb = est(),
    {continue, _, Part} = stage(trim, seg(4998, ?TH_ACK, <<"abcdef">>), Tcb),
    {continue, _, Syn} = stage(trim, seg(4999, ?TH_SYN bor ?TH_ACK, <<"abc">>), Tcb),
    {continue, Dup, Old} = stage(trim, seg(4990, ?TH_ACK bor ?TH_FIN, <<"abc">>), Tcb),
    {continue, Upto, Fin} = stage(trim, seg(4998, ?TH_ACK bor ?TH_FIN, <<"abc">>), Tcb),
    {continue, Sack, _} = stage(trim, seg(4998, ?TH_ACK, <<"abcdef">>), Tcb#tcb{sack = on}),
    W = ?WRAPPED,
    {continue, _, Wrapped} = stage(trim, seg(W - 2, ?TH_ACK, <<"abcd">>), est(W)),
    [?_assertEqual({5001, <<"def">>}, {Part#seg.seq, Part#seg.data}),
     ?_assertEqual({5001, <<"bc">>, ?TH_ACK}, {Syn#seg.seq, Syn#seg.data, Syn#seg.flags}),
     %% Wholly old: a duplicate FIN goes and an ACK is owed.
     ?_assertEqual({4993, <<>>, ?TH_ACK, true},
                   {Old#seg.seq, Old#seg.data, Old#seg.flags, Dup#tcb.ack_now}),
     %% Old data up to rcv_nxt with a new FIN: the FIN stays, no ACK owed for the trim.
     ?_assertEqual({5001, <<>>, ?TH_ACK bor ?TH_FIN, false},
                   {Fin#seg.seq, Fin#seg.data, Fin#seg.flags, Upto#tcb.ack_now}),
     ?_assert(Sack#tcb.ack_now),
     ?_assertEqual({W, <<"cd">>}, {Wrapped#seg.seq, Wrapped#seg.data})].

trim_back_test_() ->
    Tcb = est(),
    Push = ?TH_ACK bor ?TH_PUSH bor ?TH_FIN,
    {continue, _, Cut} = stage(trim, seg(5995, Push, <<"abcdefgh">>), Tcb),
    {continue, _, Fits} = stage(trim, seg(5993, Push, <<"abcdefgh">>), Tcb),
    Edge = stage(trim, seg(6001, ?TH_ACK, <<"abc">>), Tcb),
    Closed = Tcb#tcb{rcv_wnd = 0},
    {continue, Probe, Window} = stage(trim, seg(5001, Push, <<"abc">>), Closed),
    Beyond = stage(trim, seg(5002, ?TH_ACK, <<"abc">>), Closed),
    [?_assertEqual({<<"abcdef">>, ?TH_ACK}, {Cut#seg.data, Cut#seg.flags}),
     ?_assertEqual({<<"abcdefgh">>, Push}, {Fits#seg.data, Fits#seg.flags}),
     %% Starting exactly at the window's right edge: acknowledged and dropped.
     ?_assertMatch({done, #tcb{ack_now = true}, []}, Edge),
     %% A closed window takes a segment at rcv_nxt, without its data, and owes an ACK.
     ?_assertEqual({<<>>, ?TH_ACK, true}, {Window#seg.data, Window#seg.flags, Probe#tcb.ack_now}),
     ?_assertMatch({done, #tcb{ack_now = true}, []}, Beyond)].

trim_back_runs_on_the_window_of_the_step_test() ->
    %% The receive window is at least what was advertised (tcp_input.c:1958-1961).
    {T, []} = input([wire(5001, ?ISS + 1, ?TH_ACK)], (est())#tcb{rcv_hiwat = 10,
                                                                 rcv_adv = 5001 + 300}),
    ?assertEqual(300, T#tcb.rcv_wnd).

data_after_close_resets_test() ->
    Tcb = (est())#tcb{user_closed = true},
    {T, A} = input([wire(5001, ?ISS + 1, ?TH_ACK, <<"x">>, #tcp_opts{})], Tcb),
    ?assertEqual({true, none, [{?ISS + 1, 0, ?TH_RST, 0}]}, {T#tcb.ended, T#tcb.error, resets(A)}),
    {Fin, []} = input([wire(5001, ?ISS + 1, ?TH_ACK, <<"x">>, #tcp_opts{})],
                      Tcb#tcb{state = close_wait}),
    ?assertNot(Fin#tcb.ended).

reset_carries_no_options_test() ->
    Tcb = with_ts((est())#tcb{user_closed = true}, 500),
    {_, [{reset, {Rst, _, []}}]} = input([wire(5001, 0, 0, <<"x">>, #tcp_opts{ts = {600, 0}})], Tcb),
    ?assertEqual({0, 5002, ?TH_RST bor ?TH_ACK, 0, #tcp_opts{}},
                 {Rst#tcp.seq, Rst#tcp.ack, Rst#tcp.flags, Rst#tcp.win, Rst#tcp.opts}).

ts_recent_from_a_segment_covering_last_ack_sent_test_() ->
    Covers = fun(Tcb, Seq, Data) ->
                     Opts = #tcp_opts{ts = {600, 0}},
                     {T, _} = input([wire(Seq, ?ISS + 1, ?TH_ACK, Data, Opts)], Tcb),
                     T#tcb.ts#ts.recent
             end,
    Tcb = with_ts(est(), 500),
    %% A delayed ACK pending: last_ack_sent is behind rcv_nxt.
    Delayed = Tcb#tcb{last_ack_sent = 4999},
    [?_assertEqual(600, Covers(Tcb, 5001, <<"ab">>)),
     %% Old data trimmed to rcv_nxt still covers last_ack_sent there.
     ?_assertEqual(600, Covers(Tcb, 4999, <<"ab">>)),
     %% Wholly older data trimmed to nothing ends before it.
     ?_assertEqual(500, Covers(Tcb, 4998, <<"ab">>)),
     ?_assertEqual(500, Covers(Delayed, 5001, <<"ab">>))].

%% --- check_ack, tcp_input.c:2397-2450 ---------------------------------------------------

without_ack_test_() ->
    {Dropped, []} = input([wire(5001, 0, 0, <<"x">>, #tcp_opts{})], est()),
    {Acked, []} = input([wire(4000, 0, 0, <<"x">>, #tcp_opts{})], est()),
    Kept = stage(check_ack, seg(5001, 0, <<"x">>), (est())#tcb{state = syn_received}),
    [?_assertNot(Dropped#tcb.ack_now),
     ?_assert(Acked#tcb.ack_now),
     ?_assertMatch({goto, step6, _, #seg{}, []}, Kept)].

ack_floor_test_() ->
    Check = fun(Tcb, Ack) ->
                    case stage(check_ack, (seg(5001, ?TH_ACK, <<>>))#seg{ack = Ack}, Tcb) of
                        {continue, _, _} -> pass;
                        {done, _, A} -> {challenged, length(challenges(A))}
                    end
            end,
    Young = (est())#tcb{snd_una = ?ISS + 100, max_sndwnd = 1000},
    Far = ?ISS + 16#ffff + 50000,
    Old = (est())#tcb{snd_una = Far, max_sndwnd = 20000},
    Mid = (est())#tcb{snd_una = ?ISS + 70000, max_sndwnd = 80000},
    [%% Ghost ACKs: nothing at or below the ISS was ever sent.
     ?_assertEqual({challenged, 1}, Check(Young, ?ISS)),
     ?_assertEqual(pass, Check(Young, ?ISS + 1)),
     %% Once snd_una is a maximal window past the ISS, only the too-old bound counts.
     ?_assertEqual({challenged, 1}, Check(Old, Far - 20001)),
     ?_assertEqual(pass, Check(Old, Far - 20000)),
     %% An ACK of the ISS once the too-old bound is below it is old, not challenged; the
     %% window scale widens the ISS check's reach.
     ?_assertEqual(pass, Check(Mid, ?ISS)),
     ?_assertEqual({challenged, 1}, Check(Mid#tcb{wscale = {2, 0}}, ?ISS))].

%% --- the pipeline -----------------------------------------------------------------------

segments_after_the_end_are_reinjected_test() ->
    Rst = wire(5001, 0, ?TH_RST),
    Next = wire(5001, ?ISS + 1, ?TH_ACK),
    {T, A} = input([Rst, Next], est()),
    ?assert(T#tcb.ended),
    ?assertEqual([{reinject, Next}], A).

stopping_the_retransmission_timer_keeps_the_backoff_test() ->
    Tcb = (est())#tcb{send_timer = {rexmt, ?T0}, rxtshift = 3},
    T = erx_tcp:loss_events([stop_rexmt], Tcb, ?ISS + 1, ctx()),
    ?assertEqual({none, 3}, {T#tcb.send_timer, T#tcb.rxtshift}).

time_wait_segments_are_not_taken_test() ->
    Tcb = (est())#tcb{state = time_wait},
    ?assertEqual({Tcb, []}, input([wire(5001, 0, ?TH_RST)], Tcb)).

%% tcp_input.c:3450-3451: a segment that would draw a RST draws none when its frame was
%% link broadcast or multicast.
no_reset_for_link_broadcast_test() ->
    Bad = wire(9000, ?ISS, ?TH_SYN bor ?TH_ACK),
    Resets = fun(Cast) -> resets(element(2, input([setelement(4, Bad, Cast)], syn_sent()))) end,
    ?assertMatch([_], Resets(unicast)),
    ?assertEqual({[], []}, {Resets(broadcast), Resets(multicast)}).
