%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_bytes_probe).

-moduledoc """
Judges erx_bytes's network primitives, `inet_csum/2`, `inet_csum_update/3`, `siphash24/2`,
`tcp_merge/1`, `tcp_merge_limit/0` and `entropy/1`, in a running erXos release against the Erlang models of the host stand-in
(test/erlang/host_bytes/erx_bytes.erl). The host tests run `answers/0` on stock OTP with the
stand-in, then load this module into the release and hand those answers to `check/1`, which
compares them with the answers of erx_bytes there, the BIFs', to the same calls. The calls come
from a fixed seed of `rand`, so both runtimes, which are the same OTP release, make the same
arguments. Their iolists nest binaries at odd and even offsets, so the walk over iodata is
judged as well as the arithmetic. `check/1` also judges every refusal and acceptance of the
shared contract against literal answers, so on stock it judges the stand-in's contract too:
integer bytes, binaries at a bit offset, the cell limit, deep nesting and improper tails
included.
""".

-export([answers/0, check/1, merge_frame/1, merge_batch/0]).

-define(RANDOM_CALLS, 20).
-define(MERGE_BATCHES, 60).
-define(CALL_MAX, 65536).
-define(CELLS_MAX, 131072).

-type answer() :: non_neg_integer() | badarg | {size, pos_integer()} | boolean()
                | {units, non_neg_integer()} | {pos_integer(), pos_integer()}.

-doc "The answers of erx_bytes, whichever implementation is loaded, to the probe's calls.".
-spec answers() -> [answer()].
answers() ->
    [answer(Call) || Call <- calls()].

-doc """
`{net_bytes, Mismatches, Contract}`: the positions of the calls whose answers differ from
`Expected`, the stand-in's answers (or `[count]` when there are not as many), and the
contract cases that answered wrongly as `{Position, Want, Got}`; both empty when the
implementation agrees.
""".
-spec check([answer()]) -> {net_bytes, [pos_integer()] | [count], [{pos_integer(), answer(), answer()}]}.
check(Expected) ->
    {net_bytes, mismatches(Expected, answers()), wrong_contract_answers()}.

mismatches(Expected, Answers) when length(Expected) =/= length(Answers) ->
    [count];
mismatches(Expected, Answers) ->
    [Index || {Index, Want, Got} <- lists:zip3(lists:seq(1, length(Answers)), Expected, Answers),
              Want =/= Got].

wrong_contract_answers() ->
    Answered = [{Index, Want, answer(Call)}
                || {Index, {Call, Want}} <- lists:enumerate(contract())],
    [Wrong || {_Index, Want, Got} = Wrong <- Answered, Want =/= Got].

%% entropy/1 answers with the size of its bytes, and entropy_pair with whether two draws of
%% its size differ, which equal draws of 32 bytes do with probability 2^-256.
answer({entropy, [N]}) ->
    try {size, byte_size(erx_bytes:entropy(N))}
    catch error:badarg -> badarg
    end;
answer({entropy_pair, [N]}) ->
    erx_bytes:entropy(N) =/= erx_bytes:entropy(N);
%% tcp_merge/1 answers with a hash of its units, so the answers stay short enough to type into
%% the release's console; a difference in any unit changes it.
answer({tcp_merge, [Frames]}) ->
    try units(erx_bytes:tcp_merge(Frames))
    catch error:badarg -> badarg
    end;
answer({Function, Arguments}) ->
    try apply(erx_bytes, Function, Arguments)
    catch error:badarg -> badarg
    end.

units(Units) -> {units, erlang:phash2(Units, 1 bsl 32)}.

%% Random calls of each primitive over iolists of pieces of 0 to 1500 bytes, some over 512, and
%% random batches of the merge (merge_batch/0).
calls() ->
    _ = rand:seed(exsss, {1071, 1624, 2012}),
    lists:append([[{inet_csum, [rand:uniform(16#10000) - 1, iolist()]},
                   {siphash24, [rand:bytes(16), iolist()]},
                   {inet_csum_update, update_arguments()}] || _ <- lists:seq(1, ?RANDOM_CALLS)])
        ++ [{tcp_merge, [merge_batch()]} || _ <- lists:seq(1, ?MERGE_BATCHES)].

iolist() ->
    nest([rand:bytes(rand:uniform(1501) - 1) || _ <- lists:seq(1, rand:uniform(5))]).

nest([]) -> [];
nest([Piece]) -> [Piece];
nest([First, Second | Rest]) -> [[First], [Second | nest(Rest)]].

update_arguments() ->
    Size = 2 * (rand:uniform(5) - 1),
    [rand:uniform(16#10000) - 1, rand:bytes(Size), rand:bytes(Size)].

%% Each call with its literal answer: refusals, the limits of 64 KiB, and iodata of every shape.
contract() ->
    Key = list_to_binary(lists:seq(0, 15)),
    Max = binary:copy(<<1>>, ?CALL_MAX),
    %% Binaries that start at a bit offset, which the BIFs copy before they read them.
    <<_:1, Odd/binary>> = <<0:1, 1, 2>>,
    <<_:3, OddKey/binary>> = <<0:3, Key/binary>>,
    [{{inet_csum, [-1, <<>>]}, badarg},
     {{inet_csum, [16#10000, <<>>]}, badarg},
     {{inet_csum, [0, <<Max/binary, 1>>]}, badarg},
     {{inet_csum, [0, [<<1>>, Max]]}, badarg},
     {{inet_csum, [0, <<1:7>>]}, badarg},
     {{inet_csum, [0, [<<1:7>>]]}, badarg},
     {{inet_csum, [0, [atom]]}, badarg},
     {{inet_csum, [0, atom]}, badarg},
     {{inet_csum, [0, [1 | 2]]}, badarg},
     {{inet_csum, [0, [256]]}, badarg},
     {{inet_csum, [16#1234, []]}, 16#1234},
     {{inet_csum, [0, [<<1>> | <<2>>]]}, 16#0102},
     {{inet_csum, [0, Max]}, 16#8080},
     {{inet_csum, [0, [binary:part(Max, 0, ?CALL_MAX - 1), 1]]}, 16#8080},
     {{inet_csum, [0, [binary:part(Max, 0, ?CALL_MAX - 1), 1, 1]]}, badarg},
     {{inet_csum, [0, [1, 2]]}, 16#0102},
     {{inet_csum, [0, [<<1>>, [[2]] | <<3>>]]}, 16#0402},
     {{inet_csum, [0, Odd]}, 16#0102},
     {{inet_csum, [0, [<<>>, Odd]]}, 16#0102},
     {{inet_csum, [0, [Odd, <<3>>, Odd]]}, 16#0603},
     {{inet_csum, [16#1234, lists:duplicate(?CELLS_MAX, <<>>)]}, 16#1234},
     {{inet_csum, [16#1234, lists:duplicate(?CELLS_MAX + 1, <<>>)]}, badarg},
     {{inet_csum, [16#1234, lists:duplicate(?CELLS_MAX + 1, [])]}, badarg},
     {{inet_csum, [0, left_nested(?CELLS_MAX div 2, <<1>>)]}, 16#8080},
     {{inet_csum, [0, left_nested(?CELLS_MAX div 2 + 1, <<1>>)]}, badarg},
     {{inet_csum, [0, right_nested(?CELLS_MAX - 1, [<<1>>])]}, 16#0100},
     {{inet_csum, [0, right_nested(?CELLS_MAX - 1, [<<1>> | 2])]}, badarg},
     {{inet_csum, [0, [<<1>> | 2]]}, badarg},
     {{inet_csum, [0, [-1]]}, badarg},
     {{inet_csum, [0, [1.0]]}, badarg},
     {{inet_csum, [0, 1]}, badarg},
     {{inet_csum, [0, [Max | <<1>>]]}, badarg},
     {{inet_csum_update, [0, <<1>>, <<2>>]}, badarg},
     {{inet_csum_update, [0, <<1, 2>>, <<1, 2, 3, 4>>]}, badarg},
     {{inet_csum_update, [16#10000, <<>>, <<>>]}, badarg},
     {{inet_csum_update, [0, [<<1, 2>>], <<1, 2>>]}, badarg},
     {{inet_csum_update, [0, <<Max/binary, 0, 0>>, <<Max/binary, 0, 0>>]}, badarg},
     {{inet_csum_update, [16#dd2f, <<16#55, 16#55>>, <<16#32, 16#85>>]}, 16#0000},
     {{inet_csum_update, [16#ffff, <<>>, <<>>]}, 16#ffff},
     {{siphash24, [<<0:120>>, <<>>]}, badarg},
     {{siphash24, [<<0:127>>, <<>>]}, badarg},
     {{siphash24, [[Key], <<>>]}, badarg},
     {{siphash24, [Key, <<Max/binary, 1>>]}, badarg},
     {{siphash24, [Key, [1 | 2]]}, badarg},
     {{siphash24, [Key, lists:seq(0, 14)]}, 16#a129ca6149be45e5},
     {{siphash24, [OddKey, lists:seq(0, 14)]}, 16#a129ca6149be45e5},
     {{siphash24, [Key, [<<0, 1, 2>>, [[3 | <<4, 5>>]], lists:seq(6, 14)]]}, 16#a129ca6149be45e5},
     {{siphash24, [Key, lists:duplicate(?CELLS_MAX + 1, [])]}, badarg},
     {{siphash24, [Key, right_nested(?CELLS_MAX - 1, [<<1>> | 2])]}, badarg},
     {{siphash24, [Key, []]}, 16#726fdb47dd0e0e31},
     {{tcp_merge_limit, []}, {256, 65536}},
     {{tcp_merge, [[]]}, units([])},
     {{tcp_merge, [[Odd]]}, units([{sum, 0, <<1, 2>>}])},
     {{tcp_merge, [[{sum, 7, Odd}]]}, units([{sum, 7, <<1, 2>>}])},
     {{tcp_merge, [[binary:copy(<<0>>, 32768), binary:copy(<<0>>, 32767), Max]]},
      units([{sum, 0, binary:copy(<<0>>, 32768)}, {sum, 0, binary:copy(<<0>>, 32767)},
             {sum, ones(binary:part(Max, 14, ?CALL_MAX - 14)), Max}])},
     {{tcp_merge, [atom]}, badarg},
     {{tcp_merge, [[<<>> | <<>>]]}, badarg},
     {{tcp_merge, [[atom]]}, badarg},
     {{tcp_merge, [[<<1:7>>]]}, badarg},
     {{tcp_merge, [[{sum, 16#10000, <<>>}]]}, badarg},
     {{tcp_merge, [[{sum, 1, <<>>, x}]]}, badarg},
     {{tcp_merge, [[{csum, 1, <<>>}]]}, badarg},
     {{tcp_merge, [lists:duplicate(257, <<>>)]}, badarg},
     {{tcp_merge, [[Max, <<>>]]}, badarg},
     {{tcp_merge, [[<<Max/binary, 1>>]]}, badarg},
     {{entropy, [0]}, badarg},
     {{entropy, [257]}, badarg},
     {{entropy, [-1]}, badarg},
     {{entropy, [16.0]}, badarg},
     {{entropy, [atom]}, badarg},
     {{entropy_pair, [32]}, true}
     | [{{entropy, [N]}, {size, N}} || N <- lists:seq(1, 256)]].

%% Leaf inside N lists, each the head of its own one-cell list: [[[Leaf]]] for N of 3. The walk
%% keeps each level's empty tail on its stack, so this is the case that grows it most.
right_nested(0, Leaf) -> Leaf;
right_nested(N, Leaf) -> right_nested(N - 1, [Leaf]).

%% Leaf after N levels of [Acc, Leaf], the shape of [Acc, Piece] built in a loop: two cells a
%% level, and a tail held on the walk's stack at each.
left_nested(N, Leaf) ->
    lists:foldl(fun(_, Acc) -> [Acc, Leaf] end, [], lists:seq(1, N)).

%% --- The merge of received TCP segments ----------------------------------------------------

-doc """
An Ethernet frame carrying one TCP segment, its checksums right unless `bad` names one to
spoil. `Spec` holds `version` (4 or 6), `link` (12 bytes), `src` and `dst` (4 or 16 bytes),
`sport`, `dport`, `seq`, `ack`, `flags`, `options` (`none`, `{ts, Val, Ecr}` or other option
bytes) and `payload`; and optionally `tos` (the IPv4 type of service, or IPv6's first four
header bytes' traffic class), `off` (a data offset other than the options'), `win`, `frag` (`{MoreFragments, Offset}` of IPv4), `pad` (pad an
IPv4 frame to 60 bytes with a5 bytes), `raw` (the frame's bytes, as given) and `bad` (`ip` or `tcp`).
""".
-spec merge_frame(map()) -> binary().
merge_frame(#{raw := Frame}) ->
    Frame;
merge_frame(#{version := Version, link := Link, src := Src, dst := Dst, sport := Sport, dport := Dport,
              seq := Seq, ack := Ack, flags := Flags, options := Options, payload := Payload} = Spec) ->
    Opts = case Options of
               none -> <<>>;
               {ts, Val, Ecr} -> <<1, 1, 8, 10, Val:32, Ecr:32>>;
               Bytes when is_binary(Bytes) -> Bytes
           end,
    Off = maps:get(off, Spec, 5 + byte_size(Opts) div 4),
    Win = maps:get(win, Spec, 65535),
    Bare = <<Sport:16, Dport:16, Seq:32, Ack:32, Off:4, Flags:12, Win:16, 0:16, 0:16,
             Opts/binary, Payload/binary>>,
    Length = byte_size(Bare),
    Pseudo = case Version of
                 4 -> <<Src/binary, Dst/binary, 0, 6, Length:16>>;
                 6 -> <<Src/binary, Dst/binary, Length:32, 0:24, 6>>
             end,
    Spoil = fun(Part, Field) -> case maps:get(bad, Spec, none) of Part -> Field bxor 1; _ -> Field end end,
    TcpSum = Spoil(tcp, bnot ones(<<Pseudo/binary, Bare/binary>>) band 16#ffff),
    <<Head:16/binary, _:16, Tail/binary>> = Bare,
    Tcp = <<Head/binary, TcpSum:16, Tail/binary>>,
    Tos = maps:get(tos, Spec, 0),
    Frame = case Version of
                4 ->
                    {Mf, FragOff} = maps:get(frag, Spec, {0, 0}),
                    Ip0 = <<4:4, 5:4, Tos, (20 + Length):16, 0:16, 0:1, 1:1, Mf:1, FragOff:13, 64, 6, 0:16,
                            Src/binary, Dst/binary>>,
                    IpSum = Spoil(ip, bnot ones(Ip0) band 16#ffff),
                    <<IpHead:10/binary, _:16, IpTail/binary>> = Ip0,
                    <<Link/binary, 16#0800:16, IpHead/binary, IpSum:16, IpTail/binary, Tcp/binary>>;
                6 ->
                    <<Link/binary, 16#86dd:16, 6:4, Tos:8, 0:20, Length:16, 6, 64, Src/binary, Dst/binary,
                      Tcp/binary>>
            end,
    case maps:get(pad, Spec, false) andalso byte_size(Frame) < 60 of
        true -> <<Frame/binary, (binary:copy(<<16#a5>>, 60 - byte_size(Frame)))/binary>>;
        false -> Frame
    end.

%% The folded RFC 1071 sum, the probe's own.
ones(Bytes) -> fold(words(Bytes, 0)).

words(<<Word:16, Rest/binary>>, Total) -> words(Rest, Total + Word);
words(<<Byte>>, Total) -> Total + (Byte bsl 8);
words(<<>>, Total) -> Total.

fold(Total) when Total > 16#ffff -> fold((Total band 16#ffff) + (Total bsr 16));
fold(Total) -> Total.

-doc """
A random batch within the merge's limit: frames of up to ten connections, some differing only
in their ports, interleaved, mostly in order and some past a gap, with pure ACKs that advance
and duplicates that do not, window updates, every TCP flag, the timestamps and other options,
a changed type of service, spoiled checksums, 60-byte frames with padding, fragments, a frame
that is not IP and large payloads that reach a unit's length limit; each frame with its sum,
a wrong sum or none.
""".
-spec merge_batch() -> [binary() | {sum, 0..16#ffff, binary()}].
merge_batch() ->
    %% A quarter of the batches carry jumbo payloads, whose units reach the length limit.
    Size = case rand:uniform(4) of 1 -> jumbo; _ -> ethernet end,
    Conns = [(merge_conn(Index))#{size => Size} || Index <- lists:seq(1, rand:uniform(rand:uniform(10)))],
    merge_frames(rand:uniform(80), maps:from_list(lists:enumerate(Conns)), 0, []).

merge_conn(Index) ->
    Version = case rand:uniform(4) of 1 -> 6; _ -> 4 end,
    Size = case Version of 4 -> 4; 6 -> 16 end,
    %% Connections 1 to 3 differ only in their ports, and all start at the same sequence
    %% numbers, so a merge that ignored a field of the connection would be seen.
    Peer = case Index =< 3 of true -> 1; false -> Index end,
    #{version => Version, link => <<2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, Peer>>,
      src => <<10, Peer:(Size * 8 - 8)>>, dst => <<10, 2:(Size * 8 - 8)>>,
      sport => 1000 + Index, dport => 80, seq => 16#fffff000, ack => 7, win => 65535,
      ts => case rand:uniform(2) of 1 -> none; 2 -> 100 end}.

merge_frames(0, _Conns, _Bytes, Frames) ->
    lists:reverse(Frames);
merge_frames(Left, Conns, Bytes, Frames) ->
    Index = rand:uniform(map_size(Conns)),
    {Spec, Conn} = merge_step(maps:get(Index, Conns)),
    Frame = merge_frame(Spec),
    case Bytes + byte_size(Frame) of
        Next when Next >= 65536 -> lists:reverse([with_sum(Frame) | Frames]);
        Next -> merge_frames(Left - 1, Conns#{Index := Conn}, Next, [with_sum(Frame) | Frames])
    end.

%% The next segment of Conn, and Conn after it.
merge_step(#{seq := Seq, ack := Ack, ts := Ts, size := Size} = Conn) ->
    Length = case {rand:uniform(10), Size} of
                 {1, _} -> 0;
                 {2, _} -> rand:uniform(100);
                 {_, jumbo} -> 8000 + rand:uniform(960);
                 {_, ethernet} -> 1448
             end,
    Event = rand:uniform(40),
    Payload = case Event of
                  E when E =< 3 -> <<>>;          % a pure ACK: advancing, a duplicate or a window update
                  _ -> rand:bytes(Length)
              end,
    NextAck = case rand:uniform(3) of 1 -> Ack; _ -> (Ack + rand:uniform(3000)) band 16#ffffffff end,
    Skip = case Event of 4 -> rand:uniform(1000); _ -> 0 end,
    NextTs = case {Ts, rand:uniform(10)} of
                 {none, _} -> none;
                 {_, 1} -> (Ts - 1) band 16#ffffffff;
                 _ -> (Ts + rand:uniform(2) - 1) band 16#ffffffff
             end,
    Base = maps:with([version, link, src, dst, sport, dport, win], Conn),
    Spec0 = Base#{seq => (Seq + Skip) band 16#ffffffff, ack => NextAck, flags => 16#10, payload => Payload,
                  options => case NextTs of none -> none; _ -> {ts, NextTs, 5} end},
    Spec = case Event of
               5 -> Spec0#{flags => 16#10 bor lists:nth(rand:uniform(8), [16#01, 16#02, 16#04, 16#20, 16#40,
                                                                      16#80, 16#11, 16#100])};
               6 -> Spec0#{flags => 16#18};
               7 -> Spec0#{options => <<1, 1, 4, 2>>};
               8 -> Spec0#{tos => 3};
               9 -> Spec0#{bad => tcp};
               10 -> Spec0#{bad => ip};
               11 -> Spec0#{payload => rand:bytes(rand:uniform(6) - 1), options => none, pad => true};
               16 -> Spec0#{payload => <<>>, raw => <<(maps:get(link, Conn))/binary, 16#0806:16,
                                                      (rand:bytes(28))/binary>>};
               12 -> Spec0#{frag => {1, 0}};
               13 -> Spec0#{frag => {0, 100}};
               14 -> Spec0#{win => rand:uniform(65535)};
               15 -> Spec0#{flags => 0};
               _ -> Spec0
           end,
    Sent = byte_size(maps:get(payload, Spec)),
    {Spec, Conn#{seq := (Seq + Skip + Sent) band 16#ffffffff, ack := NextAck, ts := NextTs}}.

with_sum(<<_:14/binary, Network/binary>> = Frame) ->
    case rand:uniform(4) of
        1 -> Frame;
        2 -> {sum, rand:uniform(16#10000) - 1, Frame};
        _ -> {sum, ones(Network), Frame}
    end.
