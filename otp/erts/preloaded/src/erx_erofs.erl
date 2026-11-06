%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_erofs).
-moduledoc """
The EROFS reader (docs/design-storage.md, Reading EROFS images): reads a
read-only image in the calling process, written from the format's header,
`erofs_fs.h`, whose layouts `abi/formats/erofs.txt` declares.

It implements what the packer's `mkfs.erofs` options write: 4 KiB blocks,
compact and extended inodes, the plain and inline data layouts, regular
files, directories and symbolic links, no compression. It steps over an
inode's inline extended attributes and serves none. `mount/2` refuses an
image with an incompatible feature bit, naming the bits, an extended
superblock, another block or directory block size, or a bad superblock
CRC-32C; an inode with another data layout (compressed or chunked) or of
another file type answers `enotsup` when it is reached.

Every block comes from `erx_verity:read/3`, the one funnel, and nothing
else reads the image. Every field is checked before it is used: an inode
number, an offset or a size that points outside the image, a directory
entry whose name runs past its block, a name of 0 or over
`ERX_EROFS_NAME_MAX` bytes, or entries out of order fail the operation with
`{error, eio}` after a diagnostic, an ASCII line of numbers and fixed text,
is handed to the mount's log function. A malformed image fails the
operation, never its caller, and makes no atom.

Operations name their file by its names from the image's root, as the path
resolver, `erx_path`, hands them: every name but the last a directory. A
walk takes at most `ERX_NS_NAMES_MAX` names, and a lookup in a directory of
b blocks reads O(log b) of them, so the work of every operation is bounded
by its names and the image's size; nothing recurses on the image's data.
It calls only BIFs, since it runs in whatever process reads a path, the
code server included.

`mount/3` opens the image through the funnel from the block service's
window on it; `erx_ns` mounts the result in the namespace, `prim_file`
calls the operations below on the names `erx_path` resolves there, and an
open file of the image is `erx_erofs_file`'s.
""".

-export([mount/3, walk/2, read_link/2, read_file_info/2, file_info/2,
         list_dir/2, read_file/2, pread/4]).
-export_type([fs/0, kind/0, info/0]).

-include("file.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, ?ERX_EROFS_BLOCK_SIZE).
-define(SLOT, (1 bsl ?ERX_EROFS_INODE_SLOT_BITS)).
-define(LINK_MAX, (?ERX_PATH_MAX - 1)).

-record(fs, {image :: erx_verity:image(),
             log :: log(),
             blocks :: non_neg_integer(),
             meta :: non_neg_integer(),
             root :: non_neg_integer(),
             epoch :: non_neg_integer(),
             nsec :: non_neg_integer(),
             compact_mtime :: boolean()}).

%% An inode, decoded and checked: where its data lies and what stat shows.
%% Its data is `full` whole blocks from block `start`, then for the inline
%% layout a tail of the rest of `size` bytes at byte `tail` of the image.
-record(inode, {nid :: non_neg_integer(),
                type :: regular | directory | symlink,
                mode :: non_neg_integer(),
                size :: non_neg_integer(),
                nlink :: non_neg_integer(),
                uid :: non_neg_integer(),
                gid :: non_neg_integer(),
                mtime :: {non_neg_integer(), non_neg_integer()},
                start :: non_neg_integer(),
                full :: non_neg_integer(),
                tail :: non_neg_integer()}).

-opaque fs() :: #fs{}.
-type log() :: fun((binary()) -> term()).
-type name() :: binary().
-type posix() :: eio | enotsup | enoent | enotdir | eisdir | einval | enametoolong.
-doc "What `erx_path` takes from a walk: the kind of each name passed.".
-type kind() :: directory | link | other.
-type info() :: #{type := regular | directory | symlink, size := non_neg_integer(),
                  mode := non_neg_integer(), nlink := non_neg_integer(),
                  uid := non_neg_integer(), gid := non_neg_integer(),
                  mtime := {non_neg_integer(), non_neg_integer()},
                  inode := non_neg_integer()}.

%% A failure inside an operation: its error and its diagnostic.
-define(FAIL(Posix, Text, Args), throw({?MODULE, Posix, Text, Args})).

-doc """
Mounts the image the block service's window `Window` holds, checked
against `Tree`: opens it through the funnel, reads block 0, checks the
superblock and the root directory, and returns the mount, or the error and
its diagnostic. `Log` receives the diagnostic of every later failed
operation.
""".
-spec mount(pid(), erx_verity:tree(), log()) -> {ok, fs()} | {error, posix(), binary()}.
mount(Window, Tree, Log) when is_function(Log, 1) ->
    case erx_verity:open(Window, Tree) of
        {ok, Image} -> mount_image(Image, Log);
        {error, eio} -> {error, eio, <<"erofs: the window did not answer its length">>}
    end.

mount_image(Image, Log) ->
    Probe = #fs{image = Image, log = Log, blocks = 1, meta = 0, root = 0,
                epoch = 0, nsec = 0, compact_mtime = false},
    try
        Fs = superblock(Probe, block(Probe, 0)),
        #inode{type = directory} = inode_of_type(Fs, Fs#fs.root, directory),
        {ok, Fs}
    catch
        throw:{?MODULE, Posix, Text, Args} -> {error, Posix, diagnostic(Text, Args)}
    end.

-doc """
Walks `Names` from the root and answers the kind of each name passed, in
order, up to and including the first that is not a directory, and how the
walk ended, `erx_path`'s walk reply. A link ends the walk with `ok`.
""".
-spec walk(fs(), [name()]) -> {[kind()], ok | {error, posix()}}.
walk(Fs, Names) when length(Names) =< ?ERX_NS_NAMES_MAX ->
    run(Fs, fun() -> walk(Fs, root(Fs), Names) end, fun(Posix) -> {[], {error, Posix}} end);
walk(_, _) ->
    {[], {error, enametoolong}}.

-doc "Reads the text of the symbolic link `Names` names.".
-spec read_link(fs(), [name()]) -> {ok, binary()} | {error, posix()}.
read_link(Fs, Names) ->
    operation(Fs, Names, fun(#inode{type = symlink, size = Size} = Link)
                               when Size >= 1, Size =< ?LINK_MAX ->
                                 Text = data(Fs, Link, 0, Size),
                                 binary:match(Text, <<0>>) =:= nomatch
                                     orelse ?FAIL(eio, "inode ~b: link text holds a NUL", [Link#inode.nid]),
                                 Text;
                            (#inode{type = symlink, nid = Nid}) ->
                                 ?FAIL(eio, "inode ~b: link text length out of range", [Nid]);
                            (_) ->
                                 throw({?MODULE, einval})
                         end).

-doc "Answers what stat shows of the file `Names` names, links not followed.".
-spec read_file_info(fs(), [name()]) -> {ok, info()} | {error, posix()}.
read_file_info(Fs, Names) ->
    operation(Fs, Names, fun(#inode{} = I) ->
                                 #{type => I#inode.type, size => I#inode.size,
                                   mode => I#inode.mode, nlink => I#inode.nlink,
                                   uid => I#inode.uid, gid => I#inode.gid,
                                   mtime => I#inode.mtime, inode => I#inode.nid}
                         end).

-doc """
What `read_file_info/2` answers, as the record stock's `prim_file` NIF
returns for a path: its times POSIX seconds, for `prim_file` to convert.
""".
-spec file_info(fs(), [name()]) -> #file_info{} | {error, posix()}.
file_info(Fs, Names) ->
    case operation(Fs, Names, fun stat/1) of
        {ok, Info} -> Info;
        Error -> Error
    end.

%% A stat of the inode. Every time is the image's modification time, as the format keeps
%% no other. The owner's read bit gives the access, never write, since the image takes
%% none, as stock's access(2) answers on a read-only mount; a link's own record carries
%% none, which prim_file takes from the file the link leads to. No device number is
%% given to an image, so it has none.
stat(#inode{type = Type, mtime = {Seconds, _}} = I) ->
    #file_info{size = I#inode.size, type = Type,
               access = access(I),
               atime = Seconds, mtime = Seconds, ctime = Seconds, mode = type_bits(Type) bor I#inode.mode,
               links = I#inode.nlink, major_device = 0, minor_device = 0,
               inode = I#inode.nid, uid = I#inode.uid, gid = I#inode.gid}.

access(#inode{type = symlink}) -> undefined;
access(#inode{mode = Mode}) when Mode band 8#400 =:= 0 -> none;
access(#inode{}) -> read.

%% The file type bits of st_mode, which stat shows and the inode's mode, as decoded,
%% leaves out.
type_bits(regular) -> 8#100000;
type_bits(directory) -> 8#040000;
type_bits(symlink) -> 8#120000.

-doc "Lists the names of the directory `Names` names, without `.` and `..`.".
-spec list_dir(fs(), [name()]) -> {ok, [name()]} | {error, posix()}.
list_dir(Fs, Names) ->
    operation(Fs, Names, fun(#inode{type = directory} = Dir) ->
                                 [Name || Index <- seq(0, dir_blocks(Dir) - 1),
                                          {Name, _} <- dir_block(Fs, Dir, Index),
                                          Name =/= <<".">>, Name =/= <<"..">>];
                            (_) ->
                                 throw({?MODULE, enotdir})
                         end).

-doc "Reads the whole regular file `Names` names.".
-spec read_file(fs(), [name()]) -> {ok, binary()} | {error, posix()}.
read_file(Fs, Names) ->
    operation(Fs, Names, fun(#inode{type = regular, size = Size} = File) -> data(Fs, File, 0, Size);
                            (#inode{type = directory}) -> throw({?MODULE, eisdir});
                            (_) -> throw({?MODULE, einval})
                         end).

-doc """
Reads at most `Length` bytes from byte `Offset` of the regular file `Names`
names, or `eof` at or past its end.
""".
-spec pread(fs(), [name()], non_neg_integer(), non_neg_integer()) ->
          {ok, binary()} | eof | {error, posix()}.
pread(Fs, Names, Offset, Length)
  when is_integer(Offset), Offset >= 0, is_integer(Length), Length >= 0 ->
    case operation(Fs, Names, fun(#inode{type = regular, size = Size}) when Offset >= Size -> eof;
                                 (#inode{type = regular, size = Size} = File) ->
                                      data(Fs, File, Offset, min(Length, Size - Offset));
                                 (#inode{type = directory}) -> throw({?MODULE, eisdir});
                                 (_) -> throw({?MODULE, einval})
                              end) of
        {ok, eof} -> eof;
        Result -> Result
    end;
pread(_, _, _, _) ->
    {error, einval}.

%% Operations

%% Runs Fun on the inode Names names, every name before the last a
%% directory, and answers {ok, Result} or the error it threw.
operation(Fs, Names, Fun) when length(Names) =< ?ERX_NS_NAMES_MAX ->
    run(Fs, fun() -> {ok, Fun(resolve(Fs, root(Fs), Names))} end, fun(Posix) -> {error, Posix} end);
operation(_, _, _) ->
    {error, enametoolong}.

%% Runs an operation, turning a failure into Failed(Posix); a malformed
%% image's failure hands its diagnostic to the log first.
run(#fs{log = Log}, Operation, Failed) ->
    try
        Operation()
    catch
        throw:{?MODULE, Posix} ->
            Failed(Posix);
        throw:{?MODULE, Posix, Text, Args} ->
            _ = Log(diagnostic(Text, Args)),
            Failed(Posix)
    end.

%% A diagnostic: fixed text with each ~b of it a decimal and each ~.16b a
%% hexadecimal integer.
diagnostic(Text, Args) ->
    iolist_to_binary(["erofs: " | format(Text, Args)]).

format([$~, $b | Text], [N | Args]) -> [integer_to_binary(N) | format(Text, Args)];
format([$~, $., $1, $6, $b | Text], [N | Args]) -> [integer_to_binary(N, 16) | format(Text, Args)];
format([C | Text], Args) -> [C | format(Text, Args)];
format([], []) -> [].

root(#fs{root = Root} = Fs) -> inode(Fs, Root).

%% The walk loop: one name a step, ended by the names, a missing name, a
%% link or another file; never deeper than its names.
walk(_, _, []) ->
    {[], ok};
walk(Fs, Dir, [Name | Rest]) ->
    case lookup(Fs, Dir, Name) of
        none ->
            {[], {error, enoent}};
        Nid ->
            case inode(Fs, Nid) of
                #inode{type = directory} = Next ->
                    {Kinds, End} = walk(Fs, Next, Rest),
                    {[directory | Kinds], End};
                #inode{type = symlink} -> {[link], ok};
                #inode{} when Rest =:= [] -> {[other], ok};
                #inode{} -> {[other], {error, enotdir}}
            end
    end.

resolve(_, Inode, []) ->
    Inode;
resolve(Fs, #inode{type = directory} = Dir, [Name | Rest]) ->
    case lookup(Fs, Dir, Name) of
        none -> throw({?MODULE, enoent});
        Nid -> resolve(Fs, inode(Fs, Nid), Rest)
    end;
resolve(_, _, _) ->
    throw({?MODULE, enotdir}).

%% Directories

%% The inode number of Name in Dir, or none: a binary search over the
%% directory's blocks by their first and last names, then within the block.
lookup(_, _, Name) when byte_size(Name) > ?ERX_EROFS_NAME_MAX ->
    throw({?MODULE, enametoolong});
lookup(Fs, Dir, Name) ->
    search_blocks(Fs, Dir, Name, 0, dir_blocks(Dir) - 1).

search_blocks(_, _, _, Low, High) when Low > High ->
    none;
search_blocks(Fs, Dir, Name, Low, High) ->
    Middle = (Low + High) div 2,
    Entries = list_to_tuple(dir_block(Fs, Dir, Middle)),
    {First, _} = element(1, Entries),
    {Last, _} = element(tuple_size(Entries), Entries),
    if
        Name < First -> search_blocks(Fs, Dir, Name, Low, Middle - 1);
        Name > Last -> search_blocks(Fs, Dir, Name, Middle + 1, High);
        true -> search_entries(Entries, Name, 1, tuple_size(Entries))
    end.

search_entries(_, _, Low, High) when Low > High ->
    none;
search_entries(Entries, Name, Low, High) ->
    Middle = (Low + High) div 2,
    case element(Middle, Entries) of
        {Name, Nid} -> Nid;
        {Other, _} when Name < Other -> search_entries(Entries, Name, Low, Middle - 1);
        _ -> search_entries(Entries, Name, Middle + 1, High)
    end.

dir_blocks(#inode{size = Size}) -> (Size + ?BLOCK - 1) div ?BLOCK.

%% The entries of a directory's block Index, {Name, Nid} in strictly
%% increasing order of name. The first entry's name offset counts the
%% entries; each name runs to the next entry's name, the last one to the
%% end of the block's data or its first NUL.
dir_block(Fs, #inode{nid = Nid, size = Size} = Dir, Index) ->
    Length = min(?BLOCK, Size - Index * ?BLOCK),
    Bytes = data(Fs, Dir, Index * ?BLOCK, Length),
    Length >= ?ERX_EROFS_DIRENT_SIZE
        orelse ?FAIL(eio, "inode ~b block ~b: no directory entry", [Nid, Index]),
    First = u16(Bytes, ?ERX_EROFS_DIRENT_OFF_NAMEOFF),
    (First >= ?ERX_EROFS_DIRENT_SIZE andalso First rem ?ERX_EROFS_DIRENT_SIZE =:= 0
     andalso First < Length)
        orelse ?FAIL(eio, "inode ~b block ~b: bad first name offset ~b", [Nid, Index, First]),
    Count = First div ?ERX_EROFS_DIRENT_SIZE,
    Offsets = [u16(Bytes, Entry * ?ERX_EROFS_DIRENT_SIZE + ?ERX_EROFS_DIRENT_OFF_NAMEOFF)
               || Entry <- seq(0, Count - 1)] ++ [Length],
    Entries = entries(Bytes, Offsets, 0, {Nid, Index}),
    ordered([Name || {Name, _} <- Entries])
        orelse ?FAIL(eio, "inode ~b block ~b: names out of order", [Nid, Index]),
    Entries.

entries(_, [_End], _, _) ->
    [];
entries(Bytes, [Start, End | Rest], Entry, {Nid, Index} = Where) ->
    (Start < End andalso End =< byte_size(Bytes))
        orelse ?FAIL(eio, "inode ~b block ~b: entry ~b name runs past its block", [Nid, Index, Entry]),
    Raw = binary:part(Bytes, Start, End - Start),
    Name = case Rest of
               [] -> hd(binary:split(Raw, <<0>>));
               _ -> Raw
           end,
    (byte_size(Name) >= 1 andalso byte_size(Name) =< ?ERX_EROFS_NAME_MAX
     andalso binary:match(Name, [<<0>>, <<"/">>]) =:= nomatch)
        orelse ?FAIL(eio, "inode ~b block ~b: entry ~b has a bad name", [Nid, Index, Entry]),
    Child = u64(Bytes, Entry * ?ERX_EROFS_DIRENT_SIZE + ?ERX_EROFS_DIRENT_OFF_NID_LO),
    [{Name, Child} | entries(Bytes, [End | Rest], Entry + 1, Where)].

seq(From, To) when From > To -> [];
seq(From, To) -> [From | seq(From + 1, To)].

ordered([A, B | Rest]) when A < B -> ordered([B | Rest]);
ordered([_, _ | _]) -> false;
ordered(_) -> true.

%% Inodes

inode_of_type(Fs, Nid, Type) ->
    case inode(Fs, Nid) of
        #inode{type = Type} = Inode -> Inode;
        _ -> ?FAIL(eio, "inode ~b: root is not a directory", [Nid])
    end.

%% Decodes and checks inode Nid: its format word, file type, data layout,
%% extended attributes and where its data lies, all inside the image. The
%% compact and extended layouts share their first 8 bytes and i_u, so those
%% fields are read from the first 32 bytes by the compact offsets.
inode(#fs{meta = Meta} = Fs, Nid) ->
    At = Meta * ?BLOCK + Nid * ?SLOT,
    Head = bytes(Fs, At, ?ERX_EROFS_INODE_COMPACT_SIZE, Nid),
    Format = u16(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_FORMAT),
    Format band bnot ?ERX_EROFS_I_ALL =:= 0
        orelse ?FAIL(eio, "inode ~b: unknown format bits 0x~.16b", [Nid, Format]),
    Layout = (Format bsr ?ERX_EROFS_I_DATALAYOUT_SHIFT) band ?ERX_EROFS_I_DATALAYOUT_MASK,
    Layout =:= ?ERX_EROFS_INODE_FLAT_PLAIN orelse Layout =:= ?ERX_EROFS_INODE_FLAT_INLINE
        orelse ?FAIL(enotsup, "inode ~b: data layout ~b is not implemented", [Nid, Layout]),
    {Size, Fields} =
        case Format band ?ERX_EROFS_I_VERSION_MASK of
            ?ERX_EROFS_INODE_LAYOUT_COMPACT -> compact(Fs, Head, Format);
            ?ERX_EROFS_INODE_LAYOUT_EXTENDED -> extended(bytes(Fs, At, ?ERX_EROFS_INODE_EXTENDED_SIZE, Nid))
        end,
    Mode = u16(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_MODE),
    Type = case Mode band ?ERX_EROFS_S_IFMT of
               ?ERX_EROFS_S_IFREG -> regular;
               ?ERX_EROFS_S_IFDIR -> directory;
               ?ERX_EROFS_S_IFLNK -> symlink;
               Other -> ?FAIL(enotsup, "inode ~b: file type 0x~.16b is not implemented", [Nid, Other])
           end,
    ICount = u16(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_XATTR_ICOUNT),
    Xattrs = case ICount of
                 0 -> 0;
                 _ -> ?ERX_EROFS_XATTR_IBODY_HEADER_SIZE + (ICount - 1) * ?ERX_EROFS_XATTR_ENTRY_SIZE
             end,
    Blocks = (Size + ?BLOCK - 1) div ?BLOCK,
    {Full, Tail} =
        case Layout of
            ?ERX_EROFS_INODE_FLAT_PLAIN -> {Blocks, 0};
            ?ERX_EROFS_INODE_FLAT_INLINE when Blocks =:= 0 -> {0, 0};
            ?ERX_EROFS_INODE_FLAT_INLINE -> {Blocks - 1, At + maps:get(isize, Fields) + Xattrs}
        end,
    Start = u32(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_U),
    Full =:= 0 orelse Start + Full =< Fs#fs.blocks
        orelse ?FAIL(eio, "inode ~b: data blocks ~b+~b outside the image", [Nid, Start, Full]),
    TailLength = Size - Full * ?BLOCK,
    InlineFits = Tail rem ?BLOCK + TailLength =< ?BLOCK andalso Tail + TailLength =< Fs#fs.blocks * ?BLOCK,
    Layout =:= ?ERX_EROFS_INODE_FLAT_PLAIN orelse TailLength =:= 0 orelse InlineFits
        orelse ?FAIL(eio, "inode ~b: inline data crosses its block or leaves the image", [Nid]),
    #inode{nid = Nid, type = Type, mode = Mode band 8#7777, size = Size,
           nlink = maps:get(nlink, Fields), uid = maps:get(uid, Fields),
           gid = maps:get(gid, Fields), mtime = maps:get(mtime, Fields),
           start = Start, full = Full, tail = Tail}.

compact(#fs{epoch = Epoch, nsec = Nsec, compact_mtime = OwnMtime}, Head, Format) ->
    Nlink = case Format band ?ERX_EROFS_I_NLINK_1 of
                0 -> u16(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_NLINK);
                _ -> 1
            end,
    Mtime = case OwnMtime of
                true -> Epoch + u32(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_MTIME);
                false -> Epoch
            end,
    {u32(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_SIZE),
     #{isize => ?ERX_EROFS_INODE_COMPACT_SIZE, nlink => Nlink,
       uid => u16(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_UID),
       gid => u16(Head, ?ERX_EROFS_INODE_COMPACT_OFF_I_GID), mtime => {Mtime, Nsec}}}.

extended(Inode) ->
    {u64(Inode, ?ERX_EROFS_INODE_EXTENDED_OFF_I_SIZE),
     #{isize => ?ERX_EROFS_INODE_EXTENDED_SIZE,
       nlink => u32(Inode, ?ERX_EROFS_INODE_EXTENDED_OFF_I_NLINK),
       uid => u32(Inode, ?ERX_EROFS_INODE_EXTENDED_OFF_I_UID),
       gid => u32(Inode, ?ERX_EROFS_INODE_EXTENDED_OFF_I_GID),
       mtime => {u64(Inode, ?ERX_EROFS_INODE_EXTENDED_OFF_I_MTIME),
                 u32(Inode, ?ERX_EROFS_INODE_EXTENDED_OFF_I_MTIME_NSEC)}}}.

%% Data

%% Length bytes of an inode's data from byte Offset, which the caller keeps
%% inside its size: whole blocks from its start block, then its inline tail.
data(_, _, _, 0) ->
    <<>>;
data(Fs, #inode{nid = Nid, start = Start, full = Full, tail = Tail}, Offset, Length) ->
    InBlocks = max(0, min(Offset + Length, Full * ?BLOCK) - Offset),
    Head = case InBlocks of
               0 -> <<>>;
               _ -> bytes(Fs, Start * ?BLOCK + Offset, InBlocks, Nid)
           end,
    Rest = Length - InBlocks,
    InTail = case Rest of
                 0 -> <<>>;
                 _ -> bytes(Fs, Tail + (Offset + InBlocks - Full * ?BLOCK), Rest, Nid)
             end,
    <<Head/binary, InTail/binary>>.

%% Length bytes of the image from byte At, read through the funnel at most
%% ERX_VERITY_READ_BLOCKS_MAX blocks a call, all of them inside the image.
bytes(#fs{blocks = Blocks}, At, Length, Nid) when At + Length > Blocks * ?BLOCK ->
    ?FAIL(eio, "inode ~b: bytes ~b+~b outside the image", [Nid, At, Length]);
bytes(Fs, At, Length, _) ->
    First = At div ?BLOCK,
    Last = (At + Length - 1) div ?BLOCK,
    Joined = iolist_to_binary(blocks(Fs, First, Last - First + 1)),
    binary:part(Joined, At - First * ?BLOCK, Length).

blocks(_, _, 0) ->
    [];
blocks(Fs, First, Count) ->
    Now = min(Count, ?ERX_VERITY_READ_BLOCKS_MAX),
    [read(Fs, First, Now) | blocks(Fs, First + Now, Count - Now)].

block(Fs, Block) -> iolist_to_binary(read(Fs, Block, 1)).

read(#fs{image = Image}, First, Count) ->
    case erx_verity:read(Image, First, Count) of
        {ok, Blocks} -> Blocks;
        {error, eio} -> ?FAIL(eio, "blocks ~b+~b failed to read", [First, Count])
    end.

%% The superblock

superblock(Fs, Block0) ->
    Sb = binary:part(Block0, ?ERX_EROFS_SUPER_OFFSET, ?ERX_EROFS_SUPER_BLOCK_SIZE),
    u32(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_MAGIC) =:= ?ERX_EROFS_MAGIC
        orelse ?FAIL(eio, "block 0: no EROFS magic", []),
    Bits = u8(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_BLKSZBITS),
    Bits =:= ?ERX_EROFS_BLOCK_BITS
        orelse ?FAIL(enotsup, "block 0: block size 2^~b, not 2^~b", [Bits, ?ERX_EROFS_BLOCK_BITS]),
    Incompat = u32(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_FEATURE_INCOMPAT),
    Incompat =:= 0
        orelse ?FAIL(enotsup, "block 0: incompatible feature bits 0x~.16b are not implemented", [Incompat]),
    u8(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_SB_EXTSLOTS) =:= 0
        orelse ?FAIL(enotsup, "block 0: extended superblock slots are not implemented", []),
    u8(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_DIRBLKBITS) =:= 0
        orelse ?FAIL(enotsup, "block 0: directory blocks larger than a block are not implemented", []),
    Compat = u32(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_FEATURE_COMPAT),
    Compat band ?ERX_EROFS_COMPAT_SB_CHKSUM =:= 0 orelse checksum_matches(Block0)
        orelse ?FAIL(eio, "block 0: superblock CRC-32C mismatch", []),
    Blocks = u32(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_BLOCKS),
    Meta = u32(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_META_BLKADDR),
    Meta < Blocks
        orelse ?FAIL(eio, "block 0: metadata block ~b outside the image's ~b blocks", [Meta, Blocks]),
    Fs#fs{blocks = Blocks, meta = Meta,
          root = u16(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_ROOT_NID),
          epoch = u64(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_EPOCH),
          nsec = u32(Sb, ?ERX_EROFS_SUPER_BLOCK_OFF_FIXED_NSEC),
          compact_mtime = Compat band ?ERX_EROFS_COMPAT_MTIME =/= 0}.

%% erofs_fs.h's superblock checksum: the CRC-32C of the block from the
%% superblock to its end with the checksum field zeroed, seeded with all
%% ones and not inverted at the end, as Linux's crc32c(~0, ...) leaves it.
checksum_matches(Block0) ->
    At = ?ERX_EROFS_SUPER_OFFSET + ?ERX_EROFS_SUPER_BLOCK_OFF_CHECKSUM,
    <<Before:At/binary, Stored:32/little, After/binary>> = Block0,
    Covered = <<(binary:part(Before, ?ERX_EROFS_SUPER_OFFSET, At - ?ERX_EROFS_SUPER_OFFSET))/binary,
                0:32, After/binary>>,
    crc32c(Covered) =:= Stored.

%% CRC-32C (Castagnoli, reflected polynomial 0x82F63B78), bit by bit, so the
%% reader runs on stock OTP, which has no erx_bytes NIF (TODO.md).
crc32c(Bytes) ->
    crc32c(Bytes, 16#FFFFFFFF).

crc32c(<<Byte, Rest/binary>>, Crc) ->
    crc32c(Rest, crc32c_bits(Crc bxor Byte, 8));
crc32c(<<>>, Crc) ->
    Crc.

crc32c_bits(Crc, 0) -> Crc;
crc32c_bits(Crc, N) when Crc band 1 =:= 1 -> crc32c_bits((Crc bsr 1) bxor 16#82F63B78, N - 1);
crc32c_bits(Crc, N) -> crc32c_bits(Crc bsr 1, N - 1).

%% Little-endian fields at a byte offset of a binary already bounds-checked
%% to hold them.

u8(Bin, At) -> binary:at(Bin, At).
u16(Bin, At) -> <<_:At/binary, V:16/little, _/binary>> = Bin, V.
u32(Bin, At) -> <<_:At/binary, V:32/little, _/binary>> = Bin, V.
u64(Bin, At) -> <<_:At/binary, V:64/little, _/binary>> = Bin, V.
