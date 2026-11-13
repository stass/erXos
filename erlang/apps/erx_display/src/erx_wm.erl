%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wm).
-moduledoc """
The window policy behaviour (docs/design-display.md, "Windows and the
window system"): the pure module erx_winfs asks every question of
geometry and input. A policy decides where windows go, which are shown,
how they are framed and which window an input event reaches; erx_winfs
keeps the window table and applies the answers. erx_wm_single, the
kiosk's, is the policy built so far; the overlapping one, erx_wm_rio,
comes with the desktop.

The table is a list of windows in stacking order, the topmost first.
A policy reads a window's `id`, `dir`, `rect` and `state`, sets `rect`
and `state`, may reorder the list, and keeps every other field as it
found it.

A policy's own state, from init/1, is threaded by erx_winfs through
place/6, arrange/4 and input/4, which also take
`Session`, the directory of the display's session or `none`, which
erx_winfs derives at the call from its grants: the live grant most
recently minted with `session` set. The configuration names no session. Every policy keeps the reserved chord's state,
chord_init/1 and chord/2: it answers the chord with `{wm, chord}` and
delivers it to no window.

Callbacks:

* init(Config) builds the policy's state from the manifest's
  configuration.
* place(Request, Window, Windows, Screen, Session, State) answers a geometry
  request about `Window`: `new` when erx_winfs has just added it to the
  table (its `rect` and `state` are the policy's to set), or a `wctl`
  command (erx_wctl:parse/1). It returns the whole new table, or
  `{error, einval}` for a request the policy refuses.
* arrange(Windows, Screen, Session, State) sets every window's `rect` and
  `state` after a change erx_winfs makes itself: a window ended or the
  screen's size changed.
* decorate(Windows, Screen) returns each shown window's decoration as
  rectangles and colours, or none.
* input(Input, Windows, Session, State) routes one input event: to one window,
  to the window system itself (`{wm, Term}`, such as a menu request),
  as a rearranged table (`{windows, Table}`, such as a click that
  raises a window), or nowhere.

Every rectangle a policy returns lies within the screen, within/2.
""".

-export([within/2, shown/1, fetch/2, session/1, chord_init/1, chord/2]).
-export_type([window_id/0, coord/0, rect/0, color/0, window/0, request/0,
              input/0, route/0, chord/0, session/0]).

-doc "A window's number, unique within a display.".
-type window_id() :: 1..16#7fffffff.
-doc "draw(3)'s 32-bit coordinate.".
-type coord() :: -16#80000000..16#7fffffff.
-doc "A half-open rectangle `{X0, Y0, X1, Y1}`, as Plan 9's.".
-type rect() :: {X0 :: coord(), Y0 :: coord(), X1 :: coord(), Y1 :: coord()}.
-doc "draw(3)'s RGBA colour.".
-type color() :: 0..16#ffffffff.
-doc """
A row of erx_winfs's window table. The policy reads and sets only the
fields named here; erx_winfs's other fields pass through unchanged.
""".
-type window() :: #{id := window_id(),
                    dir := {Session :: binary(), Name :: binary()},
                    rect := rect(),
                    state := shown | hidden,
                    atom() => term()}.
-doc "What erx_winfs asks of place/6.".
-type request() :: new | erx_wctl:command().
-doc "The directory of the display's session, or `none` while it has none.".
-type session() :: binary() | none.
-doc "One input event, from any input driver.".
-type input() :: #{device := binary(),
                   at := integer(),
                   event := {pointer, X :: coord(), Y :: coord(), Buttons :: 0..255}
                          | {touch, Slot :: 0..9, down | move | up,
                             X :: coord(), Y :: coord()}
                          | {key, down | up, Code :: 0..16#ffff,
                             Rune :: 0..16#d7ff | 16#e000..16#10ffff | none}
                          | {wheel, Steps :: -128..127}}.
-doc "Where input/3 sends an event.".
-type route() :: {to, window_id(), input()} | {wm, term()}
               | {windows, [window()]} | drop.
-doc """
The reserved chord's state: its keys, or `none` when the manifest names
no chord; the keys held down; and the keys whose down completed the
chord, withheld until their up.
""".
-opaque chord() :: #{keys := ordsets:ordset(0..16#ffff) | none,
                     down := ordsets:ordset(0..16#ffff),
                     withheld := ordsets:ordset(0..16#ffff)}.

-callback init(Config :: map()) -> State :: term().
-callback place(request(), window_id(), Windows :: [window()], Screen :: rect(),
                Session :: session(), State :: term()) ->
    {ok, [window()], State :: term()} | {error, einval}.
-callback arrange(Windows :: [window()], Screen :: rect(), Session :: session(),
                  State :: term()) ->
    {[window()], State :: term()}.
-callback decorate(Windows :: [window()], Screen :: rect()) ->
    [{window_id(), [{rect(), color()}]}].
-callback input(input(), Windows :: [window()], Session :: session(), State :: term()) ->
    {route(), State :: term()}.

-doc "Whether rectangle `Inner` is non-empty and lies within `Outer`.".
-spec within(rect(), rect()) -> boolean().
within({X0, Y0, X1, Y1}, {SX0, SY0, SX1, SY1}) ->
    X0 < X1 andalso Y0 < Y1 andalso
        X0 >= SX0 andalso Y0 >= SY0 andalso X1 =< SX1 andalso Y1 =< SY1.

-doc "The shown windows, topmost first.".
-spec shown([window()]) -> [window()].
shown(Windows) -> [W || W = #{state := shown} <- Windows].

-doc "The window with id `Id`, or `error` when the table has none.".
-spec fetch(window_id(), [window()]) -> {ok, window()} | error.
fetch(Id, Windows) ->
    case [W || W = #{id := Found} <- Windows, Found =:= Id] of
        [W] -> {ok, W};
        _ -> error
    end.

-doc "The session a window belongs to.".
-spec session(window()) -> binary().
session(#{dir := {Session, _}}) -> Session.

-doc """
The reserved chord's state from a policy's configuration: `chord`, when
present, is a non-empty list of key codes; anything else raises
`badarg`.
""".
-spec chord_init(map()) -> chord().
chord_init(#{chord := Keys = [_ | _]}) ->
    case lists:all(fun(Code) -> is_integer(Code) andalso Code >= 0
                                    andalso Code =< 16#ffff end, Keys) of
        true -> #{keys => ordsets:from_list(Keys), down => [], withheld => []};
        false -> error(badarg, [Keys])
    end;
chord_init(#{chord := Keys}) ->
    error(badarg, [Keys]);
chord_init(#{}) ->
    #{keys => none, down => [], withheld => []}.

-doc """
Tracks one input event against the reserved chord. The chord fires on
the key down of a chord key not yet held that makes the keys held
include every chord key, whatever other keys are held, so a stuck or
extra key neither disables the chord nor lets it through to a window.
That down answers `chord`, and its repeats and its up answer
`withheld`, so holding the chord while a driver repeats keys fires it
once. Every other event, the chord's other keys included, answers
`pass` and is the policy's to route.
""".
-spec chord(input(), chord()) -> {chord | withheld | pass, chord()}.
chord(#{event := {key, down, Code, _}}, Chord = #{keys := Keys, down := Down,
                                                  withheld := Withheld}) ->
    Held = ordsets:add_element(Code, Down),
    Next = Chord#{down := Held},
    NewlyHeld = not ordsets:is_element(Code, Down),
    Completes = Keys =/= none andalso NewlyHeld andalso ordsets:is_element(Code, Keys)
        andalso ordsets:is_subset(Keys, Held),
    case {ordsets:is_element(Code, Withheld), Completes} of
        {true, _} -> {withheld, Next};
        {false, true} -> {chord, Next#{withheld := ordsets:add_element(Code, Withheld)}};
        {false, false} -> {pass, Next}
    end;
chord(#{event := {key, up, Code, _}}, Chord = #{down := Down, withheld := Withheld}) ->
    Next = Chord#{down := ordsets:del_element(Code, Down),
                  withheld := ordsets:del_element(Code, Withheld)},
    case ordsets:is_element(Code, Withheld) of
        true -> {withheld, Next};
        false -> {pass, Next}
    end;
chord(_Input, Chord) ->
    {pass, Chord}.
