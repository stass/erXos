%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_records_tests).
-moduledoc """
EUnit cases of the command shell's record pipelines (docs/design-shell.md,
"Pipelines" and "Verification and testing"): `where`'s predicates, their
three-valued logic and bounds, `sort` and `count`, the terminal's table,
and whole pipelines of Erlang commands run by the runner to a terminal.
The module is also a command of its own, `recs`, which emits fixed
records, among them ones whose values are `unknown` and `timeout`.
""".

-include_lib("eunit/include/eunit.hrl").

-erx_command(recs).
-erx_usage("recs").
-erx_fields([name, n]).

-export([run/2]).

%%% The test command

run([], Ctx) ->
    [erx_cmd:emit(Ctx, Record) || Record <- records()],
    ok;
run([<<"hostile">>], Ctx) ->
    erx_cmd:emit(Ctx, #{name => ok(<<27, "]0;pwned", 7>>), n => ok(<<27, "[2J">>)}).

records() ->
    [#{name => ok(<<"init">>), n => ok(10)},
     #{name => ok(<<"logger">>), n => {runtime, unknown}},
     #{name => ok(<<"shell">>), n => ok(9)},
     #{name => ok(<<"timer">>), n => {service, {timeout, 500}}},
     #{name => ok(<<"io">>), n => ok(200)}].

ok(Value) -> {runtime, {ok, Value}}.

%%% Predicates

truth(Source, Record) ->
    {ok, Pred} = erx_shell_where:parse(Source),
    erx_shell_where:eval(Pred, Record).

%% For a field `n` holding 10, `n < 9` is false and `n < '9'` is true.
integers_compare_as_numbers_and_text_as_bytes_test() ->
    R = #{n => ok(10), s => ok(<<"abc">>)},
    ?assertEqual(false, truth(<<"n < 9">>, R)),
    ?assertEqual(true, truth(<<"n < '9'">>, R)),
    ?assertEqual(true, truth(<<"n = 10">>, R)),
    ?assertEqual(true, truth(<<"n = 010">>, R)),
    ?assertEqual(false, truth(<<"n = '010'">>, R)),
    ?assertEqual(true, truth(<<"n > -3">>, R)),
    ?assertEqual(true, truth(<<"s >= abc">>, R)),
    ?assertEqual(true, truth(<<"s != abd">>, R)),
    ?assertEqual(true, truth(<<"s < b">>, R)),
    ?assertEqual(false, truth(<<"s = 10">>, R)).

globs_test() ->
    R = #{line => ok(<<"an error here">>), n => ok(123)},
    ?assertEqual(true, truth(<<"line ~ *error*">>, R)),
    ?assertEqual(false, truth(<<"line ~ error">>, R)),
    ?assertEqual(true, truth(<<"n ~ 1?3">>, R)),
    ?assertEqual(true, truth(<<"n ~ [0-9]*">>, R)),
    %% A quoted pattern matches literally, as in rc.
    ?assertEqual(false, truth(<<"line ~ '*error*'">>, R)),
    ?assertEqual(true, truth(<<"line ~ '*error*'">>, #{line => ok(<<"*error*">>)})).

%% A comparison with a value that is not `ok`, or a field the record lacks,
%% is undecided, never true or false.
statuses_are_undecided_test() ->
    Values = [{runtime, unknown}, {kernel, unsupported}, {service, {timeout, 500}},
              {runtime, {partial, 3}}, {runtime, {error, x}}],
    [?assertEqual(undecided, truth(Source, #{n => Value}))
     || Value <- Values,
        Source <- [<<"n = 3">>, <<"n != 3">>, <<"n < 3">>, <<"n ~ *">>, <<"n = '[unknown]'">>]],
    ?assertEqual(undecided, truth(<<"absent = 1">>, #{n => ok(1)})),
    ?assertEqual(undecided, truth(<<"no_such_field_anywhere_xyz = 1">>, #{n => ok(1)})).

%% Kleene's tables of not, and and or over true, false and undecided.
kleene_test_() ->
    Lit = fun(true) -> <<"t = 1">>; (false) -> <<"t = 2">>; (undecided) -> <<"u = 1">> end,
    R = #{t => ok(1), u => {runtime, unknown}},
    Truths = [true, false, undecided],
    Not = fun(true) -> false; (false) -> true; (undecided) -> undecided end,
    And = fun(false, _) -> false; (_, false) -> false; (true, true) -> true; (_, _) -> undecided end,
    Or = fun(true, _) -> true; (_, true) -> true; (false, false) -> false; (_, _) -> undecided end,
    [?_assertEqual(Not(A), truth(<<"not ", (Lit(A))/binary>>, R)) || A <- Truths]
        ++ [?_assertEqual(And(A, B), truth(<<(Lit(A))/binary, " and ", (Lit(B))/binary>>, R))
            || A <- Truths, B <- Truths]
        ++ [?_assertEqual(Or(A, B), truth(<<(Lit(A))/binary, " or ", (Lit(B))/binary>>, R))
            || A <- Truths, B <- Truths].

precedence_test() ->
    R = #{t => ok(1)},
    %% and binds tighter than or.
    ?assertEqual(true, truth(<<"t = 1 or t = 2 and t = 3">>, R)),
    ?assertEqual(false, truth(<<"(t = 1 or t = 2) and t = 3">>, R)),
    ?assertEqual(true, truth(<<"not not t = 1">>, R)).

%% A glob made to backtrack over a 64 KiB field is undecided past its step
%% budget, and decided within it.
glob_step_budget_test_() ->
    {timeout, 120, fun() ->
        Long = binary:copy(<<"a">>, 65536),
        R = #{line => ok(Long)},
        %% At each of the 65,536 places the star tries, 300 bytes match
        %% before the `b` fails: about 2^24.2 steps.
        Pattern = <<"*", (binary:copy(<<"a">>, 300))/binary, "b">>,
        ?assertEqual(undecided, truth(<<"line ~ ", Pattern/binary>>, R)),
        %% A class's members each count a step, so a class of 3,900 tested
        %% at every place is past the budget too, not two steps a place.
        Class = <<"*[", (binary:copy(<<"b">>, 3900))/binary, "]z">>,
        ?assertEqual(undecided, truth(<<"line ~ ", Class/binary>>, R)),
        ?assertEqual(true, truth(<<"line ~ *a">>, R)),
        ?assertEqual(false, truth(<<"line ~ *b">>, R))
    end}.

parse_errors_name_a_byte_and_echo_nothing_test() ->
    Cases = [{<<"">>, <<"expected a field, `not` or `(` at byte 1">>},
             {<<"n">>, <<"expected an operator at byte 2">>},
             {<<"n =">>, <<"expected a value at byte 4">>},
             {<<"n = 'x">>, <<"unterminated quote at byte 5">>},
             {<<"n ! 1">>, <<"`!` without `=` at byte 3">>},
             {<<"(n = 1">>, <<"expected `)` at byte 7">>},
             {<<"n = 1 secret">>, <<"unexpected token at byte 7">>},
             {<<"= 1">>, <<"expected a field, `not` or `(` at byte 1">>}],
    [?assertEqual({error, Want}, erx_shell_where:parse(Source)) || {Source, Want} <- Cases].

bounds_test() ->
    Deep = fun(N) -> iolist_to_binary([lists:duplicate(N, $(), <<"n = 1">>, lists:duplicate(N, $))]) end,
    ?assertMatch({ok, _}, erx_shell_where:parse(Deep(64))),
    ?assertEqual({error, <<"nested deeper than 64 levels at byte 65">>}, erx_shell_where:parse(Deep(65))),
    Nots = fun(N) -> iolist_to_binary([lists:duplicate(N, <<"not ">>), <<"n = 1">>]) end,
    ?assertMatch({ok, _}, erx_shell_where:parse(Nots(64))),
    ?assertMatch({error, <<"nested deeper", _/binary>>}, erx_shell_where:parse(Nots(65))),
    Long = iolist_to_binary([<<"n = '">>, binary:copy(<<"x">>, 4096 - 6), $']),
    ?assertEqual(4096, byte_size(Long)),
    ?assertMatch({ok, _}, erx_shell_where:parse(Long)),
    ?assertEqual({error, <<"predicate longer than 4096 bytes">>},
                 erx_shell_where:parse(<<Long/binary, " ">>)),
    %% A long chain is a list, not a deep tree.
    Chain = iolist_to_binary(lists:join(<<" and ">>, lists:duplicate(400, <<"n=1">>))),
    {ok, {'and', Factors}} = erx_shell_where:parse(Chain),
    ?assertEqual(400, length(Factors)).

%% An unknown field name makes no atom.
parse_makes_no_atom_test() ->
    Name = <<"erx_where_never_an_atom_", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    {ok, _} = erx_shell_where:parse(<<Name/binary, " = 1">>),
    ?assertError(badarg, binary_to_existing_atom(Name)).

%%% The terminal's table

table(Records) ->
    {Out, Table} = lists:foldl(fun({Fields, Record}, {Acc, T}) ->
                                       {Bytes, T1} = erx_render:table_record(Fields, Record, T),
                                       {[Acc, Bytes], T1}
                               end, {[], erx_render:table()}, Records),
    {Rest, _} = erx_render:table_flush(Table),
    iolist_to_binary([Out, Rest]).

%% The widest value of a column, a status among them, sets its width; a
%% column of integers and statuses is aligned right, and the last column is
%% not padded on its right.
table_aligns_columns_under_a_header_test() ->
    ?assertEqual(lines([["name", sp(16), "n"],
                        ["init", sp(15), "10"],
                        ["logger", sp(6), "[unknown]"],
                        ["shell", sp(15), "9"],
                        ["timer", sp(3), "[timeout 500]"],
                        ["io", sp(16), "200"]]),
                 table([{[name, n], R} || R <- records()])).

sp(N) -> lists:duplicate(N, $\s).

lines(Lines) -> iolist_to_binary([[Line, $\n] || Line <- Lines]).

%% Widths are measured on the escaped text, which is what the terminal shows.
table_escapes_values_test() ->
    Hostile = #{a => ok(<<27, "[1m", 16#ff, "\x{202e}"/utf8>>), b => ok(<<"x\ty">>)},
    ?assertEqual(lines([["a", sp(20), "b"], ["\\x1b[1m\\xff\\u{202e}", sp(2), "x\\ty"]]),
                 table([{[a, b], Hostile}])).

table_of_one_column_prints_bare_test() ->
    Lines = [{[line], #{line => ok(<<"one">>)}}, {[line], #{line => ok(<<"two">>)}}],
    ?assertEqual(<<"one\ntwo\n">>, table(Lines)),
    %% Each prints as it comes, held for nothing.
    {Bytes, _} = erx_render:table_record([line], #{line => ok(<<"x">>)}, erx_render:table()),
    ?assertEqual(<<"x\n">>, iolist_to_binary(Bytes)).

%% A record of another shape starts a table of its own; a field the record
%% lacks is not a column.
table_shapes_test() ->
    Out = table([{[name], #{name => ok(<<"dir:">>)}},
                 {[type, size, name], #{type => ok(f), size => ok(3), name => ok(<<"x">>)}},
                 {[type, size, name], #{type => ok(d), size => ok(1024), name => ok(<<"long">>)}}]),
    ?assertEqual(<<"dir:\n"
                   "type  size  name\n"
                   "f        3  x\n"
                   "d     1024  long\n">>, Out).

%% Past 256 held rows the columns are fixed and later rows print at once.
table_holds_at_most_256_rows_test() ->
    Row = fun(N) -> {[a, b], #{a => ok(N), b => ok(<<"v">>)}} end,
    {Held, T1} = lists:foldl(fun(R, {Acc, T}) ->
                                     {Bytes, Next} = erx_render:table_record(element(1, R), element(2, R), T),
                                     {[Acc, Bytes], Next}
                             end, {[], erx_render:table()}, [Row(N) || N <- lists:seq(1, 255)]),
    ?assertEqual(0, iolist_size(Held)),
    {Printed, T2} = erx_render:table_record([a, b], #{a => ok(1), b => ok(<<"v">>)}, T1),
    ?assertEqual(257, length(binary:matches(iolist_to_binary(Printed), <<"\n">>))),
    {Later, _} = erx_render:table_record([a, b], #{a => ok(123456), b => ok(<<"v">>)}, T2),
    ?assertEqual(<<"123456  v\n">>, iolist_to_binary(Later)).

%%% Pipelines through the runner, to a terminal

terminal() ->
    Me = self(),
    {tty, fun(Bytes) -> Me ! {tty, iolist_to_binary(Bytes)}, ok end}.

shown() -> shown([]).

shown(Acc) ->
    receive {tty, Bytes} -> shown([Acc, Bytes])
    after 0 -> iolist_to_binary(Acc)
    end.

run_line(Source) -> run_line(Source, #{inspect => local}).

run_line(Source, Facets) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [?MODULE, erx_cmd_ps, erx_cmd_where, erx_cmd_sort, erx_cmd_count,
                                   erx_cmd_echo, erx_cmd_cat]]),
    Terminal = terminal(),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => Terminal, 2 => Terminal},
                                     table => Table, facets => Facets}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(Source, Shell),
    {erx_shell_eval:status(Done), shown()}.

pipeline_filters_records_test() ->
    ?assertEqual({<<"||">>, <<"name    n\ninit   10\nio    200\n">>},
                 run_line(<<"recs | where 'n > 9' | sort -k name">>)).

%% `where` neither keeps nor coerces a value it cannot compare; `where -u`
%% lists those, and `sort` places them last, with `-r` too.
pipeline_statuses_test() ->
    ?assertEqual({<<"|">>, <<"name    n\nlogger  [unknown]\ntimer   [timeout 500]\n">>},
                 run_line(<<"recs | where -u 'n > 9'">>)),
    Header = ["name", sp(16), "n"],
    Sorted = [["shell", sp(15), "9"], ["init", sp(15), "10"], ["io", sp(16), "200"]],
    Undecided = [["logger", sp(6), "[unknown]"], ["timer", sp(3), "[timeout 500]"]],
    ?assertEqual({<<"|">>, lines([Header] ++ Sorted ++ Undecided)}, run_line(<<"recs | sort -k n">>)),
    ?assertEqual({<<"|">>, lines([Header] ++ lists:reverse(Sorted) ++ Undecided)},
                 run_line(<<"recs | sort -r -k n">>)).

pipeline_count_test() ->
    ?assertEqual({<<"||">>, <<"2\n">>}, run_line(<<"recs | where 'n < 100' | count">>)),
    ?assertEqual({<<>>, <<"0\n">>}, run_line(<<"count">>)).

%% Lines from bytes become `line` records, so `where` filters text.
pipeline_lines_test() ->
    ?assertEqual({<<"|||">>, <<"beta\nalpha\n">>},
                 run_line(<<"echo 'alpha\nbeta\ngamma' | where 'line ~ *a' and 'line != gamma' "
                            "| sort -r | cat">>)).

%% `ps` emits records that `where` and `count` take.
pipeline_ps_test() ->
    {Status, Shown} = run_line(<<"ps | where 'memory > 0' and 'reductions >= 0' | count">>),
    ?assertEqual(<<"||">>, Status),
    ?assert(binary_to_integer(string:trim(Shown)) > 0),
    {_, Table} = run_line(<<"ps | sort -r -k memory">>),
    [Header | _] = binary:split(Table, <<"\n">>),
    ?assertMatch([<<"pid">>, <<"name">>, <<"status">>, <<"memory">>, <<"reductions">>, <<"messages">>],
                 string:lexemes(Header, " ")).

pipeline_usage_and_predicate_errors_test() ->
    ?assertEqual({<<"usage">>, <<"usage: where [-u] predicate ...\n">>}, run_line(<<"where">>)),
    ?assertEqual({<<"usage">>, <<"usage: sort [-r] [-k field] ...\n">>}, run_line(<<"sort -k">>)),
    ?assertEqual({<<"expected a value at byte 4">>, <<"where: expected a value at byte 4\n">>},
                 run_line(<<"where 'n ='">>)).

%% A record reaches the terminal only through the table's escape, whatever
%% stage passes it on: `cat` passes records on as records, never as the
%% bytes of a line, so no control byte of a value reaches the terminal raw.
records_through_cat_are_escaped_test() ->
    {<<>>, Alone} = run_line(<<"recs hostile">>),
    ?assertEqual(nomatch, binary:match(Alone, <<27>>)),
    ?assertEqual({<<"|">>, Alone}, run_line(<<"recs hostile | cat">>)),
    ?assertEqual({<<"||">>, Alone}, run_line(<<"recs hostile | cat | cat -">>)).

%% `sort` without `-k` orders records of different field lists totally: a
%% key list that is a prefix of another sorts first.
sort_orders_keys_of_different_lengths_test() ->
    ?assertEqual({<<"|">>, <<"a\na\n">>}, run_line(<<"{echo a; echo a} | sort">>)),
    {<<"||">>, Shown} = run_line(<<"{recs; echo init} | sort | where 'line = init' or 'name = init'">>),
    ?assertEqual([<<"init">>, <<"name   n">>, <<"init  10">>],
                 binary:split(Shown, <<"\n">>, [global, trim])).
