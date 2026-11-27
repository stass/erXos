%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_bot_core (docs/design-usb.md, "The BOT engine" and "Media and
%% drives"): the engine explored to a fixed point over two units, two media generations
%% a unit and every CSW and sense outcome, against a model device and the invariants the
%% design states; BOT 1.0's thirteen cases (section 6.7) as a table; traces of autosense,
%% readiness, the medium reference, the deadlines and the start; and the decoders on
%% written cases. Every number is written out here, so a bound changed in
%% abi/formats/usb.txt fails a case instead of moving with the module.
-module(erx_usb_bot_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([explore/0]).

-define(CSW_SIGNATURE, 16#53425355).
-define(NOT_READY, 2).
-define(MEDIUM_ERROR, 3).
-define(ILLEGAL_REQUEST, 5).
-define(UNIT_ATTENTION, 6).
-define(DATA_PROTECT, 7).


%% ---------------------------------------------------------------------------------------
%% The engine explored to a fixed point.
%%
%% The model plays the function and the device. The function submits a script of
%% requests, in order, each either while the engine is idle or just after it posts a CBW,
%% which puts the request in the queue behind a whole operation. A write's two data bytes
%% name its unit and medium, so the device knows which medium a write is for.
%%
%% Three kinds of model, each explored to a fixed point:
%% * every first operation: from an engine whose unit 0 has a medium, one operation of
%%   each kind (a write, a flush, a read, an INQUIRY, a readiness) with requests queued
%%   behind it, the device answering the operation every way the design distinguishes: a
%%   CBW taken or stalled; a data phase whole, short or stalled; a CSW good, good with all
%%   its length left over, failed, a phase error, of another tag, with a residue past its
%%   length, or stalled, and again after the stall; sense data of the key the device
%%   holds, short, or of an unknown format; each step of recovery done or failed.
%%   The requests behind it are answered with success, so the model stays small;
%% * two units, two media generations a unit: a script that makes each unit's first
%%   medium ready, writes and flushes it, makes its second medium ready, writes the first
%%   again, ended by then if the device reported its end, and writes the second, the
%%   device answering each operation with every outcome class: success, a phase error,
%%   or a failed status whose sense is read or fails;
%% * the recovery ladder: two writes of different blocks, the first of which the device
%%   answers with a good CSW, a phase error or MEDIUM ERROR, never completes, or completes
%%   only after its transfer was cancelled; and whose steps of recovery it answers at
%%   once, just before the next deadline, with a failure, or never; and, at any moment,
%%   the function's word that the medium's transport has ended. Time runs in this model
%%   alone: a tick comes at deadline/1, and a slow answer one millisecond before it.
%% The split keeps the exploration short: every CSW and sense outcome in every medium
%% generation would multiply the outcomes of each operation across the script, and so
%% would time.
%% A failed status with a meaningful CSW holds a sense: UNIT ATTENTION, NOT READY, ILLEGAL
%% REQUEST or MEDIUM ERROR, the first two ending the unit's medium on the device at that
%% moment; the two-unit model leaves out MEDIUM ERROR, whose retries the other two cover.
%%
%% The invariants, checked at every step:
%% * a CSW calls for reset recovery exactly when BOT 1.0 says (6.3, 6.5): invalid, not
%%   meaningful, a phase error, or a metadata command's relevant bytes past what moved;
%%   for an operation that has been through recovery once, the port instead
%%   (`{stop, {reset_port, again, _}}`), and never a second recovery;
%% * REQUEST SENSE is sent only right after a meaningful failed status of another command
%%   on its unit;
%% * no write is sent for a medium that has ended, on the device, in the engine or by the
%%   function's word, a retry included;
%% * every send of an operation's command, a retry included, is its request's command
%%   exactly, and every data phase is its CBW's: its tag, a write's data, a read's length;
%% * a medium ends in the engine only as its unit's current one;
%% * a medium becomes ready only on a unit with none, and flushes exactly when its
%%   readiness drew no ILLEGAL REQUEST; a flush of one that cannot is answered no_flush;
%% * no class reset, and no other transfer, while a bulk transfer is posted: one the engine
%%   stopped waiting on is cancelled first, by a reset of the pipe it is posted on, and
%%   counts as posted until the cancel is done;
%% * whenever the engine waits, deadline/1 is no later than the wait's own bound: 5 s
%%   (usb_bot_recovery_step_ms) for a step of recovery, 8 s (usb_bot_attempt_ms) for a
%%   bulk transfer;
%% * a rung of the ladder (the cancel, reset_1 to reset_3) that fails or times out ends
%%   the function as `{stop, {reset_port, Rung, _}}` naming it, and nothing else does;
%% * an operation's command is sent at most five times (usb_bot_retries 4), and an
%%   operation is answered with `reset` or a retried sense (MEDIUM ERROR, HARDWARE ERROR,
%%   ABORTED COMMAND) only once all five are spent;
%% * the late completion of a cancelled transfer, and the late answer of a step, change
%%   nothing; a tick at deadline/1 changes the engine;
%% * every request is answered once, and, unless the function stopped, every request is
%%   answered when nothing is left to happen.
the_engine_explored_keeps_its_invariants_test_() ->
    {timeout, 600, fun() -> ?assertMatch({ok, _}, explore()) end}.

explore() ->
    explore_models([first_write, first_flush, first_read, first_inquiry, first_ready, two_units, ladder], []).

explore_models([], Counts) ->
    io:format(user, "~nerx_usb_bot_core explored to a fixed point: ~p~n", [lists:reverse(Counts)]),
    {ok, lists:reverse(Counts)};
explore_models([Name | Rest], Counts) ->
    {State, Model} = model(Name),
    case explore([{State, Model}], #{{State, Model} => true}) of
        {ok, Seen} -> explore_models(Rest, [{Name, Seen} | Counts]);
        {error, Why} -> {error, {Name, Why}}
    end.

%% The engine and model each kind starts from. Unit 0's first medium is ready, but for
%% the two-unit model, which makes every medium ready itself.
model(Name) ->
    {Ready, First} = ready(started(), 0, true),
    Refs = #{{0, 1} => First, {0, 2} => make_ref(), {1, 1} => make_ref(), {1, 2} => make_ref()},
    Ref = fun(Lun, Gen) -> maps:get({Lun, Gen}, Refs) end,
    Write = fun(Lun, Gen) -> {Ref(Lun, Gen), {write, Lun, 0, <<Lun, Gen>>}} end,
    {State, Mode, Current, Script} =
        case Name of
            first_write -> {Ready, full, First, [Write(0, 1), Write(0, 1), {none, {test_unit_ready, 1}}]};
            first_flush -> {Ready, full, First, [{First, {flush, 0}}, Write(0, 1)]};
            first_read -> {Ready, full, First, [{First, {read, 0, 0, 1}}, Write(0, 1)]};
            first_inquiry -> {Ready, full, First, [{none, {inquiry, 1}}, Write(0, 1)]};
            first_ready -> {Ready, full, First, [{none, {ready, 1, Ref(1, 1)}}, {Ref(1, 1), {flush, 1}},
                                                 Write(1, 1)]};
            two_units ->
                {started(), classes, none,
                 [{none, {ready, 0, Ref(0, 1)}}, {none, {ready, 1, Ref(1, 1)}}, Write(0, 1), Write(1, 1),
                  {Ref(0, 1), {flush, 0}}, {none, {ready, 0, Ref(0, 2)}}, Write(0, 1), {none, {ready, 1, Ref(1, 2)}},
                  Write(0, 2), Write(1, 2)]};
            ladder -> {Ready, ladder, First, [Write(0, 1), {First, {write, 0, 1, <<0, 1>>}}]}
        end,
    %% `op` is the script index of the operation on the wire, `attempts` how often its
    %% command was sent, `marked` whether it has been through recovery; `rung` is the rung
    %% of the ladder the engine waits on; `posted` the tag of a bulk transfer the engine
    %% has cancelled and the controller not yet stopped, `stale` one that has stopped and
    %% whose completion may still arrive.
    {State, #{refs => Refs, script => Script, cursor => 1, answered => [], mode => Mode, pending => none,
              current => #{0 => Current, 1 => none}, dead => [], flushless => [], held => none,
              sense_allowed => none, last_key => #{0 => none, 1 => none}, wire => none, wire_tag => none,
              moved => 0, stopped => false, now => 0, op => none, attempts => 0, marked => false, rung => none,
              posted => none, stale => none, ends => Name =:= ladder}}.

explore([], Seen) ->
    {ok, map_size(Seen)};
explore([{State, Model} | Rest], Seen) ->
    case events(State, Model) of
        [] ->
            case finished(Model) of
                ok -> explore(Rest, Seen);
                {error, Why} -> {error, Why}
            end;
        Events ->
            case follow_all(Events, State, Model, []) of
                {ok, Nodes} ->
                    New = lists:usort([Node || Node <- Nodes, not is_map_key(Node, Seen)]),
                    explore(New ++ Rest, maps:merge(Seen, maps:from_keys(New, true)));
                {error, Why} ->
                    {error, Why}
            end
    end.

follow_all([], _State, _Model, Nodes) ->
    {ok, Nodes};
follow_all([{Event, Heard, At} | Rest], State, Model, Nodes) ->
    {Next, Actions} = erx_usb_bot_core:step(Event, At, State),
    case observe(Heard, Actions, heard(Heard, Model#{now := At}), {State, Next}) of
        {ok, M} -> follow_all(Rest, State, Model, [{Next, M} | Nodes]);
        {error, Why} -> {error, {Why, Event, At, Actions}}
    end.

%% The events possible in Model, each with what the model remembers of it and its time:
%% the device's answer to what the engine waits on, in the ladder model also a tick and a
%% slow answer, the script's next request while the function is not inside a call, and a
%% cancelled transfer's late completion.
events(_State, #{stopped := true}) ->
    [];
events(State, Model = #{pending := Pending, script := Script, cursor := Cursor, now := Now}) ->
    Answers = case Pending of
                  {_Kind, Action} -> [{Event, Heard, Now} || {Event, Heard} <- device(Action, Model)]
                                         ++ ladder(State, Model);
                  none -> []
              end,
    Next = [begin
                {Medium, Request} = lists:nth(Cursor, Script),
                {{request, Cursor, Medium, Request}, submitted, Now}
            end || submits(Pending), Cursor =< length(Script)],
    Late = [{{transfer, Tag, {error, stopped}}, stale, Now} || Tag <- [maps:get(stale, Model)], Tag =/= none],
    Answers ++ Next ++ Late ++ late_steps(Model) ++ function_ends(Model).

%% In the ladder model, the function's word that a medium's transport has ended, at any
%% moment its medium is current: an operation for it may be on the wire, and its caller
%% is gone.
function_ends(#{ends := true, current := Current, now := Now}) ->
    [{{end_medium, Lun, Ref}, {function_ended, Lun, Ref}, Now} || {Lun, Ref} <- maps:to_list(Current), Ref =/= none];
function_ends(_Model) ->
    [].

%% In the ladder model, while the engine waits on a bulk transfer, the answer of a step it
%% gave up on: the function drops one under a reference it no longer holds, but one under
%% the reference it still holds reaches the engine.
late_steps(#{mode := ladder, pending := {bulk, _Transfer}, now := Now}) ->
    [{Event, late_step, Now} || Event <- [{control, {error, gone}}, {reset_pipe, ok}]];
late_steps(_Model) ->
    [].

submits(none) -> true;
submits({bulk, {command, _Tag, _Command}}) -> true;
submits(_Pending) -> false.

%% In the ladder model, the tick at the engine's deadline, the wait unanswered; and a step
%% of recovery answered just before that deadline.
ladder(State, #{mode := ladder, pending := {Kind, Action}, now := Now}) ->
    case erx_usb_bot_core:deadline(State) of
        infinity ->
            [];
        At ->
            Slow = [{Event, done, At - 1} || Kind =:= sync, At - 1 > Now, {Event, done} <- device(Action, #{mode => success})],
            [{tick, tick, max(At, Now)} | Slow]
    end;
ladder(_State, _Model) ->
    [].

%% The device's answers to Action, each paired with what the model remembers of it.
device(class_reset, #{mode := Mode}) ->
    [{{control, {ok, <<>>}}, done} | [{{control, {error, stall}}, failed_step} || faults(Mode)]];
device({reset_pipe, _Pipe}, #{mode := Mode}) ->
    [{{reset_pipe, ok}, done} | [{{reset_pipe, {error, gone}}, failed_step} || faults(Mode)]];
device({command, Tag, _Command}, #{mode := Mode}) ->
    [{{transfer, Tag, {ok, 31}}, done} | [{{transfer, Tag, {error, stall}}, {moved, 0}} || Mode =:= full]];
device({data_out, Tag, {write, _Lun, _Sector, Data}}, #{mode := Mode}) ->
    Whole = byte_size(Data),
    [{{transfer, Tag, {ok, Whole}}, {moved, Whole}}
     | [Answer || Mode =:= full, Answer <- [{{transfer, Tag, {ok, Whole - 1}}, {moved, Whole - 1}},
                                            {{transfer, Tag, {error, stall}}, {moved, 0}}]]];
device({data_in, Tag, _Length}, #{mode := Mode, wire := Command, held := Held}) ->
    {Whole, Partial} = data(Command, Held),
    [{{transfer, Tag, {ok, Whole}}, {data, Whole}}
     | [Answer || Mode =:= full, Answer <- [{{transfer, Tag, {ok, Bytes}}, {data, Bytes}} || Bytes <- Partial]
                                           ++ [{{transfer, Tag, {error, stall}}, {moved, 0}}]]];
device({status, Tag}, #{mode := Mode, wire := Command}) ->
    Length = length_of(Command),
    Csw = fun(T, Residue, Status, Held) ->
                  {{transfer, Tag, {ok, csw(T, Residue, Status)}}, {csw, T, Residue, Status, Held}}
          end,
    {Failed, Retried} = case Command of
                            {request_sense, _Lun} -> {[Csw(Tag, 0, 1, none)], []};
                            _Other -> {[Csw(Tag, 0, 1, Key)
                                        || Key <- [?UNIT_ATTENTION, ?NOT_READY, ?ILLEGAL_REQUEST, ?MEDIUM_ERROR]],
                                       [Csw(Tag, 0, 2, none), Csw(Tag, 0, 1, ?MEDIUM_ERROR)]}
                        end,
    case Mode of
        success -> [Csw(Tag, 0, 0, none)];
        ladder -> [Csw(Tag, 0, 0, none) | Retried];
        classes -> [Csw(Tag, 0, 0, none), Csw(Tag, 0, 2, none) | lists:droplast(Failed)];
        full -> [Csw(Tag, 0, 0, none), Csw(Tag, Length, 0, none), Csw(Tag, 0, 2, none), Csw(Tag + 1, 0, 0, none),
                 Csw(Tag, Length + 1, 0, none), {{transfer, Tag, {error, stall}}, done} | Failed]
    end.

%% Whether the device may fail a step of recovery.
faults(Mode) -> Mode =:= full orelse Mode =:= ladder.

%% The data a data-in command's device sends whole, and the partial answers it may give:
%% sense data of the key it holds, short or of another format; a read short by half; an
%% INQUIRY's header alone or less.
data({request_sense, _Lun}, Held) ->
    Key = case Held of
              {_Unit, K} -> K;
              none -> 0
          end,
    {sense_bytes(16#70, Key), [binary:part(sense_bytes(16#70, Key), 0, 13), sense_bytes(16#72, Key)]};
data({read, _Lun, _Sector, Count}, _Held) ->
    {binary:copy(<<16#5a>>, 512 * Count), [binary:copy(<<16#5a>>, 256 * Count)]};
data({inquiry, _Lun}, _Held) ->
    {inquiry_bytes(36), [inquiry_bytes(5), inquiry_bytes(4)]}.

%% What the model learns from the answer it gave, before it reads the engine's actions. A
%% tick changes nothing the model knows: what the engine gave up on, it says by acting.
heard(submitted, Model = #{cursor := Cursor}) ->
    Model#{cursor := Cursor + 1};
heard(tick, Model) ->
    Model;
heard(stale, Model) ->
    Model#{stale := none};
heard(late_step, Model) ->
    Model;
heard({function_ended, _Lun, Ref}, Model = #{dead := Dead}) ->
    Model#{dead := lists:usort([Ref | Dead])};
heard(done, Model = #{pending := {sync, {reset_pipe, _Pipe}}, posted := Tag}) when Tag =/= none ->
    Model#{pending := none, posted := none, stale := Tag};
heard(Step, Model) when Step =:= done; Step =:= failed_step ->
    Model#{pending := none};
heard({moved, Moved}, Model) ->
    Model#{pending := none, moved := Moved};
heard({data, Bytes}, Model = #{wire := {request_sense, Lun}, last_key := Keys}) ->
    Key = case sense_key(Bytes) of
              {ok, K} -> K;
              none -> maps:get(Lun, Keys)
          end,
    Model#{pending := none, moved := byte_size(Bytes), last_key := Keys#{Lun := Key}};
heard({data, Bytes}, Model) ->
    Model#{pending := none, moved := byte_size(Bytes)};
heard({csw, _Tag, _Residue, _Status, Held}, Model = #{wire := Command, current := Current, dead := Dead}) ->
    Lun = element(2, Command),
    Ended = case Held of
                Key when Key =:= ?UNIT_ATTENTION; Key =:= ?NOT_READY -> [maps:get(Lun, Current)];
                _Kept -> []
            end,
    Model#{pending := none, held := held(Lun, Held), dead := lists:usort(Dead ++ [Ref || Ref <- Ended, Ref =/= none])}.

%% The key of 18 bytes of fixed-format sense data as the device sent it, read here from
%% the written layout: response code 70h, key in byte 2.
sense_key(<<16#70, _, Key, _:15/binary>>) -> {ok, Key};
sense_key(_Other) -> none.

held(_Lun, none) -> none;
held(Lun, Key) -> {Lun, Key}.

%% Reads the engine's actions after the answer Heard, checking each invariant; Before and
%% After are the engine's states around the step.
observe(Heard, Actions, Model, {Before, After}) ->
    try
        case Heard of
            stale -> check(Actions =:= [] andalso After =:= Before, stale_completion_taken);
            late_step -> check(Actions =:= [] andalso After =:= Before, late_step_answer_taken);
            tick -> check(After =/= Before, tick_at_deadline_changed_nothing);
            {function_ended, Lun, Ref} -> check(lists:member({medium_ended, Lun, Ref}, Actions),
                                                {function_end_not_taken, Lun});
            _Other -> ok
        end,
        case expects_reset(Heard, Model) of
            none -> ok;
            true -> check(lists:member(class_reset, Actions) orelse (maps:get(marked, Model) andalso again(Actions)),
                          {reset_expected, true});
            false -> check(not lists:member(class_reset, Actions), {reset_expected, false})
        end,
        rung(Heard, Actions, Model),
        Allowed = sense_allowed(Heard, Model),
        Observed = idle(lists:foldl(fun action/2, Model#{sense_allowed := Allowed}, Actions)),
        bounded(After, Observed),
        {ok, Observed}
    catch
        throw:{violation, Why} -> {error, Why}
    end.

again(Actions) ->
    lists:any(fun(Action) -> element(1, Action) =:= stop andalso element(1, element(2, Action)) =:= reset_port
                                 andalso element(2, element(2, Action)) =:= again end, Actions).

%% A rung that fails ends the function naming it; on a tick it times out the same way or
%% waits on, never steps elsewhere; and only a rung, or `again`, is named in a port reset.
rung(Heard, Actions, #{rung := Rung}) ->
    Named = [R || {stop, {reset_port, R, _Reason}} <- Actions],
    check(lists:all(fun(R) -> R =:= again orelse (R =:= Rung andalso Rung =/= none) end, Named),
          {port_reset_names_another_rung, Rung, Named}),
    case {Heard, Rung} of
        {_Heard, none} -> ok;
        {failed_step, _Rung} -> check(Named =:= [Rung] andalso not lists:any(fun waits/1, Actions),
                                      {failed_rung_not_to_port, Rung});
        {tick, _Rung} -> check(not lists:any(fun waits/1, Actions), {timed_out_rung_not_to_port, Rung});
        {_Heard, _Rung} -> ok
    end.

waits(Action) ->
    lists:member(Action, [class_reset, get_max_lun])
        orelse lists:member(element(1, Action), [reset_pipe, command, data_in, data_out, status]).

%% Whether a CSW calls for reset recovery, by BOT 1.0's rules written here.
expects_reset({csw, Tag, Residue, Status, _Held}, #{wire := Command, wire_tag := WireTag, moved := Moved}) ->
    Length = length_of(Command),
    if
        Tag =/= WireTag -> true;
        Status =:= 2 -> true;
        Residue > Length -> true;
        Status =:= 0 -> metadata(Command) andalso Length - Residue > Moved;
        true -> false
    end;
expects_reset(_Heard, _Model) ->
    none.

sense_allowed({csw, Tag, Residue, 1, _Held}, #{wire := Command, wire_tag := WireTag}) ->
    case Tag =:= WireTag andalso Residue =< length_of(Command) andalso element(1, Command) =/= request_sense of
        true -> element(2, Command);
        false -> none
    end;
sense_allowed(_Heard, #{sense_allowed := Allowed}) ->
    Allowed.

%% Whenever the engine waits, its deadline is no later than the wait's own bound: 5 s for
%% a step of recovery, 8 s for a bulk transfer, as abi/formats/usb.txt sets them.
bounded(_State, #{stopped := true}) ->
    ok;
bounded(_State, #{pending := none}) ->
    ok;
bounded(State, #{pending := {Kind, _Action}, now := Now}) ->
    Bound = Now + case Kind of
                      sync -> 5000;
                      bulk -> 8000
                  end,
    Deadline = erx_usb_bot_core:deadline(State),
    check(is_integer(Deadline) andalso Deadline =< Bound, {wait_past_its_bound, Kind, Deadline, Bound}).

%% With no transfer outstanding the engine is idle, and what the model kept of the last
%% command no longer matters; forgetting it lets idle states that differ only by it merge.
idle(Model = #{pending := none}) ->
    Model#{wire := none, wire_tag := none, moved := 0, held := none, sense_allowed := none,
           last_key := #{0 => none, 1 => none}, op := none, attempts := 0, marked := false, rung := none};
idle(Model) ->
    Model.

action({command, Tag, Command}, Model = #{sense_allowed := Allowed, dead := Dead, refs := Refs,
                                          last_key := Keys, pending := Pending, posted := Posted,
                                          script := Script}) ->
    check(not is_bulk(Pending) andalso Posted =:= none, transfer_while_posted),
    Lun = element(2, Command),
    case Command of
        {request_sense, Lun} -> check(Allowed =:= Lun, {sense_not_after_failure, Lun});
        {write, Lun, _Sector, <<Lun, Gen>>} -> check(not lists:member(maps:get({Lun, Gen}, Refs), Dead),
                                                    {write_to_ended_medium, Lun, Gen});
        _Other -> ok
    end,
    Fresh = case Command of
                {request_sense, _} -> Model;
                _NewCommand -> attempt(Model#{held := none, last_key := Keys#{Lun := none}})
            end,
    %% Each send of an operation's command, a retry included, is its request's command
    %% exactly: the same unit, blocks and data.
    case {Command, Fresh} of
        {{request_sense, _}, _Model} -> ok;
        {_Command, #{op := Op}} -> check(Command =:= command_of(element(2, lists:nth(Op, Script))),
                                         {command_not_its_request, Op, Command})
    end,
    Fresh#{pending := {bulk, {command, Tag, Command}}, wire := Command, wire_tag := Tag, moved := 0,
           sense_allowed := none, rung := none};
action(Transfer = {Kind, Tag, Detail}, Model = #{pending := Pending, posted := Posted, wire := Wire,
                                                wire_tag := WireTag})
  when Kind =:= data_in; Kind =:= data_out ->
    check(not is_bulk(Pending) andalso Posted =:= none, transfer_while_posted),
    %% The data phase is its CBW's own: that tag, and a write's data or a read's length.
    Own = case Kind of
              data_out -> Wire;
              data_in -> length_of(Wire)
          end,
    check(Tag =:= WireTag andalso Detail =:= Own, {data_phase_not_its_cbw, Transfer, Wire}),
    Model#{pending := {bulk, Transfer}, rung := none};
action(Transfer = {status, _Tag}, Model = #{pending := Pending, posted := Posted}) ->
    check(not is_bulk(Pending) andalso Posted =:= none, transfer_while_posted),
    Model#{pending := {bulk, Transfer}, rung := none};
action(class_reset, Model = #{pending := Pending, posted := Posted, rung := Rung}) ->
    check(not is_bulk(Pending) andalso Posted =:= none, class_reset_while_posted),
    Recovery = case Rung of
                   cancel -> Model;
                   _Entry -> recovery(Model)
               end,
    Recovery#{pending := {sync, class_reset}, rung := reset_1};
action(Reset = {reset_pipe, Pipe}, Model = #{pending := {bulk, Transfer}}) ->
    %% A pipe reset while a transfer is posted is the ladder's cancel, on that transfer's
    %% pipe.
    check(Pipe =:= pipe_of(Transfer), {cancel_on_another_pipe, Pipe, Transfer}),
    (recovery(Model))#{pending := {sync, Reset}, posted := element(2, Transfer), rung := cancel};
action(Reset = {reset_pipe, _Pipe}, Model = #{rung := Rung}) ->
    Next = case Rung of
               reset_1 -> reset_2;
               reset_2 -> reset_3;
               _Clear -> none
           end,
    Model#{pending := {sync, Reset}, rung := Next};
action(get_max_lun, Model) ->
    Model#{pending := {sync, get_max_lun}, rung := none};
action({stop, Reason}, Model = #{marked := Marked}) ->
    case Reason of
        {reset_port, again, _Why} -> check(Marked, port_reset_again_without_recovery);
        _Other -> ok
    end,
    Model#{stopped := true};
action({medium_ended, Lun, Ref}, Model = #{current := Current, dead := Dead}) ->
    check(maps:get(Lun, Current) =:= Ref, {ended_not_current, Lun}),
    Model#{current := Current#{Lun := none}, dead := lists:usort([Ref | Dead])};
action({answer, Index, Reply}, Model = #{answered := Answered, cursor := Cursor, script := Script, mode := Mode,
                                         op := Op, attempts := Attempts}) ->
    check(not lists:member(Index, Answered) andalso Index < Cursor, {answer_twice_or_unasked, Index}),
    Done = case Index =:= Op of
               true -> retried_out(Reply, Attempts), Model#{op := none, attempts := 0, marked := false};
               false -> Model
           end,
    {Medium, Request} = lists:nth(Index, Script),
    Next = case {Mode, Index} of
               {full, 1} -> success;
               {ladder, 1} -> success;
               _Same -> Mode
           end,
    answered(Medium, Request, Reply, Done#{answered := ordsets:add_element(Index, Answered), mode := Next}).

%% The pipe a bulk transfer is posted on.
pipe_of({Out, _Tag, _Command}) when Out =:= command; Out =:= data_out -> out;
pipe_of(_DataInOrStatus) -> in.

%% A request's command as the engine sends it, written out here.
command_of({flush, Lun}) -> {synchronize_cache, Lun};
command_of({ready, Lun, _Ref}) -> {synchronize_cache, Lun};
command_of(Request) -> Request.

is_bulk({bulk, _Transfer}) -> true;
is_bulk(_Pending) -> false.

%% An operation's command sent: the first time, the operation is the earliest request not
%% yet answered, the queue being in order; again, a retry, at most four.
attempt(Model = #{op := none, cursor := Cursor, answered := Answered}) ->
    Op = lists:min([I || I <- lists:seq(1, Cursor - 1), not lists:member(I, Answered)]),
    Model#{op := Op, attempts := 1};
attempt(Model = #{attempts := Attempts}) ->
    check(Attempts < 5, {retries_past_their_bound, Attempts}),
    Model#{attempts := Attempts + 1}.

%% The entry into recovery of the operation on the wire, if any: once only.
recovery(Model = #{op := none}) ->
    Model;
recovery(Model = #{marked := Marked}) ->
    check(not Marked, second_recovery_not_to_port),
    Model#{marked := true}.

%% An operation answered `reset` or with a sense the engine retries has had all its
%% attempts: one and usb_bot_retries more.
retried_out(Reply, Attempts) ->
    Retried = case Reply of
                  {error, {device, reset}} -> true;
                  {error, {device, {sense, Key, _Asc, _Ascq}}} -> lists:member(Key, [?MEDIUM_ERROR, 4, 16#b]);
                  _Other -> false
              end,
    check(not Retried orelse Attempts =:= 5, {answered_before_retries_spent, Reply, Attempts}).

answered(_None, {ready, Lun, Ref}, {ok, #{flush := Flush}}, Model = #{current := Current, flushless := Flushless,
                                                                     last_key := Keys}) ->
    check(maps:get(Lun, Current) =:= none, {ready_over_a_medium, Lun}),
    check(Flush =:= (maps:get(Lun, Keys) =/= ?ILLEGAL_REQUEST), {flush_misjudged, Lun, Flush}),
    Model#{current := Current#{Lun := Ref}, flushless := lists:usort([Ref || not Flush] ++ Flushless)};
answered(Ref, {flush, _Lun}, Reply, Model = #{flushless := Flushless}) ->
    case lists:member(Ref, Flushless) of
        true -> check(lists:member(Reply, [{error, no_flush}, {error, {device, gone}}]), {flush_answered, Reply});
        false -> ok
    end,
    Model;
answered(_Medium, _Request, _Reply, Model) ->
    Model.

%% With nothing left to happen, every request of the script has its answer.
finished(#{stopped := true}) ->
    ok;
finished(#{answered := Answered, script := Script}) ->
    check_unanswered(length(Script) - length(Answered)).

check_unanswered(0) -> ok;
check_unanswered(N) -> {error, {unanswered, N}}.

length_of(Command) -> element(2, data_phase(Command)).

%% Each command's data length, written out here.
data_phase({request_sense, _Lun}) -> {in, 18};
data_phase({inquiry, _Lun}) -> {in, 36};
data_phase({read, _Lun, _Sector, Count}) -> {in, 512 * Count};
data_phase({write, _Lun, _Sector, Data}) -> {out, byte_size(Data)};
data_phase({_NoData, _Lun}) -> {none, 0}.

metadata({request_sense, _Lun}) -> true;
metadata({inquiry, _Lun}) -> true;
metadata(_Command) -> false.

check(true, _Why) -> ok;
check(false, Why) -> throw({violation, Why}).

%% ---------------------------------------------------------------------------------------
%% BOT 1.0's thirteen cases (section 6.7), each as what the device does and what the
%% engine answers: Hn by TEST UNIT READY, Hi by INQUIRY, Ho by a WRITE of two sectors. A
%% case that calls for reset recovery is followed by the command sent again, which the
%% device then completes, so the answer is the second attempt's.

the_thirteen_cases_test() ->
    Inquiry = {inquiry, 0},
    Tur = {test_unit_ready, 0},
    Write = {write, 0, 0, binary:copy(<<16#a5>>, 1024)},
    Reset = [ok, ok, ok],
    Text = {ok, #{type => 0, qualifier => 0, removable => true, vendor => <<"erXos   ">>,
                  product => <<"test stick      ">>}},
    TurAgain = Reset ++ [ok, {csw, 0, 0}],
    InquiryAgain = Reset ++ [ok, {data, inquiry_bytes(36)}, {csw, 0, 0}],
    WriteAgain = Reset ++ [ok, {moved, 1024}, {csw, 0, 0}],
    {Ready, Ref} = ready(started(), 0, true),
    Cases =
        [{1, Tur, [ok, {csw, 0, 0}], ok, false},
         {2, Tur, [ok, {csw, 0, 2} | TurAgain], ok, true},
         {3, Tur, [ok, stall, ok, {csw, 0, 2} | TurAgain], ok, true},
         {4, Inquiry, [ok, stall, ok, {csw, 36, 0}], {error, {device, short}}, false},
         {5, Inquiry, [ok, {data, inquiry_bytes(5)}, stall, ok, {csw, 31, 0}],
          {ok, #{type => 0, qualifier => 0, removable => true}}, false},
         {6, Inquiry, [ok, {data, inquiry_bytes(36)}, {csw, 0, 0}], Text, false},
         {7, Inquiry, [ok, {data, inquiry_bytes(36)}, stall, ok, {csw, 0, 2} | InquiryAgain], Text, true},
         {8, Inquiry, [ok, stall, ok, {csw, 36, 2} | InquiryAgain], Text, true},
         {9, Write, [ok, stall, ok, {csw, 1024, 0}], {error, {device, short}}, false},
         {10, Write, [ok, stall, ok, {csw, 1024, 2} | WriteAgain], ok, true},
         {11, Write, [ok, {moved, 1024}, {csw, 512, 0}], {error, {device, short}}, false},
         {12, Write, [ok, {moved, 1024}, {csw, 0, 0}], ok, false},
         {13, Write, [ok, {moved, 1024}, {csw, 0, 2} | WriteAgain], ok, true}],
    [begin
         {_State, Actions, Left} = run(Ready, [{request, Case, Ref, Request}], Script),
         ?assertEqual({Case, [Reply]}, {Case, replies(Actions)}),
         ?assertEqual({Case, ResetRan}, {Case, lists:member(class_reset, Actions)}),
         ?assertEqual({Case, if ResetRan -> 2; true -> 1 end}, {Case, length([C || {command, _, C} <- Actions])}),
         ?assertEqual({Case, []}, {Case, Left})
     end || {Case, Request, Script, Reply, ResetRan} <- Cases],
    %% A data phase that stalls is cleared on its own pipe.
    {_, Cleared, _} = run(Ready, [{request, w, Ref, Write}], [ok, stall, ok, {csw, 1024, 0}]),
    ?assert(lists:member({reset_pipe, out}, Cleared)).

%% ---------------------------------------------------------------------------------------
%% Traces.

a_failed_command_is_explained_by_its_sense_before_anything_else_runs_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    Write = {write, 0, 7, <<1, 2>>},
    {S1, [{command, Tag, Write}]} = step({request, w1, Ref, Write}, Ready),
    %% Queued behind it: another write for the same medium and a request of the other unit.
    {S2, []} = step({request, w2, Ref, {write, 0, 8, <<3, 4>>}}, S1),
    {S3, []} = step({request, other, none, {test_unit_ready, 1}}, S2),
    {S4, [{data_out, Tag, Write}]} = step({transfer, Tag, {ok, 31}}, S3),
    {S5, [{status, Tag}]} = step({transfer, Tag, {ok, 2}}, S4),
    {S6, [{command, Sense, {request_sense, 0}}]} = step({transfer, Tag, {ok, csw(Tag, 0, 1)}}, S5),
    {S7, [{data_in, Sense, 18}]} = step({transfer, Sense, {ok, 31}}, S6),
    {S8, [{status, Sense}]} = step({transfer, Sense, {ok, sense_bytes(16#70, ?UNIT_ATTENTION, 16#28, 0)}}, S7),
    {_S9, Actions} = step({transfer, Sense, {ok, csw(Sense, 0, 0)}}, S8),
    ?assertMatch([{answer, w1, {error, {device, {sense, ?UNIT_ATTENTION, 16#28, 0}}}},
                  {answer, w2, {error, {device, gone}}},
                  {medium_ended, 0, Ref},
                  {command, _, {test_unit_ready, 1}}], Actions).

a_sense_that_fails_ends_the_medium_and_is_not_asked_again_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    Write = {write, 0, 0, <<1>>},
    Failing = [ok, {moved, 1}, {csw, 0, 1}, ok],
    Ends = fun(Script) ->
                   {_, Actions, []} = run(Ready, [{request, w, Ref, Write}], Failing ++ Script),
                   ?assertEqual([{error, {device, no_sense}}], replies(Actions)),
                   ?assert(lists:member({medium_ended, 0, Ref}, Actions)),
                   ?assertEqual(1, length([C || {command, _, C = {request_sense, _}} <- Actions]))
           end,
    Ends([{data, sense_bytes(16#70, ?MEDIUM_ERROR)}, {csw, 0, 1}]),
    Ends([{data, binary:part(sense_bytes(16#70, ?MEDIUM_ERROR), 0, 13)}, {csw, 5, 0}]),
    Ends([{data, sense_bytes(16#72, ?MEDIUM_ERROR)}, {csw, 0, 0}]),
    Ends([{data, sense_bytes(16#70, ?MEDIUM_ERROR)}, {raw, <<0:13/unit:8>>}, ok, ok, ok]),
    Ends([stall, ok, {csw, 18, 0}]),
    %% A sense that is read and names neither NOT READY nor UNIT ATTENTION keeps the medium.
    {_, Kept, []} = run(Ready, [{request, w, Ref, Write}],
                        Failing ++ [{data, sense_bytes(16#70, ?DATA_PROTECT, 16#27, 0)}, {csw, 0, 0}]),
    ?assertEqual([{error, {device, {sense, ?DATA_PROTECT, 16#27, 0}}}], replies(Kept)),
    ?assertNot(lists:keymember(medium_ended, 1, Kept)).

%% MEDIUM ERROR, HARDWARE ERROR and ABORTED COMMAND send the command again, at most four
%% times; the fifth such sense is the answer, and a success on the way is.
a_retried_sense_sends_the_command_again_four_times_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    Write = {write, 0, 0, <<1>>},
    Failing = fun(Key) -> [ok, {moved, 1}, {csw, 0, 1}, ok, {data, sense_bytes(16#70, Key, 16#11, 0)}, {csw, 0, 0}] end,
    [begin
         {_, Actions, []} = run(Ready, [{request, w, Ref, Write}], lists:append(lists:duplicate(5, Failing(Key)))),
         ?assertEqual([{error, {device, {sense, Key, 16#11, 0}}}], replies(Actions)),
         ?assertEqual(5, length([C || {command, _, C = {write, _, _, _}} <- Actions]))
     end || Key <- [?MEDIUM_ERROR, 4, 16#b]],
    {_, Third, []} = run(Ready, [{request, w, Ref, Write}],
                         Failing(?MEDIUM_ERROR) ++ Failing(?MEDIUM_ERROR) ++ [ok, {moved, 1}, {csw, 0, 0}]),
    ?assertEqual([ok], replies(Third)),
    ?assertEqual(3, length([C || {command, _, C = {write, _, _, _}} <- Third])).

%% An operation that needs recovery a second time goes to the port, naming `again`; a
%% wire failure once retries are spent is answered `reset`.
a_second_recovery_goes_to_the_port_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    Tur = {test_unit_ready, 0},
    {Stopped, Actions, []} = run(Ready, [{request, t, Ref, Tur}], [ok, {csw, 0, 2}, ok, ok, ok, ok, {csw, 0, 2}]),
    ?assertEqual([], replies(Actions)),
    %% A stopped engine has nothing left to do, though its operation was never answered.
    ?assertEqual(infinity, erx_usb_bot_core:deadline(Stopped)),
    ?assertEqual(1, length([C || C = class_reset <- Actions])),
    ?assertEqual({stop, {reset_port, again, {csw, phase_error}}}, lists:last(Actions)),
    Medium = [ok, {csw, 0, 1}, ok, {data, sense_bytes(16#70, ?MEDIUM_ERROR, 16#11, 0)}, {csw, 0, 0}],
    {_, Spent, []} = run(Ready, [{request, t, Ref, Tur}],
                         lists:append(lists:duplicate(4, Medium)) ++ [ok, {csw, 0, 2}, ok, ok, ok]),
    ?assertEqual([{error, {device, reset}}], replies(Spent)).

a_medium_is_ready_only_once_its_synchronize_cache_answers_test() ->
    {Flushing, Ref} = ready(started(), 0, true),
    {_, Flushed, []} = run(Flushing, [{request, f, Ref, {flush, 0}}], [ok, {csw, 0, 0}]),
    ?assertEqual([ok], replies(Flushed)),
    %% ILLEGAL REQUEST makes a medium that cannot flush; its flush is refused unsent.
    {NoFlush, Ref2} = ready(started(), 0, false),
    ?assertMatch({_, [{answer, f, {error, no_flush}}]}, step({request, f, Ref2, {flush, 0}}, NoFlush)),
    %% Any other sense leaves the unit without a medium.
    Other = make_ref(),
    {NotReady, Actions, []} = run(started(), [{request, r, none, {ready, 0, Other}}],
                                  [ok, {csw, 0, 1}, ok, {data, sense_bytes(16#70, ?NOT_READY, 16#3a, 0)},
                                   {csw, 0, 0}]),
    ?assertEqual([{error, {device, {sense, ?NOT_READY, 16#3a, 0}}}], replies(Actions)),
    ?assertMatch({_, [{answer, w, {error, {device, gone}}}]},
                 step({request, w, Other, {write, 0, 0, <<1>>}}, NotReady)).

a_request_of_an_ended_medium_is_answered_gone_unsent_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    ?assertMatch({_, [{medium_ended, 0, Ref}]}, step({end_medium, 0, Ref}, Ready)),
    {Ended, _} = step({end_medium, 0, Ref}, Ready),
    ?assertMatch({_, []}, step({end_medium, 0, Ref}, Ended)),
    ?assertMatch({_, [{answer, r, {error, {device, gone}}}]}, step({request, r, Ref, {read, 0, 0, 1}}, Ended)),
    %% A request for no medium is refused once the unit has one.
    ?assertMatch({_, [{answer, t, {error, {device, gone}}}]}, step({request, t, none, {test_unit_ready, 0}}, Ready)).

%% A medium ended while its read is on the wire: the read runs on, its NOT READY sense ends
%% no medium, and the next medium's readiness, queued behind it, is sent only once the read
%% is answered and becomes current.
a_medium_ended_mid_operation_ends_only_its_own_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    {Reading, Sent, []} = run(Ready, [{request, r, Ref, {read, 0, 0, 1}}], [ok]),
    DataIn = lists:keyfind(data_in, 1, Sent),
    {Ended, [{medium_ended, 0, Ref}]} = step({end_medium, 0, Ref}, Reading),
    Next = make_ref(),
    {Queued, []} = step({request, ready, none, {ready, 0, Next}}, Ended),
    {Done, Actions, []} = answer(Queued, [DataIn], [], [stall, ok, {csw, 512, 1}, ok,
                                                       {data, sense_bytes(16#70, ?NOT_READY, 16#3a, 0)},
                                                       {csw, 0, 0}, ok, {csw, 0, 0}]),
    ?assertEqual([{error, {device, {sense, ?NOT_READY, 16#3a, 0}}}, {ok, #{flush => true}}], replies(Actions)),
    ?assertNot(lists:keymember(medium_ended, 1, Actions)),
    ?assertMatch({_, [{medium_ended, 0, Next}]}, step({end_medium, 0, Next}, Done)).

a_read_succeeds_only_whole_test() ->
    Read = {read, 1, 9, 2},
    Data = binary:copy(<<7>>, 1024),
    {Ready1, Ref1} = ready(started(), 1, true),
    %% A write is ok only with every byte moved, whatever the residue says.
    Write = {write, 1, 9, Data},
    {_, Short, []} = run(Ready1, [{request, w, Ref1, Write}], [ok, {moved, 1023}, {csw, 0, 0}]),
    ?assertEqual([{error, {device, short}}], replies(Short)),
    %% Media requests need their medium: none names no medium, and a readiness needs a
    %% unit without one.
    ?assertMatch({_, [{answer, n, {error, {device, gone}}}]}, step({request, n, none, Read}, started())),
    ?assertMatch({_, [{answer, n, {error, {device, gone}}}]}, step({request, n, Ref1, {ready, 1, make_ref()}}, Ready1)),
    Answer = fun(Script) ->
                     {_, Actions, []} = run(Ready1, [{request, r, Ref1, Read}], [ok | Script]),
                     replies(Actions)
             end,
    ?assertEqual([{ok, Data}], Answer([{data, Data}, {csw, 0, 0}])),
    ?assertEqual([{error, {device, short}}], Answer([{data, Data}, {csw, 512, 0}])),
    ?assertEqual([{error, {device, short}}], Answer([{data, binary:part(Data, 0, 512)}, {csw, 0, 0}])),
    ?assertEqual([{ok, Data}], Answer([{data, Data}, {csw, 1025, 0}, ok, ok, ok, ok, {data, Data}, {csw, 0, 0}])),
    ?assertEqual({in, 1024}, erx_usb_bot_core:data_phase(Read)).

the_deadlines_are_the_cores_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    %% An attempt whose transfer is still posted 8 s after its CBW climbs the ladder from
    %% the cancel of that transfer; a request queued behind it 10 s is answered unsent.
    {Busy, [{command, Tag, _}]} = step({request, a, Ref, {test_unit_ready, 0}}, Ready),
    {Queued, []} = erx_usb_bot_core:step({request, b, Ref, {test_unit_ready, 0}}, 1000, Busy),
    ?assertEqual(8000, erx_usb_bot_core:deadline(Queued)),
    ?assertMatch({_, []}, erx_usb_bot_core:step(tick, 7999, Queued)),
    {Cancelling, [{reset_pipe, out}]} = erx_usb_bot_core:step(tick, 8000, Queued),
    ?assertEqual(11000, erx_usb_bot_core:deadline(Cancelling)),
    {Swept, [{answer, b, {error, {device, deadline}}}]} = erx_usb_bot_core:step(tick, 11000, Cancelling),
    ?assertEqual(13000, erx_usb_bot_core:deadline(Swept)),
    %% The cancelled transfer's completion is ignored; the class reset follows the cancel.
    ?assertEqual({Swept, []}, erx_usb_bot_core:step({transfer, Tag, {error, stopped}}, 11500, Swept)),
    {Resetting, [class_reset]} = erx_usb_bot_core:step({reset_pipe, ok}, 12000, Swept),
    ?assertEqual(17000, erx_usb_bot_core:deadline(Resetting)),
    {R2, [{reset_pipe, in}]} = erx_usb_bot_core:step({control, {ok, <<>>}}, 12000, Resetting),
    {R3, [{reset_pipe, out}]} = erx_usb_bot_core:step({reset_pipe, ok}, 12000, R2),
    {Again, [{command, Retry, {test_unit_ready, 0}}]} = erx_usb_bot_core:step({reset_pipe, ok}, 12000, R3),
    ?assertNotEqual(Tag, Retry),
    %% Issued 18 s ago, it is answered in whatever phase and its medium ends; its posted
    %% transfer is cancelled before the reset recovery that readies the device.
    ?assertEqual(18000, erx_usb_bot_core:deadline(Again)),
    {Abandoned, Actions} = erx_usb_bot_core:step(tick, 18000, Again),
    ?assertEqual([{answer, a, {error, {device, deadline}}}, {medium_ended, 0, Ref}, {reset_pipe, out}], Actions),
    ?assertEqual(23000, erx_usb_bot_core:deadline(Abandoned)),
    {Idle, _, []} = run(Abandoned, [{reset_pipe, ok}], [ok, ok, ok]),
    ?assertEqual(infinity, erx_usb_bot_core:deadline(Idle)),
    ?assertMatch({_, [{command, _, {test_unit_ready, 0}}]}, step({request, c, none, {test_unit_ready, 0}}, Idle)),
    %% A step of recovery past its 5 s fails as `timeout`; a rung's failure goes to the port.
    ?assertMatch({_, [{stop, {reset_port, reset_1, timeout}}]}, erx_usb_bot_core:step(tick, 17000, Resetting)),
    ?assertMatch({_, [{stop, {reset_port, cancel, timeout}}]}, erx_usb_bot_core:step(tick, 13000, Swept)),
    %% A rung under way when the operation's deadline passes runs on, and the device is
    %% readied before the next command.
    {Slow, Slower} = ready(started(), 0, true),
    {S1, [{command, T, _}]} = step({request, s, Slower, {test_unit_ready, 0}}, Slow),
    {S2, [{status, T}]} = step({transfer, T, {ok, 31}}, S1),
    {S3, [class_reset]} = erx_usb_bot_core:step({transfer, T, {ok, csw(T, 0, 2)}}, 7900, S2),
    {S4, [{reset_pipe, in}]} = erx_usb_bot_core:step({control, {ok, <<>>}}, 12800, S3),
    {S5, [{reset_pipe, out}]} = erx_usb_bot_core:step({reset_pipe, ok}, 17700, S4),
    {S6, Late} = erx_usb_bot_core:step(tick, 18000, S5),
    ?assertEqual([{answer, s, {error, {device, deadline}}}, {medium_ended, 0, Slower}], Late),
    {S7, []} = erx_usb_bot_core:step({reset_pipe, ok}, 18500, S6),
    %% One whose reset recovery ends past its deadline is answered so, by the deadline its
    %% last step's answer finds decided, and the device that recovery readied takes the
    %% next command without another.
    ?assertMatch({S7, [{answer, s, {error, {device, deadline}}}, {medium_ended, 0, Slower}]},
                 erx_usb_bot_core:step({reset_pipe, ok}, 18500, S5)),
    ?assertMatch({_, [{command, _, {test_unit_ready, 0}}]}, step({request, n, none, {test_unit_ready, 0}}, S7)),
    %% A command that fails late leaves its sense a whole attempt of its own.
    {Busy3, [{command, Tag3, _}]} = step({request, f, none, {test_unit_ready, 1}}, started()),
    {Status3, [{status, Tag3}]} = step({transfer, Tag3, {ok, 31}}, Busy3),
    {Sensing, [{command, _, {request_sense, 1}}]} = erx_usb_bot_core:step({transfer, Tag3, {ok, csw(Tag3, 0, 1)}},
                                                                          7900, Status3),
    ?assertEqual(15900, erx_usb_bot_core:deadline(Sensing)),
    %% A request that reaches the head of the queue past its deadline is not sent either.
    {Busy2, [{command, Tag2, _}]} = step({request, d, none, {test_unit_ready, 1}}, started()),
    {Waiting, []} = step({request, e, none, {test_unit_ready, 1}}, Busy2),
    %% It is answered at the first event that finds it past, before that event's own answer.
    {Sent, [{status, Tag2}]} = erx_usb_bot_core:step({transfer, Tag2, {ok, 31}}, 5000, Waiting),
    {Sensing2, [{command, Tag4, {request_sense, 1}}]} =
        erx_usb_bot_core:step({transfer, Tag2, {ok, csw(Tag2, 0, 1)}}, 7000, Sent),
    {Reading, [{data_in, Tag4, _}]} = erx_usb_bot_core:step({transfer, Tag4, {ok, 31}}, 8000, Sensing2),
    {Read, [{status, Tag4}]} =
        erx_usb_bot_core:step({transfer, Tag4, {ok, sense_bytes(16#70, ?NOT_READY, 16#3a, 0)}}, 9000, Reading),
    {_, Finished} = erx_usb_bot_core:step({transfer, Tag4, {ok, csw(Tag4, 0, 0)}}, 12000, Read),
    ?assertEqual([{answer, e, {error, {device, deadline}}}, {answer, d, {error, {device, {sense, ?NOT_READY, 16#3a, 0}}}}],
                 Finished).

%% The function ends a medium while its write's sense is on the wire: the MEDIUM ERROR that
%% would send the write again finds its medium gone, so no WRITE follows the end, and the
%% write is answered gone.
a_write_is_not_sent_again_once_its_medium_has_ended_test() ->
    {Ready, Ref} = ready(started(), 0, true),
    {Sensing, Sent, []} = run(Ready, [{request, w, Ref, {write, 0, 0, <<1>>}}], [ok, {moved, 1}, {csw, 0, 1}]),
    Sense = {command, _, {request_sense, 0}} = lists:last(Sent),
    {Ended, [{medium_ended, 0, Ref}]} = step({end_medium, 0, Ref}, Sensing),
    {_, Actions, []} = answer(Ended, [Sense], [],
                              [ok, {data, sense_bytes(16#70, ?MEDIUM_ERROR, 16#11, 0)}, {csw, 0, 0}]),
    ?assertEqual([], [C || {command, _, C = {write, _, _, _}} <- Actions]),
    ?assertEqual([{error, {device, gone}}], replies(Actions)).

%% Every event decides the deadlines first, as a tick at its time would: an answer that
%% comes past its step's deadline, or its attempt's, advances nothing.
an_answer_past_its_deadline_finds_the_deadline_decided_test() ->
    {Resetting, [class_reset]} = erx_usb_bot_core:step(start, 0, erx_usb_bot_core:new()),
    ?assertMatch({_, [{stop, {reset_port, reset_1, timeout}}]},
                 erx_usb_bot_core:step({control, {ok, <<>>}}, 6000, Resetting)),
    {Ready, Ref} = ready(started(), 0, true),
    {Busy, [{command, Tag, _}]} = step({request, w, Ref, {write, 0, 0, <<1>>}}, Ready),
    ?assertMatch({_, [{reset_pipe, out}]}, erx_usb_bot_core:step({transfer, Tag, {ok, 31}}, 8001, Busy)),
    ?assertMatch({_, [{answer, w, {error, {device, deadline}}}, {medium_ended, 0, Ref}, {reset_pipe, out}]},
                 erx_usb_bot_core:step({transfer, Tag, {ok, 31}}, 18001, Busy)),
    %% A stop is the last action: a request queued behind a rung that times out is answered
    %% before it.
    {Queued, []} = step({request, i, none, {inquiry, 0}}, Resetting),
    ?assertMatch({_, [{answer, i, {error, {device, deadline}}}, {stop, {reset_port, reset_1, timeout}}]},
                 erx_usb_bot_core:step(tick, 10000, Queued)).

the_start_runs_reset_recovery_before_get_max_lun_test() ->
    {S1, [class_reset]} = step(start, erx_usb_bot_core:new()),
    ?assertEqual(5000, erx_usb_bot_core:deadline(S1)),
    %% A request waits for the units.
    {S2, []} = step({request, early, none, {inquiry, 0}}, S1),
    {S3, [{reset_pipe, in}]} = step({control, {ok, <<>>}}, S2),
    {S4, [{reset_pipe, out}]} = step({reset_pipe, ok}, S3),
    {S5, [get_max_lun]} = step({reset_pipe, ok}, S4),
    ?assertMatch({_, [{units, 1}, {command, _, {inquiry, 0}}]}, step({control, {error, stall}}, S5)),
    {Asking, [{units, 1}, {command, _, {inquiry, 0}}]} = erx_usb_bot_core:step(tick, 5000, S5),
    %% Its answer, come after all, finds a phase waiting on no step and changes nothing.
    ?assertEqual({Asking, []}, erx_usb_bot_core:step({control, {error, gone}}, 5100, Asking)),
    ?assertEqual({Asking, []}, erx_usb_bot_core:step({reset_pipe, ok}, 5100, Asking)),
    ?assertMatch({_, [{stop, {max_lun, 16}}]}, step({control, {ok, <<16>>}}, S5)),
    %% Each rung that fails, or passes its 5 s, ends the function naming it.
    ?assertMatch({_, [{stop, {reset_port, reset_1, stall}}]}, step({control, {error, stall}}, S1)),
    ?assertMatch({_, [{stop, {reset_port, reset_1, timeout}}]}, erx_usb_bot_core:step(tick, 5000, S1)),
    ?assertMatch({_, [{stop, {reset_port, reset_2, gone}}]}, step({reset_pipe, {error, gone}}, S3)),
    ?assertMatch({_, [{stop, {reset_port, reset_3, gone}}]}, step({reset_pipe, {error, gone}}, S4)).

%% ---------------------------------------------------------------------------------------
%% Quirks: each kind against a device that has it, and against one that does not.

a_single_unit_device_is_asked_no_max_lun_test() ->
    {_, Actions, []} = run(erx_usb_bot_core:new([single_unit]), [start, {request, t, none, {test_unit_ready, 0}}],
                           [ok, ok, ok, ok, {csw, 0, 0}]),
    ?assertNot(lists:member(get_max_lun, Actions)),
    ?assert(lists:member({units, 1}, Actions)),
    ?assertEqual([ok], replies(Actions)).

a_no_inquiry_device_has_its_inquiry_answered_unsent_test() ->
    Inquiry = {request, i, none, {inquiry, 0}},
    ?assertEqual({ok, #{type => 0, qualifier => 0, removable => true}}, reply(step(Inquiry, quirked([no_inquiry])))),
    ?assertMatch({_, [{command, _, {inquiry, 0}}]}, step(Inquiry, quirked([]))).

an_ignore_csw_tag_device_has_a_csw_of_another_tag_taken_test() ->
    Status = fun(Quirks) -> trace(Quirks, {test_unit_ready, 0}, [ok, {tagged, 16#dead, 0, 0}]) end,
    ?assertEqual([ok], replies(Status([ignore_csw_tag]))),
    ?assert(lists:member(class_reset, Status([]))).

a_wrong_csw_signature_device_has_only_freebsds_two_taken_test() ->
    Status = fun(Quirks, Signature) -> trace(Quirks, {test_unit_ready, 0}, [ok, {signed, Signature, 0, 0}]) end,
    ?assertEqual([ok], replies(Status([wrong_csw_signature], 16#43425355))),
    ?assertEqual([ok], replies(Status([wrong_csw_signature], 16#55425355))),
    ?assert(lists:member(class_reset, Status([wrong_csw_signature], 16#55534244))),
    ?assert(lists:member(class_reset, Status([], 16#43425355))).

a_capacity_is_count_device_has_its_last_block_read_as_a_count_test() ->
    Capacity = fun(Quirks, Last) ->
                       replies(trace(Quirks, {read_capacity_10, 0}, [ok, {data, <<Last:32, 512:32>>}, {csw, 0, 0}]))
               end,
    ?assertEqual([{error, {device, short}}], Capacity([capacity_is_count], 0)),
    ?assertEqual([{ok, #{last_block => 999, block_length => 512}}], Capacity([capacity_is_count], 1000)),
    %% All ones asks for READ CAPACITY(16), and is left as it is.
    ?assertEqual([{ok, #{last_block => 16#ffffffff, block_length => 512}}], Capacity([capacity_is_count], 16#ffffffff)),
    ?assertEqual([{ok, #{last_block => 1000, block_length => 512}}], Capacity([], 1000)).

%% ---------------------------------------------------------------------------------------
%% The decoders.

a_csw_is_valid_and_meaningful_as_bot_says_test() ->
    Csw = fun erx_usb_bot_core:csw/3,
    ?assertEqual({good, 0}, Csw(csw(5, 0, 0), 5, 36)),
    ?assertEqual({failed, 36}, Csw(csw(5, 36, 1), 5, 36)),
    ?assertEqual(not_meaningful, Csw(csw(5, 37, 0), 5, 36)),
    ?assertEqual(not_meaningful, Csw(csw(5, 37, 1), 5, 36)),
    ?assertEqual(not_meaningful, Csw(csw(5, 0, 3), 5, 36)),
    ?assertEqual(phase_error, Csw(csw(5, 16#ffffffff, 2), 5, 36)),
    ?assertEqual(invalid, Csw(csw(6, 0, 0), 5, 36)),
    ?assertEqual(invalid, Csw(<<16#55534243:32/little, 5:32/little, 0:32, 0>>, 5, 36)),
    ?assertEqual(invalid, Csw(<<(csw(5, 0, 0))/binary, 0>>, 5, 36)),
    ?assertEqual(invalid, Csw(binary:part(csw(5, 0, 0), 0, 12), 5, 36)).

get_max_lun_names_the_units_test() ->
    Max = fun erx_usb_bot_core:max_lun/1,
    ?assertEqual([{ok, 1}, {ok, 2}, {ok, 16}, {error, {max_lun, 16}}, {error, {max_lun, 255}}],
                 [Max({ok, <<N>>}) || N <- [0, 1, 15, 16, 255]]),
    ?assertEqual([{ok, 1}, {ok, 1}, {ok, 1}], [Max(A) || A <- [{error, stall}, {ok, <<>>}, {ok, <<1, 2>>}]]).

the_scsi_decoders_take_their_relevant_bytes_test() ->
    ?assertEqual({error, short}, erx_usb_bot_core:inquiry(inquiry_bytes(4))),
    ?assertEqual({ok, #{type => 0, qualifier => 0, removable => true}}, erx_usb_bot_core:inquiry(inquiry_bytes(31))),
    ?assertEqual({ok, #{type => 5, qualifier => 3, removable => false}},
                 erx_usb_bot_core:inquiry(<<16#65, 16#7f, 0, 0, 0>>)),
    ?assertEqual({error, short}, erx_usb_bot_core:sense(binary:part(sense_bytes(16#70, 6, 16#28, 1), 0, 13))),
    ?assertEqual({ok, {6, 16#28, 1}}, erx_usb_bot_core:sense(binary:part(sense_bytes(16#f0, 16#f6, 16#28, 1), 0, 14))),
    ?assertEqual({ok, {3, 1, 2}}, erx_usb_bot_core:sense(sense_bytes(16#71, 3, 1, 2))),
    ?assertEqual({error, unknown_format}, erx_usb_bot_core:sense(sense_bytes(16#72, 3, 1, 2))),
    ?assertEqual({ok, #{last_block => 16#ffffffff, block_length => 512}},
                 erx_usb_bot_core:read_capacity_10(<<16#ffffffff:32, 512:32>>)),
    ?assertEqual({error, short}, erx_usb_bot_core:read_capacity_10(<<1:32, 2:24>>)),
    ?assertEqual({ok, #{last_block => 16#100000000, block_length => 4096}},
                 erx_usb_bot_core:read_capacity_16(<<16#100000000:64, 4096:32>>)),
    ?assertEqual({error, short}, erx_usb_bot_core:read_capacity_16(<<1:64, 2:24>>)).

%% ---------------------------------------------------------------------------------------
%% Helpers.

step(Event, State) -> erx_usb_bot_core:step(Event, 0, State).

%% An engine started with Get Max LUN naming two units.
started() ->
    {State, _Actions, []} = run(erx_usb_bot_core:new(), [start], [ok, ok, ok, {max_lun, <<1>>}]),
    State.

%% An engine of a device with Quirks started with Get Max LUN naming one unit.
quirked(Quirks) ->
    {State, _Actions, []} = run(erx_usb_bot_core:new(Quirks), [start], [ok, ok, ok, {max_lun, <<0>>}]),
    State.

%% Every action of Command, a request for no medium, on a device with Quirks answered
%% from Script.
trace(Quirks, Command, Script) ->
    {_, Actions, []} = run(quirked(Quirks), [{request, r, none, Command}], Script),
    Actions.

%% The one reply of a step.
reply({_State, [{answer, _Id, Reply}]}) -> Reply.

%% Unit Lun given a medium, one that flushes or one whose readiness drew ILLEGAL REQUEST.
ready(State, Lun, Flush) ->
    Ref = make_ref(),
    Script = case Flush of
                 true -> [ok, {csw, 0, 0}];
                 false -> [ok, {csw, 0, 1}, ok, {data, sense_bytes(16#70, ?ILLEGAL_REQUEST, 16#20, 0)}, {csw, 0, 0}]
             end,
    {Ready, Actions, []} = run(State, [{request, ready, none, {ready, Lun, Ref}}], Script),
    [{ok, #{flush := Flush}}] = replies(Actions),
    {Ready, Ref}.

%% Steps Events, then answers each transfer the engine asks for from Script, in order, at
%% time 0; returns the state, every action, and what is left of Script.
run(State, Events, Script) ->
    {S, Actions} = lists:foldl(fun(Event, {S0, As}) ->
                                       {S1, New} = step(Event, S0),
                                       {S1, As ++ New}
                               end, {State, []}, Events),
    answer(S, Actions, Actions, Script).

answer(State, [], All, Script) ->
    {State, All, Script};
answer(State, [Action | Rest], All, Script) ->
    case {transfer(Action), Script} of
        {true, [Reply | Left]} ->
            {Next, New} = step(event(Action, Reply), State),
            answer(Next, Rest ++ New, All ++ New, Left);
        {_Output, _Script} ->
            answer(State, Rest, All, Script)
    end.

transfer(Action) ->
    lists:member(Action, [class_reset, get_max_lun])
        orelse lists:member(element(1, Action), [reset_pipe, command, data_in, data_out, status]).

event(class_reset, ok) -> {control, {ok, <<>>}};
event(get_max_lun, {max_lun, Bytes}) -> {control, {ok, Bytes}};
event({reset_pipe, _Pipe}, ok) -> {reset_pipe, ok};
event({command, Tag, _Command}, ok) -> {transfer, Tag, {ok, 31}};
event({data_in, Tag, _Length}, {data, Bytes}) -> {transfer, Tag, {ok, Bytes}};
event({data_out, Tag, _Command}, {moved, Moved}) -> {transfer, Tag, {ok, Moved}};
event({status, Tag}, {csw, Residue, Status}) -> {transfer, Tag, {ok, csw(Tag, Residue, Status)}};
event({status, Tag}, {raw, Bytes}) -> {transfer, Tag, {ok, Bytes}};
event({status, Tag}, {tagged, CswTag, Residue, Status}) ->
    {transfer, Tag, {ok, <<?CSW_SIGNATURE:32/little, CswTag:32/little, Residue:32/little, Status>>}};
event({status, Tag}, {signed, Signature, Residue, Status}) ->
    {transfer, Tag, {ok, <<Signature:32/little, Tag:32/little, Residue:32/little, Status>>}};
event({_Bulk, Tag, _}, stall) -> {transfer, Tag, {error, stall}};
event({status, Tag}, stall) -> {transfer, Tag, {error, stall}}.

replies(Actions) -> [Reply || {answer, _Id, Reply} <- Actions].

csw(Tag, Residue, Status) ->
    <<?CSW_SIGNATURE:32/little, Tag:32/little, Residue:32/little, Status>>.

sense_bytes(Code, Key) -> sense_bytes(Code, Key, 0, 0).

%% Fixed-format sense data of 18 bytes: response code, key in byte 2, ASC and ASCQ in
%% bytes 12 and 13, the additional length 10.
sense_bytes(Code, Key, Asc, Ascq) ->
    <<Code, 0, Key, 0:32, 10, 0:32, Asc, Ascq, 0, 0:24>>.

%% The first Length bytes of a removable direct-access unit's INQUIRY data.
inquiry_bytes(Length) ->
    binary:part(<<0, 16#80, 2, 2, 31, 0, 0, 0, "erXos   ", "test stick      ", "1.00">>, 0, Length).
