%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random bytes in random chunks through erx_console:input/2, from a fixed seed. Whatever
%% arrives, it returns; what it holds back is less than one character; every control byte
%% becomes its event; and valid UTF-8 comes out as it went in, wherever the chunks fell.

-module(erx_console_input_fuzz).
-export([run/0]).

-define(ROUNDS, 20000).
-define(MAX_LENGTH, 64).

run() ->
    rand:seed(exsss, {20, 26, 8}),
    lists:foreach(fun(_) -> round_of(random_bytes()), round_of(random_text()) end,
                  lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

round_of(Bytes) ->
    {Events, Left} = feed(chunks(Bytes), <<>>, []),
    true = byte_size(Left) < 4,
    Controls = [Byte || <<Byte>> <= Bytes, Byte =:= 3 orelse Byte =:= 7],
    Controls = [control(Event) || Event <- Events, not is_tuple(Event)],
    lists:foreach(fun({data, Bin}) -> true = is_binary(unicode:characters_to_binary(Bin));
                     (_) -> ok
                  end, Events),
    case unicode:characters_to_binary(Bytes) of
        Bytes -> Bytes = iolist_to_binary([rendered(Event) || Event <- Events]);
        _Invalid -> ok
    end.

feed([], Pending, Acc) ->
    {lists:append(lists:reverse(Acc)), Pending};
feed([Chunk | Chunks], Pending, Acc) ->
    {Events, Left} = erx_console:input(Pending, Chunk),
    feed(Chunks, Left, [Events | Acc]).

control(interrupt) -> 3;
control(menu) -> 7.

rendered({data, Bin}) -> Bin;
rendered(Event) -> control(Event).

chunks(<<>>) ->
    [];
chunks(Bytes) ->
    Size = rand:uniform(byte_size(Bytes)),
    <<Chunk:Size/binary, Rest/binary>> = Bytes,
    [Chunk | chunks(Rest)].

random_bytes() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(?MAX_LENGTH)) >>.

random_text() ->
    unicode:characters_to_binary([character() || _ <- lists:seq(1, rand:uniform(?MAX_LENGTH))]).

character() ->
    case rand:uniform(4) of
        1 -> rand:uniform(128) - 1;
        2 -> 16#80 + rand:uniform(16#780) - 1;
        3 -> 16#E000 + rand:uniform(16#1000) - 1;
        4 -> 16#10000 + rand:uniform(16#1000) - 1
    end.
