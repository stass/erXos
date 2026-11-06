%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs).
-moduledoc """
The domain's `/tmp`: the `erx_fs` callback module over `erx_ramfs_core`, and
the one tree process that holds the tree (docs/design-tmp.md).

The tree exists only in the tree process, as one `erx_ramfs_core` value. Each
callback, in the grant or in a file's owner, turns its 9P2000.L arguments into
one core request, sends it to the tree process and waits for the reply, which
it turns back into the protocol's terms. The tree process runs every request
as one `erx_ramfs_core:step/4` with a fresh stamp of the domain's version
counter and the time, in arrival order, so each request is atomic against
every other, and it never waits for anyone.

The handle `erx_fs` passes every callback, `Server`, is the tree process's pid
and a reference the tree process made at its start and published under its
registered name for the grant. It acts only on a request that carries that
reference and wants its reply at an alias of its own node, so a process that
learns its pid reaches the tree only through `erx_fs`'s checks. Any other
message is dropped, and a request the core does not know answers `einval`.

A walk holds the node it finds for the grant that asked, the caller of
`walk/3`, until that grant's `forget/2` of it, which is the one request sent
without waiting for a reply: messages from one process arrive in the order
sent, so a forget never overtakes a later walk from the same grant. The tree
process monitors each grant that walked, and its end lets go of every node
it held, so a grant that crashes leaks nothing.
If the tree process ends anyway, every caller waiting on it ends with it,
and `erx_ramfs_sup` restarts `/tmp` whole.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/2, serve/1]).
-export([init/1, root/1, walk/3, forget/2, getattr/2, open/3, read/4, readdir/4,
         readlink/2, statfs/1, clunk/2, read_mode/0, write/4, make/4,
         setattr/3, unlink/4, rename/5, fsync/2]).

%% The tree's name, which a mount's {tree, Name} and attach's Aname name.
-define(TREE, <<"tmp">>).
%% statfs's type: Linux's TMPFS_MAGIC.
-define(TMPFS_MAGIC, 16#01021994).
%% A listing's entry types, Linux's DT_ values as readdir carries them.
-define(DT_DIR, 4).
-define(DT_REG, 8).
-define(DT_LNK, 10).
%% What getattr answers: every basic field, and the data version.
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_RDEV bor ?ERX_P9_GETATTR_MASK_ATIME
                        bor ?ERX_P9_GETATTR_MASK_MTIME bor ?ERX_P9_GETATTR_MASK_CTIME
                        bor ?ERX_P9_GETATTR_MASK_INO bor ?ERX_P9_GETATTR_MASK_SIZE
                        bor ?ERX_P9_GETATTR_MASK_BLOCKS
                        bor ?ERX_P9_GETATTR_MASK_DATA_VERSION)).
-define(NS, 1000000000).

%% ---------------------------------------------------------------------------
%% The tree process
%% ---------------------------------------------------------------------------

-doc """
Starts the tree process with an empty tree under a cap of `Cap` bytes of
charges, registered as `Name`, under which it publishes its handle for the
grant; a cap of 0 makes a `/tmp` that refuses every creation with `enospc`.
""".
-spec start_link(non_neg_integer(), atom()) -> {ok, pid()} | {error, term()}.
start_link(Cap, Name) when is_integer(Cap), Cap >= 0, is_atom(Name) ->
    proc_lib:start_link(?MODULE, serve, [{start, self(), Cap, Name}]).

-doc false.
-spec serve({start, pid(), non_neg_integer(), atom()}
            | {reference(), erx_ramfs_core:ino(), erx_ramfs_core:tree(),
               #{pid() => reference()}}) -> no_return().
serve({start, Parent, Cap, Name}) ->
    %% A crash report shows no queued request, whose data is the domain's files.
    _ = process_flag(sensitive, true),
    true = register(Name, self()),
    Secret = make_ref(),
    case erx_fs_version:draw() of
        {ok, Stamp} ->
            Tree = erx_ramfs_core:new(Cap, Stamp, time_ns()),
            persistent_term:put({?MODULE, Name}, {self(), Secret}),
            proc_lib:init_ack(Parent, {ok, self()}),
            ?MODULE:serve({Secret, Stamp, Tree, #{}});
        {error, _} = Error ->
            proc_lib:init_fail(Parent, Error, {exit, normal})
    end;
%% Each request is handled whole, and the next awaited through a remote call,
%% so the tree process moves to new code between requests. Holders maps each
%% grant that walked to the monitor whose DOWN ends its holds.
serve({Secret, Root, Tree, Holders}) ->
    receive
        {?MODULE, Secret, Alias, Request} when is_reference(Alias), node(Alias) =:= node() ->
            {Reply, Tree1} = step(Request, Root, Tree),
            erlang:send(Alias, {?MODULE, Alias, Reply}),
            ?MODULE:serve({Secret, Root, Tree1, watched(Request, Holders)});
        {?MODULE, Secret, forget, Ino, Holder} ->
            {ok, Tree1} = step({forget, Ino, Holder}, Root, Tree),
            ?MODULE:serve({Secret, Root, Tree1, Holders});
        {'DOWN', Ref, process, Holder, _} when map_get(Holder, Holders) =:= Ref ->
            {ok, Tree1} = step({forget_holder, Holder}, Root, Tree),
            ?MODULE:serve({Secret, Root, Tree1, maps:remove(Holder, Holders)});
        _ ->
            ?MODULE:serve({Secret, Root, Tree, Holders})
    end.

%% A grant is monitored from its first walk until its end.
watched({walk, _, _, Holder}, Holders) when is_pid(Holder), not is_map_key(Holder, Holders) ->
    Holders#{Holder => erlang:monitor(process, Holder)};
watched(_Request, Holders) ->
    Holders.

%% A walk holds for the grant that sent it, which the tree process monitors.
step({walk, _, _, Holder}, _Root, Tree) when not is_pid(Holder) ->
    {{error, einval}, Tree};
%% The root is the tree process's own: the core names it by the first stamp.
step(root, Root, Tree) ->
    {{ok, Root}, Tree};
%% A release makes and changes nothing that takes a version, so it draws no
%% stamp and cannot fail.
step({forget, _, _} = Request, Root, Tree) ->
    erx_ramfs_core:step(Request, Root, time_ns(), Tree);
step({forget_holder, _} = Request, Root, Tree) ->
    erx_ramfs_core:step(Request, Root, time_ns(), Tree);
step(Request, _Root, Tree) ->
    case erx_fs_version:draw() of
        {ok, Stamp} -> erx_ramfs_core:step(Request, Stamp, time_ns(), Tree);
        {error, eio} -> {{error, eio}, Tree}
    end.

time_ns() ->
    os:system_time(nanosecond).

%% One request to the tree process, from a grant or an owner. The alias ends
%% with the reply, and the monitor turns the tree's end into the caller's.
call({Pid, Secret}, Request) ->
    Alias = erlang:monitor(process, Pid, [{alias, reply_demonitor}]),
    erlang:send(Pid, {?MODULE, Secret, Alias, Request}),
    receive
        {?MODULE, Alias, Reply} -> Reply;
        {'DOWN', Alias, process, _, Reason} -> exit({erx_ramfs, Reason})
    end.

%% ---------------------------------------------------------------------------
%% erx_fs's callbacks: the protocol's terms into the core's and back
%% ---------------------------------------------------------------------------

%% The handle of the tree process the supervisor started just before the
%% grant: a restart starts the tree first, so no earlier instance's is found.
-doc false.
init(Name) when is_atom(Name) ->
    {Pid, Secret} = persistent_term:get({?MODULE, Name}),
    true = Pid =:= whereis(Name),
    {ok, {Pid, Secret}}.

-doc false.
root(Server) ->
    {ok, Root} = call(Server, root),
    {ok, Attr} = call(Server, {getattr, Root}),
    {ok, ?TREE, Root, attr_qid(Attr)}.

-doc false.
walk(Dir, Name, Server) ->
    case call(Server, {walk, Dir, Name, self()}) of
        {ok, Ino, Qid} -> {ok, Ino, qid(Qid)};
        Error -> Error
    end.

-doc false.
forget(Ino, {Pid, Secret}) ->
    erlang:send(Pid, {?MODULE, Secret, forget, Ino, self()}),
    ok.

-doc false.
getattr(Ino, Server) ->
    case call(Server, {getattr, Ino}) of
        {ok, Attr} -> {ok, attr(Attr)};
        Error -> Error
    end.

-doc false.
open(Ino, Flags, Server) ->
    call(Server, {open, Ino, open_flags(Flags)}).

-doc false.
read(Handle, Offset, Count, Server) ->
    call(Server, {read, Handle, Offset, Count}).

-doc false.
readdir(Handle, Offset, Max, Server) ->
    case call(Server, {readdir, Handle, Offset, Max}) of
        {ok, Entries} ->
            {ok, [{qid(Qid), Seq, dirent_type(Kind), Name}
                  || {{Kind, _, _} = Qid, Seq, Name} <- Entries]};
        Error ->
            Error
    end.

-doc false.
readlink(Ino, Server) ->
    call(Server, {readlink, Ino}).

-doc false.
statfs(Server) ->
    {ok, Statfs} = call(Server, statfs),
    {ok, Statfs#{type => ?TMPFS_MAGIC, fsid => 0}}.

-doc false.
clunk(Handle, Server) ->
    _ = call(Server, {clunk, Handle}),
    ok.

-doc false.
read_mode() ->
    immediate.

-doc false.
write(Handle, Offset, Data, Server) ->
    call(Server, {write, Handle, Offset, Data}).

-doc false.
make(Dir, Name, What, Server) ->
    case call(Server, {make, Dir, Name, what(What)}) of
        {ok, Ino, Qid, Handle} -> {ok, Ino, qid(Qid), Handle};
        {ok, Ino, Qid} -> {ok, Ino, qid(Qid)};
        Error -> Error
    end.

-doc false.
setattr(Target, Attr, Server) ->
    call(Server, {setattr, Target, changes(Attr)}).

-doc false.
unlink(Dir, Name, Kind, Server) ->
    call(Server, {unlink, Dir, Name, Kind}).

-doc false.
rename(Dir, Name, NewDir, NewName, Server) ->
    call(Server, {rename, Dir, Name, NewDir, NewName}).

-doc false.
fsync(Handle, Server) ->
    call(Server, {fsync, Handle}).

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

dirent_type(directory) -> ?DT_DIR;
dirent_type(symlink) -> ?DT_LNK;
dirent_type(file) -> ?DT_REG.

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
