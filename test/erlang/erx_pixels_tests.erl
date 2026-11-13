%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pixels_tests).
-moduledoc """
EUnit cases of the allocator erx_pixels (docs/design-display.md, "The pixel
area", and Verification), over erx_area's own NIF built for the host with
test/display/erx_area_harness.c (test/host/erx_area_lease_test.rb). A stand-in
for the connection agent, registered as erx_connections, maps a writable area
of four pages for each of the displays 7 and 8 and answers erx_area:open/1;
the harness's take/3 and give/1 stand in for the program driver.
""".

-include_lib("eunit/include/eunit.hrl").

-define(PAGE, 4096).
-define(PAGES, 4).

%% Runs Case with an agent and an allocator, and stops both after it.
with(Case) ->
    Test = self(),
    Agent = spawn(fun() -> agent(Test) end),
    receive {agent_ready, Agent} -> ok end,
    {ok, Pixels} = gen_server:start({local, erx_pixels}, erx_pixels, [], []),
    try
        Case()
    after
        gen_server:stop(Pixels),
        Agent ! stop
    end.

%% The agent: maps the areas in its own process, as erx_connections does, and
%% tells the test of each area's unmap.
agent(Test) ->
    Areas = maps:from_list([{Peer, map_area(Peer)} || Peer <- [7, 8]]),
    true = register(erx_connections, self()),
    Test ! {agent_ready, self()},
    agent_loop(Test, Areas).

map_area(Peer) ->
    {ok, Area} = erx_area:map(20 + Peer, ?PAGES * ?PAGE, write, {area, Peer}),
    Area.

agent_loop(Test, Areas) ->
    receive
        {'$gen_call', From, {area, Peer}} ->
            gen:reply(From, case Areas of
                                #{Peer := Area} -> {ok, Area, ?PAGES * ?PAGE};
                                #{} -> {error, none}
                            end),
            agent_loop(Test, Areas);
        {get, Peer, Pid} ->
            Pid ! {area, maps:get(Peer, Areas)},
            agent_loop(Test, Areas);
        {lose, Peer, Pid} ->
            self() ! {collect, Pid},
            agent_loop(Test, maps:remove(Peer, Areas));
        {collect, Pid} ->
            erlang:garbage_collect(),
            Pid ! lost,
            agent_loop(Test, Areas);
        {erx_area_unmapped, Tag} ->
            Test ! {unmapped, Tag},
            agent_loop(Test, Areas);
        stop ->
            ok
    end.

agent_area(Peer) ->
    erx_connections ! {get, Peer, self()},
    receive {area, Area} -> Area end.

lose(Peer) ->
    erx_connections ! {lose, Peer, self()},
    receive lost -> ok end.

unmapped(Peer) ->
    receive {unmapped, {area, Peer}} -> ok after 1000 -> timeout end.

%% A process that owns ranges: it runs funs on request until stopped.
client() ->
    Pid = spawn(fun client_loop/0),
    {Pid, monitor(process, Pid)}.

client_loop() ->
    receive
        {run, Fun, From, Ref} -> From ! {Ref, Fun()}, client_loop();
        stop -> ok
    end.

ask({Pid, _}, Fun) ->
    Ref = make_ref(),
    Pid ! {run, Fun, self(), Ref},
    Ref.

answer(Ref, Timeout) ->
    receive {Ref, Answer} -> Answer after Timeout -> timeout end.

run(Client, Fun) ->
    answer(ask(Client, Fun), 1000).

pid({Pid, _}) -> Pid.

%% Stops a client. The allocator may take its 'DOWN' after a later request of
%% another process, so a case that needs it seen retries (eventually/2).
stop({Pid, Ref}) ->
    Pid ! stop,
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    ok.

%% Retries Fun until it answers Expected, for a message the allocator gets from
%% another sender, such as a lease's return from the driver.
eventually(Fun, Expected) ->
    eventually(Fun, Expected, 100).

eventually(Fun, Expected, 0) ->
    Fun() =:= Expected orelse error({never, Expected});
eventually(Fun, Expected, Tries) ->
    case Fun() of
        Expected -> true;
        _ -> timer:sleep(10), eventually(Fun, Expected, Tries - 1)
    end.

%% A request no client function makes, sent by any process, is refused and
%% leaves the allocator running.
raw_requests_are_refused_test() ->
    with(fun() ->
        Pixels = whereis(erx_pixels),
        [?assertEqual({error, badarg}, gen_server:call(erx_pixels, R))
         || R <- [foo, {alloc, 7, 0}, {alloc, foo, 1}, {lend, 7, -1}, {unlend, 0}]],
        A = client(),
        {ok, 0} = run(A, fun() -> erx_pixels:alloc(7, ?PAGE) end),
        erx_pixels ! {'DOWN', make_ref(), process, pid(A), forged},
        ?assertEqual({error, enomem}, erx_pixels:alloc(7, ?PAGES * ?PAGE)),
        ?assertEqual(Pixels, whereis(erx_pixels)),
        stop(A)
    end).

lend_refusals_test() ->
    with(fun() ->
        A = client(),
        B = client(),
        ?assertEqual({ok, 0}, run(A, fun() -> erx_pixels:alloc(7, 2 * ?PAGE) end)),
        ?assertEqual({ok, 0}, run(B, fun() -> erx_pixels:alloc(8, 1) end)),
        ?assertMatch({ok, L, 2} when L >= 1, run(A, fun() -> erx_pixels:lend(7, 0) end)),
        ?assertEqual({error, einval}, run(B, fun() -> erx_pixels:lend(7, 0) end)),
        ?assertEqual({error, einval}, run(A, fun() -> erx_pixels:lend(7, ?PAGE) end)),
        ?assertEqual({error, einval}, run(A, fun() -> erx_pixels:lend(8, 0) end)),
        ?assertEqual({error, einval}, run(A, fun() -> erx_pixels:lend(9, 0) end)),
        ?assertEqual({error, none}, run(A, fun() -> erx_pixels:alloc(9, 1) end)),
        ?assertEqual({error, enomem}, run(A, fun() -> erx_pixels:alloc(7, 3 * ?PAGE) end)),
        stop(A),
        stop(B)
    end).

lend_waits_for_the_last_return_test() ->
    with(fun() ->
        A = client(),
        B = client(),
        {ok, 0} = run(A, fun() -> erx_pixels:alloc(7, ?PAGE) end),
        {ok, First, 1} = run(A, fun() -> erx_pixels:lend(7, 0) end),
        ok = erx_area:take(First, pid(A), 1),
        Waiting = ask(A, fun() -> erx_pixels:lend(7, 0) end),
        ?assertEqual(timeout, answer(Waiting, 200)),
        ok = erx_area:give(First),
        {ok, Second, 1} = answer(Waiting, 1000),
        ?assert(Second > First),
        ?assertEqual(ok, run(A, fun() -> erx_pixels:unlend(Second) end)),
        {ok, Third, 1} = run(A, fun() -> erx_pixels:lend(7, 0) end),
        ?assertEqual(ok, run(B, fun() -> erx_pixels:unlend(Third) end)),
        ?assertEqual(ok, erx_area:take(Third, pid(A), 1)),
        ok = erx_area:give(Third),
        stop(A),
        stop(B)
    end).

%% Only the area NIF knows a lease's tag: a forged return, by the lease's
%% number alone or with a tag of the sender's own, leaves the range lent, so
%% the next lend of it still waits for the program's teardown.
forged_return_changes_nothing_test() ->
    with(fun() ->
        A = client(),
        {ok, 0} = run(A, fun() -> erx_pixels:alloc(7, ?PAGE) end),
        {ok, Lease, 1} = run(A, fun() -> erx_pixels:lend(7, 0) end),
        ok = erx_area:take(Lease, pid(A), 1),
        %% From A, so both arrive before A's next lend.
        ok = run(A, fun() ->
                        erx_pixels ! {erx_area_returned, Lease},
                        erx_pixels ! {erx_area_returned, make_ref(), Lease},
                        ok
                    end),
        Waiting = ask(A, fun() -> erx_pixels:lend(7, 0) end),
        ?assertEqual(timeout, answer(Waiting, 200)),
        ok = erx_area:give(Lease),
        {ok, Second, 1} = answer(Waiting, 1000),
        ?assertEqual(ok, run(A, fun() -> erx_pixels:unlend(Second) end)),
        stop(A)
    end).

reuse_is_zeroed_test() ->
    with(fun() ->
        A = client(),
        B = client(),
        C = client(),
        Area = agent_area(7),
        {ok, 0} = run(A, fun() -> erx_pixels:alloc(7, 2 * ?PAGE) end),
        {ok, Kept} = run(B, fun() -> erx_pixels:alloc(7, ?PAGE) end),
        ok = erx_area:poke(Area, 0, binary:copy(<<16#5a>>, 3 * ?PAGE)),
        stop(A),
        ?assert(eventually(fun() -> run(C, fun() -> erx_pixels:alloc(7, 2 * ?PAGE) end) end, {ok, 0})),
        ?assertEqual(binary:copy(<<0>>, 2 * ?PAGE), erx_area:peek(Area, 0, 2 * ?PAGE)),
        ?assertEqual(binary:copy(<<16#5a>>, ?PAGE), erx_area:peek(Area, Kept, ?PAGE)),
        stop(B),
        stop(C)
    end).

orphaned_range_stays_out_until_returned_test() ->
    with(fun() ->
        A = client(),
        B = client(),
        {ok, 0} = run(A, fun() -> erx_pixels:alloc(8, ?PAGES * ?PAGE) end),
        {ok, Lease, ?PAGES} = run(A, fun() -> erx_pixels:lend(8, 0) end),
        ok = erx_area:take(Lease, pid(A), ?PAGES),
        stop(A),
        ?assertEqual({error, enomem}, run(B, fun() -> erx_pixels:alloc(8, 1) end)),
        ok = erx_area:give(Lease),
        ?assert(eventually(fun() -> run(B, fun() -> erx_pixels:alloc(8, 1) end) end, {ok, 0})),
        stop(B)
    end).

area_is_let_go_once_no_range_is_live_test() ->
    with(fun() ->
        A = client(),
        {ok, 0} = run(A, fun() -> erx_pixels:alloc(7, ?PAGE) end),
        {ok, Lease, 1} = run(A, fun() -> erx_pixels:lend(7, 0) end),
        ok = erx_area:take(Lease, pid(A), 1),
        lose(7),
        stop(A),
        ?assertEqual(timeout, receive {unmapped, {area, 7}} -> ok after 100 -> timeout end),
        ok = erx_area:give(Lease),
        ?assertEqual(ok, unmapped(7))
    end).
