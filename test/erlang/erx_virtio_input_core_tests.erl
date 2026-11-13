%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Cases of erx_virtio_input_core, the virtio-input driver's parse of what the device
%% writes: its event records, its configuration space and the identification of a
%% keyboard, a mouse and a tablet from representative configurations of each (not checked
%% against what QEMU's devices report, which the display suite will pin). The numbers are evdev's (FreeBSD's
%% sys/dev/evdev/input-event-codes.h) and section 5.8 of the virtio 1.2 specification,
%% written out here so a wrong generated value fails a case.

-module(erx_virtio_input_core_tests).
-include_lib("eunit/include/eunit.hrl").

-define(EV_SYN, 0).
-define(EV_KEY, 1).
-define(EV_REL, 2).
-define(EV_ABS, 3).
-define(EV_MSC, 4).
-define(KEY_ESC, 1).
-define(KEY_A, 30).
-define(BTN_LEFT, 16#110).
-define(BTN_RIGHT, 16#111).
-define(BTN_MIDDLE, 16#112).
-define(BTN_0, 16#100).
-define(BTN_SOUTH, 16#130).
-define(BTN_TOUCH, 16#14a).
-define(EV_BITS, 16#11).
-define(ABS_INFO, 16#12).

record(Type, Code, Value) -> <<Type:16/little, Code:16/little, Value:32/little-signed>>.

event(Type, Code, Value) -> erx_virtio_input_core:event(record(Type, Code, Value)).

%% The configuration space as the driver reads it whole: the header, then Size bytes of
%% Data and zeros to the end of the data area.
config(Select, Subsel, Data) -> config(Select, Subsel, byte_size(Data), Data).

config(Select, Subsel, Size, Data) ->
    <<Select:8, Subsel:8, Size:8, 0:40, Data/binary, 0:((128 - byte_size(Data)) * 8)>>.

%% A bitmap with the given codes set, bit N rem 8 of byte N div 8.
bitmap(Codes) ->
    Bytes = lists:max([0 | Codes]) div 8 + 1,
    << <<(lists:foldl(fun(Code, Byte) when Code div 8 =:= Index -> Byte bor (1 bsl (Code rem 8));
                         (_, Byte) -> Byte end, 0, Codes)):8>> || Index <- lists:seq(0, Bytes - 1) >>.

absinfo(Min, Max) -> <<Min:32/little-signed, Max:32/little-signed, 0:32, 0:32, 0:32>>.

%% The reads of queries/0 for a device with these key, relative and absolute codes, each
%% type without codes answering with size zero, and these two absolute axes.
device(Key, Rel, Abs, Axes) ->
    Bits = fun([]) -> <<>>; (Codes) -> bitmap(Codes) end,
    maps:merge(#{{?EV_BITS, ?EV_KEY} => config(?EV_BITS, ?EV_KEY, Bits(Key)),
                 {?EV_BITS, ?EV_REL} => config(?EV_BITS, ?EV_REL, Bits(Rel)),
                 {?EV_BITS, ?EV_ABS} => config(?EV_BITS, ?EV_ABS, Bits(Abs))},
               maps:from_list([{{?ABS_INFO, Axis}, config(?ABS_INFO, Axis, Info)} || {Axis, Info} <- Axes])).

key_goes_down_repeats_and_up_test() ->
    ?assertEqual({ok, {key, ?KEY_A, down}}, event(?EV_KEY, ?KEY_A, 1)),
    ?assertEqual({ok, {key, ?KEY_A, repeat}}, event(?EV_KEY, ?KEY_A, 2)),
    ?assertEqual({ok, {key, ?KEY_A, up}}, event(?EV_KEY, ?KEY_A, 0)),
    ?assertEqual({ok, {key, ?BTN_LEFT, down}}, event(?EV_KEY, ?BTN_LEFT, 1)).

key_with_another_value_or_past_key_max_is_dropped_test() ->
    ?assertEqual({drop, {key, ?KEY_A, 3}}, event(?EV_KEY, ?KEY_A, 3)),
    ?assertEqual({drop, {key, ?KEY_A, -1}}, event(?EV_KEY, ?KEY_A, -1)),
    ?assertEqual({drop, {key, 16#300, 1}}, event(?EV_KEY, 16#300, 1)),
    ?assertEqual({ok, {key, 16#2ff, down}}, event(?EV_KEY, 16#2ff, 1)).

relative_moves_are_signed_test() ->
    ?assertEqual({ok, {rel, x, -1}}, event(?EV_REL, 0, -1)),
    ?assertEqual({ok, {rel, y, 5}}, event(?EV_REL, 1, 5)),
    ?assertEqual({ok, {rel, wheel, -2}}, event(?EV_REL, 8, -2)),
    ?assertEqual({ok, {rel, x, -16#80000000}}, event(?EV_REL, 0, -16#80000000)).

absolute_positions_test() ->
    ?assertEqual({ok, {abs, x, 32767}}, event(?EV_ABS, 0, 32767)),
    ?assertEqual({ok, {abs, y, 0}}, event(?EV_ABS, 1, 0)).

syn_report_and_dropped_test() ->
    ?assertEqual({ok, {syn, report}}, event(?EV_SYN, 0, 0)),
    ?assertEqual({ok, {syn, dropped}}, event(?EV_SYN, 3, 0)),
    ?assertEqual({drop, {syn, 2}}, event(?EV_SYN, 2, 0)).

events_the_driver_does_not_use_are_dropped_test() ->
    ?assertEqual({drop, {type, ?EV_MSC}}, event(?EV_MSC, 4, 458756)),
    ?assertEqual({drop, {type, 16#ffff}}, event(16#ffff, 16#ffff, -1)),
    ?assertEqual({drop, {rel, 6}}, event(?EV_REL, 6, 1)),
    ?assertEqual({drop, {abs, 16#2f}}, event(?EV_ABS, 16#2f, 1)).

record_of_another_length_is_an_error_test() ->
    Record = record(?EV_KEY, ?KEY_A, 1),
    ?assertEqual({error, {length, 0}}, erx_virtio_input_core:event(<<>>)),
    ?assertEqual({error, {length, 7}}, erx_virtio_input_core:event(binary:part(Record, 0, 7))),
    ?assertEqual({error, {length, 9}}, erx_virtio_input_core:event(<<Record/binary, 0>>)),
    ?assertEqual({error, {length, 16}}, erx_virtio_input_core:event(<<Record/binary, Record/binary>>)).

config_returns_the_bytes_size_names_test() ->
    ?assertEqual({ok, <<"QEMU Virtio Keyboard">>},
                 erx_virtio_input_core:config(1, 0, config(1, 0, <<"QEMU Virtio Keyboard">>))),
    ?assertEqual({ok, <<>>}, erx_virtio_input_core:config(?EV_BITS, ?EV_REL, config(?EV_BITS, ?EV_REL, <<>>))),
    Full = binary:copy(<<16#a5>>, 128),
    ?assertEqual({ok, Full}, erx_virtio_input_core:config(?EV_BITS, ?EV_KEY, config(?EV_BITS, ?EV_KEY, Full))).

config_size_past_the_data_area_is_an_error_test() ->
    ?assertEqual({error, {size, 129}}, erx_virtio_input_core:config(1, 0, config(1, 0, 129, <<>>))),
    ?assertEqual({error, {size, 255}}, erx_virtio_input_core:config(1, 0, config(1, 0, 255, <<>>))).

config_of_another_query_or_length_is_an_error_test() ->
    Block = config(?EV_BITS, ?EV_KEY, <<1>>),
    ?assertEqual({error, {query, {?EV_BITS, ?EV_KEY}}}, erx_virtio_input_core:config(?EV_BITS, ?EV_REL, Block)),
    ?assertEqual({error, {length, 135}}, erx_virtio_input_core:config(?EV_BITS, ?EV_KEY, binary:part(Block, 0, 135))),
    ?assertEqual({error, {length, 137}}, erx_virtio_input_core:config(?EV_BITS, ?EV_KEY, <<Block/binary, 0>>)),
    ?assertEqual({error, {length, 0}}, erx_virtio_input_core:config(?EV_BITS, ?EV_KEY, <<>>)).

bits_are_least_significant_first_test() ->
    ?assertEqual([0, 1, 15], erx_virtio_input_core:bits(<<16#03, 16#80>>)),
    ?assertEqual([?BTN_LEFT, ?BTN_RIGHT, ?BTN_MIDDLE], erx_virtio_input_core:bits(bitmap([?BTN_MIDDLE, ?BTN_LEFT, ?BTN_RIGHT]))),
    ?assertEqual([], erx_virtio_input_core:bits(<<>>)).

absinfo_needs_the_whole_layout_and_min_below_max_test() ->
    ?assertEqual({ok, #{min => -5, max => 32767, fuzz => 0, flat => 0, res => 0}},
                 erx_virtio_input_core:absinfo(absinfo(-5, 32767))),
    ?assertEqual({error, {absinfo, absinfo(7, 7)}}, erx_virtio_input_core:absinfo(absinfo(7, 7))),
    Short = binary:part(absinfo(0, 1), 0, 19),
    ?assertEqual({error, {absinfo, Short}}, erx_virtio_input_core:absinfo(Short)).

keyboard_is_identified_test() ->
    Keyboard = device([?KEY_ESC, ?KEY_A, 16#2ff], [], [], []),
    ?assertEqual({ok, keyboard}, erx_virtio_input_core:identify(Keyboard)).

mouse_is_identified_test() ->
    Mouse = device([?BTN_LEFT, ?BTN_RIGHT, ?BTN_MIDDLE], [0, 1, 8], [], []),
    ?assertEqual({ok, mouse}, erx_virtio_input_core:identify(Mouse)).

tablet_is_identified_with_its_axes_test() ->
    Tablet = device([?BTN_LEFT, ?BTN_RIGHT, ?BTN_MIDDLE], [8], [0, 1], [{0, absinfo(0, 32767)}, {1, absinfo(0, 32767)}]),
    Axis = #{min => 0, max => 32767, fuzz => 0, flat => 0, res => 0},
    ?assertEqual({ok, {tablet, Axis, Axis}}, erx_virtio_input_core:identify(Tablet)).

buttons_alone_make_no_keyboard_test() ->
    Buttons = device([?BTN_LEFT, ?BTN_RIGHT], [], [], []),
    ?assertEqual({error, {class, [?BTN_LEFT, ?BTN_RIGHT], [], []}}, erx_virtio_input_core:identify(Buttons)).

the_first_button_is_no_key_test() ->
    ?assertEqual({error, {class, [?BTN_0], [], []}}, erx_virtio_input_core:identify(device([?BTN_0], [], [], []))).

joystick_axes_make_no_tablet_test() ->
    Axes = [{0, absinfo(-32768, 32767)}, {1, absinfo(-32768, 32767)}],
    ?assertEqual({error, {class, [?BTN_SOUTH], [], [0, 1]}},
                 erx_virtio_input_core:identify(device([?BTN_SOUTH], [], [0, 1], Axes))).

identify_refuses_a_missing_or_broken_read_test() ->
    Keyboard = device([?KEY_A], [], [], []),
    ?assertEqual({error, {missing, {?EV_BITS, ?EV_REL}}},
                 erx_virtio_input_core:identify(maps:remove({?EV_BITS, ?EV_REL}, Keyboard))),
    ?assertEqual({error, {{?EV_BITS, ?EV_ABS}, {size, 200}}},
                 erx_virtio_input_core:identify(Keyboard#{{?EV_BITS, ?EV_ABS} => config(?EV_BITS, ?EV_ABS, 200, <<>>)})),
    Flat = device([?BTN_TOUCH], [], [0, 1], [{0, absinfo(0, 32767)}, {1, absinfo(9, 9)}]),
    ?assertEqual({error, {{?ABS_INFO, 1}, {absinfo, absinfo(9, 9)}}}, erx_virtio_input_core:identify(Flat)),
    ?assertEqual({error, {missing, {?ABS_INFO, 1}}},
                 erx_virtio_input_core:identify(maps:remove({?ABS_INFO, 1}, Flat))).

queries_cover_every_read_identify_makes_test() ->
    Tablet = device([], [], [0, 1], [{0, absinfo(0, 1)}, {1, absinfo(0, 1)}]),
    ?assertEqual(lists:sort(maps:keys(Tablet)), lists:sort(erx_virtio_input_core:queries())).
