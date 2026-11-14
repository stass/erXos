%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_device_record:find/3, the parse of the device records from the boot
%% information. Each malformed form ends in a stated reason, never in an exception.
%% test/host/erx_device_record_test.rb runs them on stock's emulator.

-module(erx_device_record_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(U64_MAX, "18446744073709551615").
-define(U32_MAX, "4294967295").
%% QEMU virt's block transport, the device every record below names.
-define(PATH, "/virtio_mmio@a003e00").

find(Arguments) ->
    erx_device_record:find(block, virtio_mmio, Arguments).

spec(Base, Size, Line, Clock) ->
    #{peripheral => virtio_mmio, path => <<?PATH>>, window => {physical, Base, Size}, lines => [Line], clock => Clock}.

%% A physical record of Base, Size, Line and Clock, its line marked direct, as on QEMU virt.
record([Base, Size, Line, Clock | Words]) ->
    ["device", "block", "virtio_mmio", ?PATH, Base, Size, Line, "direct", Clock | Words];
record(Words) ->
    ["device", "block", "virtio_mmio", ?PATH | Words].

%% The words the root writes for QEMU virt's host link UART, its one physical record.
the_root_s_record_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, path => <<"/pl011@9040000">>, window => {physical, 151257088, 4096}, lines => [40], clock => 24000000}]},
                 erx_device_record:find(hostlink, pl011, [["device", "hostlink", "pl011", "/pl011@9040000", "151257088", "4096", "40",
                                                           "direct", "24000000"]])).

%% The Raspberry Pi 4's host link UART shares line 153 with the other PL011s, and its
%% record says so; erx_device:open/1 takes the line marked.
a_shared_line_is_marked_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, path => <<"/soc/serial@7e201600">>, window => {physical, 4263515648, 512}, lines => [{shared, 153}],
                         clock => 48000000}]},
                 erx_device_record:find(hostlink, pl011, [["device", "hostlink", "pl011", "/soc/serial@7e201600", "4263515648", "512", "153",
                                                           "shared", "48000000"]])),
    ?assertEqual({ok, [(given_spec(12, 0, 512, 13, 0))#{lines => [{shared, {object, 13}}]}]},
                 find([given_marked(["12", "0", "512", "13", "shared", "0", "0", "0", "0", "0"])])).

%% Only the two words mark a line: anything else refuses the record rather than reading
%% it as one mark or the other.
a_bad_mark_refuses_test() ->
    [?assertMatch({error, {bad_device_record, "a device record's line mark" ++ _}},
                  find([["device", "block", "virtio_mmio", ?PATH, "1", "2", "3", Mark, "4"]]))
     || Mark <- bad_marks()],
    [?assertMatch({error, {bad_device_record, "a given device record's line mark" ++ _}},
                  find([given_marked(["1", "0", "2", "3", Mark, "0", "0", "0", "0", "0"])]))
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

%% A given record of the nine numbers, its line marked direct after LINE_H.
given([Window, Offset, Size, Line | Rest]) ->
    given_marked([Window, Offset, Size, Line, "direct" | Rest]);
given(Words) ->
    given_marked(Words).

given_marked(Words) ->
    ["given", "block", "virtio_mmio", ?PATH | Words].

given_spec(Window, Offset, Size, Line, Clock) ->
    #{peripheral => virtio_mmio, path => <<?PATH>>, window => {object, Window, Offset, Size}, lines => [{object, Line}],
      clock => Clock, coherent => false}.

%% The words the domain library writes for a holder of QEMU virt's block transport: the
%% window object's handle, the transport at 0xe00 in its page, the line's handle, the
%% device's one memory and its clock, 0 since its driver reads none.
a_holder_s_record_test() ->
    ?assertEqual({ok, [(given_spec(12, 3584, 512, 13, 0))#{memory => {object, 14, 1048576}}]},
                 find([given(["12", "3584", "512", "13", "14", "1048576", "0", "0", "0"])])).

%% A given PL011 carries its clock as the physical record does.
a_given_uart_s_clock_test() ->
    ?assertEqual({ok, [#{peripheral => pl011, path => <<"/pl011@9040000">>, window => {object, 12, 0, 4096}, lines => [{object, 13}],
                         clock => 24000000, coherent => false}]},
                 erx_device_record:find(uart, pl011, [["given", "uart", "pl011", "/pl011@9040000", "12", "0", "4096", "13", "direct",
                                                       "0", "0", "24000000", "0", "0"]])).

a_given_record_of_no_memory_has_no_memory_key_test() ->
    ?assertEqual({ok, [given_spec(12, 0, 4096, 13, 0)]},
                 find([given(["12", "0", "4096", "13", "0", "0", "0", "0", "0"])])).

the_two_forms_keep_their_order_and_their_own_counts_test() ->
    ?assertEqual({ok, [spec(1, 2, 3, 4), given_spec(5, 6, 7, 8, 9), spec(9, 10, 11, 12)]},
                 find([record(["1", "2", "3", "4", "5", "6"]),
                       given(["5", "6", "7", "8", "0", "0", "9", "0", "0", "word"]),
                       record(["9", "10", "11", "12"])])).

given_field_bounds_test() ->
    ?assertEqual({ok, [(given_spec(18446744073709551615, 0, 18446744073709551615, 18446744073709551615,
                                   4294967295))
                       #{memory => {object, 18446744073709551615, 18446744073709551615}}]},
                 find([given([?U64_MAX, "0", ?U64_MAX, ?U64_MAX, ?U64_MAX, ?U64_MAX, ?U32_MAX, "0", "0"])])),
    [?assertMatch({error, {bad_device_record, _}}, find([given(Numbers ++ ["0", "0"])]))
     || Numbers <- [["18446744073709551616", "0", "1", "1", "1", "1", "0"], ["1", "0", "1", "1", "1", "-1", "0"],
                    ["1", "0x0", "1", "1", "1", "1", "0"], ["1", "0", "1", "1", "1", "018446744073709551615", "0"],
                    ["1", "0", "1", "1", "1", "1", "4294967296"], ["1", "0", "1", "1", "1", "1", "-1"]]].

%% COHERENT is the tree's coherence mark: 1 is true, 0 false, and any other word refuses the
%% record rather than reading as either.
a_given_record_s_coherence_test() ->
    ?assertEqual({ok, [(given_spec(12, 0, 4096, 13, 0))#{coherent => true}]},
                 find([given(["12", "0", "4096", "13", "0", "0", "0", "1", "0"])])),
    ?assertEqual({ok, [given_spec(12, 0, 4096, 13, 0)]},
                 find([given(["12", "0", "4096", "13", "0", "0", "0", "0", "0"])])),
    [?assertMatch({error, {bad_device_record, "a given device record's coherence" ++ _}},
                  find([given(["12", "0", "4096", "13", "0", "0", "0", Coherent, "0"])]))
     || Coherent <- ["2", "", "01", "true", "-1", "1 "]].

%% MAC is the tree's 48-bit hardware address: the spec has the mac key only for a nonzero
%% address, and an address above 2^48 - 1 refuses the record.
a_given_record_s_hardware_address_test() ->
    ?assertEqual({ok, [(given_spec(12, 0, 4096, 13, 0))#{mac => 16#525400123456}]},
                 find([given(["12", "0", "4096", "13", "0", "0", "0", "0", "90520731923542"])])),
    ?assertEqual({ok, [(given_spec(12, 0, 4096, 13, 0))#{mac => 16#ffffffffffff}]},
                 find([given(["12", "0", "4096", "13", "0", "0", "0", "0", "281474976710655"])])),
    [?assertMatch({error, {bad_device_record, _}},
                  find([given(["12", "0", "4096", "13", "0", "0", "0", "0", Mac])]))
     || Mac <- ["281474976710656", "-1", "0x1", "", "0281474976710655"]].

a_short_given_record_refuses_test() ->
    ?assertMatch({error, {bad_device_record, _}}, find([given(["1", "2", "3", "4", "5", "6"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([given(["12", "3584", "512", "13", "14", "1", "0", "0"])])),
    ?assertMatch({error, {bad_device_record, _}}, find([given(["12", "3584", "512", "13", "14", "1", "0", "0", "0"]),
                                                        given([])])),
    ?assertMatch({error, {bad_device_record, _}},
                 find([given_marked(["12", "3584", "512", "13", "14", "1", "0", "0", "0"])])).

%% The framebuffer record (docs/design-device-tree.md, "Facts into records"): the window the
%% root installed, the framebuffer's offset and bytes in it, its geometry and its format.
framebuffer(Words) ->
    ["framebuffer" | Words].

a_framebuffer_record_is_read_test() ->
    ?assertEqual({ok, [#{window => {object, 14, 0, 8294400}, width => 1920, height => 1080, stride => 7680,
                         format => x8r8g8b8}]},
                 erx_device_record:framebuffers([given(["12", "0", "4096", "13", "0", "0", "0", "0", "0"]),
                                                 framebuffer(["14", "0", "8294400", "1920", "1080", "7680",
                                                              "x8r8g8b8"])])),
    ?assertEqual({ok, [#{window => {object, 9, 256, 6144}, width => 32, height => 64, stride => 96,
                         format => r8g8b8}]},
                 erx_device_record:framebuffers([framebuffer(["9", "256", "6144", "32", "64", "96", "r8g8b8"])])).

%% No framebuffer the tree placed is no record, and no record is no framebuffer: never a
%% made-up one.
no_framebuffer_record_is_none_test() ->
    ?assertEqual({ok, []}, erx_device_record:framebuffers([])),
    ?assertEqual({ok, []}, erx_device_record:framebuffers([given(["12", "0", "4096", "13", "0", "0", "0", "0", "0"])])).

%% Each malformed record ends in a stated reason: too few words, a bad number, a format
%% outside the binding's table, and geometry the tree's reader would have refused.
a_malformed_framebuffer_record_refuses_test() ->
    Good = ["14", "0", "8294400", "1920", "1080", "7680", "x8r8g8b8"],
    [?assertMatch({error, {bad_device_record, _}}, erx_device_record:framebuffers([framebuffer(Words)]))
     || Words <- [lists:sublist(Good, 6), ["x" | tl(Good)], setelement_list(4, Good, "0"),
                  setelement_list(4, Good, ?U64_MAX), setelement_list(7, Good, "X8R8G8B8"),
                  setelement_list(7, Good, "rgb"), setelement_list(6, Good, "7679"),
                  setelement_list(3, Good, "8294399"), setelement_list(3, Good, "0"),
                  setelement_list(5, Good, "0")]].

setelement_list(At, List, Value) ->
    lists:sublist(List, At - 1) ++ [Value | lists:nthtail(At, List)].

%% PATH is the device's device-tree path, its name: a node path of the characters a device
%% tree allows in names of at most ERX_DEVICE_PATH_MAX bytes. The longest passes
%% in either form; one a byte longer, an empty, a relative, or one holding an escape, a
%% space or a byte outside ASCII refuses the record, so no name a driver shows carries a
%% control.
a_record_s_path_names_its_device_test() ->
    Longest = "/virtio_mmio@a003e00/" ++ lists:duplicate(?ERX_DEVICE_PATH_MAX - 21, $a),
    ?assertEqual(?ERX_DEVICE_PATH_MAX, length(Longest)),
    ?assertEqual({ok, [(spec(1, 2, 3, 4))#{path => list_to_binary(Longest)}]},
                 find([["device", "block", "virtio_mmio", Longest, "1", "2", "3", "direct", "4"]])),
    ?assertEqual({ok, [(given_spec(1, 0, 2, 3, 0))#{path => list_to_binary(Longest)}]},
                 find([["given", "block", "virtio_mmio", Longest, "1", "0", "2", "3", "direct", "0", "0", "0", "0",
                        "0"]])),
    [?assertMatch({error, {bad_device_record, "a device record's path" ++ _}},
                  find([["device", "block", "virtio_mmio", Path, "1", "2", "3", "direct", "4"]]))
     || Path <- bad_paths(Longest)],
    [?assertMatch({error, {bad_device_record, "a given device record's path" ++ _}},
                  find([["given", "block", "virtio_mmio", Path, "1", "0", "2", "3", "direct", "0", "0", "0", "0",
                         "0"]]))
     || Path <- bad_paths(Longest)].

bad_paths(Longest) ->
    [Longest ++ "a", "", "virtio_mmio@a003e00", "/virtio_mmio@a003e00\e[2J", "/virtio mmio", "/virtio_mmio\n",
     [$/, 16#661], "/virtio_mmio@a003e00:0", [$/, 0]].
