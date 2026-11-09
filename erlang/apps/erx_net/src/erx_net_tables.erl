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
  restarted driver's registration replaces its predecessor's, and nothing else reads it;
* `erx_net_secrets`, `{tcp, Isn}`: the stack's TCP secrets, drawn at start, held in a
  closure that gives a four-tuple's initial sequence number and timestamp offset
  (erx_tcp_isn), so no crash report prints the keys; only this process writes it, and
  only erx_net_bind's claim reads it.

Each process registered with watch_resolver/1, a grant, gets `{erx_net_tables, resolver}`
when the interfaces' name servers or search list may have moved: after an interface
applied or dropped a lease (resolver_moved/0) and after an interface stopped. It then
reads them again through erx_net:interfaces/0.

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
         generation/0, configuration/0, interfaces/0, interface/1, neighbour/2, first_hint/2, demux/1,
         tcp_isn/0, watch_resolver/1, resolver_moved/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(IFS, erx_net_ifs).
-define(ADDRS, erx_net_addrs).
-define(ROUTES, erx_net_routes).
-define(NEIGH, erx_net_neigh).
-define(GEN, erx_net_gen).
-define(DEMUX, erx_net_demux).
-define(DRIVERS, erx_net_drivers).
-define(SECRETS, erx_net_secrets).

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

-doc "Each published interface's name and the pid of the incarnation that wrote its row.".
-spec interfaces() -> [{term(), pid()}].
interfaces() ->
    [{Name, Pid} || {Name, Pid, _} <- ets:tab2list(?IFS)].

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

-doc """
The closure that gives a four-tuple's initial sequence number and timestamp offset at a
time in microseconds, under the stack's secrets; erx_net_bind's claim calls it.
""".
-spec tcp_isn() -> fun((erx_tcp_isn:four_tuple(), integer()) ->
                          {erx_tcp_seq:wire(), erx_tcp_seq:wire()}).
tcp_isn() ->
    ets:lookup_element(?SECRETS, tcp, 2).

-doc "Monitors `Pid`, which gets `{erx_net_tables, resolver}` whenever the name servers may have moved.".
-spec watch_resolver(pid()) -> ok.
watch_resolver(Pid) ->
    gen_server:call(?MODULE, {watch, resolver, Pid}, infinity).

-doc "Called by an interface after it applied or dropped a lease.".
-spec resolver_moved() -> ok.
resolver_moved() ->
    gen_server:cast(?MODULE, resolver_moved).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init([]) ->
    [ets:new(Name, [named_table, public, set, {read_concurrency, true}])
     || Name <- [?IFS, ?ADDRS, ?ROUTES, ?NEIGH, ?GEN, ?DEMUX, ?DRIVERS]],
    true = ets:insert(?GEN, {gen, 0}),
    _ = ets:new(?SECRETS, [named_table, protected, set, {read_concurrency, true}]),
    Secrets = erx_tcp_isn:secrets(erx_net_clock:entropy(16), erx_net_clock:entropy(16)),
    true = ets:insert(?SECRETS, {tcp, fun(FourTuple, Now) ->
                                              {erx_tcp_isn:isn(Secrets, FourTuple, Now),
                                               erx_tcp_isn:ts_offset(Secrets, FourTuple)}
                                      end}),
    {ok, #{}}.

-doc false.
handle_call({watch, Kind, Pid}, _From, Watched) ->
    Ref = erlang:monitor(process, Pid),
    {reply, ok, Watched#{Ref => {Kind, Pid}}}.

-doc false.
handle_cast(resolver_moved, Watched) ->
    ok = notify_resolver(Watched),
    {noreply, Watched};
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
            ok = notify_resolver(Rest),
            {noreply, Rest};
        {{resolver, _Pid}, Rest} ->
            {noreply, Rest};
        {{holder, Pid}, Rest} ->
            ets:match_delete(?DEMUX, {'_', Pid, '_'}),
            {noreply, Rest};
        error ->
            {noreply, Watched}
    end;
handle_info(_Msg, Watched) ->
    {noreply, Watched}.

notify_resolver(Watched) ->
    _ = [Pid ! {erx_net_tables, resolver} || {resolver, Pid} <- maps:values(Watched)],
    ok.
