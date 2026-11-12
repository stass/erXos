%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_sup).
-moduledoc """
The start service's supervision tree (docs/design-apps.md,
"Concurrency"), rest_for_one over two children:

1. the keepers' branch, erx_starter_keepers, a one_for_one supervisor of
   one erx_starter_row per enabled row that runs or is down, and one keeper
   per session started once (`start` of a row that is not enabled);
2. the table, erx_starter, which owns the merged table.

A crash of the table restarts the table alone: it reads the table again
and finds the rows the keepers' branch holds (erx_start_table:reconcile/2),
so no session ends. A crash of the keepers' branch ends every session it
kept, and rest_for_one restarts the table after it, which starts each
enabled row again.

The keepers' branch restarts no row. A row's supervisor is a transient
child, and its only end is `shutdown`, at its intensity or at a stop, so
OTP keeps its child spec without restarting it: a spec with no pid is a
row that is down, and the record of it outlives the table's process. A
stop deletes the spec, so a row with none is stopped or never started.
""".
-behaviour(supervisor).

-export([start_link/0, start_link/1, start_row/2, start_once/3, stop/1, held/0]).
-export([init/1]).

-define(KEEPERS, erx_starter_keepers).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(system).

-doc """
The tree, its table made from Manifest: `system`, the system manifest, or
the table's part of a manifest as erx_starter:manifest_table/1 makes it,
for the tests.
""".
-spec start_link(erx_starter:source()) -> supervisor:startlink_ret().
start_link(Manifest) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {top, Manifest}).

-doc """
Starts the supervisor of row Name, which keeps Row's session
(erx_starter_row:start_link/1); a row that is down is started afresh,
with its intensity's count cleared. {error, {already_started, Pid}} for a
row that runs.
""".
-spec start_row(binary(), erx_starter_row:row()) -> supervisor:startchild_ret().
start_row(Name, Row) ->
    _ = supervisor:delete_child(?KEEPERS, {row, Name}),
    supervisor:start_child(?KEEPERS, #{id => {row, Name}, start => {erx_starter_row, start_link, [Row]},
                                       restart => transient, type => supervisor, shutdown => infinity}).

-doc "Starts one keeper of principal Principal's session with Start, which nothing starts again.".
-spec start_once(binary(), pos_integer(), map()) -> supervisor:startchild_ret().
start_once(Name, Principal, Start) ->
    supervisor:start_child(?KEEPERS, #{id => {once, Name}, start => {erx_starter_keeper, start_link, [Principal, Start]},
                                       restart => temporary, shutdown => 5000}).

-doc "Stops what keeps row Name's sessions, its supervisor and a keeper started once, and ends them.".
-spec stop(binary()) -> ok.
stop(Name) ->
    lists:foreach(fun(Id) ->
                          _ = supervisor:terminate_child(?KEEPERS, Id),
                          _ = supervisor:delete_child(?KEEPERS, Id)
                  end, [{row, Name}, {once, Name}]).

-doc "The rows the keepers' branch holds a supervisor for: running, with its pid, or down.".
-spec held() -> [{binary(), pid() | down}].
held() ->
    [{Name, run_state(Pid)} || {{row, Name}, Pid, _, _} <- supervisor:which_children(?KEEPERS)].

run_state(Pid) when is_pid(Pid) -> Pid;
run_state(_Undefined) -> down.

init({top, Manifest}) ->
    Keepers = #{id => keepers, start => {supervisor, start_link, [{local, ?KEEPERS}, ?MODULE, keepers]},
                type => supervisor, shutdown => infinity},
    Table = #{id => table, start => {erx_starter, start_link, [Manifest]}},
    {ok, {#{strategy => rest_for_one}, [Keepers, Table]}};
init(keepers) ->
    {ok, {#{strategy => one_for_one}, []}}.
