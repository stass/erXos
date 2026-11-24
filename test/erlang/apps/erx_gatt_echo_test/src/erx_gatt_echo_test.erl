%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_echo_test).
-moduledoc """
Test only: the serial service's echo (docs/design-bluetooth.md, "On QEMU against
Bumble"). The application's supervisor starts one process, registered under this
module's name, which starts erx_gatt_serial linked to itself and sends each
`{serial, Conn, Bytes}` back with erx_gatt_serial:send/2, so a phone reads on `tx`
every byte it wrote to `rx`, in order. A send that fails, to a phone that left or did
not subscribe to `tx`, drops those bytes. The domain service installs `ble` only once
both this domain and the Bluetooth domain are ready, and this domain reports ready only
once its boot script's applications have started, so the echo answers its start at
once and then waits, at most FACET_WAIT_MS, for the facet before it attaches; it exits
if none comes or the attach fails, for its supervisor to start it again, at most five
times in ten seconds.
""".

-behaviour(application).
-behaviour(supervisor).

-export([start/2, stop/1, init/1, start_link/0, echo_init/1]).

-define(FACET_WAIT_MS, 120000).

-doc false.
start(_Type, _Args) ->
    supervisor:start_link({local, erx_gatt_echo_test_sup}, ?MODULE, []).

-doc false.
stop(_State) ->
    ok.

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => echo, start => {?MODULE, start_link, []}}]}}.

-doc "Starts the echo, linked to the caller; it starts its serial handler once the facet comes.".
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    proc_lib:start_link(?MODULE, echo_init, [self()]).

-doc false.
echo_init(Parent) ->
    register(?MODULE, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    case erx_facets:await(ble, none, ?FACET_WAIT_MS) of
        {ok, _Facet} -> ok;
        NoFacet -> exit({no_facet, NoFacet})
    end,
    {ok, _Serial} = erx_gatt_serial:start_link(nus, self()),
    echo().

echo() ->
    receive
        {serial, Conn, Bytes} ->
            _ = erx_gatt_serial:send(Conn, Bytes),
            echo();
        _Other ->
            echo()
    end.
