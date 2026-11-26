%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% FAT's names, erx_fat_name, and the FAT server's directory changes, erx_fat_dir
%% (docs/design-storage.md, "Removable media: FAT"), over the FAT16 and FAT32
%% volumes test/host/erx_fat_dir_test.rb has fsimg write into ERX_FAT_IMAGES. Every
%% batch's plan is applied step by step to an image held as erx_fat_alloc_tests
%% holds it, and cut inside every step: with each write of the step alone and with
%% each left out, the volume passes the ownership check (erx_fat:check/1), so a cut
%% anywhere leaves names reaching only allocated clusters, no cluster in two chains
%% or under two names, and every `..` naming its parent. The finished volume passes
%% fsimg's verify (ERX_FSIMG), and fsimg's extract gives the expected tree.

-module(erx_fat_dir_tests).

-include_lib("eunit/include/eunit.hrl").

-export([check_bound_case/0, ops/2]).

-define(SECTOR, 512).
-define(TIME, 1700000000).

%% ---------------------------------------------------------------------------
%% Names
%% ---------------------------------------------------------------------------

names_the_server_refuses_test() ->
    [?assertEqual({error, einval}, erx_fat_name:check(Name))
     || Name <- [<<>>, <<".">>, <<"..">>, <<" lead">>, <<"trail ">>, <<"dot.">>, <<"a", 16#ff>>, <<"tab\tx">>]
            ++ [<<"a", C, "b">> || C <- "\"*/:<>?\\|"]],
    ?assertMatch({ok, _}, erx_fat_name:check(binary:copy(<<"n">>, 255))),
    ?assertEqual({error, enametoolong}, erx_fat_name:check(binary:copy(<<"n">>, 256))),
    %% 63 Deseret letters are 252 bytes of UTF-8 and 126 code units; 64 pass 255 bytes.
    ?assertMatch({ok, _}, erx_fat_name:check(binary:copy(<<16#10400/utf8>>, 63))),
    ?assertEqual({error, enametoolong}, erx_fat_name:check(binary:copy(<<16#10400/utf8>>, 64))).

names_compare_by_bmp_simple_uppercase_test() ->
    Same = [{<<"readme.TXT">>, <<"README.txt">>}, {<<"\x{e9}t\x{e9}"/utf8>>, <<"\x{c9}T\x{c9}"/utf8>>},
            {<<"\x{3c9}mega"/utf8>>, <<"\x{3a9}MEGA"/utf8>>}, {<<"\x{44f}"/utf8>>, <<"\x{42f}"/utf8>>}],
    [?assertEqual(erx_fat_name:key(A), erx_fat_name:key(B)) || {A, B} <- Same],
    %% Deseret's letters lie beyond the plane: their surrogates compare as they are.
    ?assertNotEqual(erx_fat_name:key(<<16#10428/utf8>>), erx_fat_name:key(<<16#10400/utf8>>)),
    ?assertEqual("17.0.0", erx_fat_case:unicode()).

%% The vectors of tools/lib/erx/fat_short_names.rb: a name that fits 8.3 in one
%% case per part is its short form with the case flags that restore it.
short_names_of_names_that_fit_test() ->
    Free = [],
    ?assertEqual({<<"START4  ELF">>, 16#18, short_only}, short(<<"start4.elf">>, Free)),
    ?assertEqual({<<"README     ">>, 0, short_only}, short(<<"README">>, Free)),
    ?assertEqual({<<"OVERLAYS   ">>, 16#08, short_only}, short(<<"overlays">>, Free)),
    ?assertEqual({<<"KERNEL8 IMG">>, 16#10, short_only}, short(<<"KERNEL8.img">>, Free)),
    ?assertEqual({<<"START4  ELF">>, 0, long}, short(<<"Start4.elf">>, Free)),
    ?assertEqual({<<"LICENC~1BRO">>, 0, long}, short(<<"LICENCE.broadcom">>, Free)),
    ?assertEqual({<<"A_B~1   TXT">>, 0, long}, short(<<"a+b.txt">>, Free)),
    ?assertEqual({<<"AB~1    C  ">>, 0, long}, short(<<"a.b.c">>, Free)),
    ?assertEqual({<<"ABC~1      ">>, 0, long}, short(<<".abc">>, Free)),
    ?assertEqual({<<"___~1      ">>, 0, long}, short(<<"\x{65e5}\x{672c}\x{8a9e}"/utf8>>, Free)).

%% Short names taken one after another number their tails upwards.
short_name_collision_series_test() ->
    Series = lists:foldl(fun(N, Taken) ->
                                 Name = iolist_to_binary(["longfilename-", integer_to_list(N), ".txt"]),
                                 {Short, 0, long} = short(Name, Taken),
                                 Taken ++ [Short]
                         end, [], lists:seq(1, 10)),
    ?assertEqual([iolist_to_binary(["LONGFI~", integer_to_list(N), "TXT"]) || N <- lists:seq(1, 9)]
                 ++ [<<"LONGF~10TXT">>], Series).

%% The short name of Name in a directory whose short entries are Taken, each
%% claimed against Name's basis as erx_fat_dir reads them.
short(Name, Taken) ->
    Basis = erx_fat_name:short_basis(Name),
    Claims = [erx_fat_name:claim(Basis, Short) || Short <- Taken],
    erx_fat_name:short_name(Basis, lists:member(basis, Claims), fun(N) -> lists:member(N, Claims) end).

long_entries_carry_the_name_test() ->
    {ok, Units} = erx_fat_name:check(<<"Long File Name.dat">>),
    Short = <<"LONGFI~1DAT">>,
    [Last, First] = erx_fat_name:long_entries(Units, Short),
    Sum = erx_fat_name:checksum(Short),
    ?assertMatch(<<16#42, _:10/binary, 16#0f, 0, Sum, _/binary>>, Last),
    ?assertMatch(<<16#01, "L", 0, "o", 0, _/binary>>, First),
    %% The last part, "e.dat", ends in one zero unit, then 0xFFFF to the entry's end.
    <<_, Part1:10/binary, _:3/binary, Part2:12/binary, 0:16, Part3:4/binary>> = Last,
    ?assertEqual(<<"e", 0, ".", 0, "d", 0, "a", 0, "t", 0>>, Part1),
    ?assertEqual(<<0, 0, (binary:copy(<<16#ff>>, 10))/binary>>, Part2),
    ?assertEqual(<<16#ff, 16#ff, 16#ff, 16#ff>>, Part3).

%% ---------------------------------------------------------------------------
%% Changes over fsimg's volumes
%% ---------------------------------------------------------------------------

volumes_test_() ->
    {timeout, 600, [{Name, fun() -> volume_ops(Name) end} || Name <- ["fat16.img", "fat32.img"]]}.

volume_ops(Image) ->
    Fat = mounted(Image),
    ok = erx_fat:check(Fat),
    Tree = ops(Fat, fun cuts/2),
    ?assertMatch({0, _}, erx_fat_alloc_tests:verify(erx_fat_alloc_tests:flat())),
    ?assertEqual(Tree, extracted(erx_fat_alloc_tests:flat())).

%% The changes every volume takes, batch by batch, each batch's plan applied through
%% Apply; the tree the volume then holds, as {Path, Bytes} sorted.
ops(Fat, Apply) ->
    Root = erx_fat:root(Fat),
    Folder = <<"New Folder">>,
    Entry = fun(N) -> iolist_to_binary(io_lib:format("entry number ~2..0w with a long name", [N])) end,
    B1 = batch(Fat, Apply, fun(B) ->
               {B2, F} = node_of(erx_fat_dir:mkdir(B, Root, Folder, ?TIME)),
               {B3, _} = node_of(erx_fat_dir:create(B2, F, <<"a file with a long name.txt">>, ?TIME)),
               {B4, _} = node_of(erx_fat_dir:create(B3, Root, <<"\x{dc}n\x{ef}c\x{f6}d\x{e9}.txt"/utf8>>, ?TIME)),
               {B5, _} = node_of(erx_fat_dir:create(B4, Root, <<16#10400/utf8, " deseret">>, ?TIME)),
               {B6, _} = node_of(erx_fat_dir:create(B5, Root, <<16#10428/utf8, " deseret">>, ?TIME)),
               ?assertEqual({error, eexist}, erx_fat_dir:create(B6, Root, <<"\x{fc}N\x{cf}C\x{d6}D\x{c9}.TXT"/utf8>>, ?TIME)),
               ?assertEqual({error, eexist}, erx_fat_dir:mkdir(B6, Root, <<"new folder">>, ?TIME)),
               B6
           end, dirty(Fat)),
    %% Twenty names of four entries each grow the folder past its first cluster.
    B7 = batch(Fat, Apply, fun(B) ->
               F = walked(B, Root, Folder),
               lists:foldl(fun(N, Acc) -> element(1, node_of(erx_fat_dir:create(Acc, F, Entry(N), ?TIME))) end,
                           B, lists:seq(1, 20))
           end, B1),
    B8 = batch(Fat, Apply, fun(B) ->
               F = walked(B, Root, Folder),
               Sub = walked(B, Root, <<"sub">>),
               {ok, _, Ba} = erx_fat_dir:rename(B, Root, <<"hello.txt">>, F, <<"hello renamed.txt">>),
               {ok, _, Bb} = erx_fat_dir:rename(Ba, Sub, <<"deeper">>, F, <<"Deeper moved">>),
               {ok, {_, Replaced}, Bc} = erx_fat_dir:rename(Bb, F, Entry(1), F, Entry(2)),
               ?assertNotEqual(none, Replaced),
               {ok, Empty, Bd} = erx_fat_dir:remove(Bc, Root, <<"EMPTY">>),
               0 = erx_fat:first(Empty),
               ?assertEqual({error, enotempty}, erx_fat_dir:rmdir(Bd, Root, <<"sub">>)),
               Moved = walked(Bd, F, <<"Deeper moved">>),
               ?assertEqual({error, einval}, erx_fat_dir:rename(Bd, Root, Folder, Moved, <<"loop">>)),
               ?assertEqual({error, einval}, erx_fat_dir:rename(Bd, Root, Folder, walked(Bd, Root, Folder), <<"self">>)),
               ?assertEqual({error, enotdir}, erx_fat_dir:rename(Bd, F, <<"Deeper moved">>, Root,
                                                                 <<"\x{dc}n\x{ef}c\x{f6}d\x{e9}.txt"/utf8>>)),
               ?assertEqual({error, eisdir}, erx_fat_dir:rename(Bd, Root, <<"\x{dc}n\x{ef}c\x{f6}d\x{e9}.txt"/utf8>>,
                                                                Root, Folder)),
               ?assertEqual({error, eisdir}, erx_fat_dir:remove(Bd, Root, Folder)),
               ?assertEqual({error, enoent}, erx_fat_dir:remove(Bd, Root, <<"absent">>)),
               {Be, _} = node_of(erx_fat_dir:mkdir(Bd, Root, <<"Gone">>, ?TIME)),
               {ok, Gone, Bf} = erx_fat_dir:rmdir(Be, Root, <<"gone">>),
               {ok, Bg} = erx_fat_dir:free(Bf, erx_fat:first(Gone)),
               Bg
           end, B7),
    B9 = batch(Fat, Apply, fun(B) ->
              Sub = walked(B, Root, <<"sub">>),
              {ok, File, Ba} = erx_fat_dir:remove(B, Sub, <<"long file name.dat">>),
              {ok, Bb} = erx_fat_dir:free(Ba, erx_fat:first(File)),
              {ok, Dir, Bc} = erx_fat_dir:rmdir(Bb, Root, <<"sub">>),
              {ok, Bd} = erx_fat_dir:free(Bc, erx_fat:first(Dir)),
              {ok, _, Be} = erx_fat_dir:remove(Bd, Root, <<16#10428/utf8, " deseret">>),
              %% A case variant of a name renamed onto itself takes the new case.
              {ok, _, Bf} = erx_fat_dir:rename(Be, Root, <<"new folder">>, Root, <<"New folder">>),
              Bf
          end, B8),
    finished(Fat, Apply, B9),
    Folder2 = <<"New folder">>,
    lists:sort([{<<Folder2/binary, "/hello renamed.txt">>, <<"hello, stick\n">>},
                {<<Folder2/binary, "/Deeper moved/x.TXT">>, <<"deep\n">>},
                {<<Folder2/binary, "/a file with a long name.txt">>, <<>>},
                {<<"\x{dc}n\x{ef}c\x{f6}d\x{e9}.txt"/utf8>>, <<>>}, {<<16#10400/utf8, " deseret">>, <<>>}]
               ++ [{<<Folder2/binary, "/", (Entry(N))/binary>>, <<>>} || N <- lists:seq(2, 20)]).

%% Change applied to batch B, committed until the allocator's releases finish.
batch(Fat, Apply, Change, B) -> committed(Fat, Apply, Change(B)).

%% The volume's last batches applied after B, so its clean bit is set again.
finished(Fat, Apply, B) ->
    case erx_fat_dir:finish(B) of
        {ok, Plan, finished} -> Apply(Fat, Plan);
        {ok, Plan, B1} -> Apply(Fat, Plan), finished(Fat, Apply, B1)
    end.

committed(Fat, Apply, B) ->
    {ok, Plan, B1} = erx_fat_dir:commit(B),
    Apply(Fat, Plan),
    case erx_fat_dir:held(B1) of
        0 -> B1;
        _ -> committed(Fat, Apply, B1)
    end.

%% Plan applied step by step, the volume checked at every cut inside each step:
%% each write of the step alone, and the step without each write.
cuts(Fat, Plan) ->
    lists:foreach(fun({Step, Writes}) ->
                          [cut(Fat, Step, Some) || W <- Writes, Some <- [[W], Writes -- [W]]],
                          erx_fat_alloc_tests:apply_plan([{Step, Writes}]),
                          ?assertEqual({Step, ok}, {Step, erx_fat:check(Fat)})
                  end, Plan).

cut(Fat, Step, Writes) ->
    Saved = get(image),
    erx_fat_alloc_tests:apply_plan([{Step, Writes}]),
    ?assertEqual({cut_in, Step, ok}, {cut_in, Step, erx_fat:check(Fat)}),
    put(image, Saved).

node_of({ok, Node, B}) -> {B, Node}.

walked(B, Dir, Name) ->
    {ok, Node} = erx_fat:walk(Dir, Name, erx_fat_dir:view(B)),
    Node.

%% A new batch on Fat once the volume is marked in use, as before its first change
%% after a mount, which writes FAT32's FSInfo hints unknown.
dirty(Fat) ->
    {ok, Plan} = erx_fat_alloc:dirty(erx_fat_alloc:new(erx_fat:layout(Fat))),
    erx_fat_alloc_tests:apply_plan(Plan),
    erx_fat_dir:new(Fat).

mounted(Image) ->
    {ok, Base} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Image)),
    erx_fat_alloc_tests:use(Base),
    {ok, Fat} = erx_fat:mount(erx_fat_alloc_tests:reader(), byte_size(Base) div ?SECTOR),
    Fat.

%% fsimg's extract of Bytes: every file under its path, sorted.
extracted(Bytes) ->
    Image = filename:absname("extract.img"),
    Out = filename:absname("extracted"),
    ok = file:write_file(Image, Bytes),
    _ = file:del_dir_r(Out),
    ok = file:make_dir(Out),
    Port = open_port({spawn_executable, os:getenv("ERX_FSIMG")},
                     [{args, ["x", "-f", Image, "-C", Out]}, exit_status, stderr_to_stdout, binary]),
    {0, _} = erx_fat_alloc_tests:collect(Port, <<>>),
    {ok, [Top]} = file:list_dir(Out),
    lists:sort(files(filename:join(Out, Top), <<>>)).

files(Dir, Prefix) ->
    {ok, Names} = file:list_dir(Dir),
    lists:append([begin
                      Path = filename:join(Dir, Name),
                      Rel = case Prefix of <<>> -> unicode:characters_to_binary(Name);
                                _ -> <<Prefix/binary, "/", (unicode:characters_to_binary(Name))/binary>>
                            end,
                      case filelib:is_dir(Path) of
                          true -> files(Path, Rel);
                          false -> {ok, Bytes} = file:read_file(Path), [{Rel, Bytes}]
                      end
                  end || Name <- Names]).

%% ---------------------------------------------------------------------------
%% Directory growth, FAT16's root and the end marker
%% ---------------------------------------------------------------------------

%% A name of 255 code units takes 21 entries, more than a 512-byte cluster's 16, so
%% it begins in a directory's first cluster and ends in the one it grows by.
a_longest_name_spans_a_directory_s_clusters_test() ->
    Fat = mounted("fat32.img"),
    Root = erx_fat:root(Fat),
    Long = binary:copy(<<"n">>, 255),
    B = committed(Fat, fun cuts/2, element(1, node_of(erx_fat_dir:mkdir(dirty(Fat), Root, <<"d">>, ?TIME)))),
    D = walked(B, Root, <<"d">>),
    {ok, _, B1} = erx_fat_dir:create(B, D, Long, ?TIME),
    {ok, {[{Long, 2, 22}], #{total := 32}}} = erx_fat:fold(D, erx_fat_dir:view(B1), fun named/3, []),
    finished(Fat, fun cuts/2, committed(Fat, fun cuts/2, B1)),
    {ok, [{Long, _}]} = erx_fat:list(D, Fat),
    {0, _} = erx_fat_alloc_tests:verify(erx_fat_alloc_tests:flat()).

fat16s_root_fills_and_answers_enospc_test() ->
    Fat = mounted("fat16.img"),
    Root = erx_fat:root(Fat),
    Fill = fun Fill(B, N) ->
                   case erx_fat_dir:create(B, Root, iolist_to_binary(["root filler ", integer_to_list(N)]), ?TIME) of
                       {ok, _, B1} -> Fill(B1, N + 1);
                       {error, enospc} -> {B, N}
                   end
           end,
    {B, Count} = Fill(dirty(Fat), 1),
    ?assert(Count > 100),
    Apply = fun(_, Plan) -> erx_fat_alloc_tests:apply_plan(Plan) end,
    finished(Fat, Apply, committed(Fat, Apply, B)),
    ok = erx_fat:check(Fat),
    {0, _} = erx_fat_alloc_tests:verify(erx_fat_alloc_tests:flat()).

%% A name placed at a directory's end marker is followed by a new one, so what a
%% medium holds past the old marker is never read as a name.
a_name_past_the_end_marker_is_followed_by_one_test() ->
    Fat = mounted("fat32.img"),
    Root = erx_fat:root(Fat),
    B = committed(Fat, fun cuts/2, element(1, node_of(erx_fat_dir:mkdir(erx_fat_dir:new(Fat), Root, <<"g">>, ?TIME)))),
    G = walked(B, Root, <<"g">>),
    {ok, [Sector | _]} = erx_fat:cluster_sectors(Fat, erx_fat:first(G)),
    <<Dots:64/binary, _:32/binary, _/binary>> = erx_fat_alloc_tests_sector(Sector),
    Garbage = <<"GARBAGE TXT", 16#20, 0:(14 * 8), 2:16/little, 5:32/little>>,
    erx_fat_alloc_tests:apply_plan([{craft, [{Sector, <<Dots/binary, 0:256, Garbage/binary, 0:((?SECTOR - 128) * 8)>>}]}]),
    {ok, _, B1} = erx_fat_dir:create(B, G, <<"x">>, ?TIME),
    _ = committed(Fat, fun cuts/2, B1),
    ?assertMatch({ok, [{<<"x">>, _}]}, erx_fat:list(G, Fat)).

%% Live long-name entries before a free entry, carrying a short name's checksum,
%% never become the long name of a name stored as that short entry alone: the name
%% takes long-name entries of its own. A change in a file is enotdir.
stray_long_entries_never_name_a_short_only_name_test() ->
    Fat = mounted("fat32.img"),
    Root = erx_fat:root(Fat),
    B = committed(Fat, fun cuts/2, element(1, node_of(erx_fat_dir:mkdir(erx_fat_dir:new(Fat), Root, <<"s">>, ?TIME)))),
    S = walked(B, Root, <<"s">>),
    {ok, [Sector | _]} = erx_fat:cluster_sectors(Fat, erx_fat:first(S)),
    <<Dots:64/binary, _/binary>> = erx_fat_alloc_tests_sector(Sector),
    {ok, Units} = erx_fat_name:check(<<"stray">>),
    [Stray] = erx_fat_name:long_entries(Units, <<"README     ">>),
    Deleted = <<16#e5, 0:(31 * 8)>>,
    erx_fat_alloc_tests:apply_plan([{craft, [{Sector, <<Dots/binary, Stray/binary, Deleted/binary,
                                                        0:((?SECTOR - 128) * 8)>>}]}]),
    {ok, _, B1} = erx_fat_dir:create(B, S, <<"README">>, ?TIME),
    _ = committed(Fat, fun cuts/2, B1),
    ?assertMatch({ok, [{<<"README">>, _}]}, erx_fat:list(S, Fat)),
    {ok, File} = erx_fat:walk(S, <<"README">>, Fat),
    ?assertEqual({error, enotdir}, erx_fat_dir:create(erx_fat_dir:new(Fat), File, <<"x">>, ?TIME)).

%% Each name fold/4 meets, with the indices of its first and its short entry.
named(Index, {short, _, {Name, _, Start}}, Acc) -> Acc ++ [{Name, Start, Index}];
named(_Index, _Event, Acc) -> Acc.

erx_fat_alloc_tests_sector(Sector) ->
    {ok, Bytes} = (erx_fat_alloc_tests:reader())(Sector),
    Bytes.

%% Run alone by test/host/erx_fat_dir_test.rb with the check's bound on pending
%% directories seeded to 2: a volume of more is too large, not a crash.
check_bound_case() ->
    Fat = mounted("fat32.img"),
    Root = erx_fat:root(Fat),
    B = lists:foldl(fun(Name, Acc) -> element(1, node_of(erx_fat_dir:mkdir(Acc, Root, Name, ?TIME))) end,
                    erx_fat_dir:new(Fat), [<<"d1">>, <<"d2">>, <<"d3">>]),
    _ = committed(Fat, fun(_, Plan) -> erx_fat_alloc_tests:apply_plan(Plan) end, B),
    ?assertEqual({read_only, too_large}, erx_fat:check(Fat)).

%% A directory of exactly the specification's 65,536 entries reads, and passes the
%% ownership check: its chain of 4,096 clusters of 512 bytes is not refused at its
%% last cluster.
a_directory_of_the_entries_bound_reads_test() ->
    Fat = mounted("fat32.img"),
    Root = erx_fat:root(Fat),
    Apply = fun(_, Plan) -> erx_fat_alloc_tests:apply_plan(Plan) end,
    B = committed(Fat, Apply, element(1, node_of(erx_fat_dir:mkdir(erx_fat_dir:new(Fat), Root, <<"big">>, ?TIME)))),
    Big = walked(B, Root, <<"big">>),
    {ok, _, Alloc} = erx_fat_alloc:grow(erx_fat_alloc:new(erx_fat:layout(Fat)), erx_fat:first(Big), 4095),
    {ok, Plan, _} = erx_fat_alloc:commit(Alloc),
    erx_fat_alloc_tests:apply_plan(Plan),
    ?assertMatch({ok, {[], #{total := 65536}}}, erx_fat:fold(Big, Fat, fun named/3, [])),
    ?assertEqual({ok, []}, erx_fat:list(Big, Fat)),
    ?assertEqual(ok, erx_fat:check(Fat)).

%% A directory of 65,402 entries, 21,800 names of two long-name entries and a short
%% one, takes a create past them all and a rename of a name in the middle, found by
%% lookup, within the volume's memory bound, media_volume_bytes (2 MiB,
%% abi/formats/probe.txt): each change reads the directory a sector at a time and
%% keeps only what it looks for, so the process that runs them is never killed by a
%% heap of that bound.
a_directory_near_the_entries_bound_changes_within_the_memory_bound_test_() ->
    {timeout, 600, fun() ->
                           Flat = big_directory(21800),
                           Bound = 2097152 div erlang:system_info(wordsize),
                           {Pid, Ref} = spawn_opt(fun() -> big_directory_changes(Flat) end,
                                                  [monitor, {max_heap_size, #{size => Bound, kill => true,
                                                                              error_logger => false}}]),
                           receive {'DOWN', Ref, process, Pid, Reason} -> ?assertEqual(normal, Reason) end
                   end}.

big_name(N) -> iolist_to_binary(io_lib:format("name number ~5..0w of many", [N])).

%% fsimg's FAT32 volume with directory big of 4,096 clusters holding Count names
%% after its dot entries, as one flat image.
big_directory(Count) ->
    Fat = mounted("fat32.img"),
    Root = erx_fat:root(Fat),
    Apply = fun(_, Plan) -> erx_fat_alloc_tests:apply_plan(Plan) end,
    B = committed(Fat, Apply, element(1, node_of(erx_fat_dir:mkdir(erx_fat_dir:new(Fat), Root, <<"big">>, ?TIME)))),
    Big = walked(B, Root, <<"big">>),
    {ok, _, Alloc} = erx_fat_alloc:grow(erx_fat_alloc:new(erx_fat:layout(Fat)), erx_fat:first(Big), 4095),
    {ok, Plan, _} = erx_fat_alloc:commit(Alloc),
    erx_fat_alloc_tests:apply_plan(Plan),
    {ok, {_, #{sectors := Sectors}}} = erx_fat:fold(Big, Fat, fun(_, _, Acc) -> Acc end, none),
    [First | _] = tuple_to_list(Sectors),
    <<Dots:64/binary, _/binary>> = erx_fat_alloc_tests_sector(First),
    Entries = iolist_to_binary([Dots | [begin
                                            Short = iolist_to_binary(io_lib:format("N~7..0w   ", [N])),
                                            {ok, Units} = erx_fat_name:check(big_name(N)),
                                            [erx_fat_name:long_entries(Units, Short),
                                             erx_fat_entry:encode(erx_fat_entry:new(Short, 0, file, 0, ?TIME))]
                                        end || N <- lists:seq(1, Count)]]),
    Padded = <<Entries/binary, 0:((tuple_size(Sectors) * ?SECTOR - byte_size(Entries)) * 8)>>,
    erx_fat_alloc_tests:apply_plan([{craft, [{Sector, binary:part(Padded, I * ?SECTOR, ?SECTOR)}
                                             || {I, Sector} <- lists:enumerate(0, tuple_to_list(Sectors))]}]),
    erx_fat_alloc_tests:flat().

big_directory_changes(Flat) ->
    erx_fat_alloc_tests:use(Flat),
    {ok, Fat} = erx_fat:mount(erx_fat_alloc_tests:reader(), byte_size(Flat) div ?SECTOR),
    Big = walked(erx_fat_dir:new(Fat), erx_fat:root(Fat), <<"big">>),
    {ok, _, B1} = erx_fat_dir:create(erx_fat_dir:new(Fat), Big, <<"a new name past them all">>, ?TIME),
    {ok, _, B2} = erx_fat_dir:rename(B1, Big, big_name(10900), Big, <<"renamed in the middle">>),
    {ok, _, _} = erx_fat_dir:commit(B2),
    walked(B2, Big, <<"renamed in the middle">>).

%% ---------------------------------------------------------------------------
%% A file's contents: writes, appends, holes, cuts and growth
%% ---------------------------------------------------------------------------

contents_test_() ->
    {timeout, 600, [{Name, fun() -> contents_ops(Name) end} || Name <- ["fat16.img", "fat32.img"]]}.

contents_ops(Image) ->
    Fat = mounted(Image),
    Root = erx_fat:root(Fat),
    Pattern = fun(N, Seed) -> << <<((I * 7 + Seed) rem 251)>> || I <- lists:seq(1, N) >> end,
    A = Pattern(9000, 1),
    B1 = batch(Fat, fun mount_cuts/2, fun(B) ->
                   {Ba, F} = node_of(erx_fat_dir:create(B, Root, <<"copied file.bin">>, ?TIME)),
                   {ok, F1, Bb} = erx_fat_dir:write(Ba, F, 0, binary:part(A, 0, 5000), ?TIME),
                   {ok, F2, Bc} = erx_fat_dir:write(Bb, F1, 5000, binary:part(A, 5000, 4000), ?TIME),
                   ?assertMatch(#{size := 9000}, erx_fat:attr(F2)),
                   ?assertEqual({ok, A}, erx_fat:read(F2, 0, 9000, erx_fat_dir:view(Bc))),
                   ?assertEqual({error, efbig}, erx_fat_dir:write(Bc, F2, 16#ffffffff, <<"x">>, ?TIME)),
                   Bd = Bc, H = walked(Bd, Root, <<"hello.txt">>),
                   ?assertEqual({error, eisdir}, erx_fat_dir:write(Bd, Root, 0, <<"x">>, ?TIME)),
                   {ok, _, Be} = erx_fat_dir:write(Bd, H, 0, <<"rewritten">>, ?TIME),
                   Be
               end, dirty(Fat)),
    B2 = batch(Fat, fun mount_cuts/2, fun(B) ->
                   F = walked(B, Root, <<"copied file.bin">>),
                   %% A write past the size zeroes from the size to its offset.
                   {ok, F1, Ba} = erx_fat_dir:write(B, F, 12000, <<"tail">>, ?TIME),
                   %% A cut to the middle of a cluster, then growth: the cut-off bytes read zero.
                   {ok, F2, Bb} = erx_fat_dir:truncate(Ba, F1, 1000, ?TIME),
                   {ok, F3, Bc} = erx_fat_dir:truncate(Bb, F2, 3000, ?TIME),
                   ?assertEqual({ok, <<(binary:part(A, 0, 1000))/binary, 0:(2000 * 8)>>},
                                erx_fat:read(F3, 0, 5000, erx_fat_dir:view(Bc))),
                   {ok, _, Bd} = erx_fat_dir:setattr(Bc, F3, #{mtime => ?TIME + 60, read_only => true}),
                   G = walked(Bd, Root, <<"hello.txt">>),
                   {ok, G1, Be} = erx_fat_dir:truncate(Bd, G, 0, ?TIME),
                   ?assertEqual(0, erx_fat:first(G1)),
                   Be
               end, B1),
    B3 = batch(Fat, fun mount_cuts/2, fun(B) ->
                   G = walked(B, Root, <<"hello.txt">>),
                   {ok, _, Ba} = erx_fat_dir:write(B, G, 0, <<"again\n">>, ?TIME),
                   Ba
               end, B2),
    finished(Fat, fun mount_cuts/2, B3),
    F = walked(erx_fat_dir:new(Fat), Root, <<"copied file.bin">>),
    ?assertMatch(#{read_only := true, mtime := M} when M =:= ?TIME + 60, erx_fat:attr(F)),
    ?assertMatch({0, _}, erx_fat_alloc_tests:verify(erx_fat_alloc_tests:flat())),
    Tree = extracted(erx_fat_alloc_tests:flat()),
    ?assertEqual(<<(binary:part(A, 0, 1000))/binary, 0:(2000 * 8)>>, proplists:get_value(<<"copied file.bin">>, Tree)),
    ?assertEqual(<<"again\n">>, proplists:get_value(<<"hello.txt">>, Tree)).

%% Plan applied as cuts/2 applies it, every cut checked by what a mount then does:
%% a cut inside a step whose FAT sectors split a new run may leave the run's first
%% sector linking into a sector not yet written, which the ownership check finds,
%% but every such cut leaves the volume dirty, so it mounts read-only as `dirty`
%% before the check runs, and never answers wrongly.
mount_cuts(Fat, Plan) ->
    lists:foreach(fun({Step, Writes}) ->
                          [mount_cut(Fat, Step, Some) || W <- Writes, Some <- [[W], Writes -- [W]]],
                          erx_fat_alloc_tests:apply_plan([{Step, Writes}]),
                          ?assertEqual({Step, ok}, {Step, erx_fat:check(Fat)})
                  end, Plan).

mount_cut(Fat, Step, Writes) ->
    Saved = get(image),
    erx_fat_alloc_tests:apply_plan([{Step, Writes}]),
    case erx_fat:check(Fat) of
        ok -> ok;
        Refused ->
            {ok, Cut} = erx_fat:mount(erx_fat_alloc_tests:reader(), byte_size(element(1, Saved)) div ?SECTOR),
            ?assertMatch({cut_in, Step, {read_only, tree}, #{clean := false}},
                         {cut_in, Step, Refused, erx_fat:info(Cut)})
    end,
    put(image, Saved).
