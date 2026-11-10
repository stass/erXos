%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_app).
-moduledoc "The domain service's application: starts erx_domain_sup.".
-behaviour(application).

-export([start/2, stop/1]).

%% Boot step 4 follows the service's start (docs/design-system.md, "Booting"): the service
%% starts the configured domains before it takes a call, and the console then logs the
%% line's principal in, which asks the service for that principal's session.
start(_Type, _Args) ->
    case erx_domain_sup:start_link() of
        {ok, _Sup} = Started ->
            ok = erx_console:login(),
            Started;
        Refused ->
            Refused
    end.

stop(_State) ->
    ok.
