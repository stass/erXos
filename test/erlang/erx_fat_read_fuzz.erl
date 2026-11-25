%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the record volume's reader, erx_fat_read:root_file/3
%% (docs/design-ssh.md, "Verification"). Its seeds are the volumes
%% test/fixtures/fat_record_volume.rb writes into the directory it is given. A round
%% takes one, mutates its boot sector, FAT entries, root directory entries and data
%% (bytes flipped, 16-bit fields set to random or telling values: free, bad, end of
%% chain, the data area's edges, the record's erase unit), and reads authorized_keys
%% from it. Whatever the volume holds, the reader never raises and makes no atom, reads
%% no sector outside the record partition and at most 32 data sectors, and answers either at most 16 KiB or a finding of the closed
%% set; an unmutated seed answers the bytes the fixture wrote for it. The seed comes
%% from make check-fuzz.

-module(erx_fat_read_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 100).
-define(SECTOR, 512).
-define(MAX, 16384).
-define(NAME, <<"authorized_keys">>).
-define(FINDINGS, [not_its_volume, not_found, too_long, does_not_read, read_failed]).

run([Seed, Directory]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Volumes = [volume(Directory, Image) || Image <- filelib:wildcard("*.img", Directory)],
    Volumes =/= [] orelse error(no_seed_volumes),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Accepted = lists:sum([round_of(lists:nth(rand:uniform(length(Volumes)), Volumes))
                          || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

%% A seed: its sectors that are not zero, and the file it must answer, if any.
volume(Directory, Image) ->
    {ok, Bytes} = file:read_file(filename:join(Directory, Image)),
    Sectors = maps:from_list([{Index, Sector} || Index <- lists:seq(0, byte_size(Bytes) div ?SECTOR - 1),
                                                  Sector <- [binary:part(Bytes, Index * ?SECTOR, ?SECTOR)],
                                                  Sector =/= <<0:(?SECTOR * 8)>>]),
    File = case file:read_file(filename:join(Directory, filename:rootname(Image) ++ ".file")) of
               {ok, Contents} -> {ok, Contents};
               {error, enoent} -> unknown
           end,
    {Sectors, File}.

%% 1 when the reader answered a file.
round_of({Seed, File}) ->
    {Sectors, Mutated} = case rand:uniform(8) of
                             1 -> {Seed, false};
                             _ -> {mutated(Seed, rand:uniform(6)), true}
                         end,
    put(data_reads, 0),
    Atoms = erlang:system_info(atom_count),
    Said = try erx_fat_read:root_file(reader(Sectors), ?NAME, ?MAX)
           catch Class:Reason -> error({raised, Class, Reason, changed(Seed, Sectors)}) end,
    erlang:system_info(atom_count) =:= Atoms orelse error(atoms_made),
    get(data_reads) =< ?MAX div ?SECTOR orelse error({data_reads, get(data_reads), changed(Seed, Sectors)}),
    case Said of
        {ok, Bytes} when byte_size(Bytes) =< ?MAX -> ok;
        {error, Finding} -> lists:member(Finding, ?FINDINGS) orelse error({unknown_finding, Finding});
        _ -> error({unknown_answer, Said})
    end,
    Mutated orelse File =:= unknown orelse Said =:= File orelse error({seed_misread, Said}),
    case Said of
        {ok, _} -> 1;
        _ -> 0
    end.

%% The window's read, which refuses nothing inside the partition; a read outside it
%% raises, since the reader must never ask for one.
reader(Sectors) ->
    fun(Index) when Index >= 0, Index < ?ERX_MEDIUM_RECORD_SECTORS ->
            Index >= ?ERX_MEDIUM_RECORD_SELECT_START andalso put(data_reads, get(data_reads) + 1),
            {ok, maps:get(Index, Sectors, <<0:(?SECTOR * 8)>>)};
       (Index) ->
            error({outside_the_partition, Index})
    end.

%% The sectors a round changed, for its report.
changed(Seed, Sectors) -> maps:filter(fun(Index, Sector) -> maps:get(Index, Seed, none) =/= Sector end, Sectors).

mutated(Sectors, 0) -> Sectors;
mutated(Sectors, Left) ->
    %% The boot sector an eighth of the time, else any sector the seed holds.
    Indexes = maps:keys(Sectors),
    Index = case Indexes =/= [] andalso rand:uniform(8) > 1 of
                true -> lists:nth(rand:uniform(length(Indexes)), Indexes);
                false -> 0
            end,
    Sector = maps:get(Index, Sectors, <<0:(?SECTOR * 8)>>),
    mutated(Sectors#{Index => mutated_sector(Sector)}, Left - 1).

mutated_sector(Sector) ->
    At = rand:uniform(?SECTOR div 2) * 2 - 2,
    <<Before:At/binary, Word:16/little, After/binary>> = Sector,
    New = case rand:uniform(4) of
              1 -> Word bxor (1 bsl (rand:uniform(16) - 1));
              2 -> rand:uniform(16#10000) - 1;
              _ -> telling()
          end,
    <<Before/binary, New:16/little, After/binary>>.

%% Values a FAT entry, a first cluster or a BPB field tends to break on.
telling() ->
    Data = ?ERX_MEDIUM_RECORD_SECTORS - ?ERX_MEDIUM_RECORD_SELECT_START,
    Region = ?ERX_MEDIUM_ERASE_SECTORS,
    element(rand:uniform(12), {0, 1, 2, 3, Region + 1, Region + 2, Data, Data + 1, Data + 2,
                               16#fff7, 16#fff8, 16#ffff}).
