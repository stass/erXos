%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The console's choice of its first shell, what follows that shell's end, which group
%% shell:whereis/0 reports, and which driver the boot records name
%% (erx_console:first_shell/1, erx_console:after_first_shell/2,
%% erx_console:erlang_shell_group/1, erx_console:console_driver/1).
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

%% -- The console's driver, from `-erx_record console_driver Module` -----------------

the_last_naming_of_a_driver_wins_test() ->
    ?assertEqual({ok, erx_stdio},
                 erx_console:console_driver([["console_driver", "erx_pl011"], ["build", "7"],
                                             ["console_driver", "erx_stdio"]])),
    ?assertEqual({ok, erx_mini_uart},
                 erx_console:console_driver([["console_driver", "erx_mini_uart", "quiet"]])).

no_console_driver_record_is_refused_test() ->
    ?assertMatch({error, {no_console_driver, _}}, erx_console:console_driver([["build", "7"]])),
    ?assertMatch({error, {no_console_driver, _}}, erx_console:console_driver([["console_driver"]])).

%% A word that names no console driver is refused, and becomes no atom: the system
%% domain's atom table grows only within bounds its own policy sets.
an_unknown_driver_is_refused_and_makes_no_atom_test() ->
    Word = "erx_no_console_driver_" ++ integer_to_list(erlang:unique_integer([positive])),
    ?assertError(badarg, list_to_existing_atom(Word)),
    ?assertMatch({error, {bad_console_driver, _}},
                 erx_console:console_driver([["console_driver", "erx_pl011"], ["console_driver", Word]])),
    ?assertError(badarg, list_to_existing_atom(Word)).

%% A word longer than any atom is refused as any other unknown word is.
a_word_no_atom_can_hold_is_refused_test() ->
    ?assertMatch({error, {bad_console_driver, _}},
                 erx_console:console_driver([["console_driver", lists:duplicate(256, $a)]])).

%% A module that is no console driver is refused, though its atom exists.
a_module_that_is_no_driver_is_refused_test() ->
    ?assertMatch({error, {bad_console_driver, _}},
                 erx_console:console_driver([["console_driver", "erlang"]])).
