%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_tests).
-moduledoc """
EUnit and property tests of an `erx_fs` grant's fids and owners
(docs/design-files.md#verification-and-testing): fids refused while in use,
".." held at the root, walks that stop at a link, owners outside the domain,
fid floods against the pool, short-lived and ended owners and their monitors,
the in-flight bound, the read-only refusals of F5, pipelined requests, and an
exhaustive model of the fid table. The grants serve erx_fs_test_tree.
test/host/erx_fs_test.rb runs these on stock OTP and seeds a fault for each.
""".

-include_lib("eunit/include/eunit.hrl").

-define(NOFID, 16#ffffffff).
-define(TREE, <<"test">>).
-define(ROOT_QID, {16#80, 0, 1}).
-define(A_QID, {16#80, 0, 2}).
-define(LINK_QID, {16#02, 0, 5}).
-define(O_WRONLY, 1).
-define(O_TRUNC, 8#1000).
-define(WRLCK, 1).

%% Fixtures --------------------------------------------------------------

grant(Rights) ->
    grant(Rights, #{}).

grant(Rights, Options) ->
    {ok, Grant} = erx_fs:start_link(erx_fs_test_tree, [{observer, self()}], Rights, Options),
    unlink(Grant),
    Grant.

%% A grant whose tree reports no callbacks, for tests that make many requests.
quiet_grant() ->
    {ok, Grant} = erx_fs:start_link(erx_fs_test_tree, [], rw),
    unlink(Grant),
    Grant.

stop(Grant) ->
    exit(Grant, kill).

%% One request and its reply, as erx_file_remote sends it: to a fresh alias.
call(Grant, Request) ->
    call(Grant, self(), Request).

call(Grant, Owner, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, Owner, Request},
    receive
        {erx_9p, Alias, Reply} -> Reply
    after 2000 ->
        erlang:error({no_reply, Request})
    end.

attach(Grant, Fid) ->
    attach(Grant, self(), Fid).

attach(Grant, Owner, Fid) ->
    call(Grant, Owner, {attach, Fid, ?NOFID, <<"user">>, ?TREE, 0}).

walk(Grant, Fid, NewFid, Names) ->
    call(Grant, {walk, Fid, NewFid, Names}).

%% Whether Fid names a node: getattr answers its qid, or ebadf for no fid.
qid_of(Grant, Fid) ->
    case call(Grant, {getattr, Fid, 16#7ff}) of
        {ok, #{qid := Qid}} -> Qid;
        {error, Posix} -> Posix
    end.

monitors(Grant) ->
    {monitors, Monitors} = process_info(Grant, monitors),
    length(Monitors).

wait_for_monitors(Grant, Count) ->
    wait_for_monitors(Grant, Count, 500).

wait_for_monitors(Grant, Count, 0) ->
    ?assertEqual(Count, monitors(Grant));
wait_for_monitors(Grant, Count, Tries) ->
    case monitors(Grant) of
        Count -> ok;
        _ -> timer:sleep(10), wait_for_monitors(Grant, Count, Tries - 1)
    end.

tree_calls() ->
    receive
        {tree_call, Callback} -> [Callback | tree_calls()]
    after 0 ->
        []
    end.

ended_process() ->
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Pid, _} -> Pid end.

%% A pid of a process on another node, which no request may name as an owner.
foreign_pid() ->
    Node = <<"other@host">>,
    binary_to_term(<<131, 88, 119, (byte_size(Node)), Node/binary, 1:32, 0:32, 1:32>>).

%% Version and attach ----------------------------------------------------

version_test() ->
    Grant = grant(rw),
    ?assertEqual({ok, 8192, <<"9P2000.L">>}, call(Grant, {version, 8192, <<"9P2000.L">>})),
    ?assertEqual({ok, 65560, <<"9P2000.L">>}, call(Grant, {version, 1 bsl 20, <<"9P2000.L">>})),
    ?assertEqual({ok, 8192, <<"unknown">>}, call(Grant, {version, 8192, <<"9P2000">>})),
    ?assertEqual({error, einval}, call(Grant, {version, 4095, <<"9P2000.L">>})),
    stop(Grant).

attach_test() ->
    Grant = grant(rw),
    ?assertEqual({ok, ?ROOT_QID}, attach(Grant, 1)),
    ?assertEqual({error, enoent}, call(Grant, {attach, 2, ?NOFID, <<"u">>, <<"tmp">>, 0})),
    ?assertEqual({error, ebadf}, call(Grant, {attach, 2, 7, <<"u">>, ?TREE, 0})),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    stop(Grant).

%% Fid numbers -------------------------------------------------------------

fid_in_use_is_refused_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    {ok, [?A_QID]} = walk(Grant, 1, 2, [<<"a">>]),
    ?assertEqual({error, einval}, attach(Grant, 1)),
    ?assertEqual({error, einval}, attach(Grant, 2)),
    ?assertEqual({error, einval}, walk(Grant, 1, 2, [<<"f">>])),
    %% The fid in use is untouched by the refusals.
    ?assertEqual(?A_QID, qid_of(Grant, 2)),
    ok = call(Grant, {clunk, 2}),
    ?assertEqual({ok, [?A_QID]}, walk(Grant, 1, 2, [<<"a">>])),
    stop(Grant).

%% Walking -----------------------------------------------------------------

dotdot_stays_at_the_root_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    ?assertEqual({ok, [?ROOT_QID, ?ROOT_QID]}, walk(Grant, 1, 2, [<<"..">>, <<"..">>])),
    ?assertEqual({ok, [?A_QID, ?ROOT_QID, ?ROOT_QID, ?A_QID]},
                 walk(Grant, 1, 3, [<<"a">>, <<"..">>, <<"..">>, <<"a">>])),
    ?assertEqual({ok, [?A_QID, {16#80, 0, 3}, ?A_QID, ?ROOT_QID]},
                 walk(Grant, 1, 4, [<<"a">>, <<"b">>, <<"..">>, <<"..">>])),
    ?assertEqual(?ROOT_QID, qid_of(Grant, 4)),
    %% ".." from a fid walked below the root returns to its recorded parent.
    ?assertEqual({ok, [?ROOT_QID]}, walk(Grant, 3, 3, [<<"..">>])),
    stop(Grant).

walk_that_stops_makes_no_fid_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    ?assertEqual({error, enoent}, walk(Grant, 1, 2, [<<"missing">>])),
    ?assertEqual({ok, [?A_QID]}, walk(Grant, 1, 2, [<<"a">>, <<"missing">>])),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    %% A walk in place that stops leaves its fid where it was.
    ?assertEqual({ok, [?A_QID]}, walk(Grant, 1, 1, [<<"a">>, <<"missing">>])),
    ?assertEqual(?ROOT_QID, qid_of(Grant, 1)),
    stop(Grant).

walk_through_a_link_stops_at_it_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    flush_tree_calls(),
    ?assertEqual({ok, [?LINK_QID]}, walk(Grant, 1, 2, [<<"l">>, <<"b">>])),
    ?assertEqual([walk], tree_calls()),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    {ok, [?LINK_QID]} = walk(Grant, 1, 2, [<<"l">>]),
    ?assertEqual({ok, <<"a">>}, call(Grant, {readlink, 2})),
    ?assertEqual({error, enotdir}, walk(Grant, 2, 3, [<<"b">>])),
    ?assertEqual({error, enotdir}, walk(Grant, 2, 3, [<<"..">>])),
    stop(Grant).

flush_tree_calls() ->
    _ = tree_calls(),
    ok.

pipelined_requests_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    [Walk, Stat, Bad, Getattr] = [alias([reply]) || _ <- lists:seq(1, 4)],
    Grant ! {erx_9p, Walk, self(), {walk, 1, 2, [<<"a">>, <<"f">>]}},
    Grant ! {erx_9p, Stat, self(), {getattr, 2, 16#7ff}},
    Grant ! {erx_9p, Bad, self(), {walk, 1, 3, [<<"l">>, <<"f">>]}},
    Grant ! {erx_9p, Getattr, self(), {getattr, 3, 16#7ff}},
    ?assertMatch({ok, [?A_QID, {0, 0, 4}]}, receive {erx_9p, Walk, R1} -> R1 end),
    ?assertMatch({ok, #{qid := {0, 0, 4}}}, receive {erx_9p, Stat, R2} -> R2 end),
    ?assertMatch({ok, [?LINK_QID]}, receive {erx_9p, Bad, R3} -> R3 end),
    ?assertEqual({error, ebadf}, receive {erx_9p, Getattr, R4} -> R4 end),
    stop(Grant).

%% Owners ------------------------------------------------------------------

owner_outside_the_domain_is_refused_test() ->
    Grant = grant(rw),
    flush_tree_calls(),
    ?assertEqual({error, einval}, attach(Grant, foreign_pid(), 1)),
    ?assertEqual([], tree_calls()),
    ?assertEqual(ebadf, qid_of(Grant, 1)),
    {ok, _} = attach(Grant, 1),
    ?assertEqual({error, einval}, call(Grant, foreign_pid(), {walk, 1, 2, []})),
    ?assertEqual({error, einval}, call(Grant, foreign_pid(), {clunk, 1})),
    ?assertEqual(?ROOT_QID, qid_of(Grant, 1)),
    ?assertEqual(1, monitors(Grant)),
    stop(Grant).

monitor_is_removed_at_the_last_fid_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"a">>]),
    ?assertEqual(1, monitors(Grant)),
    ok = call(Grant, {clunk, 1}),
    ?assertEqual(1, monitors(Grant)),
    ok = call(Grant, {clunk, 2}),
    ?assertEqual(0, monitors(Grant)),
    stop(Grant).

%% A fid made for an owner that has already ended is clunked when the grant
%% handles that owner's DOWN, which OTP delivers at once.
ended_owner_leaves_no_fid_test() ->
    Grant = grant(rw),
    Ended = ended_process(),
    {ok, _} = attach(Grant, 1),
    ?assertEqual({ok, ?ROOT_QID}, attach(Grant, Ended, 2)),
    ?assertMatch({ok, []}, call(Grant, Ended, {walk, 1, 3, []})),
    wait_for_monitors(Grant, 1),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    ?assertEqual(ebadf, qid_of(Grant, 3)),
    %% Twice, so the second fid meets an owner the grant already forgot.
    ?assertEqual({ok, ?ROOT_QID}, attach(Grant, Ended, 2)),
    wait_for_monitors(Grant, 1),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    stop(Grant).

owner_end_clunks_its_fids_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    Owner = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = attach(Grant, Owner, 2),
    {ok, _} = call(Grant, Owner, {walk, 2, 3, [<<"a">>]}),
    ?assertEqual(2, monitors(Grant)),
    Owner ! stop,
    wait_for_monitors(Grant, 1),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    ?assertEqual(ebadf, qid_of(Grant, 3)),
    ?assertEqual(?ROOT_QID, qid_of(Grant, 1)),
    stop(Grant).

%% 100,000 owners that each make and clunk one fid, then 10,000 that each make
%% one and end: afterwards the grant monitors no one and holds no fid.
short_lived_owners_test_() ->
    {timeout, 120, fun short_lived_owners/0}.

short_lived_owners() ->
    Grant = quiet_grant(),
    Clunking = fun(Fid) ->
                       {ok, _} = attach(Grant, Fid),
                       ok = call(Grant, {clunk, Fid})
               end,
    run_owners(Clunking, [lists:seq(1, 32) || _ <- lists:seq(1, 100000 div 32)]),
    ?assertEqual(0, monitors(Grant)),
    Leaving = fun(Fid) -> {ok, _} = attach(Grant, Fid) end,
    Fids = lists:seq(1, 10016),
    run_owners(Leaving, [lists:sublist(Fids, Start, 32) || Start <- lists:seq(1, 10016, 32)]),
    wait_for_monitors(Grant, 0),
    ?assertEqual({ok, ?ROOT_QID}, attach(Grant, 10016)),
    stop(Grant).

%% One owner process for each fid of a batch, the batches one after another.
run_owners(Body, Batches) ->
    Parent = self(),
    lists:foreach(
      fun(Batch) ->
              Pids = [spawn(fun() -> Body(Fid), Parent ! {done, self()} end) || Fid <- Batch],
              [receive {done, Pid} -> ok after 5000 -> erlang:error(owner_stuck) end
               || Pid <- Pids]
      end, Batches).

%% Bounds ------------------------------------------------------------------

fid_flood_stops_at_the_pool_test() ->
    Grant = grant(rw, #{pool => 8}),
    Owners = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, 8)],
    [?assertEqual({ok, ?ROOT_QID}, attach(Grant, Owner, Fid))
     || {Fid, Owner} <- lists:zip(lists:seq(1, 8), Owners)],
    ?assertEqual({error, emfile}, attach(Grant, 9)),
    ?assertEqual({error, emfile}, walk(Grant, 1, 9, [<<"a">>])),
    ?assertEqual(8, monitors(Grant)),
    %% A walk in place makes no fid and passes at a full pool.
    ?assertEqual({ok, [?A_QID]}, walk(Grant, 1, 1, [<<"a">>])),
    ok = call(Grant, {clunk, 8}),
    ?assertEqual({ok, ?ROOT_QID}, attach(Grant, 9)),
    [Owner ! stop || Owner <- Owners],
    wait_for_monitors(Grant, 1),
    stop(Grant).

%% The in-flight bound and flush, on the pure core: requests answered outside
%% the grant's step come with open files, so the core's hooks stand in here.
in_flight_bound_test() ->
    Core0 = core(rw),
    {_, Core1} = core_frame(Core0, {attach, 1, ?NOFID, <<"u">>, ?TREE, 0}),
    Deferred = [make_ref() || _ <- lists:seq(1, 64)],
    Core2 = lists:foldl(fun(Alias, Core) ->
                                erx_fs_grant:defer(Alias, {getattr, 1, 0}, Core)
                        end, Core1, Deferred),
    ?assertMatch({[{reply, _, {error, emfile}}], _},
                 core_frame(Core2, {getattr, 1, 0})),
    %% A refused remove still clunks its fid.
    {[{demonitor, _}, {reply, _, {error, emfile}}], Core3} = core_frame(Core2, {remove, 1}),
    ?assertMatch(#{fids := 0, owners := 0, in_flight := 64}, erx_fs_grant:info(Core3)),
    [First | _] = Deferred,
    {Effects, Core4} = erx_fs_grant:complete(First, {error, ebadf}, Core2),
    ?assertEqual([{reply, First, {error, ebadf}}], Effects),
    %% One slot free: a flush of a deferred request waits for its answer.
    [_, Second | _] = Deferred,
    Flush = make_ref(),
    {[], Core5} = erx_fs_grant:handle_frame({erx_9p, Flush, self(), {flush, Second}}, Core4),
    ?assertMatch(#{in_flight := 64}, erx_fs_grant:info(Core5)),
    ?assertMatch({[{reply, _, {error, emfile}}], _}, core_frame(Core5, {flush, Second})),
    %% A flush of a request not in flight holds nothing and passes the bound.
    ?assertMatch({[{reply, _, ok}], _}, core_frame(Core5, {flush, make_ref()})),
    {Answers, Core6} = erx_fs_grant:complete(Second, {error, ebadf}, Core5),
    ?assertEqual([{reply, Second, {error, ebadf}}, {reply, Flush, ok}], Answers),
    ?assertMatch(#{in_flight := 62}, erx_fs_grant:info(Core6)),
    %% A flush of a request that is not in flight is answered at once.
    ?assertMatch({[{reply, _, ok}], _}, core_frame(core(rw), {flush, make_ref()})).

%% A core whose monitors the test performs: core_frame/2 hands every monitor
%% effect back at once.
core(Rights) ->
    {module, _} = code:ensure_loaded(erx_fs_test_tree),
    {ok, Tree} = erx_fs_test_tree:init([]),
    erx_fs_grant:new(#{module => erx_fs_test_tree, tree => Tree, rights => Rights,
                       client => node()}).

core_frame(Core, Request) ->
    core_frame(Core, self(), Request).

core_frame(Core, Owner, Request) ->
    {Effects, Core1} = erx_fs_grant:handle_frame({erx_9p, make_ref(), Owner, Request}, Core),
    {Effects, lists:foldl(fun({monitor, Pid}, C) -> erx_fs_grant:monitored(Pid, make_ref(), C);
                             (_, C) -> C
                          end, Core1, Effects)}.

%% Read-only grants (F5) ---------------------------------------------------

%% One valid request of each operation, the writing ones in their writing form.
samples() ->
    #{statfs => {statfs, 1}, lopen => {lopen, 1, ?O_WRONLY},
      lcreate => {lcreate, 1, <<"n">>, 0, 8#644, 0},
      symlink => {symlink, 1, <<"n">>, <<"t">>, 0},
      mknod => {mknod, 1, <<"n">>, 8#644, 0, 0, 0}, readlink => {readlink, 1},
      getattr => {getattr, 1, 16#7ff},
      setattr => {setattr, 1, maps:from_keys([valid, mode, uid, gid, size, atime_sec,
                                              atime_nsec, mtime_sec, mtime_nsec], 0)},
      xattrwalk => {xattrwalk, 1, 9, <<"n">>}, xattrcreate => {xattrcreate, 1, <<"n">>, 1, 0},
      readdir => {readdir, 1, 0, 4096}, fsync => {fsync, 1, 0},
      lock => {lock, 1, ?WRLCK, 0, 0, 1, 1, <<"c">>},
      getlock => {getlock, 1, ?WRLCK, 0, 1, 1, <<"c">>}, link => {link, 1, 1, <<"n">>},
      mkdir => {mkdir, 1, <<"n">>, 8#755, 0},
      renameat => {renameat, 1, <<"f">>, 1, <<"g">>}, unlinkat => {unlinkat, 1, <<"f">>, 0},
      version => {version, 8192, <<"9P2000.L">>},
      auth => {auth, 9, <<"u">>, ?TREE, 0},
      attach => {attach, 9, ?NOFID, <<"u">>, ?TREE, 0}, flush => {flush, make_ref()},
      walk => {walk, 1, 9, [<<"a">>]}, read => {read, 1, 0, 1},
      write => {write, 1, 0, <<"x">>}, clunk => {clunk, 1}, remove => {remove, 1}}.

-define(WRITING, [lcreate, link, lock, lopen, mkdir, mknod, remove, renameat, setattr,
                  symlink, unlinkat, write, xattrcreate]).

read_only_grants_refuse_every_writing_operation_test_() ->
    [{atom_to_list(Rights), fun() -> refuses_writes(Rights) end} || Rights <- [ro, rx]].

refuses_writes(Rights) ->
    Samples = samples(),
    ?assertEqual(lists:sort(erx_9p_grammar:operations()), lists:sort(maps:keys(Samples))),
    Refused = [Op || Op <- lists:sort(maps:keys(Samples)), refused(Rights, maps:get(Op, Samples))],
    ?assertEqual(?WRITING, Refused).

%% Whether a fresh grant with Rights answers Request erofs without a callback.
refused(Rights, Request) ->
    Grant = grant(Rights),
    {ok, _} = attach(Grant, 1),
    flush_tree_calls(),
    Reply = call(Grant, Request),
    Calls = tree_calls(),
    stop(Grant),
    case Reply of
        {error, erofs} -> ?assertEqual({Request, []}, {Request, Calls}), true;
        _ -> false
    end.

lcreate_is_refused_whatever_its_flags_test() ->
    [?assert(refused(ro, {lcreate, 1, <<"f">>, Flags, 8#644, 0})) || Flags <- [0, 8#100]],
    ?assertNot(refused(ro, {lopen, 1, 0})),
    ?assert(refused(ro, {lopen, 1, ?O_TRUNC})).

refused_remove_still_clunks_its_fid_test() ->
    Grant = grant(ro),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"f">>]),
    flush_tree_calls(),
    ?assertEqual({error, erofs}, call(Grant, {remove, 2})),
    ?assertEqual([], tree_calls()),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    ?assertMatch({ok, [{0, 0, 6}]}, walk(Grant, 1, 2, [<<"f">>])),
    stop(Grant).

tree_without_write_is_read_only_test() ->
    {ok, Tree} = erx_fs_test_tree:init([]),
    Core = erx_fs_grant:new(#{module => ?MODULE, tree => Tree, rights => rw, client => node()}),
    ?assertMatch(#{rights := ro}, erx_fs_grant:info(Core)).

%% Changes on a read-write grant -------------------------------------------

make_unlink_rename_setattr_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    {ok, [_]} = walk(Grant, 1, 2, [<<"a">>]),
    {ok, {16#80, 0, D}} = call(Grant, {mkdir, 2, <<"d">>, 8#040700, 0}),
    {ok, [{16#80, 0, D}]} = walk(Grant, 2, 3, [<<"d">>]),
    ?assertMatch(#{mode := 8#040700}, getattr(Grant, 3)),
    {ok, {2, 0, _}} = call(Grant, {symlink, 3, <<"s">>, <<"../f">>, 0}),
    ?assertEqual({error, eperm}, call(Grant, {link, 3, 2, <<"x">>})),
    {ok, [_]} = walk(Grant, 1, 4, [<<"f">>]),
    ok = call(Grant, {link, 3, 4, <<"h">>}),
    ?assertEqual({error, enotdir}, call(Grant, {unlinkat, 3, <<"h">>, 16#200})),
    ok = call(Grant, {unlinkat, 3, <<"h">>, 0}),
    ?assertEqual({error, enotempty}, call(Grant, {unlinkat, 2, <<"d">>, 16#200})),
    ok = call(Grant, {renameat, 3, <<"s">>, 2, <<"s2">>}),
    {ok, [{2, 0, _}]} = walk(Grant, 2, 5, [<<"s2">>]),
    ?assertEqual({ok, <<"../f">>}, call(Grant, {readlink, 5})),
    %% remove passes any and clunks its fid.
    ok = call(Grant, {remove, 5}),
    ?assertEqual(ebadf, qid_of(Grant, 5)),
    ?assertEqual({error, enoent}, walk(Grant, 2, 5, [<<"s2">>])),
    ok = call(Grant, {remove, 3}),
    ?assertEqual({error, enoent}, walk(Grant, 2, 3, [<<"d">>])),
    ?assertEqual({error, einval}, call(Grant, {remove, 1})),
    ?assertEqual(ebadf, qid_of(Grant, 1)),
    Set = maps:from_keys([uid, gid, size, atime_sec, atime_nsec, mtime_sec, mtime_nsec], 0),
    ok = call(Grant, {setattr, 4, Set#{valid => 1, mode => 8#600}}),
    ?assertMatch(#{mode := 8#100600}, getattr(Grant, 4)),
    ?assertEqual({error, eperm}, call(Grant, {mknod, 2, <<"n">>, 8#644, 0, 0, 0})),
    ?assertMatch({ok, #{bsize := 4096}}, call(Grant, {statfs, 2})),
    stop(Grant).

getattr(Grant, Fid) ->
    {ok, Attr} = call(Grant, {getattr, Fid, 16#7ff}),
    Attr.

malformed_frames_are_answered_or_dropped_test() ->
    Grant = grant(rw),
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), {walk, 1, 2, [<<"a/b">>]}},
    ?assertEqual({error, einval}, receive {erx_9p, Alias, R} -> R end),
    Grant ! {erx_9p, not_an_alias, self(), {clunk, 1}},
    Grant ! junk,
    Grant ! {system, {self(), make_ref()}, get_state},
    ?assertEqual({ok, ?ROOT_QID}, attach(Grant, 1)),
    %% A DOWN that does not carry the owner's monitor ends none of its fids.
    Grant ! {'DOWN', make_ref(), process, self(), forged},
    ?assertEqual(?ROOT_QID, qid_of(Grant, 1)),
    ?assertEqual(1, monitors(Grant)),
    stop(Grant).

%% A reference made on another node, as an alias of another domain is.
foreign_alias() ->
    Node = <<"other@host">>,
    binary_to_term(<<131, 90, 3:16, 119, (byte_size(Node)), Node/binary, 1:32,
                     1:32, 2:32, 3:32>>).

%% A client may not have the grant answer a third domain: a frame whose alias
%% is not the client domain's is dropped, valid or not.
replies_go_only_to_the_client_domain_test() ->
    Core = core(rw),
    Alias = foreign_alias(),
    [?assertEqual({[], Request}, {element(1, erx_fs_grant:handle_frame(
                                                 {erx_9p, Alias, self(), Request}, Core)),
                                  Request})
     || Request <- [{version, 8192, <<"9P2000.L">>}, {walk, 1, 2, [<<"a/b">>]},
                    {attach, 1, ?NOFID, <<"u">>, ?TREE, 0}]],
    ?assertMatch(#{fids := 0}, erx_fs_grant:info(
                                 element(2, erx_fs_grant:handle_frame(
                                              {erx_9p, Alias, self(),
                                               {attach, 1, ?NOFID, <<"u">>, ?TREE, 0}},
                                              Core)))).

%% The fid table, exhaustively ---------------------------------------------

%% Every sequence of six events over two fids and two owners, on the pure core,
%% against a model that is a map from live fid to owner: a fid exists exactly
%% when the model says, the core records exactly the model's owners, and each
%% such owner has exactly one live monitor.
fid_table_model_test_() ->
    {timeout, 300, fun() -> explore(6) end}.

events() ->
    [{attach, 1, a}, {attach, 2, b}, {clone, 1, 2, b}, {clone, 2, 1, a},
     {stray, 1, 2, a}, {stray, 2, 1, b}, {clunk, 1}, {clunk, 2}, {down, a}, {down, b}].

explore(Depth) ->
    Owners = #{a => ended_process(), b => ended_process()},
    World = #{core => core(rw), model => #{}, alive => #{a => true, b => true},
              monitors => #{}},
    explore(Depth, World, Owners, []).

explore(0, _, _, _) ->
    ok;
explore(Depth, World, Owners, Trace) ->
    lists:foreach(fun(Event) ->
                          World1 = step(Event, World, Owners),
                          check(World1, Owners, [Event | Trace]),
                          explore(Depth - 1, World1, Owners, [Event | Trace])
                  end, events()).

step({attach, Fid, Owner}, World, Owners) ->
    request({attach, Fid, ?NOFID, <<"u">>, ?TREE, 0}, Owner, made(Fid, Owner, World), World,
            Owners);
step({clone, From, To, Owner}, World, Owners) ->
    Model = case maps:is_key(From, model(World)) of
                true -> made(To, Owner, World);
                false -> model(World)
            end,
    request({walk, From, To, []}, Owner, Model, World, Owners);
step({stray, From, To, Owner}, World, Owners) ->
    request({walk, From, To, [<<"a">>, <<"missing">>]}, Owner, model(World), World, Owners);
step({clunk, Fid}, World, Owners) ->
    request({clunk, Fid}, a, maps:remove(Fid, model(World)), World, Owners);
step({down, Owner}, #{alive := Alive, monitors := Monitors} = World, Owners) ->
    Pid = maps:get(Owner, Owners),
    Model = maps:filter(fun(_, O) -> O =/= Owner end, model(World)),
    World1 = World#{alive := Alive#{Owner := false}, model := Model},
    case [Ref || {Ref, P} <- maps:to_list(Monitors), P =:= Pid] of
        [] -> World1;
        [Ref] -> perform(erx_fs_grant:owner_down(Ref, Pid, world_core(World1)),
                         World1#{monitors := maps:remove(Ref, Monitors)}, Owners)
    end.

model(#{model := Model}) -> Model.
world_core(#{core := Core}) -> Core.

%% A fid made while its number is free, for an owner still alive.
made(Fid, Owner, #{model := Model, alive := Alive}) ->
    case {maps:is_key(Fid, Model), maps:get(Owner, Alive)} of
        {false, true} -> Model#{Fid => Owner};
        _ -> Model
    end.

request(Request, Owner, Model, World, Owners) ->
    Pid = maps:get(Owner, Owners),
    Frame = {erx_9p, make_ref(), Pid, Request},
    perform(erx_fs_grant:handle_frame(Frame, world_core(World)), World#{model := Model}, Owners).

%% The shell's effects, with a monitor on an ended owner firing at once.
perform({Effects, Core}, World, Owners) ->
    lists:foldl(fun(Effect, W) -> effect(Effect, W, Owners) end, World#{core := Core}, Effects).

effect({reply, _, _}, World, _) ->
    World;
effect({demonitor, Ref}, #{monitors := Monitors} = World, _) ->
    World#{monitors := maps:remove(Ref, Monitors)};
effect({monitor, Pid}, #{monitors := Monitors, alive := Alive} = World, Owners) ->
    Ref = make_ref(),
    World1 = World#{core := erx_fs_grant:monitored(Pid, Ref, world_core(World))},
    [Owner] = [O || {O, P} <- maps:to_list(Owners), P =:= Pid],
    case maps:get(Owner, Alive) of
        true -> World1#{monitors := Monitors#{Ref => Pid}};
        false -> perform(erx_fs_grant:owner_down(Ref, Pid, world_core(World1)), World1, Owners)
    end.

check(#{core := Core, model := Model, monitors := Monitors}, Owners, Trace) ->
    Expected = #{fids => map_size(Model),
                 owners => length(lists:usort(maps:values(Model))),
                 monitors => length(lists:usort(maps:values(Model)))},
    #{fids := Fids, owners := CoreOwners} = erx_fs_grant:info(Core),
    Actual = #{fids => Fids, owners => CoreOwners, monitors => map_size(Monitors)},
    Live = lists:sort([maps:get(O, Owners) || O <- lists:usort(maps:values(Model))]),
    case {Expected =:= Actual, lists:sort(maps:values(Monitors)) =:= Live} of
        {true, true} -> ok;
        _ -> erlang:error({model_mismatch, lists:reverse(Trace), Expected, Actual})
    end.
