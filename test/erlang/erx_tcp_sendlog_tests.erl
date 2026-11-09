%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The send log's scoreboard against RFC 6675's definitions written directly over a byte map
%% (docs/design-network-stack.md, "The send log, loss and congestion: properties and a
%% FreeBSD oracle"): random sends, acknowledgements with SACK blocks on the log's range
%% edges, and retransmissions chosen by next_seg/2, with SACKed bytes, IsLost, the pipe and
%% NextSeg's rules 1 and 3 compared after every step.
-module(erx_tcp_sendlog_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MSS, 100).
-define(DUPTHRESH, 3).
-define(ISS, 1000).

%% The oracle: SACKed bytes as a set, and RFC 6675's HighRxt as the byte after the highest
%% retransmitted one.
-record(model, {una = ?ISS, max = ?ISS, sacked = #{}, high_rxt = ?ISS}).

matches_byte_map_test() ->
    lists:foreach(fun run/1, lists:seq(1, 60)).

run(Seed) ->
    rand:seed(exsss, {Seed, 17, 29}),
    lists:foldl(fun(Step, {Log, Model}) ->
                        {Log1, Model1} = step(rand:uniform(3), Step, Log, Model),
                        check(Seed, Step, Log1, Model1),
                        {Log1, Model1}
                end, {erx_tcp_sendlog:new(?ISS), #model{}}, lists:seq(1, 150)).

%% Send new data, unless the window is full: half full-sized segments, half of any size.
step(1, Now, Log, #model{una = Una, max = Max} = M) when Max - Una < 30 * ?MSS ->
    Next = Max + case rand:uniform(2) of 1 -> ?MSS; 2 -> rand:uniform(?MSS) end,
    {erx_tcp_sendlog:sent(Log, Max, Next, Now), M#model{max = Next}};
%% An acknowledgement: a cumulative point (a range edge or any byte) and up to three SACK
%% blocks on range edges.
step(2, _Now, Log, #model{una = Una, max = Max, sacked = Sacked} = M) when Max > Una ->
    Edges = edges(Log),
    Ack = case rand:uniform(4) of
        1 -> Una + rand:uniform(Max - Una);
        2 -> pick(Edges);
        _ -> Una
    end,
    Blocks = [block(Edges) || _ <- lists:seq(1, rand:uniform(4) - 1)],
    {Log1, _} = erx_tcp_sendlog:ack(Log, Ack, Blocks),
    {Log2, _} = erx_tcp_sendlog:mark_lost(Log1, ?DUPTHRESH, ?MSS),
    Una1 = max(Una, Ack),
    Kept = maps:filter(fun(B, _) -> B >= Una1 end, Sacked),
    Sacked1 = lists:foldl(fun({L, R}, Acc) ->
                                  maps:merge(Acc, maps:from_keys(bytes(max(L, Una1), min(R, Max)), true))
                          end, Kept, Blocks),
    {Log2, M#model{una = Una1, sacked = Sacked1}};
%% A retransmission, if NextSeg offers one.
step(_, Now, Log, #model{max = Max, high_rxt = HighRxt} = M) ->
    case erx_tcp_sendlog:next_seg(Log, opts(Max)) of
        {retransmit, S, E} -> {erx_tcp_sendlog:sent(Log, S, E, Now), M#model{high_rxt = max(HighRxt, E)}};
        _ -> {Log, M}
    end.

opts(Max) -> #{mss => ?MSS, recover => Max, new_data => false, rescue => false}.

edges(Log) ->
    lists:usort(lists:append([[S, N] || {S, N, _} <- erx_tcp_sendlog:to_list(Log)])).

pick([]) -> ?ISS;
pick(List) -> lists:nth(rand:uniform(length(List)), List).

block(Edges) ->
    A = pick(Edges),
    B = pick(Edges),
    {min(A, B), max(A, B)}.

check(Seed, Step, Log, #model{una = Una, max = Max, sacked = Sacked, high_rxt = HighRxt}) ->
    Where = {seed, Seed, step, Step},
    Lost = is_lost(Una, Max, Sacked),
    Unsacked = [B || B <- lists:seq(Una, Max - 1), not maps:is_key(B, Sacked)],
    Pipe = lists:sum([b2i(not maps:get(B, Lost)) + b2i(B < HighRxt) || B <- Unsacked]),
    LogLost = maps:from_list([{B, L} || {S, N, #{lost := L}} <- erx_tcp_sendlog:to_list(Log),
                                        B <- lists:seq(S, N - 1)]),
    ?assertEqual({Where, maps:size(Sacked)}, {Where, erx_tcp_sendlog:sacked_bytes(Log)}),
    ?assertEqual({Where, [B || B <- Unsacked, maps:get(B, Lost)]},
                 {Where, [B || B <- Unsacked, maps:get(B, LogLost)]}),
    ?assertEqual({Where, Pipe}, {Where, erx_tcp_sendlog:pipe(Log)}),
    HighSacked = lists:max([Una | [B + 1 || B <- maps:keys(Sacked)]]),
    Eligible = [B || B <- Unsacked, B >= HighRxt, B < HighSacked],
    Expected = case [B || B <- Eligible, maps:get(B, Lost)] of
        [Rule1 | _] -> Rule1;
        [] -> case Eligible of [Rule3 | _] -> Rule3; [] -> none end
    end,
    Got = case erx_tcp_sendlog:next_seg(Log, opts(Max)) of
        {retransmit, S, _} -> S;
        none -> none
    end,
    ?assertEqual({Where, Expected}, {Where, Got}).

%% RFC 6675's IsLost for every byte of [Una, Max): DupThresh discontiguous SACKed sequences
%% above it, or more than (DupThresh - 1) * SMSS SACKed bytes above it.
is_lost(Una, Max, Sacked) ->
    {_, _, _, Lost} =
        lists:foldl(fun(B, {Above, Runs, InRun, Acc}) ->
                            case maps:is_key(B, Sacked) of
                                true -> {Above + 1, Runs + b2i(not InRun), true, Acc#{B => false}};
                                false ->
                                    L = Runs >= ?DUPTHRESH orelse Above > (?DUPTHRESH - 1) * ?MSS,
                                    {Above, Runs, false, Acc#{B => L}}
                            end
                    end, {0, 0, false, #{}}, lists:seq(Max - 1, Una, -1)),
    Lost.

bytes(From, To) when From < To -> lists:seq(From, To - 1);
bytes(_, _) -> [].

b2i(true) -> 1;
b2i(false) -> 0.

%% A SACK block that covers only part of a range marks nothing: the peer cannot split the
%% log into pieces smaller than what was sent.
partial_block_marks_nothing_test() ->
    Log0 = erx_tcp_sendlog:sent(erx_tcp_sendlog:new(0), 0, 100, 1),
    Log1 = erx_tcp_sendlog:sent(Log0, 100, 200, 2),
    {Log2, #{sacked := Newly}} = erx_tcp_sendlog:ack(Log1, 0, [{150, 200}, {10, 20}]),
    ?assertEqual(0, Newly),
    ?assertEqual(2, length(erx_tcp_sendlog:to_list(Log2))),
    {Log3, #{sacked := 100, delivered := 100}} = erx_tcp_sendlog:ack(Log2, 0, [{100, 250}]),
    ?assertEqual(200, erx_tcp_sendlog:snd_fack(Log3)).

%% Rule 4: one rescue retransmission per recovery, ending at the highest unSACKed byte, and
%% none again until snd_una passes the recovery point.
rescue_test() ->
    Log0 = lists:foldl(fun(I, L) -> erx_tcp_sendlog:sent(L, I * 100, I * 100 + 100, I) end,
                       erx_tcp_sendlog:new(0), lists:seq(0, 4)),
    {Acked, _} = erx_tcp_sendlog:ack(Log0, 0, [{100, 200}]),
    Opts = #{mss => 60, recover => 500, new_data => false, rescue => true},
    %% Rule 3 first resends the hole below the SACKed range; then only the rescue is left.
    ?assertEqual({retransmit, 0, 60}, erx_tcp_sendlog:next_seg(Acked, Opts)),
    Log1 = erx_tcp_sendlog:sent(Acked, 0, 100, 5),
    ?assertEqual({rescue, 440, 500}, erx_tcp_sendlog:next_seg(Log1, Opts)),
    Log2 = erx_tcp_sendlog:rescued(Log1, 440, 500, 500, 9),
    ?assertEqual(none, erx_tcp_sendlog:next_seg(Log2, Opts)),
    ?assertEqual(erx_tcp_sendlog:pipe(Log1), erx_tcp_sendlog:pipe(Log2)).

%% A timeout makes everything unSACKed lost; the first keeps the SACKed ranges.
timeout_test() ->
    Log0 = lists:foldl(fun(I, L) -> erx_tcp_sendlog:sent(L, I * 100, I * 100 + 100, I) end,
                       erx_tcp_sendlog:new(0), lists:seq(0, 4)),
    {Log1, _} = erx_tcp_sendlog:ack(Log0, 0, [{200, 300}]),
    Kept = erx_tcp_sendlog:timeout(Log1, keep),
    ?assertEqual({100, 0}, {erx_tcp_sendlog:sacked_bytes(Kept), erx_tcp_sendlog:pipe(Kept)}),
    Gone = erx_tcp_sendlog:timeout(Log1, expunge),
    ?assertEqual({0, 0, 0}, {erx_tcp_sendlog:sacked_bytes(Gone), erx_tcp_sendlog:pipe(Gone),
                             erx_tcp_sendlog:snd_fack(Gone)}),
    ?assertEqual({retransmit, 0, 100},
                 erx_tcp_sendlog:next_seg(Gone, #{mss => 100, recover => 500, new_data => true,
                                                  rescue => false})).
