%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_plan_tests).
-moduledoc """
EUnit cases for erXos's F2FS volume state and checkpoint plan
(docs/design-f2fs.md, "The volume state", "Allocation", "Checkpoints" and
"Read-write mounts: the mount checkpoint"): mounting read-write and
committing an unchanged tree, over erx_f2fs_format's fresh volume and the
corpus images that mount read-write, some with sections of two segments,
gives a checkpoint erXos's own mount accepts, its table copies flipped
exactly where it wrote, and repeated cycles stay valid. After every commit
the six current segments lie in six sections, the free set holds no
section with a durable block, and every main-area block written lies in a
section free at the last commit or past its log's next block. Every crash
state at the plan's phase boundaries, under a device that honours flushes
and writes a sector whole or not at all, mounts to the old checkpoint or
the new one. set_node keeps the counters and i_blocks through creating,
moving and freeing nodes, and a dirty dentry block goes to the warm data
log.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
-define(SECTOR, 512).
-define(SEG, 512).
-define(MIB_SECTORS, 2048).
-define(ALLOWANCE, (64 bsl 20)).
%% A 4 GiB partition.
-define(SECTORS, (4096 * ?MIB_SECTORS)).
-define(WARM_DATA, 1).
-define(WARM_NODE, 4).
-define(COLD_NODE, 5).

%%% The medium: blocks by address, zeros where nothing was written

fresh() ->
    Geometry = #{start => ?ERX_MEDIUM_DATA_START, sectors => ?SECTORS},
    {ok, Plan} = erx_f2fs_format:plan(Geometry, #{version => 16#2468ace1, uuid => binary:copy(<<16#5a>>, 16),
                                                  time => 1700000000}),
    {?SECTORS div 8, written(#{}, Plan)}.

%% The fresh volume re-described with sections of two segments, as another
%% writer may leave one: only its superblock and copy change, the main area
%% trimmed to whole sections, so each pair of its six logs, in segments 0
%% to 5, shares a section.
wide({Partition, Medium}) ->
    {ok, #{segment_count_main := Segments} = Super} = erx_f2fs_codec:superblock(maps:get(0, Medium)),
    Block = erx_f2fs_codec:encode_superblock(Super#{segs_per_sec := 2, section_count := Segments div 2,
                                                    segment_count_main := Segments div 2 * 2}),
    {Partition, Medium#{0 => Block, 1 => Block}}.

written(Medium, Plan) ->
    lists:foldl(fun({Address, Block}, M) -> M#{Address => Block} end, Medium, lists:append(Plan)).

read(Medium, Addresses) ->
    maps:from_list([{A, maps:get(A, Medium, <<0:(?BLOCK * 8)>>)} || A <- Addresses]).

%% Runs a pure step through its need loop over the medium.
need(Step, Medium) -> need(Step, Medium, #{}, 16).

need(Step, Medium, Given, Rounds) ->
    case Step(Given) of
        {need, Addresses} when Rounds > 0 -> need(Step, Medium, maps:merge(Given, read(Medium, Addresses)),
                                                  Rounds - 1);
        Answer -> Answer
    end.

mount({Partition, Medium}) ->
    need(fun(Blocks) -> erx_f2fs_mount:mount(Partition, ?ALLOWANCE, Blocks) end, Medium).

state(Mounted, Medium) ->
    {ok, State} = need(fun(Blocks) -> erx_f2fs_core:state(Mounted, Blocks) end, Medium),
    State.

checkpoint(State, Medium) ->
    {ok, Plan, Committed} = need(fun(Blocks) -> erx_f2fs_plan:checkpoint(State, Blocks) end, Medium),
    {Plan, Committed}.

%% The root's names, as a mount of Medium lists them.
names(Mounted, Medium) ->
    #{root := Root} = Mounted,
    {ok, {Entries, done}} = need(fun(Blocks) -> erx_f2fs_core:readdir(Mounted, Root, 0, Blocks) end, Medium),
    lists:sort([Name || #{name := Name} <- Entries]).

%%% Mount and commit cycles

fresh_volumes_commit_and_remount_test_() ->
    {timeout, 300, ?_test(cycles(fresh(), 4))}.

corpus_images_commit_and_remount_test_() ->
    {timeout, 600,
     fun() ->
             Writable = [Image || Pin <- erx_f2fs_corpus:pins(os:getenv("ERX_DEPS_LOCK")),
                                  Image <- [corpus_image(Pin)],
                                  {ok, #{mode := read_write}} <- [mount(Image)]],
             ?assertMatch([_, _ | _], Writable),
             [cycles(Image, 3) || Image <- Writable]
     end}.

corpus_image(Pin) ->
    {ok, Image} = erx_f2fs_corpus:image(Pin, erx_f2fs_corpus:fetched(os:getenv("ERX_F2FS_CORPUS"), Pin)),
    Partition = byte_size(Image) div ?BLOCK,
    {Partition, maps:from_list([{A, binary:part(Image, A * ?BLOCK, ?BLOCK)}
                                || A <- lists:seq(0, Partition - 1)])}.

cycles(_Image, 0) -> ok;
cycles({Partition, Medium} = Image, N) ->
    {ok, #{checkpoint := Old} = Mounted} = mount(Image),
    State = state(Mounted, Medium),
    {Plan, Committed} = checkpoint(State, Medium),
    check_plan(Mounted, State, Plan, Committed),
    crash_states(Image, Mounted, Plan),
    After = written(Medium, Plan),
    {ok, #{checkpoint := New} = Remounted} = mount({Partition, After}),
    ?assertEqual(maps:get(checkpoint_ver, Old) + 1, maps:get(checkpoint_ver, New)),
    ?assertEqual(names(Mounted, Medium), names(Remounted, After)),
    ?assertEqual(maps:with([valid_block_count, valid_node_count, valid_inode_count], Old),
                 maps:with([valid_block_count, valid_node_count, valid_inode_count], New)),
    ?assertNotEqual(maps:get(pack, Mounted), maps:get(pack, Remounted)),
    cycles({Partition, After}, N - 1).

%% The properties of one commit: six logs in six sections, a free set
%% clear of the new durable view, writes only into what was free or past a
%% log's next block, and table copies flipped exactly where written.
check_plan(#{superblock := #{segs_per_sec := S, main_blkaddr := Main} = Super,
             checkpoint := Old},
           Before, [_Body, [_Last]] = Plan, Committed) ->
    Section = fun(A) -> (A - Main) div ?SEG div S end,
    #{volume := #{sit := Sit, checkpoint := New}} = erx_f2fs_core:epoch(Committed),
    Logs = erx_f2fs_core:logs(Committed),
    ?assertEqual(6, length(lists:usort([Section(A) || A <- Logs]))),
    Durable = lists:usort([Section(lists:nth(?WARM_NODE + 1, Logs)) |
                           [Segno div S || {Segno, #{valid_blocks := V}}
                                               <- lists:enumerate(0, tuple_to_list(Sit)), V > 0]]),
    ?assertEqual([], ordsets:intersection(Durable, erx_f2fs_core:free_sections(Committed))),
    Free = erx_f2fs_core:free_sections(Before),
    Positions = erx_f2fs_core:logs(Before),
    MainWrites = [A || {A, _} <- lists:append(Plan), A >= Main],
    ?assertEqual([], [A || A <- MainWrites, not lists:member(Section(A), Free),
                           not lists:any(fun(P) -> Section(P) =:= Section(A) andalso A >= P end,
                                         Positions)]),
    lists:foreach(fun(Table) -> check_flips(Table, Super, Old, New, lists:append(Plan)) end, [nat, sit]).

check_flips(Table, Super, Old, New, Writes) ->
    Key = #{nat => nat_version_bitmap, sit => sit_version_bitmap},
    OldBits = maps:get(maps:get(Table, Key), Old),
    NewBits = maps:get(maps:get(Table, Key), New),
    Flipped = [I || I <- lists:seq(0, bit_size(OldBits) - 1),
                    erx_f2fs_codec:bit(OldBits, I) =/= erx_f2fs_codec:bit(NewBits, I)],
    Addresses = maps:from_list([{A, ok} || {A, _} <- Writes]),
    Written = [I || I <- lists:seq(0, bit_size(OldBits) - 1),
                    is_map_key(erx_f2fs_codec:current_block(Table, Super, New, I), Addresses)],
    ?assertEqual(Written, Flipped).

%%% Crash states

%% Every crash state at the plan's phase boundaries mounts to the old
%% checkpoint or the new one with the same root: each phase's blocks over
%% the medium of the phases before it, any of its sectors landed, sampled
%% as none, all, all but each one block, each block torn in half, and
%% random subsets of whole blocks and sectors.
crash_states({Partition, Medium}, #{checkpoint := Old} = Mounted, Plan) ->
    rand:seed(exsss, {16#c2a5, 7, length(lists:append(Plan))}),
    {ok, #{checkpoint := New}} = mount({Partition, written(Medium, Plan)}),
    Versions = [maps:get(checkpoint_ver, C) || C <- [Old, New]],
    Names = names(Mounted, Medium),
    lists:foldl(
      fun(Phase, Prefix) ->
              [begin
                   Crashed = written(Prefix, [Landed]),
                   case mount({Partition, Crashed}) of
                       {ok, #{checkpoint := #{checkpoint_ver := V}} = Got} ->
                           ?assert(lists:member(V, Versions)),
                           ?assertEqual(Names, names(Got, Crashed));
                       Failed ->
                           ?assertEqual({landed, length(Landed), ok}, {landed, length(Landed), Failed})
                   end
               end || Landed <- landings(Phase, Prefix)],
              written(Prefix, [Phase])
      end, Medium, Plan).

landings(Phase, Medium) ->
    Torn = fun({A, Block}) ->
                   OldBlock = maps:get(A, Medium, <<0:(?BLOCK * 8)>>),
                   {A, <<(binary:part(Block, 0, ?BLOCK div 2))/binary,
                         (binary:part(OldBlock, ?BLOCK div 2, ?BLOCK div 2))/binary>>}
           end,
    Sectors = fun({A, Block}) ->
                      OldBlock = maps:get(A, Medium, <<0:(?BLOCK * 8)>>),
                      {A, << <<(case rand:uniform(2) of
                                    1 -> binary:part(Block, I * ?SECTOR, ?SECTOR);
                                    2 -> binary:part(OldBlock, I * ?SECTOR, ?SECTOR)
                                end)/binary>> || I <- lists:seq(0, ?BLOCK div ?SECTOR - 1) >>}
              end,
    [[], Phase] ++
        [Phase -- [Write] || Write <- Phase] ++
        [[Torn(Write) | Phase -- [Write]] || Write <- Phase] ++
        [[case rand:uniform(3) of
              1 -> Write;
              2 -> Sectors(Write);
              3 -> Torn(Write)
          end || Write <- Phase, rand:uniform(2) =:= 1] || _ <- lists:seq(1, 8)].

%%% The log positions at mount

a_read_only_mount_gets_no_writable_state_test() ->
    {_, Medium} = Image = fresh(),
    {ok, Mounted} = mount(Image),
    ?assertEqual({error, {mode, read_only}},
                 erx_f2fs_core:state(Mounted#{mode := {read_only, [{section_count, 16}]}}, Medium)).

%% A block live in a later segment of the warm node log's section moves the
%% log past it, here to a free section, since the segment it would resume
%% in holds a live block whose summary only its SSA block has; a footprint
%% block there moves it to the block after, in that segment. The volume is
%% the wide one, its cold node log, which shares the warm node log's
%% section, moved to a section of its own.
a_log_resumes_past_the_durable_blocks_of_its_whole_section_test() ->
    {_, Medium} = Image = wide(fresh()),
    {ok, #{superblock := #{main_blkaddr := Main, segs_per_sec := 2}, sit := Sit,
           logs := Shared} = Wide} = mount(Image),
    {?COLD_NODE, _, 0, Alloc} = lists:keyfind(?COLD_NODE, 1, Shared),
    Logs = lists:keyreplace(?COLD_NODE, 1, Shared, {?COLD_NODE, 2 * ?COLD_NODE, 0, Alloc}),
    Mounted = Wide#{logs := Logs},
    {?WARM_NODE, Segno, 1, _} = lists:keyfind(?WARM_NODE, 1, Logs),
    Later = Segno + 1,
    Entry = element(Later + 1, Sit),
    Live = Mounted#{sit := setelement(Later + 1, Sit, Entry#{valid_blocks := 1, type := ?WARM_NODE,
                                                            valid_map := <<0:7, 1:1, 0:504>>})},
    Moved = lists:nth(?WARM_NODE + 1, erx_f2fs_core:logs(state(Live, Medium))),
    ?assertNotEqual(Segno div 2, (Moved - Main) div ?SEG div 2),
    ?assertEqual(0, (Moved - Main) rem (2 * ?SEG)),
    Walked = Mounted#{footprint := [Main + Later * ?SEG + 3]},
    ?assertEqual(Main + Later * ?SEG + 4,
                 lists:nth(?WARM_NODE + 1, erx_f2fs_core:logs(state(Walked, Medium)))).

%%% set_node, set_slot and the dirty blocks

%% Creating a direct, an indirect and an xattr node of the root, writing
%% them at a checkpoint and freeing one keeps valid_node_count,
%% valid_block_count and the root's i_blocks equal to a recount, and every
%% crash state of each checkpoint mounts to one of its two sides.
set_node_keeps_every_count_a_node_is_in_test_() ->
    {timeout, 120, fun set_node_counts/0}.

set_node_counts() ->
    {Partition, Medium} = Image = fresh(),
    {ok, #{root := Root, checkpoint := Header} = Mounted} = mount(Image),
    Root3 = ?ERX_F2FS_ROOT_INO,
    Footer = fun(Nid, Offset) -> #{nid => Nid, ino => Root3, flag => Offset bsl ?ERX_F2FS_NODE_MARK_BITS,
                                   cp_ver => 0, next_blkaddr => 0} end,
    Nodes = [{4, {direct, lists:duplicate(?ERX_F2FS_ADDRS_PER_BLOCK, 0), Footer(4, 1)}},
             {5, {indirect, lists:duplicate(?ERX_F2FS_NIDS_PER_BLOCK, 0), Footer(5, 3)}},
             {6, {direct, lists:duplicate(?ERX_F2FS_ADDRS_PER_BLOCK, 0),
                  Footer(6, ?ERX_F2FS_XATTR_NODE_OFFSET)}}],
    Created = lists:foldl(
                fun({Nid, Value}, S) ->
                        S1 = erx_f2fs_core:put_node(S, Nid, Value),
                        {ok, S2} = need(fun(B) -> erx_f2fs_core:set_node(S1, Nid, Root3, ?ERX_F2FS_NEW_ADDR, B)
                                        end, Medium),
                        S2
                end, erx_f2fs_core:put_node(state(Mounted, Medium), Root3, {inode, Root}), Nodes),
    expect_counts(Created, Header, 3, 2 + 3),
    %% A dirty node freed is gone: no checkpoint writes it back.
    {ok, Dropped} = need(fun(B) -> erx_f2fs_core:set_node(Created, 6, Root3, ?ERX_F2FS_NULL_ADDR, B) end,
                         Medium),
    expect_counts(Dropped, Header, 2, 2 + 2),
    {DroppedPlan, _} = checkpoint(Dropped, Medium),
    ?assertEqual(3, length([A || {A, _} <- hd(DroppedPlan), A >= main(Mounted)])),
    {Plan, Committed} = checkpoint(Created, Medium),
    crash_states(Image, Mounted, Plan),
    check_plan(Mounted, Created, Plan, Committed),
    expect_counts(Committed, Header, 3, 2 + 3),
    ?assertEqual([], [A || {A, _} <- hd(Plan), A >= main(Mounted), not in_log(A, Created, Committed)]),
    After = written(Medium, Plan),
    {ok, #{root := #{i_blocks := 5}} = Remounted} = mount({Partition, After}),
    Freed0 = erx_f2fs_core:put_node(state(Remounted, After), Root3, {inode, maps:get(root, Remounted)}),
    {ok, Freed} = need(fun(B) -> erx_f2fs_core:set_node(Freed0, 5, Root3, ?ERX_F2FS_NULL_ADDR, B) end, After),
    expect_counts(Freed, Header, 2, 2 + 2),
    {Plan2, Committed2} = checkpoint(Freed, After),
    crash_states({Partition, After}, Remounted, Plan2),
    {ok, #{root := #{i_blocks := 4}, checkpoint := #{valid_node_count := 3}}} =
        mount({Partition, written(After, Plan2)}),
    expect_counts(Committed2, Header, 2, 2 + 2).

%% The counters Created nodes past the format's and the root's i_blocks.
expect_counts(State, #{valid_block_count := Blocks, valid_node_count := Nodes, valid_inode_count := Inodes},
              Created, IBlocks) ->
    #{counts := Counts, nodes := Dirty} = erx_f2fs_core:epoch(State),
    ?assertEqual(#{valid_block_count => Blocks + Created, valid_node_count => Nodes + Created,
                   valid_inode_count => Inodes}, Counts),
    case lists:keyfind(?ERX_F2FS_ROOT_INO, 1, Dirty) of
        {_, {inode, #{i_blocks := Got}}} -> ?assertEqual(IBlocks, Got);
        false -> ok
    end.

main(#{superblock := #{main_blkaddr := Main}}) -> Main.

%% Whether A lies in the warm node or warm data log, at or past its next
%% block before the plan and before its next block after it.
in_log(A, Before, After) ->
    lists:any(fun(Type) ->
                      From = lists:nth(Type + 1, erx_f2fs_core:logs(Before)),
                      To = lists:nth(Type + 1, erx_f2fs_core:logs(After)),
                      A >= From andalso A < To
              end, [?WARM_DATA, ?WARM_NODE]).

%% The root's dentry block, dirty, goes to the warm data log and its slot
%% follows it; its old block's section stays out of the free set, and the
%% other four logs keep their places.
a_dirty_dentry_block_goes_to_the_warm_data_log_test() ->
    {Partition, Medium} = Image = fresh(),
    {ok, #{root := #{addresses := [Old | _]} = Root, checkpoint := Header} = Mounted} = mount(Image),
    {ok, Dentries} = erx_f2fs_codec:dentry_block(maps:get(Old, Medium)),
    State0 = erx_f2fs_core:put_node(state(Mounted, Medium), ?ERX_F2FS_ROOT_INO, {inode, Root}),
    {ok, Cleared} = need(fun(B) -> erx_f2fs_core:set_slot(State0, ?ERX_F2FS_ROOT_INO, 0,
                                                         ?ERX_F2FS_NULL_ADDR, B) end, Medium),
    #{superblock := #{segs_per_sec := S}} = Mounted,
    ?assertNot(lists:member((Old - main(Mounted)) div ?SEG div S, erx_f2fs_core:free_sections(Cleared))),
    State = erx_f2fs_core:put_dentries(State0, {?ERX_F2FS_ROOT_INO, 0}, Dentries),
    {Plan, Committed} = checkpoint(State, Medium),
    check_plan(Mounted, State, Plan, Committed),
    Main = main(Mounted),
    [Dentry, Inode] = [A || {A, _} <- hd(Plan), A >= Main],
    ?assertEqual({?WARM_DATA, ?WARM_NODE}, {log_of(Dentry, State), log_of(Inode, State)}),
    Untouched = [0, 2, 3, 5],
    ?assertEqual([lists:nth(T + 1, erx_f2fs_core:logs(State)) || T <- Untouched],
                 [lists:nth(T + 1, erx_f2fs_core:logs(Committed)) || T <- Untouched]),
    After = written(Medium, Plan),
    {ok, #{root := #{addresses := [Dentry | _], i_blocks := 2},
           checkpoint := #{valid_block_count := Valid}} = Remounted} = mount({Partition, After}),
    ?assertEqual(maps:get(valid_block_count, Header), Valid),
    ?assertEqual([<<".">>, <<"..">>], names(Remounted, After)).

log_of(A, State) ->
    hd([T || T <- lists:seq(0, 5), lists:nth(T + 1, erx_f2fs_core:logs(State)) =:= A]).

%%% Logs that share a section

%% A volume another writer left with logs sharing sections, as mkfs.f2fs
%% leaves two to four ([T 19]): the wide volume, whose six logs share three
%% sections. The mount checkpoint moves all six to free sections, writes
%% the SSA blocks of the segments the warm logs leave, naming the root's
%% inode and dentry block, and its crash states and the cycles after it
%% stay valid.
logs_sharing_a_section_move_at_the_mount_checkpoint_test_() ->
    {timeout, 120, fun shared_sections/0}.

shared_sections() ->
    {Partition, Medium} = Shared = wide(fresh()),
    {ok, #{superblock := #{main_blkaddr := Main, ssa_blkaddr := Ssa}, logs := Logs} = Mounted} = mount(Shared),
    {?WARM_DATA, WarmData, 1, _} = lists:keyfind(?WARM_DATA, 1, Logs),
    {?WARM_NODE, WarmNode, 1, _} = lists:keyfind(?WARM_NODE, 1, Logs),
    State = state(Mounted, Medium),
    Section = fun(A) -> (A - Main) div ?SEG div 2 end,
    Before = [Section(Main + Segno * ?SEG) || {_, Segno, _, _} <- Logs],
    After = [Section(A) || A <- erx_f2fs_core:logs(State)],
    ?assertEqual(3, length(lists:usort(Before))),
    ?assertEqual([], [T || {T, B, A} <- lists:zip3(lists:seq(0, 5), Before, After), B =:= A]),
    {Plan, Committed} = checkpoint(State, Medium),
    check_plan(Mounted, State, Plan, Committed),
    crash_states(Shared, Mounted, Plan),
    Written = maps:from_list(lists:append(Plan)),
    Root = #{nid => ?ERX_F2FS_ROOT_INO, version => 0, ofs_in_node => 0},
    [?assertMatch({ok, #{entries := [Root | _], entry_type := Type}},
                  erx_f2fs_codec:summary_block(maps:get(Ssa + Segno, Written)))
     || {Segno, Type} <- [{WarmNode, ?ERX_F2FS_SUMMARY_NODE}, {WarmData, ?ERX_F2FS_SUMMARY_DATA}]],
    cycles({Partition, written(Medium, Plan)}, 2).
