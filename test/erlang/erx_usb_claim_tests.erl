%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_claim, the claim table and the endpoint parameters
%% (docs/design-usb.md, "What the USB domain claims" and "Descriptors"), over
%% configurations written with erx_usb_desc_tests' encoders and decoded by erx_usb_desc.
%% Every number is written out here, so a bound changed in abi/formats/usb.txt or
%% xhci.txt fails a case instead of moving with the module.
-module(erx_usb_claim_tests).

-include_lib("eunit/include/eunit.hrl").

-import(erx_usb_desc_tests, [device/3, configuration/1, interface/5, endpoint/4, companion/3,
                             hid/1]).

claim(Speed, Device, Bytes) ->
    {ok, D} = erx_usb_desc:device(Device),
    {ok, C} = erx_usb_desc:configuration(Bytes),
    erx_usb_claim:functions(Speed, D, C).

claim(Speed, Bytes) -> claim(Speed, device(0, 0, 0), Bytes).

%% The parameters of one endpoint descriptor, with its companion if given.
parameters(Speed, Descriptors) ->
    {ok, #{settings := #{{0, 0} := #{endpoints := [Endpoint]}}}} =
        erx_usb_desc:configuration(configuration([interface(0, 0, 16#ff, 0, 0) | Descriptors])),
    erx_usb_claim:parameters(Speed, Endpoint).

pipe(Speed, Descriptors) ->
    {ok, Pipe} = parameters(Speed, Descriptors),
    maps:with([packet_size, burst, payload], Pipe).

the_boot_keyboard_runs_a_hid_function_on_its_interrupt_endpoint_test() ->
    ?assertMatch({ok, [#{driver := erx_usb_hid, interface := 0, alternate := 0,
                         setting := #{class := 3, hid := #{}},
                         pipes := [#{address := 16#81, type := interrupt, packet_size := 8,
                                     burst := 0, payload := 8, interval_exponent := 6}]}]},
                 claim(low, erx_usb_desc_tests:boot_keyboard())),
    ?assertMatch({ok, [#{driver := erx_usb_hid}]}, claim(full, erx_usb_desc_tests:tablet())).

mass_storage_takes_its_first_bulk_in_and_first_bulk_out_endpoint_test() ->
    ?assertMatch({ok, [#{driver := erx_usb_bot, interface := 0, alternate := 0,
                         pipes := [#{address := 16#81, type := bulk, packet_size := 512, burst := 0,
                                     payload := 512},
                                   #{address := 16#02, type := bulk, packet_size := 512}]}]},
                 claim(high, erx_usb_desc_tests:storage())),
    ?assertEqual({ok, []}, claim(high, configuration([interface(0, 0, 8, 6, 16#50),
                                                      endpoint(16#81, 2, 512, 0)]))),
    ?assertEqual({ok, []}, claim(high, configuration([interface(0, 0, 8, 6, 16#62),
                                                      endpoint(16#81, 2, 512, 0),
                                                      endpoint(16#02, 2, 512, 0)]))).

%% A device whose quirks force SCSI or Bulk-Only has a mass-storage interface of another
%% subclass or protocol taken as such, and its functions carry its quirks; without them the
%% interface runs none. 0411:001c is FreeBSD's MELCO DUBPXXG (usb_quirk.c:308-309,
%% usbdevs:97 and :3273); 0451:5416 at release 0100h is the Linux facts record's, which
%% forces Bulk-Only alone, so an ATAPI interface of it stays unclaimed.
quirks_force_a_mass_storage_interface_test() ->
    Atapi = configuration([interface(0, 0, 8, 5, 0), endpoint(16#81, 2, 512, 0), endpoint(16#02, 2, 512, 0)]),
    Cbi = configuration([interface(0, 0, 8, 6, 0), endpoint(16#81, 2, 512, 0), endpoint(16#02, 2, 512, 0)]),
    ?assertMatch({ok, [#{driver := erx_usb_bot, quirks := [force_bot, force_scsi, ignore_residue]}]},
                 claim(high, device_of(16#0411, 16#001c), Atapi)),
    ?assertEqual({ok, []}, claim(high, Atapi)),
    ?assertMatch({ok, [#{driver := erx_usb_bot, quirks := [force_bot]}]},
                 claim(high, device_of(16#0451, 16#5416), Cbi)),
    ?assertEqual({ok, []}, claim(high, device_of(16#0451, 16#5416), Atapi)),
    ?assertEqual({ok, []}, claim(high, Cbi)).

%% A device descriptor of Vendor and Product, otherwise device(0, 0, 0)'s, release 0100h.
device_of(Vendor, Product) ->
    <<Head:8/binary, _Ids:4/binary, Tail/binary>> = device(0, 0, 0),
    <<Head/binary, Vendor:16/little, Product:16/little, Tail/binary>>.

a_multi_tt_hub_selects_its_alternate_setting_1_test() ->
    Hub = erx_usb_desc_tests:hub_multi_tt(),
    ?assertMatch({ok, [#{driver := erx_usb_hub, alternate := 1, setting := #{protocol := 2},
                         pipes := [#{address := 16#81, packet_size := 1, payload := 1}]}]},
                 claim(high, device(9, 0, 2), Hub)),
    ?assertMatch({ok, [#{driver := erx_usb_hub, alternate := 0, setting := #{protocol := 1}}]},
                 claim(high, device(9, 0, 1), Hub)),
    ?assertEqual({error, missing_setting},
                 claim(high, device(9, 0, 2), configuration([interface(0, 0, 9, 0, 1),
                                                             endpoint(16#81, 3, 1, 12)]))).

%% FreeBSD's rule: a hub is a device of class 09h, and its one function runs on
%% interface 0 whatever that interface's class; an interface of class 09h on another
%% device is no hub.
a_hub_device_runs_one_hub_function_on_interface_0_test() ->
    Two = configuration([interface(0, 0, 9, 0, 0), endpoint(16#81, 3, 1, 12),
                         interface(1, 0, 9, 0, 0), endpoint(16#82, 3, 1, 12)]),
    ?assertMatch({ok, [#{driver := erx_usb_hub, interface := 0}]}, claim(full, device(9, 0, 0), Two)),
    ?assertMatch({ok, [#{driver := erx_usb_hub, interface := 0}]},
                 claim(high, device(9, 0, 1), configuration([interface(0, 0, 16#ff, 0, 0),
                                                             endpoint(16#81, 3, 1, 12)]))),
    ?assertEqual({ok, []}, claim(full, device(0, 0, 0), Two)),
    ?assertEqual({ok, []}, claim(high, device(16#ef, 2, 1), erx_usb_desc_tests:hub_multi_tt())),
HidBeside = configuration([interface(0, 0, 3, 1, 1), hid(63), endpoint(16#81, 3, 8, 10),
                           interface(1, 0, 3, 1, 1), hid(63), endpoint(16#82, 3, 8, 10)]),
?assertMatch({ok, [#{driver := erx_usb_hub, interface := 0}, #{driver := erx_usb_hid, interface := 1}]},
             claim(full, device(9, 0, 0), HidBeside)),
?assertMatch({ok, [#{driver := erx_usb_hid, interface := 1}]}, claim(low, device(9, 0, 0), HidBeside)).

a_superspeed_hub_runs_no_function_test() ->
    Hub = configuration([interface(0, 0, 9, 0, 0), endpoint(16#81, 3, 2, 8), companion(0, 0, 2)]),
    ?assertEqual({ok, []}, claim(super, device(9, 0, 3), Hub)).

a_composite_device_runs_one_function_an_interface_test() ->
    Bytes = configuration([interface(0, 0, 3, 1, 1), hid(63), endpoint(16#81, 3, 8, 10),
                           interface(1, 0, 16#ff, 0, 0), endpoint(16#83, 2, 64, 0),
                           interface(2, 0, 8, 6, 16#50), endpoint(16#82, 2, 64, 0),
                           endpoint(16#02, 2, 64, 0)]),
    ?assertMatch({ok, [#{driver := erx_usb_hid, interface := 0},
                       #{driver := erx_usb_bot, interface := 2}]},
                 claim(full, Bytes)).

an_interface_without_the_endpoint_its_function_needs_runs_none_test() ->
    ?assertEqual({ok, []}, claim(full, configuration([interface(0, 0, 3, 0, 0), endpoint(16#01, 3, 8, 1),
                                                      endpoint(16#82, 2, 64, 0)]))),
    ?assertEqual({ok, []}, claim(full, configuration([interface(0, 1, 3, 0, 0),
                                                      endpoint(16#81, 3, 8, 1)]))).

no_endpoint_belongs_to_two_functions_test() ->
    Twice = configuration([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1),
                           interface(1, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1)]),
    ?assertEqual({error, duplicate_endpoint}, claim(full, Twice)),
    ?assertEqual({error, duplicate_endpoint},
                 claim(full, configuration([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1),
                                            endpoint(16#81, 3, 8, 1)]))),
    ?assertMatch({ok, [_]}, claim(full, configuration([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1),
                                                       interface(1, 0, 16#ff, 0, 0),
                                                       endpoint(16#81, 3, 8, 1)]))),
    ?assertMatch({ok, [_, _]}, claim(full, configuration([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1),
                                                          interface(1, 0, 3, 0, 0),
                                                          endpoint(16#82, 3, 8, 1)]))).

a_device_uses_at_most_8_endpoints_with_ep0_test() ->
    Hids = fun(N) -> configuration([[interface(I, 0, 3, 0, 0), endpoint(16#80 + I, 3, 8, 1)]
                                    || I <- lists:seq(1, N)]) end,
    ?assertMatch({ok, [_, _, _, _, _, _, _]}, claim(full, Hids(7))),
    ?assertEqual({error, too_many_endpoints}, claim(full, Hids(8))).

every_endpoint_has_its_companion_at_superspeed_test() ->
    ?assertEqual({error, missing_companion},
                 claim(super, configuration([interface(0, 0, 3, 0, 0), endpoint(16#81, 3, 8, 1)]))),
    ?assertEqual({error, missing_companion},
                 claim(super, configuration([interface(0, 0, 16#ff, 0, 0), endpoint(16#81, 3, 8, 1)]))),
    ?assertEqual({error, missing_companion}, parameters(super, [endpoint(16#81, 3, 8, 1)])),
    ?assertMatch({ok, [_]}, claim(super, erx_usb_desc_tests:ss_interrupt(8))).

%% The design's fixture: the payload is the companion's, not the product.
a_superspeed_interrupt_payload_is_the_companions_bytes_per_interval_test() ->
    ?assertMatch({ok, [#{pipes := [#{packet_size := 64, burst := 0, payload := 8}]}]},
                 claim(super, erx_usb_desc_tests:ss_interrupt(8))),
    ?assertEqual({error, zero_interval_payload}, claim(super, erx_usb_desc_tests:ss_interrupt(0))),
    ?assertEqual({error, endpoint_too_large}, claim(super, erx_usb_desc_tests:ss_interrupt(65))),
    ?assertMatch({ok, [#{pipes := [#{payload := 64}]}]}, claim(super, erx_usb_desc_tests:ss_interrupt(64))),
    ?assertEqual(#{packet_size => 1024, burst => 2, payload => 1000},
                 maps:with([packet_size, burst, payload],
                           element(2, erx_usb_claim:parameters(super, #{address => 16#81, type => interrupt,
                                                                         max_packet => 1024, interval => 1,
                                                                         companion => #{max_burst => 2, attributes => 0,
                                                                                        bytes_per_interval => 1000}})))),
    ?assertEqual({error, endpoint_too_large}, parameters(super, [endpoint(16#81, 3, 1024, 1), companion(2, 0, 3072)])),
    ?assertEqual({error, endpoint_too_large}, parameters(super, [endpoint(16#81, 3, 1024, 1), companion(2, 0, 3073)])).

%% Below SuperSpeed the payload is the packet size times the burst plus one.
a_high_speed_interrupt_payload_counts_every_transaction_test() ->
    ?assertEqual(#{packet_size => 512, burst => 1, payload => 1024},
                 pipe(high, [endpoint(16#81, 3, 512 bor (1 bsl 11), 1)])),
    ?assertEqual({error, endpoint_too_large}, parameters(high, [endpoint(16#81, 3, 1024 bor (1 bsl 11), 1)])),
    ?assertEqual(#{packet_size => 1024, burst => 0, payload => 1024},
                 pipe(high, [endpoint(16#81, 3, 1024, 1)])),
    ?assertEqual({error, malformed_descriptor}, parameters(high, [endpoint(16#81, 3, 8 bor (3 bsl 11), 1)])),
    ?assertEqual(#{packet_size => 512, burst => 0, payload => 512},
                 pipe(high, [endpoint(16#81, 2, 512 bor (1 bsl 11), 0)])),
    ?assertEqual(#{packet_size => 64, burst => 0, payload => 64},
                 pipe(full, [endpoint(16#81, 3, 64 bor (2 bsl 11), 1)])).

packet_sizes_follow_freebsds_filter_test() ->
    Interrupt = fun(Speed, Size) -> maps:get(packet_size, pipe(Speed, [endpoint(16#81, 3, Size, 1)])) end,
    ?assertEqual([8, 8, 1], [Interrupt(low, S) || S <- [64, 8, 1]]),
    ?assertEqual([64, 64, 63], [Interrupt(full, S) || S <- [1023, 64, 63]]),
    ?assertEqual([1024, 1024, 100], [Interrupt(high, S) || S <- [16#7ff, 1024, 100]]),
    Bulk = fun(Speed, Size) -> maps:get(packet_size, pipe(Speed, [endpoint(16#81, 2, Size, 0)])) end,
    ?assertEqual([8, 8, 8, 16, 16, 32, 32, 64, 64, 64],
                 [Bulk(full, S) || S <- [1, 7, 15, 16, 31, 32, 63, 64, 100, 16#7ff]]),
    ?assertEqual([8, 8], [Bulk(low, S) || S <- [1, 64]]),
    ?assertEqual({error, zero_interval_payload}, parameters(full, [endpoint(16#81, 2, 16#800, 0)])),
    ?assertEqual([512, 512], [Bulk(high, S) || S <- [64, 1024]]),
    ?assertEqual(1024, maps:get(packet_size, pipe(super, [endpoint(16#81, 2, 512, 0), companion(0, 0, 0)]))),
    ?assertEqual({error, zero_interval_payload}, parameters(full, [endpoint(16#81, 3, 0, 1)])).

a_superspeed_burst_is_the_companions_up_to_15_test() ->
    ?assertEqual(#{packet_size => 1024, burst => 15, payload => 16384},
                 pipe(super, [endpoint(16#81, 2, 1024, 0), companion(15, 0, 0)])),
    ?assertEqual({error, malformed_descriptor}, parameters(super, [endpoint(16#81, 2, 1024, 0), companion(16, 0, 0)])),
    ?assertEqual(#{packet_size => 1024, burst => 0, payload => 1024},
                 pipe(super, [endpoint(16#81, 2, 1024 bor (2 bsl 11), 0), companion(0, 0, 0)])).

%% xHCI's Interval (Table 6-12): milliseconds rounded down to a power of two of 125 us
%% at low and full speed, 2^(bInterval-1) microframes above, 0 on a bulk endpoint.
the_interval_exponent_follows_xhcis_table_test() ->
    Exponent = fun(Speed, Type, Interval) ->
                       Companion = [companion(0, 0, 8) || Speed =:= super],
                       {ok, #{interval_exponent := E}} =
                           parameters(Speed, [endpoint(16#81, Type, 8, Interval) | Companion]),
                       E
               end,
    ?assertEqual([3, 4, 4, 5, 6, 10, 10], [Exponent(full, 3, I) || I <- [1, 2, 3, 4, 10, 128, 255]]),
    ?assertEqual([3, 6], [Exponent(low, 3, I) || I <- [1, 10]]),
    ?assertEqual([0, 3, 15], [Exponent(high, 3, I) || I <- [1, 4, 16]]),
    ?assertEqual([0, 15], [Exponent(super, 3, I) || I <- [1, 16]]),
    ?assertEqual([0, 0, 0], [Exponent(high, 2, I) || I <- [0, 17, 255]]),
    ?assertEqual({error, malformed_descriptor}, parameters(full, [endpoint(16#81, 3, 8, 0)])),
    ?assertEqual({error, malformed_descriptor}, parameters(high, [endpoint(16#81, 3, 8, 0)])),
    ?assertEqual({error, malformed_descriptor}, parameters(high, [endpoint(16#81, 3, 8, 17)])),
    ?assertEqual({error, malformed_descriptor}, parameters(super, [endpoint(16#81, 3, 8, 17), companion(0, 0, 8)])).
