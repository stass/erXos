%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% A merged segment in TCP (docs/design-network-fastpath.md, "A merged segment in TCP", and
%% its test 5): the same bytes stepped through erx_tcp:step/3 as one merged segment and as
%% its members one by one leave the connection where FreeBSD's LRO leaves it against
%% per-segment input. The units are made as erx_bytes:tcp_merge/1 makes them: in order,
%% acknowledgements that do not go back, no pure ACK that does not advance, and the header
%% erx_tcp:merged/3 builds from the first and last members.

-module(erx_tcp_merged_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp.hrl").
-include("erx_tcp_wire.hrl").

-define(T0, 1000000000).
%% Our ISS and the peer's next byte, a little below 2^32, so a unit wraps the wire.
-define(ISS, (16#100000000 - 3000)).
-define(RCV, (16#100000000 - 100)).
-define(UNA, (?ISS + 1)).
-define(MSS, 1000).
%% What we have sent and the peer has not acknowledged, and the window we hold.
-define(OUT, 60000).
-define(WND, 55000).

ctx() -> #tcp_ctx{now = ?T0, credit = 64, mtu = 1500, loopback = false}.

%% An established connection with ?OUT bytes outstanding, a send window of ?WND bytes and
%% room to receive 64 KiB, in slow start.
est() ->
    New = erx_tcp_user:new(#{family => inet, local => {<<10, 0, 0, 1>>, 4000},
                             remote => {<<10, 0, 0, 2>>, 80}, iss => erx_tcp_seq:wire(?ISS),
                             ts_offset => 0, cc => erx_tcp_cc_newreno,
                             loss => erx_tcp_loss_dupack, snd_hiwat => 65536,
                             rcv_hiwat => 65536, gen => erx_net_rand:new(<<0:128>>),
                             now => ?T0}),
    Log = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(?UNA), ?UNA, ?UNA + ?OUT, ?MSS, ?T0 - 50000),
    New#tcb{state = established, irs = ?RCV - 1, rcv_nxt = ?RCV, rcv_adv = ?RCV + 65536,
            rcv_up = ?RCV, last_ack_sent = ?RCV, rcv_hiwat = 65536, rcv_wnd = 65536,
            iss = ?ISS, snd_una = ?UNA, snd_nxt = ?UNA + ?OUT, snd_max = ?UNA + ?OUT,
            snd_wl1 = ?RCV, snd_wl2 = ?UNA, snd_wnd = ?WND, max_sndwnd = ?WND,
            snd_recover = ?UNA, wscale = {0, 0}, ts = off, sack = off, maxseg = ?MSS,
            sendlog = Log, send_timer = {rexmt, ?T0 + 1000000},
            ccv = (New#tcb.ccv)#ccv{cwnd = 10 * ?MSS},
            sndbuf = erx_tcp_sndbuf:append(erx_tcp_sndbuf:new(), binary:copy(<<"d">>, ?OUT))}.

%% A member as the interface hands a frame on: its header and payload. A payload is cut
%% from a larger binary, as a frame's payload is a sub-binary of its frame.
member(Seq, Ack, Win, Data) ->
    Frame = <<0:54/unit:8, Data/binary>>,
    {#tcp{sport = 80, dport = 4000, seq = erx_tcp_seq:wire(Seq), ack = erx_tcp_seq:wire(Ack),
          flags = ?TH_ACK, win = Win, urp = 0, opts = #tcp_opts{}},
     binary:part(Frame, 54, byte_size(Data)), 0, unicast}.

%% Members from {Len, AckAdvance, Win} triples: contiguous from rcv_nxt, each ACK the one
%% before it moved by its advance.
members(Specs) ->
    {Members, _, _} = lists:foldl(fun({Len, Adv, Win}, {Acc, Seq, Ack0}) ->
                                          Ack = Ack0 + Adv,
                                          Data = binary:copy(<<(Len rem 251)>>, Len),
                                          {[member(Seq, Ack, Win, Data) | Acc], Seq + Len, Ack}
                                  end, {[], ?RCV, ?UNA}, Specs),
    lists:reverse(Members).

%% The members as the one segment the interface hands on for their unit.
merge(Members) ->
    Pieces = [Data || {_, Data, _, _} <- Members, Data =/= <<>>],
    erx_tcp:merged(hd(Members), lists:last(Members), {length(Members), Pieces}).

%% The connection after stepping Segments as one event, with the bytes it delivered and the
%% acknowledgement numbers of the segments it sent.
step(Segments) ->
    {Tcb, Actions} = erx_tcp:step({segments, Segments}, est(), ctx()),
    Delivered = iolist_to_binary([Data || {deliver, Data} <- Actions]),
    Acks = [Ack || {transmit, Out} <- Actions, {#tcp{ack = Ack}, _, _} <- Out],
    {Tcb, Delivered, Acks}.

%% The facts of test 5 for one unit, as a list of mismatches, empty when it holds.
compare(Specs) ->
    Members = members(Specs),
    {Single, SingleBytes, SingleAcks} = step(Members),
    {Merged, MergedBytes, MergedAcks} = step([merge(Members)]),
    {LastTh, _, _, _} = lists:last(Members),
    Len = lists:sum([L || {L, _, _} <- Specs]),
    %% The one case the design states: a unit at snd_wl1 whose acknowledgement stays at
    %% snd_wl2 takes the last window only if it grew.
    OldWindow = lists:all(fun({_, Adv, _}) -> Adv =:= 0 end, Specs)
        andalso LastTh#tcp.win =< ?WND,
    Expect = [{delivered, SingleBytes, MergedBytes},
              {rcv_nxt, Single#tcb.rcv_nxt, Merged#tcb.rcv_nxt},
              {snd_una, Single#tcb.snd_una, Merged#tcb.snd_una},
              {snd_wl2, Single#tcb.snd_wl2, Merged#tcb.snd_wl2},
              {sendlog, log(Single), log(Merged)},
              {snd_wnd, case OldWindow of
                            true -> ?WND;
                            false -> Single#tcb.snd_wnd
                        end, Merged#tcb.snd_wnd},
              {snd_wl1, ?RCV, Merged#tcb.snd_wl1},
              {acked_now, Len =< ?MSS orelse MergedAcks =/= [], true},
              {last_ack, case MergedAcks of
                             [] -> none;
                             _ -> lists:last(SingleAcks)
                         end, case MergedAcks of
                                  [] -> none;
                                  _ -> lists:last(MergedAcks)
                              end},
              {cwnd_within_a_segment,
               abs((Single#tcb.ccv)#ccv.cwnd - (Merged#tcb.ccv)#ccv.cwnd) =< ?MSS, true}],
    [{Fact, Want, Got} || {Fact, Want, Got} <- Expect, Want =/= Got].

%% The send log as a value: its ranges, a gb_tree whose shape follows its history of
%% updates, as a list.
log(#tcb{sendlog = Log}) -> setelement(6, Log, gb_trees:to_list(element(6, Log))).

%% A unit as the merge could make it: 2 to 12 members, each a full or short data segment or
%% a pure ACK that advances, ACKs moving by at most two segments as a delayed-ACK receiver's
%% do, and windows on either side of the one held. One unit in four keeps every ACK at
%% snd_una, the window's special case.
unit() ->
    Still = rand:uniform(4) =:= 1,
    Specs = [spec(Still) || _ <- lists:seq(1, 1 + rand:uniform(11))],
    fix_first(Specs, Still).

spec(true) ->
    {data_len(), 0, window()};
spec(false) ->
    case rand:uniform(4) of
        1 -> {0, rand:uniform(2 * ?MSS), window()};
        _ -> {data_len(), rand:uniform(2 * ?MSS + 1) - 1, window()}
    end.

data_len() ->
    case rand:uniform(3) of
        1 -> rand:uniform(?MSS);
        _ -> ?MSS
    end.

window() -> ?WND - 5000 + rand:uniform(10000).

%% The merge takes a pure ACK as a unit's first frame only when the next member moves the
%% ACK past it, and a unit of pure ACKs only when the first also advances.
fix_first([{0, Adv, Win}, {Len, 0, Win2} | Rest], _) ->
    [{0, Adv, Win}, {Len, 1, Win2} | Rest];
fix_first(Specs, _) ->
    Specs.

merged_input_equals_per_segment_input_test() ->
    rand:seed(exsss, {7, 5, 13}),
    Failures = [{Specs, Diff} || Specs <- [unit() || _ <- lists:seq(1, 300)],
                                 Diff <- [compare(Specs)], Diff =/= []],
    ?assertEqual([], lists:sublist(Failures, 3)).

%% Slow start counts each merged ACK (tcp_input.c:2988 hands cc_ack_received lro_nsegs):
%% four ACKs of two segments each grow the window by eight segments, merged or not.
merged_acks_grow_the_window_as_separate_acks_test() ->
    Specs = [{0, 2 * ?MSS, ?WND} || _ <- lists:seq(1, 4)],
    ?assertEqual([], compare(Specs)),
    {Merged, _, _} = step([merge(members(Specs))]),
    ?assertEqual((est())#tcb.ccv#ccv.cwnd + 8 * ?MSS, (Merged#tcb.ccv)#ccv.cwnd).

%% The window is the last member's, which acknowledges the most.
merged_window_is_the_last_members_test() ->
    Specs = [{?MSS, ?MSS, ?WND - 4000}, {?MSS, ?MSS, ?WND - 2000}, {?MSS, ?MSS, ?WND + 3000}],
    ?assertEqual([], compare(Specs)),
    {Merged, _, _} = step([merge(members(Specs))]),
    ?assertEqual(?WND + 3000, Merged#tcb.snd_wnd).

%% A unit at snd_wl1 and snd_wl2 whose window shrinks keeps the old one, as under FreeBSD's
%% LRO; per segment the second member would take it.
merged_unit_at_wl1_keeps_a_shrunk_window_test() ->
    Specs = [{?MSS, 0, ?WND + 1000}, {?MSS, 0, ?WND - 1000}],
    ?assertEqual([], compare(Specs)),
    {Single, _, _} = step(members(Specs)),
    {Merged, _, _} = step([merge(members(Specs))]),
    ?assertEqual({?WND - 1000, ?WND}, {Single#tcb.snd_wnd, Merged#tcb.snd_wnd}).

%% A merged data segment is longer than the MSS, so DELAY_ACK (tcp_input.c:511) lets it go
%% at once: one ACK, for the whole unit.
merged_data_is_acknowledged_at_once_test() ->
    Specs = [{?MSS, 0, ?WND} || _ <- lists:seq(1, 5)],
    {_, Bytes, Acks} = step([merge(members(Specs))]),
    ?assertEqual(5 * ?MSS, byte_size(Bytes)),
    ?assertEqual([erx_tcp_seq:wire(?RCV + 5 * ?MSS)], Acks).

%% Out of order, a merged segment waits in the reassembly queue piece by piece, and the
%% segment that fills the hole delivers it.
merged_segment_out_of_order_is_reassembled_test() ->
    [Hole | Later] = members([{?MSS, 0, ?WND} || _ <- lists:seq(1, 4)]),
    Unit = merge(Later),
    {T1, A1} = erx_tcp:step({segments, [Unit]}, est(), ctx()),
    ?assertEqual([], [D || {deliver, D} <- A1]),
    {T2, A2} = erx_tcp:step({segments, [Hole]}, T1, ctx()),
    ?assertEqual(4 * ?MSS, iolist_size([D || {deliver, D} <- A2])),
    ?assertEqual(?RCV + 4 * ?MSS, T2#tcb.rcv_nxt).

%% A peer's tiny segments in large frames pin no more than their bytes: the reassembly queue
%% copies each small piece of a merged segment out of its frame and charges it its own size,
%% and keeps a piece that fills most of its frame, charged the whole frame.
merged_pieces_in_reassembly_cost_what_they_keep_alive_test() ->
    Piece = fun(Len) -> binary:part(<<0:54/unit:8, (binary:copy(<<1>>, Len))/binary>>, 54, Len) end,
    Ctx = #{established => true, room => 65536, hiwat => 65536, mss => ?MSS},
    Tiny = [Piece(1) || _ <- lists:seq(1, 40)],
    {queued, Q1} = erx_tcp_reass:insert(erx_tcp_reass:new(),
                                        #{seq => 10, data => Tiny, fin => false}, 0, Ctx),
    #{bytes := TinyCost, ranges := [{10, 50}]} = erx_tcp_reass:held(Q1),
    Full = [Piece(1448) || _ <- lists:seq(1, 3)],
    {queued, Q2} = erx_tcp_reass:insert(erx_tcp_reass:new(),
                                        #{seq => 10, data => Full, fin => false}, 0, Ctx),
    #{bytes := FullCost} = erx_tcp_reass:held(Q2),
    ?assertEqual({40 * (1 + 256), 3 * (1448 + 54 + 256)}, {TinyCost, FullCost}),
    {delivered, Data, 50, false, _} = erx_tcp_reass:present(Q1, 10),
    ?assertEqual([1], lists:usort([binary:referenced_byte_size(D) || D <- Data])).

%% Timestamps are the last member's, as FreeBSD's LRO stores them: ts_recent takes the last
%% TSval and the ACK echoes it. One by one, only the member at last_ack_sent updates
%% ts_recent (tcp_input.c:2385-2389), since no ACK goes out between them.
merged_timestamps_are_the_last_members_test() ->
    Tcb = (est())#tcb{ts = #ts{recent = 500, recent_age = ?T0, offset = 0}},
    Stamp = fun({I, {Th, Data, Ecn, Cast}}) ->
                    {Th#tcp{opts = #tcp_opts{ts = {600 + I, ?T0 div 1000 - 20 + I}}}, Data, Ecn, Cast}
            end,
    Plain = members([{?MSS, ?MSS, ?WND} || _ <- lists:seq(1, 4)]),
    Members = lists:map(Stamp, lists:enumerate(Plain)),
    Echo = fun(Actions) -> [Ecr || {transmit, Out} <- Actions,
                                   {#tcp{opts = #tcp_opts{ts = {_, Ecr}}}, _, _} <- Out] end,
    {Single, SingleActions} = erx_tcp:step({segments, Members}, Tcb, ctx()),
    {Merged, MergedActions} = erx_tcp:step({segments, [merge(Members)]}, Tcb, ctx()),
    ?assertEqual({601, 604}, {(Single#tcb.ts)#ts.recent, (Merged#tcb.ts)#ts.recent}),
    ?assertEqual({[601], [604]}, {Echo(SingleActions), Echo(MergedActions)}).
