%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random bytes in random chunks through erx_console:input/2. Whatever arrives, it returns,
%% what it holds back is less than one character, its text is UTF-8, and what it says agrees
%% with reference/1, a reader of the whole input that shares no code with it, so a byte that
%% is not part of a character is checked as latin-1 wherever the chunks fell. The seed comes
%% from make check-fuzz.

-module(erx_console_input_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MAX_LENGTH, 64).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    lists:foreach(fun(_) ->
                          round_of(random_bytes()),
                          round_of(random_text()),
                          round_of(torn_text())
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

round_of(Bytes) ->
    {Events, Left} = feed(chunks(Bytes), <<>>, []),
    true = byte_size(Left) < 4,
    %% Only a character cut short waits, so a key typed reaches the group at once.
    case Left of
        <<>> -> ok;
        _ -> {incomplete, <<>>, Left} = unicode:characters_to_binary(Left)
    end,
    lists:foreach(fun({data, Bin}) -> true = is_binary(unicode:characters_to_binary(Bin));
                     (_) -> ok
                  end, Events),
    case said(Events, Left) =:= reference(Bytes) of
        true -> ok;
        false -> error({disagrees_with_reference, Bytes, Events, Left})
    end.

feed([], Pending, Acc) ->
    {lists:append(lists:reverse(Acc)), Pending};
feed([Chunk | Chunks], Pending, Acc) ->
    {Events, Left} = erx_console:input(Pending, Chunk),
    feed(Chunks, Left, [Events | Acc]).

%% What the events say, then what is held back as the console reads it at end of input: each
%% byte latin-1, whose code points are the byte values.
said(Events, Left) ->
    lists:flatmap(fun({data, Bin}) -> [Char || <<Char/utf8>> <= Bin];
                     (Event) -> [Event]
                  end, Events) ++ binary_to_list(Left).

%% The reference: one pass with the compiler's own UTF-8 matching. A control byte is its
%% event, a character is itself, and any other byte reads as latin-1.
reference(<<>>) -> [];
reference(<<3, Rest/binary>>) -> [interrupt | reference(Rest)];
reference(<<26, Rest/binary>>) -> [suspend | reference(Rest)];
reference(<<Char/utf8, Rest/binary>>) -> [Char | reference(Rest)];
reference(<<Byte, Rest/binary>>) -> [Byte | reference(Rest)].

chunks(<<>>) ->
    [];
chunks(Bytes) ->
    Size = rand:uniform(byte_size(Bytes)),
    <<Chunk:Size/binary, Rest/binary>> = Bytes,
    [Chunk | chunks(Rest)].

random_bytes() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(?MAX_LENGTH)) >>.

random_text() ->
    unicode:characters_to_binary(random_characters()).

%% Characters cut short, so sequences that start well end in the latin-1 branch.
torn_text() ->
    << <<(torn(Char))/binary>> || Char <- random_characters() >>.

torn(Char) ->
    Bytes = <<Char/utf8>>,
    binary:part(Bytes, 0, rand:uniform(byte_size(Bytes))).

random_characters() ->
    [character() || _ <- lists:seq(1, rand:uniform(?MAX_LENGTH))].

character() ->
    case rand:uniform(4) of
        1 -> rand:uniform(128) - 1;
        2 -> 16#80 + rand:uniform(16#780) - 1;
        3 -> 16#E000 + rand:uniform(16#1000) - 1;
        4 -> 16#10000 + rand:uniform(16#1000) - 1
    end.
