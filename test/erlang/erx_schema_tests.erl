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
    ?assertEqual([machine, cpu, group, budget, domain, thread, process, module, listing], erx_schema:kinds()).

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
             {process, links, {ok, [self() | self()]}}, {process, location, {ok, {lists, <<"map">>, 2, <<>>, 1}}},
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
sample(pid) ->
    "<" ++ Text = pid_to_list(self()),
    {self(), list_to_binary(lists:droplast(Text))}.

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
    ?assertEqual(18, length(Declarations)),
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
    ?assertEqual([], Visible([processes, self()])),
    {ok, Processes} = erx_schema:resolve([domains, 4, processes]),
    ?assertMatch(#{entries := {pid, 1048576}, append_only := false}, Processes).

unknown_paths_test() ->
    [?assertEqual({error, unknown_path}, erx_schema:resolve(Path))
     || Path <- [[cpus, 64], [budgets, 0], [domains, <<"4">>], [domains, 4, modules, lists], [kernel]]],
    [?assertEqual({error, unknown_path}, erx_schema:resolve_text(Text))
     || Text <- [<<"cpus/64">>, <<"budgets/0">>, <<"domains/4/modules/lists.erl">>, <<"kernel">>]].

%% A pid is read only in the spelling the runtime writes it: stock OTP's list_to_pid/1
%% takes any domain number on a node that is not distributed as its own, which would
%% give "processes/3.N.S" a second spelling.
pid_text_is_read_in_the_runtimes_one_spelling_test() ->
    [_, N, S] = string:split(string:trim(pid_to_list(self()), both, "<>"), ".", all),
    ?assertMatch({ok, [processes, _], _}, erx_schema:resolve_text(iolist_to_binary(["processes/0.", N, ".", S]))),
    ?assertEqual({error, unknown_path}, erx_schema:resolve_text(iolist_to_binary(["processes/3.", N, ".", S]))).

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
