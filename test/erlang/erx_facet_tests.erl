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
        ?assertEqual({exported, Facet, [send], ?GRANTEE}, receive {exported, _, _, _} = E -> E after 0 -> none end),
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
%% alias, which is where the reply would go, a message
%% past max_request and a local call are dropped and counted, with no answer.
admits_only_its_grantee_test() ->
    Facet = facet(echo(), domain_pid(), #{max_request => 4096}),
    ?assertEqual({echo, ping}, call(Facet, ping)),
    ?assertEqual(none, call(Facet, ?OTHER, self(), ping)),
    ?assertEqual(none, call(Facet, ?GRANTEE, remote_pid(?OTHER), ping)),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | remote_ref(?OTHER)]}, ping}},
    ?assertEqual(none, call(Facet, binary:copy(<<0>>, 4096))),
    ?assertEqual({echo, small}, call(Facet, small)),
    ?assertEqual(none, try gen_server:call(Facet, ping, 300) catch exit:{timeout, _} -> none end),
    ?assertMatch(#{grantee := ?GRANTEE, dropped := 5, refused := 0, outstanding := 0}, erx_facet:info(Facet)).

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

%% Past the grant's limit in flight a request is refused with {error, badarg}, and a
%% reply that names no outstanding forward reaches no one.
limits_its_forwards_test() ->
    Facet = facet(echo(), domain_pid(), #{in_flight => 1}),
    ?assertEqual(none, call(Facet, hold)),
    ?assertEqual({error, badarg}, call(Facet, ping)),
    Facet ! {[alias | make_ref()], forged},
    ?assertMatch(#{dropped := 1, refused := 1, outstanding := 1}, erx_facet:info(Facet)).

%% The facet ends with its grantee's domain pid, and with the process behind it, with
%% the same reason; a grant whose process has already ended starts no facet.
ends_with_its_grant_test() ->
    Domain = domain_pid(),
    Facet = facet(echo(), Domain, #{}),
    Monitor = monitor(process, Facet),
    exit(Domain, {domain_down, ?GRANTEE, stopped}),
    ?assertEqual({domain_down, ?GRANTEE, stopped}, receive {'DOWN', Monitor, process, _, R} -> R after 1000 -> timeout end),
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
