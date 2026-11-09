%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_if).
-moduledoc """
The interface process (docs/design-network-stack.md, "The interface core", "The loop"):
the effect layer around erx_net_if_core. It takes one message at a time, steps the core
and performs the actions in order; it decides nothing a pure function could decide.

1. Before anything else it reads the configuration generation, and when it differs from
   the core's steps `{config, Gen, Snapshot}` from `erx_net_tables:configuration/0`.
2. A batch `{frames, Driver, Frames}` takes its units from the receive credit. Each frame
   in turn is classified against the core's view with the demultiplexing lookup added. An
   `owned` frame reserves a unit of each holder's credit and is verified; its item is kept
   for each holder that took it, or the units are released when it fails. A `local` frame
   is stepped at once; a step that raises is counted as `raised` and the core keeps its
   value from before the frame, so a frame that trips a bug costs only itself. A `drop` is
   counted. At the batch's end each holder gets one
   message `{items, Interface, Items}`, its units already reserved.
3. A link notice takes its unit of the receive credit, a `{resolve, ...}` hand-over one of
   the sender credit; a hint, the DHCP client's messages and the clock's hint carry none.

The process writes its rows of `erx_net_ifs`, `erx_net_addrs`, `erx_net_routes` and
`erx_net_neigh`, new and changed rows first and deleted rows last, then increments the
generation. Its own row adds what only it knows to the core's: its pid, its receive and
sender credits (`rx_credit`, `credit`) and its driver's pid and transmit credit (`driver`,
`driver_credit`).

Messages:

* from the driver: `{frames, Driver, [binary()]}`, `{link, Driver, up | down}`;
* from senders: `{resolve, NextHop, Src, Packets}`, a connection's `{reset, NextHop, Src,
  Packets}` and `charge_rst`, each against `credit`, and `{hint, NextHop}`;
* from its erx_dhcp4: `{dhcp_attach, Pid}` once, then `{dhcp, Pid, erx_dhcp4_core:action()}`;
  to it, `{erx_net_if, {reply, Msg} | {link, up | down}}`;
* `admin/2`, a call, for netadmin's requests (`counters`, `lease`, `status`).
""".

-behaviour(gen_server).

-export([start_link/2, admin/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(RX_LIMIT, 256).
-define(SENDER_LIMIT, 256).

-record(state, {name :: term(),
                core :: erx_net_if_core:core(),
                gen = none :: none | non_neg_integer(),   % the core's configuration generation
                driver :: pid(),
                rx :: erx_net_credit:credit(),
                sender :: erx_net_credit:credit(),
                tx :: erx_net_credit:credit(),
                dhcp = none :: none | {pid(), reference()},
                armed = infinity :: erx_net_clock:armed()}).

-doc """
Starts the interface `Name` with its configuration (`erx_net_if_core:config()`), over the
driver its link supervisor started before it.
""".
-spec start_link(term(), erx_net_if_core:config()) -> {ok, pid()} | {error, term()}.
start_link(Name, Config) ->
    gen_server:start_link(?MODULE, {Name, Config}, []).

-doc "Asks the interface an administrative question: `counters`, `lease` or `status`.".
-spec admin(pid(), term()) -> term().
admin(If, Request) ->
    gen_server:call(If, {admin, Request}, infinity).

%% --- gen_server ------------------------------------------------------------------

-doc false.
init({Name, Config}) ->
    ok = erx_net_tables:register_interface(self()),
    {ok, Driver} = erx_net_tables:driver(Name),
    Rx = erx_net_credit:new(?RX_LIMIT),
    {ok, Link, Tx} = erx_net_driver:attach(Driver, Rx),
    Gen = erx_net_rand:new(erx_net_clock:entropy(16)),
    Core = erx_net_if_core:new(#{name => Name, link => Link, gen => Gen, config => Config}),
    S = #state{name = Name, core = Core, driver = Driver, rx = Rx,
               sender = erx_net_credit:new(?SENDER_LIMIT), tx = Tx},
    {ok, finish(step(start, S))}.

-doc false.
handle_call({admin, Request}, From, S) ->
    {noreply, finish(step({admin, Request, From}, sync(S)))}.

-doc false.
handle_cast(_Msg, S) ->
    {noreply, S}.

-doc false.
handle_info(Msg, S) ->
    {noreply, finish(message(Msg, sync(S)))}.

%% --- One message -----------------------------------------------------------------

message({frames, Driver, Frames}, #state{driver = Driver, rx = Rx} = S) ->
    ok = erx_net_credit:take(Rx, length(Frames)),
    frames(Frames, S);
message({link, Driver, State}, #state{driver = Driver, rx = Rx} = S) ->
    ok = erx_net_credit:take(Rx, 1),
    step({link, State}, S);
message({Kind, _NextHop, _Src, _Packets} = Event, #state{sender = Sender} = S)
  when Kind =:= resolve; Kind =:= reset ->
    ok = erx_net_credit:take(Sender, 1),
    step(Event, S);
message(charge_rst, #state{sender = Sender} = S) ->
    ok = erx_net_credit:take(Sender, 1),
    step(charge_rst, S);
message({hint, _NextHop} = Event, S) ->
    step(Event, S);
message({dhcp_attach, Pid}, #state{dhcp = Old} = S) when is_pid(Pid) ->
    _ = [erlang:demonitor(Ref, [flush]) || {_, Ref} <- [Old]],
    S#state{dhcp = {Pid, erlang:monitor(process, Pid)}};
message({dhcp, Pid, Action}, #state{dhcp = {Pid, _}} = S) ->
    step({dhcp, Action}, S);
message({'DOWN', Ref, process, _, _}, #state{dhcp = {_, Ref}} = S) ->
    S#state{dhcp = none};
message({erx_net_clock, hint}, S) ->
    step({expired, erx_net_clock:now()}, S#state{armed = infinity});
message(_Msg, S) ->
    S.

%% The configuration first: a newer generation is stepped before anything else.
sync(#state{gen = Gen} = S) ->
    case erx_net_tables:generation() of
        Gen ->
            S;
        _ ->
            {NewGen, Snapshot} = erx_net_tables:configuration(),
            step({config, NewGen, Snapshot}, S#state{gen = NewGen})
    end.

%% Arms the clock at the core's next deadline.
finish(#state{core = Core, armed = Armed} = S) ->
    S#state{armed = erx_net_clock:arm_by(erx_net_if_core:next_deadline(Core), Armed)}.

%% --- A batch of frames -----------------------------------------------------------

frames(Frames, S0) ->
    {S, Batches} = lists:foldl(fun(Frame, {S1, B}) -> input({frame, Frame}, S1, B) end,
                               {S0, #{}}, Frames),
    maps:foreach(fun(Pid, Items) ->
                         ok = erx_net_credit:send(Pid, {items, self(), lists:reverse(Items)})
                 end, Batches),
    S.

input(Input, #state{core = Core} = S, Batches) ->
    View = (erx_net_if_core:view(Core))#{demux => fun erx_net_tables:demux/1},
    case erx_net_input:classify(Input, View) of
        {owned, Holders, Pending} ->
            owned(Holders, Pending, S, Batches);
        {local, Pending} ->
            {guarded({local, Pending}, S), Batches};
        {drop, Reason} ->
            {step({drop, Reason}, S), Batches}
    end.

%% An owned frame is verified only once some holder has room for it: each holder whose
%% credit takes a unit is kept.
owned(Holders, Pending, S, Batches) ->
    case lists:filter(fun({_Pid, Credit}) -> erx_net_credit:reserve(Credit, 1) =:= ok end, Holders) of
        [] ->
            {step({drop, no_room}, S), Batches};
        Taken ->
            case erx_net_input:verify(Pending) of
                {ok, Item} ->
                    {S, lists:foldl(fun({Pid, _}, B) ->
                                            maps:update_with(Pid, fun(Is) -> [Item | Is] end,
                                                             [Item], B)
                                    end, Batches, Taken)};
                {drop, Reason} ->
                    [ok = erx_net_credit:release(Credit, 1) || {_, Credit} <- Taken],
                    {step({drop, Reason}, S), Batches}
            end
    end.

%% --- Steps and their actions -----------------------------------------------------

%% A frame's step: one that raises leaves the state as it was and is counted, never logged,
%% since the frame's bytes would reach the log unescaped.
guarded(Event, S) ->
    try
        step(Event, S)
    catch
        error:_ -> step({drop, raised}, S)
    end.

step(Event, #state{core = Core0} = S) ->
    {Core, Actions} = erx_net_if_core:step(Event, Core0, #{now => erx_net_clock:now()}),
    lists:foldl(fun perform/2, S#state{core = Core}, Actions).

perform({transmit, Frames}, #state{driver = Driver, tx = Tx} = S) ->
    case erx_net_credit:hand(Driver, Tx, length(Frames), {transmit, Frames}) of
        ok -> S;
        full -> step({drop, tx_full}, S)
    end;
perform({publish, Rows}, S) ->
    publish(Rows, S);
perform({neigh, publish, Ip, LinkAddr, Freshness}, S) ->
    true = ets:insert(erx_net_neigh, {{self(), Ip}, LinkAddr, Freshness, 0}),
    S;
perform({neigh, unpublish, Ip}, S) ->
    true = ets:delete(erx_net_neigh, {self(), Ip}),
    S;
perform({dhcp, Msg}, #state{dhcp = {Pid, _}} = S) ->
    Pid ! {erx_net_if, Msg},
    S;
perform({dhcp, _Msg}, #state{dhcp = none} = S) ->
    S;
perform({reply, From, Reply}, S) ->
    gen_server:reply(From, Reply),
    S.

%% The interface's complete rows: new and changed ones written first, those it no longer
%% has deleted last, and then the generation moved.
publish(#{iface := Iface, addrs := Addrs, routes := Routes},
        #state{name = Name, driver = Driver, rx = Rx, sender = Sender, tx = Tx} = S) ->
    Me = self(),
    Row = Iface#{pid => Me, driver => Driver, driver_credit => Tx, rx_credit => Rx,
                 credit => Sender},
    true = ets:insert(erx_net_ifs, {Name, Me, Row}),
    NewAddrs = [{{Me, A}, Me, Order, R} || {Order, #{addr := A} = R} <- Addrs],
    NewRoutes = [{{Me, P, L}, Me, R} || #{prefix := P, plen := L} = R <- Routes],
    true = ets:insert(erx_net_addrs, NewAddrs),
    true = ets:insert(erx_net_routes, NewRoutes),
    delete_others(erx_net_addrs, ets:match(erx_net_addrs, {'$1', Me, '_', '_'}), NewAddrs),
    delete_others(erx_net_routes, ets:match(erx_net_routes, {'$1', Me, '_'}), NewRoutes),
    _ = ets:update_counter(erx_net_gen, gen, 1),
    S.

delete_others(Table, Present, Kept) ->
    Keep = sets:from_list([element(1, Row) || Row <- Kept], [{version, 2}]),
    [true = ets:delete(Table, Key) || [Key] <- Present, not sets:is_element(Key, Keep)],
    ok.
