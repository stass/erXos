%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_where).
-moduledoc """
The predicates of `where` (docs/design-shell.md, "Pipelines"): a small
grammar of its own, parsed from untrusted text and evaluated over records
by Kleene's three-valued logic, with no evaluation of Erlang.

```text
pred   := term { "or" term }
term   := factor { "and" factor }
factor := "not" factor | "(" pred ")" | FIELD op value
op     := "=" | "!=" | "<" | "<=" | ">" | ">=" | "~"
value  := INTEGER | 'QUOTED STRING' | WORD
```

A WORD is a run of bytes other than blanks, parentheses, quotes and the
operators' characters `=!<>~`; one of digits, with an optional leading
`-`, is an INTEGER; `and`, `or` and `not` are the keywords. A quoted
string is rc's: `''` inside it is one quote.

Bounds. A predicate is at most 4,096 bytes and nests at most 64 levels,
each `(` and each `not` one, so parsing is linear and its recursion is at
most 64 deep. `and` and `or` keep their operands in a list, so a long
chain is not a deep tree. A field name that is not an existing atom names
a field no record has, so parsing makes no atom. An error says what is
wrong and at which byte, never echoing the input.

Evaluation. A predicate is true, false or `undecided`. `not` exchanges
true and false and keeps undecided; `and` is false when any operand is
false, true when all are true, and undecided otherwise; `or` is true when
any is true, false when all are false, and undecided otherwise. A
comparison with a field the record lacks, or whose value is not `ok`, is
undecided, so no status becomes a value (SH3). Two integers compare as
numbers; any other pair compares as text, the field's value as erx_render
prints it against the literal's text as written, byte by byte. `~`
matches the field's text against the literal as an rc pattern
(erx_shell_glob), a WORD's pattern characters live and a quoted string's
literal; a match that would take more than 2^24 steps is undecided.
""".

-export([parse/1, eval/2]).

-export_type([pred/0, truth/0]).

-type truth() :: true | false | undecided.
-type op() :: '=' | '!=' | '<' | '<=' | '>' | '>=' | '~'.
%% A literal keeps its text as written; an integer also keeps its value.
-type literal() :: {integer, integer(), binary()} | {word, binary()} | {quoted, binary()}.
%% A field the predicate names: an atom, or a name that is no atom, which no
%% record has, since a record's fields are atoms.
-type field() :: atom() | {no_atom, binary()}.
-type pred() :: {'or', [pred(), ...]} | {'and', [pred(), ...]} | {'not', pred()}
              | {compare, field(), op(), literal()}.

-define(MAX_SOURCE, 4096).
-define(MAX_DEPTH, 64).
-define(MAX_STEPS, (1 bsl 24)).
-define(IS_BLANK(C), (C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r)).
-define(IS_OP_CHAR(C), (C =:= $= orelse C =:= $! orelse C =:= $< orelse C =:= $> orelse C =:= $~)).

%%% Parsing

-doc "Parses a predicate, or says what is wrong with it.".
-spec parse(binary()) -> {ok, pred()} | {error, binary()}.
parse(Source) when byte_size(Source) > ?MAX_SOURCE ->
    {error, <<"predicate longer than 4096 bytes">>};
parse(Source) when is_binary(Source) ->
    try
        Tokens = lex(Source, 0, []),
        case pred(Tokens, 0) of
            {Pred, [{eof, _}]} -> {ok, Pred};
            {_Pred, [Token | _]} -> fail(<<"unexpected token">>, Token)
        end
    catch
        throw:{?MODULE, Message} -> {error, Message}
    end.

%% Tokens, each with the offset it starts at, ending in `eof`.
lex(<<>>, At, Acc) ->
    lists:reverse([{eof, At} | Acc]);
lex(<<C, Rest/binary>>, At, Acc) when ?IS_BLANK(C) ->
    lex(Rest, At + 1, Acc);
lex(<<"(", Rest/binary>>, At, Acc) -> lex(Rest, At + 1, [{lparen, At} | Acc]);
lex(<<")", Rest/binary>>, At, Acc) -> lex(Rest, At + 1, [{rparen, At} | Acc]);
lex(<<"!=", Rest/binary>>, At, Acc) -> lex(Rest, At + 2, [{op, At, '!='} | Acc]);
lex(<<"<=", Rest/binary>>, At, Acc) -> lex(Rest, At + 2, [{op, At, '<='} | Acc]);
lex(<<">=", Rest/binary>>, At, Acc) -> lex(Rest, At + 2, [{op, At, '>='} | Acc]);
lex(<<"=", Rest/binary>>, At, Acc) -> lex(Rest, At + 1, [{op, At, '='} | Acc]);
lex(<<"<", Rest/binary>>, At, Acc) -> lex(Rest, At + 1, [{op, At, '<'} | Acc]);
lex(<<">", Rest/binary>>, At, Acc) -> lex(Rest, At + 1, [{op, At, '>'} | Acc]);
lex(<<"~", Rest/binary>>, At, Acc) -> lex(Rest, At + 1, [{op, At, '~'} | Acc]);
lex(<<"!", _/binary>>, At, _Acc) -> fail(<<"`!` without `=`">>, At);
lex(<<"'", Rest/binary>>, At, Acc) ->
    {Text, After, Used} = quoted(Rest, At, []),
    lex(After, At + Used, [{quoted, At, Text} | Acc]);
lex(Source, At, Acc) ->
    Size = word_size(Source, 0),
    <<Word:Size/binary, Rest/binary>> = Source,
    lex(Rest, At + Size, [word(Word, At) | Acc]).

%% A quoted string's text, what follows it and how many bytes it took with
%% its quotes.
quoted(Source, At, Acc) -> quoted(Source, At, 1, Acc).

quoted(<<"''", Rest/binary>>, At, Used, Acc) -> quoted(Rest, At, Used + 2, [$' | Acc]);
quoted(<<"'", Rest/binary>>, _At, Used, Acc) ->
    {list_to_binary(lists:reverse(Acc)), Rest, Used + 1};
quoted(<<C, Rest/binary>>, At, Used, Acc) -> quoted(Rest, At, Used + 1, [C | Acc]);
quoted(<<>>, At, _Used, _Acc) -> fail(<<"unterminated quote">>, At).

word_size(<<C, _/binary>>, Size) when ?IS_BLANK(C); ?IS_OP_CHAR(C); C =:= $(; C =:= $); C =:= $' ->
    Size;
word_size(<<_, Rest/binary>>, Size) -> word_size(Rest, Size + 1);
word_size(<<>>, Size) -> Size.

word(<<"and">>, At) -> {'and', At};
word(<<"or">>, At) -> {'or', At};
word(<<"not">>, At) -> {'not', At};
word(Word, At) ->
    case is_integer_text(Word) of
        true -> {integer, At, binary_to_integer(Word), Word};
        false -> {word, At, Word}
    end.

is_integer_text(<<"-", Digits/binary>>) -> is_digits(Digits);
is_integer_text(Digits) -> is_digits(Digits).

is_digits(<<>>) -> false;
is_digits(Digits) -> lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)).

%% pred := term { "or" term }
pred(Tokens, Depth) ->
    {First, Rest} = term(Tokens, Depth),
    case alternatives(Rest, Depth, [First]) of
        {[Only], After} -> {Only, After};
        {Terms, After} -> {{'or', Terms}, After}
    end.

alternatives([{'or', _} | Tokens], Depth, Acc) ->
    {Term, Rest} = term(Tokens, Depth),
    alternatives(Rest, Depth, [Term | Acc]);
alternatives(Tokens, _Depth, Acc) ->
    {lists:reverse(Acc), Tokens}.

%% term := factor { "and" factor }
term(Tokens, Depth) ->
    {First, Rest} = factor(Tokens, Depth),
    case conjuncts(Rest, Depth, [First]) of
        {[Only], After} -> {Only, After};
        {Factors, After} -> {{'and', Factors}, After}
    end.

conjuncts([{'and', _} | Tokens], Depth, Acc) ->
    {Factor, Rest} = factor(Tokens, Depth),
    conjuncts(Rest, Depth, [Factor | Acc]);
conjuncts(Tokens, _Depth, Acc) ->
    {lists:reverse(Acc), Tokens}.

%% factor := "not" factor | "(" pred ")" | FIELD op value
factor([{'not', At} | Tokens], Depth) ->
    {Factor, Rest} = factor(Tokens, enter(Depth, At)),
    {{'not', Factor}, Rest};
factor([{lparen, At} | Tokens], Depth) ->
    case pred(Tokens, enter(Depth, At)) of
        {Pred, [{rparen, _} | Rest]} -> {Pred, Rest};
        {_Pred, [Token | _]} -> fail(<<"expected `)`">>, Token)
    end;
factor([{word, _, Name}, {op, _, Op} | Tokens], _Depth) ->
    {Literal, Rest} = literal(Tokens),
    {{compare, field(Name), Op, Literal}, Rest};
factor([{word, _, _}, Token | _], _Depth) ->
    fail(<<"expected an operator">>, Token);
factor([Token | _], _Depth) ->
    fail(<<"expected a field, `not` or `(`">>, Token).

literal([{integer, _, Value, Text} | Rest]) -> {{integer, Value, Text}, Rest};
literal([{word, _, Text} | Rest]) -> {{word, Text}, Rest};
literal([{quoted, _, Text} | Rest]) -> {{quoted, Text}, Rest};
literal([Token | _]) -> fail(<<"expected a value">>, Token).

enter(Depth, At) when Depth >= ?MAX_DEPTH -> fail(<<"nested deeper than 64 levels">>, At);
enter(Depth, _At) -> Depth + 1.

%% No record has a field whose name is no atom, so none is made for it.
field(Name) ->
    try binary_to_existing_atom(Name) catch error:badarg -> {no_atom, Name} end.

%% Fails at an offset, or at a token's: every token holds its offset second.
-spec fail(binary(), tuple() | non_neg_integer()) -> no_return().
fail(What, At) when is_integer(At) ->
    throw({?MODULE, iolist_to_binary([What, <<" at byte ">>, integer_to_binary(At + 1)])});
fail(What, Token) ->
    fail(What, element(2, Token)).

%%% Evaluation

-doc "Whether a record satisfies the predicate: true, false or undecided.".
-spec eval(pred(), #{atom() => erx_render:attr()}) -> truth().
eval({'not', Pred}, Record) ->
    case eval(Pred, Record) of
        true -> false;
        false -> true;
        undecided -> undecided
    end;
eval({'and', Preds}, Record) -> all(Preds, Record, true);
eval({'or', Preds}, Record) -> any(Preds, Record, false);
eval({compare, Field, Op, Literal}, Record) ->
    case maps:find(Field, Record) of
        {ok, {_Reporter, {ok, _}} = Attr} -> compare(Op, Attr, Literal);
        _NotOk -> undecided
    end.

%% `and` over its operands: false as soon as one is false.
all([], _Record, Truth) -> Truth;
all([Pred | Preds], Record, Truth) ->
    case eval(Pred, Record) of
        false -> false;
        true -> all(Preds, Record, Truth);
        undecided -> all(Preds, Record, undecided)
    end.

%% `or` over its operands: true as soon as one is true.
any([], _Record, Truth) -> Truth;
any([Pred | Preds], Record, Truth) ->
    case eval(Pred, Record) of
        true -> true;
        false -> any(Preds, Record, Truth);
        undecided -> any(Preds, Record, undecided)
    end.

compare('~', Attr, Literal) ->
    case erx_shell_glob:match(erx_render:value(Attr), pattern(Literal), ?MAX_STEPS) of
        too_many_steps -> undecided;
        Matched -> Matched
    end;
compare(Op, {_Reporter, {ok, Value}}, {integer, Number, _Text}) when is_integer(Value) ->
    order(Op, Value, Number);
compare(Op, Attr, Literal) ->
    order(Op, erx_render:value(Attr), text(Literal)).

order('=', A, B) -> A == B;
order('!=', A, B) -> A /= B;
order('<', A, B) -> A < B;
order('<=', A, B) -> A =< B;
order('>', A, B) -> A > B;
order('>=', A, B) -> A >= B.

text({integer, _Value, Text}) -> Text;
text({word, Text}) -> Text;
text({quoted, Text}) -> Text.

pattern({quoted, Text}) -> [{lit, Text}];
pattern(Literal) -> [{src, text(Literal)}].
