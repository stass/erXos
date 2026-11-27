%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The repairs of the FAT checker, erx_fat_check:write/4 (docs/design-fsck-fat.md,
%% "Writing a repair" and "Host tests"), over erx_fat_check_tests' damaged volumes,
%% laid out by erx_fat_damage with a /LOST.DIR and every file's sectors filled with
%% bytes of its own. Each repair is written to a medium in the test process that
%% records every write and flush; a repaired volume is checked again and by the FAT
%% server's own check; and a repair cut after every commit and inside each commit,
%% then run again, keeps every cluster allocated and every file the uninterrupted
%% repair keeps (FK-R3).

-module(erx_fat_repair_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).
-define(UNKNOWN, 16#ffffffff).
%% A commit of more writes than this is cut at each prefix and with each write left
%% out, not at every subset.
-define(SUBSETS_UP_TO, 4).

%% ---------------------------------------------------------------------------
%% The volumes and the medium
%% ---------------------------------------------------------------------------

tree() -> erx_fat_check_tests:tree() ++ [{dir, <<"LOST.DIR">>, []}].

%% The clean volume of Type, each file's sectors filled with bytes of its own.
volume(Type) ->
    V = erx_fat_damage:volume(Type, tree()),
    #{data_start := DataStart} = erx_fat_damage:layout(V),
    lists:foldl(fun({Path, Cluster}, Acc) ->
                        Fill = binary:copy(<<(erlang:phash2({Path, Cluster})):32>>, ?SECTOR div 4),
                        erx_fat_damage:poke(Acc, DataStart + Cluster - 2, 0, Fill)
                end, V, [{Path, Cluster} || Path <- maps:keys(maps:get(paths, V)), is_file(V, Path),
                                             First <- [erx_fat_damage:first(V, Path)], First =/= 0,
                                             Cluster <- erx_fat_damage:chain(V, First)]).

is_file(V, Path) ->
    {Sector, Offset} = erx_fat_damage:entry_at(V, Path),
    {ok, <<_:Offset/binary, _:11/binary, Attributes, _/binary>>} = (erx_fat_damage:read(V))(Sector),
    Attributes band 16#10 =:= 0.

check(V) -> erx_fat_check:check(erx_fat_damage:read(V), erx_fat_damage:sectors(V)).

%% Repair written to V through a medium that records each write and flush and
%% refuses any sector outside the volume; the volume written and the record, oldest
%% first, each {write, Sector, Bytes} or flush.
written(V, Repair) ->
    written(V, Repair, fun(_Sector) -> ok end).

written(V = #{data := Data}, Repair, Watch) ->
    Sectors = erx_fat_damage:sectors(V),
    Medium = ets:new(medium, [set, private]),
    ets:insert(Medium, {log, []}),
    Read = fun(S) when S >= 0, S < Sectors ->
                   case ets:lookup(Medium, S) of [{S, B}] -> {ok, B}; [] -> (erx_fat_damage:read(V))(S) end
           end,
    Log = fun(Event) -> [{log, L}] = ets:lookup(Medium, log), ets:insert(Medium, {log, [Event | L]}) end,
    Write = fun(S, B) when S >= 0, S < Sectors, byte_size(B) =:= ?SECTOR ->
                    ets:insert(Medium, {S, B}), Log({write, S, B}), Watch(S), ok
            end,
    Flush = fun() -> Log(flush), ok end,
    ok = erx_fat_check:write(Repair, Read, Write, Flush),
    [{log, Events}] = ets:lookup(Medium, log),
    Written = maps:from_list([{S, B} || {S, B} <- ets:tab2list(Medium), is_integer(S)]),
    ets:delete(Medium),
    {V#{data := maps:merge(Data, Written)}, lists:reverse(Events)}.

repaired(V) ->
    {ok, _Findings, Repair} = check(V),
    written(V, Repair).

%% The record's commits, each the writes before a flush.
commits(Events) -> commits(Events, [], []).

commits([], [], Done) -> lists:reverse(Done);
commits([flush | Rest], Writes, Done) -> commits(Rest, [], [lists:reverse(Writes) | Done]);
commits([{write, S, B} | Rest], Writes, Done) -> commits(Rest, [{S, B} | Writes], Done).

with_writes(V = #{data := Data}, Writes) -> V#{data := maps:merge(Data, maps:from_list(Writes))}.

%% ---------------------------------------------------------------------------
%% What a volume holds
%% ---------------------------------------------------------------------------

fat(V) ->
    {ok, Fat} = erx_fat:admission(erx_fat_damage:read(V), erx_fat_damage:sectors(V)),
    Fat.

%% Cluster's entry of the first FAT, in its value bits.
entry(V, Cluster) ->
    #{type := Type, fat_start := FirstFat} = erx_fat:layout(fat(V)),
    {Index, Offset} = erx_fat_alloc:entry_place(Type, Cluster),
    {ok, <<_:Offset/binary, Value:Type/little, _/binary>>} = (erx_fat_damage:read(V))(FirstFat + Index),
    case Type of 16 -> Value; 32 -> Value band 16#0fffffff end.

dirty(V) ->
    #{type := Type} = erx_fat:layout(fat(V)),
    not maps:get(clean, erx_fat_alloc:volume_flags(Type, entry(V, 1))).

allocated(V) ->
    #{clusters := Clusters} = erx_fat:layout(fat(V)),
    [C || C <- lists:seq(2, Clusters + 1), entry(V, C) =/= 0].

%% Every name the FAT server lists, by path, with its first cluster, and each file's
%% contents' hash, or why they do not read, as a cut may leave a size not yet shrunk.
names(V) ->
    Fat = fat(V),
    names(Fat, erx_fat:root(Fat), <<>>, [root]).

%% Directory Dir's names, below the directories Seen by their first clusters, so a
%% damaged directory that names itself or an ancestor is listed once.
names(Fat, Dir, Prefix, Seen) ->
    case erx_fat:list(Dir, Fat) of
        {ok, Entries} ->
            lists:append([named(Fat, <<Prefix/binary, $/, Name/binary>>, Node, Seen)
                          || {Name, Node} <- Entries, Name =/= <<".">>, Name =/= <<"..">>]);
        {error, _} ->
            []
    end.

named(Fat, Path, Node, Seen) ->
    First = erx_fat:first(Node),
    case erx_fat:attr(Node) of
        #{kind := dir} ->
            [{Path, First, dir} | case lists:member(First, Seen) of
                                      true -> [];
                                      false -> names(Fat, Node, Path, [First | Seen])
                                  end];
        #{kind := file, size := Size} ->
            Hash = case erx_fat:read(Node, 0, Size, Fat) of
                       {ok, Bytes} -> erlang:md5(Bytes);
                       {error, Why} -> Why
                   end,
            [{Path, erx_fat:first(Node), Hash}]
    end.

files(V) -> lists:sort([{Path, Hash} || {Path, _First, Hash} <- names(V), Hash =/= dir]).

%% FK-R2: a second check finds nothing but kept lost chains, the FAT server's check
%% passes and the writable rule allows a writable mount.
assert_writable(V) ->
    {ok, Findings, _} = check(V),
    ?assertEqual([], [F || F <- Findings, not kept(F)]),
    {ok, Fat} = erx_fat:mount(erx_fat_damage:read(V), erx_fat_damage:sectors(V)),
    ?assertEqual(ok, erx_fat:check(Fat)),
    ?assertEqual(ok, erx_fat_alloc:writable(erx_fat:info(Fat))).

kept({lost_chain, _, _, Fate}) -> Fate =/= named;
kept(_) -> false.

%% ---------------------------------------------------------------------------
%% The tests
%% ---------------------------------------------------------------------------

%% The damaged volumes of erx_fat_check_tests' cases that answer a repair.
repairs() ->
    Volumes = #{16 => volume(16), 32 => volume(32)},
    [{Description, Damage(maps:get(Type, Volumes))} || {Description, Type, Damage, Expected} <- erx_fat_check_tests:cases(),
                                                         element(1, Expected(maps:get(Type, Volumes))) =:= ok].

each_repair_leaves_a_writable_volume_test_() ->
    [{Description, fun() ->
                           {Repaired, _} = repaired(V),
                           assert_writable(Repaired)
                   end} || {Description, V} <- repairs()].

%% A lost chain is named in /LOST.DIR, and read there with its contents.
a_lost_chain_is_named_in_lost_dir_test() ->
    V = volume(16),
    Lost = erx_fat_damage:poke(V, element(1, erx_fat_damage:entry_at(V, <<"/HELLO.TXT">>)),
                               element(2, erx_fat_damage:entry_at(V, <<"/HELLO.TXT">>)), <<16#e5>>),
    First = erx_fat_damage:first(V, <<"/HELLO.TXT">>),
    ?assertMatch({ok, [{lost_chain, First, 2, named}], _}, check(Lost)),
    {Repaired, _} = repaired(Lost),
    Name = <<"/LOST.DIR/", (integer_to_binary(First))/binary>>,
    ?assertMatch([{Name, First, _}], [N || N = {P, _, _} <- names(Repaired), P =:= Name]),
    assert_writable(Repaired).

%% With no /LOST.DIR, a lost chain stays allocated and unnamed, and the volume is
%% marked clean.
a_lost_chain_without_lost_dir_is_kept_test() ->
    V = erx_fat_damage:volume(16, erx_fat_check_tests:tree()),
    {Sector, Offset} = erx_fat_damage:entry_at(V, <<"/HELLO.TXT">>),
    Lost = erx_fat_damage:poke(V, Sector, Offset, <<16#e5>>),
    First = erx_fat_damage:first(V, <<"/HELLO.TXT">>),
    {Repaired, _} = repaired(Lost),
    ?assertMatch({ok, [{lost_chain, First, 2, no_lost_dir}], _}, check(Repaired)),
    ?assertNot(dirty(Repaired)),
    ?assert(lists:member(First, allocated(Repaired))).

%% The final ownership check: a second `.` in slot 5 of a subdirectory is repaired
%% (a checker without that row answers not_writable instead).
a_second_dot_is_repaired_test() ->
    V = volume(16),
    {Sector, Offset} = erx_fat_damage:entry_at(V, <<"/DOCS/SUB/NOTE.TXT">>),
    Dot = erx_fat_entry:encode(erx_fat_entry:new(<<".          ">>, 0, dir, erx_fat_damage:first(V, <<"/DOCS/SUB">>), 0)),
    Damaged = erx_fat_damage:poke(V, Sector, Offset + 3 * 32, Dot),
    {Repaired, _} = repaired(Damaged),
    assert_writable(Repaired).

%% Each step computed at its turn: a cut in the first FAT's first sector, the odd
%% header's fix and an FSInfo sector whose lead signature was damaged over stale
%% hints. After every write but the last the volume reads dirty; after the `fsinfo`
%% step the FSInfo hints read unknown; only the last write sets the clean bit.
each_step_is_computed_at_its_turn_test() ->
    V = volume(32),
    First = erx_fat_damage:first(V, <<"/HELLO.TXT">>),
    Damaged = lists:foldl(fun(F, Acc) -> F(Acc) end, V,
                          [fun(A) -> erx_fat_damage:fat(A, 0, 16#0ffffff0) end,
                           fun(A) -> erx_fat_damage:fat(A, First + 1, 16#0ffffff0) end,
                           fun(A) -> erx_fat_damage:poke(A, 1, 488, <<5:32/little, 3:32/little>>) end,
                           fun(A) -> erx_fat_damage:poke(A, 1, 0, <<"X">>) end]),
    {Repaired, Events} = repaired(Damaged),
    Writes = [{S, B} || {write, S, B} <- Events],
    Prefixes = [lists:sublist(Writes, N) || N <- lists:seq(1, length(Writes) - 1)],
    ?assertEqual([], [N || {N, P} <- lists:zip(lists:seq(1, length(Prefixes)), Prefixes),
                           not dirty(with_writes(Damaged, P))]),
    ?assertNot(dirty(Repaired)),
    {ok, Info} = (erx_fat_damage:read(Repaired))(1),
    ?assertEqual({?UNKNOWN, ?UNKNOWN}, erx_fat_alloc:fsinfo(Info)),
    assert_writable(Repaired).

%% FK-R3: each repair cut after every commit and after every subset of a commit's
%% writes reads dirty unless the cut followed the last write, keeps every cluster
%% allocated, adds no name to a free cluster and no second name to a cluster; run
%% again, it meets FK-R2 and keeps every file the uninterrupted repair keeps.
a_cut_repair_loses_nothing_test_() ->
    [{Description, {timeout, 300, fun() -> cuts(V) end}} || {Description, V} <- repairs()].

cuts(V) ->
    {Repaired, Events} = repaired(V),
    Kept = files(Repaired),
    Commits = commits(Events),
    Before = allocated(V),
    Shared = shared(V),
    Named = firsts(V),
    lists:foreach(
      fun(K) ->
              Done = lists:append(lists:sublist(Commits, K - 1)),
              Commit = lists:nth(K, Commits),
              [begin
                   Cut = with_writes(V, Done ++ Subset),
                   Untouched = Done ++ Subset =:= [],
                   Last = K =:= length(Commits) andalso Subset =:= Commit,
                   ?assertEqual({K, Subset, not (Last orelse Untouched)}, {K, Subset, dirty(Cut) andalso not Untouched}),
                   ?assertEqual({K, Subset, []}, {K, Subset, Before -- allocated(Cut)}),
                   ?assertEqual({K, Subset, []}, {K, Subset, shared(Cut) -- Shared}),
                   Free = [N || N = {_, C} <- firsts(Cut) -- Named, C =/= 0, not lists:member(C, allocated(Cut))],
                   ?assertEqual({K, Subset, []}, {K, Subset, Free}),
                   {Again, _} = repaired(Cut),
                   assert_writable(Again),
                   ?assertEqual({K, Subset, []}, {K, Subset, Kept -- files(Again)})
               end || Subset <- subsets(Commit)]
      end, lists:seq(1, length(Commits))).

subsets(Writes) when length(Writes) =< ?SUBSETS_UP_TO ->
    lists:foldr(fun(W, Acc) -> Acc ++ [[W | S] || S <- Acc] end, [[]], Writes);
subsets(Writes) ->
    [lists:sublist(Writes, N) || N <- lists:seq(0, length(Writes))] ++ [Writes -- [W] || W <- Writes].

firsts(V) -> [{Path, First} || {Path, First, _} <- names(V), is_integer(First)].

%% The clusters two names start at.
shared(V) ->
    Firsts = [C || {_, C} <- firsts(V), C =/= 0],
    lists:usort(Firsts -- lists:usort(Firsts)).
