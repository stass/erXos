%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_manifest_tests).
-moduledoc """
erx_pkg_manifest:system_config/1 and admission/1, and erx_pkg:system_config/2
over them, over the manifests test/host/erx_pkg_manifest_test.rb writes to
$ERX_PKG_MANIFEST_FILES: the hand-built bytes of AbiManifestFixture.packages
(development and release), its refused variants, the fixture with none of
the records, and the manifest the host's check packs.
""".

-include_lib("eunit/include/eunit.hrl").

-define(MIB, 1048576).

manifest(Name) ->
    {ok, Bytes} = file:read_file(filename:join(os:getenv("ERX_PKG_MANIFEST_FILES"), Name ++ ".bin")),
    Bytes.

key(Byte) ->
    binary:copy(<<Byte>>, 32).

%% The apps row of AbiManifestFixture.packages with max Max: the app
%% template's packages row is facet 2, not facet 1, granted to the system
%% domain, its display and data rows are 3 and 4, not facet 0, which grants
%% display to the other template, and its system row is 5. It offers no ble.
apps(Max) ->
    #{memory => ?MIB, max => Max, packages_row => 2, system_row => 5,
      services => [#{name => <<"display">>, windows => true, row => 3},
                   #{name => <<"data">>, windows => false, row => 4}],
      ble => none}.

%% The names of its principal, domain, services and facet rows, sorted.
reserved() ->
    [<<"data">>, <<"display">>, <<"kiosk_display">>, <<"packages">>, <<"pkg_admin">>,
     <<"root">>, <<"spare">>, <<"storage">>, <<"system">>].

packages() ->
    [#{name => <<"clock">>, sha256 => key(16#ab), enabled => true},
     #{name => <<"quotes">>, sha256 => key(16#ee), enabled => false}].

hand_built_records_test() ->
    ?assertEqual({ok, #{apps => apps(2), reserved => reserved(), packages => packages(),
                        signers => [{<<"ops">>, key(16#cd)}], development => key(7)}},
                 erx_pkg_manifest:system_config(manifest("packages"))).

admission_test() ->
    {ok, Config} = erx_pkg_manifest:system_config(manifest("packages")),
    ?assertEqual(#{apps => apps(2), reserved => reserved(), packages => [<<"clock">>, <<"quotes">>]},
                 erx_pkg_manifest:admission(Config)).

no_records_test() ->
    ?assertEqual({ok, #{apps => none, reserved => [<<"root">>], packages => [], signers => [],
                        development => none}},
                 erx_pkg_manifest:system_config(manifest("none"))).

%% A release manifest holds no development key, and the apps table holds one
%% row.
refused_test() ->
    ?assertMatch({error, #{reason := inactive, field := <<"root.development_key.count">>}},
                 erx_pkg_manifest:system_config(manifest("release_development"))),
    ?assertMatch({error, #{reason := extent, field := <<"apps">>}},
                 erx_pkg_manifest:system_config(manifest("two_apps"))),
    ?assertMatch({error, _}, erx_pkg_manifest:system_config(<<>>)).

%% The host's check packs QEMU virt's apps row with the app template's rows it
%% derives: the template's packages and system rows and one row for each of the
%% row's services, the display and the network, each a row of its own.
packed_manifest_test() ->
    {ok, #{apps := #{memory := 137363456, max := 4, packages_row := Packages, system_row := System,
                     services := [#{name := <<"display">>, windows := true, row := Display},
                                  #{name := <<"net">>, windows := false, row := Net}],
                     ble := none},
           packages := [#{name := <<"clock">>, enabled := true}, #{name := <<"quotes">>, enabled := false}],
           signers := [{<<"ops">>, _}]}} = erx_pkg_manifest:system_config(manifest("admitted")),
    ?assertEqual(4, length(lists:usort([Packages, System, Display, Net]))).

%% The same row offering ble with gatt nus: the template's ble row is no
%% service a need may name, so admission refuses a need of ble (step 6); it is
%% the row of the row's ble, a row of its own, and its services parameter is
%% the set steps 7 and 8 judge a declaration's gatt by.
ble_is_no_need_test() ->
    {ok, #{apps := #{packages_row := Packages, system_row := System, services := Services,
                     ble := #{row := Ble, gatt := Gatt}}}} =
        erx_pkg_manifest:system_config(manifest("ble")),
    ?assertEqual([<<"display">>, <<"net">>], [Name || #{name := Name} <- Services]),
    ?assertEqual([<<"nus">>], Gatt),
    ?assertEqual(5, length(lists:usort([Packages, System, Ble | [Row || #{row := Row} <- Services]]))).

library(Max) ->
    {ok, #{template => 0, first => 2, max => Max, memory => ?MIB}}.

%% The library's max, not the row's, in the config and in admission's row;
%% the development key as the development signer, after the signer rows.
recovery_config_test() ->
    ?assertEqual(#{images => [{<<"clock.app">>, key(16#ab)}, {<<"quotes.app">>, key(16#ee)}],
                   signers => [{<<"ops">>, key(16#cd)}, {development, key(7)}],
                   max => 3,
                   manifest => #{apps => apps(3), reserved => reserved(),
                                 packages => [<<"clock">>, <<"quotes">>]}},
                 erx_pkg:system_config(library(3), {ok, manifest("packages")})).

release_config_test() ->
    #{signers := Signers} = erx_pkg:system_config(library(2), {ok, manifest("release")}),
    ?assertEqual([{<<"ops">>, key(16#cd)}], Signers).

%% No package process without app entries or without an apps row, nor for a
%% manifest the library placed entries from that gives no config here, a
%% broken image that costs the packages alone.
no_config_test() ->
    ?assertEqual(none, erx_pkg:system_config({ok, none}, {ok, manifest("packages")})),
    ?assertEqual(none, erx_pkg:system_config({error, enotsup}, {error, enoent})),
    ?assertEqual(none, erx_pkg:system_config(library(2), {ok, manifest("none")})),
    ?assertEqual(none, erx_pkg:system_config(library(2), {error, enoent})),
    ?assertEqual(none, erx_pkg:system_config(library(2), {ok, manifest("two_apps")})).
