%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The generator of FAT volumes for the checker's tests (docs/design-fsck-fat.md,
%% "Damaged images"): volume/2,3 lays a tree out on a fresh FAT16 or FAT32 volume,
%% clusters handed out in order from the root's, each directory's entries packed
%% from its first slot; the damage helpers then change the bytes a case names (a FAT
%% entry, an entry's field, a run's order number). A volume is held in memory as its
%% non-zero sectors by index, so a volume of millions of clusters costs only what
%% it writes, and is never written to disk. A clean volume passes erx_fat:check/1.
%%
%% A tree is a list of {file, Name, Size} and {dir, Name, Tree}; a Name is a short
%% name's text, `NAME.EXT`, or {long, Text, ShortText}, a long name over its short
%% one. paths/1 names where each lies: its first cluster and its short entry's sector
%% and byte offset, by path from the root (<<"/A/B">>).

-module(erx_fat_damage).

-export([volume/2, volume/3, read/1, sectors/1, first/2, entry_at/2, chain/2, layout/1]).
-export([fat/3, fat_copy/4, poke/4, entry/3, size/3, start/3, entry_bytes/2]).

-define(SECTOR, 512).
-define(ENTRY, 32).
-define(ZERO, <<0:(?SECTOR * 8)>>).
-define(FAT16_CLUSTERS, 4200).
-define(FAT32_CLUSTERS, 65600).
-define(EPOCH_2026, 1767225600).

%% A volume: its type, its count of sectors, its non-zero sectors, where its regions
%% lie and where each path's entry lies.
-type volume() :: #{type := 16 | 32, sectors := pos_integer(), data := #{non_neg_integer() => binary()},
                    layout := map(), paths := map()}.

volume(Type, Tree) -> volume(Type, Tree, #{}).

%% Options: clusters, the volume's count of clusters; root_entries, FAT16's root
%% region's slots.
-spec volume(16 | 32, list(), map()) -> volume().
volume(Type, Tree, Options) ->
    Clusters = maps:get(clusters, Options, case Type of 16 -> ?FAT16_CLUSTERS; 32 -> ?FAT32_CLUSTERS end),
    RootEntries = case Type of 16 -> maps:get(root_entries, Options, 512); 32 -> 0 end,
    Reserved = case Type of 16 -> 1; 32 -> 32 end,
    FatSectors = ((Clusters + 2) * (Type div 8) + ?SECTOR - 1) div ?SECTOR,
    RootSector = Reserved + 2 * FatSectors,
    DataStart = RootSector + RootEntries * ?ENTRY div ?SECTOR,
    Layout = #{type => Type, first_fat => Reserved, fats => 2, fat_sectors => FatSectors, data_start => DataStart,
               root_sector => RootSector, root_entries => RootEntries, clusters => Clusters},
    Empty = #{type => Type, sectors => DataStart + Clusters, data => #{}, layout => Layout, paths => #{},
              next => 2, fat => #{}},
    Built = case Type of
                16 -> root16(Empty, Tree);
                32 -> root32(Empty, Tree)
            end,
    Free = Clusters - (maps:get(next, Built) - 2),
    Done = fats(boot(Built, Free)),
    maps:without([next, fat], Done).

%% FAT16's root: its fixed region holds the tree's entries.
root16(V = #{layout := #{root_sector := First}}, Tree) ->
    {Entries, V1} = children(V, Tree, 0, <<>>),
    place(V1, [First + I || I <- lists:seq(0, (length(Entries) * ?ENTRY + ?SECTOR - 1) div ?SECTOR - 1)],
          Entries, <<>>).

%% FAT32's root: a chain from the first cluster, as a subdirectory's but with no dot entries.
root32(V, Tree) ->
    Count = clusters_for(V, entries_count(Tree)),
    {Chain, V1} = allocated(V, Count),
    {Entries, V2} = children(V1, Tree, 0, <<>>),
    place(V2, chain_sectors(V2, Chain), Entries, <<>>).

%% The entries of Tree in a directory whose children's `..` names Parent, at Path.
children(V, Tree, Parent, Path) ->
    {Reversed, Built} = lists:foldl(fun(Node, {Acc, VAcc}) ->
                                            {Entries, VNext} = child(VAcc, Node, Parent, Path),
                                            {lists:reverse(Entries, Acc), VNext}
                                    end, {[], V}, Tree),
    {lists:reverse(Reversed), Built}.

child(V, {file, Name, Size}, _Parent, Path) ->
    {Long, Short} = names(Name),
    {Chain, V1} = allocated(V, (Size + cluster_bytes(V) - 1) div cluster_bytes(V)),
    First = case Chain of [] -> 0; [C | _] -> C end,
    Entry = erx_fat_entry:encode(erx_fat_entry:with_size(erx_fat_entry:new(Short, 0, file, First, ?EPOCH_2026), Size)),
    {Long ++ [{entry, path(Path, Name), First, Entry}], V1};
child(V, {dir, Name, Tree}, Parent, Path) ->
    {Long, Short} = names(Name),
    {Chain = [First | _], V1} = allocated(V, clusters_for(V, 2 + entries_count(Tree))),
    Here = path(Path, Name),
    Dots = [erx_fat_entry:encode(erx_fat_entry:new(<<".          ">>, 0, dir, First, ?EPOCH_2026)),
            erx_fat_entry:encode(erx_fat_entry:new(<<"..         ">>, 0, dir, Parent, ?EPOCH_2026))],
    {Entries, V2} = children(V1, Tree, First, Here),
    V3 = place(V2, chain_sectors(V2, Chain), Dots ++ Entries, Here),
    {Long ++ [{entry, Here, First, erx_fat_entry:encode(erx_fat_entry:new(Short, 0, dir, First, ?EPOCH_2026))}], V3}.

entries_count(Tree) -> lists:sum([length(element(1, names(element(2, Node)))) + 1 || Node <- Tree]).

names({long, Text, ShortText}) ->
    Short = short(ShortText),
    {erx_fat_name:long_entries(unicode:characters_to_binary(Text, utf8, {utf16, little}), Short), Short};
names(Text) ->
    {[], short(Text)}.

short(Text) ->
    {Base, Extension} = case binary:split(Text, <<".">>) of [B, E] -> {B, E}; [B] -> {B, <<>>} end,
    <<(pad(Base, 8))/binary, (pad(Extension, 3))/binary>>.

pad(Text, Size) -> <<Text/binary, (binary:copy(<<" ">>, Size - byte_size(Text)))/binary>>.

path(Path, {long, Text, _Short}) -> <<Path/binary, "/", Text/binary>>;
path(Path, Text) -> <<Path/binary, "/", Text/binary>>.

%% Entries placed in Sectors, in order; each named entry's place recorded.
place(V, Sectors, Entries, _Dir) ->
    Slots = lists:zip(lists:seq(0, length(Entries) - 1), Entries),
    lists:foldl(fun({Slot, Entry}, VAcc) ->
                        Sector = lists:nth(Slot div (?SECTOR div ?ENTRY) + 1, Sectors),
                        Offset = Slot rem (?SECTOR div ?ENTRY) * ?ENTRY,
                        placed(VAcc, Sector, Offset, Entry)
                end, V, Slots).

placed(V, Sector, Offset, {entry, Path, First, Bytes}) ->
    Paths = maps:get(paths, V),
    poke(V#{paths := Paths#{Path => #{first => First, at => {Sector, Offset}}}}, Sector, Offset, Bytes);
placed(V, Sector, Offset, Bytes) ->
    poke(V, Sector, Offset, Bytes).

%% Count clusters handed out in order, linked into one chain.
allocated(V, 0) ->
    {[], V};
allocated(V = #{next := Next, fat := Fat, layout := #{clusters := Clusters}}, Count) ->
    Next + Count =< Clusters + 2 orelse error(volume_full),
    Chain = lists:seq(Next, Next + Count - 1),
    Links = maps:from_list(lists:zip(Chain, tl(Chain) ++ [eof])),
    {Chain, V#{next := Next + Count, fat := maps:merge(Fat, Links)}}.

clusters_for(V, Entries) -> max(1, (Entries * ?ENTRY + cluster_bytes(V) - 1) div cluster_bytes(V)).

cluster_bytes(_V) -> ?SECTOR.

chain_sectors(#{layout := #{data_start := DataStart}}, Chain) -> [DataStart + C - 2 || C <- Chain].

%% The boot sector, and FAT32's FSInfo sector with its hints exact.
boot(V = #{type := 16, sectors := Sectors, layout := #{fat_sectors := FatSectors, root_entries := RootEntries}}, _Free) ->
    Common = common(1, RootEntries, Sectors, FatSectors, 16),
    Boot = <<Common/binary, 16#80, 0, 16#29, 16#12345678:32/little, "ERXOS TEST ", "FAT16   ">>,
    poke(V, 0, 0, signed(Boot));
boot(V = #{type := 32, sectors := Sectors, layout := #{fat_sectors := FatSectors}, next := Next}, Free) ->
    Common = common(32, 0, Sectors, FatSectors, 32),
    Boot = <<Common/binary, FatSectors:32/little, 0:16, 0:16, 2:32/little, 1:16/little, 6:16/little, 0:96,
             16#80, 0, 16#29, 16#12345678:32/little, "ERXOS TEST ", "FAT32   ">>,
    Info = <<"RRaA", 0:(480 * 8), "rrAa", Free:32/little, Next:32/little, 0:96, 0, 0, 16#55, 16#aa>>,
    poke(poke(V, 0, 0, signed(Boot)), 1, 0, Info).

%% The BIOS parameter block to the 32-bit sector count: 512-byte sectors, one sector
%% a cluster, two FATs, media 0xF8.
common(Reserved, RootEntries, Sectors, FatSectors, Type) ->
    {Total16, Total32} = case Sectors < 16#10000 andalso Type =:= 16 of
                             true -> {Sectors, 0};
                             false -> {0, Sectors}
                         end,
    Fat16 = case Type of 16 -> FatSectors; 32 -> 0 end,
    <<16#eb, 16#3c, 16#90, "ERXOS   ", ?SECTOR:16/little, 1, Reserved:16/little, 2, RootEntries:16/little,
      Total16:16/little, 16#f8, Fat16:16/little, 32:16/little, 64:16/little, 0:32, Total32:32/little>>.

signed(Boot) -> <<Boot/binary, 0:((510 - byte_size(Boot)) * 8), 16#55, 16#aa>>.

%% Both FATs from the volume's chains, entries 0 and 1 in the clean form.
fats(V = #{type := Type, fat := Fat}) ->
    Eof = case Type of 16 -> 16#ffff; 32 -> 16#0fffffff end,
    Entries = Fat#{0 => (Eof band bnot 16#ff) bor 16#f8, 1 => Eof},
    maps:fold(fun(Cluster, Value, VAcc) -> fat(VAcc, Cluster, case Value of eof -> Eof; _ -> Value end) end,
              V, Entries).

%% ---------------------------------------------------------------------------
%% Reading and damage
%% ---------------------------------------------------------------------------

%% The function that reads the volume's sectors; a sector past its end does not read.
read(#{sectors := Sectors, data := Data}) ->
    fun(Index) when Index >= 0, Index < Sectors -> {ok, maps:get(Index, Data, ?ZERO)};
       (_Index) -> {error, eio}
    end.

sectors(#{sectors := Sectors}) -> Sectors.

layout(#{layout := Layout}) -> Layout.

first(#{paths := Paths}, Path) -> maps:get(first, maps:get(Path, Paths)).

entry_at(#{paths := Paths}, Path) -> maps:get(at, maps:get(Path, Paths)).

%% The chain from Cluster, as the first FAT links it.
chain(V, Cluster) ->
    case fat_value(V, Cluster) of
        Next when Next >= 2, Next < 16#fff0 -> [Cluster | chain(V, Next)];
        _ -> [Cluster]
    end.

fat_value(V = #{type := Type, layout := #{first_fat := FirstFat}}, Cluster) ->
    Offset = Cluster * (Type div 8),
    <<_:(Offset rem ?SECTOR)/binary, Value:Type/little, _/binary>> = sector(V, FirstFat + Offset div ?SECTOR),
    Value.

%% Cluster's entry set to Value in every FAT, or in copy Copy only.
fat(V = #{layout := #{fats := Fats}}, Cluster, Value) ->
    lists:foldl(fun(Copy, VAcc) -> fat_copy(VAcc, Copy, Cluster, Value) end, V, lists:seq(0, Fats - 1)).

fat_copy(V = #{type := Type, layout := #{first_fat := FirstFat, fat_sectors := FatSectors}}, Copy, Cluster, Value) ->
    Offset = Cluster * (Type div 8),
    poke(V, FirstFat + Copy * FatSectors + Offset div ?SECTOR, Offset rem ?SECTOR, <<Value:Type/little>>).

%% Bytes written at Offset of sector Sector.
poke(V = #{data := Data}, Sector, Offset, Bytes) ->
    Old = maps:get(Sector, Data, ?ZERO),
    <<Before:Offset/binary, _:(byte_size(Bytes))/binary, After/binary>> = Old,
    V#{data := Data#{Sector => <<Before/binary, Bytes/binary, After/binary>>}}.

sector(#{data := Data}, Sector) -> maps:get(Sector, Data, ?ZERO).

%% The 32 bytes of Path's short entry, and the entry replaced by Bytes.
entry_bytes(V, Path) ->
    {Sector, Offset} = entry_at(V, Path),
    binary:part(sector(V, Sector), Offset, ?ENTRY).

entry(V, Path, Bytes) ->
    {Sector, Offset} = entry_at(V, Path),
    poke(V, Sector, Offset, Bytes).

%% Path's short entry with its size or first cluster changed.
size(V, Path, Size) -> entry(V, Path, short_with(V, Path, fun(S) -> erx_fat_entry:with_size(S, Size) end)).

start(V, Path, First) -> entry(V, Path, short_with(V, Path, fun(S) -> erx_fat_entry:with_first(S, First) end)).

short_with(V, Path, Change) ->
    {short, Short} = erx_fat_entry:decode(entry_bytes(V, Path)),
    erx_fat_entry:encode(Change(Short)).
