%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_session_app).
-moduledoc "The session application: the session's /data, /apps and /svc and its supervisor (erx_session_sup).".
-behaviour(application).

-export([start/2, stop/1]).

%% Each facet the session's template is granted or the session holds, once, that has a
%% place in the namespace (erx_ns:mount_facets/1), mounted before the application
%% starts its supervisor. The packages and system facets, which an app's session holds
%% for its own package, have no place, so neither has a mount point in its namespace;
%% what the session reaches through either, by erx:cap/1, its {erofs, app} mount or an
%% entry its own code puts in its table, is what the grant reaches
%% (docs/design-packaging.md, "An app's session").
%%
%% /data only for a session whose template the manifest grants data, which the ready
%% answer names (erx:granted/0) before the application starts: the storage domain's tree
%% through the session's data facet, which each lookup reads afresh, so a grant installed
%% later or re-granted after the storage domain restarts needs no remount. A session
%% without the grant has no /data mount and finds the root's empty /data directory
%% (docs/design-files.md, "A facet's mount").
%%
%% /svc, which shows the start service's tree (docs/design-apps.md, "Interfaces") and
%% the domain service's machine tree (docs/design-system.md, "A session's request") to
%% a session whose template the manifest grants them: their grants are in the ready
%% answer, before the application starts (erx:caps/0), and a session without one finds
%% no such name under /svc (docs/design-app-trees.md, "The namespace entry").
start(_Type, _Args) ->
    ok = erx_ns:mount_facets(lists:usort(erx:granted() ++ maps:keys(erx:caps()))),
    ok = mount_home(erx_session_sup:home()),
    erx_session_sup:start_link().

%% The session's home facet, which has no place of its own, at its user's home
%% (docs/design-files.md, "A user's home"); nothing for a session without one.
mount_home(none) -> ok;
mount_home({ok, {Point, Options}}) -> erx_ns:mount({facet, home}, Point, Options).

stop(_State) ->
    ok.
