%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the `system` tree's backend, erx_storage_system, through erx_fs grants
%% over a RAM window (erx_erofs_tests:window/1) on the partitions
%% test/host/erx_storage_system_test.rb writes in ERX_SYSTEM_CASES, each opened with the
%% record words written beside it.
-module(erx_storage_system_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([export/3]).

-define(NOFID, 16#ffffffff).
-define(SYSTEM, 4).
-define(TREE, <<"system">>).
-define(O_RDONLY, 0).
-define(O_WRONLY, 1).
-define(O_TRUNC, 8#1000).
%% The one line a mount that serves its tree hands its log.
-define(SERVED, <<"serving the system tree">>).

%% Fixtures --------------------------------------------------------------

%% The partition Name's bytes and its boot records, the system_image record alone.
partition(Name) ->
    Dir = os:getenv("ERX_SYSTEM_CASES"),
    {ok, Cases} = file:consult(filename:join(Dir, "system.terms")),
    {Name, Words} = lists:keyfind(Name, 1, Cases),
    {ok, Bytes} = file:read_file(filename:join(Dir, Name ++ ".img")),
    {Bytes, [Words]}.

%% The tree mounted on partition Name with the layout its records name, through mount/3,
%% which the module exports to TEST alone, its log lines sent to the caller; lines an
%% earlier mount of the same process sent and no case read are dropped first.
open(Name) ->
    {Bytes, Records} = partition(Name),
    open(Bytes, Records).

open(Bytes, Records) ->
    _ = logged(),
    Self = self(),
    erx_storage_system:mount(erx_erofs_tests:window(Bytes), erx_device_record:system_image(Records),
                             fun(Line) -> Self ! {log, Line} end).

%% An attached grant with Rights on Tree, fid 1 at its root.
grant(Tree, Rights) ->
    {ok, Grant, _} = erx_fs:start_link(erx_storage_system, Tree, Rights),
    unlink(Grant),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?TREE, 0}),
    Grant.

call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive
        {erx_9p, Alias, Reply} -> Reply
    after 5000 ->
        erlang:error({no_reply, Request})
    end.

%% The whole file at fid Fid, opened for reading, read in pieces of Count bytes.
read_all(Grant, Fid, Count) -> read_all(Grant, Fid, Count, 0, []).

read_all(Grant, Fid, Count, Offset, Read) ->
    case call(Grant, {read, Fid, Offset, Count}) of
        {ok, <<>>} -> {ok, iolist_to_binary(lists:reverse(Read))};
        {ok, Bytes} -> read_all(Grant, Fid, Count, Offset + byte_size(Bytes), [Bytes | Read]);
        {error, _} = Error -> Error
    end.

%% The names a directory fid lists, opened for reading.
names(Grant, Fid) -> names(Grant, Fid, 0, []).

names(Grant, Fid, Offset, Names) ->
    case call(Grant, {readdir, Fid, Offset, 4096}) of
        {ok, []} -> {ok, lists:sort(Names)};
        {ok, Entries} ->
            {_, Next, _, _} = lists:last(Entries),
            names(Grant, Fid, Next, Names ++ [Name || {_Qid, _Offset, _Type, Name} <- Entries]);
        {error, _} = Error -> Error
    end.

%% The names the partitions' apps/ holds, sorted, as the host test wrote them.
listed() ->
    {ok, Cases} = file:consult(filename:join(os:getenv("ERX_SYSTEM_CASES"), "system.terms")),
    {names, Names} = lists:keyfind(names, 1, Cases),
    Names.

logged() ->
    receive {log, Line} -> [Line | logged()]
    after 0 -> []
    end.

%% A good partition ----------------------------------------------------------

%% The tree roots at apps/: it lists the packages, reads each whole and in pieces across
%% its blocks, and reaches nothing outside apps/: the grammar refuses a walk naming `.`
%% or `..` before the tree sees it.
good_partition_serves_apps_test() ->
    Grant = grant(open("good"), rx),
    {ok, []} = call(Grant, {walk, 1, 9, []}),
    {ok, _, _} = call(Grant, {lopen, 9, ?O_RDONLY}),
    ?assertEqual({ok, listed()}, names(Grant, 9)),
    {ok, [{0, 0, _}]} = call(Grant, {walk, 1, 2, [<<"big.app">>]}),
    ?assertMatch({ok, #{size := 20000, mode := Mode}} when Mode band ?ERX_P9_S_IFMT =:= ?ERX_P9_S_IFREG,
                 call(Grant, {getattr, 2, 16#7ff})),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    ?assertEqual({ok, erx_erofs_tests:contents(20000, 3)}, read_all(Grant, 2, 4096)),
    ?assertEqual({ok, erx_erofs_tests:contents(20000, 3)}, read_all(Grant, 2, 3000)),
    ?assertEqual({ok, binary:part(erx_erofs_tests:contents(20000, 3), 4090, 20)},
                 call(Grant, {read, 2, 4090, 20})),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"small.app">>]}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_RDONLY}),
    ?assertEqual({ok, erx_erofs_tests:contents(100, 1)}, read_all(Grant, 3, 4096)),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"README">>]})),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"apps">>]})),
    ?assertEqual({error, einval}, call(Grant, {walk, 1, 4, [<<"..">>]})),
    ?assertEqual({error, einval}, call(Grant, {walk, 1, 4, [<<".">>]})),
    %% Neither refused walk took fid 4.
    {ok, []} = call(Grant, {walk, 1, 4, []}),
    {ok, _, _} = call(Grant, {lopen, 4, ?O_RDONLY}),
    ?assertEqual({ok, listed()}, names(Grant, 4)),
    ?assertMatch({ok, #{type := ?ERX_P9_MAGIC_EROFS}}, call(Grant, {statfs, 1})),
    ?assertEqual([?SERVED], logged()).

%% The packer's partition serves the image's packages, written at apps/NAME.app of the
%% system partition, and nothing of the release beside them.
packed_partition_serves_the_image_packages_test() ->
    Grant = grant(open("packed"), ro),
    {ok, []} = call(Grant, {walk, 1, 9, []}),
    {ok, _, _} = call(Grant, {lopen, 9, ?O_RDONLY}),
    ?assertEqual({ok, [<<"big.app">>, <<"small.app">>]}, names(Grant, 9)),
    {ok, [_]} = call(Grant, {walk, 1, 2, [<<"big.app">>]}),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    ?assertEqual({ok, erx_erofs_tests:contents(20000, 3)}, read_all(Grant, 2, 4096)),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"small.app">>]}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_RDONLY}),
    ?assertEqual({ok, erx_erofs_tests:contents(100, 1)}, read_all(Grant, 3, 4096)),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"system">>]})),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"README">>]})),
    ?assertEqual([?SERVED], logged()).

%% The packer's partition of an image with no package still holds apps/, so the
%% tree mounts and serves it empty, logging only that it serves it.
packed_partition_without_packages_serves_an_empty_tree_test() ->
    Grant = grant(open("packed-empty"), ro),
    {ok, []} = call(Grant, {walk, 1, 9, []}),
    {ok, _, _} = call(Grant, {lopen, 9, ?O_RDONLY}),
    ?assertEqual({ok, []}, names(Grant, 9)),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 4, [<<"system">>]})),
    ?assertEqual([?SERVED], logged()).

%% Writing -------------------------------------------------------------------

%% Every grant of the tree refuses each writing operation with erofs, an rw grant too,
%% since the tree has no writing callback.
writes_through_a_grant_are_refused_test_() ->
    Tree = open("good"),
    [{atom_to_list(Rights), fun() -> refuses_writes(Tree, Rights) end} || Rights <- [ro, rx, rw]].

refuses_writes(Tree, Rights) ->
    Grant = grant(Tree, Rights),
    {ok, [_]} = call(Grant, {walk, 1, 2, [<<"big.app">>]}),
    ?assertEqual({error, erofs}, call(Grant, {lopen, 2, ?O_WRONLY})),
    ?assertEqual({error, erofs}, call(Grant, {lopen, 2, ?O_RDONLY bor ?O_TRUNC})),
    ?assertEqual({error, erofs}, call(Grant, {lcreate, 1, <<"new.app">>, 0, 8#644, 0})),
    ?assertEqual({error, erofs}, call(Grant, {mkdir, 1, <<"d">>, 8#755, 0})),
    ?assertEqual({error, erofs}, call(Grant, {unlinkat, 1, <<"big.app">>, 0})),
    ?assertEqual({error, erofs}, call(Grant, {renameat, 1, <<"big.app">>, 1, <<"b.app">>})),
    ?assertEqual({error, erofs}, call(Grant, {setattr, 2, maps:from_keys([valid, mode, uid, gid, size, atime_sec,
                                                                       atime_nsec, mtime_sec, mtime_nsec], 0)})),
    {ok, _, _} = call(Grant, {lopen, 2, ?O_RDONLY}),
    ?assertEqual({error, erofs}, call(Grant, {write, 2, 0, <<"x">>})),
    ?assertEqual({ok, erx_erofs_tests:contents(20000, 3)}, read_all(Grant, 2, 4096)).

%% No tree -------------------------------------------------------------------

%% A record that is absent or refused opens no image: every request answers eio, and the
%% refusal is logged.
refused_record_serves_no_tree_test_() ->
    {Bytes, _} = partition("good"),
    [fun() -> serves_nothing(open(Bytes, Records)) end
     || Records <- [[], [["system_image", "1"]]]].

serves_nothing(Tree) ->
    ?assertMatch([<<"no system tree: ", _/binary>>], logged()),
    Grant = grant(Tree, rx),
    ?assertEqual({error, eio}, call(Grant, {walk, 1, 2, [<<"big.app">>]})),
    ?assertEqual({error, eio}, call(Grant, {getattr, 1, 16#7ff})),
    ?assertEqual({error, eio}, call(Grant, {lopen, 1, ?O_RDONLY})).

%% A flipped bit of the apps/ directory's entries, which turns big.app into big.apq and
%% keeps their order, answers eio before the reader parses the block: neither a walk of
%% either name nor the listing answers anything else.
flipped_directory_bit_answers_eio_test() ->
    Grant = grant(open("directory"), rx),
    ?assertEqual({error, eio}, call(Grant, {walk, 1, 2, [<<"big.app">>]})),
    ?assertEqual({error, eio}, call(Grant, {walk, 1, 2, [<<"big.apq">>]})),
    ?assertNotMatch({ok, _, _}, call(Grant, {lopen, 1, ?O_RDONLY})).

%% A changed partition whose tree was rebuilt to match it, opened with the record of the
%% original: every request answers eio, so none of the changed bytes is served. With the
%% record of its own tree the same partition serves them, so the image itself is sound.
changed_partition_under_the_original_root_answers_eio_test() ->
    Grant = grant(open("changed"), rx),
    ?assertEqual({error, eio}, call(Grant, {walk, 1, 2, [<<"big.app">>]})),
    ?assertEqual({error, eio}, call(Grant, {walk, 1, 2, [<<"small.app">>]})),
    ?assertEqual({error, eio}, call(Grant, {lopen, 1, ?O_RDONLY})),
    ?assertNotEqual([], logged() -- [?SERVED]),
    Own = grant(open("changed-own"), rx),
    {ok, [_]} = call(Own, {walk, 1, 2, [<<"big.app">>]}),
    {ok, _, _} = call(Own, {lopen, 2, ?O_RDONLY}),
    ?assertEqual({ok, erx_erofs_tests:contents(20000, 4)}, read_all(Own, 2, 4096)).

%% The mint ------------------------------------------------------------------

%% The service's mint over the mounted tree names itself the mint of `system`.
the_mint_names_itself_system_s_mint_test() ->
    {ok, Mint} = erx_fs_mint:start_link(system, erx_storage_system, fun() -> open("good") end),
    unlink(Mint),
    ?assertMatch(#{system := Mint}, persistent_term:get({erx, provides})),
    exit(Mint, kill).

%% The mint has started and named itself before it mounts the tree, and mounts it in its
%% own process, so the supervisor that starts it, and with it the domain's ready report,
%% waits for no mount. Here the mount waits until it is told to go: started by a process
%% of its own, which stands in for the supervisor, the start must answer meanwhile.
the_mint_starts_before_it_mounts_its_tree_test() ->
    Self = self(),
    Mount = fun() -> Self ! {mounting, self()}, receive go -> open("good") end end,
    Starter = spawn(fun() -> Self ! {started, erx_fs_mint:start_link(system, erx_storage_system, Mount)},
                             receive after infinity -> ok end end),
    Started = receive {started, Answer} -> Answer after 2000 -> no_answer end,
    ?assertMatch({ok, _}, Started),
    {ok, Mint} = Started,
    ?assertMatch(#{system := Mint}, persistent_term:get({erx, provides})),
    ?assertEqual(Mint, receive {mounting, Pid} -> Pid after 2000 -> no_mount end),
    Mint ! go,
    exit(Starter, kill).

%% A grant the mint makes for the system domain, as it makes one for each row, with the
%% row's rights, ro or rx, reads a file of the tree and answers each write erofs before any
%% callback; over a tree mounted from no record every walk answers eio.
minted_grants_read_and_refuse_writes_test_() ->
    Tree = open("good"),
    [{atom_to_list(Rights), fun() -> minted_reads(Tree, Rights) end} || Rights <- [ro, rx]].

minted_reads(Tree, Rights) ->
    Small = erx_erofs_tests:contents(100, 1),
    ?assertMatch([{ok, _, _}, {ok, _}, {ok, [_]}, {error, erofs}, {ok, _, _}, {ok, Small},
                  {error, erofs}, {error, erofs}],
                 exchange(minted(Tree, Rights),
                          [{version, 65560, <<"9P2000.L">>}, {attach, 1, ?NOFID, <<"user">>, ?TREE, 0},
                           {walk, 1, 2, [<<"small.app">>]}, {lopen, 2, ?O_WRONLY}, {lopen, 2, ?O_RDONLY},
                           {read, 2, 0, 4096}, {write, 2, 0, <<"x">>},
                           {lcreate, 1, <<"new.app">>, 0, 8#644, 0}])).

minted_grants_of_no_tree_answer_eio_test() ->
    {Bytes, _} = partition("good"),
    Grant = minted(open(Bytes, []), ro),
    ?assertMatch([<<"no system tree: ", _/binary>>], logged()),
    ?assertMatch([{ok, _, _}, {ok, _}, {error, eio}, {error, eio}],
                 exchange(Grant, [{version, 65560, <<"9P2000.L">>}, {attach, 1, ?NOFID, <<"user">>, ?TREE, 0},
                                  {walk, 1, 2, [<<"small.app">>]}, {lopen, 1, ?O_RDONLY}])).

%% The system domain's grant of Tree with Rights, as the mint makes it: under the mint's
%% grants supervisor, bound to the system domain, exported through export/3.
minted(Tree, Rights) ->
    {ok, Grants} = erx_fs_grants:start_link(erx_storage_system, Tree),
    unlink(Grants),
    {ok, Grant, _Tree} = erx_fs_mint:grant(Grants, ?SYSTEM, ?SYSTEM, <<"system">>, #{rights => Rights}, ?MODULE),
    Grant.

%% The stand-in of the export table, which exports every grant.
-doc false.
export(_Name, _Rights, _Peer) -> ok.

%% The answers to Requests, sent in order in the system domain's envelope while the grant
%% is suspended. The grant monitors the frames' owner, a name of the system domain's
%% node, which stock is not connected to, so the monitor's 'DOWN' would end the fids:
%% sent first, the frames reach the grant before it. Each request has an alias of that
%% node of its own, which stock cannot reach, so its answer, which may come after a later
%% request's when a file process gives it, is read from a trace of the grant's calls of
%% erlang:send/2, as erx_fs_mint_tests reads them.
exchange(Grant, Requests) ->
    Owner = binary_to_term(<<131, 88, 119, 9, "d@erxos11", 1:32, 0:32, ?SYSTEM:32>>),
    Aliased = [{binary_to_term(<<131, 90, 3:16, 119, 9, "d@erxos11", ?SYSTEM:32, Id:32, 2:32, 3:32>>), Request}
               || {Id, Request} <- lists:enumerate(Requests)],
    _ = erlang:trace_pattern({erlang, send, 2}, true, []),
    1 = erlang:trace(Grant, true, [call]),
    true = erlang:suspend_process(Grant),
    _ = [Grant ! {erx_origin, ?SYSTEM, {erx_9p, Alias, Owner, Request}} || {Alias, Request} <- Aliased],
    true = erlang:resume_process(Grant),
    [receive
         {trace, Grant, call, {erlang, send, [Alias, {erx_9p, Alias, Reply}]}} -> Reply
     after 5000 ->
         erlang:error({no_reply, Request})
     end || {Alias, Request} <- Aliased].
