%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random writes through erx_wctl:parse/1, the parser of a window's wctl
%% file, whose bytes come from a client. Whatever arrives, it returns
%% `{ok, Command}` or `{error, einval}` and never raises, and what it says
%% agrees with reference/1, a reader of the same grammar written as one
%% regular expression with the bound and the range checked apart, which
%% shares no code with the parser. The inputs are random bytes, valid lines
%% with random white space and coordinates near the 32-bit edges, lines
%% padded across the 1,024-byte bound, and valid lines with a byte changed,
%% inserted or removed. The seed comes from make check-fuzz.

-module(erx_wctl_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MAX_LINE, 1024).
-define(GRAMMAR, "\\A[ \\t]*(?:(resize|move)[ \\t]+-r[ \\t]+(-?[0-9]+)[ \\t]+(-?[0-9]+)"
                 "[ \\t]+(-?[0-9]+)[ \\t]+(-?[0-9]+)|(hide|show|top|bottom))[ \\t]*\\n?\\z").

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    {ok, Grammar} = re:compile(?GRAMMAR),
    lists:foreach(fun(_) ->
                          round_of(random_bytes(), Grammar),
                          round_of(valid_line(), Grammar),
                          round_of(padded(valid_line()), Grammar),
                          round_of(mutated(valid_line()), Grammar)
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

round_of(Bytes, Grammar) ->
    Said = try erx_wctl:parse(Bytes)
           catch Class:Reason:Stack -> error({raised, Bytes, Class, Reason, Stack})
           end,
    case Said =:= reference(Bytes, Grammar) of
        true -> ok;
        false -> error({disagrees_with_reference, Bytes, Said, reference(Bytes, Grammar)})
    end.

%% The reference: the line bound, then the whole line against the grammar,
%% then each coordinate against draw(3)'s 32-bit range.
reference(Bytes, _Grammar) when byte_size(Bytes) > ?MAX_LINE ->
    {error, einval};
reference(Bytes, Grammar) ->
    case re:run(Bytes, Grammar, [{capture, all_but_first, binary}]) of
        {match, [Verb, A, B, C, D]} ->
            Coords = [binary_to_integer(N) || N <- [A, B, C, D]],
            case lists:all(fun(N) -> N >= -(1 bsl 31) andalso N < 1 bsl 31 end, Coords) of
                true -> {ok, {binary_to_atom(Verb), list_to_tuple(Coords)}};
                false -> {error, einval}
            end;
        {match, [<<>>, <<>>, <<>>, <<>>, <<>>, Word]} ->
            {ok, binary_to_atom(Word)};
        nomatch ->
            {error, einval}
    end.

random_bytes() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(160) - 1) >>.

valid_line() ->
    Words = case rand:uniform(3) of
                1 -> [pick([<<"hide">>, <<"show">>, <<"top">>, <<"bottom">>])];
                _ -> [pick([<<"resize">>, <<"move">>]), <<"-r">> | [coordinate() || _ <- [1, 2, 3, 4]]]
            end,
    Gaps = [space() || _ <- tl(Words)] ++ [pick([<<>>, space()])],
    Line = iolist_to_binary([pick([<<>>, space()]),
                             lists:zipwith(fun(W, G) -> [W, G] end, Words, Gaps)]),
    case rand:uniform(2) of
        1 -> <<Line/binary, "\n">>;
        2 -> Line
    end.

%% Spaces to carry a line to either side of the bound.
padded(Line) ->
    Pad = binary:copy(<<" ">>, max(0, ?MAX_LINE - byte_size(Line)) + rand:uniform(5) - 3),
    <<Pad/binary, Line/binary>>.

mutated(Line) ->
    At = rand:uniform(byte_size(Line) + 1) - 1,
    <<Before:At/binary, After/binary>> = Line,
    Byte = pick([$\s, $\t, $\n, $\r, $-, $+, $0, $9, $x, 0, 16#7f, 16#c3, rand:uniform(256) - 1]),
    case {rand:uniform(3), After} of
        {1, _} -> <<Before/binary, Byte, After/binary>>;
        {2, <<_, Rest/binary>>} -> <<Before/binary, Byte, Rest/binary>>;
        {_, <<_, Rest/binary>>} -> <<Before/binary, Rest/binary>>;
        {_, <<>>} -> <<Before/binary, Byte>>
    end.

%% Coordinates near zero, near the 32-bit edges and past them, some with
%% leading zeros.
coordinate() ->
    N = case rand:uniform(4) of
            1 -> rand:uniform(4000) - 2000;
            2 -> (1 bsl 31) - 3 + rand:uniform(5);
            3 -> -(1 bsl 31) - 3 + rand:uniform(5);
            4 -> rand:uniform(1 bsl 40) - (1 bsl 39)
        end,
    Text = integer_to_binary(abs(N)),
    Zeros = binary:copy(<<"0">>, rand:uniform(3) - 1),
    case N < 0 of
        true -> <<"-", Zeros/binary, Text/binary>>;
        false -> <<Zeros/binary, Text/binary>>
    end.

space() ->
    << <<(pick([$\s, $\t]))>> || _ <- lists:seq(1, rand:uniform(3)) >>.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
