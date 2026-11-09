%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The receiver's SACK blocks (erx_tcp_sack) against a model that records,
%% for every byte received above rcv_nxt, the time of the last segment that
%% covered it (RFC 2018 section 4, RFC 2883 section 4).
-module(erx_tcp_sack_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ROUNDS, 300).
-define(LIMIT, 4).

%% Over random arrivals around rcv_nxt, new, duplicate below rcv_nxt,
%% duplicate of held data and partly each, with zero to two
%% acknowledgements after each: every acknowledgement's SACK blocks are the
%% model's held runs, most recently covered first, as many as fit beside the
%% D-SACK block and the held run that contains it; the D-SACK block is the
%% lowest run of bytes the receiver had of the last duplicate since the
%% previous acknowledgement, reported once and first.
matches_model_test() ->
    [property(Seed) || Seed <- lists:seq(1, ?ROUNDS)],
    ok.

property(Seed) ->
    _ = rand:seed(exsss, {Seed, 16#5a, 16#c3}),
    Base = rand:uniform(1 bsl 40),
    Model = #{rcv_nxt => Base, held => #{}, pending => none},
    lists:foldl(fun(Time, {Sack, M}) -> arrive(Time, Sack, M) end,
                {erx_tcp_sack:new(), Model}, lists:seq(1, 60)),
    ok.

%% One segment, then the acknowledgements, each checked against the model.
arrive(Time, Sack, #{rcv_nxt := RcvNxt, held := Held, pending := Pending}) ->
    First = RcvNxt - 20 + rand:uniform(100),
    End = First + rand:uniform(12) - 1,
    Bytes = lists:seq(First, End - 1),
    Had = [B || B <- Bytes, B < RcvNxt orelse is_map_key(B, Held)],
    Held1 = maps:merge(Held, maps:from_list([{B, Time} || B <- Bytes, B >= RcvNxt])),
    {RcvNxt1, Held2} = advance(RcvNxt, Held1),
    Sack1 = erx_tcp_sack:arrived(Sack, {First, End}, RcvNxt, ranges(Held2)),
    Pending1 = case Had of
                   [] -> Pending;
                   [Low | _] -> {Low, run_end(Low, Had)}
               end,
    M = #{rcv_nxt => RcvNxt1, held => Held2, pending => Pending1},
    lists:foldl(fun(_, {S, Model}) -> check_ack(S, Model) end, {Sack1, M},
                lists:seq(1, rand:uniform(3) - 1)).

check_ack(Sack, #{held := Held, pending := Pending} = M) ->
    {Blocks, Sack1} = erx_tcp_sack:ack(Sack),
    Recent = [Range || {_, Range} <- lists:reverse(lists:sort(
                [{lists:max([maps:get(B, Held) || B <- lists:seq(L, R - 1)]), {L, R}}
                 || {L, R} <- ranges(Held)]))],
    Expected = case Pending of
                   none -> lists:sublist(Recent, ?LIMIT);
                   {DL, DR} = Dsack ->
                       {In, Out} = lists:partition(fun({L, R}) -> L < DR andalso DL < R end, Recent),
                       [Dsack | lists:sublist(In ++ Out, ?LIMIT - 1)]
               end,
    ?assertEqual(Expected, Blocks),
    {Sack1, M#{pending := none}}.

%% Delivery: rcv_nxt moves past the held bytes that start at it.
advance(RcvNxt, Held) when is_map_key(RcvNxt, Held) ->
    advance(RcvNxt + 1, maps:remove(RcvNxt, Held));
advance(RcvNxt, Held) ->
    {RcvNxt, Held}.

%% The maximal runs of held byte positions, in sequence order.
ranges(Held) ->
    lists:reverse(lists:foldl(fun(B, [{L, B} | Rest]) -> [{L, B + 1} | Rest];
                                 (B, Acc) -> [{B, B + 1} | Acc]
                              end, [], lists:sort(maps:keys(Held)))).

%% The end of the run of consecutive positions starting at N.
run_end(N, [N | Rest]) -> run_end(N + 1, Rest);
run_end(N, _) -> N.

