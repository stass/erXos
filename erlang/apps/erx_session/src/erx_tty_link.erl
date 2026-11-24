%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_link).
-moduledoc """
The tty's side of the seven messages between a session's tty and its master
(docs/design-live.md, "Between domains", "A lost answer does not stop a
tty" and "A stopped tty"), as a pure state machine: each call takes one
event and returns the actions it decides, in order, and the next state.
The calls only change what is held; send/1, which the owner calls once at
the end of each step, sends what is held, as FreeBSD wakes the device once
after a step's input or a write (ttydisc_rint_done, tty_ttydisc.c:1293-1305;
the end of ttydisc_write, :653-658). So nothing a step drops, by a flush,
reaches the master before the drop, and what the master has outstanding
changes only between steps. erx_session_relay_core carries the actions
out.

The tty has one output outstanding at a time, numbered from 0. It sends
the bytes held once, as `{tty_output, N, Bytes}`, and asks for a timer; when
the timer for N fires with N still outstanding, it names itself again
with `{tty_open, Tty}`, sends `{tty_output, N, <<>>}` and asks again, so a
lost `{tty_taken, N}` is asked for once a second until it comes. The timer
of an output already taken does nothing. So while an output is outstanding
the tty sends its master two messages a second, and a new output follows only
the master's `{tty_taken, N}`, which the console sends once it has acted on
everything the tty sent before (erx_console, `erx_tty_message`): a new output
never meets the console facet's limit in flight filled with the tty's own
messages, past which the facet would drop it. A `{tty_taken, N}` for any other
number is a late repeat and is ignored.

It holds at most ?MAX_HELD bytes, the outstanding output among them. A
write takes what room there is, in arrival order, and its writer is told
it is done once all its bytes are held; until then the writer and every
writer after it wait. An empty write is done at once and changes nothing.
A write nobody waits on (`none`, a line editor's
redraw) may not wait unboundedly: past ?MAX_WAITING bytes waiting it is
dropped and counted. A tty whose master takes no output is stopped in
that state, and nothing piles up.

The master's other messages are states, so a repeat is harmless: a size
is reported only when it changes, and the hangup once, after which every
write is done at once and its bytes dropped, as a hung-up line's are.
Input is passed on as it came, in one numbered sequence of the master's
`{tty_input, N, Bytes}` and `{tty_lost, N}` (docs/design-live.md, "One
input sequence across domains"): N one above the last taken is the next
message, a higher N a gap, the messages between lost on the way, taken as
a loss at its place before the message, and an N not above the last is
refused, dropped and counted. So a dropped message is a loss, never a
silent one. Each receiver check is the one the design's table gives; a
message that fails it is dropped and counted.

The line discipline's actions on output reach it as calls: flush/1 drops
what it holds but the outstanding output, which the master already has,
and stop/1 and start/1 hold output back and let it go again, as VSTOP and
VSTART do. Output stopped is recorded here alone; writes still fill what
is held while it is stopped, as FreeBSD's do. room/1 is the room the line
discipline is given, derived from what it holds, so its owner counts
nothing itself.

A tty may have no master, as a session's tty has none when erx:cap(console)
names none. That is fixed at new/1: such a tty sends nothing, so it holds
4 KiB and its writers wait, as while output is stopped, and drops every
message as from a master. flowing/1 says whether what is held goes
anywhere, so an owner waits for output to drain only while it does.
""".

-export([new/1, write/3, master/2, timeout/2, flush/1, stop/1, start/1, send/1]).
-export([held/1, room/1, stopped/1, flowing/1, waiting/1, counts/1]).
-export([input_max/0]).

-export_type([link/0, writer/0, action/0, master_message/0]).

-include("generated/erx_abi.hrl").

%% At most this many bytes are held, the outstanding output among them: the
%% room the line discipline gives echo.
-define(MAX_HELD, erx_tty:master_room()).
%% At most this many bytes wait in writes nobody waits on.
-define(MAX_WAITING, 65536).
-define(MAX_INPUT, ?ERX_TTY_MAX_INPUT).

%% Who waits on a write: a term the relay hands back, or none.
-type writer() :: term().
-type master_message() :: {tty_taken, non_neg_integer()}
                        | {tty_input, non_neg_integer(), binary()}
                        | {tty_lost, non_neg_integer()}
                        | {tty_size, pos_integer(), pos_integer()}
                        | tty_hangup.
-type action() :: {output, non_neg_integer(), binary()}   % send {tty_output, N, Bytes}
                | open                                    % send {tty_open, Tty}
                | {resend_after, non_neg_integer()}       % call timeout(N) in 1 s
                | {done, writer()}                        % all its bytes are held
                | {input, binary()}                       % typed input, as it came
                | lost                                    % input lost, at its place
                | {size, pos_integer(), pos_integer()}    % Rows, Columns
                | hangup.

-record(link, {
          %% Whether the tty has a master, fixed at new/1.
          master :: none | present,
          %% The number the next new output gets.
          next = 0 :: non_neg_integer(),
          %% The number the master's next input message carries.
          input = 0 :: non_neg_integer(),
          %% The output sent and not yet taken, and its size, which counts as held.
          outstanding = none :: none | {non_neg_integer(), non_neg_integer()},
          %% Bytes held and not yet sent.
          held = <<>> :: binary(),
          %% The writers whose bytes are not all held, oldest first, each with what
          %% is left of its write.
          waiting = queue:new() :: queue:queue({writer(), binary()}),
          %% The bytes of the `none` writes among them.
          unowned = 0 :: non_neg_integer(),
          size = none :: none | erx_console:size(),
          hung_up = false :: boolean(),
          %% Output stopped by VSTOP: held bytes wait and none is sent.
          stopped = false :: boolean(),
          counts = #{output_dropped => 0, input_dropped => 0, input_refused => 0, size_refused => 0}
            :: #{atom() => non_neg_integer()}}).

-opaque link() :: #link{}.

-doc "The most bytes one `{tty_input, N, Bytes}` carries; a longer one is dropped.".
-spec input_max() -> pos_integer().
input_max() -> ?MAX_INPUT.

-doc """
A tty with nothing written, no size and no master message seen, whose
master is `present` or `none` for as long as it lives.
""".
-spec new(none | present) -> link().
new(Master) when Master =:= none; Master =:= present -> #link{master = Master}.

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
    fill(L#link{waiting = queue:in({Writer, Bytes}, Waiting), unowned = Unowned + Added}).

-doc "One of the master's messages, checked as the design's table says.".
-spec master(term(), link()) -> {[action()], link()}.
master(_Message, L = #link{master = none}) ->
    {[], L};
master({tty_taken, N}, L = #link{outstanding = {N, _Size}, hung_up = false}) ->
    fill(L#link{outstanding = none});
master({tty_taken, _N}, L) ->
    {[], L};
master({tty_input, N, Bytes}, L) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_INPUT ->
    numbered(N, [{input, Bytes} || Bytes =/= <<>>], L);
master({tty_lost, N}, L) ->
    numbered(N, [lost], L);
master(Input, L = #link{hung_up = false, counts = Counts})
  when element(1, Input) =:= tty_input; element(1, Input) =:= tty_lost ->
    {[], L#link{counts = bump(input_dropped, Counts)}};
master({tty_size, Rows, Columns}, L = #link{size = {Rows, Columns}}) ->
    {[], L};
master({tty_size, Rows, Columns}, L)
  when is_integer(Rows), Rows >= 1, Rows =< ?ERX_CONSOLE_SIDE_MAX,
       is_integer(Columns), Columns >= 1, Columns =< ?ERX_CONSOLE_SIDE_MAX ->
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

%% An input message numbered N, taking Taken: ignored after a hangup; past
%% a gap, the messages between were lost on the way, a loss before Taken
%% (one with the message's own loss); not past the last taken, refused.
numbered(_N, _Taken, L = #link{hung_up = true}) ->
    {[], L};
numbered(N, Taken, L = #link{input = Next}) when is_integer(N), N >= Next ->
    Gap = [lost || N > Next, Taken =/= [lost]],
    {Gap ++ Taken, L#link{input = N + 1}};
numbered(N, _Taken, L = #link{counts = Counts}) when is_integer(N) ->
    {[], L#link{counts = bump(input_refused, Counts)}};
numbered(_N, _Taken, L = #link{counts = Counts}) ->
    {[], L#link{counts = bump(input_dropped, Counts)}}.

-doc """
The timer for output N has fired: if N is still outstanding, the tty names
itself again and sends N again, empty; otherwise nothing.
""".
-spec timeout(non_neg_integer(), link()) -> {[action()], link()}.
timeout(N, L = #link{outstanding = {N, _Size}, hung_up = false}) ->
    {[open, {output, N, <<>>}, {resend_after, N}], L};
timeout(_N, L) ->
    {[], L}.

-doc """
A flush: the bytes held and not yet sent are dropped, and every writer
waiting is done, its bytes dropped with them. The outstanding output stays,
since the master has it.
""".
-spec flush(link()) -> {[action()], link()}.
flush(L = #link{waiting = Waiting}) ->
    Done = lists:append([done(Writer) || {Writer, _Left} <- queue:to_list(Waiting)]),
    {Done, L#link{held = <<>>, waiting = queue:new(), unowned = 0}}.

-doc "Output stops: what is held waits until start/1; writes still fill it.".
-spec stop(link()) -> link().
stop(L) -> L#link{stopped = true}.

-doc "Output starts again: the next send/1 sends what is held.".
-spec start(link()) -> link().
start(L) -> L#link{stopped = false}.

-doc """
The end of a step: what is held goes to the master as a new output, if
there is a master, nothing is outstanding and output is not stopped.
""".
-spec send(link()) -> {[action()], link()}.
send(L = #link{outstanding = none, held = Held, next = N}) when Held =/= <<>> ->
    case flowing(L) of
        true -> {[{output, N, Held}, {resend_after, N}],
                 L#link{outstanding = {N, byte_size(Held)}, held = <<>>, next = N + 1}};
        false -> {[], L}
    end;
send(L) ->
    {[], L}.

-doc """
The room for the line discipline, as erx_tty's room(): what is free of the
4 KiB, the outstanding output, which a flush cannot drop, and whether output
is stopped.
""".
-spec room(link()) -> erx_tty:room().
room(L = #link{outstanding = Outstanding, stopped = Stopped}) ->
    {?MAX_HELD - held(L), outstanding_size(Outstanding), Stopped}.

-doc "The bytes held, the outstanding output among them; never more than 4 KiB.".
-spec held(link()) -> non_neg_integer().
held(#link{outstanding = Outstanding, held = Held}) ->
    outstanding_size(Outstanding) + byte_size(Held).

-doc "Whether output is stopped.".
-spec stopped(link()) -> boolean().
stopped(#link{stopped = Stopped}) -> Stopped.

-doc """
Whether what is held goes to a master: there is one and output is not
stopped. While it does not, nothing would take the bytes.
""".
-spec flowing(link()) -> boolean().
flowing(#link{master = Master, stopped = Stopped}) -> Master =:= present andalso not Stopped.

-doc "The number of writers waiting.".
-spec waiting(link()) -> non_neg_integer().
waiting(#link{waiting = Waiting}) -> queue:len(Waiting).

-doc "How many writes, inputs and sizes were dropped or refused.".
-spec counts(link()) -> #{atom() => non_neg_integer()}.
counts(#link{counts = Counts}) -> Counts.

%%% The core's steps

%% Moves what fits from the waiting writers into the held bytes. The
%% outstanding output counts as held, so only its taking makes room.
fill(L) ->
    fill(L, []).

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
