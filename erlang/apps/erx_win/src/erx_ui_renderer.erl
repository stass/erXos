%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_renderer).
-moduledoc """
The renderer behaviour (docs/design-display.md, "The widget server"): what
erx_ui_server asks of the module that draws its tree. A renderer starts
over its target, applies each tree's operations, the `diff_op()`s of
erx_ui_model:delta/2 ending with `commit`, and stops.

A renderer reads its target's input in a process of its own, linked to
the server: a window's mouse and kbd, or a browser's events. For each event
on a node, and each change of a state property, it sends the server
`{ui_hit, Node, Event, Value}`, `Event` the event property's name and
`Value` the state value, or `none`. A renderer that fails ends one of the
processes linked to the server, which ends the UI as `renderer_down`.
""".

-export_type([target/0]).

-doc """
What a renderer draws on: a window of a display the domain holds, or the
domain's web line (docs/design-web.md, "UIs: the browser renderer").
""".
-type target() :: {window, Window :: term()}
                | {web, Line :: pid()}.

-doc "Starts the renderer over its target for the widget server `Server`.".
-callback start(Target :: target(), Server :: pid(), Opts :: map()) -> {ok, State :: term()}.

-doc "Applies one tree's operations, which end with `commit`.".
-callback apply(Ops :: [erx_ui_model:diff_op()], State :: term()) ->
              {ok, State :: term()} | {error, term()}.

-doc "Stops the renderer; its end then is no fault.".
-callback stop(State :: term()) -> ok.
