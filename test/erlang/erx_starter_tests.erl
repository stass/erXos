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
      principals => #{<<"clock">> => 1, <<"kiosk">> => 2, <<"logger">> => 3},
      boot_order => [<<"storage">>, <<"net">>]}.

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
      fun a_keeper_stopped_while_its_start_is_pending_ends_the_session/1,
      fun a_stopped_row_stays_stopped_when_its_settings_change/1,
      fun a_down_row_stays_down_when_its_settings_change/1,
      fun enable_starts_a_stopped_row_and_clears_its_mark/1,
      fun stop_marks_the_row_before_it_ends_it/1,
      fun start_clears_the_mark_before_it_starts_the_row/1,
      fun enable_clears_the_mark_before_the_table_is_made/1,
      fun the_next_table_completes_a_stop_cut_short/1,
      fun an_unchanged_text_is_not_recorded_again/1,
      fun a_new_text_is_recorded_before_the_old_is_dropped/1,
      fun a_restarted_table_takes_the_newer_of_two_recorded_texts/1,
      fun a_row_neither_held_nor_marked_is_starting/1]}.

%% A first read of rc.conf that fails: the file is a directory until the case
%% replaces it.
unreadable_test_() ->
    {foreach, fun() -> setup(fun(Dir) -> ok = file:make_dir(filename:join(Dir, "rc.conf")) end) end,
     fun cleanup/1, [fun a_failed_read_starts_the_manifest_rows_and_reads_again/1]}.

%% The two behaviours of OTP's one_for_one supervisor the keepers' branch
%% stands on (erx_starter_sup): a transient child that ends with shutdown is
%% not restarted and keeps its spec with no pid, and a child whose start
%% returns ignore keeps its spec with no pid.
a_one_for_one_supervisor_keeps_a_spec_with_no_pid_test() ->
    {ok, Sup} = supervisor:start_link(erx_starter_sup, keepers),
    {ok, Child} = supervisor:start_child(Sup, #{id => transient, restart => transient, type => supervisor,
                                                start => {supervisor, start_link, [erx_starter_sup, keepers]}}),
    ok = gen_server:stop(Child, shutdown, ?WAIT_MS),
    ok = wait_until(fun() -> supervisor:which_children(Sup) =:= [{transient, undefined, supervisor, [supervisor]}] end),
    ?assertMatch({ok, #{id := transient}}, supervisor:get_childspec(Sup, transient)),
    ?assertEqual({ok, undefined},
                 supervisor:start_child(Sup, #{id => ignored, restart => transient,
                                               start => {erx_starter_sup, ignore, [value]}})),
    ?assertMatch({ok, #{start := {erx_starter_sup, ignore, [value]}}}, supervisor:get_childspec(Sup, ignored)),
    ?assertEqual(lists:sort([{transient, undefined, supervisor, [supervisor]},
                             {ignored, undefined, worker, [erx_starter_sup]}]),
                 lists:sort(supervisor:which_children(Sup))),
    unlink(Sup),
    ok = gen_server:stop(Sup, shutdown, ?WAIT_MS).

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
            ok = restart_table(),
            ?assertEqual(running, run(<<"kiosk">>)),
            ?assertEqual(none, started_within(?KIOSK, 200)),
            ?assert(is_process_alive(Kiosk)),
            ?assert(is_process_alive(Logger))
    end.

a_killed_keeper_ends_its_session(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            {Rows, []} = erx_starter_sup:held(),
            [RowSup] = [Pid || {Name, Pid, _Row} <- Rows, Name =:= <<"kiosk">>],
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

%% A row whose supervisor ended with no stopped mark, as when a table ends
%% between recording rc.conf's text and starting the row, is `starting`, not
%% `stopped`: only the mark makes a row stopped (/proc/apps tells them apart).
a_row_neither_held_nor_marked_is_starting(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= running end),
            ok = erx_starter_sup:stop(<<"kiosk">>),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            ?assertEqual(starting, run(<<"kiosk">>)),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            ?assertEqual(stopped, run(<<"kiosk">>)),
            ?assertMatch(#{boot_order := [<<"storage">>, <<"net">>]}, erx_starter:rows())
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
            ?assertMatch({error, {failed, _}}, erx_starter:command({enable, <<"clock">>, #{}})),
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

a_stopped_row_stays_stopped_when_its_settings_change(Setup) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            ok = file:write_file(rc_path(Setup), <<"kiosk_restarts=\"3\"\n">>),
            ok = restart_table(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(none, started_within(?KIOSK, 300)),
            ?assertEqual(stopped, run(<<"kiosk">>))
    end.

a_down_row_stays_down_when_its_settings_change(Setup) ->
    fun() ->
            ok = watch(),
            First = started(?KIOSK),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            Last = lists:foldl(fun(_, Session) -> Session ! {end_session, crashed}, started(?KIOSK) end,
                               First, [1, 2]),
            Last ! {end_session, crashed},
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= down end),
            ok = file:write_file(rc_path(Setup), <<"kiosk_restarts=\"3\"\n">>),
            ok = restart_table(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(none, started_within(?KIOSK, 300)),
            ?assertEqual(down, run(<<"kiosk">>))
    end.

enable_starts_a_stopped_row_and_clears_its_mark(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            ?assertEqual(ok, erx_starter:command({enable, <<"kiosk">>, #{}})),
            Again = started(?KIOSK),
            ?assertEqual(running, run(<<"kiosk">>)),
            %% A mark left behind would stop the row at the next table's read.
            ok = restart_table(),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            receive {ended, ?KIOSK, Again, _} -> error(marked_row_stopped) after 300 -> ok end,
            ?assertEqual(running, run(<<"kiosk">>))
    end.

%% A table that ends between the two steps of a stop must find the row
%% stopped, so the mark is written before the row ends.
stop_marks_the_row_before_it_ends_it(_) ->
    fun() ->
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= running end),
            Calls = supervisor_calls(whereis(erx_starter),
                                     fun() -> ok = erx_starter:command({stop, <<"kiosk">>, #{}}) end),
            Mark = {start_child, {stopped, <<"kiosk">>}},
            End = {terminate_child, {row, <<"kiosk">>}},
            ?assertMatch([_, _], [Call || Call <- Calls, Call =:= Mark orelse Call =:= End]),
            ?assertEqual([Mark, End], [Call || Call <- Calls, Call =:= Mark orelse Call =:= End])
    end.

%% A table that ends between the two steps of a start must not find the row
%% marked, so the mark is cleared before the row starts.
start_clears_the_mark_before_it_starts_the_row(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            Calls = supervisor_calls(whereis(erx_starter),
                                     fun() -> ok = erx_starter:command({start, <<"kiosk">>, #{}}) end),
            Clear = {delete_child, {stopped, <<"kiosk">>}},
            Start = {start_child, {row, <<"kiosk">>}},
            ?assertEqual([Clear, Start], [Call || Call <- Calls, Call =:= Clear orelse Call =:= Start])
    end.

%% An enable of a stopped row clears the mark before the table is made from
%% the text it wrote, so a table that ends between the two finds the row
%% enabled and unmarked, and starts it once its own read answers; cleared
%% after, the row would stay enabled and stopped. The enable changes the
%% text, which no rc.conf in the case's directory set, so the table records it.
enable_clears_the_mark_before_the_table_is_made(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({stop, <<"kiosk">>, #{}})),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(session_outlived_stop) end,
            Calls = supervisor_calls(whereis(erx_starter),
                                     fun() -> ok = erx_starter:command({enable, <<"kiosk">>, #{}}) end),
            Clear = {delete_child, {stopped, <<"kiosk">>}},
            ?assertMatch([Clear, {start_child, _} | _],
                         [Call || Call <- Calls, Call =:= Clear orelse is_record_call(Call)])
    end.

%% A stop cut short, its mark written and its row still running, is
%% completed by the next table once its read of rc.conf answers.
the_next_table_completes_a_stop_cut_short(_) ->
    fun() ->
            ok = watch(),
            Kiosk = started(?KIOSK),
            ok = wait_until(fun() -> run(<<"kiosk">>) =:= running end),
            %% The mark erx_starter_sup:stop_row/1 writes first.
            {ok, undefined} = supervisor:start_child(erx_starter_keepers,
                                                     #{id => {stopped, <<"kiosk">>}, restart => transient,
                                                       start => {erx_starter_sup, ignore, [<<"kiosk">>]}}),
            ok = restart_table(),
            receive {ended, ?KIOSK, Kiosk, _} -> ok after ?WAIT_MS -> error(stop_cut_short_left_running) end,
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(stopped, run(<<"kiosk">>)),
            ?assertEqual(none, started_within(?KIOSK, 200))
    end.

%% Recording a text unchanged leaves the record alone.
an_unchanged_text_is_not_recorded_again(_) ->
    fun() ->
            ok = wait_until(fun() -> rc_conf() =:= read end),
            {ok, Text} = erx_starter_sup:recorded(),
            ?assertEqual([], record_calls(Text))
    end.

%% A new text is recorded before the old record is dropped, so a table that
%% ends at any step finds a text recorded.
a_new_text_is_recorded_before_the_old_is_dropped(_) ->
    fun() ->
            ok = wait_until(fun() -> rc_conf() =:= read end),
            {ok, Text} = erx_starter_sup:recorded(),
            Edited = <<Text/binary, "# edited\n">>,
            ?assertMatch([{start_child, _}, {delete_child, _}], record_calls(Edited)),
            ?assertEqual({ok, Edited}, erx_starter_sup:recorded())
    end.

%% A record cut short between its two steps leaves the old text and the new
%% one recorded. The table restarted then is made from the newer while
%% rc.conf is unreadable, and its read, once it answers, leaves one record.
a_restarted_table_takes_the_newer_of_two_recorded_texts(Setup) ->
    fun() ->
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertEqual(ok, erx_starter:command({enable, <<"clock">>, #{}})),
            Newer = <<"clock_enable=\"NO\"\n">>,
            [Generation] = [Id || {{rc_conf, Id}, _, _, _} <- supervisor:which_children(erx_starter_keepers)],
            %% The new record erx_starter_sup:record/1 adds first.
            {ok, undefined} = supervisor:start_child(erx_starter_keepers,
                                                     #{id => {rc_conf, Generation + 1}, restart => transient,
                                                       start => {erx_starter_sup, ignore, [Newer]}}),
            ok = file:delete(rc_path(Setup)),
            ok = file:make_dir(rc_path(Setup)),
            ok = restart_table(),
            ?assertEqual(unread, rc_conf()),
            ?assertEqual(Newer, erx_starter:rc_conf()),
            ?assertEqual(none, run(<<"clock">>)),
            ok = file:del_dir(rc_path(Setup)),
            ok = file:write_file(rc_path(Setup), Newer),
            ok = wait_until(fun() -> rc_conf() =:= read end),
            ?assertMatch([_], [Id || {{rc_conf, _} = Id, _, _, _} <- supervisor:which_children(erx_starter_keepers)]),
            ?assertEqual({ok, Newer}, erx_starter_sup:recorded())
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

%% The calls of supervisor:start_child/2, terminate_child/2 and delete_child/2
%% process Pid makes while Act runs, in order, each as {Function, Id}, Id the
%% child's id.
supervisor_calls(Pid, Act) ->
    Functions = [start_child, terminate_child, delete_child],
    _ = [erlang:trace_pattern({supervisor, Function, 2}, true, []) || Function <- Functions],
    1 = erlang:trace(Pid, true, [call]),
    try Act()
    after
        _ = erlang:trace(Pid, false, [call]),
        _ = [erlang:trace_pattern({supervisor, Function, 2}, false, []) || Function <- Functions]
    end,
    Ref = erlang:trace_delivered(Pid),
    receive {trace_delivered, Pid, Ref} -> ok end,
    traced(Pid).

traced(Pid) ->
    receive
        {trace, Pid, call, {supervisor, Function, [_Sup, #{id := Id}]}} -> [{Function, Id} | traced(Pid)];
        {trace, Pid, call, {supervisor, Function, [_Sup, Id]}} -> [{Function, Id} | traced(Pid)]
    after 0 -> []
    end.

%% A supervisor call on a record of rc.conf's text.
is_record_call({_Function, rc_conf}) -> true;
is_record_call({_Function, {rc_conf, _Generation}}) -> true;
is_record_call(_Call) -> false.

%% The supervisor calls of erx_starter_sup:record(Text), made in a process
%% of its own.
record_calls(Text) ->
    Test = self(),
    Recorder = spawn_link(fun() -> receive record -> Test ! {recorded, erx_starter_sup:record(Text)} end,
                                          receive done -> ok end
                          end),
    Recorded = fun() ->
                       Recorder ! record,
                       receive {recorded, ok} -> ok after ?WAIT_MS -> error(record_stuck) end
               end,
    Calls = supervisor_calls(Recorder, Recorded),
    Recorder ! done,
    Calls.

%% Kills the table and waits for its supervisor to start the next. The kill is
%% a signal, so the old table can still hold the name for a while after
%% exit/2 returns; once its DOWN has arrived the name is free, and the next
%% process to hold it is the new table, which answers calls once its init is
%% done.
restart_table() ->
    Table = whereis(erx_starter),
    Ref = monitor(process, Table),
    exit(Table, kill),
    receive {'DOWN', Ref, process, Table, killed} -> ok after ?WAIT_MS -> error(table_outlived_kill) end,
    wait_until(fun() -> is_pid(whereis(erx_starter)) end).

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
