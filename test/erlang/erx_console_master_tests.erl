%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_console_master_tests).
-moduledoc """
The console as the master of a session's tty, end to end on the host: a console
on a fake line driver with a small shell of its own as the system shell, and
the test as the session's tty relay, behind a console facet minted as the
domain service mints one (erx_domain_facet, with the limits erx_console:facet/0
names). Messages from the session arrive at the facet in their envelope, as the
peer delivers them. This module stands in for the export table.

The line takes a session's output only while the session is connected, and
answers {tty_taken, N} only once it has written it; typed input goes to the
connected session as {tty_input, Bytes}, except Ctrl-G, which never reaches a
session and returns the line to the system shell; a wrong number detaches the
tty for good; a 5 KiB message never reaches the console; and a session whose
facet ends gives the line back.
""".

-include_lib("eunit/include/eunit.hrl").

-export([export/3, owner/1, shell/0, marker/1]).

-define(WAIT_MS, 3000).
-define(QUIET_MS, 300).

export(_Pid, _Rights, _Peer) -> ok.

%% Every name of the test's node is session 7's, so the test can call as its grantee.
owner(_Name) -> 7.

%% A shell that, if it ever starts, says so.
marker(Test) ->
    spawn_link(fun() -> Test ! system_code_ran end).

%% The system shell: each line it reads comes back as "sys:" and the line.
shell() ->
    Group = self(),
    spawn_link(fun() -> group_leader(Group, self()), shell_loop() end).

shell_loop() ->
    case io:get_line("") of
        eof -> ok;
        Line -> io:put_chars(["sys:", Line]), shell_loop()
    end.

%% The fake driver: the line's bytes go to the test, and each write is done at once.
driver(Test) ->
    fun(Console) ->
            Pid = spawn_link(fun Loop() ->
                                     receive
                                         {erx_console_output, From, Bytes} ->
                                             Test ! {line, iolist_to_binary(Bytes)},
                                             Console ! {erx_console_written, From},
                                             Loop()
                                     end
                             end),
            {ok, Pid, true}
    end.

master_test_() ->
    {timeout, 60, fun master/0}.

master() ->
    process_flag(trap_exit, true),
    {ok, Console} = erx_console:start_link(#{role => session, name => erx_console,
                                             driver => driver(self()),
                                             first_shell => {?MODULE, shell, []}}),
    type(<<"a\r">>),
    {ok, _} = await(<<"sys:a">>),
    Domain = spawn(fun() -> receive after infinity -> ok end end),
    Facet = facet(7, Domain, Console),
    ok = erx_console:add_session(7, self()),
    a_grantees_calls_reach_nothing(Facet),
    held_until_connected(Facet),
    input_goes_to_the_session(),
    output_and_repeats(Facet),
    ctrl_g_returns_the_line(Facet),
    a_wrong_number_detaches(Facet),
    the_facet_bounds_messages(Console),
    a_session_that_ends_gives_the_line_back(Console),
    the_facets_end_with_the_console(Console, Facet).

%% The console facet takes the tty's messages and nothing else: every call of the
%% grantee's is refused, so a session cannot run a shell in the system domain, write
%% to the line, take it, name another tty or speak for another domain's tty.
a_grantees_calls_reach_nothing(Facet) ->
    Calls = [{run_shell, {?MODULE, marker, [self()]}}, {write, <<"FORGED">>}, {connect, 7}, detach,
             {add_session, 99, self()}, {erx_facet_message, 99, {tty_output, 0, <<"AS99">>}},
             {'$erx_facet_message', 99, {tty_output, 0, <<"AS99">>}}],
    [?assertEqual({Call, {error, badarg}}, {Call, call(Facet, Call)}) || Call <- Calls],
    ?assertEqual(none, receive system_code_ran -> ran after ?QUIET_MS -> none end),
    nothing_on_the_line(),
    nothing_from_the_console(),
    ?assertEqual({error, unknown}, erx_console:connect(99)).

%% Output from a session that is not connected is held and not answered: its tty is
%% stopped. Connecting writes it, with the size first, and only then answers.
held_until_connected(Facet) ->
    tty_output(Facet, 0, <<"S0">>),
    nothing_from_the_console(),
    ok = erx_console:connect(7),
    ?assertEqual({tty_size, 24, 80}, from_console()),
    {ok, _} = await(<<"S0">>),
    ?assertEqual({tty_taken, 0}, from_console()).

input_goes_to_the_session() ->
    type(<<"ls\r">>),
    ?assertEqual({tty_input, <<"ls\r">>}, from_console()),
    nothing_on_the_line().

output_and_repeats(Facet) ->
    tty_output(Facet, 1, <<"S1">>),
    {ok, _} = await(<<"S1">>),
    ?assertEqual({tty_taken, 1}, from_console()),
    %% A repeat of the output last taken: answered again, with the size.
    tty_output(Facet, 1, <<>>),
    ?assertEqual({tty_taken, 1}, from_console()),
    ?assertEqual({tty_size, 24, 80}, from_console()).

%% Ctrl-G never reaches the session: the bytes before it do, and the line goes back to
%% the system shell, which gets the bytes after it. The session is stopped again.
ctrl_g_returns_the_line(Facet) ->
    type(<<"x", $\^G, "b\r">>),
    ?assertEqual({tty_input, <<"x">>}, from_console()),
    {ok, _} = await(<<"sys:b">>),
    nothing_from_the_console(),
    tty_output(Facet, 2, <<"S2">>),
    nothing_from_the_console(),
    ok = erx_console:connect(7),
    {ok, _} = await(<<"S2">>),
    ?assertEqual({tty_taken, 2}, from_console()).

%% A number that is neither the next nor a repeat detaches the tty: nothing of it is
%% written or answered, the line goes back to the system shell, and the session can
%% never be connected again.
a_wrong_number_detaches(Facet) ->
    tty_output(Facet, 9, <<"BAD">>),
    nothing_from_the_console(),
    type(<<"c\r">>),
    {ok, Seen} = await(<<"sys:c">>),
    ?assertEqual(nomatch, binary:match(Seen, <<"BAD">>)),
    ?assertEqual({error, refused}, erx_console:connect(7)),
    tty_output(Facet, 3, <<"S3">>),
    nothing_from_the_console().

%% The console facet takes the largest output the tty sends, 4 KiB with a large number,
%% and drops a 5 KiB one before the console sees it.
the_facet_bounds_messages(Console) ->
    Facet = facet(8, spawn(fun() -> receive after infinity -> ok end end), Console),
    ok = erx_console:add_session(8, self()),
    Facet ! {erx_origin, 8, {tty_output, 0, binary:copy(<<$y>>, 5120)}},
    Full = binary:copy(<<$z>>, 4096),
    Facet ! {erx_origin, 8, {tty_output, 0, Full}},
    ok = erx_console:connect(8),
    ?assertEqual({tty_size, 24, 80}, from_console()),
    {ok, Seen} = await(Full),
    ?assertEqual(nomatch, binary:match(Seen, <<"yyyy">>)),
    ?assertEqual({tty_taken, 0}, from_console()),
    ?assertMatch(#{dropped := 1}, erx_facet:info(Facet)).

%% A session's facet ends with its domain, and the session with it: the line goes back
%% to the system shell, with a notice naming the domain.
a_session_that_ends_gives_the_line_back(Console) ->
    Domain = spawn(fun() -> receive after infinity -> ok end end),
    Facet = facet(9, Domain, Console),
    ok = erx_console:add_session(9, self()),
    tty_output(Facet, 0, <<"S9">>),
    ok = erx_console:connect(9),
    ?assertEqual({tty_size, 24, 80}, from_console()),
    {ok, _} = await(<<"S9">>),
    ?assertEqual({tty_taken, 0}, from_console()),
    exit(Domain, kill),
    {ok, _} = await(<<"domain 9">>),
    type(<<"d\r">>),
    {ok, _} = await(<<"sys:d">>),
    ?assertEqual({error, unknown}, erx_console:connect(9)).

%% A console that stops, normally too, ends every console facet in front of it, so no
%% session's tty is left asking a master that is gone.
the_facets_end_with_the_console(Console, Facet) ->
    Monitor = monitor(process, Facet),
    unlink(Console),
    ok = gen_server:stop(Console),
    ?assertEqual(normal, receive {'DOWN', Monitor, process, _, R} -> R after ?WAIT_MS -> runs_on end).

%%% Helpers

%% A console facet for Grantee, minted as the domain service mints one from a spec's
%% `console => erx_console:facet()`, ending with Domain or the process behind it.
facet(Grantee, Domain, _Console) ->
    {Behind, Limits} = erx_console:facet(),
    {ok, Facet} = erx_facet:start(erx_domain_facet,
                                  Limits#{grantee => Grantee, ends_with => [Domain, Behind],
                                          behind => Behind},
                                  #{exports => ?MODULE}),
    Facet.

%% A gen_server call of the grantee's to Facet, as it arrives from its domain: the reply,
%% or none.
call(Facet, Request) ->
    Alias = alias(),
    Facet ! {erx_origin, 7, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after ?WAIT_MS -> none end.

%% Output N of the tty behind Facet, in the envelope of the facet's grantee.
tty_output(Facet, N, Bytes) ->
    #{grantee := Grantee} = erx_facet:info(Facet),
    Facet ! {erx_origin, Grantee, {tty_output, N, Bytes}}.

type(Bytes) ->
    erx_console ! {erx_console_input, Bytes}.

%% The next of the console's messages to the session's tty, the test.
from_console() ->
    receive
        {tty_taken, _} = M -> M;
        {tty_input, _} = M -> M;
        {tty_size, _, _} = M -> M;
        tty_hangup = M -> M
    after ?WAIT_MS -> none
    end.

nothing_from_the_console() ->
    ?assertEqual(none, receive
                           {tty_taken, _} = M -> M;
                           {tty_input, _} = M -> M;
                           {tty_size, _, _} = M -> M
                       after ?QUIET_MS -> none
                       end).

%% No bytes reach the line; the shell's empty prompt is no bytes.
nothing_on_the_line() ->
    ?assertEqual(none, receive {line, Bytes} when Bytes =/= <<>> -> Bytes after ?QUIET_MS -> none end).

%% The line's bytes up to and including Pattern.
await(Pattern) ->
    await(Pattern, <<>>).

await(Pattern, Seen) ->
    case binary:match(Seen, Pattern) of
        nomatch ->
            receive {line, Bytes} -> await(Pattern, <<Seen/binary, Bytes/binary>>)
            after ?WAIT_MS -> {timeout, Seen}
            end;
        _ ->
            {ok, Seen}
    end.
