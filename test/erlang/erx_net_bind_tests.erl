%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_bind_tests).
-moduledoc """
An explicit bind's check, erx_net_bind:avail/2, rule by rule (docs/design-network-stack.md,
"Explicit binds"), the bind that runs it in erx_net_tables with its insertion,
erx_net_bind:bind/2, the deletion of a grant's entries at its end, and a listener's rewrite of its own entry, erx_net_bind:update/2, which
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
connection(Local) -> {{tcp, inet, Local, ?PORT, ?PEER, 40000}, self(), #{pid => self(), credit => c, grant => self()}}.
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

%% --- bind/2 and a grant's end ---------------------------------------------------------

bind_test_() ->
    {foreach,
     fun() ->
             {ok, Tables} = erx_net_tables:start_link(),
             unlink(Tables),
             Me = spawn(fun() -> receive stop -> ok end end),
             true = ets:insert(erx_net_addrs, {{Me, ?OURS}, Me, 0,
                                               #{addr => ?OURS, plen => 24, ifname => en0, flags => []}}),
             Tables
     end,
     fun(Tables) ->
             Ref = monitor(process, Tables),
             exit(Tables, kill),
             receive {'DOWN', Ref, _, _, _} -> ok end
     end,
     [{"a bind inserts its key and answers its port", fun a_bind_inserts_its_key/0},
      {"a bind meets the keys of its transport it overlaps", fun a_bind_meets_overlapping_keys/0},
      {"port 0 takes the first ephemeral port avail/2 allows", fun port_zero_is_checked_as_named/0},
      {"a bind for another process is refused", fun a_bind_for_another_process_is_refused/0},
      {"a grant's end deletes every entry naming it", fun a_grants_end_deletes_its_entries/0},
      {"a holder that ends after its bind leaves no entry", fun an_ended_holder_leaves_no_entry/0},
      {"a socket deletes only a key it holds", fun a_socket_deletes_only_its_own_key/0}]}.

an_ended_holder_leaves_no_entry() ->
    {G, _} = grants(),
    Self = self(),
    Pid = spawn(fun() -> Self ! {bound, erx_net_bind:bind(spec(udp, any, ?PORT),
                                                          #{pid => self(), credit => c, grant => G})}
                end),
    receive {bound, Bound} -> ?assertEqual({ok, ?PORT}, Bound) end,
    Ref = monitor(process, Pid),
    receive {'DOWN', Ref, _, _, _} -> ok end,
    _ = sys:get_state(erx_net_tables),
    ?assertEqual([], erx_net_tables:demux({udp, inet, any, ?PORT})).

a_socket_deletes_only_its_own_key() ->
    {_, H} = grants(),
    {ok, ?PORT} = bind_in_other(spec(udp, any, ?PORT), H),
    ok = erx_net_bind:delete({udp, inet, any, ?PORT}),
    ?assertMatch([#{grant := H}], erx_net_tables:demux({udp, inet, any, ?PORT})).

%% A bind of ?PORT on Local by the calling process for grant G.
spec(Transport, Local, Port) ->
    #{transport => Transport, family => inet, local => Local, port => Port, start => 10000,
      reuseaddr => false, reuseport => false, allowed => [{1024, 65535}]}.
entry(G) -> #{pid => self(), credit => c, grant => G}.

%% Binds in a process of its own, which stays until it gets stop.
bind_in_other(Spec, G) ->
    Self = self(),
    Pid = spawn(fun() -> Self ! {bound, self(), erx_net_bind:bind(Spec, #{pid => self(), credit => c, grant => G})},
                         receive stop -> ok end
                end),
    receive {bound, Pid, Result} -> Result end.

a_bind_inserts_its_key() ->
    {G, _} = grants(),
    ?assertEqual({ok, ?PORT}, erx_net_bind:bind(spec(tcp, ?OURS, ?PORT), entry(G))),
    ?assertEqual([entry(G)], erx_net_tables:demux({tcp_listen, inet, ?OURS, ?PORT})),
    ?assertEqual({error, eaddrnotavail}, erx_net_bind:bind(spec(tcp, ?PEER, ?PORT), entry(G))),
    ?assertEqual({error, eacces}, erx_net_bind:bind(spec(udp, any, 80), entry(G))).

a_bind_meets_overlapping_keys() ->
    {G, H} = grants(),
    {ok, ?PORT} = bind_in_other(spec(udp, any, ?PORT), H),
    ?assertEqual({error, eaddrinuse}, erx_net_bind:bind(spec(udp, ?OURS, ?PORT), entry(G))),
    ?assertEqual({error, eaddrinuse},
                 erx_net_bind:bind((spec(udp, ?OURS, ?PORT))#{reuseaddr := true}, entry(G))),
    %% A TCP listener never meets a UDP key.
    ?assertEqual({ok, ?PORT}, erx_net_bind:bind(spec(tcp, ?OURS, ?PORT), entry(G))).

port_zero_is_checked_as_named() ->
    {G, H} = grants(),
    Narrow = (spec(tcp, any, 0))#{allowed := [{20000, 20000}]},
    ?assertEqual({ok, 20000}, bind_in_other(Narrow, H)),
    ?assertEqual({error, eaddrnotavail}, erx_net_bind:bind(Narrow, entry(G))),
    ?assertEqual({error, eaddrnotavail}, erx_net_bind:bind(Narrow#{allowed := [{80, 1023}]}, entry(G))),
    {ok, Port} = erx_net_bind:bind((spec(tcp, any, 0))#{start := 20000}, entry(G)),
    ?assertEqual(20001, Port).

a_bind_for_another_process_is_refused() ->
    {G, _} = grants(),
    Other = #{pid => G, credit => c, grant => G},
    ?assertEqual({error, badarg}, erx_net_tables:bind(spec(tcp, any, ?PORT), Other)),
    ?assertEqual([], erx_net_tables:demux({tcp_listen, inet, any, ?PORT})).

a_grants_end_deletes_its_entries() ->
    G = spawn(fun() -> receive stop -> ok end end),
    {_, H} = grants(),
    ok = erx_net_tables:watch_grant(G),
    {ok, _} = erx_net_bind:bind(spec(tcp, any, ?PORT), entry(G)),
    ok = erx_net_bind:insert({tcp, inet, ?OURS, ?PORT, ?PEER, 40000}, self(), entry(G)),
    {ok, _} = erx_net_bind:bind(spec(udp, any, ?PORT), entry(H)),
    Ref = monitor(process, G),
    G ! stop,
    receive {'DOWN', Ref, _, _, _} -> ok end,
    _ = sys:get_state(erx_net_tables),
    ?assertEqual([], erx_net_tables:demux({tcp_listen, inet, any, ?PORT})),
    ?assertEqual([], erx_net_tables:demux({tcp, inet, ?OURS, ?PORT, ?PEER, 40000})),
    ?assertEqual([entry(H)], erx_net_tables:demux({udp, inet, any, ?PORT})).

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
