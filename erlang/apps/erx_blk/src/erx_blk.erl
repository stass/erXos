%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The virtio-mmio block driver's device process (docs/design-storage.md, "The block
%% driver"), under erx_blk_sup in the storage domain, over erx_device
%% (docs/design-runtime.md, "The device NIF"). It owns the device's one request queue,
%% posts each read and write as one request, and answers its caller when the device
%% completes it, on the line's interrupt.
%%
%% Its start and every restart run one sequence, so a restarted driver finds the device as
%% its predecessor left it and resets it: the block device's record, erx_device:open/1,
%% the transport's magic, version and device id, queue_create/4, negotiate/2, which resets
%% the device and returns every buffer it held, erx_irq_line:attach/2, and the capacity from the
%% configuration space. A machine without a disk, a record the driver cannot read and a
%% device that fails any step each give one line in the kernel log and no driver: init/1
%% returns ignore, so the boot goes on.
%%
%% A request answers {ok, Bytes} for a read, ok for a write, or {error, Reason}: out_of_range
%% and bad_count before the device is touched, busy when the backlog is full, ioerr, unsupp,
%% {status, N} and {length, N} from what the device wrote (erx_blk_request:decode/2), and
%% broken for a request in flight when the device broke its queue. A broken queue is
%% renegotiated in place; a device that refuses that ends the driver with a shutdown, which,
%% as any end of the driver, ends erx_blk_sup and the storage domain.

-module(erx_blk).
-behaviour(gen_server).

-export([start_link/0, read/2, write/2, info/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

%% The request queue, its entries and the requests that wait for a free entry.
-define(QUEUE, 0).
-define(QUEUE_SIZE, 16).
-define(MAX_WAITING, 64).
-define(IRQ_LINE, 0).
%% Features wanted beyond VERSION_1: none, so the device runs the plain request set.
-define(WANTED, 0).
-define(CALL_TIMEOUT, 30000).
-define(GENERATION_TRIES, 4).

-type op() :: {read, non_neg_integer(), pos_integer()} | {write, non_neg_integer(), binary()}.

%% dev, queue, capacity and version are fixed once init/1 returns; tag is the next request's
%% tag; pending maps each posted tag to its caller and what to decode; waiting holds the
%% requests the full queue turned away, oldest first.
-record(state, {dev, irq, queue, capacity :: non_neg_integer(), version :: non_neg_integer(),
                features :: non_neg_integer(), tag = 0 :: non_neg_integer(),
                pending = #{} :: #{non_neg_integer() => {gen_server:from(), erx_blk_request:request()}},
                waiting = queue:new() :: queue:queue({gen_server:from(), op()})}).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Count sectors from Sector, at most erx_blk_request:max_sectors() in one request.
-spec read(non_neg_integer(), pos_integer()) -> {ok, binary()} | {error, term()}.
read(Sector, Count) -> call({read, Sector, Count}).

%% Data, whole sectors, from Sector.
-spec write(non_neg_integer(), binary()) -> ok | {error, term()}.
write(Sector, Data) -> call({write, Sector, Data}).

%% The transport version, the capacity in sectors and the features the device runs with.
-spec info() -> {ok, #{version := non_neg_integer(), capacity := non_neg_integer(),
                       features := non_neg_integer()}} | {error, no_device}.
info() -> call(info).

call(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, no_device};
        Pid -> gen_server:call(Pid, Request, ?CALL_TIMEOUT)
    end.

%% Any exception of the sequence, a bug or a NIF that changed, is one line and no driver as
%% well: the application is permanent, so a raise here would end the boot. A machine with
%% no disk is a configuration, not a fault, so it has no line, as an absent device's probe
%% prints nothing on FreeBSD.
init([]) ->
    case try start_device() catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State} ->
            log("virtio-mmio version ~b, capacity ~b sectors", [State#state.version, State#state.capacity]),
            {ok, State};
        {error, no_device} ->
            ignore;
        {error, Reason} ->
            log("the block device is not driven: ~0p", [Reason]),
            ignore
    end.

%% The record, open, identify, queue_create, negotiate, attach and capacity, in that
%% order; each step's refusal is the sequence's error and stops it.
start_device() ->
    maybe
        {ok, Spec} ?= record(),
        {ok, Dev} ?= open(Spec),
        {ok, Version} ?= identify(Dev),
        {ok, Queue} ?= step(queue_create, erx_device:queue_create(Dev, ?QUEUE, ?QUEUE_SIZE,
                                                                  erx_blk_request:buffer_size())),
        {ok, Features} ?= step(negotiate, erx_device:negotiate(Dev, ?WANTED)),
        {ok, Irq} ?= step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        {ok, Capacity} ?= capacity(Dev, ?GENERATION_TRIES),
        {ok, #state{dev = Dev, irq = Irq, queue = Queue, capacity = Capacity, version = Version, features = Features}}
    end.

record() ->
    case erx_device_record:find(block, virtio_mmio) of
        {ok, [Spec | _]} -> {ok, Spec};
        {ok, []} -> {error, no_device};
        {error, {bad_device_record, _Text}} -> {error, bad_device_record}
    end.

open(Spec) -> step(open, erx_device:open(Spec)).

identify(Dev) ->
    Version = erx_device:read(Dev, version),
    case erx_blk_request:identify(erx_device:read(Dev, magic), Version, erx_device:read(Dev, device_id)) of
        ok -> {ok, Version};
        %% Device id 0 is an empty transport: virtio's name for no device.
        {error, {device_id, 0}} -> {error, no_device};
        Refused -> Refused
    end.

%% The capacity, read between two equal reads of the configuration generation, so the two
%% words come from one configuration (section 4.2.2.2 of the specification).
capacity(_Dev, 0) ->
    {error, {capacity, unstable}};
capacity(Dev, Tries) ->
    Before = erx_device:read(Dev, config_generation),
    Low = erx_device:read(Dev, {config, ?ERX_VIRTIO_BLK_CONFIG_CAPACITY_LOW}),
    High = erx_device:read(Dev, {config, ?ERX_VIRTIO_BLK_CONFIG_CAPACITY_HIGH}),
    case erx_device:read(Dev, config_generation) of
        Before -> {ok, erx_blk_request:capacity(Low, High)};
        _Changed -> capacity(Dev, Tries - 1)
    end.

step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

handle_call(info, _From, State = #state{version = Version, capacity = Capacity, features = Features}) ->
    {reply, {ok, #{version => Version, capacity => Capacity, features => Features}}, State};
handle_call(Op = {read, _Sector, _Count}, From, State) ->
    submit(From, Op, State);
handle_call(Op = {write, _Sector, _Data}, From, State) ->
    submit(From, Op, State);
handle_call(_Other, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

%% The line fired: acknowledge the device's interrupt before draining, so a completion that
%% lands after the drain fires the line again, then unmask the line before draining, for
%% the same reason, and answer whatever the device returned. A delivery may be spurious, which drains nothing.
handle_info({erx_irq, Dev, ?IRQ_LINE}, State = #state{dev = Dev}) ->
    Status = erx_device:read(Dev, interrupt_status),
    ok = erx_device:write(Dev, interrupt_ack, Status band 3),
    ok = erx_irq_line:ack(State#state.irq),
    drain(State);
handle_info(_Other, State) ->
    {noreply, State}.

%% A request from a caller: posted, held while the queue is full, or answered at once.
submit(From, Op, State) ->
    case post(From, Op, State) of
        {posted, Next} ->
            {noreply, Next};
        full ->
            hold(From, Op, State);
        broken ->
            recover([From], State);
        {refused, Reason} ->
            {reply, {error, Reason}, State}
    end.

hold(From, Op, State = #state{waiting = Waiting}) ->
    case queue:len(Waiting) < ?MAX_WAITING of
        true -> {noreply, State#state{waiting = queue:in({From, Op}, Waiting)}};
        false -> {reply, {error, busy}, State}
    end.

%% One post, of a read or a write, through erx_blk_write, the one module that posts and so
%% the one write path. A posted request waits in pending under its tag for its completion.
post(From, Op, State = #state{dev = Dev, queue = Queue, capacity = Capacity, tag = Tag, pending = Pending}) ->
    {Posted, Request} =
        case Op of
            {read, Sector, Count} ->
                {erx_blk_write:read(Dev, Queue, Tag, Sector, Count, Capacity), {read, Count}};
            {write, Sector, Data} ->
                {erx_blk_write:write(Dev, Queue, Tag, Sector, Data, Capacity), write}
        end,
    case Posted of
        ok -> {posted, State#state{tag = (Tag + 1) band 16#ffffffffffffffff,
                                   pending = Pending#{Tag => {From, Request}}}};
        {error, full} -> full;
        {error, broken} -> broken;
        {error, Reason} -> {refused, Reason}
    end.

%% Every completion the device has returned, each answered with what decode/2 makes of its
%% bytes, then the held requests posted while entries are free. The NIF returns only tags in
%% flight, so each call returns fewer entries than are pending and the loop ends.
drain(State = #state{dev = Dev, queue = Queue}) ->
    case erx_device:complete(Dev, Queue) of
        {ok, []} ->
            resume(State);
        {ok, Completions} ->
            drain(lists:foldl(fun answer/2, State, Completions));
        {error, broken} ->
            recover([], State)
    end.

answer({Tag, Bytes}, State = #state{pending = Pending}) ->
    case maps:take(Tag, Pending) of
        {{From, Request}, Rest} ->
            gen_server:reply(From, erx_blk_request:decode(Request, Bytes)),
            State#state{pending = Rest};
        error ->
            State
    end.

resume(State = #state{waiting = Waiting}) ->
    case queue:out(Waiting) of
        {empty, _} ->
            {noreply, State};
        {{value, {From, Op}}, Rest} ->
            case post(From, Op, State#state{waiting = Rest}) of
                {posted, Next} ->
                    resume(Next);
                full ->
                    {noreply, State};
                broken ->
                    recover([From], State#state{waiting = Rest});
                {refused, Reason} ->
                    gen_server:reply(From, {error, Reason}),
                    resume(State#state{waiting = Rest})
            end
    end.

%% The device broke its queue: a completion it wrote did not match what was in flight. Every
%% request in flight or held, and the callers in Unqueued, whose requests the broken queue
%% refused, are answered broken, since none of
%% their completions can be believed, and negotiate/2 resets the device and returns every
%% buffer to the pool. A device that refuses the reset ends the driver.
recover(Unqueued, State = #state{dev = Dev, pending = Pending, waiting = Waiting}) ->
    Callers = Unqueued ++ [From || {From, _Request} <- maps:values(Pending)]
        ++ [From || {From, _Op} <- queue:to_list(Waiting)],
    lists:foreach(fun(From) -> gen_server:reply(From, {error, broken}) end, Callers),
    Clear = State#state{pending = #{}, waiting = queue:new()},
    case erx_device:negotiate(Dev, ?WANTED) of
        {ok, Features} ->
            log("the device broke its queue; reset it", []),
            {noreply, Clear#state{features = Features}};
        {error, Reason} ->
            log("the device broke its queue and refused a reset: ~0p", [Reason]),
            {stop, {shutdown, {negotiate, Reason}}, Clear}
    end.

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% driver's or erx_device's, never text the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_blk: ", io_lib:format(Format, Arguments)]),
    ok.
