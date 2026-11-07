%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of `where`'s predicates, erx_shell_where (docs/design-shell.md,
%% "Pipelines" and "Verification and testing"). Inputs come from three sources:
%% soups of the grammar's fragments and random bytes; mutations of valid
%% predicates; and nestings of `(` and `not` at a chosen number of levels near
%% 64, with predicates at and just over the 4,096-byte bound. Every input must
%% parse or fail with a diagnostic, never raise. A diagnostic must say what is
%% wrong at a byte inside the input, or one past its end, in printable ASCII,
%% and only an input over 4,096 bytes may be refused for its length, as every
%% such input must be. A tree must have every node in the shape the module's
%% types give, and printed back to the grammar by a printer of its own it must
%% parse to itself. A nesting of N levels must parse when N is at most 64 and
%% fail as nested too deep when it is more. Each tree is evaluated over random
%% records and must agree with an evaluator of this module's own, written from
%% the design's rules; over a record whose every value is not `ok`, every
%% predicate is undecided (SH3). Since that evaluator and the printer read the
%% parser's own trees, a fourth source checks the parser's structure on its
%% own: random trees, printed and parsed, must parse to the tree they came
%% from, so a parser that binds `not`, `and` or `or` wrongly is caught. The
%% seed comes from make check-fuzz.

-module(erx_shell_where_fuzz).
-export([run/1]).

-define(SOUPS, 60000).
-define(MUTATIONS, 60000).
-define(NESTINGS, 400).
-define(TREES, 20000).
-define(MAX_SOURCE, 4096).
-define(MAX_DEPTH, 64).

-define(FRAGMENTS,
        [<<"n">>, <<"name">>, <<"line">>, <<"memory">>, <<"absent">>, <<" ">>, <<" ">>,
         <<"\t">>, <<"\n">>, <<"(">>, <<")">>, <<"and">>, <<" and ">>, <<" or ">>,
         <<"not ">>, <<"=">>, <<"!=">>, <<"<">>, <<"<=">>, <<">">>, <<">=">>, <<"~">>,
         <<"!">>, <<"'">>, <<"''">>, <<"'q r'">>, <<"0">>, <<"10">>, <<"-3">>, <<"-">>,
         <<"9">>, <<"*">>, <<"?">>, <<"[a-z]">>, <<"[~0]">>, <<"[">>, <<"]">>, <<"abc">>,
         <<"\e[2J">>, <<16#c3, 16#a9>>, <<16#ff>>, <<0>>]).

-define(CORPUS,
        [<<"memory > 10000000">>, <<"name = init and n != 3">>,
         <<"line ~ *error*">>, <<"not (n < 9 or n >= '9') and name ~ 'a*'">>,
         <<"(name = x or name = y) and not memory <= -1">>, <<"n = 'it''s'">>,
         <<"absent ~ [a-c]?* or line = abc">>]).

%% The fields the generated records may hold, and values of each kind.
-define(FIELDS, [n, name, line, memory]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Counts0 = #{ok => 0, error => 0},
    Counts1 = repeat(?SOUPS, fun soup/0, Counts0),
    Counts2 = repeat(?MUTATIONS, fun mutation/0, Counts1),
    Counts3 = repeat(?NESTINGS, fun nesting/0, Counts2),
    Counts4 = lists:foldl(fun(Source, Acc) -> count(check(Source), Acc) end, Counts3, bounds()),
    Counts5 = repeat(?TREES, fun() -> {tree, tree(rand:uniform(5))} end, Counts4),
    io:format("results: ~p~n", [Counts5]),
    case Counts5 of
        #{ok := Ok, error := Error} when Ok >= 2000, Error >= 2000 -> ok;
        _ -> error({one_sided, Counts5})
    end,
    io:format("fuzz: ~p inputs ok~n", [maps:get(ok, Counts5) + maps:get(error, Counts5)]).

%% A tree of at most Depth levels in the parser's shape: `and` and `or` of
%% two or more operands.
tree(0) -> comparison();
tree(Depth) ->
    Operands = fun() -> [tree(Depth - 1) || _ <- lists:seq(1, 1 + rand:uniform(3))] end,
    case rand:uniform(4) of
        1 -> comparison();
        2 -> {'not', tree(Depth - 1)};
        3 -> {'and', Operands()};
        4 -> {'or', Operands()}
    end.

comparison() ->
    {compare, pick(?FIELDS), pick(['=', '!=', '<', '<=', '>', '>=', '~']),
     pick([{integer, 10, <<"10">>}, {integer, -3, <<"-3">>}, {integer, 7, <<"007">>},
           {word, <<"abc">>}, {word, <<"*e*">>}, {quoted, <<"it's">>}, {quoted, <<>>},
           {quoted, <<"a b">>}, {quoted, <<"and">>}])}.

repeat(0, _Generate, Counts) -> Counts;
repeat(N, Generate, Counts) -> repeat(N - 1, Generate, count(check(Generate()), Counts)).

count(Result, Counts) -> maps:update_with(Result, fun(N) -> N + 1 end, Counts).

%%% Generators

soup() -> iolist_to_binary([fragment() || _ <- lists:seq(1, rand:uniform(30))]).

fragment() ->
    case rand:uniform(10) of
        1 -> <<(rand:uniform(256) - 1)>>;
        _ -> pick(?FRAGMENTS)
    end.

mutation() ->
    lists:foldl(fun(_, S) -> mutate(S) end, pick(?CORPUS), lists:seq(1, rand:uniform(3))).

mutate(<<>>) -> fragment();
mutate(Source) ->
    At = rand:uniform(byte_size(Source)) - 1,
    <<Before:At/binary, After/binary>> = Source,
    case rand:uniform(4) of
        1 -> <<Before/binary, (fragment())/binary, After/binary>>;
        2 -> <<Before/binary, (drop(After))/binary>>;
        3 -> <<Before/binary, (rand:uniform(256) - 1), (drop(After))/binary>>;
        4 -> <<Before/binary, Before/binary, After/binary>>
    end.

drop(<<>>) -> <<>>;
drop(Bytes) -> binary_part(Bytes, 1, byte_size(Bytes) - 1).

%% N levels of `(` and `not`, mixed at random, around a predicate of none.
nesting() -> nesting(?MAX_DEPTH - 3 + rand:uniform(6)).

nesting(Levels) ->
    Openers = [pick([paren, 'not']) || _ <- lists:seq(1, Levels)],
    Open = [case O of paren -> <<"(">>; 'not' -> <<"not ">> end || O <- Openers],
    Close = [<<")">> || paren <- Openers],
    Flat = pick([<<"n = 1">>, <<"name = x or n != 3 and line ~ *e*">>, <<"memory > 10000000">>]),
    {nesting, Levels, iolist_to_binary([Open, Flat, Close])}.

%% Predicates at and just over the bound, and nestings at and over 64.
bounds() ->
    At = iolist_to_binary([<<"n = '">>, binary:copy(<<"x">>, ?MAX_SOURCE - 6), $']),
    Over = <<At/binary, " ">>,
    Chain = iolist_to_binary(lists:join(<<" or ">>, lists:duplicate(700, <<"n=1">>))),
    [At, Over, Chain, binary:part(Chain, 0, ?MAX_SOURCE)]
        ++ [{nesting, N, iolist_to_binary([lists:duplicate(N, $(), <<"n=1">>, lists:duplicate(N, $))])}
            || N <- [?MAX_DEPTH, ?MAX_DEPTH + 1]]
        ++ [{nesting, N, iolist_to_binary([lists:duplicate(N, <<"not ">>), <<"n=1">>])}
            || N <- [?MAX_DEPTH, ?MAX_DEPTH + 1]].

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%%% Checks

check({tree, Tree}) ->
    Source = iolist_to_binary(print(Tree)),
    case byte_size(Source) =< ?MAX_SOURCE andalso catch_parse(Source) of
        false -> ok;
        {ok, Tree} -> evaluations(Tree, Source), ok;
        Other -> fail(generated_round_trip, Source, {Tree, Other})
    end;
check({nesting, Levels, Source}) ->
    Result = check(Source),
    case {Levels =< ?MAX_DEPTH, erx_shell_where:parse(Source)} of
        {true, {ok, _}} -> Result;
        {false, {error, <<"nested deeper than 64 levels", _/binary>>}} -> Result;
        {false, {ok, _}} -> fail(too_deep_accepted, Source, Levels);
        {_, Other} -> fail(wrong_nesting_result, Source, {Levels, Other})
    end;
check(Source) ->
    case catch_parse(Source) of
        {ok, Tree} when byte_size(Source) =< ?MAX_SOURCE ->
            shape(Tree, Source),
            round_trip(Tree, Source),
            evaluations(Tree, Source),
            ok;
        {ok, _Tree} ->
            fail(over_size_accepted, Source, byte_size(Source));
        {error, <<"predicate longer than 4096 bytes">>} when byte_size(Source) > ?MAX_SOURCE ->
            error;
        {error, <<"predicate longer than 4096 bytes">>} ->
            fail(wrong_bound, Source, byte_size(Source));
        {error, Message} when byte_size(Source) > ?MAX_SOURCE ->
            fail(over_size_not_refused, Source, Message);
        {error, Message} ->
            diagnostic(Message, Source),
            error
    end.

catch_parse(Source) ->
    try erx_shell_where:parse(Source)
    catch Class:Reason:Stack -> fail(raised, Source, {Class, Reason, Stack})
    end.

%% `... at byte N`, printable ASCII, with N within the input or one past it.
diagnostic(Message, Source) ->
    Printable = lists:all(fun(C) -> C >= $\s andalso C =< $~ end, binary_to_list(Message)),
    case re:run(Message, <<" at byte ([0-9]+)$">>, [{capture, all_but_first, binary}]) of
        {match, [Digits]} when Printable ->
            At = binary_to_integer(Digits),
            (At >= 1 andalso At =< byte_size(Source) + 1)
                orelse fail(diagnostic_outside_input, Source, Message);
        _ -> fail(bad_diagnostic, Source, Message)
    end.

%% Every node in the shape the types give; `and` and `or` hold two or more.
shape({Kind, [_, _ | _] = Preds}, Source) when Kind =:= 'and'; Kind =:= 'or' ->
    [shape(P, Source) || P <- Preds], ok;
shape({'not', Pred}, Source) -> shape(Pred, Source);
shape({compare, Field, Op, Literal}, Source) ->
    field_shape(Field) andalso lists:member(Op, ['=', '!=', '<', '<=', '>', '>=', '~'])
        andalso literal_shape(Literal) orelse fail(bad_node, Source, {compare, Field, Op, Literal}),
    ok;
shape(Node, Source) -> fail(bad_node, Source, Node).

field_shape(Field) when is_atom(Field) -> true;
field_shape({no_atom, Name}) -> is_binary(Name) andalso Name =/= <<>>;
field_shape(_) -> false.

literal_shape({integer, Value, Text}) -> is_integer(Value) andalso binary_to_integer(Text) =:= Value;
literal_shape({word, Text}) -> is_binary(Text) andalso Text =/= <<>>;
literal_shape({quoted, Text}) -> is_binary(Text);
literal_shape(_) -> false.

round_trip(Tree, Source) ->
    Printed = iolist_to_binary(print(Tree)),
    case byte_size(Printed) =< ?MAX_SOURCE andalso erx_shell_where:parse(Printed) of
        false -> ok;
        {ok, Tree} -> ok;
        Other -> fail(round_trip, Source, {Printed, Other})
    end.

%% The printer: an `or` inside an `and`, and anything but a comparison or
%% a `not` under a `not`, in parentheses; nothing else adds a level.
print({'or', Preds}) -> lists:join(<<" or ">>, [alternative(P) || P <- Preds]);
print({'and', Preds}) -> lists:join(<<" and ">>, [operand(P) || P <- Preds]);
print({'not', Pred}) -> [<<"not ">>, operand(Pred)];
print({compare, Field, Op, Literal}) ->
    [field_text(Field), $\s, atom_to_binary(Op), $\s, literal_text(Literal)].

operand({'or', _} = Pred) -> [$(, print(Pred), $)];
operand({'and', _} = Pred) -> [$(, print(Pred), $)];
operand(Pred) -> print(Pred).

%% An `or` inside an `or` keeps its parentheses, or it would flatten.
alternative({'or', _} = Pred) -> [$(, print(Pred), $)];
alternative(Pred) -> print(Pred).

field_text({no_atom, Name}) -> Name;
field_text(Field) -> atom_to_binary(Field).

literal_text({integer, _Value, Text}) -> Text;
literal_text({word, Text}) -> Text;
literal_text({quoted, Text}) -> [$', binary:replace(Text, <<"'">>, <<"''">>, [global]), $'].

%%% Evaluation against a reference

evaluations(Tree, Source) ->
    [evaluation(Tree, record(), Source) || _ <- lists:seq(1, 4)],
    Unknown = maps:from_list([{F, {runtime, unknown}} || F <- ?FIELDS]),
    [case erx_shell_where:eval(Tree, Record) of
         undecided -> ok;
         Other -> fail(status_became_value, Source, {Record, Other})
     end || Record <- [Unknown, #{}]],
    ok.

evaluation(Tree, Record, Source) ->
    Got = try erx_shell_where:eval(Tree, Record)
          catch Class:Reason:Stack -> fail(eval_raised, Source, {Class, Reason, Stack, Record})
          end,
    case reference(Tree, Record) of
        Got -> ok;
        Want -> fail(wrong_truth, Source, {Record, Got, Want})
    end.

record() ->
    maps:from_list([{F, value()} || F <- ?FIELDS, rand:uniform(4) > 1]).

value() ->
    case rand:uniform(8) of
        1 -> {runtime, unknown};
        2 -> {service, {timeout, 500}};
        3 -> {kernel, unsupported};
        4 -> {runtime, {ok, rand:uniform(21) - 11}};
        5 -> {runtime, {ok, 10}};
        6 -> {runtime, {ok, pick([<<"abc">>, <<"x">>, <<"10">>, <<"-3">>, <<"it's">>, <<>>])}};
        7 -> {runtime, {ok, pick([init, abc, 'q r'])}};
        8 -> {runtime, {ok, soup()}}
    end.

%% Kleene's logic and the comparison rules, written from the design.
reference({'not', P}, R) ->
    case reference(P, R) of true -> false; false -> true; undecided -> undecided end;
reference({'and', Ps}, R) ->
    Truths = [reference(P, R) || P <- Ps],
    case {lists:member(false, Truths), lists:all(fun(T) -> T =:= true end, Truths)} of
        {true, _} -> false;
        {false, true} -> true;
        _ -> undecided
    end;
reference({'or', Ps}, R) ->
    Truths = [reference(P, R) || P <- Ps],
    case {lists:member(true, Truths), lists:all(fun(T) -> T =:= false end, Truths)} of
        {true, _} -> true;
        {false, true} -> false;
        _ -> undecided
    end;
reference({compare, Field, Op, Literal}, R) ->
    case maps:get(Field, R, absent) of
        {_, {ok, V}} when Op =:= '~' ->
            Pattern = case Literal of
                          {quoted, T} -> [{lit, T}];
                          _ -> [{src, literal_plain(Literal)}]
                      end,
            erx_shell_glob:match(erx_render:value({runtime, {ok, V}}), Pattern);
        {_, {ok, V}} when is_integer(V), element(1, Literal) =:= integer ->
            holds(Op, V, element(2, Literal));
        {_, {ok, V}} ->
            holds(Op, erx_render:value({runtime, {ok, V}}), literal_plain(Literal));
        _ -> undecided
    end.

literal_plain({integer, _, Text}) -> Text;
literal_plain({word, Text}) -> Text;
literal_plain({quoted, Text}) -> Text.

holds('=', A, B) -> A == B;
holds('!=', A, B) -> A /= B;
holds('<', A, B) -> A < B;
holds('<=', A, B) -> A =< B;
holds('>', A, B) -> A > B;
holds('>=', A, B) -> A >= B.

fail(What, Source, Detail) ->
    io:format("~p on ~P:~n~P~n", [What, Source, 80, Detail, 80]),
    error({What, Source}).
