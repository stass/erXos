%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bus_link).
-moduledoc """
The messages between a controller process and its bus process
(docs/design-usb.md, "The controller process" and "Ports, hubs and
devices: the bus core"): the one module that spells them, used by the bus
process, erx_usb_bus, and by the controller process on the other side, so
a change of shape is a change here alone.

The bus process attaches itself with attach/1 once it starts; the
controller answers `{root_ports, N}` when its start reaches the bus (the
design's start, step 4), and from then on sends the bus process its root
ports' events and the answers to its requests, each an event of
erx_usb_bus_core as the core names it. The bus process sends every request
with request/2: the bus core's root-hub operations, enumeration requests,
pipe resets and detaches as the core makes them, and an external hub's
port operations as `{control, Hub, {port, Target, Op}, Setup, Data}`, a
control request on the hub's EP0 whose tag takes the place of an
enumeration step. The controller builds each answer with reply/2, which
echoes the request's reference and tag, and never reads either from a
device's data.

Every message carries the module's tag, so the bus process takes from its
mailbox only what came this way.
""".

-export([attach/1, request/2, answer/2, reply/2, from_controller/1, from_bus/1]).

-export_type([request/0, answer/0]).

-doc "What the bus process asks of its controller.".
-type request() :: attach
                 | {port, root, erx_usb_bus_core:target(), erx_usb_bus_core:op()}
                 | {control, erx_usb_bus_core:ref(), erx_usb_bus_core:step() | port_tag(), <<_:64>>,
                    none | {in, pos_integer()}}
                 | {enable_slot, erx_usb_bus_core:ref(), erx_usb_bus_core:step()}
                 | {address, erx_usb_bus_core:ref(), erx_usb_bus_core:step(), map()}
                 | {evaluate_context, erx_usb_bus_core:ref(), erx_usb_bus_core:step(), map()}
                 | {configure_endpoints, erx_usb_bus_core:ref(), erx_usb_bus_core:step(), map()}
                 | {reset_pipe, erx_usb_bus_core:ref(), byte(), byte()}
                 | {detach, erx_usb_bus_core:ref()}.

-doc "An external hub's port operation, the tag of its control request and of the answer.".
-type port_tag() :: {port, erx_usb_bus_core:target(), erx_usb_bus_core:op()}.

-doc """
What the controller sends its bus process: the root hub's port count, then core events,
and the answers to an external hub's port operations.
""".
-type answer() :: {root_ports, 1..255} | erx_usb_bus_core:event()
                | {control_done, erx_usb_bus_core:ref(), port_tag(), {ok, binary()} | {error, term()}}.

-doc "Attaches the calling bus process to Controller.".
-spec attach(pid()) -> ok.
attach(Controller) ->
    request(Controller, attach).

-doc "Sends Request to Controller from the calling bus process.".
-spec request(pid(), request()) -> ok.
request(Controller, Request) ->
    Controller ! {?MODULE, self(), Request},
    ok.

-doc """
The answer to Request with Result, the event of erx_usb_bus_core that
names Request's reference and step, or the root hub's target, so the
controller builds every answer here.
""".
-spec reply(request(), term()) -> answer().
reply({port, root, Target, _Op}, Result) -> {port_done, root, Target, Result};
reply({control, Ref, Tag, _Setup, _Data}, Result) -> {control_done, Ref, Tag, Result};
reply({enable_slot, Ref, Step}, Result) -> {slot, Ref, Step, Result};
reply({address, Ref, Step, _Params}, Result) -> {addressed, Ref, Step, Result};
reply({evaluate_context, Ref, Step, _Context}, Result) -> {evaluated, Ref, Step, Result};
reply({configure_endpoints, Ref, Step, _Endpoints}, Result) -> {endpoints_configured, Ref, Step, Result};
reply({reset_pipe, Ref, Interface, Address}, Result) -> {pipe_reset, Ref, Interface, Address, Result}.

-doc "Sends Answer to Bus, from the controller side.".
-spec answer(pid(), answer()) -> ok.
answer(Bus, Answer) ->
    Bus ! {?MODULE, Answer},
    ok.

-doc "The answer a message to the bus process carries, or `none` for a message that did not come this way.".
-spec from_controller(term()) -> {ok, answer()} | none.
from_controller({?MODULE, Answer}) -> {ok, Answer};
from_controller(_Other) -> none.

-doc """
The bus process and the request a message to the controller carries, or `none` for a
message that did not come this way.
""".
-spec from_bus(term()) -> {ok, pid(), request()} | none.
from_bus({?MODULE, Bus, Request}) -> {ok, Bus, Request};
from_bus(_Other) -> none.
