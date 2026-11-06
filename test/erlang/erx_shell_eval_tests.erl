%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_shell_eval_tests).
-moduledoc """
EUnit cases of the command shell's evaluator (docs/design-shell.md, "The
language") for what the differential corpus against rc cannot show: the
requests the evaluator makes of its runner, which bodies run on a copy of
the shell, how faults and `exit` unwind through redirections and local
variables, globbing, the builtins rc has and the shell refuses, pattern
matching, and the bounds on recursion. rc's own behaviour on the language
is checked by test/integration/erx_shell_corpus_test.rb.
""".

-include_lib("eunit/include/eunit.hrl").

%% Runs Source with the fake runner; gives how it ended, stdout and stderr.
run(Source) ->
    erx_shell_fake_runner:run(iolist_to_binary(Source)).

out(Source) ->
    {_, Out, _} = run(Source),
    Out.

shell_of({ok, Shell}) -> Shell;
shell_of({exit, Shell}) -> Shell;
shell_of({error, _, Shell}) -> Shell.

%% A runner that records every request and answers from Answers, a fun of
%% the request; its state is the list of requests, newest first.
recording(Answers) ->
    fun(Request, Seen) -> {Answers(Request), [Request | Seen]} end.

requests(Source, Answers) ->
    Shell = erx_shell_eval:new(#{}, recording(Answers), []),
    Outcome = erx_shell_eval:run_source(iolist_to_binary(Source), Shell),
    {Outcome, lists:reverse(erx_shell_eval:runner_state(shell_of(Outcome)))}.

%%% The runner's boundary

a_command_outside_the_language_goes_to_the_runner_with_its_argv_test() ->
    {{ok, Shell}, Seen} = requests(<<"x=(a b); ls -l $x\n">>,
                                   fun({run, _, _}) -> <<"7">> end),
    [{run, Argv, Vars}] = Seen,
    ?assertEqual([<<"ls">>, <<"-l">>, <<"a">>, <<"b">>], Argv),
    ?assertEqual([<<"a">>, <<"b">>], maps:get(<<"x">>, Vars)),
    ?assertEqual(<<"7">>, erx_shell_eval:status(Shell)).

only_unquoted_pattern_characters_are_globbed_test() ->
    Answers = fun({glob, Pattern}) ->
                      [<<(erx_shell_eval:pattern_text(Pattern))/binary, ".1">>];
                 ({run, _, _}) -> <<>>
              end,
    {{ok, _}, Seen} = requests(<<"x='*'; c *.c '*.h' $x a^'['\n">>, Answers),
    ?assertMatch([{glob, _}, {run, _, _}], Seen),
    [_, {run, Argv, _}] = Seen,
    ?assertEqual([<<"c">>, <<"*.c.1">>, <<"*.h">>, <<"*">>, <<"a[">>], Argv).

a_pattern_that_matches_nothing_stays_as_written_test() ->
    ?assertEqual(<<"a* [b] ?\n">>, out(<<"echo a* [b] ?\n">>)).

redirections_reach_the_runner_expanded_test() ->
    Answers = fun({redirect, _, Body}) -> element(1, Body([])) ;
                 ({run, _, _}) -> <<>>
              end,
    Shell = erx_shell_eval:new(#{<<"f">> => [<<"out">>]},
                               fun(Request, Seen) ->
                                       {Answers(Request), [Request | Seen]}
                               end, []),
    {ok, Done} = erx_shell_eval:run_source(
                   <<"cmd >$f.txt >>[2]log <<EOF >[2=1] >[3=]\nhi $f\nEOF\n">>,
                   Shell),
    [{redirect, Redirs, _}] = [R || {redirect, _, _} = R
                                       <- erx_shell_eval:runner_state(Done)],
    ?assertEqual([{write, 1, <<"out.txt">>}, {append, 2, <<"log">>},
                  {here, 0, <<"hi out\n">>}, {dup, 2, 1}, {close, 3}],
                 Redirs).

a_redirection_to_a_list_is_a_fault_test() ->
    {{error, Message, _}, _} =
        requests(<<"x=(a b); cmd >$x; echo never\n">>, fun(_) -> ok end),
    ?assertEqual(<<"> requires singleton\n">>, Message).

%%% Copies of the shell

bodies_run_apart_cannot_change_the_parent_test() ->
    ?assertEqual(<<"sub kept\nkept\nkept\n">>,
                 out(<<"x=kept; y=`{x=sub; echo $x}; echo $y $x\n"
                       "@{ x=subshell }; echo $x\n"
                       "{ x=stage } | true; echo $x\n">>)).

a_block_under_redirection_changes_the_shell_test() ->
    ?assertEqual(<<"set\n">>, out(<<"{ x=set } >[2=1]; echo $x\n">>)).

a_fault_in_a_substitution_ends_only_the_substitution_test() ->
    {{ok, Shell}, Out, Err} =
        run(<<"x=`{ echo a^() }; echo st $status $#x\n">>),
    ?assertEqual(<<"st error 0\n">>, Out),
    ?assertEqual(<<"rc: null list in concatenation\n">>, Err),
    ?assertEqual(<<>>, erx_shell_eval:status(Shell)).

a_background_block_sets_apid_and_leaves_status_test() ->
    Answers = fun({background, Body}) ->
                      {<<"1">>, _} = Body([]),
                      <<"42">>;
                 ({run, _, _}) -> <<"1">>
              end,
    {{ok, Shell}, _} = requests(<<"false; { x=lost; false } &\n">>, Answers),
    ?assertEqual([<<"42">>], erx_shell_eval:var(<<"apid">>, Shell)),
    ?assertEqual([], erx_shell_eval:var(<<"x">>, Shell)),
    ?assertEqual(<<"1">>, erx_shell_eval:status(Shell)).

%%% Unwinding

exit_unwinds_through_redirections_and_locals_test() ->
    {Outcome, Out, _} =
        run(<<"x=outer; fn f { x=inner { exit 3 } >[2=1] }\nf a\necho no\n">>),
    {exit, Shell} = Outcome,
    ?assertEqual(<<>>, Out),
    ?assertEqual(<<"3">>, erx_shell_eval:status(Shell)),
    ?assertEqual([<<"outer">>], erx_shell_eval:var(<<"x">>, Shell)),
    ?assertEqual([], erx_shell_eval:var(<<"*">>, Shell)),
    State = erx_shell_eval:runner_state(Shell),
    ?assertEqual(#{1 => stdout, 2 => stderr}, maps:get(fds, State)).

a_fault_stops_the_script_and_keeps_what_ran_test() ->
    {{error, Message, Shell}, Out, Err} =
        run(<<"x=1\necho a^(b c)^(d e f)\nx=2\n">>),
    ?assertEqual(<<"mismatched list lengths in concatenation">>, Message),
    ?assertEqual(<<>>, Out),
    ?assertEqual(<<"rc: ", Message/binary, "\n">>, Err),
    ?assertEqual([<<"1">>], erx_shell_eval:var(<<"x">>, Shell)),
    ?assertEqual(<<"error">>, erx_shell_eval:status(Shell)).

a_unit_that_does_not_parse_stops_the_script_test() ->
    {{error, Message, Shell}, Out, _} = run(<<"echo one\nif(\n">>),
    ?assertEqual(<<"one\n">>, Out),
    ?assertEqual(Message, erx_shell_eval:status(Shell)).

eval_runs_in_the_current_shell_test() ->
    ?assertEqual(<<"a b\nfrom-fn\n">>,
                 out(<<"eval x'=(a b)'; echo $x; eval 'fn g { echo from-fn }'; g\n">>)).

%%% Builtins

exec_and_rfork_are_refused_test() ->
    {{ok, Shell}, _, Err} = run(<<"exec echo hi; rfork e\n">>),
    ?assertEqual(<<"exec: not supported by this shell\n"
                   "rfork: not supported by this shell\n">>, Err),
    ?assertEqual(<<"not supported">>, erx_shell_eval:status(Shell)).

builtin_skips_functions_test() ->
    ?assertEqual(<<"fn\nplain\n">>,
                 out(<<"fn echo { builtin echo fn }; echo x; builtin echo plain\n">>)).

%%% Patterns

match(Name, Pattern) ->
    {ok, [{match, _, [Word]}], _} =
        erx_shell_parse:next(<<"~ x ", Pattern/binary, "\n">>, final),
    {ok, Shell} = erx_shell_eval:run_unit(
                    [{match, {quoted, Name}, [Word]}],
                    erx_shell_eval:new(#{}, erx_shell_fake_runner:runner(),
                                       erx_shell_fake_runner:new())),
    erx_shell_eval:status(Shell) =:= <<>>.

pattern_matching_test_() ->
    Cases = [{<<"abc">>, <<"a*c">>, true}, {<<"ac">>, <<"a*c">>, true},
             {<<"abd">>, <<"a*c">>, false}, {<<"aXbXc">>, <<"*b*c">>, true},
             {<<"b">>, <<"[abc]">>, true}, {<<"d">>, <<"[a-c]">>, false},
             {<<"d">>, <<"[~a-c]">>, true}, {<<"-">>, <<"[a-]">>, false},
             {<<"]">>, <<"[]]">>, false}, {<<"[">>, <<"[">>, false},
             {<<"b">>, <<"[c-a]">>, true}, {<<"[ab">>, <<"[ab">>, false},
             {<<16#c3, 16#a9>>, <<"?">>, true},
             {<<"\xff">>, <<"?">>, true}, {<<>>, <<"*">>, true},
             {<<"*">>, <<"'*'">>, true}, {<<"x">>, <<"'*'">>, false},
             {<<"ab">>, <<"a'?'">>, false}],
    [{iolist_to_binary([Name, " ~ ", Pattern]),
      ?_assertEqual(Want, match(Name, Pattern))}
     || {Name, Pattern, Want} <- Cases].

a_star_pattern_against_a_long_text_matches_test() ->
    Long = binary:copy(<<"a">>, 100000),
    ?assert(match(<<Long/binary, "b">>, <<"*a*b">>)),
    ?assertNot(match(Long, <<"*a*b">>)).

%%% Bounds

%% The loop is iterative: what it holds is its variables, not its iterations.
a_loop_of_a_thousand_iterations_fits_the_stage_heap_test() ->
    Source = <<"k=(); while(! ~ $#k 1000) k=($k x); echo $#k\n">>,
    ?assertEqual({normal, <<"1000\n">>}, bounded(fun() -> out(Source) end)).

nesting_at_the_parsers_bound_evaluates_test() ->
    Depth = 255,
    Source = [lists:duplicate(Depth, "{"), "echo deep", lists:duplicate(Depth, "}"), "\n"],
    ?assertEqual(<<"deep\n">>, out(Source)).

%% A function that calls itself without end, holding nothing that grows,
%% ends its own process at the heap limit the session sets on every
%% evaluator (SH2): its stack alone is bounded.
runaway_recursion_ends_its_process_at_the_heap_limit_test() ->
    ?assertEqual({killed, none},
                 bounded(fun() -> run(<<"fn f { f }\nf\n">>) end)).

%% A NUL would cut a C string short, so a program never sees one.
a_nul_byte_in_an_argument_is_a_fault_test() ->
    ?assertMatch({{error, <<"an argument holds a NUL byte">>, _}, _, _}, run(<<"echo a", 0, "b\n">>)),
    ?assertMatch({{error, <<"> file name holds a NUL byte">>, _}, _, _}, run(<<"echo a >f", 0, "\n">>)).

%% Runs Fun in a process under the heap limit the design sets on every
%% evaluator, 4 MiB; gives how the process ended and what Fun returned,
%% `none` when it did not return.
bounded(Fun) ->
    Self = self(),
    Words = 4 * 1024 * 1024 div erlang:system_info(wordsize),
    {Pid, Ref} = spawn_monitor(
                   fun() ->
                           process_flag(max_heap_size,
                                        #{size => Words, kill => true,
                                          error_logger => false,
                                          include_shared_binaries => true}),
                           Self ! {self(), Fun()}
                   end),
    receive
        {'DOWN', Ref, process, Pid, Reason} ->
            receive {Pid, Value} -> {Reason, Value}
            after 0 -> {Reason, none}
            end
    after 60000 ->
            exit(Pid, kill),
            timeout
    end.
