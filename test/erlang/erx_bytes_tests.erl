%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The Erlang models of the host stand-in (test/erlang/host_bytes/erx_bytes.erl) for the
%% Internet checksum and SipHash-2-4, against the published examples and vectors, and the
%% contract they share with erx_bytes. test/host/erx_net_bytes_test.rb also compares them with
%% the C cores over random cases.

-module(erx_bytes_tests).
-include_lib("eunit/include/eunit.hrl").

-define(IPV4_HEADER, <<16#45, 16#00, 16#00, 16#73, 16#00, 16#00, 16#40, 16#00, 16#40, 16#11, 16#b8, 16#61,
                       16#c0, 16#a8, 16#00, 16#01, 16#c0, 16#a8, 16#00, 16#c7>>).

%% RFC 1071, section 3: 00 01 f2 03 f4 f5 f6 f7 sums to ddf2, whole or in pieces.
rfc_1071_example_test() ->
    Bytes = <<16#00, 16#01, 16#f2, 16#03, 16#f4, 16#f5, 16#f6, 16#f7>>,
    ?assertEqual(16#ddf2, erx_bytes:inet_csum(0, Bytes)),
    <<A:3/binary, B/binary>> = Bytes,
    ?assertEqual(16#ddf2, erx_bytes:inet_csum(0, [A, [B]])),
    <<C:4/binary, D/binary>> = Bytes,
    ?assertEqual(16#ddf2, erx_bytes:inet_csum(erx_bytes:inet_csum(0, C), D)).

%% An IPv4 header verifies, and with its field zeroed sums to the field's complement, b861.
ipv4_header_test() ->
    ?assertEqual(16#ffff, erx_bytes:inet_csum(0, ?IPV4_HEADER)),
    <<Head:10/binary, _:16, Tail/binary>> = ?IPV4_HEADER,
    ?assertEqual(16#b861, bnot erx_bytes:inet_csum(0, [Head, <<0, 0>>, Tail]) band 16#ffff).

%% RFC 1624, section 4: equation 3 turns dd2f into 0000 when 5555 becomes 3285.
rfc_1624_example_test() ->
    ?assertEqual(16#0000, erx_bytes:inet_csum_update(16#dd2f, <<16#55, 16#55>>, <<16#32, 16#85>>)),
    ?assertEqual(16#dd2f, erx_bytes:inet_csum_update(16#dd2f, <<16#55, 16#55>>, <<16#55, 16#55>>)),
    ?assertEqual(16#1234, erx_bytes:inet_csum_update(16#1234, <<>>, <<>>)).

%% Decrementing the IPv4 header's TTL, 40 11 to 3f 11, updates the field as a recomputation does.
ttl_update_test() ->
    <<Head:8/binary, Ttl:2/binary, _:16, Tail/binary>> = ?IPV4_HEADER,
    Want = bnot erx_bytes:inet_csum(0, [Head, <<16#3f, 16#11, 0, 0>>, Tail]) band 16#ffff,
    ?assertEqual(Want, erx_bytes:inet_csum_update(16#b861, Ttl, <<16#3f, 16#11>>)).

%% The reference implementation's vectors under the key 00 .. 0f for the messages 00 .. n-1:
%% n of 0, 1, 7, 8, 15 (the paper's appendix A) and 63.
siphash_vectors_test_() ->
    Key = list_to_binary(lists:seq(0, 15)),
    Vectors = [{0, 16#726fdb47dd0e0e31}, {1, 16#74f839c593dc67fd}, {7, 16#ab0200f58b01d137},
               {8, 16#93f5f5799a932462}, {15, 16#a129ca6149be45e5}, {63, 16#958a324ceb064572}],
    [?_assertEqual(Want, erx_bytes:siphash24(Key, list_to_binary(lists:seq(0, N - 1))))
     || {N, Want} <- Vectors].

siphash_iodata_test() ->
    Key = list_to_binary(lists:seq(0, 15)),
    ?assertEqual(16#a129ca6149be45e5, erx_bytes:siphash24(Key, [<<0, 1, 2>>, [[<<3>>], <<>>], lists:seq(4, 14)])).

%% The contract erx_bytes shares with the stand-in, judged by the probe that also judges the
%% release (test/fixtures/erx_net_bytes_probe.erl): every refusal and acceptance answers as
%% written there.
contract_test() ->
    ?assertMatch({net_bytes, [], []}, erx_net_bytes_probe:check(erx_net_bytes_probe:answers())).

%% --- The merge of received TCP segments (docs/design-network-fastpath.md, "The merge") ---

%% A segment of connection Port (its source port) from Seq on, acknowledging Ack, with
%% Payload: IPv4, the timestamps option, ACK only; Changes override any field.
segment(Port, Seq, Ack, Payload) -> segment(Port, Seq, Ack, Payload, #{}).

segment(Port, Seq, Ack, Payload, Changes) ->
    Spec = #{version => 4, link => <<2, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 2>>,
             src => <<10, 0, 0, 1>>, dst => <<10, 0, 0, 2>>, sport => Port, dport => 80,
             seq => Seq, ack => Ack, flags => 16#10, options => {ts, 100, 5}, payload => Payload},
    erx_net_bytes_probe:merge_frame(maps:merge(Spec, Changes)).

summed(<<_:14/binary, Network/binary>> = Frame) -> {sum, erx_bytes:inet_csum(0, Network), Frame}.

payload(N) -> binary:copy(<<N>>, 1000).

%% In-order data of one connection becomes one unit of its first and last frame, each with
%% its sum, and the payloads in order; a frame that came without its sum is summed.
merge_in_order_test() ->
    Frames = [segment(1, 1000 * N, 7, payload(N)) || N <- [1, 2, 3]],
    [A, B, C] = Frames,
    ?assertEqual([{merged, 3, summed(A), summed(C), [payload(1), payload(2), payload(3)]}],
                 erx_bytes:tcp_merge([A, summed(B), C])),
    ?assertEqual([summed(A)], erx_bytes:tcp_merge([A])),
    ?assertEqual([], erx_bytes:tcp_merge([])).

%% A change of the type-of-service byte, a CE mark for one, ends the unit, so ECN sees it.
merge_differing_tos_test() ->
    A = segment(1, 1000, 7, payload(1)),
    B = segment(1, 2000, 7, payload(2), #{tos => 3}),
    ?assertEqual([summed(A), summed(B)], erx_bytes:tcp_merge([A, B])).

%% A first frame whose TCP checksum is wrong is no candidate, and the frames after it merge
%% without it; one whose IP checksum is wrong likewise.
merge_bad_checksum_test_() ->
    [fun() ->
         A = segment(1, 1000, 7, payload(1), #{bad => Bad}),
         B = segment(1, 2000, 7, payload(2)),
         C = segment(1, 3000, 7, payload(3)),
         ?assertEqual([summed(A), {merged, 2, summed(B), summed(C), [payload(2), payload(3)]}],
                      erx_bytes:tcp_merge([A, B, C]))
     end || Bad <- [tcp, ip]].

%% A wrong sum is believed as the copy's: a right frame given one is no candidate.
merge_believes_the_sum_test() ->
    A = segment(1, 1000, 7, payload(1)),
    {sum, S, _} = summed(A),
    B = segment(1, 2000, 7, payload(2)),
    ?assertEqual([{sum, S bxor 1, A}, summed(B)], erx_bytes:tcp_merge([{sum, S bxor 1, A}, B])).

%% A pure ACK whose acknowledgement does not move, a duplicate or a window update, is never
%% merged, after data nor as the first frame data would join; one that advances joins and is
%% counted, with no payload.
merge_pure_acks_test() ->
    Data = segment(1, 1000, 7, payload(1)),
    Dup = segment(1, 2000, 7, <<>>),
    Update = segment(1, 2000, 7, <<>>, #{win => 100}),
    More = segment(1, 2000, 7, payload(2)),
    ?assertEqual([summed(Data), summed(Dup)], erx_bytes:tcp_merge([Data, Dup])),
    ?assertEqual([summed(Data), summed(Update)], erx_bytes:tcp_merge([Data, Update])),
    ?assertEqual([summed(Dup), summed(More)], erx_bytes:tcp_merge([Dup, More])),
    Advance = segment(1, 2000, 9, <<>>),
    ?assertEqual([{merged, 2, summed(Data), summed(Advance), [payload(1)]}],
                 erx_bytes:tcp_merge([Data, Advance])),
    Later = segment(1, 2000, 9, payload(2)),
    ?assertEqual([{merged, 3, summed(Data), summed(Later), [payload(1), payload(2)]}],
                 erx_bytes:tcp_merge([Data, Advance, Later])).

%% An acknowledgement that goes back, a gap, a timestamp that goes back, a FIN and other
%% options each end the unit; the frame after a gap opens the next.
merge_breaks_test_() ->
    A = segment(1, 1000, 7, payload(1)),
    Breaks = [segment(1, 2000, 6, payload(2)),
              segment(1, 2001, 7, payload(2)),
              segment(1, 2000, 7, payload(2), #{options => {ts, 99, 5}}),
              segment(1, 2000, 7, payload(2), #{flags => 16#11}),
              segment(1, 2000, 7, payload(2), #{options => <<1, 1, 4, 2>>}),
              segment(1, 2000, 7, payload(2), #{options => none})],
    [?_assertEqual([summed(A), summed(B)], erx_bytes:tcp_merge([A, B])) || B <- Breaks].

%% A frame of another connection that differs only in its ports does not join; frames of two
%% connections interleaved each merge into their own unit, which stands where its first frame
%% stood; a FIN of a connection closes its unit, so the frames after it start another.
merge_connections_test() ->
    [A1, A2, A3] = [segment(1, 1000 * N, 7, payload(N)) || N <- [1, 2, 3]],
    [B1, B2] = [segment(2, 1000 * N, 7, payload(N + 10)) || N <- [1, 2]],
    ?assertEqual([{merged, 3, summed(A1), summed(A3), [payload(1), payload(2), payload(3)]},
                  {merged, 2, summed(B1), summed(B2), [payload(11), payload(12)]}],
                 erx_bytes:tcp_merge([A1, B1, A2, B2, A3])),
    Fin = segment(1, 2000, 7, <<>>, #{flags => 16#11}),
    After = segment(1, 2001, 7, payload(2)),
    Then = segment(1, 3001, 7, payload(3)),
    ?assertEqual([summed(A1), summed(Fin), {merged, 2, summed(After), summed(Then), [payload(2), payload(3)]}],
                 erx_bytes:tcp_merge([A1, Fin, After, Then])).

%% Eight units are open at once: a ninth connection closes the oldest, whose next frame then
%% opens a unit of its own.
merge_open_units_test() ->
    Firsts = [segment(Port, 1000, 7, payload(Port)) || Port <- lists:seq(1, 9)],
    Next = segment(1, 2000, 7, payload(20)),
    Units = erx_bytes:tcp_merge(Firsts ++ [Next]),
    ?assertEqual([summed(F) || F <- Firsts] ++ [summed(Next)], Units),
    ?assertMatch([{merged, 2, _, _, _} | _],
                 erx_bytes:tcp_merge(tl(Firsts) ++ [segment(2, 2000, 7, payload(20))])).

%% A 60-byte frame's padding is no payload: a pure ACK that advances joins with no piece.
%% IPv6 merges like IPv4, its traffic class standing for the type of service.
merge_padding_and_ipv6_test() ->
    A = segment(1, 1000, 7, payload(1), #{options => none}),
    Ack = segment(1, 2000, 9, <<>>, #{options => none, pad => true}),
    ?assertEqual(60, byte_size(Ack)),
    ?assertEqual([{merged, 2, summed(A), summed(Ack), [payload(1)]}], erx_bytes:tcp_merge([A, Ack])),
    Six = #{version => 6, src => <<1:128>>, dst => <<2:128>>},
    [C, D] = [segment(1, 1000 * N, 7, payload(N), Six) || N <- [1, 2]],
    ?assertEqual([{merged, 2, summed(C), summed(D), [payload(1), payload(2)]}], erx_bytes:tcp_merge([C, D])),
    E = segment(1, 3000, 7, payload(3), Six#{tos => 4}),
    ?assertEqual([{merged, 2, summed(C), summed(D), [payload(1), payload(2)]}, summed(E)],
                 erx_bytes:tcp_merge([C, D, E])).

%% A TCP data offset below 5, or past the segment, makes a frame no candidate: it is passed
%% on alone, and the unit before it is closed.
merge_bad_data_offset_test_() ->
    A = segment(1, 1000, 7, payload(1)),
    [?_assertEqual([summed(A), summed(B)], erx_bytes:tcp_merge([A, B]))
     || Off <- [0, 4, 15], B <- [segment(1, 2000, 7, <<1, 2, 3>>, #{off => Off, options => none})]].

%% A unit holds less than 65,280 bytes of payload, as FreeBSD's flushes at its length limit:
%% the frame that would reach it opens the next.
merge_unit_length_test() ->
    Jumbo = fun(N) -> segment(1, 9000 * N, 7, binary:copy(<<N>>, 9000)) end,
    Frames = [Jumbo(N) || N <- lists:seq(0, 7)],
    [{merged, 7, _, _, Pieces}, Alone] = erx_bytes:tcp_merge(Frames),
    ?assertEqual(63000, iolist_size(Pieces)),
    ?assertEqual(summed(lists:last(Frames)), Alone).

merge_unit_length_boundary_test() ->
    Piece = fun(Seq, Size) -> segment(1, Seq, 7, binary:copy(<<1>>, Size)) end,
    Three = [Piece(16000 * N, 16000) || N <- [0, 1, 2]],
    ?assertMatch([{merged, 4, _, _, _}], erx_bytes:tcp_merge(Three ++ [Piece(48000, 17279)])),
    ?assertMatch([{merged, 3, _, _, _}, {sum, _, _}], erx_bytes:tcp_merge(Three ++ [Piece(48000, 17280)])).

%% The limit: 256 frames, fewer than 65,536 bytes before the last and no frame over 65,536.
merge_limit_test() ->
    ?assertEqual({256, 65536}, erx_bytes:tcp_merge_limit()),
    Small = segment(1, 1000, 7, <<>>),
    ?assertEqual(256, length(erx_bytes:tcp_merge(lists:duplicate(256, Small)))),
    ?assertError(badarg, erx_bytes:tcp_merge(lists:duplicate(257, Small))),
    Big = binary:copy(<<0>>, 32768),
    ?assertEqual(3, length(erx_bytes:tcp_merge([Big, binary:part(Big, 0, 32767), binary:copy(<<0>>, 65536)]))),
    ?assertError(badarg, erx_bytes:tcp_merge([Big, Big, Small])),
    ?assertError(badarg, erx_bytes:tcp_merge([binary:copy(<<0>>, 65537)])),
    [?assertError(badarg, erx_bytes:tcp_merge(Bad))
     || Bad <- [Small, [Small | Small], [atom], [{sum, 16#10000, Small}], [{sum, -1, Small}],
                [{sum, 1, atom}], [{sum, 1}], [{csum, 1, Small}], [<<1:7>>]]].
