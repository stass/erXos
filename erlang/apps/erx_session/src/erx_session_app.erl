%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_app).
-moduledoc "The session application: the session's /data and /apps and its supervisor (erx_session_sup).".
-behaviour(application).

-export([start/2, stop/1]).

%% /data first: the storage domain's tree through the session's data facet, which each
%% lookup reads afresh, so a grant installed later or re-granted after the storage
%% domain restarts needs no remount, and a session whose principal holds no data facet
%% finds /data answering eio (docs/design-stopgap.md, "/data for other domains").
%%
%% Then /apps, the start service's tree (docs/design-apps.md, "Interfaces"), only for a
%% session whose template the manifest grants apps: a session without the grant has no
%% /apps at all. The grant is in the ready answer, before the application starts.
start(_Type, _Args) ->
    ok = erx_ns:mount({facet, data}, <<"/data">>, [{tree, <<"data">>}, rw]),
    ok = mount_apps(erx:cap(apps)),
    erx_session_sup:start_link().

mount_apps(undefined) -> ok;
mount_apps(_Grant) -> erx_ns:mount({facet, apps}, <<"/apps">>, [{tree, <<"apps">>}, rw]).

stop(_State) ->
    ok.
