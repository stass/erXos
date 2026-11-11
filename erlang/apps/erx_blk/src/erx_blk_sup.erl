%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's supervisor (docs/design-storage.md, "The block driver"): the device
%% process, erx_blk, restarted after a crash and left stopped after a shutdown, which is how
%% it ends on a device that refuses a reset; then the partition process, erx_blk_service,
%% which admits the partition table and holds the windows; then the mounts of its image
%% windows at /images/NAME. erx_storage's supervisor starts /data on the data window
%% once this application has started. A machine without a disk starts
%% no device process: erx_blk's init/1 returns ignore, and the partition process serves no
%% window.

-module(erx_blk_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Device = #{id => erx_blk,
               start => {erx_blk, start_link, []},
               restart => transient,
               shutdown => 2000,
               type => worker,
               modules => [erx_blk]},
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
    {ok, {#{strategy => one_for_one, intensity => 3, period => 60}, [Device, Service, Images]}}.
