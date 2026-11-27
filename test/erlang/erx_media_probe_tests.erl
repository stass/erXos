%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Host tests of erx_media_probe (docs/design-drives.md, "Host tests"), over volumes
%% written here signature by signature and over the FAT12, FAT16 and FAT32 volumes
%% fsimg writes into the directory ERX_PROBE_VOLUMES names. test/host/
%% erx_media_probe_test.rb runs them against the probe as it is and against each
%% seeded fault it lists.

-module(erx_media_probe_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([signed/2, fsimg/1, reader/2]).

-define(SECTOR, 512).
-define(DEVELOPMENT, [fat, littlefs]).
-define(RELEASE, [fat]).

%% A volume of Sectors 512-byte sectors, zero but for Overlay, {ByteOffset, Bytes}.
signed(Overlay, Sectors) ->
    lists:foldl(fun({Offset, Bytes}, Image) ->
                        Lba = Offset div ?SECTOR,
                        Within = Offset rem ?SECTOR,
                        <<Before:Within/binary, _:(byte_size(Bytes))/binary, After/binary>> =
                            maps:get(Lba, Image, <<0:(?SECTOR * 8)>>),
                        Image#{Lba => <<Before/binary, Bytes/binary, After/binary>>}
                end, #{length => Sectors}, Overlay).

%% The first sectors of fsimg's image Name, as a volume of its length.
fsimg(Name) ->
    Path = filename:join(os:getenv("ERX_PROBE_VOLUMES"), Name),
    {ok, Bytes} = file:read_file(Path),
    Count = byte_size(Bytes) div ?SECTOR,
    maps:from_list([{length, Count} | [{Lba, binary:part(Bytes, Lba * ?SECTOR, ?SECTOR)}
                                       || Lba <- lists:seq(0, min(Count, 600) - 1)]]).

with(Volume, Overlay) ->
    maps:merge(Volume, maps:remove(length, signed(Overlay, 0))).

%% The volume's placement; the probe never asks for a sector past its length.
reader(#{length := Length} = Volume, _Failing) ->
    fun(Lba) when Lba >= Length -> error({read_past_the_volume, Lba});
       (Lba) -> {ok, maps:get(Lba, Volume, <<0:(?SECTOR * 8)>>)}
    end.

probe(Volume) -> probe(Volume, ?DEVELOPMENT).

probe(Volume, Written) ->
    {ok, Probe} = erx_media_probe:format(reader(Volume, none), maps:get(length, Volume), Written),
    Probe.

%% A seed of each row.
each_row_selects_its_format_test() ->
    Rows = [{ufs, [{65536 + 1372, <<16#19540119:32/little>>}]},
            {ufs, [{262144 + 1372, <<16#011954:32/little>>}]},
            {cd9660, [{32768, <<1, "CD001", 1, 0>>}]},
            {'hfs+', [{1024, <<"H+", 4:16>>}]},
            {'hfs+', [{1024, <<"HX", 5:16>>}]},
            {ext2fs, [{1080, <<16#ef53:16/little>>}]},
            {f2fs, [{1024, <<?ERX_F2FS_MAGIC:32/little>>}]},
            {erofs, [{1024, <<?ERX_EROFS_MAGIC:32/little>>}]},
            {littlefs, [{8, <<"littlefs">>}]},
            {littlefs, [{4104, <<"littlefs">>}]},
            {apfs, [{32, <<"NXSB">>}]},
            {exfat, [{3, <<"EXFAT   ">>}, {510, <<16#55, 16#aa>>}]},
            {ntfs, [{3, <<"NTFS    ">>}, {510, <<16#55, 16#aa>>}]}],
    [?assertMatch(#{format := Name}, probe(signed(Overlay, 1024))) || {Name, Overlay} <- Rows],
    ?assertEqual(#{format => unknown, also => []}, probe(signed([], 1024))).

fsimg_fat_volumes_are_fat_with_their_type_test() ->
    ?assertEqual(#{format => fat, also => [], fat => 16}, probe(fsimg("fat16.img"))),
    ?assertEqual(#{format => fat, also => [], fat => 32}, probe(fsimg("fat32.img"))).

a_fat12_volume_is_named_with_its_type_test() ->
    ?assertEqual(#{format => fat, also => [], fat => 12}, probe(fsimg("fat12.img"))).

a_pico_boot_sector_without_its_signature_is_fat_test() ->
    Volume = maps:get(0, fsimg("fat16.img")),
    <<Head:510/binary, _:2/binary>> = Volume,
    ?assertMatch(#{format := fat, fat := 16}, probe((fsimg("fat16.img"))#{0 => <<Head/binary, 0, 0>>})).

a_fat32_volume_holding_erofs_magic_selects_erofs_test() ->
    Volume = with(fsimg("fat32.img"), [{1024, <<?ERX_EROFS_MAGIC:32/little>>}]),
    ?assertEqual(#{format => erofs, also => [fat]}, probe(Volume)).

a_fat32_volume_that_kept_a_littlefs_superblock_selects_littlefs_test() ->
    Volume = with(fsimg("fat32.img"), [{4096 + 8, <<"littlefs">>}]),
    ?assertEqual(#{format => littlefs, also => [fat]}, probe(Volume, ?DEVELOPMENT)),
    ?assertEqual(#{format => littlefs, also => [fat]}, probe(Volume, ?RELEASE)),
    ?assertEqual(#{format => littlefs, also => []}, probe(Volume, [])).

a_volume_too_short_lacks_the_signatures_past_it_test() ->
    Fat = fsimg("fat16.img"),
    ?assertMatch(#{format := fat}, probe(Fat#{length := 1})),
    ?assertMatch(#{format := unknown}, probe(signed([{65536 + 1372, <<16#19540119:32/little>>}], 128))).

a_failed_read_fails_the_probe_test() ->
    Read = fun(2) -> {error, eio}; (_) -> {ok, <<0:(?SECTOR * 8)>>} end,
    ?assertEqual({error, {read, eio}}, erx_media_probe:format(Read, 1000, ?DEVELOPMENT)),
    Short = fun(_) -> {ok, <<0:8>>} end,
    ?assertEqual({error, {read, {short, 1}}}, erx_media_probe:format(Short, 1000, ?DEVELOPMENT)).

%% A sector inside the volume whose read fails, erange included, fails the probe:
%% only the volume's length says where its sectors end.
an_erange_inside_the_volume_fails_the_probe_test() ->
    Read = fun(2) -> {error, erange}; (_) -> {ok, <<0:(?SECTOR * 8)>>} end,
    ?assertEqual({error, {read, erange}}, erx_media_probe:format(Read, 1000, ?DEVELOPMENT)).

a_boot_sector_without_a_cluster_count_has_no_type_test() ->
    <<Head:11/binary, _:16, Rest/binary>> = maps:get(0, fsimg("fat16.img")),
    ?assertMatch(#{format := fat, fat := none}, probe((fsimg("fat16.img"))#{0 => <<Head/binary, 0:16, Rest/binary>>})).
