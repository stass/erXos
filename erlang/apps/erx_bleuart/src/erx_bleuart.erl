%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart).
-moduledoc """
bleuart, root's shell over Nordic's UART service (docs/design-bluetooth.md, "The
console"): the application its session's `-eval` starts, permanent, and its one
process, the owner of the `nus` handler.

At start it starts erx_gatt_serial for `nus`, linked, so the end of either ends the
other, and the end of the Bluetooth domain's facet ends both. For each client:

* **The line.** At the first connection it asks its login grant for root's line
  (`root_line`) and keeps the line for its life, watching it: the line's end, with
  the console's session or with the login facet, ends erx_bleuart, so the session
  that starts next asks for the line of whatever session the console holds then.
  An answer other than a line leaves no line, so the next connection asks again;
  the client it was asked for is sent the one constant line `bleuart: root's
  session is not running` and nothing else.
* **A tty.** It starts the connection's master, erx_bleuart_channel, and asks the
  line to `open_tty` a tty of root's session for it, running the command shell, at
  the default size and `TERM`. It hands the master each of the connection's events:
  a write of `rx`, a gap, a change of the subscription to `tx`, and the disconnect.

A phone's bytes reach root's session only as tty input; nothing here reads them.
""".
-behaviour(application).

-export([start/2, stop/1]).
-export([init/1]).

%% The Nordic UART service of abi/gatt, the one service bleuart handles.
-define(SERVICE, nus).
%% The bound on each call to the login grant and the line.
-define(CALL_MS, 10000).
-define(UNAVAILABLE, <<"bleuart: root's session is not running\r\n">>).

start(_Type, _Args) ->
    proc_lib:start_link(?MODULE, init, [self()]).

stop(_State) ->
    ok.

-doc false.
init(Parent) ->
    true = register(?MODULE, self()),
    case erx_gatt_serial:start_link(?SERVICE, self()) of
        {ok, _Handler} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            loop(#{line => none, channels => #{}});
        {error, Reason} ->
            logger:error("bleuart: the UART service's handler did not start: ~0p", [Reason]),
            proc_lib:init_fail(Parent, {error, Reason}, {exit, normal})
    end.

%% line: root's line and its monitor, or none; channels: each connection's master.
loop(#{line := Line, channels := Channels} = S) ->
    LineMonitor = case Line of
                      {_Pid, Monitor} -> Monitor;
                      none -> none
                  end,
    receive
        {connected, Conn, _Info} when is_reference(Conn) ->
            loop(connected(Conn, S));
        {serial, Conn, Bytes} ->
            loop(to_channel(Conn, {serial, Bytes}, S));
        {serial_lost, Conn} ->
            loop(to_channel(Conn, serial_lost, S));
        {subscribed, Conn, tx, Kind} ->
            loop(to_channel(Conn, {subscribed, Kind}, S));
        {disconnected, Conn} ->
            loop(to_channel(Conn, disconnected, S));
        {'DOWN', LineMonitor, process, _Line, Reason} ->
            exit({shutdown, {line_ended, Reason}});
        {'DOWN', _Ref, process, Channel, _Reason} ->
            loop(S#{channels := maps:filter(fun(_Conn, Pid) -> Pid =/= Channel end, Channels)});
        _Other ->
            loop(S)
    end.

to_channel(Conn, Event, #{channels := Channels} = S) ->
    case Channels of
        #{Conn := Channel} -> erx_bleuart_channel:event(Channel, Event);
        #{} -> ok
    end,
    case Event of
        disconnected -> S#{channels := maps:remove(Conn, Channels)};
        _ -> S
    end.

connected(Conn, S0) ->
    case line(S0) of
        {ok, Line, S} ->
            open(Conn, Line, S);
        {error, S} ->
            _ = erx_gatt_serial:send(Conn, ?UNAVAILABLE),
            S
    end.

%% Root's line, asked once and kept.
line(#{line := {Line, _Ref}} = S) ->
    {ok, Line, S};
line(S) ->
    case root_line() of
        {ok, Line} when is_pid(Line) ->
            {ok, Line, S#{line := {Line, monitor(process, Line)}}};
        {error, unavailable} ->
            {error, S};
        Other ->
            logger:warning("bleuart: no line of root's session: ~0p", [Other]),
            {error, S}
    end.

root_line() ->
    case erx:cap(login) of
        Facet when is_pid(Facet) -> call(Facet, root_line);
        undefined -> {error, no_facet}
    end.

%% A tty of root's session for Conn, mastered by a channel of its own.
open(Conn, Line, #{channels := Channels} = S) ->
    Channel = erx_bleuart_channel:start_link(Conn, erx:owner(Line)),
    _ = monitor(process, Channel),
    case call(Line, {open_tty, Channel, shell, <<>>, 0, 0}) of
        ok ->
            S#{channels := Channels#{Conn => Channel}};
        Refused ->
            logger:warning("bleuart: root's session opened no tty: ~0p", [Refused]),
            erx_bleuart_channel:event(Channel, disconnected),
            S
    end.

%% A call to a facet; its end or silence past the bound is an error, not our end.
call(Facet, Request) ->
    try gen_server:call(Facet, Request, ?CALL_MS)
    catch
        exit:Reason -> {error, Reason}
    end.
