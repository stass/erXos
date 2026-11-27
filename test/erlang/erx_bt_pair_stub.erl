%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stub file for erx_bt_pair's reader, shared by its cases, its fuzz target and
%% btpair's cases: a process that answers file:read/2 through the io protocol from Data,
%% or with Reply to every read when Data is `{reply, Reply}`, splits what it serves into
%% reads as Plan says, and keeps every count asked and the octets served. Plan is `all`
%% (each read gets all it asks), an octet count each read gets at most, or a list of such
%% counts for the first reads, after which each read gets all it asks. A file:read_line/1
%% gets the rest of its line, newline included, whatever Plan says. It answers every
%% file:write/2 with Write, `ok` unless start/3 gives another answer, and keeps the
%% octets written, and watches the writer, the file's owner: it answers file:close/1
%% with `ok`, and keeps that the file was closed, as a server sees a clunk, at that
%% close or at the owner's end. A read of Data `hold` gets no answer.

-module(erx_bt_pair_stub).
-export([start/2, start/3, asked/1, served/1, written/1, closed/1]).

start(Data, Plan) -> start(Data, Plan, ok).

start(Data, Plan, Write) ->
    spawn_link(fun() ->
                       serve(#{data => Data, plan => Plan, write => Write, asked => [],
                               served => 0, written => <<>>, closed => false})
               end).

%% Every count asked so far, oldest first.
asked(Stub) -> lists:reverse(maps:get(asked, report(Stub))).

%% The octets served so far.
served(Stub) -> maps:get(served, report(Stub)).

%% The octets written so far, the writes joined.
written(Stub) -> maps:get(written, report(Stub)).

%% Whether the file was closed.
closed(Stub) -> maps:get(closed, report(Stub)).

report(Stub) ->
    Stub ! {report, self()},
    receive {report, Stub, State} -> State end.

serve(#{data := Data, plan := Plan, asked := Asked, served := Served} = State) ->
    receive
        {io_request, _From, _Ref, {get_chars, latin1, '', Count}} when Data =:= hold ->
            serve(State#{asked := [Count | Asked]});
        {io_request, From, Ref, {get_chars, latin1, '', Count}} ->
            {Allowed, Later} = allowance(Plan),
            {Reply, Rest} = chars(Data, min(Count, Allowed)),
            From ! {io_reply, Ref, Reply},
            serve(State#{data := Rest, plan := Later, asked := [Count | Asked],
                         served := Served + served_by(Reply)});
        {io_request, From, Ref, {put_chars, latin1, Bytes}} ->
            #{write := Write, written := Written} = State,
            From ! {io_reply, Ref, Write},
            erlang:monitor(process, From),
            serve(State#{written := <<Written/binary, Bytes/binary>>});
        {io_request, From, Ref, {get_line, latin1, ''}} ->
            {Reply, Rest} = line(Data),
            From ! {io_reply, Ref, Reply},
            serve(State#{data := Rest, served := Served + served_by(Reply)});
        {file_request, From, Ref, close} ->
            From ! {file_reply, Ref, ok},
            serve(State#{closed := true});
        {'DOWN', _Monitor, process, _Owner, _Reason} ->
            serve(State#{closed := true});
        {report, From} ->
            From ! {report, self(), State},
            serve(State)
    end.

allowance(all) -> {infinity, all};
allowance([]) -> {infinity, all};
allowance([Allowed | Later]) -> {Allowed, Later};
allowance(Allowed) when is_integer(Allowed) -> {Allowed, Allowed}.

chars({reply, Reply} = Data, _) -> {Reply, Data};
chars(<<>>, _) -> {eof, <<>>};
chars(Data, Count) ->
    Take = min(Count, byte_size(Data)),
    <<Taken:Take/binary, Rest/binary>> = Data,
    {Taken, Rest}.

line(<<>>) -> {eof, <<>>};
line(Data) ->
    case binary:split(Data, <<"\n">>) of
        [Line, Rest] -> {<<Line/binary, "\n">>, Rest};
        [Line] -> {Line, <<>>}
    end.

served_by(Reply) when is_binary(Reply) -> byte_size(Reply);
served_by(Reply) when is_list(Reply) -> length(Reply);
served_by(_) -> 0.
