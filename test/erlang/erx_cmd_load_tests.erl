%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_load_tests).
-moduledoc """
EUnit cases of the session's `load` (docs/design-live.md, "One load, three routes"):
its reader of the arguments and of standard input, and whole lines of the shell that load
modules compiled here into this emulator through the code service, erx_code, reached as
the system domain's shell reaches it (`local`) and through a stand-in facet process, as a
session reaches it. Each case starts its own erx_code.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%%% The reader

parse_test() ->
    P = fun(Line) -> erx_cmd_load:parse(binary:split(Line, <<" ">>, [global, trim_all])) end,
    ?assertMatch({ok, #{target := system, verbose := false, source := {files, [<<"a.beam">>]}}}, P(<<"-s a.beam">>)),
    ?assertMatch({ok, #{target := {domain, <<"net">>}, verbose := true, source := {input, [{<<"a">>, 3}, {<<"b">>, rest}]}}},
                 P(<<"-v -d net -m a:3 -m b">>)),
    ?assertMatch({ok, #{source := {input, [{<<"a">>, 3}, {<<"b">>, 16777213}]}}}, P(<<"-s -m a:3 -m b:16777213">>)),
    [?assertEqual({error, usage}, P(Line), Line)
     || Line <- [<<"a.beam">>,                     % no target
                 <<"-s -d 5 a.beam">>,             % both targets
                 <<"-s -s a.beam">>,
                 <<"-s">>,                         % no module
                 <<"-s -m a:3 b.beam">>,           % both forms
                 <<"-s -m a -m b:3">>,             % only the last may leave out its size
                 <<"-s -m a:0">>, <<"-s -m a:">>, <<"-s -m :3">>, <<"-s -m a:3x">>,
                 <<"-s -m a:-3">>, <<"-s -m a:1234567890">>,
                 <<"-s -m a:16777216 -m b:1">>,    % past the load bound in all
                 <<"-s -m a:16777217">>]].

%% A name may hold a colon: the size is what follows the last one, and the code service
%% decides whether the name names a module.
colon_test() ->
    ?assertMatch({ok, #{source := {input, [{<<"a:b">>, 2}]}}}, erx_cmd_load:parse([<<"-s">>, <<"-m">>, <<"a:b:2">>])).

split_test() ->
    ?assertEqual({ok, [{<<"a">>, <<"xyz">>}, {<<"b">>, <<"tail">>}]},
                 erx_cmd_load:split([{<<"a">>, 3}, {<<"b">>, rest}], <<"xyztail">>)),
    ?assertEqual({ok, [{<<"a">>, <<"xy">>}, {<<"b">>, <<"z">>}]},
                 erx_cmd_load:split([{<<"a">>, 2}, {<<"b">>, 1}], <<"xyz">>)),
    ?assertEqual({error, {<<"b">>, short}}, erx_cmd_load:split([{<<"a">>, 2}, {<<"b">>, 2}], <<"xyz">>)),
    ?assertEqual({error, {<<"b">>, short}}, erx_cmd_load:split([{<<"a">>, 3}, {<<"b">>, rest}], <<"xyz">>)),
    ?assertEqual({error, {<<"a">>, short}}, erx_cmd_load:split([{<<"a">>, 3}], <<>>)),
    ?assertEqual({error, {<<"b">>, long}}, erx_cmd_load:split([{<<"a">>, 1}, {<<"b">>, 1}], <<"xyz">>)).

%%% Whole lines

lines_test_() ->
    {foreach, fun start/0, fun stop/1,
     [fun loads_a_batch_from_standard_input/1,
      fun loads_files_through_a_facet_process/1,
      fun verbose_names_what_was_sent/1,
      fun refusals_load_nothing/1,
      fun a_missing_facet_reads_nothing/1,
      fun a_blob_past_one_piece_goes_in_pieces/1]}.

start() ->
    {ok, Pid} = erx_code:start_link(#{limit => 1 bsl 22}),
    unlink(Pid),
    Dir = erx_test_dir:new(),
    #{service => Pid, dir => list_to_binary(Dir)}.

stop(#{service := Pid, dir := Dir}) ->
    exit(Pid, kill),
    file:del_dir_r(Dir),
    [begin code:purge(M), code:delete(M), code:purge(M) end || M <- [erx_load_probe_a, erx_load_probe_b]].

loads_a_batch_from_standard_input(#{dir := Dir}) ->
    A = probe(erx_load_probe_a, 1),
    B = probe(erx_load_probe_b, 2),
    ok = file:write_file(filename:join(Dir, "in"), [A, B]),
    Line = iolist_to_binary(["cat in | load -s -m erx_load_probe_a:", integer_to_list(byte_size(A)), " -m erx_load_probe_b"]),
    Result = run_line(Line, Dir, #{install => local}),
    [?_assertEqual({<<"|">>, <<>>, <<>>}, Result),
     ?_assertEqual(1, erx_load_probe_a:v()),
     ?_assertEqual(2, erx_load_probe_b:v())].

loads_files_through_a_facet_process(#{dir := Dir}) ->
    ok = file:write_file(filename:join(Dir, "erx_load_probe_a.beam"), probe(erx_load_probe_a, 7)),
    Facet = facet(),
    Result = run_line(<<"load -s erx_load_probe_a.beam">>, Dir, #{install => Facet}),
    [?_assertEqual({<<>>, <<>>, <<>>}, Result),
     ?_assertEqual(7, erx_load_probe_a:v())].

verbose_names_what_was_sent(#{dir := Dir}) ->
    A = probe(erx_load_probe_a, 3),
    ok = file:write_file(filename:join(Dir, "erx_load_probe_a.beam"), A),
    Hex = binary:encode_hex(crypto:hash(sha256, A), lowercase),
    First = run_line(<<"load -s -v erx_load_probe_a.beam">>, Dir, #{install => local}),
    Again = run_line(<<"load -s -v erx_load_probe_a.beam">>, Dir, #{install => local}),
    [?_assertEqual({<<>>, <<"erx_load_probe_a ", Hex/binary, " sent\n">>, <<>>}, First),
     ?_assertEqual({<<>>, <<"erx_load_probe_a ", Hex/binary, " not sent\n">>, <<>>}, Again)].

%% Input that ends early, goes on past the last module, or holds a module the loader
%% refuses loads nothing of the batch, and each failure names its module.
refusals_load_nothing(#{dir := Dir}) ->
    A = probe(erx_load_probe_a, 4),
    ok = file:write_file(filename:join(Dir, "in"), A),
    Size = integer_to_list(byte_size(A)),
    Short = run_line(iolist_to_binary(["cat in | load -s -m erx_load_probe_a:", Size, " -m erx_load_probe_b"]),
                     Dir, #{install => local}),
    Long = run_line(iolist_to_binary(["cat in | load -s -m erx_load_probe_a:", integer_to_list(byte_size(A) - 1)]),
                    Dir, #{install => local}),
    ok = file:write_file(filename:join(Dir, "bad"), [A, <<"not a module">>]),
    Bad = run_line(iolist_to_binary(["cat bad | load -s -m erx_load_probe_a:", Size, " -m erx_load_probe_b"]),
                   Dir, #{install => local}),
    [?_assertEqual({<<"|1">>, <<>>, <<"load: erx_load_probe_b: input ends early\n">>}, Short),
     ?_assertEqual({<<"|1">>, <<>>, <<"load: erx_load_probe_a: input goes on past the last module\n">>}, Long),
     ?_assertMatch({<<"|1">>, <<>>, <<"load: erx_load_probe_b: ", _/binary>>}, Bad),
     ?_assertEqual(false, code:is_loaded(erx_load_probe_a))].

a_missing_facet_reads_nothing(#{dir := Dir}) ->
    [?_assertEqual({<<"1">>, <<>>, <<"load: no install facet\n">>}, run_line(<<"load -s nothing.beam">>, Dir, #{})),
     ?_assertEqual({<<"1">>, <<>>, <<"load: no code facet\n">>},
                   run_line(<<"load -d 5 nothing.beam">>, Dir, #{install => local}))].

a_blob_past_one_piece_goes_in_pieces(#{dir := Dir}) ->
    Big = binary:copy(<<"0123456789abcdef">>, 10000),
    Forms = [{attribute, 1, module, erx_load_probe_a}, {attribute, 1, export, [{v, 0}]},
             {function, 1, v, 0, [{clause, 1, [], [], [{bin, 1, [{bin_element, 1, {string, 1, binary_to_list(Big)},
                                                                   default, default}]}]}]}],
    {ok, _, Beam} = compile:forms(Forms, []),
    ok = file:write_file(filename:join(Dir, "erx_load_probe_a.beam"), Beam),
    Result = run_line(<<"load -s erx_load_probe_a.beam">>, Dir, #{install => facet()}),
    [?_assert(byte_size(Beam) > 2 * 65536),
     ?_assertEqual({<<>>, <<>>, <<>>}, Result),
     ?_assertEqual(Big, erx_load_probe_a:v())].

%% The largest requests load sends fit code_request_max, which the generator derives
%% from abi/services/code.txt (tools/lib/erx/abi_code_bounds.rb): a load of
%% code_modules_max modules with 255-byte names into a domain named by 255 bytes, and a
%% put of a whole piece. A stand-in code facet takes each call, says the first blob is
%% missing, and measures the call as a facet of another domain receives it, from a pid
%% and a reference of the longest node name.
largest_requests_fit_the_request_bound_test() ->
    Dir = erx_test_dir:new(),
    Names = [[integer_to_list(I), lists:duplicate(255 - length(integer_to_list(I)), $m)]
             || I <- lists:seq(1, ?ERX_CODE_MODULES_MAX)],
    ok = file:write_file(filename:join(Dir, "in"), [binary:copy(<<0>>, ?ERX_CODE_PIECE_MAX), lists:duplicate(length(Names) - 1, 0)]),
    %% A line holds at most 4,096 bytes, so the arguments gather in a list line by line.
    Source = iolist_to_binary(["a=()\n", [["a=($a -m ", Name, ":1)\n"] || Name <- tl(Names)],
                               "cat in | load -d ", lists:duplicate(255, $d), " -m ", hd(Names), $:,
                               integer_to_list(?ERX_CODE_PIECE_MAX), " $a\n"]),
    Node = binary:copy(<<$n>>, 255),
    Pid = binary_to_term(<<131, 88, 119, 255, Node/binary, 1:32, 0:32, 1:32>>),
    Ref = binary_to_term(<<131, 90, 5:16, 119, 255, Node/binary, 1:32, 1:32, 2:32, 3:32, 4:32, 5:32>>),
    Me = self(),
    Facet = spawn(fun Loop() ->
                          receive
                              {'$gen_call', From, Request} ->
                                  Me ! {request, element(1, Request), erlang:external_size({'$gen_call', {Pid, [alias | Ref]}, Request})},
                                  gen_server:reply(From, case Request of
                                                             {missing, [Hash | _]} -> {ok, [Hash]};
                                                             {put, _, _, _, _} -> {ok, stored};
                                                             {load, _, _} -> ok
                                                         end),
                                  Loop()
                          end
                  end),
    Result = run_line(Source, list_to_binary(Dir), #{code => Facet}),
    exit(Facet, kill),
    file:del_dir_r(Dir),
    Sizes = [receive {request, Kind, Size} -> {Kind, Size} after 0 -> none end || _ <- [missing, put, load]],
    ?assertEqual({<<"|">>, <<>>, <<>>}, Result),
    ?assertMatch([{missing, _}, {put, _}, {load, _}], Sizes),
    [?assert(Size =< ?ERX_CODE_REQUEST_MAX) || {_, Size} <- Sizes].

%%% Helpers

%% A module Name whose v/0 answers V, compiled here.
probe(Name, V) ->
    Forms = [{attribute, 1, module, Name}, {attribute, 1, export, [{v, 0}]},
             {function, 1, v, 0, [{clause, 1, [], [], [{integer, 1, V}]}]}],
    {ok, Name, Beam} = compile:forms(Forms, []),
    Beam.

%% A stand-in for the install facet a session holds: a process that takes gen_server
%% calls and answers each with the code service's answer.
facet() ->
    spawn(fun Loop() ->
                  receive
                      {'$gen_call', From, Request} -> gen_server:reply(From, erx_code:call(Request)), Loop()
                  end
          end).

%% Runs a line of the shell in Dir with Facets, answering its status, its standard output
%% and its standard error.
run_line(Source, Dir, Facets) ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_load, erx_cmd_cat]]),
    State = erx_shell_runner:state(#{cwd => Dir, fds => #{0 => null, 1 => sink(out), 2 => sink(err)},
                                     table => Table, facets => fun() -> Facets end}),
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
