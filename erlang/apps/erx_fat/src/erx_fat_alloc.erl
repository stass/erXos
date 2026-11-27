%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_alloc).
-moduledoc """
The FAT server's allocator (docs/design-storage.md, "Removable media: FAT"): the
cluster chains of one FAT16 or FAT32 volume as a pure core that reads the volume's
sectors through the function its layout carries (erx_fat:layout/1) and answers
write plans, `[{Step, [{Sector, Bytes}]}]`, which its caller writes in order with a
flush after each step. It does no I/O of its own, and its function must answer the
medium as every plan answered before has left it. It starts on a volume whose
ownership check (erx_fat:check/3) passed, so every chain it reaches is one name's
and no chain reaches a free cluster.

* **A batch.** grow/3 and shrink/3 change chains in an overlay of FAT entries,
  each tagged with the step of the batch that writes it (set/3): every entry of a
  cluster the batch allocates goes in `preparation`, so each new run is a chain of
  its own ending in an end-of-chain mark that nothing reaches yet, and a link from
  one of its entries into another FAT sector is an end-of-chain mark there and the
  link in `linking` (written/3), so preparation's sectors, landed in any order or
  in part, leave lost clusters at worst; the link from a live chain's last
  cluster to a new run goes in `linking`; and an entry that
  replaces a live chain's link, the end-of-chain mark that cuts it or, when a file
  shrinks and grows in one batch, the cut cluster's link to its new run, goes in
  `cutting`, after the caller's `publication` step has shrunk the file's size. A step's sectors carry every
  entry of the steps before it, so no write undoes an earlier step's. The
  allocator writes nothing in `publication`, which holds directory entries alone.
* **Release.** What a shrink cuts off, or a chain freed whole, waits as its first
  cluster alone. commit/1 frees the waiting chains in its `release` step, in the
  order they came, each from its first cluster on through the batch's entries and
  the medium, for as long as the step's FAT sectors stay within ?BATCH_SECTORS; a
  chain it does not finish waits from the cluster it reached, for the next
  commit. Releases are chosen only at commit, after every allocation of the
  batch, and a waiting chain's entries are not free on the medium, so a cluster
  freed in a batch is allocated again only in a later one, by construction.
* **Every copy.** Each sector goes to every FAT, the first first, built from the
  first's bytes; a FAT32 entry keeps the top four bits it was read with.
* **Allocation.** Next-fit from the cluster after the last one the mount
  allocated, starting at the first: the first run of clusters free on the medium
  and not in the batch long enough for the request, or failing that the first
  such clusters met.
* **The measure.** held/1 is the batch's share of what the volume holds: each FAT
  sector once for every step that writes it, and one sector for each waiting
  chain. A grow of N clusters adds at most one sector per ?SECTOR bytes of their
  entries, so a caller that grows a cluster at a time with the data it holds
  keeps the overlay within the batch's bound.
* **The volume's flags and FSInfo.** dirty/1 clears the clean bit of the FAT's
  second entry and writes FAT32's FSInfo hints unknown; finish/1 commits batches
  until no chain waits, writes in the last one's release step a next-free hint
  when the mount allocated any cluster, the first cluster the next-fit search
  would allocate from there, which is free once the batch is written, or unknown
  when no cluster outside the batch is free before it, and then sets the clean
  bit. The FAT the server reads is the first copy to lose the
  clean bit and the last to get it back, each in a step of its own, so it reads
  dirty whenever its copies may disagree, and a cut between copies never leaves a
  clean volume whose FATs differ. The hard-error bit is written as it was read. An
  FSInfo sector without its signatures is left as it is.
* **Chains read from the medium** are untrusted: one is followed only through
  clusters of the data area, at most as many links as the volume has clusters,
  and a release frees each cluster it reaches before it follows the next, so a
  release that comes back to a cluster reads it free; a free, reserved or bad
  link and a loop are each `does_not_read`.

A sector the function does not answer with 512 bytes is `read_failed`; a request
for more clusters than are free is `no_space`. Each finding leaves through one
throw, `{erx_fat_alloc, Finding}`, caught at each exported entry, and leaves the
allocator as it was.
""".

-export([new/1, chain/2, span/3, grow/3, shrink/3, free/2, held/1, commit/1, dirty/1, finish/1, finish/2, volume_flags/2, fsinfo/1, entry_place/2,
         writable/1, view/1, batch_sectors/0, held_sector_words/0]).
-export_type([alloc/0, layout/0, plan/0, step/0, finding/0, cluster/0]).

-include("generated/erx_abi.hrl").

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
%% The steps that write FAT entries of the overlay, in the batch's order; the
%% caller's publication step lies between linking and cutting, and release follows.
-define(STEPS, [preparation, linking, cutting]).
%% What one sector a batch holds costs the volume's memory bound when a collection
%% checks it (docs/design-drives.md, "Time and memory"): its 512-byte image, and as
%% much again for the image a later change replaced until a collection frees it; and
%% its share of the batch's maps, at most ?HELD_SECTOR_WORDS words of heap, which a
%% collection counts four times (the young heap's slack, the new heap it builds and
%% the old one at once; measured on the BEAM for the node table, erx_media_volume's
%% TABLE_MAX): 2 x 512 + 4 x ?HELD_SECTOR_WORDS x 8 bytes, rounded up to a whole KiB.
%% (erx_media_volume_write_tests checks the heap words a held sector costs against
%% ?HELD_SECTOR_WORDS.)
-define(HELD_SECTOR_WORDS, 30).
-define(HELD_SECTOR_BYTES, ((2 * ?SECTOR + 4 * ?HELD_SECTOR_WORDS * 8 + 1023) div 1024 * 1024)).
%% The sectors a batch holds before it commits (erx_fat_dir:full/1) and the FAT
%% sectors one release step writes at most: a quarter of the volume's memory bound,
%% media_volume_bytes, at what each costs.
-define(BATCH_SECTORS, (?ERX_MEDIA_VOLUME_BYTES div 4 div ?HELD_SECTOR_BYTES)).

-type cluster() :: pos_integer().
-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
-type layout() :: #{read := read_sector(), type := 16 | 32, fat_start := pos_integer(), fats := pos_integer(),
                    fat_sectors := pos_integer(), clusters := pos_integer(), fsinfo := pos_integer() | none}.
-type step() :: dirty | dirty_mirrors | preparation | linking | publication | cutting | release | clean_mirrors | clean.
-type plan() :: [{step(), [{non_neg_integer(), binary()}]}].
-type finding() :: does_not_read | read_failed | no_space.

%% next is where the next search starts; allocated whether the mount has allocated
%% a cluster, so next names the one after the last it allocated. batch maps each
%% cluster whose entry the batch changes to {fresh, Value} for one it allocates or
%% {live, Value}, Value the low bits;
%% waiting holds the chains to free, each as {Cluster, Left}: the first cluster not
%% yet freed and how many more clusters its release may free, the volume's count at
%% first, so a medium that answers a chain differently on a later read cannot keep
%% a release going across commits.
-record(alloc, {read :: read_sector(),
                type :: 16 | 32,
                fat_start :: pos_integer(),
                fats :: pos_integer(),
                fat_sectors :: pos_integer(),
                clusters :: pos_integer(),
                fsinfo :: pos_integer() | none,
                next = 2 :: cluster(),
                allocated = false :: boolean(),
                batch = #{} :: #{cluster() => {fresh | live, non_neg_integer()}},
                waiting = [] :: [{cluster(), non_neg_integer()}]}).

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
FAT32's FSInfo sector Bytes (the FAT specification, section 5): its free count and
next-free hint, each unknown as 16#ffffffff, or `unsigned` when one of its three
signatures is wrong, so its hints mean nothing.
""".
-spec fsinfo(<<_:4096>>) -> {non_neg_integer(), non_neg_integer()} | unsigned.
fsinfo(<<16#41615252:32/little, _:480/binary, 16#61417272:32/little, Free:32/little, Next:32/little, _:12/binary,
         16#aa550000:32/little>>) ->
    {Free, Next};
fsinfo(<<_:512/binary>>) ->
    unsigned.

-doc """
The writable rule's fourth condition (docs/design-drives.md, "The writable rule")
over erx_fat:info/1: the volume is not dirty, records no hard error and mirrors its
FATs, checked in that order; otherwise the reason it mounts read-only. The
ownership check, erx_fat:check/3, follows it.
""".
-spec writable(#{clean := boolean(), hard_error := boolean(), mirrored := boolean(), _ => _}) ->
          ok | {read_only, dirty | hard_error | mirror}.
writable(#{clean := false}) -> {read_only, dirty};
writable(#{hard_error := true}) -> {read_only, hard_error};
writable(#{mirrored := false}) -> {read_only, mirror};
writable(#{}) -> ok.

-doc """
The sectors a batch holds, by held/1's measure and erx_fat_dir's, before it
commits, and the FAT sectors one release step writes at most: a quarter of
media_volume_bytes at what one held sector costs the volume's memory bound.
""".
-spec batch_sectors() -> pos_integer().
batch_sectors() -> ?BATCH_SECTORS.

-doc "The heap words a sector a batch holds may cost at most, beside its image (?HELD_SECTOR_BYTES).".
-spec held_sector_words() -> pos_integer().
held_sector_words() -> ?HELD_SECTOR_WORDS.

-doc "The allocator of a volume a writable mount admitted, with no batch open.".
-spec new(layout()) -> alloc().
new(#{read := Read, type := Type, fat_start := FatStart, fats := Fats, fat_sectors := FatSectors,
      clusters := Clusters, fsinfo := FsInfo}) ->
    #alloc{read = Read, type = Type, fat_start = FatStart, fats = Fats, fat_sectors = FatSectors,
           clusters = Clusters, fsinfo = FsInfo}.

%% ---------------------------------------------------------------------------
%% Chains
%% ---------------------------------------------------------------------------

-doc """
The volume as the batch leaves it: a function that reads one of its sectors, each
sector of the first FAT with every entry the batch changes, so a reader that
follows chains through it (erx_fat:with_read/2) sees the batch's. Making it reads
nothing and costs nothing, and a read of a FAT sector looks up only that sector's
entries, so what a read costs does not grow with the batch.
""".
-spec view(alloc()) -> read_sector().
view(Alloc = #alloc{read = Read, fat_start = FatStart, fat_sectors = FatSectors}) ->
    fun(Sector) when Sector >= FatStart, Sector < FatStart + FatSectors ->
            case sector_entries(Alloc, Sector - FatStart) of
                [] -> Read(Sector);
                Entries -> guarded(fun() -> patched(Alloc, Sector - FatStart, Entries) end)
            end;
       (Sector) ->
            Read(Sector)
    end.

%% The batch's {Cluster, Value} entries that lie in FAT sector Index.
sector_entries(#alloc{batch = Batch}, _Index) when map_size(Batch) =:= 0 ->
    [];
sector_entries(#alloc{type = Type, batch = Batch}, Index) ->
    PerSector = ?SECTOR * 8 div Type,
    [{Cluster, Value} || Cluster <- lists:seq(Index * PerSector, Index * PerSector + PerSector - 1),
                         {_Kind, Value} <- [maps:get(Cluster, Batch, none)]].

-doc "The whole chain from First as the batch leaves it, first to last; the tests' oracle, as the server follows only spans (span/3).".
-spec chain(alloc(), cluster()) -> {ok, [cluster()]} | {error, finding()}.
chain(Alloc, First) ->
    guarded(fun() -> lists:reverse(whole(Alloc, First, fun(Cluster, Got) -> [Cluster | Got] end, [])) end).

-doc """
The chain from First as the batch leaves it, followed at most Need clusters: how
many it has of them, the last of those, and those from index From on (the first
cluster's is 0), first to last. Only those are kept, so what it holds grows with
Need less From, not with the chain; a Need past the volume's clusters is
no_space. It follows Need links and no further, so it refuses no loop past a
free, reserved or bad link: the volume calls it only after the ownership check
(erx_fat:check/3) found every chain a name reaches disjoint and loop-free, and a
batch links only free clusters, so it makes no loop.
""".
-spec span(alloc(), cluster(), {non_neg_integer(), pos_integer()}) ->
          {ok, {pos_integer(), cluster(), [cluster()]}} | {error, finding()}.
span(#alloc{clusters = Clusters}, _First, {_From, Need}) when Need > Clusters ->
    {error, no_space};
span(Alloc, First, {From, Need}) ->
    guarded(fun() ->
                    Take = fun(Cluster, {Index, _Last, Got}) when Index >= From -> {Index + 1, Cluster, [Cluster | Got]};
                              (Cluster, {Index, _Last, Got}) -> {Index + 1, Cluster, Got}
                           end,
                    {{Count, Last, Got}, _} = follow(Alloc, First, Need, Take, {0, none, []}),
                    {Count, Last, lists:reverse(Got)}
            end).

-doc """
Count new clusters at the end of the chain from First, or as a new chain when First
is none: the new clusters, first to last, and the allocator holding them.
""".
-spec grow(alloc(), cluster() | none, pos_integer()) -> {ok, [cluster()], alloc()} | {error, finding()}.
grow(Alloc = #alloc{batch = Batch}, First, Count) when is_integer(Count), Count >= 1 ->
    guarded(fun() ->
                    Tail = case First of none -> none; _ -> whole(Alloc, First, fun(Cluster, _) -> Cluster end, none) end,
                    Run = find(Alloc, Count),
                    Fresh = lists:foldl(fun({Cluster, Next}, Acc) -> Acc#{Cluster => {fresh, Next}} end,
                                        Batch, lists:zip(Run, tl(Run) ++ [eoc(Alloc)])),
                    Prepared = Alloc#alloc{batch = Fresh, next = after_cluster(Alloc, lists:last(Run)), allocated = true},
                    {Run, case Tail of none -> Prepared; _ -> set(Prepared, Tail, hd(Run)) end}
            end).

-doc """
The chain from First cut to its first Keep clusters, the rest waiting for its
release; Keep 0 has the whole chain wait. A chain shorter than Keep is
does_not_read. Only the kept clusters are walked.
""".
-spec shrink(alloc(), cluster(), non_neg_integer()) -> {ok, alloc()} | {error, finding()}.
shrink(Alloc = #alloc{waiting = Waiting, clusters = Clusters}, First, 0) ->
    guarded(fun() -> Alloc#alloc{waiting = Waiting ++ [{data_cluster(Alloc, First), Clusters}]} end);
shrink(Alloc = #alloc{waiting = Waiting, clusters = Clusters}, First, Keep) when is_integer(Keep), Keep >= 1 ->
    guarded(fun() ->
                    case follow(Alloc, First, Keep, fun(Cluster, {Count, _}) -> {Count + 1, Cluster} end, {0, none}) of
                        {{Keep, _Last}, done} -> Alloc;
                        {{_Shorter, _Last}, done} -> fail(does_not_read);
                        {{Keep, Last}, Rest} -> (set(Alloc, Last, eoc(Alloc)))#alloc{waiting = Waiting ++ [{Rest, Clusters}]}
                    end
            end).

-doc "The whole chain from First waiting for its release.".
-spec free(alloc(), cluster()) -> {ok, alloc()} | {error, finding()}.
free(Alloc, First) ->
    shrink(Alloc, First, 0).

%% The whole chain from First folded through Take; one of more links than the
%% volume has clusters loops.
whole(Alloc = #alloc{clusters = Clusters}, First, Take, Acc) ->
    case follow(Alloc, First, Clusters, Take, Acc) of
        {Folded, done} -> Folded;
        {_Folded, _Next} -> fail(does_not_read)
    end.

%% Take folded over at most Max clusters of the chain from First, through the batch's
%% entries and the medium: {Acc, done} when the chain ends within them, else {Acc,
%% Next} with the cluster that follows the Max-th.
follow(Alloc, First, Max, Take, Acc) ->
    follow(Alloc, data_cluster(Alloc, First), Max, Take, Acc, none).

follow(_Alloc, Cluster, 0, _Take, Acc, _Cache) ->
    {Acc, Cluster};
follow(Alloc = #alloc{batch = Batch}, Cluster, Left, Take, Acc, Cache) ->
    {Value, Read} = case Batch of
                        #{Cluster := {_Step, Entry}} -> {Entry, Cache};
                        #{} -> medium(Alloc, Cluster, Cache)
                    end,
    case end_of_chain(Alloc, Value) of
        true -> {Take(Cluster, Acc), done};
        false -> follow(Alloc, data_cluster(Alloc, Value), Left - 1, Take, Take(Cluster, Acc), Read)
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

%% Cluster's entry set to Value: a cluster the batch allocates stays fresh, whatever
%% it holds, and any other is live.
set(Alloc = #alloc{batch = Batch}, Cluster, Value) ->
    Kind = case Batch of #{Cluster := {fresh, _}} -> fresh; #{} -> live end,
    Alloc#alloc{batch = Batch#{Cluster => {Kind, Value}}}.

%% The step that writes live Cluster's entry of the overlay, from what it replaces on
%% the medium (a fresh cluster's steps are written/3's), so that a file's chain is never shorter than its size, which the caller's
%% publication step changes between linking and cutting. A live entry the medium ends a chain at only grows the chain,
%% in linking; an end-of-chain mark that replaces a link only shrinks it, in
%% cutting. A link that replaces a link, a cut cluster's link to a new run when a
%% file shrinks and grows in one batch, goes in linking when the new rest of the
%% chain is no shorter than the old one, and in cutting otherwise.
step(Alloc, Cluster, Value) ->
    Old = element(1, medium(Alloc, Cluster, none)),
    case {end_of_chain(Alloc, Old), end_of_chain(Alloc, Value)} of
        {true, _} -> linking;
        {false, true} -> cutting;
        {false, false} ->
            New = whole(Alloc, Value, fun(_, Count) -> Count + 1 end, 0),
            case ends_within(Alloc, Old, New) of true -> linking; false -> cutting end
    end.

%% Whether the medium's chain from Cluster, without the batch's entries, ends within
%% Max clusters.
ends_within(Alloc, Cluster, Max) ->
    ends_within(Alloc, data_cluster(Alloc, Cluster), Max, none).

ends_within(_Alloc, _Cluster, 0, _Cache) ->
    false;
ends_within(Alloc, Cluster, Left, Cache) ->
    {Value, Read} = medium(Alloc, Cluster, Cache),
    end_of_chain(Alloc, Value) orelse ends_within(Alloc, data_cluster(Alloc, Value), Left - 1, Read).

%% ---------------------------------------------------------------------------
%% Allocation
%% ---------------------------------------------------------------------------

%% Count free clusters, next-fit from next: the first run of Count contiguous ones,
%% the search wrapping once from the last cluster to the first, or else the first
%% Count met. A cluster the batch names is not free.
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

%% The next-free hint: the cluster next-fit would allocate first, which is free once
%% the batch is written, since the search counts no cluster the batch names as free;
%% or unknown when none is.
next_free(Alloc) ->
    try find(Alloc, 1) of
        [Cluster] -> Cluster
    catch
        throw:{?MODULE, no_space} -> ?UNKNOWN
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
The batch's share of what the volume holds, in sectors, at most: each FAT sector
once for preparation when it holds a fresh entry, once more for linking when
one of those links into another FAT sector, once each for linking and cutting
when it holds a live one, and one for each waiting chain. It reads
nothing. It is non-zero after a commit exactly when a chain still waits, and the
caller commits again at once.
""".
-spec held(alloc()) -> non_neg_integer().
held(Alloc = #alloc{batch = Batch, waiting = Waiting}) ->
    Writes = lists:usort([{Step, entry_sector(Alloc, Cluster)} || Cluster := Entry <- Batch,
                                                                 Step <- held_steps(Alloc, Cluster, Entry)]),
    length(Writes) + length(Waiting).

held_steps(Alloc, Cluster, {fresh, Value}) ->
    case crosses(Alloc, Cluster, Value) of true -> [preparation, linking]; false -> [preparation] end;
held_steps(_Alloc, _Cluster, {live, _Value}) ->
    [linking, cutting].

-doc """
The batch's plan, its preparation, linking, cutting and release steps each with the
FAT sectors it writes, steps without a write left out; and the allocator with no
batch open, holding the chains the release did not finish.
""".
-spec commit(alloc()) -> {ok, plan(), alloc()} | {error, finding()}.
commit(Alloc) ->
    guarded(fun() ->
                    {Plan, Waiting} = batch_plan(Alloc),
                    {Plan, Alloc#alloc{batch = #{}, waiting = Waiting}}
            end).

-doc """
The plan that marks the volume in use before its first change: the second entry's
clean bit cleared in the FAT the server reads, then in the other copies with
FAT32's FSInfo hints unknown.
""".
-spec dirty(alloc()) -> {ok, plan()} | {error, finding()}.
dirty(Alloc) ->
    guarded(fun() ->
                    {Clean, _} = flag_bits(Alloc#alloc.type),
                    {Read, Mirrors} = flag_writes(Alloc, fun(Entry) -> Entry band bnot Clean end, []),
                    written_steps([{dirty, Read}, {dirty_mirrors, Mirrors ++ fsinfo_writes(Alloc, ?UNKNOWN)}])
            end).

-doc """
One of the volume's last batches: commit/1's plan and the allocator, while a chain
still waits after it, for the caller to finish again; or, once none waits, that
plan with the next-free hint in its release step, when the mount allocated, then
the clean bit set in the other copies and last in the FAT the server reads, and
`finished`.
""".
-spec finish(alloc()) -> {ok, plan(), alloc() | finished} | {error, finding()}.
finish(Alloc) -> finish(Alloc, clean).

-doc """
finish/1, with the second entry written as Entry says: `clean`, the clean bit set
and the hard-error bit kept as the medium holds it, as the FAT server writes it;
or `correct`, the entry written whole as FreeBSD's "Correct" writes it, every bit
set, which a repair writes (docs/design-fsck-fat.md, "The repair order").
""".
-spec finish(alloc(), clean | correct) -> {ok, plan(), alloc() | finished} | {error, finding()}.
finish(Alloc = #alloc{allocated = Allocated}, Entry) ->
    guarded(fun() ->
                    case batch_plan(Alloc) of
                        {Plan, [_ | _] = Waiting} ->
                            {Plan, Alloc#alloc{batch = #{}, waiting = Waiting}};
                        {Plan, []} ->
                            Hint = case {Allocated, Alloc#alloc.fsinfo} of
                                       {true, Sector} when Sector =/= none -> fsinfo_writes(Alloc, keep, next_free(Alloc));
                                       _ -> []
                                   end,
                            Last = case Hint of
                                       [] -> Plan;
                                       _ -> lists:keystore(release, 1, Plan,
                                                           {release, proplists:get_value(release, Plan, []) ++ Hint})
                                   end,
                            {Clean, _} = flag_bits(Alloc#alloc.type),
                            {Read, Mirrors} = flag_writes(Alloc, entry1(Entry, Clean, Alloc#alloc.type), Last),
                            {Last ++ written_steps([{clean_mirrors, Mirrors}, {clean, Read}]), finished}
                    end
            end).

%% The overlay's steps, each FAT sector built from the medium's with the entries of
%% that step and of every step before it, then the release; with the chains still
%% waiting after it.
batch_plan(Alloc) ->
    BySector = lists:sort(maps:to_list(by_sector(Alloc))),
    Steps = [{Step, copies(Alloc, [{Index, patched(Alloc, Index, upto(Step, Entries))}
                                   || {Index, Entries} <- BySector, lists:keymember(Step, 1, Entries)])}
             || Step <- ?STEPS],
    {Released, Waiting} = release(Alloc, maps:from_list(BySector), Alloc#alloc.waiting, #{}),
    {[{Step, Writes} || {Step, Writes} <- Steps ++ [{release, copies(Alloc, Released)}], Writes =/= []], Waiting}.

%% Entries' {Cluster, Value} of Step and of the steps before it.
%% A cluster written in two steps takes the later step's value.
upto(Step, Entries) ->
    {Before, _} = lists:splitwith(fun(Other) -> Other =/= Step end, ?STEPS),
    maps:to_list(maps:from_list([{Cluster, Value} || Other <- Before ++ [Step], {Written, Cluster, Value} <- Entries,
                                                    Written =:= Other])).

%% The batch's entries by the FAT sector each lies in, as {Step, Cluster, Value}.
by_sector(Alloc = #alloc{batch = Batch}) ->
    maps:groups_from_list(fun({_Step, Cluster, _Value}) -> entry_sector(Alloc, Cluster) end,
                          lists:append([written(Alloc, Cluster, Entry) || Cluster := Entry <- Batch])).

%% Cluster's entry of the overlay as the steps write it, {Step, Cluster, Value}: a
%% fresh entry that links into another FAT sector is an end-of-chain mark in
%% preparation and its link in linking, so that preparation's sectors, landed in
%% any order or in part, hold only new chains that end within their own sector, and
%% a cut leaves lost clusters at worst.
written(Alloc, Cluster, {fresh, Value}) ->
    case crosses(Alloc, Cluster, Value) of
        true -> [{preparation, Cluster, eoc(Alloc)}, {linking, Cluster, Value}];
        false -> [{preparation, Cluster, Value}]
    end;
written(Alloc, Cluster, {live, Value}) ->
    [{step(Alloc, Cluster, Value), Cluster, Value}].

%% Whether Value, Cluster's entry, links to a cluster whose entry lies in another
%% FAT sector.
crosses(Alloc, Cluster, Value) ->
    not end_of_chain(Alloc, Value)
        andalso entry_sector(Alloc, data_cluster(Alloc, Value)) =/= entry_sector(Alloc, Cluster).

%% The waiting chains freed in order, each from its first cluster on, each entry read
%% from its sector as the overlay's steps leave it, for as long as the release's FAT
%% sectors stay within ?BATCH_SECTORS: the release's sectors, sorted, and the chains
%% still waiting, the first from the cluster the release reached with what is left of
%% its budget; a chain past its budget loops. A cluster is freed
%% before its link is followed, so a link back to one reads it free.
release(_Alloc, _BySector, [], Sectors) ->
    {lists:sort(maps:to_list(Sectors)), []};
release(_Alloc, _BySector, [{_Cluster, 0} | _Rest], _Sectors) ->
    fail(does_not_read);
release(Alloc, BySector, [{Cluster, Left} | Rest] = Waiting, Sectors) ->
    Index = entry_sector(Alloc, Cluster),
    case Sectors of
        #{Index := Sector} ->
            Freed = Sectors#{Index := put_entry(Alloc, Cluster, ?FREE, Sector)},
            Value = entry_value(Alloc, Cluster, Sector),
            case end_of_chain(Alloc, Value) of
                true -> release(Alloc, BySector, Rest, Freed);
                false -> release(Alloc, BySector, [{data_cluster(Alloc, Value), Left - 1} | Rest], Freed)
            end;
        #{} when map_size(Sectors) >= ?BATCH_SECTORS ->
            {lists:sort(maps:to_list(Sectors)), Waiting};
        #{} ->
            Overlay = upto(lists:last(?STEPS), maps:get(Index, BySector, [])),
            release(Alloc, BySector, Waiting, Sectors#{Index => patched(Alloc, Index, Overlay)})
    end.

%% FAT sector Index of the first FAT with Entries, each of which lies in it, written,
%% a later entry of a cluster over an earlier one. The sector is built once, whatever
%% the count of entries: a view reads a FAT sector at every link a walk follows, and
%% one rebuilt for each entry would leave garbage in proportion to the entries.
patched(Alloc = #alloc{type = Type}, Index, Entries) ->
    Sector = fat_sector(Alloc, Index),
    Values = maps:from_list([{entry_offset(Alloc, Cluster), Value} || {Cluster, Value} <- Entries]),
    {End, Parts} = maps:fold(fun(Offset, Value, {At, Acc}) ->
                                     <<_:Offset/binary, Old:Type/little, _/binary>> = Sector,
                                     {Offset + Type div 8,
                                      [Acc, binary:part(Sector, At, Offset - At), <<(encode(Type, Old, Value)):Type/little>>]}
                             end, {0, []}, maps:iterator(Values, ordered)),
    iolist_to_binary([Parts, binary:part(Sector, End, ?SECTOR - End)]).

%% Sector, the one holding Cluster's entry, with that entry set to Value.
put_entry(Alloc = #alloc{type = Type}, Cluster, Value, Sector) ->
    Offset = entry_offset(Alloc, Cluster),
    <<Before:Offset/binary, Old:Type/little, After/binary>> = Sector,
    <<Before/binary, (encode(Type, Old, Value)):Type/little, After/binary>>.

%% An entry's bytes: FAT32 keeps the top four bits the entry held.
encode(16, _Old, Value) -> Value;
encode(32, Old, Value) -> (Old band ?RESERVED_32) bor (Value band ?VALUE_32).

%% Sectors of the first FAT, each written to every FAT, the first first.
copies(#alloc{fat_start = FatStart, fats = Fats, fat_sectors = FatSectors}, Sectors) ->
    [{FatStart + Copy * FatSectors + Index, Bytes} || Copy <- lists:seq(0, Fats - 1), {Index, Bytes} <- Sectors].

%% Steps without a write left out.
written_steps(Steps) -> [Step || {_Name, [_ | _]} = Step <- Steps].

%% The second entry, rewritten by Change, in every FAT, its sector as Plan last wrote
%% it, or as the medium holds it: {the FAT the server reads, the other copies}.
flag_writes(Alloc = #alloc{type = Type, fat_start = FatStart}, Change, Plan) ->
    Sector = case [Bytes || {_Step, Writes} <- Plan, {Index, Bytes} <- Writes, Index =:= FatStart] of
                 [] -> fat_sector(Alloc, 0);
                 Written -> lists:last(Written)
             end,
    Offset = Type div 8,
    <<First:Offset/binary, Entry:Type/little, After/binary>> = Sector,
    [Read | Mirrors] = copies(Alloc, [{0, <<First/binary, (Change(Entry)):Type/little, After/binary>>}]),
    {[Read], Mirrors}.

entry1(clean, Clean, _Type) -> fun(Old) -> Old bor Clean end;
entry1(correct, _Clean, 16) -> fun(_Old) -> ?EOC_16 end;
entry1(correct, _Clean, 32) -> fun(_Old) -> ?EOC_32 end.

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
        {Result, finished} -> {ok, Result, finished};
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

-doc """
Where Cluster's entry lies in a FAT of Type-bit entries: the sector that holds it, as
an index into the FAT, and its byte offset in that sector.
""".
-spec entry_place(16 | 32, non_neg_integer()) -> {non_neg_integer(), non_neg_integer()}.
entry_place(Type, Cluster) ->
    Offset = Cluster * (Type div 8),
    {Offset div ?SECTOR, Offset rem ?SECTOR}.

entry_sector(#alloc{type = Type}, Cluster) -> element(1, entry_place(Type, Cluster)).

entry_offset(#alloc{type = Type}, Cluster) -> element(2, entry_place(Type, Cluster)).

%% Sector Index of the first FAT, as the medium holds it.
fat_sector(Alloc = #alloc{fat_start = FatStart}, Index) -> sector(Alloc, FatStart + Index).

%% Cluster's entry in Sector, the FAT sector that holds it, in its value bits.
entry_value(Alloc = #alloc{type = Type}, Cluster, Sector) ->
    Offset = entry_offset(Alloc, Cluster),
    <<_:Offset/binary, Entry:Type/little, _/binary>> = Sector,
    case Type of 16 -> Entry; 32 -> Entry band ?VALUE_32 end.

%% Cluster's entry as the medium holds it, read through Cache, the last FAT sector
%% read as {Index, Bytes} or none; with the sector read.
medium(Alloc, Cluster, Cache) ->
    Index = entry_sector(Alloc, Cluster),
    Bytes = case Cache of {Index, Cached} -> Cached; _ -> fat_sector(Alloc, Index) end,
    {entry_value(Alloc, Cluster, Bytes), {Index, Bytes}}.
