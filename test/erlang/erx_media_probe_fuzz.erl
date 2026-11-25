%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the probe of a volume's format, erx_media_probe
%% (docs/design-drives.md, "Fuzz targets"). Its seeds are one volume of each format:
%% each signature the probe's order lists, written alone, and the FAT12, FAT16 and
%% FAT32 volumes fsimg writes into the directory it is given. A round takes one,
%% mutates the bytes of the sectors the probe reads (bytes flipped, a BIOS parameter
%% block's fields set to 0, 1 or their largest value), may cut the volume short, and
%% probes it. Whatever the volume holds, the probe never raises and makes no atom, and
%% answers a format of its order or unknown, also-found formats only among the
%% formats written and never the one selected, and a FAT type exactly when it selects
%% msdosfs. The seed comes from make check-fuzz.

-module(erx_media_probe_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 20000).
-define(SECTOR, 512).
-define(NAMES, [ufs, cd9660, 'hfs+', ext2fs, f2fs, erofs, littlefs, apfs, exfat, msdosfs, ntfs]).
-define(READ, [0, 2, 8, 18, 64, 130, 514]).
%% The BIOS parameter block's fields, {offset, bytes}.
-define(BPB, [{11, 2}, {13, 1}, {14, 2}, {16, 1}, {17, 2}, {19, 2}, {22, 2}, {32, 4}, {36, 4}]).

run([Seed, Directory]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    true = os:putenv("ERX_PROBE_VOLUMES", Directory),
    Seeds = [erx_media_probe_tests:fsimg(Name) || Name <- ["fat12.img", "fat16.img", "fat32.img"]]
        ++ [erx_media_probe_tests:signed(Overlay, 1024) || Overlay <- signatures()],
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Selected = lists:sum([round_of(lists:nth(rand:uniform(length(Seeds)), Seeds)) || _ <- lists:seq(1, ?ROUNDS)]),
    io:format("fuzz: ~p rounds ok, ~p selected a format~n", [?ROUNDS, Selected]).

signatures() ->
    [[{65536 + 1372, <<16#19540119:32/little>>}], [{32768, <<1, "CD001", 1, 0>>}], [{1024, <<"H+", 4:16>>}],
     [{1080, <<16#ef53:16/little>>}], [{1024, <<?ERX_F2FS_MAGIC:32/little>>}],
     [{1024, <<?ERX_EROFS_MAGIC:32/little>>}], [{4104, <<"littlefs">>}], [{32, <<"NXSB">>}],
     [{3, <<"EXFAT   ">>}], [{3, <<"NTFS    ">>}]].

round_of(Seed) ->
    Volume = lists:foldl(fun(_, V) -> mutate(V) end, Seed, lists:seq(1, rand:uniform(8))),
    Written = lists:nth(rand:uniform(3), [[], [msdosfs], [msdosfs, littlefs]]),
    Atoms = erlang:system_info(atom_count),
    Answer = try
                 erx_media_probe:format(erx_media_probe_tests:reader(Volume, none), maps:get(length, Volume), Written)
             catch
                 Class:Reason:Stack -> error({raised, Class, Reason, Stack})
             end,
    Atoms =:= erlang:system_info(atom_count) orelse error({made_an_atom, Answer}),
    check(Answer, Written).

mutate(Volume = #{length := Length}) ->
    case rand:uniform(4) of
        1 -> Volume#{length := rand:uniform(Length + 1) - 1};
        2 -> overlay(Volume, rand:uniform(?SECTOR) - 1, <<(rand:uniform(256) - 1)>>, lists:nth(rand:uniform(7), ?READ));
        _ ->
            {Offset, Bytes} = lists:nth(rand:uniform(length(?BPB)), ?BPB),
            Value = lists:nth(rand:uniform(3), [0, 1, (1 bsl (8 * Bytes)) - 1]),
            overlay(Volume, Offset, <<Value:(8 * Bytes)/little>>, 0)
    end.

overlay(Volume, Offset, Bytes, Lba) ->
    <<Before:Offset/binary, _:(byte_size(Bytes))/binary, After/binary>> =
        maps:get(Lba, Volume, <<0:(?SECTOR * 8)>>),
    Volume#{Lba => <<Before/binary, Bytes/binary, After/binary>>}.

check({ok, #{format := unknown, also := []} = Probe}, _Written) when map_size(Probe) =:= 2 ->
    0;
check({ok, #{format := msdosfs, also := Also, fat := Type}}, Written) when Type =:= 12; Type =:= 16; Type =:= 32;
                                                                           Type =:= none ->
    also(msdosfs, Also, Written);
check({ok, #{format := Format, also := Also} = Probe}, Written) when map_size(Probe) =:= 2, Format =/= msdosfs ->
    lists:member(Format, ?NAMES) orelse error({unknown_format, Probe}),
    also(Format, Also, Written);
check(Answer, _Written) ->
    error({unexpected_answer, Answer}).

also(Format, Also, Written) ->
    [error({also_not_written, Format, Also}) || Name <- Also, not lists:member(Name, Written) orelse Name =:= Format],
    1.
