%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_virtio_input).
-moduledoc """
The virtio-input driver (docs/design-display.md, "The display device"
and "Input events"): the process that owns one virtio-mmio input device
over erx_device and sends its records to the input router with
`erx_winfs:input/2`, under the name the device's record carries, its
device-tree path. A keyboard and a tablet are the same driver: it does
not decide what kind of device it drives, so a device with keys and
axes sends both. Its decisions are `erx_virtio_input_core`'s; this
module performs the device's steps and holds the fold between
deliveries.

Its start and every restart run one sequence, so a restarted process
resets the device its predecessor left: erx_device:open/1 on the record,
the transport's magic, version and device id, queue_create/4 for the
event queue, negotiate/2, which resets the device and returns every
buffer, the configuration's reads for each query
`erx_virtio_input_core:queries/0` names, erx_irq_line:attach/2, and
then every buffer of the event queue posted, each one event long. The
status queue, which carries what a driver tells the device, such as a
keyboard's LEDs, is not set up: the driver tells the device nothing. A
transport with no device behind it gives no process; a device that
fails any step gives one line in the kernel log and no process: init/1
returns ignore, so the display goes on without that device.

Each delivery of the line acknowledges the device's interrupt and takes
every buffer the device returned, in order; each is folded, its records
routed one at a time, and only then posted again, so a device that
sends faster than the router routes runs out of buffers and drops whole
updates, never part of one ("Input waits at its source"). A queue that
breaks, or a buffer that cannot be posted again, ends the process; the
supervisor's restart resets the device, and the router, which monitors
each source, releases what the device held.

Everything the device writes is untrusted: the configuration reads and
each event go to the core, which bounds every parse and never raises on
any input. The device's own name, its `ID_NAME`, is never read, so no text
the device supplies reaches the router or the log.
""".

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

-define(QUEUE, ?ERX_VIRTIO_INPUT_QUEUE_EVENT).
%% The event queue's entries, each one buffer of one event: QEMU's queue size
%% (docs/research-virtio-input-qemu.md, fact 7), so an update of up to 64 events arrives.
-define(QUEUE_SIZE, 64).
-define(IRQ_LINE, 0).
%% The features wanted beyond VERSION_1: none, since the device type has no feature bits
%% of its own (virtio 1.2, section 5.8.3).
-define(WANTED, 0).
%% How many times one query's reads are tried before the configuration counts as never
%% holding still.
-define(GENERATION_TRIES, 4).

%% dev, irq, queue and path are fixed once init/1 returns; fold is the core's state.
-record(state, {dev :: erx_device:device(), irq :: erx_irq_line:handle(), queue :: erx_device:queue(),
                path :: binary(), fold :: erx_virtio_input_core:state()}).

-doc "The driver of the input device record Spec, unregistered: a display has several.".
-spec start_link(erx_device_record:spec()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

%% Any exception of the sequence, a bug or a NIF that changed, is one line and no process as
%% well. An empty transport is no device, a configuration and not a fault, so it has no line.
init(#{path := Path} = Spec) ->
    case try start_device(Spec) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State} ->
            log(Path, "driven", []),
            {ok, State};
        {error, no_device} ->
            ignore;
        {error, Reason} ->
            log(Path, "not driven: ~0p", [Reason]),
            ignore
    end.

%% Open, identify, queue_create, negotiate, the configuration, attach and the posts, in that
%% order; each step's refusal is the sequence's error and stops it.
start_device(#{path := Path} = Spec) ->
    maybe
        {ok, Dev} ?= step(open, erx_device:open(Spec)),
        ok ?= identify(Dev),
        {ok, Queue} ?= step(queue_create, erx_device:queue_create(Dev, ?QUEUE, ?QUEUE_SIZE,
                                                                  ?ERX_VIRTIO_INPUT_EVENT_SIZE)),
        {ok, _Features} ?= step(negotiate, erx_device:negotiate(Dev, ?WANTED)),
        {ok, Reads} ?= reads(Dev, erx_virtio_input_core:queries(), #{}),
        {ok, Fold} ?= step(configuration, erx_virtio_input_core:new(Reads)),
        {ok, Irq} ?= step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        ok ?= step(post, post_all(Dev, Queue, ?QUEUE_SIZE)),
        {ok, #state{dev = Dev, irq = Irq, queue = Queue, path = Path, fold = Fold}}
    end.

%% Whether the transport's first registers say a virtio-mmio version 2 input device; device
%% id 0 is an empty transport, virtio's name for no device.
identify(Dev) ->
    case {erx_device:read(Dev, magic), erx_device:read(Dev, version), erx_device:read(Dev, device_id)} of
        {?ERX_VIRTIO_MMIO_MAGIC, ?ERX_VIRTIO_MMIO_VERSION, ?ERX_VIRTIO_ID_INPUT} -> ok;
        {?ERX_VIRTIO_MMIO_MAGIC, ?ERX_VIRTIO_MMIO_VERSION, 0} -> {error, no_device};
        {?ERX_VIRTIO_MMIO_MAGIC, ?ERX_VIRTIO_MMIO_VERSION, Other} -> {error, {device_id, Other}};
        {?ERX_VIRTIO_MMIO_MAGIC, Version, _} -> {error, {version, Version}};
        {Magic, _, _} -> {error, {magic, Magic}}
    end.

%% The registers read for each query, as erx_virtio_input_core:new/1 takes them.
reads(_Dev, [], Reads) ->
    {ok, Reads};
reads(Dev, [Query | Rest], Reads) ->
    case answer(Dev, Query, ?GENERATION_TRIES) of
        {ok, Read} -> reads(Dev, Rest, Reads#{Query => Read});
        {error, _} = Error -> Error
    end.

%% One query: select and subsel written, the only fields the driver may write (virtio 1.2,
%% section 5.8.5.1), then size, abs_min and abs_max read between two equal reads of the
%% configuration generation, so the three come from one configuration (section 4.2.2.2).
answer(_Dev, Query, 0) ->
    {error, {generation, Query}};
answer(Dev, {Select, Subsel} = Query, Tries) ->
    ok = erx_device:write(Dev, select, Select),
    ok = erx_device:write(Dev, subsel, Subsel),
    Before = erx_device:read(Dev, config_generation),
    Read = {erx_device:read(Dev, size), erx_device:read(Dev, abs_min), erx_device:read(Dev, abs_max)},
    case erx_device:read(Dev, config_generation) of
        Before -> {ok, Read};
        _Changed -> answer(Dev, Query, Tries - 1)
    end.

%% Every entry of the queue posted, each one event long; the tag is the entry's index, for
%% nothing but the completion it comes back with.
post_all(_Dev, _Queue, 0) ->
    ok;
post_all(Dev, Queue, N) ->
    case post(Dev, Queue, N - 1) of
        ok -> post_all(Dev, Queue, N - 1);
        {error, _} = Error -> Error
    end.

post(Dev, Queue, Tag) ->
    erx_device:post(Dev, Queue, Tag, [{in, ?ERX_VIRTIO_INPUT_EVENT_SIZE}]).

step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

%% The driver answers no call and takes no cast: it only sends.
handle_call(_Request, _From, State) ->
    {reply, {error, einval}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

%% A delivery of the line: the interrupt acknowledged and the line answered before the
%% drain, so a buffer the device returns after the drain fires the line again; then every
%% buffer the device returned, folded, routed and posted again in order.
handle_info({erx_irq, Dev, ?IRQ_LINE}, State = #state{dev = Dev, irq = Irq, queue = Queue}) ->
    Status = erx_device:read(Dev, interrupt_status),
    ok = erx_device:write(Dev, interrupt_ack, Status band 3),
    ok = erx_irq_line:ack(Irq),
    case drain(Dev, Queue, State) of
        {ok, Next} -> {noreply, Next};
        {error, Reason, Next} -> {stop, {device, Reason}, Next}
    end;
handle_info(_Other, State) ->
    {noreply, State}.

%% The device's returned buffers until it has none left; a broken queue or a buffer that
%% cannot be posted again is the device's failure.
drain(Dev, Queue, State) ->
    case erx_device:complete(Dev, Queue) of
        {ok, []} -> {ok, State};
        {ok, Returned} ->
            case route(Returned, State) of
                {ok, Next} -> drain(Dev, Queue, Next);
                {error, _, _} = Error -> Error
            end;
        {error, broken} -> {error, broken, State}
    end.

%% Each buffer's event folded, its records routed, then the buffer posted again.
route([], State) ->
    {ok, State};
route([{Tag, Bytes} | Rest], State = #state{dev = Dev, queue = Queue, path = Path, fold = Fold}) ->
    {Records, Next} = erx_virtio_input_core:fold(Bytes, Fold),
    lists:foreach(fun(Record) -> erx_winfs:input(Path, Record) end, Records),
    case post(Dev, Queue, Tag) of
        ok -> route(Rest, State#state{fold = Next});
        {error, Reason} -> {error, Reason, State#state{fold = Next}}
    end.

%% One line of the kernel log. The path is the record's, a device-tree node path the record
%% reader holds to the characters a device tree allows; every other value is an integer or
%% a fixed atom of this driver's, its core's or erx_device's, never bytes the device wrote.
log(Path, Format, Arguments) ->
    _ = erx_log:debug(["erx_virtio_input: ", Path, " ", io_lib:format(Format, Arguments)]),
    ok.
