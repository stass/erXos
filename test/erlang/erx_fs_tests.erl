%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_tests).
-moduledoc """
EUnit and property tests of an `erx_fs` grant's fids and owners
(docs/design-files.md#verification-and-testing): fids refused while in use,
".." held at the root, walks that stop at a link, owners outside the domain,
fid floods against the pool, short-lived and ended owners and their monitors,
the in-flight bound, the read-only refusals of F5, pipelined requests, an
exhaustive model of the fid table, and open files: create-or-open, exclusive
creates, writes answering where they landed under two appenders, truncation
decided by the open, the clunks of an ended owner, listings, remove after a
rename, opens of a node with no name, ".." after renames and removals, aliases
in flight and the owner's tag. The grants serve erx_fs_test_tree.
test/host/erx_fs_test.rb runs these on stock OTP and seeds a fault for each.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% This module is also a tree with a root and no write/4 (tree_without_write_is_read_only_test).
-export([root/1]).

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
    {ok, Grant, _} = erx_fs:start_link(erx_fs_test_tree, [{observer, self()}], Rights, Options),
    unlink(Grant),
    Grant.

%% A grant whose tree reports no callbacks, for tests that make many requests.
quiet_grant() ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_test_tree, [], rw),
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

%% A grant on erx_fs_test_tree whose root answers pass through Answer.
answered_grant(Answer) ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_test_tree, [{root_answer, Answer}], rw),
    unlink(Grant),
    Grant.

%% Each attach asks the root afresh and carries its version; an answer naming
%% another type, path or tree than the start admitted is eio and makes no fid.
attach_carries_the_roots_version_and_nothing_else_test() ->
    Change = counters:new(1, []),
    Answer = fun({ok, Tree, Node, {Type, _, Path}}) ->
                     case counters:get(Change, 1) of
                         0 -> {ok, Tree, Node, {Type, 0, Path}};
                         1 -> {ok, Tree, Node, {Type, 7, Path}};
                         2 -> {ok, Tree, Node, {Type, 7, Path + 1}};
                         3 -> {ok, Tree, Node, {0, 7, Path}};
                         4 -> {ok, <<"other">>, Node, {Type, 7, Path}}
                     end
             end,
    Grant = answered_grant(Answer),
    ok = counters:add(Change, 1, 1),
    ?assertEqual({ok, {16#80, 7, 1}}, attach(Grant, 1)),
    [begin
         ok = counters:add(Change, 1, 1),
         ?assertEqual({error, eio}, attach(Grant, Fid)),
         ?assertEqual(ebadf, qid_of(Grant, Fid))
     end || Fid <- [2, 3, 4]],
    ?assertEqual({error, enoent}, call(Grant, {attach, 5, ?NOFID, <<"u">>, <<"other">>, 0})),
    stop(Grant).

%% The root is admitted before the grant takes any request: a qid that is no
%% directory fails the start, so no grant serves it.
a_root_that_is_no_directory_fails_the_start_test() ->
    File = fun({ok, Tree, _, _}) -> {ok, Tree, 6, {0, 0, 6}} end,
    ?assertEqual({error, root}, erx_fs:start_link(erx_fs_test_tree, [{root_answer, File}], rw)).

a_malformed_root_fails_the_start_test() ->
    Long = binary:copy(<<"t">>, 256),
    Answers = [{ok, <<>>, 1, {16#80, 0, 1}}, {ok, Long, 1, {16#80, 0, 1}},
               {ok, <<"a/b">>, 1, {16#80, 0, 1}}, {ok, <<"..">>, 1, {16#80, 0, 1}},
               {ok, test, 1, {16#80, 0, 1}}, {ok, <<"test">>, 1, {16#80, -1, 1}},
               {ok, <<"test">>, 1, {16#80, 0, 1 bsl 64}}, {ok, <<"test">>, 1, {16#80, 0}},
               {error, eio}, ok],
    [?assertEqual({error, root},
                  erx_fs:start_link(erx_fs_test_tree, [{root_answer, fun(_) -> Answer end}], rw))
     || Answer <- Answers],
    %% A tree name of 255 bytes is a plain name, and its grant answers it.
    Longest = binary:copy(<<"t">>, 255),
    ?assertMatch({ok, _, _},
                 erx_fs:start_link(erx_fs_test_tree,
                                   [{root_answer, fun({ok, _, Node, Qid}) -> {ok, Longest, Node, Qid} end}],
                                   rw)).

%% Walks from NOFID ----------------------------------------------------------

%% A walk from NOFID starts at the grant's root, as a walk from a fid an attach
%% had just made: of no names it makes a fid on the root, recording the qid the
%% start admitted, and it makes no fid but NewFid.
nofid_walk_starts_at_the_grants_root_test() ->
    flush_tree_calls(),
    Grant = grant(rw),
    ?assertEqual({ok, []}, walk(Grant, ?NOFID, 1, [])),
    ?assertEqual(?ROOT_QID, qid_of(Grant, 1)),
    ?assertEqual({ok, [?A_QID, {16#80, 0, 3}]}, walk(Grant, ?NOFID, 2, [<<"a">>, <<"b">>])),
    ?assertEqual({ok, [?ROOT_QID, ?A_QID]}, walk(Grant, ?NOFID, 3, [<<"..">>, <<"a">>])),
    ?assertEqual({error, einval}, walk(Grant, ?NOFID, 1, [<<"a">>])),
    ?assertEqual({error, enoent}, walk(Grant, ?NOFID, 4, [<<"none">>])),
    ?assertEqual(ebadf, qid_of(Grant, 4)),
    ?assertEqual([root], [Callback || Callback <- tree_calls(), Callback =:= root]),
    stop(Grant).

%% A grant rooted below its tree's top, as a home grant is: a walk from NOFID
%% starts there, and ".." from it stays there, so nothing above it is reached.
nofid_walk_stays_within_the_grants_root_test() ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_test_tree, [{root, 2}], rw),
    unlink(Grant),
    ?assertEqual({ok, []}, walk(Grant, ?NOFID, 1, [])),
    ?assertEqual(?A_QID, qid_of(Grant, 1)),
    ?assertEqual({ok, [?A_QID, ?A_QID]}, walk(Grant, ?NOFID, 2, [<<"..">>, <<"..">>])),
    %% The f beside /a is /f, inode 6; from this root f is /a/f, inode 4.
    ?assertEqual({ok, [?A_QID, {0, 0, 4}]}, walk(Grant, ?NOFID, 3, [<<"..">>, <<"f">>])),
    ?assertEqual({error, enoent}, walk(Grant, ?NOFID, 4, [<<"l">>])),
    stop(Grant).

%% A walk from NOFID carries only the grant's rights: on a read-only grant the
%% fid it makes writes nothing.
nofid_walk_on_a_read_only_grant_cannot_write_test() ->
    Grant = grant(ro),
    {ok, [_]} = walk(Grant, ?NOFID, 1, [<<"f">>]),
    ?assertEqual({error, erofs}, call(Grant, {lopen, 1, ?O_WRONLY})),
    {ok, []} = walk(Grant, ?NOFID, 2, []),
    ?assertEqual({error, erofs}, call(Grant, {mkdir, 2, <<"d">>, 8#755, 0})),
    ?assertEqual({error, erofs}, call(Grant, {lcreate, 2, <<"n">>, ?O_WRONLY, 8#644, 0})),
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

%% O_DIRECTORY on a fid at a file, a truncating open included, answers enotdir and
%% never reaches the tree's open; at a directory it opens.
lopen_with_directory_opens_only_a_directory_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    {ok, [_]} = walk(Grant, 1, 2, [<<"f">>]),
    {ok, [_]} = walk(Grant, 1, 3, [<<"a">>]),
    flush_tree_calls(),
    ?assertEqual({error, enotdir}, call(Grant, {lopen, 2, ?O_WRONLY bor ?O_TRUNC bor ?ERX_P9_O_DIRECTORY})),
    ?assertEqual([], tree_calls()),
    ?assertMatch({ok, _, _}, call(Grant, {lopen, 3, ?ERX_P9_O_DIRECTORY})),
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

%% Report ------------------------------------------------------------------

%% A grant of another domain holds that domain's frames in its state, its mailbox and the
%% arguments of its frames (a Bluetooth line's write carries keys). It is a plain proc_lib
%% process, and exporting format_status/1 is what makes proc_lib's crash report hide them;
%% what the callback leaves is the reason's name alone.
a_grants_report_shows_no_term_test() ->
    {module, erx_fs} = code:ensure_loaded(erx_fs),
    ?assert(erlang:function_exported(erx_fs, format_status, 1)),
    Secret = <<"GRANT-SECRET">>,
    Status = erx_fs:format_status(#{reason => {tree_ended, Secret}, state => {grant, Secret},
                                    message => {erx_9p, make_ref(), self(), {write, 1, 0, Secret}}}),
    ?assertEqual(#{reason => tree_ended, state => hidden, message => hidden}, Status).

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

%% A grant for its own domain ends with the process ends_with names, whatever
%% that process's reason, normal included (docs/design-files.md,
%% "Interfaces"), as a program's /dev tree ends with its handler.
own_grant_ends_with_what_it_names_test() ->
    Holder = spawn(fun() -> receive go -> ok end end),
    Grant = grant(rw, #{ends_with => Holder}),
    Watch = monitor(process, Grant),
    ?assertMatch({ok, _}, attach(Grant, 1)),
    Holder ! go,
    %% A grant that stays fails here, within EUnit's 5 s, so the module's other
    %% cases still run.
    receive
        {'DOWN', Watch, process, Grant, Reason} -> ?assertEqual({shutdown, connection_ended}, Reason)
    after 4000 ->
        stop(Grant),
        ?assert(false)
    end.

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

%% A core of the test tree, served by the calling process.
core(Rights) ->
    {module, _} = code:ensure_loaded(erx_fs_test_tree),
    {ok, Fs} = erx_fs_test_tree:init([]),
    {ok, Core} = erx_fs_grant:new(#{module => erx_fs_test_tree, fs => Fs, rights => Rights,
                                     client => own}),
    Core.

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

root(Fs) -> erx_fs_test_tree:root(Fs).

tree_without_write_is_read_only_test() ->
    {ok, Fs} = erx_fs_test_tree:init([]),
    {ok, Core} = erx_fs_grant:new(#{module => ?MODULE, fs => Fs, rights => rw, client => own}),
    ?assertMatch(#{rights := ro}, erx_fs_grant:info(Core)).

%% Changes on a read-write grant -------------------------------------------

%% A mkdir's Owner reaches the tree as the request's own, not the grant's or the
%% caller's: a window's holder is that Owner (docs/design-files.md, "Fid owners").
mkdir_carries_the_requests_owner_test() ->
    Grant = grant(rw),
    Owner = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = attach(Grant, Owner, 1),
    {ok, _} = call(Grant, Owner, {mkdir, 1, <<"w">>, 8#755, 0}),
    ?assertEqual({directory, 8#755, Owner}, receive {tree_make, What} -> What after 2000 -> none end),
    Owner ! stop,
    stop(Grant).

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
    %% remove passes the node its fid stands at, and clunks the fid.
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

%% Frames from another domain, as edit 16 delivers them: in the envelope
%% {erx_origin, D, Frame}, D the domain of the connection the frame came on. The
%% names are built for domain D's node, so erx_dist's stand-in reads D from them as
%% the BIF does; the core only answers them, so nothing is sent to them.
-define(CLIENT, 5).
-define(THIRD, 9).

domain_pid(D) ->
    binary_to_term(<<131, 88, 119, 9, "d@erxos11", 1:32, 0:32, D:32>>).

domain_ref(D) ->
    binary_to_term(<<131, 90, 3:16, 119, 9, "d@erxos11", D:32, 1:32, 2:32, 3:32>>).

client_core() ->
    {ok, Fs} = erx_fs_test_tree:init([]),
    {ok, Core} = erx_fs_grant:new(#{module => erx_fs_test_tree, fs => Fs, rights => ro, client => ?CLIENT}),
    Core.

%% Effects and the refusals counted after Message reaches a fresh core.
handled(Core, Message) ->
    {Effects, Core1} = erx_fs_grant:handle_frame(Message, Core),
    {Effects, maps:get(refused, erx_fs_grant:info(Core1))}.

%% A grant for another domain takes a frame only in that domain's envelope, and
%% answers it only to that domain's alias, for that domain's owner: a frame
%% enveloped from a third domain, or bare, from the server's own, is dropped and
%% counted, with no answer to anyone.
frames_come_only_from_the_client_domain_test() ->
    Core = client_core(),
    Alias = domain_ref(?CLIENT),
    Version = {version, 8192, <<"9P2000.L">>},
    Frame = {erx_9p, Alias, domain_pid(?CLIENT), Version},
    ?assertEqual({[{reply, Alias, {ok, 8192, <<"9P2000.L">>}}], 0},
                 handled(Core, {erx_origin, ?CLIENT, Frame})),
    ?assertEqual({[], 1}, handled(Core, {erx_origin, ?THIRD, Frame})),
    ?assertEqual({[], 1}, handled(Core, Frame)),
    ?assertEqual({[], 1}, handled(Core, {erx_origin, ?CLIENT, {erx_origin, ?CLIENT, Frame}})),
    %% In the client's envelope, a third domain's alias is dropped and a third
    %% domain's owner refused to the client's alias.
    ThirdAlias = {erx_9p, domain_ref(?THIRD), domain_pid(?CLIENT), Version},
    ?assertEqual({[], 1}, handled(Core, {erx_origin, ?CLIENT, ThirdAlias})),
    ThirdOwner = {erx_9p, Alias, domain_pid(?THIRD), {attach, 1, ?NOFID, <<"u">>, ?TREE, 0}},
    ?assertEqual({[{reply, Alias, {error, einval}}], 1},
                 handled(Core, {erx_origin, ?CLIENT, ThirdOwner})).

%% A grant for the server's own domain takes bare frames only: one in any
%% domain's envelope is dropped and counted, whatever names it carries.
own_grant_drops_every_envelope_test() ->
    Core = core(ro),
    Frame = {erx_9p, make_ref(), self(), {version, 8192, <<"9P2000.L">>}},
    ?assertMatch({[{reply, _, {ok, 8192, _}}], 0}, handled(Core, Frame)),
    [?assertEqual({[], 1}, handled(Core, {erx_origin, D, Frame})) || D <- [own, 0, ?CLIENT, ?THIRD]].

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
        [Ref] -> perform(erx_fs_grant:down(Ref, Pid, world_core(World1)),
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
        false -> perform(erx_fs_grant:down(Ref, Pid, world_core(World1)), World1, Owners)
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

%% Open files ------------------------------------------------------------

-define(O_RDONLY, 0).
-define(O_RDWR, 2).
-define(O_EXCL, 8#200).
-define(O_APPEND, 8#2000).
-define(ATTR_SIZE, 8).

%% Sends one request to a fresh alias and returns the alias, for requests
%% pipelined before their replies are read.
send(Grant, Owner, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, Owner, Request},
    Alias.

answer(Alias) ->
    receive
        {erx_9p, Alias, Reply} -> Reply
    after 2000 ->
        erlang:error(no_reply)
    end.

lcreate(Grant, Fid, Name, Flags) ->
    call(Grant, {lcreate, Fid, Name, Flags, 8#644, 0}).

set_attr(Changes) ->
    maps:merge(maps:from_keys([valid, mode, uid, gid, size, atime_sec, atime_nsec,
                               mtime_sec, mtime_nsec], 0), Changes).

size_of(Grant, Fid) ->
    #{size := Size} = getattr(Grant, Fid),
    Size.

%% Two lcreates of one new name, sent before either is answered, both open
%% the one file it names: the first makes it, the second opens it.
two_openers_of_one_new_name_both_succeed_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, []} = walk(Grant, 1, 2, []),
    {ok, []} = walk(Grant, 1, 3, []),
    First = send(Grant, self(), {lcreate, 2, <<"new">>, ?O_RDWR, 8#644, 0}),
    Second = send(Grant, self(), {lcreate, 3, <<"new">>, ?O_RDWR, 8#644, 0}),
    {ok, Qid, 0} = answer(First),
    ?assertMatch({ok, Qid, 0}, answer(Second)),
    ?assertEqual({ok, 3, 0}, call(Grant, {write, 2, 0, <<"one">>})),
    ?assertEqual({ok, <<"one">>}, call(Grant, {read, 3, 0, 100})),
    stop(Grant).

lcreate_with_exclusive_answers_eexist_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, []} = walk(Grant, 1, 2, []),
    ?assertEqual({error, eexist}, lcreate(Grant, 2, <<"f">>, ?O_RDWR bor ?O_EXCL)),
    %% The refused lcreate left the fid unopened, at the directory.
    ?assertEqual({error, ebadf}, call(Grant, {read, 2, 0, 1})),
    ?assertMatch({ok, [_]}, walk(Grant, 2, 3, [<<"f">>])),
    ?assertMatch({ok, _, 0}, lcreate(Grant, 2, <<"g">>, ?O_RDWR bor ?O_EXCL)),
    stop(Grant).

%% Each write answers where its bytes landed; the bytes are there.
write_answers_where_it_wrote_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, []} = walk(Grant, 1, 2, []),
    {ok, _, 0} = lcreate(Grant, 2, <<"w">>, ?O_RDWR),
    ?assertEqual({ok, 3, 5}, call(Grant, {write, 2, 5, <<"abc">>})),
    ?assertEqual({ok, <<0, 0, 0, 0, 0, "abc">>}, call(Grant, {read, 2, 0, 100})),
    ?assertEqual(8, size_of(Grant, 2)),
    %% A write through a read-only open is refused by the tree, through the owner.
    {ok, [_]} = walk(Grant, 1, 3, [<<"w">>]),
    {ok, _, 0} = call(Grant, {lopen, 3, ?O_RDONLY}),
    ?assertEqual({error, ebadf}, call(Grant, {write, 3, 0, <<"x">>})),
    %% An unopened fid has no handle to read or write through.
    {ok, [_]} = walk(Grant, 1, 4, [<<"w">>]),
    ?assertEqual({error, ebadf}, call(Grant, {write, 4, 0, <<"x">>})),
    ?assertEqual({error, ebadf}, call(Grant, {fsync, 4, 0})),
    %% A tree without fsync syncs nothing and answers ok.
    ?assertEqual(ok, call(Grant, {fsync, 2, 0})),
    stop(Grant).

%% Two clients append through their own fids, each with its writes pipelined.
%% Every write answers where it landed: the answers tile the file from 0 with
%% no gap or overlap, and each write's bytes are where its answer says.
append_answers_order_two_appenders_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, []} = walk(Grant, 1, 2, []),
    {ok, _, 0} = lcreate(Grant, 2, <<"log">>, ?O_RDWR bor ?O_APPEND),
    Parent = self(),
    Appender = fun(Fid, Byte) ->
                       fun() ->
                               {ok, [_]} = walk(Grant, 1, Fid, [<<"log">>]),
                               {ok, _, 0} = call(Grant, {lopen, Fid, 1 bor ?O_APPEND}),
                               Writes = [binary:copy(<<Byte>>, N) || N <- lists:seq(1, 20)],
                               Aliases = [send(Grant, self(), {write, Fid, 0, W}) || W <- Writes],
                               Parent ! {appended, [{W, answer(A)} || {W, A} <- lists:zip(Writes, Aliases)]}
                       end
               end,
    spawn_link(Appender(3, $a)),
    spawn_link(Appender(4, $b)),
    Results = lists:append([receive {appended, R} -> R after 5000 -> erlang:error(no_appends) end
                            || _ <- [1, 2]]),
    Landed = lists:sort([{At, Data} || {Data, {ok, Count, At}} <- Results, Count =:= byte_size(Data)]),
    ?assertEqual(40, length(Landed)),
    {ok, Contents} = call(Grant, {read, 2, 0, 65536}),
    End = lists:foldl(fun({At, Data}, Expected) ->
                              ?assertEqual(Expected, At),
                              ?assertEqual(Data, binary:part(Contents, At, byte_size(Data))),
                              At + byte_size(Data)
                      end, 0, Landed),
    ?assertEqual(End, byte_size(Contents)),
    stop(Grant).

%% A size change through an opened fid is decided by that open's access: a
%% read-only open truncates nothing. Through an unopened fid the node decides.
truncate_through_a_read_only_open_is_refused_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, []} = walk(Grant, 1, 2, []),
    {ok, _, 0} = lcreate(Grant, 2, <<"t">>, ?O_RDWR),
    {ok, 5, 0} = call(Grant, {write, 2, 0, <<"hello">>}),
    {ok, [_]} = walk(Grant, 1, 3, [<<"t">>]),
    {ok, _, 0} = call(Grant, {lopen, 3, ?O_RDONLY}),
    Truncate = set_attr(#{valid => ?ATTR_SIZE, size => 0}),
    ?assertEqual({error, einval}, call(Grant, {setattr, 3, Truncate})),
    ?assertEqual({ok, <<"hello">>}, call(Grant, {read, 2, 0, 100})),
    ok = call(Grant, {setattr, 2, set_attr(#{valid => ?ATTR_SIZE, size => 4})}),
    {ok, [_]} = walk(Grant, 1, 4, [<<"t">>]),
    ok = call(Grant, {setattr, 4, set_attr(#{valid => ?ATTR_SIZE, size => 2})}),
    ?assertEqual({ok, <<"he">>}, call(Grant, {read, 3, 0, 100})),
    stop(Grant).

%% A process that ends with files open has its opened fids clunked, and the
%% tree hears each clunk.
owner_end_clunks_its_open_fids_test() ->
    Grant = grant(rw),
    Parent = self(),
    {Client, Ref} = spawn_monitor(
                      fun() ->
                              {ok, _} = attach(Grant, 1),
                              {ok, []} = walk(Grant, 1, 2, []),
                              {ok, _, 0} = lcreate(Grant, 2, <<"o">>, ?O_RDWR),
                              {ok, [_]} = walk(Grant, 1, 3, [<<"o">>]),
                              {ok, _, 0} = call(Grant, {lopen, 3, ?O_RDONLY}),
                              {ok, [_]} = walk(Grant, 1, 4, [<<"a">>]),
                              {ok, _, 0} = call(Grant, {lopen, 4, ?O_RDONLY}),
                              Parent ! opened,
                              receive stop -> ok end
                      end),
    receive opened -> ok after 2000 -> erlang:error(not_opened) end,
    flush_tree_calls(),
    Client ! stop,
    receive {'DOWN', Ref, process, Client, _} -> ok end,
    wait_for_monitors(Grant, 0),
    %% A request behind the DOWN returns once the grant has taken the DOWN.
    ?assertEqual({error, ebadf}, call(Grant, {clunk, 9})),
    ?assertEqual([clunk, clunk, clunk], [C || C <- tree_calls(), C =:= clunk]),
    stop(Grant).

%% readdir needs an opened directory fid and fits its entries to the count.
readdir_over_an_open_directory_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, []} = walk(Grant, 1, 2, []),
    ?assertEqual({error, ebadf}, call(Grant, {readdir, 2, 0, 8192})),
    {ok, ?ROOT_QID, 0} = call(Grant, {lopen, 2, ?O_RDONLY}),
    ?assertMatch({ok, [{?A_QID, 1, 4, <<"a">>}, {_, 2, 8, <<"f">>}, {?LINK_QID, 3, 10, <<"l">>}]},
                 call(Grant, {readdir, 2, 0, 8192})),
    ?assertMatch({ok, [{?LINK_QID, 3, 10, <<"l">>}]}, call(Grant, {readdir, 2, 2, 8192})),
    ?assertEqual({ok, []}, call(Grant, {readdir, 2, 3, 8192})),
    %% 25 bytes hold one entry of a one-byte name; 24 hold none.
    ?assertMatch({ok, [{?A_QID, 1, 4, <<"a">>}]}, call(Grant, {readdir, 2, 0, 25})),
    ?assertEqual({error, einval}, call(Grant, {readdir, 2, 0, 24})),
    %% A file opened is no directory to list.
    {ok, [_]} = walk(Grant, 1, 3, [<<"f">>]),
    {ok, _, 0} = call(Grant, {lopen, 3, ?O_RDONLY}),
    ?assertEqual({error, enotdir}, call(Grant, {readdir, 3, 0, 8192})),
    %% No walk starts from an opened fid.
    ?assertEqual({error, einval}, walk(Grant, 2, 4, [<<"a">>])),
    stop(Grant).

%% A request whose directory fid names a file or a link is enotdir from the
%% grant, so the tree is never asked to make, unlink, rename or list in a
%% node that is no directory, whatever its own checks; the directory fid of
%% each such request is refused alone, the other fid naming a directory.
directory_operations_on_a_file_or_a_link_reach_no_tree_test() ->
    Grant = grant(rw),
    {ok, _} = attach(Grant, 1),
    {ok, [_]} = walk(Grant, 1, 2, [<<"a">>]),
    {ok, [_]} = walk(Grant, 1, 3, [<<"f">>]),
    {ok, [?LINK_QID]} = walk(Grant, 1, 4, [<<"l">>]),
    flush_tree_calls(),
    Requests = fun(NotDir) ->
                       [{mkdir, NotDir, <<"n">>, 8#755, 0},
                        {symlink, NotDir, <<"n">>, <<"t">>, 0},
                        {mknod, NotDir, <<"n">>, 8#644, 0, 0, 0},
                        {link, NotDir, 2, <<"n">>},
                        {unlinkat, NotDir, <<"n">>, 0},
                        {unlinkat, NotDir, <<"n">>, 16#200},
                        {renameat, NotDir, <<"f">>, 2, <<"n">>},
                        {renameat, 2, <<"b">>, NotDir, <<"n">>},
                        {lcreate, NotDir, <<"n">>, ?O_RDWR, 8#644, 0},
                        {walk, NotDir, 5, [<<"n">>]}]
               end,
    [?assertEqual({Request, {error, enotdir}}, {Request, call(Grant, Request)})
     || NotDir <- [3, 4], Request <- Requests(NotDir)],
    ?assertEqual([], tree_calls()),
    %% Nothing changed: the fids still stand where they were walked.
    ?assertEqual(?LINK_QID, qid_of(Grant, 4)),
    ?assertMatch({ok, [_, _]}, walk(Grant, 1, 5, [<<"a">>, <<"b">>])),
    %% A file opened is listed by no tree.
    {ok, _, 0} = call(Grant, {lopen, 3, ?O_RDONLY}),
    flush_tree_calls(),
    ?assertEqual({error, enotdir}, call(Grant, {readdir, 3, 0, 8192})),
    ?assertEqual([], tree_calls()),
    stop(Grant).

%% remove acts on the fid's node, not on whatever its name names now: after
%% the name moved and a new file took it, remove leaves the new file alone.
remove_after_a_rename_leaves_the_new_name_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, [{0, 0, 6}]} = walk(Grant, 1, 2, [<<"f">>]),
    ok = call(Grant, {renameat, 1, <<"f">>, 1, <<"g">>}),
    {ok, []} = walk(Grant, 1, 3, []),
    {ok, {0, 0, New}, 0} = lcreate(Grant, 3, <<"f">>, ?O_RDWR),
    ?assertEqual({error, enoent}, call(Grant, {remove, 2})),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    ?assertEqual({ok, [{0, 0, New}]}, walk(Grant, 1, 4, [<<"f">>])),
    ?assertEqual({ok, [{0, 0, 6}]}, walk(Grant, 1, 5, [<<"g">>])),
    %% Renamed away and back, the name names the fid's node again.
    ok = call(Grant, {renameat, 1, <<"g">>, 1, <<"h">>}),
    ok = call(Grant, {renameat, 1, <<"h">>, 1, <<"g">>}),
    ?assertEqual(ok, call(Grant, {remove, 5})),
    ?assertEqual({error, enoent}, walk(Grant, 1, 5, [<<"g">>])),
    stop(Grant).

%% An open through a fid whose node lost its last name opens nothing; an open
%% made before the unlink keeps working.
lopen_of_a_node_with_no_name_is_enoent_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, [_]} = walk(Grant, 1, 2, [<<"f">>]),
    {ok, [_]} = walk(Grant, 1, 3, [<<"f">>]),
    {ok, _, 0} = call(Grant, {lopen, 3, ?O_RDWR}),
    {ok, 4, 0} = call(Grant, {write, 3, 0, <<"kept">>}),
    ok = call(Grant, {unlinkat, 1, <<"f">>, 0}),
    ?assertEqual({error, enoent}, call(Grant, {lopen, 2, ?O_RDONLY})),
    ?assertEqual({ok, <<"kept">>}, call(Grant, {read, 3, 0, 100})),
    stop(Grant).

%% ".." returns to the directory a fid was walked through, whatever was
%% renamed or removed since; the removed directory itself answers enoent.
dotdot_returns_through_renames_and_removals_test() ->
    Grant = quiet_grant(),
    {ok, _} = attach(Grant, 1),
    {ok, [?A_QID, _]} = walk(Grant, 1, 2, [<<"a">>, <<"b">>]),
    ok = call(Grant, {renameat, 1, <<"a">>, 1, <<"c">>}),
    ?assertEqual({ok, [?A_QID]}, walk(Grant, 2, 3, [<<"..">>])),
    ok = call(Grant, {unlinkat, 3, <<"b">>, 16#200}),
    ?assertEqual(enoent, qid_of(Grant, 2)),
    ?assertEqual({ok, [?A_QID, ?ROOT_QID]}, walk(Grant, 2, 4, [<<"..">>, <<"..">>])),
    stop(Grant).

%% A request sent to an alias another request still holds is dropped, since an
%% answer would reach the alias as its earlier request's, and the grant serves
%% on: the alias gets one answer, the read's.
an_alias_in_flight_takes_no_second_request_test() ->
    {Grant, Keeper} = stream_grant(),
    Alias = alias([explicit_unalias]),
    Grant ! {erx_9p, Alias, self(), {read, 2, 0, 16}},
    Grant ! {erx_9p, Alias, self(), {write, 3, 0, <<"y">>}},
    ?assertEqual({ok, 1, 0}, call(Grant, {write, 3, 0, <<"w">>})),
    ok = erx_fs_stream_tree:hand(Keeper, <<"x">>),
    ?assertEqual({ok, <<"x">>}, answer(Alias)),
    ?assertEqual(none, reply_within(Alias, 100)),
    unalias(Alias),
    ?assertEqual({ok, 1, 0}, call(Grant, {write, 3, 0, <<"z">>})),
    stop(Grant).

%% A clunk answers what the tree's clunk answered, and the fid ends either way.
a_clunk_answers_the_trees_clunk_test() ->
    Grant = stale_grant([clunk]),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"f">>]),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDWR}),
    ?assertEqual({error, eio}, call(Grant, {clunk, 2})),
    ?assertEqual({error, ebadf}, call(Grant, {clunk, 2})),
    ?assertMatch({ok, [_]}, walk(Grant, 1, 2, [<<"a">>])),
    stop(Grant).

%% Callbacks' answers -----------------------------------------------------

%% A grant on erx_fs_stale_tree, whose callbacks named in Stale answer with a
%% next state appended, as a tree kept as a value would.
stale_grant(Stale) ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_stale_tree, [{stale, Stale}], rw),
    unlink(Grant),
    Grant.

%% A callback the grant runs that answers with a next state is answered eio,
%% the grant keeps nothing of it, and it goes on serving. A make of a
%% directory answering {ok, Node, Qid, State1} is not taken for a file's
%% {ok, Node, Qid, Handle}.
answers_with_a_state_are_eio_in_the_grant_test() ->
    Grant = stale_grant([open, make, setattr, unlink, rename]),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"f">>]),
    ?assertEqual({error, eio}, call(Grant, {lopen, 2, ?O_WRONLY})),
    {ok, _} = walk(Grant, 1, 3, []),
    ?assertEqual({error, eio}, call(Grant, {lcreate, 3, <<"n">>, ?O_RDWR, 8#644, 0})),
    ?assertEqual({error, eio}, call(Grant, {mkdir, 1, <<"d">>, 8#755, 0})),
    ?assertEqual({error, eio}, call(Grant, {symlink, 1, <<"s">>, <<"t">>, 0})),
    Set = maps:from_keys([uid, gid, size, atime_sec, atime_nsec, mtime_sec, mtime_nsec], 0),
    ?assertEqual({error, eio}, call(Grant, {setattr, 2, Set#{valid => 1, mode => 8#600}})),
    ?assertEqual({error, eio}, call(Grant, {renameat, 1, <<"f">>, 1, <<"g">>})),
    ?assertEqual({error, eio}, call(Grant, {unlinkat, 1, <<"l">>, 0})),
    %% Neither fid was opened: each still walks.
    ?assertMatch({ok, [_]}, walk(Grant, 3, 4, [<<"a">>])),
    ?assertMatch({error, enotdir}, walk(Grant, 2, 5, [<<"x">>])),
    ?assert(is_process_alive(Grant)),
    stop(Grant).

%% The same for requests on an open file: each is answered eio to the client,
%% a clunk included, whose fid ends anyway, and the grant goes on serving.
answers_with_a_state_are_eio_on_an_open_file_test() ->
    Grant = stale_grant([read, write, readdir, setattr, clunk]),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"f">>]),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDWR}),
    ?assertEqual({error, eio}, call(Grant, {write, 2, 0, <<"x">>})),
    ?assertEqual({error, eio}, call(Grant, {read, 2, 0, 1})),
    Set = maps:from_keys([uid, gid, mode, atime_sec, atime_nsec, mtime_sec, mtime_nsec], 0),
    ?assertEqual({error, eio}, call(Grant, {setattr, 2, Set#{valid => 8, size => 0}})),
    {ok, _} = walk(Grant, 1, 3, []),
    {ok, _, _} = call(Grant, {lopen, 3, 0}),
    ?assertEqual({error, eio}, call(Grant, {readdir, 3, 0, 4096})),
    ?assertEqual({error, eio}, call(Grant, {clunk, 2})),
    ?assertEqual({error, eio}, call(Grant, {clunk, 3})),
    ?assertMatch({ok, [_]}, walk(Grant, 1, 4, [<<"a">>])),
    ?assert(is_process_alive(Grant)),
    stop(Grant).

%% A walk answering with a next state is eio too, and records no fid; a root
%% answering so fails the grant's start.
stale_root_and_walk_are_eio_test() ->
    ?assertEqual({error, root}, erx_fs:start_link(erx_fs_stale_tree, [{stale, [root]}], rw)),
    Walk = stale_grant([walk]),
    {ok, _} = attach(Walk, 1),
    ?assertEqual({error, eio}, walk(Walk, 1, 2, [<<"f">>])),
    ?assertEqual(ebadf, qid_of(Walk, 2)),
    ?assert(is_process_alive(Walk)),
    stop(Walk).

%% A grant, and a core, on erx_fs_stale_tree, whose callbacks named in
%% Malformed answer in their own shape with a value the grammar refuses.
malformed_grant(Malformed) ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_stale_tree, [{malformed, Malformed}, {observer, self()}], rw),
    unlink(Grant),
    Grant.

malformed_core(Malformed) ->
    {module, _} = code:ensure_loaded(erx_fs_stale_tree),
    {ok, Fs} = erx_fs_stale_tree:init([{malformed, Malformed}]),
    erx_fs_grant:new(#{module => erx_fs_stale_tree, fs => Fs, rights => rw, client => own}).

%% A malformed qid is answered eio and the grant keeps nothing of the answer:
%% an attach records no fid and monitors no owner, a walk names no new fid,
%% and an lcreate does not open its fid.
malformed_qids_change_nothing_test() ->
    ?assertEqual({error, root}, malformed_core([root])),
    {ok, Core} = malformed_core([walk, make]),
    {_, Core1} = core_frame(Core, {attach, 1, ?NOFID, <<"user">>, ?TREE, 0}),
    {Walked, Core2} = core_frame(Core1, {walk, 1, 2, [<<"f">>]}),
    ?assertMatch([{reply, _, {error, eio}}], Walked),
    ?assertMatch(#{fids := 1}, erx_fs_grant:info(Core2)),
    {_, Core3} = core_frame(Core2, {walk, 1, 3, []}),
    {Created, Core4} = core_frame(Core3, {lcreate, 3, <<"n">>, ?O_RDWR, 8#644, 0}),
    ?assertMatch([{reply, _, {error, eio}}], Created),
    ?assertMatch(#{fids := 2}, erx_fs_grant:info(Core4)),
    %% Fid 3 was not opened: it opens now.
    {Opened, _} = core_frame(Core4, {lopen, 3, 0}),
    ?assertMatch({reply, _, {ok, _, _}}, lists:last(Opened)).

%% The same through a running grant, which goes on serving; the handle the
%% tree opened for the rejected lcreate is clunked, since no fid holds it.
malformed_qids_leave_the_grant_serving_test() ->
    Grant = malformed_grant([walk, make]),
    {ok, _} = attach(Grant, 1),
    ?assertEqual({error, eio}, walk(Grant, 1, 2, [<<"f">>])),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    {ok, _} = walk(Grant, 1, 3, []),
    ?assertEqual({error, eio}, call(Grant, {lcreate, 3, <<"n">>, ?O_RDWR, 8#644, 0})),
    receive
        {tree_call, clunk} -> ok
    after 0 ->
        erlang:error(handle_not_clunked)
    end,
    ?assertMatch({ok, _, _}, call(Grant, {lopen, 3, 0})),
    ?assert(is_process_alive(Grant)),
    stop(Grant).

%% A listing whose tail is not a list is answered eio,
%% and the grant goes on serving.
improper_listing_is_eio_test() ->
    Grant = malformed_grant([readdir]),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, []),
    {ok, _, _} = call(Grant, {lopen, 2, 0}),
    ?assertEqual({error, eio}, call(Grant, {readdir, 2, 0, 4096})),
    ok = call(Grant, {clunk, 2}),
    ?assertMatch({ok, [_]}, walk(Grant, 1, 3, [<<"a">>])),
    ?assert(is_process_alive(Grant)),
    stop(Grant).

%% A remove whose tree answers an error 9P2000.L does not carry is answered
%% eio and still clunks its fid.
rejected_remove_still_clunks_its_fid_test() ->
    Grant = malformed_grant([unlink]),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"f">>]),
    ?assertEqual({error, eio}, call(Grant, {remove, 2})),
    ?assertEqual(ebadf, qid_of(Grant, 2)),
    ?assert(is_process_alive(Grant)),
    stop(Grant).

%% A clunk or a remove whose tree answers an error 9P2000.L does not carry is
%% answered eio, and the tree's clunk of the fid's open runs once.
rejected_clunk_and_remove_clunk_once_test() ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_stale_tree,
                                    [{malformed, [clunk, unlink]}, {observer, self()}], rw),
    unlink(Grant),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"f">>]),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDWR}),
    {ok, _} = walk(Grant, 1, 3, [<<"f">>]),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_RDWR}),
    flush_tree_calls(),
    ?assertEqual({error, eio}, call(Grant, {clunk, 2})),
    ?assertEqual([clunk], tree_calls()),
    ?assertEqual({error, eio}, call(Grant, {remove, 3})),
    ?assertEqual([unlink, clunk], tree_calls()),
    stop(Grant).

%% Waiting requests ------------------------------------------------------

%% A grant on erx_fs_stream_tree, whose reads wait at Keeper for the bytes the
%% test hands it, with fid 1 at the root and fids 2 and 3 opened on the stream.
stream_grant() ->
    Keeper = erx_fs_stream_tree:start_keeper(),
    {ok, Grant, _} = erx_fs:start_link(erx_fs_stream_tree, Keeper, rw),
    unlink(Grant),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"s">>]),
    {ok, _} = walk(Grant, 1, 3, [<<"s">>]),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_WRONLY}),
    {Grant, Keeper}.

%% The reply to Alias within Timeout milliseconds, or none.
reply_within(Alias, Timeout) ->
    receive
        {erx_9p, Alias, Reply} -> Reply
    after Timeout ->
        none
    end.

%% The regression of "Waiting requests": a read on the empty stream waits at
%% the keeper while the grant answers a write on the other fid of the same
%% stream, and the bytes then handed to the keeper answer the read, once.
a_write_is_answered_while_a_read_waits_test() ->
    {Grant, Keeper} = stream_grant(),
    Read = send(Grant, self(), {read, 2, 0, 16}),
    Write = send(Grant, self(), {write, 3, 0, <<"w">>}),
    ?assertEqual({ok, 1, 0}, reply_within(Write, 1000)),
    ?assertEqual(none, reply_within(Read, 0)),
    ok = erx_fs_stream_tree:hand(Keeper, <<"abc">>),
    ?assertEqual({ok, <<"abc">>}, reply_within(Read, 1000)),
    ?assertEqual(none, reply_within(Read, 100)),
    ?assertEqual([], erx_fs_stream_tree:held(Keeper)),
    stop(Grant).

%% A flush of a waiting read follows it to the keeper, which answers the read
%% eintr; then the flush is answered.
a_flush_of_a_waiting_read_reaches_its_keeper_test() ->
    {Grant, Keeper} = stream_grant(),
    Read = send(Grant, self(), {read, 2, 0, 16}),
    Flush = send(Grant, self(), {flush, Read}),
    ?assertEqual({error, eintr}, reply_within(Read, 1000)),
    ?assertEqual(ok, reply_within(Flush, 1000)),
    ok = erx_fs_stream_tree:hand(Keeper, <<"abc">>),
    ?assertEqual(none, reply_within(Read, 100)),
    ?assertEqual(ok, call(Grant, {clunk, 2})),
    stop(Grant).

%% The keeper's end answers the read it held eio, and the grant goes on.
a_keepers_end_answers_its_reads_eio_test() ->
    {Grant, Keeper} = stream_grant(),
    Read = send(Grant, self(), {read, 2, 0, 16}),
    ?assertEqual({ok, 1, 0}, call(Grant, {write, 3, 0, <<"w">>})),
    unlink(Keeper),
    exit(Keeper, kill),
    ?assertEqual({error, eio}, reply_within(Read, 1000)),
    ?assertEqual({ok, 1, 0}, call(Grant, {write, 3, 0, <<"w">>})),
    stop(Grant).

%% A grant on erx_fs_stream_tree whose keeper is Keeper, with fid 2, or each
%% of Fids, opened on the stream, as the core alone.
stream_core(Keeper) ->
    stream_core(Keeper, [2]).

stream_core(Keeper, Fids) ->
    {ok, Core} = erx_fs_grant:new(#{module => erx_fs_stream_tree, fs => Keeper, rights => rw,
                                    client => own}),
    {_, Attached} = core_frame(Core, {attach, 1, ?NOFID, <<"user">>, ?TREE, 0}),
    lists:foldl(fun(Fid, C) ->
                        {[{reply, _, {ok, [_]}}], C1} = core_frame(C, {walk, 1, Fid, [<<"s">>]}),
                        {[{reply, _, {ok, _, _}}], C2} = core_frame(C1, {lopen, Fid, ?O_RDONLY}),
                        C2
                end, Attached, Fids).

%% A keeper that is the grant itself, which would never answer, is eio at
%% once; the core built here is served by this process.
a_keeper_that_is_the_grant_is_eio_test() ->
    ?assertMatch({[{reply, _, {error, eio}}], _},
                 core_frame(stream_core(self()), {read, 2, 0, 16})).

%% A keeper's answer is held to read's shapes, and reaches the client eio when
%% it is none of them; a second answer to the same alias is refused.
a_keepers_answer_is_held_to_its_shapes_test() ->
    Keeper = spawn(fun() -> receive stop -> ok end end),
    Alias = make_ref(),
    {[{wait, Alias, Keeper, {read, 16}}], Core} =
        erx_fs_grant:handle_frame({erx_9p, Alias, self(), {read, 2, 0, 16}}, stream_core(Keeper)),
    Ref = make_ref(),
    Waiting = erx_fs_grant:waiting(Alias, Ref, Core),
    ?assertMatch(#{waiting := 1, in_flight := 1}, erx_fs_grant:info(Waiting)),
    {[{reply, Alias, {error, eio}}], Answered} = erx_fs_grant:answered(Ref, {ok, 1, 0}, Waiting),
    ?assertMatch(#{waiting := 0, in_flight := 0}, erx_fs_grant:info(Answered)),
    {[], Late} = erx_fs_grant:answered(Ref, {ok, <<"late">>}, Answered),
    ?assertMatch(#{refused := 2}, erx_fs_grant:info(Late)),
    Keeper ! stop.

%% A clunk of a fid whose read waits flushes the read first: the read is
%% answered eintr, then the clunk, and the tree's clunk runs when the keeper
%% holds nothing of the fid (the stream tree's clunk answers ebusy otherwise).
a_clunk_of_a_waiting_read_is_answered_after_its_eintr_test() ->
    {Grant, Keeper} = stream_grant(),
    Read = send(Grant, self(), {read, 2, 0, 16}),
    Clunk = send(Grant, self(), {clunk, 2}),
    ?assertEqual([{Read, {error, eintr}}, {Clunk, ok}], replies(2, 1000)),
    ?assertEqual([], erx_fs_stream_tree:held(Keeper)),
    ?assertEqual({error, ebadf}, call(Grant, {read, 2, 0, 16})),
    ?assertMatch({ok, [_]}, walk(Grant, 1, 2, [<<"s">>])),
    stop(Grant).

%% The next N replies this process receives, in the order they came, each
%% within Timeout milliseconds.
replies(0, _) ->
    [];
replies(N, Timeout) ->
    receive
        {erx_9p, Alias, Reply} -> [{Alias, Reply} | replies(N - 1, Timeout)]
    after Timeout ->
        []
    end.

%% Bounds, in the grant's core (design-files.md, "Bounds"): 64 waiting reads
%% fill the window, so a 65th request is emfile, yet a clunk of one of their
%% fids is admitted and answered after that read's eintr, and its number is
%% free once it is answered. A flush of each other read is then admitted and
%% answered after its read; a second flush of one read is dropped and counted,
%% and so is a request sent on the alias of a waiting flush, whose alias still
%% gets one answer, the flush's.
a_window_of_waiting_reads_is_still_flushed_and_clunked_test() ->
    Keeper = erx_fs_stream_tree:start_keeper(),
    Fids = lists:seq(2, 65),
    {Reads, Full} = lists:mapfoldl(fun(Fid, C) -> wait_read(Fid, Keeper, C) end,
                                   stream_core(Keeper, Fids), Fids),
    ?assertMatch(#{waiting := 64, in_flight := 64}, erx_fs_grant:info(Full)),
    ?assertMatch({[{reply, _, {error, emfile}}], _}, core_frame(Full, {getattr, 1, 0})),
    %% A flush of a request not in flight holds nothing and passes the bound.
    ?assertMatch({[{reply, _, ok}], _}, core_frame(Full, {flush, make_ref()})),
    [{Read, At} | Others] = Reads,
    Clunk = make_ref(),
    {[{flush, Keeper, At}], Clunking} =
        erx_fs_grant:handle_frame({erx_9p, Clunk, self(), {clunk, 2}}, Full),
    {[{reply, Read, {error, eintr}}, {reply, Clunk, ok}], Clunked} =
        erx_fs_grant:answered(At, {error, eintr}, Clunking),
    ?assertMatch({[{reply, _, {ok, []}}], _}, core_frame(Clunked, {walk, 1, 2, []})),
    {Flushes, Flushing} = lists:mapfoldl(fun({Alias, AtKeeper}, C) -> flush_read(Alias, AtKeeper, Keeper, C) end,
                                         Clunked, Others),
    [{Second, _} | _] = Others,
    [FirstFlush | _] = Flushes,
    %% The flushes wait beside the window, which holds the 63 reads.
    #{refused := Refused, in_flight := 63} = erx_fs_grant:info(Flushing),
    {[], Twice} = erx_fs_grant:handle_frame({erx_9p, make_ref(), self(), {flush, Second}}, Flushing),
    {[], Reused} = erx_fs_grant:handle_frame({erx_9p, FirstFlush, self(), {getattr, 1, 0}}, Twice),
    ?assertEqual(Refused + 2, maps:get(refused, erx_fs_grant:info(Reused))),
    Done = lists:foldl(fun({{Alias, AtKeeper}, Flush}, C) ->
                               {Answers, C1} = erx_fs_grant:answered(AtKeeper, {error, eintr}, C),
                               ?assertEqual([{reply, Alias, {error, eintr}}, {reply, Flush, ok}], Answers),
                               C1
                       end, Reused, lists:zip(Others, Flushes)),
    ?assertMatch(#{waiting := 0, in_flight := 0}, erx_fs_grant:info(Done)),
    unlink(Keeper),
    exit(Keeper, kill).

%% A read of Fid that waits at Keeper, handed over as the shell hands it: as
%% {Alias, KeeperAlias}, and the core that holds it.
wait_read(Fid, Keeper, Core) ->
    Alias = make_ref(),
    {[{wait, Alias, Keeper, {read, 16}}], Core1} =
        erx_fs_grant:handle_frame({erx_9p, Alias, self(), {read, Fid, 0, 16}}, Core),
    At = make_ref(),
    {{Alias, At}, erx_fs_grant:waiting(Alias, At, Core1)}.

%% A flush of the read Alias holds at Keeper under KeeperAlias, which the core
%% sends on to the keeper and answers later: as the flush's alias and the core.
flush_read(Alias, KeeperAlias, Keeper, Core) ->
    Flush = make_ref(),
    {[{flush, Keeper, KeeperAlias}], Core1} =
        erx_fs_grant:handle_frame({erx_9p, Flush, self(), {flush, Alias}}, Core),
    {Flush, Core1}.

%% A flush of a flush is answered ok at once, at any bound, and holds nothing
%% (design-files.md, "Flush" and "Bounds"): with the window full of waiting
%% reads, a flush of a read's waiting flush is answered before the flush it
%% names, the window and the live aliases stay as they were, and the read and
%% its flush are then answered in order.
a_flush_of_a_flush_is_answered_at_once_test() ->
    Keeper = erx_fs_stream_tree:start_keeper(),
    Fids = lists:seq(2, 65),
    {[{Read, At} | _], Full} = lists:mapfoldl(fun(Fid, C) -> wait_read(Fid, Keeper, C) end,
                                              stream_core(Keeper, Fids), Fids),
    {Flush, Flushing} = flush_read(Read, At, Keeper, Full),
    OfFlush = make_ref(),
    {Answered, After} = erx_fs_grant:handle_frame({erx_9p, OfFlush, self(), {flush, Flush}}, Flushing),
    ?assertEqual([{reply, OfFlush, ok}], Answered),
    Counts = fun(Core) -> maps:with([in_flight, aliases], erx_fs_grant:info(Core)) end,
    ?assertEqual(Counts(Flushing), Counts(After)),
    ?assertMatch({[{reply, Read, {error, eintr}}, {reply, Flush, ok}], _},
                 erx_fs_grant:answered(At, {error, eintr}, After)),
    unlink(Keeper),
    exit(Keeper, kill).

%% A remove unlinks when it is admitted, while its fid's read still waits, so
%% the requests after it see the order they were sent in; only its clunk waits
%% for the read, and the remove is answered after the read's eintr with what
%% its unlink answered (design-files.md, "Waiting requests", rule 5).
a_remove_unlinks_when_it_is_admitted_test() ->
    Keeper = erx_fs_stream_tree:start_keeper(),
    {{Read, At}, Waiting} = wait_read(2, Keeper, stream_core(Keeper)),
    Remove = make_ref(),
    {[{flush, Keeper, At}], Removing} =
        erx_fs_grant:handle_frame({erx_9p, Remove, self(), {remove, 2}}, Waiting),
    ?assertEqual([unlink], erx_fs_stream_tree:log(Keeper)),
    ?assertMatch({[{reply, Read, {error, eintr}}, {reply, Remove, ok}], _},
                 erx_fs_grant:answered(At, {error, eintr}, Removing)),
    ?assertEqual([unlink, {clunk, 0}], erx_fs_stream_tree:log(Keeper)),
    unlink(Keeper),
    exit(Keeper, kill).

%% A grant whose client has ended drains (rule 5): its keeper gets the flush
%% of the read that waits, the tree's clunk of the read's fid runs once, after
%% the read has settled, nothing is answered, and then the grant ends.
a_grant_whose_client_ended_drains_test() ->
    Keeper = erx_fs_stream_tree:start_keeper(),
    Holder = spawn(fun() -> receive go -> ok end end),
    {ok, Grant, _} = erx_fs:start_link(erx_fs_stream_tree, Keeper, rw, #{ends_with => Holder}),
    unlink(Grant),
    Watch = monitor(process, Grant),
    {ok, _} = attach(Grant, 1),
    {ok, _} = walk(Grant, 1, 2, [<<"s">>]),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    Read = send(Grant, self(), {read, 2, 0, 16}),
    %% The grant handed the read over before it answers the next request.
    {ok, []} = walk(Grant, 1, 3, []),
    ?assertMatch([_], erx_fs_stream_tree:held(Keeper)),
    Holder ! go,
    receive
        {'DOWN', Watch, process, Grant, Reason} -> ?assertEqual({shutdown, connection_ended}, Reason)
    after 4000 ->
        stop(Grant),
        ?assert(false)
    end,
    ?assertEqual([flushed, {clunk, 0}], erx_fs_stream_tree:log(Keeper)),
    ?assertEqual(none, reply_within(Read, 0)),
    unlink(Keeper),
    exit(Keeper, kill).
