%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A window of the block service (docs/design-storage.md, "Partitions are windows", PW1):
%% one partition's sectors, numbered from 0, and nothing of the medium beyond them. A
%% file system holds a window's pid and nothing of the device; the window checks every
%% request against its sectors with erx_blk_table:place/3 and hands only what passes to
%% the device process, erx_blk, at the medium's sector. erx_blk_service starts one per
%% partition the table admits, linked to itself.
%%
%% A request answers {ok, Bytes} for a read and ok for a write, or {error, Reason}: einval
%% for a request that names no whole sectors or more than one device request carries
%% (erx_blk_request:max_sectors/0), erange for one that leaves the window, erofs passed on
%% from the write path, and eio for anything else the device process answered or a device
%% process that did not answer. A window
%% answers one request at a time, in order.
%%
%% Every write goes through erx_blk:write/2 to the driver's one write path, erx_blk_write,
%% which is where the trial rule (U4) applies to it; a window adds no rule of its own.

-module(erx_blk_window).
-behaviour(gen_server).

-export([start_link/1, read/3, write/3, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

%% Longer than erx_blk's own call timeout, so the window answers a device that did not.
-define(CALL_TIMEOUT, 35000).

-spec start_link(erx_blk_table:window()) -> {ok, pid()}.
start_link(Window) ->
    gen_server:start_link(?MODULE, Window, []).

%% Count sectors from Sector of the window.
-spec read(pid(), non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, einval | erange | erofs | eio}.
read(Window, Sector, Count) -> call(Window, {read, Sector, Count}).

%% Bytes, whole sectors, from Sector of the window.
-spec write(pid(), non_neg_integer(), binary()) -> ok | {error, einval | erange | erofs | eio}.
write(Window, Sector, Bytes) -> call(Window, {write, Sector, Bytes}).

%% The window's role and its length in sectors; where it lies on the medium is not the
%% client's to know.
-spec info(pid()) -> {ok, #{role := erx_blk_table:role(), sectors := pos_integer()}} | {error, eio}.
info(Window) -> call(Window, info).

%% A window that is gone or did not answer is the client's eio.
call(Window, Request) ->
    try gen_server:call(Window, Request, ?CALL_TIMEOUT) catch exit:_ -> {error, eio} end.

init(Window) ->
    {ok, Window}.

handle_call({read, Sector, Count}, _From, Window) ->
    {reply, request(erx_blk_table:place(Window, Sector, Count), fun(First) -> erx_blk:read(First, Count) end),
     Window};
handle_call({write, Sector, Bytes}, _From, Window) ->
    Placed = case sectors(Bytes) of
                 {ok, Count} -> erx_blk_table:place(Window, Sector, Count);
                 Refused -> Refused
             end,
    {reply, request(Placed, fun(First) -> erx_blk:write(First, Bytes) end), Window};
handle_call(info, _From, Window = {Role, _Start, Sectors}) ->
    {reply, {ok, #{role => Role, sectors => Sectors}}, Window};
handle_call(_Other, _From, Window) ->
    {reply, {error, einval}, Window}.

handle_cast(_Other, Window) ->
    {noreply, Window}.

%% A stray message is dropped unlogged, so no sender fills the log with terms it chose.
handle_info(_Other, Window) ->
    {noreply, Window}.

%% The sectors a write's bytes fill: einval when they are not one or more whole sectors.
sectors(Bytes) when is_binary(Bytes), byte_size(Bytes) > 0, byte_size(Bytes) rem ?ERX_VIRTIO_BLK_SECTOR_SIZE =:= 0 ->
    {ok, byte_size(Bytes) div ?ERX_VIRTIO_BLK_SECTOR_SIZE};
sectors(_Bytes) ->
    {error, einval}.

%% A placed request, handed to the device process, its answer in the window's terms.
request({error, Reason}, _Device) ->
    {error, Reason};
request({ok, First}, Device) ->
    try Device(First) of
        {ok, Bytes} when is_binary(Bytes) -> {ok, Bytes};
        ok -> ok;
        {error, bad_count} -> {error, einval};
        {error, erofs} -> {error, erofs};
        _DeviceError -> {error, eio}
    catch
        exit:_ -> {error, eio}
    end.
