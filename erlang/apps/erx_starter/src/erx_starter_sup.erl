%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_sup).
-moduledoc """
The start service's supervision tree (docs/design-apps.md,
"Concurrency"), rest_for_one over the `apps` tree's grants (erx_starter_fs),
which the system's table alone serves, and two children:

1. the keepers' branch, erx_starter_keepers, a one_for_one supervisor of
   one erx_starter_row per enabled row that runs or is down, one keeper
   per session started once (`start` of a row that is not enabled), and
   the table's records below;
2. the table, erx_starter, which owns the merged table.

A crash of the table restarts the table alone: it finds the table it had
and the rows it kept in the keepers' branch, so no session ends. A crash
of the keepers' branch ends every session it kept and every record, and
rest_for_one restarts the table after it, which makes the table as at
boot. The end of the `apps` tree's grants supervisor ends every grant
to the tree, and rest_for_one restarts the keepers' branch and the
table after it, so every session the keepers kept ends, and those
started again receive new grants. A session no keeper kept, root's
console session among them, keeps running with no `/apps` until it
restarts (TODO.md). One grant's end ends that grant alone: grants are
temporary children.

**The records.** The keepers' branch is where the table's state outlives
the table's process, as child specs OTP keeps:

* `{row, Name}`, a transient child, is an enabled row's supervisor. Its
  only end is `shutdown`, at its intensity or at a stop, so OTP keeps its
  spec without restarting it: a spec with no pid is a row that is down.
* `{stopped, Name}`, the stopped mark, is a row that `stop` stopped while
  it was enabled. It holds nothing but the name. No setting clears it:
  the table never starts a marked row (erx_start_table:reconcile/3), so
  it stays stopped whatever rc.conf sets, until start_row/2 clears it, at
  `start` or `enable`, or the branch restarts and drops every record.
* `rc_conf` holds the text of rc.conf the table was last made from, so a
  restarted table has the table it had while rc.conf is unread.

Both of the last two hold their value in their spec's start arguments and
stand for no process: their start function returns `ignore`, which a
one_for_one supervisor answers by keeping the spec with no pid. Each
`{row, Name}` spec holds the row's erx_starter_row:row(), what its session
is kept with, so a restarted table compares it with the table it makes.

**Order.** stop_row/1 and start_row/2 write their record before the act it records, so a
table that ends between the two leaves the intent behind: stop_row/1
marks the row before it ends it, and start_row/2 clears the mark before
it starts the row. record/1 replaces the text by deleting the old record
and adding the new, and does nothing for an unchanged text, so the one
moment with no record is during a real change of rc.conf (TODO.md).
""".
-behaviour(supervisor).

-export([start_link/0, start_link/2, start_row/2, stop_row/1, start_once/3, stop/1, held/0]).
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
Marks enabled row Name stopped, then stops it as stop/1 does, so no table
starts it again, a table restarted between the two included.
""".
-spec stop_row(binary()) -> ok.
stop_row(Name) ->
    ok = mark(Name),
    stop(Name).

%% The stopped mark of row Name, written once.
mark(Name) ->
    case supervisor:start_child(?KEEPERS, record_spec({stopped, Name}, Name)) of
        {ok, undefined} -> ok;
        {error, already_present} -> ok
    end.

-doc "Starts one keeper of principal Principal's session with Start, which nothing starts again.".
-spec start_once(binary(), pos_integer(), map()) -> supervisor:startchild_ret().
start_once(Name, Principal, Start) ->
    supervisor:start_child(?KEEPERS, #{id => {once, Name}, start => {erx_starter_keeper, start_link, [Principal, Start]},
                                       restart => temporary, shutdown => 5000}).

-doc """
Stops what keeps row Name's sessions, its supervisor and a keeper started
once, ends them, and drops the row's supervisor spec. A stopped mark
stays: only start_row/2 clears it.
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
    Children = supervisor:which_children(?KEEPERS),
    {[{Name, run_state(Pid), row(Id)} || {{row, Name} = Id, Pid, _, _} <- Children],
     [Name || {{stopped, Name}, _, _, _} <- Children]}.

-doc """
Records Text as the text of rc.conf the table is made from. An unchanged
text is left as it is recorded.
""".
-spec record(binary()) -> ok.
record(Text) ->
    case recorded() of
        {ok, Text} ->
            ok;
        _Other ->
            _ = supervisor:delete_child(?KEEPERS, rc_conf),
            {ok, undefined} = supervisor:start_child(?KEEPERS, record_spec(rc_conf, Text)),
            ok
    end.

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

%% The row a {row, Name} spec holds.
row(Id) ->
    {ok, #{start := {erx_starter_row, start_link, [Row]}}} = supervisor:get_childspec(?KEEPERS, Id),
    Row.

run_state(Pid) when is_pid(Pid) -> Pid;
run_state(_Undefined) -> down.

init({top, Manifest, Directory}) ->
    Keepers = #{id => keepers, start => {supervisor, start_link, [{local, ?KEEPERS}, ?MODULE, keepers]},
                type => supervisor, shutdown => infinity},
    Table = #{id => table, start => {erx_starter, start_link, [Manifest, Directory]}},
    {ok, {#{strategy => rest_for_one}, apps(Manifest) ++ [Keepers, Table]}};
init(keepers) ->
    {ok, {#{strategy => one_for_one}, []}}.

%% The `apps` tree's grants (erx_starter_fs), first, so they are served before any row
%% starts a session and a restart of the table ends no grant; the system's table alone
%% serves them, and a test's table, made from its own manifest, serves none.
apps(system) ->
    [#{id => apps, start => {erx_starter_fs, start_link, []}, type => supervisor, shutdown => infinity}];
apps(_Manifest) ->
    [].
