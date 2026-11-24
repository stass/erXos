%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the domain service: erx_ident's rule, erx_domain_core's ids,
%% names and lives, and erx_domain_srv over erx_domain_fake_lib.
-module(erx_domain_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The principals a service names where its test needs no particular manifest.
-define(PRINCIPALS, #{system => 1, names => #{1 => <<"system">>}}).

ident(Name) -> erx_ident:new(Name).

ident_test() ->
    [?assertEqual(Name, erx_ident:to_binary(ident(Name))) || Name <- [<<"a">>, <<"web">>, <<"alice_1">>, <<"x_y-z">>]],
    [?assertEqual({error, bad_identifier}, ident(Bad))
     || Bad <- [<<>>, <<"Web">>, <<".a">>, <<"a.b">>, <<"-a">>, <<"a b">>, <<"a@b">>, <<"caf", 195, 169>>,
                binary:copy(<<"a">>, 64), "web", web]],
    ?assertEqual(<<"a">>, erx_ident:to_binary(ident(binary:copy(<<"a">>, 1)))),
    ?assertMatch({erx_ident, _}, ident(binary:copy(<<"a">>, 63))).

%% erx_ident:new/1 agrees with the reference regex of the rule over random
%% byte strings drawn mostly from the alphabet and its edges (fixed seed).
ident_matches_reference_regex_test() ->
    {ok, Re} = re:compile("^[a-z0-9][a-z0-9_-]{0,62}\\z"),
    State0 = rand:seed_s(exsss, {1, 2, 3}),
    {Cases, _} = lists:mapfoldl(fun(_, S) -> ident_case(S) end, State0, lists:seq(1, 4000)),
    [begin
         Expected = re:run(Bin, Re, [{capture, none}]) =:= match,
         Actual = case erx_ident:new(Bin) of {erx_ident, Bin} -> true; {error, bad_identifier} -> false end,
         ?assertEqual({Bin, Expected}, {Bin, Actual})
     end || Bin <- Cases].

ident_case(S0) ->
    {Len, S1} = ident_length(S0),
    {Bytes, S2} = lists:mapfoldl(fun(_, S) -> ident_byte(S) end, S1, lists:seq(1, Len)),
    {list_to_binary(Bytes), S2}.

ident_length(S0) ->
    {Pick, S1} = rand:uniform_s(8, S0),
    case Pick of
        1 -> {63, S1};
        2 -> {64, S1};
        _ -> {Len, S2} = rand:uniform_s(71, S1), {Len - 1, S2}
    end.

%% Mostly valid bytes, with the characters at the rule's edges mixed in.
ident_byte(S0) ->
    {Pick, S1} = rand:uniform_s(20, S0),
    case Pick of
        P when P =< 10 -> pick($a, $z, S1);
        P when P =< 13 -> pick($0, $9, S1);
        14 -> {$_, S1};
        15 -> {$-, S1};
        16 -> {$., S1};
        17 -> pick($A, $Z, S1);
        18 -> {hd("\n"), S1};
        _ -> {B, S2} = rand:uniform_s(256, S1), {B - 1, S2}
    end.

pick(Lo, Hi, S0) ->
    {N, S1} = rand:uniform_s(Hi - Lo + 1, S0),
    {Lo + N - 1, S1}.

admit(Name, Principal, Origin, Core) ->
    {ok, Domain, Next} = erx_domain_core:admit(ident(Name), Principal, Origin, Core),
    {Domain, Next}.

%% Runs a domain through its life to its end, which drops its record.
live(Name, Core0) ->
    {#{id := Id} = Domain, Core1} = admit(Name, 1, request, Core0),
    Core2 = erx_domain_core:running(Id, erx_domain_core:built(Id, #{connection => 7, ctl_slots => 0, reader => 4096}, self(), make_ref(), Core1)),
    {stopped, _, Core3} = erx_domain_core:ended(Id, {stopped, 0}, none, 0, Core2),
    {Domain, Core3}.

%% D1: ids start above the system domain's 4, increase, and are never reused,
%% whether a creation succeeded or was refused.
ids_increase_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    {#{id := 5, node := 'web@erxos'}, Core1} = live(<<"web">>, Core0),
    {#{id := 6}, Core2} = admit(<<"web">>, 1, request, Core1),
    Core3 = erx_domain_core:failed(6, Core2),
    {#{id := 7, node := 'web@erxos'}, _} = admit(<<"web">>, 1, request, Core3).

names_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    {#{id := Id}, Core1} = admit(<<"web">>, 1, request, Core0),
    ?assertEqual({error, name_taken}, erx_domain_core:admit(ident(<<"web">>), 1, request, Core1)),
    Core2 = erx_domain_core:failed(Id, Core1),
    %% The name stays the first principal's for the boot.
    ?assertEqual({error, name_taken}, erx_domain_core:admit(ident(<<"web">>), 2, request, Core2)),
    {_, _} = admit(<<"web">>, 1, request, Core2).

%% Only a session takes a name session naming keeps, root or a session name's form: a
%% request or configured domain is refused it, even once its session ended.
session_reserved_names_test() ->
    Core = erx_domain_core:new(<<"erxos">>),
    [?assertEqual({error, name_taken}, erx_domain_core:admit(ident(Name), 1, request, Core))
     || Name <- [<<"root">>, <<"clock_1">>, <<"clock_100">>, <<"a_b_7">>]],
    {#{id := Id}, Session} = admit(<<"clock_1">>, 3, {session, 0}, Core),
    Ended = erx_domain_core:failed(Id, Session),
    ?assertEqual({error, name_taken}, erx_domain_core:admit(ident(<<"clock_1">>), 3, request, Ended)),
    ?assertEqual({error, name_taken},
                 erx_domain_core:admit(ident(<<"root_2">>), 3, {configured, 0}, Core)),
    [?assertNot(erx_domain_core:session_reserved(Name))
     || Name <- [<<"clock">>, <<"room_a">>, <<"clock_">>, <<"root_a">>]].

names_quota_test() ->
    Core = lists:foldl(fun(N, Acc) ->
                               {#{id := Id}, Next} = admit(integer_to_binary(N), 2, request, Acc),
                               erx_domain_core:failed(Id, Next)
                       end, erx_domain_core:new(<<"erxos">>), lists:seq(1, 64)),
    ?assertEqual({error, quota}, erx_domain_core:admit(ident(<<"one-more">>), 2, request, Core)),
    %% A name bound already is no new atom, and the quota does not hold it back.
    {_, _} = admit(<<"1">>, 2, request, Core),
    %% The manifest's rows are outside the quota.
    {_, _} = admit(<<"one-more">>, 2, {configured, 0}, Core).

life_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    {#{id := Id}, Core1} = admit(<<"a">>, 1, request, Core0),
    ?assertEqual(none, erx_domain_core:ended(Id, {halt, 0}, none, 0, Core1)),
    ?assertError({badmatch, _}, erx_domain_core:running(Id, Core1)),
    Core2 = erx_domain_core:built(Id, #{connection => 0, ctl_slots => 0, reader => 4096}, self(), make_ref(), Core1),
    ?assertMatch({ok, #{id := Id}}, erx_domain_core:find_pid(self(), Core2)),
    {{halt, 3}, _, Core3} = erx_domain_core:ended(Id, {halt, 3}, none, 9, Core2),
    ?assertEqual(none, erx_domain_core:ended(Id, {halt, 0}, none, 0, Core3)),
    ?assertMatch([#{id := Id, info := {halt, 3}, at := 9}], erx_domain_core:deaths(1, Core3)),
    [?assertEqual(Info, erx_domain_core:info(End))
     || {End, Info} <- [{{halt, 1}, {halt, 1}}, {{crash, 5}, crash}, {{fault, 2}, {fault, 2}}, {{stopped, 0}, stopped}]].

%% A fault's end names where it struck, from the fault record of the stop that ended it,
%% which the exit record carries under fault: its pc, cause (the syndrome on AArch64) and
%% address. Only a memory, deleted or alignment fault names an address; any other reads
%% unknown, never a number, and an asynchronous error's thread is only presumed its source.
%% Every other end, and a fault whose record lacks the fault, says no more than the end does.
fault_where_test() ->
    Exit = #{kind => 9, cause => 0, addr => 0, pc => 0, thread => 0, space => 4, status => -1},
    Memory = Exit#{fault => #{kind => 1, cause => 16#2, addr => 16#3e000400, pc => 16#40002cd4c4,
                              thread => 0, space => 6, status => 0}},
    Async = Exit#{fault => #{kind => 7, cause => 16#bf000002, addr => 0, pc => 16#40002cd4c4,
                             thread => 0, space => 6, status => 0}},
    ?assertEqual(" at pc 0x40002cd4c4, cause 0x2, addr 0x3e000400",
                 lists:flatten(erx_domain_core:fault_where({fault, 1}, Memory))),
    ?assertEqual(" presumed at pc 0x40002cd4c4, cause 0xbf000002, addr unknown",
                 lists:flatten(erx_domain_core:fault_where({fault, 7}, Async))),
    Undefined = Exit#{fault => #{kind => 3, cause => 16#2000000, addr => 0, pc => 16#40002cd4c4,
                                 thread => 0, space => 6, status => 0}},
    ?assertEqual(" at pc 0x40002cd4c4, cause 0x2000000, addr unknown",
                 lists:flatten(erx_domain_core:fault_where({fault, 3}, Undefined))),
    ?assertEqual("", lists:flatten(erx_domain_core:fault_where({fault, 7}, Exit))),
    ?assertEqual("", lists:flatten(erx_domain_core:fault_where({fault, 7}, #{}))),
    ?assertEqual("", lists:flatten(erx_domain_core:fault_where({halt, 1}, Async))),
    ?assertEqual("", lists:flatten(erx_domain_core:fault_where({crash, 5}, Async))).

%% A crash's death keeps the slogan the service read, or why it could not;
%% no other end keeps one.
crash_death_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    {#{id := A}, Core1} = admit(<<"a">>, 1, request, Core0),
    {#{id := B}, Core2} = admit(<<"b">>, 1, request, Core1),
    Built = erx_domain_core:built(A, #{connection => 0, ctl_slots => 0, reader => 4096}, self(), make_ref(), Core2),
    Core3 = erx_domain_core:built(B, #{connection => 0, ctl_slots => 0, reader => 4096}, self(), make_ref(), Built),
    {crash, _, Core4} = erx_domain_core:ended(A, {crash, 0}, <<"boom">>, 1, Core3),
    {crash, _, Core5} = erx_domain_core:ended(B, {crash, 0}, {unreadable, ecorrupt}, 2, Core4),
    ?assertMatch([#{id := B, slogan := {unreadable, ecorrupt}}, #{id := A, slogan := <<"boom">>}],
                 erx_domain_core:deaths(1, Core5)).

deaths_kept_test() ->
    Core = lists:foldl(fun(_, Acc) -> element(2, live(<<"d">>, Acc)) end,
                       erx_domain_core:new(<<"erxos">>), lists:seq(1, 20)),
    Deaths = erx_domain_core:deaths(1, Core),
    ?assertEqual(16, length(Deaths)),
    ?assertMatch([#{id := 24} | _], Deaths).

%% The inspect facet's scope for every pair of root (a system-shell principal the
%% manifest names) or another principal, and a development or a release build: only
%% root in a development build has `all`. Root is whichever principal the manifest
%% names, so principal 1 is root only where the manifest says so, and a manifest
%% naming none has no root.
inspect_scope_test() ->
    Cases = [{1, [1], true, all},
             {2, [1], true, {principal, 2}},
             {1, [1], false, {principal, 1}},
             {2, [1], false, {principal, 2}},
             {3, [1, 3], true, all},
             {7, [7], true, all},
             {1, [7], true, {principal, 1}},
             {1, [], true, {principal, 1}}],
    [?assertEqual({Principal, Roots, Development, Scope},
                  {Principal, Roots, Development, erx_domain_core:inspect_scope(Principal, Roots, Development)})
     || {Principal, Roots, Development, Scope} <- Cases].

%% Restarts after ends that were not boot timeouts: at most 2 within 10 s, as OTP
%% counts them, whether the domain had reported ready or was still booting.
restart_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    Two = #{restarts => 2, period_s => 10},
    {yes, Core1} = erx_domain_core:restart(0, Two, ready, 100, Core0),
    {yes, Core2} = erx_domain_core:restart(0, Two, running, 105, Core1),
    {no, Core3} = erx_domain_core:restart(0, Two, ready, 109, Core2),
    {yes, _} = erx_domain_core:restart(0, Two, ready, 110, Core3),
    {no, _} = erx_domain_core:restart(1, Two#{restarts := 0}, ready, 100, Core0).

%% The answers to ends at the times and boots of Ends, in turn, from no restarts.
answers(Intensity, Ends) ->
    {Answers, _} = lists:mapfoldl(fun({At, Boot}, Earlier) ->
                                          erx_domain_core:intensity(Earlier, Intensity, Boot, At)
                                  end, [], Ends),
    Answers.

%% A boot that hangs is stopped only at each boot timeout, so its restarts come a boot
%% timeout apart: however far apart, 5 restarts that timed out in a row are the limit,
%% and the sixth timeout leaves it down.
timeouts_in_a_row_are_the_limit_test() ->
    Five = #{restarts => 5, period_s => 1},
    [?assertEqual({Apart, [yes, yes, yes, yes, yes, no]},
                  {Apart, answers(Five, [{N * Apart, timed_out} || N <- lists:seq(1, 6)])})
     || Apart <- [1, 60, 600, 3600, 86400]].

%% A boot that reached ready ends the run of timeouts: its own end is counted by time
%% alone, and the timeouts after it count from none. An end before ready does not end
%% the run.
a_ready_boot_ends_the_timeouts_in_a_row_test() ->
    Two = #{restarts => 2, period_s => 10},
    ?assertEqual([yes, yes, yes, yes, yes, no],
                 answers(Two, [{100, timed_out}, {200, timed_out}, {300, ready},
                               {400, timed_out}, {500, timed_out}, {600, timed_out}])),
    ?assertEqual([yes, yes, yes, no],
                 answers(Two, [{100, timed_out}, {200, before_ready}, {300, timed_out}, {400, timed_out}])),
    ?assertEqual([yes, yes, no], answers(Two, [{100, ready}, {105, timed_out}, {106, timed_out}])).

%% The domain service is the supervisor's significant child and is never
%% restarted: its end, however it comes, shuts the supervisor down, which ends
%% the application and with it the system domain. A kill, an end with an
%% error and a normal end each do; the service traps exits, so another
%% process's exit/2 with any other reason is a message to it, not its end.
service_end_shuts_the_supervisor_down_test_() ->
    Ends = [{"kill", fun(Service) -> exit(Service, kill) end},
            {"crash", fun(Service) -> sys:terminate(Service, crashed) end},
            {"normal", fun(Service) -> sys:terminate(Service, normal) end}],
    [{Name, fun() -> service_end_shuts_down(End) end} || {Name, End} <- Ends].

%% The supervisor starts the service over erx_domain_lib, whose NIFs stock's
%% emulator does not have: a stand-in loaded here answers register/0 as the
%% module does where no domain library was built, so the service runs with none.
service_end_shuts_down(End) ->
    load_no_library(),
    %% The namespace the machine tree mounts its own grant in.
    persistent_term:erase(erx_ns),
    {ok, Ns} = erx_ns:start_link(erx_ns_prim_stub),
    unlink(Ns),
    {ok, Sup} = erx_domain_sup:start_link(),
    unlink(Sup),
    SupDown = monitor(process, Sup),
    Service = whereis(erx_domain_srv),
    ?assert(is_pid(Service)),
    End(Service),
    Why = receive {'DOWN', SupDown, process, Sup, Reason} -> Reason after 2000 -> still_up end,
    %% A restarted service is registered again. Clean up before asserting.
    Restarted = whereis(erx_domain_srv),
    erx_domain_fake_lib:kill_and_await([Pid || Pid <- [Sup, Restarted, Ns], is_pid(Pid)]),
    persistent_term:erase(erx_ns),
    ?assertEqual({shutdown, undefined}, {Why, Restarted}).

load_no_library() ->
    code:is_loaded(erx_domain_lib) =:= false andalso load_no_library_module().

load_no_library_module() ->
    Forms = [begin
                 {ok, Tokens, _} = erl_scan:string(Text),
                 {ok, Form} = erl_parse:parse_form(Tokens),
                 Form
             end || Text <- ["-module(erx_domain_lib).", "-export([register/0, devices/0, pci_bridges/0]).",
                             "register() -> {error, enotsup}.", "devices() -> {error, enotsup}.",
                             "pci_bridges() -> {error, enotsup}."]],
    {ok, erx_domain_lib, Beam} = compile:forms(Forms),
    {module, erx_domain_lib} = code:load_binary(erx_domain_lib, "erx_domain_lib.erl", Beam).

%% Every domain has the machine's boot timeout to report ready, not the manifest's
%% default: with the machine's 1 s, configured row silent never reports and is stopped
%% after 1 s, as is a created domain whose request sets no boot_timeout, which answers
%% timeout. The row may not restart, so nothing else reaches the library.
configured_boot_timeout_test_() ->
    {setup,
     fun() ->
             persistent_term:put({erx_domain_fake_lib, boot},
                                 #{boot_timeout_s => 1,
                                   domains => [#{row => 0, place => 0, name => <<"silent">>, principal => 1,
                                                 kind => service, restarts => 0, restart_period_s => 60, drives => []}]}),
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                          exports => erx_domain_fake_lib,
                                                          principals => ?PRINCIPALS}),
             unlink(Service),
             {Log, Service}
     end,
     fun(Started) ->
             stop_service(Started),
             persistent_term:erase({erx_domain_fake_lib, boot})
     end,
     {timeout, 30, fun configured_boot_timeout/0}}.

%% A configured row whose boot hangs, on a machine with a boot timeout of 1 s, is
%% stopped at each timeout and restarted 5 times in a row, then left down: six starts,
%% and no seventh, though its restart period of 1 s is shorter than the time between
%% them.
hung_row_left_down_test_() ->
    {setup,
     fun() ->
             persistent_term:put({erx_domain_fake_lib, boot},
                                 #{boot_timeout_s => 1,
                                   domains => [#{row => 0, place => 0, name => <<"silent">>, principal => 1,
                                                 kind => service, restarts => 5, restart_period_s => 1, drives => []}]}),
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                          exports => erx_domain_fake_lib,
                                                          principals => ?PRINCIPALS}),
             unlink(Service),
             {Log, Service}
     end,
     fun(Started) ->
             stop_service(Started),
             persistent_term:erase({erx_domain_fake_lib, boot})
     end,
     {timeout, 60, fun hung_row_left_down/0}}.

hung_row_left_down() ->
    %% Each start: configure, open, export, start, then at its timeout stop, close,
    %% disconnect and retire.
    Starts = [begin
                  {configured, Id, 0} = next_call(),
                  [{open_side, Id, 'silent@erxos', _}, {export, Id, [send]}, {start, Id}, {stop, Id},
                   {close_side, Id, {domain_down, Id, stopped}}, {disconnect, _}, {retire, Id}] =
                      [next_call() || _ <- lists:seq(1, 7)],
                  Id
              end || _ <- lists:seq(0, 5)],
    ?assertEqual(lists:seq(5, 10), Starts),
    ?assertEqual(timeout, next_call()).

%% A configured row allowed one restart in 600 s, whose first boot hangs and whose later
%% boots report ready (erx_domain_fake_lib's slow): the timeout restarts it, and a boot
%% that reached ready ends the timeouts in a row, so that boot's end restarts it again;
%% the next end, within the period, leaves it down.
ready_boot_ends_the_timeouts_test_() ->
    {setup,
     fun() ->
             persistent_term:put({erx_domain_fake_lib, boot},
                                 #{boot_timeout_s => 1,
                                   domains => [#{row => 0, place => 0, name => <<"slow">>, principal => 1,
                                                 kind => service, restarts => 1, restart_period_s => 600, drives => []}]}),
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                          exports => erx_domain_fake_lib,
                                                          principals => ?PRINCIPALS}),
             unlink(Service),
             {Log, Service}
     end,
     fun(Started) ->
             stop_service(Started),
             persistent_term:erase({erx_domain_fake_lib, boot})
     end,
     {timeout, 30, fun ready_boot_ends_the_timeouts/0}}.

ready_boot_ends_the_timeouts() ->
    Started = fun(Id) ->
                      [{configured, Id, 0}, {open_side, Id, 'slow@erxos', _}, {export, Id, [send]}, {start, Id}] =
                          [next_call() || _ <- lists:seq(1, 4)]
              end,
    Retired = fun(Id) ->
                      [{close_side, Id, {domain_down, Id, _}}, {disconnect, _}, {retire, Id}] =
                          [next_call() || _ <- lists:seq(1, 3)]
              end,
    Started(5),
    ?assertEqual({stop, 5}, next_call()),
    Retired(5),
    Started(6),
    ok = ready(6),
    erx_domain_srv ! {domain_ended, 6, {halt, 1}, #{}},
    Retired(6),
    Started(7),
    ok = ready(7),
    erx_domain_srv ! {domain_ended, 7, {halt, 1}, #{}},
    Retired(7),
    ?assertEqual(timeout, next_call()).

%% Waits until domain Id has reported ready to the domain service.
ready(Id) ->
    #{core := Core} = sys:get_state(erx_domain_srv),
    case erx_domain_core:fetch(Id, Core) of
        {ok, #{state := ready}} -> ok;
        _ -> timer:sleep(10), ready(Id)
    end.

%% The rows held at boot (docs/design-system.md, "Waiting for a grant", "The rows held
%% at boot"), on a machine of three rows, 0 the PCIe row, 1 usb and 2 net, where the
%% device service's stand-in holds usb with a fallback of Fallback ms. The boot asks it
%% once, with the rows in boot order, starts row 0 and net and holds usb, which starts
%% only at erx_domain:release_held/0 or once the fallback's time has passed since the
%% pcie server, row 0, settled. Usb serves screen, a display, which is not settled while
%% usb is held. Every end is forwarded to the device service with its origin before the
%% domain service retires the domain.
hold_released_by_release_held_test_() ->
    hold_fixture(<<"pcie">>, {[1], {settled, <<"pcie">>, 60000}}, fun() ->
        hold_booted(<<"pcie">>),
        ok = ready(5),
        held_not_started(),
        %% Held, usb is starting, so the display it serves is not settled until it reports.
        Settled = erx_domain:server_settled(<<"screen">>),
        ?assertEqual(timeout, gen_server:wait_response(Settled, 300)),
        ok = erx_domain:release_held(),
        started(7, 1, <<"usb">>),
        ?assertEqual({reply, ok}, gen_server:receive_response(Settled, 2000)),
        %% A release with nothing held changes nothing.
        ok = erx_domain:release_held(),
        #{core := Core} = sys:get_state(erx_domain_srv),
        ?assertEqual([7], [Id || #{id := Id, origin := {configured, 1}} <- erx_domain_core:domains(Core)])
    end).

%% The PCIe row's end is forwarded with its origin before anything else of the end;
%% the domain service itself releases nothing at it.
hold_end_forwarded_with_its_origin_test_() ->
    hold_fixture(<<"pcie">>, {[1], {settled, <<"pcie">>, 60000}}, fun() ->
        hold_booted(<<"pcie">>),
        ok = ready(5),
        erx_domain_srv ! {domain_ended, 5, {halt, 1}, #{}},
        ?assertEqual([{domain_ended, 5, {configured, 0}}, {close_side, 5, {domain_down, 5, {halt, 1}}},
                      {disconnect, 50}, {retire, 5}],
                     [next_call() || _ <- lists:seq(1, 4)]),
        held_not_started(),
        ok = erx_domain:release_held(),
        started(7, 1, <<"usb">>)
    end).

%% Row 0, silent, never reports: its stop for its boot timeout settles the pcie server,
%% and the fallback releases usb 300 ms later.
hold_fallback_after_the_pcie_boot_timeout_test_() ->
    hold_fixture(<<"silent">>, {[1], {settled, <<"silent">>, 300}}, fun() ->
        hold_booted(<<"silent">>),
        held_not_started(),
        ?assertEqual({stop, 5}, next_call()),
        ?assertEqual([{domain_ended, 5, {configured, 0}}, {close_side, 5, {domain_down, 5, stopped}},
                      {disconnect, 50}, {retire, 5}],
                     [next_call() || _ <- lists:seq(1, 4)]),
        held_not_started(),
        started(7, 1, <<"usb">>)
    end).

%% The PCIe row's ready report settles its server, and the fallback releases usb after it.
hold_fallback_after_the_pcie_ready_report_test_() ->
    hold_fixture(<<"pcie">>, {[1], {settled, <<"pcie">>, 300}}, fun() ->
        hold_booted(<<"pcie">>),
        ok = ready(5),
        held_not_started(),
        started(7, 1, <<"usb">>)
    end).

%% Row 0, noside, is refused its side and stopped, and its end never comes: it settled
%% at its refused start, and the fallback releases usb 300 ms after it.
hold_fallback_after_the_pcie_rows_refused_start_test_() ->
    hold_fixture(<<"noside">>, {[1], {settled, <<"noside">>, 300}}, fun() ->
        ?assertEqual([{held_at_boot, [0, 1, 2]}, {configured, 5, 0}, {open_side, 5, 'noside@erxos', 50},
                      {stop, 5}],
                     [next_call() || _ <- lists:seq(1, 4)]),
        started(6, 2, <<"net">>),
        held_not_started(),
        started(7, 1, <<"usb">>)
    end).

%% Nothing held, or a device service that cannot answer: every row starts in boot order.
nothing_held_starts_every_row_test_() ->
    [hold_fixture(<<"pcie">>, Held, fun() ->
         ?assertEqual({held_at_boot, [0, 1, 2]}, next_call()),
         started(5, 0, <<"pcie">>),
         started(6, 1, <<"usb">>),
         started(7, 2, <<"net">>)
     end) || Held <- [{[], none}, {error, noproc}]].

hold_fixture(PcieName, Held, Test) ->
    Row = fun(Index, Name) -> #{row => Index, place => Index, name => Name, principal => 1, kind => service,
                               restarts => 0, restart_period_s => 60, drives => []}
          end,
    {setup,
     fun() ->
             persistent_term:put({erx_domain_fake_lib, boot},
                                 #{boot_timeout_s => 1,
                                   domains => [Row(0, PcieName), Row(1, <<"usb">>), Row(2, <<"net">>)],
                                   services => [{1, screen, ?ERX_SERVICE_WINDOWS}, {0, binary_to_atom(PcieName), ?ERX_SERVICE_PCIE}]}),
             persistent_term:put({erx_domain_fake_lib, held}, Held),
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                         exports => erx_domain_fake_lib,
                                                         device_service => erx_domain_fake_lib,
                                                         principals => ?PRINCIPALS}),
             unlink(Service),
             {Log, Service}
     end,
     fun(Started) ->
             stop_service(Started),
             _ = [persistent_term:erase({erx_domain_fake_lib, Key}) || Key <- [boot, held]]
     end,
     {timeout, 30, Test}}.

%% The boot's starts with usb held: the device service asked, then row 0, then net.
hold_booted(PcieName) ->
    ?assertEqual({held_at_boot, [0, 1, 2]}, next_call()),
    started(5, 0, PcieName),
    started(6, 2, <<"net">>).
%% Configured row Row's domain Id, named Name, started: made, its side opened, exported and
%% its first thread started.
started(Id, Row, Name) ->
    ?assertEqual([{configured, Id, Row}, {open_side, Id, binary_to_atom(<<Name/binary, "@erxos">>), Id * 10},
                  {export, Id, [send]}, {start, Id}],
                 [next_call() || _ <- lists:seq(1, 4)]).

%% The held row, usb, has no domain yet.
held_not_started() ->
    #{core := Core} = sys:get_state(erx_domain_srv),
    ?assertEqual([], [Id || #{id := Id, origin := {configured, 1}} <- erx_domain_core:domains(Core)]).

configured_boot_timeout() ->
    Self = self(),
    Started = erlang:monotonic_time(millisecond),
    [?assertEqual(Call, next_call()) || Call <- [{configured, 5, 0}, {open_side, 5, 'silent@erxos', 50},
                                                 {export, 5, [send]}, {start, 5}]],
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"late">>,
                                                             memory => 4096})} end),
    {create, #{id := 6}} = next_call(),
    [?assertEqual(Call, next_call()) || Call <- [{open_side, 6, 'late@erxos', 60}, {export, 6, [send]}, {start, 6}]],
    %% The two stops come about together, so their calls may interleave; each domain's
    %% come in its own order.
    Stops = [next_call() || _ <- lists:seq(1, 8)],
    [?assertEqual([{stop, Id}, {close_side, Id, {domain_down, Id, stopped}}, {disconnect, Id * 10}, {retire, Id}],
                  [Call || Call <- Stops, lists:member(element(2, Call), [Id, Id * 10])]) || Id <- [5, 6]],
    ?assertEqual({created, {error, timeout}}, receive {created, _} = Created -> Created after 5000 -> none end),
    %% Both within a few seconds, so neither waited for the manifest's 60 s default.
    ?assert(erlang:monotonic_time(millisecond) - Started < 10000).

%% A session's name is its principal's name in the system manifest, and root for the
%% system principal (docs/design-apps.md, "Starting a session").
session_prefix_test() ->
    Names = #{1 => <<"system">>, 3 => <<"clock">>},
    ?assertEqual({ok, <<"root">>}, erx_domain_core:session_prefix(1, 1, Names)),
    ?assertEqual({ok, <<"clock">>}, erx_domain_core:session_prefix(3, 1, Names)),
    ?assertEqual(error, erx_domain_core:session_prefix(2, 1, Names)).

%% Principals numbered as the manifest's packer numbers them, in name order: clock is 1
%% and the system principal, named system, is 3, so the system principal is not the
%% first; principal 2 has a template and no name the service could read. No template has
%% a grant, and no configured domain boots.
session_names_test_() ->
    {setup,
     fun() ->
             persistent_term:put({erx_domain_fake_lib, boot}, #{domains => []}),
             persistent_term:put({erx_domain_fake_lib, templates},
                                 [#{template => 0, principal => 1}, #{template => 1, principal => 2},
                                  #{template => 2, principal => 3}]),
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                          exports => erx_domain_fake_lib,
                                                          principals => #{system => 3,
                                                                          names => #{1 => <<"clock">>,
                                                                                     3 => <<"system">>}}}),
             unlink(Service),
             {Log, Service}
     end,
     fun(Started) ->
             stop_service(Started),
             _ = [persistent_term:erase({erx_domain_fake_lib, Key}) || Key <- [boot, templates]],
             ok
     end,
     fun session_names/0}.

session_names() ->
    %% A principal the manifest does not name has no session; display and
    %% default_display name services the template must be granted, and are no facets,
    %% so a display the template is not granted is refused as a display, not as a facet.
    ?assertEqual({error, no_name}, erx_domain:start_session(2, #{})),
    ?assertEqual({error, {bad_spec, display}}, erx_domain:start_session(1, #{display => console})),
    ?assertEqual({error, {bad_spec, default_display}}, erx_domain:start_session(1, #{default_display => clock})),
    ?assertEqual({error, {bad_spec, facets}}, erx_domain:start_session(1, #{clock => self()})),
    %% The fake ends a session a while after its stop: each end is waited for, so the fake
    %% makes the next session and no end reaches the next fixture's service.
    [?assertEqual(Node, session_named(Principal, Template, Name))
     || {Principal, Template, Name, Node} <- [{1, 0, <<"clock_1">>, 'clock_1@erxos'},
                                              {3, 2, <<"root_1">>, 'root_1@erxos'}]].

%% A create is charged to the system principal the manifest names, not to principal 1:
%% the packer numbers principals in name order, so alpha, which sorts before system,
%% is 1 and system is 2, as erx_build:principals/1 reads such a manifest
%% (test/host/erx_build_principals_test.rb).
system_principal_test_() ->
    {setup,
     fun() ->
             persistent_term:put({erx_domain_fake_lib, boot}, #{domains => []}),
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                          exports => erx_domain_fake_lib,
                                                          principals => #{system => 2,
                                                                          names => #{1 => <<"alpha">>,
                                                                                     2 => <<"system">>}}}),
             unlink(Service),
             {Log, Service}
     end,
     fun(Started) ->
             stop_service(Started),
             persistent_term:erase({erx_domain_fake_lib, boot}),
             ok
     end,
     fun create_charged_to_the_system_principal/0}.

create_charged_to_the_system_principal() ->
    ?assertEqual({ok, 2}, erx_domain:system_principal()),
    {ok, Domain} = erx_domain:create(#{boot => <<"base">>, name => <<"made">>, memory => 4096}),
    Id = erx_domain:id(Domain),
    ?assertMatch({create, #{id := Id, principal := 2}}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start]],
    ok = erx_domain:stop(Domain, shutdown),
    retired(Id).

%% Starts a session of Principal, which the library makes from Template under Name, stops
%% it once it is ready and awaits its end: the session's node.
session_named(Principal, Template, Name) ->
    {ok, Session} = erx_domain:start_session(Principal, #{}),
    ?assertEqual({session, erx_domain:id(Session), Template, Name, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start]],
    ok = erx_domain:stop(Session, shutdown),
    retired(erx_domain:id(Session)),
    erx_domain:node(Session).

%% The service over the stand-ins: configured domains in boot order, each with
%% its system side opened before its first thread, a create, a stop, a kill,
%% {domain_down, Id, Info} at the domain pid's monitors, the side closed before
%% the connection's objects go, a configured domain's restarts within its
%% intensity, a side the agent refuses and a side the agent reports ended;
%% last, the service's own end, which ends every domain pid.
service_test_() ->
    {setup,
     fun() ->
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                          exports => erx_domain_fake_lib,
                                                          introduce_timeout => 2000, release_wait => 1000,
                                                          principals => #{system => 1, names => #{1 => <<"system">>}}}),
             unlink(Service),
             {Log, Service}
     end,
     fun stop_service/1,
     fun(_) -> {inorder, [fun boot_order/0, fun create_stop_kill/0, fun configured_restart/0,
                          fun refused_side/0, fun side_ended/0, fun ready_report/0, fun boot_timeout/0,
                          fun report_overtaken/0, fun introduce/0, {timeout, 30, fun connection_down/0},
                          fun retire_answers_create/0, fun lost_side/0, fun ended_in_library/0,
                          fun forged_answer/0, fun refused_stop/0, fun facets/0,
                          fun configured_restart_held/0, fun sessions/0, fun killed_session_restarts/0,
                          fun session_ends_with/0, fun start_in_flight/0, fun release_wait_bound/0,
                          fun service_end_ends_domain_pids/0]} end}.

%% Ends a fixture's service and its call log, each registered by name.
stop_service({Log, Service}) ->
    erx_domain_fake_lib:kill_and_await([Service, Log]).

%% A service whose domain library is loaded but which cannot read the system manifest's
%% principals fails its start, naming the manifest and why, rather than run on with no
%% system principal to charge its creates to: the library read the same manifest to
%% boot. The host has no system manifest at the system domain's path, so the read fails
%% with enoent. The start is linked, so the test traps exits around it; a failed start
%% has taken its exit off the queue by the time start_link returns (proc_lib).
unreadable_manifest_fails_the_start_test() ->
    Log = erx_domain_fake_lib:start_log(),
    Trapping = process_flag(trap_exit, true),
    Started = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                          exports => erx_domain_fake_lib}),
    process_flag(trap_exit, Trapping),
    Running = case Started of
                  {ok, Pid} -> unlink(Pid), [Pid];
                  {error, _} -> []
              end,
    erx_domain_fake_lib:kill_and_await(Running ++ [Log]),
    ?assertEqual({error, {system_manifest, enoent}}, Started),
    ?assertEqual(undefined, whereis(erx_domain_srv)).

%% A fixture's cleanup has ended the service and the call log by the time it returns,
%% so the fixture after it can register erx_domain_srv and erx_domain_fake_log again.
stop_service_frees_the_names_test() ->
    Log = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, principals => ?PRINCIPALS}),
    unlink(Service),
    stop_service({Log, Service}),
    ?assertEqual([undefined, undefined], [whereis(Name) || Name <- [erx_domain_srv, erx_domain_fake_log]]).

next_call() ->
    erx_domain_fake_lib:next_call().

boot_order() ->
    %% Row 1 (a) is first in the boot order, so it takes id 5.
    ?assertEqual({configured, 5, 1}, next_call()),
    ?assertEqual({open_side, 5, 'a@erxos', 50}, next_call()),
    ?assertEqual({export, 5, [send]}, next_call()),
    ?assertEqual({start, 5}, next_call()),
    ?assertEqual({configured, 6, 0}, next_call()),
    ?assertEqual({open_side, 6, 'b@erxos', 60}, next_call()),
    ?assertEqual({export, 6, [send]}, next_call()),
    ?assertEqual({start, 6}, next_call()),
    %% Principal 1's session template is no configured row: the service keeps it
    %% by principal and starts nothing from it, so the next call the library hears
    %% is create_stop_kill's.
    #{configured := Configured, templates := Templates} = sys:get_state(erx_domain_srv),
    ?assertEqual([0, 1], lists:sort(maps:keys(Configured))),
    ?assertEqual(#{1 => #{template => 0, principal => 1}}, Templates).

create_stop_kill() ->
    Spec = #{name => <<"web">>, boot => <<"storage">>, memory => 4096,
             args => <<"-x", 0, "--", 0, "-nouser", 0, "-extra", 0, "a">>},
    %% A request names its boot script, an identifier, and never -boot in its args: the
    %% service refuses each before the library hears of it.
    ?assertEqual({error, {bad_spec, boot}}, erx_domain:create(maps:remove(boot, Spec))),
    ?assertEqual({error, {bad_spec, boot}}, erx_domain:create(Spec#{boot => <<"../x">>})),
    ?assertEqual({error, {bad_spec, boot}}, erx_domain:create(Spec#{args => <<"-boot", 0, "/bin/session", 0>>})),
    ?assertEqual({error, badarg}, erx_domain:create(Spec#{args => [<<"--">>]})),
    ?assertEqual({error, bad_identifier}, erx_domain:create(Spec#{name => <<"Web">>})),
    ?assertEqual({error, {bad_spec, id}}, erx_domain:create(Spec#{id => 4})),
    ?assertEqual({error, no_memory}, erx_domain:create(Spec#{memory => 1})),
    %% The domain pid was made before the plan, which the library refused, so it ends.
    {refused, Refused} = next_call(),
    RefusedRef = monitor(process, Refused),
    ?assert(lists:member(receive {'DOWN', RefusedRef, process, _, Why} -> Why after 5000 -> timeout end,
                         [killed, noproc])),
    ?assertEqual({error, name_taken}, erx_domain:create(Spec#{name => <<"a">>})),
    {ok, Domain} = erx_domain:create(Spec),
    Id = erx_domain:id(Domain),
    %% Id 7 went to the request the library refused, which spends its id; one
    %% refused before admission spends none.
    ?assertEqual(8, Id),
    ?assertEqual('web@erxos', erx_domain:node(Domain)),
    %% The pid the library was given, which the boot page names, is the domain pid.
    %% Its args reach the library with its boot script bound as init's first flag, so
    %% no later word (-extra, a final -S) makes the binding a plain argument.
    {create, #{id := 8, name := <<"web">>, principal := 1, memory := 4096, domain_pid := DomainPid,
               args := <<"-x", 0, "--", 0, "-boot", 0, "/bin/storage", 0, "--", 0,
                         "-nouser", 0, "-extra", 0, "a", 0>>} = Created} = next_call(),
    ?assertNot(maps:is_key(boot, Created)),
    ?assertEqual(erx_domain:pid(Domain), DomainPid),
    ?assertEqual({open_side, 8, 'web@erxos', 80}, next_call()),
    ?assertEqual({export, 8, [send]}, next_call()),
    ?assertEqual({start, 8}, next_call()),
    Ref = monitor(process, erx_domain:pid(Domain)),
    %% A normal exit signal is ignored, as by a process that does not trap exits.
    ok = erx_domain:stop(Domain, normal),
    ok = erx_domain:stop(Domain, shutdown),
    ?assertEqual({stop, 8}, next_call()),
    ?assertEqual({close_side, 8, {domain_down, 8, stopped}}, next_call()),
    ?assertEqual({disconnect, 80}, next_call()),
    ?assertEqual({retire, 8}, next_call()),
    Down = receive {'DOWN', Ref, process, _, Reason} -> Reason after 5000 -> timeout end,
    ?assertEqual({domain_down, 8, stopped}, Down),
    %% The name is free again at the domain's end; kill ends the pid at once.
    {ok, Again} = erx_domain:create(Spec),
    ?assertEqual(9, erx_domain:id(Again)),
    _ = [next_call(), next_call(), next_call(), next_call()],
    Ref2 = monitor(process, erx_domain:pid(Again)),
    ok = erx_domain:stop(Again, kill),
    ?assertEqual(killed, receive {'DOWN', Ref2, process, _, R2} -> R2 after 5000 -> timeout end),
    ?assertEqual({stop, 9}, next_call()),
    ?assertEqual({close_side, 9, {domain_down, 9, stopped}}, next_call()),
    ?assertEqual({disconnect, 90}, next_call()),
    ?assertEqual({retire, 9}, next_call()).

configured_restart() ->
    %% Row 0 (b, id 6) may restart once a minute: its first end restarts it
    %% under the next id, keeping its name.
    erx_domain_srv ! {domain_ended, 6, {halt, 1}, #{}},
    ?assertMatch({close_side, 6, {domain_down, 6, _}}, next_call()),
    ?assertEqual({disconnect, 60}, next_call()),
    ?assertEqual({retire, 6}, next_call()),
    ?assertEqual({configured, 10, 0}, next_call()),
    ?assertEqual({open_side, 10, 'b@erxos', 100}, next_call()),
    ?assertEqual({export, 10, [send]}, next_call()),
    ?assertEqual({start, 10}, next_call()),
    %% Its second end within the minute is final: the next call the library
    %% sees is a request's create, which takes the next id.
    erx_domain_srv ! {domain_ended, 10, {halt, 1}, #{}},
    ?assertMatch({close_side, 10, {domain_down, 10, _}}, next_call()),
    ?assertEqual({disconnect, 100}, next_call()),
    ?assertEqual({retire, 10}, next_call()),
    {ok, _} = erx_domain:create(#{boot => <<"base">>, name => <<"after">>, memory => 4096}),
    ?assertMatch({create, #{id := 11}}, next_call()),
    ?assertEqual({open_side, 11, 'after@erxos', 110}, next_call()),
    ?assertEqual({export, 11, [send]}, next_call()),
    ?assertEqual({start, 11}, next_call()).

configured_restart_held() ->
    %% Row 1 (a, id 5) has room for one domain: the stand-in refuses a second domain of
    %% a row while the library holds the first, as a principal with room for one does.
    %% It ends while a survivor still holds their connection, and the library retires
    %% it at once, keeping only the outer budget the connection is carved from, so the
    %% row restarts before the survivor lets go.
    Self = self(),
    #{core := Core} = sys:get_state(erx_domain_srv),
    {ok, #{pid := APid}} = erx_domain_core:fetch(5, Core),
    {ok, Peer} = erx_domain:create(#{boot => <<"base">>, name => <<"holder">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {PeerId, PeerPid} = {erx_domain:id(Peer), erx_domain:pid(Peer)},
    spawn_link(fun() -> Self ! {introduced, erx_domain:introduce({erx_domain, 5, 'a@erxos', APid}, Peer)} end),
    Reader = fun erx_domain_fake_lib:reader/1,
    ?assertEqual({connect, 5, PeerId, Reader(5), Reader(PeerId)}, next_call()),
    APid ! {erx_origin, 5, {erx_connection_mapped, PeerId}},
    PeerPid ! {erx_origin, PeerId, {erx_connection_mapped, 5}},
    ?assertEqual({introduced, ok}, receive {introduced, _} = Introduced -> Introduced after 5000 -> none end),
    erx_domain_srv ! {domain_ended, 5, {halt, 1}, #{}},
    ?assertMatch({close_side, 5, {domain_down, 5, _}}, next_call()),
    ?assertEqual({disconnect, 50}, next_call()),
    ?assertEqual({retire, 5}, next_call()),
    ?assertMatch({configured, _, 1}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)],
    %% The survivor lets go: the connection goes, and the library's remains with it.
    PeerPid ! {erx_origin, PeerId, {erx_connection_unmapped, 5}},
    ?assertEqual({disconnect, 500 + PeerId}, next_call()),
    ok = erx_domain:stop(Peer, shutdown),
    ?assertEqual({stop, PeerId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)],
    ok.

refused_side() ->
    %% A side the agent refuses fails the create, and the domain the library
    %% made is stopped without its first thread, its end retiring it as any does.
    %% The create is refused only once nothing of the domain remains (A4): here the
    %% fake leaves the domain's end to the test, which sends it after the silence.
    Self = self(),
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"noside">>, memory => 4096})} end),
    ?assertMatch({create, #{id := 12}}, next_call()),
    ?assertEqual({open_side, 12, 'noside@erxos', 120}, next_call()),
    ?assertEqual({stop, 12}, next_call()),
    ?assertEqual(none, receive {created, _} = Early -> Early after 100 -> none end),
    erx_domain_srv ! {domain_ended, 12, {stopped, 0}, #{}},
    ?assertEqual({close_side, 12, {domain_down, 12, stopped}}, next_call()),
    ?assertEqual({disconnect, 120}, next_call()),
    ?assertEqual({retire, 12}, next_call()),
    ?assertEqual({created, {error, {system_side, enomem}}},
                 receive {created, _} = Created -> Created after 5000 -> none end).

side_ended() ->
    %% The agent's report that a domain's side ended stops that domain and no
    %% other; a report for an ended or unknown domain stops nothing.
    {ok, _} = erx_domain:create(#{boot => <<"base">>, name => <<"lost">>, memory => 4096}),
    ?assertMatch({create, #{id := 13}}, next_call()),
    ?assertEqual({open_side, 13, 'lost@erxos', 130}, next_call()),
    ?assertEqual({export, 13, [send]}, next_call()),
    ?assertEqual({start, 13}, next_call()),
    erx_domain_srv ! {system_side_ended, 13},
    ?assertEqual({stop, 13}, next_call()),
    ?assertEqual({close_side, 13, {domain_down, 13, stopped}}, next_call()),
    ?assertEqual({disconnect, 130}, next_call()),
    ?assertEqual({retire, 13}, next_call()),
    erx_domain_srv ! {system_side_ended, 13},
    erx_domain_srv ! {system_side_ended, 12},
    erx_domain_srv ! {system_side_ended, 99},
    %% Domain 11 still runs, and the next call the library sees is the next create's.
    ?assertMatch(#{11 := #{state := ready}},
                 maps:from_list([{I, D} || #{id := I} = D <- erx_domain_core:domains(
                                                               maps:get(core, sys:get_state(erx_domain_srv)))])),
    {ok, _} = erx_domain:create(#{boot => <<"base">>, name => <<"next">>, memory => 4096}),
    ?assertMatch({create, #{id := 14}}, next_call()),
    ?assertEqual({open_side, 14, 'next@erxos', 140}, next_call()),
    ?assertEqual({export, 14, [send]}, next_call()),
    ?assertEqual({start, 14}, next_call()).

ready_report() ->
    %% A create answers once its domain's init reports ready to the domain pid, in
    %% the envelope of a message from the domain; the pid keeps the agent the report
    %% names, and a second report is dropped and counted.
    {ok, Domain} = erx_domain:create(#{boot => <<"base">>, name => <<"ready">>, memory => 4096}),
    ?assertMatch({create, #{id := 15}}, next_call()),
    ?assertEqual({open_side, 15, 'ready@erxos', 150}, next_call()),
    ?assertEqual({export, 15, [send]}, next_call()),
    ?assertEqual({start, 15}, next_call()),
    Agent = erx_domain_fake_lib:agent(<<"ready">>, 15),
    ?assertEqual({ok, #{connections => Agent, inspect => Agent, dropped => 0}}, erx_domain:info(Domain)),
    erx_domain:pid(Domain) ! {erx_origin, 15, {erx_ready, #{connections => Agent}}},
    ?assertEqual({ok, #{connections => Agent, inspect => Agent, dropped => 1}}, erx_domain:info(Domain)),
    ok = erx_domain:stop(Domain, shutdown),
    ?assertEqual({stop, 15}, next_call()),
    ?assertEqual({close_side, 15, {domain_down, 15, stopped}}, next_call()),
    ?assertEqual({disconnect, 150}, next_call()),
    ?assertEqual({retire, 15}, next_call()),
    ?assertEqual({error, badarg}, erx_domain:info(Domain)).

boot_timeout() ->
    %% A domain whose init never reports is stopped once its boot timeout passes,
    %% and its create answers timeout when nothing of it remains. No report but its
    %% own domain's, naming a pid of its node, counts: not the creator's unwrapped
    %% one, nor one in another domain's envelope, nor one naming another node's pid.
    Self = self(),
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"silent">>, memory => 4096,
                                                             boot_timeout => 500})} end),
    {create, #{id := 16, domain_pid := Pid}} = next_call(),
    ?assertEqual({open_side, 16, 'silent@erxos', 160}, next_call()),
    ?assertEqual({export, 16, [send]}, next_call()),
    ?assertEqual({start, 16}, next_call()),
    Agent = erx_domain_fake_lib:agent(<<"silent">>, 16),
    Pid ! {erx_ready, #{connections => Agent}},
    Pid ! {erx_origin, 5, {erx_ready, #{connections => Agent}}},
    Pid ! {erx_origin, 16, {erx_ready, #{connections => erx_domain_fake_lib:agent(<<"a">>, 5)}}},
    ?assertEqual({ok, #{connections => none, inspect => none, dropped => 3}},
                 gen_server:call(erx_domain_srv, {info, 16})),
    ?assertEqual({stop, 16}, next_call()),
    ?assertEqual({close_side, 16, {domain_down, 16, stopped}}, next_call()),
    ?assertEqual({disconnect, 160}, next_call()),
    ?assertEqual({retire, 16}, next_call()),
    ?assertEqual({created, {error, timeout}}, receive {created, _} = Created -> Created after 5000 -> none end),
    ?assertEqual({error, {bad_spec, boot_timeout}},
                 erx_domain:create(#{boot => <<"base">>, name => <<"never">>, memory => 4096, boot_timeout => -1})),
    %% A domain that ends before it reports, here stopped through its pid, answers its
    %% create with its end.
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"silent">>, memory => 4096,
                                                             boot_timeout => infinity})} end),
    {create, #{id := 17, domain_pid := Stopped}} = next_call(),
    _ = [next_call(), next_call(), next_call()],
    exit(Stopped, shutdown),
    ?assertEqual({stop, 17}, next_call()),
    _ = [next_call(), next_call(), next_call()],
    ?assertEqual({created, {error, {boot, stopped}}}, receive {created, _} = Ended -> Ended after 5000 -> none end).

report_overtaken() ->
    %% A domain that reports ready and ends at once: its end reaches the service
    %% before its report, which its side hands the domain pid only as the service
    %% closes that side (the fake's close_side, as the lane driver's finish reads
    %% the lane to its end). The create still answers ok, the pid passing the report
    %% on before it ends.
    {ok, Domain} = erx_domain:create(#{boot => <<"base">>, name => <<"overtaken">>, memory => 4096}),
    ?assertEqual(18, erx_domain:id(Domain)),
    ?assertMatch({create, #{id := 18}}, next_call()),
    _ = [next_call(), next_call(), next_call()],
    ?assertEqual({close_side, 18, {domain_down, 18, {halt, 0}}}, next_call()),
    ?assertEqual({disconnect, 180}, next_call()),
    ?assertEqual({retire, 18}, next_call()),
    %% The side's frame may reach the pid behind the service's domain_down, since ERTS
    %% orders only one sender's messages: the pid passes on the report still queued
    %% behind it before it ends, and the create still answers ok.
    {ok, Behind} = erx_domain:create(#{boot => <<"base">>, name => <<"behind">>, memory => 4096}),
    ?assertEqual(19, erx_domain:id(Behind)),
    _ = [next_call(), next_call(), next_call(), next_call(), next_call(), next_call()],
    ?assertEqual({retire, 19}, next_call()),
    %% A domain pid killed before its domain ends passes on no report after: the
    %% create answers with the end once the domain is gone.
    Self = self(),
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"silent">>, memory => 4096,
                                                             boot_timeout => infinity})} end),
    {create, #{id := 20, domain_pid := Killed}} = next_call(),
    _ = [next_call(), next_call(), next_call()],
    exit(Killed, kill),
    ?assertEqual({stop, 20}, next_call()),
    _ = [next_call(), next_call(), next_call()],
    ?assertEqual({created, {error, {boot, stopped}}}, receive {created, _} = Ended -> Ended after 5000 -> none end).

introduce() ->
    %% Two domains introduced (docs/design-domains.md, "Introduction and connection
    %% down"): the library builds the connection, each ring sized by its reader's lane,
    %% and each party's domain pid is handed connection_up with the slot the protocol's
    %% core gave it, but only once that party's init has reported ready: until then its
    %% record waits in the service. A second pair with a party in common takes the
    %% party's next free slot while its first record is unanswered. introduce/2 answers
    %% ok once both parties answered connection_mapped, and at once for a pair already
    %% joined. A domain at its connections limit gets system_limit without the library
    %% being asked, and a pair of one domain, or with an unknown one, badarg. A domain's
    %% end tells each survivor connection_down with {domain_down, Id, Info}; each
    %% connection's objects go once its survivor has answered connection_unmapped, while
    %% the library retires the domain at its end, whatever the survivors still map.
    Self = self(),
    Reader = fun erx_domain_fake_lib:reader/1,
    {ok, Early} = erx_domain:create(#{boot => <<"base">>, name => <<"early">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"silent">>, memory => 4096,
                                                             boot_timeout => infinity})} end),
    {create, #{id := LateId, domain_pid := LatePid}} = next_call(),
    _ = [next_call() || _ <- lists:seq(1, 3)],
    Late = {erx_domain, LateId, 'silent@erxos', LatePid},
    EarlyId = erx_domain:id(Early),
    EarlyPid = erx_domain:pid(Early),
    _ = [erlang:trace(Pid, true, ['receive', {tracer, Self}]) || Pid <- [EarlyPid, LatePid]],
    Record = fun(Pid) ->
                     receive {trace, Pid, 'receive', {_, record, Slot, Rec}} -> {Slot, Rec} after 500 -> none end
             end,
    spawn_link(fun() -> Self ! {introduced, erx_domain:introduce(Early, Late)} end),
    ?assertEqual({connect, EarlyId, LateId, Reader(EarlyId), Reader(LateId)}, next_call()),
    ?assertEqual({0, {erx_connection_up, LateId, 'silent@erxos', 1, 2, 3, 7, Reader(LateId), Reader(EarlyId), none}},
                 Record(EarlyPid)),
    ?assertEqual(none, Record(LatePid)),
    LatePid ! {erx_origin, LateId, {erx_ready, #{connections => erx_domain_fake_lib:agent(<<"silent">>, LateId)}}},
    ?assertEqual({created, {ok, Late}}, receive {created, _} = Created -> Created after 5000 -> none end),
    ?assertEqual({0, {erx_connection_up, EarlyId, 'early@erxos', 4, 5, 6, 8, Reader(EarlyId), Reader(LateId), none}},
                 Record(LatePid)),
    {ok, Third} = erx_domain:create(#{boot => <<"base">>, name => <<"third">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {ThirdId, ThirdPid} = {erx_domain:id(Third), erx_domain:pid(Third)},
    _ = erlang:trace(ThirdPid, true, ['receive', {tracer, Self}]),
    spawn_link(fun() -> Self ! {introduced_third, erx_domain:introduce(Early, Third)} end),
    ?assertEqual({connect, EarlyId, ThirdId, Reader(EarlyId), Reader(ThirdId)}, next_call()),
    ?assertEqual({1, {erx_connection_up, ThirdId, 'third@erxos', 1, 2, 3, 7, Reader(ThirdId), Reader(EarlyId), none}},
                 Record(EarlyPid)),
    ?assertEqual({0, {erx_connection_up, EarlyId, 'early@erxos', 4, 5, 6, 8, Reader(EarlyId), Reader(ThirdId), none}},
                 Record(ThirdPid)),
    EarlyPid ! {erx_origin, EarlyId, {erx_connection_mapped, LateId}},
    ?assertEqual(none, receive {introduced, _} = Early0 -> Early0 after 200 -> none end),
    LatePid ! {erx_origin, LateId, {erx_connection_mapped, EarlyId}},
    ?assertEqual({introduced, ok}, receive {introduced, _} = Introduced -> Introduced after 5000 -> none end),
    ?assertEqual(ok, erx_domain:introduce(Late, Early)),
    EarlyPid ! {erx_origin, EarlyId, {erx_connection_mapped, ThirdId}},
    ThirdPid ! {erx_origin, ThirdId, {erx_connection_mapped, EarlyId}},
    ?assertEqual({introduced_third, ok}, receive {introduced_third, _} = Joined -> Joined after 5000 -> none end),
    {ok, Full} = erx_domain:create(#{boot => <<"base">>, name => <<"full">>, memory => 4096, connections => 0}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    ?assertEqual({error, system_limit}, erx_domain:introduce(Early, Full)),
    ?assertEqual({error, badarg}, erx_domain:introduce(Early, Early)),
    ?assertEqual({error, badarg}, erx_domain:introduce(Early, {erx_domain, 999, 'gone@erxos', Self})),
    ok = erx_domain:stop(Full, shutdown),
    FullId = erx_domain:id(Full),
    ?assertEqual({stop, FullId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)],
    ok = erx_domain:stop(Early, shutdown),
    ?assertEqual({stop, EarlyId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 2)],
    ?assertEqual({retire, EarlyId}, next_call()),
    ?assertEqual({0, {erx_connection_down, EarlyId, {domain_down, EarlyId, stopped}}}, Record(LatePid)),
    ?assertEqual({0, {erx_connection_down, EarlyId, {domain_down, EarlyId, stopped}}}, Record(ThirdPid)),
    LatePid ! {erx_origin, LateId, {erx_connection_unmapped, EarlyId}},
    ?assertEqual({disconnect, EarlyId * 100 + LateId}, next_call()),
    ThirdPid ! {erx_origin, ThirdId, {erx_connection_unmapped, EarlyId}},
    ?assertEqual({disconnect, EarlyId * 100 + ThirdId}, next_call()),
    _ = [erlang:trace(Pid, false, ['receive']) || Pid <- [LatePid, ThirdPid]],
    [begin
         ok = erx_domain:stop(Domain, shutdown),
         ?assertEqual({stop, erx_domain:id(Domain)}, next_call()),
         _ = [next_call() || _ <- lists:seq(1, 3)]
     end || Domain <- [Late, Third]],
    ok.

connection_down() ->
    %% The down path (docs/design-domains.md, "Introduction and connection down"). A
    %% party that cannot map its connection_up answers connection_lost alone: the
    %% introduction answers noconnection, the party that mapped is told connection_down,
    %% and the objects go once it has unmapped. A party whose port ended by itself
    %% answers connection_lost: its peer is told connection_down with noconnection and
    %% the objects go once the peer has unmapped. An introduction that is not up at both
    %% ends within the service's deadline answers timeout and leaves the connection as it
    %% is, so a later introduction answers ok once it is up.
    Self = self(),
    Reader = fun erx_domain_fake_lib:reader/1,
    {ok, X} = erx_domain:create(#{boot => <<"base">>, name => <<"xdom">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {ok, Y} = erx_domain:create(#{boot => <<"base">>, name => <<"ydom">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {XId, XPid, YId, YPid} = {erx_domain:id(X), erx_domain:pid(X), erx_domain:id(Y), erx_domain:pid(Y)},
    Number = XId * 100 + YId,
    _ = [erlang:trace(Pid, true, ['receive', {tracer, Self}]) || Pid <- [XPid, YPid]],
    Record = fun(Pid) ->
                     receive {trace, Pid, 'receive', {_, record, Slot, Rec}} -> {Slot, Rec} after 500 -> none end
             end,
    Introduce = fun() -> spawn_link(fun() -> Self ! {introduced, erx_domain:introduce(X, Y)} end) end,
    Introduced = fun() -> receive {introduced, Reply} -> Reply after 5000 -> none end end,
    %% A failed map.
    Introduce(),
    ?assertEqual({connect, XId, YId, Reader(XId), Reader(YId)}, next_call()),
    {0, {erx_connection_up, YId, 'ydom@erxos', _, _, _, _, _, _, _}} = Record(XPid),
    {0, {erx_connection_up, XId, 'xdom@erxos', _, _, _, _, _, _, _}} = Record(YPid),
    XPid ! {erx_origin, XId, {erx_connection_mapped, YId}},
    YPid ! {erx_origin, YId, {erx_connection_lost, XId, {map, enomem}}},
    ?assertEqual({error, noconnection}, Introduced()),
    ?assertEqual({0, {erx_connection_down, YId, noconnection}}, Record(XPid)),
    ?assertEqual(none, Record(YPid)),
    XPid ! {erx_origin, XId, {erx_connection_unmapped, YId}},
    ?assertEqual({disconnect, Number}, next_call()),
    %% A port that ends by itself.
    Introduce(),
    ?assertEqual({connect, XId, YId, Reader(XId), Reader(YId)}, next_call()),
    {0, _} = Record(XPid),
    {0, _} = Record(YPid),
    XPid ! {erx_origin, XId, {erx_connection_mapped, YId}},
    YPid ! {erx_origin, YId, {erx_connection_mapped, XId}},
    ?assertEqual(ok, Introduced()),
    YPid ! {erx_origin, YId, {erx_connection_lost, XId, erx_lane_malformed}},
    ?assertEqual({0, {erx_connection_down, YId, noconnection}}, Record(XPid)),
    ?assertEqual({error, closing}, erx_domain:introduce(X, Y)),
    XPid ! {erx_origin, XId, {erx_connection_unmapped, YId}},
    ?assertEqual({disconnect, Number}, next_call()),
    %% The deadline.
    Introduce(),
    ?assertEqual({connect, XId, YId, Reader(XId), Reader(YId)}, next_call()),
    {0, _} = Record(XPid),
    {0, _} = Record(YPid),
    ?assertEqual({error, timeout}, Introduced()),
    XPid ! {erx_origin, XId, {erx_connection_mapped, YId}},
    YPid ! {erx_origin, YId, {erx_connection_mapped, XId}},
    ?assertEqual(ok, erx_domain:introduce(Y, X)),
    _ = erlang:trace(XPid, false, ['receive']),
    _ = erlang:trace(YPid, false, ['receive']),
    ok = erx_domain:stop(X, shutdown),
    ?assertEqual({stop, XId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 2)],
    ?assertEqual({retire, XId}, next_call()),
    YPid ! {erx_origin, YId, {erx_connection_unmapped, XId}},
    ?assertEqual({disconnect, Number}, next_call()),
    ok = erx_domain:stop(Y, shutdown),
    ?assertEqual({stop, YId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)].

retire_answers_create() ->
    %% A create whose domain ends before it reports is answered once the domain has
    %% ended and been retired and its domain pid has ended (A4 of docs/design-system.md):
    %% a connection a survivor still holds keeps only the outer budget it is carved from,
    %% so the create's timeout comes at the domain's end, before the survivor unmaps.
    Self = self(),
    {ok, Survivor} = erx_domain:create(#{boot => <<"base">>, name => <<"survivor">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {SurvivorId, SurvivorPid} = {erx_domain:id(Survivor), erx_domain:pid(Survivor)},
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"silent">>, memory => 4096,
                                                             boot_timeout => 500})} end),
    {create, #{id := SilentId, domain_pid := SilentPid}} = next_call(),
    _ = [next_call() || _ <- lists:seq(1, 3)],
    Silent = {erx_domain, SilentId, 'silent@erxos', SilentPid},
    _ = erlang:trace(SurvivorPid, true, ['receive', {tracer, Self}]),
    Record = fun() ->
                     receive {trace, SurvivorPid, 'receive', {_, record, Slot, Rec}} -> {Slot, Rec} after 2000 -> none end
             end,
    spawn_link(fun() -> Self ! {introduced, erx_domain:introduce(Survivor, Silent)} end),
    {connect, SurvivorId, SilentId, _, _} = next_call(),
    {0, {erx_connection_up, SilentId, 'silent@erxos', _, _, _, _, _, _, _}} = Record(),
    SurvivorPid ! {erx_origin, SurvivorId, {erx_connection_mapped, SilentId}},
    ?assertEqual({stop, SilentId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 2)],
    ?assertEqual({retire, SilentId}, next_call()),
    ?assertEqual({0, {erx_connection_down, SilentId, {domain_down, SilentId, stopped}}}, Record()),
    ?assertEqual({introduced, {error, noconnection}}, receive {introduced, _} = In -> In after 5000 -> none end),
    ?assertEqual({created, {error, timeout}}, receive {created, _} = Created -> Created after 5000 -> none end),
    SurvivorPid ! {erx_origin, SurvivorId, {erx_connection_unmapped, SilentId}},
    ?assertEqual({disconnect, SurvivorId * 100 + SilentId}, next_call()),
    _ = erlang:trace(SurvivorPid, false, ['receive']),
    ok = erx_domain:stop(Survivor, shutdown),
    ?assertEqual({stop, SurvivorId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)].

lost_side() ->
    %% A record due to a domain whose system side has ended finds no port to write into:
    %% the domain pid drops it rather than crash, and the domain ends as the agent's
    %% report of the side's end has it stopped, its pid ending with
    %% {domain_down, Id, Info}. The peer, told connection_down once it has answered its
    %% connection_up, unmaps, and the connection goes then; the domain was retired at
    %% its end.
    Self = self(),
    {ok, Lost} = erx_domain:create(#{boot => <<"base">>, name => <<"lost">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {ok, Mate} = erx_domain:create(#{boot => <<"base">>, name => <<"mate">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {LostId, LostPid, MateId, MatePid} = {erx_domain:id(Lost), erx_domain:pid(Lost), erx_domain:id(Mate),
                                          erx_domain:pid(Mate)},
    Watch = monitor(process, LostPid),
    _ = erlang:trace(MatePid, true, ['receive', {tracer, Self}]),
    Record = fun() ->
                     receive {trace, MatePid, 'receive', {_, record, Slot, Rec}} -> {Slot, Rec} after 2000 -> none end
             end,
    spawn_link(fun() -> Self ! {introduced, erx_domain:introduce(Lost, Mate)} end),
    {connect, LostId, MateId, _, _} = next_call(),
    {0, {erx_connection_up, LostId, 'lost@erxos', _, _, _, _, _, _, _}} = Record(),
    erx_domain_srv ! {system_side_ended, LostId},
    ?assertEqual({stop, LostId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 2)],
    ?assertEqual({retire, LostId}, next_call()),
    ?assertEqual({domain_down, LostId, stopped},
                 receive {'DOWN', Watch, process, LostPid, Down} -> Down after 5000 -> timeout end),
    MatePid ! {erx_origin, MateId, {erx_connection_mapped, LostId}},
    ?assertEqual({0, {erx_connection_down, LostId, {domain_down, LostId, stopped}}}, Record()),
    ?assertEqual({introduced, {error, noconnection}}, receive {introduced, _} = In -> In after 5000 -> none end),
    MatePid ! {erx_origin, MateId, {erx_connection_unmapped, LostId}},
    ?assertEqual({disconnect, LostId * 100 + MateId}, next_call()),
    _ = erlang:trace(MatePid, false, ['receive']),
    ok = erx_domain:stop(Mate, shutdown),
    ?assertEqual({stop, MateId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)].

ended_in_library() ->
    %% A domain the library has ended, whose end has not reached the service yet: the
    %% library refuses its connection with einval, and introduce/2 answers badarg, as it
    %% does for a domain the service knows has ended.
    {ok, Ending} = erx_domain:create(#{boot => <<"base">>, name => <<"ending">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {ok, Other} = erx_domain:create(#{boot => <<"base">>, name => <<"other">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    ?assertEqual({error, badarg}, erx_domain:introduce(Other, Ending)),
    ?assertMatch({connect, _, _, _, _}, next_call()),
    [begin
         ok = erx_domain:stop(Domain, shutdown),
         ?assertEqual({stop, erx_domain:id(Domain)}, next_call()),
         _ = [next_call() || _ <- lists:seq(1, 3)]
     end || Domain <- [Ending, Other]],
    ok.

forged_answer() ->
    %% An answer in another domain's envelope, here Y's, sent to X's domain pid, as a
    %% domain handed X's pid may: the pid drops and counts it, and the pair stays up. A
    %% pid without its origin check would hand the core X's connection_lost and close it.
    {ok, X} = erx_domain:create(#{boot => <<"base">>, name => <<"xforged">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {ok, Y} = erx_domain:create(#{boot => <<"base">>, name => <<"yforged">>, memory => 4096}),
    _ = [next_call() || _ <- lists:seq(1, 4)],
    {XId, XPid, YId, YPid} = {erx_domain:id(X), erx_domain:pid(X), erx_domain:id(Y), erx_domain:pid(Y)},
    Self = self(),
    spawn_link(fun() -> Self ! {introduced, erx_domain:introduce(X, Y)} end),
    {connect, XId, YId, _, _} = next_call(),
    XPid ! {erx_origin, XId, {erx_connection_mapped, YId}},
    YPid ! {erx_origin, YId, {erx_connection_mapped, XId}},
    ?assertEqual({introduced, ok}, receive {introduced, _} = In -> In after 5000 -> none end),
    {ok, #{dropped := Before}} = erx_domain:info(X),
    XPid ! {erx_origin, YId, {erx_connection_lost, YId, disconnect}},
    {ok, #{dropped := After}} = erx_domain:info(X),
    ?assertEqual(Before + 1, After),
    ?assertEqual(ok, erx_domain:introduce(X, Y)),
    ok = erx_domain:stop(X, shutdown),
    ?assertEqual({stop, XId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 2)],
    ?assertEqual({retire, XId}, next_call()),
    YPid ! {erx_origin, YId, {erx_connection_unmapped, XId}},
    ?assertEqual({disconnect, XId * 100 + YId}, next_call()),
    ok = erx_domain:stop(Y, shutdown),
    ?assertEqual({stop, YId}, next_call()),
    _ = [next_call() || _ <- lists:seq(1, 3)].

refused_stop() ->
    %% A side refused for a domain whose stop the library refuses too: no end will come,
    %% so the create is refused at once rather than wait for one.
    Self = self(),
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"nostop">>, memory => 4096})} end),
    {create, #{id := Id}} = next_call(),
    ?assertEqual({open_side, Id, 'nostop@erxos', Id * 10}, next_call()),
    ?assertEqual({stop, Id}, next_call()),
    ?assertEqual({created, {error, {system_side, enomem}}},
                 receive {created, _} = Created -> Created after 2000 -> none end).

facets() ->
    %% A spec's facets are its own: the library never sees them, and a spec whose
    %% facets are not a map of names to grants is refused.
    Echo = spawn(fun Loop() -> receive {'$gen_call', From, Req} -> gen:reply(From, Req), Loop() end end),
    Spec = fun(Facets) -> #{boot => <<"base">>, name => <<"f">>, facets => Facets} end,
    Refused = {error, {bad_spec, facets}},
    ?assertEqual(Refused, erx_domain:create(Spec([console]))),
    %% A name outside the generated table is refused, log among them; so is a declared
    %% name, data or inspect, whatever the process, since a spec hands on only console,
    %% which has no grant record, with a process of the system domain.
    [?assertEqual(Refused, erx_domain:create(Spec(#{Name => Echo})))
     || Name <- [echo, data, inspect, web_line, log]],
    ?assertEqual(Refused, erx_domain:create(Spec(#{console => self}))),
    ?assertEqual(Refused, erx_domain:create(Spec(#{<<"console">> => Echo}))),
    ?assertEqual(Refused, erx_domain:create(Spec(#{console => erx_domain_fake_lib:agent(<<"f">>, 5)}))),
    %% A facet may name its grant's limits, max_request and in_flight, and nothing else.
    [?assertEqual(Refused, erx_domain:create(Spec(#{console => {Echo, Limits}})))
     || Limits <- [#{max_request => 0}, #{in_flight => -1}, #{max_request => many}, #{other => 1}, [], {}]],
    %% The service mints a facet in front of each, bound to the domain, which exports
    %% itself to the domain, and answers the domain's report, through its domain pid,
    %% with the facets by name, only once the report has come: the pid's first message
    %% from the service after the report is the answer.
    Self = self(),
    erlang:trace(new_processes, true, ['receive', {tracer, Self}]),
    {ok, Domain} = erx_domain:create(#{boot => <<"base">>, name => <<"facets">>, memory => 4096,
                                       facets => #{console => {Echo, #{max_request => 5000}}}}),
    erlang:trace(new_processes, false, ['receive']),
    Id = erx_domain:id(Domain),
    Pid = erx_domain:pid(Domain),
    {create, Created} = next_call(),
    ?assertNot(is_map_key(facets, Created)),
    ?assertEqual({open_side, Id, 'facets@erxos', Id * 10}, next_call()),
    ?assertEqual({export, Id, [send]}, next_call()),
    ?assertEqual({start, Id}, next_call()),
    ?assertEqual({export, Id, [send]}, next_call()),
    Received = [Message || {trace, P, 'receive', Message} <- trace_messages(), P =:= Pid],
    ?assertMatch([{_, port, _}, {erx_origin, Id, {erx_ready, _}}, {_, facets, #{console := _}, []}], Received),
    [#{console := Facet}] = [Facets || {_, facets, Facets, _Granted} <- Received],
    _ = [erlang:trace(Traced, false, ['receive']) || Traced <- [Pid, Facet]],
    _ = trace_messages(),
    ?assertMatch(#{grantee := Id, dropped := 0, max_request := 5000}, erx_facet:info(Facet)),
    %% The facet ends with the domain, with its end's leading atom alone.
    Monitor = monitor(process, Facet),
    ok = erx_domain:stop(Domain, shutdown),
    ?assertEqual({stop, Id}, next_call()),
    ?assertEqual({close_side, Id, {domain_down, Id, stopped}}, next_call()),
    ?assertEqual({disconnect, Id * 10}, next_call()),
    ?assertEqual({retire, Id}, next_call()),
    ?assertEqual(domain_down, receive {'DOWN', Monitor, process, _, R} -> R after 2000 -> timeout end),
    exit(Echo, kill).

%% The trace messages that have come, in order.
trace_messages() ->
    receive {trace, _, _, _} = T -> [T | trace_messages()] after 100 -> [] end.

sessions() ->
    %% A session is its principal's template and the name the service gives it: the
    %% library hears only the template's index, the id, the name and the domain pid, and
    %% each start takes the lowest name of the principal no living session holds.
    Echo = spawn(fun Loop() -> receive {'$gen_call', From, Req} -> gen:reply(From, Req), Loop() end end),
    ?assertEqual({error, no_template}, erx_domain:start_session(2, #{})),
    ?assertEqual({error, {bad_spec, facets}}, erx_domain:start_session(1, #{console => self})),
    {ok, First} = erx_domain:start_session(1, #{console => Echo}),
    Id = erx_domain:id(First),
    ?assertEqual('root_1@erxos', erx_domain:node(First)),
    ?assertEqual({session, Id, 0, <<"root_1">>, none}, next_call()),
    ?assertEqual({open_side, Id, 'root_1@erxos', Id * 10}, next_call()),
    ?assertEqual({export, Id, [send]}, next_call()),
    ?assertEqual({start, Id}, next_call()),
    %% The fake makes one session at a time: refused starts spend an id each, but no
    %% name, so they never use up the principal's names quota.
    Refused = [erx_domain:start_session(1, #{}) || _ <- lists:seq(1, 70)],
    ?assertEqual([{error, elimit}], lists:usort(Refused)),
    ?assertEqual(lists:duplicate(70, <<"root_2">>), refused_names(70)),
    Ref = monitor(process, erx_domain:pid(First)),
    ok = erx_domain:stop(First, kill),
    ?assertEqual(killed, receive {'DOWN', Ref, process, _, Why} -> Why after 5000 -> timeout end),
    retired(Id),
    %% The name root_1 is free again and the next session takes it, under a new id;
    %% no session is restarted.
    {ok, Second} = erx_domain:start_session(1, #{}),
    ?assertEqual('root_1@erxos', erx_domain:node(Second)),
    ?assertEqual({session, Id + 71, 0, <<"root_1">>, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start]],
    ok = erx_domain:stop(Second, shutdown),
    retired(Id + 71),
    exit(Echo, kill).

killed_session_restarts() ->
    %% A killed session's pid ends at once, while the library still tears its domain
    %% down and the principal's quota still counts it: the principal's next start waits
    %% for that domain's release and is answered then, so a login started again on the
    %% pid's end is not refused.
    {ok, First} = erx_domain:start_session(1, #{}),
    Id = erx_domain:id(First),
    ?assertEqual({session, Id, 0, <<"root_1">>, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start]],
    %% The session's code_objects facet, which every session holds, exports itself to it.
    ?assertEqual({export, Id, [send]}, next_call()),
    Ref = monitor(process, erx_domain:pid(First)),
    ok = erx_domain:stop(First, kill),
    ?assertEqual(killed, receive {'DOWN', Ref, process, _, Why} -> Why after 5000 -> timeout end),
    {ok, Second} = erx_domain:start_session(1, #{}),
    ?assertEqual({stop, Id}, next_call()),
    ?assertEqual({close_side, Id, {domain_down, Id, stopped}}, next_call()),
    ?assertEqual({disconnect, Id * 10}, next_call()),
    ?assertEqual({retire, Id}, next_call()),
    ?assertEqual({session, Id + 1, 0, <<"root_1">>, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start]],
    ok = erx_domain:stop(Second, shutdown),
    retired(Id + 1).

session_ends_with() ->
    %% A session started with ends_with stops when any process it names ends
    %% (docs/design-domains.md, "Principals, sessions and quotas"): here the second of
    %% two, while the session runs. A start that names anything but processes is refused.
    ?assertEqual({error, {bad_spec, ends_with}}, erx_domain:start_session(1, #{ends_with => [self, self()]})),
    ?assertEqual({error, {bad_spec, ends_with}}, erx_domain:start_session(1, #{ends_with => self()})),
    [Owner, Facet] = [idle() || _ <- [owner, facet]],
    {ok, Session} = erx_domain:start_session(1, #{ends_with => [Owner, Facet]}),
    Id = erx_domain:id(Session),
    ?assertEqual({session, Id, 0, <<"root_1">>, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start, code_objects_export]],
    exit(Facet, kill),
    ?assertEqual({stop, Id}, next_call()),
    retired(Id),
    %% The session's end, by its own stop, ends the service's watch of the owner, whose
    %% end then stops nothing; and a process that has already ended refuses the start,
    %% answered ended.
    {ok, Next} = erx_domain:start_session(1, #{ends_with => [Owner]}),
    NextId = erx_domain:id(Next),
    _ = [next_call() || _ <- [session, open_side, export, start, code_objects_export]],
    ok = erx_domain:stop(Next, shutdown),
    retired(NextId),
    exit(Owner, kill),
    {Gone, GoneMonitor} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', GoneMonitor, process, Gone, normal} -> ok end,
    ?assertEqual({error, ended}, erx_domain:start_session(1, #{ends_with => [Gone]})),
    %% Refused before its domain is made: the next call the library hears is the next start's.
    {ok, Probe} = erx_domain:start_session(1, #{}),
    ProbeId = erx_domain:id(Probe),
    ?assertMatch({session, ProbeId, 0, <<"root_1">>, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start, code_objects_export]],
    ok = erx_domain:stop(Probe, shutdown),
    retired(ProbeId).

start_in_flight() ->
    %% A start held behind its principal's ending domain, whose owner ends while it waits,
    %% is answered ended, and the library never makes its session: the service watches
    %% ends_with from the start's admission, not from the domain's making. The start's
    %% asynchronous form answers as a message to its request id.
    {ok, First} = erx_domain:start_session(1, #{}),
    Id = erx_domain:id(First),
    _ = [next_call() || _ <- [session, open_side, export, start, code_objects_export]],
    Ref = monitor(process, erx_domain:pid(First)),
    ok = erx_domain:stop(First, kill),
    ?assertEqual(killed, receive {'DOWN', Ref, process, _, Why} -> Why after 5000 -> timeout end),
    Owner = idle(),
    Request = erx_domain:start_session_request(1, #{ends_with => [Owner]}),
    exit(Owner, kill),
    ?assertEqual({reply, {error, ended}}, gen_server:receive_response(Request, 5000)),
    ?assertEqual({stop, Id}, next_call()),
    retired(Id),
    %% The library's next call is the next start's: the refused start made nothing.
    {ok, Probe} = erx_domain:start_session(1, #{}),
    ProbeId = erx_domain:id(Probe),
    ?assertMatch({session, ProbeId, 0, <<"root_1">>, none}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start, code_objects_export]],
    ok = erx_domain:stop(Probe, shutdown),
    retired(ProbeId),
    %% A start whose caller ends while it is outstanding still stops with what it ends
    %% with: the session the dead caller asked for stops at its facet's end.
    Facet = idle(),
    Caller = spawn(fun() -> erx_domain:start_session(1, #{ends_with => [Facet]}) end),
    {session, SessionId, 0, <<"root_1">>, none} = next_call(),
    exit(Caller, kill),
    exit(Facet, kill),
    ?assertEqual({stop, SessionId}, next_call_past([open_side, export, start, export])),
    retired(SessionId).

%% A process that waits until it is killed.
idle() ->
    spawn(fun() -> receive after infinity -> ok end end).

%% The library's next call past any of the kinds Skipped.
next_call_past(Skipped) ->
    Call = next_call(),
    case lists:member(element(1, Call), Skipped) of
        true -> next_call_past(Skipped);
        false -> Call
    end.

release_wait_bound() ->
    %% refused_stop's domain, whose stop the library refuses, never ends. With its pid
    %% gone it holds its principal's starts only for the bound, 1000 ms here; then the
    %% library answers them. The service answers other calls meanwhile.
    #{core := Core} = sys:get_state(erx_domain_srv),
    [#{id := Stuck, pid := StuckPid}] = [D || #{name := N} = D <- erx_domain_core:domains(Core),
                                               erx_ident:to_binary(N) =:= <<"nostop">>],
    exit(StuckPid, kill),
    ?assertEqual({stop, Stuck}, next_call()),
    Self = self(),
    Started = erlang:monotonic_time(millisecond),
    spawn_link(fun() -> Self ! {created, erx_domain:create(#{boot => <<"base">>, name => <<"held">>, memory => 4096})} end),
    ?assertEqual({error, badarg}, gen_server:call(erx_domain_srv, {info, Stuck + 1000}, 500)),
    {created, {ok, Held}} = receive {created, _} = Created -> Created after 5000 -> timeout end,
    ?assert(erlang:monotonic_time(millisecond) - Started >= 1000),
    HeldId = erx_domain:id(Held),
    ?assertMatch({create, #{id := HeldId}}, next_call()),
    _ = [next_call() || _ <- [open_side, export, start]],
    ok = erx_domain:stop(Held, shutdown),
    retired(HeldId).

%% The names of the next N sessions the library refused, past its other calls.
refused_names(0) ->
    [];
refused_names(N) ->
    case next_call() of
        {refused, 0, Name, _Pid} -> [Name | refused_names(N - 1)];
        _ -> refused_names(N)
    end.

%% The library calls up to domain Id's retire.
retired(Id) ->
    case next_call() of
        {retire, Id} -> ok;
        _ -> retired(Id)
    end.

service_end_ends_domain_pids() ->
    %% The service's end ends every domain pid with its reason: no domain
    %% outlives the system domain, so the pid has nothing left to stop.
    {ok, Domain} = erx_domain:create(#{boot => <<"base">>, name => <<"last">>, memory => 4096}),
    Id = erx_domain:id(Domain),
    ?assertMatch({create, #{id := Id}}, next_call()),
    ?assertEqual({open_side, Id, 'last@erxos', Id * 10}, next_call()),
    ?assertEqual({export, Id, [send]}, next_call()),
    ?assertEqual({start, Id}, next_call()),
    Pid = erx_domain:pid(Domain),
    Ref = monitor(process, Pid),
    %% An exit message forged in the service's name while it lives ends nothing.
    Service = whereis(erx_domain_srv),
    Pid ! {'EXIT', Service, {domain_down, Id, {halt, 0}}},
    ?assertEqual(timeout, receive {'DOWN', Ref, process, _, Forged} -> Forged after 200 -> timeout end),
    exit(Service, kill),
    ?assertEqual(killed, receive {'DOWN', Ref, process, _, Reason} -> Reason after 2000 -> timeout end).


%% The inspection agent a ready report names is kept only when the reporting
%% incarnation owns it, its node the domain's and its creation the domain's id
%% (docs/design-live.md, "The runtime agent"): a pid of another domain, one with the
%% domain's creation on another domain's node, and any other value leave the domain
%% without one, logged and counted; a report that names none leaves it without one,
%% uncounted.
inspect_agent_of_another_incarnation_test() ->
    Own = erx_domain_fake_lib:agent(<<"own">>, 16),
    Cases = [{#{inspect => Own}, Own, 0},
             {#{inspect => erx_domain_fake_lib:agent(<<"own">>, 5)}, none, 1},
             {#{inspect => erx_domain_fake_lib:agent(<<"a">>, 16)}, none, 1},
             {#{inspect => self()}, none, 1},
             {#{inspect => undefined}, none, 1},
             {#{}, none, 0}],
    [begin
         Ref = make_ref(),
         Pid = erx_domain_pid:start_link(self(), 16, 'own@erxos', Ref),
         Pid ! {erx_origin, 16, {erx_ready, Named#{connections => Own}}},
         Got = receive {domain_ready, Ref, 16, #{}, Inspect} -> Inspect after 5000 -> timeout end,
         Tag = make_ref(),
         Pid ! {Ref, info, {self(), Tag}},
         Info = receive {Tag, Reply} -> Reply after 5000 -> timeout end,
         unlink(Pid),
         exit(Pid, kill),
         ?assertEqual({Named, Kept, {ok, #{connections => Own, inspect => Kept, dropped => Dropped}}},
                      {Named, Got, Info})
     end || {Named, Kept, Dropped} <- Cases].

%% The inspect view (erx_domain_core:inspect_view/2): scope `all` gives every
%% living domain with its agent or `none` and the service's name, principal
%% and state, and every kept death `ended`; a principal's gives its own only;
%% a kept death of an id that lives again is listed living, never ended.
inspect_view_test() ->
    Agent = self(),
    Domain = fun(Principal, Inspect, Name, Life) ->
                     #{principal => Principal, inspect => Inspect, name => erx_ident:new(Name), state => Life}
             end,
    State = #{domains => #{9 => Domain(1, Agent, <<"web">>, ready),
                           11 => Domain(2, none, <<"tty">>, built)},
              deaths => #{1 => [#{id => 8}, #{id => 9}], 2 => [#{id => 10}]}},
    Nine = {9, Agent, #{name => <<"web">>, principal => 1, state => running}},
    Eleven = {11, none, #{name => <<"tty">>, principal => 2, state => booting}},
    ?assertEqual([{8, ended, none}, Nine, {10, ended, none}, Eleven], erx_domain_core:inspect_view(all, State)),
    ?assertEqual([{8, ended, none}, Nine], erx_domain_core:inspect_view({principal, 1}, State)),
    ?assertEqual([{10, ended, none}, Eleven], erx_domain_core:inspect_view({principal, 2}, State)),
    ?assertEqual([], erx_domain_core:inspect_view({principal, 3}, State)).

%% Each life a domain passes through has the schema's state for it.
inspect_view_states_test() ->
    Of = fun(Life) ->
                 State = #{domains => #{9 => #{principal => 1, inspect => none, name => erx_ident:new(<<"d">>),
                                               state => Life}}, deaths => #{}},
                 [{9, none, #{state := Seen}}] = erx_domain_core:inspect_view(all, State),
                 Seen
         end,
    ?assertEqual([booting, booting, booting, running, ending], [Of(L) || L <- [building, built, running, ready, stopping]]).

%% The code server's report (docs/design-live.md, "The code server") is taken once,
%% before the ready report: the first is passed to the service only when the reporting
%% incarnation owns the pid, node and creation both; a pid of another creation, one on
%% another node, and any other value are refused and counted, and so is every report
%% after the first.
code_agent_report_of_another_incarnation_test() ->
    Own = erx_domain_fake_lib:agent(<<"own">>, 16),
    Cases = [{Own, Own, 0},
             {erx_domain_fake_lib:agent(<<"own">>, 5), none, 1},
             {erx_domain_fake_lib:agent(<<"a">>, 16), none, 1},
             {undefined, none, 1}],
    [begin
         Ref = make_ref(),
         Pid = erx_domain_pid:start_link(self(), 16, 'own@erxos', Ref),
         Pid ! {erx_origin, 16, {erx_code_agent, Named}},
         Pid ! {erx_origin, 16, {erx_code_agent, Own}},
         Pid ! {erx_origin, 16, {erx_ready, #{connections => Own}}},
         Got = receive {domain_code_agent, Ref, 16, Agent} -> Agent after 200 -> none end,
         receive {domain_ready, Ref, 16, _, _} -> ok after 5000 -> error(no_ready) end,
         Tag = make_ref(),
         Pid ! {Ref, info, {self(), Tag}},
         {ok, #{dropped := Dropped}} = receive {Tag, Reply} -> Reply after 5000 -> timeout end,
         unlink(Pid),
         exit(Pid, kill),
         ?assertEqual({Named, Kept, Expected + 1}, {Named, Got, Dropped})
     end || {Named, Kept, Expected} <- Cases].
