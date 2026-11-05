%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs_sup).
-moduledoc """
The domain's `/tmp` as one unit (docs/design-tmp.md#starting-and-mounting):
the tree process and the grant for the domain itself, under `one_for_all`,
started by `kernel_safe_sup`.

The tree process starts first, with the cap of the runtime's startup limits
(`erx_ns:tmp_limit/0`). The grant's start then loads every module the
serving processes can call (`erx_ramfs_serving`, generated with `xref`), so
none of them asks the code server for code while the code server may itself
be waiting on `/tmp` (T6), starts the grant on the tree process, which it
finds by its registered name, and mounts it at `/tmp`, after removing any
entry an earlier instance left there. The
grant's file owners are linked to it, so when the tree process, the grant or
an owner ends, all of them end, `/tmp` restarts empty and is mounted again,
and the old grant's open files answer `eio` to their clients.
""".

-behaviour(supervisor).

-export([start_link/0, start_link/3, start_grant/2]).
-export([init/1]).

-define(POINT, <<"/tmp">>).

-doc "Starts `/tmp` with the runtime's cap, mounted at `/tmp`.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(erx_ns:tmp_limit(), ?POINT, erx_ramfs).

-doc """
Starts a RAM file system under a cap of `Cap` bytes, mounted at `Point`, whose
tree process is registered as `Name`; tests start a second one with a small
cap.
""".
-spec start_link(non_neg_integer(), binary(), atom()) -> supervisor:startlink_ret().
start_link(Cap, Point, Name) ->
    supervisor:start_link(?MODULE, {Cap, Point, Name}).

-doc false.
init({Cap, Point, Name}) ->
    Flags = #{strategy => one_for_all, intensity => 1, period => 5},
    Tree = #{id => tree, start => {erx_ramfs, start_link, [Cap, Name]},
             restart => permanent, shutdown => brutal_kill, type => worker,
             modules => [erx_ramfs]},
    Grant = #{id => grant, start => {?MODULE, start_grant, [Name, Point]},
              restart => permanent, shutdown => brutal_kill, type => worker,
              modules => [erx_fs]},
    {ok, {Flags, [Tree, Grant]}}.

-doc false.
-spec start_grant(atom(), binary()) -> {ok, pid()} | {error, term()}.
start_grant(Name, Point) ->
    ok = code:ensure_modules_loaded(erx_ramfs_serving:modules()),
    {ok, Grant} = erx_fs:start_link(erx_ramfs, Name, rw),
    _ = erx_ns:unmount(Point),
    case erx_ns:mount(Grant, Point, [{tree, <<"tmp">>}, rw]) of
        ok ->
            {ok, Grant};
        {error, _} = Error ->
            %% A grant the supervisor does not know of must not outlive the start.
            unlink(Grant),
            exit(Grant, kill),
            Error
    end.

