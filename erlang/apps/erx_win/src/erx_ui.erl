%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui).
-moduledoc """
The widget toolkit's client library (docs/design-display.md, "The widget
server" and "Choosing a display"). An application opens a UI, hands it
trees and closes it; the UI's widget server, erx_ui_server, runs under the
toolkit's supervisor erx_ui_sup in the application's own runtime and sends
the opener `{ui, Window, Term, Detail}` for each event its tree takes and
`{ui_down, Window, Reason}` when the UI ends other than by close/1.

`Window` is the reference of the monitor the opener holds on the server,
so a server that is killed outright leaves the opener that monitor's
`'DOWN'`. The opener's process dictionary maps it to the server, under
`{erx_ui, Window}`: a UI is its opener's, as its events are, and tree/2
and close/1 work from the opener.

open/1 chooses the display and the renderer by choose/2. The server opens
its own target, a window made with the server as its holder, or the web
line: until the window stack and the web line are built, a display the
domain holds, and `web`, answer `{error, enotsup}`. start/1 starts a UI on
a target its caller made; it is the entry of the tests and the renderers'
harnesses only, and goes when the server opens its own window.
""".

-export([open/1, tree/2, close/1]).
-export([choose/2, start/1]).

-type window() :: reference().
-type renderer() :: erlang | lvgl.
-export_type([window/0, renderer/0]).

-doc """
Opens a UI on the display that `Options`' `display` names, or the default
display, the environment variable `display`, drawn by the renderer that
`Options`' `renderer` names, or the one `ui_renderer` names, or `erlang`.
`{error, no_display}` when the name is unset or names no display the
domain holds.
""".
-spec open(map()) -> {ok, window()} | {error, no_display | enotsup | badarg}.
open(Options) when is_map(Options) ->
    Env = #{display => os:getenv("display"), ui_renderer => os:getenv("ui_renderer")},
    case choose(Options, Env) of
        {ok, web, _Renderer} -> {error, enotsup};
        {ok, Display, _Renderer} -> on_display(Display, erx:caps());
        {error, _Why} = Refused -> Refused
    end.

-doc "Hands the UI a tree: `ok`, or `{error, Reason}` with the UI unchanged.".
-spec tree(window(), term()) -> ok | {error, term()}.
tree(Window, Tree) ->
    case get({?MODULE, Window}) of
        undefined ->
            {error, closed};
        Server ->
            try erx_ui_server:tree(Server, Tree)
            catch exit:{_Why, {gen_server, call, _}} -> {error, closed}
            end
    end.

-doc "Ends the UI and its window; the opener is sent nothing more of it.".
-spec close(window()) -> ok.
close(Window) ->
    case erase({?MODULE, Window}) of
        undefined ->
            ok;
        Server ->
            demonitor(Window, [flush]),
            try erx_ui_server:close(Server)
            catch exit:{_Why, {gen_server, call, _}} -> ok
            end,
            %% A UI that ended before the close may have sent its ui_down.
            receive {ui_down, Window, _} -> ok after 0 -> ok end
    end.

-doc """
The display and renderer `Options` choose, given the environment's
`display` and `ui_renderer` (each a string, or `false` when unset): the
display's name, the atom `web` for the web line, and the renderer. A name
is matched against the atoms that exist, so no name makes an atom; a
`renderer` option other than `erlang` and `lvgl` is `badarg`, and an
environment value other than theirs names none.
""".
-spec choose(map(), #{display := string() | false, ui_renderer := string() | false}) ->
          {ok, atom(), renderer()} | {error, no_display | badarg}.
choose(Options, #{display := DefaultDisplay, ui_renderer := DefaultRenderer}) ->
    Display = case Options of
                  #{display := Name} -> Name;
                  #{} -> existing_atom(DefaultDisplay)
              end,
    Renderer = case Options of
                   #{renderer := Named} -> Named;
                   #{} -> env_renderer(DefaultRenderer)
               end,
    if
        Renderer =/= erlang, Renderer =/= lvgl -> {error, badarg};
        not is_atom(Display) -> {error, badarg};
        Display =:= undefined -> {error, no_display};
        true -> {ok, Display, Renderer}
    end.

-doc """
Starts a UI for the caller on a target it made, drawn by `renderer`, a
module of the erx_ui_renderer behaviour, started with `opts`. The entry
of the tests and the renderers' harnesses only; it is deleted when the
server opens its own window.
""".
-spec start(#{renderer := module(), target := erx_ui_renderer:target(), opts := map()}) ->
          {ok, window()} | {error, term()}.
start(#{renderer := Renderer, target := Target, opts := Opts}) ->
    Spec = #{opener => self(), renderer => Renderer, target => Target, opts => Opts},
    case erx_ui_sup:start_server(Spec) of
        {ok, Server} ->
            Window = monitor(process, Server),
            try erx_ui_server:opened(Server, Window) of
                ok ->
                    put({?MODULE, Window}, Server),
                    {ok, Window}
            catch
                exit:{Why, {gen_server, call, _}} ->
                    demonitor(Window, [flush]),
                    {error, Why}
            end;
        {error, _Why} = Failed ->
            Failed
    end.

%% A display the domain holds opens a window there, which the window
%% stack provides.
on_display(Display, Caps) ->
    case Caps of
        #{Display := _Grant} -> {error, enotsup};
        #{} -> {error, no_display}
    end.

existing_atom(false) -> undefined;
existing_atom(Name) ->
    try list_to_existing_atom(Name)
    catch error:badarg -> undefined
    end.

env_renderer("lvgl") -> lvgl;
env_renderer(_ErlangOrUnset) -> erlang.
