%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_mount_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([fixture_volume/0, cleared_fuchsia/0]).

-define(BLOCK, 4096).
-define(SEGMENT, 512).
%% The fixture volume's blocks and its two packs' addresses.
-define(PARTITION, 16384).
-define(PACK1, 512).
-define(PACK2, 1024).
%% A 64-bit version just below its wrap.
-define(LAST_VERSION, 16#ffffffffffffffff).
%% A partition for a main area of 34 segments after the fixture's metadata.
-define(WIDE_PARTITION, 21504).
%% An allowance no fixture's SIT reaches.
-define(ALLOWANCE, (1 bsl 30)).
%% The fixture's SIT and NAT block 0, each at copy 0 and copy 1 ([F 34],
%% [F 38]), and written only in the copy its version bit selects, the
%% root's inode, in block 0 of segment 0, the hot node log's, its dentry
%% block, in block 0 of segment 3, the hot data log's, and the warm node
%% log's next block, block 1 of segment 1, where a chain would start.
-define(SIT_COPIES, [1536, 2048]).
-define(NAT_COPIES, [2560, 3072]).
-define(ROOT_INODE, 4096).
-define(ROOT_DENTRIES, 5632).
-define(WALK_START, 4609).
%% The fixture pack's data summaries, hot, warm, cold, and its node ones.
-define(DATA_SUMMARIES, [513, 514, 515]).

%%% Fixtures: erx_f2fs_codec_tests' volume of 16384 blocks, its pack 1 of 8
%%% blocks with no payload at block 512, and pack 2 at block 1024 zeros
%%% unless a case writes one.

super() -> erx_f2fs_codec_tests:superblock_fields().

%% The fixture header, its valid blocks the root's inode and dentry block.
header() -> (erx_f2fs_codec_tests:checkpoint_fields())#{valid_block_count := 2}.

%% The SIT and NAT version bitmaps the fixture header holds, 64 bytes each.
bitmaps() -> binary:copy(<<16#a5>>, 128).

%% A pack at Start: its header and, at its last block, its copy.
pack(Start, Fields) -> pack(Start, Fields, Fields).

pack(Start, #{cp_pack_total_block_count := Total} = Fields, CopyFields) ->
    #{Start => erx_f2fs_codec_tests:checkpoint_block(Fields, bitmaps()),
      Start + Total - 1 => erx_f2fs_codec_tests:checkpoint_block(CopyFields, bitmaps())}.

volume(Super, Packs) ->
    Block = erx_f2fs_codec_tests:superblock_block(Super),
    maps:merge(maps:merge(#{0 => Block, 1 => Block}, tables(Super)), Packs).

volume(Super) -> volume(Super, pack(?PACK1, header())).

%% The fixture volume's blocks, which mount read-write; erx_f2fs_fuzz's
%% seed of a whole mount.
fixture_volume() -> volume(super()).

%% Mounts from Blocks as the volume process does: each {need, Addresses}
%% is answered with those blocks, a zero block for any Blocks lacks, and the
%% mount runs again from the start. A mount that asks for a block it was
%% given, or asks more than eight times, fails the case.
mount(Partition, Blocks) -> mount(Partition, ?ALLOWANCE, Blocks).

mount(Partition, Allowance, Blocks) -> mount(Partition, Allowance, Blocks, #{}, 8).

mount(Partition, Allowance, Blocks, Given, Rounds) ->
    case erx_f2fs_mount:mount(Partition, Allowance, Given) of
        {need, Addresses} when Rounds > 0, Addresses =/= [] ->
            ?assertEqual([], [A || A <- Addresses, is_map_key(A, Given) orelse A >= Partition]),
            Read = maps:from_list([{A, maps:get(A, Blocks, <<0:(?BLOCK * 8)>>)} || A <- Addresses]),
            mount(Partition, Allowance, Blocks, maps:merge(Given, Read), Rounds - 1);
        Answer ->
            Answer
    end.

mount(Blocks) -> mount(?PARTITION, Blocks).

%% The fixture's tables and root for a volume of Super, which may change
%% the counts but not the areas.
tables(Super) ->
    Sit = sit([{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0]}]),
    Nat = nat([{3, erx_f2fs_codec_tests:nat_entry(0, 3, ?ROOT_INODE)}]),
    maps:from_list([{current(?SIT_COPIES), Sit}, {current(?NAT_COPIES), Nat}] ++
                       [{?ROOT_INODE, root_block(Super, #{})}]).

%% A SIT block whose segments are each {Segment, Type, ValidOffsets}, the
%% others empty.
sit(Segments) ->
    Entries = [case lists:keyfind(Segment, 1, Segments) of
                   {Segment, Type, Valid} -> erx_f2fs_codec_tests:sit_entry(Type, Valid);
                   false -> erx_f2fs_codec_tests:sit_entry(0, [])
               end || Segment <- lists:seq(0, 54)],
    erx_f2fs_codec_tests:sit_block(Entries).

%% NAT block 0 with Entries, {Nid, Entry}, and the others free.
nat(Entries) ->
    Free = erx_f2fs_codec_tests:nat_entry(0, 0, 0),
    erx_f2fs_codec_tests:nat_block([proplists:get_value(Nid, Entries, Free)
                                    || Nid <- lists:seq(0, ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK - 1)]).

%% The root's inode block, a directory of one dentry block, with Changes to
%% its fixed part.
root_block(Super, Changes) ->
    #{inode := Inode, i_addr := [W0, W1, W2, _, _ | Rest]} = Fields =
        erx_f2fs_codec_tests:inode_fields(),
    Root = maps:merge(Inode#{i_mode := 8#40755, i_links := 2, i_size := ?BLOCK, i_blocks := 2,
                             i_namelen := 0, i_name := <<0:(255 * 8)>>},
                      Changes),
    erx_f2fs_codec_tests:inode_block(
      Super, Fields#{inode := Root, i_addr := [W0, W1, W2, ?ROOT_DENTRIES, 0 | Rest],
                     footer := #{nid => 3, ino => 3, flag => 0, cp_ver => 1, next_blkaddr => 0}}).

mode(Blocks) ->
    {ok, #{mode := Mode}} = mount(Blocks),
    Mode.

failure(Blocks) ->
    {error, Failure} = mount(Blocks),
    Failure.

%%% The fixed corpora (docs/design-f2fs.md, "Corpora")

%% What each corpus image's mount answers, from its mkfs options
%% (erx_f2fs_corpus_tests) and the rules of docs/design-f2fs.md, "Scope:
%% features and forms": syzkaller's seeds without features or with
%% extra_attr alone mount read-write, those with the R features read-only,
%% the -s 2 seeds as their features say, since each keeps more than 16
%% sections, and those with encrypt, fscrypt_f2fs and Fuchsia's image are
%% refused naming the bits.
expected("f2fs-fuchsia") ->
    {error, {superblock, {features, [encrypt, verity]}}};
expected("f2fs-syzkaller-fscrypt") ->
    {error, {superblock, {features, [encrypt]}}};
expected("f2fs-syzkaller-" ++ N) ->
    case list_to_integer(N) rem 4 of
        1 -> {error, {superblock, {features, [encrypt]}}};
        3 -> {ok, {read_only, [{features, [prjquota, flexible_inline_xattr, inode_crtime]}]}};
        _ -> {ok, read_write}
    end.

corpus_image(Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    Image.

image_blocks(Image) ->
    fun(Addresses) -> maps:from_list([{A, binary:part(Image, A * ?BLOCK, ?BLOCK)} || A <- Addresses]) end.

%% Mounts Image through the need loop, reading each block it asks for.
mount_image(Image) -> mount_image(Image, #{}, 8).

mount_image(Image, Given, Rounds) ->
    Partition = byte_size(Image) div ?BLOCK,
    case erx_f2fs_mount:mount(Partition, ?ALLOWANCE, Given) of
        {need, Addresses} when Rounds > 0 ->
            ?assertEqual([], [A || A <- Addresses, is_map_key(A, Given) orelse A >= Partition]),
            mount_image(Image, maps:merge(Given, (image_blocks(Image))(Addresses)), Rounds - 1);
        {ok, #{mode := Mode}} -> {ok, Mode};
        Answer -> Answer
    end.

every_corpus_image_mounts_as_its_features_and_geometry_say_test_() ->
    {timeout, 600,
     fun() ->
             Pins = erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK")),
             ?assertEqual(18, length(Pins)),
             Wrong = [{Id, Got, Want}
                      || #{id := Id} = Pin <- Pins,
                         Got <- [mount_image(corpus_image(Pin))],
                         Want <- [expected(Id)], Got =/= Want],
             ?assertEqual([], Wrong)
     end}.

%% Fuchsia's image with ENCRYPT and VERITY cleared in both copies (it has
%% no SB_CHKSUM, so no checksum to fix) has no feature outside W, and its
%% geometry asks for nothing read-only.
fuchsia_without_encrypt_and_verity_mounts_test_() ->
    {timeout, 600,
     fun() ->
             ?assertEqual({ok, read_write}, mount_image(cleared_fuchsia()))
     end}.

%% Fuchsia's image with ENCRYPT and VERITY cleared, which erx_f2fs_core_tests
%% also reads.
cleared_fuchsia() ->
    [Pin] = [Pin || #{id := "f2fs-fuchsia"} = Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK"))],
    lists:foldl(fun clear_features/2, corpus_image(Pin), [0, 1]).

clear_features(Copy, Image) ->
    At = Copy * ?BLOCK + ?ERX_F2FS_SUPER_OFFSET + ?ERX_F2FS_SUPER_BLOCK_OFF_FEATURE,
    <<Before:At/binary, Feature:32/little, After/binary>> = Image,
    ?assertEqual(0, Feature band ?ERX_F2FS_FEATURE_SB_CHKSUM),
    Clear = Feature band bnot (?ERX_F2FS_FEATURE_ENCRYPT bor ?ERX_F2FS_FEATURE_VERITY),
    <<Before/binary, Clear:32/little, After/binary>>.

%%% The need protocol

a_mount_asks_for_the_superblock_copies_first_test() ->
    ?assertEqual({need, [0, 1]}, erx_f2fs_mount:mount(?PARTITION, ?ALLOWANCE, #{})).

the_fixture_mounts_read_write_from_pack_1_test() ->
    {ok, #{superblock := #{block_count := 16384}, pack := ?PACK1, bad_copies := [],
           checkpoint := #{checkpoint_ver := 1, sit_version_bitmap := Sit,
                           nat_version_bitmap := Nat},
           mode := read_write}} = mount(volume(super())),
    ?assertEqual(bitmaps(), <<Sit/binary, Nat/binary>>).

%% The fixture's bitmaps set the first bit of each, so its table blocks
%% are current in copy 1.
current([_Copy0, Copy1]) -> Copy1.

%% With one payload block the header holds the NAT bitmap and the payload
%% block after it the SIT bitmap ([F 20], [F 23]). Both bitmaps clear the
%% first bit, so the fixture's table blocks move to copy 0.
payload_volume(StartSum) ->
    Sit = binary:copy(<<16#3c>>, 64),
    Nat = binary:copy(<<16#5a>>, 64),
    Header = (header())#{cp_pack_total_block_count := 9, cp_pack_start_sum := StartSum},
    Block = erx_f2fs_codec_tests:checkpoint_block(Header, Nat),
    Payload = <<Sit/binary, 0:((?BLOCK - 64) * 8)>>,
    Volume = volume((super())#{cp_payload := 1},
                    #{?PACK1 => Block, ?PACK1 + 1 => Payload, ?PACK1 + 8 => Block}),
    Moved = maps:from_list(lists:append([[{Copy0, maps:get(Copy1, Volume)}, {Copy1, <<0:(?BLOCK * 8)>>}]
                                         || [Copy0, Copy1] <- [?SIT_COPIES, ?NAT_COPIES]])),
    {maps:merge(Volume, Moved), Sit, Nat}.

a_pack_with_a_payload_block_reads_its_sit_bitmap_there_test() ->
    {Blocks, Sit, Nat} = payload_volume(2),
    {ok, #{checkpoint := #{sit_version_bitmap := GotSit, nat_version_bitmap := GotNat}}} = mount(Blocks),
    ?assertEqual({Sit, Nat}, {GotSit, GotNat}).

summaries_starting_in_the_payload_fail_test() ->
    {Blocks, _Sit, _Nat} = payload_volume(1),
    ?assertEqual({error, {checkpoint, start_sum}}, mount(Blocks)).

%%% The superblock copy (docs/design-f2fs.md, "Mount", step 1)

a_bad_first_copy_leaves_the_second_test() ->
    Blocks = volume(super()),
    Bad = erx_f2fs_codec_tests:superblock_block((super())#{magic := 0}),
    {error, Rule} = erx_f2fs_codec:superblock(Bad),
    {ok, #{bad_copies := BadCopies, mode := read_write}} = mount(Blocks#{0 := Bad}),
    ?assertEqual([{0, Rule}], BadCopies).

%% A copy refused on erXos's policy, not its validity, fails the mount: the
%% older copy 1 without the feature is never mounted in its place.
a_valid_first_copy_with_a_refused_feature_fails_the_mount_test() ->
    Super = super(),
    Refused = erx_f2fs_codec_tests:superblock_block(
                Super#{feature := maps:get(feature, Super) bor ?ERX_F2FS_FEATURE_ENCRYPT}),
    ?assertEqual({error, {superblock, {features, [encrypt]}}},
                 mount((volume(Super))#{0 := Refused})).

%% A first copy that names a device list fails the mount as well.
a_valid_first_copy_with_a_device_list_fails_the_mount_test() ->
    Listed = erx_f2fs_codec_tests:superblock_block(device_list()),
    ?assertEqual({error, {superblock, device_list}}, mount((volume(super()))#{0 := Listed})).

%% Copy 0 invalid on its SSA and copy 1 on its magic: the mount names copy 0's.
both_bad_copies_fail_with_the_first_ones_rule_test() ->
    Blocks = volume(ssa_area_short_of_the_main_area()),
    Bad = erx_f2fs_codec_tests:superblock_block((super())#{magic := 0}),
    ?assertEqual({superblock, ssa_area}, failure(Blocks#{1 := Bad})).

%% The SSA's one segment holds the summaries of exactly 512 main segments,
%% and of no more.
the_ssa_holds_one_summary_per_main_segment_test_() ->
    Fit = fun(Main) ->
                  End = 4096 + Main * ?SEGMENT,
                  Super = (super())#{segment_count_main := Main, section_count := Main,
                                     segment_count := 7 + Main, block_count := End},
                  mount(End, volume(Super))
          end,
    [?_assertMatch({ok, _}, Fit(512)),
     ?_assertEqual({error, {superblock, ssa_area}}, Fit(513))].

a_partition_without_both_copies_fails_before_any_read_test() ->
    ?assertEqual({error, {superblock, partition}}, erx_f2fs_mount:mount(1, ?ALLOWANCE, #{})).

%% The fixture's areas moved a segment on, so its main area ends a segment
%% past block_count and the partition, under a valid segment_count.
main_area_past_the_partition() ->
    (super())#{segment0_blkaddr := 1024, cp_blkaddr := 1024, sit_blkaddr := 2048,
               nat_blkaddr := 3072, ssa_blkaddr := 4096, main_blkaddr := 4608}.

%% The fixture's areas moved a segment back, so pack 1 would start at block 0.
checkpoint_area_over_the_superblock() ->
    (super())#{segment0_blkaddr := 0, cp_blkaddr := 0, sit_blkaddr := 1024,
               nat_blkaddr := 2048, ssa_blkaddr := 3072, main_blkaddr := 3584,
               block_count := 15872}.

%% The fixture's checkpoint area cut to one segment and its SIT area grown
%% by one, so pack 2 would lie in the SIT.
checkpoint_area_of_one_segment() ->
    (super())#{segment_count_ckpt := 1, segment_count_sit := 3, sit_blkaddr := 1024}.

%% The fixture's SSA area cut to no segment, so its main area's 24 segments
%% have no summary block; the areas still follow each other.
ssa_area_short_of_the_main_area() ->
    (super())#{segment_count := 30, segment_count_ssa := 0, main_blkaddr := 3584}.

%% Device 0 named, its segments the volume's, so the codec's sum holds.
device_list() ->
    Super = super(),
    Named = #{path => <<"/dev/a", 0:(58 * 8)>>, total_segments => maps:get(segment_count, Super)},
    Super#{devs := [Named | tl(maps:get(devs, Super))]}.

superblock_cases() ->
    Super = super(),
    Feature = maps:get(feature, Super),
    [{partition, mount(?PARTITION - 1, volume(Super))},
     {partition, mount(volume(main_area_past_the_partition()))},
     {{features, [encrypt, verity]},
      mount(volume(Super#{feature := Feature bor ?ERX_F2FS_FEATURE_ENCRYPT bor
                                         ?ERX_F2FS_FEATURE_VERITY}))},
     {{features, [16#20000]}, mount(volume(Super#{feature := Feature bor 16#20000}))},
     {{needs_extra_attr, [inode_chksum]},
      mount(volume(Super#{feature := Feature band bnot ?ERX_F2FS_FEATURE_EXTRA_ATTR}))},
     {device_list, mount(volume(device_list()))},
     {checkpoint_area, mount(volume(checkpoint_area_of_one_segment()))},
     {checkpoint_area, mount(volume(checkpoint_area_over_the_superblock()))},
     {ssa_area, mount(volume(ssa_area_short_of_the_main_area()))}].

each_superblock_rule_fails_with_its_name_test_() ->
    [{lists:flatten(io_lib:format("~p", [Rule])), ?_assertEqual({error, {superblock, Rule}}, Got)}
     || {Rule, Got} <- superblock_cases()].

%%% The mount's mode (docs/design-f2fs.md, "Scope: features and forms")

read_only_reasons_test_() ->
    Super = super(),
    Feature = maps:get(feature, Super),
    Small = Super#{block_count := 12288, segment_count := 23, section_count := 16,
                   segment_count_main := 16},
    [{"an R feature", ?_assertEqual({read_only, [{features, [inode_crtime]}]},
                                    mode(volume(Super#{feature := Feature bor
                                                           ?ERX_F2FS_FEATURE_INODE_CRTIME})))},
     {"a main area of 12 sections of two segments",
      ?_assertEqual({read_only, [{section_count, 12}]},
                    mode(volume(Super#{segs_per_sec := 2, section_count := 12})))},
     {"a main area of 17 sections of two segments",
      ?_assertEqual({ok, read_write}, mount_mode(?WIDE_PARTITION, wide_sections()))},
     {"a main area of 16 sections",
      ?_assertEqual({read_only, [{section_count, 16}]},
                    mode(volume(Small, pack(?PACK1, (header())#{user_block_count := 4096}))))},
     {"FSCK and QUOTA_NEED_FSCK mount as they are",
      ?_assertEqual(read_write,
                    mode(volume(Super, pack(?PACK1, flags(?ERX_F2FS_CP_FSCK bor
                                                              ?ERX_F2FS_CP_QUOTA_NEED_FSCK)))))}].

%% The fixture grown to a main area of 34 segments in 17 sections of two
%% segments each, on a partition of 21504 blocks.
wide_sections() ->
    volume((super())#{block_count := ?WIDE_PARTITION, segment_count := 41,
                      segment_count_main := 34, segs_per_sec := 2, section_count := 17}).

mount_mode(Partition, Blocks) ->
    case mount(Partition, Blocks) of
        {ok, #{mode := Mode}} -> {ok, Mode};
        Answer -> Answer
    end.

flags(Flags) ->
    Header = header(),
    Header#{ckpt_flags := maps:get(ckpt_flags, Header) bor Flags}.

%%% The checkpoint pack (docs/design-f2fs.md, "Mount", step 2)

versions(V1, V2) ->
    Packs = maps:merge(pack(?PACK1, (header())#{checkpoint_ver := V1}),
                       pack(?PACK2, (header())#{checkpoint_ver := V2})),
    {ok, #{pack := Pack, checkpoint := #{checkpoint_ver := Version}}} = mount(volume(super(), Packs)),
    {Pack, Version}.

the_later_pack_wins_under_wrap_around_test_() ->
    [?_assertEqual({?PACK2, 2}, versions(1, 2)),
     ?_assertEqual({?PACK1, 2}, versions(2, 1)),
     ?_assertEqual({?PACK1, 3}, versions(3, 3)),
     ?_assertEqual({?PACK2, 0}, versions(?LAST_VERSION, 0)),
     ?_assertEqual({?PACK1, 0}, versions(0, ?LAST_VERSION))].

a_copy_of_another_version_leaves_the_other_pack_test() ->
    Header = header(),
    Packs = maps:merge(pack(?PACK1, Header#{checkpoint_ver := 5}, Header#{checkpoint_ver := 4}),
                       pack(?PACK2, Header#{checkpoint_ver := 3})),
    {ok, #{pack := ?PACK2}} = mount(volume(super(), Packs)).

no_valid_pack_names_each_packs_rule_test() ->
    Header = header(),
    Packs = pack(?PACK1, Header#{checkpoint_ver := 5}, Header#{checkpoint_ver := 4}),
    ?assertEqual({checkpoint, {no_valid_pack, [copy_version, checksum_offset]}},
                 failure(volume(super(), Packs))).

checkpoint_cases() ->
    H = header(),
    [{{flags, [error]}, flags(?ERX_F2FS_CP_ERROR)},
     {{flags, [large_nat_bitmap, disabled, resizefs]},
      flags(?ERX_F2FS_CP_LARGE_NAT_BITMAP bor ?ERX_F2FS_CP_DISABLED bor ?ERX_F2FS_CP_RESIZEFS)},
     {{flags, [16#8000]}, flags(16#8000)},
     {metadata_segments, H#{rsvd_segment_count := 24}},
     {metadata_segments, H#{rsvd_segment_count := 0}},
     {reserved_segments, H#{overprov_segment_count := 0}},
     {user_blocks, H#{user_block_count := 0}},
     {user_blocks, H#{user_block_count := 24 * ?SEGMENT}},
     {valid_blocks, H#{valid_block_count := 10241}},
     {valid_nodes, H#{valid_node_count := 455 * ?SEGMENT - 2}},
     {log_position, H#{cur_node_segno := [24 | tl(maps:get(cur_node_segno, H))]}},
     {log_position, H#{cur_data_blkoff := lists:duplicate(8, ?SEGMENT)}},
     {log_segments, H#{cur_data_segno := [3, 4, 4 | lists:duplicate(5, 16#ffffffff)]}},
     {log_segments, H#{cur_data_segno := [3, 4, 0 | lists:duplicate(5, 16#ffffffff)]}},
     {bitmap_size, H#{sit_ver_bitmap_bytesize := 32}},
     {bitmap_size, H#{nat_ver_bitmap_bytesize := 96}},
     {start_sum, H#{cp_pack_start_sum := 0}},
     {start_sum, H#{cp_pack_start_sum := 506}}].

each_checkpoint_rule_fails_with_its_name_test_() ->
    [{lists:flatten(io_lib:format("~p ~p", [Rule, N])),
      ?_assertEqual({checkpoint, Rule}, failure(volume(super(), pack(?PACK1, Fields))))}
     || {N, {Rule, Fields}} <- lists:enumerate(checkpoint_cases())].

%% A SIT of two segments has 512 blocks in each copy, so its version bitmap
%% of exactly 64 bytes covers 512 x 55 segments, and a main area of one more
%% segment needs a SIT block the bitmap has no bit for ([F 55]). The SSA
%% grows to 56 segments, a summary block for each main segment.
a_main_area_past_the_sit_bitmap_fails_test() ->
    Main = 512 * 55 + 1,
    Ssa = 56,
    MainStart = 3584 + Ssa * ?SEGMENT,
    End = MainStart + Main * ?SEGMENT,
    Super = (super())#{segment_count_ssa := Ssa, main_blkaddr := MainStart,
                       segment_count_main := Main, section_count := Main,
                       segment_count := 6 + Ssa + Main, block_count := End},
    ?assertEqual({error, {checkpoint, sit_bitmap_bits}}, mount(End, volume(Super))).

%% NAT bits take the last blocks of the pack's segment: with a NAT of 2 x
%% 32256 segments, each of the two bitmaps of nat_bits is 2064384 bytes,
%% 1009 blocks together, which no segment holds beside a pack ([F 27]).
nat_bits_past_the_segment_fail_test() ->
    Nat = 2 * 32256,
    NatBlocks = Nat div 2 * ?SEGMENT,
    Main = 24,
    Super = (super())#{segment_count_nat := Nat, ssa_blkaddr := 2560 + Nat * ?SEGMENT,
                       main_blkaddr := 3072 + Nat * ?SEGMENT,
                       segment_count := 5 + Nat + Main,
                       block_count := 3072 + (Nat + Main) * ?SEGMENT},
    Header = (flags(?ERX_F2FS_CP_NAT_BITS))#{nat_ver_bitmap_bytesize := NatBlocks div 8},
    Partition = maps:get(block_count, Super),
    ?assertEqual({error, {checkpoint, nat_bits_room}}, mount(Partition, volume(Super, pack(?PACK1, Header)))).

%%% The pack's contents (docs/design-f2fs.md, "Mount", step 3)

%% The fixture pack has UMOUNT, so its node summaries follow its three
%% normal data summaries; each log has written one block.
the_fixture_answers_its_contents_and_tables_test() ->
    {ok, #{orphans := [], data_summaries := [[_], [_], [_]],
           node_summaries := [[_], [_], [_]], sit := Sit, nat := _,
           root := #{i_mode := 8#40755, i_size := ?BLOCK}}} =
        mount(volume(super())),
    ?assertEqual(24, tuple_size(Sit)),
    ?assertMatch(#{type := ?ERX_F2FS_LOG_HOT_NODE, valid_blocks := 1}, element(1, Sit)).

%% A pack of Total blocks with Flags added and its start_sum at StartSum,
%% and the blocks Extra puts after its header.
pack_with(Flags, Total, StartSum, Extra) ->
    Header = (flags(Flags))#{cp_pack_total_block_count := Total, cp_pack_start_sum := StartSum},
    maps:merge(pack(?PACK1, Header), Extra).

summary(Journal) -> erx_f2fs_codec_tests:summary_block(Journal).

nat_journal(Entries) -> erx_f2fs_codec_tests:nat_journal(length(Entries), Entries).

sit_journal(Entries) ->
    erx_f2fs_codec_tests:sit_journal(length(Entries),
                                     [{Segment, erx_f2fs_codec_tests:sit_entry(Type, Valid)}
                                      || {Segment, Type, Valid} <- Entries]).

%% The fixture with the hot data summary carrying NatJournal and the cold
%% one SitJournal.
journals(NatJournal, SitJournal) ->
    volume(super(), maps:merge(pack(?PACK1, header()),
                               #{513 => summary(NatJournal), 515 => summary(SitJournal)})).

no_nats() -> nat_journal([]).

no_sits() -> sit_journal([]).

%% Without UMOUNT the pack has no node summaries, so its data summaries end
%% at its copy; a compact form of one block holds both journals.
a_compact_pack_without_node_summaries_test() ->
    Pack = (header())#{ckpt_flags := ?ERX_F2FS_CP_COMPACT_SUM bor ?ERX_F2FS_CP_CRC_RECOVERY,
                       cp_pack_total_block_count := 3},
    Nat = nat_journal([{3, erx_f2fs_codec_tests:nat_entry(0, 3, ?ROOT_INODE)}]),
    Summaries = [[#{nid => 3, version => 0, ofs_in_node => 0}], [], []],
    [Compact] = erx_f2fs_codec_tests:compact_blocks(Nat, no_sits(), Summaries),
    Blocks = volume(super(), maps:merge(pack(?PACK1, Pack#{cur_data_blkoff := [1, 0, 0, 0, 0, 0, 0, 0]}),
                                        #{513 => Compact})),
    {ok, #{data_summaries := Got, node_summaries := none}} = mount(Blocks),
    ?assertEqual(Summaries, Got).

orphans_are_read_when_the_pack_has_them_test() ->
    Orphans = erx_f2fs_codec_tests:orphan_block([7, 8], 2),
    Pack = pack_with(?ERX_F2FS_CP_ORPHAN_PRESENT, 9, 2, #{513 => Orphans}),
    {ok, #{orphans := [7, 8]}} = mount(volume(super(), Pack)).

%% Each rule of the pack's contents, the tables and the root, by the
%% fixture changed to break it alone.
content_cases() ->
    Super = super(),
    Valid = fun(Segments) -> with_sit(header(), Segments) end,
    %% A third valid block, which the checkpoint counts.
    Third = fun(Segments) -> with_sit((header())#{valid_block_count := 3}, Segments) end,
    [{"normal summaries not ending at the node summaries",
      {checkpoint, pack_layout}, volume(Super, pack_with(0, 9, 1, #{}))},
     {"a compact form of three blocks",
      {checkpoint, pack_layout}, volume(Super, pack_with(?ERX_F2FS_CP_COMPACT_SUM, 8, 1, #{}))},
     {"an orphan block of 1021 entries",
      {orphan_block, entry_count},
      volume(Super, pack_with(?ERX_F2FS_CP_ORPHAN_PRESENT, 9, 2,
                              #{513 => erx_f2fs_codec_tests:orphan_block([], 1021)}))},
     {"a NAT journal of 39 entries", {nat_journal, entry_count},
      journals(erx_f2fs_codec_tests:nat_journal(39, []), no_sits())},
     {"a NAT journal nid past the NAT", {nat, journal_nid},
      journals(nat_journal([{455 * 512, erx_f2fs_codec_tests:nat_entry(0, 0, 0)}]), no_sits())},
     {"a NAT journal naming a nid twice", {nat, journal_duplicate},
      journals(nat_journal([{9, erx_f2fs_codec_tests:nat_entry(0, 0, 0)},
                            {9, erx_f2fs_codec_tests:nat_entry(1, 0, 0)}]), no_sits())},
     {"a SIT journal of 7 entries", {sit_journal, entry_count},
      journals(no_nats(), erx_f2fs_codec_tests:sit_journal(7, []))},
     {"a SIT journal segment past the main area", {sit, journal_segno},
      journals(no_nats(), sit_journal([{24, 0, []}]))},
     {"a SIT journal naming a segment twice", {sit, journal_duplicate},
      journals(no_nats(), sit_journal([{9, 0, []}, {9, 0, []}]))},
     {"an alloc_type neither LFS nor SSR", {checkpoint, alloc_type},
      volume(Super, pack(?PACK1, (header())#{alloc_type := <<2, 0:120>>}))},
     {"node blocks the checkpoint does not count", {sit, valid_nodes},
      Valid([{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0]}, {9, ?ERX_F2FS_LOG_HOT_NODE + 2, [5]}])},
     {"more valid blocks than the checkpoint's", {sit, valid_blocks},
      Valid([{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0]}, {9, 0, [5]}])},
     {"a log's next block in use", {sit, log_next_block},
      Third([{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0, 1]}])},
     {"an LFS log with a block in use after its next", {sit, log_next_block},
      Third([{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0, 511]}])},
     {"the root's node outside the main area", {nat, block_addr},
      root_at(erx_f2fs_codec_tests:nat_entry(0, 3, 4095))},
     {"the root's node past the main area", {nat, block_addr},
      root_at(erx_f2fs_codec_tests:nat_entry(0, 3, ?PARTITION))},
     {"the root's node at a block the SIT holds free", {nat, block_addr},
      root_at(erx_f2fs_codec_tests:nat_entry(0, 3, ?ROOT_INODE + 1))},
     {"the root's nid free", {nat, free}, root_at(erx_f2fs_codec_tests:nat_entry(0, 0, 0))},
     {"the root's NAT entry owned by another inode", {nat, owner},
      root_at(erx_f2fs_codec_tests:nat_entry(0, 4, ?ROOT_INODE))},
     {"a root that is a file", {root, not_directory}, root_is(#{i_mode => 8#100644})},
     %% The codec refuses any inode without blocks, the root's among them.
     {"a root without blocks", {inode, blocks}, root_is(#{i_blocks => 0})},
     {"a root without a size", {root, no_size}, root_is(#{i_size => 0})},
     {"a root without links", {root, no_links}, root_is(#{i_links => 0})}].

each_content_rule_fails_with_its_name_test_() ->
    [{Name, ?_assertEqual({error, Failure}, mount(Blocks))}
     || {Name, Failure, Blocks} <- content_cases()].

sit_copies(Segments) -> #{current(?SIT_COPIES) => sit(Segments)}.

%% The fixture with Header in pack 1 and the SIT holding Segments.
with_sit(Header, Segments) ->
    volume(super(), maps:merge(pack(?PACK1, Header), sit_copies(Segments))).

root_at(Entry) ->
    Nat = nat([{3, Entry}]),
    maps:merge(volume(super()), #{current(?NAT_COPIES) => Nat}).

root_is(Changes) ->
    maps:merge(volume(super()), #{?ROOT_INODE => root_block(super(), Changes)}).

%%% The tables (steps 4 and 6)

%% An SSR log reuses free blocks wherever they lie, so only its next block
%% must be free.
an_ssr_log_may_have_blocks_in_use_after_its_next_test() ->
    Header = (header())#{alloc_type := <<1, 0:120>>, valid_block_count := 3},
    Blocks = with_sit(Header, [{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0, 511]}]),
    {ok, #{data_summaries := [Hot, [_], [_]]}} = mount(Blocks),
    ?assertEqual(512, length(Hot)).

%% The SIT journal's entry replaces its segment's.
the_sit_journal_overrides_the_blocks_test() ->
    Blocks = maps:merge(journals(no_nats(), sit_journal([{9, ?ERX_F2FS_LOG_HOT_NODE, []}])),
                        sit_copies([{0, ?ERX_F2FS_LOG_HOT_NODE, [0]}, {3, 0, [0]},
                                    {9, ?ERX_F2FS_LOG_HOT_NODE, [4]}])),
    {ok, #{sit := Sit}} = mount(Blocks),
    ?assertMatch(#{valid_blocks := 0, type := ?ERX_F2FS_LOG_HOT_NODE}, element(10, Sit)).

%% With the root in the NAT journal, the journal's entry wins over the
%% block's, which holds the root's nid free.
the_nat_journal_overrides_the_blocks_test() ->
    Entry = erx_f2fs_codec_tests:nat_entry(0, 3, ?ROOT_INODE),
    Blocks = maps:merge(journals(nat_journal([{3, Entry}]), no_sits()),
                        #{current(?NAT_COPIES) => nat([])}),
    ?assertMatch({ok, #{root := #{i_mode := 8#40755}}}, mount(Blocks)),
    ?assertEqual({nat, free}, failure(maps:merge(journals(no_nats(), no_sits()),
                                                 #{current(?NAT_COPIES) => nat([])}))).

%% The SIT's 24 segments are admitted at 160 bytes each before any SIT
%% block is asked for.
the_sit_is_admitted_before_it_is_read_test() ->
    Blocks = volume(super()),
    ?assertEqual({error, {allowance, {sit, 3840}}}, mount(?PARTITION, 3839, Blocks)),
    {ok, _} = mount(?PARTITION, 3840, Blocks).

%%% The chain (docs/design-f2fs.md, "The walk")

%% A node block of the checkpoint at the warm node log's next block, its
%% cp_ver as Version says, fails the mount; one of another checkpoint
%% does not.
chain(Flags, Version) ->
    Header = flags(Flags),
    {ok, #{crc := Crc}} = erx_f2fs_codec:checkpoint(erx_f2fs_codec_tests:checkpoint_block(Header, bitmaps())),
    Footer = <<3:32/little, 3:32/little, 0:32, (Version(Crc)):64/little, 0:32>>,
    Block = <<0:((?BLOCK - 24) * 8), Footer/binary>>,
    mount(maps:merge(volume(super(), pack(?PACK1, Header)), #{?WALK_START => Block})).

a_chain_fails_the_mount_test_() ->
    Plain = ?ERX_F2FS_CP_CRC_RECOVERY,
    [{"the version and CRC under CRC_RECOVERY",
      ?_assertEqual({error, {walk, chain}}, chain(0, fun(Crc) -> 1 bor (Crc bsl 32) end))},
     {"the version alone under CRC_RECOVERY",
      ?_assertMatch({ok, _}, chain(0, fun(_Crc) -> 1 end))},
     {"an older version", ?_assertMatch({ok, _}, chain(0, fun(Crc) -> 0 bor (Crc bsl 32) end))},
     {"the low half alone without NOCRC_RECOVERY",
      ?_assertMatch({ok, _}, chain(0, fun(_Crc) -> 1 bor (16#dead bsl 32) end))},
     {"the low half under NOCRC_RECOVERY",
      ?_assertEqual({error, {walk, chain}},
                    chain(?ERX_F2FS_CP_NOCRC_RECOVERY, fun(_Crc) -> 1 bor (16#dead bsl 32) end))},
     {"the version alone without either flag",
      ?_assertEqual({error, {walk, chain}},
                    chain_without(Plain, fun(_Crc) -> 1 end))}].

chain_without(Flags, Version) ->
    Header = header(),
    Cleared = Header#{ckpt_flags := maps:get(ckpt_flags, Header) band bnot Flags},
    {ok, #{crc := Crc}} = erx_f2fs_codec:checkpoint(erx_f2fs_codec_tests:checkpoint_block(Cleared, bitmaps())),
    Footer = <<3:32/little, 3:32/little, 0:32, (Version(Crc)):64/little, 0:32>>,
    mount(maps:merge(volume(super(), pack(?PACK1, Cleared)),
                     #{?WALK_START => <<0:((?BLOCK - 24) * 8), Footer/binary>>})).
