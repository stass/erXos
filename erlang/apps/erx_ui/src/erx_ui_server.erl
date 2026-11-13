%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ui_server).
-behaviour(gen_server).
-moduledoc """
The widget server of one open UI (docs/design-display.md, "The widget
server"), started by erx_ui under erx_ui_sup. It holds the realised tree
and the number to give next, and does nothing but sequence the pure
functions over them: a tree is validated whole with erx_ui_schema,
numbered with erx_ui_model:pair/3, diffed with erx_ui_model:delta/2 and
applied through the renderer behaviour (erx_ui_renderer); a renderer's
hit goes through erx_ui_model:hit/4, and what it fires goes to the opener
as `{ui, Window, Term, Detail}`.

A tree that fails validation answers `{error, {Reason, Where}}` and
changes nothing. The UI ends, sending the opener `{ui_down, Window,
Reason}`, when the window would need a node number past 2^32 - 1
(`limit`), when the renderer refuses an apply, raises in any of its
callbacks, or a process linked to the server ends abnormally
(`renderer_down`: the renderer's view of the tree
is then unknown), and when the toolkit's supervisor shuts it down
(`shutdown`). close/1 ends it with no message, and so does its opener's
end, which the server monitors. A server that crashes or is killed leaves
the opener only the monitor's `'DOWN'`.

Every message from a renderer is checked by hit/4 against the realised
tree before anything is recorded, and a message of no known shape is
dropped, so nothing a renderer sends crashes the server or makes an atom.
A crash report of the server shows neither the tree nor the message it
was handling (format_status/1), so no application term leaves the domain
through the log.
""".

-export([start_link/1, opened/2, tree/2, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

%% The toolkit's limit on a tree's nodes (docs/design-display.md, "Widget
%% trees", `ui_nodes`).
-define(UI_NODES, 10000).

-type spec() :: #{opener := pid(), renderer := module(),
                  target := erx_ui_renderer:target(), opts := map()}.
-export_type([spec/0]).

-record(server, {opener :: pid(),
                 opener_monitor :: reference(),
                 window :: reference() | undefined,
                 renderer :: module(),
                 renderer_state :: term(),
                 realised :: erx_ui_model:realised(),
                 next = 1 :: erx_ui_model:next()}).

-doc """
Starts the server for `Opener` and its renderer over the target, linked to
the caller, erx_ui_sup.
""".
-spec start_link(spec()) -> gen_server:start_ret().
start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

-doc "Tells the server its window: the reference of the opener's monitor on it.".
-spec opened(pid(), reference()) -> ok.
opened(Server, Window) ->
    gen_server:call(Server, {opened, Window}).

-doc "Hands the server a tree: `ok`, or `{error, Reason}` with nothing changed.".
-spec tree(pid(), term()) -> ok | {error, term()}.
tree(Server, Tree) ->
    gen_server:call(Server, {tree, Tree}, infinity).

-doc "Ends the server and its renderer; the opener is sent nothing.".
-spec close(pid()) -> ok.
close(Server) ->
    gen_server:call(Server, close, infinity).

init(#{opener := Opener, renderer := Renderer, target := Target, opts := Opts}) ->
    %% A renderer's processes are linked to the server; their abnormal end
    %% ends the UI as renderer_down.
    process_flag(trap_exit, true),
    Monitor = monitor(process, Opener),
    case renderer(fun() -> Renderer:start(Target, self(), Opts) end) of
        {ok, State} ->
            {ok, #server{opener = Opener, opener_monitor = Monitor, renderer = Renderer,
                         renderer_state = State, realised = erx_ui_model:empty()}};
        _Failed ->
            {stop, {shutdown, renderer_down}}
    end.

handle_call({opened, Window}, {Opener, _Tag}, #server{opener = Opener, window = undefined} = S)
  when is_reference(Window) ->
    {reply, ok, S#server{window = Window}};
handle_call({tree, Tree}, _From, S) ->
    take_tree(Tree, S);
handle_call(close, _From, S) ->
    {stop, {shutdown, closed}, ok, S};
handle_call(_Request, _From, S) ->
    {reply, {error, badarg}, S}.

handle_cast(_Request, S) ->
    {noreply, S}.

handle_info({ui_hit, Node, Event, Value}, #server{realised = Ui} = S) ->
    case erx_ui_model:hit(Ui, Node, Event, Value) of
        {fire, Term, Detail, Ui1} ->
            S#server.opener ! {ui, S#server.window, Term, Detail},
            {noreply, S#server{realised = Ui1}};
        {keep, Ui1} ->
            {noreply, S#server{realised = Ui1}};
        drop ->
            {noreply, S}
    end;
handle_info({'DOWN', Monitor, process, _Opener, _Why}, #server{opener_monitor = Monitor} = S) ->
    {stop, normal, S};
handle_info({'EXIT', _Pid, normal}, S) ->
    {noreply, S};
handle_info({'EXIT', _Pid, _Why}, S) ->
    {stop, {shutdown, renderer_down}, S};
handle_info(_Message, S) ->
    {noreply, S}.

%% Stops the renderer, which may be gone already, and tells the opener
%% why the UI ended unless the opener closed it or is gone itself.
%% Before the opener has its window it hears nothing: start/1 answers it.
terminate(Reason, #server{renderer = Renderer, renderer_state = State, window = Window} = S) ->
    _ = renderer(fun() -> Renderer:stop(State) end),
    case down_reason(Reason) of
        _Why when Window =:= undefined -> ok;
        none -> ok;
        Why -> S#server.opener ! {ui_down, Window, Why}
    end.

%% A crash report names the server's reason and nothing of its tree, its
%% renderer's state or the message it was handling.
format_status(Status) ->
    maps:map(fun(state, #server{} = S) -> S#server{realised = hidden, renderer_state = hidden};
                (Key, _Value) when Key =:= message; Key =:= queue; Key =:= log -> hidden;
                (_Key, Value) -> Value
             end, Status).

%% Every renderer callback runs through here: whatever it raises, an exit
%% from a renderer process already gone among it, is the renderer's
%% failure, answered as {failed, Class}, and never a crash of the server.
renderer(Callback) ->
    try Callback()
    catch Class:_Why -> {failed, Class}
    end.

down_reason({shutdown, closed}) -> none;
down_reason({shutdown, Why}) -> Why;
down_reason(shutdown) -> shutdown;
down_reason(_NormalOrCrash) -> none.

%% A tree: validated whole, numbered, diffed and applied, in that order,
%% so a refusal at any step leaves the realised tree as it was.
take_tree(Tree, #server{realised = Ui, next = Next} = S) ->
    case erx_ui_schema:validate(Tree, ?UI_NODES) of
        {error, _Fault} = Refused ->
            {reply, Refused, S};
        ok ->
            case erx_ui_model:pair(Ui, Tree, Next) of
                {error, limit} = Limit ->
                    {stop, {shutdown, limit}, Limit, S};
                {Ui1, Next1} ->
                    apply_tree(erx_ui_model:delta(Ui, Ui1), S#server{realised = Ui1, next = Next1})
            end
    end.

apply_tree(Ops, #server{renderer = Renderer, renderer_state = State} = S) ->
    case renderer(fun() -> Renderer:apply(Ops, State) end) of
        {ok, State1} ->
            {reply, ok, S#server{renderer_state = State1}};
        {error, _Why} = Refused ->
            {stop, {shutdown, renderer_down}, Refused, S};
        _Failed ->
            {stop, {shutdown, renderer_down}, {error, renderer_down}, S}
    end.
