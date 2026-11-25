%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs).
-moduledoc """
The `erx_fs` behaviour and the process that serves one grant
(docs/design-files.md#serving-the-erx_fs-behaviour).

A file server is a callback module of this behaviour, which calls back for its
tree; `erx_fs` owns the protocol, the fids and the checks. Each grant is one
process that serves one client domain on one tree. It decides nothing itself:
every message goes to `erx_fs_grant`, a `DOWN` to `down/3`, a keeper's answer
to `answered/3` and every other message to the funnel, and the process
performs the effects the core returns, in order: replies, monitors and
demonitors, and the requests and flushes it sends to keepers. Requests arrive as `{erx_9p, Alias, Owner, Request}`, a
client's of another domain in the envelope `{erx_origin, D, Frame}` that every
message from another domain arrives in, and replies leave as
`{erx_9p, Alias, Reply}` to `Alias`.

The grant is a plain `proc_lib` process, not a `gen_server`: whoever holds a
grant's pid, a process of another domain included, can send it any term, and
a `gen_server` would act on a `system` message (`sys:replace_state/2`,
`sys:suspend/1`) or a call from it. Its loop has one receive, and everything
it receives but its `DOWN`s and its keepers' answers is a frame for the
funnel. Once its client has ended the grant drains: it takes no frame,
clunks every fid by rule 5, answers nothing and ends once the last clunk
has run.

The grant runs every callback itself, one at a time, in the order the
requests arrive, and none waits for an event: a read or a write that must
wait answers `{wait, Keeper, Request}`, and the grant hands the request to
its keeper, a process of the tree, and goes on with its client's other
requests ("Waiting requests" of docs/design-files.md). The grant monitors
the keeper with an alias that the first reply deactivates and sends it the
request; the keeper's one answer arrives through that alias, its end
through the monitor, which answers the request `eio`. The messages between
them are erx_fs_waits.hrl's. That every request is atomic against every
other is the tree's to keep.

`init/1` answers the tree's handle, `Fs`, which never changes: every callback
receives it and none returns a new one, and a tree that changes keeps its
nodes behind it, in a process or on a medium, where every grant reaches the
same tree. A callback's answer that is not one of its shapes reaches the
client as `eio`.
""".

-export([start_link/3, start_link/4, start_mounted/4]).
-export([init/2, loop/2, drain/1, format_status/1]).

-include("erx_fs_waits.hrl").

-export_type([qid/0, attr/0, statfs/0, dirent/0, what/0, wait/0, grant_handle/0]).

-type qid() :: {Type :: 0..255, Version :: 0..16#ffffffff,
                Path :: 0..16#ffffffffffffffff}.
-type attr() :: #{atom() => term()}.
-type statfs() :: #{atom() => non_neg_integer()}.
-type dirent() :: {qid(), Offset :: non_neg_integer(), Type :: 0..255, Name :: binary()}.
-type what() :: {file, Mode :: 0..8#7777, Flags :: non_neg_integer()}
              | {directory, Mode :: 0..8#7777, Owner :: pid()}
              | {symlink, Target :: binary()} | {link, Node :: term()}
              | {node, Mode :: non_neg_integer(), Major :: non_neg_integer(),
                 Minor :: non_neg_integer()}.
-type wait() :: {wait, Keeper :: pid(), Request :: term()}.
%% A grant of the domain's own, as its starter received it from start_link/3,4: the
%% pid, the tree its callback module's root names and the rights it was started with
%% (docs/design-files.md, "A grant handle is built by its starter").
-opaque grant_handle() :: {pid(), Tree :: binary(), erx_fs_grant:rights()}.

-callback init(Args :: term()) -> {ok, Fs :: term()}.
%% A tree whose grants a facet row's `tree` may root within it (abi/services/files.txt)
%% adds subtree: the init Args of a grant of the tree Args name, rooted at the root Tree
%% names for Grantee, the domain the grant is for and the principal its mint named
%% (erx_fs_grants:grantee/0), or {error, einval}. erx_fs_grants asks it before such a
%% grant starts; a tree without it starts no grant whose row states a tree.
-callback subtree(Args :: term(), Tree :: atom(), Grantee :: erx_fs_grants:grantee()) ->
              {ok, Args1 :: term()} | {error, einval}.
%% The tree the grant roots in: its name, which attach's Aname must match, and its root.
%% An error fails the grant's start, as an answer that fails the root's check does.
-callback root(Fs :: term()) -> {ok, Tree :: binary(), Node :: term(), qid()} | {error, file:posix()}.
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
%% A read or a write that waits for an event answers {wait, Keeper, Request}:
%% the tree's Keeper answers it later, through erx_fs_waits ("Waiting requests").
-callback read(Handle :: term(), Offset :: non_neg_integer(),
               Count :: 1..65536, Fs :: term()) ->
              {ok, binary()} | {error, file:posix()} | wait().
-callback readdir(Handle :: term(), Offset :: non_neg_integer(),
                  Max :: 1..256, Fs :: term()) ->
              {ok, [dirent()]} | {error, file:posix()}.
-callback readlink(Node :: term(), Fs :: term()) ->
              {ok, binary()} | {error, file:posix()}.
-callback statfs(Fs :: term()) -> {ok, statfs()}.
%% ok, or the errno of what the close could not complete; the fid ends
%% either way.
-callback clunk(Handle :: term(), Fs :: term()) -> ok | {error, file:posix()}.
%% A tree that writes adds these; one without them is read-only (F5). write's At is
%% the offset the bytes were written at: the request's, or the file's end for an
%% append fid (design-files.md, "Open files and offsets").
-callback write(Handle :: term(), Offset :: non_neg_integer(), binary(),
                Fs :: term()) ->
              {ok, Count :: non_neg_integer(), At :: non_neg_integer()}
            | {error, file:posix()} | wait().
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
-optional_callbacks([subtree/3, forget/2, readlink/2, write/4, make/4, setattr/3,
                     unlink/4, rename/5, fsync/2, xattr/3]).

%% What a grant's process may hold for its client, its fids and their paths,
%% its owners and the requests in flight, binaries included, in words.
-define(MAX_HEAP_WORDS, 4194304).

-doc """
Serves one grant of `Module`'s tree to the server's own domain, and answers its
pid with its handle, which carries the tree the callback module's `root` names and
the rights the grant serves, `ro` for `rw` on a tree that writes nothing. The
root is asked once and checked before the grant takes any request; a root that
fails the check fails the start with `{error, root}` (erx_fs_grant:new/1).
""".
-spec start_link(module(), term(), erx_fs_grant:rights()) ->
          {ok, pid(), grant_handle()} | {error, term()}.
start_link(Module, Args, Rights) ->
    start_link(Module, Args, Rights, #{}).

-doc """
Serves one grant of `Module`'s tree to the server's own domain, as
start_link/3 does, and mounts it at `Point` with the tree and the rights
its handle carries, `{Pid, Rights}` (erx_ns:mount/3), after removing any
entry an earlier instance left there. So the entry's tree and rights are
the grant's, named once (docs/design-files.md, "Rights beneath an
entry"). A mount that fails ends the grant, which the caller's supervisor
does not know of, and answers its `{error, Reason}`.
""".
-spec start_mounted(module(), term(), erx_fs_grant:rights(), binary()) ->
          {ok, pid()} | {error, term()}.
start_mounted(Module, Args, Requested, Point) ->
    case start_link(Module, Args, Requested) of
        {ok, Grant, {Grant, Tree, Rights}} ->
            _ = erx_ns:unmount(Point),
            mounted(Grant, erx_ns:mount({Grant, Rights}, Point, [{tree, Tree}, Rights]));
        {error, _} = Refused ->
            Refused
    end.

mounted(Grant, ok) ->
    {ok, Grant};
mounted(Grant, {error, _} = Error) ->
    unlink(Grant),
    exit(Grant, kill),
    Error.

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
client's domain pid, which the grant monitors before the export; at its end
the grant drains, answering nothing, and then ends with
`{shutdown, connection_ended}`, so the grant and its export outlive the
connection its client calls through only while the grant drains; or `none`, for a
client whose grant lives as long as this domain. A grant for another domain
without it fails to start. A grant for its own domain ends with the process
`ends_with` names, whatever that process's reason, as a program's `/dev`
tree ends with its handler (docs/design-files.md, "A program's window"), and
lives as long as this domain without it.
""".
-spec start_link(module(), term(), erx_fs_grant:rights(),
                 #{client => erx_fs_grant:client(), pool => pos_integer(),
                   in_flight => pos_integer(), msize => pos_integer(),
                   max_heap_size => pos_integer(), ends_with => port() | pid() | none,
                   exports => module()}) ->
          {ok, pid(), grant_handle()} | {error, term()}.
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
    case erx_fs_grant:new((maps:with([pool, in_flight, msize], Options))#{
                            module => Module, fs => Fs, rights => Rights, client => Client}) of
        {ok, Grant} ->
            serve(Parent, Grant, Client, Options);
        {error, root} = Refused ->
            proc_lib:init_ack(Parent, Refused)
    end.

%% A grant whose root the core admitted, exported to its client and then
%% answered with its handle.
serve(Parent, Grant, Client, Options) ->
    %% The monitor comes first: a connection that ends at any time from here on,
    %% before the export or after it, ends the grant, and a port or process that
    %% has ended already is answered at once with a 'DOWN'.
    ConnectionMonitor = connection_monitor(Client, Options),
    case export(Client, maps:get(exports, Options, erx_dist)) of
        ok ->
            proc_lib:init_ack(Parent, {ok, self(), {self(), erx_fs_grant:tree(Grant), erx_fs_grant:rights(Grant)}}),
            loop(Grant, ConnectionMonitor);
        {error, _} = Refused ->
            proc_lib:init_ack(Parent, Refused)
    end.

-doc """
What proc_lib's crash report shows of a grant that crashes: its reason's name alone. The
grant holds its client's frames, a Bluetooth line's writes among them, in its state, its
mailbox and its frames' arguments, and exporting this is what makes the report hide all
three (erx_report:status/2). The grant takes no `sys` message, so no status is asked of it
otherwise.
""".
-spec format_status(#{atom() => term()}) -> #{atom() => term()}.
format_status(Status) ->
    erx_report:status(Status, #{}).

%% A grant ends with what Options' ends_with names: a port (a connection's) or a
%% process (a client domain's pid, or the holder of a grant for this domain), or
%% none. A grant for its own domain may leave it out; one for another domain that
%% names nothing is a caller's mistake, and its start fails.
connection_monitor(_Client, #{ends_with := none}) -> none;
connection_monitor(_Client, #{ends_with := Port}) when is_port(Port) -> erlang:monitor(port, Port);
connection_monitor(_Client, #{ends_with := Process}) when is_pid(Process) -> erlang:monitor(process, Process);
connection_monitor(own, #{}) -> none.

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
        {'DOWN', ConnectionMonitor, _PortOrProcess, _, _} when is_reference(ConnectionMonitor) ->
            ?MODULE:drain(perform(erx_fs_grant:client_ended(Grant)));
        {'DOWN', Ref, process, Pid, _} when is_reference(Ref), is_pid(Pid) ->
            ?MODULE:loop(perform(erx_fs_grant:down(Ref, Pid, Grant)), ConnectionMonitor);
        ?ERX_FS_ANSWER(Ref, Result) when is_reference(Ref) ->
            ?MODULE:loop(perform(erx_fs_grant:answered(Ref, Result, Grant)), ConnectionMonitor);
        Frame ->
            ?MODULE:loop(perform(erx_fs_grant:handle_frame(Frame, Grant)), ConnectionMonitor)
    end.

%% A grant whose client has ended drains (docs/design-files.md, "What waiting
%% holds"): it takes its keepers' answers and ends and its owners' ends, which
%% settle its fids' held requests and run their clunks, drops every other
%% message unread, and ends once the last clunk has run.
-doc false.
-spec drain(erx_fs_grant:grant()) -> no_return().
drain(Grant) ->
    case erx_fs_grant:drained(Grant) of
        true ->
            exit({shutdown, connection_ended});
        false ->
            receive
                {'DOWN', Ref, process, Pid, _} when is_reference(Ref), is_pid(Pid) ->
                    ?MODULE:drain(perform(erx_fs_grant:down(Ref, Pid, Grant)));
                ?ERX_FS_ANSWER(Ref, Result) when is_reference(Ref) ->
                    ?MODULE:drain(perform(erx_fs_grant:answered(Ref, Result, Grant)));
                _ ->
                    ?MODULE:drain(Grant)
            end
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
perform_effect({wait, Alias, Keeper, Request}, Grant) ->
    Ref = erlang:monitor(process, Keeper, [{alias, reply_demonitor}]),
    erlang:send(Keeper, ?ERX_FS_WAIT({self(), Ref}, Request)),
    erx_fs_grant:waiting(Alias, Ref, Grant);
perform_effect({flush, Keeper, Ref}, Grant) ->
    erlang:send(Keeper, ?ERX_FS_FLUSH({self(), Ref})),
    Grant.
