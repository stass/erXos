%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_screen_core, the screen's pure core
%% (docs/design-display.md, "The screen and its one path to the device" and
%% "Who touches pixels"), explored exhaustively over small screens.
%%
%% The oracle works pixel by pixel, which the core never does: the source of
%% a pixel is found by walking the layout from the top window down and taking
%% the first decoration or window rectangle that contains it, else the
%% background. Every rectangle the core returns is expanded into its pixels
%% and compared with the pixels the oracle names, counting each pixel, so a
%% gap, an overlap or a pixel too many fails the case that saw it, and the
%% failure names the layouts.

-module(erx_screen_core_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BACKGROUND, 0).
%% Long enough for the largest domain on a slow host.
-define(EXHAUSTIVE_SECONDS, 300).

%% Domains.

%% Every nonempty rectangle with corners on the given coordinates.
rects(Xs, Ys) ->
    [{X0, Y0, X1, Y1} || X0 <- Xs, X1 <- Xs, X0 < X1, Y0 <- Ys, Y1 <- Ys, Y0 < Y1].

window(Id, Rect, Decorations) ->
    #{id => Id, rect => Rect, decorations => Decorations, proc => self()}.

%% The decorations the tiling domain gives a window of rectangle R: none; one
%% pixel at its top-left corner; one covering the window; two that overlap
%% at the corner in different colours, where the later one shows; and a
%% strip above the window reaching past both its sides, as a border outside
%% the window's rectangle would.
tiling_decorations({X0, Y0, X1, Y1}) ->
    [[],
     [{{X0, Y0, X0 + 1, Y0 + 1}, 1}],
     [{{X0, Y0, X1, Y1}, 2}],
     [{{X0, Y0, X1, Y0 + 1}, 1}, {{X0, Y0, X0 + 1, Y1}, 2}],
     [{{X0 - 1, Y0 - 1, X1 + 1, Y0}, 2}]].

%% Layouts over the 3-by-2 screen with rectangles reaching past every edge:
%% one window of any rectangle with each decoration choice; two windows,
%% both stacking orders, from a coarser set; three undecorated windows.
tiling_layouts() ->
    One = rects([-1, 0, 1, 2, 3, 4], [-1, 0, 1, 2, 3]),
    Two = rects([-1, 1, 2, 4], [-1, 1, 3]),
    Three = rects([0, 1, 3], [0, 1, 2]),
    Empty = {1, 1, 1, 2},
    [[]]
        ++ [[window(1, R, D)] || R <- [Empty | One], D <- tiling_decorations(R)]
        ++ [[window(A, RA, DA), window(B, RB, DB)]
            || {A, B} <- [{1, 2}, {2, 1}], RA <- Two, RB <- Two,
               DA <- tiling_decorations(RA), DB <- tiling_decorations(RB)]
        ++ [[window(1, RA, []), window(2, RB, []), window(3, RC, [])]
            || RA <- Three, RB <- Three, RC <- Three].

%% Layouts over the 2-by-2 screen for pairs of layouts: none, one or two
%% windows, each rectangle inside the screen or the one past every edge,
%% each window with or without a pixel of decoration at the top-left corner
%% of its part of the screen.
%% Window 1's decoration has the background's colour, window 2's another,
%% so a fill of the same colour and a fill of a new one both occur. The
%% rectangle {0, 0, 2, 2} undecorated, alone, is the direct path.
pair_layouts() ->
    Rects = [{-1, -1, 3, 3} | rects([0, 1, 2], [0, 1, 2])],
    Window = fun(Id, R) -> [window(Id, R, D) || D <- pair_decorations(Id, R)] end,
    [[]]
        ++ [[W] || Id <- [1, 2], R <- Rects, W <- Window(Id, R)]
        ++ [[WA, WB] || {A, B} <- [{1, 2}, {2, 1}], RA <- Rects, RB <- Rects,
                        WA <- Window(A, RA), WB <- Window(B, RB)].

pair_decorations(Id, {X0, Y0, _, _}) ->
    Color = case Id of 1 -> ?BACKGROUND; 2 -> 1 end,
    {X, Y} = {max(X0, 0), max(Y0, 0)},
    [[], [{{X, Y, X + 1, Y + 1}, Color}]].

%% The oracle.

pixels({X0, Y0, X1, Y1}) ->
    [{X, Y} || Y <- lists:seq(Y0, Y1 - 1), X <- lists:seq(X0, X1 - 1)].

pixels_of(Rects) ->
    lists:sort(lists:flatmap(fun pixels/1, Rects)).

inside({X, Y}, {X0, Y0, X1, Y1}) -> X >= X0 andalso X < X1 andalso Y >= Y0 andalso Y < Y1.

%% The source of pixel P under Layout, topmost window first, each window's
%% last decoration first.
source_at(_, []) ->
    {background, ?BACKGROUND};
source_at(P, [#{id := Id, proc := Proc, rect := {X0, Y0, _, _} = R, decorations := Ds} | Below]) ->
    case [Color || {DR, Color} <- lists:reverse(Ds), inside(P, DR)] of
        [Color | _] -> {decoration, Id, Color};
        [] ->
            case inside(P, R) of
                true -> {window, Id, Proc, {X0, Y0}};
                false -> source_at(P, Below)
            end
    end.

%% What a pixel shows: fills of one colour look the same.
look({window, _, _, _} = Source) -> Source;
look({decoration, _, Color}) -> {fill, Color};
look({background, Color}) -> {fill, Color}.

direct(Screen, [#{rect := Screen, decorations := []}]) -> true;
direct(_, _) -> false.

%% What each pixel of Screen shows before New takes effect, after Old, or
%% unknown everywhere for a fresh screen and for a layout on the copy path after
%% the direct path, whose screen image holds none of the window's pixels.
before(_, none, _) ->
    fun(_) -> unknown end;
before(Screen, Old, New) ->
    case direct(Screen, Old) andalso not direct(Screen, New) of
        true -> fun(_) -> unknown end;
        false -> fun(P) -> look(source_at(P, Old)) end
    end.

%% The plan the oracle expects: per window the pixels to copy from its
%% buffer, none on the direct path, the pixels to fill with their colours,
%% and every changed pixel to push.
expected_plan(Screen, Old, New) ->
    Shown = before(Screen, Old, New),
    Changed = [{P, source_at(P, New)} || P <- pixels(Screen),
                                         look(source_at(P, New)) =/= Shown(P)],
    Copies = [{Id, Ps} || #{id := Id} <- New,
                           Ps <- [lists:sort([P || {P, {window, W, _, _}} <- Changed, W =:= Id])],
                           Ps =/= []],
    Fills = lists:sort([{P, Color} || {P, Source} <- Changed, {fill, Color} <- [look(Source)]]),
    Push = lists:sort([P || {P, _} <- Changed]),
    case direct(Screen, New) of
        true -> {[], Fills, Push};
        false -> {Copies, Fills, Push}
    end.

%% Running the core.

%% A screen whose driver takes a client's buffer, so the direct path is open.
screen(Rect) ->
    screen(Rect, true).

screen(Rect, Direct) ->
    {ok, State} = erx_screen_core:new(Rect, ?BACKGROUND, Direct),
    State.

laid_out(Rect, Layouts) ->
    lists:foldl(fun(Layout, State) ->
                        {ok, _, Next} = erx_screen_core:layout(Layout, State),
                        Next
                end, screen(Rect), Layouts).

plan_pixels(#{fill := Fills, copy := Copies, push := Push}) ->
    {[{Id, pixels_of(Rs)} || {Id, Rs} <- Copies],
     lists:sort([{P, Color} || {R, Color} <- Fills, P <- pixels(R)]),
     pixels_of(Push)}.

%% Every pixel of the screen comes from exactly one source, the oracle's.

tiles_cover_every_pixel_once_test_() ->
    {timeout, ?EXHAUSTIVE_SECONDS,
     fun() ->
             Screen = {0, 0, 3, 2},
             lists:foreach(fun(Layout) -> check_tiling(Screen, Layout) end,
                           tiling_layouts())
     end}.

check_tiling(Screen, Layout) ->
    State = laid_out(Screen, [Layout]),
    Tiles = erx_screen_core:tiles(State),
    Got = lists:sort([{P, Source} || {R, Source} <- Tiles, P <- pixels(R)]),
    Want = [{P, source_at(P, Layout)} || P <- lists:sort(pixels(Screen))],
    ?assertEqual({Layout, Want}, {Layout, Got}),
    [?assertEqual({Layout, Id, [P || {P, {window, W, _, _}} <- Want, W =:= Id]},
                  {Layout, Id, pixels_of(erx_screen_core:visible(Id, State))})
     || #{id := Id} <- Layout].

%% A layout change copies and fills exactly the pixels whose look changed.

layout_changes_copy_and_fill_exactly_what_changed_test_() ->
    {timeout, ?EXHAUSTIVE_SECONDS,
     fun() ->
             Screen = {0, 0, 2, 2},
             Layouts = pair_layouts(),
             lists:foreach(fun(Old) ->
                                   Before = laid_out(Screen, [Old]),
                                   [check_change(Screen, Old, Before, New) || New <- Layouts]
                           end, Layouts)
     end}.

first_layout_fills_and_copies_everything_test() ->
    Screen = {0, 0, 2, 2},
    [check_change(Screen, none, screen(Screen), New) || New <- pair_layouts()].

check_change(Screen, Old, Before, New) ->
    {ok, Plan, _} = erx_screen_core:layout(New, Before),
    ?assertEqual({Old, New, expected_plan(Screen, Old, New)}, {Old, New, plan_pixels(Plan)}).

repaint_fills_and_copies_everything_test() ->
    Screen = {0, 0, 2, 2},
    lists:foreach(
      fun(Layout) ->
              {Plan, _} = erx_screen_core:repaint(laid_out(Screen, [Layout])),
              ?assertEqual({Layout, expected_plan(Screen, none, Layout)},
                           {Layout, plan_pixels(Plan)})
      end, pair_layouts()).

%% A present copies exactly the changed pixels the window shows, or on the
%% direct path pushes exactly its changed pixels on the screen.

present_copies_exactly_the_visible_dirty_area_test_() ->
    {timeout, ?EXHAUSTIVE_SECONDS,
     fun() ->
             Screen = {0, 0, 2, 2},
             Dirty = rects([-1, 0, 1, 3], [-1, 0, 1, 3]),
             Bounds = [Screen, {0, 0, 1, 1}, {1, 0, 5, 5}, {-3, -3, -1, -1}],
             [check_present(Screen, Layout, Id, B, Dirty)
              || Layout <- pair_layouts(), Id <- [3 | [I || #{id := I} <- Layout]],
                 B <- Bounds]
     end}.

check_present(Screen, Layout, Id, Bounds, DirtyRects) ->
    State = laid_out(Screen, [Layout]),
    Direct = direct(Screen, Layout),
    lists:foreach(
      fun(Dirty) ->
              Wanted = [P || P <- pixels(Screen), inside(P, Dirty), inside(P, Bounds),
                             is_window(Id, source_at(P, Layout))],
              Want = {case Direct andalso is_window(Id, source_at({0, 0}, Layout)) of
                          true -> direct;
                          false -> copy
                      end, lists:sort(Wanted)},
              {Path, Rects} = erx_screen_core:present({Id, self()}, Bounds, [Dirty], State),
              ?assertEqual({Layout, Id, Bounds, Dirty, Want},
                           {Layout, Id, Bounds, Dirty, {Path, pixels_of(Rects)}})
      end, DirtyRects).

is_window(Id, {window, Id, _, _}) -> true;
is_window(_, _) -> false.

present_of_overlapping_rectangles_test() ->
    State = laid_out({0, 0, 4, 4}, [[window(1, {0, 0, 2, 4}, []), window(2, {0, 0, 4, 4}, [])]]),
    {copy, Rects} = erx_screen_core:present({2, self()}, {0, 0, 4, 4}, [{0, 0, 3, 1}, {2, 0, 4, 2}], State),
    ?assertEqual(lists:sort([{2, 0}, {3, 0}, {2, 0}, {2, 1}, {3, 1}]), pixels_of(Rects)).

%% The direct path.

direct_path_is_one_undecorated_window_covering_the_screen_test() ->
    Screen = {0, 0, 4, 3},
    Path = fun(Layout) -> erx_screen_core:path(laid_out(Screen, [Layout])) end,
    ?assertEqual({direct, 7}, Path([window(7, Screen, [])])),
    ?assertEqual(copy, Path([window(7, Screen, [{{0, 0, 1, 1}, 5}])])),
    ?assertEqual(copy, Path([window(7, {0, 0, 4, 2}, [])])),
    ?assertEqual(copy, Path([window(7, {-1, 0, 4, 3}, [])])),
    ?assertEqual(copy, Path([window(7, Screen, []), window(8, {0, 0, 1, 1}, [])])),
    ?assertEqual(copy, Path([])).

leaving_direct_path_copies_every_window_whole_test() ->
    Screen = {0, 0, 4, 3},
    Direct = laid_out(Screen, [[window(7, Screen, [])]]),
    Border = {{0, 0, 4, 1}, 5},
    {ok, Plan, _} = erx_screen_core:layout([window(8, {1, 1, 3, 3}, []), window(7, Screen, [Border])],
                                           Direct),
    #{copy := Copies, fill := Fills} = Plan,
    ?assertEqual([{8, pixels_of([{1, 1, 3, 3}])},
                  {7, pixels_of([{0, 1, 1, 3}, {3, 1, 4, 3}])}],
                 [{Id, pixels_of(Rs)} || {Id, Rs} <- Copies]),
    ?assertEqual([Border], Fills).

entering_direct_path_pushes_only_what_the_screen_lacks_test() ->
    Screen = {0, 0, 4, 3},
    Framed = laid_out(Screen, [[window(7, Screen, [{{0, 0, 4, 1}, 5}])]]),
    {ok, Plan, Direct} = erx_screen_core:layout([window(7, Screen, [])], Framed),
    ?assertEqual(#{fill => [], copy => [], push => [{0, 0, 4, 1}]}, Plan),
    ?assertEqual({direct, 7}, erx_screen_core:path(Direct)).

%% A driver that does not take a client's buffer keeps every layout on the copy
%% path, the one window that covers the screen included, and copies it.
a_driver_without_direct_copies_every_layout_test() ->
    Screen = {0, 0, 4, 3},
    {ok, Plan, State} = erx_screen_core:layout([window(7, Screen, [])], screen(Screen, false)),
    ?assertEqual(copy, erx_screen_core:path(State)),
    ?assertEqual(#{fill => [], copy => [{7, [Screen]}], push => [Screen]}, Plan),
    ?assertEqual({copy, [Screen]}, erx_screen_core:present({7, self()}, Screen, [Screen], State)),
    ?assertEqual({error, einval}, erx_screen_core:new(Screen, ?BACKGROUND, yes)).

%% Targeted cases of the change rule.

a_decoration_of_the_background_colour_needs_no_fill_test() ->
    Screen = {0, 0, 4, 4},
    Before = laid_out(Screen, [[window(1, {0, 0, 2, 2}, [])]]),
    {ok, Plan, _} = erx_screen_core:layout([window(1, {0, 0, 2, 2}, [{{2, 2, 3, 3}, ?BACKGROUND}])],
                                           Before),
    ?assertEqual(#{fill => [], copy => [], push => []}, Plan).

a_moved_window_is_copied_wherever_it_shows_other_pixels_test() ->
    Screen = {0, 0, 4, 1},
    Before = laid_out(Screen, [[window(1, {0, 0, 2, 1}, [])]]),
    {ok, Plan, _} = erx_screen_core:layout([window(1, {1, 0, 3, 1}, [])], Before),
    ?assertEqual(#{fill => [{{0, 0, 1, 1}, ?BACKGROUND}],
                   copy => [{1, [{1, 0, 3, 1}]}],
                   push => [{0, 0, 1, 1}, {1, 0, 3, 1}]}, Plan).

an_unchanged_layout_plans_nothing_test() ->
    Screen = {0, 0, 4, 4},
    Layout = [window(1, {1, 1, 3, 3}, [{{1, 1, 3, 2}, 4}]), window(2, {0, 0, 4, 4}, [])],
    {ok, Plan, _} = erx_screen_core:layout(Layout, laid_out(Screen, [Layout])),
    ?assertEqual(#{fill => [], copy => [], push => []}, Plan).

%% The dirty list.

seventeenth_dirty_rectangle_yields_its_bounding_box_test() ->
    Sixteen = [{X, Y, X + 1, Y + 1} || X <- lists:seq(0, 3), Y <- lists:seq(0, 3)],
    Full = lists:foldl(fun erx_screen_core:add_dirty/2, [], Sixteen),
    ?assertEqual(lists:sort(Sixteen), lists:sort(Full)),
    ?assertEqual([{-2, 0, 4, 9}], erx_screen_core:add_dirty({-2, 8, -1, 9}, Full)),
    Again = erx_screen_core:add_dirty({7, 7, 8, 8}, [{-2, 0, 4, 9}]),
    ?assertEqual(lists:sort([{-2, 0, 4, 9}, {7, 7, 8, 8}]), lists:sort(Again)).

an_empty_dirty_rectangle_changes_nothing_test() ->
    ?assertEqual([], erx_screen_core:add_dirty({1, 1, 1, 5}, [])),
    ?assertEqual([{0, 0, 1, 1}], erx_screen_core:add_dirty({3, 2, 1, 5}, [{0, 0, 1, 1}])).

%% Malformed input.

malformed_input_is_refused_test() ->
    State = laid_out({0, 0, 4, 4}, [[]]),
    Refused = fun(Layout) -> erx_screen_core:layout(Layout, State) end,
    ?assertEqual({error, einval}, Refused([window(1, {0, 0, 1, 1}, []), window(1, {1, 1, 2, 2}, [])])),
    ?assertEqual({error, einval}, Refused([window(0, {0, 0, 1, 1}, [])])),
    ?assertEqual({error, einval}, Refused([window(1, {0, 0, 1}, [])])),
    ?assertEqual({error, einval}, Refused([window(1, {0, 0, 1, 16#80000000}, [])])),
    ?assertEqual({error, einval}, Refused([window(1, {0, 0, 1, 1}, [{{0, 0, 1, 1}, -1}])])),
    ?assertEqual({error, einval}, Refused([window(1, {0, 0, 1, 1}, [{0, 0, 1, 1}])])),
    ?assertEqual({error, einval}, Refused([#{id => 1, rect => {0, 0, 1, 1}}])),
    ?assertEqual({error, einval}, Refused(not_a_list)),
    ?assertEqual({error, einval}, erx_screen_core:present({1, self()}, {0, 0, 1, 1}, [{0, 0, a, 1}], State)),
    ?assertEqual({error, einval}, erx_screen_core:present({1, self()}, {0, 0, 1}, [], State)),
    ?assertEqual({error, einval}, erx_screen_core:present({1, self()}, {0, 0, 1, 1}, not_a_list, State)),
    ?assertEqual({error, einval}, erx_screen_core:new({0, 0, 0, 4}, ?BACKGROUND, true)),
    ?assertEqual({error, einval}, erx_screen_core:new({0, 0, 4, 4}, 16#100000000, true)).

extreme_coordinates_are_accepted_test() ->
    Edge = {-16#80000000, -16#80000000, 16#7fffffff, 16#7fffffff},
    State = laid_out({0, 0, 2, 2}, [[window(1, Edge, [])]]),
    ?assertEqual([{0, 0, 2, 2}], erx_screen_core:visible(1, State)),
    ?assertEqual({copy, [{0, 0, 2, 2}]}, erx_screen_core:present({1, self()}, Edge, [Edge], State)).

a_window_id_shown_again_by_another_process_is_copied_whole_test() ->
    Screen = {0, 0, 4, 4},
    Before = laid_out(Screen, [[window(1, {0, 0, 2, 2}, [])]]),
    Other = spawn(fun() -> ok end),
    {ok, Plan, _} = erx_screen_core:layout([#{id => 1, proc => Other, rect => {0, 0, 2, 2},
                                              decorations => []}], Before),
    ?assertEqual(#{fill => [], copy => [{1, [{0, 0, 2, 2}]}], push => [{0, 0, 2, 2}]}, Plan).

more_than_sixteen_dirty_rectangles_are_refused_test() ->
    State = laid_out({0, 0, 4, 4}, [[window(1, {0, 0, 4, 4}, [])]]),
    Rects = fun(N) -> lists:duplicate(N, {0, 0, 1, 1}) end,
    ?assertMatch({direct, [_ | _]}, erx_screen_core:present({1, self()}, {0, 0, 4, 4}, Rects(16), State)),
    ?assertEqual({error, einval}, erx_screen_core:present({1, self()}, {0, 0, 4, 4}, Rects(17), State)).

improper_lists_are_refused_test() ->
    State = laid_out({0, 0, 4, 4}, [[]]),
    W = window(1, {0, 0, 1, 1}, []),
    ?assertEqual({error, einval}, erx_screen_core:layout([W | x], State)),
    ?assertEqual({error, einval}, erx_screen_core:layout([W#{decorations := [{{0, 0, 1, 1}, 1} | x]}], State)),
    ?assertEqual({error, einval}, erx_screen_core:layout([maps:remove(proc, W)], State)),
    ?assertEqual({error, einval}, erx_screen_core:present({1, self()}, {0, 0, 1, 1}, [{0, 0, 1, 1} | x], State)).

a_malformed_dirty_rectangle_fails_its_window_test() ->
    ?assertError(_, erx_screen_core:add_dirty({0, 0, a, 1}, [])),
    ?assertError(_, erx_screen_core:add_dirty({0, 0, 1}, [])).

%% Cost: a weave of 64 windows, half tall and half wide, each with a border
%% of four rectangles, has thousands of tiles; moving one window must not
%% compare every tile with every other. The bound is generous, so a slow host
%% passes, and a comparison of tiles by pairs, about a thousand times the
%% work, does not.
a_layout_change_costs_little_over_a_weave_test_() ->
    {timeout, ?EXHAUSTIVE_SECONDS,
     fun() ->
             Screen = {0, 0, 2048, 2048},
             Weave = fun(Shift) -> [woven(I, Shift) || I <- lists:seq(1, 64)] end,
             Before = laid_out(Screen, [Weave(0)]),
             {Micros, {ok, #{copy := Copies}, _}} =
                 timer:tc(erx_screen_core, layout, [Weave(1), Before]),
             ?assertMatch([_ | _], Copies),
             ?assert(Micros < 2000000)
     end}.

woven(I, Shift) when I =< 32 ->
    bordered(I, {I * 60 + Shift, 0, I * 60 + 20 + Shift, 2048});
woven(I, _) ->
    bordered(I, {0, (I - 32) * 60, 2048, (I - 32) * 60 + 20}).

bordered(Id, {X0, Y0, X1, Y1} = R) ->
    window(Id, R, [{{X0, Y0, X1, Y0 + 2}, 3}, {{X0, Y1 - 2, X1, Y1}, 3},
                   {{X0, Y0, X0 + 2, Y1}, 3}, {{X1 - 2, Y0, X1, Y1}, 3}]).

%% Layouts over a 3-by-1 strip, where one band holds changed runs with an
%% unchanged run between them: none, one or two windows of any rectangle on
%% the strip, each undecorated or with a pixel of decoration at both ends in
%% one of two colours, so a recoloured border changes at both ends and not
%% between.
strip_layouts() ->
    Rects = rects([0, 1, 2, 3], [0, 1]),
    Window = fun(Id, R) -> [window(Id, R, D) || D <- strip_decorations(R)] end,
    [[]]
        ++ [[W] || Id <- [1, 2], R <- Rects, W <- Window(Id, R)]
        ++ [[WA, WB] || {A, B} <- [{1, 2}, {2, 1}], RA <- Rects, RB <- Rects,
                        WA <- Window(A, RA), WB <- Window(B, RB)].

strip_decorations({X0, Y0, X1, Y1}) ->
    [[] | [[{{X0, Y0, X0 + 1, Y1}, C}, {{X1 - 1, Y0, X1, Y1}, C}] || C <- [1, 2]]].

layout_changes_on_a_strip_copy_and_fill_exactly_what_changed_test_() ->
    {timeout, ?EXHAUSTIVE_SECONDS,
     fun() ->
             Screen = {0, 0, 3, 1},
             Layouts = strip_layouts(),
             lists:foreach(fun(Old) ->
                                   Before = laid_out(Screen, [Old]),
                                   [check_change(Screen, Old, Before, New) || New <- Layouts]
                           end, Layouts)
     end}.

closing_a_window_behind_another_fills_only_what_it_showed_test() ->
    Screen = {0, 0, 10, 1},
    Before = laid_out(Screen, [[window(1, {3, 0, 6, 1}, []), window(2, {0, 0, 10, 1}, [])]]),
    {ok, Plan, _} = erx_screen_core:layout([window(1, {3, 0, 6, 1}, [])], Before),
    ?assertEqual(#{fill => [{{0, 0, 3, 1}, ?BACKGROUND}, {{6, 0, 10, 1}, ?BACKGROUND}],
                   copy => [],
                   push => [{0, 0, 3, 1}, {6, 0, 10, 1}]}, Plan).

recolouring_a_border_fills_only_the_border_test() ->
    Screen = {0, 0, 10, 1},
    Border = fun(C) -> [window(1, Screen, [{{0, 0, 1, 1}, C}, {{9, 0, 10, 1}, C}])] end,
    {ok, Plan, _} = erx_screen_core:layout(Border(6), laid_out(Screen, [Border(5)])),
    ?assertEqual(#{fill => [{{0, 0, 1, 1}, 6}, {{9, 0, 10, 1}, 6}],
                   copy => [],
                   push => [{0, 0, 1, 1}, {9, 0, 10, 1}]}, Plan).

a_present_by_another_process_of_the_same_id_copies_nothing_test() ->
    Screen = {0, 0, 4, 4},
    Other = spawn(fun() -> ok end),
    Compose = laid_out(Screen, [[window(1, {0, 0, 2, 2}, [])]]),
    Direct = laid_out(Screen, [[window(1, Screen, [])]]),
    ?assertEqual({copy, []}, erx_screen_core:present({1, Other}, Screen, [Screen], Compose)),
    ?assertEqual({copy, []}, erx_screen_core:present({1, Other}, Screen, [Screen], Direct)),
    ?assertEqual({direct, [Screen]}, erx_screen_core:present({1, self()}, Screen, [Screen], Direct)),
    ?assertEqual({error, einval}, erx_screen_core:present({1, not_a_pid}, Screen, [], Compose)),
    ?assertEqual({error, einval}, erx_screen_core:present(1, Screen, [], Compose)).
