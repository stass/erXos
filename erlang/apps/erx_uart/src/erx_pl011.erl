%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The driver of an Arm PrimeCell UART PL011 (docs/design-runtime.md, "The console and
%% standard I/O"; Arm DDI 0183G for the register rules cited below), for the console and for
%% the host link's line (docs/design-live.md, "The host link"). It speaks the driver's
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
%% the byte goes up as read.
%%
%% Sending: one byte per free FIFO slot. A full FIFO waits a millisecond at a time with the
%% receive side still served. A UART at 115200 baud frees eleven slots a millisecond, so no
%% interrupt is worth unmasking for it.

-module(erx_pl011).

-export([start_link/1, start_link/2]).
-export([init/2]).
-export([console_uart/1]).

%% The spec's one line.
-define(RX_LINE, 0).
%% LCR_H's word length for eight bits.
-define(WLEN_8, 3).
%% QEMU virt's UART clock of 24 MHz, which times a character for reprogramming, and the
%% divisors for 115200 baud at that clock, for a UART the boot left unprogrammed (3-10: an
%% integer divisor of 0 is invalid), as Fiasco leaves it on virt. Only the board knows its
%% clock, which belongs in the platform record (TODO.md).
-define(UART_CLOCK_HZ, 24000000).
-define(IBRD_DEFAULT, 13).
-define(FBRD_DEFAULT, 1).
%% The longest character a line format the boot chose can have: a start bit, eight data
%% bits, a parity bit and two stop bits.
-define(CHARACTER_BITS, 12).
%% How many reads of FR wait for the transmitter to go idle before reprogramming.
-define(BUSY_READS, 100000).
-define(FULL_WAIT_MS, 1).

%% The console's driver, on the UART of `-erx console_uart`. Terminal is true: a person's
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
    start(spec(), Console, {ok, self(), true});
init(Spec, Owner) ->
    start(Spec, Owner, {ok, self()}).

start(Spec, Owner, Ack) ->
    {ok, Dev} = erx_device:open(Spec),
    reprogram(Dev),
    ok = erx_device:irq_bind(Dev, ?RX_LINE),
    ok = erx_device:write_field(Dev, imsc, rxim, 1),
    ok = erx_device:write_field(Dev, imsc, rtim, 1),
    proc_lib:init_ack(Ack),
    deliver_input(Dev, Owner),
    loop(Dev, Owner).

%% The root's words from the manifest's device entry for the console, as the boot information
%% carries them to init's arguments. A failure exits with a stated reason, so a malformed
%% entry stops the driver with that reason rather than a crash in the middle of the parse.
spec() ->
    {ok, Arguments} = init:get_argument(erx),
    case console_uart(Arguments) of
        {ok, Spec} -> Spec;
        {error, Reason} -> exit(Reason)
    end.

%% `-erx console_uart BASE SIZE LINE`, once, each number in decimal and within its field of
%% the boot manifest's console (64, 64 and 32 bits). A plain word of the kernel command line
%% can follow the three numbers, so an entry may be longer. A pure function, exported for its
%% tests and fuzz target.
-spec console_uart([[string()]]) -> {ok, erx_device:spec()} | {error, {atom(), string()}}.
console_uart(Arguments) ->
    case [Words || ["console_uart" | Words] <- Arguments] of
        [[Base, Size, Line | _]] ->
            case {number(Base, 64), number(Size, 64), number(Line, 32)} of
                {{ok, B}, {ok, S}, {ok, L}} ->
                    {ok, #{peripheral => pl011, window => {physical, B, S}, lines => [L]}};
                _ ->
                    {error, {bad_console_uart, "console_uart's base, size or line is not a decimal "
                                              "number of its field's width"}}
            end;
        [_] ->
            {error, {bad_console_uart, "console_uart has fewer than three numbers"}};
        [] ->
            {error, {no_console_uart, "the manifest names no device entry as machine.console"}};
        [_, _ | _] ->
            {error, {bad_console_uart, "more than one console_uart entry"}}
    end.

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

%% The control registers change only with the UART disabled and the character in flight
%% finished, since a disabled UART completes the character it is sending or receiving before
%% it stops (3-16). The driver waits for the transmitter to send what the boot left, disables
%% the UART, and waits one character time at the boot's divisors: a received character has no
%% flag to say it has finished, and a sent one, at the same rate, finishes within that time
%% too. BUSY is not waited on again: the kernel's console can write the UART at any time, and
%% a byte it queues while the UART is disabled holds BUSY set until the driver enables it.
%% The FIFOs are not flushed by clearing FEN: what the kernel queued goes out once the UART
%% is enabled, and the receive FIFO holds what a person typed, that last character included.
%% The boot's divisors stay.
reprogram(Dev) ->
    wait_idle(Dev, ?BUSY_READS),
    ok = erx_device:write_field(Dev, cr, uarten, 0),
    IntegerDivisor = erx_device:read_field(Dev, ibrd, baud_divint),
    Wait = character_ms(IntegerDivisor, erx_device:read_field(Dev, fbrd, baud_divfrac)),
    receive after Wait -> ok end,
    ok = erx_device:write(Dev, imsc, 0),
    ok = erx_device:write(Dev, icr, erx_device:read(Dev, ris)),
    set_divisors(Dev, IntegerDivisor),
    ok = erx_device:write_field(Dev, lcr_h, wlen, ?WLEN_8),
    ok = erx_device:write_field(Dev, lcr_h, fen, 1),
    ok = erx_device:write_field(Dev, cr, rxe, 1),
    ok = erx_device:write_field(Dev, cr, txe, 1),
    ok = erx_device:write_field(Dev, cr, uarten, 1).

wait_idle(_Dev, 0) ->
    exit({pl011_busy, "the transmitter stayed busy", ?BUSY_READS, reads});
wait_idle(Dev, Reads) ->
    case erx_device:read_field(Dev, fr, busy) of
        0 -> ok;
        1 -> wait_idle(Dev, Reads - 1)
    end.

%% One character at divisor Int + Frac / 64 lasts CHARACTER_BITS * 16 * divisor / clock
%% seconds (3-10), rounded up to whole milliseconds and at least one. The clock is virt's
%% (UART_CLOCK_HZ); on a board with a slower one the time is short by their ratio, which the
%% floor of one millisecond still covers at any rate of 12000 baud or more. An unprogrammed
%% divisor receives nothing, so the one millisecond is enough for it.
character_ms(Int, Frac) ->
    Sixtyfourths = Int * 64 + Frac,
    Numerator = ?CHARACTER_BITS * 16 * 1000 * Sixtyfourths,
    Denominator = 64 * ?UART_CLOCK_HZ,
    max(1, (Numerator + Denominator - 1) div Denominator).

set_divisors(Dev, 0) ->
    ok = erx_device:write_field(Dev, ibrd, baud_divint, ?IBRD_DEFAULT),
    ok = erx_device:write_field(Dev, fbrd, baud_divfrac, ?FBRD_DEFAULT);
set_divisors(_Dev, _Divisor) ->
    ok.

loop(Dev, Owner) ->
    receive
        {erx_irq, Dev, ?RX_LINE} ->
            take_input(Dev, Owner),
            loop(Dev, Owner);
        {erx_console_output, From, Bytes} ->
            send(Dev, Owner, iolist_to_binary(Bytes)),
            Owner ! {erx_console_written, From},
            loop(Dev, Owner);
        _Other ->
            loop(Dev, Owner)
    end.

send(_Dev, _Owner, <<>>) ->
    ok;
send(Dev, Owner, Bytes = <<Byte, Rest/binary>>) ->
    case erx_device:read_field(Dev, fr, txff) of
        0 ->
            ok = erx_device:write(Dev, dr, Byte),
            send(Dev, Owner, Rest);
        1 ->
            receive
                {erx_irq, Dev, ?RX_LINE} -> take_input(Dev, Owner)
            after ?FULL_WAIT_MS -> ok
            end,
            send(Dev, Owner, Bytes)
    end.

take_input(Dev, Owner) ->
    deliver_input(Dev, Owner),
    ok = erx_device:irq_ack(Dev, ?RX_LINE).

deliver_input(Dev, Owner) ->
    ok = erx_device:write(Dev, icr, erx_device:read(Dev, mis)),
    case drain(Dev, <<>>) of
        <<>> -> ok;
        Bytes -> Owner ! {erx_console_input, Bytes}
    end.

%% Reading DR pops a byte, so each word is read once and its data decoded from that word.
drain(Dev, Bytes) ->
    case erx_device:read_field(Dev, fr, rxfe) of
        1 ->
            Bytes;
        0 ->
            Byte = erx_device:field(Dev, dr, data, erx_device:read(Dev, dr)),
            drain(Dev, <<Bytes/binary, Byte>>)
    end.
