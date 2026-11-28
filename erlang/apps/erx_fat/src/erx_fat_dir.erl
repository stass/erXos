%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_dir).
-moduledoc """
The FAT server's directory changes (docs/design-storage.md, "Removable media: FAT"):
creating, removing and renaming names of one FAT16 or FAT32 volume as a pure core
over the volume's sector reader and its allocator, erx_fat_alloc. A batch gathers
changes and commit/1 answers its write plan, `[{Step, [{Sector, Bytes}]}]`, which
the caller writes in order with a flush after each step. It starts on a volume
whose ownership check (erx_fat:check/3) passed.

* **Steps.** A directory sector is kept as one image for each step that changes
  it, and a change at a step goes into that step's image and every later one, so
  the sector a step writes holds the changes of that step and of the steps before
  it, and the batch's last change to an entry wins from its step on: a name
  created and removed in one batch leaves its entries deleted. `preparation`
  removes names (a removed name's entries, a renamed name's old ones, the name a
  rename replaces), zeroes every cluster that grows a directory, writes a new
  directory's first cluster with its `.` and `..` entries, and writes an end marker
  after a name placed past the old one; `linking` rewrites the `..` of a directory
  moved to another parent; `publication` writes every new name's entries. The
  allocator writes its FAT entries in its own steps, so a new directory's cluster
  and a directory's new run are allocated in preparation and the run linked in
  linking. Only the sectors a batch changes have images.
* **The view.** view/1 is the volume as the batch leaves it, every image and every
  FAT entry of the batch read through, so each change sees the ones before it.
* **One fold a directory.** A change reads a directory through erx_fat:fold/4, a
  sector at a time, and keeps only what it looks for: the name it names, and for a
  name it places the short names that claim its short name's candidates (one bit a
  numeric tail, in an atomics array local to the call) and the first free run of
  each length the name may take. What it holds does not grow with the directory.
  The node a placed name answers is made from where that scan put it and the short
  entry written there (erx_fat:entry_node/4), so a create or a mkdir reads its
  directory once; a scan's cost still grows with the directory, as nothing indexes
  its names.
* **Placement.** A name takes the first run of free entries, deleted or past the
  end marker, long enough for its long-name entries and its short entry; failing
  that the directory grows by as many zeroed clusters as the entries need beyond
  the free ones that end it, as FreeBSD's msdosfs counts them (`createde`,
  sys/fs/msdosfs/msdosfs_lookup.c:655-660 at release/14.3.0), within 65,536
  entries. A name stored as its short entry alone never follows a live long-name
  entry, which would read as its long name: where its run would, it is stored
  with long-name entries too, whose last part ends any such run. FAT16's root does
  not grow, and a name that finds no run in it is `enospc`. A directory is never
  compacted.
* **A file's contents.** write/5 writes a file's bytes in preparation, in the
  clusters it keeps and in a run the allocator grows its chain by, zeroes first
  from its old size when the write starts past it, so every byte within a size is
  one written to the file; truncate/4 cuts its chain through the allocator, the
  cut clusters waiting for their release, or grows it as a write of nothing at the
  new size does; setattr/3 changes its time and read-only attribute. Each
  publishes the file's entry, its first cluster, size, time and attributes, in
  publication. A write or cut past the end of a chain shorter than its file's size
  is `does_not_read`, and one past 4 GiB less one byte `efbig`.
* **Removal.** remove/3 and rmdir/3 take the name away and answer its node; its
  chain is the caller's to free with free/2 once no fid names it. Until then
  write_removed/4, truncate_removed/3 and setattr_removed/3 change a removed file
  as write/5, truncate/4 and setattr/3 do, from the node the caller keeps, and
  publish no entry.
* **Renaming** onto an existing name removes it, a directory onto a file is
  `enotdir`, a file onto a directory `eisdir`, a directory onto one that holds
  entries `enotempty`, and a directory into its own subtree `einval`, found by
  walking the new parent's `..` entries to the root, at most as many steps as the
  volume has clusters.

Names follow erx_fat_name: `einval` and `enametoolong` for a name the server does
not create, `eexist` for one that compares equal to a name the directory holds,
`enoent` for a name it does not hold, and `enotdir` for a change in a file. A
volume read that breaks is erx_fat's finding. Each refusal leaves through one
throw, `{erx_fat_dir, Error}`, caught at each exported entry, and leaves the batch
as it was.
""".

-export([new/1, view/1, create/4, mkdir/4, remove/3, rmdir/3, rename/5, free/2, held/1, full/1, commit/1, finish/1]).
-export([write/5, write_removed/4, truncate/4, truncate_removed/3, setattr/3, setattr_removed/3,
         refreshed/2]).
-export_type([batch/0, error/0]).

-include("erx_fat_entry.hrl").

-define(SECTOR, 512).
-define(ENTRIES_PER_SECTOR, (?SECTOR div ?ENTRY)).
%% The steps that write directory sectors, in the batch's order.
-define(STEPS, [preparation, linking, publication]).
%% The largest file FAT holds: 4 GiB less one byte.
-define(FILE_MAX, 16#ffffffff).
%% The whole plan's steps, the allocator's among them.
-define(PLAN_STEPS, [preparation, linking, publication, cutting, release]).
%% The numeric tails a placement records: the least free one is at most one past a
%% directory's entries.
-define(TAILS_RECORDED, (?DIR_ENTRIES_MAX + 1)).

-type step() :: preparation | linking | publication.
-type error() :: einval | enametoolong | eexist | enoent | enospc | enotempty | enotdir | eisdir | efbig
               | erx_fat:finding() | erx_fat_alloc:finding().
%% An entry's place on the medium: its sector and its byte offset in it.
-type slot() :: {non_neg_integer(), non_neg_integer()}.

%% fat is the volume as mounted and alloc its allocator; images maps each directory
%% or data sector the batch changes to its image at each step that changes it.
-record(batch, {fat :: erx_fat:fat(),
                alloc :: erx_fat_alloc:alloc(),
                images = #{} :: #{non_neg_integer() => #{step() => binary()}}}).

-opaque batch() :: #batch{}.

%% A free run being sought: none, one open from Start, or the one found from Start;
%% AfterLong says whether the entry before Start is a live long-name entry.
-type run() :: none | {open | found, non_neg_integer(), boolean()}.

%% One fold over a directory for a name being placed: the search for a name that
%% compares equal to it, its short name's basis, whether a short entry holds the
%% basis itself and which numeric tails short entries hold, whether the last entry
%% read is a live long-name entry, and the first free run for each count of entries
%% the name may take. The tails array is mutable: a scan is folded once and dropped.
-record(scan, {match :: erx_fat_name:match(),
               basis :: erx_fat_name:basis(),
               basis_taken = false :: boolean(),
               tails :: atomics:atomics_ref(),
               after_long = false :: boolean(),
               runs :: [{pos_integer(), run()}]}).

%% ---------------------------------------------------------------------------
%% The batch
%% ---------------------------------------------------------------------------

-doc "An empty batch over mounted volume Fat, whose allocator it makes.".
-spec new(erx_fat:fat()) -> batch().
new(Fat) ->
    #batch{fat = Fat, alloc = erx_fat_alloc:new(erx_fat:layout(Fat))}.

-doc "The volume as the batch leaves it, for erx_fat's reads.".
-spec view(batch()) -> erx_fat:fat().
view(#batch{fat = Fat, alloc = Alloc, images = Images}) ->
    Under = erx_fat_alloc:view(Alloc),
    erx_fat:with_read(Fat, fun(Sector) ->
                                   case Images of
                                       #{Sector := Steps} -> {ok, latest(Steps)};
                                       #{} -> Under(Sector)
                                   end
                           end).

-doc """
The batch's share of what the volume holds: each directory sector once for every
step that writes it, with the allocator's measure (erx_fat_alloc:held/1).
""".
-spec held(batch()) -> non_neg_integer().
held(#batch{alloc = Alloc, images = Images}) ->
    lists:sum([map_size(Steps) || _Sector := Steps <- Images]) + erx_fat_alloc:held(Alloc).

-doc """
Whether the batch holds more sectors than its bound (erx_fat_alloc:batch_sectors/0),
so that its holder commits it before taking another change.
""".
-spec full(batch()) -> boolean().
full(B) -> held(B) > erx_fat_alloc:batch_sectors().

-doc """
The batch's plan, directory sectors and FAT sectors in the steps of the module's
doc, steps without a write left out; and the batch emptied, holding the chains the
allocator's release did not finish.
""".
-spec commit(batch()) -> {ok, erx_fat_alloc:plan(), batch()} | {error, error()}.
commit(B = #batch{alloc = Alloc}) ->
    guarded(fun() ->
                    {Plan, Alloc1} = ok(erx_fat_alloc:commit(Alloc)),
                    {merged(B, Plan), B#batch{alloc = Alloc1, images = #{}}}
            end).

-doc """
One of the volume's last batches: the batch's plan with erx_fat_alloc:finish/1's,
and the emptied batch while a chain still waits, else `finished` once the clean bit
is set.
""".
-spec finish(batch()) -> {ok, erx_fat_alloc:plan(), batch() | finished} | {error, error()}.
finish(B = #batch{alloc = Alloc}) ->
    guarded(fun() ->
                    case ok(erx_fat_alloc:finish(Alloc)) of
                        {Plan, finished} -> {merged(B, Plan), finished};
                        {Plan, Alloc1} -> {merged(B, Plan), B#batch{alloc = Alloc1, images = #{}}}
                    end
            end).

%% The allocator's Plan with the batch's directory sectors in their steps, the
%% allocator's own steps past the batch's, the clean bit's, after them in its order.
merged(#batch{images = Images}, Plan) ->
    Dir = [{Step, lists:sort([{Sector, Bytes} || Sector := #{Step := Bytes} <- Images])} || Step <- ?STEPS],
    Flags = [Step || {Step, _} <- Plan, not lists:member(Step, ?PLAN_STEPS)],
    [{Step, Writes} || Step <- ?PLAN_STEPS ++ Flags,
                       Writes <- [proplists:get_value(Step, Dir, []) ++ proplists:get_value(Step, Plan, [])],
                       Writes =/= []].

-doc "Chain First, of a removed name no fid names any more, freed in a coming release.".
-spec free(batch(), pos_integer()) -> {ok, batch()} | {error, error()}.
free(B = #batch{alloc = Alloc}, First) ->
    guarded(fun() -> B#batch{alloc = ok(erx_fat_alloc:free(Alloc, First))} end).

%% ---------------------------------------------------------------------------
%% Changes
%% ---------------------------------------------------------------------------

-doc "An empty file Name in directory Dir, modified at Time (UNIX seconds): its node.".
-spec create(batch(), erx_fat:fat_node(), binary(), integer()) -> {ok, erx_fat:fat_node(), batch()} | {error, error()}.
create(B, Dir, Name, Time) ->
    guarded(fun() ->
                    Units = checked(Name),
                    place(B, Dir, Name, Units, fun(Short, Flags, B1) -> {erx_fat_entry:new(Short, Flags, file, 0, Time), B1} end)
            end).

-doc "An empty directory Name in directory Dir, modified at Time: its node.".
-spec mkdir(batch(), erx_fat:fat_node(), binary(), integer()) -> {ok, erx_fat:fat_node(), batch()} | {error, error()}.
mkdir(B, Dir, Name, Time) ->
    guarded(fun() ->
                    Units = checked(Name),
                    %% Its cluster is allocated once the placing scan has refused a name
                    %% the directory holds, so a full volume answers eexist.
                    place(B, Dir, Name, Units, new_dir(Dir, Time))
            end).

%% place/5's Entry for a new directory of Dir modified at Time: its cluster
%% allocated and written with its `.` and `..` entries, and its short entry.
new_dir(Dir, Time) ->
    fun(Short, Flags, B = #batch{alloc = Alloc}) ->
            {[Cluster], Alloc1} = ok(erx_fat_alloc:grow(Alloc, none, 1)),
            Dots = <<(erx_fat_entry:encode(erx_fat_entry:new(?DOT, 0, dir, Cluster, Time)))/binary,
                     (erx_fat_entry:encode(erx_fat_entry:new(?DOTDOT, 0, dir, number(Dir), Time)))/binary>>,
            {erx_fat_entry:new(Short, Flags, dir, Cluster, Time), zeroed(B#batch{alloc = Alloc1}, Cluster, Dots)}
    end.

-doc "File Name of directory Dir taken away: its node, whose chain the caller frees.".
-spec remove(batch(), erx_fat:fat_node(), binary()) -> {ok, erx_fat:fat_node(), batch()} | {error, error()}.
remove(B, Dir, Name) ->
    guarded(fun() ->
                    {Node, Slots} = found(B, Dir, Name),
                    kind(Node) =:= file orelse fail(eisdir),
                    {Node, unnamed(B, Slots)}
            end).

-doc "Empty directory Name of directory Dir taken away: its node, whose chain the caller frees.".
-spec rmdir(batch(), erx_fat:fat_node(), binary()) -> {ok, erx_fat:fat_node(), batch()} | {error, error()}.
rmdir(B, Dir, Name) ->
    guarded(fun() ->
                    {Node, Slots} = found(B, Dir, Name),
                    kind(Node) =:= dir orelse fail(enotdir),
                    empty(B, Node) orelse fail(enotempty),
                    {Node, unnamed(B, Slots)}
            end).

-doc """
Name From of directory FromDir renamed to To in directory ToDir: the renamed node
and the node of the name it replaced, or none; the replaced node's chain is the
caller's to free.
""".
-spec rename(batch(), erx_fat:fat_node(), binary(), erx_fat:fat_node(), binary()) ->
          {ok, {erx_fat:fat_node(), erx_fat:fat_node() | none}, batch()} | {error, error()}.
rename(B, FromDir, From, ToDir, To) ->
    guarded(fun() ->
                    {Node, Slots} = found(B, FromDir, From),
                    Units = checked(To),
                    kind(Node) =:= dir andalso moves(FromDir, ToDir) andalso not outside(B, Node, ToDir)
                        andalso fail(einval),
                    %% To may name the renamed entry itself, by its bytes or in another case.
                    case lookup(B, ToDir, To) of
                        {_Itself, Slots} when From =:= To ->
                            {{Node, none}, B};
                        {_Itself, Slots} ->
                            moved(B, Node, FromDir, Slots, ToDir, To, Units, none);
                        {Target, TargetSlots} ->
                            replaceable(B, Node, Target),
                            moved(unnamed(B, TargetSlots), Node, FromDir, Slots, ToDir, To, Units, Target);
                        none ->
                            moved(B, Node, FromDir, Slots, ToDir, To, Units, none)
                    end
            end).

-doc """
Count bytes Bytes of file File written from Offset at Time: the file as the batch
then leaves it. A write past the file's size zeroes from the size to Offset first.
""".
-spec write(batch(), erx_fat:fat_node(), non_neg_integer(), binary(), integer()) ->
          {ok, erx_fat:fat_node(), batch()} | {error, error()}.
write(B, File, Offset, Bytes, Time) ->
    guarded(fun() -> written(B, fresh(B, File), Offset, Bytes, entry_publisher(Time)) end).

-doc """
Bytes written to File, a removed file whose node the caller keeps, from Offset as
write/5 writes them, but with no entry published: the file as it then reads, its
first cluster and size changed.
""".
-spec write_removed(batch(), erx_fat:fat_node(), non_neg_integer(), binary()) ->
          {ok, erx_fat:fat_node(), batch()} | {error, error()}.
write_removed(B, File, Offset, Bytes) ->
    guarded(fun() -> written(B, removed_file(File), Offset, Bytes, fun unpublished/4) end).

-doc """
File File cut or grown to Size bytes at Time: the file as the batch then leaves it.
What a cut takes off waits for its release; a growth reads as zeroes.
""".
-spec truncate(batch(), erx_fat:fat_node(), non_neg_integer(), integer()) ->
          {ok, erx_fat:fat_node(), batch()} | {error, error()}.
truncate(B, File, Size, Time) ->
    guarded(fun() -> resized(B, fresh(B, File), Size, entry_publisher(Time)) end).

-doc "Removed file File cut or grown to Size bytes as truncate/4 does, with no entry published.".
-spec truncate_removed(batch(), erx_fat:fat_node(), non_neg_integer()) ->
          {ok, erx_fat:fat_node(), batch()} | {error, error()}.
truncate_removed(B, File, Size) ->
    guarded(fun() -> resized(B, removed_file(File), Size, fun unpublished/4) end).

%% Bytes written to File from Offset, zeroes first from its size when Offset is past
%% it, and the file's new first cluster and size given to Publish.
written(B, File, Offset, Bytes, Publish) ->
    #{size := Size} = erx_fat:attr(File),
    End = Offset + byte_size(Bytes),
    End =< ?FILE_MAX orelse fail(efbig),
    Start = min(Offset, Size),
    contents(B, File, Start, <<0:((Offset - Start) * 8), Bytes/binary>>, max(Size, End), Publish).

%% File cut or grown to Size, its new first cluster and size given to Publish.
resized(B = #batch{alloc = Alloc}, File, Size, Publish) ->
    #{size := Old} = erx_fat:attr(File),
    Size =< ?FILE_MAX orelse fail(efbig),
    case {Size >= Old, erx_fat:first(File)} of
        {true, _} ->
            contents(B, File, Old, <<0:((Size - Old) * 8)>>, Size, Publish);
        {false, 0} ->
            Publish(B, File, 0, Size);
        {false, First} ->
            Keep = (Size + cluster_bytes(B) - 1) div cluster_bytes(B),
            Alloc1 = ok(erx_fat_alloc:shrink(Alloc, First, Keep)),
            Publish(B#batch{alloc = Alloc1}, File, case Keep of 0 -> 0; _ -> First end, Size)
    end.

%% A named file's new first cluster and size published in its entry, with Time.
entry_publisher(Time) -> fun(B, File, First, Size) -> published(B, File, First, Size, Time) end.

%% A removed file's new first cluster and size, kept in its node alone.
unpublished(B, File, First, Size) -> {erx_fat:with_contents(File, First, Size), B}.

removed_file(File) ->
    kind(File) =:= file orelse fail(eisdir),
    File.

-doc """
File File's attributes changed: `mtime` (UNIX seconds) and `read_only`, each when
Changes holds it; the file as the batch then leaves it.
""".
-spec setattr(batch(), erx_fat:fat_node(), #{mtime => integer(), read_only => boolean()}) ->
          {ok, erx_fat:fat_node(), batch()} | {error, error()}.
setattr(B, File, Changes) ->
    guarded(fun() ->
                    Fresh = fresh(B, File),
                    entry_changed(B, Fresh, fun(Short) ->
                                                    S1 = case Changes of #{mtime := T} -> erx_fat_entry:with_mtime(Short, T); #{} -> Short end,
                                                    case Changes of #{read_only := R} -> erx_fat_entry:with_read_only(S1, R); #{} -> S1 end
                                            end)
            end).

-doc """
Removed file File's attributes changed as setattr/3 changes a named file's, kept in
its node alone, as FreeBSD's msdosfs keeps an unlinked file's in its denode and
writes no entry for it (`sys/fs/msdosfs/msdosfs_denode.c:334-335` at
`release/14.3.0`).
""".
-spec setattr_removed(batch(), erx_fat:fat_node(), #{mtime => integer(), read_only => boolean()}) ->
          {ok, erx_fat:fat_node(), batch()} | {error, error()}.
setattr_removed(B, File, Changes) ->
    guarded(fun() ->
                    #{mtime := Mtime, read_only := ReadOnly} = erx_fat:attr(removed_file(File)),
                    Held = case Changes of #{mtime := T} -> erx_fat_entry:held_mtime(T); #{} -> Mtime end,
                    {erx_fat:with_attributes(File, Held, maps:get(read_only, Changes, ReadOnly)), B}
            end).

-doc "File File as the batch leaves it (erx_fat:refreshed/2).".
-spec refreshed(batch(), erx_fat:fat_node()) -> {ok, erx_fat:fat_node()} | {error, error()}.
refreshed(B, File) ->
    try {ok, fresh(B, File)} catch throw:{?MODULE, Error} -> {error, Error} end.

fresh(B, File) ->
    kind(File) =:= file orelse fail(eisdir),
    ok(erx_fat:refreshed(File, view(B))).

cluster_bytes(#batch{fat = Fat}) -> maps:get(cluster_bytes, erx_fat:info(Fat)).

%% Data, the file's bytes from Start, written in preparation in the file's chain,
%% grown first to hold them, and its first cluster and size Size given to Publish.
%% Start is never past the file's size, since both callers start at most there
%% (written/5 at the lesser of the offset and the size, resized/4 at the old size,
%% each with zeroes up to the bytes asked for). So when the chain grows, the cluster
%% Start lies in is the chain's own (From =< Have, as Start =< Old =< Have clusters),
%% Span ++ Run runs on from it, and every grown cluster is written from its first byte.
contents(B, File, _Start, <<>>, Size, Publish) ->
    Publish(B, File, erx_fat:first(File), Size);
contents(B = #batch{alloc = Alloc}, File, Start, Data, Size, Publish) ->
    #{size := Old} = erx_fat:attr(File),
    PerCluster = cluster_bytes(B),
    From = Start div PerCluster,
    Need = (Start + byte_size(Data) + PerCluster - 1) div PerCluster,
    %% The chain is followed only as far as the data needs, and only the clusters
    %% the data lands in are kept, so a write holds no file's whole chain.
    {Have, Last, Span} = case erx_fat:first(File) of
                             0 -> {0, none, []};
                             First -> ok(erx_fat_alloc:span(Alloc, First, {From, Need}))
                         end,
    {Run, B1} = case Need - Have of
                    More when More > 0 ->
                        %% A chain shorter than its size has no clusters of its own past its end.
                        Have * PerCluster >= Old orelse fail(does_not_read),
                        {Grown, Alloc1} = ok(erx_fat_alloc:grow(Alloc, Last, More)),
                        {Grown, B#batch{alloc = Alloc1}};
                    _ ->
                        {[], B}
                end,
    B2 = data_written(B1, Span ++ Run, Start rem PerCluster, Data),
    Publish(B2, File, case Have of 0 -> hd(Run); _ -> erx_fat:first(File) end, Size).

%% Data written from byte Offset of the first of Clusters on, a sector at a time:
%% a whole sector as it is, a part patched into the sector as the batch leaves it.
data_written(B, _Clusters, _Offset, <<>>) ->
    B;
data_written(B, [Cluster | Rest], Offset, Data) ->
    Sectors = ok(erx_fat:cluster_sectors(view(B), Cluster)),
    Room = length(Sectors) * ?SECTOR - Offset,
    Here = min(Room, byte_size(Data)),
    <<Mine:Here/binary, Later/binary>> = Data,
    data_written(sectors_written(B, lists:nthtail(Offset div ?SECTOR, Sectors), Offset rem ?SECTOR, Mine),
                 Rest, 0, Later).

sectors_written(B, _Sectors, _Offset, <<>>) ->
    B;
sectors_written(B, [Sector | Rest], Offset, Data) ->
    Here = min(?SECTOR - Offset, byte_size(Data)),
    <<Mine:Here/binary, Later/binary>> = Data,
    sectors_written(set_entry(B, preparation, {Sector, Offset}, Mine), Rest, 0, Later).

%% File's entry published with first cluster First, size Size and time Time.
published(B, File, First, Size, Time) ->
    entry_changed(B, File, fun(Short) ->
                                   erx_fat_entry:with_mtime(erx_fat_entry:with_size(erx_fat_entry:with_first(Short, First), Size), Time)
                           end).

%% File's short entry changed by Change in publication: the file as it then reads.
entry_changed(B, File, Change) ->
    Slot = ok(erx_fat:entry_slot(File, view(B))),
    {short, Short} = erx_fat_entry:decode(entry_at(B, Slot)),
    B1 = set_entry(B, publication, Slot, erx_fat_entry:encode(Change(Short))),
    {fresh(B1, File), B1}.

%% Node's entries, at Slots of FromDir, taken away and published again as To in
%% ToDir, its short entry's fields kept; its `..` named again in linking when a
%% directory changes parent.
moved(B, Node, FromDir, Slots, ToDir, To, Units, Replaced) ->
    {short, Old} = erx_fat_entry:decode(entry_at(B, lists:last(Slots))),
    B1 = unnamed(B, Slots),
    B2 = case kind(Node) =:= dir andalso moves(FromDir, ToDir) of
             true -> parent_named(B1, erx_fat:first(Node), number(ToDir));
             false -> B1
         end,
    {Moved, B3} = place(B2, ToDir, To, Units, fun(Short, Flags, Ready) -> {Old#{name := Short, flags := Flags}, Ready} end),
    {{Moved, Replaced}, B3}.

moves(FromDir, ToDir) -> erx_fat:key(FromDir) =/= erx_fat:key(ToDir).

%% Target, the name a rename replaces, may be replaced by Node.
replaceable(B, Node, Target) ->
    case {kind(Node), kind(Target)} of
        {dir, file} -> fail(enotdir);
        {file, dir} -> fail(eisdir);
        {dir, dir} -> empty(B, Target) orelse fail(enotempty);
        {file, file} -> true
    end.

%% Whether directory ToDir lies outside the subtree of directory Node: its `..`
%% entries walked to the root, at most as many steps as the volume has clusters.
outside(B, Node, ToDir) ->
    #{clusters := Clusters} = erx_fat:info(B#batch.fat),
    ancestors(B, erx_fat:first(Node), number(ToDir), Clusters + 1).

ancestors(_B, _Moved, 0, _Left) -> true;
ancestors(_B, Moved, Moved, _Left) -> false;
ancestors(_B, _Moved, _Cluster, 0) -> fail(does_not_read);
ancestors(B = #batch{fat = Fat}, Moved, Cluster, Left) ->
    #{type := Type} = erx_fat:info(Fat),
    ancestors(B, Moved, erx_fat_entry:first(dotdot(B, Cluster), Type), Left - 1).

%% Directory Cluster's `..` entry naming Parent, rewritten in linking.
parent_named(B, Cluster, Parent) ->
    set_entry(B, linking, dotdot_slot(B, Cluster),
              erx_fat_entry:encode(erx_fat_entry:with_first(dotdot(B, Cluster), Parent))).

%% Directory Cluster's `..` entry, its second.
dotdot(B, Cluster) ->
    case erx_fat_entry:decode(entry_at(B, dotdot_slot(B, Cluster))) of
        {short, DotDot = #{name := ?DOTDOT}} -> DotDot;
        _ -> fail(does_not_read)
    end.

dotdot_slot(B, Cluster) -> {hd(ok(erx_fat:cluster_sectors(view(B), Cluster))), ?ENTRY}.

%% ---------------------------------------------------------------------------
%% Names in a directory
%% ---------------------------------------------------------------------------

checked(Name) -> ok(erx_fat_name:check(Name)).

%% Fun folded over directory Dir as the batch leaves it (erx_fat:fold/4).
folded(B, Dir, Fun, Acc) -> ok(erx_fat:fold(Dir, view(B), Fun, Acc)).

%% The entry Name names in Dir (erx_fat_name:match/1): its node and the slots of its
%% entries, its short entry's last, or none.
lookup(B, Dir, Name) ->
    {Match, Read} = folded(B, Dir, fun(Index, {short, _, {Other, Node, Start}}, M) ->
                                           erx_fat_name:match(M, Other, {Node, Start, Index});
                                      (_Index, _Event, M) -> M
                                   end, erx_fat_name:match(Name)),
    case erx_fat_name:matched(Match) of
        none -> none;
        {Node, Start, Index} -> {Node, [slot(Read, I) || I <- lists:seq(Start, Index)]}
    end.

found(B, Dir, Name) ->
    case lookup(B, Dir, Name) of
        none -> fail(enoent);
        Found -> Found
    end.

%% Whether directory Node holds nothing but its dot entries.
empty(B, Node) ->
    {Empty, _Read} = folded(B, Node, fun(_Index, {short, #{name := Short}, _}, _) when Short =/= ?DOT, Short =/= ?DOTDOT -> false;
                                        (_Index, _Event, Empty) -> Empty
                                     end, true),
    Empty.

%% Name, of code units Units, placed in Dir: its entries written in publication in
%% the first free run, the directory grown when none is long enough (see the
%% module's doc). Entry(Short, Flags, B) runs once the scan has refused a name Dir
%% holds and before the directory grows; it answers the short entry to write and B
%% with what that entry names made ready (mkdir's cluster). Answers the node walk/3
%% reads back for the placed entry, made from where the scan put it, and the batch.
place(B, Dir, Name, Units, Entry) ->
    Basis = erx_fat_name:short_basis(Name),
    Long = length(erx_fat_name:long_entries(Units, ?DOT)) + 1,
    Scan0 = #scan{match = erx_fat_name:match(Name), basis = Basis,
                  tails = atomics:new(?TAILS_RECORDED div 64 + 1, [{signed, false}]), runs = [{1, none}, {Long, none}]},
    {Scan, Read} = folded(B, Dir, fun scanned/3, Scan0),
    erx_fat_name:matched(Scan#scan.match) =:= none orelse fail(eexist),
    {Short, Flags, Form} = erx_fat_name:short_name(Basis, Scan#scan.basis_taken, fun(N) -> tail_taken(Scan, N) end),
    {Entries, Where} = case {Form, run_for(Scan, 1, Read)} of
                           {short_only, {_, _, false} = Alone} -> {[], Alone};
                           _ -> {erx_fat_name:long_entries(Units, Short), run_for(Scan, Long, Read)}
                       end,
    {Named, B1} = Entry(Short, Flags, B),
    Written = Entries ++ [erx_fat_entry:encode(Named)],
    {Start, Sectors, B2} = room(B1, Read, Where, length(Written)),
    B3 = lists:foldl(fun({Index, Bytes}, Acc) -> set_entry(Acc, publication, slot(Sectors, Index), Bytes) end,
                     B2, lists:enumerate(Start, Written)),
    {erx_fat:entry_node(Dir, Start + length(Written) - 1, Named, B3#batch.fat), B3}.

%% The scan moved past entry Index.
scanned(Index, Event, S = #scan{runs = Runs, after_long = AfterLong}) ->
    S1 = S#scan{runs = [{Count, run(Run, Count, Index, Event =:= deleted, AfterLong)} || {Count, Run} <- Runs],
                after_long = Event =:= long},
    case Event of
        {short, #{name := Short}, Named} -> claimed(matched(S1, Named, Index), Short);
        _ -> S1
    end.

run({found, _, _} = Found, _Count, _Index, _Free, _AfterLong) -> Found;
run(_Run, _Count, _Index, false, _AfterLong) -> none;
run(none, Count, Index, true, AfterLong) -> counted({open, Index, AfterLong}, Count, Index);
run(Open, Count, Index, true, _AfterLong) -> counted(Open, Count, Index).

counted({open, Start, AfterLong}, Count, Index) when Index - Start + 1 =:= Count -> {found, Start, AfterLong};
counted(Open, _Count, _Index) -> Open.

matched(S, none, _Index) -> S;
matched(S = #scan{match = M}, {Other, Node, Start}, Index) -> S#scan{match = erx_fat_name:match(M, Other, {Node, Start, Index})}.

%% Short, a short entry's name, recorded when it is one of the basis's candidates.
claimed(S = #scan{basis = Basis, tails = Tails}, Short) ->
    case erx_fat_name:claim(Basis, Short) of
        basis -> S#scan{basis_taken = true};
        N when is_integer(N), N =< ?TAILS_RECORDED ->
            {Word, Bit} = tail_bit(N),
            ok = atomics:put(Tails, Word, atomics:get(Tails, Word) bor Bit),
            S;
        _ -> S
    end.

tail_taken(_S, N) when N > ?TAILS_RECORDED -> false;
tail_taken(#scan{tails = Tails}, N) ->
    {Word, Bit} = tail_bit(N),
    atomics:get(Tails, Word) band Bit =/= 0.

%% Tail N's word in the tails array and its bit in that word.
tail_bit(N) -> {N div 64 + 1, 1 bsl (N rem 64)}.

%% Where Count entries go once the scan has read the directory: {found, Start,
%% AfterLong} or {grow, Start, AfterLong}, the entries past the end marker free.
run_for(#scan{runs = Runs, after_long = LastLong}, Count, #{end_at := End, total := Total}) ->
    {Start, AfterLong} = case proplists:get_value(Count, Runs) of
                             {found, S, A} -> {S, A};
                             {open, S, A} -> {S, A};
                             none -> {End, LastLong}
                         end,
    case Start + Count =< Total of
        true -> {found, Start, AfterLong};
        false -> {grow, Start, AfterLong}
    end.

%% The run Where of Count entries made ready: its start, the directory's sectors
%% once it holds the run, and the batch that grows it when it must. A run that
%% reaches past the end marker has its entries from the marker on, and the entry
%% after it, zeroed in preparation, so what a medium holds past the old marker is
%% never read as a name, even when a cut lands only part of the publication.
room(B, #{sectors := Sectors, end_at := End, total := Total}, {found, Start, _}, Count) when Start + Count - 1 >= End ->
    {Start, Sectors, cleared(B, Sectors, max(Start, End), min(Start + Count, Total - 1))};
room(B, #{sectors := Sectors}, {found, Start, _}, _Count) ->
    {Start, Sectors, B};
room(_B, #{cluster := fixed}, {grow, _, _}, _Count) ->
    fail(enospc);
room(B, Read = #{sectors := Sectors, end_at := End, total := Total}, {grow, Start, _}, Count) ->
    grown(cleared(B, Sectors, max(Start, End), Total - 1), Read, Start, Count).

%% Entries From to To zeroed in preparation.
cleared(B, Sectors, From, To) ->
    lists:foldl(fun(Index, Acc) -> set_entry(Acc, preparation, slot(Sectors, Index), <<0:(?ENTRY * 8)>>) end,
                B, lists:seq(From, To)).

%% The directory grown by the zeroed clusters a run of Count entries from Start
%% needs past its entries.
grown(B = #batch{fat = Fat, alloc = Alloc}, #{sectors := Sectors, total := Total, cluster := First}, Start, Count) ->
    #{cluster_bytes := ClusterBytes} = erx_fat:info(Fat),
    PerCluster = ClusterBytes div ?ENTRY,
    Clusters = (Start + Count - Total + PerCluster - 1) div PerCluster,
    Total + Clusters * PerCluster =< ?DIR_ENTRIES_MAX orelse fail(enospc),
    {Run, Alloc1} = ok(erx_fat_alloc:grow(Alloc, First, Clusters)),
    B1 = lists:foldl(fun(Cluster, Acc) -> zeroed(Acc, Cluster, <<>>) end, B#batch{alloc = Alloc1}, Run),
    New = lists:append([ok(erx_fat:cluster_sectors(view(B1), Cluster)) || Cluster <- Run]),
    {Start, list_to_tuple(tuple_to_list(Sectors) ++ New), B1}.

%% The entries at Slots, one name's, marked deleted in preparation.
unnamed(B, Slots) ->
    lists:foldl(fun(Slot, Acc) -> set_entry(Acc, preparation, Slot, erx_fat_entry:deleted(entry_at(Acc, Slot))) end,
                B, Slots).

%% Entry Index of a directory of sectors Sectors, or of the directory fold/4 read.
-spec slot(tuple() | erx_fat:dir(), non_neg_integer()) -> slot().
slot(#{sectors := Sectors}, Index) -> slot(Sectors, Index);
slot(Sectors, Index) -> {element(Index div ?ENTRIES_PER_SECTOR + 1, Sectors), Index rem ?ENTRIES_PER_SECTOR * ?ENTRY}.

entry_at(B, {Sector, Offset}) -> binary:part(sector(B, Sector), Offset, ?ENTRY).

%% ---------------------------------------------------------------------------
%% Sector images
%% ---------------------------------------------------------------------------

%% Bytes, an entry or a file's data, at Slot from Step on: Step's image takes them, made from the latest image
%% of Step or a step before it, else from the medium, and so does every later image
%% the sector has.
set_entry(B = #batch{images = Images}, Step, {Sector, Offset}, Bytes) ->
    Steps = maps:get(Sector, Images, #{}),
    {Before, [Step | After]} = lists:splitwith(fun(Other) -> Other =/= Step end, ?STEPS),
    Base = case [maps:get(Other, Steps) || Other <- [Step | lists:reverse(Before)], is_map_key(Other, Steps)] of
               [Latest | _] -> Latest;
               [] -> medium(B, Sector)
           end,
    Later = #{Other => patched(Image, Offset, Bytes) || Other := Image <- Steps, lists:member(Other, After)},
    B#batch{images = Images#{Sector => maps:merge(Steps, Later#{Step => patched(Base, Offset, Bytes)})}}.

patched(Image, Offset, Bytes) ->
    Length = byte_size(Bytes),
    <<Head:Offset/binary, _:Length/binary, Tail/binary>> = Image,
    <<Head/binary, Bytes/binary, Tail/binary>>.

%% Cluster, which the batch allocated, zeroed in preparation, its first bytes Head.
zeroed(B = #batch{images = Images}, Cluster, Head) ->
    [First | Rest] = ok(erx_fat:cluster_sectors(view(B), Cluster)),
    Zero = <<0:(?SECTOR * 8)>>,
    Written = [{First, <<Head/binary, 0:((?SECTOR - byte_size(Head)) * 8)>>} | [{Sector, Zero} || Sector <- Rest]],
    B#batch{images = maps:merge(Images, maps:from_list([{S, #{preparation => Bytes}} || {S, Bytes} <- Written]))}.

latest(Steps) -> maps:get(lists:last([Step || Step <- ?STEPS, is_map_key(Step, Steps)]), Steps).

%% Sector as the batch leaves it.
sector(B, Sector) ->
    #{read := Read} = erx_fat:layout(view(B)),
    checked_sector(Read(Sector)).

%% Sector as the medium holds it, beneath the batch's directory images.
medium(#batch{fat = Fat}, Sector) ->
    #{read := Read} = erx_fat:layout(Fat),
    checked_sector(Read(Sector)).

checked_sector({ok, <<Bytes:?SECTOR/binary>>}) -> Bytes;
checked_sector(_) -> fail(read_failed).

%% The cluster a directory's children's `..` entries name: 0 for the root.
number(Dir) ->
    case erx_fat:first(Dir) of
        root -> 0;
        Cluster -> Cluster
    end.

kind(Node) -> maps:get(kind, erx_fat:attr(Node)).

%% ---------------------------------------------------------------------------
%% Failure
%% ---------------------------------------------------------------------------

guarded(Fun) ->
    try Fun() of
        {Result, #batch{} = B} -> {ok, Result, B};
        {Result, finished} -> {ok, Result, finished};
        #batch{} = B -> {ok, B}
    catch throw:{?MODULE, Error} -> {error, Error}
    end.

fail(Error) -> throw({?MODULE, Error}).

%% A result of erx_fat, erx_fat_name or erx_fat_alloc, its error in this module's set.
ok({ok, Value}) -> Value;
ok({ok, Value, Rest}) -> {Value, Rest};
ok({error, no_space}) -> fail(enospc);
ok({error, not_dir}) -> fail(enotdir);
ok({error, not_found}) -> fail(enoent);
ok({error, Error}) -> fail(Error).
