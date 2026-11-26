%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a volume's writes (docs/design-storage.md, "Removable media: FAT",
%% "Durability"; docs/design-drives.md, "The writable rule"): a volume process over a
%% window proxy that holds fsimg's FAT16 or FAT32 volume as one binary in RAM, answers
%% writes and flushes and logs them, and may be cut after any write, as a stick pulled
%% out mid-batch. The image the volume leaves is checked by fsimg's verify and extract.
%% ERX_FAT_IMAGES as erx_media_volume_tests; ERX_FSIMG fsimg's binary.

-module(erx_media_volume_write_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SECTOR, 512).

%% ---------------------------------------------------------------------------
%% A RAM medium behind a window proxy
%% ---------------------------------------------------------------------------

%% A proxy over Medium that answers flush with ok, applies writes until Cut of them
%% have landed (infinity: all), and answers every later write `eio` unapplied. The
%% sectors written are kept beside Medium, so a write copies one sector, not the
%% image. It ends once ram_final/1 has its medium, when the test that made it ends,
%% or, failing the test, on a request it does not serve, so no volume waits on it.
ram(Medium, Cut) ->
    Test = self(),
    spawn_link(fun() ->
                       erlang:monitor(process, Test),
                       ram_serve(#{medium => Medium, written => #{}, cut => Cut, writes => 0, log => []})
               end).

ram_serve(#{medium := Medium, written := Written, cut := Cut, writes := Writes, log := Log} = S) ->
    receive
        {'DOWN', _, process, _Test, _} ->
            ok;
        {'$gen_call', From, info} ->
            gen:reply(From, {ok, #{role => drive, sectors => byte_size(Medium) div ?SECTOR}}), ram_serve(S);
        {'$gen_call', From, {read, _Lba, 1}} when is_map_key(fail_reads, S) ->
            gen:reply(From, {error, eio}), ram_serve(S);
        {fail_reads, Test} ->
            Test ! reads_failing, ram_serve(S#{fail_reads => true});
        {'$gen_call', From, {read, Lba, 1}} when (Lba + 1) * ?SECTOR =< byte_size(Medium) ->
            Sector = maps:get(Lba, Written, binary:part(Medium, Lba * ?SECTOR, ?SECTOR)),
            gen:reply(From, {ok, binary:copy(Sector)}), ram_serve(S);
        {'$gen_call', From, flush} ->
            gen:reply(From, ok), ram_serve(S#{log := [flush | Log]});
        {'$gen_call', From, {write, _Lba, _Bytes}} when Writes >= Cut ->
            gen:reply(From, {error, eio}), ram_serve(S);
        {'$gen_call', From, {write, Lba, <<_:?SECTOR/binary>> = Bytes}} when (Lba + 1) * ?SECTOR =< byte_size(Medium) ->
            gen:reply(From, ok),
            ram_serve(S#{written := Written#{Lba => Bytes}, writes := Writes + 1, log := [{write, Lba} | Log]});
        {'$gen_call', _From, Unserved} ->
            error({unserved, Unserved});
        {final, Test} ->
            Test ! {ram, self(), applied(Medium, Written), Writes, lists:reverse(Log)}
    end.

%% Medium with each sector of Written in its place.
applied(Medium, Written) ->
    {End, Parts} = maps:fold(fun(Lba, Bytes, {At, Acc}) ->
                                     {(Lba + 1) * ?SECTOR, [Acc, binary:part(Medium, At, Lba * ?SECTOR - At), Bytes]}
                             end, {0, []}, maps:iterator(Written, ordered)),
    iolist_to_binary([Parts, binary:part(Medium, End, byte_size(Medium) - End)]).

%% The medium Proxy holds, its count of applied writes and its log, as it ends. A
%% proxy that ended before fails the test rather than leaving it waiting.
ram_final(Proxy) ->
    Ref = erlang:monitor(process, Proxy),
    Proxy ! {final, self()},
    receive
        {ram, Proxy, Medium, Writes, Log} -> erlang:demonitor(Ref, [flush]), {Medium, Writes, Log};
        {'DOWN', Ref, process, Proxy, Why} -> error({proxy_ended, Why})
    end.

image(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    Bytes.

%% The volume of the whole medium behind Proxy, mounted.
volume(Proxy, Medium) ->
    ok = erx_media_volume:new_mounts(),
    process_flag(trap_exit, true),
    {ok, Pid} = erx_media_volume:start_link(Proxy, #{number => 1, first => 0, length => byte_size(Medium) div ?SECTOR}),
    Pid.

%% The volume finished as its supervisor ends it.
finish(Pid) ->
    exit(Pid, shutdown),
    receive {'EXIT', Pid, _} -> ok end.

%% ---------------------------------------------------------------------------
%% The round trip
%% ---------------------------------------------------------------------------

round_trip_test_() ->
    [{Name, {timeout, 300, fun() -> round_trip(Name) end}} || Name <- ["fat16.img", "fat32.img"]].

round_trip(Name) ->
    Base = image(Name),
    Proxy = ram(Base, infinity),
    Pid = volume(Proxy, Base),
    ?assertMatch(#{mount := rw}, erx_media_volume:outcome(Pid)),
    Expected = changes(Pid),
    finish(Pid),
    {Medium, _, Log} = ram_final(Proxy),
    flushed_between_steps(Log),
    ?assertMatch({0, _}, erx_fat_alloc_tests:verify(Medium)),
    ?assertEqual(Expected(extracted(Base)), extracted(Medium)),
    %% The volume mounts writable again: clean, and its tree passes the check.
    Again = volume(ram(Medium, infinity), Medium),
    ?assertMatch(#{mount := rw}, erx_media_volume:outcome(Again)),
    finish(Again).

%% The changes every volume takes, through the volume's calls; the function that
%% turns the volume's tree before them into the tree after.
changes(Pid) ->
    {ok, dir, Root} = erx_media_volume:root(Pid),
    Big = << <<(I rem 251)>> || I <- lists:seq(1, 60000) >>,
    {ok, dir, Docs} = erx_media_volume:mkdir(Pid, Root, <<"Documents">>),
    {ok, file, Notes} = erx_media_volume:create(Pid, Docs, <<"notes for the stick.txt">>),
    {ok, 6} = erx_media_volume:write(Pid, Notes, 0, <<"hello\n">>),
    {ok, 6} = erx_media_volume:write(Pid, Notes, 6, <<"again\n">>),
    {ok, file, BigPath} = erx_media_volume:create(Pid, Root, <<"big.bin">>),
    [{ok, 20000} = erx_media_volume:write(Pid, BigPath, N * 20000, binary:part(Big, N * 20000, 20000)) || N <- [0, 1, 2]],
    ok = erx_media_volume:fsync(Pid),
    ok = erx_media_volume:truncate(Pid, BigPath, 25000),
    ?assertMatch({ok, #{size := 25000}, BigPath}, erx_media_volume:attr(Pid, BigPath)),
    ok = erx_media_volume:rename(Pid, Docs, <<"notes for the stick.txt">>, Root, <<"Notes moved.txt">>),
    %% The renamed file keeps its path.
    ?assertMatch({ok, file, Notes}, erx_media_volume:walk(Pid, Root, <<"notes moved.txt">>)),
    ok = erx_media_volume:rename(Pid, Root, <<"hello.txt">>, Docs, <<"hello.txt">>),
    {ok, dir, _} = erx_media_volume:mkdir(Pid, Root, <<"Gone">>),
    ok = erx_media_volume:rmdir(Pid, Root, <<"gone">>),
    ?assertEqual({error, enotempty}, erx_media_volume:rmdir(Pid, Root, <<"Documents">>)),
    ?assertEqual({error, eexist}, erx_media_volume:create(Pid, Root, <<"BIG.BIN">>)),
    %% A removed file reads and writes through its path while its create's fid names
    %% it, and is gone once that fid is clunked.
    {ok, file, Doomed} = erx_media_volume:create(Pid, Root, <<"doomed">>),
    {ok, 4} = erx_media_volume:write(Pid, Doomed, 0, <<"bye\n">>),
    ok = erx_media_volume:remove(Pid, Root, <<"doomed">>),
    ?assertEqual({error, enoent}, erx_media_volume:walk(Pid, Root, <<"doomed">>)),
    ?assertMatch({ok, #{size := 4}, Doomed}, erx_media_volume:attr(Pid, Doomed)),
    ?assertEqual({ok, 1}, erx_media_volume:write(Pid, Doomed, 4, <<"x">>)),
    ?assertEqual({ok, <<"bye\nx">>}, read(Pid, Doomed, 0, 10)),
    ok = erx_media_volume:clunked(Pid, Doomed),
    ?assertEqual({error, enoent}, erx_media_volume:attr(Pid, Doomed)),
    fun(Tree) ->
            Hello = proplists:get_value(<<"hello.txt">>, Tree),
            lists:sort([{<<"Documents/hello.txt">>, Hello}, {<<"Notes moved.txt">>, <<"hello\nagain\n">>},
                        {<<"big.bin">>, binary:part(Big, 0, 25000)}
                        | proplists:delete(<<"hello.txt">>, Tree)])
    end.

%% No sector is written twice between two flushes: a sector two steps write, as a
%% directory sector that loses a name and gains one, is flushed between, as every step is.
flushed_between_steps(Log) ->
    lists:foldl(fun(flush, _Seen) -> #{};
                   ({write, Lba}, Seen) -> ?assertNot(is_map_key(Lba, Seen)), Seen#{Lba => true}
                end, #{}, Log).

%% ---------------------------------------------------------------------------
%% Cuts and refusals
%% ---------------------------------------------------------------------------

%% A stick pulled out after any write of the round trip's batches: the volume ends,
%% and the medium it leaves mounts read-only as dirty, or, cut before the dirty flag's
%% write landed, writable with a tree that passes the check. Never a wrong answer.
cuts_test_() ->
    [{Name, {timeout, 600, fun() -> cuts(Name) end}} || Name <- ["fat16.img", "fat32.img"]].

cuts(Name) ->
    Base = image(Name),
    Whole = ram(Base, infinity),
    Pid = volume(Whole, Base),
    _ = changes(Pid),
    finish(Pid),
    {_, Total, _} = ram_final(Whole),
    lists:foreach(fun(Cut) -> cut(Base, Cut) end, lists:seq(0, Total - 1, max(1, Total div 40))).

cut(Base, Cut) ->
    Proxy = ram(Base, Cut),
    Pid = volume(Proxy, Base),
    _ = try changes(Pid) catch error:_Ended -> cut end,
    receive {'EXIT', Pid, _} -> ok after 0 -> finish(Pid) end,
    {Medium, Cut, _} = ram_final(Proxy),
    Remounted = ram(Medium, infinity),
    Again = volume(Remounted, Medium),
    Outcome = erx_media_volume:outcome(Again),
    ?assert(lists:member(maps:get(mount, Outcome), [rw, {ro, dirty}])),
    finish(Again),
    _ = ram_final(Remounted).

%% ---------------------------------------------------------------------------
%% Files by fid
%% ---------------------------------------------------------------------------

%% A file removed while a walked fid names it, never opened, lives by that fid: a
%% file created in its slots is another file with a path of its own, the removed
%% file reads its own bytes and writes them without touching the new file, and the
%% last clunk releases its clusters alone, so the finished volume passes fsimg's
%% verify and holds the new file whole.
a_removed_file_lives_by_its_fids_test() ->
    Base = image("fat16.img"),
    Proxy = ram(Base, infinity),
    Pid = volume(Proxy, Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    Old = pattern(9000, 1),
    New = pattern(30000, 2),
    {ok, file, Created} = erx_media_volume:create(Pid, Root, <<"slot">>),
    {ok, 9000} = erx_media_volume:write(Pid, Created, 0, Old),
    ok = erx_media_volume:clunked(Pid, Created),
    {ok, file, Walked} = erx_media_volume:walk(Pid, Root, <<"slot">>),
    ok = erx_media_volume:fsync(Pid),
    ok = erx_media_volume:remove(Pid, Root, <<"slot">>),
    ok = erx_media_volume:fsync(Pid),
    {ok, file, Again} = erx_media_volume:create(Pid, Root, <<"slot">>),
    ?assertNotEqual(Walked, Again),
    {ok, 30000} = erx_media_volume:write(Pid, Again, 0, New),
    ok = erx_media_volume:fsync(Pid),
    ?assertEqual({ok, Old}, read(Pid, Walked, 0, 9000)),
    {ok, 4} = erx_media_volume:write(Pid, Walked, 9000, <<"more">>),
    ok = erx_media_volume:fsync(Pid),
    ?assertEqual({ok, <<Old/binary, "more">>}, read(Pid, Walked, 0, 9004)),
    %% As FreeBSD's msdosfs, its attributes and size change in its node alone.
    ok = erx_media_volume:setattr(Pid, Walked, #{read_only => true, mtime => 1700000001}),
    ok = erx_media_volume:truncate(Pid, Walked, 9002),
    ?assertMatch({ok, #{size := 9002, read_only := true, mtime := 1700000000}, Walked},
                 erx_media_volume:attr(Pid, Walked)),
    ?assertEqual({ok, New}, read(Pid, Again, 0, 30000)),
    ok = erx_media_volume:clunked(Pid, Walked),
    ?assertEqual({error, enoent}, erx_media_volume:attr(Pid, Walked)),
    finish(Pid),
    {Medium, _, _} = ram_final(Proxy),
    ?assertMatch({0, _}, erx_fat_alloc_tests:verify(Medium)),
    ?assertEqual(New, proplists:get_value(<<"slot">>, extracted(Medium))).

%% The table holds as many nodes as fit its share of the volume's memory bound, a
%% removed file's among them: past it a create answers enfile and changes nothing,
%% and the volume lives on (a table bound past what its memory holds would end it,
%% and each call after would answer eio). The table full takes no more words
%% than an eighth of the memory bound holds, and a clunk makes room again.
the_table_holds_what_its_memory_share_holds_test_() ->
    {timeout, 600, fun table_bound/0}.

table_bound() ->
    Base = image("fat16.img"),
    Pid = volume(ram(Base, infinity), Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    %% The root is one node, and each round leaves a removed file its create's fid names.
    Removed = fill(Pid, Root, []),
    ?assertEqual({error, enoent}, erx_media_volume:walk(Pid, Root, <<"x">>)),
    #{nodes := Nodes, places := Places} = sys:get_state(Pid),
    ?assertEqual(length(Removed) + 1, map_size(Nodes)),
    #{size := Words} = erx_media_medium:memory_bound(),
    ?assert(erts_debug:flat_size({Nodes, Places}) =< Words div 8),
    ok = erx_media_volume:clunked(Pid, hd(Removed)),
    ?assertMatch({ok, file, _}, erx_media_volume:create(Pid, Root, <<"x">>)),
    finish(Pid).

%% Removed files made until a create answers enfile: their paths, the last first.
fill(Pid, Root, Acc) ->
    case erx_media_volume:create(Pid, Root, <<"x">>) of
        {ok, file, Path} -> ok = erx_media_volume:remove(Pid, Root, <<"x">>), fill(Pid, Root, [Path | Acc]);
        {error, enfile} -> Acc
    end.

%% A read through the volume's waiting request, as the media tree sends it.
read(Pid, Path, Offset, Count) ->
    Alias = alias(),
    Pid ! {erx_fs_wait, {grant, Alias}, {read, Path, Offset, Count}},
    receive {erx_fs_answer, Alias, Answer} -> unalias(Alias), Answer end.

pattern(N, Seed) -> << <<((I * 7 + Seed) rem 251)>> || I <- lists:seq(1, N) >>.

%% A commit that cannot read the medium, as a stick pulled before an fsync, ends the
%% volume: once a commit may have written part of a plan, the batch before it no
%% longer describes the medium, so no later change may build on it.
a_commit_that_cannot_read_ends_the_volume_test() ->
    Base = image("fat16.img"),
    Proxy = ram(Base, infinity),
    Pid = volume(Proxy, Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, F} = erx_media_volume:create(Pid, Root, <<"f">>),
    {ok, 5000} = erx_media_volume:write(Pid, F, 0, pattern(5000, 3)),
    Proxy ! {fail_reads, self()},
    receive reads_failing -> ok end,
    ?assertEqual({error, eio}, erx_media_volume:fsync(Pid)),
    receive {'EXIT', Pid, Why} -> ?assertMatch({shutdown, {failed, _}}, Why)
    after 5000 -> error(volume_lives_on)
    end.

%% A volume whose names and chains do not form one tree mounts read-only, `tree`.
a_crossed_chain_mounts_read_only_test() ->
    Base = image("fat16.img"),
    Proxy = ram(Base, infinity),
    Pid = volume(Proxy, Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, A} = erx_media_volume:create(Pid, Root, <<"a">>),
    {ok, 1} = erx_media_volume:write(Pid, A, 0, <<"a">>),
    {ok, file, B} = erx_media_volume:create(Pid, Root, <<"b">>),
    {ok, 1} = erx_media_volume:write(Pid, B, 0, <<"b">>),
    finish(Pid),
    %% b's entry given a's first cluster: two names, one chain.
    {Medium, _, _} = ram_final(Proxy),
    Crossed = crossed(Medium, <<"B          ">>, <<"A          ">>),
    Again = volume(ram(Crossed, infinity), Crossed),
    ?assertMatch(#{mount := {ro, tree}}, erx_media_volume:outcome(Again)),
    {ok, dir, Root2} = erx_media_volume:root(Again),
    ?assertEqual({error, erofs}, erx_media_volume:create(Again, Root2, <<"c">>)),
    finish(Again).

%% Medium with short entry Victim's first cluster set to short entry Source's.
crossed(Medium, Victim, Source) ->
    {S, _} = binary:match(Medium, Source),
    {V, _} = binary:match(Medium, Victim),
    <<_:(S + 26)/binary, Low:2/binary, _/binary>> = Medium,
    <<Head:(V + 26)/binary, _:2/binary, Tail/binary>> = Medium,
    <<Head/binary, Low/binary, Tail/binary>>.

%% fsimg's extract of Bytes: every file under its path, sorted.
extracted(Bytes) ->
    Image = filename:absname("volume-extract.img"),
    Out = filename:absname("volume-extracted"),
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
                          false -> {ok, Data} = file:read_file(Path), [{Rel, Data}]
                      end
                  end || Name <- Names]).
