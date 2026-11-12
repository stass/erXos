%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The start table's pure core (docs/design-apps.md, "Verification and testing"):
%% the merge, rc.conf's names and values, the ctl grammar and set/3, on made-up
%% manifests. test/host/erx_start_table_test.rb runs them on stock's emulator, and
%% against each seeded fault it plants, where the case it names must fail.

-module(erx_start_table_tests).
-include_lib("eunit/include/eunit.hrl").

%% A manifest's rows: clock and kiosk may take the display; logger has none.
rows() ->
    [#{principal => <<"clock">>, enable => false, display => <<"display">>, restarts => 5, period => 600},
     #{principal => <<"kiosk">>, enable => true, display => <<"display">>, restarts => 5, period => 600},
     #{principal => <<"logger">>, enable => true, display => none, restarts => 3, period => 60}].

grants() ->
    #{<<"clock">> => [<<"display">>, <<"second">>], <<"kiosk">> => [<<"display">>]}.

merged(Text) ->
    {ok, Local} = erx_start_table:parse_rc_conf(Text),
    erx_start_table:merge(rows(), Local, grants()).

row(Name, Rows) ->
    [Row] = [Row || #{principal := Principal} = Row <- Rows, Principal =:= Name],
    Row.

the_manifest_alone_is_the_table_test() ->
    {Rows, []} = merged(<<>>),
    ?assertEqual([<<"clock">>, <<"kiosk">>, <<"logger">>], [P || #{principal := P} <- Rows]),
    ?assertMatch(#{status := disabled, from_rc_conf := []}, row(<<"clock">>, Rows)),
    ?assertMatch(#{status := enabled, display := <<"display">>}, row(<<"kiosk">>, Rows)),
    ?assertMatch(#{status := enabled, display := none}, row(<<"logger">>, Rows)).

settings_replace_defaults_test() ->
    {Rows, []} = merged(<<"# the machine's own\n"
                          "logger_restarts=\"9\"\n"
                          "  logger_period='120'   # two minutes\n"
                          "kiosk_display=\"\"\n">>),
    ?assertMatch(#{restarts := 9, period := 120, from_rc_conf := [period, restarts], status := enabled},
                 row(<<"logger">>, Rows)),
    ?assertMatch(#{display := none, from_rc_conf := [display], status := enabled}, row(<<"kiosk">>, Rows)).

no_disables_and_a_later_line_wins_test() ->
    {Rows, []} = merged(<<"kiosk_enable=\"YES\"\nkiosk_enable=\"NO\"\n">>),
    ?assertMatch(#{enable := false, status := disabled}, row(<<"kiosk">>, Rows)).

checkyesno_values_in_any_case_test() ->
    Read = fun(Value) ->
                   {ok, Local} = erx_start_table:parse_rc_conf(<<"clock_enable=\"", Value/binary, "\"">>),
                   Local
           end,
    [?assertEqual([{set, 1, <<"clock">>, enable, true}], Read(V))
     || V <- [<<"YES">>, <<"yes">>, <<"True">>, <<"on">>, <<"ON">>, <<"1">>]],
    [?assertEqual([{set, 1, <<"clock">>, enable, false}], Read(V))
     || V <- [<<"NO">>, <<"no">>, <<"False">>, <<"oFf">>, <<"0">>]],
    [?assertEqual([{skipped, 1, {bad_value, enable}}], Read(V))
     || V <- [<<>>, <<"yess">>, <<"2">>, <<"enabled">>]].

a_bad_line_and_an_undeclared_name_are_skipped_test() ->
    {Rows, Skipped} = merged(<<"clock_enable=\"YES\"\n"
                               "kiosk_enable=\"maybe\"\n"
                               "weather_enable=\"YES\"\n"
                               "hostname=\"box\"\n"
                               "kiosk_display=\"$HOME\"\n"
                               "logger_restarts=7 extra\n"
                               "just text\n"
                               "logger_period=\"60\n"
                               "logger_colour=\"red\"\n"
                               "logger_restarts=\"-1\"\n"
                               "logger_period=\"0\"\n"
                               "logger_restarts=\"4294967296\"\n">>),
    ?assertEqual([{skipped, 2, {bad_value, enable}},
                  {skipped, 3, {undeclared, <<"weather">>}},
                  {skipped, 4, bad_variable},
                  {skipped, 5, bad_quoting},
                  {skipped, 6, trailing_text},
                  {skipped, 7, not_an_assignment},
                  {skipped, 8, bad_quoting},
                  {skipped, 9, bad_variable},
                  {skipped, 10, {bad_value, restarts}},
                  {skipped, 11, {bad_value, period}},
                  {skipped, 12, {bad_value, restarts}}], Skipped),
    ?assertEqual(3, length(Rows)),
    ?assertMatch(#{status := enabled}, row(<<"clock">>, Rows)),
    ?assertMatch(#{restarts := 3, period := 60, from_rc_conf := []}, row(<<"logger">>, Rows)).

a_name_splits_at_its_last_underscore_test() ->
    Rows = [#{principal => <<"a_b">>, enable => false, display => none, restarts => 5, period => 600}],
    {ok, Local} = erx_start_table:parse_rc_conf(<<"a_b_enable=YES\n">>),
    ?assertEqual([{set, 1, <<"a_b">>, enable, true}], Local),
    ?assertMatch({[#{principal := <<"a_b">>, enable := true, status := enabled}], []},
                 erx_start_table:merge(Rows, Local, #{})).

a_second_enabled_row_on_a_display_is_refused_with_the_first_name_test() ->
    {Rows, []} = merged(<<"clock_enable=YES\n">>),
    ?assertMatch(#{status := enabled}, row(<<"clock">>, Rows)),
    ?assertEqual({refused, {display_held, <<"clock">>}}, maps:get(status, row(<<"kiosk">>, Rows))),
    {Moved, []} = merged(<<"clock_enable=YES\nclock_display=second\n">>),
    ?assertMatch(#{status := enabled, display := <<"second">>}, row(<<"clock">>, Moved)),
    ?assertMatch(#{status := enabled}, row(<<"kiosk">>, Moved)).

a_display_the_template_is_not_granted_is_refused_test() ->
    {Rows, []} = merged(<<"kiosk_display=second\nlogger_display=display\n">>),
    ?assertEqual({refused, {no_grant, <<"second">>}}, maps:get(status, row(<<"kiosk">>, Rows))),
    ?assertEqual({refused, {no_grant, <<"display">>}}, maps:get(status, row(<<"logger">>, Rows))),
    %% A disabled row asks for nothing, so it is not refused.
    {Off, []} = merged(<<"clock_display=elsewhere\n">>),
    ?assertMatch(#{status := disabled}, row(<<"clock">>, Off)).

rc_conf_over_64_kib_is_refused_test() ->
    Line = <<"# padding\n">>,
    Fits = binary:copy(Line, 65536 div byte_size(Line)),
    Exact = <<Fits/binary, (binary:copy(<<"#">>, 65536 - byte_size(Fits)))/binary>>,
    ?assertEqual(65536, byte_size(Exact)),
    ?assertEqual({ok, []}, erx_start_table:parse_rc_conf(Exact)),
    ?assertEqual({error, too_large}, erx_start_table:parse_rc_conf(<<Exact/binary, "\n">>)),
    ?assertEqual({error, too_large}, erx_start_table:set(<<Exact/binary, "\n">>, <<"clock">>, #{})),
    ?assertEqual({error, too_large}, erx_start_table:set(Exact, <<"clock">>, #{enable => true})).

ctl_commands_test() ->
    ?assertEqual({ok, {enable, <<"clock">>, #{display => <<"display">>, restarts => 3, period => 60}}},
                 erx_start_table:parse_ctl(<<"enable clock display=display restarts=3 period=60\n">>)),
    ?assertEqual({ok, {enable, <<"clock">>, #{display => none}}},
                 erx_start_table:parse_ctl(<<"  enable\tclock   display=">>)),
    ?assertEqual({ok, {disable, <<"a_b">>, #{}}}, erx_start_table:parse_ctl(<<"disable a_b\n">>)),
    ?assertEqual({ok, {start, <<"clock">>, #{display => <<"second">>}}},
                 erx_start_table:parse_ctl(<<"start clock display=second">>)),
    ?assertEqual({ok, {stop, <<"clock">>, #{}}}, erx_start_table:parse_ctl(<<"stop clock">>)).

ctl_refusals_test() ->
    [?assertEqual({error, Reason}, erx_start_table:parse_ctl(Write))
     || {Write, Reason} <- [{<<>>, empty}, {<<"\n">>, empty}, {<<"reboot clock">>, unknown_command},
                            {<<"enable">>, no_name}, {<<"enable Clock">>, bad_name},
                            {<<"enable ../x">>, bad_name},
                            {<<"stop clock display=display">>, setting_not_allowed},
                            {<<"start clock restarts=3">>, setting_not_allowed},
                            {<<"enable clock enable=YES">>, setting_not_allowed},
                            {<<"enable clock colour=red">>, bad_setting},
                            {<<"enable clock restarts">>, bad_setting},
                            {<<"enable clock period=0">>, bad_setting},
                            {<<"enable clock display=\"x\"">>, bad_setting},
                            {<<"enable clock restarts=1 restarts=2">>, duplicate_setting},
                            {<<"stop clock\nstop kiosk">>, not_one_line},
                            {<<"stop clock\n\n">>, not_one_line},
                            {<<"stop clock\r\n">>, not_one_line},
                            {<<"stop \e[2Jclock">>, not_one_line}]].

ctl_line_of_4096_bytes_test() ->
    Command = <<"stop clock">>,
    Fits = <<Command/binary, (binary:copy(<<" ">>, 4096 - byte_size(Command)))/binary>>,
    ?assertEqual({ok, {stop, <<"clock">>, #{}}}, erx_start_table:parse_ctl(Fits)),
    ?assertEqual({error, too_long}, erx_start_table:parse_ctl(<<Fits/binary, "\n">>)).

set_rewrites_only_the_row_variables_test() ->
    Text = <<"# local settings\n"
             "kiosk_enable=\"YES\"\n"
             "clock_enable=\"NO\"   # off for now\n"
             "clock_display=\"display\"\n"
             "not a setting\n"
             "  clock_enable=YES\n"
             "clock_enabled=\"x\"\n">>,
    {ok, Out} = erx_start_table:set(Text, <<"clock">>, #{enable => true, display => none, restarts => 2}),
    ?assertEqual(<<"# local settings\n"
                   "kiosk_enable=\"YES\"\n"
                   "clock_enable=\"YES\"\n"
                   "clock_display=\"\"\n"
                   "not a setting\n"
                   "clock_enabled=\"x\"\n"
                   "clock_restarts=\"2\"\n">>, Out),
    {Rows, _} = merged(Out),
    ?assertMatch(#{enable := true, display := none, restarts := 2}, row(<<"clock">>, Rows)).

set_appends_to_a_file_without_a_final_newline_test() ->
    ?assertEqual({ok, <<"clock_period=\"30\"\n">>}, erx_start_table:set(<<>>, <<"clock">>, #{period => 30})),
    ?assertEqual({ok, <<"# x\nclock_enable=\"NO\"\n">>},
                 erx_start_table:set(<<"# x">>, <<"clock">>, #{enable => false})),
    ?assertEqual({error, bad_setting}, erx_start_table:set(<<>>, <<"Clock">>, #{enable => true})),
    ?assertEqual({error, bad_setting}, erx_start_table:set(<<>>, <<"clock">>, #{display => <<"a\"b">>})),
    ?assertEqual({error, bad_setting}, erx_start_table:set(<<>>, <<"clock">>, #{period => 0})).
