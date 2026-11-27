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
node_block/4, which refuses the reserved nids, looks the nid up, the
journal's entry over its NAT block's ([F 35]), and admits the entry only
when it is used, owned by the inode the reader expects and places its node
in the main area at a block the SIT marks valid in a node log's segment.
The codec then checks the block's footer against the nid, the inode and
the node offset the reader expects, so every node of a file is read at its
one place in that file's tree. A data slot likewise names only a valid
block of a data log's segment, so no file reads a node as its data, and
a data block is read only through the slot its summary entry names, the
slot's node and its index there ([F 46]): owned/3 alone takes the entry,
a committed data log's from the pack, else its segment's SSA block, and
each slot/4, read and directory read checks the slots whose blocks it
takes there, so a slot naming another file's block, or one of its own
that another slot owns, reads nothing. A read-write state's set_slot/5
likewise clears an old block's valid bit only when the block's summary,
the state's for a segment it holds, names the slot.

Every function takes two arguments besides its own. The first is the
volume: the map erx_f2fs_mount answers, or at the mount the part of it
that holds the superblock, the checkpoint, the SIT and the NAT. The other
is the blocks read so far, a map from address to block, as the mount
takes them. Each answers {ok, Value}, {need, Addresses} naming the blocks
it needs next, every one inside the NAT, the SSA or the main area, or
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
claims ([F 58]). A readdir takes at most ?READDIR_STEPS steps a call, each
a block that holds data or a run of empty slots that one node leaves, the
span under a node id of 0 and the node ids of 0 after it in the same
indirect node among them, and answers the position the next
call starts from, which is past the one it was given; so its work follows
the blocks and nodes the directory holds, not the size it claims.

A read-write mount's state ("The volume state", "Allocation") is built
here alone, by state/2 from what the mount answers, and changed only by
allocate/3, which hands out a log's next blocks within whole sections,
set_slot/5 and set_node/5, which keep the SIT's valid maps, the
unpublished summaries and the counters, and put_node/3 and
put_dentries/3, which make a block dirty, and write/6, which sets a
file's written blocks in their slots. erx_f2fs_plan reads it through
epoch/1 and hands back the state its checkpoint commits through
committed/3, the one place sections join the free set. Reads of a
read-write volume take view/1, the volume as the state holds it: a dirty
node is read as the block the next checkpoint writes for it, and a data
block's owner is judged against the state's summaries, so a read sees
every change since the checkpoint and no summary a commit replaced.
""".

-export([nat/2, inode/3, slot/4, read/5, symlink/3, lookup/4, readdir/4]).
-export([state/2, allocate/3, set_slot/5, set_node/5, put_node/3, put_dentries/3, logs/1,
         free_sections/1, epoch/1, committed/3, view/1, write/6, encode_node/2]).
-export_type([nat/0, volume/0, slot/0, dentry/0, failure/0, blocks/0, state/0, node_value/0,
              epoch/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
%% The nodes the inode names, by their depth above the data: two direct,
%% two indirect and one double indirect node ([F 53]).
-define(TREE_DEPTHS, [1, 1, 2, 2, 3]).
%% A position counts the slots of the blocks before its own ([F 59]).
-define(DENTRY_SLOTS, erx_f2fs_codec:dentry_slots(?BLOCK_SIZE)).
%% The steps one readdir takes at most, each a dentry block or a run of
%% empty slots one node leaves.
-define(READDIR_STEPS, 8).
%% A summary entry no block holds yet.
-define(NO_SUMMARY, #{nid => 0, version => 0, ofs_in_node => 0}).

-record(state, {volume, logs, free, summaries, sit_dirty, nodes, dentries, counts, orphans,
                allocated}).

-doc "The NAT journal's entries by nid, read only by this module.".
-opaque nat() :: #{non_neg_integer() => erx_f2fs_codec:nat_entry()}.
-doc """
The tables a read needs: the superblock, the checkpoint header with its
version bitmaps, the SIT (element S + 1 for main segment S) and the NAT,
and for a data block's owner the committed logs and their data
summaries from the pack, as erx_f2fs_mount answers them.
""".
-type volume() :: #{superblock := erx_f2fs_codec:superblock(),
                    checkpoint := erx_f2fs_codec:checkpoint(),
                    sit := tuple(), nat := nat(),
                    logs => [{0..5, non_neg_integer(), non_neg_integer(), 0 | 1}],
                    data_summaries => [[erx_f2fs_codec:summary()]], atom() => term()}.
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
                   {data, block_addr | owner} | {file, inline | size | type} | {dir, dot} |
                   {space, no_free_section} | {mode, read_only} |
                   {sit, valid_bit | summary} | {file, unmapped} |
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
valid in a data log's segment, whose summary entry names the slot ([F 46]).
""".
-spec slot(volume(), erx_f2fs_codec:inode(), non_neg_integer(), blocks()) -> result(slot()).
slot(Volume, Inode, Block, Blocks) ->
    run(fun() ->
                {Slot, _Nodes} = find_slot(Volume, Inode, Block, Blocks, #{}),
                owned(Volume, [Slot], Blocks),
                Slot
        end).

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

%% The block of node Nid of inode Ino. Nid names a node, past the reserved
%% nids, whose NAT entries place no node ([F 6]). Its NAT entry is the
%% journal's or its block's in the copy
%% the version bitmap selects ([F 34], [F 35]); the entry is used, owned by
%% Ino and places the node at a valid block of a node log's segment. The
%% owner is checked here as well as in the node's footer, so another file's
%% node is refused before its block is asked for.
node_block(#{superblock := Super, dirty := Dirty}, Nid, Ino, _Blocks) when is_map_key(Nid, Dirty) ->
    Value = maps:get(Nid, Dirty),
    require(node_ino(Value) =:= Ino, {nat, owner}),
    encode_node(Super, Value);
node_block(#{superblock := Super, checkpoint := Header, nat := Journal} = Volume, Nid, Ino, Blocks) ->
    require(erx_f2fs_codec:valid_nid(Super, Nid), {nat, nid}),
    #{block_addr := Address, ino := Owner} =
        case Journal of
            #{Nid := Entry} ->
                Entry;
            #{} ->
                PerBlock = ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK,
                [Block] = fetch(Blocks, [erx_f2fs_codec:current_block(nat, Super, Header,
                                                                      Nid div PerBlock)]),
                lists:nth(Nid rem PerBlock + 1, ok(erx_f2fs_codec:nat_block(Block)))
        end,
    require(Address =/= ?ERX_F2FS_NULL_ADDR, {nat, free}),
    require(Owner =:= Ino, {nat, owner}),
    require(block_kind(Volume, Address) =:= node, {nat, block_addr}),
    [Node] = fetch(Blocks, [Address]),
    Node.

%% The kind of block at Address, data or node, when it is a main area block
%% the SIT marks valid: the kind of log its segment's SIT entry names, so a
%% data slot never reads a node and the NAT never places a node in a data
%% block ([F 21], [F 37]); else none.
block_kind(#{superblock := #{main_blkaddr := Main} = Super, sit := Sit}, Address) ->
    case Address >= Main andalso Address < erx_f2fs_codec:main_end(Super) of
        true ->
            #{valid_map := Map, type := Type} = element((Address - Main) div ?BLOCKS_PER_SEG + 1, Sit),
            case erx_f2fs_codec:bit(Map, (Address - Main) rem ?BLOCKS_PER_SEG) of
                1 when Type < ?ERX_F2FS_LOG_HOT_NODE -> data;
                1 -> node;
                0 -> none
            end;
        false ->
            none
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

%% A slot's address is a hole, NEW_ADDR or a valid block of a data log's
%% segment ([F 4], [F 37]).
checked_slot(_Volume, none) ->
    none;
checked_slot(Volume, {_Nid, _Index, Address} = Slot) ->
    require(Address =:= ?ERX_F2FS_NULL_ADDR orelse Address =:= ?ERX_F2FS_NEW_ADDR orelse
                block_kind(Volume, Address) =:= data,
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
%% NEW_ADDR slot. Every slot is found first, each node decoded once, its
%% owner checked, and the data blocks are then asked at once.
file_blocks(Volume, Inode, Range, Blocks) ->
    {Slots, _Nodes} = lists:mapfoldl(fun(Block, Nodes) ->
                                             find_slot(Volume, Inode, Block, Blocks, Nodes)
                                     end, #{}, Range),
    owned(Volume, Slots, Blocks),
    Addresses = data_addresses(Slots),
    Data = maps:from_list(lists:zip(Addresses, fetch(Blocks, Addresses))),
    [block_bytes(Slot, Data) || Slot <- Slots].

data_addresses(Slots) ->
    lists:usort([Address || {_Nid, _Index, Address} <- Slots, real(Address)]).

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

%% The entries from Position on: the inline ones, or those of the dentry
%% blocks at most ?READDIR_STEPS steps from the block holding Position
%% reach, each step a block that holds data or a run of empty slots.
entries_from(_Volume, #{inline_dentries := _} = Dir, Position, _Blocks) ->
    {from(Position, placed(ok(erx_f2fs_codec:inline_dentries(Dir)), 0)), done};
entries_from(Volume, Dir, Position, Blocks) ->
    {Found, Next} = dentry_blocks(Volume, Dir, Position div ?DENTRY_SLOTS, dir_end(Dir),
                                  ?READDIR_STEPS, Blocks, #{}, []),
    owned(Volume, [Slot || {_Block, Slot} <- Found], Blocks),
    Bytes = fetch(Blocks, [Address || {_Block, {_Nid, _Index, Address}} <- Found]),
    Entries = [placed(ok(erx_f2fs_codec:dentry_block(Data)), Block * ?DENTRY_SLOTS)
               || {{Block, _Slot}, Data} <- lists:zip(Found, Bytes)],
    {from(Position, lists:append(Entries)), Next}.

%% The dentry blocks from Block, {Block, Slot} each, that Steps steps
%% reach before End, and the position the next readdir starts from, or done
%% at End. A step takes one block that holds data, or skips a run of empty
%% slots in one node, so every step moves past Block.
dentry_blocks(_Volume, _Dir, Block, End, _Steps, _Blocks, _Nodes, Found) when Block >= End ->
    {lists:reverse(Found), done};
dentry_blocks(_Volume, _Dir, Block, _End, 0, _Blocks, _Nodes, Found) ->
    {lists:reverse(Found), Block * ?DENTRY_SLOTS};
dentry_blocks(Volume, Dir, Block, End, Steps, Blocks, Nodes, Found) ->
    case extent(Volume, Dir, Block, Blocks, Nodes) of
        {{data, Slot}, Decoded} ->
            dentry_blocks(Volume, Dir, Block + 1, End, Steps - 1, Blocks, Decoded,
                          [{Block, Slot} | Found]);
        {{empty, Count}, Decoded} ->
            dentry_blocks(Volume, Dir, Block + Count, End, Steps - 1, Blocks, Decoded, Found)
    end.

%% What file block Block of Inode holds, and Nodes with the nodes this walk
%% decoded added: {data, Slot}, the slot of a valid block, or {empty, Count}, the
%% run of Count blocks from Block that one node leaves empty, all NULL_ADDR
%% or NEW_ADDR slots of its address array or of one direct node, or the
%% span under node id 0 and under the node ids 0 that follow it in the same
%% indirect node ([F 4], [F 53]); each of the inode's five node ids is a run
%% of its own. Count is at least 1.
extent(Volume, #{addresses := Addresses, footer := #{ino := Ino}}, Block, _Blocks, Nodes)
  when Block < length(Addresses) ->
    {slots_extent(Volume, Ino, Block, lists:nthtail(Block, Addresses)), Nodes};
extent(Volume, #{addresses := Addresses, i_nid := Nids, footer := #{ino := Ino}}, Block, Blocks,
       Nodes) ->
    %% dir_end/1 keeps Block within the blocks a file addresses.
    {Tree, Path} = place(Block - length(Addresses)),
    extent_under(Volume, Ino, lists:nth(Tree + 1, Nids), Path, Blocks, Nodes);
extent(_Volume, _Inode, _Block, _Blocks, _Nodes) ->
    fail({file, inline}).

%% The extent at the end of Path below node Nid: a node id of 0 leaves the
%% rest of its span empty.
extent_under(_Volume, _Ino, 0, Path, _Blocks, Nodes) ->
    {{empty, rest(Path)}, Nodes};
extent_under(Volume, Ino, Nid, [{Offset, Index}], Blocks, Nodes) ->
    {Addresses, Decoded} = node(direct_node, Volume, Ino, Nid, Offset, Blocks, Nodes),
    {slots_extent(Volume, Nid, Index, lists:nthtail(Index, tuple_to_list(Addresses))), Decoded};
extent_under(Volume, Ino, Nid, [{Offset, Index} | Path], Blocks, Nodes) ->
    {Children, Decoded} = node(indirect_node, Volume, Ino, Nid, Offset, Blocks, Nodes),
    case lists:nthtail(Index, tuple_to_list(Children)) of
        [0 | Later] ->
            Absent = length(lists:takewhile(fun(Child) -> Child =:= 0 end, Later)),
            {{empty, rest(Path) + Absent * span(length(Path))}, Decoded};
        [Child | _] ->
            extent_under(Volume, Ino, Child, Path, Blocks, Decoded)
    end.

%% The extent at the head of Slots, node Nid's slots from its slot Index on:
%% its data block's slot, or the run of empty slots it starts.
slots_extent(Volume, Nid, Index, [Address | _] = Slots) ->
    case length(lists:takewhile(fun(Slot) -> not real(Slot) end, Slots)) of
        0 -> {data, checked_slot(Volume, {Nid, Index, Address})};
        Count -> {empty, Count}
    end.

%% The blocks from a path's block to the end of the node the path starts
%% at: the rest of its own child's span, and the spans of the later children.
rest([{_Offset, Index}]) ->
    ?ERX_F2FS_ADDRS_PER_BLOCK - Index;
rest([{_Offset, Index} | Path]) ->
    rest(Path) + (?ERX_F2FS_NIDS_PER_BLOCK - 1 - Index) * span(length(Path)).

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

%%% Owners

%% Each of Slots that holds a real address names a block whose summary
%% entry names that slot, its node and its index there ([F 46]), or the
%% read fails: the durable view's entry, a committed data log's from the
%% pack and else the SSA block of the block's segment, every one the
%% slots' segments lack asked at once. A committed node log's segment
%% holds no data block, so its entries are empty and name no slot.
owned(#{superblock := Super} = Volume, Slots, Blocks) ->
    Held = case Volume of
               #{held := Unpublished} -> Unpublished;
               #{logs := Logs, data_summaries := Data} ->
                   held(Logs, Data, pad([[] || {Type, _, _, _} <- Logs, Type >= ?ERX_F2FS_LOG_HOT_NODE]))
           end,
    Real = [{Nid, Index, place_in_main(Super, Address)}
            || {Nid, Index, Address} <- Slots, real(Address)],
    Summaries = segment_summaries(Super, Held, lists:usort([S || {_, _, {S, _}} <- Real]), Blocks),
    lists:foreach(fun({Nid, Index, {Segno, Offset}}) ->
                          require(names(maps:get(Segno, Summaries), Offset, Nid, Index), {data, owner})
                  end, Real).

%% The summaries a durable view holds outside the SSA, by segment: its
%% committed logs', the data logs' from the pack and the node logs' as
%% Nodes gives them, each a tuple of a segment's entries, empty past the
%% blocks a log has written ([F 45]).
held(Logs, Data, Nodes) ->
    maps:from_list(lists:zip([Segno || {_, Segno, _, _} <- Logs], pad(Data) ++ Nodes)).

%% A main area address's segment and its offset there.
place_in_main(#{main_blkaddr := Main}, Address) ->
    {(Address - Main) div ?BLOCKS_PER_SEG, (Address - Main) rem ?BLOCKS_PER_SEG}.

%% The summary entries of each of Segments, a tuple by segment: Held's,
%% the entries a volume holds outside the SSA, else its SSA block's
%% ([F 45]), every SSA block asked at once.
segment_summaries(#{ssa_blkaddr := Ssa}, Held, Segments, Blocks) ->
    Unheld = [Segno || Segno <- Segments, not is_map_key(Segno, Held)],
    Read = [list_to_tuple(maps:get(entries, ok(erx_f2fs_codec:summary_block(Block))))
            || Block <- fetch(Blocks, [Ssa + Segno || Segno <- Unheld])],
    maps:merge(maps:with(Segments, Held), maps:from_list(lists:zip(Unheld, Read))).

%% Whether entry Offset of a segment's Entries names slot Index of node
%% Nid; an empty entry's nid, 0, is no node's.
names(Entries, Offset, Nid, Index) ->
    case element(Offset + 1, Entries) of
        #{nid := Nid, ofs_in_node := Index} -> true;
        #{} -> false
    end.

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

%%% The volume state

-doc """
State Ino of node Nid's footer and one body: an inode's map, a direct
node's address array or an indirect node's nids ([F 43], [F 53]).
""".
-type node_value() :: {inode, erx_f2fs_codec:inode()} |
                      {direct | indirect, [non_neg_integer()], erx_f2fs_codec:footer()}.

-doc """
A read-write volume's state (docs/design-f2fs.md, "The volume state"):
the tables as they stand, the six logs, the free sections, the
unpublished summaries, the epoch's dirty nodes and dentry blocks and the
counters. Only this module builds or changes it.
""".
-opaque state() :: #state{}.

-doc """
What the next checkpoint writes, from State: the tables, the six logs'
next blocks by type, the SIT segments and NAT entries changed or kept
in a journal since the checkpoint, the unpublished summaries, the dirty
nodes and dentry blocks, the counters and the orphans.
""".
-type epoch() :: #{volume := volume(), logs := [non_neg_integer()],
                   sit_segments := [non_neg_integer()],
                   nat := [{non_neg_integer(), erx_f2fs_codec:nat_entry()}],
                   summaries := [{non_neg_integer(), [erx_f2fs_codec:summary()]}],
                   nodes := [{non_neg_integer(), node_value()}],
                   dentries := [{{non_neg_integer(), non_neg_integer()},
                                 erx_f2fs_codec:dentries()}],
                   counts := #{atom() => non_neg_integer()},
                   orphans := [non_neg_integer()]}.

-doc """
The state of a read-write mount of Mounted, erx_f2fs_mount's answer,
taken from the durable view's blocks: every block live at the
checkpoint and every block of the walk's footprint (docs/design-f2fs.md,
"Read-write mounts: the mount checkpoint"). A section is free when it
holds none of them and no log of the checkpoint holds it. Each log
resumes at the block after the last of them in its section, over all its
segments, and takes the lowest free section instead when no block is
left there, when it is an SSR log, when another log shares its section,
or when the block it would resume at lies in another segment of its
section that holds a live block, whose summary only its SSA block holds.
The committed logs' summaries are their pack's, or for node logs without
them rebuilt from the footers of their segments' valid blocks ([F 31]);
the entries of invalid blocks are read by no one and are left empty.
""".
-spec state(erx_f2fs_mount:mounted(), blocks()) -> result(state()).
state(#{mode := {read_only, _}}, _Blocks) ->
    {error, {mode, read_only}};
state(#{superblock := #{main_blkaddr := Main, segs_per_sec := S},
        checkpoint := Header, sit := Sit, logs := Committed,
        footprint := Footprint, sit_journal := Journal, orphans := Orphans,
        data_summaries := Data, node_summaries := Node} = Mounted, Blocks) ->
    run(fun() ->
                Volume = maps:with([superblock, checkpoint, sit, nat, pack], Mounted),
                Sections = tuple_size(Sit) div S,
                Footed = lists:usort([(A - Main) div ?BLOCKS_PER_SEG div S || A <- Footprint]),
                LogSections = [Segno div S || {_, Segno, _, _} <- Committed],
                Held = lists:usort([Sec || Sec <- lists:seq(0, Sections - 1),
                                           not empty_section(Sit, S, Sec)] ++ Footed ++ LogSections),
                Free = ordsets:subtract(lists:seq(0, Sections - 1), Held),
                Summaries = held(Committed, Data, node_summaries(Volume, Committed, Node, Blocks)),
                State0 = #state{volume = Volume, logs = #{}, free = Free, summaries = Summaries,
                                sit_dirty = lists:usort([Segno || #{segno := Segno} <- Journal]),
                                nodes = #{}, dentries = #{}, orphans = Orphans, allocated = 0,
                                counts = maps:with([valid_block_count, valid_node_count,
                                                    valid_inode_count], Header)},
                lists:foldl(fun(Log, State) -> resume(State, Log, Footprint, LogSections) end,
                            State0, Committed)
        end).

%% The committed node logs' summaries: the pack's, or each valid block's
%% footer's nid ([F 31], [F 46]).
node_summaries(_Volume, _Logs, Node, _Blocks) when Node =/= none -> pad(Node);
node_summaries(#{superblock := #{main_blkaddr := Main}, sit := Sit}, Logs, none, Blocks) ->
    [begin
         #{valid_map := Map} = element(Segno + 1, Sit),
         Valid = [I || {I, 1} <- lists:enumerate(0, [B || <<B:1>> <= Map])],
         Footers = maps:from_list(
                     [{I, ok(erx_f2fs_codec:node_footer(Block))}
                      || {I, Block} <- lists:zip(Valid, fetch(Blocks, [Main + Segno * ?BLOCKS_PER_SEG + I
                                                                       || I <- Valid]))]),
         list_to_tuple([case Footers of
                            #{I := #{nid := Nid}} -> #{nid => Nid, version => 0, ofs_in_node => 0};
                            #{} -> ?NO_SUMMARY
                        end || I <- lists:seq(0, ?BLOCKS_PER_SEG - 1)])
     end || {Type, Segno, _, _} <- Logs, Type >= ?ERX_F2FS_LOG_HOT_NODE].

pad(Lists) ->
    [list_to_tuple(Entries ++ lists:duplicate(?BLOCKS_PER_SEG - length(Entries), ?NO_SUMMARY))
     || Entries <- Lists].

empty_section(Sit, S, Sec) ->
    lists:all(fun(Segno) -> maps:get(valid_blocks, element(Segno + 1, Sit)) =:= 0 end,
              lists:seq(Sec * S, Sec * S + S - 1)).

%% A log's next block at mount, from the last durable block in its section.
resume(#state{volume = #{superblock := #{main_blkaddr := Main, segs_per_sec := S}, sit := Sit}} = State,
       {Type, Segno, Offset, Alloc}, Footprint, LogSections) ->
    Sec = Segno div S,
    First = Main + Sec * S * ?BLOCKS_PER_SEG,
    Live = [First + K * ?BLOCKS_PER_SEG + I
            || K <- lists:seq(0, S - 1),
               #{valid_map := Map} <- [element(Sec * S + K + 1, Sit)],
               {I, 1} <- lists:enumerate(0, [B || <<B:1>> <= Map])],
    InSection = [A || A <- Footprint, A >= First, A < First + S * ?BLOCKS_PER_SEG],
    Next = lists:max([Main + Segno * ?BLOCKS_PER_SEG + Offset | [A + 1 || A <- Live ++ InSection]]),
    NextSegno = (Next - Main) div ?BLOCKS_PER_SEG,
    Shared = length([L || L <- LogSections, L =:= Sec]) > 1,
    Stranded = NextSegno =/= Segno andalso Next < First + S * ?BLOCKS_PER_SEG andalso
        maps:get(valid_blocks, element(NextSegno + 1, Sit)) > 0,
    case Alloc =:= ?ERX_F2FS_ALLOC_SSR orelse Shared orelse Stranded orelse
        Next =:= First + S * ?BLOCKS_PER_SEG of
        true -> take_section(State, Type);
        false when NextSegno =:= Segno -> put_log(State, Type, Next);
        false -> enter(put_log(State, Type, Next), Type, NextSegno)
    end.

put_log(#state{logs = Logs} = State, Type, Next) -> State#state{logs = Logs#{Type => Next}}.

%% The log takes the lowest free section and enters its first segment.
take_section(#state{free = []}, _Type) ->
    fail({space, no_free_section});
take_section(#state{free = [Sec | Free],
                    volume = #{superblock := #{main_blkaddr := Main, segs_per_sec := S}}} = State,
             Type) ->
    enter(put_log(State#state{free = Free}, Type, Main + Sec * S * ?BLOCKS_PER_SEG), Type, Sec * S).

%% A log enters Segno, a segment with no live block: the SIT gives it the
%% log's type and its summary starts empty.
enter(#state{volume = #{sit := Sit} = Volume, sit_dirty = Dirty, summaries = Summaries} = State,
      Type, Segno) ->
    Entry = element(Segno + 1, Sit),
    State#state{volume = Volume#{sit := setelement(Segno + 1, Sit, Entry#{type := Type})},
                sit_dirty = ordsets:add_element(Segno, Dirty),
                summaries = Summaries#{Segno => erlang:make_tuple(?BLOCKS_PER_SEG, ?NO_SUMMARY)}}.

-doc """
The next N blocks of log Type (docs/design-f2fs.md, "Allocation"), in
order, and the state with the log past them: within its section, then
the lowest free section, or enospc, the state unchanged.
""".
-spec allocate(state(), 0..5, non_neg_integer()) ->
          {ok, [non_neg_integer()], state()} | {error, enospc}.
allocate(State, Type, N) ->
    try
        {Addresses, Next} = lists:mapfoldl(fun(_, S) -> advance(S, Type) end, State, lists:seq(1, N)),
        {ok, Addresses, Next#state{allocated = Next#state.allocated + N}}
    catch
        throw:{?MODULE, failure, {space, no_free_section}} -> {error, enospc}
    end.

advance(#state{logs = Logs, volume = #{superblock := #{main_blkaddr := Main,
                                                        segs_per_sec := S}}} = State, Type) ->
    #{Type := Address} = Logs,
    Next = Address + 1,
    State1 = put_log(State, Type, Next),
    {Address, case (Next - Main) rem (S * ?BLOCKS_PER_SEG) of
                  0 -> take_section(State1, Type);
                  At when At rem ?BLOCKS_PER_SEG =:= 0 -> enter(State1, Type, (Next - Main) div ?BLOCKS_PER_SEG);
                  _ -> State1
              end}.

-doc "The next block of each log, by type.".
-spec logs(state()) -> [non_neg_integer()].
logs(#state{logs = Logs}) -> [maps:get(Type, Logs) || Type <- lists:seq(0, ?ERX_F2FS_SIT_TYPES - 1)].

-doc "The free sections, in order.".
-spec free_sections(state()) -> [non_neg_integer()].
free_sections(#state{free = Free}) -> Free.

-doc "State with node Nid's value Value dirty, to be written by the next checkpoint.".
-spec put_node(state(), non_neg_integer(), node_value()) -> state().
put_node(#state{nodes = Nodes} = State, Nid, Value) -> State#state{nodes = Nodes#{Nid => Value}}.

-doc """
State with the dentry block of slot Index of node Owner dirty, holding
Dentries; the next checkpoint writes it to the warm data log.
""".
-spec put_dentries(state(), {non_neg_integer(), non_neg_integer()}, erx_f2fs_codec:dentries()) ->
          state().
put_dentries(#state{dentries = Dentries} = State, Slot, Value) ->
    State#state{dentries = Dentries#{Slot => Value}}.

-doc """
State with slot Index of dirty node Owner, an inode's address array or a
direct node, holding Address (docs/design-f2fs.md, "Allocation"): the
old address's valid bit cleared when its block's summary names the slot,
the new one's set with its summary entry, the owning inode's i_blocks
moved by the slots' weights, a real address or NEW_ADDR one and
NULL_ADDR none, and valid_block_count by the same less an old block the
summary does not confirm, which stays its owner's ([F 46]).
""".
-spec set_slot(state(), non_neg_integer(), non_neg_integer(), non_neg_integer(), blocks()) ->
          result(state()).
set_slot(#state{nodes = Nodes} = State, Owner, Index, Address, Blocks) ->
    run(fun() ->
                {Ino, Old, Node} = case maps:get(Owner, Nodes) of
                                       {inode, #{addresses := As} = I} ->
                                           {Owner, lists:nth(Index + 1, As),
                                            {inode, I#{addresses := replace(As, Index, Address)}}};
                                       {direct, As, #{ino := I} = Footer} ->
                                           {I, lists:nth(Index + 1, As),
                                            {direct, replace(As, Index, Address), Footer}}
                                   end,
                #{version := Version} = nat_entry(State, Owner, Blocks),
                Summary = #{nid => Owner, version => Version, ofs_in_node => Index},
                %% The old address the slot gives up: a block its summary does
                %% not confirm stays its owner's, so the slot clears nothing.
                Cleared = case not real(Old) orelse confirms(State, Old, Owner, Index, Blocks) of
                              true -> Old;
                              false -> ?ERX_F2FS_NULL_ADDR
                          end,
                State1 = mark(unmark(put_node(State, Owner, Node), Cleared), Address, Summary),
                count(State1, Ino, weight(Address) - weight(Old),
                      [{valid_block_count, weight(Address) - weight(Cleared)}])
        end).

-doc """
State with node Nid of inode Ino at Address (docs/design-f2fs.md,
"Allocation"): its NAT entry, a summary entry for a real address, and
every count a node block is in. A node that comes into being, its entry
NULL_ADDR before, adds one to valid_node_count, valid_block_count and
its inode's i_blocks, and an inode one to valid_inode_count; a freed
node, Address NULL_ADDR, takes away exactly that and bumps its entry's
version ([F 33]); a node that moves changes no count. The inode whose
i_blocks changes must be dirty.
""".
-spec set_node(state(), non_neg_integer(), non_neg_integer(), non_neg_integer(), blocks()) ->
          result(state()).
set_node(State, Nid, Ino, Address, Blocks) ->
    run(fun() ->
                #{block_addr := Old, version := Version} = Entry = nat_entry(State, Nid, Blocks),
                Delta = weight(Address) - weight(Old),
                Bumped = case Delta of
                             -1 -> (Version + 1) band 16#ff;
                             _ -> Version
                         end,
                #state{volume = #{nat := Nat} = Volume} = State1 =
                    mark(unmark(State, Old), Address, #{nid => Nid, version => 0, ofs_in_node => 0}),
                State2 = State1#state{volume = Volume#{nat := Nat#{Nid => Entry#{block_addr := Address,
                                                                               ino := Ino,
                                                                               version := Bumped}}}},
                Counts = [{valid_node_count, Delta}, {valid_block_count, Delta}] ++
                    [{valid_inode_count, Delta} || Nid =:= Ino],
                case Delta of
                    -1 when Nid =:= Ino -> count(forget(State2, Nid), none, Delta, Counts);
                    -1 -> count(forget(State2, Nid), Ino, Delta, Counts);
                    _ -> count(State2, Ino, Delta, Counts)
                end
        end).

%% Whether Old, the real address slot Index of node Owner held, is a valid
%% block of a data log's segment whose summary names that slot: the
%% state's for a segment it holds, else its SSA block's. Any other address
%% is no block the slot owns.
confirms(#state{volume = #{superblock := Super} = Volume, summaries = Held}, Old, Owner, Index,
         Blocks) ->
    block_kind(Volume, Old) =:= data andalso
        begin
            {Segno, Offset} = place_in_main(Super, Old),
            #{Segno := Entries} = segment_summaries(Super, Held, [Segno], Blocks),
            names(Entries, Offset, Owner, Index)
        end.

%% A freed node is no longer dirty, nor any dentry block in its slots, so
%% no checkpoint writes it back.
forget(#state{nodes = Nodes, dentries = Dentries} = State, Nid) ->
    State#state{nodes = maps:remove(Nid, Nodes),
                dentries = maps:filter(fun({Owner, _}, _) -> Owner =/= Nid end, Dentries)}.

%% A node's NAT entry as it stands: the epoch's or the journal's, else its
%% block's in the selected copy.
nat_entry(#state{volume = #{superblock := Super, checkpoint := Header, nat := Nat}}, Nid, Blocks) ->
    require(Nid < erx_f2fs_codec:nat_capacity(Super), {nat, nid}),
    case Nat of
        #{Nid := Entry} ->
            Entry;
        #{} ->
            PerBlock = ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK,
            [Block] = fetch(Blocks, [erx_f2fs_codec:current_block(nat, Super, Header, Nid div PerBlock)]),
            lists:nth(Nid rem PerBlock + 1, ok(erx_f2fs_codec:nat_block(Block)))
    end.

weight(?ERX_F2FS_NULL_ADDR) -> 0;
weight(_) -> 1.

real(Address) -> Address =/= ?ERX_F2FS_NULL_ADDR andalso Address =/= ?ERX_F2FS_NEW_ADDR.

%% The valid bit of a real address, cleared or set; a block has one owner,
%% so a bit is never set twice or cleared when clear.
unmark(State, Address) ->
    case real(Address) of
        true -> valid_bit(State, Address, 0, none);
        false -> State
    end.

mark(State, Address, Summary) ->
    case real(Address) of
        true -> valid_bit(State, Address, 1, Summary);
        false -> State
    end.

valid_bit(#state{volume = #{superblock := #{main_blkaddr := Main} = Super, sit := Sit} = Volume,
                 sit_dirty = Dirty, summaries = Summaries} = State, Address, Bit, Summary) ->
    require(Address >= Main andalso Address < erx_f2fs_codec:main_end(Super), {data, block_addr}),
    Segno = (Address - Main) div ?BLOCKS_PER_SEG,
    Offset = (Address - Main) rem ?BLOCKS_PER_SEG,
    #{valid_map := Map, valid_blocks := Count} = Entry = element(Segno + 1, Sit),
    <<Before:Offset/bitstring, Was:1, After/bitstring>> = Map,
    require(Was =:= 1 - Bit, {sit, valid_bit}),
    Sit1 = setelement(Segno + 1, Sit, Entry#{valid_map := <<Before/bitstring, Bit:1, After/bitstring>>,
                                             valid_blocks := Count + 2 * Bit - 1}),
    Summaries1 = case Summary of
                     none -> Summaries;
                     #{} ->
                         require(is_map_key(Segno, Summaries), {sit, summary}),
                         maps:update_with(Segno, fun(T) -> setelement(Offset + 1, T, Summary) end,
                                          Summaries)
                 end,
    State#state{volume = Volume#{sit := Sit1}, sit_dirty = ordsets:add_element(Segno, Dirty),
                summaries = Summaries1}.

%% The counters by Deltas, and Ino's i_blocks by Delta, unless Ino is none.
count(#state{counts = Counts} = State, Ino, Delta, Deltas) ->
    Counts1 = lists:foldl(fun({Name, D}, C) -> maps:update_with(Name, fun(V) -> V + D end, C) end,
                          Counts, Deltas),
    State1 = State#state{counts = Counts1},
    case Ino =:= none orelse Delta =:= 0 of
        true -> State1;
        false ->
            {inode, #{i_blocks := IBlocks} = Inode} = maps:get(Ino, State1#state.nodes),
            put_node(State1, Ino, {inode, Inode#{i_blocks := IBlocks + Delta}})
    end.

replace(List, Index, Value) ->
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ [Value | After].

-doc """
The volume as State holds it, for reads (docs/design-f2fs.md, "Inodes"):
its tables, its dirty nodes and its summaries, which a read takes for a
segment they hold over the pack's and the SSA's. Only a checkpoint makes
a dentry block dirty, and it commits it, so between requests the state
holds none and the view takes none.
""".
-spec view(state()) -> volume().
view(#state{volume = Volume, nodes = Nodes, summaries = Summaries, dentries = Dentries})
  when map_size(Dentries) =:= 0 ->
    Volume#{dirty => Nodes, held => Summaries}.

-doc """
The block a node's value is written as: its footer and its body, an
inode's under Super's rules ([F 41], [F 43], [F 53]).
""".
-spec encode_node(erx_f2fs_codec:superblock(), node_value()) -> binary().
encode_node(Super, {inode, Inode}) -> erx_f2fs_codec:encode_inode(Super, Inode);
encode_node(_Super, {direct, Addresses, Footer}) -> erx_f2fs_codec:encode_direct_node(Addresses, Footer);
encode_node(_Super, {indirect, Nids, Footer}) -> erx_f2fs_codec:encode_indirect_node(Nids, Footer).

node_ino({inode, #{footer := #{ino := Ino}}}) -> Ino;
node_ino({_Kind, _Body, #{ino := Ino}}) -> Ino.

-doc """
State with file blocks Placed of regular file Ino, each {Block, Address}
a block written at Address of the warm data log, set in its slot
(docs/design-f2fs.md, "Operations"): the node holding the slot made
dirty, from the medium when it was clean, then set_slot/5; and the
inode's size raised to at least Size, its mtime and ctime Time, in
nanoseconds. A slot no node holds fails {file, unmapped}: the step that
claimed the blocks checked each slot first, so only a bug reaches it.
""".
-spec write(state(), non_neg_integer(), [{non_neg_integer(), non_neg_integer()}], non_neg_integer(),
            non_neg_integer(), blocks()) -> result(state()).
write(State0, Ino, Placed, Size, Time, Blocks) ->
    run(fun() ->
                State = lists:foldl(fun({Block, Address}, S) -> place_block(S, Ino, Block, Address, Blocks) end,
                                    dirty_inode(State0, Ino, Blocks), Placed),
                {inode, #{i_size := Old} = Inode} = maps:get(Ino, State#state.nodes),
                Seconds = Time div 1000000000,
                Nanos = Time rem 1000000000,
                put_node(State, Ino, {inode, Inode#{i_size := max(Old, Size),
                                                    i_mtime := Seconds, i_mtime_nsec := Nanos,
                                                    i_ctime := Seconds, i_ctime_nsec := Nanos}})
        end).

%% State with inode Ino dirty, from the medium when it was clean.
dirty_inode(#state{nodes = Nodes} = State, Ino, _Blocks) when is_map_key(Ino, Nodes) ->
    State;
dirty_inode(#state{volume = #{superblock := Super}} = State, Ino, Blocks) ->
    Inode = ok(erx_f2fs_codec:inode(Super, Ino, node_block(view(State), Ino, Ino, Blocks))),
    put_node(State, Ino, {inode, Inode}).

%% File block Block of inode Ino set to Address, its slot's node dirty.
place_block(#state{nodes = Nodes} = State, Ino, Block, Address, Blocks) ->
    {inode, Inode} = maps:get(Ino, Nodes),
    View = view(State),
    case find_slot(View, Inode, Block, Blocks, #{}) of
        {none, _} ->
            fail({file, unmapped});
        {{Ino, Index, _Old}, _} ->
            ok(set_slot(State, Ino, Index, Address, Blocks));
        {{Nid, Index, _Old}, Decoded} ->
            Dirty = case Nodes of
                        #{Nid := _} -> State;
                        #{} ->
                            [Words] = [W || {N, _Offset} := W <- Decoded, N =:= Nid],
                            Footer = ok(erx_f2fs_codec:node_footer(node_block(View, Nid, Ino, Blocks))),
                            put_node(State, Nid, {direct, tuple_to_list(Words), Footer})
                    end,
            ok(set_slot(Dirty, Nid, Index, Address, Blocks))
    end.

-doc "What the next checkpoint writes, from State.".
-spec epoch(state()) -> epoch().
epoch(#state{volume = #{nat := Nat} = Volume, sit_dirty = Sit, summaries = Summaries, nodes = Nodes,
             dentries = Dentries, counts = Counts, orphans = Orphans} = State) ->
    #{volume => Volume, logs => logs(State), sit_segments => Sit, nat => lists:sort(maps:to_list(Nat)),
      summaries => lists:sort([{Segno, tuple_to_list(T)} || Segno := T <- Summaries]),
      nodes => lists:sort(maps:to_list(Nodes)), dentries => lists:sort(maps:to_list(Dentries)),
      counts => Counts, orphans => Orphans}.

-doc """
State once a checkpoint whose header is Header, in the pack at Pack, has
committed (docs/design-f2fs.md, "Checkpoints"): the epoch's dirty state
cleared, the summaries the six logs' alone, and the free set every
section with no live block that no log holds, so the sections the epoch
emptied join it here and nowhere else.
""".
-spec committed(state(), erx_f2fs_codec:checkpoint(), non_neg_integer()) -> state().
committed(#state{volume = #{superblock := #{main_blkaddr := Main, segs_per_sec := S}, sit := Sit} = Volume,
                 summaries = Summaries} = State, Header, Pack) ->
    LogSegments = [(A - Main) div ?BLOCKS_PER_SEG || A <- logs(State)],
    LogSections = [Segno div S || Segno <- LogSegments],
    Free = [Sec || Sec <- lists:seq(0, tuple_size(Sit) div S - 1),
                   not lists:member(Sec, LogSections), empty_section(Sit, S, Sec)],
    State#state{volume = Volume#{checkpoint := Header, pack => Pack, nat := #{}},
                free = Free, summaries = maps:with(LogSegments, Summaries),
                sit_dirty = [], nodes = #{}, dentries = #{}, allocated = 0}.
