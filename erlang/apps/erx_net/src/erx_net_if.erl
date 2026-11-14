%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_if).
-moduledoc """
The interface process (docs/design-network-stack.md, "The interface core", "The loop"):
the effect layer around erx_net_if_core. It takes one message at a time, except that a
batch of frames takes every further batch already queued with it; it steps the core and
performs the actions in order, and decides nothing a pure function could decide.

1. Before anything else it reads the configuration generation, and when it differs from
   the core's steps `{config, Gen, Snapshot}` from `erx_net_tables:configuration/0`.
2. A batch `{frames, Driver, Frames}` is taken with every further batch from the driver
   already in the mailbox, up to a link notice, which is stepped after them
   (docs/design-network-fastpath.md, "Processes and batching"). On an Ethernet interface
   each batch is merged (erx_bytes:tcp_merge/1), and each frame or unit of the merge in
   turn is classified against the core's view with the demultiplexing lookup added. An
   `owned` frame reserves a unit of each holder's credit, a unit of the merge N of them,
   and is verified; its item is kept
   for each holder that took it, or the units are released when it fails. A `local` frame
   is stepped at once; a step that raises is counted as `raised` and the core keeps its
   value from before the frame, so a frame that trips a bug costs only itself. A `drop` is
   counted. At the pass's end each holder gets one message `{items, Interface, Items}`,
   its units already reserved, and only then are the batches' units taken from the receive
   credit, so the driver hands nothing past the credit's room while the pass runs and a
   pass never exceeds the credit's limit.
3. A link notice takes its unit of the receive credit, a `{resolve, ...}` hand-over one of
   the sender credit; a hint, the DHCP client's messages and the clock's hint carry none.

The process writes its rows of `erx_net_ifs`, `erx_net_addrs`, `erx_net_routes` and
`erx_net_neigh`, new and changed rows first and deleted rows last, then increments the
generation. Its own row adds what only it knows to the core's: its pid, its receive and
sender credits (`rx_credit`, `credit`) and its driver's pid and transmit credit (`driver`,
`driver_credit`).

Messages:

* from the driver: `{frames, Driver, [erx_net_driver:rx_frame()]}`, `{link, Driver, up | down}`;
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
                armed = infinity :: erx_net_clock:armed(),
                link :: ethernet | none}).                % the driver's link, which decides the merge

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
    S = #state{name = Name, core = Core, driver = Driver, rx = Rx, link = maps:get(link, Link),
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

message({frames, Driver, Frames}, #state{driver = Driver} = S) ->
    queued_frames([Frames], S);
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
    Next = step({dhcp, Action}, S),
    ok = lease_moved(Action),
    Next;
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

%% --- Batches of frames -----------------------------------------------------------

%% Takes every further batch the driver has already queued, after those taken so far
%% (`Taken`, newest first), and classifies them all in one pass. A link notice from the
%% driver ends the drain and is stepped after the frames that came before it, so the
%% driver's order holds. No unit is taken back while the drain runs, so the driver hands
%% nothing past the receive credit's room and the drain ends within the credit's limit.
queued_frames(Taken, #state{driver = Driver} = S) ->
    receive
        {frames, Driver, Frames} ->
            queued_frames([Frames | Taken], S);
        {link, Driver, _} = Link ->
            message(Link, frames(lists:reverse(Taken), S))
    after 0 ->
        frames(lists:reverse(Taken), S)
    end.

%% Merges each batch and classifies its units in the order the driver handed them, the
%% batches kept apart, hands each holder its items of all of them in one message, and then
%% takes the batches' units from the receive credit, one for each frame the driver handed.
frames(Batches, #state{rx = Rx, link = Link} = S0) ->
    {S, ByHolder} = lists:foldl(fun(Frames, Acc) -> batch(Link, Frames, Acc) end, {S0, #{}}, Batches),
    maps:foreach(fun(Pid, Items) ->
                         ok = erx_net_credit:send(Pid, {items, self(), lists:reverse(Items)})
                 end, ByHolder),
    ok = erx_net_credit:take(Rx, lists:sum([length(Frames) || Frames <- Batches])),
    S.

%% One batch: merged, its units counted, and each frame or unit classified in turn.
batch(Link, Frames, {S0, ByHolder0}) ->
    Units = merged(Link, Frames),
    lists:foldl(fun(Unit, {S, ByHolder}) -> input(frame_input(Unit), S, ByHolder) end,
                {count_units(Units, S0), ByHolder0}, Units).

%% An Ethernet interface merges each batch before it classifies anything
%% (docs/design-network-fastpath.md, "The merge, before classification"), in one call over
%% the batch, which the driver cut to the merge's limit. The merge answers every frame with
%% its network sum, alone or in a unit. A looped packet carries its zone, which no merge
%% reads, so the loopback interface's batches go on as they came. A batch the merge refuses,
%% which only a bug of the cut or the merge makes, goes on unmerged, each frame classified
%% alone, so the bug costs only the merge and strands no holder's units.
merged(ethernet, Frames) ->
    try
        erx_bytes:tcp_merge(Frames)
    catch
        error:_ -> Frames
    end;
merged(none, Frames) -> Frames.

%% A batch's units of the merge and the segments they hold, counted as the interface's
%% `units` and `unit_segments`, which the benchmarks read.
count_units(Units, S) ->
    case [N || {merged, N, _, _, _} <- Units] of
        [] -> S;
        Counts -> step({merged, length(Counts), lists:sum(Counts)}, S)
    end.

%% A frame or unit as the merge answered it, or a frame as its driver handed it, a looped
%% packet with its zone among them, as `classify/2` takes it. Any other shape goes on as it
%% is and raises in the guarded classification, so it costs only itself.
frame_input({sum, Sum, Bytes}) -> {frame, Bytes, Sum};
frame_input({merged, _, _, _, _} = Unit) -> Unit;
frame_input({Zone, Bytes}) -> {looped, Zone, Bytes};
frame_input(Bytes) -> {frame, Bytes, none}.

input(Input, #state{core = Core} = S, ByHolder) ->
    View = (erx_net_if_core:view(Core))#{demux => fun erx_net_tables:demux/1},
    case guarded_input(fun() -> erx_net_input:classify(Input, View) end) of
        {owned, Holders, Pending} ->
            owned(Holders, Pending, S, ByHolder);
        {local, Pending} ->
            {guarded({local, Pending}, S), ByHolder};
        {drop, Reason} ->
            {step({drop, Reason}, S), ByHolder}
    end.

%% Classifying or verifying a frame that raises drops the frame as `raised`, as a raising
%% step does, so a frame that trips a bug costs only itself and strands no holder's units.
guarded_input(Fun) ->
    try
        Fun()
    catch
        error:_ -> {drop, raised}
    end.

%% An owned frame is verified only once some holder has room for it: each holder whose
%% credit takes its units, one for a frame and N for a unit of the merge
%% (erx_net_input:units/1), is kept.
owned(Holders, Pending, S, ByHolder) ->
    Units = erx_net_input:units(Pending),
    case lists:filter(fun({_Pid, Credit}) -> erx_net_credit:reserve(Credit, Units) =:= ok end, Holders) of
        [] ->
            {step({drop, no_room}, S), ByHolder};
        Taken ->
            case guarded_input(fun() -> erx_net_input:verify(Pending) end) of
                {ok, Item} ->
                    {S, lists:foldl(fun({Pid, _}, B) ->
                                            maps:update_with(Pid, fun(Is) -> [Item | Is] end,
                                                             [Item], B)
                                    end, ByHolder, Taken)};
                {drop, Reason} ->
                    [ok = erx_net_credit:release(Credit, Units) || {_, Credit} <- Taken],
                    {step({drop, Reason}, S), ByHolder}
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
    {Core, Actions} = erx_net_if_core:step(Event, Core0, context(Event)),
    lists:foldl(fun perform/2, S#state{core = Core}, Actions).

%% The time, and for a segment to a listener the stack's secrets, read for that frame alone
%% (docs/design-network-stack.md, "Connection setup").
context({local, Pending}) ->
    case erx_net_input:for_listener(Pending) of
        true -> #{now => erx_net_clock:now(), secrets => erx_net_tables:syncache_secrets()};
        false -> #{now => erx_net_clock:now()}
    end;
context(_Event) ->
    #{now => erx_net_clock:now()}.

perform({transmit, Frames}, #state{driver = Driver, tx = Tx} = S) ->
    case erx_net_credit:hand(Driver, Tx, erx_net_frame:units(Frames), {transmit, Frames}) of
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
    S;
%% A completed handshake. Nothing starts an accepted connection, so every handshake
%% is refused as one whose listener has no accept credit left, with the RST of
%% tcp_sc_rst_sock_fail (TODO.md, "erx_tcp_listen").
perform({accept, _Entry, Conn, _Handshake, Segment, _Gen}, S) ->
    step({accept_refused, Conn, Segment}, S).

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

%% A lease applied or dropped may move the name servers the grants answer: a renewal that
%% changes nothing is told too, and each grant compares before it tells its subscriber.
lease_moved({configure, _Lease}) -> erx_net_tables:resolver_moved();
lease_moved(unconfigure) -> erx_net_tables:resolver_moved();
lease_moved(_Action) -> ok.
