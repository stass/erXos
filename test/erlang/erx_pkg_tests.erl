%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_tests).
-moduledoc """
EUnit cases of the package process at boot (docs/design-packaging.md, "Boot
and recovery"): the file check, erx_pkg_header:check_file/2; the recovery's
plan, erx_pkg_plan; the path table, erx_pkg_io; and the package process,
erx_pkg, under erx_pkg_sup, over a simulated medium with the real
admission and with registration and publication stubbed. The package files
come from test/host/erx_pkg_test.rb, in ERX_PKG_FILES: dashboard.bin,
clock.bin, other.bin and relay.bin, each a well-formed package of that app
name sealed by the Ed25519 key whose public half is key.bin; dashboard, other
and relay declare the GATT service nus, other and pulse hrm, clock none.
""".
-include_lib("eunit/include/eunit.hrl").

-define(SIGNERS, [{development, file("key")}]).
-define(MIB, 1048576).

file(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_PKG_FILES"), Name ++ ".bin")),
    Bytes.

header_hash(Bytes) ->
    {ok, #{header_length := Length}} = erx_pkg_header:decode(byte_size(Bytes), Bytes),
    crypto:hash(sha256, binary:part(Bytes, 0, Length)).

check(Name, Bytes, Authority) ->
    erx_pkg_header:check_file({Name, byte_size(Bytes), Bytes}, Authority).

%% The file check.

check_file_test() ->
    Clock = file("clock"),
    Hash = header_hash(Clock),
    ?assertMatch({ok, #{signer := image, sha256 := Hash, extent := 4096,
                        header := #{name := <<"clock">>}}},
                 check(<<"clock.app">>, Clock, {hash, Hash})),
    <<First, Rest/binary>> = Hash,
    ?assertEqual({error, {untrusted, hash}},
                 check(<<"clock.app">>, Clock, {hash, <<(First bxor 1), Rest/binary>>})),
    ?assertMatch({ok, #{signer := development}},
                 check(<<"clock.app">>, Clock, {signers, ?SIGNERS})),
    ?assertEqual({error, {untrusted, signer}},
                 check(<<"clock.app">>, Clock, {signers, [{<<"other">>, <<0:256>>}]})),
    ?assertEqual({error, {name, <<"misnamed.app">>, <<"clock">>}},
                 check(<<"misnamed.app">>, Clock, {signers, ?SIGNERS})),
    Short = binary:part(Clock, 0, byte_size(Clock) - 1),
    ?assertMatch({error, {length, _, _}}, check(<<"clock.app">>, Short, {signers, ?SIGNERS})).

%% The listing.

listing_test() ->
    Names = [<<"tmp.0">>, <<"tmp.7">>, <<"tmp.8">>, <<"tmp.01">>, <<"image">>,
             <<"a-b.app">>, <<"a.app">>, <<"tmp.app">>, <<"tmp.5x">>, <<"BAD.app">>, <<".app">>, <<"notes">>],
    ?assertEqual({ok, #{temporaries => [<<"tmp.0">>, <<"tmp.7">>],
                        packages => [<<"a.app">>, <<"a-b.app">>, <<"tmp.app">>],
                        unknown => [<<"tmp.8">>, <<"tmp.01">>, <<"tmp.5x">>, <<"BAD.app">>, <<".app">>,
                                    <<"notes">>]}},
                 erx_pkg_plan:listing(Names, false, 8)),
    ?assertEqual({overflow, 3}, erx_pkg_plan:listing([<<"a">>, <<"b">>, <<"c">>], true, 8)).

%% The package process over the simulated medium.

%% The table the registration and publication stubs log into (test/erlang/erx_pkg_stubs).
stubs_log() ->
    _ = [ets:delete(erx_pkg_stubs) || ets:whereis(erx_pkg_stubs) =/= undefined],
    erx_pkg_stubs = ets:new(erx_pkg_stubs, [named_table, public]),
    ok.

setup(Options) ->
    process_flag(trap_exit, true),
    ok = erx_fs_version:init(),
    ok = erx_pkg_medium:new(),
    ok = stubs_log(),
    Dashboard = file("dashboard"),
    Clock = file("clock"),
    erx_pkg_medium:put(system, <<"dashboard.app">>, Dashboard),
    erx_pkg_medium:put(installed, <<"clock.app">>, Clock),
    erx_pkg_medium:put(installed, <<"other.app">>, file("other")),
    erx_pkg_medium:put(installed, <<"misnamed.app">>, Clock),
    erx_pkg_medium:put(installed, <<"short.app">>, binary:part(Clock, 0, 4096)),
    erx_pkg_medium:put(installed, <<"tmp.0">>, <<"partial">>),
    erx_pkg_medium:put(installed, <<"tmp.7">>, <<>>),
    erx_pkg_medium:put(installed, <<"notes">>, <<"left alone">>),
    erx_pkg_medium:put(installed, <<"image">>, <<>>),
    [erx_pkg_medium:set(Key, Value) || {Key, Value} <- Options],
    Io = case whereis(erx_pkg_io) of
             undefined -> {ok, Pid} = erx_pkg_io:start_link(), Pid;
             Pid -> Pid
         end,
    Config = #{images => [{<<"dashboard.app">>, header_hash(Dashboard)}],
               signers => ?SIGNERS, max => 8, manifest => manifest()},
    {Io, Config}.

%% The facts admission reads: an apps row that offers every test package's
%% needs, display and data, within its budget, and the GATT service nus in its
%% ble row; a principal named other, so admission refuses the package of that
%% name; and the image's package dashboard.
manifest() ->
    #{apps => #{memory => 128 * ?MIB, max => 8, packages_row => 0, system_row => 3,
                services => [#{name => <<"display">>, windows => true, row => 1},
                             #{name => <<"data">>, windows => false, row => 2}],
                ble => #{row => 4, gatt => [<<"hrm">>, <<"nus">>]}},
      reserved => [<<"system">>, <<"other">>],
      packages => [<<"dashboard">>]}.

wait_recovered() ->
    wait_until(fun() -> maps:get(scan, erx_pkg:packages()) =/= unknown end).

wait_until(Done) ->
    wait_until(Done, 200).

wait_until(Done, 0) -> ?assert(Done());
wait_until(Done, N) ->
    try Done() of
        true -> ok;
        false -> timer:sleep(10), wait_until(Done, N - 1)
    catch
        exit:_ -> timer:sleep(10), wait_until(Done, N - 1)
    end.

published() ->
    case ets:lookup(erx_pkg_stubs, published) of
        [{published, Sets}] -> Sets;
        [] -> []
    end.

stop(Sup) ->
    unlink(Sup),
    exit(Sup, shutdown),
    wait_until(fun() -> not is_process_alive(Sup) end).

recovery_test() ->
    {_Io, Config} = setup([]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    wait_recovered(),
    #{scan := Scan, packages := Records} = erx_pkg:packages(),
    ?assertEqual({ok, 8}, Scan),
    %% Every temporary file is deleted; an entry of no recognized form stays.
    ?assertEqual([<<"tmp.0">>, <<"tmp.7">>], erx_pkg_medium:deleted()),
    ?assertMatch(#{{system, <<"dashboard.app">>} := #{state := admitted, signer := image},
                   {installed, <<"clock.app">>} := #{state := admitted, signer := development,
                                                       version := 3},
                   {installed, <<"other.app">>} := #{state := refused,
                                                       reason := {name_taken, <<"other">>}},
                   {installed, <<"misnamed.app">>} := #{state := refused, version := unknown,
                                                          reason := {file, {name, _, _}}},
                   {installed, <<"short.app">>} := #{state := refused, needs := unknown}},
                 Records),
    ?assertEqual(5, map_size(Records)),
    %% The set holds the admitted packages, the image's first; only they
    %% register, each in a free entry with the signer the file check named.
    [{Lifetime, Set}] = published(),
    ?assertEqual(whereis(erx_pkg), Lifetime),
    ?assertEqual([{<<"dashboard">>, system}, {<<"clock">>, installed}],
                 [{Name, Place} || #{name := Name, place := Place} <- Set]),
    ?assertEqual([{<<"dashboard">>, system, 0, image}, {<<"clock">>, installed, 1, development}],
                 [{Name, Place, Entry, Signer}
                  || {Name, Place, Entry, #{signer := Signer}}
                         <- ets:lookup_element(erx_pkg_stubs, registered, 2)]),
    stop(Sup).

path_table_test() ->
    {_Io, Config} = setup([]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    wait_recovered(),
    Clock = file("clock"),
    {ok, Qid} = erx_pkg_io:lookup(installed, <<"clock.app">>),
    ?assertEqual({ok, binary:part(Clock, 0, 8192)},
                 erx_pkg_io:read(installed, <<"clock.app">>, Qid, 0, 8192)),
    ?assertEqual({ok, binary:part(Clock, 100, 10)},
                 erx_pkg_io:read(installed, <<"clock.app">>, Qid, 100, 10)),
    %% Admission's refusal keeps the authenticated header: it reads.
    {ok, Other} = erx_pkg_io:lookup(installed, <<"other.app">>),
    ?assertMatch({ok, <<_:16/binary>>}, erx_pkg_io:read(installed, <<"other.app">>, Other, 0, 16)),
    %% The file check's refusal is listed and serves no byte.
    {ok, Misnamed} = erx_pkg_io:lookup(installed, <<"misnamed.app">>),
    ?assertEqual({error, eio}, erx_pkg_io:read(installed, <<"misnamed.app">>, Misnamed, 0, 16)),
    ?assertEqual({error, eio}, erx_pkg_io:read(installed, <<"misnamed.app">>, Misnamed, 8192, 16)),
    ?assertEqual({error, enoent}, erx_pkg_io:lookup(installed, <<"nope.app">>)),
    ?assertEqual({error, enoent}, erx_pkg_io:lookup(installed, <<"tmp.0">>)),
    ?assertEqual({error, eio}, erx_pkg_io:read(installed, <<"clock.app">>, Qid + 1000, 0, 16)),
    ?assertEqual({error, einval}, erx_pkg_io:read(installed, <<"clock.app">>, Qid, -1, 16)),
    ?assertEqual({error, einval}, erx_pkg_io:read(installed, <<"clock.app">>, Qid, 0, -1)),
    %% A header changed on the medium since its check is never served.
    <<Byte, Tail/binary>> = Clock,
    erx_pkg_medium:put(installed, <<"clock.app">>, <<(Byte bxor 1), Tail/binary>>),
    ?assertEqual({error, eio}, erx_pkg_io:read(installed, <<"clock.app">>, Qid, 0, 16)),
    %% A new lifetime gives the package a new qid path, and its predecessor's
    %% requests are refused.
    erx_pkg_medium:put(installed, <<"clock.app">>, Clock),
    Old = whereis(erx_pkg),
    exit(Old, kill),
    wait_until(fun() -> is_pid(whereis(erx_pkg)) andalso whereis(erx_pkg) =/= Old end),
    wait_recovered(),
    {ok, Again} = erx_pkg_io:lookup(installed, <<"clock.app">>),
    ?assertNotEqual(Qid, Again),
    ?assertEqual({error, eio}, erx_pkg_io:request({header, Old, installed, <<"clock.app">>})),
    ?assertEqual({error, eio}, erx_pkg_io:request({delete, Old, <<"clock.app">>})),
    stop(Sup).

pending_test() ->
    {_Io, _Config} = setup([]),
    Lifetime = spawn(fun() -> receive stop -> ok end end),
    ok = erx_pkg_io:request({begin_lifetime, Lifetime}),
    {ok, _, false} = erx_pkg_io:request({list, Lifetime}),
    %% A listed name answers eio until its entry comes, then its qid path.
    ?assertEqual({error, eio}, erx_pkg_io:lookup(installed, <<"clock.app">>)),
    ok = erx_pkg_io:request({path_entry, Lifetime, installed, <<"clock.app">>, refused}),
    ?assertMatch({ok, _}, erx_pkg_io:lookup(installed, <<"clock.app">>)),
    %% A request of an alive process that is not the lifetime is refused.
    Stranger = spawn(fun() -> receive stop -> ok end end),
    ?assertEqual({error, eio}, erx_pkg_io:request({delete, Stranger, <<"clock.app">>})),
    Lifetime ! stop,
    Stranger ! stop.

%% Every medium answer outside the callbacks' contract is eio, and erx_pkg_io
%% lives on; a read past the largest package reads nothing.
medium_route_test() ->
    {Io, _Config} = setup([{listing, {ok, not_names, false}}]),
    Lifetime = spawn(fun() -> receive stop -> ok end end),
    ok = erx_pkg_io:request({begin_lifetime, Lifetime}),
    ?assertEqual({error, eio}, erx_pkg_io:request({list, Lifetime})),
    erx_pkg_medium:set(listing, {ok, [<<"clock.app">>, 7], false}),
    ?assertEqual({error, eio}, erx_pkg_io:request({list, Lifetime})),
    erx_pkg_medium:set(listing, {ok, [], false}),
    ?assertEqual({ok, [], false}, erx_pkg_io:request({list, Lifetime})),
    Header = fun() -> erx_pkg_io:request({header, Lifetime, installed, <<"clock.app">>}) end,
    erx_pkg_medium:set(pread_answer, eof),
    ?assertEqual({error, eio}, Header()),
    erx_pkg_medium:set(pread_answer, {ok, <<0:(65537 * 8)>>}),
    ?assertEqual({error, eio}, Header()),
    erx_pkg_medium:set(pread_answer, {error, "not an atom"}),
    ?assertEqual({error, eio}, Header()),
    ?assert(is_process_alive(Io)),
    ?assertEqual({ok, <<>>}, erx_pkg_io:read(installed, <<"clock.app">>, 1, 1 bsl 30, 1)),
    Lifetime ! stop.

%% Step 8 in the recovery's order: the image's dashboard, judged first, holds nus,
%% so the installed relay, which declares it too, is refused, and clock, which
%% declares none, is admitted beside it; only dashboard's and pulse's admissions keep
%% the ble row. other, refused by its name, holds nothing, so pulse, judged after it,
%% takes hrm.
held_in_recovery_order_test() ->
    {_Io, Config} = setup([]),
    erx_pkg_medium:put(installed, <<"relay.app">>, file("relay")),
    erx_pkg_medium:put(installed, <<"pulse.app">>, file("pulse")),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    wait_recovered(),
    #{packages := Records} = erx_pkg:packages(),
    ?assertMatch(#{{installed, <<"relay.app">>} := #{state := refused,
                                                     reason := {gatt_taken, <<"nus">>, <<"dashboard">>}},
                   {installed, <<"clock.app">>} := #{state := admitted},
                   {installed, <<"pulse.app">>} := #{state := admitted}},
                 Records),
    ?assertEqual([{<<"dashboard">>, #{row => 4, gatt => [<<"nus">>]}}, {<<"clock">>, none},
                  {<<"pulse">>, #{row => 4, gatt => [<<"hrm">>]}}],
                 [{Name, Ble} || {Name, _Place, _Entry, #{ble := Ble}}
                                     <- ets:lookup_element(erx_pkg_stubs, registered, 2)]),
    stop(Sup).

overflow_test() ->
    %% A medium answers at most the names asked for, and whether more remain.
    Names = [integer_to_binary(N) || N <- lists:seq(1, 1024)],
    {_Io, Config} = setup([{listing, {ok, Names, true}}]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    wait_recovered(),
    #{scan := Scan, packages := Records} = erx_pkg:packages(),
    ?assertEqual({overflow, 1024}, Scan),
    ?assertEqual([{system, <<"dashboard.app">>}], maps:keys(Records)),
    ?assertEqual([], erx_pkg_medium:deleted()),
    stop(Sup).

unreadable_listing_test_() ->
    [fun() -> unknown_scan({error, Reason}) end || Reason <- [absent, eio]].

%% A listing that fails as Listing leaves the scan unknown and publishes the image's packages.
unknown_scan(Listing) ->
    {_Io, Config} = setup([{listing, Listing}]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    wait_until(fun() -> published() =/= [] end),
    #{scan := Scan, packages := Records} = erx_pkg:packages(),
    ?assertEqual(unknown, Scan),
    ?assertEqual([{system, <<"dashboard.app">>}], maps:keys(Records)),
    stop(Sup).

%% The recovery waits for the system domain's namespace, as the start table's
%% first read of rc.conf does (docs/design-packaging.md, "Boot and recovery"):
%% until the domain service answers, the scan stays unknown and nothing is
%% published, and once it answers the recovery is carried out.
the_listing_waits_for_the_namespace_test() ->
    Test = self(),
    Holder = spawn_link(fun() ->
                                register(erx_pkg_namespace, self()),
                                Test ! registered,
                                receive {'$gen_call', From, {settled, namespace}} ->
                                        receive release -> gen:reply(From, ok) end
                                end
                        end),
    receive registered -> ok end,
    {_Io, Config} = setup([]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    timer:sleep(200),
    ?assertMatch(#{scan := unknown}, erx_pkg:packages()),
    ?assertEqual([], published()),
    Holder ! release,
    wait_recovered(),
    ?assertMatch(#{scan := {ok, _}}, erx_pkg:packages()),
    stop(Sup).

%% The recovery runs one action per message: a call made during it waits for
%% one action, here one slow header read, never for the whole recovery,
%% whose five slow reads take longer than a call's timeout.
answers_during_recovery_test_() ->
    {timeout, 60, fun answers_during_recovery/0}.

answers_during_recovery() ->
    {_Io, Config} = setup([{pread_delay, 1200}]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    timer:sleep(100),
    ?assertMatch(#{scan := unknown, packages := #{}}, erx_pkg:packages()),
    wait_until(fun() -> maps:get(scan, erx_pkg:packages()) =/= unknown end, 1000),
    stop(Sup).

%% A failed change ends the lifetime; past erx_pkg_sup's intensity the
%% package process stays down and erx_pkg_io lives on.
failed_change_test() ->
    {Io, Config} = setup([{fail_delete, true}]),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    receive {'EXIT', Sup, shutdown} -> ok after 5000 -> ?assert(false) end,
    ?assertEqual(undefined, whereis(erx_pkg)),
    ?assert(is_process_alive(Io)),
    ?assertEqual([], published()).

failed_publication_test() ->
    {Io, Config} = setup([]),
    true = ets:insert(erx_pkg_stubs, {fail_publish, true}),
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    receive {'EXIT', Sup, shutdown} -> ok after 5000 -> ?assert(false) end,
    ?assert(is_process_alive(Io)).
