%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_sup).
-moduledoc """
The start service's supervision tree (docs/design-apps.md,
"Concurrency"), rest_for_one over the `apps` tree's grants (erx_starter_fs),
which the system's table alone serves, and three children:

1. the keepers' branch, erx_starter_keepers, a one_for_one supervisor of
   one erx_starter_row per enabled row that runs or is down, one keeper
   per session started once (`start` of a row that is not enabled), and
   the table's records, erx_starter_records, below;
2. the rc.conf process, erx_starter_rc, which does every file operation
   on rc.conf, one at a time;
3. the table, erx_starter, which owns the merged table.

A crash of the table restarts the table alone: it finds the table it had
and the rows it kept in the keepers' branch, so no session ends, and the
rc.conf process carries on with any write the table asked for, which
lands before the restarted table's read of rc.conf or not at all
(erx_starter_rc). A crash of the rc.conf process restarts it and the
table. A crash of the keepers' branch ends every session it kept and
every record, and rest_for_one restarts the rc.conf process and the
table after it, which makes the table as at boot. The end of the `apps`
tree's grants supervisor ends every grant to the tree, and rest_for_one
restarts the keepers' branch, the rc.conf process and the table after
it, so every session the keepers kept ends, and those
started again receive new grants. A session no keeper kept, root's
console session among them, keeps running with no `/apps` until it
restarts (TODO.md). One grant's end ends that grant alone: grants are
temporary children.

**The keepers' branch** is where the table's state outlives the table's
process:

* `{row, Name}`, a transient child, is an enabled row's supervisor. Its
  only end is `shutdown`, at its intensity or at a stop, so OTP keeps its
  spec without restarting it: a spec with no pid is a row that is down.
  The spec holds the row's erx_starter_row:row(), what its session is
  kept with, so a restarted table compares it with the table it makes.
* `records`, the branch's first child, is erx_starter_records, which
  holds the stopped marks and the text of rc.conf the table was last made
  from. It is the branch's one significant child, and the branch shuts
  down when it ends: a crash of the records process ends every session
  the branch kept, and an end of the branch ends the records, so the two
  are lost only together, and the table is made again as at boot.

**Order.** stop_row/1 and start_row/2 write their record before the act
it records, so a table that ends between the two leaves the intent
behind: stop_row/1 marks the row before it ends it, and start_row/2
clears the mark before it starts the row.
""".
-behaviour(supervisor).

-export([start_link/0, start_link/2, start_row/2, clear/1, stop_row/1, start_once/3, stop/1, held/0]).
-export([init/1]).

-define(KEEPERS, erx_starter_keepers).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    start_link(system, erx_starter_rc:directory()).

-doc """
The tree, its table made from Manifest: `system`, the system manifest, or
the table's part of a manifest as erx_starter:manifest_table/1 makes it,
for the tests. rc.conf is in Directory: erx_starter_rc:directory/0, or
the tests' own.
""".
-spec start_link(erx_starter:source(), binary()) -> supervisor:startlink_ret().
start_link(Manifest, Directory) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, {top, Manifest, Directory}).

-doc """
Starts the supervisor of row Name, which keeps Row's session
(erx_starter_row:start_link/1); a row that is down or stopped is started
afresh, with its intensity's count cleared. {error, {already_started,
Pid}} for a row that runs.
""".
-spec start_row(binary(), erx_starter_row:row()) -> supervisor:startchild_ret().
start_row(Name, Row) ->
    ok = clear(Name),
    supervisor:start_child(?KEEPERS, #{id => {row, Name}, start => {erx_starter_row, start_link, [Row]},
                                       restart => transient, type => supervisor, shutdown => infinity}).

-doc """
Clears the two records that keep row Name from starting when the table is
made: its stopped mark, and its supervisor's spec when the row is down. A
row that runs keeps running.
""".
-spec clear(binary()) -> ok.
clear(Name) ->
    _ = supervisor:delete_child(?KEEPERS, {row, Name}),
    erx_starter_records:unmark(Name).

-doc """
Marks enabled row Name stopped, then stops it as stop/1 does, so no table
starts it again, a table restarted between the two included.
""".
-spec stop_row(binary()) -> ok.
stop_row(Name) ->
    ok = erx_starter_records:mark(Name),
    stop(Name).

-doc "Starts one keeper of principal Principal's session with Start, which nothing starts again.".
-spec start_once(binary(), pos_integer(), map()) -> supervisor:startchild_ret().
start_once(Name, Principal, Start) ->
    supervisor:start_child(?KEEPERS, #{id => {once, Name}, start => {erx_starter_keeper, start_link, [Principal, Start]},
                                       restart => temporary, shutdown => 5000}).

-doc """
Stops what keeps row Name's sessions, its supervisor and a keeper started
once, ends them, and drops the row's supervisor spec. A stopped mark
stays: only clear/1 clears it.
""".
-spec stop(binary()) -> ok.
stop(Name) ->
    lists:foreach(fun(Kind) -> ok = remove(Name, Kind) end, [row, once]).

-doc """
What the keepers' branch holds: each row it keeps a supervisor for,
running, with the supervisor's pid, or down, with the row it is kept
with, and the names of the rows marked stopped.
""".
-spec held() -> {[{binary(), pid() | down, erx_starter_row:row()}], Stopped :: [binary()]}.
held() ->
    {[{Name, run_state(Pid), row(Id)} || {{row, Name} = Id, Pid, _, _} <- supervisor:which_children(?KEEPERS)],
     erx_starter_records:stopped()}.

remove(Name, Kind) ->
    _ = supervisor:terminate_child(?KEEPERS, {Kind, Name}),
    _ = supervisor:delete_child(?KEEPERS, {Kind, Name}),
    ok.

%% The row a {row, Name} spec holds.
row(Id) ->
    {ok, #{start := {erx_starter_row, start_link, [Row]}}} = supervisor:get_childspec(?KEEPERS, Id),
    Row.

run_state(Pid) when is_pid(Pid) -> Pid;
run_state(_Undefined) -> down.

init({top, Manifest, Directory}) ->
    Keepers = #{id => keepers, start => {supervisor, start_link, [{local, ?KEEPERS}, ?MODULE, keepers]},
                type => supervisor, shutdown => infinity},
    %% Its shutdown waits for the file operation in progress (erx_starter_rc).
    Rc = #{id => rc, start => {erx_starter_rc, start_link, []}, shutdown => infinity},
    Table = #{id => table, start => {erx_starter, start_link, [Manifest, Directory]}},
    {ok, {#{strategy => rest_for_one}, apps(Manifest) ++ [Keepers, Rc, Table]}};
init(keepers) ->
    Records = #{id => records, start => {erx_starter_records, start_link, []},
                restart => temporary, significant => true},
    {ok, {#{strategy => one_for_one, auto_shutdown => any_significant}, [Records]}}.

%% The `apps` tree's grants (erx_starter_fs), first, so they are served before any row
%% starts a session and a restart of the table ends no grant; the system's table alone
%% serves them, and a test's table, made from its own manifest, serves none.
apps(system) ->
    [#{id => apps, start => {erx_starter_fs, start_link, []}, type => supervisor, shutdown => infinity}];
apps(_Manifest) ->
    [].
