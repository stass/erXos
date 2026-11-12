%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random argument lists through erx_mini_uart:console_uart/1. Whatever arrives, it returns
%% {ok, Spec} or {error, {Atom, Text}}, and what it says agrees with reference/1, a reader
%% that shares no code with it: it finds entries by filtering and numbers by a regular
%% expression. The words come from a small alphabet of console_uart, digits near the field
%% bounds, signs, spaces and other characters, so duplicates, short entries and bad numbers
%% are common. The mini UART's entry carries no clock, so only a clock of 0 parses. The seed comes from make check-fuzz.

-module(erx_mini_uart_console_uart_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MAX_ENTRIES, 4).
-define(MAX_WORDS, 6).
%% The fewest rounds that must parse, so an edit to the generator cannot leave the accepting
%% path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 100).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of(arguments()) =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of(Arguments) ->
    Said = erx_mini_uart:console_uart(Arguments),
    case Said of
        {ok, #{}} -> ok;
        {error, {Reason, Text}} when is_atom(Reason), is_list(Text) -> ok
    end,
    case verdict(Said) =:= reference(Arguments) of
        true when element(1, Said) =:= ok -> accepted;
        true -> refused;
        false -> error({disagrees_with_reference, Arguments, Said})
    end.

verdict({ok, Spec}) -> {ok, Spec};
verdict({error, {Reason, _Text}}) -> {error, Reason}.

reference(Arguments) ->
    case lists:filter(fun(["console_uart" | _]) -> true; (_) -> false end, Arguments) of
        [] ->
            {error, no_console_uart};
        [["console_uart", Base, Size, Line, Clock | _]] ->
            case {decimal(Base, 16#ffffffffffffffff), decimal(Size, 16#ffffffffffffffff),
                  decimal(Line, 16#ffffffff), decimal(Clock, 16#ffffffff)} of
                {B, S, L, 0} when is_integer(B), is_integer(S), is_integer(L) ->
                    {ok, #{peripheral => mini_uart, window => {physical, B, S}, lines => [L]}};
                _ ->
                    {error, bad_console_uart}
            end;
        _ ->
            {error, bad_console_uart}
    end.

%% Digits only, and no more of them than Max has.
decimal(Word, Max) ->
    Digits = integer_to_list(length(integer_to_list(Max))),
    case re:run(Word, "\\A[0-9]{1," ++ Digits ++ "}\\z", [unicode, {capture, none}]) of
        match ->
            case list_to_integer(Word) of
                Value when Value =< Max -> Value;
                _ -> bad
            end;
        nomatch ->
            bad
    end.

arguments() ->
    [entry() || _ <- lists:seq(1, rand:uniform(?MAX_ENTRIES + 1) - 1)].

%% A third of the entries start with four number words, some within their fields and some
%% just past them, so the accepting path and the field bounds are reached often.
entry() ->
    Words = [word() || _ <- lists:seq(1, rand:uniform(?MAX_WORDS + 1) - 1)],
    case rand:uniform(3) of
        1 -> ["console_uart" | Words];
        2 -> Words;
        3 -> ["console_uart", number(), number(), number(), number() | Words]
    end.

number() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick(["0", "0", "0", "33", "4096", "4294967295", "4294967296", "18446744073709551615",
          "18446744073709551616", integer_to_list(rand:uniform(1 bsl 32) - 1)]).

word() ->
    Pick = fun(List) -> lists:nth(rand:uniform(length(List)), List) end,
    Pick([Pick(["0", "1", "33", "4096", "150994944", "4294967295", "4294967296",
                "18446744073709551615", "18446744073709551616", "018446744073709551615"]),
          integer_to_list(rand:uniform(1 bsl 70) - 1),
          Pick(["", "-1", "+1", " 1", "1 ", "1\n", "0x10", "1e3", "x", "console_uart", "debug"]),
          [Pick([$0, $9, $a, $-, $\s, 16#661, 16#ff10]) || _ <- lists:seq(1, rand:uniform(24))]]).
