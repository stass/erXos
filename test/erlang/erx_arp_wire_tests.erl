%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Known answers for erx_arp_wire and erx_net_eth: a captured ARP request in its Ethernet
%% frame, with its padding, and the order in which the ARP checks refuse a packet. The fuzz
%% targets cover the rest.
-module(erx_arp_wire_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_arp_wire.hrl").
-include("erx_net_eth.hrl").

%% Who has 10.0.2.2? Tell 10.0.2.15: QEMU's user network, padded to Ethernet's 60 bytes.
-define(FRAME, <<16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#52, 16#54, 0, 16#12, 16#34, 16#56,
                 16#08, 16#06,
                 0, 1, 16#08, 0, 6, 4, 0, 1,
                 16#52, 16#54, 0, 16#12, 16#34, 16#56, 10, 0, 2, 15,
                 0, 0, 0, 0, 0, 0, 10, 0, 2, 2,
                 0:144>>).

request_in_frame_test() ->
    {ok, Eth, Payload} = erx_net_eth:decode(?FRAME),
    ?assertEqual(#eth{dst = <<16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>,
                      src = <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>, type = ?ETHERTYPE_ARP}, Eth),
    {ok, Arp, Padding} = erx_arp_wire:decode(Payload),
    ?assertEqual(#arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST,
                      sha = <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>, spa = <<10, 0, 2, 15>>,
                      tha = <<0:48>>, tpa = <<10, 0, 2, 2>>}, Arp),
    ?assertEqual(<<0:144>>, Padding),
    ?assertEqual(?FRAME, <<(erx_net_eth:encode(Eth))/binary, (erx_arp_wire:encode(Arp))/binary, Padding/binary>>),
    ?assertEqual({error, too_short}, erx_net_eth:decode(binary:part(?FRAME, 0, 13))).

%% arpintr's order: the length the header announces first, then the hardware, then the
%% protocol; a packet failing several is refused for the first.
refusal_order_test() ->
    Packet = fun(Hrd, Pro, Hln, Pln, Length) ->
                 binary:part(<<Hrd:16, Pro:16, Hln, Pln, 1:16, 0:(8 * 600)>>, 0, Length)
             end,
    ?assertEqual({error, too_short}, erx_arp_wire:decode(<<0, 1, 8, 0, 6, 4, 0>>)),
    ?assertEqual({error, too_short}, erx_arp_wire:decode(Packet(99, 99, 6, 4, 27))),
    ?assertEqual({error, too_short}, erx_arp_wire:decode(Packet(1, 16#0800, 255, 4, 200))),
    ?assertEqual({error, bad_hardware}, erx_arp_wire:decode(Packet(99, 99, 6, 4, 28))),
    ?assertEqual({error, bad_hardware}, erx_arp_wire:decode(Packet(1, 99, 8, 4, 32))),
    ?assertEqual({error, bad_protocol}, erx_arp_wire:decode(Packet(?ARPHRD_IEEE802, 16#86DD, 6, 4, 28))),
    ?assertEqual({error, bad_protocol}, erx_arp_wire:decode(Packet(1, 16#0800, 6, 16, 52))),
    ?assertMatch({ok, #arp{hrd = ?ARPHRD_IEEE802}, <<>>}, erx_arp_wire:decode(Packet(6, 16#0800, 6, 4, 28))).
