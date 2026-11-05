%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_pl011:console_uart/1, the parse of the console's device words from the
%% boot information. Each malformed form ends in a stated reason, never in an exception.
%% test/host/erx_pl011_test.rb runs them on stock's emulator.

-module(erx_pl011_tests).
-include_lib("eunit/include/eunit.hrl").

-define(U64_MAX, "18446744073709551615").
-define(U32_MAX, "4294967295").

parse(Arguments) ->
    erx_pl011:console_uart(Arguments).

spec(Base, Size, Line) ->
    #{peripheral => pl011, window => {physical, Base, Size}, lines => [Line]}.

one_entry_test() ->
    ?assertEqual({ok, spec(150994944, 4096, 33)}, parse([["console_uart", "150994944", "4096", "33"]])).

other_entries_and_trailing_words_are_left_alone_test() ->
    ?assertEqual({ok, spec(1, 2, 3)},
                 parse([["debug"], ["console_uart", "1", "2", "3", "quiet"], []])).

largest_values_test() ->
    ?assertEqual({ok, spec(18446744073709551615, 18446744073709551615, 4294967295)},
                 parse([["console_uart", ?U64_MAX, ?U64_MAX, ?U32_MAX]])).

absent_test() ->
    ?assertMatch({error, {no_console_uart, _}}, parse([])),
    ?assertMatch({error, {no_console_uart, _}}, parse([["debug"], []])).

duplicate_test() ->
    Entry = ["console_uart", "1", "2", "3"],
    ?assertMatch({error, {bad_console_uart, "more than one" ++ _}}, parse([Entry, Entry])),
    ?assertMatch({error, {bad_console_uart, "more than one" ++ _}}, parse([Entry, ["console_uart"]])).

truncated_test() ->
    lists:foreach(fun(Words) ->
                          ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart" | Words]]))
                  end, [[], ["1"], ["1", "2"]]).

non_numeric_test() ->
    lists:foreach(fun(Word) ->
                          ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", Word, "2", "3"]])),
                          ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", "1", Word, "3"]])),
                          ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", "1", "2", Word]]))
                  end, ["", "x", "-1", "+1", " 1", "1 ", "0x10", "1e3", "1_000", [$1, 16#661]]).

oversized_test() ->
    Over64 = integer_to_list((1 bsl 64)),
    Over32 = integer_to_list((1 bsl 32)),
    Long = lists:duplicate(10000, $9),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", Over64, "2", "3"]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", "1", Over64, "3"]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", "1", "2", Over32]])),
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", Long, "2", "3"]])),
    %% Leading zeros past the width of the largest value are refused too: the boot writes none.
    ?assertMatch({error, {bad_console_uart, _}}, parse([["console_uart", "0" ++ ?U64_MAX, "2", "3"]])).
