%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the FAT server's allocator, erx_fat_alloc (docs/design-storage.md,
%% "Removable media: FAT"). Its seeds are the volumes test/fixtures/fat_volumes.rb
%% writes into the directory it is given. A round takes one, as it is or with its FATs
%% and its files' first clusters mutated (16-bit words set to random or telling
%% values: free, reserved, bad, end of chain, small cluster numbers), mounts it, and
%% when it mounts writable runs random batches of grows, shrinks and frees over its
%% files, as erx_fat_alloc_tests:op/3 makes them, each file's directory entry given
%% its new first cluster and size, then the finish. Whatever the volume holds, each
%% round ends in a finding of the allocator's closed set or a volume fsimg's verify
%% (ERX_FSIMG) passes whenever it passed the round's starting volume; the allocator
%% reads only sectors of the first FAT and FSInfo, and every plan writes only FAT and
%% FSInfo sectors, each FAT sector the same bytes to every FAT. The seed comes from
%% make check-fuzz.

-module(erx_fat_alloc_fuzz).

-export([run/1]).

-define(ROUNDS, 200).
-define(MIN_VERIFIED, ?ROUNDS div 4).
-define(SECTOR, 512).
-define(FINDINGS, [does_not_read, no_space, read_failed]).

run([Seed, Directory]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Seeds = [Bytes || Name <- ["fat16.img", "fat32.img"],
                      {ok, Bytes} <- [file:read_file(filename:join(Directory, Name))]],
    length(Seeds) =:= 2 orelse error(no_seed_volumes),
    Outcomes = [round_of(lists:nth(rand:uniform(2), Seeds)) || _ <- lists:seq(1, ?ROUNDS)],
    Verified = length([verified || verified <- Outcomes]),
    Verified >= ?MIN_VERIFIED orelse error({too_few_verified, Verified}),
    io:format("fuzz: ~b rounds ok, ~b verified~n", [?ROUNDS, Verified]).

round_of(Base) ->
    Mutated = rand:uniform(2) =:= 1,
    Image = case Mutated of true -> mutated(Base); false -> Base end,
    erx_fat_alloc_tests:use(Image),
    Fat = erx_fat:mount(erx_fat_alloc_tests:reader(), byte_size(Image) div ?SECTOR),
    Entries = erx_fat_alloc_tests:entries(Image),
    case Fat of
        {ok, Mounted} when map_size(Entries) > 0 ->
            case erx_fat_alloc:writable(erx_fat:info(Mounted)) of
                ok -> written(Mounted, Entries, Image, Mutated);
                {read_only, _} -> refused
            end;
        _ ->
            refused
    end.

written(Fat, Entries, Image, Mutated) ->
    L = erx_fat:layout(Fat),
    #{cluster_bytes := ClusterBytes} = erx_fat:info(Fat),
    A = erx_fat_alloc:new(L#{read := watched(L)}),
    try
        Chains = maps:map(fun(_Offset, 0) -> []; (_Offset, First) -> answer(erx_fat_alloc:chain(A, First)) end,
                          Entries),
        %% Files that already share a cluster, which only a scan of every chain
        %% would find (a residual in TODO.md), are not the allocator's to keep apart.
        All = lists:append(maps:values(Chains)),
        length(All) =:= length(lists:usort(All)) orelse throw(crossed),
        planned(answer(erx_fat_alloc:dirty(A)), L),
        {A1, _} = lists:foldl(fun(_, {Ai, Ci}) -> batch(Ai, Ci, L, ClusterBytes) end, {A, Chains},
                              lists:seq(1, rand:uniform(4))),
        {Finish, _} = answer(erx_fat_alloc:finish(A1)),
        planned(Finish, L),
        verdict(Image, Mutated)
    catch
        throw:{refused, Finding} ->
            lists:member(Finding, ?FINDINGS) orelse error({finding, Finding}),
            refused;
        throw:crossed ->
            crossed
    end.

batch(A, Chains, L, ClusterBytes) ->
    {A1, Post} = lists:foldl(fun(_, {Ai, Ci}) -> erx_fat_alloc_tests:op(Ai, Ci, maps:keys(Ci)) end, {A, Chains},
                             lists:seq(1, rand:uniform(4))),
    {Plan, A2} = answer(erx_fat_alloc:commit(A1)),
    planned(Plan, L),
    maps:foreach(fun(Offset, Chain) -> erx_fat_alloc_tests:entry(Offset, Chain, ClusterBytes) end, Post),
    {A2, Post}.

answer({ok, Value}) -> Value;
answer({ok, Value, Alloc}) -> {Value, Alloc};
answer({error, Finding}) -> throw({refused, Finding}).

%% The image's reader, refusing a sector outside the first FAT and FSInfo.
watched(#{fat_start := Start, fat_sectors := FatSectors, fsinfo := FsInfo}) ->
    Read = erx_fat_alloc_tests:reader(),
    fun(Sector) when Sector >= Start, Sector < Start + FatSectors; Sector =:= FsInfo -> Read(Sector);
       (Sector) -> error({read_outside, Sector})
    end.

%% Plan applied once every write lies in a FAT or FSInfo and each FAT sector goes
%% to every FAT with the same bytes.
planned(Plan, L = #{fat_start := Start, fats := Fats, fat_sectors := FatSectors, fsinfo := FsInfo}) ->
    [begin
         [inside(L, Sector) orelse error({write_outside, Sector}) || {Sector, _} <- Writes],
         Groups = maps:groups_from_list(fun({Sector, _}) -> (Sector - Start) rem FatSectors end,
                                        fun({_, Bytes}) -> Bytes end,
                                        [Write || {Sector, _} = Write <- Writes, Sector =/= FsInfo]),
         [{Fats, [_]} = {length(Copies), lists:usort(Copies)} || _ := Copies <- Groups]
     end || {_Step, Writes} <- Plan],
    erx_fat_alloc_tests:apply_plan(Plan).

inside(#{fsinfo := Sector}, Sector) -> true;
inside(#{fat_start := Start, fats := Fats, fat_sectors := FatSectors}, Sector) ->
    Sector >= Start andalso Sector < Start + Fats * FatSectors.

%% A volume that fsimg's verify passed at the round's start passes it at its end.
verdict(Image, Mutated) ->
    Valid = not Mutated orelse element(1, erx_fat_alloc_tests:verify(Image)) =:= 0,
    case {Valid, erx_fat_alloc_tests:verify(erx_fat_alloc_tests:flat())} of
        {true, {0, _}} -> verified;
        {true, {_, Output}} -> error({verify_failed, Output});
        {false, _} -> survived
    end.

%% ---------------------------------------------------------------------------
%% Mutations
%% ---------------------------------------------------------------------------

mutated(Image) ->
    <<_:14/binary, Reserved:16/little, _:6/binary, FatSize16:16/little, _:12/binary, FatSize32:32/little,
      _/binary>> = Image,
    FatSectors = case FatSize16 of 0 -> FatSize32; _ -> FatSize16 end,
    lists:foldl(fun(_, Acc) -> mutation(Acc, Reserved, FatSectors) end, Image, lists:seq(1, rand:uniform(8))).

%% A word of the first 2 KiB of the first FAT, or of both FATs, or a file's first
%% cluster's low word, set to a telling value.
mutation(Image, Reserved, FatSectors) ->
    Word = Reserved * ?SECTOR + 2 * rand:uniform(1023),
    case rand:uniform(3) of
        1 -> put16(Image, Word, telling());
        2 -> Value = telling(), put16(put16(Image, Word, Value), Word + FatSectors * ?SECTOR, Value);
        3 -> Offsets = maps:keys(erx_fat_alloc_tests:entries(Image)),
             put16(Image, lists:nth(rand:uniform(length(Offsets)), Offsets) + 26, telling())
    end.

telling() ->
    Values = {0, 1, 2, 3, 16#fff0, 16#fff7, 16#fff8, 16#ffff, rand:uniform(65536) - 1, 1 + rand:uniform(40)},
    element(rand:uniform(tuple_size(Values)), Values).

put16(Image, Offset, Value) ->
    <<Before:Offset/binary, _:16, After/binary>> = Image,
    <<Before/binary, Value:16/little, After/binary>>.
