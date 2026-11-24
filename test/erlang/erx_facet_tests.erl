%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the facet behaviour, erx_facet, minted as the domain service mints
%% one, an erx_domain_facet in front of a process of its own domain. This module stands
%% in for the export table (erx_dist:export/3 and owner/1): an export is sent to the
%% process registered as erx_facet_tests, and every name of the test's own node stands
%% for a name of the grantee's, so the test's own calls are the grantee's, and a name
%% of another node is its creation's, as edit 16 reads it.
-module(erx_facet_tests).
-include_lib("eunit/include/eunit.hrl").
-export([export/3, owner/1]).
%% The callback of a facet whose grant lists operations: it forwards every request and
%% message to the process behind, and a request {Operation, _} invokes Operation.
-export([init/1, admit/3, message/2, operation/1]).

-define(GRANTEE, 7).
-define(OTHER, 9).

export(Pid, Rights, Peer) ->
    erx_facet_tests ! {exported, Pid, Rights, Peer},
    ok.

owner(Name) when node(Name) =:= node() ->
    ?GRANTEE;
owner(Pid) when is_pid(Pid) ->
    <<131, 88, 119, Length, _Node:Length/binary, _Number:32, _Serial:32, Creation:32>> = term_to_binary(Pid),
    Creation;
owner(Ref) when is_reference(Ref) ->
    <<131, 90, _Count:16, 119, Length, _Node:Length/binary, Creation:32, _Ids/binary>> = term_to_binary(Ref),
    Creation.

%% A pid of domain Id's node, as a frame from that domain carries one.
remote_pid(Id) ->
    binary_to_term(<<131, 88, 119, 9, "x@erxos11", 1:32, 0:32, Id:32>>).

%% A reference of domain Id's node, as a frame from that domain carries one.
remote_ref(Id) ->
    binary_to_term(<<131, 90, 3:16, 119, 9, "x@erxos11", Id:32, 1:32, 2:32, 3:32>>).

%% A facet granted to ?GRANTEE in front of Behind, with Grant's limits besides, that
%% ends with Ends.
facet(Behind, Ends, Grant) ->
    true = register(erx_facet_tests, self()),
    try
        {ok, Facet} = erx_facet:start(erx_domain_facet,
                                      Grant#{grantee => ?GRANTEE, ends_with => [Ends, Behind], behind => Behind},
                                      #{exports => ?MODULE}),
        %% The facet exported itself toward its grantee, with send alone, before start/3
        %% answered.
        ?assertEqual({exported, Facet, [send], ?GRANTEE}, receive {exported, Facet, _, _} = E -> E after 0 -> none end),
        Facet
    after
        unregister(erx_facet_tests)
    end.

init(#{hang := Watcher}) ->
    Watcher ! {watch, self()},
    receive after infinity -> {ok, Watcher} end;
init(#{behind := Behind}) ->
    {ok, Behind}.

admit({crash, Secret}, _From, _Behind) ->
    error({badmatch, Secret});
admit(Request, _From, Behind) ->
    {forward, Behind, Request, Behind}.

message(_Message, Behind) ->
    {forward, Behind, Behind}.

operation({Operation, _}) when is_atom(Operation) ->
    {ok, Operation};
operation(_Request) ->
    error.

%% A facet of this module's callback granted to ?GRANTEE in front of Behind, with
%% Grant's operations.
operations_facet(Behind, Grant) ->
    true = register(erx_facet_tests, self()),
    try
        {ok, Facet} = erx_facet:start(?MODULE, Grant#{grantee => ?GRANTEE, ends_with => [domain_pid(), Behind],
                                                      behind => Behind}, #{exports => ?MODULE}),
        {exported, Facet, [send], ?GRANTEE} = receive {exported, Facet, _, _} = E -> E after 0 -> none end,
        Facet
    after
        unregister(erx_facet_tests)
    end.

%% A process of the facet's own domain that answers every gen_server call with
%% {echo, Request}, or, told hold, keeps the call unanswered.
echo() ->
    spawn(fun Loop() ->
                  receive
                      {'$gen_call', _From, hold} -> Loop();
                      {'$gen_call', From, Request} -> gen:reply(From, {echo, Request}), Loop()
                  end
          end).

%% Holds until killed: the domain pid a facet ends with.
domain_pid() ->
    spawn(fun() -> receive after infinity -> ok end end).

%% A gen_server call of Request to Facet, as it arrives from domain D: in the envelope,
%% from a caller of Caller's with a fresh alias of the test's as its tag. The reply, or
%% none if none came in 300 ms.
call(Facet, D, Caller, Request) ->
    Alias = alias(),
    Facet ! {erx_origin, D, {'$gen_call', {Caller, [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after 300 -> none end.

call(Facet, Request) ->
    call(Facet, ?GRANTEE, self(), Request).

%% The grantee's call is forwarded to the process behind and its reply returned; what any
%% other domain sends, what the grantee sends naming another domain's caller or reply
%% alias, which is where the reply would go, a call whose tag is no reply alias or whose
%% caller is no pid, a message past max_request and a local call are dropped and counted,
%% with no answer; none reaches the process behind as a message.
admits_only_its_grantee_test() ->
    Facet = facet(echo(), domain_pid(), #{max_request => 4096}),
    ?assertEqual({echo, ping}, call(Facet, ping)),
    ?assertEqual(none, call(Facet, ?OTHER, self(), ping)),
    ?assertEqual(none, call(Facet, ?GRANTEE, remote_pid(?OTHER), ping)),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | remote_ref(?OTHER)]}, ping}},
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), make_ref()}, ping}},
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {not_a_pid, [alias | make_ref()]}, ping}},
    ?assertEqual(none, call(Facet, binary:copy(<<0>>, 4096))),
    ?assertEqual({echo, small}, call(Facet, small)),
    ?assertEqual(none, try gen_server:call(Facet, ping, 300) catch exit:{timeout, _} -> none end),
    ?assertMatch(#{grantee := ?GRANTEE, dropped := 7, refused := 0, outstanding := 0}, erx_facet:info(Facet)).

%% A message of the grantee's that is no call reaches the process behind, here the test,
%% as {'$erx_facet_message', ReplyTo, Grantee, Message}, whose answer the facet takes and
%% drops; another domain's message, one past max_request and one past the limit in
%% flight are dropped and counted, with nothing forwarded.
forwards_its_grantees_messages_test() ->
    Facet = facet(self(), domain_pid(), #{max_request => 64, in_flight => 2}),
    Facet ! {erx_origin, ?GRANTEE, {tty_output, 0, <<"hi">>}},
    {From, Forwarded} = receive {'$erx_facet_message', {Facet, _} = F, G, M} -> {F, {G, M}}
                        after 1000 -> {none, none} end,
    ?assertEqual({?GRANTEE, {tty_output, 0, <<"hi">>}}, Forwarded),
    gen:reply(From, ok),
    Facet ! {erx_origin, ?OTHER, hello},
    Facet ! {erx_origin, ?GRANTEE, binary:copy(<<0>>, 64)},
    [Facet ! {erx_origin, ?GRANTEE, Word} || Word <- [one, two, three]],
    [?assertEqual({?GRANTEE, Word},
                  receive {'$erx_facet_message', {Facet, _}, G2, M2} -> {G2, M2} after 1000 -> none end)
     || Word <- [one, two]],
    ?assertEqual(none, receive {'$erx_facet_message', _, _, M3} -> M3 after 300 -> none end),
    ?assertMatch(#{grantee := ?GRANTEE, dropped := 3, refused := 0, outstanding := 2}, erx_facet:info(Facet)).

%% Past the grant's limit in flight a request is refused with {error, busy}, and a
%% reply that names no outstanding forward reaches no one.
limits_its_forwards_test() ->
    Facet = facet(echo(), domain_pid(), #{in_flight => 1}),
    ?assertEqual(none, call(Facet, hold)),
    ?assertEqual({error, busy}, call(Facet, ping)),
    Facet ! {[alias | make_ref()], forged},
    ?assertMatch(#{dropped := 1, refused := 1, outstanding := 1}, erx_facet:info(Facet)).

%% The facet ends with its grantee's domain pid, and with the process behind it, with
%% the leading atom of the reason alone (docs/design-domains.md, "A facet's end carries no
%% terms"): a service's reason can hold what one grantee sent it, and the facet's monitors
%% are every grantee's. A grant whose process has already ended starts no facet.
ends_with_its_grant_test() ->
    Domain = domain_pid(),
    Facet = facet(echo(), Domain, #{}),
    Monitor = monitor(process, Facet),
    exit(Domain, {domain_down, ?GRANTEE, stopped}),
    ?assertEqual(domain_down, receive {'DOWN', Monitor, process, _, R} -> R after 1000 -> timeout end),
    Secret = echo(),
    Cut = facet(Secret, domain_pid(), #{}),
    CutMonitor = monitor(process, Cut),
    exit(Secret, {badarg, <<"sentinel passphrase">>}),
    ?assertEqual(badarg, receive {'DOWN', CutMonitor, process, _, R1} -> R1 after 1000 -> timeout end),
    Behind = echo(),
    Second = facet(Behind, domain_pid(), #{}),
    SecondMonitor = monitor(process, Second),
    exit(Behind, kill),
    ?assertEqual(killed, receive {'DOWN', SecondMonitor, process, _, R2} -> R2 after 1000 -> timeout end),
    {Gone, GoneMonitor} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', GoneMonitor, process, Gone, normal} -> ok end,
    ?assertEqual({error, noproc},
                 erx_facet:start(erx_domain_facet, #{grantee => ?GRANTEE, ends_with => [Gone], behind => Gone},
                                 #{exports => ?MODULE})).

%% The facet ends with a port of its grant, as a grantee's connection is one
%% (erx_connections:connection/1), when that port closes; a grant whose port has already
%% closed starts no facet, nor does one that names neither a process nor a port.
ends_with_a_connection_port_test() ->
    Connection = open_port({spawn_executable, "/bin/cat"}, [binary]),
    Facet = facet(echo(), Connection, #{}),
    Monitor = monitor(process, Facet),
    ?assertEqual({echo, ping}, call(Facet, ping)),
    true = port_close(Connection),
    ?assertEqual(normal, receive {'DOWN', Monitor, process, _, R} -> R after 1000 -> timeout end),
    ?assertEqual({error, noproc},
                 erx_facet:start(erx_domain_facet, #{grantee => ?GRANTEE, ends_with => [Connection], behind => echo()},
                                 #{exports => ?MODULE})),
    ?assertEqual({error, badarg},
                 erx_facet:start(erx_domain_facet, #{grantee => ?GRANTEE, ends_with => [connection], behind => echo()},
                                 #{exports => ?MODULE})).

%% A forward's service that ends before it replies, killed as OTP kills a query worker at
%% its heap limit, answers the grantee's caller {error, failed}, and the facet lives on.
a_forwards_service_that_ends_answers_failed_test() ->
    Killed = spawn(fun() -> receive {'$gen_call', _From, _Request} -> exit(kill) end end),
    true = register(erx_facet_tests, self()),
    {ok, Facet} = try erx_facet:start(erx_domain_facet, #{grantee => ?GRANTEE, ends_with => [domain_pid()], behind => Killed},
                                      #{exports => ?MODULE})
                  after unregister(erx_facet_tests)
                  end,
    ?assertEqual({error, failed}, call(Facet, ping)),
    ?assertMatch(#{outstanding := 0}, erx_facet:info(Facet)).

%% A mint's reply goes to the domain's own domain pid, which the connection agent names
%% in {erx, domain_pid}; a domain with none has no system connection to reply over.
minted_replies_through_the_domain_pid_test() ->
    persistent_term:erase({erx, domain_pid}),
    ?assertEqual({error, noconnection}, erx_facet:minted(7, {ok, self()})),
    persistent_term:put({erx, domain_pid}, self()),
    try
        ?assertEqual(ok, erx_facet:minted(7, {ok, self()})),
        Self = self(),
        ?assertEqual({ok, Self}, receive {erx_facet_minted, 7, Reply} -> Reply after 1000 -> timeout end),
        %% A refusal crosses as refused, whatever its reason.
        ?assertEqual(ok, erx_facet:minted(8, {error, {enospc, "data"}})),
        ?assertEqual(refused, receive {erx_facet_minted, 8, Refusal} -> Refusal after 1000 -> timeout end)
    after
        persistent_term:erase({erx, domain_pid})
    end.

%% A mint named before init's ready report joins the report's provides; once init has
%% taken them and left reported in their place, a later one is refused, since no report
%% would carry it to the domain service.
provide_is_refused_after_the_report_test() ->
    persistent_term:erase({erx, provides}),
    try
        Self = self(),
        ?assertEqual(ok, erx_facet:provide(echo, Self)),
        ?assertEqual(#{echo => Self}, persistent_term:get({erx, provides})),
        persistent_term:put({erx, provides}, reported),
        ?assertEqual({error, reported}, erx_facet:provide(other, Self)),
        ?assertEqual(reported, persistent_term:get({erx, provides}))
    after
        persistent_term:erase({erx, provides})
    end.

%% A grant's operations are its callback's to check: a request of an operation the
%% grant lists is forwarded, one of another refused with {error, eperm} and one that
%% invokes none with {error, badarg}, before the callback's admit/3 sees either; a
%% message of another operation is dropped before message/2. A grant that lists none,
%% or names no operations, admits nothing.
admits_only_its_grants_operations_test() ->
    Facet = operations_facet(echo(), #{operations => [read]}),
    ?assertEqual({echo, {read, 1}}, call(Facet, {read, 1})),
    ?assertEqual({error, eperm}, call(Facet, {write, 1})),
    ?assertEqual({error, badarg}, call(Facet, ping)),
    ?assertMatch(#{refused := 2, dropped := 0}, erx_facet:info(Facet)),
    Behind = operations_facet(self(), #{operations => [read]}),
    Behind ! {erx_origin, ?GRANTEE, {write, 2}},
    Behind ! {erx_origin, ?GRANTEE, {read, 2}},
    ?assertEqual({read, 2}, receive {'$erx_facet_message', _, ?GRANTEE, M} -> M after 1000 -> none end),
    ?assertMatch(#{dropped := 1}, erx_facet:info(Behind)),
    [?assertEqual({error, eperm}, call(operations_facet(echo(), Grant), {read, 1})) || Grant <- [#{operations => []}, #{}]].

%% A grant that lists operations to a callback with no operation/1 to check them starts
%% no facet; one that lists none starts one that admits what the callback admits.
a_grant_s_operations_need_a_checking_callback_test() ->
    Grant = #{grantee => ?GRANTEE, ends_with => [domain_pid()], behind => echo()},
    ?assertEqual({error, unchecked_operations},
                 erx_facet:start(erx_domain_facet, Grant#{operations => [read]}, #{exports => ?MODULE})),
    ?assertEqual({error, badarg}, erx_facet:start(?MODULE, Grant#{operations => read}, #{exports => ?MODULE})),
    Facet = facet(echo(), domain_pid(), #{operations => []}),
    ?assertEqual({echo, {write, 1}}, call(Facet, {write, 1})).

%% A facet whose init never reports is killed at start/3's timeout, and start/3 answers
%% {error, timeout} only once it has ended (docs/design-system.md, "A session's lines",
%% the replacement test): a watcher that monitors the facet from its init on has its
%% 'DOWN' before the refusal reaches the test, so no failed start overlaps the next, and
%% start/3 has taken its own monitor's 'DOWN', which a start that answers before the
%% facet has ended would leave in its caller's queue.
a_timed_out_start_has_ended_before_it_answers_test_() ->
    {timeout, 30, fun() ->
        Watcher = spawn(fun watcher/0),
        Grant = #{grantee => ?GRANTEE, ends_with => [domain_pid()], hang => Watcher},
        ?assertEqual({error, timeout}, erx_facet:start(?MODULE, Grant, #{exports => ?MODULE})),
        Watcher ! {seen, self()},
        ?assertEqual({down, killed}, receive {Watcher, Seen} -> Seen after 1000 -> none end),
        ?assertEqual(none, receive {'DOWN', _, process, _, _} = Down -> Down after 200 -> none end)
    end}.

%% Monitors the process that names itself with {watch, Pid}, and answers {seen, From}
%% with that monitor's 'DOWN', waiting a second for it, since nothing orders the
%% facet's signal to the watcher before the test's.
watcher() ->
    receive {watch, Pid} -> watched(Pid, monitor(process, Pid)) end.

watched(Pid, Monitor) ->
    receive {seen, From} ->
        From ! {self(), receive {'DOWN', Monitor, process, Pid, Reason} -> {down, Reason} after 1000 -> alive end}
    end.

%% A callback that crashes on a request whose reason holds the request ends the facet with
%% the reason's leading atom alone: its grantee's caller gets no answer and its monitors
%% see no byte of the request (docs/design-domains.md, "A facet's end carries no terms").
a_callback_crash_ends_the_facet_with_an_atom_test() ->
    Facet = operations_facet(echo(), #{operations => [crash]}),
    Monitor = monitor(process, Facet),
    ?assertEqual(none, call(Facet, {crash, <<"sentinel passphrase">>})),
    ?assertEqual(badmatch, receive {'DOWN', Monitor, process, _, R} -> R after 1000 -> timeout end).
