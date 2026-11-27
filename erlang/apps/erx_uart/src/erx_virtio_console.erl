%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_virtio_console).
-moduledoc """
The driver of port 0 of a virtio console (virtio 1.2, section 5.3), for a
line the line service serves on QEMU `virt` (docs/design-bluetooth.md, "The
line on QEMU `virt`"). It speaks the driver's messages that erx_console
documents to the one process it serves, its owner, the line, as erx_pl011
does, and passes bytes unchanged both ways: it parses none.

Its start runs one sequence, so a fresh start resets the device its
predecessor left: erx_device:open/1 on the record, the transport's magic,
version and device id, queue_create/4 for the receive and the transmit
queue, negotiate/2, which resets the device and returns every buffer it
held, erx_irq_line:attach/2, and every buffer of the receive queue posted.
It negotiates none of the type's features, so the device has port 0 alone
and no control queue (section 5.3.2). A step that fails fails the start,
which leaves the line broken with no driver.

**Receiving.** Each buffer the device returns on the receive queue holds
the bytes it wrote, as many as its used length says, which the device NIF's
ring core holds to the buffer's size; they go to the owner as
`{erx_console_input, Bytes}` and the buffer is posted again.

**Sending.** `{erx_console_output, From, Bytes}` hands erx_virtio_console_core
a write, which cuts it into buffers of the transmit queue; the owner hears
`{erx_console_written, From}` once the device has returned all of them, in
the order the writes came. A transmit queue the device never empties holds
the write until the line's next reset ends the driver.

Each delivery of the interrupt line acknowledges the device's interrupt,
takes every buffer the device returned on the transmit queue and one batch
of the receive queue's, and asks itself for the next batch, so a device
that keeps the receive queue full never holds up the owner's writes. A
queue that breaks, or a buffer that cannot be posted, ends the driver,
which leaves the line broken with no driver until its next reset. Nothing the device writes to memory reaches the log:
a failed start logs the record's path and the step's reason, and a crash
report shows no byte of the controller's traffic (format_status/1).
""".

-behaviour(gen_server).

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-include("generated/erx_abi.hrl").

-define(RX, ?ERX_VIRTIO_CONSOLE_QUEUE_RECEIVE).
-define(TX, ?ERX_VIRTIO_CONSOLE_QUEUE_TRANSMIT).
%% Each queue's entries and buffer size: 64 KiB each way, so a write the size of the
%% line's receive buffer is in the device at once.
-define(QUEUE_SIZE, 16).
-define(BUFFER, 4096).
-define(IRQ_LINE, 0).
%% None of the type's own features (section 5.3.3): no size, no ports beyond 0, no
%% emergency write.
-define(WANTED, 0).

-record(state, {dev :: erx_device:device(), irq :: erx_irq_line:handle(),
                rx :: erx_device:queue(), tx :: erx_device:queue(),
                owner :: pid(), core :: erx_virtio_console_core:state()}).

-doc """
The driver of the virtio console of the device record Spec, for Owner, linked
to the caller.
""".
-spec start_link(erx_device:spec(), Owner :: pid()) -> {ok, pid()} | {error, term()}.
start_link(Spec, Owner) ->
    gen_server:start_link(?MODULE, {Spec, Owner}, []).

-doc false.
init({#{path := Path} = Spec, Owner}) ->
    case try start_device(Spec, Owner) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, State} ->
            {ok, State};
        {error, no_device} ->
            {stop, {not_driven, no_device}};
        {error, Reason} ->
            log(Path, "not driven: ~0p", [Reason]),
            {stop, {not_driven, Reason}}
    end.

%% Open, identify, the two queues, negotiate, attach and the receive posts, in that order;
%% each step's refusal is the sequence's error and stops it.
start_device(Spec, Owner) ->
    maybe
        {ok, Dev} ?= erx_step:step(open, erx_device:open(Spec)),
        ok ?= erx_virtio:identify(fun(Register) -> erx_device:read(Dev, Register) end, ?ERX_VIRTIO_ID_CONSOLE),
        {ok, Rx} ?= erx_step:step(queue_create,
                                  erx_device:queue_create(Dev, ?RX, ?QUEUE_SIZE, ?BUFFER)),
        {ok, Tx} ?= erx_step:step(queue_create,
                                  erx_device:queue_create(Dev, ?TX, ?QUEUE_SIZE, ?BUFFER)),
        {ok, _Features} ?= erx_step:step(negotiate, erx_device:negotiate(Dev, ?WANTED)),
        {ok, Irq} ?= erx_step:step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        State = #state{dev = Dev, irq = Irq, rx = Rx, tx = Tx, owner = Owner,
                       core = erx_virtio_console_core:new(?QUEUE_SIZE, ?BUFFER)},
        ok ?= try lists:foreach(fun(Tag) -> post_receive(State, Tag) end, lists:seq(0, ?QUEUE_SIZE - 1))
              catch throw:{device, Reason} -> {error, {post, Reason}}
              end,
        {ok, State}
    end.

-doc false.
handle_call(_Request, _From, State) ->
    {reply, {error, einval}, State}.

-doc false.
handle_cast(_Request, State) ->
    {noreply, State}.

%% Every event runs whole or throws {device, Reason}, the device's failure, which is
%% caught here alone and ends the driver.
-doc false.
handle_info(Event, State) ->
    try event(Event, State) of
        Next -> {noreply, Next}
    catch
        throw:{device, Reason} -> {stop, {device, Reason}, State}
    end.

%% A write from the owner: handed to the core, then whatever may go out goes out.
event({erx_console_output, From, Bytes}, State = #state{core = Core}) ->
    {Done, Next} = erx_virtio_console_core:write(From, iolist_to_binary(Bytes), Core),
    written(Done, State),
    send(State#state{core = Next});
%% A delivery of the line: the interrupt acknowledged and the line answered before the
%% drain, so a buffer the device returns after the drain fires the line again. The
%% transmit queue is reclaimed first, so the owner's write is answered whatever the
%% device sends, then one batch of input is taken.
event({erx_irq, Dev, ?IRQ_LINE}, State = #state{dev = Dev, irq = Irq}) ->
    Status = erx_device:read(Dev, interrupt_status),
    ok = erx_device:write(Dev, interrupt_ack, Status band 3),
    ok = erx_irq_line:ack(Irq),
    take_input(send(take_returned(State)));
%% The rest of the device's input, after a batch that did not empty the receive queue.
event({?MODULE, more}, State) ->
    take_input(State);
event(_Other, State) ->
    State.

%% One batch of the buffers the device returned on the receive queue, at most what
%% complete/2 hands back at once: each one's bytes to the owner, in order, and the
%% buffer posted again. When the device returned some, the driver asks itself for
%% more, so the owner's writes and the transmit side are served between batches
%% however fast the device fills the queue.
take_input(State = #state{dev = Dev, rx = Rx}) ->
    case erx_device:complete(Dev, Rx) of
        {ok, []} ->
            State;
        {ok, Returned} ->
            lists:foreach(fun({Tag, Bytes}) -> deliver(State, Bytes), post_receive(State, Tag) end, Returned),
            self() ! {?MODULE, more},
            State;
        {error, broken} ->
            throw({device, {receive_queue, broken}})
    end.

%% A buffer of no bytes has nothing to deliver.
deliver(_State, <<>>) ->
    ok;
deliver(#state{owner = Owner}, Bytes) ->
    Owner ! {erx_console_input, Bytes},
    ok.

post_receive(#state{dev = Dev, rx = Rx}, Tag) ->
    posted(erx_device:post(Dev, Rx, Tag, [{in, ?BUFFER}]), receive_post).

%% Every transmit buffer the device returned, handed back to the core; the writes done
%% are answered.
take_returned(State = #state{dev = Dev, tx = Tx, core = Core}) ->
    case erx_device:complete(Dev, Tx) of
        {ok, []} ->
            State;
        {ok, Returned} ->
            {Done, Next} = erx_virtio_console_core:returned([Tag || {Tag, _} <- Returned], Core),
            written(Done, State),
            take_returned(State#state{core = Next});
        {error, broken} ->
            throw({device, {transmit_queue, broken}})
    end.

%% The pieces the core lets go out, each posted as one buffer the device reads.
send(State = #state{dev = Dev, tx = Tx, core = Core}) ->
    {Posts, Next} = erx_virtio_console_core:posts(Core),
    lists:foreach(fun({Tag, Piece}) -> posted(erx_device:post(Dev, Tx, Tag, [{out, Piece}]), transmit_post) end,
                  Posts),
    State#state{core = Next}.

posted(ok, _What) -> ok;
posted({error, Reason}, What) -> throw({device, {What, Reason}}).

written(Done, #state{owner = Owner}) ->
    lists:foreach(fun(From) -> Owner ! {erx_console_written, From} end, Done).

%% A crash report shows neither the bytes the core holds nor a message's: they are the
%% controller's traffic, which carries keys (docs/design-bluetooth.md, "Security"). The
%% driver runs in the system domain, where no report filter runs (docs/design-log.md,
%% "Reports carry no term"): because the module exports format_status/1, proc_lib leaves
%% the mailbox and the dictionary out, and erx_report:status/2 empties the log and shows
%% the reason's leading atom; the state keeps its handles and owner, a write its length.
%% sys:get_state/1 and sys:log/2 still show the state whole, to the system domain's code.
-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun state/1, message => fun message/1}).

state(#state{} = State) -> erx_report:fields(State, [{#state.core, redacted}]);
state(_State) -> hidden.

message({erx_console_output, From, Bytes}) when is_binary(Bytes) ->
    {erx_console_output, From, erx_report:bytes(Bytes)};
message(_Message) ->
    hidden.

%% One line of the kernel log. The path is the record's, a device-tree node path the record
%% reader holds to the characters a device tree allows; every other value is an atom of
%% this driver's, erx_virtio's or erx_device's, or an integer read from the transport's
%% identification registers, never bytes the device wrote to memory.
log(Path, Format, Arguments) ->
    _ = erx_log:debug(["erx_virtio_console: ", Path, " ", io_lib:format(Format, Arguments)]),
    ok.
