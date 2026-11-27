%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_core).
-moduledoc """
F2FS's node tree, read (docs/design-f2fs.md, "Inodes" and "Operations"):
the one lookup of a node id in the NAT, the inode and node reads behind
it, a file block's slot through the inode's address array and its direct,
indirect and double indirect nodes, and a file's bytes, holes and NEW_ADDR
slots reading as zeros; and directories, read ("Directories"): a name's
lookup over the hash levels and readdir from a position. [F n] cites fact
n of the F2FS facts record, part 1.

The NAT is resolved only here: nat/2 checks the journal the mount read and
answers it as an opaque value, and every node read goes through
node_block/4, which looks the nid up, the journal's entry over its NAT
block's ([F 35]), and admits the entry only when it is used, owned by the
inode the reader expects and places its node in the main area at a block
the SIT marks valid. The codec then checks the block's footer against the
nid, the inode and the node offset the reader expects, so every node of a
file is read at its one place in that file's tree.

Every function takes two arguments besides its own. The first is the
volume: the map erx_f2fs_mount answers, or at the mount the part of it
that holds the superblock, the checkpoint, the SIT and the NAT. The other
is the blocks read so far, a map from address to block, as the mount
takes them. Each answers {ok, Value}, {need, Addresses} naming the blocks
it needs next, every one inside the NAT or the main area, or
{error, Failure}. A walk to one file block reads at most one node a level,
three below the inode, and a read decodes each node it crosses once, so
its work follows the blocks it covers and the nodes they lie under,
whatever the image claims.

A directory's entries are read from its inline dentries or its dentry
blocks, which are file blocks read as any file's are. A lookup searches
only the bucket the name's hash gives at each level, and stops at the
first level whose bucket starts past the directory's end, its size and
never past the largest block a file addresses, so it reads at most two
blocks a level for at most 29 levels whatever depth and level the inode
claims ([F 58]). A readdir covers at most ?READDIR_BLOCKS blocks a call
and answers the position the next starts from, which is past the one it
was given.
""".

-export([nat/2, inode/3, slot/4, read/5, symlink/3, lookup/4, readdir/4]).
-export_type([nat/0, volume/0, slot/0, dentry/0, failure/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
%% The nodes the inode names, by their depth above the data: two direct,
%% two indirect and one double indirect node ([F 53]).
-define(TREE_DEPTHS, [1, 1, 2, 2, 3]).
%% A position counts the slots of the blocks before its own ([F 59]).
-define(DENTRY_SLOTS, erx_f2fs_codec:dentry_slots(?BLOCK_SIZE)).
%% The blocks of a directory one readdir covers at most, holes included.
-define(READDIR_BLOCKS, 8).

-doc "The NAT journal's entries by nid, read only by this module.".
-opaque nat() :: #{non_neg_integer() => erx_f2fs_codec:nat_entry()}.
-doc """
The tables a read needs: the superblock, the checkpoint header with its
version bitmaps, the SIT (element S + 1 for main segment S) and the NAT.
""".
-type volume() :: #{superblock := erx_f2fs_codec:superblock(),
                    checkpoint := erx_f2fs_codec:checkpoint(),
                    sit := tuple(), nat := nat(), atom() => term()}.
-doc """
Where a file block's slot lies: the node holding it (the inode's own nid
for its address array), the slot's index there, counted after the extra
attributes, and the address the slot holds; none when no node holds it.
""".
-type slot() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()} | none.
-doc """
A directory's entry: its name, inode, file type and stored hash, and its
position, the slot it starts at counted through the directory's blocks,
the block's index times 214 plus the slot, or its inline slot ([F 59]).
""".
-type dentry() :: #{name := binary(), ino := non_neg_integer(), file_type := byte(),
                    hash_code := non_neg_integer(), position := non_neg_integer()}.
-doc "The table a read broke a rule of, and the rule, or a codec failure.".
-type failure() :: {nat, nid | free | owner | block_addr | journal_nid | journal_duplicate} |
                   {data, block_addr} | {file, inline | size | type} | {dir, dot} |
                   erx_f2fs_codec:failure().
-type blocks() :: #{non_neg_integer() => binary()}.
-type result(Value) :: {ok, Value} | {need, [non_neg_integer()]} | {error, failure()}.

-doc """
The NAT of a volume whose superblock is Super and whose NAT journal holds
Entries: each names a nid the NAT can hold, and names it once, so no
entry hides another ([F 35], [F 36]).
""".
-spec nat(erx_f2fs_codec:superblock(),
          [#{nid := non_neg_integer(), entry := erx_f2fs_codec:nat_entry()}]) ->
          {ok, nat()} | {error, failure()}.
nat(Super, Entries) ->
    run(fun() ->
                Nids = [Nid || #{nid := Nid} <- Entries],
                Capacity = erx_f2fs_codec:nat_capacity(Super),
                require(lists:all(fun(Nid) -> Nid < Capacity end, Nids), {nat, journal_nid}),
                require(length(lists:usort(Nids)) =:= length(Nids), {nat, journal_duplicate}),
                maps:from_list([{Nid, Entry} || #{nid := Nid, entry := Entry} <- Entries])
        end).

-doc """
Inode Ino, from the block its NAT entry places, under the codec's rules
for an inode block ([F 41], [F 42]).
""".
-spec inode(volume(), non_neg_integer(), blocks()) -> result(erx_f2fs_codec:inode()).
inode(#{superblock := Super} = Volume, Ino, Blocks) ->
    run(fun() -> ok(erx_f2fs_codec:inode(Super, Ino, node_block(Volume, Ino, Ino, Blocks))) end).

-doc """
The slot of file block Block of Inode, a file with an address array:
in the array, or in the direct node its node ids lead to ([F 53]). A
slot's address is NULL_ADDR, NEW_ADDR, or a main area block the SIT marks
valid.
""".
-spec slot(volume(), erx_f2fs_codec:inode(), non_neg_integer(), blocks()) -> result(slot()).
slot(Volume, Inode, Block, Blocks) ->
    run(fun() -> element(1, find_slot(Volume, Inode, Block, Blocks, #{})) end).

-doc """
Length bytes of Inode's file from Offset, cut at its size: inline data
from the inode ([F 48]), else each block's from the address its slot
holds, a hole or a NEW_ADDR slot reading as zeros ([F 4]).
""".
-spec read(volume(), erx_f2fs_codec:inode(), non_neg_integer(), non_neg_integer(), blocks()) ->
          result(binary()).
read(Volume, Inode, Offset, Length, Blocks) ->
    run(fun() -> read_bytes(Volume, Inode, Offset, Length, Blocks) end).

-doc """
A symlink's target: its bytes, inline or in its first block, at most a
block of them.
""".
-spec symlink(volume(), erx_f2fs_codec:inode(), blocks()) -> result(binary()).
symlink(Volume, #{i_mode := Mode, i_size := Size} = Inode, Blocks) ->
    run(fun() ->
                require(Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_LNK, {file, type}),
                require(Size =< ?BLOCK_SIZE, {file, size}),
                read_bytes(Volume, Inode, 0, Size, Blocks)
        end).

-doc """
The entry of directory Dir named Name, or none: among its inline
dentries, or in the bucket Name's hash gives at each hash level from 0
([F 57], [F 58]). An entry matches by its stored hash and its name.
""".
-spec lookup(volume(), erx_f2fs_codec:inode(), binary(), blocks()) -> result(dentry() | none).
lookup(Volume, Dir, Name, Blocks) ->
    run(fun() ->
                require_directory(Dir),
                Hash = erx_f2fs_codec:dentry_hash(Name),
                Named = fun(Entries) -> named(Entries, Name, Hash) end,
                case Dir of
                    #{inline_dentries := _} -> Named(placed(ok(erx_f2fs_codec:inline_dentries(Dir)), 0));
                    #{} -> first_named(Named, Volume, Dir, buckets(Dir, Hash), Blocks)
                end
        end).

-doc """
Directory Dir's entries from position Position on, in position order,
and the position the next call starts from, past Position, or done after
the directory's last block.
""".
-spec readdir(volume(), erx_f2fs_codec:inode(), non_neg_integer(), blocks()) ->
          result({[dentry()], non_neg_integer() | done}).
readdir(Volume, Dir, Position, Blocks) ->
    run(fun() ->
                require_directory(Dir),
                entries_from(Volume, Dir, Position, Blocks)
        end).

%%% The NAT

%% The block of node Nid of inode Ino. Its NAT entry is the journal's or
%% its block's in the copy the version bitmap selects ([F 34], [F 35]);
%% the entry is used, owned by Ino and places the node at a valid block.
%% The owner is checked here as well as in the node's footer, so another
%% file's node is refused before its block is asked for.
node_block(#{superblock := Super, checkpoint := Header, nat := Journal} = Volume, Nid, Ino, Blocks) ->
    require(Nid < erx_f2fs_codec:nat_capacity(Super), {nat, nid}),
    #{block_addr := Address, ino := Owner} =
        case Journal of
            #{Nid := Entry} ->
                Entry;
            #{} ->
                PerBlock = ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK,
                [Block] = fetch(Blocks, [nat_address(Super, Header, Nid div PerBlock)]),
                lists:nth(Nid rem PerBlock + 1, ok(erx_f2fs_codec:nat_block(Block)))
        end,
    require(Address =/= ?ERX_F2FS_NULL_ADDR, {nat, free}),
    require(Owner =:= Ino, {nat, owner}),
    require(valid_block(Volume, Address), {nat, block_addr}),
    [Node] = fetch(Blocks, [Address]),
    Node.

%% NAT block Index of one copy: the copies interleave a segment at a time,
%% and the block's bit in the version bitmap, first bit most significant,
%% selects the second ([F 23], [F 34]).
nat_address(#{nat_blkaddr := First}, #{nat_version_bitmap := Bitmap}, Index) ->
    First + Index div ?BLOCKS_PER_SEG * 2 * ?BLOCKS_PER_SEG + Index rem ?BLOCKS_PER_SEG +
        erx_f2fs_codec:bit(Bitmap, Index) * ?BLOCKS_PER_SEG.

%% Whether Address is a main area block the SIT marks valid.
valid_block(#{superblock := #{main_blkaddr := Main} = Super, sit := Sit}, Address) ->
    case Address >= Main andalso Address < erx_f2fs_codec:main_end(Super) of
        true ->
            #{valid_map := Map} = element((Address - Main) div ?BLOCKS_PER_SEG + 1, Sit),
            erx_f2fs_codec:bit(Map, (Address - Main) rem ?BLOCKS_PER_SEG) =:= 1;
        false ->
            false
    end.

%%% The node tree

%% File block Block's slot and Nodes, the nodes decoded so far by
%% {Nid, NodeOffset}, with the ones this walk decoded added.
find_slot(Volume, #{addresses := Addresses, footer := #{ino := Ino}}, Block, _Blocks, Nodes)
  when Block < length(Addresses) ->
    {checked_slot(Volume, {Ino, Block, lists:nth(Block + 1, Addresses)}), Nodes};
find_slot(Volume, #{addresses := Addresses, i_nid := Nids, footer := #{ino := Ino}}, Block,
          Blocks, Nodes) ->
    case place(Block - length(Addresses)) of
        {Tree, Path} ->
            {Slot, Decoded} = descend(Volume, Ino, lists:nth(Tree + 1, Nids), Path, Blocks, Nodes),
            {checked_slot(Volume, Slot), Decoded};
        none ->
            {none, Nodes}
    end;
find_slot(_Volume, _Inode, _Block, _Blocks, _Nodes) ->
    fail({file, inline}).

%% A slot's address is a hole, NEW_ADDR or a valid block ([F 4]).
checked_slot(_Volume, none) ->
    none;
checked_slot(Volume, {_Nid, _Index, Address} = Slot) ->
    require(Address =:= ?ERX_F2FS_NULL_ADDR orelse Address =:= ?ERX_F2FS_NEW_ADDR orelse
                valid_block(Volume, Address),
            {data, block_addr}),
    Slot.

%% Where the Block-th file block past the address array lies ([F 53]): under
%% the inode's node id Tree, through a path of {NodeOffset, Index} from that
%% node to the direct node, one a level; none past the double indirect
%% node's span. A file's nodes are numbered in tree order from the inode's
%% 0, so each tree's first offset follows the nodes of the trees before it.
place(Block) ->
    place(Block, lists:enumerate(0, ?TREE_DEPTHS), 1).

place(_Block, [], _Offset) ->
    none;
place(Block, [{Tree, Depth} | Trees], Offset) ->
    case span(Depth) of
        Span when Block < Span -> {Tree, path(Depth, Offset, Block)};
        Span -> place(Block - Span, Trees, Offset + tree_nodes(Depth))
    end.

%% A node at Depth, with node offset Offset, holding Block of its span: its
%% child's index, and the child's own path, whose offset follows the nodes
%% of the children before it.
path(1, Offset, Block) ->
    [{Offset, Block}];
path(Depth, Offset, Block) ->
    Span = span(Depth - 1),
    Child = Block div Span,
    [{Offset, Child} | path(Depth - 1, Offset + 1 + Child * tree_nodes(Depth - 1), Block rem Span)].

%% The file blocks under a node at Depth, and the nodes of its tree.
span(Depth) -> pow(?ERX_F2FS_NIDS_PER_BLOCK, Depth - 1) * ?ERX_F2FS_ADDRS_PER_BLOCK.

tree_nodes(1) -> 1;
tree_nodes(Depth) -> 1 + ?ERX_F2FS_NIDS_PER_BLOCK * tree_nodes(Depth - 1).

pow(_Base, 0) -> 1;
pow(Base, Exponent) -> Base * pow(Base, Exponent - 1).

%% Down the path from node Nid, each node read at the offset its parent
%% gives, as a tuple of its words; node id 0 is no node, so no slot.
descend(_Volume, _Ino, 0, _Path, _Blocks, Nodes) ->
    {none, Nodes};
descend(Volume, Ino, Nid, [{Offset, Index}], Blocks, Nodes) ->
    {Addresses, Decoded} = node(direct_node, Volume, Ino, Nid, Offset, Blocks, Nodes),
    {{Nid, Index, element(Index + 1, Addresses)}, Decoded};
descend(Volume, Ino, Nid, [{Offset, Index} | Path], Blocks, Nodes) ->
    {Children, Decoded} = node(indirect_node, Volume, Ino, Nid, Offset, Blocks, Nodes),
    descend(Volume, Ino, element(Index + 1, Children), Path, Blocks, Decoded).

%% Node Nid at Offset, decoded once a walk: the key holds the offset, so a
%% node decoded at one place is never taken at another.
node(_Kind, _Volume, _Ino, Nid, Offset, _Blocks, Nodes) when is_map_key({Nid, Offset}, Nodes) ->
    {maps:get({Nid, Offset}, Nodes), Nodes};
node(Kind, Volume, Ino, Nid, Offset, Blocks, Nodes) ->
    Words = list_to_tuple(ok(erx_f2fs_codec:Kind(Nid, Ino, Offset,
                                                 node_block(Volume, Nid, Ino, Blocks)))),
    {Words, Nodes#{{Nid, Offset} => Words}}.

%%% Bytes

%% The file's bytes from Offset, cut at its size.
read_bytes(_Volume, #{i_size := Size}, Offset, Length, _Blocks)
  when Offset >= Size; Length =:= 0 ->
    <<>>;
read_bytes(_Volume, #{i_size := Size, inline_data := Data}, Offset, Length, _Blocks) ->
    binary:part(Data, Offset, min(Size, Offset + Length) - Offset);
read_bytes(Volume, #{i_size := Size} = Inode, Offset, Length, Blocks) ->
    End = min(Size, Offset + Length),
    First = Offset div ?BLOCK_SIZE,
    Read = file_blocks(Volume, Inode, range(First, (End - 1) div ?BLOCK_SIZE + 1), Blocks),
    Bytes = << <<(zeros_for_hole(Block))/binary>> || Block <- Read >>,
    binary:part(Bytes, Offset - First * ?BLOCK_SIZE, End - Offset).

zeros_for_hole(hole) -> <<0:(?BLOCK_SIZE * 8)>>;
zeros_for_hole(Bytes) -> Bytes.

%% File blocks Range of Inode, each its bytes, or hole for a hole or a
%% NEW_ADDR slot. Every slot is found first, each node decoded once, and
%% the data blocks are then asked at once.
file_blocks(Volume, Inode, Range, Blocks) ->
    {Slots, _Nodes} = lists:mapfoldl(fun(Block, Nodes) ->
                                             find_slot(Volume, Inode, Block, Blocks, Nodes)
                                     end, #{}, Range),
    Addresses = data_addresses(Slots),
    Data = maps:from_list(lists:zip(Addresses, fetch(Blocks, Addresses))),
    [block_bytes(Slot, Data) || Slot <- Slots].

data_addresses(Slots) ->
    lists:usort([Address || {_Nid, _Index, Address} <- Slots,
                            Address =/= ?ERX_F2FS_NULL_ADDR, Address =/= ?ERX_F2FS_NEW_ADDR]).

block_bytes({_Nid, _Index, Address}, Data) when is_map_key(Address, Data) ->
    maps:get(Address, Data);
block_bytes(_Hole, _Data) ->
    hole.

%% The blocks from First up to End, none when End is not past First.
range(First, End) -> lists:seq(First, max(First, End) - 1).

%%% Directories

require_directory(#{i_mode := Mode}) ->
    require(Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_DIR, {file, type}).

%% The first entry Named finds in the buckets' blocks, read a level at a
%% time, or none.
first_named(_Named, _Volume, _Dir, [], _Blocks) ->
    none;
first_named(Named, Volume, Dir, [Bucket | Buckets], Blocks) ->
    case Named(dentries(Volume, Dir, Bucket, Blocks)) of
        none -> first_named(Named, Volume, Dir, Buckets, Blocks);
        Entry -> Entry
    end.

named(Entries, Name, Hash) ->
    case lists:search(fun(#{name := Named, hash_code := Code}) ->
                              Named =:= Name andalso Code =:= Hash
                      end, Entries) of
        {value, Entry} -> Entry;
        false -> none
    end.

%% The blocks of Hash's bucket at each level a lookup searches, in level
%% order: level n of 2^(n + d) buckets, at most 2^30, under i_dir_level d,
%% each of two blocks below level 31 and four from it on ([F 58]), for the
%% levels below i_current_depth up to the first whose bucket starts at or
%% past the directory's end, since every later level's starts later.
buckets(#{i_current_depth := Depth, i_dir_level := Level} = Dir, Hash) ->
    buckets(0, Depth, Level, 0, Hash, dir_end(Dir)).

buckets(N, Depth, _Level, _Start, _Hash, _End) when N >= Depth ->
    [];
buckets(N, Depth, Level, Start, Hash, End) ->
    Count = 1 bsl min(N + Level, ?ERX_F2FS_DIR_BUCKETS_LOG_MAX),
    Size = case N < ?ERX_F2FS_DIR_WIDE_LEVEL of
               true -> ?ERX_F2FS_DIR_BUCKET_BLOCKS;
               false -> ?ERX_F2FS_DIR_WIDE_BUCKET_BLOCKS
           end,
    First = Start + Hash rem Count * Size,
    case First < End of
        true -> [range(First, min(First + Size, End)) |
                 buckets(N + 1, Depth, Level, Start + Count * Size, Hash, End)];
        false -> []
    end.

%% The block past a directory's last: its size in blocks, never past the
%% largest block a file addresses.
dir_end(#{i_size := Size, addresses := Addresses}) ->
    min((Size + ?BLOCK_SIZE - 1) div ?BLOCK_SIZE,
        length(Addresses) + lists:sum([span(Depth) || Depth <- ?TREE_DEPTHS])).

%% The entries from Position on: the inline ones, or those of at most
%% ?READDIR_BLOCKS blocks from the one holding Position.
entries_from(_Volume, #{inline_dentries := _} = Dir, Position, _Blocks) ->
    {from(Position, placed(ok(erx_f2fs_codec:inline_dentries(Dir)), 0)), done};
entries_from(Volume, Dir, Position, Blocks) ->
    First = Position div ?DENTRY_SLOTS,
    End = dir_end(Dir),
    Last = min(End, First + ?READDIR_BLOCKS),
    Next = case Last < End of
               true -> Last * ?DENTRY_SLOTS;
               false -> done
           end,
    {from(Position, dentries(Volume, Dir, range(First, Last), Blocks)), Next}.

from(Position, Entries) -> [Entry || #{position := At} = Entry <- Entries, At >= Position].

%% The entries of Dir's blocks Range, a hole or a NEW_ADDR slot holding
%% none.
dentries(Volume, Dir, Range, Blocks) ->
    lists:append([placed(ok(erx_f2fs_codec:dentry_block(Bytes)), Block * ?DENTRY_SLOTS)
                  || {Block, Bytes} <- lists:zip(Range, file_blocks(Volume, Dir, Range, Blocks)),
                     Bytes =/= hole]).

%% A dentry area's entries at their positions from Base, "." only at
%% position 0 and ".." only at 1, where the format puts them ([F 61]).
placed(#{entries := Entries}, Base) ->
    [begin
         Entry = maps:remove(slot, Dentry#{position => Base + Slot}),
         require(dot_placed(Entry), {dir, dot}),
         Entry
     end || #{slot := Slot} = Dentry <- Entries].

dot_placed(#{name := <<".">>, position := Position}) -> Position =:= 0;
dot_placed(#{name := <<"..">>, position := Position}) -> Position =:= 1;
dot_placed(#{}) -> true.

%%% Blocks and the one failure path

run(Read) ->
    try
        {ok, Read()}
    catch
        throw:{?MODULE, need, Addresses} -> {need, Addresses};
        throw:{?MODULE, failure, Failure} -> {error, Failure}
    end.

%% The blocks at Addresses, in order, or a need of every one Blocks lacks.
fetch(Blocks, Addresses) ->
    case [Address || Address <- Addresses, not is_map_key(Address, Blocks)] of
        [] -> [maps:get(Address, Blocks) || Address <- Addresses];
        Missing -> throw({?MODULE, need, lists:usort(Missing)})
    end.

ok({ok, Value}) -> Value;
ok({error, Failure}) -> fail(Failure).

require(true, _Failure) -> ok;
require(false, Failure) -> fail(Failure).

-spec fail(failure()) -> no_return().
fail(Failure) -> throw({?MODULE, failure, Failure}).
