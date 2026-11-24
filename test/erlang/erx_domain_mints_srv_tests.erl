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
%% sessions are root_N; the fake library's templates are principal 1's. Its mints name
%% its user, root, not its manifest name (docs/design-system.md, the mint request).
-define(PRINCIPALS, #{system => 1, names => #{1 => <<"system">>}}).

mints_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_) -> {inorder, [fun installs/0, {timeout, 20, fun restart/0}, fun grantee_restart/0, fun foreign_mint/0, {timeout, 20, fun last_end/0}]} end}.

%% A session's line minted for b (lines/0).
lines_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_) -> {timeout, 20, fun lines/0} end}.

%% Template 0's sessions, beside a (5) and b (6), each get a grant of their own.
sessions_test_() ->
    {setup, fun() -> setup(?ERX_SERVICE_WINDOWS) end, fun cleanup/1, fun(_) -> {timeout, 20, fun sessions/0} end}.

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

%% A display's row waits for its server (docs/design-system.md, "A session takes the
%% console"): erx_domain:server_settled/1 is answered once no starting row serves the
%% display, its server ready, ended or stopped for its boot timeout, and at once for a
%% name no configured row serves. late (row 1, id 5) serves screen and never reports by
%% itself.
server_settled_test_() ->
    [{setup, fun() -> display_setup() end, fun cleanup/1,
      fun(_) -> {timeout, 20, {Name, Case}} end}
     || {Name, Case} <- [{"ready", fun display_ready/0}, {"ended", fun display_ended/0},
                         {"boot timeout", fun display_timed_out/0}]].

%% The settlement wait (docs/design-system.md, "Waiting for a grant"): three askers, one
%% of each query, each answered at the step that settles its own query, over late (row
%% 1, id 5), which here serves echo, of no files interface, to the system domain.
settling_test_() ->
    {setup, fun() -> display_setup([{1, echo, 1}], [{system, echo, 1, #{}}]) end, fun cleanup/1,
     fun(_) -> {timeout, 20, fun three_askers/0} end}.

%% One incarnation's grant (docs/design-system.md, "A session takes the console"):
%% erx_domain:await_grant/2 is answered once the system domain's grant of echo has
%% settled for the incarnation it names, with the facet, failed, ended or unprovided,
%% while the service goes on answering other calls; in the last case a's reports
%% provide nothing.
await_grant_test_() ->
    [{setup, fun() -> setup(1, #{}, Provides) end, fun cleanup/1,
      fun(_) -> {timeout, 20, {Name, Case}} end}
     || {Name, Case, Provides} <- [{"installed", fun await_installed/0, fun(Id) -> #{<<"echo">> => pid('a@erxos', Id, 1)} end},
                                   {"failed", fun await_failed/0, fun(Id) -> #{<<"echo">> => pid('a@erxos', Id, 1)} end},
                                   {"ended", fun await_ended/0, fun(Id) -> #{<<"echo">> => pid('a@erxos', Id, 1)} end},
                                   {"unprovided", fun await_unprovided/0, fun(_Id) -> #{} end}]].

%% The domain service's funnel for a domain's facets (docs/design-domains.md, "Facets"),
%% with a table of facet names that holds echo and other, and with the table the
%% build generates.
funnel_test_() ->
    {setup, fun() -> setup(1, #{facet_names => [echo, other]}) end, fun cleanup/1,
     fun(_) -> {timeout, 20, fun funnel/0} end}.

%% A report's provides name each service by its text (init's report_ready/0): a name
%% the system domain has no atom for is refused as undeclared and makes none, while the
%% rest of the report stands, so the grant of echo waits idle for a provider.
unknown_name_test_() ->
    Name = <<"erx_mints_srv_tests_no_such_atom">>,
    {setup, fun() -> setup(1, #{}, fun(Id) -> #{Name => pid('a@erxos', Id, 1)} end) end, fun cleanup/1,
     fun(_) -> {timeout, 20, fun() -> unknown_name(Name) end} end}.

stopgap_names_test_() ->
    {setup, fun() -> setup(1) end, fun cleanup/1, fun(_) -> {timeout, 20, fun stopgap_names/0} end}.

%% With echo a service of the windows interface, the pair of a and b has echo's pixel
%% area, windows_pixels_default since b's grant states no pixels, read by a: whether
%% the grant's introduction makes their connection, or erx_domain:introduce/2 makes it
%% before the grant is introduced, here while a's report provides nothing.
pair_area_test_() ->
    [{setup, fun() -> setup(?ERX_SERVICE_WINDOWS) end, fun cleanup/1, fun(_) -> {timeout, 20, fun grant_area/0} end},
     {setup, fun() -> setup(?ERX_SERVICE_WINDOWS, #{}, fun(_Id) -> #{} end) end, fun cleanup/1,
      fun(_) -> {timeout, 20, fun introduced_area/0} end}].

grant_area() ->
    ?assertEqual({connect, 5, 6, erx_domain_fake_lib:reader(5), erx_domain_fake_lib:reader(6),
                  ?ERX_WINDOWS_PIXELS_DEFAULT, 5}, next_connect()).

introduced_area() ->
    poll(fun() -> sys:get_state(erx_domain_srv) end,
         fun(#{core := Core}) -> [ok, ok] =:= [element(1, erx_domain_core:fetch(Id, Core)) || Id <- [5, 6]] end, 100),
    Request = gen_server:send_request(erx_domain_srv, {introduce, 5, 6}),
    ?assertEqual({connect, 5, 6, erx_domain_fake_lib:reader(5), erx_domain_fake_lib:reader(6),
                  ?ERX_WINDOWS_PIXELS_DEFAULT, 5}, next_connect()),
    #{{0, echo} := idle} = grants(),
    _ = gen_server:wait_response(Request, 0).

%% The library's next session call, past every other call the service makes first.
session_call() ->
    case erx_domain_fake_lib:next_call() of
        Call when element(1, Call) =:= session -> Call;
        timeout -> timeout;
        _Other -> session_call()
    end.

%% The library's connect call for the pair of A and B, past every other call.
connect_of(A, B) ->
    case next_connect() of
        {connect, A, B, _, _} = Call -> Call;
        timeout -> timeout;
        _Other -> connect_of(A, B)
    end.

%% The library's next connect call, past every other call the service makes first.
next_connect() ->
    case erx_domain_fake_lib:next_call() of
        Call when element(1, Call) =:= connect -> Call;
        timeout -> timeout;
        _Other -> next_connect()
    end.

setup() -> setup(1).

setup(Interface) -> setup(Interface, #{}).

setup(Interface, Opts) -> setup(Interface, Opts, fun(Id) -> #{<<"echo">> => pid('a@erxos', Id, 1)} end).

%% With echo a service of interface Interface, the service's start_link options merged
%% with Opts, which may name a table of facet names for the funnel's cases, and a's
%% reports providing what Provides answers for the reporting incarnation's id.
setup(Interface, Opts, Provides) ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 3, restart_period_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)],
                          services => [{1, echo, Interface}],
                          grants => [{0, echo, 1, #{max_request => 512}}, {system, echo, 1, #{}},
                                     {{template, 0}, echo, 1, #{max_request => 64}}]}),
    provide_a(Provides),
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
provide(Node) -> provide_a(fun(Id) -> #{<<"echo">> => pid(Node, Id, 1)} end).

%% a's reports provide what Provides answers for the reporting incarnation's id.
provide_a(Provides) ->
    persistent_term:put({erx_domain_fake_lib, provides},
                        #{<<"a">> => Provides,
                          <<"root_1">> => fun(Id) -> #{<<"web_line">> => pid('root_1@erxos', Id, 3),
                                                       <<"ssh_line">> => pid('b@erxos', Id, 4)} end}).

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
    ?assertMatch({erx_facet_mint, Tag, echo, 6, <<"root">>, #{max_request := 512}},
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
    {_Generation, SystemRegistry} = persistent_term:get({erx, facets}),
    ?assertEqual(#{echo => SystemFacet}, SystemRegistry),
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

unknown_name(Name) ->
    wait_counts(fun(#{{refused, undeclared} := N}) -> N =:= 1 end),
    ?assertMatch(#{{system, echo} := idle}, grants()),
    ?assertError(badarg, binary_to_existing_atom(Name)).

%% The running table holds only the manifest's service names: none of the names the
%% facet-names check exempts travels into it. The funnel's one stopgap name, console,
%% stands outside it and still passes with a process of the system domain, so the spec
%% fails only at its boot, and is refused with a process of another node; log, a
%% manifest service name in the table that a spec cannot hand on, since the funnel
%% passes no facet on unattenuated (attenuated/2), web_line, a `served_by session` line (?ERX_LINES) but
%% no stopgap of the funnel, and a name in neither are refused, alone or beside
%% console.
stopgap_names() ->
    #{facet_names := Names} = sys:get_state(erx_domain_srv),
    ?assertEqual([], [Name || Name <- [console, web_line], lists:member(Name, Names)]),
    ?assert(lists:member(data, Names) andalso lists:member(log, Names)),
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
    receive {trace, PidA, 'receive', {_, record, _, {erx_connection_up, 8, _, _, _, _, _, _, _, _}}} -> ok
    after 2000 -> error(no_connection_up) end,
    PidA ! {erx_origin, 7, {erx_connection_mapped, 8}},
    PidB ! {erx_origin, 8, {erx_connection_mapped, 7}},
    #{{0, echo} := {minting, {7, 8}, Tag}} = wait(fun(#{{0, echo} := {minting, {7, 8}, _}}) -> true end),
    Mint = pid('a@erxos', 7, 1),
    ?assertMatch({erx_facet_mint, Tag, echo, 8, <<"root">>, #{max_request := 512}},
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
%% the service starts, and a (row 1) is granted clock, which no service names, and log
%% by a row that lists its write operation, which erx_log_facet has no operation/1 to
%% check (erx_facet:start/3). b's ready answer carries a facet in front of log's
%% process, bound to b and within the row's max_request; a's carries none, and no grant
%% reaches the mint core.
%% It starts the service itself: the trace of the domain pids goes to the process that
%% asks for it, and EUnit runs a fixture's setup in another process than its test.
served_test() ->
    Started = served_setup(),
    try served() after served_cleanup(Started) end.

served_setup() ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 0, restart_period_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)], services => [],
                          grants => [{0, log, system, #{max_request => 64, in_flight => 2, queue => 4096}},
                                     {1, clock, system, #{max_request => 1}},
                                     {1, log, system, #{max_request => 64, operations => [write]}}]}),
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

%% The ready answer names the facets of configured domains the manifest grants the
%% domain, each with its interface, echo's 1, which come later by installation, so the domain mounts each it is granted:
%% b (row 0) and a session of template 0 are granted echo and their answers name it;
%% a, which serves echo and is granted nothing, finds none, and a session of template 1,
%% which the manifest grants nothing, finds none, though template 0 holds a grant.
granted_names_test_() ->
    [{"template 0", fun() -> ?assertEqual({[], [{echo, 1}], [{echo, 1}]}, granted_names(0)) end},
     {"template 1", fun() -> ?assertEqual({[], [{echo, 1}], []}, granted_names(1)) end}].

%% The grants the ready answers of a, b and a session of principal 1 carried, with
%% principal 1's sessions made from template Template.
granted_names(Template) ->
    Self = self(),
    erlang:trace(new_processes, true, ['receive', {tracer, Self}]),
    persistent_term:put({erx_domain_fake_lib, templates}, [#{principal => 1, template => Template}]),
    Started = setup(),
    try
        [PidA, PidB] = [domain_pid(Id) || Id <- [5, 6]],
        #{PidA := A, PidB := B} = granted_answers([PidA, PidB], #{}),
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        #{} = Session = granted_answers([domain_pid(Id)], #{}),
        {A, B, maps:get(domain_pid(Id), Session)}
    after
        erlang:trace(new_processes, false, ['receive']),
        persistent_term:erase({erx_domain_fake_lib, templates}),
        cleanup(Started)
    end.

%% The names each of Pids' ready answers carried, from the trace of their receives.
granted_answers([], Answers) ->
    Answers;
granted_answers(Pids, Answers) ->
    receive
        {trace, Pid, 'receive', {_Ref, facets, _Facets, Granted}} ->
            case lists:member(Pid, Pids) of
                true -> granted_answers(lists:delete(Pid, Pids), Answers#{Pid => Granted});
                false -> granted_answers(Pids, Answers)
            end;
        {trace, _, 'receive', _} ->
            granted_answers(Pids, Answers)
    after 2000 ->
            error({no_answer, Pids})
    end.

%% The system domain mounts /data once the domain service has read the manifest, and
%% only when the manifest grants it data: then /data is the facet's mount, which answers
%% eio until the grant is installed; with no grant there is no mount, so /data is the
%% root's own entry, as FreeBSD shows a mount point with nothing mounted on it.
system_data_mount_test_() ->
    [{"granted", fun() -> ?assertMatch([_, #{point := [<<"data">>], provider := {facet, data, <<"data">>}, rights := rw}],
                                       system_mounts([{system, data, 1, #{}}, {0, data, 1, #{}}])) end},
     {"not granted", fun() -> ?assertEqual([#{point => [], provider => release, root => [], rights => ro}],
                                           system_mounts([{0, data, 1, #{}}])) end}].

%% The packages tree, which no session mounts, the system domain mounts at its system
%% place, /packages (erx_ns:packages_place/0), where erx_pkg_medium reads the installed
%% packages, and only when the manifest grants it packages.
system_packages_mount_test_() ->
    [{"granted", fun() -> ?assertMatch([_, #{point := [<<"packages">>], provider := {facet, packages, <<"packages">>},
                                             rights := rw}],
                                       system_mounts([{system, packages, 1, #{}}, {0, packages, 1, #{}}])) end},
     {"not granted", fun() -> ?assertEqual([#{point => [], provider => release, root => [], rights => ro}],
                                           system_mounts([{0, packages, 1, #{}}])) end}].

%% The system domain's mounts once the service has booted from a manifest whose data and
%% packages are files services of a (row 1) with Grants, as start_link returns them, with
%% no call to the service first, as the release's later applications read /data.
system_mounts(Grants) ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 0, restart_period_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)],
                          services => [{1, data, 5}, {1, packages, 5}], grants => Grants}),
    persistent_term:erase(erx_ns),
    {ok, Ns} = erx_ns:start_link(erx_ns_prim_stub),
    unlink(Ns),
    Log = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1,
                                                            deadline => ?DEADLINE}}),
    unlink(Service),
    try
        erx_ns_prim_stub:erx_mounts()
    after
        erx_domain_fake_lib:kill_and_await([Service, Log, Ns]),
        _ = [persistent_term:erase(Key) || Key <- [{erx_domain_fake_lib, boot}, erx_ns, {erx, facets}]]
    end.

%% The ready answer each of Pids received, from the trace of its receives.
answers([], Answers) ->
    Answers;
answers(Pids, Answers) ->
    receive
        {trace, Pid, 'receive', {_Ref, facets, Facets, _Granted}} ->
            answers(lists:delete(Pid, Pids), Answers#{Pid => Facets});
        {trace, _, 'receive', _} ->
            answers(Pids, Answers)
    after 2000 ->
            error({no_answer, Pids})
    end.

%% A session's template granted inspect by the manifest, a service the system domain
%% serves, finds the inspect facet in its ready answer, bound to the session and within
%% the grant's limits; a template the manifest grants nothing finds none
%% (docs/design-live.md, "The inspect service"). Beside it, each holds the code_objects
%% facet every session gets (session_code_objects_test).
session_inspect_test() ->
    Started = inspect_setup([{{template, 0}, inspect, system, #{in_flight => 2}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        #{inspect := Facet} = Facets = maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})),
        ?assertEqual([code_objects, inspect], lists:sort(maps:keys(Facets))),
        ?assertMatch(#{grantee := Id, in_flight := 2}, erx_facet:info(Facet))
    after
        inspect_cleanup(Started)
    end.

%% A session the manifest grants nothing holds the code_objects facet alone, by the domain
%% service's own policy, bound to the session itself and within the service's own limits
%% (docs/design-system.md, "The code_objects facet"); a domain made on request, which
%% the manifest grants nothing either, holds none.
session_code_objects_test() ->
    Started = inspect_setup([]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        #{code_objects := Facet} = Facets = maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})),
        ?assertEqual([code_objects], maps:keys(Facets)),
        ?assertMatch(#{grantee := Id, max_request := ?ERX_CODE_OBJECTS_MAX_REQUEST, in_flight := 4},
                     erx_facet:info(Facet)),
        {ok, {erx_domain, Made, _, _}} = erx_domain:create(#{boot => <<"base">>, name => <<"made">>, memory => 4096}),
        ?assertEqual(#{}, maps:get(domain_pid(Made), answers([domain_pid(Made)], #{})))
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

%% A session's template granted start, a service of the files interface the system domain
%% serves, finds in its ready answer an erx_fs grant that the service's erx_fs_grants
%% supervisor started, exported to the session alone and ending with its domain pid;
%% no facet stands in front of it (docs/design-system.md, "Facets of the system
%% domain's services").
session_files_grant_test() ->
    Started = {_, _, Grants} = files_setup([{{template, 0}, start, system, #{max_request => 131072, in_flight => 4}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        DomainPid = domain_pid(Id),
        #{start := {Grant, rw}} = Facets = maps:get(DomainPid, answers([DomainPid], #{})),
        ?assertEqual([code_objects, start], lists:sort(maps:keys(Facets))),
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

%% A session whose template the manifest does not grant start finds no grant, though
%% another template holds one, and the service starts none.
session_without_files_grant_test() ->
    Started = {_, _, Grants} = files_setup([{{template, 1}, start, system, #{max_request => 131072}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        ?assertEqual([code_objects], maps:keys(maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})))),
        ?assertEqual([], supervisor:which_children(Grants))
    after
        files_cleanup(Started)
    end.

%% A session's template granted line, a service of the line interface, which abi/services
%% declares served as a tree, finds an erx_fs grant of the tree's erx_fs_grants in its
%% ready answer, as a files service's grantee does, and no facet in front of the tree
%% (docs/design-bluetooth.md, "The controller's line").
session_line_grant_test() ->
    Started = {_, _, Grants} = tree_setup(line, ?ERX_SERVICE_LINE,
                                          [{{template, 0}, line, system, #{max_request => 131072}}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        #{line := {Grant, rw}} = maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})),
        ?assertEqual([Grant], [Child || {_, Child, _, _} <- supervisor:which_children(Grants)])
    after
        files_cleanup(Started)
    end.

%% A session of the system principal holds a machine grant that names it by its user
%% name, root, as every mint request does (docs/design-system.md, "A session's
%% request"), so the machine's end is logged by the name the session logs in as.
session_machine_grant_test() ->
    Started = tree_setup(machine, ?ERX_SERVICE_FILES, [{{template, 0}, machine, system, #{max_request => 131072}}],
                         fun() -> erx_fs_grants:start_link(erx_machine_fs) end),
    {module, _} = code:ensure_loaded(erx_machine_fs),
    1 = erlang:trace_pattern({erx_machine_fs, init, 1}, true, [local]),
    erlang:trace(all, true, [call, {tracer, self()}]),
    try
        {ok, {erx_domain, Id, _, _}} = erx_domain:start_session(1, #{}),
        #{machine := {_Grant, rw}} = maps:get(domain_pid(Id), answers([domain_pid(Id)], #{})),
        ?assertEqual([<<"root">>], [Arg || {trace, _, call, {erx_machine_fs, init, [Arg]}} <- flush_traces()])
    after
        erlang:trace(all, false, [call]),
        erlang:trace_pattern({erx_machine_fs, init, 1}, false, [local]),
        files_cleanup(Started)
    end.

%% Every trace message this process holds, in arrival order.
flush_traces() ->
    receive {trace, _, _, _} = Trace -> [Trace | flush_traces()];
            {trace, _, _, _, _} = Trace -> [Trace | flush_traces()]
    after 0 -> []
    end.

%% No configured domain, start the system domain's files service named start, with a
%% test tree's grants behind it, and a trace of the domain pids' receives to this process,
%% with Grants the manifest's.
files_setup(Grants) ->
    tree_setup(start, ?ERX_SERVICE_FILES, Grants).

%% As files_setup/1, for the system domain's service Name of interface Interface.
tree_setup(Name, Interface, Grants) ->
    tree_setup(Name, Interface, Grants, fun() -> erx_fs_grants:start_link(erx_fs_test_tree, []) end).

%% As tree_setup/3, with the grants supervisor Start starts behind the service.
tree_setup(Name, Interface, Grants, Start) ->
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [], services => [{system, Name, Interface}], grants => Grants}),
    {ok, Tree} = Start(),
    unlink(Tree),
    ok = erx_facet:serve(Name, Tree),
    erlang:trace(new_processes, true, ['receive', {tracer, self()}]),
    Fake = erx_domain_fake_lib:start_log(),
    %% The service reads the manifest in its init, so a boot it refuses is start_link's
    %% error, which this case's match fails on, rather than an exit that ends the case
    %% unreported.
    Trap = process_flag(trap_exit, true),
    Result = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                         exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                         mints => #{owner => fun erx_domain_mints_tests:owner/1}}),
    process_flag(trap_exit, Trap),
    {ok, Service} = Result,
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
%% session mark, and the library plans the session with echo as its default display. A
%% display the template is not granted, and two displays, are refused before the session
%% takes an id.
sessions() ->
    ?assertEqual({error, {bad_spec, display}}, erx_domain:start_session(1, #{display => inspect})),
    ?assertEqual({error, {bad_spec, display}}, erx_domain:start_session(1, #{display => echo,
                                                                              default_display => echo})),
    {ok, {erx_domain, 7, _, _} = Session} = erx_domain:start_session(1, #{display => echo}),
    ?assertMatch({session, 7, 0, _, echo}, session_call()),
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
    ?assertMatch({erx_facet_mint, Tag, echo, 7, <<"root">>, #{max_request := 64, session := true}},
                 receive {trace, PidA, 'receive', {_, mint, _, {erx_facet_mint, Tag, _, _, _, _} = R}} -> R
                 after 2000 -> none end),
    Facet = pid('a@erxos', 5, 7),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual(Facet, receive {trace, Pid7, 'receive', {_, install, Tag, echo, F}} -> F after 2000 -> none end),
    PidB ! {erx_origin, 6, {erx_facets_installed, Tag}},
    wait_counts(fun(#{{dropped, wrong_domain} := N}) -> N =:= 1 end),
    Pid7 ! {erx_origin, 7, {erx_facets_installed, Tag}},
    wait(fun(#{Key := {installed, {5, 7}, F}}) -> F =:= Facet end),
    ok = erx_domain:stop(Session, kill),
    wait(fun(Grants) -> not is_map_key(Key, Grants) end),
    PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    wait_counts(fun(#{{dropped, unknown_tag} := N}) -> N =:= 1 end).

%% A session's line (docs/design-system.md, "A session's lines"): erx_domain:line/4 is
%% one call the mint core answers. Session 7's report provides web_line under a pid of
%% its own and ssh_line under one of another node, which refuses that entry alone. A
%% request for web_line with b (6) as peer introduces the two, then sends the mint
%% request to the line through the session's domain pid, with ?ERX_LINES's quantities,
%% the opening and b's user name, and the session's reply with the operation's tag
%% answers the asker with its facet. A second request while one is pending is busy, a
%% refused line and a domain that is no session answer no_line, and after the
%% session's end so does every request.
lines() ->
    {ok, {erx_domain, 7, _, _} = Session} = erx_domain:start_session(1, #{}),
    [PidB, Pid7] = [domain_pid(Id) || Id <- [6, 7]],
    erlang:trace(Pid7, true, ['receive', {tracer, self()}]),
    Opening = self(),
    Asked = gen_server:send_request(erx_domain_srv, {line, web_line, 7, 6, Opening}),
    ?assertEqual({error, busy}, erx_domain:line(web_line, 7, 6, Opening)),
    ?assertEqual({error, no_line}, erx_domain:line(ssh_line, 7, 6, Opening)),
    ?assertEqual({error, no_line}, erx_domain:line(web_line, 5, 6, Opening)),
    ?assertMatch({connect, 7, 6, _, _}, connect_of(7, 6)),
    PidB ! {erx_origin, 6, {erx_connection_mapped, 7}},
    Pid7 ! {erx_origin, 7, {erx_connection_mapped, 6}},
    Mint = pid('root_1@erxos', 7, 3),
    Request = receive {trace, Pid7, 'receive', {_, mint, Mint, R}} -> R after 2000 -> none end,
    ?assertMatch({erx_facet_mint, _, web_line, 6, <<"root">>, #{opening := Opening}}, Request),
    {erx_facet_mint, Tag, _, _, _, Limits} = Request,
    ?assertEqual((maps:get(web_line, ?ERX_LINES))#{opening => Opening}, Limits),
    Facet = pid('root_1@erxos', 7, 9),
    Pid7 ! {erx_origin, 7, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual({reply, {ok, Facet}}, gen_server:wait_response(Asked, 2000)),
    erlang:trace(Pid7, false, ['receive']),
    ok = erx_domain:stop(Session, kill),
    poll(fun() -> erx_domain:line(web_line, 7, 6, Opening) end, fun(Answer) -> Answer =:= {error, no_line} end, 100).

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

%% A wait for a (5) while its grant is minting, unanswered after the service has
%% answered system_namespace/0, which with echo of no files interface waits for
%% nothing; and the grant's tag.
await_minting() ->
    Wait = erx_domain:await_grant(echo, 5),
    #{{system, echo} := {minting, {5, 4}, Tag}} = wait(fun(#{{system, echo} := {minting, _, _}}) -> true end),
    ?assertEqual({reply, ok}, gen_server:receive_response(erx_domain:system_namespace(), 2000)),
    %% wait_response/2 keeps the request on its timeout, where receive_response/2 abandons it.
    ?assertEqual(timeout, gen_server:wait_response(Wait, 200)),
    {Wait, Tag}.

%% The grant installed answers the wait with a's facet, and a later wait at once. A wait
%% for another incarnation, 7, is never answered with a's facet, since the grant carries
%% another server, and a name the system domain is not granted has nothing to wait for.
await_installed() ->
    {Wait, Tag} = await_minting(),
    Facet = pid('a@erxos', 5, 3),
    domain_pid(5) ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual({reply, {ok, Facet}}, gen_server:receive_response(Wait, 2000)),
    ?assertEqual({reply, {ok, Facet}}, gen_server:receive_response(erx_domain:await_grant(echo, 5), 2000)),
    ?assertEqual({reply, {error, ended}}, gen_server:receive_response(erx_domain:await_grant(echo, 7), 2000)),
    ?assertEqual({reply, {error, unprovided}}, gen_server:receive_response(erx_domain:await_grant(other, 5), 2000)).

%% A facet of another node fails the grant, which answers the wait failed.
await_failed() ->
    {Wait, Tag} = await_minting(),
    domain_pid(5) ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, pid('x@erxos', 5, 3)}}},
    ?assertEqual({reply, {error, failed}}, gen_server:receive_response(Wait, 2000)).

%% a's end answers the wait ended, and a wait for it after its restart, 7, at once; a
%% wait for 7 waits for 7's own grant.
await_ended() ->
    {Wait, _Tag} = await_minting(),
    erx_domain_srv ! {domain_ended, 5, {stopped, 0}, #{}},
    ?assertEqual({reply, {error, ended}}, gen_server:receive_response(Wait, 2000)),
    wait(fun(#{{system, echo} := {minting, {7, 4}, _}}) -> true end),
    ?assertEqual({reply, {error, ended}}, gen_server:receive_response(erx_domain:await_grant(echo, 5), 2000)),
    ?assertEqual(timeout, gen_server:wait_response(erx_domain:await_grant(echo, 7), 200)).

%% a ready without echo answers the wait unprovided: its grant is idle and no operation
%% will start for it. A wait for 7, which the core has not heard of, is ended at once:
%% a is not starting, so nothing comes for 7.
await_unprovided() ->
    Wait = erx_domain:await_grant(echo, 5),
    ?assertEqual({reply, {error, unprovided}}, gen_server:receive_response(Wait, 2000)),
    ?assertMatch(#{{system, echo} := idle}, grants()),
    ?assertEqual({reply, {error, ended}}, gen_server:receive_response(erx_domain:await_grant(echo, 7), 2000)).

%% The service over b (row 0) and late (row 1, id 5), which serves screen, a windows
%% service no row is granted.
display_setup() -> display_setup([{1, screen, ?ERX_SERVICE_WINDOWS}], []).

%% The same over late serving Services, and Grants of them.
display_setup(Services, Grants) ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 3, restart_period_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"late">>)],
                          services => Services, grants => Grants}),
    Log = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1,
                                                            deadline => ?DEADLINE}}),
    unlink(Service),
    {Log, Service}.

%% A wait for screen, still unanswered while late starts, and one for a name no row
%% serves, answered at once.
display_waits() ->
    Wait = erx_domain:server_settled(<<"screen">>),
    ?assertEqual({reply, ok}, gen_server:receive_response(erx_domain:server_settled(<<"other">>), 2000)),
    %% wait_response/2 keeps the request on its timeout, where receive_response/2 abandons it.
    ?assertEqual(timeout, gen_server:wait_response(Wait, 200)),
    Wait.

%% late's ready report answers the wait, and a later wait at once.
display_ready() ->
    Wait = display_waits(),
    domain_pid(5) ! {erx_origin, 5, {erx_ready, #{connections => erx_domain_fake_lib:agent(<<"late">>, 5),
                                                  inspect => erx_domain_fake_lib:agent(<<"late">>, 5)}}},
    ?assertEqual({reply, ok}, gen_server:receive_response(Wait, 2000)),
    ?assertEqual({reply, ok}, gen_server:receive_response(erx_domain:server_settled(<<"screen">>), 2000)).

%% late's end answers the wait at the end's step, before its restart starts, which a
%% later wait waits for again (docs/design-system.md, "Waiting for a grant").
display_ended() ->
    Wait = display_waits(),
    exit(domain_pid(5), kill),
    ?assertEqual({reply, ok}, gen_server:receive_response(Wait, 2000)),
    ?assertEqual(timeout, gen_server:wait_response(erx_domain:server_settled(<<"screen">>), 200)).

%% late stopped for its boot timeout answers the wait, as its timer would.
display_timed_out() ->
    Wait = display_waits(),
    erx_domain_srv ! {timeout, make_ref(), {boot_timeout, 5}},
    ?assertEqual({reply, ok}, gen_server:receive_response(Wait, 2000)).

%% The namespace is answered at its own call, echo being no files service, while the
%% others wait; echo's server at late's ready report, while the grant still waits; and
%% late's grant at its installation, once the agent has written the system domain's
%% registry, which then holds the facet the answer names. A query outside the closed
%% set is answered badarg, as is a server named by its atom rather than by its text.
three_askers() ->
    Grant = erx_domain:await_grant(echo, 5),
    Server = erx_domain:server_settled(<<"echo">>),
    ?assertEqual({reply, ok}, gen_server:receive_response(erx_domain:system_namespace(), 2000)),
    [?assertEqual({error, badarg}, gen_server:call(erx_domain_srv, {settled, Query}))
     || Query <- [rogue, {server, echo}, {grant, echo, 0}, {grant, <<"echo">>, 5}]],
    %% wait_response/2 keeps the request on its timeout, where receive_response/2 abandons it.
    ?assertEqual(timeout, gen_server:wait_response(Server, 200)),
    ?assertEqual(timeout, gen_server:wait_response(Grant, 0)),
    domain_pid(5) ! {erx_origin, 5, {erx_ready, #{connections => erx_domain_fake_lib:agent(<<"late">>, 5),
                                                  inspect => erx_domain_fake_lib:agent(<<"late">>, 5),
                                                  provides => #{<<"echo">> => pid('late@erxos', 5, 1)}}}},
    ?assertEqual({reply, ok}, gen_server:receive_response(Server, 2000)),
    #{{system, echo} := {minting, {5, 4}, Tag}} = wait(fun(#{{system, echo} := {minting, _, _}}) -> true end),
    ?assertEqual(timeout, gen_server:wait_response(Grant, 200)),
    Facet = pid('late@erxos', 5, 3),
    domain_pid(5) ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, Facet}}},
    ?assertEqual({reply, {ok, Facet}}, gen_server:receive_response(Grant, 2000)),
    ?assertEqual(Facet, erx_facets:find(echo)).

%% An app's session (docs/design-packaging.md, "An app's session"): the boot's app
%% template, 2, is granted two of a's services, screen (facet row 0), a display of the
%% windows interface, and clip (row 1), of the files interface, and the app clock's
%% admission kept only row 1. Its session is planned under the app's entry with the
%% declared memory, granted clip alone, whose mint carries the app's name as its
%% principal's, and its ready answer names clip alone; the connection clip's grant makes
%% between a and the session carries no pixel area, since the session holds no screen
%% row, though its template does (erx_domain_mints:pair_area/3); its
%% domain pid receives the app's record the registration kept once clip is installed,
%% after the ready answer and before the start is answered. A name not registered is
%% refused.
app_session_test_() ->
    {setup, fun app_setup/0, fun app_cleanup/1,
     fun(_) -> {inorder, [fun no_app/0, {timeout, 20, fun app_session/0}]} end}.

-define(APP_MEMORY, 16777216).
-define(APP_RECORD, #{place => {packages, [<<"clock.app">>]}, layout => #{}, start => {applications, [<<"clock">>]},
                     window => false}).

app_setup() ->
    persistent_term:put({erx_domain_fake_lib, apps}, #{template => 2, first => 6, max => 4, memory => 4 * ?APP_MEMORY}),
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 3, restart_period_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)],
                          services => [{1, screen, ?ERX_SERVICE_WINDOWS}, {1, clip, ?ERX_SERVICE_FILES}],
                          grants => [{{template, 2}, screen, 1, #{max_request => 64}},
                                     {{template, 2}, clip, 1, #{max_request => 32}}]}),
    provide_a(fun(Id) -> #{<<"screen">> => pid('a@erxos', Id, 1), <<"clip">> => pid('a@erxos', Id, 4)} end),
    Log = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                exports => erx_domain_fake_lib, principals => ?PRINCIPALS,
                                                introduce_timeout => ?DEADLINE,
                                                mints => #{owner => fun erx_domain_mints_tests:owner/1,
                                                           deadline => ?DEADLINE}}),
    unlink(Service),
    {Log, Service}.

app_cleanup(Started) ->
    persistent_term:erase({erx_domain_fake_lib, apps}),
    cleanup(Started).

no_app() ->
    ?assertEqual({error, no_app}, erx_domain:start_app(<<"clock">>, #{})).

app_session() ->
    Checked = #{header => #{name => <<"clock">>, layout => #{}, start => {applications, [<<"clock">>]}},
                signer => image, sha256 => <<0:256>>, extent => 1},
    ok = erx_principal:register_app(#{name => <<"clock">>, place => installed, checked => Checked,
                                      admitted => #{signer => image, memory => ?APP_MEMORY,
                                                    rows => [1], ble => none, display => none}}),
    Self = self(),
    erlang:trace(new_processes, true, ['receive', {tracer, Self}]),
    Ref = make_ref(),
    _ = spawn(fun() -> Self ! {Ref, erx_domain:start_app(<<"clock">>, #{})} end),
    try
        {Earlier, Call} = app_session_call([]),
        ?assertMatch({app_session, 7, 0, ?APP_MEMORY, <<"clock_1">>, none}, Call),
        ?assertEqual([], [Stop || {stop, _} = Stop <- Earlier]),
        ?assertEqual({connect, 5, 7, erx_domain_fake_lib:reader(5), erx_domain_fake_lib:reader(7)}, next_connect()),
        [PidA, Pid7] = [domain_pid(Id) || Id <- [5, 7]],
        erlang:trace(PidA, true, ['receive', {tracer, Self}]),
        Key = {{session, 7}, clip},
        #{Key := {introducing, {5, 7}, _}} = Grants = wait(fun(#{Key := {introducing, _, _}}) -> true end),
        ?assertEqual([Key], [K || {{session, 7}, _} = K <- maps:keys(Grants)]),
        PidA ! {erx_origin, 5, {erx_connection_mapped, 7}},
        Pid7 ! {erx_origin, 7, {erx_connection_mapped, 5}},
        #{Key := {minting, {5, 7}, Tag}} = wait(fun(#{Key := {minting, _, _}}) -> true end),
        ?assertMatch({erx_facet_mint, Tag, clip, 7, <<"clock">>, #{max_request := 32}},
                     receive {trace, PidA, 'receive', {_, mint, _, {erx_facet_mint, Tag, _, _, _, _} = R}} -> R
                     after 2000 -> none end),
        PidA ! {erx_origin, 5, {erx_facet_minted, Tag, {ok, pid('a@erxos', 5, 7)}}},
        {Before, {_, install, Tag, clip, _}} = received(Pid7, fun({_, install, _, _, _}) -> true end, []),
        ?assertEqual([[{clip, ?ERX_SERVICE_FILES}]], [Granted || {_, facets, _, Granted} <- Before]),
        %% An app's session holds the code_objects facet too, bound to itself.
        [#{code_objects := CodeObjects}] = [Facets || {_, facets, Facets, _} <- Before],
        ?assertMatch(#{grantee := 7}, erx_facet:info(CodeObjects)),
        ?assertEqual(none, answer(Ref, 200)),
        Pid7 ! {erx_origin, 7, {erx_facets_installed, Tag}},
        ?assertMatch({ok, {erx_domain, 7, _, Pid7}}, answer(Ref, 2000)),
        {Between, {_, app, App}} = received(Pid7, fun({_, app, _}) -> true end, []),
        ?assertEqual(?APP_RECORD, App),
        ?assertEqual([], [M || {_, facets, _, _} = M <- Between]),
        ?assertEqual([Key], [K || {{session, 7}, _} = K <- maps:keys(grants())])
    after
        erlang:trace(all, false, ['receive'])
    end.

%% The fake library's app_session call and the calls before it, in order.
app_session_call(Earlier) ->
    case erx_domain_fake_lib:next_call() of
        {app_session, _, _, _, _, _} = Call -> {lists:reverse(Earlier), Call};
        timeout -> error({no_app_session, lists:reverse(Earlier)});
        Other -> app_session_call([Other | Earlier])
    end.

%% The messages Pid received, from the trace of its receives, up to the first that Match
%% holds for: those before it, in order, and it.
received(Pid, Match, Before) ->
    receive
        {trace, Pid, 'receive', Message} ->
            case (try Match(Message) catch error:function_clause -> false end) of
                true -> {lists:reverse(Before), Message};
                false -> received(Pid, Match, [Message | Before])
            end
    after 2000 ->
            error({not_received, Pid, lists:reverse(Before)})
    end.

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
