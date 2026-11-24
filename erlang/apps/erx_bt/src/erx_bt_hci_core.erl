%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_hci_core).
-moduledoc """
The pure core of the controller process, `erx_bt_hci` (docs/design-bluetooth.md, "One
owner, one step", "The bring-up" and "Commands and data credits"). `step/3` takes one
input, the current time and the state and returns the next state and the actions the process performs;
a stop is the action `{stop, Reason}`, after which the process ends and its group's restart resets the line.

**The bring-up** is a line of steps fixed by `new/1`: reset the line, `HCI_Reset`,
identify, the patch where the configuration names one (its own reset and identify after
it), the buffers, the configuration, then `ready`. The line's reset stops unless the
line is ready within `bt_line_reset_timeout_ms`. Each command step waits for its
Command Complete with status success; any other answer, or none within
`bt_command_timeout_ms`, stops with the step and the status. The patched steps are
distinct from the first ones, so the bring-up patches at most once.

**The slot** holds the one thing a deadline guards, with that deadline, so a bring-up
wait and a command are never both active and leaving a state drops its deadline:

- `idle`: nothing, and no deadline;
- `{line_reset, Deadline}`: the line is being reset, until `line_ready`; the process
  does not wait on the reset, so its deadline can pass while the line service holds it;
- `{wait, Deadline}`: a bring-up wait, which ends when its deadline passes;
- `{due, Deadline}`: a command is due and waits for the writer and for the controller's
  `Num_HCI_Command_Packets` to be at least one (Part E, 4.4), or was due and the line
  has been unable to take a command since;
- `{sent, Label, Command, Opcode, Deadline}`: the writer has the command, until its
  answer; the deadline is the one it had when it fell due.

Which command is due is decided again on every step and taken only when it is handed to
the writer, so a disconnect for a handle that has gone, even one the controller has given
a new peer since, or advertising at the limit, is never sent. The command's deadline
starts when it falls due and runs until its answer, so a controller that allows no
command and never says otherwise stops on it. A due slot whose command stops being due
empties only when the line would take a command, so a command that falls due again
while the controller allows none, as the advertising enable does at the limit for a
controller that reports connections coming and going, keeps the deadline it first fell due with; at that deadline
the core stops whether or not a command is due. Command Complete or Command Status for the
command sent empties the slot; one with opcode 0 only updates the count, and one naming
any other opcode, the command due but not yet written included, stops.

**Disconnects**: a link's disconnect stays with its handle, asked and then taken, until
the handle's Disconnection Complete, so a second request for the handle is ignored and
the core never decides a disconnect for a handle after its Disconnection Complete. A
connection on a handle whose disconnect is handed to the writer and unanswered stops,
since the controller may carry that disconnect out on the new peer. A disconnect
answered with Unknown Connection Identifier (the handle has gone) or Command Disallowed
(which NimBLE's and Zephyr's controllers answer when the connection is already ending)
keeps its mark until the handle's Disconnection Complete, as one answered with success
does; any other status stops. A disconnect is never asked again: the mark taken holds a
deadline, `bt_disconnect_timeout_ms` from the moment the writer takes it, and a handle
whose successful Disconnection Complete has not come by then stops, so a controller that
refuses the disconnect of a connection that is not ending, by Command Disallowed or a
failed Disconnection Complete, cannot keep the connection up.

**Long Term Key replies**: a link answers the LE Long Term Key Request the core passed
it with `{ltk_reply, Key}`, its key, or `{ltk_reply, none}` when it has none, which the
core sends as LE Long Term Key Request Reply or Negative Reply (Part E, 7.8.25, 7.8.26)
for the link's own handle, the one its name carries: no request names a handle. A reply
waits with its handle until it is taken, and a second one asked before then is ignored,
so a link answers each request once;
Disconnection Complete drops it, so it never reaches the handle's next peer. Its
Command Complete goes to the handle's link as `{ltk_reply_complete, ok}` or
`{ltk_reply_complete, {failed, Status}}`, a failed Command Status as the latter; a
success naming another handle, a malformed return or a Command Status of success stops,
and so does a connection on a handle whose reply is handed to the writer and unanswered,
as for a disconnect. The key is a secret: it stays in the reply and the
command, which `facts/1` does not show, and no stop reason carries a request.

**Links** are named by their handle and the connection that gave it, `{Handle, Serial}`,
the serial counting the core's connections: `link_up` gives a link its name, every
action for a link carries it, and every request comes in one envelope that carries it,
`{request, Link, Request}`. The envelope's one clause asks `current/2` before any
request is read, and a name that is not its handle's current link is refused, so a
request of a link that has gone changes nothing: its packet or disconnect never
reaches the peer the controller gave the handle next. Names are unique within one run
of the core; a stop ends every link with it (its group restarts), so the process maps
full names to link processes and no link outlives the core that named it.

**ACL credits** (Part E, 4.1.1): each live handle counts its packets in flight, and the
free credits are the controller's buffer count less their sum, so a completion can never
grow them: one naming a handle that is not live, or more packets than the handle has
given the writer, stops, so the writer's list holds at most the credits. Disconnection
Complete returns all of a handle's (4.3). Each link may hold at most its share, the
buffers divided by the connection limit, and counts its own packets back: a completion
passes each handle's count to its link as `{completed, Count}`. A controller with fewer
buffers than the limit lowers the limit to its buffer count, so every share is at least
one buffer.

**A link's backlog** (docs/design-bluetooth.md, "Commands and data credits"): every
message for a link, events, ACL packets, completions, Long Term Key reply outcomes and
`busy` alike, goes through one funnel, `to_link/3`, which counts the messages the link
has not yet acknowledged; the link's `taken`, a request in its envelope, acknowledges
one, so a gone link's acknowledgement changes nothing. A message for a link whose
backlog is `bt_link_backlog` is dropped, the link is cut off and sent nothing more, and
its handle's disconnect is asked with Remote Device Terminated Connection due to Low
Resources (Part E, 7.1.6), so a link's mailbox holds at most that many of the
controller process's messages however long the link is held up.

**The writer** is given one item at a time, the next only after `written`: the due
command first, once the controller allows one, then the credited packets in order. A
command is in flight only once the writer has it, so what waits for the line is the one
due command and the credited packets, whatever the controller does.

**Advertising** is on exactly while connections are below the limit: the controller
stops it when a connection completes, and the core enables it again whenever the slot is
free and connections are below the limit. A connection that completes while the enable
is sent came from that enable, so the enable's answer leaves advertising off. New
advertising data, `{advertising_data, Data}`, waits until the core is ready and is then
written with LE Set Advertising Data at the next free command slot, before an enable that
is due, so the enable advertises it; a later input replaces data not yet written, so only
the last is written. A controller that refuses it stops the core, whose restart writes
the data the configuration then gives in the bring-up, before it enables advertising.

**Time** is an input (docs/design.md, "Deadlines in state"): every step takes the
current time in milliseconds, a deadline is that time plus its timeout, each deadline is
a field of the state it guards, the slot or a taken disconnect, and `next_deadline/1`
answers the earliest of them. The process reads the clock, keeps one
wake-up timer at that deadline and steps `expired` when it fires; `expired` runs a
deadline at or before the time given and changes nothing otherwise, so a late, early or
repeated wake-up costs one look. Inputs and actions are terms. The patch arrives as records already read whole by `erx_bt_patch` (a later
slice): this core sends what it is given.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/3, next_deadline/1, facts/1]).
-export_type([time/0]).
-export_type([config/0, input/0, action/0, core/0, link/0, request/0]).

-type handle() :: erx_hci:handle().
-type link() :: {handle(), pos_integer()}.     % a handle and the serial of the connection on it
-type config() :: #{connections := 1..?ERX_BT_CONNECTIONS_MAX, address := <<_:48>>,
                    advertising_data := binary(), scan_response_data := binary(),
                    patch := none | #{manufacturer := 0..16#FFFF, records := [{0..16#FFFF, binary()}]}}.
-type time() :: integer().                    % milliseconds, the process's monotonic clock
-type input() :: start | line_ready | written | expired
               | {event, erx_hci:event()}
               | {acl, handle(), 0..3, 0..3, binary()}
               | {request, link(), request()}
               | {advertising_data, binary()}.
-type request() :: {send, 0..3, binary()} | {disconnect, byte()} | {ltk_reply, erx_hci:key() | none} | taken.
-type action() :: line_reset | {write, binary()} | {ready, map()} | {link_up, link(), map()} | {link_down, link()}
                | {to_link, link(), term()} | {stop, term()}.

%% A bring-up step: reset the line, send a command under a label, or wait.
-type step() :: line_reset | {command, term(), erx_hci:command()} | {wait, pos_integer()}.

%% A live handle's link: the serial of the connection that gave it the handle, its packets
%% in flight, and the messages sent it and not yet taken, or `cut` once one was dropped.
-record(live, {
    serial :: pos_integer(),
    in_flight = 0 :: non_neg_integer(),
    backlog = 0 :: 0..?ERX_BT_LINK_BACKLOG | cut
}).

-record(core, {
    limit :: 1..?ERX_BT_CONNECTIONS_MAX,
    identity :: <<_:48>>,                      % the identity address, for each link_up
    manufacturer :: none | 0..16#FFFF,
    plan :: [step()],                          % the bring-up steps left; [] once ready
    stage = bringup :: bringup | ready,
    slot = idle :: idle | {line_reset, time()} | {wait, time()} | {due, time()}  % moduledoc
                 | {sent, Label :: term(), erx_hci:command(), Opcode :: 0..16#FFFF, time()},
    allowed = 1 :: byte(),                     % Num_HCI_Command_Packets
    writer = idle :: idle | busy,
    out = [] :: [{handle(), binary()}],        % ACL packets for the writer, in order, each with its handle
    credits = 0 :: 0..?ERX_BT_ACL_CREDITS_MAX,
    acl_tx_max = 0 :: 0..16#FFFF,
    serial = 0 :: non_neg_integer(),           % the connections so far, the last link's serial
    links = #{} :: #{handle() => #live{}},
    advertising = false :: boolean(),
    advertising_data = none :: none | binary(),  % data given and not yet written
    disconnects = [] :: [{handle(), {asked, Reason :: byte()} | {taken, Deadline :: time()}}],  % live handles only
    replies = [] :: [{handle(), erx_hci:key() | none}],  % asked and not taken, live handles only
    facts = #{} :: map(),
    dropped = 0 :: non_neg_integer()
}).
-opaque core() :: #core{}.

-doc "The state before `start`, with the bring-up's steps fixed from the configuration.".
-spec new(config()) -> core().
new(#{connections := Limit, address := Address, patch := Patch} = Config)
  when Limit >= 1, Limit =< ?ERX_BT_CONNECTIONS_MAX ->
    Manufacturer = case Patch of none -> none; #{manufacturer := M} -> M end,
    #core{limit = Limit, identity = Address, manufacturer = Manufacturer, plan = plan(Config)}.

plan(#{address := Address, advertising_data := AdvertisingData, scan_response_data := ScanData,
       patch := Patch}) ->
    Interval = ?ERX_BT_ADVERTISING_INTERVAL_US div ?ERX_HCI_ADVERTISING_INTERVAL_UNIT_US,
    [line_reset, {command, reset, reset} | identify(first)] ++ patch(Patch) ++
        [{command, buffers, le_read_buffer_size},
         {command, host_buffer_size, {host_buffer_size, ?ERX_BT_ACL_RX_MAX, ?ERX_BT_HOST_ACL_PACKETS}},
         {command, event_mask, {set_event_mask, mask(?ERX_HCI_EVENT_MASK_BIT_MEMBERS)}},
         {command, le_event_mask, {le_set_event_mask, mask(?ERX_HCI_LE_EVENT_MASK_BIT_MEMBERS)}},
         {command, random_address, {le_set_random_address, Address}},
         {command, advertising_parameters, {le_set_advertising_parameters, Interval}},
         {command, advertising_data, {le_set_advertising_data, AdvertisingData}},
         {command, scan_response_data, {le_set_scan_response_data, ScanData}}].

%% Identify (design step 3); the second run, after the patch, has labels of its own.
identify(Run) ->
    [{command, {Run, Name}, Name} || Name <- [read_local_version, read_local_commands, le_read_features, read_bd_addr]].

%% The patch (design step 4): the download command and its wait, each record, the launch
%% wait, then HCI_Reset and identify again.
patch(none) -> [];
patch(#{records := Records}) ->
    [{command, minidriver, {vendor, ?ERX_BT_PATCH_DOWNLOAD_MINIDRIVER, <<>>}}, {wait, ?ERX_BT_PATCH_MINIDRIVER_MS}] ++
        [{command, {patch_record, N}, {vendor, Opcode, Parameters}}
         || {N, {Opcode, Parameters}} <- lists:enumerate(Records)] ++
        [{wait, ?ERX_BT_PATCH_LAUNCH_MS}, {command, patched_reset, reset} | identify(patched)].

mask(Members) -> lists:foldl(fun({_Event, Bit}, Mask) -> Mask bor (1 bsl Bit) end, 0, Members).

-doc """
For `/proc/bt`: what the bring-up read from the controller, the events dropped, the
connection limit in force, each live handle's packets in flight and its link's backlog,
the free credits and whether advertising is on.
""".
-spec facts(core()) -> map().
facts(#core{facts = Facts, dropped = Dropped, limit = Limit, links = Links, advertising = Advertising} = Core) ->
    Facts#{dropped => Dropped, limit => Limit, free => free(Core), advertising => Advertising,
           links => #{Handle => N || Handle := #live{in_flight = N} <- Links},
           backlogs => #{Handle => Backlog || Handle := #live{backlog = Backlog} <- Links}}.

-doc """
One input at the time `Now`: the next state and the actions to perform, in order. A stop
is the one action `{stop, Reason}`, with the state unchanged.
""".
-spec step(input(), time(), core()) -> {core(), [action()]}.
step(Input, Now, Core) ->
    try
        {Actions, Next} = input(Input, Now, Core),
        {More, Pumped} = pump(Now, Next),
        {Pumped, Actions ++ More}
    catch
        throw:{stop, Reason} -> {Core, [{stop, Reason}]}
    end.

stop(Reason) -> throw({stop, Reason}).

-doc "The earliest deadline the state holds, the slot's or a taken disconnect's; `infinity` when it holds none.".
-spec next_deadline(core()) -> time() | infinity.
next_deadline(Core) ->
    %% Every integer sorts before the atom infinity.
    lists:min([infinity | [Deadline || {_Guarded, Deadline} <- deadlines(Core)]]).

%% Every deadline the state holds, each with what it guards: the slot's, if it holds one,
%% and each taken disconnect's.
deadlines(#core{slot = Slot, disconnects = Disconnects}) ->
    [{slot, Deadline} || Deadline <- slot_deadline(Slot)] ++
        [{{disconnect, Handle}, Deadline} || {Handle, {taken, Deadline}} <- Disconnects].

slot_deadline(idle) -> [];
slot_deadline({line_reset, Deadline}) -> [Deadline];
slot_deadline({wait, Deadline}) -> [Deadline];
slot_deadline({due, Deadline}) -> [Deadline];
slot_deadline({sent, _Label, _Command, _Opcode, Deadline}) -> [Deadline].

input(start, Now, #core{plan = [line_reset | Plan], slot = idle} = Core) ->
    {[line_reset], Core#core{plan = Plan, slot = {line_reset, Now + ?ERX_BT_LINE_RESET_TIMEOUT_MS}}};
input(line_ready, _Now, #core{slot = {line_reset, _}} = Core) ->
    {[], Core#core{slot = idle}};
%% The first deadline at or before Now runs; with none, nothing changes. Only a bring-up
%% wait runs without stopping, and it never meets a disconnect: there are no links before
%% ready.
input(expired, Now, Core) ->
    case [Guarded || {Guarded, Deadline} <- deadlines(Core), Deadline =< Now] of
        [Guarded | _] -> expired(Guarded, Now, Core);
        [] -> {[], Core}
    end;
input(Input, _Now, Core) ->
    untimed(Input, Core).

%% A deadline has passed. A taken disconnect's: its handle's connection outlived the
%% longest time the controller may take to end it.
expired({disconnect, Handle}, _Now, _Core) ->
    stop({disconnect_not_completed, Handle});
expired(slot, _Now, #core{slot = {line_reset, _}}) ->
    stop(line_reset_timeout);
expired(slot, _Now, #core{slot = {wait, _}} = Core) ->
    {[], Core#core{slot = idle}};
%% A due slot outlives its command only while the line could take none (command/2), so
%% with none due then, no command was written through the whole deadline.
expired(slot, Now, #core{slot = {due, _}} = Core) ->
    case due(Now, Core) of
        {Label, _, _} -> stop({command_timeout, Label});
        none -> stop(command_not_written)
    end;
expired(slot, _Now, #core{slot = {sent, Label, _, _, _}}) ->
    stop({command_timeout, Label}).

%% The inputs that do not read the time, and start or line_ready out of their state.
untimed(written, #core{writer = busy} = Core) ->
    {[], Core#core{writer = idle}};
untimed({event, Event}, Core) ->
    event(Event, Core);
untimed({acl, Handle, Boundary, _Broadcast, Data}, Core) ->
    to_link(Handle, {acl, Boundary, Data}, Core);
untimed({advertising_data, Data}, Core) when is_binary(Data) ->
    {[], Core#core{advertising_data = Data}};
untimed({request, Link, Request}, Core) ->
    case current(Link, Core) of
        {current, Live} -> request(Request, Link, Live, Core);
        gone -> {[], Core}
    end;
untimed(Input, _Core) ->
    stop({unexpected_input, Input}).

%% A request's link, when it is its handle's current link, else gone. Every request
%% comes in one envelope, whose one clause asks this first.
current({Handle, Serial}, #core{links = Links}) ->
    case Links of
        #{Handle := #live{serial = Serial} = Live} -> {current, Live};
        #{} -> gone
    end.

%% A request of a link current on its handle.
request({send, Boundary, Data}, {Handle, _Serial}, #live{in_flight = InFlight} = Live,
        #core{links = Links, out = Out} = Core) ->
    case InFlight < share(Core) andalso free(Core) > 0 of
        true ->
            Packet = erx_h4:acl(Handle, Boundary, Data),
            {[], Core#core{out = Out ++ [{Handle, Packet}],
                           links = Links#{Handle := Live#live{in_flight = InFlight + 1}}}};
        false ->
            to_link(Handle, busy, Core)
    end;
request({disconnect, Reason}, {Handle, _Serial}, _Live, Core) ->
    {[], disconnect(Handle, Reason, Core)};
%% A link's acknowledgement of one message it was sent; once it is cut off, its
%% acknowledgements of the messages already in its mailbox change nothing. One beyond
%% what it was sent is a defect of the domain's own link and stops, as any request the
%% core does not take does.
request(taken, _Link, #live{backlog = cut}, Core) ->
    {[], Core};
request(taken, {Handle, _Serial}, #live{backlog = Backlog} = Live, #core{links = Links} = Core) when is_integer(Backlog), Backlog > 0 ->
    {[], Core#core{links = Links#{Handle := Live#live{backlog = Backlog - 1}}}};
request({ltk_reply, Key}, {Handle, _Serial}, _Live, #core{replies = Replies} = Core)
  when Key =:= none; bit_size(Key) =:= 128 ->
    case lists:keymember(Handle, 1, Replies) of
        false -> {[], Core#core{replies = Replies ++ [{Handle, Key}]}};
        true -> {[], Core}
    end;
%% The request is left out of the reason: a malformed reply may hold a key.
request(_Request, Link, _Live, _Core) ->
    stop({unexpected_request, Link}).

%% A disconnect asked for a live handle, which stays with the handle until its
%% Disconnection Complete: a second one is ignored.
disconnect(Handle, Reason, #core{disconnects = Pending} = Core) ->
    case lists:keymember(Handle, 1, Pending) of
        false -> Core#core{disconnects = Pending ++ [{Handle, {asked, Reason}}]};
        true -> Core
    end.

%% The credits no live handle holds, and a link's share of all of them.
free(#core{credits = Credits, links = Links}) ->
    Credits - lists:sum([InFlight || _ := #live{in_flight = InFlight} <- Links]).

%% At least one: the bring-up keeps the limit at most the credits.
share(#core{credits = Credits, limit = Limit}) -> Credits div Limit.

dropped(#core{dropped = Dropped} = Core) -> Core#core{dropped = Dropped + 1}.

%% The events of Part E, 7.7, as erx_hci decodes them.
event({command_complete, Allowed, Opcode, Return}, Core) ->
    answer(Opcode, {complete, Return}, Core#core{allowed = Allowed});
event({command_status, Status, Allowed, Opcode}, Core) ->
    answer(Opcode, {status, Status}, Core#core{allowed = Allowed});
event({hardware_error, Code}, _Core) ->
    stop({hardware_error, Code});
event({number_of_completed_packets, Pairs}, Core) ->
    {Completed, Returned} = lists:mapfoldl(fun complete/2, Core, Pairs),
    {lists:append(Completed), Returned};
event({le_connection_complete, Handle, Peer}, Core) ->
    connected(Handle, Peer, Core);
event({le_connection_complete, {failed, _Status}}, Core) ->
    {[], Core};
event({disconnection_complete, ?ERX_HCI_STATUS_SUCCESS, Handle, _Reason}, #core{links = Links} = Core) ->
    case Links of
        #{Handle := #live{serial = Serial}} ->
            %% A packet still waiting for the writer is dropped with its handle, which the
            %% controller may give the next peer, and so is the handle's disconnect. The
            %% packet the writer already holds is on the line (TODO.md, security residuals).
            {[{link_down, {Handle, Serial}}],
             Core#core{links = maps:remove(Handle, Links),
                       out = [Item || {Owner, _} = Item <- Core#core.out, Owner =/= Handle],
                       disconnects = lists:keydelete(Handle, 1, Core#core.disconnects),
                       replies = lists:keydelete(Handle, 1, Core#core.replies)}};
        #{} ->
            {[], dropped(Core)}
    end;
event({encryption_key_refresh_complete, _Status, Handle} = Event, Core) ->
    to_link(Handle, Event, Core);
%% New connection parameters change nothing for erXos, which asks for none: no consumer.
event({le_connection_update_complete, _Status, _Handle}, Core) ->
    {[], Core};
event({encryption_change, _Status, Handle, _Enabled} = Event, Core) ->
    to_link(Handle, Event, Core);
event({le_long_term_key_request, Handle, _Random, _Ediv} = Event, Core) ->
    to_link(Handle, Event, Core);
event({disconnection_complete, _Failed, _Handle, _Reason}, Core) ->
    {[], Core};
event({unknown, _Code}, Core) ->
    {[], dropped(Core)};
event(malformed, _Core) ->
    stop(malformed_event).

%% The one funnel of every message for a link: a message for a handle goes to the
%% handle's current link, named in full, and counts in its backlog; at the backlog's
%% bound it is dropped instead, the link is cut off, and the handle's disconnect is
%% asked. A cut-off link is sent nothing more; a handle not live drops the message. Every
%% message dropped counts among the dropped events.
to_link(Handle, Message, #core{links = Links} = Core) ->
    case Links of
        #{Handle := #live{backlog = cut}} ->
            {[], dropped(Core)};
        #{Handle := #live{backlog = ?ERX_BT_LINK_BACKLOG} = Live} ->
            Cut = Core#core{links = Links#{Handle := Live#live{backlog = cut}}},
            {[], dropped(disconnect(Handle, ?ERX_HCI_DISCONNECT_REASON_LOW_RESOURCES, Cut))};
        #{Handle := #live{serial = Serial, backlog = Backlog} = Live} ->
            {[{to_link, {Handle, Serial}, Message}],
             Core#core{links = Links#{Handle := Live#live{backlog = Backlog + 1}}}};
        #{} ->
            {[], dropped(Core)}
    end.

%% A completion returns a live handle's packets, never more than it has given the
%% writer: one still on the writer's list has not reached the controller, and freeing
%% its credit would let the list grow while the line is stalled. The packets returned
%% go to the handle's link, so the link counts its share back; a count of 0 returns
%% nothing and tells the link nothing.
complete({Handle, Count}, #core{links = Links, out = Out} = Core) ->
    Queued = length([Owner || {Owner, _} <- Out, Owner =:= Handle]),
    case Links of
        #{Handle := #live{in_flight = InFlight} = Live} when Count =< InFlight - Queued ->
            Returned = Core#core{links = Links#{Handle := Live#live{in_flight = InFlight - Count}}},
            completed(Handle, Count, Returned);
        #{Handle := _} -> stop({completion_beyond_in_flight, Handle, Count});
        #{} -> stop({completion_for_dead_handle, Handle})
    end.

completed(_Handle, 0, Core) -> {[], Core};
completed(Handle, Count, Core) -> to_link(Handle, {completed, Count}, Core).

%% A connection, which ends the controller's advertising (Part E, 7.8.9).
connected(Handle, _Peer, #core{stage = bringup}) ->
    stop({connection_during_bringup, Handle});
connected(Handle, _Peer, #core{links = Links}) when is_map_key(Handle, Links) ->
    stop({duplicate_handle, Handle});
connected(Handle, _Peer, #core{slot = {sent, {disconnect, Handle}, _, _, _}}) ->
    stop({connection_while_disconnecting, Handle});
connected(Handle, _Peer, #core{slot = {sent, {ltk_reply, Handle}, _, _, _}}) ->
    stop({connection_while_replying, Handle});
connected(Handle, _Peer, #core{links = Links, limit = Limit}) when map_size(Links) >= Limit ->
    stop({connection_beyond_limit, Handle});
connected(Handle, Peer, #core{links = Links, serial = Last, identity = Identity, acl_tx_max = TxMax,
                              slot = Slot} = Core) ->
    Serial = Last + 1,
    {[{link_up, {Handle, Serial}, #{peer => Peer, identity => Identity, acl_tx_max => TxMax, share => share(Core)}}],
     Core#core{links = Links#{Handle => #live{serial = Serial}}, serial = Serial, advertising = false,
               slot = overtaken(Slot)}}.

%% A connection while the advertising enable is sent came from that enable, which the
%% controller has carried out and not yet answered: its answer must leave advertising
%% off.
overtaken({sent, advertise, Command, Opcode, Deadline}) -> {sent, advertise_overtaken, Command, Opcode, Deadline};
overtaken(Slot) -> Slot.

%% Command Complete or Status for the command in the slot; opcode 0 only updates the
%% count (Part E, 4.4).
answer(0, _Answer, Core) ->
    {[], Core};
answer(Opcode, Answer, #core{slot = {sent, Label, Command, Opcode, _Deadline}} = Core) ->
    answered(Label, Command, Answer, Core#core{slot = idle});
answer(Opcode, _Answer, _Core) ->
    stop({answer_to_other_command, Opcode}).

%% A disconnect is answered by Command Status (Part E, 7.1.6). Unknown Connection
%% Identifier means the handle has gone; Command Disallowed is what NimBLE's and
%% Zephyr's controllers answer when the connection is already ending (7.7.5 lists a
%% disconnect not presently allowed among the failed ones). After either, as after
%% success, the handle keeps its taken mark until its Disconnection Complete, or until
%% the mark's deadline stops the core. Any other failure stops.
answered({disconnect, Handle}, Command, Answer, Core) ->
    case outcome(Command, Answer) of
        {ok, _} -> {[], Core};
        {failed, ?ERX_HCI_STATUS_UNKNOWN_CONNECTION} -> {[], Core};
        {failed, ?ERX_HCI_STATUS_COMMAND_DISALLOWED} -> {[], Core};
        Failed -> stop({disconnect_failed, Handle, Failed})
    end;
%% A Long Term Key reply is answered by Command Complete naming its handle (7.8.25,
%% 7.8.26); its outcome goes to the handle's link.
answered({ltk_reply, Handle}, Command, Answer, Core) ->
    case outcome(Command, Answer) of
        {ok, Handle} -> to_link(Handle, {ltk_reply_complete, ok}, Core);
        {failed, Status} -> to_link(Handle, {ltk_reply_complete, {failed, Status}}, Core);
        Other -> stop({ltk_reply_answer, Handle, Other})
    end;
answered(advertise, _Command, {complete, <<?ERX_HCI_STATUS_SUCCESS>>}, Core) ->
    {[], Core#core{advertising = true}};
answered(advertise_overtaken, _Command, {complete, <<?ERX_HCI_STATUS_SUCCESS>>}, Core) ->
    {[], Core};
answered(Label, _Command, {status, Status}, _Core) ->
    stop({step_failed, Label, {command_status, Status}});
answered(Label, Command, {complete, Return}, Core) ->
    case erx_hci:return(name(Command), Return) of
        {ok, Value} -> bringup(Label, Value, Core);
        {failed, Status} -> stop({step_failed, Label, Status});
        malformed -> stop({step_failed, Label, malformed})
    end.

%% A command's outcome from either answer.
outcome(_Command, {status, ?ERX_HCI_STATUS_SUCCESS}) -> {ok, none};
outcome(_Command, {status, Status}) -> {failed, Status};
outcome(Command, {complete, Return}) -> erx_hci:return(name(Command), Return).

name({vendor, _, _}) -> vendor;
name(Command) when is_atom(Command) -> Command;
name(Command) -> element(1, Command).

%% What a bring-up step's answer decides.
bringup({first, read_local_version}, #{company := Company}, #core{manufacturer = Manufacturer})
  when Manufacturer =/= none, Company =/= Manufacturer ->
    stop({patch_for_other_controller, Company});
bringup({_Run, Name}, Value, #core{facts = Facts} = Core) when Name =:= read_local_version;
                                                               Name =:= read_local_commands;
                                                               Name =:= le_read_features;
                                                               Name =:= read_bd_addr ->
    {[], Core#core{facts = Facts#{Name => Value}}};
%% LE Read Buffer Size: a length or a count of 0 means no LE buffers of their own, so LE
%% shares the BR/EDR buffers, which Read Buffer Size gives (Part E, 7.8.2). Only LE
%% reserves the lengths 1 to 26; Read Buffer Size gives a length and a count from 1
%% (7.4.5).
bringup(buffers, {Length, Packets}, #core{plan = Plan} = Core) when Length =:= 0; Packets =:= 0 ->
    {[], Core#core{plan = [{command, shared_buffers, read_buffer_size} | Plan]}};
bringup(buffers, {Length, Packets}, Core) when Length >= ?ERX_HCI_LE_ACL_LENGTH_MIN ->
    {[], buffers(Length, Packets, Core)};
bringup(shared_buffers, {Length, Packets}, Core) when Length > 0, Packets > 0 ->
    {[], buffers(Length, Packets, Core)};
bringup(Label, {Length, Packets}, _Core) when Label =:= buffers; Label =:= shared_buffers ->
    stop({step_failed, Label, {buffers, Length, Packets}});
bringup(_Label, _Value, Core) ->
    {[], Core}.

%% The credits and the longest packet to the controller; the connection limit no more
%% than the credits, so each link's share is at least one.
buffers(Length, Packets, #core{limit = Limit} = Core) ->
    Credits = min(Packets, ?ERX_BT_ACL_CREDITS_MAX),
    Core#core{credits = Credits, acl_tx_max = Length, limit = min(Limit, Credits)}.

%% After every input: the bring-up's next wait or its end, the command slot, then the
%% writer's next item.
pump(Now, Core) ->
    {Steps, Stepped} = next_step(Now, Core),
    {Commands, Commanded} = command(Now, Stepped),
    {Writes, Written} = feed(Now, Commanded),
    {Steps ++ Commands ++ Writes, Written}.

next_step(Now, #core{stage = bringup, slot = idle, plan = [{wait, Milliseconds} | Plan]} = Core) ->
    {[], Core#core{plan = Plan, slot = {wait, Now + Milliseconds}}};
next_step(_Now, #core{stage = bringup, slot = idle, plan = []} = Core) ->
    {[{ready, facts(Core)}], Core#core{stage = ready}};
next_step(_Now, Core) ->
    {[], Core}.

%% The command due now, if any: its label, the command, and the state once it is taken
%% at Now (the plan's step popped, the disconnect marked taken under its deadline, or the
%% reply removed). Only feed/2 keeps that state; the other callers ask only whether a
%% command is due. In the bring-up, its next step; once ready, the first disconnect asked
%% for and not yet taken, else the first Long Term Key reply, else new advertising data,
%% else advertising while connections are below the limit.
due(_Now, #core{stage = bringup, plan = [{command, Label, Command} | Plan]} = Core) ->
    {Label, Command, Core#core{plan = Plan}};
due(Now, #core{stage = ready, disconnects = Disconnects} = Core) ->
    case [Asked || {_Handle, {asked, _Reason}} = Asked <- Disconnects] of
        [{Handle, {asked, Reason}} | _] ->
            Taken = {Handle, {taken, Now + ?ERX_BT_DISCONNECT_TIMEOUT_MS}},
            {{disconnect, Handle}, {disconnect, Handle, Reason},
             Core#core{disconnects = lists:keyreplace(Handle, 1, Disconnects, Taken)}};
        [] ->
            case reply(Core) of
                none -> advertising_data(Core);
                Reply -> Reply
            end
    end;
due(_Now, _Core) ->
    none.

reply(#core{replies = [{Handle, Key} | Replies]} = Core) ->
    {{ltk_reply, Handle}, ltk_command(Handle, Key), Core#core{replies = Replies}};
reply(_Core) ->
    none.

ltk_command(Handle, none) -> {le_long_term_key_request_negative_reply, Handle};
ltk_command(Handle, Key) -> {le_long_term_key_request_reply, Handle, Key}.

advertising_data(#core{advertising_data = none} = Core) ->
    advertise(Core);
advertising_data(#core{advertising_data = Data} = Core) ->
    {advertising_update, {le_set_advertising_data, Data}, Core#core{advertising_data = none}}.

advertise(#core{advertising = false, links = Links, limit = Limit} = Core) when map_size(Links) < Limit ->
    {advertise, {le_set_advertising_enable, true}, Core};
advertise(_Core) ->
    none.

%% The slot, when free or due: a command falling due starts its deadline, which runs
%% until the command is sent, or until the line would take a command and none is due,
%% when the slot empties and the deadline goes with it. While the line takes none, a
%% command that stops being due and falls due again keeps the deadline it first fell due
%% with, so connections that come and go cannot hold off a controller that allows none.
command(Now, #core{slot = idle} = Core) ->
    case due(Now, Core) of
        none -> {[], Core};
        _ -> {[], Core#core{slot = {due, Now + ?ERX_BT_COMMAND_TIMEOUT_MS}}}
    end;
command(Now, #core{slot = {due, _}} = Core) ->
    case due(Now, Core) =:= none andalso line_takes_command(Core) of
        true -> {[], Core#core{slot = idle}};
        false -> {[], Core}
    end;
command(_Now, Core) ->
    {[], Core}.

%% Whether the line takes a command now: the writer is idle and the controller allows one.
line_takes_command(#core{writer = Writer, allowed = Allowed}) -> Writer =:= idle andalso Allowed > 0.

%% The writer, when the line takes a command, takes the due one, which is decided and
%% sent at that moment and keeps the deadline it fell due with, else the next packet. The
%% slot is due here only with a command due: command/2 has just emptied it otherwise.
feed(Now, #core{writer = idle, slot = {due, Deadline}, allowed = Allowed} = Core) when Allowed > 0 ->
    {Label, Command, Taken} = due(Now, Core),
    {Opcode, Parameters} = erx_hci:command(Command),
    {[{write, erx_h4:command(Opcode, Parameters)}],
     Taken#core{writer = busy, slot = {sent, Label, Command, Opcode, Deadline}, allowed = Allowed - 1}};
feed(_Now, #core{writer = idle, out = [{_Handle, Packet} | Out]} = Core) ->
    {[{write, Packet}], Core#core{writer = busy, out = Out}};
feed(_Now, Core) ->
    {[], Core}.
