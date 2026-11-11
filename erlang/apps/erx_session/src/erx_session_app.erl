%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_app).
-moduledoc "The session application: the session's /data and its supervisor (erx_session_sup).".
-behaviour(application).

-export([start/2, stop/1]).

%% /data first: the storage domain's tree through the session's data facet, which each
%% lookup reads afresh, so a grant installed later or re-granted after the storage
%% domain restarts needs no remount, and a session whose principal holds no data facet
%% finds /data answering eio (docs/design-stopgap.md, "/data for other domains").
start(_Type, _Args) ->
    ok = erx_ns:mount({facet, data}, <<"/data">>, [{tree, <<"data">>}, rw]),
    erx_session_sup:start_link().

stop(_State) ->
    ok.
