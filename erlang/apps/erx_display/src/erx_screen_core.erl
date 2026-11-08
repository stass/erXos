%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_screen_core).
-moduledoc """
The decisions of `erx_screen`, the one writer of the screen image
(docs/design-display.md, "The screen and its one path to the device").

A **layout** is the list of shown windows, topmost first, that `erx_winfs`
hands `erx_screen` after every change of its table: each window's id, its
window process, its rectangle on the screen and its decorations from the
policy's `decorate/2`. From a layout the core **tiles** the screen: it cuts
the screen into disjoint rectangles, each with the one source its pixels come
from, a window's image, a decoration's colour or the background's colour. A
window's decorations lie over its own image, later decorations over earlier
ones, and the whole window, decorations included, lies over every window
below it. A window's **visible region** is the set of its tiles.

Everything here is in screen coordinates, rectangles half-open as Plan 9's.
`erx_screen` places a window's image on the screen; the core needs only the
image's rectangle as placed there.

Three calls carry the decisions out:

* `layout/2` takes a new layout and returns its plan: the decoration and
  background rectangles to fill and push, and the area of each window to
  expose, which the window's answering flush pushes. A pixel is filled or
  exposed only when what it shows changes: two fills of one colour show the
  same thing, and a window shows the same thing only from the same window
  process at the same origin, since a moved window shows other pixels of its
  image there and a restarted one another image. Keying a window by its
  process, not only its id, keeps a reused id from passing for the window
  that had it.
* `repaint/1` is the plan of the current layout over a screen whose contents
  are unknown, which follows a driver's restart, a wake and `erx_screen`'s
  own restart: every fill, every visible region exposed whole.
* `flush/4` is the plan of a window's flush: the rectangles to copy from its
  image into the screen image and push, or in direct mode the rectangles to
  push from its image itself. Overlapping dirty rectangles give overlapping
  copies, which write the same pixels twice, as Plan 9's do.

**Direct mode.** A layout of exactly one window whose rectangle is the
screen's, no larger, and which has no decorations composes nothing: the
window's flushes are pushed from its own image. The screen image then holds
none of the window's pixels, so the layout after direct mode treats the
screen image as unknown, and a composing layout fills and exposes
everything. Entering direct mode compares with what the device shows, the
screen image, so `erx_screen` pushes every rectangle it still owes the
driver before it enters.

`add_dirty/2` keeps a window's dirty list of at most 16 rectangles, which a
seventeenth replaces by the bounding box of all of them, as Plan 9's
`flushimage` does with one; `flush/4` refuses a longer list.

**Cost.** The tiling works in **bands**: the horizontal edges of the screen
and of every window and decoration rectangle cut the screen into bands, and
within a band a sweep from left to right over the rectangles that cross it
gives its runs, each with the topmost source over it. A layout of L
rectangles has at most 2L + 1 bands of at most 2L + 1 runs, so tiling costs
O(L^2 log L), and comparing two tilings walks both band lists together, in
time linear in their runs. L counts the windows of every grant on the
display and their decorations, so no one client's quota bounds it, and the
work runs in `erx_screen`, not in a client's window processes
(docs/design-display.md, G3; TODO.md records the residual).

Input is checked whole before anything is decided: a malformed layout or
rectangle, a coordinate outside draw(3)'s 32 bits, or more than 16 dirty
rectangles is refused with `{error, einval}`.
""".

-export([new/2, layout/2, repaint/1, flush/4, visible/2, tiles/1, mode/1,
         add_dirty/2]).
-export_type([rect/0, color/0, window_id/0, entry/0, layout/0, source/0,
              tile/0, mode/0, plan/0, state/0]).

-define(COORD_MIN, -16#80000000).
-define(COORD_MAX, 16#7fffffff).
-define(DIRTY_MAX, 16).

-type coord() :: ?COORD_MIN..?COORD_MAX.
-type rect() :: {X0 :: coord(), Y0 :: coord(), X1 :: coord(), Y1 :: coord()}.
-type color() :: 0..16#ffffffff.
-type window_id() :: 1..16#7fffffff.
%% One shown window of a layout; erx_screen's other keys are carried and
%% ignored.
-type entry() :: #{id := window_id(), proc := pid(), rect := rect(),
                   decorations := [{rect(), color()}], _ => _}.
%% The shown windows, topmost first.
-type layout() :: [entry()].
%% Where a tile's pixels come from. A window's source carries its process and
%% the origin of its rectangle, the top-left corner its image is placed at.
-type source() :: {window, window_id(), pid(), {coord(), coord()}}
                | {decoration, window_id(), color()}
                | {background, color()}.
-type tile() :: {rect(), source()}.
%% A band: a horizontal strip of the screen and its runs, disjoint, sorted by
%% X0. The type is named strip because band is an Erlang operator.
-type strip() :: {Y0 :: coord(), Y1 :: coord(), [run()]}.
-type run() :: {X0 :: coord(), X1 :: coord(), source()}.
-type mode() :: compose | {direct, window_id()}.
-type plan() :: #{fill := [{rect(), color()}],
                  expose := [{window_id(), [rect()]}],
                  push := [rect()]}.

-record(screen, {rect :: rect(),
                 background :: color(),
                 layout = [] :: layout(),
                 mode = compose :: mode(),
                 %% The tiling of the layout, as the screen will show it once
                 %% the last plan is carried out; unknown before the first.
                 bands = unknown :: unknown | [strip()],
                 tiles = [] :: [tile()],
                 %% Each shown window's process and visible region.
                 visible = #{} :: #{window_id() => {pid(), [rect()]}}}).
-opaque state() :: #screen{}.

-doc """
The state of a screen of rectangle `Screen` and background colour
`Background`, with no window shown and its contents unknown, so that the
first layout fills and exposes everything.
""".
-spec new(rect(), color()) -> {ok, state()} | {error, einval}.
new(Screen, Background) ->
    case is_rect(Screen) andalso not is_empty(Screen) andalso
        is_color(Background) of
        true -> {ok, #screen{rect = Screen, background = Background}};
        false -> {error, einval}
    end.

-doc """
Takes `Layout`, the shown windows topmost first, and returns the plan that
brings the screen from the old layout to it: the fills, the exposes and the
pushes.
""".
-spec layout(layout(), state()) -> {ok, plan(), state()} | {error, einval}.
layout(Layout, #screen{} = Screen) ->
    case is_layout(Layout) of
        true ->
            {Plan, New} = arrange(Layout, known(Layout, Screen), Screen),
            {ok, Plan, New};
        false ->
            {error, einval}
    end.

-doc """
The plan of the current layout over a screen whose contents are unknown:
every decoration and the background filled, and every visible region
exposed whole.
""".
-spec repaint(state()) -> {plan(), state()}.
repaint(#screen{layout = Layout} = Screen) ->
    arrange(Layout, unknown, Screen).

-doc """
The plan of a flush of window `Id` by its process `Proc`, whose image lies
at `Bounds` on the
screen, with at most 16 dirty rectangles `Rects` in screen coordinates.
`{copy, Rs}`: copy `Rs` from the window's image into the screen image, then
push them; they are the dirty rectangles clipped to the image and to the
window's visible region, and empty for a window the layout does not show,
or shows from another process. `{direct, Rs}`, in direct mode: push `Rs`
straight from the window's image; its visible region is the screen.
""".
-spec flush({window_id(), pid()}, rect(), [rect()], state()) ->
          {copy | direct, [rect()]} | {error, einval}.
flush({Id, Proc}, Bounds, Rects, #screen{} = Screen) when is_pid(Proc) ->
    case is_rect(Bounds) andalso every(fun is_rect/1, Rects) andalso
        length(Rects) =< ?DIRTY_MAX of
        true -> flush_plan(Id, Proc, [intersect(R, Bounds) || R <- Rects], Screen);
        false -> {error, einval}
    end;
flush(_, _, _, #screen{}) ->
    {error, einval}.

flush_plan(Id, Proc, Rects, #screen{mode = Mode, visible = Visible}) ->
    case Visible of
        #{Id := {Proc, Region}} ->
            {pushed_from(Id, Mode), [Piece || Part <- Region,
                                              Piece <- clip_region(Rects, Part)]};
        #{} ->
            {copy, []}
    end.

pushed_from(Id, {direct, Id}) -> direct;
pushed_from(_, _) -> copy.

-doc "The visible region of window `Id`: its disjoint tiles' rectangles.".
-spec visible(window_id(), state()) -> [rect()].
visible(Id, #screen{visible = Visible}) ->
    case Visible of
        #{Id := {_, Region}} -> Region;
        #{} -> []
    end.

-doc """
The tiling of the screen by the current layout: disjoint rectangles that
cover the screen, each with its source; `unknown` before the first layout.
""".
-spec tiles(state()) -> unknown | [tile()].
tiles(#screen{bands = unknown}) -> unknown;
tiles(#screen{tiles = Tiles}) -> Tiles.

-doc "Whether the current layout composes or is in direct mode.".
-spec mode(state()) -> mode().
mode(#screen{mode = Mode}) -> Mode.

-doc """
Adds `Rect`, a rectangle the window decoded, to its dirty list, which holds
at most 16 rectangles: a seventeenth replaces the list by the bounding box of
all seventeen. An empty rectangle changes nothing.
""".
-spec add_dirty(rect(), [rect()]) -> [rect()].
add_dirty({_, _, _, _} = Rect, Dirty) when is_list(Dirty) ->
    true = is_rect(Rect),
    case is_empty(Rect) of
        true -> Dirty;
        false when length(Dirty) < ?DIRTY_MAX -> [Rect | Dirty];
        false -> [lists:foldl(fun bounding_box/2, Rect, Dirty)]
    end.

%% The plan and state of Layout over a screen that holds Known, the bands it
%% shows, or unknown.
arrange(Layout, Known, #screen{rect = Rect, background = Background} = Screen) ->
    Bands = bands(Rect, Background, Layout),
    Tiles = rects_of(Bands),
    Changed = rects_of(changed(Known, Bands)),
    Fills = [{R, Color} || {R, Source} <- Changed, {fill, Color} <- [content(Source)]],
    Plan = #{fill => Fills,
             expose => by_window(Layout, Changed),
             push => [R || {R, _} <- Fills]},
    {Plan, Screen#screen{layout = Layout, mode = mode_of(Rect, Layout),
                         bands = Bands, tiles = Tiles,
                         visible = visible_regions(Layout, Tiles)}}.

%% Each shown window's process and visible region, by window id.
visible_regions(Layout, Tiles) ->
    Procs = maps:from_list([{Id, Proc} || #{id := Id, proc := Proc} <- Layout]),
    maps:from_list([{Id, {maps:get(Id, Procs), Region}}
                    || {Id, Region} <- by_window(Layout, Tiles)]).

%% What the screen shows before Layout takes effect, as the new layout's
%% mode sees it: leaving direct mode for a composing layout finds a screen
%% image that holds none of the direct window's pixels.
known(Layout, #screen{rect = Rect, mode = Old, bands = Bands}) ->
    case {Old, mode_of(Rect, Layout)} of
        {{direct, _}, compose} -> unknown;
        _ -> Bands
    end.

mode_of(Screen, [#{id := Id, rect := Screen, decorations := []}]) -> {direct, Id};
mode_of(_, _) -> compose.

%% The rectangles of Tiles that come from each window of Layout, in layout
%% order, for the windows with any.
by_window(Layout, Tiles) ->
    Areas = lists:foldl(fun({R, {window, Id, _, _}}, Acc) ->
                                maps:update_with(Id, fun(Rs) -> [R | Rs] end, [R], Acc);
                           (_, Acc) ->
                                Acc
                        end, #{}, Tiles),
    [{Id, lists:reverse(maps:get(Id, Areas))} || #{id := Id} <- Layout,
                                                is_map_key(Id, Areas)].

%% Tiling.

%% The bands of Screen under Layout. Every layer is clipped to the screen and
%% numbered by depth, 1 topmost; the horizontal edges of the screen and the
%% layers cut the screen into bands, and a layer crosses a band whole or not
%% at all.
bands({_, SY0, _, SY1} = Screen, Background, Layout) ->
    Clipped = [{intersect(Rect, Screen), Source}
               || {Rect, Source} <- lists:flatmap(fun layers/1, Layout)],
    Layers = lists:enumerate([L || {R, _} = L <- Clipped, not is_empty(R)]),
    Edges = lists:usort([SY0, SY1 | [Y || {_, {{_, Y0, _, Y1}, _}} <- Layers, Y <- [Y0, Y1]]]),
    [{Y0, Y1, runs(Screen, Background, crossing(Y0, Y1, Layers))}
     || {Y0, Y1} <- lists:zip(lists:droplast(Edges), tl(Edges))].

%% The layers that cross the band from Y0 to Y1, as {Depth, X0, X1, Source}.
crossing(Y0, Y1, Layers) ->
    [{Depth, X0, X1, Source} || {Depth, {{X0, LY0, X1, LY1}, Source}} <- Layers,
                                LY0 =< Y0, LY1 >= Y1].

%% A window's layers, topmost first: its decorations, the last over the
%% others, then its image.
layers(#{id := Id, proc := Proc, rect := {X0, Y0, _, _} = Rect,
         decorations := Decorations}) ->
    [{R, {decoration, Id, Color}} || {R, Color} <- lists:reverse(Decorations)]
        ++ [{Rect, {window, Id, Proc, {X0, Y0}}}].

%% The runs of one band: a sweep from the screen's left edge to its right
%% over the layers crossing the band, keeping those open at the sweep's
%% position by depth, so the topmost is the smallest. Every edge at one x is
%% applied before the run from there is emitted, so their order does not
%% matter, and a layer never opens and closes at one x, being nonempty.
runs({SX0, _, SX1, _}, Background, Crossing) ->
    Edges = lists:sort([{X0, open, Depth, Source} || {Depth, X0, _, Source} <- Crossing]
                       ++ [{X1, close, Depth, Source} || {Depth, _, X1, Source} <- Crossing]),
    merge_runs(sweep(Edges, SX0, SX1, gb_trees:empty(), Background)).

sweep(Edges, X, End, Open, Background) when X < End ->
    {Here, Later} = lists:splitwith(fun({EX, _, _, _}) -> EX =:= X end, Edges),
    Now = lists:foldl(fun({_, open, Depth, Source}, T) -> gb_trees:insert(Depth, Source, T);
                         ({_, close, Depth, _}, T) -> gb_trees:delete(Depth, T)
                      end, Open, Here),
    Next = case Later of
               [{NX, _, _, _} | _] -> NX;
               [] -> End
           end,
    [{X, Next, topmost(Now, Background)} | sweep(Later, Next, End, Now, Background)];
sweep(_, _, _, _, _) ->
    [].

topmost(Open, Background) ->
    case gb_trees:is_empty(Open) of
        true -> {background, Background};
        false -> element(2, gb_trees:smallest(Open))
    end.

%% Runs of one source joined where one ends at the next one's start. A
%% band's changed runs have gaps between them, which no join may cross.
merge_runs([{X0, X, Source}, {X, X1, Source} | Rest]) ->
    merge_runs([{X0, X1, Source} | Rest]);
merge_runs([Run | Rest]) ->
    [Run | merge_runs(Rest)];
merge_runs([]) ->
    [].

%% The runs of bands as rectangles, a run continued by the same run in the
%% band below it joined into one. The bands are contiguous, top to bottom,
%% as bands/3 and differ_bands/2 make them. Open maps each run of the last
%% band to the top of the rectangle it continues; Bottom is that band's
%% bottom edge.
rects_of(Bands) ->
    {Done, Open, Bottom} = lists:foldl(fun extend/2, {[], #{}, none}, Bands),
    lists:sort(close_all(Open, Bottom, Done)).

extend({Y0, Y1, Runs}, {Done, Open, Bottom}) when Bottom =:= none; Bottom =:= Y0 ->
    Carried = maps:with(Runs, Open),
    Ended = maps:without(Runs, Open),
    Next = maps:merge(maps:from_list([{Run, Y0} || Run <- Runs]), Carried),
    {close_all(Ended, Bottom, Done), Next, Y1}.

close_all(Open, Bottom, Done) ->
    [{{X0, Top, X1, Bottom}, Source} || {{X0, X1, Source}, Top} <- maps:to_list(Open)] ++ Done.

%% Comparing tilings.

%% The parts of the new bands whose content differs from what Known shows
%% there, as bands. Both tilings cover the same screen, so their band lists
%% start together and walk together: each step takes the overlap of the two
%% first bands, compares its runs, and keeps the rest of the taller band.
changed(unknown, Bands) ->
    Bands;
changed(Known, Bands) ->
    differ_bands(Known, Bands).

differ_bands([{Y0, OY1, OldRuns} | OldRest], [{Y0, NY1, NewRuns} | NewRest]) ->
    Y1 = min(OY1, NY1),
    [{Y0, Y1, merge_runs(differ_runs(OldRuns, NewRuns))}
     | differ_bands(rest_band(Y1, OY1, OldRuns, OldRest),
                    rest_band(Y1, NY1, NewRuns, NewRest))];
differ_bands([], []) ->
    [].

rest_band(Y1, Y1, _, Rest) -> Rest;
rest_band(Y1, BandY1, Runs, Rest) -> [{Y1, BandY1, Runs} | Rest].

%% The new runs' parts whose content differs from the old runs' at the same
%% place; both lists cover the band, so they start together and walk together.
differ_runs([{X0, OX1, Old} | OldRest], [{X0, NX1, New} | NewRest]) ->
    X1 = min(OX1, NX1),
    Here = case content(Old) =:= content(New) of
               true -> [];
               false -> [{X0, X1, New}]
           end,
    Here ++ differ_runs(rest_run(X1, OX1, Old, OldRest),
                        rest_run(X1, NX1, New, NewRest));
differ_runs([], []) ->
    [].

rest_run(X1, X1, _, Rest) -> Rest;
rest_run(X1, RunX1, Source, Rest) -> [{X1, RunX1, Source} | Rest].

%% What a source puts on the screen: a decoration and the background of one
%% colour show the same pixels.
content({window, _, _, _} = Source) -> Source;
content({decoration, _, Color}) -> {fill, Color};
content({background, Color}) -> {fill, Color}.

%% Rectangle arithmetic. A rectangle is half-open; one with X0 >= X1 or
%% Y0 >= Y1 is empty.

is_empty({X0, Y0, X1, Y1}) -> X0 >= X1 orelse Y0 >= Y1.

intersect({AX0, AY0, AX1, AY1}, {BX0, BY0, BX1, BY1}) ->
    {max(AX0, BX0), max(AY0, BY0), min(AX1, BX1), min(AY1, BY1)}.

bounding_box({AX0, AY0, AX1, AY1}, {BX0, BY0, BX1, BY1}) ->
    {min(AX0, BX0), min(AY0, BY0), max(AX1, BX1), max(AY1, BY1)}.

%% The nonempty parts of Rects inside Rect.
clip_region(Rects, Rect) ->
    [Part || R <- Rects, Part <- [intersect(R, Rect)], not is_empty(Part)].

%% Input checks.

is_layout(Layout) ->
    every(fun is_entry/1, Layout) andalso
        begin
            Ids = [Id || #{id := Id} <- Layout],
            length(lists:usort(Ids)) =:= length(Ids)
        end.

is_entry(#{id := Id, proc := Proc, rect := Rect, decorations := Decorations})
  when is_integer(Id), Id >= 1, Id =< 16#7fffffff, is_pid(Proc) ->
    is_rect(Rect) andalso every(fun is_decoration/1, Decorations);
is_entry(_) ->
    false.

is_decoration({Rect, Color}) -> is_rect(Rect) andalso is_color(Color);
is_decoration(_) -> false.

is_rect({X0, Y0, X1, Y1}) ->
    is_coord(X0) andalso is_coord(Y0) andalso is_coord(X1) andalso is_coord(Y1);
is_rect(_) ->
    false.

is_coord(C) -> is_integer(C) andalso C >= ?COORD_MIN andalso C =< ?COORD_MAX.

is_color(C) -> is_integer(C) andalso C >= 0 andalso C =< 16#ffffffff.

%% Whether List is a proper list whose every element satisfies Pred.
every(Pred, [H | T]) -> Pred(H) andalso every(Pred, T);
every(_, []) -> true;
every(_, _) -> false.
