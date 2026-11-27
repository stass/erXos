%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's partition process (docs/design-storage.md, "The block driver" and
%% "The boot medium's table"), under erx_blk_sup after the device process. It reads the
%% five records of the partition table through erx_blk, admits them with
%% erx_blk_table:admit/2, and starts one window, erx_blk_window, per partition the layout
%% names: the boot-selection record's, boot A's, boot B's, the vault's and the data
%% partition's. A table that differs from the layout in anything but
%% the data partition's length, a medium too small for the layout, a record the device
%% does not return and a machine without a block device each leave the service with no
%% window and one line in the kernel log naming why: the driver serves none of such a
%% medium.
%%
%% Once the table is admitted, it also starts the windows the boot value decides, which
%% erx_blk_table:booted/1 derives from the -erx_record boot words the domain library
%% gives the block device's holder: the read-only system window on the booted slot's
%% system partition (docs/design-fiasco.md, "The booted slot"), which reads no
%% manifest and is started only in the holder given a system_image record; the
%% read-only record_volume window on the whole record partition, started in the holder
%% whose system_image record names it, whatever the slot, for erx_storage_login_keys;
%% and a read-only window on each EROFS image of the booted slot that the release's manifest
%% gives the system domain, of role
%% {image, Name}, which erx_blk_image places from the slot and the manifest. A boot with
%% no slot, an unknown boot, serves neither; so does a boot value the reader refuses,
%% which is one line of the log, as is each image refused. Nothing mounts an image
%% window: only erx_storage_system opens an image on a window, the `system` window with
%% its layout (Erx::ErofsReads). In a storage domain, whose namespace holds no manifest,
%% the read fails and no image is served, which is one line of the log.
%%
%% The windows are linked to the service, which does not trap exits, so a window that
%% crashes takes the service and its other windows with it, and so, through erx_blk_sup,
%% which restarts nothing, the storage domain; its restart reads the table again and
%% starts new windows.
%%
%% window/1 is where a window's pid is handed out, to any caller in the driver's domain and
%% for any role. It is the seam the device service replaces: that service names each
%% client's windows by role and hands their pids out as grants, the boot, system A,
%% system B and record windows to the slot writer alone and the system window to the
%% manifest's holder of it (PW1).

-module(erx_blk_service).
-behaviour(gen_server).

-export([start_link/0, window/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

%% The table is read after init/1 returns, so the boot does not wait on the device; a
%% call made before then waits for it: at most the capacity and three reads, each bounded
%% by erx_blk's own call timeout (30 s), and a margin.
-define(CALL_TIMEOUT, 150000).

%% served maps each role to its window; refused holds why the medium is not served.
-type state() :: admitting | {served, #{erx_blk_table:role() => pid()}} | {refused, term()}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% The window on the partition of Role.
-spec window(erx_blk_table:role()) -> {ok, pid()} | {error, no_window | no_service | {refused, term()}}.
window(Role) ->
    case whereis(?MODULE) of
        undefined -> {error, no_service};
        Pid -> try gen_server:call(Pid, {window, Role}, ?CALL_TIMEOUT) catch exit:_ -> {error, no_service} end
    end.

init([]) ->
    {ok, admitting, {continue, admit}}.

handle_continue(admit, admitting) ->
    {noreply, serve(admit())}.

-spec serve({ok, [erx_blk_table:window()], pos_integer()} | {error, term()}) -> state().
serve({ok, Windows, MaxSectors}) ->
    {Slot, System} = booted(erx_blk_table:booted(erx_device_record:records())),
    Booted = System ++ image_windows(Slot),
    Served = maps:from_list([{Role, start_window(Window, MaxSectors)}
                             || Window = {Role, _Start, _Sectors} <- Windows ++ Booted]),
    log("partition table admitted; ~b windows", [map_size(Served)]),
    {served, Served};
%% no_device is either a machine without a disk, a configuration that has no line, or a disk
%% erx_blk refused, which erx_blk has already logged: either way, no second line here.
serve({error, no_device}) ->
    {refused, no_device};
serve({error, Reason}) ->
    log("the medium is not served: ~0p", [Reason]),
    {refused, Reason}.

start_window(Window, MaxSectors) ->
    {ok, Pid} = erx_blk_window:start_link(Window, MaxSectors),
    Pid.

%% The booted slot and its system window, with a refused boot value's or system_image
%% record's line in the log.
booted({Slot, System, ok}) ->
    {Slot, System};
booted({Slot, System, {error, bad_boot}}) ->
    log("no system window or image is served: bad_boot", []),
    {Slot, System};
booted({Slot, System, {error, {bad_device_record, Reason}}}) ->
    log("no system window is served: ~s", [Reason]),
    {Slot, System}.

%% The windows on the booted slot's images (erx_blk_image). The manifest is read only on a
%% boot that has a slot.
image_windows(none) ->
    [];
image_windows(Slot) ->
    slot_images(Slot, file:read_file(manifest_path())).

slot_images(Slot, {ok, Manifest}) ->
    case erx_blk_image:windows(Manifest, Slot) of
        {ok, Windows, Refused} ->
            lists:foreach(fun({Name, Why}) -> log("image ~s is not served: ~0p", [Name, Why]) end, Refused),
            Windows;
        {error, Reason} ->
            log("no image is served: ~0p", [Reason]),
            []
    end;
slot_images(_Slot, {error, Reason}) ->
    log("no image is served: the manifest: ~0p", [Reason]),
    [].

%% The archive's manifest as the system domain's namespace shows it: the release slice
%% at / holds the archive's files under system/ (liberx/release.c), so the ABI's path
%% loses that prefix.
manifest_path() ->
    <<"system/", Path/binary>> = ?ERX_SYSTEM_MANIFEST_PATH_BYTES,
    <<"/", Path/binary>>.

%% The capacity and the most sectors a request carries, then the records at the sectors
%% the layout fixes, then the table, answered with the windows it admits and that most.
%% Every value in a refusal is an atom of this driver's or an integer, never bytes the
%% medium holds.
admit() ->
    maybe
        {ok, #{capacity := Capacity, max_sectors := MaxSectors}} ?= device(catch_exit(fun erx_blk:info/0)),
        ok ?= erx_blk_table:check_capacity(Capacity),
        {ok, Records} ?= read_records(erx_blk_table:records(), []),
        {ok, Windows} ?= erx_blk_table:admit(Capacity, Records),
        {ok, Windows, MaxSectors}
    end.

read_records([], Read) ->
    {ok, lists:reverse(Read)};
read_records([{Name, Sector} | Rest], Read) ->
    case device(catch_exit(fun() -> erx_blk:read(Sector, 1) end)) of
        {ok, Bytes} -> read_records(Rest, [Bytes | Read]);
        {error, Reason} -> {error, {read, Name, Reason}}
    end.

device({ok, Value}) -> {ok, Value};
device({error, Reason}) when is_atom(Reason) -> {error, Reason};
device({error, _Reason}) -> {error, device}.

catch_exit(Fun) ->
    try Fun() catch exit:_ -> {error, no_answer} end.

handle_call({window, Role}, _From, State = {served, Windows}) ->
    case Windows of
        #{Role := Pid} -> {reply, {ok, Pid}, State};
        #{} -> {reply, {error, no_window}, State}
    end;
handle_call({window, _Role}, _From, State = {refused, Reason}) ->
    {reply, {error, {refused, Reason}}, State};
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

%% A stray message is dropped unlogged, so no sender fills the log with terms it chose.
handle_info(_Other, State) ->
    {noreply, State}.

%% One line of the kernel log.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_blk_service: ", io_lib:format(Format, Arguments)]),
    ok.
