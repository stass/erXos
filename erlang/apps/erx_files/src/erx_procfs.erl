%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_procfs).
-moduledoc """
`/proc`, the inspector's paths as a read-only file tree (docs/design-live.md,
"The /proc tree"): the `erx_fs` callback module. The tree holds no scope
and decides nothing itself: a walk, an open and a listing each ask
erx_inspector:inspect/2 for the path, which outside the system domain
goes through the domain's inspect facet, and erx_procfs_core turns the
answers into nodes, entries and text. A path the inspector answers
`{error, scope}`, and every path of a domain that holds no inspect facet
or whose facet has ended (`{error, no_facet}`), reads as `enoent`, so the tree shows nothing that
erx:i/1 in the same domain does not.

* **Handle.** init/1 takes the inspector to ask, erx_inspector:inspect/2
  or a host test's stand-in, and answers `Fs`, it and a counter of the
  grant's open snapshots, shared by the grant and its file processes.
* **Snapshots.** An open runs the inspector's query once: a `status` file
  holds its rendered record and a directory its entries, and reads see that
  snapshot until the clunk. The file of an append-only path, such as
  `/proc/kernel/log`, runs it once a page, from sequence number 0, each
  page from where the one before stopped, while the inspector answers
  partial and the entries fit the file's 64 KiB, for at most 16 pages. A grant holds at most 256 snapshots; the 257th
  open answers `emfile`.
* **Attributes.** Every node is read-only, owned by uid 0, size 0 as a
  Linux `/proc` file is, so a reader reads to the end of the file.

The kernel's safe supervisor starts one grant in every runtime with
start_link/0, mounted at `/proc`: in the system domain its queries run
in a local query worker at scope `all`, and in every other domain they
go through that domain's inspect facet.
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
%% The most pages one open of an append-only path asks for.
-define(MAX_PAGES, 16).
%% The most bytes of one file (design-live.md, Snapshots): once the entries
%% asked for hold that many, the file is cut there anyway.
-define(MAX_FILE, 65536).
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS)).

-doc """
Starts this domain's tree, a grant over erx_inspector:inspect/2, and mounts
it at `/proc`, after removing any entry an earlier instance left there.
""".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    {ok, Grant} = erx_fs:start_link(?MODULE, fun erx_inspector:inspect/2, ro),
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
init(Inspect) when is_function(Inspect, 2) ->
    {ok, #{inspect => Inspect, snapshots => counters:new(1, [atomics])}}.

-doc false.
root(_Fs) ->
    Root = erx_procfs_core:root(),
    {ok, ?TREE, Root, qid(Root)}.

-doc false.
walk({dir, Dir}, Name, #{inspect := Inspect}) ->
    case erx_procfs_core:walk(Dir, Name, fun(Question) -> ask(Question, Inspect) end) of
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
           blksize => ?ERX_PAGE_SIZE, blocks => 0,
           atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0,
           ctime_sec => 0, ctime_nsec => 0, btime_sec => 0, btime_nsec => 0,
           gen => 0, data_version => 0}}.

-doc false.
open(Node, Flags, #{inspect := Inspect, snapshots := Snapshots}) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> counted(Snapshots, fun() -> snapshot(Node, Inspect) end);
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

snapshot({dir, Path}, Inspect) ->
    Lookup = fun(Question) -> ask(Question, Inspect) end,
    Entries = erx_procfs_core:listing(Path, listing_answer(Path, Inspect), Lookup),
    {ok, {entries, [{qid(Child), Index, dirent_type(Child), Name}
                    || {Index, {Name, Child}} <- lists:enumerate(1, Entries)]}};
snapshot({status, Path}, Inspect) ->
    Answer = Inspect(Path, #{}),
    case erx_procfs_core:named(Answer) of
        true -> {ok, {bytes, erx_procfs_core:status(Answer, build(Inspect))}};
        false -> {error, enoent}
    end;
snapshot({lines, Path}, Inspect) ->
    [First | _] = Answers = pages(Path, 0, Inspect, ?MAX_PAGES, 0),
    case erx_procfs_core:named(First) of
        true -> {ok, {bytes, erx_procfs_core:lines(Answers)}};
        false -> {error, enoent}
    end;
snapshot({Marker, Path}, Inspect) ->
    {ok, {bytes, erx_procfs_core:marker(Marker, ask({listing, Path}, Inspect))}}.

%% The inspector's answers for an append-only path's pages from Offset on:
%% the next page is asked from where a partial one stopped, up to Left
%% pages, and only while the entries so far, Bytes of values, fit the
%% file, since each entry's line is at least its value's bytes.
pages(Path, Offset, Inspect, Left, Bytes) ->
    case Inspect(Path, #{offset => Offset}) of
        {ok, #{entries := {partial, Next, Entries}}} = Answer when Left > 1 ->
            Held = Bytes + lists:sum([byte_size(Value) || {_Sequence, Value} <- Entries]),
            case Held < ?MAX_FILE of
                true -> [Answer | pages(Path, Next, Inspect, Left - 1, Held)];
                false -> [Answer]
            end;
        Answer ->
            [Answer]
    end.

%% The inspector's answer for a directory's listing, asked only of a
%% directory that lists the inspector's entries.
listing_answer(Path, Inspect) ->
    case erx_procfs_core:lists_entries(Path) of
        true -> ask({listing, Path}, Inspect);
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
    {ok, #{type => ?ERX_P9_MAGIC_PROC, bsize => ?ERX_PAGE_SIZE, blocks => 0, bfree => 0, bavail => 0,
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

%% The inspector's answer for a path, whether a walk asks if it names
%% something or a directory asks for its listing: the tree keeps no scope
%% and decides nothing itself, so both are the path's record as the
%% domain's inspect facet answers it.
ask({Question, Path}, Inspect) when Question =:= exists; Question =:= listing ->
    Inspect(Path, #{}).

%% Which build's projection a status file shows: development only when
%% the kernel reports the machine as a development build, as erx:i/1 does.
build(Inspect) ->
    case Inspect([], #{}) of
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

dirent_type({dir, _}) -> ?ERX_P9_DT_DIR;
dirent_type(_File) -> ?ERX_P9_DT_REG.
