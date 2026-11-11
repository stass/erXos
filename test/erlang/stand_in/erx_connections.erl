%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erXos's erx_connections as the host tests of a mint see it on stock's emulator: the
%% connection to a domain is the port a test set for it with set/2, a stand-in of the
%% lane driver's port, and a domain with none is not connected.

-module(erx_connections).

-export([connection/1, set/2]).

-spec connection(pos_integer()) -> {ok, port()} | {error, noconnection}.
connection(Domain) ->
    persistent_term:get({?MODULE, Domain}, {error, noconnection}).

-spec set(pos_integer(), port()) -> ok.
set(Domain, Port) ->
    persistent_term:put({?MODULE, Domain}, {ok, Port}).
