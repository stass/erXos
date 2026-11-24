%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a drive's facet, erx_blk_drive_facet, and its window proxy,
%% erx_blk_drive_proxy (docs/design-drives.md, "How the grant reaches the media domain"),
%% and of the mint's request decision, erx_blk_drive:mint_request/3. The facet stands in
%% front of a real drive grant, erx_blk_drive, which this test occupies and serves a
%% stand-in window. This module stands in for the export table, as erx_facet_tests does:
%% every name of the test's own node is the grantee's, so the test's own calls, sent in
%% the grantee's envelope, are the media domain's.
-module(erx_blk_drive_facet_tests).
-include_lib("eunit/include/eunit.hrl").

-export([export/3, owner/1]).

-define(GRANTEE, 7).
-define(SYSTEM, 4).

export(Proxy, Rights, Peer) ->
    persistent_term:put({?MODULE, exported, Proxy}, {Rights, Peer}),
    ok.

owner(_Name) -> ?GRANTEE.

%% A call of the grantee's to Pid, in its envelope; the answer, or none.
call(Pid, Request) ->
    Alias = monitor(process, Pid, [{alias, demonitor}]),
    Pid ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive
        {[alias | Alias], Reply} -> demonitor(Alias, [flush]), Reply;
        {'DOWN', Alias, process, Pid, _} -> down
    after 500 -> demonitor(Alias, [flush]), none
    end.

%% A stand-in window: it tells the test each request and answers none itself.
window(Test) ->
    receive {'$gen_call', From, Request} -> Test ! {got, From, Request}, window(Test) end.

%% A drive grant serving a stand-in window, and a facet in front of it for ?GRANTEE.
setup(InFlight) ->
    [persistent_term:erase(Key) || {{?MODULE, exported, _} = Key, _} <- persistent_term:get()],
    {ok, Grant} = erx_blk_drive:start_link(),
    unlink(Grant),
    Test = self(),
    Window = spawn(fun() -> window(Test) end),
    ok = erx_blk_drive:occupy(Grant, self()),
    ok = erx_blk_drive:serve(Grant, Window, {self(), medium}),
    _ = sys:get_state(Grant),
    {ok, Facet} = erx_facet:start(erx_blk_drive_facet,
                                  #{grantee => ?GRANTEE, ends_with => [self()], operations => [window],
                                    max_request => 65536, in_flight => InFlight, max_heap_size => 131072,
                                    find => fun() -> {ok, Grant} end, exports => ?MODULE},
                                  #{exports => ?MODULE}),
    #{grant => Grant, window => Window, facet => Facet}.

cleanup(#{grant := Grant, window := Window, facet := Facet}) ->
    [exit(P, kill) || P <- [Facet, Window, Grant]],
    ok.

%% The holder reaches only window through the facet: the grant's own calls, occupy and
%% serve, and an ask for another drive are refused before the callback sees them, and
%% the proxy, exported to the grantee with send alone, answers einval to them.
the_holder_reaches_only_window_test() ->
    S = #{facet := Facet} = setup(8),
    try
        ?assertEqual({error, badarg}, call(Facet, {occupy, self()})),
        ?assertEqual({error, badarg}, call(Facet, {serve, self(), {self(), m}})),
        ?assertEqual({error, badarg}, call(Facet, {window, 1})),
        {ok, Proxy} = call(Facet, window),
        ?assertEqual({[send], ?GRANTEE}, persistent_term:get({?MODULE, exported, Proxy})),
        ?assertEqual({error, einval}, call(Proxy, {occupy, self()})),
        ?assertEqual({error, einval}, call(Proxy, window)),
        %% A call outside the grantee's envelope is dropped unanswered.
        ?assertEqual(none, catch_local(Proxy, info))
    after
        cleanup(S)
    end.

catch_local(Pid, Request) ->
    try gen_server:call(Pid, Request, 300) catch exit:{timeout, _} -> none end.

%% The proxy forwards a window request to its window and its answer back, and answers
%% busy to one past in_flight forwarded and unanswered.
the_proxy_admits_no_more_than_in_flight_test() ->
    S = #{facet := Facet} = setup(2),
    try
        {ok, Proxy} = call(Facet, window),
        Callers = [spawn_call(Proxy, {read, N, 1}) || N <- [0, 1]],
        Got = [receive {got, From, Request} -> {From, Request} after 500 -> none end || _ <- Callers],
        ?assertEqual([{read, 0, 1}, {read, 1, 1}], lists:sort([R || {_, R} <- Got])),
        ?assertEqual({error, busy}, call(Proxy, {read, 2, 1})),
        [gen:reply(From, {ok, <<0:4096>>}) || {From, _} <- Got],
        ?assertEqual([{ok, <<0:4096>>}, {ok, <<0:4096>>}],
             [receive {answer, C, A} -> A after 500 -> none end || C <- Callers])
    after
        cleanup(S)
    end.

spawn_call(Proxy, Request) ->
    Test = self(),
    spawn(fun() -> Test ! {answer, self(), call(Proxy, Request)} end).

%% The medium's end leaves no window serving: its window's end ends the proxy, and a
%% next window ask ends the proxy before it, and the facet's end ends its proxy.
a_medium_s_end_leaves_no_proxy_serving_test() ->
    S = #{facet := Facet, window := Window} = setup(8),
    try
        {ok, Proxy} = call(Facet, window),
        Monitor = monitor(process, Proxy),
        exit(Window, kill),
        ?assertMatch(ok, receive {'DOWN', Monitor, process, Proxy, _} -> ok after 500 -> none end),
        ?assertEqual({error, no_medium}, call(Facet, window))
    after
        cleanup(S)
    end.

the_next_ask_and_the_facet_s_end_end_the_proxy_test() ->
    S = #{facet := Facet, grant := Grant} = setup(8),
    try
        {ok, First} = call(Facet, window),
        M1 = monitor(process, First),
        %% The grant ends the old medium at a second ask; the test, its issuer, takes the end.
        Second = spawn_call(Facet, window),
        ?assertMatch(ok, receive {'DOWN', M1, process, First, _} -> ok after 500 -> none end),
        ?assertMatch(ok, receive {erx_blk_drive, end_medium, medium} -> ok after 500 -> none end),
        _ = Grant,
        exit(Facet, kill),
        ?assertMatch(ok, receive {answer, Second, _} -> ok after 1000 -> none end)
    after
        cleanup(S)
    end.

%% A facet that ends while its proxy waits on the grant ends that proxy at once: the proxy
%% leaves the grant unmonitored, and when the grant answers the held ask with the next
%% medium's window no proxy exports itself to the grantee.
the_facet_s_end_mid_ask_ends_the_waiting_proxy_test() ->
    S = #{facet := Facet, grant := Grant, window := Window} = setup(8),
    try
        {ok, First} = call(Facet, window),
        %% The second ask's proxy waits on the grant, which waits on the old medium's end.
        Second = spawn_call(Facet, window),
        ?assertMatch(ok, receive {erx_blk_drive, end_medium, medium} -> ok after 500 -> none end),
        ?assertMatch([_], monitors_of(Grant)),
        exit(Facet, kill),
        ?assertMatch(ok, receive {answer, Second, down} -> ok after 500 -> none end),
        ?assertEqual([], settled(fun() -> monitors_of(Grant) end, [])),
        Test = self(),
        Next = spawn(fun() -> window(Test) end),
        ok = erx_blk_drive:serve(Grant, Next, {self(), next}),
        exit(Window, kill),
        _ = sys:get_state(Grant),
        timer:sleep(50),
        ?assertEqual(lists:sort([Facet, First]), exported()),
        exit(Next, kill)
    after
        cleanup(S)
    end.

%% The processes monitoring Grant, the test's own call monitors excluded.
monitors_of(Grant) ->
    {monitored_by, By} = process_info(Grant, monitored_by),
    [P || P <- By, P =/= self()].

%% Fun's value once it is Expected, or its last value after half a second.
settled(Fun, Expected) -> settled(Fun, Expected, 50).
settled(Fun, _Expected, 0) -> Fun();
settled(Fun, Expected, Tries) ->
    case Fun() of
        Expected -> Expected;
        _ -> timer:sleep(10), settled(Fun, Expected, Tries - 1)
    end.

%% The facets and proxies exported to the grantee since setup.
exported() ->
    lists:sort([P || {{?MODULE, exported, P}, _} <- persistent_term:get()]).

%% The proxy runs under the grant's max_heap_size, and the facet monitors the proxy it
%% has. A grant that names no max_heap_size starts no facet, so no proxy runs unbounded.
the_proxy_runs_under_the_grant_s_heap_bound_test() ->
    S = #{facet := Facet} = setup(8),
    try
        {ok, Proxy} = call(Facet, window),
        ?assertMatch({max_heap_size, #{size := 131072, kill := true, include_shared_binaries := true}},
                     process_info(Proxy, max_heap_size)),
        ?assert(lists:member(Facet, element(2, process_info(Proxy, monitored_by))))
    after
        cleanup(S)
    end.

a_grant_without_a_heap_bound_starts_no_facet_test() ->
    ?assertMatch({error, _},
                 erx_facet:start(erx_blk_drive_facet,
                                 #{grantee => ?GRANTEE, ends_with => [self()], operations => [window],
                                   max_request => 65536, in_flight => 8,
                                   find => fun() -> none end, exports => ?MODULE},
                                 #{exports => ?MODULE})).

%% The mint grants a request of drive in the system domain's envelope for a number its
%% records name, refuses one they do not, and drops every other shape.
mint_request_test() ->
    Find = fun(0) -> none; (_) -> unknown end,
    Request = fun(Origin, Grantee, Limits) ->
                      {erx_origin, Origin, {erx_facet_mint, 5, drive, Grantee, <<"p">>, Limits}}
              end,
    ?assertMatch({grant, 5, #{grantee := ?GRANTEE, drive := 0}},
                 erx_blk_drive:mint_request(?SYSTEM, Find, Request(?SYSTEM, ?GRANTEE, #{drive => 0}))),
    ?assertEqual({refuse, 5}, erx_blk_drive:mint_request(?SYSTEM, Find, Request(?SYSTEM, ?GRANTEE, #{drive => 1}))),
    ?assertEqual(unknown, erx_blk_drive:mint_request(?SYSTEM, Find, Request(?GRANTEE, ?GRANTEE, #{drive => 0}))),
    ?assertEqual(unknown, erx_blk_drive:mint_request(?SYSTEM, Find, Request(?SYSTEM, ?SYSTEM, #{drive => 0}))),
    ?assertEqual(unknown, erx_blk_drive:mint_request(?SYSTEM, Find, Request(?SYSTEM, ?GRANTEE, #{drive => -1}))),
    ?assertEqual(unknown, erx_blk_drive:mint_request(?SYSTEM, Find, Request(?SYSTEM, ?GRANTEE, #{}))).
