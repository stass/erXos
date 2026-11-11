%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_line_app).
-moduledoc """
The line application: a session's line to the web domain, erx_web_line,
and nothing else. The session's boot script starts it, so the line is up
before init's ready report, and the application names the line as
`web_line` among the report's provides (erx_facet:provide/2): the domain
service keeps it for erx_domain:web_line/2, which hands it to the web
domain when the host opens its `web` facet. The line is the application's
one process, and the boot script starts the application permanent, so the
line and the session domain end together (docs/design-web.md, "Views on
the line"). A runtime that reports nothing, the system domain's or a
host's, takes the name and passes it on to no one.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Line} = erx_web_line:start_link(#{}),
    ok = erx_facet:provide(web_line, Line),
    {ok, Line}.

stop(_State) ->
    ok.
