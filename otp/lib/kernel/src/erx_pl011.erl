%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The console driver of an Arm PrimeCell UART PL011 (docs/design-runtime.md, "The console
%% and standard I/O"; Arm DDI 0183G for the register rules cited below). It speaks the
%% driver's messages that erx_console documents and passes bytes unchanged both ways: what
%% a terminal does with them is the tty layer's business, above this module.
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

-export([start_link/1]).
-export([init/1]).

%% The spec's one line.
-define(RX_LINE, 0).
%% LCR_H's word length for eight bits.
-define(WLEN_8, 3).
%% QEMU virt's UART clock of 24 MHz at 115200 baud, for a UART the boot left unprogrammed
%% (3-10: an integer divisor of 0 is invalid), as Fiasco leaves it on virt. Only the board
%% knows its clock, which belongs in the platform record (TODO.md).
-define(IBRD_DEFAULT, 13).
-define(FBRD_DEFAULT, 1).
%% How many reads of FR wait for the transmitter to go idle before reprogramming.
-define(BUSY_READS, 100000).
-define(FULL_WAIT_MS, 1).

-spec start_link(Console :: pid()) -> {ok, pid(), Terminal :: boolean()}.
start_link(Console) ->
    proc_lib:start_link(?MODULE, init, [Console]).

%% Terminal is true: a person's terminal is on the line, so the group edits lines.
-spec init(pid()) -> no_return().
init(Console) ->
    {ok, Dev} = erx_device:open(spec()),
    reprogram(Dev),
    ok = erx_device:irq_bind(Dev, ?RX_LINE),
    ok = erx_device:write_field(Dev, imsc, rxim, 1),
    ok = erx_device:write_field(Dev, imsc, rtim, 1),
    proc_lib:init_ack({ok, self(), true}),
    deliver_input(Dev, Console),
    loop(Dev, Console).

%% The root's words from the manifest's device entry for the console. A plain word of the
%% kernel command line can follow them, so the list may be longer.
spec() ->
    {ok, Arguments} = init:get_argument(erx),
    case [{Base, Size, Line} || ["console_uart", Base, Size, Line | _] <- Arguments] of
        [{Base, Size, Line}] ->
            #{peripheral => pl011,
              window => {physical, list_to_integer(Base), list_to_integer(Size)},
              lines => [list_to_integer(Line)]};
        [] ->
            exit({no_console_uart, "the manifest names no device entry as machine.console"})
    end.

%% The control registers change only with the UART disabled and its line idle (3-16): the
%% driver waits for the transmitter to send what the boot left, then disables it. The FIFOs
%% are not flushed by clearing FEN: the transmit FIFO is empty by then, and the receive
%% FIFO holds what a person typed. The boot's divisors stay.
reprogram(Dev) ->
    wait_idle(Dev, ?BUSY_READS),
    ok = erx_device:write_field(Dev, cr, uarten, 0),
    ok = erx_device:write(Dev, imsc, 0),
    ok = erx_device:write(Dev, icr, erx_device:read(Dev, ris)),
    set_divisors(Dev, erx_device:read_field(Dev, ibrd, baud_divint)),
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

set_divisors(Dev, 0) ->
    ok = erx_device:write_field(Dev, ibrd, baud_divint, ?IBRD_DEFAULT),
    ok = erx_device:write_field(Dev, fbrd, baud_divfrac, ?FBRD_DEFAULT);
set_divisors(_Dev, _Divisor) ->
    ok.

loop(Dev, Console) ->
    receive
        {erx_irq, Dev, ?RX_LINE} ->
            take_input(Dev, Console),
            loop(Dev, Console);
        {erx_console_output, From, Bytes} ->
            send(Dev, Console, iolist_to_binary(Bytes)),
            Console ! {erx_console_written, From},
            loop(Dev, Console);
        _Other ->
            loop(Dev, Console)
    end.

send(_Dev, _Console, <<>>) ->
    ok;
send(Dev, Console, Bytes = <<Byte, Rest/binary>>) ->
    case erx_device:read_field(Dev, fr, txff) of
        0 ->
            ok = erx_device:write(Dev, dr, Byte),
            send(Dev, Console, Rest);
        1 ->
            receive
                {erx_irq, Dev, ?RX_LINE} -> take_input(Dev, Console)
            after ?FULL_WAIT_MS -> ok
            end,
            send(Dev, Console, Bytes)
    end.

take_input(Dev, Console) ->
    deliver_input(Dev, Console),
    ok = erx_device:irq_ack(Dev, ?RX_LINE).

deliver_input(Dev, Console) ->
    ok = erx_device:write(Dev, icr, erx_device:read(Dev, mis)),
    case drain(Dev, <<>>) of
        <<>> -> ok;
        Bytes -> Console ! {erx_console_input, Bytes}
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
