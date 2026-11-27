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

%% fsimg's reading of an image, which erx_media_tree_tests shares.
-export([extracted/1, unreadable/1]).

-import(erx_ram_window, [ram/2, ram_final/1, counts/1]).

-define(SECTOR, 512).

sectors({synthesized, Sectors, _Sector}) -> Sectors;
sectors(Medium) -> byte_size(Medium) div ?SECTOR.

image(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    Bytes.

%% The volume of the whole medium behind Proxy, mounted.
volume(Proxy, Medium) ->
    ok = erx_media_volume:new_mounts(),
    process_flag(trap_exit, true),
    {ok, Pid} = erx_media_volume:start_link(Proxy, #{number => 1, first => 0, length => sectors(Medium)}),
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
    ok = erx_media_volume:forget(Pid, Doomed),
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
    ?assertEqual({Cut, []}, {Cut, unreadable(Again)}),
    finish(Again),
    _ = ram_final(Remounted).

%% The steps a stick took from rc on a board: a file written, then appended to, a
%% directory made, the file moved into it and removed there, each through the calls
%% the file server makes, each group committed as a batch of its own.
removal(Pid) ->
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, Hello} = erx_media_volume:create(Pid, Root, <<"note.txt">>),
    {ok, 6} = erx_media_volume:write(Pid, Hello, 0, <<"hello\n">>),
    erx_media_volume:forget(Pid, Hello),
    {ok, file, Again} = erx_media_volume:walk(Pid, Root, <<"note.txt">>),
    {ok, 6, _} = erx_media_volume:append(Pid, Again, <<"again\n">>),
    erx_media_volume:forget(Pid, Again),
    ok = erx_media_volume:fsync(Pid),
    {ok, dir, New} = erx_media_volume:mkdir(Pid, Root, <<"newdir">>),
    ok = erx_media_volume:rename(Pid, Root, <<"note.txt">>, New, <<"moved.txt">>),
    ok = erx_media_volume:fsync(Pid),
    ok = erx_media_volume:remove(Pid, New, <<"moved.txt">>),
    ok = erx_media_volume:fsync(Pid).

%% Every write of the removal cut in turn: the medium left mounts writable, clean
%% and passing fsimg's verify, or read-only as dirty, and either way every directory
%% of its tree reads, the root first.
every_cut_of_a_removal_leaves_a_tree_that_reads_test_() ->
    [{Name, {timeout, 600, fun() -> removal_cuts(Name) end}} || Name <- ["fat16.img", "fat32.img"]].

removal_cuts(Name) ->
    Base = image(Name),
    Whole = ram(Base, infinity),
    Pid = volume(Whole, Base),
    ok = removal(Pid),
    finish(Pid),
    {_, Total, _} = ram_final(Whole),
    lists:foreach(fun(Cut) -> removal_cut(Base, Cut) end, lists:seq(0, Total)).

removal_cut(Base, Cut) ->
    Proxy = ram(Base, Cut),
    Pid = volume(Proxy, Base),
    _ = try removal(Pid) catch error:_Ended -> cut end,
    receive {'EXIT', Pid, _} -> ok after 0 -> finish(Pid) end,
    {Medium, _, _} = ram_final(Proxy),
    Again = volume(ram(Medium, infinity), Medium),
    ?assertEqual({Cut, []}, {Cut, unreadable(Again)}),
    case maps:get(mount, erx_media_volume:outcome(Again)) of
        rw -> ?assertMatch({Cut, {0, _}}, {Cut, erx_fat_alloc_tests:verify(Medium)});
        Mount -> ?assertEqual({Cut, {ro, dirty}}, {Cut, Mount})
    end,
    finish(Again).

%% The directories of the volume Pid that do not read, from the root down, each with
%% its refusal: [] for a tree that reads whole.
unreadable(Pid) ->
    {ok, dir, Root} = erx_media_volume:root(Pid),
    unreadable(Pid, Root, <<>>).

unreadable(Pid, Dir, Name) ->
    case erx_media_volume:list(Pid, Dir) of
        {ok, Entries} ->
            lists:append([case erx_media_volume:walk(Pid, Dir, Sub) of
                              {ok, dir, Path} -> unreadable(Pid, Path, <<Name/binary, "/", Sub/binary>>);
                              Refused -> [{<<Name/binary, "/", Sub/binary>>, Refused}]
                          end || {Sub, dir, _} <- Entries]);
        Refused ->
            [{<<Name/binary, "/">>, Refused}]
    end.

%% The removal on a volume shaped as an 8 GB FAT32 stick, 1,953,534 clusters of 4 KiB
%% and FATs of 15,263 sectors each: the remove and its batch read and write a
%% handful of sectors, not the FAT, whose size never enters what a removal costs.
a_removal_on_a_large_volume_costs_a_handful_of_sectors_test_() ->
    {timeout, 300, fun() ->
                           Medium = erx_media_volume_tests:fat32_shaped(15_628_288, 8, 4, 40),
                           Proxy = ram(Medium, infinity),
                           Pid = volume(Proxy, Medium),
                           ?assertMatch(#{mount := rw}, erx_media_volume:outcome(Pid)),
                           {ok, dir, Root} = erx_media_volume:root(Pid),
                           {ok, file, F} = erx_media_volume:create(Pid, Root, <<"moved.txt">>),
                           {ok, 6} = erx_media_volume:write(Pid, F, 0, <<"hello\n">>),
                           erx_media_volume:forget(Pid, F),
                           ok = erx_media_volume:fsync(Pid),
                           {Reads, Writes} = counts(Proxy),
                           ok = erx_media_volume:remove(Pid, Root, <<"moved.txt">>),
                           ok = erx_media_volume:fsync(Pid),
                           {ReadsAfter, WritesAfter} = counts(Proxy),
                           ?assert(ReadsAfter - Reads =< 16),
                           ?assert(WritesAfter - Writes =< 8),
                           finish(Pid)
                   end}.

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
    ok = erx_media_volume:forget(Pid, Created),
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
    ok = erx_media_volume:forget(Pid, Walked),
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
    ok = erx_media_volume:forget(Pid, hd(Removed)),
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
%% A crash report of a volume holding written data shows its outcome and counts, and
%% neither the batch's bytes nor a request's: the report holds no file's contents and
%% stays small whatever the batch holds.
a_crash_report_holds_no_file_contents_test() ->
    Base = image("fat16.img"),
    Pid = volume(ram(Base, infinity), Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, File} = erx_media_volume:create(Pid, Root, <<"secret.bin">>),
    Secret = binary:copy(<<"SECRET-BYTES-">>, 2000),
    {ok, _} = erx_media_volume:write(Pid, File, 0, Secret),
    State = sys:get_state(Pid),
    Shown = erx_media_volume:format_status(#{state => State, message => {write, File, 0, Secret},
                                             reason => {function_clause, [{erx_fat_dir, write, [Secret], []}]},
                                             log => [{in, Secret}]}),
    Report = term_to_binary(Shown),
    ?assertEqual(nomatch, binary:match(Report, <<"SECRET-BYTES-">>)),
    ?assert(byte_size(Report) < 2048),
    #{state := #{outcome := #{mount := rw}, nodes := Nodes, batch_sectors := Held}, message := Message,
      reason := Reason, log := []} = Shown,
    ?assert(Nodes >= 2 andalso Held > 0),
    ?assertEqual(write, Message),
    ?assertEqual(function_clause, Reason),
    finish(Pid).

a_commit_that_cannot_read_ends_the_volume_test() ->
    Base = image("fat16.img"),
    Proxy = ram(Base, infinity),
    Pid = volume(Proxy, Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, F} = erx_media_volume:create(Pid, Root, <<"f">>),
    {ok, 5000} = erx_media_volume:write(Pid, F, 0, pattern(5000, 3)),
    ok = erx_ram_window:fail_reads(Proxy),
    %% The end, which the drive's status no longer shows, is logged with its reason.
    ok = logger:add_handler(?MODULE, erx_media_volume_tests, #{config => #{test => self()}}),
    try
        ?assertEqual({error, eio}, erx_media_volume:fsync(Pid)),
        receive {'EXIT', Pid, Why} -> ?assertMatch({shutdown, {failed, _}}, Why)
        after 5000 -> error(volume_lives_on)
        end,
        ?assertEqual(<<"erx_media: volume s1 ended: its commit failed: read_failed">>,
                     receive {logged, Line} -> Line after 0 -> none end)
    after
        logger:remove_handler(?MODULE)
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

%% ---------------------------------------------------------------------------
%% Create or open
%% ---------------------------------------------------------------------------

%% lcreate's create-or-open is one call: a directory at the name answers eisdir and an
%% O_EXCL create of a name there eexist, each holding nothing for the caller; a file
%% there is opened, or emptied for truncate, and held.
create_or_open_holds_only_what_it_answers_test_() ->
    {timeout, 300, fun create_or_open/0}.

create_or_open() ->
    Base = image("fat16.img"),
    Pid = volume(ram(Base, infinity), Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, dir, _} = erx_media_volume:mkdir(Pid, Root, <<"Docs">>),
    {ok, file, Notes} = erx_media_volume:create(Pid, Root, <<"notes.txt">>),
    {ok, 6} = erx_media_volume:write(Pid, Notes, 0, <<"hello\n">>),
    Before = held_by_me(Pid),
    ?assertEqual({error, eisdir}, erx_media_volume:create(Pid, Root, <<"docs">>, open)),
    ?assertEqual({error, eisdir}, erx_media_volume:create(Pid, Root, <<"DOCS">>, truncate)),
    ?assertEqual({error, eexist}, erx_media_volume:create(Pid, Root, <<"docs">>, refuse)),
    ?assertEqual({error, eexist}, erx_media_volume:create(Pid, Root, <<"Notes.TXT">>, refuse)),
    ?assertEqual(Before, held_by_me(Pid)),
    ?assertEqual({ok, file, Notes}, erx_media_volume:create(Pid, Root, <<"NOTES.txt">>, open)),
    ?assertEqual({ok, <<"hello\n">>}, read(Pid, Notes, 0, 10)),
    ?assertEqual({ok, file, Notes}, erx_media_volume:create(Pid, Root, <<"notes.txt">>, truncate)),
    ?assertMatch({ok, #{size := 0}, Notes}, erx_media_volume:attr(Pid, Notes)),
    {ok, file, New} = erx_media_volume:create(Pid, Root, <<"new.txt">>, truncate),
    ?assertEqual(lists:sort([New | Before]), held_by_me(Pid)),
    finish(Pid).

%% The paths of the nodes the volume holds for the calling process.
held_by_me(Pid) ->
    #{nodes := Nodes} = sys:get_state(Pid),
    lists:sort([Path || Path := {named, _, Holders} <- Nodes, is_map_key(self(), Holders)]).

%% FAT's read-only attribute is shown, not enforced, as FreeBSD's msdosfs grants a
%% write and a truncate of such a file (docs/design-storage.md, "Attributes").
a_read_only_file_still_writes_test_() ->
    {timeout, 300, fun read_only_writes/0}.

read_only_writes() ->
    Base = image("fat16.img"),
    Pid = volume(ram(Base, infinity), Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, File} = erx_media_volume:create(Pid, Root, <<"locked.txt">>),
    ok = erx_media_volume:setattr(Pid, File, #{read_only => true}),
    ?assertMatch({ok, #{read_only := true}, File}, erx_media_volume:attr(Pid, File)),
    ?assertEqual({ok, file, File}, erx_media_volume:create(Pid, Root, <<"locked.txt">>, truncate)),
    ?assertEqual({ok, 3}, erx_media_volume:write(Pid, File, 0, <<"abc">>)),
    ?assertEqual(ok, erx_media_volume:truncate(Pid, File, 1)),
    ?assertEqual({ok, <<"a">>}, read(Pid, File, 0, 10)),
    finish(Pid).

%% finish/1 writes the volume's last batch and the clean bit before it answers, so a
%% volume changed, synced, which writes the medium dirty, and then finished, still
%% running, has left its medium clean: FAT16's clean bit, bit 15 of FAT entry 1, is set
%% again, the file is there, and the medium mounts writable.
finish_writes_the_clean_bit_test_() ->
    {timeout, 300, fun finish_writes_the_clean_bit/0}.

finish_writes_the_clean_bit() ->
    Base = image("fat16.img"),
    Proxy = ram(Base, infinity),
    Pid = volume(Proxy, Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, File} = erx_media_volume:create(Pid, Root, <<"changed.txt">>),
    ?assertEqual({ok, 6}, erx_media_volume:write(Pid, File, 0, <<"hello\n">>)),
    ?assertEqual(ok, erx_media_volume:fsync(Pid)),
    ?assertEqual(ok, erx_media_volume:finish(Pid)),
    {Medium, _, _} = ram_final(Proxy),
    <<_:14/binary, Reserved:16/little, _/binary>> = Medium,
    <<_:(Reserved * ?SECTOR + 2)/binary, Entry1:16/little, _/binary>> = Medium,
    ?assertNotEqual(0, Entry1 band 16#8000),
    ?assert(lists:member({<<"changed.txt">>, <<"hello\n">>}, extracted(Medium))),
    Again = volume(ram(Medium, infinity), Medium),
    ?assertMatch(#{mount := rw}, erx_media_volume:outcome(Again)),
    finish(Again),
    finish(Pid).

%% A finished volume changes nothing more: a forget that reaches it after finish/1
%% leaves its table as the finish left it, so nothing it does can write after the clean bit.
a_finished_volume_ignores_a_forget_test_() ->
    {timeout, 300, fun finished_ignores_forget/0}.

finished_ignores_forget() ->
    Base = image("fat16.img"),
    Pid = volume(ram(Base, infinity), Base),
    {ok, dir, Root} = erx_media_volume:root(Pid),
    {ok, file, File} = erx_media_volume:create(Pid, Root, <<"kept.txt">>),
    ?assertEqual(ok, erx_media_volume:finish(Pid)),
    Before = sys:get_state(Pid),
    ok = erx_media_volume:forget(Pid, File),
    ?assertEqual(Before, sys:get_state(Pid)),
    finish(Pid).
