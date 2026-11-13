%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A window of the block service (docs/design-storage.md, "Partitions are windows", PW1):
%% one partition's sectors, numbered from 0, and nothing of the medium beyond them. A
%% file system holds a window's pid and nothing of the device; the window checks every
%% request against its sectors with erx_blk_table:place/3 and hands only what passes to
%% the device process, erx_blk, at the medium's sector. erx_blk_service starts one per
%% partition the table admits, linked to itself.
%%
%% A request answers {ok, Bytes} for a read and ok for a write or a flush, or {error,
%% Reason}: einval for a request that names no whole sectors or more than one device
%% request carries (max_sectors of erx_blk:info/1), erange for one that leaves the window,
%% erofs for a write to an image window or passed on from the write path, and eio for
%% anything else the device process answered or a device process that did not answer. A
%% flush is the whole medium's (erx_blk:flush/1). A window answers one request at a time,
%% in order.
%%
%% A window is bound to one device process's life. Its first request that reaches the
%% device binds it to the process erx_blk names then (erx_blk:device/0); it calls that
%% process by pid from then on and monitors it. Once that process has ended, every request
%% that would reach the device answers eio, even when a new device process runs: whatever
%% restarted the driver (storage_ctl, /dev's ctl, the supervisor) reset the device, and
%% nothing promises the reset kept what its write cache held, so a later flush could not
%% vouch for the writes this window answered ok. The file system over the window breaks
%% on its next request, and its restart mounts it afresh on a window opened after the
%% restart, which binds to the new process. A request made while no device process runs
%% answers eio and binds nothing.
%%
%% Every write goes through erx_blk:write/3 to the driver's one write path, erx_blk_write,
%% which is where the trial rule (U4) applies to it. A window adds one rule of its own: a
%% window of role {image, Name}, on an EROFS image (erx_blk_image), is read-only and sends
%% no write to the device.

-module(erx_blk_window).
-behaviour(gen_server).

-export([start_link/1, read/3, write/3, flush/1, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

%% Longer than erx_blk's own call timeout, so the window answers a device that did not.
-define(CALL_TIMEOUT, 35000).

%% The window's sectors, and the device process it is bound to: unbound until a request
%% first reaches the device, {bound, Pid, Monitor} after, and ended once Pid has ended, for
%% good. Calling by pid alone already fails once Pid has ended; the monitor makes the end
%% final, so a later process that reused the pid is never reached.
-record(state, {window :: erx_blk_table:window(),
                device = unbound :: unbound | {bound, pid(), reference()} | ended}).

-spec start_link(erx_blk_table:window()) -> {ok, pid()}.
start_link(Window) ->
    gen_server:start_link(?MODULE, Window, []).

%% Count sectors from Sector of the window.
-spec read(pid(), non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, einval | erange | erofs | eio}.
read(Window, Sector, Count) -> call(Window, {read, Sector, Count}).

%% Bytes, whole sectors, from Sector of the window.
-spec write(pid(), non_neg_integer(), binary()) -> ok | {error, einval | erange | erofs | eio}.
write(Window, Sector, Bytes) -> call(Window, {write, Sector, Bytes}).

%% ok once every write the window answered before it is durable on the medium.
-spec flush(pid()) -> ok | {error, eio}.
flush(Window) -> call(Window, flush).

%% The window's role and its length in sectors; where it lies on the medium is not the
%% client's to know.
-spec info(pid()) -> {ok, #{role := erx_blk_table:role(), sectors := pos_integer()}} | {error, eio}.
info(Window) -> call(Window, info).

%% A window that is gone or did not answer is the client's eio.
call(Window, Request) ->
    try gen_server:call(Window, Request, ?CALL_TIMEOUT) catch exit:_ -> {error, eio} end.

init(Window) ->
    {ok, #state{window = Window}}.

handle_call({read, Sector, Count}, _From, State = #state{window = Window}) ->
    case erx_blk_table:place(Window, Sector, Count) of
        {ok, First} ->
            on_bound_device(fun(Device) -> erx_blk:read(Device, First, Count) end, fun answer/1,
                            State);
        Refused -> {reply, Refused, State}
    end;
%% An image window is read-only: a write to it is the client's erofs, and reaches no device.
handle_call({write, _Sector, _Bytes}, _From,
            State = #state{window = {{image, _Name}, _Start, _Sectors}}) ->
    {reply, {error, erofs}, State};
handle_call({write, Sector, Bytes}, _From, State = #state{window = Window}) ->
    Placed = case sectors(Bytes) of
                 {ok, Count} -> erx_blk_table:place(Window, Sector, Count);
                 NotSectors -> NotSectors
             end,
    case Placed of
        {ok, First} ->
            on_bound_device(fun(Device) -> erx_blk:write(Device, First, Bytes) end, fun answer/1,
                            State);
        Refused -> {reply, Refused, State}
    end;
%% A flush covers the whole medium, so it covers the window's sectors too.
handle_call(flush, _From, State) ->
    on_bound_device(fun erx_blk:flush/1, fun flush_answer/1, State);
handle_call(info, _From, State = #state{window = {Role, _Start, Sectors}}) ->
    {reply, {ok, #{role => Role, sectors => Sectors}}, State};
handle_call(_Other, _From, State) ->
    {reply, {error, einval}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

%% The device process the window is bound to has ended: the window answers eio from now on.
handle_info({'DOWN', Monitor, process, Device, _Reason},
            State = #state{device = {bound, Device, Monitor}}) ->
    {noreply, State#state{device = ended}};
%% A stray message is dropped unlogged, so no sender fills the log with terms it chose.
handle_info(_Other, State) ->
    {noreply, State}.

%% The sectors a write's bytes fill: einval when they are not one or more whole sectors.
sectors(Bytes) when is_binary(Bytes), byte_size(Bytes) > 0, byte_size(Bytes) rem ?ERX_VIRTIO_BLK_SECTOR_SIZE =:= 0 ->
    {ok, byte_size(Bytes) div ?ERX_VIRTIO_BLK_SECTOR_SIZE};
sectors(_Bytes) ->
    {error, einval}.

%% The reply to a request that reaches the device: Call on the device process the window
%% is bound to, in the window's terms by Answer, or eio when that process has ended or
%% there is none to bind to.
on_bound_device(Call, Answer, State) ->
    case bind(State) of
        {ok, Device, Bound} -> {reply, Answer(fun() -> Call(Device) end), Bound};
        none -> {reply, {error, eio}, State}
    end.

%% The device process the window is bound to, binding an unbound window to the one
%% registered now and monitoring it; none once the bound process has ended or while no
%% device process runs.
bind(State = #state{device = {bound, Device, _Monitor}}) ->
    {ok, Device, State};
bind(#state{device = ended}) ->
    none;
bind(State = #state{device = unbound}) ->
    case erx_blk:device() of
        {ok, Device} ->
            Monitor = monitor(process, Device),
            {ok, Device, State#state{device = {bound, Device, Monitor}}};
        {error, no_device} ->
            none
    end.

%% The device process's answer to a flush in the window's terms: ok only for ok, since a
%% flush moves no bytes, and eio for anything else.
flush_answer(Call) ->
    try Call() of
        ok -> ok;
        _DeviceError -> {error, eio}
    catch
        exit:_ -> {error, eio}
    end.

%% The device process's answer to a read or a write in the window's terms.
answer(Call) ->
    try Call() of
        {ok, Bytes} when is_binary(Bytes) -> {ok, Bytes};
        ok -> ok;
        {error, bad_count} -> {error, einval};
        {error, erofs} -> {error, erofs};
        _DeviceError -> {error, eio}
    catch
        exit:_ -> {error, eio}
    end.
