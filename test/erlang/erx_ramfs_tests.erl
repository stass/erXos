%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs_tests).
-moduledoc """
EUnit tests of /tmp's grant over the real tree (docs/design-tmp.md, Verification): the
"Fids and nodes" cases, a fid that keeps a removed file and never reaches a file made after
it, a stat that a rename over its name falls inside, a stopped walk, ".." from a removed
directory, a removed file freed by its last fid's clunk and a file two grants hold, and
the "Grammar on the local route" case, names and link texts at and past their limits sent
to the grant as local messages and refused before any callback, and statfs back at its
start after every way a file gives up its space. The tree is `erx_ramfs`
under `erx_fs`, as `erx_ramfs_sup` starts them. test/host/erx_ramfs_test.rb runs these on
stock OTP and seeds a fault for each.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(NOFID, 16#ffffffff).
-define(O_RDWR, 2).
-define(CAP, 1000000).
%% How long a case waits for a reply or for a condition, in milliseconds. Each wait is
%% short of the EUnit timeout that test/host/erx_ramfs_test.rb gives a case, and the waits
%% along any one case's path add up to less, so a case that never sees what it waits for
%% fails with its reason and is not timed out.
-define(REPLY_BOUND, 30000).
-define(CONDITION_BOUND, 10000).

%% Fixtures --------------------------------------------------------------

%% A tree and its grant, registered under a name of their own; the file version
%% counter is the one the tests share. The tree is kept in the test process's
%% dictionary under its grant, so that stop/1 ends both.
start() ->
    ok = erx_fs_version:init(),
    Name = list_to_atom("erx_ramfs_test_" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Tree} = erx_ramfs:start_link(?CAP, Name),
    {ok, Grant} = erx_fs:start_link(erx_ramfs, Name, rw),
    unlink(Tree),
    unlink(Grant),
    put({tree, Grant}, Tree),
    put({name, Grant}, Name),
    {ok, _} = attach(Grant, 1),
    Grant.

stop(Grant) ->
    exit(Grant, kill),
    exit(erase({tree, Grant}), kill).

%% A second grant on the tree of Grant, attached at fid 1.
second_grant(Grant) ->
    {ok, Second} = erx_fs:start_link(erx_ramfs, get({name, Grant}), rw),
    unlink(Second),
    {ok, _} = attach(Second, 1),
    Second.

%% A grant that ends while the request is out fails the case at once with the request, so
%% that a grant that crashed on it is a failed case and not a timed out one. The reply
%% bound is generous, as the host may be starved of CPU for seconds; only a grant that is
%% alive and silent reaches it.
call(Grant, Request) ->
    call_as(Grant, self(), Request).

call_as(Grant, Sender, Request) ->
    Alias = alias([reply]),
    Monitor = monitor(process, Grant),
    Grant ! {erx_9p, Alias, Sender, Request},
    receive
        {erx_9p, Alias, Reply} ->
            demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Grant, Reason} ->
            erlang:error({grant_ended, Reason, Request})
    after ?REPLY_BOUND ->
        erlang:error({no_reply, Request})
    end.

attach(Grant, Fid) ->
    call(Grant, {attach, Fid, ?NOFID, <<"user">>, <<"tmp">>, 0}).

%% A file made and closed under Name in the directory Fid names; Fid is left alone.
make_file(Grant, Fid, Name, Spare) ->
    {ok, []} = call(Grant, {walk, Fid, Spare, []}),
    {ok, _, _} = call(Grant, {lcreate, Spare, Name, ?O_RDWR, 8#644, 0}),
    ok = call(Grant, {clunk, Spare}).

%% A closed file under Name in the grant's root holding Data.
write_file(Grant, Name, Data, Spare) ->
    {ok, []} = call(Grant, {walk, 1, Spare, []}),
    {ok, _, _} = call(Grant, {lcreate, Spare, Name, ?O_RDWR, 8#644, 0}),
    Size = byte_size(Data),
    {ok, Size, _} = call(Grant, {write, Spare, 0, Data}),
    ok = call(Grant, {clunk, Spare}).

%% A closed file of 50000 bytes, enough to show in statfs's free blocks.
make_data_file(Grant, Name, Spare) ->
    {ok, []} = call(Grant, {walk, 1, Spare, []}),
    {ok, _, _} = call(Grant, {lcreate, Spare, Name, ?O_RDWR, 8#644, 0}),
    {ok, 50000, _} = call(Grant, {write, Spare, 0, binary:copy(<<1>>, 50000)}),
    ok = call(Grant, {clunk, Spare}).

%% Fids and nodes ----------------------------------------------------------

%% A fid walked to a file, the file removed, then a getattr and a lopen through the
%% fid: the walk keeps the file, so getattr finds it with no links and lopen opens it,
%% as the open that walk began would have. Once the fid is clunked the file is gone,
%% and a file made after it must not take its inode number.
a_fid_never_reaches_a_file_made_after_its_own_test() ->
    Grant = start(),
    make_file(Grant, 1, <<"f">>, 2),
    {ok, [{_, _, Old}]} = call(Grant, {walk, 1, 3, [<<"f">>]}),
    ok = call(Grant, {unlinkat, 1, <<"f">>, 0}),
    ?assertMatch({ok, #{nlink := 0, qid := {_, _, Old}}}, call(Grant, {getattr, 3, 16#7ff})),
    ?assertMatch({ok, {_, _, Old}, _}, call(Grant, {lopen, 3, 0})),
    ok = call(Grant, {clunk, 3}),
    make_file(Grant, 1, <<"g">>, 4),
    {ok, [{_, _, New}]} = call(Grant, {walk, 1, 5, [<<"g">>]}),
    ?assertNotEqual(Old, New),
    stop(Grant).

%% erx_file_remote's stat of a path, sent by one process: attach, walk, getattr, clunk.
%% A rename over the path's last name, sent by another, reaches the grant between the
%% walk and the getattr, as the grant's mailbox can order them. On Unix a rename over an
%% existing name is atomic, so a stat of that name finds the old file or the new one and
%% never answers enoent.
a_stat_finds_a_name_renamed_over_between_its_walk_and_getattr_test() ->
    Grant = start(),
    make_file(Grant, 1, <<"a">>, 2),
    make_file(Grant, 1, <<"b">>, 3),
    Stat = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = call_as(Grant, Stat, {attach, 10, ?NOFID, <<"user">>, <<"tmp">>, 0}),
    {ok, [_]} = call_as(Grant, Stat, {walk, 10, 11, [<<"b">>]}),
    ok = call(Grant, {renameat, 1, <<"a">>, 1, <<"b">>}),
    ?assertMatch({ok, _}, call_as(Grant, Stat, {getattr, 11, 16#7ff})),
    ok = call_as(Grant, Stat, {clunk, 11}),
    ok = call_as(Grant, Stat, {clunk, 10}),
    Stat ! stop,
    stop(Grant).

%% erx_file_remote's open of a path to read, sent by one process: attach, walk, lopen,
%% then a read. A rename over the path's last name, sent by another, reaches the grant
%% between the walk and the lopen, as the grant's mailbox can order them. A rename
%% replaces its target atomically, so the open finds the old file, as an open sent
%% before the rename would, and reads its bytes; it never answers enoent.
an_open_finds_a_name_renamed_over_between_its_walk_and_lopen_test() ->
    Grant = start(),
    write_file(Grant, <<"a">>, <<"new">>, 2),
    write_file(Grant, <<"b">>, <<"old">>, 3),
    Open = spawn(fun() -> receive stop -> ok end end),
    {ok, _} = call_as(Grant, Open, {attach, 10, ?NOFID, <<"user">>, <<"tmp">>, 0}),
    {ok, [_]} = call_as(Grant, Open, {walk, 10, 11, [<<"b">>]}),
    ok = call(Grant, {renameat, 1, <<"a">>, 1, <<"b">>}),
    ?assertMatch({ok, _, _}, call_as(Grant, Open, {lopen, 11, 0})),
    ?assertEqual({ok, <<"old">>}, call_as(Grant, Open, {read, 11, 0, 10})),
    ok = call_as(Grant, Open, {clunk, 11}),
    ok = call_as(Grant, Open, {clunk, 10}),
    Open ! stop,
    stop(Grant).

%% A walk that stops after its first name makes no fid, so it keeps nothing: the
%% file it passed is freed with its name.
a_stopped_walk_keeps_nothing_test() ->
    Grant = start(),
    Free = free(Grant),
    make_data_file(Grant, <<"f">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"f">>, <<"x">>]}),
    ?assertEqual({error, ebadf}, call(Grant, {getattr, 3, 16#7ff})),
    ok = call(Grant, {unlinkat, 1, <<"f">>, 0}),
    ?assertEqual(Free, free(Grant)),
    stop(Grant).

%% A fid at a directory that is removed: the directory finds no name, and ".." through
%% the fid's chain returns to the parent, after which nothing keeps the directory.
dotdot_after_rmdir_lets_the_directory_go_test() ->
    Grant = start(),
    Free = free(Grant),
    {ok, _} = call(Grant, {mkdir, 1, <<"d">>, 8#755, 0}),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"d">>]}),
    ok = call(Grant, {unlinkat, 1, <<"d">>, 16#200}),
    ?assertMatch({ok, #{nlink := 0}}, call(Grant, {getattr, 3, 16#7ff})),
    ?assertEqual({error, enoent}, call(Grant, {walk, 3, 4, [<<"x">>]})),
    ?assert(free(Grant) < Free),
    {ok, [{16#80, _, _}]} = call(Grant, {walk, 3, 3, [<<"..">>]}),
    ?assertMatch({ok, #{nlink := 2}}, call(Grant, {getattr, 3, 16#7ff})),
    ?assertEqual(Free, free(Grant)),
    stop(Grant).

%% A removed file stays while any fid names it, and its last clunk frees it.
clunking_every_fid_frees_a_nameless_file_test() ->
    Grant = start(),
    Free = free(Grant),
    make_data_file(Grant, <<"f">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"f">>]}),
    {ok, []} = call(Grant, {walk, 3, 4, []}),
    ok = call(Grant, {unlinkat, 1, <<"f">>, 0}),
    ok = call(Grant, {clunk, 3}),
    ?assert(free(Grant) < Free),
    ?assertMatch({ok, #{nlink := 0, size := 50000}}, call(Grant, {getattr, 4, 16#7ff})),
    ok = call(Grant, {clunk, 4}),
    ?assertEqual(Free, free(Grant)),
    stop(Grant).

%% Two grants that walked to one file each keep it; it is freed only when both have
%% let go, the second by ending.
a_file_two_grants_hold_needs_both_to_let_go_test() ->
    Grant = start(),
    Second = second_grant(Grant),
    Free = free(Grant),
    make_data_file(Grant, <<"f">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"f">>]}),
    {ok, [_]} = call(Second, {walk, 1, 3, [<<"f">>]}),
    ok = call(Grant, {unlinkat, 1, <<"f">>, 0}),
    ok = call(Grant, {clunk, 3}),
    ?assert(free(Grant) < Free),
    ?assertMatch({ok, #{nlink := 0}}, call(Second, {getattr, 3, 16#7ff})),
    kill_and_wait(Second),
    ?assertEqual(ok, wait_free(Grant, Free)),
    stop(Grant).

%% Grammar on the local route ----------------------------------------------

-define(BAD_NAMES, [<<"a", 0, "b">>, <<"a/b">>, <<".">>, <<"..">>, <<>>, <<16#ff, 16#fe>>,
                    binary:copy(<<"n">>, 256)]).
-define(GOOD_NAMES, [<<"x">>, binary:copy(<<"n">>, 255), <<"..x">>, <<"a.b">>]).

%% Every request that carries a name, with Name in it.
named_requests(Name) ->
    [{lcreate, 2, Name, ?O_RDWR, 8#644, 0},
     {mkdir, 2, Name, 8#755, 0},
     {symlink, 2, Name, <<"t">>, 0},
     {link, 2, 3, Name},
     {unlinkat, 2, Name, 0},
     {renameat, 2, Name, 2, <<"to">>},
     {renameat, 2, <<"from">>, 2, Name}].

%% Whether the callbacks that take a name were called while Fun ran.
callbacks_called_during(Fun) ->
    Self = self(),
    Pattern = [{erx_ramfs, walk, 3}, {erx_ramfs, make, 4}, {erx_ramfs, unlink, 4}, {erx_ramfs, rename, 5}],
    [1 = erlang:trace_pattern(P, true, [local]) || P <- Pattern],
    _ = erlang:trace(all, true, [call, {tracer, Self}]),
    try Fun() of
        Result -> {Result, drain_calls()}
    after
        _ = erlang:trace(all, false, [call]),
        [erlang:trace_pattern(P, false, [local]) || P <- Pattern]
    end.

%% The calls traced so far. erlang:trace_delivered/1 answers once every trace message
%% generated before the call has reached this process, so no wait on the clock decides what
%% was seen. That covers each callback, as the grant makes them before it sends the reply
%% that Fun waited for.
drain_calls() ->
    drain_calls(erlang:trace_delivered(all), []).

drain_calls(Ref, Seen) ->
    receive
        {trace, _, call, {erx_ramfs, Function, _}} -> drain_calls(Ref, [Function | Seen]);
        {trace_delivered, all, Ref} -> lists:reverse(Seen)
    end.

names_that_break_the_grammar_are_refused_before_a_callback_test() ->
    Grant = start(),
    {ok, []} = call(Grant, {walk, 1, 2, []}),
    {ok, []} = call(Grant, {walk, 1, 3, []}),
    {Replies, Called} =
        callbacks_called_during(fun() ->
                                        [{Name, call(Grant, Request)}
                                         || Name <- ?BAD_NAMES, Request <- named_requests(Name)]
                                end),
    %% A grant that answered by crashing is not a grant that refused.
    ?assert(is_process_alive(Grant)),
    ?assertEqual([], [Reply || {_, Reply} <- Replies, element(1, Reply) =/= error]),
    ?assertEqual([], Called),
    %% Nothing was made.
    {ok, []} = call(Grant, {walk, 1, 4, []}),
    ?assertEqual({error, enoent}, call(Grant, {walk, 1, 5, [<<"x">>]})),
    stop(Grant).

names_at_the_limit_are_made_test() ->
    Grant = start(),
    [begin
         {ok, []} = call(Grant, {walk, 1, 2, []}),
         ?assertMatch({ok, _, _}, call(Grant, {lcreate, 2, Name, ?O_RDWR, 8#644, 0})),
         ok = call(Grant, {clunk, 2})
     end || Name <- ?GOOD_NAMES],
    stop(Grant).

link_texts_are_held_to_their_limit_test() ->
    Grant = start(),
    {ok, []} = call(Grant, {walk, 1, 2, []}),
    {Replies, Called} =
        callbacks_called_during(fun() ->
                                        [call(Grant, {symlink, 2, <<"s", (integer_to_binary(Size))/binary>>,
                                                      binary:copy(<<"t">>, Size), 0})
                                         || Size <- [4095, 4096, 4097]]
                                end),
    ?assertEqual([ok, error, error], [element(1, R) || R <- Replies]),
    %% Only the 4,095-byte text reached the tree.
    ?assertEqual([make], Called),
    stop(Grant).

%% Open after unlink ----------------------------------------------------------

%% The free blocks, then the free nodes, which show a node's own charge.
free(Grant) ->
    {ok, #{bfree := Blocks, ffree := Nodes}} = call(Grant, {statfs, 1}),
    {Blocks, Nodes}.

%% Ends Pid and returns once it is gone. The grants that monitored it learn of it a
%% moment later, in an order nothing fixes, which wait_free/2 waits out.
kill_and_wait(Pid) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Monitor, process, Pid, _} -> ok
    after ?CONDITION_BOUND ->
        erlang:error({not_killed, Pid})
    end.

%% Polls until statfs shows Free again and returns ok, or returns timeout after
%% ?CONDITION_BOUND milliseconds.
wait_free(Grant, Free) ->
    wait_free(Grant, Free, erlang:monotonic_time(millisecond) + ?CONDITION_BOUND).

wait_free(Grant, Free, Deadline) ->
    case free(Grant) of
        Free ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(20), wait_free(Grant, Free, Deadline);
                false -> timeout
            end
    end.

%% A process opens a file, removes it and writes it, then ends: the grant clunks its
%% fids, so what the file held is given back.
a_dead_owners_open_file_gives_back_what_it_held_test() ->
    Grant = start(),
    Free = free(Grant),
    Owner = spawn(fun() -> receive never -> ok end end),
    As = fun(Request) -> call_as(Grant, Owner, Request) end,
    {ok, _} = As({attach, 10, ?NOFID, <<"user">>, <<"tmp">>, 0}),
    {ok, []} = As({walk, 10, 11, []}),
    {ok, _, _} = As({lcreate, 11, <<"f">>, ?O_RDWR, 8#644, 0}),
    ok = As({unlinkat, 10, <<"f">>, 0}),
    {ok, 50000, _} = As({write, 11, 0, binary:copy(<<1>>, 50000)}),
    ?assert(free(Grant) < Free),
    kill_and_wait(Owner),
    ?assertEqual(ok, wait_free(Grant, Free)),
    stop(Grant).

%% Space comes back ----------------------------------------------------------

%% setattr's attributes with only the size set.
size_attr(Size) ->
    #{valid => ?ERX_P9_SETATTR_VALID_SIZE, mode => 0, uid => 0, gid => 0, size => Size,
      atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0}.

%% Every way a file's bytes are given back, one after another on one tree: a
%% file walked, clunked and removed; one truncated through an unopened fid,
%% through an open one and by an open with O_TRUNC, each truncation giving its
%% chunks back at once; one renamed over; and one open in a process that is
%% killed. statfs's free blocks and nodes come back to their start each time
%% the last name goes. A clunk of an open fid reaches the tree from the file's
%% own process, so the counts are awaited rather than read once.
every_way_of_letting_go_gives_the_space_back_test() ->
    Grant = start(),
    Free = free(Grant),
    Data = binary:copy(<<7>>, 50000),
    %% Written, walked, clunked and removed.
    make_data_file(Grant, <<"a">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"a">>]}),
    ok = call(Grant, {clunk, 3}),
    ok = call(Grant, {unlinkat, 1, <<"a">>, 0}),
    ?assertEqual(ok, wait_free(Grant, Free, 100)),
    %% An empty file's own cost, against which each truncation is measured.
    make_file(Grant, 1, <<"b">>, 2),
    Empty = settled_free(Grant),
    ok = call(Grant, {unlinkat, 1, <<"b">>, 0}),
    %% Truncated to 0 through an unopened fid.
    make_data_file(Grant, <<"b">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"b">>]}),
    ok = call(Grant, {setattr, 3, size_attr(0)}),
    ?assertEqual(ok, wait_free(Grant, Empty, 100)),
    ok = call(Grant, {clunk, 3}),
    %% Written and truncated to 0 through an open fid.
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"b">>]}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_RDWR}),
    {ok, 50000, _} = call(Grant, {write, 3, 0, Data}),
    ok = call(Grant, {setattr, 3, size_attr(0)}),
    ok = call(Grant, {clunk, 3}),
    ?assertEqual(ok, wait_free(Grant, Empty, 100)),
    %% Written, then opened with O_TRUNC.
    make_data_file(Grant, <<"b">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"b">>]}),
    {ok, _, _} = call(Grant, {lopen, 3, ?O_RDWR bor ?ERX_P9_O_TRUNC}),
    ok = call(Grant, {clunk, 3}),
    ?assertEqual(ok, wait_free(Grant, Empty, 100)),
    ok = call(Grant, {unlinkat, 1, <<"b">>, 0}),
    ?assertEqual(ok, wait_free(Grant, Free, 100)),
    %% Renamed over, and the survivor removed.
    make_data_file(Grant, <<"c">>, 2),
    make_data_file(Grant, <<"d">>, 2),
    ok = call(Grant, {renameat, 1, <<"c">>, 1, <<"d">>}),
    ok = call(Grant, {unlinkat, 1, <<"d">>, 0}),
    ?assertEqual(ok, wait_free(Grant, Free, 100)),
    %% Opened, written and walked by a process that is killed with its file
    %% open, then removed.
    Owner = spawn(fun() -> receive never -> ok end end),
    As = fun(Request) -> call_as(Grant, Owner, Request) end,
    {ok, _} = As({attach, 10, ?NOFID, <<"user">>, <<"tmp">>, 0}),
    {ok, []} = As({walk, 10, 11, []}),
    {ok, _, _} = As({lcreate, 11, <<"e">>, ?O_RDWR, 8#644, 0}),
    {ok, 50000, _} = As({write, 11, 0, Data}),
    {ok, [_]} = As({walk, 10, 12, [<<"e">>]}),
    exit(Owner, kill),
    ok = call(Grant, {unlinkat, 1, <<"e">>, 0}),
    ?assertEqual(ok, wait_free(Grant, Free, 100)),
    stop(Grant).

%% statfs's free counts once two reads 20 ms apart agree, so that the clunks
%% of open fids sent before have reached the tree.
settled_free(Grant) ->
    settled_free(Grant, free(Grant), 100).

settled_free(_Grant, Seen, 0) ->
    Seen;
settled_free(Grant, Seen, Tries) ->
    timer:sleep(20),
    case free(Grant) of
        Seen -> Seen;
        Now -> settled_free(Grant, Now, Tries - 1)
    end.
