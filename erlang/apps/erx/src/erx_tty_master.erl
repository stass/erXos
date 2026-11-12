%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_tty_master).
-moduledoc """
The master's side of the five messages between a session's tty and the console
(docs/design-live.md, "Between domains", "A lost answer does not stop a tty" and
"A stopped tty"), as a pure state machine, the twin of the tty's own core,
erx_tty_link: each call takes one event and returns the actions it decides, in
order, and the next state. erx_console carries the actions out, one master for
each session's tty.

The master takes one output at a time. While its session is connected to the
line, an output is written to the line, and `{tty_taken, N}` is answered only
once the line has written it, so a session never has more than one output in
the console and its line driver together. While the session is not connected,
the tty is stopped: the master holds the one output it was sent and answers
nothing, and writes it once the session is connected.

Every message from the tty is checked as the design's table says. It must be
`{tty_output, N, Bytes}`, Bytes a binary of at most 4 KiB, and N either the
next output's number or the number of the output held, being written or last
taken, again with Bytes empty: the tty's resend of an output it has no answer
for. A resend of the output last taken is answered again, with the size, since
both are states and a lost one is sent again. A resend whose first send was
lost arrives as the next number with no bytes, and is taken as such: those bytes
are lost, as a line's overrun loses them, and the action `{lost, N}` has the
console log the loss. Anything else refuses the tty, with the
action `detach`: the console detaches it, and the master takes nothing from it,
answers nothing and is never connected again.
""".

-export([new/0, output/2, written/2, connect/2, disconnect/1, input/2, size/2]).
-export([is_refused/1, max_message/0]).

-export_type([master/0, action/0]).

%% The largest Bytes of a tty_output, and of a tty_input.
-define(MAX_BYTES, 4096).
%% The largest output number max_message/0 allows for: no tty sends more outputs.
-define(MAX_NUMBER, (1 bsl 64) - 1).

-type size() :: {Rows :: pos_integer(), Columns :: pos_integer()}.
-type action() :: {write, non_neg_integer(), binary()}   % write the bytes, then written(N)
                | {send, {tty_taken, non_neg_integer()}  % to the tty
                       | {tty_input, binary()}
                       | {tty_size, pos_integer(), pos_integer()}}
                | {lost, non_neg_integer()}              % log that output N's bytes were lost
                | detach.                                % the tty failed a check

-record(master, {
          %% The number the tty's next new output carries.
          next = 0 :: non_neg_integer(),
          %% The output in the console: none, held while not connected, or being written.
          output = none :: none | {held, non_neg_integer(), binary()} | {writing, non_neg_integer()},
          connected = false :: boolean(),
          %% The size last sent to the tty, which a repeated answer carries again.
          size = none :: none | size(),
          refused = false :: boolean()}).

-opaque master() :: #master{}.

-doc "A master that has taken nothing and is not connected.".
-spec new() -> master().
new() -> #master{}.

-doc "A message from the tty, checked as the design's table says.".
-spec output(term(), master()) -> {[action()], master()}.
output(_Message, M = #master{refused = true}) ->
    {[], M};
output({tty_output, N, Bytes}, M)
  when is_integer(N), N >= 0, is_binary(Bytes), byte_size(Bytes) =< ?MAX_BYTES ->
    take(N, Bytes, M);
output(_Message, M) ->
    refuse(M).

%% A new output is written if connected and held if not, and one with no bytes is a
%% resend whose first send was lost, since a tty never sends a new output empty; a
%% resend of the output in the console changes nothing; a resend of the output last
%% taken is answered again.
take(N, Bytes, M = #master{next = N, output = none, connected = Connected}) ->
    Lost = [{lost, N} || Bytes =:= <<>>],
    case Connected of
        true -> {Lost ++ [{write, N, Bytes}], M#master{output = {writing, N}}};
        false -> {Lost, M#master{output = {held, N, Bytes}}}
    end;
take(N, <<>>, M = #master{output = {held, N, _Bytes}}) ->
    {[], M};
take(N, <<>>, M = #master{output = {writing, N}}) ->
    {[], M};
take(N, <<>>, M = #master{next = Next, output = none, size = Size}) when N =:= Next - 1 ->
    {[{send, {tty_taken, N}} | [{send, {tty_size, Rows, Columns}} || {Rows, Columns} <- [Size]]], M};
take(_N, _Bytes, M) ->
    refuse(M).

refuse(M) ->
    {[detach], M#master{output = none, connected = false, refused = true}}.

-doc "The line has written output N: it is taken, and the tty told so.".
-spec written(non_neg_integer(), master()) -> {[action()], master()}.
written(N, M = #master{output = {writing, N}}) ->
    {[{send, {tty_taken, N}}], M#master{output = none, next = N + 1}};
written(_N, M) ->
    {[], M}.

-doc """
The session is connected to a line of size Size: the tty gets the size if it is new,
and then the output held is written. A refused tty is never connected.
""".
-spec connect(size(), master()) -> {[action()], master()}.
connect(_Size, M = #master{refused = true}) ->
    {[], M};
connect(Size, M0) ->
    {Sized, M1} = size(Size, M0#master{connected = true}),
    case M1 of
        #master{output = {held, N, Bytes}} ->
            {Sized ++ [{write, N, Bytes}], M1#master{output = {writing, N}}};
        #master{} ->
            {Sized, M1}
    end.

-doc """
The session is no longer connected: its tty is stopped once the output being
written, if any, is taken.
""".
-spec disconnect(master()) -> master().
disconnect(M) -> M#master{connected = false}.

-doc "Bytes typed at the line, sent to a connected tty in parts of at most 4 KiB.".
-spec input(binary(), master()) -> {[action()], master()}.
input(Bytes, M = #master{connected = true}) ->
    {[{send, {tty_input, Part}} || Part <- parts(Bytes)], M};
input(_Bytes, M) ->
    {[], M}.

-doc "The line's size, sent to a connected tty when it changes.".
-spec size(size(), master()) -> {[action()], master()}.
size(Size, M = #master{connected = true, size = Sent}) when Size =/= Sent ->
    {Rows, Columns} = Size,
    {[{send, {tty_size, Rows, Columns}}], M#master{size = Size}};
size(_Size, M) ->
    {[], M}.

-doc "Whether the tty failed a check and is detached for good.".
-spec is_refused(master()) -> boolean().
is_refused(#master{refused = Refused}) -> Refused.

-doc """
The encoded size of the largest message a tty sends its master, a tty_output of
4 KiB: the console facet's max_request, so the facet takes every message the
checks above take and drops a larger one before the console sees it.
""".
-spec max_message() -> pos_integer().
max_message() ->
    erlang:external_size({tty_output, ?MAX_NUMBER, <<0:(?MAX_BYTES * 8)>>}).

parts(<<Part:?MAX_BYTES/binary, Rest/binary>>) when Rest =/= <<>> -> [Part | parts(Rest)];
parts(<<>>) -> [];
parts(Part) -> [Part].
