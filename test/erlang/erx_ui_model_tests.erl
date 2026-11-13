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

%% pair/3 and hit/4 (docs/design-display.md, "Widget trees", and
%% "Verification and testing"). An application's tree is {Kind, Props,
%% Children}; realised_nodes/1 reads a realised tree back as the inserts that build
%% it from nothing, {Id, Parent, Kind, Props} in depth-first order.

-define(EDITS, 500).

pair_numbers_a_new_tree_in_depth_first_order_test() ->
    Tree = {column, #{}, [{label, #{text => <<"a">>}, []},
                          {button, #{text => <<"b">>, on_click => go}, []}]},
    {Ui, Next} = erx_ui_model:pair(erx_ui_model:empty(), Tree, 1),
    ?assertEqual(4, Next),
    ?assertEqual([{1, 0, column, #{}}, {2, 1, label, #{text => <<"a">>}},
                  {3, 1, button, #{text => <<"b">>, on_click => go}}], realised_nodes(Ui)),
    ?assertEqual({Ui, 4}, erx_ui_model:pair(Ui, Tree, 4)),
    ?assertEqual([commit], erx_ui_model:delta(Ui, Ui)).

a_keyed_child_moved_among_its_siblings_keeps_its_number_and_state_test() ->
    Input = fun(Key) -> {input, #{key => Key, on_change => {typed, Key}}, []} end,
    {Ui, Next} = erx_ui_model:pair(erx_ui_model:empty(), {row, #{}, [Input(a), Input(b)]}, 1),
    {fire, {typed, b}, {change, <<"hi">>}, Typed} = erx_ui_model:hit(Ui, 3, on_change, <<"hi">>),
    {Swapped, Next} = erx_ui_model:pair(Typed, {row, #{}, [Input(b), Input(a)]}, Next),
    ?assertMatch([{1, 0, row, _}, {3, 1, input, #{text := <<"hi">>}}, {2, 1, input, _}], realised_nodes(Swapped)),
    ?assertEqual([{move, 3, 0}, commit], erx_ui_model:delta(Typed, Swapped)).

a_subtree_moved_to_another_parent_gets_new_numbers_and_no_state_test() ->
    Input = {input, #{key => x, on_change => typed}, []},
    Before = {column, #{}, [{row, #{key => r1}, [Input]}, {row, #{key => r2}, []}]},
    After = {column, #{}, [{row, #{key => r1}, []}, {row, #{key => r2}, [Input]}]},
    {Ui, Next} = erx_ui_model:pair(erx_ui_model:empty(), Before, 1),
    {fire, typed, _, Typed} = erx_ui_model:hit(Ui, 3, on_change, <<"kept?">>),
    {Moved, _} = erx_ui_model:pair(Typed, After, Next),
    ?assertEqual([{1, 0, column, #{}}, {2, 1, row, #{key => r1}}, {4, 1, row, #{key => r2}},
                  {5, 4, input, #{key => x, on_change => typed}}], realised_nodes(Moved)).

a_fixed_property_changed_is_a_new_node_test() ->
    {Ui, Next} = erx_ui_model:pair(erx_ui_model:empty(), {input, #{}, []}, 1),
    {Secret, _} = erx_ui_model:pair(Ui, {input, #{secret => true}, []}, Next),
    ?assertEqual([{2, 0, input, #{secret => true}}], realised_nodes(Secret)),
    %% An absent fixed property is its default, so false is the same node.
    ?assertMatch({_, Next}, erx_ui_model:pair(Ui, {input, #{secret => false}, []}, Next)).

typed_text_survives_a_tree_that_omits_it_and_yields_to_one_that_sets_it_test() ->
    {Ui, Next} = erx_ui_model:pair(erx_ui_model:empty(), {input, #{}, []}, 1),
    {keep, Typed} = erx_ui_model:hit(Ui, 1, on_change, <<"typed">>),
    {Kept, Next} = erx_ui_model:pair(Typed, {input, #{placeholder => <<"p">>}, []}, Next),
    ?assertEqual([{1, 0, input, #{placeholder => <<"p">>, text => <<"typed">>}}], realised_nodes(Kept)),
    {Set, Next} = erx_ui_model:pair(Kept, {input, #{text => <<"set">>}, []}, Next),
    ?assertEqual([{1, 0, input, #{text => <<"set">>}}], realised_nodes(Set)).

a_kept_value_outside_a_new_range_is_dropped_test() ->
    {Ui, Next} = erx_ui_model:pair(erx_ui_model:empty(), {slider, #{}, []}, 1),
    {keep, Slid} = erx_ui_model:hit(Ui, 1, on_change, 80),
    {Inside, Next} = erx_ui_model:pair(Slid, {slider, #{max => 90}, []}, Next),
    ?assertEqual([{1, 0, slider, #{max => 90, value => 80}}], realised_nodes(Inside)),
    {Outside, Next} = erx_ui_model:pair(Slid, {slider, #{max => 50}, []}, Next),
    ?assertEqual([{1, 0, slider, #{max => 50}}], realised_nodes(Outside)).

pair_refuses_a_number_past_the_last_test() ->
    Last = 16#ffffffff,
    ?assertMatch({_, 16#100000000}, erx_ui_model:pair(erx_ui_model:empty(), {spacer, #{}, []}, Last)),
    ?assertEqual({error, limit},
                 erx_ui_model:pair(erx_ui_model:empty(), {row, #{}, [{spacer, #{}, []}]}, Last)).

hit_drops_what_the_node_does_not_take_test() ->
    Tree = {column, #{}, [{label, #{text => <<"l">>}, []},
                          {slider, #{on_change => slid}, []},
                          {button, #{on_click => go}, []}]},
    {Ui, _} = erx_ui_model:pair(erx_ui_model:empty(), Tree, 1),
    ?assertEqual(drop, erx_ui_model:hit(Ui, 9, on_click, none)),        % not in the tree
    ?assertEqual(drop, erx_ui_model:hit(Ui, 0, on_click, none)),        % the top
    ?assertEqual(drop, erx_ui_model:hit(Ui, 2, on_click, none)),        % a label takes no click
    ?assertEqual(drop, erx_ui_model:hit(Ui, 2, text, none)),            % not an event
    ?assertEqual(drop, erx_ui_model:hit(Ui, 3, on_change, 101)),        % past max
    ?assertEqual(drop, erx_ui_model:hit(Ui, 3, on_change, <<"5">>)),    % not an integer
    ?assertEqual(drop, erx_ui_model:hit(Ui, 4, on_click, 1)),           % a click has no value
    ?assertEqual(drop, erx_ui_model:hit(Ui, 4, {bad}, none)),
    {Input, _} = erx_ui_model:pair(erx_ui_model:empty(), {input, #{on_change => typed}, []}, 1),
    ?assertEqual(drop, erx_ui_model:hit(Input, 1, on_change, {kernel, unknown})),  % a status form
    ?assertMatch({fire, slid, {change, 7}, _}, erx_ui_model:hit(Ui, 3, on_change, 7)),
    ?assertMatch({fire, go, click, _}, erx_ui_model:hit(Ui, 4, on_click, none)).

a_select_carries_the_trees_own_presentation_test() ->
    Label = fun(Present) -> {label, #{present => Present, on_select => picked}, []} end,
    Select = fun(Present) ->
                     {Ui, _} = erx_ui_model:pair(erx_ui_model:empty(), Label(Present), 1),
                     erx_ui_model:hit(Ui, 1, on_select, none)
             end,
    ?assertMatch({fire, picked, {select, pid, <<"<0.1.0>">>}, _}, Select({pid, <<"<0.1.0>">>})),
    ?assertMatch({fire, picked, {select, pid, x}, _}, Select({service, {partial, {pid, x}}})),
    ?assertEqual(drop, Select({service, unknown})),
    ?assertEqual(drop, Select({kernel, {timeout, 5}})),
    {Ui, _} = erx_ui_model:pair(erx_ui_model:empty(), {label, #{on_select => picked}, []}, 1),
    ?assertEqual(drop, erx_ui_model:hit(Ui, 1, on_select, none)).

a_secret_inputs_text_is_never_kept_test() ->
    {Ui, _} = erx_ui_model:pair(erx_ui_model:empty(),
                                {input, #{secret => true, on_submit => login}, []}, 1),
    ?assertEqual({fire, login, {submit, {erx_secret, <<"pw">>}}, Ui},
                 erx_ui_model:hit(Ui, 1, on_submit, <<"pw">>)),
    ?assertEqual({keep, Ui}, erx_ui_model:hit(Ui, 1, on_change, <<"pw">>)).

%% Random trees and edits: pair/3 then delta/2 turns one realised tree into
%% the next, the realised tree reads back as the application's, and pairing
%% a tree again changes nothing.
pair_and_delta_over_random_trees_test() ->
    rand:seed(exsss, {16#a, 16#1, 16#e}),
    lists:foreach(fun(_) -> check_edit() end, lists:seq(1, ?EDITS)).

check_edit() ->
    T1 = app_tree(0),
    T2 = app_edit(T1, 0),
    ?assertEqual(ok, erx_ui_schema:validate(T1, 10000)),
    ?assertEqual(ok, erx_ui_schema:validate(T2, 10000)),
    {R1, N1} = erx_ui_model:pair(erx_ui_model:empty(), T1, 1),
    {R2, N2} = erx_ui_model:pair(R1, T2, N1),
    check({delta_does_not_apply, T1, T2}, {ok, R2}, erx_ui_model:apply_ops(erx_ui_model:delta(R1, R2), R1)),
    check({reads_back_otherwise, T2}, T2, read_back(R2)),
    check({pairs_again_otherwise, T2}, {R2, N2}, erx_ui_model:pair(R2, T2, N2)).

app_tree(Depth) when Depth >= 3 -> {label, #{text => pick([<<"a">>, <<"b">>])}, []};
app_tree(Depth) ->
    case rand:uniform(3) of
        1 -> {label, #{text => pick([<<"a">>, <<"b">>])}, []};
        _ -> {pick([column, row]), #{}, keyed([app_tree(Depth + 1) || _ <- lists:seq(1, rand:uniform(4) - 1)])}
    end.

%% Some children get keys, unique among their siblings.
keyed(Children) ->
    [case rand:uniform(2) of
         1 -> {K, P#{key => I}, C};
         2 -> {K, P, C}
     end || {I, {K, P, C}} <- lists:enumerate(Children)].

%% An edit: a label's text changed, a container's children shuffled, a
%% child dropped or added, or a subtree replaced.
app_edit({Kind, Props, Children}, Depth) ->
    case rand:uniform(5) of
        1 -> app_tree(Depth);
        2 when Kind =:= label -> {label, Props#{text => pick([<<"a">>, <<"c">>])}, []};
        3 when Children =/= [] -> {Kind, Props, shuffle(Children)};
        4 when Children =/= [] -> {Kind, Props, tl(Children)};
        _ -> {Kind, Props, [app_edit(C, Depth + 1) || C <- Children]}
    end.

shuffle(List) -> [X || {_, X} <- lists:sort([{rand:uniform(), X} || X <- List])].

realised_nodes(Ui) ->
    {ok, _} = erx_ui_model:apply_ops(erx_ui_model:delta(erx_ui_model:empty(), Ui), erx_ui_model:empty()),
    [{Id, Parent, Kind, Props} || {insert, Id, Parent, _Index, Kind, Props} <- erx_ui_model:delta(erx_ui_model:empty(), Ui)].

%% The application's tree a realised tree holds.
read_back(Ui) ->
    Nodes = realised_nodes(Ui),
    [{Root, 0, _, _}] = [N || {_, 0, _, _} = N <- Nodes],
    read_back(Root, Nodes).

read_back(Id, Nodes) ->
    {Id, _, Kind, Props} = lists:keyfind(Id, 1, Nodes),
    {Kind, Props, [read_back(C, Nodes) || {C, P, _, _} <- Nodes, P =:= Id]}.
