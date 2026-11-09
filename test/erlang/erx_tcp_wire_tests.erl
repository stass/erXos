%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Known answers for erx_tcp_wire where it follows FreeBSD rather than a plain reading of the
%% RFC: the options a SYN alone may carry, the window-scale clamp, a malformed option ending
%% the walk, the refusals, and tcp_addoptions' byte layout. The fuzz target
%% (test/erlang/erx_tcp_wire_fuzz.erl) covers totality, round trips and the rest.
-module(erx_tcp_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_tcp_wire.hrl").

-define(SRC, <<10, 0, 0, 1>>).
-define(DST, <<10, 0, 0, 2>>).

pseudo(Len) -> erx_ip4_wire:pseudo_sum(?SRC, ?DST, Len, 6).

%% A segment with the options bytes given (a multiple of 4) and Flags, its checksum right.
segment(Flags, Options, Payload) ->
    Off = 5 + byte_size(Options) div 4,
    Len = Off * 4 + byte_size(Payload),
    Head = <<1000:16, 80:16, 1:32, 2:32, Off:4, Flags:12, 65535:16>>,
    Tail = <<0:16, Options/binary, Payload/binary>>,
    Sum = bnot erx_bytes:inet_csum(pseudo(Len), [Head, <<0:16>>, Tail]) band 16#ffff,
    <<Head/binary, Sum:16, Tail/binary>>.

decode(Segment) -> erx_tcp_wire:decode(pseudo(byte_size(Segment)), Segment).

opts({ok, #tcp{opts = Opts}, _}) -> Opts.

-define(SYN_OPTIONS, <<2, 4, 5, 180, 1, 3, 3, 15, 4, 2, 8, 10, 0:32, 7:32, 5, 10, 1:32, 2:32, 0, 0>>).

%% MSS, window scale and SACK-permitted count on a SYN, the scale clamped to 14; SACK blocks
%% do not. On a segment without SYN it is the other way round. Timestamps count on both.
syn_rule_test() ->
    ?assertEqual(#tcp_opts{mss = 1460, wscale = 14, sack_permitted = true, ts = {0, 7}},
                 opts(decode(segment(?TH_SYN, ?SYN_OPTIONS, <<>>)))),
    ?assertEqual(#tcp_opts{ts = {0, 7}, sacks = [{1, 2}]},
                 opts(decode(segment(?TH_ACK, ?SYN_OPTIONS, <<>>)))).

%% A zero length byte ends the walk: the timestamp before it is kept, the MSS after it is not.
malformed_option_ends_walk_test() ->
    Options = <<8, 10, 3:32, 4:32, 77, 0, 2, 4, 5, 180, 0, 0, 0, 0>>,
    ?assertEqual(#tcp_opts{ts = {3, 4}}, opts(decode(segment(?TH_SYN, Options, <<>>)))).

refusals_test() ->
    Good = segment(?TH_ACK, <<>>, <<"data">>),
    <<Front:12/binary, _:4, Back/bitstring>> = Good,
    ?assertEqual({error, too_short}, decode(binary:part(Good, 0, 19))),
    ?assertEqual({error, bad_sum}, erx_tcp_wire:decode(pseudo(byte_size(Good)) bxor 1, Good)),
    %% A data offset of 4 words, and one of 15 past the 24 bytes delivered; the checksum is
    %% fixed up for the changed byte, so the offset check is what refuses them.
    [?assertEqual({error, bad_off}, decode(fix_sum(<<Front/binary, Off:4, Back/bitstring>>))) || Off <- [4, 15]].

fix_sum(<<Head:16/binary, _:16, Tail/binary>>) ->
    Sum = bnot erx_bytes:inet_csum(pseudo(byte_size(Head) + 2 + byte_size(Tail)), [Head, <<0:16>>, Tail]) band 16#ffff,
    <<Head/binary, Sum:16, Tail/binary>>.

%% tcp_addoptions' layouts: a SYN's MSS, NOP and window scale, SACK-permitted and timestamps
%% in 20 bytes; a segment's NOP NOP timestamps, then NOP NOP SACK with the three blocks of
%% four that fit; each encodes and decodes back.
addoptions_layout_test() ->
    Syn = #tcp{sport = 1000, dport = 80, seq = 1, ack = 0, flags = ?TH_SYN, win = 65535, urp = 0,
               opts = #tcp_opts{mss = 1460, wscale = 7, sack_permitted = true, ts = {5, 0}}},
    ?assertMatch(<<_:12/binary, 16#a0, _:7/binary, 2, 4, 5, 180, 1, 3, 3, 7, 4, 2, 8, 10, 5:32, 0:32>>,
                 encoded(Syn)),
    Blocks = [{N, N + 1} || N <- [10, 20, 30, 40]],
    Ack = Syn#tcp{flags = ?TH_ACK, opts = #tcp_opts{ts = {5, 6}, sacks = Blocks}},
    ?assertMatch(<<_:12/binary, 16#f0, _:7/binary, 1, 1, 8, 10, 5:32, 6:32, 1, 1, 5, 26,
                   10:32, 11:32, 20:32, 21:32, 30:32, 31:32>>,
                 encoded(Ack)),
    ?assertEqual({ok, Syn, <<>>}, decode(encoded(Syn))),
    ?assertEqual({ok, Ack#tcp{opts = #tcp_opts{ts = {5, 6}, sacks = lists:sublist(Blocks, 3)}}, <<>>},
                 decode(encoded(Ack))).

encoded(Tcp) -> iolist_to_binary(erx_tcp_wire:encode(Tcp, <<>>, pseudo(0))).
