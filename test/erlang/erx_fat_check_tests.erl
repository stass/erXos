%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The checker of a FAT volume, erx_fat_check (docs/design-fsck-fat.md,
%% "Verification"), over volumes erx_fat_damage lays out in memory: a clean volume
%% yields no finding, each damaged one exactly the findings of its kind in FreeBSD's
%% order, and a volume past a bound is refused within the command's heap, reading
%% nothing past what the bound needs. When ERX_FAT_IMAGES names a directory, the
%% volumes fsimg wrote there are checked clean too.

-module(erx_fat_check_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).
-define(T, 1767225600).
%% The command's heap, -erx_heap(16), at which the runtime kills it.
-define(HEAP_BYTES, (16 * 1024 * 1024)).

tree() ->
    [{file, <<"HELLO.TXT">>, 1000},
     {dir, <<"DOCS">>, [{file, {long, <<"a long name.txt">>, <<"ALONGN~1.TXT">>}, 600},
                        {dir, <<"SUB">>, [{file, <<"NOTE.TXT">>, 10}]}]},
     {file, <<"EMPTY.TXT">>, 0},
     {file, <<"X.TXT">>, 1000}].

-define(H, <<"/HELLO.TXT">>).
-define(E, <<"/EMPTY.TXT">>).
-define(LONG, <<"/DOCS/a long name.txt">>).

check(V) -> erx_fat_check:check(erx_fat_damage:read(V), erx_fat_damage:sectors(V)).

%% Sector Cluster's first sector.
cluster_sector(V, Cluster) -> maps:get(data_start, erx_fat_damage:layout(V)) + Cluster - 2.

first(V, Path) -> erx_fat_damage:first(V, Path).

%% Bytes written at Offset of the entry Path's short entry is at, Slots slots on.
poke_entry(V, Path, Slots, Offset, Bytes) ->
    {Sector, At} = erx_fat_damage:entry_at(V, Path),
    erx_fat_damage:poke(V, Sector, At + Slots * 32 + Offset, Bytes).

%% Bytes written at Offset of slot Slot of directory Path's first cluster.
poke_dir(V, Path, Slot, Offset, Bytes) ->
    erx_fat_damage:poke(V, cluster_sector(V, first(V, Path)), Slot * 32 + Offset, Bytes).

entry(Name, Attributes, First) ->
    Short = erx_fat_entry:new(Name, 0, file, First, ?T),
    <<Front:11/binary, _, Back/binary>> = erx_fat_entry:encode(Short),
    <<Front/binary, Attributes, Back/binary>>.

%% Each case: a description the seeded faults name, the volume's type, its damage,
%% and the findings expected of the damaged volume, given the clean one.
cases() ->
    [{"finding boot_sector", 16, fun(V) -> erx_fat_damage:poke(V, 0, 14, <<0, 0>>) end,
      fun(_) -> {fatal, {boot_sector, reserved}} end},
     {"refusal fat12", 16, fun(V) -> erx_fat_damage:poke(V, 0, 19, <<(67 + 4000):16/little>>) end,
      fun(_) -> {refused, fat12} end},
     {"refusal sector_size", 16, fun(V) -> erx_fat_damage:poke(V, 0, 11, <<0, 4>>) end,
      fun(_) -> {refused, sector_size} end},
     {"refusal not_mirrored", 32, fun(V) -> erx_fat_damage:poke(V, 0, 40, <<16#80, 0>>) end,
      fun(_) -> {refused, not_mirrored} end},
     {"finding fsinfo_signature", 32, fun(V) -> erx_fat_damage:poke(V, 1, 0, <<"X">>) end,
      fun(_) -> {ok, [fsinfo_signature]} end},
     {"finding fat_header", 16, fun(V) -> erx_fat_damage:fat(V, 0, 16#fff0) end,
      fun(_) -> {ok, [{fat_header, <<16#f0, 16#ff, 16#ff, 16#ff>>}]} end},
     {"finding dirty", 32, fun(V) -> erx_fat_damage:fat(V, 1, 16#07ffffff) end,
      fun(_) -> {ok, [dirty]} end},
     {"finding out_of_range_link", 16, fun(V) -> erx_fat_damage:fat(V, first(V, ?H) + 1, 16#fff0) end,
      fun(V) -> {ok, [{out_of_range_link, first(V, ?H) + 1, 16#fff0}]} end},
     {"finding crossed", 16, fun(V) -> erx_fat_damage:fat(V, first(V, <<"/X.TXT">>), first(V, ?H) + 1) end,
      fun(V) ->
              X = first(V, <<"/X.TXT">>),
              {ok, [{crossed, X, first(V, ?H) + 1}, {size_too_large, <<"/X.TXT">>, 1000, 512}, {lost_chain, X + 1, 1}]}
      end},
     {"fatal root_not_chain", 32, fun(V) -> erx_fat_damage:fat(V, first(V, ?H) + 1, 2) end,
      fun(_) -> {fatal, root_not_chain} end},
     {"finding chain_end", 16, fun(V) -> erx_fat_damage:fat(V, first(V, ?H) + 1, 0) end,
      fun(V) -> {ok, [{chain_end, first(V, ?H), free}, {size_too_large, ?H, 1000, 512}]} end},
     {"finding entries_after_end", 16, fun(V) -> poke_entry(V, ?H, 0, 0, <<0>>) end,
      fun(V) -> {ok, [{entries_after_end, <<>>}, {lost_chain, first(V, ?H), 2}]} end},
     {"finding invalid_long", 16, fun(V) -> poke_entry(V, ?LONG, 0, 7, <<"2">>) end,
      fun(_) -> {ok, [{invalid_long, <<"/DOCS/ALONGN~2.TXT">>}]} end},
     {"finding invalid_long_at_end", 16,
      fun(V) -> poke_entry(V, <<"/DOCS/SUB/NOTE.TXT">>, 1, 0, erx_fat_entry:long(1, true, 0, binary:copy(<<"a", 0>>, 13))) end,
      fun(_) -> {ok, [{invalid_long_at_end, <<"/DOCS/SUB">>}]} end},
     {"finding invalid_long_label", 16,
      fun(V) ->
              Long = poke_entry(V, <<"/X.TXT">>, 1, 0, erx_fat_entry:long(1, true, 0, binary:copy(<<"a", 0>>, 13))),
              poke_entry(Long, <<"/X.TXT">>, 2, 0, entry(<<"LABEL      ">>, 16#08, 0))
      end,
      fun(_) -> {ok, [invalid_long_label]} end},
     {"finding invalid_long_name", 16, fun(V) -> poke_entry(V, ?LONG, -2, 0, <<16#40>>) end,
      fun(_) -> {ok, [invalid_long_name, {invalid_long, <<"/DOCS/ALONGN~1.TXT">>}]} end},
     {"finding long_name_too_long", 16, fun(V) -> poke_entry(V, ?LONG, -2, 0, <<(16#40 bor 21)>>) end,
      fun(_) -> {ok, [long_name_too_long, {invalid_long, <<"/DOCS/ALONGN~1.TXT">>}]} end},
     {"finding long_cluster", 16, fun(V) -> poke_entry(V, ?LONG, -2, 26, <<5, 0>>) end,
      fun(_) -> {ok, [long_cluster, {invalid_long, <<"/DOCS/ALONGN~1.TXT">>}]} end},
     {"finding start_out_of_range", 16, fun(V) -> erx_fat_damage:start(V, ?H, 5000) end,
      fun(V) -> {ok, [{start_out_of_range, ?H, 5000}, {lost_chain, first(V, ?H), 2}]} end},
     {"finding not_new_chain", 16, fun(V) -> erx_fat_damage:size(erx_fat_damage:start(V, ?E, first(V, ?H)), ?E, 100) end,
      fun(_) -> {ok, [{not_new_chain, ?E}]} end},
     {"finding not_new_chain of a directory named twice", 16,
      fun(V) -> erx_fat_damage:entry(V, ?E, entry(<<"EMPTY   TXT">>, 16#10, first(V, <<"/DOCS">>))) end,
      fun(_) -> {ok, [{not_new_chain, <<"/DOCS">>}]} end},
     {"finding dir_size", 16, fun(V) -> erx_fat_damage:size(V, <<"/DOCS">>, 100) end,
      fun(_) -> {ok, [{dir_size, <<"/DOCS">>}]} end},
     {"finding dot_cluster", 16, fun(V) -> poke_dir(V, <<"/DOCS">>, 0, 26, <<9, 0>>) end,
      fun(_) -> {ok, [{dot_cluster, <<"/DOCS">>}]} end},
     {"finding dotdot_nonzero", 16, fun(V) -> poke_dir(V, <<"/DOCS">>, 1, 26, <<7, 0>>) end,
      fun(_) -> {ok, [{dotdot_nonzero, <<"/DOCS">>}]} end},
     {"finding dotdot_cluster", 32, fun(V) -> poke_dir(V, <<"/DOCS/SUB">>, 1, 26, <<9, 0>>) end,
      fun(_) -> {ok, [{dotdot_cluster, <<"/DOCS/SUB">>}]} end},
     {"finding dot_out_of_place", 16,
      fun(V) -> poke_entry(V, <<"/DOCS/SUB/NOTE.TXT">>, 1, 0, entry(<<".          ">>, 16#10, first(V, <<"/DOCS/SUB">>))) end,
      fun(_) -> {ok, [{dot_out_of_place, dot, <<"/DOCS/SUB">>}]} end},
     {"finding incorrect_dot", 16, fun(V) -> poke_dir(V, <<"/DOCS/SUB">>, 0, 0, <<"X">>) end,
      fun(V) -> {ok, [{incorrect_dot, <<"SUB">>}, {lost_chain, first(V, <<"/DOCS/SUB">>), 1},
                      {lost_chain, first(V, <<"/DOCS/SUB/NOTE.TXT">>), 1}]} end},
     {"finding incorrect_dotdot", 16, fun(V) -> poke_dir(V, <<"/DOCS/SUB">>, 1, 11, <<16#20>>) end,
      fun(V) -> {ok, [{incorrect_dotdot, <<"SUB">>}, {lost_chain, first(V, <<"/DOCS/SUB">>), 1},
                      {lost_chain, first(V, <<"/DOCS/SUB/NOTE.TXT">>), 1}]} end},
     {"finding invalid_cluster", 16, fun(V) -> erx_fat_damage:start(V, ?E, 5000) end,
      fun(_) -> {ok, [{invalid_cluster, ?E, 0, 5000}]} end},
     {"finding size_too_large", 32, fun(V) -> erx_fat_damage:size(V, ?H, 5000) end,
      fun(_) -> {ok, [{size_too_large, ?H, 5000, 1024}]} end},
     {"finding too_many_clusters", 16, fun(V) -> erx_fat_damage:size(V, ?H, 100) end,
      fun(V) -> {ok, [{too_many_clusters, ?H}, {lost_chain, first(V, ?H) + 1, 1}]} end},
     {"finding lost_chain", 16, fun(V) -> poke_entry(V, ?H, 0, 0, <<16#e5>>) end,
      fun(V) -> {ok, [{lost_chain, first(V, ?H), 2}]} end},
     {"finding lost_loop", 16, fun(V) -> erx_fat_damage:fat(erx_fat_damage:fat(V, 100, 101), 101, 100) end,
      fun(_) -> {ok, [{lost_loop, 100}, {lost_chain, 100, 2}]} end},
     {"finding fsinfo_free", 32, fun(V) -> erx_fat_damage:poke(V, 1, 488, <<5:32/little>>) end,
      fun(V) -> {ok, [{fsinfo_free, 5, free_count(V)}]} end},
     {"finding fsinfo_next", 32, fun(V) -> erx_fat_damage:poke(V, 1, 492, <<70000:32/little>>) end,
      fun(_) -> {ok, [{fsinfo_next, 70000, invalid}]} end},
     {"finding fsinfo_next not free", 32, fun(V) -> erx_fat_damage:poke(V, 1, 492, <<3:32/little>>) end,
      fun(_) -> {ok, [{fsinfo_next, 3, not_free}]} end},
     {"finding fat_copy_differs", 16, fun(V) -> erx_fat_damage:fat_copy(V, 1, 100, 16#ffff) end,
      fun(_) -> {ok, [{fat_copy_differs, 1}]} end}].

free_count(V) ->
    {ok, Info} = (erx_fat_damage:read(V))(1),
    {Free, _Next} = erx_fat_alloc:fsinfo(Info),
    Free.

volumes() -> #{16 => erx_fat_damage:volume(16, tree()), 32 => erx_fat_damage:volume(32, tree())}.

each_finding_test_() ->
    Volumes = volumes(),
    [{Description, fun() ->
                           Clean = maps:get(Type, Volumes),
                           ?assertEqual(Expected(Clean), check(Damage(Clean)))
                   end}
     || {Description, Type, Damage, Expected} <- cases()].

%% A clean volume has no finding, and the FAT server's own check agrees.
clean_volumes_have_no_finding_test() ->
    maps:foreach(fun(_Type, V) ->
                         ?assertEqual({ok, []}, check(V)),
                         {ok, Fat} = erx_fat:mount(erx_fat_damage:read(V), erx_fat_damage:sectors(V)),
                         ?assertEqual(ok, erx_fat:check(Fat))
                 end, volumes()).

fsimg_volumes_have_no_finding_test() ->
    case os:getenv("ERX_FAT_IMAGES") of
        false ->
            ok;
        Directory ->
            [begin
                 {ok, Bytes} = file:read_file(filename:join(Directory, Image)),
                 Read = fun(I) when I < byte_size(Bytes) div ?SECTOR -> {ok, binary:part(Bytes, I * ?SECTOR, ?SECTOR)};
                           (_) -> {error, eio}
                        end,
                 ?assertEqual({Image, {ok, []}}, {Image, erx_fat_check:check(Read, byte_size(Bytes) div ?SECTOR)})
             end || Image <- filelib:wildcard("*.img", Directory)]
    end.

%% A boot sector that claims more sectors than the file holds is refused with
%% nothing read past it.
a_volume_longer_than_its_file_is_refused_reading_only_the_boot_sector_test() ->
    V = maps:get(16, volumes()),
    {Answer, Highest} = bounded(V#{sectors := 4000}),
    ?assertEqual({fatal, {boot_sector, longer_than_file}}, Answer),
    ?assertEqual(0, Highest).

%% The bounds: each refused within the command's heap; a volume of too
%% many clusters before any FAT sector past the one admission reads.
too_many_clusters_are_refused_before_the_fat_is_read_test() ->
    V = erx_fat_damage:volume(32, [], #{clusters => erx_fat:checked_clusters_max() + 1}),
    {Answer, Highest} = bounded(V),
    ?assertEqual({refused, {bound, clusters}}, Answer),
    ?assertEqual(maps:get(first_fat, erx_fat_damage:layout(V)), Highest).

too_many_directories_are_refused_test_() ->
    {timeout, 120, fun() ->
                           Count = 1048576 div (64 + 6) + 1,
                           Tree = [{dir, iolist_to_binary(io_lib:format("D~5..0b", [N])), []} || N <- lists:seq(1, Count)],
                           V = erx_fat_damage:volume(16, Tree, #{clusters => 20000, root_entries => 15008}),
                           ?assertMatch({{refused, {bound, directories}}, _}, bounded(V))
                   end}.

too_many_edits_are_refused_test_() ->
    {timeout, 60, fun() ->
                          V = lists:foldl(fun(C, Acc) -> erx_fat_damage:fat(Acc, C, 1) end,
                                          erx_fat_damage:volume(16, tree(), #{clusters => 20000}),
                                          lists:seq(1000, 1000 + 12288)),
                          ?assertMatch({{refused, {bound, edits}}, _}, bounded(V))
                  end}.

too_many_findings_are_refused_test_() ->
    {timeout, 60, fun() ->
                          V = lists:foldl(fun(C, Acc) -> erx_fat_damage:fat(Acc, C, 16#ffff) end,
                                          erx_fat_damage:volume(16, tree(), #{clusters => 20000}),
                                          lists:seq(1000, 1000 + 16384)),
                          ?assertMatch({{refused, {bound, findings}}, _}, bounded(V))
                  end}.

%% A path past its bound keeps its last names, the earlier shown as `...`.
a_deep_path_keeps_its_last_bytes_test() ->
    Name = fun(N) -> {long, iolist_to_binary([integer_to_list(N), lists:duplicate(200, $a)]), <<"DIR~", (integer_to_binary(N))/binary>>} end,
    Tree = lists:foldl(fun(N, Inner) -> [{dir, Name(N), Inner}] end, [{file, <<"F.TXT">>, 100}], lists:seq(1, 6)),
    V = erx_fat_damage:volume(16, Tree),
    [Deep] = [Path || Path <- maps:keys(maps:get(paths, V)), binary:longest_common_suffix([Path, <<"/F.TXT">>]) =:= 6],
    {ok, [{size_too_large, Shown, 5000, 512}]} = check(erx_fat_damage:size(V, Deep, 5000)),
    ?assert(byte_size(Shown) =< 1024 + 3),
    ?assertMatch(<<"...", _/binary>>, Shown),
    ?assertEqual(binary:part(Deep, byte_size(Deep), -(byte_size(Shown) - 3)), binary:part(Shown, 3, byte_size(Shown) - 3)).

%% The check of V in a process whose heap limit is the command's, which a pass
%% kills; with the highest sector it read.
bounded(V) ->
    Highest = atomics:new(1, [{signed, true}]),
    atomics:put(Highest, 1, -1),
    Read = erx_fat_damage:read(V),
    Logged = fun(I) -> atomics:put(Highest, 1, max(I, atomics:get(Highest, 1))), Read(I) end,
    Self = self(),
    {Pid, Ref} = spawn_opt(fun() -> Self ! {self(), erx_fat_check:check(Logged, erx_fat_damage:sectors(V))} end,
                           [monitor, {max_heap_size, #{size => ?HEAP_BYTES div erlang:system_info(wordsize),
                                                        kill => true, error_logger => false}}]),
    receive
        {Pid, Answer} -> erlang:demonitor(Ref, [flush]), {Answer, atomics:get(Highest, 1)};
        {'DOWN', Ref, process, Pid, Why} -> error({checker_died, Why})
    end.
