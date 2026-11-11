%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_storage_sup).
-moduledoc """
The storage domain's supervisor (docs/design-stopgap.md, "littlefs in the storage domain").
Its one child is `/data`, littlefs on the block driver's data window
(erx_lfs_sup), which erx_storage's application starts once erx_blk's has
started, so the block service holds the windows by then. The child is not
restarted: a volume that failed stays unavailable, so no later write races one
the failed volume left outstanding.
""".
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc false.
init([]) ->
    Data = #{id => erx_lfs_sup,
             start => {erx_lfs_sup, start_link, []},
             restart => temporary,
             shutdown => infinity,
             type => supervisor,
             modules => [erx_lfs_sup]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, [Data]}}.
