%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of a drive process, erx_media_drive (docs/design-drives.md,
%% "Concurrency"), in front of a stand-in facet that tells the test each window ask
%% and answers what the test gives it, and a stand-in proxy that answers sector
%% requests.
-module(erx_media_drive_tests).
-include_lib("eunit/include/eunit.hrl").

%% A stand-in facet: each window ask goes to the test, which answers it.
facet(Test) ->
    receive {'$gen_call', From, window} -> Test ! {asked, From}, facet(Test) end.

%% A stand-in proxy: a read answers the sector's number repeated, a write ok, and info
%% eio, so the drive process's reading of the medium fails and leaves it idle.
proxy() ->
    receive
        {'$gen_call', From, info} -> gen:reply(From, {error, eio}), proxy();
        {'$gen_call', From, {read, Sector, 1}} -> gen:reply(From, {ok, <<Sector:4096>>}), proxy();
        {'$gen_call', From, {write, _Sector, _Bytes}} -> gen:reply(From, ok), proxy()
    end.

start(Find) ->
    {ok, Drive} = erx_media_drive:start_link(0, Find),
    unlink(Drive),
    Drive.

%% The test's answer to the next window ask, and the drive process's answer to its ask.
answered(Drive, Answer) ->
    Test = self(),
    Caller = spawn(fun() -> Test ! {medium, self(), gen_server:call(Drive, medium, 5000)} end),
    ok = receive {asked, From} -> gen:reply(From, Answer) after 1000 -> no_ask end,
    receive {medium, Caller, Medium} -> Medium after 1000 -> none end.

%% The facet's proxy is the medium, held while it lives without asking again, idle when
%% its reading fails, and read and written through.
the_facet_s_proxy_is_the_medium_until_it_ends_test() ->
    Test = self(),
    Facet = spawn(fun() -> facet(Test) end),
    Proxy = spawn(fun proxy/0),
    Drive = start(fun() -> Facet end),
    try
        Idle = {ok, #{proxy => Proxy, table => {failed, {info, {error, eio}}}}},
        ?assertEqual(Idle, answered(Drive, {ok, Proxy})),
        ?assertEqual(Idle, gen_server:call(Drive, medium)),
        ?assertEqual({ok, <<7:4096>>}, gen_server:call(Proxy, {read, 7, 1})),
        ?assertEqual(ok, gen_server:call(Proxy, {write, 7, <<0:4096>>})),
        %% The proxy's end is the medium's: the next ask asks the facet again.
        exit(Proxy, kill),
        _ = sys:get_state(Drive),
        ?assertEqual({error, no_medium}, answered(Drive, {error, no_medium}))
    after
        [exit(P, kill) || P <- [Drive, Facet, Proxy]]
    end.

%% Any answer but a proxy, and a facet the registry does not hold, are no medium, and
%% leave nothing held.
no_proxy_is_no_medium_test() ->
    Test = self(),
    Facet = spawn(fun() -> facet(Test) end),
    Drive = start(fun() -> Facet end),
    Absent = start(fun() -> undefined end),
    try
        ?assertEqual({error, no_medium}, answered(Drive, {error, failed})),
        ?assertEqual({error, no_medium}, answered(Drive, {error, busy})),
        ?assertEqual({error, no_medium}, answered(Drive, {ok, not_a_pid})),
        ?assertEqual({error, no_medium}, gen_server:call(Absent, medium)),
        ?assertEqual({error, badarg}, gen_server:call(Drive, {window, 1}))
    after
        [exit(P, kill) || P <- [Drive, Absent, Facet]]
    end.

%% A facet that ends before it answers is no medium, and the drive process lives on.
a_facet_that_ends_mid_ask_is_no_medium_test() ->
    Test = self(),
    Facet = spawn(fun() -> facet(Test) end),
    Drive = start(fun() -> Facet end),
    try
        Caller = spawn(fun() -> Test ! {medium, self(), gen_server:call(Drive, medium, 5000)} end),
        ok = receive {asked, _From} -> exit(Facet, kill), ok after 1000 -> no_ask end,
        ?assertEqual({error, no_medium}, receive {medium, Caller, M} -> M after 1000 -> none end),
        ?assert(is_process_alive(Drive))
    after
        [exit(P, kill) || P <- [Drive, Facet]]
    end.
