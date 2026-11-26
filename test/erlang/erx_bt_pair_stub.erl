%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A stub file for erx_bt_pair's reader, shared by its cases and its fuzz target: a
%% process that answers file:read/2 through the io protocol from Data, or with Reply to
%% every read when Data is `{reply, Reply}`, splits what it serves into reads as Plan says, and keeps
%% every count asked and the octets served. Plan is `all` (each read gets all it asks),
%% an octet count each read gets at most, or a list of such counts for the first reads,
%% after which each read gets all it asks.

-module(erx_bt_pair_stub).
-export([start/2, asked/1, served/1]).

start(Data, Plan) ->
    spawn_link(fun() -> serve(Data, Plan, [], 0) end).

%% Every count asked so far, oldest first.
asked(Stub) -> element(1, report(Stub)).

%% The octets served so far.
served(Stub) -> element(2, report(Stub)).

report(Stub) ->
    Stub ! {report, self()},
    receive {report, Stub, Asked, Served} -> {Asked, Served} end.

serve(Data, Plan, Asked, Served) ->
    receive
        {io_request, From, Ref, {get_chars, latin1, '', Count}} ->
            {Allowed, Later} = allowance(Plan),
            {Reply, Rest} = chars(Data, min(Count, Allowed)),
            From ! {io_reply, Ref, Reply},
            serve(Rest, Later, [Count | Asked], Served + served_by(Reply));
        {report, From} ->
            From ! {report, self(), lists:reverse(Asked), Served},
            serve(Data, Plan, Asked, Served)
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

served_by(Reply) when is_binary(Reply) -> byte_size(Reply);
served_by(Reply) when is_list(Reply) -> length(Reply);
served_by(_) -> 0.
