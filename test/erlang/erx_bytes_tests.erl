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
