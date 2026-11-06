%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_shell_lex and erx_shell_parse: rc's syntax as plan9port's
%% rc and its rc(1) manual define it, case by case, and malformed sources, each
%% of which must give its diagnostic at its position. Expected trees are
%% written out in full from the manual's rules, not derived from the parser.

-module(erx_shell_parse_tests).
-include_lib("eunit/include/eunit.hrl").

%% Fixtures: a whole source parsed as an evaluator reads a script, one unit
%% at a time from the rest the last one left, stopping at the first fault,
%% with every diagnostic's line counted from the source's start and whether
%% an `if not` may follow carried from unit to unit; the one
%% command a source parses to; and its words.
program(Source) ->
    program(Source, 0, []).

program(Source, Lines, Units) ->
    IfBefore = erx_shell_parse:if_not_may_follow(lists:append(lists:reverse(Units)), false),
    case erx_shell_parse:next(Source, final, IfBefore) of
        eof ->
            {ok, lists:append(lists:reverse(Units))};
        {ok, Cmds, Rest} ->
            Used = binary_part(Source, 0, byte_size(Source) - byte_size(Rest)),
            program(Rest, Lines + length(binary:matches(Used, <<"\n">>)), [Cmds | Units]);
        {incomplete, Pos, Message} ->
            {error, {incomplete, shift(Pos, Lines), Message}};
        {error, {too_long, _} = TooLong, _Rest} ->
            {error, TooLong};
        {error, {too_deep, Pos}, _Rest} ->
            {error, {too_deep, shift(Pos, Lines)}};
        {error, {syntax, Pos, Message}, _Rest} ->
            {error, {syntax, shift(Pos, Lines), Message}}
    end.

shift({Line, Column}, Lines) -> {Line + Lines, Column}.

one(Source) ->
    {ok, [Cmd]} = program(Source),
    Cmd.

args(Source) ->
    {simple, Words, []} = one(Source),
    Words.

w(Text) -> {word, Text}.
q(Text) -> {quoted, Text}.
v(Name) -> {var, w(Name)}.
cmd(Words) -> {simple, [w(Word) || Word <- Words], []}.
err(Source) -> program(Source).

%% Words and quoting

words_split_on_blanks_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"a">>), w(<<"b">>)], args(<<"echo  a\tb">>)).

quote_keeps_specials_and_doubles_quotes_test() ->
    ?assertEqual([w(<<"echo">>), q(<<"it's a $x; |{}">>)],
                 args(<<"echo 'it''s a $x; |{}'">>)).

quoted_word_spans_lines_test() ->
    ?assertEqual([w(<<"echo">>), q(<<"a\nb">>)], args(<<"echo 'a\nb'">>)).

empty_quote_is_a_word_test() ->
    ?assertEqual([w(<<"echo">>), q(<<>>)], args(<<"echo ''">>)).

glob_characters_stay_in_unquoted_words_test() ->
    ?assertEqual([w(<<"ls">>), w(<<"*.c">>), q(<<"*.h">>), w(<<"a?[bc]">>)],
                 args(<<"ls *.c '*.h' a?[bc]">>)).

backslash_and_bang_are_word_bytes_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"a\\b">>), w(<<"!x">>), w(<<"~y">>)],
                 args(<<"echo a\\b !x ~y">>)).

keyword_after_the_first_word_is_a_word_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"if">>), w(<<"for">>), w(<<"in">>),
                  w(<<"!">>), w(<<"~">>), w(<<"@">>)],
                 args(<<"echo if for in ! ~ @">>)).

non_ascii_bytes_are_word_bytes_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"caf", 16#c3, 16#a9>>)],
                 args(<<"echo caf", 16#c3, 16#a9>>)).

%% Variables

dollar_forms_test() ->
    ?assertEqual([w(<<"echo">>), v(<<"x">>), {count, w(<<"x">>)},
                  {flat, w(<<"x">>)}, v(<<"*">>), {count, w(<<"*">>)}],
                 args(<<"echo $x $#x $\"x $* $#*">>)).

subscript_test() ->
    ?assertEqual([w(<<"echo">>),
                  {var_sub, w(<<"x">>), [w(<<"2">>)]},
                  {var_sub, w(<<"*">>), [w(<<"1">>), w(<<"3-4">>)]}],
                 args(<<"echo $x(2) $*(1 3-4)">>)).

keyword_name_takes_a_subscript_test() ->
    ?assertEqual([w(<<"echo">>), {var_sub, w(<<"if">>), [w(<<"1">>)]}], args(<<"echo $if(1)">>)).

space_before_paren_is_no_subscript_test() ->
    ?assertEqual([w(<<"echo">>), v(<<"x">>), {list, [w(<<"2">>)]}],
                 args(<<"echo $x (2)">>)).

indirect_variable_test() ->
    ?assertEqual([w(<<"echo">>), {var, v(<<"x">>)}], args(<<"echo $$x">>)).

subscript_binds_to_the_inner_dollar_test() ->
    ?assertEqual([w(<<"echo">>), {var, {var_sub, w(<<"x">>), [w(<<"1">>)]}}],
                 args(<<"echo $$x(1)">>)).

quoted_and_keyword_names_test() ->
    ?assertEqual([w(<<"echo">>), {var, q(<<"a b">>)}, v(<<"if">>)],
                 args(<<"echo $'a b' $if">>)).

name_stops_at_a_non_name_byte_test() ->
    ?assertEqual([w(<<"echo">>), {concat, [v(<<"stem">>), w(<<".c">>)]},
                  {concat, [v(<<"a">>), w(<<"-b">>)]}],
                 args(<<"echo $stem.c $a-b">>)).

%% Concatenation

explicit_caret_test() ->
    ?assertEqual([{concat, [w(<<"echo">>), w(<<"a">>)]}], args(<<"echo ^a">>)),
    ?assertEqual([w(<<"echo">>), {concat, [w(<<"a">>), w(<<"b">>), q(<<"c">>)]}],
                 args(<<"echo a ^ b^'c'">>)).

free_carets_test() ->
    ?assertEqual([w(<<"cc">>), {concat, [w(<<"-">>), v(<<"flags">>)]},
                  {concat, [v(<<"stem">>), w(<<".c">>)]},
                  {concat, [q(<<"a">>), w(<<"b">>), q(<<"c">>)]}],
                 args(<<"cc -$flags $stem.c 'a'b'c'">>)).

caret_binds_looser_than_dollar_test() ->
    ?assertEqual([w(<<"echo">>), {concat, [v(<<"a">>), w(<<"b">>)]}],
                 args(<<"echo $a^b">>)).

no_free_caret_after_a_keyword_or_a_paren_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"for">>), v(<<"x">>),
                  {list, [w(<<"a">>)]}, w(<<"b">>)],
                 args(<<"echo for$x (a)b">>)).

free_caret_before_backquote_test() ->
    ?assertEqual([w(<<"echo">>),
                  {concat, [w(<<"a">>), {backquote, ifs, [cmd([<<"b">>])]}]}],
                 args(<<"echo a`{b}">>)).

%% Lists and assignment

assignment_test() ->
    ?assertEqual({assign, w(<<"x">>), {list, [w(<<"a">>), w(<<"b">>), w(<<"c">>)]}},
                 one(<<"x=(a b c)">>)),
    ?assertEqual({assign, w(<<"x">>), {list, []}}, one(<<"x=()">>)),
    ?assertEqual({assign, v(<<"n">>), w(<<"1">>)}, one(<<"$n=1">>)).

local_assignment_applies_to_the_pipeline_test() ->
    ?assertEqual({local, w(<<"x">>), w(<<"1">>),
                  {pipeline, cmd([<<"a">>]), [{{1, 0}, cmd([<<"b">>])}]}},
                 one(<<"x=1 a | b">>)).

%% `=` is a word's byte except after a command's first word, as in rc's
%% hand-written parser: free carets join it to what touches it.
equals_inside_words_test() ->
    Eq = w(<<"=">>),
    ?assertEqual([w(<<"echo">>), {concat, [w(<<"a">>), Eq, w(<<"b">>)]},
                  {concat, [w(<<"x">>), Eq]}, {concat, [Eq, w(<<"y">>)]}],
                 args(<<"echo a=b x= =y">>)),
    ?assertEqual({assign, w(<<"x">>), {list, [w(<<"p">>), {concat, [w(<<"q">>), Eq, w(<<"r">>)]}]}},
                 one(<<"x=(p q=r)">>)),
    ?assertEqual({assign, w(<<"z">>), {concat, [w(<<"a">>), Eq, w(<<"b">>)]}}, one(<<"z=a=b">>)),
    ?assertEqual({assign, w(<<"y">>), w(<<"1">>)}, one(<<"y = 1">>)),
    ?assertEqual([{concat, [w(<<"a">>), w(<<"b">>), Eq, w(<<"c">>)]}], args(<<"a^b=c">>)),
    ?assertEqual([{concat, [w(<<"a">>), Eq, w(<<"b">>)]}], args(<<"a^=b">>)),
    ?assertEqual({assign, {concat, [w(<<"a">>), w(<<"b">>)]}, w(<<"c">>)}, one(<<"a^b =c">>)),
    ?assertEqual([w(<<"echo">>), {concat, [v(<<"x">>), Eq, w(<<"1">>)]}], args(<<"echo $x=1">>)),
    %% In a switch, `case` assigned to is a command, as rc runs it.
    ?assertEqual({switch, {list, [v(<<"x">>)]}, [{'case', [w(<<"a">>)], [{assign, w(<<"case">>), w(<<"*">>)},
                                                               {assign, w(<<"case">>), w(<<"b">>)}]}]},
                 one(<<"switch($x){case a\ncase= *\ncase = b\n}">>)).

nested_lists_test() ->
    ?assertEqual([w(<<"echo">>), {list, [w(<<"a">>), {list, [w(<<"b">>)]}]}],
                 args(<<"echo (a (b))">>)).

%% Redirections

redirections_test() ->
    ?assertEqual({simple, [w(<<"cmd">>), w(<<"arg">>)],
                  [{write, 1, w(<<"out">>)}, {append, 2, w(<<"err">>)},
                   {read, 0, w(<<"in">>)}, {rdwr, 0, w(<<"dev">>)},
                   {read, 3, w(<<"three">>)}]},
                 one(<<"cmd >out arg >>[2] err <in <>dev <[3]three">>)).

dup_and_close_test() ->
    ?assertEqual({simple, [w(<<"cmd">>)], [{dup, 2, 1}, {close, 0}, {dup, 0, 3}]},
                 one(<<"cmd >[2=1] >[0=] <[0=3]">>)).

prefix_redirection_test() ->
    ?assertEqual({redirect, {write, 1, w(<<"f">>)},
                  {pipeline, cmd([<<"a">>]), [{{1, 0}, cmd([<<"b">>])}]}},
                 one(<<">f a | b">>)),
    ?assertEqual({redirect, {write, 1, w(<<"f">>)}, empty}, one(<<">f">>)).

block_redirections_test() ->
    ?assertEqual({block, [cmd([<<"a">>]), cmd([<<"b">>])],
                  [{write, 1, w(<<"f">>)}, {dup, 2, 1}]},
                 one(<<"{a; b} >f >[2=1]">>)).

here_document_template_test() ->
    ?assertEqual({ok, [{simple, [w(<<"cat">>)],
                        [{here, 0, {template, [<<"a ">>, {var, <<"x">>},
                                               <<"y $ ">>, {var, <<"1">>},
                                               <<"\n">>]}}]},
                       cmd([<<"echo">>])]},
                 program(<<"cat <<EOF\na $x^y $$ $1\nEOF\necho">>)).

quoted_here_document_is_literal_test() ->
    ?assertEqual({simple, [w(<<"cat">>)], [{here, 0, {literal, <<"$x\n">>}}]},
                 one(<<"cat <<'EOF'\n$x\nEOF\n">>)).

two_here_documents_on_one_line_test() ->
    ?assertEqual({ok, [{simple, [w(<<"a">>)], [{here, 0, {literal, <<"1\n">>}}]},
                       {simple, [w(<<"b">>)], [{here, 3, {literal, <<"2\n">>}}]}]},
                 program(<<"a <<'X'; b <<[3]'Y'\n1\nX\n2\nY\n">>)).

here_document_body_waits_for_the_line_end_test() ->
    ?assertEqual({ok, [{block, [{simple, [w(<<"cat">>)],
                                 [{here, 0, {literal, <<"in\n">>}}]}], []}]},
                 program(<<"{cat <<'E'\nin\nE\n}">>)).

here_document_inside_a_block_test() ->
    ?assertEqual({block, [{simple, [w(<<"cat">>)], [{here, 0, {template, [<<"x\n">>]}}]}], []},
                 one(<<"{cat <<E\nx\nE\n}">>)).

here_document_tag_on_the_last_line_test() ->
    ?assertEqual({simple, [w(<<"cat">>)], [{here, 0, {literal, <<"x\n">>}}]},
                 one(<<"cat <<'E'\nx\nE">>)).

%% Pipes and conditions

pipes_test() ->
    ?assertEqual({pipeline, cmd([<<"a">>]),
                  [{{1, 0}, cmd([<<"b">>])}, {{2, 0}, cmd([<<"c">>])},
                   {{3, 4}, cmd([<<"d">>])}]},
                 one(<<"a | b |[2] c |[3=4]\n d">>)).

and_or_is_flat_and_left_to_right_test() ->
    ?assertEqual({and_or, cmd([<<"a">>]),
                  [{'and', cmd([<<"b">>])}, {'or', cmd([<<"c">>])},
                   {'and', cmd([<<"d">>])}]},
                 one(<<"a && b ||\n c && d">>)).

pipe_binds_tighter_than_and_test() ->
    ?assertEqual({and_or, {pipeline, cmd([<<"a">>]), [{{1, 0}, cmd([<<"b">>])}]},
                  [{'or', cmd([<<"c">>])}]},
                 one(<<"a | b || c">>)).

bang_takes_the_pipeline_not_the_and_test() ->
    ?assertEqual({and_or, {'not', {pipeline, cmd([<<"a">>]), [{{1, 0}, cmd([<<"b">>])}]}},
                  [{'and', cmd([<<"c">>])}]},
                 one(<<"! a | b && c">>)).

subshell_test() ->
    ?assertEqual({subshell, cmd([<<"a">>])}, one(<<"@ a">>)).

background_test() ->
    ?assertEqual({ok, [{background, cmd([<<"a">>])}, cmd([<<"b">>])]},
                 program(<<"a & b">>)),
    ?assertEqual({ok, [cmd([<<"a">>])]}, program(<<";; a ;\n\n">>)).

%% Compound commands

if_and_if_not_test() ->
    ?assertEqual({ok, [{'if', [{match, v(<<"x">>), [w(<<"a">>)]}],
                        {and_or, cmd([<<"b">>]), [{'and', cmd([<<"c">>])}]}},
                       {if_not, cmd([<<"d">>])}]},
                 program(<<"if(~ $x a) b && c\nif not d">>)).

%% An `if not` stands only where rc's parser lets it: first in a sequence
%% whose command before it, in the same sequence or the unit before, is an
%% `if` or an `if not` whose body is an `if` or empty, or as the body of an
%% accepted `if not`. A line with no commands leaves the flag as it was; a
%% source, a block, a function's body and a switch arm start without it.
-define(IF_NOT, <<"`if not' does not follow `if(...)'">>).

if_not_where_rc_accepts_it_test_() ->
    Sources = [<<"if(a) b; if not c">>, <<"if(a) b\n\n# note\nif not c">>,
               <<"if(a) b; if not if(c) d; if not e">>, <<"if(a) b; if not; if not c">>,
               <<"if(a) b; if not if not c">>, <<"if(a) if(b) c; if not d">>,
               <<"{if(a) b; if not c}">>, <<"switch(x){case a\nif(b) c; if not d}">>,
               <<"fn f {if(a) b\nif not c}">>],
    [{Source, ?_assertMatch({ok, _}, program(Source))} || Source <- Sources].

if_not_where_rc_refuses_it_test_() ->
    Cases = [{<<"if not c">>, {1, 1}}, {<<"a; if not c">>, {1, 4}},
             {<<"if(a) b; c; if not d">>, {1, 13}}, {<<"if(a) b; if not c; if not d">>, {1, 20}},
             {<<"if(a) b &\nif not c">>, {2, 1}}, {<<"if(a) b; x | if not c">>, {1, 14}},
             {<<"if(a) b; x && if not c">>, {1, 15}}, {<<"if(a) if not c">>, {1, 7}},
             {<<"if(a) b; {if not c}">>, {1, 11}}, {<<"if(a) b; fn f {if not c}">>, {1, 16}},
             {<<"if(a) b; ! if not c">>, {1, 12}}, {<<"if(a) b; if not {if not c}">>, {1, 18}},
             {<<"if not if not c">>, {1, 1}}],
    [{Source, ?_assertEqual({error, {syntax, Pos, ?IF_NOT}}, program(Source))}
     || {Source, Pos} <- Cases].

if_not_after_the_unit_before_test() ->
    IfNot = {ok, [{if_not, cmd([<<"c">>])}], <<>>},
    ?assertEqual(IfNot, erx_shell_parse:next(<<"if not c\n">>, final, true)),
    ?assertEqual(IfNot, erx_shell_parse:next_bounded(<<"if not c\n">>, final, true)),
    ?assertMatch({error, {syntax, {1, 1}, ?IF_NOT}, <<>>},
                 erx_shell_parse:next_bounded(<<"if not c\n">>, final, false)),
    ?assertMatch({error, {syntax, {1, 1}, ?IF_NOT}, <<>>},
                 erx_shell_parse:next(<<"if not c\n">>, final)).

if_not_may_follow_test() ->
    Follows = fun(Source, Before) ->
                      {ok, Program, <<>>} = erx_shell_parse:next(Source, final, Before),
                      erx_shell_parse:if_not_may_follow(Program, Before)
              end,
    ?assert(Follows(<<"# nothing\n">>, true)),
    ?assertNot(Follows(<<"# nothing\n">>, false)),
    ?assert(Follows(<<"if(a) b\n">>, false)),
    ?assert(Follows(<<"a; if(a) b\n">>, false)),
    ?assertNot(Follows(<<"if(a) b; a\n">>, false)),
    ?assertNot(Follows(<<"if(a) b &\n">>, false)),
    ?assert(Follows(<<"if not;\n">>, true)),
    ?assert(Follows(<<"if not if(a) b\n">>, true)),
    ?assertNot(Follows(<<"if not b\n">>, true)),
    ?assertNot(Follows(<<"if not if not b\n">>, true)).

if_body_on_the_next_line_test() ->
    ?assertEqual({'if', [cmd([<<"t">>]), cmd([<<"u">>])], cmd([<<"b">>])},
                 one(<<"if(t\n u)\n\n b">>)).

empty_if_body_test() ->
    ?assertEqual({block, [{'if', [cmd([<<"t">>])], empty}], []}, one(<<"{if(t)}">>)).

for_test() ->
    ?assertEqual({for, w(<<"i">>), {in, [w(<<"a">>), w(<<"in">>)]}, cmd([<<"b">>])},
                 one(<<"for(i in a in) b">>)),
    ?assertEqual({for, w(<<"i">>), args, {block, [cmd([<<"b">>])], []}},
                 one(<<"for(i)\n{b}">>)),
    ?assertEqual({for, w(<<"i">>), {in, []}, cmd([<<"b">>])}, one(<<"for(i in) b">>)).

while_test() ->
    ?assertEqual({while, [cmd([<<"t">>])], {block, [cmd([<<"b">>])], []}},
                 one(<<"while(t) {b}">>)).

switch_test() ->
    ?assertEqual({switch, {list, [v(<<"x">>)]},
                  [{'case', [w(<<"a">>), w(<<"b*">>)], [cmd([<<"one">>]), cmd([<<"two">>])]},
                   {'case', [w(<<"*">>)], []}]},
                 one(<<"switch($x) {\ncase a b*\n one; two\ncase *\n}">>)).

switch_subject_is_a_word_test() ->
    ?assertEqual({switch, v(<<"x">>), [{'case', [w(<<"a">>)], [cmd([<<"b">>])]}]},
                 one(<<"switch $x {case a; b}">>)).

quoted_case_is_a_command_test() ->
    ?assertEqual({switch, w(<<"x">>),
                  [{'case', [w(<<"a">>)], [{simple, [q(<<"case">>), w(<<"b">>)], []}]}]},
                 one(<<"switch x {case a; 'case' b}">>)).

joined_case_is_a_command_test() ->
    ?assertEqual({switch, w(<<"x">>),
                  [{'case', [w(<<"a">>)],
                    [{simple, [{concat, [w(<<"case">>), w(<<"y">>)]}, w(<<"b">>)], []}]}]},
                 one(<<"switch x {case a; case^y b}">>)).

match_test() ->
    ?assertEqual({match, v(<<"x">>), [w(<<"*.c">>), q(<<"a">>)]}, one(<<"~ $x *.c 'a'">>)).

fn_test() ->
    ?assertEqual({fn, [w(<<"f">>), w(<<"g">>)], [cmd([<<"echo">>, <<"hi">>])]},
                 one(<<"fn f g { echo hi }">>)),
    ?assertEqual({fn_delete, [w(<<"f">>)]}, one(<<"fn f">>)).

substitutions_test() ->
    ?assertEqual([w(<<"echo">>),
                  {backquote, ifs, [cmd([<<"ls">>])]},
                  {backquote, q(<<":">>), [cmd([<<"cat">>, <<"f">>])]},
                  {pipefd, read, [cmd([<<"a">>])]},
                  {pipefd, write, [cmd([<<"b">>])]}],
                 args(<<"echo `{ls} `':'{cat f} <{a} > {b}">>)).

%% Comments and continuation

comment_test() ->
    ?assertEqual({ok, [cmd([<<"a">>]), cmd([<<"b">>])]},
                 program(<<"# head\na#tail\nb # more">>)),
    ?assertEqual([w(<<"echo">>), {count, w(<<"x">>)}], args(<<"echo $#x">>)).

comment_ends_at_its_newline_despite_a_backslash_test() ->
    ?assertEqual({ok, [cmd([<<"echo">>, <<"a">>]), cmd([<<"echo">>, <<"b">>])]},
                 program(<<"echo a # c \\\necho b">>)).

line_continuation_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"a">>), w(<<"b">>)], args(<<"echo a\\\nb">>)),
    ?assertEqual([w(<<"echo">>), q(<<"a\\\nb">>)], args(<<"echo 'a\\\nb'">>)).

%% Malformed sources: each a diagnostic at a position.

syntax_errors_test_() ->
    Cases = [{<<"echo a=(b)">>, {1, 8}, <<"unexpected '('">>},
             {<<"echo =">>, {1, 7}, <<"a word must follow">>},
             {<<"a=^b">>, {1, 3}, <<"a word must follow">>},
             {<<"x= ^b">>, {1, 4}, <<"a word must follow">>},
             {<<"echo x(1)">>, {1, 7}, <<"unexpected '('">>},
             {<<"a\n  }">>, {2, 3}, <<"unexpected '}'">>},
             {<<"echo {a}">>, {1, 6}, <<"unexpected '{'">>},
             {<<"in x">>, {1, 1}, <<"unexpected 'in'">>},
             {<<"not x">>, {1, 1}, <<"unexpected 'not'">>},
             {<<"| a">>, {1, 1}, <<"unexpected '|'">>},
             {<<"a && ; b">>, {1, 6}, <<"a command must follow">>},
             {<<"^a">>, {1, 1}, <<"unexpected '^'">>},
             {<<"echo (a">>, {1, 8}, <<"expected ')'">>},
             {<<"a >[2">>, {1, 3}, <<"malformed redirection">>},
             {<<"x=">>, {1, 3}, <<"a word must follow">>},
             {<<"echo $#x(1)">>, {1, 9}, <<"unexpected '('">>},
             {<<"echo )\necho >[x]">>, {1, 6}, <<"unexpected ')'">>},
             {<<"echo ) 'abc">>, {1, 6}, <<"unexpected ')'">>},
             {<<"x=(a\nb)">>, {1, 5}, <<"expected ')'">>},
             {<<"x=; a">>, {1, 3}, <<"a word must follow">>},
             {<<"$ ; a">>, {1, 3}, <<"a variable name must follow '$'">>},
             {<<"if x">>, {1, 4}, <<"expected '('">>},
             {<<"for i in a">>, {1, 5}, <<"expected '('">>},
             {<<"switch x {a}">>, {1, 11}, <<"a switch body must begin with case">>},
             {<<"switch x {case a >f; b}">>, {1, 18}, <<"a case takes only words">>},
             {<<"a >[x] b">>, {1, 3}, <<"malformed redirection">>},
             {<<"a >>[2=1]">>, {1, 3}, <<"malformed redirection">>},
             {<<"a |[2=] b">>, {1, 3}, <<"malformed pipe">>},
             {<<"a >[99999999999] b">>, {1, 3}, <<"descriptor number is too large">>},
             {<<"a >>{b}">>, {1, 3}, <<"malformed redirection">>},
             {<<"cat <<$x\n">>, {1, 5}, <<"here document has no tag">>},
             {<<"cat <<a'b'\nab\n">>, {1, 5}, <<"here document tag is not one word">>}],
    [{binary_to_list(Source),
      ?_assertEqual({error, {syntax, Pos, Message}}, err(Source))}
     || {Source, Pos, Message} <- Cases].

incomplete_test_() ->
    Cases = [{<<"echo 'abc">>, {1, 6}, <<"quoted word is not closed">>},
             {<<"{ a\n">>, {2, 1}, <<"expected '}'">>},
             {<<"a &&\n">>, {2, 1}, <<"a command must follow">>},
             {<<"a |">>, {1, 4}, <<"a command must follow">>},
             {<<"a |\n">>, {2, 1}, <<"a command must follow">>},
             {<<"if(t)\n">>, {2, 1}, <<"a command must follow">>},
             {<<"echo a \\\n">>, {2, 1}, <<"line continues past the end of the input">>},
             {<<"cat <<\\\n">>, {2, 1}, <<"line continues past the end of the input">>},
             {<<"cat <<EOF\nbody\n">>, {1, 5}, <<"here document is not terminated">>},
             {<<"cat <<EOF">>, {1, 5}, <<"here document is not terminated">>},
             {<<"if(a">>, {1, 5}, <<"expected ')'">>},
             {<<"echo a # c \\\n{">>, {2, 2}, <<"expected '}'">>}],
    [{binary_to_list(Source),
      ?_assertEqual({error, {incomplete, Pos, Message}}, err(Source))}
     || {Source, Pos, Message} <- Cases].

texts_hold_no_reference_to_the_source_test() ->
    Source = <<"echo 'a quoted word' plain $name <<'E'\nbody\nE\n">>,
    {ok, [{simple, Words, [{here, 0, {literal, Body}}]}]} = program(Source),
    Texts = [Body | [T || {_, T} <- Words, is_binary(T)]] ++ [N || {var, {word, N}} <- Words],
    ?assertEqual(5, length(Texts)),
    [?assertEqual(byte_size(T), binary:referenced_byte_size(T)) || T <- Texts].

diagnostic_quotes_no_source_test() ->
    {error, Diagnostic} = program(<<"echo \e[31m }">>),
    ?assertEqual(nomatch, binary:match(erx_shell_parse:format_error(Diagnostic), <<"\e">>)).

%% Units: a source is parsed one of rc's lines at a time.

next_yields_one_line_and_the_rest_test() ->
    ?assertEqual({ok, [cmd([<<"a">>]), {background, cmd([<<"b">>])}], <<"c\n">>},
                 erx_shell_parse:next(<<"a; b &\nc\n">>, final)),
    ?assertEqual({ok, [cmd([<<"c">>])], <<>>}, erx_shell_parse:next(<<"c">>, final)),
    ?assertEqual({ok, [], <<"a\n">>}, erx_shell_parse:next(<<"  # note\na\n">>, final)),
    ?assertEqual(eof, erx_shell_parse:next(<<>>, final)),
    ?assertEqual(eof, erx_shell_parse:next(<<>>, more)).

unit_takes_its_here_documents_test() ->
    ?assertEqual({ok, [{simple, [w(<<"cat">>)], [{here, 0, {literal, <<"x\n">>}}]}], <<"b\n">>},
                 erx_shell_parse:next(<<"cat <<'E'\nx\nE\nb\n">>, final)).

an_unfinished_line_is_not_run_while_more_may_follow_test() ->
    ?assertEqual({ok, [cmd([<<"a">>])], <<"echo b">>},
                 erx_shell_parse:next(<<"a\necho b">>, more)),
    ?assertMatch({incomplete, _, _}, erx_shell_parse:next(<<"echo b">>, more)),
    ?assertMatch({incomplete, _, _}, erx_shell_parse:next(<<"if(t)\n{b">>, more)),
    ?assertEqual({ok, [cmd([<<"echo">>, <<"b">>])], <<>>},
                 erx_shell_parse:next(<<"echo b">>, final)),
    ?assertEqual(erx_shell_parse:next(<<"a |\n b\nc\n">>, final),
                 erx_shell_parse:next(<<"a |\n b\nc\n">>, more)).

units_before_a_syntax_error_parse_test() ->
    Script = <<"a\nb; c\n)\nd\n">>,
    {ok, [First], Rest1} = erx_shell_parse:next(Script, final),
    {ok, Second, Rest2} = erx_shell_parse:next(Rest1, final),
    ?assertEqual({cmd([<<"a">>]), [cmd([<<"b">>]), cmd([<<"c">>])]}, {First, Second}),
    ?assertEqual({error, {syntax, {1, 1}, <<"unexpected ')'">>}, <<"d\n">>},
                 erx_shell_parse:next(Rest2, final)),
    ?assertEqual({error, {syntax, {3, 1}, <<"unexpected ')'">>}}, program(Script)).

a_fault_ends_with_its_line_test() ->
    ?assertMatch({error, {syntax, {2, 2}, _}, <<"c\n">>},
                 erx_shell_parse:next(<<"a |\n ) b\nc\n">>, final)),
    ?assertMatch({error, {syntax, {1, 6}, _}, <<>>}, erx_shell_parse:next(<<"echo )">>, final)),
    ?assertMatch({error, {too_deep, _}, <<"b\n">>},
                 erx_shell_parse:next(<<(binary:copy(<<"{">>, 257))/binary, "\nb\n">>, final)).

command_split_across_feeds_test() ->
    Body = {block, [cmd([<<"b">>])], []},
    ?assertEqual({incomplete, {2, 1}, <<"a command must follow">>},
                 erx_shell_parse:next(<<"if(t)\n">>, more)),
    ?assertEqual({incomplete, {3, 1}, <<"expected '}'">>},
                 erx_shell_parse:next(<<"if(t)\n{b\n">>, more)),
    ?assertEqual({ok, [{'if', [cmd([<<"t">>])], Body}], <<>>},
                 erx_shell_parse:next(<<"if(t)\n{b\n}\n">>, more)),
    ?assertEqual({ok, [{pipeline, cmd([<<"a">>]), [{{1, 0}, cmd([<<"b">>])}]}], <<"c\n">>},
                 erx_shell_parse:next(<<"a |\n\n b\nc\n">>, more)).

command_at_the_bound_parses_and_one_byte_more_does_not_test() ->
    Max = erx_shell_parse:max_command_bytes(),
    Fits = <<"echo ", (binary:copy(<<"a">>, Max - 6))/binary, "\n">>,
    ?assertEqual(Max, byte_size(Fits)),
    ?assertMatch({ok, [_], <<"b\n">>}, erx_shell_parse:next(<<Fits/binary, "b\n">>, final)),
    ?assertEqual({error, {too_long, Max}, <<>>},
                 erx_shell_parse:next(<<"a", Fits/binary, "b\n">>, final)),
    Unfinished = <<"{", Fits/binary>>,
    ?assertMatch({incomplete, _, _}, erx_shell_parse:next(binary_part(Unfinished, 0, Max - 1), final)),
    ?assertMatch({error, {too_long, Max}, _}, erx_shell_parse:next(Unfinished, final)),
    ?assertMatch({error, {too_long, Max}, _}, erx_shell_parse:next(Unfinished, more)).

a_last_line_without_a_newline_counts_the_newline_test() ->
    Max = erx_shell_parse:max_command_bytes(),
    Line = fun(N) -> <<"echo ", (binary:copy(<<"a">>, N - 5))/binary>> end,
    ?assertMatch({ok, [_], <<>>}, erx_shell_parse:next(Line(Max - 1), final)),
    ?assertEqual({error, {too_long, Max}, <<>>}, erx_shell_parse:next(Line(Max), final)),
    ?assertEqual({error, {too_long, Max}, <<>>}, erx_shell_parse:next(Line(Max), more)).

%% Where a unit too long to parse ends is unknown, so nothing of it is
%% resumed: the body of a long block is never run at the top level, and
%% the tail of a long line still being read is never run as a command.
a_unit_too_long_resumes_nothing_test() ->
    Max = erx_shell_parse:max_command_bytes(),
    Block = iolist_to_binary([<<"if(false) {\n">>, binary:copy(<<"echo filler\n">>, Max div 12),
                              <<"rm y\n}\n">>]),
    ?assertEqual({error, {too_long, Max}, <<>>}, erx_shell_parse:next(Block, final)),
    ?assertEqual({error, {too_long, Max}, <<>>}, erx_shell_parse:next(Block, more)),
    Long = <<"echo ", (binary:copy(<<"a">>, Max))/binary>>,
    ?assertEqual({error, {too_long, Max}, <<>>}, erx_shell_parse:next(Long, more)).

here_document_counts_toward_the_bound_test() ->
    Max = erx_shell_parse:max_command_bytes(),
    Doc = fun(N) -> <<"cat <<'E'\n", (binary:copy(<<"b">>, N))/binary, "\nE\n">> end,
    ?assertMatch({ok, [_], <<"c\n">>}, erx_shell_parse:next(<<(Doc(Max - 13))/binary, "c\n">>, final)),
    ?assertMatch({error, {too_long, Max}, _},
                 erx_shell_parse:next(<<(Doc(Max - 12))/binary, "c\n">>, final)).

what_follows_a_unit_is_not_read_test() ->
    Max = erx_shell_parse:max_command_bytes(),
    Junk = binary:copy(<<"'">>, 3 * Max),
    ?assertEqual({ok, [cmd([<<"a">>])], Junk}, erx_shell_parse:next(<<"a\n", Junk/binary>>, final)).

a_script_has_no_size_bound_test() ->
    Max = erx_shell_parse:max_command_bytes(),
    Script = binary:copy(<<"echo a | b\n">>, 16 * Max div 11),
    {ok, Program} = program(Script),
    ?assertEqual(16 * Max div 11, length(Program)).

nesting_256_deep_parses_and_257_does_not_test() ->
    Nest = fun(N) -> iolist_to_binary([lists:duplicate(N, <<"{">>), <<"a">>,
                                       lists:duplicate(N, <<"}">>)]) end,
    ?assertMatch({ok, [_]}, program(Nest(256))),
    ?assertEqual({error, {too_deep, {1, 257}}}, program(Nest(257))).

long_flat_chains_are_not_nesting_test() ->
    Stages = erx_shell_parse:max_command_bytes() div 2,
    Chain = iolist_to_binary(lists:join(<<"|">>, lists:duplicate(Stages, <<"a">>))),
    {ok, [{pipeline, _, Rest}]} = program(Chain),
    ?assertEqual(Stages - 1, length(Rest)).

prefix_chains_count_as_nesting_test() ->
    Prefixes = fun(N) -> iolist_to_binary([lists:duplicate(N, <<"! ">>), <<"a">>]) end,
    ?assertMatch({ok, [_]}, program(Prefixes(256))),
    ?assertMatch({error, {too_deep, _}}, program(Prefixes(257))).

format_error_test() ->
    ?assertEqual(<<"syntax error at line 2, column 3: unexpected '}'">>,
                 erx_shell_parse:format_error({syntax, {2, 3}, <<"unexpected '}'">>})),
    ?assertEqual(<<"syntax error: line too long, over 4096 bytes">>,
                 erx_shell_parse:format_error({too_long, 4096})),
    ?assertEqual(<<"syntax error at line 1, column 9: nested deeper than 256">>,
                 erx_shell_parse:format_error({too_deep, {1, 9}})).

%% The parse heap (docs/design-shell.md, "Bounds"): the sweep the bound is
%% derived from. Each source is exactly max_command_bytes() long, a shape
%% that costs much heap per byte, repeated behind a prefix that moves where
%% the heap's garbage-collection steps fall, and ends with ` a` and a
%% newline. Each must parse within half of parse_heap_bytes(), the margin
%% the bound is derived with: to a program where the shape is valid rc,
%% and to a program or a diagnostic where it nests too deep, never closes
%% or is valid only for some cuts; and
%% next_bounded/3, in its child with the whole heap, must return the same.
parse_heap_sweep_test_() ->
    {timeout, 120, fun parse_heap_sweep/0}.

parse_heap_sweep() ->
    Max = erx_shell_parse:max_command_bytes(),
    Valid = [<<"a|">>, <<"$x|">>, <<"a|\n">>, <<"x=y;">>, <<";">>, <<"a ">>, <<"a&&\n">>,
             <<"a >f ">>, <<"$x^">>, <<"a&">>, <<"a^">>],
    Faulty = [<<"if(x)">>, <<"$x(">>, <<"{">>, <<"`{">>, <<"''">>, <<"x=y ">>],
    Prefixes = [binary:copy(<<"x">>, K) || K <- lists:seq(0, 299, 3)]
               ++ [binary:copy(<<"@ ">>, N) || N <- [1, 2, 3, 5, 20, 50]],
    Fill = fun(Prefix, Shape) ->
                   Run = binary:copy(Shape, Max div byte_size(Shape) + 1),
                   Body = binary_part(Run, 0, Max - 3 - byte_size(Prefix)),
                   <<Prefix/binary, Body/binary, " a\n">>
           end,
    Wrong = [{Shape, byte_size(Prefix), Result}
             || Shape <- Valid ++ Faulty, Prefix <- Prefixes,
                Source <- [Fill(Prefix, Shape)],
                Result <- [within_half_the_parse_heap(Source)],
                not expected(lists:member(Shape, Valid), Result)
                    orelse erx_shell_parse:next_bounded(Source, final, false) =/= Result],
    ?assertEqual([], Wrong).

expected(true, Result) -> element(1, Result) =:= ok;
expected(false, Result) -> element(1, Result) =/= died.

within_half_the_parse_heap(Source) ->
    Words = erx_shell_parse:parse_heap_bytes() div 2 div erlang:system_info(wordsize),
    Limit = #{size => Words, kill => true, error_logger => false, include_shared_binaries => true},
    {Pid, Ref} = spawn_opt(fun() -> exit({parsed, erx_shell_parse:next(Source, final)}) end,
                           [monitor, {max_heap_size, Limit}]),
    receive
        {'DOWN', Ref, process, Pid, {parsed, Result}} -> Result;
        {'DOWN', Ref, process, Pid, Reason} -> {died, Reason}
    end.

%% The last source is a unit of 1 KB in a buffer twice the parse heap: the
%% child is handed a copy of its window, so the buffer does not count
%% against the child heap. (A window of 64 bytes or less would be copied
%% to the child whatever next_bounded/3 does.)
next_bounded_parses_as_next_does_test() ->
    Sources = [<<"a|b\nc">>, <<"if(t)\n">>, <<"echo )\nb\n">>, <<>>,
               binary:copy(<<"a\n">>, erx_shell_parse:max_command_bytes()),
               <<"echo ", (binary:copy(<<"a">>, 1000))/binary, "\n",
                 (binary:copy(<<"b">>, 2 * erx_shell_parse:parse_heap_bytes()))/binary>>],
    [?assertEqual(erx_shell_parse:next(S, End), erx_shell_parse:next_bounded(S, End, false))
     || S <- Sources, End <- [more, final]].
