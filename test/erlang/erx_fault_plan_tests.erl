%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_fault_plan, the stand-ins' one fault vocabulary
%% (docs/design-recovery.md, "Fault injection and tests", layer 2): each of the five
%% faults met by the exchange its rule matches and by no other, the Nth match, rules
%% taken once and in order, and `gone` lasting.

-module(erx_fault_plan_tests).
-include_lib("eunit/include/eunit.hrl").

%% The answers a plan gives to Kinds, asked in turn.
answers(Plan, Kinds) ->
    {Answers, _Plan} = lists:mapfoldl(fun erx_fault_plan:ask/2, Plan, Kinds),
    Answers.

an_empty_plan_passes_every_exchange_test() ->
    ?assertEqual([pass, pass, pass], answers(erx_fault_plan:new([]), [read, write, read])).

each_fault_is_met_once_by_the_next_exchange_of_its_kind_test() ->
    [?assertEqual([pass, Fault, pass, pass], answers(erx_fault_plan:new([{read, Fault}]), [write, read, read, write]))
     || Fault <- [silent, {late, 40}, {error, eio}, {wrong_once, <<0>>}]].

the_nth_match_waits_for_the_nth_exchange_of_its_kind_test() ->
    Plan = erx_fault_plan:new([{{nth, read, 3}, {error, eio}}]),
    ?assertEqual([pass, pass, pass, pass, {error, eio}, pass], answers(Plan, [read, write, read, write, read, read])).

rules_are_taken_in_order_test() ->
    Plan = erx_fault_plan:new([{read, silent}, {read, {error, eio}}]),
    ?assertEqual([silent, {error, eio}, pass], answers(Plan, [read, read, read])).

a_rule_added_later_counts_from_the_plan_s_start_test() ->
    {pass, Plan} = erx_fault_plan:ask(read, erx_fault_plan:new([])),
    ?assertEqual([{error, eio}, pass], answers(erx_fault_plan:add({{nth, read, 2}, {error, eio}}, Plan), [read, read])).

gone_lasts_for_every_later_exchange_of_any_kind_test() ->
    Plan = erx_fault_plan:new([{write, gone}, {read, {error, eio}}]),
    ?assertEqual([pass, gone, gone, gone], answers(Plan, [flush, write, read, flush])).

a_wrong_answer_is_the_answer_or_the_fun_of_the_right_one_test() ->
    ?assertEqual(<<0>>, erx_fault_plan:wrong_answer(<<0>>, <<1, 2>>)),
    ?assertEqual(<<1>>, erx_fault_plan:wrong_answer(fun(<<A, _/binary>>) -> <<A>> end, <<1, 2>>)).

a_rule_that_is_not_a_fault_is_refused_test() ->
    ?assertError({not_a_fault, stall}, erx_fault_plan:new([{read, stall}])),
    ?assertError({not_a_fault, {late, -1}}, erx_fault_plan:new([{read, {late, -1}}])).
