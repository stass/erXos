%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_tcp_icmp, each named for the part of sys/netinet/tcp_subr.c it pins:
%% tcp_ctlinput_with_port's sequence check (RFC 5927), tcp_next_pmtu and tcp6_next_pmtu,
%% tcp_mtudisc, tcp_drop_syn_sent and tcp_notify.
-module(erx_tcp_icmp_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").
-include("erx_icmp4_wire.hrl").
-include("erx_ip6.hrl").

-define(T0, 1000000000).
-define(ISS, 1000).
-define(UNA, (?ISS + 1)).
-define(FLIGHT, 4000).

ctx() -> #tcp_ctx{now = ?T0, credit = 64, mtu = 1500}.

new(Family, Iss) ->
    Addrs = case Family of
                inet -> {<<10, 0, 0, 1>>, <<10, 0, 0, 2>>};
                inet6 -> {<<16#fd00:16, 0:96, 1:16>>, <<16#fd00:16, 0:96, 2:16>>}
            end,
    erx_tcp_user:new(#{family => Family, local => {element(1, Addrs), 4000},
                       remote => {element(2, Addrs), 80}, iss => Iss, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => 1 bsl 20, rcv_hiwat => 65536,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

%% An established connection with ?FLIGHT bytes in flight from Una, sent at an MSS of
%% `Maxseg`, windows open.
est(Family, Maxseg) -> est(Family, Maxseg, ?ISS).
est(Family, Maxseg, Iss) ->
    #tcb{ccv = Ccv} = T = new(Family, Iss),
    Una = Iss + 1,
    T#tcb{state = established, irs = 5000, rcv_nxt = 5001, rcv_adv = 5001 + 65536,
          snd_una = Una, snd_nxt = Una + ?FLIGHT, snd_max = Una + ?FLIGHT, snd_recover = Una,
          snd_wnd = 65535, max_sndwnd = 65535, maxseg = Maxseg,
          ccv = Ccv#ccv{cwnd = 10 * Maxseg, maxseg = Maxseg}, wscale = {0, 0}, ts = off,
          sack = off, rtt_probe = {Una, ?T0},
          sendlog = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(Una), Una, Una + ?FLIGHT, ?T0),
          sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(), binary:copy(<<"x">>, ?FLIGHT)),
          send_timer = {rexmt, ?T0 + 1000000}}.

syn_sent() ->
    (new(inet, ?ISS))#tcb{state = syn_sent, snd_nxt = ?UNA, snd_max = ?UNA}.

quote(Seq) ->
    #{proto => 6, len => 1500, src => <<10, 0, 0, 1>>, dst => <<10, 0, 0, 2>>,
      upper => <<4000:16, 80:16, (erx_tcp_seq:wire(Seq)):32, 0:32>>}.

quote6(Seq) ->
    #{proto => 6, src => <<16#fd00:16, 0:96, 1:16>>, dst => <<16#fd00:16, 0:96, 2:16>>,
      upper => <<4000:16, 80:16, (erx_tcp_seq:wire(Seq)):32, 0:32>>}.

%% Fragmentation needed with a proposed MTU (0 for none), quoting Seq.
needfrag(NextMtu, Seq) -> {#icmp4{type = ?ICMP_UNREACH, code = 4, msg = {error, NextMtu}}, quote(Seq)}.
too_big(Mtu, Seq) -> {#icmp6{type = ?ICMP6_PACKET_TOO_BIG, code = 0, msg = {error, Mtu}}, quote6(Seq)}.
unreach(Code, Seq) -> {#icmp4{type = ?ICMP_UNREACH, code = Code, msg = {error, 0}}, quote(Seq)}.
timxceed(Seq) -> {#icmp4{type = ?ICMP_TIMXCEED, code = 0, msg = {error, 0}}, quote(Seq)}.
paramprob(Seq) -> {#icmp4{type = ?ICMP_PARAMPROB, code = 0, msg = {error, 0}}, quote(Seq)}.

report(Report, Tcb) ->
    {Tcb1, []} = erx_tcp_icmp:report(Report, Tcb, ctx()),
    Tcb1.

maxseg(Report, Tcb) -> (report(Report, Tcb))#tcb.maxseg.

%% --- tcp_ctlinput_with_port, :3150-3151: only a quoted number in flight acts (RFC 5927) ---

sequence_in_flight_test_() ->
    T = est(inet, 1460),
    [?_assertEqual(T, report(needfrag(1280, ?UNA - 1), T)),
     ?_assertEqual(T, report(needfrag(1280, ?UNA + ?FLIGHT), T)),
     ?_assertEqual(1240, maxseg(needfrag(1280, ?UNA), T)),
     ?_assertEqual(1240, maxseg(needfrag(1280, ?UNA + ?FLIGHT - 1), T)),
     %% The same edges across the 32-bit wrap.
     ?_test(begin
                W = est(inet, 1460, 16#ffffffff - 100),
                Una = W#tcb.snd_una,
                ?assertEqual(W, report(needfrag(1280, Una - 1), W)),
                ?assertEqual(W, report(needfrag(1280, Una + ?FLIGHT), W)),
                ?assertEqual(1240, maxseg(needfrag(1280, Una + ?FLIGHT - 1), W))
            end)].

%% Nothing is in flight in TIME-WAIT or once everything is acknowledged, so no report acts.
nothing_in_flight_test() ->
    T = (est(inet, 1460))#tcb{state = time_wait, snd_una = ?UNA + ?FLIGHT},
    ?assertEqual(T, report(needfrag(1280, ?UNA + ?FLIGHT), T)),
    ?assertEqual(T, report(unreach(3, ?UNA + ?FLIGHT), T)).

ignored_reports_test_() ->
    T = est(inet, 1460),
    Short = {#icmp4{type = ?ICMP_UNREACH, code = 4, msg = {error, 1280}},
             (quote(?UNA))#{upper := <<4000:16, 80:16, 0:16>>}},
    [%% An ICMP type icmp_errmap maps to nothing.
     ?_assertEqual(T, report({#icmp4{type = ?ICMP_TIMXCEED, code = 1, msg = {error, 0}},
                              quote(?UNA)}, T)),
     %% A quote without the sequence number.
     ?_assertEqual(T, report(Short, T))].

%% --- :3152-3168 and tcp_next_pmtu, :3077-3089: the MTU only goes down ------------------

mtu_decreases_only_test_() ->
    T = est(inet, 1460),
    [?_assertEqual(T, report(needfrag(1500, ?UNA), T)),
     ?_assertEqual(T, report(needfrag(9000, ?UNA), T)),
     ?_assertEqual(1459, maxseg(needfrag(1499, ?UNA), T)),
     %% Below an MSS the peer already made small, a larger MTU changes nothing.
     ?_test(begin
                S = est(inet, 500),
                ?assertEqual(S, report(needfrag(1000, ?UNA), S))
            end)].

absurd_mtus_are_raised_test_() ->
    T = est(inet, 1460),
    [%% Below tcp_minmss with its headers, 256 bytes.
     ?_assertEqual(216, maxseg(needfrag(68, ?UNA), T)),
     ?_assertEqual(216, maxseg(needfrag(1, ?UNA), T)),
     %% No proposal: the plateau below the quoted length (1500 -> 1492).
     ?_assertEqual(1452, maxseg(needfrag(0, ?UNA), T)),
     ?_test(begin
                {I, Q} = needfrag(0, ?UNA),
                ?assertEqual(216, maxseg({I, Q#{len := 0}}, T))
            end),
     %% tcp6_next_pmtu: never below IPV6_MMTU, 1,280.
     ?_assertEqual(1220, maxseg(too_big(500, ?UNA), est(inet6, 1440))),
     ?_assertEqual(1240, maxseg(too_big(1300, ?UNA), est(inet6, 1440))),
     ?_test(begin
                S = est(inet6, 1440),
                ?assertEqual(S, report(too_big(1500, ?UNA), S))
            end)].

%% --- tcp_mtudisc, :3594-3651: the flight is resent from snd_una at the new size ------------

mtudisc_rewinds_test() ->
    T = report(needfrag(1280, ?UNA + 10), (est(inet, 1460))#tcb{sack = on}),
    ?assertEqual(1240, T#tcb.maxseg),
    ?assertEqual(?UNA, T#tcb.snd_nxt),
    ?assertEqual(?UNA + ?FLIGHT, T#tcb.snd_recover),
    ?assertEqual(none, T#tcb.rtt_probe),
    ?assertEqual(0, erx_tcp_sendlog:pipe(T#tcb.sendlog)).

mtudisc_output_resends_from_snd_una_test() ->
    {T, Actions} = erx_tcp:step({icmp, needfrag(1280, ?UNA)}, est(inet, 1460), ctx()),
    [Out] = [O || {transmit, O} <- Actions],
    {#tcp{seq = First}, _, _} = hd(Out),
    ?assertEqual(erx_tcp_seq:wire(?UNA), First),
    ?assert(lists:all(fun({_, _, P}) -> iolist_size(P) =< 1240 end, Out)),
    ?assertEqual(established, T#tcb.state).

mtudisc_send_buffer_caps_the_mss_test() ->
    T = (est(inet, 1460))#tcb{snd_hiwat = 1000},
    ?assertEqual(1000, maxseg(needfrag(1280, ?UNA), T)).

%% --- tcp_drop_syn_sent, :3559-3585: only a handshake in SYN-SENT ends ----------------------

drop_syn_sent_test_() ->
    Ends = fun(Report, Error) ->
                   {T, Actions} = erx_tcp:step({icmp, Report}, syn_sent(), ctx()),
                   ?assert(T#tcb.ended),
                   ?assertEqual(Error, T#tcb.error),
                   ?assertEqual([], [R || {reset, _} = R <- Actions]),
                   ?assertEqual(finish, lists:last(Actions))
           end,
    [?_test(Ends(unreach(3, ?ISS), econnrefused)),          % port unreachable
     ?_test(Ends(unreach(13, ?ISS), econnrefused)),         % administratively prohibited
     ?_test(Ends(timxceed(?ISS), ehostunreach)),
     %% A port unreachable for an established connection is ignored altogether.
     ?_test(begin
                E = est(inet, 1460),
                ?assertEqual(E, report(unreach(3, ?UNA), E))
            end),
     %% Quoting anything but the ISS, nothing happens.
     ?_assertEqual(syn_sent(), report(unreach(3, ?ISS + 1), syn_sent()))].

%% --- tcp_notify, :2580-2620: soft errors ------------------------------------------------------

soft_errors_test_() ->
    E = est(inet, 1460),
    S = syn_sent(),
    [%% Established ignores a host or net unreachable.
     ?_assertEqual(E, report(unreach(1, ?UNA), E)),
     ?_assertEqual(none, (report(unreach(0, ?UNA), E))#tcb.soft_error),
     %% Other errors are kept for the timeout to report.
     ?_assertEqual(enoprotoopt, (report(paramprob(?UNA), E))#tcb.soft_error),
     ?_assertEqual(ehostunreach,
                   (report(unreach(1, ?UNA), E#tcb{state = close_wait}))#tcb.soft_error),
     %% A handshake keeps it until it has timed out more than three times with one kept.
     ?_assertEqual(ehostunreach, (report(unreach(1, ?ISS), S))#tcb.soft_error),
     ?_assertNot((report(unreach(1, ?ISS), S#tcb{rxtshift = 3, soft_error = ehostunreach}))#tcb.ended),
     ?_assertNot((report(unreach(1, ?ISS), S#tcb{rxtshift = 4}))#tcb.ended),
     ?_test(begin
                T = report(unreach(1, ?ISS), S#tcb{rxtshift = 4, soft_error = ehostunreach}),
                ?assert(T#tcb.ended),
                ?assertEqual(ehostunreach, T#tcb.error)
            end)].

%% erx_tcp_mss:mtudisc/5: the MSS never grows, even with no route, where tcp_mss_update falls
%% back to the family's default (536), above an MSS of 300.
mss_never_grows_test_() ->
    [?_assertEqual({lower, 300}, erx_tcp_mss:mtudisc(inet, 300, 0, 300, 1 bsl 20)),
     ?_assertEqual({lower, 260}, erx_tcp_mss:mtudisc(inet, 300, 1500, 300, 1 bsl 20)),
     ?_assertEqual(keep, erx_tcp_mss:mtudisc(inet, 340, 1500, 300, 1 bsl 20)),
     %% A tiny send buffer caps it, at no less than 64 bytes.
     ?_assertEqual({lower, 64}, erx_tcp_mss:mtudisc(inet, 1000, 1500, 1460, 10))].

%% tcp_mtudisc's tfb_tcp_mtu_chg: a smaller MTU sends the flight again through the loss
%% module's rewind callback (erx_tcp:rewind/3).
mtudisc_rewinds_through_the_loss_module_test() ->
    T = (est(inet6, 1440))#tcb{loss = erx_tcp_loss_spy, loss_state = erx_tcp_loss_spy:init(#{sack => false})},
    T1 = report(too_big(1300, ?UNA), T),
    ?assertEqual({?UNA, [mtu]}, {T1#tcb.snd_nxt, erx_tcp_loss_spy:causes(T1#tcb.loss_state)}).
