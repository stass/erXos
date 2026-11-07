%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_glob).
-moduledoc """
rc's pattern matching (docs/design-shell.md, "The language" and
"Pipelines"): `*` matches any text, `?` any one character, `[...]` one
character of a class of characters and ranges and `[~...]` one character
outside it. A pattern is a word's chunks: only characters of `src`
chunks, written unquoted in the source, are pattern characters, and `lit`
characters match themselves. Text is matched by code point where it is
UTF-8 and by byte elsewhere.

The matcher is iterative and keeps one point to backtrack to, the last
`*`, so it takes at most the text's length times the pattern's length in
steps and never deepens the stack. match/3 also bounds the steps, for
`where`'s `~`, whose texts and patterns come from records and users.
""".

-export([match/2, match/3]).

-export_type([pattern/0]).

-type pattern() :: [{lit | src, binary()}].

-doc "Whether Text matches Pattern.".
-spec match(binary(), pattern()) -> boolean().
match(Text, Pattern) ->
    match(Text, Pattern, infinity).

-doc """
Whether Text matches Pattern within MaxSteps steps, or `too_many_steps`
when deciding would take more.
""".
-spec match(binary(), pattern(), pos_integer() | infinity) -> boolean() | too_many_steps.
match(Text, Pattern, MaxSteps) ->
    run(tokens(marked(Pattern)), characters(Text), none, MaxSteps).

%% The pattern's characters, each marked as a pattern character or not.
marked(Pattern) ->
    [{Kind, C} || {Kind, Text} <- Pattern, C <- characters(Text)].

characters(<<>>) -> [];
characters(<<C/utf8, Rest/binary>>) -> [C | characters(Rest)];
characters(<<B, Rest/binary>>) -> [{byte, B} | characters(Rest)].

%% Compiles marked characters into match tokens. A class runs from an
%% unquoted `[` to the next `]`, whatever its characters' quoting, as in
%% rc; a `[` with no `]` after it makes the pattern match nothing, as in
%% rc's glob.c.
tokens([]) -> [];
tokens([{src, $*} | Rest]) -> [star | tokens(Rest)];
tokens([{src, $?} | Rest]) -> [any | tokens(Rest)];
tokens([{src, $[} | Rest]) ->
    {Inside, Members} = case Rest of
                            [{_, $~} | Tail] -> {false, Tail};
                            _ -> {true, Rest}
                        end,
    case ranges(Members, []) of
        {ok, Ranges, After} -> [{class, Inside, Ranges} | tokens(After)];
        unterminated -> [never]
    end;
tokens([{_, C} | Rest]) -> [{char, C} | tokens(Rest)].

%% A class's members up to its `]`, as rc's glob.c reads them: the
%% character after a `-` always ends the range, `]` included, reversed
%% bounds are swapped, and a class with no `]` is malformed and matches
%% nothing.
ranges([{_, $]} | After], Acc) -> {ok, Acc, After};
ranges([{_, Low}, {_, $-}, {_, High} | Rest], Acc) ->
    ranges(Rest, [ordered(Low, High) | Acc]);
ranges([{_, C} | Rest], Acc) -> ranges(Rest, [{C, C} | Acc]);
ranges([], _Acc) -> unterminated.

ordered(Low, High) when is_integer(Low), is_integer(High), High < Low ->
    {High, Low};
ordered(Low, High) -> {Low, High}.

%% One step per token tried, and one more for each member of a class it
%% tests, so the steps count the work. On a mismatch the last star takes
%% one more character and the tokens after it start again.
run(_Tokens, _Chars, _Back, Steps) when Steps =< 0 -> too_many_steps;
run([star | Tokens], Chars, _Back, Steps) -> run(Tokens, Chars, {Tokens, Chars}, tick(Steps, 1));
run([Token | Tokens], [C | Chars], Back, Steps) ->
    case one(Token, C) of
        true -> run(Tokens, Chars, Back, tick(Steps, cost(Token)));
        false -> retry(Back, tick(Steps, cost(Token)))
    end;
run([], [], _Back, _Steps) -> true;
run(_Tokens, _Chars, Back, Steps) -> retry(Back, tick(Steps, 1)).

cost({class, _Inside, Ranges}) -> 1 + length(Ranges);
cost(_Token) -> 1.

%% No integer is greater than an atom, so `infinity =< 0` is false and an
%% unbounded match never runs out.
tick(infinity, _Cost) -> infinity;
tick(Steps, Cost) -> Steps - Cost.

retry({Tokens, [_ | Chars]}, Steps) -> run(Tokens, Chars, {Tokens, Chars}, Steps);
retry(_Back, _Steps) -> false.

one(never, _C) -> false;
one(any, _C) -> true;
one({char, Want}, C) -> Want =:= C;
one({class, Inside, Ranges}, C) ->
    In = lists:any(fun({Low, High}) -> in_range(C, Low, High) end, Ranges),
    In =:= Inside.

in_range(C, Low, High) when is_integer(C), is_integer(Low), is_integer(High) ->
    Low =< C andalso C =< High;
in_range(C, Low, High) -> C =:= Low orelse C =:= High.
