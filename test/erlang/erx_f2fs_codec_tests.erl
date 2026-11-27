%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_f2fs_codec (docs/design-f2fs.md, "Reading the medium" and
%% "Unit and property tests"), run on stock OTP by test/host/erx_f2fs_codec_test.rb,
%% which also runs them against seeded faults.
%%
%% The fixtures are a 64 MiB volume's superblock and checkpoint header built field by
%% field with erx_abi_packed:encode/2 and their checksums computed by crc_reference/2, a
%% bitwise CRC written from the facts record's definition ([F 49]) and independent of
%% the codec's use of erlang:crc32/2. Agreeing with that definition does not settle
%% whether Linux's CRC routine is the same (open question 1 of the facts record): the
%% CRCs of Linux-made images do, when the oracle guest makes them. Each rejection case breaks one rule of a fixture,
%% refreshes the checksum so the rule itself is what fails, and expects that rule.
%% erx_f2fs_fuzz builds its seeds from the same fixtures.
-module(erx_f2fs_codec_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([superblock_fields/0, superblock_block/1, checkpoint_fields/0,
         checkpoint_block/2, orphan_block/2, crc_reference/2,
         nat_entry/3, nat_block/1, nat_journal/2, sit_entry/2, sit_block/1,
         sit_journal/2, summary_block/1, compact_blocks/3, inode_fields/0,
         inode_block/2, inode_checksum_applies/2, with_inode_checksum/2,
         dentry_block/1, dentry_area/3, inline_inode/3]).

-define(BLOCK, 4096).

%%% Fixtures

%% A volume of 16384 blocks: segment 0 at block 512, then 2 checkpoint, 2 SIT,
%% 2 NAT and 1 SSA segments and a main area of 24, ending at the volume's end.
superblock_fields() ->
    Empty = maps:from_list([{Field, 0} || Field <- integer_fields(erx_f2fs_super_block)]),
    Empty#{magic => ?ERX_F2FS_MAGIC, major_ver => 1, minor_ver => 16,
           log_sectorsize => 9, log_sectors_per_block => 3,
           log_blocksize => 12, log_blocks_per_seg => 9,
           segs_per_sec => 1, secs_per_zone => 1,
           checksum_offset => ?ERX_F2FS_SUPER_BLOCK_OFF_CRC,
           block_count => 16384, section_count => 24, segment_count => 31,
           segment_count_ckpt => 2, segment_count_sit => 2,
           segment_count_nat => 2, segment_count_ssa => 1,
           segment_count_main => 24,
           segment0_blkaddr => 512, cp_blkaddr => 512, sit_blkaddr => 1536,
           nat_blkaddr => 2560, ssa_blkaddr => 3584, main_blkaddr => 4096,
           root_ino => 3, node_ino => 1, meta_ino => 2,
           uuid => binary:copy(<<16#5a>>, 16),
           volume_name => <<0:8192>>,
           extension_list => lists:duplicate(64, <<0:64>>),
           version => <<0:2048>>, init_version => <<0:2048>>,
           feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR bor
                          ?ERX_F2FS_FEATURE_INODE_CHKSUM bor
                          ?ERX_F2FS_FEATURE_SB_CHKSUM,
           encrypt_pw_salt => <<0:128>>,
           devs => lists:duplicate(8, #{path => <<0:512>>, total_segments => 0}),
           qf_ino => [0, 0, 0],
           s_stop_reason => <<0:256>>, s_errors => <<0:128>>}.

%% The superblock's block: 1024 bytes before the record, the record with its
%% checksum computed when SB_CHKSUM asks for one, and zeros after it.
superblock_block(#{feature := Feature} = Fields) ->
    Unsigned = erx_abi_packed:encode(erx_f2fs_super_block, Fields#{crc => 0}),
    Record = case Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM of
                 0 -> erx_abi_packed:encode(erx_f2fs_super_block, Fields);
                 _ -> with_crc(Unsigned, ?ERX_F2FS_SUPER_BLOCK_OFF_CRC)
             end,
    Tail = ?BLOCK - ?ERX_F2FS_SUPER_OFFSET - byte_size(Record),
    <<0:(?ERX_F2FS_SUPER_OFFSET * 8), Record/binary, 0:(Tail * 8)>>.

%% Pack 1 of the volume's first checkpoint: 64-byte SIT and NAT bitmaps (one
%% bit per block of one copy of a one-segment table) and the checksum in the
%% header's last word.
checkpoint_fields() ->
    Empty = maps:from_list([{Field, 0} || Field <- integer_fields(erx_f2fs_checkpoint)]),
    Empty#{checkpoint_ver => 1, user_block_count => 10240,
           rsvd_segment_count => 2, overprov_segment_count => 4,
           free_segment_count => 18,
           cur_node_segno => [0, 1, 2 | lists:duplicate(5, 16#ffffffff)],
           cur_node_blkoff => lists:duplicate(8, 1),
           cur_data_segno => [3, 4, 5 | lists:duplicate(5, 16#ffffffff)],
           cur_data_blkoff => lists:duplicate(8, 1),
           ckpt_flags => ?ERX_F2FS_CP_UMOUNT bor ?ERX_F2FS_CP_CRC_RECOVERY,
           cp_pack_total_block_count => 8, cp_pack_start_sum => 1,
           valid_node_count => 1, valid_inode_count => 1, next_free_nid => 4,
           sit_ver_bitmap_bytesize => 64, nat_ver_bitmap_bytesize => 64,
           checksum_offset => ?BLOCK - 4,
           alloc_type => <<0:128>>}.

%% A header block: the fixed part, then Bitmaps, the bytes the bitmaps occupy
%% in the header, then zeros, and the checksum at checksum_offset.
checkpoint_block(#{checksum_offset := At} = Fields, Bitmaps) ->
    Fixed = erx_abi_packed:encode(erx_f2fs_checkpoint, Fields),
    Body = <<Fixed/binary, Bitmaps/binary>>,
    Unsigned = <<Body/binary, 0:((?BLOCK - byte_size(Body)) * 8)>>,
    with_crc(Unsigned, At).

orphan_block(Inodes, Used) ->
    Slots = Inodes ++ lists:duplicate(?ERX_F2FS_ORPHANS_PER_BLOCK - length(Inodes), 0),
    erx_abi_packed:encode(erx_f2fs_orphan_block,
                          #{ino => Slots, blk_addr => 1, blk_count => 1,
                            entry_count => Used, check_sum => 0}).

%% Bytes with the 32-bit checksum at At replaced by the CRC of every other
%% byte, seeded with the magic ([F 13], [F 51]).
with_crc(Bytes, At) ->
    <<Before:At/binary, _:32, After/binary>> = Bytes,
    Crc = crc_reference(?ERX_F2FS_MAGIC, <<Before/binary, After/binary>>),
    <<Before/binary, Crc:32/little, After/binary>>.

%% The CRC as [F 49] defines it, one bit at a time: the reflected polynomial
%% 0xEDB88320, bytes in order, least significant bit first, from the seed and
%% with no inversion at either end.
crc_reference(Seed, Data) ->
    lists:foldl(fun(Byte, Crc) -> crc_bits(Crc bxor Byte, 8) end,
                Seed, binary_to_list(Data)).

crc_bits(Crc, 0) -> Crc;
crc_bits(Crc, Left) when Crc band 1 =:= 1 ->
    crc_bits((Crc bsr 1) bxor 16#EDB88320, Left - 1);
crc_bits(Crc, Left) -> crc_bits(Crc bsr 1, Left - 1).

%% The fields of a layout whose decoded value is an integer.
integer_fields(Layout) ->
    Size = case Layout of
               erx_f2fs_super_block -> ?ERX_F2FS_SUPER_BLOCK_SIZE;
               erx_f2fs_checkpoint -> ?ERX_F2FS_CHECKPOINT_SIZE
           end,
    Decoded = erx_abi_packed:decode(Layout, <<0:(Size * 8)>>),
    [Field || {Field, Value} <- maps:to_list(Decoded), is_integer(Value)].

superblock(Fields) -> erx_f2fs_codec:superblock(superblock_block(Fields)).

header(Fields) -> checkpoint_block(Fields, binary:copy(<<16#a5>>, 128)).

%% A header read with its payload, under a superblock whose cp_payload is the
%% payload's length.
pack(Block, Payload) ->
    Super = (superblock_fields())#{cp_payload => length(Payload)},
    erx_f2fs_codec:checkpoint(Super, Block, Payload).

%%% The CRC

crc_matches_the_definition_from_any_seed_test() ->
    Cases = [{0, <<>>}, {16#ffffffff, <<"123456789">>},
             {?ERX_F2FS_MAGIC, <<"F2FS">>},
             {16#12345678, binary:copy(<<0, 255, 16#a5>>, 1365)}],
    [?assertEqual({Seed, Data, crc_reference(Seed, Data)},
                  {Seed, Data, erx_f2fs_codec:crc(Seed, Data)})
     || {Seed, Data} <- Cases].

crc_continues_over_iodata_test() ->
    Whole = erx_f2fs_codec:crc(?ERX_F2FS_MAGIC, <<"abcdef">>),
    ?assertEqual(Whole, erx_f2fs_codec:crc(?ERX_F2FS_MAGIC, [<<"abc">>, <<"def">>])),
    Partial = erx_f2fs_codec:crc(?ERX_F2FS_MAGIC, <<"abc">>),
    ?assertEqual(Whole, erx_f2fs_codec:crc(Partial, <<"def">>)).

%%% The superblock

a_valid_superblock_reads_as_its_fields_test() ->
    Fields = superblock_fields(),
    {ok, Super} = superblock(Fields),
    ?assertEqual(Fields#{crc => maps:get(crc, Super)}, Super).

a_superblock_without_sb_chksum_is_not_checked_test() ->
    Fields = (superblock_fields())#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR,
                                    checksum_offset => 0, crc => 16#dead},
    ?assertMatch({ok, #{crc := 16#dead}}, superblock(Fields)).

a_changed_byte_under_the_checksum_fails_it_test() ->
    <<Before:1100/binary, Byte, After/binary>> = superblock_block(superblock_fields()),
    Changed = <<Before/binary, (Byte bxor 1), After/binary>>,
    ?assertEqual({error, {superblock, crc}}, erx_f2fs_codec:superblock(Changed)).

%% Each case breaks one rule of [F 54] and keeps every other.
each_superblock_rule_fails_with_its_name_test_() ->
    Valid = superblock_fields(),
    Cases =
        [{magic, #{magic => ?ERX_F2FS_MAGIC + 1}},
         {checksum_offset, #{checksum_offset => 3064}},
         {log_blocksize, #{log_blocksize => 13}},
         {log_blocks_per_seg, #{log_blocks_per_seg => 10}},
         {log_sectorsize, #{log_sectorsize => 8, log_sectors_per_block => 4}},
         {log_sectorsize, #{log_sectors_per_block => 2}},
         {segment_count, #{segment_count => 8}},
         {segment_count, #{segment_count => ?ERX_F2FS_SEGMENT_COUNT_MAX + 1}},
         {section_count, #{section_count => 0}},
         {section_count, #{section_count => 25}},
         {segs_per_sec, #{segs_per_sec => 0}},
         {segs_per_sec, #{segs_per_sec => 32}},
         {segment_count_main, #{section_count => 12}},
         {segment_count_main, #{segs_per_sec => 2, section_count => 24,
                                segment_count_main => 48}},
         {block_count, #{block_count => 31 * 512 - 1}},
         {secs_per_zone, #{secs_per_zone => 0}},
         {secs_per_zone, #{secs_per_zone => 25}},
         {cp_payload, #{cp_payload => 504}},
         {extensions, #{extension_count => 65}},
         {extensions, #{hot_ext_count => 65}},
         {extensions, #{extension_count => 40, hot_ext_count => 25}},
         {reserved_inodes, #{root_ino => 4}},
         {reserved_inodes, #{node_ino => 2}},
         {reserved_inodes, #{meta_ino => 3}},
         {devices, #{devs => [#{path => <<"/dev/a", 0:464>>,
                                total_segments => 30}
                              | lists:duplicate(7, #{path => <<0:512>>,
                                                     total_segments => 0})]}},
         {areas, #{cp_blkaddr => 1024}},
         {areas, #{sit_blkaddr => 1537}},
         {areas, #{nat_blkaddr => 2048}},
         {areas, #{ssa_blkaddr => 3072}},
         {areas, #{main_blkaddr => 4608}},
         {areas, #{segment_count_main => 25, section_count => 25}}],
    [{atom_to_list(Rule), ?_assertEqual({error, {superblock, Rule}},
                                        superblock(maps:merge(Valid, Broken)))}
     || {Rule, Broken} <- Cases].

named_devices_whose_segments_add_up_are_accepted_test() ->
    Devices = [#{path => <<"/dev/a", 0:464>>, total_segments => 20},
               #{path => <<"/dev/b", 0:464>>, total_segments => 11}
               | lists:duplicate(6, #{path => <<0:512>>, total_segments => 99})],
    ?assertMatch({ok, _}, superblock((superblock_fields())#{devs => Devices})).

a_superblock_block_of_another_size_fails_test() ->
    Block = superblock_block(superblock_fields()),
    ?assertEqual({error, {superblock, block_size}},
                 erx_f2fs_codec:superblock(binary:part(Block, 0, 4095))).

%%% The checkpoint pack

%% A header reads as its fields and the checksum it stores, which a node
%% footer of its checkpoint carries ([F 43]).
a_valid_header_reads_as_its_fields_test() ->
    Fields = checkpoint_fields(),
    Block = header(Fields),
    <<_:(?BLOCK - 4)/binary, Crc:32/little>> = Block,
    ?assertEqual({ok, Fields#{crc => Crc}}, erx_f2fs_codec:checkpoint(Block)).

the_checksum_may_sit_before_the_blocks_end_test() ->
    Fields = (checkpoint_fields())#{checksum_offset => 4000},
    Block = header(Fields),
    <<_:4000/binary, Crc:32/little, _/binary>> = Block,
    ?assertEqual({ok, Fields#{crc => Crc}}, erx_f2fs_codec:checkpoint(Block)).

a_changed_byte_after_the_checksum_fails_it_test() ->
    Block = header((checkpoint_fields())#{checksum_offset => 4000}),
    <<Before:4090/binary, Byte, After/binary>> = Block,
    ?assertEqual({error, {checkpoint, crc}},
                 erx_f2fs_codec:checkpoint(<<Before/binary, (Byte bxor 1), After/binary>>)).

each_header_rule_fails_with_its_name_test_() ->
    Valid = checkpoint_fields(),
    Cases = [{checksum_offset, #{checksum_offset => ?ERX_F2FS_CHECKPOINT_SIZE - 1}},
             {checksum_offset, #{checksum_offset => ?BLOCK - 3}},
             {pack_blocks, #{cp_pack_total_block_count => 2}},
             {pack_blocks, #{cp_pack_total_block_count => 513}}],
    [{atom_to_list(Rule), ?_assertEqual({error, {checkpoint, Rule}},
                                        erx_f2fs_codec:checkpoint(raw_header(maps:merge(Valid, Broken))))}
     || {Rule, Broken} <- Cases].

%% A header whose checksum_offset lies outside the block has nowhere to
%% carry a checksum, so its block is built without one.
raw_header(#{checksum_offset := At} = Fields) when At > ?BLOCK - 4 ->
    Fixed = erx_abi_packed:encode(erx_f2fs_checkpoint, Fields),
    <<Fixed/binary, 0:((?BLOCK - byte_size(Fixed)) * 8)>>;
raw_header(Fields) -> header(Fields).

the_header_holds_both_bitmaps_without_payload_test() ->
    Sit = binary:copy(<<16#81>>, 64),
    Nat = binary:copy(<<16#18>>, 64),
    Block = checkpoint_block(checkpoint_fields(), <<Sit/binary, Nat/binary>>),
    ?assertMatch({ok, #{sit_version_bitmap := Sit, nat_version_bitmap := Nat}},
                 pack(Block, [])).

the_payload_holds_the_sit_bitmap_test() ->
    Sit = binary:copy(<<16#81>>, 5000),
    Nat = binary:copy(<<16#18>>, 64),
    Fields = (checkpoint_fields())#{sit_ver_bitmap_bytesize => 5000},
    Block = checkpoint_block(Fields, Nat),
    <<First:4096/binary, Rest/binary>> = <<Sit/binary, 0:(3192 * 8)>>,
    ?assertMatch({ok, #{sit_version_bitmap := Sit, nat_version_bitmap := Nat}},
                 pack(Block, [First, Rest])).

%% Bitmaps one byte larger than the room before the checksum, or than the
%% payload, are refused before they are read ([F 23]).
bitmaps_past_their_room_fail_test_() ->
    Room = ?BLOCK - 4 - ?ERX_F2FS_CHECKPOINT_SIZE,
    Header = fun(Sit, Nat) ->
                     header((checkpoint_fields())#{sit_ver_bitmap_bytesize => Sit,
                                                   nat_ver_bitmap_bytesize => Nat})
             end,
    Payload = [<<0:(?BLOCK * 8)>>],
    [?_assertMatch({ok, _}, pack(Header(Room - 64, 64), [])),
     ?_assertEqual({error, {checkpoint, bitmap_room}},
                   pack(Header(Room - 63, 64), [])),
     ?_assertMatch({ok, _}, pack(Header(?BLOCK, Room), Payload)),
     ?_assertEqual({error, {checkpoint, bitmap_room}},
                   pack(Header(?BLOCK + 1, 64), Payload)),
     ?_assertEqual({error, {checkpoint, bitmap_room}},
                   pack(Header(64, Room + 1), Payload))].

a_large_nat_bitmap_pack_is_refused_test() ->
    Fields = (checkpoint_fields())#{ckpt_flags => ?ERX_F2FS_CP_LARGE_NAT_BITMAP},
    ?assertEqual({error, {checkpoint, large_nat_bitmap}},
                 pack(header(Fields), [])).

%% The payload is as many blocks as the superblock's cp_payload says, so
%% where the bitmaps lie never depends on how many blocks a caller passed.
a_payload_of_another_count_fails_test_() ->
    Block = header(checkpoint_fields()),
    Super = superblock_fields(),
    [?_assertEqual({error, {checkpoint, payload_count}},
                   erx_f2fs_codec:checkpoint(Super#{cp_payload => 1}, Block, [])),
     ?_assertEqual({error, {checkpoint, payload_count}},
                   erx_f2fs_codec:checkpoint(Super, Block, [<<0:(?BLOCK * 8)>>]))].

%% The header's copy at the pack's end needs only its checksum ([F 22]): a
%% block count out of range fails the header and not the copy.
the_copy_is_checked_for_its_checksum_alone_test() ->
    Block = header((checkpoint_fields())#{cp_pack_total_block_count => 600}),
    ?assertEqual({error, {checkpoint, pack_blocks}}, erx_f2fs_codec:checkpoint(Block)),
    ?assertMatch({ok, #{cp_pack_total_block_count := 600}},
                 erx_f2fs_codec:checkpoint_copy(Block)),
    <<Before:100/binary, Byte, After/binary>> = Block,
    ?assertEqual({error, {checkpoint, crc}},
                 erx_f2fs_codec:checkpoint_copy(<<Before/binary, (Byte bxor 1), After/binary>>)).

a_bitstring_is_no_block_test() ->
    ?assertEqual({error, {superblock, block_size}},
                 erx_f2fs_codec:superblock(<<0:32767>>)).

a_payload_block_of_another_size_fails_test() ->
    ?assertEqual({error, {checkpoint, block_size}},
                 pack(header(checkpoint_fields()), [<<0:8>>])).

%%% Orphan blocks

an_orphan_block_answers_its_used_slots_test() ->
    ?assertEqual({ok, [7, 9, 11]}, erx_f2fs_codec:orphan_block(orphan_block([7, 9, 11, 13], 3))),
    Full = lists:seq(100, 100 + ?ERX_F2FS_ORPHANS_PER_BLOCK - 1),
    ?assertEqual({ok, Full},
                 erx_f2fs_codec:orphan_block(orphan_block(Full, ?ERX_F2FS_ORPHANS_PER_BLOCK))).

an_orphan_count_past_the_block_fails_test() ->
    ?assertEqual({error, {orphan_block, entry_count}},
                 erx_f2fs_codec:orphan_block(orphan_block([], ?ERX_F2FS_ORPHANS_PER_BLOCK + 1))).

%%% Fixtures of the tables, summaries, inodes and dentries

nat_entry(Version, Ino, Address) ->
    #{version => Version, ino => Ino, block_addr => Address}.

%% A NAT block whose first entries are Entries and the rest free.
nat_block(Entries) ->
    Free = nat_entry(0, 0, 0),
    erx_abi_packed:encode(erx_f2fs_nat_block,
                          #{entries => pad(Entries, ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK, Free)}).

%% A NAT journal claiming Count entries, its slots Entries ({Nid, Entry})
%% and zeros.
nat_journal(Count, Entries) ->
    Slots = [#{nid => Nid, entry => Entry} || {Nid, Entry} <- Entries],
    Empty = #{nid => 0, entry => nat_entry(0, 0, 0)},
    erx_abi_packed:encode(erx_f2fs_nat_journal,
                          #{n_nats => Count,
                            entries => pad(Slots, ?ERX_F2FS_NAT_JOURNAL_ENTRIES, Empty)}).

%% A SIT entry of log Type whose valid blocks are Valid, a list of block
%% offsets, their bits set first-bit-most-significant ([F 5], [F 37]).
sit_entry(Type, Valid) ->
    Map = << <<(case lists:member(Bit, Valid) of true -> 1; false -> 0 end):1>>
             || Bit <- lists:seq(0, 511) >>,
    #{vblocks => (Type bsl 10) bor length(Valid), valid_map => Map, mtime => 77}.

sit_block(Entries) ->
    erx_abi_packed:encode(erx_f2fs_sit_block,
                          #{entries => pad(Entries, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK,
                                           sit_entry(0, []))}).

sit_journal(Count, Entries) ->
    Slots = [#{segno => Segno, entry => Entry} || {Segno, Entry} <- Entries],
    erx_abi_packed:encode(erx_f2fs_sit_journal,
                          #{n_sits => Count,
                            entries => pad(Slots, ?ERX_F2FS_SIT_JOURNAL_ENTRIES,
                                           #{segno => 0, entry => sit_entry(0, [])})}).

%% A summary block of a data segment whose entry for block k is nid 100 + k,
%% version k mod 256 and offset k, with Journal.
summary_block(Journal) ->
    Entries = [#{nid => 100 + K, version => K rem 256, ofs_in_node => K}
               || K <- lists:seq(0, 511)],
    erx_abi_packed:encode(erx_f2fs_summary_block,
                          #{entries => Entries, journal => Journal,
                            entry_type => 0, check_sum => 16#dead}).

%% The compact form's blocks for the data logs' Summaries, laid out by
%% [F 29]'s numbers: the journals at bytes 0 and 507 of the first block,
%% its 439 entries from byte 1014, then 584 entries from byte 0 of each
%% further block, the last 5 bytes and more of each block unused.
compact_blocks(Nat, Sit, Summaries) ->
    Packed = [<<Nid:32/little, Version:8, Offset:16/little>>
              || #{nid := Nid, version := Version, ofs_in_node := Offset}
                     <- lists:append(Summaries)],
    {Head, Tail} = lists:split(min(439, length(Packed)), Packed),
    First = iolist_to_binary([Nat, Sit | Head]),
    [pad_block(First) | [pad_block(iolist_to_binary(Chunk)) || Chunk <- chunks(Tail, 584)]].

chunks([], _Size) -> [];
chunks(List, Size) when length(List) =< Size -> [List];
chunks(List, Size) ->
    {Chunk, Rest} = lists:split(Size, List),
    [Chunk | chunks(Rest, Size)].

pad_block(Bytes) -> <<Bytes/binary, 0:((?BLOCK - byte_size(Bytes)) * 8)>>.

pad(List, Count, Filler) -> List ++ lists:duplicate(Count - length(List), Filler).

%% Inode 4 of superblock_fields()'s volume: a regular file of two blocks,
%% with EXTRA_ATTR and i_extra_isize 12, so its addresses start at word 3
%% of i_addr ([F 41]), named "file" in directory 3.
inode_fields() ->
    Zero = erx_abi_packed:decode(erx_f2fs_inode, <<0:(?ERX_F2FS_INODE_SIZE * 8)>>),
    Inode = Zero#{i_mode => 8#100644, i_inline => ?ERX_F2FS_EXTRA_ATTR,
                  i_links => 1, i_size => 8192, i_blocks => 3,
                  i_generation => 16#01020304, i_pino => 3,
                  i_namelen => 4, i_name => <<"file", 0:(251 * 8)>>},
    Addresses = [5000, 5001 | lists:duplicate(?ERX_F2FS_ADDRS_PER_INODE - 5, 0)],
    #{inode => Inode, i_addr => extra_words(12, 0) ++ Addresses,
      i_nid => [0, 0, 0, 0, 0],
      footer => #{nid => 4, ino => 4, flag => 0, cp_ver => 1, next_blkaddr => 0}}.

%% The first words of i_addr for i_extra_isize Size and an inline xattr
%% size, the rest of the extra attributes zero ([F 41]).
extra_words(Size, XattrWords) ->
    [Size bor (XattrWords bsl 16) | lists:duplicate(Size div 4 - 1, 0)].

%% An inode block of Super's volume, its checksum computed when [F 50]
%% asks for one.
inode_block(Super, Fields) ->
    Block = erx_abi_packed:encode(erx_f2fs_inode_block, Fields),
    case inode_checksum_applies(Super, Fields) of
        true -> with_inode_checksum(Super, Block);
        false -> Block
    end.

inode_checksum_applies(#{feature := Feature},
                       #{inode := #{i_inline := Inline}, i_addr := [Word0 | _]}) ->
    Feature band ?ERX_F2FS_FEATURE_INODE_CHKSUM =/= 0 andalso
        Inline band ?ERX_F2FS_EXTRA_ATTR =/= 0 andalso
        Word0 band 16#ffff >= 12.

%% [F 50]: the CRC of the UUID from all ones, continued over the footer's
%% ino, i_generation, bytes 0 to 367, four zeros and bytes 372 to 4095,
%% stored at byte 368.
with_inode_checksum(#{uuid := Uuid}, Block) ->
    <<Before:368/binary, _:32, After/binary>> = Block,
    <<_:4076/binary, Ino:4/binary, _/binary>> = Block,
    <<_:68/binary, Generation:4/binary, _/binary>> = Block,
    Seed = crc_reference(16#ffffffff, Uuid),
    Crc = crc_reference(Seed, <<Ino/binary, Generation/binary, Before/binary, 0:32,
                                After/binary>>),
    <<Before/binary, Crc:32/little, After/binary>>.

%% A dentry block holding Dentries, {Slot, Name, Ino}, laid out by [F 59]'s
%% offsets: the bitmap, first bit least significant, at byte 0, slot
%% records of 11 bytes from byte 30 and name slots of 8 bytes from byte
%% 2384. A name's run sets every bit and zeroes the later records'
%% name_len ([F 60]). A dentry may carry its stored hash as a fourth
%% element; without one, the hash is 0x1000 plus the slot.
dentry_block(Dentries) ->
    dentry_area(?BLOCK, {27, 30, 2384}, Dentries).

dentry_area(Size, {BitmapBytes, RecordsAt, NamesAt}, Dentries) ->
    Runs = [{Slot, (byte_size(Name) + 7) div 8, Name, Ino, Hash}
            || Dentry <- Dentries,
               {Slot, Name, Ino, Hash} <- [case Dentry of
                                               {S, N, I} -> {S, N, I, 16#1000 + S};
                                               {_, _, _, _} -> Dentry
                                           end]],
    Used = lists:append([lists:seq(Slot, Slot + Run - 1) || {Slot, Run, _, _, _} <- Runs]),
    Bitmap = << <<(lists:sum([1 bsl Bit || Bit <- lists:seq(0, 7),
                                           lists:member(Byte * 8 + Bit, Used)]))>>
               || Byte <- lists:seq(0, BitmapBytes - 1) >>,
    Writes = [{0, Bitmap}]
        ++ [{RecordsAt + 11 * Slot,
             <<Hash:32/little, Ino:32/little, (byte_size(Name)):16/little, 1>>}
            || {Slot, _, Name, Ino, Hash} <- Runs]
        ++ [{NamesAt + 8 * Slot, Name} || {Slot, _, Name, _, _} <- Runs],
    lists:foldl(fun({At, Bytes}, Area) ->
                        <<Before:At/binary, _:(byte_size(Bytes))/binary, After/binary>> = Area,
                        <<Before/binary, Bytes/binary, After/binary>>
                end, <<0:(Size * 8)>>, Writes).

inode(Fields) ->
    Super = superblock_fields(),
    erx_f2fs_codec:inode(Super, 4, inode_block(Super, Fields)).

%% Fields with the inode's fixed part changed by Changes.
with_inode(#{inode := Inode} = Fields, Changes) ->
    Fields#{inode := maps:merge(Inode, Changes)}.

%%% The NAT and the SIT

a_nat_block_answers_its_entries_test() ->
    Entries = [nat_entry(1, 3, 4096), nat_entry(255, 9, 4100)],
    {ok, Read} = erx_f2fs_codec:nat_block(nat_block(Entries)),
    ?assertEqual(?ERX_F2FS_NAT_ENTRIES_PER_BLOCK, length(Read)),
    ?assertEqual(Entries, lists:sublist(Read, 2)),
    ?assertEqual({error, {nat_block, block_size}},
                 erx_f2fs_codec:nat_block(binary:part(nat_block([]), 0, 4095))).

a_nat_journal_answers_its_counted_entries_test() ->
    Entries = [{N, nat_entry(N, N, 4096 + N)} || N <- lists:seq(3, 40)],
    Full = [#{nid => Nid, entry => Entry} || {Nid, Entry} <- Entries],
    ?assertEqual({ok, Full}, erx_f2fs_codec:nat_journal(nat_journal(38, Entries))),
    ?assertEqual({ok, lists:sublist(Full, 2)},
                 erx_f2fs_codec:nat_journal(nat_journal(2, Entries))),
    ?assertEqual({ok, []}, erx_f2fs_codec:nat_journal(nat_journal(0, []))).

%% [F 32]: more than 38 entries refuses the journal, and the journal is its
%% 507 bytes.
a_nat_journal_past_its_room_fails_test() ->
    ?assertEqual({error, {nat_journal, entry_count}},
                 erx_f2fs_codec:nat_journal(nat_journal(39, []))),
    ?assertEqual({error, {nat_journal, journal_size}},
                 erx_f2fs_codec:nat_journal(<<0:4096>>)).

a_sit_block_answers_its_main_segments_test() ->
    Entries = [sit_entry(3, [0, 1, 2]), sit_entry(0, lists:seq(0, 511)), sit_entry(5, [])],
    {ok, Read} = erx_f2fs_codec:sit_block(sit_block(Entries), 3),
    ?assertMatch([#{valid_blocks := 3, type := 3, mtime := 77},
                  #{valid_blocks := 512, type := 0},
                  #{valid_blocks := 0, type := 5}], Read),
    ?assertEqual([Map || #{valid_map := Map} <- Entries],
                 [Map || #{valid_map := Map} <- Read]).

%% Entries past the main area's segments are not read ([F 39]), and no
%% block holds more than 55.
a_sit_block_reads_only_the_entries_asked_for_test_() ->
    Broken = (sit_entry(0, [1]))#{vblocks => 2},
    Block = sit_block([sit_entry(0, [1]), Broken]),
    [?_assertMatch({ok, [_]}, erx_f2fs_codec:sit_block(Block, 1)),
     ?_assertEqual({error, {sit_block, valid_map}}, erx_f2fs_codec:sit_block(Block, 2)),
     ?_assertEqual({error, {sit_block, entry_count}},
                   erx_f2fs_codec:sit_block(Block, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK + 1))].

%% Each rule of [F 39] on one entry.
each_sit_entry_rule_fails_with_its_name_test_() ->
    Valid = sit_entry(2, [7, 8]),
    Cases = [{valid_map, Valid#{vblocks => (2 bsl 10) bor 3}},
             {valid_map, Valid#{vblocks => 2 bsl 10}},
             {valid_blocks, Valid#{vblocks => (2 bsl 10) bor 513}},
             {type, Valid#{vblocks => (6 bsl 10) bor 2}}],
    lists:append(
      [[{atom_to_list(Rule) ++ " in a block",
         ?_assertEqual({error, {sit_block, Rule}},
                       erx_f2fs_codec:sit_block(sit_block([Entry]), 1))},
        {atom_to_list(Rule) ++ " in a journal",
         ?_assertEqual({error, {sit_journal, Rule}},
                       erx_f2fs_codec:sit_journal(sit_journal(1, [{9, Entry}])))}]
       || {Rule, Entry} <- Cases]).

a_sit_journal_answers_its_counted_entries_test() ->
    Entries = [{S, sit_entry(S rem 6, [S])} || S <- lists:seq(10, 15)],
    {ok, Read} = erx_f2fs_codec:sit_journal(sit_journal(6, Entries)),
    ?assertEqual([10, 11, 12, 13, 14, 15], [Segno || #{segno := Segno} <- Read]),
    ?assertMatch([#{entry := #{valid_blocks := 1, type := 4}} | _], Read),
    ?assertEqual({error, {sit_journal, entry_count}},
                 erx_f2fs_codec:sit_journal(sit_journal(7, Entries))),
    ?assertEqual({error, {sit_journal, journal_size}},
                 erx_f2fs_codec:sit_journal(<<0:4048>>)).

%%% Segment summaries

a_summary_block_answers_its_entries_and_journal_test() ->
    Journal = nat_journal(1, [{3, nat_entry(0, 3, 4096)}]),
    {ok, Read} = erx_f2fs_codec:summary_block(summary_block(Journal)),
    ?assertEqual([entries, entry_type, journal], lists:sort(maps:keys(Read))),
    #{entries := Entries, journal := Journal, entry_type := 0} = Read,
    ?assertEqual(512, length(Entries)),
    ?assertEqual(#{nid => 611, version => 255, ofs_in_node => 511}, lists:last(Entries)),
    ?assertEqual({error, {summary_block, block_size}},
                 erx_f2fs_codec:summary_block(<<0:8>>)).

%% Summaries for logs of 439, 512 and 512 entries take three blocks: the
%% first log fills the first block exactly ([F 29]).
compact_summaries_run_on_through_their_blocks_test() ->
    Nat = nat_journal(1, [{5, nat_entry(0, 5, 4200)}]),
    Sit = sit_journal(0, []),
    Logs = [[#{nid => Log * 10000 + K, version => K rem 256, ofs_in_node => K}
             || K <- lists:seq(1, Count)]
            || {Log, Count} <- [{1, 439}, {2, 512}, {3, 512}]],
    Blocks = compact_blocks(Nat, Sit, Logs),
    ?assertEqual(3, length(Blocks)),
    ?assertEqual({ok, #{nat_journal => Nat, sit_journal => Sit, summaries => Logs}},
                 erx_f2fs_codec:compact_summaries([439, 512, 512], Blocks)),
    ?assertEqual({ok, #{nat_journal => Nat, sit_journal => Sit, summaries => [[], [], []]}},
                 erx_f2fs_codec:compact_summaries([0, 0, 0], [hd(Blocks)])).

compact_summaries_past_their_room_fail_test_() ->
    Blocks = compact_blocks(nat_journal(0, []), sit_journal(0, []), [[]]),
    [?_assertEqual({error, {compact_summary, room}},
                   erx_f2fs_codec:compact_summaries([440], Blocks)),
     ?_assertEqual({error, {compact_summary, room}},
                   erx_f2fs_codec:compact_summaries([0], [])),
     ?_assertEqual({error, {compact_summary, entry_count}},
                   erx_f2fs_codec:compact_summaries([513], Blocks ++ Blocks)),
     ?_assertEqual({error, {compact_summary, block_size}},
                   erx_f2fs_codec:compact_summaries([1], [<<0:8>>]))].

%%% Inodes

a_valid_inode_reads_as_its_fields_test() ->
    #{inode := Fixed} = Fields = inode_fields(),
    {ok, Inode} = inode(Fields),
    ?assertMatch(#{i_name := <<"file">>, i_size := 8192, i_extra_isize := 12,
                   inline_xattr := <<>>, i_projid := 0, i_crtime := 0,
                   i_nid := [0, 0, 0, 0, 0], footer := #{nid := 4, ino := 4}}, Inode),
    Extra = maps:keys(erx_abi_packed:decode(erx_f2fs_inode_extra,
                                            <<0:(?ERX_F2FS_INODE_EXTRA_SIZE * 8)>>)),
    ?assertEqual(lists:sort(maps:keys(Fixed) ++ Extra ++ [addresses, footer, i_nid, inline_xattr]),
                 lists:sort(maps:keys(Inode))),
    #{addresses := Addresses} = Inode,
    ?assertEqual(?ERX_F2FS_ADDRS_PER_INODE - 3, length(Addresses)),
    ?assertEqual([5000, 5001, 0], lists:sublist(Addresses, 3)).

a_changed_byte_under_the_inode_checksum_fails_it_test_() ->
    Super = superblock_fields(),
    Block = inode_block(Super, inode_fields()),
    Flip = fun(At) ->
                   <<Before:At/binary, Byte, After/binary>> = Block,
                   erx_f2fs_codec:inode(Super, 4, <<Before/binary, (Byte bxor 1), After/binary>>)
           end,
    %% A byte of the fixed part, of the addresses and of the footer's cp_ver.
    [?_assertEqual({error, {inode, checksum}}, Flip(At)) || At <- [33, 2000, 4090]].

%% Without INODE_CHKSUM, or with i_extra_isize short of the field, no
%% checksum is read ([F 50]).
an_inode_without_a_checksum_is_not_checked_test_() ->
    Fields = inode_fields(),
    Short = Fields#{i_addr := extra_words(8, 0) ++ [5000 | lists:duplicate(920, 0)]},
    NoChecksum = (superblock_fields())#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR},
    [?_assertMatch({ok, #{i_extra_isize := 8}}, inode(Short)),
     ?_assertMatch({ok, _}, erx_f2fs_codec:inode(NoChecksum, 4,
                                                 erx_abi_packed:encode(erx_f2fs_inode_block,
                                                                       Fields)))].

%% Each rule of [F 41] and [F 42] that concerns one inode block.
each_inode_rule_fails_with_its_name_test_() ->
    Valid = inode_fields(),
    InlineFile = inline_file(),
    Super = superblock_fields(),
    Read = fun(SuperFields, Nid, Fields) ->
                   erx_f2fs_codec:inode(SuperFields, Nid, inode_block(SuperFields, Fields))
           end,
    Extra = fun(Words) -> Valid#{i_addr := Words ++ lists:duplicate(923 - length(Words), 0)} end,
    Flexible = Super#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR bor
                                 ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR},
    Cases =
        [{nid, Read(Super, 2, Valid#{footer := #{nid => 2, ino => 2, flag => 0,
                                                 cp_ver => 1, next_blkaddr => 0}})},
         {nid, Read(Super, 455 * 512, Valid)},
         {footer, Read(Super, 5, Valid)},
         {footer, Read(Super, 4, Valid#{footer := #{nid => 4, ino => 3, flag => 0,
                                                    cp_ver => 1, next_blkaddr => 0}})},
         %% An xattr node's offset in an inode's footer ([F 43], [F 53]).
         {footer, Read(Super, 4, Valid#{footer := #{nid => 4, ino => 4,
                                                    flag => 16#1fffffff bsl 3,
                                                    cp_ver => 1, next_blkaddr => 0}})},
         {extra_attr, Read(Super, 4, with_inode(Valid, #{i_inline => 0}))},
         {extra_attr, Read(Super#{feature => ?ERX_F2FS_FEATURE_SB_CHKSUM}, 4, Valid)},
         {extra_isize, Read(Super, 4, Extra([13, 0, 0]))},
         {extra_isize, Read(Super, 4, Extra([2]))},
         {extra_isize, Read(Super, 4, Extra([40 | lists:duplicate(9, 0)]))},
         {extra_isize, Read(Super, 4, Extra([14, 0, 0, 0]))},
         {inline_xattr_size, Read(Flexible, 4, Extra(extra_words(4, 904)))},
         {inline_xattr_size,
          Read(Flexible, 4, with_inode(Extra(extra_words(4, 5)),
                                       #{i_inline => ?ERX_F2FS_EXTRA_ATTR bor
                                                         ?ERX_F2FS_INLINE_XATTR}))},
         {blocks, Read(Super, 4, with_inode(Valid, #{i_blocks => 0}))},
         {xattr_nid, Read(Super, 4, with_inode(Valid, #{i_xattr_nid => 4}))},
         {xattr_nid, Read(Super, 4, with_inode(Valid, #{i_xattr_nid => 1}))},
         {casefold, Read(Super, 4, with_inode(Valid, #{i_flags => ?ERX_F2FS_CASEFOLD_FL}))},
         {device_alias,
          Read(Super, 4, with_inode(Valid, #{i_flags => ?ERX_F2FS_DEVICE_ALIAS_FL}))},
         {device_alias,
          Read(Super#{feature => maps:get(feature, Super) bor
                                     ?ERX_F2FS_FEATURE_DEVICE_ALIAS}, 4,
               with_inode(Valid, #{i_flags => ?ERX_F2FS_DEVICE_ALIAS_FL}))},
         {namelen, Read(Super, 4, with_inode(Valid, #{i_namelen => 256}))},
         {inline_data,
          Read(Super, 4, with_inode(InlineFile, #{i_size => 4 * (923 - 3 - 1) + 1}))}]
        ++ file_type_cases(fun(Fields) -> Read(Super, 4, Fields) end, Valid, InlineFile),
    [{atom_to_list(Rule), ?_assertEqual({error, {inode, Rule}}, Result)}
     || {Rule, Result} <- Cases].

%% The rules of [F 66] to [F 70] that turn on i_mode's file type, each
%% broken by an inode Read reads, from the fixture regular file Valid and
%% the same file with one block of inline data, InlineFile.
file_type_cases(Read, Valid, InlineFile) ->
    Inline = fun(Changes) -> Read(with_inode(InlineFile, Changes)) end,
    InlineDentry = ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_DENTRY,
    [{mode, Read(with_inode(Valid, #{i_mode => 8#170644}))},
     {mode, Read(with_inode(Valid, #{i_mode => 8#644}))},
     {mode, Read(with_inode(Valid, #{i_mode => 8#30644}))},
     {links, Read(with_inode(Valid, #{i_mode => 8#40755, i_links => 1}))},
     {inline_dentry, Read(with_inode(Valid, #{i_inline => InlineDentry}))},
     {inline_dentry, Read(with_inode(Valid, #{i_mode => 8#120777, i_inline => InlineDentry}))},
     {inline_data_type, Inline(#{i_mode => 8#40755, i_links => 2})},
     {inline_data_type, Inline(#{i_mode => 8#20644})},
     {inline_data_type, Inline(#{i_mode => 8#10644})},
     {inline_data_type, Inline(#{i_mode => 8#140644})},
     %% Both inline flags: a directory has no inline data, a file no dentries.
     {inline_data_type,
      Inline(#{i_mode => 8#40755, i_links => 2,
               i_inline => ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_DATA bor
                               ?ERX_F2FS_INLINE_DENTRY})},
     {inline_dentry,
      Inline(#{i_inline => ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_DATA bor
                               ?ERX_F2FS_INLINE_DENTRY})},
     {inline_data_blocks, Inline(#{i_blocks => 2})},
     {inline_data_blocks, Inline(#{i_blocks => 3, i_xattr_nid => 9})},
     {inline_data_blocks, Read((with_inode(InlineFile, #{}))#{i_nid := [0, 0, 0, 0, 7]})},
     {inline_data_transformed, Inline(#{i_advise => ?ERX_F2FS_ADVISE_ENCRYPT})},
     {inline_data_transformed, Inline(#{i_advise => ?ERX_F2FS_ADVISE_VERITY})},
     {inline_data_transformed, Inline(#{i_flags => ?ERX_F2FS_COMPR_FL})}].

%% A directory's i_current_depth above 63 reads as 63, as Linux clamps it
%% ([F 42], [F 58]), so no lookup walks more levels; a regular file keeps
%% i_gc_failures in that word, which reads as it is.
a_directory_depth_past_63_reads_as_63_test_() ->
    Super = superblock_fields(),
    Depth = fun(Changes) ->
                    {ok, #{i_current_depth := Got}} =
                        erx_f2fs_codec:inode(Super, 4, inode_block(Super, with_inode(inode_fields(), Changes))),
                    Got
            end,
    Directory = #{i_mode => 8#40755, i_links => 2},
    [?_assertEqual(Want, Depth(Directory#{i_current_depth => Stored}))
     || {Stored, Want} <- [{1, 1}, {63, 63}, {64, 63}, {16#ffffffff, 63}]]
        ++ [?_assertEqual(16#ffffffff, Depth(#{i_current_depth => 16#ffffffff}))].

%% What the file type rules allow: every one of the seven types, a
%% directory of two links, inline data on a symlink, with an xattr node's
%% block counted, and on an encrypted symlink ([F 70]).
the_file_types_pass_their_rules_test_() ->
    Super = superblock_fields(),
    Read = fun(Fields) -> erx_f2fs_codec:inode(Super, 4, inode_block(Super, Fields)) end,
    Valid = inode_fields(),
    InlineFile = inline_file(),
    [?_assertMatch({ok, _}, Read(with_inode(Valid, #{i_mode => Type bor 8#644, i_links => 2})))
     || Type <- [8#10000, 8#20000, 8#40000, 8#60000, 8#100000, 8#120000, 8#140000]]
        ++ [?_assertMatch({ok, _}, Read(with_inode(Valid, #{i_mode => 8#40755, i_links => 0}))),
            %% Without inline data a regular file may be verity or compressed.
            ?_assertMatch({ok, _}, Read(with_inode(Valid, #{i_advise => ?ERX_F2FS_ADVISE_VERITY,
                                                            i_flags => ?ERX_F2FS_COMPR_FL}))),
            ?_assertMatch({ok, #{inline_data := <<"ab">>}},
                          Read(with_inode(InlineFile, #{i_mode => 8#120777}))),
            ?_assertMatch({ok, #{inline_data := <<"ab">>}},
                          Read(with_inode(InlineFile, #{i_blocks => 2, i_xattr_nid => 9}))),
            ?_assertMatch({ok, #{inline_data := <<"ab">>}},
                          Read(with_inode(InlineFile, #{i_mode => 8#120777,
                                                        i_advise => ?ERX_F2FS_ADVISE_ENCRYPT})))].

%% The fixture regular file with two bytes of inline data and only its
%% inode block counted.
inline_file() ->
    inline_inode(<<"ab", 0:16>>, #{i_inline => ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_DATA,
                                   i_size => 2, i_blocks => 1}, 3).

the_flags_pass_with_their_features_test_() ->
    Valid = inode_fields(),
    Super = superblock_fields(),
    Features = maps:get(feature, Super),
    Read = fun(SuperFields, Fields) ->
                   erx_f2fs_codec:inode(SuperFields, 4, inode_block(SuperFields, Fields))
           end,
    [?_assertMatch({ok, _},
                   Read(Super#{feature => Features bor ?ERX_F2FS_FEATURE_CASEFOLD},
                        with_inode(Valid, #{i_flags => ?ERX_F2FS_CASEFOLD_FL}))),
     ?_assertMatch({ok, _},
                   Read(Super#{feature => Features bor ?ERX_F2FS_FEATURE_DEVICE_ALIAS},
                        with_inode(Valid, #{i_flags => ?ERX_F2FS_DEVICE_ALIAS_FL,
                                            i_inline => ?ERX_F2FS_EXTRA_ATTR bor
                                                            ?ERX_F2FS_PIN_FILE}))),
     ?_assertMatch({ok, _}, Read(Super, with_inode(Valid, #{i_xattr_nid => 9})))].

%% Every row of [F 48]'s table of worked values: E and X give where the
%% inline content starts and its size, and the inline dentry area's slots,
%% bitmap and reserved bytes. Each row reads an inode whose content fills
%% its inline area, as file bytes and as dentries with a name in the last
%% slot.
the_inode_layout_follows_every_row_of_the_table_test_() ->
    Rows = [{0, 50, 364, 3488, 182, 23, 7},
            {0, 0, 364, 3688, 192, 24, 16},
            {1, 50, 368, 3484, 182, 23, 3},
            {3, 50, 376, 3476, 181, 23, 14},
            {6, 50, 388, 3464, 181, 23, 2},
            {9, 50, 400, 3452, 180, 23, 9}],
    lists:append([layout_cases(Row) || Row <- Rows]).

layout_cases({E, X, Start, Size, Slots, BitmapBytes, Reserved} = Row) ->
    Super = layout_super(E),
    Xattr = case X of 50 -> ?ERX_F2FS_INLINE_XATTR; 0 -> 0 end,
    Extra = case E of 0 -> 0; _ -> ?ERX_F2FS_EXTRA_ATTR end,
    Data = << <<(N rem 251)>> || N <- lists:seq(1, Size) >>,
    DataInode = inline_inode(Data,
                             #{i_inline => Extra bor Xattr bor ?ERX_F2FS_INLINE_DATA bor
                                               ?ERX_F2FS_DATA_EXIST,
                               i_size => Size, i_blocks => 1}, E),
    DataBlock = inode_block(Super, DataInode),
    Name = <<"last">>,
    Last = Slots - 1,
    Area = dentry_area(Size, {BitmapBytes, BitmapBytes + Reserved,
                              BitmapBytes + Reserved + 11 * Slots},
                       [{Last, Name, 77}]),
    DentryInode = inline_inode(Area,
                               #{i_mode => 8#40755, i_links => 2, i_size => Size,
                                 i_inline => Extra bor ?ERX_F2FS_INLINE_DENTRY}, E),
    Read = fun(Fields) -> erx_f2fs_codec:inode(Super, 4, inode_block(Super, Fields)) end,
    %% The fixture puts the content where the table's start says.
    [{lists:flatten(io_lib:format("~p start", [Row])),
      ?_assertMatch(<<_:Start/binary, Data:Size/binary, _/binary>>, DataBlock)},
     {lists:flatten(io_lib:format("~p data", [Row])),
      ?_assertMatch({ok, #{inline_data := Data, inline_xattr := <<_:(4 * X)/binary>>}},
                    Read(DataInode))}]
        ++ [{lists:flatten(io_lib:format("~p dentries", [Row])),
             ?_assertMatch({ok, #{entries := [#{slot := Last, name := Name, ino := 77}],
                                  bitmap := <<0:Last, 1:1>>}},
                           begin
                               {ok, DentryRead} = Read(DentryInode),
                               erx_f2fs_codec:inline_dentries(DentryRead)
                           end)}
            || X =:= 50].

%% A volume whose features give an inode E extra words: none for E = 0,
%% EXTRA_ATTR alone for E = 1, and INODE_CHKSUM too beyond.
layout_super(0) -> (superblock_fields())#{feature => 0};
layout_super(1) -> (superblock_fields())#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR};
layout_super(_) -> superblock_fields().

%% An inode whose inline content is Content, after E extra words and the
%% reserved word.
inline_inode(Content, Changes, E) ->
    Fields = with_inode(inode_fields(), Changes),
    Before = case E of 0 -> []; _ -> extra_words(4 * E, 0) end,
    Words = [Word || <<Word:32/little>> <= Content],
    Fields#{i_addr := pad(Before ++ [0 | Words], ?ERX_F2FS_ADDRS_PER_INODE, 0)}.

%% With FLEXIBLE_INLINE_XATTR the inline xattr area is i_inline_xattr_size
%% words, even without INLINE_XATTR, and the address array shrinks by it.
a_flexible_inline_xattr_size_moves_the_inline_area_test() ->
    Super = (superblock_fields())#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR bor
                                              ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR},
    Fields = (inode_fields())#{i_addr := pad(extra_words(4, 10) ++ [0, 16#64636261],
                                             ?ERX_F2FS_ADDRS_PER_INODE, 0)},
    Data = with_inode(Fields, #{i_inline => ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_DATA,
                                i_size => 4 * (923 - 1 - 10 - 1), i_blocks => 1}),
    {ok, #{inline_data := Bytes, inline_xattr := <<_:40/binary>>}} =
        erx_f2fs_codec:inode(Super, 4, inode_block(Super, Data)),
    ?assertMatch(<<"abcd", 0:(4 * (923 - 1 - 10 - 2) * 8)>>, Bytes),
    ?assertMatch({ok, #{addresses := Addresses}} when length(Addresses) =:= 923 - 1 - 10,
                 erx_f2fs_codec:inode(Super, 4, inode_block(Super, Fields))).

%%% Dentries

a_dentry_block_answers_its_used_slots_test() ->
    Long = binary:copy(<<"n">>, 255),
    Block = dentry_block([{0, <<".">>, 3}, {1, <<"..">>, 3}, {2, <<"eightchr">>, 10},
                          {3, <<"ninechars">>, 11}, {181, Long, 12}]),
    {ok, #{bitmap := Bitmap, entries := Entries}} = erx_f2fs_codec:dentry_block(Block),
    ?assertEqual(214, bit_size(Bitmap)),
    ?assertMatch(<<2#11111:5, 0:176, 16#ffffffff:32, 0:1>>, Bitmap),
    ?assertEqual([{0, <<".">>, 3}, {1, <<"..">>, 3}, {2, <<"eightchr">>, 10},
                  {3, <<"ninechars">>, 11}, {181, Long, 12}],
                 [{Slot, Name, Ino} || #{slot := Slot, name := Name, ino := Ino} <- Entries]),
    ?assertMatch([#{hash_code := 16#1000, file_type := 1} | _], Entries).

%% A set bit whose record has name_len 0 is one unused slot ([F 60]).
a_used_slot_without_a_name_is_passed_test() ->
    Block = dentry_block([{0, <<"a">>, 5}]),
    <<Bitmap, Rest/binary>> = Block,
    {ok, #{entries := Entries}} =
        erx_f2fs_codec:dentry_block(<<(Bitmap bor 2#110), Rest/binary>>),
    ?assertEqual([0], [Slot || #{slot := Slot} <- Entries]).

each_dentry_rule_fails_with_its_name_test_() ->
    LongRecord = fun(Slot, Length) ->
                         Block = dentry_block([{Slot, <<"x">>, 5}]),
                         At = 30 + 11 * Slot + 8,
                         <<Before:At/binary, _:16, After/binary>> = Block,
                         <<Before/binary, Length:16/little, After/binary>>
                 end,
    [?_assertEqual({error, {dentry_block, name_len}},
                   erx_f2fs_codec:dentry_block(LongRecord(0, 256))),
     ?_assertEqual({error, {dentry_block, name_run}},
                   erx_f2fs_codec:dentry_block(LongRecord(213, 9))),
     ?_assertEqual({error, {dentry_block, name_run}},
                   erx_f2fs_codec:dentry_block(LongRecord(190, 255))),
     ?_assertMatch({ok, #{entries := [#{slot := 213, name := <<"x">>}]}},
                   erx_f2fs_codec:dentry_block(dentry_block([{213, <<"x">>, 5}]))),
     ?_assertEqual({error, {dentry_block, block_size}},
                   erx_f2fs_codec:dentry_block(<<0:8>>))]
        ++ [?_assertEqual({error, {dentry_block, name}},
                          erx_f2fs_codec:dentry_block(dentry_block([{3, Name, 5}])))
            || Name <- [<<"a/b">>, <<"/">>, <<"a", 0, "b">>, <<0>>, <<"abcdefgh/">>]].

%% "." and ".." hash to 0 ([F 57]); every other name's hash is checked by
%% erx_f2fs_core_tests' corpus test against the hashes Linux stored.
the_dots_hash_to_zero_test() ->
    ?assertEqual({0, 0}, {erx_f2fs_codec:dentry_hash(<<".">>), erx_f2fs_codec:dentry_hash(<<"..">>)}).

%% A long name past the inline area's last slot fails the inline dentries,
%% not the inode.
an_inline_dentry_past_its_last_slot_fails_the_dentries_test() ->
    Super = superblock_fields(),
    Area = dentry_area(3476, {23, 37, 37 + 11 * 181}, [{180, <<"x">>, 5}]),
    At = 37 + 11 * 180 + 8,
    <<Before:At/binary, _:16, After/binary>> = Area,
    Broken = <<Before/binary, 9:16/little, After/binary>>,
    Fields = inline_inode(Broken, #{i_mode => 8#40755, i_links => 2, i_size => 3476,
                                    i_inline => ?ERX_F2FS_EXTRA_ATTR bor
                                                    ?ERX_F2FS_INLINE_DENTRY}, 3),
    {ok, Inode} = erx_f2fs_codec:inode(Super, 4, inode_block(Super, Fields)),
    ?assertEqual({error, {inline_dentries, name_run}}, erx_f2fs_codec:inline_dentries(Inode)).

%%% Encoders: each fixture, built by hand to [F n]'s offsets, decodes and
%%% encodes back to its own bytes

a_superblock_encodes_to_its_block_test_() ->
    [?_assertEqual(Block, begin {ok, Super} = erx_f2fs_codec:superblock(Block),
                                erx_f2fs_codec:encode_superblock(Super) end)
     || Fields <- [superblock_fields(), (superblock_fields())#{feature => 0, crc => 16#1234}],
        Block <- [superblock_block(Fields)]].

%% Both placements of the version bitmaps ([F 23]): in the header, and the
%% SIT bitmap in two payload blocks.
a_checkpoint_pack_encodes_to_its_blocks_test_() ->
    Sit = binary:copy(<<16#81>>, 64),
    Nat = binary:copy(<<16#18>>, 64),
    Header = checkpoint_block(checkpoint_fields(), <<Sit/binary, Nat/binary>>),
    Long = binary:copy(<<16#42>>, 5000),
    Paid = checkpoint_block((checkpoint_fields())#{sit_ver_bitmap_bytesize => 5000}, Nat),
    <<First:4096/binary, Rest/binary>> = <<Long/binary, 0:(3192 * 8)>>,
    [?_assertEqual({Block, Payload},
                   begin
                       {ok, Checkpoint} = pack(Block, Payload),
                       Super = (superblock_fields())#{cp_payload => length(Payload)},
                       erx_f2fs_codec:encode_checkpoint(Super, Checkpoint)
                   end)
     || {Block, Payload} <- [{Header, []}, {Paid, [First, Rest]}]].

%% The checksum is computed, whatever crc the value carries, and at an
%% offset short of the block's end the bytes after it are zeros.
a_checkpoint_checksum_is_computed_at_its_offset_test() ->
    Fields = (checkpoint_fields())#{checksum_offset => 4000, sit_ver_bitmap_bytesize => 0,
                                    nat_ver_bitmap_bytesize => 0},
    Super = (superblock_fields())#{cp_payload => 0},
    {Block, []} = erx_f2fs_codec:encode_checkpoint(
                    Super, Fields#{crc => 0, sit_version_bitmap => <<>>, nat_version_bitmap => <<>>}),
    ?assertEqual(checkpoint_block(Fields, <<>>), Block).

an_orphan_block_encodes_to_its_block_test() ->
    Inodes = [7, 8, 1000],
    ?assertEqual(orphan_block(Inodes, 3), erx_f2fs_codec:encode_orphan_block(Inodes, 1, 1)).

a_nat_block_encodes_to_its_block_test() ->
    Block = nat_block([nat_entry(1, 3, 4096), nat_entry(255, 9, 4100)]),
    {ok, Entries} = erx_f2fs_codec:nat_block(Block),
    ?assertEqual(Block, erx_f2fs_codec:encode_nat_block(Entries)).

%% A SIT block's entries past those given are zeros; the valid block count
%% is the one its map gives.
a_sit_block_encodes_to_its_block_test() ->
    Entries = [sit_entry(3, [0, 1, 2]), sit_entry(5, lists:seq(0, 511, 3))],
    Zero = #{vblocks => 0, valid_map => <<0:512>>, mtime => 0},
    Block = erx_abi_packed:encode(erx_f2fs_sit_block,
                                  #{entries => pad(Entries, ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK, Zero)}),
    {ok, Read} = erx_f2fs_codec:sit_block(Block, 2),
    ?assertEqual(Block, erx_f2fs_codec:encode_sit_block(Read)),
    ?assertEqual(Block, erx_f2fs_codec:encode_sit_block([Entry#{valid_blocks := 0} || Entry <- Read])).

%% check_sum, which no one computes, is written as 0, and the journal is
%% always empty: a block whose journal holds entries comes back without them.
a_summary_block_encodes_to_its_block_test() ->
    Empty = erx_f2fs_codec:empty_journal(),
    <<Head:(?BLOCK - 4)/binary, _:32>> = summary_block(Empty),
    {ok, #{entries := Entries, entry_type := Type}} =
        erx_f2fs_codec:summary_block(summary_block(binary:copy(<<16#3c>>, ?ERX_F2FS_NAT_JOURNAL_SIZE))),
    ?assertEqual(<<Head/binary, 0:32>>, erx_f2fs_codec:encode_summary_block(Entries, Type)).

%% Inodes of every layout erXos writes: the fixture's E = 3 under
%% INODE_CHKSUM, E = 9 with every extra attribute set and an inline xattr
%% area, E = 1 under EXTRA_ATTR alone, and none without it.
an_inode_encodes_to_its_block_test_() ->
    Xattr = [16#a0000000 + K || K <- lists:seq(1, 50)],
    Full = with_inode((inode_fields())#{i_addr := [36 bor (50 bsl 16), 16#77, 0, 16#c0ffee,
                                                   16#11, 16#22, 16#33, 16#44, 16#55]
                                                  ++ lists:duplicate(923 - 9 - 50, 6000)
                                                  ++ Xattr},
                      #{i_inline => ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_XATTR,
                        i_xattr_nid => 9, i_blocks => 4}),
    Bare = fun(E) -> (inode_fields())#{i_addr := extra_words(4 * E, 0)
                                                 ++ lists:duplicate(923 - E, 7000)} end,
    Cases = [{superblock_fields(), inode_fields()}, {superblock_fields(), Full},
             {layout_super(1), Bare(1)},
             {layout_super(0), with_inode((inode_fields())#{i_addr := lists:duplicate(923, 8000)},
                                          #{i_inline => 0})}],
    [?_assertEqual(Block, begin {ok, Inode} = erx_f2fs_codec:inode(Super, 4, Block),
                                erx_f2fs_codec:encode_inode(Super, Inode) end)
     || {Super, Fields} <- Cases, Block <- [inode_block(Super, Fields)]].

%% i_ext is written with len 0 ([F 44]), and the checksum covers it.
an_inode_is_written_without_its_extent_test() ->
    Super = superblock_fields(),
    {ok, Inode} = erx_f2fs_codec:inode(Super, 4, inode_block(Super, inode_fields())),
    Block = erx_f2fs_codec:encode_inode(Super, Inode#{i_ext := #{fofs => 1, blk => 5000, len => 2}}),
    ?assertMatch({ok, #{i_ext := #{fofs := 1, blk := 5000, len := 0}}},
                 erx_f2fs_codec:inode(Super, 4, Block)).

%% An inline body is a form erXos only reads, and has no encoder.
an_inline_inode_has_no_encoder_test() ->
    Super = superblock_fields(),
    Fields = inline_inode(<<"data">>, #{i_inline => ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_DATA,
                                        i_size => 4, i_blocks => 1}, 3),
    {ok, Inode} = erx_f2fs_codec:inode(Super, 4, inode_block(Super, Fields)),
    ?assertError(function_clause, erx_f2fs_codec:encode_inode(Super, Inode)).

%% A node's footer names another nid than its inode's, and carries marks
%% and a version in every field ([F 43]).
direct_and_indirect_nodes_encode_to_their_blocks_test_() ->
    Footer = #{nid => 40, ino => 4, flag => (7 bsl 3) bor 2#011, cp_ver => 16#0102030405060708,
               next_blkaddr => 5123},
    Words = [K * 3 || K <- lists:seq(1, 1018)],
    Direct = erx_abi_packed:encode(erx_f2fs_direct_node, #{addr => Words, footer => Footer}),
    {ok, Addresses} = erx_f2fs_codec:direct_node(40, 4, 7, Direct),
    {ok, Indirect} = erx_f2fs_codec:indirect_node(40, 4, 7, Direct),
    {ok, Read} = erx_f2fs_codec:node_footer(Direct),
    [?_assertEqual(Direct, erx_f2fs_codec:encode_direct_node(Addresses, Read)),
     ?_assertEqual(Direct, erx_f2fs_codec:encode_indirect_node(Indirect, Read))].

%% Dots, a name that fills its slot, one that runs on, one at the last
%% slots, and a hash other than the fixture's.
a_dentry_block_encodes_to_its_block_test() ->
    Block = dentry_block([{0, <<".">>, 3, 0}, {1, <<"..">>, 3, 0}, {2, <<"eightchr">>, 10},
                          {3, <<"ninechars">>, 11}, {9, <<"x">>, 12, 16#89abcdef},
                          {181, binary:copy(<<"n">>, 255), 13}]),
    {ok, Dentries} = erx_f2fs_codec:dentry_block(Block),
    ?assertEqual(Block, erx_f2fs_codec:encode_dentry_block(Dentries)).

%%% Encoders: decoding what an encoder builds answers what it was given,
%%% over generated values in the forms erXos writes

-define(ROUNDS, 200).

%% Rounds of Check over values Generate makes, from a fixed seed.
generated(Generate, Check) ->
    rand:seed(exsss, {20, 26, 7}),
    [Check(Generate()) || _ <- lists:seq(1, ?ROUNDS)],
    ok.

uniform(Bits) -> rand:uniform(1 bsl Bits) - 1.

random_bytes(Size) -> << <<(uniform(8))>> || _ <- lists:seq(1, Size) >>.

%% Count bits, each set with odds of one in Odds.
random_bits(Count, Odds) ->
    << <<(case rand:uniform(Odds) of 1 -> 1; _ -> 0 end):1>> || _ <- lists:seq(1, Count) >>.

generated_tables_decode_to_their_values_test() ->
    generated(fun() -> [nat_entry(uniform(8), uniform(32), uniform(32)) || _ <- lists:seq(1, 455)] end,
              fun(Entries) ->
                      ?assertEqual({ok, Entries},
                                   erx_f2fs_codec:nat_block(erx_f2fs_codec:encode_nat_block(Entries)))
              end),
    generated(fun() ->
                      [#{valid_blocks => set_count(Map), type => rand:uniform(6) - 1,
                         valid_map => Map, mtime => uniform(64)}
                       || _ <- lists:seq(1, rand:uniform(55)), Map <- [random_bits(512, rand:uniform(9))]]
              end,
              fun(Entries) ->
                      Block = erx_f2fs_codec:encode_sit_block(Entries),
                      ?assertEqual({ok, Entries}, erx_f2fs_codec:sit_block(Block, length(Entries)))
              end),
    generated(fun() ->
                      #{entries => [#{nid => uniform(32), version => uniform(8), ofs_in_node => uniform(16)}
                                    || _ <- lists:seq(1, 512)],
                        journal => erx_f2fs_codec:empty_journal(), entry_type => uniform(1)}
              end,
              fun(#{entries := Entries, entry_type := Type} = Summary) ->
                      ?assertEqual({ok, Summary},
                                   erx_f2fs_codec:summary_block(erx_f2fs_codec:encode_summary_block(Entries, Type)))
              end),
    generated(fun() -> [uniform(32) || _ <- lists:seq(1, rand:uniform(1021) - 1)] end,
              fun(Inodes) ->
                      ?assertEqual({ok, Inodes},
                                   erx_f2fs_codec:orphan_block(erx_f2fs_codec:encode_orphan_block(Inodes, 2, 3)))
              end).

set_count(Map) -> length([B || <<B:1>> <= Map, B =:= 1]).

generated_nodes_decode_to_their_values_test() ->
    generated(fun() ->
                      {[uniform(32) || _ <- lists:seq(1, 1018)],
                       #{nid => uniform(32), ino => uniform(32), flag => uniform(32), cp_ver => uniform(64),
                         next_blkaddr => uniform(32)}}
              end,
              fun({Words, #{nid := Nid, ino := Ino, flag := Flag} = Footer}) ->
                      Direct = erx_f2fs_codec:encode_direct_node(Words, Footer),
                      Offset = Flag bsr 3,
                      ?assertEqual({ok, Words}, erx_f2fs_codec:direct_node(Nid, Ino, Offset, Direct)),
                      ?assertEqual({ok, Footer}, erx_f2fs_codec:node_footer(Direct)),
                      Indirect = erx_f2fs_codec:encode_indirect_node(Words, Footer),
                      ?assertEqual({ok, Words}, erx_f2fs_codec:indirect_node(Nid, Ino, Offset, Indirect))
              end).

%% Slots in order, each entry starting after the last one's run, names of
%% any length and of any bytes but "/" and NUL, and bits set beyond the
%% runs, which read as passed slots.
generated_dentry_blocks_decode_to_their_values_test() ->
    generated(fun random_dentries/0,
              fun(Dentries) ->
                      ?assertEqual({ok, Dentries},
                                   erx_f2fs_codec:dentry_block(erx_f2fs_codec:encode_dentry_block(Dentries)))
              end).

random_dentries() ->
    Entries = random_entries(rand:uniform(4) - 1, []),
    Runs = lists:append([lists:seq(Slot, Slot + (byte_size(Name) + 7) div 8 - 1)
                         || #{slot := Slot, name := Name} <- Entries]),
    Passed = [Bit || <<Bit:1>> <= random_bits(214, 20)],
    Bitmap = << <<(case lists:member(Slot, Runs) of true -> 1; false -> Bit end):1>>
                || {Slot, Bit} <- lists:zip(lists:seq(0, 213), Passed) >>,
    #{bitmap => Bitmap, entries => Entries}.

random_entries(Slot, Entries) ->
    Name = << <<(rand:uniform(254) + 1)>> || _ <- lists:seq(1, rand:uniform(255)) >>,
    Clean = binary:replace(Name, <<"/">>, <<"-">>, [global]),
    End = Slot + (byte_size(Clean) + 7) div 8,
    case End =< 214 andalso rand:uniform(8) =/= 1 of
        true ->
            Entry = #{slot => Slot, hash_code => uniform(32), ino => uniform(32),
                      file_type => uniform(8), name => Clean},
            random_entries(End + rand:uniform(4) - 1, [Entry | Entries]);
        false ->
            lists:reverse(Entries)
    end.

%% Inodes of each layout erXos writes, with every field it carries random:
%% the extra attributes' size, the inline xattr area, the name, the times.
generated_inodes_decode_to_their_values_test() ->
    generated(fun random_inode/0,
              fun({Super, Inode}) ->
                      Block = erx_f2fs_codec:encode_inode(Super, Inode),
                      {ok, Read} = erx_f2fs_codec:inode(Super, 4, Block),
                      ?assertEqual(maps:remove(i_inode_checksum, Inode),
                                   maps:remove(i_inode_checksum, Read)),
                      ?assertEqual(Block, erx_f2fs_codec:encode_inode(Super, Read))
              end).

random_inode() ->
    {Super, Size} = lists:nth(rand:uniform(5), [{layout_super(0), 0}, {layout_super(1), 4},
                                                 {layout_super(1), 36}, {superblock_fields(), 12},
                                                 {superblock_fields(), 36}]),
    Xattr = lists:nth(rand:uniform(2), [0, ?ERX_F2FS_INLINE_XATTR]),
    Extra = case Size of 0 -> 0; _ -> ?ERX_F2FS_EXTRA_ATTR end,
    XattrWords = case Xattr of 0 -> 0; _ -> ?ERX_F2FS_INLINE_XATTR_WORDS end,
    Attributes = random_extra(Size),
    Name = random_bytes(rand:uniform(256) - 1),
    #{inode := Fixed} = inode_fields(),
    Fields = Fixed#{i_inline := Extra bor Xattr, i_uid := uniform(32), i_gid := uniform(32),
                    i_size := uniform(40), i_blocks := rand:uniform(1000),
                    i_atime := uniform(40), i_mtime_nsec := uniform(30),
                    i_generation := uniform(32), i_pino := uniform(20),
                    i_namelen := byte_size(Name), i_name := Name,
                    i_ext := #{fofs => uniform(32), blk => uniform(32), len => 0}},
    {Super, maps:merge(maps:merge(Fields, Attributes),
                       #{addresses => [uniform(32) || _ <- lists:seq(1, 923 - Size div 4 - XattrWords)],
                         inline_xattr => random_bytes(4 * XattrWords),
                         i_nid => [uniform(32) || _ <- lists:seq(1, 5)],
                         footer => #{nid => 4, ino => 4, flag => uniform(3),
                                     cp_ver => uniform(64), next_blkaddr => uniform(32)}})}.

%% Extra attributes of Size bytes, random where they lie within it and 0
%% past it, as the codec reads them ([F 41]).
random_extra(Size) ->
    Random = erx_abi_packed:encode(erx_f2fs_inode_extra,
                                   #{i_extra_isize => Size, i_inline_xattr_size => uniform(16),
                                     i_projid => uniform(32), i_inode_checksum => uniform(32),
                                     i_crtime => uniform(64), i_crtime_nsec => uniform(32),
                                     i_compr_blocks => uniform(64), i_compress_algorithm => uniform(8),
                                     i_log_cluster_size => uniform(8), i_compress_flag => uniform(16)}),
    <<Held:Size/binary, _/binary>> = Random,
    erx_abi_packed:decode(erx_f2fs_inode_extra,
                          <<Held/binary, 0:((?ERX_F2FS_INODE_EXTRA_SIZE - Size) * 8)>>).

generated_superblocks_and_packs_decode_to_their_values_test() ->
    generated(fun() ->
                      (superblock_fields())#{uuid => random_bytes(16), volume_name => random_bytes(1024),
                                             version => random_bytes(256), crc => uniform(32),
                                             feature => lists:nth(rand:uniform(2),
                                                                  [?ERX_F2FS_FEATURE_SB_CHKSUM, 0])}
              end,
              fun(Super) ->
                      {ok, Read} = erx_f2fs_codec:superblock(erx_f2fs_codec:encode_superblock(Super)),
                      ?assertEqual(maps:remove(crc, Super), maps:remove(crc, Read))
              end),
    generated(fun() ->
                      Payload = rand:uniform(3) - 1,
                      SitBytes = case Payload of 0 -> rand:uniform(1000); _ -> rand:uniform(4096 * Payload) end,
                      {Payload,
                       (checkpoint_fields())#{checkpoint_ver => uniform(64), valid_node_count => uniform(32),
                                              sit_ver_bitmap_bytesize => SitBytes,
                                              nat_ver_bitmap_bytesize => rand:uniform(1000),
                                              sit_version_bitmap => random_bytes(SitBytes),
                                              nat_version_bitmap => random_bytes(rand:uniform(1000))}}
              end,
              fun({Payload, #{nat_version_bitmap := Nat} = Checkpoint}) ->
                      Super = (superblock_fields())#{cp_payload => Payload},
                      {Block, Blocks} = erx_f2fs_codec:encode_checkpoint(Super, Checkpoint),
                      {ok, Read} = erx_f2fs_codec:checkpoint(Super, Block, Blocks),
                      ?assertEqual(Checkpoint#{nat_ver_bitmap_bytesize := byte_size(Nat)},
                                   maps:remove(crc, Read))
              end).
