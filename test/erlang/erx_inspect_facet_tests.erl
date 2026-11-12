%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the inspect facet (docs/design-live.md, "The inspect service"):
%% erx_inspect_query's decoder of a grantee's request, and erx_inspect_facet minted
%% as the domain service mints it, with fake agents for domains 10 and up and a view
%% the test controls in for the domain service's. This module stands in for the
%% export table: every name of the test's own node is the grantee's, so the test's
%% calls, and those of processes it spawns, are the grantee's.
-module(erx_inspect_facet_tests).
-include_lib("eunit/include/eunit.hrl").
-export([export/3, owner/1]).

-define(GRANTEE, 7).
-define(PRINCIPAL, 3).
-define(D, 10).

export(_Pid, [send], ?GRANTEE) -> ok.

owner(Name) when node(Name) =:= node() -> ?GRANTEE.

%%% The decoder.

%% The interface's two operations, with every segment shape and both options.
decoder_accepts_the_interfaces_requests_test() ->
    Paths = [[], [processes], [processes, {pid, 4, 0, 0}], [domains, 5, threads, 16#ffffffffffffffff],
             [processes, {pid, 16#ffffffff, 16#ffffffff, 16#ffffffff}], [kernel, log],
             [domains, binary:copy(<<"a">>, 765)], lists:duplicate(16, processes)],
    [?assertEqual({ok, {entries, Path}}, erx_inspect_query:decode({entries, Path})) || Path <- Paths],
    [?assertEqual({ok, {inspect, Path, Options}}, erx_inspect_query:decode({inspect, Path, Options}))
     || Path <- Paths, Options <- [#{}, #{offset => 0}, #{limit => 1000}, #{offset => 16#ffffffffffffffff, limit => 1}]].

%% Anything else is badarg: a path past 16 segments, improper or of another shape;
%% a segment out of its bounds, an atom no declared path holds, or a live pid; options
%% naming a scope or out of their bounds; an extra element or another operation.
decoder_refuses_everything_else_test() ->
    Refused = [{entries, lists:duplicate(17, processes)}, {entries, [processes | cpus]}, {entries, processes},
               {entries, [nothing_declared]}, {entries, [-1]}, {entries, [16#10000000000000000]},
               {entries, [processes, {pid, 16#100000000, 0, 0}]}, {entries, [processes, {pid, 4, -1, 0}]},
               {entries, [processes, self()]}, {entries, [binary:copy(<<"a">>, 766)]}, {entries, [1.0]},
               {inspect, [], #{scope => all}}, {inspect, [], #{offset => -1}}, {inspect, [], #{limit => 0}},
               {inspect, [], #{limit => 1001}}, {inspect, [], [{offset, 0}]}, {inspect, [], #{}, all},
               {entries, [], #{}}, {overview, []}, inspect, <<"inspect">>],
    [?assertEqual({error, badarg}, erx_inspect_query:decode(Request)) || Request <- Refused],
    ?assertEqual(erlang:system_info(atom_count),
                 begin _ = erx_inspect_query:decode({entries, [processes]}), erlang:system_info(atom_count) end).

%%% The facet.

%% A record of process N of domain D, as its agent gives it.
record(D, N) ->
    Id = {pid, D, N, 0},
    #{schema => erx_schema:schema(), path => [processes, Id], kind => process, id => Id,
      attrs => #{reductions => {runtime, {ok, N}}}, children => []}.

%% An agent of domain D that answers every question about one of its processes, or
%% stalls when told to.
agent(D, Mode) ->
    spawn(fun Loop() ->
                  receive
                      {erx_inspect_ask, Alias, {inspect, [processes, {pid, D, N, 0}], _}} when Mode =:= answer ->
                          Alias ! {erx_origin, D, {Alias, {ok, record(D, N)}}},
                          Loop();
                      _Question ->
                          Loop()
                  end
          end).

%% Holds until killed: the domain pid and the service process a facet ends with.
holder() ->
    spawn(fun() -> receive after infinity -> ok end end).

%% An inspect facet of Scope for ?GRANTEE whose workers read the view View(), or
%% none when View() is unavailable, and wait Wait milliseconds for an agent.
facet(Scope, View, Wait) ->
    {ok, Facet} = erx_facet:start(erx_inspect_facet,
                                  #{grantee => ?GRANTEE, ends_with => [holder(), holder()], in_flight => 2,
                                    scope => Scope,
                                    worker => #{view => fun(_ViewScope) -> view(View()) end, agent_wait => Wait}},
                                  #{exports => ?MODULE}),
    Facet.

view(unavailable) -> unavailable;
view(Domains) -> {ok, Domains}.

%% Request to Facet as the grantee's call arrives, and its answer, or none in Timeout.
call(Facet, Request, Timeout) ->
    Alias = alias(),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | Alias]}, Request}},
    receive {[alias | Alias], Reply} -> Reply after Timeout -> none end.

call(Facet, Request) -> call(Facet, Request, 2000).

%% A holder cannot widen its scope: a request naming a scope is refused before any
%% worker runs, and a release build's root session, of scope {principal, P}, gets
%% the answer of a path that names nothing for the kernel log.
a_holder_cannot_widen_its_scope_test() ->
    Facet = facet({principal, ?PRINCIPAL}, fun() -> [] end, 500),
    ?assertEqual({error, badarg}, call(Facet, {inspect, [kernel, log], #{scope => all}})),
    ?assertEqual({error, badarg}, call(Facet, {entries, [processes], all})),
    ?assertEqual({error, scope}, call(Facet, {inspect, [kernel, log], #{}})),
    ?assertEqual({error, scope}, call(Facet, {inspect, [processes, erx_inspector:proc_id(self())], #{}})).

%% A principal's scope follows its domains: a domain the view admits for the principal
%% after the mint is in scope from then on, while a domain of another principal, which
%% the view leaves out, and an id never used answer alike.
a_principals_scope_follows_its_domains_test() ->
    Domains = ets:new(domains, [public]),
    View = fun() -> ets:tab2list(Domains) end,
    Facet = facet({principal, ?PRINCIPAL}, View, 500),
    Agent = agent(?D, answer),
    Path = [processes, {pid, ?D, 5, 0}],
    ?assertEqual({error, scope}, call(Facet, {inspect, Path, #{}})),
    true = ets:insert(Domains, {?D, Agent}),
    ?assertMatch({ok, #{id := {pid, ?D, 5, 0}, attrs := #{reductions := {runtime, {ok, 5}}}}},
                 call(Facet, {inspect, Path, #{}})),
    Other = agent(?D + 1, answer),
    ?assertEqual({error, scope}, call(Facet, {inspect, [processes, {pid, ?D + 1, 5, 0}], #{}})),
    ?assertEqual({error, scope}, call(Facet, {inspect, [processes, {pid, ?D + 99, 5, 0}], #{}})),
    [exit(Pid, kill) || Pid <- [Agent, Other]],
    ets:delete(Domains).

%% A principal's scope the worker cannot resolve, the domain service not answering,
%% is a failed query, never the answer of a path that names nothing: the grantee's
%% own process does not read as gone while the service is busy.
an_unknown_principals_scope_fails_the_query_test() ->
    Facet = facet({principal, ?PRINCIPAL}, fun() -> unavailable end, 500),
    ?assertEqual({error, failed}, call(Facet, {inspect, [processes, {pid, ?D, 5, 0}], #{}})),
    ?assertEqual({error, failed}, call(Facet, {inspect, [processes], #{}})),
    ?assertEqual({error, failed}, call(Facet, {entries, [processes]})).

%% An agent that never answers holds up no other query: while one query of the facet
%% waits on it, a second query of the same facet, and one of another holder's facet,
%% answer at their usual time.
a_stalled_agent_holds_up_no_other_query_test() ->
    Stalling = agent(?D, stall),
    View = fun() -> [{?D, Stalling}] end,
    Facet = facet(all, View, 1500),
    Other = facet(all, View, 1500),
    Self = self(),
    _ = spawn(fun() -> Self ! {stalled, call(Facet, {inspect, [processes, {pid, ?D, 5, 0}], #{}}, 3000)} end),
    timer:sleep(100),
    Start = erlang:monotonic_time(millisecond),
    Local = {inspect, [processes, erx_inspector:proc_id(self())], #{}},
    ?assertMatch({ok, #{kind := process}}, call(Facet, Local, 1000)),
    ?assertMatch({ok, #{kind := process}}, call(Other, Local, 1000)),
    ?assert(erlang:monotonic_time(millisecond) - Start < 1000),
    ?assertMatch({stalled, {ok, #{attrs := #{reductions := {runtime, {timeout, 1500}}}}}},
                 receive {stalled, _} = Stalled -> Stalled after 3000 -> none end),
    exit(Stalling, kill).

%% A worker ends with its facet: revoking the grant leaves no worker asking agents.
a_worker_ends_with_its_facet_test() ->
    Stalling = agent(?D, stall),
    Domain = holder(),
    {ok, Facet} = erx_facet:start(erx_inspect_facet,
                                  #{grantee => ?GRANTEE, ends_with => [Domain], scope => all,
                                    worker => #{view => fun(_) -> {ok, [{?D, Stalling}]} end, agent_wait => 5000}},
                                  #{exports => ?MODULE}),
    Before = erlang:processes(),
    Facet ! {erx_origin, ?GRANTEE, {'$gen_call', {self(), [alias | alias()]}, {inspect, [processes, {pid, ?D, 5, 0}], #{}}}},
    timer:sleep(100),
    [Worker] = erlang:processes() -- Before,
    Monitor = monitor(process, Worker),
    exit(Domain, kill),
    ?assertMatch({'DOWN', Monitor, process, Worker, _}, receive {'DOWN', Monitor, _, _, _} = Down -> Down after 1000 -> none end),
    exit(Stalling, kill).
