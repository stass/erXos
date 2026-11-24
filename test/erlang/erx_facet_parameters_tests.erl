%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A facet row's parameters from the packed manifest to the mint
%% (docs/design-system.md, "Facets a configured domain serves"), run by
%% test/host/facet_parameters_test.rb: served/1, the host harness
%% test/fixtures/erx_domain_terms_harness.c, builds the domain library's boot
%% view from the manifest bytes in manifest.bin and turns it into the
%% services and grants erx_domain_lib:configured/0 returns, with the NIF's own
%% erx_domain_served_terms. The manifest is the display_domain suite's, its
%% client template's grant of the display stating pixels, windows and clipboard;
%% the grant's limits carry each by name, and erx_domain_mints charges the
%% display the pixel area the row asks for. Each refused-NAME.bin beside it
%% forges the grant's parameter rows, and the view refuses it. line.bin is the
%% configured domains' manifest with alpha granted the line, its device the
%% device row whose index line-device holds, and the reader refuses
%% unreadable-device-past-the-table.bin, its device one past the device table.
%% operations.bin is the development manifest with root's template granted two
%% of inspect's operations, which reach the grant's limits by name in number
%% order; each forged-operations-NAME.bin forges its operation rows, or names
%% them on a service a configured domain serves, and the view refuses it. net.bin is
%% the development manifest with its session template's grant of net stating sockets,
%% 16 ports and one listen port; each set reaches the limits as the list of its elements in
%% ascending order.
-module(erx_facet_parameters_tests).
-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([served/1, drives/1]).
-on_load(load/0).

load() ->
    erlang:load_nif("./erx_domain_terms_harness", 0).

served(_Bytes) ->
    erlang:nif_error(not_loaded).

drives(_Bytes) ->
    erlang:nif_error(not_loaded).

%% Each configured row carries the drive numbers of the drive windows on its placed
%% devices (docs/design-drives.md, "How the grant reaches the media domain"): the
%% development manifest's one drive, disk0, lies on the xhci unit the usb domain holds,
%% and no other row carries one.
the_usb_row_carries_the_development_manifest_s_drive_test() ->
    {ok, Bytes} = file:read_file("net.bin"),
    {ok, Rows} = drives(Bytes),
    ?assertEqual([{<<"usb">>, [0]}], [Row || {_Name, [_ | _]} = Row <- Rows]),
    ?assert(lists:keymember(<<"media">>, 1, Rows)).

%% The display service and the client template's grant of it, from the manifest.
display() ->
    {ok, Bytes} = file:read_file("manifest.bin"),
    {ok, {Services, Grants}} = served(Bytes),
    [{Server, Name}] = [{Row, N} || {Row, N, ?ERX_SERVICE_WINDOWS} <- Services],
    [Grant] = [G || {{template, _}, N, S, _} = G <- Grants, N =:= Name, S =:= Server],
    {Services, Grants, Grant}.

the_grant_s_limits_carry_its_parameters_by_name_test() ->
    {_Services, _Grants, {_Grantee, _Name, _Server, Limits}} = display(),
    ?assertMatch(#{pixels := 4194304, windows := 2, clipboard := true, operations := []}, Limits),
    ?assertEqual(lists:sort([max_request, in_flight, reductions, period_ns, max_heap_size, queue,
                             operations, pixels, windows, clipboard]),
                 lists:sort(maps:keys(Limits))).

%% The mint core as the domain service makes it from those terms (erx_domain_srv:booted/1),
%% and a session of the template holding the row its plan gave it.
the_pixel_charge_follows_the_row_test() ->
    {Services, Grants, {{template, _Template}, Name, Server, Limits}} = display(),
    Mints = erx_domain_mints:new(#{services => [{S, N} || {S, N, _} <- Services, S =/= system],
                                   grants => [G || {_, _, S, _} = G <- Grants, S =/= system],
                                   windows => [Name], owner => fun(_) -> ok end}),
    ?assertEqual({4194304, 5}, erx_domain_mints:pair_area({5, {configured, Server}},
                                                         {6, {rows, [{Name, Server, Limits}]}}, Mints)).

the_line_grant_s_device_is_its_device_row_test() ->
    {ok, Bytes} = file:read_file("line.bin"),
    {ok, Text} = file:read_file("line-device"),
    {ok, {Services, Grants}} = served(Bytes),
    [Name] = [N || {system, N, ?ERX_SERVICE_LINE} <- Services],
    [Limits] = [L || {0, N, system, L} <- Grants, N =:= Name],
    ?assertMatch(#{device := _, rate := 115200, flow := <<"none">>}, Limits),
    ?assertEqual(binary_to_integer(Text), maps:get(device, Limits)),
    {ok, Past} = file:read_file("unreadable-device-past-the-table.bin"),
    ?assertEqual(unreadable, served(Past)).

the_net_grant_s_sets_are_lists_test() ->
    {ok, Bytes} = file:read_file("net.bin"),
    {ok, {Services, Grants}} = served(Bytes),
    [{Server, Name}] = [{Row, N} || {Row, N, ?ERX_SERVICE_NET} <- Services],
    [Limits] = [L || {{template, _}, N, S, #{sockets := _} = L} <- Grants, N =:= Name, S =:= Server],
    Ports = lists:seq(2000, 2015),
    ?assertMatch(#{sockets := 80, ports := Ports, listen := [2015], operations := []}, Limits),
    ?assertEqual(lists:sort([max_request, in_flight, reductions, period_ns, max_heap_size, queue,
                             operations, sockets, ports, listen]),
                 lists:sort(maps:keys(Limits))).

forged_parameter_rows_are_refused_test() ->
    Forged = filelib:wildcard("refused-*.bin"),
    ?assertEqual(8, length(Forged)),
    [?assertMatch({File, {refused, _}}, {File, served(element(2, file:read_file(File)))}) || File <- Forged].

the_grant_s_limits_carry_its_operations_by_name_test() ->
    {ok, Bytes} = file:read_file("operations.bin"),
    {ok, {Services, Grants}} = served(Bytes),
    [Name] = [N || {system, N, ?ERX_SERVICE_INSPECT} <- Services],
    [Limits] = [L || {{template, _}, N, system, L} <- Grants, N =:= Name],
    ?assertEqual([inspect, entries], maps:get(operations, Limits)).

forged_operation_rows_are_refused_test() ->
    Forged = filelib:wildcard("forged-operations-*.bin"),
    ?assertEqual(4, length(Forged)),
    [?assertMatch({File, {refused, _}}, {File, served(element(2, file:read_file(File)))}) || File <- Forged].
