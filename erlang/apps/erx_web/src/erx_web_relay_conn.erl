%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_relay_conn).

-moduledoc """
One browser connection the host link relays (docs/design-web.md, "The
host tool's front end"): the process that drives the connection core
erx_web_conn for it, started by erx_web_relay. The core decides everything;
this process feeds it what arrives and performs what it returns, in order,
with erx_web_conn:perform/2.

* A message from the browser arrives as `{in, Bytes}` from the relay. The
  core never hears `tick`: on this path the host tool owns the browser's
  liveness, since WebSocket pings end there, and it closes a WebSocket
  silent for `web_idle_ms` itself; the connection's bound on a lost host is
  its sink, whose end ends it.
* A `send` goes to the sink, the system domain's process that relays for the
  host session, as `{web, C, Bytes}`; a `close` as `{web_closed, C, Reason}`,
  after which the process ends.
* A view is opened on the connection's line, the erx_web_line of the
  session the connection is bound to, which answers the view's process.
  The view's answers, `{web_view, Pid, Body}` and `{web_view_ended, Pid,
  Reason}`, are taken only from a view this connection opened, and from
  another domain only in the envelope of the line's domain; a view's end
  without an answer, its 'DOWN', is `ended closed`. A connection bound to
  no line answers every open `ended unsupported`.
* `close` from the relay, the host closing the connection, and the end of
  the sink end the process without a word to the sink; the views it opened
  monitor it and end with it.
""".

-export([start_link/3]).
-export([init/4]).

-doc """
Starts connection `C` of `Sink`, bound to `Line`, linked to the caller;
`{error, Reason}` when the core refuses the line.
""".
-spec start_link(pid(), non_neg_integer(), erx_web_relay:line()) -> {ok, pid()} | {error, term()}.
start_link(Sink, C, Line) ->
    case erx_web_conn:new(Line) of
        {ok, Core} ->
            {ok, proc_lib:spawn_link(?MODULE, init, [Sink, C, Core, maps:get(line, Line, none)])};
        {error, _} = Error ->
            Error
    end.

-doc false.
init(Sink, C, Core, Line) ->
    _ = erlang:monitor(process, Sink),
    loop(#{sink => Sink, c => C, core => Core, line => Line, views => #{}}).

loop(#{sink := Sink, line := Line, views := Views} = State) ->
    receive
        {in, Bytes} ->
            loop(step({in, Bytes}, State));
        close ->
            exit(normal);
        {'DOWN', _Ref, process, Sink, _Reason} ->
            exit(normal);
        {'DOWN', _Ref, process, Pid, _Reason} when is_map_key(Pid, Views) ->
            loop(view_ended(Pid, closed, State));
        Message ->
            case from_view(Message, Line, Views) of
                {update, Pid, Body} -> loop(step({update, map_get(Pid, Views), Body}, State));
                {ended, Pid, Reason} -> loop(view_ended(Pid, Reason, State));
                drop -> loop(State)
            end
    end.

%% What a view sent: from a view this connection opened, in the envelope of the
%% line's domain, or without one from a view of this runtime, as in a host test.
from_view({erx_origin, D, Message}, Line, Views) when is_pid(Line) ->
    case erx:owner(Line) of
        D -> from_view(Message, none, Views);
        _ -> drop
    end;
from_view({web_view, Pid, Body}, _Line, Views) when is_map_key(Pid, Views) ->
    {update, Pid, Body};
from_view({web_view_ended, Pid, Reason}, _Line, Views) when is_map_key(Pid, Views), is_atom(Reason) ->
    {ended, Pid, Reason};
from_view(_Message, _Line, _Views) ->
    drop.

view_ended(Pid, Reason, #{views := Views} = State) ->
    Next = step({ended, map_get(Pid, Views), Reason}, State),
    Next#{views := maps:remove(Pid, map_get(views, Next))}.

%% Feeds the core one input and performs its actions in order, feeding back
%% what each produced: the view the line started, or why it could not.
step(Input, #{core := Core} = State) ->
    {Actions, Next} = erx_web_conn:step(Input, Core),
    lists:foldl(fun perform/2, State#{core := Next}, Actions).

perform(Action, #{sink := Sink, c := C, line := Line} = State) ->
    Driver = #{send => fun(Bytes) -> Sink ! {web, C, Bytes} end,
               close => fun(Reason) -> Sink ! {web_closed, C, Reason}, exit(normal) end,
               line => Line},
    lists:foldl(fun(Input, Acc) -> step(Input, remember(Input, Acc)) end, State,
                erx_web_conn:perform(Action, Driver)).

remember({opened, View, Pid}, #{views := Views} = State) -> State#{views := Views#{Pid => View}};
remember(_Input, State) -> State.
