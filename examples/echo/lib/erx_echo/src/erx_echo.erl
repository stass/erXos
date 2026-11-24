%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_echo).
-moduledoc """
The echo app (examples/echo/README.md): Nordic's UART service, `nus`, echoed back to
each phone. The application's supervisor starts one process, registered under this
module's name, which starts the serial service's handler, erx_gatt_serial, for `nus`,
linked to itself, and sends each `{serial, Conn, Bytes}` back to the link it came from
with erx_gatt_serial:send/2, so a phone reads on `tx` every byte it wrote to `rx`, in
order, and never a byte another phone wrote.

The handler attaches through the session's `ble` grant, which names only the GATT
services the package declares (`gatt nus`) and admission kept, so an app without that
grant fails its start with the attach's refusal, `not_granted`, and answers nothing.
Once attached it logs `erx_echo: echoing nus`. A send that fails, to a phone that left
or did not subscribe to `tx`, drops those bytes; the echo logs none of them.
""".

-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1, start_link/0, echo_init/1]).

-doc false.
start(_Type, _Args) ->
    supervisor:start_link({local, erx_echo_sup}, ?MODULE, []).

-doc false.
stop(_State) ->
    ok.

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => echo, start => {?MODULE, start_link, []}}]}}.

-doc "Starts the echo, linked to the caller, once its handler has attached `nus`.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    proc_lib:start_link(?MODULE, echo_init, [self()]).

-doc false.
echo_init(Parent) ->
    register(?MODULE, self()),
    case erx_gatt_serial:start_link(nus, self()) of
        {ok, _Serial} ->
            proc_lib:init_ack(Parent, {ok, self()}),
            logger:notice("erx_echo: echoing nus"),
            echo();
        {error, Reason} ->
            proc_lib:init_fail(Parent, {error, Reason}, {exit, normal})
    end.

echo() ->
    receive
        {serial, Conn, Bytes} ->
            _ = erx_gatt_serial:send(Conn, Bytes),
            echo();
        _Other ->
            echo()
    end.
