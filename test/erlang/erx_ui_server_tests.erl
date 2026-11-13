%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the widget toolkit (docs/design-display.md, "The widget
%% server" and "Choosing a display"): erx_ui's choice of display and
%% renderer, and erx_ui_server over a renderer this module plays. The
%% renderer reports each apply and its stop to the test process, and its
%% reader, a process linked to the server, is what a test ends to make the
%% renderer fail.
-module(erx_ui_server_tests).
-behaviour(erx_ui_renderer).

-include_lib("eunit/include/eunit.hrl").

-export([start/3, apply/2, stop/1]).

-define(WAIT_MS, 5000).

%% The renderer.

start(_Target, _Server, #{test := Test} = Opts) ->
    Reader = spawn_link(fun() -> receive {end_reader, Why} -> exit(Why) end end),
    Test ! {reader, Reader},
    {ok, Opts#{reader => Reader}}.

apply(Ops, #{test := Test} = State) ->
    Test ! {applied, Ops},
    case State of
        #{refuse := true} -> {error, refused};
        #{raise := true} -> exit(program_gone);
        #{} -> {ok, State}
    end.

stop(#{test := Test}) ->
    Test ! renderer_stopped,
    ok.

%% The cases.

toolkit_test_() ->
    {foreach,
     fun() -> {ok, Sup} = erx_ui_sup:start_link(), unlink(Sup), Sup end,
     fun(Sup) -> exit(Sup, shutdown), wait_gone(Sup) end,
     [fun a_tree_is_validated_numbered_and_applied/0,
      fun a_refused_tree_changes_nothing/0,
      fun a_hit_reaches_the_opener_as_its_term/0,
      fun nothing_a_renderer_sends_crashes_the_server/0,
      fun a_failed_renderer_ends_the_ui_as_renderer_down/0,
      fun a_refused_apply_ends_the_ui_as_renderer_down/0,
      fun a_renderer_that_raises_ends_the_ui_as_renderer_down/0,
      fun close_ends_the_ui_with_no_message/0,
      fun the_server_ends_with_its_opener/0]}.

a_tree_is_validated_numbered_and_applied() ->
    {Window, _Reader} = open(#{}),
    Tree = {column, #{}, [{button, #{text => <<"go">>, on_click => go}, []}]},
    ?assertEqual(ok, erx_ui:tree(Window, Tree)),
    ?assertEqual([{insert, 1, 0, 0, column, #{}},
                  {insert, 2, 1, 0, button, #{text => <<"go">>, on_click => go}}, commit],
                 applied()),
    ?assertEqual(ok, erx_ui:tree(Window, {column, #{}, [{button, #{text => <<"on">>, on_click => go}, []}]})),
    ?assertEqual([{set, 2, #{text => <<"on">>}, []}, commit], applied()),
    ok = erx_ui:close(Window).

a_refused_tree_changes_nothing() ->
    {Window, _Reader} = open(#{}),
    ?assertEqual({error, {unknown_kind, []}}, erx_ui:tree(Window, {frame, #{}, []})),
    ?assertEqual({error, {bad_value, {[0], text}}},
                 erx_ui:tree(Window, {column, #{}, [{label, #{text => 7}, []}]})),
    ?assertEqual(nothing, applied_or_nothing()),
    ok = erx_ui:tree(Window, {label, #{}, []}),
    ?assertEqual([{insert, 1, 0, 0, label, #{}}, commit], applied()),
    ok = erx_ui:close(Window).

a_hit_reaches_the_opener_as_its_term() ->
    {Window, _Reader} = open(#{}),
    ok = erx_ui:tree(Window, {button, #{on_click => {pressed, 1}}, []}),
    _ = applied(),
    server(Window) ! {ui_hit, 1, on_click, none},
    ?assertEqual({ui, Window, {pressed, 1}, click}, next_message()),
    ok = erx_ui:close(Window).

nothing_a_renderer_sends_crashes_the_server() ->
    {Window, _Reader} = open(#{}),
    ok = erx_ui:tree(Window, {slider, #{on_change => slid}, []}),
    _ = applied(),
    Server = server(Window),
    [Server ! Junk || Junk <- [garbage, {ui_hit, 99, on_click, none}, {ui_hit, 1, on_change, 1000},
                               {ui_hit, 1, <<"on_change">>, 5}, {ui_hit, 1}, {'EXIT', self(), normal}]],
    gen_server:cast(Server, garbage),
    ?assertEqual({error, badarg}, gen_server:call(Server, garbage)),
    Server ! {ui_hit, 1, on_change, 42},
    ?assertEqual({ui, Window, slid, {change, 42}}, next_message()),
    ok = erx_ui:close(Window).

a_failed_renderer_ends_the_ui_as_renderer_down() ->
    {Window, Reader} = open(#{}),
    Reader ! {end_reader, boom},
    ?assertEqual(renderer_stopped, next_message()),
    ?assertEqual({ui_down, Window, renderer_down}, next_message()),
    ?assertMatch({'DOWN', Window, process, _, {shutdown, renderer_down}}, next_message()),
    ?assertEqual({error, closed}, erx_ui:tree(Window, {label, #{}, []})),
    ok = erx_ui:close(Window).

a_refused_apply_ends_the_ui_as_renderer_down() ->
    {Window, _Reader} = open(#{refuse => true}),
    ?assertEqual({error, refused}, erx_ui:tree(Window, {label, #{}, []})),
    _ = applied(),
    ?assertEqual(renderer_stopped, next_message()),
    ?assertEqual({ui_down, Window, renderer_down}, next_message()),
    ok = erx_ui:close(Window).

a_renderer_that_raises_ends_the_ui_as_renderer_down() ->
    {Window, _Reader} = open(#{raise => true}),
    ?assertEqual({error, renderer_down}, erx_ui:tree(Window, {label, #{}, []})),
    _ = applied(),
    ?assertEqual(renderer_stopped, next_message()),
    ?assertEqual({ui_down, Window, renderer_down}, next_message()),
    ?assertMatch({'DOWN', Window, process, _, {shutdown, renderer_down}}, next_message()),
    ok = erx_ui:close(Window).

close_ends_the_ui_with_no_message() ->
    {Window, _Reader} = open(#{}),
    Server = server(Window),
    ok = erx_ui:close(Window),
    ?assertEqual(renderer_stopped, next_message()),
    wait_gone(Server),
    ?assertEqual(nothing, applied_or_nothing()),
    ?assertEqual({error, closed}, erx_ui:tree(Window, {label, #{}, []})).

the_server_ends_with_its_opener() ->
    Test = self(),
    Opener = spawn(fun() ->
                           {ok, Window} = erx_ui:start(spec(#{})),
                           Test ! {server, get({erx_ui, Window})},
                           receive stop -> ok end
                   end),
    Server = receive {server, S} -> S after ?WAIT_MS -> error(no_server) end,
    Opener ! stop,
    wait_gone(Server).

%% choose/2 and open/1, which make no atom and answer no_display for a
%% display the domain does not hold.
choose_test() ->
    Unset = #{display => false, ui_renderer => false},
    ?assertEqual({error, no_display}, erx_ui:choose(#{}, Unset)),
    ?assertEqual({ok, main, erlang}, erx_ui:choose(#{display => main}, Unset)),
    ?assertEqual({ok, web, lvgl}, erx_ui:choose(#{}, #{display => "web", ui_renderer => "lvgl"})),
    ?assertEqual({ok, main, lvgl}, erx_ui:choose(#{display => main, renderer => lvgl}, Unset)),
    ?assertEqual({ok, main, erlang}, erx_ui:choose(#{display => main}, Unset#{ui_renderer => "other"})),
    ?assertEqual({error, badarg}, erx_ui:choose(#{display => main, renderer => other}, Unset)),
    ?assertEqual({error, badarg}, erx_ui:choose(#{display => "main"}, Unset)),
    Unmade = "erx_ui_server_tests_no_such_display_atom",
    ?assertEqual({error, no_display}, erx_ui:choose(#{}, Unset#{display => Unmade})),
    ?assertError(badarg, list_to_existing_atom(Unmade)).

open_without_a_display_test() ->
    ?assertEqual({error, no_display}, erx_ui:open(#{display => erx_ui_server_tests_display})).

%% Helpers.

spec(Opts) ->
    #{renderer => ?MODULE, target => {window, test}, opts => Opts#{test => self()}}.

open(Opts) ->
    {ok, Window} = erx_ui:start(spec(Opts)),
    Reader = receive {reader, R} -> R after ?WAIT_MS -> error(no_reader) end,
    {Window, Reader}.

server(Window) -> get({erx_ui, Window}).

applied() ->
    receive {applied, Ops} -> Ops after ?WAIT_MS -> error(no_apply) end.

applied_or_nothing() ->
    receive {applied, Ops} -> Ops after 100 -> nothing end.

next_message() ->
    receive Message -> Message after ?WAIT_MS -> error(no_message) end.

wait_gone(Pid) ->
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, process, Pid, _} -> ok after ?WAIT_MS -> error({not_gone, Pid}) end.
