%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The cases of erx_usb_bus_core (docs/design-usb.md, "Ports, hubs and devices: the bus
%% core", "Hubs", "A function's end" and the bus core's row of "Host tests of the
%% cores"): the core explored to a fixed point against a simulated bus of a root hub of
%% two ports, one external hub of two ports and devices of one and two functions, whose
%% functions may end; then traces of 1,000 attach and detach cycles on one port, a
%% connection storm, a hub detached during its child's enumeration, a chain of six hubs,
%% four connects on one port within a minute, a function's restarts within a minute,
%% a hub function's restart and a device replugged between a read and its clear;
%% over-current changes read on a root port; and a port's failure logged.
%% World places are routes from the root.
%%
%% The simulation is the test's own model of the hardware and the processes around the
%% core: every port's connection, enable, power and latched change bits; the port
%% operations, commands and hub reports in flight; and the slots the controller handed
%% out; and each function's run, its pipes' resets in flight and its ends. Each
%% transition checks the design's invariants against that model and the
%% actions, not against the core's own bookkeeping:
%% * at most one port is between its reset and its device's address answer (the
%%   address-zero window), and a reset is never issued while another port's window is
%%   open; a failed address keeps the window until its answer;
%% * a connection change read on an occupied port detaches the occupant first;
%% * every slot handed out belongs to a device the core still holds, and a detached
%%   device's reference is gone and named by no later action: an enumeration names a
%%   reference above every one enumerated before, a port reset's included;
%% * a hub has at most one port operation in flight, and `handled` goes only to the hub
%%   function whose report is outstanding;
%% * no status read reaches a hub's port before its power-good time has passed since
%%   its last power-on answer;
%% * at most one simulated device is enabled and not yet addressed;
%% * no reset names a port that is off or empty;
%% * Address Device names the device's place in the world as its root port and route,
%%   at most five tiers below the root port;
%% * every answer a device has taken, delivered again once its step is left, the
%%   answer just taken among them, changes neither the core's state nor its actions;
%% * a function ended is started again only once every one of its pipes has answered
%%   `ok` to a reset since its end, its pipes reset one at a time; a failed reset
%%   detaches its device, and an end, a reset's answer or a detached device's
%%   function's end delivered again changes nothing;
%% * a function starts again as it was claimed, under a run number no earlier instance
%%   had, and every earlier instance's end, and a hub function's earlier instances'
%%   reports, delivered at any node, change nothing;
%% * a HID function's end as unusable is final: nothing is reset, started or detached,
%%   its run keeps the reason, the device's other functions are as they were, and any
%%   later end of it changes nothing, so a composite device keeps its other functions;
%% * a quiet bus, nothing in flight and no deadline pending, keeps every port empty
%%   exactly where nothing is connected, so no change, one latched between a status
%%   read and its clear included, is lost.
%% Times start at 2^40, so every integer at or above it in a state is a time; states are
%% compared with times taken relative to the clock and device references renumbered in
%% order, so equal situations at different times are one state. Every number is
%% written out here, so a constant changed in the module fails a case.
-module(erx_usb_bus_core_tests).

-include_lib("eunit/include/eunit.hrl").

-export([states/3, explored/3]).

-define(T0, (1 bsl 40)).
%% The depths explored, as connects or disconnects, failed answers and functions' ends
%% the environment may spend: three of the first carry a hub, a device behind it and the
%% hub's unplugging; two and a failure carry a failed address with another device
%% waiting for the turn; two and an end carry a hub function's restart with a device
%% behind it, or a function ending before its device is unplugged; one, a failure and
%% an end a failed reset; one and two ends a function ending twice, or two functions of
%% one device ending together, either of them unusable.
-define(DEPTHS, [{3, 0, 0}, {2, 1, 0}, {2, 0, 1}, {1, 1, 1}, {1, 0, 2}]).
%% Power-good times: the root's 10 units, the simulated hub's 50, each times 2 ms plus 20.
-define(ROOT_POWER_GOOD, 40).
-define(HUB_POWER_GOOD, 120).
%% A port's enumeration attempts: at most 3 in any 60 s.
-define(ATTEMPTS_MAX, 3).
-define(ATTEMPT_WINDOW, 60000).
%% A function's restarts: at most 3 in any 60 s.
-define(RESTARTS_MAX, 3).
-define(RESTART_WINDOW, 60000).
%% A function's ends as the bus process passes them on: a failed transfer, which counts
%% toward the restarts, and an interface the function cannot drive, which is final.
-define(FAILED, {shutdown, {transfer, stall}}).
-define(UNUSABLE, {shutdown, {unusable, no_usable_report}}).
%% A BOT function's end asking for its device's port to be reset, the top rung of its
%% recovery, which counts toward the restarts.
-define(RESET_PORT, {shutdown, {reset_port, reset_2, {transfer, stall}}}).
%% FreeBSD's power-up delay, which a port settles for before its attempt.
-define(POWER_UP_DELAY, 300).
%% wPortStatus's and wPortChange's connection and over-current bits.
-define(CONNECTION, 1).
-define(OVER_CURRENT, 8).

%% The exploration.

explored_to_a_fixed_point_test_() ->
    [{timeout, 600, fun() -> explored(Stimuli, Errors, Ends) end} || {Stimuli, Errors, Ends} <- ?DEPTHS].

%% The exploration at one depth, its size printed; the host test runs a seeded fault
%% at the smallest depth that catches it, every path of which a depth of ?DEPTHS
%% at least as deep in every count also takes.
explored(Stimuli, Errors, Ends) ->
    {ok, Seen} = states(Stimuli, Errors, Ends),
    io:format(user, "~nerx_usb_bus_core: ~b states, ~b connects or disconnects, ~b failed answers and ~b "
              "functions' ends deep~n", [Seen, Stimuli, Errors, Ends]).

%% The node after the bus's first step: the root hub powering its ports.
start(Stimuli, Errors, Ends) ->
    deliver(expired, (model0())#{stimuli := Stimuli, errors := Errors, ends := Ends}, erx_usb_bus_core:new(2)).

%% The number of states reachable with Stimuli connects or disconnects, Errors failed
%% answers and Ends functions' ends. A port's attempts throttle only its fourth within a
%% minute, which takes four connects at its place and the three disconnects between
%% them, since stimuli/1 moves a place only between a device and nothing; a function's
%% restarts refuse only its fourth end within a minute. With fewer stimuli and ends no
%% attempt or end time decides anything, so key/1 drops them.
states(Stimuli, Errors, Ends) when Stimuli < 2 * ?ATTEMPTS_MAX + 1, Ends < ?RESTARTS_MAX + 1 ->
    explore(start(Stimuli, Errors, Ends)).

explore(Start) ->
    explore([Start], #{key(Start) => true}).

explore([], Seen) ->
    {ok, map_size(Seen)};
explore([Node | Rest], Seen) ->
    Next = maps:from_list([{key(N), N} || Choice <- choices(Node), N <- [follow(Choice, Node)]]),
    New = maps:filter(fun(Key, _Node) -> not is_map_key(Key, Seen) end, Next),
    explore(maps:values(New) ++ Rest, maps:merge(Seen, maps:map(fun(_, _) -> true end, New))).

%% A power-on answered longer ago than any hub's power-good time is as good as any
%% older one, so its time is clamped and the key stays finite as time passes; attempt
%% and end times decide nothing at the depths explored (states/3) and are dropped. The
%% answers each device has taken are dropped too: each is checked to change nothing, and
%% so decides nothing after it.
key({Model = #{now := Now, powered := Powered, fns := Fns}, Core}) ->
    Clamped = maps:map(fun(_Hub, At) -> max(At, Now - 1000) end, Powered),
    Untimed = #{K => Fn#{ended := []} || K := Fn <- Fns},
    canon({maps:without([last, answered], Model#{powered := Clamped, fns := Untimed}), without_times(Core)}, Now).

%% The core's state with every port's attempt times and every function's end times
%% emptied: the one place the test reads the core's representation rather than its
%% exported views.
without_times(Core = #{hubs := Hubs, devices := Devices}) ->
    Core#{hubs := #{Id => Hub#{histories := #{N => History#{attempts := []} || N := History <- Histories}}
                    || Id := Hub = #{histories := Histories} <- Hubs},
          devices := #{Ref => Device#{runs := #{I => Run#{ends := []} || I := Run <- Runs}}
                       || Ref := Device = #{runs := Runs} <- Devices}}.

%% The simulated bus.

model0() ->
    #{now => ?T0, deadline => none,
      world => #{[1] => port0(), [2] => port0()},
      hubs => #{}, ops => #{}, cmds => [], slots => #{}, things => #{}, seen => #{}, addressed_at => #{},
      powered => #{}, window => none, answered => #{}, fns => #{}, resets => [], last_ref => none,
      stimuli => 0, errors => 0, ends => 0}.

port0() -> #{thing => none, chg => [], enabled => false, addressed => false, powered => false, signaled => false}.

%% The choices the environment has in a node. It answers what is in flight, the
%% devices' requests included, in one fixed order, the first of them only,
%% which keeps two devices' lifecycles from multiplying into each other; reports and
%% port events arrive in any state; any answer may fail, the next deadline may pass
%% first, so an answer can come after its deadline or never, and anything may be
%% connected or disconnected, and any running function may end, at any point.
%%
%% Fixing the order of the successful answers loses no reachable situation, because
%% answers to different hubs and devices commute in the core's state: the core decides
%% on the state when an answer arrives, not when its request was issued, and so does
%% the model's hardware; an answer touches only its own hub's ports or its own device's
%% port, except that a detach makes the other's answer stale, which the core ignores
%% whichever comes first, and that an answer releasing the turn lets the same step
%% grant it on another hub, to the port the arrival order names whichever answer
%% released it; and the turn is granted in the arrival order the settling
%% deadlines set, and the model's clock moves only at a deadline, so answers reordered
%% between two deadlines set the same times. What the fixed order would hide, an answer
%% held back while others overtake it, the interleaved failures, deadlines and
%% stimuli reach instead.
%%
%% Once the environment has spent its connects, disconnects and failures, the first answer,
%% when it is one
%% to a device's request after its address settle is taken alone when the device
%% still sits, enabled, at its place, with no connection change latched there or at
%% any place above it (a partial-order reduction: the answer is the node's only
%% choice, and every other choice waits until it is taken). Such an answer is
%% independent of every other choice the node or any node after it can offer:
%% * it reads and writes only its device's port, its device and, at the last
%%   step, the hub it adds under its own reference; it reads no time, since a step
%%   after the settle has no deadline and the settle check passes at any later
%%   time; and it neither takes nor releases the turn, so the turn's grant and
%%   every other hub's next operation and deadline are the same either side of it;
%% * the choices left are other answers, hub reports and deadlines: a report only
%%   marks ports to read, a deadline only moves ports that are timed, which a port
%%   past its settle is not, and a status read of the device's port or of a port
%%   above it finds nothing that moves the port, since its connection, enable and
%%   presence agree with the port's state and only a stimulus, now spent, could
%%   latch a change there;
%% * no choice can make its answer fail or its device go: that takes a stimulus,
%%   a failed answer, a latched connection change or a hub function's ends, and
%%   none is left.
%% So the two orders of the answer and any other choice reach the same node, the
%% invariants checked at each step do not depend on which step of its walk a
%% device past its address is at, and a device's walk is finite, so no choice is
%% postponed forever. While a stimulus or a failure is left, every interleaving of
%% a device's steps with it is explored.
choices(Node = {M, _Core}) ->
    {Ready, Failed} = environment(Node),
    [check_quiet_agreement(Node) || Ready =:= [], expiry(M) =:= []],
    {Answers, Reports} = lists:partition(fun({Kind, _}) -> Kind =:= core end, Ready),
    First = lists:sublist(Answers, 1),
    case lists:any(fun(A) -> taken_alone(A, Node) end, First) of
        true -> First;
        false -> First ++ Reports ++ Failed ++ expiry(M) ++ stimuli(M) ++ finishes(M)
    end.

%% Whether the first answer is one choices/1 may take alone. Only the first is, so a
%% node offers a subset of what it offers with more connects, failures or ends to spend.
taken_alone({core, {Kind, Ref, _Step, _Result}},
            {M = #{stimuli := 0, errors := 0, ends := 0, things := Things}, Core})
  when Kind =:= control_done; Kind =:= evaluated; Kind =:= endpoints_configured ->
    case {maps:find(Ref, erx_usb_bus_core:devices(Core)), maps:find(Ref, Things)} of
        {{ok, _Device}, {ok, {Place, Thing}}} -> undisturbed(Place, Thing, M);
        _Gone -> false
    end;
taken_alone(_Choice, _Node) ->
    false.

%% The device Thing sits enabled at Place, and no place from the root to it has a
%% connection change latched.
undisturbed(Place, Thing, #{world := World}) ->
    Above = [lists:sublist(Place, I) || I <- lists:seq(1, length(Place))],
    case maps:get(Place, World, none) of
        #{thing := Thing, enabled := true} ->
            lists:all(fun(P) -> not lists:member(connection, maps:get(chg, maps:get(P, World, port0()))) end,
                      Above);
        _ -> false
    end.

%% What the environment can deliver now, in its fixed order, and the failures it may
%% deliver instead.
environment({M, _Core}) ->
    All = answers(M) ++ commands(M) ++ resets(M) ++ reports(M),
    {[C || C = {Kind, _} <- All, Kind =/= core_error], [C || C = {core_error, _} <- All]}.

answers(M = #{ops := Ops, errors := Errors}) ->
    lists:append([[{core, {port_done, H, T, answer(H, T, Op, M)}}]
                  ++ [{core_error, {port_done, H, T, {error, stall}}} || Errors > 0, H =/= root, live(H, M)]
                  || H := {T, Op} <- Ops]).

%% The controller's commands and the devices' control transfers in flight, one per
%% device, each answered as the controller and the device on its place would.
commands(M = #{cmds := Cmds, errors := Errors}) ->
    lists:append([[{core, {Kind, Ref, Step, command_answer(Kind, Ref, Request, M)}}]
                  ++ [{core_error, {Kind, Ref, Step, {error, transaction}}} || Errors > 0]
                  || {Kind, Ref, Step, Request} <- Cmds]).

%% The resets of ended functions' pipes in flight, each answered `ok` while its device
%% lasts and `gone` once the controller has dropped the device's reference.
resets(#{resets := Resets, things := Things, errors := Errors}) ->
    lists:append([[{core, {pipe_reset, Ref, I, A, case is_map_key(Ref, Things) of
                                                     true -> ok;
                                                     false -> {error, gone}
                                                 end}}]
                  ++ [{core_error, {pipe_reset, Ref, I, A, {error, stall}}} || Errors > 0]
                  || {Ref, I, A} <- Resets]).

%% Every running function's end, while the environment has ends to spend: failed, or,
%% for a HID function, unusable; the hub function, whose hub descriptor the core read
%% before starting it, ends only failed.
finishes(#{ends := 0}) -> [];
finishes(#{fns := Fns}) ->
    [{finish, Ref, I, How} || {Ref, I} := #{state := running, driver := Driver} <- Fns, How <- ends_of(Driver)].

ends_of(erx_usb_hub) -> [failed];
ends_of(_Driver) -> [failed, unusable, reset_port].

%% Every reason an end may carry, for the ends delivered as stale.
end_reasons() -> [?FAILED, ?UNUSABLE, ?RESET_PORT].

runs(Ref, Core) ->
    maps:get(runs, maps:get(Ref, erx_usb_bus_core:devices(Core))).

command_answer(Kind, _Ref, none, #{slots := Slots}) when Kind =:= slot; Kind =:= addressed ->
    {ok, free_slot(Slots)};
command_answer(control_done, Ref, Setup, #{things := Things, world := World}) ->
    case maps:find(Ref, Things) of
        {ok, {Place, Thing}} ->
            case maps:get(Place, World, none) of
                #{thing := Thing, enabled := true} -> device_answer(Thing, Setup);
                _UnpluggedOrReplaced -> {error, timeout}
            end;
        error ->
            %% Detached: the controller dropped its reference, so its pipe answers gone.
            {error, gone}
    end;
command_answer(_EvaluatedOrConfigured, _Ref, none, _M) ->
    ok.

%% The devices: dev1 a full-speed HID device whose EP0 takes 64 bytes, dev2 a
%% high-speed device of two HID interfaces, and a high-speed single-TT hub of two
%% ports; each answers a request by the bytes it holds, cut to the length asked.
device_answer(Thing, Setup = <<_:6/binary, Length:16/little>>) ->
    Bytes = case request_name(Setup) of
                Device when Device =:= device_head; Device =:= device -> device_bytes(Thing);
                Config when Config =:= config_head; Config =:= configuration -> config_bytes(Thing);
                hub_descriptor -> erx_usb_desc_tests:hub(2, 0, 50);
                set_configuration -> <<>>
            end,
    {ok, binary:part(Bytes, 0, min(Length, byte_size(Bytes)))}.

%% The requests the devices understand, by their setup packets written out; any other
%% fails the case.
request_name(<<16#80, 6, 0, 1, 0:16, 8:16/little>>) -> device_head;
request_name(<<16#80, 6, 0, 1, 0:16, 18:16/little>>) -> device;
request_name(<<16#80, 6, 0, 2, 0:16, 9:16/little>>) -> config_head;
request_name(<<16#80, 6, 0, 2, 0:16, _:16>>) -> configuration;
request_name(<<0, 9, 1, 0, 0:16, 0:16>>) -> set_configuration;
request_name(<<16#a0, 6, 0, 16#29, 0:16, 7:16/little>>) -> hub_descriptor.

device_bytes(hub) -> erx_usb_desc_tests:device(9, 0, 1);
device_bytes(_Device) -> erx_usb_desc_tests:device(0, 0, 0).

config_bytes(dev1) ->
    erx_usb_desc_tests:configuration([erx_usb_desc_tests:interface(0, 0, 3, 0, 0),
                                      erx_usb_desc_tests:endpoint(16#81, 3, 8, 10)]);
config_bytes(dev2) ->
    erx_usb_desc_tests:configuration([erx_usb_desc_tests:interface(0, 0, 3, 0, 0),
                                      erx_usb_desc_tests:endpoint(16#81, 3, 8, 10),
                                      erx_usb_desc_tests:interface(1, 0, 3, 0, 0),
                                      erx_usb_desc_tests:endpoint(16#82, 3, 8, 10)]);
config_bytes(hub) ->
    erx_usb_desc_tests:configuration([erx_usb_desc_tests:interface(0, 0, 9, 0, 0),
                                      erx_usb_desc_tests:endpoint(16#81, 3, 1, 12)]).

%% The requests and commands each device must see from its address on, in order, and
%% its functions and hub fields once configured.
expected_steps(dev1) -> [device_head, ep0_packet, device, config_head, configuration, set_configuration,
                         configure_endpoints];
expected_steps(dev2) -> [device, config_head, configuration, set_configuration, configure_endpoints];
expected_steps(hub) -> [device, config_head, configuration, set_configuration, hub_descriptor,
                        configure_endpoints].

expected_pipes(dev2) -> 2;
expected_pipes(_Dev1OrHub) -> 1.

expected_hub_fields(hub) -> #{ports => 2, think_time => 0, multi_tt => false};
expected_hub_fields(_Device) -> none.

%% Each hub function with no report outstanding: its first report names every port and
%% the hub, a later one the ports whose change bits are set.
reports(M = #{hubs := Hubs, world := World}) ->
    [{report, {changed, Ref, Named, Instance, {fn, Ref, Instance}}}
     || Ref := #{route := Route, first := First, outstanding := false, running := true, instance := Instance} <- Hubs,
        Named <- [named(First, [N || N <- [1, 2], maps:get(chg, maps:get(Route ++ [N], World, port0())) =/= []])],
        Named =/= []]
        ++ root_events(M).

named(true, _Changed) -> [1, 2, hub];
named(false, Changed) -> Changed.

root_events(#{world := World}) ->
    [{signal, {port_event, N}} || N <- [1, 2], #{chg := [_ | _], signaled := false} <- [maps:get([N], World)]].

expiry(#{deadline := none}) -> [];
expiry(#{deadline := At}) -> [{expire, At}].

stimuli(#{stimuli := 0}) ->
    [];
stimuli(#{world := World}) ->
    HubPresent = lists:any(fun(#{thing := T}) -> T =:= hub end, maps:values(World)),
    [{stimulus, Where, New}
     || Where := #{thing := Thing} <- World,
        New <- case Thing of
                   none -> [dev1, dev2] ++ [hub || length(Where) =:= 1, not HubPresent];
                   _ -> [none]
               end].

live(root, _M) -> true;
live(H, #{hubs := Hubs}) -> is_map_key(H, Hubs).

free_slot(Slots) -> hd(lists:seq(1, 16) -- maps:values(Slots)).

%% The place of port N of hub H in the world: its route from the root; `gone` for a hub
%% the model no longer holds.
where(root, N, _M) ->
    [N];
where(H, N, #{hubs := Hubs}) ->
    case Hubs of
        #{H := #{route := Route}} -> Route ++ [N];
        #{} -> gone
    end.

%% A live port operation's answer from the world; an operation on a hub already gone
%% is answered as its pipe would be.
answer(H, T, Op, M) ->
    case live(H, M) andalso (T =:= hub orelse is_map_key(where(H, T, M), maps:get(world, M))) of
        true -> world_answer(H, T, Op, M);
        false -> {error, gone}
    end.

world_answer(_H, hub, get_status, _M) ->
    {ok, <<0:16, 0:16>>};
world_answer(H, N, get_status, M = #{world := World}) ->
    #{thing := Thing, chg := Chg, enabled := Enabled, powered := Powered} = maps:get(where(H, N, M), World),
    Status = bit(Thing =/= none, 1) bor bit(Enabled, 2) bor bit(Powered, 256)
        bor bit(H =/= root andalso (Thing =:= dev2 orelse Thing =:= hub), 1024),
    Change = lists:sum([maps:get(C, #{connection => 1, enabled => 2, reset => 16}) || C <- Chg]),
    Words = <<Status:16/little, Change:16/little>>,
    case H of
        root -> {ok, Words, root_speed(Thing)};
        _ -> {ok, Words}
    end;
world_answer(_H, _T, _Op, _M) ->
    ok.

bit(true, Mask) -> Mask;
bit(false, _Mask) -> 0.

root_speed(dev1) -> 1;
root_speed(_HighOrNone) -> 3.

%% One choice taken: the world moves, then the core steps when the choice reaches it.
follow({stimulus, Where, New}, {M = #{world := World, stimuli := S}, Core}) ->
    Port = #{thing := Old, chg := Chg} = maps:get(Where, World),
    Moved = World#{Where := Port#{thing := New, enabled := false, addressed := false,
                                  chg := ordsets:add_element(connection, Chg)}},
    Downstream = case {Old, New} of
                     {hub, none} -> maps:filter(fun(P, _) -> not lists:prefix(Where, P) orelse P =:= Where end, Moved);
                     {_, hub} -> Moved#{Where ++ [1] => port0(), Where ++ [2] => port0()};
                     _ -> Moved
                 end,
    {M#{world := Downstream, stimuli := S - 1}, Core};
follow({expire, At}, {M = #{now := Now}, Core}) ->
    At > Now orelse error({deadline_not_in_the_future, At - Now}),
    deliver(expired, M#{now := At}, Core);
follow({signal, Event = {port_event, N}}, {M = #{world := World}, Core}) ->
    deliver(Event, M#{world := World#{[N] := (maps:get([N], World))#{signaled := true}}}, Core);
follow({report, Event = {changed, Ref, _, _, _}}, {M = #{hubs := Hubs}, Core}) ->
    Fn = maps:get(Ref, Hubs),
    deliver(Event, M#{hubs := Hubs#{Ref := Fn#{first := false, outstanding := true}}}, Core);
%% A function's end as unusable: final, so nothing follows, neither a reset, a start nor
%% a detach; its run keeps the reason, and the device's other functions are as they were.
follow({finish, Ref, I, unusable}, {M = #{ends := E, fns := Fns}, Core}) ->
    Fn = #{run := Run} = maps:get({Ref, I}, Fns),
    Ending = M#{ends := E - 1, fns := Fns#{{Ref, I} := Fn#{state := unusable}}},
    Node = {#{last := Last}, After} = deliver({function_ended, Ref, I, Run, ?UNUSABLE}, Ending, Core),
    [] =:= [A || A <- Last, element(1, A) =/= deadline] orelse error({unusable_end_acted, Ref, I, Last}),
    #{I := Ended} = Runs = runs(Ref, After),
    maps:remove(I, Runs) =:= maps:remove(I, runs(Ref, Core)) orelse error({unusable_end_moved_another_function, Ref, I}),
    maps:get(state, Ended) =:= {unusable, no_usable_report} orelse error({unusable_reason_not_kept, Ref, I, Ended}),
    Node;
%% A function's failed end: its pipes' resets follow, or its device's detach past its
%% restarts. A hub function stops reporting until its next instance starts.
follow({finish, Ref, I, failed}, {M = #{ends := E, fns := Fns, hubs := Hubs, now := Now}, Core}) ->
    Fn = #{pipes := Pipes, ended := Ended, driver := Driver, run := Run} = maps:get({Ref, I}, Fns),
    Recent = [T || T <- Ended, Now - T < ?RESTART_WINDOW] ++ [Now],
    Stopped = case Driver of
                  erx_usb_hub -> Hubs#{Ref := (maps:get(Ref, Hubs))#{running := false, outstanding := false}};
                  _ -> Hubs
              end,
    Ending = M#{ends := E - 1, hubs := Stopped, fns := Fns#{{Ref, I} := Fn#{state := {ended, Pipes}, ended := Recent}}},
    Node = {#{last := Last}, _} = deliver({function_ended, Ref, I, Run, ?FAILED}, Ending, Core),
    Answered = case length(Recent) > ?RESTARTS_MAX of
                   true -> lists:member({detach, Ref}, Last);
                   false -> [A || {reset_pipe, R, J, A} <- Last, {R, J} =:= {Ref, I}] =/= []
               end,
    Answered orelse error({function_end_not_answered, Ref, I, Last}),
    Node;
%% A function's end asking for a port reset: its device's reference leaves the controller
%% and every function of the device stops, and its port settles to be reset in its turn,
%% or, past its restarts, is given up. Whatever comes back is enumerated under a fresh
%% reference (action/4's enable_slot checks it is above every earlier one), so the model
%% treats its configuration as a first start, the run numbers carried over aside.
follow({finish, Ref, I, reset_port}, {M = #{ends := E, fns := Fns, now := Now}, Core}) ->
    Fn = #{ended := Ended, run := Run} = maps:get({Ref, I}, Fns),
    Recent = [T || T <- Ended, Now - T < ?RESTART_WINDOW] ++ [Now],
    #{port := {H, N}} = maps:get(Ref, erx_usb_bus_core:devices(Core)),
    Ending = M#{ends := E - 1, fns := Fns#{{Ref, I} := Fn#{state := {ended, []}, ended := Recent}}},
    Node = {#{last := Last}, After} = deliver({function_ended, Ref, I, Run, ?RESET_PORT}, Ending, Core),
    lists:member({detach, Ref}, Last) orelse error({reset_port_end_not_answered, Ref, I, Last}),
    Port = maps:get({H, N}, erx_usb_bus_core:ports(After)),
    case {length(Recent) > ?RESTARTS_MAX, Port} of
        {true, {disabling, {function, I, {restarts, ?RESET_PORT}}, _}} -> ok;
        {false, {settling, _At}} -> ok;
        _ -> error({reset_port_end_left_port, Ref, I, Port})
    end,
    Node;
%% A pipe reset's answer: on `ok` the pipe is reset; a failure of a reset in flight must
%% detach its device.
follow({Kind, Event = {pipe_reset, Ref, I, A, Result}}, {M = #{fns := Fns, resets := Resets, errors := E}, Core})
  when Kind =:= core; Kind =:= core_error ->
    Spent = case Kind of
                core -> E;
                core_error -> E - 1
            end,
    {InFlight, Moved} = case maps:get({Ref, I}, Fns, none) of
                            Fn = #{state := {resetting, A, Left}} when Result =:= ok ->
                                {true, Fns#{{Ref, I} := Fn#{state := {ended, Left}}}};
                            #{state := {resetting, A, _Left}} ->
                                {true, Fns};
                            _NotInFlight ->
                                {false, Fns}
                        end,
    Answered = M#{fns := Moved, resets := lists:delete({Ref, I, A}, Resets), errors := Spent},
    Node = {#{last := Last}, _} = deliver(Event, Answered, Core),
    InFlight andalso Result =/= ok andalso not lists:member({detach, Ref}, Last)
        andalso error({failed_reset_kept_the_device, Ref, I, Last}),
    Node;
follow({core_error, Event}, {M = #{errors := E}, Core}) ->
    deliver(Event, consume(Event, M#{errors := E - 1}), Core);
follow({core, Event = {addressed, Ref, _Step, {ok, _}}}, {M = #{world := World}, Core}) ->
    Where = case maps:find(Ref, erx_usb_bus_core:devices(Core)) of
                {ok, #{port := {H, N}}} -> where(H, N, M);
                _Gone -> gone
            end,
    Addressed = case maps:find(Where, World) of
                    {ok, Port} ->
                        M#{world := World#{Where := Port#{addressed := true}}};
                    _ -> M
                end,
    deliver(Event, consume(Event, Addressed#{addressed_at := (map_get(addressed_at, Addressed))#{Ref => map_get(now, M)}}),
            Core);
follow({core, Event}, {M, Core}) ->
    deliver(Event, consume(Event, world_effect(Event, M)), Core).

consume({port_done, H, _T, _Result}, M = #{ops := Ops}) -> M#{ops := maps:remove(H, Ops)};
consume({Kind, Ref, Step, _Result}, M = #{cmds := Cmds})
  when Kind =:= slot; Kind =:= addressed; Kind =:= control_done; Kind =:= evaluated;
       Kind =:= endpoints_configured ->
    M#{cmds := [C || C = {K, R, S, _} <- Cmds, {K, R, S} =/= {Kind, Ref, Step}]};
consume(_Event, M) -> M.

%% What a successful port operation does to the simulated hardware.
world_effect({port_done, H, N, ok}, M = #{world := World, ops := Ops}) when is_integer(N) ->
    case {live(H, M), maps:find(where(H, N, M), World)} of
        {true, {ok, Port}} ->
            Op = element(2, maps:get(H, Ops)),
            Powered = case Op of
                          power_on -> (map_get(powered, M))#{H => map_get(now, M)};
                          _ -> map_get(powered, M)
                      end,
            M#{world := World#{where(H, N, M) := port_effect(Op, Port)}, powered := Powered};
        _ -> M
    end;
world_effect(_Event, M) ->
    M.

port_effect(power_on, Port) ->
    Port#{powered := true};
port_effect(reset, Port = #{thing := Thing, chg := Chg}) when Thing =/= none ->
    Port#{enabled := true, addressed := false, chg := ordsets:add_element(reset, Chg)};
port_effect(disable, Port) ->
    Port#{enabled := false};
port_effect({clear, C}, Port = #{chg := Chg, signaled := Signaled}) ->
    Left = ordsets:del_element(C, Chg),
    Port#{chg := Left, signaled := Signaled andalso Left =/= []};
port_effect(_Op, Port) ->
    Port.

deliver(Event, M, Core0) ->
    {Core, Actions} = erx_usb_bus_core:step(Event, maps:get(now, M), Core0),
    observe(Event, Actions, M, Core0, Core).

%% The checks, and the model's bookkeeping of the actions.

observe(Event, Actions, M0, Before, After) ->
    check_default_state(M0, Event),
    check_turn(After, Event),
    check_connection_detach(Event, Actions, Before),
    check_failure_logs(Event, Actions, Before, After),
    [stale({function_ended, Ref, I, Run, Reason}, maps:get(now, M0), After)
     || {detach, Ref} <- Actions, {R, I} := #{run := Run} <- maps:get(fns, M0), R =:= Ref, Reason <- end_reasons()],
    M1 = close_window(Event, M0, Before, After),
    M2 = lists:foldl(fun(Action, M) -> action(Action, M, Before, After) end,
                     M1#{deadline := none, last => Actions}, Actions),
    [is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({slot_of_gone_device, Ref, Event})
     || Ref := _ <- maps:get(slots, M2)],
    earlier_runs_stale(M2, After),
    {check_stale(Event, M2, After), After}.

%% A device's successful answer is kept while the device lasts, and every answer the
%% device has taken, this one included, is delivered again: each names a step the
%% device has left, so each must leave the state as it is and act on nothing.
check_stale(Event, M = #{answered := Answered, now := Now}, Core) ->
    repeated(Event, Now, Core),
    Devices = erx_usb_bus_core:devices(Core),
    case succeeded_answer(Event) of
        {ok, Ref} when is_map_key(Ref, Devices) ->
            History = [Event | maps:get(Ref, Answered, [])],
            lists:foreach(fun(Stale) -> stale(Stale, Now, Core) end, History),
            M#{answered := Answered#{Ref => History}};
        _NoneOrGone ->
            M
    end.

%% A function's end or a pipe reset's answer delivered again: the function is no
%% longer running, or the reset no longer in flight, so it changes nothing.
repeated(Event = {function_ended, _Ref, _I, _Run, _Reason}, Now, Core) -> stale(Event, Now, Core);
repeated(Event = {pipe_reset, _Ref, _I, _A, _Result}, Now, Core) -> stale(Event, Now, Core);
repeated(_Event, _Now, _Core) -> ok.

%% The end of every instance not running, and a hub function's reports from each, naming
%% every port and the hub, delivered at any node: the earlier instances', and an ended
%% instance's own while its pipes are still being reset. Each is stale, so it changes
%% nothing, however late it comes.
earlier_runs_stale(#{fns := Fns, now := Now}, Core) ->
    lists:foreach(fun(Stale) -> stale(Stale, Now, Core) end,
                  [Event || {Ref, I} := #{run := Run, state := State, driver := Driver} <- Fns,
                            Old <- lists:seq(1, last_not_running(Run, State)),
                            Event <- instance_events(Ref, I, Old, Driver)]).

last_not_running(Run, running) -> Run - 1;
last_not_running(Run, _Ended) -> Run.

instance_events(Ref, I, Run, erx_usb_hub) ->
    [{changed, Ref, [1, 2, hub], Run, {fn, Ref, Run}} | [{function_ended, Ref, I, Run, R} || R <- end_reasons()]];
instance_events(Ref, I, Run, _Driver) ->
    [{function_ended, Ref, I, Run, R} || R <- end_reasons()].

stale(Stale, Now, Core) ->
    case erx_usb_bus_core:step(Stale, Now, Core) of
        {Core, Actions} ->
            [] =:= [A || A <- Actions, element(1, A) =/= deadline] orelse error({stale_answer_acted, Stale, Actions});
        {_Changed, _Actions} ->
            error({stale_answer_changed_the_state, Stale})
    end.

%% The device an answer to its request names, when the answer succeeded.
succeeded_answer({Kind, Ref, _Step, Result})
  when Kind =:= slot; Kind =:= addressed; Kind =:= control_done; Kind =:= evaluated;
       Kind =:= endpoints_configured ->
    case Result of
        {error, _Reason} -> none;
        _Value -> {ok, Ref}
    end;
succeeded_answer(_Event) ->
    none.

%% The test's own notion of the address-zero window, from the design's port table.
in_window({resetting, _, _}) -> true;
in_window({recovering, _, _}) -> true;
in_window({enumerating, _, Step}) -> Step =:= enabling_slot orelse Step =:= addressing;
in_window({disabling, _, Held}) -> Held;
in_window(_) -> false.

%% The hardware's own count: at most one device enabled and not yet addressed, so at
%% most one answers address zero, whatever the core believes about its ports.
check_default_state(#{world := World}, Event) ->
    case [W || W := #{thing := T, enabled := true, addressed := false} <- World, T =/= none] of
        [_, _ | _] = Two -> error({two_devices_at_address_zero, Two, Event});
        _ -> ok
    end.

%% A quiet bus, nothing in flight and no deadline pending, waits for the world to
%% change, so every port it keeps must agree with the world: empty exactly where
%% nothing is connected. A change latched between a status read and its clear, which
%% the clear takes away unseen, leaves such a node disagreeing.
check_quiet_agreement({M = #{world := World}, Core}) ->
    [error({quiet_port_disagrees_with_the_world, {H, N}, State, Thing})
     || {H, N} := State <- erx_usb_bus_core:ports(Core),
        #{thing := Thing} <- [maps:get(where(H, N, M), World, absent)],
        (Thing =:= none) =/= (State =:= empty)].

check_turn(Core, Event) ->
    case [P || P := S <- erx_usb_bus_core:ports(Core), in_window(S)] of
        [_, _ | _] = Two -> error({two_ports_at_address_zero, Two, Event});
        _ -> ok
    end.

check_connection_detach({port_done, H, N, {ok, <<_:16, Change:16/little>>, _SpeedId}}, Actions, Before) ->
    connection_detach(H, N, Change, Actions, Before);
check_connection_detach({port_done, H, N, {ok, <<_:16, Change:16/little>>}}, Actions, Before) when N =/= hub ->
    connection_detach(H, N, Change, Actions, Before);
check_connection_detach(_Event, _Actions, _Before) ->
    ok.

connection_detach(H, N, Change, Actions, Before) when Change band 1 =/= 0 ->
    case maps:get({H, N}, erx_usb_bus_core:ports(Before), none) of
        {enumerating, Ref, _} -> first_detaches(Ref, Actions);
        {running, Ref} -> first_detaches(Ref, Actions);
        _ -> ok
    end;
connection_detach(_H, _N, _Change, _Actions, _Before) ->
    ok.

%% A port given up, moved into `disabling` or `disabled` from a state that is neither, is
%% logged once with its reason, and no other port is: only a connection change leaves
%% those states, so this is the design's one failure line per connection.
check_failure_logs(Event, Actions, Before, After) ->
    Was = erx_usb_bus_core:ports(Before),
    Expected = lists:sort([{log, H, N, {failed, Reason}}
                           || {H, N} := Port <- erx_usb_bus_core:ports(After), {failed, Reason} <- [failure(Port)],
                              failure(maps:get({H, N}, Was, off)) =:= none]),
    Logged = lists:sort([A || A = {log, _, _, {failed, _}} <- Actions]),
    Logged =:= Expected orelse error({failure_logs, Logged, Expected, Event}).

failure({disabling, Reason, _Held}) -> {failed, Reason};
failure({disabled, Reason}) -> {failed, Reason};
failure(_Port) -> none.

first_detaches(Ref, Actions = [{detach, _} | _]) ->
    lists:member({detach, Ref}, Actions) orelse error({occupant_kept, Ref, Actions});
first_detaches(Ref, Actions) ->
    error({connection_change_without_detach_first, Ref, Actions}).

%% A window opens with its port's reset and closes with its device's address answer,
%% or when the port leaves it by a failure, a detach or a connection change; it never
%% reaches a step past the address without the answer.
close_window(_Event, M = #{window := none}, _Before, _After) ->
    M;
close_window({addressed, Ref, _Step, _Result}, M = #{window := Window}, Before, After) ->
    case {maps:find(Ref, erx_usb_bus_core:devices(Before)), maps:get(Window, erx_usb_bus_core:ports(After), gone)} of
        {{ok, #{port := Window}}, {disabling, _, true}} -> M;
        {{ok, #{port := Window}}, _} -> M#{window := none};
        _ -> left(M, After)
    end;
close_window(_Event, M, _Before, After) ->
    left(M, After).

left(M = #{window := Window}, After) ->
    case maps:get(Window, erx_usb_bus_core:ports(After), gone) of
        {enumerating, _, Step} when Step =/= enabling_slot, Step =/= addressing ->
            error({window_closed_without_address_answer, Window});
        State ->
            case in_window(State) of
                true -> M;
                false -> M#{window := none}
            end
    end.

action({port, H, T, Op}, M = #{ops := Ops, now := Now, powered := Powered}, _Before, After) ->
    is_map_key(H, Ops) andalso error({two_operations_on_hub, H, Op}),
    Op =:= power_on andalso length(where(H, T, M)) > 6 andalso error({power_on_past_five_hub_tiers, H, T}),
    Opened = case {T, Op} of
                 {N, get_status} when is_integer(N) ->
                     Now >= maps:get(H, Powered, Now + 1) + power_good(H)
                         orelse error({read_before_power_good, H, N}),
                     M;
                 {N, reset} ->
                     {resetting, _, sent} = maps:get({H, N}, erx_usb_bus_core:ports(After)),
                     open_window({H, N}, M);
                 _ ->
                     M
             end,
    Opened#{ops := Ops#{H => {T, Op}}};
action({handled, H, From}, M = #{hubs := Hubs}, _Before, _After) ->
    case Hubs of
        #{H := Fn = #{outstanding := true, instance := Instance}} when From =:= {fn, H, Instance} ->
            M#{hubs := Hubs#{H := Fn#{outstanding := false}}};
        #{} -> error({handled_without_report, H, From})
    end;
action({enable_slot, Ref, Step}, M = #{cmds := Cmds, things := Things, world := World, last_ref := Last},
       _Before, After) ->
    Ref > Last orelse error({reference_reused, Ref, Last}),
    #{port := {H, N}} = maps:get(Ref, erx_usb_bus_core:devices(After)),
    Place = where(H, N, M),
    #{thing := Thing} = maps:get(Place, World, #{thing => gone}),
    M#{cmds := Cmds ++ [{slot, Ref, Step, none}], things := Things#{Ref => {Place, Thing}}, last_ref := Ref};
%% A low- or full-speed device behind the high-speed hub is served by the hub's
%% translator on its port; every other device by none.
action({address, Ref, Step, #{slot := Slot, root_port := RootPort, route := Tiers, tt := TT}},
       M = #{cmds := Cmds, slots := Slots, things := Things}, _Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({address_for_gone_device, Ref}),
    #{port := {H, N}} = maps:get(Ref, erx_usb_bus_core:devices(After)),
    [RootPort | Tiers] =:= where(H, N, M) orelse error({address_route_not_the_place, Ref, RootPort, Tiers}),
    length(Tiers) =< 5 orelse error({route_past_five_tiers, Ref, Tiers}),
    %% The speed the core saw may be a device's since replaced on the place, so only a
    %% translator named is checked against the hub's slot and the device's port.
    Expected = case {H, maps:get(Ref, Things)} of
                   {root, _} -> [none];
                   {_, {_, dev1}} -> [#{hub_slot => maps:get(H, Slots), port => N, multi => false}];
                   {_, _} -> [none, #{hub_slot => maps:get(H, Slots), port => N, multi => false}]
               end,
    lists:member(TT, Expected) orelse error({wrong_translator, Ref, TT, Expected}),
    M#{cmds := Cmds ++ [{addressed, Ref, Step, none}], slots := Slots#{Ref => Slot}};
action({control, Ref, Step, Setup, Data}, M = #{cmds := Cmds}, _Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({request_for_gone_device, Ref}),
    Expected = case Setup of
                   <<16#80:8, _:40, Length:16/little>> -> {in, Length};
                   <<16#a0:8, _:40, Length:16/little>> -> {in, Length};
                   <<_:48, 0:16>> -> none
               end,
    Data =:= Expected orelse error({data_stage_not_the_setups, Setup, Data}),
    settled(Ref, M),
    saw(Ref, request_name(Setup), M#{cmds := Cmds ++ [{control_done, Ref, Step, Setup}]});
action({evaluate_context, Ref, Step, Context}, M = #{cmds := Cmds}, _Before, _After) ->
    Context =:= #{ep0_packet => 64} orelse error({wrong_ep0_packet, Ref, Context}),
    saw(Ref, ep0_packet, M#{cmds := Cmds ++ [{evaluated, Ref, Step, none}]});
action({configure_endpoints, Ref, Step, #{add := Pipes, hub := HubFields}}, M = #{cmds := Cmds, things := Things},
       _Before, _After) ->
    {_, Thing} = maps:get(Ref, Things),
    {length(Pipes), HubFields} =:= {expected_pipes(Thing), expected_hub_fields(Thing)}
        orelse error({wrong_endpoints, Ref, Pipes, HubFields}),
    saw(Ref, configure_endpoints, M#{cmds := Cmds ++ [{endpoints_configured, Ref, Step, none}]});
action({start, Ref, Functions}, M = #{fns := Fns}, _Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(After)) orelse error({start_for_gone_device, Ref}),
    case [I || {#{interface := I}, _Run} <- Functions, is_map_key({Ref, I}, Fns)] of
        [] -> first_start(Ref, Functions, M, After);
        Restarted -> restart(Ref, Restarted, Functions, M)
    end;
%% Each of an ended function's pipes is reset once, one at a time.
action({reset_pipe, Ref, I, A}, M = #{fns := Fns, resets := Resets}, _Before, _After) ->
    case maps:get({Ref, I}, Fns, none) of
        Fn = #{state := {ended, Left}} ->
            lists:member(A, Left) orelse error({reset_of_a_pipe_not_left_to_reset, Ref, I, A}),
            M#{fns := Fns#{{Ref, I} := Fn#{state := {resetting, A, lists:delete(A, Left)}}},
               resets := Resets ++ [{Ref, I, A}]};
        Other ->
            error({reset_pipe_of_a_function_not_ended, Ref, I, Other})
    end;
action({detach, Ref}, M = #{slots := Slots, things := Things, hubs := Hubs, seen := Seen, fns := Fns}, Before, After) ->
    is_map_key(Ref, erx_usb_bus_core:devices(Before)) orelse error({detached_twice, Ref}),
    is_map_key(Ref, erx_usb_bus_core:devices(After)) andalso error({reference_kept, Ref}),
    M#{slots := maps:remove(Ref, Slots), things := maps:remove(Ref, Things), hubs := maps:remove(Ref, Hubs),
       seen := maps:remove(Ref, Seen), addressed_at := maps:remove(Ref, map_get(addressed_at, M)),
       answered := maps:remove(Ref, map_get(answered, M)),
       fns := maps:filter(fun({R, _I}, _Fn) -> R =/= Ref end, Fns)};
action({log, _H, _N, over_current}, M, _Before, _After) ->
    M;
action({log, _H, _N, {failed, _Reason}}, M, _Before, _After) ->
    M;
action({deadline, At}, M, _Before, _After) ->
    M#{deadline := At}.

%% A device's functions started at its configuration, after the steps its kind needs,
%% each running.
first_start(Ref, Functions, M = #{hubs := Hubs, things := Things, seen := Seen, fns := Fns}, After) ->
    #{port := {H, N}} = maps:get(Ref, erx_usb_bus_core:devices(After)),
    {_, Thing} = maps:get(Ref, Things),
    lists:reverse(maps:get(Ref, Seen)) =:= expected_steps(Thing)
        orelse error({started_after_other_steps, Ref, Thing, maps:get(Ref, Seen)}),
    Runs = #{{Ref, I} => #{state => running, driver => Driver, pipes => [A || #{address := A} <- Pipes],
                           ended => [], run => Run, function => Function}
             || {Function = #{interface := I, driver := Driver, pipes := Pipes}, Run} <- Functions},
    Started = M#{fns := maps:merge(Fns, Runs)},
    case [{Driver, Run} || {#{driver := Driver}, Run} <- Functions] of
        [{erx_usb_hub, Run}] ->
            Started#{hubs := Hubs#{Ref => #{route => where(H, N, M), first => true, outstanding => false,
                                            running => true, instance => Run}}};
        _ ->
            Started
    end.

%% A function started again: alone, as it was claimed, with a run number no earlier
%% instance had, and only once every one of its pipes has answered a reset since its
%% end; a hub function's next instance reports every port first.
restart(Ref, [I], [{Function = #{interface := I}, Run}], M = #{fns := Fns, hubs := Hubs}) ->
    case maps:get({Ref, I}, Fns) of
        #{state := {ended, []}, run := Before, function := Claimed} when Run =< Before; Function =/= Claimed ->
            error({restart_not_a_new_instance_of_the_claim, Ref, I, Run, Before});
        Fn = #{state := {ended, []}, driver := Driver} ->
            Running = M#{fns := Fns#{{Ref, I} := Fn#{state := running, run := Run}}},
            case Driver of
                erx_usb_hub ->
                    Hub = maps:get(Ref, Hubs),
                    Running#{hubs := Hubs#{Ref := Hub#{first := true, outstanding := false, running := true,
                                                       instance := Run}}};
                _ ->
                    Running
            end;
        Other ->
            error({restarted_before_every_reset_answered, Ref, I, Other})
    end;
restart(Ref, Restarted, Functions, _M) ->
    error({restart_not_of_one_ended_function, Ref, Restarted, Functions}).

%% No request reaches a device within 10 ms of its address answer, FreeBSD's settle.
settled(Ref, #{now := Now, addressed_at := AddressedAt}) ->
    case AddressedAt of
        #{Ref := At} when Now < At + 10 -> error({request_before_address_settle, Ref, Now - At});
        #{} -> ok
    end.

%% The model's record of the requests and commands a device has seen, newest first.
saw(Ref, Name, M = #{seen := Seen}) ->
    M#{seen := Seen#{Ref => [Name | maps:get(Ref, Seen, [])]}}.

power_good(root) -> ?ROOT_POWER_GOOD;
power_good(_Ext) -> ?HUB_POWER_GOOD.

open_window(Port, #{window := Window}) when Window =/= none, Window =/= Port ->
    error({reset_with_window_open, Window, Port});
open_window(Port, M) ->
    M#{window := Port}.

%% The traces.

%% Drives the node by the first choice Allow takes, answers before deadlines, until
%% Stop holds or no choice is left; at most Steps steps.
drive(Node, Stop, Allow) ->
    drive(Node, Stop, Allow, 10000).

drive(Node, _Stop, _Allow, 0) ->
    error({drive_did_not_settle, Node});
drive(Node, Stop, Allow, Steps) ->
    case Stop(Node) of
        true ->
            Node;
        false ->
            {Ready, _Failed} = environment(Node),
            case [C || C <- Ready ++ expiry(element(1, Node)), Allow(C)] of
                [] -> Node;
                [Choice | _] -> drive(follow(Choice, Node), Stop, Allow, Steps - 1)
            end
    end.

settle(Node) -> drive(Node, fun(_) -> false end, fun(_) -> true end).

port_of({_M, Core}, Where) -> maps:get(Where, erx_usb_bus_core:ports(Core)).

trace_start() -> settle(start(1 bsl 30, 0, 1 bsl 30)).

%% A device attached to root port 1 runs, then is detached, leaving the port empty.
cycle(Node) ->
    Running = settle(follow({stimulus, [1], dev2}, Node)),
    ?assertMatch({running, _}, port_of(Running, {root, 1})),
    Gone = settle(follow({stimulus, [1], none}, Running)),
    ?assertEqual(empty, port_of(Gone, {root, 1})),
    ?assertEqual(#{}, erx_usb_bus_core:devices(element(2, Gone))),
    Gone.

cycles(Count, Node) -> lists:foldl(fun(_, Acc) -> cycle(Acc) end, Node, lists:seq(1, Count)).

%% From the fourth cycle on, the port's attempts repeat every three cycles, the first
%% of each three held until a minute after the attempt three before it, so the state
%% after the 1,000th cycle is the state after the fourth.
attach_and_detach_cycles_leave_nothing_behind_test_() ->
    {timeout, 300, fun() ->
        Fourth = {#{now := Now4}, Core4} = cycles(4, trace_start()),
        {#{now := Now}, Core} = cycles(996, Fourth),
        ?assertEqual(canon(Core4, Now4), canon(Core, Now))
    end}.

%% Three attempts on one port in a few seconds; the fourth connect settles within the
%% minute and is held in `settling` until the first attempt is a minute old, then
%% starts, and the port keeps only the three attempts within the window.
a_port_starts_at_most_three_attempts_a_minute_test() ->
    Three = cycles(3, trace_start()),
    #{{root, 1} := #{attempts := [A1, A2, A3]}} = erx_usb_bus_core:histories(element(2, Three)),
    Held = fun(Node) -> port_of(Node, {root, 1}) =:= {settling, A1 + ?ATTEMPT_WINDOW} end,
    {#{now := Now, deadline := Deadline}, _} = Node = drive(follow({stimulus, [1], dev2}, Three), Held,
                                                            fun(_) -> true end),
    ?assert(Held(Node)),
    ?assert(Now < A1 + ?ATTEMPT_WINDOW),
    ?assertEqual(A1 + ?ATTEMPT_WINDOW, Deadline),
    {_, Core} = Running = settle(Node),
    ?assertMatch({running, _}, port_of(Running, {root, 1})),
    #{{root, 1} := #{attempts := Attempts}} = erx_usb_bus_core:histories(Core),
    ?assertEqual([A2, A3, A1 + ?ATTEMPT_WINDOW], Attempts).

%% Over-current changes on a root port: each is counted and the first is logged, the
%% next only counted, a connection change read with one included, until the port's
%% next attempt starts 300 ms later; the first after it is logged again.
over_current_changes_are_logged_once_per_attempt_test() ->
    {#{now := Now}, Core0} = trace_start(),
    Log = [{log, root, 1, over_current}],
    {Logged1, Core1} = root_read(?OVER_CURRENT, ?OVER_CURRENT, Now, Core0),
    {Logged2, Core2} = root_read(?OVER_CURRENT, ?OVER_CURRENT, Now, Core1),
    {Logged3, Core3} = root_read(?CONNECTION bor ?OVER_CURRENT, ?CONNECTION bor ?OVER_CURRENT, Now, Core2),
    ?assertMatch(#{{root, 1} := {settling, _}}, erx_usb_bus_core:ports(Core3)),
    Started = Now + 300,
    {Core4, Reset} = erx_usb_bus_core:step(expired, Started, Core3),
    ?assert(lists:member({port, root, 1, reset}, Reset)),
    {Core5, _} = erx_usb_bus_core:step({port_done, root, 1, ok}, Started, Core4),
    {Logged4, Core6} = root_read(?CONNECTION bor ?OVER_CURRENT, ?OVER_CURRENT, Started, Core5),
    {Logged5, Core7} = root_read(?CONNECTION bor ?OVER_CURRENT, ?OVER_CURRENT, Started, Core6),
    ?assertEqual([Log, [], [], Log, []], [Logged1, Logged2, Logged3, Logged4, Logged5]),
    ?assertMatch(#{{root, 1} := #{over_current_changes := 5}}, erx_usb_bus_core:histories(Core7)).

%% Root port 1 of an idle bus signals, its status read answers Status and Change, and
%% each change bit is cleared in turn, after which the port is read again and shows Status
%% with no change; the over-current log actions of all of it and the state after.
root_read(Status, Change, Now, Core0) ->
    {Core1, [{port, root, 1, get_status} | _]} = erx_usb_bus_core:step({port_event, 1}, Now, Core0),
    {Core2, Actions} = erx_usb_bus_core:step({port_done, root, 1, {ok, <<Status:16/little, Change:16/little>>, 3}},
                                             Now, Core1),
    cleared(Status, Actions, Now, Core2, [A || A = {log, _, _, over_current} <- Actions]).

cleared(Status, Actions, Now, Core, Logged) ->
    Answer = case [Op || {port, root, 1, Op} <- Actions] of
                 [] -> none;
                 [{clear, _}] -> ok;
                 [get_status] -> {ok, <<Status:16/little, 0:16>>, 3}
             end,
    case Answer of
        none ->
            {Logged, Core};
        _ ->
            {Next, More} = erx_usb_bus_core:step({port_done, root, 1, Answer}, Now, Core),
            cleared(Status, More, Now, Next, Logged ++ [A || A = {log, _, _, over_current} <- More])
    end.

%% A running device on root port 1 is unplugged and plugged in again after the status
%% read that saw it gone and before that connection change is cleared: the clear takes
%% the second change too, and the controller signals nothing more, so only a read
%% after the clear can see the new device (FreeBSD's uhub_reattach_port reads the
%% port after its clear, usb_hub.c:620-637).
a_change_between_a_read_and_its_clear_is_not_lost_test() ->
    Running = settle(follow({stimulus, [1], dev2}, trace_start())),
    ?assertMatch({running, _}, port_of(Running, {root, 1})),
    Clearing = drive(follow({stimulus, [1], none}, Running),
                     fun({#{ops := Ops}, _Core}) -> maps:get(root, Ops, none) =:= {1, {clear, connection}} end,
                     fun(_) -> true end),
    ?assertEqual(empty, port_of(Clearing, {root, 1})),
    Again = settle(follow({stimulus, [1], dev2}, Clearing)),
    ?assertMatch({running, _}, port_of(Again, {root, 1})).

a_connection_storm_stays_bounded_test() ->
    Toggle = fun(I, Node) ->
                     Thing = case I rem 2 of 0 -> none; 1 -> dev1 end,
                     drive(follow({stimulus, [1], Thing}, Node), fun(_) -> false end,
                           fun({expire, _}) -> false; (_) -> true end)
             end,
    Storm = {_, Core} = lists:foldl(Toggle, trace_start(), lists:seq(1, 201)),
    ?assert(erts_debug:flat_size(Core) < 400),
    ?assertMatch({running, _}, port_of(settle(Storm), {root, 1})).

%% A hub is unplugged while its child waits for its address: the child is detached
%% before the hub, every reference is gone, the late address answer changes nothing,
%% and the turn is free for the next device.
a_hub_detached_during_its_childs_enumeration_test() ->
    Hub = settle(follow({stimulus, [1], hub}, trace_start())),
    {running, HubRef} = port_of(Hub, {root, 1}),
    Addressing = fun(Node) -> port_of(Node, {HubRef, 1}) =:= {enumerating, {device, 2}, addressing} end,
    Child = drive(follow({stimulus, [1, 1], dev1}, Hub), Addressing, fun(_) -> true end),
    ?assert(Addressing(Child)),
    Root = fun({signal, _}) -> true; ({core, {port_done, root, _, _}}) -> true; (_) -> false end,
    Unplugged = {#{last := Last}, Core} =
        drive(follow({stimulus, [1], none}, Child),
              fun(Node) -> not is_map_key(HubRef, erx_usb_bus_core:devices(element(2, Node))) end, Root),
    ?assertEqual([{detach, {device, 2}}, {detach, HubRef}], [A || A = {detach, _} <- Last]),
    ?assertEqual(#{}, erx_usb_bus_core:devices(Core)),
    {_, Late} = erx_usb_bus_core:step({addressed, {device, 2}, addressing, {ok, 2}}, maps:get(now, element(1, Unplugged)), Core),
    ?assertEqual([], [A || A <- Late, element(1, A) =/= deadline]),
    Next = settle(follow({stimulus, [2], dev1}, settle(Unplugged))),
    ?assertMatch({running, _}, port_of(Next, {root, 2})).

%% Power: every port off until its power-on answer, then no status read before the
%% hub's power-good time; the root's is 40 ms after its last port's answer.
the_root_hub_powers_its_ports_before_reading_them_test() ->
    {S1, A1} = erx_usb_bus_core:step(expired, 0, erx_usb_bus_core:new(2)),
    ?assertEqual([{port, root, 1, power_on}], A1),
    {S2, A2} = erx_usb_bus_core:step({port_done, root, 1, ok}, 5, S1),
    ?assertEqual([{port, root, 2, power_on}], A2),
    {S3, A3} = erx_usb_bus_core:step({port_done, root, 2, ok}, 7, S2),
    ?assertEqual([{deadline, 47}], A3),
    ?assertEqual(#{{root, 1} => empty, {root, 2} => empty}, erx_usb_bus_core:ports(S3)),
    ?assertMatch({_, [{deadline, 47}]}, erx_usb_bus_core:step(expired, 46, S3)),
    ?assertMatch({_, [{port, root, 1, get_status}]}, erx_usb_bus_core:step(expired, 47, S3)).

%% A report naming a port the hub does not have reads nothing of it, and an answer of
%% a shape its operation never answers gives the hub up, as a failed answer does.
out_of_shape_reports_and_answers_test() ->
    Powering = fun({#{ops := Ops}, _}) -> [H || H := {_, power_on} <- Ops, H =/= root] =/= [] end,
    {#{now := Now}, Core} = Node = drive(follow({stimulus, [1], hub}, trace_start()), Powering, fun(_) -> true end),
    {running, HubRef} = port_of(Node, {root, 1}),
    {_, Detached} = erx_usb_bus_core:step({port_done, HubRef, 1, {ok, <<>>}}, Now, Core),
    ?assertEqual([{detach, HubRef}], [A || A = {detach, _} <- Detached]),
    {_, Idle} = Hub = settle(Node),
    Later = maps:get(now, element(1, Hub)),
    {S1, A1} = erx_usb_bus_core:step({changed, HubRef, [3], 1, fn}, Later, Idle),
    ?assertEqual([{handled, HubRef, fn}], [A || A <- A1, element(1, A) =/= deadline]),
    ?assertMatch({_, [{port, HubRef, 1, get_status} | _]}, erx_usb_bus_core:step({changed, HubRef, [1, 3], 1, fn}, Later, S1)).

%% A hub given up while a port below it holds the turn keeps the turn on its own port
%% until its parent answers the disable, since the child stays reachable through the
%% hub until then: a device waiting on the other root port is reset only after that.
a_hub_given_up_keeps_its_childs_turn_test() ->
    Hub = settle(follow({stimulus, [1], hub}, trace_start())),
    {running, HubRef} = port_of(Hub, {root, 1}),
    Resetting = fun(Node) -> P = port_of(Node, {HubRef, 1}), is_tuple(P) andalso element(1, P) =:= resetting end,
    Child = drive(follow({stimulus, [1, 1], dev1}, Hub), Resetting, fun(_) -> true end),
    HubAnswer = fun({core, {port_done, H, _, _}}) -> H =:= HubRef; (_) -> false end,
    Waiting = fun(Node) -> port_of(Node, {root, 2}) =:= waiting end,
    {#{now := Now, ops := #{HubRef := {Target, _}}}, Core} =
        drive(follow({stimulus, [2], dev1}, Child), Waiting, fun(C) -> not HubAnswer(C) end),
    {Failed, Actions} = erx_usb_bus_core:step({port_done, HubRef, Target, {error, stall}}, Now, Core),
    ?assertEqual([{detach, HubRef}], [A || A = {detach, _} <- Actions]),
    ?assertMatch(#{{root, 1} := {disabling, _, true}, {root, 2} := waiting}, erx_usb_bus_core:ports(Failed)),
    ?assert(lists:member({port, root, 1, disable}, Actions)),
    {_, Next} = erx_usb_bus_core:step({port_done, root, 1, ok}, Now, Failed),
    ?assert(lists:member({port, root, 2, reset}, Next)).

%% A chain of six hubs, each on port 1 of the one above: the fifth, five tiers below the
%% root, has its ports powered, and a device on it is addressed with a route of five
%% tiers; the sixth is configured and runs, but its ports stay `off` and are never
%% powered, so a device plugged below it is never enumerated with a route the slot
%% context cannot hold, and no operation names the sixth hub.
a_hub_past_the_depth_limit_keeps_its_ports_off_test() ->
    Chain = lists:foldl(fun(Tier, Node) -> settle(follow({stimulus, lists:duplicate(Tier, 1), hub}, Node)) end,
                        trace_start(), lists:seq(1, 6)),
    Full = settle(follow({stimulus, [1, 1, 1, 1, 1, 2], dev1}, Chain)),
    {#{powered := Powered, ops := Ops}, Core} = settle(follow({stimulus, lists:duplicate(7, 1), dev1}, Full)),
    Devices = erx_usb_bus_core:devices(Core),
    [Sixth] = [Ref || Ref := #{route := Route} <- Devices, Route =:= [1, 1, 1, 1, 1, 1]],
    [Device] = [Ref || Ref := #{route := Route} <- Devices, Route =:= [1, 1, 1, 1, 1, 2]],
    Ports = erx_usb_bus_core:ports(Core),
    ?assertMatch(#{{Sixth, 1} := off, {Sixth, 2} := off}, Ports),
    ?assertNot(is_map_key(Sixth, Powered)),
    ?assertNot(is_map_key(Sixth, Ops)),
    ?assertEqual(7, map_size(Devices)),
    ?assertEqual(lists:sort(maps:keys(Devices)), lists:sort([R || _ := {running, R} <- Ports])),
    #{port := DevicePort} = maps:get(Device, Devices),
    ?assertEqual({running, Device}, maps:get(DevicePort, Ports)).


%% A function's ends, each answered by its pipe's reset and then its start again: three
%% within a minute restart it; a fourth within that minute detaches its device and gives
%% its port up, logged once with that last end's reason, the disable's answer
%% logging nothing more; once the first end has left the window another restarts
%% it, and one more is refused again.
a_function_restarts_at_most_three_times_a_minute_test() ->
    {#{now := Now}, Core0} = Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    Three = lists:foldl(fun(At, Core) -> restarted(Ref, At, Core) end, Core0, [Now, Now + 1, Now + 2]),
    {Refused, Actions} = erx_usb_bus_core:step({function_ended, Ref, 0, 4, ?FAILED}, Now + 3, Three),
    Failure = {function, 0, {restarts, ?FAILED}},
    ?assertEqual([{detach, Ref}, {log, root, 1, {failed, Failure}}, {port, root, 1, disable}],
                 [A || A <- Actions, element(1, A) =/= deadline]),
    {Disabled, More} = erx_usb_bus_core:step({port_done, root, 1, ok}, Now + 3, Refused),
    ?assertEqual([], [A || A = {log, _, _, _} <- More]),
    ?assertEqual({disabled, Failure}, maps:get({root, 1}, erx_usb_bus_core:ports(Disabled))),
    Later = restarted(Ref, Now + ?RESTART_WINDOW, Three),
    ?assertMatch({_, [{detach, Ref} | _]},
                 erx_usb_bus_core:step({function_ended, Ref, 0, 5, ?FAILED}, Now + ?RESTART_WINDOW, Later)).

%% A function's request for a port reset (docs/design-usb.md, "Reattach"): its device is
%% detached from the controller, retiring its reference, and its port settles; the port
%% is reset in its turn, and the device, read back the same, is configured under a fresh
%% reference with its function's run carried over, starting again as its next instance
%% with the end counted.
a_port_reset_carries_the_runs_to_a_fresh_reference_test() ->
    Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    Back = {_, Core} = settle(follow({finish, Ref, 0, reset_port}, Running)),
    {running, New} = port_of(Back, {root, 1}),
    ?assert(New > Ref),
    ?assertNot(is_map_key(Ref, erx_usb_bus_core:devices(Core))),
    ?assertMatch(#{0 := #{state := running, number := 2, ends := [_]}}, runs(New, Core)).

%% A device that answers its port's reset as another, with no connection change, is a
%% new device: back at another speed (full-speed dev1 back as high-speed dev2), or at its
%% speed with other descriptors (dev2 back as a hub), it takes none of the runs the port
%% kept, and its function starts under the fresh reference as instance 1 with no ends.
a_port_reset_finds_another_device_new_test() ->
    back_as_another(dev1, dev2),
    back_as_another(dev2, hub).

back_as_another(Was, Is) ->
    Running = settle(follow({stimulus, [1], Was}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    {M = #{world := World}, Reset} = follow({finish, Ref, 0, reset_port}, Running),
    Below = case Is of
                hub -> #{[1, 1] => port0(), [1, 2] => port0()};
                _ -> #{}
            end,
    Swapped = {M#{world := maps:merge(World#{[1] := (maps:get([1], World))#{thing := Is}}, Below)}, Reset},
    Back = {_, Core} = settle(Swapped),
    {running, New} = port_of(Back, {root, 1}),
    ?assertNotEqual(Ref, New),
    ?assertNot(is_map_key(Ref, erx_usb_bus_core:devices(Core))),
    ?assertMatch(#{0 := #{state := running, number := 1, ends := []}}, runs(New, Core)).

%% A device replugged while its port waits for the reset a function asked for is a new
%% device, even when it answers the same: the connection change forgets what the port
%% kept.
a_replug_before_the_port_reset_forgets_the_kept_device_test() ->
    Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    Reset = follow({finish, Ref, 0, reset_port}, Running),
    Back = {_, Core} = settle(follow({stimulus, [1], dev1}, follow({stimulus, [1], none}, Reset))),
    {running, New} = port_of(Back, {root, 1}),
    ?assertNotEqual(Ref, New),
    ?assertMatch(#{0 := #{number := 1, ends := []}}, runs(New, Core)).

%% A port reset that its hub never answers is given up at its deadline, as any port's
%% reset is: the port is logged as failed and disabled, and holds the turn until then.
a_port_reset_past_its_deadline_gives_the_port_up_test() ->
    {#{now := Now}, Core0} = Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    {Core1, A1} = erx_usb_bus_core:step({function_ended, Ref, 0, 1, ?RESET_PORT}, Now, Core0),
    ?assertEqual([{detach, Ref}, {deadline, Now + ?POWER_UP_DELAY}], A1),
    {Core2, A2} = erx_usb_bus_core:step(expired, Now + ?POWER_UP_DELAY, Core1),
    ?assertEqual([{port, root, 1, reset}], [A || A <- A2, element(1, A) =/= deadline]),
    {Core3, A3} = erx_usb_bus_core:step(expired, Now + ?ATTEMPT_WINDOW, Core2),
    ?assertEqual([{log, root, 1, {failed, reset_timeout}}], [A || A <- A3, element(1, A) =/= deadline]),
    ?assertMatch({disabling, reset_timeout, true}, maps:get({root, 1}, erx_usb_bus_core:ports(Core3))).

%% A request for a port reset counts toward the function's restarts as any end does:
%% after three restarts within a minute, it gives the port up, named whole.
a_port_reset_past_the_restarts_gives_the_port_up_test() ->
    {#{now := Now}, Core0} = Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    Three = lists:foldl(fun(At, Core) -> restarted(Ref, At, Core) end, Core0, [Now, Now + 1, Now + 2]),
    {_, Actions} = erx_usb_bus_core:step({function_ended, Ref, 0, 4, ?RESET_PORT}, Now + 3, Three),
    ?assertEqual([{detach, Ref}, {log, root, 1, {failed, {function, 0, {restarts, ?RESET_PORT}}}},
                  {port, root, 1, disable}],
                 [A || A <- Actions, element(1, A) =/= deadline]).

%% The end that gives a port up is logged by name only (docs/design-log.md, "Reports
%% carry no term"): a crash whose stack frame holds the keys a keyboard reported
%% shows as its leading atom, and so does a shutdown that carries bytes; a start
%% that raised keeps 'EXIT' and its reason's leading atom.
a_given_up_function_logs_its_end_by_name_only_test() ->
    {#{now := Now}, Core0} = Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    Three = lists:foldl(fun(At, Core) -> restarted(Ref, At, Core) end, Core0, [Now, Now + 1, Now + 2]),
    Logged = fun(End) ->
                     {_, Actions} = erx_usb_bus_core:step({function_ended, Ref, 0, 4, End}, Now + 3, Three),
                     [Failure] = [F || {log, root, 1, {failed, F}} <- Actions],
                     Failure
             end,
    Crash = {function_clause, [{erx_hid_core, step, [<<0, 0, 4, 5>>], []}]},
    ?assertEqual({function, 0, {restarts, function_clause}}, Logged(Crash)),
    ?assertEqual({function, 0, {restarts, {shutdown, transfer}}}, Logged({shutdown, {transfer, <<"held">>}})),
    Raised = {'EXIT', {undef, [{erx_usb_bot, start_link, [#{device => Ref}], []}]}},
    ?assertEqual({function, 0, {restarts, {'EXIT', undef}}}, Logged(Raised)).

%% A late end from the run before, delivered once the function has started again,
%% changes nothing: the running instance's pipes are not reset under it.
a_late_end_from_an_earlier_run_changes_nothing_test() ->
    {#{now := Now}, Core0} = Running = settle(follow({stimulus, [1], dev1}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    stale({function_ended, Ref, 0, 1, ?FAILED}, Now + 1, restarted(Ref, Now, Core0)).

%% A composite keyboard whose second interface no function can drive: each of that
%% function's ends is unusable, the first final, so neither the four ends within a minute
%% nor any later one gives the device up; the keyboard's function runs on as its first
%% instance, its record keeps the reason, and its own ends still restart it.
a_composite_keeps_its_keyboard_past_unusable_ends_test() ->
    {#{now := Now}, Core0} = Running = settle(follow({stimulus, [1], dev2}, trace_start())),
    {running, Ref} = port_of(Running, {root, 1}),
    Core = lists:foldl(fun(At, C) -> ended_as(Ref, 1, ?UNUSABLE, At, C) end, Core0, [Now, Now + 1, Now + 2, Now + 3]),
    ?assertEqual({running, Ref}, maps:get({root, 1}, erx_usb_bus_core:ports(Core))),
    ?assertMatch(#{runs := #{0 := #{state := running, number := 1}, 1 := #{state := {unusable, no_usable_report}}}},
                 maps:get(Ref, erx_usb_bus_core:devices(Core))),
    {Restarting, Actions} = erx_usb_bus_core:step({function_ended, Ref, 0, 1, ?FAILED}, Now + 4, Core),
    ?assertEqual([{reset_pipe, Ref, 0, 16#81}], [A || A <- Actions, element(1, A) =/= deadline]),
    ?assertMatch(#{runs := #{1 := #{state := {unusable, no_usable_report}}}},
                 maps:get(Ref, erx_usb_bus_core:devices(Restarting))).

%% The bus process's part in function I's end at At as Reason: the end of its running
%% instance, then every pipe reset the core asks for answered `ok`.
ended_as(Ref, I, Reason, At, Core0) ->
    #{runs := #{I := #{number := Run}}} = maps:get(Ref, erx_usb_bus_core:devices(Core0)),
    answer_resets(erx_usb_bus_core:step({function_ended, Ref, I, Run, Reason}, At, Core0), At).

answer_resets({Core, Actions}, At) ->
    case [R || R = {reset_pipe, _, _, _} <- Actions] of
        [] -> Core;
        [{reset_pipe, Ref, I, A}] -> answer_resets(erx_usb_bus_core:step({pipe_reset, Ref, I, A, ok}, At, Core), At)
    end.

%% A report from a hub function's ended instance, arriving once its next instance runs,
%% changes nothing: it neither queues a read nor takes `handled` from its successor.
a_report_from_an_ended_hub_instance_changes_nothing_test() ->
    Hub = settle(follow({stimulus, [1], hub}, trace_start())),
    {running, HubRef} = port_of(Hub, {root, 1}),
    {#{now := Now}, Core} = settle(follow({finish, HubRef, 0, failed}, Hub)),
    stale({changed, HubRef, [1, 2, hub], 1, {fn, HubRef, 1}}, Now, Core).

%% dev1's one function, interface 0, running as instance Run, ends at Now and starts
%% again as instance Run + 1 once its one pipe, 81h, has answered its reset.
restarted(Ref, Now, Core0) ->
    #{runs := #{0 := #{number := Run}}} = maps:get(Ref, erx_usb_bus_core:devices(Core0)),
    {Core1, A1} = erx_usb_bus_core:step({function_ended, Ref, 0, Run, ?FAILED}, Now, Core0),
    ?assertEqual([{reset_pipe, Ref, 0, 16#81}], [A || A <- A1, element(1, A) =/= deadline]),
    {Core2, A2} = erx_usb_bus_core:step({pipe_reset, Ref, 0, 16#81, ok}, Now, Core1),
    Next = Run + 1,
    ?assertMatch([{start, Ref, [{#{interface := 0, pipes := [#{address := 16#81}]}, Next}]}],
                 [A || A <- A2, element(1, A) =/= deadline]),
    Core2.

%% A hub function ends while a device runs behind the hub: the function's pipe is reset,
%% it starts again, its next instance's first report reads every port, `handled` goes to
%% that instance, and the device behind the hub keeps running under its reference.
a_hub_functions_restart_leaves_agreeing_ports_test() ->
    Hub = settle(follow({stimulus, [1], hub}, trace_start())),
    {running, HubRef} = port_of(Hub, {root, 1}),
    {_, Before} = Behind = settle(follow({stimulus, [1, 2], dev2}, Hub)),
    {running, Child} = port_of(Behind, {HubRef, 2}),
    {#{hubs := Fns, last := Last}, Core} = Restarted = settle(follow({finish, HubRef, 0, failed}, Behind)),
    ?assertMatch(#{HubRef := #{instance := 2, first := false, outstanding := false}}, Fns),
    ?assertEqual([{handled, HubRef, {fn, HubRef, 2}}], [A || A = {handled, _, _} <- Last]),
    ?assertEqual({running, Child}, port_of(Restarted, {HubRef, 2})),
    ?assertEqual(maps:keys(erx_usb_bus_core:devices(Before)), maps:keys(erx_usb_bus_core:devices(Core))),
    ?assertEqual(maps:get(Child, erx_usb_bus_core:devices(Before)), maps:get(Child, erx_usb_bus_core:devices(Core))).

%% Canonical form: times relative to Now, references renumbered in order.
canon(Term, Now) ->
    Refs = lists:usort(collect(Term, [])),
    Map = maps:from_list(lists:zip(Refs, [{device, I} || I <- lists:seq(1, length(Refs))])),
    rewrite(Term, Map, Now).

collect(R = {device, N}, Acc) when is_integer(N) -> [R | Acc];
collect(T, Acc) when is_tuple(T) -> collect(tuple_to_list(T), Acc);
collect(L, Acc) when is_list(L) -> lists:foldl(fun collect/2, Acc, L);
collect(M, Acc) when is_map(M) -> collect(maps:to_list(M), Acc);
collect(_, Acc) -> Acc.

rewrite(R = {device, N}, Map, _Now) when is_integer(N) -> maps:get(R, Map);
rewrite(T, Map, Now) when is_tuple(T) -> list_to_tuple(rewrite(tuple_to_list(T), Map, Now));
rewrite(L, Map, Now) when is_list(L) -> [rewrite(E, Map, Now) || E <- L];
rewrite(M, Map, Now) when is_map(M) ->
    maps:from_list([{rewrite(K, Map, Now), rewrite(V, Map, Now)} || K := V <- M]);
rewrite(I, _Map, Now) when is_integer(I), I >= ?T0 -> {at, I - Now};
rewrite(X, _Map, _Now) -> X.
