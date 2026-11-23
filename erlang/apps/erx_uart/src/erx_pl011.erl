%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The driver of an Arm PrimeCell UART PL011 (docs/design-runtime.md, "The console and
%% standard I/O"; Arm DDI 0183G for the register rules cited below), for the console and for
%% the host link's line (docs/design-live.md, "The host link") and for a line the line
%% service serves (docs/design-bluetooth.md, "The controller's line"). It speaks the driver's
%% messages that erx_console documents to the one process it serves, its owner, and passes
%% bytes unchanged both ways: what a terminal does with them is the tty layer's business,
%% above this module, and the host link's bytes are erx_hostlink's. The owner is the line's
%% one sink: only it sends the driver bytes to write.
%%
%% Receiving: FIFO interrupts fire when a level is crossed (3-17), so one delivery drains
%% the FIFO to empty, and the receive timeout is unmasked with the receive interrupt, since
%% a byte below the level raises nothing else (3-19). Bytes typed before the driver started
%% raise nothing either once reprogramming has cleared the raw interrupts, so the driver
%% drains the FIFO once after unmasking. Interrupts are cleared before the drain and the
%% line acknowledged after it, so a byte that arrives during the drain fires the line
%% again. A framing, parity, break or overrun bit on a byte is not a reason to drop it:
%% the byte goes up as read. The console's driver sends a loss as erx_console_lost, in order
%% with its bytes (docs/design-live.md, "Lost input"): the receive FIFO stores the overrun
%% status with each character it pushes (BCM2711 ARM Peripherals, 11.5, DR), so the loss
%% goes before the byte whose word has OE set (received/2), unverified on silicon, since
%% QEMU's model sets no OE. If OE rides on the first
%% character pushed after the loss, that is the loss's place; if on the last one the full
%% FIFO held, the loss goes one byte early; either way no byte that came after the loss is
%% sent before it. Another line's driver makes no loss: the host link's and a Bluetooth
%% controller's bytes are a protocol's, which checks its own frames. A drain reads at most
%% ?DRAIN_WORDS words, two FIFO depths, so a device whose RXFE never sets holds no driver.
%%
%% One input message outstanding: the console's driver sends its next input message only
%% after the console's erx_console_taken answers the last, and drains meanwhile into a store
%% of one drain's bytes (erx_uart_input). A send takes a waiting answer between its bytes,
%% so output never waits on input being taken, nor input on output. A line's driver hands
%% each drain up as read, as its owner bounds what it holds.
%%
%% Sending: one byte per free FIFO slot. A full FIFO waits a millisecond at a time with the
%% receive side still served. A UART at 115200 baud frees eleven slots a millisecond, so no
%% interrupt is worth unmasking for it.

-module(erx_pl011).

-export([start_link/1, start_link/2]).
-export([init/2, format_status/1]).
-export([console_records/0, console_uart/1, baud_divisors/1, program/1]).
%% Exported for its tests.
-export([drain/2, on_overrun/1]).
-export_type([step/0]).

-include("generated/erx_hw_pl011.hrl").

%% The spec's one line.
-define(RX_LINE, 0).
%% LCR_H's word length for eight bits.
-define(WLEN_8, 3).
%% The rate the driver programs into a UART the boot left unprogrammed (3-10: an integer
%% divisor of 0 is invalid), as Fiasco leaves QEMU virt's and the Raspberry Pi 4's firmware
%% leaves UART3. Its divisors come from the UART's clock, which the board's platform record
%% gives with the UART's window and line.
-define(BAUD, 115200).
%% The longest character a line format the boot chose can have: a start bit, eight data
%% bits, a parity bit and two stop bits.
-define(CHARACTER_BITS, 12).
%% How many reads of FR wait for the transmitter to go idle before reprogramming.
-define(BUSY_READS, 100000).
-define(FULL_WAIT_MS, 1).
%% The reads that empty the receive side: the FIFO's 32 entries (2-6) and the holding
%% register.
-define(RX_DRAIN_READS, 33).
%% The words one delivery's drain reads at most: two FIFO depths.
-define(DRAIN_WORDS, 64).

%% The driver's state: its device, its line, the process it serves, whether it makes a
%% loss of an overrun, which only the console's driver does, and the console's input not
%% yet sent (erx_uart_input), which a line's driver leaves empty.
-record(driver, {dev :: erx_device:device(),
                 irq :: erx_irq_line:handle(),
                 owner :: pid(),
                 on_overrun :: on_overrun(),
                 input :: erx_uart_input:input()}).
-type on_overrun() :: mark | pass.

%% One step of a driver's start over its UART (program/1), which run/3 performs: a
%% register written whole or one field of it, the transmitter waited idle, one character
%% time waited at the divisors the UART holds, the raw interrupts cleared, the receive
%% side read empty in at most so many reads, and divisors written only where the boot left
%% none.
-type step() :: {write, erx_device:register_name(), non_neg_integer()}
              | {field, erx_device:register_name(), atom(), non_neg_integer()}
              | wait_idle | wait_character | clear_raw | {drain_receive, pos_integer()}
              | {default_divisors, pos_integer(), 0..63}.

%% The console's driver, on the UART of `-erx_record console pl011`. Terminal is true: a person's
%% terminal is on the line, so the group edits lines.
-spec start_link(Console :: pid()) -> {ok, pid(), Terminal :: boolean()}.
start_link(Console) ->
    proc_lib:start_link(?MODULE, init, [console, Console]).

%% The driver of the UART Spec, a device record (erx_device_record), for Owner.
-spec start_link(erx_device:spec(), Owner :: pid()) -> {ok, pid()}.
start_link(Spec, Owner) ->
    proc_lib:start_link(?MODULE, init, [Spec, Owner]).

-spec init(console | erx_device:spec(), pid()) -> no_return().
init(console, Console) ->
    start(spec(), Console, {ok, self(), true}, on_overrun(console));
init(Spec, Owner) ->
    start(Spec, Owner, {ok, self()}, on_overrun(Spec)).

%% Whether a driver makes a loss of an overrun: the console's does, for the console to
%% refuse the damaged line; a line's, the host link's or a Bluetooth controller's, passes
%% its bytes as read, since they are a protocol's, which checks its own frames.
-spec on_overrun(console | erx_device:spec()) -> on_overrun().
on_overrun(console) -> mark;
on_overrun(#{}) -> pass.

-doc """
Its existence is what makes proc_lib's crash report of this process hide its terms
(gen:hides_terms/1): the report then shows neither the mailbox, which holds the bytes the
line sent to write (a Bluetooth line's carry keys, the console's a typed passphrase), nor
the process dictionary, nor a stack frame's arguments, but only the reason's leading atom
(erx_report:reason_name/1). The driver's own state is not shown either: its input store
holds typed bytes.
""".
-spec format_status(#{atom() => term()}) -> #{atom() => term()}.
format_status(Status) ->
    erx_report:status(Status, #{}).

%% A record program/1 refuses stops the driver with its reason before it touches the UART.
%% IMSC is written whole once the line is attached, whichever the start: the receive and
%% receive-timeout interrupts and no other.
start(Spec, Owner, Ack, OnOverrun) ->
    Steps = case program(Spec) of
                {ok, Program} -> Program;
                {error, Reason} -> exit(Reason)
            end,
    #{clock := Clock} = Spec,
    {ok, Dev} = erx_device:open(Spec),
    lists:foreach(fun(Step) -> run(Dev, Clock, Step) end, Steps),
    {ok, Irq} = erx_irq_line:attach(Dev, ?RX_LINE),
    ok = erx_device:write(Dev, imsc, ?ERX_HW_PL011_IMSC_RXIM_PUT(1) bor ?ERX_HW_PL011_IMSC_RTIM_PUT(1)),
    proc_lib:init_ack(Ack),
    S = #driver{dev = Dev, irq = Irq, owner = Owner, on_overrun = OnOverrun,
                input = erx_uart_input:new(?DRAIN_WORDS)},
    loop(deliver_input(S)).

%% The console's record, for the console to start its line's owner before the driver.
-spec console_records() -> [erx_device:spec()].
console_records() ->
    [spec()].

%% The root's words from the manifest's device entry for the console, as the boot information
%% carries them to init's arguments. A failure exits with a stated reason, so a malformed
%% entry stops the driver with that reason rather than a crash in the middle of the parse.
spec() ->
    case console_uart(erx_device_record:records()) of
        {ok, Spec} -> Spec;
        {error, Reason} -> exit(Reason)
    end.

%% `-erx_record console pl011 BASE SIZE LINE MARK CLOCK`, once, each number in decimal and within its
%% field of the boot manifest's console (64, 64, 32 and 32 bits), the clock in hertz and not
%% 0. MARK is `shared` when another device of the console's unit names its line, which
%% reaches erx_device:open/1 as `{shared, Line}`, and `direct` otherwise; any other word
%% refuses the entry. A plain word of the kernel command line can follow the clock, so an
%% entry may be longer. A pure function, exported for its tests and fuzz target.
-spec console_uart([[string()]]) -> {ok, erx_device:spec()} | {error, {atom(), string()}}.
console_uart(Arguments) ->
    case [Words || ["console", "pl011" | Words] <- Arguments] of
        [[Base, Size, Line, Mark, Clock | _]] ->
            case {number(Base, 64), number(Size, 64), number(Line, 32), number(Clock, 32), mark(Mark)} of
                {{ok, _}, {ok, _}, {ok, _}, {ok, 0}, _} ->
                    {error, {bad_console_uart, "the console's clock is 0 Hz"}};
                {{ok, B}, {ok, S}, {ok, L}, {ok, C}, {ok, Sharing}} ->
                    {ok, #{peripheral => pl011, window => {physical, B, S}, lines => [marked(Sharing, L)],
                           clock => C}};
                {{ok, _}, {ok, _}, {ok, _}, {ok, _}, error} ->
                    {error, {bad_console_uart, "the console's line mark is neither direct nor shared"}};
                _ ->
                    {error, {bad_console_uart, "the console's base, size, line or clock is not a "
                                              "decimal number of its field's width"}}
            end;
        [_] ->
            {error, {bad_console_uart, "the console record has fewer than four numbers and a line mark"}};
        [] ->
            {error, {no_console_uart, "no -erx_record console names this UART"}};
        [_, _ | _] ->
            {error, {bad_console_uart, "more than one console record of this UART"}}
    end.

%% The line's mark word (docs/design-shared-devices.md, "Lines inside a domain"), and the
%% line as erx_device:open/1 takes it.
mark("direct") -> {ok, direct};
mark("shared") -> {ok, shared};
mark(_Word) -> error.

marked(direct, Line) -> Line;
marked(shared, Line) -> {shared, Line}.

%% Digits only, at most as many as the field's largest value has, so no word builds a large
%% integer before the range check.
number(Word, Bits) ->
    Max = (1 bsl Bits) - 1,
    case Word =/= [] andalso length(Word) =< length(integer_to_list(Max))
        andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Word) of
        true ->
            case list_to_integer(Word) of
                Value when Value =< Max -> {ok, Value};
                _ -> error
            end;
        false ->
            error
    end.

%% The steps that program the UART of record Spec, in order, or a stated reason to refuse
%% the record before any of them (docs/design-bluetooth.md, "Its driver is erx_pl011,
%% started fresh"). Its init is keep where it states none. Control registers change only
%% with the UART disabled and the character in flight finished, since a disabled UART
%% completes the character it is sending or receiving before it stops (3-16); a received
%% character has no flag to say it has finished, so the driver waits one character time at
%% the divisors the UART holds, and a sent one, at the same rate, finishes within it too.
%%
%% * keep, the console's and the host link's: the boot's line stays. The transmitter is
%%   waited idle, then BUSY is not waited on again: the kernel's console can write the UART
%%   at any time, and a byte it queues while the UART is disabled holds BUSY set until the
%%   driver enables it. The FIFOs are not flushed: what the kernel queued goes out once the
%%   UART is enabled, and the receive FIFO holds what a person typed. The boot's divisors
%%   stay, and a UART the boot left unprogrammed takes those for BAUD.
%% * fresh, a line's: no interrupt, divisor, format or flow setting of the boot or the last
%%   driver stays. Every interrupt is masked with the UART disabled, so a controller's
%%   bytes raise nothing on a line another driver shares until the start ends. BUSY is never
%%   waited on, since a controller holding CTS off keeps the transmitter busy indefinitely; FEN
%%   cleared flushes the transmit FIFO and the receive side is read empty; the record's
%%   rate is divided before the LCR_H write that latches the divisors (3-14), 8 data bits,
%%   no parity, one stop bit, FIFOs on, no break; every interrupt is cleared; and CR is
%%   written whole, with RTSEN and CTSEN under rts_cts flow, so the UART holds RTS off while
%%   its receive FIFO is full and sends only while CTS is on.
%%
%% A record that carries a line's rate or flow but no init is refused rather than kept, so
%% a line's record that lost its init never keeps the boot's line. A fresh rate is BAUD's,
%% the one rate the line design names. Every refusal below throws {refused, Reason}, which
%% program/1 alone catches. A pure function, exported for its tests; run/3 performs each
%% step.
-spec program(erx_device:spec()) -> {ok, [step()]} | {error, {atom(), string()}}.
program(Spec) ->
    try
        {ok, steps(maps:get(init, Spec, keep), Spec)}
    catch
        throw:{refused, Reason} -> {error, Reason}
    end.

steps(keep, #{rate := _}) ->
    throw({refused, {bad_line_record, "a kept record carries a line's rate"}});
steps(keep, #{flow := _}) ->
    throw({refused, {bad_line_record, "a kept record carries a line's flow"}});
steps(keep, Spec) ->
    {Integer, Fraction} = divisors(Spec, ?BAUD),
    [wait_idle, {field, cr, uarten, 0}, wait_character, {write, imsc, 0}, clear_raw,
     {default_divisors, Integer, Fraction}, {field, lcr_h, wlen, ?WLEN_8}, {field, lcr_h, fen, 1},
     {field, cr, rxe, 1}, {field, cr, txe, 1}, {field, cr, uarten, 1}];
steps(fresh, #{rate := ?BAUD, flow := Flow} = Spec) ->
    {Integer, Fraction} = divisors(Spec, ?BAUD),
    Enabled = ?ERX_HW_PL011_CR_UARTEN_PUT(1) bor ?ERX_HW_PL011_CR_TXE_PUT(1) bor ?ERX_HW_PL011_CR_RXE_PUT(1),
    [{write, cr, 0}, {write, imsc, 0}, wait_character,
     {field, lcr_h, fen, 0}, {drain_receive, ?RX_DRAIN_READS},
     {write, ibrd, ?ERX_HW_PL011_IBRD_BAUD_DIVINT_PUT(Integer)},
     {write, fbrd, ?ERX_HW_PL011_FBRD_BAUD_DIVFRAC_PUT(Fraction)},
     {write, lcr_h, ?ERX_HW_PL011_LCR_H_WLEN_PUT(?WLEN_8) bor ?ERX_HW_PL011_LCR_H_FEN_PUT(1)},
     {write, icr, every_interrupt()},
     {write, cr, Enabled bor flow_enables(Flow)}];
steps(fresh, _Spec) ->
    throw({refused, {bad_line_record, "a fresh line's record gives no flow or a rate other than 115200"}});
steps(_Init, _Spec) ->
    throw({refused, {bad_line_record, "the record's init is neither keep nor fresh"}}).

flow_enables(none) ->
    0;
flow_enables(rts_cts) ->
    ?ERX_HW_PL011_CR_RTSEN_PUT(1) bor ?ERX_HW_PL011_CR_CTSEN_PUT(1);
flow_enables(_Flow) ->
    throw({refused, {bad_line_record, "the line's flow is neither none nor rts_cts"}}).

%% ICR's every bit, each a write-one-to-clear of one interrupt.
every_interrupt() ->
    ?ERX_HW_PL011_ICR_RIMIC_MASK bor ?ERX_HW_PL011_ICR_CTSMIC_MASK bor ?ERX_HW_PL011_ICR_DCDMIC_MASK
        bor ?ERX_HW_PL011_ICR_DSRMIC_MASK bor ?ERX_HW_PL011_ICR_RXIC_MASK bor ?ERX_HW_PL011_ICR_TXIC_MASK
        bor ?ERX_HW_PL011_ICR_RTIC_MASK bor ?ERX_HW_PL011_ICR_FEIC_MASK bor ?ERX_HW_PL011_ICR_PEIC_MASK
        bor ?ERX_HW_PL011_ICR_BEIC_MASK bor ?ERX_HW_PL011_ICR_OEIC_MASK.

%% The divisors for Rate at the clock in hertz the record carries (the console's from
%% console_uart/1, the others from erx_device_record, in either form). A record without a
%% clock, with a clock of 0, or with one that gives no divisors is refused, since a guessed
%% clock would time characters and divide the rate wrongly.
divisors(#{clock := Clock}, Rate) when is_integer(Clock), Clock > 0 ->
    case baud_divisors(Clock, Rate) of
        {ok, Integer, Fraction} -> {Integer, Fraction};
        {error, Reason} -> throw({refused, Reason})
    end;
divisors(_Spec, _Rate) ->
    throw({refused, {no_uart_clock, "the UART's device record gives no clock"}}).

%% The integer and fractional divisors for BAUD at Clock hertz (baud_divisors/2). A pure
%% function, exported for its tests.
-spec baud_divisors(non_neg_integer()) ->
    {ok, Integer :: pos_integer(), Fraction :: 0..63} | {error, {pl011_clock, string()}}.
baud_divisors(Clock) ->
    baud_divisors(Clock, ?BAUD).

%% The divisors for Rate at Clock hertz: Clock / (16 * Rate) in sixty-fourths, rounded to
%% the nearest (3-10). The divisor runs from 1 + 0/64 to 65535 + 0/64: an integer divisor
%% of 65535 takes no fraction, so the bound is 65535 * 64 sixty-fourths, not one past it. A
%% clock too slow for a divisor of 1 is refused with a stated reason; no 32-bit clock
%% reaches the upper bound at 115200 baud.
baud_divisors(Clock, Rate) ->
    Sixtyfourths = (Clock * 4 + Rate div 2) div Rate,
    case Sixtyfourths >= 64 andalso Sixtyfourths =< 65535 * 64 of
        true -> {ok, Sixtyfourths div 64, Sixtyfourths rem 64};
        false -> {error, {pl011_clock, "the UART's clock gives no divisor of 1 to 65535 for the line's rate"}}
    end.

run(Dev, _Clock, {write, Register, Word}) ->
    ok = erx_device:write(Dev, Register, Word);
run(Dev, _Clock, {field, Register, Field, Value}) ->
    ok = erx_device:write_field(Dev, Register, Field, Value);
run(Dev, _Clock, wait_idle) ->
    wait_idle(Dev, ?BUSY_READS);
run(Dev, Clock, wait_character) ->
    Wait = character_ms(erx_device:read_field(Dev, ibrd, baud_divint),
                        erx_device:read_field(Dev, fbrd, baud_divfrac), Clock),
    receive after Wait -> ok end;
run(Dev, _Clock, clear_raw) ->
    ok = erx_device:write(Dev, icr, erx_device:read(Dev, ris));
run(Dev, _Clock, {drain_receive, Reads}) ->
    discard(Dev, Reads);
run(Dev, _Clock, {default_divisors, Integer, Fraction}) ->
    case erx_device:read_field(Dev, ibrd, baud_divint) of
        0 ->
            ok = erx_device:write_field(Dev, ibrd, baud_divint, Integer),
            ok = erx_device:write_field(Dev, fbrd, baud_divfrac, Fraction);
        _Boot ->
            ok
    end.

wait_idle(_Dev, 0) ->
    exit({pl011_busy, "the transmitter stayed busy", ?BUSY_READS, reads});
wait_idle(Dev, Reads) ->
    case erx_device:read_field(Dev, fr, busy) of
        0 -> ok;
        1 -> wait_idle(Dev, Reads - 1)
    end.

%% One character at divisor Int + Frac / 64 lasts CHARACTER_BITS * 16 * divisor / Clock
%% seconds (3-10), rounded up to whole milliseconds and at least one. An unprogrammed
%% divisor receives nothing, so the one millisecond is enough for it.
character_ms(Int, Frac, Clock) ->
    Sixtyfourths = Int * 64 + Frac,
    Numerator = ?CHARACTER_BITS * 16 * 1000 * Sixtyfourths,
    Denominator = 64 * Clock,
    max(1, (Numerator + Denominator - 1) div Denominator).

%% Reads DR until RXFE is set, at most Reads times, dropping what it reads.
discard(_Dev, 0) ->
    ok;
discard(Dev, Reads) ->
    case erx_device:read_field(Dev, fr, rxfe) of
        1 -> ok;
        0 -> _ = erx_device:read(Dev, dr), discard(Dev, Reads - 1)
    end.

loop(S = #driver{dev = Dev, owner = Owner}) ->
    receive
        {erx_irq, Dev, ?RX_LINE} ->
            loop(take_input(S));
        erx_console_taken ->
            loop(taken(S));
        {erx_console_output, From, Bytes} ->
            Next = send(S, iolist_to_binary(Bytes)),
            Owner ! {erx_console_written, From},
            loop(Next);
        _Other ->
            loop(S)
    end.

send(S, <<>>) ->
    S;
send(S0 = #driver{dev = Dev}, Bytes = <<Byte, Rest/binary>>) ->
    S = answer_in_send(S0),
    case erx_device:read_field(Dev, fr, txff) of
        0 ->
            ok = erx_device:write(Dev, dr, Byte),
            send(S, Rest);
        1 ->
            Next = receive
                       {erx_irq, Dev, ?RX_LINE} -> take_input(S)
                   after ?FULL_WAIT_MS -> S
                   end,
            send(Next, Bytes)
    end.

%% The owner's answer to the input message last sent, taken between two bytes of a send.
answer_in_send(S) ->
    receive
        erx_console_taken -> taken(S)
    after 0 ->
            S
    end.

take_input(S = #driver{irq = Irq}) ->
    Next = deliver_input(S),
    ok = erx_irq_line:ack(Irq),
    Next.

deliver_input(S = #driver{dev = Dev, on_overrun = OnOverrun}) ->
    ok = erx_device:write(Dev, icr, erx_device:read(Dev, mis)),
    handed(drain(Dev, OnOverrun), S).

%% One drain's units: a line's driver hands its bytes up at once; the console's puts them
%% in the store and sends the next message if none waits.
handed(Units, S = #driver{on_overrun = pass, owner = Owner}) ->
    [Owner ! {erx_console_input, list_to_binary(Units)} || Units =/= []],
    S;
handed(Units, S = #driver{on_overrun = mark, input = Input}) ->
    send_next(S#driver{input = erx_uart_input:add(Units, Input)}).

taken(S = #driver{input = Input}) ->
    send_next(S#driver{input = erx_uart_input:taken(Input)}).

send_next(S = #driver{owner = Owner, input = Input}) ->
    case erx_uart_input:next(Input) of
        {none, Next} -> S#driver{input = Next};
        {Message, Next} -> Owner ! Message, S#driver{input = Next}
    end.

%% The units the receive side holds, in order, read until FR shows it empty or
%% ?DRAIN_WORDS words are read.
-spec drain(erx_device:device(), on_overrun()) -> [erx_uart_input:unit()].
drain(Dev, OnOverrun) ->
    drain(Dev, OnOverrun, ?DRAIN_WORDS, []).

%% Reading DR pops a byte, so each word is read once and decoded from that word.
drain(_Dev, _OnOverrun, 0, Units) ->
    lists:append(lists:reverse(Units));
drain(Dev, OnOverrun, Words, Units) ->
    case erx_device:read_field(Dev, fr, rxfe) of
        1 ->
            lists:append(lists:reverse(Units));
        0 ->
            Received = received(erx_device:read(Dev, dr), OnOverrun),
            drain(Dev, OnOverrun, Words - 1, [Received | Units])
    end.

%% The units a word read from DR stands for: its data, after the loss when the driver makes
%% losses and the word's OE says input was lost before the byte.
received(Word, OnOverrun) ->
    Byte = ?ERX_HW_PL011_DR_DATA_GET(Word),
    case {OnOverrun, ?ERX_HW_PL011_DR_OE_GET(Word)} of
        {mark, 1} -> [lost, Byte];
        _ -> [Byte]
    end.
