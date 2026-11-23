%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_pl011:console_uart/1, the parse of the console's device words from the
%% boot information, of erx_pl011:baud_divisors/1, and of erx_pl011:program/1, the register
%% steps of a driver's start. Each malformed form ends in a stated reason, never in an
%% exception. test/host/erx_pl011_test.rb runs them on stock's emulator.

-module(erx_pl011_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_pl011.hrl").

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

%% erx_pl011:program/1, the register steps a driver runs over its UART
%% (docs/design-bluetooth.md, "A reset", "Its driver is erx_pl011, started fresh"). A line's
%% record, init fresh, programs the UART from nothing in the manual's order (DDI 0183G
%% 3-16): disabled with every interrupt masked, FIFOs flushed by clearing FEN and the receive side drained by at most
%% 33 reads, the record's divisors before the LCR_H write that latches them (3-14), every
%% interrupt cleared, and CR written whole last, with both flow enables under rts_cts.
fresh(Flow) ->
    #{peripheral => pl011, window => {physical, 16#fe201000, 16#200}, lines => [153],
      clock => 48000000, init => fresh, rate => 115200, flow => Flow}.

enabled() ->
    ?ERX_HW_PL011_CR_UARTEN_PUT(1) bor ?ERX_HW_PL011_CR_TXE_PUT(1) bor ?ERX_HW_PL011_CR_RXE_PUT(1).

every_interrupt() ->
    lists:foldl(fun(Mask, Word) -> Word bor Mask end, 0,
                [?ERX_HW_PL011_ICR_RIMIC_MASK, ?ERX_HW_PL011_ICR_CTSMIC_MASK, ?ERX_HW_PL011_ICR_DCDMIC_MASK,
                 ?ERX_HW_PL011_ICR_DSRMIC_MASK, ?ERX_HW_PL011_ICR_RXIC_MASK, ?ERX_HW_PL011_ICR_TXIC_MASK,
                 ?ERX_HW_PL011_ICR_RTIC_MASK, ?ERX_HW_PL011_ICR_FEIC_MASK, ?ERX_HW_PL011_ICR_PEIC_MASK,
                 ?ERX_HW_PL011_ICR_BEIC_MASK, ?ERX_HW_PL011_ICR_OEIC_MASK]).

fresh_steps(Cr) ->
    [{write, cr, 0}, {write, imsc, 0}, wait_character,
     {field, lcr_h, fen, 0}, {drain_receive, 33},
     {write, ibrd, 26}, {write, fbrd, 3},
     {write, lcr_h, ?ERX_HW_PL011_LCR_H_WLEN_PUT(3) bor ?ERX_HW_PL011_LCR_H_FEN_PUT(1)},
     {write, icr, every_interrupt()},
     {write, cr, Cr}].

fresh_without_flow_test() ->
    ?assertEqual({ok, fresh_steps(enabled())}, erx_pl011:program(fresh(none))).

fresh_with_rts_cts_test() ->
    Cr = enabled() bor ?ERX_HW_PL011_CR_RTSEN_PUT(1) bor ?ERX_HW_PL011_CR_CTSEN_PUT(1),
    ?assertEqual({ok, fresh_steps(Cr)}, erx_pl011:program(fresh(rts_cts))).

%% The console's and the host link's record, with no init or init keep, keeps what the
%% boot left: the transmitter idle, the UART disabled for one character, its interrupts
%% masked and cleared, the boot's divisors unless it left none, eight bits, FIFOs on.
keep_steps() ->
    [wait_idle, {field, cr, uarten, 0}, wait_character, {write, imsc, 0}, clear_raw,
     {default_divisors, 26, 3}, {field, lcr_h, wlen, 3}, {field, lcr_h, fen, 1},
     {field, cr, rxe, 1}, {field, cr, txe, 1}, {field, cr, uarten, 1}].

keep_test() ->
    Console = spec(16#9000000, 16#1000, 1, 48000000),
    ?assertEqual({ok, keep_steps()}, erx_pl011:program(Console)),
    ?assertEqual({ok, keep_steps()}, erx_pl011:program(Console#{init => keep})).

%% A record the driver cannot program is refused with a stated reason before any step: no
%% clock, a clock with no divisor for the rate, a fresh record without its rate or flow or
%% with a rate other than 115200, a line's record without its init, a flow of neither word,
%% and an init of neither word.
refused_test() ->
    Fresh = fresh(none),
    ?assertMatch({error, {no_uart_clock, _}}, erx_pl011:program(maps:remove(clock, Fresh))),
    ?assertMatch({error, {pl011_clock, _}}, erx_pl011:program(Fresh#{clock => 1000})),
    ?assertMatch({error, {bad_line_record, _}}, erx_pl011:program(maps:remove(rate, Fresh))),
    ?assertMatch({error, {bad_line_record, _}}, erx_pl011:program(Fresh#{rate => 9600})),
    ?assertMatch({error, {bad_line_record, _}}, erx_pl011:program(maps:remove(init, Fresh))),
    ?assertMatch({error, {bad_line_record, _}}, erx_pl011:program(maps:remove(flow, Fresh))),
    ?assertMatch({error, {bad_line_record, _}}, erx_pl011:program(Fresh#{flow => xon})),
    ?assertMatch({error, {bad_line_record, _}}, erx_pl011:program(Fresh#{init => warm})).

%% A crash report of the driver shows only its reason's name: it exports format_status/1,
%% which is what makes proc_lib hide the mailbox (the bytes the line sent to write), the
%% dictionary and the frames' arguments.
format_status_shows_only_the_reasons_name_test() ->
    {module, erx_pl011} = code:ensure_loaded(erx_pl011),
    ?assert(erlang:function_exported(erx_pl011, format_status, 1)),
    Status = erx_pl011:format_status(#{reason => {badmatch, <<"SECRET">>}, state => <<"SECRET">>,
                                       message => {erx_console_output, make_ref(), <<"SECRET">>}}),
    ?assertEqual(#{reason => badmatch, state => hidden, message => hidden}, Status).

%% The console's drain over a scripted device (test/erlang/stand_in/erx_device.erl): FR
%% shows a byte waiting four times, then the FIFO empty, and DR gives the words. The word
%% whose OE bit is set is the first byte pushed after the loss, since the receive FIFO
%% stores the overrun status with the character that follows it (BCM2711 ARM Peripherals,
%% 11.5, DR), so the loss goes before that byte and the newline after it does not send the
%% damaged line out whole (docs/design-live.md, "Lost input").
overrun_is_placed_before_the_byte_after_the_loss_test() ->
    script_receive([$a, $b, ?ERX_HW_PL011_DR_OE_MASK bor $c, $\n]),
    ?assertEqual([$a, $b, lost, $c, $\n], erx_pl011:drain(dev, mark)).

%% A framing, parity or break bit is no loss: the byte goes up as read, a break's NUL a byte.
other_errors_are_no_loss_test() ->
    script_receive([?ERX_HW_PL011_DR_FE_MASK bor $a, ?ERX_HW_PL011_DR_PE_MASK bor $b,
                    ?ERX_HW_PL011_DR_BE_MASK, $\n]),
    ?assertEqual([$a, $b, 0, $\n], erx_pl011:drain(dev, mark)).

%% A line's driver, the host link's or a Bluetooth controller's, makes no loss: its bytes
%% are a protocol's, which checks its own frames.
a_line_s_driver_makes_no_loss_test() ->
    script_receive([$a, $b, ?ERX_HW_PL011_DR_OE_MASK bor $c, $\n]),
    ?assertEqual([$a, $b, $c, $\n], erx_pl011:drain(dev, pass)).

%% A device whose RXFE never sets: a drain reads at most 64 words, two FIFO depths, and
%% returns, so the driver serves its mailbox; the line, still raised, delivers again.
a_wedged_receive_is_drained_a_bounded_amount_test() ->
    erx_device:script(#{{fr, rxfe} => [0], dr => [$x]}),
    ?assertEqual(lists:duplicate(64, $x), erx_pl011:drain(dev, pass)).

%% The console stalled, its driver's one input message not yet taken, while 200 bytes
%% arrive in drains of at most 64: the store holds one drain's bytes and one loss for the
%% rest, kept though its bytes fill it, and sends them in order, one per answer.
a_stalled_console_holds_one_drain_and_one_loss_test() ->
    Paste = [$a + N rem 26 || N <- lists:seq(0, 199)],
    {First, Rest} = lists:split(64, Paste),
    {Sent, Waiting} = erx_uart_input:next(erx_uart_input:add(First, erx_uart_input:new(64))),
    ?assertEqual({erx_console_input, list_to_binary(First)}, Sent),
    Stalled = lists:foldl(fun erx_uart_input:add/2, Waiting, chunks(Rest, 64)),
    ?assertMatch({none, _}, erx_uart_input:next(Stalled)),
    ?assertEqual([{erx_console_input, list_to_binary(lists:sublist(Rest, 64))}, erx_console_lost],
                 answered(Stalled)).

%% Losses with no byte between them are one, in the store and against the loss last sent.
losses_with_no_byte_between_are_one_test() ->
    Store = erx_uart_input:add([lost, lost, $a, lost], erx_uart_input:new(64)),
    {erx_console_lost, Waiting} = erx_uart_input:next(Store),
    ?assertEqual([{erx_console_input, <<"a">>}, erx_console_lost], answered(Waiting)),
    {erx_console_lost, Again} = erx_uart_input:next(erx_uart_input:add([lost], erx_uart_input:new(64))),
    ?assertEqual([], answered(erx_uart_input:add([lost], Again))).

%% The messages a waiting store sends, one per answer, until it holds none.
answered(Store) ->
    case erx_uart_input:next(erx_uart_input:taken(Store)) of
        {none, _} -> [];
        {Message, Next} -> [Message | answered(Next)]
    end.

chunks([], _Size) -> [];
chunks(List, Size) when length(List) =< Size -> [List];
chunks(List, Size) -> {Chunk, Rest} = lists:split(Size, List), [Chunk | chunks(Rest, Size)].

script_receive(Words) ->
    erx_device:script(#{{fr, rxfe} => lists:duplicate(length(Words), 0) ++ [1], dr => Words}).

%% Which start marks: the console's driver, and no line's, whether the host link's or a
%% Bluetooth controller's record.
only_the_console_s_driver_marks_test() ->
    ?assertEqual(mark, erx_pl011:on_overrun(console)),
    ?assertEqual(pass, erx_pl011:on_overrun(fresh(rts_cts))),
    ?assertEqual(pass, erx_pl011:on_overrun(spec(16#9000000, 16#1000, 1, 48000000))).
