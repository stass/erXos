%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_net_sum (docs/design-network-stack.md, "Checksums in the copy"): the
%% sum span/4 derives from a packet's sum equals the sum erx_bytes:inet_csum/2 computes over
%% the same bytes, for every even start and every length, odd ones included; and add/2 and
%% sub/2 are one's-complement addition and subtraction. test/host/erx_net_input_test.rb runs
%% them with the seeded faults they exist to catch.

-module(erx_net_sum_tests).
-include_lib("eunit/include/eunit.hrl").

-define(ROUNDS, 3000).

%% One's-complement arithmetic is arithmetic modulo 16#ffff, where 0 and 16#ffff are the same.
same(A, B) -> A rem 16#ffff =:= B rem 16#ffff.

span_equals_the_sum_of_its_bytes_test() ->
    _ = rand:seed(exsss, {16#5, 16#a, 16#f}),
    [begin
         Packet = rand:bytes(rand:uniform(120) - 1),
         Size = byte_size(Packet),
         Start = 2 * (rand:uniform(Size div 2 + 1) - 1),
         Length = rand:uniform(Size - Start + 1) - 1,
         Sum = erx_bytes:inet_csum(0, Packet),
         Got = erx_net_sum:span(Packet, Sum, Start, Length),
         Want = erx_bytes:inet_csum(0, binary:part(Packet, Start, Length)),
         ?assert(is_integer(Got) andalso Got >= 0 andalso Got =< 16#ffff),
         ?assert(same(Got, Want), {Packet, Start, Length, Got, Want})
     end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

%% A packet's sum is nonzero once its first byte is, as an IP header's version makes it, and a
%% span derived from it is then nonzero too: its zero is written 16#ffff, the form a decoder
%% compares with.
span_of_a_nonzero_sum_is_never_zero_test() ->
    Packet = <<16#45, 0, 0, 0, 0, 0, 16#45, 0>>,
    Sum = erx_bytes:inet_csum(0, Packet),
    ?assertEqual(16#ffff, erx_net_sum:span(Packet, Sum, 0, 0)),
    ?assertEqual(16#ffff, erx_net_sum:span(Packet, Sum, 2, 4)).

%% The bytes after the span start at an odd offset when its length is odd, and the padding
%% after an IP packet is subtracted as seen from there.
span_after_an_odd_length_test() ->
    Packet = <<1, 2, 3, 4, 5, 6, 7>>,
    Sum = erx_bytes:inet_csum(0, Packet),
    ?assertEqual(erx_bytes:inet_csum(0, <<3, 4, 5>>), erx_net_sum:span(Packet, Sum, 2, 3)).

span_refusals_test() ->
    Packet = <<1, 2, 3, 4>>,
    ?assertError(badarg, erx_net_sum:span(Packet, 0, 1, 2)),
    ?assertError(badarg, erx_net_sum:span(Packet, 0, 2, 3)),
    ?assertError(badarg, erx_net_sum:span(Packet, 16#10000, 0, 2)),
    ?assertError(badarg, erx_net_sum:span(<<>>, 0, 0, 1)).

add_and_sub_test() ->
    ?assertEqual(16#0002, erx_net_sum:add(16#ffff, 16#0002)),
    ?assertEqual(erx_bytes:inet_csum(0, <<16#12, 16#34, 16#f0, 16#0f>>), erx_net_sum:add(16#1234, 16#f00f)),
    ?assertEqual(16#ffff, erx_net_sum:sub(16#1234, 16#1234)),
    ?assertEqual(16#1234, erx_net_sum:add(erx_net_sum:sub(16#1234, 16#abcd), 16#abcd)),
    ?assertEqual(16#ffff, erx_net_sum:add(16#ffff, 16#ffff)).
