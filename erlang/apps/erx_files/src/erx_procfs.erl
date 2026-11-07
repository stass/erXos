%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_procfs).
-moduledoc """
`/proc`, the inspector's paths as a read-only file tree (docs/design-live.md,
"The /proc tree"): the `erx_fs` callback module, one grant per inspect
scope. The tree decides nothing itself: a walk, an open and a listing each
ask erx_inspector for the path through the grant's scope, and
erx_procfs_core turns the answers into nodes, entries and text. A path the
inspector answers `{error, scope}` reads as `enoent`, so the tree shows
nothing that erx:i/1 with the same scope does not.

* **Handle.** init/1 takes the scope and answers `Fs`, the scope and a
  counter of the grant's open snapshots, shared by the grant and its file
  processes.
* **Snapshots.** An open runs the inspector's query once: a `status` file
  holds its rendered record and a directory its entries, and reads see that
  snapshot until the clunk. A grant holds at most 256 snapshots; the 257th
  open answers `emfile`.
* **Attributes.** Every node is read-only, owned by uid 0, size 0 as a
  Linux `/proc` file is, so a reader reads to the end of the file.

In Phase 1 every runtime is the system domain's, and the kernel's safe
supervisor starts one grant of scope `all` with start_link/0, mounted at
`/proc` (docs/design-live.md: the system shell's tree).
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/0]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, statfs/1, clunk/2,
         read_mode/0]).

%% The tree's name, which a mount's {tree, Name} and attach's Aname name.
-define(TREE, <<"proc">>).
-define(POINT, <<"/proc">>).
%% The most open snapshots of one grant (design-live.md, Snapshots).
-define(MAX_SNAPSHOTS, 256).
%% statfs's type: Linux's PROC_SUPER_MAGIC.
-define(PROC_SUPER_MAGIC, 16#9fa0).
-define(DT_DIR, 4).
-define(DT_REG, 8).
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS)).

-doc """
Starts the system shell's tree, a grant of scope `all`, and mounts it at
`/proc`, after removing any entry an earlier instance left there.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    {ok, Grant} = erx_fs:start_link(?MODULE, all, ro),
    _ = erx_ns:unmount(?POINT),
    case erx_ns:mount(Grant, ?POINT, [{tree, ?TREE}, ro]) of
        ok ->
            {ok, Grant};
        {error, _} = Error ->
            %% A grant the supervisor does not know of must not outlive the start.
            unlink(Grant),
            exit(Grant, kill),
            Error
    end.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(Scope) when Scope =:= all; is_list(Scope) ->
    {ok, #{scope => Scope, snapshots => counters:new(1, [atomics])}}.

-doc false.
root(_Fs) ->
    Root = erx_procfs_core:root(),
    {ok, ?TREE, Root, qid(Root)}.

-doc false.
walk({dir, Dir}, Name, #{scope := Scope}) ->
    case erx_procfs_core:walk(Dir, Name, fun(Question) -> ask(Question, Scope) end) of
        {ok, Node} -> {ok, Node, qid(Node)};
        {error, _} = Error -> Error
    end;
walk(_Node, _Name, _Fs) ->
    {error, enotdir}.

-doc false.
getattr(Node, _Fs) ->
    {Type, Mode, Nlink} = case Node of
                              {dir, _} -> {?ERX_P9_S_IFDIR, 8#555, 2};
                              _ -> {?ERX_P9_S_IFREG, 8#444, 1}
                          end,
    {ok, #{valid => ?GETATTR_VALID, qid => qid(Node), mode => Type bor Mode,
           uid => 0, gid => 0, nlink => Nlink, rdev => 0, size => 0,
           blksize => 4096, blocks => 0,
           atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0,
           ctime_sec => 0, ctime_nsec => 0, btime_sec => 0, btime_nsec => 0,
           gen => 0, data_version => 0}}.

-doc false.
open(Node, Flags, #{scope := Scope, snapshots := Snapshots}) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> counted(Snapshots, fun() -> snapshot(Node, Scope) end);
        _ -> {error, erofs}
    end.

%% Takes one of the grant's snapshots for TakeSnapshot's answer, and gives
%% it back when there is no snapshot to hold. Opens run only in the grant's
%% process, the counter's one adder; clunks, in file processes, only
%% subtract, so the read and the add cannot race another add. A crash in the
%% inspector or the renderer answers eio, so it neither leaks a snapshot nor
%% ends the grant.
counted(Snapshots, TakeSnapshot) ->
    case counters:get(Snapshots, 1) < ?MAX_SNAPSHOTS of
        true ->
            counters:add(Snapshots, 1, 1),
            case taken(TakeSnapshot) of
                {ok, _Handle} = Opened ->
                    Opened;
                {error, _} = Error ->
                    counters:sub(Snapshots, 1, 1),
                    Error
            end;
        false ->
            {error, emfile}
    end.

taken(TakeSnapshot) ->
    try TakeSnapshot()
    catch
        _:_ -> {error, eio}
    end.

snapshot({dir, Path}, Scope) ->
    Entries = erx_procfs_core:listing(Path, listing_answer(Path, Scope), Scope),
    {ok, {entries, [{qid(Child), Index, dirent_type(Child), Name}
                    || {Index, {Name, Child}} <- lists:enumerate(1, Entries)]}};
snapshot({status, Path}, Scope) ->
    case erx_inspector:inspect(Path, Scope) of
        {error, scope} -> {error, enoent};
        Answer -> {ok, {bytes, erx_procfs_core:status(Answer, build(Scope))}}
    end;
snapshot({Marker, Path}, Scope) ->
    {ok, {bytes, erx_procfs_core:marker(Marker, ask({listing, Path}, Scope))}}.

%% The inspector's answer for a directory's listing, asked only of a
%% directory that lists the inspector's entries.
listing_answer(Path, Scope) ->
    case erx_procfs_core:lists_entries(Path) of
        true -> ask({listing, Path}, Scope);
        false -> none
    end.

-doc false.
read({bytes, Bytes}, Offset, _Count, _Fs) when Offset >= byte_size(Bytes) ->
    {ok, <<>>};
read({bytes, Bytes}, Offset, Count, _Fs) ->
    {ok, binary:part(Bytes, Offset, min(Count, byte_size(Bytes) - Offset))};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

%% An entry's offset is its place in the listing, so a read from Offset
%% continues after the entry that carried it.
-doc false.
readdir({entries, Entries}, Offset, Max, _Fs) ->
    {ok, lists:sublist(Entries, Offset + 1, Max)};
readdir({bytes, _}, _Offset, _Max, _Fs) ->
    {error, enotdir}.

-doc false.
statfs(_Fs) ->
    {ok, #{type => ?PROC_SUPER_MAGIC, bsize => 4096, blocks => 0, bfree => 0, bavail => 0,
           files => 0, ffree => 0, fsid => 0, namelen => 255}}.

-doc false.
clunk(_Handle, #{snapshots := Snapshots}) ->
    counters:sub(Snapshots, 1, 1),
    ok.

%% A read is a part of a snapshot the open already took.
-doc false.
read_mode() -> immediate.

%% ---------------------------------------------------------------------------
%% The inspector's answers
%% ---------------------------------------------------------------------------

%% Whether a path names something: a listing exists wherever the scope
%% reaches it, so no listing is built for a walk; any other path is asked.
ask({exists, Path}, Scope) ->
    case erx_schema:resolve(Path) of
        {ok, #{kind := listing} = Declaration} ->
            case erx_inspector:reachable(Path, {ok, Declaration}, Scope) of
                {ok, _Owner} -> {ok, listing};
                error -> {error, scope}
            end;
        _ ->
            erx_inspector:inspect(Path, Scope)
    end;
ask({listing, Path}, Scope) ->
    erx_inspector:inspect(Path, Scope).

%% Which build's projection a status file shows: development only when
%% the kernel reports the machine as a development build, as erx:i/1 does.
build(Scope) ->
    case erx_inspector:inspect([], Scope) of
        {ok, #{attrs := #{development := {kernel, {ok, true}}}}} -> development;
        _ -> release
    end.

%% A qid's path is a 64-bit hash of the node, the same for the node in
%% every grant.
qid(Node) ->
    Path = (erlang:phash2({erx_procfs, high, Node}, 1 bsl 32) bsl 32)
        bor erlang:phash2({erx_procfs, low, Node}, 1 bsl 32),
    {qid_type(Node), 0, Path}.

qid_type({dir, _}) -> ?ERX_P9_QTDIR;
qid_type(_File) -> 0.

dirent_type({dir, _}) -> ?DT_DIR;
dirent_type(_File) -> ?DT_REG.
