%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_records).
-moduledoc """
The start table's records (docs/design-apps.md, "Concurrency"): what the
table must not forget when its own process ends, held by a process in the
keepers' branch (erx_starter_sup), so the records live exactly as long as
the sessions the branch keeps.

* The stopped marks: the name of each row that `stop` stopped while it
  was enabled. No setting clears a mark: the table never starts a marked
  row (erx_start_table:reconcile/3), so it stays stopped whatever rc.conf
  sets, until unmark/1, at `start` or `enable`.
* The basis the table was last made from, rc.conf's text or the
  published card's defaults (erx_starter:basis()), so a restarted table
  has the table it had while rc.conf is unread.
* The last package set the table took (erx_starter:packages/2), so a
  restarted table has the rows of every app it keeps without asking the
  package process for its set.

Only the table writes the records, from its own process, and each write
replaces what it changes in one step, so a table that ends at any point
finds either the record before the write or the record after it.
""".
-behaviour(gen_server).

-export([start_link/0, mark/1, unmark/1, stopped/0, record/1, recorded/0, record_set/1, recorded_set/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-spec start_link() -> gen_server:start_ret().
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Marks row Name stopped; a row marked already stays marked.".
-spec mark(binary()) -> ok.
mark(Name) ->
    gen_server:call(?MODULE, {mark, Name}).

-doc "Clears row Name's stopped mark, if it has one.".
-spec unmark(binary()) -> ok.
unmark(Name) ->
    gen_server:call(?MODULE, {unmark, Name}).

-doc "The names of the rows marked stopped, in order.".
-spec stopped() -> [binary()].
stopped() ->
    gen_server:call(?MODULE, stopped).

-doc "Records Basis as the basis the table is made from.".
-spec record(erx_starter:basis()) -> ok.
record(Basis) ->
    gen_server:call(?MODULE, {record, Basis}).

-doc "The basis record/1 last recorded, or none.".
-spec recorded() -> {ok, erx_starter:basis()} | none.
recorded() ->
    gen_server:call(?MODULE, recorded).

-doc "Records Set as the last package set the table took.".
-spec record_set([erx_pkg_plan:published()]) -> ok.
record_set(Set) ->
    gen_server:call(?MODULE, {record_set, Set}).

-doc "The set record_set/1 last recorded; before the first, the empty set.".
-spec recorded_set() -> [erx_pkg_plan:published()].
recorded_set() ->
    gen_server:call(?MODULE, recorded_set).

%% The state: the stopped marks, an ordset of names, the recorded basis and the
%% recorded package set.
init([]) ->
    {ok, #{stopped => ordsets:new(), basis => none, set => []}}.

handle_call({mark, Name}, _From, #{stopped := Stopped} = State) ->
    {reply, ok, State#{stopped := ordsets:add_element(Name, Stopped)}};
handle_call({unmark, Name}, _From, #{stopped := Stopped} = State) ->
    {reply, ok, State#{stopped := ordsets:del_element(Name, Stopped)}};
handle_call(stopped, _From, #{stopped := Stopped} = State) ->
    {reply, Stopped, State};
handle_call({record, Basis}, _From, State) ->
    {reply, ok, State#{basis := {ok, Basis}}};
handle_call(recorded, _From, #{basis := Basis} = State) ->
    {reply, Basis, State};
handle_call({record_set, Set}, _From, State) ->
    {reply, ok, State#{set := Set}};
handle_call(recorded_set, _From, #{set := Set} = State) ->
    {reply, Set, State}.

handle_cast(_Request, State) ->
    {noreply, State}.
