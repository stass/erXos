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
%%   * every key event reaches the shown window (single).
%% The reserved chord is the input router's, tested with it (erx_input_tests).
%% The key oracle keeps its own record of the windows keys went down to,
%% written from the moduledocs' rules rather than from the policy's code. The sequences come from rand with a fixed seed, and
%% a failure names the policy, sequence, step and operation.
%%
%% A window's end and a change of screen are followed by arrange/3, as
%% erx_winfs does.

-module(erx_wm_tests).
-include_lib("eunit/include/eunit.hrl").
-export([properties/2]).

-define(SEQUENCES, 400).
-define(STEPS, 60).
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
              got_down => #{}},
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
               erx_wm_single -> #{}
           end,
    case rand:uniform(4) of
        _ -> Base
    end.

%% One step of erx_winfs: make a window, end one, pass a wctl request or
%% route an input event.
step({new, Session}, World = #{policy := Policy, table := Table, next := Id,
                               screen := Screen, state := State}) ->
    Window = #{id => Id, dir => {Session, integer_to_binary(Id)},
               rect => {0, 0, 0, 0}, state => hidden, holder => {holder, Id}},
    Given = Table ++ [Window],
    {ok, Placed, Next} = Policy:place(new, Id, Given, Screen, ?APP, State),
    same_windows(Given, Placed),
    World#{table := Placed, next := Id + 1, state := Next};
step({remove, Id}, World = #{table := Table}) ->
    arranged([W || W = #{id := Other} <- Table, Other =/= Id], World);
step({screen, Screen}, World = #{table := Table}) ->
    arranged(Table, World#{screen := Screen});
step({wctl, Id, Request}, World = #{policy := Policy, table := Table,
                                    screen := Screen, state := State}) ->
    case Policy:place(Request, Id, Table, Screen, ?APP, State) of
        {ok, Placed, Next} ->
            same_windows(Table, Placed),
            World#{table := Placed, state := Next};
        {error, einval} ->
            World
    end;
step({input, Input}, World = #{policy := Policy, table := Table, state := State}) ->
    {Route, Next} = Policy:input(Input, Table, ?APP, State),
    routed(Input, Route, World#{state := Next}).

%% Asks the policy to arrange a table erx_winfs changed itself.
arranged(Given, World = #{policy := Policy, screen := Screen, state := State}) ->
    {Arranged, Next} = Policy:arrange(Given, Screen, ?APP, State),
    same_windows(Given, Arranged),
    World#{table := Arranged, state := Next}.

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

%% The key oracle: under the single policy every key event the policy is asked about
%% reaches the shown window, when there is one.
keys({key, Edge, Code, _, _, _}, Target, World = #{got_down := GotDown}) ->
    case {Target, shown_window(World)} of
        {none, {single, _}} -> error({key_not_delivered, Edge, Code});
        _ -> ok
    end,
    World#{got_down := case {Edge, Target} of
                           {down, {to, Id}} -> GotDown#{Code => Id};
                           {up, _} -> maps:remove(Code, GotDown);
                           _ -> GotDown
                       end};
keys(_Event, _Target, World) ->
    World.

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

random_op(#{table := Table}) ->
    Ids = [Id || #{id := Id} <- Table],
    case {rand:uniform(10), Ids} of
        {1, _} -> {new, pick([?APP, ?APP, <<"other">>])};
        {2, [_ | _]} -> {remove, pick(Ids)};
        {3, _} -> {screen, random_screen()};
        {N, [_ | _]} when N =< 5 -> {wctl, pick([99 | Ids]), random_request()};
        {_, []} -> {new, pick([?APP, ?APP, <<"other">>])};
        _ -> {input, random_input()}
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
                _ -> {key, pick([down, repeat, up]), rand:uniform(5), none, none, []}
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

key(Direction, Code) -> #{device => <<"kbd">>, at => 0, event => {key, Direction, Code, none, none, []}}.

%% Makes windows 1..N under a policy, each placed as erx_winfs would.
made(Policy, Config, Sessions) ->
    lists:foldl(fun({Id, Session}, {Table, State}) ->
                        {ok, Placed, Next} =
                            Policy:place(new, Id, Table ++ [window(Id, Session)],
                                         screen(), ?APP, State),
                        {Placed, Next}
                end, {[], Policy:init(Config)},
                lists:zip(lists:seq(1, length(Sessions)), Sessions)).

single_shows_the_oldest_app_window_full_screen_test() ->
    {Table, _} = made(erx_wm_single, #{}, [<<"other">>, ?APP, ?APP]),
    ?assertMatch([#{id := 1, state := hidden}, #{id := 2, state := shown},
                  #{id := 3, state := hidden}], Table),
    ?assertEqual([screen()], lists:usort([R || #{rect := R} <- Table])),
    ?assertEqual([], erx_wm_single:decorate(Table, screen())).

%% No event marks a window's end: the table erx_winfs hands the policy
%% after the shown window ended already routes input to the next oldest.
single_next_oldest_takes_over_when_the_shown_ends_test() ->
    {Table, State} = made(erx_wm_single, #{}, [<<"other">>, ?APP, ?APP]),
    Ended = [W || W = #{id := Id} <- Table, Id =/= 2],
    ?assertEqual(3, erx_wm_single:shown(?APP, Ended)),
    ?assertMatch({{to, 3, _}, _}, erx_wm_single:input(key(down, 30), Ended, ?APP, State)),
    Gone = [W || W = #{id := 1} <- Ended],
    ?assertEqual(none, erx_wm_single:shown(?APP, Gone)),
    ?assertMatch({drop, _}, erx_wm_single:input(key(down, 30), Gone, ?APP, State)).

single_refuses_every_wctl_request_test() ->
    {Table, State} = made(erx_wm_single, #{}, [?APP]),
    [?assertEqual({error, einval}, erx_wm_single:place(R, 1, Table, screen(), ?APP, State))
     || R <- [hide, show, top, bottom, {move, {0, 0, 1, 1}}, {resize, screen()}]].

single_without_chord_withholds_nothing_test() ->
    {Table, State} = made(erx_wm_single, #{}, [?APP]),
    {{to, 1, _}, S1} = erx_wm_single:input(key(down, 1), Table, ?APP, State),
    ?assertMatch({{to, 1, _}, _}, erx_wm_single:input(key(down, 2), Table, ?APP, S1)).

bad_configuration_is_refused_test() ->
    ?assertError(badarg, erx_wm_single:init(not_a_map)),
    ?assertError(badarg, erx_wm_single:init(#{chord => [1]})),
    ?assertError(badarg, erx_wm_single:init(#{app => ?APP})),
    ?assertError(badarg, erx_wm_single:init(#{session => ?APP})).

%% With no session every window is hidden and input reaches none; a session that
%% comes later shows its oldest window, and another session's shows another's.
single_follows_the_session_it_is_passed_test() ->
    State = erx_wm_single:init(#{}),
    Table = [window(1, <<"a">>), window(2, <<"b">>), window(3, <<"b">>)],
    {None, State} = erx_wm_single:arrange(Table, screen(), none, State),
    ?assertEqual([], erx_wm:shown(None)),
    ?assertEqual(none, erx_wm_single:shown(none, None)),
    ?assertMatch({drop, _}, erx_wm_single:input(key(down, 30), None, none, State)),
    {ForB, State} = erx_wm_single:arrange(Table, screen(), <<"b">>, State),
    ?assertMatch([#{id := 2}], erx_wm:shown(ForB)),
    {ForA, State} = erx_wm_single:arrange(ForB, screen(), <<"a">>, State),
    ?assertMatch([#{id := 1}], erx_wm:shown(ForA)),
    ?assertMatch({{to, 1, _}, _}, erx_wm_single:input(key(down, 30), ForA, <<"a">>, State)).
