%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_grep_re).
-moduledoc """
The translator from a POSIX regular expression, as `grep` takes one, to
the syntax of OTP's `re` (docs/design-shell.md, "Text commands"). It is a
pure function: translate/2 answers the `re` source or refuses the pattern
with the message FreeBSD's regerror(3) gives for it, so `re` never reads
POSIX syntax as its own and every pattern either means what it means on
FreeBSD or is refused with status 2.

The patterns are FreeBSD 15.1's, as its `grep` compiles them with
libregex (lib/libc/regex/regcomp.c with its GNU extensions):

* basic (`bre`): `\(` `\)` group, `\{m,n\}`, `\+` and `\?` repeat, `*`
  repeats except where it starts an expression, `\|` separates
  alternatives, `^` and `$`
  anchor only at the ends of an expression, and `+ ? | ( ) {` are
  ordinary;
* extended (`ere`): `( ) | * + ? {m,n}` are operators, `^` and `$`
  anchor anywhere, and a repeat with nothing to repeat is refused;
* both: `.`, bracket expressions with ranges, `[:class:]`, `[=c=]` and
  `[.c.]`; the GNU escapes `\w \W \s \S \b \B \< \>` and back-references
  `\1` to `\9`; an escaped letter that is none of these is refused, and
  any other escaped character is itself;
* fixed (`fixed`): every byte is itself.

Every literal byte is written as `\xHH` unless it is a letter or digit,
so no byte of a pattern reaches `re` as an operator. A repeat after a
repeat is refused, as FreeBSD's regcomp() refuses it, so every repeat
follows a single `re` item and none reads as `re`'s lazy or possessive
forms. The result is compiled in byte mode with
`dotall` and `dollar_endonly` (options/1). A pattern is at most 4 KiB,
nests groups at most 64 deep, so the parser's recursion stays small; a deeper pattern is refused
as too big, where FreeBSD's would compile, and so is a source `re` will
not compile, too long or nested too deep (erx_cmd_grep:compile/2).
""".

-export([translate/2, options/1]).

-export_type([syntax/0]).

-type syntax() :: bre | ere | fixed.

-define(MAX_PATTERN, 4096).
-define(MAX_DEPTH, 64).
-define(MAX_REPEAT, 255).

%% The parser's state: the syntax, the groups opened and those closed (a
%% back-reference may name only a closed one), and the current depth.
-record(p, {syntax :: bre | ere, opened = 0 :: non_neg_integer(),
            closed = [] :: [pos_integer()], depth = 0 :: non_neg_integer()}).

-doc """
The `re` source of a pattern, or the reason it is refused, in
regerror(3)'s words.
""".
-spec translate(binary(), syntax()) -> {ok, binary()} | {error, binary()}.
translate(Pattern, _Syntax) when byte_size(Pattern) > ?MAX_PATTERN ->
    {error, <<"regular expression too big">>};
translate(Pattern, fixed) ->
    {ok, iolist_to_binary([literal(C) || <<C>> <= Pattern])};
translate(Pattern, Syntax) when Syntax =:= bre; Syntax =:= ere ->
    try alternatives(Pattern, #p{syntax = Syntax}) of
        {Source, <<>>, _P} -> {ok, iolist_to_binary(Source)};
        {_Source, _Rest, _P} -> {error, <<"parentheses not balanced">>}
    catch
        throw:{refused, Message} -> {error, Message}
    end.

-doc "The `re:compile/2` options a translated pattern is compiled with.".
-spec options(#{ignore_case := boolean()}) -> [atom()].
options(#{ignore_case := true}) -> [caseless | options(#{ignore_case => false})];
options(#{ignore_case := false}) -> [dotall, dollar_endonly].

%%% The parser: alternatives, then sequences of atoms, each with repeats

%% Alternatives up to the end of the pattern or the close of a group.
alternatives(Bytes, P) ->
    {First, Rest, P1} = sequence(Bytes, P, start),
    more_alternatives(Rest, P1, [First]).

more_alternatives(Bytes, #p{syntax = Syntax} = P, Acc) ->
    case {Syntax, Bytes} of
        {bre, <<"\\|", Rest/binary>>} -> next_alternative(Rest, P, Acc);
        {ere, <<"|", Rest/binary>>} -> next_alternative(Rest, P, Acc);
        _ -> {lists:join($|, lists:reverse(Acc)), Bytes, P}
    end.

next_alternative(Bytes, P, Acc) ->
    {Next, Rest, P1} = sequence(Bytes, P, start),
    more_alternatives(Rest, P1, [Next | Acc]).

%% A sequence of atoms, each with its repeats. Where tells an atom whether
%% it starts an expression, where `*` is ordinary in a basic expression
%% and `^` anchors.
sequence(Bytes, P, Where) ->
    case ends_sequence(Bytes, P) of
        true ->
            {[], Bytes, P};
        false ->
            {Repeated, Rest1, P1} = repeats(atom(Bytes, P, Where)),
            {More, Rest2, P2} = sequence(Rest1, P1, inside),
            {[Repeated | More], Rest2, P2}
    end.

ends_sequence(<<>>, _P) -> true;
ends_sequence(<<"\\|", _/binary>>, #p{syntax = bre}) -> true;
ends_sequence(<<"\\)", _/binary>>, #p{syntax = bre, depth = Depth}) when Depth > 0 -> true;
ends_sequence(<<"|", _/binary>>, #p{syntax = ere}) -> true;
ends_sequence(<<")", _/binary>>, #p{syntax = ere, depth = Depth}) when Depth > 0 -> true;
ends_sequence(_Bytes, _P) -> false.

%% One atom: its `re` source, the rest of the pattern and the state.
atom(<<"^", Rest/binary>>, #p{syntax = ere} = P, _Where) -> {anchor, <<"^">>, Rest, P};
atom(<<"^", Rest/binary>>, #p{syntax = bre} = P, start) -> {anchor, <<"^">>, Rest, P};
atom(<<"$", Rest/binary>>, #p{syntax = ere} = P, _Where) -> {anchor, <<"$">>, Rest, P};
atom(<<"$", Rest/binary>>, #p{syntax = bre} = P, _Where) ->
    case ends_sequence(Rest, P) of
        true -> {anchor, <<"$">>, Rest, P};
        false -> {char, literal($$), Rest, P}
    end;
atom(<<"*", Rest/binary>>, #p{syntax = bre} = P, start) -> {char, literal($*), Rest, P};
atom(<<C, _/binary>>, #p{syntax = ere}, _Where) when C =:= $*; C =:= $+; C =:= $? ->
    refuse(<<"repetition-operator operand invalid">>);
atom(<<"{", D, _/binary>>, #p{syntax = ere}, _Where) when D >= $0, D =< $9 ->
    refuse(<<"repetition-operator operand invalid">>);
atom(<<"(", Rest/binary>>, #p{syntax = ere} = P, _Where) -> group(Rest, P);
atom(<<"\\(", Rest/binary>>, #p{syntax = bre} = P, _Where) -> group(Rest, P);
atom(<<")", _/binary>>, #p{syntax = ere}, _Where) -> refuse(<<"parentheses not balanced">>);
atom(<<"\\)", _/binary>>, #p{syntax = bre}, _Where) -> refuse(<<"parentheses not balanced">>);
atom(<<"\\{", _/binary>>, #p{syntax = bre}, _Where) -> refuse(<<"repetition-operator operand invalid">>);
atom(<<".", Rest/binary>>, P, _Where) -> {char, <<".">>, Rest, P};
atom(<<"[", Rest/binary>>, P, _Where) -> bracket(Rest, P);
atom(<<"\\", Rest/binary>>, P, _Where) -> escape(Rest, P);
atom(<<C, Rest/binary>>, P, _Where) -> {char, literal(C), Rest, P}.

group(Bytes, #p{depth = Depth, opened = Opened} = P) ->
    Number = Opened + 1,
    {Inner, Rest, P1} = alternatives(Bytes, deeper(P#p{opened = Number})),
    Close = case P#p.syntax of bre -> <<"\\)">>; ere -> <<")">> end,
    case binary:longest_common_prefix([Rest, Close]) =:= byte_size(Close) of
        true ->
            After = binary_part(Rest, byte_size(Close), byte_size(Rest) - byte_size(Close)),
            {char, [$(, Inner, $)], After, P1#p{depth = Depth, closed = [Number | P1#p.closed]}};
        false ->
            refuse(<<"parentheses not balanced">>)
    end.

deeper(#p{depth = Depth}) when Depth >= ?MAX_DEPTH -> refuse(<<"regular expression too big">>);
deeper(#p{depth = Depth} = P) -> P#p{depth = Depth + 1}.

escape(<<>>, _P) -> refuse(<<"trailing backslash (\\)">>);
escape(<<D, Rest/binary>>, #p{closed = Closed} = P) when D >= $1, D =< $9 ->
    case lists:member(D - $0, Closed) of
        true -> {char, [$\\, $g, ${, D, $}], Rest, P};
        false -> refuse(<<"invalid backreference number">>)
    end;
escape(<<C, Rest/binary>>, P) ->
    case gnu_escape(C) of
        {char, Source} -> {char, Source, Rest, P};
        {anchor, Source} -> {anchor, Source, Rest, P};
        none when C >= $a, C =< $z; C >= $A, C =< $Z -> refuse(<<"trailing backslash (\\)">>);
        none -> {char, literal(C), Rest, P}
    end.

gnu_escape($w) -> {char, <<"[[:alnum:]_]">>};
gnu_escape($W) -> {char, <<"[^[:alnum:]_]">>};
gnu_escape($s) -> {char, <<"[[:space:]]">>};
gnu_escape($S) -> {char, <<"[^[:space:]]">>};
gnu_escape($b) -> {anchor, <<"\\b">>};
gnu_escape($B) -> {anchor, <<"\\B">>};
gnu_escape($<) -> {anchor, <<"\\b(?=\\w)">>};
gnu_escape($>) -> {anchor, <<"\\b(?<=\\w)">>};
gnu_escape($`) -> {anchor, <<"\\A">>};
gnu_escape($') -> {anchor, <<"\\z">>};
gnu_escape(_C) -> none.

%% The repeat after an atom; a second one is refused. An anchor is
%% not repeated: a repeat after one is ordinary in a basic expression and
%% refused in an extended one, as on FreeBSD.
repeats({anchor, Source, Rest, P}) ->
    case {P#p.syntax, Rest} of
        {ere, <<C, _/binary>>} when C =:= $*; C =:= $+; C =:= $? ->
            refuse(<<"repetition-operator operand invalid">>);
        _ ->
            {Source, Rest, P}
    end;
repeats({char, Source, Rest, P}) ->
    case repeat(Rest, P) of
        none ->
            {Source, Rest, P};
        {Operator, After} ->
            repeat(After, P) =:= none orelse refuse(<<"repetition-operator operand invalid">>),
            {[Source, Operator], After, P}
    end.

repeat(<<"*", Rest/binary>>, _P) -> {<<"*">>, Rest};
repeat(<<"+", Rest/binary>>, #p{syntax = ere}) -> {<<"+">>, Rest};
repeat(<<"?", Rest/binary>>, #p{syntax = ere}) -> {<<"?">>, Rest};
repeat(<<"{", D, _/binary>> = Bytes, #p{syntax = ere}) when D >= $0, D =< $9 ->
    interval(binary_part(Bytes, 1, byte_size(Bytes) - 1), <<"}">>);
repeat(<<"\\{", Rest/binary>>, #p{syntax = bre}) -> interval(Rest, <<"\\}">>);
repeat(<<"\\+", Rest/binary>>, #p{syntax = bre}) -> {<<"+">>, Rest};
repeat(<<"\\?", Rest/binary>>, #p{syntax = bre}) -> {<<"?">>, Rest};
repeat(_Bytes, _P) -> none.

%% `m`, `m,` or `m,n` and the close, each count at most 255 and m =< n.
interval(Bytes, Close) ->
    {Min, Rest} = count(Bytes),
    {Max, Rest1} = case Rest of
                       <<",", More/binary>> ->
                           case count(More) of
                               {none, After} -> {infinity, After};
                               Counted -> Counted
                           end;
                       _ -> {Min, Rest}
                   end,
    Min =:= none andalso refuse(<<"invalid repetition count(s)">>),
    case binary:longest_common_prefix([Rest1, Close]) =:= byte_size(Close) of
        false -> refuse(<<"braces not balanced">>);
        true -> ok
    end,
    (Max =:= infinity orelse Max >= Min) orelse refuse(<<"invalid repetition count(s)">>),
    Operator = case Max of
                   infinity -> [${, integer_to_binary(Min), <<",}">>];
                   Min -> [${, integer_to_binary(Min), $}];
                   _ -> [${, integer_to_binary(Min), $,, integer_to_binary(Max), $}]
               end,
    {Operator, binary_part(Rest1, byte_size(Close), byte_size(Rest1) - byte_size(Close))}.

count(Bytes) ->
    Digits = length(lists:takewhile(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bytes))),
    case Digits of
        0 -> {none, Bytes};
        _ when Digits > 3 -> refuse(<<"invalid repetition count(s)">>);
        _ ->
            N = binary_to_integer(binary_part(Bytes, 0, Digits)),
            N =< ?MAX_REPEAT orelse refuse(<<"invalid repetition count(s)">>),
            {N, binary_part(Bytes, Digits, byte_size(Bytes) - Digits)}
    end.

%%% Bracket expressions

%% After `[`: an optional `^`, then members up to the `]` that closes it,
%% a `]` first being a member.
bracket(<<"^", Rest/binary>>, P) -> bracket(Rest, P, <<"[^">>);
bracket(Bytes, P) -> bracket(Bytes, P, <<"[">>).

bracket(<<"]", Rest/binary>>, P, Open) ->
    members(Rest, P, [literal($])], Open);
bracket(Bytes, P, Open) ->
    members(Bytes, P, [], Open).

members(<<>>, _P, _Acc, _Open) ->
    refuse(<<"brackets ([ ]) not balanced">>);
members(<<"]", Rest/binary>>, P, Acc, Open) ->
    {char, [Open, lists:reverse(Acc), $]], Rest, P};
members(<<"[:", Rest/binary>>, P, Acc, Open) ->
    {Name, After} = until(Rest, <<":]">>, <<"brackets ([ ]) not balanced">>),
    lists:member(Name, [<<"alnum">>, <<"alpha">>, <<"blank">>, <<"cntrl">>, <<"digit">>,
                        <<"graph">>, <<"lower">>, <<"print">>, <<"punct">>, <<"space">>,
                        <<"upper">>, <<"xdigit">>])
        orelse refuse(<<"invalid character class">>),
    members(After, P, [[<<"[:">>, Name, <<":]">>] | Acc], Open);
members(Bytes, P, Acc, Open) ->
    {Low, Rest} = element_char(Bytes),
    case Rest of
        <<"-", Next, _/binary>> when Next =/= $] ->
            {High, Rest1} = element_char(binary_part(Rest, 1, byte_size(Rest) - 1)),
            Low =< High orelse refuse(<<"invalid character range">>),
            members(Rest1, P, [[literal(Low), $-, literal(High)] | Acc], Open);
        _ ->
            members(Rest, P, [literal(Low) | Acc], Open)
    end.

%% One character of a bracket: itself, or a one-byte `[.c.]` or `[=c=]`.
element_char(<<"[.", C, ".]", Rest/binary>>) -> {C, Rest};
element_char(<<"[=", C, "=]", Rest/binary>>) -> {C, Rest};
element_char(<<"[.", _/binary>>) -> refuse(<<"invalid collating element">>);
element_char(<<"[=", _/binary>>) -> refuse(<<"invalid collating element">>);
element_char(<<"[:", _/binary>>) -> refuse(<<"invalid character range">>);
element_char(<<C, Rest/binary>>) -> {C, Rest};
element_char(<<>>) -> refuse(<<"brackets ([ ]) not balanced">>).

until(Bytes, Close, Message) ->
    case binary:match(Bytes, Close) of
        {At, Size} -> {binary_part(Bytes, 0, At), binary_part(Bytes, At + Size, byte_size(Bytes) - At - Size)};
        nomatch -> refuse(Message)
    end.

%% A byte as itself: a letter or digit bare, anything else as `\xHH`.
literal(C) when C >= $a, C =< $z; C >= $A, C =< $Z; C >= $0, C =< $9 -> <<C>>;
literal(C) -> iolist_to_binary(io_lib:format("\\x~2.16.0B", [C])).

refuse(Message) -> throw({refused, Message}).
