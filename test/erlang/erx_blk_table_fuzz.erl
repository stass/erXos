%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Random partition tables through erx_blk_table:admit/4, the block driver's parse of the
%% boot medium's master and extended boot records, and random requests through place/3.
%% Each round starts from the table the layout prescribes for a random data partition on
%% a medium of random capacity, both clustered at their bounds, and changes none, one or
%% several things: an entry's field, set to a neighbour of its value, zero, all ones or
%% another layout value; a byte anywhere in a record; a record's size; or a record that is
%% not a binary. Whatever arrives, admit/4 answers {ok, Windows} or {error, Reason} with
%% Reason one of its fixed shapes, never a crash, and agrees with reference/4: a model of
%% the same rule written from the PC partition table's published format, with its offsets
%% written out rather than taken from erx_abi.hrl, so a wrong offset in the ABI file or a
%% check the parser drops shows as a disagreement. Every admitted set of windows lies
%% within the medium, overlaps no other window and no record of the table. The seed comes
%% from make check-fuzz.

-module(erx_blk_table_fuzz).
-export([run/1]).

-include("generated/erx_abi.hrl").

-define(ROUNDS, 20000).
%% The fewest rounds that must admit a table, so a change to the generator cannot leave the
%% accepting path untried.
-define(MIN_ACCEPTED, ?ROUNDS div 20).
-define(MIN_DATA, ?ERX_MEDIUM_DATA_SECTORS_MIN).
-define(MIN_MEDIUM, (?ERX_MEDIUM_DATA_START + ?ERX_MEDIUM_DATA_SECTORS_MIN)).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    Accepted = length([ok || _ <- lists:seq(1, ?ROUNDS), round_of() =:= accepted]),
    case Accepted >= ?MIN_ACCEPTED of
        true -> io:format("fuzz: ~p rounds ok, ~p accepted~n", [?ROUNDS, Accepted]);
        false -> error({too_few_accepted, Accepted})
    end.

round_of() ->
    check_place(),
    Capacity = pick([?MIN_MEDIUM - 1, ?MIN_MEDIUM, ?MIN_MEDIUM + rand:uniform(1 bsl 20),
                     (1 bsl 32) + rand:uniform(1 bsl 20), rand:uniform(?MIN_MEDIUM)]),
    Room = max(Capacity - ?ERX_MEDIUM_DATA_START, 1),
    Data = pick([?MIN_DATA, ?MIN_DATA - 1, Room, Room + 1, min(Room, (1 bsl 32) - 1),
                 ?MIN_DATA + rand:uniform(1 bsl 20)]) band 16#ffffffff,
    Entries = mutate_entries(good(Data), rand:uniform(4) - 1),
    Records = mutate_records([encode(Entry) || Entry <- Entries], rand:uniform(8) - 6),
    [Mbr, Vault, DataEbr] = Records,
    Said = erx_blk_table:admit(Capacity, Mbr, Vault, DataEbr),
    shape(Said),
    case {Said, reference(Capacity, Mbr, Vault, DataEbr)} of
        {{ok, Windows}, {ok, Windows}} ->
            disjoint(Capacity, Windows),
            accepted;
        {{error, _}, error} ->
            refused;
        {_, Reference} ->
            error({disagrees_with_reference, Capacity, Said, Reference})
    end.

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).

%% The good table as three lists of four {Status, Type, Start, Sectors} entries.
good(Data) ->
    End = ?ERX_MEDIUM_DATA_START + Data,
    [[{0, ?ERX_MEDIUM_RECORD_TYPE, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
      {0, ?ERX_MEDIUM_SLOT_TYPE, ?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS},
      {0, ?ERX_MEDIUM_SLOT_TYPE, ?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS},
      {0, ?ERX_MEDIUM_EXTENDED_TYPE, ?ERX_MEDIUM_EXTENDED_START, End - ?ERX_MEDIUM_EXTENDED_START}],
     [{0, ?ERX_MEDIUM_VAULT_TYPE, ?ERX_MEDIUM_VAULT_START - ?ERX_MEDIUM_EXTENDED_START, ?ERX_MEDIUM_VAULT_SECTORS},
      {0, ?ERX_MEDIUM_LINK_TYPE, ?ERX_MEDIUM_DATA_EBR - ?ERX_MEDIUM_EXTENDED_START, End - ?ERX_MEDIUM_DATA_EBR},
      {0, 0, 0, 0}, {0, 0, 0, 0}],
     [{0, ?ERX_MEDIUM_DATA_TYPE, ?ERX_MEDIUM_DATA_START - ?ERX_MEDIUM_DATA_EBR, Data},
      {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}]].


mutate_entries(Records, 0) ->
    Records;
mutate_entries(Records, Left) ->
    Which = rand:uniform(3),
    Index = rand:uniform(4),
    Entry = lists:nth(Index, lists:nth(Which, Records)),
    Field = rand:uniform(4),
    Old = element(Field, Entry),
    Width = case Field of 1 -> 16#ff; 2 -> 16#ff; _ -> 16#ffffffff end,
    New = pick([Old + 1, Old - 1, 0, Width, rand:uniform(Width + 1) - 1, ?ERX_MEDIUM_LINK_TYPE,
                ?ERX_MEDIUM_DATA_EBR, ?ERX_MEDIUM_EXTENDED_START]) band Width,
    Record = replace(lists:nth(Which, Records), Index, setelement(Field, Entry, New)),
    mutate_entries(replace(Records, Which, Record), Left - 1).

replace(List, Index, Value) ->
    lists:sublist(List, Index - 1) ++ [Value] ++ lists:nthtail(Index, List).

%% A record's bytes: 446 the reader ignores, the four entries, the signature 55 aa.
encode(Entries) ->
    <<(noise(446))/binary,
      << <<Status:8, (rand:uniform(256) - 1):24, Type:8, (rand:uniform(256) - 1):24, Start:32/little, Count:32/little>>
         || {Status, Type, Start, Count} <- Entries >>/binary,
      16#55, 16#aa>>.

noise(Size) -> << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, Size) >>.

mutate_records(Records, Left) when Left =< 0 ->
    Records;
mutate_records(Records, Left) ->
    Which = rand:uniform(3),
    Record = lists:nth(Which, Records),
    Changed = case rand:uniform(4) of
                  1 -> flip(Record, 446 + rand:uniform(66) - 1);
                  2 -> flip(Record, rand:uniform(512) - 1);
                  3 -> resize(Record);
                  4 -> pick([not_a_record, [], 512])
              end,
    mutate_records(replace(Records, Which, Changed), Left - 1).

flip(Record, At) when is_binary(Record), At < byte_size(Record) ->
    <<Before:At/binary, Byte, After/binary>> = Record,
    <<Before/binary, (Byte bxor rand:uniform(255)), After/binary>>;
flip(Record, _At) ->
    Record.

resize(<<>>) ->
    <<0>>;
resize(Record) when is_binary(Record) ->
    pick([<<>>, binary:part(Record, 0, byte_size(Record) - 1), <<Record/binary, 0>>,
          binary:part(Record, 0, rand:uniform(byte_size(Record)) - 1)]);
resize(Record) ->
    Record.

%% The rule, from the format: three 512-byte records ending in 55 aa, whose entries at
%% 446, 462, 478 and 494 (status at +0, type at +4, start and length little-endian at +8
%% and +12) equal the good table for the data partition's length that the data record's
%% first entry names, a length from the minimum to the medium's end.
reference(Capacity, Mbr, Vault, DataEbr) when is_integer(Capacity), Capacity >= ?MIN_MEDIUM ->
    case [ref_entries(Record) || Record <- [Mbr, Vault, DataEbr]] of
        [{ok, M}, {ok, V}, {ok, D = [{_, _, _, Data} | _]}] ->
            Fits = Data >= ?MIN_DATA andalso ?ERX_MEDIUM_DATA_START + Data =< Capacity,
            case Fits andalso [M, V, D] =:= good(Data) of
                true -> {ok, [{record, ?ERX_MEDIUM_RECORD_START, ?ERX_MEDIUM_RECORD_SECTORS},
                              {slot_a, ?ERX_MEDIUM_SLOT_A_START, ?ERX_MEDIUM_SLOT_SECTORS},
                              {slot_b, ?ERX_MEDIUM_SLOT_B_START, ?ERX_MEDIUM_SLOT_SECTORS},
                              {vault, ?ERX_MEDIUM_VAULT_START, ?ERX_MEDIUM_VAULT_SECTORS},
                              {data, ?ERX_MEDIUM_DATA_START, Data}]};
                false -> error
            end;
        _ -> error
    end;
reference(_Capacity, _Mbr, _Vault, _DataEbr) ->
    error.

ref_entries(Record) when is_binary(Record), byte_size(Record) =:= 512 ->
    case binary:part(Record, 510, 2) of
        <<16#55, 16#aa>> ->
            {ok, [begin
                      <<Status:8, _:3/binary, Type:8, _:3/binary, Start:32/little, Count:32/little>> =
                          binary:part(Record, 446 + 16 * Index, 16),
                      {Status, Type, Start, Count}
                  end || Index <- [0, 1, 2, 3]]};
        _ -> error
    end;
ref_entries(_Record) ->
    error.

shape({ok, Windows}) when is_list(Windows) -> ok;
shape({error, {capacity, _}}) -> ok;
shape({error, {Name, What}}) when Name =:= mbr; Name =:= vault_ebr; Name =:= data_ebr ->
    true = lists:member(What, [size, signature]),
    ok;
shape({error, {Name, Index, Field}}) when Name =:= mbr; Name =:= vault_ebr; Name =:= data_ebr ->
    true = lists:member(Index, [1, 2, 3, 4]) andalso lists:member(Field, [status, type, start, sectors]),
    ok;
shape(Other) ->
    error({bad_shape, Other}).

%% Admitted windows lie within the medium and share no sector with each other or with
%% the three records.
disjoint(Capacity, Windows) ->
    Spans = lists:sort([{Start, Start + Sectors} || {_Role, Start, Sectors} <- Windows]
                       ++ [{Sector, Sector + 1} || {_Name, Sector} <- erx_blk_table:records()]),
    lists:foldl(fun({Start, End}, Previous) when Start >= Previous, End =< Capacity, Start < End -> End;
                   (Span, Previous) -> error({windows_overlap, Span, Previous})
                end, 0, Spans).

%% place/3 against plain comparisons.
check_place() ->
    Window = {data, rand:uniform(1 bsl 33), rand:uniform(1 bsl 20)},
    {_, Start, Sectors} = Window,
    Sector = pick([0, Sectors - 1, Sectors, Sectors + 1, -1, rand:uniform(1 bsl 34), one]),
    Count = pick([0, 1, 2, Sectors, Sectors + 1, -1, rand:uniform(16), 1.0]),
    Expected = if
                   not is_integer(Sector) orelse not is_integer(Count) -> {error, einval};
                   Sector < 0 orelse Count < 1 -> {error, einval};
                   Sector + Count > Sectors -> {error, erange};
                   true -> {ok, Start + Sector}
               end,
    case erx_blk_table:place(Window, Sector, Count) of
        Expected -> ok;
        Other -> error({place_disagrees_with_reference, Window, Sector, Count, Other, Expected})
    end.
