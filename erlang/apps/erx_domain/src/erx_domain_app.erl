%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_app).
-moduledoc """
The domain service's application: mounts the system domain's /data and
starts erx_domain_sup.
""".
-behaviour(application).

-export([start/2, stop/1]).

%% Boot step 4 follows the service's start (docs/design-system.md, "Booting"): the service
%% starts the configured domains before it takes a call, and the console then logs the
%% line's principal in, which asks the service for that principal's session.
%%
%% Before both, /data: the storage domain's tree through the system domain's data facet,
%% which each lookup reads afresh, so the system shell finds it whenever a grant is
%% installed and a restarted storage domain's re-grant needs no remount
%% (docs/design-stopgap.md, "/data for other domains").
start(_Type, _Args) ->
    ok = erx_ns:mount({facet, data}, <<"/data">>, [{tree, <<"data">>}, rw]),
    case erx_domain_sup:start_link() of
        {ok, _Sup} = Started ->
            ok = erx_console:login(),
            Started;
        Refused ->
            Refused
    end.

stop(_State) ->
    ok.
