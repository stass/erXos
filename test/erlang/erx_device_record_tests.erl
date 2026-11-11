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

spec(Base, Size, Line) ->
    #{peripheral => virtio_mmio, window => {physical, Base, Size}, lines => [Line]}.

record(Numbers) ->
    ["device", "block", "virtio_mmio" | Numbers].

%% The words the root writes for QEMU virt's host link UART, its one physical record.
the_root_s_record_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, window => {physical, 151257088, 4096}, lines => [40]}]},
                 erx_device_record:find(hostlink, pl011, [["device", "hostlink", "pl011", "151257088", "4096", "40"]])).

a_missing_disk_is_no_record_test() ->
    ?assertEqual({ok, []}, find([])),
    ?assertEqual({ok, []}, find([["console_uart", "1", "2", "3"], ["console_driver", "erx_pl011"]])).

other_roles_and_peripherals_are_left_alone_test() ->
    ?assertEqual({ok, []}, find([["device", "network", "virtio_mmio", "x"],
                                 ["device", "block", "sdhci", "1", "2", "3", "4"],
                                 ["device", "block"], ["device"]])).

several_records_keep_their_order_and_trailing_words_are_dropped_test() ->
    ?assertEqual({ok, [spec(1, 2, 3), spec(5, 6, 7)]},
                 find([record(["1", "2", "3", "plainword"]), ["debug"], record(["5", "6", "7"])])).

field_bounds_test() ->
    ?assertEqual({ok, [spec(18446744073709551615, 18446744073709551615, 4294967295)]},
                 find([record([?U64_MAX, ?U64_MAX, ?U32_MAX])])),
    [?assertMatch({error, {bad_device_record, _}}, find([record(Numbers)]))
     || Numbers <- [["18446744073709551616", "1", "1"], ["1", "1", "4294967296"],
                    ["1", "18446744073709551616", "1"], ["1", "018446744073709551615", "1"]]].

malformed_numbers_refuse_test() ->
    [?assertMatch({error, {bad_device_record, _}}, find([record(Numbers)]))
     || Numbers <- [["", "1", "1"], ["-1", "1", "1"], ["0x10", "1", "1"],
                    ["1", " 1", "1"], ["1", "1", "1e3"], [[16#661], "1", "1"]]].

a_short_record_refuses_even_after_a_good_one_test() ->
    ?assertMatch({error, {bad_device_record, _}}, find([record(["1", "2", "3"]), record(["1", "2"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([record([])])).

given(Numbers) ->
    ["given", "block", "virtio_mmio" | Numbers].

given_spec(Window, Offset, Size, Line) ->
    #{peripheral => virtio_mmio, window => {object, Window, Offset, Size}, lines => [{object, Line}]}.

%% The words the domain library writes for a holder of QEMU virt's block transport: the
%% window object's handle, the transport at 0xe00 in its page, the line's handle and the
%% device's one memory.
a_holder_s_record_test() ->
    ?assertEqual({ok, [(given_spec(12, 3584, 512, 13))#{memory => {object, 14, 1048576}}]},
                 find([given(["12", "3584", "512", "13", "14", "1048576"])])).

a_given_record_of_no_memory_has_no_memory_key_test() ->
    ?assertEqual({ok, [given_spec(12, 0, 4096, 13)]}, find([given(["12", "0", "4096", "13", "0", "0"])])).

the_two_forms_keep_their_order_and_their_own_counts_test() ->
    ?assertEqual({ok, [spec(1, 2, 3), given_spec(5, 6, 7, 8), spec(9, 10, 11)]},
                 find([record(["1", "2", "3", "4", "5", "6"]), given(["5", "6", "7", "8", "0", "0", "word"]),
                       record(["9", "10", "11"])])).

given_field_bounds_test() ->
    ?assertEqual({ok, [(given_spec(18446744073709551615, 0, 18446744073709551615, 18446744073709551615))
                       #{memory => {object, 18446744073709551615, 18446744073709551615}}]},
                 find([given([?U64_MAX, "0", ?U64_MAX, ?U64_MAX, ?U64_MAX, ?U64_MAX])])),
    [?assertMatch({error, {bad_device_record, _}}, find([given(Numbers)]))
     || Numbers <- [["18446744073709551616", "0", "1", "1", "1", "1"], ["1", "0", "1", "1", "1", "-1"],
                    ["1", "0x0", "1", "1", "1", "1"], ["1", "0", "1", "1", "1", "018446744073709551615"]]].

a_short_given_record_refuses_test() ->
    ?assertMatch({error, {bad_device_record, _}}, find([given(["1", "2", "3", "4", "5"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([given(["12", "3584", "512", "13", "14", "1"]),
                                                        given([])])).
