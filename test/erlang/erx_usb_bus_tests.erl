%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The bus process, its supervision tree and the hub function (docs/design-usb.md,
%% "The process tree", "Ports, hubs and devices: the bus core", "Hubs"), run whole
%% under erx_usb's top supervisor against erx_usb_fake_xhci, a controller that speaks the design's
%% controller-to-bus protocol over a world each case changes, with a stand-in HID
%% function the case can end at will. Each case reads what the controller was asked,
%% in order, from the fake's log, and which function instances run from the stand-in's
%% and the function supervisor's reports.

-module(erx_usb_bus_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(FAKE, erx_usb_fake_xhci_under_test).
%% How long a case waits for each thing it expects before it fails. Only a failing case
%% waits it out, so it is long enough for a host loaded many times over; the runner
%% scales EUnit's per-case timeout above it. A case that chains waits may still time out
%% instead of failing on its own assertion, which the runner counts as a failure too.
-define(WAIT_MS, 10000).

%% ---------------------------------------------------------------------------
%% Cases
%% ---------------------------------------------------------------------------

a_keyboard_on_a_root_port_runs_its_function_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Ref = configured([1]),
        {hid_started, _Pid, Args} = next_hid(),
        ?assertMatch(#{device := Ref, run := 1, function := #{interface := 0}}, Args),
        ?assertEqual([{Ref, 16#81}], [erx_usb_pipe:endpoint(P) || P <- maps:get(pipes, Args)]),
        ?assertEqual({Ref, 0}, erx_usb_pipe:endpoint(maps:get(control, Args))),
        ?assert(is_pid(maps:get(places, Args)))
    end).

%% A function that finds its interface unusable ends for good, as a FreeBSD probe's
%% ENXIO does: it is not started again, its pipes are not reset, and the device's
%% other function keeps running.
an_unusable_interface_leaves_the_others_running_test() ->
    persistent_term:put(erx_usb_hid_stand_in, {unusable, 1}),
    try
        with_bus(#{[1] => composite}, fun() ->
            Ref = configured([1]),
            {hid_started, Running, #{function := #{interface := 0}}} = next_hid(),
            Gone = receive {hid_unusable, Pid, #{function := #{interface := 1}}} -> Pid
                   after ?WAIT_MS -> error(no_unusable_start)
                   end,
            settled(),
            ?assertNot(is_process_alive(Gone)),
            ?assert(is_process_alive(Running)),
            ?assertEqual(0, count({reset_pipe, Ref, 1, 16#82})),
            ?assertEqual([], [D || D = {detach, _} <- log()]),
            ?assertEqual(none, next_hid(200)),
            ?assertEqual(none, receive Again = {hid_unusable, _, _} -> Again after 0 -> none end)
        end)
    after
        persistent_term:erase(erx_usb_hid_stand_in)
    end.

%% A function's end while its device stays resets its pipes and starts it again with
%% the next run number, at most usb_function_restarts_max times in the window; the end
%% past them disables the port and detaches the device.
a_function_ends_and_restarts_within_its_bounds_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Ref = configured([1]),
        Runs = [begin
                    {hid_started, Pid, #{run := Run}} = next_hid(),
                    exit(Pid, kill),
                    Run
                end || _ <- lists:seq(0, ?ERX_USB_FUNCTION_RESTARTS_MAX)],
        ?assertEqual(lists:seq(1, ?ERX_USB_FUNCTION_RESTARTS_MAX + 1), Runs),
        wait(fun() -> lists:member({detach, Ref}, log()) end),
        ?assertEqual(?ERX_USB_FUNCTION_RESTARTS_MAX, count({reset_pipe, Ref, 0, 16#81})),
        ?assert(lists:member({port, root, 1, disable}, log())),
        ?assertEqual(none, next_hid(200))
    end).

%% A start that fails is an end too, so the function is retried within the same
%% bounds and then given up, rather than left counted as running with nothing behind.
a_function_whose_start_fails_ends_test() ->
    persistent_term:put(erx_usb_hid_stand_in, fail),
    try
        with_bus(#{[1] => keyboard}, fun() ->
            Ref = configured([1]),
            wait(fun() -> lists:member({detach, Ref}, log()) end),
            ?assertEqual(?ERX_USB_FUNCTION_RESTARTS_MAX, count({reset_pipe, Ref, 0, 16#81})),
            ?assert(lists:member({port, root, 1, disable}, log()))
        end)
    after
        persistent_term:erase(erx_usb_hid_stand_in)
    end.

%% A start that fails as unusable, as a HID function's with no free input number, is
%% final too: its pipes are not reset, it is not started again, and the device's other
%% function keeps running.
an_unusable_start_is_final_test() ->
    persistent_term:put(erx_usb_hid_stand_in, {unusable_start, 1}),
    try
        with_bus(#{[1] => composite}, fun() ->
            Ref = configured([1]),
            {hid_started, Running, #{function := #{interface := 0}}} = next_hid(),
            settled(),
            ?assert(is_process_alive(Running)),
            ?assertEqual(0, count({reset_pipe, Ref, 1, 16#82})),
            ?assertEqual([], [D || D = {detach, _} <- log()]),
            ?assertEqual(1, refusals(0))
        end)
    after
        persistent_term:erase(erx_usb_hid_stand_in)
    end.

%% A hub's ports are powered and read with the hub class's requests on its EP0; a
%% device plugged in behind it is reported on the hub's status pipe, its connection
%% change cleared, and it enumerates through the address-zero turn with its route.
a_hub_with_a_child_enumerates_it_test() ->
    with_bus(#{[1] => {hub, 2}}, fun() ->
        Hub = configured([1]),
        settled(),
        ok = erx_usb_fake_xhci:plug(?FAKE, [1, 2], keyboard),
        Keyboard = configured([1, 2]),
        Log = log(),
        ?assert(lists:member({port, 1, power_on}, hub_ops(Hub, Log))),
        ?assert(lists:member({port, 2, power_on}, hub_ops(Hub, Log))),
        ?assert(lists:member({port, 2, reset}, hub_ops(Hub, Log))),
        ?assertMatch([#{root_port := 1, route := [2]}], [P || {address, R, _, P} <- Log, R =:= Keyboard]),
        ?assertMatch([_], hub_functions()),
        {hid_started, _Pid, #{device := Keyboard}} = next_hid()
    end).

%% A mass-storage stick behind a hub, beside a keyboard, as on the Raspberry Pi 4's
%% VL805: its function serves its medium without ending, so the bus resets none of its
%% pipes, and the keyboard runs on.
a_stick_behind_a_hub_is_served_beside_a_keyboard_test() ->
    with_bus(#{[1] => {hub, 4}}, fun() ->
        configured([1]),
        settled(),
        ok = erx_usb_fake_xhci:plug(?FAKE, [1, 1], keyboard),
        Keyboard = configured([1, 1]),
        {hid_started, Running, #{device := Keyboard}} = next_hid(),
        ok = erx_usb_fake_xhci:plug(?FAKE, [1, 3], stick),
        Stick = configured([1, 3]),
        settled(),
        ?assertEqual(0, count({reset_pipe, Stick, 0, 16#81})),
        ?assertEqual([], [D || D = {detach, _} <- log()]),
        ?assert(is_process_alive(Running)),
        ?assertMatch({ok, #{transport := usb_bot}}, erx_blk:info(transport()))
    end).

%% The fake answers by name as soon as its start returns, as a case reaches it straight
%% after the controllers start: checked straight after each of many starts.
the_fake_answers_by_name_once_started_test() ->
    [begin
         {ok, Fake} = erx_usb_fake_xhci:start_link({?FAKE, 1, #{}}),
         ?assertEqual([], erx_usb_fake_xhci:log(?FAKE)),
         unlink(Fake),
         Monitor = monitor(process, Fake),
         exit(Fake, kill),
         receive {'DOWN', Monitor, process, Fake, _} -> ok end
     end || _ <- lists:seq(1, 50)],
    ok.

%% A stick on a root port serves its medium: reset recovery, Get Max LUN, INQUIRY, TEST
%% UNIT READY, READ CAPACITY and the readiness SYNCHRONIZE CACHE make a block transport
%% whose reads and writes reach the medium, within the transport contract's bounds.
a_stick_serves_its_medium_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        Transport = transport(),
        ?assertMatch({ok, #{transport := usb_bot, capacity := 128, max_sectors := 64, flush := true,
                            detail := #{vendor := <<"erXos   ">>, product := <<"Model stick     ">>}}},
                     erx_blk:info(Transport)),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk:read(Transport, 0, 1)),
        Data = << <<(I rem 251)>> || I <- lists:seq(1, 1024) >>,
        ?assertEqual(ok, erx_blk:write(Transport, 126, Data)),
        ?assertEqual({ok, Data}, erx_blk:read(Transport, 126, 2)),
        ?assertEqual({error, out_of_range}, erx_blk:read(Transport, 127, 2)),
        ?assertEqual({error, bad_count}, erx_blk:read(Transport, 0, 65)),
        ?assertEqual({error, bad_count}, erx_blk:write(Transport, 0, <<1, 2, 3>>)),
        ?assertEqual(ok, erx_blk:flush(Transport))
    end).

%% A stick the quirk table names gets its quirks' behaviour (design-usb.md, "Device
%% quirks"): 04cf:8818, FreeBSD's ignore_residue and no_sync_cache, reports a wrong residue
%% in every CSW, which would refuse each command, yet its medium is served, its residue
%% taken from what each data phase moved, with no reset beyond the start's, and it cannot
%% flush, no SYNCHRONIZE CACHE sent.
a_quirked_stick_gets_its_quirks_behaviour_test() ->
    with_bus(#{[1] => {residue_liar, 16#04cf, 16#8818}}, fun() ->
        configured([1]),
        Transport = transport(),
        ?assertMatch({ok, #{capacity := 128, flush := false}}, erx_blk:info(Transport)),
        Data = << <<(I rem 251)>> || I <- lists:seq(1, 1024) >>,
        ?assertEqual(ok, erx_blk:write(Transport, 2, Data)),
        ?assertEqual({ok, Data}, erx_blk:read(Transport, 2, 2)),
        ?assertEqual({error, no_flush}, erx_blk:flush(Transport)),
        ?assertEqual(1, class_resets())
    end).

%% A served medium is logged when it comes up and when it ends, as numbers and names: a
%% transport killed ends its medium with the reason's name.
a_medium_is_logged_as_ready_and_as_ended_test() ->
    with_bus(#{[1] => stick}, fun() ->
        {ok, Lines} = erx_pcie_log_capture:logged(fun() ->
            configured([1]),
            exit(transport(), kill),
            wait(fun() -> {messages, Queued} = process_info(self(), messages),
                          lists:member({logged, "erx_usb_bot: medium LUN 0 ended: killed"}, Queued)
                 end),
            ok
        end),
        ?assertEqual(["erx_usb_bot: medium LUN 0 ready: 128 blocks of 512 bytes as disk0",
                      "erx_usb_bot: medium LUN 0 ended: killed"], Lines)
    end).

%% A data phase that stalls is cleared, its CSW read, and its failure explained by the
%% REQUEST SENSE the same operation sends; MEDIUM ERROR sends the read again, which
%% succeeds, and the medium stays.
a_stalled_data_phase_is_cleared_and_explained_test() ->
    with_bus(#{[1] => stick}, fun() ->
        Ref = configured([1]),
        Transport = transport(),
        Cleared = pipe_resets(Ref, 16#81),
        ok = erx_usb_fake_xhci:stick_fault(?FAKE, [1], {data_in, {error, stall}}),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk:read(Transport, 4, 1)),
        ?assertEqual(Cleared + 1, pipe_resets(Ref, 16#81)),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk:read(Transport, 4, 1))
    end).

%% A CSW that is short, or signed wrongly, is refused: reset recovery readies the device,
%% the read is sent again and succeeds, and the function and its medium run on.
a_short_or_malformed_csw_is_refused_with_a_reset_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        [Function] = functions(erx_usb_bot),
        Transport = transport(),
        Resets = class_resets(),
        ok = erx_usb_fake_xhci:stick_fault(?FAKE, [1], {csw, {wrong_once, fun({ok, Csw}) -> {ok, binary_part(Csw, 0, 12)} end}}),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk:read(Transport, 0, 1)),
        ok = erx_usb_fake_xhci:stick_fault(?FAKE, [1], {csw, {wrong_once, fun({ok, <<_:32, Rest/binary>>}) -> {ok, <<0:32, Rest/binary>>} end}}),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk:read(Transport, 0, 1)),
        ?assertEqual(Resets + 2, class_resets()),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk:read(Transport, 0, 1)),
        ?assertEqual([Function], functions(erx_usb_bot)),
        ?assertEqual([Transport], transports())
    end).

%% A stick that only a port reset revives (docs/design-usb.md, "Recovery", rung 3, and
%% "Reattach"): every bulk transfer stalls whatever its class reset and its clears do, so
%% its function ends asking for a port reset; the bus resets its port, retiring the
%% stick's reference, the stick comes back the same under a fresh one, and the function,
%% started again on it, serves its medium under a new transport, which reads what the
%% old one wrote.
a_stick_only_a_port_reset_revives_is_reattached_test() ->
    with_bus(#{[1] => stick}, fun() ->
        Ref = configured([1]),
        Transport = transport(),
        Data = binary:copy(<<7>>, 512),
        ok = erx_blk:write(Transport, 3, Data),
        Resets = count({port, root, 1, reset}),
        ok = erx_usb_fake_xhci:wedge_stick(?FAKE, [1]),
        ?assertNotMatch({ok, _}, read_or_exit(Transport)),
        wait(fun() -> count({port, root, 1, reset}) =:= Resets + 1 end),
        wait(fun() -> [T || T <- transports(), T =/= Transport] =/= [] end),
        [New] = transports(),
        ?assertEqual({ok, Data}, erx_blk:read(New, 3, 1)),
        [Ref, Fresh] = references([1], log()),
        ?assert(Fresh > Ref),
        ?assert(lists:member({detach, Ref}, log())),
        ?assertEqual(Resets + 1, count({port, root, 1, reset}))
    end).

%% A device that answers its port's reset as another, with no connection change, is a
%% new device: the reference the stick had is detached, and the keyboard now on the port
%% is enumerated under a fresh one and its function starts as a first instance, so it
%% takes nothing the stick held.
a_device_back_as_another_after_its_port_reset_is_new_test() ->
    with_bus(#{[1] => stick}, fun() ->
        Old = configured([1]),
        Transport = transport(),
        ok = erx_usb_fake_xhci:swap_on_reset(?FAKE, [1], keyboard),
        ok = erx_usb_fake_xhci:wedge_stick(?FAKE, [1]),
        _ = read_or_exit(Transport),
        wait(fun() -> length(lists:usort(references([1], log()))) =:= 2 end),
        [Old, New] = references([1], log()),
        ?assertNotEqual(Old, New),
        {hid_started, _, #{device := New, run := 1}} = next_hid(),
        ?assert(lists:member({detach, Old}, log())),
        ?assertEqual([], transports())
    end).

%% A stick unplugged while a read's data phase is posted: the read fails, never answering
%% data, and the function and its medium's transport end; the bus runs on.
a_stick_unplugged_mid_transfer_ends_its_function_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        [Function] = functions(erx_usb_bot),
        Transport = transport(),
        ok = erx_usb_fake_xhci:stick_fault(?FAKE, [1], {data_in, silent}),
        Self = self(),
        spawn(fun() -> Self ! {read, try erx_blk:read(Transport, 0, 1) catch exit:Reason -> {exit, Reason} end} end),
        wait(fun() -> lists:any(fun({bulk_in, _, _, 512}) -> true; (_) -> false end, log()) end),
        ok = erx_usb_fake_xhci:unplug(?FAKE, [1]),
        receive {read, Result} -> ?assertNotMatch({ok, _}, Result)
        after ?WAIT_MS -> error(no_read_answer)
        end,
        wait(fun() -> not is_process_alive(Function) andalso not is_process_alive(Transport) end),
        ?assert(is_process_alive(erx_usb_fake_xhci:bus(?FAKE)))
    end).

%% A card reader's transport that crashes ends only its unit's medium: the function and
%% the other unit's transport run on, and the unit's readiness sequence finds its medium
%% again, at the next poll, under a new transport that reads what the old one wrote.
a_transport_crash_ends_only_its_medium_test() ->
    with_bus(#{[1] => {stick, 2}}, fun() ->
        configured([1]),
        [Function] = functions(erx_usb_bot),
        wait(fun() -> length(transports()) =:= 2 end),
        [Crashing, Serving] = transports(),
        Written = binary:copy(<<16#a5>>, 512),
        Other = binary:copy(<<16#5a>>, 512),
        ok = erx_blk:write(Crashing, 3, Written),
        ok = erx_blk:write(Serving, 3, Other),
        exit(Crashing, kill),
        ?assertEqual({ok, Other}, erx_blk:read(Serving, 3, 1)),
        ?assert(is_process_alive(Function)),
        wait_until(fun() -> length(transports()) =:= 2 end,
                   erlang:monotonic_time(millisecond) + ?ERX_USB_BOT_POLL_MS + ?WAIT_MS),
        [Found] = transports() -- [Serving],
        ?assertEqual({ok, Written}, erx_blk:read(Found, 3, 1)),
        ?assertEqual({ok, Other}, erx_blk:read(Serving, 3, 1)),
        ?assertEqual([Function], functions(erx_usb_bot))
    end).

%% A ready medium takes the lowest free drive of the domain's records (the runner names
%% drives 0 and 1), and that drive's grant alone hands out the medium's window: the
%% transport's own, over the whole medium.
a_medium_takes_the_lowest_free_drive_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        Transport = transport(),
        [{0, Grant0}, {1, Grant1}] = drives(),
        {ok, Window} = erx_blk_drive:window(Grant0),
        ?assertEqual([Transport], [parent(Window)]),
        ?assertEqual({ok, binary:copy(<<0>>, 512)}, erx_blk_window:read(Window, 127, 1)),
        ?assertEqual({error, no_medium}, erx_blk_drive:window(Grant1))
    end).

%% The function's own end_medium clause (erx_blk_drive's ask again): the grant asked a
%% second time for the window it handed out sends the function the medium's end, the
%% old transport and window stop, the held ask is answered no_medium, and the unit's
%% readiness sequence makes the next medium under a new transport, which takes drive 0
%% again, lowest first, and whose window the grant hands out.
a_grant_asked_again_ends_its_medium_through_the_function_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        Old = transport(),
        [{0, Grant} | _] = drives(),
        {ok, OldWindow} = erx_blk_drive:window(Grant),
        Watch = monitor(process, Old),
        Ask = gen_server:send_request(Grant, window),
        receive {'DOWN', Watch, process, Old, _} -> ok
        after ?WAIT_MS -> error(old_transport_lives)
        end,
        ?assertNot(is_process_alive(OldWindow)),
        ?assertEqual({reply, {error, no_medium}}, gen_server:receive_response(Ask, ?WAIT_MS)),
        wait_until(fun() -> transports() =/= [] end,
                   erlang:monotonic_time(millisecond) + ?ERX_USB_BOT_POLL_MS + ?WAIT_MS),
        [New] = transports(),
        ?assertNotEqual(Old, New),
        {ok, NewWindow} = erx_blk_drive:window(Grant),
        ?assertEqual(New, parent(NewWindow))
    end).

%% A unit whose medium becomes ready when every drive is taken is not served: a card
%% reader of three units on a domain of two drives serves two media, and its third shows
%% no drive, while the function runs on.
a_medium_finding_every_drive_taken_shows_no_drive_test() ->
    with_bus(#{[1] => {stick, 3}}, fun() ->
        {ok, Lines} = erx_pcie_log_capture:logged(fun() ->
            configured([1]),
            wait(fun() -> {messages, Queued} = process_info(self(), messages),
                          length([L || {logged, L} <- Queued, lists:suffix("ready: no drive", L)]) =:= 1
                 end),
            ok
        end),
        ?assertMatch([_, _], transports()),
        ?assertMatch([_], [L || L <- Lines, lists:suffix("ready: no drive", L)]),
        ?assertMatch([_], functions(erx_usb_bot))
    end).

%% The function's crash report shows none of the unit's INQUIRY text, nor the write data
%% a message, the reason or the log carries (docs/design-log.md, "Reports carry no term").
a_function_status_shows_no_medium_bytes_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        _ = transport(),
        [Function] = functions(erx_usb_bot),
        refute_shown(erx_usb_bot, Function, fun(Data) -> {request, make_ref(), {write, 0, 3, Data}} end,
                     {request, write})
    end).

%% The transport's crash report shows none of the unit's INQUIRY text, nor the write data
%% a message, the reason or the log carries.
a_transport_status_shows_no_medium_bytes_test() ->
    with_bus(#{[1] => stick}, fun() ->
        configured([1]),
        refute_shown(erx_blk_usb, transport(), fun(Data) -> {write, 3, Data} end, write)
    end).

%% Module's format_status/1 of Pid's live state, with Write of the marker as the last
%% message, in the reason and in the log, shows the message as Kind and neither the
%% marker nor the stick's INQUIRY text.
refute_shown(Module, Pid, Write, Kind) ->
    Marker = <<"status-marker-0123456789abcdef!">>,
    Data = binary:copy(<<Marker/binary, $.>>, 16),
    Status = #{state => sys:get_state(Pid), message => Write(Data), reason => {{badmatch, Data}, []},
               log => [{in, Write(Data)}]},
    Formatted = Module:format_status(Status),
    ?assertMatch(#{message := Kind, reason := badmatch, log := []}, Formatted),
    ?assertEqual(nomatch, binary:match(term_to_binary(Formatted), [Marker, <<"erXos">>, <<"Model stick">>])).

%% A hub's removal detaches the devices below it first and ends every function of each.
a_hub_removed_detaches_below_it_first_test() ->
    with_bus(#{[1] => {hub, 2}, [1, 2] => keyboard}, fun() ->
        Hub = configured([1]),
        Keyboard = configured([1, 2]),
        {hid_started, HidPid, _} = next_hid(),
        [HubPid] = hub_functions(),
        ok = erx_usb_fake_xhci:unplug(?FAKE, [1]),
        wait(fun() -> lists:member({detach, Hub}, log()) end),
        ?assertEqual([{detach, Keyboard}, {detach, Hub}], [D || D = {detach, _} <- log()]),
        ?assertNot(is_process_alive(HidPid)),
        ?assertNot(is_process_alive(HubPid)),
        ?assertEqual(none, next_hid(200))
    end).

%% A device replaced before its port is read is detached and the new one enumerated
%% under a new reference, never under the old one's.
a_device_replaced_unseen_gets_a_new_reference_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Old = configured([1]),
        {hid_started, _, #{device := Old}} = next_hid(),
        ok = erx_usb_fake_xhci:replace(?FAKE, [1], keyboard),
        wait(fun() -> length(references([1], log())) =:= 2 end),
        [Old, New] = references([1], log()),
        wait(fun() -> lists:member(New, configured_references(log())) end),
        ?assert(lists:member({detach, Old}, log())),
        {hid_started, _, #{device := New, run := 1}} = next_hid()
    end).

%% A hub function that fails is restarted after its pipe's reset; the new instance's
%% first report reads every port again, and the device behind the hub stays.
a_hub_function_restart_reads_every_port_again_test() ->
    with_bus(#{[1] => {hub, 2}, [1, 2] => keyboard}, fun() ->
        Hub = configured([1]),
        _Keyboard = configured([1, 2]),
        {hid_started, HidPid, _} = next_hid(),
        [Old] = hub_functions(),
        settled(),
        Reads = count_hub_op(Hub, {port, 1, get_status}),
        ok = erx_usb_fake_xhci:fail_status_transfer(?FAKE, Hub),
        wait(fun() -> hub_functions() =/= [] andalso hub_functions() =/= [Old] end),
        wait(fun() -> count_hub_op(Hub, {port, 1, get_status}) > Reads end),
        ?assertEqual(1, count({reset_pipe, Hub, 0, 16#81})),
        ?assert(is_process_alive(HidPid)),
        ?assertEqual([], [D || D = {detach, _} <- log()])
    end).

%% A report from a hub function instance that has ended is dropped: it names no
%% instance the bus process holds, so it reads no port and is answered to no one.
a_report_from_an_ended_hub_instance_is_dropped_test() ->
    with_bus(#{[1] => {hub, 2}}, fun() ->
        Hub = configured([1]),
        [Old] = hub_functions(),
        ok = erx_usb_fake_xhci:fail_status_transfer(?FAKE, Hub),
        wait(fun() -> hub_functions() =/= [] andalso hub_functions() =/= [Old] end),
        settled(),
        Reads = count_hub_op(Hub, {port, 1, get_status}),
        erx_usb_fake_xhci:bus(?FAKE) ! {changed, Hub, [1], Old},
        settled(),
        ?assertEqual(Reads, count_hub_op(Hub, {port, 1, get_status}))
    end).

%% A controller that fails at every start is restarted with its bus group at most
%% usb_bus_restarts_max times, then given up, while the places keep running.
a_controller_failing_at_every_reset_is_given_up_test() ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    {ok, Sup} = erx_usb:start_link(),
    try
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 1, fails_at_start}]}]),
        {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(Sup)),
        wait(fun() -> element(2, lists:keyfind({controller, 0}, 1, supervisor:which_children(Sup))) =:=
                          undefined end),
        Starts = fake_starts(0),
        ?assertEqual(?ERX_USB_BUS_RESTARTS_MAX + 1, Starts),
        ?assertMatch({{controller, 0}, undefined, _, _}, lists:keyfind({controller, 0}, 1, supervisor:which_children(Sup))),
        ?assertMatch({places, Places, _, _}, lists:keyfind(places, 1, supervisor:which_children(Sup))),
        ?assert(is_process_alive(Places))
    after
        stop(Sup)
    end.

%% A controller's failure restarts its bus group, which enumerates every port again
%% and starts every function afresh, at run 1; the places are untouched. A reference
%% names a device within one bus process's life, so the new bus may reuse old ones.
a_controller_failure_restarts_the_bus_not_the_places_test() ->
    with_bus(#{[1] => keyboard}, fun() ->
        Sup = whereis(erx_usb),
        {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(Sup)),
        _ = configured([1]),
        {hid_started, HidPid, _} = next_hid(),
        exit(whereis(?FAKE), host_controller_error),
        {hid_started, NewPid, #{run := 1}} = next_hid(),
        ?assertNotEqual(HidPid, NewPid),
        ?assertNot(is_process_alive(HidPid)),
        ?assertMatch({places, Places, _, _}, lists:keyfind(places, 1, supervisor:which_children(Sup)))
    end).

%% The application's top supervisor runs the places, and one bus group for each
%% controller start, here one fake's, whose keyboard's function starts below it; and a
%% bus group that ends abnormally ends the top supervisor, intensity 0, and so the
%% application and the domain (docs/design-usb.md, "Failure handling").
the_application_runs_one_bus_group_per_controller_test() ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    {ok, Top} = erx_usb:start_link(),
    try
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 2, #{[1] => keyboard}}]}]),
        [places, {controller, 0}] = lists:sort([Id || {Id, _, supervisor, _} <- supervisor:which_children(Top)]),
        {{controller, 0}, Group, _, _} = lists:keyfind({controller, 0}, 1, supervisor:which_children(Top)),
        _ = configured([1]),
        ?assertMatch({hid_started, _, #{run := 1}}, next_hid()),
        exit(Group, kill),
        receive {'EXIT', Top, Reason} -> ?assertEqual(shutdown, Reason)
        after ?WAIT_MS -> error(top_supervisor_lives)
        end
    after
        true = unregister(erx_usb_bus_tests),
        flush()
    end.

%% The places start with the application, from the boot script, and their mints name
%% themselves usb_input's and drive's mints before init's ready report; the row's
%% -eval starts the controllers after it, when erx_facet:provide/2 answers {error, reported}.
the_mint_provides_before_the_report_and_the_controllers_start_after_test() ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    persistent_term:erase({erx, provides}),
    {ok, Top} = erx_usb:start_link(),
    try
        {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(Top)),
        Children = supervisor:which_children(Places),
        [Mint] = [Pid || {mint, Pid, _, _} <- Children],
        [DriveMint] = [Pid || {drive_mint, Pid, _, _} <- Children],
        ?assertEqual(#{usb_input => Mint, drive => DriveMint}, persistent_term:get({erx, provides})),
        persistent_term:put({erx, provides}, reported),
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 2, #{[1] => keyboard}}]}]),
        _ = configured([1]),
        ?assertMatch({hid_started, _, #{run := 1}}, next_hid())
    after
        persistent_term:erase({erx, provides}),
        stop(Top)
    end.

%% ---------------------------------------------------------------------------
%% The fixture
%% ---------------------------------------------------------------------------

%% Runs Case against a bus of two root ports holding World, under erx_usb's top
%% supervisor.
with_bus(World, Case) ->
    register(erx_usb_bus_tests, self()),
    process_flag(trap_exit, true),
    {ok, Sup} = erx_usb:start_link(),
    try
        ok = erx_usb:start_controllers([{erx_usb_fake_xhci, start_link, [{?FAKE, 2, World}]}]),
        Case()
    after
        stop(Sup)
    end.

stop(Sup) ->
    unlink(Sup),
    Monitor = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Monitor, process, Sup, _} -> ok end,
    true = unregister(erx_usb_bus_tests),
    flush().

flush() ->
    receive _ -> flush() after 0 -> ok end.

%% The fake's starts, each told before it failed, so all are in once the group is given up.
%% On one node a message is in the receiver's mailbox once its sender has sent it, so
%% `after 0` sees every start told before the event the case waited for; a lower count
%% fails the case, never passes it wrongly.
fake_starts(Count) ->
    receive {fake_started, _} -> fake_starts(Count + 1) after 0 -> Count end.

%% The stand-in's refused starts, counted from its reports.
refusals(Count) ->
    receive {hid_refused, _} -> refusals(Count + 1) after 0 -> Count end.

next_hid() ->
    case next_hid(?WAIT_MS) of
        none -> error(no_hid_start);
        Started -> Started
    end.

next_hid(Timeout) ->
    receive Started = {hid_started, _, _} -> Started after Timeout -> none end.

%% The fake's log once it has stood still for a moment, so every answer in flight
%% has been taken.
settled() -> settled(?WAIT_MS div 100).

settled(0) ->
    error({unsettled, log()});
settled(Tries) ->
    Before = log(),
    timer:sleep(100),
    case log() of
        Before -> ok;
        _Moved -> settled(Tries - 1)
    end.

log() -> erx_usb_fake_xhci:log(?FAKE).

count(Request) -> length([R || R <- log(), R =:= Request]).

%% Hub's port operations, as the bus process tagged its control requests.
hub_ops(Hub, Log) -> [Tag || {control, R, Tag = {port, _, _}, _, _} <- Log, R =:= Hub].

count_hub_op(Hub, {port, N, Op}) -> length([T || T = {port, M, O} <- hub_ops(Hub, log()), M =:= N, O =:= Op]).

%% The references addressed at Place, oldest first.
references([Root | Tiers], Log) ->
    [R || {address, R, _, #{root_port := Rp, route := T}} <- Log, Rp =:= Root, T =:= Tiers].

configured_references(Log) -> [R || {configure_endpoints, R, _, _} <- Log].

%% The reference of the device at Place, once its endpoints are configured.
configured(Place) ->
    wait(fun() ->
             case references(Place, log()) of
                 [] -> false;
                 Refs -> lists:member(lists:last(Refs), configured_references(log()))
             end
         end),
    lists:last(references(Place, log())).

hub_functions() -> functions(erx_usb_hub).

%% The running function instances of driver Module.
functions(Module) ->
    Bus = erx_usb_fake_xhci:bus(?FAKE),
    {dictionary, Dictionary} = process_info(Bus, dictionary),
    {_, Parent} = lists:keyfind('$ancestors', 1, Dictionary),
    [Group | _] = Parent,
    {functions, Functions, _, _} = lists:keyfind(functions, 1, supervisor:which_children(Group)),
    [Pid || {_, Pid, _, [erx_usb_bus_sup]} <- supervisor:which_children(Functions), is_pid(Pid),
            started_by(Module, Pid)].

started_by(Module, Pid) ->
    case proc_lib:initial_call(Pid) of
        {Module, init, _} -> true;
        _ -> false
    end.

%% The block transports of the running mass-storage functions, each started by its own.
transports() ->
    Functions = functions(erx_usb_bot),
    [T || T <- processes(), started_by(erx_blk_usb, T), lists:member(parent(T), Functions)].

parent(Pid) ->
    case process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            {_, [Parent | _]} = lists:keyfind('$ancestors', 1, Dictionary),
            Parent;
        undefined ->
            none
    end.

%% A read of block 0 through a transport that may end under it: its answer, or the exit
%% that ended it.
read_or_exit(Transport) ->
    try erx_blk:read(Transport, 0, 1) catch exit:Reason -> {exit, Reason} end.

%% The one transport, once its medium is ready.
transport() ->
    wait(fun() -> transports() =/= [] end),
    [Transport] = transports(),
    Transport.

%% The domain's drives and their grants, from the places under erx_usb's top supervisor.
drives() ->
    {places, Places, _, _} = lists:keyfind(places, 1, supervisor:which_children(erx_usb)),
    erx_usb_places_sup:drives(Places).

%% How often the function reset its device's pipe at Address, or sent the class reset.
pipe_resets(Ref, Address) ->
    length([P || {reset_pipe, P, _} <- log(), erx_usb_pipe:endpoint(P) =:= {Ref, Address}]).

class_resets() ->
    length([S || {control, _, S = <<16#21, ?ERX_USB_BOT_REQUEST_RESET, _/binary>>, _, _} <- log()]).

wait(Condition) -> wait_until(Condition, erlang:monotonic_time(millisecond) + ?WAIT_MS).

%% The fake's log for a timeout's error, or no_fake when the fake is not registered.
fake_log() ->
    try log() catch error:{no_fake, _} -> no_fake end.

wait_until(Condition, Deadline) ->
    case Condition() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(20), wait_until(Condition, Deadline);
                false -> error({timeout, fake_log()})
            end
    end.

%% A domain given no xHCI function record starts no controller, and says so: a VL805
%% its PCIe report held back or never found is otherwise silent.
a_domain_given_no_xhci_function_says_it_starts_no_controller_test() ->
    ?assertEqual({ok, ["usb: no xhci function record; no controller started"]},
                 erx_pcie_log_capture:logged(fun() -> erx_usb:start_controllers([]) end)).
