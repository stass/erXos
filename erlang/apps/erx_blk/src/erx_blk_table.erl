%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The boot medium's partition table, parsed and admitted (docs/design-storage.md, "The
%% boot medium's table"): the block driver's pure core for its partition process,
%% erx_blk_service, which reads the three sectors records/0 names and hands them here.
%%
%% The table is the master boot record and exactly two extended boot records, at sectors
%% the medium layout of the ABI file fixes (abi/medium.txt, through erx_abi.hrl). admit/4
%% builds the table the layout prescribes and compares the medium's three records with
%% it entry for entry and field for field: status, type, start and length. One value is
%% the medium's to choose, the data partition's length, read from the data partition's
%% record: it must be at least the layout's minimum and end within the medium, and the
%% extended partition's length and the vault record's link length follow from it. No
%% chain is followed: the extended boot records are read where the layout puts them,
%% whatever their link entries say, and a link entry that names anything else is refused.
%% The cylinder-head-sector fields, and the bytes before the entries, are not read.
%%
%% Every value comes from a binary match on a sector of exactly the format's size, so a
%% short, long or non-binary record is refused with a reason, never a crash; the reasons
%% are a closed set of atoms and the medium's capacity, an integer the device reported.
%% place/3 is a window's check of a request against its sectors.

-module(erx_blk_table).

-export([records/0, minimum_sectors/0, check_capacity/1, admit/4, place/3]).
-export_type([role/0, window/0, record_name/0, reason/0]).

-include("generated/erx_abi.hrl").

-type role() :: record | slot_a | slot_b | vault | data.
%% A window: its role, its first sector on the medium and its length in sectors.
-type window() :: {role(), non_neg_integer(), pos_integer()}.
-type record_name() :: mbr | vault_ebr | data_ebr.
-type field() :: status | type | start | sectors.
-type reason() :: {capacity, term()}
                | {record_name(), size | signature}
                | {record_name(), 1..4, field()}.
%% One entry as the table holds it: status, type, start and length.
-type entry() :: {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}.

%% The three records of the table and their sectors, in the order admit/4 takes them.
-spec records() -> [{record_name(), non_neg_integer()}].
records() ->
    [{mbr, 0}, {vault_ebr, ?ERX_MEDIUM_EXTENDED_START}, {data_ebr, ?ERX_MEDIUM_DATA_EBR}].

%% The fewest sectors a medium laid out by the layout has: through the data partition's
%% minimum length.
-spec minimum_sectors() -> pos_integer().
minimum_sectors() -> ?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN.

%% ok when a medium of Capacity sectors can hold the layout, so its records can be read.
-spec check_capacity(term()) -> ok | {error, reason()}.
check_capacity(Capacity) when is_integer(Capacity), Capacity >= ?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN ->
    ok;
check_capacity(Capacity) ->
    {error, {capacity, Capacity}}.

%% The windows of a medium of Capacity sectors whose records/0 sectors hold Mbr, VaultEbr
%% and DataEbr, or the first way the table differs from the layout.
-spec admit(term(), term(), term(), term()) -> {ok, [window()]} | {error, reason()}.
admit(Capacity, Mbr, VaultEbr, DataEbr) ->
    maybe
        ok ?= check_capacity(Capacity),
        {ok, MbrEntries} ?= entries(mbr, Mbr),
        {ok, VaultEntries} ?= entries(vault_ebr, VaultEbr),
        {ok, DataEntries} ?= entries(data_ebr, DataEbr),
        {ok, DataSectors} ?= data_sectors(Capacity, DataEntries),
        Expected = expected(DataSectors),
        ok ?= compare(mbr, MbrEntries, maps:get(mbr, Expected)),
        ok ?= compare(vault_ebr, VaultEntries, maps:get(vault_ebr, Expected)),
        ok ?= compare(data_ebr, DataEntries, maps:get(data_ebr, Expected)),
        {ok, [{record, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
              {slot_a, ?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS},
              {slot_b, ?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS},
              {vault, ?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
              {data, ?ERX_MEDIUM_DATA_START, DataSectors}]}
    end.

%% The medium's first sector of a request for Count sectors from Sector of Window: einval
%% for a request that names no sectors, erange for one that leaves the window.
-spec place(window(), term(), term()) -> {ok, non_neg_integer()} | {error, einval | erange}.
place({_Role, Start, Sectors}, Sector, Count)
  when is_integer(Sector), is_integer(Count), Sector >= 0, Count >= 1 ->
    case Sector + Count =< Sectors of
        true -> {ok, Start + Sector};
        false -> {error, erange}
    end;
place(_Window, _Sector, _Count) ->
    {error, einval}.

%% The four entries of a record of exactly one sector that ends in the signature.
entries(Name, Sector) when is_binary(Sector), byte_size(Sector) =:= ?ERX_MBR_SECTOR_SIZE ->
    <<_:?ERX_MBR_ENTRIES_OFFSET/binary, Entries:(?ERX_MBR_ENTRIES * ?ERX_MBR_ENTRY_SIZE)/binary, _/binary>> = Sector,
    <<_:?ERX_MBR_SIGNATURE_OFFSET/binary, Signature:16/little, _/binary>> = Sector,
    case Signature of
        ?ERX_MBR_SIGNATURE -> {ok, [entry(Entry) || <<Entry:?ERX_MBR_ENTRY_SIZE/binary>> <= Entries]};
        _ -> {error, {Name, signature}}
    end;
entries(Name, _Sector) ->
    {error, {Name, size}}.

entry(Entry) ->
    <<_:?ERX_MBR_ENTRY_OFF_STATUS/binary, Status:8, _/binary>> = Entry,
    <<_:?ERX_MBR_ENTRY_OFF_TYPE/binary, Type:8, _/binary>> = Entry,
    <<_:?ERX_MBR_ENTRY_OFF_LBA_START/binary, Start:32/little, _/binary>> = Entry,
    <<_:?ERX_MBR_ENTRY_OFF_LBA_SECTORS/binary, Sectors:32/little, _/binary>> = Entry,
    {Status, Type, Start, Sectors}.

%% The data partition's length, the one value the medium chooses: from the layout's
%% minimum to the medium's end. Its record's other fields are compared with the rest.
data_sectors(Capacity, [{_Status, _Type, _Start, Sectors} | _]) ->
    case Sectors >= ?ERX_MEDIUM_DATA_SECTORS_MIN andalso ?ERX_MEDIUM_DATA_START + Sectors =< Capacity of
        true -> {ok, Sectors};
        false -> {error, {data_ebr, 1, sectors}}
    end.

%% The table the layout prescribes for a data partition of DataSectors sectors. An extended
%% boot record's first entry starts relative to the record's own sector, and its link
%% entry relative to the extended partition's start, and spans the next record and its
%% logical partition.
-spec expected(pos_integer()) -> #{record_name() := [entry()]}.
expected(DataSectors) ->
    DataEnd = ?ERX_MEDIUM_DATA_START + DataSectors,
    #{mbr => [used(?ERX_MEDIUM_RECORD_TYPE, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS),
              used(?ERX_MEDIUM_SLOT_TYPE, ?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS),
              used(?ERX_MEDIUM_SLOT_TYPE, ?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS),
              used(?ERX_MEDIUM_EXTENDED_TYPE, ?ERX_MEDIUM_EXTENDED_START, DataEnd - ?ERX_MEDIUM_EXTENDED_START)],
      vault_ebr => [used(?ERX_MEDIUM_VAULT_TYPE, ?ERX_MEDIUM_VAULT_START - ?ERX_MEDIUM_EXTENDED_START,
                         ?ERX_MEDIUM_VAULT_SECTORS),
                    used(?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_DATA_EBR - ?ERX_MEDIUM_EXTENDED_START,
                         DataEnd - ?ERX_MEDIUM_DATA_EBR),
                    unused(), unused()],
      data_ebr => [used(?ERX_MEDIUM_DATA_TYPE, ?ERX_MEDIUM_DATA_START - ?ERX_MEDIUM_DATA_EBR, DataSectors),
                   unused(), unused(), unused()]}.

used(Type, Start, Sectors) -> {?ERX_MBR_STATUS_INACTIVE, Type, Start, Sectors}.

unused() -> {?ERX_MBR_STATUS_INACTIVE, ?ERX_MBR_TYPE_EMPTY, 0, 0}.

%% ok when every entry equals the layout's, or the first entry and field that do not.
compare(Name, Entries, Expected) ->
    Differences = [{Name, Index, field(Entry, Want)}
                   || {Index, Entry, Want} <- lists:zip3(lists:seq(1, length(Expected)), Entries, Expected),
                      Entry =/= Want],
    case Differences of
        [] -> ok;
        [First | _] -> {error, First}
    end.

field({Status, _, _, _}, {Want, _, _, _}) when Status =/= Want -> status;
field({_, Type, _, _}, {_, Want, _, _}) when Type =/= Want -> type;
field({_, _, Start, _}, {_, _, Want, _}) when Start =/= Want -> start;
field(_Entry, _Want) -> sectors.
