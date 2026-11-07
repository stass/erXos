%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_pipe).
-moduledoc """
A pipe between Erlang stages of the command shell (docs/design-shell.md,
"Pipelines"): one process holding what a stage wrote and its reader has
not yet taken, bytes and records in the order they were written.

Bounds. At most 256 items and 1 MiB are in flight: a writer whose item
does not fit waits until the reader takes enough. Adjacent bytes merge
into one item, so a line written a byte at a time never fills the item
count. A reader takes a line, at most 64 KiB, or a record; bytes that
reach 64 KiB without a newline answer `line_too_long`, so no input makes
a reader gather without bound.

Ends. The runner that makes a pipe attaches each stage to the end it
holds, and the pipe monitors every holder. When every writer has ended,
a reader that drained the pipe gets `eof`; when every reader has ended,
what was in flight is dropped and every writer, waiting or not, gets
`epipe`, as a write on a pipe with no reader does. An end that nothing
ever attached stays open: the runner stops every pipe it made once the
request that made it is done, and a pipe also ends with the process that
made it, so no pipe outlives its line.

`from_binary/1` and `from_file/1` make a pipe a pump process fills, for
a here document and for `<`, so every input an Erlang command reads is a
pipe and has the same bounds.
""".

-export([new/0, attach/3, put/2, get/1, get_chunk/1, stop/1,
         from_binary/1, from_file/1]).

-export_type([item/0]).

-compile({no_auto_import, [put/2, get/1]}).

-define(MAX_ITEMS, 256).
-define(MAX_BYTES, 1 bsl 20).
-define(MAX_LINE, 1 bsl 16).
%% A writer's bytes go in pieces of at most this size, so one fits an
%% empty pipe whatever its length.
-define(PIECE, 65536).

%% A record carries the order of its fields, the emitting command's, so a
%% stage that renders it into a line keeps that order.
-type item() :: {bytes, binary()} | {record, [atom()], map()}.
-type end_() :: read | write.

-doc "A new, empty pipe, which ends when its maker does.".
-spec new() -> pid().
new() ->
    Maker = self(),
    spawn(fun() ->
                  monitor(process, Maker),
                  loop(#{maker => Maker, items => queue:new(), count => 0,
                         bytes => 0, putters => queue:new(),
                         getters => queue:new(), holders => #{},
                         held => #{read => 0, write => 0},
                         seen => #{read => false, write => false}})
          end).

-doc "Makes Pid a holder of the pipe's End.".
-spec attach(pid(), end_(), pid()) -> ok.
attach(Pipe, End, Pid) when End =:= read; End =:= write ->
    Pipe ! {attach, End, Pid},
    ok.

-doc """
Writes an item, waiting while the pipe is full: `ok`, or `{error, epipe}`
when no reader is left or the pipe is gone.
""".
-spec put(pid(), item()) -> ok | {error, epipe}.
put(Pipe, {bytes, Bytes}) when byte_size(Bytes) > ?PIECE ->
    <<Piece:?PIECE/binary, Rest/binary>> = Bytes,
    case call(Pipe, {put, {bytes, Piece}}, {error, epipe}) of
        ok -> put(Pipe, {bytes, Rest});
        Error -> Error
    end;
put(_Pipe, {bytes, <<>>}) ->
    ok;
put(Pipe, Item) ->
    call(Pipe, {put, Item}, {error, epipe}).

-doc """
The next line, with its newline unless it is the last and has none, or
the next record; `eof` once every writer has ended and the pipe is
drained, or the pipe is gone.
""".
-spec get(pid()) -> {line, binary()} | {record, [atom()], map()} | eof
                        | {error, line_too_long}.
get(Pipe) -> call(Pipe, {get, line}, eof).

-doc "The next bytes, however many are in flight, or the next record.".
-spec get_chunk(pid()) -> {bytes, binary()} | {record, [atom()], map()} | eof.
get_chunk(Pipe) -> call(Pipe, {get, chunk}, eof).

-doc "Ends the pipe and whatever pumps it.".
-spec stop(pid()) -> ok.
stop(Pipe) ->
    exit(Pipe, kill),
    ok.

-doc "A pipe holding Bytes and then its end, for a here document.".
-spec from_binary(binary()) -> pid().
from_binary(Bytes) ->
    Pipe = new(),
    spawn(fun() -> pump_start(Pipe, fun() -> pump_binary(Pipe, Bytes) end) end),
    Pipe.

-doc """
A pipe that a pump fills from the file at Path, opened before this
returns so that a file that cannot be read is an error of the caller.
""".
-spec from_file(binary()) -> {ok, pid()} | {error, file:posix() | badarg}.
from_file(Path) ->
    Pipe = new(),
    Caller = self(),
    Ref = make_ref(),
    {_Pump, PumpRef} =
        spawn_monitor(fun() ->
                              case file:open(Path, [read, raw, binary]) of
                                  {ok, Fd} ->
                                      Caller ! {Ref, ok},
                                      pump_start(Pipe, fun() -> pump_file(Pipe, Fd) end);
                                  {error, Reason} ->
                                      Caller ! {Ref, {error, Reason}}
                              end
                      end),
    receive
        {Ref, ok} ->
            demonitor(PumpRef, [flush]),
            {ok, Pipe};
        {Ref, {error, Reason}} ->
            demonitor(PumpRef, [flush]),
            stop(Pipe),
            {error, Reason};
        {'DOWN', PumpRef, process, _, _} ->
            stop(Pipe),
            {error, badarg}
    end.

%%% The pumps

%% A pump holds the write end and ends with the pipe.
pump_start(Pipe, Fill) ->
    monitor(process, Pipe),
    attach(Pipe, write, self()),
    Fill().

pump_binary(Pipe, Bytes) ->
    _ = put(Pipe, {bytes, Bytes}),
    ok.

pump_file(Pipe, Fd) ->
    case file:read(Fd, ?PIECE) of
        {ok, Bytes} ->
            case put(Pipe, {bytes, Bytes}) of
                ok -> pump_file(Pipe, Fd);
                {error, epipe} -> ok
            end;
        _EofOrError ->
            ok
    end.

%%% Calls

call(Pipe, Request, Gone) ->
    Ref = monitor(process, Pipe),
    Pipe ! {Request, self(), Ref},
    receive
        {Ref, Reply} ->
            demonitor(Ref, [flush]),
            Reply;
        {'DOWN', Ref, process, _, _} ->
            Gone
    end.

%%% The pipe's process

loop(State) ->
    receive
        {{put, Item}, From, Ref} ->
            loop(serve(offer({From, Ref, Item}, State)));
        {{get, Mode}, From, Ref} ->
            #{getters := Getters} = State,
            loop(serve(State#{getters := queue:in({From, Ref, Mode}, Getters)}));
        {attach, End, Pid} ->
            loop(attach_holder(End, Pid, State));
        {'DOWN', _, process, Pid, _} ->
            case State of
                #{maker := Pid} -> exit(normal);
                _ -> loop(serve(detach_holder(Pid, State)))
            end
    end.

attach_holder(End, Pid, #{holders := Holders, held := Held, seen := Seen} = State) ->
    monitor(process, Pid),
    State#{holders := Holders#{Pid => End},
           held := Held#{End := maps:get(End, Held) + 1},
           seen := Seen#{End := true}}.

detach_holder(Pid, #{holders := Holders, held := Held} = State) ->
    case maps:take(Pid, Holders) of
        {End, Holders1} ->
            State1 = State#{holders := Holders1,
                            held := Held#{End := maps:get(End, Held) - 1}},
            case End =:= read andalso closed(read, State1) of
                true -> refuse_writers(State1);
                false -> State1
            end;
        error ->
            State
    end.

%% An end is closed once something held it and nothing holds it now.
closed(End, #{held := Held, seen := Seen}) ->
    maps:get(End, Seen) andalso maps:get(End, Held) =:= 0.

%% No reader is left: what was in flight is dropped and every writer told.
refuse_writers(#{putters := Putters} = State) ->
    [From ! {Ref, {error, epipe}} || {From, Ref, _} <- queue:to_list(Putters)],
    State#{items := queue:new(), count := 0, bytes := 0, putters := queue:new()}.

%% A writer's item is taken when it fits, or when the pipe is empty, and
%% the writer waits otherwise.
offer({From, Ref, _Item} = Put, #{putters := Putters} = State) ->
    case closed(read, State) of
        true ->
            From ! {Ref, {error, epipe}},
            State;
        false ->
            State#{putters := queue:in(Put, Putters)}
    end.

%% Takes every waiting item that fits, then answers every reader it can.
serve(State) ->
    answer(admit(State)).

admit(#{putters := Putters} = State) ->
    case queue:out(Putters) of
        {{value, {From, Ref, Item}}, Rest} ->
            case fits(Item, State) of
                true ->
                    From ! {Ref, ok},
                    admit(enqueue(Item, State#{putters := Rest}));
                false ->
                    State
            end;
        {empty, _} ->
            State
    end.

fits(_Item, #{count := 0}) -> true;
fits(Item, #{count := Count, bytes := Bytes, items := Items}) ->
    Merges = element(1, Item) =:= bytes andalso tail_is_bytes(Items),
    (Merges orelse Count < ?MAX_ITEMS) andalso Bytes + size_of(Item) =< ?MAX_BYTES.

tail_is_bytes(Items) ->
    case queue:peek_r(Items) of
        {value, {bytes, _}} -> true;
        _ -> false
    end.

size_of({bytes, Bytes}) -> byte_size(Bytes);
size_of({record, _, _} = Record) -> erlang:external_size(Record).

enqueue({bytes, New} = Item, #{items := Items, count := Count, bytes := Bytes} = State) ->
    case queue:out_r(Items) of
        {{value, {bytes, Old}}, Front} ->
            State#{items := queue:in({bytes, <<Old/binary, New/binary>>}, Front),
                   bytes := Bytes + byte_size(New)};
        _ ->
            State#{items := queue:in(Item, Items), count := Count + 1,
                   bytes := Bytes + byte_size(New)}
    end;
enqueue(Item, #{items := Items, count := Count, bytes := Bytes} = State) ->
    State#{items := queue:in(Item, Items), count := Count + 1,
           bytes := Bytes + size_of(Item)}.

answer(#{getters := Getters} = State) ->
    case queue:out(Getters) of
        {{value, {From, Ref, Mode}}, Rest} ->
            case take(Mode, State) of
                {Reply, State1} ->
                    From ! {Ref, Reply},
                    answer(admit(State1#{getters := Rest}));
                wait ->
                    State
            end;
        {empty, _} ->
            State
    end.

%% What a reader in Mode gets from the head of the pipe, or wait.
take(Mode, #{items := Items} = State) ->
    case queue:out(Items) of
        {empty, _} ->
            case closed(write, State) of
                true -> {eof, State};
                false -> wait
            end;
        {{value, {record, _, _} = Record}, Rest} ->
            {Record, dropped(Record, Rest, State)};
        {{value, {bytes, _} = Head}, Rest} when Mode =:= chunk ->
            {Head, dropped(Head, Rest, State)};
        {{value, {bytes, Bytes}}, Rest} ->
            take_line(Bytes, Rest, State)
    end.

%% A line ends at a newline; bytes before a record or the end of input are
%% a line of their own.
take_line(Bytes, Rest, State) ->
    case binary:match(Bytes, <<"\n">>) of
        {At, 1} when At < ?MAX_LINE ->
            <<Line:(At + 1)/binary, After/binary>> = Bytes,
            {{line, Line}, remaining(After, byte_size(Line), Rest, State)};
        {_, 1} ->
            {{error, line_too_long}, State};
        nomatch when byte_size(Bytes) >= ?MAX_LINE ->
            {{error, line_too_long}, State};
        nomatch ->
            case closed(write, State) orelse not queue:is_empty(Rest) of
                true -> {{line, Bytes}, dropped({bytes, Bytes}, Rest, State)};
                false -> wait
            end
    end.

remaining(<<>>, Taken, Rest, #{count := Count, bytes := Bytes} = State) ->
    State#{items := Rest, count := Count - 1, bytes := Bytes - Taken};
remaining(After, Taken, Rest, #{bytes := Bytes} = State) ->
    State#{items := queue:in_r({bytes, After}, Rest), bytes := Bytes - Taken}.

dropped(Item, Rest, #{count := Count, bytes := Bytes} = State) ->
    State#{items := Rest, count := Count - 1, bytes := Bytes - size_of(Item)}.
