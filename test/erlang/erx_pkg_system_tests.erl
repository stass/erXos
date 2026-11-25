%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_system_tests).
-moduledoc """
EUnit cases of the image's packages as the package process reads them at boot
(docs/design-packaging.md, "Where a package lies"; "Boot and recovery"): the real
erx_pkg_medium reads each through the system domain's grant of the `system`
facet, here a stand-in tree (erx_fs over erx_fs_test_tree) that holds
dashboard.app at its root, as the storage domain serves the system partition's
apps/. Registration and publication are stubbed (test/erlang/erx_pkg_stubs).
The package files come from test/host/erx_pkg_test.rb, in ERX_PKG_FILES, as
for erx_pkg_tests.
""".
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(MIB, 1048576).

file(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_PKG_FILES"), Name ++ ".bin")),
    Bytes.

header_hash(Bytes) ->
    {ok, #{header_length := Length}} = erx_pkg_header:decode(byte_size(Bytes), Bytes),
    crypto:hash(sha256, binary:part(Bytes, 0, Length)).

%% A read-only grant of the stand-in system tree, its root holding dashboard.app, as the
%% registry holds the facet of a files service: with its grant's rights.
system_grant(Bytes) ->
    {ok, Grant, _} = erx_fs:start_link(erx_fs_test_tree, [{name, <<"system">>},
                                                      {file, <<"dashboard.app">>, Bytes}], ro),
    unlink(Grant),
    erx_facets:files(Grant, ro).

%% The table the registration and publication stubs log into.
stubs_log() ->
    _ = [ets:delete(erx_pkg_stubs) || ets:whereis(erx_pkg_stubs) =/= undefined],
    erx_pkg_stubs = ets:new(erx_pkg_stubs, [named_table, public]),
    ok.

manifest() ->
    #{apps => #{memory => 128 * ?MIB, max => 8, packages_row => 0, system_row => 3,
                services => [#{name => <<"display">>, windows => true, row => 1},
                             #{name => <<"data">>, windows => false, row => 2}],
                ble => #{row => 4, gatt => [<<"nus">>]}},
      reserved => [<<"system">>],
      packages => [<<"dashboard">>]}.

%% The installed packages are listed at installed/ of the place erx_ns gives the packages
%% tree (erx_ns:packages_place/0), where erx_domain_srv mounts the system domain's grant,
%% and at no path of this module's own: the trace sees the one path the listing reads. The
%% listing runs in a process of its own, since a process is never its own tracer.
installed_lies_beneath_the_packages_place_test() ->
    {Packages, _Options} = erx_ns:packages_place(),
    1 = erlang:trace_pattern({prim_file, list_dir_all, 1}, true, [local]),
    Lister = spawn(fun() -> receive list -> erx_pkg_medium:list(1) end end),
    1 = erlang:trace(Lister, true, [call]),
    try
        Lister ! list,
        Installed = <<Packages/binary, "/installed">>,
        ?assertEqual(Installed, receive {trace, Lister, call, {prim_file, list_dir_all, [Path]}} -> Path
                                after 2000 -> no_call end)
    after
        _ = erlang:trace_pattern({prim_file, list_dir_all, 1}, false, [local])
    end.

%% Without the grant every read answers enoent; with it a package's length and bytes
%% come through it, and a name the tree does not hold answers enoent.
reads_through_the_system_grant_test() ->
    Dashboard = file("dashboard"),
    persistent_term:put({erx, facets}, {0, #{}}),
    ?assertEqual({error, enoent}, erx_pkg_medium:size(system, <<"dashboard.app">>)),
    ?assertEqual({error, enoent}, erx_pkg_medium:pread(system, <<"dashboard.app">>, 0, 16)),
    persistent_term:put({erx, facets}, {1, #{system => {?ERX_SERVICE_FILES, system_grant(Dashboard)}}}),
    Size = byte_size(Dashboard),
    ?assertEqual({ok, Size}, erx_pkg_medium:size(system, <<"dashboard.app">>)),
    ?assertEqual({ok, binary:part(Dashboard, 100, 4096)},
                 erx_pkg_medium:pread(system, <<"dashboard.app">>, 100, 4096)),
    ?assertEqual({ok, <<>>}, erx_pkg_medium:pread(system, <<"dashboard.app">>, Size, 16)),
    ?assertEqual({error, enoent}, erx_pkg_medium:size(system, <<"nope.app">>)),
    ?assertEqual({error, enoent}, erx_pkg_medium:pread(system, <<"nope.app">>, 0, 16)),
    persistent_term:erase({erx, facets}).

%% The system grant is in place only once the system domain's namespace has settled,
%% so the recovery reads no image package before then: here the grant is installed
%% as the domain service answers, and the image's package is admitted from it.
image_packages_wait_for_the_namespace_test() ->
    process_flag(trap_exit, true),
    ok = erx_fs_version:init(),
    ok = stubs_log(),
    Dashboard = file("dashboard"),
    persistent_term:put({erx, facets}, {0, #{}}),
    Test = self(),
    Holder = spawn_link(fun() ->
                                register(erx_pkg_namespace, self()),
                                Test ! registered,
                                receive {'$gen_call', From, {settled, namespace}} ->
                                        receive release ->
                                                persistent_term:put({erx, facets},
                                                                    {1, #{system => {?ERX_SERVICE_FILES,
                                                                                     system_grant(Dashboard)}}}),
                                                gen:reply(From, ok)
                                        end
                                end
                        end),
    receive registered -> ok end,
    {ok, _Io} = erx_pkg_io:start_link(),
    Config = #{images => [{<<"dashboard.app">>, header_hash(Dashboard)}],
               signers => [], max => 8, manifest => manifest()},
    {ok, Sup} = erx_pkg_sup:start_link(Config),
    timer:sleep(200),
    ?assertMatch(#{scan := unknown, packages := #{}}, erx_pkg:packages()),
    Holder ! release,
    %% The host has no /packages, so the listing answers absent and the scan stays
    %% unknown; the recovery is done once the image's packages are published.
    wait_until(fun() -> published() =/= [] end, 200),
    ?assertMatch(#{packages := #{{system, <<"dashboard.app">>} := #{state := admitted, signer := image}}},
                 erx_pkg:packages()),
    ?assertMatch([{_, [#{name := <<"dashboard">>, place := system}]}], published()),
    unlink(Sup),
    exit(Sup, shutdown),
    persistent_term:erase({erx, facets}).

wait_until(Done, 0) -> ?assert(Done());
wait_until(Done, N) ->
    case Done() of
        true -> ok;
        false -> timer:sleep(10), wait_until(Done, N - 1)
    end.

%% The sets the publication stub logged.
published() ->
    case ets:lookup(erx_pkg_stubs, published) of
        [{published, Sets}] -> Sets;
        [] -> []
    end.
