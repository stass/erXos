%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The driver of the BCM2711's mini UART, the Raspberry Pi 4's console
%% (docs/design-platforms.md, "Raspberry Pi 4 Model B"; hw/svd/mini_uart/mini_uart.svd for
%% the registers). It speaks the driver's messages that erx_console documents to the one
%% process it serves, the console, and passes bytes unchanged both ways, as erx_pl011 does.
%%
%% The firmware pins the core clock the baud rate is divided from and programs the line
%% (`enable_uart=1`), so the driver keeps the divisor, the line control and the receiver
%% and transmitter enables as it finds them, and computes nothing from a clock. Its window
%% is the mini UART's own registers: the auxiliary block's enable register, which also
%% enables the auxiliary SPI controllers on the same page, lies outside it.
%%
%% Receiving: IER's RX_ERRATA bits are set with RXIE, in the belief that the silicon's
%% receive interrupt needs them. The BCM2711's manual prints the receive enable at a
%% different bit than RXIE's, and says nothing of RX_ERRATA, so both are unverified on
%% silicon. The receive interrupt is level, raised while the receive FIFO holds a byte, so
%% one delivery drains the FIFO, to empty or as far as its store has room, at most ?DRAIN_MAX bytes, and the line is acknowledged
%% after it; a byte left or arriving during the drain raises the line again. Bytes typed
%% before the driver started are drained once after the interrupt is enabled.
%%
%% Overruns: the receive FIFO holds eight bytes, about 0.7 ms of input at 115200 baud, and
%% the line has no flow control, so a delivery later than that loses the bytes the FIFO
%% had no room for. The driver sends each loss as erx_console_lost, in order with its
%% bytes (docs/design-live.md, "Lost input"), and places it conservatively, before every
%% byte that might have arrived after it. A read of LSR that shows an overrun says the loss
%% came after the previous read of LSR, when the FIFO held eight bytes from before it, of
%% which the driver has read P since that previous read: one when a data read came between
%% the two, as in a drain, and none when none did, as in a send's poll. So the loss goes after
%% the next ?FIFO_BYTES - P bytes the driver reads, or where the FIFO reads empty if that
%% comes first (add_mark/2, received/2), and a newline that arrived after the loss is read
%% after it. FreeBSD's flush of the receiver after an overrun, which spaces overruns out for
%% a multiport card's other lines, is not done. Every read of LSR, the receive side's and the
%% send side's alike, goes through read_lsr/1, because the read clears RX_OVERRUN:
%% overrun_seen/2 counts each overrun a read shows (count_overrun/2) and keeps its mark until
%% the drain places it, so an overrun a send's read shows is placed by the drain that
%% follows.
%%
%% One input message outstanding: the driver sends its next input message only after the
%% console's erx_console_taken answers the last, and drains meanwhile into a store of one
%% drain's bytes (erx_uart_input). It reads no more input than the store can hold: every
%% drain is bounded by the store's room (drain/1), whether a delivery, a continuation or a
%% send's poll calls it. A drain that stopped with the store full pauses the receive side
%% (settled/1): IER masks the receive interrupt, the bytes wait in the FIFO, and the
%% console's answer, once the store has room again, enables it and drains. Input is then lost
%% only to the FIFO's overrun, which is marked as above. A send takes a waiting answer
%% between its bytes, so output never waits on input being taken, nor input on output.
%%
%% Logging: the driver logs a warning only when its mailbox is empty, after a delivery has been drained and acknowledged or a send
%% has finished, so a pending interrupt is always served before the log call; a byte that
%% arrives during the call still waits for it. It warns of the first overrun and then of
%% each count at least double the last one it logged (to_report/2), so a flood writes only
%% a few lines to the line it overflows.
%%
%% Sending: one read of LSR per byte, which decides both sides (send_step/1). While the
%% driver writes, a delivered interrupt waits unread in its mailbox, so the send polls the
%% receive side itself: a read that shows a received byte drains the receive FIFO, and the
%% same read's TX_EMPTY then decides whether the byte is written, so output progresses
%% whatever the input does. A drain inside a send takes and acknowledges a delivery already
%% waiting; without one it acknowledges nothing, since erx_irq_line takes one answer per
%% notice. A full transmit FIFO waits a millisecond at a time for the receive interrupt,
%% longer than the receive FIFO lasts, so there input still depends on the delivery.
%%
%% A drain stops after ?DRAIN_MAX bytes, four FIFO depths, so neither a device whose
%% DATA_READY never clears nor input faster than the driver reads holds it: the driver
%% serves its mailbox and then continues the drain, as erx_pl011 does, the line, still
%% raised, delivers again, and a send writes its byte.

-module(erx_mini_uart).

-export([start_link/1]).
-export([init/2, format_status/1]).
-export([console_records/0, console_uart/1]).
%% Exported for its tests.
-export([count_overrun/2, to_report/2, send_step/1, received/2, add_mark/2]).

-include("generated/erx_hw_mini_uart.hrl").

%% The spec's one line.
-define(RX_LINE, 0).
-define(FULL_WAIT_MS, 1).
-define(DRAIN_MAX, 32).
%% The receive FIFO's depth (BCM2711 ARM Peripherals, 2.2: 8 symbols).
-define(FIFO_BYTES, 8).

%% The driver's state: its device, its line, the console it serves, how many reads of LSR
%% have shown an overrun since it started, the overrun count the last warning logged (0
%% before any), a mark for each loss not yet placed, the bytes still to read before it, in
%% the order the losses were seen (add_mark/2), how many data reads came since the last read
%% of LSR, the input not yet sent (erx_uart_input), and the receive side as erx_pl011 keeps
%% it: drained, the last drain read the FIFO empty; stopped, it stopped at its bound and the
%% store has room, so the driver drains on; paused, the store is full and IER masks the
%% receive interrupt until the console's answer.
-record(driver, {dev :: erx_device:device(),
                 irq :: erx_irq_line:handle(),
                 console :: pid(),
                 overruns = 0 :: non_neg_integer(),
                 reported = 0 :: non_neg_integer(),
                 marks = [] :: [pos_integer()],
                 data_reads = 0 :: 0..1,
                 input = erx_uart_input:new(?DRAIN_MAX) :: erx_uart_input:input(),
                 rx = drained :: drained | stopped | paused}).

-spec start_link(Console :: pid()) -> {ok, pid(), Terminal :: boolean()}.
start_link(Console) ->
    proc_lib:start_link(?MODULE, init, [Console, spec()]).

%% The driver of the device Spec names, serving Console. Spec is an argument, not read here,
%% so that a test can hand the driver a device it plays.
-spec init(pid(), erx_device:spec()) -> no_return().
init(Console, Spec) ->
    {ok, Dev} = erx_device:open(Spec),
    ok = erx_device:write(Dev, ier, 0),
    {ok, Irq} = erx_irq_line:attach(Dev, ?RX_LINE),
    ok = enable_receive(Dev),
    proc_lib:init_ack({ok, self(), true}),
    loop(deliver_input(#driver{dev = Dev, irq = Irq, console = Console})).

%% IER's receive interrupt enabled, as the driver's start and its unpause do (settled/1).
enable_receive(Dev) ->
    ok = erx_device:write_field(Dev, ier, rx_errata, 3),
    ok = erx_device:write_field(Dev, ier, rxie, 1).

-doc """
Its existence is what makes proc_lib's crash report of this process hide its terms
(gen:hides_terms/1), as erx_pl011's does: neither the mailbox, which holds the bytes the
console sent to write, nor a stack frame's arguments, whose driver state holds typed bytes
not yet taken, are shown.
""".
-spec format_status(#{atom() => term()}) -> #{atom() => term()}.
format_status(Status) ->
    erx_report:status(Status, #{}).

%% The console's record, for the console to start its line's owner before the driver.
-spec console_records() -> [erx_device:spec()].
console_records() ->
    [spec()].

spec() ->
    case console_uart(erx_device_record:records()) of
        {ok, Spec} -> Spec;
        {error, Reason} -> exit(Reason)
    end.

%% The console's device words, `-erx_record console mini_uart Base Size Line Mark Clock`, which the root
%% writes from the manifest's console row; words after the clock are ignored. Mark is
%% `shared` when another device of the console's unit names its line, as the auxiliary SPI
%% controllers name the mini UART's on the Raspberry Pi 4, which reaches erx_device:open/1
%% as `{shared, Line}`, and `direct` otherwise; any other word refuses the entry. The mini
%% UART's row carries no clock, so Clock is 0.
-spec console_uart([[string()]]) -> {ok, erx_device:spec()} | {error, {atom(), string()}}.
console_uart(Arguments) ->
    case [Words || ["console", "mini_uart" | Words] <- Arguments] of
        [[Base, Size, Line, Mark, Clock | _]] ->
            case {number(Base, 64), number(Size, 64), number(Line, 32), number(Clock, 32), mark(Mark)} of
                {{ok, B}, {ok, S}, {ok, L}, {ok, 0}, {ok, Sharing}} ->
                    {ok, #{peripheral => mini_uart, window => {physical, B, S}, lines => [marked(Sharing, L)]}};
                {{ok, _}, {ok, _}, {ok, _}, {ok, 0}, error} ->
                    {error, {bad_console_uart, "the console's line mark is neither direct nor shared"}};
                {{ok, _}, {ok, _}, {ok, _}, {ok, _}, _} ->
                    {error, {bad_console_uart, "the mini UART's row carries a clock"}};
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

%% Serves the messages waiting; with none left, continues a drain that stopped at its bound,
%% as erx_pl011 does, or logs the overruns due and waits for one.
loop(S) ->
    receive
        Message -> loop(handle(Message, S))
    after 0 ->
            case S of
                #driver{rx = stopped} -> loop(deliver_input(S));
                _ -> idle(report_overruns(S))
            end
    end.

idle(S) ->
    receive
        Message -> loop(handle(Message, S))
    end.

handle({erx_irq, Dev, ?RX_LINE}, S = #driver{dev = Dev}) ->
    take_input(S);
handle(erx_console_taken, S) ->
    taken(S);
handle({erx_console_output, From, Bytes}, S = #driver{console = Console}) ->
    Next = send(S, iolist_to_binary(Bytes)),
    Console ! {erx_console_written, From},
    Next;
handle(_Other, S) ->
    S.

send(S, <<>>) ->
    S;
send(S0 = #driver{dev = Dev}, Bytes = <<Byte, Rest/binary>>) ->
    {Lsr, S1} = read_lsr(answer_in_send(S0)),
    {Receive, Transmit} = send_step(Lsr),
    S = case Receive of
            drain -> drain_in_send(S1);
            idle -> S1
        end,
    case Transmit of
        write ->
            ok = erx_device:write(Dev, io, Byte),
            send(S, Rest);
        wait ->
            Next = receive
                       {erx_irq, Dev, ?RX_LINE} -> take_input(S)
                   after ?FULL_WAIT_MS -> S
                   end,
            send(Next, Bytes)
    end.

%% What a send does after a read of LSR that returned Lsr: drain the receive FIFO first if a
%% byte waits in it, then write the next byte if the transmit FIFO can take one, else wait
%% for room.
-spec send_step(non_neg_integer()) -> {drain | idle, write | wait}.
send_step(Lsr) ->
    Receive = case ?ERX_HW_MINI_UART_LSR_DATA_READY_GET(Lsr) of
                  1 -> drain;
                  0 -> idle
              end,
    Transmit = case ?ERX_HW_MINI_UART_LSR_TX_EMPTY_GET(Lsr) of
                   1 -> write;
                   0 -> wait
               end,
    {Receive, Transmit}.

%% The console's answer to the input message last sent, taken between two bytes of a send.
answer_in_send(S) ->
    receive
        erx_console_taken -> taken(S)
    after 0 ->
            S
    end.

%% A drain between two bytes of a send, which takes a delivery already waiting with it.
drain_in_send(S = #driver{dev = Dev}) ->
    receive
        {erx_irq, Dev, ?RX_LINE} -> take_input(S)
    after 0 ->
            deliver_input(S)
    end.

take_input(S = #driver{irq = Irq}) ->
    Next = deliver_input(S),
    ok = erx_irq_line:ack(Irq),
    Next.

%% One drain's units into the store, and the next message sent if none waits. A paused
%% driver reads nothing: a delivery that came before its mask is acknowledged, and a send's
%% poll, which still reads LSR and so keeps every overrun's mark, drains nothing.
deliver_input(S = #driver{rx = paused}) ->
    S;
deliver_input(S0) ->
    {Units, Rx, S = #driver{input = Input}} = drain(S0),
    settled(send_next(S#driver{input = erx_uart_input:add(Units, Input), rx = Rx})).

taken(S = #driver{input = Input}) ->
    settled(send_next(S#driver{input = erx_uart_input:taken(Input)})).

%% The receive side once a drain or an answer has changed the store: a drain that stopped
%% with no room left pauses, writing IER whole to 0, since the interrupt is a level that a
%% byte in the FIFO keeps raised and an acknowledgement withheld instead would hold the
%% auxiliary block's shared line from the SPI controllers on it; a paused driver whose store
%% has room again enables the interrupt and drains. The marks and the data reads since the
%% last read of LSR stay as they were across the pause.
settled(S = #driver{rx = stopped, dev = Dev, input = Input}) ->
    case erx_uart_input:room(Input) of
        0 ->
            ok = erx_device:write(Dev, ier, 0),
            S#driver{rx = paused};
        _ ->
            S
    end;
settled(S = #driver{rx = paused, dev = Dev, input = Input}) ->
    case erx_uart_input:room(Input) of
        0 ->
            S;
        _ ->
            ok = enable_receive(Dev),
            deliver_input(S#driver{rx = stopped})
    end;
settled(S = #driver{rx = drained}) ->
    S.

send_next(S = #driver{console = Console, input = Input}) ->
    case erx_uart_input:next(Input) of
        {none, Next} -> S#driver{input = Next};
        {Message, Next} -> Console ! Message, S#driver{input = Next}
    end.

%% The units the receive FIFO gives, in order, until it reads empty (drained) or as many
%% bytes are read as the store has room for (stopped), at most ?DRAIN_MAX, the store's size.
%% A loss takes no room, so no caller can make a drain give the store a byte it cannot hold.
drain(S = #driver{input = Input}) ->
    drain(S, erx_uart_input:room(Input), []).

drain(S, 0, Units) ->
    {lists:append(lists:reverse(Units)), stopped, S};
drain(S0 = #driver{dev = Dev}, Room, Units) ->
    {Lsr, S = #driver{marks = Marks}} = read_lsr(S0),
    case ?ERX_HW_MINI_UART_LSR_DATA_READY_GET(Lsr) of
        0 ->
            {Received, Left} = received(empty, Marks),
            {lists:append(lists:reverse([Received | Units])), drained, S#driver{marks = Left}};
        1 ->
            Byte = ?ERX_HW_MINI_UART_IO_DATA_GET(erx_device:read(Dev, io)),
            {Received, Left} = received(Byte, Marks),
            drain(S#driver{marks = Left, data_reads = 1}, Room - 1, [Received | Units])
    end.

%% The units a drain appends, and the marks left, after the byte Byte it read or after a
%% read of LSR that found the FIFO `empty`: the byte, followed by the loss when it was the
%% last byte before a mark, or, from an empty FIFO, the loss of every mark, since no byte
%% that came before those losses is left in it. Marks are distinct, so at most one is due
%% at a byte, and losses with no byte between them are one.
-spec received(byte() | empty, [pos_integer()]) -> {[erx_uart_input:unit()], [pos_integer()]}.
received(empty, []) ->
    {[], []};
received(empty, _Marks) ->
    {[lost], []};
received(Byte, Marks) ->
    Left = [Count - 1 || Count <- Marks, Count > 1],
    case length(Left) < length(Marks) of
        true -> {[Byte, lost], Left};
        false -> {[Byte], Left}
    end.

%% LSR's word, read once, and the driver once it has seen the overrun the word shows
%% (overrun_seen/2): the read clears RX_OVERRUN, so the overrun is seen here or never. The
%% data reads since this read start again at none. Nothing is logged here, in the middle of
%% a drain.
read_lsr(S = #driver{dev = Dev}) ->
    Lsr = erx_device:read(Dev, lsr),
    {Lsr, (overrun_seen(Lsr, S))#driver{data_reads = 0}}.

%% The driver after a read of LSR that returned Lsr: an overrun it shows counted, for the
%% log, and its mark added, waiting for the FIFO's bytes that came before the loss.
overrun_seen(Lsr, S = #driver{overruns = Seen, marks = Marks, data_reads = Read}) ->
    case ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_GET(Lsr) of
        0 -> S;
        1 -> S#driver{overruns = count_overrun(Lsr, Seen), marks = add_mark(Read, Marks)}
    end.

%% The marks after an overrun shown by a read of LSR with Read data reads since the previous
%% one: the loss goes after the ?FIFO_BYTES - Read bytes of the full FIFO still to read,
%% unless a mark is already there, the same place, since no byte lies between them. The
%% marks are distinct counts from 1 to ?FIFO_BYTES, at most ?FIFO_BYTES of them, however
%% many reads show RX_OVERRUN.
-spec add_mark(0..1, [pos_integer()]) -> [pos_integer()].
add_mark(Read, Marks) ->
    Count = ?FIFO_BYTES - Read,
    case lists:member(Count, Marks) of
        true -> Marks;
        false -> Marks ++ [Count]
    end.

%% Logs a warning if to_report/2 says the count is due, and returns S with the logged count
%% recorded.
report_overruns(S = #driver{overruns = Overruns, reported = Reported}) ->
    case to_report(Overruns, Reported) of
        false ->
            S;
        true ->
            logger:warning("erx_mini_uart: receive FIFO overrun, input lost (~b overruns)", [Overruns]),
            S#driver{reported = Overruns}
    end.

%% The overrun count after a read of LSR that returned Lsr, from Seen before it.
-spec count_overrun(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
count_overrun(Lsr, Seen) ->
    Seen + ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_GET(Lsr).

%% Whether Overruns, the count now, is to be logged when Reported was the count the last
%% warning gave (0 before any): the first overrun is, and then a count at least double the
%% last one logged. The first term matters only before any warning, when twice 0 is 0.
-spec to_report(non_neg_integer(), non_neg_integer()) -> boolean().
to_report(Overruns, Reported) ->
    Overruns > Reported andalso Overruns >= 2 * Reported.
