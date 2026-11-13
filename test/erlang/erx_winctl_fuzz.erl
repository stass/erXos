%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random writes through erx_winctl:parse/1, the parser of a present written
%% to a window's ctl file, whose bytes come from a client. Whatever arrives,
%% it returns `{ok, Present}` or `{error, einval}` and never raises, and what
%% it says agrees with reference/1, a reader of the same grammar written as one
%% regular expression with the bounds, the rectangles' form and the clipping
%% checked apart, which shares no code with the parser. The inputs are random
%% bytes, valid lines with random white space, sizes near 1 and 16,384, offsets
%% near 2^63, coordinates near the 32-bit edges and from 14 to 18 rectangles,
%% lines padded across the 1,024-byte bound, and valid lines with a byte
%% changed, inserted or removed. The seed comes from make check-fuzz.

-module(erx_winctl_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MAX_LINE, 1024).
-define(GRAMMAR, "\\A[ \\t]*present[ \\t]+([0-9]+)[ \\t]+([0-9]+)[ \\t]+([0-9]+)"
                 "((?:[ \\t]+-?[0-9]+)*)[ \\t]*\\n?\\z").

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
    Said = try erx_winctl:parse(Bytes)
           catch Class:Reason:Stack -> error({raised, Bytes, Class, Reason, Stack})
           end,
    case Said =:= reference(Bytes, Grammar) of
        true -> ok;
        false -> error({disagrees_with_reference, Bytes, Said, reference(Bytes, Grammar)})
    end.

%% The reference: the line bound, then the whole line against the grammar,
%% then the numbers' digits and ranges, the count and form of the rectangles, and each
%% rectangle clipped to the buffer.
reference(Bytes, _Grammar) when byte_size(Bytes) > ?MAX_LINE ->
    {error, einval};
reference(Bytes, Grammar) ->
    case re:run(Bytes, Grammar, [{capture, all_but_first, binary}]) of
        {match, [O, W, H, Rest]} ->
            [Offset, Width, Height] = [binary_to_integer(N) || N <- [O, W, H]],
            Coords = [binary_to_integer(N) || N <- binary:split(Rest, [<<" ">>, <<"\t">>], [global, trim_all])],
            Sized = re:run(Bytes, "[0-9]{20}") =:= nomatch andalso Offset < 1 bsl 63 andalso lists:all(fun(N) -> N >= 1 andalso N =< 16384 end, [Width, Height]),
            Ranged = lists:all(fun(N) -> N >= -(1 bsl 31) andalso N < 1 bsl 31 end, Coords),
            Rects = quads(Coords),
            Formed = Rects =/= error andalso length(Rects) =< 16 andalso
                lists:all(fun({X0, Y0, X1, Y1}) -> X0 =< X1 andalso Y0 =< Y1 end, Rects),
            case Sized andalso Ranged andalso Formed of
                true -> {ok, #{offset => Offset, width => Width, height => Height,
                               rects => clipped(Rects, Width, Height)}};
                false -> {error, einval}
            end;
        nomatch ->
            {error, einval}
    end.

quads([]) -> [];
quads([A, B, C, D | Rest]) ->
    case quads(Rest) of
        error -> error;
        Quads -> [{A, B, C, D} | Quads]
    end;
quads(_) -> error.

clipped([], Width, Height) ->
    [{0, 0, Width, Height}];
clipped(Rects, Width, Height) ->
    [{X0, Y0, X1, Y1} || {AX0, AY0, AX1, AY1} <- Rects,
                         X0 <- [max(0, AX0)], Y0 <- [max(0, AY0)],
                         X1 <- [min(Width, AX1)], Y1 <- [min(Height, AY1)],
                         X0 < X1, Y0 < Y1].

random_bytes() ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, rand:uniform(160) - 1) >>.

valid_line() ->
    Rects = case rand:uniform(4) of
                1 -> [];
                2 -> [rectangle(well_formed) || _ <- lists:seq(1, 13 + rand:uniform(5))];
                _ -> [rectangle(pick([well_formed, any])) || _ <- lists:seq(1, rand:uniform(4))]
            end,
    Words = [<<"present">>, offset(), size(), size() | lists:append(Rects)],
    Gaps = [space() || _ <- tl(Words)] ++ [pick([<<>>, space()])],
    Line = iolist_to_binary([pick([<<>>, space()]),
                             lists:zipwith(fun(Word, Gap) -> [Word, Gap] end, Words, Gaps)]),
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

offset() ->
    N = case rand:uniform(3) of
            1 -> 4096 * (rand:uniform(64) - 1);
            2 -> (1 bsl 63) - 3 + rand:uniform(5);
            3 -> rand:uniform(1 bsl 70)
        end,
    zeros(integer_to_binary(N)).

%% Sizes near the ends of 1 to 16,384, and past them.
size() ->
    N = case rand:uniform(3) of
            1 -> rand:uniform(3) - 1;
            2 -> 16384 - 2 + rand:uniform(3);
            3 -> rand:uniform(64)
        end,
    zeros(integer_to_binary(N)).

%% A rectangle's four words: a well-formed one of small coordinates, so that
%% lines of many rectangles reach the count bound and rectangles fall inside,
%% across and outside a small buffer, or four coordinates of any kind.
rectangle(well_formed) ->
    [X0, X1] = lists:sort([rand:uniform(80) - 20 || _ <- [1, 2]]),
    [Y0, Y1] = lists:sort([rand:uniform(80) - 20 || _ <- [1, 2]]),
    [decimal(N) || N <- [X0, Y0, X1, Y1]];
rectangle(any) ->
    [coordinate() || _ <- [1, 2, 3, 4]].

%% Coordinates near zero, near the 32-bit edges and past them.
coordinate() ->
    N = case rand:uniform(4) of
            1 -> rand:uniform(80) - 20;
            2 -> (1 bsl 31) - 3 + rand:uniform(5);
            3 -> -(1 bsl 31) - 3 + rand:uniform(5);
            4 -> rand:uniform(1 bsl 40) - (1 bsl 39)
        end,
    decimal(N).

decimal(N) ->
    Text = zeros(integer_to_binary(abs(N))),
    case N < 0 of
        true -> <<"-", Text/binary>>;
        false -> Text
    end.

zeros(Digits) ->
    Pad = case rand:uniform(8) of
              1 -> max(0, 18 - byte_size(Digits) + rand:uniform(2));
              _ -> rand:uniform(3) - 1
          end,
    <<(binary:copy(<<"0">>, Pad))/binary, Digits/binary>>.

space() ->
    << <<(pick([$\s, $\t]))>> || _ <- lists:seq(1, rand:uniform(3)) >>.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
