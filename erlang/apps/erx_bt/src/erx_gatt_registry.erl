%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_registry).
-moduledoc """
The registry's pure core (docs/design-bluetooth.md, "One owner, one step", "The `ble`
facet" and "The link's messages"): the table, the values the handlers last set, each
service's handler, the live links with their `Conn`, and the writes handed to handlers.
`erx_gatt_srv` is its process: it steps each input and performs the actions in order.

- **Links.** A link joins at its start with its `Conn` and its phone's address; the core
  answers the table and the values, asks for a monitor of the link and tells every handler
  `connected` at level `open`, not bonded. Joins and sets are inputs of one core, so every
  set after the values a join answered goes to that link. At the link's end, its monitor's
  `down`, every handler hears `disconnected`, and its `Conn` is gone.
- **Handlers.** A facet's operation carries its caller, the grantee's process. The `ble`
  facet (`erx_ble_facet`) has refused every service its grant does not name, and a grant
  names only declared services, which are the ones the registry serves, so the core checks
  no service: an operation names a served one.
  `attach` makes the caller a service's handler; the core asks for a monitor of a handler
  it does not yet watch, and a handler's `down` detaches it from every service. A handler
  that attaches hears `connected` for each live link, so it knows every `Conn` it may
  notify. A bonded link's `connected` carries the bond's identity only to a handler whose
  attach said its grant asks for it, which the facet alone states.
- **Writes.** A link's write goes to its service's handler under `Req`, a reference the
  process made for it, which the core maps back to the handler, the link and the link's
  own `Ref`; an answer is taken only from that handler, once, and goes to the link. A
  service with no handler answers the write Unlikely Error at once. An answer for a `Req`
  the core does not hold, another handler's, one already answered or one whose link
  ended, changes nothing.
- **Notifications.** A notification or indication of a served service's characteristic,
  within its maximum, becomes a request to the link, which the process sends with
  `gen_server:send_request/4` and answers the caller from; the link's gate and bearer
  decide the rest (access, subscription, MTU, queue). A `Conn` the core does not hold
  answers `{error, gone}` at once.
""".

-export([new/2, step/2]).
-export_type([core/0, input/0, action/0, limits/0, security/0]).

-type key() :: erx_gatt_db:key().
-type level() :: erx_gatt_gate:level().
-type from() :: gen_server:from().
-doc """
A link's security as it reports it: the level it reaches and whether it is bonded, with
the bond's identity address exactly when it is.
""".
-type security() :: #{level := level(), bonded := false}
                  | #{level := level(), bonded := true, identity := erx_smp_crypto:address()}.
-doc "What a handler learns of a characteristic at `attach`: its maximum and its accesses.".
-type limits() :: #{max := 0..512, access := #{erx_gatt_db:access() => level()}}.

-doc "A live link: its `Conn`, its phone's address and the security it last reported.".
-type link() :: #{conn := reference(), address := erx_smp_crypto:address(), security := security()}.

-record(core, {
    table :: erx_gatt_db:table(),
    limits :: #{atom() => #{atom() => limits()}},
    values = #{} :: #{key() => binary()},
    handlers = #{} :: #{atom() => pid()},
    hearing = [] :: [pid()],  % the handlers whose grant asks for a bonded link's identity
    links = #{} :: #{pid() => link()},
    conns = #{} :: #{reference() => pid()},
    writes = #{} :: #{reference() => {Handler :: pid(), Link :: pid(), Ref :: pos_integer()}}
}).
-opaque core() :: #core{}.

-type op() :: {attach, atom(), Identity :: boolean()} | {set, atom(), atom(), binary()}
            | {notify | indicate, reference(), atom(), atom(), binary()} | {reply, reference(), term()}.
-doc """
What the process steps: a link's `join` call and its messages, a write with the fresh
`Req` the process made for it, a facet's operation with its caller, and the
`down` of a monitored process.
""".
-type input() :: {join, Link :: pid(), reference(), #{address := erx_smp_crypto:address()}, from()}
               | {write, Link :: pid(), Ref :: pos_integer(), key(), binary(), Req :: reference()}
               | {link, Link :: pid(), {subscribed, key(), none | notify | indicate} | {mtu, pos_integer()}
                                       | {security, security()}}
               | {facet, Caller :: pid(), op(), from()}
               | {down, pid()}.
-doc """
What the process performs: a call's answer, a monitor, an event to a handler, a message to
a link (`{answer, Ref, Answer}` or `{set, Key, Value}`), and a notification request to a
link whose answer goes to `From`.
""".
-type action() :: {reply, from(), term()} | {monitor, pid()} | {event, pid(), tuple()}
                | {to_link, pid(), {answer, pos_integer(), term()} | {set, key(), binary()}}
                | {request, pid(), {notify, notify | indicate, key(), binary()}, from()}.

-doc """
The core of the served `Services`, as `erx_gatt_decl` declares them, in any order, with
GAP's values `Gap`.
""".
-spec new(erx_gatt_db:gap(), [erx_gatt_db:service()]) -> core().
new(Gap, Services) ->
    Limits = #{Name => #{Char => maps:with([max, access], C) || #{name := Char} = C <- Chars}
               || #{name := Name, characteristics := Chars} <- Services},
    #core{table = erx_gatt_db:build(Gap, Services), limits = Limits}.

-doc "Steps one input: the actions to perform, in order, and the next core.".
-spec step(input(), core()) -> {[action()], core()}.
step({join, Link, Conn, #{address := Address}, From}, #core{links = Links, conns = Conns} = Core)
  when not is_map_key(Link, Links), not is_map_key(Conn, Conns) ->
    Security = #{level => open, bonded => false},
    Joined = Core#core{links = Links#{Link => #{conn => Conn, address => Address, security => Security}},
                       conns = Conns#{Conn => Link}},
    {[{monitor, Link},
      {reply, From, #{table => Core#core.table, values => Core#core.values}}
      | connected_events(Conn, Address, Security, Core)],
     Joined};
%% A link sends its next write only once it has the last one's answer or gave up waiting,
%% so a new write drops the link's earlier one: the core holds at most one write a link.
step({write, Link, Ref, {Service, Char}, Value, Req}, #core{links = Links} = Core) ->
    Writes = without_link(Link, Core#core.writes),
    case {Links, Core#core.handlers} of
        {#{Link := #{conn := Conn}}, #{Service := Handler}} ->
            {[{event, Handler, {write, Req, Conn, Char, Value}}],
             Core#core{writes = Writes#{Req => {Handler, Link, Ref}}}};
        {#{Link := _}, _} ->
            {[{to_link, Link, {answer, Ref, {error, unlikely_error}}}], Core#core{writes = Writes}};
        _ ->
            {[], Core}
    end;
step({link, Link, Message}, #core{links = Links} = Core) ->
    case Links of
        #{Link := Joined} -> link(Link, Joined, Message, Core);
        #{} -> {[], Core}
    end;
step({facet, Caller, Op, From}, Core) ->
    try facet(Op, Caller, From, Core)
    catch throw:{refused, Reason} -> {[{reply, From, {error, Reason}}], Core}
    end;
step({down, Pid}, Core) ->
    down(Pid, Core).

%% ---- a link's messages ----

link(_Link, #{conn := Conn}, {subscribed, {Service, Char}, Kind}, Core) ->
    {to_handler(Service, {subscribed, Conn, Char, Kind}, Core), Core};
link(_Link, #{conn := Conn}, {mtu, Mtu}, Core) ->
    {to_handlers({mtu, Conn, Mtu}, Core), Core};
link(Link, #{conn := Conn, address := Address} = Joined, {security, Security}, Core) ->
    {connected_events(Conn, Address, Security, Core),
     Core#core{links = (Core#core.links)#{Link := Joined#{security := Security}}}}.

%% ---- a facet's operations ----

%% A refusal is thrown as {refused, Reason} and answered once, in step/2.
facet({attach, Service, Identity}, Caller, From, #core{handlers = Handlers} = Core) when is_boolean(Identity) ->
    is_map_key(Service, Handlers) andalso throw({refused, attached}),
    New = not lists:member(Caller, maps:values(Handlers)),
    Next = Core#core{handlers = Handlers#{Service => Caller}, hearing = hearing(Identity, Caller, Core#core.hearing)},
    Connected = [{event, Caller, {connected, Conn, connected(Caller, Address, Security, Next)}}
                 || New, _Link := #{conn := Conn, address := Address, security := Security}
                                 <- maps:iterator(Core#core.links, ordered)],
    {[{monitor, Caller} || New] ++ [{reply, From, {ok, maps:get(Service, Core#core.limits)}} | Connected], Next};
facet({set, Service, Char, Value}, Caller, From, Core) when is_binary(Value) ->
    owned(Service, Caller, Core),
    within(Service, Char, Value, Core),
    Key = {Service, Char},
    {[{reply, From, ok} | [{to_link, Link, {set, Key, Value}} || Link := _ <- maps:iterator(Core#core.links, ordered)]],
     Core#core{values = (Core#core.values)#{Key => Value}}};
facet({Kind, Conn, Service, Char, Value}, Caller, From, Core)
  when (Kind =:= notify orelse Kind =:= indicate), is_binary(Value) ->
    owned(Service, Caller, Core),
    within(Service, Char, Value, Core),
    case Core#core.conns of
        #{Conn := Link} -> {[{request, Link, {notify, Kind, {Service, Char}, Value}, From}], Core};
        #{} -> throw({refused, gone})
    end;
facet({reply, Req, Answer}, Caller, From, #core{writes = Writes} = Core) ->
    case Writes of
        #{Req := {Caller, Link, Ref}} ->
            {[{reply, From, ok}, {to_link, Link, {answer, Ref, Answer}}],
             Core#core{writes = maps:remove(Req, Writes)}};
        #{} ->
            {[{reply, From, ok}], Core}
    end;
facet(_Op, _Caller, _From, _Core) ->
    throw({refused, badarg}).

%% Caller is Service's handler: only a service's owner changes its values or sends them to
%% a phone (docs/design-bluetooth.md, "A service belongs to its handler").
owned(Service, Caller, #core{handlers = Handlers}) ->
    case Handlers of
        #{Service := Caller} -> ok;
        #{} -> throw({refused, not_attached})
    end.

%% A value for Service's Char: the declaration names the characteristic, and the value
%% fits its maximum.
within(Service, Char, Value, #core{limits = Limits}) ->
    case Limits of
        #{Service := #{Char := #{max := Max}}} when byte_size(Value) =< Max -> ok;
        #{Service := #{Char := _}} -> throw({refused, too_long});
        #{} -> throw({refused, no_such_characteristic})
    end.

%% ---- a monitored process's end ----

%% A link's end: every handler hears it, its Conn is gone and the writes it awaits are
%% dropped. A handler's end detaches it from every service, and the writes it held are
%% dropped, for the link's deadline to answer.
down(Pid, #core{links = Links, conns = Conns, writes = Writes} = Core) ->
    case Links of
        #{Pid := #{conn := Conn}} ->
            {to_handlers({disconnected, Conn}, Core),
             Core#core{links = maps:remove(Pid, Links), conns = maps:remove(Conn, Conns),
                       writes = without_link(Pid, Writes)}};
        #{} ->
            {[], Core#core{handlers = #{S => H || S := H <- Core#core.handlers, H =/= Pid},
                           hearing = lists:delete(Pid, Core#core.hearing),
                           writes = #{Req => W || Req := {Handler, _, _} = W <- Writes, Handler =/= Pid}}}
    end.

%% The writes without those of the link Link.
without_link(Link, Writes) ->
    #{Req => W || Req := {_, L, _} = W <- Writes, L =/= Link}.

%% ---- events ----

%% Every attached handler's `connected` event of link Conn, once each.
connected_events(Conn, Address, Security, #core{handlers = Handlers} = Core) ->
    [{event, Handler, {connected, Conn, connected(Handler, Address, Security, Core)}}
     || Handler <- lists:usort(maps:values(Handlers))].

%% A `connected` event's facts for Handler: the address the phone connected from and the
%% link's security as it last reported it, a security() whose shape this match checks
%% whole: its level and whether it is bonded, with the bond's identity when it is and
%% Handler's grant asks for it.
connected(_Handler, Address, #{level := _, bonded := false} = Security, _Core) when map_size(Security) =:= 2 ->
    Security#{address => Address};
connected(Handler, Address, #{level := _, bonded := true, identity := _} = Security, #core{hearing = Hearing})
  when map_size(Security) =:= 3 ->
    case lists:member(Handler, Hearing) of
        true -> Security#{address => Address};
        false -> (maps:remove(identity, Security))#{address => Address}
    end.

%% The handlers that hear a bonded link's identity, with Caller among them when its
%% attach asks for it.
hearing(true, Caller, Hearing) -> lists:usort([Caller | Hearing]);
hearing(false, _Caller, Hearing) -> Hearing.

to_handler(Service, Event, #core{handlers = Handlers}) ->
    case Handlers of
        #{Service := Handler} -> [{event, Handler, Event}];
        #{} -> []
    end.

%% Every attached handler hears Event once, however many services it handles.
to_handlers(Event, #core{handlers = Handlers}) ->
    [{event, Handler, Event} || Handler <- lists:usort(maps:values(Handlers))].
