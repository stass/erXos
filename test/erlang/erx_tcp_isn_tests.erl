%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_tcp_isn: tcp_keyed_hash's input layout and fold, the ISN clock, and the
%% per-connection timestamp offset.
-module(erx_tcp_isn_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ISN_KEY, <<0:64, 16#0123456789abcdef:64>>).
-define(TS_KEY, <<16#fedcba9876543210:64, 0:64>>).
-define(SECRET, erx_tcp_isn:secrets(?ISN_KEY, ?TS_KEY)).
-define(V4, {<<10, 0, 0, 1>>, 49152, <<192, 0, 2, 7>>, 80}).

%% The hash covers the foreign port, the local port, the foreign address and the local
%% address, in that order and in network byte order, as in_conninfo lays them out, and
%% folds the 64-bit digest's two halves with XOR; the ISN uses the ISN key and the offset
%% the timestamp key.
layout_test() ->
    {LAddr, LPort, FAddr, FPort} = ?V4,
    Fold = fun(Key) ->
                   Digest = erx_bytes:siphash24(Key, <<FPort:16, LPort:16, FAddr/binary, LAddr/binary>>),
                   (Digest bsr 32) bxor (Digest band 16#ffffffff)
           end,
    ?assertEqual(Fold(?ISN_KEY), erx_tcp_isn:isn(?SECRET, ?V4, 0)),
    ?assertEqual(Fold(?TS_KEY), erx_tcp_isn:ts_offset(?SECRET, ?V4)).

%% For one four-tuple the ISN advances with the microsecond clock, modulo 2^32; another
%% four-tuple or another secret gives an unrelated ISN.
clock_test() ->
    Base = erx_tcp_isn:isn(?SECRET, ?V4, 0),
    ?assertEqual((Base + 1000000) rem (1 bsl 32), erx_tcp_isn:isn(?SECRET, ?V4, 1000000)),
    ?assertEqual((Base + (1 bsl 32) - 5) rem (1 bsl 32), erx_tcp_isn:isn(?SECRET, ?V4, -5)),
    ?assertNotEqual(Base, erx_tcp_isn:isn(?SECRET, setelement(2, ?V4, 49153), 0)),
    ?assertNotEqual(Base, erx_tcp_isn:isn(erx_tcp_isn:secrets(<<1:128>>, ?TS_KEY), ?V4, 0)).

%% tcp_ts_offset_per_conn: the ports are hashed, so two connections between the same
%% hosts get different timestamp clocks; IPv6 four-tuples hash their 16-byte addresses.
ts_offset_test() ->
    ?assertNotEqual(erx_tcp_isn:ts_offset(?SECRET, ?V4),
                    erx_tcp_isn:ts_offset(?SECRET, setelement(4, ?V4, 443))),
    V6 = {<<16#fe80:16, 0:96, 1:16>>, 1, <<16#fe80:16, 0:96, 2:16>>, 2},
    ?assert(is_integer(erx_tcp_isn:ts_offset(?SECRET, V6))),
    ?assertError(function_clause, erx_tcp_isn:ts_offset(?SECRET, setelement(1, V6, <<10, 0, 0, 1>>))).

%% The two keys must be two draws: one key for both is refused.
secrets_test() ->
    ?assertError(function_clause, erx_tcp_isn:secrets(?ISN_KEY, ?ISN_KEY)).
