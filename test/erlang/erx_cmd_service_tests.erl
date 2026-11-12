%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_service_tests).
-moduledoc """
EUnit cases of the command shell's `service` (erx_cmd_service,
docs/design-apps.md, "Interfaces"): its plans from inspector answers made
up as data, as FreeBSD's service(8) and rc.subr(8) answer. A command on a
row that is not enabled names its `one` form and acts on nothing;
`onestart` writes `start` to /apps/ctl; `service -e` lists the configured
domains in boot order and then the enabled rows, and says so when
rc.conf is unread or a row's state is unknown; each state `status`
shows comes from the row's record, never made up.
""".

-include_lib("eunit/include/eunit.hrl").

table(Names) ->
    {ok, #{kind => start_table, attrs => #{boot_order => {service, {ok, [<<"storage">>, <<"net">>]}},
                                           rc_conf => {service, {ok, read}}},
           children => Names}}.

table() -> table([<<"clock">>, <<"kiosk">>]).

row(Enabled, State) -> row(Enabled, State, {ok, <<>>}).

row(Enabled, State, Reason) ->
    {ok, #{kind => app, attrs => #{enabled => {service, {ok, Enabled}}, state => {service, {ok, State}},
                                   reason => {service, Reason}, domain => {service, unsupported}}}}.

plan(Line, Row) ->
    {ok, Request} = erx_cmd_service:parse(binary:split(Line, <<" ">>, [global])),
    flat(erx_cmd_service:plan(Request, table(), Row)).

%% A plan with its texts as binaries.
flat(Steps) ->
    [case Step of
         {Stream, Text} when Stream =:= out; Stream =:= err -> {Stream, iolist_to_binary(Text)};
         Other -> Other
     end || Step <- Steps].

usage_test_() ->
    [?_assertEqual({error, usage}, erx_cmd_service:parse(Args))
     || Args <- [[], [<<"-e">>, <<"x">>], [<<"-x">>], [<<"clock">>], [<<"clock">>, <<"frob">>],
                 [<<"clock">>, <<"oneenable">>], [<<"clock">>, <<"stop">>, <<"display=d">>],
                 [<<"clock">>, <<"start">>, <<"display=d">>], [<<"clock">>, <<"enable">>, <<"color=red">>],
                 [<<"clock">>, <<"enable">>, <<"display">>]]].

start_of_a_row_not_enabled_names_onestart_test() ->
    ?assertEqual([{out, <<"Cannot 'start' clock. Set clock_enable to YES in /apps/rc.conf or use 'onestart' "
                          "instead of 'start'.\n">>}, {status, ok}],
                 plan(<<"clock start">>, row(false, disabled))).

each_command_on_a_row_not_enabled_names_its_one_form_test_() ->
    [?_assertMatch([{out, <<"Cannot '", _/binary>>}, {status, ok}], plan(<<"clock ", Word/binary>>, row(false, disabled)))
     || Word <- [<<"stop">>, <<"restart">>, <<"status">>]].

onestart_starts_one_session_test() ->
    ?assertEqual([{out, <<"Starting clock.\n">>}, {ctl, <<"start clock display=display\n">>}],
                 plan(<<"clock onestart display=display">>, row(false, disabled))).

onestop_stops_it_test() ->
    ?assertEqual([{out, <<"Stopping clock.\n">>}, {ctl, <<"stop clock\n">>}],
                 plan(<<"clock onestop">>, row(false, disabled))).

start_of_an_enabled_row_test() ->
    ?assertEqual([{out, <<"Starting kiosk.\n">>}, {ctl, <<"start kiosk\n">>}], plan(<<"kiosk start">>, row(true, down))),
    ?assertEqual([{err, <<"kiosk already running?\n">>}, {status, failed}], plan(<<"kiosk start">>, row(true, running))).

stop_of_an_enabled_row_test() ->
    ?assertEqual([{out, <<"Stopping kiosk.\n">>}, {ctl, <<"stop kiosk\n">>}], plan(<<"kiosk stop">>, row(true, running))),
    ?assertEqual([{err, <<"kiosk not running? (stopped)\n">>}, {status, failed}],
                 plan(<<"kiosk stop">>, row(true, stopped))).

restart_stops_and_starts_test() ->
    ?assertEqual([{out, <<"Stopping kiosk.\n">>}, {ctl, <<"stop kiosk\n">>},
                  {out, <<"Starting kiosk.\n">>}, {ctl, <<"start kiosk\n">>}],
                 plan(<<"kiosk restart">>, row(true, running))).

enable_and_disable_write_rc_conf_test() ->
    ?assertEqual([{ctl, <<"enable clock display=display restarts=3\n">>},
                  {out, <<"clock enabled in /apps/rc.conf\n">>}],
                 plan(<<"clock enable display=display restarts=3">>, row(false, disabled))),
    ?assertEqual([{ctl, <<"disable kiosk\n">>}, {out, <<"kiosk disabled in /apps/rc.conf\n">>}],
                 plan(<<"kiosk disable">>, row(true, running))).

status_shows_each_state_test_() ->
    [?_assertEqual(Expected, plan(<<"kiosk status">>, Row))
     || {Row, Expected} <-
            [{row(true, running), [{out, <<"kiosk is running.\n">>}]},
             {row(true, down, unknown), [{out, <<"kiosk is not running (down).\n">>}, {status, failed}]},
             {row(true, stopped), [{out, <<"kiosk is not running (stopped).\n">>}, {status, failed}]},
             {row(true, starting), [{out, <<"kiosk is not running (starting).\n">>}, {status, failed}]},
             {row(true, refused, {ok, <<"no_grant display">>}),
              [{out, <<"kiosk is not running (refused: no_grant display).\n">>}, {status, failed}]}]].

onestatus_of_a_disabled_row_does_not_claim_it_is_down_test() ->
    ?assertEqual([{out, <<"kiosk is not enabled; a session started with onestart is not shown.\n">>}, {status, failed}],
                 plan(<<"kiosk onestatus">>, row(false, disabled))).

an_unknown_state_is_not_made_up_test() ->
    Unknown = {ok, #{kind => app, attrs => #{enabled => {service, unknown}, state => {service, unknown}}}},
    ?assertEqual([{err, <<"service: kiosk: enabled unknown\n">>}, {status, failed}],
                 plan(<<"kiosk status">>, Unknown)).

a_state_read_error_is_shown_test() ->
    Failed = {ok, #{kind => app, attrs => #{enabled => {service, {ok, true}}, state => {service, {error, invalid}}}}},
    ?assertEqual([{err, <<"service: kiosk: state error\n">>}, {status, failed}], plan(<<"kiosk status">>, Failed)).

stop_marks_a_row_yet_to_start_test() ->
    ?assertEqual([{out, <<"Stopping kiosk.\n">>}, {ctl, <<"stop kiosk\n">>}], plan(<<"kiosk stop">>, row(true, starting))).

a_value_with_a_blank_is_one_setting_or_none_test() ->
    ?assertEqual({error, usage}, erx_cmd_service:parse([<<"clock">>, <<"enable">>, <<"display=a period=9">>])),
    ?assertEqual({error, usage}, erx_cmd_service:parse([<<"clock">>, <<"enable">>, <<"display=a\nstop net">>])),
    ?assertMatch({ok, _}, erx_cmd_service:parse([<<"clock">>, <<"enable">>, <<"display=a">>])).

a_name_with_no_row_test() ->
    ?assertEqual([{err, <<"storage is configured in the system manifest\n">>}, {status, failed}],
                 plan(<<"storage restart">>, none)),
    ?assertEqual([{err, <<"service: nobody does not exist in the system manifest\n">>}, {status, failed}],
                 plan(<<"nobody start">>, none)).

a_name_is_escaped_test() ->
    ?assertEqual([{err, <<"service: a\\x1Bb does not exist in the system manifest\n">>}, {status, failed}],
                 plan(<<"a", 27, "b start">>, none)).

listing_test() ->
    Rows = [{<<"clock">>, row(false, disabled)}, {<<"kiosk">>, row(true, down, unknown)},
            {<<"pager">>, row(true, refused, {ok, <<"no_grant display">>})}],
    ?assertEqual([{out, <<"storage\n">>}, {out, <<"net\n">>}, {out, <<"kiosk\n">>}, {status, ok}],
                 flat(erx_cmd_service:listing(table([<<"clock">>, <<"kiosk">>, <<"pager">>]), Rows))).

listing_says_what_it_does_not_know_test() ->
    {ok, Unread} = table(),
    #{attrs := Attrs} = Unread,
    Answer = {ok, Unread#{attrs := Attrs#{rc_conf := {service, {ok, unread}}}}},
    ?assertMatch([{err, <<"service: /apps/rc.conf has not been read yet", _/binary>>}, {out, <<"storage\n">>},
                  {out, <<"net\n">>}, {err, <<"service: kiosk: /proc/apps: failed\n">>}, {status, failed}],
                 flat(erx_cmd_service:listing(Answer, [{<<"kiosk">>, {error, failed}}]))),
    ?assertMatch([{out, <<"storage\n">>}, {out, <<"net\n">>}, {err, <<"service: the start table is not made yet\n">>},
                  {status, failed}],
                 flat(erx_cmd_service:listing(table(unknown), []))),
    ?assertEqual([{err, <<"service: /proc/apps: no inspect facet\n">>}, {status, failed}],
                 flat(erx_cmd_service:listing({error, no_facet}, []))).

a_session_with_no_apps_grant_cannot_run_it_test() ->
    {Table, []} = erx_shell_namespace:build(
                    [{Module, Module:module_info(attributes), Module:module_info(exports)}
                     || Module <- [erx_cmd_service]]),
    Me = self(),
    Sink = fun(Stream) -> {tty, fun(Bytes) -> Me ! {Stream, iolist_to_binary(Bytes)}, ok end} end,
    State = erx_shell_runner:state(#{cwd => <<"/">>, fds => #{0 => null, 1 => Sink(out), 2 => Sink(err)},
                                     table => Table, facets => fun() -> #{} end}),
    Shell = erx_shell_eval:new(#{}, erx_shell_runner:runner(), State),
    {ok, Done} = erx_shell_eval:run_source(<<"service -e">>, Shell),
    ?assertEqual(<<"no_facet">>, erx_shell_eval:status(Done)),
    ?assertEqual({err, <<"service: no_facet\n">>}, receive {err, _} = Err -> Err after 1000 -> none end).
