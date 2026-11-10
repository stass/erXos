%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain_facet).
-moduledoc """
The facet the domain service mints for a domain in front of each process a
create's spec names under facets (docs/design-domains.md, "Facets", "Handing
a facet on"): an erx_facet bound to the new domain that forwards every
request and every message it admits to the process behind it, and ends when
the domain or that process ends. It admits no more than the process behind it
does; a narrower grant is a callback of its own. It implements erx_facet's
callbacks without naming the behaviour, which erx_domain's build, with erx's
modules not on its path, cannot load.
""".

-export([init/1, admit/3, message/2]).

init(#{behind := Behind}) when is_pid(Behind) ->
    {ok, Behind}.

admit(Request, _From, Behind) ->
    {forward, Behind, Request, Behind}.

message(_Message, Behind) ->
    {forward, Behind, Behind}.
