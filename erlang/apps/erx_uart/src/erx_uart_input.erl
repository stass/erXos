%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A UART driver's input on its way to the one process it serves (docs/design-live.md,
%% "Lost input", "One input message outstanding per driver"): the units its drains read, each
%% a byte or the loss `lost`, and whether the message last sent still waits for its
%% erx_console_taken. A driver has at most one input message its owner has not taken: next/1
%% gives the next message only once taken/1 has recorded the answer to the last, so the
%% owner's mailbox holds at most one input message from the driver however late it is. A
%% UART's line cannot wait, so the driver keeps draining into this store meanwhile, which
%% holds at most Max bytes, one drain's: a byte that finds it full is dropped and becomes a
%% loss. A loss takes no byte of room, so it is kept when the
%% bytes fill the store, and losses with no byte between them, in the store or against the
%% loss last sent, are one, so the store holds at most one loss between two of its bytes.
%% Only a console's driver keeps a store: a line's driver, the host link's or a Bluetooth
%% controller's, hands each drain up as it reads it, since its owner bounds what it holds
%% and a dropped byte there would be silent.
%%
%% The messages are the driver's: {erx_console_input, Bytes}, a run of bytes in the order
%% read, and erx_console_lost, at the loss's place among them.

-module(erx_uart_input).

-export([new/1, add/2, room/1, next/1, taken/1]).
-export_type([input/0, unit/0]).

-type unit() :: byte() | lost.
-type message() :: {erx_console_input, binary()} | erx_console_lost.

%% The units held, newest first; how many of them are bytes; Max; whether the last unit
%% taken in, held or sent, was a loss; and whether a message waits for its answer.
-record(input, {held = [] :: [unit()],
                bytes = 0 :: non_neg_integer(),
                max :: pos_integer(),
                after_loss = false :: boolean(),
                waiting = false :: boolean()}).

-opaque input() :: #input{}.

-doc "An empty store of at most Max bytes.".
-spec new(pos_integer()) -> input().
new(Max) ->
    #input{max = Max}.

-doc "How many more bytes the store holds before a byte becomes a loss.".
-spec room(input()) -> non_neg_integer().
room(#input{bytes = Bytes, max = Max}) ->
    Max - Bytes.

-doc "The store after the units a drain read, in order.".
-spec add([unit()], input()) -> input().
add(Units, Input) ->
    lists:foldl(fun take_in/2, Input, Units).

take_in(lost, I = #input{after_loss = true}) ->
    I;
take_in(lost, I = #input{held = Held}) ->
    I#input{held = [lost | Held], after_loss = true};
take_in(_Byte, I = #input{bytes = Max, max = Max}) ->
    take_in(lost, I);
take_in(Byte, I = #input{held = Held, bytes = Bytes}) ->
    I#input{held = [Byte | Held], bytes = Bytes + 1, after_loss = false}.

-doc """
The next message to send and the store once it is sent, or `none` while the last message
waits for its answer or nothing is held. A message is a loss, or the bytes held before the
next loss.
""".
-spec next(input()) -> {message() | none, input()}.
next(I = #input{waiting = true}) ->
    {none, I};
next(I = #input{held = []}) ->
    {none, I};
next(I = #input{held = Held, bytes = Bytes}) ->
    case lists:reverse(Held) of
        [lost | Rest] ->
            {erx_console_lost, I#input{held = lists:reverse(Rest), waiting = true}};
        Oldest ->
            {Run, Rest} = lists:splitwith(fun is_integer/1, Oldest),
            {{erx_console_input, list_to_binary(Run)},
             I#input{held = lists:reverse(Rest), bytes = Bytes - length(Run), waiting = true}}
    end.

-doc "The store once the owner has taken the message last sent.".
-spec taken(input()) -> input().
taken(I) ->
    I#input{waiting = false}.
