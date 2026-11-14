%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A connection made from the syncache (erx_tcp_user:accepted/3, FreeBSD's syncache_socket,
%% tcp_syncache.c:894-984) and the segment that completes its handshake, stepped as
%% tcp_input steps it into the new socket in SYN-RECEIVED.
-module(erx_tcp_accepted_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
-define(ISS, 5000).
-define(IRS, 9000).
-define(TCPTV_KEEP_INIT_US, (75000 * 1000)).
-define(TCPTV_KEEP_IDLE_US, (120 * 60 * 1000 * 1000)).

ctx() -> #tcp_ctx{now = ?T0, credit = 64, mtu = 1500}.

init() ->
    #{family => inet, local => {<<10, 0, 0, 1>>, 80}, remote => {<<10, 0, 0, 2>>, 4000},
      cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
      snd_hiwat => 65536, rcv_hiwat => 65536, gen => erx_net_rand:new(<<0:128>>)}.

%% A handshake with every option negotiated, as syncache_expand returns it for an entry
%% whose one SYN-ACK was answered.
handshake() ->
    #{iss => ?ISS, irs => ?IRS, rcv_wnd => 65535, peer_mss => 1460, wscale => {7, 3},
      sack => true, ts => {1000, 77}, ecn => false, rxmits => 1, challenge => none}.

%% The same without options, as from a peer whose SYN carried none.
bare() ->
    (handshake())#{peer_mss := 0, wscale := none, sack := false, ts := none}.

accepted(Handshake) ->
    erx_tcp_user:accepted(Handshake, init(), ctx()).

%% The segment from the peer: {Tcp, Data, IpEcn, LinkCast}, as an interface hands it.
wire(Seq, Ack, Flags) -> wire(Seq, Ack, Flags, <<>>).
wire(Seq, Ack, Flags, Data) ->
    {#tcp{sport = 4000, dport = 80, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = 2000, urp = 0, opts = #tcp_opts{}}, Data, 0, unicast}.

step(Segment, Tcb) -> erx_tcp:step({segments, [Segment]}, Tcb, ctx()).

resets(Actions) ->
    [{S, A, F} || {reset, {#tcp{seq = S, ack = A, flags = F}, _, []}} <- Actions].

%% --- syncache_socket ------------------------------------------------------------------

%% tcp_syncache.c:894-905 with tcp_rcvseqinit and tcp_sendseqinit (tcp_seq.h:66-71): our SYN
%% is in flight, so snd_una is the ISS and snd_nxt and snd_max are past it, and the send log
%% holds it; the receive side starts past the peer's SYN with the window the SYN-ACK offered.
sequence_space_test() ->
    {T, _} = accepted(handshake()),
    ?assertEqual({syn_received, ?ISS, ?IRS, ?ISS, ?ISS + 1, ?ISS + 1, ?ISS, ?ISS},
                 {T#tcb.state, T#tcb.iss, T#tcb.irs, T#tcb.snd_una, T#tcb.snd_nxt,
                  T#tcb.snd_max, T#tcb.snd_up, T#tcb.snd_recover}),
    ?assertEqual({?IRS, ?IRS + 1, ?IRS + 1, 65535, ?IRS + 1 + 65535, ?IRS + 1},
                 {T#tcb.snd_wl1, T#tcb.rcv_nxt, T#tcb.rcv_up, T#tcb.rcv_wnd, T#tcb.rcv_adv,
                  T#tcb.last_ack_sent}),
    ?assertEqual({?ISS, ?ISS + 1},
                 {erx_tcp_sendlog:snd_una(T#tcb.sendlog), erx_tcp_sendlog:snd_max(T#tcb.sendlog)}),
    ?assertEqual({false, false, none}, {T#tcb.need_syn, T#tcb.ended, T#tcb.send_timer}).

%% :910-929: the options the handshake negotiated; none when the SYN carried none.
options_test_() ->
    {T, _} = accepted(handshake()),
    {B, _} = accepted(bare()),
    [?_assertEqual({{7, 3}, #ts{recent = 1000, recent_age = ?T0, offset = 77}, on},
                   {T#tcb.wscale, T#tcb.ts, T#tcb.sack}),
     ?_assertEqual({off, off, off}, {B#tcb.wscale, B#tcb.ts, B#tcb.sack}),
     ?_assertEqual(erx_tcp_loss_dupack:init(#{sack => true}), T#tcb.loss_state),
     ?_assertEqual(erx_tcp_loss_dupack:init(#{sack => false}), B#tcb.loss_state)].

%% :932, tcp_ecn_syncache_socket (tcp_ecn.c:463-486): classic ECN when the entry granted it.
ecn_test_() ->
    {On, _} = accepted((handshake())#{ecn := true}),
    {Off, _} = accepted(handshake()),
    [?_assert(erx_tcp_ecn:enabled(On#tcb.ecn)),
     ?_assertNot(erx_tcp_ecn:enabled(Off#tcb.ecn))].

%% :938, tcp_mss with the peer's MSS (0 is none, the family's default): the segment size and
%% the buffers rounded up to whole segments, asked of the grant.
mss_test_() ->
    {T, Actions} = accepted(handshake()),
    {Maxseg, Snd, Rcv} = erx_tcp_mss:mss(inet, 1460, {1500, 0}, {65536, 65536}, 2 * 1024 * 1024),
    {B, _} = accepted(bare()),
    [?_assertEqual(1460, Maxseg),
     ?_assertEqual(Maxseg, T#tcb.maxseg),
     ?_assertEqual([{reserve_buffer, snd, Snd}, {reserve_buffer, rcv, Rcv}], Actions),
     ?_assertEqual(536, B#tcb.maxseg)].

%% :945-946: a SYN-ACK sent more than once leaves one segment of congestion window
%% (cc_conn_init reads snd_cwnd 1 as that); sent once, the window is untouched.
retransmitted_synack_test_() ->
    {Once, _} = accepted(handshake()),
    {Twice, _} = accepted((handshake())#{rxmits := 2}),
    [?_assertEqual(1, (Twice#tcb.ccv)#ccv.cwnd),
     ?_assertNotEqual(1, (Once#tcb.ccv)#ccv.cwnd)].

%% :948-949: the entry's challenge-ACK window carries over, its end moved from the
%% syncache's milliseconds to the connection's microseconds.
challenge_state_test_() ->
    {T, _} = accepted((handshake())#{challenge := {2000, 3}}),
    {N, _} = accepted(handshake()),
    [?_assertEqual({2000000, 3}, T#tcb.challenge),
     ?_assertEqual(none, N#tcb.challenge)].

%% :979-984: the keepalive options copied from the listener and TT_KEEP at TP_KEEPINIT.
keep_init_test_() ->
    {T, _} = accepted(handshake()),
    {K, _} = erx_tcp_user:accepted(handshake(), (init())#{keep_init => 3000}, ctx()),
    [?_assertEqual(?T0 + ?TCPTV_KEEP_INIT_US, (T#tcb.deadlines)#deadlines.keep),
     ?_assertEqual(?T0 + 3000 * 1000, (K#tcb.deadlines)#deadlines.keep)].

%% --- The completing segment (tcp_input.c:2458-2527, :2887-2898) ----------------------

%% The ACK of our SYN establishes the connection: snd_una moves past the SYN (incforsyn),
%% the keepalive runs on its idle time, and the congestion window starts.
completing_ack_establishes_test() ->
    {T0, _} = accepted(bare()),
    {T, _} = step(wire(?IRS + 1, ?ISS + 1, ?TH_ACK), T0),
    ?assertEqual({established, ?ISS + 1, ?ISS + 1, 2000},
                 {T#tcb.state, T#tcb.snd_una, erx_tcp_sendlog:snd_una(T#tcb.sendlog), T#tcb.snd_wnd}),
    ?assertEqual(?T0 + ?TCPTV_KEEP_IDLE_US, (T#tcb.deadlines)#deadlines.keep),
    ?assertEqual(erx_tcp_mss:initwnd(536), (T#tcb.ccv)#ccv.cwnd).

%% After a retransmitted SYN-ACK, cc_conn_init starts the window at one segment.
completing_ack_after_retransmission_test() ->
    {T0, _} = accepted((bare())#{rxmits := 3}),
    {T, _} = step(wire(?IRS + 1, ?ISS + 1, ?TH_ACK), T0),
    ?assertEqual({established, 536}, {T#tcb.state, (T#tcb.ccv)#ccv.cwnd}).

%% Data on the completing ACK is taken in order and delivered.
completing_ack_with_data_test() ->
    {T0, _} = accepted(bare()),
    {T, Actions} = step(wire(?IRS + 1, ?ISS + 1, ?TH_ACK bor ?TH_PUSH, <<"hello">>), T0),
    ?assertEqual({established, ?IRS + 6}, {T#tcb.state, T#tcb.rcv_nxt}),
    ?assertEqual([<<"hello">>], [iolist_to_binary(D) || {deliver, D} <- Actions]).

%% The timestamp the handshake echoed is ts_recent: a completing ACK whose TSval is older
%% fails PAWS and is dropped with an ACK (tcp_input.c:1879-1902); a newer one completes.
completing_ack_paws_test_() ->
    {T0, _} = accepted(handshake()),
    {Old, _} = step(ts_ack(999), T0),
    {New, _} = step(ts_ack(1001), T0),
    [?_assertEqual(syn_received, Old#tcb.state),
     ?_assertEqual(established, New#tcb.state)].

%% The completing ACK with a timestamp whose echo is the TSval our SYN-ACK carried: the
%% connection's offset plus the clock in milliseconds.
ts_ack(TsVal) ->
    {Tcp, Data, Ecn, Cast} = wire(?IRS + 1, ?ISS + 1, ?TH_ACK),
    {Tcp#tcp{opts = #tcp_opts{ts = {TsVal, 77 + ?T0 div 1000}}}, Data, Ecn, Cast}.

%% The peer's window on the completing ACK is scaled by its shift, the first of the pair
%% (tcp_input.c:1584, :2479).
completing_ack_scales_window_test() ->
    {T0, _} = accepted(handshake()),
    {T, _} = step(ts_ack(1001), T0),
    ?assertEqual({established, 2000 bsl 7}, {T#tcb.state, T#tcb.snd_wnd}).

%% Initial sequence numbers at the top of the 32-bit space: the numbers past them go on
%% unwrapped, and the completing ACK, whose wire numbers have wrapped to 0, establishes.
wrapped_sequence_space_test() ->
    Top = 16#ffffffff,
    {T0, _} = accepted((bare())#{iss := Top, irs := Top}),
    ?assertEqual({Top + 1, Top + 1, Top + 1}, {T0#tcb.snd_nxt, T0#tcb.snd_max, T0#tcb.rcv_nxt}),
    {T, _} = step(wire(Top + 1, Top + 1, ?TH_ACK), T0),
    ?assertEqual({established, Top + 1}, {T#tcb.state, T#tcb.snd_una}).

%% An ACK of anything but our SYN, below it or past it, draws a RST at the acknowledged
%% number and leaves the connection waiting (tcp_input.c:1969-1980); a RST at rcv_nxt ends
%% it as refused (:2148-2194).
wrong_ack_is_reset_test_() ->
    {T0, _} = accepted(bare()),
    [?_assertEqual({syn_received, [{erx_tcp_seq:wire(Ack), 0, ?TH_RST}]},
                   begin
                       {T, A} = step(wire(?IRS + 1, Ack, ?TH_ACK), T0),
                       {T#tcb.state, resets(A)}
                   end)
     || Ack <- [?ISS, ?ISS - 1, ?ISS + 2]].

rst_ends_test() ->
    {T0, _} = accepted(bare()),
    {T, _} = step(wire(?IRS + 1, 0, ?TH_RST), T0),
    ?assertEqual({true, closed}, {T#tcb.ended, T#tcb.state}).
