%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs).
-moduledoc """
The `erx_fs` behaviour and the process that serves one grant
(docs/design-files.md#serving-the-erx_fs-behaviour).

A file server is a callback module of this behaviour, which calls back for its
tree; `erx_fs` owns the protocol, the fids and the checks. Each grant is one
process that serves one client domain on one tree. It decides nothing itself:
every message but an owner's `DOWN` goes to `erx_fs_grant`'s funnel, and the
process performs the effects the core returns, replies, monitors and
demonitors, in order. Requests arrive as `{erx_9p, Alias, Owner, Request}` and
replies leave as `{erx_9p, Alias, Reply}` to `Alias`.

The grant is a plain `proc_lib` process, not a `gen_server`: whoever holds a
grant's pid, a process of another domain included, can send it any term, and
a `gen_server` would act on a `system` message (`sys:replace_state/2`,
`sys:suspend/1`) or a call from it. This loop has one receive, and everything
it receives but its owners' `DOWN`s is a frame for the funnel.
""".

-export([start_link/3, start_link/4]).
-export([init/2, loop/1]).

-export_type([qid/0, attr/0, statfs/0, dirent/0, what/0]).

-type qid() :: {Type :: 0..255, Version :: 0..16#ffffffff,
                Path :: 0..16#ffffffffffffffff}.
-type attr() :: #{atom() => term()}.
-type statfs() :: #{atom() => non_neg_integer()}.
-type dirent() :: {qid(), Offset :: non_neg_integer(), Type :: 0..255, Name :: binary()}.
-type what() :: {file, Mode :: 0..8#7777, Flags :: non_neg_integer()}
              | {directory, Mode :: 0..8#7777}
              | {symlink, Target :: binary()} | {link, Node :: term()}
              | {node, Mode :: non_neg_integer(), Major :: non_neg_integer(),
                 Minor :: non_neg_integer()}.

-callback init(Args :: term()) -> {ok, State :: term()}.
%% The tree the grant roots in: its name, which attach's Aname must match, and its root.
-callback root(State :: term()) -> {ok, Tree :: binary(), Node :: term(), qid()}.
-callback walk(Node :: term(), Name :: binary(), State :: term()) ->
              {ok, Node1 :: term(), qid()} | {error, file:posix()}.
-callback getattr(Node :: term(), State :: term()) ->
              {ok, attr()} | {error, file:posix()}.
-callback open(Node :: term(), Flags :: non_neg_integer(), State :: term()) ->
              {ok, Handle :: term(), State1 :: term()} | {error, file:posix()}.
-callback read(Handle :: term(), Offset :: non_neg_integer(),
               Count :: 1..65536, State :: term()) ->
              {ok, binary(), State1 :: term()} | {error, file:posix()}.
-callback readdir(Handle :: term(), Offset :: non_neg_integer(),
                  Max :: 1..256, State :: term()) ->
              {ok, [dirent()], State1 :: term()} | {error, file:posix()}.
-callback readlink(Node :: term(), State :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback statfs(State :: term()) -> {ok, statfs()}.
-callback clunk(Handle :: term(), State :: term()) -> {ok, State1 :: term()}.
%% A tree whose reads never wait for a medium answers immediate; absent: helper.
-callback read_mode() -> helper | immediate.
%% A tree that writes adds these; one without them is read-only (F5).
-callback write(Handle :: term(), Offset :: non_neg_integer(), binary(),
                State :: term()) ->
              {ok, Count :: non_neg_integer(), At :: non_neg_integer(),
               State1 :: term()} | {error, file:posix()}.
%% A {file, ...} make answers with the open Handle; every other kind without.
-callback make(Dir :: term(), Name :: binary(), What :: what(), State :: term()) ->
              {ok, Node :: term(), qid(), Handle :: term(), State1 :: term()}
            | {ok, Node :: term(), qid(), State1 :: term()} | {error, file:posix()}.
-callback setattr(Target :: {open, Handle :: term()} | {node, Node :: term()},
                  Changes :: map(), State :: term()) ->
              {ok, State1 :: term()} | {error, file:posix()}.
-callback unlink(Dir :: term(), Name :: binary(), Kind :: file | directory | any,
                 State :: term()) ->
              {ok, State1 :: term()} | {error, file:posix()}.
-callback rename(Dir :: term(), Name :: binary(), NewDir :: term(),
                 NewName :: binary(), State :: term()) ->
              {ok, State1 :: term()} | {error, file:posix()}.
-callback fsync(Handle :: term(), State :: term()) ->
              {ok, State1 :: term()} | {error, file:posix()}.
-callback xattr(Node :: term(), Op :: term(), State :: term()) ->
              {ok, term(), State1 :: term()} | {error, file:posix()}.
-optional_callbacks([read_mode/0, readlink/2, write/4, make/4, setattr/3,
                     unlink/4, rename/5, fsync/2, xattr/3]).

%% What a grant's process may hold for its client: its fids and their paths,
%% its owners and the requests in flight, binaries included, in words.
-define(MAX_HEAP_WORDS, 4194304).

-doc "Serves one grant of `Module`'s tree to the server's own domain.".
-spec start_link(module(), term(), erx_fs_grant:rights()) ->
          {ok, pid()} | {error, term()}.
start_link(Module, Args, Rights) ->
    start_link(Module, Args, Rights, #{}).

-doc """
Serves one grant of `Module`'s tree. `client` names the node of the domain the
grant is for (the server's own by default) and `pool` its fid bound (4,096).
""".
-spec start_link(module(), term(), erx_fs_grant:rights(),
                 #{client => node(), pool => pos_integer()}) ->
          {ok, pid()} | {error, term()}.
start_link(Module, Args, Rights, Options) ->
    Heap = #{size => ?MAX_HEAP_WORDS, kill => true, include_shared_binaries => true},
    proc_lib:start_link(?MODULE, init, [self(), {Module, Args, Rights, Options}],
                        infinity, [{max_heap_size, Heap}]).

-doc false.
-spec init(pid(), {module(), term(), erx_fs_grant:rights(), map()}) -> no_return().
init(Parent, {Module, Args, Rights, Options}) ->
    {module, Module} = code:ensure_loaded(Module),
    {ok, Tree} = Module:init(Args),
    Grant = erx_fs_grant:new((maps:with([pool], Options))#{
                               module => Module, tree => Tree, rights => Rights,
                               client => maps:get(client, Options, node())}),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(Grant).

%% Each message is handled whole, and the next is awaited through a remote call,
%% so a grant moves to newly loaded code between messages and the purge of the
%% old code kills no grant. A grant takes no `sys` suspension: an upgrade that
%% changes the core's state must restart its grants.
-doc false.
-spec loop(erx_fs_grant:grant()) -> no_return().
loop(Grant) ->
    receive
        {'DOWN', Ref, process, Owner, _} when is_reference(Ref), is_pid(Owner) ->
            ?MODULE:loop(perform(erx_fs_grant:owner_down(Ref, Owner, Grant)));
        Frame ->
            ?MODULE:loop(perform(erx_fs_grant:handle_frame(Frame, Grant)))
    end.

perform({Effects, Grant}) ->
    lists:foldl(fun perform_effect/2, Grant, Effects).

perform_effect({reply, Alias, Reply}, Grant) ->
    erlang:send(Alias, {erx_9p, Alias, Reply}),
    Grant;
perform_effect({monitor, Owner}, Grant) ->
    erx_fs_grant:monitored(Owner, erlang:monitor(process, Owner), Grant);
perform_effect({demonitor, Ref}, Grant) ->
    erlang:demonitor(Ref, [flush]),
    Grant.
