%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_check).
-moduledoc """
The checker of a FAT volume (docs/design-fsck-fat.md, "The checker"): one pure
function over a function that reads one 512-byte sector of the volume and the
volume file's length in sectors, which answers what FreeBSD 15.1's `fsck_msdosfs`
finds on it, in FreeBSD's order of examination, or a fatal finding, or a refusal.
It writes nothing, and every byte it reads is untrusted input.

* **Admission.** The boot sector is erx_fat's, admitted by erx_fat:admission/2
  given the file's length, so a volume that claims more sectors than the file holds
  is refused before a FAT sector is read. FAT12 and sectors other than 512 bytes are
  refused, as are FATs whose mirroring is off; any other refusal of the boot sector
  is fatal, as FreeBSD's is. A volume of more clusters than the ownership check
  examines (erx_fat:checked_clusters_max/0) is refused before the FAT is read.
* **The order.** The FSInfo sector's signatures, then the FAT's first two entries;
  phase 1, every FAT entry once in cluster order, with each other copy of the FAT
  compared as its sectors pass; phase 2, the directories from the root, the last
  subdirectory found in a directory walked first, its whole subtree before the
  next; phase 3, lost chains in cluster order, then loops of lost clusters, then
  the FSInfo hints; then the copies that differ and the dirty flag.
* **The view.** Each finding is decided as if every earlier repair were made:
  every chain the checker ends is held as the FAT entry it writes, and every read
  of a FAT entry goes through those, so a later decision sees the earlier ones.
* **Walks end.** Phase 1 ends one of every two chains that link to one cluster, and
  a repair only ever writes an end of chain, so no cluster is linked to twice; a
  walk starts only at a cluster nothing links to, so it never meets a cluster twice
  and takes at most as many steps as the volume has clusters.
* **Bounds** (the design's Bounds table): two sets of one bit a cluster, outside
  the heap; the directories on the walk's path and those waiting, each measured as
  ?ITEM_BYTES bytes plus its name's, within ?HELD_BYTES_MAX; ?CACHE_SECTORS cached
  FAT sectors; ?EDITS_MAX FAT entries the repair writes; findings measured as
  ?ITEM_BYTES bytes plus their text's, within ?HELD_BYTES_MAX, each path its last
  ?PATH_BYTES_MAX bytes. Each is checked before what it limits grows past it, and a
  volume that would pass one is refused naming it.
* **The repair** (the design's "Writing a repair"). Every repair decided is an
  edit, a few bytes at an offset of one sector, in one step: FAT entries the
  repair ends in `cutting`, directory entries that come to reach less in
  `preparation`, those that come to reach more in `publication`, the FSInfo
  signatures in `fsinfo`. Directory reads go through the edits decided so far,
  so a later decision, lost chains named in `/LOST.DIR` among them, sees the
  earlier ones. When the order has run, erx_fat:check/1 over the volume as the
  repair leaves it decides whether the repair is answered at all. write/4 writes
  it step by step, each step computed from what the medium then holds.

Names in paths are FreeBSD's: a long name's UTF-16 code units shown by their low
byte, `?` for one beyond Latin-1, or else the short name as `NAME.EXT`. They are the
medium's bytes, which the report escapes. Each answer leaves through one throw,
`{erx_fat_check, Answer}`, caught at check/2.
""".

-export([check/2, write/4, message/1]).
-export_type([result/0, finding/0, fatal/0, refusal/0, repair/0]).

-include("erx_fat_entry.hrl").

-define(SECTOR, 512).
-define(ENTRIES_PER_SECTOR, (?SECTOR div ?ENTRY)).
%% The bounds of the design's Bounds table.
-define(EDITS_MAX, 12288).
-define(HELD_BYTES_MAX, 1048576).
-define(ITEM_BYTES, 64).
-define(PATH_BYTES_MAX, 1024).
-define(CACHE_SECTORS, 64).
%% FreeBSD's long-name buffer, whose end a name may not reach (dosfs.h:100), and the
%% mask of a long-name entry's order number (dosfs.h:102).
-define(LONG_NAME_BYTES, 256).
-define(UNITS_PER_ENTRY, 13).
-define(ORDER_MASK, 16#1f).
%% An FSInfo hint that is unknown.
-define(UNKNOWN, 16#ffffffff).
%% A deleted directory entry's first byte, and the short name of the root's
%% directory of lost chains.
-define(DELETED, 16#e5).
-define(LOST_DIR, <<"LOST    DIR">>).
%% The sectors one commit of a repair reads and writes at most, a raw file's
%% largest request.
-define(COMMIT_SECTORS, 256).
%% The steps of a repair's edits, in the order they are written.
-define(EDIT_STEPS, [preparation, cutting, publication, fsinfo]).
%% A word of a cluster set whose clusters are all in it.
-define(WORD_FULL, 16#ffffffffffffffff).

-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
-type path() :: binary().
-type finding() :: fsinfo_signature
                 | {fat_header, binary()}
                 | {out_of_range_link, pos_integer(), non_neg_integer()}
                 | {crossed, pos_integer(), pos_integer()}
                 | {chain_end, pos_integer(), free | bad}
                 | {entries_after_end, path()}
                 | {invalid_long, path()} | {invalid_long_at_end, path()} | invalid_long_label
                 | invalid_long_name | long_name_too_long | long_cluster
                 | {start_out_of_range, path(), non_neg_integer()} | {not_new_chain, path()}
                 | {dir_size, path()}
                 | {dot_cluster, path()} | {dotdot_nonzero, path()} | {dotdot_cluster, path()}
                 | {dot_out_of_place, dot | dotdot, path()}
                 | {incorrect_dot, binary()} | {incorrect_dotdot, binary()}
                 | {invalid_cluster, path(), non_neg_integer(), pos_integer()}
                 | {size_too_large, path(), non_neg_integer(), non_neg_integer()}
                 | {too_many_clusters, path()}
                 | {lost_chain, pos_integer(), pos_integer(), fate()}
                 | {lost_loop, pos_integer()}
                 | {fsinfo_free, non_neg_integer(), non_neg_integer()}
                 | {fsinfo_next, non_neg_integer(), invalid | not_free}
                 | {fat_copy_differs, pos_integer()}
                 | dirty.
-type fatal() :: {boot_sector, erx_fat:refusal() | root} | root_not_chain.
%% What becomes of a lost chain: named as a file of /LOST.DIR, or kept allocated and
%% unnamed, and why (the design's "Lost chains").
-type fate() :: named | no_lost_dir | no_slot | name_taken | too_large.
-type refusal() :: fat12 | sector_size | not_mirrored | {bound, clusters | directories | edits | findings}
                 | {read_failed, non_neg_integer()} | {not_writable, too_large | tree | read_failed}.
-type step() :: cutting | preparation | publication | fsinfo.
%% An edit's bytes, or a FAT32 entry's value bits, whose reserved top four bits are
%% kept as the medium holds them when the edit is written.
-type value() :: binary() | {fat32, non_neg_integer()}.
-type edits() :: #{non_neg_integer() => #{non_neg_integer() => value()}}.
%% A repair: the volume's FAT layout and its edits by step, sector and offset; none
%% for a volume with nothing to repair.
-type repair() :: none | #{layout := map(), edits := #{step() => edits()}}.
-type result() :: {ok, [finding()], repair()} | {fatal, fatal()} | {refused, refusal()}.
-type write_sector() :: fun((non_neg_integer(), binary()) -> ok | {error, term()}).
-type flush() :: fun(() -> ok | {error, term()}).

%% The check's state. links is the view of the FAT: the entries the repair writes,
%% by cluster, in their value bits; edits the view of every other sector, by sector
%% and byte offset, each with its step, counted in edit_count with links. cleared is
%% FreeBSD's head map inverted: a cluster is in it once it is free or bad, something
%% links to it or a walk started at it, so a cluster not in it starts a chain no one
%% has walked; reached holds every cluster a walk kept in its chain. held counts the
%% directories' bytes, findings' bytes theirs. lost_dir is the first cluster of the
%% root's LOST.DIR; lost_slots its free slots and names the numbers its entries are
%% named, read when the first lost chain is named.
-record(st, {read :: read_sector(),
             fat :: erx_fat:fat(),
             type :: 16 | 32,
             clusters :: pos_integer(),
             cluster_bytes :: pos_integer(),
             first_fat :: pos_integer(),
             fats :: pos_integer(),
             fat_sectors :: pos_integer(),
             cleared :: atomics:atomics_ref(),
             reached :: atomics:atomics_ref(),
             cache = #{} :: #{non_neg_integer() => binary()},
             links = #{} :: #{non_neg_integer() => non_neg_integer()},
             edits = #{} :: #{non_neg_integer() => #{non_neg_integer() => {step(), value()}}},
             edit_count = 0 :: non_neg_integer(),
             lost_dir = none :: none | pos_integer(),
             lost_slots = unread :: unread | [{non_neg_integer(), non_neg_integer()}],
             names :: atomics:atomics_ref() | undefined,
             findings = [] :: [finding()],
             finding_bytes = 0 :: non_neg_integer(),
             held = 0 :: non_neg_integer(),
             free = 0 :: non_neg_integer(),
             fsinfo = none :: none | {non_neg_integer(), non_neg_integer()},
             copies = [] :: [pos_integer()],
             tails = [] :: [pos_integer()],
             dirty = false :: boolean()}).

%% A directory on the walk's path: its first cluster (0 for FAT16's root), its name
%% (root for the root), the subdirectory it was found as (none for the root), and
%% the subdirectories found in it and not yet walked, the last found first.
-type frame() :: #{head := non_neg_integer(), name := binary() | root, kid => kid(), kids := [kid()]}.
%% A subdirectory waiting: its first cluster, its name, and the places of its short
%% entry and of its long name's entries, each as <<Sector:32, Offset:16>>.
-type kid() :: {pos_integer(), binary(), binary()}.

-doc """
The findings on the volume Read reads, of Sectors sectors, in FreeBSD's order (see
the module's doc), and the repair of them all, `none` when there is no finding;
`{fatal, Finding}` for a boot sector the checker cannot take or a FAT32 root that
starts no chain; `{refused, Reason}` for a volume it does not check or one that
would pass a bound, for a sector that does not read, and `{not_writable, Why}` for
a volume the repair would leave failing erx_fat:check/1 as Why.
""".
-spec check(read_sector(), non_neg_integer()) -> result().
check(Read, Sectors) ->
    try examined(Read, Sectors)
    catch throw:{?MODULE, Answer} -> Answer
    end.

examined(Read, Sectors) ->
    Fat = admitted(erx_fat:admission(Read, Sectors)),
    #{type := Type, fat_start := FirstFat, fats := Fats, fat_sectors := FatSectors, clusters := Clusters,
      fsinfo := FsInfo} = erx_fat:layout(Fat),
    #{mirrored := Mirrored, cluster_bytes := ClusterBytes} = erx_fat:info(Fat),
    #{root := Root, media := Media} = erx_fat:geometry(Fat),
    Mirrored orelse answer({refused, not_mirrored}),
    Clusters =< erx_fat:checked_clusters_max() orelse answer({refused, {bound, clusters}}),
    St = #st{read = Read, fat = Fat, type = Type, clusters = Clusters, cluster_bytes = ClusterBytes,
             first_fat = FirstFat, fats = Fats, fat_sectors = FatSectors,
             cleared = cluster_set(Clusters), reached = cluster_set(Clusters)},
    Phases = [fun(S) -> fsinfo_signature(S, FsInfo) end,
              fun(S) -> fat_header(S, Media) end,
              fun fat_pass/1,
              fun(S) -> directories(S, Root) end,
              fun(S) -> lost_chains(S, 2) end,
              fun(S) -> lost_loops(S, 2) end,
              fun fsinfo_hints/1,
              fun copies/1,
              fun dirty/1],
    Done = #st{findings = Findings} = lists:foldl(fun(Phase, S) -> Phase(S) end, St, Phases),
    {ok, lists:reverse(Findings), writable(repair(Done, FsInfo), Fat, Read)}.

%% The repair of the findings: the FAT entries the view holds, but entry 1, which
%% the last step writes, in `cutting`; every other edit in its own step; and, when
%% the FSInfo signatures were wrong, the signatures and both hints unknown in
%% `fsinfo` (the design's "The repair order"); none without a finding.
repair(#st{findings = []}, _FsInfo) ->
    none;
repair(St = #st{links = Links, edits = Edits, fat = Fat}, FsInfo) ->
    Cuts = [{cutting, fat_place(St, Cluster), fat_value(St, Cluster, Value)}
            || Cluster := Value <- Links, Cluster =/= 1],
    Others = [{Step, {Sector, Offset}, Value} || Sector := Offsets <- Edits, Offset := {Step, Value} <- Offsets],
    Signed = case lists:member(fsinfo_signature, St#st.findings) of
                 true -> [{fsinfo, {FsInfo, 0}, <<16#41615252:32/little>>},
                          {fsinfo, {FsInfo, 16#1e4}, <<16#61417272:32/little, ?UNKNOWN:32, ?UNKNOWN:32>>},
                          {fsinfo, {FsInfo, 16#1fc}, <<16#aa550000:32/little>>}];
                 false -> []
             end,
    Steps = lists:foldl(fun({Step, {Sector, Offset}, Value}, Acc) ->
                                Acc#{Step => placed(maps:get(Step, Acc, #{}), Sector, Offset, Value)}
                        end, #{}, Cuts ++ Others ++ Signed),
    #{layout => maps:remove(read, erx_fat:layout(Fat)), edits => Steps}.

placed(Edits, Sector, Offset, Value) -> Edits#{Sector => (maps:get(Sector, Edits, #{}))#{Offset => Value}}.

%% Where Cluster's entry lies in the first FAT, as {Sector, Offset}.
fat_place(#st{type = Type, first_fat = FirstFat}, Cluster) ->
    {Index, Offset} = erx_fat_alloc:entry_place(Type, Cluster),
    {FirstFat + Index, Offset}.

%% A FAT entry's edit: entry 0 written whole, as FreeBSD's "Correct" writes it;
%% any other the value bits alone on FAT32.
fat_value(#st{type = 16}, _Cluster, Value) -> <<Value:16/little>>;
fat_value(#st{type = 32}, 0, Value) -> <<Value:32/little>>;
fat_value(#st{type = 32}, _Cluster, Value) -> {fat32, Value}.

%% The repair, if erx_fat:check/1 passes over the volume as it leaves it: every
%% edit laid over what Read reads, each copy of the FAT read as the first, and entry
%% 1 written clean (the design's "The checker"); a volume with nothing to repair as
%% it reads. The checker's sets go with its state, which nothing holds past
%% repair/2.
writable(none, Fat, Read) ->
    accepted(erx_fat:check(erx_fat:with_read(Fat, Read))),
    none;
writable(Repair = #{layout := #{type := Type, fat_start := FirstFat, fats := Fats, fat_sectors := FatSectors},
                    edits := Steps}, Fat, Read) ->
    {Entry1, Offset1} = erx_fat_alloc:entry_place(Type, 1),
    Clean = #{FirstFat + Entry1 => #{Offset1 => fat_entry_bytes(Type, mask(Type))}},
    View = lists:foldl(fun(Step, Acc) -> merged(Acc, maps:get(Step, Steps, #{})) end, #{},
                       ?EDIT_STEPS),
    Copies = {FirstFat + FatSectors, FirstFat + Fats * FatSectors, FatSectors},
    ViewRead = fun(Sector) -> view_sector(Read, merged(View, Clean), Copies, Sector) end,
    accepted(erx_fat:check(erx_fat:with_read(Fat, ViewRead))),
    Repair.

  accepted(ok) -> ok;
  accepted({read_only, Why}) -> answer({refused, {not_writable, Why}});
  accepted({error, read_failed}) -> answer({refused, {not_writable, read_failed}}).

fat_entry_bytes(16, Value) -> <<Value:16/little>>;
fat_entry_bytes(32, Value) -> <<Value:32/little>>.

merged(Edits, More) ->
    maps:fold(fun(Sector, Offsets, Acc) -> Acc#{Sector => maps:merge(maps:get(Sector, Acc, #{}), Offsets)} end,
              Edits, More).

%% Sector as the repair leaves it, a sector of a FAT copy read as the first FAT's.
view_sector(Read, View, {From, To, FatSectors}, Sector) when Sector >= From, Sector < To ->
    view_sector(Read, View, none, From - FatSectors + (Sector - From) rem FatSectors);
view_sector(Read, View, _Copies, Sector) ->
    case Read(Sector) of
        {ok, <<Bytes:?SECTOR/binary>>} -> {ok, patched(Bytes, maps:get(Sector, View, #{}))};
        Other -> Other
    end.

%% Bytes with every edit of Offsets written over them, in the order of their offsets.
patched(Bytes, Offsets) ->
    lists:foldl(fun({Offset, Value}, B) -> patched(B, Offset, Value) end, Bytes, lists:sort(maps:to_list(Offsets))).

patched(Bytes, Offset, {fat32, Value}) ->
    <<Before:Offset/binary, Old:32/little, After/binary>> = Bytes,
    <<Before/binary, ((Old band bnot mask(32)) bor Value):32/little, After/binary>>;
patched(Bytes, Offset, Value) ->
    <<Before:Offset/binary, _:(byte_size(Value))/binary, After/binary>> = Bytes,
    <<Before/binary, Value/binary, After/binary>>.

admitted({ok, Fat}) -> Fat;
admitted({error, {not_its_volume, fat12}}) -> answer({refused, fat12});
admitted({error, {not_its_volume, sector_size}}) -> answer({refused, sector_size});
admitted({error, {not_its_volume, Why}}) -> answer({fatal, {boot_sector, Why}});
admitted({error, does_not_read}) -> answer({fatal, {boot_sector, root}});
admitted({error, read_failed}) -> answer({refused, {read_failed, 0}}).

answer(Answer) -> throw({?MODULE, Answer}).

%% ---------------------------------------------------------------------------
%% The boot sector's FSInfo and the FAT's first entries
%% ---------------------------------------------------------------------------

%% FreeBSD's boot.c:206-245: a sector whose signatures are wrong is a finding, its
%% hints written unknown with them, so they are not checked; otherwise its hints.
fsinfo_signature(St, none) ->
    St;
fsinfo_signature(St, Sector) ->
    case erx_fat_alloc:fsinfo(sector(St, Sector)) of
        unsigned -> finding(St, fsinfo_signature);
        Hints -> St#st{fsinfo = Hints}
    end.

%% FreeBSD's fat.c:865-940: entries 0 and 1 of the first FAT as a clean volume holds
%% them, in the dirty form Windows writes, or anything else, which is corrected to
%% the clean form.
fat_header(St = #st{type = Type}, Media) ->
    {Sector, St1} = fat_sector(St, 0),
    <<Head:(Type div 4)/binary, _/binary>> = Sector,
    case header(Type, Media, Head) of
        clean -> St1;
        dirty -> St1#st{dirty = true};
        odd -> linked(linked(finding(St1, {fat_header, Head}), 0, header_entry(Type, Media)), 1, mask(Type))
    end.

header(16, Media, <<Media, 16#ff, 16#ff, 16#ff>>) -> clean;
header(16, Media, <<Media, 16#ff, 16#ff, 16#7f>>) -> dirty;
header(32, Media, <<Media, 16#ff, 16#ff, B3, 16#ff, 16#ff, 16#ff, B7>>)
  when B3 band 16#0f =:= 16#0f, B7 band 16#0f =:= 16#0f -> clean;
header(32, Media, <<Media, 16#ff, 16#ff, 16#0f, 16#ff, 16#ff, 16#ff, 16#07>>) -> dirty;
header(_Type, _Media, _Head) -> odd.

%% Entry 0 as FreeBSD's "Correct" writes it: the media byte, then ones.
header_entry(Type, Media) -> (mask(Type) band bnot 16#ff) bor Media.

%% ---------------------------------------------------------------------------
%% Phase 1: every FAT entry once
%% ---------------------------------------------------------------------------

%% FreeBSD's fat.c:942-1023, a sector of the first FAT at a time, each other copy's
%% sector compared as it passes. Phase 1 reads each entry before any repair can
%% write it, so it reads the sectors as the medium holds them.
fat_pass(St) -> fat_pass(St, 2).

fat_pass(St = #st{clusters = Clusters}, Cluster) when Cluster >= Clusters + 2 ->
    St;
fat_pass(St = #st{type = Type, clusters = Clusters}, Cluster) ->
    {Index, Skip} = erx_fat_alloc:entry_place(Type, Cluster),
    Next = min(Clusters + 2, Cluster + (?SECTOR - Skip) * 8 div Type),
    Bytes = (Next - Cluster) * Type div 8,
    {Sector, St1} = fat_sector(St, Index),
    <<Used:(Skip + Bytes)/binary, _/binary>> = Sector,
    <<_:Skip/binary, Entries:Bytes/binary>> = Used,
    fat_pass(entries(compared(St1, Index, Used, 1), Entries, Cluster), Next).

%% The copies after the first whose sector Index differs from Used, the part of the
%% first FAT's sector that holds the volume's entries.
compared(St = #st{fats = Fats}, _Index, _Used, Copy) when Copy >= Fats ->
    St;
compared(St = #st{copies = Copies}, Index, Used, Copy) ->
    case lists:member(Copy, Copies) of
        true ->
            compared(St, Index, Used, Copy + 1);
        false ->
            Theirs = sector(St, St#st.first_fat + Copy * St#st.fat_sectors + Index),
            Differs = binary:part(Theirs, 0, byte_size(Used)) =/= Used,
            compared(St#st{copies = case Differs of true -> [Copy | Copies]; false -> Copies end},
                     Index, Used, Copy + 1)
    end.

entries(St, <<>>, _Cluster) ->
    St;
entries(St = #st{type = Type}, Entries, Cluster) ->
    <<Raw:Type/little, Rest/binary>> = Entries,
    entries(phase1(St, Cluster, Raw band mask(Type)), Rest, Cluster + 1).

%% One entry: a free or bad cluster starts no chain; a link out of range, or to a
%% cluster something linked to before, ends the chain here; any other link marks
%% its cluster as one something links to.
phase1(St = #st{cleared = Cleared}, Cluster, Value) ->
    case kind(St, Value) of
        free ->
            mark(Cleared, Cluster),
            St#st{free = St#st.free + 1, fsinfo = next_free(St#st.fsinfo, Cluster)};
        bad ->
            mark(Cleared, Cluster),
            St;
        out_of_range ->
            linked(finding(St, {out_of_range_link, Cluster, Value}), Cluster, mask(St#st.type));
        {link, Next} ->
            case mark(Cleared, Next) of
                false -> St;
                true -> linked(finding(St, {crossed, Cluster, Next}), Cluster, mask(St#st.type))
            end;
        eof ->
            St
    end.

%% FreeBSD takes a next-free hint of 0 as the first free cluster (fat.c:957-960).
next_free({Free, 0}, Cluster) -> {Free, Cluster};
next_free(Hints, _Cluster) -> Hints.

%% ---------------------------------------------------------------------------
%% Phase 2: the directories
%% ---------------------------------------------------------------------------

directories(St, {fixed, _First, _Entries} = Root) ->
    tree(St, Root, 0);
directories(St = #st{cleared = Cleared}, Root) ->
    marked(Cleared, Root) andalso answer({fatal, root_not_chain}),
    tree(St, Root, Root).

tree(St, Root, Head) ->
    Frame = #{head => Head, name => root, kids => []},
    {St1, Kids} = directory(St, Root, [Frame]),
    descend(St1, [Frame#{kids := Kids}]).

%% The walk: the last subdirectory found in the directory atop the path walked
%% next, or the directory left when none waits. A subdirectory whose first cluster
%% a walk started at since it was found is named twice: FreeBSD asserts there
%% (fat.c:1056-1057), erXos finds that its entry starts no new chain and deletes it
%% (and forgets LOST.DIR, should the entry be one of its names).
-spec descend(#st{}, [frame()]) -> #st{}.
descend(St, []) ->
    St;
descend(St, [#{kids := []} = Done | Up]) ->
    descend(released(St, Done), Up);
descend(St = #st{cleared = Cleared}, [Frame = #{kids := [Kid = {Head, Name, Places} | Rest]} | Up]) ->
    Path = [Frame#{kids := Rest} | Up],
    Child = #{head => Head, name => Name, kid => Kid, kids => []},
    case marked(Cleared, Head) of
        true ->
            St1 = deleted(finding(St, {not_new_chain, path([Child | Path])}),
                          [{Sector, Offset} || <<Sector:32, Offset:16>> <= Places]),
            LostDir = case St1#st.lost_dir of Head -> none; Other -> Other end,
            descend(released(St1#st{lost_dir = LostDir}, Child), Path);
        false ->
            {St1, Kids} = directory(St, Head, [Child | Path]),
            descend(St1, [Child#{kids := Kids} | Path])
    end.

released(St = #st{held = Held}, #{kid := Kid}) -> St#st{held = Held - item_bytes(Kid)};
released(St, #{name := root}) -> St.

%% Directory Source, atop Path, entry by entry (FreeBSD's dir.c:543-1043): FAT16's
%% root as its fixed region, any other directory as its chain, checked first.
directory(St, {fixed, First, Entries}, Path) ->
    Sectors = [{First + I, min(?ENTRIES_PER_SECTOR, Entries - I * ?ENTRIES_PER_SECTOR)}
               || I <- lists:seq(0, (Entries - 1) div ?ENTRIES_PER_SECTOR)],
    ended(lists:foldl(fun(Sector, {S, D}) -> sector_entries(S, D, Path, Sector) end, {St, walk()}, Sectors),
          Path);
directory(St, Head, Path) ->
    {_Count, St1} = checkchain(St, Head),
    ended(cluster_entries(St1, walk(), Path, Head), Path).

%% A directory's walk: its next slot and that slot's place, {Sector, Offset}; the
%% end markers met since the last entry, as spans of one sector's slots
%% {Sector, First, Last}, and their count; whether entries behind end markers were
%% found, so the later fixes of this directory are written before those markers
%% turn deleted; and FreeBSD's long-name state: the run's checksum (none outside
%% one), the order number the next part must carry, the name so far, the places of
%% the open valid run's entries (none when no valid run is open), whether an
%% invalid one waits to be reported, and the subdirectories found. The entries of
%% an invalid run are deleted as they become invalid: every invalid run is deleted
%% in the end (dir.c:348-380).
walk() ->
    #{slot => 0, place => none, ends => [], end_spans => 0, behind => false, sum => none, lidx => 0, buf => blank(),
      run => none, invalid => false, kids => []}.

blank() -> <<0:(?LONG_NAME_BYTES * 8)>>.

%% The end of a directory: a run still open has no short entry, and is deleted.
ended({St, #{kids := Kids, run := Run, invalid := Invalid}}, Path) ->
    case Run =/= none orelse Invalid of
        true -> {deleted(finding(St, {invalid_long_at_end, path(Path)}), Run), Kids};
        false -> {St, Kids}
    end.

%% The directory's clusters from Cluster, each read before its link, the link read
%% through the view, as checkchain/2 left it.
cluster_entries(St = #st{fat = Fat}, D, Path, Cluster) ->
    {ok, Sectors} = erx_fat:cluster_sectors(Fat, Cluster),
    {St1, D1} = lists:foldl(fun(Sector, {S, Dir}) -> sector_entries(S, Dir, Path, {Sector, ?ENTRIES_PER_SECTOR}) end,
                            {St, D}, Sectors),
    {Next, St2} = entry(St1, Cluster),
    case kind(St2, Next) of
        {link, Link} -> cluster_entries(St2, D1, Path, Link);
        _End -> {St2, D1}
    end.

sector_entries(St, D, Path, {Sector, Count}) ->
    <<Entries:(Count * ?ENTRY)/binary, _/binary>> = sector(St, Sector),
    slots(St, D, Path, Entries, Sector, 0).

slots(St, D, _Path, <<>>, _Sector, _Offset) ->
    {St, D};
slots(St, D = #{slot := Slot}, Path, <<Bytes:?ENTRY/binary, Rest/binary>>, Sector, Offset) ->
    {St1, D1} = slot(St, D#{place := {Sector, Offset}}, Path, Bytes, erx_fat_entry:decode(Bytes)),
    slots(St1, D1#{slot := Slot + 1}, Path, Rest, Sector, Offset + ?ENTRY).

%% One slot. An end marker or a deleted entry ends no long-name run (dir.c:615-631);
%% any other entry after end markers is found, and every marker since the last
%% entry turns deleted, so the entries behind them are read.
slot(St, D, _Path, _Bytes, end_of_directory) ->
    {St, end_met(D)};
slot(St, D, _Path, _Bytes, deleted) ->
    {St, D};
slot(St, D = #{ends := [_ | _] = Ends}, Path, Bytes, Entry) ->
    St1 = lists:foldl(fun({Sector, First, Last}, S) ->
                              deleted(S, publication, [{Sector, Offset} || Offset <- lists:seq(First, Last, ?ENTRY)])
                      end, finding(St, {entries_after_end, path(Path)}), Ends),
    slot(St1, D#{ends := [], end_spans := 0, behind := true}, Path, Bytes, Entry);
slot(St, D, Path, _Bytes, {short, Short}) ->
    short_entry(St, D, Path, Short);
slot(St, D, _Path, Bytes, _Long) ->
    long_entry(St, D, Bytes).

%% An end marker met at the slot's place: its sector's span extended, or a span of
%% its own within ?EDITS_MAX spans. A deleted entry inside a span is deleted again.
end_met(D = #{place := {Sector, Offset}, ends := [{Sector, First, _} | Rest]}) ->
    D#{ends := [{Sector, First, Offset} | Rest]};
end_met(D = #{place := {Sector, Offset}, ends := Ends, end_spans := Spans}) ->
    Spans < ?EDITS_MAX orelse answer({refused, {bound, edits}}),
    D#{ends := [{Sector, Offset, Offset} | Ends], end_spans := Spans + 1}.

%% A long-name entry (dir.c:661-747). Its type byte and cluster field are read here,
%% not by erx_fat_entry:decode/1, which refuses both non-zero where FreeBSD checks
%% only the cluster. A new last part opens a run, ending the open one invalid; a
%% part out of sequence makes the run invalid; the entry then joins the open valid
%% run or, when an invalid one waits, is deleted.
long_entry(St, D = #{sum := Sum, lidx := Lidx, place := Place}, Bytes) ->
    <<Front:12/binary, _Type, Middle:13/binary, Cluster:16/little, Back:4/binary>> = Bytes,
    {long, Order, Last, Check, Units} = erx_fat_entry:decode(<<Front/binary, 0, Middle/binary, 0:16, Back/binary>>),
    Index = Order band ?ORDER_MASK,
    {St1, D1} = if
                    Last -> opened(invalidated(St, D), Check);
                    Check =/= Sum; Index =/= Lidx -> broken(invalidated(St, D));
                    true -> {St, D}
                end,
    {St2, D2} = joined(St1, D1, Place),
    case Index of
        0 ->
            {St3, D3} = invalidated(finding(St2, invalid_long_name), D2),
            {St3, D3#{lidx := 0}};
        _ ->
            {Buf, Fits} = copied(maps:get(buf, D2), (Index - 1) * ?UNITS_PER_ENTRY, Units),
            {St3, D3} = invalid_if(not Fits, long_name_too_long, St2, D2),
            {St4, D4} = invalid_if(Cluster =/= 0, long_cluster, St3, D3),
            {St4, D4#{lidx := Index - 1, buf := Buf}}
    end.

opened({St, D}, Check) -> {St, D#{run := [], sum := Check, buf := blank()}}.

broken({St, D}) -> {St, D#{invalid := true}}.

joined(St, D = #{run := none, invalid := true}, Place) -> {deleted(St, [Place]), D};
joined(St, D = #{run := none}, _Place) -> {St, D};
joined(St, D = #{run := Run}, Place) -> {St, D#{run := [Place | Run]}}.

invalid_if(true, Finding, St, D) -> invalidated(finding(St, Finding), D);
invalid_if(false, _Finding, St, D) -> {St, D}.

%% An open valid run becomes invalid: its entries deleted, and the invalid run waits.
invalidated(St, D = #{run := none}) -> {St, D};
invalidated(St, D = #{run := Run}) -> {deleted(St, Run), D#{run := none, invalid := true}}.

%% Units, 13 UTF-16 code units, written into the name from byte Position as FreeBSD
%% writes them: to the first 0, each as its low byte or `?`, never past the buffer's
%% end; and whether the name stayed short of that end.
copied(Buf, Position, _Units) when Position >= ?LONG_NAME_BYTES ->
    {Buf, false};
copied(Buf, Position, Units) ->
    Chars = list_to_binary(chars(Units, ?LONG_NAME_BYTES - Position)),
    <<Before:Position/binary, _:(byte_size(Chars))/binary, After/binary>> = Buf,
    {<<Before/binary, Chars/binary, After/binary>>, Position + byte_size(Chars) < ?LONG_NAME_BYTES}.

chars(_Units, 0) -> [];
chars(<<>>, _Room) -> [];
chars(<<0:16, _/binary>>, _Room) -> [];
chars(<<Low, 0, Rest/binary>>, Room) -> [Low | chars(Rest, Room - 1)];
chars(<<_Low, _High, Rest/binary>>, Room) -> [$? | chars(Rest, Room - 1)].

%% A short entry: a volume label ends a run, which is then invalid and deleted
%% (dir.c:765-776); any other entry takes the run's name when its checksum matches,
%% the run's entries then its own, and an invalid run before it is found under its
%% path and deleted (dir.c:785-818).
short_entry(St, D = #{run := Run, invalid := Invalid}, Path, Short = #{name := Short11}) ->
    Reset = D#{run := none, invalid := false},
    case erx_fat_entry:kind(Short) of
        label ->
            {deleted(found_if(Run =/= none orelse Invalid, invalid_long_label, St), Run), Reset};
        Kind ->
            Named = Run =/= none andalso maps:get(sum, D) =:= erx_fat_name:checksum(Short11),
            {Name, Sum, Own} = case Named of
                                   true -> {name_or(hd(binary:split(maps:get(buf, D), <<0>>)), Short11), none, Run};
                                   false -> {short_text(Short11), maps:get(sum, D), []}
                               end,
            St1 = found_if(Invalid orelse (Run =/= none andalso not Named), {invalid_long, path(Path, Name)}, St),
            St2 = case Named of true -> St1; false -> deleted(St1, Run) end,
            entry_named(St2, Reset#{sum := Sum}, Path, Kind, Name, Short, Own)
    end.

found_if(true, Finding, St) -> finding(St, Finding);
found_if(false, _Finding, St) -> St.

name_or(<<>>, Short11) -> short_text(Short11);
name_or(Long, _Short11) -> Long.

%% A short name as FreeBSD shows it: the base and the extension, their trailing
%% spaces dropped, the dot between them only when the extension's first byte is not a space; a
%% first byte 0x05 stands for 0xE5.
short_text(<<First, Base:7/binary, Extension:3/binary>>) ->
    Lead = case First of 16#05 -> 16#e5; _ -> First end,
    Dot = case Extension of <<$\s, _/binary>> -> <<>>; _ -> <<$.>> end,
    trimmed(<<(trimmed(<<Lead, Base/binary>>))/binary, Dot/binary, Extension/binary>>).

%% Text without its trailing spaces, byte by byte: a short name is any bytes, not UTF-8.
trimmed(<<>>) -> <<>>;
trimmed(Text) ->
    case binary:last(Text) of
        $\s -> trimmed(binary:part(Text, 0, byte_size(Text) - 1));
        _ -> Text
    end.

%% A named entry (dir.c:820-1003), at the slot's place, with the places of its long
%% name's entries, Own: a file or directory that claims clusters must start a chain
%% no one has walked, else a directory's entry is deleted and a file's emptied; then
%% a directory's own rules, or a file's size.
entry_named(St, D = #{place := Place}, Path, Kind, Name, Short = #{name := Short11, size := Size}, Own) ->
    Head = erx_fat_entry:first(Short, St#st.type),
    DotName = Short11 =:= ?DOT orelse Short11 =:= ?DOTDOT,
    Dots = Kind =:= dir andalso DotName,
    case not Dots andalso (Size =/= 0 orelse Kind =:= dir) andalso not starts_chain(St, Head) of
        _ when DotName, Kind =:= file, tl(Path) =/= [] ->
            Which = case Short11 of ?DOT -> dot; ?DOTDOT -> dotdot end,
            {deleted(finding(St, {dot_out_of_place, Which, path(Path)}), [Place | Own]), D};
        true ->
            Finding = case valid(St, Head) of
                          false -> {start_out_of_range, path(Path, Name), Head};
                          true -> {not_new_chain, path(Path, Name)}
                      end,
            St1 = finding(St, Finding),
            {case Kind of dir -> deleted(St1, [Place | Own]); file -> emptied(St1, Place) end, D};
        false when Kind =:= dir ->
            St1 = case Size of
                      0 -> St;
                      _ -> size_set(finding(St, {dir_size, path(Path, Name)}), Place, 0)
                  end,
            directory_entry(St1, D, Path, Name, Short11, Head, [Place | Own]);
        false ->
            {file_entry(St, Place, Path, Name, Head, Size), D}
    end.

%% A directory's entry, whose short entry and long name's entries lie at Places, the
%% short entry's first. A `.` or `..` outside the first two slots of a subdirectory
%% is erXos's finding, since the ownership check refuses it; the rest are FreeBSD's
%% (dir.c:898-976). A fix in place is published, unless the entry lay behind end
%% markers.
directory_entry(St, D = #{slot := Slot}, Path = [#{head := Here} | Up], Name, Short11, Head, Places = [Place | _]) ->
    Step = case maps:get(behind, D) of true -> preparation; false -> publication end,
    case Short11 of
        ?DOT when Up =/= [], Slot =/= 0 -> {deleted(finding(St, {dot_out_of_place, dot, path(Path)}), Places), D};
        ?DOT when Head =/= Here -> {first_set(finding(St, {dot_cluster, path(Path)}), Step, Place, Here), D};
        ?DOT -> {St, D};
        ?DOTDOT when Up =/= [], Slot =/= 1 -> {deleted(finding(St, {dot_out_of_place, dotdot, path(Path)}), Places), D};
        ?DOTDOT -> {dotdot(St, Step, Place, Path, Head), D};
        _ -> subdirectory(St, D, Up =:= [], Short11, Name, Head, Places)
    end.

%% A subdirectory's `..` names 0 under the root and its parent's cluster below it;
%% the root's is not read.
dotdot(St, _Step, _Place, [_Root], _Head) ->
    St;
dotdot(St, Step, Place, Path = [_Here, _Root], Head) when Head =/= 0 ->
    first_set(finding(St, {dotdot_nonzero, path(Path)}), Step, Place, 0);
dotdot(St, Step, Place, Path = [_Here, #{head := Parent}, _ | _], Head) when Head =/= Parent ->
    first_set(finding(St, {dotdot_cluster, path(Path)}), Step, Place, Parent);
dotdot(St, _Step, _Place, _Path, _Head) ->
    St.

%% FreeBSD's check_subdirectory (dir.c:475-538): the subdirectory's first sector
%% holds `.` and `..` as directories, or its entry is deleted; otherwise it waits,
%% held with its name and its entries' places. The root's LOST.DIR is noted.
subdirectory(St = #st{fat = Fat, held = Held}, D = #{kids := Kids}, AtRoot, Short11, Name, Head, Places) ->
    {ok, [First | _]} = erx_fat:cluster_sectors(Fat, Head),
    <<Dot:?ENTRY/binary, DotDot:?ENTRY/binary, _/binary>> = sector(St, First),
    Text = short_text(Short11),
    DotOk = dot_entry(Dot, ?DOT),
    DotDotOk = dot_entry(DotDot, ?DOTDOT),
    St1 = found_if(not DotDotOk, {incorrect_dotdot, Text}, found_if(not DotOk, {incorrect_dot, Text}, St)),
    case DotOk andalso DotDotOk of
        false ->
            {deleted(St1, Places), D};
        true ->
            Kid = {Head, Name, << <<Sector:32, Offset:16>> || {Sector, Offset} <- Places >>},
            Bytes = Held + item_bytes(Kid),
            Bytes =< ?HELD_BYTES_MAX orelse answer({refused, {bound, directories}}),
            LostDir = case AtRoot andalso Short11 =:= ?LOST_DIR of true -> Head; false -> St1#st.lost_dir end,
            {St1#st{held = Bytes, lost_dir = LostDir}, D#{kids := [Kid | Kids]}}
    end.

dot_entry(Bytes, Name) ->
    case erx_fat_entry:decode(Bytes) of
        {short, Short = #{name := Name}} -> erx_fat_entry:kind(Short) =:= dir;
        _ -> false
    end.

%% A file's size against its chain (FreeBSD's checksize, dir.c:385-461), its short
%% entry at Place.
file_entry(St, Place, Path, Name, Head, Size) ->
    Shown = fun() -> path(Path, Name) end,
    if
        Head =:= 0 ->
            sized(St, Place, Shown, Size, 0, Head);
        true ->
            case starts_chain(St, Head) of
                false ->
                    emptied(finding(St, {invalid_cluster, Shown(), Size, Head}), Place);
                true ->
                    {Count, St1} = checkchain(St, Head),
                    sized(St1, Place, Shown, Size, Count, Head)
            end
    end.

sized(St = #st{cluster_bytes = ClusterBytes}, Place, Path, Size, Count, Head) ->
    Physical = Count * ClusterBytes,
    if
        Physical < Size -> size_set(finding(St, {size_too_large, Path(), Size, Physical}), Place, Physical);
        Physical - Size >= ClusterBytes -> trimmed(finding(St, {too_many_clusters, Path()}), Place, Head, Size);
        true -> St
    end.

%% The chain from Head ended after the cluster that holds byte Size - 1; an empty
%% file's first cluster set to 0 instead. The tail, or the empty file's whole chain,
%% is a lost chain, which phase 3 walks, and none of it is reached. It stays out of
%% the chains that start, so no later entry takes it.
trimmed(St, Place, Head, 0) ->
    St1 = first_set(St, preparation, Place, 0),
    unreached(St1#st{tails = [Head | St1#st.tails]}, Head);
trimmed(St = #st{cluster_bytes = ClusterBytes}, _Place, Head, Size) ->
    {Last, St1} = nth(St, Head, (Size + ClusterBytes - 1) div ClusterBytes - 1),
    {Next, St2} = entry(St1, Last),
    case kind(St2, Next) of
        {link, Tail} ->
            St3 = linked(St2, Last, mask(St2#st.type)),
            unreached(St3#st{tails = [Tail | St3#st.tails]}, Tail);
        _End ->
            St2
    end.

nth(St, Cluster, 0) ->
    {Cluster, St};
nth(St, Cluster, Steps) ->
    {Next, St1} = entry(St, Cluster),
    nth(St1, Next, Steps - 1).

unreached(St = #st{reached = Reached}, Cluster) ->
    unmark(Reached, Cluster),
    {Next, St1} = entry(St, Cluster),
    case kind(St1, Next) of
        {link, Link} -> unreached(St1, Link);
        _End -> St1
    end.

%% ---------------------------------------------------------------------------
%% Chains
%% ---------------------------------------------------------------------------

%% FreeBSD's checkchain (fat.c:1030-1124): the chain from Head, which no one has
%% walked, followed to its end, each cluster kept in it reached; the count of its
%% clusters. A chain that ends at a free or bad cluster ends before it, which keeps
%% at least Head, whose own entry is neither or Head would not start a chain. No link
%% out of range is met: phase 1 ended the chain at every one.
checkchain(St = #st{cleared = Cleared}, Head) ->
    mark(Cleared, Head),
    chain(St, Head, Head, Head, 0).

chain(St = #st{reached = Reached}, Head, Previous, Cluster, Links) ->
    {Next, St1} = entry(St, Cluster),
    case kind(St1, Next) of
        {link, Link} ->
            mark(Reached, Cluster),
            chain(St1, Head, Cluster, Link, Links + 1);
        eof ->
            mark(Reached, Cluster),
            {Links + 1, St1};
        Marked ->
            {Links, linked(finding(St1, {chain_end, Head, Marked}), Previous, mask(St1#st.type))}
    end.

%% ---------------------------------------------------------------------------
%% Phase 3: lost chains, loops, the FSInfo hints
%% ---------------------------------------------------------------------------

%% FreeBSD's checklost (fat.c:1256-1305): every chain no one has walked, in cluster
%% order, a word of 64 walked clusters skipped at once; then the tails cut off files'
%% chains, in cluster order.
lost_chains(St = #st{clusters = Clusters, tails = Tails}, Cluster) when Cluster >= Clusters + 2 ->
    lists:foldl(fun(Tail, S) -> lost(S, Tail) end, St, lists:sort(Tails));
lost_chains(St = #st{cleared = Cleared}, Cluster) ->
    case word_full(Cleared, Cluster) of
        true -> lost_chains(St, Cluster + 64);
        false -> lost_chains(case marked(Cleared, Cluster) of true -> St; false -> lost(St, Cluster) end, Cluster + 1)
    end.

lost(St, Head) ->
    case checkchain(St, Head) of
        {0, St1} -> St1;
        {Count, St1} -> named(St1, Head, Count)
    end.

%% The lost chain at Head named in the root's LOST.DIR as its first cluster in
%% decimal, in the directory's first free slot, or kept, and why (the design's
%% "Lost chains"). The directory's slots and names are read at its first chain.
named(St = #st{lost_dir = none}, Head, Count) ->
    finding(St, {lost_chain, Head, Count, no_lost_dir});
named(St = #st{cluster_bytes = ClusterBytes}, Head, Count) when Count * ClusterBytes > 16#ffffffff ->
    finding(St, {lost_chain, Head, Count, too_large});
named(St = #st{lost_slots = unread}, Head, Count) ->
    named(lost_dir_read(St), Head, Count);
named(St = #st{lost_slots = Slots, names = Names}, Head, Count) ->
    case {marked(Names, Head), Slots} of
        {true, _} ->
            finding(St, {lost_chain, Head, Count, name_taken});
        {false, []} ->
            finding(St, {lost_chain, Head, Count, no_slot});
        {false, [Slot | Rest]} ->
            mark(Names, Head),
            St1 = entry_put(St#st{lost_slots = Rest}, Slot, lost_entry(St, Head, Count)),
            finding(St1, {lost_chain, Head, Count, named})
    end.

%% LOST.DIR's free slots, in order, at most ?EDITS_MAX: a deleted slot or an end
%% marker whose nearest earlier entry that is not deleted is no long-name entry, so
%% a name placed there ends no other name's run; and the clusters its entries name,
%% as the decimal names a lost chain would take. It is read through the view, its
%% chain as phase 2 walked it, so the entries behind its end markers are in view.
lost_dir_read(St = #st{lost_dir = Head, clusters = Clusters}) ->
    {St1, {_Free, _Count, Slots}} = lost_dir_cluster(St#st{names = cluster_set(Clusters)}, Head, {true, 0, []}),
    St1#st{lost_slots = lists:reverse(Slots)}.

lost_dir_cluster(St = #st{fat = Fat}, Cluster, Acc) ->
    {ok, Sectors} = erx_fat:cluster_sectors(Fat, Cluster),
    Acc1 = lists:foldl(fun(Sector, A) -> lost_dir_slots(St, sector(St, Sector), Sector, 0, A) end, Acc, Sectors),
    {Next, St1} = entry(St, Cluster),
    case kind(St1, Next) of
        {link, Link} -> lost_dir_cluster(St1, Link, Acc1);
        _End -> {St1, Acc1}
    end.

lost_dir_slots(_St, <<>>, _Sector, _Offset, Acc) ->
    Acc;
lost_dir_slots(St, <<Bytes:?ENTRY/binary, Rest/binary>>, Sector, Offset, {Free, Count, Slots}) ->
    Acc = case erx_fat_entry:decode(Bytes) of
              Empty when Empty =:= deleted; Empty =:= end_of_directory ->
                  case Free andalso Count < ?EDITS_MAX andalso not removed(St, Sector, Offset) of
                      true -> {Free, Count + 1, [{Sector, Offset} | Slots]};
                      false -> {Free, Count, Slots}
                  end;
              {short, #{name := Short11}} ->
                  named_number(St, Short11),
                  {true, Count, Slots};
              _Long ->
                  {false, Count, Slots}
          end,
    lost_dir_slots(St, Rest, Sector, Offset + ?ENTRY, Acc).

%% Whether the slot at Sector and Offset reads deleted only through a deletion of
%% `preparation`: a lost chain named there would land in `publication` over a name
%% that must be gone before `cutting`, so the slot is not free.
removed(#st{edits = Edits}, Sector, Offset) ->
    case Edits of
        #{Sector := #{Offset := {preparation, _}}} -> true;
        _ -> false
    end.

%% A short name that a lost chain's name could equal: up to seven decimal digits,
%% without a leading zero, and no extension; the cluster it names noted.
named_number(#st{names = Names, clusters = Clusters}, <<Base:8/binary, "   ">>) ->
    Digits = trimmed(Base),
    case byte_size(Digits) =< 7 andalso Digits =/= <<>> andalso [C || <<C>> <= Digits, C < $0 orelse C > $9] =:= [] of
        true ->
            Number = binary_to_integer(Digits),
            integer_to_binary(Number) =:= Digits andalso Number >= 2 andalso Number < Clusters + 2
                andalso mark(Names, Number);
        false ->
            false
    end;
named_number(_St, _Short11) ->
    false.

%% FreeBSD's entry for a lost chain (dir.c's reconnect): its first cluster in
%% decimal as the name, attributes and dates 0, the first cluster and the size set.
lost_entry(#st{cluster_bytes = ClusterBytes}, Head, Count) ->
    Name = integer_to_binary(Head),
    Padded = <<Name/binary, (binary:copy(<<$\s>>, 11 - byte_size(Name)))/binary>>,
    <<Padded/binary, 0, 0, 0, 0:16, 0:16, 0:16, (Head bsr 16):16/little, 0:16, 0:16,
      (Head band 16#ffff):16/little, (Count * ClusterBytes):32/little>>.

%% erXos's loop pass: a cluster no walk reached whose entry links on lies on a loop
%% of lost clusters, since nothing is linked to twice and every chain that starts
%% somewhere was walked; the first met is the loop's lowest. The link into it is
%% ended, and the loop is a lost chain.
lost_loops(St = #st{clusters = Clusters}, Cluster) when Cluster >= Clusters + 2 ->
    St;
lost_loops(St = #st{reached = Reached}, Cluster) ->
    case word_full(Reached, Cluster) of
        true -> lost_loops(St, Cluster + 64);
        false -> lost_loops(case marked(Reached, Cluster) of true -> St; false -> looped(St, Cluster) end, Cluster + 1)
    end.

looped(St, Cluster) ->
    {Value, St1} = entry(St, Cluster),
    case kind(St1, Value) of
        {link, Next} -> closed(St1, Cluster, Cluster, Next);
        _NoLink -> St1
    end.

%% The loop through Lowest followed from Cluster, which links to Next, to the
%% cluster that links back to Lowest. A chain that ends instead starts at Lowest.
closed(St, Lowest, Cluster, Lowest) ->
    lost(linked(finding(St, {lost_loop, Lowest}), Cluster, mask(St#st.type)), Lowest);
closed(St, Lowest, _Cluster, Next) ->
    {Value, St1} = entry(St, Next),
    case kind(St1, Value) of
        {link, Link} -> closed(St1, Lowest, Next, Link);
        _End -> lost(St1, Lowest)
    end.

%% FreeBSD's fat.c:1307-1334, over a sector whose signatures held.
fsinfo_hints(St = #st{fsinfo = none}) ->
    St;
fsinfo_hints(St = #st{fsinfo = {Hint, Next}, free = Free, clusters = Clusters}) ->
    St1 = found_if(Hint =/= ?UNKNOWN andalso Hint =/= Free, {fsinfo_free, Hint, Free}, St),
    if
        Next =:= ?UNKNOWN -> St1;
        Next >= Clusters + 2 -> finding(St1, {fsinfo_next, Next, invalid});
        Free =:= 0 -> St1;
        true ->
            {Value, St2} = entry(St1, Next),
            found_if(Value =/= 0, {fsinfo_next, Next, not_free}, St2)
    end.

copies(St = #st{copies = Copies}) ->
    lists:foldl(fun(Copy, S) -> finding(S, {fat_copy_differs, Copy}) end, St, lists:sort(Copies)).

dirty(St = #st{dirty = Dirty}) -> found_if(Dirty, dirty, St).

%% ---------------------------------------------------------------------------
%% The view, the sets and the bounds
%% ---------------------------------------------------------------------------

%% Sector Index of the volume, which the geometry erx_fat admitted places within
%% the file.
sector(#st{read = Read, edits = Edits}, Index) ->
    case {Read(Index), Edits} of
        {{ok, <<Bytes:?SECTOR/binary>>}, #{Index := Offsets}} -> patched(Bytes, #{O => V || O := {_, V} <- Offsets});
        {{ok, <<Bytes:?SECTOR/binary>>}, _} -> Bytes;
        _ -> answer({refused, {read_failed, Index}})
    end.

%% Sector Index of the first FAT as the medium holds it, through a cache of
%% ?CACHE_SECTORS sectors, emptied when full.
fat_sector(St = #st{cache = Cache}, Index) ->
    case Cache of
        #{Index := Bytes} ->
            {Bytes, St};
        _ ->
            Bytes = sector(St, St#st.first_fat + Index),
            Kept = case map_size(Cache) >= ?CACHE_SECTORS of true -> #{}; false -> Cache end,
            {Bytes, St#st{cache = Kept#{Index => Bytes}}}
    end.

%% Cluster's FAT entry in its value bits, through the view.
entry(St = #st{links = Links}, Cluster) when is_map_key(Cluster, Links) ->
    {map_get(Cluster, Links), St};
entry(St = #st{type = Type}, Cluster) ->
    {Index, Offset} = erx_fat_alloc:entry_place(Type, Cluster),
    {Bytes, St1} = fat_sector(St, Index),
    <<_:Offset/binary, Value:Type/little, _/binary>> = Bytes,
    {Value band mask(Type), St1}.

%% Cluster's entry set to Value in the view, within ?EDITS_MAX edits.
linked(St = #st{links = Links, edit_count = Count}, Cluster, Value) ->
    is_map_key(Cluster, Links) orelse map_size(Links) + Count < ?EDITS_MAX orelse answer({refused, {bound, edits}}),
    St#st{links = Links#{Cluster => Value}}.

%% Bytes written at Place, {Sector, Offset}, in Step, in the view, within
%% ?EDITS_MAX edits. Bytes written at the same place again keep the earlier step,
%% `preparation` before `publication`.
edit(St = #st{edits = Edits, edit_count = Count}, Step, {Sector, Offset}, Bytes) ->
    Offsets = maps:get(Sector, Edits, #{}),
    case Offsets of
        #{Offset := {preparation, _}} ->
            St#st{edits = Edits#{Sector := Offsets#{Offset := {preparation, Bytes}}}};
        #{Offset := _} ->
            St#st{edits = Edits#{Sector := Offsets#{Offset := {Step, Bytes}}}};
        _ ->
            Count + map_size(St#st.links) < ?EDITS_MAX orelse answer({refused, {bound, edits}}),
            St#st{edits = Edits#{Sector => Offsets#{Offset => {Step, Bytes}}}, edit_count = Count + 1}
    end.

%% A whole entry, Bytes, published at the slot at Place, every earlier edit of the
%% slot's bytes dropped.
entry_put(St = #st{edits = Edits, edit_count = Count}, Place = {Sector, Offset}, Bytes) ->
    Offsets = maps:get(Sector, Edits, #{}),
    Kept = maps:filter(fun(At, _) -> At < Offset orelse At >= Offset + ?ENTRY end, Offsets),
    Dropped = map_size(Offsets) - map_size(Kept),
    edit(St#st{edits = Edits#{Sector => Kept}, edit_count = Count - Dropped}, publication, Place, Bytes).

%% The entries at Places deleted, in `preparation` unless Step is given.
deleted(St, none) -> St;
deleted(St, Places) -> deleted(St, preparation, Places).

deleted(St, Step, Places) -> lists:foldl(fun(Place, S) -> edit(S, Step, Place, <<?DELETED>>) end, St, Places).

%% The fields of the short entry at Place: its first cluster, the high half only on
%% FAT32; its size; both 0.
first_set(St = #st{type = Type}, Step, {Sector, Offset}, Cluster) ->
    St1 = edit(St, Step, {Sector, Offset + 26}, <<(Cluster band 16#ffff):16/little>>),
    case Type of
        16 -> St1;
        32 -> edit(St1, Step, {Sector, Offset + 20}, <<(Cluster bsr 16):16/little>>)
    end.

size_set(St, {Sector, Offset}, Size) -> edit(St, preparation, {Sector, Offset + 28}, <<Size:32/little>>).

emptied(St, Place) -> size_set(first_set(St, preparation, Place, 0), Place, 0).

finding(St = #st{findings = Findings, finding_bytes = Bytes}, Finding) ->
    Total = Bytes + ?ITEM_BYTES + lists:sum([byte_size(Text) || Text <- tuple_list(Finding), is_binary(Text)]),
    Total =< ?HELD_BYTES_MAX orelse answer({refused, {bound, findings}}),
    St#st{findings = [Finding | Findings], finding_bytes = Total}.

tuple_list(Finding) when is_tuple(Finding) -> tuple_to_list(Finding);
tuple_list(_Atom) -> [].

item_bytes({_Head, Name, Places}) -> ?ITEM_BYTES + byte_size(Name) + byte_size(Places).

%% What an entry's value is, as FreeBSD reads it (dosfs.h:85-90, fat.c:286 and :325,
%% which widen only values from the bad mark up): free, a link to a cluster of the
%% data area, an end of chain, bad, or out of range.
kind(#st{type = Type, clusters = Clusters}, Value) ->
    Bad = mask(Type) - 8,
    if
        Value =:= 0 -> free;
        Value >= 2, Value < Clusters + 2 -> {link, Value};
        Value > Bad -> eof;
        Value =:= Bad -> bad;
        true -> out_of_range
    end.

valid(#st{clusters = Clusters}, Cluster) -> Cluster >= 2 andalso Cluster < Clusters + 2.

%% A cluster of the data area at which no walk has started and to which nothing links.
starts_chain(St = #st{cleared = Cleared}, Cluster) -> valid(St, Cluster) andalso not marked(Cleared, Cluster).

mask(16) -> 16#ffff;
mask(32) -> 16#0fffffff.

%% A set of one bit for each of clusters 0 to Clusters + 1, outside the heap; for
%% cleared, clusters 0 and 1 and the bits past the last cluster start in it.
cluster_set(Clusters) ->
    Set = atomics:new((Clusters + 2 + 63) div 64, [{signed, false}]),
    [mark(Set, Cluster) || Cluster <- [0, 1 | lists:seq(Clusters + 2, (Clusters + 2 + 63) div 64 * 64 - 1)]],
    Set.

%% Cluster added to Set; whether Set held it before.
mark(Set, Cluster) ->
    {Word, Bit} = bit(Cluster),
    Old = atomics:get(Set, Word),
    ok = atomics:put(Set, Word, Old bor Bit),
    Old band Bit =/= 0.

unmark(Set, Cluster) ->
    {Word, Bit} = bit(Cluster),
    ok = atomics:put(Set, Word, atomics:get(Set, Word) band bnot Bit).

marked(Set, Cluster) ->
    {Word, Bit} = bit(Cluster),
    atomics:get(Set, Word) band Bit =/= 0.

%% Whether Cluster opens a word of Set that holds all its clusters.
word_full(Set, Cluster) -> Cluster rem 64 =:= 0 andalso atomics:get(Set, Cluster div 64 + 1) =:= ?WORD_FULL.

bit(Cluster) -> {Cluster div 64 + 1, 1 bsl (Cluster rem 64)}.

%% ---------------------------------------------------------------------------
%% Paths and messages
%% ---------------------------------------------------------------------------

%% The path of the directory atop Path, or of entry Name in it, as FreeBSD's
%% fullpath (dir.c:162-187) builds it: the names from the root, each after a slash,
%% the root's empty; at most its last ?PATH_BYTES_MAX bytes, the names before them
%% shown as `...`.
path(Path) -> shown([Name || #{name := Name} <- Path], [], 0).

path(Path, Name) -> shown([Name | [Dir || #{name := Dir} <- Path]], [], 0).

shown([root | _], Acc, _Bytes) ->
    iolist_to_binary(Acc);
shown([Name | Up], Acc, Bytes) when Bytes + 1 + byte_size(Name) =< ?PATH_BYTES_MAX ->
    shown(Up, [$/, Name | Acc], Bytes + 1 + byte_size(Name));
shown(_Up, Acc, _Bytes) ->
    iolist_to_binary([<<"...">> | Acc]).

-doc """
A finding or a fatal finding as FreeBSD's `fsck_msdosfs` prints it, or as erXos
words its own; paths and names are the medium's bytes, unescaped.
""".
-spec message(finding() | fatal()) -> binary().
message(Finding) -> iolist_to_binary(text(Finding)).

text({boot_sector, Why}) -> io_lib:format("not a FAT16 or FAT32 volume erXos admits: ~s", [Why]);
text(root_not_chain) -> "Root directory doesn't start a cluster chain";
text(fsinfo_signature) -> "Invalid signature in fsinfo block";
text({fat_header, Head}) -> ["FAT starts with odd byte sequence (", [io_lib:format("~2.16.0b", [B]) || <<B>> <= Head], ")"];
text({out_of_range_link, C, V}) -> io_lib:format("Cluster ~b continues with out of range cluster number ~b", [C, V]);
text({crossed, C, N}) -> io_lib:format("Cluster ~b crossed another chain at ~b", [C, N]);
text({chain_end, H, Marked}) -> io_lib:format("Cluster chain starting at ~b ends with cluster marked ~s", [H, Marked]);
text({entries_after_end, P}) -> [P, " has entries after end of directory"];
text({invalid_long, P}) -> ["Invalid long filename entry for ", P];
text({invalid_long_at_end, P}) -> ["Invalid long filename entry at end of directory ", P];
text(invalid_long_label) -> "Invalid long filename entry for volume label";
text(invalid_long_name) -> "invalid long name";
text(long_name_too_long) -> "long filename too long";
text(long_cluster) -> "long filename record cluster start != 0";
text({start_out_of_range, P, H}) -> [P, io_lib:format(" starts with cluster out of range(~b)", [H])];
text({not_new_chain, P}) -> [P, " doesn't start a new cluster chain"];
text({dir_size, P}) -> ["Directory ", P, " has size != 0"];
text({dot_cluster, P}) -> ["`.' entry in ", P, " has incorrect start cluster"];
text({dotdot_nonzero, P}) -> ["`..' entry in ", P, " has non-zero start cluster"];
text({dotdot_cluster, P}) -> ["`..' entry in ", P, " has incorrect start cluster"];
text({dot_out_of_place, dot, P}) -> ["`.' entry in ", P, " outside the directory's first two slots"];
text({dot_out_of_place, dotdot, P}) -> ["`..' entry in ", P, " outside the directory's first two slots"];
text({incorrect_dot, N}) -> ["check_subdirectory: Incorrect `.' for ", N, "."];
text({incorrect_dotdot, N}) -> ["check_subdirectory: Incorrect `..' for ", N, ". "];
text({invalid_cluster, P, S, H}) -> ["Directory entry ", P, io_lib:format(" of size ~b referencing invalid cluster ~b", [S, H])];
text({size_too_large, P, S, M}) -> ["size of ", P, io_lib:format(" is ~b, should at most be ~b", [S, M])];
text({too_many_clusters, P}) -> [P, " has too many clusters allocated"];
text({lost_chain, H, N, Fate}) ->
    [io_lib:format("Lost cluster chain at cluster ~b, ~b Cluster(s) lost", [H, N]), kept(H, Fate)];
text({lost_loop, C}) -> io_lib:format("Cluster ~b closes a loop of lost clusters", [C]);
text({fsinfo_free, H, F}) -> io_lib:format("Free space in FSInfo block (~b) not correct (~b)", [H, F]);
text({fsinfo_next, N, Why}) ->
    io_lib:format("Next free cluster in FSInfo block (~b) ~s", [N, case Why of invalid -> "invalid"; not_free -> "not free" end]);
text({fat_copy_differs, K}) -> io_lib:format("FAT ~b differs from FAT 0", [K]);
text(dirty) -> "the volume is marked dirty".

kept(_Head, named) -> "";
kept(_Head, no_lost_dir) -> "; kept: no /LOST.DIR";
kept(_Head, no_slot) -> "; kept: /LOST.DIR has no free slot";
kept(Head, name_taken) -> io_lib:format("; kept: /LOST.DIR/~b exists", [Head]);
kept(_Head, too_large) -> "; kept: larger than 4 GiB".

%% ---------------------------------------------------------------------------
%% Writing a repair
%% ---------------------------------------------------------------------------

-doc """
Repair written to the volume that Read reads and Write writes, step by step in the
design's order ("The repair order"), each step in commits of at most
?COMMIT_SECTORS sectors: a commit reads its sectors as the medium then holds them,
writes their patched images and flushes, through erx_fat_plan:apply/3, before the
next commit reads. First `dirty` and `dirty_mirrors`, by erx_fat_alloc:dirty/1;
then `preparation`, `cutting`, `publication` and `fsinfo`; then `mirrors`, every
used sector of each copy that differs from the first FAT's written with the first
FAT's; last `clean_mirrors` and `clean`, by erx_fat_alloc:finish/2 with FreeBSD's
"Correct" value. A step with nothing to write is skipped. The caller has flushed
once before, refusing if that failed. Answers `ok`, or the first read, write or
flush that failed, after which the medium holds a cut that running the check again
repairs.
""".
-spec write(repair(), read_sector(), write_sector(), flush()) -> ok | {error, term()}.
write(none, _Read, _Write, _Flush) ->
    ok;
write(#{layout := Layout, edits := Steps}, Read, Write, Flush) ->
    Writer = #{read => Read, write => Write, flush => Flush},
    Alloc = fun() -> erx_fat_alloc:new(Layout#{read => Read}) end,
    try
        planned(erx_fat_alloc:dirty(Alloc()), Writer),
        [edited(Step, maps:get(Step, Steps, #{}), Writer) || Step <- ?EDIT_STEPS],
        mirrored(Layout, Writer),
        planned(erx_fat_alloc:finish(Alloc(), correct), Writer),
        ok
    catch throw:{?MODULE, write, Why} -> {error, Why}
    end.

write_failed(Why) -> throw({?MODULE, write, Why}).

%% A plan of erx_fat_alloc's, each step written in commits.
planned({ok, Plan}, Writer) -> [committed(Step, Images, Writer) || {Step, Images} <- Plan];
planned({ok, Plan, finished}, Writer) -> planned({ok, Plan}, Writer);
planned({error, Why}, _Writer) -> write_failed(Why).

%% Step's edits, each commit's sectors read when its turn comes and patched.
edited(Step, Edits, Writer) ->
    [committed(Step, [{Sector, patched(medium(Writer, Sector), maps:get(Sector, Edits))} || Sector <- Commit], Writer)
     || Commit <- commits(lists:sort(maps:keys(Edits)))].

%% Every used sector of each FAT copy made equal to the first FAT's, ?COMMIT_SECTORS
%% sectors of the first FAT and of one copy read at a time.
mirrored(#{type := Type, fat_start := FirstFat, fats := Fats, fat_sectors := FatSectors, clusters := Clusters},
         Writer) ->
    {Last, _} = erx_fat_alloc:entry_place(Type, Clusters + 1),
    [begin
         Firsts = [{Index, medium(Writer, FirstFat + Index)} || Index <- Commit],
         [committed(mirrors, [{Sector, Bytes} || {Index, Bytes} <- Firsts,
                                                 Sector <- [FirstFat + Copy * FatSectors + Index],
                                                 medium(Writer, Sector) =/= Bytes], Writer)
          || Copy <- lists:seq(1, Fats - 1)]
     end || Commit <- commits(lists:seq(0, Last))],
    ok.

commits([]) -> [];
commits(Sectors) when length(Sectors) =< ?COMMIT_SECTORS -> [Sectors];
commits(Sectors) ->
    {Commit, Rest} = lists:split(?COMMIT_SECTORS, Sectors),
    [Commit | commits(Rest)].

%% One commit: its images written and flushed, or nothing for an empty one.
committed(_Step, [], _Writer) ->
    ok;
committed(Step, Images, #{write := Write, flush := Flush}) ->
    case erx_fat_plan:apply([{Step, Images}], Write, Flush) of
        ok -> ok;
        {error, Why} -> write_failed(Why);
        Other -> write_failed({unexpected, Other})
    end.

medium(#{read := Read}, Sector) ->
    case Read(Sector) of
        {ok, <<Bytes:?SECTOR/binary>>} -> Bytes;
        _ -> write_failed({read_failed, Sector})
    end.
