%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_wc_tests).
-moduledoc """
EUnit cases of the command shell's `wc` (erx_cmd_wc, docs/design-shell.md,
"Commands"): each flag, several files and their total, standard input,
records from a record stage, the error paths, UTF-8 under `-m`, and a
golden comparison with FreeBSD's wc over the inputs of test/fixtures/wc,
whose `expected` file is the standard output of macOS's /usr/bin/wc
(FreeBSD's wc, text_cmds-199) in a UTF-8 locale, as
test/fixtures/wc/generate.rb writes it. The fixture directory is named by
ERX_WC_FIXTURES. The module is also a command of its own,
`wcrecs`, which emits fixed records.
""".

-include_lib("eunit/include/eunit.hrl").

-erx_command(wcrecs).
-erx_usage("wcrecs").
-erx_fields([name, n]).

-export([run/2]).

%%% The test command

run([], Ctx) ->
    erx_cmd:emit(Ctx, #{name => ok(<<"init">>), n => ok(10)}),
    erx_cmd:emit(Ctx, #{name => ok(<<"a b\tc">>), n => {runtime, unknown}}),
    erx_cmd:emit(Ctx, [line], #{line => {data, {ok, <<"caf", 16#C3, 16#A9>>}}}).

ok(Value) -> {runtime, {ok, Value}}.

%%% Running a line

%% Runs a line of the shell in Dir, answering its status, its standard
%% output and its standard error.
run_line(Source, Dir) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [?MODULE, erx_cmd_wc, erx_cmd_cat, erx_cmd_echo]]),
    State = erx_shell_runner:state(#{cwd => Dir, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => #{}}),
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

with_files(Files, Fun) ->
    Dir = filename:join(filename:basedir(user_cache, "erx_cmd_wc_tests"),
                        integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_path(Dir),
    try
        [ok = file:write_file(filename:join(Dir, Name), Bytes) || {Name, Bytes} <- Files],
        Fun(list_to_binary(Dir))
    after
        file:del_dir_r(Dir)
    end.

fixtures() -> list_to_binary(os:getenv("ERX_WC_FIXTURES")).

%%% Golden comparison with FreeBSD's wc

%% Each `$ wc args` line of `expected` and the lines of output under it.
golden_cases(Text) ->
    Cases = lists:foldl(fun(<<"$ ", Command/binary>>, Acc) -> [{Command, <<>>} | Acc];
                           (Line, [{Command, Out} | Acc]) -> [{Command, <<Out/binary, Line/binary, "\n">>} | Acc]
                        end, [], binary:split(Text, <<"\n">>, [global, trim])),
    lists:reverse(Cases).

golden_test_() ->
    Dir = fixtures(),
    {ok, Text} = file:read_file(filename:join(Dir, "expected")),
    Cases = golden_cases(Text),
    %% A truncated `expected` must not pass by comparing nothing.
    true = length(Cases) >= 25,
    [{binary_to_list(Command),
      fun() ->
              {_Status, Out, _Err} = run_line(Command, Dir),
              ?assertEqual(Expected, Out)
      end} || {Command, Expected} <- Cases].

%%% Flags

options_test() ->
    Default = #{lines => true, words => true, size => bytes, longest => false},
    ?assertEqual(Default, erx_cmd_wc:options([])),
    ?assertEqual(Default#{words := false, size := none}, erx_cmd_wc:options("l")),
    %% The later of -c and -m wins.
    ?assertEqual(#{lines => false, words => false, size => chars, longest => false},
                 erx_cmd_wc:options("cm")),
    ?assertEqual(#{lines => false, words => false, size => bytes, longest => false},
                 erx_cmd_wc:options("mc")),
    ?assertEqual(#{lines => false, words => false, size => none, longest => true},
                 erx_cmd_wc:options("L")).

each_flag_test() ->
    with_files(
      [{<<"f">>, <<"one two\n  three\x{e9}\n\nfour"/utf8>>}],
      fun(Dir) ->
              ?assertEqual({<<>>, <<"       3       4      23 f\n">>, <<>>}, run_line(<<"wc f">>, Dir)),
              ?assertEqual({<<>>, <<"       3 f\n">>, <<>>}, run_line(<<"wc -l f">>, Dir)),
              ?assertEqual({<<>>, <<"       4 f\n">>, <<>>}, run_line(<<"wc -w f">>, Dir)),
              ?assertEqual({<<>>, <<"      23 f\n">>, <<>>}, run_line(<<"wc -c f">>, Dir)),
              ?assertEqual({<<>>, <<"      22 f\n">>, <<>>}, run_line(<<"wc -m f">>, Dir)),
              %% The longest line is measured to its newline: "four" has none.
              ?assertEqual({<<>>, <<"       9 f\n">>, <<>>}, run_line(<<"wc -L f">>, Dir)),
              ?assertEqual({<<>>, <<"      22       8 f\n">>, <<>>}, run_line(<<"wc -mL f">>, Dir)),
              ?assertEqual({<<>>, <<"       3       4      22       8 f\n">>, <<>>},
                           run_line(<<"wc -Lmwl f">>, Dir))
      end).

usage_test() ->
    {Status, Out, Err} = run_line(<<"wc -x">>, <<"/">>),
    ?assertNotEqual(<<>>, Status),
    ?assertEqual(<<>>, Out),
    ?assertEqual(<<"usage: wc [-c | -m] [-Llw] [file ...]\n">>, Err).

%%% Several files, standard input and records

total_test() ->
    with_files(
      [{<<"a">>, <<"x y\n">>}, {<<"b">>, <<"a long line\nz">>}],
      fun(Dir) ->
              ?assertEqual({<<>>, <<"       1       2 a\n       1       4 b\n       2       6 total\n">>, <<>>},
                           run_line(<<"wc -lw a b">>, Dir)),
              ?assertEqual({<<>>, <<"       4       3 a\n      13      11 b\n      17      11 total\n">>, <<>>},
                           run_line(<<"wc -cL a b">>, Dir))
      end).

standard_input_test() ->
    with_files(
      [{<<"f">>, <<"hello world\n">>}],
      fun(Dir) ->
              Counts = <<"       1       2      12\n">>,
              ?assertEqual({<<"|">>, Counts, <<>>}, run_line(<<"echo hello world | wc">>, Dir)),
              ?assertEqual({<<>>, Counts, <<>>}, run_line(<<"wc < f">>, Dir)),
              ?assertEqual({<<>>, <<"       0       0       0\n">>, <<>>}, run_line(<<"wc">>, Dir))
      end).

%% Each record counts as one line, the text it renders toward a file:
%% "init\t10", "a b\\tc\t[unknown]" and a line of data, "caf\xc3\xa9": 31 bytes,
%% 30 characters, and 16 in the longest line.
records_test() ->
    ?assertEqual({<<"|">>, <<"       3\n">>, <<>>}, run_line(<<"wcrecs | wc -l">>, <<"/">>)),
    ?assertEqual({<<"|">>, <<"       3       6      31\n">>, <<>>}, run_line(<<"wcrecs | wc">>, <<"/">>)),
    ?assertEqual({<<"|">>, <<"      30      16\n">>, <<>>}, run_line(<<"wcrecs | wc -mL">>, <<"/">>)),
    ?assertEqual({<<"||">>, <<"       3\n">>, <<>>}, run_line(<<"wcrecs | cat | wc -l">>, <<"/">>)).

%% A line longer than a pipe's line bound is still counted: wc reads
%% standard input in pieces, not lines.
long_line_from_a_pipe_test() ->
    with_files(
      [{<<"f">>, binary:copy(<<"ab ">>, 100000)}],
      fun(Dir) ->
              ?assertEqual({<<"|">>, <<"       0  100000  300000\n">>, <<>>}, run_line(<<"cat f | wc">>, Dir))
      end).

%% Counting only lines and bytes of short lines from a pipe stays within the
%% stage's heap limit: a megabyte piece of newlines is counted in constant
%% memory.
dense_newlines_from_a_pipe_test_() ->
    {timeout, 120,
     fun() ->
             with_files(
               [{<<"nl">>, binary:copy(<<"\n">>, 8 bsl 20)}],
               fun(Dir) ->
                       ?assertEqual({<<"|">>, <<" 8388608\n">>, <<>>}, run_line(<<"cat nl | wc -l">>, Dir)),
                       ?assertEqual({<<>>, <<" 8388608 8388608\n">>, <<>>}, run_line(<<"wc -lc < nl">>, Dir))
               end)
     end}.

%%% Errors

missing_file_test() ->
    with_files(
      [{<<"f">>, <<"a\n">>}],
      fun(Dir) ->
              ?assertEqual({<<"no such file or directory">>,
                            <<"       1       1       2 f\n       1       1       2 total\n">>,
                            <<"wc: nofile: open: no such file or directory\n">>},
                           run_line(<<"wc nofile f">>, Dir)),
              %% `-` names a file, as in FreeBSD's wc.
              ?assertEqual({<<"no such file or directory">>, <<>>,
                            <<"wc: -: open: no such file or directory\n">>},
                           run_line(<<"wc -c -">>, Dir))
      end).

directory_test() ->
    with_files(
      [{<<"f">>, <<"a\n">>}],
      fun(Dir) ->
              {Status, Out, Err} = run_line(<<"wc . f">>, Dir),
              ?assertNotEqual(<<>>, Status),
              ?assertEqual(<<"       1       1       2 f\n       1       1       2 total\n">>, Out),
              ?assertMatch(<<"wc: .: ", _/binary>>, Err)
      end).

%%% UTF-8 under -m

illegal_sequences_test() ->
    with_files(
      [{<<"bad">>, <<"a", 16#FF, " b\n", 16#C3>>}, {<<"good">>, <<"\x{e9}\n"/utf8>>}],
      fun(Dir) ->
              %% 0xFF counts as one character, the cut sequence at the end
              %% as none; the warning comes once and leaves the status.
              ?assertEqual({<<>>, <<"       5 bad\n">>, <<"wc: bad: illegal byte sequence\n">>},
                           run_line(<<"wc -m bad">>, Dir)),
              ?assertEqual({<<"|">>, <<"       5\n">>, <<"wc: stdin: illegal byte sequence\n">>},
                           run_line(<<"cat bad | wc -m">>, Dir)),
              ?assertEqual({<<>>, <<"       2 good\n">>, <<>>}, run_line(<<"wc -m good">>, Dir)),
              %% Without -m bytes are counted, and nothing is illegal.
              ?assertEqual({<<>>, <<"       6 bad\n">>, <<>>}, run_line(<<"wc -c bad">>, Dir))
      end).

%% Splitting the input anywhere, a UTF-8 sequence too, counts the same.
pieces_test() ->
    Text = <<"caf\x{e9} \x{65e5}\x{3000}x\n\x{1f600}y"/utf8, 16#E2, 16#82, "z\n", 16#F0, 16#9F>>,
    Options = erx_cmd_wc:options("lwmL"),
    Whole = erx_cmd_wc:line(Options, erx_cmd_wc:close(erx_cmd_wc:add(chars, Text, erx_cmd_wc:new())), stdin),
    ?assertEqual(<<"       2       4      15       8\n">>, iolist_to_binary(Whole)),
    [begin
         <<Head:At/binary, Tail/binary>> = Text,
         Count = erx_cmd_wc:add(chars, Tail, erx_cmd_wc:add(chars, Head, erx_cmd_wc:new())),
         ?assertEqual(Whole, erx_cmd_wc:line(Options, erx_cmd_wc:close(Count), stdin))
     end || At <- lists:seq(0, byte_size(Text))].

%% FreeBSD's white space in C.UTF-8 separates words; NEL, a zero-width
%% space and NUL do not.
white_space_test() ->
    Spaces = [9, 10, 11, 12, 13, 32, 16#A0, 16#1680, 16#2000, 16#2005, 16#200A, 16#2028, 16#2029,
              16#202F, 16#205F, 16#3000],
    Others = [0, 16#85, 16#200B, 16#FEFF, 16#180E, 16#1C, 16#1F],
    Words = fun(Char) ->
                    Count = erx_cmd_wc:add(chars, <<"a", Char/utf8, "b">>, erx_cmd_wc:new()),
                    iolist_to_binary(erx_cmd_wc:line(erx_cmd_wc:options("w"), Count, stdin))
            end,
    [?assertEqual({Char, <<"       2\n">>}, {Char, Words(Char)}) || Char <- Spaces],
    [?assertEqual({Char, <<"       1\n">>}, {Char, Words(Char)}) || Char <- Others].

%% A count wider than seven digits widens its field, as printf's %7ju does.
wide_field_test() ->
    Thousand = erx_cmd_wc:add(newlines, binary:copy(<<"\n">>, 1000), erx_cmd_wc:new()),
    Count = lists:foldl(fun erx_cmd_wc:sum/2, erx_cmd_wc:new(), lists:duplicate(12346, Thousand)),
    ?assertEqual(<<" 12346000 total\n">>,
                 iolist_to_binary(erx_cmd_wc:line(erx_cmd_wc:options("l"), Count, <<"total">>))).
