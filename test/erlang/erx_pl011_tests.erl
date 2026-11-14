%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_pl011:console_uart/1, the parse of the console's device words from the
%% boot information, and of erx_pl011:baud_divisors/1. Each malformed form ends in a stated
%% reason, never in an exception. test/host/erx_pl011_test.rb runs them on stock's emulator.

-module(erx_pl011_tests).
-include_lib("eunit/include/eunit.hrl").

-define(U64_MAX, "18446744073709551615").
-define(U32_MAX, "4294967295").

parse(Arguments) ->
    erx_pl011:console_uart(Arguments).

spec(Base, Size, Line, Clock) ->
    #{peripheral => pl011, window => {physical, Base, Size}, lines => [Line], clock => Clock}.

one_entry_test() ->
    ?assertEqual({ok, spec(150994944, 4096, 33, 24000000)},
                 parse([["console", "pl011", "150994944", "4096", "33", "direct", "24000000"]])).

other_entries_and_trailing_words_are_left_alone_test() ->
    ?assertEqual({ok, spec(1, 2, 3, 4)},
                 parse([["debug"], ["console", "pl011", "1", "2", "3", "direct", "4", "quiet"], []])).

largest_values_test() ->
    ?assertEqual({ok, spec(18446744073709551615, 18446744073709551615, 4294967295, 4294967295)},
                 parse([["console", "pl011", ?U64_MAX, ?U64_MAX, ?U32_MAX, "direct", ?U32_MAX]])).

absent_test() ->
    ?assertMatch({error, {no_console_uart, _}}, parse([])),
    ?assertMatch({error, {no_console_uart, _}}, parse([["debug"], []])).

%% The console record of another peripheral is not the PL011's.
another_uart_s_record_is_not_the_pl011_s_test() ->
    ?assertMatch({error, {no_console_uart, _}}, parse([["console", "mini_uart", "1", "2", "3", "direct", "4"]])),
    ?assertMatch({error, {no_console_uart, _}}, parse([["console", "stdio"]])).

duplicate_test() ->
    Entry = ["console", "pl011", "1", "2", "3", "direct", "4"],
    ?assertMatch({error, {bad_console_uart, "more than one" ++ _}}, parse([Entry, Entry])),
    ?assertMatch({error, {bad_console_uart, "more than one" ++ _}}, parse([Entry, ["console", "pl011"]])).

truncated_test() ->
    lists:foreach(fun(Words) ->
                          ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011" | Words]]))
                  end, [[], ["1"], ["1", "2"], ["1", "2", "3"], ["1", "2", "3", "direct"], ["1", "2", "3", "4"]]).

non_numeric_test() ->
    lists:foreach(fun(Word) ->
                          ?assertMatch({error, {bad_console_uart, _}},
                                       parse([["console", "pl011", Word, "2", "3", "direct", "4"]])),
                          ?assertMatch({error, {bad_console_uart, _}},
                                       parse([["console", "pl011", "1", Word, "3", "direct", "4"]])),
                          ?assertMatch({error, {bad_console_uart, _}},
                                       parse([["console", "pl011", "1", "2", Word, "direct", "4"]])),
                          ?assertMatch({error, {bad_console_uart, _}},
                                       parse([["console", "pl011", "1", "2", "3", "direct", Word]]))
                  end, ["", "x", "-1", "+1", " 1", "1 ", "0x10", "1e3", "1_000", [$1, 16#661]]).

oversized_test() ->
    Over64 = integer_to_list((1 bsl 64)),
    Over32 = integer_to_list((1 bsl 32)),
    Long = lists:duplicate(10000, $9),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011", Over64, "2", "3", "direct", "4"]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011", "1", Over64, "3", "direct", "4"]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011", "1", "2", Over32, "direct", "4"]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011", "1", "2", "3", "direct", Over32]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011", Long, "2", "3", "direct", "4"]])),
    %% Leading zeros past the width of the largest value are refused too: the boot writes none.
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console", "pl011", "0" ++ ?U64_MAX, "2", "3", "direct", "4"]])).

%% The console's line is marked shared when another device of its unit names it too, as
%% the Raspberry Pi 4's mini UART's line 125 is the SPI controllers' (docs/design-shared-devices.md,
%% "Lines inside a domain"), and erx_device:open/1 takes it marked.
shared_line_test() ->
    ?assertEqual({ok, #{peripheral => pl011, window => {physical, 1, 2}, lines => [{shared, 3}], clock => 4}},
                 parse([["console", "pl011", "1", "2", "3", "shared", "4"]])).

%% Only the two words mark a line: anything else refuses the entry rather than reading it
%% as one mark or the other.
bad_mark_test() ->
    lists:foreach(fun(Mark) ->
                          ?assertMatch({error, {bad_console_uart, "the console's line mark" ++ _}},
                                       parse([["console", "pl011", "1", "2", "3", Mark, "4"]]))
                  end, ["", "Shared", "DIRECT", "shared ", " direct", "share", "directly", "1", "shared\n"]).

%% A clock of 0 Hz times nothing and divides no rate: the manifest check refuses a PL011 entry
%% without a clock, and the parse refuses one that arrives anyway.
zero_clock_test() ->
    ?assertMatch({error, {bad_console_uart, "the console's clock" ++ _}},
                 parse([["console", "pl011", "150994944", "4096", "33", "direct", "0"]])).

%% The divisors for 115200 baud, clock / (16 * 115200) in sixty-fourths rounded to the nearest
%% (DDI 0183G 3-10): QEMU virt's 24 MHz gives 13 + 1/64, a 48 MHz clock 26 + 3/64, the
%% slowest clock with an integer part of at least 1 gives 1 + 0/64, and a slower one is
%% refused, as is a clock of 0. The largest 32-bit clock stays well inside IBRD's 16 bits.
baud_divisors_test() ->
    ?assertEqual({ok, 13, 1}, erx_pl011:baud_divisors(24000000)),
    ?assertEqual({ok, 26, 3}, erx_pl011:baud_divisors(48000000)),
    ?assertEqual({ok, 1, 0}, erx_pl011:baud_divisors(1828800)),
    ?assertMatch({error, {pl011_clock, _}}, erx_pl011:baud_divisors(1828799)),
    ?assertMatch({error, {pl011_clock, _}}, erx_pl011:baud_divisors(0)),
    ?assertEqual({ok, 2330, 11}, erx_pl011:baud_divisors(4294967295)).
