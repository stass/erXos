%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_principal_tests).
-moduledoc """
The registry of app principals (docs/design-packaging.md, "An app's
principal"): a record is written into an entry no other name holds, keeps
its entry and signer for the boot, holds nothing but its entry, signer, memory,
kept rows and app's record, and takes the entry erx_app_admit:entry/4 gives.
test/host/erx_principal_test.rb runs it against erx_principal as it is and
against seeded faults.
""".

-include_lib("eunit/include/eunit.hrl").

-define(MIB, 1048576).
%% The ble row an admission kept, with the GATT services it admitted.
-define(BLE, #{row => 3, gatt => [<<"nus">>]}).

admitted(Signer, Memory) ->
    #{signer => Signer, memory => Memory,
      rows => [0, 2], ble => ?BLE, display => <<"display">>}.

-define(LAYOUT, #{image_offset => 4096, image_length => 8192, tree_offset => 12288,
                  tree_length => 4096, salt => <<0:256>>, root_hash => <<1:256>>}).
-define(START, {applications, [<<"kiosk">>]}).

%% A package the package process committed: installed unless named.
package(Name, Admitted) ->
    package(Name, installed, Admitted).

package(Name, Place, Admitted) ->
    #{name => Name, place => Place, admitted => Admitted,
      checked => #{header => #{name => Name, layout => ?LAYOUT, start => ?START},
                   signer => image, sha256 => <<0:256>>, extent => 1}}.

register(Name, Admitted, Apps) ->
    erx_principal:register(package(Name, Admitted), Apps).

%% The record `Name`'s registration as an installed package writes.
record(Name, Entry, Signer, Memory) ->
    #{entry => Entry, signer => Signer, memory => Memory, rows => [0, 2], ble => ?BLE,
      app => #{place => {packages, [<<Name/binary, ".app">>]}, layout => ?LAYOUT, start => ?START,
               window => true}}.

registered(Max, Records) ->
    lists:foldl(fun({Name, Admitted}, Apps) ->
                        {ok, Next} = register(Name, Admitted, Apps),
                        Next
                end, erx_principal:new(Max), Records).

registration_writes_the_record_admission_reads_test() ->
    Apps = registered(4, [{<<"kiosk">>, admitted(image, 32 * ?MIB)},
                          {<<"clock">>, admitted(<<"vendor">>, 64 * ?MIB)}]),
    ?assertEqual({ok, record(<<"clock">>, 1, <<"vendor">>, 64 * ?MIB)},
                 erx_principal:app(<<"clock">>, Apps)),
    ?assertEqual(#{<<"clock">> => #{entry => 1, signer => <<"vendor">>},
                   <<"kiosk">> => #{entry => 0, signer => image}},
                 erx_principal:registry(Apps)),
    ?assertEqual(error, erx_principal:app(<<"notes">>, Apps)).

%% AP2: no credential, nor anything else of the admission, enters the record.
a_record_holds_no_credentials_test() ->
    Given = (admitted(development, 8 * ?MIB))#{credentials => <<"secret">>, login => true},
    {ok, Apps} = register(<<"notes">>, Given, erx_principal:new(2)),
    {ok, Record} = erx_principal:app(<<"notes">>, Apps),
    ?assertEqual(#{}, maps:with([credentials, login], Record)),
    ?assertEqual(record(<<"notes">>, 0, development, 8 * ?MIB), Record).

a_name_registered_again_keeps_its_entry_and_signer_test() ->
    Apps = registered(4, [{<<"clock">>, admitted(<<"vendor">>, 64 * ?MIB)}]),
    {ok, Updated} = register(<<"clock">>, admitted(<<"vendor">>, 16 * ?MIB), Apps),
    ?assertEqual({ok, record(<<"clock">>, 0, <<"vendor">>, 16 * ?MIB)},
                 erx_principal:app(<<"clock">>, Updated)),
    ?assertEqual({error, {signer_changed, <<"clock">>}},
                 register(<<"clock">>, admitted(<<"other">>, 16 * ?MIB), Apps)).

%% A new name takes the lowest free entry, the one admission found free.
a_new_name_takes_the_lowest_free_entry_test() ->
    Apps = registered(4, [{<<"clock">>, admitted(<<"vendor">>, 8 * ?MIB)}]),
    {ok, Notes} = register(<<"notes">>, admitted(development, 8 * ?MIB), Apps),
    ?assertMatch({ok, #{entry := 1}}, erx_principal:app(<<"notes">>, Notes)).

%% PK9: no entry is freed within a boot. Every entry held, a new name finds
%% none; and nothing removes a name, so a removed app's entry stays its own
%% until the next boot.
no_entry_is_freed_within_a_boot_test() ->
    Apps = registered(2, [{<<"clock">>, admitted(<<"vendor">>, 8 * ?MIB)},
                          {<<"notes">>, admitted(development, 8 * ?MIB)}]),
    ?assertEqual({error, apps_full},
                 register(<<"chess">>, admitted(<<"vendor">>, 8 * ?MIB), Apps)),
    ?assertEqual([{app, 2}, {app_registry, 0}, {fetch_name, 2}, {module_info, 0}, {module_info, 1}, {new, 1},
                  {register, 2}, {register_app, 1}, {registry, 1}],
                 lists:sort(erx_principal:module_info(exports))).

without_an_apps_row_nothing_registers_test() ->
    ?assertEqual({error, apps_full},
                 register(<<"clock">>, admitted(image, 8 * ?MIB), erx_principal:new(0))).

%% The record keeps the app's record each of its sessions is sent:
%% the file's place as the facet whose grant holds it and its names there,
%% apps/NAME.app on the `system` grant for a system package and NAME.app at
%% the root of the `packages` grant for an installed one, with the header's
%% layout and start; fetch_name/2 answers the name in an entry.
the_record_keeps_the_app_record_with_its_place_test() ->
    {ok, Image} = erx_principal:register(package(<<"kiosk">>, system, admitted(image, ?MIB)),
                                         erx_principal:new(2)),
    {ok, Apps} = register(<<"clock">>, (admitted(development, ?MIB))#{display := none}, Image),
    {ok, #{app := Kiosk}} = erx_principal:app(<<"kiosk">>, Apps),
    %% A window exactly when the admission kept a windows service.
    ?assertEqual(#{place => {system, [<<"kiosk.app">>]}, layout => ?LAYOUT, start => ?START,
                   window => true},
                 Kiosk),
    {ok, #{app := Clock}} = erx_principal:app(<<"clock">>, Apps),
    ?assertEqual(#{place => {packages, [<<"clock.app">>]}, layout => ?LAYOUT, start => ?START,
                   window => false}, Clock),
    ?assertEqual(<<"kiosk">>, erx_principal:fetch_name(0, Apps)),
    ?assertEqual(<<"clock">>, erx_principal:fetch_name(1, Apps)).
