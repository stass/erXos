%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% F2FS's node tree, read, erx_f2fs_core (docs/design-f2fs.md, "Inodes" and
%% "Operations"): a file of erx_f2fs_mount_tests' fixture volume with every
%% kind of node, each refusal by a crafted change to it, and the files of the
%% corpus images that mount, each block's slot checked against the summary
%% Linux wrote for its block.
-module(erx_f2fs_core_tests).
-export([fixture_file/0, fixture_nodes/0, fixture_directory/0, fixture_names/0]).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
-define(SEGMENT, 512).
-define(PARTITION, 16384).
-define(MAIN, 4096).
%% The fixture's first data segment, segment 3, and its first node segment.
-define(DATA, (?MAIN + 3 * ?SEGMENT)).
-define(NODES, ?MAIN).
-define(NEW, ?ERX_F2FS_NEW_ADDR).
%% The test file's inode and nodes, by nid: the inode, direct node 1,
%% indirect node 1 with its second direct child, and the double indirect
%% node with its first indirect child and that child's second direct child.
-define(INO, 4).
-define(DIRECT1, 5).
-define(INDIRECT1, 6).
-define(DOUBLE, 7).
-define(CHILD, 8).
-define(GRANDCHILD, 9).
-define(DOUBLE_DIRECT, 10).
%% The address array's slots with i_extra_isize 12 and no inline xattrs.
-define(SLOTS, (?ERX_F2FS_ADDRS_PER_INODE - 3)).
-define(PER, 1018).
%% The file blocks the test file maps through each node ([F 53]).
-define(B_DIRECT1, ?SLOTS).
-define(B_INDIRECT1, (?SLOTS + 2 * ?PER)).
-define(B_DOUBLE, (?B_INDIRECT1 + 2 * ?PER * ?PER)).

%%% The fixture file

%% The fixture volume as mounted, with Nodes, {Nid, Owner, Address}, in its
%% NAT journal and every block of Valid valid in its SIT.
volume(Nodes, Valid) ->
    Volume = mounted(),
    Nat = maps:from_list([{Nid, erx_f2fs_codec_tests:nat_entry(0, Owner, Address)}
                          || {Nid, Owner, Address} <- Nodes]),
    Volume#{nat := nat(Volume, Nat), sit := valid(maps:get(sit, Volume), Valid)}.

mounted() ->
    Blocks = erx_f2fs_mount_tests:fixture_volume(),
    {ok, Volume} = need_loop(fun(Given) -> erx_f2fs_mount:mount(?PARTITION, 1 bsl 30, Given) end,
                             Blocks),
    Volume.

valid(Sit, Addresses) ->
    lists:foldl(fun(Address, Table) ->
                        Segment = (Address - ?MAIN) div ?SEGMENT + 1,
                        Offset = (Address - ?MAIN) rem ?SEGMENT,
                        #{valid_map := Map} = Entry = element(Segment, Table),
                        <<Before:Offset, _:1, After/bitstring>> = Map,
                        setelement(Segment, Table, Entry#{valid_map := <<Before:Offset, 1:1, After/bitstring>>})
                end, Sit, Addresses).

%% The node at offset Offset of the test file, Words its addresses or nids.
node(Layout, Field, Nid, Offset, Words) ->
    Padded = Words ++ lists:duplicate(?PER - length(Words), 0),
    erx_abi_packed:encode(Layout, #{Field => Padded,
                                    footer => #{nid => Nid, ino => ?INO,
                                                flag => Offset bsl ?ERX_F2FS_NODE_MARK_BITS,
                                                cp_ver => 1, next_blkaddr => 0}}).

direct(Nid, Offset, Words) -> node(erx_f2fs_direct_node, addr, Nid, Offset, Words).

indirect(Nid, Offset, Words) -> node(erx_f2fs_indirect_node, nid, Nid, Offset, Words).

%% Words with Value at Index and zeros before it.
at(Index, Value) -> lists:duplicate(Index, 0) ++ [Value].

data(N) -> binary:copy(<<N>>, ?BLOCK).

%% The test file: slot 0 at data block 0, slot 1 NEW_ADDR, the rest of its
%% array holes; then data block 1 at slot 0 and data block 2 at the last
%% slot of direct node 1, data block 3 at slot 2 of indirect node 1's second
%% child, and data block 4 at slot 3 of the double indirect node's first
%% indirect child's second direct child. Direct node 2 and indirect node 2
%% are absent.
file_inode(Changes) ->
    #{inode := Inode, i_addr := Words} = Fields = erx_f2fs_codec_tests:inode_fields(),
    {Extra, _} = lists:split(3, Words),
    Addresses = [?DATA, ?NEW | lists:duplicate(?SLOTS - 2, 0)],
    maps:merge(Fields#{inode := Inode#{i_size := (?B_DOUBLE + ?PER + 4) * ?BLOCK, i_blocks := 12},
                       i_addr := Extra ++ Addresses,
                       i_nid := [?DIRECT1, 0, ?INDIRECT1, 0, ?DOUBLE]},
               Changes).

file_nodes() ->
    [{?INO, ?NODES + 1, inode},
     {?DIRECT1, ?NODES + 2, direct(?DIRECT1, 1, [?DATA + 1 | at(?PER - 2, ?DATA + 2)])},
     {?INDIRECT1, ?NODES + 3, indirect(?INDIRECT1, 3, at(1, ?CHILD))},
     {?CHILD, ?NODES + 4, direct(?CHILD, 5, at(2, ?DATA + 3))},
     {?DOUBLE, ?NODES + 5, indirect(?DOUBLE, 2041, [?GRANDCHILD])},
     {?GRANDCHILD, ?NODES + 6, indirect(?GRANDCHILD, 2042, at(1, ?DOUBLE_DIRECT))},
     {?DOUBLE_DIRECT, ?NODES + 7, direct(?DOUBLE_DIRECT, 2044, at(3, ?DATA + 4))}].

%% The fixture volume holding the test file with Changes to its inode
%% fields and Replaced nodes, {Nid, Block}; its NAT, valid blocks and
%% blocks by address.
file(Changes, Replaced) ->
    Super = maps:get(superblock, mounted()),
    Nodes = [{Nid, Address, proplists:get_value(Nid, Replaced, Block)}
             || {Nid, Address, Block} <- file_nodes()],
    Inode = erx_f2fs_codec_tests:inode_block(Super, file_inode(Changes)),
    Blocks = maps:from_list([{Address, case Block of inode -> Inode; _ -> Block end}
                             || {_Nid, Address, Block} <- Nodes]
                            ++ [{?DATA + N, data(N + 1)} || N <- lists:seq(0, 4)]
                            %% Block 0 is no zeros, so a hole read from it shows.
                            ++ [{0, data(16#ee)}]),
    Valid = [Address || {_Nid, Address, _} <- Nodes] ++ [?DATA + N || N <- lists:seq(0, 4)],
    {volume([{Nid, ?INO, Address} || {Nid, Address, _} <- Nodes], Valid), Blocks}.

file() -> file(#{}, []).

%% erx_f2fs_fuzz's seeds: the test file's volume and blocks, and each of its
%% direct and indirect nodes with the nid and node offset its parent gives,
%% an indirect node's offset being 3, 1022, 2041 or 2042 + 1019k ([F 53]).
fixture_file() -> file().

fixture_nodes() ->
    [{case lists:member(Offset, [3, 2041, 2042]) of
          true -> indirect_node;
          false -> direct_node
      end, Nid, Offset, Block}
     || {Nid, _Address, Block} <- file_nodes(), is_binary(Block),
        #{flag := Flag} <- [footer(Block)], Offset <- [Flag bsr ?ERX_F2FS_NODE_MARK_BITS]].

footer(Block) ->
    {ok, Footer} = erx_f2fs_codec:node_footer(Block),
    Footer.

%% Answers a need loop over Blocks: each {need, Addresses} must name blocks
%% inside the partition not given before, and is answered with those
%% blocks, a zero block for any Blocks lacks, within 16 rounds.
need_loop(Step, Blocks) -> need_loop(Step, Blocks, #{}, 16).

need_loop(Step, Blocks, Given, Rounds) ->
    case Step(Given) of
        {need, Addresses} when Rounds > 0 ->
            ?assertEqual([], [A || A <- Addresses, is_map_key(A, Given) orelse A >= ?PARTITION]),
            Read = maps:from_list([{A, maps:get(A, Blocks, <<0:(?BLOCK * 8)>>)} || A <- Addresses]),
            need_loop(Step, Blocks, maps:merge(Given, Read), Rounds - 1);
        Answer ->
            Answer
    end.

inode({Volume, Blocks}) ->
    {ok, Inode} = need_loop(fun(Given) -> erx_f2fs_core:inode(Volume, ?INO, Given) end, Blocks),
    Inode.

slot({Volume, Blocks} = File, Block) ->
    Inode = inode(File),
    need_loop(fun(Given) -> erx_f2fs_core:slot(Volume, Inode, Block, Given) end, Blocks).

read({Volume, Blocks} = File, Offset, Length) ->
    Inode = inode(File),
    need_loop(fun(Given) -> erx_f2fs_core:read(Volume, Inode, Offset, Length, Given) end, Blocks).

%%% The block map

each_block_maps_through_its_node_test_() ->
    File = file(),
    [?_assertEqual(Want, slot(File, Block))
     || {Block, Want} <- [{0, {ok, {?INO, 0, ?DATA}}},
                          {1, {ok, {?INO, 1, ?NEW}}},
                          {?SLOTS - 1, {ok, {?INO, ?SLOTS - 1, 0}}},
                          {?B_DIRECT1, {ok, {?DIRECT1, 0, ?DATA + 1}}},
                          {?B_DIRECT1 + ?PER - 1, {ok, {?DIRECT1, ?PER - 1, ?DATA + 2}}},
                          {?B_DIRECT1 + ?PER, {ok, none}},
                          {?B_INDIRECT1 + 2, {ok, none}},
                          {?B_INDIRECT1 + ?PER + 2, {ok, {?CHILD, 2, ?DATA + 3}}},
                          {?B_INDIRECT1 + ?PER * ?PER, {ok, none}},
                          {?B_DOUBLE + ?PER + 3, {ok, {?DOUBLE_DIRECT, 3, ?DATA + 4}}},
                          {?B_DOUBLE + ?PER * ?PER, {ok, none}},
                          {?B_DOUBLE + ?PER * ?PER * ?PER, {ok, none}}]].

%% Holes and NEW_ADDR read as zeros, data as its block, cut at the size.
a_read_gives_data_holes_and_new_addr_as_zeros_test() ->
    File = file(),
    Zeros = <<0:(?BLOCK * 8)>>,
    ?assertEqual({ok, <<(data(1))/binary, Zeros/binary, Zeros/binary>>}, read(File, 0, 3 * ?BLOCK)),
    ?assertEqual({ok, <<1, 1, 0>>}, read(File, ?BLOCK - 2, 3)),
    ?assertEqual({ok, data(4)}, read(File, (?B_INDIRECT1 + ?PER + 2) * ?BLOCK, ?BLOCK)),
    ?assertEqual({ok, <<5, 5>>}, read(File, (?B_DOUBLE + ?PER + 4) * ?BLOCK - 2, 10)),
    ?assertEqual({ok, <<>>}, read(File, (?B_DOUBLE + ?PER + 4) * ?BLOCK, 10)).

%% A slot asks for its nodes one at a time, and only the ones its path
%% crosses.
a_slot_reads_only_the_nodes_on_its_path_test() ->
    {Volume, Blocks} = File = file(),
    Inode = inode(File),
    ?assertEqual({need, [?NODES + 5]}, erx_f2fs_core:slot(Volume, Inode, ?B_DOUBLE, #{})),
    Given = maps:with([?NODES + 5, ?NODES + 6], Blocks),
    ?assertEqual({need, [?NODES + 7]}, erx_f2fs_core:slot(Volume, Inode, ?B_DOUBLE + ?PER, Given)).

%% Inline data reads from the inode; a symlink's target inline or in its
%% first block.
inline_data_and_symlinks_test() ->
    Inline = file(#{inode => (inode_fields_inode())#{i_inline := ?ERX_F2FS_EXTRA_ATTR bor
                                                                  ?ERX_F2FS_INLINE_DATA,
                                                      i_size := 5, i_blocks := 1},
                    i_addr => inline_words(<<"hello">>), i_nid => [0, 0, 0, 0, 0]}, []),
    ?assertEqual({ok, <<"ell">>}, read(Inline, 1, 3)),
    {InlineVolume, InlineBlocks} = Inline,
    InlineLink = (inode(Inline))#{i_mode := 8#120777},
    ?assertEqual({ok, <<"hello">>}, erx_f2fs_core:symlink(InlineVolume, InlineLink, InlineBlocks)),
    {Volume, Blocks} = Block = file(#{inode => (inode_fields_inode())#{i_mode := 8#120777,
                                                                       i_size := 7}}, []),
    ?assertEqual({ok, <<1, 1, 1, 1, 1, 1, 1>>},
                 need_loop(fun(Given) -> erx_f2fs_core:symlink(Volume, inode(Block), Given) end,
                           Blocks)).

inode_fields_inode() -> maps:get(inode, erx_f2fs_codec_tests:inode_fields()).

%% i_addr with i_extra_isize 12 and Bytes as inline content after the
%% reserved word ([F 48]).
inline_words(Bytes) ->
    #{i_addr := [W0, W1, W2 | _]} = erx_f2fs_codec_tests:inode_fields(),
    Padded = <<Bytes/binary, 0:((4 * (?ERX_F2FS_ADDRS_PER_INODE - 4) - byte_size(Bytes)) * 8)>>,
    [W0, W1, W2, 0 | [Word || <<Word:32/little>> <= Padded]].

%%% Refusals

each_refusal_names_its_rule_test_() ->
    Direct1 = fun(Words, Footer) -> [{?DIRECT1, direct_with(Words, Footer)}] end,
    Words1 = [?DATA + 1],
    [{Name, ?_assertEqual({error, Want}, slot(file(Changes, Replaced), Block))}
     || {Name, Want, Block, Changes, Replaced} <-
            [{"a direct node naming another nid", {direct_node, footer}, ?B_DIRECT1, #{},
              Direct1(Words1, #{nid => ?INDIRECT1})},
             {"a direct node of another inode", {direct_node, footer}, ?B_DIRECT1, #{},
              Direct1(Words1, #{ino => ?INO + 1})},
             {"a direct node at another node offset", {direct_node, footer}, ?B_DIRECT1, #{},
              Direct1(Words1, #{flag => 2 bsl ?ERX_F2FS_NODE_MARK_BITS})},
             {"an indirect node naming itself", {direct_node, footer}, ?B_INDIRECT1 + ?PER, #{},
              [{?INDIRECT1, indirect(?INDIRECT1, 3, at(1, ?INDIRECT1))}]},
             {"an inode naming itself as its direct node", {direct_node, footer}, ?B_DIRECT1,
              #{i_nid => [?INO, 0, 0, 0, 0]}, []},
             {"a node id past the NAT", {nat, nid}, ?B_DIRECT1,
              #{i_nid => [16#ffffffff, 0, 0, 0, 0]}, []},
             {"a node id the NAT holds free", {nat, free}, ?B_DIRECT1,
              #{i_nid => [11, 0, 0, 0, 0]}, []},
             {"a data address outside the main area", {data, block_addr}, ?B_DIRECT1, #{},
              Direct1([?MAIN - 1], #{})},
             {"a data address past the main area", {data, block_addr}, ?B_DIRECT1, #{},
              Direct1([?PARTITION], #{})},
             {"a data address the SIT holds free", {data, block_addr}, ?B_DIRECT1, #{},
              Direct1([?DATA + 100], #{})},
             {"an indirect child at another node offset", {indirect_node, footer},
              ?B_DOUBLE + ?PER + 3, #{},
              [{?GRANDCHILD, indirect(?GRANDCHILD, 2043, at(1, ?DOUBLE_DIRECT))}]}]].

%% With inline xattrs the address array ends 50 words early ([F 48]): its
%% last slot is 869, and file block 870 is direct node 1's first.
inline_xattrs_end_the_address_array_early_test() ->
    #{inode := Inode, i_addr := [_, W1, W2 | _]} = file_inode(#{}),
    Slots = ?SLOTS - ?ERX_F2FS_INLINE_XATTR_WORDS,
    Words = [12 bor (?ERX_F2FS_INLINE_XATTR_WORDS bsl 16), W1, W2]
        ++ lists:duplicate(Slots - 1, 0) ++ [?DATA + 4]
        ++ lists:duplicate(?ERX_F2FS_INLINE_XATTR_WORDS, ?DATA + 3),
    File = file(#{inode => Inode#{i_inline := ?ERX_F2FS_EXTRA_ATTR bor ?ERX_F2FS_INLINE_XATTR},
                  i_addr => Words}, []),
    ?assertEqual({ok, {?INO, Slots - 1, ?DATA + 4}}, slot(File, Slots - 1)),
    ?assertEqual({ok, {?DIRECT1, 0, ?DATA + 1}}, slot(File, Slots)).

%% Direct node 1 with Words and its footer changed by Footer.
direct_with(Words, Footer) ->
    Block = direct(?DIRECT1, 1, Words),
    <<Body:(?BLOCK - ?ERX_F2FS_NODE_FOOTER_SIZE)/binary, Old/binary>> = Block,
    New = maps:merge(erx_abi_packed:decode(erx_f2fs_node_footer, Old), Footer),
    <<Body/binary, (erx_abi_packed:encode(erx_f2fs_node_footer, New))/binary>>.

%% The NAT's entry is checked before its node is read: owned by another
%% inode, or placed where no valid node lies.
nat_entries_are_checked_before_the_node_is_read_test_() ->
    {Volume, Blocks} = file(),
    Inode = inode({Volume, Blocks}),
    Slot = fun(Nat) ->
                   Changed = Volume#{nat := nat(Volume, Nat)},
                   need_loop(fun(Given) -> erx_f2fs_core:slot(Changed, Inode, ?B_DIRECT1, Given) end,
                             Blocks)
           end,
    Entry = fun(Owner, Address) -> #{?DIRECT1 => erx_f2fs_codec_tests:nat_entry(0, Owner, Address)} end,
    [?_assertEqual({error, {nat, owner}}, Slot(Entry(?INO + 1, ?NODES + 2))),
     ?_assertEqual({error, {nat, block_addr}}, Slot(Entry(?INO, ?MAIN - 1))),
     ?_assertEqual({error, {nat, block_addr}}, Slot(Entry(?INO, ?NODES + 100)))].

%% A direct node read as an inode fails as one, and an inline file has no
%% slots; a symlink's target is at most a block.
inodes_and_inline_files_test() ->
    {Volume, Blocks} = File = file(),
    Node = Volume#{nat := nat(Volume, #{?INO => erx_f2fs_codec_tests:nat_entry(0, ?INO, ?NODES + 2)})},
    ?assertEqual({error, {inode, footer}},
                 need_loop(fun(Given) -> erx_f2fs_core:inode(Node, ?INO, Given) end, Blocks)),
    Inline = (inode(File))#{inline_data => <<>>},
    ?assertEqual({error, {file, inline}},
                 erx_f2fs_core:slot(Volume, maps:remove(addresses, Inline), 0, Blocks)),
    Long = (inode(File))#{i_mode := 8#120777, i_size := ?BLOCK + 1},
    ?assertEqual({error, {file, size}}, erx_f2fs_core:symlink(Volume, Long, Blocks)),
    ?assertEqual({error, {file, type}}, erx_f2fs_core:symlink(Volume, inode(File), Blocks)).

%%% The corpus images

%% Every inode of every corpus image that mounts, and of Fuchsia's with
%% ENCRYPT and VERITY cleared, within its first nids, reads; every block of
%% each regular file and symlink below its size, up to 4096 a file, maps,
%% and a slot holding a block names the node and index Linux's summary of
%% that block names ([F 46]); the file's first MiB reads. The counts are
%% the pinned images': 2522 inodes, 2087 files and symlinks, and 8257 slots
%% holding blocks, 6449 of them in direct nodes, under the inode or under
%% indirect node 1, so the node offsets Linux wrote agree with [F 53].
corpus_files_map_as_their_summaries_say_test_() ->
    {timeout, 600,
     fun() ->
             Images = [corpus_image(Pin) || Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK"))]
                 ++ [erx_f2fs_mount_tests:cleared_fuchsia()],
             Tally = lists:foldl(fun(Image, Sum) -> maps:merge_with(fun(_, A, B) -> A + B end, Sum, check_image(Image)) end,
                                 #{inodes => 0, files => 0, slots => 0, node_slots => 0}, Images),
             ?assertEqual(#{inodes => 2522, files => 2087, slots => 8257, node_slots => 6449}, Tally)
     end}.

corpus_image(Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    Image.

check_image(Image) ->
    Partition = byte_size(Image) div ?BLOCK,
    Read = fun(Addresses) -> maps:from_list([{A, binary:part(Image, A * ?BLOCK, ?BLOCK)} || A <- Addresses]) end,
    case image_loop(fun(Given) -> erx_f2fs_mount:mount(Partition, 1 bsl 30, Given) end, Read, Partition) of
        {ok, Volume} ->
            lists:foldl(fun(Nid, Sum) -> maps:merge_with(fun(_, A, B) -> A + B end, Sum,
                                                         check_inode(Volume, Nid, Read, Partition)) end,
                        #{}, lists:seq(3, nid_bound(Volume)));
        {error, _} ->
            #{}
    end.

%% The nids an image's nodes hold: Linux takes the lowest free nids, so
%% twice the checkpoint's node count past the root covers them.
nid_bound(#{superblock := Super, checkpoint := #{valid_node_count := Nodes}}) ->
    min(erx_f2fs_codec:nat_capacity(Super) - 1, 3 + 2 * Nodes).

check_inode(Volume, Nid, Read, Partition) ->
    case image_loop(fun(Given) -> erx_f2fs_core:inode(Volume, Nid, Given) end, Read, Partition) of
        {ok, #{i_mode := Mode, i_size := Size} = Inode}
          when Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_REG;
               Mode band ?ERX_F2FS_MODE_TYPE_MASK =:= ?ERX_F2FS_MODE_LNK ->
            Blocks = case Inode of
                         #{addresses := _} -> lists:seq(0, (Size + ?BLOCK - 1) div ?BLOCK - 1);
                         #{} -> []
                     end,
            Slots = [check_slot(Volume, Inode, Block, Read, Partition) || Block <- lists:sublist(Blocks, 4096)],
            {ok, Bytes} = image_loop(fun(Given) -> erx_f2fs_core:read(Volume, Inode, 0, min(Size, 1 bsl 20), Given) end,
                                     Read, Partition),
            ?assertEqual(min(Size, 1 bsl 20), byte_size(Bytes)),
            #{inodes => 1, files => 1, slots => length([S || S <- Slots, S =/= hole]),
              node_slots => length([S || S <- Slots, S =:= node])};
        {ok, _Other} ->
            #{inodes => 1};
        {error, {nat, Rule}} when Rule =:= free; Rule =:= owner ->
            #{}
    end.

check_slot(Volume, Inode, Block, Read, Partition) ->
    case image_loop(fun(Given) -> erx_f2fs_core:slot(Volume, Inode, Block, Given) end, Read, Partition) of
        {ok, {Nid, Index, Address}} when Address =/= 0, Address =/= ?NEW ->
            ?assertMatch({Nid, Index}, summary(Volume, Address, Read)),
            case Inode of
                #{footer := #{ino := Nid}} -> inode;
                #{} -> node
            end;
        {ok, _Hole} ->
            hole
    end.

%% The summary of a main area block: the pack's, for a current data log's
%% segment, else the SSA's ([F 45]).
summary(#{superblock := #{main_blkaddr := Main, ssa_blkaddr := Ssa},
          checkpoint := #{cur_data_segno := Segments}, data_summaries := Logs}, Address, Read) ->
    Segment = (Address - Main) div ?SEGMENT,
    Offset = (Address - Main) rem ?SEGMENT,
    Entries = case lists:search(fun({S, _}) -> S =:= Segment end,
                                lists:zip(lists:sublist(Segments, 3), Logs)) of
                  {value, {_, Log}} ->
                      Log;
                  false ->
                      #{Ssa + Segment := Block} = Read([Ssa + Segment]),
                      {ok, #{entries := Summaries}} = erx_f2fs_codec:summary_block(Block),
                      Summaries
              end,
    #{nid := Nid, ofs_in_node := Index} = lists:nth(Offset + 1, Entries),
    {Nid, Index}.

image_loop(Step, Read, Partition) -> image_loop(Step, Read, Partition, #{}, 16).

image_loop(Step, Read, Partition, Given, Rounds) ->
    case Step(Given) of
        {need, Addresses} when Rounds > 0 ->
            ?assertEqual([], [A || A <- Addresses, A >= Partition]),
            image_loop(Step, Read, Partition, maps:merge(Given, Read(Addresses)), Rounds - 1);
        Answer ->
            Answer
    end.

%%% Directories

%% The NAT of Volume, the fixture's, with Entries, nid to entry, in its
%% journal.
nat(#{superblock := Super}, Entries) ->
    {ok, Nat} = erx_f2fs_core:nat(Super, [#{nid => Nid, entry => Entry}
                                          || {Nid, Entry} <- lists:sort(maps:to_list(Entries))]),
    Nat.

hash(Name) -> erx_f2fs_codec:dentry_hash(Name).

%% The first block of Name's bucket at Level in a directory whose
%% i_dir_level is 0: level n has 2^n buckets of two blocks ([F 58]), and
%% starts past the 2^n - 1 buckets of the levels before it.
bucket(Level, Name) -> level_start(Level) + hash(Name) rem (1 bsl Level) * 2.

%% The first block of the bucket after Name's at Level, where a lookup of
%% Name never searches.
next_bucket(Level, Name) -> level_start(Level) + (hash(Name) + 1) rem (1 bsl Level) * 2.

level_start(Level) -> (1 bsl Level - 1) * 2.

long_name() -> binary:copy(<<"long">>, 63).

%% The test directory's dentries, {Block, Slot, Name, Ino, Hash}: "." and
%% ".." where the format puts them, a name at each of its three levels,
%% one in the second block of its bucket, a 252-byte name, a name in the
%% wrong bucket of level 2 and one at its level 1 bucket with a stored hash
%% that is not its own. Every slot differs, so no two collide.
dir_dentries() ->
    [{0, 0, <<".">>, ?INO, 0}, {0, 1, <<"..">>, 3, 0},
     {bucket(0, <<"zero">>), 2, <<"zero">>, 20, hash(<<"zero">>)},
     {bucket(1, <<"one">>) + 1, 3, <<"one">>, 21, hash(<<"one">>)},
     {bucket(2, <<"two">>), 4, <<"two">>, 22, hash(<<"two">>)},
     {bucket(2, long_name()), 5, long_name(), 23, hash(long_name())},
     {next_bucket(2, <<"misplaced">>), 40, <<"misplaced">>, 24, hash(<<"misplaced">>)},
     {bucket(1, <<"badhash">>), 41, <<"badhash">>, 25, hash(<<"badhash">>) bxor 1}].

%% A directory of i_current_depth 3 and i_dir_level 0, 14 blocks, holding
%% Dentries in its address array's blocks, each dentry block at
%% ?DATA + 16 + its index and every other block a hole.
directory(Dentries) ->
    ByBlock = maps:groups_from_list(fun(Dentry) -> element(1, Dentry) end,
                                    fun({_, Slot, Name, Ino, Hash}) -> {Slot, Name, Ino, Hash} end,
                                    Dentries),
    DentryBlocks = #{?DATA + 16 + Block => erx_f2fs_codec_tests:dentry_block(Entries)
                     || Block := Entries <- ByBlock},
    #{i_addr := Words} = erx_f2fs_codec_tests:inode_fields(),
    {Extra, _} = lists:split(3, Words),
    Addresses = [case is_map_key(Block, ByBlock) of
                     true -> ?DATA + 16 + Block;
                     false -> 0
                 end || Block <- lists:seq(0, ?SLOTS - 1)],
    Fields = #{inode => (inode_fields_inode())#{i_mode := 8#40755, i_links := 2,
                                                i_size := 14 * ?BLOCK, i_current_depth := 3,
                                                i_dir_level := 0, i_blocks := 1 + map_size(ByBlock)},
               i_addr => Extra ++ Addresses, i_nid => [0, 0, 0, 0, 0]},
    {#{sit := Sit} = Volume, Blocks} = file(Fields, []),
    {Volume#{sit := valid(Sit, maps:keys(DentryBlocks))}, maps:merge(Blocks, DentryBlocks)}.

directory() -> directory(dir_dentries()).

%% erx_f2fs_fuzz's seeds: the test directory and the names a lookup asks.
fixture_directory() -> directory().

fixture_names() ->
    [Name || {_, _, Name, _, _} <- dir_dentries()] ++ [<<"absent">>, <<>>, <<"a/b">>].

lookup({Volume, Blocks} = Dir, Name) ->
    need_loop(fun(Given) -> erx_f2fs_core:lookup(Volume, inode(Dir), Name, Given) end, Blocks).

readdir({Volume, Blocks} = Dir, Position) ->
    need_loop(fun(Given) -> erx_f2fs_core:readdir(Volume, inode(Dir), Position, Given) end, Blocks).

position(Block, Slot) -> Block * 214 + Slot.

%% Each name is found in its bucket at its level, the last level below
%% i_current_depth included; a name outside its bucket, or whose stored
%% hash is not its own, is not, as Linux finds neither.
each_name_is_found_in_its_bucket_test() ->
    Dir = directory(),
    Found = [{Name, Ino, position(Block, Slot)}
             || {Block, Slot, Name, Ino, _} <- dir_dentries(),
                not lists:member(Name, [<<"misplaced">>, <<"badhash">>])],
    ?assertEqual(Found, [case lookup(Dir, Name) of
                             {ok, #{name := Name, ino := Got, position := At}} -> {Name, Got, At};
                             Other -> {Name, Other}
                         end || {Name, _, _} <- Found]),
    ?assertEqual([{ok, none} || _ <- lists:seq(1, 4)],
                 [lookup(Dir, Name) || Name <- [<<"misplaced">>, <<"badhash">>, <<"absent">>,
                                               binary:part(long_name(), 0, 251)]]).

%% A readdir takes eight steps a call, each a dentry block or a run of
%% holes, and answers the position the next starts from; together the
%% calls give every entry once, in position order, and a call from a
%% position inside a block skips what lies before. The test directory's
%% six dentry blocks and the holes between them take two calls.
readdir_resumes_at_its_position_test() ->
    Dir = directory(),
    {ok, {First, Next}} = readdir(Dir, 0),
    ?assert(is_integer(Next) andalso Next > 0),
    {ok, {Rest, done}} = readdir(Dir, Next),
    Expected = lists:sort([{position(Block, Slot), Name} || {Block, Slot, Name, _, _} <- dir_dentries()]),
    ?assertEqual(Expected, [{At, Name} || #{position := At, name := Name} <- First ++ Rest]),
    {ok, {After, Next}} = readdir(Dir, 2),
    ?assertEqual([At || {At, _} <- Expected, At >= 2, At < Next], [At || #{position := At} <- After]),
    ?assertEqual({ok, {[], done}}, readdir(Dir, position(1000, 0))).

%% A directory claiming the largest size, with no block in its address
%% array and no node, lists in one call that reads nothing: each run of
%% holes, the array's and each node id 0's span, is one step.
a_readdir_over_holes_is_one_step_a_run_test() ->
    {Volume, Blocks} = Dir = directory([]),
    #{addresses := Addresses} = Empty = inode(Dir),
    Huge = Empty#{i_size := 1 bsl 60, addresses := [0 || _ <- Addresses], i_nid := [0, 0, 0, 0, 0]},
    ?assertEqual({ok, {[], done}}, erx_f2fs_core:readdir(Volume, Huge, 0, Blocks)),
    ?assertEqual({ok, {[], done}}, erx_f2fs_core:readdir(Volume, Huge, position(5000000, 3), Blocks)).

%% An inline directory's entries are its inline slots ([F 48]); its bytes
%% are no file's, so read/5 refuses it.
inline_directories_test() ->
    Area = erx_f2fs_codec_tests:dentry_area(3476, {23, 37, 37 + 11 * 181},
                                            [{0, <<".">>, ?INO, 0}, {1, <<"..">>, 3, 0},
                                             {7, <<"inline">>, 9, hash(<<"inline">>)}]),
    Fields = erx_f2fs_codec_tests:inline_inode(Area, #{i_mode => 8#40755, i_links => 2,
                                                       i_size => 3476,
                                                       i_inline => ?ERX_F2FS_EXTRA_ATTR bor
                                                                       ?ERX_F2FS_INLINE_DENTRY}, 3),
    Dir = file(Fields, []),
    ?assertMatch({ok, #{ino := 9, position := 7}}, lookup(Dir, <<"inline">>)),
    ?assertMatch({ok, #{ino := 3, position := 1}}, lookup(Dir, <<"..">>)),
    ?assertEqual({ok, none}, lookup(Dir, <<"other">>)),
    ?assertMatch({ok, {[#{position := 0}, #{position := 1}, #{name := <<"inline">>}], done}},
                 readdir(Dir, 0)),
    ?assertMatch({ok, {[#{name := <<"inline">>}], done}}, readdir(Dir, 2)),
    ?assertEqual({error, {file, inline}}, read(Dir, 0, 10)).

%% "." and ".." only where the format puts them, names a path can hold, and
%% only a directory has entries.
each_directory_refusal_names_its_rule_test_() ->
    Dots = [{0, 0, <<".">>, ?INO, 0}, {0, 1, <<"..">>, 3, 0}],
    Listed = fun(Dentries) -> readdir(directory(Dentries), 0) end,
    [?_assertEqual({error, {dir, dot}}, Listed(Dots ++ [{0, 9, <<".">>, ?INO, 0}])),
     ?_assertEqual({error, {dir, dot}}, Listed([{0, 0, <<"..">>, 3, 0}])),
     ?_assertEqual({error, {dir, dot}}, Listed(Dots ++ [{3, 0, <<"..">>, 3, 0}])),
     ?_assertEqual({error, {dir, dot}}, lookup(directory([{1, 1, <<"..">>, 3, 0}]), <<"..">>)),
     ?_assertEqual({error, {dentry_block, name}}, Listed(Dots ++ [{0, 2, <<"a/b">>, 5, 0}])),
     ?_assertEqual({error, {dentry_block, name}}, Listed(Dots ++ [{0, 2, <<"a", 0>>, 5, 0}])),
     ?_assertEqual({error, {file, type}}, readdir(file(), 0)),
     ?_assertEqual({error, {file, type}}, lookup(file(), <<"a">>))].

%% Whatever depth and size a directory claims, a lookup ends by the level
%% whose bucket starts past the largest block a file addresses.
a_lookup_is_bounded_whatever_the_directory_claims_test() ->
    {Volume, Blocks} = Dir = directory(),
    Huge = (inode(Dir))#{i_current_depth := 63, i_dir_level := 0, i_size := 1 bsl 60},
    ?assertEqual({ok, none}, need_loop(fun(Given) -> erx_f2fs_core:lookup(Volume, Huge, <<"absent">>, Given) end,
                                       Blocks)),
    Wide = Huge#{i_dir_level := 255},
    ?assertEqual({ok, none}, need_loop(fun(Given) -> erx_f2fs_core:lookup(Volume, Wide, <<"absent">>, Given) end,
                                       Blocks)).

%% Every directory reached from the root of every corpus image that mounts,
%% and of Fuchsia's with ENCRYPT and VERITY cleared, lists through readdir
%% from position to position; each entry's stored hash is the one
%% erx_f2fs_codec:dentry_hash/1 computes from its name, and a lookup of each
%% name finds the very entry Linux wrote ([F 57], [F 58]); no directory
%% lists a name twice and none is reached twice. An encrypted directory's
%% names are ciphertext under another hash, out of scope, so it is counted
%% and not read. The counts are the pinned images': 31 directories, 2166
%% entries, one name past 16 bytes, which takes two chunks of the hash,
%% and one encrypted directory.
corpus_directories_list_and_look_up_as_linux_wrote_test_() ->
    {timeout, 600,
     fun() ->
             Images = [corpus_image(Pin) || Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK"))]
                 ++ [erx_f2fs_mount_tests:cleared_fuchsia()],
             Tally = lists:foldl(fun(Image, Sum) -> maps:merge_with(fun(_, A, B) -> A + B end, Sum, check_tree(Image)) end,
                                 #{directories => 0, entries => 0, long_names => 0, encrypted => 0}, Images),
             ?assertEqual(#{directories => 31, entries => 2166, long_names => 1, encrypted => 1}, Tally)
     end}.

check_tree(Image) ->
    Partition = byte_size(Image) div ?BLOCK,
    Read = fun(Addresses) -> maps:from_list([{A, binary:part(Image, A * ?BLOCK, ?BLOCK)} || A <- Addresses]) end,
    case image_loop(fun(Given) -> erx_f2fs_mount:mount(Partition, 1 bsl 30, Given) end, Read, Partition) of
        {ok, #{superblock := #{root_ino := Root}} = Volume} ->
            Loop = fun(Step) -> image_loop(Step, Read, Partition) end,
            check_directories(Volume, Loop, [Root], #{}, #{});
        {error, _} ->
            #{}
    end.

check_directories(_Volume, _Loop, [], _Seen, Tally) ->
    Tally;
check_directories(Volume, Loop, [Ino | Inos], Seen, Tally) ->
    ?assertNot(is_map_key(Ino, Seen)),
    {ok, #{i_advise := Advise} = Dir} = Loop(fun(Given) -> erx_f2fs_core:inode(Volume, Ino, Given) end),
    case Advise band ?ERX_F2FS_ADVISE_ENCRYPT of
        0 ->
            Entries = list_directory(Volume, Loop, Dir, 0),
            Names = [Name || #{name := Name} <- Entries],
            ?assertEqual(length(Names), length(lists:usort(Names))),
            ?assertEqual([{Name, Hash} || #{name := Name, hash_code := Hash} <- Entries],
                         [{Name, hash(Name)} || Name <- Names]),
            [?assertEqual({Name, {ok, Entry}},
                          {Name, Loop(fun(Given) -> erx_f2fs_core:lookup(Volume, Dir, Name, Given) end)})
             || #{name := Name} = Entry <- Entries],
            %% File type 2 is a directory ([F 59]).
            Children = [Child || #{name := Name, ino := Child, file_type := 2} <- Entries,
                                 Name =/= <<".">>, Name =/= <<"..">>],
            check_directories(Volume, Loop, Children ++ Inos, Seen#{Ino => true},
                              bump(Tally, #{directories => 1, entries => length(Entries),
                                            long_names => length([N || N <- Names, byte_size(N) > 16])}));
        _ ->
            check_directories(Volume, Loop, Inos, Seen#{Ino => true}, bump(Tally, #{encrypted => 1}))
    end.

%% Every entry of Dir from Position, a readdir at a time, each call's next
%% position past the one it was given.
list_directory(Volume, Loop, Dir, Position) ->
    case Loop(fun(Given) -> erx_f2fs_core:readdir(Volume, Dir, Position, Given) end) of
        {ok, {Entries, done}} ->
            Entries;
        {ok, {Entries, Next}} ->
            ?assert(Next > Position),
            Entries ++ list_directory(Volume, Loop, Dir, Next)
    end.

bump(Tally, Counts) -> maps:merge_with(fun(_, A, B) -> A + B end, Tally, Counts).
