%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_shell_lex and erx_shell_parse: rc's syntax as plan9port's
%% rc and its rc(1) manual define it, case by case, and malformed sources, each
%% of which must give its diagnostic at its position. Expected trees are
%% written out in full from the manual's rules, not derived from the parser.

-module(erx_shell_parse_tests).
-include_lib("eunit/include/eunit.hrl").

%% Fixtures: the one command a source parses to, and its words.
one(Source) ->
    {ok, [Cmd]} = erx_shell_parse:parse(Source),
    Cmd.

args(Source) ->
    {simple, Words, []} = one(Source),
    Words.

w(Text) -> {word, Text}.
q(Text) -> {quoted, Text}.
v(Name) -> {var, w(Name)}.
cmd(Words) -> {simple, [w(Word) || Word <- Words], []}.
err(Source) -> erx_shell_parse:parse(Source).

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
                 erx_shell_parse:parse(<<"cat <<EOF\na $x^y $$ $1\nEOF\necho">>)).

quoted_here_document_is_literal_test() ->
    ?assertEqual({simple, [w(<<"cat">>)], [{here, 0, {literal, <<"$x\n">>}}]},
                 one(<<"cat <<'EOF'\n$x\nEOF\n">>)).

two_here_documents_on_one_line_test() ->
    ?assertEqual({ok, [{simple, [w(<<"a">>)], [{here, 0, {literal, <<"1\n">>}}]},
                       {simple, [w(<<"b">>)], [{here, 3, {literal, <<"2\n">>}}]}]},
                 erx_shell_parse:parse(<<"a <<'X'; b <<[3]'Y'\n1\nX\n2\nY\n">>)).

here_document_body_waits_for_the_line_end_test() ->
    ?assertEqual({ok, [{block, [{simple, [w(<<"cat">>)],
                                 [{here, 0, {literal, <<"in\n">>}}]}], []}]},
                 erx_shell_parse:parse(<<"{cat <<'E'\nin\nE\n}">>)).

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
                 erx_shell_parse:parse(<<"a & b">>)),
    ?assertEqual({ok, [cmd([<<"a">>])]}, erx_shell_parse:parse(<<";; a ;\n\n">>)).

%% Compound commands

if_and_if_not_test() ->
    ?assertEqual({ok, [{'if', [{match, v(<<"x">>), [w(<<"a">>)]}],
                        {and_or, cmd([<<"b">>]), [{'and', cmd([<<"c">>])}]}},
                       {if_not, cmd([<<"d">>])}]},
                 erx_shell_parse:parse(<<"if(~ $x a) b && c\nif not d">>)).

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
                 erx_shell_parse:parse(<<"# head\na#tail\nb # more">>)),
    ?assertEqual([w(<<"echo">>), {count, w(<<"x">>)}], args(<<"echo $#x">>)).

comment_ends_at_its_newline_despite_a_backslash_test() ->
    ?assertEqual({ok, [cmd([<<"echo">>, <<"a">>]), cmd([<<"echo">>, <<"b">>])]},
                 erx_shell_parse:parse(<<"echo a # c \\\necho b">>)).

line_continuation_test() ->
    ?assertEqual([w(<<"echo">>), w(<<"a">>), w(<<"b">>)], args(<<"echo a\\\nb">>)),
    ?assertEqual([w(<<"echo">>), q(<<"a\\\nb">>)], args(<<"echo 'a\\\nb'">>)).

%% Malformed sources: each a diagnostic at a position.

syntax_errors_test_() ->
    Cases = [{<<"echo a=b">>, {1, 7}, <<"unexpected '='">>},
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
             {<<"cat <<EOF\nbody\n">>, {1, 5}, <<"here document is not terminated">>},
             {<<"cat <<EOF">>, {1, 5}, <<"here document is not terminated">>},
             {<<"if(a">>, {1, 5}, <<"expected ')'">>},
             {<<"echo a # c \\\n{">>, {2, 2}, <<"expected '}'">>}],
    [{binary_to_list(Source),
      ?_assertEqual({error, {incomplete, Pos, Message}}, err(Source))}
     || {Source, Pos, Message} <- Cases].

%% Bounds

source_over_64_kib_is_refused_test() ->
    Fits = <<"echo ", (binary:copy(<<"a">>, 65536 - 5))/binary>>,
    ?assertMatch({ok, [_]}, erx_shell_parse:parse(Fits)),
    ?assertEqual({error, {too_long, 65537}}, erx_shell_parse:parse(<<Fits/binary, "a">>)).

nesting_256_deep_parses_and_257_does_not_test() ->
    Nest = fun(N) -> iolist_to_binary([lists:duplicate(N, <<"{">>), <<"a">>,
                                       lists:duplicate(N, <<"}">>)]) end,
    ?assertMatch({ok, [_]}, erx_shell_parse:parse(Nest(256))),
    ?assertEqual({error, {too_deep, {1, 257}}}, erx_shell_parse:parse(Nest(257))).

long_flat_chains_are_not_nesting_test() ->
    Chain = iolist_to_binary(lists:join(<<" | ">>, lists:duplicate(5000, <<"a">>))),
    {ok, [{pipeline, _, Stages}]} = erx_shell_parse:parse(Chain),
    ?assertEqual(4999, length(Stages)).

prefix_chains_count_as_nesting_test() ->
    Prefixes = fun(N) -> iolist_to_binary([lists:duplicate(N, <<"! ">>), <<"a">>]) end,
    ?assertMatch({ok, [_]}, erx_shell_parse:parse(Prefixes(256))),
    ?assertMatch({error, {too_deep, _}}, erx_shell_parse:parse(Prefixes(257))).

format_error_test() ->
    ?assertEqual(<<"syntax error at line 2, column 3: unexpected '}'">>,
                 erx_shell_parse:format_error({syntax, {2, 3}, <<"unexpected '}'">>})),
    ?assertEqual(<<"syntax error: 70000 bytes, over the limit of 65536">>,
                 erx_shell_parse:format_error({too_long, 70000})),
    ?assertEqual(<<"syntax error at line 1, column 9: nested deeper than 256">>,
                 erx_shell_parse:format_error({too_deep, {1, 9}})).

texts_hold_no_reference_to_the_source_test() ->
    Source = <<"echo 'a quoted word' plain $name <<'E'\nbody\nE\n">>,
    {ok, [{simple, Words, [{here, 0, {literal, Body}}]}]} = erx_shell_parse:parse(Source),
    Texts = [Body | [T || {_, T} <- Words, is_binary(T)]] ++ [N || {var, {word, N}} <- Words],
    ?assertEqual(5, length(Texts)),
    [?assertEqual(byte_size(T), binary:referenced_byte_size(T)) || T <- Texts].

diagnostic_quotes_no_source_test() ->
    {error, Diagnostic} = erx_shell_parse:parse(<<"echo \e[31m }">>),
    ?assertEqual(nomatch, binary:match(erx_shell_parse:format_error(Diagnostic), <<"\e">>)).

%% The parse heap a 64 KiB source needs today (TODO.md, "shell, parse
%% heap"): the worst source known, 64 KiB of `a|`, parses within 32 MiB.
worst_source_parses_within_32_mib_test_() ->
    {timeout, 60,
     fun() ->
             Source = <<(binary:copy(<<"a|">>, 32767))/binary, "a">>,
             Words = 32 * 1024 * 1024 div erlang:system_info(wordsize),
             Limit = #{size => Words, kill => true, error_logger => false,
                       include_shared_binaries => true},
             Parse = fun() -> {ok, _} = erx_shell_parse:parse(Source), exit(parsed) end,
             {_, Ref} = spawn_opt(Parse, [monitor, {max_heap_size, Limit}]),
             receive {'DOWN', Ref, process, _, Reason} -> ?assertEqual(parsed, Reason) end
     end}.
