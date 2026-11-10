%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_link).
-moduledoc """
The tty's side of the five messages between a session's tty and its master
(docs/design-live.md, "Between domains", "A lost answer does not stop a
tty" and "A stopped tty"), as a pure state machine: each call takes one
event and returns the actions it decides, in order, and the next state.
erx_session_tty carries the actions out.

The tty has one output outstanding at a time, numbered from 0. It sends
the bytes once, as `{tty_output, N, Bytes}`, and asks for a timer; when
the timer for N fires with N still outstanding, it sends
`{tty_output, N, <<>>}` and asks again, so a lost `{tty_taken, N}` is
asked for once a second until it comes. A `{tty_taken, N}` for any other
number is a late repeat and is ignored.

It holds at most ?MAX_HELD bytes, the outstanding output among them. A
write takes what room there is, in arrival order, and its writer is told
it is done once all its bytes are held; until then the writer and every
writer after it wait. A write nobody waits on (`none`, a line editor's
redraw) may not wait unboundedly: past ?MAX_WAITING bytes waiting it is
dropped and counted. A tty whose master takes no output is stopped in
that state, and nothing piles up.

The master's other messages are states, so a repeat is harmless: a size
is reported only when it changes, and the hangup once, after which every
write is done at once and its bytes dropped, as a hung-up line's are.
Input is passed on as it came. Each receiver check is the one the design's
table gives; a message that fails it is dropped and counted.
""".

-export([new/0, write/3, master/2, timeout/2]).
-export([held/1, waiting/1, counts/1]).

-export_type([link/0, writer/0, action/0, master_message/0]).

%% At most this many bytes are held, the outstanding output among them.
-define(MAX_HELD, 4096).
%% At most this many bytes wait in writes nobody waits on.
-define(MAX_WAITING, 65536).
-define(MAX_INPUT, 4096).
-define(MAX_SIDE, 65535).

%% Who waits on a write: a term erx_session_tty hands back, or none.
-type writer() :: term().
-type master_message() :: {tty_taken, non_neg_integer()}
                        | {tty_input, binary()}
                        | {tty_size, pos_integer(), pos_integer()}
                        | tty_hangup.
-type action() :: {output, non_neg_integer(), binary()}   % send {tty_output, N, Bytes}
                | {resend_after, non_neg_integer()}       % call timeout(N) in 1 s
                | {done, writer()}                        % all its bytes are held
                | {input, binary()}                       % typed input, as it came
                | {size, pos_integer(), pos_integer()}    % Rows, Columns
                | hangup.

-record(link, {
          %% The number the next new output gets.
          next = 0 :: non_neg_integer(),
          %% The output sent and not yet taken, and its size, which counts as held.
          outstanding = none :: none | {non_neg_integer(), non_neg_integer()},
          %% Bytes held and not yet sent.
          held = <<>> :: binary(),
          %% The writers whose bytes are not all held, oldest first, each with what
          %% is left of its write.
          waiting = queue:new() :: queue:queue({writer(), binary()}),
          %% The bytes of the `none` writes among them.
          unowned = 0 :: non_neg_integer(),
          size = none :: none | {pos_integer(), pos_integer()},
          hung_up = false :: boolean(),
          counts = #{output_dropped => 0, input_dropped => 0, size_refused => 0}
            :: #{atom() => non_neg_integer()}}).

-opaque link() :: #link{}.

-doc "A tty with nothing written, no size and no master message seen.".
-spec new() -> link().
new() -> #link{}.

-doc """
Writer writes Bytes. The writer is done at once if its bytes all fit and
nobody waits before it; otherwise it waits behind the writers before it.
""".
-spec write(writer(), binary(), link()) -> {[action()], link()}.
write(Writer, _Bytes, L = #link{hung_up = true}) ->
    {done(Writer), L};
write(Writer, <<>>, L) ->
    {done(Writer), L};
write(none, Bytes, L = #link{unowned = Unowned, counts = Counts})
  when Unowned + byte_size(Bytes) > ?MAX_WAITING ->
    {[], L#link{counts = bump(output_dropped, Counts)}};
write(Writer, Bytes, L = #link{waiting = Waiting, unowned = Unowned}) ->
    Added = case Writer of none -> byte_size(Bytes); _ -> 0 end,
    send(L#link{waiting = queue:in({Writer, Bytes}, Waiting), unowned = Unowned + Added}).

-doc "One of the master's messages, checked as the design's table says.".
-spec master(term(), link()) -> {[action()], link()}.
master({tty_taken, N}, L = #link{outstanding = {N, _Size}, hung_up = false}) ->
    send(L#link{outstanding = none});
master({tty_taken, _N}, L) ->
    {[], L};
master({tty_input, Bytes}, L = #link{hung_up = false})
  when is_binary(Bytes), byte_size(Bytes) =< ?MAX_INPUT ->
    {[{input, Bytes} || Bytes =/= <<>>], L};
master({tty_input, _Bytes}, L = #link{hung_up = true}) ->
    {[], L};
master({tty_input, _Bytes}, L = #link{counts = Counts}) ->
    {[], L#link{counts = bump(input_dropped, Counts)}};
master({tty_size, Rows, Columns}, L = #link{size = {Rows, Columns}}) ->
    {[], L};
master({tty_size, Rows, Columns}, L)
  when is_integer(Rows), Rows >= 1, Rows =< ?MAX_SIDE,
       is_integer(Columns), Columns >= 1, Columns =< ?MAX_SIDE ->
    {[{size, Rows, Columns}], L#link{size = {Rows, Columns}}};
master({tty_size, _Rows, _Columns}, L = #link{counts = Counts}) ->
    {[], L#link{counts = bump(size_refused, Counts)}};
master(tty_hangup, L = #link{hung_up = true}) ->
    {[], L};
master(tty_hangup, L = #link{waiting = Waiting}) ->
    Done = lists:append([done(Writer) || {Writer, _Left} <- queue:to_list(Waiting)]),
    {[hangup | Done], L#link{outstanding = none, held = <<>>, waiting = queue:new(),
                             unowned = 0, hung_up = true}};
master(_Other, L) ->
    {[], L}.

-doc "The timer for output N has fired: N is sent again, empty, if it is still outstanding.".
-spec timeout(non_neg_integer(), link()) -> {[action()], link()}.
timeout(N, L = #link{outstanding = {N, _Size}, hung_up = false}) ->
    {[{output, N, <<>>}, {resend_after, N}], L};
timeout(_N, L) ->
    {[], L}.

-doc "The bytes held, the outstanding output among them; never more than 4 KiB.".
-spec held(link()) -> non_neg_integer().
held(#link{outstanding = Outstanding, held = Held}) ->
    outstanding_size(Outstanding) + byte_size(Held).

-doc "The number of writers waiting.".
-spec waiting(link()) -> non_neg_integer().
waiting(#link{waiting = Waiting}) -> queue:len(Waiting).

-doc "How many writes, inputs and sizes were dropped or refused.".
-spec counts(link()) -> #{atom() => non_neg_integer()}.
counts(#link{counts = Counts}) -> Counts.

%%% The core's steps

%% Moves what fits from the waiting writers into the held bytes, and sends the
%% held bytes if nothing is outstanding. The outstanding output counts as held,
%% so sending makes no room.
send(L0) ->
    {Done, L1} = fill(L0, []),
    {Sent, L2} = start_output(L1),
    {Done ++ Sent, L2}.

start_output(L = #link{outstanding = none, held = Held, next = N}) when Held =/= <<>> ->
    {[{output, N, Held}, {resend_after, N}],
     L#link{outstanding = {N, byte_size(Held)}, held = <<>>, next = N + 1}};
start_output(L) ->
    {[], L}.

fill(L = #link{waiting = Waiting, held = Held, unowned = Unowned}, Done) ->
    Room = ?MAX_HELD - held(L),
    case queue:out(Waiting) of
        {{value, {Writer, Bytes}}, Rest} when Room > 0 ->
            Take = min(Room, byte_size(Bytes)),
            <<Taken:Take/binary, Left/binary>> = Bytes,
            Freed = case Writer of none -> Take; _ -> 0 end,
            Next = L#link{held = <<Held/binary, Taken/binary>>, unowned = Unowned - Freed},
            case Left of
                <<>> -> fill(Next#link{waiting = Rest}, [done(Writer) | Done]);
                _ -> {lists:append(lists:reverse(Done)),
                      Next#link{waiting = queue:in_r({Writer, Left}, Rest)}}
            end;
        _ ->
            {lists:append(lists:reverse(Done)), L}
    end.

outstanding_size(none) -> 0;
outstanding_size({_N, Size}) -> Size.

done(none) -> [];
done(Writer) -> [{done, Writer}].

bump(Key, Counts) -> maps:update_with(Key, fun(Count) -> Count + 1 end, Counts).
