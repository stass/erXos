%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the domain service: erx_ident's rule, erx_domain_core's ids,
%% names and lives, and erx_domain_srv over erx_domain_fake_lib.
-module(erx_domain_tests).
-include_lib("eunit/include/eunit.hrl").

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

%% Runs a domain through its life to retired.
live(Name, Core0) ->
    {#{id := Id} = Domain, Core1} = admit(Name, 1, request, Core0),
    Core2 = erx_domain_core:running(Id, erx_domain_core:built(Id, 7, self(), make_ref(), Core1)),
    {stopped, _, Core3} = erx_domain_core:ended(Id, {stopped, 0}, none, 0, Core2),
    {Domain, erx_domain_core:retired(Id, Core3)}.

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
    Core2 = erx_domain_core:built(Id, 0, self(), make_ref(), Core1),
    ?assertMatch({ok, #{id := Id}}, erx_domain_core:find_pid(self(), Core2)),
    {{halt, 3}, _, Core3} = erx_domain_core:ended(Id, {halt, 3}, none, 9, Core2),
    ?assertEqual(none, erx_domain_core:ended(Id, {halt, 0}, none, 0, Core3)),
    ?assertMatch([#{id := Id, info := {halt, 3}, at := 9}], erx_domain_core:deaths(1, Core3)),
    [?assertEqual(Info, erx_domain_core:info(End))
     || {End, Info} <- [{{halt, 1}, {halt, 1}}, {{crash, 5}, crash}, {{fault, 2}, {fault, 2}}, {{stopped, 0}, stopped}]].

%% A crash's death keeps the slogan the service read, or why it could not;
%% no other end keeps one.
crash_death_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    {#{id := A}, Core1} = admit(<<"a">>, 1, request, Core0),
    {#{id := B}, Core2} = admit(<<"b">>, 1, request, Core1),
    Built = erx_domain_core:built(A, 0, self(), make_ref(), Core2),
    Core3 = erx_domain_core:built(B, 0, self(), make_ref(), Built),
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

restart_test() ->
    Core0 = erx_domain_core:new(<<"erxos">>),
    {yes, Core1} = erx_domain_core:restart(0, 2, 10, 100, Core0),
    {yes, Core2} = erx_domain_core:restart(0, 2, 10, 105, Core1),
    {no, Core3} = erx_domain_core:restart(0, 2, 10, 109, Core2),
    {yes, _} = erx_domain_core:restart(0, 2, 10, 111, Core3),
    {no, _} = erx_domain_core:restart(1, 0, 10, 100, Core0).

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

service_end_shuts_down(End) ->
    {ok, Sup} = erx_domain_sup:start_link(),
    unlink(Sup),
    SupDown = monitor(process, Sup),
    Service = whereis(erx_domain_srv),
    ?assert(is_pid(Service)),
    End(Service),
    Why = receive {'DOWN', SupDown, process, Sup, Reason} -> Reason after 2000 -> still_up end,
    %% A restarted service is registered again. Clean up before asserting.
    Restarted = whereis(erx_domain_srv),
    is_process_alive(Sup) andalso exit(Sup, kill),
    ?assertEqual({shutdown, undefined}, {Why, Restarted}).

%% The service over the stand-ins: configured domains in boot order, each with
%% its system side opened before its first thread, a create, a stop, a kill,
%% {domain_down, Id, Info} at the domain pid's monitors, the side closed before
%% the connection's objects go, a configured domain's restarts within its
%% intensity and a side the agent refuses; last, the service's own end, which
%% ends every domain pid.
service_test_() ->
    {setup,
     fun() ->
             Log = erx_domain_fake_lib:start_log(),
             {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib}),
             unlink(Service),
             {Log, Service}
     end,
     fun({Log, Service}) ->
             exit(Service, kill),
             exit(Log, kill)
     end,
     fun(_) -> {inorder, [fun boot_order/0, fun create_stop_kill/0, fun configured_restart/0,
                          fun refused_side/0, fun service_end_ends_domain_pids/0]} end}.

next_call() ->
    erx_domain_fake_lib:next_call().

boot_order() ->
    %% Row 1 (a) is first in the boot order, so it takes id 5.
    ?assertEqual({configured, 5, 1}, next_call()),
    ?assertEqual({open_side, 5, 'a@erxos', 50}, next_call()),
    ?assertEqual({start, 5}, next_call()),
    ?assertEqual({configured, 6, 0}, next_call()),
    ?assertEqual({open_side, 6, 'b@erxos', 60}, next_call()),
    ?assertEqual({start, 6}, next_call()).

create_stop_kill() ->
    Spec = #{name => <<"web">>, memory => 4096},
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
    {create, #{id := 8, name := <<"web">>, principal := 1, memory := 4096, domain_pid := DomainPid}} = next_call(),
    ?assertEqual(erx_domain:pid(Domain), DomainPid),
    ?assertEqual({open_side, 8, 'web@erxos', 80}, next_call()),
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
    _ = [next_call(), next_call(), next_call()],
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
    ?assertEqual({start, 10}, next_call()),
    %% Its second end within the minute is final: the next call the library
    %% sees is a request's create, which takes the next id.
    erx_domain_srv ! {domain_ended, 10, {halt, 1}, #{}},
    ?assertMatch({close_side, 10, {domain_down, 10, _}}, next_call()),
    ?assertEqual({disconnect, 100}, next_call()),
    ?assertEqual({retire, 10}, next_call()),
    {ok, _} = erx_domain:create(#{name => <<"after">>, memory => 4096}),
    ?assertMatch({create, #{id := 11}}, next_call()),
    ?assertEqual({open_side, 11, 'after@erxos', 110}, next_call()),
    ?assertEqual({start, 11}, next_call()).

refused_side() ->
    %% A side the agent refuses fails the create, and the domain the library
    %% made is stopped without its first thread, its end retiring it as any does.
    ?assertEqual({error, {system_side, enomem}}, erx_domain:create(#{name => <<"noside">>, memory => 4096})),
    ?assertMatch({create, #{id := 12}}, next_call()),
    ?assertEqual({open_side, 12, 'noside@erxos', 120}, next_call()),
    ?assertEqual({stop, 12}, next_call()),
    ?assertEqual({close_side, 12, {domain_down, 12, stopped}}, next_call()),
    ?assertEqual({disconnect, 120}, next_call()),
    ?assertEqual({retire, 12}, next_call()).

service_end_ends_domain_pids() ->
    %% The service's end ends every domain pid with its reason: no domain
    %% outlives the system domain, so the pid has nothing left to stop.
    {ok, Domain} = erx_domain:create(#{name => <<"last">>, memory => 4096}),
    ?assertMatch({create, #{id := 13}}, next_call()),
    ?assertEqual({open_side, 13, 'last@erxos', 130}, next_call()),
    ?assertEqual({start, 13}, next_call()),
    Pid = erx_domain:pid(Domain),
    Ref = monitor(process, Pid),
    %% An exit message forged in the service's name while it lives ends nothing.
    Service = whereis(erx_domain_srv),
    Pid ! {'EXIT', Service, {domain_down, 13, {halt, 0}}},
    ?assertEqual(timeout, receive {'DOWN', Ref, process, _, Forged} -> Forged after 200 -> timeout end),
    exit(Service, kill),
    ?assertEqual(killed, receive {'DOWN', Ref, process, _, Reason} -> Reason after 2000 -> timeout end).
