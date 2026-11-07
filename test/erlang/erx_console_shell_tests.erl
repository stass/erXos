%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The console's choice of its first shell, and what follows that shell's end
%% (erx_console:first_shell/1, erx_console:after_first_shell/2).
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
