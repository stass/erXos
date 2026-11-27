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

Names in paths are FreeBSD's: a long name's UTF-16 code units shown by their low
byte, `?` for one beyond Latin-1, or else the short name as `NAME.EXT`. They are the
medium's bytes, which the report escapes. Each answer leaves through one throw,
`{erx_fat_check, Answer}`, caught at check/2.
""".

-export([check/2, message/1]).
-export_type([result/0, finding/0, fatal/0, refusal/0]).

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
%% A word of a cluster set whose clusters are all in it.
-define(WORD_FULL, 16#ffffffffffffffff).

-type read_sector() :: fun((non_neg_integer()) -> {ok, binary()} | {error, term()}).
-type path() :: binary().
-type finding() :: fsinfo_signature
                 | {fat_header, binary()}
                 | {out_of_range_link, pos_integer(), non_neg_integer()}
                 | {crossed, pos_integer(), pos_integer()}
                 | {chain_end, pos_integer(), free | bad | reserved}
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
                 | {lost_chain, pos_integer(), pos_integer()}
                 | {lost_loop, pos_integer()}
                 | {fsinfo_free, non_neg_integer(), non_neg_integer()}
                 | {fsinfo_next, non_neg_integer(), invalid | not_free}
                 | {fat_copy_differs, pos_integer()}
                 | dirty.
-type fatal() :: {boot_sector, erx_fat:refusal()} | root_not_chain.
-type refusal() :: fat12 | sector_size | not_mirrored | {bound, clusters | directories | edits | findings}
                 | {read_failed, non_neg_integer()}.
-type result() :: {ok, [finding()]} | {fatal, fatal()} | {refused, refusal()}.

%% The check's state. links is the view: the FAT entries the repair writes, by
%% cluster, in their value bits. cleared is FreeBSD's head map inverted: a cluster is
%% in it once it is free or bad, something links to it or a walk started at it, so a
%% cluster not in it starts a chain no one has walked; reached holds every cluster a
%% walk kept in its chain. held counts the directories' bytes, findings' bytes theirs.
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
             findings = [] :: [finding()],
             finding_bytes = 0 :: non_neg_integer(),
             held = 0 :: non_neg_integer(),
             free = 0 :: non_neg_integer(),
             fsinfo = none :: none | {non_neg_integer(), non_neg_integer()},
             copies = [] :: [pos_integer()],
             dirty = false :: boolean()}).

%% A directory on the walk's path: its first cluster (0 for FAT16's root), its name
%% (root for the root) and the subdirectories found in it and not yet walked, the
%% last found first, each {FirstCluster, Name}.
-type frame() :: #{head := non_neg_integer(), name := binary() | root, kids := [{pos_integer(), binary()}]}.

-doc """
The findings on the volume Read reads, of Sectors sectors, in FreeBSD's order (see
the module's doc); `{fatal, Finding}` for a boot sector the checker cannot take or a
FAT32 root that starts no chain; `{refused, Reason}` for a volume it does not
check or one that would pass a bound, and for a sector that does not read.
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
    #st{findings = Findings} = lists:foldl(fun(Phase, S) -> Phase(S) end, St, Phases),
    {ok, lists:reverse(Findings)}.

admitted({ok, Fat}) -> Fat;
admitted({error, {not_its_volume, fat12}}) -> answer({refused, fat12});
admitted({error, {not_its_volume, sector_size}}) -> answer({refused, sector_size});
admitted({error, {not_its_volume, Why}}) -> answer({fatal, {boot_sector, Why}});
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
        _EndOrReserved ->
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
%% (fat.c:1056-1057), erXos finds that its entry starts no new chain.
-spec descend(#st{}, [frame()]) -> #st{}.
descend(St, []) ->
    St;
descend(St, [#{kids := []} = Done | Up]) ->
    descend(released(St, Done), Up);
descend(St = #st{cleared = Cleared}, [Frame = #{kids := [{Head, Name} | Rest]} | Up]) ->
    Path = [Frame#{kids := Rest} | Up],
    Child = #{head => Head, name => Name, kids => []},
    case marked(Cleared, Head) of
        true ->
            descend(released(finding(St, {not_new_chain, path([Child | Path])}), Child), Path);
        false ->
            {St1, Kids} = directory(St, Head, [Child | Path]),
            descend(St1, [Child#{kids := Kids} | Path])
    end.

released(St = #st{held = Held}, #{name := Name}) when is_binary(Name) -> St#st{held = Held - item_bytes(Name)};
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

%% A directory's walk: its next slot, whether an end marker was met, and FreeBSD's
%% long-name state: the run's checksum (none outside one), the order number the next
%% part must carry, the name so far, whether a valid run is open and whether an
%% invalid one waits to be reported.
walk() ->
    #{slot => 0, empty => false, sum => none, lidx => 0, buf => blank(), valid => false, invalid => false,
      kids => []}.

blank() -> <<0:(?LONG_NAME_BYTES * 8)>>.

%% The end of a directory: a run still open has no short entry.
ended({St, D = #{kids := Kids}}, Path) ->
    case maps:get(valid, D) orelse maps:get(invalid, D) of
        true -> {finding(St, {invalid_long_at_end, path(Path)}), Kids};
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
    slots(St, D, Path, Entries).

slots(St, D, _Path, <<>>) ->
    {St, D};
slots(St, D = #{slot := Slot}, Path, <<Bytes:?ENTRY/binary, Rest/binary>>) ->
    {St1, D1} = slot(St, D, Path, Bytes, erx_fat_entry:decode(Bytes)),
    slots(St1, D1#{slot := Slot + 1}, Path, Rest).

%% One slot. An end marker or a deleted entry ends no long-name run (dir.c:615-631);
%% any other entry after an end marker is found, and the marker is read past.
slot(St, D, _Path, _Bytes, end_of_directory) ->
    {St, D#{empty := true}};
slot(St, D, _Path, _Bytes, deleted) ->
    {St, D};
slot(St, D = #{empty := true}, Path, Bytes, Entry) ->
    slot(finding(St, {entries_after_end, path(Path)}), D#{empty := false}, Path, Bytes, Entry);
slot(St, D, Path, _Bytes, {short, Short}) ->
    short_entry(St, D, Path, Short);
slot(St, D, _Path, Bytes, _Long) ->
    long_entry(St, D, Bytes).

%% A long-name entry (dir.c:661-747). Its type byte and cluster field are read here,
%% not by erx_fat_entry:decode/1, which refuses both non-zero where FreeBSD checks
%% only the cluster.
long_entry(St, D = #{sum := Sum, lidx := Lidx, valid := Valid, invalid := Invalid}, Bytes) ->
    <<Front:12/binary, _Type, Middle:13/binary, Cluster:16/little, Back:4/binary>> = Bytes,
    {long, Order, Last, Check, Units} = erx_fat_entry:decode(<<Front/binary, 0, Middle/binary, 0:16, Back/binary>>),
    Index = Order band ?ORDER_MASK,
    D1 = if
             Last -> D#{invalid := Invalid orelse (Valid andalso Sum =/= none), valid := true, sum := Check,
                        buf := blank()};
             Check =/= Sum; Index =/= Lidx -> D#{invalid := true, valid := false};
             true -> D
         end,
    case Index of
        0 ->
            {finding(St, invalid_long_name), invalidated(D1#{lidx := 0})};
        _ ->
            {Buf, Fits} = copied(maps:get(buf, D1), (Index - 1) * ?UNITS_PER_ENTRY, Units),
            {St1, D2} = invalid_if(not Fits, long_name_too_long, St, D1),
            {St2, D3} = invalid_if(Cluster =/= 0, long_cluster, St1, D2),
            {St2, D3#{lidx := Index - 1, buf := Buf}}
    end.

invalid_if(true, Finding, St, D) -> {finding(St, Finding), invalidated(D)};
invalid_if(false, _Finding, St, D) -> {St, D}.

%% An open valid run becomes the invalid one that waits.
invalidated(D = #{valid := Valid, invalid := Invalid}) -> D#{invalid := Invalid orelse Valid, valid := false}.

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

%% A short entry: a volume label ends a run that is then invalid (dir.c:765-776);
%% any other entry takes the run's name when its checksum matches, and an invalid
%% run before it is found under its path (dir.c:785-818).
short_entry(St, D = #{valid := Valid, invalid := Invalid}, Path, Short = #{name := Short11}) ->
    case erx_fat_entry:kind(Short) of
        label ->
            {found_if(Valid orelse Invalid, invalid_long_label, St), D#{valid := false, invalid := false}};
        Kind ->
            Named = Valid andalso maps:get(sum, D) =:= erx_fat_name:checksum(Short11),
            Name = case Named of
                       true -> name_or(hd(binary:split(maps:get(buf, D), <<0>>)), Short11);
                       false -> short_text(Short11)
                   end,
            Sum = case Named of true -> none; false -> maps:get(sum, D) end,
            St1 = found_if(Invalid orelse (Valid andalso not Named), {invalid_long, path(Path, Name)}, St),
            entry_named(St1, D#{valid := false, invalid := false, sum := Sum}, Path, Kind, Name, Short)
    end.

found_if(true, Finding, St) -> finding(St, Finding);
found_if(false, _Finding, St) -> St.

name_or(<<>>, Short11) -> short_text(Short11);
name_or(Long, _Short11) -> Long.

%% A short name as FreeBSD shows it: the base and the extension, their trailing
%% spaces dropped, joined by a dot when the extension's first byte is not a space; a
%% first byte 0x05 stands for 0xE5.
short_text(<<First, Base:7/binary, Extension:3/binary>>) ->
    Lead = case First of 16#05 -> 16#e5; _ -> First end,
    Name = trimmed(<<Lead, Base/binary>>),
    case Extension of
        <<$\s, _/binary>> -> Name;
        _ -> <<Name/binary, $., (trimmed(Extension))/binary>>
    end.

trimmed(Text) -> string:trim(Text, trailing, " ").

%% A named entry (dir.c:820-1003): a file or directory that claims clusters must
%% start a chain no one has walked, then a directory's own rules, or a file's size.
entry_named(St, D, Path, Kind, Name, Short = #{name := Short11, size := Size}) ->
    Head = erx_fat_entry:first(Short, St#st.type),
    Dots = Kind =:= dir andalso (Short11 =:= ?DOT orelse Short11 =:= ?DOTDOT),
    case not Dots andalso (Size =/= 0 orelse Kind =:= dir) andalso not starts_chain(St, Head) of
        true ->
            Finding = case valid(St, Head) of
                          false -> {start_out_of_range, path(Path, Name), Head};
                          true -> {not_new_chain, path(Path, Name)}
                      end,
            {finding(St, Finding), D};
        false when Kind =:= dir ->
            directory_entry(found_if(Size =/= 0, {dir_size, path(Path, Name)}, St), D, Path, Name, Short11, Head);
        false ->
            {file_entry(St, Path, Name, Head, Size), D}
    end.

%% A directory's entry. A `.` or `..` outside the first two slots of a subdirectory
%% is erXos's finding, since the ownership check refuses it; the rest are FreeBSD's
%% (dir.c:898-976).
directory_entry(St, D = #{slot := Slot}, Path = [#{head := Here} | Up], Name, Short11, Head) ->
    case Short11 of
        ?DOT when Up =/= [], Slot =/= 0 -> {finding(St, {dot_out_of_place, dot, path(Path)}), D};
        ?DOT -> {found_if(Head =/= Here, {dot_cluster, path(Path)}, St), D};
        ?DOTDOT when Up =/= [], Slot =/= 1 -> {finding(St, {dot_out_of_place, dotdot, path(Path)}), D};
        ?DOTDOT -> {dotdot(St, Path, Head), D};
        _ -> subdirectory(St, D, Short11, Name, Head)
    end.

%% A subdirectory's `..` names 0 under the root and its parent's cluster below it;
%% the root's is not read.
dotdot(St, [_Root], _Head) ->
    St;
dotdot(St, Path = [_Here, _Root], Head) ->
    found_if(Head =/= 0, {dotdot_nonzero, path(Path)}, St);
dotdot(St, Path = [_Here, #{head := Parent} | _], Head) ->
    found_if(Head =/= Parent, {dotdot_cluster, path(Path)}, St).

%% FreeBSD's check_subdirectory (dir.c:475-538): the subdirectory's first sector
%% holds `.` and `..` as directories, or it is not walked; otherwise it waits.
subdirectory(St = #st{fat = Fat, held = Held}, D = #{kids := Kids}, Short11, Name, Head) ->
    {ok, [First | _]} = erx_fat:cluster_sectors(Fat, Head),
    <<Dot:?ENTRY/binary, DotDot:?ENTRY/binary, _/binary>> = sector(St, First),
    Text = short_text(Short11),
    DotOk = dot_entry(Dot, ?DOT),
    DotDotOk = dot_entry(DotDot, ?DOTDOT),
    St1 = found_if(not DotDotOk, {incorrect_dotdot, Text}, found_if(not DotOk, {incorrect_dot, Text}, St)),
    case DotOk andalso DotDotOk of
        false ->
            {St1, D};
        true ->
            Bytes = Held + item_bytes(Name),
            Bytes =< ?HELD_BYTES_MAX orelse answer({refused, {bound, directories}}),
            {St1#st{held = Bytes}, D#{kids := [{Head, Name} | Kids]}}
    end.

dot_entry(Bytes, Name) ->
    case erx_fat_entry:decode(Bytes) of
        {short, Short = #{name := Name}} -> erx_fat_entry:kind(Short) =:= dir;
        _ -> false
    end.

%% A file's size against its chain (FreeBSD's checksize, dir.c:385-461).
file_entry(St, Path, Name, Head, Size) ->
    Shown = fun() -> path(Path, Name) end,
    if
        Head =:= 0 ->
            sized(St, Shown, Size, 0, Head);
        true ->
            case starts_chain(St, Head) of
                false ->
                    finding(St, {invalid_cluster, Shown(), Size, Head});
                true ->
                    {Count, St1} = checkchain(St, Head),
                    sized(St1, Shown, Size, Count, Head)
            end
    end.

sized(St = #st{cluster_bytes = ClusterBytes}, Path, Size, Count, Head) ->
    Physical = Count * ClusterBytes,
    if
        Physical < Size -> finding(St, {size_too_large, Path(), Size, Physical});
        Physical - Size >= ClusterBytes -> trimmed(finding(St, {too_many_clusters, Path()}), Head, Size);
        true -> St
    end.

%% The chain from Head ended after the cluster that holds byte Size - 1, or after
%% Head for an empty file; the tail is a lost chain, so it starts a chain no one
%% has walked and none of it is reached.
trimmed(St = #st{cluster_bytes = ClusterBytes}, Head, Size) ->
    {Last, St1} = nth(St, Head, max(1, (Size + ClusterBytes - 1) div ClusterBytes) - 1),
    {Next, St2} = entry(St1, Last),
    case kind(St2, Next) of
        {link, Tail} ->
            St3 = linked(St2, Last, mask(St2#st.type)),
            unmark(St3#st.cleared, Tail),
            unreached(St3, Tail);
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
%% clusters. A chain that ends at a free, bad or reserved cluster ends before it; a
%% chain whose first entry is reserved keeps no cluster, and its entry is left as it
%% reads. No link out of range is met: phase 1 ended the chain at every one.
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
        Marked when Links =:= 0 ->
            {0, finding(St1, {chain_end, Head, Marked})};
        Marked ->
            {Links, linked(finding(St1, {chain_end, Head, Marked}), Previous, mask(St1#st.type))}
    end.

%% ---------------------------------------------------------------------------
%% Phase 3: lost chains, loops, the FSInfo hints
%% ---------------------------------------------------------------------------

%% FreeBSD's checklost (fat.c:1256-1305): every chain no one has walked, in cluster
%% order, a word of 64 walked clusters skipped at once.
lost_chains(St = #st{clusters = Clusters}, Cluster) when Cluster >= Clusters + 2 ->
    St;
lost_chains(St = #st{cleared = Cleared}, Cluster) ->
    case word_full(Cleared, Cluster) of
        true -> lost_chains(St, Cluster + 64);
        false -> lost_chains(case marked(Cleared, Cluster) of true -> St; false -> lost(St, Cluster) end, Cluster + 1)
    end.

lost(St, Head) ->
    case checkchain(St, Head) of
        {0, St1} -> St1;
        {Count, St1} -> finding(St1, {lost_chain, Head, Count})
    end.

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
sector(#st{read = Read}, Index) ->
    case Read(Index) of
        {ok, <<Bytes:?SECTOR/binary>>} -> Bytes;
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

%% Cluster's entry set to Value in the view, within ?EDITS_MAX entries.
linked(St = #st{links = Links}, Cluster, Value) ->
    is_map_key(Cluster, Links) orelse map_size(Links) < ?EDITS_MAX orelse answer({refused, {bound, edits}}),
    St#st{links = Links#{Cluster => Value}}.

finding(St = #st{findings = Findings, finding_bytes = Bytes}, Finding) ->
    Total = Bytes + ?ITEM_BYTES + lists:sum([byte_size(Text) || Text <- tuple_list(Finding), is_binary(Text)]),
    Total =< ?HELD_BYTES_MAX orelse answer({refused, {bound, findings}}),
    St#st{findings = [Finding | Findings], finding_bytes = Total}.

tuple_list(Finding) when is_tuple(Finding) -> tuple_to_list(Finding);
tuple_list(_Atom) -> [].

item_bytes(Name) -> ?ITEM_BYTES + byte_size(Name).

%% What an entry's value is, as FreeBSD reads it (dosfs.h:85-90): free, a link to a
%% cluster of the data area, an end of chain, bad, reserved, or out of range.
kind(#st{type = Type, clusters = Clusters}, Value) ->
    Reserved = mask(Type) - 9,
    if
        Value =:= 0 -> free;
        Value >= 2, Value < Clusters + 2 -> {link, Value};
        Value >= Reserved + 2 -> eof;
        Value =:= Reserved + 1 -> bad;
        Value =:= Reserved -> reserved;
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
text({lost_chain, H, N}) -> io_lib:format("Lost cluster chain at cluster ~b, ~b Cluster(s) lost", [H, N]);
text({lost_loop, C}) -> io_lib:format("Cluster ~b closes a loop of lost clusters", [C]);
text({fsinfo_free, H, F}) -> io_lib:format("Free space in FSInfo block (~b) not correct (~b)", [H, F]);
text({fsinfo_next, N, Why}) ->
    io_lib:format("Next free cluster in FSInfo block (~b) ~s", [N, case Why of invalid -> "invalid"; not_free -> "not free" end]);
text({fat_copy_differs, K}) -> io_lib:format("FAT ~b differs from FAT 0", [K]);
text(dirty) -> "the volume is marked dirty".
