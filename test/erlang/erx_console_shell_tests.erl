%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The console's choice of its first shell, what follows that shell's end, and which
%% group shell:whereis/0 reports (erx_console:first_shell/1,
%% erx_console:after_first_shell/2, erx_console:erlang_shell_group/1).
-module(erx_console_shell_tests).
-include_lib("eunit/include/eunit.hrl").

the_command_shell_is_the_first_shell_test() ->
    ?assertEqual({erx_shell, console, []},
                 erx_console:first_shell(#{noshell => false, noinput => false})).

noshell_or_noinput_leaves_no_shell_test() ->
    [?assertEqual(none, erx_console:first_shell(#{noshell => NoShell, noinput => NoInput}))
     || {NoShell, NoInput} <- [{true, false}, {false, true}, {true, true}]].

the_first_shell_starts_again_while_input_may_come_test() ->
    [?assertEqual(restart, erx_console:after_first_shell(Reason, false))
     || Reason <- [normal, killed, {badarg, []}, shutdown]].

the_end_of_input_ends_the_runtime_test() ->
    ?assertEqual({halt, 0}, erx_console:after_first_shell(normal, true)),
    [?assertEqual({halt, 1}, erx_console:after_first_shell(Reason, true))
     || Reason <- [killed, {badarg, []}, shutdown]].

%% shell:whereis/0 names only an Erlang shell: shell:get_state/0 waits for its answer,
%% which a command shell never sends, so edlin_expand:expand/1 would wait forever with
%% the command shell in front.
no_erlang_shell_before_one_runs_test() ->
    ?assertEqual(undefined, erx_console:erlang_shell_group([])).

a_command_shell_in_front_is_no_erlang_shell_test() ->
    Erlang = {self(), make_ref()},
    Command = {spawn(fun() -> ok end), make_ref()},
    ?assertEqual(undefined,
                 erx_console:erlang_shell_group([shell_entry(Command, {erx_shell, start, []}),
                                                 shell_entry(Erlang, {shell, start, []})])).

the_erlang_shell_in_front_is_reported_test() ->
    {Group, _} = Erlang = {self(), make_ref()},
    Command = {spawn(fun() -> ok end), make_ref()},
    ?assertEqual(Group,
                 erx_console:erlang_shell_group([shell_entry(Erlang, {shell, start, []}),
                                                 shell_entry(Command, {erx_shell, console, []})])).

shell_entry({Group, Tag}, Shell) -> {Group, {self(), Tag}, Shell}.
