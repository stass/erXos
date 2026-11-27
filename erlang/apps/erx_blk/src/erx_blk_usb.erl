%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The block transport of one medium on a USB mass-storage unit (docs/design-usb.md, "The
%% block transport"): it answers erx_blk's four calls, read, write, flush and info, with the
%% transport contract's answers and closed error set, by handing each request to the
%% medium's BOT function, erx_usb_bot, which runs it through the BOT engine.
%%
%% The function starts one for each medium that becomes ready, and stops it when the medium
%% ends; it is reached by pid and never registered. The function and its transport monitor
%% each other, never link: the function's end ends the transport, and the transport's end
%% ends only its medium, which the function's unit finds again by its readiness sequence.
%% With its window it is the medium's block service (docs/design-usb.md, "Media and
%% drives"): it starts one window of role drive over every sector of the medium,
%% erx_blk_window linked to it and bound to it, so the window ends with the transport and
%% the transport with a window that crashes; and it tells the medium's drive grant, when
%% the function names one, of that window and that the grant ends the medium through the
%% function under the medium's reference (erx_blk_drive).
%% It holds the medium's reference, which every request it hands the function carries, so
%% the engine answers a request of a medium that has ended `{error, {device, gone}}` and
%% sends nothing. It checks
%% each request against the contract's bounds before the function sees it: a count of no
%% sectors, or above max_sectors, or bytes that are not whole sectors is bad_count; sectors
%% past the capacity are out_of_range (erx_blk_request:range/4). Every other answer is the
%% engine's: `{device, Detail}`
%% with Detail a sense's three integers, no_sense, reset, short, gone or deadline, and
%% no_flush for a flush of a medium that cannot flush.
%%
%% One request is with the function at a time. The function's call is not timed out here:
%% the engine answers every request within its queue and issue deadlines, 28 s together,
%% inside erx_blk's own call timeout, and the function's end ends this process with
%% `shutdown`, whether its monitor or a call in progress observes it.

-module(erx_blk_usb).
-behaviour(gen_server).

-export([start_monitor/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).

-export_type([medium/0]).

-include("generated/erx_abi.hrl").

%% One bulk buffer's worth of sectors, 64 (docs/design-usb.md, "The block transport").
-define(MAX_SECTORS, (?ERX_XHCI_BULK_BUFFER_SIZE div ?ERX_SCSI_BLOCK_LENGTH)).

-doc "What the function knows of a ready medium: its unit, reference, capacity in sectors, whether it flushes, the unit's text, and the drive grant that hands the medium out, or none.".
-type medium() :: #{function := pid(), lun := erx_usb_bot_core:lun(), ref := erx_usb_bot_core:medium_ref(),
                    capacity := pos_integer(), flush := boolean(), detail := map(), drive := none | pid()}.

-doc "Starts the transport of Medium, monitored by the caller, its BOT function, and monitoring it.".
-spec start_monitor(medium()) -> {ok, {pid(), reference()}}.
start_monitor(Medium) ->
    gen_server:start_monitor(?MODULE, Medium, []).

-doc false.
init(Medium = #{function := Function, lun := Lun, ref := Ref, capacity := Capacity, drive := Drive}) ->
    _ = monitor(process, Function),
    {ok, Window} = erx_blk_window:start_link({drive, 0, Capacity}, self(), ?MAX_SECTORS),
    _ = Drive =/= none andalso erx_blk_drive:serve(Drive, Window, {Function, {Lun, Ref}}),
    {ok, Medium}.

-doc false.
handle_call({read, Sector, Count}, _From, M = #{lun := Lun}) ->
    {reply, checked(Sector, Count, M, fun() -> request({read, Lun, Sector, Count}, M) end), M};
handle_call({write, Sector, Data}, _From, M = #{lun := Lun}) when is_binary(Data),
                                                                   byte_size(Data) rem ?ERX_SCSI_BLOCK_LENGTH =:= 0 ->
    Count = byte_size(Data) div ?ERX_SCSI_BLOCK_LENGTH,
    {reply, checked(Sector, Count, M, fun() -> request({write, Lun, Sector, Data}, M) end), M};
handle_call({write, _Sector, _Data}, _From, M) ->
    {reply, {error, bad_count}, M};
handle_call(flush, _From, M = #{lun := Lun}) ->
    {reply, request({flush, Lun}, M), M};
handle_call(info, _From, M = #{capacity := Capacity, flush := Flush, detail := Detail}) ->
    {reply, {ok, #{transport => usb_bot, capacity => Capacity, max_sectors => ?MAX_SECTORS, flush => Flush,
                   detail => Detail}}, M}.

-doc false.
handle_cast(_Request, M) ->
    {noreply, M}.

-doc false.
handle_info({'DOWN', _Monitor, process, Function, _Reason}, M = #{function := Function}) ->
    {stop, shutdown, M};
handle_info(_Message, M) ->
    {noreply, M}.

%% A crash report shows the medium's unit, capacity and flush, and a message's kind; never
%% the unit's INQUIRY text, a request's sectors or a write's data. erx_report:status/2
%% hides the log and cuts the reason to its leading atom (docs/design-log.md, "Reports
%% carry no term").
-doc false.
format_status(Status) ->
    erx_report:status(Status, #{state => fun medium_facts/1, message => fun erx_report:reason_name/1}).

medium_facts(M = #{lun := _, capacity := _, flush := _}) -> maps:with([lun, capacity, flush], M);
medium_facts(_State) -> hidden.

%% Send the request only if its sectors are one request on the medium, by the transports'
%% one check (erx_blk_request:range/4).
checked(Sector, Count, #{capacity := Capacity}, Send) ->
    case erx_blk_request:range(Sector, Count, ?MAX_SECTORS, Capacity) of
        ok -> Send();
        Refused -> Refused
    end.

%% The function's call has no timeout, so it exits only when the function has ended. That
%% end ends this process with `shutdown`, as its monitor would, so no crash report carries
%% the call's arguments, a write's sectors among them.
request(Request, #{function := Function, ref := Ref}) ->
    try
        erx_usb_bot:request(Function, Ref, Request)
    catch
        exit:{_FunctionEnd, {gen_server, call, _Arguments}} -> exit(shutdown)
    end.
