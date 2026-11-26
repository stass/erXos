%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat).
-moduledoc """
The FAT server's read path (docs/design-storage.md, "Removable media: FAT", and
docs/design-drives.md, "FAT"): one FAT16 or FAT32 volume of a drive, read through
the function it is handed, which reads one 512-byte sector of the volume's
placement. It holds no device and no process; the volume process
(erx_media_volume) holds what mount/2 answers and runs each operation on it. Every
byte of the volume is untrusted input.

* **The mount.** The boot sector's type is erx_fat_read:boot_sector/1's, the
  decoder the drives' probe used; FAT16 and FAT32 are admitted, with 512-byte
  sectors, a power-of-two cluster of at most 128 sectors, every region inside
  the placement, and a FAT that holds an entry for every cluster of the data
  area. Anything else is `not_its_volume`. The FAT read is the first copy, or the
  one FAT32's mirroring flags name active; its second entry's clean bit is the
  volume's dirty flag.
* **Directories.** A directory is read entry by entry to its end marker or its
  last entry: FAT16's root as its fixed region, every other directory as its
  cluster chain, at most 65,536 entries (2 MiB), the specification's bound. A
  long name counts only when its entries run in order from the last to the first,
  each with the checksum of the short entry that follows them, and its UTF-16 is
  valid and fits 255 bytes of UTF-8; otherwise the entry is listed under its short
  name, decoded as code page 437 with the case flags Windows writes. A name the
  specification forbids (a `/`, a control, `.` or `..` among them) is never
  listed, so no name a medium supplies reaches outside its directory. Deleted
  entries, volume labels and the `.` and `..` entries are not listed.
* **Lookups.** A name is found by its bytes, or else as the first entry whose
  name compares equal by erx_fat_name:key/1, each UTF-16 code unit of the Basic
  Multilingual Plane uppercased by the generated case table.
* **Reads.** A chain is followed at most as many steps as the read needs and the
  volume has clusters, each link a cluster of the data area not seen before in
  the chain; a link out of the data area, a cluster seen twice and an end of
  chain before the clusters needed are `does_not_read`. A read answers at most
  the bytes the directory entry's size gives.
* **The ownership check.** check/1 runs before a writable mount writes anything:
  two passes over the FAT the server reads and a walk of every directory, which
  marks in two sets of one bit a cluster every cluster an entry links to and every
  name's first cluster, and finds a cluster linked to twice, a first cluster named
  twice or linked to, a dot entry that names no parent, and a reached cluster whose
  entry is free or bad. Any finding, a directory the read path would refuse with
  `does_not_read` among them, is `tree`; the sets are atomics local to the call.
  The directories found and not yet walked stay within a quarter of the volume's
  memory bound, ?CHECK_PENDING_MAX of them; a volume that queues more is
  `too_large`, as one of too many clusters is.
* **The write path's view.** fold/4 folds a function over a directory's entries
  as erx_fat_dir places names in it, a sector at a time, and answers the
  directory's sectors, size, end marker and first cluster, so no caller holds a
  directory's entries to read them. with_read/2 reads the volume through another
  function, the batch's view of it. Every entry is decoded by erx_fat_entry.

A sector the function does not answer with 512 bytes is `read_failed`, about the
medium's reading and not the volume's form. Each finding leaves through one
throw, `{erx_fat, Finding}`, caught at each exported entry; anything else the read
function raises propagates.
""".

-export([mount/2, info/1, layout/1, check/1, root/1, walk/3, attr/1, list/2, read/4, key/1]).
-export([with_read/2, first/1, fold/4, cluster_sectors/2, entry_slot/2, refreshed/2]).
-export_type([fat/0, fat_node/0, finding/0, read_sector/0, dir/0, event/0]).

-include("generated/erx_abi.hrl").

-define(SECTOR, 512).
-include("erx_fat_entry.hrl").

-define(ENTRIES_PER_SECTOR, (?SECTOR div ?ENTRY)).
%% A short name's first byte 0x05 stands for 0xE5 (section 6.1).
-define(KANJI_E5, 16#05).
%% The boot sector's extended signature, behind which its serial and label lie.
-define(EXTENDED_BOOT, 16#29).
%% 1980-01-01T00:00:00Z, FAT's first time, in seconds since the UNIX epoch.
-define(FAT_EPOCH, 315532800).
%% The least entry that ends a chain (section 4.1).
-define(END_MARK_16, 16#fff8).
-define(END_MARK_32, 16#0ffffff8).
%% FAT32's largest count of clusters, whose numbers end below the bad mark,
%% 16#0ffffff7, and the one file-system version FAT32 defines, 0.0, as fsimg, the
%% server's oracle, admits them (lib/formats/fat/codec.c:191-201 and :221-223 at
%% fsimg b6c1ea2).
-define(CLUSTERS_MAX_32, 16#0ffffff5).
-define(VERSION_32, 0).
%% The value a bad cluster's entry holds (section 4.1).
-define(BAD_16, 16#fff7).
-define(BAD_32, 16#0ffffff7).
%% The ownership check's two sets, one bit a cluster each, stay within half of
%% the volume's memory bound, so it checks at most 4,194,304 clusters.
-define(CHECKED_CLUSTERS_MAX, (?ERX_MEDIA_VOLUME_BYTES div 2 * 8 div 2)).
%% The directories the check has found and not yet walked, each a list cell and a
%% pair of small integers, five words, stay within a quarter of the bound.
-define(CHECK_PENDING_MAX, (?ERX_MEDIA_VOLUME_BYTES div 4 div 40)).

-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
-type finding() :: not_its_volume | does_not_read | read_failed.

%% The volume as its boot sector lays it out, in sectors from the placement's start.
%% root is FAT16's fixed root region, {fixed, FirstSector, Entries}, or FAT32's root
%% cluster. fat_start is the FAT the server reads, first_fat the first of the fats
%% copies of fat_sectors each; fsinfo is FAT32's FSInfo sector when the boot sector
%% names one in the reserved area.
-record(fat, {read :: read_sector(),
              type :: 16 | 32,
              per_cluster :: pos_integer(),
              fat_start :: pos_integer(),
              first_fat :: pos_integer(),
              fats :: pos_integer(),
              fat_sectors :: pos_integer(),
              fsinfo :: pos_integer() | none,
              mirrored :: boolean(),
              hard_error :: boolean(),
              data_start :: pos_integer(),
              clusters :: pos_integer(),
              root :: {fixed, pos_integer(), pos_integer()} | pos_integer(),
              label :: binary() | none,
              serial :: non_neg_integer() | none,
              clean :: boolean()}).

%% A file or directory: which it is, its key (root; a directory by its first
%% cluster, so two entries naming one directory name one key; a file by where its
%% entry lies, {file, ParentKey, Index}); its first cluster (0 for an empty file),
%% its size and its modification time.
-type key() :: root | {dir, pos_integer()} | {file, root | {dir, pos_integer()}, non_neg_integer()}.
-record(fat_node, {key :: key(),
                   kind :: dir | file,
                   first :: non_neg_integer() | root,
                   size :: non_neg_integer(),
                   mtime :: non_neg_integer(),
                   read_only :: boolean()}).

-opaque fat() :: #fat{}.
-opaque fat_node() :: #fat_node{}.

%% A directory as fold/4 answers it: its sectors in order, each of
%% ?ENTRIES_PER_SECTOR entries but the last of FAT16's root; its count of entries;
%% the index of its end marker, or its count when it has none; and its first
%% cluster, or fixed for FAT16's root, which cannot grow.
-type dir() :: #{sectors := tuple(), total := non_neg_integer(), end_at := non_neg_integer(),
                 cluster := pos_integer() | fixed}.
%% An entry as fold/4 meets it: deleted, a long-name entry, or a short entry with
%% what it names, {Name, Node, Start} with Start the index of the name's first
%% entry, or none when it names nothing the volume serves.
-type event() :: deleted | long | {short, erx_fat_entry:short(), {binary(), fat_node(), non_neg_integer()} | none}.

%% ---------------------------------------------------------------------------
%% The read path
%% ---------------------------------------------------------------------------

-doc """
The volume of a placement of Sectors sectors, read through Read: its admission
from the boot sector and its FAT's second entry.
""".
-spec mount(read_sector(), non_neg_integer()) -> {ok, fat()} | {error, finding()}.
mount(Read, Sectors) ->
    guarded(fun() -> admit(Read, Sectors, sector(Read, 0)) end).

-doc """
What the volume's status shows of it: its type, label, serial, its dirty and
hard-error flags and whether its FATs are mirrored, the last three what
erx_fat_alloc:writable/1 reads as the writable rule's fourth condition.
""".
-spec info(fat()) -> #{type := 16 | 32, label := binary() | none, serial := non_neg_integer() | none,
                       clean := boolean(), hard_error := boolean(), mirrored := boolean(),
                       cluster_bytes := pos_integer(), clusters := pos_integer()}.
info(#fat{type = Type, label = Label, serial = Serial, clean = Clean, hard_error = HardError,
          mirrored = Mirrored, per_cluster = PerCluster, clusters = Clusters}) ->
    #{type => Type, label => Label, serial => Serial, clean => Clean, hard_error => HardError,
      mirrored => Mirrored, cluster_bytes => PerCluster * ?SECTOR, clusters => Clusters}.

-doc """
Where the volume keeps what erx_fat_alloc writes: its FATs, the first first, its
count of clusters and FAT32's FSInfo sector; with the function that reads the
volume's sectors.
""".
-spec layout(fat()) -> erx_fat_alloc:layout().
layout(#fat{read = Read, type = Type, first_fat = First, fats = Fats, fat_sectors = FatSectors,
            clusters = Clusters, fsinfo = FsInfo}) ->
    #{read => Read, type => Type, fat_start => First, fats => Fats, fat_sectors => FatSectors,
      clusters => Clusters, fsinfo => FsInfo}.

-doc "The volume's root directory.".
-spec root(fat()) -> fat_node().
root(_Fat) ->
    #fat_node{key = root, kind = dir, first = root, size = 0, mtime = ?FAT_EPOCH, read_only = false}.

-doc "Which file or directory a node is, the same for as long as the volume is mounted.".
-spec key(fat_node()) -> key().
key(#fat_node{key = Key}) -> Key.

-doc "A node's kind, size, modification time in UNIX seconds, and read-only attribute.".
-spec attr(fat_node()) -> #{kind := dir | file, size := non_neg_integer(), mtime := non_neg_integer(),
                            read_only := boolean()}.
attr(#fat_node{kind = Kind, size = Size, mtime = Mtime, read_only = ReadOnly}) ->
    #{kind => Kind, size => Size, mtime => Mtime, read_only => ReadOnly}.

-doc "The entry of directory Dir named Name (see the module's doc), or `not_found`.".
-spec walk(fat_node(), binary(), fat()) -> {ok, fat_node()} | {error, not_found | not_dir | finding()}.
walk(#fat_node{kind = dir} = Dir, Name, Fat) ->
    guarded(fun() ->
                    {Match, _Dir} = fold_dir(Dir, Fat, fun(_Index, {short, _, {Other, Node, _}}, M) ->
                                                               erx_fat_name:match(M, Other, Node);
                                                          (_Index, _Event, M) -> M
                                                       end, erx_fat_name:match(Name)),
                    case erx_fat_name:matched(Match) of
                        none -> fail(not_found);
                        Node -> Node
                    end
            end);
walk(#fat_node{kind = file}, _Name, _Fat) ->
    {error, not_dir}.

-doc "Directory Dir's entries, each name with its node, in the order the volume holds them.".
-spec list(fat_node(), fat()) -> {ok, [{binary(), fat_node()}]} | {error, not_dir | finding()}.
list(#fat_node{kind = dir} = Dir, Fat) ->
    guarded(fun() -> entries(Dir, Fat) end);
list(#fat_node{kind = file}, _Fat) ->
    {error, not_dir}.

-doc "At most Count bytes of file File from Offset, none past its size.".
-spec read(fat_node(), non_neg_integer(), non_neg_integer(), fat()) ->
          {ok, binary()} | {error, is_dir | finding()}.
read(#fat_node{kind = dir}, _Offset, _Count, _Fat) ->
    {error, is_dir};
read(#fat_node{size = Size}, Offset, Count, _Fat) when Offset >= Size; Count =:= 0 ->
    {ok, <<>>};
read(#fat_node{first = First, size = Size}, Offset, Count, Fat = #fat{per_cluster = PerCluster}) ->
    guarded(fun() ->
                    Bytes = PerCluster * ?SECTOR,
                    End = min(Size, Offset + Count),
                    Skip = Offset div Bytes,
                    Chain = lists:nthtail(Skip, chain(Fat, First, (End - 1) div Bytes + 1)),
                    Data = iolist_to_binary([cluster(Fat, Cluster) || Cluster <- Chain]),
                    binary:copy(binary:part(Data, Offset - Skip * Bytes, End - Offset))
            end).

-doc "The volume read through Read, the batch's view of it (erx_fat_dir).".
-spec with_read(fat(), read_sector()) -> fat().
with_read(Fat, Read) -> Fat#fat{read = Read}.

-doc "A node's first cluster: 0 for an empty file, root for the root directory.".
-spec first(fat_node()) -> non_neg_integer() | root.
first(#fat_node{first = First}) -> First.

-doc """
Where file File's short entry lies, `{Sector, Offset}`: entry Index of the directory
its key names, whose sectors are followed afresh, so the slot is the one the volume
read through Fat holds.
""".
-spec entry_slot(fat_node(), fat()) -> {ok, {pos_integer(), non_neg_integer()}} | {error, finding()}.
entry_slot(#fat_node{key = {file, Parent, Index}}, Fat) ->
    guarded(fun() -> slot_of(Parent, Index, Fat) end).

-doc """
File File as the volume read through Fat holds its entry now: the same key, with its
entry's first cluster, size, time and read-only attribute. An entry that no longer
names a file is `does_not_read`.
""".
-spec refreshed(fat_node(), fat()) -> {ok, fat_node()} | {error, finding()}.
refreshed(#fat_node{key = {file, Parent, Index}} = File, Fat) ->
    guarded(fun() ->
                    {Sector, Offset} = slot_of(Parent, Index, Fat),
                    <<_:Offset/binary, Bytes:?ENTRY/binary, _/binary>> = sector(Fat#fat.read, Sector),
                    case erx_fat_entry:decode(Bytes) of
                        {short, Short} ->
                            erx_fat_entry:kind(Short) =:= file orelse fail(does_not_read),
                            File#fat_node{first = erx_fat_entry:first(Short, Fat#fat.type),
                                          size = maps:get(size, Short), mtime = erx_fat_entry:mtime(Short),
                                          read_only = erx_fat_entry:read_only(Short)};
                        _ -> fail(does_not_read)
                    end
            end).

%% Entry Index of the directory key Parent names: its sector and byte offset.
slot_of(Parent, Index, Fat) ->
    Dir = #fat_node{key = Parent, kind = dir, first = case Parent of root -> root; {dir, C} -> C end,
                    size = 0, mtime = ?FAT_EPOCH, read_only = false},
    {Sectors, Total} = dir_sectors(Dir, Fat),
    Index < Total orelse fail(does_not_read),
    {lists:nth(Index div ?ENTRIES_PER_SECTOR + 1, Sectors), Index rem ?ENTRIES_PER_SECTOR * ?ENTRY}.

-doc "The sectors of data cluster Cluster, in order.".
-spec cluster_sectors(fat(), pos_integer()) -> {ok, [pos_integer()]} | {error, does_not_read}.
cluster_sectors(Fat, Cluster) -> guarded(fun() -> cluster_sectors_of(Fat, data_cluster(Fat, Cluster)) end).

-doc """
Fun(Index, Event, Acc) folded over directory Dir's entries to its end marker, a
sector at a time (event()), with the directory as dir() answers it.
""".
-spec fold(fat_node(), fat(), fun((non_neg_integer(), event(), Acc) -> Acc), Acc) ->
          {ok, {Acc, dir()}} | {error, not_dir | finding()}.
fold(#fat_node{kind = dir} = Dir, Fat, Fun, Acc) ->
    guarded(fun() -> fold_dir(Dir, Fat, Fun, Acc) end);
fold(#fat_node{kind = file}, _Fat, _Fun, _Acc) ->
    {error, not_dir}.

guarded(Fun) ->
    try {ok, Fun()}
    catch throw:{?MODULE, Finding} -> {error, Finding}
    end.

fail(Finding) -> throw({?MODULE, Finding}).

%% ---------------------------------------------------------------------------
%% The volume
%% ---------------------------------------------------------------------------

sector(Read, Index) ->
    case Read(Index) of
        {ok, <<Bytes:?SECTOR/binary>>} -> Bytes;
        _ -> fail(read_failed)
    end.

%% The BIOS parameter block (section 3.1), then FAT16's tail or FAT32's (sections
%% 3.2 and 3.3), each destructured once. A FAT32 volume states its size and its
%% FAT's only in their 32-bit fields.
admit(Read, Sectors, <<_:11/binary, ?SECTOR:16/little, PerCluster, Reserved:16/little, Fats,
                       RootEntries:16/little, Total16:16/little, _Media, FatSize16:16/little, _:8/binary,
                       Total32:32/little, Tail/binary>> = Boot) ->
    Total = case Total16 of 0 -> Total32; _ -> Total16 end,
    Type = case erx_fat_read:boot_sector(Boot) of
               {fat, 16} -> 16;
               {fat, 32} when FatSize16 =:= 0, Total16 =:= 0 -> 32;
               _ -> fail(not_its_volume)
           end,
    #{fat_size := FatSectors, active := Active, root := RootCluster, serial := Serial, label := Label,
      version := Version, fsinfo := FsInfo, mirrored := Mirrored} = tail(Type, FatSize16, Tail),
    RootSector = Reserved + Fats * FatSectors,
    DataStart = RootSector + (RootEntries * ?ENTRY + ?SECTOR - 1) div ?SECTOR,
    Clusters = (Total - DataStart) div max(PerCluster, 1),
    admitted(lists:member(PerCluster, [1, 2, 4, 8, 16, 32, 64, 128])
             andalso Reserved >= 1 andalso Fats >= 1 andalso Active < Fats
             andalso Total =< Sectors andalso DataStart < Total andalso Clusters >= 1
             andalso FatSectors * ?SECTOR >= (Clusters + 2) * (Type div 8)
             andalso (Type =:= 16 orelse (Version =:= ?VERSION_32 andalso Clusters =< ?CLUSTERS_MAX_32))),
    Fat = #fat{read = Read, type = Type, per_cluster = PerCluster, fat_start = Reserved + Active * FatSectors,
               first_fat = Reserved, fats = Fats, fat_sectors = FatSectors, mirrored = Mirrored,
               fsinfo = case FsInfo of N when N >= 1, N < Reserved -> N; _ -> none end,
               data_start = DataStart, clusters = Clusters, root = {fixed, RootSector, RootEntries},
               label = Label, serial = Serial, clean = true, hard_error = false},
    Root = case {Type, RootCluster} of
               {16, none} when RootEntries >= 1 -> {fixed, RootSector, RootEntries};
               {32, Cluster} when RootEntries =:= 0 -> data_cluster(Fat, Cluster);
               _ -> fail(not_its_volume)
           end,
    #{clean := Clean, hard_error := HardError} = erx_fat_alloc:volume_flags(Type, raw_entry(Fat, 1)),
    Fat#fat{root = Root, clean = Clean, hard_error = HardError};
admit(_Read, _Sectors, _Boot) ->
    fail(not_its_volume).

admitted(true) -> ok;
admitted(false) -> fail(not_its_volume).

%% FAT16's tail holds its serial and label; FAT32's its FAT size, mirroring flags
%% and root cluster before them. A FAT32 volume whose flags turn mirroring off
%% reads the FAT they name.
tail(16, FatSize16, <<_Drive, _, Signature, Serial:32/little, Label:11/binary, _/binary>>) ->
    identity(Signature, Serial, Label, #{fat_size => FatSize16, active => 0, root => none, version => 0,
                                         fsinfo => none, mirrored => true});
tail(32, _FatSize16, <<FatSize32:32/little, Flags:16/little, Version:16/little, Root:32/little, Info:16/little,
                       _Backup:16, _:12/binary, _Drive, _, Signature, Serial:32/little, Label:11/binary,
                       _/binary>>) ->
    Mirrored = Flags band 16#80 =:= 0,
    Active = case Mirrored of true -> 0; false -> Flags band 16#0f end,
    identity(Signature, Serial, Label, #{fat_size => FatSize32, active => Active, root => Root, version => Version,
                                         fsinfo => Info, mirrored => Mirrored}).

%% The serial and label behind the extended signature. The label is text a status
%% line shows, so one holding a control character is none, as an empty one is.
identity(?EXTENDED_BOOT, Serial, Label, Tail) ->
    Text = short_text(Label),
    Shown = Text =/= <<>> andalso Text =/= <<"NO NAME">>
        andalso not lists:any(fun(C) -> C < 16#20 end, unicode:characters_to_list(Text)),
    Tail#{serial => Serial, label => case Shown of true -> Text; false -> none end};
identity(_Signature, _Serial, _Label, Tail) ->
    Tail#{serial => none, label => none}.

raw_entry(#fat{read = Read, type = Type, fat_start = FatStart}, Cluster) ->
    Offset = Cluster * (Type div 8),
    <<_:(Offset rem ?SECTOR)/binary, Entry:Type/little, _/binary>> = sector(Read, FatStart + Offset div ?SECTOR),
    Entry.

%% Cluster, when it is a cluster of the data area, the one check every cluster a
%% walk reaches passes: a directory entry's first and every link. A free, reserved
%% or bad entry is none, and breaks its chain.
data_cluster(#fat{clusters = Clusters}, Cluster) when is_integer(Cluster), Cluster >= 2, Cluster < Clusters + 2 ->
    Cluster;
data_cluster(_Fat, _Cluster) ->
    fail(does_not_read).

%% Cluster's link: end of chain, or the next cluster of the data area.
next_link(Fat = #fat{type = Type}, Cluster) ->
    case raw_entry(Fat, Cluster) band mask(Type) of
        Mark when Type =:= 16, Mark >= ?END_MARK_16; Type =:= 32, Mark >= ?END_MARK_32 -> end_of_chain;
        Next -> data_cluster(Fat, Next)
    end.

mask(16) -> 16#ffff;
mask(32) -> 16#0fffffff.

%% Exactly Count clusters of the chain from First, none seen before in it, so a
%% chain that loops or ends before them is does_not_read.
chain(#fat{clusters = Clusters}, _First, Count) when Count > Clusters ->
    fail(does_not_read);
chain(Fat, First, Count) ->
    walk_chain(Fat, data_cluster(Fat, First), {exactly, Count}, #{}, []).

%% A directory's whole chain, to its end of chain, within the entries' bound.
dir_chain(Fat = #fat{per_cluster = PerCluster, clusters = Clusters}, First) ->
    Max = min(Clusters, max(1, (?DIR_ENTRIES_MAX * ?ENTRY) div (PerCluster * ?SECTOR))),
    walk_chain(Fat, data_cluster(Fat, First), {at_most, Max}, #{}, []).

%% The one walk of a chain: Bound is {exactly, Left}, the clusters still to take, or
%% {at_most, Left}, the clusters it may still take before its end of chain. Only an
%% exact walk keeps the clusters it has seen: a loop never reaches an end of chain,
%% so an at-most walk runs out of Left on one, holding nothing more.
walk_chain(_Fat, Cluster, _Bound, Seen, _Got) when is_map_key(Cluster, Seen) ->
    fail(does_not_read);
walk_chain(_Fat, Cluster, {exactly, 1}, _Seen, Got) ->
    lists:reverse([Cluster | Got]);
walk_chain(Fat, Cluster, {Kind, Left}, Seen, Got) ->
    case {next_link(Fat, Cluster), Kind, Left} of
        {end_of_chain, at_most, _} -> lists:reverse([Cluster | Got]);
        {end_of_chain, exactly, _} -> fail(does_not_read);
        {_Next, at_most, 1} -> fail(does_not_read);
        {Next, exactly, _} -> walk_chain(Fat, Next, {Kind, Left - 1}, Seen#{Cluster => true}, [Cluster | Got]);
        {Next, at_most, _} -> walk_chain(Fat, Next, {Kind, Left - 1}, Seen, [Cluster | Got])
    end.

cluster_sectors_of(#fat{data_start = DataStart, per_cluster = PerCluster}, Cluster) ->
    First = DataStart + (Cluster - 2) * PerCluster,
    lists:seq(First, First + PerCluster - 1).

cluster(Fat = #fat{read = Read}, Cluster) ->
    [sector(Read, Sector) || Sector <- cluster_sectors_of(Fat, Cluster)].

%% ---------------------------------------------------------------------------
%% The ownership check
%% ---------------------------------------------------------------------------

-doc """
The ownership check a writable mount runs before it writes anything
(docs/design-storage.md, "The ownership check"): `ok` when the volume's names and
chains form one tree; `{read_only, too_large}` for a volume of more than
?CHECKED_CLUSTERS_MAX clusters, read not at all; `{read_only, tree}` for a
finding; `{error, read_failed}` when a sector does not read.
""".
-spec check(fat()) -> ok | {read_only, too_large | tree} | {error, read_failed}.
check(#fat{clusters = Clusters}) when Clusters > ?CHECKED_CLUSTERS_MAX ->
    {read_only, too_large};
check(Fat = #fat{clusters = Clusters}) ->
    Sets = {bits(Clusters), bits(Clusters)},
    try
        fat_pass(Fat, fun(Cluster, Value) -> linked_once(Fat, Sets, Cluster, Value) end),
        names_pass(Fat, Sets),
        fat_pass(Fat, fun(Cluster, Value) -> held_allocated(Fat, Sets, Cluster, Value) end)
    catch
        throw:{?MODULE, read_failed} -> {error, read_failed};
        throw:{?MODULE, too_large} -> {read_only, too_large};
        throw:{?MODULE, _Tree} -> {read_only, tree}
    end.

%% Fun applied to every cluster of the data area with its entry's value, the FAT the
%% server reads taken a sector at a time from start to end.
fat_pass(#fat{read = Read, type = Type, fat_start = Start, clusters = Clusters}, Fun) ->
    PerSector = ?SECTOR * 8 div Type,
    lists:foreach(fun(Index) ->
                          Values = [Entry band mask(Type) || <<Entry:Type/little>> <= sector(Read, Start + Index)],
                          [Fun(Cluster, Value) || {Cluster, Value} <- lists:enumerate(Index * PerSector, Values),
                                                  Cluster >= 2, Cluster < Clusters + 2]
                  end, lists:seq(0, (Clusters + 1) div PerSector)),
    ok.

%% What an entry holds: free, bad, the end of a chain, a link to a cluster of the
%% data area, or a value the specification gives no entry (section 4.1).
entry_kind(#fat{type = Type, clusters = Clusters}, Value) ->
    case Value of
        0 -> free;
        _ when Type =:= 16, Value =:= ?BAD_16; Type =:= 32, Value =:= ?BAD_32 -> bad;
        _ when Type =:= 16, Value >= ?END_MARK_16; Type =:= 32, Value >= ?END_MARK_32 -> end_of_chain;
        _ when Value >= 2, Value < Clusters + 2 -> {to, Value};
        _ -> invalid
    end.

%% The first pass: every cluster an entry links to marked once.
linked_once(Fat, {Linked, _Named}, _Cluster, Value) ->
    case entry_kind(Fat, Value) of
        {to, Next} -> mark(Linked, Next) andalso fail(tree);
        invalid -> fail(tree);
        _ -> ok
    end.

%% The third pass: a cluster a chain or a name reaches holds neither free nor bad.
held_allocated(Fat, {Linked, Named}, Cluster, Value) ->
    Held = marked(Linked, Cluster) orelse marked(Named, Cluster),
    Held andalso lists:member(entry_kind(Fat, Value), [free, bad]) andalso fail(tree).

%% The second pass: the directories walked from the root, FAT32's root cluster
%% named first.
names_pass(Fat = #fat{root = Root}, Sets) ->
    is_integer(Root) andalso named(Fat, Sets, Root),
    directories(Fat, Sets, [{root, 0}], 1).

%% Each directory once, from Work, which holds {Dir, Parent}: Dir is root or a
%% subdirectory's first cluster, and Parent the cluster its `..` names, 0 for the
%% root (section 6.1); Pending is Work's length. A subdirectory holds both its dot
%% entries.
directories(_Fat, _Sets, [], 0) ->
    ok;
directories(Fat, Sets, [{Dir, Parent} | Work], Pending) ->
    Node = #fat_node{key = root, kind = dir, first = Dir, size = 0, mtime = ?FAT_EPOCH, read_only = false},
    #{dot := Dot, dotdot := DotDot, work := Next, pending := Queued} =
        fold_entries(Fat, dir_sectors(Node, Fat),
                     fun(Entry, Acc = #{index := Index}) -> (owned(Fat, Sets, Dir, Parent, Entry, Acc))#{index := Index + 1} end,
                     #{dot => false, dotdot => false, work => Work, pending => Pending - 1, index => 0}),
    Dir =:= root orelse (Dot andalso DotDot) orelse fail(tree),
    directories(Fat, Sets, Next, Queued).

%% One entry of directory Dir: a name's first cluster named, a subdirectory queued,
%% and a subdirectory's `.` and `..`, its first two entries as the specification
%% places them, matched against its own first cluster and its parent's. Deleted, long-name and label entries hold no cluster (sections 6 and
%% 7), and the root has no dot entries, so any it holds are not read.
owned(Fat = #fat{type = Type}, Sets, Dir, Parent, {short, Short = #{name := Name}}, Acc = #{work := Work, index := Index}) ->
    First = erx_fat_entry:first(Short, Type),
    case {Name, erx_fat_entry:kind(Short)} of
        {_, label} -> Acc;
        {_, _} when Dir =:= root, Name =:= ?DOT orelse Name =:= ?DOTDOT -> Acc;
        {?DOT, _} -> (Index =:= 0 andalso First =:= Dir) orelse fail(tree), Acc#{dot := true};
        {?DOTDOT, _} -> (Index =:= 1 andalso First =:= Parent) orelse fail(tree), Acc#{dotdot := true};
        {_, dir} -> named(Fat, Sets, First), queued(Acc#{work := [{First, number(Dir)} | Work]});
        {_, file} when First =:= 0 -> Acc;
        {_, file} -> named(Fat, Sets, First), Acc
    end;
owned(_Fat, _Sets, _Dir, _Parent, _Unnamed, Acc) ->
    Acc.

queued(#{pending := Pending}) when Pending >= ?CHECK_PENDING_MAX -> fail(too_large);
queued(Acc = #{pending := Pending}) -> Acc#{pending := Pending + 1}.

%% The cluster a directory's children's `..` entries name.
number(root) -> 0;
number(Cluster) -> Cluster.

%% First, a name's first cluster: a cluster of the volume, so never 0, which no
%% subdirectory's entry may give, that no entry links to and no other name gives.
named(#fat{clusters = Clusters}, {Linked, Named}, First) ->
    First >= 2 andalso First < Clusters + 2 orelse fail(tree),
    marked(Linked, First) andalso fail(tree),
    mark(Named, First) andalso fail(tree).

%% A set of clusters, one bit each, local to one check.
bits(Clusters) -> atomics:new((Clusters + 63) div 64, [{signed, false}]).

%% Cluster added to Set; whether Set held it before.
mark(Set, Cluster) ->
    {Word, Bit} = bit(Cluster),
    Old = atomics:get(Set, Word),
    ok = atomics:put(Set, Word, Old bor Bit),
    Old band Bit =/= 0.

marked(Set, Cluster) ->
    {Word, Bit} = bit(Cluster),
    atomics:get(Set, Word) band Bit =/= 0.

bit(Cluster) -> {(Cluster - 2) div 64 + 1, 1 bsl ((Cluster - 2) rem 64)}.

%% ---------------------------------------------------------------------------
%% Directories
%% ---------------------------------------------------------------------------

%% The sectors of a directory, in order, with its count of entries: FAT16's fixed
%% root region, or a directory's cluster chain.
dir_sectors(#fat_node{first = root}, #fat{root = {fixed, First, Count}}) ->
    {lists:seq(First, First + (Count - 1) div ?ENTRIES_PER_SECTOR), Count};
dir_sectors(#fat_node{first = root}, Fat = #fat{root = Cluster}) ->
    chain_sectors(Fat, Cluster);
dir_sectors(#fat_node{first = First}, Fat) ->
    chain_sectors(Fat, First).

chain_sectors(Fat, First) ->
    Sectors = [Sector || Cluster <- dir_chain(Fat, First), Sector <- cluster_sectors_of(Fat, Cluster)],
    {Sectors, length(Sectors) * ?ENTRIES_PER_SECTOR}.

%% A directory's entries, each name with its node, in order.
entries(Dir, Fat) ->
    {Got, _Dir} = fold_dir(Dir, Fat, fun(_Index, {short, _, {Name, Node, _}}, Acc) -> [{Name, Node} | Acc];
                                        (_Index, _Event, Acc) -> Acc
                                     end, []),
    lists:reverse(Got).

%% Fun folded over a directory's entries through one cursor, to its end marker,
%% whose index the cursor's index ends at, with the directory as dir() answers it.
%% Long is the long name being gathered across entries and sectors, none or
%% {long, Next, Sum, Parts, Start}: the order number the next entry must carry, the
%% checksum all carry, the parts read so far, first part first, and the index of
%% its first entry.
fold_dir(#fat_node{key = Parent, first = First} = Dir, Fat = #fat{root = Root}, Fun, Acc0) ->
    {Sectors, Total} = dir_sectors(Dir, Fat),
    Cursor = #{fat => Fat, parent => Parent, step => Fun, index => 0, long => none, acc => Acc0},
    #{index := End, acc := Acc} =
        fold_entries(Fat, {Sectors, Total},
                     fun(Entry, Next = #{index := Index}) -> (event(Entry, Next))#{index := Index + 1} end, Cursor),
    {Acc, #{sectors => list_to_tuple(Sectors), total => Total, end_at => End,
            cluster => case {First, Root} of
                           {root, {fixed, _, _}} -> fixed;
                           {root, Cluster} -> Cluster;
                           _ -> First
                       end}}.

%% Fun fed one entry, the long name gathered so far moved on.
event(Entry, Cursor = #{index := Index, long := Long, step := Fun, acc := Acc}) ->
    {Event, Next} = case Entry of
                        deleted -> {deleted, none};
                        bad_long -> {long, none};
                        {long, Order, Last, Sum, Part} -> {long, long_part(Order, Last, Sum, Part, Long, Index)};
                        {short, Short} -> {{short, Short, listed(Short, Long, Cursor)}, none}
                    end,
    Cursor#{long := Next, acc := Fun(Index, Event, Acc)}.

%% What short entry Short names, after long name Long: {Name, Node, Start}, or none
%% for a label, a dot entry or a name the volume may not serve.
listed(Short = #{name := Bytes, flags := Case}, Long, #{fat := Fat, parent := Parent, index := Index}) ->
    Kind = erx_fat_entry:kind(Short),
    case Kind =/= label andalso binary:first(Bytes) =/= $. andalso name(Bytes, Case, Long, Index) of
        {Name, Start} ->
            First = erx_fat_entry:first(Short, Fat#fat.type),
            {Name, #fat_node{key = node_key(Fat, Kind, First, Parent, Index), kind = Kind, first = First,
                             size = case Kind of file -> maps:get(size, Short); dir -> 0 end,
                             mtime = erx_fat_entry:mtime(Short), read_only = erx_fat_entry:read_only(Short)},
             Start};
        _ ->
            none
    end.

%% Fun folded over a directory's entries, given as its sectors and its count of
%% entries, a sector read at a time, each entry decoded, to its end marker or its
%% last entry.
fold_entries(Fat, {Sectors, Total}, Fun, Acc) ->
    fold_sectors(Fat, Sectors, Total, Fun, Acc).

fold_sectors(_Fat, [], _Left, _Fun, Acc) ->
    Acc;
fold_sectors(Fat = #fat{read = Read}, [Sector | Rest], Left, Fun, Acc) ->
    Count = min(?ENTRIES_PER_SECTOR, Left),
    case fold_sector(sector(Read, Sector), Count, Fun, Acc) of
        {done, Done} -> Done;
        {next, Next} -> fold_sectors(Fat, Rest, Left - Count, Fun, Next)
    end.

fold_sector(_Bytes, 0, _Fun, Acc) ->
    {next, Acc};
fold_sector(<<Bytes:?ENTRY/binary, Rest/binary>>, Left, Fun, Acc) ->
    case erx_fat_entry:decode(Bytes) of
        end_of_directory -> {done, Acc};
        Entry -> fold_sector(Rest, Left - 1, Fun, Fun(Entry, Acc))
    end.

node_key(#fat{root = First}, dir, First, _Parent, _Index) -> root;
node_key(_Fat, dir, First, _Parent, _Index) -> {dir, First};
node_key(_Fat, file, _First, Parent, Index) -> {file, Parent, Index}.

%% A long name's entries run from its last, flagged, down to order number 1, each
%% with the same checksum; any other entry starts the gathering again or drops it.
long_part(Order, true, Sum, Part, _Long, Index) when Order >= 1 ->
    {long, Order - 1, Sum, [Part], Index};
long_part(Order, false, Sum, Part, {long, Order, Sum, Parts, Start}, _Index) when Order >= 1 ->
    {long, Order - 1, Sum, [Part | Parts], Start};
long_part(_Order, _Last, _Sum, _Part, _Long, _Index) ->
    none.

%% The entry's name with the index of its first entry: its long name when one
%% complete, matching and valid precedes it, else its short name at Index, and none
%% when neither is a name the volume may serve.
name(Short, Case, {long, 0, Sum, Parts, Start}, Index) ->
    case Sum =:= erx_fat_name:checksum(Short) andalso long_name(iolist_to_binary(Parts)) of
        Name when is_binary(Name) -> {Name, Start};
        _ -> name(Short, Case, none, Index)
    end;
name(Short, Case, _Long, Index) ->
    case erx_fat_name:valid(short_name(Short, Case)) of
        none -> none;
        Name -> {Name, Index}
    end.

%% The UTF-16 code units up to the terminating zero, as UTF-8.
long_name(Units) ->
    Text = take_units(Units, <<>>),
    case unicode:characters_to_binary(Text, {utf16, little}, utf8) of
        Name when is_binary(Name), byte_size(Name) =< 255 -> erx_fat_name:valid(Name);
        _ -> none
    end.

take_units(<<0:16, _/binary>>, Got) -> Got;
take_units(<<Unit:2/binary, Rest/binary>>, Got) -> take_units(Rest, <<Got/binary, Unit/binary>>);
take_units(<<>>, Got) -> Got.

%% An 8.3 name: its base and extension, trailing spaces dropped, each lower-cased
%% when its case flag says so, and joined by a period when the extension is not
%% empty. A first byte 0x05 stands for 0xE5.
short_name(<<?KANJI_E5, Rest:10/binary>>, Case) ->
    short_name(<<16#e5, Rest/binary>>, Case);
short_name(<<Base:8/binary, Extension:3/binary>>, Case) ->
    B = cased(short_text(Base), Case band ?LOWER_BASE),
    case cased(short_text(Extension), Case band ?LOWER_EXTENSION) of
        <<>> -> B;
        E -> <<B/binary, $., E/binary>>
    end.

cased(Text, 0) -> Text;
cased(Text, _) -> << <<(case C of _ when C >= $A, C =< $Z -> C + 32; _ -> C end)/utf8>> || <<C/utf8>> <= Text >>.

%% Bytes of a short name or label as code page 437, trailing spaces and NULs dropped.
short_text(Bytes) ->
    Trimmed = trim_spaces(Bytes, byte_size(Bytes)),
    << <<(cp437(Byte))/utf8>> || <<Byte>> <= Trimmed >>.

-define(CP437_HIGH,
        {16#00c7, 16#00fc, 16#00e9, 16#00e2, 16#00e4, 16#00e0, 16#00e5, 16#00e7, 16#00ea, 16#00eb, 16#00e8,
         16#00ef, 16#00ee, 16#00ec, 16#00c4, 16#00c5, 16#00c9, 16#00e6, 16#00c6, 16#00f4, 16#00f6, 16#00f2,
         16#00fb, 16#00f9, 16#00ff, 16#00d6, 16#00dc, 16#00a2, 16#00a3, 16#00a5, 16#20a7, 16#0192, 16#00e1,
         16#00ed, 16#00f3, 16#00fa, 16#00f1, 16#00d1, 16#00aa, 16#00ba, 16#00bf, 16#2310, 16#00ac, 16#00bd,
         16#00bc, 16#00a1, 16#00ab, 16#00bb, 16#2591, 16#2592, 16#2593, 16#2502, 16#2524, 16#2561, 16#2562,
         16#2556, 16#2555, 16#2563, 16#2551, 16#2557, 16#255d, 16#255c, 16#255b, 16#2510, 16#2514, 16#2534,
         16#252c, 16#251c, 16#2500, 16#253c, 16#255e, 16#255f, 16#255a, 16#2554, 16#2569, 16#2566, 16#2560,
         16#2550, 16#256c, 16#2567, 16#2568, 16#2564, 16#2565, 16#2559, 16#2558, 16#2552, 16#2553, 16#256b,
         16#256a, 16#2518, 16#250c, 16#2588, 16#2584, 16#258c, 16#2590, 16#2580, 16#03b1, 16#00df, 16#0393,
         16#03c0, 16#03a3, 16#03c3, 16#00b5, 16#03c4, 16#03a6, 16#0398, 16#03a9, 16#03b4, 16#221e, 16#03c6,
         16#03b5, 16#2229, 16#2261, 16#00b1, 16#2265, 16#2264, 16#2320, 16#2321, 16#00f7, 16#2248, 16#00b0,
         16#2219, 16#00b7, 16#221a, 16#207f, 16#00b2, 16#25a0, 16#00a0}).

trim_spaces(Bytes, Size) when Size > 0, binary_part(Bytes, Size - 1, 1) =:= <<" ">>;
                              Size > 0, binary_part(Bytes, Size - 1, 1) =:= <<0>> ->
    trim_spaces(Bytes, Size - 1);
trim_spaces(Bytes, Size) ->
    binary_part(Bytes, 0, Size).

%% Code page 437's upper half, from Unicode's mapping table
%% (https://www.unicode.org/Public/MAPPINGS/VENDORS/MICSFT/PC/CP437.TXT, SHA-256
%% 6bad4dabcdf5940227c7d81fab130dcb18a77850b5d79de28b5dc4e047b0aaac); the lower half
%% is ASCII.
cp437(Byte) when Byte < 16#80 -> Byte;
cp437(Byte) -> element(Byte - 16#7f, ?CP437_HIGH).


