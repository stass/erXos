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

`init/1` answers either the tree's handle, `{ok, Fs}`, which never changes:
every callback receives it and none returns a new one, and a tree that
changes keeps its nodes behind it, in a process or on a medium, where every
grant reaches the same tree; or a tree of the grant's own, `{own, Tree}`, a
value only this grant holds, which every callback takes and answers anew with
its reply, so a step of it runs in the grant with no message (`/tmp`'s, of
docs/design-tmp.md). A callback's answer that is not one of its shapes
reaches the client as `eio`.
""".

-export([start_link/3, start_link/4, start_mounted/4, start_mounted/5, reserve_words/2]).
-export([init/2, loop/2, drain/1, format_status/1]).
-export([handle_tree/1]).
-export([open_permitted/3, search_permitted/1]).

-include("erx_fs_waits.hrl").

-define(OWNER_READ, 8#400).
-define(OWNER_WRITE, 8#200).
-define(OWNER_SEARCH, 8#100).

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
%% (docs/design-files.md, "A grant handle is built by its starter"), the source
%% erx_ns:mount/3 mounts, whose entry takes the tree from it.
-opaque grant_handle() :: {pid(), Tree :: binary(), erx_fs_grant:rights()}.

%% The grant's tree: {ok, Fs}, a handle to a tree kept elsewhere, the same for the
%% grant's life; or {own, Tree}, a tree value init made, which only this grant holds.
%% For an own tree every callback below takes the current Tree in Fs's place and
%% answers {Answer, Tree1}, forget {ok, Tree1}, and the grant keeps Tree1.
-type answer(Answer) :: Answer | {Answer, Tree1 :: term()}.
-callback init(Args :: term()) -> {ok, Fs :: term()} | {own, Tree :: term()}.
%% A tree whose grants a facet row's `tree` may root within it (abi/services/files.txt)
%% adds subtree: the init Args of a grant of the tree Args name, rooted at the root Tree
%% names for Grantee, the domain the grant is for and the principal its mint named
%% (erx_fs_grants:grantee/0), or {error, einval}. erx_fs_grants asks it before such a
%% grant starts; a tree without it starts no grant whose row states a tree.
-callback subtree(Args :: term(), Tree :: atom(), Grantee :: erx_fs_grants:grantee()) ->
              {ok, Args1 :: term()} | {error, einval}.
%% The tree the grant roots in: its name, which attach's Aname must match, and its root.
%% An error fails the grant's start, as an answer that fails the root's check does.
-callback root(Fs :: term()) ->
              answer({ok, Tree :: binary(), Node :: term(), qid()} | {error, file:posix()}).
-callback walk(Node :: term(), Name :: binary(), Fs :: term()) ->
              answer({ok, Node1 :: term(), qid()} | {error, file:posix()}).
%% A tree that adds forget keeps each node its walk, make or lcreate's make
%% answers alive for the calling grant until the grant forgets it or ends; the
%% grant forgets a node once none of its fids names it, and at once one whose
%% answer it refused. The one callback without a reply.
-callback forget(Node :: term(), Fs :: term()) -> term().
-callback getattr(Node :: term(), Fs :: term()) ->
              answer({ok, attr()} | {error, file:posix()}).
-callback open(Node :: term(), Flags :: non_neg_integer(), Fs :: term()) ->
              answer({ok, Handle :: term()} | {error, file:posix()}).
%% A read or a write that waits for an event answers {wait, Keeper, Request}:
%% the tree's Keeper answers it later, through erx_fs_waits ("Waiting requests").
-callback read(Handle :: term(), Offset :: non_neg_integer(),
               Count :: 1..65536, Fs :: term()) ->
              answer({ok, binary()} | {error, file:posix()} | wait()).
-callback readdir(Handle :: term(), Offset :: non_neg_integer(),
                  Max :: 1..256, Fs :: term()) ->
              answer({ok, [dirent()]} | {error, file:posix()}).
-callback readlink(Node :: term(), Fs :: term()) ->
              answer({ok, binary()} | {error, file:posix()}).
-callback statfs(Fs :: term()) -> answer({ok, statfs()}).
%% ok, or the errno of what the close could not complete; the fid ends
%% either way.
-callback clunk(Handle :: term(), Fs :: term()) -> answer(ok | {error, file:posix()}).
%% A tree that writes adds these; one without them is read-only (F5). write's At is
%% the offset the bytes were written at: the request's, or the file's end for an
%% append fid (design-files.md, "Open files and offsets").
-callback write(Handle :: term(), Offset :: non_neg_integer(), binary(),
                Fs :: term()) ->
              answer({ok, Count :: non_neg_integer(), At :: non_neg_integer()}
                    | {error, file:posix()} | wait()).
%% A {file, ...} make answers with the open Handle; every other kind without.
-callback make(Dir :: term(), Name :: binary(), What :: what(), Fs :: term()) ->
              answer({ok, Node :: term(), qid(), Handle :: term()}
                    | {ok, Node :: term(), qid()} | {error, file:posix()}).
-callback setattr(Target :: {open, Handle :: term()} | {node, Node :: term()},
                  Changes :: map(), Fs :: term()) ->
              answer(ok | {error, file:posix()}).
-callback unlink(Dir :: term(), Name :: binary(),
                 Kind :: file | directory | {node, Node :: term()},
                 Fs :: term()) ->
              answer(ok | {error, file:posix()}).
-callback rename(Dir :: term(), Name :: binary(), NewDir :: term(),
                 NewName :: binary(), Fs :: term()) ->
              answer(ok | {error, file:posix()}).
-callback fsync(Handle :: term(), Fs :: term()) ->
              answer(ok | {error, file:posix()}).
-callback xattr(Node :: term(), Op :: term(), Fs :: term()) ->
              answer({ok, term()} | {error, file:posix()}).
%% A tree whose node or handle terms can be larger than a few words adds
%% largest_node: the largest node or handle any of its grants answers, a term
%% the grant's heap reserve counts each fid's copies of (reserve_words/2).
-callback largest_node() -> term().
-optional_callbacks([subtree/3, forget/2, readlink/2, write/4, make/4, setattr/3,
                     unlink/4, rename/5, fsync/2, xattr/3, largest_node/0]).

%% The reserve's parts (reserve_words/2), in words. The grant's own state with no
%% fid, and each of its pool's fids at its largest, whatever its depth, as
%% erx_fs_grant:fid_words/2 measures it, with the tree's largest node, or a node
%% of a few words for a tree without largest_node/0. A collection meets the
%% bound with more than the live words: a full sweep with the young and old heaps
%% and the heap it copies into, a minor one with more (erl_gc.c,
%% minor_collection and major_collection). The reserve counts its heap words
%% three times, a factor /tmp's deep-fid case measures enough for a grant at its
%% bounds, not one ERTS guarantees (docs/todo-storage.md); binaries off the heap
%% count once. A request in flight counts its frame twice: the message and the
%% payload a callback may copy from it, both binaries off the heap.
-define(BASE_WORDS, 65536).
-define(SMALL_NODE, {node, 16#ffffffffffffffff}).
-define(COLLECTION_COPIES, 3).
-define(FRAME_COPIES, 2).
-define(DEFAULT_POOL, 4096).
-define(DEFAULT_IN_FLIGHT, 64).
-define(DEFAULT_MSIZE, 65560).

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
its handle carries, `{Pid, Tree, Rights}` (erx_ns:mount/3), after removing any
entry an earlier instance left there. So the entry's tree and rights are
the grant's, named once (docs/design-files.md, "Rights beneath an
entry"). A mount that fails ends the grant, which the caller's supervisor
does not know of, and answers its `{error, Reason}`.
""".
-spec start_mounted(module(), term(), erx_fs_grant:rights(), binary()) ->
          {ok, pid()} | {error, term()}.
start_mounted(Module, Args, Requested, Point) ->
    start_mounted(Module, Args, Requested, Point, #{}).

-doc "Serves and mounts one grant, as start_mounted/4 does, with start_link/4's `Options`.".
-spec start_mounted(module(), term(), erx_fs_grant:rights(), binary(), map()) ->
          {ok, pid()} | {error, term()}.
start_mounted(Module, Args, Requested, Point, Options) ->
    case start_link(Module, Args, Requested, Options) of
        {ok, Grant, {Grant, _Tree, Rights} = Handle} ->
            _ = erx_ns:unmount(Point),
            mounted(Grant, erx_ns:mount(Handle, Point, [Rights]));
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
(by default the reserve of reserve_words/2, which a tree of the grant's own
must add to), and `sensitive`, `true` for a grant whose state holds a tree of
files (`/tmp`'s), makes its process sensitive before `init/1` runs, so neither
`process_info/2`, a trace nor a crash dump shows its queue, its heap or its
dictionary (default `false`).

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
                   max_heap_size => pos_integer(), sensitive => boolean(),
                   ends_with => port() | pid() | none,
                   exports => module()}) ->
          {ok, pid(), grant_handle()} | {error, term()}.
start_link(Module, Args, Rights, Options) ->
    Bound = case Options of
                #{max_heap_size := Words} -> Words;
                #{} -> reserve_words(Module, Options)
            end,
    Heap = #{size => Bound, kill => true,
             include_shared_binaries => true},
    proc_lib:start_link(?MODULE, init, [self(), {Module, Args, Rights, Options}],
                        infinity, [{max_heap_size, Heap}]).

-doc """
What any grant of `Module`'s tree and these bounds may hold beside the tree's own
state, in words: its root and state, its pool of fids each at its largest, with
its place, its per-node counts and its owner's monitor, and its requests in
flight with a full frame each (docs/design-tmp.md, "The grant's heap bound"). The
same for every grant of the same tree and bounds, and never zero.
""".
-spec reserve_words(module(), #{pool => pos_integer(), in_flight => pos_integer(),
                                msize => pos_integer(), atom() => term()}) -> pos_integer().
reserve_words(Module, Options) ->
    Pool = maps:get(pool, Options, ?DEFAULT_POOL),
    InFlight = maps:get(in_flight, Options, ?DEFAULT_IN_FLIGHT),
    Msize = maps:get(msize, Options, ?DEFAULT_MSIZE),
    {FidHeap, FidOffHeap} = erx_fs_grant:fid_words(Pool, largest_node(Module)),
    ?COLLECTION_COPIES * (?BASE_WORDS + Pool * FidHeap) + Pool * FidOffHeap
        + InFlight * ceil(?FRAME_COPIES * Msize / erlang:system_info(wordsize)).

largest_node(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    case erlang:function_exported(Module, largest_node, 0) of
        true -> Module:largest_node();
        false -> ?SMALL_NODE
    end.

-doc false.
-spec init(pid(), {module(), term(), erx_fs_grant:rights(), map()}) -> no_return().
init(Parent, {Module, Args, Rights, Options}) ->
    _ = process_flag(sensitive, maps:get(sensitive, Options, false)),
    {module, Module} = code:ensure_loaded(Module),
    Fs = case Module:init(Args) of
             {ok, _} = Handle -> Handle;
             {own, _} = Own -> Own
         end,
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
            proc_lib:init_ack(Parent, {ok, self(), handle(Grant)}),
            loop(Grant, ConnectionMonitor);
        {error, _} = Refused ->
            proc_lib:init_ack(Parent, Refused)
    end.

%% The grant's handle: its pid, the tree it reaches and the rights it serves.
handle(Grant) ->
    {self(), erx_fs_grant:tree(Grant), erx_fs_grant:rights(Grant)}.

-doc """
The tree a grant's handle carries, the one its callback module's `root` names: what
a grant started for another domain answers its mint with beside its pid
(erx_fs_grants:grant/3,4; docs/design-system.md, "the mint's reply").
""".
-spec handle_tree(grant_handle()) -> binary().
handle_tree({_Pid, Tree, _Rights}) ->
    Tree.

-doc """
Whether a node of Mode opens for Access, and for a truncation when
Truncate: the permission rule erx_ramfs_core's and erx_f2fs's opens share. An
open needs the owner's bits for its access, `r` to read, `w` to write,
both for both, and `w` for a truncation, whoever opens it; the domain is
one user who is no superuser (docs/design-tmp.md, "Permissions").
""".
-spec open_permitted(Mode :: non_neg_integer(), read | write | read_write, Truncate :: boolean()) ->
          ok | {error, eacces}.
open_permitted(Mode, Access, Truncate) ->
    Bits = case Access of
               read -> ?OWNER_READ;
               write -> ?OWNER_WRITE;
               read_write -> ?OWNER_READ bor ?OWNER_WRITE
           end,
    Needed = case Truncate of
                 true -> Bits bor ?OWNER_WRITE;
                 false -> Bits
             end,
    case Mode band Needed of
        Needed -> ok;
        _ -> {error, eacces}
    end.

-doc """
Whether a directory of Mode may be searched, by a walk or any other lookup of
a name in it: the rule erx_ramfs_core's and erx_f2fs's walks share. A
search needs the owner's `x` bit, whoever searches; the domain is one user
who is no superuser (docs/design-tmp.md, "Permissions").
""".
-spec search_permitted(Mode :: non_neg_integer()) -> ok | {error, eacces}.
search_permitted(Mode) ->
    case Mode band ?OWNER_SEARCH of
        0 -> {error, eacces};
        _ -> ok
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
