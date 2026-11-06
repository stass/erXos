%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs_tests).
-moduledoc """
EUnit tests of /tmp's grant over the real tree (docs/design-tmp.md, Verification): the
"Fids and nodes" case, a fid that outlives its file never reaching a file made after it, and
the "Grammar on the local route" case, names and link texts at and past their limits sent
to the grant as local messages and refused before any callback. The tree is `erx_ramfs`
under `erx_fs`, as `erx_ramfs_sup` starts them. test/host/erx_ramfs_test.rb runs these on
stock OTP and seeds a fault for each.
""".

-include_lib("eunit/include/eunit.hrl").

-define(NOFID, 16#ffffffff).
-define(O_RDWR, 2).
-define(CAP, 1000000).

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
    {ok, _} = attach(Grant, 1),
    Grant.

stop(Grant) ->
    exit(Grant, kill),
    exit(erase({tree, Grant}), kill).

%% A grant that ends while the request is out fails the case at once with the request, so
%% that a grant that crashed on it is a failed case and not a timed out one.
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
    after 2000 ->
        erlang:error({no_reply, Request})
    end.

attach(Grant, Fid) ->
    call(Grant, {attach, Fid, ?NOFID, <<"user">>, <<"tmp">>, 0}).

%% A file made and closed under Name in the directory Fid names; Fid is left alone.
make_file(Grant, Fid, Name, Spare) ->
    {ok, []} = call(Grant, {walk, Fid, Spare, []}),
    {ok, _, _} = call(Grant, {lcreate, Spare, Name, ?O_RDWR, 8#644, 0}),
    ok = call(Grant, {clunk, Spare}).

%% Fids and nodes ----------------------------------------------------------

%% A fid walked to a file, the file removed, then a lopen and a getattr through the
%% fid: both answer enoent, even after a new file is made, which must not take the
%% removed file's inode number.
a_fid_never_reaches_a_file_made_after_its_own_test() ->
    Grant = start(),
    make_file(Grant, 1, <<"f">>, 2),
    {ok, [_]} = call(Grant, {walk, 1, 3, [<<"f">>]}),
    ok = call(Grant, {unlinkat, 1, <<"f">>, 0}),
    make_file(Grant, 1, <<"g">>, 4),
    ?assertEqual({error, enoent}, call(Grant, {lopen, 3, 0})),
    ?assertEqual({error, enoent}, call(Grant, {getattr, 3, 16#7ff})),
    %% The new file is there, and under another inode.
    {ok, [_]} = call(Grant, {walk, 1, 5, [<<"g">>]}),
    ?assertMatch({ok, _}, call(Grant, {getattr, 5, 16#7ff})),
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
        Result -> {Result, drain_calls([])}
    after
        _ = erlang:trace(all, false, [call]),
        [erlang:trace_pattern(P, false, [local]) || P <- Pattern]
    end.

drain_calls(Seen) ->
    receive
        {trace, _, call, {erx_ramfs, Function, _}} -> drain_calls([Function | Seen])
    after 50 ->
        lists:reverse(Seen)
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

free(Grant) ->
    {ok, #{bfree := Free}} = call(Grant, {statfs, 1}),
    Free.

wait_free(_Grant, _Free, 0) ->
    timeout;
wait_free(Grant, Free, Tries) ->
    case free(Grant) of
        Free -> ok;
        _ -> timer:sleep(20), wait_free(Grant, Free, Tries - 1)
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
    exit(Owner, kill),
    ?assertEqual(ok, wait_free(Grant, Free, 100)),
    stop(Grant).
