%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fs_node).
-moduledoc """
What the made trees share: trees of the erx_fs behaviour whose nodes their
servers make from state they read rather than keep on a medium, `/proc`,
`/dev`, `/apps`, `/svc/machine`, a display's window tree and the fixed tree of
a session's export
(docs/design-files.md#serving-the-erx_fs-behaviour).

* **Attributes.** Every node is owned by uid 0 and has size 0 and no times,
  as a `/proc` file does; a directory has two links, and a file or a
  character device one.
* **A listing** is the entries the directory's open took, made by
  listing/1, and an entry's
  offset is its place in the listing, so a read from Offset continues after
  the entry that carried it.
* **A ctl file opens through a create.** prim_file opens every file it
  writes through a create, so a create of an existing ctl opens it for
  writing, as the tree's open does, unless it must make a new file
  (`O_EXCL`).

Each tree keeps its own nodes, modes, opens and statfs type; these are pure
functions of what it hands them.
""".

-include("generated/erx_abi.hrl").

-export([attr/3, statfs/1, listing/1, readdir/3, open_by_create/4]).

-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS)).

-doc """
The attributes of the node whose qid is Qid, a directory, a file or a
character device with permission bits Mode.
""".
-spec attr(erx_fs:qid(), dir | file | char, 0..8#7777) -> {ok, erx_fs:attr()}.
attr(Qid, Kind, Mode) ->
    {Type, Nlink} = case Kind of
                        dir -> {?ERX_P9_S_IFDIR, 2};
                        file -> {?ERX_P9_S_IFREG, 1};
                        char -> {?ERX_P9_S_IFCHR, 1}
                    end,
    {ok, #{valid => ?GETATTR_VALID, qid => Qid, mode => Type bor Mode,
           uid => 0, gid => 0, nlink => Nlink, rdev => 0, size => 0,
           blksize => ?ERX_PAGE_SIZE, blocks => 0,
           atime_sec => 0, atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0,
           ctime_sec => 0, ctime_nsec => 0, btime_sec => 0, btime_nsec => 0,
           gen => 0, data_version => 0}}.

-doc "The statfs answer of a tree of file system type Magic, which holds no blocks.".
-spec statfs(non_neg_integer()) -> {ok, erx_fs:statfs()}.
statfs(Magic) ->
    {ok, #{type => Magic, bsize => ?ERX_PAGE_SIZE, blocks => 0, bfree => 0, bavail => 0,
           files => 0, ffree => 0, fsid => 0, namelen => 255}}.

-doc """
The handle of a directory's open that lists Entries, each a qid, a dirent
type and a name, in that order.
""".
-spec listing([{erx_fs:qid(), 0..255, binary()}]) -> {entries, [erx_fs:dirent()]}.
listing(Entries) ->
    {entries, [{Qid, Offset, Type, Name} || {Offset, {Qid, Type, Name}} <- lists:enumerate(1, Entries)]}.

-doc """
Up to Max entries of a listing from Offset, for a Handle that listing/1
made; any other handle is no directory.
""".
-spec readdir(term(), non_neg_integer(), pos_integer()) -> {ok, [erx_fs:dirent()]} | {error, enotdir}.
readdir({entries, Entries}, Offset, Max) ->
    {ok, lists:sublist(Entries, Offset + 1, Max)};
readdir(_Handle, _Offset, _Max) ->
    {error, enotdir}.

-doc """
A create with Flags of the existing file Node, whose qid is Qid: the open
Open answers, run with Flags, or `eexist` when the create must make a new
file (`O_EXCL`).
""".
-spec open_by_create(term(), erx_fs:qid(), non_neg_integer(),
                     fun((non_neg_integer()) -> {ok, term()} | {error, file:posix()})) ->
          {ok, term(), erx_fs:qid(), term()} | {error, file:posix()}.
open_by_create(Node, Qid, Flags, Open) ->
    case Flags band ?ERX_P9_O_EXCL of
        0 ->
            case Open(Flags) of
                {ok, Handle} -> {ok, Node, Qid, Handle};
                {error, _} = Error -> Error
            end;
        _ ->
            {error, eexist}
    end.
