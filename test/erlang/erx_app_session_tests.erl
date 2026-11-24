%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_session_tests).
-moduledoc """
The plan of an app's session, `erx_domain_core:app_session/4`
(docs/design-packaging.md, "An app's session", and its verification row):
a header is admitted (`erx_app_admit:admit/4`) and registered
(`erx_principal:register/2`) as the package process does, and the plan is
made from the record the registry holds. The session's rows are the
`packages` and `system` rows, the rows its needs name and, for a
declaration that names gatt, the `ble` row with its services narrowed to the
record's (PK13); its principal, from which every
facet's scope is computed, is the app's entry; its memory is the declared
one; and one header admitted as an image package and as an installed one
gives the same plan (PK10). test/host/erx_app_session_test.rb runs it
against the core as it is and against seeded faults.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(MIB, 1048576).
%% The app entries the library placed: entry i is principal 6 + i.
-define(APPS, #{template => 2, first => 6, max => 4, memory => 128 * ?MIB}).

%% The apps row as admission reads it: the app template's packages row is 7, its
%% system row 11, the services an app may need are granted by rows 8 to 10, and
%% its ble row 12 offers the GATT services hrm and nus.
manifest(ImagePackages) ->
    #{apps => #{memory => 128 * ?MIB, max => 4, packages_row => 7, system_row => 11,
                services => [#{name => <<"display">>, windows => true, row => 8},
                             #{name => <<"data">>, windows => false, row => 9},
                             #{name => <<"panel">>, windows => true, row => 10}],
                ble => #{row => 12, gatt => [<<"hrm">>, <<"nus">>]}},
      reserved => [<<"system">>, <<"storage">>, <<"display">>, <<"data">>, <<"panel">>],
      packages => ImagePackages}.

%% The app template's facet rows by their index in the facet table, each the
%% {Service, Server, Limits} the domain service keeps for it, the ble row's
%% services parameter among its limits.
template_rows() ->
    [{7, row(packages, storage)}, {8, row(display, display)}, {9, row(data, storage)},
     {10, row(panel, panel)}, {11, row(system, storage)}, {12, ble([<<"hrm">>, <<"nus">>])}].

row(Service, Server) -> {Service, Server, #{}}.

ble(Services) -> {ble, bt, #{services => Services}}.

header(Name, Memory, Needs) ->
    header(Name, Memory, Needs, []).

header(Name, Memory, Needs, Gatt) ->
    #{name => Name, memory => Memory, needs => Needs, gatt => Gatt,
      abi_version => ?ERX_ABI_VERSION, arch => ?ERX_ARCH_MACHINE_ARCH_BYTES}.

%% Admits Header signed by Signer against Manifest, registers it in Apps, and plans
%% its session from the registered record; answers the plan and the registry.
started(Header, Signer, Manifest, Apps) ->
    #{name := Name} = Header,
    {ok, Admitted} = erx_app_admit:admit(#{header => Header, signer => Signer}, Manifest,
                                         erx_principal:registry(Apps), #{}),
    Checked = #{header => Header#{layout => #{}, start => {applications, [Name]}}, signer => Signer,
                sha256 => <<0:256>>, extent => 1},
    {ok, Registered} = erx_principal:register(#{name => Name, place => installed, checked => Checked,
                                                admitted => Admitted}, Apps),
    {ok, Record} = erx_principal:app(Name, Registered),
    {erx_domain_core:app_session(Name, Record, ?APPS, template_rows()), Registered}.

started(Header, Signer) ->
    {Plan, _} = started(Header, Signer, manifest([]), erx_principal:new(4)),
    Plan.

the_rows_are_packages_system_and_the_needs_test() ->
    Dashboard = started(header(<<"dashboard">>, 16 * ?MIB, [<<"display">>]), <<"vendor">>),
    ?assertEqual([row(packages, storage), row(display, display), row(system, storage)],
                 maps:get(rows, Dashboard)),
    Daemon = started(header(<<"daemon">>, 16 * ?MIB, []), <<"vendor">>),
    ?assertEqual([row(packages, storage), row(system, storage)], maps:get(rows, Daemon)),
    Both = started(header(<<"panels">>, 16 * ?MIB, [<<"panel">>, <<"data">>]), <<"vendor">>),
    ?assertEqual([row(packages, storage), row(data, storage), row(panel, panel), row(system, storage)],
                 maps:get(rows, Both)).

%% PK13: the ble row reaches a session only with the services the app's record
%% holds, never the row's whole set; and only for an app whose declaration names gatt.
the_ble_row_names_the_records_services_test() ->
    Beacon = started(header(<<"beacon">>, 16 * ?MIB, [], [<<"nus">>]), <<"vendor">>),
    ?assertEqual([row(packages, storage), row(system, storage), ble([<<"nus">>])], maps:get(rows, Beacon)),
    Daemon = started(header(<<"daemon">>, 16 * ?MIB, [], []), <<"vendor">>),
    ?assertEqual([row(packages, storage), row(system, storage)], maps:get(rows, Daemon)).

%% Whatever a record holds, the grant names only services the row offers: the
%% intersection, in the row's order.
the_ble_row_is_never_wider_than_the_templates_test() ->
    Record = #{entry => 0, signer => <<"vendor">>, memory => 16 * ?MIB, rows => [7, 11],
               ble => #{row => 12, gatt => [<<"bas">>, <<"nus">>]}, app => #{}},
    #{rows := Rows} = erx_domain_core:app_session(<<"beacon">>, Record, ?APPS, template_rows()),
    ?assertEqual([row(packages, storage), row(system, storage), ble([<<"nus">>])], Rows).

%% Every facet's parameters are computed from the plan's principal: the app's entry,
%% never the template's, whatever entry the app takes.
every_scope_names_the_apps_principal_test() ->
    {First, Apps} = started(header(<<"clock">>, 16 * ?MIB, []), <<"vendor">>, manifest([]),
                            erx_principal:new(4)),
    {Second, _} = started(header(<<"notes">>, 16 * ?MIB, []), development, manifest([]), Apps),
    ?assertMatch(#{entry := 0, principal := 6, prefix := <<"clock">>}, First),
    ?assertMatch(#{entry := 1, principal := 7, prefix := <<"notes">>}, Second),
    ?assertEqual({principal, 6}, erx_domain_core:inspect_scope(maps:get(principal, First), [], true)),
    ?assertEqual({principal, 7}, erx_domain_core:inspect_scope(maps:get(principal, Second), [], true)).

the_memory_is_the_declared_one_test() ->
    ?assertEqual(16 * ?MIB, maps:get(memory, started(header(<<"clock">>, 16 * ?MIB, []), <<"vendor">>))),
    ?assertEqual(64 * ?MIB, maps:get(memory, started(header(<<"clock">>, 64 * ?MIB, []), image))).

%% PK10: an image package and an installed one, with one header, have one plan; only
%% what authenticated the header differs, and the plan reads nothing of it.
one_header_admitted_both_ways_gives_one_plan_test() ->
    Header = header(<<"kiosk">>, 32 * ?MIB, [<<"display">>, <<"data">>], [<<"nus">>]),
    {Image, _} = started(Header, image, manifest([<<"kiosk">>]), erx_principal:new(4)),
    {Installed, _} = started(Header, <<"vendor">>, manifest([]), erx_principal:new(4)),
    ?assertEqual(Image, Installed),
    ?assertEqual([row(packages, storage), row(display, display), row(data, storage), row(system, storage),
                  ble([<<"nus">>])],
                 maps:get(rows, Image)).
