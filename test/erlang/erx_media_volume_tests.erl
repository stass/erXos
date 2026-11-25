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

-define(SECTOR, 512).
-define(START, 2048).

image(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_FAT_IMAGES"), Name)),
    Bytes.

%% A window proxy over Medium whose flush answers Flush; it sends the test process
%% {flushed, self()} at each flush. A read answers a copy of its sector, as the window
%% does, never a sub-binary of the whole medium, which a volume's memory bound counts.
proxy(Medium, Flush) ->
    Test = self(),
    spawn_link(fun() -> serve(Medium, Flush, Test) end).

serve(Medium, Flush, Test) ->
    receive
        {'$gen_call', From, Request} ->
            gen:reply(From, answer(Request, Medium, Flush, Test)),
            serve(Medium, Flush, Test);
        stop ->
            ok
    end.

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
%% is clean mounts rw, after exactly one flush.
a_fat_stick_with_no_table_mounts_rw_test() ->
    Proxy = proxy(image("fat16.img"), ok),
    {_Sup, {none, [{#{number := 1, first := 0}, Volume}], 0}} = through(Proxy),
    ?assertMatch(#{format := msdosfs, fat := 16, mount := rw}, erx_media_volume:outcome(Volume)),
    ?assertEqual(1, flushes(Proxy)).

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
    ?assertMatch(#{mount := {none, {flush, eio}}}, erx_media_volume:outcome(Malformed)).

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
    ?assertEqual(rw, erx_media_volume:writable(msdosfs, [], fun() -> ok end, true)).

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
