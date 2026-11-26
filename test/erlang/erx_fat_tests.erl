%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The FAT server's read path, erx_fat (docs/design-storage.md, "Removable media:
%% FAT"), over the volumes test/host/erx_fat_test.rb has fsimg write into
%% ERX_FAT_IMAGES: fat16.img and fat32.img, each of the tree beside them in tree/,
%% and over copies of them a crafted medium would hold.

-module(erx_fat_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).
-define(LONG, <<"Long File Name.dat">>).

dir() -> os:getenv("ERX_FAT_IMAGES").

image(Name) ->
    {ok, Image} = file:read_file(filename:join(dir(), Name)),
    Image.

expected(Path) ->
    {ok, Bytes} = file:read_file(filename:join([dir(), "tree" | Path])),
    Bytes.

%% A sector of the image, as the volume's placement answers it; one past the image
%% fails, as the window refuses one past the volume.
reader(Image) ->
    fun(Sector) when (Sector + 1) * ?SECTOR =< byte_size(Image) -> {ok, binary:part(Image, Sector * ?SECTOR, ?SECTOR)};
       (_Sector) -> {error, outside}
    end.

mounted(Image) ->
    {ok, Fat} = erx_fat:mount(reader(Image), byte_size(Image) div ?SECTOR),
    Fat.

path(Fat, Names) ->
    lists:foldl(fun(Name, {ok, Dir}) -> erx_fat:walk(Dir, Name, Fat);
                   (_Name, Error) -> Error
                end, {ok, erx_fat:root(Fat)}, Names).

names(Fat, Names) ->
    {ok, Dir} = path(Fat, Names),
    {ok, Entries} = erx_fat:list(Dir, Fat),
    lists:sort([Name || {Name, _} <- Entries]).

whole(Fat, Names) ->
    {ok, File} = path(Fat, Names),
    #{size := Size} = erx_fat:attr(File),
    erx_fat:read(File, 0, Size + 100, Fat).

%% The 16-bit word at Offset of Image set to Value.
put16(Image, Offset, Value) ->
    <<Before:Offset/binary, _:16, After/binary>> = Image,
    <<Before/binary, Value:16/little, After/binary>>.

put32(Image, Offset, Value) ->
    <<Before:Offset/binary, _:32, After/binary>> = Image,
    <<Before/binary, Value:32/little, After/binary>>.

%% FAT16's first FAT and its entries, from the image's own boot sector.
fat16_start(<<_:14/binary, Reserved:16/little, _/binary>>) -> Reserved * ?SECTOR.

%% Every FAT16 link from cluster 2 on replaced by What(Cluster, Link).
relinked(Image, What) ->
    Start = fat16_start(Image),
    <<_:Start/binary, _:32, Entries:(64 * 2)/binary, _/binary>> = Image,
    Links = [{Cluster, Link} || {Cluster, Link} <- lists:zip(lists:seq(2, 65), [L || <<L:16/little>> <= Entries]),
                                Link >= 2, Link < 16#fff0],
    lists:foldl(fun({Cluster, Link}, Acc) -> put16(Acc, Start + Cluster * 2, What(Cluster, Link)) end, Image, Links).

replaced(Image, From, To) ->
    [Before, After] = binary:split(Image, From),
    <<Before/binary, To/binary, After/binary>>.

each_type(Test) ->
    [Test(mounted(image(Name))) || Name <- ["fat16.img", "fat32.img"]].

%% ---------------------------------------------------------------------------
%% The mount
%% ---------------------------------------------------------------------------

a_volume_mounts_with_its_type_label_and_clean_flag_test() ->
    ?assertMatch(#{type := 16, label := <<"STICK16">>, clean := true, cluster_bytes := 1024},
                 erx_fat:info(mounted(image("fat16.img")))),
    ?assertMatch(#{type := 32, label := <<"STICK32">>, clean := true, cluster_bytes := 512},
                 erx_fat:info(mounted(image("fat32.img")))).

a_cleared_hard_error_bit_and_fat32_unmirrored_are_reported_test() ->
    Image = image("fat16.img"),
    Start = fat16_start(Image),
    <<_:(Start + 2)/binary, Second:16/little, _/binary>> = Image,
    ?assertMatch(#{clean := true, hard_error := true, mirrored := true},
                 erx_fat:info(mounted(put16(Image, Start + 2, Second band 16#bfff)))),
    %% FAT32's ExtFlags, at byte 40, with mirroring off and the first FAT active.
    Info = erx_fat:info(mounted(put16(image("fat32.img"), 40, 16#80))),
    ?assertMatch(#{mirrored := false, hard_error := false}, Info),
    ?assertEqual({read_only, mirror}, erx_fat_alloc:writable(Info)).

%% FAT32's version, at byte 42, must be 0.0, and its count of clusters at most
%% 16#0ffffff5: a boot sector stating one more over a placement that large, whose
%% sectors past the image read as zeroes, is refused, and one stating exactly that
%% many mounts.
fat32s_version_and_largest_count_of_clusters_are_checked_test() ->
    Image = image("fat32.img"),
    ?assertEqual({error, not_its_volume}, erx_fat:mount(reader(put16(Image, 42, 1)), byte_size(Image) div ?SECTOR)),
    <<_:14/binary, Reserved:16/little, _/binary>> = Image,
    FatSectors = ((16#0ffffff7 + 2) * 4 + ?SECTOR - 1) div ?SECTOR,
    Huge = fun(Clusters) ->
                   Total = Reserved + 2 * FatSectors + Clusters,
                   Boot = put32(put32(Image, 36, FatSectors), 32, Total),
                   Read = fun(S) when (S + 1) * ?SECTOR =< byte_size(Boot) -> {ok, binary:part(Boot, S * ?SECTOR, ?SECTOR)};
                             (_S) -> {ok, <<0:(?SECTOR * 8)>>}
                          end,
                   erx_fat:mount(Read, Total)
           end,
    ?assertEqual({error, not_its_volume}, Huge(16#0ffffff6)),
    ?assertMatch({ok, _}, Huge(16#0ffffff5)).

%% FAT32's FSInfo sector, named at byte 48, is written only inside the reserved
%% area past the boot sector: 0, the first FAT and a data sector are none, so no
%% crafted boot sector aims the FSInfo writes at itself, a FAT or a file.
an_fsinfo_sector_outside_the_reserved_area_is_none_test() ->
    Image = image("fat32.img"),
    <<_:14/binary, Reserved:16/little, _:32/binary, FsInfo:16/little, _/binary>> = Image,
    ?assertMatch(#{fsinfo := FsInfo}, erx_fat:layout(mounted(Image))),
    [?assertMatch(#{fsinfo := none}, erx_fat:layout(mounted(put16(Image, 48, Sector))))
     || Sector <- [0, Reserved, Reserved + 1, 16#ffff]].

a_cleared_clean_bit_is_the_dirty_flag_test() ->
    Image = image("fat16.img"),
    Start = fat16_start(Image),
    <<_:(Start + 2)/binary, Second:16/little, _/binary>> = Image,
    Dirty = put16(Image, Start + 2, Second band 16#7fff),
    ?assertMatch(#{clean := false}, erx_fat:info(mounted(Dirty))).

a_label_holding_a_control_is_not_shown_test() ->
    %% FAT16's label lies at byte 43 of the boot sector, behind its extended signature.
    Image = image("fat16.img"),
    <<Before:43/binary, _:11/binary, After/binary>> = Image,
    ?assertMatch(#{label := none}, erx_fat:info(mounted(<<Before/binary, "AB\ns1_x    ", After/binary>>))).

a_boot_sector_the_server_does_not_admit_is_refused_test() ->
    Image = image("fat16.img"),
    Refused = fun(Bytes, Sectors) -> erx_fat:mount(reader(Bytes), Sectors) end,
    %% 4096-byte sectors, a FAT too small for its clusters, a volume past its placement.
    ?assertEqual({error, not_its_volume}, Refused(put16(Image, 11, 4096), byte_size(Image) div ?SECTOR)),
    ?assertEqual({error, not_its_volume}, Refused(put16(Image, 22, 1), byte_size(Image) div ?SECTOR)),
    ?assertEqual({error, not_its_volume}, Refused(Image, byte_size(Image) div ?SECTOR - 1)),
    ?assertEqual({error, not_its_volume}, Refused(<<0:(?SECTOR * 8)>>, 1)),
    ?assertEqual({error, read_failed}, erx_fat:mount(fun(_) -> {error, eio} end, 100)).

%% ---------------------------------------------------------------------------
%% Directories and lookups
%% ---------------------------------------------------------------------------

directories_list_their_long_names_and_no_dot_entries_test() ->
    each_type(fun(Fat) ->
                      ?assertEqual([<<"empty">>, <<"hello.txt">>, <<"sub">>], names(Fat, [])),
                      ?assertEqual([<<"Deeper">>, ?LONG], names(Fat, [<<"sub">>])),
                      ?assertEqual([<<"x.TXT">>], names(Fat, [<<"sub">>, <<"Deeper">>]))
              end).

a_name_is_found_with_its_ascii_case_ignored_test() ->
    each_type(fun(Fat) ->
                      {ok, Exact} = path(Fat, [<<"sub">>, ?LONG]),
                      ?assertEqual({ok, Exact}, path(Fat, [<<"SUB">>, <<"long file name.DAT">>])),
                      ?assertEqual({error, not_found}, path(Fat, [<<"nothing">>])),
                      {ok, Sub} = path(Fat, [<<"sub">>]),
                      {ok, Again} = path(Fat, [<<"sub">>, <<"Deeper">>]),
                      ?assertNotEqual(erx_fat:key(Sub), erx_fat:key(Again)),
                      ?assertEqual({error, not_dir}, path(Fat, [<<"hello.txt">>, <<"x">>]))
              end).

a_name_the_specification_forbids_is_never_listed_test() ->
    Image = image("fat16.img"),
    %% The long name's first entry spells "Long File Na" in UTF-16: a slash in it
    %% leaves the entry its short name; the short entry of hello.txt given one
    %% breaks its long name's checksum and leaves no name to serve at all.
    Slashed = replaced(Image, <<"L", 0, "o", 0, "n", 0, "g", 0>>, <<"L", 0, "/", 0, "n", 0, "g", 0>>),
    Fat = mounted(replaced(Slashed, <<"HELLO   TXT">>, <<"HE/LO   TXT">>)),
    Listed = names(Fat, []) ++ names(Fat, [<<"sub">>]),
    ?assertEqual([], [Name || Name <- Listed, binary:match(Name, <<"/">>) =/= nomatch]),
    ?assertEqual([<<"empty">>, <<"sub">>], names(Fat, [])),
    ?assertMatch([<<"Deeper">>, Short] when Short =/= ?LONG, names(Fat, [<<"sub">>])).

%% ---------------------------------------------------------------------------
%% Reads
%% ---------------------------------------------------------------------------

a_file_reads_whole_across_its_chain_and_no_further_test() ->
    each_type(fun(Fat) ->
                      ?assertEqual({ok, expected(["hello.txt"])}, whole(Fat, [<<"hello.txt">>])),
                      ?assertEqual({ok, expected(["sub", "Long File Name.dat"])}, whole(Fat, [<<"sub">>, ?LONG])),
                      ?assertEqual({ok, <<>>}, whole(Fat, [<<"empty">>])),
                      ?assertEqual({ok, expected(["sub", "Deeper", "x.TXT"])},
                                   whole(Fat, [<<"sub">>, <<"Deeper">>, <<"x.TXT">>]))
              end).

a_read_from_an_offset_answers_that_range_test() ->
    each_type(fun(Fat) ->
                      {ok, File} = path(Fat, [<<"sub">>, ?LONG]),
                      Bytes = expected(["sub", "Long File Name.dat"]),
                      ?assertEqual({ok, binary:part(Bytes, 1000, 2100)}, erx_fat:read(File, 1000, 2100, Fat)),
                      ?assertEqual({ok, binary:part(Bytes, 4990, 10)}, erx_fat:read(File, 4990, 4096, Fat)),
                      ?assertEqual({ok, <<>>}, erx_fat:read(File, 5000, 10, Fat)),
                      ?assertEqual({error, is_dir}, erx_fat:read(erx_fat:root(Fat), 0, 10, Fat))
              end).

a_chain_that_loops_is_refused_test() ->
    Fat = mounted(relinked(image("fat16.img"), fun(Cluster, _Link) -> Cluster end)),
    ?assertEqual({error, does_not_read}, whole(Fat, [<<"sub">>, ?LONG])),
    ?assertEqual({ok, expected(["hello.txt"])}, whole(Fat, [<<"hello.txt">>])).

%% Whole, and as a read of the first two clusters, whose second is the bad link
%% itself and is never read.
a_link_out_of_the_data_area_or_free_is_refused_test() ->
    [begin
         Fat = mounted(relinked(image("fat16.img"), fun(_, _) -> Value end)),
         {ok, File} = path(Fat, [<<"sub">>, ?LONG]),
         ?assertEqual({error, does_not_read}, whole(Fat, [<<"sub">>, ?LONG])),
         ?assertEqual({error, does_not_read}, erx_fat:read(File, 0, 1025, Fat))
     end || Value <- [0, 1, 16#fff0, 16#fff7, 60000]].

a_chain_that_ends_early_is_refused_test() ->
    Fat = mounted(relinked(image("fat16.img"), fun(_, _) -> 16#ffff end)),
    ?assertEqual({error, does_not_read}, whole(Fat, [<<"sub">>, ?LONG])).

a_sector_the_medium_does_not_read_is_read_failed_test() ->
    Image = image("fat16.img"),
    Fat = mounted(Image),
    {ok, File} = path(Fat, [<<"hello.txt">>]),
    {ok, Broken} = erx_fat:mount(fun(Sector) when Sector < 64 -> (reader(Image))(Sector);
                                    (_) -> {error, eio}
                                 end, byte_size(Image) div ?SECTOR),
    ?assertEqual({error, read_failed}, erx_fat:read(File, 0, 10, Broken)).

%% ---------------------------------------------------------------------------
%% The ownership check
%% ---------------------------------------------------------------------------

%% Where an image keeps its FATs and clusters, from its own boot sector.
geometry(<<_:11/binary, ?SECTOR:16/little, PerCluster, Reserved:16/little, Fats, RootEntries:16/little, _:16, _Media,
           Fat16:16/little, _:8/binary, _:32, Fat32:32/little, _/binary>>) ->
    FatSectors = case Fat16 of 0 -> Fat32; _ -> Fat16 end,
    RootSectors = (RootEntries * 32 + ?SECTOR - 1) div ?SECTOR,
    #{type => case Fat16 of 0 -> 32; _ -> 16 end, fat => Reserved * ?SECTOR, fats => Fats,
      fat_bytes => FatSectors * ?SECTOR, cluster_bytes => PerCluster * ?SECTOR,
      data => (Reserved + Fats * FatSectors + RootSectors) * ?SECTOR}.

%% Cluster's entry in every FAT set to Value, or as the first FAT holds it.
fat_put(Image, Cluster, Value) ->
    G = #{type := Type, fat := Fat, fats := Fats, fat_bytes := FatBytes} = geometry(Image),
    lists:foldl(fun(Copy, Acc) ->
                        Offset = Fat + Copy * FatBytes + Cluster * (Type div 8),
                        case G of #{type := 16} -> put16(Acc, Offset, Value); #{type := 32} -> put32(Acc, Offset, Value) end
                end, Image, lists:seq(0, Fats - 1)).

fat_get(Image, Cluster) ->
    #{type := Type, fat := Fat} = geometry(Image),
    <<_:(Fat + Cluster * (Type div 8))/binary, Entry:Type/little, _/binary>> = Image,
    Entry band 16#0fffffff.

%% The byte offset of a cluster, and of a short entry: by its name, or the long-named
%% file's by its size.
cluster_at(Image, Cluster) ->
    #{data := Data, cluster_bytes := Bytes} = geometry(Image),
    Data + (Cluster - 2) * Bytes.

short_entry(Image, Short) ->
    {Offset, 11} = binary:match(Image, Short),
    Offset.

long_entry(Image) ->
    hd([Offset || Offset <- lists:seq(0, byte_size(Image) - 32, 32),
                  <<Name, _:10/binary, Attr, _:16/binary, 5000:32/little>> <- [binary:part(Image, Offset, 32)],
                  Name =/= 16#e5, Attr band 16#18 =:= 0]).

first_of(Image, Entry) ->
    <<_:Entry/binary, _:20/binary, High:16/little, _:4/binary, Low:16/little, _/binary>> = Image,
    (High bsl 16) bor Low.

first_set(Image, Entry, First) ->
    put16(put16(Image, Entry + 20, First bsr 16), Entry + 26, First band 16#ffff).

%% A subdirectory's first cluster, from the read path's key for it.
dir_first(Image, Names) ->
    {ok, Dir} = path(mounted(Image), Names),
    {dir, First} = erx_fat:key(Dir),
    First.

checked(Image) -> erx_fat:check(mounted(Image)).

%% A FAT16 mark, 16#fff0 or above, as the image's type writes it.
mark(Image, Mark16) ->
    case geometry(Image) of #{type := 16} -> Mark16; #{type := 32} -> Mark16 bor 16#0fff0000 end.

each_image(Test) ->
    [Test(image(Name)) || Name <- ["fat16.img", "fat32.img"]].

%% A cluster free in both seeds, far past their files.
-define(SPARE, 300).

the_seed_volumes_pass_the_ownership_check_test() ->
    each_image(fun(Image) -> ?assertEqual(ok, checked(Image)) end).

a_chain_no_name_reaches_passes_test() ->
    each_image(fun(Image) ->
                       Lost = fat_put(fat_put(fat_put(fat_put(Image, ?SPARE, ?SPARE + 1), ?SPARE + 1, ?SPARE),
                                              ?SPARE + 2, ?SPARE + 3), ?SPARE + 3, mark(Image, 16#fff8)),
                       ?assertEqual(ok, checked(Lost))
               end).

a_cluster_linked_to_twice_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       Second = fat_get(Image, first_of(Image, long_entry(Image))),
                       ?assertEqual({read_only, tree}, checked(fat_put(Image, ?SPARE, Second)))
               end).

an_entry_of_no_value_the_specification_gives_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       #{clusters := Clusters} = erx_fat:info(mounted(Image)),
                       [?assertEqual({read_only, tree}, checked(fat_put(Image, ?SPARE, Value)))
                        || Value <- [1, Clusters + 2, mark(Image, 16#fff0)]]
               end).

a_first_cluster_outside_the_volume_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       #{clusters := Clusters} = erx_fat:info(mounted(Image)),
                       Hello = short_entry(Image, <<"HELLO   TXT">>),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, Hello, Clusters + 2))),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, short_entry(Image, <<"SUB        ">>), 0)))
               end).

a_first_cluster_named_twice_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       Long = first_of(Image, long_entry(Image)),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, short_entry(Image, <<"HELLO   TXT">>), Long)))
               end).

a_first_cluster_linked_to_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       Long = first_of(Image, long_entry(Image)),
                       Hello = short_entry(Image, <<"HELLO   TXT">>),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, Hello, fat_get(Image, Long)))),
                       %% A loop back to the chain's own first cluster.
                       Last = lists:last(chain_of(Image, Long)),
                       ?assertEqual({read_only, tree}, checked(fat_put(Image, Last, Long)))
               end).

chain_of(Image, First) ->
    case fat_get(Image, First) of
        Next when Next >= 2, Next < 16#fff0 -> [First | chain_of(Image, Next)];
        _ -> [First]
    end.

a_dot_entry_naming_another_directory_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       Sub = dir_first(Image, [<<"sub">>]),
                       Deeper = dir_first(Image, [<<"sub">>, <<"Deeper">>]),
                       ?assertEqual(Sub, first_of(Image, cluster_at(Image, Deeper) + 32)),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, cluster_at(Image, Sub), Deeper))),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, cluster_at(Image, Deeper) + 32, 0))),
                       ?assertEqual({read_only, tree}, checked(first_set(Image, cluster_at(Image, Sub) + 32, Sub)))
               end).

a_subdirectory_without_its_dot_entries_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       Deeper = cluster_at(Image, dir_first(Image, [<<"sub">>, <<"Deeper">>])),
                       [?assertEqual({read_only, tree}, checked(put16(Image, At, 16#e5 bor ($. bsl 8))))
                        || At <- [Deeper, Deeper + 32]]
               end).

a_reached_cluster_whose_entry_is_free_or_bad_is_a_tree_finding_test() ->
    each_image(fun(Image) ->
                       Hello = first_of(Image, short_entry(Image, <<"HELLO   TXT">>)),
                       Long = first_of(Image, long_entry(Image)),
                       Bad = mark(Image, 16#fff7),
                       [?assertEqual({read_only, tree}, checked(fat_put(Image, Cluster, Value)))
                        || Cluster <- [Hello, lists:last(chain_of(Image, Long))], Value <- [0, Bad]]
               end).

%% A FAT32 boot sector claiming 4,300,000 one-sector clusters over the seed: the check
%% answers too_large without reading a sector.
a_volume_past_the_checked_count_is_too_large_and_unread_test() ->
    Total = 4_300_000,
    Image = put32(put32(image("fat32.img"), 32, Total), 36, (Total + 2) * 4 div ?SECTOR + 1),
    <<_:13/binary, _, Rest/binary>> = Image,
    Huge = <<(binary:part(Image, 0, 13))/binary, 1, Rest/binary>>,
    Read = reader(Huge),
    put(reads, true),
    {ok, Fat} = erx_fat:mount(fun(Sector) -> case get(reads) of true -> Read(Sector); false -> {error, read} end end,
                              Total),
    put(reads, false),
    ?assertMatch(#{clusters := C} when C > 4_194_304, erx_fat:info(Fat)),
    ?assertEqual({read_only, too_large}, erx_fat:check(Fat)).

a_sector_that_does_not_read_fails_the_check_test() ->
    Image = image("fat16.img"),
    #{fat := FatStart, fats := Fats, fat_bytes := FatBytes} = geometry(Image),
    Root = (FatStart + Fats * FatBytes) div ?SECTOR,
    {ok, Fat} = erx_fat:mount(fun(Sector) when Sector < Root -> (reader(Image))(Sector); (_) -> {error, eio} end,
                              byte_size(Image) div ?SECTOR),
    ?assertEqual({error, read_failed}, erx_fat:check(Fat)).
