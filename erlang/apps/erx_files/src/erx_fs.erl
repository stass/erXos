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
demonitors, in order. Requests arrive as `{erx_9p, Alias, Owner, Request}`, a
client's of another domain in the envelope `{erx_origin, D, Frame}` that every
message from another domain arrives in, and replies leave as
`{erx_9p, Alias, Reply}` to `Alias`.

The grant is a plain `proc_lib` process, not a `gen_server`: whoever holds a
grant's pid, a process of another domain included, can send it any term, and
a `gen_server` would act on a `system` message (`sys:replace_state/2`,
`sys:suspend/1`) or a call from it. This loop has one receive, and everything
it receives but its owners' `DOWN`s and its open files' answers is a frame
for the funnel.

Each open file has a **file process**, the file's owner of
docs/design-files.md, which the grant starts at the file's first open through
it and which ends after its last clunk: it runs the requests of the file's
opened fids (reads, writes, listings, size changes through an open, syncs
and clunks) one at a time, in the order the grant sent them, and answers
each to the grant. Requests on the node itself (opens, truncation through an
unopened fid, `getattr`, `remove`) run in the grant; that every request is
atomic against every other is the tree's to keep.

`init/1` answers the tree's handle, `Fs`, which never changes: every callback
receives it and none returns a new one, so the grant and every file process
call the tree through the same handle, and a tree that changes keeps its
nodes behind it, in a process or on a medium, where all of them reach the
same tree. A callback's answer that is not one of its shapes reaches the
client as `eio`.
""".

-export([start_link/3, start_link/4]).
-export([init/2, loop/2, file_loop/4]).

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

-callback init(Args :: term()) -> {ok, Fs :: term()}.
%% The tree the grant roots in: its name, which attach's Aname must match, and its root.
-callback root(Fs :: term()) -> {ok, Tree :: binary(), Node :: term(), qid()}.
-callback walk(Node :: term(), Name :: binary(), Fs :: term()) ->
              {ok, Node1 :: term(), qid()} | {error, file:posix()}.
%% A tree that adds forget keeps each node its walk answers alive for the
%% calling grant until the grant forgets it or ends; the grant forgets a node
%% once none of its fids names it. The one callback without a reply.
-callback forget(Node :: term(), Fs :: term()) -> term().
-callback getattr(Node :: term(), Fs :: term()) ->
              {ok, attr()} | {error, file:posix()}.
-callback open(Node :: term(), Flags :: non_neg_integer(), Fs :: term()) ->
              {ok, Handle :: term()} | {error, file:posix()}.
-callback read(Handle :: term(), Offset :: non_neg_integer(),
               Count :: 1..65536, Fs :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback readdir(Handle :: term(), Offset :: non_neg_integer(),
                  Max :: 1..256, Fs :: term()) ->
              {ok, [dirent()]} | {error, file:posix()}.
-callback readlink(Node :: term(), Fs :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback statfs(Fs :: term()) -> {ok, statfs()}.
-callback clunk(Handle :: term(), Fs :: term()) -> ok.
%% A tree whose reads never wait for a medium answers immediate; absent: helper.
-callback read_mode() -> helper | immediate.
%% A tree that writes adds these; one without them is read-only (F5).
-callback write(Handle :: term(), Offset :: non_neg_integer(), binary(),
                Fs :: term()) ->
              {ok, Count :: non_neg_integer(), At :: non_neg_integer()}
            | {error, file:posix()}.
%% A {file, ...} make answers with the open Handle; every other kind without.
-callback make(Dir :: term(), Name :: binary(), What :: what(), Fs :: term()) ->
              {ok, Node :: term(), qid(), Handle :: term()}
            | {ok, Node :: term(), qid()} | {error, file:posix()}.
-callback setattr(Target :: {open, Handle :: term()} | {node, Node :: term()},
                  Changes :: map(), Fs :: term()) ->
              ok | {error, file:posix()}.
-callback unlink(Dir :: term(), Name :: binary(),
                 Kind :: file | directory | {node, Node :: term()},
                 Fs :: term()) ->
              ok | {error, file:posix()}.
-callback rename(Dir :: term(), Name :: binary(), NewDir :: term(),
                 NewName :: binary(), Fs :: term()) ->
              ok | {error, file:posix()}.
-callback fsync(Handle :: term(), Fs :: term()) ->
              ok | {error, file:posix()}.
-callback xattr(Node :: term(), Op :: term(), Fs :: term()) ->
              {ok, term()} | {error, file:posix()}.
-optional_callbacks([forget/2, read_mode/0, readlink/2, write/4, make/4, setattr/3,
                     unlink/4, rename/5, fsync/2, xattr/3]).

%% What a grant's process may hold for its client, its fids and their paths,
%% its owners and the requests in flight, binaries included, in words; and
%% what each file process may hold, the jobs the grant sent it, of which at
%% most 64 carry data.
-define(MAX_HEAP_WORDS, 4194304).

-doc "Serves one grant of `Module`'s tree to the server's own domain.".
-spec start_link(module(), term(), erx_fs_grant:rights()) ->
          {ok, pid()} | {error, term()}.
start_link(Module, Args, Rights) ->
    start_link(Module, Args, Rights, #{}).

-doc """
Serves one grant of `Module`'s tree. `client` names the domain the grant is
for, `own` for the server's own (the default) or another domain's id;
`pool` is its fid bound (4,096), `in_flight` and `msize` its bounds on the
requests it holds and on the message size (erx_fs_grant:new/1), and
`max_heap_size` its process's heap bound in words, shared binaries included
(4,194,304).

A grant for another domain is exported to that domain alone, with `send`
alone, before this returns, through `exports` (erx_dist, or a host test's
stand-in); a refused export is answered `{error, Reason}` and leaves no
grant. Such a grant must name `ends_with`: the port of this domain's connection to
the client, or, in the system domain, which holds no port of a connection, the
client's domain pid, which the grant monitors before the export and ends with
`{shutdown, connection_ended}` when it ends, so the grant and its export
never outlive the connection its client calls through; or `none`, for a
client whose grant lives as long as this domain. A grant for another domain
without it fails to start.
""".
-spec start_link(module(), term(), erx_fs_grant:rights(),
                 #{client => erx_fs_grant:client(), pool => pos_integer(),
                   in_flight => pos_integer(), msize => pos_integer(),
                   max_heap_size => pos_integer(), ends_with => port() | pid() | none,
                   exports => module()}) ->
          {ok, pid()} | {error, term()}.
start_link(Module, Args, Rights, Options) ->
    Heap = #{size => maps:get(max_heap_size, Options, ?MAX_HEAP_WORDS), kill => true,
             include_shared_binaries => true},
    proc_lib:start_link(?MODULE, init, [self(), {Module, Args, Rights, Options}],
                        infinity, [{max_heap_size, Heap}]).

-doc false.
-spec init(pid(), {module(), term(), erx_fs_grant:rights(), map()}) -> no_return().
init(Parent, {Module, Args, Rights, Options}) ->
    {module, Module} = code:ensure_loaded(Module),
    {ok, Fs} = Module:init(Args),
    Client = maps:get(client, Options, own),
    Grant = erx_fs_grant:new((maps:with([pool, in_flight, msize], Options))#{
                               module => Module, fs => Fs, rights => Rights,
                               client => Client}),
    %% The monitor comes first: a connection that ends at any time from here on,
    %% before the export or after it, ends the grant, and a port that has ended
    %% already is answered at once with a 'DOWN'.
    ConnectionMonitor = connection_monitor(Client, Options),
    case export(Client, maps:get(exports, Options, erx_dist)) of
        ok ->
            proc_lib:init_ack(Parent, {ok, self()}),
            loop(Grant, ConnectionMonitor);
        {error, _} = Refused ->
            proc_lib:init_ack(Parent, Refused)
    end.

%% A grant for another domain ends with the connection Options name, or with the
%% client's domain pid, or names none; one that names none of these is a caller's
%% mistake, and its start fails.
connection_monitor(own, _Options) -> none;
connection_monitor(_Client, #{ends_with := none}) -> none;
connection_monitor(_Client, #{ends_with := Port}) when is_port(Port) -> erlang:monitor(port, Port);
connection_monitor(_Client, #{ends_with := DomainPid}) when is_pid(DomainPid) -> erlang:monitor(process, DomainPid).

%% A grant for another domain is exported to that domain alone, with send alone; a
%% grant for the server's own domain is exported to no one.
export(own, _Exports) ->
    ok;
export(Client, Exports) ->
    Exports:export(self(), [send], Client).

%% Each message is handled whole, and the next is awaited through a remote call,
%% so a grant moves to newly loaded code between messages and the purge of the
%% old code kills no grant. A grant takes no `sys` suspension: an upgrade that
%% changes the core's state must restart its grants.
-doc false.
-spec loop(erx_fs_grant:grant(), reference() | none) -> no_return().
loop(Grant, ConnectionMonitor) ->
    receive
        {'DOWN', ConnectionMonitor, _PortOrProcess, _, _} ->
            exit({shutdown, connection_ended});
        {'DOWN', Ref, process, Owner, _} when is_reference(Ref), is_pid(Owner) ->
            ?MODULE:loop(perform(erx_fs_grant:owner_down(Ref, Owner, Grant)), ConnectionMonitor);
        {erx_fs_file, Tag, Alias, Reply} when is_reference(Tag), is_reference(Alias) ->
            ?MODULE:loop(perform(erx_fs_grant:file_answer(Tag, Alias, Reply, Grant)), ConnectionMonitor);
        Frame ->
            ?MODULE:loop(perform(erx_fs_grant:handle_frame(Frame, Grant)), ConnectionMonitor)
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
    Grant;
perform_effect({start_file, Node, Module, Fs}, Grant) ->
    Tag = make_ref(),
    Heap = #{size => ?MAX_HEAP_WORDS, kill => true, include_shared_binaries => true},
    Process = proc_lib:spawn_opt(?MODULE, file_loop, [self(), Tag, Module, Fs],
                                 [link, {max_heap_size, Heap}]),
    erx_fs_grant:file_started(Node, Process, Tag, Grant);
perform_effect({run, Process, Tag, Job}, Grant) ->
    erlang:send(Process, {Tag, Job}),
    Grant.

%% A file process: it runs its file's jobs one at a time, in the order the
%% grant sent them, answers each request to the grant, and ends after the last
%% clunk. It is linked to its grant, so a callback that crashes in it ends the
%% grant, and the grant's end ends it. A message without its tag is dropped, so
%% nothing but the grant's jobs reaches the tree through it.
-doc false.
-spec file_loop(pid(), reference(), module(), term()) -> ok.
file_loop(Grant, Tag, Module, Fs) ->
    receive
        {Tag, Job} ->
            case erx_fs_grant:run_job(Job, Module, Fs) of
                {answer, Alias, Reply} ->
                    erlang:send(Grant, {erx_fs_file, Tag, Alias, Reply}),
                    ?MODULE:file_loop(Grant, Tag, Module, Fs);
                continue ->
                    ?MODULE:file_loop(Grant, Tag, Module, Fs);
                stop ->
                    ok
            end;
        _ ->
            ?MODULE:file_loop(Grant, Tag, Module, Fs)
    end.
