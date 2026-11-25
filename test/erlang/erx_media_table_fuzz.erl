%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the partition table's reader, erx_media_table
%% (docs/design-drives.md, "Fuzz targets"). Its seeds are the media
%% erx_media_table_cases:seeds/0 writes: MBRs, a FAT boot sector and GPTs. A round
%% takes one, mutates its capacity, sector 0's entries, the GPT headers' fields and the
%% arrays' entries (bytes flipped, fields set to random or telling values: 0, 1, the
%% medium's last sector and its neighbours, the largest 32- and 64-bit values), mends
%% the CRCs of the headers it can in half the rounds so the checks past them are
%% reached, and reads the table. Whatever the medium holds, the reader never raises and
%% makes no atom, asks only for sectors of the medium and at most five times, and
%% every volume it serves lies inside the medium, apart from every sector the reader
%% read and from every other served volume, and place/3 keeps each request inside its
%% volume. The seed comes from make check-fuzz.

-module(erx_media_table_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(MIN_ACCEPTED, ?ROUNDS div 100).
-define(SECTOR, 512).
-define(HEADER_FIELDS, [{8, 32}, {12, 32}, {24, 64}, {32, 64}, {40, 64}, {48, 64}, {72, 64}, {80, 32}, {84, 32}]).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Seeds = erx_media_table_cases:seeds(),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Accepted = lists:sum([round_of(lists:nth(rand:uniform(length(Seeds)), Seeds)) || _ <- lists:seq(1, ?ROUNDS)]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of({SeedCapacity, SeedImage}) ->
    Capacity = capacity(SeedCapacity),
    Mutated = lists:foldl(fun(_, Image) -> mutate(Image, Capacity) end, SeedImage,
                          lists:seq(1, rand:uniform(6))),
    Image = case rand:uniform(2) of
                1 -> mend(Mutated);
                2 -> Mutated
            end,
    Atoms = erlang:system_info(atom_count),
    {Answer, Read} = try
                         erx_media_table_cases:read_sectors(Capacity, Image)
                     catch
                         Class:Reason:Stack -> error({raised, Class, Reason, Stack})
                     end,
    Atoms =:= erlang:system_info(atom_count) orelse error({made_an_atom, Answer}),
    check(Answer, Capacity, Read).

capacity(Seed) ->
    case rand:uniform(6) of
        1 -> max(1, Seed - rand:uniform(64));
        2 -> Seed + rand:uniform(64);
        3 -> rand:uniform(1 bsl 40);
        _ -> Seed
    end.

mutate(Image, Capacity) ->
    Last = Capacity - 1,
    case rand:uniform(4) of
        1 -> flip(Image);
        2 -> {Offset, Bits} = lists:nth(rand:uniform(4), [{0, 8}, {4, 8}, {8, 32}, {12, 32}]),
             field(Image, 0, 446 + 16 * (rand:uniform(4) - 1) + Offset, Bits, Last);
        3 -> header_field(Image, Last);
        4 -> entry_field(Image, Last)
    end.

flip(Image) ->
    Lba = lists:nth(rand:uniform(maps:size(Image)), maps:keys(Image)),
    Offset = rand:uniform(?SECTOR) - 1,
    <<Before:Offset/binary, Byte, After/binary>> = maps:get(Lba, Image),
    Image#{Lba := <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>}.

header_field(Image, Last) ->
    case [Lba || Lba := <<"EFI PART", _/binary>> <- Image] of
        [] -> Image;
        Headers ->
            {Offset, Bits} = lists:nth(rand:uniform(length(?HEADER_FIELDS)), ?HEADER_FIELDS),
            field(Image, lists:nth(rand:uniform(length(Headers)), Headers), Offset, Bits, Last)
    end.

%% An entry's first or last sector, in a sector of an array.
entry_field(Image, Last) ->
    case [Lba || Lba := <<"erxos test type!", _/binary>> <- Image] of
        [] -> Image;
        Arrays ->
            field(Image, lists:nth(rand:uniform(length(Arrays)), Arrays),
                  128 * (rand:uniform(4) - 1) + element(rand:uniform(2), {32, 40}), 64, Last)
    end.

field(Image, Lba, Offset, Bits, Last) ->
    Value = element(rand:uniform(9), {0, 1, 2, Last - 1, Last, Last + 1, (1 bsl Bits) - 1,
                                      rand:uniform(1 bsl Bits) - 1, rand:uniform(Last + 2) - 1}),
    Bytes = Bits div 8,
    Sector = maps:get(Lba, Image, <<0:(?SECTOR * 8)>>),
    <<Before:Offset/binary, _:Bytes/binary, After/binary>> = Sector,
    Image#{Lba => <<Before/binary, (Value band ((1 bsl Bits) - 1)):Bits/little, After/binary>>}.

%% Each header's array CRC from the array it names, then its own CRC, where its size
%% and its array's allow.
mend(Image) ->
    maps:fold(fun(Lba, <<"EFI PART", _/binary>> = Header, Acc) -> Acc#{Lba := mended(Header, Acc)};
                 (_, _, Acc) -> Acc
              end, Image, Image).

mended(<<Head:12/binary, Size:32/little, _:32, Rest:60/binary, Entries:32/little, EntrySize:32/little,
         ArrayCrc:32/little, Tail/binary>>, Image) when Size >= 92, Size =< ?SECTOR ->
    <<_:52/binary, Table:64/little, _/binary>> = Rest,
    Bytes = Entries * EntrySize,
    Crc = case Bytes > 0 andalso Bytes =< 16384 of
              true ->
                  Sectors = [maps:get(Lba, Image, <<0:(?SECTOR * 8)>>)
                             || Lba <- lists:seq(Table, Table + (Bytes + ?SECTOR - 1) div ?SECTOR - 1)],
                  erlang:crc32(binary:part(iolist_to_binary(Sectors), 0, Bytes));
              false ->
                  ArrayCrc
          end,
    Zeroed = <<Head/binary, Size:32/little, 0:32, Rest/binary, Entries:32/little, EntrySize:32/little,
               Crc:32/little, Tail/binary>>,
    <<Before:16/binary, _:32, After/binary>> = Zeroed,
    <<Before/binary, (erlang:crc32(binary:part(Zeroed, 0, Size))):32/little, After/binary>>;
mended(Header, _Image) ->
    Header.

%% Read is every sector the reader read, each one the table occupies, so no served
%% volume holds one.
check({refused, _}, _Capacity, _Read) ->
    0;
check({none, [#{number := 1, first := 0, length := Capacity, serve := yes}]}, Capacity, _Read) ->
    0;
check({Scheme, Volumes}, Capacity, Read) when Scheme =:= mbr; Scheme =:= gpt ->
    Served = [{First, First + Length - 1, Volume}
              || Volume = #{first := First, length := Length, serve := yes} <- Volumes],
    length(Served) =< 8 orelse error({served_too_many, Volumes}),
    [error({served_outside, Volume}) || {First, Last, Volume} <- Served, First < 1 orelse Last >= Capacity],
    [error({served_overlapping, A, B}) || {FirstA, LastA, A} <- Served, {FirstB, LastB, B} <- Served,
                                         A =/= B, FirstA =< LastB, FirstB =< LastA],
    [error({served_metadata, Volume, Lba}) || {First, Last, Volume} <- Served, Lba <- Read, Lba >= First, Lba =< Last],
    [placed(Volume, First, Last) || {First, Last, Volume} <- Served],
    case Served of
        [] -> 0;
        _ -> 1
    end;
check(Answer, Capacity, _Read) ->
    error({unexpected_answer, Capacity, Answer}).

placed(Volume, First, Last) ->
    Offset = rand:uniform(Last - First + 3) - 2,
    Count = rand:uniform(4) - 1,
    case erx_media_table:place(Volume, Offset, Count) of
        {ok, Sector} when Sector >= First, Sector + Count - 1 =< Last, Count >= 1 -> ok;
        {error, erange} when Offset < 0; Count < 1; Offset + Count - 1 > Last - First -> ok;
        Placed -> error({placed_outside, Volume, Offset, Count, Placed})
    end.
