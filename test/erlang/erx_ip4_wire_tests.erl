%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Known answers for erx_ip4_wire: a header with a published checksum, the order in which
%% the checks refuse a packet that fails several, the options walk, and the cut at the total
%% length. The fuzz target (test/erlang/erx_ip4_wire_fuzz.erl) covers the rest.
-module(erx_ip4_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip4_wire.hrl").

%% 192.168.0.1 to 192.168.0.199, UDP, DF, total length 115: the example header of
%% RFC 1071's usual illustrations, whose checksum is 16#B861.
-define(HEADER, <<16#45, 0, 0, 16#73, 0, 0, 16#40, 0, 16#40, 16#11, 16#B8, 16#61,
                  192, 168, 0, 1, 192, 168, 0, 199>>).

payload(Length) -> binary:copy(<<16#AB>>, Length).

known_header_test() ->
    Payload = payload(95),
    {ok, Ip4, Payload} = erx_ip4_wire:decode(<<?HEADER/binary, Payload/binary, 0, 0, 0>>),
    ?assertEqual(#ip4{tos = 0, len = 115, id = 0, rf = 0, df = 1, mf = 0, off = 0, ttl = 64, p = 17,
                      src = <<192, 168, 0, 1>>, dst = <<192, 168, 0, 199>>, options = <<>>}, Ip4),
    ?assertEqual(?HEADER, erx_ip4_wire:encode(Ip4)).

%% A header that fails both its checksum and its total length is a bad checksum: the sum is
%% checked before any field but the version and header length.
checksum_before_length_test() ->
    <<Head:2/binary, _Len:16, Mid:6/binary, Sum:16, Tail/binary>> = ?HEADER,
    BadLength = <<Head/binary, 19:16, Mid/binary, Sum:16, Tail/binary>>,
    ?assertEqual({error, bad_sum}, erx_ip4_wire:decode(BadLength)),
    ?assertEqual({error, bad_sum}, erx_ip4_wire:decode(<<Head/binary, 115:16, Mid/binary, (Sum + 1):16, Tail/binary>>)).

refusals_test() ->
    Base = #ip4{len = 24, ttl = 1, p = 6, src = <<10, 0, 0, 1>>, dst = <<10, 0, 0, 2>>},
    Header = erx_ip4_wire:encode(Base),
    <<_:4, Rest/bitstring>> = Header,
    ?assertEqual({error, too_short}, erx_ip4_wire:decode(binary:part(Header, 0, 19))),
    ?assertEqual({error, bad_vers}, erx_ip4_wire:decode(<<6:4, Rest/bitstring>>)),
    ?assertEqual({error, bad_hlen}, erx_ip4_wire:decode(<<4:4, 4:4, (binary:part(Header, 1, 19))/binary>>)),
    ?assertEqual({error, bad_hlen}, erx_ip4_wire:decode(<<4:4, 6:4, (binary:part(Header, 1, 19))/binary>>)),
    ?assertEqual({error, too_short}, erx_ip4_wire:decode(<<Header/binary, 1, 2, 3>>)),
    ?assertEqual({error, bad_len}, erx_ip4_wire:decode(with_len(Header, 19))),
    ?assertMatch({ok, _, <<1, 2, 3, 4>>}, erx_ip4_wire:decode(<<Header/binary, 1, 2, 3, 4, 5>>)).

%% A 28-byte header from 10.0.0.1 to 10.0.0.2 with Options, which encode/1 would refuse when
%% malformed, and its checksum.
raw(Options) ->
    Zero = <<4:4, 7:4, 0, 28:16, 0:32, 1, 6, 0:16, 10, 0, 0, 1, 10, 0, 0, 2, Options/binary>>,
    <<Head:10/binary, 0:16, Tail/binary>> = Zero,
    <<Head/binary, (bnot erx_bytes:inet_csum(0, Zero) band 16#FFFF):16, Tail/binary>>.

%% Header with its total length field replaced and its checksum recomputed.
with_len(Header, Len) ->
    <<Head:2/binary, _:16, Mid:6/binary, _:16, Tail/binary>> = Header,
    Zero = <<Head/binary, Len:16, Mid/binary, 0:16, Tail/binary>>,
    Sum = bnot erx_bytes:inet_csum(0, Zero) band 16#FFFF,
    <<Head/binary, Len:16, Mid/binary, Sum:16, Tail/binary>>.

options_test() ->
    Base = #ip4{len = 28, ttl = 1, p = 6, src = <<10, 0, 0, 1>>, dst = <<10, 0, 0, 2>>},
    Decode = fun(Options) -> erx_ip4_wire:decode(raw(Options)) end,
    {ok, Ip4, <<>>} = Decode(<<?IPOPT_NOP, ?IPOPT_RR, 3, 4, ?IPOPT_EOL, 99, 99, 99>>),
    ?assertEqual([{?IPOPT_RR, <<4>>}], erx_ip4_wire:options(Ip4)),
    {ok, Lsrr, <<>>} = Decode(<<?IPOPT_LSRR, 7, 4, 10, 0, 0, 3, ?IPOPT_EOL>>),
    ?assertEqual([{?IPOPT_LSRR, <<4, 10, 0, 0, 3>>}], erx_ip4_wire:options(Lsrr)),
    %% A length past the header, a length below 2, and a type with no length byte, each
    %% refused with the offset of its length byte, as ip_dooptions points at it.
    ?assertEqual({error, {bad_options, 21}}, Decode(<<?IPOPT_RR, 9, 4, 0, 0, 0, 0, 0>>)),
    ?assertEqual({error, {bad_options, 22}}, Decode(<<?IPOPT_NOP, ?IPOPT_TS, 1, 0, 0, 0, 0, 0>>)),
    ?assertEqual({error, {bad_options, 28}}, Decode(<<?IPOPT_NOP, ?IPOPT_NOP, ?IPOPT_NOP, ?IPOPT_NOP,
                                                    ?IPOPT_NOP, ?IPOPT_NOP, ?IPOPT_NOP, ?IPOPT_RR>>)),
    ?assertError({badmatch, _}, erx_ip4_wire:encode(Base#ip4{options = <<?IPOPT_RR, 9, 0, 0>>})).
