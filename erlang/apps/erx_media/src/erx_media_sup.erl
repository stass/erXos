%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_sup).
-moduledoc """
The media domain's supervisor (docs/design-drives.md, "Failure handling"): one drive
process, erx_media_drive, for each drive of the registry that has been asked for, each
started at the first ask for it under the id `{drive, N}` and restarted if it ends, so
that the registry's drives, and no name a caller makes up, bound how many there are;
and the mint of the files service `media`, whose tree is erx_media_tree (erx_fs_mint),
the one child it starts with. It makes the domain's mount counter
(erx_media_volume:new_mounts/0) before any volume can start.
""".

-behaviour(supervisor).

-export([start_link/0, drive/1]).
-export([init/1]).

-doc "Starts the supervisor, registered under its module's name, with no drive process.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc """
The drive process of the drive `{drive, N}`, started now if none runs. The caller has
found the drive in the registry (erx_media_drive:medium/1).
""".
-spec drive(non_neg_integer()) -> pid().
drive(N) when is_integer(N), N >= 0 ->
    Find = fun() -> erx:cap({drive, N}) end,
    case supervisor:start_child(?MODULE, #{id => {drive, N}, start => {erx_media_drive, start_link, [N, Find]}}) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end.

-doc false.
init([]) ->
    ok = erx_media_volume:new_mounts(),
    Mint = #{id => media, start => {erx_fs_mint, start_link, [media, erx_media_tree, fun() -> media end]},
             modules => [erx_fs_mint, erx_media_tree]},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 60}, [Mint]}}.
