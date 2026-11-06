%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lfs_sup).
-moduledoc """
The domain's `/data` (docs/design-stopgap.md#littlefs-in-the-system-domain):
the volume's owner, `erx_lfs`, on the block service's data window, and the
grant that mounts it at `/data`. Neither is restarted: a volume that failed
stays unavailable until the next boot, so no later write races one the
failed volume left outstanding. A machine without a data window starts
neither.
""".

-behaviour(supervisor).

-export([start_link/0, start_link/3, start_grant/2]).
-export([init/1]).

-doc "Starts `/data` on the data window, mounted at `/data`.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(data, <<"/data">>, erx_lfs).

-doc "Starts a littlefs volume on the window of `Role`, mounted at `Point`.".
-spec start_link(erx_blk_table:role(), binary(), atom()) -> supervisor:startlink_ret().
start_link(Role, Point, Name) ->
    supervisor:start_link(?MODULE, {Role, Point, Name}).

-doc false.
init({Role, Point, Name}) ->
    Flags = #{strategy => one_for_all, intensity => 0, period => 1},
    Owner = #{id => owner, start => {erx_lfs, start_link, [Role, Name]},
              restart => temporary, shutdown => brutal_kill, type => worker,
              modules => [erx_lfs]},
    Grant = #{id => grant, start => {?MODULE, start_grant, [Name, Point]},
              restart => temporary, shutdown => brutal_kill, type => worker,
              modules => [erx_fs]},
    {ok, {Flags, [Owner, Grant]}}.

-doc false.
-spec start_grant(atom(), binary()) -> {ok, pid()} | ignore | {error, term()}.
start_grant(Name, Point) ->
    case whereis(Name) of
        undefined ->
            ignore;
        _ ->
            ok = code:ensure_modules_loaded([erx_fs, erx_fs_grant, erx_lfs, erx_littlefs]),
            {ok, Grant} = erx_fs:start_link(erx_lfs, Name, rw),
            _ = erx_ns:unmount(Point),
            case erx_ns:mount(Grant, Point, [{tree, <<"data">>}, rw]) of
                ok ->
                    {ok, Grant};
                {error, _} = Error ->
                    unlink(Grant),
                    exit(Grant, kill),
                    Error
            end
    end.
