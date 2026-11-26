%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The FAT server's allocator, erx_fat_alloc (docs/design-storage.md, "Removable
%% media: FAT"), over volumes built here, of a FAT region alone, and over the volumes
%% test/host/erx_fat_alloc_test.rb has fsimg write into ERX_FAT_IMAGES, whose results
%% fsimg's verify (ERX_FSIMG) checks. Every plan is applied step by step to an image
%% held in the process dictionary, which the allocator's read function reads, so it
%% sees every plan applied before, as the medium answers it.

-module(erx_fat_alloc_tests).

-include_lib("eunit/include/eunit.hrl").

%% The image helpers test/erlang/erx_fat_alloc_fuzz.erl shares.
-export([use/1, reader/0, apply_plan/1, flat/0, entries/1, entry/3, op/3, verify/1]).

-define(SECTOR, 512).
-define(UNKNOWN, 16#ffffffff).
-define(SLOTS, 5).

%% ---------------------------------------------------------------------------
%% The image
%% ---------------------------------------------------------------------------

use(Base) -> put(image, {Base, #{}}).

reader() ->
    fun(Sector) ->
            {Base, Written} = get(image),
            case Written of
                #{Sector := Bytes} -> {ok, Bytes};
                #{} when (Sector + 1) * ?SECTOR =< byte_size(Base) -> {ok, binary:part(Base, Sector * ?SECTOR, ?SECTOR)};
                #{} -> {error, outside}
            end
    end.

sector(Index) ->
    {ok, Bytes} = (reader())(Index),
    Bytes.

write(Writes) ->
    {Base, Written} = get(image),
    put(image, {Base, maps:merge(Written, maps:from_list(Writes))}).

apply_plan(Plan) -> [write(Writes) || {_Step, Writes} <- Plan].

flat() ->
    {Base, _} = get(image),
    << <<(sector(Index))/binary>> || Index <- lists:seq(0, byte_size(Base) div ?SECTOR - 1) >>.

%% Entry Cluster of FAT Copy as the image holds it, all its bits.
raw(#{type := Type, fat_start := Start, fat_sectors := FatSectors}, Copy, Cluster) ->
    Offset = Cluster * (Type div 8),
    <<_:(Offset rem ?SECTOR)/binary, Entry:Type/little, _/binary>> =
        sector(Start + Copy * FatSectors + Offset div ?SECTOR),
    Entry.

value(L = #{type := 16}, Cluster) -> raw(L, 0, Cluster);
value(L = #{type := 32}, Cluster) -> raw(L, 0, Cluster) band 16#0fffffff.

%% Entries written into every FAT as a crafted medium holds them, keeping FAT32's
%% top bits.
craft(L = #{type := Type, fat_start := Start, fats := Fats, fat_sectors := FatSectors}, Entries) ->
    lists:foreach(
      fun({Cluster, Value}) ->
              Offset = Cluster * (Type div 8),
              [begin
                   Index = Start + Copy * FatSectors + Offset div ?SECTOR,
                   At = Offset rem ?SECTOR,
                   <<Before:At/binary, Old:Type/little, After/binary>> = sector(Index),
                   New = case Type of 16 -> Value; 32 -> (Old band 16#f0000000) bor Value end,
                   write([{Index, <<Before/binary, New:Type/little, After/binary>>}])
               end || Copy <- lists:seq(0, Fats - 1)],
              L
      end, Entries).

links(L, Chain) -> lists:zip(Chain, tl(Chain) ++ [eoc(L)]).

eoc(#{type := 16}) -> 16#ffff;
eoc(#{type := 32}) -> 16#0fffffff.

%% The chain from First as the image holds it, walked here and not by the
%% allocator: the clusters to its end-of-chain mark, or why it breaks.
walk(L = #{clusters := Clusters}, First) -> walk(L, First, Clusters + 1, []).

walk(_L, _Cluster, 0, _Got) -> loops;
walk(L = #{clusters := Clusters}, Cluster, Left, Got) when Cluster >= 2, Cluster < Clusters + 2 ->
    Value = value(L, Cluster),
    case Value >= eoc(L) - 7 of
        true -> lists:reverse([Cluster | Got]);
        false -> walk(L, Value, Left - 1, [Cluster | Got])
    end;
walk(_L, Cluster, _Left, _Got) -> {breaks_at, Cluster}.

allocated(L = #{clusters := Clusters}) -> [C || C <- lists:seq(2, Clusters + 1), value(L, C) =/= 0].

free_clusters(L = #{clusters := Clusters}) -> [C || C <- lists:seq(2, Clusters + 1), value(L, C) =:= 0].

copies_equal(#{fat_start := Start, fats := Fats, fat_sectors := FatSectors}) ->
    First = [sector(Start + I) || I <- lists:seq(0, FatSectors - 1)],
    [?assertEqual(First, [sector(Start + Copy * FatSectors + I) || I <- lists:seq(0, FatSectors - 1)])
     || Copy <- lists:seq(1, Fats - 1)].

%% FAT32's reserved top bits of every entry of every FAT.
tops(L = #{type := 32, fats := Fats, clusters := Clusters}) ->
    [raw(L, Copy, C) bsr 28 || Copy <- lists:seq(0, Fats - 1), C <- lists:seq(0, Clusters + 1)];
tops(#{type := 16}) -> [].

%% A volume of a FAT region alone: sector 0 unused, FAT32's FSInfo at sector 1 with
%% a free count of 4660 and a next-free hint of 77, then Fats FATs, each entry's
%% top bits Top(Cluster) on FAT32, the second entry clean and without a hard error
%% unless Second says otherwise.
synthetic(Type, Clusters, Fats, Top) -> synthetic(Type, Clusters, Fats, Top, clean).

synthetic(Type, Clusters, Fats, Top, Second) ->
    FatSectors = ((Clusters + 2) * (Type div 8) + ?SECTOR - 1) div ?SECTOR,
    {Media, Flags} = case Type of 16 -> {16#fff8, 16#ffff}; 32 -> {16#0ffffff8, 16#0fffffff} end,
    SecondValue = case Second of clean -> Flags; hard_error -> Flags band bnot case Type of 16 -> 16#4000; 32 -> 16#04000000 end end,
    Entries = lists:enumerate(0, [Media, SecondValue | lists:duplicate(Clusters, 0)]),
    Raw = << <<(top(Type, Top, Cluster) bor Value):Type/little>> || {Cluster, Value} <- Entries >>,
    Fat = <<Raw/binary, 0:((FatSectors * ?SECTOR - byte_size(Raw)) * 8)>>,
    Info = case Type of 32 -> fsinfo(4660, 77); 16 -> <<0:(?SECTOR * 8)>> end,
    use(<<0:(?SECTOR * 8), Info/binary, (binary:copy(Fat, Fats))/binary>>),
    #{read => reader(), type => Type, fat_start => 2, fats => Fats, fat_sectors => FatSectors,
      clusters => Clusters, fsinfo => case Type of 32 -> 1; 16 -> none end}.

top(16, _Top, _Cluster) -> 0;
top(32, Top, Cluster) -> Top(Cluster) bsl 28.

zero(_Cluster) -> 0.

fsinfo(Count, Next) ->
    <<16#41615252:32/little, 0:(480 * 8), 16#61417272:32/little, Count:32/little, Next:32/little, 0:96,
      16#aa550000:32/little>>.

hints() ->
    <<_:488/binary, Count:32/little, Next:32/little, _/binary>> = sector(1),
    {Count, Next}.

committed(A) ->
    {ok, Plan, A1} = erx_fat_alloc:commit(A),
    apply_plan(Plan),
    A1.

%% ---------------------------------------------------------------------------
%% Batches
%% ---------------------------------------------------------------------------

%% Random batches of grows, shrinks and frees over files in ?SLOTS slots, each plan
%% applied a step at a time. After every step every FAT is equal and keeps its top
%% bits, and every file's chain is whole and ends in an end-of-chain mark, no
%% cluster in two: as before the batch while only its allocation step has landed,
%% as after it from then on (a batch that only frees has its publication in the
%% directory steps the directory code writes). Every cluster the batch allocates was free before it and is no
%% cluster it frees, and after the batch the FAT allocates exactly the files'.
batches_keep_every_chain_whole_at_every_cut_test_() ->
    {timeout, 300, fun() -> [property(Seed) || Seed <- lists:seq(1, 80)] end}.

property(Seed) ->
    rand:seed(exsss, {7, 11, Seed}),
    Type = element(rand:uniform(2), {16, 32}),
    L = synthetic(Type, 150 + rand:uniform(400), rand:uniform(3), fun(_) -> rand:uniform(16) - 1 end),
    batches(erx_fat_alloc:new(L), L, tops(L), #{}, 1 + rand:uniform(6)).

batches(_A, _L, _Tops, _Chains, 0) ->
    ok;
batches(A, L, Tops, Pre, Left) ->
    {A1, Post} = lists:foldl(fun(_, {Ai, Ci}) -> op(Ai, Ci, lists:seq(1, ?SLOTS)) end, {A, Pre},
                             lists:seq(1, 1 + rand:uniform(6))),
    Free = free_clusters(L),
    New = lists:append([maps:get(K, Post) -- maps:get(K, Pre, []) || K <- maps:keys(Post)]),
    Freed = lists:append([Chain -- maps:get(K, Post, []) || K := Chain <- Pre]),
    ?assertEqual([], New -- Free),
    ?assertEqual([], [C || C <- New, lists:member(C, Freed)]),
    Runs = [Run || K := Chain <- Post, [_ | _] = Run <- [Chain -- maps:get(K, Pre, [])]],
    Old = [{C, value(L, C)} || C <- Freed],
    {ok, Plan, A2} = erx_fat_alloc:commit(A1),
    Steps = [Step || {Step, _} <- Plan],
    ?assertEqual([S || S <- [allocation, publication, release], lists:member(S, Steps)], Steps),
    lists:foldl(fun({Step, Writes}, Published) ->
                        %% Every new run is whole before anything can reach it.
                        [?assertEqual(Run, walk(L, hd(Run))) || Step =/= allocation, Run <- Runs],
                        write(Writes),
                        %% Every freed cluster keeps its entry until its release.
                        [?assertEqual(Old, [{C, value(L, C)} || {C, _} <- Old]) || Step =/= release],
                        Now = Published orelse Step =/= allocation,
                        cut_holds(L, Tops, case Now of true -> Post; false -> Pre end),
                        Now
                end, false, Plan),
    ?assertEqual(lists:sort(lists:append(maps:values(Post))), allocated(L)),
    batches(A2, L, Tops, Post, Left - 1).

cut_holds(L, Tops, Live) ->
    copies_equal(L),
    ?assertEqual(Tops, tops(L)),
    All = lists:append(maps:values(Live)),
    ?assertEqual(length(All), length(lists:usort(All))),
    [?assertEqual(Chain, walk(L, First)) || _ := [First | _] = Chain <- Live].

%% One random change to the file under one of Keys, whose chains Chains holds; the
%% allocator's own view of the chain checked first. A finding but no_space is
%% thrown as {refused, Finding}.
op(A, Chains, Keys) ->
    Key = lists:nth(rand:uniform(length(Keys)), Keys),
    Chain = maps:get(Key, Chains, []),
    [?assertEqual(Chain, checked(erx_fat_alloc:chain(A, hd(Chain)))) || Chain =/= []],
    case {Chain, rand:uniform(3)} of
        {[], _} ->
            grow(A, Chains, Key, none, Chain);
        {_, 1} ->
            grow(A, Chains, Key, hd(Chain), Chain);
        {_, 2} ->
            Keep = rand:uniform(length(Chain) + 1) - 1,
            {checked(erx_fat_alloc:shrink(A, hd(Chain), Keep)), Chains#{Key => lists:sublist(Chain, Keep)}};
        {_, 3} ->
            {checked(erx_fat_alloc:free(A, hd(Chain))), Chains#{Key => []}}
    end.

grow(A, Chains, Key, First, Chain) ->
    case erx_fat_alloc:grow(A, First, rand:uniform(24)) of
        {ok, Run, A1} -> {A1, Chains#{Key => Chain ++ Run}};
        {error, no_space} -> {A, Chains#{Key => Chain}};
        {error, Finding} -> throw({refused, Finding})
    end.

%% What the allocator answered, or {refused, Finding} thrown, which fails a test and
%% ends a fuzz round over a crafted volume.
checked({ok, Value}) -> Value;
checked({error, Finding}) -> throw({refused, Finding}).

%% A file of Len clusters from Start, behind a chain holding every cluster before
%% it, grown by every Grow and then cut to every Keep, around FAT16's first FAT
%% sector boundary at cluster 256: the new run follows the file, the cut frees the
%% rest, and nothing else changes.
grow_and_shrink_across_a_fat_sector_boundary_test_() ->
    {timeout, 300,
     fun() ->
             [boundary(Start, Len, Grow, Keep)
              || Start <- [250, 253, 255, 256], Len <- lists:seq(1, 6), Grow <- lists:seq(1, 6),
                 Keep <- lists:seq(0, Len + Grow)]
     end}.

boundary(Start, Len, Grow, Keep) ->
    L = synthetic(16, 600, 2, fun zero/1),
    Filler = lists:seq(2, Start - 1),
    craft(L, links(L, Filler) ++ links(L, lists:seq(Start, Start + Len - 1))),
    {ok, Run, A} = erx_fat_alloc:grow(erx_fat_alloc:new(L), Start, Grow),
    ?assertEqual(lists:seq(Start + Len, Start + Len + Grow - 1), Run),
    A1 = committed(A),
    File = lists:seq(Start, Start + Len + Grow - 1),
    ?assertEqual(File, walk(L, Start)),
    {ok, A2} = erx_fat_alloc:shrink(A1, Start, Keep),
    committed(A2),
    [?assertEqual(lists:sublist(File, Keep), walk(L, Start)) || Keep > 0],
    ?assertEqual(Filler, walk(L, 2)),
    ?assertEqual(Filler ++ lists:sublist(File, Keep), allocated(L)),
    copies_equal(L).

a_freed_cluster_is_not_allocated_again_in_its_batch_test() ->
    L = synthetic(16, 300, 2, fun zero/1),
    craft(L, links(L, lists:seq(2, 301))),
    {ok, A} = erx_fat_alloc:shrink(erx_fat_alloc:new(L), 2, 100),
    ?assertEqual({error, no_space}, erx_fat_alloc:grow(A, none, 1)),
    ?assertEqual({error, no_space}, erx_fat_alloc:grow(A, 2, 1)),
    ?assertMatch({ok, [C], _} when C > 101, erx_fat_alloc:grow(committed(A), none, 1)).

a_run_freed_in_the_batch_that_allocated_it_waits_for_the_next_test() ->
    L = synthetic(16, 300, 1, fun zero/1),
    craft(L, links(L, lists:seq(2, 297))),
    {ok, [298, 299], A} = erx_fat_alloc:grow(erx_fat_alloc:new(L), none, 2),
    {ok, A1} = erx_fat_alloc:free(A, 298),
    ?assertEqual({error, no_space}, erx_fat_alloc:grow(A1, none, 3)),
    ?assertMatch({ok, [300, 301], _}, erx_fat_alloc:grow(A1, none, 2)).

every_fat_is_written_in_the_same_step_the_first_first_test() ->
    L = #{fat_start := Start, fat_sectors := FatSectors} = synthetic(16, 600, 3, fun zero/1),
    craft(L, links(L, lists:seq(2, 254))),
    {ok, _Run, A} = erx_fat_alloc:grow(erx_fat_alloc:new(L), 2, 4),
    {ok, [{allocation, Allocation}, {publication, Publication}], _} = erx_fat_alloc:commit(A),
    [begin
         Sectors = [Index || {Index, _} <- Writes],
         ?assertEqual(Sectors, lists:sort(Sectors)),
         Copies = [[Bytes || {Index, Bytes} <- Writes, (Index - Start) div FatSectors =:= Copy] || Copy <- [0, 1, 2]],
         ?assertMatch([Same, Same, Same], Copies)
     end || Writes <- [Allocation, Publication]].

a_run_starts_after_the_last_cluster_allocated_and_wraps_test() ->
    L = synthetic(16, 40, 1, fun zero/1),
    {ok, [2, 3, 4], A} = erx_fat_alloc:grow(erx_fat_alloc:new(L), none, 3),
    {ok, A1} = erx_fat_alloc:free(committed(A), 2),
    {ok, [5, 6, 7], A2} = erx_fat_alloc:grow(committed(A1), none, 3),
    craft(L, links(L, lists:seq(10, 40))),
    %% From 8: 8 and 9 hold no run of three, nor 41 alone before the wrap; 2..4, freed
    %% and committed, do.
    ?assertMatch({ok, [2, 3, 4], _}, erx_fat_alloc:grow(committed(A2), none, 3)),
    %% No run of five: the first five free clusters met, from 8 on.
    ?assertMatch({ok, [8, 9, 41, 2, 3], _}, erx_fat_alloc:grow(committed(A2), none, 5)).

%% ---------------------------------------------------------------------------
%% Chains a crafted medium holds
%% ---------------------------------------------------------------------------

a_chain_that_loops_or_leaves_the_data_area_is_refused_test() ->
    [begin
         L = synthetic(Type, 300, 2, fun zero/1),
         Bad = case Type of 16 -> 16#fff7; 32 -> 16#0ffffff7 end,
         craft(L, [{2, 3}, {3, 2}, {10, 11}, {11, 0}, {20, 302}, {30, Bad}, {40, 1}]),
         A = erx_fat_alloc:new(L),
         [begin
              ?assertEqual({error, does_not_read}, erx_fat_alloc:chain(A, First)),
              ?assertEqual({error, does_not_read}, erx_fat_alloc:grow(A, First, 1)),
              ?assertEqual({error, does_not_read}, erx_fat_alloc:free(A, First))
          end || First <- [2, 10, 20, 30, 40, 0, 1, 302]]
     end || Type <- [16, 32]].

two_chains_crossing_are_refused_test() ->
    L = synthetic(16, 300, 2, fun zero/1),
    %% 2 -> 3 and 4 -> 3 share 3; 6 -> 7, whose entry is free, which a new run then takes.
    craft(L, [{2, 3}, {3, eoc(L)}, {4, 3}, {5, eoc(L)}, {6, 7}]),
    {ok, A} = erx_fat_alloc:free(erx_fat_alloc:new(L), 2),
    ?assertEqual({error, does_not_read}, erx_fat_alloc:chain(A, 4)),
    ?assertEqual({error, does_not_read}, erx_fat_alloc:chain(A, 3)),
    {ok, [7], A1} = erx_fat_alloc:grow(erx_fat_alloc:new(L), none, 1),
    ?assertEqual({error, does_not_read}, erx_fat_alloc:chain(A1, 6)),
    ?assertEqual({ok, [7]}, erx_fat_alloc:chain(A1, 7)).

a_shrink_past_the_chain_is_refused_test() ->
    L = synthetic(16, 300, 1, fun zero/1),
    craft(L, links(L, [2, 3, 4])),
    ?assertEqual({error, does_not_read}, erx_fat_alloc:shrink(erx_fat_alloc:new(L), 2, 4)).

a_sector_the_medium_does_not_read_is_read_failed_test() ->
    L = synthetic(16, 300, 1, fun zero/1),
    A = erx_fat_alloc:new(L#{read := fun(_) -> {error, eio} end}),
    ?assertEqual({error, read_failed}, erx_fat_alloc:grow(A, none, 1)),
    ?assertEqual({error, read_failed}, erx_fat_alloc:chain(A, 2)).

%% ---------------------------------------------------------------------------
%% The volume's flags and FSInfo
%% ---------------------------------------------------------------------------

the_dirty_and_clean_steps_keep_the_top_bits_and_set_the_hints_test() ->
    L = synthetic(32, 300, 2, fun(C) -> C rem 16 end),
    Tops = tops(L),
    A = erx_fat_alloc:new(L),
    {ok, [{dirty, Dirty}]} = erx_fat_alloc:dirty(A),
    write(Dirty),
    ?assertEqual(#{clean => false, hard_error => false}, erx_fat_alloc:volume_flags(32, raw(L, 0, 1))),
    ?assertEqual({?UNKNOWN, ?UNKNOWN}, hints()),
    copies_equal(L),
    {ok, [2, 3, 4], A1} = erx_fat_alloc:grow(A, none, 3),
    {ok, Plan, _} = erx_fat_alloc:finish(A1),
    ?assertEqual([allocation, release, clean], [Step || {Step, _} <- Plan]),
    apply_plan(Plan),
    ?assertEqual([2, 3, 4], walk(L, 2)),
    ?assertEqual(#{clean => true, hard_error => false}, erx_fat_alloc:volume_flags(32, raw(L, 0, 1))),
    ?assertEqual({?UNKNOWN, 5}, hints()),
    ?assertEqual(Tops, tops(L)),
    copies_equal(L).

a_finish_without_an_allocation_leaves_the_hint_unknown_test() ->
    L = synthetic(32, 300, 2, fun zero/1),
    A = erx_fat_alloc:new(L),
    {ok, Dirty} = erx_fat_alloc:dirty(A),
    apply_plan(Dirty),
    ?assertMatch({ok, [{clean, _}], _}, erx_fat_alloc:finish(A)),
    ?assertEqual({?UNKNOWN, ?UNKNOWN}, hints()).

the_hint_wraps_past_the_last_cluster_test() ->
    L = synthetic(32, 300, 1, fun zero/1),
    craft(L, links(L, lists:seq(2, 300))),
    {ok, [301], A} = erx_fat_alloc:grow(erx_fat_alloc:new(L), none, 1),
    {ok, Plan, _} = erx_fat_alloc:finish(A),
    apply_plan(Plan),
    ?assertEqual({4660, 2}, hints()).

a_hard_error_stays_recorded_test() ->
    L = synthetic(16, 300, 2, fun zero/1, hard_error),
    A = erx_fat_alloc:new(L),
    {ok, Dirty} = erx_fat_alloc:dirty(A),
    apply_plan(Dirty),
    {ok, Plan, _} = erx_fat_alloc:finish(A),
    apply_plan(Plan),
    ?assertEqual(#{clean => true, hard_error => true}, erx_fat_alloc:volume_flags(16, raw(L, 1, 1))).

an_fsinfo_sector_without_its_signatures_is_left_alone_test() ->
    L = synthetic(32, 300, 1, fun zero/1),
    write([{1, <<1:(?SECTOR * 8)>>}]),
    {ok, [{dirty, Writes}]} = erx_fat_alloc:dirty(erx_fat_alloc:new(L)),
    ?assertEqual([2], [Index || {Index, _} <- Writes]).

the_writable_rule_names_its_first_reason_test() ->
    Ok = #{clean => true, hard_error => false, mirrored => true},
    ?assertEqual(ok, erx_fat_alloc:writable(Ok)),
    ?assertEqual({read_only, dirty}, erx_fat_alloc:writable(Ok#{clean := false, hard_error := true, mirrored := false})),
    ?assertEqual({read_only, hard_error}, erx_fat_alloc:writable(Ok#{hard_error := true, mirrored := false})),
    ?assertEqual({read_only, mirror}, erx_fat_alloc:writable(Ok#{mirrored := false})).

%% ---------------------------------------------------------------------------
%% fsimg's volumes, checked by fsimg's verify
%% ---------------------------------------------------------------------------

%% Random batches over the files of fsimg's volumes, each file's directory entry
%% given its new first cluster and a size its chain holds, as the publication step
%% will write it, then the finish: fsimg's verify passes the result.
seeded_volumes_pass_fsimg_verify_after_batches_test_() ->
    {timeout, 600, fun() -> [seeded(Name, Seed) || Name <- ["fat16.img", "fat32.img"], Seed <- lists:seq(1, 5)] end}.

seeded(Name, Seed) ->
    rand:seed(exsss, {3, 5, Seed}),
    {ok, Base} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    use(Base),
    {ok, Fat} = erx_fat:mount(reader(), byte_size(Base) div ?SECTOR),
    ok = erx_fat_alloc:writable(erx_fat:info(Fat)),
    L = erx_fat:layout(Fat),
    #{cluster_bytes := ClusterBytes} = erx_fat:info(Fat),
    Entries = entries(Base),
    Chains = maps:map(fun(_Offset, First) -> case First of 0 -> []; _ -> walk(L, First) end end, Entries),
    A = erx_fat_alloc:new(L),
    {ok, Dirty} = erx_fat_alloc:dirty(A),
    apply_plan(Dirty),
    {A1, _} = lists:foldl(fun(_, {Ai, Ci}) -> seeded_batch(Ai, Ci, ClusterBytes) end, {A, Chains}, lists:seq(1, 4)),
    {ok, Finish, _} = erx_fat_alloc:finish(A1),
    apply_plan(Finish),
    ?assertMatch({0, _}, verify(flat())).

seeded_batch(A, Chains, ClusterBytes) ->
    {A1, Post} = lists:foldl(fun(_, {Ai, Ci}) -> op(Ai, Ci, maps:keys(Chains)) end, {A, Chains},
                             lists:seq(1, 1 + rand:uniform(4))),
    A2 = committed(A1),
    maps:foreach(fun(Offset, Chain) -> entry(Offset, Chain, ClusterBytes) end, Post),
    {A2, Post}.

%% The short entries of the seeds' four files, by their byte offsets in the image,
%% to their first clusters: three by name, Long File Name.dat by its size.
entries(Base) ->
    maps:from_list([{Offset, First} || Offset <- lists:seq(0, byte_size(Base) - 32, 32),
                                       <<Name:11/binary, Attr, _:8/binary, Hi:16/little, _:4/binary, Lo:16/little,
                                         Size:32/little>> <- [binary:part(Base, Offset, 32)],
                                       First <- [Hi bsl 16 bor Lo],
                                       lists:member(Name, [<<"HELLO   TXT">>, <<"EMPTY      ">>, <<"X       TXT">>])
                                           orelse (Size =:= 5000 andalso Attr band 16#18 =:= 0
                                                   andalso binary:first(Name) =/= 16#e5)]).

entry(Offset, Chain, ClusterBytes) ->
    Index = Offset div ?SECTOR,
    At = Offset rem ?SECTOR,
    <<Before:At/binary, Name:20/binary, _:16, Times:4/binary, _:16, _:32, After/binary>> = sector(Index),
    First = case Chain of [] -> 0; [C | _] -> C end,
    write([{Index, <<Before/binary, Name/binary, (First bsr 16):16/little, Times/binary, (First band 16#ffff):16/little,
                     (length(Chain) * ClusterBytes):32/little, After/binary>>}]).

seeded_entries_are_found_test() ->
    [begin
         {ok, Base} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
         ?assertEqual(4, map_size(entries(Base)))
     end || Name <- ["fat16.img", "fat32.img"]].

%% fsimg's verify of Bytes: its exit status and what it printed.
verify(Bytes) ->
    Path = filename:absname("verify.img"),
    ok = file:write_file(Path, Bytes),
    Port = open_port({spawn_executable, os:getenv("ERX_FSIMG")},
                     [{args, ["W", "-f", Path]}, exit_status, stderr_to_stdout, binary]),
    collect(Port, <<>>).

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    end.
