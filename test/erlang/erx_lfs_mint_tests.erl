%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_lfs_mint_tests).
-moduledoc """
EUnit for erx_lfs_mint, the mint of storage's `data` files service, on stock's
emulator: which messages it takes as mint requests, the erx_fs options a facet row's
limits give a grant, and the grants it starts, each a real erx_fs grant of a test tree
(erx_fs_test_tree) under the mint's grants supervisor. This module stands in for the
export table (export/3), as test/erlang/erx_net_grant_tests.erl does for the network
mint, and a port stands in for this domain's connection to the grantee, which
erx_connections' stand-in answers. A grant's
answers go to aliases of another domain's node, which stock cannot reach, so the tests
read them from a trace of the grant's calls of erlang:send/2.
""".

-include_lib("eunit/include/eunit.hrl").

-export([export/3]).

-define(SYSTEM, 1).
-define(GRANTEE, 5).
-define(THIRD, 9).
-define(WAIT, 5000).
-define(VERSION, <<"9P2000.L">>).

%% Mint requests -------------------------------------------------------------

%% Only a mint request in the system domain's envelope, for this service, is granted.
only_the_system_domains_mint_request_is_granted_test() ->
    Request = {erx_facet_mint, 7, data, ?GRANTEE, #{in_flight => 16}},
    ?assertEqual({grant, 7, ?GRANTEE, #{in_flight => 16}},
                 erx_lfs_mint:mint_request(?SYSTEM, data, {erx_origin, ?SYSTEM, Request})),
    Dropped = [Request,
               {erx_origin, ?GRANTEE, Request},
               {erx_origin, ?SYSTEM, {erx_origin, ?SYSTEM, Request}},
               {erx_origin, ?SYSTEM, setelement(3, Request, net)},
               {erx_origin, ?SYSTEM, setelement(2, Request, 0)},
               {erx_origin, ?SYSTEM, setelement(4, Request, 0)},
               {erx_origin, ?SYSTEM, setelement(5, Request, [])}],
    [?assertEqual(unknown, erx_lfs_mint:mint_request(?SYSTEM, data, Message)) || Message <- Dropped].

%% Grant options -------------------------------------------------------------

%% A row's limits become the grant's bounds, capped at erx_fs_grant's; a row below 9P's
%% least message size, or with a bound that is not positive, is refused.
grant_options_test() ->
    ?assertEqual({ok, #{in_flight => 64, msize => 65560}}, erx_fs_grants:grant_options(#{})),
    ?assertEqual({ok, #{in_flight => 16, msize => 65560, max_heap_size => 262144}},
                 erx_fs_grants:grant_options(#{in_flight => 16, max_request => 65560,
                                              max_heap_size => 262144, reductions => 100})),
    ?assertEqual({ok, #{in_flight => 64, msize => 65560}},
                 erx_fs_grants:grant_options(#{in_flight => 1000, max_request => 131072})),
    ?assertEqual({ok, #{in_flight => 1, msize => 4096}},
                 erx_fs_grants:grant_options(#{in_flight => 1, max_request => 4096})),
    [?assertEqual({error, einval}, erx_fs_grants:grant_options(Limits))
     || Limits <- [#{max_request => 4095}, #{in_flight => 0}, #{max_heap_size => 0}, #{max_heap_size => 100},
                   #{in_flight => many}, #{max_request => -1}, #{max_heap_size => big}]].

%% Limits a row would refuse start no grant and export nothing.
refused_limits_start_no_grant_test() ->
    with_grants(fun(Grants) ->
        ?assertEqual({error, einval}, grant(Grants, #{max_request => 1}, connection())),
        receive {exported, _, _, _, _} -> error(exported) after 0 -> ok end,
        ?assertEqual([], grants(Grants))
    end).

%% Minted grants -------------------------------------------------------------

%% The grant is exported to its grantee, with send alone, while it runs and before its
%% start returns, so no answer names a grant the grantee cannot reach.
the_export_comes_before_the_start_returns_test() ->
    with_grants(fun(Grants) ->
        {ok, Grant} = grant(Grants, #{}, connection()),
        receive
            {exported, Exported, Rights, Peer, Alive} ->
                ?assertEqual({Grant, [send], ?GRANTEE, true}, {Exported, Rights, Peer, Alive})
        after 0 ->
            error(answered_before_export)
        end,
        ?assertEqual([Grant], grants(Grants))
    end).

%% A refused export is the answer, and no grant is left.
a_refused_export_leaves_no_grant_test() ->
    with_grants(fun(Grants) ->
        persistent_term:put({?MODULE, export}, {error, noconnection}),
        ?assertEqual({error, noconnection}, grant(Grants, #{}, connection())),
        Grant = receive {exported, G, _, _, true} -> G after 0 -> error(not_exported) end,
        Ref = monitor(process, Grant),
        receive {'DOWN', Ref, process, Grant, _} -> ok after ?WAIT -> error(grant_left) end,
        ?assertEqual([], grants(Grants))
    end).

%% The grantee's frames, in its own envelope and with its own names, are served, within
%% the row's max_request; a frame in a third domain's envelope, or bare, is dropped.
an_enveloped_exchange_is_served_test() ->
    with_grants(fun(Grants) ->
        {ok, Grant} = grant(Grants, #{max_request => 8192}, connection()),
        Alias = domain_ref(?GRANTEE),
        Frame = {erx_9p, Alias, domain_pid(?GRANTEE), {version, 65560, ?VERSION}},
        trace_sends(Grant),
        Grant ! {erx_origin, ?THIRD, Frame},
        Grant ! Frame,
        Grant ! {erx_origin, ?GRANTEE, Frame},
        ?assertEqual({Alias, {erx_9p, Alias, {ok, 8192, ?VERSION}}}, first_send(Grant))
    end).

%% A grant ends with its connection, and the grants supervisor and the mint, here the
%% test, outlive it. The grantee's next incarnation is a new domain id over a new
%% connection: its grant takes no frame of the old one, in either domain's envelope.
the_grant_ends_with_its_connection_test() ->
    with_grants(fun(Grants) ->
        Old = connection(),
        {ok, Grant} = grant(Grants, #{}, Old),
        Ref = monitor(process, Grant),
        true = port_close(Old),
        receive {'DOWN', Ref, process, Grant, Reason} -> ?assertEqual({shutdown, connection_ended}, Reason)
        after ?WAIT -> error(grant_outlived_connection)
        end,
        ?assert(is_process_alive(Grants)),
        dropped(Grants, Grant, ?WAIT),
        Next = ?GRANTEE + 1,
        ok = erx_connections:set(Next, connection()),
        {ok, NewGrant} = erx_lfs_mint:grant(Grants, ?SYSTEM, Next, #{}, ?MODULE),
        Stale = {erx_9p, domain_ref(?GRANTEE), domain_pid(?GRANTEE), {version, 8192, ?VERSION}},
        trace_sends(NewGrant),
        NewGrant ! {erx_origin, ?GRANTEE, Stale},
        NewGrant ! {erx_origin, Next, Stale},
        Alias = domain_ref(Next),
        NewGrant ! {erx_origin, Next, {erx_9p, Alias, domain_pid(Next), {version, 8192, ?VERSION}}},
        ?assertEqual({Alias, {erx_9p, Alias, {ok, 8192, ?VERSION}}}, first_send(NewGrant))
    end).

%% The system domain's grant ends with no connection, as it lives as long as this
%% domain; another grantee with no connection to this domain gets no grant.
only_the_system_domains_grant_has_no_connection_test() ->
    with_grants(fun(Grants) ->
        {ok, Grant} = erx_lfs_mint:grant(Grants, ?SYSTEM, ?SYSTEM, #{}, ?MODULE),
        ?assertEqual([Grant], grants(Grants)),
        ?assertEqual({error, noconnection}, erx_lfs_mint:grant(Grants, ?SYSTEM, ?THIRD, #{}, ?MODULE)),
        ?assertEqual([Grant], grants(Grants))
    end).

%% Fixtures ------------------------------------------------------------------

%% Runs Fun with a grants supervisor of the test tree, linked to the test as it is to the
%% mint, and with this module as the export table, answering ok.
with_grants(Fun) ->
    persistent_term:put({?MODULE, test}, self()),
    persistent_term:put({?MODULE, export}, ok),
    {ok, Grants} = erx_fs_grants:start_link(erx_fs_test_tree, []),
    try
        Fun(Grants)
    after
        unlink(Grants),
        exit(Grants, kill),
        persistent_term:erase({?MODULE, export}),
        persistent_term:erase({?MODULE, test})
    end.

%% The grantee's grant, over Connection, its stand-in's connection to the grantee.
grant(Grants, Limits, Connection) ->
    ok = erx_connections:set(?GRANTEE, Connection),
    erx_lfs_mint:grant(Grants, ?SYSTEM, ?GRANTEE, Limits, ?MODULE).

grants(Grants) ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(Grants)].

%% The supervisor's 'EXIT' may reach it after the 'DOWN' reaches the test.
dropped(Grants, Grant, Wait) ->
    case lists:member(Grant, grants(Grants)) of
        false -> ok;
        true when Wait > 0 -> timer:sleep(10), dropped(Grants, Grant, Wait - 10);
        true -> error(grant_kept)
    end.

%% A stand-in of the domain's connection to the grantee: a port, whose end is the
%% connection's end.
connection() ->
    open_port({spawn, "cat"}, [binary]).

%% The stand-in of the export table: it tells the test what it was asked and whether the
%% grant ran then, and answers what the test set.
-doc false.
export(Name, Rights, Peer) ->
    persistent_term:get({?MODULE, test}) ! {exported, Name, Rights, Peer, is_process_alive(Name)},
    persistent_term:get({?MODULE, export}).

%% Traces Grant's sends to the test, before the test sends it any frame. Stock drops a
%% send to another node's name without a send event, as no node is connected, so the
%% trace is of the grant's calls of erlang:send/2, through which it answers.
trace_sends(Grant) ->
    _ = erlang:trace_pattern({erlang, send, 2}, true, []),
    1 = erlang:trace(Grant, true, [call]).

%% The first answer Grant sent since trace_sends/1, with its destination. The grant
%% handles the test's frames in order, so an answer to a frame it should have dropped
%% would come first.
first_send(Grant) ->
    receive
        {trace, Grant, call, {erlang, send, [To, {erx_9p, _, _} = Message]}} -> {To, Message}
    after ?WAIT ->
        error(no_answer)
    end.

%% Names of domain D's node, as another domain's arrive here: the node's creation is the
%% domain id, which erx_dist's stand-in reads as the BIF does.
domain_pid(D) ->
    binary_to_term(<<131, 88, 119, 9, "d@erxos11", 1:32, 0:32, D:32>>).

domain_ref(D) ->
    binary_to_term(<<131, 90, 3:16, 119, 9, "d@erxos11", D:32, 1:32, 2:32, 3:32>>).
