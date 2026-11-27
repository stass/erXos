%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_fake_stick).
-moduledoc """
A model USB flash drive for erx_usb_fake_xhci: one logical unit, or as
many as a card reader's, each a fixed, not removable, 128-sector medium of
512-byte blocks held in memory, speaking Bulk-Only Transport (BOT 1.0, 5
and 6) and the SCSI commands the mass-storage function sends. The units
share the one command state and the one pending sense, as they share the
interface.

Its command state is BOT's: waiting for a CBW, in a command's data phase
(bulk-in data to send, or bulk-out data to take), or holding the CSW. A
class reset readies it for a CBW whatever it held, and a transfer out of
turn stalls. A command that fails answers status 1 and keeps the sense
REQUEST SENSE reads next.

The test plants faults as erx_fault_plan rules over four kinds of
transfer, `cbw`, `data_out`, `data_in` and `csw`, which the stick asks
at each. It acts them as the controller's answers: `silent` is `hold`,
the transfer left unanswered with the stick's state where it was, so
the device can be unplugged mid-transfer;
`{wrong_once, Answer}` replaces the right answer, the state moving on
as for the right one (a CSW of 12 bytes, or one with a wrong signature);
`gone` is `{error, gone}`. `{error, Reason}` is `{error, Reason}`, and in
a data phase, in or out, it also fails the command with MEDIUM ERROR,
as an unreadable sector does. The stick does not act `{late, Ms}`, whose
effect must land when the transfer completes: a test that plants it fails.
A stick told to lie about residue (lie_about_residue/1) reports FFFFFFFFh
as every CSW's residue from then on, as a device that cannot count; a
wedged stick (wedge/1) stalls every bulk transfer, its class reset and
its endpoints' clears notwithstanding, until its port is reset
(port_reset/1), as a stick only a port reset revives. Both are
properties of the device, not faults of one transfer.
""".

-include("generated/erx_abi.hrl").

-export([new/1, lie_about_residue/1, wedge/1, units/1, fault/2, reset/1, port_reset/1, bulk_out/2, bulk_in/2]).
-export_type([answer/0]).

%% A transfer's answer as the controller gives it, or a fault's form of one (the moduledoc).
-type answer() :: {ok, binary()} | {error, term()} | hold.

-define(BLOCKS, 128).
-define(BLOCK, 512).
%% MEDIUM ERROR, UNRECOVERED READ ERROR (SPC's sense key 3, ASC 11h).
-define(MEDIUM_ERROR, {3, 16#11, 0}).

new(Units) ->
    #{media => maps:from_keys(lists:seq(0, Units - 1), binary:copy(<<0>>, ?BLOCKS * ?BLOCK)), phase => cbw,
      sense => {0, 0, 0}, plan => erx_fault_plan:new([]), wedged => false}.

lie_about_residue(Stick) -> Stick#{residue_lie => true}.

wedge(Stick) -> Stick#{wedged := true}.

units(#{media := Media}) -> map_size(Media).

%% Stick with Rule, an erx_fault_plan rule, after its other rules.
fault(Stick = #{plan := Plan}, Rule) -> Stick#{plan := erx_fault_plan:add(Rule, Plan)}.

reset(Stick) -> Stick#{phase := cbw}.

%% The stick's port reset: it is ready for a CBW and no longer wedged.
port_reset(Stick) -> Stick#{phase := cbw, wedged := false}.

%% A bulk-OUT transfer: a CBW for one of the units, or a write's data; its answer as the
%% controller's.
bulk_out(_Data, Stick = #{wedged := true}) ->
    {{error, stall}, Stick};
bulk_out(<<?ERX_USB_BOT_CBW_SIGNATURE:32/little, Tag:32/little, Length:32/little, _Flags, Lun, Size, Block:16/binary>>,
         Stick = #{phase := cbw, media := Media}) when Size >= 1, Size =< 16, is_map_key(Lun, Media) ->
    exchange(cbw, Stick, fun(S) -> {{ok, <<>>}, command(Tag, Length, binary_part(Block, 0, Size), Lun, S)} end);
bulk_out(Data, Stick = #{phase := {data_out, Tag, Length, Lun, Sector}, media := Media}) when byte_size(Data) =:= Length ->
    Offset = Sector * ?BLOCK,
    <<Before:Offset/binary, _Old:Length/binary, After/binary>> = maps:get(Lun, Media),
    exchange(data_out, Stick,
             fun(S) -> {{ok, <<>>}, S#{media := Media#{Lun := <<Before/binary, Data/binary, After/binary>>},
                                       phase := {csw, Tag, 0, 0}}} end,
             fun(S) -> S#{phase := {csw, Tag, Length, 1}, sense := ?MEDIUM_ERROR} end);
bulk_out(_OutOfTurn, Stick) ->
    {{error, stall}, Stick}.

%% A bulk-IN transfer: a command's data, or its CSW.
bulk_in(_Length, Stick = #{wedged := true}) ->
    {{error, stall}, Stick};
bulk_in(_Length, Stick = #{phase := {data_in, Tag, Bytes, Residue}}) ->
    exchange(data_in, Stick,
             fun(S) -> {{ok, Bytes}, S#{phase := {csw, Tag, Residue, 0}}} end,
             fun(S) -> S#{phase := {csw, Tag, byte_size(Bytes) + Residue, 1}, sense := ?MEDIUM_ERROR} end);
bulk_in(_Length, Stick = #{phase := {csw, Tag, Residue, Status}}) ->
    Reported = case Stick of
                   #{residue_lie := true} -> 16#ffffffff;
                   #{} -> Residue
               end,
    Csw = <<?ERX_USB_BOT_CSW_SIGNATURE:32/little, Tag:32/little, Reported:32/little, Status>>,
    exchange(csw, Stick, fun(S) -> {{ok, Csw}, S#{phase := cbw}} end);
bulk_in(_Length, Stick) ->
    {{error, stall}, Stick}.

%% A transfer of Kind, as the plan has it meet the stick: Right(Stick) is the right
%% answer and the stick after it; Failed(Stick) the stick after an `{error, Reason}`,
%% which in a data phase fails the command.
exchange(Kind, Stick, Right) ->
    exchange(Kind, Stick, Right, fun(S) -> S end).

exchange(Kind, Stick = #{plan := Plan0}, Right, Failed) ->
    {Fault, Plan} = erx_fault_plan:ask(Kind, Plan0),
    Asked = Stick#{plan := Plan},
    case Fault of
        pass -> Right(Asked);
        silent -> {hold, Asked};
        gone -> {{error, gone}, Asked};
        {error, Reason} -> {{error, Reason}, Failed(Asked)};
        {late, _Ms} -> error({not_acted_by_the_stick, Fault});
        {wrong_once, Wrong} -> {Answer, Moved} = Right(Asked), {erx_fault_plan:wrong_answer(Wrong, Answer), Moved}
    end.

%% A command block for unit Lun, by its operation code (sys/cam/scsi/scsi_all.h's layouts).
command(Tag, _Length, <<?ERX_SCSI_OP_TEST_UNIT_READY, _/binary>>, _Lun, Stick) ->
    Stick#{phase := {csw, Tag, 0, 0}};
command(Tag, Length, <<?ERX_SCSI_OP_SYNCHRONIZE_CACHE_10, _/binary>>, _Lun, Stick) ->
    Stick#{phase := {csw, Tag, Length, 0}};
command(Tag, Length, <<?ERX_SCSI_OP_REQUEST_SENSE, _/binary>>, _Lun, Stick = #{sense := {Key, Asc, Ascq}}) ->
    data_in(Tag, Length, <<16#70, 0, Key, 0:32, 10, 0:32, Asc, Ascq, 0:32>>, Stick#{sense := {0, 0, 0}});
command(Tag, Length, <<?ERX_SCSI_OP_INQUIRY, _/binary>>, _Lun, Stick) ->
    data_in(Tag, Length, <<0, 0, 2, 2, 31, 0, 0, 0, "erXos   ", "Model stick     ", "1.0 ">>, Stick);
command(Tag, Length, <<?ERX_SCSI_OP_READ_CAPACITY_10, _/binary>>, _Lun, Stick) ->
    data_in(Tag, Length, <<(?BLOCKS - 1):32, ?BLOCK:32>>, Stick);
command(Tag, Length, <<?ERX_SCSI_OP_READ_10, 0, Sector:32, 0, Count:16, 0>>, Lun, Stick = #{media := Media}) ->
    data_in(Tag, Length, binary_part(maps:get(Lun, Media), Sector * ?BLOCK, Count * ?BLOCK), Stick);
command(Tag, Length, <<?ERX_SCSI_OP_WRITE_10, 0, Sector:32, 0, Count:16, 0>>, Lun, Stick) when Length =:= Count * ?BLOCK ->
    Stick#{phase := {data_out, Tag, Length, Lun, Sector}}.

data_in(Tag, Length, Bytes, Stick) ->
    Sent = binary_part(Bytes, 0, min(Length, byte_size(Bytes))),
    Stick#{phase := {data_in, Tag, Sent, Length - byte_size(Sent)}}.
