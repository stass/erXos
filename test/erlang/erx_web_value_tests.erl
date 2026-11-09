%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_web_value (docs/design-web.md, "Values"): each bound of
%% datum() at its limit and one past it, hostile terms that must project in
%% bounded time and size, and a record's wire form.
-module(erx_web_value_tests).
-include_lib("eunit/include/eunit.hrl").

nested(0, Leaf) -> Leaf;
nested(Levels, Leaf) -> [nested(Levels - 1, Leaf)].

datum_depth({Container, Elements}) when Container =:= list; Container =:= tuple ->
    1 + lists:max([0 | [datum_depth(Element) || Element <- Elements]]);
datum_depth(_Datum) -> 0.

seven_levels_are_kept_and_an_eighth_container_is_printed_test() ->
    ?assertEqual(7, datum_depth(erx_web_value:datum(nested(7, 1)))),
    Eight = erx_web_value:datum(nested(8, 1)),
    ?assertEqual(7, datum_depth(Eight)),
    ?assertEqual({list, [{printed, <<"[1]">>}]}, innermost(Eight, 6)).

innermost(Datum, 0) -> Datum;
innermost({list, [Element]}, Levels) -> innermost(Element, Levels - 1).

a_tuple_counts_as_a_level_test() ->
    Term = nested(6, {nested(1, x)}),
    ?assertMatch({tuple, [{printed, <<"[x]">>}]}, innermost(erx_web_value:datum(Term), 6)).

list_and_tuple_bounds_test() ->
    ?assertMatch({list, L} when length(L) =:= 1000, erx_web_value:datum(lists:seq(1, 1000))),
    ?assertMatch({printed, _}, erx_web_value:datum(lists:seq(1, 1001))),
    ?assertMatch({tuple, L} when length(L) =:= 16, erx_web_value:datum(list_to_tuple(lists:seq(1, 16)))),
    ?assertMatch({printed, _}, erx_web_value:datum(list_to_tuple(lists:seq(1, 17)))),
    ?assertEqual({printed, <<"[a|b]">>}, erx_web_value:datum([a | b])).

scalar_bounds_test() ->
    Forty = binary_to_integer(binary:copy(<<"9">>, 39)),
    ?assertEqual({int, <<"-", (integer_to_binary(Forty))/binary>>}, erx_web_value:datum(-Forty)),
    ?assertMatch({printed, _}, erx_web_value:datum(Forty * 100 + 99)),
    ?assertEqual({int, <<"0">>}, erx_web_value:datum(0)),
    Long = binary_to_atom(binary:copy(<<"a">>, 255)),
    ?assertEqual({atom, atom_to_binary(Long)}, erx_web_value:datum(Long)),
    %% 128 two-byte characters: 128 characters, but 256 bytes.
    Wide = binary_to_atom(binary:copy(<<"\x{e9}"/utf8>>, 128)),
    ?assertMatch({printed, _}, erx_web_value:datum(Wide)),
    ?assertEqual({text, <<16#C0, 0, 27>>}, erx_web_value:datum(<<16#C0, 0, 27>>)),
    ?assertEqual({printed, <<"<<1:1>>">>}, erx_web_value:datum(<<1:1>>)).

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
                  {Micros, Datum} = timer:tc(erx_web_value, datum, [Term]),
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
    ?assertEqual(#{path => [], kind => <<"machine">>, id => {text, <<"m">>},
                   attrs => [{atom_to_binary(First), kernel, partial, {list, [{int, <<"1">>}]}},
                             {atom_to_binary(Second), {stopgap, <<"liberx_pool">>}, {timeout, 5}, {list, []}}],
                   children => {partial, [{text, <<"a%2Eb%2Fc">>}, {text, <<"7">>}, {text, Name}]}},
                 erx_web_value:project(Record)),
    Statuses = #{First => {service, unknown}, Second => {runtime, {error, {badarg, x}}}},
    ?assertMatch(#{attrs := [{_, service, unknown, {list, []}},
                             {_, runtime, error, {tuple, [{atom, <<"badarg">>}, {atom, <<"x">>}]}}],
                   children := {unknown, []}},
                 erx_web_value:project(Record#{attrs := Statuses, children := unknown})).
