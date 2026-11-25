%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_code).
-behaviour(gen_server).

-moduledoc """
The code service of the system domain (docs/design-live.md, "Code from the host" and "The
code store"): it keeps the in-memory code store, erx_code_store, and loads modules into the
system domain's runtime by hash.

Every operation is one request term, read by `erx_code_store:read_request/1`, so the host
link's install facet hands `call/1` the term it decoded and nothing else; the other exports
build the same terms for callers in the system domain. A host loads a set of modules in
three steps, sending only what the store lacks: `missing/1` with the modules' hashes,
`put_piece/4` for each piece of each missing blob, then `load/1` with the manifest.

A load is planned whole before it changes anything. The plan names every module's verified
bytes (`erx_code_store:plan_load/2`), and `erx_code_batch:load/1`, which every domain's code
server also loads through, makes the batch current or refuses it whole: either every
module of the manifest is current when `load/1` returns `ok` or none changed.
`erx_code_batch:load/1` makes the names atoms, only after the manifest has been read, at
most code_modules_max of 255 bytes each per load (abi/services/code.txt); a load the
loader refuses still leaves its names' atoms behind (TODO.md).

**Start loads** (docs/design-live.md, "The code server", "The effect layer"). The domain
service tells erx_code with `started/4` that a supervised domain's code server reported.
erx_code keeps one erx_code_target state for each target, keyed by the name the domain
service gave it, and applies the actions each returns, in order, one effect each. Each load
in flight has an alias of its own, a deadline `code_load_wait` from its start with a timer
for it, and a monitor of its domain pid. A code server's messages reach erx_code in their
domain's envelope, `{erx_origin, D, Msg}`, and go to the target whose load holds the alias
`Msg` names; a load past its deadline ends as timed out before its message is read. Every
message to a domain leaves through `to_domain/2`, which never suspends erx_code. erx_code's
lifeline, which ends with it however it ends, is what a code server that keeps published
code monitors.
""".

-export([start_link/0, start_link/1, call/1, missing/1, put_piece/4, load/1, history/2, started/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).
-export_type([reply/0, target/0]).

-include("generated/erx_abi.hrl").

%% The store's limit: the overlay limit's default (docs/design-live.md, "Overlays").
-define(STORE_LIMIT, ?ERX_CODE_LOAD_BYTES_MAX).
%% A load prepares, purges and loads up to code_modules_max modules.
-define(CALL_TIMEOUT, 60000).

-doc """
A target as the domain service names it (docs/design-live.md, "Targets"): a configured row
whose domains carry the `supervised` flag, or one domain no specification restarts.
""".
-type target() :: {configured, term()} | {domain, non_neg_integer()}.

%% A load in flight: its target, the monotonic millisecond its deadline falls at, the timer
%% that fires then and the monitor of its domain pid.
-record(load, {target :: target(), deadline :: integer(), timer :: reference(),
               monitor :: reference()}).

%% The store, the lifeline, the load deadline's length in milliseconds, each target's core
%% and each load in flight by its alias.
-record(state, {store :: erx_code_store:store(), lifeline :: pid(), wait :: pos_integer(),
                targets = #{} :: #{target() => erx_code_target:state()},
                loads = #{} :: #{reference() => #load{}}}).

-doc """
The answer to a request. A load that `code:prepare_loading/1` or `code:finish_loading/1`
refuses answers `{error, {not_loaded, [{Name, What}]}}`, with `What` as `code:atomic_load/1`
gives it, a member of abi/services/code.txt's `code_load_reason`.
""".
-type reply() :: ok
               | {ok, [erx_code_store:hash()]}
               | {ok, erx_code_store:put_reply()}
               | {ok, erx_code_store:history()}
               | {error, bad_request | {bad_manifest, erx_code_store:manifest_error()}
                       | erx_code_store:put_error()
                       | {missing, [erx_code_store:hash()]}
                       | {hash_mismatch, erx_code_store:name()}
                       | {not_loaded, [{erx_code_store:name(), erx_abi_enums:code_load_reason()}]}
                       | scope}.

-doc "Starts the code service, registered as `erx_code`, with a store of 16 MiB.".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-doc """
As `start_link/0`, with the store's byte limit `limit` and a load's deadline `load_wait`, in
milliseconds (`code_load_wait` unless given), from `Options`.
""".
-spec start_link(#{limit => pos_integer(), load_wait => pos_integer()}) -> gen_server:start_ret().
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
                          {maps:get(limit, Options, ?STORE_LIMIT),
                           maps:get(load_wait, Options, ?ERX_CODE_LOAD_WAIT)}, []).

-doc """
Serves one request term from outside the code service, as `erx_code_store:read_request/1`
lists them. A term of any other shape answers `{error, bad_request}` and changes nothing.
""".
-spec call(term()) -> reply().
call(Request) ->
    gen_server:call(?MODULE, {request, Request}, ?CALL_TIMEOUT).

-doc "The hashes of `Hashes` whose blobs the store lacks.".
-spec missing([erx_code_store:hash()]) -> reply().
missing(Hashes) ->
    call({missing, Hashes}).

-doc "One piece of the blob `Hash` of `Size` bytes, at `Offset` (`erx_code_store:put_piece/5`).".
-spec put_piece(erx_code_store:hash(), pos_integer(), non_neg_integer(), binary()) -> reply().
put_piece(Hash, Size, Offset, Piece) ->
    call({put, Hash, Size, Offset, Piece}).

-doc "Loads the modules of `Manifest`, `[{Name, Hash}]`, into the system domain as one batch.".
-spec load(term()) -> reply().
load(Manifest) ->
    call({load, Manifest}).

-doc """
The hashes loaded into domain `DomainId` for `Module`, newest first, at most 16, each with
the time of its load in milliseconds of `erlang:system_time/1`. The service loads only into
the system domain, so any other domain answers `{error, scope}`.
""".
-spec history(integer(), module() | binary()) -> reply().
history(DomainId, Module) when is_atom(Module) ->
    history(DomainId, atom_to_binary(Module));
history(DomainId, Module) ->
    call({history, DomainId, Module}).

-doc """
The domain service's word that domain `Id`, of target `Target`, has the code server `Agent`
behind the domain pid `DomainPid`: a message, never a call, sent only to a registered
erx_code, so the domain service never waits on erx_code and runs on when none is
registered (docs/design-live.md, "The endpoint and its export").
""".
-spec started(non_neg_integer(), target(), pid(), pid()) -> ok.
started(Id, Target, DomainPid, Agent) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Pid -> Pid ! {erx_code_started, Id, Target, DomainPid, Agent}, ok
    end.

-doc false.
-spec init({pos_integer(), pos_integer()}) -> {ok, #state{}}.
init({Limit, Wait}) ->
    %% A send to a domain whose connection is busy then fails as nosuspend instead of
    %% queueing behind it (to_domain/2).
    process_flag(async_dist, false),
    {ok, #state{store = erx_code_store:new(Limit), lifeline = start_lifeline(), wait = Wait}}.

%% The lifeline: linked to erx_code, trapping exits, so it exits on erx_code's exit signal
%% whatever its reason, normal included, and dropping every other message. It traps exits
%% before erx_code goes on, so no exit of erx_code finds it not yet trapping.
start_lifeline() ->
    Owner = self(),
    Lifeline = spawn_link(fun() ->
                                  process_flag(trap_exit, true),
                                  Owner ! {lifeline, self()},
                                  lifeline(Owner)
                          end),
    receive {lifeline, Lifeline} -> Lifeline end.

lifeline(Owner) ->
    receive
        {'EXIT', Owner, Reason} -> exit(Reason);
        _ -> lifeline(Owner)
    end.

-doc false.
-spec handle_call({request, term()}, gen_server:from(), #state{}) -> {reply, reply(), #state{}}.
handle_call({request, Term}, _From, #state{store = Store} = State) ->
    {Reply, Next} = case erx_code_store:read_request(Term) of
                        {ok, Request} -> serve(Request, Store);
                        {error, _} = Refused -> {Refused, Store}
                    end,
    {reply, Reply, State#state{store = Next}}.

-doc false.
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info({erx_code_started, Id, {configured, _} = Target, DomainPid, Agent}, State0) ->
    State = with_target(Target, State0),
    {_, Modules} = erx_code_target:overlay(map_get(Target, State#state.targets)),
    Stored = erx_code_store:sizes(State#state.store, [H || {_, H, _} <- Modules]),
    Domain = #{id => Id, pid => DomainPid, agent => Agent, ready => true},
    Alias = alias(),
    {noreply, step(Target, fun(T) -> erx_code_target:started(Alias, Domain, Stored, T) end, State)};
handle_info({erx_origin, Origin, Message}, #state{loads = Loads} = State) ->
    case erx_code_target:alias(Message) of
        {ok, Alias} when is_map_key(Alias, Loads) ->
            #load{target = Target, deadline = Deadline} = map_get(Alias, Loads),
            Late = erlang:monotonic_time(millisecond) >= Deadline,
            Due = if
                      Late -> step(Target, fun(T) -> erx_code_target:deadline(Alias, T) end, State);
                      true -> State
                  end,
            {noreply, step(Target, fun(T) -> erx_code_target:received(Origin, Message, T) end, Due)};
        _ ->
            {noreply, State}
    end;
handle_info({timeout, _Timer, {erx_code_deadline, Alias}}, State) ->
    {noreply, on_load(Alias, fun(T) -> erx_code_target:deadline(Alias, T) end, State)};
handle_info({{erx_code_down, Alias}, _Monitor, process, _Pid, _Info}, State) ->
    {noreply, on_load(Alias, fun(T) -> erx_code_target:domain_down(Alias, T) end, State)};
%% Anything else, a started word for a target no specification restarts among it, which
%% the domain service never sends, and the timer and 'DOWN' messages of ended loads.
handle_info(_Message, State) ->
    {noreply, State}.

%% A configured target is made at the first word that names it, and kept: its overlay
%% outlives each of its domains.
with_target(Target, #state{targets = Targets, lifeline = Lifeline} = State) ->
    case Targets of
        #{Target := _} -> State;
        #{} -> State#state{targets = Targets#{Target => erx_code_target:new(#{lifeline => Lifeline,
                                                                             supervised => true})}}
    end.

%% An event of the load with Alias, if it is still in flight; a timer or monitor message
%% of a load that has ended reaches nothing.
on_load(Alias, Event, #state{loads = Loads} = State) ->
    case Loads of
        #{Alias := #load{target = Target}} -> step(Target, Event, State);
        #{} -> State
    end.

%% One event of Target's core, then the effects of the actions it returns, in order.
step(Target, Event, #state{targets = Targets} = State) ->
    {Core, Actions} = Event(map_get(Target, Targets)),
    lists:foldl(fun(Action, Acc) -> effect(Target, Action, Acc) end,
                State#state{targets = Targets#{Target := Core}}, Actions).

%% The effects of a start load's actions. A start load names only the published overlay,
%% whose blobs only a facet's load publishes, so begin_load holds no blob here; serve,
%% reply and stop_domain come with the facet's loads and resets (docs/todo-domains.md,
%% "code service, start loads to supervised domains").
effect(Target, {begin_load, Alias, DomainPid, _Hashes}, #state{loads = Loads, wait = Wait} = State) ->
    Deadline = erlang:monotonic_time(millisecond) + Wait,
    Timer = erlang:start_timer(Deadline, self(), {erx_code_deadline, Alias}, [{abs, true}]),
    Monitor = erlang:monitor(process, DomainPid, [{tag, {erx_code_down, Alias}}]),
    Load = #load{target = Target, deadline = Deadline, timer = Timer, monitor = Monitor},
    State#state{loads = Loads#{Alias => Load}};
effect(_, {send, Agent, Message}, State) ->
    to_domain(Agent, Message),
    State;
effect(_, {end_load, Alias}, #state{loads = Loads} = State) ->
    #{Alias := #load{timer = Timer, monitor = Monitor}} = Loads,
    _ = unalias(Alias),
    _ = erlang:cancel_timer(Timer, [{async, false}, {info, false}]),
    true = erlang:demonitor(Monitor, [flush]),
    State#state{loads = maps:remove(Alias, Loads)};
effect(_, {unalias, Alias}, State) ->
    _ = unalias(Alias),
    State;
effect(Target, {log, {start_load_failed, Revision, Result}}, State) ->
    logger:warning("erx_code: the start load of ~0p, overlay revision ~b, failed: ~0p",
                   [Target, Revision, Result]),
    State.

%% The one way a message leaves erx_code for a domain. It never suspends erx_code behind a
%% busy connection: a send refused as nosuspend is a message dropped, as one past the
%% runtime's system_queue is, and the load's deadline, or for a word of publication the
%% code server's, ends what it leaves waiting (docs/design-live.md, "The effect layer").
to_domain(Agent, Message) ->
    _ = erlang:send(Agent, Message, [nosuspend]),
    ok.

-doc """
The state as a crash report or `sys:get_status/1` shows it: the store's size and its
blobs' hashes, never its bytes, of the request being served only its kind, and of a
crash's reason only its leading atom (erx_report:reason_name/1), so no report carries
bytes from outside.
""".
-spec format_status(gen_server:format_status()) -> gen_server:format_status().
format_status(Status) ->
    erx_report:status(Status, #{state => fun store_summary/1, message => fun request_kind/1}).

store_summary(#state{store = Store, targets = Targets, loads = Loads}) ->
    (erx_code_store:summary(Store))#{targets => map_size(Targets), loads => map_size(Loads)};
store_summary(_State) -> hidden.

request_kind({request, Request}) ->
    {request, erx_report:reason_name(Request)};
request_kind(_Message) ->
    request.

-doc false.
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(_Message, State) ->
    {noreply, State}.

serve({missing, Hashes}, Store) ->
    {{ok, erx_code_store:missing(Store, Hashes)}, Store};
serve({put, Hash, Size, Offset, Piece}, Store) ->
    case erx_code_store:put_piece(Store, Hash, Size, Offset, Piece) of
        {ok, Reply, Next} -> {{ok, Reply}, Next};
        {error, Why, Next} -> {{error, Why}, Next}
    end;
serve({load, Manifest}, Store) ->
    case erx_code_store:plan_load(Store, Manifest) of
        {ok, Plan} ->
            case erx_code_batch:load(Plan) of
                ok -> {ok, erx_code_store:commit(Store, Plan, erlang:system_time(millisecond))};
                {error, _} = Failed -> {Failed, Store}
            end;
        {error, _} = Refused ->
            {Refused, Store}
    end;
serve({history, ?ERX_SYSTEM_DOMAIN_ID, Name}, Store) ->
    {{ok, erx_code_store:history(Store, Name)}, Store};
serve({history, _DomainId, _Name}, Store) ->
    {{error, scope}, Store}.
