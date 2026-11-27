%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs).
-moduledoc """
The erx_fs callback module of an F2FS volume (docs/design-f2fs.md, "The
interface"): every callback of erx_fs, each one call to the volume
process, erx_f2fs_volume, which answers it, so nothing is kept in the
grant that calls it. The tree's handle is the volume's pid; a node is a
nid and a handle its nid and the access it was opened for (erx_f2fs_request:handle()). A read-only volume answers every
mutation erofs, a read-write one those it does not offer enotsup; xattr answers enotsup here, as the design
states for every volume. clunk has nothing to release.
""".
-behaviour(erx_fs).

-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, readdir/4, readlink/2, statfs/1,
         clunk/2, write/4, make/4, setattr/3, unlink/4, rename/5, fsync/2, xattr/3]).

%% The tree littlefs serves, which F2FS replaces.
-define(TREE, <<"data">>).

-type nid() :: non_neg_integer().
-type error() :: {error, file:posix()}.
-type handle() :: erx_f2fs_request:handle().

-doc false.
-spec init(pid()) -> {ok, pid()}.
init(Volume) when is_pid(Volume) -> {ok, Volume}.

-doc false.
-spec root(pid()) -> {ok, binary(), nid(), erx_fs:qid()} | error().
root(Volume) ->
    case erx_f2fs_volume:call(Volume, root) of
        {ok, Root, Qid} -> {ok, ?TREE, Root, Qid};
        {error, _} = Error -> Error
    end.

-doc false.
-spec walk(nid(), binary(), pid()) -> {ok, nid(), erx_fs:qid()} | error().
walk(Dir, Name, Volume) -> erx_f2fs_volume:call(Volume, {walk, Dir, Name}).
-doc false.
-spec getattr(nid(), pid()) -> {ok, erx_fs:attr()} | error().
getattr(Node, Volume) -> erx_f2fs_volume:call(Volume, {getattr, Node}).
-doc false.
-spec open(nid(), non_neg_integer(), pid()) -> {ok, handle()} | error().
open(Node, Flags, Volume) -> erx_f2fs_volume:call(Volume, {open, Node, Flags}).
-doc false.
-spec read(handle(), non_neg_integer(), pos_integer(), pid()) -> {ok, binary()} | error().
read(Handle, Offset, Count, Volume) -> erx_f2fs_volume:call(Volume, {read, Handle, Offset, Count}).
-doc false.
-spec readdir(handle(), non_neg_integer(), pos_integer(), pid()) -> {ok, [erx_fs:dirent()]} | error().
readdir(Handle, Offset, Max, Volume) -> erx_f2fs_volume:call(Volume, {readdir, Handle, Offset, Max}).
-doc false.
-spec readlink(nid(), pid()) -> {ok, binary()} | error().
readlink(Node, Volume) -> erx_f2fs_volume:call(Volume, {readlink, Node}).
-doc false.
-spec statfs(pid()) -> {ok, erx_fs:statfs()} | error().
statfs(Volume) -> erx_f2fs_volume:call(Volume, statfs).
-doc false.
-spec clunk(handle(), pid()) -> ok.
clunk(_Handle, _Volume) -> ok.
-doc false.
-spec write(handle(), non_neg_integer(), binary(), pid()) ->
          {ok, non_neg_integer(), non_neg_integer()} | error().
write(Handle, Offset, Bytes, Volume) -> erx_f2fs_volume:call(Volume, {write, {Handle, Offset, Bytes}}).
-doc false.
-spec make(nid(), binary(), erx_fs:what(), pid()) -> error().
make(Dir, Name, What, Volume) -> erx_f2fs_volume:call(Volume, {make, {Dir, Name, What}}).
-doc false.
-spec setattr(term(), map(), pid()) -> error().
setattr(Target, Changes, Volume) -> erx_f2fs_volume:call(Volume, {setattr, {Target, Changes}}).
-doc false.
-spec unlink(nid(), binary(), term(), pid()) -> error().
unlink(Dir, Name, Kind, Volume) -> erx_f2fs_volume:call(Volume, {unlink, {Dir, Name, Kind}}).
-doc false.
-spec rename(nid(), binary(), nid(), binary(), pid()) -> error().
rename(Dir, Name, NewDir, NewName, Volume) ->
    erx_f2fs_volume:call(Volume, {rename, {Dir, Name, NewDir, NewName}}).
-doc false.
-spec fsync(handle(), pid()) -> ok | error().
fsync(Handle, Volume) -> erx_f2fs_volume:call(Volume, {fsync, Handle}).
-doc false.
-spec xattr(nid(), term(), pid()) -> {error, enotsup}.
xattr(_Node, _Op, _Volume) -> {error, enotsup}.
