%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the mini UART driver's receive overruns: what a read of LSR says of them,
%% where the driver places the loss it sends, which counts are logged, when the driver logs
%% one against its drain, that a long write never starves the receive FIFO, and that the
%% driver keeps one input message outstanding (docs/design-live.md, "Lost input").
%% test/host/erx_mini_uart_test.rb runs them on stock's emulator.

-module(erx_mini_uart_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_hw_mini_uart.hrl").

%% The logger handler of the order case.
-export([log/2]).

-define(READY, ?ERX_HW_MINI_UART_LSR_DATA_READY_MASK).
-define(OVERRUN, ?ERX_HW_MINI_UART_LSR_RX_OVERRUN_MASK).
-define(TX, (?ERX_HW_MINI_UART_LSR_TX_EMPTY_MASK bor ?ERX_HW_MINI_UART_LSR_TX_IDLE_MASK)).
%% The receive FIFO's depth.
-define(FIFO_BYTES, 8).

%% A read without the overrun bit counts nothing, whatever else LSR says.
no_overrun_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual(5, erx_mini_uart:count_overrun(Lsr, 5)) end,
                  [0, ?READY, ?TX, ?READY bor ?TX]).

%% The read clears the bit, so the read that shows it counts it, with or without a byte
%% behind it and whether the send side or the receive side read it.
overrun_counts_whatever_else_lsr_says_test() ->
    lists:foreach(fun(Lsr) -> ?assertEqual(1, erx_mini_uart:count_overrun(Lsr, 0)) end,
                  [?OVERRUN, ?OVERRUN bor ?READY, ?OVERRUN bor ?TX, ?OVERRUN bor ?READY bor ?TX]).

%% One read of LSR decides both sides: a received byte is drained, and the same read's
%% transmit room decides between writing and waiting, so a drain never stops a write. The
%% overrun bit, counted elsewhere, decides nothing.
send_step_test() ->
    ?assertEqual({drain, write}, erx_mini_uart:send_step(?READY bor ?TX)),
    ?assertEqual({drain, wait}, erx_mini_uart:send_step(?READY bor ?OVERRUN)),
    ?assertEqual({idle, write}, erx_mini_uart:send_step(?TX)),
    ?assertEqual({idle, write}, erx_mini_uart:send_step(?TX bor ?OVERRUN)),
    ?assertEqual({idle, wait}, erx_mini_uart:send_step(0)).

%% With one overrun per check, the first and each doubling of the count are logged.
logged_counts_test() ->
    ?assertEqual([1, 2, 4, 8, 16, 32, 64, 128, 256], logged(lists:duplicate(300, 1))).

%% With several per check, a count is logged once it at least doubles the last one
%% logged, so no warning is lost to a count that skipped a power of two.
logged_counts_skip_powers_of_two_test() ->
    ?assertEqual([3, 6, 15, 30], logged([3, 1, 2, 9, 15])),
    ?assertEqual([], logged([0, 0])).

%% The counts to_report/2 logs when each step adds the overruns given to the count.
logged(Steps) ->
    {_, _, Logged} = lists:foldl(fun(Step, {Seen, Reported, Acc}) ->
                                         N = Seen + Step,
                                         case erx_mini_uart:to_report(N, Reported) of
                                             true -> {N, N, [N | Acc]};
                                             false -> {N, Reported, Acc}
                                         end
                                 end, {0, 0, []}, Steps),
    lists:reverse(Logged).

%% A burst that overran the receive FIFO, eight bytes in it and one that came after the
%% loss: the driver takes every byte, marks the loss after the eighth, and acknowledges the
%% line before it logs the overrun, so the log call, which formats and writes a line, never stalls a drain with the FIFO filling behind
%% it. The driver runs over a played device (test/erlang/stand_in/erx_device.erl): this
%% process answers its register calls from a model of the FIFO and records them, the
%% console input and the driver's log calls in the order they come.
overrun_is_logged_after_the_drain_and_the_acknowledgement_test() ->
    Self = self(),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => Self}),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        %% The start's drain finds the FIFO empty at its first read of LSR.
        {_, _} = serve(Driver, {[], [], []}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Events, _} = serve(Driver, {[], "abcdefghi", [true]}, logged, []),
        ?assertEqual([{input, <<"abcdefgh">>}, lost, {input, <<"i">>}], sent(Events ++ flush_sent(Driver))),
        Order = [E || E <- Events, E =:= {read, io} orelse E =:= ack orelse element(1, E) =:= logged],
        {Reads, After} = lists:split(9, Order),
        ?assertEqual(lists:duplicate(9, {read, io}), Reads),
        ?assertMatch([ack, {logged, {_Format, [1]}}], After)
    after
        unlink(Driver),
        exit(Driver, kill),
        logger:remove_handler(?MODULE)
    end.

%% A line typed into a full FIFO: "rm -rf /" filled it, the next byte was lost, and "x\n"
%% arrived during the drain. No byte was read since the previous read of LSR, so the loss
%% follows the eight bytes the FIFO held and comes before the newline, and the damaged line
%% goes up with its loss; a loss at the end of the drain would send "rm -rf /x" out whole.
overrun_mid_line_is_placed_where_the_bytes_were_lost_test() ->
    ?assertEqual([{input, <<"rm -rf /">>}, lost, {input, <<"x\n">>}],
                 delivered({[], "rm -rf /x\n", [true]})).

%% The overrun fell between a drain's read of LSR and its read of the byte: LSR showed data,
%% the byte "a" was read, and the next read of LSR shows the overrun. Of the eight bytes the
%% full FIFO held at the loss, "a" is read, so seven came before the loss and the newline,
%% in the FIFO's last place, came after it: the loss goes after the next seven bytes.
overrun_after_a_data_read_is_placed_one_byte_sooner_test() ->
    ?assertEqual([{input, <<"a1234567">>}, lost, {input, <<"\n">>}],
                 delivered({[], "a1234567\n", [false, true]})).

%% A FIFO that has not overrun goes up as read, with no loss.
input_without_an_overrun_has_no_loss_test() ->
    ?assertEqual([{input, <<"ls\n">>}], delivered({[], "ls\n", []})).

%% A console that answers late while a paste arrives in bursts of ten bytes, each burst
%% reaching the FIFO once a drain has read it empty (late/1): the driver reads no more than
%% its store has room for, masks its receive interrupt in IER while the store is full, so
%% the level line, which a byte in the FIFO holds raised, delivers nothing meanwhile, and on
%% the console's answer unmasks it and drains. So every byte goes up, none as a loss, one
%% message at a time, the line is not delivered again and again while the store is full,
%% and it ends unmasked.
a_late_console_leaves_its_input_in_the_fifo_test() ->
    Paste = [$a + N rem 26 || N <- lists:seq(0, 199)],
    #{input := Input, ier := Ier, masks := Masks} = late(chunks(Paste, 10)),
    ?assertEqual([{input, list_to_binary(Paste)}], joined(Input)),
    ?assert(Masks > 0),
    ?assert(Ier).

%% Starts the driver over a played mini UART whose bursts Bursts reach its FIFO one at a
%% time, the next whenever LSR shows the FIFO empty, and whose line is a level: raised while
%% the FIFO holds a byte and IER's receive interrupt is enabled, and delivered when raised
%% and the last delivery has been acknowledged. This process is the console too: it answers
%% an input message with erx_console_taken only once the driver has been quiet for 100 ms,
%% and fails the case on a second message sent before the answer, on more deliveries than a
%% burst each would need, or on the driver's crash. Returns the input messages in order,
%% whether IER ends enabled and how many times it was masked after the start.
late(Bursts) ->
    Self = self(),
    Driver = proc_lib:spawn(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    _ = monitor(process, Driver),
    try
        late_play(Driver, #{fifo => [], bursts => Bursts, ier => false, out => false,
                            started => false, masks => 0, acks => 0, input => [],
                            unanswered => false})
    after
        exit(Driver, kill)
    end.

late_play(Driver, Line) ->
    receive
        {erx_device, Driver, Call} ->
            {Answer, Next} = late_answer(Call, Line),
            Driver ! {erx_device, Answer},
            late_play(Driver, late_raise(Driver, Next));
        {erx_console_input, Bytes} ->
            late_play(Driver, late_input({input, Bytes}, Line));
        erx_console_lost ->
            late_play(Driver, late_input(lost, Line));
        {ack, Driver, _InitAck} ->
            late_play(Driver, Line);
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

late_input(Message, Line = #{unanswered := false, input := Input}) ->
    Line#{input := [Message | Input], unanswered := true}.

late_answer({read, lsr}, Line = #{fifo := [], bursts := [Burst | Rest]}) ->
    {?TX, Line#{fifo := Burst, bursts := Rest}};
late_answer({read, lsr}, Line = #{fifo := []}) ->
    {?TX, Line};
late_answer({read, lsr}, Line) ->
    {?READY bor ?TX, Line};
late_answer({read, io}, Line = #{fifo := [Byte | Rest]}) ->
    {Byte, Line#{fifo := Rest}};
late_answer({write, ier, 0}, Line = #{started := true, masks := Masks}) ->
    {ok, Line#{ier := false, masks := Masks + 1}};
late_answer({write, ier, 0}, Line) ->
    {ok, Line#{ier := false}};
late_answer({write_field, ier, rxie, Enabled}, Line) ->
    {ok, Line#{ier := Enabled =:= 1, started := true}};
late_answer({ack, _Line}, Line = #{acks := Acks}) ->
    ?assert(Acks < 100),
    {ok, Line#{out := false, acks := Acks + 1}};
late_answer(_Write, Line) ->
    {ok, Line}.

%% The level line delivered while raised, once the last delivery is acknowledged.
late_raise(Driver, Line = #{fifo := [_ | _], ier := true, out := false}) ->
    Driver ! {erx_irq, {stand_in, self()}, 0},
    Line#{out := true};
late_raise(_Driver, Line) ->
    Line.

%% The input messages, each run of bytes joined into one.
joined([{input, A}, {input, B} | Rest]) -> joined([{input, <<A/binary, B/binary>>} | Rest]);
joined([Message | Rest]) -> [Message | joined(Rest)];
joined([]) -> [].

chunks([], _Size) -> [];
chunks(List, Size) when length(List) =< Size -> [List];
chunks(List, Size) -> {Chunk, Rest} = lists:split(Size, List), [Chunk | chunks(Rest, Size)].

%% The marks a drain keeps, one per overrun not yet placed, each the bytes still to read
%% before its loss: a byte that is the last before a mark is followed by the loss; a FIFO
%% read empty first places every loss still pending as one, since no byte that came before
%% them is left in it.
marks_test() ->
    ?assertEqual({[$a], [7]}, erx_mini_uart:received($a, [8])),
    ?assertEqual({[$h, lost], [5]}, erx_mini_uart:received($h, [1, 6])),
    ?assertEqual({[$z], []}, erx_mini_uart:received($z, [])),
    ?assertEqual({[lost], []}, erx_mini_uart:received(empty, [3, 8])),
    ?assertEqual({[], []}, erx_mini_uart:received(empty, [])).

%% An overrun's mark: eight bytes when no data was read since the previous read of LSR, as
%% when a send's poll shows it, and seven after one data read; a mark already at that count
%% is the same place, so a stuck RX_OVERRUN adds none.
add_mark_test() ->
    ?assertEqual([8], erx_mini_uart:add_mark(0, [])),
    ?assertEqual([7], erx_mini_uart:add_mark(1, [])),
    ?assertEqual([3, 7], erx_mini_uart:add_mark(1, [3])),
    ?assertEqual([7], erx_mini_uart:add_mark(1, [7])).

%% An overrun the send path's read of LSR shows, which clears the bit before the drain's own
%% reads, with no data read since the previous read of LSR: the driver keeps it pending, so
%% the drain between two bytes of the send places the loss after the eight bytes the FIFO
%% held, before the two that came after it.
overrun_seen_by_a_send_is_marked_test() ->
    Self = self(),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], []}, {read, lsr}, []),
        Driver ! {erx_console_output, Self, "."},
        {Written, _} = serve(Driver, {[], "abcdefghij", [true]}, written, []),
        ?assertEqual([{input, <<"abcdefgh">>}, lost, {input, <<"ij">>}], sent(Written ++ flush_sent(Driver)))
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% The input messages one receive interrupt delivers from the FIFO given, each answered.
delivered(Fifo) ->
    Self = self(),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], []}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Events, _} = serve(Driver, Fifo, ack, []),
        sent(Events ++ flush_sent(Driver))
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% A paste at the rate the driver echoes, one byte arriving on the line for each byte the
%% driver hands the transmitter, while the console's line-long write goes out and no
%% interrupt is delivered: the transmit loop reads LSR before each byte, sees the byte
%% waiting and drains the receive FIFO before writing on, so the FIFO's eight bytes never
%% overflow and every pasted byte reaches the console. With no delivery received, nothing
%% is acknowledged during the write; the interrupt delivered after it takes the byte that
%% came with the last one and is acknowledged once.
receive_is_drained_during_a_long_write_test() ->
    Self = self(),
    Paste = "the quick brown fox jumps over the lazy dog",
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], []}, {read, lsr}, []),
        Driver ! {erx_console_output, Self, lists:duplicate(length(Paste), $.)},
        {Written, Left} = serve(Driver, {Paste, [], []}, written, []),
        ?assertEqual(length(Paste), length([E || E = {write, io, _} <- Written])),
        ?assertEqual([], [E || E = ack <- Written]),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Rest, _} = serve(Driver, Left, ack, []),
        ?assertEqual([ack], [E || E = ack <- Rest]),
        Input = << <<B/binary>> || {input, B} <- Written ++ Rest ++ flush_sent(Driver) >>,
        ?assertEqual(list_to_binary(Paste), Input)
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% A device whose DATA_READY never clears: one delivery reads at most four FIFO depths,
%% hands them up and acknowledges the line, so the driver goes on serving its mailbox
%% instead of reading forever.
wedged_receive_is_drained_a_bounded_amount_test() ->
    Self = self(),
    Driver = proc_lib:spawn_link(erx_mini_uart, init, [Self, #{stand_in => Self}]),
    try
        {_, _} = serve(Driver, {[], [], []}, {read, lsr}, []),
        Driver ! {erx_irq, {stand_in, Self}, 0},
        {Events, _} = serve(Driver, {[], wedged, []}, ack, []),
        ?assertEqual(32, length([E || E = {read, io} <- Events])),
        ?assertEqual([{input, binary:copy(<<"x">>, 32)}], sent(Events))
    after
        unlink(Driver),
        exit(Driver, kill)
    end.

%% Plays the driver's device and console until the event Until is recorded, and answers the
%% events recorded, oldest first, with the FIFO as the driver left it. Fifo is
%% {Arriving, Bytes, Overruns}: the bytes still to arrive on the line, one with each byte the
%% driver writes to IO, the receive FIFO's bytes (or `wedged`, a FIFO that always holds an
%% "x"), and whether each next read of LSR shows an overrun, none past the list's end. The
%% console answers each input message with erx_console_taken, or, with Taken `hold`, none.
%% A driver that stops short of Until fails the case.
serve(Driver, Fifo, Until, Events) ->
    serve(Driver, Fifo, Until, Events, answer).

serve(Driver, Fifo, Until, Events, Taken) ->
    receive
        {erx_device, Driver, Call} ->
            {Answer, Next} = answer(Call, Fifo),
            Driver ! {erx_device, Answer},
            recorded(Driver, Next, Until, event(Call), Events, Taken);
        {erx_console_input, Bytes} ->
            [Driver ! erx_console_taken || Taken =:= answer],
            recorded(Driver, Fifo, Until, {input, Bytes}, Events, Taken);
        erx_console_lost ->
            [Driver ! erx_console_taken || Taken =:= answer],
            recorded(Driver, Fifo, Until, lost, Events, Taken);
        {erx_console_written, _From} ->
            recorded(Driver, Fifo, Until, written, Events, Taken);
        {logged, Driver, Report} ->
            recorded(Driver, Fifo, Until, {logged, Report}, Events, Taken);
        {ack, Driver, _InitAck} ->
            serve(Driver, Fifo, Until, Events, Taken)
    after 5000 ->
            error({driver_stopped_short_of, Until, lists:reverse(Events)})
    end.

recorded(Driver, Fifo, Until, Event, Events, Taken) ->
    case Event =:= Until orelse (is_tuple(Event) andalso element(1, Event) =:= Until) of
        true -> {lists:reverse([Event | Events]), Fifo};
        false -> serve(Driver, Fifo, Until, [Event | Events], Taken)
    end.

%% The input messages among Events, in the order sent.
sent(Events) ->
    [E || E <- Events, E =:= lost orelse element(1, E) =:= input].

%% The input messages the driver still sends once each before it is answered, after the
%% event a case served to.
flush_sent(Driver) ->
    receive
        {erx_console_input, Bytes} -> Driver ! erx_console_taken, [{input, Bytes} | flush_sent(Driver)];
        erx_console_lost -> Driver ! erx_console_taken, [lost | flush_sent(Driver)]
    after 100 -> []
    end.

event({ack, _Line}) -> ack;
event(Call) -> Call.

answer({read, lsr}, Wedged = {_, wedged, _}) -> {?READY bor ?TX, Wedged};
answer({read, io}, Wedged = {_, wedged, _}) -> {$x, Wedged};
answer({read, lsr}, {Arriving, Bytes, Overruns}) ->
    Ready = case Bytes of [] -> 0; _ -> ?READY end,
    {Lost, Left} = case Overruns of
                       [true | Rest] -> {?OVERRUN, Rest};
                       [false | Rest] -> {0, Rest};
                       [] -> {0, []}
                   end,
    {Ready bor Lost bor ?TX, {Arriving, Bytes, Left}};
answer({read, io}, {Arriving, [Byte | Rest], Overrun}) -> {Byte, {Arriving, Rest, Overrun}};
answer({write, io, _Byte}, Fifo) -> {ok, arrive(Fifo)};
answer({write, _Register, _Value}, Fifo) -> {ok, Fifo};
answer({write_field, _Register, _Field, _Value}, Fifo) -> {ok, Fifo};
answer({ack, _Line}, Fifo) -> {ok, Fifo}.

%% The next byte on the line enters the receive FIFO, or is lost to a full one.
arrive({[], Bytes, Overrun}) -> {[], Bytes, Overrun};
arrive({[_Lost | Arriving], Bytes, _Overruns}) when length(Bytes) >= ?FIFO_BYTES ->
    {Arriving, Bytes, [true]};
arrive({[Byte | Arriving], Bytes, Overrun}) -> {Arriving, Bytes ++ [Byte], Overrun}.

%% The logger handler the order case adds: each event logged, with the process that logged
%% it, sent to the case, which keeps only the driver's.
log(#{msg := Msg, meta := #{pid := Pid}}, #{config := Case}) ->
    Case ! {logged, Pid, Msg}.

%% However many reads show an overrun while no byte is read, the marks stay at most one per
%% place a byte can be: an overrun before any byte is read since the last adds none, and one
%% after a byte adds one, so a device that keeps RX_OVERRUN set cannot grow the driver.
marks_are_bounded_test() ->
    Stuck = lists:foldl(fun(_, Marks) -> erx_mini_uart:add_mark(0, Marks) end, [], lists:seq(1, 100)),
    ?assertEqual([8], Stuck),
    Read = lists:foldl(fun(_, Marks) ->
                               {_, Left} = erx_mini_uart:received($a, erx_mini_uart:add_mark(1, Marks)),
                               Left
                       end, [], lists:seq(1, 100)),
    ?assertEqual([1, 2, 3, 4, 5, 6], Read).
