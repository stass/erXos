%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The fuzz target of erx_ui_schema:validate/2, the validator of the widget trees a
%% client sends (docs/design-display.md, "Widget trees"). Each round builds a random
%% valid tree from the module's tables, which it must accept, and then breaks it in
%% one place, which it must refuse with that place's reason and path; it also
%% validates a hostile term near the shape of a tree, which must answer ok or a
%% fault whose path names a node of the term, and never raise.
-module(erx_ui_schema_fuzz).
-export([run/1]).

-define(ROUNDS, 4000).
-define(REASONS, [not_a_node, unknown_kind, unknown_property, bad_value, children,
                  duplicate_key, too_many_nodes, too_deep]).

run([Seed]) ->
    rand:seed(exsss, {list_to_integer(Seed), 17, 29}),
    try
        lists:foreach(fun round/1, lists:seq(1, ?ROUNDS)),
        io:format("fuzz: ~b rounds ok~n", [?ROUNDS])
    catch
        Class:Reason:Stack ->
            io:format("fuzz failed: ~p:~P~n~P~n", [Class, Reason, 40, Stack, 20]),
            halt(1)
    end.

round(N) ->
    Tree = tree(1),
    Count = count(Tree),
    expect(ok, Tree, Count, valid),
    {Broken, Quota, Expected} = break(rand:uniform(7), Tree, Count),
    expect(Expected, Broken, Quota, broken),
    hostile(hostile_tree(4), N).

expect(Expected, Tree, Quota, What) ->
    case erx_ui_schema:validate(Tree, Quota) of
        Expected -> ok;
        Got -> error({disagrees_with_reference, What, Expected, Got, Tree})
    end.

hostile(Term, _N) ->
    case erx_ui_schema:validate(Term, 50) of
        ok -> ok;
        {error, {Reason, Where}} ->
            true = lists:member(Reason, ?REASONS),
            Path = case Where of {P, _Property} -> P; P -> P end,
            exists(Term, Path) orelse error({path_names_no_node, Term, Where})
    end.

%% A valid tree, at most five levels and a few children per container.
tree(Depth) ->
    Kinds = erx_ui_schema:kinds(),
    Kind = lists:nth(rand:uniform(length(Kinds)), Kinds),
    #{takes := Takes, children := TakesChildren} = erx_ui_schema:kind(Kind),
    Props = fix(Kind, maps:from_list([{P, value(P)} || P <- Takes, P =/= key, rand:uniform(3) =:= 1])),
    Children = case TakesChildren andalso Depth < 5 of
        true -> keyed([tree(Depth + 1) || _ <- lists:seq(1, rand:uniform(4) - 1)]);
        false -> []
    end,
    {Kind, Props, Children}.

%% Siblings carry keys unique among them, or none.
keyed(Children) ->
    [case rand:uniform(3) of
         1 -> {K, P#{key => I}, C};
         2 -> {K, P#{key => <<"k", (integer_to_binary(I))/binary>>}, C};
         3 -> {K, P, C}
     end || {I, {K, P, C}} <- lists:enumerate(Children)].

%% The marks that relate a kind's properties, made to hold.
fix(slider, Props) ->
    Low = rand:uniform(2000) - 1000,
    High = Low + rand:uniform(500),
    Props#{min => Low, max => High, value => Low + rand:uniform(High - Low + 1) - 1};
fix(list, Props = #{items := Items, selected := _}) when Items =/= [] ->
    Props#{selected => rand:uniform(length(Items)) - 1};
fix(list, Props) ->
    maps:remove(selected, Props);
fix(input, Props = #{secret := true}) ->
    maps:remove(text, Props);
fix(_Kind, Props) ->
    Props.

value(Property) ->
    #{type := Type, status := Status} = erx_ui_schema:property(Property),
    Plain = plain(Type),
    case Status andalso rand:uniform(3) of
        1 -> {lists:nth(rand:uniform(3), [kernel, service, runtime]), {ok, Plain}};
        2 -> {{stopgap, liberx_pool}, lists:nth(rand:uniform(3), [unknown, {timeout, 7}, {partial, Plain}])};
        _ -> Plain
    end.

plain({integer, Min, Max}) -> lists:nth(rand:uniform(3), [Min, Max, Min + rand:uniform(Max - Min + 1) - 1]);
plain({text, Max}) -> text(Max);
plain({bytes, Max}) -> binary:copy(<<7>>, rand:uniform(min(Max, 64) + 1) - 1);
plain({list, {text, TextMax}, Max}) -> [text(TextMax) || _ <- lists:seq(1, rand:uniform(min(Max, 8) + 1) - 1)];
plain({enum, Atoms}) -> lists:nth(rand:uniform(length(Atoms)), Atoms);
plain({image, Atoms}) -> lists:nth(rand:uniform(length(Atoms)), Atoms);
plain(boolean) -> rand:uniform(2) =:= 1;
plain(event) -> {event, rand:uniform(100)};
plain(presentation) -> {bytes, rand:uniform(1 bsl 20)}.

text(Max) ->
    case rand:uniform(4) of
        1 -> binary:copy(<<"a">>, Max);
        _ -> unicode:characters_to_binary(lists:sublist([$h, 233, 8364, 128512, $i], rand:uniform(5)))
    end.

%% Breaks a valid tree in one place; answers the tree, the quota to validate it
%% with and the fault the validator must report.
break(1, Tree, Count) ->
    {Path, _Node} = some_node(Tree),
    Junk = lists:nth(rand:uniform(4), [label, {label, #{}}, {label, [], []}, {label, #{}, nil}]),
    {put_at(Tree, Path, Junk), Count, {error, {not_a_node, Path}}};
break(2, Tree, Count) ->
    {Path, {_Kind, Props, Children}} = some_node(Tree),
    {put_at(Tree, Path, {canvas, Props, Children}), Count, {error, {unknown_kind, Path}}};
break(3, Tree, Count) ->
    {Path, {Kind, Props, Children}} = some_node(Tree),
    #{takes := Takes} = erx_ui_schema:kind(Kind),
    Unknown = hd([P || P <- erx_ui_schema:properties() ++ [zz_unknown], not lists:member(P, Takes)]),
    {put_at(Tree, Path, {Kind, Props#{Unknown => 0}, Children}), Count,
     {error, {unknown_property, {Path, Unknown}}}};
break(4, Tree, Count) ->
    {Path, {Kind, Props, Children}} = some_node(Tree),
    #{takes := Takes} = erx_ui_schema:kind(Kind),
    Typed = [P || P <- Takes, maps:get(type, erx_ui_schema:property(P)) =/= event],
    Property = lists:nth(rand:uniform(length(Typed)), Typed),
    Bad = bad(maps:get(type, erx_ui_schema:property(Property))),
    {put_at(Tree, Path, {Kind, Props#{Property => Bad}, Children}), Count,
     {error, {bad_value, {Path, Property}}}};
break(5, Tree, Count) ->
    case [N || N = {_, {K, _, _}} <- nodes(Tree), not maps:get(children, erx_ui_schema:kind(K))] of
        [] -> break(7, Tree, Count);
        Leaves ->
            {Path, {Kind, Props, []}} = lists:nth(rand:uniform(length(Leaves)), Leaves),
            {put_at(Tree, Path, {Kind, Props, [{spacer, #{}, []}]}), Count + 1, {error, {children, Path}}}
    end;
break(6, Tree, Count) ->
    case [N || N = {_, {_, _, [_, _ | _]}} <- nodes(Tree)] of
        [] -> break(7, Tree, Count);
        Parents ->
            {Path, {Kind, Props, Children}} = lists:nth(rand:uniform(length(Parents)), Parents),
            I = rand:uniform(length(Children) - 1),
            J = I + rand:uniform(length(Children) - I),
            Keyed = [case Index of
                         _ when Index =:= I; Index =:= J -> {K, P#{key => dup}, C};
                         _ -> {K, P, C}
                     end || {Index, {K, P, C}} <- lists:enumerate(Children)],
            {put_at(Tree, Path, {Kind, Props, Keyed}), Count, {error, {duplicate_key, Path ++ [J - 1]}}}
    end;
break(7, Tree, Count) ->
    case rand:uniform(2) of
        1 ->
            {Last, _} = lists:last(nodes(Tree)),
            {Tree, Count - 1, {error, {too_many_nodes, Last}}};
        2 ->
            {Path, _Node} = some_node(Tree),
            Levels = 65 - length(Path),
            {put_at(Tree, Path, chain(Levels)), 1000, {error, {too_deep, Path ++ lists:duplicate(Levels - 1, 0)}}}
    end.

bad({integer, _Min, Max}) -> lists:nth(rand:uniform(2), [Max + 1, one]);
bad({text, Max}) -> lists:nth(rand:uniform(3), [binary:copy(<<"a">>, Max + 1), <<"a", 16#c0, 16#80>>, "list"]);
bad({bytes, Max}) -> lists:nth(rand:uniform(2), [binary:copy(<<0>>, Max + 1), [0]]);
bad({list, {text, TextMax}, Max}) ->
    lists:nth(rand:uniform(3), [[<<>> | tail], lists:duplicate(Max + 1, <<>>), [binary:copy(<<"a">>, TextMax + 1)]]);
bad({enum, _Atoms}) -> nowhere;
bad({image, _Atoms}) -> gif;
bad(boolean) -> 0;
bad(key) -> lists:nth(rand:uniform(3), [binary:copy(<<"k">>, 256), 1.0, {k}]);
bad(presentation) -> lists:nth(rand:uniform(3), [{<<"bytes">>, 1}, bytes, {kernel, {timeout, 0}}]).

chain(1) -> {spacer, #{}, []};
chain(N) -> {column, #{}, [chain(N - 1)]}.

%% Every node with its path, in depth-first order.
nodes(Tree) -> nodes(Tree, []).
nodes({_, _, Children} = Node, Path) ->
    [{Path, Node} | lists:append([nodes(C, Path ++ [I - 1]) || {I, C} <- lists:enumerate(Children)])].

some_node(Tree) ->
    All = nodes(Tree),
    lists:nth(rand:uniform(length(All)), All).

count(Tree) -> length(nodes(Tree)).

put_at(_Tree, [], Node) ->
    Node;
put_at({Kind, Props, Children}, [Index | Rest], Node) ->
    {Before, [Child | After]} = lists:split(Index, Children),
    {Kind, Props, Before ++ [put_at(Child, Rest, Node) | After]}.

%% Whether Path, child indexes from the root, leads to an element of the term.
exists(_Term, []) -> true;
exists({_, _, Children}, [Index | Rest]) when is_list(Children) ->
    case nth_child(Children, Index) of
        {ok, Child} -> exists(Child, Rest);
        none -> false
    end;
exists(_Term, _Path) -> false.

nth_child([Child | _], 0) -> {ok, Child};
nth_child([_ | Rest], N) -> nth_child(Rest, N - 1);
nth_child(_, _) -> none.

%% A term near the shape of a tree: kinds, property names and values drawn from
%% the schema and from outside it, children lists that may be improper.
hostile_tree(0) ->
    lists:nth(rand:uniform(4), [{spacer, #{}, []}, spacer, {}, []]);
hostile_tree(Depth) ->
    Kinds = erx_ui_schema:kinds() ++ [canvas, <<"label">>, 7],
    Kind = lists:nth(rand:uniform(length(Kinds)), Kinds),
    Names = erx_ui_schema:properties() ++ [zz, <<"text">>],
    Props = maps:from_list([{lists:nth(rand:uniform(length(Names)), Names), hostile_value()}
                            || _ <- lists:seq(1, rand:uniform(4) - 1)]),
    Children = [hostile_tree(Depth - 1) || _ <- lists:seq(1, rand:uniform(4) - 1)],
    case rand:uniform(8) of
        1 -> {Kind, Props};
        2 -> {Kind, Props, Children ++ improper};
        3 -> {Kind, maps:to_list(Props), Children};
        _ -> {Kind, Props, Children}
    end.

hostile_value() ->
    lists:nth(rand:uniform(12),
              [0, -1, 1 bsl 40, <<>>, <<255>>, true, fill, png, [<<"a">>], {kernel, {ok, <<"x">>}},
               {{stopgap, nope}, unknown}, {bytes, 1}]).
