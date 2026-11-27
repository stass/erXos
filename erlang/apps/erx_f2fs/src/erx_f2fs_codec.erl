%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_codec).
-moduledoc """
F2FS's on-disk records read from a volume's blocks and built into them
(docs/design-f2fs.md, "Reading the medium" and "The core"): the only module
that reads or builds block bytes. The layouts are abi/formats/f2fs.txt's,
read and written by erx_abi_packed; this module checks every
value a decoder reads against its bounds before anything uses it, following
the rules Linux enforces on reads and adding the bounds Linux leaves out:
the version bitmaps' room in the checkpoint pack, an inode's name length
against its field, and an inline file's size against its inline area
whatever else the inode holds. [F n] cites fact n of the F2FS facts
record, part 1.

Each decoder takes whole 4096-byte blocks, or a journal's 507 bytes, and
answers {ok, Record}, or
{error, {Structure, Rule}} naming the structure and the first rule its bytes
broke: a decoder fails at its first error by one module-private throw,
caught once at its entry. What a decoder checks is one record's own
consistency; the rules that relate records, or a record to the partition,
are the mount's (docs/design-f2fs.md, "Mount").

The superblock (superblock/1) is read from either copy's block. When the
mount chooses a pack ([F 22]), it reads the pack's first block, its header,
with checkpoint/1, and its last block, the header's copy, with
checkpoint_copy/1, which checks only what Linux checks of it. The chosen
pack's header is read again with its payload blocks by checkpoint/3, which
adds the SIT and NAT version bitmaps; both bitmaps are
first-bit-most-significant ([F 5]), Erlang's own bit order, so they are the
bytes as they are. An orphan block (orphan_block/1) answers its inode
numbers.

The tables: a NAT block (nat_block/1) answers its entries, a SIT block
(sit_block/2) the entries of the main area's segments it holds, each under
its own rules ([F 39]). A summary block (summary_block/1) answers its
entries and its journal's bytes, which nat_journal/1 or sit_journal/1 reads
by the log the summary is for ([F 28]); a pack's compact data summaries
(compact_summaries/2) answer both journals and each data log's entries.

An inode block (inode/3) answers the inode's fields and its body: the
address words, or with INLINE_DATA the file's bytes, or with INLINE_DENTRY
its inline dentries, where its geometry puts them ([F 41], [F 48]). A
dentry block (dentry_block/1) answers its used slots. Both dentry forms
are read by one walk, which fails an area holding a name no path can
hold; their bitmaps are first-bit-least-significant ([F 5]), and the
codec answers each as a bitstring in Erlang's own order, first bit most
significant, which bit/2 reads for every bitmap. A name's hash in its
directory is dentry_hash/1 ([F 57]). A direct node (direct_node/4) answers its
addresses and an indirect node (indirect_node/4) its node ids, once its
footer shows it is the node its parent names ([F 43], [F 53]). Any
block's last bytes read as a node footer (node_footer/1), which is how the
mount asks whether a log's next block holds a node of the checkpoint
([F 43]).

The encoders build the records erXos writes, each from the value its
decoder answers and in the one form erXos writes it
(docs/design-f2fs.md, "Scope: features and forms"): a superblock, a
checkpoint pack's header and payload, an orphan block, NAT and SIT blocks,
a summary block in the normal form, an inode whose body is its address
array, direct and indirect nodes, and a dentry block. On that form each is
the inverse of its decoder: decoding what an encoder builds answers the
value it was given, and encoding what a decoder answers gives back the
block's bytes wherever the block holds nothing the value leaves out. What
a value leaves out is written as zeros: padding, reserved bytes, the check
words no one computes, a free dentry slot. Every checksum that applies is
computed by the same function its reader checks it with; i_ext is written
with len 0 ([F 44]). The forms erXos only reads (compact summaries,
journals other than empty ones, inline data and dentries) have no encoder;
a summary block is always written with an empty journal.
""".

-export([superblock/1, checkpoint/1, checkpoint_copy/1, checkpoint/3,
         orphan_block/1, nat_block/1, nat_journal/1, sit_block/2,
         sit_journal/1, summary_block/1, compact_summaries/2, inode/3,
         direct_node/4, indirect_node/4, dentry_block/1, inline_dentries/1,
         node_footer/1, crc/2,
         encode_superblock/1, encode_checkpoint/2, encode_orphan_block/3, encode_pack/4,
         encode_nat_block/1, encode_sit_block/1, encode_summary_block/2,
         encode_inode/2, encode_direct_node/2, encode_indirect_node/2,
         encode_dentry_block/1, empty_journal/0,
         dentry_hash/1, dentry_slots/1, bit/2, extra_attr_features/0,
         nat_capacity/1, valid_nid/2, node_capacity/1, main_end/1, copy_blocks/1, bitmap_bytes/1,
         table_block/4, current_block/4]).
-export_type([superblock/0, checkpoint/0, nat_entry/0, sit_entry/0,
              summary/0, inode/0, dentries/0, footer/0, failure/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
%% A checksum, an address and a node id are each a 32-bit word.
-define(CHECKSUM_SIZE, 4).
-define(WORD, 4).
-define(WORD_MASK, 16#ffffffff).
%% The features whose inodes Linux reads only with EXTRA_ATTR set ([F 41]).
-define(NEED_EXTRA_ATTR, (?ERX_F2FS_FEATURE_PRJQUOTA bor
                          ?ERX_F2FS_FEATURE_INODE_CHKSUM bor
                          ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR bor
                          ?ERX_F2FS_FEATURE_INODE_CRTIME bor
                          ?ERX_F2FS_FEATURE_COMPRESSION)).
%% The seven file types of i_mode ([F 66]).
-define(FILE_TYPES, [?ERX_F2FS_MODE_FIFO, ?ERX_F2FS_MODE_CHR,
                     ?ERX_F2FS_MODE_DIR, ?ERX_F2FS_MODE_BLK,
                     ?ERX_F2FS_MODE_REG, ?ERX_F2FS_MODE_LNK,
                     ?ERX_F2FS_MODE_SOCK]).

-doc "A superblock copy: erx_abi_packed's map of erx_f2fs_super_block.".
-type superblock() :: #{atom() => term()}.
-doc """
A checkpoint pack's header: erx_abi_packed's map of erx_f2fs_checkpoint
with crc, the checksum it stores at checksum_offset, and from checkpoint/3
also sit_version_bitmap and nat_version_bitmap.
""".
-type checkpoint() :: #{atom() => term()}.
-doc "A NAT entry: erx_abi_packed's map of erx_f2fs_nat_entry.".
-type nat_entry() :: #{version := byte(), ino := non_neg_integer(),
                       block_addr := non_neg_integer()}.
-doc """
A SIT entry: its valid blocks and log type from vblocks, its valid map,
first bit most significant, and its age ([F 37]).
""".
-type sit_entry() :: #{valid_blocks := non_neg_integer(),
                       type := non_neg_integer(), valid_map := binary(),
                       mtime := non_neg_integer()}.
-doc "A summary entry: erx_abi_packed's map of erx_f2fs_summary_entry.".
-type summary() :: #{nid := non_neg_integer(), version := byte(),
                     ofs_in_node := 0..16#ffff}.
-doc """
An inode: erx_abi_packed's map of erx_f2fs_inode with i_name cut to
i_namelen; the fields of erx_f2fs_inode_extra that lie within its
i_extra_isize bytes, every other one 0, and i_extra_isize 0 without
EXTRA_ATTR; i_nid; footer; inline_xattr, the X words of the inline xattr
area as bytes; and one body: addresses, the 923 - E - X address words from
word E, or inline_data, or inline_dentries, the inline content's bytes,
which inline_dentries/1 reads ([F 41], [F 48]).
""".
-type inode() :: #{atom() => term()}.
-doc """
A dentry area's slots: bitmap, one bit per slot in slot order, and each
used slot's record with its name ([F 59], [F 60]).
""".
-type dentries() :: #{bitmap := bitstring(),
                      entries := [#{slot := non_neg_integer(),
                                    hash_code := non_neg_integer(),
                                    ino := non_neg_integer(),
                                    file_type := byte(),
                                    name := binary()}]}.
-doc "A node block's footer: erx_abi_packed's map of erx_f2fs_node_footer.".
-type footer() :: #{nid := non_neg_integer(), ino := non_neg_integer(),
                    flag := non_neg_integer(), cp_ver := non_neg_integer(),
                    next_blkaddr := non_neg_integer()}.
-doc "The structure a decoder read and the first rule its bytes broke.".
-type failure() :: {superblock | checkpoint | orphan_block | nat_block |
                    nat_journal | sit_block | sit_journal | summary_block |
                    compact_summary | inode | direct_node | indirect_node |
                    dentry_block | inline_dentries | node_footer,
                    atom()}.

%%% Entries

-doc """
The superblock copy at byte 1024 of Block, block 0 or block 1 of the
volume ([F 7]), valid under every rule of [F 54] that concerns one copy:
the magic, the checksum when SB_CHKSUM is set ([F 13]), the block,
segment and sector sizes, the segment and section counts, the device list,
the extension counts, the payload's bound, the reserved inode numbers and
the six areas' boundaries ([F 14]).
""".
-spec superblock(binary()) -> {ok, superblock()} | {error, failure()}.
superblock(Block) ->
    decode(superblock, fun() -> read_superblock(Block) end).

-doc """
A checkpoint pack's header block, valid when its checksum verifies at a
checksum_offset within the block ([F 51]) and its pack's block count is
above the header and its copy and within a segment ([F 22]).
""".
-spec checkpoint(binary()) -> {ok, checkpoint()} | {error, failure()}.
checkpoint(Block) ->
    decode(checkpoint, fun() -> read_checkpoint(Block) end).

-doc """
A checkpoint pack's last block, the copy of its header, valid when its
checksum verifies ([F 51]); Linux checks nothing else of it but that its
checkpoint_ver is the header's, which the mount compares ([F 22]).
""".
-spec checkpoint_copy(binary()) -> {ok, checkpoint()} | {error, failure()}.
checkpoint_copy(Block) ->
    decode(checkpoint, fun() -> read_checkpoint_copy(Block) end).

-doc """
A checkpoint pack's header block, as checkpoint/1 reads it, with its
version bitmaps ([F 23]). Where they lie follows from Super's cp_payload,
and Payload must be exactly that many blocks, the ones after the header:
with none, the header holds both bitmaps; with some, the header holds the
NAT bitmap and the payload the SIT bitmap. Each bitmap must fit the room
it claims, which Linux does not check: before the checksum, or within the
payload. A LARGE_NAT_BITMAP pack, whose bitmaps lie elsewhere ([F 24]),
is refused here because its bitmaps cannot be placed; the mount's set of
checkpoint flags, which refuses the flag too, is the authority on it
(docs/design-f2fs.md, "Scope: features and forms").
""".
-spec checkpoint(superblock(), binary(), [binary()]) ->
          {ok, checkpoint()} | {error, failure()}.
checkpoint(#{cp_payload := PayloadBlocks}, Block, Payload) ->
    decode(checkpoint,
           fun() -> read_checkpoint(PayloadBlocks, Block, Payload) end).

-doc """
The inode numbers an orphan block holds: the first entry_count of its
slots, at most f2fs_orphans_per_block ([F 26]). Its check_sum, blk_addr
and blk_count are read by no one.
""".
-spec orphan_block(binary()) ->
          {ok, [non_neg_integer()]} | {error, failure()}.
orphan_block(Block) ->
    decode(orphan_block, fun() -> read_orphans(Block) end).

-doc """
A NAT block's f2fs_nat_entries_per_block entries, entry k for the block's
k-th nid ([F 33]). Where a used entry's block lies, and whether the SIT
marks it valid, are the mount's to check ([F 35]).
""".
-spec nat_block(binary()) -> {ok, [nat_entry()]} | {error, failure()}.
nat_block(Block) ->
    decode(nat_block, fun() -> read_nat_block(Block) end).

-doc """
A NAT journal's entries, each a nid and its NAT entry, at most
f2fs_nat_journal_entries of them ([F 32], [F 47]).
""".
-spec nat_journal(binary()) ->
          {ok, [#{nid := non_neg_integer(), entry := nat_entry()}]} |
          {error, failure()}.
nat_journal(Journal) ->
    decode(nat_journal, fun() -> read_nat_journal(Journal) end).

-doc """
The first Used entries of a SIT block, Used being how many of the main
area's segments it holds, at most f2fs_sit_entries_per_block: Linux checks
only main segments' entries ([F 39]).
""".
-spec sit_block(binary(), non_neg_integer()) ->
          {ok, [sit_entry()]} | {error, failure()}.
sit_block(Block, Used) ->
    decode(sit_block, fun() -> read_sit_block(Block, Used) end).

-doc """
A SIT journal's entries, each a segment number and its SIT entry, at most
f2fs_sit_journal_entries of them ([F 32], [F 47]); whether each segment is
in the main area is the mount's to check ([F 39]).
""".
-spec sit_journal(binary()) ->
          {ok, [#{segno := non_neg_integer(), entry := sit_entry()}]} |
          {error, failure()}.
sit_journal(Journal) ->
    decode(sit_journal, fun() -> read_sit_journal(Journal) end).

-doc """
A summary block: its f2fs_summaries_per_block entries in block order, its
journal's bytes and its entry_type ([F 45]). Its check_sum is read by no
one.
""".
-spec summary_block(binary()) ->
          {ok, #{entries := [summary()], journal := binary(),
                 entry_type := byte()}} | {error, failure()}.
summary_block(Block) ->
    decode(summary_block, fun() -> read_summary_block(Block) end).

-doc """
A pack's data summaries in the compact form ([F 29]): the NAT and SIT
journals' bytes from the first of Blocks, and Counts, each data log's
entry count in log order, at most a segment's blocks, as summaries read on
from there through the rest of Blocks, which must hold them.
""".
-spec compact_summaries([non_neg_integer()], [binary()]) ->
          {ok, #{nat_journal := binary(), sit_journal := binary(),
                 summaries := [[summary()]]}} | {error, failure()}.
compact_summaries(Counts, Blocks) ->
    decode(compact_summary, fun() -> read_compact(Counts, Blocks) end).

-doc """
The inode Nid of a volume whose superblock is Super, from its node block:
valid under every rule of [F 41], [F 42] and [F 50] that concerns one
inode block and its volume's features, with its body where its geometry
puts it ([F 48]). A directory's i_current_depth above 63 reads as 63, as
Linux reads it ([F 42]), so an inode written back from the map carries 63.
Whether its address words and node ids name valid blocks and nodes is for
the readers of those to check.
""".
-spec inode(superblock(), non_neg_integer(), binary()) ->
          {ok, inode()} | {error, failure()}.
inode(Super, Nid, Block) ->
    decode(inode, fun() -> read_inode(Super, Nid, Block) end).

-doc """
Direct node Nid of inode Ino, at node offset Offset of its file's tree
([F 53]): its f2fs_addrs_per_block address words, once its footer names
that nid, that inode and that offset ([F 43]). Whether each address names
a valid block is for the reader of the block to check.
""".
-spec direct_node(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary()) ->
          {ok, [non_neg_integer()]} | {error, failure()}.
direct_node(Nid, Ino, Offset, Block) ->
    decode(direct_node, fun() ->
                                read_node(erx_f2fs_direct_node, addr, Nid, Ino, Offset, Block)
                        end).

-doc """
Indirect node Nid of inode Ino, at node offset Offset of its file's tree
([F 53]): its f2fs_nids_per_block node ids, 0 for none, once its footer
names that nid, that inode and that offset ([F 43]). Each node id is
resolved, and refused if the NAT cannot hold it, by its reader.
""".
-spec indirect_node(non_neg_integer(), non_neg_integer(), non_neg_integer(), binary()) ->
          {ok, [non_neg_integer()]} | {error, failure()}.
indirect_node(Nid, Ino, Offset, Block) ->
    decode(indirect_node, fun() ->
                                  read_node(erx_f2fs_indirect_node, nid, Nid, Ino, Offset, Block)
                          end).

-doc """
A dentry block's slots ([F 59]): each used slot's record and name, a long
name's run of slots answered once, at its first slot ([F 60]).
""".
-spec dentry_block(binary()) -> {ok, dentries()} | {error, failure()}.
dentry_block(Block) ->
    decode(dentry_block, fun() -> require_block(Block), dentries(Block) end).

-doc """
The slots of an inline directory's dentries, from the inline content
inode/3 answered ([F 48], [F 59]), as dentry_block/1 answers a block's:
a bad entry fails the directory's listing, not its inode.
""".
-spec inline_dentries(inode()) -> {ok, dentries()} | {error, failure()}.
inline_dentries(#{inline_dentries := Area}) ->
    decode(inline_dentries, fun() -> dentries(Area) end).

-doc """
The nids the NAT of a volume whose superblock is Super holds:
f2fs_nat_entries_per_block for each block of one of its two copies
([F 36]).
""".
-spec nat_capacity(superblock()) -> non_neg_integer().
nat_capacity(#{segment_count_nat := Segments}) ->
    ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK * copy_blocks(Segments).

-doc """
The blocks of one copy of a NAT or SIT of Segments segments: each table
holds two copies ([F 23], [F 36]), and a version bitmap has a bit per
block of one.
""".
-spec copy_blocks(non_neg_integer()) -> non_neg_integer().
copy_blocks(Segments) -> Segments div 2 * ?BLOCKS_PER_SEG.

-doc """
The bytes of a NAT or SIT version bitmap for a table of Segments
segments: a bit per block of one copy ([F 23]).
""".
-spec bitmap_bytes(non_neg_integer()) -> non_neg_integer().
bitmap_bytes(Segments) -> copy_blocks(Segments) div 8.

-doc """
The address of block Index of copy Copy, 0 or 1, of a volume's NAT or
SIT, Table, whose superblock is Super. The NAT's copies interleave a
segment at a time, copy 1 the second segment of each pair ([F 34]); the
SIT's are the area's two halves ([F 38]). A new volume's tables are
written as copy 0; a reader takes current_block/4.
""".
-spec table_block(nat | sit, superblock(), 0 | 1, non_neg_integer()) -> non_neg_integer().
table_block(nat, #{nat_blkaddr := First}, Copy, Index) ->
    First + Index div ?BLOCKS_PER_SEG * 2 * ?BLOCKS_PER_SEG + Copy * ?BLOCKS_PER_SEG +
        Index rem ?BLOCKS_PER_SEG;
table_block(sit, #{sit_blkaddr := First, segment_count_sit := Segments}, Copy, Index) ->
    First + Copy * copy_blocks(Segments) + Index.

-doc """
The address of block Index of the copy of Table, nat or sit, that the
block's bit in the version bitmap of Checkpoint selects, first bit most
significant: the block a reader reads ([F 23], [F 34], [F 38]).
""".
-spec current_block(nat | sit, superblock(), checkpoint(), non_neg_integer()) ->
          non_neg_integer().
current_block(Table, Super, Checkpoint, Index) ->
    table_block(Table, Super, bit(version_bitmap(Table, Checkpoint), Index), Index).

version_bitmap(nat, #{nat_version_bitmap := Bitmap}) -> Bitmap;
version_bitmap(sit, #{sit_version_bitmap := Bitmap}) -> Bitmap.

-doc """
The nids that can hold a node in the NAT of a volume whose superblock is
Super: those from the root's on, as none below it holds one ([F 36]).
""".
-spec node_capacity(superblock()) -> non_neg_integer().
node_capacity(Super) -> nat_capacity(Super) - ?ERX_F2FS_ROOT_INO.

-doc """
The first block past the main area of a volume whose superblock is Super
([F 14]): main area blocks are those from main_blkaddr up to it.
""".
-spec main_end(superblock()) -> non_neg_integer().
main_end(#{main_blkaddr := Main, segment_count_main := Segments}) ->
    Main + Segments * ?BLOCKS_PER_SEG.

-doc """
The footer of a node block, its last 24 bytes ([F 43]), read from any
block: whether the block is a node, and of which checkpoint, is for the
footer's reader to ask.
""".
-spec node_footer(binary()) -> {ok, footer()} | {error, failure()}.
node_footer(Block) ->
    decode(node_footer, fun() -> read_node_footer(Block) end).

-doc """
The features whose inodes Linux reads only with EXTRA_ATTR set ([F 41]),
as a mask of the feature word: a superblock with one of them needs
EXTRA_ATTR too.
""".
-spec extra_attr_features() -> non_neg_integer().
extra_attr_features() -> ?NEED_EXTRA_ATTR.

-doc """
F2FS's CRC-32 of Data continued from Seed ([F 49]): the reflected
polynomial 0xEDB88320 without zlib's initial and final inversions, so
erlang:crc32/2, which has both, runs between two of its own.
""".
-spec crc(0..16#ffffffff, iodata()) -> 0..16#ffffffff.
crc(Seed, Data) ->
    Inverted = erlang:crc32((bnot Seed) band 16#ffffffff, Data),
    (bnot Inverted) band 16#ffffffff.

-doc """
A name's hash in its directory ([F 57]): "." and ".." hash to 0, and any
other name to the TEA directory hash of its bytes, taken 16 at a time.
""".
-spec dentry_hash(binary()) -> 0..16#ffffffff.
dentry_hash(Name) when Name =:= <<".">>; Name =:= <<"..">> ->
    0;
dentry_hash(Name) ->
    hash_chunks(Name, {16#67452301, 16#efcdab89}).

-doc """
The slots of a dentry area of Bytes bytes, a block or an inode's inline
content: as many as fit at a bitmap bit, a slot record and a name slot
each ([F 48], [F 59]); 214 in a block.
""".
-spec dentry_slots(non_neg_integer()) -> non_neg_integer().
dentry_slots(Bytes) ->
    8 * Bytes div (8 * (?ERX_F2FS_DIR_ENTRY_SIZE + ?ERX_F2FS_NAME_SLOT_SIZE) + 1).

-doc """
Bit Index of a first-bit-most-significant bitmap, the order of the SIT
valid maps and the version bitmaps ([F 5]), and of every bitmap the
codec answers.
""".
-spec bit(bitstring(), non_neg_integer()) -> 0 | 1.
bit(Bitmap, Index) ->
    <<_:Index, Bit:1, _/bitstring>> = Bitmap,
    Bit.

%%% Encoders

-doc """
The block of a superblock copy, block 0 or block 1 of the volume: Super, a
superblock as superblock/1 answers it, at byte 1024 and zeros around it
([F 7]), with crc computed when SB_CHKSUM is set ([F 13]) and taken from
Super otherwise.
""".
-spec encode_superblock(superblock()) -> binary().
encode_superblock(#{feature := Feature} = Super) ->
    Record = case Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM of
                 0 ->
                     erx_abi_packed:encode(erx_f2fs_super_block, Super);
                 _ ->
                     %% checksum_offset names the crc field, the record's last word.
                     Placed = Super#{checksum_offset := ?ERX_F2FS_SUPER_BLOCK_OFF_CRC},
                     Unsigned = erx_abi_packed:encode(erx_f2fs_super_block, Placed),
                     erx_abi_packed:encode(erx_f2fs_super_block,
                                           Placed#{crc := superblock_checksum(Unsigned)})
             end,
    zeros_to(<<0:(?ERX_F2FS_SUPER_OFFSET * 8), Record/binary>>, ?BLOCK_SIZE).

-doc """
The header block and the payload blocks of a checkpoint pack of a volume
whose superblock is Super, from Checkpoint, a header as checkpoint/3
answers it: the fixed part, the version bitmaps where [F 23] places them
for Super's cp_payload, with their sizes taken from the bitmaps, zeros
elsewhere, and the checksum at checksum_offset, computed over the rest of
the header block ([F 51]); Checkpoint's crc is not read. The header block
is also the pack's last block, the header's copy ([F 22]).
""".
-spec encode_checkpoint(superblock(), checkpoint()) -> {binary(), [binary()]}.
encode_checkpoint(#{cp_payload := PayloadBlocks},
                  #{checksum_offset := At, sit_version_bitmap := Sit,
                    nat_version_bitmap := Nat} = Checkpoint) ->
    Fixed = erx_abi_packed:encode(erx_f2fs_checkpoint,
                                  Checkpoint#{sit_ver_bitmap_bytesize => byte_size(Sit),
                                              nat_ver_bitmap_bytesize => byte_size(Nat)}),
    {Bitmaps, Payload} =
        case PayloadBlocks of
            0 -> {<<Sit/binary, Nat/binary>>, []};
            _ -> {Nat, blocks(Sit, PayloadBlocks)}
        end,
    %% The bitmaps end by the checksum, or the block cannot be built.
    Body = zeros_to(<<Fixed/binary, Bitmaps/binary>>, At),
    Unsigned = zeros_to(Body, ?BLOCK_SIZE),
    {put_word(Unsigned, At, checkpoint_crc(At, Unsigned)), Payload}.

-doc """
Orphan block Index of the Count a pack holds, both counted from 1, holding
Inodes, at most f2fs_orphans_per_block ([F 26]): what orphan_block/1
answers, with blk_addr and blk_count as Linux writes them and check_sum 0,
which no one computes.
""".
-spec encode_orphan_block([non_neg_integer()], pos_integer(), pos_integer()) -> binary().
encode_orphan_block(Inodes, Index, Count) ->
    erx_abi_packed:encode(erx_f2fs_orphan_block,
                          #{ino => pad_list(Inodes, ?ERX_F2FS_ORPHANS_PER_BLOCK, 0),
                            blk_addr => Index, blk_count => Count,
                            entry_count => length(Inodes), check_sum => 0}).

-doc """
A checkpoint pack's blocks, in order from its first ([F 20]): the header
of Checkpoint, its payload, the orphan blocks holding Orphans, the
summary blocks Summaries, and the header's copy, its last block. The
header's cp_pack_total_block_count and cp_pack_start_sum are derived
here from what the pack holds, so no caller writes them down.
""".
-spec encode_pack(superblock(), checkpoint(), [non_neg_integer()], [binary()]) -> [binary()].
encode_pack(#{cp_payload := Payload} = Super, Checkpoint, Orphans, Summaries) ->
    OrphanLists = chunks(Orphans, ?ERX_F2FS_ORPHANS_PER_BLOCK),
    OrphanCount = length(OrphanLists),
    OrphanBlocks = [encode_orphan_block(Inodes, Index, OrphanCount)
                    || {Index, Inodes} <- lists:enumerate(OrphanLists)],
    {Header, PayloadBlocks} =
        encode_checkpoint(Super, Checkpoint#{cp_pack_start_sum => 1 + Payload + OrphanCount,
                                             cp_pack_total_block_count =>
                                                 2 + Payload + OrphanCount + length(Summaries)}),
    [Header | PayloadBlocks] ++ OrphanBlocks ++ Summaries ++ [Header].

-doc "A NAT block of Entries, its f2fs_nat_entries_per_block entries ([F 33]).".
-spec encode_nat_block([nat_entry()]) -> binary().
encode_nat_block(Entries) ->
    erx_abi_packed:encode(erx_f2fs_nat_block, #{entries => Entries}).

-doc """
A SIT block whose first entries are Entries, at most
f2fs_sit_entries_per_block, as sit_block/2 answers them, and the rest
zeros: each entry's log type and the blocks its valid map sets, which give
its valid block count, packed into vblocks ([F 37]).
""".
-spec encode_sit_block([sit_entry()]) -> binary().
encode_sit_block(Entries) ->
    Packed = [#{vblocks => (Type bsl ?ERX_F2FS_SIT_VBLOCKS_BITS) bor set_bits(Map),
                valid_map => Map, mtime => Age}
              || #{type := Type, valid_map := Map, mtime := Age} <- Entries],
    Free = erx_abi_packed:decode(erx_f2fs_sit_entry, <<0:(?ERX_F2FS_SIT_ENTRY_SIZE * 8)>>),
    erx_abi_packed:encode(erx_f2fs_sit_block,
                          #{entries => pad_list(Packed, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK, Free)}).

-doc """
A summary block in the normal form of Entries, its
f2fs_summaries_per_block entries, and entry_type Type, with an empty
journal and check_sum 0, which no one computes ([F 45]). erXos keeps every
NAT and SIT entry in its table block, so it writes no journal entry, and
summary_block/1 answers the journal of a block erXos wrote as zeros.
""".
-spec encode_summary_block([summary()], byte()) -> binary().
encode_summary_block(Entries, Type) ->
    erx_abi_packed:encode(erx_f2fs_summary_block,
                          #{entries => Entries, journal => empty_journal(),
                            entry_type => Type, check_sum => 0}).

-doc """
The bytes of an empty journal, the one journal erXos writes ([F 47]): the
one source for its readers and tests.
""".
-spec empty_journal() -> binary().
empty_journal() -> <<0:(?ERX_F2FS_JOURNAL_SIZE * 8)>>.

-doc """
The node block of Inode, an inode of a volume whose superblock is Super,
in the one form erXos writes: its body is its address array, never inline
data or dentries (docs/design-f2fs.md, "Scope: features and forms"). The
block holds the fields inode/3 answers: the fixed part with i_name padded
with zeros, i_namelen its length and i_ext's len 0 ([F 44]), the extra
attributes' i_extra_isize bytes, the addresses, the inline xattr bytes,
which must be the X words the inode's flags and the volume's features give
([F 48]), i_nid and the footer; and, computed last over the whole block,
footer included, the checksum where [F 50] asks for one. Where it does not
and the extra attributes reach i_inode_checksum, that field is written as
given.
""".
-spec encode_inode(superblock(), inode()) -> binary().
encode_inode(Super, #{i_name := Name, i_ext := Extent, i_extra_isize := ExtraSize,
                      i_generation := Generation, addresses := Addresses,
                      inline_xattr := Xattr, i_nid := Nids,
                      footer := #{ino := Ino} = Footer} = Inode) ->
    %% The layout the reader will find: X from the flags and features, so
    %% xattr bytes kept past a cleared flag cannot be read as addresses.
    XattrBytes = ?WORD * inline_xattr_words(Super, Inode, Inode),
    <<_:XattrBytes/binary>> = Xattr,
    Fixed = Inode#{i_name := zeros_to(Name, ?ERX_F2FS_NAME_LEN_MAX),
                   i_namelen := byte_size(Name), i_ext := Extent#{len := 0}},
    <<Extra:ExtraSize/binary, _/binary>> = erx_abi_packed:encode(erx_f2fs_inode_extra, Inode),
    Words = [Word || <<Word:32/little>> <= <<Extra/binary, (words_bytes(Addresses))/binary,
                                              Xattr/binary>>],
    Block = erx_abi_packed:encode(erx_f2fs_inode_block,
                                  #{inode => Fixed, i_addr => Words, i_nid => Nids,
                                    footer => Footer}),
    case inode_checksum(Super, ExtraSize, Generation, Ino, Block) of
        none -> Block;
        {At, Checksum} -> put_word(Block, At, Checksum)
    end.

-doc """
The block of a direct node holding Addresses, f2fs_addrs_per_block of
them, under Footer: what direct_node/4 and node_footer/1 answer ([F 43]).
""".
-spec encode_direct_node([non_neg_integer()], footer()) -> binary().
encode_direct_node(Addresses, Footer) ->
    erx_abi_packed:encode(erx_f2fs_direct_node, #{addr => Addresses, footer => Footer}).

-doc """
The block of an indirect node holding Nids, f2fs_nids_per_block of them,
under Footer: what indirect_node/4 and node_footer/1 answer ([F 43]).
""".
-spec encode_indirect_node([non_neg_integer()], footer()) -> binary().
encode_indirect_node(Nids, Footer) ->
    erx_abi_packed:encode(erx_f2fs_indirect_node, #{nid => Nids, footer => Footer}).

-doc """
A dentry block of Dentries, as dentry_block/1 answers them: the bitmap in
its first-bit-least-significant order ([F 5]), each entry's record at its
slot and its name through its run's name slots ([F 59], [F 60]), and zeros
everywhere else, so a run's later records hold only a name_len of 0 and a
used slot no entry starts reads as passed.
""".
-spec encode_dentry_block(dentries()) -> binary().
encode_dentry_block(#{bitmap := Bitmap, entries := Entries}) ->
    {Slots, BitmapBytes, Reserved} = dentry_geometry(?BLOCK_SIZE),
    Stored = reverse_bits(<<Bitmap/bitstring, 0:(BitmapBytes * 8 - Slots)>>),
    {Records, Names, End} = lists:foldl(fun dentry_run/2, {[], [], 0}, Entries),
    Left = Slots - End,
    iolist_to_binary([Stored, <<0:(Reserved * 8)>>,
                      Records, <<0:(Left * ?ERX_F2FS_DIR_ENTRY_SIZE * 8)>>,
                      Names, <<0:(Left * ?ERX_F2FS_NAME_SLOT_SIZE * 8)>>]).

%%% The superblock

read_superblock(Block) ->
    Record = superblock_record(Block),
    Super = erx_abi_packed:decode(erx_f2fs_super_block, Record),
    require(maps:get(magic, Super) =:= ?ERX_F2FS_MAGIC, magic),
    check_superblock_checksum(Super, Record),
    check_sizes(Super),
    check_counts(Super),
    check_devices(Super),
    check_extensions(Super),
    check_reserved_inodes(Super),
    check_areas(Super),
    Super.

superblock_record(Block) ->
    require_block(Block),
    <<_:?ERX_F2FS_SUPER_OFFSET/binary,
      Record:?ERX_F2FS_SUPER_BLOCK_SIZE/binary, _/binary>> = Block,
    Record.

%% With SB_CHKSUM the checksum is crc, the record's last word, over every
%% byte before it, and checksum_offset names it ([F 13]).
check_superblock_checksum(#{feature := Feature} = Super, Record) ->
    case Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM of
        0 ->
            ok;
        _ ->
            #{checksum_offset := At, crc := Stored} = Super,
            require(At =:= ?ERX_F2FS_SUPER_BLOCK_OFF_CRC, checksum_offset),
            require(superblock_checksum(Record) =:= Stored, crc)
    end.

%% The CRC of a superblock record's bytes before its crc field ([F 13]),
%% which the reader checks and the encoder writes.
superblock_checksum(Record) ->
    <<Covered:?ERX_F2FS_SUPER_BLOCK_OFF_CRC/binary, _/binary>> = Record,
    crc(?ERX_F2FS_MAGIC, Covered).

%% A block is 4096 bytes, a segment 512 blocks, and a sector at least 512
%% bytes and at most a block, a whole number of them to a block ([F 54]).
check_sizes(#{log_blocksize := LogBlock, log_blocks_per_seg := LogSegment,
              log_sectorsize := LogSector,
              log_sectors_per_block := LogSectorsPerBlock}) ->
    require(LogBlock =:= ?ERX_F2FS_LOG_BLOCK_SIZE, log_blocksize),
    require(LogSegment =:= ?ERX_F2FS_LOG_BLOCKS_PER_SEG, log_blocks_per_seg),
    require(LogSector >= ?ERX_F2FS_LOG_SECTOR_SIZE_MIN andalso
                LogSector =< ?ERX_F2FS_LOG_BLOCK_SIZE andalso
                LogSector + LogSectorsPerBlock =:= ?ERX_F2FS_LOG_BLOCK_SIZE,
            log_sectorsize).

%% The volume's segments, the main area's sections and segments, and the
%% zones they group into agree with each other and with block_count, and
%% the checkpoint pack's payload leaves room in its segment for the header,
%% its copy and the summaries ([F 54]). segs_per_sec is checked before it
%% divides.
check_counts(#{block_count := Blocks, segment_count := Segments,
               section_count := Sections, segs_per_sec := SegsPerSec,
               segment_count_main := MainSegments,
               secs_per_zone := SecsPerZone, cp_payload := Payload}) ->
    require(Segments >= ?ERX_F2FS_SEGMENT_COUNT_MIN andalso
                Segments =< ?ERX_F2FS_SEGMENT_COUNT_MAX,
            segment_count),
    require(Sections >= 1 andalso Sections =< MainSegments, section_count),
    require(SegsPerSec >= 1 andalso SegsPerSec =< Segments, segs_per_sec),
    require(MainSegments =:= Sections * SegsPerSec andalso
                Segments div SegsPerSec >= Sections,
            segment_count_main),
    require(Segments =< Blocks div ?BLOCKS_PER_SEG, block_count),
    require(SecsPerZone >= 1 andalso SecsPerZone =< Sections, secs_per_zone),
    require(Payload < ?BLOCKS_PER_SEG - ?ERX_F2FS_CP_FIXED_BLOCKS
                          - ?ERX_F2FS_CP_SUMMARY_BLOCKS_MAX,
            cp_payload).

%% A device list starts with a named device or is empty. When it is not
%% empty, the leading named devices' segments add up to the volume's
%% ([F 54]); a device is named when its path is not the empty string.
check_devices(#{devs := Devices, segment_count := Segments}) ->
    Named = lists:takewhile(fun(#{path := <<First, _/binary>>}) ->
                                    First =/= 0
                            end, Devices),
    case Named of
        [] ->
            ok;
        _ ->
            Total = lists:sum([Count || #{total_segments := Count} <- Named]),
            require(Total =:= Segments, devices)
    end.

check_extensions(#{extension_count := Cold, hot_ext_count := Hot}) ->
    require(Cold =< ?ERX_F2FS_EXTENSIONS_MAX andalso
                Hot =< ?ERX_F2FS_EXTENSIONS_MAX andalso
                Cold + Hot =< ?ERX_F2FS_EXTENSIONS_MAX,
            extensions).

check_reserved_inodes(#{node_ino := Node, meta_ino := Meta, root_ino := Root}) ->
    require(Node =:= ?ERX_F2FS_NODE_INO andalso Meta =:= ?ERX_F2FS_META_INO
                andalso Root =:= ?ERX_F2FS_ROOT_INO,
            reserved_inodes).

%% The checkpoint, SIT, NAT, SSA and main areas follow each other from
%% segment 0, each a whole number of segments, and the main area ends within
%% the volume's segments ([F 14]).
check_areas(#{segment0_blkaddr := Segment0, cp_blkaddr := Checkpoint,
              sit_blkaddr := Sit, nat_blkaddr := Nat, ssa_blkaddr := Ssa,
              main_blkaddr := Main, segment_count := Segments,
              segment_count_ckpt := CheckpointSegments,
              segment_count_sit := SitSegments,
              segment_count_nat := NatSegments,
              segment_count_ssa := SsaSegments,
              segment_count_main := MainSegments}) ->
    require(Checkpoint =:= Segment0 andalso
                Sit =:= area_end(Checkpoint, CheckpointSegments) andalso
                Nat =:= area_end(Sit, SitSegments) andalso
                Ssa =:= area_end(Nat, NatSegments) andalso
                Main =:= area_end(Ssa, SsaSegments) andalso
                area_end(Main, MainSegments) =< area_end(Segment0, Segments),
            areas).

area_end(Start, Segments) -> Start + Segments * ?BLOCKS_PER_SEG.

%%% The checkpoint pack

read_checkpoint(Block) ->
    Checkpoint = read_checkpoint_copy(Block),
    #{cp_pack_total_block_count := PackBlocks} = Checkpoint,
    require(PackBlocks > ?ERX_F2FS_CP_FIXED_BLOCKS andalso
                PackBlocks =< ?BLOCKS_PER_SEG,
            pack_blocks),
    Checkpoint.

read_checkpoint_copy(Block) ->
    require_block(Block),
    <<Fixed:?ERX_F2FS_CHECKPOINT_SIZE/binary, _/binary>> = Block,
    Checkpoint = erx_abi_packed:decode(erx_f2fs_checkpoint, Fixed),
    Checkpoint#{crc => checkpoint_checksum(Checkpoint, Block)}.

%% The checksum lies after the header's fixed part and within the block,
%% and covers every byte of the block but its own ([F 51]); it is answered
%% once verified, since a node footer of the checkpoint carries it ([F 43]).
checkpoint_checksum(#{checksum_offset := At}, Block) ->
    require(At >= ?ERX_F2FS_CHECKPOINT_SIZE andalso
                At =< ?BLOCK_SIZE - ?CHECKSUM_SIZE,
            checksum_offset),
    <<_:At/binary, Stored:32/little, _/binary>> = Block,
    require(checkpoint_crc(At, Block) =:= Stored, crc),
    Stored.

%% The CRC of a header block's every byte but its checksum's, at At
%% ([F 51]), which the reader checks and the encoder writes.
checkpoint_crc(At, Block) ->
    <<Before:At/binary, _:32, After/binary>> = Block,
    crc(?ERX_F2FS_MAGIC, [Before, After]).

read_checkpoint(PayloadBlocks, Block, Payload) ->
    Checkpoint = read_checkpoint(Block),
    require(length(Payload) =:= PayloadBlocks, payload_count),
    lists:foreach(fun require_block/1, Payload),
    {Sit, Nat} = version_bitmaps(Checkpoint, Block, Payload),
    Checkpoint#{sit_version_bitmap => Sit, nat_version_bitmap => Nat}.

%% Where the bitmaps lie ([F 23]): without payload blocks, the SIT bitmap
%% and then the NAT bitmap follow the header's fixed part; with them, the
%% NAT bitmap follows the fixed part and the SIT bitmap fills the payload
%% from its first byte. Either way the header's bitmaps end before its
%% checksum. Payload has the superblock's cp_payload blocks, as
%% read_checkpoint/3 has checked.
version_bitmaps(#{ckpt_flags := Flags}, _Block, _Payload)
  when Flags band ?ERX_F2FS_CP_LARGE_NAT_BITMAP =/= 0 ->
    fail(large_nat_bitmap);
version_bitmaps(#{sit_ver_bitmap_bytesize := SitBytes,
                  nat_ver_bitmap_bytesize := NatBytes,
                  checksum_offset := At}, Block, Payload) ->
    HeaderRoom = At - ?ERX_F2FS_CHECKPOINT_SIZE,
    <<_:?ERX_F2FS_CHECKPOINT_SIZE/binary, Bitmaps:HeaderRoom/binary,
      _/binary>> = Block,
    case Payload of
        [] ->
            require(SitBytes + NatBytes =< HeaderRoom, bitmap_room),
            <<Sit:SitBytes/binary, Nat:NatBytes/binary, _/binary>> = Bitmaps,
            {Sit, Nat};
        _ ->
            require(NatBytes =< HeaderRoom andalso
                        SitBytes =< length(Payload) * ?BLOCK_SIZE,
                    bitmap_room),
            <<Nat:NatBytes/binary, _/binary>> = Bitmaps,
            <<Sit:SitBytes/binary, _/binary>> = iolist_to_binary(Payload),
            {Sit, Nat}
    end.

read_orphans(Block) ->
    require_block(Block),
    #{ino := Slots, entry_count := Used} =
        erx_abi_packed:decode(erx_f2fs_orphan_block, Block),
    require(Used =< ?ERX_F2FS_ORPHANS_PER_BLOCK, entry_count),
    lists:sublist(Slots, Used).

%%% The NAT and the SIT

read_nat_block(Block) ->
    require_block(Block),
    #{entries := Entries} = erx_abi_packed:decode(erx_f2fs_nat_block, Block),
    Entries.

read_nat_journal(Journal) ->
    require_size(Journal, ?ERX_F2FS_NAT_JOURNAL_SIZE, journal_size),
    #{n_nats := Count, entries := Entries} =
        erx_abi_packed:decode(erx_f2fs_nat_journal, Journal),
    require(Count =< ?ERX_F2FS_NAT_JOURNAL_ENTRIES, entry_count),
    lists:sublist(Entries, Count).

read_sit_block(Block, Used) ->
    require_block(Block),
    require(Used =< ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK, entry_count),
    #{entries := Entries} = erx_abi_packed:decode(erx_f2fs_sit_block, Block),
    [sit_entry(Entry) || Entry <- lists:sublist(Entries, Used)].

read_sit_journal(Journal) ->
    require_size(Journal, ?ERX_F2FS_SIT_JOURNAL_SIZE, journal_size),
    #{n_sits := Count, entries := Entries} =
        erx_abi_packed:decode(erx_f2fs_sit_journal, Journal),
    require(Count =< ?ERX_F2FS_SIT_JOURNAL_ENTRIES, entry_count),
    [#{segno => Segno, entry => sit_entry(Entry)}
     || #{segno := Segno, entry := Entry} <- lists:sublist(Entries, Count)].

%% A SIT entry's own rules ([F 39]): its valid blocks are at most a
%% segment's and exactly the bits its map sets, and its type is one of the
%% six logs'.
sit_entry(#{vblocks := VBlocks, valid_map := Map, mtime := Age}) ->
    <<Type:(16 - ?ERX_F2FS_SIT_VBLOCKS_BITS),
      Valid:?ERX_F2FS_SIT_VBLOCKS_BITS>> = <<VBlocks:16>>,
    require(Valid =< ?BLOCKS_PER_SEG, valid_blocks),
    require(Valid =:= set_bits(Map), valid_map),
    require(Type < ?ERX_F2FS_SIT_TYPES, type),
    %% The map is copied out of its block, so a SIT held whole keeps 64
    %% bytes a segment rather than every SIT block it was read from.
    #{valid_blocks => Valid, type => Type, valid_map => binary:copy(Map), mtime => Age}.

%% The bits Bytes sets, a byte at a time, each the sum of its two nibbles'.
set_bits(Bytes) ->
    Nibbles = {0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4},
    lists:sum([element(Byte bsr 4 + 1, Nibbles) + element(Byte band 16#f + 1, Nibbles)
               || <<Byte>> <= Bytes]).

%%% Segment summaries

read_summary_block(Block) ->
    require_block(Block),
    Summary = erx_abi_packed:decode(erx_f2fs_summary_block, Block),
    maps:remove(check_sum, Summary).

%% The compact form's entries run on through its blocks from the journals,
%% each block usable up to f2fs_compact_summary_end ([F 29]): a cursor over
%% those spans gives each log its entries in turn.
read_compact(Counts, Blocks) ->
    lists:foreach(fun require_block/1, Blocks),
    require(lists:all(fun(Count) -> Count =< ?ERX_F2FS_SUMMARIES_PER_BLOCK end,
                      Counts),
            entry_count),
    require(Blocks =/= [], room),
    [First | Rest] = Blocks,
    <<Journals:?ERX_F2FS_COMPACT_JOURNALS_SIZE/binary, _/binary>> = First,
    #{nat_journal := Nat, sit_journal := Sit} =
        erx_abi_packed:decode(erx_f2fs_compact_journals, Journals),
    End = ?ERX_F2FS_COMPACT_SUMMARY_END,
    Spans = [binary:part(First, byte_size(Journals), End - byte_size(Journals))
             | [binary:part(Block, 0, End) || Block <- Rest]],
    {Summaries, _Unused} =
        lists:mapfoldl(fun(Count, Cursor) -> summaries(Count, Cursor, []) end,
                       Spans, Counts),
    #{nat_journal => Nat, sit_journal => Sit, summaries => Summaries}.

%% Count entries from the spans; an entry that does not fit what is left
%% of a span starts the next one.
summaries(0, Spans, Read) ->
    {lists:reverse(Read), Spans};
summaries(Count, [<<Entry:?ERX_F2FS_SUMMARY_ENTRY_SIZE/binary, Rest/binary>>
                  | Spans], Read) ->
    Summary = erx_abi_packed:decode(erx_f2fs_summary_entry, Entry),
    summaries(Count - 1, [Rest | Spans], [Summary | Read]);
summaries(Count, [_Spent | Spans], Read) ->
    summaries(Count, Spans, Read);
summaries(_Count, [], _Read) ->
    fail(room).

%%% Inodes

read_inode(Super, Nid, Block) ->
    require_block(Block),
    #{inode := Inode, i_addr := Words, i_nid := Nids, footer := Footer} =
        erx_abi_packed:decode(erx_f2fs_inode_block, Block),
    require(valid_nid(Super, Nid), nid),
    check_inode_footer(Nid, Footer),
    ExtraSize = extra_size(Inode, Block),
    check_inode_checksum(Super, ExtraSize, Inode, Footer, Block),
    check_extra_attributes(Super, Inode, ExtraSize),
    Extra = extra_attributes(ExtraSize, Block),
    XattrWords = inline_xattr_words(Super, Inode, Extra),
    check_inode_fields(Super, Nid, Inode),
    check_file_type(Inode, Nids),
    #{i_name := Name, i_namelen := NameLength} = Inode,
    Body = inode_body(Inode, Words, ExtraSize div ?WORD, XattrWords),
    Xattr = words_bytes(lists:nthtail(?ERX_F2FS_ADDRS_PER_INODE - XattrWords, Words)),
    Bounded = bound_hash_depth(Inode),
    maps:merge(maps:merge(Bounded, Extra),
               Body#{i_name => binary:part(Name, 0, NameLength),
                     i_nid => Nids, footer => Footer, inline_xattr => Xattr}).

%% A directory's hash levels, i_current_depth, read as Linux reads them: at
%% most 63, however large the stored word ([F 42], [F 58]), so the depth an
%% insertion grows from is bounded. A regular file keeps i_gc_failures in
%% that word, which reads as it is.
bound_hash_depth(#{i_mode := Mode, i_current_depth := Depth} = Inode)
  when Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_DIR ->
    Inode#{i_current_depth := min(Depth, ?ERX_F2FS_DIR_HASH_DEPTH_MAX)};
bound_hash_depth(Inode) ->
    Inode.

-doc """
Whether Nid names a node of a volume whose superblock is Super: it is at
least the root's, past 0 and the node and meta inodes' reserved nids, and
below the NAT's capacity ([F 6], [F 36]).
""".
-spec valid_nid(superblock(), non_neg_integer()) -> boolean().
valid_nid(Super, Nid) ->
    Nid >= ?ERX_F2FS_ROOT_INO andalso Nid < nat_capacity(Super).

%% The block is the node asked for, an inode: node offset 0 of its own
%% inode ([F 43], [F 53]).
check_inode_footer(Nid, Footer) ->
    check_node_footer(Nid, Nid, 0, Footer).

%% A node block is the node its parent names: its footer names its own nid,
%% the file's inode and the node offset its place in the file's tree gives
%% ([F 43], [F 53]). Every node offset of a file is one place, so a node
%% named from two places, from itself or from another file fails here, and
%% no walk of a tree loops or reads another file's node as its own.
check_node_footer(Nid, Ino, Offset, #{nid := FooterNid, ino := FooterIno, flag := Flag}) ->
    require(FooterNid =:= Nid andalso FooterIno =:= Ino andalso
                Flag bsr ?ERX_F2FS_NODE_MARK_BITS =:= Offset,
            footer).

%% With EXTRA_ATTR the extra attributes lie over the first words of the
%% address array, i_extra_isize bytes of them ([F 41]); without it there
%% are none.
extra_size(#{i_inline := Inline}, Block) when Inline band ?ERX_F2FS_EXTRA_ATTR =/= 0 ->
    #{i_extra_isize := Size} = erx_abi_packed:decode(erx_f2fs_inode_extra, extra_area(Block)),
    Size;
extra_size(_Inode, _Block) ->
    0.

extra_area(Block) ->
    <<_:?ERX_F2FS_INODE_BLOCK_OFF_I_ADDR/binary, Area:?ERX_F2FS_INODE_EXTRA_SIZE/binary,
      _/binary>> = Block,
    Area.

%% The extra attributes as the inode holds them: its Size bytes, which
%% check_extra_attributes has bounded, and every byte past them read as
%% zero, so a field it lacks reads as 0 and the encoder writes back exactly
%% the bytes it has ([F 41]).
extra_attributes(Size, Block) ->
    <<Held:Size/binary, _/binary>> = extra_area(Block),
    erx_abi_packed:decode(erx_f2fs_inode_extra,
                          <<Held/binary, 0:((?ERX_F2FS_INODE_EXTRA_SIZE - Size) * 8)>>).

%% The checksum is checked once the footer shows the block is this inode,
%% before any rule of the inode's own fields, so a damaged inode fails as
%% one.
check_inode_checksum(Super, ExtraSize, #{i_generation := Generation}, #{ino := Ino}, Block) ->
    case inode_checksum(Super, ExtraSize, Generation, Ino, Block) of
        none ->
            ok;
        {At, Computed} ->
            <<_:At/binary, Stored:32/little, _/binary>> = Block,
            require(Computed =:= Stored, checksum)
    end.

%% Where an inode block's checksum lies and the value it must hold there, or
%% none ([F 50]): on a volume with INODE_CHKSUM, an inode whose extra
%% attributes reach i_inode_checksum carries the CRC of its block with that
%% field as zeros, seeded with the CRC of the volume's UUID from all ones and
%% continued over the footer's ino and i_generation. The reader and the
%% encoder both ask here.
inode_checksum(#{feature := Feature, uuid := Uuid}, ExtraSize, Generation, Ino, Block)
  when Feature band ?ERX_F2FS_FEATURE_INODE_CHKSUM =/= 0,
       ExtraSize >= ?ERX_F2FS_INODE_EXTRA_OFF_I_INODE_CHECKSUM + ?CHECKSUM_SIZE ->
    At = ?ERX_F2FS_INODE_BLOCK_OFF_I_ADDR
             + ?ERX_F2FS_INODE_EXTRA_OFF_I_INODE_CHECKSUM,
    <<Before:At/binary, _:32, After/binary>> = Block,
    Seed = crc(16#ffffffff, Uuid),
    {At, crc(Seed, [<<Ino:32/little, Generation:32/little>>, Before, <<0:32>>, After])};
inode_checksum(_Super, _ExtraSize, _Generation, _Ino, _Block) ->
    none.

%% EXTRA_ATTR on an inode needs the feature, and the features that extend
%% an inode need EXTRA_ATTR on every inode; i_extra_isize is a whole number
%% of words from the two size words to the whole extra attributes ([F 41]).
check_extra_attributes(#{feature := Feature}, #{i_inline := Inline}, _Size)
  when Inline band ?ERX_F2FS_EXTRA_ATTR =:= 0 ->
    require(Feature band ?NEED_EXTRA_ATTR =:= 0, extra_attr);
check_extra_attributes(#{feature := Feature}, _Inode, Size) ->
    require(Feature band ?ERX_F2FS_FEATURE_EXTRA_ATTR =/= 0, extra_attr),
    require(Size rem ?ERX_F2FS_EXTRA_ISIZE_ALIGN =:= 0 andalso
                Size >= ?ERX_F2FS_EXTRA_ISIZE_MIN andalso
                Size =< ?ERX_F2FS_INODE_EXTRA_SIZE,
            extra_isize).

%% The inline xattr area's words, X of [F 48]: i_inline_xattr_size with
%% FLEXIBLE_INLINE_XATTR, which check_extra_attributes has made present,
%% within its bounds ([F 42]); else f2fs_inline_xattr_words when the inode
%% has INLINE_XATTR or INLINE_DENTRY, and none otherwise.
inline_xattr_words(#{feature := Feature}, #{i_inline := Inline}, Extra)
  when Feature band ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR =/= 0 ->
    #{i_inline_xattr_size := Words} = Extra,
    require(Words =< ?ERX_F2FS_INLINE_XATTR_WORDS_MAX andalso
                (Inline band ?ERX_F2FS_INLINE_XATTR =:= 0 orelse
                     Words >= ?ERX_F2FS_INLINE_XATTR_WORDS_MIN),
            inline_xattr_size),
    Words;
inline_xattr_words(_Super, #{i_inline := Inline}, _Extra)
  when Inline band (?ERX_F2FS_INLINE_XATTR bor ?ERX_F2FS_INLINE_DENTRY) =/= 0 ->
    ?ERX_F2FS_INLINE_XATTR_WORDS;
inline_xattr_words(_Super, _Inode, _Extra) ->
    0.

%% The rules of [F 42] on the inode's own fields: it counts at least its
%% own block, its xattr node is another valid node, its flags need their
%% features, and its name fits its field.
check_inode_fields(#{feature := Feature} = Super, Nid,
                   #{i_blocks := Blocks, i_xattr_nid := Xattr, i_flags := Flags,
                     i_inline := Inline, i_namelen := NameLength}) ->
    require(Blocks =/= 0, blocks),
    require(Xattr =:= 0 orelse (Xattr =/= Nid andalso valid_nid(Super, Xattr)),
            xattr_nid),
    require(Flags band ?ERX_F2FS_CASEFOLD_FL =:= 0 orelse
                Feature band ?ERX_F2FS_FEATURE_CASEFOLD =/= 0,
            casefold),
    require(Flags band ?ERX_F2FS_DEVICE_ALIAS_FL =:= 0 orelse
                (Feature band ?ERX_F2FS_FEATURE_DEVICE_ALIAS =/= 0 andalso
                     Inline band ?ERX_F2FS_PIN_FILE =/= 0),
            device_alias),
    require(NameLength =< ?ERX_F2FS_NAME_LEN_MAX, namelen).

%% The rules that turn on the file type, i_mode's S_IFMT bits: it is one of
%% F2FS's seven ([F 66]), a directory never has exactly one link ([F 69]),
%% only a directory has inline dentries ([F 68]), and inline data obeys
%% check_inline_data. So an inode has at most one inline body.
check_file_type(#{i_mode := Mode, i_links := Links, i_inline := Inline} = Inode, Nids) ->
    Type = Mode band ?ERX_F2FS_MODE_TYPE_MASK,
    require(lists:member(Type, ?FILE_TYPES), mode),
    require(Type =/= ?ERX_F2FS_MODE_DIR orelse Links =/= 1, links),
    require(Inline band ?ERX_F2FS_INLINE_DENTRY =:= 0 orelse
                Type =:= ?ERX_F2FS_MODE_DIR,
            inline_dentry),
    case Inline band ?ERX_F2FS_INLINE_DATA of
        0 -> ok;
        _ -> check_inline_data(Type, Inode, Nids)
    end.

%% Only a regular file or a symlink has inline data, and then no block but
%% its inode and its xattr node, which i_blocks counts, and no node; and a
%% regular file with it is neither encrypted, verity nor compressed, while
%% a symlink with it may be any of these ([F 67], [F 70], open question 12
%% of the facts record).
check_inline_data(Type, #{i_blocks := Blocks, i_xattr_nid := Xattr,
                          i_advise := Advise, i_flags := Flags}, Nids) ->
    require(Type =:= ?ERX_F2FS_MODE_REG orelse Type =:= ?ERX_F2FS_MODE_LNK,
            inline_data_type),
    XattrBlocks = case Xattr of
                      0 -> 0;
                      _ -> 1
                  end,
    require(Blocks - 1 =< XattrBlocks andalso
                lists:all(fun(Node) -> Node =:= 0 end, Nids),
            inline_data_blocks),
    require(Type =/= ?ERX_F2FS_MODE_REG orelse
                (Advise band (?ERX_F2FS_ADVISE_ENCRYPT bor
                                  ?ERX_F2FS_ADVISE_VERITY) =:= 0 andalso
                     Flags band ?ERX_F2FS_COMPR_FL =:= 0),
            inline_data_transformed).

%% The address array is the 923 - E - X words from word E. An inline inode
%% keeps that array's first word reserved and its content in the rest, up
%% to the inline xattr area ([F 48]): a directory's inline dentries, or a
%% file's first i_size bytes, which must fit.
inode_body(#{i_inline := Inline, i_size := Size}, Words, ExtraWords,
           XattrWords) ->
    Count = ?ERX_F2FS_ADDRS_PER_INODE - ExtraWords - XattrWords,
    Addresses = lists:sublist(Words, ExtraWords + 1, Count),
    if
        Inline band ?ERX_F2FS_INLINE_DENTRY =/= 0 ->
            #{inline_dentries => inline_content(Addresses)};
        Inline band ?ERX_F2FS_INLINE_DATA =/= 0 ->
            Content = inline_content(Addresses),
            require(Size =< byte_size(Content), inline_data),
            #{inline_data => binary:part(Content, 0, Size)};
        true ->
            #{addresses => Addresses}
    end.

inline_content([_Reserved | Words]) ->
    words_bytes(Words).

words_bytes(Words) -> << <<Word:32/little>> || Word <- Words >>.

%%% Direct and indirect nodes

%% A direct or an indirect node, by its layout: the words of its Field,
%% once its footer is the one its parent expects.
read_node(Layout, Field, Nid, Ino, Offset, Block) ->
    require_block(Block),
    #{Field := Words, footer := Footer} = erx_abi_packed:decode(Layout, Block),
    check_node_footer(Nid, Ino, Offset, Footer),
    Words.

%%% Node footers

read_node_footer(Block) ->
    require_block(Block),
    <<_:(?BLOCK_SIZE - ?ERX_F2FS_NODE_FOOTER_SIZE)/binary, Footer/binary>> = Block,
    erx_abi_packed:decode(erx_f2fs_node_footer, Footer).

%%% Dentries

%% A dentry area, a block or an inode's inline content, holds as many slots
%% as fit at a bitmap bit, a slot record and a name slot each; its bitmap
%% has a bit per slot rounded up to bytes, and reserved bytes take what is
%% left before the records ([F 48], [F 59]). The bitmap's bits are turned
%% into Erlang's order, first bit most significant ([F 5]).
dentries(Area) ->
    {Slots, BitmapBytes, Reserved} = dentry_geometry(byte_size(Area)),
    <<Bitmap:BitmapBytes/binary, _:Reserved/binary,
      Records:(Slots * ?ERX_F2FS_DIR_ENTRY_SIZE)/binary, Names/binary>> = Area,
    <<Used:Slots/bitstring, _/bitstring>> = reverse_bits(Bitmap),
    #{bitmap => Used, entries => walk(Used, Records, Names, 0, [])}.

%% A dentry area's slots, its bitmap's bytes and the reserved bytes between
%% the bitmap and the slot records, for an area of Bytes bytes.
dentry_geometry(Bytes) ->
    Slots = dentry_slots(Bytes),
    BitmapBytes = (Slots + 7) div 8,
    SlotBytes = ?ERX_F2FS_DIR_ENTRY_SIZE + ?ERX_F2FS_NAME_SLOT_SIZE,
    {Slots, BitmapBytes, Bytes - BitmapBytes - Slots * SlotBytes}.

%% Each byte's bits in the other order: the on-disk bitmap's
%% first-bit-least-significant order to Erlang's, and back ([F 5]).
reverse_bits(Bytes) ->
    << <<H:1, G:1, F:1, E:1, D:1, C:1, B:1, A:1>>
       || <<A:1, B:1, C:1, D:1, E:1, F:1, G:1, H:1>> <= Bytes >>.

%% The slots in order, three cursors moving together: a used slot with a
%% name takes the run of slots its name needs, which must end by the last
%% slot, and any other slot is passed alone ([F 60]). A name is what a
%% path can name: never empty, since a slot whose name_len is 0 is passed,
%% and holding no "/" or NUL byte.
walk(<<>>, _Records, _Names, _Slot, Read) ->
    lists:reverse(Read);
walk(<<1:1, Bits/bitstring>>, Records, Names, Slot, Read) ->
    <<Record:?ERX_F2FS_DIR_ENTRY_SIZE/binary, _/binary>> = Records,
    case erx_abi_packed:decode(erx_f2fs_dir_entry, Record) of
        #{name_len := 0} ->
            pass(Bits, Records, Names, Slot, Read);
        #{name_len := Length} = Entry ->
            require(Length =< ?ERX_F2FS_NAME_LEN_MAX, name_len),
            Run = (Length + ?ERX_F2FS_NAME_SLOT_SIZE - 1)
                      div ?ERX_F2FS_NAME_SLOT_SIZE,
            require(Run =< 1 + bit_size(Bits), name_run),
            RecordBytes = Run * ?ERX_F2FS_DIR_ENTRY_SIZE,
            NameBytes = Run * ?ERX_F2FS_NAME_SLOT_SIZE,
            <<_:(Run - 1), BitsLeft/bitstring>> = Bits,
            <<_:RecordBytes/binary, RecordsLeft/binary>> = Records,
            <<Name:Length/binary, _/binary>> = Names,
            require(binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch, name),
            <<_:NameBytes/binary, NamesLeft/binary>> = Names,
            Dentry = maps:remove(name_len, Entry#{slot => Slot, name => Name}),
            walk(BitsLeft, RecordsLeft, NamesLeft, Slot + Run, [Dentry | Read])
    end;
walk(<<0:1, Bits/bitstring>>, Records, Names, Slot, Read) ->
    pass(Bits, Records, Names, Slot, Read).

pass(Bits, Records, Names, Slot, Read) ->
    <<_:?ERX_F2FS_DIR_ENTRY_SIZE/binary, RecordsLeft/binary>> = Records,
    <<_:?ERX_F2FS_NAME_SLOT_SIZE/binary, NamesLeft/binary>> = Names,
    walk(Bits, RecordsLeft, NamesLeft, Slot + 1, Read).

%% The encoder's step for one entry, in slot order: zeros for the slots
%% since the last run, then the entry's record and its run's later records
%% as zeros, and its name padded with zeros to its run's name slots. End is
%% the slot after the last run.
dentry_run(#{slot := Slot, name := Name} = Entry, {Records, Names, End}) ->
    Gap = Slot - End,
    Run = (byte_size(Name) + ?ERX_F2FS_NAME_SLOT_SIZE - 1) div ?ERX_F2FS_NAME_SLOT_SIZE,
    Record = erx_abi_packed:encode(erx_f2fs_dir_entry, Entry#{name_len => byte_size(Name)}),
    {[Records, <<0:(Gap * ?ERX_F2FS_DIR_ENTRY_SIZE * 8)>>, Record,
      <<0:((Run - 1) * ?ERX_F2FS_DIR_ENTRY_SIZE * 8)>>],
     [Names, <<0:(Gap * ?ERX_F2FS_NAME_SLOT_SIZE * 8)>>,
      zeros_to(Name, Run * ?ERX_F2FS_NAME_SLOT_SIZE)],
     Slot + Run}.

%%% The dentry hash

%% Each 16-byte chunk, the last one shorter, mixes the state's first two
%% words with TEA keyed by the chunk's words; the hash is the first word
%% after the last chunk ([F 57]).
hash_chunks(Name, {A, B}) ->
    Left = byte_size(Name),
    Taken = min(Left, 16),
    <<Chunk:Taken/binary, Rest/binary>> = Name,
    {Y, Z} = tea(A, B, hash_words(Chunk, Left band 16#ff, 4), 0, 16),
    State = {(A + Y) band ?WORD_MASK, (B + Z) band ?WORD_MASK},
    case Rest of
        <<>> -> element(1, State);
        _ -> hash_chunks(Rest, State)
    end.

%% A chunk's Count key words, each four bytes first byte most significant;
%% a word short of bytes has Pad, the bytes left counting from this
%% chunk's, in its high bytes above the ones it has.
hash_words(_Chunk, _Pad, 0) ->
    [];
hash_words(Chunk, Pad, Count) ->
    Taken = min(byte_size(Chunk), 4),
    <<Bytes:Taken/binary, Rest/binary>> = Chunk,
    <<Word:32>> = <<(binary:copy(<<Pad>>, 4 - Taken))/binary, Bytes/binary>>,
    [Word | hash_words(Rest, Pad, Count - 1)].

tea(Y, Z, _Key, _Sum, 0) ->
    {Y, Z};
tea(Y, Z, [K0, K1, K2, K3] = Key, Sum0, Rounds) ->
    Sum = (Sum0 + 16#9e3779b9) band ?WORD_MASK,
    Y1 = (Y + ((((Z bsl 4) + K0) bxor (Z + Sum) bxor ((Z bsr 5) + K1)))) band ?WORD_MASK,
    Z1 = (Z + ((((Y1 bsl 4) + K2) bxor (Y1 + Sum) bxor ((Y1 bsr 5) + K3)))) band ?WORD_MASK,
    tea(Y1, Z1, Key, Sum, Rounds - 1).

%%% Building blocks

%% Bytes followed by zeros to Size bytes; Bytes longer than Size cannot be
%% built.
zeros_to(Bytes, Size) ->
    <<Bytes/binary, 0:((Size - byte_size(Bytes)) * 8)>>.

%% Bytes laid out over Count blocks from the first one's first byte.
blocks(Bytes, Count) ->
    [binary:part(Padded, Block * ?BLOCK_SIZE, ?BLOCK_SIZE)
     || Padded <- [zeros_to(Bytes, Count * ?BLOCK_SIZE)], Block <- lists:seq(0, Count - 1)].

%% Bytes with the little-endian word at At replaced by Word.
put_word(Bytes, At, Word) ->
    <<Before:At/binary, _:32, After/binary>> = Bytes,
    <<Before/binary, Word:32/little, After/binary>>.

pad_list(List, Count, Filler) ->
    List ++ lists:duplicate(Count - length(List), Filler).

%%% The one failure path

decode(Structure, Read) ->
    try
        {ok, Read()}
    catch
        throw:{?MODULE, Rule} -> {error, {Structure, Rule}}
    end.

%% Every decoder reads whole blocks: anything else, a bitstring that is not
%% whole bytes included, is no block.
require_block(Block) ->
    require_size(Block, ?BLOCK_SIZE, block_size).

require_size(Bytes, Size, Rule) ->
    require(is_binary(Bytes) andalso byte_size(Bytes) =:= Size, Rule).

require(true, _Rule) -> ok;
require(false, Rule) -> fail(Rule).

-spec fail(atom()) -> no_return().
fail(Rule) -> throw({?MODULE, Rule}).

chunks([], _Size) -> [];
chunks(List, Size) when length(List) =< Size -> [List];
chunks(List, Size) ->
    {Chunk, Rest} = lists:split(Size, List),
    [Chunk | chunks(Rest, Size)].
