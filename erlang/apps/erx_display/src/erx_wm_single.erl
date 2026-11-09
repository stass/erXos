%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wm_single).
-moduledoc """
The single window policy of a kiosk, a dashboard or a pair of glasses
(docs/design-display.md, "Windows and the window system"): one window
is shown, it has the whole screen and no decoration, and every input
event but the reserved chord goes to it.

Configuration, from the manifest: `app`, the session directory of the
application domain whose window takes the screen, and optionally
`chord`, the reserved chord's key codes (erx_wm:chord_init/1).

Which window is shown is derived, never stored: it is the live window
of the `app` session with the lowest id, shown/2, computed afresh from
every table erx_winfs hands the policy. A window is matched by its
session, since a window's name is its client's choice. Every other
window, a later one of the same session or one of any other session, is
hidden. With no live window of the session, none is shown and input is
dropped.

Placement. `new` gives every window the screen's rectangle and sets
each window's state from shown/2. Every `wctl` request is refused with
`einval`, so no window takes the screen by asking.

Input. The reserved chord is answered with `{wm, chord}` and its
repeats and its key up are dropped (erx_wm:chord/2); every other event
goes to the shown window.
""".

-behaviour(erx_wm).

-export([init/1, place/5, decorate/2, input/3, shown/2]).
-export_type([config/0, state/0]).

-doc "The manifest's configuration of the policy.".
-type config() :: #{app := binary(), chord => [0..16#ffff, ...]}.
-doc "The policy's state, threaded by erx_winfs.".
-type state() :: #{app := binary(), chord := erx_wm:chord()}.

-doc "The policy's state from its configuration; a bad one raises `badarg`.".
-spec init(config()) -> state().
init(Config = #{app := App}) when is_binary(App) ->
    #{app => App, chord => erx_wm:chord_init(Config)};
init(Config) ->
    error(badarg, [Config]).

-doc """
Answers a geometry request: `new` arranges the table, and every `wctl`
request is refused.
""".
-spec place(erx_wm:request(), erx_wm:window_id(), [erx_wm:window()],
            erx_wm:rect(), state()) ->
          {ok, [erx_wm:window()], state()} | {error, einval}.
place(new, Id, Windows, Screen = {X0, Y0, X1, Y1}, State = #{app := App})
  when X0 < X1, Y0 < Y1 ->
    case erx_wm:fetch(Id, Windows) of
        {ok, _} ->
            ShownId = shown(App, Windows),
            {ok, [W#{rect := Screen,
                     state := case WindowId of ShownId -> shown; _ -> hidden end}
                  || W = #{id := WindowId} <- Windows], State};
        error ->
            {error, einval}
    end;
place(_Request, _Id, _Windows, _Screen, _State) ->
    {error, einval}.

-doc "The single policy draws nothing.".
-spec decorate([erx_wm:window()], erx_wm:rect()) -> [].
decorate(_Windows, _Screen) -> [].

-doc "Routes one input event; see the moduledoc.".
-spec input(erx_wm:input(), [erx_wm:window()], state()) ->
          {erx_wm:route(), state()}.
input(Input, Windows, State = #{app := App, chord := Chord}) ->
    {Seen, Next} = erx_wm:chord(Input, Chord),
    Route = case {Seen, shown(App, Windows)} of
                {chord, _} -> {wm, chord};
                {withheld, _} -> drop;
                {pass, none} -> drop;
                {pass, Id} -> {to, Id, Input}
            end,
    {Route, State#{chord := Next}}.

-doc """
The window the policy shows: the live window of session `App` with the
lowest id, or `none` when the session has no window in the table.
""".
-spec shown(binary(), [erx_wm:window()]) -> erx_wm:window_id() | none.
shown(App, Windows) ->
    case [Id || W = #{id := Id} <- Windows, erx_wm:session(W) =:= App] of
        [] -> none;
        Ids -> lists:min(Ids)
    end.
