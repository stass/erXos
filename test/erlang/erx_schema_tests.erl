%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of the checked-in erx_schema, generated from abi/inspection.txt: one case
%% per status and per reporter through the validators, the root pool stopgap on a
%% budget's used, and every declared path resolved from its term and from its text to
%% exactly one declaration. test/host/erx_schema_test.rb runs them on stock's emulator.

-module(erx_schema_tests).
-include_lib("eunit/include/eunit.hrl").

-define(STATUSES, [{ok, 7}, {partial, 7}, unknown, unsupported, {timeout, 500}, {error, enoent}]).

schema_test() ->
    ?assertEqual(1, erx_schema:schema()),
    ?assertEqual([machine, cpu, group, budget, domain, thread, process, log, module, listing], erx_schema:kinds()).

%% An attribute each reporter may report, and one it may not. The collector names the
%% reporter, so a frame's own tag is never read.
reporter_cases() ->
    [{kernel, {budget, guarantee}, {domain, name}},
     {service, {domain, principal}, {budget, guarantee}},
     {runtime, {process, reductions}, {machine, uptime}},
     {{stopgap, liberx_pool}, {budget, used}, {budget, guarantee}}].

every_status_for_every_reporter_test() ->
    [?assertEqual({ok, {Reporter, Value}}, erx_schema:validate_attr(Kind, Key, Reporter, Value))
     || {Reporter, {Kind, Key}, _Refused} <- reporter_cases(), Value <- ?STATUSES].

every_reporter_is_refused_where_it_is_not_listed_test() ->
    [?assertEqual({error, reporter}, erx_schema:validate_attr(Kind, Key, Reporter, unknown))
     || {Reporter, _Allowed, {Kind, Key}} <- reporter_cases()],
    ?assertEqual({error, reporter}, erx_schema:validate_attr(budget, used, {stopgap, other}, unknown)),
    ?assertEqual({error, reporter}, erx_schema:validate_attr(budget, used, liberx_pool, unknown)).

%% docs/design-stopgap.md, "Reporting a budget": used is partial, by root pool; the
%% rest is the kernel's, unsupported.
budget_on_the_stopgap_test() ->
    ?assertEqual({ok, {{stopgap, liberx_pool}, {partial, 12}}},
                 erx_schema:validate_attr(budget, used, {stopgap, liberx_pool}, {partial, 12})),
    [?assertEqual({ok, {kernel, unsupported}}, erx_schema:validate_attr(budget, Key, kernel, unsupported))
     || Key <- [guarantee, cap, carved, lent, pinned]],
    ?assertEqual({ok, <<"root pool">>}, erx_schema:reporter_label({stopgap, liberx_pool})),
    {ok, #{category := kernel, scope := Scope}} = erx_schema:stopgap(liberx_pool),
    ?assertEqual(<<"pages of the root's pool: those handed out, carved budgets' included, and the pool's total and free; not the kernel's or sigma0's memory, page tables or mapping records">>, Scope),
    {ok, #{unit := Unit}} = erx_schema:attribute(budget, used),
    ?assertEqual(<<"pages">>, Unit).

%% docs/design-live.md, "Tracing": each row's reporter comes from the schema, the
%% backend's from the liberx trace stopgap, which stands in for the kernel.
trace_rows_test() ->
    ?assertEqual([erts, backend, kernel], erx_schema:trace_rows()),
    ?assertEqual({ok, runtime}, erx_schema:trace_row(erts)),
    ?assertEqual({ok, {stopgap, liberx_trace}}, erx_schema:trace_row(backend)),
    ?assertEqual({ok, kernel}, erx_schema:trace_row(kernel)),
    ?assertEqual(error, erx_schema:trace_row(frames)),
    ?assertEqual({ok, <<"liberx trace">>}, erx_schema:reporter_label({stopgap, liberx_trace})),
    {ok, #{category := kernel}} = erx_schema:stopgap(liberx_trace).

values_outside_their_type_are_invalid_test() ->
    Cases = [{budget, used, {partial, -1}}, {domain, name, {ok, <<16#ff>>}}, {domain, state, {ok, dead}},
             {process, links, {ok, [{pid, 4, 1, 0} | {pid, 4, 2, 0}]}}, {process, group_leader, {ok, self()}},
             {process, group_leader, {ok, {pid, 16#100000000, 1, 0}}}, {process, links, {ok, [{pid, 4, -1, 0}]}},
             {process, location, {ok, {lists, <<"map">>, 2, <<>>, 1}}},
             {machine, entropy_quality, {ok, poor}}, {cpu, ready_threads, {ok, lists:duplicate(65, 0)}}],
    [?assertEqual({ok, {Reporter, {error, invalid}}}, erx_schema:validate_attr(Kind, Key, Reporter, Value))
     || {Kind, Key, Value} <- Cases,
        {ok, #{reporters := [Reporter | _]}} <- [erx_schema:attribute(Kind, Key)]].

%% A sample segment of each variable type, as a term and as its text.
sample({type, Name}) ->
    {ok, Descriptor} = erx_schema:type(Name),
    sample(Descriptor);
sample({integer, Minimum, _Maximum, _Multiple}) ->
    {Minimum + 1, integer_to_binary(Minimum + 1)};
sample({text, _Maximum, _Encoding}) ->
    {<<"lists.erl">>, <<"lists%2Eerl">>};
sample(proc_id) ->
    {{pid, 4, 85, 0}, <<"4.85.0">>}.

samples(Pattern) ->
    lists:unzip([case Element of
                     {variable, Type} -> sample(Type);
                     Literal -> {Literal, atom_to_binary(Literal)}
                 end || Element <- Pattern]).

%% A matcher that shares no code with erx_schema's own.
matching(Path) ->
    [D || #{pattern := Pattern} = D <- erx_schema:declarations(), match(Pattern, Path)].

match([], []) -> true;
match([{variable, Type} | Pattern], [Segment | Path]) ->
    Segment =/= <<>> andalso erx_schema:valid(Type, Segment) andalso match(Pattern, Path);
match([Literal | Pattern], [Segment | Path]) -> Literal =:= Segment andalso match(Pattern, Path);
match(_, _) -> false.

every_path_resolves_to_exactly_one_declaration_test() ->
    Declarations = erx_schema:declarations(),
    ?assertEqual(20, length(Declarations)),
    [begin
         {Path, Texts} = samples(Pattern),
         ?assertEqual([Declaration], matching(Path)),
         ?assertEqual({ok, Declaration}, erx_schema:resolve(Path)),
         Text = iolist_to_binary(lists:join(<<"/">>, Texts)),
         ?assertEqual({ok, Path, Declaration}, erx_schema:resolve_text(Text)),
         ?assertEqual({ok, Path, Declaration}, erx_schema:resolve_text(<<"/", Text/binary>>))
     end || #{pattern := Pattern} = Declaration <- Declarations].

machine_wide_paths_are_marked_test() ->
    Visible = fun(Path) -> {ok, #{visible := V}} = erx_schema:resolve(Path), V end,
    ?assertEqual([all], Visible([cpus, 0])),
    ?assertEqual([all], Visible([budgets, 1])),
    ?assertEqual([all], Visible([groups, 1])),
    ?assertEqual([], Visible([domains, 4, group])),
    ?assertEqual([], Visible([domains, 4, threads, 7])),
    ?assertEqual([], Visible([domains, 4, budget])),
    ?assertEqual([], Visible([processes, {pid, 4, 85, 0}])),
    {ok, Processes} = erx_schema:resolve([domains, 4, processes]),
    ?assertMatch(#{entries := {proc_id, 1048576}, append_only := false}, Processes),
    ?assertEqual([all], Visible([kernel, log])),
    {ok, Log} = erx_schema:resolve([kernel, log]),
    ?assertMatch(#{kind := log, entries := {{type, log_line}, 65536}, append_only := true}, Log).

unknown_paths_test() ->
    [?assertEqual({error, unknown_path}, erx_schema:resolve(Path))
     || Path <- [[cpus, 64], [budgets, 0], [domains, <<"4">>], [domains, 4, modules, lists], [kernel, trace]]],
    [?assertEqual({error, unknown_path}, erx_schema:resolve_text(Text))
     || Text <- [<<"cpus/64">>, <<"budgets/0">>, <<"domains/4/modules/lists.erl">>, <<"kernel/trace">>]].

%% A process's segment is its proc_id(), three numbers read from D.N.S as numbers alone:
%% no pid is made, so any domain's number reads alike, connected or not, and each part
%% is a canonical decimal of at most 32 bits.
proc_id_text_is_three_numbers_test() ->
    ?assertMatch({ok, [processes, {pid, 4, 85, 0}], _}, erx_schema:resolve_text(<<"processes/4.85.0">>)),
    ?assertMatch({ok, [processes, {pid, 3, 85, 0}], _}, erx_schema:resolve_text(<<"processes/3.85.0">>)),
    ?assertMatch({ok, [processes, {pid, 16#ffffffff, 0, 16#ffffffff}], _},
                 erx_schema:resolve_text(<<"processes/4294967295.0.4294967295">>)),
    [?assertEqual({error, unknown_path}, erx_schema:resolve_text(<<"processes/", Text/binary>>))
     || Text <- [<<"4294967296.0.0">>, <<"4.85">>, <<"4.85.0.1">>, <<"04.85.0">>, <<"4.-1.0">>,
                 <<"<4.85.0>">>, <<"4..0">>, <<"4.85.0.">>]],
    ?assertEqual(<<"4.85.0">>, erx_schema:segment_text({pid, 4, 85, 0})).

%% docs/design-live.md, V10: a record holds no pid, port, reference or fun at any depth,
%% in an attribute, its id, an error's reason or nested in a list, a tuple or a map,
%% and validate_record/1 refuses it whole, before any other check.
names() ->
    Port = hd(erlang:ports()),
    [self(), make_ref(), Port, fun() -> ok end].

process_record(Attrs) ->
    #{schema => 1, path => [processes, {pid, 4, 85, 0}], kind => process, id => {pid, 4, 85, 0},
      attrs => Attrs, children => []}.

a_record_of_proc_ids_is_valid_test() ->
    Attrs = #{group_leader => {runtime, {ok, {pid, 4, 1, 0}}}, links => {runtime, {ok, [{pid, 5, 2, 3}]}},
              monitors => {runtime, {partial, []}}},
    ?assertEqual({ok, process_record(Attrs)}, erx_schema:validate_record(process_record(Attrs))).

no_record_holds_a_name_test() ->
    [?assertEqual({error, name}, erx_schema:validate_record(Record))
     || Name <- names(),
        Record <- [process_record(#{group_leader => {runtime, {ok, Name}}}),
                   process_record(#{links => {runtime, {ok, [{pid, 4, 1, 0}, Name]}}}),
                   process_record(#{links => {runtime, {partial, [[Name]]}}}),
                   process_record(#{state => {runtime, {error, Name}}}),
                   process_record(#{state => {runtime, {error, {Name}}}}),
                   process_record(#{location => {runtime, {ok, {<<"m">>, <<"f">>, 0, #{Name => 1}, 0}}}}),
                   (process_record(#{}))#{id := Name},
                   (process_record(#{}))#{id := #{key => [Name]}},
                   (process_record(#{}))#{children := [Name]},
                   (process_record(#{}))#{path := [processes, Name]},
                   (process_record(#{}))#{extra => Name},
                   #{name => Name}]].

%% A record's id is its path's last segment where that segment is variable.
id_is_the_last_variable_segment_test() ->
    ?assertEqual({error, id}, erx_schema:validate_record((process_record(#{}))#{id := {pid, 4, 86, 0}})),
    ?assertEqual({error, id}, erx_schema:validate_record((process_record(#{}))#{id := 85})),
    Cpu = #{schema => 1, path => [cpus, 2], kind => cpu, id => 2, attrs => #{}, children => []},
    ?assertMatch({ok, _}, erx_schema:validate_record(Cpu)),
    ?assertEqual({error, id}, erx_schema:validate_record(Cpu#{id := 3})).

%% /proc's status file and the shell show fields in schema order.
fields_test() ->
    {ok, Keys} = erx_schema:attributes(budget),
    ?assertEqual({ok, Keys}, erx_schema:fields(budget, proc, release)),
    ?assertEqual([kind, guarantee, cap, used], lists:sublist(Keys, 4)).

%% A derived attribute names its inputs; one a report carries names none.
derived_test() ->
    ?assertMatch({ok, #{derived := [used, carved, lent]}}, erx_schema:attribute(budget, spending)),
    ?assertMatch({ok, #{derived := []}}, erx_schema:attribute(budget, used)),
    ?assertMatch({ok, #{derived := []}}, erx_schema:attribute(thread, state)).
