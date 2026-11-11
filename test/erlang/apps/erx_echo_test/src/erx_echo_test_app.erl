%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_echo_test_app).
-moduledoc """
The test-only application erx_echo_test, which only a test image's domain boot
script boots (tools/lib/erx/erlang_apps.rb, TEST_ONLY), for the system_domain
suite's echo checkpoint (tools/lib/erx/system_domain.rb). As it starts, before
init's ready report, it names its mint for the service echo with
erx_facet:provide/2, and adds to the report's provides two entries the domain
service must refuse (docs/design-system.md, "Facets a configured domain
serves"): relay, mapped to the system domain's domain pid, a mint this domain
does not own, and stray, a name no service row declares. provide/2 refuses
relay, so it is written into the provides term directly, as a domain whose
code is hostile could, and stray beside it.
""".
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    Mint = spawn_link(erx_echo_test, mint, []),
    ok = erx_facet:provide(echo, Mint),
    {_Id, {_SystemId, _SystemNode, DomainPid}} = erx_dist:boot(),
    Provides = persistent_term:get({erx, provides}),
    persistent_term:put({erx, provides}, Provides#{relay => DomainPid, stray => Mint}),
    {ok, Mint}.

stop(_State) ->
    ok.
