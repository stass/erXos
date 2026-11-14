%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block driver's virtio-mmio transport (docs/design-storage.md, "The block driver"):
%% the device process erx_blk starts for a block record whose peripheral is virtio_blk,
%% registered as erx_blk, under erx_blk_sup in the storage domain, over erx_device
%% (docs/design-runtime.md, "The device NIF"). It owns the device's one request queue,
%% posts each read, write and flush as one request through erx_blk_write, and answers its
%% caller when the device completes it, on the line's interrupt.
%%
%% Its start and every restart run one sequence, so a restarted process finds the device as
%% its predecessor left it and resets it: erx_device:open/1 on the record, the transport's
%% magic, version and device id, queue_create/4, negotiate/2, which resets the device and
%% returns every buffer it held, erx_irq_line:attach/2, and the capacity from the
%% configuration space.
%% The start requires VIRTIO_BLK_F_FLUSH of the device, since flush has nothing to post on a
%% device without it. A transport with no device behind it gives no line and no process; a
%% device that fails any step gives one line in the kernel log and no process: init/1 returns
%% ignore, so the boot goes on.
%%
%% A call answers as the transport contract says (erx_blk): {ok, Bytes} for a read, ok for a
%% write or a flush, or {error, Reason}: out_of_range and bad_count before the device is
%% touched, busy when the backlog is full, and {device, Detail} for a request the device
%% failed: Detail is ioerr, unsupp, {status, N} or {length, N} from what the device wrote
%% (erx_blk_request:decode/2), or broken for every request the process holds when the
%% device breaks its queue. A broken queue ends the process with a shutdown, which, as any
%% end of the device process, ends erx_blk_sup and the storage domain; the domain's restart
%% resets the device and mounts its file systems afresh. The process does not reset the
%% device itself: nothing promises that a reset keeps what the device's volatile write cache
%% holds, so writes it answered ok before the reset could be lost while a later flush
%% answered ok, and a file system would report durable what was not. A restart through the
%% driver-control facet starts a new process, and the windows bound to this one answer eio
%% from then on (erx_blk_window).

-module(erx_blk_virtio).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

%% The request queue, its entries and the requests that wait for a free entry.
-define(QUEUE, 0).
-define(QUEUE_SIZE, 16).
-define(MAX_WAITING, 64).
-define(IRQ_LINE, 0).
%% Features wanted beyond VERSION_1: FLUSH alone, so the device takes a flush and runs the
%% plain request set otherwise.
-define(WANTED, (1 bsl ?ERX_VIRTIO_BLK_F_FLUSH)).
-define(GENERATION_TRIES, 4).

-type op() :: {read, non_neg_integer(), pos_integer()} | {write, non_neg_integer(), binary()} | flush.

%% dev, irq, queue, capacity, version and features are fixed once init/1 returns; tag is
%% the next request's tag; pending maps each posted tag to its caller and what to decode;
%% waiting holds the requests the full queue turned away, oldest first.
-record(state, {dev, irq, queue, capacity :: non_neg_integer(), version :: non_neg_integer(),
                features :: non_neg_integer(), tag = 0 :: non_neg_integer(),
                pending = #{} :: #{non_neg_integer() => {gen_server:from(), erx_blk_request:request()}},
                waiting = queue:new() :: queue:queue({gen_server:from(), op()})}).

%% The device process of the block record Spec, registered as erx_blk, the name the
%% transport contract's calls reach it by.
-spec start_link(erx_device_record:spec()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Spec) ->
    gen_server:start_link({local, erx_blk}, ?MODULE, Spec, []).

%% Any exception of the sequence, a bug or a NIF that changed, is one line and no process as
%% well: the application is permanent, so a raise here would end the boot. An empty
%% transport is no disk, a configuration and not a fault, so it has no line, as an absent
%% device's probe prints nothing on FreeBSD.
init(Spec) ->
    case try start_device(Spec) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State} ->
            log("virtio-mmio version ~b, capacity ~b sectors", [State#state.version, State#state.capacity]),
            {ok, State};
        {error, no_device} ->
            ignore;
        {error, Reason} ->
            log("the block device is not driven: ~0p", [Reason]),
            ignore
    end.

%% Open, identify, queue_create, negotiate, attach and capacity, in that order; each
%% step's refusal is the sequence's error and stops it.
start_device(Spec) ->
    maybe
        {ok, Dev} ?= step(open, erx_device:open(Spec)),
        {ok, Version} ?= identify(Dev),
        {ok, Queue} ?= step(queue_create, erx_device:queue_create(Dev, ?QUEUE, ?QUEUE_SIZE,
                                                                  erx_blk_request:buffer_size())),
        {ok, Features} ?= step(negotiate, negotiate(Dev)),
        {ok, Irq} ?= step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        {ok, Capacity} ?= capacity(Dev, ?GENERATION_TRIES),
        {ok, #state{dev = Dev, irq = Irq, queue = Queue, capacity = Capacity, version = Version,
                    features = Features}}
    end.

identify(Dev) ->
    Version = erx_device:read(Dev, version),
    case erx_blk_request:identify(erx_device:read(Dev, magic), Version, erx_device:read(Dev, device_id)) of
        ok -> {ok, Version};
        %% Device id 0 is an empty transport: virtio's name for no device.
        {error, {device_id, 0}} -> {error, no_device};
        Refused -> Refused
    end.

%% The device's reset and features, at the start. The NIF accepts of WANTED only what the
%% device offers, so a device that does not offer FLUSH is refused here.
negotiate(Dev) ->
    case erx_device:negotiate(Dev, ?WANTED) of
        {ok, Features} when Features band ?WANTED =:= ?WANTED -> {ok, Features};
        {ok, _Features} -> {error, no_flush};
        Refused -> Refused
    end.

%% The capacity, read between two equal reads of the configuration generation, so the two
%% words come from one configuration (section 4.2.2.2 of the specification).
capacity(_Dev, 0) ->
    {error, {capacity, unstable}};
capacity(Dev, Tries) ->
    Before = erx_device:read(Dev, config_generation),
    Low = erx_device:read(Dev, capacity_low),
    High = erx_device:read(Dev, capacity_high),
    case erx_device:read(Dev, config_generation) of
        Before -> {ok, erx_blk_request:capacity(Low, High)};
        _Changed -> capacity(Dev, Tries - 1)
    end.

step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

handle_call(info, _From, State = #state{version = Version, capacity = Capacity, features = Features}) ->
    {reply, {ok, #{transport => virtio_mmio, capacity => Capacity, max_sectors => erx_blk_request:max_sectors(),
                   detail => #{version => Version, features => Features}}}, State};
handle_call(Op = {read, _Sector, _Count}, From, State) ->
    submit(From, Op, State);
handle_call(Op = {write, _Sector, _Data}, From, State) ->
    submit(From, Op, State);
handle_call(flush, From, State) ->
    submit(From, flush, State);
%% A call outside the transport contract, which only a caller that bypasses erx_blk sends,
%% is refused with bad_count, the nearest reason of the contract's closed set, before the
%% device is touched. It is answered, not crashed on, so no process of the domain can end
%% the device process by sending one.
handle_call(_Other, _From, State) ->
    {reply, {error, bad_count}, State}.

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

%% A request from a caller: held behind any request already waiting, so the device takes
%% requests in the order they arrive even when a smaller one would fit; otherwise posted,
%% held while the queue is full, or answered at once.
submit(From, Op, State = #state{waiting = Waiting}) ->
    case queue:is_empty(Waiting) of
        true -> submit_now(From, Op, State);
        false -> hold(From, Op, State)
    end.

submit_now(From, Op, State) ->
    case post(From, Op, State) of
        {posted, Next} ->
            {noreply, Next};
        full ->
            hold(From, Op, State);
        broken ->
            broken([From], State);
        {refused, Reason} ->
            {reply, {error, Reason}, State}
    end.

hold(From, Op, State = #state{waiting = Waiting}) ->
    case queue:len(Waiting) < ?MAX_WAITING of
        true -> {noreply, State#state{waiting = queue:in({From, Op}, Waiting)}};
        false -> {reply, {error, busy}, State}
    end.

%% One post, of a read, a write or a flush, through erx_blk_write, the one module that posts
%% and so the one write path. A posted request waits in pending under its tag for its
%% completion. A flush posted now covers every write answered before it, since a write is
%% answered only once the device has completed it.
post(From, Op, State = #state{dev = Dev, queue = Queue, capacity = Capacity, tag = Tag, pending = Pending}) ->
    {Posted, Request} =
        case Op of
            {read, Sector, Count} ->
                {erx_blk_write:read(Dev, Queue, Tag, Sector, Count, Capacity), {read, Count}};
            {write, Sector, Data} ->
                {erx_blk_write:write(Dev, Queue, Tag, Sector, Data, Capacity), write};
            flush ->
                {erx_blk_write:flush(Dev, Queue, Tag), flush}
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
            broken([], State)
    end.

answer({Tag, Bytes}, State = #state{pending = Pending}) ->
    case maps:take(Tag, Pending) of
        {{From, Request}, Rest} ->
            gen_server:reply(From, device(erx_blk_request:decode(Request, Bytes))),
            State#state{pending = Rest};
        error ->
            State
    end.

%% A completion in the transport contract's terms: what the device or the medium failed is
%% {device, Detail}, Detail one of erx_blk_request:reason()'s fixed atoms and integers. A
%% window answers its client eio for it and passes on nothing of it.
device({error, Detail}) -> {error, {device, Detail}};
device(Result) -> Result.

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
                    broken([From], State#state{waiting = Rest});
                {refused, Reason} ->
                    gen_server:reply(From, {error, Reason}),
                    resume(State#state{waiting = Rest})
            end
    end.

%% The device broke its queue: a completion it wrote did not match what was in flight. Every
%% request in flight or held, and the callers in Unqueued, whose requests the broken queue
%% refused, are answered {device, broken}, since none of their completions can be believed,
%% and the process ends (moduledoc): the storage domain's restart resets the device.
broken(Unqueued, State = #state{pending = Pending, waiting = Waiting}) ->
    Callers = Unqueued ++ [From || {From, _Request} <- maps:values(Pending)]
        ++ [From || {From, _Op} <- queue:to_list(Waiting)],
    lists:foreach(fun(From) -> gen_server:reply(From, {error, {device, broken}}) end, Callers),
    log("the device broke its queue; the storage domain ends", []),
    {stop, {shutdown, broken_queue}, State#state{pending = #{}, waiting = queue:new()}}.

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% driver's or erx_device's, never text the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_blk: ", io_lib:format(Format, Arguments)]),
    ok.
