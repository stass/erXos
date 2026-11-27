%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bus_core).
-moduledoc """
The bus process's pure core: the topology of one controller's bus, its
hubs' ports and the devices on them (docs/design-usb.md, "Ports, hubs and
devices: the bus core" and "Hubs").

step/3 takes one event, the time it is handled at, in milliseconds, and the
state, and answers the actions the bus process performs, in order, and the
next state. Every timer is a deadline in the state; the last action, when
any deadline is pending, is `{deadline, At}`, the earliest of them, and the
process answers it with the event `expired` at or after that time.

**Hubs.** The root hub and every external hub are kept alike: a map of
ports, the queue of ports (and `hub`, the hub itself) whose status is still
to be read, each at most once and in the order they were named, the one port
operation in flight, the change bits still to be cleared after a read, and
the pid of the hub function whose report is being handled, to which
`{handled, Hub, From}` goes once the queue is empty, so a restarted hub
function never takes its predecessor's answer. A hub's port operations run
one at a time, chosen afresh whenever none is in flight: first the clears of
the last read, then powering an `off` port, then disabling a port given up,
then the reset of the port holding the address-zero turn, then the next
status read, which waits until the hub's power-good time has passed. So a
hub has at most one operation and one report in flight however fast it
reports, and nothing is queued but its own ports, each at most once. A read
that saw changes queues its target again, so the target is read again after
their clears, behind the reads already queued, and leaves the queue only on
a read that sees none: a change that latched between a read and its clear,
which the clear takes away unseen, is in the next read's status.

**Ports** are in the states of the design's port table; a state carries
its deadline and, from `enumerating` on, its occupant's reference, so a
port cannot hold a device it is not enumerating or running. A status
read decides by agreement: a connection change, or a status that says
connected on an `empty` port or disconnected on an occupied one, first
detaches the occupant and then moves the port to `settling` or `empty`,
as FreeBSD's `uhub_reattach_port` frees the old child before it reads the
fresh status (sys/dev/usb/usb_hub.c:625-637, release/15.1.0, 95719d8a); a
status that agrees with the state leaves the port as it is.

**Attempts and over-current.** A port's history outlives its states: a
settled port starts an enumeration attempt, moving to `waiting`, only while
fewer than `usb_port_attempts_max` started on it in the last
`usb_port_attempt_window_ms`, and is held in `settling` until its oldest
attempt leaves the window otherwise, so a device that toggles its connection
costs that port at most three Enable Slots a minute. A hub's ports start their
histories afresh when the hub is attached again, which the attempts of the
hub's own port bound. An over-current change is counted, and answered with
`{log, Hub, Port, over_current}` once per attempt.

**Power.** A hub's ports start `off`, and a hub more than five tiers below
the root, `usb_hub_depth_max`, keeps them so. The core powers each, one request
at a time, and the hub's power-good time, `bPwrOn2PwrGood` times
`usb_power_good_unit_ms` plus FreeBSD's `usb_extra_power_up_ms`
(usb_hub.c:1280-1281, usb.h:124 and 624), runs from the last one's answer;
FreeBSD waits it after each port (usb_hub.c:1512),
and once after the last is enough, since every port's own time started
earlier. The root hub's is FreeBSD's xHCI root hub value,
`usb_root_power_good_units` (sys/dev/usb/controller/xhci.c:3533).

**The address-zero turn** is not a field: the port that holds it is the
one in `resetting`, `recovering`, `enumerating` before its address is
answered, or `disabling` after holding it: a port given up while its
device may still be enabled is disabled at its hub before the turn moves
on. The turn goes to the `waiting` port that arrived first only
when no port holds it, so at most one device is in the default state on
the bus, and a port that leaves those states, by any path, a detach of
its hub included, has released it.

**Detach** is one function, detach_device/2, and update_port/4, the one
writer of a port's state but for a reset's send, which moves an unoccupied
port to another, is its only caller: a port whose new state
does not keep its occupant has the occupant detached first, so the state
holds a device exactly while a port holds its reference and no path that
moves a port can forget its device. It detaches every device
below a hub first, deepest first, drops each device and hub from the
state and answers `{detach, Ref}` for each, which tells the bus process
to stop the device's functions, free its places and have the controller
drop the reference and tear down its slot. Answers naming a reference or
a hub the state no longer holds are ignored, so a device removed in the
middle of any step leaves nothing behind.

**Enumeration.** At the end of its reset recovery a port's device gets a
reference and walks the steps of the design's enumeration, each one
request whose answer is the next event, named by the port's state
`{enumerating, Ref, Step}`: `{enable_slot, Ref, Step}`; `{address, Ref,
Step, Params}` with the route, the root port, the speed and the
transaction translator, whose answer releases the turn; `{address_settle,
At}`, FreeBSD's settle of `usb_set_address_settle_ms`, awaiting no answer; at full speed the
device descriptor's first 8 bytes and, when its EP0 packet size is not 8,
`{evaluate_context, Ref, Step, ...}`; the whole device descriptor; the
configuration's header and then all of it, which erx_usb_claim turns into
the device's functions; SET_CONFIGURATION; for a hub, SET_INTERFACE to its
multi-TT setting when the claim selected it, and the hub descriptor's
head; and one `{configure_endpoints, Ref, Step, ...}` adding every claimed
pipe, with the hub fields for a hub. Control transfers go out as
`{control, Ref, Step, Setup, Data}`. On the last answer the port is
`running`, `{start, Ref, Functions}` starts the device's functions, each
paired with its run number, 1, and a hub enters with its ports `off`.

Every request names its device's reference and the step it was sent at,
and its answer echoes both: `{Kind, Ref, Step, Result}`. request/4 is the
one maker of a request, and it sets the port's step from the same value
it writes into the request; a device passes each step at most once, so a
reference and a step name one request. An answer is taken only while its
port is at the step it names and that step awaits its kind, so an answer
repeated, or arriving after its step was left, is stale by construction
and ignored, without the core counting the requests in flight. Any failed
answer, or descriptor erx_usb_desc or the claim refuses, gives the port up
with the step and the reason, through one throw caught in
device_answered/6.

**A function's end.** `{function_ended, Ref, Interface, Run, Reason}`,
which the bus process sends when instance Run of a running function ends
while its device stays, with the reason its process ended or the Reason
of the `{error, Reason}` its start answered. An end as `{shutdown, {unusable, Why}}`, a function that cannot
drive its interface, is final, as a FreeBSD probe that answers ENXIO: the
run keeps Why for the device's inspection record, nothing is reset or
started again, and the end counts toward no bound, so the device's other
functions run on. Any other end resets the function's pipes other than
EP0 one at a time,
`{reset_pipe, Ref, Interface, Address}` each, the next sent only on the
last one's `ok`, and `{start, Ref, [{Function, Run + 1}]}` starts the
function again once every one has answered, so its new instance never
meets a transfer, a halt or a toggle of the old one. A function starts
again at most `usb_function_restarts_max` times in any
`usb_function_restart_window_ms`, counted as a port's attempts are, by
admit/4; an end past them, or a reset that fails, gives its device's port
up.

A function's run is in one of three states: `running`; ended, with the
pipes it has still to reset, the first of them in flight; or
`{unusable, Why}`. It keeps the number of the instance last started. Every
start carries its instance's number and the bus process echoes it in that
instance's end and, for a hub function, in its reports, `{changed, Ref,
Set, Run, From}`. An end or a report is taken only while its function is
running with the number it names, so one from an instance that ended,
repeated or late, is stale by construction and ignored, however the bus
process orders them. What the numbers cannot give is an end that never
comes: the bus process sends an instance's end at least once, when its
process ends and when its start fails, so no function is left running
with nothing behind it. A reset's answer for a pipe not in flight is ignored,
and a reset's answer is stale by construction too, since the controller
answers every reset once and a pipe's next reset is sent only after its
last answer was taken. A hub function's end leaves the report it was
handling answered to no one, and its next instance's first report reads
every port again, leaving each whose status agrees with its state as it
is.

**Diagnostics.** A port is logged as given up, `{log, Hub, Port, {failed,
Reason}}`, when update_port/4 moves it into `disabling` or `disabled` from
a state that is neither; only a connection change leaves those two, so a
port's failure is logged once per connection.

Every status word comes from a device and is decoded by erx_usb_hub_core,
which refuses a malformed one; a malformed status or answer, like a failed
port operation, detaches an external hub. The root hub's operations are the
controller process's register accesses and do not fail. An external hub's
go out as control requests on its EP0, spelled by hub_request/2, the hub
class's GET_STATUS, SET_FEATURE and CLEAR_FEATURE (usb.h:229-264), and the
request's answer comes back as the operation's by hub_answer/2.
""".

-export([new/1, step/3, ports/1, histories/1, devices/1, hub_request/2, hub_answer/2, unusable/1]).

-export_type([state/0, event/0, action/0, hub_id/0, ref/0, target/0, op/0, port_state/0, port_history/0, step/0, run/0,
              run_no/0, address_params/0]).

-include("generated/erx_abi.hrl").

-doc "A device's reference: fresh for every device the bus ever enumerates.".
-type ref() :: {device, pos_integer()}.

-doc "A hub: the root hub, or an external hub by its device's reference.".
-type hub_id() :: root | ref().

-type port_no() :: 1..255.
-type target() :: port_no() | hub.
-type ms() :: integer().
-type speed() :: erx_usb_claim:speed().

-doc """
A port's state, with its deadline and, while it has one, its occupant. A
resetting port's reset is `to_send` until its hub sends it, `sent` until the
hub answers, then `{poll, At}` until its next status read is due and
`read_queued` until that read is answered; its deadline runs from the send.
`disabling` is a port given up whose hub has yet to answer its disable, with
whether it holds the address-zero turn meanwhile.
""".
-type port_state() :: off | empty | {settling, ms()} | waiting
                    | {resetting, to_send} | {resetting, ms(), sent | {poll, ms()} | read_queued}
                    | {disabling, term(), boolean()}
                    | {recovering, ms(), speed()}
                    | {enumerating, ref(), step()}
                    | {running, ref()}
                    | {disabled, term()}.

-doc """
What a port keeps across its states: the start times of its enumeration
attempts within the last `usb_port_attempt_window_ms`, oldest first, at most
`usb_port_attempts_max` of them; its over-current changes counted; and whether
one has been logged since its last attempt started.
""".
-type port_history() :: #{attempts := [ms()], over_current_changes := non_neg_integer(),
                          over_current_logged := boolean()}.

-type op() :: power_on | get_status | reset | disable | {clear, atom()}.

-doc """
A step of a device's enumeration, in order; each awaits one answer, of the
kind awaits/1 names, and that answer echoes the step its request named. A
device passes each step at most once: no step is retried, so a retry would
be a step of its own. `device_head` and `ep0_packet` are a full-speed
device's alone, `set_interface` a multi-TT hub's and `hub_descriptor` a
hub's.
""".
-type step() :: enabling_slot | addressing | {address_settle, ms()} | device_head | ep0_packet | device
              | config_head | configuration | set_configuration | set_interface | hub_descriptor
              | configuring_endpoints.

-type answer_kind() :: slot | addressed | control_done | evaluated | endpoints_configured.

-type event() :: {port_event, port_no()}
               | {changed, ref(), erx_usb_hub_core:change_set(), run_no(), From :: term()}
               | {port_done, hub_id(), target(), ok | {ok, binary()} | {ok, binary(), byte()} | {error, term()}}
               | {slot, ref(), step(), {ok, pos_integer()} | {error, term()}}
               | {addressed, ref(), step(), {ok, pos_integer()} | {error, term()}}
               | {control_done, ref(), step(), {ok, binary()} | {error, term()}}
               | {evaluated | endpoints_configured, ref(), step(), ok | {error, term()}}
               | {function_ended, ref(), Interface :: byte(), run_no(), Reason :: term()}
               | {pipe_reset, ref(), Interface :: byte(), Address :: byte(), ok | {error, term()}}
               | expired.

-doc "An enumeration request as the core makes it, before request/4 names its device and step.".
-type request() :: enable_slot | {address, address_params()}
                 | {control, Setup :: <<_:64>>, none | {in, pos_integer()}}
                 | {evaluate_context, #{ep0_packet := pos_integer()}}
                 | {configure_endpoints, endpoints()}.

-type endpoints() :: #{add := [erx_usb_claim:pipe()],
                       hub := none | #{ports := 1..?ERX_USB_HUB_PORTS_MAX, think_time := 0..3,
                                       multi_tt := boolean()}}.

-type address_params() :: #{slot := pos_integer(), root_port := port_no(), route := [port_no()],
                            speed := speed(),
                            tt := none | #{hub_slot := pos_integer(), port := port_no(), multi := boolean()}}.

-type action() :: {port, hub_id(), target(), op()}
                | {handled, hub_id(), From :: term()}
                | {enable_slot, ref(), step()}
                | {address, ref(), step(), address_params()}
                | {control, ref(), step(), Setup :: <<_:64>>, none | {in, pos_integer()}}
                | {evaluate_context, ref(), step(), #{ep0_packet := pos_integer()}}
                | {configure_endpoints, ref(), step(), endpoints()}
                | {start, ref(), [{erx_usb_claim:function_(), run_no()}]}
                | {reset_pipe, ref(), Interface :: byte(), Address :: byte()}
                | {detach, ref()}
                | {log, hub_id(), port_no(), over_current | {failed, term()}}
                | {deadline, ms()}.

%% A hub; `ports` and `histories` have the same keys, every port of the hub, since
%% hub/5 makes both and nothing adds or removes a port but the hub's own removal.
-type hub() :: #{parent := root | {hub, full | high}, power_good := ms(),
                 power := powering | {good_at, ms()} | good | unpowered, multi_tt := boolean(),
                 ports := #{port_no() => port_state()}, histories := #{port_no() => port_history()},
                 pending := [target()],
                 op := none | {target(), op()}, clears := [{target(), atom()}], reporter := none | term()}.

-doc """
A device: its place, speed, slot and translator, and what its enumeration
has read so far: its device descriptor, its claimed functions and, for a
hub, its hub descriptor; and, once configured, its functions' runs by
interface.
""".
-type device() :: #{port := {hub_id(), port_no()}, route := [port_no(), ...], speed := speed(),
                    slot := none | pos_integer(),
                    tt := none | {hub_id(), port_no()},
                    descriptor := none | erx_usb_desc:device(),
                    functions := [erx_usb_claim:function_()],
                    runs := #{Interface :: byte() => run()},
                    hub := none | erx_usb_desc:hub()}.

-doc """
A claimed function's run: `running`; ended and with the addresses of its
pipes still to reset, in order, the first of them in flight; or ended unusable
for good, with the function's reason; the number of the instance last started;
and the times of its counted ends within the last
`usb_function_restart_window_ms`, oldest first, at most
`usb_function_restarts_max` of them.
""".
-type run() :: #{state := running | {resetting, [byte(), ...]} | {unusable, term()}, number := run_no(),
                 ends := [ms()]}.

-doc "A function instance's number: 1 for the function's first start, one more for each start again.".
-type run_no() :: pos_integer().

-opaque state() :: #{hubs := #{hub_id() => hub()}, devices := #{ref() => device()},
                     waiting := [{hub_id(), port_no()}], next := ref()}.

-doc "The bus of a controller whose root hub has RootPorts ports, every port `off`.".
-spec new(port_no()) -> state().
new(RootPorts) when is_integer(RootPorts), RootPorts >= 1, RootPorts =< 255 ->
    #{hubs => #{root => hub(root, RootPorts, ?ERX_USB_ROOT_POWER_GOOD_UNITS, false, powering)},
      devices => #{}, waiting => [], next => {device, 1}}.

-doc "The next state on Event, handled at Now, and the actions the bus process performs.".
-spec step(event(), ms(), state()) -> {state(), [action()]}.
step(Event, Now, State0) ->
    {Actions, State} = event(Event, Now, State0),
    settle(Now, Actions, State).

-doc "Every port's state, by its hub and number, for inspection.".
-spec ports(state()) -> #{{hub_id(), port_no()} => port_state()}.
ports(#{hubs := Hubs}) ->
    maps:from_list([{{Id, N}, Port} || Id := #{ports := Ports} <- Hubs, N := Port <- Ports]).

-doc "Every port's history, by its hub and number, for inspection.".
-spec histories(state()) -> #{{hub_id(), port_no()} => port_history()}.
histories(#{hubs := Hubs}) ->
    maps:from_list([{{Id, N}, History} || Id := #{histories := Histories} <- Hubs, N := History <- Histories]).

-doc "An external hub's port operation on Target as the control request on its EP0: the setup packet and its data stage.".
-spec hub_request(target(), op()) -> {<<_:64>>, none | {in, pos_integer()}}.
hub_request(hub, get_status) ->
    get_status(?ERX_USB_RECIPIENT_DEVICE, 0);
hub_request(hub, {clear, Change}) ->
    hub_feature(?ERX_USB_REQUEST_CLEAR_FEATURE, ?ERX_USB_RECIPIENT_DEVICE, hub_change_feature(Change), 0);
hub_request(N, get_status) ->
    get_status(?ERX_USB_RECIPIENT_OTHER, N);
hub_request(N, power_on) ->
    hub_feature(?ERX_USB_REQUEST_SET_FEATURE, ?ERX_USB_RECIPIENT_OTHER, ?ERX_USB_PORT_FEATURE_POWER, N);
hub_request(N, reset) ->
    hub_feature(?ERX_USB_REQUEST_SET_FEATURE, ?ERX_USB_RECIPIENT_OTHER, ?ERX_USB_PORT_FEATURE_RESET, N);
hub_request(N, disable) ->
    hub_feature(?ERX_USB_REQUEST_CLEAR_FEATURE, ?ERX_USB_RECIPIENT_OTHER, ?ERX_USB_PORT_FEATURE_ENABLE, N);
hub_request(N, {clear, Change}) ->
    hub_feature(?ERX_USB_REQUEST_CLEAR_FEATURE, ?ERX_USB_RECIPIENT_OTHER, port_change_feature(Change), N).

-doc """
The answer to an external hub's port operation Op, from its control
request's: GET_STATUS answers its bytes, which the status decoders check;
any other operation answers `ok` once its request completes.
""".
-spec hub_answer(op(), {ok, binary()} | {error, term()}) -> ok | {ok, binary()} | {error, term()}.
hub_answer(get_status, Result) -> Result;
hub_answer(_Op, {ok, _Bytes}) -> ok;
hub_answer(_Op, {error, Reason}) -> {error, Reason}.

%% GET_STATUS answers a status word and a change word, 16 bits each.
get_status(Recipient, Index) ->
    {erx_usb_setup:packet(?ERX_USB_REQUEST_DIR_IN bor ?ERX_USB_REQUEST_TYPE_CLASS bor Recipient,
                          ?ERX_USB_REQUEST_GET_STATUS, 0, Index, 4),
     {in, 4}}.

hub_feature(Request, Recipient, Feature, Index) ->
    {control, Setup, none} = control(?ERX_USB_REQUEST_TYPE_CLASS, Recipient, Request, Feature, Index),
    {Setup, none}.

%% The feature that clears each change erx_usb_hub_core names.
hub_change_feature(local_power) -> ?ERX_USB_HUB_FEATURE_C_LOCAL_POWER;
hub_change_feature(over_current) -> ?ERX_USB_HUB_FEATURE_C_OVER_CURRENT.

port_change_feature(connection) -> ?ERX_USB_PORT_FEATURE_C_CONNECTION;
port_change_feature(enabled) -> ?ERX_USB_PORT_FEATURE_C_ENABLE;
port_change_feature(suspend) -> ?ERX_USB_PORT_FEATURE_C_SUSPEND;
port_change_feature(over_current) -> ?ERX_USB_PORT_FEATURE_C_OVER_CURRENT;
port_change_feature(reset) -> ?ERX_USB_PORT_FEATURE_C_RESET.

-doc """
The end of a function that cannot drive its interface, for the reason Why:
the one exit reason the core takes as final (ended/6), which a function
builds here alone.
""".
-spec unusable(term()) -> {shutdown, {unusable, term()}}.
unusable(Why) -> {shutdown, {unusable, Why}}.

-doc "Every device the bus holds, by its reference, for inspection.".
-spec devices(state()) -> #{ref() => device()}.
devices(#{devices := Devices}) -> Devices.

%% Events.

event({port_event, N}, _Now, State) ->
    {[], with_hub(root, fun(Hub = #{ports := Ports, pending := P}) when is_map_key(N, Ports) ->
                                Hub#{pending := queued([N], P)};
                           (Hub) ->
                                Hub
                        end, State)};
event({changed, Ref, Set, Run, From}, _Now, State) ->
    case hub_run(Ref, State) of
        #{state := running, number := Run} ->
            {[], with_hub(Ref, fun(Hub = #{pending := P, ports := Ports}) ->
                                       Named = [T || T <- Set, T =:= hub orelse is_map_key(T, Ports)],
                                       Hub#{pending := queued(Named, P), reporter := From}
                               end, State)};
        _Stale ->
            {[], State}
    end;
event({port_done, Id, Target, Result}, Now, State = #{hubs := Hubs}) ->
    case Hubs of
        #{Id := Hub = #{op := {Target, Op}}} ->
            answered(Id, Target, Op, Result, Now, State#{hubs := Hubs#{Id := Hub#{op := none}}});
        #{} ->
            {[], State}
    end;
event({Kind, Ref, Step, Result}, Now, State)
  when Kind =:= slot; Kind =:= addressed; Kind =:= control_done; Kind =:= evaluated;
       Kind =:= endpoints_configured ->
    device_answered(Ref, Step, Kind, Result, Now, State);
event({function_ended, Ref, Interface, Run, Reason}, Now, State) ->
    function_ended(Ref, Interface, Run, Reason, Now, State);
event({pipe_reset, Ref, Interface, Address, Result}, _Now, State) ->
    pipe_reset(Ref, Interface, Address, Result, State);
event(expired, Now, State = #{hubs := Hubs}) ->
    lists:foldl(fun(Id, Acc) -> expire_hub(Id, Now, Acc) end, {[], State}, lists:sort(maps:keys(Hubs))).

%% Enumeration.

%% The answer of kind Kind to device Ref's request at Step, taken only while its
%% port is at that step and the step awaits that kind: a reference and a step name
%% one request, so an answer for a step left, of another kind or for a device gone
%% is stale and ignored. A failed answer, or a descriptor or claim refused, gives
%% the port up with the step and the reason.
device_answered(Ref, Step, Kind, Result, Now, State = #{devices := Devices}) ->
    case Devices of
        #{Ref := Device = #{port := {Id, N}}} ->
            case port(Id, N, State) of
                {enumerating, Ref, Step} ->
                    case awaits(Step) of
                        Kind ->
                            try
                                enumerated(Step, Ref, Device, Result, Now, State)
                            catch
                                throw:{?MODULE, refused, Reason} -> fail_device(Ref, {Step, Reason}, State)
                            end;
                        _Other ->
                            {[], State}
                    end;
                _ ->
                    {[], State}
            end;
        #{} ->
            {[], State}
    end.

-spec awaits(step()) -> answer_kind() | none.
awaits(enabling_slot) -> slot;
awaits(addressing) -> addressed;
awaits({address_settle, _At}) -> none;
awaits(device_head) -> control_done;
awaits(ep0_packet) -> evaluated;
awaits(device) -> control_done;
awaits(config_head) -> control_done;
awaits(configuration) -> control_done;
awaits(set_configuration) -> control_done;
awaits(set_interface) -> control_done;
awaits(hub_descriptor) -> control_done;
awaits(configuring_endpoints) -> endpoints_configured.

%% A step's successful answer moves the device to its next step, in the order of
%% FreeBSD's usb_alloc_device (docs/design-usb.md, the enumeration's steps).
%% Only a full-speed EP0 has a packet size to learn, so only a full-speed device
%% reads the device descriptor's first 8 bytes first, as usbd_setup_device_desc
%% does (sys/dev/usb/usb_request.c:1984-2026, release/15.1.0, 95719d8a).
enumerated(enabling_slot, Ref, Device, Result, _Now, State) ->
    Slotted = Device#{slot := value(Result)},
    request(Ref, addressing, {address, address_params(Slotted, State)}, put_device(Ref, Slotted, State));
enumerated(addressing, Ref, _Device, Result, Now, State) ->
    _Address = value(Result),
    set_step(Ref, {address_settle, Now + ?ERX_USB_SET_ADDRESS_SETTLE_MS}, State);
enumerated(device_head, Ref, _Device, Result, _Now, State) ->
    case ep0_packet(value(erx_usb_desc:device_head(value(Result)))) of
        ?ERX_USB_EP0_PACKET_FULL_FIRST -> read_device(Ref, State);
        Packet -> request(Ref, ep0_packet, {evaluate_context, #{ep0_packet => Packet}}, State)
    end;
enumerated(ep0_packet, Ref, _Device, Result, _Now, State) ->
    ok = value(Result),
    read_device(Ref, State);
enumerated(device, Ref, Device = #{speed := Speed}, Result, _Now, State) ->
    Descriptor = value(erx_usb_desc:device(value(Result))),
    no_superspeed_hub(Descriptor, Speed),
    request(Ref, config_head, get_descriptor(?ERX_USB_DESCRIPTOR_TYPE_CONFIGURATION,
                                             ?ERX_USB_CONFIGURATION_DESCRIPTOR_SIZE),
            put_device(Ref, Device#{descriptor := Descriptor}, State));
enumerated(config_head, Ref, _Device, Result, _Now, State) ->
    Total = value(erx_usb_desc:configuration_length(value(Result))),
    request(Ref, configuration, get_descriptor(?ERX_USB_DESCRIPTOR_TYPE_CONFIGURATION, Total), State);
enumerated(configuration, Ref, Device = #{speed := Speed, descriptor := Descriptor}, Result, _Now, State) ->
    Configuration = #{value := Value} = value(erx_usb_desc:configuration(value(Result))),
    Functions = value(erx_usb_claim:functions(Speed, Descriptor, Configuration)),
    request(Ref, set_configuration, control(?ERX_USB_REQUEST_TYPE_STANDARD, ?ERX_USB_RECIPIENT_DEVICE,
                                            ?ERX_USB_REQUEST_SET_CONFIGURATION, Value, 0),
            put_device(Ref, Device#{functions := Functions}, State));
enumerated(set_configuration, Ref, #{functions := Functions}, Result, _Now, State) ->
    _ = value(Result),
    case hub_function(Functions) of
        none ->
            configure_endpoints(Ref, State);
        #{alternate := 0} ->
            read_hub_descriptor(Ref, State);
        #{interface := Interface, alternate := Alternate} ->
            request(Ref, set_interface, control(?ERX_USB_REQUEST_TYPE_STANDARD, ?ERX_USB_RECIPIENT_INTERFACE,
                                                ?ERX_USB_REQUEST_SET_INTERFACE, Alternate, Interface), State)
    end;
enumerated(set_interface, Ref, _Device, Result, _Now, State) ->
    _ = value(Result),
    read_hub_descriptor(Ref, State);
enumerated(hub_descriptor, Ref, Device, Result, _Now, State) ->
    Hub = value(erx_usb_desc:hub(value(Result))),
    configure_endpoints(Ref, put_device(Ref, Device#{hub := Hub}, State));
enumerated(configuring_endpoints, Ref, Device, Result, _Now, State) ->
    ok = value(Result),
    configured(Ref, Device, State).

%% The value of a step's answer or decoding; a failure leaves through refuse/1.
value({ok, Value}) -> Value;
value(ok) -> ok;
value({error, Reason}) -> refuse(Reason).

%% The one throw device_answered/6 catches, for a step that refuses.
-spec refuse(term()) -> no_return().
refuse(Reason) -> throw({?MODULE, refused, Reason}).

%% A full-speed EP0's packet size from bMaxPacketSize0: a power of two from 8 to
%% usb_ep0_packet_full_max, the sizes FreeBSD's fallback tries
%% (usb_request.c:1998-2011); any other value is not one to guess at.
ep0_packet(Packet) when Packet >= ?ERX_USB_DEVICE_DESCRIPTOR_HEAD, Packet =< ?ERX_USB_EP0_PACKET_FULL_MAX,
                        Packet band (Packet - 1) =:= 0 ->
    Packet;
ep0_packet(_Packet) ->
    refuse(malformed_descriptor).

%% A hub at SuperSpeed is refused at its device descriptor (docs/design-usb.md,
%% "Outside this design").
no_superspeed_hub(#{class := ?ERX_USB_CLASS_HUB}, super) -> refuse(superspeed_hub);
no_superspeed_hub(_Descriptor, _Speed) -> ok.

hub_function(Functions) ->
    case [F || F = #{driver := erx_usb_hub} <- Functions] of
        [Hub] -> Hub;
        [] -> none
    end.

%% The first request after the address's settle.
first_read(Ref, State = #{devices := Devices}) ->
    case maps:get(Ref, Devices) of
        #{speed := full} -> request(Ref, device_head, get_descriptor(?ERX_USB_DESCRIPTOR_TYPE_DEVICE,
                                                                     ?ERX_USB_DEVICE_DESCRIPTOR_HEAD), State);
        #{} -> read_device(Ref, State)
    end.

read_device(Ref, State) ->
    request(Ref, device, get_descriptor(?ERX_USB_DESCRIPTOR_TYPE_DEVICE, ?ERX_USB_DEVICE_DESCRIPTOR_SIZE), State).

%% The hub descriptor's 7-byte head holds every field the slot's hub fields take,
%% so its port bitmaps are not read (erx_usb_desc:hub/1).
read_hub_descriptor(Ref, State) ->
    request(Ref, hub_descriptor,
            {control, erx_usb_setup:packet(?ERX_USB_REQUEST_DIR_IN bor ?ERX_USB_REQUEST_TYPE_CLASS bor ?ERX_USB_RECIPIENT_DEVICE,
                                           ?ERX_USB_REQUEST_GET_DESCRIPTOR, ?ERX_USB_DESCRIPTOR_TYPE_HUB bsl 8, 0,
                                           ?ERX_USB_HUB_DESCRIPTOR_HEAD),
             {in, ?ERX_USB_HUB_DESCRIPTOR_HEAD}},
            State).

%% One Configure Endpoint adding every pipe the claimed functions need, with the
%% hub fields for a hub: the multi-TT flag only once its multi-TT setting was
%% selected (xHCI 4.5.2, as docs/design-usb.md cites it).
configure_endpoints(Ref, State = #{devices := Devices}) ->
    #{functions := Functions, hub := Hub} = maps:get(Ref, Devices),
    HubFields = case Hub of
                    none -> none;
                    #{ports := Ports, think_time := Think} -> #{ports => Ports, think_time => Think,
                                                                multi_tt => multi_tt(Functions)}
                end,
    request(Ref, configuring_endpoints,
            {configure_endpoints, #{add => [Pipe || #{pipes := Pipes} <- Functions, Pipe <- Pipes],
                                    hub => HubFields}},
            State).

multi_tt(Functions) ->
    #{alternate := Alternate} = hub_function(Functions),
    Alternate =:= ?ERX_USB_HUB_MULTI_TT_ALTERNATE.

%% The device configured: its port `running`, its functions started and running,
%% and a hub's ports added `off`.
configured(Ref, Device = #{port := {Id, N}, speed := Speed, route := Route, functions := Functions, hub := Hub},
           State0 = #{hubs := Hubs}) ->
    Runs = maps:from_list([{Interface, #{state => running, number => 1, ends => []}}
                           || #{interface := Interface} <- Functions]),
    State1 = put_device(Ref, Device#{runs := Runs}, State0),
    State = case Hub of
                none ->
                    State1;
                #{ports := Ports, power_good := Units} ->
                    Added = hub({hub, hub_speed(Speed)}, Ports, Units, multi_tt(Functions), hub_power(Route)),
                    State1#{hubs := Hubs#{Ref => Added}}
            end,
    Started = [{Function, Number} || Function = #{interface := Interface} <- Functions,
                                     #{number := Number} <- [maps:get(Interface, Runs)]],
    then([{start, Ref, Started}], set_port(Id, N, {running, Ref}, State)).

%% A function's end (docs/design-usb.md, "A function's end" and "Failure handling").

%% Function Interface of device Ref ended as Reason while the device stays. An end
%% named for a device gone, for a function not running or for an instance other
%% than the one running is stale.
function_ended(Ref, Interface, Run, Reason, Now, State) ->
    case find_run(Ref, Interface, State) of
        Current = #{state := running, number := Run} ->
            ended(Ref, Interface, Reason, Current, Now, drop_reporter(Ref, Interface, State));
        _Stale ->
            {[], State}
    end.

%% A function that cannot drive its interface ends unusable, which is final: the
%% run keeps the reason, nothing is reset or started, and the end counts toward no
%% bound, as a FreeBSD probe that answers ENXIO leaves its interface unattached.
%% Any other end, a crash or a failed transfer, resets the function's pipes and
%% starts it again, when fewer than usb_function_restarts_max of its ends fell in
%% the last usb_function_restart_window_ms; past them its device's port is given up,
%% the failure naming the end that went past them by end_name/1, since a function
%% that ends on a failed transfer leaves no crash report of its own.
ended(Ref, Interface, {shutdown, {unusable, Why}}, Current, _Now, State) ->
    {[], put_run(Ref, Interface, Current#{state := {unusable, Why}}, State)};
ended(Ref, Interface, End, Current = #{ends := Ends}, Now, State) ->
    case admit(Ends, Now, ?ERX_USB_FUNCTION_RESTARTS_MAX, ?ERX_USB_FUNCTION_RESTART_WINDOW_MS) of
        {admitted, Admitted} ->
            #{pipes := Pipes} = claimed(Ref, Interface, State),
            reset_next_or_start(Ref, Interface, [Address || #{address := Address} <- Pipes],
                                Current#{ends := Admitted}, State);
        {refused, _Until} ->
            fail_device(Ref, {function, Interface, {restarts, end_name(End)}}, State)
    end.

%% A function's end as the port's failure keeps it and the log shows it: names only
%% (docs/design-log.md, "Reports carry no term"). A shutdown made of atoms and
%% integers, such as {shutdown, {transfer, stall}}, is kept whole; a shutdown
%% carrying data the function held keeps its reason's leading atom alone; a start
%% that raised, {'EXIT', Reason} as the function supervisor answers it, keeps
%% Reason's leading atom, as {'EXIT', undef}; and any other end, a crash's reason
%% with its stack frames' arguments among them, is cut to its leading atom, each by
%% the report filter's own rule (erx_report).
end_name(End = {shutdown, Why}) ->
    case named(Why) of
        true -> End;
        false -> {shutdown, erx_report:reason_name(Why)}
    end;
end_name({'EXIT', Why}) ->
    {'EXIT', erx_report:reason_name(Why)};
end_name(End) ->
    erx_report:reason_name(End).

named(Term) when is_atom(Term); is_integer(Term) -> true;
named(Term) when is_tuple(Term) -> lists:all(fun named/1, tuple_to_list(Term));
named(_Term) -> false.

%% The answer to the reset of pipe Address of ended function Interface, taken only
%% while that reset is in flight: on `ok` the next pipe's reset or the function's
%% start; otherwise its device's port is given up.
pipe_reset(Ref, Interface, Address, Result, State) ->
    case find_run(Ref, Interface, State) of
        Current = #{state := {resetting, [Address | Left]}} ->
            case Result of
                ok -> reset_next_or_start(Ref, Interface, Left, Current, State);
                {error, Reason} -> fail_device(Ref, {function, Interface, {reset_pipe, Reason}}, State)
            end;
        _NotInFlight ->
            {[], State}
    end.

%% An ended function's next pipe reset, or, with none left, its start again as
%% the next instance.
reset_next_or_start(Ref, Interface, [], Current = #{number := Number}, State) ->
    {[{start, Ref, [{claimed(Ref, Interface, State), Number + 1}]}],
     put_run(Ref, Interface, Current#{state := running, number := Number + 1}, State)};
reset_next_or_start(Ref, Interface, Left = [Address | _], Current, State) ->
    {[{reset_pipe, Ref, Interface, Address}], put_run(Ref, Interface, Current#{state := {resetting, Left}}, State)}.

%% A hub function's end: the report its hub was handling is the ended instance's,
%% so it is answered to no one; the next instance's first report names every port.
drop_reporter(Ref, Interface, State) ->
    case claimed(Ref, Interface, State) of
        #{driver := erx_usb_hub} -> with_hub(Ref, fun(Hub) -> Hub#{reporter := none} end, State);
        #{} -> State
    end.

find_run(Ref, Interface, #{devices := Devices}) ->
    case Devices of
        #{Ref := #{runs := #{Interface := Run}}} -> Run;
        #{} -> none
    end.

%% The run of hub Ref's hub function, or `none` for a device the bus does not
%% hold or holds but not as a configured hub.
hub_run(Ref, State = #{devices := Devices}) ->
    Functions = case Devices of
                    #{Ref := #{functions := Claimed}} -> Claimed;
                    #{} -> []
                end,
    case hub_function(Functions) of
        #{interface := Interface} -> find_run(Ref, Interface, State);
        none -> none
    end.

put_run(Ref, Interface, Run, State = #{devices := Devices}) ->
    Device = #{runs := Runs} = maps:get(Ref, Devices),
    State#{devices := Devices#{Ref := Device#{runs := Runs#{Interface := Run}}}}.

claimed(Ref, Interface, #{devices := Devices}) ->
    #{functions := Functions} = maps:get(Ref, Devices),
    [Function] = [F || F = #{interface := I} <- Functions, I =:= Interface],
    Function.

%% Device Ref's next step, Step, and its one request, sent naming the device and the
%% step. The one maker of an enumeration request, so the step a request names, which
%% its answer echoes, is the step its port is set to.
request(Ref, Step, Request, State) ->
    then([sent(Ref, Step, Request)], set_step(Ref, Step, State)).

-spec sent(ref(), step(), request()) -> action().
sent(Ref, Step, enable_slot) -> {enable_slot, Ref, Step};
sent(Ref, Step, {address, Params}) -> {address, Ref, Step, Params};
sent(Ref, Step, {control, Setup, Data}) -> {control, Ref, Step, Setup, Data};
sent(Ref, Step, {evaluate_context, Context}) -> {evaluate_context, Ref, Step, Context};
sent(Ref, Step, {configure_endpoints, Endpoints}) -> {configure_endpoints, Ref, Step, Endpoints}.

get_descriptor(Type, Length) ->
    {control, erx_usb_setup:packet(?ERX_USB_REQUEST_DIR_IN bor ?ERX_USB_REQUEST_TYPE_STANDARD bor ?ERX_USB_RECIPIENT_DEVICE,
                                   ?ERX_USB_REQUEST_GET_DESCRIPTOR, Type bsl 8, 0, Length),
     {in, Length}}.

%% A request with no data stage.
control(Kind, Recipient, Request, Value, Index) ->
    {control, erx_usb_setup:packet(Kind bor Recipient, Request, Value, Index, 0), none}.

put_device(Ref, Device, State = #{devices := Devices}) ->
    State#{devices := Devices#{Ref := Device}}.

hub_speed(high) -> high;
hub_speed(_LowOrFull) -> full.

%% A hub more than usb_hub_depth_max tiers below the root keeps every port `off`:
%% a slot context's route string holds five tiers below the root port, four bits a
%% tier, so no device below such a hub could be addressed (docs/design-usb.md, "What
%% a device can make the domain spend"). An `unpowered` hub issues no port operation
%% (next_op's first clause), so its ports never leave `off` and its hub function's
%% first report stays unanswered: one transfer, then nothing.
hub_power(Route) when length(Route) > ?ERX_USB_HUB_DEPTH_MAX -> unpowered;
hub_power(_Route) -> powering.

hub(Parent, Ports, PowerGoodUnits, MultiTT, Power) ->
    #{parent => Parent, power_good => PowerGoodUnits * ?ERX_USB_POWER_GOOD_UNIT_MS + ?ERX_USB_EXTRA_POWER_UP_MS,
      power => Power, multi_tt => MultiTT,
      ports => maps:from_keys(lists:seq(1, Ports), off),
      histories => maps:from_keys(lists:seq(1, Ports), #{attempts => [], over_current_changes => 0,
                                                        over_current_logged => false}),
      pending => lists:seq(1, Ports),
      op => none, clears => [], reporter => none}.

%% The answer to a hub's port operation. A port that has moved on since the
%% operation was issued keeps its state.

answered(Id, N, power_on, ok, _Now, State) ->
    update_port(Id, N, fun(off) -> empty; (Other) -> Other end, State);
answered(Id, N, reset, ok, Now, State) ->
    update_port(Id, N, fun({resetting, At, sent}) -> {resetting, At, {poll, Now + ?ERX_USB_RESET_POLL_MS}};
                          (Other) -> Other
                       end, State);
answered(Id, N, disable, ok, _Now, State) ->
    update_port(Id, N, fun({disabling, Reason, _Held}) -> {disabled, Reason}; (Other) -> Other end, State);
answered(Id, Target, {clear, Change}, ok, _Now, State) ->
    {[], with_hub(Id, fun(Hub = #{clears := [{T, C} | Rest]}) when T =:= Target, C =:= Change ->
                              Hub#{clears := Rest}
                      end, State)};
%% A read that saw changes queues its target again, behind the targets already
%% queued, and the clears go first (next_op/3), so the target is read again after
%% its last clear: a change that latched between this read and its clear, which the
%% clear takes away unseen, is in that next read's status, as FreeBSD's
%% uhub_reattach_port reads the port after it clears the connection change
%% (usb_hub.c:620-637). Only a read with no changes takes the target off; a port
%% whose changes keep coming back is read in turn with the targets queued, and
%% holds back its hub's `handled` while they do.
answered(Id, Target, get_status, Result, Now, State) ->
    case decode(Id, Target, Result, State) of
        {ok, Status = #{changes := Changes}} ->
            Read = with_hub(Id, fun(Hub = #{pending := P}) when Changes =:= [] ->
                                        Hub#{pending := P -- [Target]};
                                   (Hub = #{pending := P}) ->
                                        Hub#{pending := queued([Target], P -- [Target]),
                                             clears := [{Target, C} || C <- Changes]}
                                end, State),
            read(Id, Target, Status, Now, Read);
        {error, Reason} ->
            fail_hub(Id, Target, Reason, State)
    end;
answered(Id, Target, _Op, {error, Reason}, _Now, State) ->
    fail_hub(Id, Target, Reason, State);
answered(Id, Target, _Op, _Malformed, _Now, State) ->
    fail_hub(Id, Target, malformed_answer, State).

decode(_Id, hub, {ok, Words}, _State) ->
    erx_usb_hub_core:hub_status(Words);
decode(root, _N, {ok, Words, SpeedId}, _State) ->
    erx_usb_hub_core:port_status(Words, {root, SpeedId});
decode(Id, _N, {ok, Words}, #{hubs := Hubs}) when Id =/= root ->
    #{Id := #{parent := Parent}} = Hubs,
    erx_usb_hub_core:port_status(Words, Parent);
decode(_Id, _Target, {error, Reason}, _State) ->
    {error, Reason};
decode(_Id, _Target, _Malformed, _State) ->
    {error, malformed_status}.

%% A hub's own status needs nothing beyond clearing its changes; a port's status
%% moves the port as the port table says, then its over-current change is counted.
read(_Id, hub, _HubStatus, _Now, State) ->
    {[], State};
read(Id, N, Status = #{connected := Connected}, Now, State) ->
    Port = port(Id, N, State),
    {Actions, Moved} = case connection_changed(Status, Port) of
                           true ->
                               Arrival = case Connected of
                                             true -> {settling, Now + ?ERX_USB_POWER_UP_DELAY_MS};
                                             false -> empty
                                         end,
                               set_port(Id, N, Arrival, State);
                           false ->
                               follow(Id, N, Port, Status, Now, State)
                       end,
    then(Actions, over_current(Id, N, Status, Moved)).

%% A connection change, or a status that disagrees with whether the port holds
%% something: nothing on an `empty` port, something on every other read port.
connection_changed(#{changes := Changes, connected := Connected}, Port) ->
    lists:member(connection, Changes) orelse Connected =/= (Port =/= empty).

%% An over-current change is counted for the port's inspection and logged once per
%% enumeration attempt: the first since the port's last attempt started is logged,
%% the rest only counted. attempt/4 rearms the log, so a device that reports
%% connection and over-current changes on every read logs at most one line more
%% than the attempts it is allowed. The hub, not software, cuts the port's power,
%% so the port only follows its status (usb_hub.c:1036-1046).
over_current(Id, N, #{changes := Changes}, State) ->
    case lists:member(over_current, Changes) of
        true ->
            History = #{over_current_changes := Count, over_current_logged := Logged} = history(Id, N, State),
            {[{log, Id, N, over_current} || not Logged],
             put_history(Id, N, History#{over_current_changes := Count + 1, over_current_logged := true}, State)};
        false ->
            {[], State}
    end.

%% A running port its hub disabled is given up; a resetting port's read after its
%% reset was answered decides the reset, as usbd_req_reset_port does
%% (usb_request.c:832-844): still resetting, read again in usb_reset_poll_ms; done with the
%% port disabled, given up; done at a speed the controller cannot run, disabled at
%% the hub; otherwise its recovery, usb_reset_recovery_ms.
follow(Id, N, {running, _Ref}, #{enabled := false}, _Now, State) ->
    set_port(Id, N, {disabled, port_disabled}, State);
follow(Id, N, {resetting, At, Phase}, Status, Now, State) when Phase =/= sent ->
    case Status of
        #{reset := true, changes := Changes} ->
            case lists:member(reset, Changes) of
                true -> reset_done(Id, N, Status, Now, State);
                false -> set_port(Id, N, {resetting, At, {poll, Now + ?ERX_USB_RESET_POLL_MS}}, State)
            end;
        #{} ->
            reset_done(Id, N, Status, Now, State)
    end;
follow(_Id, _N, _Port, _Status, _Now, State) ->
    {[], State}.

reset_done(Id, N, #{enabled := false}, _Now, State) ->
    set_port(Id, N, {disabled, reset_disabled}, State);
reset_done(Id, N, #{speed := unsupported}, _Now, State) ->
    give_up(Id, N, unsupported_speed, State);
reset_done(Id, N, #{speed := Speed}, Now, State) ->
    set_port(Id, N, {recovering, Now + ?ERX_USB_RESET_RECOVERY_MS, Speed}, State).

%% Deadlines.

expire_hub(Id, Now, {Actions, State = #{hubs := Hubs}}) ->
    case Hubs of
        #{Id := Hub = #{ports := Ports, power := Power}} ->
            Powered = case Power of
                          {good_at, At} when At =< Now -> Hub#{power := good};
                          _ -> Hub
                      end,
            lists:foldl(fun(N, {Acc, S}) -> then(Acc, expire_port(Id, N, maps:get(N, Ports), Now, S)) end,
                        {Actions, State#{hubs := Hubs#{Id := Powered}}}, lists:sort(maps:keys(Ports)));
        #{} ->
            {Actions, State}
    end.

expire_port(Id, N, {settling, At}, Now, State = #{waiting := Waiting}) when At =< Now ->
    case attempt(Id, N, Now, State) of
        {started, Started} -> set_port(Id, N, waiting, Started#{waiting := Waiting ++ [{Id, N}]});
        {held, Until} -> set_port(Id, N, {settling, Until}, State)
    end;
expire_port(Id, N, {resetting, At, _Phase}, Now, State) when At =< Now ->
    give_up(Id, N, reset_timeout, State);
expire_port(Id, N, {resetting, At, {poll, Poll}}, Now, State) when Poll =< Now ->
    Polled = with_hub(Id, fun(Hub = #{pending := P}) -> Hub#{pending := queued([N], P)} end, State),
    set_port(Id, N, {resetting, At, read_queued}, Polled);
expire_port(Id, N, {recovering, At, Speed}, Now, State) when At =< Now ->
    enumerate(Id, N, Speed, State);
expire_port(_Id, _N, {enumerating, Ref, {address_settle, At}}, Now, State) when At =< Now ->
    first_read(Ref, State);
expire_port(_Id, _N, _Port, _Now, State) ->
    {[], State}.

%% A settled port starts an enumeration attempt when fewer than usb_port_attempts_max
%% started in the last usb_port_attempt_window_ms (docs/design-usb.md, "What a device
%% can make the domain spend"); otherwise it is held until its oldest attempt leaves
%% the window. A started attempt rearms the port's over-current log (over_current/4).
attempt(Id, N, Now, State) ->
    History = #{attempts := Attempts} = history(Id, N, State),
    case admit(Attempts, Now, ?ERX_USB_PORT_ATTEMPTS_MAX, ?ERX_USB_PORT_ATTEMPT_WINDOW_MS) of
        {admitted, Admitted} ->
            {started, put_history(Id, N, History#{attempts := Admitted, over_current_logged := false}, State)};
        {refused, Until} ->
            {held, Until}
    end.

%% The window a port's attempts and a function's restarts are counted in: an event
%% at Now is admitted when fewer than Max of Times, the earlier ones' times oldest
%% first, fell in the last Window ms, and Times keeps only those and Now, so it never
%% holds more than Max however often the event recurs; otherwise it is refused until
%% the oldest of them leaves the window.
admit(Times, Now, Max, Window) ->
    Recent = [T || T <- Times, Now - T < Window],
    case length(Recent) < Max of
        true -> {admitted, Recent ++ [Now]};
        false -> {refused, hd(Recent) + Window}
    end.

%% A device for the port at the end of its reset recovery.
enumerate(Id, N, Speed, State = #{devices := Devices, next := Ref = {device, Next}}) ->
    Device = #{port => {Id, N}, route => route(Id, State) ++ [N], speed => Speed, slot => none,
               tt => translator(Id, N, Speed, State), descriptor => none, functions => [], runs => #{},
               hub => none},
    request(Ref, enabling_slot, enable_slot, State#{devices := Devices#{Ref => Device}, next := {device, Next + 1}}).

route(root, _State) -> [];
route(Ref, #{devices := Devices}) -> maps:get(route, maps:get(Ref, Devices)).

%% The high-speed hub port whose transaction translator serves a low- or
%% full-speed device on port N of hub Id: the nearest high-speed hub above it.
translator(_Id, _N, Speed, _State) when Speed =:= high; Speed =:= super ->
    none;
translator(root, _N, _Speed, _State) ->
    none;
translator(Id, N, Speed, State = #{devices := Devices}) ->
    case Devices of
        #{Id := #{speed := high}} -> {Id, N};
        #{Id := #{port := {Above, AboveN}}} -> translator(Above, AboveN, Speed, State)
    end.

address_params(#{route := [RootPort | Tiers], speed := Speed, slot := Slot, tt := TT},
               #{devices := Devices, hubs := Hubs}) ->
    Translator = case TT of
                     none ->
                         none;
                     {HubRef, Port} ->
                         #{slot := HubSlot} = maps:get(HubRef, Devices),
                         #{multi_tt := Multi} = maps:get(HubRef, Hubs),
                         #{hub_slot => HubSlot, port => Port, multi => Multi}
                 end,
    #{slot => Slot, root_port => RootPort, route => Tiers, speed => Speed, tt => Translator}.

%% Failure and detach.

%% A failed or malformed answer on a hub's port: an external hub's control pipe
%% failed, so the hub is detached. The root hub's operations are the controller
%% process's own register accesses, which do not fail; one that does ends the bus
%% process, and its supervisor restarts it with the controller.
fail_hub(root, Target, Reason, _State) ->
    error({root_port_operation_failed, Target, Reason});
fail_hub(Ref, _Target, Reason, State) ->
    fail_device(Ref, {hub, Reason}, State).

fail_device(Ref, Reason, State = #{devices := Devices}) ->
    #{port := {Id, N}} = maps:get(Ref, Devices),
    give_up(Id, N, Reason, State).

%% Port N of hub Id given up while a device on it may still be enabled: its
%% occupant detached, and the port disabled at its hub before it is `disabled`,
%% holding the turn until then, as FreeBSD clears the port's enable on its error
%% path (usb_hub.c:827-832), so a device left in the default state never meets
%% the next port's reset.
%% The port keeps the turn while disabling when it, or a port below the hub on
%% it, held the turn: that holder goes with the hub in the same write, and its
%% device stays reachable through the hub until the disable is answered. A
%% configuring or running device with no holder below was addressed already, so
%% at most one port holds the turn.
give_up(Id, N, Reason, State) ->
    update_port(Id, N, fun(Old) -> {disabling, Reason, holds_turn_below(Old, State)} end, State).

holds_turn_below(Port, State = #{hubs := Hubs}) ->
    Below = [P || Ref <- occupant(Port), #{Ref := #{ports := Ports}} <- [Hubs], P <- maps:values(Ports)],
    holds_turn(Port) orelse lists:any(fun(P) -> holds_turn_below(P, State) end, Below).

%% Detaches Ref and, when it is a hub, every device below it first, deepest
%% first. Only update_port calls it, for the occupant a port's new state drops;
%% the ports of a detached hub go with the hub.
detach_device(Ref, State = #{hubs := Hubs}) ->
    Below = case Hubs of
                #{Ref := #{ports := Ports}} -> [Child || {_N, Port} <- lists:sort(maps:to_list(Ports)),
                                                         Child <- occupant(Port)];
                #{} -> []
            end,
    {Actions, Detached = #{hubs := Left, devices := Devices}} =
        lists:foldl(fun(Child, {Acc, S}) ->
                            {More, Next} = detach_device(Child, S),
                            {Acc ++ More, Next}
                    end, {[], State}, Below),
    {Actions ++ [{detach, Ref}],
     Detached#{hubs := maps:remove(Ref, Left), devices := maps:remove(Ref, Devices)}}.

occupant({enumerating, Ref, _Step}) -> [Ref];
occupant({running, Ref}) -> [Ref];
occupant(_Unoccupied) -> [].

%% After every event: the turn, each hub's next operation and answer, and the
%% earliest deadline.

settle(Now, Actions, State0) ->
    {Granted, State1} = grant_turn(prune_waiting(State0)),
    {Operations, State} = run_hubs(Now, State1),
    {State, Actions ++ Granted ++ Operations ++ deadline(State)}.

%% The arrival order keeps only ports still `waiting`.
prune_waiting(State = #{waiting := Waiting}) ->
    State#{waiting := [{Id, N} || {Id, N} <- Waiting, find_port(Id, N, State) =:= waiting]}.

%% The first waiting port takes the turn when no port holds it; its reset's
%% deadline starts when its hub sends the reset.
grant_turn(State = #{waiting := [{Id, N} | Rest]}) ->
    case lists:any(fun holds_turn/1, maps:values(ports(State))) of
        true -> {[], State};
        false -> set_port(Id, N, {resetting, to_send}, State#{waiting := Rest})
    end;
grant_turn(State) ->
    {[], State}.

holds_turn({resetting, to_send}) -> true;
holds_turn({resetting, _At, _Phase}) -> true;
holds_turn({recovering, _At, _Speed}) -> true;
holds_turn({enumerating, _Ref, Step}) -> Step =:= enabling_slot orelse Step =:= addressing;
holds_turn({disabling, _Reason, Held}) -> Held;
holds_turn(_Port) -> false.

run_hubs(Now, State = #{hubs := Hubs}) ->
    lists:foldl(fun(Id, {Acc, S = #{hubs := H}}) ->
                        {More, Hub} = run_hub(Id, maps:get(Id, H), Now),
                        {Acc ++ More, S#{hubs := H#{Id := Hub}}}
                end, {[], State}, lists:sort(maps:keys(Hubs))).

%% A hub with nothing in flight takes its next operation; one whose report has
%% been read and cleared whole answers its reporter.
run_hub(Id, Hub0, Now) ->
    {Operation, Hub1} = case Hub0 of
                            #{op := none} -> next_op(Id, Hub0, Now);
                            #{} -> {[], Hub0}
                        end,
    case Hub1 of
        #{pending := [], clears := [], reporter := From} when From =/= none ->
            {Operation ++ [{handled, Id, From}], Hub1#{reporter := none}};
        #{} ->
            {Operation, Hub1}
    end.

%% A hub's next port operation: the clears of the last read, powering, disabling
%% a port given up, the turn holder's reset, then a status read once powered.
%% A resetting port's reads are queued in `pending` with the hub's other reads,
%% so a report is answered only once they are done as well.
next_op(_Id, Hub = #{power := unpowered}, _Now) ->
    {[], Hub};
next_op(Id, Hub = #{clears := [{Target, Change} | _]}, _Now) ->
    issue(Id, Target, {clear, Change}, Hub);
next_op(Id, Hub = #{power := powering, ports := Ports, power_good := PowerGood}, Now) ->
    case [N || {N, off} <- lists:sort(maps:to_list(Ports))] of
        [N | _] -> issue(Id, N, power_on, Hub);
        [] -> next_op(Id, Hub#{power := {good_at, Now + PowerGood}}, Now)
    end;
next_op(Id, Hub = #{ports := Ports}, Now) ->
    Sorted = lists:sort(maps:to_list(Ports)),
    case [N || {N, {disabling, _, _}} <- Sorted] of
        [N | _] -> issue(Id, N, disable, Hub);
        [] -> next_reset(Id, Hub, [N || {N, {resetting, to_send}} <- Sorted], Now)
    end.

next_reset(Id, Hub = #{ports := Ports}, [N | _], Now) ->
    %% From `{resetting, to_send}` to `sent`, neither occupied, so this hub-local
    %% write needs nothing of update_port's.
    issue(Id, N, reset, Hub#{ports := Ports#{N := {resetting, Now + ?ERX_USB_RESET_DEADLINE_MS, sent}}});
next_reset(Id, Hub, [], _Now) ->
    next_read(Id, Hub).

next_read(Id, Hub = #{pending := [Target | _], power := good}) ->
    issue(Id, Target, get_status, Hub);
next_read(_Id, Hub) ->
    {[], Hub}.

%% The targets of a hub's queue of reads with Targets added at its end, each once.
queued(Targets, Pending) ->
    Pending ++ [T || T <- lists:usort(Targets), not lists:member(T, Pending)].

issue(Id, Target, Op, Hub) ->
    {[{port, Id, Target, Op}], Hub#{op := {Target, Op}}}.

deadline(#{hubs := Hubs}) ->
    case [At || #{ports := Ports, power := Power} <- maps:values(Hubs),
                At <- [A || {good_at, A} <- [Power]] ++ lists:flatmap(fun port_deadlines/1, maps:values(Ports))] of
        [] -> [];
        Deadlines -> [{deadline, lists:min(Deadlines)}]
    end.

port_deadlines({settling, At}) -> [At];
port_deadlines({resetting, At, {poll, Poll}}) -> [At, Poll];
port_deadlines({resetting, At, _Phase}) -> [At];
port_deadlines({recovering, At, _Speed}) -> [At];
port_deadlines({enumerating, _Ref, {address_settle, At}}) -> [At];
port_deadlines(_Port) -> [].

%% State access.

port(Id, N, #{hubs := Hubs}) -> maps:get(N, maps:get(ports, maps:get(Id, Hubs))).

history(Id, N, #{hubs := Hubs}) -> maps:get(N, maps:get(histories, maps:get(Id, Hubs))).

put_history(Id, N, History, State) ->
    with_hub(Id, fun(Hub = #{histories := Histories}) -> Hub#{histories := Histories#{N := History}} end, State).

find_port(Id, N, #{hubs := Hubs}) ->
    case Hubs of
        #{Id := #{ports := #{N := Port}}} -> Port;
        #{} -> none
    end.

set_port(Id, N, Port, State) ->
    update_port(Id, N, fun(_Old) -> Port end, State).

%% The one way a port's state changes: an occupant the new state does not keep is
%% detached first, with every device below it, so the state holds a device exactly
%% while a port holds its reference, and a port given up is logged as it is. A port
%% of a hub already gone is left alone.
update_port(Id, N, Fun, State) ->
    case find_port(Id, N, State) of
        none ->
            {[], State};
        Old ->
            New = Fun(Old),
            {Detached, Vacated} = case occupant(Old) -- occupant(New) of
                                      [Ref] -> detach_device(Ref, State);
                                      [] -> {[], State}
                                  end,
            {Detached ++ failure_log(Id, N, Old, New),
             with_hub(Id, fun(Hub = #{ports := Ports}) -> Hub#{ports := Ports#{N := New}} end, Vacated)}
    end.

%% A port's failure is logged as the port moves into `disabling` or `disabled` from
%% a state that is neither. Only a connection change leaves those two, so a port's
%% failure is logged once per connection (docs/design-usb.md, "What a device can
%% make the domain spend").
failure_log(Id, N, Old, New) ->
    case {failure(Old), failure(New)} of
        {none, {failed, Reason}} -> [{log, Id, N, {failed, Reason}}];
        {_Old, _New} -> []
    end.

failure({disabling, Reason, _Held}) -> {failed, Reason};
failure({disabled, Reason}) -> {failed, Reason};
failure(_Port) -> none.

%% The actions Actions, then those of a step's answer.
then(Actions, {More, State}) -> {Actions ++ More, State}.

set_step(Ref, Step, State = #{devices := Devices}) ->
    #{port := {Id, N}} = maps:get(Ref, Devices),
    set_port(Id, N, {enumerating, Ref, Step}, State).

%% Applies Fun to hub Id; a hub the state no longer holds is left alone, since
%% what names it is stale.
with_hub(Id, Fun, State = #{hubs := Hubs}) ->
    case Hubs of
        #{Id := Hub} -> State#{hubs := Hubs#{Id := Fun(Hub)}};
        #{} -> State
    end.
