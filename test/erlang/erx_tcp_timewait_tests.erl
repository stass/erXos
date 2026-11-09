%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_tcp_timewait, each named for the part of sys/netinet/tcp_timewait.c it
%% pins: tcp_twstart with tcp_eff_msl, and tcp_twcheck's RFC 1337, RFC 6191, duplicate-FIN
%% and acknowledgement rules, reached through erx_tcp_input:segments/3 and erx_tcp:step/3.
-module(erx_tcp_timewait_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
-define(S(Ms), ((Ms) * 1000)).
-define(ISS, 1000).
-define(RCV, 5001).
-define(SND, (?ISS + 2)).

ctx() -> #tcp_ctx{now = ?T0, credit = 64, mtu = 1500}.

new() ->
    erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                       remote => {<<10, 0, 0, 2>>, 80}, iss => ?ISS, ts_offset => 7,
                       cc => erx_tcp_cc_newreno, loss => erx_tcp_loss_dupack,
                       snd_hiwat => 65536, rcv_hiwat => 65536,
                       gen => erx_net_rand:new(<<0:128>>), now => ?T0}).

%% A connection in TIME-WAIT: both FINs taken and acknowledged, 2MSL armed from T0.
tw() ->
    erx_tcp_timewait:start(
      (new())#tcb{state = fin_wait_2, irs = ?RCV - 2, rcv_nxt = ?RCV, rcv_adv = ?RCV,
                  last_ack_sent = ?RCV, rcv_wnd = 1000, snd_una = ?SND, snd_nxt = ?SND,
                  snd_max = ?SND, wscale = {0, 0}, ts = off, sack = off, rcv_closed = true,
                  snd_closed = true, sendlog = erx_tcp_sendlog:new(?SND)}, ctx()).

with_ts(Tcb, Recent) -> Tcb#tcb{ts = #ts{recent = Recent, recent_age = ?T0, offset = 7}}.

wire(Seq, Ack, Flags) -> wire(Seq, Ack, Flags, <<>>, #tcp_opts{}).
wire(Seq, Ack, Flags, Data, Opts) ->
    {#tcp{sport = 80, dport = 4000, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = Flags, win = 1000, urp = 0, opts = Opts}, Data, 0}.
syn(Seq) -> wire(Seq, 0, ?TH_SYN).
syn_ts(Seq, Val) -> wire(Seq, 0, ?TH_SYN, <<>>, #tcp_opts{ts = {Val, 0}}).

input(Segments, Tcb) -> erx_tcp_input:segments(Segments, Tcb, ctx()).

acks(Actions) ->
    [{S, A} || {transmit, [{#tcp{seq = S, ack = A, flags = ?TH_ACK}, _, []}]} <- Actions].

%% --- tcp_twstart, :148-186, with tcp_eff_msl ----------------------------------------------

start_arms_2msl_test_() ->
    [?_assertEqual(?T0 + ?S(60000), ((tw())#tcb.deadlines)#deadlines.msl2),
     ?_assertEqual(none, (tw())#tcb.send_timer),
     ?_assertEqual(?T0 + ?S(20),
                   ((erx_tcp_timewait:start((tw())#tcb{local_peer = true}, ctx()))
                        #tcb.deadlines)#deadlines.msl2)].

%% FIN in FIN-WAIT-2 enters TIME-WAIT through start/2.
fin_enters_time_wait_test() ->
    T0 = (tw())#tcb{state = fin_wait_2, rcv_nxt = ?RCV - 1, local_peer = true,
                    deadlines = #deadlines{}},
    {T, _} = input([wire(?RCV - 1, ?SND, ?TH_FIN bor ?TH_ACK)], T0),
    ?assertEqual(time_wait, T#tcb.state),
    ?assertEqual(?T0 + ?S(20), (T#tcb.deadlines)#deadlines.msl2).

%% --- tcp_twcheck, :233-234: no RST ends TIME-WAIT (RFC 1337) -------------------------------

rst_is_dropped_test_() ->
    T = tw(),
    [?_assertEqual({T, []}, input([wire(?RCV, 0, ?TH_RST)], T)),
     ?_assertEqual({T, []}, input([wire(?RCV, ?SND, ?TH_RST bor ?TH_ACK)], T)),
     ?_test(begin
                {T1, Actions} = erx_tcp:step({segments, [wire(?RCV, ?SND, ?TH_RST)]}, T, ctx()),
                ?assertEqual(time_wait, T1#tcb.state),
                ?assertNot(T1#tcb.ended),
                ?assertNot(lists:member(finish, Actions))
            end)].

%% --- :262-287: a new SYN reuses the four-tuple as RFC 6191 allows ---------------------------

recycled(Segment, Tcb) ->
    {T, Actions} = input([Segment], Tcb),
    T#tcb.ended andalso Actions =:= [{reinject, Segment}].

dropped(Segment, Tcb) -> input([Segment], Tcb) =:= {Tcb, []}.

syn_past_rcv_nxt_recycles_test_() ->
    T = tw(),
    [?_assert(recycled(syn(?RCV + 1), T)),
     ?_assert(dropped(syn(?RCV), T)),
     ?_assert(dropped(syn(?RCV - 100), T)),
     %% Across the 32-bit wrap.
     ?_assert(recycled(syn(16#100000000 + 3), T#tcb{rcv_nxt = 16#100000000 - 3})),
     ?_assert(dropped(syn(16#100000000 - 4), T#tcb{rcv_nxt = 16#100000000 - 3}))].

syn_with_newer_timestamp_recycles_test_() ->
    T = with_ts(tw(), 500),
    [?_assert(recycled(syn_ts(?RCV - 100, 501), T)),
     ?_assert(dropped(syn_ts(?RCV - 100, 500), T)),
     ?_assert(dropped(syn_ts(?RCV - 100, 499), T)),
     %% Without its timestamp the sequence rule alone decides.
     ?_assert(dropped(syn(?RCV - 100), T)),
     ?_assert(recycled(syn(?RCV + 1), T)),
     %% Timestamps wrap too.
     ?_assert(recycled(syn_ts(?RCV - 100, 5), with_ts(tw(), 16#fffffff0))),
     %% A timestamp on a SYN to a connection that negotiated none is no reason: missing
     %% timestamps are tolerated.
     ?_assert(dropped(syn_ts(?RCV - 100, 501), tw()))].

%% The rest of the batch follows the recycled SYN back to the interface.
recycle_reinjects_the_rest_test() ->
    Syn = syn(?RCV + 10),
    Ack = wire(?RCV + 11, 0, ?TH_ACK),
    {T, Actions} = input([Syn, Ack], tw()),
    ?assert(T#tcb.ended),
    ?assertEqual([{reinject, Syn}, {reinject, Ack}], Actions).

%% The step closes it without a RST and finishes.
recycle_through_the_step_test() ->
    Syn = syn(?RCV + 10),
    {_, Actions} = erx_tcp:step({segments, [Syn]}, tw(), ctx()),
    ?assertEqual({reinject, Syn}, hd(Actions)),
    ?assertEqual([], [R || {reset, _} = R <- Actions]),
    ?assertEqual(finish, lists:last(Actions)).

%% SYN with ACK is no new connection: acknowledged as any other segment.
syn_ack_is_acknowledged_test() ->
    ?assertEqual([{erx_tcp_seq:wire(?SND), erx_tcp_seq:wire(?RCV)}],
                 acks(element(2, input([wire(?RCV + 10, ?SND, ?TH_SYN bor ?TH_ACK)], tw())))).

%% --- :318-347: no ACK is dropped; a retransmitted FIN restarts 2MSL; ACK what is new ------

without_ack_is_dropped_test_() ->
    T = tw(),
    [?_assert(dropped(wire(?RCV - 1, 0, ?TH_FIN), T)),
     ?_assert(dropped(wire(?RCV, 0, 0, <<"data">>, #tcp_opts{}), T))].

retransmitted_fin_test() ->
    Later = (ctx())#tcp_ctx{now = ?T0 + ?S(30000)},
    {T, Actions} = erx_tcp_input:segments([wire(?RCV - 1, ?SND, ?TH_FIN bor ?TH_ACK)], tw(),
                                          Later),
    ?assertEqual(?T0 + ?S(90000), (T#tcb.deadlines)#deadlines.msl2),
    ?assertEqual([{erx_tcp_seq:wire(?SND), erx_tcp_seq:wire(?RCV)}], acks(Actions)).

other_fin_keeps_the_deadline_test() ->
    T0 = tw(),
    {T, Actions} = input([wire(?RCV - 10, ?SND, ?TH_FIN bor ?TH_ACK)], T0),
    ?assertEqual(T0#tcb.deadlines, T#tcb.deadlines),
    ?assertEqual(1, length(acks(Actions))).

acknowledgement_test_() ->
    T = tw(),
    Acked = fun(Segment) -> acks(element(2, input([Segment], T))) end,
    Ours = [{erx_tcp_seq:wire(?SND), erx_tcp_seq:wire(?RCV)}],
    [%% A bare duplicate ACK draws nothing.
     ?_assertEqual([], Acked(wire(?RCV, ?SND, ?TH_ACK))),
     ?_assertEqual(Ours, Acked(wire(?RCV, ?SND, ?TH_ACK, <<"x">>, #tcp_opts{}))),
     ?_assertEqual(Ours, Acked(wire(?RCV + 5, ?SND, ?TH_ACK))),
     ?_assertEqual(Ours, Acked(wire(?RCV, ?SND - 1, ?TH_ACK))),
     ?_assertEqual(time_wait, (element(1, input([wire(?RCV + 5, ?SND, ?TH_ACK)], T)))#tcb.state)].
