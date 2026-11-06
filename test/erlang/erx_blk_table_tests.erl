%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_blk_table, the boot medium's partition table and a window's check
%% (test/host/erx_blk_table_test.rb runs them). The records are built here from the PC
%% partition table's published format, with its offsets written out rather than taken
%% from erx_abi.hrl, so a wrong offset in the ABI file fails these cases; the layout's
%% sectors come from erx_abi.hrl, the layout's one source.

-module(erx_blk_table_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(EXTRA, 4096).
-define(DATA, (?ERX_MEDIUM_DATA_SECTORS_MIN + ?EXTRA)).
-define(CAPACITY, (?ERX_MEDIUM_DATA_START + ?DATA)).

%% A record: 446 bytes the reader ignores, four 16-byte entries, the signature 55 aa.
record(Entries) ->
    Padded = Entries ++ lists:duplicate(4 - length(Entries), {0, 0, 0, 0}),
    <<(binary:copy(<<16#e5>>, 446))/binary,
      << <<Status:8, 16#fe, 16#ff, 16#ff, Type:8, 16#fe, 16#ff, 16#ff, Start:32/little, Count:32/little>>
         || {Status, Type, Start, Count} <- Padded >>/binary,
      16#55, 16#aa>>.

%% The good table of a medium whose data partition has Data sectors.
table(Data) ->
    End = ?ERX_MEDIUM_DATA_START + Data,
    #{mbr => [{0, ?ERX_MEDIUM_RECORD_TYPE, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
              {0, ?ERX_MEDIUM_SLOT_TYPE, ?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS},
              {0, ?ERX_MEDIUM_SLOT_TYPE, ?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS},
              {0, ?ERX_MEDIUM_EXTENDED_TYPE, ?ERX_MEDIUM_EXTENDED_START, End - ?ERX_MEDIUM_EXTENDED_START}],
      vault_ebr => [{0, ?ERX_MEDIUM_VAULT_TYPE, ?ERX_MEDIUM_VAULT_START - ?ERX_MEDIUM_EXTENDED_START,
                     ?ERX_MEDIUM_VAULT_SECTORS},
                    {0, ?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_DATA_EBR - ?ERX_MEDIUM_EXTENDED_START,
                     End - ?ERX_MEDIUM_DATA_EBR}],
      data_ebr => [{0, ?ERX_MEDIUM_DATA_TYPE, ?ERX_MEDIUM_DATA_START - ?ERX_MEDIUM_DATA_EBR, Data}]}.

admit(Capacity, Table) ->
    erx_blk_table:admit(Capacity, record(maps:get(mbr, Table)), record(maps:get(vault_ebr, Table)),
                        record(maps:get(data_ebr, Table))).

windows(Data) ->
    [{record, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
     {slot_a, ?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS},
     {slot_b, ?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS},
     {vault, ?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
     {data, ?ERX_MEDIUM_DATA_START, Data}].

good_table_is_admitted_test() ->
    ?assertEqual({ok, windows(?DATA)}, admit(?CAPACITY, table(?DATA))).

data_partition_may_end_before_the_medium_test() ->
    ?assertEqual({ok, windows(?ERX_MEDIUM_DATA_SECTORS_MIN)},
                 admit(?CAPACITY, table(?ERX_MEDIUM_DATA_SECTORS_MIN))).

data_partition_past_the_medium_is_refused_test() ->
    ?assertEqual({error, {data_ebr, 1, sectors}}, admit(?CAPACITY, table(?DATA + 1))).

data_partition_below_the_minimum_is_refused_test() ->
    ?assertEqual({error, {data_ebr, 1, sectors}}, admit(?CAPACITY, table(?ERX_MEDIUM_DATA_SECTORS_MIN - 1))).

medium_below_the_layout_is_refused_test() ->
    Small = erx_blk_table:minimum_sectors() - 1,
    ?assertEqual({error, {capacity, Small}}, admit(Small, table(?ERX_MEDIUM_DATA_SECTORS_MIN))),
    ?assertEqual({error, {capacity, nonsense}}, admit(nonsense, table(?DATA))),
    ?assertEqual(ok, erx_blk_table:check_capacity(erx_blk_table:minimum_sectors())).

records_are_where_the_layout_puts_them_test() ->
    ?assertEqual([{mbr, 0}, {vault_ebr, ?ERX_MEDIUM_EXTENDED_START}, {data_ebr, ?ERX_MEDIUM_DATA_EBR}],
                 erx_blk_table:records()).

%% Every field of every entry, changed alone, is refused with that record, entry and field;
%% the first differing field in status, type, start, sectors order is the one named.
every_field_is_checked_test_() ->
    Good = table(?DATA),
    [?_assertEqual({error, {Name, Index, Field}}, admit(?CAPACITY, change(Good, Name, Index, Field)))
     || Name <- [mbr, vault_ebr, data_ebr], Index <- [1, 2, 3, 4], Field <- [status, type, start, sectors],
        not (Name =:= data_ebr andalso Index =:= 1 andalso Field =:= sectors)].

change(Table, Name, Index, Field) ->
    Entries = maps:get(Name, Table),
    Full = Entries ++ lists:duplicate(4 - length(Entries), {0, 0, 0, 0}),
    {Status, Type, Start, Count} = lists:nth(Index, Full),
    Changed = case Field of
                  status -> {16#80, Type, Start, Count};
                  type -> {Status, Type bxor 1, Start, Count};
                  start -> {Status, Type, Start + 1, Count};
                  sectors -> {Status, Type, Start, Count + 1}
              end,
    Table#{Name := lists:sublist(Full, Index - 1) ++ [Changed] ++ lists:nthtail(Index, Full)}.

%% A link that names a third record is refused: no chain is followed.
a_chain_past_two_records_is_refused_test() ->
    Good = table(?DATA),
    Linked = Good#{data_ebr := maps:get(data_ebr, Good) ++ [{0, ?ERX_MEDIUM_LINK_TYPE, 1, 1}]},
    ?assertEqual({error, {data_ebr, 2, type}}, admit(?CAPACITY, Linked)).

bad_records_are_refused_test() ->
    Good = table(?DATA),
    Mbr = record(maps:get(mbr, Good)),
    Vault = record(maps:get(vault_ebr, Good)),
    Data = record(maps:get(data_ebr, Good)),
    Unsigned = <<(binary:part(Vault, 0, 510))/binary, 16#aa, 16#55>>,
    ?assertEqual({error, {vault_ebr, signature}}, erx_blk_table:admit(?CAPACITY, Mbr, Unsigned, Data)),
    ?assertEqual({error, {mbr, size}}, erx_blk_table:admit(?CAPACITY, binary:part(Mbr, 0, 511), Vault, Data)),
    ?assertEqual({error, {mbr, size}}, erx_blk_table:admit(?CAPACITY, <<Mbr/binary, 0>>, Vault, Data)),
    ?assertEqual({error, {data_ebr, size}}, erx_blk_table:admit(?CAPACITY, Mbr, Vault, not_a_sector)),
    ?assertEqual({error, {mbr, size}}, erx_blk_table:admit(?CAPACITY, <<>>, Vault, Data)).

%% The layout itself: partitions in medium order, none overlapping another or a record,
%% each boundary on 1 MiB, every sector the MBR can address, and the MBR's entries ending
%% where its signature starts.
layout_is_consistent_test() ->
    Spans = [{0, 1}, {?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
             {?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS}, {?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS},
             {?ERX_MEDIUM_EXTENDED_START, 1}, {?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
             {?ERX_MEDIUM_DATA_EBR, 1}, {?ERX_MEDIUM_DATA_START, ?ERX_MEDIUM_DATA_SECTORS_MIN}],
    lists:foreach(fun({{Start, Count}, {Next, _}}) -> ?assert(Start + Count =< Next) end,
                  lists:zip(lists:droplast(Spans), tl(Spans))),
    ?assert(lists:all(fun({Start, _}) -> Start rem 2048 =:= 0 end, tl(Spans))),
    ?assert(?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN < 1 bsl 32),
    ?assertEqual(446, ?ERX_MBR_ENTRIES_OFFSET),
    ?assertEqual(510, ?ERX_MBR_SIGNATURE_OFFSET),
    ?assertEqual(?ERX_MBR_SIGNATURE_OFFSET, ?ERX_MBR_ENTRIES_OFFSET + ?ERX_MBR_ENTRIES * ?ERX_MBR_ENTRY_SIZE).

place_test_() ->
    Window = {vault, 1000, 10},
    [?_assertEqual({ok, 1000}, erx_blk_table:place(Window, 0, 1)),
     ?_assertEqual({ok, 1009}, erx_blk_table:place(Window, 9, 1)),
     ?_assertEqual({ok, 1002}, erx_blk_table:place(Window, 2, 8)),
     ?_assertEqual({error, erange}, erx_blk_table:place(Window, 10, 1)),
     ?_assertEqual({error, erange}, erx_blk_table:place(Window, 9, 2)),
     ?_assertEqual({error, erange}, erx_blk_table:place(Window, 1 bsl 70, 1)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, 0, 0)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, -1, 1)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, 0, one)),
     ?_assertEqual({error, einval}, erx_blk_table:place(Window, 1.0, 1))].
