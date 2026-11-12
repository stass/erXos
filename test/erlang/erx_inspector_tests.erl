%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The inspector's process records, scopes and renderers (docs/design-live.md,
%% "Inspection", V2 and V9): each process attribute from a constructed
%% process_info answer, with a seed that flips its status; the scope rules
%% for paths and attributes; every status and reporter as erx_render prints
%% it, each with a seed that changes the record and must change the text;
%% hostile names through the line escape; erx:i/0's overview within 80
%% columns; and every process named as data, by its proc_id() (V10).
-module(erx_inspector_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(SYSTEM, 4).

%%% Process records

info() ->
    [{status, waiting}, {priority, normal}, {reductions, 120},
     {current_location, {gen_server, loop, 7, [{file, "gen_server.erl"}, {line, 2405}]}},
     {heap_size, 233}, {stack_size, 9}, {message_queue_len, 2}, {registered_name, worker},
     {group_leader, self()}, {trap_exit, true}, {links, [self()]}, {monitors, [{process, self()}]}].

%% This runtime's proc_id() of its own process: the system domain's on a host.
me() -> erx_inspector:proc_id(self()).

attrs(Info) ->
    {ok, #{attrs := Attrs}} = erx_process_records:record(self(), Info, ?SYSTEM),
    Attrs.

with(Key, Value) -> lists:keystore(Key, 1, info(), {Key, Value}).

every_attribute_is_runtime_ok_but_the_domain_test() ->
    Attrs = attrs(info()),
    {ok, Keys} = erx_schema:attributes(process),
    ?assertEqual(lists:sort(Keys), lists:sort(maps:keys(Attrs))),
    ?assertEqual({service, {ok, ?SYSTEM}}, maps:get(domain, Attrs)),
    ?assertEqual({runtime, {ok, waiting}}, maps:get(state, Attrs)),
    ?assertEqual({runtime, {ok, <<"worker">>}}, maps:get(registered_name, Attrs)),
    ?assertEqual({runtime, {ok, {<<"gen_server">>, <<"loop">>, 7, <<"gen_server.erl">>, 2405}}},
                 maps:get(location, Attrs)),
    ?assert(lists:all(fun({runtime, {ok, _}}) -> true; ({service, {ok, _}}) -> true; (_) -> false end,
                      maps:values(Attrs))).

no_registered_name_is_empty_test() ->
    ?assertEqual({runtime, {ok, <<>>}}, maps:get(registered_name, attrs(with(registered_name, [])))).

location_without_position_test() ->
    Attrs = attrs(with(current_location, {erlang, hibernate, 3, []})),
    ?assertEqual({runtime, {ok, {<<"erlang">>, <<"hibernate">>, 3, <<>>, 0}}}, maps:get(location, Attrs)).

link_to_a_port_is_partial_test() ->
    [Port | _] = erlang:ports(),
    ?assertEqual({runtime, {ok, [me()]}}, maps:get(links, attrs(info()))),
    ?assertEqual({runtime, {partial, [me()]}}, maps:get(links, attrs(with(links, [self(), Port])))).

links_beyond_the_bound_are_partial_test() ->
    Pids = lists:duplicate(1001, self()),
    ?assertEqual({runtime, {ok, lists:duplicate(1000, me())}},
                 maps:get(links, attrs(with(links, lists:sublist(Pids, 1000))))),
    ?assertEqual({runtime, {partial, lists:duplicate(1000, me())}},
                 maps:get(links, attrs(with(links, Pids)))).

monitor_of_a_name_is_partial_test() ->
    Named = [{process, self()}, {process, {logger, node()}}],
    ?assertEqual({runtime, {partial, [me()]}}, maps:get(monitors, attrs(with(monitors, Named)))).

%% docs/design-live.md, V10: the record names its process, its group leader, its
%% links and its monitors by proc_id(), and holds no pid anywhere. A pid of another
%% domain is the domain its text names.
names_are_proc_ids_test() ->
    {ok, #{path := Path, id := Id, attrs := Attrs}} = erx_process_records:record(self(), info(), ?SYSTEM),
    ?assertEqual({[processes, me()], me()}, {Path, Id}),
    ?assertEqual({runtime, {ok, me()}}, maps:get(group_leader, Attrs)),
    "<" ++ Text = pid_to_list(self()),
    [_, N, S] = string:lexemes(Text, ".>"),
    ?assertEqual({pid, ?SYSTEM, list_to_integer(N), list_to_integer(S)}, me()),
    ?assertEqual({pid, 7, 1, 0}, erx_process_records:proc_id(foreign_pid(), ?SYSTEM)).

%% Seeded (V10): a collector that put the live group leader into the record has it
%% refused whole by the validation, so no name leaves in a record.
a_live_group_leader_is_refused_test() ->
    {ok, #{attrs := Attrs} = Record} = erx_process_records:record(self(), info(), ?SYSTEM),
    Seeded = Record#{attrs := Attrs#{group_leader := {runtime, {ok, group_leader()}}}},
    ?assertEqual({error, name}, erx_schema:validate_record(Seeded)).

%% A pid of an earlier run of this node, its name but another creation, prints as
%% a local pid of the same numbers yet is another process: it is named by its own
%% creation, never as the live process of this runtime that has those numbers.
an_earlier_run_of_this_node_is_not_this_runtime_test() ->
    <<131, Node/binary>> = term_to_binary(node()),
    Creation = erlang:system_info(creation) + 1,
    Earlier = binary_to_term(<<131, 88, Node/binary, 1:32, 0:32, Creation:32>>),
    ?assertEqual(node(), node(Earlier)),
    ?assertEqual({pid, Creation, 1, 0}, erx_process_records:proc_id(Earlier, ?SYSTEM)).

%% A proc_id() is this runtime's pid only when it names this runtime's domain and
%% numbers it prints as; any other is no pid here.
proc_id_back_to_its_pid_test() ->
    {pid, _, N, S} = me(),
    ?assertEqual({ok, self()}, erx_process_records:local_pid(me(), ?SYSTEM)),
    ?assertEqual(error, erx_process_records:local_pid(me(), 5)),
    ?assertEqual(error, erx_process_records:local_pid({pid, 5, N, S}, ?SYSTEM)),
    ?assertEqual(error, erx_process_records:local_pid({pid, ?SYSTEM, 1 bsl 32, S}, ?SYSTEM)),
    ?assertEqual(error, erx_process_records:local_pid({pid, ?SYSTEM, -1, S}, ?SYSTEM)),
    ?assertEqual(error, erx_process_records:local_pid(self(), ?SYSTEM)).

name_longer_than_the_schema_is_invalid_test() ->
    Long = list_to_atom(lists:duplicate(200, 16#e9)),
    ?assertEqual({runtime, {error, invalid}}, maps:get(registered_name, attrs(with(registered_name, Long)))).

gone_process_is_no_record_test() ->
    ?assertEqual(none, erx_process_records:record(self(), undefined, ?SYSTEM)).

live_process_record_test() ->
    {ok, #{path := Path, attrs := Attrs}} = erx_process_records:process(self(), ?SYSTEM),
    ?assertEqual([processes, me()], Path),
    ?assertMatch({runtime, {ok, running}}, maps:get(state, Attrs)).

%%% Scopes

foreign_pid() ->
    binary_to_term(<<131, 88, 119, 9, "erx@other", 1:32, 0:32, 7:32>>).

reachable(Path, Scope) -> erx_inspector:declared_reachable(Path, erx_schema:resolve(Path), Scope).

machine_paths_need_scope_all_test() ->
    ?assertEqual({ok, machine}, reachable([], [5])),
    ?assertEqual({ok, machine}, reachable([cpus], all)),
    ?assertEqual(error, reachable([cpus], [?SYSTEM])),
    ?assertEqual(error, reachable([cpus, 0], [?SYSTEM])),
    ?assertEqual(error, reachable([budgets], [?SYSTEM])).

domain_paths_need_their_domain_test() ->
    ?assertEqual({ok, {domain, ?SYSTEM}}, reachable([domains, ?SYSTEM, budget], [?SYSTEM])),
    ?assertEqual(error, reachable([domains, ?SYSTEM, budget], [5])),
    ?assertEqual({ok, {domain, ?SYSTEM}}, reachable([processes, me()], [?SYSTEM])),
    ?assertEqual(error, reachable([processes, me()], [5])),
    ?assertEqual({ok, {domain, 9}}, reachable([processes, {pid, 9, 1, 0}], [9])),
    ?assertEqual(error, reachable([processes, self()], all)).

unknown_and_unreachable_paths_answer_as_scope_test() ->
    ?assertEqual(error, reachable([nothing], all)),
    ?assertEqual(error, reachable([processes, {pid, 0, 1 bsl 32, 0}], all)),
    ?assertEqual({error, scope}, erx_inspector:inspect([processes, {pid, 9, 1, 0}], all, #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([processes, self()], all, #{})),
    %% A caller of domain 5 that writes 5 for this runtime's domain in a process's
    %% proc_id() reaches no process of this runtime.
    {pid, ?SYSTEM, N, S} = me(),
    ?assertEqual({error, scope}, erx_inspector:inspect([processes, {pid, 5, N, S}], [5], #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([cpus], [?SYSTEM], #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([domains, 9, budget], all, #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([nothing], all, #{})).

dead_process_answers_as_scope_test() ->
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    ?assertEqual({error, scope}, erx_inspector:inspect([processes, erx_inspector:proc_id(Pid)], all, #{})).

uncollected_path_is_unsupported_test() ->
    ?assertEqual({error, unsupported}, erx_inspector:inspect([groups], all, #{})),
    ?assertEqual({error, unsupported}, erx_inspector:entries([domains], all)).

process_paths_test() ->
    {ok, #{kind := process, id := Me}} = erx_inspector:inspect([processes, me()], all, #{}),
    ?assertEqual(me(), Me),
    {ok, #{kind := listing, children := Children}} = erx_inspector:inspect([processes], all, #{}),
    ?assert(lists:member(me(), Children)),
    {ok, Records} = erx_inspector:entries([processes], all),
    ?assert(lists:any(fun(#{id := Id}) -> Id =:= me() end, Records)),
    ?assertEqual({ok, []}, erx_inspector:entries([processes], [5])).

machine() ->
    {ok, Machine} = erx_kernel_records:record(machine, [], 0, {error, ?ERX_ENOTSUP}, 0),
    Machine.

scoped_record_keeps_what_the_scope_sees_test() ->
    #{attrs := All} = erx_inspector:scoped(machine(), machine, all),
    #{attrs := Scoped} = erx_inspector:scoped(machine(), machine, [?SYSTEM]),
    ?assertEqual(9, map_size(All)),
    ?assertEqual([build, cpus_online, development, dma_profile, memory_free, memory_total, uptime],
                 lists:sort(maps:keys(Scoped))),
    Process = maps:get(attrs, element(2, erx_process_records:record(self(), info(), ?SYSTEM))),
    Record = #{kind => process, attrs => Process},
    ?assertEqual(Process, maps:get(attrs, erx_inspector:scoped(Record, {domain, ?SYSTEM}, [?SYSTEM]))),
    ?assertEqual(#{}, maps:get(attrs, erx_inspector:scoped(Record, {domain, ?SYSTEM}, [5]))).

%%% Renderers

process_record(Attrs) ->
    #{schema => 1, path => [processes, me()], kind => process, id => me(),
      attrs => Attrs, children => []}.

rendered(Attr) ->
    iolist_to_binary(erx_render:record(process_record(#{reductions => Attr}), release)).

%% Each status prints as itself beside its reporter, never as a number or a
%% blank, and flipping the status or the reporter changes the line.
each_status_renders_as_itself_test_() ->
    Cases = [{{ok, 42}, <<"42">>}, {{partial, 42}, <<"[partial]">>}, {unknown, <<"[unknown]">>},
             {unsupported, <<"[unsupported]">>}, {{timeout, 500}, <<"[timeout 500]">>},
             {{error, invalid}, <<"[error]">>}],
    [?_test(begin
                Text = rendered({runtime, Value}),
                ?assertMatch({match, _}, re:run(Text, <<"reductions  runtime  \\Q", Shown/binary, "\\E\n">>)),
                ?assertNotEqual(Text, rendered({service, Value})),
                [?assertNotEqual(Text, rendered({runtime, Other})) || {Other, _} <- Cases, Other =/= Value]
            end) || {Value, Shown} <- Cases].

stopgap_reporter_is_named_with_its_scope_test() ->
    Reported = ?ERX_INFO_BUDGET_REPORTED_KIND bor ?ERX_INFO_BUDGET_REPORTED_GUARANTEE
        bor ?ERX_INFO_BUDGET_REPORTED_CAP bor ?ERX_INFO_BUDGET_REPORTED_CARVED
        bor ?ERX_INFO_BUDGET_REPORTED_LENT,
    Report = <<0:32/little, Reported:32/little, 100:64/little, 400:64/little, 30:64/little,
               20:64/little, 10:64/little, 0:64/little>>,
    {ok, Budget} = erx_kernel_records:record(budget, [domains, ?SYSTEM, budget], 0, {ok, Report},
                                             ?ERX_INFO_BUDGET_REPORTED_USED),
    Text = iolist_to_binary(erx_render:record(Budget, release)),
    ?assertMatch({match, _}, re:run(Text, <<"\n  used +root pool  \\[partial\\]\n">>)),
    ?assertMatch({match, _}, re:run(Text, <<"\n  spending +root pool  \\[unknown\\]\n">>)),
    ?assertMatch({match, _}, re:run(Text, <<"\n  guarantee +kernel +100\n">>)),
    ?assertMatch({match, _}, re:run(Text, <<"\nroot pool: pages of the root's pool:">>)),
    {ok, Exact} = erx_kernel_records:record(budget, [domains, ?SYSTEM, budget], 0, {ok, Report}, 0),
    ?assertEqual(nomatch, re:run(iolist_to_binary(erx_render:record(Exact, release)), <<"liberx">>)).

hostile_names() ->
    [<<"evil", 16#1b, "[2J", 16#1b, "]0;title", 7>>, <<"rtl", 16#e2, 16#80, 16#ae, "txt">>,
     <<"c1", 16#c2, 16#9b, "31m">>, <<"bad", 16#ff, 16#fe, "utf8">>, <<"over", 16#c0, 16#af>>,
     <<"line", $\n, "break", $\r, $\t>>, <<"zw", 16#e2, 16#80, 16#8b, "sp">>].

%% No byte of a rendering is a control but its newlines, and no bidi
%% override, C1 control or invalid UTF-8 survives.
assert_clean(Text) ->
    ?assertEqual(nomatch, re:run(Text, <<"[\\x00-\\x09\\x0b-\\x1f\\x7f]">>)),
    ?assertMatch(Chars when is_binary(Chars), unicode:characters_to_binary(Text)),
    Chars = unicode:characters_to_list(Text),
    ?assertEqual([], [C || C <- Chars, C >= 16#80, C =< 16#9f]),
    ?assertEqual([], [C || C <- Chars, C >= 16#200b, C =< 16#200f]),
    ?assertEqual([], [C || C <- Chars, C >= 16#202a, C =< 16#202e]).

hostile_names_are_escaped_test_() ->
    [?_test(begin
                Attrs = #{registered_name => {runtime, {ok, Name}},
                          location => {runtime, {ok, {Name, Name, 0, Name, 1}}}},
                Record = process_record(Attrs),
                Single = iolist_to_binary(erx_render:record(Record, release)),
                assert_clean(Single),
                ?assertEqual(4, length(binary:matches(Single, <<"\n">>))),
                Overview = iolist_to_binary(erx_render:overview([{[processes], {ok, [Record]}}], release)),
                assert_clean(Overview)
            end) || Name <- hostile_names()].

hostile_path_segment_is_escaped_test() ->
    Record = #{schema => 1, path => [domains, 4, modules, hd(hostile_names())], kind => module,
               id => x, attrs => #{}, children => []},
    assert_clean(iolist_to_binary(erx_render:record(Record, release))).

overview_shows_error_statuses_test() ->
    Text = iolist_to_binary(erx_render:overview([{[groups], {error, unsupported}},
                                                 {[cpus], {error, scope}}], release)),
    ?assertEqual(<<"/groups  [unsupported]\n/cpus  [error]\n">>, Text).

overview_names_a_cells_own_reporter_test() ->
    {ok, A} = erx_process_records:record(self(), info(), ?SYSTEM),
    B = A#{id := {pid, ?SYSTEM, 1, 0},
           attrs := (maps:get(attrs, A))#{reductions := {service, {ok, 7}}}},
    Text = iolist_to_binary(erx_render:overview([{[processes], {ok, [A, B]}}], release)),
    ?assertMatch({match, _}, re:run(Text, <<"\n  by +runtime +runtime +runtime">>)),
        ?assertMatch({match, _}, re:run(Text, <<"\\(service\\) 7">>)).

status_cells_are_never_cut_test() ->
    {ok, A} = erx_process_records:record(self(), info(), ?SYSTEM),
    Name = list_to_binary(lists:duplicate(60, $n)),
    B = A#{attrs := (maps:get(attrs, A))#{state := {runtime, {ok, garbage_collecting}},
                                          registered_name := {runtime, {ok, Name}},
                                          location := {runtime, {timeout, 500}}}},
    Text = iolist_to_binary(erx_render:overview([{[processes], {ok, [B]}}], release)),
    ?assertMatch({match, _}, re:run(Text, <<"\\[timeout 500\\]\n">>)).

machine_paths_are_closed_to_scoped_callers_test() ->
    ?assertEqual(error, reachable([domains], [?SYSTEM])),
    ?assertEqual({ok, machine}, reachable([domains], all)),
    ?assertEqual({ok, machine}, reachable([processes], [?SYSTEM])).

repeated_thread_makes_a_partial_listing_test() ->
    Report = fun(Id) -> {ok, <<Id:64/little, 0:32/little, 0:32/little, 0:32/little, 0:32/little>>} end,
    Answers = fun(0) -> Report(10); (1) -> Report(10); (2) -> Report(12);
                 (_) -> {error, ?ERX_ERANGE} end,
    Path = [domains, ?SYSTEM, threads],
    Listed = erx_kernel_records:listing(thread, Answers, 0, 128),
    ?assertMatch({ok, #{children := {partial, [10, 12]}}}, erx_inspector:listing(Path, Listed)),
    Once = erx_kernel_records:listing(thread, fun(1) -> Report(11); (N) -> Answers(N) end, 0, 128),
    ?assertMatch({ok, #{children := [10, 11, 12]}}, erx_inspector:listing(Path, Once)).

%% The overview of a machine whose kernel answers nothing, with this node's
%% processes and a process whose name is as long as the schema allows,
%% fits 80 columns on every line.
overview_fits_80_columns_test() ->
    Long = list_to_atom(lists:duplicate(255, $n)),
    Pid = spawn(fun() -> receive stop -> ok end end),
    true = register(Long, Pid),
    Threads = erx_kernel_records:listing(thread, fun(Index) when Index < 3 ->
                                                         {ok, <<Index:64/little, 1:32/little, 2:32/little,
                                                                3:32/little, 0:32/little>>};
                                                    (_) -> {error, ?ERX_ERANGE}
                                                 end, 0, 128),
    Sections = [{[], {ok, machine()}},
                {[cpus], erx_kernel_records:listing(cpu, fun(0) -> {error, ?ERX_ENOTSUP};
                                                            (_) -> {error, ?ERX_ERANGE}
                                                         end, 0, 64)},
                {[domains, ?SYSTEM, group], {error, unsupported}},
                {[domains, ?SYSTEM, threads], Threads},
                {[processes], erx_inspector:entries([processes], all)}],
    Text = iolist_to_binary(erx_render:overview(Sections, development)),
    Pid ! stop,
    Lines = binary:split(Text, <<"\n">>, [global, trim]),
    ?assert(length(Lines) > 20),
    ?assertEqual([], [Line || Line <- Lines, string:length(Line) > 80]),
    ?assertMatch({match, _}, re:run(Text, <<"nnnnnnnnnnnnnnnnn\\.\\.\\.">>)).

%%% The session's facet and the domain record

%% A development host's runtime stands for the system domain, which is
%% handed no facet and asks its own query worker at scope `all`.
a_development_host_is_the_system_domain_test() ->
    ?assert(erx_facets:system()),
    ?assertEqual(#{}, erx_facets:domain()),
    ?assertMatch({ok, #{kind := domain}}, erx_inspector:inspect([domains, ?SYSTEM])).

%% Outside the system domain a query goes to the domain's inspect facet as
%% it is, never to a local core at a scope of the runtime's own: a domain
%% without the facet is answered `no_facet`, even for a path of its own,
%% and one with the facet gets the facet's answer.
a_domain_asks_only_through_its_facet_test() ->
    Own = [domains, ?SYSTEM],
    ?assertEqual({error, no_facet}, erx_inspector:route(false, undefined, {inspect, Own, #{}})),
    ?assertEqual({error, no_facet}, erx_inspector:route(false, undefined, {entries, [processes]})),
    Facet = spawn_link(fun() -> receive {'$gen_call', From, Query} -> gen:reply(From, {asked, Query}) end end),
    Ended = monitor(process, Facet),
    ?assertEqual({asked, {inspect, Own, #{offset => 3}}},
                 erx_inspector:route(false, Facet, {inspect, Own, #{offset => 3}})),
    receive {'DOWN', Ended, process, Facet, _} -> ok end,
    ?assertEqual({error, no_facet}, erx_inspector:route(false, Facet, {entries, [processes]})).

%% A facet that has ended, as a revoked one does, admits no query: the
%% domain holds no facet from then on (design-live.md, "The /proc tree").
%% One that ends while it holds a query, and so never answers it, fails
%% that query alone.
an_ended_facet_is_no_facet_test() ->
    Dead = spawn(fun() -> ok end),
    Gone = monitor(process, Dead),
    receive {'DOWN', Gone, process, Dead, _} -> ok end,
    ?assertEqual({error, no_facet}, erx_inspector:route(false, Dead, {inspect, [], #{}})),
    Ending = spawn(fun() -> receive {'$gen_call', _From, _Query} -> exit(revoked) end end),
    ?assertEqual({error, failed}, erx_inspector:route(false, Ending, {inspect, [], #{}})).

%% The system domain's record carries this runtime's figures, its run queue
%% among them, and the domain service's and the kernel's, which have no
%% collector here, as unsupported; a scope without the domain gets nothing.
domain_record_test() ->
    {ok, #{kind := domain, attrs := Attrs, children := Children}} = erx_inspector:inspect([domains, ?SYSTEM], all, #{}),
    ?assertMatch({runtime, {ok, N}} when is_integer(N), maps:get(run_queue, Attrs)),
    ?assertMatch({runtime, {ok, P}} when P > 0, maps:get(processes, Attrs)),
    ?assertEqual({service, unsupported}, maps:get(name, Attrs)),
    ?assertEqual({kernel, unsupported}, maps:get(threads, Attrs)),
    ?assert(lists:member(budget, Children)),
    ?assertEqual({error, scope}, erx_inspector:inspect([domains, ?SYSTEM], [5], #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([domains, 9], all, #{})).

domain_record_core_test() ->
    Figures = #{atoms => 10, ets_tables => 2, modules => 30, processes => 40, run_queue => 3},
    {ok, #{attrs := Attrs}} = erx_runtime_records:domain(?SYSTEM, Figures),
    ?assertEqual({runtime, {ok, 3}}, maps:get(run_queue, Attrs)),
    ?assertEqual({runtime, {ok, 40}}, maps:get(processes, Attrs)),
    ?assertEqual({service, unsupported}, maps:get(state, Attrs)),
    {ok, Keys} = erx_schema:attributes(domain),
    ?assertEqual(lists:sort(Keys), lists:sort(maps:keys(Attrs))).

%%% The kernel log (erx_log_records), from made-up reads

%% A read that answers each cursor from Answers, and refuses one it does not list.
reads(Answers) ->
    fun(Cursor) -> maps:get(Cursor, Answers, {error, ?ERX_EINVAL}) end.

log_entries(Offset, Answers) ->
    case erx_log_records:record(Offset, reads(Answers)) of
        {ok, #{path := [kernel, log], kind := log, entries := Entries}} -> Entries;
        Error -> Error
    end.

%% Records the ring overwrote before the read reached them are left out,
%% and each line keeps its record's number, so the gap says how many.
a_read_past_lost_records_numbers_its_lines_test() ->
    Answers = #{0 => {ok, 7, 5, [<<"#5 five\n">>, <<"#6 six\n">>]}, 7 => {ok, 7, 0, []}},
    ?assertEqual({ok, 7, [{5, <<"#5 five">>}, {6, <<"#6 six">>}]}, log_entries(0, Answers)),
    ?assertEqual({ok, 7, [{6, <<"#6 six">>}]},
                 log_entries(6, #{6 => {ok, 7, 0, [<<"#6 six\n">>]}, 7 => {ok, 7, 0, []}})).

%% A read stops at a record that fails its checks but moves past it, so
%% the records it could not show are a gap too, never a line.
unreadable_records_are_a_gap_test() ->
    Answers = #{0 => {corrupt, 4, 0, [<<"#0 a\n">>]}, 4 => {ok, 6, 0, [<<"#4 b\n">>, <<"#5 c\n">>]},
                6 => {ok, 6, 0, []}},
    ?assertEqual({ok, 6, [{0, <<"#0 a">>}, {4, <<"#4 b">>}, {5, <<"#5 c">>}]}, log_entries(0, Answers)).

%% A log that keeps growing still ends the query, at a page, partial.
a_growing_log_ends_at_a_page_test() ->
    Growing = fun(Cursor) -> {ok, Cursor + 3, 0, [<<"x\n">>, <<"y\n">>, <<"z\n">>]} end,
    {ok, #{entries := {partial, 1000, Entries}}} = erx_log_records:record(0, Growing),
    ?assertEqual(lists:seq(0, 999), [Sequence || {Sequence, _} <- Entries]),
    Lossy = fun(Cursor) -> {ok, Cursor + 1, 1, []} end,
    ?assertMatch({ok, #{entries := {partial, 1000, []}}}, erx_log_records:record(0, Lossy)).

log_refusals_are_named_test() ->
    ?assertEqual({error, invalid}, log_entries(9, #{})),
    ?assertEqual({error, unsupported}, erx_log_records:record(0, fun(_) -> {error, ?ERX_ENOTSUP} end)),
    %% Counts that do not add up, more lines than the read moved past.
    ?assertEqual({error, failed}, log_entries(0, #{0 => {ok, 1, 0, [<<"a\n">>, <<"b\n">>]}})),
    ?assertEqual({error, invalid}, erx_log_records:record(-1, reads(#{}))),
    ?assertEqual({error, invalid}, erx_log_records:record(1 bsl 64, reads(#{}))),
    %% A refusal after the first read ends the entries where they stopped.
    ?assertEqual({partial, 1, [{0, <<"a">>}]}, log_entries(0, #{0 => {ok, 1, 0, [<<"a\n">>]}})).

kernel_paths_need_scope_all_test() ->
    ?assertEqual({ok, #{schema => 1, path => [kernel], kind => listing, id => kernel, attrs => #{},
                        children => [log]}},
                 erx_inspector:inspect([kernel], all, #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([kernel], [?SYSTEM], #{})),
    ?assertEqual({error, scope}, erx_inspector:inspect([kernel, log], [?SYSTEM], #{offset => 0})),
    %% The offset is the caller's: one that is no sequence number is refused before any read.
    ?assertEqual({error, invalid}, erx_inspector:inspect([kernel, log], all, #{offset => -1})),
    ?assertEqual({error, invalid}, erx_inspector:inspect([kernel, log], all, #{offset => <<"0">>})),
    ?assertEqual({error, invalid}, erx_inspector:inspect([kernel, log], all, [{offset, 0}])).

%% Entries are checked like the rest of a record: only where the schema
%% declares them, numbered in order below Next, of the entry type.
the_record_validator_checks_entries_test() ->
    Record = #{schema => 1, path => [kernel, log], kind => log, id => log, attrs => #{}, children => []},
    Valid = fun(Entries) -> erx_schema:validate_record(Record#{entries => Entries}) end,
    ?assertMatch({ok, _}, Valid({ok, 3, [{0, <<"a">>}, {2, <<"b">>}]})),
    ?assertMatch({ok, _}, erx_schema:validate_record(Record)),
    ?assertEqual({error, entries}, Valid({ok, 3, [{2, <<"a">>}, {1, <<"b">>}]})),
    ?assertEqual({error, entries}, Valid({ok, 3, [{1, <<"a">>}, {1, <<"b">>}]})),
    ?assertEqual({error, entries}, Valid({ok, 3, [{3, <<"a">>}]})),
    ?assertEqual({error, entries}, Valid({ok, 3, [{0, a}]})),
    ?assertEqual({error, entries}, Valid({whole, 3, []})),
    ?assertEqual({error, entries}, Valid({ok, 1 bsl 64, []})),
    ?assertEqual({error, entries}, Valid({ok, 1001, [{N, <<>>} || N <- lists:seq(0, 1000)]})),
    ?assertEqual({error, entries},
                 erx_schema:validate_record(#{schema => 1, path => [kernel], kind => listing, id => kernel,
                                              attrs => #{}, children => [log], entries => {ok, 0, []}})),
    ?assertEqual({error, malformed}, erx_schema:validate_record(Record#{entries => {ok, 0, []}, other => 1})).

%% A runtime collects the system domain's records only when it is the system domain.
%% Another runtime's kernel records are its own domain's, so a session, even one whose
%% inspect scope is `all`, collects none rather than show its own as the system
%% domain's, and no runtime collects another domain's.
collects_domain_test() ->
    System = erx_kernel_records:system_domain(),
    Session = System + 4,
    ?assert(erx_inspector:collects_domain(System, System)),
    ?assertNot(erx_inspector:collects_domain(System, Session)),
    ?assertNot(erx_inspector:collects_domain(Session, Session)),
    ?assertNot(erx_inspector:collects_domain(Session, System)).
