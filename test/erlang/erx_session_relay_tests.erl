%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The terminal relay's server, erx_session_relay (docs/design-shell.md, "The
%% terminal relay's protocol"), around its core: the cases that belong to the
%% edge, which answers before it acts, holds the name, monitors, runs the
%% timers and refuses what the core must never see. The core's own decisions
%% are erx_session_relay_core_tests'. The test process plays the console, the
%% master (a process of this node, whose messages are plain) and the shell;
%% a group is a process the test starts.
-module(erx_session_relay_tests).
-include_lib("eunit/include/eunit.hrl").

-define(RELAY, erx_session_relay).
-define(NAME, erx_tty_owner).
-define(WAIT_MS, 1000).

%%% Helpers

%% The relay of the domain's line for Console and Master, not linked to the
%% test, so a crash shows as a dead relay, and a start that fails as a failed
%% match, rather than a dead test.
start(Console, Master) ->
    started(fun() -> ?RELAY:start_link(Console, Master, #{domain_line => true}) end).

%% A relay whose master is in domain D, which stock's emulator cannot name:
%% the server is started with the origin start_link/2 would have found, with
%% the test as the console and as the master unless Master is given.
start_in_domain(D) -> start_in_domain(D, self()).

start_in_domain(D, Master) ->
    started(fun() ->
                    gen_server:start_link({local, ?NAME}, ?RELAY, {self(), {domain, Master, D}, #{}}, [])
            end).

%% While the test traps exits, the end of any process linked to it is a
%% message, and eunit links each case's group leader to the test process and
%% lets it end after the case: a leader whose end the test handles inside the
%% next case's start would be taken for one of the relay's messages. Such
%% normal ends are dropped; a failed start's own 'EXIT' proc_lib has already
%% taken, and its {error, Reason} fails the match below.
started(Start) ->
    Trapping = process_flag(trap_exit, true),
    Started = Start(),
    process_flag(trap_exit, Trapping),
    flush_exits(),
    {ok, Relay} = Started,
    unlink(Relay),
    Relay.

%% Nothing waits in the test's mailbox once a request made after the
%% messages sent has been answered: the relay acts on each in turn.
nothing_after(Barrier) ->
    _ = Barrier(),
    receive Message -> error({unexpected, Message}) after 0 -> ok end.

with_relay(Fun) -> with_relay(self(), Fun).

with_relay(Master, Fun) ->
    Relay = start(self(), Master),
    try
        announced(Master, Relay),
        Fun(Relay)
    after
        stop(Relay)
    end.

%% The tty names itself to a master in the test process first.
announced(Master, Relay) when Master =:= self() -> {tty_open, Relay} = next();
announced(_Master, _Relay) -> ok.

stop(Relay) ->
    Ref = monitor(process, Relay),
    exit(Relay, kill),
    receive {'DOWN', Ref, process, Relay, _} -> ok end,
    flush().

flush() ->
    receive _ -> flush() after 0 -> ok end.

flush_exits() ->
    receive {'EXIT', _, normal} -> flush_exits() after 0 -> ok end.

next() ->
    receive Message -> Message after ?WAIT_MS -> error(nothing_received) end.

%% Bytes typed at the master.
%% The master's input, numbered for each relay from 0.
type(Relay, Bytes) ->
    N = case get({typed, Relay}) of undefined -> 0; Typed -> Typed end,
    put({typed, Relay}, N + 1),
    Relay ! {tty_input, N, Bytes}.

%% A process that stands for a shell's group until it is killed.
group() -> spawn(fun() -> receive stop -> ok end end).

with(Word, Set, Clear, Chars, Termios) ->
    Flags = lists:usort((maps:get(Word, Termios) -- Clear) ++ Set),
    (Termios#{Word := Flags})#{cc := maps:merge(maps:get(cc, Termios), Chars)}.

%% Polls Fun until it returns true: a 'DOWN' from another process may reach
%% the relay after the test's next request.
eventually(Fun) -> eventually(Fun, ?WAIT_MS div 10).

eventually(Fun, 0) -> ?assert(Fun());
eventually(Fun, Tries) ->
    case Fun() of
        true -> ok;
        false -> timer:sleep(10), eventually(Fun, Tries - 1)
    end.

%%% Cases

%% Order: a watch of `in` made while a byte waits gets its answer as the
%% first message and the report as the second.
order_test() ->
    with_relay(fun(Relay) ->
        {ok, Open} = ?RELAY:open_reader(Relay, console),
        type(Relay, <<"x">>),
        Request = gen_server:send_request(Relay, {watch, Open, [in]}),
        First = next(),
        Second = next(),
        ?assertEqual({reply, ok}, gen_server:check_response(First, Request)),
        ?assertMatch({ready, Open, [in], 0}, Second)
    end).

%% The name: the relay of the domain's line holds erx_tty_owner, and the relay
%% of another tty of the session none, nor takes it at a drain. An open names
%% the relay that made it, so the client functions reach that relay with it,
%% and the other relay knows no such open.
the_name_test() ->
    with_relay(fun(Line) ->
        Other = started(fun() -> ?RELAY:start_link(self(), undefined, #{}) end),
        try
            ?assertEqual(Line, whereis(?NAME)),
            {ok, Open} = ?RELAY:open_writer(Other, job_a),
            ?assertMatch({ok, {_, _}}, ?RELAY:tty(Open, winsize)),
            ?assertEqual({error, ebadf}, gen_server:call(Line, {tty, Open, winsize})),
            Drain = make_ref(),
            Other ! {tty_drain, self(), Drain},
            receive {Drain, ok} -> ok after ?WAIT_MS -> error(drain_unanswered) end,
            ?assertEqual(Line, whereis(?NAME))
        after
            stop(Other)
        end
    end).

%% The writers: the console's write and a tty_write are each answered once
%% their bytes are in; a drain only once the master has taken them all, and
%% the name goes with it.
a_drain_gives_the_name_up_test() ->
    with_relay(fun(Relay) ->
        Relay ! {erx_console_output, console_write, <<"c">>},
        receive {erx_console_written, console_write} -> ok after ?WAIT_MS -> error(unanswered) end,
        receive {tty_output, 0, <<"c">>} -> ok after ?WAIT_MS -> error(no_output) end,
        Relay ! {tty_taken, 0},
        Write = make_ref(),
        Relay ! {tty_write, self(), Write, <<"hi">>},
        receive {Write, ok} -> ok after ?WAIT_MS -> error(unanswered) end,
        receive {tty_output, 1, <<"hi">>} -> ok after ?WAIT_MS -> error(no_output) end,
        Drain = make_ref(),
        Relay ! {tty_drain, self(), Drain},
        nothing_after(fun() -> ?RELAY:open_writer(Relay, job_a) end),
        ?assertEqual(Relay, whereis(?NAME)),
        Relay ! {tty_taken, 1},
        receive {Drain, ok} -> ok after ?WAIT_MS -> error(drain_unanswered) end,
        ?assertEqual(undefined, whereis(?NAME))
    end).

%% A shell that ends while its job holds: the console takes the terminal in
%% the editing setting, and its parked watch reports a typed key.
a_shell_that_ends_while_its_job_holds_test() ->
    with_relay(fun(Relay) ->
        {ok, Console} = ?RELAY:open_reader(Relay, console),
        Group = group(),
        ?assertMatch({ok, _, 0}, ?RELAY:foreground(Relay, job_a, cooked, {Group, 0})),
        ok = ?RELAY:watch(Console, {read, 1}),
        exit(Group, kill),
        eventually(fun() ->
                           {ok, #{lflag := Lflag}} = ?RELAY:tty(Console, tcgetattr),
                           not lists:member(icanon, Lflag)
                   end),
        type(Relay, <<"k">>),
        ?assertMatch({ready, Console, [{read, 1}], 0}, next())
    end).

%% A read's timer: with VMIN 0 and VTIME 1 a wait is reported when the timer
%% the relay started ends, and the read then takes nothing.
a_timed_read_test() ->
    with_relay(fun(Relay) ->
        Group = group(),
        {ok, _, 0} = ?RELAY:foreground(Relay, job_a, cooked, {Group, 0}),
        {ok, Open} = ?RELAY:open_reader(Relay, job_a),
        {ok, Termios} = ?RELAY:tty(Open, tcgetattr),
        Timed = with(lflag, [], [icanon], #{vmin => 0, vtime => 1}, Termios),
        ok = ?RELAY:tty(Open, {tcsetattr, Timed}),
        ok = ?RELAY:watch(Open, {read, 4096}),
        {ready, Open, [{read, 4096}], N} = next(),
        ?assertEqual({ok, <<>>}, ?RELAY:read(Open, 4096, N)),
        exit(Group, kill)
    end).

%% The master's end is the tty's hangup: the console is told, an armed wait is ready, and a read
%% that finds no bytes reads the end of file.
the_masters_end_hangs_up_test() ->
    Master = group(),
    with_relay(Master, fun(Relay) ->
        {ok, Open} = ?RELAY:open_reader(Relay, console),
        ok = ?RELAY:watch(Open, {read, 1}),
        exit(Master, kill),
        %% The console hears of the hangup first, before the wait it readies.
        erx_console_eof = next(),
        {ready, Open, [{read, 1}], N} = next(),
        ?assertEqual(eof, ?RELAY:read(Open, 1, N))
    end).

%% The relay is its console's line and ends with it.
the_relay_ends_with_its_console_test() ->
    Console = group(),
    Relay = start(Console, undefined),
    Ref = monitor(process, Relay),
    exit(Console, kill),
    receive
        {'DOWN', Ref, process, Relay, _Reason} -> ok
    after ?WAIT_MS ->
        stop(Relay),
        error(relay_outlived_its_console)
    end.

%% What the core must never see is dropped or refused, and the relay lives
%% on: writers' messages of the wrong shape, a 'DOWN' with a reference the
%% relay did not make for the test process, which is the console, the master
%% and an open's maker, a message enveloped while the master is in this
%% domain, a group that is no pid, and an open named by its caller.
malformed_messages_are_refused_test() ->
    with_relay(fun(Relay) ->
        {ok, Open} = ?RELAY:open_reader(Relay, console),
        Relay ! {tty_write, not_a_pid, make_ref(), <<"a">>},
        Relay ! {tty_write, self(), make_ref(), [<<"a">> | not_a_tail]},
        Relay ! {tty_drain, self(), not_a_ref},
        Relay ! {erx_console_output, from, {not_iodata}},
        Relay ! {'DOWN', make_ref(), process, self(), forged},
        Relay ! {erx_origin, 7, {tty_input, 0, <<"z">>}},
        %% A loss from another domain than the master's is not taken.
        Relay ! {erx_origin, 7, {tty_lost, 0}},
        ?assertEqual({error, einval}, ?RELAY:console_group(Relay, not_a_pid)),
        ?assertEqual({error, einval}, ?RELAY:foreground(Relay, job_a, cooked, {not_a_pid, 0})),
        ?assertEqual({error, einval}, ?RELAY:foreground(Relay, console, {not_a_pid, 0})),
        ?assertEqual({error, einval}, gen_server:call(Relay, {open, console, read, Open})),
        ?assertMatch({ok, _}, ?RELAY:tty(Open, tcgetattr)),
        nothing_after(fun() -> ok = ?RELAY:watch(Open, in) end),
        ?assert(is_process_alive(Relay))
    end).

%% A timer's message is taken only with the reference the relay holds: a
%% forged end of a read's timer ends no wait, and a forged resend of the
%% outstanding output sends the master nothing.
forged_timers_are_ignored_test() ->
    with_relay(fun(Relay) ->
        Group = group(),
        {ok, _, 0} = ?RELAY:foreground(Relay, job_a, cooked, {Group, 0}),
        {ok, Open} = ?RELAY:open_reader(Relay, job_a),
        {ok, Termios} = ?RELAY:tty(Open, tcgetattr),
        Slow = with(lflag, [], [icanon], #{vmin => 0, vtime => 255}, Termios),
        ok = ?RELAY:tty(Open, {tcsetattr, Slow}),
        ok = ?RELAY:watch(Open, {read, 1}),
        {ok, 1} = ?RELAY:write(Open, <<"x">>),
        {tty_output, 0, <<"x">>} = next(),
        [Relay ! {timeout, make_ref(), {timer, {{Open, read}, Serial}}} || Serial <- lists:seq(0, 3)],
        Relay ! {timeout, make_ref(), {resend, 0}},
        nothing_after(fun() -> ?RELAY:tty(Open, winsize) end),
        exit(Group, kill)
    end).

%% A master in another domain: only what arrives enveloped from its domain
%% is the master's; a plain message and one from another domain are not.
a_master_in_another_domain_test() ->
    Relay = start_in_domain(7),
    try
        {tty_open, Relay} = next(),
        {ok, Open} = ?RELAY:open_reader(Relay, console),
        ok = ?RELAY:watch(Open, in),
        Relay ! {tty_input, 0, <<"p">>},
        Relay ! {erx_origin, 8, {tty_input, 0, <<"q">>}},
        nothing_after(fun() -> ?RELAY:tty(Open, winsize) end),
        Relay ! {erx_origin, 7, {tty_input, 0, <<"r">>}},
        ?assertMatch({ready, Open, [in], 0}, next())
    after
        stop(Relay)
    end.

%% The end of a master in another domain is the tty's hangup too, though it says no
%% tty_hangup: a crash of its connection, where a 'DOWN' that names the master with a
%% reference the relay never made changes nothing, and the end of its domain, which here
%% is a node never reached, whose monitor fires with noconnection.
a_master_in_another_domain_that_ends_hangs_up_test() ->
    Master = group(),
    Relay = start_in_domain(7, Master),
    try
        Relay ! {'DOWN', make_ref(), process, Master, killed},
        nothing_after(fun() -> sys:get_state(Relay) end),
        exit(Master, kill),
        ?assertEqual(erx_console_eof, next())
    after
        stop(Relay)
    end,
    Gone = start_in_domain(8, binary_to_term(<<131, 88, 119, 9, "erx@other", 1:32, 0:32, 1:32>>)),
    try
        ?assertEqual(erx_console_eof, next())
    after
        stop(Gone)
    end.
