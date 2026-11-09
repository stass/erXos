%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_ui_model's difference (docs/design-display.md,
%% "Widget trees"): apply_ops(delta(A, B), A) == {ok, B} over random trees
%% and edits, each prefix of a delta applies and the rest of the change
%% follows from where it leaves the tree, as the browser renderer sends a
%% long change, and an unchanged tree or subtree emits nothing.
%%
%% A test tree is {Id, Kind, Props, Children} with the server's numbers
%% already given, or none for the empty tree. An edit keeps a node's number,
%% parent and kind, as pair/3 does, or replaces the node with a new subtree
%% under new numbers, which is how a subtree reaches another parent.
-module(erx_ui_model_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PAIRS, 1000).

delta_turns_one_tree_into_the_other_test() ->
    rand:seed(exsss, {16#e, 16#7, 16#05}),
    lists:foreach(fun(_) -> check_pair() end, lists:seq(1, ?PAIRS)).

check_pair() ->
    {TreeA, Next} = gen_root(1),
    {TreeB, _} = edit_root(TreeA, Next),
    A = realise(TreeA),
    B = realise(TreeB),
    Ops = erx_ui_model:delta(A, B),
    check({delta_does_not_apply, TreeA, TreeB, Ops}, {ok, B}, erx_ui_model:apply_ops(Ops, A)),
    check({unchanged_tree_emits, TreeB}, [commit], erx_ui_model:delta(B, B)),
    Prefix = lists:sublist(Ops, rand:uniform(length(Ops) + 1) - 1),
    {ok, Partial} = erx_ui_model:apply_ops(Prefix, A),
    check({rest_does_not_apply, TreeA, TreeB, Prefix}, {ok, B},
          erx_ui_model:apply_ops(erx_ui_model:delta(Partial, B), Partial)).

one_changed_property_is_one_set_test() ->
    Before = {1, column, #{}, [{2, label, #{text => <<"a">>}, []},
                               {3, row, #{}, [{4, label, #{text => <<"b">>, width => 4}, []}]}]},
    After = {1, column, #{}, [{2, label, #{text => <<"a">>}, []},
                              {3, row, #{}, [{4, label, #{text => <<"c">>}, []}]}]},
    ?assertEqual([{set, 4, #{text => <<"c">>}, [width]}, commit],
                 erx_ui_model:delta(realise(Before), realise(After))).

a_child_moved_to_the_front_is_one_move_test() ->
    Row = fun(Order) -> {1, row, #{}, [{Id, label, #{}, []} || Id <- Order]} end,
    ?assertEqual([{move, 6, 0}, commit],
                 erx_ui_model:delta(realise(Row([2, 3, 4, 5, 6])), realise(Row([6, 2, 3, 4, 5])))).

%% An index counts the siblings as they stand once the moved node is out.
a_move_index_counts_without_the_moved_node_test() ->
    Row = fun(Order) -> {1, row, #{}, [{Id, label, #{}, []} || Id <- Order]} end,
    ?assertEqual([{move, 2, 2}, commit],
                 erx_ui_model:delta(realise(Row([2, 3, 4])), realise(Row([3, 4, 2])))).

apply_ops_refuses_an_operation_that_does_not_fit_test() ->
    Ui = realise({1, column, #{}, [{2, label, #{}, []}]}),
    Refused = fun(Op) -> {error, {Reason, Op}} = erx_ui_model:apply_ops([Op], Ui), Reason end,
    ?assertEqual(node_exists, Refused({insert, 2, 1, 0, label, #{}})),
    ?assertEqual(root_exists, Refused({insert, 3, 0, 0, label, #{}})),
    ?assertEqual(bad_index, Refused({insert, 3, 1, 2, label, #{}})),
    ?assertEqual(no_node, Refused({insert, 3, 9, 0, label, #{}})),
    ?assertEqual(no_node, Refused({remove, 9})),
    ?assertEqual(bad_index, Refused({move, 2, 1})),
    ?assertEqual(bad_op, Refused({remove, 0})),
    ?assertEqual(bad_op, Refused({set, 2, [], []})),
    ?assertEqual(bad_op, Refused({set, 2, #{}, [a | b]})),
    ?assertEqual({error, {bad_op, foo}}, erx_ui_model:apply_ops([commit | foo], Ui)).

%% Checks a property, raising its name and the case when it fails.
check(_Case, Expected, Expected) -> ok;
check(Case, Expected, Actual) -> erlang:error({Case, {expected, Expected}, {actual, Actual}}).

%% The realised tree a renderer has once it applies every node's insert.
realise(none) -> erx_ui_model:empty();
realise(Tree) ->
    {ok, Ui} = erx_ui_model:apply_ops(inserts(Tree, 0, 0), erx_ui_model:empty()),
    Ui.

inserts({Id, Kind, Props, Children}, Parent, Index) ->
    [{insert, Id, Parent, Index, Kind, Props}
     | lists:append([inserts(Child, Id, I) || {I, Child} <- lists:enumerate(0, Children)])].

%% Random trees: at most 4 deep below the root and 4 children a node.

gen_root(Next) ->
    case rand:uniform(20) of
        1 -> {none, Next};
        _ -> gen(Next, 0)
    end.

gen(Id, Depth) ->
    Width = case Depth of 4 -> 0; _ -> rand:uniform(5) - 1 end,
    {Children, Next} = lists:mapfoldl(fun(_, N) -> gen(N, Depth + 1) end, Id + 1, lists:seq(1, Width)),
    {{Id, pick([column, row, stack, label]), gen_props(), Children}, Next}.

gen_props() -> maps:from_list([{Key, gen_value()} || Key <- [width, text, align, key], rand:uniform(2) =:= 1]).

gen_value() -> pick([0, 1, 2, <<"a">>, <<"b">>, start, fill]).

%% Random edits of a tree, Next its first unused number.

edit_root(none, Next) -> gen_root(Next);
edit_root(Tree, Next) ->
    case rand:uniform(20) of
        1 -> {none, Next};
        _ -> edit(Tree, Next, 0)
    end.

edit({Id, Kind, Props, Children}, Next, Depth) ->
    case rand:uniform(10) of
        1 ->
            gen(Next, Depth);
        _ ->
            Kept = [Child || Child <- Children, rand:uniform(7) > 1],
            {Edited, Next1} = lists:mapfoldl(fun(Child, N) -> edit(Child, N, Depth + 1) end, Next, Kept),
            {Grown, Next2} = grow(reorder(Edited), Next1, Depth + 1),
            {{Id, Kind, edit_props(Props), Grown}, Next2}
    end.

edit_props(Props) ->
    lists:foldl(fun(Key, Acc) ->
                        case rand:uniform(6) of
                            1 -> maps:remove(Key, Acc);
                            2 -> Acc#{Key => gen_value()};
                            _ -> Acc
                        end
                end, Props, [width, text, align, key]).

reorder(Children) ->
    case rand:uniform(3) of
        1 -> [Child || {_, Child} <- lists:sort([{rand:uniform(), Child} || Child <- Children])];
        _ -> Children
    end.

grow(Children, Next, Depth) when Depth > 4 -> {Children, Next};
grow(Children, Next, Depth) ->
    case rand:uniform(3) of
        1 ->
            {New, Next1} = gen(Next, Depth),
            {Before, After} = lists:split(rand:uniform(length(Children) + 1) - 1, Children),
            {Before ++ [New | After], Next1};
        _ ->
            {Children, Next}
    end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
