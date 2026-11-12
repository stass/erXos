%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_top_tests).
-moduledoc """
EUnit cases of the command shell's `top` (erx_cmd_top, docs/design-live.md,
"The command shell"): its options and FreeBSD's warnings, the share of a
CPU from two samples, the layout of a display over a fixed table, the
time and size formats of FreeBSD's usr.bin/top/utils.c, and whole lines
run by the runner, in batch and at a terminal, with names escaped.
""".

-include_lib("eunit/include/eunit.hrl").

%%% Running a line

%% Runs a line with the given variables, its standard output and error at
%% a terminal, answering its status, its output and its error.
run_line(Source, Vars) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_top, erx_cmd_cat]]),
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> #{} end}),
    Shell = erx_shell_eval:new(Vars, erx_shell_runner:runner(), State),
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

lines(Text) -> binary:split(Text, <<"\n">>, [global, trim]).

%%% Options

options_defaults_test() ->
    Defaults = #{batch => false, displays => default, delay_ms => 2000, topn => default},
    ?assertEqual({ok, Defaults, []}, erx_cmd_top:options([])),
    ?assertEqual({ok, Defaults#{batch := true}, []}, erx_cmd_top:options([<<"-b">>])),
    ?assertEqual({ok, Defaults#{batch := true}, []}, erx_cmd_top:options([<<"-n">>])).

options_values_test() ->
    {ok, Options, []} = erx_cmd_top:options([<<"-bd">>, <<"3">>, <<"-s0.25">>, <<"10">>, <<"ignored">>]),
    ?assertEqual(#{batch => true, displays => 3, delay_ms => 250, topn => 10}, Options),
    ?assertMatch({ok, #{displays := infinity, topn := infinity}, []},
                 erx_cmd_top:options([<<"-d">>, <<"inf">>, <<"all">>])),
    ?assertMatch({ok, #{displays := 5, topn := 7}, []}, erx_cmd_top:options([<<"-d">>, <<" +5">>, <<"+7">>])),
    ?assertMatch({ok, #{delay_ms := 1}, []}, erx_cmd_top:options([<<"-s">>, <<"0.0001">>])),
    ?assertMatch({ok, #{delay_ms := 1500}, []}, erx_cmd_top:options([<<"-s">>, <<"1.5009">>])),
    ?assertMatch({ok, #{delay_ms := 500}, []}, erx_cmd_top:options([<<"-s">>, <<".5">>])),
    ?assertMatch({ok, #{delay_ms := 16#FFFFFFFF}, []}, erx_cmd_top:options([<<"-s">>, <<"99999999999">>])),
    ?assertMatch({ok, #{delay_ms := 3000}, []}, erx_cmd_top:options([<<"-s">>, <<"\t+3x">>])).

%% Each bad value is FreeBSD's warning and leaves the default in place,
%% bytes that are not UTF-8 included.
options_warnings_test() ->
    {ok, Options, Warnings} = erx_cmd_top:options([<<"-d">>, <<"0">>, <<"-s">>, <<"0.000">>, <<"-s">>, <<"x">>,
                                                    <<"-s">>, <<"-1">>, <<"-s">>, <<255, "3">>,
                                                    <<"-d">>, <<"-2">>, <<"--">>, <<"-5">>]),
    ?assertEqual(#{batch => false, displays => default, delay_ms => 2000, topn => default}, Options),
    ?assertEqual([<<"display count should be positive -- option ignored">>,
                  <<"seconds delay should be positive -- using default">>,
                  <<"invalid delay">>,
                  <<"seconds delay should be positive -- using default">>,
                  <<"invalid delay">>,
                  <<"display count should be positive -- option ignored">>,
                  <<"process display count should be non-negative -- using default">>], Warnings),
    ?assertEqual({error, usage}, erx_cmd_top:options([<<"-x">>])),
    ?assertEqual({error, usage}, erx_cmd_top:options([<<"-d">>])).

count_test() ->
    ?assertEqual(0, erx_cmd_top:count(<<>>)),
    ?assertEqual(infinity, erx_cmd_top:count(<<"i">>)),
    ?assertEqual(infinity, erx_cmd_top:count(<<"max">>)),
    ?assertEqual(invalid, erx_cmd_top:count(<<"-1">>)),
    ?assertEqual(12, erx_cmd_top:count(<<"12abc">>)),
    ?assertEqual(12, erx_cmd_top:count(<<" \n+12">>)),
    ?assertEqual(0, erx_cmd_top:count(<<"abc">>)),
    ?assertEqual(0, erx_cmd_top:count(<<"alls">>)).

%% Output that is not a terminal, or -b, gets one display of at most 18
%% processes; a screen gets displays until Ctrl-C, as many processes as
%% fit. Values given on the line stand either way.
plan_test() ->
    {ok, Defaults, []} = erx_cmd_top:options([]),
    ?assertEqual(#{screen => true, displays => infinity, delay_ms => 2000, topn => infinity},
                 erx_cmd_top:plan(Defaults, true)),
    Batch = #{screen => false, displays => 1, delay_ms => 2000, topn => 18},
    ?assertEqual(Batch, erx_cmd_top:plan(Defaults, false)),
    ?assertEqual(Batch, erx_cmd_top:plan(Defaults#{batch := true}, true)),
    ?assertEqual(Batch#{displays := 4, topn := infinity},
                 erx_cmd_top:plan(Defaults#{displays := 4, topn := infinity}, false)).

%%% Shares

row(N, Values) ->
    maps:merge(#{id => [0, N, 0], pid => iolist_to_binary(["<0.", integer_to_binary(N), ".0>"]),
                 tt => missing, state => <<"S">>, time => missing, pcpu => missing, rss => 4 * N,
                 comm => <<"p", (integer_to_binary(N))/binary>>,
                 command => <<"p", (integer_to_binary(N))/binary>>}, Values).

wcpus(Rows) -> [{N, Wcpu} || #{id := [0, N, 0], wcpu := Wcpu} <- Rows].

%% The first display has no interval and shows the share since start.
shares_first_display_test() ->
    Rows = [row(1, #{time => 10, pcpu => 0.5}), row(2, #{}), row(3, #{time => 20, pcpu => 7.0})],
    ?assertEqual([{3, 7.0}, {1, 0.5}, {2, missing}], wcpus(erx_cmd_top:shares(none, {100, Rows}))).

%% Over 1.6 seconds between samples, 0.4 seconds of CPU time is 25%; a
%% row the previous sample did not have, and one whose time went down,
%% show the share since start; a row without a time shows none. A share
%% over the nominal 2-second delay, or from lifetime figures, would fail.
shares_interval_test() ->
    Before = [row(1, #{time => 1000000}), row(2, #{time => 5000000}), row(4, #{})],
    ?assertEqual(#{<<"<0.1.0>">> => 1000000, <<"<0.2.0>">> => 5000000}, erx_cmd_top:cpu_times(Before)),
    After = [row(1, #{time => 1400000, pcpu => 1.0}), row(2, #{time => 100, pcpu => 3.0}),
             row(3, #{time => 9, pcpu => 2.0}), row(4, #{})],
    ?assertEqual([{1, 25.0}, {2, 3.0}, {3, 2.0}, {4, missing}],
                 wcpus(erx_cmd_top:shares({0, erx_cmd_top:cpu_times(Before)}, {1600000, After}))).


%%% Displays

layout(MaxRows, Width) -> #{max_rows => MaxRows, width => Width, clock => {1, 2, 3}}.

display(Rows, Layout) -> display(Rows, #{}, Layout).

display(Rows, System, Layout) ->
    iolist_to_binary(erx_cmd_top:display(erx_cmd_top:shares(none, {0, Rows}), System, Layout)).

%% The system's figures as the inspector answers them, of every status.
system() ->
    #{uptime => {kernel, {ok, ((2 * 24 + 3) * 3600 + 4 * 60 + 5) * 1000000000 + 999}},
      run_queue => {runtime, {ok, 3}},
      memory_total => {kernel, {ok, 2048 * 1048576}},
      memory_free => {{stopgap, liberx_pool}, {partial, 4096}},
      domain => 4,
      used => {{stopgap, liberx_pool}, {partial, 30}},
      guarantee => {kernel, {ok, 256}},
      cap => {kernel, unsupported}}.

%% Without figures every value of the header is `-`, and each line says
%% that nobody reported its figures.
display_test() ->
    Rows = [row(3, #{state => <<"R">>, time => 61000000, pcpu => 12.5}), row(12, #{rss => 20000}),
            row(5, #{state => missing, rss => missing, comm => missing}), row(7, #{state => <<"T">>})],
    ?assertEqual(<<"run queue [not reported]: -;  up [not reported] -    01:02:03\n",
                   "4 processes:   1 running, 1 sleeping, 1 stopped\n",
                   "Mem [not reported]: - Total, - Free\n",
                   "Domain budget [not reported]: - Used, - Guarantee, - Cap\n",
                   "\n",
                   "    PID    RES STATE    TIME    WCPU COMMAND\n",
                   "<0.3.0>    12K RUN      1:01  12.50% p3\n",
                   "<0.5.0>      - -           -       - -\n",
                   "<0.7.0>    28K STOP        -       - p7\n">>,
                 display(Rows, layout(3, infinity))),
    ?assertEqual(<<"1 processes:   1 sleeping">>, lists:nth(2, lines(display([row(1, #{})], layout(0, infinity))))).

%% The header shows each figure the inspector answers ok in FreeBSD's
%% format, a partial one with its reporter named after it where the line
%% has numbers of other reporters or statuses, and `-` with its status for
%% every other status, so a partial count never reads as exact; the budget
%% line names its domain.
display_system_test() ->
    [First, _States, Mem, Budget, <<>> | _] = lines(display([row(1, #{})], system(), layout(0, infinity))),
    ?assertEqual(<<"run queue: 3;  up 2+03:04:05    01:02:03">>, First),
    ?assertEqual(<<"Mem: 2048M Total, 4K Free (root pool)">>, Mem),
    ?assertEqual(<<"Domain 4 budget: 120K Used (root pool), 1024K Guarantee, - Cap [unsupported]">>, Budget),
    Other = (system())#{run_queue := {runtime, unknown}, uptime := {kernel, {timeout, 500}},
                        memory_free := {kernel, unsupported}, used := {{stopgap, liberx_pool}, {error, gone}}},
    [Missing, _, NoMem, NoBudget | _] = lines(display([], Other, layout(0, infinity))),
    ?assertEqual(<<"run queue [unknown]: -;  up [timeout 500] -    01:02:03">>, Missing),
    ?assertEqual(<<"Mem: 2048M Total, - Free [unsupported]">>, NoMem),
    ?assertEqual(<<"Domain 4 budget: - Used [error], 1024K Guarantee, - Cap [unsupported]">>, NoBudget).

%% A figure whose path the inspector refused says the refusal, once in the
%% line's label when every figure of the line shares it.
display_refusals_test() ->
    Refused = fun(Reason) -> {missing, {error, Reason}} end,
    System = (system())#{memory_total := Refused(busy), memory_free := Refused(busy),
                         used := Refused(scope), guarantee := Refused(scope), cap := Refused(scope),
                         run_queue := {missing, not_reported}, uptime := Refused(no_facet)},
    [First, _, Mem, Budget | _] = lines(display([], System, layout(0, infinity))),
    ?assertEqual(<<"run queue [not reported]: -;  up [no inspect facet] -    01:02:03">>, First),
    ?assertEqual(<<"Mem [inspector busy]: - Total, - Free">>, Mem),
    ?assertEqual(<<"Domain 4 budget [not in scope]: - Used, - Guarantee, - Cap">>, Budget),
    Mixed = System#{memory_free := Refused(failed)},
    ?assertEqual(<<"Mem: - Total [inspector busy], - Free [failed]">>,
                 lists:nth(3, lines(display([], Mixed, layout(0, infinity))))).

%% A line whose every number is partial under one reporter names it once,
%% in its label, and marks no figure; `-` figures do not count.
display_line_reporter_test() ->
    Pool = (system())#{memory_total := {{stopgap, liberx_pool}, {partial, 118 * 1048576}},
                       memory_free := {{stopgap, liberx_pool}, {partial, 74 * 1048576}},
                       guarantee := {kernel, unsupported}},
    [_, _, Mem, Budget | _] = lines(display([], Pool, layout(0, infinity))),
    ?assertEqual(<<"Mem (root pool): 118M Total, 74M Free">>, Mem),
    ?assertEqual(<<"Domain 4 budget (root pool): 120K Used, - Guarantee [unsupported], - Cap [unsupported]">>, Budget).

%% Each header figure in turn under each status: unknown, unsupported,
%% timed out and failed print as an absent figure does, `-` with the
%% status in place of `[not reported]`, and partial names its reporter
%% exactly once, beside an `ok` number of the same reporter.
display_every_status_test() ->
    Exact = #{uptime => {kernel, {ok, 0}}, run_queue => {kernel, {ok, 3}}, memory_total => {kernel, {ok, 1024}},
              memory_free => {kernel, {ok, 1024}}, domain => 4, used => {kernel, {ok, 1}},
              guarantee => {kernel, {ok, 1}}, cap => {kernel, {ok, 1}}},
    Header = fun(System) -> iolist_to_binary(lists:join($\n, lists:sublist(lines(display([], System, layout(0, infinity))), 4))) end,
    [?assertEqual(binary:replace(Header(maps:remove(Key, Exact)), <<"[not reported]">>, Said),
                  Header(Exact#{Key := {kernel, Status}}))
     || Key <- maps:keys(Exact), Key =/= domain,
        {Status, Said} <- [{unknown, <<"[unknown]">>}, {unsupported, <<"[unsupported]">>},
                           {{timeout, 500}, <<"[timeout 500]">>}, {{error, gone}, <<"[error]">>}]],
    [?assertEqual(1, length(binary:matches(iolist_to_binary(Header(Exact#{Key := {kernel, {partial, 2}}})),
                                           <<"(kernel)">>)))
     || Key <- maps:keys(Exact), Key =/= domain].

%% A partial figure beside an `ok` one of the same reporter names its
%% reporter itself, so the line's label never makes the `ok` one partial.
display_same_reporter_test() ->
    Mixed = (system())#{memory_total := {{stopgap, liberx_pool}, {ok, 2048 * 1048576}}},
    ?assertEqual(<<"Mem: 2048M Total, 4K Free (root pool)">>,
                 lists:nth(3, lines(display([], Mixed, layout(0, infinity))))).

%% A line of ok figures is FreeBSD's, with no reporter named.
display_ok_test() ->
    Exact = (system())#{memory_free := {kernel, {ok, 74 * 1048576}}, used := {kernel, {ok, 30}},
                        cap := {kernel, {ok, 512}}},
    [_, _, Mem, Budget | _] = lines(display([], Exact, layout(0, infinity))),
    ?assertEqual(<<"Mem: 2048M Total, 74M Free">>, Mem),
    ?assertEqual(<<"Domain 4 budget: 120K Used, 1024K Guarantee, 2048K Cap">>, Budget).

%% Partial figures of two reporters on one line each name their own; a
%% figure alone in its label names its reporter there.
display_reporters_test() ->
    Two = (system())#{memory_total := {kernel, {partial, 1048576}}, run_queue := {runtime, {partial, 3}},
                      uptime := {kernel, {partial, 61000000000}}},
    [First, _, Mem | _] = lines(display([], Two, layout(0, infinity))),
    ?assertEqual(<<"Mem: 1024K Total (kernel), 4K Free (root pool)">>, Mem),
    ?assertEqual(<<"run queue (runtime): 3;  up (kernel) 0+00:01:01    01:02:03">>, First).

format_uptime_test() ->
    ?assertEqual(<<"0+00:00:00">>, erx_cmd_top:format_uptime(999999999)),
    ?assertEqual(<<"1+00:00:59">>, erx_cmd_top:format_uptime((86400 + 59) * 1000000000)).

display_cuts_lines_test() ->
    Text = display([row(1, #{comm => <<"abcd", 16#C3, 16#A9, "f">>})], layout(1, 42)),
    ?assertEqual(<<"<0.1.0>     4K SLEEP       -       - abcd">>, lists:last(lines(Text))),
    [?assert(byte_size(Line) =< 42) || Line <- lines(Text)].

format_time_test() ->
    ?assertEqual(<<"0:00">>, erx_cmd_top:format_time(999999)),
    ?assertEqual(<<"16:39">>, erx_cmd_top:format_time(999 * 1000000)),
    ?assertEqual(<<"999:59">>, erx_cmd_top:format_time(59999 * 1000000)),
    ?assertEqual(<<"16.7H">>, erx_cmd_top:format_time(60000 * 1000000)),
    ?assertEqual(<<"???">>, erx_cmd_top:format_time(99999 * 360 * 1000000 + 1000000)).

format_k_test() ->
    ?assertEqual(<<"0K">>, erx_cmd_top:format_k(0)),
    ?assertEqual(<<"9999K">>, erx_cmd_top:format_k(9999)),
    ?assertEqual(<<"10M">>, erx_cmd_top:format_k(10000)),
    ?assertEqual(<<"1024M">>, erx_cmd_top:format_k(1048576)),
    ?assertEqual(<<"9766M">>, erx_cmd_top:format_k(10000000)),
    ?assertEqual(<<"95G">>, erx_cmd_top:format_k(100000000)).

%% ps writes a CPU time as `M:SS.hh`, rounded to the hundredth.
ps_time_test() ->
    Rows = [row(1, #{time => 4999}), row(2, #{time => 995000}), row(3, #{time => 61500000})],
    ?assertEqual(<<"   TIME\n0:00.00\n0:01.00\n1:01.50\n">>,
                 iolist_to_binary(erx_cmd_ps:table([time], Rows, infinity))).

%% A cut never splits a UTF-8 sequence, in ps's table as in top's.
ps_cut_test() ->
    ?assertEqual(<<"ab">>, erx_cmd_ps:cut(<<"ab", 16#C3, 16#A9>>, 3)),
    ?assertEqual(<<"ab", 16#C3, 16#A9>>, erx_cmd_ps:cut(<<"ab", 16#C3, 16#A9, "c">>, 4)),
    ?assertEqual(<<"ab", 16#FF>>, erx_cmd_ps:cut(<<"ab", 16#FF, 16#FF>>, 3)).

%%% Lines

%% Batch writes one display of the live table and no control sequence;
%% two displays are a blank line apart.
top_batch_test() ->
    {Status, Out, Err} = run_line(<<"top -b">>, #{}),
    ?assertEqual({<<>>, <<>>}, {Status, Err}),
    [First, States, Mem, Budget, <<>>, Header | Rows] = lines(Out),
    ?assertMatch({match, _}, re:run(First, <<"^run queue \\[no inspect facet\\]: -;  up \\[no inspect facet\\] -    "
                                              "\\d\\d:\\d\\d:\\d\\d$">>)),
    ?assertEqual({<<"Mem [no inspect facet]: - Total, - Free">>,
                  <<"Domain budget [no inspect facet]: - Used, - Guarantee, - Cap">>}, {Mem, Budget}),
    ?assertMatch({match, _}, re:run(States, <<"^\\d+ processes: +\\d+ ">>)),
    ?assertMatch({match, _}, re:run(Header, <<"^ +PID    RES STATE    TIME    WCPU COMMAND$">>)),
    ?assertEqual(18, length(Rows)),
    ?assertEqual(nomatch, binary:match(Out, <<27>>)),
    {<<>>, Two, <<>>} = run_line(<<"top -b -d 2 -s 0.01 1">>, #{}),
    ?assertMatch([_, _, _, _, <<>>, _, _, <<>>, _, _, _, _, <<>>, _, _], lines(Two)).

%% The header asks the session's facet for the machine's record, top's own
%% process's, and its domain's and that domain's budget, and says why each
%% figure it did not get is missing: here the budget's path is out of the
%% facet's scope and the domain's record holds no run queue.
top_header_reads_the_facet_test() ->
    Answers = fun([]) -> {ok, #{attrs => #{uptime => {kernel, {ok, 61000000000}},
                                           memory_total => {kernel, {ok, 2048 * 1048576}},
                                           memory_free => {{stopgap, liberx_pool}, {partial, 1048576}}}}};
                 ([processes, _Self]) -> {ok, #{attrs => #{domain => {kernel, {ok, 8}}}}};
                 ([domains, 8]) -> {ok, #{attrs => #{}}};
                 ([domains, 8, budget]) -> {error, scope}
              end,
    persistent_term:put(erx_inspector, Answers),
    try
        {<<>>, Out, <<>>} = run_line(<<"top -b">>, #{}),
        [First, _States, Mem, Budget | _] = lines(Out),
        ?assertMatch({match, _}, re:run(First, <<"^run queue \\[not reported\\]: -;  up 0\\+00:01:01    ">>)),
        ?assertEqual(<<"Mem: 2048M Total, 1024K Free (root pool)">>, Mem),
        ?assertEqual(<<"Domain 8 budget [not in scope]: - Used, - Guarantee, - Cap">>, Budget)
    after
        persistent_term:erase(erx_inspector)
    end.

%% At a terminal each display starts with home and clear and fills the
%% terminal's height, less the cursor's line, each line within its width.
top_terminal_test() ->
    Vars = #{<<"LINES">> => [<<"10">>], <<"COLUMNS">> => [<<"30">>]},
    {<<>>, Out, <<>>} = run_line(<<"top -d 2 -s 0.01">>, Vars),
    [<<>>, First, Second] = binary:split(Out, <<"\e[H\e[2J">>, [global]),
    [?assertEqual(9, length(lines(Display))) || Display <- [First, Second]],
    [?assert(byte_size(Line) =< 29) || Display <- [First, Second], Line <- lines(Display)].

%% Output that is not a terminal gets one display without -b, and the
%% line ends: a top that kept drawing into a pipe would never let cat end.
top_pipe_test() ->
    {Status, Out, <<>>} = run_line(<<"top -s 0.01 2 | cat">>, #{}),
    ?assertEqual(<<"|">>, Status),
    ?assertEqual(8, length(lines(Out))),
    ?assertEqual(nomatch, binary:match(Out, <<27>>)).

top_options_line_test() ->
    ?assertMatch({<<"usage">>, <<>>, <<"usage: top [-bn] [-d count] [-s time] [number]\n">>},
                 run_line(<<"top -x">>, #{})),
    {<<>>, _, Err} = run_line(<<"top -b -s nope 0">>, #{}),
    ?assertEqual(<<"top: warning: invalid delay\n">>, Err).

%% Names go through the field escape: none of a name's controls reach the
%% terminal, in batch or on the screen.
top_escapes_names_test() ->
    Name = <<27, "]8;;x", 7, "\ta\n", 16#E2, 16#80, 16#AE>>,
    register(binary_to_atom(Name, utf8), self()),
    try
        {_, Batch, _} = run_line(<<"top -b all">>, #{}),
        {_, Screen, _} = run_line(<<"top -d 1 all">>, #{<<"LINES">> => [<<"100000">>], <<"COLUMNS">> => [<<"1000">>]}),
        Escaped = erx_text:escape_field(Name),
        [?assertNotEqual(nomatch, binary:match(Text, Escaped)) || Text <- [Batch, Screen]],
        ?assertEqual(nomatch, binary:match(Batch, [<<27>>, <<7>>, <<"\t">>])),
        ?assertEqual(nomatch, binary:match(binary:replace(Screen, <<"\e[H\e[2J">>, <<>>), [<<27>>, <<7>>, <<"\t">>]))
    after
        unregister(binary_to_atom(Name, utf8))
    end.

%% ps's table cut at a terminal's width keeps whole characters: a cut
%% through a byte count alone would end the line in half of the e-acute.
ps_table_cut_test() ->
    Text = iolist_to_binary(erx_cmd_ps:table([pid, command], [row(1, #{command => <<"ab", 16#C3, 16#A9>>})], 11)),
    ?assertEqual([<<"    PID COM">>, <<"<0.1.0> ab">>], lines(Text)).
