%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_web_value (docs/design-web.md, "Values"): each bound of
%% datum() at its limit and one past it, hostile terms that must project in
%% bounded time and size, and a record's wire form.
-module(erx_web_value_tests).
-include_lib("eunit/include/eunit.hrl").

%% The datum of Term within one update.
d(Term) ->
    {ok, Datum} = erx_web_value:datum(Term),
    Datum.

nested(0, Leaf) -> Leaf;
nested(Levels, Leaf) -> [nested(Levels - 1, Leaf)].

datum_depth({Container, Elements}) when Container =:= list; Container =:= tuple ->
    1 + lists:max([0 | [datum_depth(Element) || Element <- Elements]]);
datum_depth(_Datum) -> 0.

seven_levels_are_kept_and_an_eighth_container_is_printed_test() ->
    ?assertEqual(7, datum_depth(d(nested(7, 1)))),
    Eight = d(nested(8, 1)),
    ?assertEqual(7, datum_depth(Eight)),
    ?assertEqual({list, [{printed, <<"[1]">>}]}, innermost(Eight, 6)).

innermost(Datum, 0) -> Datum;
innermost({list, [Element]}, Levels) -> innermost(Element, Levels - 1).

a_tuple_counts_as_a_level_test() ->
    Term = nested(6, {nested(1, x)}),
    ?assertMatch({tuple, [{printed, <<"[x]">>}]}, innermost(d(Term), 6)).

list_and_tuple_bounds_test() ->
    ?assertMatch({list, L} when length(L) =:= 1000, d(lists:seq(1, 1000))),
    ?assertMatch({printed, _}, d(lists:seq(1, 1001))),
    ?assertMatch({tuple, L} when length(L) =:= 16, d(list_to_tuple(lists:seq(1, 16)))),
    ?assertMatch({printed, _}, d(list_to_tuple(lists:seq(1, 17)))),
    ?assertEqual({printed, <<"[a|b]">>}, d([a | b])).

scalar_bounds_test() ->
    Forty = binary_to_integer(binary:copy(<<"9">>, 39)),
    ?assertEqual({int, <<"-", (integer_to_binary(Forty))/binary>>}, d(-Forty)),
    ?assertMatch({printed, _}, d(Forty * 100 + 99)),
    %% Decided by magnitude: 10^40 - 1 is 40 digits and -10^39 is 41 bytes.
    ?assertEqual({int, binary:copy(<<"9">>, 40)}, d(Forty * 10 + 9)),
    ?assertEqual({printed, <<"-1", (binary:copy(<<"0">>, 39))/binary>>}, d(-(Forty + 1))),
    ?assertEqual({int, <<"0">>}, d(0)),
    Long = binary_to_atom(binary:copy(<<"a">>, 255)),
    ?assertEqual({atom, atom_to_binary(Long)}, d(Long)),
    %% 128 two-byte characters: 128 characters, but 256 bytes.
    Wide = binary_to_atom(binary:copy(<<"\x{e9}"/utf8>>, 128)),
    ?assertMatch({printed, _}, d(Wide)),
    ?assertEqual({text, <<16#C0, 0, 27>>}, d(<<16#C0, 0, 27>>)),
    ?assertEqual({printed, <<"<<1:1>>">>}, d(<<1:1>>)).

%% A list of ten million elements, a list nested 300,000 deep, a huge binary
%% nine levels down and a huge map each print within 4 KiB, quickly, and cut
%% at a character's end.
hostile_terms_print_bounded_test_() ->
    Big = binary:copy(<<"\x{e9}"/utf8>>, 1 bsl 20),
    Terms = [lists:seq(1, 10000000), nested(300000, x), [nested(300000, x) | x], nested(9, Big), maps:from_list([{N, Big} || N <- lists:seq(1, 1000)]),
             nested(7, {nested(1, [Big])}), list_to_tuple(lists:duplicate(100000, Big))],
    {timeout, 60,
     fun() ->
             [begin
                  {Micros, {ok, Datum}} = timer:tc(erx_web_value, datum, [Term]),
                  ?assert(Micros < 2000000),
                  [?assert(byte_size(Text) =< 4096) || Text <- printed(Datum)],
                  [?assertMatch(<<_/utf8>>, last_char(Text)) || Text <- printed(Datum), Text =/= <<>>]
              end || Term <- Terms]
     end}.

printed({printed, Text}) -> [Text];
printed({Container, Elements}) when Container =:= list; Container =:= tuple ->
    lists:append([printed(Element) || Element <- Elements]);
printed(_Datum) -> [].

%% The last whole character of Text, or the bytes after the last lead byte.
last_char(Text) ->
    Lead = lists:last([At || At <- lists:seq(0, byte_size(Text) - 1),
                             binary:at(Text, At) band 16#C0 =/= 16#80]),
    binary:part(Text, Lead, byte_size(Text) - Lead).

a_record_projects_in_schema_order_test() ->
    {ok, [First, Second | _]} = erx_schema:attributes(machine),
    Record = #{schema => 1, path => [], kind => machine, id => <<"m">>,
               attrs => #{Second => {{stopgap, liberx_pool}, {timeout, 5}},
                          First => {kernel, {partial, [1]}}},
               children => {partial, [<<"a.b/c">>, 7, self()]}},
    Pid = list_to_binary(pid_to_list(self())),
    Name = binary:part(Pid, 1, byte_size(Pid) - 2),
    ?assertEqual({ok, #{path => [], kind => <<"machine">>, id => {text, <<"m">>},
                   attrs => [{atom_to_binary(First), kernel, partial, {list, [{int, <<"1">>}]}},
                             {atom_to_binary(Second), {stopgap, <<"liberx_pool">>}, {timeout, 5}, {list, []}}],
                   children => {partial, [{text, <<"a%2Eb%2Fc">>}, {text, <<"7">>}, {text, Name}]}}},
                 erx_web_value:project(Record)),
    Statuses = #{First => {service, unknown}, Second => {runtime, {error, {badarg, x}}}},
    ?assertMatch({ok, #{attrs := [{_, service, unknown, {list, []}},
                             {_, runtime, error, {tuple, [{atom, <<"badarg">>}, {atom, <<"x">>}]}}],
                   children := {unknown, []}}},
                 erx_web_value:project(Record#{attrs := Statuses, children := unknown})).

%% An integer too long to print whole prints as its leading digits, the
%% first 4 KiB of its decimal text, and the largest one and a list of them
%% print in a fraction of the time printing one whole takes.
huge_integers_print_their_leading_digits_test_() ->
    Mid = binary_to_integer(<<"-7", (binary:copy(<<"31">>, 15000))/binary>>),
    Huge = (1 bsl (4194000 + erlang:phash2(self(), 1))) - 1,
    {timeout, 60,
     fun() ->
             ?assertEqual({printed, binary:part(integer_to_binary(Mid), 0, 4096)}, d(Mid)),
             ?assertEqual({printed, binary:part(integer_to_binary(-Mid), 0, 4096)}, d(-Mid)),
             ?assertMatch({printed, <<"[", _/binary>>}, d(lists:duplicate(1001, Mid))),
             [begin
                  {Micros, {ok, {printed, Text}}} = timer:tc(erx_web_value, datum, [Term]),
                  ?assertEqual(4096, byte_size(Text)),
                  ?assert(Micros < 1000000)
              end || Term <- [Huge, -Huge, lists:duplicate(1001, Huge)]]
     end}.

%% A value of an attribute typed as a presentation's one variable segment is
%% present, with erx_present's text; any other value of it is shown as is.
presentations_project_as_present_test() ->
    Record = #{schema => 1, path => [processes, self()], kind => process, id => self(),
               attrs => #{group_leader => {runtime, {ok, self()}}, domain => {service, {partial, 3}},
                          links => {runtime, {ok, [self()]}}},
               children => []},
    {ok, #{attrs := Attrs}} = erx_web_value:project(Record),
    Pid = erx_present:text(pid, self()),
    ?assertEqual({<<"domain">>, service, partial, {present, <<"domain">>, <<"3">>}},
                 lists:keyfind(<<"domain">>, 1, Attrs)),
    ?assertEqual({<<"group_leader">>, runtime, ok, {present, <<"pid">>, Pid}},
                 lists:keyfind(<<"group_leader">>, 1, Attrs)),
    ?assertMatch({_, runtime, ok, {list, [{printed, _}]}}, lists:keyfind(<<"links">>, 1, Attrs)),
    Odd = Record#{attrs := #{domain => {service, {ok, -1}}}},
    ?assertMatch({ok, #{attrs := [{<<"domain">>, service, ok, {int, <<"-1">>}}]}}, erx_web_value:project(Odd)).

%% Each datum is charged its encoded size against one update: a text of
%% the update less its tag and length fits and one byte more does not, and
%% a term of 16 x 1,000 x 1,000 shared cells, hundreds of megabytes
%% projected, is refused quickly.
projection_stays_within_one_update_test_() ->
    Shared = list_to_tuple(lists:duplicate(16, lists:duplicate(1000, lists:duplicate(1000, 0)))),
    Record = #{schema => 1, path => [], kind => machine, id => <<"m">>,
               attrs => #{build => {kernel, {ok, Shared}}}, children => []},
    {timeout, 30,
     fun() ->
             ?assertMatch({ok, {text, _}}, erx_web_value:datum(binary:copy(<<0>>, 65531))),
             ?assertEqual({error, too_large}, erx_web_value:datum(binary:copy(<<0>>, 65532))),
             {Micros, Answer} = timer:tc(erx_web_value, project, [Record]),
             ?assertEqual({error, too_large}, Answer),
             ?assert(Micros < 2000000),
             ?assertEqual({error, too_large}, erx_web_value:datum(Shared))
     end}.
