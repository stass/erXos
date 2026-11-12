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
      fun start_of_a_row_not_enabled_starts_one_session/1]}.

%% ---------------------------------------------------------------------------
%% The stub domain service

%% The stub, and the tree under a holder, its parent, whose end with shutdown
%% stops it. EUnit runs each case in a process of its own, which takes the
%% stub's reports, those of the starts before it included, with watch/0.
setup() ->
    Setup = self(),
    Stub = spawn(fun() -> register(erx_domain_srv, self()), stub(#{refuse => [], next => 1, test => none, kept => []}) end),
    ok = wait_until(fun() -> whereis(erx_domain_srv) =:= Stub end),
    Holder = spawn(fun() ->
                           {ok, Sup} = erx_starter_sup:start_link(manifest()),
                           Setup ! {sup, Sup},
                           receive stop -> exit(shutdown) end
                   end),
    Sup = receive {sup, Pid} -> Pid after ?WAIT_MS -> error(no_sup) end,
    #{stub => Stub, holder => Holder, sup => Sup}.

cleanup(#{stub := Stub, holder := Holder, sup := Sup}) ->
    Ref = monitor(process, Sup),
    Holder ! stop,
    receive {'DOWN', Ref, _, _, _} -> ok after ?WAIT_MS -> error(sup_stuck) end,
    StubRef = monitor(process, Stub),
    exit(Stub, kill),
    receive {'DOWN', StubRef, _, _, _} -> ok end,
    flush().

%% The calling process takes the stub's reports from here on, and those it kept.
watch() ->
    erx_domain_srv ! {watch, self()},
    ok.

%% The stub answers start_session with a session, a process that traps exits as
%% a domain pid does and ends with {domain_down, Id, Info} when it is told to or
%% when a linked process ends with any reason but normal. It reports each start,
%% and each end, to the test.
stub(#{refuse := Refuse, next := Id} = State) ->
    Stub = self(),
    receive
        {'$gen_call', From, {start_session, Principal, Start}} ->
            case lists:member(Principal, Refuse) of
                true ->
                    gen:reply(From, {error, quota}),
                    stub(State);
                false ->
                    Session = spawn(fun() -> process_flag(trap_exit, true), session(Stub, Id, Principal) end),
                    gen:reply(From, {ok, {erx_domain, Id, node(), Session}}),
                    stub(report({started, Principal, Start, Session}, State#{next := Id + 1}))
            end;
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
            [{_, RowSup}] = [{Name, Pid} || {Name, Pid} <- erx_starter_sup:held(), Name =:= <<"kiosk">>],
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

%% ---------------------------------------------------------------------------
%% Helpers

%% The next session the stub starts for Principal.
started(Principal) ->
    case started_within(Principal, ?WAIT_MS) of
        none -> error({no_session, Principal});
        Session -> Session
    end.

started_within(Principal, Ms) ->
    receive {started, Principal, #{}, Session} -> Session after Ms -> none end.

run(Name) ->
    #{rows := Rows} = erx_starter:rows(),
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
