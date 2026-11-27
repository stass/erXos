%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_corpus_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The feature bits and segments per section that each image's mkfs options
%% state: syzkaller's in each program's header, as the probe record copies
%% them; fscrypt_f2fs states none and is encrypted (docs/design-f2fs.md,
%% "Corpora"); Fuchsia's script passes -O encrypt,verity.
expected("f2fs-fuchsia") ->
    {?ERX_F2FS_FEATURE_ENCRYPT bor ?ERX_F2FS_FEATURE_VERITY, 1};
expected("f2fs-syzkaller-fscrypt") ->
    {?ERX_F2FS_FEATURE_ENCRYPT, 1};
expected("f2fs-syzkaller-" ++ N) ->
    Seed = list_to_integer(N),
    Features = case Seed rem 4 of
                   0 -> 0;
                   1 -> ?ERX_F2FS_FEATURE_ENCRYPT;
                   2 -> ?ERX_F2FS_FEATURE_EXTRA_ATTR;
                   3 -> ?ERX_F2FS_FEATURE_EXTRA_ATTR bor ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR bor
                            ?ERX_F2FS_FEATURE_INODE_CHKSUM bor ?ERX_F2FS_FEATURE_INODE_CRTIME bor
                            ?ERX_F2FS_FEATURE_PRJQUOTA
               end,
    {Features, (Seed div 4) rem 2 + 1}.

%% Each image deps.lock pins (ERX_DEPS_LOCK) decodes from the file the fetch
%% step put under ERX_F2FS_CORPUS to its pinned bytes; its superblock reads
%% with the features and segments per section its mkfs options state; and at
%% least one of its checkpoint packs reads whole: header, copy and payload.
%% A failing image is named with what failed.
every_corpus_image_reads_as_its_mkfs_options_state_test_() ->
    {timeout, 600,
     fun() ->
             Pins = erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK")),
             ?assertEqual(18, length(Pins)),
             Results = [{Id, try read_image(Pin) catch Class:Reason -> {Class, Reason} end}
                        || #{id := Id} = Pin <- Pins],
             ?assertEqual([], [Result || {_Id, Got} = Result <- Results, Got =/= ok])
     end}.

read_image(#{id := Id} = Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    {ok, #{feature := Features, segs_per_sec := SegsPerSec}, [_ | _]} = erx_f2fs_corpus:metadata(Image),
    {Features, SegsPerSec} = expected(Id),
    ok.

%%% Damaged and hostile files, against pins of small images made here

pin(Form, Image) ->
    #{id => "f2fs-hostile", form => Form, filename => "hostile", bytes => byte_size(Image),
      sha256 => binary:encode_hex(crypto:hash(sha256, Image), lowercase)}.

scratch(Name, Bytes) ->
    Path = filename:absname(Name ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:write_file(Path, Bytes),
    Path.

image(Form, Image, Name, File) ->
    erx_f2fs_corpus:image(pin(Form, Image), scratch(Name, File)).

program(Compressed) ->
    <<"syz_mount_image$f2fs(&AUTO='f2fs\\x00', &AUTO=\"$", (base64:encode(Compressed))/binary, "\")\n">>.

zstd(Image) ->
    base64:encode(iolist_to_binary(zstd:compress(Image))).

the_pinned_image_decodes_from_either_form_test() ->
    Image = crypto:strong_rand_bytes(8192),
    ?assertEqual({ok, Image}, image(syzkaller, Image, "zlib", program(zlib:compress(Image)))),
    ?assertEqual({ok, Image}, image(fuchsia, Image, "zstd", zstd(Image))).

%% A stream that decompresses past the image's pinned size stops there:
%% 2 MiB of zeros against a 1 MiB pin, in each form.
a_stream_past_its_image_stops_at_the_pin_test() ->
    Pinned = binary:copy(<<0>>, 1 bsl 20),
    Bomb = binary:copy(<<0>>, 2 bsl 20),
    ?assertEqual({error, too_large}, image(syzkaller, Pinned, "zlib-bomb", program(zlib:compress(Bomb)))),
    ?assertEqual({error, too_large}, image(fuchsia, Pinned, "zstd-bomb", zstd(Bomb))).

%% An image of the pinned size but other bytes is refused by its SHA-256.
other_bytes_of_the_pinned_size_are_refused_test() ->
    Pinned = binary:copy(<<0>>, 4096),
    Other = binary:copy(<<1>>, 4096),
    ?assertEqual({error, sha256}, image(syzkaller, Pinned, "other", program(zlib:compress(Other)))),
    ?assertEqual({error, sha256}, image(fuchsia, Pinned, "other", zstd(Other))).

%% A stream cut short decodes to fewer bytes than the pin, in each form.
a_truncated_stream_is_refused_test() ->
    Image = crypto:strong_rand_bytes(8192),
    Cut = fun(Bytes) -> binary:part(Bytes, 0, byte_size(Bytes) div 2) end,
    Zstd = iolist_to_binary(zstd:compress(Image)),
    ?assertEqual({error, size}, image(syzkaller, Image, "cut", program(Cut(zlib:compress(Image))))),
    ?assertEqual({error, size}, image(fuchsia, Image, "cut", base64:encode(Cut(Zstd)))).

a_damaged_stream_is_refused_test() ->
    Image = <<"image">>,
    ?assertMatch({error, {zlib, _}}, image(syzkaller, Image, "damaged", program(<<"not zlib at all">>))),
    ?assertMatch({error, {zstd, _}}, image(fuchsia, Image, "damaged", base64:encode(<<"not zstd at all">>))).

%% A zlib stream that asks for a preset dictionary names that.
a_stream_wanting_a_dictionary_is_refused_test() ->
    Image = <<"image">>,
    Z = zlib:open(),
    ok = zlib:deflateInit(Z),
    _ = zlib:deflateSetDictionary(Z, <<"dictionary">>),
    Compressed = iolist_to_binary(zlib:deflate(Z, Image, finish)),
    zlib:close(Z),
    ?assertEqual({error, need_dictionary}, image(syzkaller, Image, "dictionary", program(Compressed))).

a_file_past_its_bound_is_refused_test() ->
    Big = binary:copy(<<"A">>, (1 bsl 20) + 1),
    ?assertEqual({error, file_too_large}, image(syzkaller, <<"image">>, "big", Big)).

an_empty_file_is_refused_test() ->
    ?assertEqual({error, empty_file}, image(syzkaller, <<"image">>, "empty", <<>>)),
    ?assertEqual({error, empty_file}, image(fuchsia, <<"image">>, "empty", <<>>)).

base64_garbage_is_refused_test() ->
    ?assertEqual({error, base64}, image(syzkaller, <<"image">>, "garbage", <<"\"$%%%%\"">>)),
    ?assertEqual({error, base64}, image(fuchsia, <<"image">>, "garbage", <<"%%%%">>)).

a_program_with_two_images_is_refused_test() ->
    Two = <<"\"$AAAA\" \"$AAAA\"">>,
    ?assertEqual({error, image_string}, image(syzkaller, <<"image">>, "two", Two)).

%%% The encoders against Linux's blocks

%% Every block of the corpus images that erXos writes in some form, read
%% where Linux put it: both superblock copies, each valid pack's header with
%% its payload, orphan blocks and normal summaries, the current NAT and SIT
%% blocks, the SSA, each node the NAT names, and each block directory's
%% dentry blocks (docs/design-f2fs.md, "Unit and property tests"). Each
%% block that decodes must encode, in the form erXos writes, to a block that
%% decodes to that form's value; and a block already in that form must
%% encode back to its own bytes wherever its value describes them, so a
%% byte may differ only where the encoder writes zeros over bytes no value
%% holds (a deleted name, a stale record). Blocks of zeros prove nothing
%% and are not counted. The counts are per kind: blocks read, and blocks
%% whose bytes came back whole. The 25 inodes that do not are those whose
%% i_ext Linux filled, and the two dentry blocks keep a removed entry's
%% record. All but one image's current SIT blocks hold only zeros.
every_corpus_block_erxos_writes_encodes_back_test_() ->
    {timeout, 600,
     fun() ->
             Pins = erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK")),
             {Tally, Failures} =
                 lists:foldl(fun(Pin, Acc) -> image_blocks(Pin, Acc) end, {#{}, []}, Pins),
             ?assertEqual([], Failures),
             ?assertEqual(#{superblock => {36, 36}, checkpoint => {36, 36},
                            orphan_block => {1, 1}, summary_block => {19, 19},
                            nat_block => {27, 27}, sit_block => {1, 1},
                            inode => {52, 27}, node => {19, 19},
                            dentry_block => {30, 28}},
                          Tally)
     end}.

image_blocks(Pin, Acc) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    case erx_f2fs_corpus:metadata(Image) of
        {ok, Super, _Packs} -> lists:foldl(fun(Check, In) -> Check(Super, Image, In) end, Acc,
                                           [fun superblocks/3, fun packs/3, fun tables/3, fun nodes/3]);
        {error, _} -> Acc
    end.

superblocks(_Super, Image, Acc) ->
    lists:foldl(fun(Address, In) ->
                        Block = block(Image, Address),
                        round_trip(superblock, Block, erx_f2fs_codec:superblock(Block),
                                   fun erx_f2fs_codec:encode_superblock/1,
                                   fun erx_f2fs_codec:superblock/1, In)
                end, Acc, [0, 1]).

%% Each valid pack: its header and payload, its orphan blocks, and its
%% summaries in the normal form, the data logs' and, with UMOUNT or
%% FASTBOOT, the node logs' ([F 26], [F 30]).
packs(#{cp_blkaddr := First, cp_payload := Payload} = Super, Image, Acc) ->
    lists:foldl(fun(Start, In) -> pack(Super, Image, Start, In) end, Acc,
                [Start || Start <- [First, First + 512],
                          {ok, _} <- [erx_f2fs_codec:checkpoint(Super, block(Image, Start),
                                                                blocks(Image, Start + 1, Payload))]]).

pack(#{cp_payload := Payload} = Super, Image, Start, Acc) ->
    Header = block(Image, Start),
    Paid = blocks(Image, Start + 1, Payload),
    {ok, #{ckpt_flags := Flags, cp_pack_start_sum := StartSum,
           cp_pack_total_block_count := Total}} = Read = erx_f2fs_codec:checkpoint(Super, Header, Paid),
    Encode = fun(Checkpoint) ->
                     {Block, Blocks} = erx_f2fs_codec:encode_checkpoint(Super, Checkpoint),
                     iolist_to_binary([Block | Blocks])
             end,
    Decode = fun(<<Block:4096/binary, Blocks/binary>>) ->
                     erx_f2fs_codec:checkpoint(Super, Block, [B || <<B:4096/binary>> <= Blocks])
             end,
    Packed = round_trip(checkpoint, iolist_to_binary([Header | Paid]), Read, Encode, Decode, Acc),
    Orphans = case Flags band ?ERX_F2FS_CP_ORPHAN_PRESENT of
                  0 -> [];
                  _ -> lists:seq(Start + 1 + Payload, Start + StartSum - 1)
              end,
    Count = length(Orphans),
    Orphaned = lists:foldl(
                 fun({Index, Address}, In) ->
                         Block = block(Image, Address),
                         round_trip(orphan_block, Block, erx_f2fs_codec:orphan_block(Block),
                                    fun(Inodes) -> erx_f2fs_codec:encode_orphan_block(Inodes, Index, Count) end,
                                    fun erx_f2fs_codec:orphan_block/1, In)
                 end, Packed, lists:zip(lists:seq(1, Count), Orphans)),
    Summaries = case Flags band ?ERX_F2FS_CP_COMPACT_SUM of
                    0 -> case Flags band (?ERX_F2FS_CP_UMOUNT bor ?ERX_F2FS_CP_FASTBOOT) of
                             0 -> lists:seq(Start + Total - 4, Start + Total - 2);
                             _ -> lists:seq(Start + Total - 7, Start + Total - 2)
                         end;
                    _ -> []
                end,
    lists:foldl(fun(Address, In) -> summary(block(Image, Address), In) end, Orphaned, Summaries).

summary(Block, Acc) ->
    round_trip(summary_block, Block, erx_f2fs_codec:summary_block(Block),
               fun(#{entries := Entries, entry_type := Type}) ->
                       erx_f2fs_codec:encode_summary_block(Entries, Type)
               end, fun erx_f2fs_codec:summary_block/1, Acc).

%% The NAT and SIT blocks the newest pack's version bitmaps select, and the
%% SSA ([F 34], [F 38], [F 45]).
tables(#{nat_blkaddr := Nat, segment_count_nat := NatSegments, sit_blkaddr := Sit,
         segment_count_sit := SitSegments, ssa_blkaddr := Ssa,
         segment_count_main := Main} = Super, Image, Acc) ->
    #{nat_version_bitmap := NatBits, sit_version_bitmap := SitBits} = newest(Super, Image),
    Natted = lists:foldl(
               fun(Index, In) ->
                       Block = block(Image, nat_block(Nat, NatBits, Index)),
                       round_trip(nat_block, Block, erx_f2fs_codec:nat_block(Block),
                                  fun erx_f2fs_codec:encode_nat_block/1,
                                  fun erx_f2fs_codec:nat_block/1, In)
               end, Acc, lists:seq(0, copy_blocks(NatSegments) - 1)),
    Sitted = lists:foldl(
               fun(Index, In) ->
                       Block = block(Image, table_block(Sit, SitSegments, SitBits, Index)),
                       Used = min(?ERX_F2FS_SIT_ENTRIES_PER_BLOCK,
                                  Main - ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK * Index),
                       round_trip(sit_block, Block, erx_f2fs_codec:sit_block(Block, Used),
                                  fun erx_f2fs_codec:encode_sit_block/1,
                                  fun(Encoded) -> erx_f2fs_codec:sit_block(Encoded, Used) end, In)
               end, Natted, lists:seq(0, (Main - 1) div ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK)),
    lists:foldl(fun(Segment, In) -> summary(block(Image, Ssa + Segment), In) end,
                Sitted, lists:seq(0, Main - 1)).

%% Block Index of the SIT's current copy: copy 1 is the area's second half
%% ([F 38]).
table_block(First, Segments, Bitmap, Index) ->
    First + Index + erx_f2fs_codec:bit(Bitmap, Index) * copy_blocks(Segments).

copy_blocks(Segments) -> Segments div 2 * 512.

%% NAT block Index of the current copy: the copies interleave a segment at a
%% time, copy 1 the second segment of each pair ([F 34]).
nat_block(First, Bitmap, Index) ->
    First + 1024 * (Index div 512) + Index rem 512 + erx_f2fs_codec:bit(Bitmap, Index) * 512.

newest(Super, Image) ->
    {ok, Super, Packs} = erx_f2fs_corpus:metadata(Image),
    Read = [Checkpoint || {Header, Payload} <- Packs,
                          {ok, Checkpoint} <- [erx_f2fs_codec:checkpoint(Super, Header, Payload)]],
    lists:last(lists:sort(fun(#{checkpoint_ver := A}, #{checkpoint_ver := B}) -> A =< B end, Read)).

%% Each node a used entry of the current NAT places in the main area whose
%% footer names that nid and that entry's inode, an xattr node excepted: an
%% inode, read as its nid's, or a direct or indirect node, which share one
%% layout; and the dentry blocks each block directory's inode addresses.
%% An inode with an inline body is a form erXos only reads.
nodes(#{nat_blkaddr := Nat, segment_count_nat := NatSegments} = Super, Image, Acc) ->
    #{nat_version_bitmap := NatBits} = newest(Super, Image),
    Entries = [{Index * ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK + Slot, Entry}
               || Index <- lists:seq(0, copy_blocks(NatSegments) - 1),
                  {ok, Read} <- [erx_f2fs_codec:nat_block(
                                   block(Image, nat_block(Nat, NatBits, Index)))],
                  {Slot, Entry} <- lists:enumerate(0, Read)],
    lists:foldl(fun({Nid, #{ino := Ino, block_addr := Address}}, In) ->
                        case Nid >= ?ERX_F2FS_ROOT_INO andalso in_main(Super, Image, Address) of
                            true -> node(Super, Image, Nid, Ino, block(Image, Address), In);
                            false -> In
                        end
                end, Acc, Entries).

node(Super, Image, Nid, Ino, Block, Acc) ->
    case {erx_f2fs_codec:node_footer(Block), erx_f2fs_codec:inode(Super, Nid, Block)} of
        {{ok, #{nid := Nid, ino := Nid}}, {ok, #{addresses := _}} = Read} ->
            Inoded = round_trip(inode, Block, Read,
                                fun(Inode) -> erx_f2fs_codec:encode_inode(Super, Inode) end,
                                fun(Encoded) -> erx_f2fs_codec:inode(Super, Nid, Encoded) end, Acc),
            dentry_blocks(Super, Image, Read, Inoded);
        {{ok, #{nid := Nid, ino := Ino, flag := Flag} = Footer}, _}
          when Nid =/= Ino, Flag bsr ?ERX_F2FS_NODE_MARK_BITS =/= ?ERX_F2FS_XATTR_NODE_OFFSET ->
            Offset = Flag bsr ?ERX_F2FS_NODE_MARK_BITS,
            round_trip(node, Block, erx_f2fs_codec:direct_node(Nid, Ino, Offset, Block),
                       fun(Words) -> erx_f2fs_codec:encode_direct_node(Words, Footer) end,
                       fun(Encoded) -> erx_f2fs_codec:direct_node(Nid, Ino, Offset, Encoded) end,
                       Acc);
        _ ->
            Acc
    end.

dentry_blocks(Super, Image, {ok, #{i_mode := Mode, addresses := Addresses}}, Acc)
  when Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_DIR ->
    lists:foldl(fun(Address, In) ->
                        Block = block(Image, Address),
                        round_trip(dentry_block, Block, erx_f2fs_codec:dentry_block(Block),
                                   fun erx_f2fs_codec:encode_dentry_block/1,
                                   fun erx_f2fs_codec:dentry_block/1, In)
                end, Acc, [Address || Address <- Addresses, in_main(Super, Image, Address)]);
dentry_blocks(_Super, _Image, _Read, Acc) ->
    Acc.

in_main(#{main_blkaddr := Main} = Super, Image, Address) ->
    Address >= Main andalso Address < erx_f2fs_codec:main_end(Super)
        andalso Address < byte_size(Image) div 4096.

%% One block of Kind, counted when it decodes and is not all zeros: its
%% value in the form erXos writes decodes back from its encoding, and when
%% the value is in that form already, its encoding keeps every byte of the
%% block but where it writes a zero. A failure names the kind and the first
%% byte the encoding changed.
round_trip(Kind, Block, {ok, Value}, Encode, Decode, {Tally, Failures} = Acc) ->
    case Block =:= <<0:(byte_size(Block) * 8)>> of
        true ->
            Acc;
        false ->
            Writer = writer_form(Kind, Value),
            Encoded = Encode(Writer),
            Decoded = Decode(Encoded),
            Same = Decoded =:= {ok, writer_value(Kind, Writer, Decoded)},
            Changed = [{At, Old, New}
                       || {At, Old, New} <- lists:zip3(lists:seq(0, byte_size(Block) - 1),
                                                       binary_to_list(Block),
                                                       binary_to_list(Encoded)),
                          Old =/= New],
            Kept = Writer =:= Value andalso Changed =:= [],
            {Read, Whole} = maps:get(Kind, Tally, {0, 0}),
            Counted = Tally#{Kind => {Read + 1, Whole + case Kept of true -> 1; false -> 0 end}},
            Bad = [Change || Writer =:= Value, {_, _, New} = Change <- Changed, New =/= 0],
            case {Same, Bad} of
                {true, []} -> {Counted, Failures};
                _ -> {Counted, [{Kind, Same, lists:sublist(Bad, 1)} | Failures]}
            end
    end;
round_trip(_Kind, _Block, {error, _}, _Encode, _Decode, Acc) ->
    Acc.

%% The value erXos would write for a decoded one: an inode's extent hint
%% has len 0 ([F 44]); any other record is written as read.
writer_form(inode, #{i_ext := Extent} = Inode) -> Inode#{i_ext := Extent#{len := 0}};
writer_form(summary_block, Summary) -> Summary#{journal := erx_f2fs_codec:empty_journal()};
writer_form(_Kind, Value) -> Value.

%% What a value decodes back as: its checksums are the computed ones.
writer_value(inode, Inode, {ok, #{i_inode_checksum := Checksum}}) ->
    Inode#{i_inode_checksum := Checksum};
writer_value(superblock, Super, {ok, #{crc := Crc}}) -> Super#{crc := Crc};
writer_value(checkpoint, Checkpoint, {ok, #{crc := Crc}}) -> Checkpoint#{crc := Crc};
writer_value(_Kind, Value, _Read) -> Value.

block(Image, Address) -> binary:part(Image, Address * 4096, 4096).

blocks(Image, First, Count) -> [block(Image, First + N) || N <- lists:seq(0, Count - 1)].
