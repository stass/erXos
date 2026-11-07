%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's partition process (docs/design-storage.md, "The block driver" and
%% "The boot medium's table"), under erx_blk_sup after the device process. It reads the
%% three records of the partition table through erx_blk, admits them with
%% erx_blk_table:admit/4, and starts one window, erx_blk_window, per partition the layout
%% names: the boot-selection record's, slot A's, slot B's, the vault's and the data
%% partition's. A table that differs from the layout in anything but the data partition's
%% length, a medium too small for the layout, a record the device does not return and a
%% machine without a block device each leave the service with no window and one line in
%% the kernel log naming why: the driver serves none of such a medium.
%%
%% Once the table is admitted, it also starts a read-only window on each EROFS image of
%% the booted slot that the release's manifest gives the system domain, of role
%% {image, Name}, which erx_blk_image places from the root's -erx boot words and the
%% manifest; a boot with no slot serves none, and an image it refuses is one line of the
%% log. mount_images/0, the supervisor's next child, mounts each at /images/NAME
%% (docs/design-stopgap.md, "Image windows").
%%
%% The windows are linked to the service, which does not trap exits, so a window that
%% crashes takes the service and its other windows with it, and the supervisor's restart
%% reads the table again and starts new windows; a client's old pid then answers eio, and
%% so does a mounted image until the next boot.
%%
%% window/1 is where a window's pid is handed out, to any caller in the system domain and
%% for any role. It is the seam the device service replaces: that service names each
%% client's windows by role and hands their pids out as grants, the slot and record windows
%% to the slot writer alone (PW1).

-module(erx_blk_service).
-behaviour(gen_server).

-export([start_link/0, window/1, mount_images/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

%% Where the system domain's images mount, each under its manifest name (docs/design-stopgap.md,
%% "Image windows").
-define(IMAGES_POINT, "/images/").

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

%% Mounts each image window at /images/NAME, read-only, and starts no process: the
%% supervisor's child after the service, which a call reaches once the table is admitted.
%% A mount that fails is one line of the log; erx_ns has logged the reader's diagnostic.
%% A mount that exits, as erx_ns's call does when its process ends, is a line of the log
%% too, so no mount stops the block driver's start and /data.
-spec mount_images() -> ignore.
mount_images() ->
    Images = case whereis(?MODULE) of
                 undefined -> {error, no_service};
                 Pid -> try gen_server:call(Pid, images, ?CALL_TIMEOUT) catch exit:_ -> {error, no_answer} end
             end,
    case Images of
        {error, Reason} -> log("no image is mounted: ~0p", [Reason]);
        _ -> lists:foreach(fun mount_image/1, Images)
    end,
    ignore.

mount_image({Name, Window}) ->
    Point = <<?IMAGES_POINT, Name/binary>>,
    try erx_ns:mount({erofs, Window}, Point, []) of
        ok -> log("image ~s mounted at ~s", [Name, Point]);
        {error, Reason} -> log("image ~s is not mounted: ~0p", [Name, Reason])
    catch
        exit:_ -> log("image ~s is not mounted: the namespace did not answer", [Name])
    end.

init([]) ->
    {ok, admitting, {continue, admit}}.

handle_continue(admit, admitting) ->
    {noreply, serve(admit())}.

-spec serve({ok, [erx_blk_table:window()]} | {error, term()}) -> state().
serve({ok, Windows}) ->
    Served = maps:from_list([{Role, start_window(Window)}
                             || Window = {Role, _Start, _Sectors} <- Windows ++ image_windows()]),
    log("partition table admitted; ~b windows", [map_size(Served)]),
    {served, Served};
%% A machine without a disk is a configuration, so it has no line here, as it has none from
%% erx_blk.
serve({error, no_device}) ->
    {refused, no_device};
serve({error, Reason}) ->
    log("the medium is not served: ~0p", [Reason]),
    {refused, Reason}.

start_window(Window) ->
    {ok, Pid} = erx_blk_window:start_link(Window),
    Pid.

%% The windows on the booted slot's images (erx_blk_image). The manifest is read only on a
%% boot that has a slot.
image_windows() ->
    Arguments = case init:get_argument(erx) of
                    {ok, Words} -> Words;
                    error -> []
                end,
    case erx_blk_image:boot_slot(Arguments) of
        {ok, none} ->
            [];
        {ok, Slot} ->
            slot_images(Slot, file:read_file(manifest_path()));
        {error, Reason} ->
            log("no image is served: ~0p", [Reason]),
            []
    end.

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

%% The capacity, then the records at the sectors the layout fixes, then the table. Every
%% value in a refusal is an atom of this driver's or an integer, never bytes the medium
%% holds.
admit() ->
    maybe
        {ok, #{capacity := Capacity}} ?= device(catch_exit(fun erx_blk:info/0)),
        ok ?= erx_blk_table:check_capacity(Capacity),
        {ok, [Mbr, VaultEbr, DataEbr]} ?= read_records(erx_blk_table:records(), []),
        erx_blk_table:admit(Capacity, Mbr, VaultEbr, DataEbr)
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
handle_call(images, _From, State = {served, Windows}) ->
    {reply, [{Name, Pid} || {{image, Name}, Pid} <- maps:to_list(Windows)], State};
handle_call(images, _From, State) ->
    {reply, [], State};
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
