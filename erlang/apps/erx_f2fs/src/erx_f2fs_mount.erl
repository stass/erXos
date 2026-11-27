%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_mount).
-moduledoc """
F2FS's mount (docs/design-f2fs.md, "Mount"): the rules that relate a
volume's records to each other and to its partition, and erXos's own rules
of what it mounts and how ("Scope: features and forms"), over the records
erx_f2fs_codec reads. It chooses the superblock copy and the checkpoint
pack, reads the pack's contents and the tables, checks the root inode,
asks whether the checkpoint has a chain of node blocks to replay, and
answers the volume's mode; [F n] cites fact n of the F2FS facts record,
part 1.

A mount is a pure function of the partition's size in blocks, the mount's
allowance in bytes, and the blocks read so far, a map from address to
block. When it needs a block the map lacks it answers {need, Addresses},
every block that step needs at once, and the caller reads them and runs it
again from the start with them added, as the volume process runs any step
("One process owns a volume"). Every address it asks for lies within the
partition: the superblock copies' blocks first, the checkpoint area only
once a valid copy has bounded the volume by the partition and placed both
packs inside that area, and the SIT, the NAT and the main area only within
their areas, which that copy also bounds, at indices the checked counts
and bitmap sizes bound.

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

The pack's contents ([F 20]): its orphan blocks when it has ORPHAN_PRESENT,
its data summaries, compact or normal ([F 29], [F 30]), and its node
summaries when it has UMOUNT or FASTBOOT. Linux finds compact summaries
from cp_pack_start_sum and normal ones from the pack's end, and does not
check that the two agree; erXos requires them to, so the data summaries
are exactly the blocks between cp_pack_start_sum and the node summaries,
three of them in the normal form and one or two in the compact one.
Each log's summaries are answered for the blocks it has written, its next
offset's worth, or the whole segment for an SSR log ([F 29]). A pack
without node summaries leaves the node logs' summaries to be rebuilt from
their segments' footers ([F 31]) by the writer, which alone needs them.
The NAT journal is the hot data log's and the SIT journal the cold data
log's ([F 28]); each names a node, or a main segment, once.

The tables ([F 34], [F 38], [F 39]): the SIT is admitted against the
mount's allowance at ?SIT_BYTES_PER_SEGMENT bytes for each main segment
before any of it is read (docs/design-f2fs.md, "Mount"), then read whole,
each block from the copy its version bit selects, with the SIT journal
over it, and checked: the node segments' valid blocks are valid_node_count
and all segments' at most valid_block_count, and every log's next block is
free in its segment, with every later block free too for an LFS log. The
NAT journal is handed to erx_f2fs_core, which checks it and alone resolves
a nid. The root is the inode erx_f2fs_core reads, a directory with blocks,
a size and links ([F 55]).

The chain: the warm node log's next block starts the checkpoint's chain of
fsynced node blocks when its footer carries the checkpoint's version
(docs/design-f2fs.md, "The walk"). This mount does not replay, so a chain
fails it with {walk, chain}, whose remedy is one mount in Linux, which
replays the chain and writes a checkpoint. A first block that tore reads
as a chain too, failing the mount where the walk would end at once.

The mode is read_write when every feature is in W and the main area has
more than 16 sections, of any size, and otherwise {read_only, Reasons},
naming each shortfall: the R features and the main area's sections.

A failure is {Structure, Rule}: the codec's, or one of this module's
rules, reached by one module-private throw caught at mount/3. A rule that
names bits names each by its [F 10] or [F 25] name, or as the bit's value
when the record names none. {allowance, {sit, Bytes}} is the one failure
of memory rather than of the medium: the SIT of Bytes would pass the
allowance, and the caller answers it enomem. The orphan list, at most a
pack's blocks of 1020 numbers each, is bounded by the format and not
admitted.
""".

-export([mount/3]).
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
%% The fewest checkpoint, table and reserved segments Linux mounts ([F 55]).
-define(METADATA_SEGMENTS_MIN, 8).
%% nat_bits' leading version word ([F 27]).
-define(NAT_BITS_VERSION_BYTES, 8).
%% The main sections erXos's cleaner keeps back, so a main area of no
%% more leaves it no room (docs/design-f2fs.md, "The space a volume offers").
-define(CLEANER_RESERVE_SECTIONS, 16).
%% What the SIT holds in memory for each main segment, in bytes, which the
%% mount's allowance admits (docs/design-f2fs.md, "Mount"): its entry's map
%% with the copied 64-byte valid map and its tuple slot, measured with
%% erts_debug:size at 144 bytes on the host's OTP, 160 when an mtime is
%% a bignum.
-define(SIT_BYTES_PER_SEGMENT, 160).

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
What a mount answers: the chosen superblock copy, each bad copy's number
and failure, the chosen pack's first block and its header with its version
bitmaps, the pack's orphan inodes, the data logs' summaries and the node
logs' when the pack has them (each list hot, warm, cold), the SIT, element
S + 1 for main segment S, the NAT, which erx_f2fs_core resolves, the root
inode, and the mode: erx_f2fs_core's volume.
""".
-type mounted() :: #{superblock := erx_f2fs_codec:superblock(),
                     bad_copies := [{0 | 1, failure()}],
                     pack := non_neg_integer(),
                     checkpoint := erx_f2fs_codec:checkpoint(),
                     orphans := [non_neg_integer()],
                     data_summaries := [[erx_f2fs_codec:summary()]],
                     node_summaries := [[erx_f2fs_codec:summary()]] | none,
                     sit := tuple(),
                     nat := erx_f2fs_core:nat(),
                     root := erx_f2fs_codec:inode(),
                     mode := mode()}.
-doc "The structure the mount read and the first rule it broke.".
-type failure() :: {superblock | checkpoint | sit | nat | root | walk | allowance,
                    term()} |
                   erx_f2fs_core:failure() | erx_f2fs_codec:failure().

-doc """
The mount of a partition of Partition blocks, holding at most Allowance
bytes of tables, from Blocks, the blocks read so far: {ok, Mounted},
{need, Addresses} naming the blocks it needs next, or {error, Failure}.
""".
-spec mount(non_neg_integer(), non_neg_integer(), blocks()) ->
          {ok, mounted()} | {need, [non_neg_integer()]} | {error, failure()}.
mount(Partition, Allowance, Blocks) ->
    try
        {Super, BadCopies} = superblock(Partition, Blocks),
        {Pack, Checkpoint} = checkpoint(Super, Blocks),
        Contents = contents(Super, Pack, Checkpoint, Blocks),
        admit_sit(Super, Allowance),
        %% The SIT and the chain's first block are each placed by what is
        %% read already, so they are asked at once.
        read(Blocks, sit_addresses(Super, Checkpoint) ++ [walk_start(Super, Checkpoint)]),
        Volume = maps:merge(maps:remove(sit_journal, Contents),
                            #{superblock => Super, bad_copies => BadCopies, pack => Pack,
                              checkpoint => Checkpoint,
                              sit => sit(Super, Checkpoint, Contents, Blocks)}),
        Root = root(Volume, Blocks),
        check_chain(Super, Checkpoint, Blocks),
        {ok, Volume#{root => Root, mode => mode(Super)}}
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
    require(Blocks =< Partition andalso erx_f2fs_codec:main_end(Super) =< Partition,
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
               segment_count_ssa := Ssa, segment_count_main := Main} = Super,
             #{rsvd_segment_count := Reserved, overprov_segment_count := Overprovision,
               user_block_count := User, valid_block_count := Valid,
               valid_node_count := Nodes}) ->
    Metadata = Checkpoint + Sit + Nat + Ssa + Reserved,
    require(Metadata < Segments andalso Metadata >= ?METADATA_SEGMENTS_MIN,
            {checkpoint, metadata_segments}),
    require(Overprovision =/= 0 andalso Reserved =/= 0, {checkpoint, reserved_segments}),
    require(User > 0 andalso User < Main * ?BLOCKS_PER_SEG, {checkpoint, user_blocks}),
    require(Valid =< User, {checkpoint, valid_blocks}),
    require(Nodes =< erx_f2fs_codec:node_capacity(Super),
            {checkpoint, valid_nodes}).

%% Each of the six logs inside the main area, no two on one segment
%% ([F 55]), and each appending or reusing a segment ([F 39]).
check_logs(#{segment_count_main := Main}, Header) ->
    Logs = logs(Header),
    require(lists:all(fun({_Type, Segment, Offset, _Alloc}) ->
                              Segment < Main andalso Offset < ?BLOCKS_PER_SEG
                      end, Logs),
            {checkpoint, log_position}),
    Segments = [Segment || {_Type, Segment, _Offset, _Alloc} <- Logs],
    require(length(lists:usort(Segments)) =:= length(Segments), {checkpoint, log_segments}),
    require(lists:all(fun({_Type, _Segment, _Offset, Alloc}) ->
                              Alloc =:= ?ERX_F2FS_ALLOC_LFS orelse Alloc =:= ?ERX_F2FS_ALLOC_SSR
                      end, Logs),
            {checkpoint, alloc_type}).

%% The six logs in type order, hot, warm and cold data, then node ([F 21]),
%% each {Type, Segment, NextOffset, AllocType}.
logs(#{cur_node_segno := NodeSegments, cur_node_blkoff := NodeOffsets,
       cur_data_segno := DataSegments, cur_data_blkoff := DataOffsets,
       alloc_type := Alloc}) ->
    Segments = lists:sublist(DataSegments, ?LOGS_PER_KIND) ++
        lists:sublist(NodeSegments, ?LOGS_PER_KIND),
    Offsets = lists:sublist(DataOffsets, ?LOGS_PER_KIND) ++
        lists:sublist(NodeOffsets, ?LOGS_PER_KIND),
    Types = lists:seq(0, 2 * ?LOGS_PER_KIND - 1),
    [{Type, Segment, Offset, binary:at(Alloc, Type)}
     || {Type, Segment, Offset} <- lists:zip3(Types, Segments, Offsets)].

%% One version bit per block of one copy of each table, exactly, and a SIT
%% bit for every SIT block the main area's segments need ([F 23], [F 55]).
check_bitmap_sizes(#{segment_count_sit := Sit, segment_count_nat := Nat,
                     segment_count_main := Main},
                   #{sit_ver_bitmap_bytesize := SitBytes,
                     nat_ver_bitmap_bytesize := NatBytes}) ->
    require(SitBytes =:= erx_f2fs_codec:bitmap_bytes(Sit) andalso
                NatBytes =:= erx_f2fs_codec:bitmap_bytes(Nat),
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
    NatBitsBlocks = ceil_div(?NAT_BITS_VERSION_BYTES + 2 * erx_f2fs_codec:bitmap_bytes(Nat),
                             ?BLOCK_SIZE),
    require(Payload + ?ERX_F2FS_CP_FIXED_BLOCKS + ?ERX_F2FS_CP_SUMMARY_BLOCKS_MAX +
                NatBitsBlocks < ?BLOCKS_PER_SEG,
            {checkpoint, nat_bits_room});
check_nat_bits(_Super, _Header) ->
    ok.

%%% The pack's contents

%% The orphan blocks, data summaries and node summaries, in one need, and
%% the journals the data summaries carry. The data summaries end where the
%% node summaries start, which end before the copy, the pack's last block.
contents(#{cp_payload := PayloadBlocks} = Super, Start,
         #{cp_pack_start_sum := StartSum, cp_pack_total_block_count := Total,
           ckpt_flags := Flags} = Header, Blocks) ->
    NodeBlocks = case has(Flags, ?ERX_F2FS_CP_UMOUNT bor ?ERX_F2FS_CP_FASTBOOT) of
                     true -> ?LOGS_PER_KIND;
                     false -> 0
                 end,
    DataBlocks = Total - 1 - NodeBlocks - StartSum,
    Compact = has(Flags, ?ERX_F2FS_CP_COMPACT_SUM),
    require(case Compact of
                %% Linux writes the compact form only when it fits fewer
                %% blocks than the normal form's three ([F 25]).
                true -> DataBlocks >= 1 andalso DataBlocks < ?LOGS_PER_KIND;
                false -> DataBlocks =:= ?LOGS_PER_KIND
            end,
            {checkpoint, pack_layout}),
    Orphans = case has(Flags, ?ERX_F2FS_CP_ORPHAN_PRESENT) of
                  true -> span(Start + 1 + PayloadBlocks, StartSum - 1 - PayloadBlocks);
                  false -> []
              end,
    Data = span(Start + StartSum, DataBlocks),
    Node = span(Start + StartSum + DataBlocks, NodeBlocks),
    read(Blocks, Orphans ++ Data ++ Node),
    {DataLogs, NodeLogs} = lists:split(?LOGS_PER_KIND, logs(Header)),
    {DataSummaries, NatJournal, SitJournal} =
        data_summaries(Compact, DataLogs, read(Blocks, Data)),
    #{orphans => lists:append([ok(erx_f2fs_codec:orphan_block(Block))
                               || Block <- read(Blocks, Orphans)]),
      data_summaries => DataSummaries,
      node_summaries => node_summaries(NodeLogs, read(Blocks, Node)),
      nat => nat(Super, ok(erx_f2fs_codec:nat_journal(NatJournal))),
      sit_journal => sit_journal(Super, SitJournal)}.

%% The data logs' summaries and the NAT and SIT journals' bytes: the
%% compact form holds both journals in its first block, and the normal form
%% the NAT journal in the hot log's summary and the SIT journal in the cold
%% log's ([F 28], [F 29]).
data_summaries(true, Logs, Blocks) ->
    #{nat_journal := Nat, sit_journal := Sit, summaries := Summaries} =
        ok(erx_f2fs_codec:compact_summaries([written(Log) || Log <- Logs], Blocks)),
    {Summaries, Nat, Sit};
data_summaries(false, Logs, Blocks) ->
    [#{journal := Nat}, _Warm, #{journal := Sit}] = Read =
        [ok(erx_f2fs_codec:summary_block(Block)) || Block <- Blocks],
    {logs_summaries(Logs, Read), Nat, Sit}.

node_summaries(_Logs, []) -> none;
node_summaries(Logs, Blocks) ->
    logs_summaries(Logs, [ok(erx_f2fs_codec:summary_block(Block)) || Block <- Blocks]).

logs_summaries(Logs, Summaries) ->
    [lists:sublist(Entries, written(Log))
     || {Log, #{entries := Entries}} <- lists:zip(Logs, Summaries)].

%% The blocks of its segment a log has written: up to its next offset, or
%% any of them for an SSR log, which fills free blocks wherever they lie
%% ([F 29]).
written({_Type, _Segment, _Offset, ?ERX_F2FS_ALLOC_SSR}) -> ?BLOCKS_PER_SEG;
written({_Type, _Segment, Offset, ?ERX_F2FS_ALLOC_LFS}) -> Offset.

%% The SIT journal's entries, each for a main segment ([F 39]), named once.
sit_journal(#{segment_count_main := Main}, Bytes) ->
    Entries = ok(erx_f2fs_codec:sit_journal(Bytes)),
    Segments = [Segment || #{segno := Segment} <- Entries],
    require(lists:all(fun(Segment) -> Segment < Main end, Segments), {sit, journal_segno}),
    require(length(lists:usort(Segments)) =:= length(Segments), {sit, journal_duplicate}),
    Entries.

%%% The tables

admit_sit(#{segment_count_main := Main}, Allowance) ->
    Bytes = Main * ?SIT_BYTES_PER_SEGMENT,
    require(Bytes =< Allowance, {allowance, {sit, Bytes}}).

%% Each SIT block the main area needs, from the copy its version bit
%% selects ([F 38]).
sit_addresses(#{segment_count_main := Main} = Super, Checkpoint) ->
    [erx_f2fs_codec:current_block(sit, Super, Checkpoint, Index)
     || Index <- lists:seq(0, ceil_div(Main, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK) - 1)].

%% The SIT, whole, as a tuple of the main segments' entries with the
%% journal's over the blocks', then checked as a whole.
sit(#{segment_count_main := Main} = Super, Header, #{sit_journal := Journal}, Blocks) ->
    PerBlock = ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK,
    Read = lists:enumerate(0, read(Blocks, sit_addresses(Super, Header))),
    Entries = lists:append(
                [ok(erx_f2fs_codec:sit_block(Block, min(PerBlock, Main - Index * PerBlock)))
                 || {Index, Block} <- Read]),
    Sit = lists:foldl(fun(#{segno := Segment, entry := Entry}, Table) ->
                              setelement(Segment + 1, Table, Entry)
                      end, list_to_tuple(Entries), Journal),
    check_sit(Header, Sit),
    Sit.

%% The counts the checkpoint records against the SIT's, and each log's next
%% block free in its segment ([F 39]).
check_sit(#{valid_node_count := Nodes, valid_block_count := Valid} = Header, Sit) ->
    Segments = tuple_to_list(Sit),
    require(lists:sum([Count || #{type := Type, valid_blocks := Count} <- Segments,
                                Type >= ?ERX_F2FS_LOG_HOT_NODE]) =:= Nodes,
            {sit, valid_nodes}),
    require(lists:sum([Count || #{valid_blocks := Count} <- Segments]) =< Valid,
            {sit, valid_blocks}),
    require(lists:all(fun(Log) -> next_block_free(Sit, Log) end, logs(Header)),
            {sit, log_next_block}).

%% A log's next block is free, and for an LFS log, which appends, every
%% block after it too.
next_block_free(Sit, {_Type, Segment, Offset, Alloc}) ->
    #{valid_map := Map} = element(Segment + 1, Sit),
    <<_:Offset, Next:1, Later/bitstring>> = Map,
    Next =:= 0 andalso (Alloc =:= ?ERX_F2FS_ALLOC_SSR orelse Later =:= <<0:(bit_size(Later))>>).

%%% The root

%% The root's inode, a directory with blocks, a size and links ([F 55]);
%% the codec refuses every inode without blocks.
root(#{superblock := #{root_ino := Root}} = Volume, Blocks) ->
    #{i_mode := Mode, i_size := Size, i_links := Links} = Inode =
        ok(erx_f2fs_core:inode(Volume, Root, Blocks)),
    require(Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_DIR, {root, not_directory}),
    require(Size =/= 0, {root, no_size}),
    require(Links =/= 0, {root, no_links}),
    Inode.

%%% The chain

%% The chain starts at the warm node log's next block (docs/design-f2fs.md,
%% "The walk").
walk_start(#{main_blkaddr := Main},
           #{cur_node_segno := [_Hot, Warm | _], cur_node_blkoff := [_, Offset | _]}) ->
    Main + Warm * ?BLOCKS_PER_SEG + Offset.

check_chain(Super, Header, Blocks) ->
    [Block] = read(Blocks, [walk_start(Super, Header)]),
    #{cp_ver := Version} = ok(erx_f2fs_codec:node_footer(Block)),
    require(not of_checkpoint(Header, Version), {walk, chain}).

%% Whether a node footer's cp_ver is the checkpoint's: its version with its
%% CRC in the upper 32 bits under CRC_RECOVERY, or the version alone, or
%% under NOCRC_RECOVERY the version's low 32 bits ([F 43]).
of_checkpoint(#{checkpoint_ver := Version, crc := Crc, ckpt_flags := Flags}, Footer) ->
    Expected = case has(Flags, ?ERX_F2FS_CP_CRC_RECOVERY) of
                   true -> Version bor (Crc bsl 32);
                   false -> Version
               end,
    Footer =:= Expected orelse
        (has(Flags, ?ERX_F2FS_CP_NOCRC_RECOVERY) andalso
             Footer band 16#ffffffff =:= Version band 16#ffffffff).

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


ceil_div(A, B) -> (A + B - 1) div B.

has(Word, Bits) -> Word band Bits =/= 0.

%% Count addresses from First.
span(First, Count) -> [First + Offset || Offset <- lists:seq(0, Count - 1)].

%%% Blocks and the one failure path

%% The blocks at Addresses, in order, or a need of every one Blocks lacks.
read(Blocks, Addresses) ->
    case [Address || Address <- Addresses, not is_map_key(Address, Blocks)] of
        [] -> [maps:get(Address, Blocks) || Address <- Addresses];
        Missing -> throw({?MODULE, need, lists:usort(Missing)})
    end.

%% The NAT the core makes of the journal's Entries, opaque to this module,
%% so it is matched here and never by ok/1.
nat(Super, Entries) ->
    case erx_f2fs_core:nat(Super, Entries) of
        {ok, Nat} -> Nat;
        {error, Failure} -> fail(Failure)
    end.

ok({ok, Value}) -> Value;
ok({need, Addresses}) -> throw({?MODULE, need, Addresses});
ok({error, Failure}) -> fail(Failure).

require(true, _Failure) -> ok;
require(false, Failure) -> fail(Failure).

-spec fail(failure()) -> no_return().
fail(Failure) -> throw({?MODULE, failure, Failure}).
