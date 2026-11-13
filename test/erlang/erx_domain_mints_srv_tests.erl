%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The domain service applying erx_domain_mints (docs/design-system.md, "Facets a
%% configured domain serves"), over erx_domain_fake_lib: configured domain a (row 1)
%% serves echo, granted to configured domain b (row 0) and to the system domain. a's
%% ready report provides a mint of its own, a pid with a's node and its incarnation's
%% id as creation, which no process stands behind, so every mint is silent until the
%% test answers for it in a's envelope through a's domain pid, as erx_facet:minted/2
%% does, and the grantee's acknowledgement is the test's too, sent to b's domain pid in
%% b's envelope. a and b each start as soon as they are
%% made, a first; a restarts after each of the test's first three ends of it, and b after
%% its one end.
-module(erx_domain_mints_srv_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

%% The service's deadline for each mint operation, and for each introduction an
%% operation asks for: an hour, so that no case reaches either deadline by waiting,
%% however slow the host is. A case that needs an operation's deadline delivers it
%% with expire/1.
-define(DEADLINE, 3600000).
%% The fixture's system principal, which the service charges creates to and whose
%% sessions are root_N; the fake library's templates are principal 1's.
-define(PRINCIPALS, #{system => 1, names => #{}}).

mints_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_) -> {inorder, [fun installs/0, {timeout, 20, fun restart/0}, fun grantee_restart/0, fun foreign_mint/0, {timeout, 20, fun last_end/0}]} end}.

%% Template 0's sessions, beside a (5) and b (6), each get a grant of their own.
sessions_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) -> {timeout, 20, fun sessions/0} end}.

%% With echo a service of the files interface, 5, a session's start is answered only
%% once its echo grant is in place (docs/design-system.md, "A session takes the
%% console"), and a session that ends before then is answered with an error.
namespace_test_() ->
    {setup, fun() -> setup(5) end, fun cleanup/1, fun(_) -> {timeout, 20, fun namespace/0} end}.

namespace_end_test_() ->
    {setup, fun() -> setup(5) end, fun cleanup/1, fun(_) -> {timeout, 20, fun namespace_end/0} end}.

%% The system domain's namespace by the same rule: erx_domain:system_namespace/0 is
%% answered only once the system domain's echo grant is installed.
system_namespace_test_() ->
    {setup, fun() -> setup(5) end, fun cleanup/1, fun(_) -> {timeout, 20, fun system_namespace/0} end}.

%% The domain service's funnel for a domain's facets (docs/design-domains.md, "Facets"),
%% with a table of facet names that holds echo and other, and with the table the
%% build generates.
funnel_test_() ->
    {setup, fun() -> setup(1, #{facet_names => [echo, other]}) end, fun cleanup/1,
     fun(_) -> {timeout, 20, fun funnel/0} end}.

stopgap_names_test_() ->
    {setup, fun() -> setup(1) end, fun cleanup/1, fun(_) -> {timeout, 20, fun stopgap_names/0} end}.

setup() -> setup(1).

setup(Interface) -> setup(Interface, #{}).

%% With echo a service of interface Interface, and the service's start_link options
%% merged with Opts, which may name a table of facet names for the funnel's cases.
setup(Interface, Opts) ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 3, restart_period_s => 60, boot_timeout_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)],
                          services => [{1, echo, Interface}],
                          grants => [{0, echo, 1, #{max_request => 512}}, {system, echo, 1, #{}},
                                     {{template, 0}, echo, 1, #{max_request => 64}}]}),
    provide('a@erxos'),
    Log = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(Opts#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                      exports => erx_domain_fake_lib, principals => ?PRINCIPALS, introduce_timeout => ?DEADLINE,
                                                      mints => #{owner => fun erx_domain_mints_tests:owner/1,
                                                                 deadline => ?DEADLINE}}),
    unlink(Service),
    {Log, Service}.

cleanup({Log, Service}) ->
    erx_domain_fake_lib:kill_and_await([Service, Log]),
    _ = [persistent_term:erase(Key) || Key <- [{erx_domain_fake_lib, boot}, {erx_domain_fake_lib, provides},
                                               {erx, facets}]],
    ok.

%% a's reports provide echo's mint at Node, with the reporting incarnation's id.
provide(Node) ->
    persistent_term:put({erx_domain_fake_lib, provides},
                        #{<<"a">> => fun(Id) -> #{echo => pid(Node, Id, 1)} end,
                          <<"root_1">> => fun(Id) -> #{web_line => pid('root_1@erxos', Id, 3)} end}).

%% The whole path for both grants: b is introduced to a, a's mint is asked, its reply
%% installs the facet in b's registry through b's domain pid, and b's acknowledgement
%% makes the grant installed; the system domain's grant installs in this runtime's
%% registry at once. A reply from another domain, and an acknowledgement from a, which
%% is not the grantee, are dropped and counted. A reply sent to the service itself, in
%% a's envelope, is not taken at all: the service's pid is no address of the protocol.
installs() ->
    %% A session template's grant has no entry until a session of it reports ready.
    #{mints := Mints} = sys:get_state(erx_domain_srv),
    ?assertEqual([{0, echo}, {system, echo}], lists:sort(maps:keys(erx_domain_mints:grants(Mints)))),
    #{{system, echo} := {minting, {5, 4}, SystemTag}} = wait(fun(#{{system, echo} := {minting, _, _}}) -> true end),
    #{{0, echo} := {introducing, {5, 6}, _}} = wait(fun(#{{0, echo} := {introducing, _, _}}) -> true end),
    [PidA, PidB] = [domain_pid(Id) || Id <- [5, 6]],
    erlang:trace(PidA, true, ['receive', {tracer, self()}]),
    erlang:trace(PidB, true, ['receive', {tracer, self()}]),
    PidA ! {erx_origin, 5, {erx_connection_mapped, 6}},
    PidB ! {erx_origin, 6, {erx_connection_mapped, 5}},
    #{{0, echo} := {minting, {5, 6}, Tag}} = wait(fun(#{{0, echo} := {minting, _, _}}) -> true end),
    %% The request reaches the mint through a's domain pid, never from the service.
    Mint = pid('a@erxos', 5, 1),
    ?assertMatch({erx_facet_mint, Tag, echo, 6, #{max_request := 512}},
                 receive {trace, PidA, 'receive', {_, mint, Mint, Request}} -> Request after 2000 -> none end),
    Facet = pid('a@erxos', 5, 2),
    PidB ! {erx_origin, 6, {erx_facet_minted, Tag, {ok, Facet}}},
    wait_counts(fun(#{{dropped, wrong_domain} := N}) -> N =:= 1 end),
    erx_domain_srv ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    #{{0, echo} := {minting, {5, 6}, Tag}} = grants(),
    ?assertMatch(#{{dropped, wrong_domain} := 1}, counts()),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual(Facet, receive {trace, PidB, 'receive', {_, install, Tag, echo, F}} -> F after 2000 -> none end),
    PidA ! {erx_origin, 5, {erx_facets_installed, Tag}},
    wait_counts(fun(#{{dropped, wrong_domain} := N}) -> N =:= 2 end),
    PidB ! {erx_origin, 6, {erx_facets_installed, Tag}},
    wait(fun(#{{0, echo} := {installed, {5, 6}, F}}) -> F =:= Facet end),
    SystemFacet = pid('a@erxos', 5, 3),
    PidA ! {erx_origin, 5, {erx_facet_minted, SystemTag, {ok, SystemFacet}}},
    wait(fun(#{{system, echo} := {installed, {5, 4}, F}}) -> F =:= SystemFacet end),
    ?assertEqual(#{echo => SystemFacet}, persistent_term:get({erx, facets})),
    erlang:trace(PidA, false, ['receive']),
    erlang:trace(PidB, false, ['receive']).

%% A name of the table is refused whatever its grant, since the attenuating facet the
%% domain service would mint in front of the starter's (docs/design-domains.md,
%% "Handing a facet on") does not exist, and the spec is refused without admitting a
%% domain. The funnel reads no grant record: the grants installed here (b's grant of
%% echo, the system domain's own, a's mint) are the fixture for the attenuating hand-on
%% of TODO.md's facets item, which tells them apart, and each is refused alike.
%% console, a stopgap name outside the table, passes with a process of the system
%% domain, so the spec fails only at its boot, checked after the facets, and is refused
%% with a process of another node.
funnel() ->
    #{{0, echo} := {introducing, {5, 6}, _}} = wait(fun(#{{0, echo} := {introducing, _, _}}) -> true end),
    [PidA, PidB] = [domain_pid(Id) || Id <- [5, 6]],
    PidA ! {erx_origin, 5, {erx_connection_mapped, 6}},
    PidB ! {erx_origin, 6, {erx_connection_mapped, 5}},
    #{{0, echo} := {minting, {5, 6}, Tag}} = wait(fun(#{{0, echo} := {minting, _, _}}) -> true end),
    GranteeFacet = pid('a@erxos', 5, 2),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, GranteeFacet}}},
    wait(fun(#{{0, echo} := {installing, {5, 6}, _, F}}) -> F =:= GranteeFacet end),
    PidB ! {erx_origin, 6, {erx_facets_installed, Tag}},
    wait(fun(#{{0, echo} := {installed, {5, 6}, F}}) -> F =:= GranteeFacet end),
    Spec = fun(Facets) -> #{boot => <<"../x">>, name => <<"c">>, memory => 4096, facets => Facets} end,
    ?assertEqual({error, {bad_spec, facets}}, erx_domain:create(Spec(#{echo => GranteeFacet}))),
    SystemFacet = install_system_grant(),
    [?assertEqual({error, {bad_spec, facets}}, erx_domain:create(Spec(Facets)))
     || Facets <- [#{echo => SystemFacet}, #{echo => {SystemFacet, #{max_request => 64}}},
                   #{other => SystemFacet}, #{echo => pid('a@erxos', 5, 1)}, #{echo => self()},
                   #{echo => GranteeFacet}, #{console => pid('a@erxos', 5, 1)}]],
    ?assertEqual({error, {bad_spec, boot}}, erx_domain:create(Spec(#{console => self()}))),
    #{core := Core} = sys:get_state(erx_domain_srv),
    ?assertEqual(none, erx_domain_core:fetch(7, Core)).

%% The running table holds only the manifest's service names: none of the names the
%% facet-names check exempts travels into it. The funnel's one stopgap name, console,
%% stands outside it and still passes with a process of the system domain, so the spec
%% fails only at its boot, and is refused with a process of another node; log, which
%% no interface declares and the funnel does not exempt, web_line, exempt in the
%% check but no stopgap of the funnel, and a name in neither are refused, alone or
%% beside console.
stopgap_names() ->
    #{facet_names := Names} = sys:get_state(erx_domain_srv),
    ?assertEqual([], [Name || Name <- [console, log, web_line], lists:member(Name, Names)]),
    ?assert(lists:member(data, Names)),
    Spec = fun(Facets) -> #{boot => <<"../x">>, name => <<"c">>, facets => Facets} end,
    ?assertEqual({error, {bad_spec, boot}}, erx_domain:create(Spec(#{console => self()}))),
    [?assertEqual({error, {bad_spec, facets}}, erx_domain:create(Spec(Facets)))
     || Facets <- [#{console => pid('a@erxos', 5, 1)}, #{log => self()}, #{console => self(), log => self()},
                   #{web_line => self()}, #{rogue => self()}, #{console => self(), rogue => self()}]].

%% The system domain's grant of echo installed, a's mint's reply its facet.
install_system_grant() ->
    #{{system, echo} := {minting, {5, 4}, Tag}} = wait(fun(#{{system, echo} := {minting, _, _}}) -> true end),
    Facet = pid('a@erxos', 5, 3),
    domain_pid(5) ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    wait(fun(#{{system, echo} := {installed, {5, 4}, F}}) -> F =:= Facet end),
    Facet.

%% a's end cancels both operations' pairs, and its restart, id 7, starts new ones. A late
%% reply of the old incarnation, which only a's new domain pid could pass on, is
%% dropped there and never reaches the core; a facet of another node with a's new
%% id fails the system domain's operation; b's introduction, which no agent answers,
%% fails at the deadline, while the service goes on answering.
restart() ->
    erx_domain_srv ! {domain_ended, 5, {stopped, 0}, #{}},
    #{{system, echo} := {minting, {7, 4}, SystemTag}} =
        wait(fun(#{{system, echo} := {minting, {7, 4}, _}}) -> true end),
    domain_pid(7) ! {erx_origin, 5, {erx_facet_minted, SystemTag, {ok, pid('a@erxos', 5, 4)}}},
    #{{system, echo} := {minting, {7, 4}, SystemTag}} = grants(),
    ?assertMatch(#{{dropped, wrong_domain} := 2}, counts()),
    domain_pid(7) ! {erx_origin, 7, {erx_facet_minted, SystemTag, {ok, pid('x@erxos', 7, 5)}}},
    wait(fun(#{{system, echo} := {failed, {7, 4}, bad_reply}}) -> true end),
    #{{0, echo} := {introducing, {7, 6}, IntroduceTag}} = grants(),
    expire(deadline_message(IntroduceTag)),
    wait(fun(#{{0, echo} := {failed, {7, 6}, {deadline, introducing}}}) -> true end).

%% b's end and restart, id 8, leave the system domain's failed grant as it was, since
%% its pair is unchanged, and give b's grant a new operation for b's new incarnation
%% and a's, 7: the introduction, the mint request naming 8 as grantee, and the
%% installation at b's new domain pid. An acknowledgement in b's old envelope, which
%% only b's new domain pid could pass on, is dropped there and never reaches the core;
%% b's new incarnation's own makes the grant installed. a first lets go of its connection
%% with b's old incarnation, whose connection_up restart/0 left unanswered, as a's agent
%% would at b's end; until then a's connection with b's new incarnation waits behind it
%% (erx_domain_links, "Queues").
grantee_restart() ->
    erx_domain_srv ! {domain_ended, 6, {stopped, 0}, #{}},
    wait(fun(#{{0, echo} := {introducing, {7, 8}, _}}) -> true end),
    ?assertMatch(#{{system, echo} := {failed, {7, 4}, bad_reply}}, grants()),
    [PidA, PidB] = [domain_pid(Id) || Id <- [7, 8]],
    erlang:trace(PidA, true, ['receive', {tracer, self()}]),
    erlang:trace(PidB, true, ['receive', {tracer, self()}]),
    PidA ! {erx_origin, 7, {erx_connection_lost, 6, noconnection}},
    receive {trace, PidA, 'receive', {_, record, _, {erx_connection_up, 8, _, _, _, _, _, _, _}}} -> ok
    after 2000 -> error(no_connection_up) end,
    PidA ! {erx_origin, 7, {erx_connection_mapped, 8}},
    PidB ! {erx_origin, 8, {erx_connection_mapped, 7}},
    #{{0, echo} := {minting, {7, 8}, Tag}} = wait(fun(#{{0, echo} := {minting, {7, 8}, _}}) -> true end),
    Mint = pid('a@erxos', 7, 1),
    ?assertMatch({erx_facet_mint, Tag, echo, 8, #{max_request := 512}},
                 receive {trace, PidA, 'receive', {_, mint, Mint, Request}} -> Request after 2000 -> none end),
    Facet = pid('a@erxos', 7, 6),
    PidA ! {erx_origin, 7, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual(Facet, receive {trace, PidB, 'receive', {_, install, Tag, echo, F}} -> F after 2000 -> none end),
    Counts = counts(),
    PidB ! {erx_origin, 6, {erx_facets_installed, Tag}},
    receive after 100 -> ok end,
    ?assertMatch(#{{0, echo} := {installing, {7, 8}, Tag, Facet}}, grants()),
    PidB ! {erx_origin, 8, {erx_facets_installed, Tag}},
    wait(fun(#{{0, echo} := {installed, {7, 8}, F}}) -> F =:= Facet end),
    ?assertEqual(Counts, counts()),
    erlang:trace(PidA, false, ['receive']),
    erlang:trace(PidB, false, ['receive']).

%% A report naming a mint of another node, with the reporting incarnation's id as its
%% creation, is refused and counted: the service passes the core the node it knows for
%% the incarnation, never one the report suggests, so the grants have no pair.
foreign_mint() ->
    provide('x@erxos'),
    erx_domain_srv ! {domain_ended, 7, {stopped, 0}, #{}},
    wait(fun(Grants) -> maps:get({system, echo}, Grants) =:= idle andalso maps:get({0, echo}, Grants) =:= idle end),
    ?assertMatch(#{{refused, foreign_mint} := 1}, wait_counts(fun(#{{refused, foreign_mint} := _}) -> true end)).

%% An end with no restart after it, a's fourth, cancels the operation its incarnation,
%% 10, had pending: the grant is idle at once, the operation's deadline is disarmed, and
%% its timer's message, should it still come, leaves the grant idle.
last_end() ->
    provide('a@erxos'),
    erx_domain_srv ! {domain_ended, 9, {stopped, 0}, #{}},
    #{{system, echo} := {minting, {10, 4}, Tag}} = wait(fun(#{{system, echo} := {minting, {10, 4}, _}}) -> true end),
    %% Read before the end, which disarms it.
    Deadline = deadline_message(Tag),
    erx_domain_srv ! {domain_ended, 10, {stopped, 0}, #{}},
    wait(fun(#{{system, echo} := idle}) -> true end),
    #{mint_timers := Timers} = sys:get_state(erx_domain_srv),
    ?assertNot(is_map_key(Tag, Timers)),
    expire(Deadline),
    ?assertMatch(#{{system, echo} := idle, {0, echo} := idle}, grants()).

%% A configured domain's facets of services the system domain serves: b (row 0) is
%% granted log, which a process of this runtime names with erx_facet:serve/2 before
%% the service starts, and a (row 1) is granted clock, which no service names. b's
%% ready answer carries a facet in front of log's process, bound to b and within the
%% row's max_request; a's carries none, and no grant reaches the mint core.
%% It starts the service itself: the trace of the domain pids goes to the process that
%% asks for it, and EUnit runs a fixture's setup in another process than its test.
served_test() ->
    Started = served_setup(),
    try served() after served_cleanup(Started) end.

served_setup() ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 0, restart_period_s => 60, boot_timeout_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)], services => [],
                          grants => [{0, log, system, #{max_request => 64, in_flight => 2, queue => 4096}},
                                     {1, clock, system, #{max_request => 1}}]}),
    Log = spawn(fun() -> receive stop -> ok end end),
    ok = erx_facet:serve(log, Log),
    Self = self(),
    erlang:trace(new_processes, true, ['receive', {tracer, Self}]),
    Fake = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1}}),
    unlink(Service),
    {Fake, Service, Log}.

served_cleanup({Fake, Service, Log}) ->
    erlang:trace(new_processes, false, ['receive']),
    erx_domain_fake_lib:kill_and_await([Service, Fake, Log]),
    _ = [persistent_term:erase(Key) || Key <- [{erx_domain_fake_lib, boot}, {erx, serves}]],
    ok.

served() ->
    [PidA, PidB] = [domain_pid(Id) || Id <- [5, 6]],
    Answers = answers([PidA, PidB], #{}),
    ?assertEqual(#{}, maps:get(PidA, Answers)),
    #{log := Facet} = maps:get(PidB, Answers),
    ?assertEqual([log], maps:keys(maps:get(PidB, Answers))),
    ?assertMatch(#{grantee := 6, max_request := 64, in_flight := 2}, erx_facet:info(Facet)),
    ?assertEqual(#{}, grants()).

%% The ready answer each of Pids received, from the trace of its receives.
answers([], Answers) ->
    Answers;
answers(Pids, Answers) ->
    receive
        {trace, Pid, 'receive', {_Ref, facets, Facets}} ->
            answers(lists:delete(Pid, Pids), Answers#{Pid => Facets});
        {trace, _, 'receive', _} ->
            answers(Pids, Answers)
    after 2000 ->
            error({no_answer, Pids})
    end.

%% A session's template granted inspect by the manifest, a service the system domain
%% serves, finds the inspect facet in its ready answer, bound to the session and within
%% the grant's limits; a template the manifest grants nothing finds none
%% (docs/design-live.md, "The inspect service").
session_inspect_test() ->
    Started = inspect_setup([{{template, 0}, inspect, system, #{in_flight => 2}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        #{inspect := Facet} = Facets = maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})),
        ?assertEqual([inspect], maps:keys(Facets)),
        ?assertMatch(#{grantee := Id, in_flight := 2}, erx_facet:info(Facet))
    after
        inspect_cleanup(Started)
    end.

session_without_inspect_test() ->
    Started = inspect_setup([]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        ?assertEqual(#{}, maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})))
    after
        inspect_cleanup(Started)
    end.

%% No configured domain, the system domain's inspect service behind every facet, and a
%% trace of the domain pids' receives to this process, with Grants the manifest's.
inspect_setup(Grants) ->
    persistent_term:put({erx_domain_fake_lib, boot}, #{domains => [], services => [], grants => Grants}),
    Inspect = spawn(fun() -> receive stop -> ok end end),
    ok = erx_facet:serve(inspect, Inspect),
    erlang:trace(new_processes, true, ['receive', {tracer, self()}]),
    Fake = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                                 inspect_policy => #{roots => [1], development => false},
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1}}),
    unlink(Service),
    {Fake, Service, Inspect}.

inspect_cleanup(Started) ->
    served_cleanup(Started).

%% A session's template granted apps, a service of the files interface the system domain
%% serves, finds in its ready answer an erx_fs grant that the service's erx_fs_grants
%% supervisor started, exported to the session alone and ending with its domain pid;
%% no facet stands in front of it (docs/design-system.md, "Facets of the system
%% domain's services").
session_files_grant_test() ->
    Started = {_, _, Grants} = files_setup([{{template, 0}, apps, system, #{max_request => 131072, in_flight => 4}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        DomainPid = domain_pid(Id),
        #{apps := Grant} = Facets = maps:get(DomainPid, answers([DomainPid], #{})),
        ?assertEqual([apps], maps:keys(Facets)),
        ?assertEqual([Grant], [Child || {_, Child, _, _} <- supervisor:which_children(Grants)]),
        %% The grant exports itself to the session, after the session's start.
        ok = await_call({start, Id}),
        ?assertEqual({export, Id, [send]}, erx_domain_fake_lib:next_call()),
        Ref = monitor(process, Grant),
        exit(DomainPid, kill),
        receive {'DOWN', Ref, process, Grant, Reason} -> ?assertEqual({shutdown, connection_ended}, Reason)
        after 2000 -> error(grant_outlived_its_domain)
        end
    after
        files_cleanup(Started)
    end.

%% A session whose template the manifest does not grant apps finds no grant, though
%% another template holds one, and the service starts none.
session_without_files_grant_test() ->
    Started = {_, _, Grants} = files_setup([{{template, 1}, apps, system, #{max_request => 131072}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        ?assertEqual(#{}, maps:get(domain_pid(Id), answers([domain_pid(Id)], #{}))),
        ?assertEqual([], supervisor:which_children(Grants))
    after
        files_cleanup(Started)
    end.

%% No configured domain, apps a files service of the system domain with a test tree's
%% grants behind it, and a trace of the domain pids' receives to this process, with
%% Grants the manifest's.
files_setup(Grants) ->
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [], services => [{system, apps, ?ERX_SERVICE_FILES}], grants => Grants}),
    {ok, Tree} = erx_fs_grants:start_link(erx_fs_test_tree, []),
    unlink(Tree),
    ok = erx_facet:serve(apps, Tree),
    erlang:trace(new_processes, true, ['receive', {tracer, self()}]),
    Fake = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1}}),
    unlink(Service),
    {Fake, Service, Tree}.

files_cleanup(Started) ->
    served_cleanup(Started).

%% Takes the library's calls up to and including Call.
await_call(Call) ->
    case erx_domain_fake_lib:next_call() of
        Call -> ok;
        timeout -> error({never_called, Call});
        _Earlier -> await_call(Call)
    end.

%% A session of template 0 (7) gets its own echo grant: it is introduced to a, a's mint
%% is asked for the session's id with the template's limits, the facet is installed
%% through the session's domain pid, and only the session's acknowledgement settles it,
%% b's being dropped. The session's end deletes its grant, and a late reply for its
%% operation is dropped as of no operation. erx_domain_mints_tests covers two sessions
%% at once; the fake library holds one. The session's start names echo as its display,
%% a grant of its template: the record keeps it beside no facet, and the mint carries the
%% session mark. A display the template is not granted, and two displays, are refused
%% before the session takes an id.
sessions() ->
    ?assertEqual({error, {bad_spec, display}}, erx_domain:start_session(1, #{display => inspect})),
    ?assertEqual({error, {bad_spec, display}}, erx_domain:start_session(1, #{display => echo,
                                                                              default_display => echo})),
    {ok, {erx_domain, 7, _, _} = Session} = erx_domain:start_session(1, #{display => echo}),
    #{core := Core} = sys:get_state(erx_domain_srv),
    {ok, #{facets := Facets, start := Start}} = erx_domain_core:fetch(7, Core),
    ?assertEqual({#{}, #{display => echo}}, {Facets, Start}),
    [PidA, PidB, Pid7] = [domain_pid(Id) || Id <- [5, 6, 7]],
    erlang:trace(PidA, true, ['receive', {tracer, self()}]),
    erlang:trace(Pid7, true, ['receive', {tracer, self()}]),
    Key = {{session, 7}, echo},
    #{Key := {introducing, {5, 7}, _}} = wait(fun(#{Key := {introducing, _, _}}) -> true end),
    PidA ! {erx_origin, 5, {erx_connection_mapped, 7}},
    Pid7 ! {erx_origin, 7, {erx_connection_mapped, 5}},
    #{Key := {minting, {5, 7}, Tag}} = wait(fun(#{Key := {minting, _, _}}) -> true end),
    ?assertMatch({erx_facet_mint, Tag, echo, 7, #{max_request := 64, session := true}},
                 receive {trace, PidA, 'receive', {_, mint, _, {erx_facet_mint, Tag, _, _, _} = R}} -> R
                 after 2000 -> none end),
    Facet = pid('a@erxos', 5, 7),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual(Facet, receive {trace, Pid7, 'receive', {_, install, Tag, echo, F}} -> F after 2000 -> none end),
    %% The session's ready report named its web line, which the service keeps for the
    %% session until it ends.
    ?assertEqual({ok, pid('root_1@erxos', 7, 3)}, gen_server:call(erx_domain_srv, {web_line, 7})),
    ?assertEqual({error, no_line}, gen_server:call(erx_domain_srv, {web_line, 5})),
    PidB ! {erx_origin, 6, {erx_facets_installed, Tag}},
    wait_counts(fun(#{{dropped, wrong_domain} := N}) -> N =:= 1 end),
    Pid7 ! {erx_origin, 7, {erx_facets_installed, Tag}},
    wait(fun(#{Key := {installed, {5, 7}, F}}) -> F =:= Facet end),
    ok = erx_domain:stop(Session, kill),
    wait(fun(Grants) -> not is_map_key(Key, Grants) end),
    ?assertEqual({error, no_line}, gen_server:call(erx_domain_srv, {web_line, 7})),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    wait_counts(fun(#{{dropped, unknown_tag} := N}) -> N =:= 1 end).

%% Session 7 has reported ready while its echo grant is being made: its start is
%% answered only once the grant is installed.
namespace() ->
    Started = start_session(),
    [PidA, Pid7] = [domain_pid(Id) || Id <- [5, 7]],
    erlang:trace(Pid7, true, ['receive', {tracer, self()}]),
    Key = {{session, 7}, echo},
    #{Key := {introducing, {5, 7}, _}} = wait(fun(#{Key := {introducing, _, _}}) -> true end),
    ?assertEqual(none, answer(Started, 200)),
    PidA ! {erx_origin, 5, {erx_connection_mapped, 7}},
    Pid7 ! {erx_origin, 7, {erx_connection_mapped, 5}},
    #{Key := {minting, {5, 7}, Tag}} = wait(fun(#{Key := {minting, _, _}}) -> true end),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, pid('a@erxos', 5, 7)}}},
    receive {trace, Pid7, 'receive', {_, install, Tag, echo, _}} -> ok after 2000 -> error(no_install) end,
    ?assertEqual(none, answer(Started, 200)),
    Pid7 ! {erx_origin, 7, {erx_facets_installed, Tag}},
    ?assertMatch({ok, {erx_domain, 7, _, Pid7}}, answer(Started, 2000)),
    erlang:trace(Pid7, false, ['receive']).

%% Session 7 ends after its ready report, while its echo grant is being made: its start
%% is answered with an error, never ok.
namespace_end() ->
    Started = start_session(),
    Key = {{session, 7}, echo},
    #{Key := {introducing, {5, 7}, _}} = wait(fun(#{Key := {introducing, _, _}}) -> true end),
    ?assertEqual(none, answer(Started, 200)),
    exit(domain_pid(7), kill),
    ?assertMatch({error, _}, answer(Started, 2000)).

%% The wait is answered after the grant's mint replies and not before, and a later wait,
%% with the namespace in place, at once.
system_namespace() ->
    First = erx_domain:system_namespace(),
    #{{system, echo} := {minting, {5, 4}, Tag}} = wait(fun(#{{system, echo} := {minting, _, _}}) -> true end),
    %% wait_response/2 keeps the request on its timeout, where receive_response/2 abandons it.
    ?assertEqual(timeout, gen_server:wait_response(First, 200)),
    domain_pid(5) ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, pid('a@erxos', 5, 3)}}},
    ?assertEqual({reply, ok}, gen_server:receive_response(First, 2000)),
    ?assertEqual({reply, ok}, gen_server:receive_response(erx_domain:system_namespace(), 2000)).

%% A session's start, asked of the service by a process of its own, as the console's
%% helper asks; answer/2 takes its answer.
start_session() ->
    Self = self(),
    Ref = make_ref(),
    _ = spawn(fun() -> Self ! {Ref, erx_domain:start_session(1, #{})} end),
    Ref.

answer(Ref, Timeout) ->
    receive {Ref, Answer} -> Answer after Timeout -> none end.

%% A pid of Node with creation Creation, as a frame from that domain carries one.
pid(Node, Creation, Number) ->
    Name = atom_to_binary(Node),
    binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, Number:32, 0:32, Creation:32>>).

domain_pid(Id) ->
    #{core := Core} = sys:get_state(erx_domain_srv),
    {ok, #{pid := Pid}} = erx_domain_core:fetch(Id, Core),
    Pid.

%% The message the service's timer delivers at the deadline of Tag's operation.
deadline_message(Tag) ->
    #{mint_timers := #{Tag := Timer}} = sys:get_state(erx_domain_srv),
    {timeout, Timer, {mint_deadline, Tag}}.

%% Delivers a deadline message now, as the timer would at the deadline, and returns once
%% the service has handled it.
expire(Message) ->
    erx_domain_srv ! Message,
    _ = sys:get_state(erx_domain_srv),
    ok.

grants() -> maps:get(grants, gen_server:call(erx_domain_srv, mints)).
counts() -> maps:get(counts, gen_server:call(erx_domain_srv, mints)).

%% The grants once Match holds for them, within a hundred polls 30 ms apart.
wait(Match) -> poll(fun grants/0, Match, 100).
wait_counts(Match) -> poll(fun counts/0, Match, 100).

poll(Read, Match, 0) ->
    error({no_match, Read()}, [Read, Match]);
poll(Read, Match, Tries) ->
    Value = Read(),
    Matched = try Match(Value) catch error:function_clause -> false end,
    case Matched of
        true -> Value;
        false -> receive after 30 -> poll(Read, Match, Tries - 1) end
    end.
