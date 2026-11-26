%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ramfs_sup).
-moduledoc """
The domain's `/tmp` as one unit (docs/design-tmp.md#starting-and-mounting):
the grant for the domain itself, which holds the tree as an own tree of
`erx_fs`, under `one_for_all`, started by `kernel_safe_sup`.

The grant's start loads every module the grant can call
(`erx_ramfs_serving`, generated with `xref`), so none of them asks the code
server for code while the code server may itself be waiting on `/tmp` (T6),
starts the grant with the cap of the runtime's startup limits
(`erx_ns:tmp_limit/0`) under the heap bound `heap_words/1` computes, and
mounts it at `/tmp`, after removing any entry an earlier instance left
there. When the grant ends, by a crash or by passing its heap bound, `/tmp`
restarts empty and is mounted again, and the old grant's open files answer
`eio` to their clients.
""".

-behaviour(supervisor).

-export([start_link/0, start_link/2, start_grant/2, grant_options/1, heap_words/1]).
-export([init/1]).

-define(POINT, <<"/tmp">>).

-doc "Starts `/tmp` with the runtime's cap, mounted at `/tmp`.".
-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(erx_ns:tmp_limit(), ?POINT).

-doc """
Starts a RAM file system under a cap of `Cap` bytes, mounted at `Point`; tests
start a second one with a small cap.
""".
-spec start_link(non_neg_integer(), binary()) -> supervisor:startlink_ret().
start_link(Cap, Point) ->
    supervisor:start_link(?MODULE, {Cap, Point}).

-doc false.
init({Cap, Point}) ->
    Flags = #{strategy => one_for_all, intensity => 1, period => 5},
    Grant = #{id => grant, start => {?MODULE, start_grant, [Cap, Point]},
              restart => permanent, shutdown => brutal_kill, type => worker,
              modules => [erx_fs, erx_ramfs]},
    {ok, {Flags, [Grant]}}.

-doc false.
-spec start_grant(non_neg_integer(), binary()) -> {ok, pid()} | {error, term()}.
start_grant(Cap, Point) ->
    ok = code:ensure_modules_loaded(erx_ramfs_serving:modules()),
    erx_fs:start_mounted(erx_ramfs, Cap, rw, Point, grant_options(Cap)).

-doc """
The options of the grant for a cap of `Cap` bytes: its heap bound, and a
sensitive process, since its state is the domain's files, so no `process_info/2`,
trace or crash dump shows them.
""".
-spec grant_options(non_neg_integer()) -> #{max_heap_size := pos_integer(), sensitive := true}.
grant_options(Cap) ->
    #{max_heap_size => heap_words(Cap), sensitive => true}.

-doc """
The grant's heap bound for a cap of `Cap` bytes, in words (docs/design-tmp.md,
"The grant's heap bound"): the reserve any grant of `erx_fs` may hold at its
bounds with no tree, plus the tree at its cap, `Cap` times one plus ERTS's
overhead per charged byte, and as much again for what a step leaves behind
until the next collection.
""".
-spec heap_words(non_neg_integer()) -> pos_integer().
heap_words(Cap) when is_integer(Cap), Cap >= 0 ->
    TreeBytes = Cap * (1 + erx_ramfs:overhead_ratio()),
    erx_fs:reserve_words(#{}) + ceil(2 * TreeBytes / erlang:system_info(wordsize)).
