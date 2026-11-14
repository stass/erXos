%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Cases of erx_virtio_input_core, the virtio-input driver's pure core: the parse of its
%% event records and its configuration space, the two absolute axes' ranges new/1 reads,
%% and the fold of each update into erx_input:record()s (docs/design-display.md, "The
%% display device" and "Verification and testing", Drivers). The numbers are evdev's
%% (FreeBSD's sys/dev/evdev/input-event-codes.h), section 5.8 of the virtio 1.2
%% specification and the bounds of a record ("Input events"), written out here so a wrong
%% generated value fails a case.

-module(erx_virtio_input_core_tests).
-include_lib("eunit/include/eunit.hrl").

-define(EV_SYN, 0).
-define(EV_KEY, 1).
-define(EV_REL, 2).
-define(EV_ABS, 3).
-define(EV_MSC, 4).
-define(SYN_REPORT, 0).
-define(SYN_DROPPED, 3).
-define(KEY_A, 30).
-define(KEY_B, 48).
-define(BTN_LEFT, 16#110).
-define(REL_X, 0).
-define(REL_Y, 1).
-define(REL_WHEEL, 8).
-define(ABS_X, 0).
-define(ABS_Y, 1).
-define(ABS_INFO, 16#12).
-define(INT32_MIN, -16#80000000).
-define(INT32_MAX, 16#7fffffff).

record(Type, Code, Value) -> <<Type:16/little, Code:16/little, Value:32/little-signed>>.

event(Type, Code, Value) -> erx_virtio_input_core:event(record(Type, Code, Value)).

%% The configuration space as the driver reads it whole: the header, then Size bytes of
%% Data and zeros to the end of the data area.
config(Select, Subsel, Data) -> config(Select, Subsel, byte_size(Data), Data).

config(Select, Subsel, Size, Data) ->
    <<Select:8, Subsel:8, Size:8, 0:40, Data/binary, 0:((128 - byte_size(Data)) * 8)>>.

absinfo(Min, Max) -> <<Min:32/little-signed, Max:32/little-signed, 0:32, 0:32, 0:32>>.

%% The reads of queries/0 for a device whose ABS_INFO answers for ABS_X and ABS_Y are
%% these data, <<>> where it has no such axis.
reads(XInfo, YInfo) ->
    #{{?ABS_INFO, ?ABS_X} => config(?ABS_INFO, ?ABS_X, XInfo),
      {?ABS_INFO, ?ABS_Y} => config(?ABS_INFO, ?ABS_Y, YInfo)}.

%% A fold of a device with no absolute axes, and of one with these two ranges.
fold() -> fold(<<>>, <<>>).

fold({XMin, XMax}, {YMin, YMax}) -> fold(absinfo(XMin, XMax), absinfo(YMin, YMax));
fold(XInfo, YInfo) ->
    {ok, Fold} = erx_virtio_input_core:new(reads(XInfo, YInfo)),
    Fold.

%% The records the fold sends for these events, in order, and the fold after them.
run(Fold, Events) ->
    lists:foldl(fun({Type, Code, Value}, {Sent, F}) ->
                        {Records, Next} = erx_virtio_input_core:fold(record(Type, Code, Value), F),
                        {Sent ++ Records, Next};
                   (Bytes, {Sent, F}) when is_binary(Bytes) ->
                        {Records, Next} = erx_virtio_input_core:fold(Bytes, F),
                        {Sent ++ Records, Next}
                end, {[], Fold}, Events).

sent(Fold, Events) -> element(1, run(Fold, Events)).

report() -> {?EV_SYN, ?SYN_REPORT, 0}.
dropped() -> {?EV_SYN, ?SYN_DROPPED, 0}.
key(Code, Value) -> {?EV_KEY, Code, Value}.
rel(Code, Value) -> {?EV_REL, Code, Value}.
abs(Code, Value) -> {?EV_ABS, Code, Value}.

%% The parse.

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
    ?assertEqual({ok, {rel, x, -1}}, event(?EV_REL, ?REL_X, -1)),
    ?assertEqual({ok, {rel, y, 5}}, event(?EV_REL, ?REL_Y, 5)),
    ?assertEqual({ok, {rel, wheel, -2}}, event(?EV_REL, ?REL_WHEEL, -2)),
    ?assertEqual({ok, {rel, x, ?INT32_MIN}}, event(?EV_REL, ?REL_X, ?INT32_MIN)).

absolute_positions_test() ->
    ?assertEqual({ok, {abs, x, 32767}}, event(?EV_ABS, ?ABS_X, 32767)),
    ?assertEqual({ok, {abs, y, 0}}, event(?EV_ABS, ?ABS_Y, 0)).

syn_report_and_dropped_test() ->
    ?assertEqual({ok, {syn, report}}, event(?EV_SYN, ?SYN_REPORT, 0)),
    ?assertEqual({ok, {syn, dropped}}, event(?EV_SYN, ?SYN_DROPPED, 0)),
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
                 erx_virtio_input_core:config(config(1, 0, <<"QEMU Virtio Keyboard">>))),
    ?assertEqual({ok, <<>>}, erx_virtio_input_core:config(config(?ABS_INFO, ?ABS_X, <<>>))),
    Full = binary:copy(<<16#a5>>, 128),
    ?assertEqual({ok, Full}, erx_virtio_input_core:config(config(16#11, 1, Full))).

%% Only size is read: QEMU's area reads as zeros, header included, for a query it has
%% nothing for (docs/research-virtio-input-qemu.md, fact 10).
config_reads_size_whatever_the_header_names_test() ->
    ?assertEqual({ok, <<>>}, erx_virtio_input_core:config(<<0:(136 * 8)>>)),
    ?assertEqual({ok, <<1>>}, erx_virtio_input_core:config(config(?ABS_INFO, ?ABS_Y, <<1>>))).

config_size_past_the_data_area_is_an_error_test() ->
    ?assertEqual({error, {size, 129}}, erx_virtio_input_core:config(config(1, 0, 129, <<>>))),
    ?assertEqual({error, {size, 255}}, erx_virtio_input_core:config(config(1, 0, 255, <<>>))).

config_of_another_length_is_an_error_test() ->
    Block = config(?ABS_INFO, ?ABS_X, <<1>>),
    ?assertEqual({error, {length, 135}}, erx_virtio_input_core:config(binary:part(Block, 0, 135))),
    ?assertEqual({error, {length, 137}}, erx_virtio_input_core:config(<<Block/binary, 0>>)),
    ?assertEqual({error, {length, 0}}, erx_virtio_input_core:config(<<>>)).

absinfo_is_the_whole_layout_with_min_below_max_test() ->
    ?assertEqual({ok, {-5, 32767}}, erx_virtio_input_core:absinfo(absinfo(-5, 32767))),
    ?assertEqual({ok, {?INT32_MIN, ?INT32_MAX}}, erx_virtio_input_core:absinfo(absinfo(?INT32_MIN, ?INT32_MAX))),
    ?assertEqual({error, {absinfo, absinfo(7, 7)}}, erx_virtio_input_core:absinfo(absinfo(7, 7))),
    ?assertEqual({error, {absinfo, absinfo(8, 7)}}, erx_virtio_input_core:absinfo(absinfo(8, 7))),
    Short = binary:part(absinfo(0, 1), 0, 19),
    ?assertEqual({error, {absinfo, Short}}, erx_virtio_input_core:absinfo(Short)),
    Long = <<(absinfo(0, 1))/binary, 0>>,
    ?assertEqual({error, {absinfo, Long}}, erx_virtio_input_core:absinfo(Long)).

%% The axes new/1 reads.

queries_are_the_reads_new_makes_test() ->
    ?assertEqual(lists:sort(maps:keys(reads(<<>>, <<>>))), lists:sort(erx_virtio_input_core:queries())).

new_refuses_a_missing_or_broken_read_test() ->
    Reads = reads(absinfo(0, 32767), absinfo(0, 32767)),
    ?assertEqual({error, {missing, {?ABS_INFO, ?ABS_Y}}},
                 erx_virtio_input_core:new(maps:remove({?ABS_INFO, ?ABS_Y}, Reads))),
    ?assertEqual({error, {{?ABS_INFO, ?ABS_X}, {size, 200}}},
                 erx_virtio_input_core:new(Reads#{{?ABS_INFO, ?ABS_X} => config(?ABS_INFO, ?ABS_X, 200, <<>>)})),
    Short = binary:part(absinfo(0, 1), 0, 19),
    ?assertEqual({error, {{?ABS_INFO, ?ABS_X}, {absinfo, Short}}}, erx_virtio_input_core:new(reads(Short, <<>>))).

new_refuses_an_empty_or_inverted_range_test() ->
    ?assertEqual({error, {{?ABS_INFO, ?ABS_Y}, {absinfo, absinfo(9, 9)}}},
                 erx_virtio_input_core:new(reads(absinfo(0, 32767), absinfo(9, 9)))),
    ?assertEqual({error, {{?ABS_INFO, ?ABS_X}, {absinfo, absinfo(1, -1)}}},
                 erx_virtio_input_core:new(reads(absinfo(1, -1), absinfo(0, 32767)))).

%% A keyboard or a mouse answers each ABS_INFO query with an area of zeros, header
%% included (docs/research-virtio-input-qemu.md, fact 10): a fold with no position.
a_device_answering_zeros_has_no_position_test() ->
    Zeros = <<0:(136 * 8)>>,
    {ok, Fold} = erx_virtio_input_core:new(#{{?ABS_INFO, ?ABS_X} => Zeros, {?ABS_INFO, ?ABS_Y} => Zeros}),
    {Sent, Next} = run(Fold, [key(?KEY_A, 1), abs(?ABS_X, 1), report()]),
    ?assertEqual([{key, down, ?KEY_A}], Sent),
    ?assertEqual(#{malformed => 0, unused => 1, skipped => 0}, erx_virtio_input_core:counts(Next)).

%% A device with one absolute axis has no position: its axis's events are counted.
one_axis_alone_makes_no_position_test() ->
    {Sent, Fold} = run(fold(absinfo(0, 100), <<>>), [abs(?ABS_X, 50), abs(?ABS_Y, 50), report()]),
    ?assertEqual([], Sent),
    ?assertEqual(#{malformed => 0, unused => 2, skipped => 0}, erx_virtio_input_core:counts(Fold)).

%% The fold.

a_repeat_sends_nothing_test() ->
    {Sent, Fold} = run(fold(), [key(?KEY_A, 1), report(), key(?KEY_A, 2), report(), key(?KEY_A, 2), report(),
                                key(?KEY_A, 0), report()]),
    ?assertEqual([{key, down, ?KEY_A}, {key, up, ?KEY_A}], Sent),
    ?assertEqual(#{malformed => 0, unused => 2, skipped => 0}, erx_virtio_input_core:counts(Fold)).

syn_dropped_sends_release_and_skips_to_the_next_report_test() ->
    {Sent, Fold} = run(fold(), [rel(?REL_X, 5), key(?KEY_A, 1), dropped(), key(?KEY_A, 0), key(?KEY_B, 1),
                                rel(?REL_X, 3), report(), key(?KEY_B, 0), report()]),
    ?assertEqual([{pointer, rel, 5, 0}, {key, down, ?KEY_A}, release, {key, up, ?KEY_B}], Sent),
    ?assertEqual(#{malformed => 0, unused => 0, skipped => 4}, erx_virtio_input_core:counts(Fold)).

syn_dropped_forgets_what_the_update_kept_test() ->
    ?assertEqual([release], sent(fold({0, 100}, {0, 100}),
                                 [rel(?REL_X, 5), rel(?REL_WHEEL, 1), abs(?ABS_X, 0), abs(?ABS_Y, 0), dropped(),
                                  report(), report()])).

a_press_lands_after_the_moves_before_it_test() ->
    ?assertEqual([{pointer, rel, 3, 0}, {key, down, ?BTN_LEFT}, {pointer, rel, 4, 0}],
                 sent(fold(), [rel(?REL_X, 3), key(?BTN_LEFT, 1), rel(?REL_X, 4), report()])),
    ?assertEqual([{pointer, abs, 0, 65535}, {key, down, ?BTN_LEFT}, {pointer, abs, 65535, 65535}],
                 sent(fold({0, 10}, {0, 10}), [abs(?ABS_X, 0), abs(?ABS_Y, 10), key(?BTN_LEFT, 1),
                                               abs(?ABS_X, 10), report()])).

relative_moves_of_an_update_are_summed_test() ->
    ?assertEqual([{pointer, rel, 4, -2}],
                 sent(fold(), [rel(?REL_X, 1), rel(?REL_Y, -2), rel(?REL_X, 3), report()])),
    ?assertEqual([], sent(fold(), [rel(?REL_X, 1), rel(?REL_X, -1), report(), report()])).

two_moves_of_the_range_maximum_are_sent_as_two_test() ->
    ?assertEqual([{pointer, rel, ?INT32_MAX, 0}, {pointer, rel, ?INT32_MAX, 0}],
                 sent(fold(), [rel(?REL_X, ?INT32_MAX), rel(?REL_X, ?INT32_MAX), report()])),
    ?assertEqual([{pointer, rel, 7, ?INT32_MIN}, {pointer, rel, 0, -1}],
                 sent(fold(), [rel(?REL_X, 7), rel(?REL_Y, ?INT32_MIN), rel(?REL_Y, -1), report()])).

wheel_steps_are_clamped_then_summed_test() ->
    ?assertEqual([{wheel, -2}], sent(fold(), [rel(?REL_WHEEL, -1), rel(?REL_WHEEL, -1), report()])),
    ?assertEqual([{wheel, 127}, {wheel, 1}], sent(fold(), [rel(?REL_WHEEL, 1000), rel(?REL_WHEEL, 1), report()])),
    ?assertEqual([{wheel, -128}], sent(fold(), [rel(?REL_WHEEL, ?INT32_MIN), report()])).

what_an_update_kept_is_sent_in_one_order_test() ->
    ?assertEqual([{pointer, rel, 1, 0}, {pointer, abs, 0, 0}, {wheel, 1}],
                 sent(fold({0, 1}, {0, 1}), [rel(?REL_WHEEL, 1), abs(?ABS_X, 0), rel(?REL_X, 1), abs(?ABS_Y, 0),
                                             report()])),
    %% A sum that would leave its range sends everything kept, in the same order.
    ?assertEqual([{pointer, rel, 5, 0}, {wheel, 127}, {wheel, 1}],
                 sent(fold(), [rel(?REL_X, 5), rel(?REL_WHEEL, 127), rel(?REL_WHEEL, 1), report()])),
    ?assertEqual([{pointer, rel, ?INT32_MAX, 0}, {wheel, 3}, {pointer, rel, 1, 0}],
                 sent(fold(), [rel(?REL_WHEEL, 3), rel(?REL_X, ?INT32_MAX), rel(?REL_X, 1), report()])).

an_axis_minimum_and_maximum_normalize_to_0_and_65535_test() ->
    Events = fun(X, Y) -> [abs(?ABS_X, X), abs(?ABS_Y, Y), report()] end,
    ?assertEqual([{pointer, abs, 0, 65535}], sent(fold({0, 32767}, {0, 32767}), Events(0, 32767))),
    ?assertEqual([{pointer, abs, 65535, 0}], sent(fold({-5, 5}, {100, 200}), Events(5, 100))),
    ?assertEqual([{pointer, abs, 32767, 32767}], sent(fold({-5, 5}, {?INT32_MIN, ?INT32_MAX}), Events(0, 0))),
    ?assertEqual([{pointer, abs, 0, 65535}],
                 sent(fold({?INT32_MIN, ?INT32_MAX}, {?INT32_MIN, ?INT32_MAX}), Events(?INT32_MIN, ?INT32_MAX))).

a_position_outside_its_range_is_clamped_to_it_test() ->
    ?assertEqual([{pointer, abs, 0, 65535}],
                 sent(fold({0, 32767}, {0, 32767}), [abs(?ABS_X, -100), abs(?ABS_Y, 40000), report()])).

an_update_sends_its_last_position_test() ->
    ?assertEqual([{pointer, abs, 65535, 0}],
                 sent(fold({0, 2}, {0, 2}), [abs(?ABS_X, 1), abs(?ABS_Y, 0), abs(?ABS_X, 2), report()])).

%% ABS_INFO carries no current value, so a position is first sent once both axes have
%% reported; after that an update that moves one axis keeps the other.
a_position_waits_for_both_axes_then_keeps_them_test() ->
    Fold = fold({0, 2}, {0, 2}),
    ?assertEqual([], sent(Fold, [abs(?ABS_X, 2), report()])),
    ?assertEqual([{pointer, abs, 65535, 0}, {pointer, abs, 0, 0}],
                 sent(Fold, [abs(?ABS_X, 2), report(), abs(?ABS_Y, 0), report(), abs(?ABS_X, 0), report(),
                             report()])).

syn_dropped_forgets_the_position_test() ->
    ?assertEqual([{pointer, abs, 65535, 65535}, release, {pointer, abs, 0, 0}],
                 sent(fold({0, 2}, {0, 2}), [abs(?ABS_X, 2), abs(?ABS_Y, 2), report(), dropped(), report(),
                                             abs(?ABS_X, 0), report(), abs(?ABS_Y, 0), report()])).

a_device_without_axes_counts_its_positions_test() ->
    {Sent, Fold} = run(fold(), [abs(?ABS_X, 1), abs(?ABS_Y, 1), report()]),
    ?assertEqual([], Sent),
    ?assertEqual(#{malformed => 0, unused => 2, skipped => 0}, erx_virtio_input_core:counts(Fold)).

unused_and_malformed_events_are_counted_test() ->
    {Sent, Fold} = run(fold(), [<<>>, <<1, 2, 3>>, record(?EV_KEY, ?KEY_A, 1),
                                {?EV_MSC, 4, 458756}, {?EV_SYN, 2, 0}, {?EV_REL, 6, 1}, key(?KEY_A, 7),
                                <<0:72>>, dropped(), <<0:56>>, report()]),
    ?assertEqual([{key, down, ?KEY_A}, release], Sent),
    ?assertEqual(#{malformed => 4, unused => 4, skipped => 1}, erx_virtio_input_core:counts(Fold)).

a_new_fold_counts_nothing_test() ->
    ?assertEqual(#{malformed => 0, unused => 0, skipped => 0}, erx_virtio_input_core:counts(fold())).
