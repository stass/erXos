%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The guest side of the block device suite (tools/lib/erx/block_device.rb, whose header
%% defines the lines printed here) and of the driver domains suite's littlefs restart
%% (tools/lib/erx/driver_domains.rb, whose header defines lfs_restart/0's lines). It is
%% test code: the suite's harness compiles it, adds it to a test image's system release
%% under /test/blk and starts it with the kernel
%% command line's `-run erx_blk_check main` in the system domain. The block driver and /data
%% run in the storage domain (docs/design-stopgap.md, "littlefs in the storage domain"), so each
%% entry waits for that domain's node to run erx_storage, loads this module's object code there
%% and runs the step at that node with erpc; the step's lines come back as its answer and
%% the system domain prints them. No production image holds it.
%%
%% It drives the driver only through erx_blk's public calls: it reports the transport
%% version and the capacity, reads each sector of the harness's disk and compares it with
%% the host's pattern, asks for the sector past the end, writes the guest's pattern to two
%% sectors, restarts the driver from the system domain through the storage domain's
%% driver-control facet (erx_driver_ctl), as the system shell does, and reads a sector
%% through the new driver. It ends with "blk: done", on which the harness ends the guest
%% and reads the disk back. A step that does not go as expected prints its "failed" line
%% and the run goes on, so the harness names the first step that went wrong.
%%
%% medium/0 is the second boot's: the harness attaches a medium laid out by the ABI file's
%% medium layout, and the module drives the block service's windows alone
%% (erx_blk_service:window/1, erx_blk_window). It reports each window's length, the medium
%% sector whose host pattern its first and last sectors hold (the data window's last only:
%% /data's littlefs volume formats over its first block at boot), and the refusal of the
%% sector past its end; it rewrites the data window's last sector with the guest's pattern of the
%% medium sector it read there, and is refused a write past the vault's end. It does not
%% know the layout: the harness checks the sectors it names against it.
%%
%% data_write/0 and data_read/0 are the power cut's two boots on one fresh medium, through
%% the file module and /data's littlefs volume. data_write opens /data/unsynced and writes
%% it, then writes /data/synced and syncs it; it neither syncs nor closes either file, and
%% a process that never ends holds both, so no close reaches the volume before the harness
%% kills QEMU on "blk: done". data_read reads both files back and reports the synced one's
%% size and MD5 digest, which the harness compares with its own, and what is left of the
%% unsynced one, which nothing promises.
%%
%% lfs_restart/0 is the driver domains suite's: it writes and closes /data/restarted at the
%% storage domain's node, kills that node's littlefs worker, sees the node go down, which is
%% the storage domain ending, waits for the domain's next incarnation to run erx_storage, and
%% reads the file back from /data as that incarnation mounted it.
%%
%% Each line goes to the console in one erlang:display_string/2 call, which reaches the
%% console's sink, its driver, whole (docs/design-runtime.md, "The console and standard
%% I/O"), so a kernel log line the console writes lands between two lines, never inside one.

-module(erx_blk_check).

-export([main/0, medium/0, data_write/0, data_read/0, lfs_restart/0]).
%% Run at the storage domain's node by step/1.
-export([run/1, main_here/0, read_again_here/0, medium_here/0, data_write_here/0,
         data_read_here/0, lfs_write_here/0, lfs_kill_here/0, lfs_read_here/0]).

-define(ROLES, [record, slot_a, slot_b, vault, data]).

%% The disk the harness attaches and the sectors it expects written (BlockDevice::SECTORS
%% and WRITE_SECTORS), and the patterns of tools/lib/erx/block_image.rb: each 512-byte
%% sector is 32 records of an 8-byte tag and the sector's index as a little-endian 64-bit
%% integer.
-define(SECTORS, 16).
-define(WRITE_SECTORS, [3, 7]).
-define(SECTOR_BYTES, 512).
-define(RECORD_BYTES, 16).
-define(HOST_TAG, <<"ERXHOST!">>).
-define(GUEST_TAG, <<"ERXGUEST">>).
%% erx_blk names why it did not start in one kernel log record, which erx_console writes
%% to the line at its next poll of the log, every LOG_POLL_MS (100 ms). The harness ends
%% the guest on "blk: done", so a run without a driver waits for a few polls first and
%% the serial log holds the reason.
-define(LOG_DRAIN_MS, 500).
%% The power cut's files (BlockDevice::DATA_BYTES and data_content): DATA_BYTES bytes, byte
%% I holding (I + Seed) rem 251, seed 0 for the synced file and 1 for the unsynced one.
-define(DATA_BYTES, 10000).
-define(SYNCED, "/data/synced").
-define(UNSYNCED, "/data/unsynced").
%% The storage domain's node (its manifest row's name at the machine's host) and how long
%% an entry waits for it to run erx_storage, polling every POLL_MS, and for its step.
-define(STORAGE_NODE, 'storage@erxos').
-define(STORAGE_WAIT_MS, 90000).
-define(POLL_MS, 200).
-define(STEP_MS, 60000).
%% lfs_restart's file, data_content(2), and how long it waits for the storage domain to
%% end once its worker is killed. The kill waits KILL_DELAY_MS, so the kill step's answer
%% leaves the node before the domain's end can overtake it.
-define(RESTARTED, "/data/restarted").
-define(STORAGE_END_MS, 60000).
-define(KILL_DELAY_MS, 200).

-spec main() -> ok.
main() -> report(at_storage(main_here) ++ control()).

-spec medium() -> ok.
medium() -> report(at_storage(medium_here)).

-spec data_write() -> ok.
data_write() -> report(at_storage(data_write_here)).

-spec data_read() -> ok.
data_read() -> report(at_storage(data_read_here)).

%% Prints Lines, then "blk: done".
report(Lines) ->
    lists:foreach(fun display/1, Lines ++ [text("done", [])]).

%% Runs Step at the storage domain's node once that node runs erx_storage: its lines. A
%% domain that never runs erx_storage, or a step that fails at its node, is the line
%% "no driver".
at_storage(Step) ->
    case wait_storage(?STORAGE_WAIT_MS div ?POLL_MS) of
        ok -> step(Step);
        timeout -> [text("no driver", [])]
    end.

%% Step's lines from the storage domain's node, after loading this module's object code
%% there, which each incarnation of the domain needs anew.
step(Step) ->
    {Module, Binary, File} = code:get_object_code(?MODULE),
    try
        {module, Module} = erpc:call(?STORAGE_NODE, code, load_binary, [Module, File, Binary], ?STEP_MS),
        erpc:call(?STORAGE_NODE, ?MODULE, run, [Step], ?STEP_MS)
    catch
        Class:Reason -> [text("no driver: ~0p", [{Class, Reason}])]
    end.

%% In the system domain, as the system shell does it: the block driver restarted through
%% the storage domain's driver-control facet, storage_ctl, so erx_blk names a new process;
%% a unit the storage domain does not hold refused; and a read through the new driver.
control() ->
    case wait_cap(storage_ctl, ?STORAGE_WAIT_MS div ?POLL_MS) of
        undefined ->
            [text("control no facet", [])];
        Facet ->
            Before = storage_driver(),
            Restarted = attempt(fun() -> erx_driver_ctl:restart(Facet, block) end),
            After = storage_driver(),
            [case Restarted =:= ok andalso is_pid(Before) andalso is_pid(After) andalso After =/= Before of
                 true -> text("control restart block ok", []);
                 false -> text("control restart block failed: ~0p", [{Restarted, Before, After}])
             end,
             case attempt(fun() -> erx_driver_ctl:restart(Facet, flux) end) of
                 {error, badarg} -> text("control restart flux refused", []);
                 Other -> text("control restart flux failed: ~0p", [Other])
             end
             | at_storage(read_again_here)]
    end.

%% The facet Name once the storage domain's ready report has installed it, or undefined.
wait_cap(_Name, 0) ->
    undefined;
wait_cap(Name, Tries) ->
    case erx:cap(Name) of
        Facet when is_pid(Facet) -> Facet;
        undefined -> timer:sleep(?POLL_MS), wait_cap(Name, Tries - 1)
    end.

storage_driver() ->
    attempt(fun() -> erpc:call(?STORAGE_NODE, erlang, whereis, [erx_blk], ?STEP_MS) end).

%% Fun's answer, or the exception it raised as {Class, Reason}.
attempt(Fun) ->
    try Fun() catch Class:Reason -> {Class, Reason} end.

-spec lfs_restart() -> ok.
lfs_restart() ->
    report(case wait_storage(?STORAGE_WAIT_MS div ?POLL_MS) of
               ok ->
                   Written = step(lfs_write_here),
                   true = erlang:monitor_node(?STORAGE_NODE, true),
                   Killed = step(lfs_kill_here),
                   Written ++ Killed ++ restarted();
               timeout ->
                   [text("no driver", [])]
           end).

%% The storage domain's end, seen as its node going down, and its next incarnation, seen
%% running erx_storage, with the file read back from its /data.
restarted() ->
    receive
        {nodedown, ?STORAGE_NODE} ->
            case wait_storage(?STORAGE_WAIT_MS div ?POLL_MS) of
                ok -> [text("storage domain ended", []), text("storage domain back", []) | step(lfs_read_here)];
                timeout -> [text("storage domain ended", []), text("storage domain not back", [])]
            end
    after ?STORAGE_END_MS ->
        [text("storage domain did not end", [])]
    end.

wait_storage(0) ->
    timeout;
wait_storage(Tries) ->
    Running = try erpc:call(?STORAGE_NODE, application, which_applications, [], ?POLL_MS) of
                  Applications -> lists:keymember(erx_storage, 1, Applications)
              catch
                  _:_ -> false
              end,
    case Running of
        true -> ok;
        false -> timer:sleep(?POLL_MS), wait_storage(Tries - 1)
    end.

%% At the storage domain's node: Step's lines, in order.
-spec run(main_here | read_again_here | medium_here | data_write_here | data_read_here
          | lfs_write_here | lfs_kill_here | lfs_read_here) -> [binary()].
run(Step) ->
    put(lines, []),
    ok = ?MODULE:Step(),
    lines().

lines() -> lists:reverse(get(lines)).

-spec main_here() -> ok.
main_here() ->
    case call(fun erx_blk:info/0) of
        {ok, #{version := Version, capacity := Capacity}} ->
            line("transport version ~b", [Version]),
            line("capacity ~b sectors", [Capacity]),
            lists:foreach(fun read/1, lists:seq(0, ?SECTORS - 1)),
            refused(?SECTORS),
            lists:foreach(fun write/1, ?WRITE_SECTORS);
        _NoDriver ->
            line("no driver", []),
            timer:sleep(?LOG_DRAIN_MS)
    end.

%% At the storage domain's node, after the restart: sector 0 read through the new driver.
-spec read_again_here() -> ok.
read_again_here() ->
    case call(fun() -> erx_blk:read(0, 1) end) =:= {ok, pattern(0, ?HOST_TAG)} of
        true -> line("read sector 0 again ok", []);
        false -> line("read sector 0 again failed", [])
    end.

-spec medium_here() -> ok.
medium_here() ->
    case call(fun erx_blk:info/0) of
        {ok, #{capacity := Capacity}} ->
            line("capacity ~b sectors", [Capacity]),
            Windows = [{Role, call(fun() -> erx_blk_service:window(Role) end)} || Role <- ?ROLES],
            case [{Role, Pid} || {Role, {ok, Pid}} <- Windows] of
                Served when length(Served) =:= length(?ROLES) ->
                    lists:foreach(fun window/1, Served),
                    rewrite_last(proplists:get_value(data, Served)),
                    refused_write(proplists:get_value(vault, Served));
                _Refused ->
                    line("no windows", []),
                    timer:sleep(?LOG_DRAIN_MS)
            end;
        _NoDriver ->
            line("no driver", []),
            timer:sleep(?LOG_DRAIN_MS)
    end.

-spec data_write_here() -> ok.
data_write_here() ->
    Parent = self(),
    {Holder, Monitor} = spawn_monitor(fun() -> hold(Parent) end),
    receive
        {Holder, written, Lines} -> put(lines, lists:reverse(Lines, get(lines)));
        {'DOWN', Monitor, process, Holder, _} -> timer:sleep(?LOG_DRAIN_MS)
    end,
    ok.

%% Writes both files, tells data_write, and then holds them open, without sync or close,
%% until the power cut: the holder's end would close them. It outlives the step's erpc
%% call, at the storage domain's node.
hold(Parent) ->
    put(lines, []),
    write_files(),
    Parent ! {self(), written, lines()},
    receive after infinity -> ok end.

%% A step that fails prints its line and the next one runs, so the harness names it.
write_files() ->
    Unsynced = open_write(?UNSYNCED, 1),
    line(case Unsynced of {ok, _} -> "data unsynced written"; _ -> "data unsynced failed" end, []),
    Synced = case open_write(?SYNCED, 0) of
                 {ok, File} -> file:sync(File);
                 Failed -> Failed
             end,
    case Synced of
        ok -> line("data synced ~b bytes", [?DATA_BYTES]);
        _ -> line("data synced failed", [])
    end.

open_write(Path, Seed) ->
    case file:open(Path, [write, binary]) of
        {ok, File} ->
            case file:write(File, data_content(Seed)) of
                ok -> {ok, File};
                Failed -> Failed
            end;
        Failed ->
            Failed
    end.

-spec data_read_here() -> ok.
data_read_here() ->
    case file:read_file(?SYNCED) of
        {ok, Synced} ->
            line("data synced ~b bytes md5 ~s", [byte_size(Synced), binary:encode_hex(erlang:md5(Synced), lowercase)]);
        _Failed ->
            line("data synced failed", []),
            timer:sleep(?LOG_DRAIN_MS)
    end,
    case file:read_file(?UNSYNCED) of
        {ok, Unsynced} ->
            Kept = byte_size(Unsynced) =< ?DATA_BYTES andalso
                Unsynced =:= binary:part(data_content(1), 0, byte_size(Unsynced)),
            line("data unsynced ~b bytes ~s", [byte_size(Unsynced), case Kept of true -> "prefix"; false -> "other" end]);
        {error, enoent} ->
            line("data unsynced absent", []);
        _Other ->
            line("data unsynced failed", []),
            timer:sleep(?LOG_DRAIN_MS)
    end.

data_content(Seed) ->
    << <<((Index + Seed) rem 251)>> || Index <- lists:seq(0, ?DATA_BYTES - 1) >>.

window({Role, Window}) ->
    Sectors = sectors(Window),
    line("window ~s sectors ~b", [Role, Sectors]),
    %% /data's littlefs volume formats the data window at boot, over its first block.
    case Role of
        data -> ok;
        _ -> holds(Role, Window, 0)
    end,
    holds(Role, Window, Sectors - 1),
    case call(fun() -> erx_blk_window:read(Window, Sectors, 1) end) of
        {error, erange} -> line("window ~s sector ~b refused", [Role, Sectors]);
        _Other -> line("window ~s sector ~b failed", [Role, Sectors])
    end.

%% A window's length, or 0 when it does not answer, which fails every later step.
sectors(Window) ->
    case call(fun() -> erx_blk_window:info(Window) end) of
        {ok, #{sectors := Sectors}} -> Sectors;
        _Other -> 0
    end.

%% The medium sector whose host pattern a window's sector holds.
holds(Role, Window, Sector) ->
    case call(fun() -> erx_blk_window:read(Window, Sector, 1) end) of
        {ok, Bytes = <<Tag:8/binary, Index:64/little, _/binary>>} when Tag =:= ?HOST_TAG ->
            case Bytes =:= pattern(Index, ?HOST_TAG) of
                true -> line("window ~s sector ~b holds host ~b", [Role, Sector, Index]);
                false -> line("window ~s sector ~b holds other", [Role, Sector])
            end;
        {ok, _Other} -> line("window ~s sector ~b holds other", [Role, Sector]);
        _Failed -> line("window ~s sector ~b failed", [Role, Sector])
    end.

rewrite_last(Window) ->
    Last = sectors(Window) - 1,
    Written = case call(fun() -> erx_blk_window:read(Window, Last, 1) end) of
                  {ok, <<Tag:8/binary, Index:64/little, _/binary>>} when Tag =:= ?HOST_TAG ->
                      call(fun() -> erx_blk_window:write(Window, Last, pattern(Index, ?GUEST_TAG)) end);
                  Other ->
                      Other
              end,
    case Written of
        ok -> line("window data wrote sector ~b", [Last]);
        _Failed -> line("window data wrote sector ~b failed", [Last])
    end.

refused_write(Window) ->
    Sectors = sectors(Window),
    case call(fun() -> erx_blk_window:write(Window, Sectors, pattern(0, ?GUEST_TAG)) end) of
        {error, erange} -> line("window vault write sector ~b refused", [Sectors]);
        _Other -> line("window vault write sector ~b failed", [Sectors])
    end.

read(Sector) ->
    case call(fun() -> erx_blk:read(Sector, 1) end) =:= {ok, pattern(Sector, ?HOST_TAG)} of
        true -> line("read sector ~b ok", [Sector]);
        false -> line("read sector ~b failed", [Sector])
    end.

refused(Sector) ->
    case call(fun() -> erx_blk:read(Sector, 1) end) of
        {error, out_of_range} -> line("read sector ~b refused", [Sector]);
        _Other -> line("read sector ~b failed", [Sector])
    end.

write(Sector) ->
    case call(fun() -> erx_blk:write(Sector, pattern(Sector, ?GUEST_TAG)) end) of
        ok -> line("wrote sector ~b", [Sector]);
        _Other -> line("wrote sector ~b failed", [Sector])
    end.

pattern(Sector, Tag) ->
    binary:copy(<<Tag/binary, Sector:64/little>>, ?SECTOR_BYTES div ?RECORD_BYTES).

-spec lfs_write_here() -> ok.
lfs_write_here() ->
    case file:write_file(?RESTARTED, data_content(2)) of
        ok -> line("lfs wrote ~b bytes", [?DATA_BYTES]);
        _Failed -> line("lfs write failed", [])
    end.

%% Kills the volume's worker, the one process erx_lfs links to besides its parent, erx_lfs_sup,
%% KILL_DELAY_MS after its line. The worker is sensitive, so its initial call does not show.
-spec lfs_kill_here() -> ok.
lfs_kill_here() ->
    Workers = case whereis(erx_lfs) of
                  undefined ->
                      [];
                  Owner ->
                      [{links, Links}, {parent, Parent}] = process_info(Owner, [links, parent]),
                      [Pid || Pid <- Links, is_pid(Pid), Pid =/= Parent]
              end,
    case Workers of
        [Worker] ->
            _ = spawn(fun() -> timer:sleep(?KILL_DELAY_MS), exit(Worker, kill) end),
            line("lfs worker found", []);
        _None ->
            line("lfs worker not found", [])
    end.

-spec lfs_read_here() -> ok.
lfs_read_here() ->
    Expected = data_content(2),
    case file:read_file(?RESTARTED) of
        {ok, Expected} -> line("lfs read back ~b bytes", [?DATA_BYTES]);
        {ok, _Other} -> line("lfs read back other", []);
        _Failed -> line("lfs read failed", [])
    end.

%% A driver call, with the exit of a call that timed out or found the driver gone taken as
%% that step's failure, so one bad step does not end the run before "blk: done".
call(Fun) ->
    try Fun() catch exit:Reason -> {exit, Reason} end.

%% A line of the step, kept for the system domain to print.
line(Format, Arguments) ->
    put(lines, [text(Format, Arguments) | get(lines)]),
    ok.

text(Format, Arguments) ->
    iolist_to_binary(["blk: ", io_lib:format(Format, Arguments), $\n]).

display(Line) ->
    true = erlang:display_string(stdout, Line),
    ok.
