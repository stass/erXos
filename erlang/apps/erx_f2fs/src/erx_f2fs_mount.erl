%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_mount).
-moduledoc """
F2FS's mount (docs/design-f2fs.md, "Mount"): the rules that relate a
volume's records to each other and to its partition, and erXos's own rules
of what it mounts and how ("Scope: features and forms"), over the records
erx_f2fs_codec reads. It runs the mount's first two steps, the superblock
copy and the checkpoint pack, and answers the volume's mode; [F n] cites
fact n of the F2FS facts record, part 1.

A mount is a pure function of the partition's size in blocks and the
blocks read so far, a map from address to block. When it needs a block the
map lacks it answers {need, Addresses}, every block that step needs at
once, and the caller reads them and runs it again from the start with them
added, as the volume process runs any step ("One process owns a volume").
Every address it asks for lies within the partition: the superblock copies'
blocks first, and the checkpoint area only once a valid copy has bounded
the volume by the partition and placed both packs inside that area.

The superblock: each copy is valid when the codec reads it, its
block_count and main area end within the partition, its checkpoint area
lies after the superblock's blocks and holds both packs ([F 19], [F 54]),
and its SSA holds a summary block for every main segment ([F 45]), bounds
erXos adds to Linux's. The first valid copy wins, and every bad copy's
failure is answered beside it so the caller can log it. With no valid copy
the mount fails with copy 0's failure: the copies are written alike, so
they are normally bad alike. Then the chosen copy alone must be one erXos
admits, its feature word with no bit outside R, the features that extend
an inode with EXTRA_ATTR, and no device list, or the mount fails: a copy
erXos refuses never yields to the other, older one.

The checkpoint pack: a pack is valid when the codec reads its header and
its last block, the header's copy, with the same checkpoint_ver ([F 22]),
and of two valid packs the later version under 64-bit wrap-around wins, a
tie going to pack 1. The chosen pack must carry only flags a mount accepts
and pass Linux's checks of a checkpoint ([F 55]) in the forms without RO,
which a mount refuses; then the codec reads its version bitmaps from the
header and the payload.

The mode is read_write when every feature is in W and the main area has
more than 16 sections, of any size, and otherwise {read_only, Reasons},
naming each shortfall: the R features and the main area's sections.

A failure is {Structure, Rule}: the codec's, or one of this module's
rules, reached by one module-private throw caught at mount/2. A rule that
names bits names each by its [F 10] or [F 25] name, or as the bit's value
when the record names none.
""".

-export([mount/2]).
-export_type([blocks/0, mounted/0, mode/0, failure/0]).

-include("generated/erx_abi.hrl").

-define(BLOCK_SIZE, (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE)).
-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
%% The superblock's two copies, in blocks 0 and 1 ([F 7]).
-define(SUPER_COPIES, [0, 1]).
%% The two checkpoint packs, one per checkpoint segment ([F 19]).
-define(PACKS, 2).
%% Each kind's logs in a checkpoint header: hot, warm and cold ([F 21]).
-define(LOGS_PER_KIND, 3).
%% The node ids below the NAT's capacity that hold no node ([F 36]).
-define(RESERVED_NIDS, 3).
%% The fewest checkpoint, table and reserved segments Linux mounts ([F 55]).
-define(METADATA_SEGMENTS_MIN, 8).
%% nat_bits' leading version word ([F 27]).
-define(NAT_BITS_VERSION_BYTES, 8).
%% The main sections erXos's cleaner keeps back, so a main area of no
%% more leaves it no room (docs/design-f2fs.md, "The space a volume offers").
-define(CLEANER_RESERVE_SECTIONS, 16).

-doc "The blocks a mount has read, by address.".
-type blocks() :: #{non_neg_integer() => binary()}.
-doc """
How the volume mounts: read-write, or read-only naming each reason
(docs/design-f2fs.md, "Scope: features and forms").
""".
-type mode() :: read_write |
                {read_only, [{features, [atom()]} |
                             {section_count, pos_integer()}]}.
-doc """
What the mount's first steps answer: the chosen superblock copy, each bad
copy's number and failure, the chosen pack's first block and its header
with its version bitmaps, and the mode.
""".
-type mounted() :: #{superblock := erx_f2fs_codec:superblock(),
                     bad_copies := [{0 | 1, failure()}],
                     pack := non_neg_integer(),
                     checkpoint := erx_f2fs_codec:checkpoint(),
                     mode := mode()}.
-doc "The structure the mount read and the first rule it broke.".
-type failure() :: {superblock | checkpoint, term()}.

-doc """
The mount of a partition of Partition blocks from Blocks, the blocks read
so far: {ok, Mounted}, {need, Addresses} naming the blocks it needs next,
or {error, Failure}.
""".
-spec mount(non_neg_integer(), blocks()) ->
          {ok, mounted()} | {need, [non_neg_integer()]} | {error, failure()}.
mount(Partition, Blocks) ->
    try
        {Super, BadCopies} = superblock(Partition, Blocks),
        {Pack, Checkpoint} = checkpoint(Super, Blocks),
        {ok, #{superblock => Super, bad_copies => BadCopies, pack => Pack,
               checkpoint => Checkpoint, mode => mode(Super)}}
    catch
        throw:{?MODULE, need, Addresses} -> {need, Addresses};
        throw:{?MODULE, failure, Failure} -> {error, Failure}
    end.

%%% The superblock

superblock(Partition, Blocks) ->
    require(Partition >= length(?SUPER_COPIES), {superblock, partition}),
    Copies = lists:zip(?SUPER_COPIES,
                       [superblock_copy(Partition, Block)
                        || Block <- read(Blocks, ?SUPER_COPIES)]),
    BadCopies = [{Copy, Failure} || {Copy, {error, Failure}} <- Copies],
    case [Super || {_Copy, {ok, Super}} <- Copies] of
        [Super | _] ->
            check_features(Super),
            check_device_list(Super),
            {Super, BadCopies};
        [] ->
            [{_Copy, First} | _] = BadCopies,
            fail(First)
    end.

%% A copy is valid or fails on its own, so each is checked under a catch of
%% its own; only the choice between them fails the mount. Validity is the
%% copy's structure and geometry; what erXos admits is asked of the chosen
%% copy alone, above.
superblock_copy(Partition, Block) ->
    try
        Super = ok(erx_f2fs_codec:superblock(Block)),
        check_partition(Partition, Super),
        check_checkpoint_area(Super),
        check_ssa_area(Super),
        {ok, Super}
    catch
        throw:{?MODULE, failure, Failure} -> {error, Failure}
    end.

check_partition(Partition, #{block_count := Blocks} = Super) ->
    require(Blocks =< Partition andalso main_end(Super) =< Partition,
            {superblock, partition}).

%% Every bit in R, and the features that extend an inode with EXTRA_ATTR
%% ([F 41]), so no inode read meets a layout the superblock cannot place.
check_features(#{feature := Feature}) ->
    Refused = names(classify(Feature, features()), refused),
    require(Refused =:= [], {superblock, {features, Refused}}),
    Extending = case Feature band ?ERX_F2FS_FEATURE_EXTRA_ATTR of
                    0 -> names(classify(Feature band erx_f2fs_codec:extra_attr_features(),
                                        features()));
                    _ -> []
                end,
    require(Extending =:= [], {superblock, {needs_extra_attr, Extending}}).

%% A device list is present when device 0 has a path ([F 54]); erXos mounts
%% no multi-device volume.
check_device_list(#{devs := [#{path := <<First, _/binary>>} | _]}) ->
    require(First =:= 0, {superblock, device_list}).

%% The checkpoint area lies after the superblock's blocks, and pack 2
%% starts a segment after pack 1 ([F 19]), so the area holds both only with
%% two segments; Linux checks neither, and reads pack 2 there regardless.
check_checkpoint_area(#{cp_blkaddr := Start, segment_count_ckpt := Segments}) ->
    require(Start >= length(?SUPER_COPIES) andalso Segments >= ?PACKS,
            {superblock, checkpoint_area}).

%% The SSA holds a summary block for every main segment ([F 45]), so no
%% segment's summary lies past the area, in the main area itself; Linux
%% checks the areas' order but not this size.
check_ssa_area(#{segment_count_ssa := Ssa, segment_count_main := Main}) ->
    require(Ssa * ?BLOCKS_PER_SEG >= Main, {superblock, ssa_area}).

%%% The checkpoint pack

%% Both packs' headers, then the copy each header places, in one need
%% each, then the chosen pack's payload.
checkpoint(#{cp_blkaddr := First, cp_payload := PayloadBlocks} = Super, Blocks) ->
    Starts = [First + Pack * ?BLOCKS_PER_SEG || Pack <- lists:seq(0, ?PACKS - 1)],
    Headers = [{Start, Block, erx_f2fs_codec:checkpoint(Block)}
               || {Start, Block} <- lists:zip(Starts, read(Blocks, Starts))],
    CopyAddresses = [copy_address(Start, Header) || {Start, _Block, {ok, Header}} <- Headers],
    Copies = maps:from_list(lists:zip(CopyAddresses, read(Blocks, CopyAddresses))),
    {Start, Block, Header} = choose([pack(Pack, Copies) || Pack <- Headers]),
    check_flags(Header),
    check_counts(Super, Header),
    check_logs(Super, Header),
    check_bitmap_sizes(Super, Header),
    check_start_sum(Super, Header),
    check_nat_bits(Super, Header),
    Payload = read(Blocks, [Start + N || N <- lists:seq(1, PayloadBlocks)]),
    {Start, ok(erx_f2fs_codec:checkpoint(Super, Block, Payload))}.

copy_address(Start, #{cp_pack_total_block_count := Total}) -> Start + Total - 1.

%% A pack is valid when its header reads, its copy reads, and both carry
%% one version ([F 22]); otherwise the first rule it broke, a copy's
%% tagged as the copy's. Copies holds the copy of every header that read.
pack({_Start, _Block, {error, {checkpoint, Rule}}}, _Copies) ->
    {error, Rule};
pack({Start, Block, {ok, #{checkpoint_ver := Version} = Header}}, Copies) ->
    case erx_f2fs_codec:checkpoint_copy(maps:get(copy_address(Start, Header), Copies)) of
        {ok, #{checkpoint_ver := Version}} -> {ok, {Start, Block, Header}};
        {ok, _Other} -> {error, copy_version};
        {error, {checkpoint, Rule}} -> {error, {copy, Rule}}
    end.

choose([{ok, Pack1}, {ok, Pack2}]) ->
    case later(version(Pack2), version(Pack1)) of
        true -> Pack2;
        false -> Pack1
    end;
choose([{ok, Pack1}, {error, _}]) -> Pack1;
choose([{error, _}, {ok, Pack2}]) -> Pack2;
choose([{error, Rule1}, {error, Rule2}]) ->
    fail({checkpoint, {no_valid_pack, [Rule1, Rule2]}}).

version({_Start, _Block, #{checkpoint_ver := Version}}) -> Version.

%% Whether version A comes after B under 64-bit wrap-around ([F 22]): their
%% difference, as a signed 64-bit number, is positive.
later(A, B) ->
    <<Difference:64/signed>> = <<(A - B):64>>,
    Difference > 0.

check_flags(#{ckpt_flags := Flags}) ->
    Refused = names(classify(Flags, flags()), refused),
    require(Refused =:= [], {checkpoint, {flags, Refused}}).

%% The segment and block counts of [F 55] and the node count against the
%% NAT's capacity ([F 36]).
check_counts(#{segment_count := Segments, segment_count_ckpt := Checkpoint,
               segment_count_sit := Sit, segment_count_nat := Nat,
               segment_count_ssa := Ssa, segment_count_main := Main},
             #{rsvd_segment_count := Reserved, overprov_segment_count := Overprovision,
               user_block_count := User, valid_block_count := Valid,
               valid_node_count := Nodes}) ->
    Metadata = Checkpoint + Sit + Nat + Ssa + Reserved,
    require(Metadata < Segments andalso Metadata >= ?METADATA_SEGMENTS_MIN,
            {checkpoint, metadata_segments}),
    require(Overprovision =/= 0 andalso Reserved =/= 0, {checkpoint, reserved_segments}),
    require(User > 0 andalso User < Main * ?BLOCKS_PER_SEG, {checkpoint, user_blocks}),
    require(Valid =< User, {checkpoint, valid_blocks}),
    Capacity = ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK * table_blocks(Nat),
    require(Nodes =< Capacity - ?RESERVED_NIDS, {checkpoint, valid_nodes}).

%% Each of the six logs inside the main area, and no two on one segment
%% ([F 55]).
check_logs(#{segment_count_main := Main},
           #{cur_node_segno := NodeSegments, cur_node_blkoff := NodeOffsets,
             cur_data_segno := DataSegments, cur_data_blkoff := DataOffsets}) ->
    Segments = lists:sublist(NodeSegments, ?LOGS_PER_KIND) ++
        lists:sublist(DataSegments, ?LOGS_PER_KIND),
    Offsets = lists:sublist(NodeOffsets, ?LOGS_PER_KIND) ++
        lists:sublist(DataOffsets, ?LOGS_PER_KIND),
    require(lists:all(fun(Segment) -> Segment < Main end, Segments) andalso
                lists:all(fun(Offset) -> Offset < ?BLOCKS_PER_SEG end, Offsets),
            {checkpoint, log_position}),
    require(length(lists:usort(Segments)) =:= length(Segments), {checkpoint, log_segments}).

%% One version bit per block of one copy of each table, exactly, and a SIT
%% bit for every SIT block the main area's segments need ([F 23], [F 55]).
check_bitmap_sizes(#{segment_count_sit := Sit, segment_count_nat := Nat,
                     segment_count_main := Main},
                   #{sit_ver_bitmap_bytesize := SitBytes,
                     nat_ver_bitmap_bytesize := NatBytes}) ->
    require(SitBytes =:= bitmap_bytes(Sit) andalso NatBytes =:= bitmap_bytes(Nat),
            {checkpoint, bitmap_size}),
    require(SitBytes * 8 >= ceil_div(Main, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK),
            {checkpoint, sit_bitmap_bits}).

%% The data summaries start after the header, the payload and any orphan
%% blocks, with room for the most summary blocks and the copy ([F 55]).
check_start_sum(#{cp_payload := Payload}, #{cp_pack_start_sum := StartSum}) ->
    require(StartSum >= Payload + 1 andalso
                StartSum =< ?BLOCKS_PER_SEG - 1 - ?ERX_F2FS_CP_SUMMARY_BLOCKS_MAX,
            {checkpoint, start_sum}).

%% nat_bits, its version word and two bitmaps of a bit per NAT block of one
%% copy, fill the end of the pack's segment and must leave room for the
%% largest pack ([F 27]).
check_nat_bits(#{cp_payload := Payload, segment_count_nat := Nat},
               #{ckpt_flags := Flags}) when Flags band ?ERX_F2FS_CP_NAT_BITS =/= 0 ->
    NatBitsBlocks = ceil_div(?NAT_BITS_VERSION_BYTES + 2 * bitmap_bytes(Nat), ?BLOCK_SIZE),
    require(Payload + ?ERX_F2FS_CP_FIXED_BLOCKS + ?ERX_F2FS_CP_SUMMARY_BLOCKS_MAX +
                NatBitsBlocks < ?BLOCKS_PER_SEG,
            {checkpoint, nat_bits_room});
check_nat_bits(_Super, _Header) ->
    ok.

%%% The mode

mode(#{feature := Feature, section_count := Sections}) ->
    ReadOnly = names(classify(Feature, features()), read),
    Reasons = [{features, ReadOnly} || ReadOnly =/= []] ++
        [{section_count, Sections} || Sections =< ?CLEANER_RESERVE_SECTIONS],
    case Reasons of
        [] -> read_write;
        _ -> {read_only, Reasons}
    end.

%%% Bits by name

%% The feature word's bits ([F 10]) by what erXos does with them
%% (docs/design-f2fs.md, "Scope: features and forms"): write, in W, which
%% erXos maintains when it writes; read, in R alone; refused, even read-only.
features() ->
    [{?ERX_F2FS_FEATURE_ENCRYPT, encrypt, refused},
     {?ERX_F2FS_FEATURE_BLKZONED, blkzoned, refused},
     {?ERX_F2FS_FEATURE_ATOMIC_WRITE, atomic_write, refused},
     {?ERX_F2FS_FEATURE_EXTRA_ATTR, extra_attr, write},
     {?ERX_F2FS_FEATURE_PRJQUOTA, prjquota, read},
     {?ERX_F2FS_FEATURE_INODE_CHKSUM, inode_chksum, write},
     {?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR, flexible_inline_xattr, read},
     {?ERX_F2FS_FEATURE_QUOTA_INO, quota_ino, read},
     {?ERX_F2FS_FEATURE_INODE_CRTIME, inode_crtime, read},
     {?ERX_F2FS_FEATURE_LOST_FOUND, lost_found, write},
     {?ERX_F2FS_FEATURE_VERITY, verity, refused},
     {?ERX_F2FS_FEATURE_SB_CHKSUM, sb_chksum, write},
     {?ERX_F2FS_FEATURE_CASEFOLD, casefold, refused},
     {?ERX_F2FS_FEATURE_COMPRESSION, compression, refused},
     {?ERX_F2FS_FEATURE_RO, ro, refused},
     {?ERX_F2FS_FEATURE_DEVICE_ALIAS, device_alias, refused},
     {?ERX_F2FS_FEATURE_PACKED_SSA, packed_ssa, refused}].

%% The checkpoint flags ([F 25]) a mount accepts and those it refuses
%% (docs/design-f2fs.md, "Scope: features and forms").
flags() ->
    [{?ERX_F2FS_CP_UMOUNT, umount, accepted},
     {?ERX_F2FS_CP_ORPHAN_PRESENT, orphan_present, accepted},
     {?ERX_F2FS_CP_COMPACT_SUM, compact_sum, accepted},
     {?ERX_F2FS_CP_ERROR, error, refused},
     {?ERX_F2FS_CP_FSCK, fsck, accepted},
     {?ERX_F2FS_CP_FASTBOOT, fastboot, accepted},
     {?ERX_F2FS_CP_CRC_RECOVERY, crc_recovery, accepted},
     {?ERX_F2FS_CP_NAT_BITS, nat_bits, accepted},
     {?ERX_F2FS_CP_TRIMMED, trimmed, accepted},
     {?ERX_F2FS_CP_NOCRC_RECOVERY, nocrc_recovery, accepted},
     {?ERX_F2FS_CP_LARGE_NAT_BITMAP, large_nat_bitmap, refused},
     {?ERX_F2FS_CP_QUOTA_NEED_FSCK, quota_need_fsck, accepted},
     {?ERX_F2FS_CP_DISABLED, disabled, refused},
     {?ERX_F2FS_CP_DISABLED_QUICK, disabled_quick, refused},
     {?ERX_F2FS_CP_RESIZEFS, resizefs, refused}].

%% The bits set in a 32-bit Word, lowest first, each with its name and
%% class from Table, or as its own value and refused when Table has none.
classify(Word, Table) ->
    [case lists:keyfind(Bit, 1, Table) of
         {Bit, Name, Class} -> {Name, Class};
         false -> {Bit, refused}
     end
     || Shift <- lists:seq(0, 31), Bit <- [1 bsl Shift], Word band Bit =/= 0].

names(Classified) -> [Name || {Name, _Class} <- Classified].

names(Classified, Class) -> [Name || {Name, Of} <- Classified, Of =:= Class].

%%% Geometry

main_end(#{main_blkaddr := Main, segment_count_main := Segments}) ->
    Main + Segments * ?BLOCKS_PER_SEG.

%% The blocks of one copy of a table of Segments segments, which holds two
%% copies ([F 23], [F 36]).
table_blocks(Segments) -> Segments div 2 * ?BLOCKS_PER_SEG.

%% A version bitmap's bytes: a bit per block of one copy ([F 23]).
bitmap_bytes(Segments) -> table_blocks(Segments) div 8.

ceil_div(A, B) -> (A + B - 1) div B.

%%% Blocks and the one failure path

%% The blocks at Addresses, in order, or a need of every one Blocks lacks.
read(Blocks, Addresses) ->
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
