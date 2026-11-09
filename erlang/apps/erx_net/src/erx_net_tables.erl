%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_tables).
-moduledoc """
The owner of the stack's shared tables (docs/design-network-stack.md, "What owners
publish"), so that a writer's crash loses no table. Every row has one writer, the owner of
the state it shows; this process writes only the configuration generation's start and the
deletion of a stopped writer's rows.

* `erx_net_ifs`, `{Name, Pid, Iface}`: one per interface, `Iface` an
  `erx_net_frame:iface()` with the interface's credits and its driver's;
* `erx_net_addrs`, `{{Pid, Addr}, Pid, Order, Row}` and `erx_net_routes`,
  `{{Pid, Prefix, Plen}, Pid, Row}`: the addresses and routes each interface publishes;
* `erx_net_neigh`, `{{Pid, Ip}, LinkAddr, fresh | stale, Hints}`: the neighbours an
  interface's transmitters may address, and how many transmitters hinted a stale one since
  the interface wrote it, so that one hint is in flight per row;
* `erx_net_gen`, `{gen, N}`: the configuration generation, which every writer of the first
  three tables increments after each change of its rows;
* `erx_net_demux`, `{Key, Pid, Entry}`: the demultiplexing table, inserted into only by
  erx_net_bind;
* `erx_net_drivers`, `{Name, Pid}`: each interface's driver, which registers itself there
  so that its interface, started after it by their link supervisor, finds it; a
  restarted driver's registration replaces its predecessor's, and nothing else reads it.

Rows end with their writer: every row names the pid of the incarnation that wrote it, and
when a registered interface stops, however it stops, this process deletes every row naming
that pid and moves the generation. It does the same for the demultiplexing entries of a
socket registered with `watch_holder/1`, which stands in for a socket's grant until the
grants exist.

Every reader of the configuration reads it through `configuration/0`: the generation first,
then the rows, so a reader that raced a writer finds a newer generation at its next read.
""".

-behaviour(gen_server).

-export([start_link/0, register_driver/2, driver/1, register_interface/1, watch_holder/1,
         generation/0, configuration/0, interface/1, neighbour/2, first_hint/2, demux/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(IFS, erx_net_ifs).
-define(ADDRS, erx_net_addrs).
-define(ROUTES, erx_net_routes).
-define(NEIGH, erx_net_neigh).
-define(GEN, erx_net_gen).
-define(DEMUX, erx_net_demux).
-define(DRIVERS, erx_net_drivers).

-doc "Starts the owner and creates the tables.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Records `Pid` as the driver of interface `Name`; called by the driver itself.".
-spec register_driver(term(), pid()) -> ok.
register_driver(Name, Pid) ->
    true = ets:insert(?DRIVERS, {Name, Pid}),
    ok.

-doc "The driver of interface `Name`.".
-spec driver(term()) -> {ok, pid()} | none.
driver(Name) ->
    case ets:lookup(?DRIVERS, Name) of
        [{_, Pid}] -> {ok, Pid};
        [] -> none
    end.

-doc "Monitors the calling interface process; its rows go when it stops.".
-spec register_interface(pid()) -> ok.
register_interface(Pid) ->
    gen_server:call(?MODULE, {watch, interface, Pid}, infinity).

-doc "Monitors a socket; its demultiplexing entries go when it stops.".
-spec watch_holder(pid()) -> ok.
watch_holder(Pid) ->
    gen_server:call(?MODULE, {watch, holder, Pid}, infinity).

-doc "The configuration generation.".
-spec generation() -> non_neg_integer().
generation() ->
    ets:lookup_element(?GEN, gen, 2).

-doc "The configuration generation and the snapshot of the rows read after it.".
-spec configuration() -> {non_neg_integer(), erx_net_frame:snapshot()}.
configuration() ->
    Gen = generation(),
    Ifs = [Iface || {_, _, Iface} <- ets:tab2list(?IFS)],
    Addrs = [{Pid, Order, Row} || {_, Pid, Order, Row} <- ets:tab2list(?ADDRS)],
    Routes = [{Pid, Row} || {_, Pid, Row} <- ets:tab2list(?ROUTES)],
    {Gen, erx_net_frame:snapshot(Ifs, Addrs, Routes)}.

-doc "The published row of interface `Name`.".
-spec interface(term()) -> {ok, erx_net_frame:iface()} | none.
interface(Name) ->
    case ets:lookup(?IFS, Name) of
        [{_, _, Iface}] -> {ok, Iface};
        [] -> none
    end.

-doc "The neighbour row interface `Pid` published for `Ip`.".
-spec neighbour(pid(), binary()) -> none | {binary(), fresh | stale}.
neighbour(Pid, Ip) ->
    case ets:lookup(?NEIGH, {Pid, Ip}) of
        [{_, LinkAddr, Freshness, _Hints}] -> {LinkAddr, Freshness};
        [] -> none
    end.

-doc """
Counts a transmitter's hint of the stale neighbour row of `Ip` on interface `Pid`, and
answers whether it is the first since the interface wrote the row, the one to send.
""".
-spec first_hint(pid(), binary()) -> boolean().
first_hint(Pid, Ip) ->
    try ets:update_counter(?NEIGH, {Pid, Ip}, {4, 1}) =:= 1
    catch
        error:badarg -> false     % the interface withdrew the row: nothing to hint
    end.

-doc "The entries that hold `Key` in the demultiplexing table, none or one.".
-spec demux(erx_net_input:key()) -> [erx_net_input:entry()].
demux(Key) ->
    [Entry || {_, _, Entry} <- ets:lookup(?DEMUX, Key)].

%% --- gen_server ------------------------------------------------------------------

-doc false.
init([]) ->
    [ets:new(Name, [named_table, public, set, {read_concurrency, true}])
     || Name <- [?IFS, ?ADDRS, ?ROUTES, ?NEIGH, ?GEN, ?DEMUX, ?DRIVERS]],
    true = ets:insert(?GEN, {gen, 0}),
    {ok, #{}}.

-doc false.
handle_call({watch, Kind, Pid}, _From, Watched) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok, Watched#{Ref => {Kind, Pid}}}.

-doc false.
handle_cast(_Msg, Watched) ->
    {noreply, Watched}.

-doc false.
handle_info({'DOWN', Ref, process, _, _}, Watched) ->
    case maps:take(Ref, Watched) of
        {{interface, Pid}, Rest} ->
            ets:match_delete(?IFS, {'_', Pid, '_'}),
            ets:match_delete(?ADDRS, {'_', Pid, '_', '_'}),
            ets:match_delete(?ROUTES, {'_', Pid, '_'}),
            ets:match_delete(?NEIGH, {{Pid, '_'}, '_', '_', '_'}),
            _ = ets:update_counter(?GEN, gen, 1),
            {noreply, Rest};
        {{holder, Pid}, Rest} ->
            ets:match_delete(?DEMUX, {'_', Pid, '_'}),
            {noreply, Rest};
        error ->
            {noreply, Watched}
    end;
handle_info(_Msg, Watched) ->
    {noreply, Watched}.
