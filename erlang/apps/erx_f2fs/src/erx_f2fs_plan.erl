%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_plan).
-moduledoc """
F2FS's checkpoint plan (docs/design-f2fs.md, "Checkpoints"): a pure
function from erx_f2fs_core's state to the blocks a checkpoint writes, in
phases, and the state once it has committed. The volume process writes
each phase and then flushes, and adopts the committed state only once
the last flush is answered, so an address enters the state only after
its block's write is answered and the commit block is written only after
a flush answered after every write it covers (orderings 1 and 2 of "The
durable view is never overwritten").

The first phase holds, each in address order: the dirty dentry blocks,
each allocated in the warm data log and set in its directory's slot;
the dirty nodes, direct nodes and inodes before indirect nodes, each
allocated in the warm node log with its footer completed there: the
committed version with the committed CRC in its upper 32 bits, the
log's next block, and no fsync or dentry mark ([F 43]); the NAT blocks
holding an entry the epoch changed or the journal kept, and the SIT
blocks holding a segment the epoch changed or the journal kept, each
whole into the copy the committed version bitmap does not select, its
bit flipped ([F 34], [F 38]); the SSA block of every unpublished summary
whose segment is not one of the new checkpoint's logs ([F 45]); and the
new pack, in the pack the committed checkpoint is not in, but for its
last block. The second phase is that last block, the header's copy
([F 22]). The volume writes only two logs, warm node and warm data
(docs/design-f2fs.md, "Scope: features and forms"), so every node goes
to the first and every dentry block to the second.

The header carries the version one above the committed one, the
counters, the six logs' next blocks, every log LFS, CRC_RECOVERY, and
ORPHAN_PRESENT exactly when orphans exist, FSCK and QUOTA_NEED_FSCK when
the committed checkpoint had them, and the free segments: those with no
valid block that are not a log's ([T 74]). The journals are empty and
the pack's three data summaries are the current data logs' in the
normal form; the node logs' summaries are rebuilt from their footers by
the next read-write mount ([F 31]).

A failure is {Structure, Rule}, a NAT block's read failing its decoder,
or {space, no_free_section} when a log cannot take a section.
""".

-export([checkpoint/2]).
-export_type([plan/0]).

-include("generated/erx_abi.hrl").

-define(BLOCKS_PER_SEG, (1 bsl ?ERX_F2FS_LOG_BLOCKS_PER_SEG)).
-define(LOG_TYPES, ?ERX_F2FS_SIT_TYPES).
-define(WARM_DATA, 1).
-define(WARM_NODE, (?ERX_F2FS_LOG_HOT_NODE + 1)).
-define(LOGS_PER_KIND, 3).
%% The flags a checkpoint keeps from the one before it ([R 27]).
-define(KEPT_FLAGS, (?ERX_F2FS_CP_FSCK bor ?ERX_F2FS_CP_QUOTA_NEED_FSCK)).

-doc "A plan's phases, each the blocks it writes in address order, a flush after each.".
-type plan() :: [[{non_neg_integer(), binary()}]].

-doc """
The checkpoint of State from Blocks, the blocks read so far: {ok, Plan,
Committed}, the state once Plan's last flush is answered, {need,
Addresses} naming the NAT and SSA blocks it needs, or {error, Failure}.
""".
-spec checkpoint(erx_f2fs_core:state(), erx_f2fs_core:blocks()) ->
          {ok, plan(), erx_f2fs_core:state()} | {need, [non_neg_integer()]} |
          {error, term()}.
checkpoint(State0, Blocks) ->
    try
        #{dentries := Dentries, nodes := Dirty} = erx_f2fs_core:epoch(State0),
        {DentryWrites, State1} = lists:mapfoldl(fun(D, S) -> dentry(D, S, Blocks) end, State0, Dentries),
        {Leaves, Indirect} = lists:partition(fun({_, {Kind, _, _}}) -> Kind =/= indirect;
                                                (_) -> true end, Dirty),
        {NodeWrites, State2} = lists:mapfoldl(fun(N, S) -> node(N, S, Blocks) end, State1,
                                              Leaves ++ Indirect),
        #{volume := #{superblock := Super, pack := Pack}} = Epoch =
            erx_f2fs_core:epoch(State2),
        {NatWrites, NatBitmap} = nat(Epoch, Blocks),
        {SitWrites, SitBitmap} = sit(Epoch),
        Header = header(Epoch, NatBitmap, SitBitmap),
        NewPack = other_pack(Super, Pack),
        PackBlocks = erx_f2fs_codec:encode_pack(Super, Header, maps:get(orphans, Epoch),
                                                data_summaries(Epoch)),
        {Body, [{Last, Copy}]} = lists:split(length(PackBlocks) - 1, lists:enumerate(NewPack, PackBlocks)),
        Phase1 = lists:keysort(1, DentryWrites ++ NodeWrites ++ NatWrites ++ SitWrites ++
                                  ssa(Epoch) ++ Body),
        {ok, Read} = decode_header(Super, PackBlocks),
        {ok, [Phase1, [{Last, Copy}]], erx_f2fs_core:committed(State2, Read, NewPack)}
    catch
        throw:{?MODULE, need, Addresses} -> {need, Addresses};
        throw:{?MODULE, failure, Failure} -> {error, Failure}
    end.

%% A dirty dentry block, allocated in the warm data log and set in its slot.
dentry({{Owner, Index}, Dentries}, State, Blocks) ->
    {[Address], State1} = allocate(State, ?WARM_DATA),
    {{Address, erx_f2fs_codec:encode_dentry_block(Dentries)},
     result(erx_f2fs_core:set_slot(State1, Owner, Index, Address, Blocks))}.

%% A dirty node, allocated in the warm node log; its footer names the
%% log's next block, read after the allocation.
node({Nid, _}, State, Blocks) ->
    {[Address], State1} = allocate(State, ?WARM_NODE),
    Next = lists:nth(?WARM_NODE + 1, erx_f2fs_core:logs(State1)),
    #{nodes := Nodes, volume := #{superblock := Super, checkpoint := Committed}} =
        erx_f2fs_core:epoch(State1),
    {Nid, Value} = lists:keyfind(Nid, 1, Nodes),
    Ino = ino(Nid, Value),
    State2 = result(erx_f2fs_core:set_node(State1, Nid, Ino, Address, Blocks)),
    {{Address, erx_f2fs_core:encode_node(Super, completed(Value, fun(Footer) -> footer(Footer, Committed, Next) end))},
     State2}.

ino(_Nid, {inode, #{footer := #{ino := Ino}}}) -> Ino;
ino(_Nid, {_Kind, _Body, #{ino := Ino}}) -> Ino.

%% A node's value with its footer completed by Complete.
completed({inode, #{footer := Footer} = Inode}, Complete) -> {inode, Inode#{footer := Complete(Footer)}};
completed({Kind, Body, Footer}, Complete) -> {Kind, Body, Complete(Footer)}.

footer(#{flag := Flag} = Footer, #{checkpoint_ver := Version, crc := Crc}, Next) ->
    Footer#{flag := Flag band bnot (?ERX_F2FS_NODE_MARK_FSYNC bor ?ERX_F2FS_NODE_MARK_DENTRY),
            cp_ver := Version bor (Crc bsl 32), next_blkaddr := Next}.

allocate(State, Type) ->
    case erx_f2fs_core:allocate(State, Type, 1) of
        {ok, Addresses, State1} -> {Addresses, State1};
        {error, enospc} -> fail({space, no_free_section})
    end.

%% Each NAT block holding an entry the epoch changed or the journal kept:
%% its selected copy's entries with those over them, into the other copy.
nat(#{volume := #{superblock := Super, checkpoint := #{nat_version_bitmap := Bitmap} = Header},
      nat := Entries}, Blocks) ->
    PerBlock = ?ERX_F2FS_NAT_ENTRIES_PER_BLOCK,
    Grouped = group(fun({Nid, _}) -> Nid div PerBlock end, Entries),
    Current = [erx_f2fs_codec:current_block(nat, Super, Header, Index) || {Index, _} <- Grouped],
    Read = fetch(Blocks, Current),
    Writes = [{erx_f2fs_codec:table_block(nat, Super, 1 - erx_f2fs_codec:bit(Bitmap, Index), Index),
               erx_f2fs_codec:encode_nat_block(
                 lists:foldl(fun({Nid, Entry}, Acc) -> replace(Acc, Nid rem PerBlock, Entry) end,
                             decoded(erx_f2fs_codec:nat_block(Block)), Changed))}
              || {{Index, Changed}, Block} <- lists:zip(Grouped, Read)],
    {Writes, flip(Bitmap, [Index || {Index, _} <- Grouped])}.

%% Each SIT block holding a segment the epoch changed or the journal kept,
%% from the state's SIT, into the other copy.
sit(#{volume := #{superblock := Super, checkpoint := #{sit_version_bitmap := Bitmap}, sit := Sit},
      sit_segments := Segments}) ->
    PerBlock = ?ERX_F2FS_SIT_ENTRIES_PER_BLOCK,
    Indices = lists:usort([Segno div PerBlock || Segno <- Segments]),
    Writes = [{erx_f2fs_codec:table_block(sit, Super, 1 - erx_f2fs_codec:bit(Bitmap, Index), Index),
               erx_f2fs_codec:encode_sit_block(
                 [element(Segno + 1, Sit)
                  || Segno <- lists:seq(Index * PerBlock,
                                        min(tuple_size(Sit), (Index + 1) * PerBlock) - 1)])}
              || Index <- Indices],
    {Writes, flip(Bitmap, Indices)}.

%% The SSA block of every unpublished summary whose segment is not one of
%% the new checkpoint's logs ([F 45]).
ssa(#{volume := #{superblock := #{ssa_blkaddr := Ssa, main_blkaddr := Main}, sit := Sit},
      logs := Logs, summaries := Summaries}) ->
    LogSegments = [(A - Main) div ?BLOCKS_PER_SEG || A <- Logs],
    [{Ssa + Segno, erx_f2fs_codec:encode_summary_block(Entries, summary_type(element(Segno + 1, Sit)))}
     || {Segno, Entries} <- Summaries, not lists:member(Segno, LogSegments)].

summary_type(#{type := Type}) when Type >= ?ERX_F2FS_LOG_HOT_NODE -> ?ERX_F2FS_SUMMARY_NODE;
summary_type(#{}) -> ?ERX_F2FS_SUMMARY_DATA.

%% The current data logs' summaries, hot, warm and cold, in the normal form.
data_summaries(#{volume := #{superblock := #{main_blkaddr := Main}}, logs := Logs,
                 summaries := Summaries}) ->
    [erx_f2fs_codec:encode_summary_block(element(2, lists:keyfind((A - Main) div ?BLOCKS_PER_SEG, 1,
                                                                   Summaries)),
                                         ?ERX_F2FS_SUMMARY_DATA)
     || A <- lists:sublist(Logs, ?LOGS_PER_KIND)].

header(#{volume := #{superblock := #{main_blkaddr := Main}, checkpoint := Committed, sit := Sit},
         logs := Logs, counts := Counts, orphans := Orphans}, NatBitmap, SitBitmap) ->
    #{checkpoint_ver := Version, ckpt_flags := Flags, cur_node_segno := NodeSegnos,
      cur_node_blkoff := NodeOffsets, cur_data_segno := DataSegnos,
      cur_data_blkoff := DataOffsets, alloc_type := Alloc} = Committed,
    Positions = [{(A - Main) div ?BLOCKS_PER_SEG, (A - Main) rem ?BLOCKS_PER_SEG} || A <- Logs],
    {Data, Node} = lists:split(?LOGS_PER_KIND, Positions),
    LogSegments = [Segno || {Segno, _} <- Positions],
    Free = length([Segno || {Segno, #{valid_blocks := 0}} <- lists:enumerate(0, tuple_to_list(Sit)),
                            not lists:member(Segno, LogSegments)]),
    maps:merge(Committed,
               Counts#{checkpoint_ver => Version + 1,
                       free_segment_count => Free,
                       cur_node_segno => over([S || {S, _} <- Node], NodeSegnos),
                       cur_node_blkoff => over([O || {_, O} <- Node], NodeOffsets),
                       cur_data_segno => over([S || {S, _} <- Data], DataSegnos),
                       cur_data_blkoff => over([O || {_, O} <- Data], DataOffsets),
                       alloc_type => binary:copy(<<?ERX_F2FS_ALLOC_LFS>>, byte_size(Alloc)),
                       ckpt_flags => ?ERX_F2FS_CP_CRC_RECOVERY bor (Flags band ?KEPT_FLAGS) bor
                           case Orphans of
                               [] -> 0;
                               _ -> ?ERX_F2FS_CP_ORPHAN_PRESENT
                           end,
                       checksum_offset => (1 bsl ?ERX_F2FS_LOG_BLOCK_SIZE) - 4,
                       nat_version_bitmap => NatBitmap, sit_version_bitmap => SitBitmap}).

%% The header as a mount reads it, its CRC included.
decode_header(#{cp_payload := Payload} = Super, [Header | Rest]) ->
    erx_f2fs_codec:checkpoint(Super, Header, lists:sublist(Rest, Payload)).

other_pack(#{cp_blkaddr := First}, First) -> First + ?BLOCKS_PER_SEG;
other_pack(#{cp_blkaddr := First}, _Pack) -> First.

%% A log array's first three entries replaced, the rest kept ([F 21]).
over(New, Old) -> New ++ lists:nthtail(length(New), Old).

flip(Bitmap, Indices) ->
    lists:foldl(fun(Index, Bits) ->
                        <<Before:Index/bitstring, Bit:1, After/bitstring>> = Bits,
                        <<Before/bitstring, (1 - Bit):1, After/bitstring>>
                end, Bitmap, Indices).

group(Key, List) ->
    maps:to_list(maps:groups_from_list(Key, List)).

replace(List, Index, Value) ->
    {Before, [_ | After]} = lists:split(Index, List),
    Before ++ [Value | After].

fetch(Blocks, Addresses) ->
    case [A || A <- Addresses, not is_map_key(A, Blocks)] of
        [] -> [maps:get(A, Blocks) || A <- Addresses];
        Missing -> throw({?MODULE, need, lists:usort(Missing)})
    end.

result({ok, Value}) -> Value;
result({need, Addresses}) -> throw({?MODULE, need, Addresses});
result({error, Failure}) -> fail(Failure).

decoded({ok, Value}) -> Value;
decoded({error, Failure}) -> fail(Failure).

-spec fail(term()) -> no_return().
fail(Failure) -> throw({?MODULE, failure, Failure}).
