%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart).
-moduledoc """
bleuart, root's shell over Nordic's UART service (docs/design-bluetooth.md, "The
console"): the application its session's `-eval` starts, permanent, and its process
that owns the `nus` handler, beside one master for each connection's tty.

At start it starts erx_gatt_serial for `nus`, linked, so the end of either ends the
other, and the end of the Bluetooth domain's facet ends both. It keeps one entry for
each connection, until the connection's `disconnected`:

* **The line.** At the first connection it asks its login grant for root's line
  (`root_line`) and keeps the line for its life, watching it: the line's end, with
  the console's session or with the login facet, ends erx_bleuart, so the session
  that starts next asks for the line of whatever session the console holds then.
  An answer other than a line leaves no line, so the next connection asks again;
  the client it was asked for is `unavailable`: at its subscription to `tx` it is
  sent the one constant line `bleuart: root's session is not running`, and nothing
  else.
* **A tty.** Otherwise it starts the connection's master, erx_bleuart_channel, and
  asks the line to `open_tty` a tty of root's session for it, running the command
  shell, at the default size and `TERM`. It hands the master each of the
  connection's events: a write of `rx`, a gap, a change of the subscription to
  `tx`, and the disconnect. The master's end, its relay ended or its tty refused,
  leaves the connection `ended`.
* **The bound.** Each event reaches the master only while the master's queue holds
  fewer than twice `bt_write_queue` messages; past it the event is a gap,
  `serial_lost`, which ends the relay, and the connection is `ended` from then on. So
  no queue a phone fills grows past that bound, and a master that cannot keep up costs
  the phone its shell, not its input. The headroom is for the writes the handler
  holds when a master's send reaches it: the link keeps at most `bt_write_queue`
  unanswered, and the handler forwards them before it takes the send, while the
  master waits on it.

An `unavailable` or `ended` connection's events reach nothing. A phone's bytes reach
root's session only as tty input; nothing here reads them.
""".
-behaviour(application).

-include("generated/erx_abi.hrl").

-export([start/2, stop/1]).
-export([start_link/1, init/2]).
-export_type([effects/0]).

-doc """
What erx_bleuart and its masters do to the world, which a host test replaces: `serial`,
the module of the `nus` handler (start_link/2 and send/2, erx_gatt_serial's); `root_line`,
the ask of the login grant; `owner`, the domain of a pid (erx:owner/1).
""".
-type effects() :: #{serial := module(),
                     root_line := fun(() -> term()),
                     owner := fun((pid()) -> non_neg_integer())}.

%% The Nordic UART service of abi/gatt, the one service bleuart handles.
-define(SERVICE, nus).
%% The bound on each call to the login grant and the line.
-define(CALL_MS, 10000).
-define(UNAVAILABLE, <<"bleuart: root's session is not running\r\n">>).
%% The most messages a master's queue holds before an event for it is a gap.
-define(MASTER_QUEUE, (2 * ?ERX_BT_WRITE_QUEUE)).

%% A connection's entry: its master, or no tty, unavailable until its one line is
%% sent, ended after.
-type entry() :: pid() | unavailable | ended.
-type state() :: #{effects := effects(), line := none | {pid(), reference()}, conns := #{reference() => entry()}}.

start(_Type, _Args) ->
    start_link(#{serial => erx_gatt_serial, root_line => fun root_line/0, owner => fun erx:owner/1}).

stop(_State) ->
    ok.

-doc false.
-spec start_link(effects()) -> {ok, pid()} | {error, term()}.
start_link(Effects) ->
    proc_lib:start_link(?MODULE, init, [self(), Effects]).

-doc false.
init(Parent, #{serial := Serial} = Effects) ->
    true = register(?MODULE, self()),
    case Serial:start_link(?SERVICE, self()) of
        {ok, _Handler} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            loop(#{effects => Effects, line => none, conns => #{}});
        {error, Reason} ->
            logger:error("bleuart: the UART service's handler did not start: ~0p", [Reason]),
            proc_lib:init_fail(Parent, {error, Reason}, {exit, normal})
    end.

%% line: root's line and its monitor, or none; conns: each connection's entry().
loop(#{line := Line, conns := Conns} = S) ->
    LineMonitor = case Line of
                      {_Pid, Monitor} -> Monitor;
                      none -> none
                  end,
    receive
        {connected, Conn, _Info} when is_reference(Conn), not is_map_key(Conn, Conns) ->
            loop(connected(Conn, S));
        {serial, Conn, Bytes} ->
            loop(to_master(Conn, {serial, Bytes}, S));
        {serial_lost, Conn} ->
            loop(to_master(Conn, serial_lost, S));
        {subscribed, Conn, tx, Kind} ->
            loop(subscribed(Conn, Kind, S));
        {disconnected, Conn} ->
            loop(forget(Conn, to_master(Conn, disconnected, S)));
        {'DOWN', LineMonitor, process, _Line, Reason} ->
            exit({shutdown, {line_ended, Reason}});
        {'DOWN', _Ref, process, Master, _Reason} ->
            loop(S#{conns := maps:map(fun(_Conn, Pid) when Pid =:= Master -> ended;
                                         (_Conn, Entry) -> Entry
                                      end, Conns)});
        _Other ->
            loop(S)
    end.

-spec forget(reference(), state()) -> state().
forget(Conn, #{conns := Conns} = S) ->
    S#{conns := maps:remove(Conn, Conns)}.

%% The event reaches Conn's master while the master keeps up, and is a gap past that.
to_master(Conn, Event, #{conns := Conns} = S) ->
    case Conns of
        #{Conn := Master} when is_pid(Master) ->
            case keeps_up(Master) of
                true ->
                    erx_bleuart_channel:event(Master, Event),
                    S;
                false ->
                    erx_bleuart_channel:event(Master, serial_lost),
                    S#{conns := Conns#{Conn := ended}}
            end;
        #{} ->
            S
    end.

keeps_up(Master) ->
    case process_info(Master, message_queue_len) of
        {message_queue_len, Queued} -> Queued < ?MASTER_QUEUE;
        undefined -> false
    end.

%% An unavailable client hears its one line once it can: at its subscription to tx.
subscribed(Conn, Kind, #{conns := Conns, effects := #{serial := Serial}} = S) ->
    case Conns of
        #{Conn := unavailable} when Kind =/= none ->
            _ = Serial:send(Conn, ?UNAVAILABLE),
            S#{conns := Conns#{Conn := ended}};
        #{} ->
            to_master(Conn, {subscribed, Kind}, S)
    end.

connected(Conn, #{conns := Conns} = S0) ->
    case line(S0) of
        {ok, Line, S} ->
            open(Conn, Line, S);
        {error, S} ->
            S#{conns := Conns#{Conn => unavailable}}
    end.

%% Root's line, asked once and kept.
line(#{line := {Line, _Ref}} = S) ->
    {ok, Line, S};
line(#{effects := #{root_line := RootLine}} = S) ->
    case RootLine() of
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

%% A tty of root's session for Conn, mastered by a process of its own.
open(Conn, Line, #{conns := Conns, effects := #{owner := Owner} = Effects} = S) ->
    Master = erx_bleuart_channel:start_link(Conn, Owner(Line), Effects),
    _ = monitor(process, Master),
    case call(Line, {open_tty, Master, shell, <<>>, 0, 0}) of
        ok ->
            ok;
        Refused ->
            logger:warning("bleuart: root's session opened no tty: ~0p", [Refused]),
            erx_bleuart_channel:event(Master, disconnected)
    end,
    S#{conns := Conns#{Conn => Master}}.

%% A call to a facet; its end or silence past the bound is an error, not our end.
call(Facet, Request) ->
    try gen_server:call(Facet, Request, ?CALL_MS)
    catch
        exit:Reason -> {error, Reason}
    end.
