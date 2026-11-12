%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_sup).
-moduledoc """
The start service's supervision tree (docs/design-apps.md,
"Concurrency"), rest_for_one over two children:

1. the keepers' branch, erx_starter_keepers, a one_for_one supervisor of
   one erx_starter_row per enabled row that runs or is down, one keeper
   per session started once (`start` of a row that is not enabled), and
   the table's records below;
2. the table, erx_starter, which owns the merged table.

A crash of the table restarts the table alone: it finds the table it had
and the rows it kept in the keepers' branch, so no session ends. A crash
of the keepers' branch ends every session it kept and every record, and
rest_for_one restarts the table after it, which makes the table as at
boot.

**The records.** The keepers' branch is where the table's state outlives
the table's process, as child specs OTP keeps:

* `{row, Name}`, a transient child, is an enabled row's supervisor. Its
  only end is `shutdown`, at its intensity or at a stop, so OTP keeps its
  spec without restarting it: a spec with no pid is a row that is down.
* `{stopped, Name}` is an enabled row that `stop` stopped, so a restarted
  table leaves it stopped rather than starting it.
* `rc_conf` holds the text of rc.conf the table was last made from, so a
  restarted table has the table it had while rc.conf is unread.

Both of the last two hold their value in their spec's start arguments and
stand for no process: their start function returns `ignore`, which a
one_for_one supervisor answers by keeping the spec with no pid. Each
`{row, Name}` and `{stopped, Name}` spec holds the row's
erx_starter_row:row(), what its session is kept with, so a restarted
table compares it with the table it makes (erx_start_table:reconcile/2).
""".
-behaviour(supervisor).

-export([start_link/0, start_link/2, start_row/2, stop_row/2, start_once/3, stop/1, held/0]).
-export([record/1, recorded/0]).
-export([init/1, ignore/1]).

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
    _ = supervisor:delete_child(?KEEPERS, {row, Name}),
    ok = remove(Name, stopped),
    supervisor:start_child(?KEEPERS, #{id => {row, Name}, start => {erx_starter_row, start_link, [Row]},
                                       restart => transient, type => supervisor, shutdown => infinity}).

-doc """
Stops enabled row Name as stop/1 does, and records it as stopped with Row,
what it is kept with, so a restarted table leaves it stopped.
""".
-spec stop_row(binary(), erx_starter_row:row()) -> ok.
stop_row(Name, Row) ->
    ok = stop(Name),
    {ok, undefined} = supervisor:start_child(?KEEPERS, record_spec({stopped, Name}, Row)),
    ok.

-doc "Starts one keeper of principal Principal's session with Start, which nothing starts again.".
-spec start_once(binary(), pos_integer(), map()) -> supervisor:startchild_ret().
start_once(Name, Principal, Start) ->
    supervisor:start_child(?KEEPERS, #{id => {once, Name}, start => {erx_starter_keeper, start_link, [Principal, Start]},
                                       restart => temporary, shutdown => 5000}).

-doc """
Stops what keeps row Name's sessions, its supervisor and a keeper started
once, ends them, and drops the row's records.
""".
-spec stop(binary()) -> ok.
stop(Name) ->
    lists:foreach(fun(Kind) -> ok = remove(Name, Kind) end, [row, once, stopped]).

-doc """
The rows the keepers' branch holds a record for: running, with its row
supervisor's pid, down or stopped, each with the row it is kept with.
""".
-spec held() -> [{binary(), pid() | down | stopped, erx_starter_row:row()}].
held() ->
    [{Name, run_state(Kind, Pid), row(Id)}
     || {{Kind, Name} = Id, Pid, _, _} <- supervisor:which_children(?KEEPERS), Kind =:= row orelse Kind =:= stopped].

-doc "Records Text as the text of rc.conf the table is made from.".
-spec record(binary()) -> ok.
record(Text) ->
    _ = supervisor:delete_child(?KEEPERS, rc_conf),
    {ok, undefined} = supervisor:start_child(?KEEPERS, record_spec(rc_conf, Text)),
    ok.

-doc "The text record/1 last recorded in this keepers' branch, or none.".
-spec recorded() -> {ok, binary()} | none.
recorded() ->
    case supervisor:get_childspec(?KEEPERS, rc_conf) of
        {ok, #{start := {?MODULE, ignore, [Text]}}} -> {ok, Text};
        {error, not_found} -> none
    end.

-doc false.
ignore(_Value) ->
    ignore.

%% A record holding Value, for which no process stands.
record_spec(Id, Value) ->
    #{id => Id, start => {?MODULE, ignore, [Value]}, restart => transient}.

remove(Name, Kind) ->
    _ = supervisor:terminate_child(?KEEPERS, {Kind, Name}),
    _ = supervisor:delete_child(?KEEPERS, {Kind, Name}),
    ok.

%% The row a {row, Name} or {stopped, Name} spec holds.
row(Id) ->
    {ok, #{start := {_Module, _Function, [Row]}}} = supervisor:get_childspec(?KEEPERS, Id),
    Row.

run_state(row, Pid) when is_pid(Pid) -> Pid;
run_state(row, _Undefined) -> down;
run_state(stopped, _Undefined) -> stopped.

init({top, Manifest, Directory}) ->
    Keepers = #{id => keepers, start => {supervisor, start_link, [{local, ?KEEPERS}, ?MODULE, keepers]},
                type => supervisor, shutdown => infinity},
    Table = #{id => table, start => {erx_starter, start_link, [Manifest, Directory]}},
    {ok, {#{strategy => rest_for_one}, [Keepers, Table]}};
init(keepers) ->
    {ok, {#{strategy => one_for_one}, []}}.
