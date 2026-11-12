%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the runtime agent (docs/design-live.md, "The runtime agent"):
%% it answers only the system domain's envelope, and only about its own domain.
-module(erx_inspect_agent_tests).
-include_lib("eunit/include/eunit.hrl").

%% The system domain's id as these cases see it: any id but the agent's own, which on the
%% host is the id the host runtime takes for the system domain.
-define(SYSTEM, 2).

%% The domain this host runtime names its own processes with.
self_domain() ->
    {pid, Domain, _Number, _Serial} = erx_inspector:proc_id(self()),
    Domain.

ask(Origin, Alias, Query) -> {erx_origin, Origin, {erx_inspect_ask, Alias, Query}}.

%% Only a question in the system domain's envelope, to a reference, is answered;
%% another domain's, a bare one and one with no alias are dropped.
answers_only_the_system_domain_test() ->
    Self = self_domain(),
    Alias = make_ref(),
    Query = {entries, [processes]},
    ?assertMatch({reply, Alias, {_, [_ | _]}}, erx_inspect_agent:handle(ask(?SYSTEM, Alias, Query), Self, ?SYSTEM)),
    [?assertEqual(drop, erx_inspect_agent:handle(Message, Self, ?SYSTEM))
     || Message <- [ask(Self, Alias, Query), ask(9, Alias, Query), {erx_inspect_ask, Alias, Query},
                    ask(?SYSTEM, self(), Query), ask(?SYSTEM, Alias, Query, extra), {Alias, ok}]].

ask(Origin, Alias, Query, Extra) -> {erx_origin, Origin, {erx_inspect_ask, Alias, Query, Extra}}.

%% The running agent answers the system domain's question to its alias, and drops
%% and counts another domain's, which gets no answer.
running_agent_answers_the_system_domain_test() ->
    Self = self_domain(),
    {ok, Agent} = erx_inspect_agent:start_link(Self, ?SYSTEM),
    try
        Foreign = alias([reply]),
        Agent ! ask(9, Foreign, {entries, [processes]}),
        Asked = alias([reply]),
        Agent ! ask(?SYSTEM, Asked, {inspect, [processes, erx_inspector:proc_id(self())], #{}}),
        receive {Asked, Answer} -> ?assertMatch({ok, #{kind := process}}, Answer)
        after 5000 -> ?assert(false)
        end,
        receive {Foreign, _} -> ?assert(false) after 100 -> ok end,
        ?assertMatch({dictionary, #{dropped := 1}}, dictionary(Agent))
    after
        unlink(Agent),
        exit(Agent, kill)
    end.

dictionary(Pid) ->
    {dictionary, Pairs} = process_info(Pid, dictionary),
    {dictionary, maps:from_list(Pairs)}.

%% A runtime describes only itself: another domain's process and domain, the
%% machine's paths and another listing are {error, scope}.
answers_another_domains_path_scope_test() ->
    Self = self_domain(),
    Other = Self + 1,
    [?assertEqual({error, scope}, erx_inspect_agent:answer(Query, Self))
     || Query <- [{inspect, [processes, {pid, Other, 1, 0}], #{}}, {inspect, [domains, Other], #{}},
                  {inspect, [domains, Other, group], #{}}, {inspect, [], #{}}, {inspect, [kernel, log], #{}},
                  {entries, [cpus]}, {entries, [domains, Other, threads]}, {inspect, [processes], #{}},
                  {inspect, [processes, {pid, Self, 1, 0}], not_a_map}, nonsense]].

%% Its own process and every path below it are its own; its own processes are
%% the listing it answers.
answers_paths_below_its_processes_test() ->
    Self = self_domain(),
    Me = erx_inspector:proc_id(self()),
    ?assert(erx_inspect_agent:owns([processes, Me], Self)),
    ?assert(erx_inspect_agent:owns([processes, Me, source], Self)),
    ?assert(erx_inspect_agent:owns([domains, Self, processes], Self)),
    ?assertNot(erx_inspect_agent:owns([processes, {pid, Self + 1, 1, 0}, source], Self)),
    ?assertMatch({ok, #{kind := process}}, erx_inspect_agent:answer({inspect, [processes, Me], #{}}, Self)),
    {_, Records} = erx_inspect_agent:answer({entries, [processes]}, Self),
    ?assert(lists:any(fun(#{id := Id}) -> Id =:= Me end, Records)).
