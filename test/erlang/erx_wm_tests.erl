%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the window policy erx_wm_single
%% (docs/design-display.md, "Verification and testing", the window system).
%%
%% The property tests drive each policy as erx_winfs would, over random
%% sequences of windows made and ended, wctl requests and input events,
%% and check after every step:
%%   * every rectangle in the table lies within the screen, and so does
%%     every decoration (both policies);
%%   * a policy's answer holds the same windows, with every field but
%%     `rect` and `state` as erx_winfs gave it (both policies);
%%   * an event is delivered only to a shown window, and a key up only to
%%     the window that got its key down (both policies);
%%   * at most one window is shown, and whenever the application's
%%     session has a window, the shown one is its window with the lowest
%%     id (single);
%%   * the reserved chord is never delivered: neither the down that
%%     completes it, nor a repeat of that key, nor its up reaches a window
%%     (both policies);
%%   * every other key event reaches the shown window (single).
%% The key oracle keeps its own record of the keys held and the chord's
%% keys, written from the moduledocs' rules with lists rather than from
%% the policy's code. The sequences come from rand with a fixed seed, and
%% a failure names the policy, sequence, step and operation.
%%
%% Under the single policy only hidden windows end in these sequences:
%% after the shown window ends, no callback lets erx_winfs set the next
%% one's state in its table (TODO.md); input/3 already routes to it.

-module(erx_wm_tests).
-include_lib("eunit/include/eunit.hrl").
-export([properties/2]).

-define(SEQUENCES, 400).
-define(STEPS, 60).
-define(CHORD, [1, 2]).
-define(APP, <<"app">>).

%% Properties

single_properties_test() -> properties(erx_wm_single, 1).

-doc "Runs the property sequences of a policy from a seed; raises on a failure.".
properties(Policy, Seed) ->
    rand:seed(exsss, {20, 26, Seed}),
    lists:foreach(fun(Sequence) -> sequence(Policy, Sequence) end,
                  lists:seq(1, ?SEQUENCES)).

sequence(Policy, Sequence) ->
    Config = config(Policy),
    World = #{policy => Policy, screen => random_screen(), table => [],
              next => 1, state => Policy:init(Config), config => Config,
              keys_held => [], chord_keys => [], got_down => #{}},
    lists:foldl(fun(Step, Before) ->
                        Op = random_op(Before),
                        try
                            After = step(Op, Before),
                            check(After),
                            After
                        catch
                            error:Reason ->
                                error({property_failed, {Policy, Sequence, Step, Op}, Reason})
                        end
                end, World, lists:seq(1, ?STEPS)).

config(Policy) ->
    Base = case Policy of
               erx_wm_single -> #{app => ?APP}
           end,
    case rand:uniform(4) of
        1 -> Base;
        _ -> Base#{chord => ?CHORD}
    end.

%% One step of erx_winfs: make a window, end one, pass a wctl request or
%% route an input event.
step({new, Session}, World = #{policy := Policy, table := Table, next := Id,
                               screen := Screen, state := State}) ->
    Window = #{id => Id, dir => {Session, integer_to_binary(Id)},
               rect => {0, 0, 0, 0}, state => hidden, holder => {holder, Id}},
    Given = Table ++ [Window],
    {ok, Placed, Next} = Policy:place(new, Id, Given, Screen, State),
    same_windows(Given, Placed),
    World#{table := Placed, next := Id + 1, state := Next};
step({remove, Id}, World = #{table := Table}) ->
    World#{table := [W || W = #{id := Other} <- Table, Other =/= Id]};
step({wctl, Id, Request}, World = #{policy := Policy, table := Table,
                                    screen := Screen, state := State}) ->
    case Policy:place(Request, Id, Table, Screen, State) of
        {ok, Placed, Next} ->
            same_windows(Table, Placed),
            World#{table := Placed, state := Next};
        {error, einval} ->
            World
    end;
step({input, Input}, World = #{policy := Policy, table := Table, state := State}) ->
    {Route, Next} = Policy:input(Input, Table, State),
    routed(Input, Route, World#{state := Next}).

%% Checks a route against the table the event met, then applies it.
routed(Input = #{event := Event}, Route, World = #{table := Table}) ->
    Target = case Route of
                 {to, Id, Input} ->
                     shown_target(Id, World),
                     {to, Id};
                 {windows, _} -> none;
                 {wm, _} -> none;
                 drop -> none
             end,
    Keyed = keys(Event, Target, World),
    case Route of
        {windows, Arranged} ->
            same_windows(Table, Arranged),
            Keyed#{table := Arranged};
        _ ->
            Keyed
    end.

%% A delivered event goes to a shown window, and under the single policy
%% to the one shown window.
shown_target(Id, #{policy := Policy, table := Table}) ->
    Shown = [I || #{id := I, state := shown} <- Table],
    case {lists:member(Id, Shown), Policy, Shown} of
        {false, _, _} -> error({delivered_to_hidden, Id, Table});
        {true, erx_wm_single, [Id]} -> ok;
        {true, erx_wm_single, _} -> error({delivered_beside_the_shown, Id, Table})
    end.

%% A policy's answer holds the windows erx_winfs gave it, each with every
%% field but `rect` and `state` unchanged.
same_windows(Before, After) ->
    Rest = fun(Table) -> lists:sort([maps:without([rect, state], W) || W <- Table]) end,
    case Rest(Before) =:= Rest(After) of
        true -> ok;
        false -> error({windows_changed, Before, After})
    end.

%% The key oracle. A key down completes the chord when it is a chord key
%% that was up and, with it, every chord key is held, whatever else is; it and every repeat of that
%% key until its up are the chord's press. Any other key down must reach
%% the single policy's shown window, when there is one.
keys({key, down, Code, _}, Target, World = #{keys_held := HeldBefore,
                                             chord_keys := ChordKeys}) ->
    HeldAfter = lists:usort([Code | HeldBefore]),
    Completes = not lists:member(Code, HeldBefore) andalso lists:member(Code, chord(World))
        andalso chord(World) -- HeldAfter =:= [],
    ChordPress = Completes orelse lists:member(Code, ChordKeys),
    case {ChordPress, Target, shown_window(World)} of
        {true, {to, _}, _} -> error({chord_delivered, Code});
        {false, none, {single, _}} -> error({key_not_delivered, Code});
        _ -> ok
    end,
    GotDown = case Target of
                  {to, Id} -> (maps:get(got_down, World))#{Code => Id};
                  none -> maps:remove(Code, maps:get(got_down, World))
              end,
    World#{keys_held := HeldAfter,
           chord_keys := case ChordPress of
                             true -> lists:usort([Code | ChordKeys]);
                             false -> ChordKeys
                         end,
           got_down := GotDown};
%% A key up that is not the chord's goes to the shown window.
keys({key, up, Code, _}, Target, World = #{chord_keys := ChordKeys,
                                           got_down := GotDown, policy := Policy}) ->
    case {lists:member(Code, ChordKeys), Target, Policy, shown_window(World)} of
        {true, {to, _}, _, _} -> error({chord_up_delivered, Code});
        {false, none, _, {single, _}} -> error({key_not_delivered, Code});
        _ -> ok
    end,
    World#{keys_held := lists:delete(Code, maps:get(keys_held, World)),
           chord_keys := lists:delete(Code, ChordKeys),
           got_down := maps:remove(Code, GotDown)};
keys(_Event, _Target, World) ->
    World.

chord(#{config := #{chord := Chord}}) -> lists:usort(Chord);
chord(_) -> [].

%% Under the single policy, the window shown, if any.
shown_window(#{policy := erx_wm_single, table := Table}) ->
    case erx_wm:shown(Table) of
        [#{id := Id}] -> {single, Id};
        _ -> none
    end;
shown_window(_) ->
    none.

%% The properties every table must keep.
check(World = #{table := Table, screen := Screen}) ->
    case [W || W = #{rect := Rect} <- Table, not erx_wm:within(Rect, Screen)] of
        [] -> ok;
        Outside -> error({rectangle_outside_screen, Screen, Outside})
    end,
    one_shown(World),
    decorations_within(World).

%% At most one window shown, and whenever the application has a window,
%% the shown one is its oldest.
one_shown(#{table := Table}) ->
    Oldest = lists:sort([Id || #{id := Id, dir := {?APP, _}} <- Table]),
    case {erx_wm:shown(Table), Oldest} of
        {[_, _ | _], _} -> error({more_than_one_shown, Table});
        {[], []} -> ok;
        {[#{id := Id}], [Id | _]} -> ok;
        _ -> error({app_window_not_shown, Table})
    end.

decorations_within(#{policy := Policy, table := Table, screen := Screen}) ->
    lists:foreach(
      fun({Id, Sides}) ->
              case erx_wm:fetch(Id, Table) of
                  {ok, #{state := shown}} -> ok;
                  _ -> error({decorated_window_not_shown, Id})
              end,
              [error({decoration_outside_screen, Side})
               || {Side, _} <- Sides, not erx_wm:within(Side, Screen)]
      end, Policy:decorate(Table, Screen)).

%% Random operations

random_op(World = #{table := Table}) ->
    Ids = [Id || #{id := Id} <- Table],
    case {rand:uniform(10), Ids} of
        {1, _} -> {new, pick([?APP, ?APP, <<"other">>])};
        {2, [_, _ | _]} -> removal(World);
        {N, [_ | _]} when N =< 5 -> {wctl, pick([99 | Ids]), random_request()};
        {_, []} -> {new, pick([?APP, ?APP, <<"other">>])};
        _ -> {input, random_input()}
    end.

%% Only a hidden window ends (see the header).
removal(#{policy := erx_wm_single, table := Table}) ->
    case [Id || #{id := Id, state := hidden} <- Table] of
        [] -> {input, random_input()};
        Hidden -> {remove, pick(Hidden)}
    end.

random_request() ->
    case rand:uniform(6) of
        1 -> {resize, random_rect()};
        2 -> {move, random_rect()};
        N -> lists:nth(N - 2, [hide, show, top, bottom])
    end.

random_input() ->
    Event = case rand:uniform(5) of
                1 -> {pointer, coord(), coord(), pick([0, 0, 1, 2, 4, 5])};
                2 -> {touch, rand:uniform(10) - 1, pick([down, move, up]), coord(), coord()};
                3 -> {wheel, pick([-1, 1])};
                _ -> {key, pick([down, up]), rand:uniform(5), none}
            end,
    #{device => <<"test">>, at => 0, event => Event}.

%% Screens from tiny to large, at origins that are not always zero.
random_screen() ->
    X0 = pick([0, 0, -500, 300]),
    Y0 = pick([0, 0, -200, 100]),
    {X0, Y0, X0 + pick([1, 60, 240, 800, 1920]), Y0 + pick([1, 30, 240, 600, 1080])}.

random_rect() ->
    {coord(), coord(), coord(), coord()}.

%% Coordinates near the screens and at draw(3)'s extremes.
coord() ->
    case rand:uniform(8) of
        1 -> pick([-16#80000000, 16#7fffffff]);
        _ -> rand:uniform(2600) - 700
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).

%% Cases

screen() -> {0, 0, 1024, 768}.

window(Id, Session) ->
    #{id => Id, dir => {Session, integer_to_binary(Id)}, rect => {0, 0, 0, 0},
      state => hidden}.

key(Direction, Code) -> #{device => <<"kbd">>, at => 0, event => {key, Direction, Code, none}}.

%% Makes windows 1..N under a policy, each placed as erx_winfs would.
made(Policy, Config, Sessions) ->
    lists:foldl(fun({Id, Session}, {Table, State}) ->
                        {ok, Placed, Next} =
                            Policy:place(new, Id, Table ++ [window(Id, Session)],
                                         screen(), State),
                        {Placed, Next}
                end, {[], Policy:init(Config)},
                lists:zip(lists:seq(1, length(Sessions)), Sessions)).

single_shows_the_oldest_app_window_full_screen_test() ->
    {Table, _} = made(erx_wm_single, #{app => ?APP}, [<<"other">>, ?APP, ?APP]),
    ?assertMatch([#{id := 1, state := hidden}, #{id := 2, state := shown},
                  #{id := 3, state := hidden}], Table),
    ?assertEqual([screen()], lists:usort([R || #{rect := R} <- Table])),
    ?assertEqual([], erx_wm_single:decorate(Table, screen())).

%% No event marks a window's end: the table erx_winfs hands the policy
%% after the shown window ended already routes input to the next oldest.
single_next_oldest_takes_over_when_the_shown_ends_test() ->
    {Table, State} = made(erx_wm_single, #{app => ?APP}, [<<"other">>, ?APP, ?APP]),
    Ended = [W || W = #{id := Id} <- Table, Id =/= 2],
    ?assertEqual(3, erx_wm_single:shown(?APP, Ended)),
    ?assertMatch({{to, 3, _}, _}, erx_wm_single:input(key(down, 30), Ended, State)),
    Gone = [W || W = #{id := 1} <- Ended],
    ?assertEqual(none, erx_wm_single:shown(?APP, Gone)),
    ?assertMatch({drop, _}, erx_wm_single:input(key(down, 30), Gone, State)).

single_refuses_every_wctl_request_test() ->
    {Table, State} = made(erx_wm_single, #{app => ?APP}, [?APP]),
    [?assertEqual({error, einval}, erx_wm_single:place(R, 1, Table, screen(), State))
     || R <- [hide, show, top, bottom, {move, {0, 0, 1, 1}}, {resize, screen()}]].

single_chord_is_the_policys_test() ->
    {Table, State} = made(erx_wm_single, #{app => ?APP, chord => ?CHORD}, [?APP]),
    {{to, 1, _}, S1} = erx_wm_single:input(key(down, 1), Table, State),
    {{wm, chord}, S2} = erx_wm_single:input(key(down, 2), Table, S1),
    %% A driver repeating the held chord key: withheld, and no second chord.
    {drop, S3} = erx_wm_single:input(key(down, 2), Table, S2),
    {drop, S4} = erx_wm_single:input(key(up, 2), Table, S3),
    {{to, 1, _}, S5} = erx_wm_single:input(key(up, 1), Table, S4),
    {{to, 1, _}, S6} = erx_wm_single:input(key(down, 2), Table, S5),
    ?assertMatch({{wm, chord}, _}, erx_wm_single:input(key(down, 1), Table, S6)).

single_without_chord_withholds_nothing_test() ->
    {Table, State} = made(erx_wm_single, #{app => ?APP}, [?APP]),
    {{to, 1, _}, S1} = erx_wm_single:input(key(down, 1), Table, State),
    ?assertMatch({{to, 1, _}, _}, erx_wm_single:input(key(down, 2), Table, S1)).

bad_configuration_is_refused_test() ->
    ?assertError(badarg, erx_wm_single:init(#{})),
    ?assertError(badarg, erx_wm_single:init(#{app => ?APP, chord => []})),
    ?assertError(badarg, erx_wm_single:init(#{app => ?APP, chord => [16#10000]})).
