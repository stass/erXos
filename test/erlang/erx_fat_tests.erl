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
