%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_xhci).
-moduledoc """
The controller process (docs/design-usb.md, "The controller process"): one per
xHCI host controller, the controller child of its bus group, erx_usb_bus_sup,
started as `{erx_xhci, start_link, [Spec]}` on the controller's device record.
Its pure core, erx_xhci_core, decides everything; this process only feeds it
events and performs its actions, so the core's moduledoc is the contract.

**Events.** Four kinds of message reach the core: the bus process's requests
(erx_usb_bus_link), a function's requests on its pipes (erx_usb_pipe), the
controller's interrupt, `{erx_irq, Dev, Line}`, and the one timer, armed at the
core's next_deadline/1 after every message and fed as `expired`. A message of
any other shape, a timer already superseded among them, is not an event and is
dropped. Every sender is a process of the USB domain itself (its bus process,
its functions, the line's owner), so no message crosses a domain and none
arrives as `{erx_origin, D, Msg}`.

**Actions** are performed in the order the core gives them. Those the device
NIF answers give the core its next event: a register read gives `{read,
Words}`, the install `{negotiated, Result}`, a pass over the event ring
`{completed, Result}`, a queue's state `{queue_state, Pipe, Report}`, and a
post the NIF refuses `{refused, Tag, Reason}`. A step's answers, in the
order of the calls that gave them, are stepped before any other event: before
the answers still waiting from an earlier step and before any message is
taken, so the core sees `{queue_state, Pipe, Report}` before any other event,
as it requires, and no interrupt or request between a call and its answer. `{fail, Reason}`, which the core gives
alone, ends the process with Reason; its supervisor's restart resets the
controller, and the exit unbinds the interrupt line, which masks it.

**The device NIF.** Every call this process makes on the device is in the
section "The device NIF's TRB ring form" below, so a change of the NIF's
shapes is an edit there alone. The core names registers abstractly; that
section maps each name to the NIF's: a register by its SVD name in lower
case, and an instance of an array or of a repeated capability as `{Name,
Index}`, Index counted from 0, so port n's PORTSC is `{portsc, n - 1}` and the
I-th supported-protocol capability's REVISION `{revision, I - 1}`.
""".
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-define(IRQ_LINE, 0).

%% How long a `pci` facet call may take: the PCIe domain plans and writes one function.
-define(PCI_TIMEOUT_MS, 5000).

-record(controller, {place :: none | {non_neg_integer(), byte(), 0..31, 0..7},
                     dev :: erx_device:device(),
                     irq :: erx_irq_line:handle(),
                     bus = none :: none | pid(),
                     core :: erx_xhci_core:state(),
                     timer = none :: none | {reference(), At :: integer()}}).

-doc "Starts the controller process of the device record Spec, linked to the caller.".
-spec start_link(erx_device:spec()) -> {ok, pid()} | {error, term()}.
start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

-doc false.
init(Spec) ->
    maybe
        ok ?= erx_step:step(pci_open, pci(Spec, open)),
        {ok, Dev} ?= erx_step:step(open, erx_device:open(Spec)),
        {ok, Irq} ?= erx_step:step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        {ok, #controller{place = place(Spec), dev = Dev, irq = Irq, core = erx_xhci_core:new()}, {continue, start}}
    else
        {error, Reason} -> {stop, Reason}
    end.

-doc false.
handle_continue(start, C) ->
    {noreply, run([{start, bound(C)}], C)}.

-doc false.
handle_call(_Request, _From, C) ->
    {reply, {error, badarg}, C}.

-doc false.
handle_cast(_Request, C) ->
    {noreply, C}.

-doc false.
handle_info(Message, C) ->
    case event(Message, C) of
        {Event, Received} -> {noreply, run([Event], Received)};
        none -> {noreply, C}
    end.

%% The core's event a message carries, with the process's state as it records the
%% message, or `none` for a message that is not one: the bus process's attach is
%% where the process learns where the bus's answers go.
event({erx_irq, Dev, ?IRQ_LINE}, C = #controller{dev = Dev}) ->
    {interrupt, C};
event({timeout, Ref, expired}, C = #controller{timer = {Ref, _At}}) ->
    {expired, C#controller{timer = none}};
event(Message, C) ->
    case {erx_usb_bus_link:from_bus(Message), erx_usb_pipe:from_function(Message)} of
        {{ok, Bus, attach}, none} -> {{bus, attach}, C#controller{bus = Bus}};
        {{ok, _Bus, Request}, none} -> {{bus, Request}, C};
        {none, {ok, From, Request}} -> {{pipe, From, Request}, C};
        {none, none} -> none
    end.

%% Steps the core on each event in turn and performs its actions; the answers the
%% NIF gives to them are stepped next, ahead of the events already waiting, and the
%% timer is armed once none is left.
run([], C) ->
    armed(C);
run([Event | Waiting], C = #controller{core = Core}) ->
    {Next, Actions} = erx_xhci_core:step(Event, erlang:monotonic_time(millisecond), Core),
    Answers = lists:flatmap(fun(Action) -> perform(Action, C) end, Actions),
    run(Answers ++ Waiting, C#controller{core = Next}).

%% Performs Action; answers the events it gives the core, none for an action the
%% NIF does not answer.
perform({command, Tag, Command}, C) -> posted(Tag, post_command(C, Tag, Command));
perform({transfer, Pipe, Tag, Transfer}, C) -> posted(Tag, post_transfer(C, Pipe, Tag, Transfer));
perform({queue_state, Pipe}, C) -> [{queue_state, Pipe, queue_state(C, Pipe)}];
perform({read, Registers}, C) -> [{read, maps:from_list([{Register, read(C, Register)} || Register <- Registers])}];
perform({write, Register, Word}, C) -> ok = write(C, Register, Word), [];
perform(negotiate, C) -> [{negotiated, negotiate(C, 0)}];
perform({negotiate, continue}, C) -> [{negotiated, negotiate(C, continue)}];
perform(complete, C) -> [{completed, complete(C)}];
perform(ack, #controller{irq = Irq}) -> ok = erx_irq_line:ack(Irq), [];
perform({bus, Answer}, #controller{bus = Bus}) -> ok = erx_usb_bus_link:answer(Bus, Answer), [];
perform({send, To, Message}, _C) -> To ! Message, [];
perform({log, What}, _C) -> logger:notice(#{usb => xhci, what => What}), [];
perform({fail, Reason}, _C) -> exit(Reason).

posted(_Tag, ok) -> [];
posted(Tag, {error, Reason}) -> [{refused, Tag, Reason}].

%% The one timer at the core's next deadline: kept while the deadline stands,
%% replaced when it moves, cancelled when there is none. A superseded timer's
%% message names another reference and is dropped.
armed(C = #controller{core = Core, timer = Timer}) ->
    case {erx_xhci_core:next_deadline(Core), Timer} of
        {At, {_Ref, At}} ->
            C;
        {none, Timer} ->
            cancel(Timer),
            C#controller{timer = none};
        {At, Timer} ->
            cancel(Timer),
            C#controller{timer = {erlang:start_timer(At, self(), expired, [{abs, true}]), At}}
    end.

cancel(none) -> ok;
cancel({Ref, _At}) -> erlang:cancel_timer(Ref, [{async, true}, {info, false}]).

%% The device NIF's TRB ring form (docs/design-usb.md, "The TRB ring form" and
%% "Registers at offsets the controller reports"): every call the process makes on
%% the device. The design states post/4, complete/2, negotiate/2 and elements/2;
%% it names neither complete/2's second argument, here the event ring, nor the
%% query of a queue's state, here queue_state/2; negotiate/2 begins a negotiation
%% with the wanted features, none here, or carries one on with `continue`, as the
%% core says, and its `{ok, Features}` is the core's `ok`.

%% The extended capabilities the NIF bound at open.
bound(#controller{dev = Dev}) ->
    #{legacy => erx_device:elements(Dev, bios_owned) =:= 1, protocols => erx_device:elements(Dev, revision)}.

post_command(#controller{dev = Dev}, Tag, Command) -> erx_device:post(Dev, command, Tag, Command).

post_transfer(#controller{dev = Dev}, Pipe, Tag, Transfer) -> erx_device:post(Dev, Pipe, Tag, Transfer).

complete(#controller{dev = Dev}) -> erx_device:complete(Dev, events).

queue_state(#controller{dev = Dev}, Pipe) -> erx_device:queue_state(Dev, Pipe).

negotiate(C = #controller{dev = Dev}, Wanted) ->
    case erx_device:negotiate(Dev, Wanted) of
        {ok, _Features} -> ok;
        reset -> master(C);
        Refused -> Refused
    end.

%% The function's PCIe side (docs/design-pcie.md, "Who programs what, and when"), for a
%% controller that is a PCIe function, whose record names its place: `open` before the
%% device is opened, so its window decodes and it masters nothing while the driver resets
%% it, and `master` once the negotiation answers `reset`, its reset ended and its MSI-X
%% table written, through the domain's `pci` facet; the negotiation then goes on at once to
%% the install, whose registers make the controller read and write memory. A controller
%% that is no PCIe function has neither, and goes on as well.
place(Spec) -> maps:get(place, Spec, none).

pci(Spec, Request) -> pci_call(place(Spec), Request).

master(C = #controller{place = Place}) ->
    case pci_call(Place, master) of
        ok -> negotiate(C, continue);
        {error, Reason} -> {error, {pci_master, Reason}}
    end.

pci_call(none, _Request) ->
    ok;
pci_call(Place, Request) ->
    case erx:cap(pci) of
        Facet when is_pid(Facet) -> facet_call(Facet, {Request, Place});
        undefined -> {error, no_pci_facet}
    end.

%% A facet that does not answer in time, or has ended, refuses the call as one that
%% answers {error, _} does, so the controller fails through its one path.
facet_call(Facet, Call) ->
    try
        gen_server:call(Facet, Call, ?PCI_TIMEOUT_MS)
    catch
        exit:{Reason, {gen_server, call, _}} -> {error, {pci, Reason}}
    end.

read(#controller{dev = Dev}, Register) -> erx_device:read(Dev, nif_register(Register)).

write(#controller{dev = Dev}, Register, Word) -> erx_device:write(Dev, nif_register(Register), Word).

nif_register({portsc, Port}) -> {portsc, Port - 1};
nif_register({legacy, Semaphore}) -> Semaphore;
nif_register({protocol, Index, Register}) -> {Register, Index - 1};
nif_register(Register) when is_atom(Register) -> Register.
