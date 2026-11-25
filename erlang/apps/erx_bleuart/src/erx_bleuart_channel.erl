%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bleuart_channel).
-moduledoc """
The master of one client's tty of root's session (docs/design-bluetooth.md, "The
console"), the thin effect layer around erx_bleuart_core: the channel the line's
`open_tty` names, so the tty's messages come to it, each in the envelope of root's
session's domain. A tty's messages do not name the tty, so each tty has a master
process of its own. erx_bleuart, which owns the connection's stream, hands it the
connection's events as `{erx_bleuart_channel, Event}`; it sends the tty its messages
and the client the tty's output with the serial module's send/2, whose answer, `ok`
or `{error, busy}`, takes the output either way, so a client that stalls loses that
output and stops nothing.

It is linked to erx_bleuart, so a crash of either ends the other, and the tty's
relay watches it, so its end of any kind hangs the tty up. It ends normally when the
core says stop.
""".

-export([start_link/3, event/2]).
-export([init/3]).

-doc """
Starts the master for connection Conn of a tty of Domain, root's session's domain,
linked to the caller, with erx_bleuart's effects: `serial`, the module whose send/2
reaches the client, and `owner`, the domain of a pid.
""".
-spec start_link(reference(), non_neg_integer(), erx_bleuart:effects()) -> pid().
start_link(Conn, Domain, Effects) when is_reference(Conn), is_integer(Domain) ->
    proc_lib:spawn_link(?MODULE, init, [Conn, Domain, Effects]).

-doc "Hands the master one event of its connection (erx_bleuart_core:event()).".
-spec event(pid(), erx_bleuart_core:event()) -> ok.
event(Channel, Event) ->
    Channel ! {?MODULE, Event},
    ok.

-doc false.
init(Conn, Domain, #{serial := Serial, owner := Owner}) ->
    loop({Conn, Serial}, erx_bleuart_core:new(Domain, Owner)).

%% Client: the connection and the module that sends to it.
loop(Client, Core) ->
    receive
        {?MODULE, Event} -> step(Event, Client, Core);
        {erx_origin, D, Message} -> step({tty, D, Message}, Client, Core);
        _Other -> loop(Client, Core)
    end.

step(Event, Client, Core0) ->
    {Actions, Core} = erx_bleuart_core:step(Event, Core0),
    carry_out(Actions, Client, Core).

carry_out([], Client, Core) ->
    loop(Client, Core);
carry_out([{to_tty, Tty, Message} | Rest], Client, Core) ->
    Tty ! Message,
    carry_out(Rest, Client, Core);
carry_out([{write, N, Bytes} | Rest], {Conn, Serial} = Client, Core0) ->
    _ = Serial:send(Conn, Bytes),
    {Taken, Core} = erx_bleuart_core:step({written, N}, Core0),
    carry_out(Taken ++ Rest, Client, Core);
carry_out([{notice, Line} | Rest], {Conn, Serial} = Client, Core) ->
    logger:notice("bleuart: ~ts", [string:trim(Line)]),
    _ = Serial:send(Conn, Line),
    carry_out(Rest, Client, Core);
carry_out([{lost_output, N} | Rest], Client, Core) ->
    logger:notice("bleuart: output ~b of root's tty was lost", [N]),
    carry_out(Rest, Client, Core);
carry_out([stop | _Rest], _Client, _Core) ->
    exit(normal).
