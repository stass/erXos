%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the driver-control facet, erx_driver_ctl: its mint's decision, and a
%% facet started as the mint starts one, in front of a supervisor of this module's whose
%% children stand for driver processes; and the block driver's supervisor, erx_blk_sup,
%% whose own flags and child specs run behind the facet with stand-in starts, so that a
%% failure of the driver ends it while the facet's stop, start and restart do not. As in
%% erx_facet_tests, this module stands in for
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
%% A supervisor's name whose process ends on the first call it takes.
-define(ENDING, erx_driver_ctl_tests_ending).

export(_Pid, _Rights, _Peer) -> ok.

owner(_Name) -> ?SYSTEM.

%% The supervisor: driver, a child that runs, and absent, one whose start is ignored, as
%% erx_blk's is on a machine without a disk.
init([]) ->
    Child = fun(Id, Mode) -> #{id => Id, start => {?MODULE, driver, [Mode]}, restart => transient,
                               shutdown => 1000, type => worker} end,
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60},
          [Child(driver, run), Child(absent, ignore)]}};
%% erx_blk_sup's own flags and child specs, each start replaced by a stand-in: the device
%% process, registered as erx_blk, and the partition process run, and the image mounts
%% start nothing.
init(blk) ->
    {ok, {Flags, Children}} = erx_blk_sup:init([]),
    Stand = fun(#{id := images} = Child) -> Child#{start => {?MODULE, driver, [ignore]}};
               (Child) -> Child#{start => {?MODULE, driver, [run]}}
            end,
    {ok, {Flags, lists:map(Stand, Children)}}.

driver(run) -> {ok, spawn_link(fun() -> receive after infinity -> ok end end)};
driver(ignore) -> ignore.

%% A facet granted to the system domain over the units block, the running driver,
%% floppy, the ignored one, tape, whose supervisor does not run, and reel, whose
%% supervisor is ?ENDING; the supervisor behind it. Ends both after Test.
with_facet(Test) ->
    Units = #{block => {?SUP, driver}, floppy => {?SUP, absent},
              tape => {erx_driver_ctl_tests_gone, drive}, reel => {?ENDING, drive}},
    with_facet([], Units, fun(Facet, _Sup) -> Test(Facet) end).

%% A facet over the unit block, the device process under erx_blk_sup's own specs
%% (init(blk)), and that supervisor; ends both after Test(Facet, Supervisor).
with_blk(Test) ->
    with_facet(blk, #{block => {?SUP, erx_blk}}, Test).

%% A facet granted to the system domain over Units, in front of the supervisor init(Spec)
%% starts, unlinked, so that its end does not end the test; ends both after Test.
with_facet(Spec, Units, Test) ->
    {ok, Sup} = supervisor:start_link({local, ?SUP}, ?MODULE, Spec),
    unlink(Sup),
    Mint = spawn(fun() -> receive after infinity -> ok end end),
    Grant = #{grantee => ?SYSTEM, ends_with => [Mint], units => Units},
    {ok, Facet} = erx_facet:start(erx_driver_ctl, Grant, #{exports => ?MODULE}),
    try
        Test(Facet, Sup)
    after
        exit(Mint, kill),
        ?assert(ended(Sup, fun() -> exit(Sup, shutdown) end))
    end.

%% Whether Sup has ended within 2 s of Act.
ended(Sup, Act) ->
    Ref = monitor(process, Sup),
    Act(),
    receive {'DOWN', Ref, process, Sup, _} -> true after 2000 -> demonitor(Ref, [flush]), false end.

%% A gen_server call of Request to Facet in domain D's envelope, as the connection
%% delivers the system shell's; the reply, or none if none came in Wait ms.
call(Facet, D, Request, Wait) ->
    Alias = alias(),
    Facet ! {erx_origin, D, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after Wait -> none end.

call(Facet, Request) -> call(Facet, ?SYSTEM, Request, 2000).

driver_pid() -> child_pid(driver).

child_pid(Id) ->
    {Id, Pid, _, _} = lists:keyfind(Id, 1, supervisor:which_children(?SUP)),
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

%% A unit whose supervisor ends while it takes the call fails, and the facet answers on.
a_supervisor_that_ends_in_the_call_fails_test() ->
    with_facet(fun(Facet) ->
                       register(?ENDING, spawn(fun() -> receive _ -> exit(shutdown) end end)),
                       ?assertEqual({error, failed}, call(Facet, {stop, reel})),
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

%% A block driver that fails, by a crash or by the shutdown with which erx_blk_virtio ends on a
%% broken queue, is not restarted in place: erx_blk_sup ends, and with it
%% the storage domain, whose restart gives the device again (docs/design-stopgap.md,
%% "littlefs in the storage domain"). So does a partition process that fails.
a_block_driver_failure_ends_its_supervisor_test_() ->
    Ends = [{erx_blk, kill}, {erx_blk, {shutdown, broken_queue}}, {erx_blk, crashed},
            {erx_blk_service, kill}],
    [{lists:flatten(io_lib:format("~p ~p", [Child, Reason])), fun() -> fails(Child, Reason) end}
     || {Child, Reason} <- Ends].

%% Whether erx_blk_sup's child Child, ended with Reason, ends the supervisor.
fails(Child, Reason) ->
    with_blk(fun(_Facet, Sup) ->
                     ?assert(ended(Sup, fun() -> exit(child_pid(Child), Reason) end))
             end).

%% The facet's stop, start and restart are no failure: erx_blk_sup runs on through them,
%% and a failure of the driver they started still ends it.
the_control_path_does_not_end_the_block_supervisor_test() ->
    with_blk(fun(Facet, Sup) ->
                     ?assertEqual(ok, call(Facet, {restart, block})),
                     ?assertEqual(ok, call(Facet, {stop, block})),
                     ?assertEqual(ok, call(Facet, {start, block})),
                     ?assertEqual(ok, call(Facet, {restart, block})),
                     ?assert(is_process_alive(Sup)),
                     ?assert(ended(Sup, fun() -> exit(child_pid(erx_blk), kill) end))
             end).
