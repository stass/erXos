%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's supervisor (docs/design-storage.md, "The block driver"): the device
%% process, registered as erx_blk and started by erx_blk:start_link/0 from the transport
%% table (erx_blk_virtio for virtio-mmio); then the partition process, erx_blk_service,
%% which admits the partition table and holds the windows; then the mounts of its image
%% windows at /images/NAME. erx_storage's supervisor starts /data on the data window once
%% this application has started. A machine without a disk starts no device process:
%% erx_blk:start_link/0 returns ignore, and the partition process serves no window.
%%
%% It restarts nothing (docs/design-stopgap.md, "littlefs in the storage domain"): every
%% child that runs a process is permanent, under a restart intensity of 0, so the end of
%% the device or the partition process, by a crash or by the shutdown with which erx_blk_virtio
%% ends on a broken queue, ends this supervisor and the erx_blk
%% application, which is permanent, and so the storage domain, whose restart gives the
%% device again. A stop, start or restart through the driver-control facet
%% (erx_driver_ctl) is no such end: the supervisor's terminate_child/2 and
%% restart_child/2 count no restart.

-module(erx_blk_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Device = #{id => erx_blk,
               start => {erx_blk, start_link, []},
               restart => permanent,
               shutdown => 2000,
               type => worker,
               modules => [erx_blk, erx_blk_virtio]},
    Service = #{id => erx_blk_service,
                start => {erx_blk_service, start_link, []},
                restart => permanent,
                shutdown => 2000,
                type => worker,
                modules => [erx_blk_service]},
    %% /images/NAME: each image window of the service, mounted once; it starts no process.
    Images = #{id => images,
               start => {erx_blk_service, mount_images, []},
               restart => temporary,
               shutdown => brutal_kill,
               type => worker,
               modules => [erx_blk_service]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, [Device, Service, Images]}}.
