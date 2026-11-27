%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_f2fs_format_tests).
-moduledoc """
EUnit cases for erx_f2fs_format (docs/design-f2fs.md, "Formatting a volume"
and "Unit and property tests"): a fresh volume mounts read-write in erXos's
own mount, every table check passing, and its root lists only "." and "..";
over generated geometries, from the smallest partition the format takes to
8 GiB, the plan writes only inside the partition, in its three phases, with
one segment a section, segment 0 on an absolute segment boundary of the
medium, each log in its own section and the SIT's valid blocks exactly the
main-area blocks the plan fills. Whether
Linux's fsck.f2fs and mount accept the volume is the oracle guest's check.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(BLOCK, 4096).
-define(SEGMENT_SECTORS, 4096).
-define(MIB_SECTORS, 2048).
-define(ALLOWANCE, (64 bsl 20)).

options() -> #{version => 16#2468ace1, uuid => binary:copy(<<16#5a>>, 16), time => 1700000000}.

%% The data partition as the medium packs it, and the vault's.
data() -> #{start => ?ERX_MEDIUM_DATA_START, sectors => ?ERX_MEDIUM_DATA_SECTORS_MIN}.
vault() -> #{start => ?ERX_MEDIUM_VAULT_START, sectors => ?ERX_MEDIUM_VAULT_SECTORS}.

%% The final content of every block the plan writes: a later phase's
%% block over an earlier one's.
written(Plan) ->
    lists:foldl(fun({Address, Block}, Blocks) -> Blocks#{Address => Block} end, #{},
                lists:append(Plan)).

%% Mounts the written blocks as the volume process does; a block the plan
%% left unwritten holds an earlier volume's bytes, so the mount, readdir and
%% lookup may ask only for written blocks, each once.
mount(Partition, Blocks) -> need(fun(Given) -> erx_f2fs_mount:mount(Partition, ?ALLOWANCE, Given) end,
                                 Blocks).

need(Step, Blocks) -> need(Step, Blocks, #{}, 16).

need(Step, Blocks, Given, Rounds) ->
    case Step(Given) of
        {need, Addresses} when Rounds > 0 ->
            ?assertEqual([], [A || A <- Addresses, not is_map_key(A, Blocks) orelse is_map_key(A, Given)]),
            need(Step, Blocks, maps:merge(Given, maps:with(Addresses, Blocks)), Rounds - 1);
        Answer ->
            Answer
    end.

%% A fresh volume on the data partition mounts read-write, and its root
%% is an empty directory: "." and ".." alone, both the root.
a_fresh_volume_mounts_read_write_with_an_empty_root_test() ->
    #{sectors := Sectors} = Geometry = data(),
    {ok, Plan} = erx_f2fs_format:plan(Geometry, options()),
    Blocks = written(Plan),
    {ok, #{mode := Mode, root := Root, orphans := Orphans} = Volume} = mount(Sectors div 8, Blocks),
    ?assertEqual(read_write, Mode),
    ?assertEqual([], Orphans),
    ?assertMatch({ok, {[#{name := <<".">>, ino := 3, position := 0},
                        #{name := <<"..">>, ino := 3, position := 1}], done}},
                 need(fun(Given) -> erx_f2fs_core:readdir(Volume, Root, 0, Given) end, Blocks)),
    ?assertEqual({ok, none},
                 need(fun(Given) -> erx_f2fs_core:lookup(Volume, Root, <<"absent">>, Given) end,
                      Blocks)).

%% The data partition's segment 0 is 2 MiB in, at 592 MiB.
the_data_partitions_segment0_is_at_592_mib_test() ->
    ?assertMatch(#{segment0_blkaddr := 512}, superblock(data())).

superblock(Geometry) ->
    {ok, [_, _, [{1, Block}, {0, Block}]]} = erx_f2fs_format:plan(Geometry, options()),
    {ok, Super} = erx_f2fs_codec:superblock(Block),
    Super.

%% The smallest partition the format takes has 20 main segments, 56 MiB at
%% the data partition's start; one block less is refused.
the_smallest_partition_holds_twenty_main_sections_test() ->
    Smallest = #{start => ?ERX_MEDIUM_DATA_START, sectors => 56 * ?MIB_SECTORS},
    ?assertMatch(#{segment_count_main := 20}, superblock(Smallest)),
    ?assertEqual({error, {geometry, too_small}},
                 erx_f2fs_format:plan(Smallest#{sectors := 56 * ?MIB_SECTORS - 8}, options())).

refusals_test_() ->
    [?_assertEqual({error, Failure}, erx_f2fs_format:plan(Geometry, maps:merge(options(), Options)))
     || {Geometry, Options, Failure} <-
            [{(data())#{start := ?ERX_MEDIUM_DATA_START + 1}, #{}, {geometry, start}},
             {(data())#{sectors := 0}, #{}, {geometry, too_small}},
             {data(), #{version => 16#2468ace0}, {options, version}},
             {data(), #{version => 1 bsl 31 + 1}, {options, version}},
             {data(), #{uuid => <<1, 2, 3>>}, {options, uuid}},
             {data(), #{time => -1}, {options, time}}]].

%%% Properties over geometries

%% Explicit geometries at the start of the data partition, of the vault
%% and on no segment boundary, and generated ones from the smallest
%% partition to 8 GiB and starts to 4 GiB.
geometries() ->
    rand:seed(exsss, {16#f2f5, 2010, 8}),
    Explicit = [data(), vault(),
                #{start => ?ERX_MEDIUM_DATA_START, sectors => 1024 * ?MIB_SECTORS},
                #{start => ?ERX_MEDIUM_VAULT_START, sectors => 2048 * ?MIB_SECTORS},
                #{start => 8, sectors => 4096 * ?MIB_SECTORS},
                #{start => 3 * ?SEGMENT_SECTORS + 8, sectors => 8192 * ?MIB_SECTORS}],
    Generated = [#{start => 8 * (rand:uniform(1 bsl 20) - 1),
                   sectors => 56 * ?MIB_SECTORS + 8 * rand:uniform(8192 * ?MIB_SECTORS div 8)}
                 || _ <- lists:seq(1, 24)],
    Explicit ++ Generated.

%% Past 3 TiB the SIT's bitmap moves to payload blocks, which the pack
%% carries before its summaries; past 2^23 segments, 16 TiB, the format
%% refuses ([F 23], [F 54]).
a_large_volume_carries_the_sit_bitmap_in_payload_blocks_test_() ->
    {timeout, 120,
     fun() ->
             {ok, [_, Body, [{1, Block} | _]]} =
                 erx_f2fs_format:plan(#{start => 0, sectors => 7 bsl 31}, options()),
             {ok, #{cp_payload := Payload, cp_blkaddr := Pack} = Super} = erx_f2fs_codec:superblock(Block),
             ?assert(Payload > 0),
             Written = maps:from_list(Body),
             ?assertMatch({ok, #{cp_pack_start_sum := Start}} when Start =:= 1 + Payload,
                          erx_f2fs_codec:checkpoint(Super, maps:get(Pack, Written),
                                                    [maps:get(Pack + K, Written) || K <- lists:seq(1, Payload)])),
             ?assertEqual({error, {geometry, too_large}},
                          erx_f2fs_format:plan(#{start => 0, sectors => 17 bsl 31}, options()))
     end}.

each_plan_writes_a_valid_volume_inside_its_partition_test_() ->
    {timeout, 300, [?_test(valid(Geometry)) || Geometry <- geometries()]}.

valid(#{start := Start, sectors := Sectors} = Geometry) ->
    Partition = Sectors div 8,
    {ok, [Zeros, Body, Supers] = Plan} = erx_f2fs_format:plan(Geometry, options()),
    Zero = <<0:(?BLOCK * 8)>>,
    ?assertEqual([{0, Zero}, {1, Zero}], Zeros),
    ?assertMatch([{1, Block}, {0, Block}], Supers),
    ?assertEqual([], [A || {A, _} <- Body, A < 2]),
    ?assertEqual([], [A || {A, Block} <- lists:append(Plan), A >= Partition orelse
                                                             byte_size(Block) =/= ?BLOCK]),
    ?assertEqual(length(Body), length(lists:ukeysort(1, Body))),
    Blocks = written(Plan),
    {ok, #{superblock := Super, sit := Sit, mode := Mode}} =
        mount(Partition, Blocks),
    ?assertEqual(read_write, Mode),
    #{segs_per_sec := 1, segment0_blkaddr := Segment0, main_blkaddr := Main,
      segment_count_main := MainSegments} = Super,
    %% Segment 0 on an absolute segment boundary.
    ?assertEqual(0, (Start div 8 + Segment0) rem 512),
    %% The SIT marks valid exactly the main-area blocks the plan fills.
    Valid = [Main + Segno * 512 + Offset
             || Segno <- lists:seq(0, MainSegments - 1),
                #{valid_map := Map} <- [element(Segno + 1, Sit)],
                Offset <- lists:seq(0, 511), erx_f2fs_codec:bit(Map, Offset) =:= 1],
    Filled = lists:sort([A || {A, Block} <- maps:to_list(Blocks), A >= Main, Block =/= Zero]),
    ?assertEqual(Filled, Valid),
    %% The tables' first copies are written whole, so no earlier volume's
    %% entry stays selected: the SIT's the area's first half ([F 38]), the
    %% NAT's the first segment of each pair ([F 34]).
    #{sit_blkaddr := SitAt, segment_count_sit := SitSegments, nat_blkaddr := NatAt,
      segment_count_nat := NatSegments} = Super,
    Area = fun(At, Segments) -> [A || A <- lists:seq(At, At + Segments * 512 - 1), is_map_key(A, Blocks)] end,
    ?assertEqual(lists:seq(SitAt, SitAt + SitSegments div 2 * 512 - 1), Area(SitAt, SitSegments)),
    ?assertEqual([NatAt + 1024 * (I div 512) + I rem 512 || I <- lists:seq(0, NatSegments div 2 * 512 - 1)],
                 Area(NatAt, NatSegments)).
