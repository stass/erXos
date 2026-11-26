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
-export([image/1, proxy/2, mbr/2, sectors/1, facet/1]).
%% The logger handler a case adds.
-export([log/2]).

-define(SECTOR, 512).
-define(START, 2048).

image(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    Bytes.

%% A window proxy over Medium whose flush answers Flush; it sends the test process
%% {flushed, self()} at each flush. A read answers a copy of its sector, as the window
%% does, never a sub-binary of the whole medium, which a volume's memory bound counts.
%% Sent `stall`, it answers nothing more, as a stick that hangs.
proxy(Medium, Flush) ->
    Test = self(),
    spawn_link(fun() -> serve(Medium, Flush, Test) end).

serve(Medium, Flush, Test) ->
    receive
        {'$gen_call', From, Request} ->
            gen:reply(From, answer(Request, Medium, Flush, Test)),
            serve(Medium, Flush, Test);
        stall ->
            stalled();
        stop ->
            ok
    end.

stalled() ->
    receive stop -> ok; _Unanswered -> stalled() end.

answer(info, Medium, _Flush, _Test) ->
    {ok, #{role => drive, sectors => byte_size(Medium) div ?SECTOR}};
answer({read, Lba, 1}, Medium, _Flush, _Test) when (Lba + 1) * ?SECTOR =< byte_size(Medium) ->
    {ok, binary:copy(binary:part(Medium, Lba * ?SECTOR, ?SECTOR))};
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
%% is clean passes every condition of the writable rule but the server's write path,
%% which erx_fat lacks, so it mounts read-only after exactly one flush, and says why in
%% one log line from the same outcome status shows. Logger runs a handler in the
%% process that logs, and the volume logs before it answers outcome/1, so the line is
%% already here when outcome/1 returns.
a_clean_fat_stick_mounts_read_only_for_want_of_a_write_path_test() ->
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => self()}}),
    try
        Proxy = proxy(image("fat16.img"), ok),
        {_Sup, {none, [{#{number := 1, first := 0}, Volume}], 0}} = through(Proxy),
        Outcome = erx_media_volume:outcome(Volume),
        ?assertMatch(#{format := msdosfs, fat := 16, mount := {ro, no_write_path}}, Outcome),
        ?assertEqual(<<"erXos has no msdosfs write path">>, erx_media_volume:ro_reason(Outcome)),
        ?assertEqual(1, flushes(Proxy)),
        ?assertEqual(<<"erx_media: volume s1 (msdosfs) mounted read-only: erXos has no msdosfs write path">>,
                     receive {logged, Line} -> Line after 0 -> none end)
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
    ?assertMatch(#{fat := 16, mount := {ro, no_write_path}}, erx_media_volume:outcome(One)),
    ?assertMatch(#{fat := 32, mount := {ro, no_write_path}}, erx_media_volume:outcome(Two)).

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
%% mounts read-only.
a_dirty_fat_volume_mounts_read_only_test() ->
    Fat16 = image("fat16.img"),
    <<_:14/binary, Reserved:16/little, _/binary>> = Fat16,
    Offset = Reserved * ?SECTOR + 3,
    <<Before:Offset/binary, High, After/binary>> = Fat16,
    {_, {none, [{_, Volume}], 0}} = read(<<Before/binary, (High band 16#7f), After/binary>>, ok),
    ?assertMatch(#{fat := 16, mount := {ro, dirty}}, erx_media_volume:outcome(Volume)).

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
    ?assertEqual({ro, format}, erx_media_volume:writable(erofs, [], Unsent, true)),
    ?assertEqual({ro, {also, littlefs}}, erx_media_volume:writable(msdosfs, [littlefs], Unsent, true)),
    ?assertEqual({ro, flush}, erx_media_volume:writable(msdosfs, [], fun() -> {error, enotsup} end, false)),
    ?assertEqual({ro, dirty}, erx_media_volume:writable(msdosfs, [], fun() -> ok end, false)),
    ?assertEqual({ro, no_write_path}, erx_media_volume:writable(msdosfs, [], fun() -> ok end, true)).

%% Each read-only reason has one plain line, which status and the log line both show;
%% an outcome that is not read-only has none.
each_read_only_reason_reads_plainly_test() ->
    Reason = fun(Format, Mount) -> erx_media_volume:ro_reason(#{format => Format, mount => Mount}) end,
    ?assertEqual(<<"erXos does not write erofs">>, Reason(erofs, {ro, format})),
    ?assertEqual(<<"a littlefs signature is also on the volume">>, Reason(littlefs, {ro, {also, littlefs}})),
    ?assertEqual(<<"the medium cannot flush">>, Reason(msdosfs, {ro, flush})),
    ?assertEqual(<<"the FAT's dirty flag is set">>, Reason(msdosfs, {ro, dirty})),
    ?assertEqual(<<"erXos has no msdosfs write path">>, Reason(msdosfs, {ro, no_write_path})),
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
    ?assertMatch(#{fat := 32, mount := {ro, no_write_path}}, erx_media_volume:outcome(Two)).

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
        ?assertMatch(#{mount := {ro, no_write_path}}, erx_media_volume:outcome(Volume)),
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
%% answers eio without reaching the format. A read-only volume holds nothing to write,
%% so its finish has the window flush nothing.
the_finish_answers_what_came_before_and_refuses_what_comes_after_test() ->
    Proxy = proxy(image("fat16.img"), ok),
    {_Sup, {none, [{_, Volume}], 0}} = through(Proxy),
    {ok, Root, dir, _} = erx_media_volume:root(Volume),
    {ok, File, file, _} = erx_media_volume:walk(Volume, Root, <<"hello.txt">>),
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
    ?assertEqual(0, flushes(Proxy)).

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
