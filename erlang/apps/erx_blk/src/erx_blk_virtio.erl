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
%% (erx_blk_request:decode/2), deadline for a request still held behind the full queue
%% blk_wait_limit_ms after its acceptance, which is never posted, and broken or
%% in_flight_bound for every request the process holds when the device breaks its queue
%% or leaves a posted request incomplete blk_in_flight_ms after its post (abi/formats/blk.txt,
%% docs/design-storage.md, "Data model"). Each held request carries the time it was
%% accepted and each posted one the time it was posted, the deadlines are derived from
%% those, and one timer wakes the process at the earliest of them.
%%
%% A broken queue or a missed in-flight bound ends the process with a shutdown, which, as
%% any end of the device process, ends erx_blk_sup and the storage domain; the domain's
%% restart resets the device and mounts its file systems afresh. The process posts nothing
%% after either, so no completion the device writes later reaches a new request: the new
%% process's negotiate/2 resets the device before its queue takes a request, and the
%% buffers of the requests in flight stay the device's until that reset returns them
%% (docs/design-runtime.md, "The device NIF"). The process does not reset the device
%% itself: nothing promises that a reset keeps what the device's volatile write cache
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
%% The transport contract's bounds (abi/formats/blk.txt), in milliseconds of the monotonic
%% clock.
-define(WAIT_LIMIT_MS, ?ERX_BLK_WAIT_LIMIT_MS).
-define(IN_FLIGHT_MS, ?ERX_BLK_IN_FLIGHT_MS).

-type op() :: {read, non_neg_integer(), pos_integer()} | {write, non_neg_integer(), binary()} | flush.
-type ms() :: integer().

%% dev, irq, queue, capacity and features are fixed once init/1 returns; tag is
%% the next request's tag; pending maps each posted tag to its caller, what to decode and
%% when it was posted; waiting holds the requests the full queue turned away, oldest
%% first, each with when it was accepted; timer is the one wake-up, at the earliest
%% deadline those times give (next_deadline/1), or none.
-record(state, {dev, irq, queue, capacity :: non_neg_integer(), features :: non_neg_integer(),
                tag = 0 :: non_neg_integer(),
                pending = #{} :: #{non_neg_integer() => {gen_server:from(), erx_blk_request:request(), ms()}},
                waiting = queue:new() :: queue:queue({gen_server:from(), op(), ms()}),
                timer = none :: {ms(), reference()} | none}).

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
            log("virtio-mmio version ~b, capacity ~b sectors", [?ERX_VIRTIO_MMIO_VERSION, State#state.capacity]),
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
        {ok, Dev} ?= erx_step:step(open, erx_device:open(Spec)),
        ok ?= erx_virtio:identify(fun(Register) -> erx_device:read(Dev, Register) end, ?ERX_VIRTIO_ID_BLOCK),
        {ok, Queue} ?= erx_step:step(queue_create,
                                     erx_device:queue_create(Dev, ?QUEUE, ?QUEUE_SIZE,
                                                             erx_blk_request:buffer_size())),
        {ok, Features} ?= erx_step:step(negotiate, negotiate(Dev)),
        {ok, Irq} ?= erx_step:step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        {ok, Capacity} ?= capacity(Dev, ?GENERATION_TRIES),
        {ok, #state{dev = Dev, irq = Irq, queue = Queue, capacity = Capacity, features = Features}}
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

handle_call(info, _From, State = #state{capacity = Capacity, features = Features}) ->
    {reply, {ok, #{transport => virtio_mmio, capacity => Capacity, max_sectors => erx_blk_request:max_sectors(),
                   flush => true,
                   detail => #{version => ?ERX_VIRTIO_MMIO_VERSION, features => Features}}}, State};
handle_call(Op = {read, _Sector, _Count}, From, State) ->
    armed(submit(From, Op, now_ms(), State));
handle_call(Op = {write, _Sector, _Data}, From, State) ->
    armed(submit(From, Op, now_ms(), State));
handle_call(flush, From, State) ->
    armed(submit(From, flush, now_ms(), State));
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
%% The deadlines due now are acted on first, so a completion that arrives after its
%% request's in-flight bound answers nothing and no held request is posted past it.
handle_info({erx_irq, Dev, ?IRQ_LINE}, State = #state{dev = Dev}) ->
    Status = erx_device:read(Dev, interrupt_status),
    ok = erx_device:write(Dev, interrupt_ack, Status band 3),
    ok = erx_irq_line:ack(State#state.irq),
    Now = now_ms(),
    case tick(State, Now) of
        {noreply, Next} -> armed(drain(Next, Now));
        Stop -> Stop
    end;
%% The timer is a hint to look at the clock, never an event in itself: whatever timer sent
%% it, the deadlines due now are acted on and the timer is set again.
handle_info({timeout, _Timer, tick}, State = #state{timer = Timer}) ->
    _ = cancel(Timer),
    armed(tick(State#state{timer = none}, now_ms()));
handle_info(_Other, State) ->
    {noreply, State}.

%% A request from a caller, accepted at Now: held behind any request already waiting, so
%% the device takes requests in the order they arrive even when a smaller one would fit;
%% otherwise posted, held while the queue is full, or answered at once.
submit(From, Op, Now, State = #state{waiting = Waiting}) ->
    case queue:is_empty(Waiting) of
        true -> submit_now(From, Op, Now, State);
        false -> hold(From, Op, Now, State)
    end.

submit_now(From, Op, Now, State) ->
    case post(From, Op, Now, State) of
        {posted, Next} ->
            {noreply, Next};
        full ->
            hold(From, Op, Now, State);
        broken ->
            fail(broken, [From], State);
        {refused, Reason} ->
            {reply, {error, Reason}, State}
    end.

hold(From, Op, Accepted, State = #state{waiting = Waiting}) ->
    case queue:len(Waiting) < ?MAX_WAITING of
        true -> {noreply, State#state{waiting = queue:in({From, Op, Accepted}, Waiting)}};
        false -> {reply, {error, busy}, State}
    end.

%% One post at Now, of a read, a write or a flush, through erx_blk_write, the one module
%% that posts and so the one write path. A posted request waits in pending under its tag
%% for its completion, with Now, from which its in-flight bound runs. A flush posted now
%% covers every write answered before it, since a write is answered only once the device
%% has completed it.
post(From, Op, Now, State = #state{dev = Dev, queue = Queue, capacity = Capacity, tag = Tag, pending = Pending}) ->
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
                                   pending = Pending#{Tag => {From, Request, Now}}}};
        {error, full} -> full;
        {error, broken} -> broken;
        {error, Reason} -> {refused, Reason}
    end.

%% Every completion the device has returned, each answered with what decode/2 makes of its
%% bytes, then the held requests posted while entries are free. The NIF returns only tags in
%% flight, so each call returns fewer entries than are pending and the loop ends.
drain(State = #state{dev = Dev, queue = Queue}, Now) ->
    case erx_device:complete(Dev, Queue) of
        {ok, []} ->
            resume(State, Now);
        {ok, Completions} ->
            drain(lists:foldl(fun answer/2, State, Completions), Now);
        {error, broken} ->
            fail(broken, [], State)
    end.

%% A completion answers only the request posted under its tag in this process; a tag
%% that names none is dropped.
answer({Tag, Bytes}, State = #state{pending = Pending}) ->
    case maps:take(Tag, Pending) of
        {{From, Request, _Posted}, Rest} ->
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

%% The held requests, oldest first, posted at Now while the queue takes them; one past its
%% wait limit is answered deadline instead, never posted.
resume(State = #state{waiting = Waiting}, Now) ->
    case queue:out(Waiting) of
        {empty, _} ->
            {noreply, State};
        {{value, {From, _Op, Accepted}}, Rest} when Now - Accepted >= ?WAIT_LIMIT_MS ->
            gen_server:reply(From, {error, {device, deadline}}),
            resume(State#state{waiting = Rest}, Now);
        {{value, {From, Op, _Accepted}}, Rest} ->
            case post(From, Op, Now, State#state{waiting = Rest}) of
                {posted, Next} ->
                    resume(Next, Now);
                full ->
                    {noreply, State};
                broken ->
                    fail(broken, [From], State#state{waiting = Rest});
                {refused, Reason} ->
                    gen_server:reply(From, {error, Reason}),
                    resume(State#state{waiting = Rest}, Now)
            end
    end.

%% The deadlines due at Now: a posted request past its in-flight bound fails the device;
%% otherwise the held requests past their wait limit are answered deadline.
tick(State, Now) ->
    case due(State, Now) of
        in_flight_bound ->
            fail(in_flight_bound, [], State);
        {Late, Next} ->
            lists:foreach(fun(From) -> gen_server:reply(From, {error, {device, deadline}}) end, Late),
            {noreply, Next}
    end.

%% What the deadlines decide at Now, without effects: in_flight_bound when a posted request
%% has been in flight for the bound, else the callers of the held requests past their wait
%% limit and the state without them. The held requests are oldest first, so those past it
%% are a prefix.
-spec due(#state{}, ms()) -> in_flight_bound | {[gen_server:from()], #state{}}.
due(State = #state{pending = Pending, waiting = Waiting}, Now) ->
    case lists:any(fun({_From, _Request, Posted}) -> Now - Posted >= ?IN_FLIGHT_MS end, maps:values(Pending)) of
        true ->
            in_flight_bound;
        false ->
            {Late, Held} = lists:splitwith(fun({_From, _Op, Accepted}) -> Now - Accepted >= ?WAIT_LIMIT_MS end,
                                           queue:to_list(Waiting)),
            {[From || {From, _Op, _Accepted} <- Late], State#state{waiting = queue:from_list(Held)}}
    end.

%% The earliest deadline the state holds, as a monotonic time in milliseconds: each posted
%% request's in-flight bound and the oldest held request's wait limit; infinity when it
%% holds none.
-spec next_deadline(#state{}) -> ms() | infinity.
next_deadline(#state{pending = Pending, waiting = Waiting}) ->
    InFlight = [Posted + ?IN_FLIGHT_MS || {_From, _Request, Posted} <- maps:values(Pending)],
    Held = case queue:peek(Waiting) of
               {value, {_From, _Op, Accepted}} -> [Accepted + ?WAIT_LIMIT_MS];
               empty -> []
           end,
    lists:min([infinity | InFlight ++ Held]).

%% A callback's result with the timer set to the state's earliest deadline: kept when that
%% deadline is the one it is set for, otherwise cancelled and set again.
armed({noreply, State}) -> {noreply, arm(State)};
armed({reply, Reply, State}) -> {reply, Reply, arm(State)};
armed(Stop = {stop, _Reason, _State}) -> Stop.

arm(State = #state{timer = Timer}) ->
    case {next_deadline(State), Timer} of
        {Deadline, {Deadline, _Ref}} ->
            State;
        {Deadline, _Other} ->
            _ = cancel(Timer),
            State#state{timer = start_timer(Deadline)}
    end.

start_timer(infinity) -> none;
start_timer(Deadline) -> {Deadline, erlang:start_timer(Deadline, self(), tick, [{abs, true}])}.

cancel(none) -> ok;
cancel({_Deadline, Ref}) -> erlang:cancel_timer(Ref, [{async, true}, {info, false}]).

%% The device failed: it broke its queue, a completion it wrote not matching what was in
%% flight, or left a posted request incomplete past its in-flight bound. Every request in
%% flight or held, and the callers in Unqueued, whose requests the broken queue refused,
%% are answered {device, Detail}, since none of their completions can be believed, and the
%% process ends (moduledoc): the storage domain's restart resets the device.
fail(Detail, Unqueued, State = #state{pending = Pending, waiting = Waiting}) ->
    Callers = Unqueued ++ [From || {From, _Request, _Posted} <- maps:values(Pending)]
        ++ [From || {From, _Op, _Accepted} <- queue:to_list(Waiting)],
    lists:foreach(fun(From) -> gen_server:reply(From, {error, {device, Detail}}) end, Callers),
    {Reason, Line} = ending(Detail),
    log("~s; the storage domain ends", [Line]),
    {stop, {shutdown, Reason}, State#state{pending = #{}, waiting = queue:new()}}.

ending(broken) -> {broken_queue, "the device broke its queue"};
ending(in_flight_bound) -> {in_flight_bound, "a request passed its in-flight bound"}.

now_ms() ->
    erlang:monotonic_time(millisecond).

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% driver's or erx_device's, never text the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_blk: ", io_lib:format(Format, Arguments)]),
    ok.
