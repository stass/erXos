%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Known answers for erx_icmp4_wire: an echo request with a checksum summed by hand, and the
%% order in which the checks refuse a message that fails several. The fuzz target
%% (test/erlang/erx_icmp4_wire_fuzz.erl) covers the rest.
-module(erx_icmp4_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_icmp4_wire.hrl").

%% 16#0800 + 16#0001 + 16#0001 = 16#0802, whose complement is 16#F7FD.
known_echo_test() ->
    Message = <<8, 0, 16#F7, 16#FD, 0, 1, 0, 1>>,
    ?assertEqual({ok, #icmp4{type = ?ICMP_ECHO, code = 0, msg = {echo, 1, 1}}, <<>>},
                 erx_icmp4_wire:decode(Message)),
    ?assertEqual(Message, iolist_to_binary(erx_icmp4_wire:encode(#icmp4{type = 8, code = 0, msg = {echo, 1, 1}}, <<>>))).

%% A fragmentation-needed message quoting a 20-byte header and 8 bytes beyond it.
error_message(Code, Quote) ->
    iolist_to_binary(erx_icmp4_wire:encode(#icmp4{type = ?ICMP_UNREACH, code = Code, msg = {error, 1400}}, Quote)).

quote(Hl, Extra) -> <<4:4, Hl:4, 0:((Hl * 4 - 1) * 8), 0:(Extra * 8)>>.

error_checks_test() ->
    Full = quote(5, 8),
    ?assertEqual({ok, #icmp4{type = ?ICMP_UNREACH, code = 4, msg = {error, 1400}}, Full},
                 erx_icmp4_wire:decode(error_message(4, Full))),
    %% The code is checked before the length, and the quoted header length too.
    ?assertEqual({error, bad_code}, erx_icmp4_wire:decode(error_message(16, quote(5, 7)))),
    ?assertEqual({error, bad_length}, erx_icmp4_wire:decode(error_message(4, quote(5, 7)))),
    ?assertEqual({error, bad_length}, erx_icmp4_wire:decode(error_message(4, quote(4, 12)))),
    ?assertEqual({error, bad_length}, erx_icmp4_wire:decode(error_message(4, quote(6, 7)))).

%% The checksum is checked before any field but the length.
checksum_first_test() ->
    <<Head:2/binary, Sum:16, Rest/binary>> = error_message(16, quote(5, 0)),
    ?assertEqual({error, bad_sum}, erx_icmp4_wire:decode(<<Head/binary, (Sum bxor 1):16, Rest/binary>>)),
    ?assertEqual({error, too_short}, erx_icmp4_wire:decode(<<8, 0, 16#F7, 16#FD, 0, 1, 0>>)),
    ?assertEqual({error, too_short}, erx_icmp4_wire:decode(foo)),
    ?assertEqual({error, bad_length}, erx_icmp4_wire:decode(<<0:65536/unit:8>>)).
