%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_reads_tests).
-moduledoc """
The console of a session domain's line reads its terminal relay on demand
(docs/design-shell.md, "The console reads on demand"), through the tree's group.erl
with edit 72 (docs/design-runtime.md), which test/host/erx_console_reads_test.rb
loads before these cases run. Each case starts the console with the relay as its
driver, this process as the relay's master, and a stand-in shell that reads a line
only when the case asks it to.
""".

-include_lib("eunit/include/eunit.hrl").

-export([shell/1]).

-define(WAIT_MS, 2000).

%% A typed line reaches the shell a byte per ask: a group that never asks gets none.
a_typed_line_reaches_the_shell_test() ->
    with_console(fun(Relay, Shell) ->
                         type(Relay, <<"hi\r">>),
                         ?assertEqual("hi\n", get_line(Shell))
                 end).

%% What follows the key that ends a line stays in the tty: the line typed after it in
%% the same burst is read whole by the job the shell then gives the terminal to.
typed_ahead_input_stays_in_the_tty_test() ->
    with_console(fun(Relay, Shell) ->
                         type(Relay, <<"cat\rtwo\r">>),
                         ?assertEqual("cat\n", get_line(Shell)),
                         Shell ! {foreground, job, self()},
                         ?assertMatch({ok, _Termios, 0}, receive {foregrounded, Answer} -> Answer after ?WAIT_MS -> timeout end),
                         {ok, Open} = erx_session_relay:open_reader(relay(), job),
                         ok = erx_session_relay:watch(Open, {read, 100}),
                         N = receive {ready, Open, [{read, 100}], Number} -> Number after ?WAIT_MS -> error(no_report) end,
                         ?assertEqual({ok, <<"two\n">>}, erx_session_relay:read(Open, 100, N))
                 end).

%% A character's bytes read one at a time join before they reach the group, and a byte
%% that belongs to no character reads as latin-1 while the next starts one: C3 then
%% E2 82 AC is U+00C3 and then U+20AC.
characters_join_across_reads_test() ->
    with_console(fun(Relay, Shell) ->
                         type(Relay, <<16#C3, 16#A9, "\r">>),
                         ?assertEqual([16#E9, $\n], get_line(Shell)),
                         type(Relay, <<16#C3, 16#E2, 16#82, 16#AC, "\r">>),
                         ?assertEqual([16#C3, 16#20AC, $\n], get_line(Shell))
                 end).

%% Ctrl-C at the prompt interrupts the line its group serves, and the group's ask stays
%% outstanding, so the next line is read through it.
an_interrupt_at_the_prompt_keeps_the_ask_test() ->
    with_console(fun(Relay, Shell) ->
                         Shell ! {get_line, self()},
                         type(Relay, <<"ab">>),
                         %% The group has drawn the line it is editing, so it serves the request.
                         drawn($b),
                         type(Relay, <<3>>),
                         ?assertEqual({error, interrupted}, line()),
                         type(Relay, <<"x\r">>),
                         ?assertEqual("x\n", get_line(Shell))
                 end).

%% The relay's master hanging up ends every shell on the line and the console.
a_hangup_ends_the_console_test() ->
    with_console(fun(Relay, Shell) ->
                         Console = persistent_term:get({erx_console, line}),
                         Ref = monitor(process, Console),
                         ShellRef = monitor(process, Shell),
                         Shell ! {get_line, self()},
                         Relay ! tty_hangup,
                         receive {'DOWN', ShellRef, process, Shell, _} -> ok after ?WAIT_MS -> error(shell_lives) end,
                         receive {'DOWN', Ref, process, Console, normal} -> ok after ?WAIT_MS -> error(console_lives) end
                 end).

%% A hangup with no read outstanding, while a job holds the terminal and the shell
%% waits on it as the Erlang shell does while it evaluates, ends every shell on the
%% line and the console at once: no read has to find the end of file first.
a_hangup_with_no_read_outstanding_ends_the_console_test() ->
    with_console(fun(Relay, Shell) ->
                         Console = persistent_term:get({erx_console, line}),
                         Ref = monitor(process, Console),
                         ShellRef = monitor(process, Shell),
                         Shell ! {foreground, job, self()},
                         ?assertMatch({ok, _Termios, 0}, receive {foregrounded, Answer} -> Answer after ?WAIT_MS -> timeout end),
                         Relay ! tty_hangup,
                         receive {'DOWN', ShellRef, process, Shell, _} -> ok after ?WAIT_MS -> error(shell_lives) end,
                         receive {'DOWN', Ref, process, Console, normal} -> ok after ?WAIT_MS -> error(console_lives) end
                 end).

%% A background program that sets ICANON, with SIGTTOU ignored, makes VEOF at a line's
%% start an end of file for the console's read. That is the read's end and no hangup:
%% the console answers no ask, no shell ends, and the next line is read through the
%% same ask.
an_end_of_file_on_a_read_ends_no_shell_test() ->
    with_console(fun(Relay, Shell) ->
                         Console = persistent_term:get({erx_console, line}),
                         {ok, Open} = erx_session_relay:open_writer(relay(), background),
                         {ok, #{lflag := L} = Termios} = erx_session_relay:tty(Open, tcgetattr),
                         Canonical = Termios#{lflag := [icanon | L -- [icanon]]},
                         ok = erx_session_relay:tty(Open, {tcsetattr, Canonical, sigttou_ignored}),
                         Shell ! {get_line, self()},
                         type(Relay, <<4>>),
                         type(Relay, <<"x\r">>),
                         ?assertEqual("x\n", line()),
                         ?assert(is_process_alive(Shell)),
                         ?assert(is_process_alive(Console))
                 end).

%% A loss the master reports among its input reaches the group as a loss at its place, so
%% the line it falls in finishes only once the user has emptied it (docs/design-live.md,
%% "Lost input").
a_loss_runs_no_line_test() ->
    with_console(fun(Relay, Shell) ->
                         Shell ! {get_line, self()},
                         type(Relay, <<"cd ">>),
                         lose(Relay),
                         type(Relay, <<"/tmp\r">>),
                         ?assertEqual(timeout, line()),
                         type(Relay, <<21, "pwd\r">>),
                         ?assertEqual("pwd\n", line())
                 end).

%% A loss that a signal's flush drops reaches the console as the relay's `lost` event,
%% ahead of the signal, and damages the read the signal leaves going: Ctrl-\ at the
%% prompt does nothing more, so the line typed on after it does not finish.
a_flushed_loss_damages_the_read_test() ->
    with_console(fun(Relay, Shell) ->
                         Shell ! {get_line, self()},
                         type(Relay, <<"ls">>),
                         drawn($s),
                         lose(Relay),
                         type(Relay, <<28>>),
                         type(Relay, <<"x\r">>),
                         ?assertEqual(timeout, line())
                 end).

%%% The console, the relay and the stand-in shell

with_console(Case) ->
    Test = self(),
    process_flag(trap_exit, true),
    {ok, Console} = erx_console:start_link(
                      #{role => session, domain_line => true, user => none,
                        driver => fun(C) -> {ok, Relay} = erx_session_relay:start_link(C, Test, #{domain_line => true}), {ok, Relay, relay} end,
                        first_shell => {?MODULE, shell, [Test]}}),
    Relay = receive {tty_open, R} -> R after ?WAIT_MS -> error(no_relay) end,
    Shell = receive {shell, S} -> S after ?WAIT_MS -> error(no_shell) end,
    try
        Case(Relay, Shell)
    after
        unlink(Console),
        exit(Console, kill),
        Ref = monitor(process, Relay),
        receive {'DOWN', Ref, process, Relay, _} -> ok after ?WAIT_MS -> error(relay_lives) end,
        flush()
    end.

%% The master's input, numbered for each relay from 0.
type(Relay, Bytes) ->
    N = case get({typed, Relay}) of undefined -> 0; Typed -> Typed end,
    put({typed, Relay}, N + 1),
    Relay ! {tty_input, N, Bytes}.

%% A loss of the master's input, numbered in the same sequence.
lose(Relay) ->
    N = case get({typed, Relay}) of undefined -> 0; Typed -> Typed end,
    put({typed, Relay}, N + 1),
    Relay ! {tty_lost, N}.

relay() -> whereis(erx_tty_owner).

%% Waits for the console's output to the master to carry Byte, taking each output as
%% the console's master does, so the next is sent.
drawn(Byte) ->
    receive
        {tty_output, N, Bytes} ->
            relay() ! {tty_taken, N},
            case binary:match(Bytes, <<Byte>>) of
                nomatch -> drawn(Byte);
                _ -> ok
            end
    after ?WAIT_MS -> error({not_drawn, Byte})
    end.

get_line(Shell) ->
    Shell ! {get_line, self()},
    line().

line() ->
    receive {line, Line} -> Line after ?WAIT_MS -> timeout end.

flush() ->
    receive _ -> flush() after 0 -> ok end.

-doc false.
%% The stand-in shell the console's first group starts: it reads a line, in unicode,
%% only when asked, and hands the terminal to a job when asked.
shell(Test) ->
    spawn(fun() -> Test ! {shell, self()}, shell_loop() end).

shell_loop() ->
    receive
        {get_line, From} ->
            ok = io:setopts([{encoding, unicode}]),
            From ! {line, io:get_line("")};
        {foreground, Tag, From} ->
            From ! {foregrounded, erx_session_relay:foreground(relay(), Tag, cooked, {group_leader(), 0})}
    end,
    shell_loop().
