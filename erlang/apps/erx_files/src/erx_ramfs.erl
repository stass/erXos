%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs).
-moduledoc """
The domain's `/tmp`: the `erx_fs` callback module over `erx_ramfs_core`, whose
tree lives in the one grant that serves it (docs/design-tmp.md).

`init/1` makes an empty tree and answers it as an own tree of `erx_fs`, so the
tree exists only in the grant's process, as one `erx_ramfs_core` value. Each
callback turns its 9P2000.L arguments into one core request, runs it as one
`erx_ramfs_core:step/4` with a fresh stamp of the domain's version counter and
the time, and answers the reply in the protocol's terms with the next tree,
which the grant keeps for its next callback. The grant runs one callback at a
time, so each request is atomic against every other; no callback sends a
message or waits, so a request costs its client's message and the reply.

A walk adds the node it finds to the tree's walked set, and the grant's
`forget/2` takes it out once none of its fids names the node. The tree has
one grant, so a hold names no holder, and the grant's end ends the tree with
every hold it took; `erx_ramfs_sup` restarts `/tmp` whole.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([init/1, root/1, walk/3, forget/2, getattr/2, open/3, read/4, readdir/4,
         readlink/2, statfs/1, clunk/2, write/4, make/4,
         setattr/3, unlink/4, rename/5, fsync/2]).
-export([overhead_ratio/0]).

%% The tree's name: its root answers it, attach's Aname names it.
-define(TREE, <<"tmp">>).
%% What getattr answers: every basic field, and the data version.
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS
                        bor ?ERX_P9_GETATTR_MASK_DATA_VERSION)).
-define(NS, 1000000000).
%% ERTS's memory per charged byte beyond the charge, `o` of "The grant's heap
%% bound" (docs/design-tmp.md): set above the worst ratio a tree of empty files
%% reaches, whose node, map entries and listing entry cost about as much as
%% their fixed charges.
-define(OVERHEAD_RATIO, 1).

%% ---------------------------------------------------------------------------
%% The tree in the grant
%% ---------------------------------------------------------------------------

-doc "`o` of the grant's heap bound: ERTS's memory per charged byte beyond the charge.".
-spec overhead_ratio() -> pos_integer().
overhead_ratio() ->
    ?OVERHEAD_RATIO.

%% An empty tree under a cap of Cap bytes of charges, which only this grant
%% holds; a cap of 0 makes a `/tmp` that refuses every creation with enospc.
%% An exhausted version counter fails the grant's start.
-doc false.
init(Cap) when is_integer(Cap), Cap >= 0 ->
    {ok, Stamp} = erx_fs_version:draw(),
    {own, erx_ramfs_core:new(Cap, Stamp, time_ns())}.

%% One request as one step of the core. A release, a forget or a clunk, makes
%% and changes nothing that takes a version, so it draws no stamp and cannot fail.
step({Release, _} = Request, Tree) when Release =:= forget; Release =:= clunk ->
    erx_ramfs_core:step(Request, 1, time_ns(), Tree);
step(Request, Tree) ->
    case erx_fs_version:draw() of
        {ok, Stamp} -> erx_ramfs_core:step(Request, Stamp, time_ns(), Tree);
        {error, eio} -> {{error, eio}, Tree}
    end.

%% A step's reply turned into the protocol's terms by Map when it succeeded.
step(Request, Tree, Map) ->
    case step(Request, Tree) of
        {{ok, _} = Ok, Tree1} -> {Map(Ok), Tree1};
        {{ok, _, _} = Ok, Tree1} -> {Map(Ok), Tree1};
        {{ok, _, _, _} = Ok, Tree1} -> {Map(Ok), Tree1};
        Refused -> Refused
    end.

time_ns() ->
    os:system_time(nanosecond).

%% ---------------------------------------------------------------------------
%% erx_fs's callbacks: the protocol's terms into the core's and back
%% ---------------------------------------------------------------------------

-doc false.
root(Tree) ->
    Root = erx_ramfs_core:root(Tree),
    step({getattr, Root}, Tree, fun({ok, Attr}) -> {ok, ?TREE, Root, attr_qid(Attr)} end).

-doc false.
walk(Dir, Name, Tree) ->
    step({walk, Dir, Name}, Tree, fun({ok, Ino, Qid}) -> {ok, Ino, qid(Qid)} end).

-doc false.
forget(Ino, Tree) ->
    step({forget, Ino}, Tree).

-doc false.
getattr(Ino, Tree) ->
    step({getattr, Ino}, Tree, fun({ok, Attr}) -> {ok, attr(Attr)} end).

-doc false.
open(Ino, Flags, Tree) ->
    step({open, Ino, open_flags(Flags)}, Tree).

-doc false.
read(Handle, Offset, Count, Tree) ->
    step({read, Handle, Offset, Count}, Tree).

-doc false.
readdir(Handle, Offset, Max, Tree) ->
    step({readdir, Handle, Offset, Max}, Tree,
         fun({ok, Entries}) ->
                 {ok, [{qid(Qid), Seq, dirent_type(Kind), Name}
                       || {{Kind, _, _} = Qid, Seq, Name} <- Entries]}
         end).

-doc false.
readlink(Ino, Tree) ->
    step({readlink, Ino}, Tree).

-doc false.
statfs(Tree) ->
    step(statfs, Tree, fun({ok, Statfs}) -> {ok, Statfs#{type => ?ERX_P9_MAGIC_TMPFS, fsid => 0}} end).

%% The core's clunk always succeeds; the fid ends either way.
-doc false.
clunk(Handle, Tree) ->
    {_, Tree1} = step({clunk, Handle}, Tree),
    {ok, Tree1}.

-doc false.
write(Handle, Offset, Data, Tree) ->
    step({write, Handle, Offset, Data}, Tree).

-doc false.
make(Dir, Name, What, Tree) ->
    step({make, Dir, Name, what(What)}, Tree,
         fun({ok, Ino, Qid, Handle}) -> {ok, Ino, qid(Qid), Handle};
            ({ok, Ino, Qid}) -> {ok, Ino, qid(Qid)}
         end).

-doc false.
setattr(Target, Attr, Tree) ->
    step({setattr, Target, changes(Attr)}, Tree).

-doc false.
unlink(Dir, Name, Kind, Tree) ->
    step({unlink, Dir, Name, Kind}, Tree).

-doc false.
rename(Dir, Name, NewDir, NewName, Tree) ->
    step({rename, Dir, Name, NewDir, NewName}, Tree).

-doc false.
fsync(Handle, Tree) ->
    step({fsync, Handle}, Tree).

%% ---------------------------------------------------------------------------
%% The mapping
%% ---------------------------------------------------------------------------

%% A qid's version is the low 32 bits of the node's; the full value travels
%% as getattr's data_version.
qid({Kind, Version, Ino}) ->
    {qid_type(Kind), Version band 16#ffffffff, Ino}.

attr_qid(#{kind := Kind, data_version := Version, ino := Ino}) ->
    qid({Kind, Version, Ino}).

qid_type(directory) -> ?ERX_P9_QTDIR;
qid_type(symlink) -> ?ERX_P9_QTSYMLINK;
qid_type(file) -> 0.

dirent_type(directory) -> ?ERX_P9_DT_DIR;
dirent_type(symlink) -> ?ERX_P9_DT_LNK;
dirent_type(file) -> ?ERX_P9_DT_REG.

mode_type(directory) -> ?ERX_P9_S_IFDIR;
mode_type(symlink) -> ?ERX_P9_S_IFLNK;
mode_type(file) -> ?ERX_P9_S_IFREG.

%% The owner and group are 0: the domain is one user who owns every file.
attr(#{kind := Kind, mode := Mode, nlink := Nlink, size := Size, blocks := Blocks,
       atime := Atime, mtime := Mtime, ctime := Ctime, data_version := Version} = Attr) ->
    #{valid => ?GETATTR_VALID, qid => attr_qid(Attr), mode => mode_type(Kind) bor Mode,
      uid => 0, gid => 0, nlink => Nlink, rdev => 0, size => Size,
      blksize => 4096, blocks => Blocks,
      atime_sec => Atime div ?NS, atime_nsec => Atime rem ?NS,
      mtime_sec => Mtime div ?NS, mtime_nsec => Mtime rem ?NS,
      ctime_sec => Ctime div ?NS, ctime_nsec => Ctime rem ?NS,
      btime_sec => 0, btime_nsec => 0, gen => 0, data_version => Version}.

%% Linux's open flags: the access mode, and of the rest those the tree acts
%% on; Linux ignores the others too. Access mode 3 is no access the core
%% knows, which it refuses with einval.
open_flags(Flags) ->
    Access = case Flags band ?ERX_P9_O_ACCMODE of
                 0 -> read;
                 ?ERX_P9_O_WRONLY -> write;
                 ?ERX_P9_O_RDWR -> read_write;
                 _ -> none
             end,
    {Access, [Option || {Bit, Option} <- [{?ERX_P9_O_TRUNC, trunc},
                                         {?ERX_P9_O_APPEND, append},
                                         {?ERX_P9_O_EXCL, excl}],
                        Flags band Bit =/= 0]}.

what({file, Mode, Flags}) -> {file, Mode, open_flags(Flags)};
%% The tree keeps stored directories, which outlive their maker: a mkdir's Owner is dropped.
what({directory, Mode, _Owner}) -> {directory, Mode};
what(What) -> What.

%% setattr's valid bits name the fields set; a time without its _SET bit is
%% the time of the step.
changes(#{valid := Valid, mode := Mode, uid := Uid, gid := Gid, size := Size,
          atime_sec := Asec, atime_nsec := Ansec, mtime_sec := Msec, mtime_nsec := Mnsec}) ->
    Fields = [{?ERX_P9_SETATTR_VALID_MODE, mode, Mode},
              {?ERX_P9_SETATTR_VALID_UID, uid, Uid},
              {?ERX_P9_SETATTR_VALID_GID, gid, Gid},
              {?ERX_P9_SETATTR_VALID_SIZE, size, Size},
              {?ERX_P9_SETATTR_VALID_ATIME, atime,
               time(Valid band ?ERX_P9_SETATTR_VALID_ATIME_SET, Asec, Ansec)},
              {?ERX_P9_SETATTR_VALID_MTIME, mtime,
               time(Valid band ?ERX_P9_SETATTR_VALID_MTIME_SET, Msec, Mnsec)}],
    maps:from_list([{Key, Value} || {Bit, Key, Value} <- Fields, Valid band Bit =/= 0]).

time(0, _Sec, _Nsec) -> now;
time(_Set, Sec, Nsec) -> Sec * ?NS + Nsec.
