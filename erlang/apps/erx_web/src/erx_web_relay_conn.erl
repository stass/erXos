%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_relay_conn).

-moduledoc """
One browser connection the host link relays (docs/design-web.md, "The
host tool's front end"): the process that drives the connection core
erx_web_conn for it, started by erx_web_relay. The core decides everything;
this process feeds it what arrives and performs what it returns, in order.

* A message from the browser arrives as `{in, Bytes}` from the relay. The
  core never hears `tick`: on this path the host tool owns the browser's
  liveness, since WebSocket pings end there, and it closes a WebSocket
  silent for `web_idle_ms` itself; the connection's bound on a lost host is
  its sink, whose end ends it.
* A `send` goes to the sink, the system domain's process that relays for the
  host session, as `{web, C, Bytes}`; a `close` as `{web_closed, C, Reason}`,
  after which the process ends.
* An `open` is answered `ended unsupported`: the line through which a view
  is fetched in the principal's session (erx_web_line) is not built yet, and
  a view the machine cannot answer says so rather than show anything. Since
  no view is ever reported `opened`, the core asks no `next`, `stop` or
  `event` of this process.
* `close` from the relay, the host closing the connection, and the end of
  the sink end the process without a word to the sink.
""".

-export([start_link/3]).
-export([init/3]).

-doc """
Starts connection `C` of `Sink`, bound to `Line`, linked to the caller;
`{error, Reason}` when the core refuses the line.
""".
-spec start_link(pid(), non_neg_integer(), erx_web_relay:line()) -> {ok, pid()} | {error, term()}.
start_link(Sink, C, Line) ->
    case erx_web_conn:new(Line) of
        {ok, Core} ->
            {ok, proc_lib:spawn_link(?MODULE, init, [Sink, C, Core])};
        {error, _} = Error ->
            Error
    end.

-doc false.
init(Sink, C, Core) ->
    _ = erlang:monitor(process, Sink),
    loop(#{sink => Sink, c => C, core => Core}).

loop(#{sink := Sink} = State) ->
    receive
        {in, Bytes} ->
            loop(step({in, Bytes}, State));
        close ->
            exit(normal);
        {'DOWN', _Ref, process, Sink, _Reason} ->
            exit(normal);
        _Other ->
            loop(State)
    end.

step(Input, #{core := Core} = State) ->
    {Actions, Next} = erx_web_conn:step(Input, Core),
    lists:foldl(fun perform/2, State#{core := Next}, Actions).

perform({send, Bytes}, #{sink := Sink, c := C} = State) ->
    Sink ! {web, C, Bytes},
    State;
perform({close, Reason}, #{sink := Sink, c := C}) ->
    Sink ! {web_closed, C, Reason},
    exit(normal);
perform({open, View, _Target}, State) ->
    step({ended, View, unsupported}, State).
