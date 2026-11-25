%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lfs_sup).
-moduledoc """
The data partition's littlefs volume (docs/design-stopgap.md#littlefs-in-the-storage-domain):
the volume's owner, `erx_lfs`, on the block service's data window; the grant
that mounts its `data` tree at `/data` in this domain; and, for each tree of
the volume (erx_lfs:trees/0), the mint of the files service of the tree's
name, which hands other domains grants of that tree alone (erx_fs_mint):
`data`, and `packages`, the installed app packages
(docs/design-packaging.md, "Where a package lies"). The owner starts once
the volume has mounted, so a mount that fails fails the domain's boot before
it reports ready, and each mint names itself its service's mint before that
report. Every child is permanent and the restart intensity is 0: when any
ends, as the owner does when the volume fails, this supervisor ends, and
through erx_storage_sup the storage domain. Nothing is restarted here: the
domain's restart mounts the volume afresh, so no later write races one the
failed volume left outstanding. A machine without a data window starts none
of them.
""".

-behaviour(supervisor).

-export([start_link/0, start_grant/1, start_mint/2]).
-export([init/1]).

-define(NAME, erx_lfs).
-define(POINT, <<"/data">>).

-doc "Starts the volume on the data window, its `data` tree mounted at `/data`.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link(?MODULE, []).

-doc false.
init([]) ->
    Flags = #{strategy => one_for_all, intensity => 0, period => 1},
    Owner = #{id => owner, start => {erx_lfs, start_link, [data, ?NAME]},
              restart => permanent, shutdown => brutal_kill, type => worker,
              modules => [erx_lfs]},
    Grant = #{id => grant, start => {?MODULE, start_grant, [?NAME]},
              restart => permanent, shutdown => brutal_kill, type => worker,
              modules => [erx_fs]},
    Mints = [#{id => {mint, Tree}, start => {?MODULE, start_mint, [Tree, ?NAME]},
               restart => permanent, shutdown => brutal_kill, type => worker,
               modules => [erx_fs_mint]}
             || Tree <- erx_lfs:trees()],
    {ok, {Flags, [Owner, Grant | Mints]}}.

-doc false.
-spec start_grant(atom()) -> {ok, pid()} | ignore | {error, term()}.
start_grant(Name) ->
    case whereis(Name) of
        undefined ->
            ignore;
        _ ->
            ok = code:ensure_modules_loaded([erx_fs, erx_fs_grant, erx_lfs, erx_littlefs]),
            erx_fs:start_mounted(erx_lfs, {Name, data}, rw, ?POINT)
    end.

-doc false.
-spec start_mint(atom(), atom()) -> {ok, pid()} | ignore.
start_mint(Tree, Name) ->
    case whereis(Name) of
        undefined -> ignore;
        %% The owner has mounted the volume, so the mint's mount answers its arguments.
        _Owner -> erx_fs_mint:start_link(Tree, erx_lfs, fun() -> {Name, Tree} end)
    end.
