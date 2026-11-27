%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_format).
-moduledoc """
The format of a new F2FS volume (docs/design-f2fs.md, "Formatting a
volume"): a pure function from the partition's geometry and the
installation's options to every block the new volume needs written, zeros
included, in three phases. The installation's medium writer runs it on the
host and writes each phase, ending each in a flush; a mount never formats.
[F n] cites fact n of the F2FS facts record, part 1, and [T n] fact n of
its f2fs-tools record.

The geometry: S segments a section, S the allocation unit in 2 MiB
segments, rounded up, from 1 to 8, and halved, so that it still divides
the unit, until it is at most the partition's segments over 256; segment 0 on the first absolute section boundary of the medium
at least 8 KiB into the partition, so the two superblock copies fit before
it; the checkpoint area 2 segments, the SIT and NAT copies sized as [T 12]
gives, the SSA a block per main segment and one more, and the four areas
padded together to whole sections, so the main area starts on an absolute
section boundary too. 8 sections are reserved, and the larger of 16
sections and 2 % of the main area, in whole sections, is overprovisioned.
The SIT version bitmap moves to payload blocks after the checkpoint
header when it leaves the NAT's no room there ([F 23]). A partition with
fewer than 20 main sections is refused, and so is one of more than
f2fs_segment_count_max segments, 16 TiB ([F 54]).

The contents: the root directory, nid 3, in the first block of the warm
node log, and its dentry block, "." and "..", in the first block of the
warm data log, the two logs erXos writes (docs/design-f2fs.md, "Scope:
features and forms"); each log of the six at the first segment of its
own section, section T for the log of type T; the next block of the warm
node log zeros, so a stale block there reads as no chain ([T 25]); NAT
block 0 with nids 1 and 2 at address 1 and the root ([T 26], [T 73]); the
SIT's first copy with the logs' types and the two valid blocks, every
other block of both tables' first copies zeros, and their second copies
unselected; pack 1 an unmount checkpoint with normal summaries and empty
journals, and pack 2's header zeros, which no mount reads as a pack.

The phases: zeros over the superblock copies first, so no copy an earlier
volume left survives; then every other block; then the second superblock
copy and the first, so a copy reaches the medium only after everything it
describes.
""".

-export([plan/2]).
-export_type([geometry/0, options/0, plan/0, failure/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
%% The medium's sectors, in which abi/medium.txt places a partition.
-define(LOG_SECTOR_SIZE, 9).
-define(SECTORS_PER_BLOCK, (?BLOCK_SIZE bsr ?LOG_SECTOR_SIZE)).
%% The superblock copies' blocks, which lie before segment 0 ([F 7]).
-define(SUPER_BLOCKS, 2).
%% The allocation unit an installation that knows none passes, the size
%% Bergmann found most common (docs/design-f2fs.md, "Formatting a volume").
-define(DEFAULT_UNIT, (4 bsl 20)).
-define(SECTION_SEGMENTS_MAX, 8).
%% A section is at most the partition's segments over this, so the 16
%% sections the cleaner keeps stay within a sixteenth of the partition.
-define(PARTITION_SEGMENTS_PER_SECTION, 256).
-define(CHECKPOINT_SEGMENTS, 2).
-define(RESERVED_SECTIONS, 8).
-define(OVERPROVISION_SECTIONS, 16).
-define(OVERPROVISION_PERCENT, 2).
%% The fewest main sections: 16 overprovisioned and 4 for files, 8 MiB at
%% one segment a section, as mkfs.f2fs's smallest volume holds ([T 17]).
-define(MAIN_SECTIONS_MIN, 20).
%% The checkpoint header's room for the version bitmaps, between its
%% fixed part and the checksum in its last word ([F 23]).
-define(BITMAP_ROOM, (?BLOCK_SIZE - 4 - ?ERX_F2FS_CHECKPOINT_SIZE)).
%% A version bitmap's bytes for each segment of one table copy.
-define(BITMAP_BYTES_PER_SEGMENT, (?BLOCKS_PER_SEG div 8)).
%% The six logs, by type: data hot, warm, cold, then node ([F 21]).
-define(WARM_DATA, 1).
-define(WARM_NODE, ?ERX_F2FS_LOG_HOT_NODE + 1).
-define(LOG_TYPES, ?ERX_F2FS_SIT_TYPES).
-define(UNUSED_LOG, 16#ffffffff).
%% A summary block's entry_type ([F 45]).
-define(DATA_SUMMARY, 0).
-define(NODE_SUMMARY, 1).
%% A directory's dentry file type ([T 23]).
-define(FILE_TYPE_DIR, 2).
%% The extra attributes every inode carries: through i_inode_checksum.
-define(EXTRA_ISIZE, ?ERX_F2FS_INODE_EXTRA_OFF_I_CRTIME).
-define(FEATURES, (?ERX_F2FS_FEATURE_EXTRA_ATTR bor ?ERX_F2FS_FEATURE_INODE_CHKSUM bor
                   ?ERX_F2FS_FEATURE_SB_CHKSUM)).
%% The tools' release whose layout the format follows, which Linux does
%% not check ([F 54], [T 29]).
-define(MAJOR_VER, 1).
-define(MINOR_VER, 16).

-doc """
A partition: its first sector on the medium and its length in sectors, as
abi/medium.txt places it.
""".
-type geometry() :: #{start := non_neg_integer(), sectors := non_neg_integer()}.
-doc """
The installation's choices: the medium's allocation unit in bytes (4 MiB
when absent), the checkpoint version, an odd 31-bit number, the volume's
UUID and the root's times in seconds; random for an installation and fixed
for a test.
""".
-type options() :: #{unit => pos_integer(), version := pos_integer(),
                     uuid := <<_:128>>, time := non_neg_integer()}.
-doc """
The three phases, each a list of blocks to write, an address in the
partition and its 4096 bytes; a phase starts only after the flush that
ends the one before it.
""".
-type plan() :: [[{non_neg_integer(), binary()}]].
-doc "What the format refuses: a geometry or an option, by its name.".
-type failure() :: {geometry, start | too_small | too_large} |
                   {options, unit | version | uuid | time}.

-doc "The plan of a volume on Geometry with Options, or what it refuses.".
-spec plan(geometry(), options()) -> {ok, plan()} | {error, failure()}.
plan(Geometry, Options) ->
    try
        #{version := Version, uuid := Uuid, time := Time} = Checked = options(Options),
        Layout = layout(Geometry, maps:get(unit, Checked, ?DEFAULT_UNIT)),
        Super = superblock(Layout, Uuid),
        Zero = <<0:(?BLOCK_SIZE * 8)>>,
        SuperBlock = erx_f2fs_codec:encode_superblock(Super),
        {ok, [[{0, Zero}, {1, Zero}],
              lists:keysort(1, tables(Layout, Super, Zero) ++ checkpoint(Layout, Super, Version, Zero)
                               ++ root(Layout, Super, Version, Time, Zero)),
              [{1, SuperBlock}, {0, SuperBlock}]]}
    catch
        throw:{?MODULE, Failure} -> {error, Failure}
    end.

%%% The options and the layout

options(#{version := Version, uuid := Uuid, time := Time} = Options) ->
    require(case Options of
                #{unit := Unit} -> is_integer(Unit) andalso Unit > 0;
                #{} -> true
            end, {options, unit}),
    require(is_integer(Version) andalso Version > 0 andalso Version < 1 bsl 31
            andalso Version band 1 =:= 1, {options, version}),
    require(is_binary(Uuid) andalso byte_size(Uuid) =:= 16, {options, uuid}),
    require(is_integer(Time) andalso Time >= 0 andalso Time < 1 bsl 64, {options, time}),
    Options;
options(#{}) ->
    fail({options, version}).

%% Every count and address of the volume, in blocks and segments of the
%% partition; segment 0 and the main area on absolute section boundaries.
layout(#{start := Start, sectors := Sectors}, Unit) ->
    require(Start rem ?SECTORS_PER_BLOCK =:= 0, {geometry, start}),
    First = Start div ?SECTORS_PER_BLOCK,
    Blocks = Sectors div ?SECTORS_PER_BLOCK,
    S = section_segments(Unit, Blocks div ?BLOCKS_PER_SEG),
    Section = S * ?BLOCKS_PER_SEG,
    Segment0 = ceil_to(First + ?SUPER_BLOCKS, Section) - First,
    Segments = max(0, Blocks - Segment0) div Section * S,
    Sit = 2 * ceil_div(ceil_div(Segments, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK), ?BLOCKS_PER_SEG),
    require(Segments =< ?ERX_F2FS_SEGMENT_COUNT_MAX, {geometry, too_large}),
    %% The NAT's bitmap shares the header with the SIT's, unless the SIT's
    %% would leave it less than a segment a copy and moves to payload blocks.
    SitBitmap = bitmap_bytes(Sit),
    {Payload, NatRoom} =
        case SitBitmap + ?BITMAP_BYTES_PER_SEGMENT =< ?BITMAP_ROOM of
            true -> {0, (?BITMAP_ROOM - SitBitmap) div ?BITMAP_BYTES_PER_SEGMENT};
            false -> {ceil_div(SitBitmap, ?BLOCK_SIZE), ?BITMAP_ROOM div ?BITMAP_BYTES_PER_SEGMENT}
        end,
    NatBlocks = ceil_div((Segments - ?CHECKPOINT_SEGMENTS - Sit) * ?BLOCKS_PER_SEG,
                         ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK),
    Nat = 2 * min(NatRoom, max(1, ceil_div(NatBlocks, ?BLOCKS_PER_SEG))),
    Tables = ?CHECKPOINT_SEGMENTS + Sit + Nat,
    Metadata = ceil_to(Tables + ceil_div(Segments - Tables + 1, ?BLOCKS_PER_SEG), S),
    Main = Segments - Metadata,
    require(Main >= ?MAIN_SECTIONS_MIN * S, {geometry, too_small}),
    Overprovision = ceil_to(max(?OVERPROVISION_SECTIONS * S,
                                ceil_div(Main * ?OVERPROVISION_PERCENT, 100)), S),
    #{blocks => Blocks, section => S, segment0 => Segment0, segments => Segments, payload => Payload,
      sit => Sit, nat => Nat, ssa => Metadata - Tables, main => Main,
      main_blkaddr => Segment0 + Metadata * ?BLOCKS_PER_SEG,
      reserved => ?RESERVED_SECTIONS * S, overprovision => Overprovision}.

section_segments(Unit, PartitionSegments) ->
    halved(max(1, min(ceil_div(Unit, ?BLOCK_SIZE * ?BLOCKS_PER_SEG), ?SECTION_SEGMENTS_MAX)),
           PartitionSegments div ?PARTITION_SEGMENTS_PER_SECTION).

halved(S, Most) when S > 1, S > Most -> halved(S div 2, Most);
halved(S, _Most) -> S.

%% The bytes of a version bitmap, a bit for each block of one copy of a
%% table of Segments.
bitmap_bytes(Segments) -> Segments div 2 * ?BITMAP_BYTES_PER_SEGMENT.

%% The first segment of log Type's section, the main area's section Type.
log_segment(#{section := S}, Type) -> Type * S.

%% The first block of log Type's segment.
log_block(#{main_blkaddr := Main} = Layout, Type) ->
    Main + log_segment(Layout, Type) * ?BLOCKS_PER_SEG.

%%% The records

superblock(#{blocks := Blocks, section := S, segment0 := Segment0, segments := Segments,
             payload := Payload,
             sit := Sit, nat := Nat, ssa := Ssa, main := Main,
             main_blkaddr := MainAddress}, Uuid) ->
    Zero = erx_abi_packed:decode(erx_f2fs_super_block, <<0:(?ERX_F2FS_SUPER_BLOCK_SIZE * 8)>>),
    SitAddress = Segment0 + ?CHECKPOINT_SEGMENTS * ?BLOCKS_PER_SEG,
    NatAddress = SitAddress + Sit * ?BLOCKS_PER_SEG,
    Zero#{magic => ?ERX_F2FS_MAGIC, major_ver => ?MAJOR_VER, minor_ver => ?MINOR_VER,
          log_sectorsize => ?LOG_SECTOR_SIZE,
          log_sectors_per_block => ?ERX_F2FS_LOG_BLOCK_SIZE - ?LOG_SECTOR_SIZE,
          log_blocksize => ?ERX_F2FS_LOG_BLOCK_SIZE,
          log_blocks_per_seg => ?ERX_F2FS_LOG_BLOCKS_PER_SEG,
          segs_per_sec => S, secs_per_zone => 1,
          block_count => Blocks, section_count => Main div S, segment_count => Segments,
          segment_count_ckpt => ?CHECKPOINT_SEGMENTS, segment_count_sit => Sit,
          segment_count_nat => Nat, segment_count_ssa => Ssa, segment_count_main => Main,
          segment0_blkaddr => Segment0, cp_blkaddr => Segment0, sit_blkaddr => SitAddress,
          nat_blkaddr => NatAddress, ssa_blkaddr => NatAddress + Nat * ?BLOCKS_PER_SEG,
          main_blkaddr => MainAddress, cp_payload => Payload,
          root_ino => ?ERX_F2FS_ROOT_INO, node_ino => ?ERX_F2FS_NODE_INO,
          meta_ino => ?ERX_F2FS_META_INO, uuid => Uuid, feature => ?FEATURES}.

%% The tables' first copies: SIT blocks of the logs' entries, then zeros;
%% NAT block 0 with the reserved nids and the root, then zeros. The NAT
%% copies interleave a segment at a time ([F 34]), the SIT's are halves.
tables(#{sit := Sit, nat := Nat} = Layout, #{sit_blkaddr := SitAddress, nat_blkaddr := NatAddress},
       Zero) ->
    SitBlocks = sit_blocks(Layout),
    Nids = [#{version => 0, ino => Nid, block_addr => Address}
            || {Nid, Address} <- [{0, 0}, {?ERX_F2FS_NODE_INO, 1}, {?ERX_F2FS_META_INO, 1},
                                  {?ERX_F2FS_ROOT_INO, log_block(Layout, ?WARM_NODE)}]],
    Free = #{version => 0, ino => 0, block_addr => 0},
    NatBlock = erx_f2fs_codec:encode_nat_block(
                 Nids ++ lists:duplicate(?ERX_F2FS_NAT_ENTRIES_PER_BLOCK - length(Nids), Free)),
    [{SitAddress + Index, Block}
     || {Index, Block} <- lists:enumerate(0, SitBlocks ++ lists:duplicate(
                                                 Sit div 2 * ?BLOCKS_PER_SEG - length(SitBlocks),
                                                 Zero))] ++
        [{NatAddress + ?BLOCKS_PER_SEG * 2 * (Index div ?BLOCKS_PER_SEG) + Index rem ?BLOCKS_PER_SEG,
          case Index of 0 -> NatBlock; _ -> Zero end}
         || Index <- lists:seq(0, Nat div 2 * ?BLOCKS_PER_SEG - 1)].

%% The SIT blocks through the last log's segment: each log's segment with
%% its type, and the root's two blocks valid.
sit_blocks(Layout) ->
    Logs = maps:from_list([{log_segment(Layout, Type), Type} || Type <- lists:seq(0, ?LOG_TYPES - 1)]),
    Entries = [sit_entry(maps:get(Segno, Logs, none))
               || Segno <- lists:seq(0, log_segment(Layout, ?LOG_TYPES - 1))],
    [erx_f2fs_codec:encode_sit_block(Chunk)
     || Chunk <- chunks(Entries, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK)].

sit_entry(Type) ->
    Valid = case Type of
                ?WARM_NODE -> 1;
                ?WARM_DATA -> 1;
                _ -> 0
            end,
    #{valid_blocks => Valid, type => case Type of none -> 0; _ -> Type end,
      valid_map => <<Valid:1, 0:(?BLOCKS_PER_SEG - 1)>>, mtime => 0}.

%% Pack 1, its header, its payload, three data and three node summaries
%% and the header's copy, and pack 2's header, zeros.
checkpoint(#{main := Main, sit := Sit, nat := Nat, reserved := Reserved, payload := Payload,
             overprovision := Overprovision} = Layout,
           #{cp_blkaddr := Pack1} = Super, Version, Zero) ->
    Logs = fun(First) -> [log_segment(Layout, Type) || Type <- lists:seq(First, First + 2)]
                             ++ lists:duplicate(5, ?UNUSED_LOG) end,
    %% The warm logs have written one block each, the others none.
    Offsets = [0, 1, 0, 0, 0, 0, 0, 0],
    Summaries = [#{nid => ?ERX_F2FS_ROOT_INO, version => 0, ofs_in_node => 0}],
    Pack = [summary([], ?DATA_SUMMARY), summary(Summaries, ?DATA_SUMMARY),
            summary([], ?DATA_SUMMARY),
            summary([], ?NODE_SUMMARY), summary(Summaries, ?NODE_SUMMARY),
            summary([], ?NODE_SUMMARY)],
    Total = 2 + Payload + length(Pack),
    Fields = erx_abi_packed:decode(erx_f2fs_checkpoint, <<0:(?ERX_F2FS_CHECKPOINT_SIZE * 8)>>),
    {Header, PayloadBlocks} = erx_f2fs_codec:encode_checkpoint(
                     Super, Fields#{checkpoint_ver => Version,
                                    user_block_count => (Main - Overprovision) * ?BLOCKS_PER_SEG,
                                    valid_block_count => 2,
                                    rsvd_segment_count => Reserved,
                                    overprov_segment_count => Overprovision,
                                    free_segment_count => Main - ?LOG_TYPES,
                                    cur_node_segno => Logs(?ERX_F2FS_LOG_HOT_NODE),
                                    cur_node_blkoff => Offsets,
                                    cur_data_segno => Logs(0),
                                    cur_data_blkoff => Offsets,
                                    ckpt_flags => ?ERX_F2FS_CP_UMOUNT bor ?ERX_F2FS_CP_CRC_RECOVERY,
                                    cp_pack_total_block_count => Total,
                                    cp_pack_start_sum => 1 + Payload,
                                    valid_node_count => 1, valid_inode_count => 1,
                                    next_free_nid => ?ERX_F2FS_ROOT_INO + 1,
                                    checksum_offset => ?BLOCK_SIZE - 4,
                                    sit_version_bitmap => <<0:(bitmap_bytes(Sit) * 8)>>,
                                    nat_version_bitmap => <<0:(bitmap_bytes(Nat) * 8)>>}),
    lists:enumerate(Pack1, [Header | PayloadBlocks] ++ Pack ++ [Header]) ++ [{Pack1 + ?BLOCKS_PER_SEG, Zero}].

summary(Entries, Type) ->
    Free = #{nid => 0, version => 0, ofs_in_node => 0},
    erx_f2fs_codec:encode_summary_block(
      Entries ++ lists:duplicate(?ERX_F2FS_SUMMARIES_PER_BLOCK - length(Entries), Free), Type).

%% The root's inode, the zeros after it, and its dentry block.
root(Layout, Super, Version, Time, Zero) ->
    Inode = log_block(Layout, ?WARM_NODE),
    Dentries = log_block(Layout, ?WARM_DATA),
    Fields = maps:merge(erx_abi_packed:decode(erx_f2fs_inode, <<0:(?ERX_F2FS_INODE_SIZE * 8)>>),
                        erx_abi_packed:decode(erx_f2fs_inode_extra,
                                              <<0:(?ERX_F2FS_INODE_EXTRA_SIZE * 8)>>)),
    Root = Fields#{i_mode => ?ERX_F2FS_MODE_DIR bor 8#755, i_inline => ?ERX_F2FS_EXTRA_ATTR,
                   i_links => 2, i_size => ?BLOCK_SIZE, i_blocks => 2,
                   i_atime => Time, i_ctime => Time, i_mtime => Time,
                   i_current_depth => 1, i_name => <<>>, i_extra_isize => ?EXTRA_ISIZE,
                   addresses => [Dentries | lists:duplicate(?ERX_F2FS_ADDRS_PER_INODE
                                                            - ?EXTRA_ISIZE div 4 - 1, 0)],
                   inline_xattr => <<>>, i_nid => [0, 0, 0, 0, 0],
                   footer => #{nid => ?ERX_F2FS_ROOT_INO, ino => ?ERX_F2FS_ROOT_INO, flag => 0,
                               cp_ver => Version, next_blkaddr => Inode + 1}},
    Dots = [#{slot => Slot, hash_code => erx_f2fs_codec:dentry_hash(Name),
              ino => ?ERX_F2FS_ROOT_INO, file_type => ?FILE_TYPE_DIR, name => Name}
            || {Slot, Name} <- [{0, <<".">>}, {1, <<"..">>}]],
    Slots = erx_f2fs_codec:dentry_slots(?BLOCK_SIZE),
    [{Inode, erx_f2fs_codec:encode_inode(Super, Root)}, {Inode + 1, Zero},
     {Dentries, erx_f2fs_codec:encode_dentry_block(#{bitmap => <<2#11:2, 0:(Slots - 2)>>,
                                                     entries => Dots})}].

%%% Arithmetic and the one failure path

ceil_div(A, B) -> (A + B - 1) div B.

ceil_to(A, B) -> ceil_div(A, B) * B.

chunks([], _Size) -> [];
chunks(List, Size) when length(List) =< Size -> [List];
chunks(List, Size) ->
    {Chunk, Rest} = lists:split(Size, List),
    [Chunk | chunks(Rest, Size)].

require(true, _Failure) -> ok;
require(false, Failure) -> fail(Failure).

-spec fail(failure()) -> no_return().
fail(Failure) -> throw({?MODULE, Failure}).
