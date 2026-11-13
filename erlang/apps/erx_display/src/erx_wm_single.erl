%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_wm_single).
-moduledoc """
The single window policy of a kiosk, a dashboard or a pair of glasses
(docs/design-display.md, "Windows and the window system"): one window
is shown, it has the whole screen and no decoration, and every input
event but the reserved chord goes to it.

Configuration, from the manifest: optionally `chord`, the reserved
chord's key codes (erx_wm:chord_init/1). It names no session:
erx_winfs passes every call the directory of the display's session.

Which window is shown is derived, never stored: it is the live window
of the display's session with the lowest id, shown/2, computed afresh from
every table erx_winfs hands the policy. A window is matched by its
session, since a window's name is its client's choice. Every other
window, a later one of the same session or one of any other session, is
hidden. With no live window of the session, none is shown and input is
dropped.

Placement. `new` and arrange/3 give every window the screen's rectangle
and set each window's state from shown/2, so when the shown window ends
the session's next oldest is shown. Every `wctl` request is refused with
`einval`, so no window takes the screen by asking.

Input. The reserved chord is answered with `{wm, chord}` and its
repeats and its key up are dropped (erx_wm:chord/2); every other event
goes to the shown window.
""".

-behaviour(erx_wm).

-export([init/1, place/6, arrange/4, decorate/2, input/4, shown/2]).
-export_type([config/0, state/0]).

-doc "The manifest's configuration of the policy.".
-type config() :: #{chord => [0..16#ffff, ...]}.
-doc "The policy's state, threaded by erx_winfs.".
-type state() :: #{chord := erx_wm:chord()}.

-doc "The policy's state from its configuration; a bad one raises `badarg`.".
-spec init(config()) -> state().
init(Config) when is_map(Config) ->
    #{chord => erx_wm:chord_init(Config)};
init(Config) ->
    error(badarg, [Config]).

-doc """
Answers a geometry request: `new` arranges the table, and every `wctl`
request is refused.
""".
-spec place(erx_wm:request(), erx_wm:window_id(), [erx_wm:window()],
            erx_wm:rect(), erx_wm:session(), state()) ->
          {ok, [erx_wm:window()], state()} | {error, einval}.
place(new, Id, Windows, Screen = {X0, Y0, X1, Y1}, Session, State)
  when X0 < X1, Y0 < Y1 ->
    case erx_wm:fetch(Id, Windows) of
        {ok, _} ->
            {Arranged, State} = arrange(Windows, Screen, Session, State),
            {ok, Arranged, State};
        error ->
            {error, einval}
    end;
place(_Request, _Id, _Windows, _Screen, _Session, _State) ->
    {error, einval}.

-doc "The table after a window ended or the screen changed; see the moduledoc.".
-spec arrange([erx_wm:window()], erx_wm:rect(), erx_wm:session(), state()) ->
          {[erx_wm:window()], state()}.
arrange(Windows, Screen, Session, State) ->
    ShownId = shown(Session, Windows),
    {[W#{rect := Screen, state := case WindowId of ShownId -> shown; _ -> hidden end}
      || W = #{id := WindowId} <- Windows], State}.

-doc "The single policy draws nothing.".
-spec decorate([erx_wm:window()], erx_wm:rect()) -> [].
decorate(_Windows, _Screen) -> [].

-doc "Routes one input event; see the moduledoc.".
-spec input(erx_wm:input(), [erx_wm:window()], erx_wm:session(), state()) ->
          {erx_wm:route(), state()}.
input(Input, Windows, Session, State = #{chord := Chord}) ->
    {Seen, Next} = erx_wm:chord(Input, Chord),
    Route = case {Seen, shown(Session, Windows)} of
                {chord, _} -> {wm, chord};
                {withheld, _} -> drop;
                {pass, none} -> drop;
                {pass, Id} -> {to, Id, Input}
            end,
    {Route, State#{chord := Next}}.

-doc """
The window the policy shows: the live window of session `Session` with
the lowest id, or `none` when there is no session or it has no window in
the table.
""".
-spec shown(erx_wm:session(), [erx_wm:window()]) -> erx_wm:window_id() | none.
shown(none, _Windows) ->
    none;
shown(Session, Windows) ->
    case [Id || W = #{id := Id} <- Windows, erx_wm:session(W) =:= Session] of
        [] -> none;
        Ids -> lists:min(Ids)
    end.
