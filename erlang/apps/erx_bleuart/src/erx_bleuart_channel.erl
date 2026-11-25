%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart_channel).
-moduledoc """
The master of one client's tty of root's session (docs/design-bluetooth.md, "The
console"), the thin effect layer around erx_bleuart_core: the channel the line's
`open_tty` names, so the tty's messages come to it, each in the envelope of root's
session's domain. erx_bleuart, which owns the connection's stream, hands it the
connection's events as `{erx_bleuart, Event}`; it sends the tty its messages and the
client the tty's output with erx_gatt_serial:send/2, whose answer, `ok` or `{error,
busy}`, takes the output either way, so a client that stalls loses that output and
stops nothing.

It is linked to erx_bleuart, so a crash of either ends the other, and the tty's
relay watches it, so its end of any kind hangs the tty up. It ends normally when the
core says stop: at the client's disconnect, after `tty_hangup`, or when the tty fails
a check.
""".

-export([start_link/2, event/2]).
-export([init/2]).

-doc """
Starts the master for connection Conn of a tty of Domain, root's session's domain,
linked to the caller.
""".
-spec start_link(reference(), non_neg_integer()) -> pid().
start_link(Conn, Domain) when is_reference(Conn), is_integer(Domain) ->
    proc_lib:spawn_link(?MODULE, init, [Conn, Domain]).

-doc "Hands the master one event of its connection (erx_bleuart_core:event()).".
-spec event(pid(), erx_bleuart_core:event()) -> ok.
event(Channel, Event) ->
    Channel ! {?MODULE, Event},
    ok.

-doc false.
init(Conn, Domain) ->
    loop(Conn, erx_bleuart_core:new(Domain, fun erx:owner/1)).

loop(Conn, Core) ->
    receive
        {?MODULE, Event} -> step(Event, Conn, Core);
        {erx_origin, D, Message} -> step({tty, D, Message}, Conn, Core);
        _Other -> loop(Conn, Core)
    end.

step(Event, Conn, Core0) ->
    {Actions, Core} = erx_bleuart_core:step(Event, Core0),
    carry_out(Actions, Conn, Core).

carry_out([], Conn, Core) ->
    loop(Conn, Core);
carry_out([{to_tty, Tty, Message} | Rest], Conn, Core) ->
    Tty ! Message,
    carry_out(Rest, Conn, Core);
carry_out([{write, N, Bytes} | Rest], Conn, Core0) ->
    _ = erx_gatt_serial:send(Conn, Bytes),
    {Taken, Core} = erx_bleuart_core:step({written, N}, Core0),
    carry_out(Taken ++ Rest, Conn, Core);
carry_out([{lost_output, N} | Rest], Conn, Core) ->
    logger:notice("bleuart: output ~b of root's tty was lost", [N]),
    carry_out(Rest, Conn, Core);
carry_out([stop | _Rest], _Conn, _Core) ->
    exit(normal).
