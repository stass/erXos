%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's transport contract (docs/design-storage.md, "The block driver"): the
%% four calls every device process answers, so nothing above the transport, the block
%% service's partition and window processes included, depends on the controller. One device
%% process runs in the storage domain, registered as erx_blk, under erx_blk_sup:
%% erx_blk_virtio for a virtio-mmio block device. start_link/0 picks it from the domain's
%% one block record by the record's peripheral, through the table of transports/0.
%%
%% Each call comes in two forms: one to the process registered as erx_blk now, and one to
%% a device process named by its pid, which device/0 returns. A restart of the driver
%% starts a new process, which resets the device, and nothing promises that the reset
%% keeps what the device's write cache held; a caller whose answers must not cross a
%% restart, erx_blk_window, binds to one pid and calls that.
%%
%% Each call answers with one closed set of errors: bad_count for bytes that are not whole
%% sectors or a count above max_sectors, and out_of_range for sectors past the capacity,
%% both before the controller is touched; erofs, the write path's refusal on a trial boot
%% (U4), which erx_blk_write does not apply yet (TODO.md); busy when the device process's
%% backlog is full; no_device when no device process runs; and {device, Detail} for a
%% request the controller or the medium failed. Detail is built from fixed atoms and
%% integers, never from a controller's bytes, and stays in the storage domain: a window
%% answers its client einval for bad_count, erofs for erofs and eio for every other error.
%% A device process that does not answer within the call's timeout, or that a call by pid
%% finds ended, exits the caller, which erx_blk_window and erx_blk_service catch.

-module(erx_blk).

-export([start_link/0, device/0, read/2, write/2, flush/0, info/0]).
-export([read/3, write/3, flush/1, info/1]).
-export([transports/0, choose/1, chosen/0]).

-export_type([reason/0, info/0]).

-define(CALL_TIMEOUT, 30000).

-type reason() :: bad_count | out_of_range | erofs | busy | no_device | {device, term()}.
-type info() :: #{transport := virtio_mmio | sdhci, capacity := non_neg_integer(),
                  max_sectors := pos_integer(), detail := map()}.

%% The transport table: a block record's CMSIS-SVD peripheral and the device process that
%% drives it, or why none does. A new controller is one row and one module.
-spec transports() -> [{atom(), {ok, module()} | {error, term()}}].
transports() ->
    [{virtio_blk, {ok, erx_blk_virtio}},
     {sdhci, {ok, erx_blk_sd}}].

%% The device process for the domain's block record, or ignore when the domain has none it
%% can drive. A domain with no block record has no line in the log, since a machine
%% without a disk is a configuration, not a fault; every other refusal is one line. This
%% runs in erx_blk_sup's process, where a raise would end the permanent application and
%% the boot, so an exception is a refusal too.
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    case chosen() of
        {ok, Module, Spec} ->
            Module:start_link(Spec);
        none ->
            ignore;
        {error, Reason} ->
            log("the block device is not driven: ~0p", [Reason]),
            ignore
    end.

%% Pure, for its host test: the device process module and the record it drives, from what
%% erx_device_record:find/2 returned for each peripheral of transports/0. A record that
%% does not parse refuses them all, since it says the record's writer and its reader
%% disagree, and so does more than one record, since the manifest gives a storage domain
%% one block device.
%% The device process's module and record for the block records the domain holds, as
%% choose/1 decides; erx_blk_sup reads it too, to start the owners of the record's shared
%% lines before the device process. A record the reader raises on is an error, not a raise.
-spec chosen() -> {ok, module(), erx_device_record:spec()} | none | {error, term()}.
chosen() ->
    try choose([{Peripheral, erx_device_record:find(block, Peripheral)}
                || {Peripheral, _Transport} <- transports()])
    catch Class:Raised -> {error, {Class, Raised}}
    end.

-spec choose([{atom(), {ok, [erx_device_record:spec()]} | {error, {bad_device_record, string()}}}]) ->
          {ok, module(), erx_device_record:spec()} | none | {error, term()}.
choose(Found) ->
    case [Peripheral || {Peripheral, {error, _}} <- Found] of
        [] ->
            case [{Peripheral, Spec} || {Peripheral, {ok, Specs}} <- Found, Spec <- Specs] of
                [] ->
                    none;
                [{Peripheral, Spec}] ->
                    case proplists:get_value(Peripheral, transports()) of
                        {ok, Module} -> {ok, Module, Spec};
                        {error, _Reason} = Refused -> Refused
                    end;
                Several ->
                    {error, {block_records, [Peripheral || {Peripheral, _Spec} <- Several]}}
            end;
        Unread ->
            {error, {bad_device_record, Unread}}
    end.

%% The device process registered now, for the forms below that take its pid.
-spec device() -> {ok, pid()} | {error, no_device}.
device() ->
    case whereis(?MODULE) of
        undefined -> {error, no_device};
        Pid -> {ok, Pid}
    end.

%% Count sectors from Sector, at most max_sectors of info/0 in one request.
-spec read(non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, reason()}.
read(Sector, Count) -> registered(fun(Device) -> read(Device, Sector, Count) end).

%% read/2 on the device process Device.
-spec read(pid(), non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, reason()}.
read(Device, Sector, Count) -> gen_server:call(Device, {read, Sector, Count}, ?CALL_TIMEOUT).

%% Data, whole sectors, from Sector: ok once the controller reports them written to the medium.
-spec write(non_neg_integer(), binary()) -> ok | {error, reason()}.
write(Sector, Data) -> registered(fun(Device) -> write(Device, Sector, Data) end).

%% write/2 on the device process Device.
-spec write(pid(), non_neg_integer(), binary()) -> ok | {error, reason()}.
write(Device, Sector, Data) -> gen_server:call(Device, {write, Sector, Data}, ?CALL_TIMEOUT).

%% ok once every write the same device process answered before it is durable on the medium.
-spec flush() -> ok | {error, reason()}.
flush() -> registered(fun flush/1).

%% flush/0 on the device process Device: only writes Device answered.
-spec flush(pid()) -> ok | {error, reason()}.
flush(Device) -> gen_server:call(Device, flush, ?CALL_TIMEOUT).

%% The transport's name, the capacity in sectors of 512 bytes, the most sectors one request
%% moves, and what the transport reports about itself for the log and the inspector.
-spec info() -> {ok, info()} | {error, no_device}.
info() -> registered(fun info/1).

%% info/0 on the device process Device.
-spec info(pid()) -> {ok, info()}.
info(Device) -> gen_server:call(Device, info, ?CALL_TIMEOUT).

%% Call on the device process registered now, or no_device when none runs.
registered(Call) ->
    case device() of
        {ok, Device} -> Call(Device);
        {error, no_device} -> {error, no_device}
    end.

%% One line of the kernel log. Every value in it is a fixed atom of this driver's, or the
%% exception of a bug, never text that choose/1 takes from a record.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_blk: ", io_lib:format(Format, Arguments)]),
    ok.
