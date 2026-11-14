%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_bind_tests).
-moduledoc """
An explicit bind's check, erx_net_bind:avail/2, rule by rule (docs/design-network-stack.md,
"Explicit binds"), and a listener's rewrite of its own entry, erx_net_bind:update/2, which
replaces an entry only while its caller holds the key with the same credit and grant.
""".

-include_lib("eunit/include/eunit.hrl").

-define(OURS, <<10, 0, 2, 15>>).
-define(OTHER_ADDR, <<10, 0, 2, 16>>).
-define(PEER, <<10, 0, 2, 2>>).
-define(PORT, 8080).

%% A TCP listener's request on ?PORT, of grant G, on Local.
request(G, Local) -> request(G, Local, false).
request(G, Local, Reuse) ->
    #{transport => tcp, family => inet, local => Local, port => ?PORT, reuseaddr => Reuse,
      reuseport => false, grant => G, allowed => [{1024, 65535}], machine => [?OURS, ?OTHER_ADDR]}.

listener(G, Local) -> {{tcp_listen, inet, Local, ?PORT}, self(), #{pid => self(), credit => c, grant => G}}.
connection(Local) -> {{tcp, inet, Local, ?PORT, ?PEER, 40000}, self(), #{pid => self(), credit => c}}.
bound_udp(G, Local) -> {{udp, inet, Local, ?PORT}, self(), #{pid => self(), credit => c, grant => G}}.

grants() -> {spawn(fun() -> ok end), spawn(fun() -> ok end)}.

an_address_not_the_machines_is_refused_test() ->
    {G, _} = grants(),
    ?assertEqual({error, eaddrnotavail}, erx_net_bind:avail(request(G, ?PEER), [])),
    ?assertEqual(ok, erx_net_bind:avail(request(G, ?OURS), [])),
    ?assertEqual(ok, erx_net_bind:avail(request(G, any), [])).

a_port_outside_the_allowed_ranges_is_refused_test() ->
    {G, _} = grants(),
    Narrow = (request(G, any))#{allowed := [{9000, 9001}]},
    ?assertEqual({error, eacces}, erx_net_bind:avail(Narrow, [])),
    ?assertEqual({error, eacces}, erx_net_bind:avail((request(G, any))#{allowed := []}, [])),
    ?assertEqual({error, eacces}, erx_net_bind:avail((request(G, any))#{port := 80}, [])),
    ?assertEqual(ok, erx_net_bind:avail((request(G, any))#{allowed := [{80, 80}, {8080, 8080}]}, [])).

another_grants_listener_refuses_whatever_the_reuse_options_test() ->
    {G, H} = grants(),
    [?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, Mine, Reuse), [listener(H, Theirs)]))
     || {Mine, Theirs} <- [{?OURS, ?OURS}, {?OURS, any}, {any, ?OURS}, {any, any}], Reuse <- [false, true]],
    %% Distinct addresses of the machine do not overlap.
    ?assertEqual(ok, erx_net_bind:avail(request(G, ?OURS, true), [listener(H, ?OTHER_ADDR)])),
    ?assertEqual(ok, erx_net_bind:avail(request(G, ?OURS), [listener(H, ?OTHER_ADDR)])).

an_entry_naming_no_grant_counts_as_another_grants_test() ->
    {G, _} = grants(),
    NoGrant = {{tcp_listen, inet, any, ?PORT}, self(), #{pid => self(), credit => c}},
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, ?OURS, true), [NoGrant])).

without_reuse_any_overlapping_key_refuses_connections_included_test() ->
    {G, _} = grants(),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, ?OURS), [listener(G, any)])),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, any), [listener(G, ?OURS)])),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, any), [connection(?OURS)])),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, ?OURS), [connection(?OURS)])).

with_reuse_only_an_unconnected_key_on_the_same_address_refuses_test() ->
    {G, _} = grants(),
    ?assertEqual(ok, erx_net_bind:avail(request(G, ?OURS, true), [listener(G, any)])),
    ?assertEqual(ok, erx_net_bind:avail(request(G, any, true), [listener(G, ?OURS)])),
    ?assertEqual(ok, erx_net_bind:avail(request(G, ?OURS, true), [connection(?OURS)])),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, ?OURS, true), [listener(G, ?OURS)])),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(request(G, any, true), [listener(G, any)])),
    %% reuseport acts as reuseaddr: a second holder of one key is refused.
    Port = (request(G, any))#{reuseport := true},
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(Port, [listener(G, any)])),
    ?assertEqual(ok, erx_net_bind:avail(Port, [listener(G, ?OURS)])).

only_keys_of_the_transport_family_and_port_take_part_test() ->
    {G, H} = grants(),
    Others = [bound_udp(H, any), {{tcp_listen, inet6, any, ?PORT}, self(), #{grant => H}},
              {{tcp_listen, inet, any, ?PORT + 1}, self(), #{grant => H}},
              {{icmp, inet, 7}, self(), #{grant => H}}],
    ?assertEqual(ok, erx_net_bind:avail(request(G, any), Others)),
    %% A UDP bind meets UDP keys, and another grant's connected UDP key counts under rule 3.
    Udp = (request(G, any, true))#{transport := udp},
    Connected = {{udp, inet, ?OURS, ?PORT, ?PEER, 53}, self(), #{pid => self(), credit => c, grant => H}},
    ?assertEqual({error, eaddrinuse}, erx_net_bind:avail(Udp, [Connected])),
    ?assertEqual(ok, erx_net_bind:avail(Udp, [listener(H, ?OURS)])).

%% --- update/2 ---------------------------------------------------------------------

update_test_() ->
    {foreach,
     fun() -> ets:new(erx_net_demux, [named_table, public, set]) end,
     fun(Tab) -> ets:delete(Tab) end,
     [{"the holder rewrites its own entry, keeping pid, credit and grant",
       fun the_holder_rewrites_its_entry/0},
      {"a key deleted is not brought back", fun a_deleted_key_is_not_brought_back/0},
      {"a key held by another socket is left as it is", fun another_holders_key_is_left/0},
      {"an entry with another credit or grant is not replaced", fun another_credit_or_grant_is_left/0}]}.

-define(KEY, {tcp_listen, inet, any, ?PORT}).

the_holder_rewrites_its_entry() ->
    Entry = #{pid => self(), credit => c, grant => g, accept => #{nodelay => false}},
    true = ets:insert_new(erx_net_demux, {?KEY, self(), Entry}),
    New = Entry#{accept := #{nodelay => true}},
    ?assertEqual(ok, erx_net_bind:update(?KEY, New)),
    ?assertEqual([{?KEY, self(), New}], ets:lookup(erx_net_demux, ?KEY)).

a_deleted_key_is_not_brought_back() ->
    ?assertEqual(gone, erx_net_bind:update(?KEY, #{pid => self(), credit => c, grant => g})),
    ?assertEqual([], ets:lookup(erx_net_demux, ?KEY)).

another_holders_key_is_left() ->
    Other = spawn(fun() -> ok end),
    Held = {?KEY, Other, #{pid => Other, credit => c, grant => g}},
    true = ets:insert_new(erx_net_demux, Held),
    ?assertEqual(gone, erx_net_bind:update(?KEY, #{pid => self(), credit => c, grant => g})),
    ?assertEqual([Held], ets:lookup(erx_net_demux, ?KEY)).

another_credit_or_grant_is_left() ->
    Held = {?KEY, self(), #{pid => self(), credit => c, grant => g}},
    true = ets:insert_new(erx_net_demux, Held),
    ?assertEqual(gone, erx_net_bind:update(?KEY, #{pid => self(), credit => d, grant => g})),
    ?assertEqual(gone, erx_net_bind:update(?KEY, #{pid => self(), credit => c, grant => h})),
    ?assertEqual([Held], ets:lookup(erx_net_demux, ?KEY)).
