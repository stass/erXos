%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_service).
-moduledoc """
The behaviour of one GATT service's handler over the `ble` facet (docs/design-bluetooth.md,
"The client"): a gen_server that attaches to its service through erx_gatt:attach/1 and
turns each event erx_gatt:event/2 admits into a callback of its module.

**Starting.** start_link/3,4 wait, at most `bt_attach_wait_ms`, for the domain to hold
`ble`, since an app's applications may start before the domain service has installed
the session's facets; then they attach, then call `Module:init(Args, Table)`, `Table` the
service's characteristics as the attach answered them. It answers `{ok, Values, State}`,
and the start sets each characteristic of `Values`, a map from characteristic to value,
before it answers `{ok, Pid}`; or `{error, Reason}`, which fails the start with `Reason`
and ends the server normally, so a linked caller that does not trap exits lives on. An
attach that fails stops the start with its refusal, `{error, attached}` past the
deadline among them, so the app's supervisor sees a start that failed and restarts it
within its intensity. The registry sends the
`connected` events it replays to a new handler straight to it, so they may arrive before
the attach's answer; gen_server reads none of them until init has returned.

**Events.** A write calls `Module:handle_write(Conn, Char, Value, State)`, whose `{Answer,
State}` is the write's reply, sent before the next message is read, so the module sees a
link's next write only once it has answered the last, as the registry hands them out. A
reply the facet refuses, such as `busy`, is dropped: the registry's
`bt_handler_timeout_ms` answers that write. Every other event calls
`Module:handle_event(Event, State)`, answering `{ok, State}`.

**Calls and other messages.** call/2 calls `Module:handle_call(Request, From, State)`,
answering `{reply, Reply, State}`, so another process of the app reaches the service
through its handler, the one process whose effects the registry takes. A message in no
envelope is the handler's own domain's and calls the optional `Module:handle_info(Info,
State)`, answering `{ok, State}`; an enveloped message that is no event of the facet's
owner is dropped.

**The facet's end.** The server monitors the facet. When it ends, the Bluetooth domain's
restart has taken the registry and every attachment; the server waits until this domain
holds the facet the new incarnation mints (erx_facets:await/3, with the ended facet as
the one seen) and then stops with `{facet, Reason}`, so its supervisor's restart attaches
through the new facet at once instead of spending its intensity on the dead one.
""".

-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/3, start_link/4, call/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-callback init(Args :: term(), Table :: erx_gatt:table()) ->
    {ok, Values :: #{atom() => binary()}, State :: term()} | {error, Reason :: term()}.
-callback handle_write(Conn :: reference(), Char :: atom(), Value :: binary(), State :: term()) ->
    {erx_gatt:answer(), State :: term()}.
-callback handle_event(Event :: erx_gatt:event(), State :: term()) -> {ok, State :: term()}.
-callback handle_call(Request :: term(), From :: gen_server:from(), State :: term()) ->
    {reply, Reply :: term(), State :: term()}.
-callback handle_info(Info :: term(), State :: term()) -> {ok, State :: term()}.
-optional_callbacks([handle_info/2]).

%% facet_monitor: the monitor of the facet; origin: the facet's owner, whose envelope the
%% events arrive in.
-record(handler, {module :: module(), facet_monitor :: reference(), origin :: non_neg_integer(),
                  state :: term()}).

-doc "Starts the handler of `Service`, linked to the caller.".
-spec start_link(atom(), module(), term()) -> gen_server:start_ret().
start_link(Service, Module, Args) ->
    gen_server:start_link(?MODULE, {Service, Module, Args}, []).

-doc "Starts the handler of `Service`, linked to the caller and registered as `Name`.".
-spec start_link(gen_server:server_name(), atom(), module(), term()) -> gen_server:start_ret().
start_link(Name, Service, Module, Args) ->
    gen_server:start_link(Name, ?MODULE, {Service, Module, Args}, []).

-doc "Calls the handler `Server`'s `Module:handle_call/3` with `Request`.".
-spec call(gen_server:server_ref(), term()) -> term().
call(Server, Request) ->
    gen_server:call(Server, {call, Request}, infinity).

-doc false.
init({Service, Module, Args}) ->
    _ = erx_facets:await(ble, none, ?ERX_BT_ATTACH_WAIT_MS),
    case erx_gatt:facet() of
        none ->
            {stop, not_granted};
        {Facet, Origin} ->
            Monitor = erlang:monitor(process, Facet),
            case erx_gatt:attach(Service) of
                {ok, Table} ->
                    started(Module:init(Args, Table), Service,
                            #handler{module = Module, facet_monitor = Monitor, origin = Origin});
                {error, Reason} ->
                    {stop, Reason}
            end
    end.

%% The start's end: each characteristic of Values set and the handler running, or the
%% module's refusal.
started({ok, Values, State}, Service, Handler) ->
    [ok = erx_gatt:set(Service, Char, Value) || Char := Value <- maps:iterator(Values, ordered)],
    {ok, Handler#handler{state = State}};
started({error, Reason}, _Service, _Handler) ->
    {error, Reason}.

-doc false.
handle_call({call, Request}, From, #handler{module = Module, state = State} = Handler) ->
    {reply, Reply, Next} = Module:handle_call(Request, From, State),
    {reply, Reply, Handler#handler{state = Next}}.

-doc false.
handle_cast(_Message, Handler) ->
    {noreply, Handler}.

-doc false.
handle_info({'DOWN', Monitor, process, Facet, Reason}, #handler{facet_monitor = Monitor} = Handler) ->
    _ = erx_facets:await(ble, Facet, infinity),
    {stop, {facet, Reason}, Handler};
handle_info({erx_origin, _, _} = Message, #handler{origin = Origin} = Handler) ->
    case erx_gatt:event(Origin, Message) of
        {ok, Event} -> {noreply, event(Event, Handler)};
        unknown -> {noreply, Handler}
    end;
handle_info(Info, #handler{module = Module, state = State} = Handler) ->
    case erlang:function_exported(Module, handle_info, 2) of
        true ->
            {ok, Next} = Module:handle_info(Info, State),
            {noreply, Handler#handler{state = Next}};
        false ->
            {noreply, Handler}
    end.

event({write, Req, Conn, Char, Value}, #handler{module = Module, state = State} = Handler) ->
    {Answer, Next} = Module:handle_write(Conn, Char, Value, State),
    _ = erx_gatt:reply(Req, Answer),
    Handler#handler{state = Next};
event(Event, #handler{module = Module, state = State} = Handler) ->
    {ok, Next} = Module:handle_event(Event, State),
    Handler#handler{state = Next}.
