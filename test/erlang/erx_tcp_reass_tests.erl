%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The TCP reassembly queue (erx_tcp_reass) against a model that records
%% every received byte position (docs/design-network-stack.md, "Reassembly
%% and buffers: properties against a byte map"), and the cases the model does
%% not reach: which bytes win an overlap, the caps, the FIN rules and data
%% queued before ESTABLISHED.
-module(erx_tcp_reass_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ROUNDS, 300).
%% Room and cap large enough that the property never drops a segment, and
%% small ones that it often does.
-define(OPEN, #{established => true, room => 1 bsl 30, hiwat => 1 bsl 20, mss => 1}).
-define(TIGHT, #{established => true, room => 2000, hiwat => 3, mss => 1}).

%% Over random arrivals cut from one stream, overlapping, duplicate and out
%% of order, some carried in frames much larger than themselves: the bytes
%% delivered are the stream's prefix up to the model's rcv_nxt, the ranges
%% are the model's runs of bytes held above it, the FIN is delivered once,
%% at the end, and the bytes the queue counts fall to zero once it is empty.
%% With small caps, segments are dropped only for room or the cap, the held
%% bytes never exceed the room nor the ranges the cap, and the segment at
%% rcv_nxt still passes, so the stream completes.
matches_byte_map_test() ->
    [property(Seed, ?OPEN) || Seed <- lists:seq(1, ?ROUNDS)],
    ok.

held_within_caps_test() ->
    [property(Seed, ?TIGHT) || Seed <- lists:seq(1, ?ROUNDS)],
    ok.

property(Seed, Ctx) ->
    _ = rand:seed(exsss, {Seed, 16#7c, 16#9a}),
    Base = rand:uniform(1 bsl 40),
    Stream = rand:bytes(1 + rand:uniform(2000)),
    Arrivals = arrivals(byte_size(Stream)),
    Final = lists:foldl(fun(Arrival, State) -> arrive(Arrival, State, Base, Stream) end,
                        #{q => erx_tcp_reass:new(), rcv_nxt => Base, out => [], fin => false,
                          have => #{}, ctx => Ctx},
                        Arrivals ++ [{0, byte_size(Stream)}]),
    #{rcv_nxt := RcvNxt, out := Out, fin := Fin, q := Q} = Final,
    ?assertEqual(Base + byte_size(Stream), RcvNxt),
    ?assertEqual(Stream, iolist_to_binary(lists:reverse(Out))),
    ?assert(Fin),
    ?assert(erx_tcp_reass:is_empty(Q)),
    ?assertEqual(0, maps:get(bytes, erx_tcp_reass:held(Q))).

%% Random spans of [0, Len), then a partition of it; the property appends
%% the whole stream, which arrives trimmed to rcv_nxt and so always passes.
%% A span reaching Len carries FIN.
arrivals(Len) ->
    Random = [span(Len) || _ <- lists:seq(1, rand:uniform(40))],
    Cuts = lists:usort([0, Len | [rand:uniform(Len) - 1 || _ <- lists:seq(1, rand:uniform(8))]]),
    Partition = lists:zip(lists:droplast(Cuts), tl(Cuts)),
    Random ++ shuffle(Partition).

span(Len) ->
    Off = rand:uniform(Len) - 1,
    {Off, min(Len, Off + rand:uniform(300))}.

%% One arrival as the caller makes it: trimmed to rcv_nxt, as tcp_input
%% trims, and sometimes cut from a larger frame.
arrive({_, End}, #{rcv_nxt := RcvNxt} = S, Base, _) when Base + End =< RcvNxt ->
    S;
arrive({Off0, End}, #{q := Q, rcv_nxt := RcvNxt, out := Out, have := Have, ctx := Ctx} = S, Base, Stream) ->
    Off = max(Off0, RcvNxt - Base),
    Data = frame(binary:part(Stream, Off, End - Off)),
    Seg = #{seq => Base + Off, data => Data, fin => End =:= byte_size(Stream)},
    Have1 = maps:merge(Have, maps:from_keys(lists:seq(Base + Off, Base + End - 1), true)),
    Expect = first_missing(RcvNxt, Have1),
    S1 = case erx_tcp_reass:insert(Q, Seg, RcvNxt, Ctx) of
             {delivered, Bytes, NewRcvNxt, Fin, Q1} ->
                 ?assertEqual(Expect, NewRcvNxt),
                 ?assertEqual(binary:part(Stream, RcvNxt - Base, NewRcvNxt - RcvNxt),
                              iolist_to_binary(Bytes)),
                 ?assertEqual(Fin, NewRcvNxt =:= Base + byte_size(Stream)),
                 S#{q := Q1, rcv_nxt := NewRcvNxt, out := [Bytes | Out], fin := Fin, have := Have1};
             {queued, Q1} ->
                 ?assertEqual(RcvNxt, Expect),
                 S#{q := Q1, have := Have1};
             {dropped, Reason, Q1} ->
                 ?assert(lists:member(Reason, [no_room, queue_full])),
                 ?assertEqual(Q, Q1),
                 S
         end,
    #{rcv_nxt := Now, q := Qn, have := HaveN} = S1,
    #{ranges := Ranges, bytes := Held} = erx_tcp_reass:held(Qn),
    ?assertEqual(runs(Now, HaveN), Ranges),
    ?assert(Held =< maps:get(room, Ctx)),
    ?assert(length(Ranges) =< min(maps:get(hiwat, Ctx) div maps:get(mss, Ctx) + 1, 100)),
    S1.

first_missing(N, Have) ->
    case Have of
        #{N := _} -> first_missing(N + 1, Have);
        _ -> N
    end.

%% The model's maximal runs of held positions at or above RcvNxt.
runs(RcvNxt, Have) ->
    Held = lists:sort([P || P <- maps:keys(Have), P >= RcvNxt]),
    lists:reverse(lists:foldl(fun(P, [{F, P} | Acc]) -> [{F, P + 1} | Acc];
                                 (P, Acc) -> [{P, P + 1} | Acc]
                              end, [], Held)).

frame(Data) ->
    case rand:uniform(3) of
        1 -> binary:part(<<0:800, Data/binary, 0:800>>, 100, byte_size(Data));
        _ -> Data
    end.

shuffle(List) -> [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

seg(Seq, Data) -> #{seq => Seq, data => Data, fin => false}.
fin(Seq, Data) -> #{seq => Seq, data => Data, fin => true}.

queued({queued, Q}) -> Q.

%% A segment starting inside a held range keeps that range's bytes; past its
%% end, the new bytes replace the held ones they cover (tcp_reass_append,
%% tcp_reass_replace, tcp_reass_merge_forward).
overlap_keeps_before_and_takes_after_test() ->
    Q1 = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), seg(110, <<"aaaa">>), 100, ?OPEN)),
    Q2 = queued(erx_tcp_reass:insert(Q1, seg(120, <<"cccc">>), 100, ?OPEN)),
    Q3 = queued(erx_tcp_reass:insert(Q2, seg(112, <<"BBBBBBBBBB">>), 100, ?OPEN)),
    ?assertEqual([{110, 124}], maps:get(ranges, erx_tcp_reass:held(Q3))),
    {delivered, Data, 124, false, _} =
        erx_tcp_reass:insert(Q3, seg(100, <<"0123456789">>), 100, ?OPEN),
    ?assertEqual(<<"0123456789aaaaBBBBBBBBcc">>, iolist_to_binary(Data)).

duplicate_is_queued_unchanged_test() ->
    Q1 = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), seg(110, <<"aaaa">>), 100, ?OPEN)),
    ?assertEqual({queued, Q1}, erx_tcp_reass:insert(Q1, seg(111, <<"xx">>), 100, ?OPEN)).

%% min(hiwat div mss + 1, 100) ranges; a segment joining a range, or the one
%% at rcv_nxt, still passes.
range_cap_test() ->
    Ctx = ctx(#{hiwat => 4, mss => 2}),
    Q = lists:foldl(fun(N, Acc) -> queued(erx_tcp_reass:insert(Acc, seg(100 + 10 * N, <<"x">>), 100, Ctx)) end,
                    erx_tcp_reass:new(), [1, 2, 3]),
    ?assertMatch({dropped, queue_full, Q}, erx_tcp_reass:insert(Q, seg(200, <<"x">>), 100, Ctx)),
    ?assertMatch({queued, _}, erx_tcp_reass:insert(Q, seg(111, <<"x">>), 100, Ctx)),
    ?assertMatch({delivered, _, 101, false, _}, erx_tcp_reass:insert(Q, seg(100, <<"x">>), 100, Ctx)),
    Full = lists:foldl(fun(N, Acc) -> queued(erx_tcp_reass:insert(Acc, seg(100 + 2 * N, <<"x">>), 100, ?OPEN)) end,
                       erx_tcp_reass:new(), lists:seq(1, 100)),
    ?assertMatch({dropped, queue_full, _}, erx_tcp_reass:insert(Full, seg(1000, <<"x">>), 100, ?OPEN)).

%% Out-of-order bytes count against the room; the segment at rcv_nxt does not.
room_test() ->
    Ctx = ctx(#{room => 8 + 256 + 2}),
    Q = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), seg(110, <<"12345678">>), 100, Ctx)),
    ?assertMatch({dropped, no_room, Q}, erx_tcp_reass:insert(Q, seg(130, <<"abc">>), 100, Ctx)),
    ?assertMatch({delivered, _, 118, false, _},
                 erx_tcp_reass:insert(Q, seg(100, <<"0123456789">>), 100, Ctx)).

%% A small payload is copied out of its frame and counts at its own size; a
%% large one keeps its frame and counts at the frame's; each piece also
%% counts 256 bytes, FreeBSD's MSIZE.
held_bytes_count_the_frame_test() ->
    Frame = binary:copy(<<0:12000>>),
    Small = binary:part(Frame, 100, 10),
    Large = binary:part(Frame, 100, 1000),
    Q1 = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), seg(110, Small), 100, ?OPEN)),
    ?assertEqual(10 + 256, maps:get(bytes, erx_tcp_reass:held(Q1))),
    Q2 = queued(erx_tcp_reass:insert(Q1, seg(200, Large), 100, ?OPEN)),
    ?assertEqual(10 + 1500 + 2 * 256, maps:get(bytes, erx_tcp_reass:held(Q2))),
    Q3 = queued(erx_tcp_reass:insert(Q2, seg(199, <<0:7992>>), 100, ?OPEN)),
    ?assertEqual(10 + 999 + 2 + 3 * 256, maps:get(bytes, erx_tcp_reass:held(Q3))).

fin_test() ->
    Q1 = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), fin(110, <<"abc">>), 100, ?OPEN)),
    ?assertEqual(113, maps:get(fin, erx_tcp_reass:held(Q1))),
    ?assertMatch({dropped, after_fin, Q1}, erx_tcp_reass:insert(Q1, seg(112, <<"xy">>), 100, ?OPEN)),
    ?assertMatch({dropped, fin_inside, Q1}, erx_tcp_reass:insert(Q1, fin(105, <<"x">>), 100, ?OPEN)),
    ?assertMatch({delivered, _, 113, true, _}, erx_tcp_reass:insert(Q1, seg(100, <<"0123456789">>), 100, ?OPEN)),
    %% A bare FIN past a gap waits for it; one at rcv_nxt is delivered at once.
    Q2 = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), fin(105, <<>>), 100, ?OPEN)),
    ?assertMatch({delivered, _, 105, true, _}, erx_tcp_reass:insert(Q2, seg(100, <<"01234">>), 100, ?OPEN)),
    ?assertMatch({delivered, [], 100, true, _}, erx_tcp_reass:insert(erx_tcp_reass:new(), fin(100, <<>>), 100, ?OPEN)),
    ?assertMatch({dropped, empty, _}, erx_tcp_reass:insert(erx_tcp_reass:new(), seg(100, <<>>), 100, ?OPEN)).

%% Before ESTABLISHED even in-order data is held, and a bare FIN is
%% stripped; present/2 delivers it once the connection is established.
before_established_test() ->
    Ctx = ctx(#{established => false}),
    Q = queued(erx_tcp_reass:insert(erx_tcp_reass:new(), seg(100, <<"abc">>), 100, Ctx)),
    ?assertMatch({dropped, empty, _}, erx_tcp_reass:insert(Q, fin(103, <<>>), 100, Ctx)),
    ?assertMatch({delivered, [<<"abc">>], 103, false, _}, erx_tcp_reass:present(Q, 100)).

ctx(Overrides) -> maps:merge(?OPEN, Overrides).
