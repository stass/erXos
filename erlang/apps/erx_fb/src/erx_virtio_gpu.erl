%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The virtio-gpu display driver (docs/design-display.md, "The display device"): the
%% process that owns a virtio-mmio GPU device over erx_device, registered as erx_fb, and
%% implements erx_display for erx_screen, its one caller. Its decisions are
%% erx_virtio_gpu_core's; this module performs what the core's machines ask for and holds
%% the state between calls.
%%
%% Its start and every restart run one sequence, so a restarted process finds the device as
%% its predecessor left it and resets it: erx_device:open/1 on the record, the transport's
%% magic, version and device id, queue_create/4 for the control queue, negotiate/2, which
%% resets the device, forgets every resource it held and returns every buffer, and
%% erx_irq_line:attach/2. The bring-up (erx_virtio_gpu_core:setup_next/2) then asks the
%% display's size, makes the screen image's region with erx_device:region/3, which the
%% NIF keeps for the boot so a restart gets the same memory back, creates the 2D resource,
%% attaches the region as its backing and sets scanout 0 to it. The screen image is an
%% erx_memdraw:wrap/4 image over the region, the one way Erlang writes it; erx_screen
%% composes into it and nothing else writes it. A transport with no device behind it gives
%% no process; a device that fails any step gives one line in the kernel log and no
%% process: init/1 returns ignore, so the domain goes on without a screen.
%%
%% flush/3 posts the core's flush plan as one frame, a transfer and a flush per changed
%% rectangle with the fence on the last, and returns when every request is answered ok:
%% from then on the device reads nothing of the image until the next flush. Any failure
%% of the device while a frame runs (an answer that fails its check, a broken queue, a
%% full queue with nothing in flight, no answer within the deadline) ends the process
%% after answering its caller; the supervisor's restart resets the device and shows the
%% scanout again, and erx_screen, which monitors the driver, repaints. The device's own
%% memory is never posted by a client: erx_screen hands flush/3 only the screen image,
%% since the device is unconfined and reports direct false, and the driver refuses any
%% other image.

-module(erx_virtio_gpu).
-behaviour(gen_server).
-behaviour(erx_display).

-export([start_link/1]).
-export([info/1, flush/3, power/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-include("generated/erx_abi.hrl").

-define(QUEUE, ?ERX_VIRTIO_GPU_QUEUE_CONTROL).
%% The control queue's entries, one descriptor per segment: 32 requests of two segments,
%% or fewer of three, so a frame of 16 rectangles, two requests each, posts without waiting
%% for the queue.
-define(QUEUE_SIZE, 64).
-define(IRQ_LINE, 0).
%% The screen image is the device's region 0.
-define(REGION, 0).
%% The features wanted beyond VERSION_1: none, the 2D device's request set.
-define(WANTED, 0).
%% How long a frame may take, from its first post to its last answer, before the driver ends.
-define(ANSWER_DEADLINE_MS, 5000).
-define(U64_MAX, 16#ffffffffffffffff).

%% dev, irq, queue, screen and info are fixed once init/1 returns; geometry and resource are
%% the core's ready(); tag is the next request's tag and fence the next frame's fence_id.
-record(state, {dev, irq, queue, screen, info :: erx_display:info(),
                geometry :: erx_virtio_gpu_core:geometry(), resource :: pos_integer(),
                tag = 0 :: 0..?U64_MAX, fence = 1 :: 0..?U64_MAX}).

%% The driver of the display record Spec, registered as erx_fb.
-spec start_link(term()) -> {ok, pid()} | ignore | {error, term()}.
start_link(Spec) ->
    gen_server:start_link({local, erx_fb}, ?MODULE, Spec, []).

%% erx_display's callbacks, as erx_screen calls them: the driver's state there is its pid.
-spec info(pid()) -> erx_display:info().
info(Driver) ->
    gen_server:call(Driver, info).

%% A failed flush is answered {error, Reason}, which raises here in the caller, and the
%% driver then ends, as the moduledoc says.
-spec flush([erx_display:rect()], erx_memdraw:image(), pid()) -> {ok, pid()}.
flush(Rects, Image, Driver) ->
    ok = gen_server:call(Driver, {flush, Rects, Image}, infinity),
    {ok, Driver}.

%% The 2D device has no panel to dim or turn off; the screen stays as erx_screen leaves it.
-spec power(on | dim | off, pid()) -> {ok, pid()}.
power(_Level, Driver) ->
    {ok, Driver}.

%% Any exception of the sequence, a bug or a NIF that changed, is one line and no process as
%% well. An empty transport is no display, a configuration and not a fault, so it has no line.
init(Spec) ->
    case try start_device(Spec) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State = #state{geometry = #{width := Width, height := Height}}} ->
            log("scanout 0 at ~bx~b", [Width, Height]),
            {ok, State};
        {error, no_device} ->
            ignore;
        {error, Reason} ->
            log("the display device is not driven: ~0p", [Reason]),
            ignore
    end.

%% Open, identify, queue_create, negotiate and attach, in that order, then the bring-up;
%% each step's refusal is the sequence's error and stops it.
start_device(Spec) ->
    maybe
        {ok, Dev} ?= step(open, erx_device:open(Spec)),
        ok ?= identify(Dev),
        {ok, Queue} ?= step(queue_create, erx_device:queue_create(Dev, ?QUEUE, ?QUEUE_SIZE,
                                                                  erx_virtio_gpu_core:buffer_size())),
        {ok, _Features} ?= step(negotiate, erx_device:negotiate(Dev, ?WANTED)),
        {ok, Irq} ?= step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        State0 = #state{dev = Dev, irq = Irq, queue = Queue},
        {Action, Setup} = erx_virtio_gpu_core:setup_start(?ERX_MEM_CONTIGUOUS_MAX),
        {ok, Ready, State1} ?= setup(Action, Setup, State0),
        screen(Ready, State1)
    end.

identify(Dev) ->
    Read = fun(Register) -> erx_device:read(Dev, Register) end,
    case erx_virtio_gpu_core:identify(Read(magic), Read(version), Read(device_id)) of
        ok -> ok;
        %% Device id 0 is an empty transport: virtio's name for no device.
        {error, {device_id, 0}} -> {error, no_device};
        Refused -> Refused
    end.

%% The bring-up's actions performed until it is ready or stops: each request as a frame of
%% one, the region by the NIF.
setup({post, Request}, Setup, State) ->
    case run_frame([Request], State) of
        {ok, [Answer], Next} -> setup_step(Setup, {answer, Answer}, Next);
        {error, Reason, _State} -> {error, {setup, Reason}}
    end;
setup({region, Bytes}, Setup, State = #state{dev = Dev}) ->
    case erx_device:region(Dev, ?REGION, Bytes) of
        {ok, Region} -> setup_step(Setup, {region, Region}, State);
        {error, Reason} -> {error, {region, Reason}}
    end;
setup({ready, Ready}, _Setup, State) ->
    {ok, Ready, State};
setup({stop, Reason}, _Setup, _State) ->
    {error, Reason}.

setup_step(Setup, Event, State) ->
    {Action, Next} = erx_virtio_gpu_core:setup_next(Setup, Event),
    setup(Action, Next, State).

%% The screen image over the region, and the info erx_screen reads.
screen(#{geometry := Geometry = #{width := Width, height := Height}, region := Region, resource := Resource,
         chan := Chan}, State) ->
    case erx_memdraw:wrap(Region, 0, {0, 0, Width, Height}, Chan) of
        {ok, Screen} ->
            Info = #{width => Width, height => Height, chan => <<"x8r8g8b8">>, screen => Screen,
                     partial => true, direct => false},
            {ok, State#state{screen = Screen, info = Info, geometry = Geometry, resource = Resource}};
        {error, Reason} ->
            {error, {wrap, Reason}}
    end.

step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

handle_call(info, _From, State = #state{info = Info}) ->
    {reply, Info, State};
handle_call({flush, Rects, Screen}, _From, State = #state{screen = Screen}) when length(Rects) >= 0 ->
    #state{geometry = Geometry, resource = Resource, fence = Fence} = State,
    {ok, Requests} = erx_virtio_gpu_core:flush_plan(Rects, Geometry, Resource, Fence),
    case run_frame(Requests, State#state{fence = (Fence + 1) band ?U64_MAX}) of
        {ok, _Answers, Next} ->
            {reply, ok, Next};
        {error, Reason, Next} ->
            log("the device failed a flush: ~0p", [Reason]),
            {stop, {device, Reason}, {error, Reason}, Next}
    end;
%% A flush of anything but the screen image, or of rectangles that are not a proper list, and any
%% other call: refused, not crashed on, so no process that reaches the driver ends it.
handle_call({flush, _Rects, _Image}, _From, State) ->
    {reply, {error, einval}, State};
handle_call(_Other, _From, State) ->
    {reply, {error, einval}, State}.

handle_cast(_Other, State) ->
    {noreply, State}.

%% A line that fires while no frame runs: every answer was taken by the frame that waited
%% for it, so the drain finds nothing; anything it does find is a request no frame posted,
%% which the device made up, and the driver ends.
handle_info({erx_irq, Dev, ?IRQ_LINE}, State = #state{dev = Dev}) ->
    case acknowledge_and_drain(State) of
        {ok, []} -> {noreply, State};
        {ok, Stray} -> {stop, {device, {stray, length(Stray)}}, State};
        {error, broken} -> {stop, {device, broken}, State}
    end;
handle_info(_Other, State) ->
    {noreply, State}.

%% One frame of Requests run to its end through erx_virtio_gpu_core:frame_step/2, with the
%% tag the state carries; the state comes back with the next frame's tag. The frame has
%% one deadline, fixed here, so deliveries of the line that bring no answer do not extend it.
run_frame(Requests, State = #state{tag = Tag}) ->
    Frame = erx_virtio_gpu_core:frame_start(Requests, Tag),
    Deadline = erlang:monotonic_time(millisecond) + ?ANSWER_DEADLINE_MS,
    perform(erx_virtio_gpu_core:frame_step(Frame, next), Deadline, State).

perform({{post, Tag, Segments}, Frame}, Deadline, State = #state{dev = Dev, queue = Queue}) ->
    case erx_device:post(Dev, Queue, Tag, Segments) of
        ok -> perform(erx_virtio_gpu_core:frame_step(Frame, next), Deadline, State);
        {error, full} -> perform(erx_virtio_gpu_core:frame_step(Frame, {full, Tag}), Deadline, State);
        {error, broken} -> {error, broken, State}
    end;
perform({wait, Frame}, Deadline, State) ->
    case await(Deadline, State) of
        {ok, Completions} -> perform(erx_virtio_gpu_core:frame_step(Frame, {answers, Completions}), Deadline, State);
        {error, Reason} -> {error, Reason, State}
    end;
perform({{done, Answers, Tag}, _Frame}, _Deadline, State) ->
    {ok, Answers, State#state{tag = Tag}};
perform({{stop, Reason}, _Frame}, _Deadline, State) ->
    {error, Reason, State}.

%% The next delivery of the line before the frame's deadline, then what the device
%% returned; a delivery may be spurious, which returns nothing, and the frame then waits
%% again, against the same deadline.
await(Deadline, State = #state{dev = Dev}) ->
    receive
        {erx_irq, Dev, ?IRQ_LINE} -> acknowledge_and_drain(State)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
        {error, timeout}
    end.

%% Acknowledge the device's interrupt, then answer the line, before draining, so an answer
%% that lands after the drain fires the line again; then every completion until none is left.
acknowledge_and_drain(#state{dev = Dev, irq = Irq, queue = Queue}) ->
    Status = erx_device:read(Dev, interrupt_status),
    ok = erx_device:write(Dev, interrupt_ack, Status band 3),
    ok = erx_irq_line:ack(Irq),
    drain(Dev, Queue, []).

drain(Dev, Queue, Taken) ->
    case erx_device:complete(Dev, Queue) of
        {ok, []} -> {ok, lists:append(lists:reverse(Taken))};
        {ok, Completions} -> drain(Dev, Queue, [Completions | Taken]);
        {error, broken} -> {error, broken}
    end.

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% driver's, its core's or erx_device's, never bytes the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_fb: ", io_lib:format(Format, Arguments)]),
    ok.
