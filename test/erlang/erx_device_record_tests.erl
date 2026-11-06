%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_device_record:find/3, the parse of the device records from the boot
%% information. Each malformed form ends in a stated reason, never in an exception.
%% test/host/erx_device_record_test.rb runs them on stock's emulator.

-module(erx_device_record_tests).
-include_lib("eunit/include/eunit.hrl").

-define(U64_MAX, "18446744073709551615").
-define(U32_MAX, "4294967295").

find(Arguments) ->
    erx_device_record:find(block, virtio_mmio, Arguments).

spec(Base, Size, Line, Dma) ->
    #{peripheral => virtio_mmio, window => {physical, Base, Size}, lines => [Line], dma_memory => Dma}.

record(Numbers) ->
    ["device", "block", "virtio_mmio" | Numbers].

%% The words the root writes for QEMU virt's block transport.
the_root_s_record_test() ->
    ?assertEqual({ok, [spec(167788032, 512, 79, 2097152)]},
                 find([record(["167788032", "512", "79", "2097152"])])).

a_missing_disk_is_no_record_test() ->
    ?assertEqual({ok, []}, find([])),
    ?assertEqual({ok, []}, find([["console_uart", "1", "2", "3"], ["console_driver", "erx_pl011"]])).

other_roles_and_peripherals_are_left_alone_test() ->
    ?assertEqual({ok, []}, find([["device", "network", "virtio_mmio", "x"],
                                 ["device", "block", "sdhci", "1", "2", "3", "4"],
                                 ["device", "block"], ["device"]])).

several_records_keep_their_order_and_trailing_words_are_dropped_test() ->
    ?assertEqual({ok, [spec(1, 2, 3, 4), spec(5, 6, 7, 0)]},
                 find([record(["1", "2", "3", "4", "plainword"]), ["debug"], record(["5", "6", "7", "0"])])).

field_bounds_test() ->
    ?assertEqual({ok, [spec(18446744073709551615, 18446744073709551615, 4294967295, 18446744073709551615)]},
                 find([record([?U64_MAX, ?U64_MAX, ?U32_MAX, ?U64_MAX])])),
    [?assertMatch({error, {bad_device_record, _}}, find([record(Numbers)]))
     || Numbers <- [["18446744073709551616", "1", "1", "1"], ["1", "1", "4294967296", "1"],
                    ["1", "1", "1", "18446744073709551616"], ["1", "1", "1", "018446744073709551615"]]].

malformed_numbers_refuse_test() ->
    [?assertMatch({error, {bad_device_record, _}}, find([record(Numbers)]))
     || Numbers <- [["", "1", "1", "1"], ["-1", "1", "1", "1"], ["0x10", "1", "1", "1"],
                    ["1", " 1", "1", "1"], ["1", "1", "1e3", "1"], [[16#661], "1", "1", "1"]]].

a_short_record_refuses_even_after_a_good_one_test() ->
    ?assertMatch({error, {bad_device_record, _}}, find([record(["1", "2", "3", "4"]), record(["1", "2", "3"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([record([])])).
