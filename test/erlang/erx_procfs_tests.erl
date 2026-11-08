%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of /proc (docs/design-live.md, "The /proc tree"): erx_procfs_core's names,
%% walks, listings and status text from made-up inspector answers, every status kind
%% among them, and erx_procfs's listing of the processes and its snapshot bound over the
%% real inspector. test/host/erx_procfs_test.rb runs them on stock's emulator, also
%% against seeded faults each of which a named case must catch.

-module(erx_procfs_tests).
-include_lib("eunit/include/eunit.hrl").

%%% Names

names_round_trip_through_child_test() ->
    Pid = self(),
    [?assertEqual({ok, Parent ++ [Segment]}, erx_procfs_core:child(Parent, erx_procfs_core:name(Segment)))
     || {Parent, Segment} <- [{[], processes}, {[], domains}, {[domains], 4}, {[domains, 4], threads},
                              {[domains, 4, threads], 0}, {[cpus], 63}, {[processes], Pid},
                              {[domains, 4, modules], <<"lists">>},
                              {[domains, 4, modules], <<".odd name\t\n%/", 16#c3, 16#a9>>}]].

pid_name_has_no_brackets_test() ->
    "<" ++ Text = pid_to_list(self()),
    ?assertEqual(list_to_binary(lists:droplast(Text)), erx_procfs_core:name(self())).

text_names_encode_every_other_byte_test() ->
    ?assertEqual(<<"%2Ea%20b%2F%25%FF">>, erx_procfs_core:name(<<".a b/%", 255>>)),
    ?assertEqual(<<"A-z_0+,:=@">>, erx_procfs_core:name(<<"A-z_0+,:=@">>)).

child_refuses_names_outside_the_encoding_test() ->
    Long = binary:copy(<<"a">>, 766),
    [?assertEqual(error, erx_procfs_core:child(Parent, Name))
     || {Parent, Name} <- [{[], <<>>}, {[], <<".">>}, {[], <<"..">>}, {[], <<"cpus/0">>}, {[], <<"/cpus">>},
                           {[], <<"nothing">>}, {[cpus], <<"007">>}, {[cpus], <<"64">>},
                           {[cpus], <<"-1">>}, {[domains, 4, modules], <<"%41">>},
                           {[domains, 4, modules], <<"%2e">>}, {[domains, 4, modules], <<"a.b">>},
                           {[domains, 4, modules], Long}, {[processes], <<"0.1">>},
                           {[processes], <<"<0.1.0>">>}, {[domains, 4], <<"status">>}]].

%%% Walks

walk_answers_status_without_asking_test() ->
    ?assertEqual({ok, {status, [domains, 4]}},
                 erx_procfs_core:walk([domains, 4], <<"status">>, fun(Q) -> error({asked, Q}) end)).

walk_reads_scope_as_no_entry_test() ->
    Scope = fun({exists, _}) -> {error, scope} end,
    ?assertEqual({error, enoent}, erx_procfs_core:walk([processes], erx_procfs_core:name(self()), Scope)),
    Unsupported = fun({exists, _}) -> {error, unsupported} end,
    ?assertEqual({ok, {dir, [groups]}}, erx_procfs_core:walk([], <<"groups">>, Unsupported)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([], <<"nothing">>, Unsupported)).

markers_exist_only_where_the_listing_says_test() ->
    Partial = fun({listing, Path}) -> listing(Path, {partial, [0]}) end,
    Unknown = fun({listing, _}) -> {error, unsupported} end,
    Whole = fun({listing, Path}) -> listing(Path, [0, 1]) end,
    ?assertEqual({ok, {partial, [cpus]}}, erx_procfs_core:walk([cpus], <<".partial">>, Partial)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([cpus], <<".unknown">>, Partial)),
    ?assertEqual({ok, {unknown, [cpus]}}, erx_procfs_core:walk([cpus], <<".unknown">>, Unknown)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([cpus], <<".partial">>, Whole)),
    ?assertEqual({error, enoent}, erx_procfs_core:walk([], <<".partial">>, Partial)).

%%% Listings

root_lists_what_the_scope_reaches_test() ->
    ?assertEqual([<<"status">>, <<"cpus">>, <<"groups">>, <<"budgets">>, <<"domains">>, <<"processes">>],
                 names(erx_procfs_core:listing([], none, all))),
    ?assertEqual([<<"status">>, <<"processes">>], names(erx_procfs_core:listing([], none, [4]))).

a_listing_lists_its_ids_and_markers_test() ->
    ?assertEqual([<<"status">>, <<"0">>, <<"1">>],
                 names(erx_procfs_core:listing([cpus], listing([cpus], [0, 1]), all))),
    ?assertEqual([<<"status">>, <<"0">>, <<".partial">>],
                 names(erx_procfs_core:listing([cpus], listing([cpus], {partial, [0]}), all))),
    ?assertEqual([<<"status">>, <<".unknown">>],
                 names(erx_procfs_core:listing([groups], {error, unsupported}, all))),
    ?assertEqual([{<<".unknown">>, {unknown, [groups]}}],
                 tl(erx_procfs_core:listing([groups], unknown_listing([groups]), all))),
    ?assertEqual([<<"status">>, <<".unknown">>],
                 names(erx_procfs_core:listing([domains, 4, processes], {error, unsupported}, all))),
    ?assertEqual([<<"status">>, <<"budget">>, <<"group">>, <<"threads">>, <<"modules">>, <<"processes">>],
                 names(erx_procfs_core:listing([domains, 4], none, all))),
    ?assertEqual([<<"status">>, erx_procfs_core:name(self())],
                 names(erx_procfs_core:listing([processes], listing([processes], [self()]), all))).

marker_files_never_fabricate_test() ->
    ?assertEqual(<<"left_out\t[unknown]\n">>, erx_procfs_core:marker(partial, listing([cpus], {partial, [0]}))),
    ?assertEqual(<<"[unsupported]\n">>, erx_procfs_core:marker(unknown, {error, unsupported})),
    ?assertEqual(<<"[unknown]\n">>,
                 erx_procfs_core:marker(unknown, unknown_listing([groups]))).

%%% Status files

every_status_kind_is_written_as_itself_test() ->
    Text = erx_procfs_core:status({ok, budget(#{guarantee => {kernel, {ok, 12}},
                                                cap => {kernel, unsupported},
                                                used => {{stopgap, liberx_pool}, {partial, 7}},
                                                carved => {kernel, unknown},
                                                lent => {kernel, {timeout, 500}},
                                                pinned => {kernel, {error, einval}}})}, development),
    ?assertEqual([[<<"guarantee">>, <<"12">>, <<"kernel">>],
                  [<<"cap">>, <<"[unsupported]">>, <<"kernel">>],
                  [<<"used">>, <<"[partial]">>, <<"root pool">>],
                  [<<"carved">>, <<"[unknown]">>, <<"kernel">>],
                  [<<"lent">>, <<"[timeout 500]">>, <<"kernel">>],
                  [<<"pinned">>, <<"[error]">>, <<"kernel">>]], rows(Text)).

an_answer_without_a_record_says_why_test() ->
    ?assertEqual(<<"[unsupported]\n">>, erx_procfs_core:status({error, unsupported}, development)).

fields_escape_and_round_trip_test() ->
    Name = <<"evil\t\n\\", 27, "[2J", 16#c2, 16#9b, "x", 255>>,
    Text = erx_procfs_core:status({ok, process(#{registered_name => {runtime, {ok, Name}}})}, development),
    [Line] = binary:split(Text, <<"\n">>, [global, trim_all]),
    ?assertEqual(nomatch, binary:match(Line, [<<27>>, <<16#c2, 16#9b>>, <<255>>])),
    [<<"registered_name">>, Value, <<"runtime">>] = binary:split(Line, <<"\t">>, [global]),
    ?assertEqual({ok, Name}, erx_text:unescape_field(Value)).

a_record_over_64_kib_is_cut_at_a_line_test() ->
    Line = <<(binary:copy(<<"x">>, 999))/binary, "\n">>,
    Text = erx_procfs_core:cut(lists:duplicate(70, Line)),
    ?assert(byte_size(Text) =< 65536),
    ?assertMatch({_, 10}, binary:match(Text, <<"[partial]\n">>, [{scope, {byte_size(Text) - 10, 10}}])),
    ?assertEqual(Line, binary:part(Text, byte_size(Text) - 1010, 1000)),
    Whole = erx_procfs_core:cut(lists:duplicate(65, Line)),
    ?assertEqual(65000, byte_size(Whole)).

%%% The tree over the real inspector

the_processes_directory_lists_this_process_test() ->
    {ok, Fs} = erx_procfs:init(all),
    {ok, Processes, _} = erx_procfs:walk(erx_procfs_core:root(), <<"processes">>, Fs),
    {ok, Handle} = erx_procfs:open(Processes, 0, Fs),
    {ok, Entries} = erx_procfs:readdir(Handle, 0, 256, Fs),
    Names = [Name || {_, _, _, Name} <- Entries],
    ?assertEqual(<<"status">>, hd(Names)),
    ?assert(lists:member(erx_procfs_core:name(self()), Names)),
    {ok, Rest} = erx_procfs:readdir(Handle, 1, 256, Fs),
    ?assertEqual(tl(Entries), Rest),
    ok = erx_procfs:clunk(Handle, Fs),
    Dead = spawn(fun() -> ok end),
    Ref = monitor(process, Dead),
    receive {'DOWN', Ref, process, Dead, _} -> ok end,
    ?assertEqual({error, enoent}, erx_procfs:walk(Processes, erx_procfs_core:name(Dead), Fs)).

the_257th_snapshot_is_refused_test() ->
    {ok, Fs} = erx_procfs:init([4]),
    Root = erx_procfs_core:root(),
    Handles = [element(2, {ok, _} = erx_procfs:open(Root, 0, Fs)) || _ <- lists:seq(1, 256)],
    ?assertEqual({error, emfile}, erx_procfs:open(Root, 0, Fs)),
    ok = erx_procfs:clunk(hd(Handles), Fs),
    ?assertMatch({ok, _}, erx_procfs:open(Root, 0, Fs)),
    ?assertEqual({error, erofs}, erx_procfs:open(Root, 1, Fs)).

a_crashing_query_answers_eio_and_keeps_its_snapshot_test() ->
    {ok, Fs} = erx_procfs:init(all),
    %% On stock erx_object_info's NIF is not loaded, so the machine's record, which a
    %% status file asks for its build's projection, crashes.
    [?assertEqual({error, eio}, erx_procfs:open({status, [processes, self()]}, 0, Fs)) || _ <- lists:seq(1, 300)],
    ?assertMatch({ok, _}, erx_procfs:open(erx_procfs_core:root(), 0, Fs)).

%%% Helpers

listing(Path, Children) ->
    {ok, Record} = erx_schema:validate_record(#{schema => 1, path => Path, kind => listing,
                                                id => lists:last(Path), attrs => #{},
                                                children => Children}),
    {ok, Record}.

budget(Attrs) ->
    #{schema => 1, path => [domains, 4, budget], kind => budget, id => budget, attrs => Attrs,
      children => []}.

process(Attrs) ->
    #{schema => 1, path => [processes, self()], kind => process, id => self(), attrs => Attrs,
      children => []}.

%% A listing whose entries the inspector could not get.
unknown_listing(Path) ->
    {ok, Record} = listing(Path, []),
    {ok, Record#{children := unknown}}.

names(Entries) -> [Name || {Name, _Node} <- Entries].

rows(Text) ->
    [binary:split(Line, <<"\t">>, [global]) || Line <- binary:split(Text, <<"\n">>, [global, trim_all])].
