%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The fuzz target of erx_ui_wire's two readers (docs/design-abi.md, "Widget
%% format"): read/1, of what a renderer sub-space writes to the widget
%% server, and read_server/1, of what the server writes to a renderer. Each
%% round encodes a random stream of one direction's records, which must read
%% back to the same records, then breaks it (bytes flipped, cut, spliced or
%% replaced by random bytes), which must read as records, more or an error,
%% and never raise.
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
    {Read, Make} = pick([{fun read_all/2, fun record/0}, {fun read_all_server/2, fun server_record/0}]),
    Records = [Make() || _ <- lists:seq(1, rand:uniform(4))],
    Stream = iolist_to_binary([erx_ui_wire:encode(Record, fun(_, _) -> <<>> end) || Record <- Records]),
    case Read(Stream, []) of
        {Records, <<>>} -> ok;
        Other -> error({round_trip, Records, Other})
    end,
    Read(break(Stream), []).

%% Server records whose every value reads back as written: no presentation,
%% whose name reads as a binary, no error, whose reason the form drops, and
%% removals in number order.
server_record() ->
    Node = rand:uniform(16#ffffffff),
    Props = maps:from_list([Prop || Prop <- [{text, status(text())}, {visible, pick([true, false])},
                                             {width, rand:uniform(16385) - 1}, {on_click, true}],
                                    rand:uniform(2) =:= 1]),
    pick([{insert, Node, rand:uniform(16#100000000) - 1, u16(), pick([label, button, column]), Props},
          {set, Node, Props, pick([[], [width], [width, visible]])},
          {remove, Node}, {move, Node, u16()}, commit, repaint,
          {screen, u16(), u16(), rand:uniform(16#100000000) - 1},
          {input, {pointer, u16(), u16(), rand:uniform(256) - 1}},
          {input, {key, pick([down, up]), u16(), pick([none, $a, 16#10ffff])}},
          {input, {wheel, rand:uniform(256) - 129}}]).

status(Value) ->
    pick([Value, {kernel, {ok, Value}}, {{stopgap, liberx_pool}, {partial, Value}}, {service, unknown},
          {runtime, unsupported}, {kernel, {timeout, rand:uniform(16#ffffffff)}}]).

text() -> unicode:characters_to_binary([pick([$a, 0, 16#e9, 16#1f600]) || _ <- lists:seq(1, rand:uniform(20))]).

-define(SERVER_TAGS, [insert, set, remove, move, commit, repaint, screen, input]).
-define(REFUSALS, [bad_length, unknown_tag, short_record, bytes_left_over, bad_node, unknown_kind, unknown_property,
                   property_twice, too_many_properties, bad_status, bad_value, unknown_input_form, bad_key_direction,
                   bad_rune]).

%% Every result of read_server/1 is a server record, more or one of its
%% reasons; a record consumes bytes, so the walk ends.
read_all_server(Bytes, Acc) ->
    case erx_ui_wire:read_server(Bytes) of
        {ok, Record, Rest} when byte_size(Rest) < byte_size(Bytes) ->
            Tag = case Record of _ when is_atom(Record) -> Record; _ -> element(1, Record) end,
            true = lists:member(Tag, ?SERVER_TAGS),
            read_all_server(Rest, [Record | Acc]);
        more -> {lists:reverse(Acc), Bytes};
        {error, Reason} ->
            true = lists:member(Reason, ?REFUSALS),
            {lists:reverse(Acc), {error, Reason}}
    end.

record() ->
    case rand:uniform(3) of
        1 -> {pixels, u16(), u16(), u16(), u16(), rand:bytes(pick([0, 1, 7, 4096, 65527]))};
        _ -> {event, rand:uniform(16#ffffffff), pick(?EVENTS), detail()}
    end.

detail() ->
    pick([none, true, false, rand:uniform(16#100000000) - 16#80000001, text()]).

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
