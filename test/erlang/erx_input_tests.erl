%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The input router's core, erx_input (docs/design-display.md, "The input router" and
%% "Verification and testing"), as a state machine under the single policy and the
%% keymap us, with two windows of two sessions over the whole screen: the display's
%% session picks which one is shown, so a change of session moves the keyboard and the
%% pointer from one window to the other, and no session hides both.
%%
%% Two exhaustive runs step every sequence of up to ?DEPTH inputs, then end every source,
%% and check what each window received:
%%   * keys: per window, source and code, a down, its repeats and one up, in that order;
%%     no down or repeat while the window is hidden; the chord's key reaches no window;
%%     once every source has ended, no timer is set (key_order, key_while_hidden,
%%     chord_delivered, timer_left);
%%   * pointer: a hidden window receives only the events of the records that let a
%%     button or touch go, and once every source has ended every window's last event
%%     holds no button (pointer_while_hidden, pointer_held_at_end).
%% A random run checks that every pointer event lies inside the screen of its step
%% (pointer_outside_screen), with records before the first screen and screen changes.
-module(erx_input_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(DEPTH, 6).
-define(SCREEN, {0, 0, 640, 480}).
-define(A, ?ERX_EVDEV_KEY_A).
-define(SHIFT, ?ERX_EVDEV_KEY_LEFTSHIFT).
-define(CHORD, ?ERX_EVDEV_KEY_ESC).
-define(LEFT, ?ERX_EVDEV_BTN_LEFT).
-define(RIGHT, ?ERX_EVDEV_BTN_RIGHT).
-define(CONFIG, #{keymap => us, repeat_delay => 500, repeat_period => 126, chord => [?CHORD]}).

%% The world one sequence runs in: the router, its view, the clock, the sources' pids,
%% the last wake and what each window received, newest first, with its state then.
world() ->
    Sources = #{s1 => spawn(fun() -> ok end), s2 => spawn(fun() -> ok end)},
    World = #{state => erx_input:new(?CONFIG), session => <<"a">>, at => 0, sources => Sources,
              wake => none, got => [], screen => ?SCREEN, action => screen},
    step({screen, ?SCREEN}, World).

view(#{session := Session, screen := Screen}) ->
    Windows = [#{id => Id, dir => {Dir, <<"w">>}, rect => Screen,
                 state => case Dir of Session -> shown; _ -> hidden end}
               || {Id, Dir} <- [{1, <<"a">>}, {2, <<"b">>}]],
    #{windows => Windows, session => Session, policy => erx_wm_single, policy_state => #{}}.

step(In, #{state := State, got := Got, wake := Wake} = World) ->
    View = #{windows := Windows} = view(World),
    {Outs, #{}, Next} = erx_input:step(In, View, State),
    {Got1, Wake1} = lists:foldl(
                      fun({to, Id, #{event := Event}}, {G, Wk}) ->
                              {ok, #{state := WindowState}} = erx_wm:fetch(Id, Windows),
                              {[{Id, WindowState, Event, maps:get(action, World)} | G], Wk};
                         ({wake, At}, {G, _}) -> {G, At};
                         (_Other, Acc) -> Acc
                      end, {Got, Wake}, Outs),
    World#{state := Next, got := Got1, wake := Wake1}.

%% One action of a run, at a clock 300 ms on from the last.
act(Action, #{at := At0, sources := Sources} = World0) ->
    At = At0 + 300,
    World = World0#{at := At, action := Action},
    case Action of
        {gone, Source} -> step({gone, maps:get(Source, Sources), At}, World);
        {Source, Record} ->
            step({record, maps:get(Source, Sources), atom_to_binary(Source), At, Record}, World);
        tick -> step({tick, At}, World);
        focus -> World#{session := next_session(maps:get(session, World))}
    end.

next_session(<<"a">>) -> <<"b">>;
next_session(<<"b">>) -> none;
next_session(none) -> <<"a">>.

%% Every sequence of up to Depth actions from Alphabet, each checked by Check after every
%% source has ended.
explore(0, _Alphabet, World, Check) ->
    Check(finish(World));
explore(Depth, Alphabet, World, Check) ->
    Check(finish(World)),
    lists:foreach(fun(Action) -> explore(Depth - 1, Alphabet, act(Action, World), Check) end, Alphabet).

finish(World) -> act({gone, s2}, act({gone, s1}, World)).

%% Keys -----------------------------------------------------------------------

keys_alphabet() ->
    [{s1, {key, down, ?A}}, {s1, {key, up, ?A}}, {s1, {key, down, ?SHIFT}}, {s1, {key, up, ?SHIFT}},
     {s1, {key, down, ?CHORD}}, {s1, {key, up, ?CHORD}}, {s2, {key, down, ?A}}, {s2, {key, up, ?A}},
     focus, {s1, release}, {gone, s1}, tick].

check_keys(#{got := Got, wake := Wake}) ->
    Keys = [{Id, State, Event} || {Id, State, {key, _, _, _, _, _} = Event, _} <- lists:reverse(Got)],
    [error({chord_delivered, E}) || {_, _, {key, _, ?CHORD, _, _, _} = E} <- Keys],
    [error({key_while_hidden, Id, E}) || {Id, hidden, {key, Edge, _, _, _, _} = E} <- Keys, Edge =/= up],
    %% Grouped by window and code, over the sources in turn: keys of both sources share
    %% a code only for the letter, so each source's own order is checked by its group.
    Groups = lists:foldl(fun({Id, _, {key, Edge, Code, _, _, _}}, Acc) ->
                                 maps:update_with({Id, Code}, fun(L) -> [Edge | L] end, [Edge], Acc)
                         end, #{}, Keys),
    maps:foreach(fun(Group, Edges) -> ok = key_order(Group, lists:reverse(Edges), 0) end, Groups),
    case Wake of none -> ok; _ -> error({timer_left, Wake}) end.

%% Each edge against the downs outstanding for the group: an up needs one, a repeat needs
%% one, and none is outstanding at the end. The letter's group counts both sources' downs.
key_order(_Group, [], 0) -> ok;
key_order(Group, [], Held) -> error({key_order, Group, {held_at_end, Held}});
key_order(Group, [down | Rest], Held) -> key_order(Group, Rest, Held + 1);
key_order(Group, [repeat | Rest], Held) when Held > 0 -> key_order(Group, Rest, Held);
key_order(Group, [up | Rest], Held) when Held > 0 -> key_order(Group, Rest, Held - 1);
key_order(Group, [Edge | _], _Held) -> error({key_order, Group, Edge}).

keys_exhaustive_test_() ->
    {timeout, 600, fun() -> explore(?DEPTH, keys_alphabet(), world(), fun check_keys/1) end}.

%% Pointer --------------------------------------------------------------------

pointer_alphabet() ->
    [{s1, {key, down, ?LEFT}}, {s1, {key, up, ?LEFT}},
     {s1, {touch, 0, down, 100, 100}}, {s1, {touch, 0, move, 200, 200}}, {s1, {touch, 0, up, 200, 200}},
     {s1, {pointer, abs, 60000, 60000}}, {s2, {key, down, ?LEFT}}, {s2, {key, up, ?LEFT}},
     focus, {s1, release}, {gone, s1}].

check_pointer(#{got := Got}) ->
    Last = lists:foldl(fun({Id, State, {pointer, _, _, Buttons}, Action}, Seen) ->
                               case {State, lets_go(Action)} of
                                   {hidden, false} -> error({pointer_while_hidden, Id, Action});
                                   _ -> ok
                               end,
                               Seen#{Id => Buttons};
                          (_Key, Seen) -> Seen
                       end, #{}, lists:reverse(Got)),
    [error({pointer_held_at_end, Id, B}) || {Id, B} <- maps:to_list(Last), B =/= 0],
    ok.

%% The actions that let a button or touch go, the only ones a hidden window hears of.
lets_go({_, {key, up, _}}) -> true;
lets_go({_, {touch, _, up, _, _}}) -> true;
lets_go({_, release}) -> true;
lets_go({gone, _}) -> true;
lets_go(_Action) -> false.

pointer_exhaustive_test_() ->
    {timeout, 600, fun() -> explore(?DEPTH, pointer_alphabet(), world(), fun check_pointer/1) end}.

%% A window hidden mid-gesture hears its own buttons go up, and never of a button
%% pressed after it was hidden: the right button's down and up reach no window.
hidden_window_hears_only_its_own_buttons_test() ->
    Pressed = lists:foldl(fun act/2, world(),
                          [{s1, {key, down, ?LEFT}}, focus, {s1, {key, down, ?RIGHT}}]),
    #{got := Got} = lists:foldl(fun act/2, Pressed,
                                [{s1, {key, up, ?LEFT}}, {s1, {key, up, ?RIGHT}}]),
    ?assertEqual([{1, shown, 1}, {1, hidden, 0}],
                 [{Id, State, B} || {Id, State, {pointer, _, _, B}, _} <- lists:reverse(Got)]).

%% A doubled touch down, and a move or an up at a slot not held, change nothing.
unmatched_touch_changes_nothing_test() ->
    W0 = act({s1, {touch, 0, down, 10, 10}}, world()),
    lists:foreach(
      fun(Record) ->
              #{state := S0} = W0,
              #{state := S1, got := Got} = act({s1, Record}, W0#{got := []}),
              ?assertEqual([], Got),
              ?assertEqual(erx_input:dropped(S0) + 1, erx_input:dropped(S1))
      end, [{touch, 0, down, 10, 10}, {touch, 1, move, 10, 10}, {touch, 1, up, 10, 10}]).

%% A key typed with Shift held types the shift layer, and its k set names Shift.
shift_selects_the_layer_test() ->
    W = act({s1, {key, down, ?A}}, act({s1, {key, down, ?SHIFT}}, world())),
    [{1, shown, {key, down, ?A, $A, $a, [?ERX_INPUT_RUNE_KSHIFT]}, _} | _] = maps:get(got, W).

%% A window's repeat: delayed, periodic, with the runes of its down, stopped by the up.
repeat_test() ->
    W0 = act({s1, {key, down, ?A}}, world()),
    #{state := S0, at := At, wake := Due} = W0,
    ?assertEqual(At + 500, Due),
    View = view(W0),
    ?assertMatch({[], _, _}, erx_input:step({tick, Due - 1}, View, S0)),
    {Outs, _, S1} = erx_input:step({tick, Due}, View, S0),
    ?assertMatch([{to, 1, #{event := {key, repeat, ?A, $a, $a, []}}}, {wake, _}], Outs),
    {Outs2, _, _} = erx_input:step({record, maps:get(s1, maps:get(sources, W0)), <<"s1">>, Due + 1,
                                    {key, up, ?A}}, View, S1),
    ?assertMatch([{to, 1, #{event := {key, up, ?A, $a, $a, []}}}, {wake, none}], Outs2).

%% Records before the first screen are dropped and counted.
before_the_screen_test() ->
    S0 = erx_input:new(?CONFIG),
    View = view(#{session => <<"a">>, screen => ?SCREEN}),
    {[], #{}, S1} = erx_input:step({record, self(), <<"k">>, 0, {key, down, ?A}}, View, S0),
    ?assertEqual(1, erx_input:dropped(S1)).

%% Random ----------------------------------------------------------------------

pointer_inside_the_screen_test() ->
    _ = rand:seed(exsss, {1, 2, 3}),
    lists:foreach(fun(_) -> random_run(60) end, lists:seq(1, 500)).

random_run(Steps) ->
    Source = spawn(fun() -> ok end),
    View0 = view(#{session => <<"a">>, screen => ?SCREEN}),
    lists:foldl(
      fun(_, {S, Screen}) ->
              {In, Screen1} = random_input(Source, Screen),
              View = case Screen1 of
                         none -> View0;
                         _ -> view(#{session => <<"a">>, screen => Screen1})
                     end,
              {Outs, _, S1} = erx_input:step(In, View, S),
              [inside(X, Y, Screen1) || {to, _, #{event := {pointer, X, Y, _}}} <- Outs],
              {S1, Screen1}
      end, {erx_input:new(?CONFIG), none}, lists:seq(1, Steps)).

random_input(Source, Screen) ->
    Big = 16#7fffffff,
    case rand:uniform(5) of
        1 ->
            X0 = rand:uniform(2000) - 1000, Y0 = rand:uniform(2000) - 1000,
            New = {X0, Y0, X0 + rand:uniform(800), Y0 + rand:uniform(600)},
            {{screen, New}, New};
        2 ->
            {{record, Source, <<"m">>, 0, {pointer, rel, rand:uniform(2 * Big + 1) - Big - 1,
                                           rand:uniform(2 * Big + 1) - Big - 1}}, Screen};
        3 ->
            {{record, Source, <<"m">>, 0, {pointer, abs, rand:uniform(65536) - 1,
                                           rand:uniform(65536) - 1}}, Screen};
        4 ->
            {{record, Source, <<"m">>, 0, {touch, 0, case rand:uniform(3) of 1 -> down; 2 -> move; 3 -> up end,
                                           rand:uniform(65536) - 1, rand:uniform(65536) - 1}}, Screen};
        5 ->
            {{record, Source, <<"m">>, 0, {key, case rand:uniform(2) of 1 -> down; 2 -> up end, ?LEFT}}, Screen}
    end.

inside(X, Y, {X0, Y0, X1, Y1}) when X >= X0, X < X1, Y >= Y0, Y < Y1 -> ok;
inside(X, Y, Screen) -> error({pointer_outside_screen, X, Y, Screen}).
