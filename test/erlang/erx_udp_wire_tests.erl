%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Known answers for erx_udp_wire: a datagram with a checksum summed by hand, the IPv4
%% datagram shorter than its IP payload, a zero checksum, the refusals, and the IPv6 rules. The fuzz target
%% (test/erlang/erx_udp_wire_fuzz.erl) covers the rest.
-module(erx_udp_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_udp_wire.hrl").

-define(SRC, <<10, 0, 0, 1>>).
-define(DST, <<10, 0, 0, 2>>).

pseudo(Len) -> erx_ip4_wire:pseudo_sum(?SRC, ?DST, Len, 17).

%% Pseudo-header 16#0A00 + 16#0001 + 16#0A00 + 16#0002 + 16#0011 + 16#0008 and header
%% 16#0001 + 16#0002 + 16#0008 sum to 16#1427, whose complement is 16#EBD8.
known_datagram_test() ->
    Datagram = <<0, 1, 0, 2, 0, 8, 16#EB, 16#D8>>,
    ?assertEqual({ok, #udp{sport = 1, dport = 2}, <<>>}, erx_udp_wire:decode(inet, pseudo(8), Datagram)),
    ?assertEqual(Datagram, iolist_to_binary(erx_udp_wire:encode(#udp{sport = 1, dport = 2}, <<>>, pseudo(0)))).

%% IPv4 delivers more bytes than the UDP length: udp_input cuts them and sums the
%% pseudo-header with the UDP length, while the caller summed it over what it delivered.
trailing_bytes_test() ->
    Datagram = iolist_to_binary(erx_udp_wire:encode(#udp{sport = 53, dport = 5353}, <<"abc">>, pseudo(0))),
    ?assertEqual({ok, #udp{sport = 53, dport = 5353}, <<"abc">>},
                 erx_udp_wire:decode(inet, pseudo(15), <<Datagram/binary, 1, 2, 3, 4>>)).

refusals_test() ->
    Good = iolist_to_binary(erx_udp_wire:encode(#udp{sport = 1, dport = 2}, <<"x">>, pseudo(0))),
    <<Ports:4/binary, _:16, Sum:16, X>> = Good,
    ?assertEqual({error, too_short}, erx_udp_wire:decode(inet, pseudo(7), binary:part(Good, 0, 7))),
    ?assertEqual({error, too_short}, erx_udp_wire:decode(inet, 0, foo)),
    ?assertEqual({error, bad_len}, erx_udp_wire:decode(inet, 0, <<Good/binary, 0:(65536 - 9)/unit:8>>)),
    ?assertEqual({error, bad_len}, erx_udp_wire:decode(inet, pseudo(9), <<Ports/binary, 7:16, Sum:16, X>>)),
    ?assertEqual({error, bad_len}, erx_udp_wire:decode(inet, pseudo(9), <<Ports/binary, 10:16, Sum:16, X>>)),
    ?assertEqual({error, bad_sum}, erx_udp_wire:decode(inet, pseudo(9), <<Ports/binary, 9:16, (Sum bxor 1):16, X>>)),
    %% A zero checksum is no checksum, and port 0 is refused after it.
    ?assertEqual({ok, #udp{sport = 1, dport = 2}, <<"x">>},
                 erx_udp_wire:decode(inet, pseudo(9), <<Ports/binary, 9:16, 0:16, X>>)),
    ?assertEqual({error, bad_port}, erx_udp_wire:decode(inet, pseudo(9), <<0, 1, 0, 0, 9:16, 0:16, X>>)).

%% Over IPv6 the UDP length must be the payload length and a checksum must be present; both
%% are refused before the sum is read.
ip6_rules_test() ->
    Good = iolist_to_binary(erx_udp_wire:encode(#udp{sport = 1, dport = 2}, <<"x">>, pseudo(0))),
    <<Head:6/binary, _:16, X>> = Good,
    ?assertEqual({error, bad_len}, erx_udp_wire:decode(inet6, 0, <<Good/binary, 0>>)),
    ?assertEqual({error, no_sum}, erx_udp_wire:decode(inet6, 0, <<Head/binary, 0:16, X>>)),
    ?assertEqual({error, bad_sum}, erx_udp_wire:decode(inet6, 0, Good)).
