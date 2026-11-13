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
* The text of rc.conf the table was last made from, so a restarted table
  has the table it had while rc.conf is unread.

Only the table writes the records, from its own process, and each write
replaces what it changes in one step, so a table that ends at any point
finds either the record before the write or the record after it.
""".
-behaviour(gen_server).

-export([start_link/0, mark/1, unmark/1, stopped/0, record/1, recorded/0]).
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

-doc "Records Text as the text of rc.conf the table is made from.".
-spec record(binary()) -> ok.
record(Text) ->
    gen_server:call(?MODULE, {record, Text}).

-doc "The text record/1 last recorded, or none.".
-spec recorded() -> {ok, binary()} | none.
recorded() ->
    gen_server:call(?MODULE, recorded).

%% The state: the stopped marks, an ordset of names, and the recorded text.
init([]) ->
    {ok, #{stopped => ordsets:new(), text => none}}.

handle_call({mark, Name}, _From, #{stopped := Stopped} = State) ->
    {reply, ok, State#{stopped := ordsets:add_element(Name, Stopped)}};
handle_call({unmark, Name}, _From, #{stopped := Stopped} = State) ->
    {reply, ok, State#{stopped := ordsets:del_element(Name, Stopped)}};
handle_call(stopped, _From, #{stopped := Stopped} = State) ->
    {reply, Stopped, State};
handle_call({record, Text}, _From, State) ->
    {reply, ok, State#{text := {ok, Text}}};
handle_call(recorded, _From, #{text := Text} = State) ->
    {reply, Text, State}.

handle_cast(_Request, State) ->
    {noreply, State}.
