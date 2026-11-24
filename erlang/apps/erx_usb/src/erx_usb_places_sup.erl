%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_places_sup).
-moduledoc """
The USB domain's places (docs/design-usb.md, "Hotplug ends at the
controller's domain", "The process tree"): what a reader outside the USB
domain holds, which lasts as long as the domain does. It supervises one
stream, erx_usb_input_stream, for each input number, `hid0` to `hid7`; one
drive grant, erx_blk_drive, for each drive the domain's records name
(erx_device_record:drives/2, docs/design-fiasco.md, "Drive records"); and
last the mint of the input tree, erx_usb_input_tree, that serves the
streams, the files service `usb_input` (erx_fs_mint), whose grants the
domain service hands to the display domain the manifest names. The
domain's top supervisor, erx_usb, starts the places once, from the USB
domain's boot script, before init's ready report, so a domain serves one
input tree, under one service name, and only the USB domain serves it.

The places hold no device state, so nothing beside them, a function's crash
or a controller's reset, ends them. Nothing restarts them either: every
child is permanent and the intensity is 0, so the end of any child ends the
places, and through erx_usb the domain. The domain service
mints a service's grants only for a new incarnation of its domain
(docs/design-system.md, "Facets a configured domain serves"), so places
started again within one incarnation would serve no reader; the domain's
restart is the fresh try.

A function takes its number with occupy_input/2, the lowest number free
when it asks, and holds it until its process ends, when the number's stream
writes `release`. A number is free when it has no occupant and its stream
has room for one read's worth (erx_usb_input_stream).

A ready medium takes its drive with occupy_drive/2, the lowest drive free
when its function asks, and holds it until the medium's window ends
(erx_blk_drive:occupy/2); a medium that finds every drive taken is not
served, and its unit shows `no drive` (erx_usb_bot). Drive records the
reader refuses start no grant: the places log the reason, and every ready
medium finds no drive, as on a domain whose manifest names none.

The mint names itself the service's mint and acknowledges its start before
it mounts the tree; its mount, in the mint's own process, reads the streams
from the places, which by then have started every child and serve the call
(erx_fs_mint). Each grant of the tree holds the streams' pids, which end
only with the places, and so with every grant.
""".
-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/0, start_link/1, occupy_input/2, streams/1, occupy_drive/2, drives/1]).
-export([init/1, start_mint/1, start_drive_mint/1]).

-doc "Starts the USB domain's places over the domain's drive records, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    start_link(erx_device_record:drives(usb)).

-doc "Starts the places over Drives, erx_device_record:drives/1's answer for `usb`, linked to the caller.".
-spec start_link({ok, [non_neg_integer()]} | {error, {bad_device_record, string()}}) -> {ok, pid()}.
start_link(Drives) ->
    supervisor:start_link(?MODULE, Drives).

-doc """
Makes Pid the occupant of the lowest input number of Places that is free,
and answers the number and its stream, which takes Pid's records
(erx_usb_input_stream:write/2), or `{error, no_input_number}` when every number is
taken.
""".
-spec occupy_input(pid(), pid()) -> {ok, non_neg_integer(), pid()} | {error, no_input_number}.
occupy_input(Places, Pid) when is_pid(Pid) ->
    lowest(streams(Places), 0, Pid).

-doc "The streams of Places' input numbers, number 0 first, the input tree's arguments in order.".
-spec streams(pid()) -> [pid()].
streams(Places) ->
    [Stream || {_, Stream} <- lists:sort([{N, Stream} || {{input, N}, Stream, _, _} <- supervisor:which_children(Places)])].

-doc """
Makes Pid, a mass-storage function, the occupant of the lowest drive of
Places that is free, for the medium it is about to serve, and answers the
drive's number and its grant, which the medium's block service is started
with; or `{error, no_drive}` when every drive is taken or there is none.
""".
-spec occupy_drive(pid(), pid()) -> {ok, non_neg_integer(), pid()} | {error, no_drive}.
occupy_drive(Places, Pid) when is_pid(Pid) ->
    case lists:search(fun({_N, Grant}) -> erx_blk_drive:occupy(Grant, Pid) =:= ok end, drives(Places)) of
        {value, {N, Grant}} -> {ok, N, Grant};
        false -> {error, no_drive}
    end.

-doc "The drives of Places and their grants, lowest number first.".
-spec drives(pid()) -> [{non_neg_integer(), pid()}].
drives(Places) ->
    lists:sort([{N, Grant} || {{drive, N}, Grant, _, _} <- supervisor:which_children(Places)]).

%% ---------------------------------------------------------------------------
%% The supervisor's callback
%% ---------------------------------------------------------------------------

-doc false.
init(Drives) ->
    Streams = [#{id => {input, N}, start => {erx_usb_input_stream, start_link, []}}
               || N <- lists:seq(0, ?ERX_USB_INPUT_MAX - 1)],
    Grants = [#{id => {drive, N}, start => {erx_blk_drive, start_link, []}} || N <- numbers(Drives)],
    %% The drives' mint, after their grants, and only with a drive: a ready report of a
    %% domain no drive window lies on may not provide drive (erx_domain_mints).
    DriveMint = [#{id => drive_mint, start => {?MODULE, start_drive_mint, [self()]}, shutdown => brutal_kill,
                   modules => [erx_blk_drive]} || Grants =/= []],
    Mint = #{id => mint, start => {?MODULE, start_mint, [self()]}, shutdown => brutal_kill,
             modules => [erx_fs_mint]},
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, Streams ++ Grants ++ DriveMint ++ [Mint]}}.

%% The input tree's mint, whose mount answers the streams of Places, number 0 first.
-doc false.
-spec start_mint(pid()) -> {ok, pid()}.
start_mint(Places) ->
    erx_fs_mint:start_link(usb_input, erx_usb_input_tree,
                           fun() -> list_to_tuple(streams(Places)) end).

%% The drives' mint (erx_blk_drive:start_mint/1), which finds a drive's grant among the
%% places' children at each ask.
-doc false.
-spec start_drive_mint(pid()) -> {ok, pid()}.
start_drive_mint(Places) ->
    erx_blk_drive:start_mint(fun(N) ->
                                     case lists:keyfind(N, 1, drives(Places)) of
                                         {N, Grant} -> {ok, Grant};
                                         false -> unknown
                                     end
                             end).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

%% The drive numbers the records name, or none, logged, when the reader refused them. The
%% reason is the reader's own text, about words the domain library wrote.
numbers({ok, Numbers}) ->
    Numbers;
numbers({error, {bad_device_record, Reason}}) ->
    logger:warning("erx_usb_places_sup: drive records refused, no drive served: ~ts", [Reason]),
    [].

lowest([], _N, _Pid) ->
    {error, no_input_number};
lowest([Stream | Rest], N, Pid) ->
    case erx_usb_input_stream:occupy(Stream, Pid) of
        ok -> {ok, N, Stream};
        taken -> lowest(Rest, N + 1, Pid)
    end.
