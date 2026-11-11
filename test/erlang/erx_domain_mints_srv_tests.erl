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
%% made, a first, and a restarts after each of the test's first three ends.
-module(erx_domain_mints_srv_tests).
-include_lib("eunit/include/eunit.hrl").

-define(DEADLINE, 1000).

mints_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_) -> {inorder, [fun installs/0, {timeout, 20, fun restart/0}, fun foreign_mint/0, {timeout, 20, fun last_end/0}]} end}.

setup() ->
    Row = fun(Row, Place, Name) -> #{row => Row, place => Place, name => Name, principal => 1, kind => service,
                                     restarts => 3, restart_period_s => 60} end,
    persistent_term:put({erx_domain_fake_lib, boot},
                        #{domains => [Row(0, 1, <<"b">>), Row(1, 0, <<"a">>)],
                          services => [{1, echo}],
                          grants => [{0, echo, 1, #{max_request => 512}}, {system, echo, 1, #{}}]}),
    provide('a@erxos'),
    Log = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib, introduce_timeout => 5000,
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1,
                                                            deadline => ?DEADLINE}}),
    unlink(Service),
    {Log, Service}.

cleanup({Log, Service}) ->
    exit(Service, kill),
    exit(Log, kill),
    _ = [persistent_term:erase(Key) || Key <- [{erx_domain_fake_lib, boot}, {erx_domain_fake_lib, provides},
                                               {erx, facets}]],
    ok.

%% a's reports provide echo's mint at Node, with the reporting incarnation's id.
provide(Node) ->
    persistent_term:put({erx_domain_fake_lib, provides}, #{<<"a">> => fun(Id) -> #{echo => pid(Node, Id, 1)} end}).

%% The whole path for both grants: b is introduced to a, a's mint is asked, its reply
%% installs the facet in b's registry through b's domain pid, and b's acknowledgement
%% makes the grant installed; the system domain's grant installs in this runtime's
%% registry at once. A reply from another domain, and an acknowledgement from a, which
%% is not the grantee, are dropped and counted. A reply sent to the service itself, in
%% a's envelope, is not taken at all: the service's pid is no address of the protocol.
installs() ->
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
    #{{0, echo} := {introducing, {7, 6}, _}} = grants(),
    wait(fun(#{{0, echo} := {failed, {7, 6}, {deadline, introducing}}}) -> true end).

%% A report naming a mint of another node, with the reporting incarnation's id as its
%% creation, is refused and counted: the service passes the core the node it knows for
%% the incarnation, never one the report suggests, so the grants have no pair.
foreign_mint() ->
    provide('x@erxos'),
    erx_domain_srv ! {domain_ended, 7, {stopped, 0}, #{}},
    wait(fun(Grants) -> maps:get({system, echo}, Grants) =:= idle andalso maps:get({0, echo}, Grants) =:= idle end),
    ?assertMatch(#{{refused, foreign_mint} := 1}, wait_counts(fun(#{{refused, foreign_mint} := _}) -> true end)).

%% An end with no restart after it, a's fourth, cancels the operation its incarnation,
%% 9, had pending: the grant is idle at once, and stays idle past the deadline the
%% operation had, which was disarmed.
last_end() ->
    provide('a@erxos'),
    erx_domain_srv ! {domain_ended, 8, {stopped, 0}, #{}},
    wait(fun(#{{system, echo} := {minting, {9, 4}, _}}) -> true end),
    erx_domain_srv ! {domain_ended, 9, {stopped, 0}, #{}},
    wait(fun(#{{system, echo} := idle}) -> true end),
    receive after ?DEADLINE + 200 -> ok end,
    ?assertMatch(#{{system, echo} := idle, {0, echo} := idle}, grants()).

%% A configured domain's facets of services the system domain serves: b (row 0) is
%% granted log, which a process of this runtime names with erx_facet:serve/2 before
%% the service starts, and a (row 1) is granted clock, which no service names. b's
%% ready answer carries a facet in front of log's process, bound to b and within the
%% row's max_request; a's carries none, and neither grant reaches the mint core.
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
                                     {1, clock, system, #{max_request => 1}}]}),
    Log = spawn(fun() -> receive stop -> ok end end),
    ok = erx_facet:serve(log, Log),
    Self = self(),
    erlang:trace(new_processes, true, ['receive', {tracer, Self}]),
    Fake = erx_domain_fake_lib:start_log(),
    {ok, Service} = erx_domain_srv:start_link(#{lib => erx_domain_fake_lib, agent => erx_domain_fake_lib,
                                                 exports => erx_domain_fake_lib,
                                                 mints => #{owner => fun erx_domain_mints_tests:owner/1}}),
    unlink(Service),
    {Fake, Service, Log}.

served_cleanup({Fake, Service, Log}) ->
    erlang:trace(new_processes, false, ['receive']),
    _ = [exit(Pid, kill) || Pid <- [Service, Fake, Log]],
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

%% A pid of Node with creation Creation, as a frame from that domain carries one.
pid(Node, Creation, Number) ->
    Name = atom_to_binary(Node),
    binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, Number:32, 0:32, Creation:32>>).

domain_pid(Id) ->
    #{core := Core} = sys:get_state(erx_domain_srv),
    {ok, #{pid := Pid}} = erx_domain_core:fetch(Id, Core),
    Pid.

grants() -> maps:get(grants, gen_server:call(erx_domain_srv, mints)).
counts() -> maps:get(counts, gen_server:call(erx_domain_srv, mints)).

%% The grants once Match holds for them, within two seconds and a deadline.
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
