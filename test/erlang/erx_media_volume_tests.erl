%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a medium's supervisor, its reader and its volume processes
%% (docs/design-drives.md, "Reading a medium", "Volumes", "Time and memory"), over a
%% fake window proxy that answers the window's read, flush and info from a medium held
%% as one binary. ERX_FAT_IMAGES: fat16.img and fat32.img, fsimg's (test/fixtures/
%% fat_volumes.rb).

-module(erx_media_volume_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").
-include("erx_fs_waits.hrl").

%% The fixtures the media tree's cases share (erx_media_tree_tests).
-export([image/1, proxy/2, mbr/2, sectors/1, facet/1, fat32_shaped/4]).
%% The logger handler a case adds.
-export([log/2]).

-define(SECTOR, 512).
-define(START, 2048).
%% A USB transport's max_sectors (erx_blk_usb), the most sectors the fake window reads at once.
-define(MAX_SECTORS, 64).

image(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    Bytes.

%% A window proxy over Medium, a binary or {synthesized, Sectors, Sector}, a medium of
%% Sectors sectors each Sector(Lba) answers, whose flush answers Flush; it sends the test process
%% {flushed, self()} at each flush. A read of one to ?MAX_SECTORS sectors, a USB
%% transport's max_sectors, answers a copy of its sectors, as the window does, never a
%% sub-binary of the whole medium, which a volume's memory bound counts; a longer one is
%% einval, as the window's. It keeps a tally of the reads it was asked for, by their
%% counts of sectors, which reads/1 answers. Sent `stall`, it answers nothing more, as a
%% stick that hangs.
proxy(Medium, Flush) ->
    Test = self(),
    spawn_link(fun() -> serve(Medium, Flush, Test, #{}) end).

serve(Medium, Flush, Test, Tally) ->
    receive
        {'$gen_call', From, reads} ->
            gen:reply(From, Tally),
            serve(Medium, Flush, Test, Tally);
        {'$gen_call', From, Request} ->
            gen:reply(From, answer(Request, Medium, Flush, Test)),
            serve(Medium, Flush, Test, tallied(Request, Tally));
        stall ->
            stalled();
        stop ->
            ok
    end.

tallied({read, _Lba, Count}, Tally) -> maps:update_with(Count, fun(N) -> N + 1 end, 1, Tally);
tallied(_Request, Tally) -> Tally.

%% The reads Proxy has been asked for: a map from a read's count of sectors to how many
%% reads asked for that count.
reads(Proxy) -> gen_server:call(Proxy, reads).

stalled() ->
    receive stop -> ok; _Unanswered -> stalled() end.

answer(info, {synthesized, Sectors, _Sector}, _Flush, _Test) ->
    {ok, #{role => drive, sectors => Sectors, max_sectors => ?MAX_SECTORS}};
answer({read, _Lba, Count}, _Medium, _Flush, _Test) when Count < 1; Count > ?MAX_SECTORS ->
    {error, einval};
answer({read, Lba, Count}, {synthesized, Sectors, Sector}, _Flush, _Test) when Lba + Count =< Sectors ->
    {ok, << <<(Sector(L))/binary>> || L <- lists:seq(Lba, Lba + Count - 1) >>};
answer(info, Medium, _Flush, _Test) ->
    {ok, #{role => drive, sectors => byte_size(Medium) div ?SECTOR, max_sectors => ?MAX_SECTORS}};
answer({read, Lba, Count}, Medium, _Flush, _Test) when (Lba + Count) * ?SECTOR =< byte_size(Medium) ->
    {ok, binary:copy(binary:part(Medium, Lba * ?SECTOR, Count * ?SECTOR))};
answer({read, _Lba, _Count}, _Medium, _Flush, _Test) ->
    {error, erange};
answer(flush, _Medium, Flush, Test) ->
    Test ! {flushed, self()},
    Flush.

%% The medium's table and its supervisor, read through a proxy over Medium.
read(Medium, Flush) ->
    through(proxy(Medium, Flush)).

%% The table and the supervisor of the medium behind Proxy.
through(Proxy) ->
    ok = erx_media_volume:new_mounts(),
    {ok, Sup} = erx_media_medium:start_link(),
    {Sup, erx_media_medium:read(Sup, Proxy)}.

%% An MBR medium: sector 0 with Entries, {Type, Start, Sectors}, then Volumes at their
%% starts, the space between them zeros.
mbr(Entries, Volumes) ->
    Slots = << <<0, 0:24, Type, 0:24, Start:32/little, Sectors:32/little>> || {Type, Start, Sectors} <- Entries >>,
    Sector0 = <<0:446/unit:8, Slots/binary, 0:((4 - length(Entries)) * 16)/unit:8, 16#55, 16#aa>>,
    lists:foldl(fun({Start, Bytes}, Medium) ->
                        Gap = Start * ?SECTOR - byte_size(Medium),
                        <<Medium/binary, 0:Gap/unit:8, Bytes/binary>>
                end, Sector0, Volumes).

sectors(Bytes) -> byte_size(Bytes) div ?SECTOR.

%% The flushes Proxy has served. EUnit runs the cases in one process, so a count
%% takes only its own proxy's.
flushes(Proxy) ->
    receive {flushed, Proxy} -> 1 + flushes(Proxy) after 0 -> 0 end.

%% A stick with no table is volume 1, its whole medium: a FAT16 volume that flushes and
%% is clean passes every condition of the writable rule, so it mounts rw after exactly
%% one flush, with no read-only reason, and logs one line naming the volume, its label
%% and the milliseconds its mount took. Logger runs a handler in the process that logs,
%% and the volume logs before it answers outcome/1, so the line is already here when
%% outcome/1 returns.
a_clean_fat_stick_mounts_rw_and_logs_one_line_test() ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
    try
        Proxy = proxy(image("fat16.img"), ok),
        {_Sup, {none, [{#{number := 1, first := 0}, Volume}], 0}} = through(Proxy),
        Outcome = erx_media_volume:outcome(Volume),
        ?assertMatch(#{format := msdosfs, fat := 16, mount := rw, label := <<_, _/binary>>}, Outcome),
        ?assertEqual(none, erx_media_volume:ro_reason(Outcome)),
        ?assertEqual(1, flushes(Proxy)),
        #{label := Label} = Outcome,
        Head = <<"erx_media: volume s1 (msdosfs) mounted rw, label ", Label/binary, " in ">>,
        Logged = receive {logged, Line} -> Line after 0 -> none end,
        ?assertMatch(<<Head:(byte_size(Head))/binary, _/binary>>, Logged),
        ?assertMatch({match, _}, re:run(binary:part(Logged, byte_size(Head), byte_size(Logged) - byte_size(Head)),
                                        <<"^[0-9]+ ms$">>)),
        ?assertEqual(none, receive {logged, Again} -> Again after 0 -> none end)
    after
        logger:remove_handler(?MODULE)
    end.

%% The logger handler the case above adds: each event's text goes to the test process.
log(#{msg := {Format, Arguments}}, #{config := #{test := Test}}) when is_list(Arguments) ->
    Test ! {logged, iolist_to_binary(io_lib:format(Format, Arguments))};
log(_Event, _Config) ->
    ok.

%% Each volume of an MBR medium reads only its own sectors, each placed by its entry:
%% FAT16 at 2048 and FAT32 behind it both mount, which no read at the wrong place
%% would let them do.
each_volume_reads_at_its_own_place_test() ->
    [Fat16, Fat32] = [image("fat16.img"), image("fat32.img")],
    Second = ?START + sectors(Fat16),
    Medium = mbr([{16#0e, ?START, sectors(Fat16)}, {16#0c, Second, sectors(Fat32)}],
                 [{?START, Fat16}, {Second, Fat32}]),
    {_Sup, {mbr, [{_, One}, {_, Two}], 0}} = read(Medium, ok),
    ?assertMatch(#{fat := 16, mount := rw}, erx_media_volume:outcome(One)),
    ?assertMatch(#{fat := 32, mount := rw}, erx_media_volume:outcome(Two)).

%% The writable rule's flush: a medium that cannot flush mounts read-only, and a flush
%% that fails refuses the mount, with nothing written.
a_flush_decides_between_rw_ro_and_none_test() ->
    Fat16 = image("fat16.img"),
    {_, {none, [{_, Cannot}], 0}} = read(Fat16, {error, enotsup}),
    ?assertMatch(#{mount := {ro, flush}}, erx_media_volume:outcome(Cannot)),
    {_, {none, [{_, Failing}], 0}} = read(Fat16, {error, eio}),
    ?assertMatch(#{mount := {none, {flush, eio}}}, erx_media_volume:outcome(Failing)),
    {_, {none, [{_, Malformed}], 0}} = read(Fat16, {ok, written}),
    ?assertMatch(#{mount := {none, {flush, eio}}}, erx_media_volume:outcome(Malformed)),
    %% A refused mount serves no files: its root answers eio.
    ?assertEqual([{error, eio}, {error, eio}], [erx_media_volume:root(Pid) || Pid <- [Failing, Malformed]]).

%% A FAT volume whose dirty flag is set, the clean bit of its FAT's second entry clear,
%% mounts read-only, and says why in one log line from the same outcome status shows.
a_dirty_fat_volume_mounts_read_only_test() ->
    Fat16 = image("fat16.img"),
    <<_:14/binary, Reserved:16/little, _/binary>> = Fat16,
    Offset = Reserved * ?SECTOR + 3,
    <<Before:Offset/binary, High, After/binary>> = Fat16,
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
    try
        {_, {none, [{#{number := 1}, Volume}], 0}} = read(<<Before/binary, (High band 16#7f), After/binary>>, ok),
        Outcome = erx_media_volume:outcome(Volume),
        ?assertMatch(#{fat := 16, mount := {ro, dirty}}, Outcome),
        ?assertEqual(<<"the FAT's dirty flag is set">>, erx_media_volume:ro_reason(Outcome)),
        ?assertEqual(<<"erx_media: volume s1 (msdosfs) mounted read-only: the FAT's dirty flag is set">>,
                     receive {logged, Line} -> Line after 0 -> none end)
    after
        logger:remove_handler(?MODULE)
    end.

%% A volume whose format is not served, or none, has no files, and no flush is sent.
a_volume_not_served_has_no_mount_test() ->
    Exfat = proxy(<<0:24, "EXFAT   ", 0:((?SECTOR * 64) - 11)/unit:8>>, ok),
    {_, {none, [{_, Volume}], 0}} = through(Exfat),
    ?assertMatch(#{format := exfat, mount := {none, format}}, erx_media_volume:outcome(Volume)),
    Zeros = proxy(<<0:(?SECTOR * 64)/unit:8>>, ok),
    {_, {none, [{_, Unknown}], 0}} = through(Zeros),
    ?assertMatch(#{format := unknown, mount := {none, unknown}}, erx_media_volume:outcome(Unknown)),
    ?assertEqual({0, 0}, {flushes(Exfat), flushes(Zeros)}).

%% The rule's first two conditions settle before the flush, which is then never sent.
the_rule_names_its_first_failing_condition_test() ->
    Unsent = fun() -> erlang:error(flushed) end,
    ?assertEqual({ro, format}, erx_media_volume:writable(erofs, [], Unsent, fun() -> ok end)),
    ?assertEqual({ro, {also, littlefs}}, erx_media_volume:writable(msdosfs, [littlefs], Unsent, fun() -> ok end)),
    ?assertEqual({ro, flush}, erx_media_volume:writable(msdosfs, [], fun() -> {error, enotsup} end, fun() -> dirty end)),
    ?assertEqual({ro, dirty}, erx_media_volume:writable(msdosfs, [], fun() -> ok end, fun() -> dirty end)),
    ?assertEqual(rw, erx_media_volume:writable(msdosfs, [], fun() -> ok end, fun() -> ok end)).

%% Each read-only reason has one plain line, which status and the log line both show;
%% an outcome that is not read-only has none.
each_read_only_reason_reads_plainly_test() ->
    Reason = fun(Format, Mount) -> erx_media_volume:ro_reason(#{format => Format, mount => Mount}) end,
    ?assertEqual(<<"erXos does not write erofs">>, Reason(erofs, {ro, format})),
    ?assertEqual(<<"a littlefs signature is also on the volume">>, Reason(littlefs, {ro, {also, littlefs}})),
    ?assertEqual(<<"the medium cannot flush">>, Reason(msdosfs, {ro, flush})),
    ?assertEqual(<<"the FAT's dirty flag is set">>, Reason(msdosfs, {ro, dirty})),
    ?assertEqual(<<"the FAT's hard-error flag is set">>, Reason(msdosfs, {ro, hard_error})),
    ?assertEqual(<<"the volume's FATs are not mirrored">>, Reason(msdosfs, {ro, mirror})),
    ?assertEqual(<<"the volume has more clusters than the ownership check holds">>, Reason(msdosfs, {ro, too_large})),
    ?assertEqual(<<"a cluster is reached twice, a chain reaches a free cluster, or a directory's .. does not "
                   "name its parent">>, Reason(msdosfs, {ro, tree})),
    ?assertEqual(none, Reason(msdosfs, rw)),
    ?assertEqual(none, Reason(exfat, {none, format})).

%% A table refused whole starts no volume; a medium whose window does not answer is a
%% failed reading.
a_refused_table_or_a_silent_window_starts_no_volume_test() ->
    Overlapping = mbr([{16#0e, ?START, 4096}, {16#0e, ?START + 100, 4096}], [{?START + 8192, <<0:4096>>}]),
    {Sup, Refused} = read(Overlapping, ok),
    ?assertMatch({refused, {overlap, _}}, Refused),
    ?assertEqual([], [Child || {{volume, _}, _, _, _} = Child <- supervisor:which_children(Sup)]),
    Proxy = proxy(<<>>, ok),
    unlink(Proxy),
    exit(Proxy, kill),
    ok = erx_media_volume:new_mounts(),
    {ok, Again} = erx_media_medium:start_link(),
    ?assertMatch({failed, {info, {error, eio}}}, erx_media_medium:read(Again, Proxy)).

%% Every volume, and the reader, run under the bound of media_volume_bytes in words,
%% killed alone past it; a volume that ends leaves the medium's other volumes served.
each_volume_runs_under_its_memory_bound_and_ends_alone_test() ->
    [Fat16, Fat32] = [image("fat16.img"), image("fat32.img")],
    Second = ?START + sectors(Fat16),
    Medium = mbr([{16#0e, ?START, sectors(Fat16)}, {16#0c, Second, sectors(Fat32)}],
                 [{?START, Fat16}, {Second, Fat32}]),
    {Sup, {mbr, [{_, One}, {_, Two}], 0}} = read(Medium, ok),
    Words = ?ERX_MEDIA_VOLUME_BYTES div erlang:system_info(wordsize),
    ?assertMatch({max_heap_size, #{size := Words, kill := true, include_shared_binaries := true}},
                 process_info(One, max_heap_size)),
    ?assertEqual(#{size => Words, kill => true, include_shared_binaries => true},
                 erx_media_medium:memory_bound()),
    unlink(Sup),
    Monitor = monitor(process, One),
    exit(One, kill),
    receive {'DOWN', Monitor, process, One, _} -> ok end,
    %% The volume's exit reaches the supervisor before this call does: both are local
    %% signals, delivered at once on one node, though Erlang orders only one sender's.
    ?assertMatch([{{volume, 2}, Two, worker, _}],
                 [Child || {{volume, _}, _, _, _} = Child <- supervisor:which_children(Sup)]),
    ?assertMatch(#{fat := 32, mount := rw}, erx_media_volume:outcome(Two)).

%% A stand-in drive facet whose every window ask answers Proxy.
facet(Proxy) ->
    receive {'$gen_call', From, window} -> gen:reply(From, {ok, Proxy}), facet(Proxy) end.

%% The drive process mounts its medium at the ask that gets a proxy: the answer names
%% the table with its volume started and mounted, a second ask answers the same
%% medium, and the proxy's end ends the volume with the medium's supervisor.
the_drive_mounts_its_medium_at_the_ask_and_ends_it_with_its_proxy_test() ->
    Proxy = proxy(image("fat16.img"), ok),
    unlink(Proxy),
    Facet = spawn(fun() -> facet(Proxy) end),
    ok = erx_media_volume:new_mounts(),
    {ok, Drive} = erx_media_drive:start_link(0, fun() -> Facet end),
    unlink(Drive),
    try
        {ok, #{proxy := Proxy, table := {none, [{_, Volume}], 0}} = Medium} = gen_server:call(Drive, medium, 5000),
        ?assertEqual({ok, Medium}, gen_server:call(Drive, medium, 5000)),
        ?assertMatch(#{mount := rw}, erx_media_volume:outcome(Volume)),
        Monitor = monitor(process, Volume),
        exit(Proxy, kill),
        ?assertEqual(shutdown, receive {'DOWN', Monitor, process, Volume, Why} -> Why after 2000 -> running end),
        ?assertEqual({links, []}, process_info(Drive, links)),
        ?assertMatch(#{medium := none}, sys:get_state(Drive))
    after
        [exit(P, kill) || P <- [Drive, Facet, Proxy]]
    end.

%% A medium whose table is refused is held idle, with no volume and its supervisor
%% stopped, until its proxy ends.
a_refused_table_leaves_the_medium_idle_with_no_supervisor_test() ->
    Proxy = proxy(mbr([{16#0e, ?START, 100}, {16#0e, ?START + 50, 100}], [{?START + 150, <<0:512/unit:8>>}]), ok),
    unlink(Proxy),
    Facet = spawn(fun() -> facet(Proxy) end),
    ok = erx_media_volume:new_mounts(),
    {ok, Drive} = erx_media_drive:start_link(0, fun() -> Facet end),
    unlink(Drive),
    try
        ?assertMatch({ok, #{proxy := Proxy, table := {refused, _}}}, gen_server:call(Drive, medium, 5000)),
        ?assertEqual({links, []}, process_info(Drive, links))
    after
        [exit(P, kill) || P <- [Drive, Facet, Proxy]]
    end.

%% Finishing a volume ---------------------------------------------------------------

%% A read of File's first bytes, waiting on Volume as the media tree hands it one, and
%% the alias its answer comes to.
wait_read(Volume, File) ->
    Alias = alias(),
    Volume ! ?ERX_FS_WAIT({self(), Alias}, {read, File, 0, 64}),
    Alias.

answered(Alias) ->
    receive ?ERX_FS_ANSWER(Alias, Result) -> Result after 2000 -> unanswered end.

%% A drive process of drive 0 over Proxy, unlinked, whose facet answers Proxy.
drive(Proxy) ->
    Facet = spawn(fun() -> facet(Proxy) end),
    {ok, Drive} = erx_media_drive:start_link(0, fun() -> Facet end),
    unlink(Drive),
    {Drive, Facet}.

two_volume_medium() ->
    [Fat16, Fat32] = [image("fat16.img"), image("fat32.img")],
    Second = ?START + sectors(Fat16),
    mbr([{16#0e, ?START, sectors(Fat16)}, {16#0c, Second, sectors(Fat32)}], [{?START, Fat16}, {Second, Fat32}]).

ended(Pid) ->
    Monitor = monitor(process, Pid),
    receive {'DOWN', Monitor, process, Pid, _} -> true after 2000 -> false end.

%% The finish is the volume's one admission barrier: every read sent before it is
%% answered, as is the finish; every request after it, a second finish among them,
%% answers eio without reaching the format. A clean volume mounted rw that changed
%% nothing writes nothing, and its finish has the window flush once.
the_finish_answers_what_came_before_and_refuses_what_comes_after_test() ->
    Proxy = proxy(image("fat16.img"), ok),
    {_Sup, {none, [{_, Volume}], 0}} = through(Proxy),
    {ok, dir, Root} = erx_media_volume:root(Volume),
    {ok, file, File} = erx_media_volume:walk(Volume, Root, <<"hello.txt">>),
    _MountsFlush = flushes(Proxy),
    Before = [wait_read(Volume, File) || _ <- lists:seq(1, 8)],
    ?assertEqual(ok, erx_media_volume:finish(Volume)),
    ?assertEqual([{ok, <<"hello, stick\n">>} || _ <- Before], [answered(Alias) || Alias <- Before]),
    ?assertEqual({error, eio}, answered(wait_read(Volume, File))),
    ?assertEqual({error, eio}, erx_media_volume:root(Volume)),
    ?assertEqual({error, eio}, erx_media_volume:walk(Volume, Root, <<"hello.txt">>)),
    ?assertEqual({error, eio}, erx_media_volume:attr(Volume, File)),
    ?assertEqual({error, eio}, erx_media_volume:list(Volume, Root)),
    ?assertEqual({error, eio}, erx_media_volume:finish(Volume)),
    ?assertEqual(1, flushes(Proxy)).

%% A volume that mounted no files finishes too, with nothing to write.
a_volume_with_no_files_finishes_test() ->
    {_Sup, {none, [{_, Volume}], 0}} = read(<<0:(64 * ?SECTOR)/unit:8>>, ok),
    ?assertMatch(#{mount := {none, unknown}}, erx_media_volume:outcome(Volume)),
    ?assertEqual(ok, erx_media_volume:finish(Volume)),
    ?assertEqual({error, eio}, erx_media_volume:finish(Volume)).

%% Eject on a drive whose medium holds two volumes finishes both, then ends the
%% medium's supervisor and holds the medium idle as ejected, mounting it again only
%% once its proxy ends; a second eject, and an eject of a drive with no medium, find no
%% mounted medium.
eject_finishes_every_volume_then_ends_the_medium_test() ->
    Proxy = proxy(two_volume_medium(), ok),
    unlink(Proxy),
    ok = erx_media_volume:new_mounts(),
    {Drive, Facet} = drive(Proxy),
    {ok, Empty} = erx_media_drive:start_link(1, fun() -> undefined end),
    unlink(Empty),
    try
        {ok, #{table := {mbr, [{_, One}, {_, Two}], 0}}} = gen_server:call(Drive, medium, 5000),
        Watched = [{V, monitor(process, V)} || V <- [One, Two]],
        ?assertEqual(ok, gen_server:call(Drive, eject, 5000)),
        [?assertEqual(shutdown, receive {'DOWN', M, process, V, Why} -> Why after 2000 -> running end)
         || {V, M} <- Watched],
        ?assertEqual({ok, #{proxy => Proxy, table => ejected}}, gen_server:call(Drive, medium, 5000)),
        ?assertEqual({error, enxio}, gen_server:call(Drive, eject, 5000)),
        ?assertEqual({links, []}, process_info(Drive, links)),
        ?assertEqual({error, enxio}, gen_server:call(Empty, eject, 5000))
    after
        [exit(P, kill) || P <- [Drive, Empty, Facet, Proxy]]
    end.

%% A volume that had already ended makes the eject answer eio, and the medium is ended
%% all the same.
an_eject_over_an_ended_volume_answers_eio_test() ->
    Proxy = proxy(two_volume_medium(), ok),
    unlink(Proxy),
    ok = erx_media_volume:new_mounts(),
    {Drive, Facet} = drive(Proxy),
    try
        {ok, #{table := {mbr, [{_, One}, {_, Two}], 0}}} = gen_server:call(Drive, medium, 5000),
        exit(One, kill),
        true = ended(One),
        ?assertEqual({error, eio}, gen_server:call(Drive, eject, 5000)),
        ?assertNot(is_process_alive(Two)),
        ?assertEqual({ok, #{proxy => Proxy, table => ejected}}, gen_server:call(Drive, medium, 5000))
    after
        [exit(P, kill) || P <- [Drive, Facet, Proxy]]
    end.

%% The freeze finishes every mounted volume of every drive at once and answers when all
%% have: each volume then refuses its requests, the media stay held, and a drive with no
%% medium has nothing to finish. A second freeze finds its volumes finished, and fails.
the_freeze_finishes_every_volume_of_every_drive_test() ->
    [P1, P2] = Proxies = [proxy(image("fat16.img"), ok), proxy(image("fat32.img"), ok)],
    [unlink(P) || P <- Proxies],
    ok = erx_media_volume:new_mounts(),
    {D1, F1} = drive(P1),
    {D2, F2} = drive(P2),
    {ok, Empty} = erx_media_drive:start_link(2, fun() -> undefined end),
    unlink(Empty),
    try
        {ok, #{table := {none, [{_, V1}], 0}} = M1} = gen_server:call(D1, medium, 5000),
        {ok, #{table := {none, [{_, V2}], 0}}} = gen_server:call(D2, medium, 5000),
        ?assertEqual(ok, erx_media_drive:freeze([D1, D2, Empty])),
        [?assertEqual({error, eio}, erx_media_volume:root(V)) || V <- [V1, V2]],
        ?assertEqual({ok, M1}, gen_server:call(D1, medium, 5000)),
        ?assertEqual({error, eio}, erx_media_drive:freeze([D2]))
    after
        [exit(P, kill) || P <- [D1, D2, Empty, F1, F2 | Proxies]]
    end.

%% The ownership check holds what it needs within the volume's memory bound, whatever
%% the volume's size: FAT32 sticks shaped as an 8 GB one, 15,628,288 sectors in
%% clusters of eight, and a 16 GB one, whose 3,899,437 clusters come near the most the
%% check holds, mount rw under their volume's own bound, as does a volume of 4,193,404
%% one-sector clusters whose root names the 16,384 subdirectories the check's stack
%% holds; one subdirectory more is too_large, and the volume mounts read-only.
fat32_volumes_are_checked_within_the_memory_bound_test_() ->
    Cases = [{"8 GB", 15_628_288, 8, 0, 0, rw}, {"16 GB", 31_256_576, 8, 0, 0, rw},
             {"a full stack", 4_260_000, 1, 16_384, 0, rw},
             {"one past a full stack", 4_260_000, 1, 16_385, 0, {ro, too_large}}],
    [{Name, {timeout, 300,
             fun() ->
                     Proxy = proxy(fat32_shaped(Total, PerCluster, Subdirs, Files), ok),
                     {_Sup, {none, [{_, Volume}], 0}} = through(Proxy),
                     ?assertMatch(#{fat := 32, mount := Mount}, erx_media_volume:outcome(Volume)),
                     Proxy ! stop
             end}}
     || {Name, Total, PerCluster, Subdirs, Files, Mount} <- Cases].

%% The ownership check reads the FAT in runs as long as the window takes, not a sector
%% at a time: a stick shaped as an 8 GB one, whose two FATs hold 15,272 sectors each,
%% mounts rw in at most one FAT's worth of full runs for each of the check's two passes,
%% and 64 reads more, and few single-sector reads. Over USB each read costs a round
%% trip of milliseconds.
the_fat_is_read_in_runs_test_() ->
    {timeout, 300,
     fun() ->
             Proxy = proxy(fat32_shaped(15_628_288, 8, 0, 0), ok),
             Started = erlang:monotonic_time(millisecond),
             {_Sup, {none, [{_, Volume}], 0}} = through(Proxy),
             ?assertMatch(#{fat := 32, mount := rw}, erx_media_volume:outcome(Volume)),
             Took = erlang:monotonic_time(millisecond) - Started,
             Tally = reads(Proxy),
             Reads = lists:sum(maps:values(Tally)),
             Bytes = lists:sum([Count * ?SECTOR * N || Count := N <- Tally]),
             ?debugFmt("8 GB stick: ~b reads, ~b bytes, ~b ms, by sectors a read ~p", [Reads, Bytes, Took, Tally]),
             FatRuns = (15_272 + ?MAX_SECTORS - 1) div ?MAX_SECTORS,
             ?assert(Reads =< 2 * FatRuns + 64),
             ?assert(maps:get(1, Tally, 0) =< 64),
             Proxy ! stop
     end}.

%% A directory of the most entries a directory holds, 65,536, is walked within the
%% volume's memory bound on a volume of nearly the most clusters the check holds, whose
%% two sets stand beside it: in a process under the volume's bound that reads through
%% the proxy, the check of 4,193,404 one-sector clusters whose root holds 65,536 names
%% answers ok, and a lookup of the root's last name finds it.
the_largest_directory_is_walked_within_the_memory_bound_test_() ->
    {timeout, 300,
     fun() ->
             Proxy = proxy(fat32_shaped(4_260_000, 1, 0, 65_536), ok),
             Read = fun(Lba) -> erx_media_medium:window(Proxy, {read, Lba, 1}) end,
             Test = self(),
             {Pid, Ref} = spawn_opt(fun() ->
                                            {ok, Fat} = erx_fat:mount(Read, 4_260_000),
                                            Check = erx_fat:check(Fat),
                                            Test ! {walked, Check, erx_fat:walk(erx_fat:root(Fat), <<"F0065535">>, Fat)}
                                    end, [monitor, {max_heap_size, erx_media_medium:memory_bound()}]),
             receive
                 {walked, Check, Walk} -> ?assertEqual(ok, Check), ?assertMatch({ok, _}, Walk);
                 {'DOWN', Ref, process, Pid, Why} -> ?assertEqual(walked, Why)
             end,
             Proxy ! stop
     end}.

%% A FAT32 volume of Total sectors and PerCluster sectors a cluster, a sector at a
%% time: the seed's reserved sectors with its boot sector's geometry changed; FATs
%% that chain the root's clusters from cluster 2 and end each subdirectory's one
%% cluster after them; a root that names Subdirs subdirectories, D0000000 on, each
%% holding its dot entries alone, then Files empty files; and zeros elsewhere.
fat32_shaped(Total, PerCluster, Subdirs, Files) ->
    Seed = image("fat32.img"),
    <<Head:13/binary, _PerCluster, Reserved:16/little, Fats, Middle:15/binary, _Total32:32, _FatSectors32:32,
      _FlagsVersion:32, _RootCluster:32, Tail:(?SECTOR - 48)/binary, _/binary>> = Seed,
    %% An entry for every sector past the reserved ones, the FATs' own among them, so
    %% at least as many as the volume's clusters need.
    FatSectors = ((Total - Reserved) div PerCluster + 2) * 4 div ?SECTOR + 1,
    Boot = <<Head/binary, PerCluster, Reserved:16/little, Fats, Middle/binary, Total:32/little,
             FatSectors:32/little, 0:32, 2:32/little, Tail/binary>>,
    Area = binary:copy(binary:part(Seed, 0, Reserved * ?SECTOR)),
    <<Media:4/binary, Flags:4/binary, _/binary>> = binary:part(Seed, Reserved * ?SECTOR, ?SECTOR),
    Data = Reserved + Fats * FatSectors,
    PerSector = ?SECTOR div 32,
    FirstSub = 2 + max(1, (Subdirs + Files + PerSector * PerCluster - 1) div (PerSector * PerCluster)),
    Entry = fun(0) -> Media;
               (1) -> Flags;
               (C) when C < FirstSub - 1 -> <<(C + 1):32/little>>;
               (C) when C < FirstSub + Subdirs -> <<16#0fffffff:32/little>>;
               (_C) -> <<0:32>>
            end,
    Short = fun(Name, Attributes, Cluster) ->
                    <<Name:11/binary, Attributes, 0:64, (Cluster bsr 16):16/little, 0:16, 16#21:16/little,
                      (Cluster band 16#ffff):16/little, 0:32>>
            end,
    Named = fun(K) when K < Subdirs -> Short(iolist_to_binary(io_lib:format("D~7..0B   ", [K])), 16#10, FirstSub + K);
               (K) when K < Subdirs + Files -> Short(iolist_to_binary(io_lib:format("F~7..0B   ", [K])), 16#20, 0);
               (_K) -> <<0:32/unit:8>>
            end,
    Zero = <<0:?SECTOR/unit:8>>,
    Cluster = fun(C, 0) when C >= FirstSub, C < FirstSub + Subdirs ->
                      <<(Short(<<".          ">>, 16#10, C))/binary, (Short(<<"..         ">>, 16#10, 0))/binary,
                        0:(?SECTOR - 64)/unit:8>>;
                 (C, J) when C < FirstSub ->
                      First = ((C - 2) * PerCluster + J) * PerSector,
                      << <<(Named(K))/binary>> || K <- lists:seq(First, First + PerSector - 1) >>;
                 (_C, _J) -> Zero
              end,
    {synthesized, Total,
     fun(0) -> Boot;
        (Lba) when Lba < Reserved -> binary:part(Area, Lba * ?SECTOR, ?SECTOR);
        (Lba) when Lba < Data ->
             First = (Lba - Reserved) rem FatSectors * (?SECTOR div 4),
             << <<(Entry(C))/binary>> || C <- lists:seq(First, First + ?SECTOR div 4 - 1) >>;
        (Lba) -> Cluster((Lba - Data) div PerCluster + 2, (Lba - Data) rem PerCluster)
     end}.
