%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% EUnit cases of erx_ui_schema:validate/2, generated from abi/formats/ui.txt: each
%% fault reason with the place it names, the node quota and depth at their bounds,
%% the status forms and the marks that relate a kind's properties.
-module(erx_ui_schema_tests).
-include_lib("eunit/include/eunit.hrl").

-define(QUOTA, 10000).

v(Tree) -> erx_ui_schema:validate(Tree, ?QUOTA).

form() ->
    {column, #{pad => 4},
     [{label, #{text => <<"Name">>}, []},
      {input, #{key => name, text => <<"ann">>, on_change => changed}, []},
      {row, #{align => 'end'},
       [{button, #{text => <<"OK">>, on_click => ok}, []},
        {slider, #{min => -10, max => 10, value => 3}, []},
        {list, #{items => [<<"a">>, <<"b">>], selected => 1}, []},
        {image, #{image => <<137, "PNG">>, image_type => png, alt => <<"logo">>}, []}]}]}.

valid_trees_test() ->
    ?assertEqual(ok, v(form())),
    ?assertEqual(ok, v({spacer, #{}, []})),
    ?assertEqual(ok, v({input, #{secret => true, on_submit => {login, 1}}, []})),
    ?assertEqual(ok, v({label, #{text => {kernel, {ok, <<"up">>}}}, []})),
    ?assertEqual(ok, v({label, #{text => {{stopgap, liberx_pool}, {timeout, 5}}}, []})),
    ?assertEqual(ok, v({label, #{present => {runtime, {partial, {bytes, 4096}}}}, []})).

reasons_name_the_first_fault_in_depth_first_order_test() ->
    Bad = fun(Path, Node) -> put_at(form(), Path, Node) end,
    ?assertEqual({error, {not_a_node, []}}, v(nonsense)),
    ?assertEqual({error, {not_a_node, [2, 1]}}, v(Bad([2, 1], {slider, []}))),
    ?assertEqual({error, {unknown_kind, [0]}}, v(Bad([0], {canvas, #{}, []}))),
    ?assertEqual({error, {unknown_property, {[1], placeholder2}}},
                 v(Bad([1], {input, #{placeholder2 => <<>>}, []}))),
    ?assertEqual({error, {unknown_property, {[2, 0], value}}},
                 v(Bad([2, 0], {button, #{value => 1}, []}))),
    ?assertEqual({error, {bad_value, {[0], text}}}, v(Bad([0], {label, #{text => <<255>>}, []}))),
    ?assertEqual({error, {children, [0]}}, v(Bad([0], {label, #{}, [{spacer, #{}, []}]}))),
    ?assertEqual({error, {children, []}}, v({column, #{}, [{spacer, #{}, []} | tail]})),
    %% The first of two faults: the earlier sibling's, before the later one's.
    Two = put_at(Bad([0], {label, #{text => 1}, []}), [2, 0], {canvas, #{}, []}),
    ?assertEqual({error, {bad_value, {[0], text}}}, v(Two)).

duplicate_keys_among_siblings_only_test() ->
    Dup = {column, #{}, [{spacer, #{key => a}, []}, {spacer, #{}, []}, {spacer, #{key => a}, []}]},
    ?assertEqual({error, {duplicate_key, [2]}}, v(Dup)),
    Cousins = {column, #{}, [{row, #{key => 1}, [{spacer, #{key => a}, []}]},
                             {row, #{key => 2}, [{spacer, #{key => a}, []}]}]},
    ?assertEqual(ok, v(Cousins)),
    ?assertEqual({error, {bad_value, {[], key}}}, v({spacer, #{key => binary:copy(<<"k">>, 256)}, []})).

node_quota_is_exact_test() ->
    Tree = {column, #{}, [{spacer, #{}, []} || _ <- lists:seq(1, 9)]},
    ?assertEqual(ok, erx_ui_schema:validate(Tree, 10)),
    ?assertEqual({error, {too_many_nodes, [8]}}, erx_ui_schema:validate(Tree, 9)),
    ?assertEqual({error, {too_many_nodes, []}}, erx_ui_schema:validate(Tree, 0)).

depth_is_at_most_64_test() ->
    ?assertEqual(ok, v(chain(64))),
    ?assertEqual({error, {too_deep, lists:duplicate(64, 0)}}, v(chain(65))).

children_are_at_most_ui_children_test() ->
    Wide = fun(N) -> {column, #{}, lists:duplicate(N, {spacer, #{}, []})} end,
    ?assertEqual(ok, v(Wide(1024))),
    ?assertEqual({error, {children, []}}, v(Wide(1025))).

status_values_test() ->
    L = fun(Text) -> v({label, #{text => Text}, []}) end,
    Bad = {error, {bad_value, {[], text}}},
    ?assertEqual(ok, L({service, unknown})),
    ?assertEqual(ok, L({kernel, {error, enoent}})),
    ?assertEqual(Bad, L({kernel, {ok, 1}})),
    ?assertEqual(Bad, L({kernel, {timeout, 0}})),
    ?assertEqual(Bad, L({kernel, {timeout, 1 bsl 32}})),
    ?assertEqual(Bad, L({{stopgap, not_a_stopgap}, unknown})),
    ?assertEqual(Bad, L({app, {ok, <<"x">>}})),
    %% placeholder carries no status, so an attr() is not its value.
    ?assertEqual({error, {bad_value, {[], placeholder}}},
                 v({input, #{placeholder => {kernel, {ok, <<"x">>}}}, []})).

related_properties_test() ->
    S = fun(Props) -> v({slider, Props, []}) end,
    ?assertEqual(ok, S(#{value => 100})),
    ?assertEqual({error, {bad_value, {[], value}}}, S(#{value => 101})),
    ?assertEqual({error, {bad_value, {[], value}}}, S(#{min => 5, value => 4})),
    ?assertEqual({error, {bad_value, {[], max}}}, S(#{min => 7, max => 7})),
    ?assertEqual({error, {bad_value, {[], min}}}, S(#{min => 200})),
    ?assertEqual({error, {bad_value, {[], max}}}, S(#{max => -1})),
    ?assertEqual({error, {bad_value, {[], selected}}}, v({list, #{selected => 0}, []})),
    ?assertEqual({error, {bad_value, {[], selected}}}, v({list, #{items => [<<"a">>], selected => 1}, []})),
    ?assertEqual({error, {bad_value, {[], items}}},
                 v({list, #{items => lists:duplicate(257, <<"a">>)}, []})),
    ?assertEqual({error, {bad_value, {[], text}}}, v({input, #{secret => true, text => <<"pw">>}, []})),
    ?assertEqual(ok, v({input, #{secret => false, text => <<"pw">>}, []})).

tables_test() ->
    #{number := 10, state := text, fixed := [secret], takes := Takes} = erx_ui_schema:kind(input),
    ?assert(lists:member(key, Takes)),
    #{type := {integer, -2147483648, 2147483647}, default := 0} = erx_ui_schema:property(min),
    ?assertEqual(error, erx_ui_schema:kind(nonsense)),
    ?assertEqual([{png, 1, <<"image/png">>}], erx_ui_schema:images()).

chain(1) -> {spacer, #{}, []};
chain(N) -> {column, #{}, [chain(N - 1)]}.

put_at(_Tree, [], Node) ->
    Node;
put_at({Kind, Props, Children}, [Index | Rest], Node) ->
    {Before, [Child | After]} = lists:split(Index, Children),
    {Kind, Props, Before ++ [put_at(Child, Rest, Node) | After]}.
