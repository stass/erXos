%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_grep_re_fuzz).
-moduledoc """
The fuzz target of grep's pattern translator, erx_grep_re
(docs/design-shell.md, "Text commands"): a program can hand `grep` its
pattern, so the translator reads untrusted input. tools/fuzz/erx_grep_re.rb
runs it.

For random soups of POSIX syntax, mutations of them and patterns at the
4 KiB bound, in each syntax, translate/2 must answer `{ok, Source}` or
`{error, Message}` and never crash; every source must compile in `re`
with the translator's options, or be longer or nest deeper than `re`
compiles, which grep refuses as too big; every backslash in it must
begin one of the translator's own escapes; hold no `(*` (an `re` start-of-pattern
option such as `(*UTF)`) and be ASCII; and the bound must hold both
ways: 4096 bytes are taken, 4097 refused. A failure prints a marker
naming the property and the pattern, and the run ends with `fuzz: N
inputs ok` only when every input held.
""".

-export([run/1]).

-define(INPUTS, 20000).
-define(BOUND, 4096).

run([Seed]) ->
    rand:seed(exsss, {list_to_integer(Seed), 7, 11}),
    Inputs = bounds() ++ [input() || _ <- lists:seq(1, ?INPUTS)],
    Failures = lists:append([check(Pattern, Syntax) || Pattern <- Inputs, Syntax <- [bre, ere, fixed]]),
    case Failures of
        [] ->
            io:format("fuzz: ~b inputs ok~n", [length(Inputs) * 3]);
        _ ->
            [io:format("~s ~p ~p~n", [Marker, Syntax, Pattern]) || {Marker, Syntax, Pattern} <- lists:sublist(Failures, 20)],
            io:format("fuzz: ~b failures~n", [length(Failures)])
    end.

bounds() ->
    [binary:copy(<<"a">>, ?BOUND), binary:copy(<<"a">>, ?BOUND + 1),
     binary:copy(<<"(">>, 70), binary:copy(<<"\\(">>, 70), binary:copy(<<"a*">>, 70),
     binary:copy(<<"[[:alpha:]]{9}">>, 200)].

input() ->
    case rand:uniform(3) of
        1 -> soup();
        2 -> mutate(soup());
        3 -> nested()
    end.

soup() -> iolist_to_binary([fragment() || _ <- lists:seq(1, rand:uniform(24))]).

fragment() ->
    pick([<<"a">>, <<"Z">>, <<"0">>, <<".">>, <<"*">>, <<"+">>, <<"?">>, <<"|">>, <<"^">>, <<"$">>,
          <<"(">>, <<")">>, <<"[">>, <<"]">>, <<"{">>, <<"}">>, <<",">>, <<"-">>, <<"\\">>,
          <<"\\(">>, <<"\\)">>, <<"\\{">>, <<"\\}">>, <<"\\|">>, <<"\\1">>, <<"\\9">>, <<"\\w">>,
          <<"\\d">>, <<"\\<">>, <<"\\b">>, <<"[:alpha:]">>, <<"[=a=]">>, <<"[.-.]">>, <<"[^">>,
          <<"{2,3}">>, <<"{,}">>, <<"{256}">>, <<"\\{1,\\}">>, <<"(*UTF)">>, <<"(?">>, <<"\\Q">>,
          <<"\\E">>, <<"\\x41">>, <<"\\p{L}">>, <<"\\K">>, <<"\n">>, <<0>>, <<255>>, <<16#C3, 16#A9>>,
          <<"#">>, <<" ">>, <<"\\\\">>]).

mutate(<<>>) -> fragment();
mutate(Pattern) ->
    At = rand:uniform(byte_size(Pattern)) - 1,
    <<Before:At/binary, _, After/binary>> = Pattern,
    <<Before/binary, (rand:uniform(256) - 1), After/binary>>.

nested() ->
    Depth = 60 + rand:uniform(10),
    {Open, Close} = pick([{<<"(">>, <<")*">>}, {<<"\\(">>, <<"\\)*">>}]),
    iolist_to_binary([binary:copy(Open, Depth), <<"a">>, binary:copy(Close, Depth)]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

check(Pattern, Syntax) ->
    try erx_grep_re:translate(Pattern, Syntax) of
        {ok, _} when byte_size(Pattern) > ?BOUND -> [{over_size_accepted, Syntax, Pattern}];
        {error, _} when Syntax =:= fixed, byte_size(Pattern) =< ?BOUND -> [{fixed_refused, Syntax, Pattern}];
        {ok, Source} -> source(Source, Pattern, Syntax);
        {error, Message} when is_binary(Message) -> [];
        Other -> [{bad_answer, Syntax, {Pattern, Other}}]
    catch
        Class:Reason -> [{crashed, Syntax, {Pattern, Class, Reason}}]
    end.

source(Source, Pattern, Syntax) ->
    Options = erx_grep_re:options(#{ignore_case => rand:uniform(2) =:= 1}),
    [{Marker, Syntax, Pattern}
     || {Marker, false} <- [{compile_failed, compiles(Source, Options)},
                            {start_option, binary:match(Source, <<"(*">>) =:= nomatch},
                            {raw_escape, re:run(Source, <<"\\\\[^xgbBwAz]|\\\\$">>) =:= nomatch},
                            {not_ascii, lists:all(fun(C) -> C < 128 end, binary_to_list(Source))}]].

%% A source compiles, or is longer or nests deeper than `re` compiles,
%% which grep refuses as too big; any other refusal by `re` is a translator fault.
compiles(Source, Options) ->
    case re:compile(Source, Options) of
        {ok, _} -> true;
        {error, {Message, _At}} ->
            string:find(Message, "too large") =/= nomatch orelse string:find(Message, "too deeply nested") =/= nomatch
    end.
