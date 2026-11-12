%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The start service's processes (docs/design-apps.md, "Keeping a session" and
%% "Verification and testing"): the table, the rows' supervisors and the keepers,
%% over a stub domain service registered as erx_domain_srv, whose sessions are
%% plain processes standing for domain pids. test/host/erx_starter_test.rb runs
%% them on stock's emulator, and against each seeded fault it plants, where the
%% case it names must fail.

-module(erx_starter_tests).
-include_lib("eunit/include/eunit.hrl").

-define(WAIT_MS, 5000).

%% kiosk and logger are enabled, clock is not; principal numbers are their
%% manifest index plus one. kiosk allows two restarts a minute.
manifest() ->
    #{rows => [#{principal => <<"clock">>, enable => false, display => none, restarts => 5, period => 600},
               #{principal => <<"kiosk">>, enable => true, display => none, restarts => 2, period => 60},
               #{principal => <<"logger">>, enable => true, display => none, restarts => 5, period => 600}],
      grants => #{},
      principals => #{<<"clock">> => 1, <<"kiosk">> => 2, <<"logger">> => 3}}.

-define(CLOCK, 1).
-define(KIOSK, 2).
-define(LOGGER, 3).

starter_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun an_ended_session_is_started_again/1,
      fun one_end_past_the_intensity_leaves_the_row_down_and_others_up/1,
      fun a_refused_start_counts_as_an_end/1,
      fun a_crash_of_the_table_ends_no_session/1,
      fun a_killed_keeper_ends_its_session/1,
      fun stop_ends_the_session_and_start_starts_it_again/1,
      fun start_of_a_row_not_enabled_starts_one_session/1,
      fun a_restart_restarts_a_row_whose_settings_changed/1,
      fun a_restart_while_rc_conf_is_unreadable_stops_no_row/1,
      fun a_stopped_row_stays_stopped_across_a_restart/1,
      fun enable_writes_rc_conf_and_starts_the_row/1,
      fun a_failed_write_answers_its_error_and_changes_nothing/1,
      fun a_keeper_stopped_while_its_start_is_pending_ends_the_session/1]}.

%% A first read of rc.conf that fails: the file is a directory until the case
%% replaces it.
unreadable_test_() ->
    {foreach, fun() -> setup(fun(Dir) -> ok = file:make_dir(filename:join(Dir, "rc.conf")) end) end,
     fun cleanup/1, [fun a_failed_read_starts_the_manifest_rows_and_reads_again/1]}.

%% ---------------------------------------------------------------------------
%% The stub domain service

%% The stub, and the tree under a holder, its parent, whose end with shutdown
%% stops it. EUnit runs each case in a process of its own, which takes the
%% stub's reports, those of the starts before it included, with watch/0.
setup() ->
    setup(fun(_Dir) -> ok end).

%% Prepare readies the case's own rc.conf directory before the tree starts.
setup(Prepare) ->
    Dir = filename:absname("rc-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Dir),
    ok = Prepare(Dir),
    Setup = self(),
    Stub = spawn(fun() -> register(erx_domain_srv, self()), stub(#{refuse => [], hold => [], held => [], next => 1, test => none, kept => []}) end),
    ok = wait_until(fun() -> whereis(erx_domain_srv) =:= Stub end),
    Holder = spawn(fun() ->
                           {ok, Sup} = erx_starter_sup:start_link(manifest(), list_to_binary(Dir)),
                           Setup ! {sup, Sup},
                           receive stop -> exit(shutdown) end
                   end),
    Sup = receive {sup, Pid} -> Pid after ?WAIT_MS -> error(no_sup) end,
    #{stub => Stub, holder => Holder, sup => Sup, dir => Dir}.

cleanup(#{stub := Stub, holder := Holder, sup := Sup, dir := Dir}) ->
    Ref = monitor(process, Sup),
    Holder ! stop,
    receive {'DOWN', Ref, _, _, _} -> ok after ?WAIT_MS -> error(sup_stuck) end,
    StubRef = monitor(process, Stub),
    exit(Stub, kill),
    receive {'DOWN', StubRef, _, _, _} -> ok end,
    ok = file:del_dir_r(Dir),
    flush().

%% The calling process takes the stub's reports from here on, and those it kept.
watch() ->
    erx_domain_srv ! {watch, self()},
    ok.

%% The stub answers start_session with a session, a process that traps exits as
%% a domain pid does and ends with {domain_down, Id, Info} when it is told to or
%% when a linked process ends with any reason but normal. It reports each start,
%% and each end, to the test.
stub(#{refuse := Refuse, hold := Hold, held := Held, next := Id} = State) ->
    Stub = self(),
    receive
        {'$gen_call', From, {start_session, Principal, Start}} ->
            case lists:member(Principal, Refuse) of
                true ->
                    gen:reply(From, {error, quota}),
                    stub(State);
                false ->
                    Session = spawn(fun() -> process_flag(trap_exit, true), session(Stub, Id, Principal) end),
                    Reply = {ok, {erx_domain, Id, node(), Session}},
                    Answered = case lists:member(Principal, Hold) of
                                   true -> State#{held := [{From, Reply} | Held]};
                                   false -> gen:reply(From, Reply), State
                               end,
                    stub(report({started, Principal, Start, Session}, Answered#{next := Id + 1}))
            end;
        {hold, Principals} ->
            stub(State#{hold := Principals});
        release ->
            lists:foreach(fun({From, Reply}) -> gen:reply(From, Reply) end, Held),
            stub(State#{hold := [], held := []});
        {refuse, Principals} ->
            stub(State#{refuse := Principals});
        {watch, Test} ->
            lists:foreach(fun(Report) -> Test ! Report end, lists:reverse(maps:get(kept, State))),
            stub(State#{test := Test, kept := []});
        {report, Report} ->
            stub(report(Report, State))
    end.

report(Report, #{test := none, kept := Kept} = State) -> State#{kept := [Report | Kept]};
report(Report, #{test := Test} = State) -> Test ! Report, State.

session(Test, Id, Principal) ->
    receive
        {'EXIT', _From, normal} ->
            session(Test, Id, Principal);
        {'EXIT', _From, Reason} ->
            Test ! {report, {ended, Principal, self(), Reason}},
            exit({domain_down, Id, stopped});
        {end_session, Info} ->
            Test ! {report, {ended, Principal, self(), Info}},
            exit({domain_down, Id, Info})
    end.

%% ---------------------------------------------------------------------------
%% The cases

an_ended_session_is_started_again(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            _Logger = started(?LOGGER),
            Kiosk ! {end_session, crashed},
            Again = started(?KIOSK),
            ?assertNotEqual(Kiosk, Again),
            ?assert(is_process_alive(Again))
    end.

one_end_past_the_intensity_leaves_the_row_down_and_others_up(_) ->
    fun() ->
            ok = watch(),
            First = started(?KIOSK),
            Logger = started(?LOGGER),
            %% Two restarts a minute: the third end is one past the intensity.
            Last = lists:foldl(fun(_, Session) -> Session ! {end_session, crashed}, started(?KIOSK) end,
                               First, [1, 2]),
            Last ! {end_session, crashed},
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= down end),
            ?assertEqual(none, started_within(?KIOSK, 200)),
            ?assertEqual(running, run(<<"logger">>)),
            ?assert(is_process_alive(Logger))
    end.

a_refused_start_counts_as_an_end(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            erx_domain_srv ! {refuse, [?KIOSK]},
            Kiosk ! {end_session, crashed},
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= down end),
            ?assertEqual(running, run(<<"logger">>))
    end.

a_crash_of_the_table_ends_no_session(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            Logger = started(?LOGGER),
            Table = whereis(erx_starter),
            exit(Table, kill),
            ok = wait_until(fun() -> is_pid(whereis(erx_starter)) andalso whereis(erx_starter) =/= Table end),
            ?assertEqual(running, run(<<"kiosk">>)),
            ?assertEqual(none, started_within(?KIOSK, 200)),
            ?assert(is_process_alive(Kiosk)),
            ?assert(is_process_alive(Logger))
    end.

a_killed_keeper_ends_its_session(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            [RowSup] = [Pid || {Name, Pid, _Row} <- erx_starter_sup:held(), Name =:= <<"kiosk">>],
            [Keeper] = [Pid || {keeper, Pid, _, _} <- supervisor:which_children(RowSup)],
            exit(Keeper, kill),
            receive {ended, ?KIOSK, Kiosk, killed} -> ok after ?WAIT_MS -> error(session_outlived_keeper) end,
            ?assertNotEqual(Kiosk, started(?KIOSK))
    end.

stop_ends_the_session_and_start_starts_it_again(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= running end),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            ?assertEqual(stopped, run(<<"kiosk">>)),
            ?assertEqual(ok, erx_starter:command({start, <<"kiosk">>, #{}})),
            ?assertNotEqual(Kiosk, started(?KIOSK)),
            ?assertEqual({error, {undeclared, <<"nobody">>}}, erx_starter:command({stop, <<"nobody">>, #{}}))
    end.

start_of_a_row_not_enabled_starts_one_session(_) ->
    fun() ->
            ok = watch(),
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= running end),
            ?assertEqual(ok, erx_starter:command({start, <<"clock">>, #{}})),
            Clock = started(?CLOCK),
            Clock ! {end_session, crashed},
            ?assertEqual(none, started_within(?CLOCK, 200)),
            ?assertEqual(none, run(<<"clock">>))
    end.

a_restart_restarts_a_row_whose_settings_changed(Setup) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            Logger = started(?LOGGER),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            %% Edited while the table is down: kiosk is kept with three restarts now.
            ok = file:write_file(rc_path(Setup), <<"kiosk_restarts=\"3\"\n">>),
            ok = restart_table(),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(changed_row_kept) end,
            ?assertNotEqual(Kiosk, started(?KIOSK)),
            ?assertEqual(none, started_within(?LOGGER, 200)),
            ?assert(is_process_alive(Logger))
    end.

a_restart_while_rc_conf_is_unreadable_stops_no_row(Setup) ->
    fun() ->
            ok = watch(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({enable, <<"clock">>, #{}})),
            Clock = started(?CLOCK),
            %% rc.conf, which alone enables clock, cannot be read by the next table.
            ok = file:delete(rc_path(Setup)),
            ok = file:make_dir(rc_path(Setup)),
            ok = restart_table(),
            ?assertEqual(unread, rc_conf()),
            receive {ended, ?CLOCK, Clock, _} -> error(rc_conf_row_stopped) after 300 -> ok end,
            ?assertEqual(running, run(<<"clock">>)),
            ?assertEqual({error, rc_conf_unread}, erx_starter:command({disable, <<"clock">>, #{}}))
    end.

a_stopped_row_stays_stopped_across_a_restart(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= running end),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            ok = restart_table(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(none, started_within(?KIOSK, 300)),
            ?assertEqual(stopped, run(<<"kiosk">>))
    end.

enable_writes_rc_conf_and_starts_the_row(Setup) ->
    fun() ->
            ok = watch(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({enable, <<"clock">>, #{restarts => 3}})),
            ?assertEqual({ok, <<"clock_enable=\"YES\"\nclock_restarts=\"3\"\n">>}, file:read_file(rc_path(Setup))),
            _ = started(?CLOCK),
            ?assertEqual(running, run(<<"clock">>)),
            ?assertEqual({error, enoent}, file:read_file_info(<<(rc_path(Setup))/binary, ".new">>))
    end.

a_failed_write_answers_its_error_and_changes_nothing(Setup) ->
    fun() ->
            ok = watch(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            %% The temporary file cannot be made.
            ok = file:make_dir(<<(rc_path(Setup))/binary, ".new">>),
            ?assertMatch({error, _}, erx_starter:command({enable, <<"clock">>, #{}})),
            ?assertEqual(none, run(<<"clock">>)),
            ?assertEqual({error, enoent}, file:read_file(rc_path(Setup))),
            ?assertEqual(none, started_within(?CLOCK, 200))
    end.

a_keeper_stopped_while_its_start_is_pending_ends_the_session(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            erx_domain_srv ! {hold, [?KIOSK]},
            Kiosk ! {end_session, crashed},
            %% The stub has made the session and holds its answer.
            Pending = started(?KIOSK),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            erx_domain_srv ! release,
            receive {ended, ?KIOSK, Pending, abandoned} -> ok after ?WAIT_MS -> error(abandoned_session_kept) end
    end.

a_failed_read_starts_the_manifest_rows_and_reads_again(Setup) ->
    fun() ->
            ok = watch(),
            _ = started(?KIOSK),
            Logger = started(?LOGGER),
            ?assertEqual(unread, rc_conf()),
            ?assertEqual({error, rc_conf_unread}, erx_starter:command({disable, <<"logger">>, #{}})),
            ok = file:del_dir(rc_path(Setup)),
            ok = file:write_file(rc_path(Setup), <<"logger_enable=\"NO\"\n">>),
            receive {ended, ?LOGGER, Logger, _} -> ok after ?WAIT_MS -> error(rc_conf_not_read_again) end,
            ?assertEqual(read, rc_conf()),
            ?assertEqual(none, run(<<"logger">>))
    end.

%% ---------------------------------------------------------------------------
%% Helpers

%% The case's rc.conf.
rc_path(#{dir := Dir}) ->
    iolist_to_binary(filename:join(Dir, "rc.conf")).

rc_conf() ->
    maps:get(rc_conf, erx_starter:rows()).

%% Kills the table and waits for its supervisor to start the next.
restart_table() ->
    Table = whereis(erx_starter),
    exit(Table, kill),
    wait_until(fun() -> is_pid(whereis(erx_starter)) andalso whereis(erx_starter) =/= Table end).

%% The next session the stub starts for Principal.
started(Principal) ->
    case started_within(Principal, ?WAIT_MS) of
        none -> error({no_session, Principal});
        Session -> Session
    end.

started_within(Principal, Ms) ->
    receive {started, Principal, #{}, Session} -> Session after Ms -> none end.

run(Name) ->
    #{rows := Made} = erx_starter:rows(),
    Rows = case Made of unmade -> []; _ -> Made end,
    case [Run || #{principal := Principal, run := Run} <- Rows, Principal =:= Name] of
        [Run] -> Run;
        %% The table has not been made yet.
        [] -> unmade
    end.

wait_until(Done) -> wait_until(Done, ?WAIT_MS div 10).

wait_until(_Done, 0) -> timeout;
wait_until(Done, Left) ->
    case Done() of
        true -> ok;
        false -> receive after 10 -> wait_until(Done, Left - 1) end
    end.

flush() ->
    receive _ -> flush() after 0 -> ok end.
