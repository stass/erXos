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
connected session as {tty_input, Bytes}, a terminal's OSC reply whole, except a
typed Ctrl-G, which never reaches a session and opens the Ctrl-G menu; the menu
lists only the line principal's live sessions, by their escaped names, and
connects one or gives the line to the system shell; a wrong number detaches the
tty for good; a 5 KiB message never reaches the console; and a session whose
domain pid or facet ends gives the line back.
""".

-include_lib("eunit/include/eunit.hrl").

-export([export/3, owner/1, shell/0, marker/1, log/2]).

-define(WAIT_MS, 3000).
-define(QUIET_MS, 300).
-define(ESC, 16#1B).

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
    {ok, Console} = erx_console:start_link(#{role => session, name => erx_console, menu => true, principal => 1,
                                             owner => fun tty_owner/1,
                                             driver => driver(self()),
                                             first_shell => {?MODULE, shell, []}}),
    type(<<"a\r">>),
    {ok, _} = await(<<"sys:a">>),
    the_system_shell_has_the_menu_too(),
    Domain = spawn(fun() -> receive after infinity -> ok end end),
    Facet = facet(7, Domain, Console),
    ok = erx_console:add_session(7, session(<<"root_1">>, 1, Domain)),
    ok = tty_named(Facet),
    a_grantees_calls_reach_nothing(Facet),
    held_until_connected(Facet),
    input_goes_to_the_session(),
    output_and_repeats(Facet),
    a_lost_output_is_logged(Facet),
    a_terminal_reply_stays_with_the_session(),
    ctrl_g_opens_the_menu(Facet),
    a_wrong_number_detaches(Facet),
    the_facet_bounds_messages(Console),
    the_menu_lists_the_principals_live_sessions(),
    a_session_that_ends_gives_the_line_back(Console),
    a_tty_names_itself(Console),
    the_end_line_is_escaped(Console),
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

%% A resend whose first send was lost arrives as the next output with no bytes: the
%% console takes it, and logs a line naming the session's domain and the output's number. The
%% node's other log handlers are silenced meanwhile: the console is the node's `user`,
%% so their copy of the line would reach the line under test.
a_lost_output_is_logged(Facet) ->
    Silenced = [{Id, Level} || #{id := Id, level := Level} <- logger:get_handler_config()],
    [ok = logger:update_handler_config(Id, level, none) || {Id, _} <- Silenced],
    ok = logger:add_handler(lost_output_probe, ?MODULE, #{config => #{to => self()}}),
    {Taken, Logged} =
        try
            tty_output(Facet, 2, <<>>),
            {from_console(),
             receive {logged, #{msg := {"erx_console: output" ++ _ = Format, Args}}} ->
                     lists:flatten(io_lib:format(Format, Args))
             after ?WAIT_MS -> none
             end}
        after
            ok = logger:remove_handler(lost_output_probe),
            [ok = logger:update_handler_config(Id, level, Level) || {Id, Level} <- Silenced]
        end,
    ?assertEqual({tty_taken, 2}, Taken),
    ?assertEqual("erx_console: output 2 of domain 7's tty was lost on its way to the console", Logged).

%% The logger handler a_lost_output_is_logged/1 adds: each event goes to the test.
log(Event, #{config := #{to := To}}) ->
    To ! {logged, Event}.

%% The BEL that ends a terminal's OSC reply is no Ctrl-G: the whole reply goes to the
%% session that asked for it, which keeps the line, and so does what is typed next.
a_terminal_reply_stays_with_the_session() ->
    Reply = <<"\e]11;rgb:0000/0000/0000", $\^G>>,
    type(Reply),
    ?assertEqual({tty_input, Reply}, from_console()),
    type(<<"q\r">>),
    ?assertEqual({tty_input, <<"q\r">>}, from_console()),
    nothing_on_the_line().

%% Ctrl-G at the system shell opens the menu too, which lists no session yet, and Esc
%% gives the line back to the system shell, which reads on.
the_system_shell_has_the_menu_too() ->
    type(<<$\^G>>),
    {ok, Menu} = await(<<"Esc returns. ">>),
    ?assertMatch({_, _}, binary:match(Menu, <<"  s* system shell\r\n  n  start a session\r\n">>)),
    type(<<?ESC>>),
    type(<<"e\r">>),
    {ok, _} = await(<<"sys:e">>).

%% Ctrl-G never reaches the session: the bytes before it do, the menu takes the line, and
%% the rest of the read that carried it is dropped. The session is stopped while the menu
%% or the system shell has the line, and its key connects it again.
ctrl_g_opens_the_menu(Facet) ->
    type(<<"x", $\^G, "b\r">>),
    ?assertEqual({tty_input, <<"x">>}, from_console()),
    {ok, Menu} = await(<<"Esc returns. ">>),
    ?assertMatch({_, _}, binary:match(Menu, <<"  s  system shell\r\n  1* root_1 (domain 7)\r\n">>)),
    nothing_from_the_console(),
    nothing_on_the_line(),
    tty_output(Facet, 3, <<"S3">>),
    nothing_from_the_console(),
    type(<<"s">>),
    type(<<"b\r">>),
    {ok, _} = await(<<"sys:b">>),
    nothing_from_the_console(),
    type(<<$\^G>>),
    {ok, _} = await(<<"Esc returns. ">>),
    type(<<"1">>),
    {ok, _} = await(<<"S3">>),
    ?assertEqual({tty_taken, 3}, from_console()).

%% The menu lists only the live sessions of the line's principal, each name through the
%% line escape: not another principal's, not one refused, and not one whose domain pid is
%% down, which connect/1 refuses too. A read of more than one byte is no key, and only
%% rings the bell; "start a session" is refused; Esc returns the line to the session that
%% had it.
the_menu_lists_the_principals_live_sessions() ->
    Up = fun() -> spawn(fun() -> receive after infinity -> ok end end) end,
    Theirs = Up(),
    ok = erx_console:add_session(10, session(<<"theirs">>, 2, Theirs)),
    Listed = Up(),
    ok = erx_console:add_session(11, session(<<"x\e]0;owned", $\^G, "\e[2J">>, 1, Listed)),
    ok = tty_named(facet(11, Listed, erx_console)),
    Down = Up(),
    ok = erx_console:add_session(12, session(<<"gone">>, 1, Down)),
    ok = tty_named(facet(12, Down, erx_console)),
    exit(Down, kill),
    ?assertEqual({error, unknown}, erx_console:connect(12)),
    type(<<$\^G>>),
    {ok, Menu} = await(<<"Esc returns. ">>),
    ?assertMatch({_, _}, binary:match(Menu, <<"  1* root_2 (domain 8)\r\n  2  x">>)),
    [?assertEqual({Absent, nomatch}, {Absent, binary:match(Menu, Absent)})
     || Absent <- [<<"theirs">>, <<"gone">>, <<"root_1">>, <<"\e]0;owned">>, <<$\^G>>, <<"\e[2J">>]],
    type(<<"12">>),
    {ok, _} = await(<<$\^G>>),
    type(<<"n">>),
    {ok, _} = await(<<"cannot start a session: enotsup">>),
    {ok, _} = await(<<"Esc returns. ">>),
    %% Another principal's session ends: this line's menu does not name it.
    exit(Theirs, kill),
    nothing_on_the_line(),
    %% A byte of a terminal's reply read alone is no key, and Esc then returns: a
    %% device report's digit and final byte, and a string's byte.
    type(<<"\e[?6">>),
    type(<<"1">>),
    type(<<"c">>),
    type(<<"\e]11;">>),
    type(<<"s">>),
    type(<<$\^G>>),
    {ok, _} = await(<<$\^G>>),
    nothing_from_the_console(),
    type(<<?ESC>>),
    type(<<"z">>),
    ?assertEqual({tty_input, <<"z">>}, from_console()).


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
    tty_output(Facet, 4, <<"S4">>),
    nothing_from_the_console().

%% The console facet takes the largest output the tty sends, 4 KiB with a large number,
%% and drops a 5 KiB one before the console sees it.
the_facet_bounds_messages(Console) ->
    Facet = facet(8, spawn(fun() -> receive after infinity -> ok end end), Console),
    ok = erx_console:add_session(8, session(<<"root_2">>, 1, spawn(fun() -> receive after infinity -> ok end end))),
    ok = tty_named(Facet),
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
%% to the system shell after one line, which names the session and how its domain ended.
a_session_that_ends_gives_the_line_back(Console) ->
    Domain = spawn(fun() -> receive after infinity -> ok end end),
    Facet = facet(9, Domain, Console),
    ok = erx_console:add_session(9, session(<<"root_3">>, 1, Domain)),
    ok = tty_named(Facet),
    tty_output(Facet, 0, <<"S9">>),
    ok = erx_console:connect(9),
    ?assertEqual({tty_size, 24, 80}, from_console()),
    {ok, _} = await(<<"S9">>),
    ?assertEqual({tty_taken, 0}, from_console()),
    exit(Domain, {domain_down, 9, {halt, 3}}),
    {ok, _} = await(<<"\r\nsession root_3 ended: {halt,3}\r\n">>),
    type(<<"d\r">>),
    {ok, _} = await(<<"sys:d">>),
    ?assertEqual({error, unknown}, erx_console:connect(9)).

%% A session the console did not hear a tty for names it through its facet: the first
%% {tty_open, Tty} names it when Tty is the grantee's own, which the console takes every
%% pid of the test for in domain 14, and the session can then connect; for another grantee the
%% same pid fails the check, and that tty is detached for good.
a_tty_names_itself(Console) ->
    Up = fun() -> spawn(fun() -> receive after infinity -> ok end end) end,
    Facet = facet(14, Up(), Console),
    ok = erx_console:add_session(14, session(<<"root_4">>, 1, Up())),
    ?assertEqual({error, no_tty}, erx_console:connect(14)),
    Facet ! {erx_origin, 14, {tty_open, self()}},
    Facet ! {erx_origin, 14, {tty_open, self()}},
    tty_output(Facet, 0, <<"S14">>),
    ok = wait_connect(14),
    ?assertEqual({tty_size, 24, 80}, from_console()),
    {ok, _} = await(<<"S14">>),
    ?assertEqual({tty_taken, 0}, from_console()),
    Other = facet(12, Up(), Console),
    ok = erx_console:add_session(12, session(<<"theirs">>, 1, Up())),
    Other ! {erx_origin, 12, {tty_open, self()}},
    ?assertEqual({error, refused}, wait_refused(12)),
    ok = erx_console:detach().

%% The end line is attributed text: a session's name and how it ended reach the line
%% only through the line escape, so neither can write a control sequence there.
the_end_line_is_escaped(Console) ->
    Domain = spawn(fun() -> receive after infinity -> ok end end),
    Facet = facet(13, Domain, Console),
    ok = erx_console:add_session(13, session(<<"x\e]0;owned", $\^G>>, 1, Domain)),
    ok = tty_named(Facet),
    tty_output(Facet, 0, <<"S13">>),
    ok = erx_console:connect(13),
    {ok, _} = await(<<"S13">>),
    exit(Domain, {domain_down, 13, {crash, <<"\e[2J", 16#9B>>}}),
    %% The console writes the line whole, so the bytes that hold " ended: " hold all of it.
    {ok, Seen} = await(<<" ended: ">>),
    [_, Ended] = binary:split(Seen, <<"session ">>),
    ?assertMatch({_, _}, binary:match(Ended, <<"\r\n">>)),
    ?assertEqual(nomatch, binary:match(Ended, [<<?ESC>>, <<$\^G>>, <<16#9B>>])).

%% connect/1 once the console has taken the tty's naming, which arrives through the facet.
wait_connect(Domain) ->
    wait_connect(Domain, 20).

wait_connect(Domain, 0) -> erx_console:connect(Domain);
wait_connect(Domain, Left) ->
    case erx_console:connect(Domain) of
        {error, no_tty} -> timer:sleep(50), wait_connect(Domain, Left - 1);
        Answer -> Answer
    end.

%% connect/1 once the console has refused the tty that named itself.
wait_refused(Domain) ->
    wait_refused(Domain, 20).

wait_refused(Domain, 0) -> erx_console:connect(Domain);
wait_refused(Domain, Left) ->
    case erx_console:connect(Domain) of
        {error, refused} = Refused -> Refused;
        _ -> timer:sleep(50), wait_refused(Domain, Left - 1)
    end.

%% A console that stops, normally too, ends every console facet in front of it, so no
%% session's tty is left asking a master that is gone.
the_facets_end_with_the_console(Console, Facet) ->
    Monitor = monitor(process, Facet),
    unlink(Console),
    ok = gen_server:stop(Console),
    ?assertEqual(normal, receive {'DOWN', Monitor, process, _, R} -> R after ?WAIT_MS -> runs_on end).

%%% Helpers

%% What add_session/2 names of a session.
session(Name, Principal, DomainPid) ->
    #{name => Name, principal => Principal, domain_pid => DomainPid}.

%% The domain whose tty Pid is, as the console's owner check asks: a tty that
%% tty_named/1 made is its facet's grantee's, and any other pid of the test is domain 14's.
tty_owner(Pid) -> persistent_term:get({?MODULE, tty, Pid}, 14).

%% A tty of Facet's grantee, which hands the test what the console sends it, named to the
%% console through Facet as a session's tty names itself; it returns once the console has
%% taken the naming, since the facet forwards before it answers its info call and the
%% console reads the forward before the test's call that follows.
tty_named(Facet) ->
    #{grantee := Grantee} = erx_facet:info(Facet),
    Test = self(),
    Tty = spawn(fun Relay() -> receive Message -> Test ! Message, Relay() end end),
    persistent_term:put({?MODULE, tty, Tty}, Grantee),
    Facet ! {erx_origin, Grantee, {tty_open, Tty}},
    _ = erx_facet:info(Facet),
    _ = erx_console:facet(),
    ok.

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
