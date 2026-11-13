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

spec(Base, Size, Line, Clock) ->
    #{peripheral => virtio_mmio, window => {physical, Base, Size}, lines => [Line], clock => Clock}.

%% A physical record of Base, Size, Line and Clock, its line marked direct, as on QEMU virt.
record([Base, Size, Line, Clock | Words]) ->
    ["device", "block", "virtio_mmio", Base, Size, Line, "direct", Clock | Words];
record(Words) ->
    ["device", "block", "virtio_mmio" | Words].

%% The words the root writes for QEMU virt's host link UART, its one physical record.
the_root_s_record_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, window => {physical, 151257088, 4096}, lines => [40], clock => 24000000}]},
                 erx_device_record:find(hostlink, pl011, [["device", "hostlink", "pl011", "151257088", "4096", "40",
                                                           "direct", "24000000"]])).

%% The Raspberry Pi 4's host link UART shares line 153 with the other PL011s, and its
%% record says so; erx_device:open/1 takes the line marked.
a_shared_line_is_marked_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, window => {physical, 4263515648, 512}, lines => [{shared, 153}],
                         clock => 48000000}]},
                 erx_device_record:find(hostlink, pl011, [["device", "hostlink", "pl011", "4263515648", "512", "153",
                                                           "shared", "48000000"]])),
    ?assertEqual({ok, [(given_spec(12, 0, 512, 13, 0))#{lines => [{shared, {object, 13}}]}]},
                 find([given_marked(["12", "0", "512", "13", "shared", "0", "0", "0"])])).

%% Only the two words mark a line: anything else refuses the record rather than reading
%% it as one mark or the other.
a_bad_mark_refuses_test() ->
    [?assertMatch({error, {bad_device_record, "a device record's line mark" ++ _}},
                  find([["device", "block", "virtio_mmio", "1", "2", "3", Mark, "4"]]))
     || Mark <- bad_marks()],
    [?assertMatch({error, {bad_device_record, "a given device record's line mark" ++ _}},
                  find([given_marked(["1", "0", "2", "3", Mark, "0", "0", "0"])]))
     || Mark <- bad_marks()],
    ?assertMatch({error, {bad_device_record, _}}, find([["device", "block", "virtio_mmio", "1", "2", "3", "4"]])).

bad_marks() ->
    ["", "Shared", "DIRECT", "shared ", " direct", "share", "directly", "1", "shared\n"].

a_missing_disk_is_no_record_test() ->
    ?assertEqual({ok, []}, find([])),
    ?assertEqual({ok, []}, find([["console_uart", "1", "2", "3", "direct", "4"], ["console_driver", "erx_pl011"]])).

other_roles_and_peripherals_are_left_alone_test() ->
    ?assertEqual({ok, []}, find([["device", "network", "virtio_mmio", "x"],
                                 ["device", "block", "sdhci", "1", "2", "3", "direct", "4"],
                                 ["device", "block"], ["device"]])).

several_records_keep_their_order_and_trailing_words_are_dropped_test() ->
    ?assertEqual({ok, [spec(1, 2, 3, 4), spec(5, 6, 7, 0)]},
                 find([record(["1", "2", "3", "4", "plainword"]), ["debug"], record(["5", "6", "7", "0"])])).

field_bounds_test() ->
    ?assertEqual({ok, [spec(18446744073709551615, 18446744073709551615, 4294967295, 4294967295)]},
                 find([record([?U64_MAX, ?U64_MAX, ?U32_MAX, ?U32_MAX])])),
    [?assertMatch({error, {bad_device_record, _}}, find([record(Numbers)]))
     || Numbers <- [["18446744073709551616", "1", "1", "1"], ["1", "1", "4294967296", "1"],
                    ["1", "18446744073709551616", "1", "1"], ["1", "018446744073709551615", "1", "1"],
                    ["1", "1", "1", "4294967296"], ["1", "1", "1", "04294967295"]]].

malformed_numbers_refuse_test() ->
    [?assertMatch({error, {bad_device_record, _}}, find([record(Numbers)]))
     || Numbers <- [["", "1", "1", "1"], ["-1", "1", "1", "1"], ["0x10", "1", "1", "1"],
                    ["1", " 1", "1", "1"], ["1", "1", "1e3", "1"], [[16#661], "1", "1", "1"],
                    ["1", "1", "1", ""], ["1", "1", "1", "-1"], ["1", "1", "1", "24MHz"]]].

a_short_record_refuses_even_after_a_good_one_test() ->
    ?assertMatch({error, {bad_device_record, _}}, find([record(["1", "2", "3", "4"]), record(["1", "2", "3"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([["device", "block", "virtio_mmio", "1", "2", "3", "direct"]])),
    ?assertMatch({error, {bad_device_record, _}}, find([record([])])).

%% A given record of the seven numbers, its line marked direct after LINE_H.
given([Window, Offset, Size, Line | Rest]) ->
    given_marked([Window, Offset, Size, Line, "direct" | Rest]);
given(Words) ->
    given_marked(Words).

given_marked(Words) ->
    ["given", "block", "virtio_mmio" | Words].

given_spec(Window, Offset, Size, Line, Clock) ->
    #{peripheral => virtio_mmio, window => {object, Window, Offset, Size}, lines => [{object, Line}],
      clock => Clock}.

%% The words the domain library writes for a holder of QEMU virt's block transport: the
%% window object's handle, the transport at 0xe00 in its page, the line's handle, the
%% device's one memory and its clock, 0 since its driver reads none.
a_holder_s_record_test() ->
    ?assertEqual({ok, [(given_spec(12, 3584, 512, 13, 0))#{memory => {object, 14, 1048576}}]},
                 find([given(["12", "3584", "512", "13", "14", "1048576", "0"])])).

%% A given PL011 carries its clock as the physical record does.
a_given_uart_s_clock_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, window => {object, 12, 0, 4096}, lines => [{object, 13}],
                         clock => 24000000}]},
                 erx_device_record:find(uart, pl011, [["given", "uart", "pl011", "12", "0", "4096", "13", "direct",
                                                       "0", "0", "24000000"]])).

a_given_record_of_no_memory_has_no_memory_key_test() ->
    ?assertEqual({ok, [given_spec(12, 0, 4096, 13, 0)]}, find([given(["12", "0", "4096", "13", "0", "0", "0"])])).

the_two_forms_keep_their_order_and_their_own_counts_test() ->
    ?assertEqual({ok, [spec(1, 2, 3, 4), given_spec(5, 6, 7, 8, 9), spec(9, 10, 11, 12)]},
                 find([record(["1", "2", "3", "4", "5", "6"]), given(["5", "6", "7", "8", "0", "0", "9", "word"]),
                       record(["9", "10", "11", "12"])])).

given_field_bounds_test() ->
    ?assertEqual({ok, [(given_spec(18446744073709551615, 0, 18446744073709551615, 18446744073709551615,
                                   4294967295))
                       #{memory => {object, 18446744073709551615, 18446744073709551615}}]},
                 find([given([?U64_MAX, "0", ?U64_MAX, ?U64_MAX, ?U64_MAX, ?U64_MAX, ?U32_MAX])])),
    [?assertMatch({error, {bad_device_record, _}}, find([given(Numbers)]))
     || Numbers <- [["18446744073709551616", "0", "1", "1", "1", "1", "0"], ["1", "0", "1", "1", "1", "-1", "0"],
                    ["1", "0x0", "1", "1", "1", "1", "0"], ["1", "0", "1", "1", "1", "018446744073709551615", "0"],
                    ["1", "0", "1", "1", "1", "1", "4294967296"], ["1", "0", "1", "1", "1", "1", "-1"]]].

a_short_given_record_refuses_test() ->
    ?assertMatch({error, {bad_device_record, _}}, find([given(["1", "2", "3", "4", "5", "6"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([given(["12", "3584", "512", "13", "14", "1", "0"]),
                                                        given([])])),
    ?assertMatch({error, {bad_device_record, _}}, find([given_marked(["12", "3584", "512", "13", "14", "1", "0"])])).
