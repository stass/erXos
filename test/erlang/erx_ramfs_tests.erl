%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs_tests).
-moduledoc """
EUnit tests of /tmp's grant over the real tree (docs/design-tmp.md, Verification): the
"Fids and nodes" cases, a fid that keeps a removed file and never reaches a file made after
it, a stat that a rename over its name falls inside, a stopped walk, ".." from a removed
directory, a removed file freed by its last fid's clunk, one message each way per request, and
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

%% A grant holding its own tree; the file version counter is the one the tests share.
start() ->
    ok = erx_fs_version:init(),
    {ok, Grant, _} = erx_fs:start_link(erx_ramfs, ?CAP, rw),
    unlink(Grant),
    {ok, _} = attach(Grant, 1),
    Grant.

stop(Grant) ->
    exit(Grant, kill).

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

%% One message each way: while a process reads a file's attributes, opens it, reads it
%% and closes it, the grant takes one message and sends one reply per request, and no
%% callback sends a message or takes a monitor, since the tree is the grant's own. The
%% open is one exchange of a walk from NOFID, a clone and an lopen.
each_request_is_one_message_each_way_test() ->
    Grant = start(),
    write_file(Grant, <<"f">>, binary:copy(<<7>>, 4096), 2),
    Requests = [{walk, ?NOFID, 5, [<<"f">>]}, {getattr, 5, 16#7ff}, {walk, 5, 6, []},
                {lopen, 6, ?O_RDWR}, {read, 6, 0, 4096}, {clunk, 6}, {clunk, 5}],
    Self = self(),
    Monitors = [{erlang, monitor, 2}, {erlang, monitor, 3}],
    [1 = erlang:trace_pattern(P, true, [global]) || P <- Monitors],
    1 = erlang:trace(Grant, true, [send, 'receive', call, {tracer, Self}]),
    Replies = try [call(Grant, R) || R <- Requests]
              after
                  _ = erlang:trace(Grant, false, [send, 'receive', call]),
                  [erlang:trace_pattern(P, false, [global]) || P <- Monitors]
              end,
    ?assertMatch([{ok, [_]}, {ok, _}, {ok, []}, {ok, _, _}, {ok, <<7:8, _/binary>>}, ok, ok],
                 Replies),
    Events = drain_trace(erlang:trace_delivered(Grant), []),
    Received = [M || {trace, _, 'receive', M} <- Events],
    Sent = [M || {trace, _, send, M, _} <- Events],
    Calls = [C || {trace, _, call, C} <- Events],
    ?assertEqual(length(Requests), length(Received)),
    ?assertEqual(length(Requests), length(Sent)),
    ?assert(lists:all(fun({erx_9p, Alias, _}) -> is_reference(Alias); (_) -> false end, Sent)),
    ?assertEqual([], Calls),
    stop(Grant).

drain_trace(Ref, Seen) ->
    receive
        {trace_delivered, _, Ref} -> lists:reverse(Seen);
        {trace, _, _, _} = Event -> drain_trace(Ref, [Event | Seen]);
        {trace, _, _, _, _} = Event -> drain_trace(Ref, [Event | Seen])
    end.

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
%% the last name goes. A killed owner's fids are clunked when the grant sees its
%% end, so the counts are awaited rather than read once.
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

%% Requests behind a failed request -------------------------------------------

%% Requests sent as one exchange, every one before the first reply is read, and
%% their replies in order.
exchange(Grant, Requests) ->
    Aliases = [begin
                   Alias = alias([reply]),
                   Grant ! {erx_9p, Alias, self(), Request},
                   Alias
               end || Request <- Requests],
    [receive {erx_9p, Alias, Reply} -> Reply after ?REPLY_BOUND -> erlang:error({no_reply, Request}) end
     || {Alias, Request} <- lists:zip(Aliases, Requests)].

%% docs/design-files.md, "Requests behind a failed request", the grant's half. A
%% live fid holds f, which has data. A walk to a missing name, a clone of the fid it
%% was to make and an lopen of the clone with O_TRUNC, sent as one: the walk fails,
%% and the clone and the lopen name fids that do not exist, so each answers ebadf.
%% Then, with one slot of the pool left, a walk to f takes it, a clone of that fid is
%% refused for the full pool, and an lopen of the clone with O_TRUNC answers ebadf.
%% f keeps its data through both, and no fid a failed request was to make exists.
requests_behind_a_failed_request_change_nothing_test() ->
    ok = erx_fs_version:init(),
    {ok, Grant, _} = erx_fs:start_link(erx_ramfs, ?CAP, rw, #{pool => 4}),
    unlink(Grant),
    {ok, _} = attach(Grant, 1),
    write_file(Grant, <<"f">>, <<"data">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 2, [<<"f">>]}),
    {ok, []} = call(Grant, {walk, 1, 3, []}),
    Trunc = ?O_RDWR bor ?ERX_P9_O_TRUNC,
    ?assertEqual([{error, enoent}, {error, ebadf}, {error, ebadf}],
                 exchange(Grant, [{walk, ?NOFID, 10, [<<"missing">>]}, {walk, 10, 11, []},
                                  {lopen, 11, Trunc}])),
    ?assertMatch([{ok, [_]}, {error, emfile}, {error, ebadf}],
                 exchange(Grant, [{walk, ?NOFID, 12, [<<"f">>]}, {walk, 12, 13, []},
                                  {lopen, 13, Trunc}])),
    [?assertEqual({error, ebadf}, call(Grant, {getattr, Fid, 16#7ff})) || Fid <- [10, 11, 13]],
    ok = call(Grant, {clunk, 12}),
    {ok, _, _} = call(Grant, {lopen, 2, 0}),
    ?assertEqual({ok, <<"data">>}, call(Grant, {read, 2, 0, 10})),
    stop(Grant).

%% The heap bound --------------------------------------------------------------

-define(WRITE, 65536).
-define(D_REMOVEDIR, 16#200).

%% A grant of a tmp of Cap bytes under the heap bound erx_ramfs_sup gives it, with
%% fid 1 on its root.
bounded(Cap) ->
    ok = erx_fs_version:init(),
    {ok, Grant, _} = erx_fs:start_link(erx_ramfs, Cap, rw,
                                       #{max_heap_size => erx_ramfs_sup:heap_words(Cap)}),
    unlink(Grant),
    {ok, _} = attach(Grant, 1),
    Grant.

%% Fills the pool with clones of From, numbered from First, and answers the fids
%% made; the clone past the last is refused with emfile.
fill_pool(Grant, From, First) ->
    case call(Grant, {walk, From, First, []}) of
        {ok, []} -> [First | fill_pool(Grant, From, First + 1)];
        {error, emfile} -> []
    end.

%% 64 writes of 64 KiB each to Fid, all sent before any reply is read, so all are in
%% the grant's mailbox at once; answers their replies.
writes_in_flight(Grant, Fid) ->
    Data = binary:copy(<<5>>, ?WRITE),
    exchange(Grant, [{write, Fid, Offset * ?WRITE, Data} || Offset <- lists:seq(0, 63)]).

%% A directory chain from fid Cursor, walked in place, as deep as the cap allows or
%% Depth at most; answers its depth.
chain(Grant, Cursor, Depth) -> chain(Grant, Cursor, Depth, 0).

chain(_Grant, _Cursor, Depth, Depth) ->
    Depth;
chain(Grant, Cursor, Depth, Made) ->
    case call(Grant, {mkdir, Cursor, <<"d">>, 8#755, 0}) of
        {ok, _} ->
            {ok, [_]} = call(Grant, {walk, Cursor, Cursor, [<<"d">>]}),
            chain(Grant, Cursor, Depth, Made + 1);
        {error, enospc} ->
            Made
    end.

%% Removes the chain of Depth directories below the directory fid Cursor names,
%% the deepest first, leaving Cursor where the chain began.
unchain(_Grant, _Cursor, 0) ->
    ok;
unchain(Grant, Cursor, Depth) ->
    {ok, [_]} = call(Grant, {walk, Cursor, Cursor, [<<"..">>]}),
    ok = call(Grant, {unlinkat, Cursor, <<"d">>, ?D_REMOVEDIR}),
    unchain(Grant, Cursor, Depth - 1).

%% Files of 4 KiB named by number in the root until the cap refuses one; answers
%% how many were made.
fill_small(Grant, Spare) -> fill_small(Grant, Spare, 0).

fill_small(Grant, Spare, N) ->
    Name = integer_to_binary(N),
    {ok, []} = call(Grant, {walk, 1, Spare, []}),
    case call(Grant, {lcreate, Spare, Name, ?O_RDWR, 8#644, 0}) of
        {ok, _, _} ->
            Reply = call(Grant, {write, Spare, 0, binary:copy(<<3>>, 4096)}),
            ok = call(Grant, {clunk, Spare}),
            case Reply of
                {ok, 4096, _} -> fill_small(Grant, Spare, N + 1);
                {error, enospc} -> ok = call(Grant, {unlinkat, 1, Name, 0}), N
            end;
        {error, enospc} ->
            ok = call(Grant, {clunk, Spare}),
            N
    end.

%% One open file in the root written 4 KiB at a time until the cap stops a write;
%% answers the size it reached, the fid left open.
fill_one(Grant, Fid) ->
    {ok, []} = call(Grant, {walk, 1, Fid, []}),
    {ok, _, _} = call(Grant, {lcreate, Fid, <<"big">>, ?O_RDWR, 8#644, 0}),
    fill_one(Grant, Fid, 0, binary:copy(<<1>>, 4096)).

fill_one(Grant, Fid, Size, Data) ->
    case call(Grant, {write, Fid, Size, Data}) of
        {ok, 4096, _} -> fill_one(Grant, Fid, Size + 4096, Data);
        {ok, Count, _} -> Size + Count;
        {error, enospc} -> Size
    end.

%% The tree the grant holds, as the step that answers a statfs returns it, checked
%% with erx_ramfs_core:check/1: a return trace of the core's step/4 shows it.
check_tree(Grant) ->
    1 = erlang:trace_pattern({erx_ramfs_core, step, 4}, [{'_', [], [{return_trace}]}], [local]),
    1 = erlang:trace(Grant, true, [call, {tracer, self()}]),
    try
        {ok, _} = call(Grant, {statfs, 1}),
        receive
            {trace, Grant, return_from, {erx_ramfs_core, step, 4}, {_, Tree}} ->
                ?assertEqual(ok, erx_ramfs_core:check(Tree))
        after ?REPLY_BOUND ->
            erlang:error(no_step_traced)
        end
    after
        _ = erlang:trace(Grant, false, [call]),
        erlang:trace_pattern({erx_ramfs_core, step, 4}, false, [local])
    end.

%% A grant still alive, its monitor never fired.
assert_serving(Grant, Monitor) ->
    receive
        {'DOWN', Monitor, process, Grant, Reason} -> erlang:error({grant_killed, Reason})
    after 0 ->
        ?assert(is_process_alive(Grant))
    end.

%% docs/design-tmp.md, "The heap bound", at a tmp of 0: the grant holds its whole
%% pool of fids on the root, every creation answers enospc, and 64 writes of 64 KiB
%% wait in its mailbox at once; it serves throughout.
a_tmp_of_0_serves_at_its_bounds_test() ->
    Grant = bounded(0),
    Monitor = monitor(process, Grant),
    Fids = fill_pool(Grant, 1, 2),
    ?assertEqual(erx_fs_grant_pool(), length(Fids) + 1),
    ok = call(Grant, {clunk, lists:last(Fids)}),
    Spare = lists:last(Fids),
    {ok, []} = call(Grant, {walk, 1, Spare, []}),
    ?assertEqual({error, enospc}, call(Grant, {lcreate, Spare, <<"f">>, ?O_RDWR, 8#644, 0})),
    ?assertEqual({error, enospc}, call(Grant, {mkdir, 1, <<"d">>, 8#755, 0})),
    ?assertEqual({error, enospc}, call(Grant, {symlink, 1, <<"l">>, <<"t">>, 0})),
    ?assert(lists:all(fun({error, _}) -> true; (_) -> false end, writes_in_flight(Grant, Spare))),
    assert_serving(Grant, Monitor),
    check_tree(Grant),
    stop(Grant).

%% The grant erx_ramfs_sup starts is sensitive: its state is the domain's files,
%% so process_info shows none of its dictionary, which proc_lib fills for any
%% other process.
the_supervisors_grant_hides_its_state_test() ->
    ok = erx_fs_version:init(),
    {ok, Grant, _} = erx_fs:start_link(erx_ramfs, 0, rw, erx_ramfs_sup:grant_options(0)),
    unlink(Grant),
    ?assertMatch({ok, _}, attach(Grant, 1)),
    ?assertEqual({dictionary, []}, process_info(Grant, dictionary)),
    stop(Grant).

%% The pool a grant takes by default (erx_fs:start_link/4).
erx_fs_grant_pool() -> 4096.

%% docs/design-tmp.md, "The heap bound", at a tmp of 64 KiB, and the case its seeded
%% fault, a bound without the reserve, must fail.
a_64_kib_tmp_serves_at_its_bounds_test() ->
    serves_at_its_bounds(64 * 1024, infinity).

%% The same at a tmp of 32 MiB. The chain stops at 1,024 directories: each walk
%% costs the grant time linear in its fid's depth (erx_fs_grant's repath/3), so
%% the chain the cap allows, about 100,000 deep, would take the case quadratic time.
a_32_mib_tmp_serves_at_its_bounds_test_() ->
    {timeout, 600, fun() -> serves_at_its_bounds(32 * 1024 * 1024, 1024) end}.

%% The grant's whole pool walked into the deepest directory chain allowed and 64
%% writes of 64 KiB in flight; then the chain gone, the tree filled to its cap with
%% 4 KiB files, then emptied and filled with one file, every chunk of it
%% overwritten a hundred times with the writes in flight again, and then
%% everything removed and the 4 KiB files made again. The grant serves throughout
%% and check/1 holds at the end.
serves_at_its_bounds(Cap, MaxDepth) ->
    Grant = bounded(Cap),
    Monitor = monitor(process, Grant),
    {ok, []} = call(Grant, {walk, 1, 2, []}),
    Depth = chain(Grant, 2, MaxDepth),
    ?assert(Depth > 0),
    Fids = fill_pool(Grant, 2, 10),
    ?assertEqual(erx_fs_grant_pool(), length(Fids) + 2),
    ok = call(Grant, {clunk, lists:last(Fids)}),
    {ok, []} = call(Grant, {walk, 2, 3, []}),
    {ok, _, _} = call(Grant, {lopen, 3, 0}),
    _ = writes_in_flight(Grant, 3),
    assert_serving(Grant, Monitor),
    [ok = call(Grant, {clunk, Fid}) || Fid <- [3 | lists:droplast(Fids)]],
    unchain(Grant, 2, Depth),
    Small = fill_small(Grant, 4),
    ?assert(Small > 0),
    [ok = call(Grant, {unlinkat, 1, integer_to_binary(N), 0}) || N <- lists:seq(0, Small - 1)],
    Size = fill_one(Grant, 5),
    ?assert(Size > 0),
    Data = binary:copy(<<9>>, ?WRITE),
    lists:foreach(fun(_) ->
                          [{ok, _, _} = call(Grant, {write, 5, At, binary:part(Data, 0, min(?WRITE, Size - At))})
                           || At <- lists:seq(0, Size - 1, ?WRITE)]
                  end, lists:seq(1, 100)),
    _ = writes_in_flight(Grant, 5),
    ok = call(Grant, {clunk, 5}),
    ok = call(Grant, {unlinkat, 1, <<"big">>, 0}),
    ?assertEqual(Small, fill_small(Grant, 4)),
    assert_serving(Grant, Monitor),
    check_tree(Grant),
    stop(Grant).
