%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_service).
-moduledoc """
The behaviour of one GATT service's handler over the `ble` facet (docs/design-bluetooth.md,
"The client"): a gen_server that attaches to its service through erx_gatt:attach/1 and
turns each event erx_gatt:event/2 admits into a callback of its module.

**Starting.** start_link/3,4 answer `{ok, Pid}` at once, since a session's grants are
installed only after its start has finished and it has reported ready
(docs/design-system.md, "Waiting for a grant"). The server then waits for its grant,
erx_facets:await(ble, none, infinity), attaches, and calls `Module:init(Args, Table)`,
`Table` the service's characteristics as the attach answered them. It answers `{ok,
Values, State}`, and the server sets each characteristic of `Values`, a map from
characteristic to value, before it takes any event; or `{error, Reason}`, which stops the
server with `Reason`. An attach that fails stops it with its refusal, `attached` past the
deadline among them, so the app's supervisor restarts it within its intensity. The
registry sends the events it replays to a new handler straight to it, so they may arrive
before the attach's answer; gen_server reads none of them until the start has finished.

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

**A phone's bytes.** A write carries what a phone sent, a console's passphrase among
them, so no report of the server shows a term it holds: `format_status/1` shows its
module and origin and each message as its kind alone (`erx_report:status/2`), and a
callback, or a call of the facet inside one, that raises stops the server with
`{Class, Name}`, `Name` the leading atom of the raise's reason, or with `normal`,
`shutdown` or `{shutdown, _}` as an exit gave it, so the exit reason that leaves the
process, to its links, its monitors and its supervisor, carries none of the terms a
callback held. `sys:get_state/1` and sys tracing show the raw state and messages to whoever
in the domain asks for them.
""".

-behaviour(gen_server).

-export([start_link/3, start_link/4, call/2]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

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
-record(handler, {module :: module(), facet_monitor = none :: reference() | none,
                  origin = none :: non_neg_integer() | none, state :: term()}).

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
    {ok, #handler{module = Module}, {continue, {start, Service, Args}}}.

%% The start after the answer: the grant awaited, the attach, and each characteristic of
%% the module's Values set, or the stop with why the start failed.
-doc false.
handle_continue({start, Service, Args}, #handler{module = Module} = Handler) ->
    case erx_facets:await(ble, none, infinity) of
        {ok, Facet} ->
            Origin = erx:owner(Facet),
            Monitor = erlang:monitor(process, Facet),
            case erx_gatt:attach(Service) of
                {ok, Table} ->
                    started(Module:init(Args, Table), Service,
                            Handler#handler{facet_monitor = Monitor, origin = Origin});
                {error, Reason} ->
                    {stop, Reason, Handler}
            end;
        {error, Reason} ->
            {stop, Reason, Handler}
    end.

started({ok, Values, State}, Service, Handler) ->
    [ok = erx_gatt:set(Service, Char, Value) || Char := Value <- maps:iterator(Values, ordered)],
    {noreply, Handler#handler{state = State}};
started({error, Reason}, _Service, Handler) ->
    {stop, Reason, Handler}.

-doc false.
handle_call({call, Request}, From, #handler{module = Module, state = State} = Handler) ->
    guarded(fun() ->
                    {reply, Reply, Next} = Module:handle_call(Request, From, State),
                    {reply, Reply, Handler#handler{state = Next}}
            end, Handler).

-doc false.
handle_cast(_Message, Handler) ->
    {noreply, Handler}.

-doc false.
handle_info({'DOWN', Monitor, process, Facet, Reason}, #handler{facet_monitor = Monitor} = Handler) ->
    _ = erx_facets:await(ble, Facet, infinity),
    {stop, {facet, Reason}, Handler};
handle_info({erx_origin, _, _} = Message, #handler{origin = Origin} = Handler) ->
    case erx_gatt:event(Origin, Message) of
        {ok, Event} -> guarded(fun() -> {noreply, event(Event, Handler)} end, Handler);
        unknown -> {noreply, Handler}
    end;
handle_info(Info, #handler{module = Module, state = State} = Handler) ->
    case erlang:function_exported(Module, handle_info, 2) of
        true ->
            guarded(fun() ->
                            {ok, Next} = Module:handle_info(Info, State),
                            {noreply, Handler#handler{state = Next}}
                    end, Handler);
        false ->
            {noreply, Handler}
    end.

-doc false.
%% The module and origin, and each message as its kind: a write's value, a call's
%% request and the module's state may hold a phone's bytes.
format_status(Status) ->
    erx_report:status(Status, #{state => fun handler_facts/1, message => fun message_kind/1}).

handler_facts(#handler{module = Module, origin = Origin}) -> #{module => Module, origin => Origin};
handler_facts(_State) -> hidden.

message_kind({'$gen_call', _From, {call, Request}}) -> {call, erx_report:reason_name(Request)};
message_kind({erx_origin, _Origin, Message}) -> {event, erx_report:reason_name(Message)};
message_kind(Message) -> erx_report:reason_name(Message).

%% Step's answer, or, when it raises, a stop whose reason is the raise's class and the
%% leading atom of its reason, or a clean exit's own reason, so no exit reason carries
%% the bytes a callback held.
guarded(Step, Handler) ->
    try Step()
    catch
        exit:Reason when Reason =:= normal; Reason =:= shutdown -> {stop, Reason, Handler};
        exit:{shutdown, _} = Reason -> {stop, Reason, Handler};
        Class:Reason -> {stop, {Class, erx_report:reason_name(Reason)}, Handler}
    end.

event({write, Req, Conn, Char, Value}, #handler{module = Module, state = State} = Handler) ->
    {Answer, Next} = Module:handle_write(Conn, Char, Value, State),
    _ = erx_gatt:reply(Req, Answer),
    Handler#handler{state = Next};
event(Event, #handler{module = Module, state = State} = Handler) ->
    {ok, Next} = Module:handle_event(Event, State),
    Handler#handler{state = Next}.
