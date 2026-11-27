%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of F2FS's codec, erx_f2fs_codec (docs/design-f2fs.md, "Reading the
%% medium"), for every reader it has. It runs from tools/fuzz/erx_f2fs.rb, which also
%% runs it against seeded faults.
%%
%% The seeds are erx_f2fs_codec_tests' fixtures: a superblock, a checkpoint header
%% with its bitmaps, one with its SIT bitmap in a payload block, an orphan block, NAT
%% and SIT blocks and journals, a summary block and compact summaries, inodes with
%% addresses, inline data and inline dentries, and a dentry block, which must each
%% read as valid first (failure `seed`). The superblock and checkpoint seeds are also
%% the corpus images' (docs/design-f2fs.md, "Corpora"), each decoded once from the
%% file the fetch step put under the directory the runner names and checked against
%% its deps.lock pin: its superblock's fields and its valid checkpoint packs, an image
%% that does not decode or read failing the run with `seed`, naming it. A superblock
%% or checkpoint case starts from a fixture or a corpus image's seed as often. NAT,
%% SIT, inode and dentry blocks of the images wait for a walk of their trees. Then
%% each case mutates one, by byte writes biased to the fixed fields or by setting
%% one decoded field to a
%% boundary or random value, with the checksum mostly fixed up by the tests' own
%% bitwise CRC so that the mutation reaches the rules behind it, and reads it with
%% blocks of other sizes and payloads of other lengths among the inputs. Every read
%% must answer {ok, Record} or {error, {Structure, Rule}} (`shape`), never raise
%% (`crash`), and give bitmaps and orphan lists of the sizes their counts claim
%% (`size`), and lists of the lengths their counts claim (`size`). A superblock
%% whose area addresses were moved apart under a fixed-up checksum must fail with
%% `areas` (failure `areas`). Every SIT entry read must count the bits its map sets
%% (`valid_map`), every inode read must have a whole number of words of extra
%% attributes (`extra_isize`) and inline data of its size (`size`), every directory
%% inode read at most 63 hash levels (`current_depth`), and every
%% dentry's name must end by its area's last slot (`size`). Every value a
%% reader answers whose record has an encoder must read back from its encoding
%% in the form erXos writes, an inode's i_ext with len 0 and its checksum aside
%% (`round_trip`). A file's slot names only a valid main area block of a data
%% log's segment (`kind`). A run reaches every rule of ?REACHED (failure `unreached`).
-module(erx_f2fs_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
%% Every outcome a run of the default length reaches; one it misses means the
%% mutations no longer reach that rule (failure `unreached`).
-define(REACHED,
        [{superblock, Rule} || Rule <- [ok, block_size, magic, crc, checksum_offset,
                                        log_blocksize, log_blocks_per_seg,
                                        log_sectorsize, segment_count,
                                        section_count, segs_per_sec,
                                        segment_count_main, block_count,
                                        secs_per_zone, cp_payload, devices,
                                        extensions, reserved_inodes, areas]]
        ++ [{checkpoint, Rule} || Rule <- [ok, block_size, crc, checksum_offset,
                                           pack_blocks, large_nat_bitmap,
                                           payload_count, bitmap_room]]
        ++ [{orphan_block, Rule} || Rule <- [ok, block_size, entry_count]]
        ++ [{nat_block, Rule} || Rule <- [ok, block_size]]
        ++ [{nat_journal, Rule} || Rule <- [ok, journal_size, entry_count]]
        ++ [{sit_block, Rule} || Rule <- [ok, block_size, entry_count | ?SIT_RULES]]
        ++ [{sit_journal, Rule} || Rule <- [ok, journal_size, entry_count | ?SIT_RULES]]
        ++ [{summary_block, Rule} || Rule <- [ok, block_size]]
        ++ [{compact_summary, Rule} || Rule <- [ok, block_size, entry_count, room]]
        ++ [{inode, Rule} || Rule <- [ok, block_size, nid, footer, checksum, extra_attr,
                                      extra_isize, inline_xattr_size, blocks,
                                      xattr_nid, casefold, device_alias, namelen,
                                      mode, links, inline_dentry, inline_data_type,
                                      inline_data_blocks, inline_data_transformed,
                                      inline_data]]
        ++ [{inline_dentries, Rule} || Rule <- [ok | ?DENTRY_RULES]]
        ++ [{dentry_block, Rule} || Rule <- [ok, block_size | ?DENTRY_RULES]]
        ++ [{Node, Rule} || Node <- [direct_node, indirect_node], Rule <- [ok, block_size, footer]]
        ++ [{walk, ok}, {data, block_addr}, {nat, free}, {nat, nid}, {file, size}]
        ++ [{dir, ok}, {dentry_block, name}]
        ++ [{mount, ok}, {allowance, sit}, {nat, block_addr}, {sit, valid_nodes}]).
%% The mount's allowance in most cases: more than any seed's SIT needs.
-define(ALLOWANCE, (1 bsl 30)).
%% The most needs a mount of a seed may answer before it ends.
-define(MOUNT_ROUNDS, 16).
%% The blocks of erx_f2fs_mount_tests' fixture volume.
-define(FIXTURE_PARTITION, 16384).
%% The most needs a walk of the fixture file may answer: its inode and its
%% NAT block, three nodes and a NAT block for each on each of two paths,
%% and the data.
-define(WALK_ROUNDS, 16).
%% The most needs a lookup or readdir of the fixture directory may answer:
%% its inode, and a round a hash level for the nine levels whose buckets
%% start in its address array, or a readdir's blocks, and the nodes of a
%% mutated tree.
-define(DIR_ROUNDS, 32).
%% The fixture's NAT area, both copies, and its main area's start: every
%% block a walk asks for lies in one of the two.
-define(FIXTURE_NAT, 2560).
-define(FIXTURE_MAIN, 4096).
%% The fixture file's inode (erx_f2fs_core_tests).
-define(FILE_INO, 4).
-define(SIT_RULES, [valid_blocks, valid_map, type]).
-define(DENTRY_RULES, [name_len, name_run]).
-define(AREA_FIELDS, [segment0_blkaddr, cp_blkaddr, sit_blkaddr, nat_blkaddr,
                      ssa_blkaddr, main_blkaddr]).

run([Seed, Cases, ThirdParty, Lock]) ->
    rand:seed(exsss, list_to_integer(Seed)),
    Count = list_to_integer(Cases),
    load_corpus(ThirdParty, Lock),
    check_seeds(),
    Kinds = [fun superblock_case/0, fun area_case/0, fun checkpoint_case/0,
             fun orphan_case/0, fun nat_case/0, fun nat_journal_case/0,
             fun sit_case/0, fun sit_journal_case/0, fun summary_case/0,
             fun compact_case/0, fun inode_case/0, fun inode_case/0,
             fun dentry_case/0, fun mount_case/0, fun mount_case/0, fun node_case/0,
             fun walk_case/0, fun walk_case/0, fun dir_case/0, fun dir_case/0],
    Outcomes = [(pick(Kinds))() || _ <- lists:seq(1, Count)],
    io:format("fuzz: ~b cases ok~n", [Count]),
    %% How often each rule answered, so a run shows which checks the cases reach.
    Tally = tally(Outcomes),
    [io:format("  ~p ~p~n", [Outcome, Times])
     || {Outcome, Times} <- lists:sort(maps:to_list(Tally))],
    case [Outcome || Outcome <- ?REACHED, not maps:is_key(Outcome, Tally)] of
        [] -> ok;
        Missed -> fail(unreached, Missed)
    end,
    halt(0).

fail(Property, Detail) ->
    io:format("fuzz failure: ~s: ~0tp~n", [Property, Detail]),
    halt(1).

%%% Seeds

super_fields() -> erx_f2fs_codec_tests:superblock_fields().

header_fields() -> erx_f2fs_codec_tests:checkpoint_fields().

%% The superblock a pack of this payload belongs to.
super_with(Payload) -> (super_fields())#{cp_payload => length(Payload)}.

%% The fixture's superblock fields or, as often, a corpus image's.
some_super() ->
    case rand:uniform(2) of
        1 -> super_fields();
        2 -> pick([Super || {Super, _Packs} <- corpus()])
    end.

%% The fixture's packs, each a superblock, a header and its payload: the bitmaps in
%% the header, or the SIT bitmap in one payload block.
packs() ->
    Fields = header_fields(),
    InHeader = erx_f2fs_codec_tests:checkpoint_block(Fields, random_bytes(128)),
    WithPayload = erx_f2fs_codec_tests:checkpoint_block(
                    Fields#{sit_ver_bitmap_bytesize => 3000}, random_bytes(64)),
    [{super_with(Payload), Header, Payload}
     || {Header, Payload} <- [{InHeader, []}, {WithPayload, [random_bytes(?BLOCK)]}]].

%% A fixture's pack or, as often, a corpus image's.
some_pack() ->
    case rand:uniform(2) of
        1 -> pick(packs());
        2 -> pick(corpus_packs())
    end.

%% The corpus images' valid packs, each with its image's superblock.
corpus_packs() ->
    [{Super, Header, Payload} || {Super, Packs} <- corpus(), {Header, Payload} <- Packs].

%% The images deps.lock at Lock pins, each decoded once from its file under
%% ThirdParty: its superblock's fields and its valid checkpoint packs.
load_corpus(ThirdParty, Lock) ->
    Images = [corpus_image(ThirdParty, Pin) || Pin <- erx_f2fs_corpus:pins(Lock)],
    persistent_term:put({?MODULE, corpus}, [{Super, Packs} || {Super, Packs, _Mount} <- Images]),
    persistent_term:put({?MODULE, mounts},
                        [{?FIXTURE_PARTITION, erx_f2fs_mount_tests:fixture_volume()}
                         | [Mount || {_Super, _Packs, Mount} <- Images]]).

corpus_image(ThirdParty, #{id := Id} = Pin) ->
    maybe
        {ok, Image} ?= erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(ThirdParty, Pin)),
        {ok, Super, Packs} ?= erx_f2fs_corpus:metadata(Image),
        {Super, Packs, mount_seed(Image)}
    else
        Failure -> fail(seed, {Id, Failure})
    end.

corpus() -> persistent_term:get({?MODULE, corpus}).

%% The mount seeds, each a partition and the blocks a mount of it reads.
mounts() -> persistent_term:get({?MODULE, mounts}).

%% The blocks a mount of Image reads, the mount's whole input, by address.
mount_seed(Image) ->
    Partition = byte_size(Image) div ?BLOCK,
    Read = fun(Addresses) ->
                   maps:from_list([{A, binary:part(Image, A * ?BLOCK, ?BLOCK)} || A <- Addresses])
           end,
    {Partition, mount_reads(Partition, Read, #{})}.

mount_reads(Partition, Read, Given) ->
    case erx_f2fs_mount:mount(Partition, ?ALLOWANCE, Given) of
        {need, Addresses} -> mount_reads(Partition, Read, maps:merge(Given, Read(Addresses)));
        _Answer -> Given
    end.

check_seeds() ->
    Super = erx_f2fs_codec_tests:superblock_block(super_fields()),
    {ok, _} = expect(seed, erx_f2fs_codec:superblock(Super)),
    [{ok, _} = expect(seed, erx_f2fs_codec:checkpoint(PackSuper, Header, Payload))
     || {PackSuper, Header, Payload} <- packs()],
    %% A corpus superblock re-encoded from its fields reads, as the cases need.
    [{ok, _} = expect(seed, erx_f2fs_codec:superblock(
                              super_block(erx_abi_packed:encode(erx_f2fs_super_block, Fields))))
     || {Fields, _Packs} <- corpus()],
    Orphans = erx_f2fs_codec_tests:orphan_block([7, 8, 9], 3),
    {ok, [7, 8, 9]} = expect(seed, erx_f2fs_codec:orphan_block(Orphans)),
    expect(seed, erx_f2fs_codec:nat_block(erx_f2fs_codec_tests:nat_block(nat_entries()))),
    expect(seed, erx_f2fs_codec:nat_journal(nat_journal(3))),
    expect(seed, erx_f2fs_codec:sit_block(erx_f2fs_codec_tests:sit_block(sit_entries()), 4)),
    expect(seed, erx_f2fs_codec:sit_journal(sit_journal(4))),
    expect(seed, erx_f2fs_codec:summary_block(erx_f2fs_codec_tests:summary_block(nat_journal(3)))),
    {Counts, Blocks} = compact(),
    expect(seed, erx_f2fs_codec:compact_summaries(Counts, Blocks)),
    [expect(seed, erx_f2fs_codec:inode(Volume, 4, erx_f2fs_codec_tests:inode_block(Volume, Fields)))
     || {Volume, Fields, _NameLengths} <- inodes()],
    {Dentries, _NameLengths} = dentry_block(),
    %% Through read/3, so a decoder that raises on its own seed fails `crash`.
    expect(seed, read(dentry_block, fun erx_f2fs_codec:dentry_block/1, [Dentries])),
    expect(seed, mount_loop(?FIXTURE_PARTITION, ?ALLOWANCE,
                            erx_f2fs_mount_tests:fixture_volume(), #{}, ?MOUNT_ROUNDS)),
    ok.

nat_entries() ->
    [erx_f2fs_codec_tests:nat_entry(N, N, 4096 + N) || N <- lists:seq(3, 12)].

nat_journal(Count) ->
    erx_f2fs_codec_tests:nat_journal(Count, [{N, erx_f2fs_codec_tests:nat_entry(1, N, 5000 + N)}
                                             || N <- lists:seq(3, 40)]).

sit_entries() ->
    [erx_f2fs_codec_tests:sit_entry(Type, lists:seq(0, Type * 50)) || Type <- lists:seq(0, 5)].

sit_journal(Count) -> sit_journal(Count, sit_entries()).

sit_journal(Count, Entries) ->
    erx_f2fs_codec_tests:sit_journal(Count, lists:zip(lists:seq(20, 25), Entries)).

%% The SIT entries, or with one entry's vblocks changed: its type, its count
%% or both set at random.
some_sit_entries() ->
    Entries = sit_entries(),
    case rand:uniform(2) of
        1 ->
            Entries;
        2 ->
            K = rand:uniform(length(Entries)),
            #{vblocks := VBlocks} = Entry = lists:nth(K, Entries),
            Changed = pick([((rand:uniform(64) - 1) bsl 10) bor (VBlocks band 16#3ff),
                            (VBlocks band 16#fc00) bor (rand:uniform(1024) - 1),
                            rand:uniform(16#10000) - 1]),
            lists:sublist(Entries, K - 1) ++ [Entry#{vblocks := Changed}]
                ++ lists:nthtail(K, Entries)
    end.

%% Compact summaries of three data logs that take two blocks.
compact() ->
    Counts = [400, 300, 12],
    Logs = [[#{nid => Log * 1000 + K, version => K rem 256, ofs_in_node => K}
             || K <- lists:seq(1, Count)] || {Log, Count} <- lists:zip([1, 2, 3], Counts)],
    {Counts, erx_f2fs_codec_tests:compact_blocks(nat_journal(2), sit_journal(1), Logs)}.

%% Inodes of each body, each with the superblock of its volume and where its
%% inline dentries' name_len fields lie in its block: the fixture's
%% addresses; inline data and inline dentries with i_extra_isize 12, their
%% content from byte 376 ([F 48]); and on a FLEXIBLE_INLINE_XATTR volume, an
%% inline directory with 10 xattr words, its content from byte 368.
inodes() ->
    Super = super_fields(),
    Fields = erx_f2fs_codec_tests:inode_fields(),
    Data = inline(Fields, 3, 50, ?ERX_F2FS_INLINE_DATA bor ?ERX_F2FS_INLINE_XATTR,
                  random_bytes(3476)),
    Names = dentries(181),
    Area = erx_f2fs_codec_tests:dentry_area(3476, {23, 37, 37 + 11 * 181}, Names),
    Directory = inline(Fields, 3, 50, ?ERX_F2FS_INLINE_DENTRY, Area),
    Flexible = Super#{feature => ?ERX_F2FS_FEATURE_EXTRA_ATTR bor
                                 ?ERX_F2FS_FEATURE_FLEXIBLE_INLINE_XATTR},
    FlexibleNames = dentries(190),
    FlexibleArea = erx_f2fs_codec_tests:dentry_area(4 * (923 - 1 - 10 - 1),
                                                    {24, 34, 34 + 11 * 190}, FlexibleNames),
    FlexibleDirectory = inline(Fields, 1, 10, ?ERX_F2FS_INLINE_DENTRY, FlexibleArea),
    [{Super, Fields, []}, {Super, Data, []},
     {Super, Directory, name_lengths(376 + 37, Names)},
     {Flexible, FlexibleDirectory, name_lengths(368 + 34, FlexibleNames)}].

%% Fields with an inline body: E extra words, X inline xattr words, the
%% inline flags Flags and Content after the reserved word; inline dentries
%% make the inode a directory of two links, and inline data a file of no
%% block but its inode's ([F 68], [F 70]).
inline(#{inode := Inode} = Fields, E, X, Flags, Content) ->
    Extra = [4 * E bor (X bsl 16) | lists:duplicate(E - 1, 0)],
    Words = Extra ++ [0 | [Word || <<Word:32/little>> <= Content]],
    Kind = case Flags band ?ERX_F2FS_INLINE_DENTRY of
               0 -> #{i_blocks => 1};
               _ -> #{i_mode => 8#40755, i_links => 2}
           end,
    Fields#{inode := maps:merge(Inode, Kind#{i_inline => ?ERX_F2FS_EXTRA_ATTR bor Flags,
                                             i_size => byte_size(Content)}),
            i_addr := Words ++ lists:duplicate(923 - length(Words), 0)}.

%% Names of 1 to 20 bytes over the first slots of Slots, and one in the last.
dentries(Slots) ->
    dentries(0, Slots, 1, []) ++ [{Slots - 1, <<"y">>, 8}].

dentries(Slot, Slots, Length, Acc) when Slot + (Length + 7) div 8 > Slots; Slot > 40 ->
    lists:reverse(Acc);
dentries(Slot, Slots, Length, Acc) ->
    Name = binary:copy(<<"n">>, Length),
    dentries(Slot + (Length + 7) div 8, Slots, Length rem 20 + 1, [{Slot, Name, 100 + Slot} | Acc]).

%% Where each dentry's name_len lies, its area's records starting at
%% RecordsAt.
name_lengths(RecordsAt, Dentries) ->
    [RecordsAt + ?ERX_F2FS_DIR_ENTRY_SIZE * Slot + ?ERX_F2FS_DIR_ENTRY_OFF_NAME_LEN
     || {Slot, _Name, _Ino} <- Dentries].

%% A dentry block and the offsets of its name_len fields, its records from
%% byte 30 ([F 59]).
dentry_block() ->
    Dentries = [{180, binary:copy(<<"z">>, 255), 9} | dentries(214)],
    {erx_f2fs_codec_tests:dentry_block(Dentries), name_lengths(30, Dentries)}.

expect(_Property, {ok, _} = Result) -> Result;
expect(Property, Result) -> fail(Property, Result).

%%% Cases

superblock_case() ->
    Fields = some_super(),
    Record = case rand:uniform(3) of
                 1 -> mutate_field(erx_f2fs_super_block, Fields);
                 2 -> mutate_bytes(erx_abi_packed:encode(erx_f2fs_super_block,
                                                         Fields), 200);
                 3 -> erx_abi_packed:encode(erx_f2fs_super_block,
                                            name_devices(Fields))
             end,
    Block = super_block(maybe_fix(Record, ?ERX_F2FS_SUPER_BLOCK_OFF_CRC)),
    outcome(superblock, read(superblock, fun erx_f2fs_codec:superblock/1, [resize(Block)])).

%% One area address moved by a non-zero amount: only [F 14] relates it to the
%% others, so the read must fail with areas.
area_case() ->
    Field = lists:nth(rand:uniform(length(?AREA_FIELDS)), ?AREA_FIELDS),
    Fields = some_super(),
    Moved = maps:get(Field, Fields) + delta(maps:get(Field, Fields)),
    Record = erx_abi_packed:encode(erx_f2fs_super_block, Fields#{Field => Moved}),
    Block = super_block(fix(Record, ?ERX_F2FS_SUPER_BLOCK_OFF_CRC)),
    case erx_f2fs_codec:superblock(Block) of
        {error, {superblock, areas}} -> {superblock, areas};
        Other -> fail(areas, {Field, Moved, Other})
    end.

checkpoint_case() ->
    {Super, Header, Payload} = some_pack(),
    <<Fixed:?ERX_F2FS_CHECKPOINT_SIZE/binary, Rest/binary>> = Header,
    Mutated = case rand:uniform(2) of
                  1 ->
                      Decoded = erx_abi_packed:decode(erx_f2fs_checkpoint, Fixed),
                      Changed = mutate_field(erx_f2fs_checkpoint, Decoded),
                      <<Changed/binary, Rest/binary>>;
                  2 ->
                      mutate_bytes(Header, 256)
              end,
    <<_:?ERX_F2FS_CHECKPOINT_OFF_CHECKSUM_OFFSET/binary, At:32/little,
      _/binary>> = Mutated,
    Block = maybe_fix(Mutated, At),
    Pages = case rand:uniform(4) of
                1 -> [];
                2 -> Payload ++ [random_bytes(?BLOCK)];
                _ -> Payload
            end,
    read(checkpoint, fun erx_f2fs_codec:checkpoint/1, [resize(Block)]),
    read(checkpoint, fun erx_f2fs_codec:checkpoint_copy/1, [resize(Block)]),
    Result = read(checkpoint, fun erx_f2fs_codec:checkpoint/3,
                  [Super, resize(Block), Pages]),
    case Result of
        {ok, #{sit_version_bitmap := Sit, nat_version_bitmap := Nat,
               sit_ver_bitmap_bytesize := SitBytes,
               nat_ver_bitmap_bytesize := NatBytes}} ->
            byte_size(Sit) =:= SitBytes andalso byte_size(Nat) =:= NatBytes
                orelse fail(size, {SitBytes, NatBytes});
        {error, _} ->
            ok
    end,
    outcome(checkpoint, Result).

orphan_case() ->
    Used = pick([0, 1, 1019, 1020, 1021, 16#ffffffff, rand:uniform(2048)]),
    Block = mutate_bytes(erx_f2fs_codec_tests:orphan_block(lists:seq(1, 10), Used),
                         ?BLOCK),
    <<_:?ERX_F2FS_ORPHAN_BLOCK_OFF_ENTRY_COUNT/binary, Claimed:32/little,
      _/binary>> = Block,
    Result = read(orphan_block, fun erx_f2fs_codec:orphan_block/1, [resize(Block)]),
    case Result of
        {ok, Inodes} when length(Inodes) =:= Claimed -> ok;
        {ok, Inodes} -> fail(size, {Claimed, length(Inodes)});
        {error, _} -> ok
    end,
    outcome(orphan_block, Result).

nat_case() ->
    Block = mutate_bytes(erx_f2fs_codec_tests:nat_block(nat_entries()), ?BLOCK),
    outcome(nat_block, read(nat_block, fun erx_f2fs_codec:nat_block/1, [resize(Block)])).

nat_journal_case() ->
    Journal = mutate_bytes(nat_journal(journal_count()), 64),
    Result = read(nat_journal, fun erx_f2fs_codec:nat_journal/1, [resize(Journal)]),
    counted(Journal, Result),
    outcome(nat_journal, Result).

sit_case() ->
    Block = mutate_bytes(erx_f2fs_codec_tests:sit_block(some_sit_entries()),
                         6 * ?ERX_F2FS_SIT_ENTRY_SIZE),
    Used = pick([0, 1, 6, 55, 56, rand:uniform(100)]),
    Result = read(sit_block, fun erx_f2fs_codec:sit_block/2, [resize(Block), Used]),
    case Result of
        {ok, Entries} when length(Entries) =:= Used -> counted_bits(Entries);
        {ok, Entries} -> fail(size, {Used, length(Entries)});
        {error, _} -> ok
    end,
    outcome(sit_block, Result).

sit_journal_case() ->
    Journal = mutate_bytes(sit_journal(journal_count(), some_sit_entries()),
                           2 + 6 * ?ERX_F2FS_SIT_JOURNAL_ENTRY_SIZE),
    Result = read(sit_journal, fun erx_f2fs_codec:sit_journal/1, [resize(Journal)]),
    counted(Journal, Result),
    case Result of
        {ok, Entries} -> counted_bits([Entry || #{entry := Entry} <- Entries]);
        {error, _} -> ok
    end,
    outcome(sit_journal, Result).

%% A count around both journals' bounds, or any.
journal_count() -> pick([0, 1, 5, 6, 7, 37, 38, 39, rand:uniform(16#10000) - 1]).

%% A journal read answers as many entries as its count claims.
counted(<<Claimed:16/little, _/binary>>, {ok, Entries}) when length(Entries) =/= Claimed ->
    fail(size, {Claimed, length(Entries)});
counted(_Journal, _Result) ->
    ok.

%% Every SIT entry read counts the bits its map sets.
counted_bits(Entries) ->
    [fail(valid_map, Entry) || #{valid_blocks := Valid, valid_map := Map} = Entry <- Entries,
                               Valid =/= lists:sum([Bit || <<Bit:1>> <= Map])],
    ok.

summary_case() ->
    Block = mutate_bytes(erx_f2fs_codec_tests:summary_block(nat_journal(3)), ?BLOCK),
    outcome(summary_block, read(summary_block, fun erx_f2fs_codec:summary_block/1,
                                [resize(Block)])).

%% The compact form's blocks, mutated, too few or too many, read for the
%% counts they hold or for others.
compact_case() ->
    {Counts, Blocks} = compact(),
    Asked = case rand:uniform(2) of
                1 -> Counts;
                2 -> [pick([0, 439, 512, 513, rand:uniform(600)]) || _ <- Counts]
            end,
    Given = case rand:uniform(4) of
                1 -> lists:sublist(Blocks, rand:uniform(length(Blocks) + 1) - 1);
                2 -> Blocks ++ [random_bytes(?BLOCK)];
                _ -> Blocks
            end,
    Mutated = [resize(mutate_bytes(Block, ?BLOCK)) || Block <- Given],
    Result = read(compact_summary, fun erx_f2fs_codec:compact_summaries/2, [Asked, Mutated]),
    case Result of
        {ok, #{summaries := Summaries}} ->
            [length(Log) || Log <- Summaries] =:= Asked orelse fail(size, Asked);
        {error, _} ->
            ok
    end,
    outcome(compact_summary, Result).

%% One of the inodes, its fixed part, extra attribute words or footer
%% changed, its bytes written at random, or a dentry's name_len set; its
%% checksum mostly fixed up; read as its own nid or another.
inode_case() ->
    {Super, #{inode := Inode, i_addr := [_ | Words], footer := Footer} = Fields,
     NameLengths} = pick(inodes()),
    {Field, Value} = inode_field(),
    Changed = case rand:uniform(5) of
                  1 -> Fields#{inode := mutated(erx_f2fs_inode, Inode)};
                  2 -> Fields#{inode := Inode#{Field := Value}};
                  3 -> Fields#{i_addr := [extra_word() | Words]};
                  4 -> Fields#{footer := mutated(erx_f2fs_node_footer, Footer)};
                  5 -> Fields
              end,
    Encoded = erx_abi_packed:encode(erx_f2fs_inode_block, Changed),
    Written = case rand:uniform(3) of
                  1 -> mutate_bytes(Encoded, ?BLOCK);
                  2 -> stretch(Encoded, NameLengths);
                  3 -> Encoded
              end,
    Block = maybe_fix_inode(Super, Written),
    Nid = case rand:uniform(10) of
              1 -> pick([0, 2, 3, 5, nid_limit() - 1, nid_limit(), rand:uniform(16#ffffffff)]);
              _ -> 4
          end,
    Result = read(inode, fun erx_f2fs_codec:inode/3, [Super, Nid, resize(Block)]),
    %% An inline directory's outcome is its dentries' read.
    case Result of
        {ok, Read} ->
            case check_inode(Read) of
                ok -> outcome(inode, Result);
                DentriesOutcome -> DentriesOutcome
            end;
        {error, _} ->
            outcome(inode, Result)
    end.

%% The fixture volume's NAT capacity, of its two NAT segments ([F 36]).
nid_limit() -> ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG.

%% A field of the inode's fixed part and a value at the edge of a rule.
inode_field() ->
    pick([{i_blocks, pick([0, 1, 2, 3])},
          {i_xattr_nid, pick([0, 1, 3, 4, 9, nid_limit()])},
          {i_flags, pick([0, ?ERX_F2FS_CASEFOLD_FL, ?ERX_F2FS_DEVICE_ALIAS_FL,
                          ?ERX_F2FS_COMPR_FL])},
          {i_mode, pick([8#644, 8#10644, 8#20644, 8#30644, 8#40755, 8#60644, 8#100644,
                         8#120777, 8#140644, 8#170644])},
          {i_links, pick([0, 1, 2])},
          {i_advise, pick([0, ?ERX_F2FS_ADVISE_ENCRYPT, ?ERX_F2FS_ADVISE_VERITY])},
          {i_inline, rand:uniform(256) - 1},
          {i_namelen, pick([255, 256])},
          {i_size, pick([0, 3476, 3477])},
          {i_current_depth, pick([0, 1, 63, 64, 16#ffffffff])}]).

%% i_extra_isize and i_inline_xattr_size around their bounds.
extra_word() ->
    Size = pick([0, 2, 4, 8, 12, 13, 14, 24, 36, 37, 40, rand:uniform(16#10000) - 1]),
    Words = pick([0, 5, 6, 10, 50, 903, 904, rand:uniform(16#10000) - 1]),
    Size bor (Words bsl 16).

maybe_fix_inode(#{feature := Feature} = Super, Block)
  when Feature band ?ERX_F2FS_FEATURE_INODE_CHKSUM =/= 0, byte_size(Block) =:= ?BLOCK ->
    case rand:uniform(10) of
        1 -> Block;
        _ -> erx_f2fs_codec_tests:with_inode_checksum(Super, Block)
    end;
maybe_fix_inode(_Super, Block) ->
    Block.

%% An inode read has a whole number of words of extra attributes, inline
%% data of its size, dentries within their slots, and, for a directory, at
%% most 63 hash levels.
check_inode(#{i_mode := Mode, i_current_depth := Depth})
  when Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_DIR,
       Depth > ?ERX_F2FS_DIR_HASH_DEPTH_MAX ->
    fail(current_depth, Depth);
check_inode(#{i_extra_isize := Size}) when Size rem 4 =/= 0 ->
    fail(extra_isize, Size);
check_inode(#{inline_data := Data, i_size := Size}) when byte_size(Data) =/= Size ->
    fail(size, {Size, byte_size(Data)});
check_inode(#{inline_dentries := _} = Inode) ->
    case read(inline_dentries, fun erx_f2fs_codec:inline_dentries/1, [Inode]) of
        {ok, Dentries} -> check_dentries(Dentries), {inline_dentries, ok};
        Failed -> outcome(inline_dentries, Failed)
    end;
check_inode(_Inode) ->
    ok.

check_dentries(#{bitmap := Bitmap, entries := Entries}) ->
    [fail(size, Entry) || #{slot := Slot, name := Name} = Entry <- Entries,
                          byte_size(Name) > ?ERX_F2FS_NAME_LEN_MAX orelse
                              Slot + (byte_size(Name) + 7) div 8 > bit_size(Bitmap)],
    ok.

dentry_case() ->
    {Block, NameLengths} = dentry_block(),
    Written = case rand:uniform(2) of
                  1 -> mutate_bytes(Block, ?BLOCK);
                  2 -> stretch(Block, NameLengths)
              end,
    Result = read(dentry_block, fun erx_f2fs_codec:dentry_block/1, [resize(Written)]),
    case Result of
        {ok, Dentries} -> check_dentries(Dentries);
        {error, _} -> ok
    end,
    outcome(dentry_block, Result).

%% One used slot's name_len, at one of the offsets given, set around the
%% bounds a name's length and its run have.
stretch(Block, []) ->
    Block;
stretch(Block, NameLengths) ->
    At = pick(NameLengths),
    Length = pick([0, 1, 8, 9, 64, 255, 256, rand:uniform(16#10000) - 1]),
    <<Before:At/binary, _:16, After/binary>> = Block,
    <<Before/binary, Length:16/little, After/binary>>.

%% Runs one read; anything but {ok, _} or {error, {Structure, Rule}} fails.
%% A whole mount of a seed with one block mutated, its checksum mostly fixed
%% up when it is a checkpoint header or copy or an inode, under an allowance
%% that may be too small for its SIT.
mount_case() ->
    {Partition, Blocks} = pick(mounts()),
    Address = pick(lists:sort(maps:keys(Blocks))),
    Old = maps:get(Address, Blocks),
    New = case rand:uniform(3) of
              1 -> mutate_bytes(Old, ?BLOCK);
              2 -> write_word(Old, word_offset(), word_value(Partition));
              3 -> nat_entry_address(Old, word_value(Partition))
          end,
    Mutated = Blocks#{Address := fix_mount_block(Blocks, Old, New)},
    Allowance = pick([?ALLOWANCE, ?ALLOWANCE, rand:uniform(1 bsl 16)]),
    outcome(mount, mount_loop(Partition, Allowance, Mutated, #{}, ?MOUNT_ROUNDS)).

%% The mount's need loop over Blocks, a block Blocks lacks reading as
%% zeros: every address it asks for lies inside the partition and was not
%% given before (`partition`, `repeat`), it ends within Rounds needs
%% (`rounds`), and it answers {ok, Mounted} or {error, {Structure, Rule}}.
mount_loop(Partition, Allowance, Blocks, Given, Rounds) ->
    try erx_f2fs_mount:mount(Partition, Allowance, Given) of
        {need, [_ | _] = Addresses} when Rounds > 0 ->
            [fail(partition, {Address, Partition})
             || Address <- Addresses, not is_integer(Address) orelse Address < 0 orelse
                                          Address >= Partition],
            [fail(repeat, Address) || Address <- Addresses, is_map_key(Address, Given)],
            Read = maps:from_list([{A, maps:get(A, Blocks, <<0:(?BLOCK * 8)>>)} || A <- Addresses]),
            mount_loop(Partition, Allowance, Blocks, maps:merge(Given, Read), Rounds - 1);
        {need, _} = Need -> fail(rounds, Need);
        {ok, #{}} = Result -> Result;
        {error, {_Structure, _Rule}} = Result -> Result;
        Other -> fail(shape, Other)
    catch
        Class:Reason:Stack -> fail(crash, {mount, Class, Reason, hd(Stack)})
    end.

%% A direct or indirect node of the fixture file, its bytes or a footer word
%% mutated, read as the node its parent names: it answers a word for each
%% slot (`size`).
node_case() ->
    {Kind, Nid, Offset, Block} = pick(erx_f2fs_core_tests:fixture_nodes()),
    Mutated = case rand:uniform(3) of
                  1 -> mutate_bytes(Block, ?BLOCK);
                  2 -> write_word(Block, pick([4072, 4076, 4080]),
                                  pick([0, Nid, Nid + 1, ?FILE_INO, ?FILE_INO + 1,
                                        Offset bsl ?ERX_F2FS_NODE_MARK_BITS,
                                        (Offset + 1) bsl ?ERX_F2FS_NODE_MARK_BITS,
                                        rand:uniform(16#ffffffff)]));
                  3 -> Block
              end,
    Result = read(Kind, fun erx_f2fs_codec:Kind/4, [Nid, ?FILE_INO, Offset, resize(Mutated)]),
    case Result of
        {ok, Words} when length(Words) =/= ?ERX_F2FS_ADDRS_PER_BLOCK -> fail(size, {Kind, length(Words)});
        _ -> ok
    end,
    outcome(Kind, Result).

%% The fixture file with one of its blocks mutated, by bytes or by a word set
%% to a nid, an address or a node offset, or with its inode's slot 0 naming
%% one of its node blocks, then a slot, a read of up to four blocks or the
%% file read as a symlink's target, through the need loop.
walk_case() ->
    {#{superblock := Super} = Volume, Blocks} = erx_f2fs_core_tests:fixture_file(),
    {Address, New} = walk_mutation(Blocks),
    Mutated = Blocks#{Address := maybe_fix_inode(Super, New)},
    Block = file_block(),
    Length = rand:uniform(4 * ?BLOCK),
    Op = case rand:uniform(3) of
             1 -> fun(Inode, Given) -> erx_f2fs_core:slot(Volume, Inode, Block, Given) end;
             2 -> fun(Inode, Given) ->
                          erx_f2fs_core:read(Volume, Inode, Block * ?BLOCK + rand:uniform(?BLOCK) - 1,
                                             Length, Given)
                  end;
             3 -> fun(Inode, Given) ->
                          erx_f2fs_core:symlink(Volume, Inode#{i_mode := 8#120777}, Given)
                  end
         end,
    Step = fun(Given) ->
                   case erx_f2fs_core:inode(Volume, ?FILE_INO, Given) of
                       {ok, Inode} -> Op(Inode, Given);
                       Other -> Other
                   end
           end,
    Result = walk_loop(Step, Mutated, #{}, ?WALK_ROUNDS),
    case Result of
        {ok, Bytes} when is_binary(Bytes), byte_size(Bytes) > max(Length, ?BLOCK) ->
            fail(size, byte_size(Bytes));
        {ok, {_Nid, _Index, SlotAddress} = Slot}
          when SlotAddress =/= ?ERX_F2FS_NULL_ADDR, SlotAddress =/= ?ERX_F2FS_NEW_ADDR ->
            data_block(Volume, SlotAddress) orelse fail(kind, Slot);
        _ ->
            ok
    end,
    outcome(walk, Result).

%% A block of the fixture file and its mutation. The inode lies at the main
%% area's second block and its six nodes after it; its slot 0 follows three
%% words of extra attributes.
walk_mutation(Blocks) ->
    case rand:uniform(4) of
        4 ->
            Inode = ?FIXTURE_MAIN + 1,
            {Inode, write_word(maps:get(Inode, Blocks), ?ERX_F2FS_INODE_BLOCK_OFF_I_ADDR + 4 * 3,
                               Inode + rand:uniform(7) - 1)};
        Kind ->
            Address = pick(lists:sort(maps:keys(Blocks))),
            Old = maps:get(Address, Blocks),
            {Address, case Kind of
                          1 -> mutate_bytes(Old, ?BLOCK);
                          2 -> write_word(Old, walk_offset(), walk_value());
                          3 -> Old
                      end}
    end.

%% Whether Address is a main area block the SIT marks valid in a segment it
%% gives a data log ([F 21], [F 37]).
data_block(#{superblock := #{main_blkaddr := Main}, sit := Sit}, Address) ->
    Segment = (Address - Main) div (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG),
    Address >= Main andalso Segment < tuple_size(Sit) andalso
        case element(Segment + 1, Sit) of
            #{type := Type, valid_map := Map} ->
                Type < ?ERX_F2FS_LOG_HOT_NODE andalso
                    erx_f2fs_codec:bit(Map, (Address - Main) rem (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)) =:= 1
        end.

%% The fixture directory with one of its blocks mutated, by bytes or by a
%% word set where its bitmap, a dentry record, or the inode's depth, level,
%% size or address words lie, then a lookup of one of its names or a
%% readdir from a position, through the need loop: every name answered is
%% one a path can hold (`name`), and a readdir answers no entry before its
%% position and a next position past it (`position`).
dir_case() ->
    {#{superblock := Super} = Volume, Blocks} = erx_f2fs_core_tests:fixture_directory(),
    Address = pick(lists:sort(maps:keys(Blocks))),
    Old = maps:get(Address, Blocks),
    New = case rand:uniform(3) of
              1 -> mutate_bytes(Old, ?BLOCK);
              2 -> write_word(Old, dir_offset(), pick([walk_value(), 0, 1, 2, 31, 63, 64, 255]));
              3 -> Old
          end,
    Mutated = Blocks#{Address := maybe_fix_inode(Super, New)},
    Name = pick(erx_f2fs_core_tests:fixture_names()),
    Position = pick([0, 1, 2, 213, 214, 8 * 214, 13 * 214 + 5, rand:uniform(1 bsl 32)]),
    Op = case rand:uniform(2) of
             1 -> fun(Dir, Given) -> erx_f2fs_core:lookup(Volume, Dir, Name, Given) end;
             2 -> fun(Dir, Given) -> erx_f2fs_core:readdir(Volume, Dir, Position, Given) end
         end,
    Step = fun(Given) ->
                   case erx_f2fs_core:inode(Volume, ?FILE_INO, Given) of
                       {ok, Dir} -> Op(Dir, Given);
                       Other -> Other
                   end
           end,
    Result = walk_loop(Step, Mutated, #{}, ?DIR_ROUNDS),
    case Result of
        {ok, {Entries, Next}} ->
            [fail(position, {Position, At}) || #{position := At} <- Entries, At < Position],
            case Next =:= done orelse Next > Position of
                true -> ok;
                false -> fail(position, {Position, Next})
            end,
            lists:foreach(fun check_name/1, Entries);
        {ok, #{} = Entry} ->
            check_name(Entry);
        _ ->
            ok
    end,
    outcome(dir, Result).

check_name(#{name := Name} = Entry) ->
    case Name =/= <<>> andalso binary:match(Name, [<<"/">>, <<0>>]) =:= nomatch of
        true -> ok;
        false -> fail(name, Entry)
    end.

%% A byte of a dentry block's bitmap, a record's hash, ino or name_len, the
%% inode's depth, level, size or first address words, else anywhere.
dir_offset() ->
    case rand:uniform(4) of
        1 -> rand:uniform(27) - 1;
        2 -> 30 + 11 * (rand:uniform(48) - 1) + pick([0, 4, 8]);
        3 -> pick([?ERX_F2FS_INODE_OFF_I_CURRENT_DEPTH, ?ERX_F2FS_INODE_OFF_I_DIR_LEVEL,
                   ?ERX_F2FS_INODE_OFF_I_SIZE, ?ERX_F2FS_INODE_OFF_I_SIZE + 4,
                   ?ERX_F2FS_INODE_BLOCK_OFF_I_ADDR + 4 * (2 + rand:uniform(14))]);
        4 -> 4 * (rand:uniform(?BLOCK div 4) - 1)
    end.

%% The walk's need loop over Blocks, as mount_loop's: every address inside
%% the NAT or the main area of the partition and not given before, within
%% Rounds needs, which bounds a walk's work by the nodes on its paths.
walk_loop(Step, Blocks, Given, Rounds) ->
    try Step(Given) of
        {need, [_ | _] = Addresses} when Rounds > 0 ->
            [fail(partition, {Address, ?FIXTURE_PARTITION})
             || Address <- Addresses, not is_integer(Address) orelse Address < ?FIXTURE_NAT orelse
                                          (Address >= ?FIXTURE_NAT + 2 * 512 andalso
                                               Address < ?FIXTURE_MAIN) orelse
                                          Address >= ?FIXTURE_PARTITION],
            [fail(repeat, Address) || Address <- Addresses, is_map_key(Address, Given)],
            Read = maps:from_list([{A, maps:get(A, Blocks, <<0:(?BLOCK * 8)>>)} || A <- Addresses]),
            walk_loop(Step, Blocks, maps:merge(Given, Read), Rounds - 1);
        {need, _} = Need -> fail(rounds, Need);
        {ok, _} = Result -> Result;
        {error, {_Structure, _Rule}} = Result -> Result;
        Other -> fail(shape, Other)
    catch
        Class:Reason:Stack -> fail(crash, {walk, Class, Reason, hd(Stack)})
    end.

%% A word where a node's slots, an inode's address array or node ids, or a
%% footer's nid, ino and flag lie, else anywhere.
walk_offset() ->
    case rand:uniform(5) of
        1 -> 4 * (rand:uniform(4) - 1);
        2 -> ?ERX_F2FS_INODE_BLOCK_OFF_I_ADDR + 4 * (rand:uniform(8) - 1);
        3 -> ?ERX_F2FS_INODE_BLOCK_OFF_I_NID + 4 * (rand:uniform(?ERX_F2FS_NIDS_PER_INODE) - 1);
        4 -> pick([4072, 4076, 4080]);
        5 -> 4 * (rand:uniform(?BLOCK div 4) - 1)
    end.

walk_value() ->
    pick([0, 1, 3, ?FILE_INO, 5 + rand:uniform(6), 11, ?ERX_F2FS_NEW_ADDR, 16#fffffffe,
          4096 + rand:uniform(16), 5632 + rand:uniform(8), ?FIXTURE_PARTITION - 1,
          ?FIXTURE_PARTITION, rand:uniform(16#ffffffff),
          pick([1, 2, 3, 5, 1022, 2041, 2042, 2044]) bsl ?ERX_F2FS_NODE_MARK_BITS]).

%% A file block in the fixture file's address array, at its nodes' edges, or
%% anywhere.
file_block() ->
    pick([0, 1, 2, 919, 920, 921, 1937, 1938, 2956, 3976, 2075604, 2076625,
          rand:uniform(1 bsl 31)]).

%% A checkpoint header or copy keeps a valid checksum in nine cases of ten,
%% and an inode block of a volume with inode checksums too.
fix_mount_block(Blocks, Old, New) ->
    case erx_f2fs_codec:checkpoint_copy(Old) of
        {ok, #{checksum_offset := At}} ->
            maybe_fix(New, At);
        {error, _} ->
            case erx_f2fs_codec:superblock(maps:get(0, Blocks)) of
                {ok, Super} -> maybe_fix_inode(Super, New);
                {error, _} -> New
            end
    end.

%% A word among a block's first sixteen in a case of four, where the
%% records' counts and the first entries lie, else anywhere.
word_offset() ->
    case rand:uniform(4) of
        1 -> 4 * (rand:uniform(16) - 1);
        _ -> 4 * (rand:uniform(?BLOCK div 4) - 1)
    end.

word_value(Partition) ->
    pick([0, 1, Partition - 1, Partition, Partition + 1, 16#ffffffff,
          rand:uniform(Partition), rand:uniform(16#ffffffff)]).

write_word(Block, At, Value) when At + 4 =< byte_size(Block) ->
    <<Before:At/binary, _:32, After/binary>> = Block,
    <<Before/binary, Value:32/little, After/binary>>;
write_word(Block, _At, _Value) ->
    Block.

%% The block's NAT entry for the root, nid 3, or a random one, pointed at
%% Value, as if the block were NAT block 0 ([F 33]).
nat_entry_address(Block, Value) ->
    Entry = pick([?ERX_F2FS_ROOT_INO, rand:uniform(?ERX_F2FS_NAT_ENTRIES_PER_BLOCK) - 1]),
    write_word(Block, Entry * ?ERX_F2FS_NAT_ENTRY_SIZE + ?ERX_F2FS_NAT_ENTRY_OFF_BLOCK_ADDR, Value).

read(Structure, Read, Arguments) ->
    try apply(Read, Arguments) of
        {ok, Value} = Result -> checked_round_trip(Structure, Arguments, Value), Result;
        {error, {Structure, Rule}} = Result when is_atom(Rule) -> Result;
        Other -> fail(shape, Other)
    catch
        Class:Reason:Stack -> fail(crash, {Structure, Class, Reason, hd(Stack)})
    end.

%% A value read decodes back from its encoding, for each reader of a record
%% that has an encoder, read with the arguments it was read with. A
%% checksum is derived: the encoder computes it over the block it builds,
%% which holds zeros where a mutated block held bytes no value describes, so
%% it is left out of the comparison. An inode is written in the form erXos
%% writes, i_ext with len 0. An encoder that cannot build a value read fails
%% the round trip too.
checked_round_trip(Structure, Arguments, Value) ->
    try
        round_trip(Structure, Arguments, Value)
    catch
        error:Reason:Stack -> fail(round_trip, {Structure, Reason, hd(Stack)})
    end.

round_trip(superblock, [_Block], Super) ->
    same(Super, erx_f2fs_codec:superblock(erx_f2fs_codec:encode_superblock(Super)), crc);
round_trip(checkpoint, [Super, _Block, _Payload], Checkpoint) ->
    {Header, Payload} = erx_f2fs_codec:encode_checkpoint(Super, Checkpoint),
    same(Checkpoint, erx_f2fs_codec:checkpoint(Super, Header, Payload), crc);
round_trip(orphan_block, [_Block], Inodes) ->
    same(Inodes, erx_f2fs_codec:orphan_block(erx_f2fs_codec:encode_orphan_block(Inodes, 1, 1)));
round_trip(nat_block, [_Block], Entries) ->
    same(Entries, erx_f2fs_codec:nat_block(erx_f2fs_codec:encode_nat_block(Entries)));
round_trip(sit_block, [_Block, Used], Entries) ->
    same(Entries, erx_f2fs_codec:sit_block(erx_f2fs_codec:encode_sit_block(Entries), Used));
round_trip(summary_block, [_Block], #{entries := Entries, entry_type := Type} = Summary) ->
    same(Summary#{journal := erx_f2fs_codec:empty_journal()},
         erx_f2fs_codec:summary_block(erx_f2fs_codec:encode_summary_block(Entries, Type)));
round_trip(inode, [Super, Nid, _Block], #{addresses := _, i_ext := Extent} = Inode) ->
    Written = Inode#{i_ext := Extent#{len := 0}},
    same(Written, erx_f2fs_codec:inode(Super, Nid, erx_f2fs_codec:encode_inode(Super, Written)),
         i_inode_checksum);
round_trip(Node, [Nid, Ino, Offset, Block], Words)
  when Node =:= direct_node; Node =:= indirect_node ->
    {ok, Footer} = erx_f2fs_codec:node_footer(Block),
    Encoded = case Node of
                  direct_node -> erx_f2fs_codec:encode_direct_node(Words, Footer);
                  indirect_node -> erx_f2fs_codec:encode_indirect_node(Words, Footer)
              end,
    same(Words, erx_f2fs_codec:Node(Nid, Ino, Offset, Encoded)),
    same(Footer, erx_f2fs_codec:node_footer(Encoded));
round_trip(dentry_block, [_Block], Dentries) ->
    same(Dentries, erx_f2fs_codec:dentry_block(erx_f2fs_codec:encode_dentry_block(Dentries)));
round_trip(_Structure, _Arguments, _Value) ->
    ok.

same(Value, {ok, Value}) -> ok;
same(Value, Other) -> fail(round_trip, {Value, Other}).

%% The same, but for the checksum a map holds at Checksum.
same(Value, {ok, Read}, Checksum) -> same(maps:remove(Checksum, Value), {ok, maps:remove(Checksum, Read)});
same(Value, Other, _Checksum) -> same(Value, Other).

outcome(Structure, {ok, _}) -> {Structure, ok};
outcome(_Structure, {error, {Failed, Rule}}) when is_tuple(Rule) -> {Failed, element(1, Rule)};
outcome(_Structure, {error, Failure}) -> Failure.

tally(Outcomes) ->
    lists:foldl(fun(Outcome, Counts) ->
                        maps:update_with(Outcome, fun(Times) -> Times + 1 end, 1, Counts)
                end, #{}, Outcomes).

%%% Mutations

%% A layout's bytes with one integer field set to a boundary or random value,
%% narrowed until encode/2 takes it, so the field's width is the layout's own;
%% arrays and byte fields are left to the byte writes.
mutate_field(Layout, Fields) ->
    erx_abi_packed:encode(Layout, mutated(Layout, Fields)).

%% Fields with one integer field so changed.
mutated(Layout, Fields) ->
    Integers = [Field || {Field, Value} <- maps:to_list(Fields), is_integer(Value)],
    Field = pick(lists:sort(Integers)),
    Old = maps:get(Field, Fields),
    Value = pick([0, 1, Old + 1, max(Old - 1, 0), 16#ff, 16#ffff, 16#ffffffff,
                  rand:uniform(16#ffffffff), rand:uniform(8192)]),
    Narrowed = [Value band Mask || Mask <- [16#ffffffffffffffff, 16#ffffffff,
                                            16#ffff, 16#ff]],
    hd([Changed || Candidate <- Narrowed,
                   Changed <- [Fields#{Field => Candidate}],
                   encodes(Layout, Changed)]).

encodes(Layout, Fields) ->
    try erx_abi_packed:encode(Layout, Fields) of
        _ -> true
    catch
        error:_ -> false
    end.

%% The device list's first one or two devices named, with segments that may
%% or may not add up to the volume's.
name_devices(#{devs := [First, Second | Rest], segment_count := Segments} = Fields) ->
    Named = fun(Device, Total) -> Device#{path := <<"/dev/f2fs", 0:440>>,
                                          total_segments := Total} end,
    Split = rand:uniform(Segments + 1) - 1,
    Devices = case rand:uniform(3) of
                  1 -> [Named(First, Segments), Second | Rest];
                  2 -> [Named(First, Split), Named(Second, Segments - Split) | Rest];
                  3 -> [Named(First, rand:uniform(64)), Second | Rest]
              end,
    Fields#{devs := Devices}.

%% Between one and eight byte writes, mostly within the first Bias bytes.
mutate_bytes(Bytes, Bias) ->
    lists:foldl(fun(_, Acc) ->
                        Limit = case rand:uniform(4) of
                                    1 -> byte_size(Acc);
                                    _ -> min(Bias, byte_size(Acc))
                                end,
                        At = rand:uniform(Limit) - 1,
                        <<Before:At/binary, _, After/binary>> = Acc,
                        <<Before/binary, (rand:uniform(256) - 1), After/binary>>
                end, Bytes, lists:seq(1, rand:uniform(8))).

%% The checksum fixed up in nine cases of ten, and only where it fits.
maybe_fix(Bytes, At) ->
    case rand:uniform(10) of
        1 -> Bytes;
        _ -> fix(Bytes, At)
    end.

fix(Bytes, At) when At + 4 =< byte_size(Bytes) ->
    <<Before:At/binary, _:32, After/binary>> = Bytes,
    Crc = erx_f2fs_codec_tests:crc_reference(?ERX_F2FS_MAGIC,
                                             <<Before/binary, After/binary>>),
    <<Before/binary, Crc:32/little, After/binary>>;
fix(Bytes, _At) -> Bytes.

super_block(Record) ->
    Tail = ?BLOCK - ?ERX_F2FS_SUPER_OFFSET - byte_size(Record),
    <<0:(?ERX_F2FS_SUPER_OFFSET * 8), Record/binary, 0:(Tail * 8)>>.

%% The block itself in most cases, else one cut short or one byte too long.
resize(Block) ->
    case rand:uniform(20) of
        1 -> binary:part(Block, 0, rand:uniform(byte_size(Block)) - 1);
        2 -> <<Block/binary, 0>>;
        _ -> Block
    end.

%% A non-zero move of an address at Value that keeps it non-negative.
delta(0) ->
    pick([1, 2, 511, 512, 1024, rand:uniform(100000)]);
delta(Value) ->
    Magnitude = pick([1, 2, 511, 512, 1024, rand:uniform(100000)]),
    pick([Magnitude, -min(Magnitude, Value)]).

pick(List) -> lists:nth(rand:uniform(length(List)), List).

random_bytes(Count) -> rand:bytes(Count).
