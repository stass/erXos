%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the session's line to the SSH domain (erx_tty_line over
%% erx_session_line, and its core, erx_tty_line_core; docs/design-ssh.md, "Sessions,
%% ttys and shells"; docs/design-system.md, "A session's lines"): the line's mint, the
%% shape checks of open_tty through its facet, a channel of a third domain, the channel
%% limit, the exit report and the bound of a request. The export table, the session's
%% connection to the grantee, the opening and the tty opener are the test's stand-ins,
%% and the test is the domain pid a mint replies to (erx_facet:minted/2);
%% erx_session_tty_tests covers the tty a channel gets and its report of the shell's
%% status.
-module(erx_tty_line_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([owner/1, export/3]).

-define(PEER, 5).
-define(SYSTEM, 4).
-define(OTHER, 9).
-define(TESTER, erx_tty_line_tests_test).
-define(SHELL, {open_tty, self(), shell, <<"vt100">>, 24, 80}).

%% The export table's stand-in: every name is the peer's unless a test has claimed it for
%% another domain.
owner(Name) when is_pid(Name); is_reference(Name); is_port(Name) ->
    persistent_term:get({?MODULE, owner, Name}, ?PEER).

%% Every export is taken and told to the test.
export(Name, Rights, Peer) ->
    ?TESTER ! {exported, Name, Rights, Peer},
    ok.

%% A process standing for the session's connection to the grantee or for the opening,
%% which lives until it is told to stop.
stand_in() ->
    spawn(fun() -> receive stop -> ok end end).

%% A line whose opener tells the test each open and answers with a fresh tty, a process
%% that reports a status through the line's Notify and ends when the test tells it to,
%% or the error the test asked for; its connection to any grantee is a stand-in.
line() ->
    _ = [unregister(?TESTER) || whereis(?TESTER) =/= undefined],
    register(?TESTER, self()),
    Open = fun(Channel, Spec = #{run := Run, size := Size}, Notify) ->
                   case persistent_term:get({?MODULE, open_error}, none) of
                       none ->
                           Tty = spawn(fun() -> stand_in_tty(Notify) end),
                           ?TESTER ! {opened, Tty, Channel, Run, Size},
                           ?TESTER ! {vars, Tty, maps:get(vars, Spec, none)},
                           {ok, Tty};
                       Error ->
                           {error, Error}
                   end
           end,
    Conn = stand_in(),
    {ok, Line} = erx_tty_line:start_link(#{system => ?SYSTEM, exports => ?MODULE, open => Open,
                                           connection => fun(_Grantee) -> {ok, Conn} end}),
    Line.

stand_in_tty(Notify) ->
    receive
        {notify, Status} -> Notify(Status), stand_in_tty(Notify);
        stop -> ok
    end.

%% The mint request of the line Name for Grantee, in Domain's envelope, and the line's
%% reply, or none.
mint(Line, Domain, Name, Grantee) ->
    persistent_term:put({erx, domain_pid}, self()),
    Tag = erlang:unique_integer([positive]),
    Limits = (maps:get(tty_line, ?ERX_LINES))#{opening => stand_in()},
    Line ! {erx_origin, Domain, {erx_facet_mint, Tag, Name, Grantee, <<"root">>, Limits}},
    receive {erx_facet_minted, Tag, Reply} -> Reply after 500 -> none end.

%% A line with its facet minted for the peer, as a login of the SSH domain's starting
%% the session does, and that facet.
open_line() ->
    Line = line(),
    {ok, Facet} = mint(Line, ?SYSTEM, tty_line, ?PEER),
    ?assertEqual(ok, receive {exported, Facet, [send], ?PEER} -> ok after 1000 -> none end),
    {Line, Facet}.

facet() ->
    {_Line, Facet} = open_line(),
    Facet.

%% Request in Domain's envelope as a call, and the answer, or none.
call(To, Domain, Request) ->
    Alias = alias([reply]),
    To ! {erx_origin, Domain, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 300 -> unalias(Alias), none end.

opened() ->
    receive {opened, Tty, Channel, Run, Size} -> {Tty, Channel, Run, Size} after 1000 -> none end.

%% The mint request in the system domain's envelope starts a facet bound to the peer and
%% exported to it with send alone; the same request in the peer's envelope, naming the
%% system domain as grantee, or naming another line starts none, and a call to the line
%% process itself in the peer's envelope opens nothing, before the mint or after it.
%% Through the facet the line serves its grantee alone.
mint_test() ->
    Line = line(),
    ?assertEqual(none, mint(Line, ?PEER, tty_line, ?PEER)),
    ?assertEqual(none, mint(Line, ?SYSTEM, tty_line, ?SYSTEM)),
    ?assertEqual(none, mint(Line, ?SYSTEM, web_line, ?PEER)),
    ?assertEqual(none, receive {exported, _, _, _} = Early -> Early after 0 -> none end),
    ?assertEqual(none, call(Line, ?PEER, ?SHELL)),
    {ok, Facet} = mint(Line, ?SYSTEM, tty_line, ?PEER),
    ?assertEqual(ok, receive {exported, Facet, [send], ?PEER} -> ok after 0 -> none end),
    ?assertEqual(none, call(Line, ?PEER, ?SHELL)),
    ?assertEqual(none, opened()),
    ?assertEqual(ok, call(Facet, ?PEER, ?SHELL)),
    ?assertMatch({_, _, shell, _}, opened()),
    ?assertEqual(none, call(Facet, ?OTHER, ?SHELL)),
    ?assertEqual(none, opened()).

%% Every shape but open_tty's, and every field outside its bounds, is badarg, and opens
%% nothing; the bounds themselves are taken.
request_shapes_test() ->
    Facet = facet(),
    Me = self(),
    Bad = [nonsense, {open_tty}, {open_tty, Me, shell, <<"xterm">>, 24},
           {open_tty, not_a_pid, shell, <<"xterm">>, 24, 80},
           {open_tty, Me, login, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, <<>>}, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, <<"echo", 0, "x">>}, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, binary:copy(<<"a">>, 32769)}, <<"xterm">>, 24, 80},
           {open_tty, Me, {exec, "echo"}, <<"xterm">>, 24, 80},
           {open_tty, Me, shell, "xterm", 24, 80},
           {open_tty, Me, shell, binary:copy(<<"x">>, 65), 24, 80},
           {open_tty, Me, shell, <<"xterm">>, -1, 80},
           {open_tty, Me, shell, <<"xterm">>, 24, 65536},
           {open_tty, Me, shell, <<"xterm">>, 24.0, 80}],
    [?assertEqual({Request, {error, badarg}}, {Request, call(Facet, ?PEER, Request)}) || Request <- Bad],
    ?assertEqual(none, opened()),
    Command = binary:copy(<<"a">>, 32768),
    ?assertEqual(ok, call(Facet, ?PEER, {open_tty, Me, {exec, Command}, binary:copy(<<"x">>, 64), 0, 65535})),
    ?assertMatch({_, Me, {exec, Command}, _}, opened()).

%% A channel that is no process of the peer's is badarg, so the session never sends a
%% tty's bytes to a third domain.
foreign_channel_test() ->
    Facet = facet(),
    Foreign = spawn(fun() -> ok end),
    persistent_term:put({?MODULE, owner, Foreign}, ?OTHER),
    try
        ?assertEqual({error, badarg}, call(Facet, ?PEER, {open_tty, Foreign, shell, <<"vt100">>, 24, 80})),
        ?assertEqual(none, opened())
    after
        persistent_term:erase({?MODULE, owner, Foreign})
    end.

%% A call in the peer's envelope whose alias, or whose caller, is a third domain's is
%% dropped unanswered, so a reply never goes there, and opens nothing.
third_domain_caller_test() ->
    Facet = facet(),
    Alias = alias([reply]),
    persistent_term:put({?MODULE, owner, Alias}, ?OTHER),
    try
        Facet ! {erx_origin, ?PEER, {'$gen_call', {self(), [alias | Alias]}, ?SHELL}},
        ?assertEqual(none, receive {[alias | Alias], Reply} -> Reply after 300 -> none end)
    after
        persistent_term:erase({?MODULE, owner, Alias})
    end,
    persistent_term:put({?MODULE, owner, self()}, ?OTHER),
    try
        ?assertEqual(none, call(Facet, ?PEER, ?SHELL))
    after
        persistent_term:erase({?MODULE, owner, self()})
    end,
    ?assertEqual(none, opened()).

%% Past ten open channels the line answers limited; a tty's end frees its place.
limited_test() ->
    Facet = facet(),
    Open = [begin
                ?assertEqual(ok, call(Facet, ?PEER, ?SHELL)),
                opened()
            end || _ <- lists:seq(1, 10)],
    ?assertEqual({error, limited}, call(Facet, ?PEER, ?SHELL)),
    [{Tty, _, _, _} | _] = Open,
    Tty ! stop,
    ?assertEqual(ok, wait_ok(Facet, 20)),
    ?assertMatch({_, _, shell, _}, opened()).

wait_ok(_Facet, 0) -> gave_up;
wait_ok(Facet, N) ->
    case call(Facet, ?PEER, ?SHELL) of
        ok -> ok;
        {error, limited} -> timer:sleep(50), wait_ok(Facet, N - 1)
    end.

%% A tty that cannot be started is answered limited.
open_failure_test() ->
    Facet = facet(),
    persistent_term:put({?MODULE, open_error}, no_room),
    try
        ?assertEqual({error, limited}, call(Facet, ?PEER, ?SHELL))
    after
        persistent_term:erase({?MODULE, open_error})
    end.

%% The tty's report of how its shell ended reaches the channel as that ending, sent by
%% the line: {exited, Status}, or {signaled, sigint} for an exec Ctrl-C ended; the same
%% report from a process that is no tty of the line's reaches no one. The line passes a
%% tty's ending on as erx_console:shell_ending/1 made it (erx_console_shell_tests).
ending_reaches_the_channel_test_() ->
    [?_assertEqual(Ending, ending_on_the_channel(Ending))
     || Ending <- [{exited, 0}, {exited, 4}, {exited, 255}, {signaled, sigint}]].

ending_on_the_channel(Ending) ->
    {Line, Facet} = open_line(),
    ?assertEqual(ok, call(Facet, ?PEER, {open_tty, self(), {exec, <<"exit 4">>}, <<"vt100">>, 24, 80})),
    {Tty, Channel, _Run, _Size} = opened(),
    ?assertEqual(self(), Channel),
    Line ! {erx_tty_line, ended, spawn(fun() -> ok end), {exited, 5}},
    Tty ! {notify, Ending},
    Reported = receive {exited, _} = Exited -> Exited; {signaled, _} = Signaled -> Signaled
               after 1000 -> none
               end,
    ?assertEqual(none, receive {exited, _} = Other -> Other; {signaled, _} = Other -> Other
                       after 300 -> none
                       end),
    Reported.

%% The tty opens at the size asked for, a side of zero being 24 rows or 80 columns.
size_test() ->
    Facet = facet(),
    [begin
         ?assertEqual(ok, call(Facet, ?PEER, {open_tty, self(), shell, <<"vt100">>, Rows, Columns})),
         ?assertMatch({_, _, shell, Size}, opened())
     end || {Rows, Columns, Size} <- [{30, 100, {30, 100}}, {0, 0, {24, 80}}, {0, 132, {24, 132}}, {50, 0, {50, 80}}]].

%% The shell's TERM is the channel's Term when abi/terminal.txt lists it and vt100 for
%% any other name: an unknown one, an empty one, another case, or one that carries an
%% escape sequence, so no byte of the peer's reaches the shell's variables.
term_test() ->
    Facet = facet(),
    [begin
         ?assertEqual(ok, call(Facet, ?PEER, {open_tty, self(), shell, Term, 24, 80})),
         {Tty, _, shell, _} = opened(),
         ?assertEqual({Term, #{<<"TERM">> => [Given]}}, {Term, receive {vars, Tty, Vars} -> Vars after 1000 -> none end})
     end || {Term, Given} <- [{<<"vt100">>, <<"vt100">>}, {<<"xterm">>, <<"xterm">>},
                              {<<"xterm-256color">>, <<"xterm-256color">>}, {<<"ansi">>, <<"vt100">>},
                              {<<>>, <<"vt100">>}, {<<"XTERM">>, <<"vt100">>},
                              {<<"xterm", 27, "]0;owned", 7>>, <<"vt100">>}]].

%% The largest request the line serves, an exec of a 32 KiB command with a 64-byte TERM
%% from a caller whose pid and alias are of a 255-character node name, fits tty_line's
%% max_request under both measures, and that bound is the smallest power of two not
%% below the larger of them; through the facet such a request is served, and an exec
%% past max_request is dropped unanswered and counted, before the line sees it.
request_bound_test() ->
    Facet = facet(),
    Me = self(),
    Largest = {open_tty, Me, {exec, binary:copy(<<"a">>, 32768)}, binary:copy(<<"x">>, 64), 65535, 65535},
    Max = maps:get(max_request, maps:get(tty_line, ?ERX_LINES)),
    Measure = erx_line_bound:measure(Largest),
    ?assert(Measure =< Max andalso Measure > Max div 2),
    ?assertEqual(ok, call(Facet, ?PEER, Largest)),
    ?assertMatch({_, Me, {exec, _}, {65535, 65535}}, opened()),
    #{dropped := Dropped} = erx_facet:info(Facet),
    ?assertEqual(none, call(Facet, ?PEER, {open_tty, Me, {exec, binary:copy(<<"a">>, Max)}, <<"vt100">>, 24, 80})),
    ?assertEqual(Dropped + 1, maps:get(dropped, erx_facet:info(Facet))),
    ?assertEqual(none, opened()).
