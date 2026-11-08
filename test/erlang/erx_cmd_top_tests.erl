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
                                     table => Table, facets => #{}}),
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

display(Rows, Layout) ->
    iolist_to_binary(erx_cmd_top:display(erx_cmd_top:shares(none, {0, Rows}), Layout)).

display_test() ->
    Rows = [row(3, #{state => <<"R">>, time => 61000000, pcpu => 12.5}), row(12, #{rss => 20000}),
            row(5, #{state => missing, rss => missing, comm => missing}), row(7, #{state => <<"T">>})],
    ?assertEqual(<<"01:02:03\n",
                   "4 processes:   1 running, 1 sleeping, 1 stopped\n",
                   "\n",
                   "    PID    RES STATE    TIME    WCPU COMMAND\n",
                   "<0.3.0>    12K RUN      1:01  12.50% p3\n",
                   "<0.5.0>      - -           -       - -\n",
                   "<0.7.0>    28K STOP        -       - p7\n">>,
                 display(Rows, layout(3, infinity))),
    ?assertEqual(<<"1 processes:   1 sleeping">>, lists:nth(2, lines(display([row(1, #{})], layout(0, infinity))))).

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
    [Clock, States, <<>>, Header | Rows] = lines(Out),
    ?assertMatch({match, _}, re:run(Clock, <<"^\\d\\d:\\d\\d:\\d\\d$">>)),
    ?assertMatch({match, _}, re:run(States, <<"^\\d+ processes: +\\d+ ">>)),
    ?assertMatch({match, _}, re:run(Header, <<"^ +PID    RES STATE    TIME    WCPU COMMAND$">>)),
    ?assertEqual(18, length(Rows)),
    ?assertEqual(nomatch, binary:match(Out, <<27>>)),
    {<<>>, Two, <<>>} = run_line(<<"top -b -d 2 -s 0.01 1">>, #{}),
    ?assertMatch([_, _, <<>>, _, _, <<>>, _, _, <<>>, _, _], lines(Two)).

%% At a terminal each display starts with home and clear and fills the
%% terminal's height, less the cursor's line, each line within its width.
top_terminal_test() ->
    Vars = #{<<"LINES">> => [<<"8">>], <<"COLUMNS">> => [<<"30">>]},
    {<<>>, Out, <<>>} = run_line(<<"top -d 2 -s 0.01">>, Vars),
    [<<>>, First, Second] = binary:split(Out, <<"\e[H\e[2J">>, [global]),
    [?assertEqual(7, length(lines(Display))) || Display <- [First, Second]],
    [?assert(byte_size(Line) =< 29) || Line <- lines(Out)].

%% Output that is not a terminal gets one display without -b, and the
%% line ends: a top that kept drawing into a pipe would never let cat end.
top_pipe_test() ->
    {Status, Out, <<>>} = run_line(<<"top -s 0.01 2 | cat">>, #{}),
    ?assertEqual(<<"|">>, Status),
    ?assertEqual(6, length(lines(Out))),
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
