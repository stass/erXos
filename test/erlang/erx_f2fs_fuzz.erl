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
%% dentry's name must end by its area's last slot (`size`). A run reaches every
%% rule of ?REACHED (failure `unreached`).
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
                                      inline_data | ?DENTRY_RULES]]
        ++ [{dentry_block, Rule} || Rule <- [ok, block_size | ?DENTRY_RULES]]).
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
             fun dentry_case/0],
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
    persistent_term:put({?MODULE, corpus},
                        [corpus_image(ThirdParty, Pin) || Pin <- erx_f2fs_corpus:pins(Lock)]).

corpus_image(ThirdParty, #{id := Id} = Pin) ->
    maybe
        {ok, Image} ?= erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(ThirdParty, Pin)),
        {ok, Super, Packs} ?= erx_f2fs_corpus:metadata(Image),
        {Super, Packs}
    else
        Failure -> fail(seed, {Id, Failure})
    end.

corpus() -> persistent_term:get({?MODULE, corpus}).

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
    expect(seed, erx_f2fs_codec:dentry_block(Dentries)),
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
    case Result of
        {ok, Read} -> check_inode(Read);
        {error, _} -> ok
    end,
    outcome(inode, Result).

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
check_inode(#{inline_dentries := Dentries}) ->
    check_dentries(Dentries);
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
read(Structure, Read, Arguments) ->
    try apply(Read, Arguments) of
        {ok, _} = Result -> Result;
        {error, {Structure, Rule}} = Result when is_atom(Rule) -> Result;
        Other -> fail(shape, Other)
    catch
        Class:Reason:Stack -> fail(crash, {Structure, Class, Reason, hd(Stack)})
    end.

outcome(Structure, {ok, _}) -> {Structure, ok};
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
