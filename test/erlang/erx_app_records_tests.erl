%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_records_tests).
-moduledoc """
EUnit cases of the start table's records (erx_app_records,
docs/design-apps.md, "Interfaces"): each state `/proc/apps` shows, from a
table made up as erx_starter:rows/0 answers it, and nothing shown that
the start service did not report: a down row's reason is `unknown`, a
row's domain and ends `unsupported`, and every attribute of a row
`unknown` before the table is made.
""".

-include_lib("eunit/include/eunit.hrl").

row(Name, Status, Run) ->
    #{principal => Name, enable => Status =/= disabled, display => none, restarts => 5, period => 600,
      from_rc_conf => [], status => Status, run => Run}.

table() ->
    #{rows => [row(<<"clock">>, disabled, none),
               row(<<"kiosk">>, enabled, running),
               (row(<<"pager">>, {refused, {no_grant, <<"display">>}}, none))#{display => <<"display">>,
                                                                              from_rc_conf => [enable, display]},
               row(<<"logger">>, enabled, down),
               row(<<"shelf">>, enabled, stopped),
               row(<<"slate">>, enabled, starting),
               row(<<"tally">>, {refused, {display_held, <<"kiosk">>}}, none),
               row(<<"ticker">>, {refused, {past_ceiling, restarts}}, none)],
      skipped => [], rc_conf => read, boot_order => [<<"storage">>, <<"net">>]}.

attrs(Name) ->
    {ok, #{kind := app, attrs := Attrs}} = erx_app_records:record([apps, Name], table()),
    Attrs.

the_table_lists_its_rows_and_the_boot_order_test() ->
    {ok, Record} = erx_app_records:record([apps], table()),
    ?assertMatch(#{kind := start_table, children := [<<"clock">>, <<"kiosk">>, <<"pager">> | _],
                   attrs := #{boot_order := {service, {ok, [<<"storage">>, <<"net">>]}},
                              rc_conf := {service, {ok, read}}}}, Record).

an_unread_rc_conf_is_shown_test() ->
    {ok, #{attrs := #{rc_conf := Value}}} = erx_app_records:record([apps], (table())#{rc_conf => unread}),
    ?assertEqual({service, {ok, unread}}, Value).

each_state_is_shown_test_() ->
    [?_assertMatch(#{state := {service, {ok, State}}, reason := {service, Reason}}, attrs(Name))
     || {Name, State, Reason} <- [{<<"clock">>, disabled, {ok, <<>>}},
                                   {<<"kiosk">>, running, {ok, <<>>}},
                                   {<<"pager">>, refused, {ok, <<"no_grant display">>}},
                                   {<<"tally">>, refused, {ok, <<"display_held kiosk">>}},
                                   {<<"ticker">>, refused, {ok, <<"past_ceiling restarts">>}},
                                   {<<"shelf">>, stopped, {ok, <<>>}},
                                   {<<"slate">>, starting, {ok, <<>>}}]].

%% Its session's last end is not collected, so its reason is not shown as none.
a_down_rows_reason_is_unknown_test() ->
    ?assertMatch(#{state := {service, {ok, down}}, reason := {service, unknown}}, attrs(<<"logger">>)).

%% A row stop marked and a row the table has yet to start read apart.
a_stopped_row_and_a_row_not_yet_started_differ_test() ->
    ?assertMatch(#{state := {service, {ok, stopped}}}, attrs(<<"shelf">>)),
    ?assertMatch(#{state := {service, {ok, starting}}}, attrs(<<"slate">>)).

a_row_shows_its_settings_test() ->
    ?assertMatch(#{enabled := {service, {ok, true}}, display := {service, {ok, <<"display">>}},
                   local := {service, {ok, [enable, display]}}}, attrs(<<"pager">>)),
    ?assertMatch(#{enabled := {service, {ok, false}}, display := {service, {ok, <<>>}},
                   local := {service, {ok, []}}}, attrs(<<"clock">>)).

what_is_not_collected_is_unsupported_test() ->
    ?assertMatch(#{domain := {service, unsupported}, ends := {service, unsupported}}, attrs(<<"kiosk">>)).

a_name_no_row_has_names_nothing_test() ->
    ?assertEqual({error, scope}, erx_app_records:record([apps, <<"nobody">>], table())).

an_unmade_table_shows_nothing_as_known_test() ->
    Unmade = (table())#{rows => unmade, rc_conf => unread},
    ?assertMatch({ok, #{children := unknown}}, erx_app_records:record([apps], Unmade)),
    {ok, #{attrs := Attrs}} = erx_app_records:record([apps, <<"kiosk">>], Unmade),
    ?assertEqual([unknown], lists:usort([Value || {service, Value} <- maps:values(Attrs)])),
    ?assertEqual(7, map_size(Attrs)).

no_start_service_is_unsupported_test() ->
    ?assertEqual(undefined, whereis(erx_starter)),
    ?assertEqual({error, unsupported}, erx_app_records:collect([apps])).
