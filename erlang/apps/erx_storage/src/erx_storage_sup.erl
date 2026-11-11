%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_storage_sup).
-moduledoc """
The storage domain's supervisor (docs/design-stopgap.md, "littlefs in the storage domain").
Its children:

* the mint of storage_ctl, the driver-control facet through which the system
  domain stops, starts or restarts the block driver under erx_blk's supervisor
  (erx_driver_ctl). The domain service holds the mint until the domain ends, so
  the mint is permanent under an intensity of 0: its end ends this supervisor,
  and with it the application, which is permanent, and the domain;
* `/data`, littlefs on the block driver's data window (erx_lfs_sup), which
  erx_storage's application starts once erx_blk's has started, so the block
  service holds the windows by then. It is not restarted: a volume that failed
  stays unavailable, so no later write races one the failed volume left
  outstanding.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    %% The units this domain holds, by their manifest names, and their driver processes.
    Units = #{block => {erx_blk_sup, erx_blk}},
    Control = #{id => storage_ctl,
                start => {erx_driver_ctl, start_mint, [storage_ctl, Units]},
                restart => permanent,
                shutdown => brutal_kill,
                type => worker,
                modules => [erx_driver_ctl]},
    Data = #{id => erx_lfs_sup,
             start => {erx_lfs_sup, start_link, []},
             restart => temporary,
             shutdown => infinity,
             type => supervisor,
             modules => [erx_lfs_sup]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, [Control, Data]}}.
