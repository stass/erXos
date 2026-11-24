%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bot).
-moduledoc """
The mass-storage function (docs/design-usb.md, "The BOT engine", "The
SCSI subset", "Media and drives"): the process that drives one claimed
Bulk-Only interface, its logical units and their media. Its decisions are
the pure `erx_usb_bot_core`, the engine, and unit/2 below, each unit's
course from INQUIRY to a ready medium; this module is their effects:
transfers and pipe resets through `erx_usb_pipe`, the CBW and the data
phase of a write through `erx_blk_write`, the class requests on EP0, the
timers, and one block transport, `erx_blk_usb`, for each ready medium.

**Start.** The bus process starts one per claimed interface, with its
bulk-IN and bulk-OUT pipes in the claim's order. Once told to go, it
starts the engine, which runs reset recovery and Get Max LUN; then each
unit the answer names begins.

**A unit.** Its INQUIRY decides whether it is served: a direct-access
device (type 0, qualifier 0) is; anything else, or an INQUIRY that fails,
is not, as a device that fails safe. A served unit is asked TEST UNIT
READY at once, then every usb_bot_poll_ms until it answers; then READ CAPACITY(10),
and (16) when (10) answers all ones, gives the capacity, served only in
512-byte blocks; then the readiness SYNCHRONIZE CACHE, the engine's
`ready` request under a fresh reference, makes the medium, and its
transport starts. A removable unit's medium is polled on, so a medium
taken out ends there. Any failure on the way leaves the unit to be polled
again. When the engine ends a medium, its transport is stopped and the
unit polls again for the next. A transport that ends on its own ends only
its medium: the function monitors each transport and hands its end to the
engine as the medium's end, so the unit's readiness sequence finds the
medium again under a fresh reference, and the function and its other
units run on.

**Requests.** A transport hands each block request to request/3, which
the engine queues under the caller's reply address; the answer is the
engine's.

**End.** A step of reset recovery that fails ends the function with
`{shutdown, {reset, Reason}}`, which the bus counts toward its restart
bound; a Get Max LUN answer above usb_bot_lun_max ends it unusable. The
device's detach makes every transfer answer `gone`, which reaches reset
recovery and ends the function so. Each transport monitors the function,
so it ends with the function.

**The block service.** A ready medium's block service is its transport
and the one window over the whole medium that the transport starts
(erx_blk_usb). A drive grant asked again for that window sends the
function `{erx_blk_drive, end_medium, {Lun, Ref}}`, and the function ends
the medium as a UNIT ATTENTION does: the transport and window stop, the
engine answers every request of the old reference `gone` unsent, and the
unit becomes ready again only through commands queued behind any already
issued (erx_blk_drive). A medium's transport is started with no drive
grant: the drives the manifest names do not reach the USB domain, so no
medium takes one (docs/todo-storage.md, the drives item).

Everything the device sends reaches only the engine's decoders, which
bound what they take; the INQUIRY's text is kept as bytes in the
transport's `detail`, escaped wherever it is shown.
""".

-behaviour(gen_server).

-export([start_link/1, request/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-include("generated/erx_abi.hrl").

%% A unit's course: asked its INQUIRY; served by none; waiting to poll; polled; asked its
%% capacity by READ CAPACITY(10) or (16); becoming ready; or serving a medium through its
%% transport. `poll` is the unit's one poll timer, which arming replaces.
-type unit() :: inquiring
              | {unserved, term()}
              | #{state := waiting | polling | capacity_10 | capacity_16 | readying | serving,
                  removable := boolean(), detail := map(), poll => reference(), capacity => pos_integer(),
                  ref => reference(), flush => boolean(), transport => {pid(), reference()}}.

-record(bot, {interface :: byte(),
              control :: erx_usb_pipe:pipe(),
              in :: erx_usb_pipe:pipe(),
              out :: erx_usb_pipe:pipe(),
              engine :: erx_usb_bot_core:state(),
              units = #{} :: #{erx_usb_bot_core:lun() => unit()},
              tick = none :: none | reference()}).

-doc "Starts a function on Start, linked to the caller.".
-spec start_link(erx_usb_bus:start()) -> {ok, pid()} | {error, term()}.
start_link(Start) ->
    gen_server:start_link(?MODULE, Start, []).

-doc "Runs Request for the medium Ref through Function's engine, and answers the engine's answer.".
-spec request(pid(), erx_usb_bot_core:medium_ref(), erx_usb_bot_core:request()) -> erx_usb_bot_core:reply().
request(Function, Ref, Request) ->
    gen_server:call(Function, {request, Ref, Request}, infinity).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(#{function := #{interface := Interface}, control := Control, pipes := [In, Out]}) ->
    {ok, #bot{interface = Interface, control = Control, in = In, out = Out, engine = erx_usb_bot_core:new()}}.

-doc false.
handle_call({request, Ref, Request}, From, B) ->
    run([{request, {call, From}, Ref, Request}], B).

-doc false.
handle_cast(_Request, B) ->
    {noreply, B}.

%% The bus process's go: the engine starts here, never in init/1.
-doc false.
handle_info({erx_usb_bus, go}, B) ->
    run([start], B);
handle_info({usb, Pipe, Tag, Result}, B = #bot{in = In, out = Out}) when Pipe =:= In; Pipe =:= Out ->
    run([{transfer, Tag, Result}], B);
handle_info({timeout, Tick, tick}, B = #bot{tick = Tick}) ->
    run([tick], B#bot{tick = none});
handle_info({timeout, Timer, {poll, Lun}}, B = #bot{units = Units}) ->
    case Units of
        #{Lun := #{poll := Timer}} -> poll(Lun, B);
        #{} -> {noreply, B}
    end;
%% A transport's end is its medium's; a transport already stopped was demonitored then.
handle_info({'DOWN', Monitor, process, _Transport, Reason}, B = #bot{units = Units}) ->
    %% A generator's pattern shadows Monitor rather than matching it, hence the filter.
    case [{Lun, Ref} || Lun := #{transport := {_Pid, Watch}, ref := Ref} <- Units, Watch =:= Monitor] of
        [{Lun, Ref}] ->
            %% The transport is gone: its medium's end is logged here, and the unit holds it no more.
            log_medium_ended(Lun, erx_report:reason_name(Reason)),
            run([{end_medium, Lun, Ref}], B#bot{units = Units#{Lun := maps:remove(transport, maps:get(Lun, Units))}});
        [] -> {noreply, B}
    end;
%% A drive grant asked again for the medium's window: the medium ends as a UNIT ATTENTION
%% ends it, here at once, so its transport and window end and the engine refuses every
%% request of the old reference; the unit's readiness sequence, behind any command
%% already issued, makes the next medium. A reference that is not the unit's current
%% medium ends nothing.
handle_info({erx_blk_drive, end_medium, {Lun, Ref}}, B = #bot{units = Units}) ->
    case Units of
        #{Lun := Unit = #{ref := Ref}} ->
            log_medium_ended(Lun, restart),
            Stopped = stop_transport(Unit, maps:remove(transport, Unit)),
            run([{end_medium, Lun, Ref}], B#bot{units = Units#{Lun := Stopped}});
        #{} -> {noreply, B}
    end;
handle_info(_Message, B) ->
    {noreply, B}.

%% A crash report shows the function's interface, its units' states and a message's kind;
%% never the engine's data, a unit's INQUIRY text or a message's bytes, which are a
%% medium's sectors or what the device sent. erx_report:status/2 hides the log and cuts
%% the reason to its leading atom (docs/design-log.md, "Reports carry no term").
-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun bot_facts/1, message => fun message_kind/1}).

bot_facts(#bot{interface = Interface, units = Units}) ->
    #{interface => Interface, units => maps:map(fun(_Lun, Unit) -> course(Unit) end, Units)};
bot_facts(_State) ->
    hidden.

course(#{state := State}) -> State;
course({unserved, Reason}) -> {unserved, erx_report:reason_name(Reason)};
course(inquiring) -> inquiring;
course(_Unit) -> hidden.

message_kind({request, _Ref, Request}) -> {request, erx_report:reason_name(Request)};
message_kind(Message) -> erx_report:reason_name(Message).

%% ---------------------------------------------------------------------------
%% The engine's events and actions
%% ---------------------------------------------------------------------------

%% Steps the engine through Events in order. An action whose effect answers at once (a
%% pipe reset, a class request) and a unit's next request each add an event behind the
%% rest, so every event is stepped once the actions before it are done.
run([], B = #bot{engine = Engine}) ->
    {noreply, schedule(erx_usb_bot_core:deadline(Engine), B)};
run([Event | Events], B = #bot{engine = Engine}) ->
    {Next, Actions} = erx_usb_bot_core:step(Event, monotonic_ms(), Engine),
    perform(Actions, Events, B#bot{engine = Next}).

perform([], Events, B) ->
    run(Events, B);
perform([{stop, Reason} | _Actions], _Events, B) ->
    {stop, stop_reason(Reason), B};
perform([Action | Actions], Events, B) ->
    {More, Next} = act(Action, B),
    perform(Actions, Events ++ More, Next).

stop_reason({max_lun, Max}) -> erx_usb_bus_core:unusable({max_lun, Max});
stop_reason(Reset = {reset, _Reason}) -> {shutdown, Reset}.

act({command, Tag, Command}, B = #bot{out = Out}) ->
    ok = erx_blk_write:bot_command(Out, Tag, Command),
    {[], B};
act({data_out, Tag, Command}, B = #bot{out = Out}) ->
    ok = erx_blk_write:bot_data_out(Out, Tag, Command),
    {[], B};
act({data_in, Tag, Length}, B = #bot{in = In}) ->
    ok = erx_usb_pipe:bulk_in(In, Tag, Length),
    {[], B};
act({status, Tag}, B = #bot{in = In}) ->
    ok = erx_usb_pipe:bulk_in(In, Tag, ?ERX_USB_BOT_CSW_SIZE),
    {[], B};
act({reset_pipe, in}, B = #bot{in = In}) ->
    {[{reset_pipe, erx_usb_pipe:reset_pipe(In)}], B};
act({reset_pipe, out}, B = #bot{out = Out}) ->
    {[{reset_pipe, erx_usb_pipe:reset_pipe(Out)}], B};
act(class_reset, B = #bot{control = Control, interface = Interface}) ->
    Setup = erx_usb_setup:packet(?ERX_USB_REQUEST_TYPE_CLASS bor ?ERX_USB_RECIPIENT_INTERFACE,
                                 ?ERX_USB_BOT_REQUEST_RESET, 0, Interface, 0),
    {[{control, erx_usb_pipe:control(Control, Setup, none)}], B};
act(get_max_lun, B = #bot{control = Control, interface = Interface}) ->
    Setup = erx_usb_setup:packet(?ERX_USB_REQUEST_DIR_IN bor ?ERX_USB_REQUEST_TYPE_CLASS
                                 bor ?ERX_USB_RECIPIENT_INTERFACE, ?ERX_USB_BOT_REQUEST_GET_MAX_LUN, 0, Interface, 1),
    {[{control, erx_usb_pipe:control(Control, Setup, {in, 1})}], B};
act({answer, {call, From}, Reply}, B) ->
    gen_server:reply(From, Reply),
    {[], B};
act({answer, {unit, Lun}, Reply}, B = #bot{units = Units}) ->
    advance(Lun, unit(maps:get(Lun, Units), Reply), B);
act({units, Count}, B) ->
    Luns = lists:seq(0, Count - 1),
    {[{request, {unit, Lun}, none, {inquiry, Lun}} || Lun <- Luns],
     B#bot{units = maps:from_keys(Luns, inquiring)}};
act({medium_ended, Lun, Ref}, B = #bot{units = Units}) ->
    case maps:get(Lun, Units) of
        Unit = #{ref := Ref} ->
            is_map_key(transport, Unit) andalso log_medium_ended(Lun, device),
            advance(Lun, {ended(Unit), wait}, B);
        _Other -> {[], B}
    end.

%% ---------------------------------------------------------------------------
%% A unit's course
%% ---------------------------------------------------------------------------

%% A unit's next state on the Reply to its last request, and what it does next: ask the
%% engine, wait to poll, start its medium's transport, or nothing.
-spec unit(unit(), erx_usb_bot_core:reply()) ->
          {unit(), {ask, test_unit_ready | read_capacity_10 | read_capacity_16 | ready} | wait | serve | none}.
unit(inquiring, {ok, Inquiry = #{type := 0, qualifier := 0, removable := Removable}}) ->
    {#{state => polling, removable => Removable, detail => maps:with([vendor, product], Inquiry)},
     {ask, test_unit_ready}};
unit(inquiring, {ok, #{type := Type, qualifier := Qualifier}}) ->
    {{unserved, {type, Type, Qualifier}}, none};
unit(inquiring, {error, Reason}) ->
    {{unserved, Reason}, none};
unit(Unit = #{state := polling}, ok) ->
    {Unit#{state := capacity_10}, {ask, read_capacity_10}};
unit(Unit = #{state := capacity_10}, {ok, #{last_block := 16#ffffffff}}) ->
    {Unit#{state := capacity_16}, {ask, read_capacity_16}};
unit(Unit = #{state := State}, {ok, #{last_block := Last, block_length := ?ERX_SCSI_BLOCK_LENGTH}})
  when State =:= capacity_10; State =:= capacity_16 ->
    {Unit#{state := readying, capacity => Last + 1, ref => make_ref()}, {ask, ready}};
unit(Unit = #{state := readying}, {ok, #{flush := Flush}}) ->
    {Unit#{state := serving, flush => Flush}, serve};
unit(Unit = #{state := serving}, _PollAnswer) ->
    {Unit, wait};
unit(Unit = #{state := _OnTheWay}, _Failure) ->
    {ended(Unit), wait}.

ended(Unit) ->
    maps:without([capacity, ref, flush, transport], Unit#{state := waiting}).

advance(Lun, {Unit, Next}, B = #bot{units = Units}) ->
    effect(Lun, Next, B#bot{units = Units#{Lun := stop_transport(maps:get(Lun, Units), Unit)}}).

%% A transport that served a medium the unit no longer holds is stopped.
stop_transport(#{transport := {Transport, Monitor}}, Unit) when not is_map_key(transport, Unit) ->
    demonitor(Monitor, [flush]),
    exit(Transport, shutdown),
    Unit;
stop_transport(_Old, Unit) ->
    Unit.

effect(_Lun, none, B) ->
    {[], B};
effect(Lun, wait, B = #bot{units = Units}) ->
    Unit = maps:get(Lun, Units),
    _ = maps:is_key(poll, Unit) andalso erlang:cancel_timer(maps:get(poll, Unit)),
    Timer = erlang:start_timer(?ERX_USB_BOT_POLL_MS, self(), {poll, Lun}),
    {[], B#bot{units = Units#{Lun := Unit#{poll => Timer}}}};
effect(Lun, {ask, ready}, B = #bot{units = Units}) ->
    #{Lun := #{ref := Ref}} = Units,
    {[{request, {unit, Lun}, none, {ready, Lun, Ref}}], B};
effect(Lun, {ask, Command}, B) ->
    {[{request, {unit, Lun}, none, {Command, Lun}}], B};
effect(Lun, serve, B = #bot{units = Units}) ->
    Unit = #{ref := Ref, capacity := Capacity, flush := Flush, detail := Detail, removable := Removable} =
        maps:get(Lun, Units),
    {ok, Transport} = erx_blk_usb:start_monitor(#{function => self(), lun => Lun, ref => Ref, capacity => Capacity,
                                                  flush => Flush, detail => Detail, drive => none}),
    Serving = B#bot{units = Units#{Lun := Unit#{transport => Transport}}},
    logger:notice("erx_usb_bot: medium LUN ~b ready: ~b blocks of ~b bytes", [Lun, Capacity, ?ERX_SCSI_BLOCK_LENGTH]),
    case Removable of
        true -> effect(Lun, wait, Serving);
        false -> {[], Serving}
    end.

%% A served medium's end, logged where the function sees it: its transport's end (the
%% transport's reason) or the engine's (`device'). The function's own end logs none.
%% Integers and atoms only: the unit's INQUIRY text is the device's and never reaches the log.
log_medium_ended(Lun, Reason) ->
    logger:notice("erx_usb_bot: medium LUN ~b ended: ~w", [Lun, Reason]).

%% A unit still without a medium is polled for one; a removable unit's medium is polled
%% under its reference, so the poll is answered gone, unsent, once the medium has ended.
poll(Lun, B = #bot{units = Units}) ->
    case maps:get(Lun, Units) of
        Unit = #{state := waiting} ->
            run([{request, {unit, Lun}, none, {test_unit_ready, Lun}}],
                B#bot{units = Units#{Lun := Unit#{state := polling}}});
        #{state := serving, ref := Ref} ->
            run([{request, {unit, Lun}, Ref, {test_unit_ready, Lun}}], B)
    end.

%% ---------------------------------------------------------------------------
%% Time
%% ---------------------------------------------------------------------------

monotonic_ms() -> erlang:monotonic_time(millisecond).

%% One tick timer, at the engine's next deadline.
schedule(Deadline, B = #bot{tick = Old}) ->
    _ = Old =/= none andalso erlang:cancel_timer(Old),
    case Deadline of
        infinity -> B#bot{tick = none};
        At -> B#bot{tick = erlang:start_timer(At, self(), tick, [{abs, true}])}
    end.
