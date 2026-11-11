%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the driver-control facet, erx_driver_ctl: its mint's decision, and a
%% facet started as the mint starts one, in front of a supervisor of this module's whose
%% children stand for driver processes. As in erx_facet_tests, this module stands in for
%% the export table (erx_dist:export/3 and owner/1), and every name of the test's own node
%% stands for a name of the grantee's, the system domain's, so the test's own calls in the
%% envelope are the system shell's.
-module(erx_driver_ctl_tests).
-include_lib("eunit/include/eunit.hrl").
-export([export/3, owner/1]).
%% The stand-in driver supervisor and its children.
-export([init/1, driver/1]).

-define(SYSTEM, 4).
-define(OTHER, 9).
-define(SUP, erx_driver_ctl_tests_sup).

export(_Pid, _Rights, _Peer) -> ok.

owner(_Name) -> ?SYSTEM.

%% The supervisor: driver, a child that runs, and absent, one whose start is ignored, as
%% erx_blk's is on a machine without a disk.
init([]) ->
    Child = fun(Id, Mode) -> #{id => Id, start => {?MODULE, driver, [Mode]}, restart => transient,
                               shutdown => 1000, type => worker} end,
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60},
          [Child(driver, run), Child(absent, ignore)]}}.

driver(run) -> {ok, spawn_link(fun() -> receive after infinity -> ok end end)};
driver(ignore) -> ignore.

%% A facet granted to the system domain over the units block, the running driver,
%% floppy, the ignored one, and tape, whose supervisor does not run; the supervisor
%% behind it. Ends both after Test.
with_facet(Test) ->
    {ok, Sup} = supervisor:start_link({local, ?SUP}, ?MODULE, []),
    Mint = spawn(fun() -> receive after infinity -> ok end end),
    Units = #{block => {?SUP, driver}, floppy => {?SUP, absent},
              tape => {erx_driver_ctl_tests_gone, drive}},
    Grant = #{grantee => ?SYSTEM, ends_with => [Mint], units => Units},
    {ok, Facet} = erx_facet:start(erx_driver_ctl, Grant, #{exports => ?MODULE}),
    try
        Test(Facet)
    after
        exit(Mint, kill),
        unlink(Sup),
        exit(Sup, shutdown)
    end.

%% A gen_server call of Request to Facet in domain D's envelope, as the connection
%% delivers the system shell's; the reply, or none if none came in Wait ms.
call(Facet, D, Request, Wait) ->
    Alias = alias(),
    Facet ! {erx_origin, D, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after Wait -> none end.

call(Facet, Request) -> call(Facet, ?SYSTEM, Request, 2000).

driver_pid() ->
    {driver, Pid, _, _} = lists:keyfind(driver, 1, supervisor:which_children(?SUP)),
    Pid.

stop_leaves_the_driver_stopped_test() ->
    with_facet(fun(Facet) ->
                       Before = driver_pid(),
                       ?assertEqual(ok, call(Facet, {stop, block})),
                       ?assertNot(is_process_alive(Before)),
                       ?assertEqual(undefined, driver_pid()),
                       ?assertEqual(ok, call(Facet, {stop, block}))
               end).

start_starts_a_stopped_driver_only_test() ->
    with_facet(fun(Facet) ->
                       ?assertEqual({error, running}, call(Facet, {start, block})),
                       ok = call(Facet, {stop, block}),
                       ?assertEqual(ok, call(Facet, {start, block})),
                       ?assert(is_pid(driver_pid()))
               end).

restart_starts_a_new_driver_test() ->
    with_facet(fun(Facet) ->
                       Before = driver_pid(),
                       ?assertEqual(ok, call(Facet, {restart, block})),
                       After = driver_pid(),
                       ?assert(is_pid(After)),
                       ?assertNotEqual(Before, After),
                       ?assertNot(is_process_alive(Before)),
                       %% A stopped driver is started.
                       ok = call(Facet, {stop, block}),
                       ?assertEqual(ok, call(Facet, {restart, block})),
                       ?assert(is_pid(driver_pid()))
               end).

%% A driver whose start is ignored did not start: failed, never ok.
an_ignored_start_fails_test() ->
    with_facet(fun(Facet) ->
                       ?assertEqual({error, failed}, call(Facet, {restart, floppy})),
                       ?assertEqual({error, failed}, call(Facet, {start, floppy}))
               end).

%% A unit whose supervisor does not run fails, and the facet answers on.
a_supervisor_that_does_not_run_fails_test() ->
    with_facet(fun(Facet) ->
                       ?assertEqual({error, failed}, call(Facet, {restart, tape})),
                       ?assertEqual(ok, call(Facet, {restart, block}))
               end).

%% A unit the holder does not name, a unit name that is no atom, an operation the facet
%% does not offer and a request of another shape are refused, and the driver runs on.
unknown_units_and_requests_are_refused_test() ->
    with_facet(fun(Facet) ->
                       Before = driver_pid(),
                       [?assertEqual({error, badarg}, call(Facet, Request))
                        || Request <- [{restart, net}, {stop, "block"}, {stop, <<"block">>},
                                       {stop, {erx_blk_sup, erx_blk}},
                                       {kill, block}, {restart, block, now}, restart, block]],
                       ?assertEqual(Before, driver_pid())
               end).

%% A call from any domain but the grantee is dropped unanswered, and acts on nothing.
another_domains_call_is_dropped_test() ->
    with_facet(fun(Facet) ->
                       Before = driver_pid(),
                       ?assertEqual(none, call(Facet, ?OTHER, {stop, block}, 300)),
                       ?assertEqual(Before, driver_pid())
               end).

mint_grants_only_the_system_domain_test() ->
    Limits = #{max_request => 512},
    Request = fun(Grantee) -> {erx_facet_mint, 3, storage_ctl, Grantee, Limits} end,
    ?assertEqual({grant, 3, Limits}, erx_driver_ctl:mint_request(?SYSTEM, storage_ctl, {erx_origin, ?SYSTEM, Request(?SYSTEM)})),
    ?assertEqual({refuse, 3}, erx_driver_ctl:mint_request(?SYSTEM, storage_ctl, {erx_origin, ?SYSTEM, Request(?OTHER)})),
    %% Only a request in the system domain's envelope, for this service, is one.
    [?assertEqual(unknown, erx_driver_ctl:mint_request(?SYSTEM, storage_ctl, Message))
     || Message <- [{erx_origin, ?OTHER, Request(?SYSTEM)}, Request(?SYSTEM),
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, network_ctl, ?SYSTEM, Limits}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 0, storage_ctl, ?SYSTEM, Limits}},
                    {erx_origin, ?SYSTEM, {erx_facet_mint, 3, storage_ctl, ?SYSTEM, none}}]].
