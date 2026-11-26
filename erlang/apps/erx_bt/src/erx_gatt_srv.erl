%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_srv).
-moduledoc """
The registry (docs/design-bluetooth.md, "One owner, one step", "The `ble` facet" and "The
link's messages"): the process registered as `erx_gatt_srv`, the effects around
`erx_gatt_registry`. It sits before the controller group in `erx_bt_sup`, so it outlives
every link, and handlers stay attached across the group's restarts.

- **Inputs.** The controller process's `advertised/0` call; a link's `join/2`
  call; a link's messages, `{erx_bt_link, Link, Message}`,
  each a write for a handler, a subscription, a new MTU or the link's security; a facet's
  operation, `facet/3`; and the `'DOWN'` of a link or a handler it monitors. For each of a
  link's writes it makes the fresh reference `Req` the handler receives.
- **Actions.** Answers, monitors, events to handlers, `{registry, Message}` to a link,
  `{advertised, Input}` to the controller process when the services advertised change, and
  notification requests: `gen_server:send_request/4` to the link, labelled with the
  caller's `From`, so the link answers the request and the request's monitor answers for a
  link that ends first, with `{error, gone}` to the caller. Its collection of request ids
  holds one per notification pending. The controller process, `erx_bt_hci`, is reached by
  its registered name and missed while its group restarts, since a controller process asks
  advertised/0 at its start, registered before it asks.
- **Facets.** `facet/3` is the one entry of a `ble` facet's operations, with its caller
  and no grant: `erx_ble_facet`, the only path here from another domain, has checked the
  grant, and forwards the call with the grantee's process as the caller, so the forwarded
  call's `From` names the facet, and the caller is the handler.
""".
-behaviour(gen_server).

-export([start_link/2, advertised/0, join/2, facet/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(srv, {
    core :: erx_gatt_registry:core(),
    requests :: gen_server:request_id_collection()
}).

-doc "Starts the registry, registered as `erx_gatt_srv`, serving `Services` with GAP's values `Gap`.".
-spec start_link(erx_gatt_db:gap(), [erx_gatt_db:service()]) -> gen_server:start_ret().
start_link(Gap, Services) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Gap, Services}, []).

-doc """
What the controller process advertises (docs/design-bluetooth.md, "Advertising"):
erx_gatt_registry:advertised/1 of the registry's core, the UUIDs of the services that
say `advertise` and have a handler now, and GAP's name and appearance, so the
advertised name and GAP's are one.
""".
-spec advertised() -> erx_bt_adv:input().
advertised() ->
    gen_server:call(?MODULE, advertised).

-doc """
A link joins the registry at its start: the registry maps `Conn` to the calling link,
tells the handlers `connected` at level `open` with no bond, and answers the table and
the values the handlers last set. It takes `join` and `set` in one order, so every `set`
after the values it answered reaches the link.
""".
-spec join(reference(), #{address := erx_smp_crypto:address()}) ->
          #{table := erx_gatt_db:table(), values := #{erx_gatt_db:key() => binary()}}.
join(Conn, Info) ->
    gen_server:call(?MODULE, {join, Conn, Info}).

-doc """
A `ble` facet's operation `Op` for `Caller`, the process that becomes a service's
handler, hears its events and alone answers the writes handed to it:
`{attach, Service}`, `{set, Service, Char, Value}`, `{notify | indicate, Conn, Service,
Char, Value}` or `{reply, Req, Answer}`. The answers and refusals are the facet's
(docs/design-bluetooth.md, "Refusals and error results"). An indication answers once the
phone confirms it or the link's 30 s transaction timeout fails it, so `Timeout` must
outlast that.
""".
-spec facet(pid(), term(), timeout()) -> term().
facet(Caller, Op, Timeout) ->
    gen_server:call(?MODULE, {facet, Caller, Op}, Timeout).

init({Gap, Services}) ->
    {ok, #srv{core = erx_gatt_registry:new(Gap, Services, erx_gatt_decl:advertised()),
              requests = gen_server:reqids_new()}}.

handle_call(advertised, _From, #srv{core = Core} = Srv) ->
    {reply, erx_gatt_registry:advertised(Core), Srv};
handle_call({join, Conn, Info}, {Link, _Tag} = From, Srv) ->
    step({join, Link, Conn, Info, From}, Srv);
handle_call({facet, Caller, Op}, From, Srv) ->
    step({facet, Caller, Op, From}, Srv).

handle_cast(_Message, Srv) ->
    {noreply, Srv}.

handle_info({erx_bt_link, Link, {write, Ref, Key, Value}}, Srv) ->
    step({write, Link, Ref, Key, Value, make_ref()}, Srv);
handle_info({erx_bt_link, Link, Message}, Srv) ->
    step({link, Link, Message}, Srv);
handle_info(Message, #srv{requests = Requests} = Srv) ->
    case gen_server:check_response(Message, Requests, true) of
        {{reply, Answer}, From, Rest} ->
            gen_server:reply(From, Answer),
            {noreply, Srv#srv{requests = Rest}};
        {{error, {_Reason, _Link}}, From, Rest} ->
            gen_server:reply(From, {error, gone}),
            {noreply, Srv#srv{requests = Rest}};
        _NotAResponse ->
            monitored(Message, Srv)
    end.

%% The end of a link or a handler the registry monitors; any other message is dropped.
monitored({'DOWN', _Monitor, process, Pid, _Reason}, Srv) ->
    step({down, Pid}, Srv);
monitored(_Stray, Srv) ->
    {noreply, Srv}.

step(Input, #srv{core = Core} = Srv) ->
    {Actions, Next} = erx_gatt_registry:step(Input, Core),
    {noreply, lists:foldl(fun perform/2, Srv#srv{core = Next}, Actions)}.

perform({reply, From, Answer}, Srv) ->
    gen_server:reply(From, Answer),
    Srv;
perform({monitor, Pid}, Srv) ->
    erlang:monitor(process, Pid),
    Srv;
perform({event, Handler, Event}, Srv) ->
    Handler ! Event,
    Srv;
perform({advertised, Input}, Srv) ->
    case whereis(erx_bt_hci) of
        undefined -> ok;
        Controller -> Controller ! {advertised, Input}
    end,
    Srv;
perform({to_link, Link, Message}, Srv) ->
    Link ! {registry, Message},
    Srv;
perform({request, Link, Request, From}, #srv{requests = Requests} = Srv) ->
    Srv#srv{requests = gen_server:send_request(Link, Request, From, Requests)}.
