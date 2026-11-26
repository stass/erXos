%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The HID function (docs/design-usb.md, "HID"): erx_hid_core:plan/2's protocol choice,
%% and erx_usb_hid end to end, from a model device's reports to the records a reader of
%% the input tree decodes, as the display's erx_input_reader does. The device is a
%% process of this module, reached through the erx_usb_pipe stand-in
%% (test/erlang/stand_in/erx_usb_pipe.erl): it answers control requests, holds the
%% interrupt-IN transfers the function posts, completes the oldest with each report the
%% case gives it and keeps the reports that find no transfer posted, as a device waits
%% with its reports. The places and a real erx_fs grant of their input tree are the
%% domain's own. Each wait has a deadline of 1 s.
-module(erx_usb_hid_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(NOFID, 16#ffffffff).
%% How long a case waits for a reply, an end or a state it expects before it fails. Only a
%% failing case waits it out, so it is long enough for a host loaded many times over; the
%% runner scales EUnit's per-case timeout above it, so such a case fails on its own error.
-define(WAIT_MS, 10000).
-define(O_RDONLY, 0).
%% The fid of number N's open file is ?FID0 + N.
-define(FID0, 10).
-define(RECORD, (erx_input_codec:size())).
-define(INTERFACE, 2).
-define(KEY_A, ?ERX_EVDEV_KEY_A).
-define(KEY_B, ?ERX_EVDEV_KEY_B).
-define(SHIFT, ?ERX_EVDEV_KEY_LEFTSHIFT).

%% FreeBSD's boot keyboard descriptor (hidrdesc.h, lines 336-368), which QEMU's
%% usb-kbd's matches field for field: modifiers, a reserved byte, LED outputs and six
%% key usages.
-define(KEYBOARD,
        <<16#05, 16#01, 16#09, 16#06, 16#a1, 16#01, 16#05, 16#07, 16#19, 16#e0, 16#29, 16#e7,
          16#15, 16#00, 16#25, 16#01, 16#75, 16#01, 16#95, 16#08, 16#81, 16#02, 16#95, 16#01,
          16#75, 16#08, 16#81, 16#01, 16#95, 16#03, 16#75, 16#01, 16#05, 16#08, 16#19, 16#01,
          16#29, 16#03, 16#91, 16#02, 16#95, 16#05, 16#75, 16#01, 16#91, 16#01, 16#95, 16#06,
          16#75, 16#08, 16#15, 16#00, 16#26, 16#ff, 16#00, 16#05, 16#07, 16#19, 16#00, 16#2a,
          16#ff, 16#00, 16#81, 16#00, 16#c0>>).
%% A vendor page's one input byte: a descriptor that parses to a layout with no role.
-define(NO_ROLE, <<16#06, 16#00, 16#ff, 16#09, 16#01, 16#a1, 16#01, 16#15, 16#00, 16#25, 16#01,
                   16#75, 16#08, 16#95, 16#01, 16#09, 16#01, 16#81, 16#02, 16#c0>>).
%% An item cut off by the descriptor's end, which the parser refuses.
-define(REFUSED, <<16#05>>).

%% The plan -------------------------------------------------------------------------

setting(Subclass, Protocol, {failing, _Reason, Announced}) ->
    (setting(Subclass, Protocol, <<>>))#{hid := #{report_length => Announced}};
setting(Subclass, Protocol, Descriptor) ->
    #{class => ?ERX_USB_CLASS_HID, subclass => Subclass, protocol => Protocol, endpoints => [],
      hid => #{report_length => byte_size(Descriptor)}}.

%% A boot keyboard whose descriptor parses is driven in the report protocol with it, and
%% is a keyboard, so it is sent SET_IDLE(0).
a_boot_interface_with_a_usable_descriptor_uses_the_report_protocol_test() ->
    {ok, Plan} = erx_hid_core:plan(setting(1, 1, ?KEYBOARD), {ok, ?KEYBOARD}),
    ?assertMatch(#{protocol := report, idle := true}, Plan),
    ?assertEqual([keys], erx_hid_core:roles(maps:get(layout, Plan))).

%% A boot interface whose descriptor is refused, has no role or could not be read falls
%% back to the boot protocol and the boot layout of its protocol.
a_boot_interface_falls_back_to_the_boot_layout_test() ->
    {ok, Keyboard} = erx_hid_core:plan(setting(1, 1, ?REFUSED), {ok, ?REFUSED}),
    ?assertMatch(#{protocol := boot, idle := true}, Keyboard),
    ?assertEqual(8, erx_hid_core:transfer_length(maps:get(layout, Keyboard))),
    {ok, Mouse} = erx_hid_core:plan(setting(1, 2, ?NO_ROLE), {ok, ?NO_ROLE}),
    ?assertMatch(#{protocol := boot, idle := false}, Mouse),
    ?assertEqual([pointer, buttons], erx_hid_core:roles(maps:get(layout, Mouse))),
    ?assertEqual(3, erx_hid_core:transfer_length(maps:get(layout, Mouse))),
    {ok, Unread} = erx_hid_core:plan(setting(1, 1, ?KEYBOARD), {error, {report_descriptor, stall}}),
    ?assertMatch(#{protocol := boot}, Unread).

%% Any other interface, and a boot interface of no boot protocol, uses the parsed layout
%% or ends with the reason it cannot.
other_interfaces_use_the_parsed_layout_or_end_test() ->
    ?assertMatch({ok, #{protocol := none, idle := true}}, erx_hid_core:plan(setting(0, 0, ?KEYBOARD), {ok, ?KEYBOARD})),
    ?assertEqual({error, truncated}, erx_hid_core:plan(setting(0, 1, ?REFUSED), {ok, ?REFUSED})),
    ?assertEqual({error, no_usable_report}, erx_hid_core:plan(setting(0, 0, ?NO_ROLE), {ok, ?NO_ROLE})),
    ?assertEqual({error, no_usable_report}, erx_hid_core:plan(setting(1, 0, ?NO_ROLE), {ok, ?NO_ROLE})),
    ?assertEqual({error, {report_descriptor, timeout}},
                 erx_hid_core:plan(setting(0, 0, ?KEYBOARD), {error, {report_descriptor, timeout}})).

%% Fixtures -------------------------------------------------------------------------

%% The places, an own grant of their input tree with every number's file open, and the
%% places unlinked, so a case's end stops them.
places() ->
    {ok, Places} = erx_usb_places_sup:start_link(),
    unlink(Places),
    {ok, {Grant, _Tree, _Rights}} = erx_fs_grants:own(erx_usb_places_prop:mint_grants(Places)),
    {ok, _} = call(Grant, {attach, 1, ?NOFID, <<"user">>, ?ERX_INPUT_TREE_BYTES, 0}),
    [begin
         {ok, _} = call(Grant, {walk, 1, ?FID0 + N, [<<"hid", (integer_to_binary(N))/binary>>]}),
         {ok, _, _} = call(Grant, {lopen, ?FID0 + N, ?O_RDONLY})
     end || N <- lists:seq(0, ?ERX_USB_INPUT_MAX - 1)],
    #{places => Places, grant => Grant}.

call(Grant, Request) ->
    Alias = alias([reply]),
    Grant ! {erx_9p, Alias, self(), Request},
    receive {erx_9p, Alias, Reply} -> Reply after ?WAIT_MS -> erlang:error({no_reply, Request}) end.

%% Reads number N's file until it has given Count records, at most 256 a read, decoding
%% them as the display's reader does.
records(#{grant := Grant}, N, Count) ->
    records(Grant, N, Count, []).

records(_Grant, _N, 0, Records) ->
    Records;
records(Grant, N, Count, Records) ->
    {ok, Bytes} = call(Grant, {read, ?FID0 + N, 0, min(Count, 256) * ?RECORD}),
    {Read, 0, <<>>} = erx_input_codec:decode(Bytes),
    records(Grant, N, Count - length(Read), Records ++ Read).

%% Reads number N's file, a record at a time, until it gives Last, and answers every
%% record it gave.
records_until(P, N, Last) ->
    case records(P, N, 1) of
        [Last] -> [Last];
        [Record] -> [Record | records_until(P, N, Last)]
    end.

%% A HID function on a model device of Subclass and Protocol whose report descriptor
%% read answers Descriptor, started as the bus process starts one: monitored, then
%% told to go.
function(#{places := Places}, Subclass, Protocol, Descriptor) ->
    Device = spawn(fun() -> device(Descriptor) end),
    Function = #{driver => erx_usb_hid, interface => ?INTERFACE, alternate => 0,
                 setting => setting(Subclass, Protocol, Descriptor), pipes => []},
    {ok, Pid} = erx_usb_hid:start_link(#{function => Function, control => {stand_in_pipe, Device, 0},
                                         pipes => [{stand_in_pipe, Device, 16#81}], places => Places}),
    unlink(Pid),
    _ = erlang:monitor(process, Pid),
    ok = erx_usb_bus:go(Pid),
    #{device => Device, pid => Pid}.

keyboard(P) ->
    F = function(P, 1, 1, ?KEYBOARD),
    wait_posted(F, 4),
    F.

ended(#{pid := Pid}) ->
    receive {'DOWN', _, process, Pid, Reason} -> Reason after ?WAIT_MS -> erlang:error({not_ended, Pid}) end.

%% A boot keyboard report: modifier bits, the reserved byte and up to six key usages.
keys(Modifiers, Usages) ->
    Padded = Usages ++ lists:duplicate(6 - length(Usages), 0),
    <<Modifiers, 0, (list_to_binary(Padded))/binary>>.

report(#{device := Device}, Report) -> Device ! {report, Report}, ok.

detach(#{device := Device}) -> Device ! detach, ok.

%% The model device's answer, waited for as long as the device lives: it answers every
%% question once it has taken the messages before it, however long a loaded host takes.
ask(#{device := Device}, What) ->
    Monitor = monitor(process, Device),
    Device ! {What, self()},
    receive
        {Device, What, Answer} -> demonitor(Monitor, [flush]), Answer;
        {'DOWN', Monitor, process, Device, Reason} -> erlang:error({device_ended, What, Reason})
    end.

wait_posted(F, Count) ->
    wait(fun() -> length(maps:get(posted, ask(F, state))) =:= Count end).

wait(Done) -> wait(Done, ?WAIT_MS).

%% Polls Done until it holds, and fails once Ms have passed without.
wait(Done, Ms) -> wait_until(Done, erlang:monotonic_time(millisecond) + Ms).

wait_until(Done, Deadline) ->
    case Done() of
        true -> ok;
        false ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline),
            timer:sleep(10),
            wait_until(Done, Deadline)
    end.

%% The model device -----------------------------------------------------------------

%% It answers GET_DESCRIPTOR(report) with Descriptor and every other request with
%% success, records every setup in order, holds the posted transfers and the reports
%% waiting for one. Detached, it completes every transfer, held or posted after, gone.
device(Descriptor) ->
    serve(#{descriptor => Descriptor, setups => [], posted => [], waiting => [], attached => true}).

serve(D = #{descriptor := Descriptor, setups := Setups}) ->
    receive
        {control, From, Ref, _Pipe, Setup, Data} ->
            From ! {Ref, answer(Setup, Data, Descriptor)},
            serve(D#{setups := Setups ++ [Setup]});
        {interrupt_in, From, Pipe, Tag, Length} ->
            serve(complete(D#{posted := maps:get(posted, D) ++ [{From, Pipe, Tag, Length}]}));
        {report, Report} ->
            serve(complete(D#{waiting := maps:get(waiting, D) ++ [Report]}));
        detach ->
            serve(complete(D#{attached := false}));
        {state, From} ->
            From ! {self(), state, D},
            serve(D)
    end.

answer(<<_, ?ERX_USB_REQUEST_GET_DESCRIPTOR, _/binary>>, {in, _Length}, {failing, Reason, _Announced}) ->
    {error, Reason};
answer(<<_, ?ERX_USB_REQUEST_GET_DESCRIPTOR, _/binary>>, {in, Length}, Descriptor) ->
    {ok, binary:part(Descriptor, 0, min(Length, byte_size(Descriptor)))};
answer(_Setup, none, _Descriptor) ->
    {ok, <<>>}.

complete(D = #{attached := false, posted := Posted}) ->
    [From ! {usb, Pipe, Tag, {error, gone}} || {From, Pipe, Tag, _} <- Posted],
    D#{posted := []};
complete(D = #{posted := [{From, Pipe, Tag, Length} | Posted], waiting := [Report | Waiting]}) ->
    From ! {usb, Pipe, Tag, {ok, binary:part(Report, 0, min(Length, byte_size(Report)))}},
    complete(D#{posted := Posted, waiting := Waiting});
complete(D) ->
    D.

%% The function ---------------------------------------------------------------------

%% A boot keyboard is read, set to the report protocol, set idle and given four
%% transfers of its 8-byte report, each request to its own interface.
a_keyboard_attaches_with_its_requests_test() ->
    P = places(),
    F = keyboard(P),
    #{setups := Setups, posted := Posted} = ask(F, state),
    Length = byte_size(?KEYBOARD),
    ?assertEqual([<<16#81, 6, 0, 16#22, ?INTERFACE, 0, Length:16/little>>,
                  <<16#21, 16#0b, 1, 0, ?INTERFACE, 0, 0, 0>>,
                  <<16#21, 16#0a, 0, 0, ?INTERFACE, 0, 0, 0>>], Setups),
    ?assertEqual([8, 8, 8, 8], [L || {_, _, _, L} <- Posted]),
    stop(P).

%% Typing arrives as key edges in order, a shifted key with its modifier, over more
%% reports than transfers posted, so each is posted again.
typing_reaches_the_reader_test() ->
    P = places(),
    F = keyboard(P),
    Reports = [keys(0, [4]), keys(0, []), keys(2, [5]), keys(0, [5]), keys(0, []), keys(0, [4]), keys(0, [])],
    [report(F, R) || R <- Reports],
    ?assertEqual([{key, down, ?KEY_A}, {key, up, ?KEY_A},
                  {key, down, ?SHIFT}, {key, down, ?KEY_B}, {key, up, ?SHIFT}, {key, up, ?KEY_B},
                  {key, down, ?KEY_A}, {key, up, ?KEY_A}],
                 records(P, 0, 8)),
    stop(P).

%% A keyboard removed with a key held ends, and its number's file carries release.
a_keyboard_removed_with_a_key_held_releases_it_test() ->
    P = places(),
    F = keyboard(P),
    report(F, keys(0, [4])),
    ?assertEqual([{key, down, ?KEY_A}], records(P, 0, 1)),
    detach(F),
    ?assertEqual({shutdown, {transfer, gone}}, ended(F)),
    ?assertEqual([release], records(P, 0, 1)),
    stop(P).

%% A function stopped mid-typing, as a controller's restart stops it, releases every key;
%% the next instance takes the same number and its keys follow the release.
a_restart_mid_typing_releases_and_typing_resumes_test() ->
    P = places(),
    F = keyboard(P),
    report(F, keys(0, [4, 5])),
    ?assertEqual([{key, down, ?KEY_A}, {key, down, ?KEY_B}], records(P, 0, 2)),
    exit(maps:get(pid, F), shutdown),
    shutdown = ended(F),
    Next = keyboard(P),
    report(Next, keys(0, [5])),
    ?assertEqual([release, {key, down, ?KEY_B}], records(P, 0, 2)),
    stop(P).

%% A boot keyboard whose descriptor the parser refuses is set to the boot protocol and
%% types through the boot layout.
a_refused_descriptor_types_in_the_boot_protocol_test() ->
    P = places(),
    F = function(P, 1, 1, ?REFUSED),
    wait_posted(F, 4),
    #{setups := [_Get, SetProtocol, _SetIdle]} = ask(F, state),
    ?assertEqual(<<16#21, 16#0b, 0, 0, ?INTERFACE, 0, 0, 0>>, SetProtocol),
    report(F, keys(0, [4])),
    ?assertEqual([{key, down, ?KEY_A}], records(P, 0, 1)),
    stop(P).

%% An interface it cannot drive ends the function unusable, with the reason, and its number is
%% released and free again.
an_interface_with_no_usable_report_ends_test() ->
    P = places(),
    F = function(P, 0, 0, ?NO_ROLE),
    ?assertEqual({shutdown, {unusable, no_usable_report}}, ended(F)),
    ?assertEqual([release], records(P, 0, 1)),
    _ = keyboard(P),
    stop(P).

%% A report descriptor whose read times out or meets a controller error may read
%% next time, so on an interface with no boot fallback that end counts toward the
%% restart bound; a read the device refuses with a stall is final.
a_failed_report_descriptor_read_counts_and_a_refused_one_is_final_test() ->
    P = places(),
    Timeout = function(P, 0, 0, {failing, timeout, byte_size(?KEYBOARD)}),
    ?assertEqual({shutdown, {report_descriptor, timeout}}, ended(Timeout)),
    Controller = function(P, 0, 0, {failing, {controller, 4}, byte_size(?KEYBOARD)}),
    ?assertEqual({shutdown, {report_descriptor, {controller, 4}}}, ended(Controller)),
    Stall = function(P, 0, 0, {failing, stall, byte_size(?KEYBOARD)}),
    ?assertEqual({shutdown, {unusable, {report_descriptor, stall}}}, ended(Stall)),
    stop(P).

%% Reports the fold cannot read, short or empty, give nothing; one cut to the transfer's
%% length, as the controller cuts it, all ones, holds the eight modifiers and usage FFh,
%% which maps to no key; and the function goes on typing.
malformed_reports_are_dropped_test() ->
    P = places(),
    F = keyboard(P),
    report(F, <<4>>),
    report(F, <<>>),
    report(F, binary:copy(<<16#ff>>, 1024)),
    report(F, keys(0, [5])),
    Records = records_until(P, 0, {key, down, ?KEY_B}),
    Modifiers = [?ERX_EVDEV_KEY_LEFTCTRL, ?SHIFT, ?ERX_EVDEV_KEY_LEFTALT, ?ERX_EVDEV_KEY_LEFTMETA,
                 ?ERX_EVDEV_KEY_RIGHTCTRL, ?ERX_EVDEV_KEY_RIGHTSHIFT, ?ERX_EVDEV_KEY_RIGHTALT,
                 ?ERX_EVDEV_KEY_RIGHTMETA],
    ?assertEqual([], [{key, down, Code} || Code <- Modifiers] -- Records),
    ?assert(is_process_alive(maps:get(pid, F))),
    stop(P).

%% A report storm with no reader fills the stream and then stops the function: no
%% transfer stays posted and the device keeps every report past one read's worth and
%% the four transfers, one report a record here; reading drains them all.
a_report_storm_waits_for_the_reader_test() ->
    P = places(),
    F = keyboard(P),
    Pairs = ?ERX_P9_IO_MAX div ?RECORD,
    [report(F, R) || _ <- lists:seq(1, Pairs), R <- [keys(0, [4]), keys(0, [])]],
    wait(fun() -> #{posted := Posted, waiting := Waiting} = ask(F, state),
                  Posted =:= [] andalso length(Waiting) =:= Pairs - 4 end, 30000),
    Records = records(P, 0, 2 * Pairs),
    ?assertEqual(lists:append(lists:duplicate(Pairs, [{key, down, ?KEY_A}, {key, up, ?KEY_A}])), Records),
    wait_posted(F, 4),
    stop(P).

%% With every number taken, the function is not started, and its start fails as unusable without
%% ending the caller.
a_function_finds_no_input_number_test() ->
    #{places := Places} = P = places(),
    Holders = [spawn(fun() -> receive stop -> ok end end) || _ <- lists:seq(1, ?ERX_USB_INPUT_MAX)],
    [{ok, _, _} = erx_usb_places_sup:occupy_input(Places, H) || H <- Holders],
    Device = spawn(fun() -> device(?KEYBOARD) end),
    Function = #{driver => erx_usb_hid, interface => 0, alternate => 0,
                 setting => setting(1, 1, ?KEYBOARD), pipes => []},
    ?assertEqual({error, {shutdown, {unusable, no_input_number}}},
                 erx_usb_hid:start_link(#{function => Function, control => {stand_in_pipe, Device, 0},
                                          pipes => [{stand_in_pipe, Device, 16#81}], places => Places})),
    [H ! stop || H <- Holders],
    exit(Device, kill),
    stop(P).

stop(#{places := Places}) ->
    exit(Places, shutdown).
