%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_request).
-moduledoc """
Each request of the read-only volume as steps over erx_f2fs_core
(docs/design-f2fs.md, "The interface" and "Read-only mounts"), pure: the
steps a request takes, the answer each gives and every errno but the
medium's eio. The volume process, erx_f2fs_volume, does the effects: it
runs each step through its need loop over the window and its cache,
answers a failed check or read eio, and logs it.

A request's first move is start/2's. A move is {reply, Reply}, the
request's answer; {then, Step}, a step to run; or {failed, Nid, Failure},
a check of the medium that node Nid broke, which the volume answers eio.
A step is a function of the volume and the blocks read so far that
answers a move or {need, Addresses}, after which the volume reads those
blocks and runs it again from the start. Each step reads one inode and
what lies under it, so the blocks it pins in the cache while it runs are
those of one node's operation and the summary blocks of the segments its
data blocks lie in.

A node is its nid. A qid's path is the nid in its low 32 bits and the
inode's i_generation in its high 32; its version is 0, since nothing on a
read-only volume changes. Every mutation answers erofs, an open for
writing or truncation among them, and a directory opened for writing
eisdir; a symlink is never opened, as the server follows none (eloop),
and a device, FIFO or socket answers enotsup.

A read-write volume's requests read its view (erx_f2fs_core:view/1), a
volume map with the state's dirty nodes, and on it a regular file opens
for writing, a write is the first step of "Operations", answering the move
{write, Ino, Blocks, Size, Reply}: at most ?WRITE_BLOCKS whole blocks in file
order, each {Block, Bytes} merged over the old block's bytes below the
file's size and zeros at and past it, the size once they are set and the
write's answer, naming the bytes they take, so a write may be short. The
volume claims the blocks, sets them in their slots and writes them
(erx_f2fs_volume). An fsync answers the move checkpoint. A write into an inline file, one that starts past the block
holding the size (which needs the truncate that raises a size) or one
whose slot no node holds, an open for truncation or for appending and
the other mutations answer enotsup. An open for writing needs the owner's
permission bits for its access (eacces), and a handle answers only the
access it was opened for (ebadf).

A readdir's entry offset is the position past the entry's first slot,
where the next call resumes ("Directories"); "." is listed with the
directory's own qid and ".." as its slot names it. A readdir calls the
core's readdir from the position it was given, and again from the next
position, until the entries reach the request's maximum or the
directory's end, a step each, then reads each entry's inode for its qid,
a step each. Its core calls are bounded by what the directory claims to
hold. A core step takes a dentry block, or a run of empty slots that ends
at a dentry block, at a child node, at the end of a node or the inode's
array, or is one of the inode's five node ids of 0. So a directory of D
dentry blocks and N nodes, its inode among them, takes at most 2D + 2N + 4
steps, one more when a call starts inside a run, and its i_blocks B
counts all of them ([F 42]): at most 2B + 5 steps. Each core call but the
last takes eight, so the listing takes at most (2B + 5) div 8 + 1 calls,
and a request past that, with B no more than the volume's user blocks,
fails {dir, blocks}. A directory that names one block in every slot thus
costs a request about a quarter of a core call per block it claims, not
one per slot.
""".

-export([start/2]).
-export_type([request/0, handle/0, step/0, move/0, failure/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
%% getattr's blocks count 512-byte units, as stat's st_blocks does.
-define(STAT_BLOCK, 512).
%% The blocks one write takes at most, so a step needs at most one free section.
-define(WRITE_BLOCKS, 64).
-define(NAME_MAX, ?ERX_F2FS_NAME_LEN_MAX).
-define(GETATTR_VALID, (?ERX_P9_GETATTR_MASK_MODE bor ?ERX_P9_GETATTR_MASK_NLINK
                        bor ?ERX_P9_GETATTR_MASK_UID bor ?ERX_P9_GETATTR_MASK_GID
                        bor ?ERX_P9_GETATTR_MASK_ATIME bor ?ERX_P9_GETATTR_MASK_MTIME
                        bor ?ERX_P9_GETATTR_MASK_CTIME bor ?ERX_P9_GETATTR_MASK_INO
                        bor ?ERX_P9_GETATTR_MASK_SIZE bor ?ERX_P9_GETATTR_MASK_BLOCKS
                        bor ?ERX_P9_GETATTR_MASK_GEN bor ?ERX_P9_GETATTR_MASK_DATA_VERSION)).

-doc """
A request: the root, or one of erx_fs's callbacks on a node, a nid, or a
handle.
""".
-type request() :: root | {walk, non_neg_integer(), binary()} | {getattr, non_neg_integer()}
                 | {open, non_neg_integer(), non_neg_integer()}
                 | {read, handle(), non_neg_integer(), pos_integer()}
                 | {readdir, handle(), non_neg_integer(), pos_integer()}
                 | {readlink, non_neg_integer()} | statfs | {fsync, handle()}
                 | {write | make | setattr | unlink | rename, term()}.
-doc """
An open node's handle: its nid and the access it was opened for. A read
through a handle not opened for reading, and a write through one not
opened for writing, answer ebadf, as erx_ramfs_core's do.
""".
-type handle() :: {non_neg_integer(), read | write | read_write}.
-doc "A check of the medium a step broke: the core's, or a readdir past its bound.".
-type failure() :: erx_f2fs_core:failure() | {dir, blocks}.
-doc "What a request does next.".
-type move() :: {reply, term()} | {then, step()} | {failed, non_neg_integer(), failure()} |
                checkpoint |
                {write, non_neg_integer(), [{non_neg_integer(), binary()}], non_neg_integer(),
                 {ok, pos_integer(), non_neg_integer()}}.
-doc "One step of a request, over the volume and the blocks read so far.".
-type step() :: fun((erx_f2fs_core:volume(), #{non_neg_integer() => binary()}) ->
                        move() | {need, [non_neg_integer()]}).

-doc "Request's first move on Volume.".
-spec start(request(), erx_f2fs_core:volume()) -> move().
start(root, #{superblock := #{root_ino := Root}}) ->
    {then, step(Root, fun(Inode, _, _) -> {reply, {ok, Root, qid(Inode)}} end)};
start({walk, Dir, Name}, _Volume) ->
    case name(Name) of
        ok -> {then, step(Dir, fun(Inode, Volume, Blocks) -> walk(Inode, Name, Volume, Blocks) end)};
        Refused -> {reply, Refused}
    end;
start({getattr, Nid}, _Volume) ->
    {then, step(Nid, fun(Inode, _, _) -> {reply, {ok, attr(Inode)}} end)};
start({open, Nid, Flags}, Volume) ->
    Writable = writable(Volume),
    {then, step(Nid, fun(Inode, _, _) -> {reply, opened(Nid, Inode, Flags, Writable)} end)};
start({read, Handle, Offset, Count}, _Volume) ->
    maybe
        {ok, Nid} ?= opened_for(Handle, read),
        {then, step(Nid, fun(Inode, Volume, Blocks) ->
                                 maybe
                                     ok ?= readable(kind(Inode)),
                                     {ok, Bytes} ?= erx_f2fs_core:read(Volume, Inode, Offset, Count, Blocks),
                                     {reply, {ok, Bytes}}
                                 end
                         end)}
    end;
start({readdir, Handle, Position, Max}, _Volume) ->
    maybe
        {ok, Nid} ?= opened_for(Handle, read),
        {then, core_call(Nid, Position, Max, [], 1)}
    end;
start({readlink, Nid}, _Volume) ->
    {then, step(Nid, fun(Inode, Volume, Blocks) ->
                             maybe
                                 ok ?= of_kind(Inode, symlink, einval),
                                 {ok, Target} ?= erx_f2fs_core:symlink(Volume, Inode, Blocks),
                                 {reply, {ok, Target}}
                             end
                     end)};
start(statfs, Volume) ->
    {reply, {ok, statfs(Volume)}};
start({fsync, _Handle}, Volume) ->
    case writable(Volume) of
        true -> checkpoint;
        false -> {reply, ok}
    end;
start({write, {Handle, Offset, Bytes}}, #{dirty := _}) ->
    maybe
        {ok, Nid} ?= opened_for(Handle, write),
        {then, step(Nid, fun(Inode, Volume, Blocks) -> write(Inode, Offset, Bytes, Volume, Blocks) end)}
    end;
start({Mutation, _Arguments}, #{dirty := _})
  when Mutation =:= make; Mutation =:= setattr; Mutation =:= unlink; Mutation =:= rename ->
    {reply, {error, enotsup}};
start({Mutation, _Arguments}, _Volume)
  when Mutation =:= write; Mutation =:= make; Mutation =:= setattr; Mutation =:= unlink;
       Mutation =:= rename ->
    {reply, {error, erofs}}.

%% A step that reads node Nid's inode and goes on with Then over it; the
%% core's failure, the inode's or one Then meets, is node Nid's.
step(Nid, Then) ->
    fun(Volume, Blocks) ->
            Move = maybe
                       {ok, Inode} ?= erx_f2fs_core:inode(Volume, Nid, Blocks),
                       Then(Inode, Volume, Blocks)
                   end,
            case Move of
                {error, Failure} -> {failed, Nid, Failure};
                _ -> Move
            end
    end.

%% A walk's name: one a directory can hold, never "." or "..", which the
%% grammar refuses before any walk reaches a tree.
name(Name) when Name =:= <<>>; Name =:= <<".">>; Name =:= <<"..">> -> {error, einval};
name(Name) when byte_size(Name) > ?NAME_MAX -> {error, enametoolong};
name(Name) ->
    case binary:match(Name, [<<"/">>, <<0>>]) of
        nomatch -> ok;
        _ -> {error, einval}
    end.

%% Name in directory Dir, then the child's inode, a step of its own.
walk(Dir, Name, Volume, Blocks) ->
    maybe
        ok ?= of_kind(Dir, directory, enotdir),
        {ok, #{ino := Child}} ?= erx_f2fs_core:lookup(Volume, Dir, Name, Blocks),
        {then, step(Child, fun(Inode, _, _) -> {reply, {ok, Child, qid(Inode)}} end)}
    else
        {ok, none} -> {reply, {error, enoent}};
        Other -> Other
    end.

%% An open's handle, the node's nid and the access it was opened for. The
%% owner's permission bits decide every open by the one rule of
%% erx_fs:open_permitted/3, which erx_ramfs_core's opens follow too; a
%% directory opened for writing or truncation answers eisdir, and a
%% read-only volume such an open's erofs, before that rule.
opened(Nid, Inode, Flags, Writable) -> opened(Nid, Inode, kind(Inode), Flags, Writable).

opened(_Nid, _Inode, _Kind, Flags, _Writable) when Flags band ?ERX_P9_O_ACCMODE =:= ?ERX_P9_O_ACCMODE ->
    {error, einval};
opened(_Nid, _Inode, Kind, _Flags, _Writable) when Kind =:= device; Kind =:= other -> {error, enotsup};
opened(_Nid, _Inode, symlink, _Flags, _Writable) -> {error, eloop};
opened(Nid, #{i_mode := Mode}, Kind, Flags, Writable) ->
    Access = access(Flags),
    Truncate = Flags band ?ERX_P9_O_TRUNC =/= 0,
    Writes = Access =/= read orelse Truncate,
    case {Writes, Kind, Writable, erx_fs:open_permitted(Mode, Access, Truncate)} of
        {true, directory, _, _} -> {error, eisdir};
        {true, _, false, _} -> {error, erofs};
        {_, _, _, {error, eacces} = Refused} -> Refused;
        {true, _, _, ok} when Flags band (?ERX_P9_O_TRUNC bor ?ERX_P9_O_APPEND) =/= 0 -> {error, enotsup};
        {_, _, _, ok} -> {ok, {Nid, Access}}
    end.

%% The access an open's flags ask for.
access(Flags) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> read;
        ?ERX_P9_O_WRONLY -> write;
        ?ERX_P9_O_RDWR -> read_write
    end.

%% Handle's nid, when it was opened for Need, else ebadf.
opened_for({Nid, Access}, Need) when Access =:= Need; Access =:= read_write -> {ok, Nid};
opened_for(_Handle, _Need) -> {reply, {error, ebadf}}.

%% Whether Volume is a read-write volume's view, which holds its dirty
%% nodes (erx_f2fs_core:view/1).
writable(Volume) -> is_map_key(dirty, Volume).

%%% write

%% The first step of a write of Bytes at Offset to Inode: the blocks it
%% covers, at most ?WRITE_BLOCKS of them, merged, each slot checked to be
%% held by a node.
write(_Inode, Offset, <<>>, _Volume, _Blocks) ->
    {reply, {ok, 0, Offset}};
write(#{i_size := Size, footer := #{ino := Ino}} = Inode, Offset, Bytes0, Volume, Blocks) ->
    First = Offset div ?BLOCK_SIZE,
    Bytes = binary:part(Bytes0, 0, min(byte_size(Bytes0), (First + ?WRITE_BLOCKS) * ?BLOCK_SIZE - Offset)),
    End = Offset + byte_size(Bytes),
    Last = (End - 1) div ?BLOCK_SIZE,
    maybe
        ok ?= readable(kind(Inode)),
        ok ?= supported(not is_map_key(inline_data, Inode) andalso First =< Size div ?BLOCK_SIZE),
        ok ?= mapped(Volume, Inode, lists:seq(First, Last), Blocks),
        {ok, Head} ?= old_block(Volume, Inode, First, Blocks),
        {ok, Tail} ?= old_block(Volume, Inode, Last, Blocks),
        Lead = Offset - First * ?BLOCK_SIZE,
        Trail = (Last + 1) * ?BLOCK_SIZE - End,
        Merged = <<(binary:part(Head, 0, Lead))/binary, Bytes/binary,
                   (binary:part(Tail, ?BLOCK_SIZE - Trail, Trail))/binary>>,
        {write, Ino, [{Block, binary:part(Merged, (Block - First) * ?BLOCK_SIZE, ?BLOCK_SIZE)}
                 || Block <- lists:seq(First, Last)],
         max(Size, End), {ok, byte_size(Bytes), Offset}}
    end.

supported(true) -> ok;
supported(false) -> {reply, {error, enotsup}}.

%% ok when a node holds the slot of each of Range's blocks.
mapped(_Volume, _Inode, [], _Blocks) ->
    ok;
mapped(Volume, Inode, [Block | Range], Blocks) ->
    case erx_f2fs_core:slot(Volume, Inode, Block, Blocks) of
        {ok, none} -> {reply, {error, enotsup}};
        {ok, _Slot} -> mapped(Volume, Inode, Range, Blocks);
        Other -> Other
    end.

%% File block Block's bytes below the size, zeros at and past it.
old_block(Volume, Inode, Block, Blocks) ->
    maybe
        {ok, Bytes} ?= erx_f2fs_core:read(Volume, Inode, Block * ?BLOCK_SIZE, ?BLOCK_SIZE, Blocks),
        {ok, <<Bytes/binary, 0:((?BLOCK_SIZE - byte_size(Bytes)) * 8)>>}
    end.

%% ok for a file a read reads; a directory's handle answers eisdir.
readable(regular) -> ok;
readable(directory) -> {reply, {error, eisdir}};
readable(_Kind) -> {reply, {error, einval}}.

%% ok when Inode is of Kind, else the answer Errno.
of_kind(Inode, Kind, Errno) ->
    case kind(Inode) of
        Kind -> ok;
        _ -> {reply, {error, Errno}}
    end.

%%% readdir

%% Call Call of the core's readdir of directory Nid, from Position, after
%% calls that found Found.
core_call(Nid, Position, Max, Found, Call) ->
    step(Nid, fun(Dir, Volume, Blocks) ->
                      maybe
                          ok ?= of_kind(Dir, directory, enotdir),
                          ok ?= within(Call, Dir, Volume),
                          {ok, {Entries, Next}} ?= erx_f2fs_core:readdir(Volume, Dir, Position, Blocks),
                          after_call(Nid, Found ++ Entries, Next, Max, Call)
                      end
              end).

within(Call, #{i_blocks := Held}, #{checkpoint := #{user_block_count := User}}) ->
    case Call =< (2 * min(Held, User) + 5) div 8 + 1 of
        true -> ok;
        false -> {error, {dir, blocks}}
    end.

%% After a core call: enough entries, or the directory's end, takes their
%% qids; else the core is called again from Next.
after_call(Nid, Found, Next, Max, _Call) when Next =:= done; length(Found) >= Max ->
    dirents(Nid, lists:sublist(Found, Max), []);
after_call(Nid, Found, Next, Max, Call) ->
    {then, core_call(Nid, Next, Max, Found, Call + 1)}.

%% Each entry of directory Dir with its inode's qid, read a step each.
dirents(_Dir, [], Dirents) ->
    {reply, {ok, lists:reverse(Dirents)}};
dirents(Dir, [#{name := Name, ino := Ino, file_type := Type, position := At} | Entries], Dirents) ->
    Node = case Name of
               <<".">> -> Dir;
               _ -> Ino
           end,
    {then, step(Node, fun(Inode, _, _) ->
                              Dirent = {qid(Inode), At + 1, dirent_type(Type), Name},
                              dirents(Dir, Entries, [Dirent | Dirents])
                      end)}.

%%% Attributes

kind(#{i_mode := Mode}) ->
    case Mode band ?ERX_F2FS_MODE_TYPE_MASK of
        ?ERX_F2FS_MODE_REG -> regular;
        ?ERX_F2FS_MODE_DIR -> directory;
        ?ERX_F2FS_MODE_LNK -> symlink;
        Type when Type =:= ?ERX_F2FS_MODE_CHR; Type =:= ?ERX_F2FS_MODE_BLK -> device;
        _ -> other
    end.

qid(#{footer := #{ino := Ino}, i_generation := Generation} = Inode) ->
    Type = case kind(Inode) of
               directory -> ?ERX_P9_QTDIR;
               symlink -> ?ERX_P9_QTSYMLINK;
               _ -> 0
           end,
    {Type, 0, Generation bsl 32 bor Ino}.

%% getattr's answer. A device's number is left out of valid: its encoding
%% in the address array is Linux's and not yet read from a source (open
%% question 7 of the F2FS facts record).
attr(#{i_mode := Mode, i_uid := Uid, i_gid := Gid, i_links := Links, i_size := Size,
       i_blocks := Blocks, i_generation := Generation} = Inode) ->
    Valid = case kind(Inode) of
                device -> ?GETATTR_VALID;
                _ -> ?GETATTR_VALID bor ?ERX_P9_GETATTR_MASK_RDEV
            end,
    #{valid => Valid, qid => qid(Inode), mode => Mode, uid => Uid, gid => Gid, nlink => Links,
      rdev => 0, size => Size, blksize => ?BLOCK_SIZE,
      blocks => Blocks * (?BLOCK_SIZE div ?STAT_BLOCK),
      atime_sec => maps:get(i_atime, Inode), atime_nsec => maps:get(i_atime_nsec, Inode),
      mtime_sec => maps:get(i_mtime, Inode), mtime_nsec => maps:get(i_mtime_nsec, Inode),
      ctime_sec => maps:get(i_ctime, Inode), ctime_nsec => maps:get(i_ctime_nsec, Inode),
      btime_sec => 0, btime_nsec => 0, gen => Generation, data_version => 0}.

%% A dentry's file type ([F 59]) as a readdir entry's.
dirent_type(?ERX_F2FS_FT_REG_FILE) -> ?ERX_P9_DT_REG;
dirent_type(?ERX_F2FS_FT_DIR) -> ?ERX_P9_DT_DIR;
dirent_type(?ERX_F2FS_FT_CHRDEV) -> ?ERX_P9_DT_CHR;
dirent_type(?ERX_F2FS_FT_BLKDEV) -> ?ERX_P9_DT_BLK;
dirent_type(?ERX_F2FS_FT_FIFO) -> ?ERX_P9_DT_FIFO;
dirent_type(?ERX_F2FS_FT_SOCK) -> ?ERX_P9_DT_SOCK;
dirent_type(?ERX_F2FS_FT_SYMLINK) -> ?ERX_P9_DT_LNK;
dirent_type(_Unknown) -> ?ERX_P9_DT_UNKNOWN.

%% statfs: the volume's blocks and the free ones, and the nids that can
%% hold a node and the free ones, which the mount checked against each
%% other ([F 55]). A read-write volume's blocks are the space it offers
%% writes, so its free blocks run out where a write answers enospc, and
%% none are free on a volume already past it; a read-only volume's are the
%% checkpoint's user blocks.
statfs(#{superblock := Super,
         checkpoint := #{user_block_count := User, valid_block_count := Valid,
                         valid_node_count := Nodes}} = Volume) ->
    Blocks = case writable(Volume) of
                 true -> erx_f2fs_mount:offered(Volume);
                 false -> User
             end,
    Free = max(0, Blocks - Valid),
    Files = erx_f2fs_codec:node_capacity(Super),
    #{type => ?ERX_P9_MAGIC_F2FS, fsid => 0, bsize => ?BLOCK_SIZE, blocks => Blocks,
      bfree => Free, bavail => Free, files => Files, ffree => Files - Nodes,
      namelen => ?NAME_MAX}.
