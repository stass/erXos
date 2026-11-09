%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The fuzz target of erx_ui_wire:read/1, the reader of what a renderer
%% sub-space writes to the widget server (docs/design-abi.md, "Widget format").
%% Each round encodes a random stream of events and pixels reports, which must
%% read back to the same records, then breaks it (bytes flipped, cut, spliced
%% or replaced by random bytes), which must read as records, more or an
%% error, and never raise.
-module(erx_ui_wire_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(EVENTS, [on_select, on_click, on_change, on_submit]).

run([Seed]) ->
    rand:seed(exsss, {list_to_integer(Seed), 11, 13}),
    try
        lists:foreach(fun(_) -> round() end, lists:seq(1, ?ROUNDS)),
        io:format("fuzz: ~b rounds ok~n", [?ROUNDS])
    catch
        Class:Reason:Stack ->
            io:format("fuzz failed: ~p:~P~n~P~n", [Class, Reason, 40, Stack, 20]),
            halt(1)
    end.

round() ->
    Records = [record() || _ <- lists:seq(1, rand:uniform(4))],
    Stream = iolist_to_binary([erx_ui_wire:encode(Record, fun(_, _) -> <<>> end) || Record <- Records]),
    case read_all(Stream, []) of
        {Records, <<>>} -> ok;
        Other -> error({round_trip, Records, Other})
    end,
    read_all(break(Stream), []).

record() ->
    case rand:uniform(3) of
        1 -> {pixels, u16(), u16(), u16(), u16(), rand:bytes(pick([0, 1, 7, 4096, 65527]))};
        _ -> {event, rand:uniform(16#ffffffff), pick(?EVENTS), detail()}
    end.

detail() ->
    pick([none, true, false, rand:uniform(16#100000000) - 16#80000001,
          unicode:characters_to_binary([pick([$a, 0, 16#e9, 16#1f600]) || _ <- lists:seq(1, rand:uniform(20))])]).

break(Stream) ->
    Size = byte_size(Stream),
    case rand:uniform(4) of
        1 -> flip(Stream, rand:uniform(8));
        2 -> binary:part(Stream, 0, rand:uniform(Size) - 1);
        3 -> Cut = rand:uniform(Size) - 1,
             <<(binary:part(Stream, 0, Cut))/binary, (rand:bytes(rand:uniform(16)))/binary,
               (binary:part(Stream, Cut, Size - Cut))/binary>>;
        4 -> rand:bytes(rand:uniform(64))
    end.

flip(Stream, 0) -> Stream;
flip(Stream, N) ->
    At = rand:uniform(byte_size(Stream)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Stream,
    flip(<<Before/binary, (Byte bxor (1 bsl (rand:uniform(8) - 1)))/integer, After/binary>>, N - 1).

%% Every result is a record of the two the reader may return, more or one of
%% its reasons; a record consumes bytes, so the walk ends.
read_all(Bytes, Acc) ->
    case erx_ui_wire:read(Bytes) of
        {ok, {event, Node, Event, Detail} = Record, Rest}
          when is_integer(Node), Node >= 1, byte_size(Rest) < byte_size(Bytes) ->
            true = lists:member(Event, ?EVENTS),
            true = Detail =:= none orelse is_boolean(Detail) orelse is_integer(Detail) orelse is_binary(Detail),
            read_all(Rest, [Record | Acc]);
        {ok, {pixels, _, _, _, _, Pixels} = Record, Rest} when is_binary(Pixels), byte_size(Rest) < byte_size(Bytes) ->
            read_all(Rest, [Record | Acc]);
        more -> {lists:reverse(Acc), Bytes};
        {error, Reason} when Reason =:= bad_length; Reason =:= bad_tag; Reason =:= bad_node;
                             Reason =:= bad_event; Reason =:= bad_detail; Reason =:= bad_body ->
            {lists:reverse(Acc), {error, Reason}}
    end.

u16() -> rand:uniform(65536) - 1.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
