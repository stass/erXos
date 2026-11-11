%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_text_tests).
-moduledoc """
EUnit cases of the command shell's text commands (docs/design-shell.md,
"Pipelines", "Text commands" and "Verification and testing";
docs/design-live.md, "The command shell"): `sort`'s keys, numbers and
last comparison, `grep`'s translator, options and statuses, `ps`'s
columns and missing values over a fixed table, `ls`'s columns and long
format, and whole lines run by the runner, at a terminal and through a
pipe. The expected bytes follow FreeBSD 15.1's sources as each command
module's documentation cites them.
""".

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

%%% Running a line

%% Runs a line in Dir with its standard output and error at a terminal,
%% answering its status, its output and its error.
run_line(Source, Dir) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_ps, erx_cmd_sort, erx_cmd_grep, erx_cmd_ls, erx_cmd_wc,
                                   erx_cmd_echo, erx_cmd_cat]]),
    State = erx_shell_runner:state(#{cwd => Dir, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> #{} end}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(Source, Shell),
    {erx_shell_eval:status(Done), shown(out), shown(err)}.

sink(Stream) ->
    Me = self(),
    {tty, fun(Bytes) -> Me ! {Stream, iolist_to_binary(Bytes)}, ok end}.

shown(Stream) -> shown(Stream, []).

shown(Stream, Acc) ->
    receive {Stream, Bytes} -> shown(Stream, [Acc, Bytes])
    after 0 -> iolist_to_binary(Acc)
    end.

with_files(Files, Test) ->
    Dir = filename:join(filename:basedir(user_cache, "erx_shell_text_tests"),
                        integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    try
        [ok = file:write_file(filename:join(Dir, Name), Bytes) || {Name, Bytes} <- Files],
        Test(list_to_binary(Dir))
    after
        file:del_dir_r(Dir)
    end.

ends_with(Text, Suffix) ->
    binary:longest_common_suffix([Text, Suffix]) =:= byte_size(Suffix).

%%% sort

sort(Flags, Lines) ->
    {ok, Options} = erx_cmd_sort:options(Flags),
    erx_cmd_sort:sort(Options, Lines).

sort_compares_bytes_test() ->
    ?assertEqual([<<"B">>, <<"a">>, <<"a b">>, <<"ab">>, <<"caf", 16#C3, 16#A9>>],
                 sort([], [<<"ab">>, <<"caf", 16#C3, 16#A9>>, <<"a b">>, <<"B">>, <<"a">>])).

%% A header and `-` compare as zero under -n, among the zeros by the last
%% comparison of whole lines; -5.5 is below -5. A sort -n that put a
%% non-number apart from zero fails here.
sort_numbers_test() ->
    Lines = [<<"x 10">>, <<"y -">>, <<"z 2">>, <<"PID TIME">>, <<"w -5.5">>, <<"v -5">>, <<"u 0">>, <<"t 2.50">>],
    ?assertEqual([<<"w -5.5">>, <<"v -5">>, <<"PID TIME">>, <<"u 0">>, <<"y -">>, <<"z 2">>,
                  <<"t 2.50">>, <<"x 10">>],
                 sort([$n, {$k, <<"2">>}], Lines)),
    ?assertEqual(lists:reverse(sort([$n, {$k, <<"2">>}], Lines)), sort([$n, $r, {$k, <<"2">>}], Lines)),
    ?assertEqual(erx_cmd_sort:number(<<"0">>), erx_cmd_sort:number(<<"-0.00">>)),
    ?assert(erx_cmd_sort:number(<<".5">>) < erx_cmd_sort:number(<<"1">>)),
    ?assert(erx_cmd_sort:number(<<"-0.55">>) < erx_cmd_sort:number(<<"-0.5">>)).

%% A field holds its leading blanks; `-k 2,2` ends at field 2's end.
sort_keys_test() ->
    ?assertEqual(<<" b">>, erx_cmd_sort:key({2, 2}, <<"a b c">>)),
    ?assertEqual(<<" b c">>, erx_cmd_sort:key({2, eol}, <<"a b c">>)),
    ?assertEqual(<<"  b">>, erx_cmd_sort:key({2, 2}, <<" a  b">>)),
    ?assertEqual(<<>>, erx_cmd_sort:key({4, 4}, <<"a b">>)),
    ?assertEqual([<<"x 1 b">>, <<"x 1 c">>, <<"y 2 a">>],
                 sort([{$k, <<"2,2">>}], [<<"y 2 a">>, <<"x 1 c">>, <<"x 1 b">>])).

%% -u keeps the first line of each set of equal keys and turns off the
%% last comparison.
sort_unique_test() ->
    ?assertEqual([<<"1 z">>, <<"2 a">>], sort([$u, {$k, <<"1,1">>}], [<<"2 a">>, <<"1 z">>, <<"1 a">>, <<"2 b">>])),
    ?assertEqual([<<"a">>, <<"b">>], sort([$u], [<<"b">>, <<"a">>, <<"b">>])).

sort_usage_test() ->
    [?assertEqual({Spec, {error, usage}}, {Spec, erx_cmd_sort:options([{$k, Spec}])})
     || Spec <- [<<"0">>, <<"2,1">>, <<"x">>, <<"1.2">>, <<"1n">>, <<>>, <<"999999">>]].

sort_line_test() ->
    with_files([{"f", <<"b\nc\na">>}],
               fun(Dir) ->
                       ?assertEqual({<<>>, <<"a\nb\nc\n">>, <<>>}, run_line(<<"sort f">>, Dir)),
                       ?assertEqual({<<"|">>, <<"c\nb\na\n">>, <<>>}, run_line(<<"cat f | sort -r">>, Dir)),
                       {Status, <<>>, Err} = run_line(<<"sort f missing">>, Dir),
                       ?assertEqual(<<"2">>, Status),
                       ?assertMatch(<<"sort: missing: ", _/binary>>, Err)
               end).

%%% grep's translator

%% A translator that passed `\d` through to `re` would fail the refusals.
translations_test() ->
    Cases = [{<<"a*b">>, bre, <<"a*b">>},
             {<<"*a">>, bre, <<"\\x2Aa">>},
             {<<"^*a$">>, bre, <<"^\\x2Aa$">>},
             {<<"a^b$c">>, bre, <<"a\\x5Eb\\x24c">>},
             {<<"\\(ab\\)\\1">>, bre, <<"(ab)\\g{1}">>},
             {<<"a\\{2,3\\}">>, bre, <<"a{2,3}">>},
             {<<"a\\|b">>, bre, <<"a|b">>},
             {<<"a+?|(b)">>, bre, <<"a\\x2B\\x3F\\x7C\\x28b\\x29">>},
             {<<"a+|b?">>, ere, <<"a+|b?">>},
             {<<"a\\+b\\?">>, bre, <<"a+b?">>},
             {<<"a{,3}">>, ere, <<"a\\x7B\\x2C3\\x7D">>},
             {<<"[^]a-c[:digit:]-]">>, ere, <<"[^\\x5Da-c[:digit:]\\x2D]">>},
             {<<"[\\d]">>, ere, <<"[\\x5Cd]">>},
             {<<"\\w\\<x\\>">>, ere, <<"[[:alnum:]_]\\b(?=\\w)x\\b(?<=\\w)">>},
             {<<"\\.\\*">>, bre, <<"\\x2E\\x2A">>},
             {<<"(*UTF)">>, fixed, <<"\\x28\\x2AUTF\\x29">>},
             {<<>>, ere, <<>>}],
    [?assertEqual({Pattern, Syntax, {ok, Want}}, {Pattern, Syntax, erx_grep_re:translate(Pattern, Syntax)})
     || {Pattern, Syntax, Want} <- Cases].

refusals_test() ->
    Cases = [{<<"\\d">>, ere, <<"trailing backslash (\\)">>},
             {<<"a\\">>, bre, <<"trailing backslash (\\)">>},
             {<<"(a">>, ere, <<"parentheses not balanced">>},
             {<<"a)">>, ere, <<"parentheses not balanced">>},
             {<<"\\(a">>, bre, <<"parentheses not balanced">>},
             {<<"[a">>, bre, <<"brackets ([ ]) not balanced">>},
             {<<"[z-a]">>, bre, <<"invalid character range">>},
             {<<"[[:nope:]]">>, bre, <<"invalid character class">>},
             {<<"*a">>, ere, <<"repetition-operator operand invalid">>},
             {<<"a|+">>, ere, <<"repetition-operator operand invalid">>},
             {<<"a**">>, ere, <<"repetition-operator operand invalid">>},
             {<<"a+?">>, ere, <<"repetition-operator operand invalid">>},
             {<<"a*\\{2\\}">>, bre, <<"repetition-operator operand invalid">>},
             {<<"a{3,2}">>, ere, <<"invalid repetition count(s)">>},
             {<<"a{256}">>, ere, <<"invalid repetition count(s)">>},
             {<<"a{2">>, ere, <<"braces not balanced">>},
             {<<"\\1">>, bre, <<"invalid backreference number">>},
             {<<"\\(a\\1\\)">>, bre, <<"invalid backreference number">>},
             {binary:copy(<<"a">>, 4097), fixed, <<"regular expression too big">>},
             {binary:copy(<<"(">>, 65), ere, <<"regular expression too big">>}],
    [?assertEqual({Pattern, {error, Want}}, {Pattern, erx_grep_re:translate(Pattern, Syntax)})
     || {Pattern, Syntax, Want} <- Cases],
    ?assertMatch({ok, _}, erx_grep_re:translate(binary:copy(<<"a">>, 4096), fixed)).

%% Every translation compiles in `re`.
translations_compile_test() ->
    [begin
         {ok, Source} = erx_grep_re:translate(Pattern, Syntax),
         ?assertMatch({ok, _}, re:compile(Source, erx_grep_re:options(#{ignore_case => false})))
     end || {Pattern, Syntax} <- [{<<"\\(a*\\)*\\1">>, bre}, {<<"(a|b)+[[:space:]]{2}$">>, ere},
                                  {<<"a{0,255}">>, ere}, {<<"[]-]">>, bre}]].

%%% grep

%% A grep that exited 0 on no match would fail the second case.
grep_test() ->
    with_files([{"f", <<"alpha\nBeta\ngamma 42\nlast">>}, {"g", <<"beta\n">>}],
               fun(Dir) ->
                       G = fun(Line) -> run_line(Line, Dir) end,
                       ?assertEqual({<<>>, <<"alpha\nBeta\ngamma 42\n">>, <<>>}, G(<<"grep 'a$\\|[0-9]' f">>)),
                       ?assertEqual({<<"1">>, <<>>, <<>>}, G(<<"grep 'a$|[0-9]' f">>)),
                       ?assertEqual({<<>>, <<"alpha\nBeta\ngamma 42\n">>, <<>>}, G(<<"grep -E 'a$|[0-9]' f">>)),
                       ?assertEqual({<<>>, <<"2:Beta\n">>, <<>>}, G(<<"grep -in beta f">>)),
                       ?assertEqual({<<>>, <<"f:Beta\ng:beta\n">>, <<>>}, G(<<"grep -i beta f g">>)),
                       ?assertEqual({<<>>, <<"f:3\ng:0\n">>, <<>>}, G(<<"grep -vc e f g">>)),
                       ?assertEqual({<<>>, <<"last\n">>, <<>>}, G(<<"grep -F 'st' f">>)),
                       ?assertEqual({<<>>, <<"g\n">>, <<>>}, G(<<"grep -l '^b' f g">>)),
                       ?assertEqual({<<>>, <<>>, <<>>}, G(<<"grep -q a f missing">>)),
                       ?assertEqual({<<"|">>, <<"Beta\n">>, <<>>}, G(<<"cat f | grep B">>)),
                       {<<"2">>, <<"f:alpha\n">>, Missing} = G(<<"grep alpha f missing">>),
                       ?assertMatch(<<"grep: missing: ", _/binary>>, Missing),
                       ?assertEqual({<<"2">>, <<>>, <<"grep: trailing backslash (\\)\n">>}, G(<<"grep '\\d' f">>)),
                       ?assertMatch({<<"usage">>, <<>>, <<"usage: grep", _/binary>>}, G(<<"grep">>))
               end).

%% A pattern built to backtrack ends grep with status 2 within the limit.
grep_too_complex_test_() ->
    {timeout, 60,
     fun() ->
             with_files([{"f", <<(binary:copy(<<"a">>, 40))/binary, "\n">>}],
                        fun(Dir) ->
                                ?assertEqual({<<"2">>, <<>>, <<"grep: pattern too complex\n">>},
                                             run_line(<<"grep -E '(a|aa)*[^a]' f">>, Dir))
                        end)
     end}.

%% A line over 64 KiB fails the stage with `line too long`.
grep_line_too_long_test() ->
    with_files([{"f", binary:copy(<<"x">>, 70000)}],
               fun(Dir) ->
                       {Status, <<>>, _} = run_line(<<"cat f | grep y">>, Dir),
                       ?assert(ends_with(Status, <<"|line too long">>)),
                       {Status2, <<>>, _} = run_line(<<"grep y f">>, Dir),
                       ?assertEqual(<<"line too long">>, Status2)
               end).

%%% ps

row(N, Values) ->
    maps:merge(#{id => [0, N, 0], pid => iolist_to_binary(["<0.", integer_to_binary(N), ".0>"]),
                 tt => missing, state => <<"S">>, time => missing, pcpu => missing, rss => 4 * N,
                 comm => <<"p", (integer_to_binary(N))/binary>>,
                 command => <<"p", (integer_to_binary(N))/binary>>}, Values).

ps_default_columns_test() ->
    Rows = erx_cmd_ps:order([row(12, #{}), row(3, #{state => <<"R">>})], none),
    ?assertEqual(<<"     PID TT STAT TIME COMMAND\n",
                   " <0.3.0> -  R       - p3\n",
                   "<0.12.0> -  S       - p12\n">>,
                 iolist_to_binary(erx_cmd_ps:table([pid, tt, state, time, command], Rows, infinity))).

%% Each missing value prints `-` and every row keeps its columns; under
%% -m and -r the rows without the value come last, in pid order. A
%% formatter that printed 0 or dropped the column would fail.
ps_missing_values_test() ->
    Rows = [row(1, #{rss => missing}), row(2, #{}), row(3, #{state => missing, comm => missing}),
            row(4, #{pcpu => 1.5}), row(5, #{pcpu => 20.0})],
    Text = iolist_to_binary(erx_cmd_ps:table([pid, state, time, pcpu, rss, comm],
                                             erx_cmd_ps:order(Rows, rss), infinity)),
    [Header | Lines] = binary:split(Text, <<"\n">>, [global, trim]),
    ?assertEqual(<<"    PID STAT TIME %CPU RSS COMMAND">>, Header),
    ?assertEqual([<<"<0.5.0>">>, <<"<0.4.0>">>, <<"<0.3.0>">>, <<"<0.2.0>">>, <<"<0.1.0>">>],
                 [hd(binary:split(Line, <<" ">>, [global, trim_all])) || Line <- Lines]),
    [?assertEqual(6, length(binary:split(Line, <<" ">>, [global, trim_all]))) || Line <- Lines],
    ?assertEqual(<<"<0.3.0> -       -    -  12 -">>, lists:nth(3, Lines)),
    ?assertEqual(<<"<0.1.0> S       -    -   - p1">>, lists:nth(5, Lines)),
    ?assertEqual([5, 4, 1, 2, 3], [N || #{id := [0, N, 0]} <- erx_cmd_ps:order(Rows, pcpu)]).

ps_keywords_test() ->
    ?assertEqual({[pid, state, pcpu, command], [<<"nope">>]}, erx_cmd_ps:keywords(<<"pid,stat,%cpu,nope,args">>)),
    {Status, Out, Err} = run_line(<<"ps -o pid,nope">>, <<"/">>),
    ?assertEqual(<<"1">>, Status),
    ?assertEqual(<<"ps: nope: keyword not found\n">>, Err),
    ?assertEqual(<<"PID">>, string:trim(hd(binary:split(Out, <<"\n">>)))).

ps_cuts_at_the_terminal_width_test() ->
    Text = iolist_to_binary(erx_cmd_ps:table([pid, command], [row(1, #{command => binary:copy(<<"x">>, 100)})], 20)),
    ?assertEqual([<<"    PID COMMAND">>, <<"<0.1.0> xxxxxxxxxxxx">>], binary:split(Text, <<"\n">>, [global, trim])).

%% Names go through the field escape at a terminal and in a pipe alike.
ps_escapes_names_test() ->
    Name = <<27, "]8;;x", 7, "\ta\n", 16#E2, 16#80, 16#AE>>,
    register(binary_to_atom(Name, utf8), self()),
    try
        {_, Out, _} = run_line(<<"ps -o comm">>, <<"/">>),
        {_, Piped, _} = run_line(<<"ps -o comm | cat">>, <<"/">>),
        Escaped = erx_text:escape_field(Name),
        ?assertNotEqual(nomatch, binary:match(Out, Escaped)),
        ?assertNotEqual(nomatch, binary:match(Piped, Escaped)),
        [?assertEqual(nomatch, binary:match(Text, [<<27>>, <<7>>, <<"\t">>])) || Text <- [Out, Piped]]
    after
        unregister(binary_to_atom(Name, utf8))
    end.

%%% ls

ls_columns_test() ->
    Names = [<<"a">>, <<"bbbbbbbbb">>, <<"c">>, <<"d">>, <<"e">>],
    ?assertEqual(<<"a\t\td\nbbbbbbbbb\te\nc\n">>, iolist_to_binary(erx_cmd_ls:columns(Names, 40))),
    ?assertEqual(<<"a\nbbbbbbbbb\nc\nd\ne\n">>, iolist_to_binary(erx_cmd_ls:columns(Names, 20))).

ls_long_test() ->
    Now = 1_800_000_000,
    Recent = #file_info{type = regular, mode = 8#100644, links = 1, uid = 0, gid = 0, size = 1234,
                        mtime = Now - 3600},
    Old = Recent#file_info{type = directory, mode = 8#41777, links = 12, uid = undefined, size = 5,
                           mtime = Now - 400 * 86400},
    ?assertEqual(<<"-rw-r--r--   1 0 0 1234 Jan 15 07:00 f\n",
                   "drwxrwxrwt  12 - 0    5 Dec 11  2025 d\n",
                   "?---------   - - -    - - u\n">>,
                 iolist_to_binary(erx_cmd_ls:long([{<<"f">>, Recent}, {<<"d">>, Old}, {<<"u">>, unknown}],
                                                  #{now => Now}))).

%% At a terminal names are in columns and escaped; through a pipe one a
%% line, as their bytes. A single directory has no heading, and an ls that
%% ignored erx_cmd:isatty/2 would fail the second case.
ls_line_test() ->
    Odd = <<"x", 27, "[2Jy">>,
    Columns = iolist_to_binary(erx_cmd_ls:columns([<<"a">>, <<"b">>, erx_text:escape_line(Odd)], 80)),
    with_files([{"b", <<>>}, {"a", <<>>}, {".h", <<>>}, {binary_to_list(Odd), <<>>}],
               fun(Dir) ->
                       ?assertEqual({<<>>, Columns, <<>>}, run_line(<<"ls">>, Dir)),
                       ?assertEqual({<<"|">>, <<"a\nb\n", Odd/binary, "\n">>, <<>>}, run_line(<<"ls | cat">>, Dir)),
                       ?assertEqual({<<>>, <<".h\na\nb\n", (erx_text:escape_line(Odd))/binary, "\n">>, <<>>},
                                    run_line(<<"ls -1a">>, Dir)),
                       ?assertEqual({<<>>, <<"a\n\n.:\n", Columns/binary>>, <<>>}, run_line(<<"ls a .">>, Dir)),
                       {<<"1">>, <<>>, Err} = run_line(<<"ls missing">>, Dir),
                       ?assertMatch(<<"ls: missing: ", _/binary>>, Err)
               end).

%% Lines a reader keeps hold only their own bytes: a megabyte of 100-byte
%% lines through a pipe into sort stays within the stage's heap limit,
%% which a line sharing the pipe's 64 KiB buffer would exceed at 128 KB.
sort_keeps_lines_within_its_heap_test_() ->
    {timeout, 120,
     fun() ->
             Lines = [[integer_to_binary(100000 + N rem 9973), binary:copy(<<"x">>, 93), $\n]
                      || N <- lists:seq(1, 10486)],
             Bytes = iolist_to_binary(Lines),
             with_files([{"f", Bytes}],
                        fun(Dir) ->
                                {Status, Out, Err} = run_line(<<"cat f | sort">>, Dir),
                                ?assertEqual({<<"|">>, <<>>}, {Status, Err}),
                                ?assertEqual(byte_size(Bytes), byte_size(Out))
                        end)
     end}.
