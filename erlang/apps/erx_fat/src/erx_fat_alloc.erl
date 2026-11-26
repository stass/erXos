%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_alloc).
-moduledoc """
The FAT server's allocator (docs/design-storage.md, "Removable media: FAT"): the
cluster chains of one FAT16 or FAT32 volume as a pure core that reads the volume's
sectors through the function its layout carries (erx_fat:layout/1) and answers
write plans, `[{Step, [{Sector, Bytes}]}]`, which its caller writes in order with a
flush after each step. It does no I/O of its own, and its function must answer the
medium as every plan answered before has left it.

* **A batch.** grow/3, shrink/3 and free/2 change chains in an overlay of FAT
  entries, each tagged with the step of the batch that writes it, which
  commit/1 turns into sectors. The tag follows from the entry alone (step/2):
  every entry of a cluster the batch allocates goes in `allocation`, so each new
  run is a chain of its own ending in an end-of-chain mark that nothing reaches
  yet; a link or a mark on a cluster a live chain holds goes in `publication`;
  a cluster freed goes in `release`. A step's sectors carry every entry of the
  steps before it, so no write undoes an earlier step's.
* **Every copy.** Each sector goes to every FAT, the first first, built from the
  first's bytes; a FAT32 entry keeps the top four bits it was read with.
* **Allocation.** Next-fit from the cluster after the last one the mount
  allocated, starting at the first: the first run of free clusters long enough
  for the request, or failing that the first free clusters met. A cluster the
  batch freed is not free again until the batch is committed, so a cut before
  its release reaches the medium leaves every old entry naming its own data.
* **The volume's flags and FSInfo.** dirty/1 clears the clean bit of the FAT's
  second entry and writes FAT32's FSInfo hints unknown; finish/1 commits the
  last batch, writes in its release step a next-free hint, the cluster after the
  last one the mount allocated, when it allocated any, and then sets the clean
  bit. The hard-error bit is written as it was read. An FSInfo sector without
  its signatures is left as it is.
* **Chains read from the medium** are untrusted: one is followed only through
  clusters of the data area, each at most once, so a walk takes at most as many
  steps as the volume has clusters; a free, reserved or bad link, a loop, a link
  from the medium into a run the batch allocated and a link into a cluster the
  batch freed are each `does_not_read`. Those are the only crossings of two chains
  found: two chains the medium already joins elsewhere are followed as they are
  (a residual in docs/todo-storage.md).

A sector the function does not answer with 512 bytes is `read_failed`; a request
for more clusters than are free is `no_space`. Each finding leaves through one
throw, `{erx_fat_alloc, Finding}`, caught at each exported entry, and leaves the
allocator as it was.
""".

-export([new/1, chain/2, grow/3, shrink/3, free/2, commit/1, dirty/1, finish/1, volume_flags/2, writable/1]).
-export_type([alloc/0, layout/0, plan/0, step/0, finding/0, cluster/0]).

-define(SECTOR, 512).
%% Entry values (the FAT specification, section 4): free, the end-of-chain mark
%% this server writes, and the least value that ends a chain.
-define(FREE, 0).
-define(EOC_16, 16#ffff).
-define(EOC_32, 16#0fffffff).
-define(END_MARK_16, 16#fff8).
-define(END_MARK_32, 16#0ffffff8).
%% FAT32 keeps an entry's value in its low 28 bits; the top four are reserved.
-define(VALUE_32, 16#0fffffff).
-define(RESERVED_32, 16#f0000000).
%% The second entry's flags, each set while it holds: the volume was unmounted
%% cleanly, and no disk error was recorded (fsimg's lib/formats/fat/read.c:244-247
%% at b6c1ea2).
-define(CLEAN_16, 16#8000).
-define(NO_ERROR_16, 16#4000).
-define(CLEAN_32, 16#08000000).
-define(NO_ERROR_32, 16#04000000).
%% FSInfo's signatures and hints (fsimg's lib/formats/fat/verify.c:171-180).
-define(UNKNOWN, 16#ffffffff).
-define(STEPS, [allocation, publication, release]).

-type cluster() :: pos_integer().
-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
-type layout() :: #{read := read_sector(), type := 16 | 32, fat_start := pos_integer(), fats := pos_integer(),
                    fat_sectors := pos_integer(), clusters := pos_integer(), fsinfo := pos_integer() | none}.
-type step() :: dirty | allocation | publication | release | clean.
-type plan() :: [{step(), [{non_neg_integer(), binary()}]}].
-type finding() :: does_not_read | read_failed | no_space.

%% next is where the next search starts; allocated whether the mount has allocated
%% a cluster, so next names the one after the last it allocated. batch maps each
%% cluster whose entry the batch changes to {Step, Value}, Value the low bits.
-record(alloc, {read :: read_sector(),
                type :: 16 | 32,
                fat_start :: pos_integer(),
                fats :: pos_integer(),
                fat_sectors :: pos_integer(),
                clusters :: pos_integer(),
                fsinfo :: pos_integer() | none,
                next = 2 :: cluster(),
                allocated = false :: boolean(),
                batch = #{} :: #{cluster() => {allocation | publication | release, non_neg_integer()}}}).

-opaque alloc() :: #alloc{}.

%% ---------------------------------------------------------------------------
%% The volume's state
%% ---------------------------------------------------------------------------

-doc "The flags of the FAT's second entry, Entry, on a volume of FAT Type.".
-spec volume_flags(16 | 32, non_neg_integer()) -> #{clean := boolean(), hard_error := boolean()}.
volume_flags(Type, Entry) ->
    {Clean, NoError} = flag_bits(Type),
    #{clean => Entry band Clean =/= 0, hard_error => Entry band NoError =:= 0}.

-doc """
The writable rule's fourth condition (docs/design-drives.md, "The writable rule")
over erx_fat:info/1: the volume is not dirty, records no hard error and mirrors its
FATs, checked in that order; otherwise the reason it mounts read-only.
""".
-spec writable(#{clean := boolean(), hard_error := boolean(), mirrored := boolean(), _ => _}) ->
          ok | {read_only, dirty | hard_error | mirror}.
writable(#{clean := false}) -> {read_only, dirty};
writable(#{hard_error := true}) -> {read_only, hard_error};
writable(#{mirrored := false}) -> {read_only, mirror};
writable(#{}) -> ok.

-doc "The allocator of a volume a writable mount admitted, with no batch open.".
-spec new(layout()) -> alloc().
new(#{read := Read, type := Type, fat_start := FatStart, fats := Fats, fat_sectors := FatSectors,
      clusters := Clusters, fsinfo := FsInfo}) ->
    #alloc{read = Read, type = Type, fat_start = FatStart, fats = Fats, fat_sectors = FatSectors,
           clusters = Clusters, fsinfo = FsInfo}.

%% ---------------------------------------------------------------------------
%% Chains
%% ---------------------------------------------------------------------------

-doc "The chain from First as the batch leaves it, first to last.".
-spec chain(alloc(), cluster()) -> {ok, [cluster()]} | {error, finding()}.
chain(Alloc, First) ->
    guarded(fun() -> walk(Alloc, First) end).

-doc """
Count new clusters at the end of the chain from First, or as a new chain when First
is none: the new clusters, first to last, and the allocator holding them.
""".
-spec grow(alloc(), cluster() | none, pos_integer()) -> {ok, [cluster()], alloc()} | {error, finding()}.
grow(Alloc, First, Count) when is_integer(Count), Count >= 1 ->
    guarded(fun() ->
                    Tail = case First of none -> none; _ -> follow(Alloc, First, fun(Cluster, _) -> Cluster end, none) end,
                    Run = find(Alloc, Count),
                    Linked = lists:foldl(fun({Cluster, Next}, Acc) -> fresh(Acc, Cluster, Next) end,
                                         Alloc, lists:zip(Run, tl(Run) ++ [eoc(Alloc)])),
                    Grown = case Tail of none -> Linked; _ -> set(Linked, Tail, hd(Run)) end,
                    {Run, Grown#alloc{next = after_cluster(Alloc, lists:last(Run)), allocated = true}}
            end).

-doc """
The chain from First cut to its first Keep clusters, the rest freed; Keep 0 frees
it all. A chain shorter than Keep is does_not_read.
""".
-spec shrink(alloc(), cluster(), non_neg_integer()) -> {ok, alloc()} | {error, finding()}.
shrink(Alloc, First, Keep) when is_integer(Keep), Keep >= 0 ->
    guarded(fun() ->
                    Chain = walk(Alloc, First),
                    length(Chain) >= Keep orelse fail(does_not_read),
                    {Kept, Cut} = lists:split(Keep, Chain),
                    Ended = case {Kept, Cut} of
                                {[], _} -> Alloc;
                                {_, []} -> Alloc;
                                _ -> set(Alloc, lists:last(Kept), eoc(Alloc))
                            end,
                    lists:foldl(fun(Cluster, Acc) -> set(Acc, Cluster, ?FREE) end, Ended, Cut)
            end).

-doc "Every cluster of the chain from First freed.".
-spec free(alloc(), cluster()) -> {ok, alloc()} | {error, finding()}.
free(Alloc, First) ->
    shrink(Alloc, First, 0).

%% The chain from First through the batch's entries, first to last.
walk(Alloc, First) ->
    lists:reverse(follow(Alloc, First, fun(Cluster, Got) -> [Cluster | Got] end, [])).

%% The chain from First folded through Take, cluster by cluster. A chain takes at
%% most as many links as the volume has clusters less one, so one that takes more
%% loops. A link the medium holds may not reach a run the batch allocated, and no
%% link a cluster the batch freed.
follow(Alloc = #alloc{clusters = Clusters}, First, Take, Acc) ->
    data_cluster(Alloc, First),
    freed(Alloc, First) andalso fail(does_not_read),
    follow(Alloc, First, Clusters, Take, Take(First, Acc), none).

follow(_Alloc, _Cluster, 0, _Take, _Acc, _Cache) ->
    fail(does_not_read);
follow(Alloc = #alloc{batch = Batch}, Cluster, Left, Take, Acc, Cache) ->
    {Value, Read} = case Batch of
                        #{Cluster := {_Step, Entry}} -> {Entry, Cache};
                        #{} -> medium(Alloc, Cluster, Cache)
                    end,
    case end_of_chain(Alloc, Value) of
        true ->
            Acc;
        false ->
            Next = data_cluster(Alloc, Value),
            Crossed = freed(Alloc, Next)
                orelse (fresh_cluster(Alloc, Next) andalso not is_map_key(Cluster, Batch)),
            Crossed andalso fail(does_not_read),
            follow(Alloc, Next, Left - 1, Take, Take(Next, Acc), Read)
    end.

%% Value as a cluster of the data area, the one check every link passes.
data_cluster(#alloc{clusters = Clusters}, Value) when is_integer(Value), Value >= 2, Value < Clusters + 2 ->
    Value;
data_cluster(_Alloc, _Value) ->
    fail(does_not_read).

end_of_chain(#alloc{type = 16}, Value) -> Value >= ?END_MARK_16;
end_of_chain(#alloc{type = 32}, Value) -> Value >= ?END_MARK_32.

eoc(#alloc{type = 16}) -> ?EOC_16;
eoc(#alloc{type = 32}) -> ?EOC_32.

freed(#alloc{batch = Batch}, Cluster) ->
    element(1, maps:get(Cluster, Batch, {none, 0})) =:= release.

fresh_cluster(#alloc{batch = Batch}, Cluster) ->
    element(1, maps:get(Cluster, Batch, {none, 0})) =:= allocation.

%% A cluster this batch allocates, Value its entry.
fresh(Alloc = #alloc{batch = Batch}, Cluster, Value) ->
    Alloc#alloc{batch = Batch#{Cluster => {allocation, Value}}}.

%% Cluster's entry set to Value, in the step that entry belongs to.
set(Alloc = #alloc{batch = Batch}, Cluster, Value) ->
    Step = step(fresh_cluster(Alloc, Cluster), Value),
    Alloc#alloc{batch = Batch#{Cluster => {Step, Value}}}.

%% The step that writes an entry: a freed cluster's in release, a cluster's the
%% batch allocated in allocation, and a link or mark on a live chain in
%% publication.
step(_Fresh, ?FREE) -> release;
step(true, _Value) -> allocation;
step(false, _Value) -> publication.

%% ---------------------------------------------------------------------------
%% Allocation
%% ---------------------------------------------------------------------------

%% Count free clusters, next-fit from next: the first run of Count contiguous ones,
%% the search wrapping once from the last cluster to the first, or else the first
%% Count met. A cluster the batch names in any step is not free.
find(#alloc{clusters = Clusters}, Count) when Count > Clusters ->
    fail(no_space);
find(Alloc = #alloc{next = Next, clusters = Clusters}, Count) ->
    Ranges = [{Next, Clusters + 1}, {2, Next - 1}],
    case lists:foldl(fun(Range, Acc) -> scan(Alloc, Range, Count, Acc) end,
                     #{run => {0, []}, met => {0, []}, cache => none}, Ranges) of
        #{run := {Count, Run}} -> lists:reverse(Run);
        #{met := {Count, Met}} -> lists:reverse(Met);
        #{} -> fail(no_space)
    end.

%% A range of clusters scanned in order, one FAT sector read at a time. run is the
%% current run of free clusters and met the first Count free ones, each with its
%% length; the last cluster and the first are not adjacent, so a run does not
%% continue across a range's end.
scan(_Alloc, _Range, Count, Acc = #{run := {Count, _}}) ->
    Acc;
scan(_Alloc, {Low, High}, _Count, Acc) when Low > High ->
    Acc#{run := {0, []}};
scan(Alloc = #alloc{batch = Batch}, {Cluster, High}, Count,
     Acc = #{run := {RunLength, Run}, met := {MetLength, Met}, cache := Cache}) ->
    {Value, Read} = medium(Alloc, Cluster, Cache),
    Next = case not is_map_key(Cluster, Batch) andalso Value =:= ?FREE of
               true when MetLength < Count -> Acc#{run := {RunLength + 1, [Cluster | Run]},
                                                    met := {MetLength + 1, [Cluster | Met]}};
               true -> Acc#{run := {RunLength + 1, [Cluster | Run]}};
               false -> Acc#{run := {0, []}}
           end,
    scan(Alloc, {Cluster + 1, High}, Count, Next#{cache := Read}).

after_cluster(#alloc{clusters = Clusters}, Cluster) when Cluster >= Clusters + 1 -> 2;
after_cluster(_Alloc, Cluster) -> Cluster + 1.

%% ---------------------------------------------------------------------------
%% Plans
%% ---------------------------------------------------------------------------

-doc """
The batch's plan, its allocation, publication and release steps each with the FAT
sectors it writes, steps without a write left out; and the allocator with no batch
open.
""".
-spec commit(alloc()) -> {ok, plan(), alloc()} | {error, finding()}.
commit(Alloc) ->
    guarded(fun() -> {batch_plan(Alloc), Alloc#alloc{batch = #{}}} end).

-doc """
The plan that marks the volume in use before its first change: the second entry's
clean bit cleared in every FAT and FAT32's FSInfo hints unknown, one step.
""".
-spec dirty(alloc()) -> {ok, plan()} | {error, finding()}.
dirty(Alloc) ->
    guarded(fun() ->
                    {Clean, _} = flag_bits(Alloc#alloc.type),
                    [{dirty, flag_writes(Alloc, fun(Entry) -> Entry band bnot Clean end, [])
                      ++ fsinfo_writes(Alloc, ?UNKNOWN)}]
            end).

-doc """
The volume's last batch: commit/1's plan with the next-free hint in its release
step, when the mount allocated, then the clean bit set in every FAT.
""".
-spec finish(alloc()) -> {ok, plan(), alloc()} | {error, finding()}.
finish(Alloc = #alloc{next = Next, allocated = Allocated}) ->
    guarded(fun() ->
                    Hint = case Allocated of true -> fsinfo_writes(Alloc, keep, Next); false -> [] end,
                    Batch = case {batch_plan(Alloc), Hint} of
                                {Plan, []} -> Plan;
                                {Plan, _} -> lists:keystore(release, 1, Plan,
                                                            {release, proplists:get_value(release, Plan, []) ++ Hint})
                            end,
                    {Clean, _} = flag_bits(Alloc#alloc.type),
                    Entries = maps:get(0, by_sector(Alloc), []),
                    {Batch ++ [{clean, flag_writes(Alloc, fun(Entry) -> Entry bor Clean end, Entries)}],
                     Alloc#alloc{batch = #{}}}
            end).

%% Each step's FAT sectors, each built from the medium's with the entries of that
%% step and of every step before it.
batch_plan(Alloc) ->
    BySector = maps:to_list(by_sector(Alloc)),
    {Plan, _Earlier} =
        lists:foldl(fun(Step, {Acc, Earlier}) ->
                            Upto = [Step | Earlier],
                            Bytes = [{Index, patched(Alloc, Index, [{C, V} || {S, C, V} <- Entries, lists:member(S, Upto)])}
                                     || {Index, Entries} <- lists:sort(BySector), lists:keymember(Step, 1, Entries)],
                            {[{Step, copies(Alloc, Bytes)} || Bytes =/= []] ++ Acc, Upto}
                    end, {[], []}, ?STEPS),
    lists:reverse(Plan).

%% The batch's entries by the FAT sector each lies in, as {Step, Cluster, Value}.
by_sector(Alloc = #alloc{batch = Batch}) ->
    maps:groups_from_list(fun({_Step, Cluster, _Value}) -> entry_sector(Alloc, Cluster) end,
                          [{Step, Cluster, Value} || Cluster := {Step, Value} <- Batch]).

%% FAT sector Index of the first FAT with Entries, each of which lies in it, written.
patched(Alloc = #alloc{type = Type}, Index, Entries) ->
    lists:foldl(fun({Cluster, Value}, Sector) ->
                        Offset = entry_offset(Alloc, Cluster),
                        <<Before:Offset/binary, Old:Type/little, After/binary>> = Sector,
                        <<Before/binary, (encode(Type, Old, Value)):Type/little, After/binary>>
                end, fat_sector(Alloc, Index), Entries).

%% An entry's bytes: FAT32 keeps the top four bits the entry held.
encode(16, _Old, Value) -> Value;
encode(32, Old, Value) -> (Old band ?RESERVED_32) bor (Value band ?VALUE_32).

%% Sectors of the first FAT, each written to every FAT, the first first.
copies(#alloc{fat_start = FatStart, fats = Fats, fat_sectors = FatSectors}, Sectors) ->
    [{FatStart + Copy * FatSectors + Index, Bytes} || Copy <- lists:seq(0, Fats - 1), {Index, Bytes} <- Sectors].

%% The second entry, rewritten by Change, in every FAT, its sector carrying Entries,
%% the batch's that the steps before have written.
flag_writes(Alloc = #alloc{type = Type}, Change, Entries) ->
    Offset = Type div 8,
    <<First:Offset/binary, Entry:Type/little, After/binary>> = patched(Alloc, 0, [{C, V} || {_, C, V} <- Entries]),
    copies(Alloc, [{0, <<First/binary, (Change(Entry)):Type/little, After/binary>>}]).

flag_bits(16) -> {?CLEAN_16, ?NO_ERROR_16};
flag_bits(32) -> {?CLEAN_32, ?NO_ERROR_32}.

%% FAT32's FSInfo sector with its free count and next-free hint set, the count
%% kept as it is when keep; none on FAT16, without an FSInfo sector, or when the
%% sector lacks its signatures.
fsinfo_writes(Alloc, Hint) -> fsinfo_writes(Alloc, Hint, Hint).

fsinfo_writes(#alloc{fsinfo = none}, _Count, _Next) ->
    [];
fsinfo_writes(Alloc = #alloc{fsinfo = Sector}, Count, Next) ->
    case sector(Alloc, Sector) of
        <<16#41615252:32/little, Middle:480/binary, 16#61417272:32/little, Old:32/little, _:32,
          Rest:12/binary, 16#aa550000:32/little>> ->
            Kept = case Count of keep -> Old; _ -> Count end,
            [{Sector, <<16#41615252:32/little, Middle/binary, 16#61417272:32/little, Kept:32/little,
                        Next:32/little, Rest/binary, 16#aa550000:32/little>>}];
        _ ->
            []
    end.

%% ---------------------------------------------------------------------------
%% The medium
%% ---------------------------------------------------------------------------

guarded(Fun) ->
    try Fun() of
        {Result, #alloc{} = Alloc} -> {ok, Result, Alloc};
        #alloc{} = Alloc -> {ok, Alloc};
        Result -> {ok, Result}
    catch throw:{?MODULE, Finding} -> {error, Finding}
    end.

fail(Finding) -> throw({?MODULE, Finding}).

sector(#alloc{read = Read}, Index) ->
    case Read(Index) of
        {ok, <<Bytes:?SECTOR/binary>>} -> Bytes;
        _ -> fail(read_failed)
    end.

%% The sector of a FAT that holds Cluster's entry, as an index into the FAT.
entry_sector(#alloc{type = Type}, Cluster) -> Cluster * (Type div 8) div ?SECTOR.

%% Where in its sector Cluster's entry lies.
entry_offset(#alloc{type = Type}, Cluster) -> Cluster * (Type div 8) rem ?SECTOR.

%% Sector Index of the first FAT, as the medium holds it.
fat_sector(Alloc = #alloc{fat_start = FatStart}, Index) -> sector(Alloc, FatStart + Index).

%% Cluster's entry as the medium holds it, in its value bits, read through Cache,
%% the last FAT sector read as {Index, Bytes} or none; with the sector read.
medium(Alloc = #alloc{type = Type}, Cluster, Cache) ->
    Index = entry_sector(Alloc, Cluster),
    Bytes = case Cache of {Index, Cached} -> Cached; _ -> fat_sector(Alloc, Index) end,
    Offset = entry_offset(Alloc, Cluster),
    <<_:Offset/binary, Entry:Type/little, _/binary>> = Bytes,
    {case Type of 16 -> Entry; 32 -> Entry band ?VALUE_32 end, {Index, Bytes}}.
