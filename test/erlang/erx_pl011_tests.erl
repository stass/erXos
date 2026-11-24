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
    ?assertEqual({[$a, $b, lost, $c, $\n], drained}, erx_pl011:drain(dev, mark, erx_uart_input:new(64))).

%% A framing, parity or break bit is no loss: the byte goes up as read, a break's NUL a byte.
other_errors_are_no_loss_test() ->
    script_receive([?ERX_HW_PL011_DR_FE_MASK bor $a, ?ERX_HW_PL011_DR_PE_MASK bor $b,
                    ?ERX_HW_PL011_DR_BE_MASK, $\n]),
    ?assertEqual({[$a, $b, 0, $\n], drained}, erx_pl011:drain(dev, mark, erx_uart_input:new(64))).

%% A line's driver, the host link's or a Bluetooth controller's, makes no loss: its bytes
%% are a protocol's, which checks its own frames.
a_line_s_driver_makes_no_loss_test() ->
    script_receive([$a, $b, ?ERX_HW_PL011_DR_OE_MASK bor $c, $\n]),
    ?assertEqual({[$a, $b, $c, $\n], drained}, erx_pl011:drain(dev, pass, erx_uart_input:new(64))).

%% A device whose RXFE never sets: a drain reads at most 64 words, two FIFO depths, and
%% returns, saying it stopped, so the driver serves its mailbox before it drains again.
a_wedged_receive_is_drained_a_bounded_amount_test() ->
    erx_device:script(#{{fr, rxfe} => [0], dr => [$x]}),
    ?assertEqual({lists:duplicate(64, $x), stopped}, erx_pl011:drain(dev, pass, erx_uart_input:new(64))).

%% A drain reads no more words than its store has room for bytes, leaving the rest in the
%% FIFO, and a word's loss takes no room: a store with room for two takes "a", the loss
%% and "b" of an OE word, and stops.
a_drain_reads_no_more_than_its_store_has_room_for_test() ->
    script_receive([$a, ?ERX_HW_PL011_DR_OE_MASK bor $b, $c]),
    Store = erx_uart_input:add(lists:duplicate(62, $x), erx_uart_input:new(64)),
    ?assertEqual({[$a, lost, $b], stopped}, erx_pl011:drain(dev, mark, Store)).

%% A paste longer than a drain, its bytes arriving as the drain reads, so the FIFO never
%% reads empty: the delivery's drain stops at its bound and the words left raise no
%% interrupt, as QEMU's model raises one only when the FIFO goes from empty to one word
%% (hw/char/pl011.c, pl011_fifo_rx_put). A line's driver drains the rest without another
%% delivery and acknowledges the line once, for its one delivery.
a_drain_stopped_at_its_bound_is_continued_without_an_interrupt_test() ->
    Spec = (spec(16#9000000, 16#1000, 1, 48000000))#{stand_in => self()},
    {Input, Acks} = played(Spec),
    ?assertEqual([{erx_console_input, list_to_binary(paste())}], joined(Input)),
    ?assertEqual(1, Acks).

%% The same paste on the console's line, the console taking each message only once the
%% driver is quiet: the driver drains no more than its store has room for, pausing with the
%% words left in the FIFO until the console's answer, so every byte goes up and none becomes
%% a loss.
a_console_s_stopped_drain_waits_for_room_test() ->
    Spec = (spec(16#9000000, 16#1000, 1, 48000000))#{stand_in => self()},
    {Input, Acks} = played({console, Spec}),
    ?assertEqual([{erx_console_input, list_to_binary(paste())}], joined(Input)),
    ?assertEqual(1, Acks).

paste() ->
    [$a + N rem 26 || N <- lists:seq(0, 149)].

%% The input messages, each run of bytes joined into one.
joined([{erx_console_input, A}, {erx_console_input, B} | Rest]) ->
    joined([{erx_console_input, <<A/binary, B/binary>>} | Rest]);
joined([Message | Rest]) ->
    [Message | joined(Rest)];
joined([]) ->
    [].

%% Starts the driver of Record over a played device (test/erlang/stand_in/erx_device.erl)
%% whose receive FIFO is empty until the start unmasks its interrupts and for the start's
%% drain, then holds paste() and delivers the
%% line once. This process is the driver's owner too: it answers each input message with
%% erx_console_taken only once the driver has been quiet for 100 ms. Returns the input
%% messages, in order, and how many times the driver acknowledged the line.
played(Record) ->
    Driver = proc_lib:spawn_link(erx_pl011, init, [Record, self()]),
    try
        play(Driver, {before_start, paste()}, {[], 0, false})
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

play(Driver, Fifo, Seen = {Input, Acks, Unanswered}) ->
    receive
        {erx_device, Driver, {write, imsc, Unmasked}} when Unmasked =/= 0, element(1, Fifo) =:= before_start ->
            {before_start, Paste} = Fifo,
            answer(Driver, ok),
            play(Driver, {started, Paste}, Seen);
        {erx_device, Driver, {read_field, fr, rxfe}} ->
            case Fifo of
                {started, Paste} ->
                    answer(Driver, 1),
                    Driver ! {erx_irq, {stand_in, self()}, 0},
                    play(Driver, Paste, Seen);
                {before_start, _} ->
                    answer(Driver, 1),
                    play(Driver, Fifo, Seen);
                [] ->
                    answer(Driver, 1),
                    play(Driver, Fifo, Seen);
                [_ | _] ->
                    answer(Driver, 0),
                    play(Driver, Fifo, Seen)
            end;
        {erx_device, Driver, {read, dr}} ->
            [Byte | Rest] = Fifo,
            answer(Driver, Byte),
            play(Driver, Rest, Seen);
        {erx_device, Driver, {read_field, ibrd, baud_divint}} ->
            answer(Driver, 26),
            play(Driver, Fifo, Seen);
        {erx_device, Driver, {read_field, fbrd, baud_divfrac}} ->
            answer(Driver, 3),
            play(Driver, Fifo, Seen);
        {erx_device, Driver, {ack, 0}} ->
            answer(Driver, ok),
            play(Driver, Fifo, {Input, Acks + 1, Unanswered});
        {erx_device, Driver, {read, _Register}} ->
            answer(Driver, 0),
            play(Driver, Fifo, Seen);
        {erx_device, Driver, {read_field, _Register, _Field}} ->
            answer(Driver, 0),
            play(Driver, Fifo, Seen);
        {erx_device, Driver, _Write} ->
            answer(Driver, ok),
            play(Driver, Fifo, Seen);
        Message when element(1, Message) =:= erx_console_input; Message =:= erx_console_lost ->
            play(Driver, Fifo, {[Message | Input], Acks, true})
    after 100 ->
            case Unanswered of
                true ->
                    Driver ! erx_console_taken,
                    play(Driver, Fifo, {Input, Acks, false});
                false ->
                    {lists:reverse(Input), Acks}
            end
    end.

answer(Driver, Answer) ->
    Driver ! {erx_device, Answer}.

%% A console that answers late while a paste arrives in bursts of ten bytes, each burst
%% reaching the FIFO once a drain has read it empty and raising the line (late/1): the
%% driver reads no more than its store has room for, masks its receive interrupts while
%% the store is full and leaves the words in the FIFO, which holds them, as QEMU's model
%% holds the line's bytes back, and on the console's answer unmasks them and drains. So
%% every byte goes up, none as a loss, one message at a time, and the line ends unmasked.
a_late_console_leaves_its_input_in_the_fifo_test() ->
    Spec = (spec(16#9000000, 16#1000, 1, 48000000))#{stand_in => self()},
    Paste = [$a + N rem 26 || N <- lists:seq(0, 199)],
    #{input := Input, imsc := Imsc, masks := Masks} = late({console, Spec}, chunks(Paste, 10)),
    ?assertEqual([{erx_console_input, list_to_binary(Paste)}], joined(Input)),
    ?assert(Masks > 0),
    ?assert(Imsc).

%% Starts the driver of Record over a played PL011 whose bursts Bursts reach its FIFO one at
%% a time, the next whenever FR shows the FIFO empty, and whose line is the level of RIS
%% under IMSC: a burst sets RIS, as the receive timeout does for words still waiting when
%% a delivery is acknowledged, ICR clears it, and the line is delivered when it is high and
%% the last delivery has been acknowledged, at most 100 times. This process is the driver's console too:
%% it answers an input message with erx_console_taken only once the driver has been quiet
%% for 100 ms, and fails the case on a second message sent before the answer or on the
%% driver's crash. Returns the input messages in order, whether IMSC ends unmasked and how
%% many times it was masked after the start.
late(Record, Bursts) ->
    Driver = proc_lib:spawn(erx_pl011, init, [Record, self()]),
    _ = monitor(process, Driver),
    try
        late_play(Driver, #{fifo => [], bursts => Bursts, imsc => false, ris => false,
                            out => false, started => false, masks => 0, acks => 0,
                            input => [], unanswered => false})
    after
        exit(Driver, kill)
    end.

late_play(Driver, Line) ->
    receive
        {erx_device, Driver, Call} ->
            {Answer, Next} = late_answer(Call, Line),
            answer(Driver, Answer),
            late_play(Driver, late_raise(Driver, Next));
        Message when element(1, Message) =:= erx_console_input; Message =:= erx_console_lost ->
            ?assertNot(maps:get(unanswered, Line)),
            late_play(Driver, Line#{input := [Message | maps:get(input, Line)], unanswered := true});
        {'DOWN', _, process, Driver, Reason} ->
            error({driver_down, Reason})
    after 100 ->
            case Line of
                #{unanswered := true} ->
                    Driver ! erx_console_taken,
                    late_play(Driver, Line#{unanswered := false});
                #{input := Input} ->
                    Line#{input := lists:reverse(Input)}
            end
    end.

late_answer({read_field, fr, rxfe}, Line = #{fifo := [], bursts := [Burst | Rest]}) ->
    {1, Line#{fifo := Burst, bursts := Rest, ris := true}};
late_answer({read_field, fr, rxfe}, Line = #{fifo := Fifo}) ->
    {case Fifo of [] -> 1; _ -> 0 end, Line};
late_answer({read, dr}, Line = #{fifo := [Byte | Rest]}) ->
    {Byte, Line#{fifo := Rest}};
late_answer({read, ris}, Line = #{ris := Ris}) ->
    {rx_bits(Ris), Line};
late_answer({read, mis}, Line = #{ris := Ris, imsc := Imsc}) ->
    {rx_bits(Ris andalso Imsc), Line};
late_answer({write, icr, Bits}, Line) ->
    {ok, Line#{ris := maps:get(ris, Line) andalso Bits band rx_bits(true) =:= 0}};
late_answer({write, imsc, 0}, Line = #{started := true, masks := Masks}) ->
    {ok, Line#{imsc := false, masks := Masks + 1}};
late_answer({write, imsc, 0}, Line) ->
    {ok, Line#{imsc := false}};
late_answer({write, imsc, _Unmasked}, Line) ->
    {ok, Line#{imsc := true, started := true}};
late_answer({read_field, ibrd, baud_divint}, Line) ->
    {26, Line};
late_answer({read_field, fbrd, baud_divfrac}, Line) ->
    {3, Line};
late_answer({ack, 0}, Line = #{acks := Acks, ris := Ris, fifo := Fifo}) ->
    ?assert(Acks < 100),
    {ok, Line#{out := false, acks := Acks + 1, ris := Ris orelse Fifo =/= []}};
late_answer({read, _Register}, Line) ->
    {0, Line};
late_answer({read_field, _Register, _Field}, Line) ->
    {0, Line};
late_answer(_Write, Line) ->
    {ok, Line}.

%% The line delivered when RIS shows under IMSC and no delivery waits for its acknowledgement.
late_raise(Driver, Line = #{ris := true, imsc := true, out := false}) ->
    Driver ! {erx_irq, {stand_in, self()}, 0},
    Line#{out := true};
late_raise(_Driver, Line) ->
    Line.

%% The receive and receive-timeout interrupts' bits, as RIS, MIS and ICR place them.
rx_bits(true) -> ?ERX_HW_PL011_ICR_RXIC_MASK bor ?ERX_HW_PL011_ICR_RTIC_MASK;
rx_bits(false) -> 0.

%% A full store takes a loss, which needs no room, and refuses a byte with a crash, since a
%% driver that gives it one has read more than room/1 allowed.
a_full_store_refuses_a_byte_test() ->
    Full = erx_uart_input:add(lists:duplicate(64, $x) ++ [lost], erx_uart_input:new(64)),
    ?assertEqual(0, erx_uart_input:room(Full)),
    ?assertError(input_store_full, erx_uart_input:add([$y], Full)).

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
