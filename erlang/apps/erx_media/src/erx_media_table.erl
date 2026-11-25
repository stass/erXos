%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_table).
-moduledoc """
A drive's partition table, read as FreeBSD's GEOM reads it
(docs/design-drives.md, "The table"). read/2 is pure: it is handed the medium's
capacity in 512-byte sectors and the sectors read so far, and answers either
`{need, Sectors}`, the sectors it must see next (sector 0, then a GPT's headers
and arrays), or the table: `{Scheme, Volumes}` or `{refused, Finding}`. The medium's
reader asks again with the sectors added until it has the table. Every byte is
untrusted: each field is read by binary matching on a sector of exactly 512 bytes,
and every sum is an Erlang integer, so no crafted field wraps.

The rules, in the order they are tried:

1. **A GPT**, when sector 0 ends in `0x55 0xAA` and any of its four entries has
   type `0xEE`, whatever its status bytes hold (`g_part_gpt.c:899-905`). Such a
   medium is read as a GPT or refused; no later rule reads it. Its primary header
   is read at sector 1 and its backup at the primary's alternate when the
   primary's header passed, at the medium's last sector otherwise. The primary
   copy is taken when its header and its array pass, the backup otherwise, and
   when neither does the table is refused naming the primary's finding.
2. **A GPT's metadata**: the taken copy's usable area meets none of sector 0, both
   headers' sectors, the taken array and, when the other copy's header passed,
   its array, each compared as a range.
3. **An MBR**, when sector 0 ends in `0x55 0xAA`, every status byte is `0x00` or
   `0x80`, and its entries are not all zero over a plausible BIOS parameter block
   (`g_part_mbr.c:413-469`).
4. **An MBR's entries**: type `0x00`, or start or length 0, is skipped; an
   extended type is listed and not served; any other is volume N, its place.
5. **No table**: the medium is volume 1, sector 0 to its end.
6. **Integrity**: every listed entry runs forward, starts at or after the first
   usable sector, ends within the medium (a GPT: its usable area) and overlaps no
   other, or the table is refused whole (`g_part.c:325-436`).
7. **A bound**: the first `media_volumes_max` served entries in entry order are served;
   the rest are listed as `over_bound`.

place/3 is the one function that turns a volume's sector into a medium's sector.
Each finding leaves through one throw, `{erx_media_table, Answer}`, caught in
read/2; it makes no atom from the medium's bytes.
""".

-include("generated/erx_abi.hrl").

-export([read/2, place/3]).
-export_type([sectors/0, volume/0, finding/0, answer/0]).

%% The sector, sector 0's and the GPT's layouts are abi/formats/mbr.txt's and
%% abi/formats/gpt.txt's.
-define(SECTOR, ?ERX_MBR_SECTOR_SIZE).
-define(ENTRIES_BYTES, (?ERX_MBR_ENTRIES * ?ERX_MBR_ENTRY_SIZE)).
-define(EXTENDED, [?ERX_MBR_TYPE_EXTENDED, ?ERX_MBR_TYPE_EXTENDED_LBA, ?ERX_MBR_TYPE_EXTENDED_LINUX]).
-define(GUID_BYTES, 16).
-define(NAME_BYTES, (?ERX_GPT_ENTRY_SIZE - ?ERX_GPT_ENTRY_OFF_NAME)).

-type lba() :: non_neg_integer().
-type sectors() :: #{lba() => <<_:4096>>}.
-type serve() :: yes | extended | over_bound.
-type volume() :: #{number := pos_integer(), first := lba(), length := pos_integer(),
                    type := byte() | <<_:128>> | none, serve := serve(),
                    name => <<_:576>>, guid => <<_:128>>}.
-type copy() :: primary | backup.
-type finding() :: {gpt_header | gpt_array | gpt_metadata, copy()}
                 | {past_the_end | backwards | before_the_first_usable_sector, [pos_integer()]}
                 | {overlap, [pos_integer()]}.
-type answer() :: {need, [lba()]} | {mbr | gpt | none, [volume()]} | {refused, finding()}.

-record(medium, {last :: lba(), sectors :: sectors()}).
%% One of sector 0's four entries.
-record(slot, {number :: 1..4, status :: byte(), type :: byte(), start :: lba(), length :: non_neg_integer()}).
%% A GPT header that passed, in the fields the reader uses.
-record(header, {copy :: copy(), self :: lba(), alternate :: lba(), first :: lba(), last :: lba(),
                 table :: lba(), entries :: pos_integer(), entry_size :: pos_integer(),
                 array_crc :: non_neg_integer()}).
%% An entry the scheme lists, before integrity: its sectors, first to last inclusive.
-record(entry, {number :: pos_integer(), first :: lba(), last :: integer(), type :: byte() | <<_:128>>,
                serve :: yes | extended, name = none :: <<_:576>> | none, guid = none :: <<_:128>> | none}).

-doc """
The table of a medium of Capacity 512-byte sectors, from the sectors read so far.
""".
-spec read(non_neg_integer(), sectors()) -> answer().
read(0, _Sectors) ->
    {none, []};
read(Capacity, Sectors) when is_integer(Capacity), Capacity > 0, is_map(Sectors) ->
    Medium = #medium{last = Capacity - 1, sectors = Sectors},
    try
        scheme(sector(0, Medium), Medium)
    catch
        throw:{?MODULE, Answer} -> Answer
    end.

-doc """
The medium's sector for Count sectors from a volume's sector Sector, or `erange`
when the request reaches past the volume.
""".
-spec place(volume(), integer(), integer()) -> {ok, lba()} | {error, erange}.
place(#{first := First, length := Length}, Sector, Count)
  when is_integer(Sector), is_integer(Count), Sector >= 0, Count >= 1, Sector + Count =< Length ->
    {ok, First + Sector};
place(#{first := _, length := _}, _Sector, _Count) ->
    {error, erange}.

fail(Finding) -> throw({?MODULE, {refused, Finding}}).

%% The sectors Lbas, all of them read, or the ones not yet read asked for.
sectors(Lbas, #medium{sectors = Sectors}) ->
    case [Lba || Lba <- Lbas, not is_map_key(Lba, Sectors)] of
        [] -> [<<_:?SECTOR/binary>> = maps:get(Lba, Sectors) || Lba <- Lbas];
        Missing -> throw({?MODULE, {need, Missing}})
    end.

sector(Lba, Medium) ->
    [Sector] = sectors([Lba], Medium),
    Sector.

%% Rules 1, 3 and 5: which scheme sector 0 holds.
scheme(Sector = <<_:?ERX_MBR_ENTRIES_OFFSET/binary, Entries:?ENTRIES_BYTES/binary, ?ERX_MBR_SIGNATURE:16/little>>,
       Medium) ->
    Slots = slots(Entries),
    case {protective(Slots), mbr_table(Sector, Entries, Slots)} of
        {true, _} -> {gpt, gpt(Medium)};
        {false, true} -> {mbr, mbr(Slots, Medium)};
        {false, false} -> {none, whole(Medium)}
    end;
scheme(_Sector, Medium) ->
    {none, whole(Medium)}.

slots(Entries) ->
    [#slot{number = Number, status = u8(Entry, ?ERX_MBR_ENTRY_OFF_STATUS), type = u8(Entry, ?ERX_MBR_ENTRY_OFF_TYPE),
           start = u32(Entry, ?ERX_MBR_ENTRY_OFF_LBA_START), length = u32(Entry, ?ERX_MBR_ENTRY_OFF_LBA_SECTORS)}
     || {Number, Entry} <- lists:enumerate([Entry || <<Entry:?ERX_MBR_ENTRY_SIZE/binary>> <= Entries])].

protective(Slots) -> lists:any(fun(#slot{type = Type}) -> Type =:= ?ERX_MBR_TYPE_GPT_PROTECTIVE end, Slots).

mbr_table(Sector, Entries, Slots) ->
    lists:all(fun(#slot{status = Status}) -> Status =:= ?ERX_MBR_STATUS_INACTIVE orelse Status =:= ?ERX_MBR_STATUS_ACTIVE end,
              Slots)
        andalso not (Entries =:= <<0:(?ENTRIES_BYTES * 8)>> andalso plausible_bpb(Sector)).

%% The little-endian fields of a record whose length its reader matched.
u8(Record, Offset) -> binary:at(Record, Offset).
u32(Record, Offset) -> <<_:Offset/binary, Value:32/little, _/binary>> = Record, Value.
u64(Record, Offset) -> <<_:Offset/binary, Value:64/little, _/binary>> = Record, Value.

%% g_part_mbr.c:176-191: a bytes-per-sector field that is a power of two from 512 to
%% 4096 and a sectors-per-cluster field that is a power of two from 1 to 128.
plausible_bpb(<<_:11/binary, BytesPerSector:16/little, PerCluster, _/binary>>) ->
    power_of_two(BytesPerSector) andalso BytesPerSector >= 512 andalso BytesPerSector =< 4096
        andalso power_of_two(PerCluster) andalso PerCluster =< 128.

power_of_two(Value) -> Value > 0 andalso Value band (Value - 1) =:= 0.

whole(#medium{last = Last}) ->
    [#{number => 1, first => 0, length => Last + 1, type => none, serve => yes}].

%% Rule 4, then rules 6 and 7 with sector 1 as the first usable sector.
mbr(Slots, #medium{last = Last}) ->
    Listed = [#entry{number = Number, first = Start, last = Start + Length - 1, type = Type,
                     serve = case lists:member(Type, ?EXTENDED) of true -> extended; false -> yes end}
              || #slot{number = Number, type = Type, start = Start, length = Length} <- Slots,
                 Type =/= 0, Start =/= 0, Length =/= 0],
    served(integrity(Listed, 1, Last)).

%% Rules 1, 2, 6 and 7.
gpt(Medium) ->
    Primary = header(primary, 1, Medium),
    BackupLba = alternate(Primary, Medium),
    Backup = header(backup, BackupLba, Medium),
    {Taken, Array, Other} = taken(Primary, Backup, Medium),
    metadata(Taken, Other, BackupLba),
    Listed = gpt_entries(Array, Taken#header.entry_size, 1),
    served(integrity(Listed, Taken#header.first, Taken#header.last)).

alternate({ok, #header{alternate = Alternate}}, _Medium) -> Alternate;
alternate({error, _}, #medium{last = Last}) -> Last.

%% The copy taken: the primary when its header and its array pass, else the backup.
taken(Primary, Backup, Medium) ->
    case array(Primary, Medium) of
        {ok, PrimaryArray} ->
            {header_of(Primary), PrimaryArray, Backup};
        {error, Finding} ->
            case array(Backup, Medium) of
                {ok, BackupArray} -> {header_of(Backup), BackupArray, Primary};
                {error, _} -> fail({Finding, primary})
            end
    end.

header_of({ok, Header}) -> Header.

%% A header passes as the design lists its checks (g_part_gpt.c:441-542, with the
%% array bound erXos's own).
header(_Copy, Lba, #medium{last = Last}) when Lba > Last ->
    {error, gpt_header};
header(Copy, Lba, Medium = #medium{last = Last}) ->
    Sector = sector(Lba, Medium),
    Size = u32(Sector, ?ERX_GPT_HEADER_OFF_SIZE),
    Header = #header{copy = Copy, self = u64(Sector, ?ERX_GPT_HEADER_OFF_LBA_SELF),
                     alternate = u64(Sector, ?ERX_GPT_HEADER_OFF_LBA_ALT), first = u64(Sector, ?ERX_GPT_HEADER_OFF_LBA_START),
                     last = u64(Sector, ?ERX_GPT_HEADER_OFF_LBA_END), table = u64(Sector, ?ERX_GPT_HEADER_OFF_LBA_TABLE),
                     entries = u32(Sector, ?ERX_GPT_HEADER_OFF_ENTRIES),
                     entry_size = u32(Sector, ?ERX_GPT_HEADER_OFF_ENTRY_SIZE),
                     array_crc = u32(Sector, ?ERX_GPT_HEADER_OFF_CRC_TABLE)},
    #header{self = Self, alternate = Alternate, first = First, last = LastUsable, entries = Entries,
            entry_size = EntrySize} = Header,
    Passes = binary:part(Sector, ?ERX_GPT_HEADER_OFF_SIGNATURE, ?ERX_GPT_SIGNATURE_SIZE) =:= ?ERX_GPT_SIGNATURE_BYTES
        andalso Size >= ?ERX_GPT_HEADER_MIN andalso Size =< ?SECTOR
        andalso header_crc(Sector, Size) =:= u32(Sector, ?ERX_GPT_HEADER_OFF_CRC_SELF)
        andalso u32(Sector, ?ERX_GPT_HEADER_OFF_REVISION) >= ?ERX_GPT_REVISION
        andalso Self =:= Lba andalso Alternate =/= Self andalso Alternate =< Last
        andalso First >= 2 andalso First =< LastUsable andalso LastUsable < Last
        andalso Entries >= 1 andalso EntrySize >= ?ERX_GPT_ENTRY_MIN andalso EntrySize rem 8 =:= 0
        andalso Entries * EntrySize =< ?ERX_GPT_ARRAY_MAX
        andalso array_placed(Header, Last),
    case Passes of
        true -> {ok, Header};
        false -> {error, gpt_header}
    end.

%% The header's CRC-32 over its size, its own field read as zero.
header_crc(Sector, Size) ->
    <<Before:?ERX_GPT_HEADER_OFF_CRC_SELF/binary, _Crc:4/binary, After/binary>> = binary:part(Sector, 0, Size),
    erlang:crc32([Before, <<0:32>>, After]).

%% g_part_gpt.c:513-524: the array starts after sector 1, ends before the medium's
%% last sector, and neither its first nor its last sector lies in the usable area.
%% An array that encloses the usable area passes here; rule 2 refuses it.
array_placed(Header = #header{table = Table, first = First, last = LastUsable}, Last) ->
    ArrayLast = array_last(Header),
    Usable = fun(Lba) -> Lba >= First andalso Lba =< LastUsable end,
    Table >= 2 andalso ArrayLast < Last andalso not Usable(Table) andalso not Usable(ArrayLast).

array_bytes(#header{entries = Entries, entry_size = EntrySize}) -> Entries * EntrySize.

array_last(Header = #header{table = Table}) ->
    Table + (array_bytes(Header) + ?SECTOR - 1) div ?SECTOR - 1.

array({error, Finding}, _Medium) ->
    {error, Finding};
array({ok, Header = #header{table = Table, array_crc = Crc}}, Medium) ->
    Bytes = array_bytes(Header),
    Array = binary:part(iolist_to_binary(sectors(lists:seq(Table, array_last(Header)), Medium)), 0, Bytes),
    case erlang:crc32(Array) =:= Crc of
        true -> {ok, Array};
        false -> {error, gpt_array}
    end.

%% Rule 2: every sector the reader knows the GPT to occupy, as ranges.
metadata(#header{copy = Copy, first = First, last = Last} = Taken, Other, BackupLba) ->
    Known = [{0, 0}, {1, 1}, {BackupLba, BackupLba}, array_range(Taken) | other_array(Other)],
    lists:any(fun({From, To}) -> From =< Last andalso First =< To end, Known)
        andalso fail({gpt_metadata, Copy}).

other_array({ok, Header}) -> [array_range(Header)];
other_array({error, _}) -> [].

array_range(Header = #header{table = Table}) -> {Table, array_last(Header)}.

%% The array read through a cursor of EntrySize bytes; an all-zero type is unused.
gpt_entries(<<>>, _EntrySize, _Number) ->
    [];
gpt_entries(Array, EntrySize, Number) ->
    <<Entry:EntrySize/binary, Rest/binary>> = Array,
    case binary:part(Entry, ?ERX_GPT_ENTRY_OFF_TYPE, ?GUID_BYTES) of
        <<0:(?GUID_BYTES * 8)>> ->
            gpt_entries(Rest, EntrySize, Number + 1);
        Type ->
            [#entry{number = Number, first = u64(Entry, ?ERX_GPT_ENTRY_OFF_LBA_START),
                    last = u64(Entry, ?ERX_GPT_ENTRY_OFF_LBA_END), type = Type, serve = yes,
                    name = binary:part(Entry, ?ERX_GPT_ENTRY_OFF_NAME, ?NAME_BYTES),
                    guid = binary:part(Entry, ?ERX_GPT_ENTRY_OFF_UUID, ?GUID_BYTES)}
             | gpt_entries(Rest, EntrySize, Number + 1)]
    end.

%% Rule 6: each entry runs forward inside [FirstUsable, LastUsable], and no two
%% meet, compared over every pair so the entries' order cannot matter.
integrity(Listed, FirstUsable, LastUsable) ->
    lists:foreach(
      fun(#entry{number = Number, first = First, last = Last}) ->
              First =< Last orelse fail({backwards, [Number]}),
              First >= FirstUsable orelse fail({before_the_first_usable_sector, [Number]}),
              Last =< LastUsable orelse fail({past_the_end, [Number]})
      end, Listed),
    Overlaps = [[A, B] || #entry{number = A, first = FirstA, last = LastA} <- Listed,
                          #entry{number = B, first = FirstB, last = LastB} <- Listed,
                          A < B, FirstA =< LastB andalso FirstB =< LastA],
    case Overlaps of
        [] -> Listed;
        [Pair | _] -> fail({overlap, Pair})
    end.

%% Rule 7, and each entry as the volume it lists.
served(Listed) ->
    {Volumes, _Served} = lists:mapfoldl(fun volume/2, 0, Listed),
    Volumes.

volume(#entry{serve = extended} = Entry, Served) ->
    {volume_map(Entry, extended), Served};
volume(Entry, Served) when Served < ?ERX_MEDIA_VOLUMES_MAX ->
    {volume_map(Entry, yes), Served + 1};
volume(Entry, Served) ->
    {volume_map(Entry, over_bound), Served}.

volume_map(#entry{number = Number, first = First, last = Last, type = Type, name = Name, guid = Guid}, Serve) ->
    Volume = #{number => Number, first => First, length => Last - First + 1, type => Type, serve => Serve},
    case Name of
        none -> Volume;
        _ -> Volume#{name => Name, guid => Guid}
    end.
