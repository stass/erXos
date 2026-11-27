%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_bot_core).
-moduledoc """
The Bulk-Only Transport engine of a mass-storage function, its pure core
(docs/design-usb.md, "The BOT engine", "Media and drives" and "The block
transport").

step/3 is the engine. Its events are the function's start, the requests
the function queues, the completions of the transfers it asked for, the
function's word that a medium has ended, and a clock tick; its actions are
transfers, answers and the end of a medium. Every step takes the time, in
milliseconds, so the deadlines are decided here and nowhere else.

The engine's unit of work is an operation: one request of the queue, its
command and, when that command fails, its REQUEST SENSE. It takes the next
request only once the current operation is done, so nothing runs between a
failed command and the sense that explains it, and one command is in
flight on the interface at a time, the units of a card reader sharing it in
turn. Its phases are the design's table:

* `command`: the CBW on bulk-out; then the data phase, or the status when
  the command moves no data; a failure: reset recovery;
* `data_in`, `data_out`: the data phase; then the status; a failure:
  `clear_data`, the data phase having moved nothing;
* `clear_data`: `reset_pipe` on the data pipe; then the status;
* `status`: the CSW on bulk-in, checked (csw/3); a failure: `clear_status`;
* `clear_status`: `reset_pipe` on bulk-in; then `status_again`;
* `status_again`: the CSW once more; a failure: reset recovery;
* `reset_1` to `reset_3`: the Bulk-Only Mass Storage Reset, then
  `reset_pipe` on bulk-in, then on bulk-out; then the operation done,
  failed, or at the function's start Get Max LUN (`max_lun`). A step of
  reset recovery that fails stops the function.

A failed `reset_pipe` outside reset recovery goes to reset recovery. A
data phase that fails in any way is cleared and followed by the status, as
FreeBSD's `umass_t_bbb_data_read_callback` treats every error but a
cancellation (sys/dev/usb/storage/umass.c:1458-1464); a failed CSW read is
cleared and read once more (umass.c:1631-1641). The pipe's failure answer
carries no count, so a failed data phase counts as moving nothing.

A CSW is valid when it is 13 bytes, its signature is 53425355h and its tag
the CBW's, and meaningful when its status is 0 or 1 with a residue no
larger than the CBW's length, or 2 (BOT 1.0, 6.3). An invalid CSW, one not
meaningful and a phase error go to reset recovery (6.5). Status 0 decides
what the command moved: a READ or WRITE succeeds only whole, with no
residue and every byte moved, and is `{error, {device, short}}` otherwise;
a command that reads metadata takes its relevant bytes, the length less
the residue, which the data phase must have moved, else the CSW is not
meaningful; its decoder reads only those bytes. Status 1 starts the
operation's REQUEST SENSE through the same states, under the operation's
deadline. A sense read (status 0, 14 bytes, fixed format) answers the
request `{error, {device, {sense, Key, Asc, Ascq}}}` and, for NOT READY and
UNIT ATTENTION, ends the unit's medium in that step. A sense that fails in
any way, reset recovery included, answers `{error, {device, no_sense}}`
and ends the unit's medium; the engine asks no sense for the sense. An
operation that went through reset recovery is otherwise answered
`{error, {device, reset}}`.

A unit's medium is the engine's: none, or the reference the function made
for it and whether it flushes. It becomes current only in the step that
checks its readiness SYNCHRONIZE CACHE (`{ready, Lun, Ref}`), which a
success or an ILLEGAL REQUEST sense answers, the latter as a medium that
cannot flush. Every request names the medium it is for, `none` when the
unit has none, and is answered `{error, {device, gone}}` without being sent
when that is not the unit's current medium as it reaches the head of the
queue; a read, write or flush needs a medium, and a readiness a unit with
none. A medium ends in the step that observes its end: the unit's medium
becomes none, every queued request for it is answered `gone`, and the
action `{medium_ended, Lun, Ref}` has the function stop its block service.
Every end names the medium it ends, and ends it only while it is the
unit's current one: an operation ends only the medium it was admitted for,
and a stale reference ends nothing. The function's own word,
`{end_medium, Lun, Ref}` for a transport that ended, ends the medium the
same way and leaves an operation already issued to run as any operation
does, to its CSW, through reset recovery or to its deadline, the device
being inside a command that completes in turn; its answer reaches a caller
that is gone, or the unit's course.
A flush of a medium that cannot flush is answered `{error, no_flush}`,
never `ok`.

A request still queued blk_wait_limit_ms (abi/formats/blk.txt) after its acceptance is
answered `{error, {device, deadline}}` and never sent. One issued
blk_in_flight_ms ago, its sense and reset recovery included, is
answered the same and ends its unit's medium, and reset recovery starts at
once: its class reset stops the transfer the device left hanging, whose
late completion names an older tag and is ignored. A tick checks the
operation's deadline while it waits on a bulk transfer, the only waits the
function's own calls do not bound; an operation that ends past its
deadline, through those calls, is answered and recovered the same way, so
the reset recovery comes before the next command. deadline/1 is the time
of the next tick that can change anything.

At start the engine runs reset recovery before Get Max LUN or any CBW, so
a device a predecessor left inside a command is ready for a new CBW (BOT
1.0, 6.2.1 and 5.3.4). Get Max LUN's answer (max_lun/1) names the units;
then queued requests run.

Everything a device sends is untrusted: csw/3, max_lun/1 and the
decoders take exactly the fields their formats have, answer instead of
raising, and create no atom. The function and its transports are trusted
Erlang code of the same domain: an event out of turn, or a request for a
unit Get Max LUN did not name, crashes the function, which its supervisor
restarts.
""".

-export([new/0, step/3, deadline/1, data_phase/1, csw/3, max_lun/1, inquiry/1, sense/1,
         read_capacity_10/1, read_capacity_16/1]).

-export_type([state/0, event/0, action/0, request/0, command/0, reply/0, lun/0, medium_ref/0]).

-include("generated/erx_abi.hrl").

-type lun() :: 0..?ERX_USB_BOT_LUN_MAX.

-doc "The reference the function makes for a medium as it becomes ready.".
-type medium_ref() :: reference().

-doc "What the function queues: a SCSI command of the subset, a medium's flush, or a medium's readiness.".
-type request() :: {inquiry | test_unit_ready | read_capacity_10 | read_capacity_16 | flush, lun()}
                 | {read, lun(), Sector :: non_neg_integer(), Count :: pos_integer()}
                 | {write, lun(), Sector :: non_neg_integer(), Data :: binary()}
                 | {ready, lun(), medium_ref()}.

-doc "What a CBW carries, as `erx_blk_write` builds it: a request's command, or the operation's REQUEST SENSE.".
-type command() :: {inquiry | test_unit_ready | read_capacity_10 | read_capacity_16 | synchronize_cache
                    | request_sense, lun()}
                 | {read, lun(), non_neg_integer(), pos_integer()}
                 | {write, lun(), non_neg_integer(), binary()}.

-type reply() :: ok | {ok, binary() | map()} | {error, no_flush}
               | {error, {device, {sense, byte(), byte(), byte()} | no_sense | reset | short | gone | deadline}}.

-type event() :: start
               | {request, Id :: term(), medium_ref() | none, request()}
               | {transfer, Tag :: non_neg_integer(), {ok, binary() | non_neg_integer()} | {error, term()}}
               | {reset_pipe, ok | {error, term()}}
               | {control, {ok, binary()} | {error, term()}}
               | {end_medium, lun(), medium_ref()}
               | tick.

-doc """
Post the CBW of Command with Tag on bulk-out; post Length bytes of bulk-in, or the data phase of
a write, under the same Tag; post the 13-byte CSW read under Tag; reset a bulk pipe; send the
class reset or Get Max LUN; answer a request; stop a medium's block service; start the units;
end the function.
""".
-type action() :: {command, Tag :: non_neg_integer(), command()}
                | {data_in, Tag :: non_neg_integer(), Length :: pos_integer()}
                | {data_out, Tag :: non_neg_integer(), command()}
                | {status, Tag :: non_neg_integer()}
                | {reset_pipe, in | out}
                | class_reset
                | get_max_lun
                | {answer, Id :: term(), reply()}
                | {medium_ended, lun(), medium_ref()}
                | {units, 1..16}
                | {stop, {reset, term()} | {max_lun, byte()}}.

-type phase() :: new | idle | command | data_in | data_out | clear_data | status | clear_status | status_again
               | reset_1 | reset_2 | reset_3 | max_lun | stopped.

-type medium() :: none | #{ref := medium_ref(), flush := boolean()}.

-type entry() :: #{id := term(), medium := medium_ref() | none, request := request(), accepted := integer()}.

%% The current operation: its request, whether its own command or its REQUEST SENSE is on
%% the wire, the command's CBW tag and data length, and what its data phase moved.
-type op() :: #{entry := entry(), stage := command | sense, issued := integer(), command := command(),
                tag := non_neg_integer(), length := non_neg_integer(), moved := non_neg_integer(),
                data := binary()}.

-opaque state() :: #{phase := phase(), tag := non_neg_integer(), op := op() | none,
                     queue := queue:queue(entry()), units := none | #{lun() => medium()}}.

%% The phases that wait on a bulk transfer, the only ones a completion or an operation's
%% deadline can find.
-define(ON_BULK(Phase), (Phase =:= command orelse Phase =:= data_in orelse Phase =:= data_out
                         orelse Phase =:= status orelse Phase =:= status_again)).

-doc "An engine that has not started.".
-spec new() -> state().
new() ->
    #{phase => new, tag => 0, op => none, queue => queue:new(), units => none}.

-doc "The next state on Event at time Now, in milliseconds, and the actions the function performs.".
-spec step(event(), integer(), state()) -> {state(), [action()]}.
step(start, _Now, State = #{phase := new}) ->
    recover(State);
step({request, Id, Medium, Request}, Now, State = #{queue := Queue}) ->
    Entry = #{id => Id, medium => Medium, request => Request, accepted => Now},
    next(Now, State#{queue := queue:in(Entry, Queue)});
step({transfer, Tag, Result}, Now, State = #{phase := Phase, op := #{tag := Tag}}) when ?ON_BULK(Phase) ->
    transferred(Phase, Result, Now, State);
step({transfer, _StaleTag, _Result}, _Now, State) ->
    {State, []};
step({reset_pipe, Result}, Now, State = #{phase := Phase}) ->
    pipe_reset(Phase, Result, Now, State);
step({control, Result}, Now, State = #{phase := Phase}) ->
    controlled(Phase, Result, Now, State);
step({end_medium, Lun, Ref}, _Now, State) ->
    end_medium(Lun, Ref, State);
step(tick, Now, State = #{phase := Phase, op := #{issued := Issued}})
  when ?ON_BULK(Phase), Now - Issued >= ?ERX_BLK_IN_FLIGHT_MS ->
    abandon(Now, State);
step(tick, Now, State) ->
    expire_queued(Now, State).

-doc "The time at which a tick next changes anything, or `infinity`.".
-spec deadline(state()) -> integer() | infinity.
deadline(#{queue := Queue, op := Op, phase := Phase}) ->
    Queued = case queue:peek(Queue) of
                 {value, #{accepted := Accepted}} -> [Accepted + ?ERX_BLK_WAIT_LIMIT_MS];
                 empty -> []
             end,
    Issued = case Op of
                 #{issued := At} when ?ON_BULK(Phase) -> [At + ?ERX_BLK_IN_FLIGHT_MS];
                 _InCallOrNone -> []
             end,
    %% A number sorts before an atom, so infinity is the minimum only of an empty list.
    lists:min([infinity | Queued ++ Issued]).

-doc "A command's data phase: its direction and its CBW's length.".
-spec data_phase(command()) -> {none, 0} | {in | out, non_neg_integer()}.
data_phase({test_unit_ready, _Lun}) -> {none, 0};
data_phase({synchronize_cache, _Lun}) -> {none, 0};
data_phase({inquiry, _Lun}) -> {in, ?ERX_SCSI_INQUIRY_LENGTH};
data_phase({request_sense, _Lun}) -> {in, ?ERX_SCSI_SENSE_LENGTH};
data_phase({read_capacity_10, _Lun}) -> {in, ?ERX_SCSI_READ_CAPACITY_10_LENGTH};
data_phase({read_capacity_16, _Lun}) -> {in, ?ERX_SCSI_READ_CAPACITY_16_LENGTH};
data_phase({read, _Lun, _Sector, Count}) -> {in, Count * ?ERX_SCSI_BLOCK_LENGTH};
data_phase({write, _Lun, _Sector, Data}) -> {out, byte_size(Data)}.

-doc """
A CSW judged against its CBW's Tag and Length (BOT 1.0, 6.3): `{good, Residue}` or
`{failed, Residue}` when valid and meaningful, `phase_error`, `not_meaningful`, or `invalid`.
""".
-spec csw(binary(), non_neg_integer(), non_neg_integer()) ->
          {good | failed, non_neg_integer()} | phase_error | not_meaningful | invalid.
csw(<<?ERX_USB_BOT_CSW_SIGNATURE:32/little, Tag:32/little, Residue:32/little, Status>>, Tag, Length) ->
    if
        Status =:= ?ERX_USB_BOT_STATUS_PHASE_ERROR -> phase_error;
        Residue > Length -> not_meaningful;
        Status =:= ?ERX_USB_BOT_STATUS_GOOD -> {good, Residue};
        Status =:= ?ERX_USB_BOT_STATUS_FAILED -> {failed, Residue};
        true -> not_meaningful
    end;
csw(_Bytes, _Tag, _Length) ->
    invalid.

-doc """
The units Get Max LUN's answer names: its one byte, the highest unit's number, at most
usb_bot_lun_max; a STALL or any other failure, a malformed answer included, means one unit.
""".
-spec max_lun({ok, binary()} | {error, term()}) -> {ok, 1..16} | {error, {max_lun, byte()}}.
max_lun({ok, <<Max>>}) when Max =< ?ERX_USB_BOT_LUN_MAX -> {ok, Max + 1};
max_lun({ok, <<Max>>}) -> {error, {max_lun, Max}};
max_lun(_StallOrFailure) -> {ok, 1}.

-doc "A unit's device type, qualifier and removable bit from INQUIRY's relevant bytes, and its text when 32 are there.".
-spec inquiry(binary()) -> {ok, #{type := 0..31, qualifier := 0..7, removable := boolean(),
                                  vendor => binary(), product => binary()}} | {error, short}.
inquiry(Bytes = <<Device, Flags, _/binary>>) when byte_size(Bytes) >= ?ERX_SCSI_INQUIRY_MIN ->
    Unit = #{type => Device band ?ERX_SCSI_PERIPHERAL_TYPE_MASK,
             qualifier => Device bsr ?ERX_SCSI_PERIPHERAL_QUALIFIER_SHIFT,
             removable => Flags band ?ERX_SCSI_REMOVABLE =/= 0},
    case Bytes of
        <<_Header:8/binary, Vendor:8/binary, Product:16/binary, _/binary>> ->
            {ok, Unit#{vendor => Vendor, product => Product}};
        _NoText ->
            {ok, Unit}
    end;
inquiry(_Bytes) ->
    {error, short}.

-doc "The sense key, additional sense code and qualifier of fixed-format sense data.".
-spec sense(binary()) -> {ok, {0..15, byte(), byte()}} | {error, short | unknown_format}.
sense(<<Code, _Segment, Flags, _Information:4/binary, _ExtraLength, _CommandInfo:4/binary, Asc, Ascq,
        _/binary>>) ->
    case Code band ?ERX_SCSI_SENSE_RESPONSE_MASK of
        Response when Response =:= ?ERX_SCSI_SENSE_RESPONSE_CURRENT;
                      Response =:= ?ERX_SCSI_SENSE_RESPONSE_DEFERRED ->
            {ok, {Flags band ?ERX_SCSI_SENSE_KEY_MASK, Asc, Ascq}};
        _Other ->
            {error, unknown_format}
    end;
sense(_Bytes) ->
    {error, short}.

-doc "READ CAPACITY(10)'s last block address and block length.".
-spec read_capacity_10(binary()) -> {ok, #{last_block := non_neg_integer(), block_length := non_neg_integer()}}
                                  | {error, short}.
read_capacity_10(<<Last:32, Length:32, _/binary>>) -> {ok, #{last_block => Last, block_length => Length}};
read_capacity_10(_Bytes) -> {error, short}.

-doc "READ CAPACITY(16)'s last block address and block length.".
-spec read_capacity_16(binary()) -> {ok, #{last_block := non_neg_integer(), block_length := non_neg_integer()}}
                                  | {error, short}.
read_capacity_16(<<Last:64, Length:32, _/binary>>) -> {ok, #{last_block => Last, block_length => Length}};
read_capacity_16(_Bytes) -> {error, short}.

%% The queue's head starts an operation once the engine is idle.
next(Now, State = #{phase := idle, queue := Queue}) ->
    case queue:out(Queue) of
        {empty, _} -> {State, []};
        {{value, Entry}, Rest} -> admit(Entry, Now, State#{queue := Rest})
    end;
next(_Now, State) ->
    {State, []}.

%% A request at the head of the queue is sent only within its deadline, for its unit's
%% current medium, and, for a flush, to a medium that flushes.
admit(#{id := Id, accepted := Accepted}, Now, State) when Now - Accepted >= ?ERX_BLK_WAIT_LIMIT_MS ->
    answer_next(Id, {error, {device, deadline}}, Now, State);
admit(Entry = #{id := Id, medium := Medium, request := Request}, Now, State) ->
    Current = current(lun(Request), State),
    case {ref(Current) =:= Medium, Current, Request} of
        {false, _Current, _Request} -> answer_next(Id, {error, {device, gone}}, Now, State);
        {true, none, {Kind, _Lun, _Sector, _Blocks}} when Kind =:= read; Kind =:= write ->
            answer_next(Id, {error, {device, gone}}, Now, State);
        {true, none, {flush, _Lun}} -> answer_next(Id, {error, {device, gone}}, Now, State);
        {true, #{ref := _Live}, {ready, _Lun, _New}} -> answer_next(Id, {error, {device, gone}}, Now, State);
        {true, #{flush := false}, {flush, _Lun}} -> answer_next(Id, {error, no_flush}, Now, State);
        {true, _Current, _Request} -> send(#{entry => Entry, stage => command, issued => Now}, command(Request), State)
    end.

answer_next(Id, Reply, Now, State) ->
    {Next, Actions} = next(Now, State),
    {Next, [{answer, Id, Reply} | Actions]}.

command({flush, Lun}) -> {synchronize_cache, Lun};
command({ready, Lun, _Ref}) -> {synchronize_cache, Lun};
command(Request) -> Request.

%% Posts Command's CBW under the next tag, a counter of this engine's, so a CSW or a late
%% completion of an earlier command never matches.
send(Op, Command, State = #{tag := Last}) ->
    Tag = (Last + 1) band 16#ffffffff,
    {_Direction, Length} = data_phase(Command),
    {State#{phase := command, tag := Tag,
            op := Op#{command => Command, tag => Tag, length => Length, moved => 0, data => <<>>}},
     [{command, Tag, Command}]}.

transferred(command, {ok, _Sent}, _Now, State = #{op := #{command := Command, tag := Tag}}) ->
    case data_phase(Command) of
        {none, 0} -> status(State);
        {in, Length} -> {State#{phase := data_in}, [{data_in, Tag, Length}]};
        {out, _Length} -> {State#{phase := data_out}, [{data_out, Tag, Command}]}
    end;
transferred(command, {error, _Reason}, _Now, State) ->
    recover(State);
transferred(data_in, {ok, Bytes}, _Now, State = #{op := Op}) when is_binary(Bytes) ->
    status(State#{op := Op#{moved := byte_size(Bytes), data := Bytes}});
transferred(data_out, {ok, Moved}, _Now, State = #{op := Op}) when is_integer(Moved) ->
    status(State#{op := Op#{moved := Moved}});
transferred(data_in, {error, _Reason}, _Now, State) ->
    {State#{phase := clear_data}, [{reset_pipe, in}]};
transferred(data_out, {error, _Reason}, _Now, State) ->
    {State#{phase := clear_data}, [{reset_pipe, out}]};
transferred(status, {error, _Reason}, _Now, State) ->
    {State#{phase := clear_status}, [{reset_pipe, in}]};
transferred(status_again, {error, _Reason}, _Now, State) ->
    recover(State);
transferred(Status, {ok, Bytes}, Now, State) when Status =:= status; Status =:= status_again ->
    judge(Bytes, Now, State).

status(State = #{op := #{tag := Tag}}) ->
    {State#{phase := status}, [{status, Tag}]}.

pipe_reset(clear_data, ok, _Now, State) ->
    status(State);
pipe_reset(clear_status, ok, _Now, State = #{op := #{tag := Tag}}) ->
    {State#{phase := status_again}, [{status, Tag}]};
pipe_reset(Clear, {error, _Reason}, _Now, State) when Clear =:= clear_data; Clear =:= clear_status ->
    recover(State);
pipe_reset(reset_2, ok, _Now, State) ->
    {State#{phase := reset_3}, [{reset_pipe, out}]};
pipe_reset(reset_3, ok, Now, State) ->
    recovered(Now, State);
pipe_reset(Reset, {error, Reason}, _Now, State) when Reset =:= reset_2; Reset =:= reset_3 ->
    stop({reset, Reason}, State).

controlled(reset_1, {ok, _Bytes}, _Now, State) ->
    {State#{phase := reset_2}, [{reset_pipe, in}]};
controlled(reset_1, {error, Reason}, _Now, State) ->
    stop({reset, Reason}, State);
controlled(max_lun, Answer, Now, State) ->
    case max_lun(Answer) of
        {ok, Count} ->
            Units = maps:from_keys(lists:seq(0, Count - 1), none),
            {Next, Actions} = next(Now, State#{phase := idle, units := Units}),
            {Next, [{units, Count} | Actions]};
        {error, Reason} ->
            stop(Reason, State)
    end.

recover(State) ->
    {State#{phase := reset_1}, [class_reset]}.

recovered(_Now, State = #{units := none}) ->
    {State#{phase := max_lun}, [get_max_lun]};
recovered(Now, State = #{op := none}) ->
    next(Now, State#{phase := idle});
recovered(Now, State = #{op := #{stage := command}}) ->
    finish({error, {device, reset}}, keep, Now, State);
recovered(Now, State = #{op := #{stage := sense}}) ->
    sense_failed(Now, State).

stop(Reason, State) ->
    {State#{phase := stopped}, [{stop, Reason}]}.

judge(Bytes, Now, State = #{op := #{tag := Tag, length := Length}}) ->
    case csw(Bytes, Tag, Length) of
        {good, Residue} -> moved(Residue, Now, State);
        {failed, _Residue} -> failed(Now, State);
        _ResetRecovery -> recover(State)
    end.

%% Status 1: the command's failure is explained by the operation's REQUEST SENSE, sent now,
%% before any other request; the sense's own failure is not explained further.
failed(_Now, State = #{op := Op = #{stage := command, command := Command}}) ->
    send(Op#{stage := sense}, {request_sense, lun(Command)}, State);
failed(Now, State = #{op := #{stage := sense}}) ->
    sense_failed(Now, State).

%% Status 0, with the residue the CSW reports.
moved(Residue, Now, State = #{op := #{stage := Stage, command := Command, length := Length, moved := Moved,
                                      data := Data}}) ->
    case {Stage, outcome(Command, Length, Residue, Moved, Data)} of
        {_Stage, not_meaningful} -> recover(State);
        {command, Outcome} -> completed(Outcome, Now, State);
        {sense, {ok, {Key, Asc, Ascq}}} -> sense_read(Key, Asc, Ascq, Now, State);
        {sense, {error, _Unread}} -> sense_failed(Now, State)
    end.

%% What a status-0 command moved, its CBW's Length, the CSW's Residue and the bytes Moved.
outcome({read, _Lun, _Sector, _Count}, Length, 0, Length, Data) -> {ok, Data};
outcome({write, _Lun, _Sector, _Written}, Length, 0, Length, _Read) -> ok;
outcome({Bulk, _Lun, _Sector, _Count}, _Length, _Residue, _Moved, _Data) when Bulk =:= read; Bulk =:= write ->
    {error, short};
outcome(_NoData, 0, _Residue, _Moved, _Data) -> ok;
outcome(_Metadata, Length, Residue, Moved, _Data) when Length - Residue > Moved -> not_meaningful;
outcome(Metadata, Length, Residue, _Moved, Data) -> decode(Metadata, binary_part(Data, 0, Length - Residue)).

decode({inquiry, _Lun}, Bytes) -> inquiry(Bytes);
decode({request_sense, _Lun}, Bytes) -> sense(Bytes);
decode({read_capacity_10, _Lun}, Bytes) -> read_capacity_10(Bytes);
decode({read_capacity_16, _Lun}, Bytes) -> read_capacity_16(Bytes).

completed(ok, Now, State = #{op := #{entry := #{request := {ready, Lun, Ref}}}}) ->
    become_ready(Lun, Ref, true, Now, State);
completed({error, short}, Now, State) ->
    finish({error, {device, short}}, keep, Now, State);
completed(Reply, Now, State) ->
    finish(Reply, keep, Now, State).

%% A readiness SYNCHRONIZE CACHE refused with ILLEGAL REQUEST makes a medium that cannot
%% flush (design-usb.md, "The SCSI subset"); any other sense is the request's answer.
sense_read(?ERX_SCSI_SENSE_KEY_ILLEGAL_REQUEST, _Asc, _Ascq, Now,
           State = #{op := #{entry := #{request := {ready, Lun, Ref}}}}) ->
    become_ready(Lun, Ref, false, Now, State);
sense_read(Key, Asc, Ascq, Now, State) ->
    Ends = case Key =:= ?ERX_SCSI_SENSE_KEY_NOT_READY orelse Key =:= ?ERX_SCSI_SENSE_KEY_UNIT_ATTENTION of
               true -> end_medium;
               false -> keep
           end,
    finish({error, {device, {sense, Key, Asc, Ascq}}}, Ends, Now, State).

sense_failed(Now, State) ->
    finish({error, {device, no_sense}}, end_medium, Now, State).

%% Late, the readiness is answered as any late operation, and no medium is made.
become_ready(_Lun, _Ref, _Flush, Now, State = #{op := #{issued := Issued}})
  when Now - Issued >= ?ERX_BLK_IN_FLIGHT_MS ->
    abandon(Now, State);
become_ready(Lun, Ref, Flush, Now, State = #{units := Units}) ->
    none = maps:get(Lun, Units),
    finish({ok, #{flush => Flush}}, keep, Now, State#{units := Units#{Lun := #{ref => Ref, flush => Flush}}}).

%% The operation done: its answer, then its unit's medium ended when Medium says so, then
%% the next request, so no queued request runs against a medium the operation has ended.
finish(_Reply, _Medium, Now, State = #{op := #{issued := Issued}}) when Now - Issued >= ?ERX_BLK_IN_FLIGHT_MS ->
    abandon(Now, State);
finish(Reply, Medium, Now, State = #{op := #{entry := #{id := Id, medium := Ref, request := Request}}}) ->
    Idle = State#{phase := idle, op := none},
    {Ended, EndActions} = case Medium of
                              end_medium -> end_medium(lun(Request), Ref, Idle);
                              keep -> {Idle, []}
                          end,
    {Next, NextActions} = next(Now, Ended),
    {Next, [{answer, Id, Reply} | EndActions] ++ NextActions}.

%% The operation's deadline passed: it is answered so, its medium ends, and reset recovery
%% readies the device before the next command.
abandon(Now, State = #{op := #{entry := #{id := Id, medium := Ref, request := Request}}}) ->
    {Ended, EndActions} = end_medium(lun(Request), Ref, State#{op := none}),
    {Recovering, ResetActions} = recover(Ended),
    {Swept, Expired} = expire_queued(Now, Recovering),
    {Swept, [{answer, Id, {error, {device, deadline}}} | EndActions] ++ ResetActions ++ Expired}.

expire_queued(Now, State = #{queue := Queue}) ->
    {Expired, Kept} = lists:partition(fun(#{accepted := Accepted}) ->
                                              Now - Accepted >= ?ERX_BLK_WAIT_LIMIT_MS
                                      end, queue:to_list(Queue)),
    {State#{queue := queue:from_list(Kept)}, [{answer, Id, {error, {device, deadline}}} || #{id := Id} <- Expired]}.

%% Ends the medium Ref if it is still Lun's current one: every queued request for it is
%% answered gone. Any other reference, none included, ends nothing.
end_medium(Lun, Ref, State = #{units := Units, queue := Queue}) ->
    case maps:get(Lun, Units) of
        #{ref := Ref} ->
            {Gone, Kept} = lists:partition(fun(#{medium := Medium}) -> Medium =:= Ref end, queue:to_list(Queue)),
            {State#{units := Units#{Lun := none}, queue := queue:from_list(Kept)},
             [{answer, Id, {error, {device, gone}}} || #{id := Id} <- Gone] ++ [{medium_ended, Lun, Ref}]};
        _NoneOrAnother ->
            {State, []}
    end.

current(Lun, #{units := Units}) -> maps:get(Lun, Units).

%% Every request and command names its unit second.
lun(RequestOrCommand) -> element(2, RequestOrCommand).

ref(none) -> none;
ref(#{ref := Ref}) -> Ref.
