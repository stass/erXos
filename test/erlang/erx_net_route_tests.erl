%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_net_route and erx_net_addr (docs/design-network-stack.md,
%% "Addresses and routes"): the longest-prefix lookup against a linear scan
%% of the rows, the generation, and the address checks.

-module(erx_net_route_tests).

-include_lib("eunit/include/eunit.hrl").

%% --- erx_net_route against a linear scan ------------------------------------

ip4_lookup_matches_linear_scan_test() -> property(4, 1).
ip6_lookup_matches_linear_scan_test() -> property(16, 2).

%% Random puts and deletes over a few prefixes that nest and overlap, with
%% every lookup (global and per interface) checked against the model.
property(Size, Seed) ->
    _ = rand:seed(exsss, {Seed, 16#40, 16#7e}),
    lists:foldl(fun(_, {T, Model}) -> step(Size, T, Model) end,
                {erx_net_route:new(), #{}}, lists:seq(1, 2000)),
    ok.

step(Size, T, Model) ->
    Row = random_row(Size),
    Key = {erx_net_addr:masked(maps:get(prefix, Row), maps:get(plen, Row)),
           maps:get(plen, Row), maps:get(ifname, Row)},
    {T2, Model2} = case rand:uniform(3) of
                       3 -> {erx_net_route:delete(Key, T), maps:remove(Key, Model)};
                       _ -> {erx_net_route:put(Row, T),
                             Model#{Key => Row#{prefix := element(1, Key)}}}
                   end,
    Dst = random_addr(Size),
    ?assertEqual(scan(Dst, maps:values(Model2)), erx_net_route:lookup(Dst, T2)),
    If = rand:uniform(3),
    ?assertEqual(scan(Dst, [R || #{ifname := I} = R <- maps:values(Model2), I =:= If]),
                 erx_net_route:lookup(Dst, If, T2)),
    {T2, Model2}.

%% The model: every row containing Dst, longest prefix, then lowest
%% metric, then lowest interface.
scan(Dst, Rows) ->
    Matches = [{{-L, M, I}, R} || #{prefix := P, plen := L, metric := M, ifname := I} = R <- Rows,
                                  erx_net_addr:masked(Dst, L) =:= P],
    case lists:keysort(1, Matches) of
        [] -> none;
        [{_, R} | _] -> {ok, R}
    end.

%% Addresses drawn from a few top bytes so prefixes nest and collide.
random_addr(Size) ->
    Rest = Size * 8 - 8,
    <<(lists:nth(rand:uniform(3), [10, 11, 255])), (rand:uniform(1 bsl 4) - 1):4,
      0:(Rest - 4)>>.

random_row(Size) ->
    Plens = [0, 1, 4, 8, 9, 12, Size * 8],
    #{prefix => random_addr(Size), plen => lists:nth(rand:uniform(length(Plens)), Plens),
      ifname => rand:uniform(3), gateway => none, metric => rand:uniform(2)}.

generation_moves_only_on_change_test() ->
    Row = #{prefix => <<10, 0, 0, 0>>, plen => 8, ifname => eth0, gateway => none, metric => 0},
    T1 = erx_net_route:put(Row, erx_net_route:new()),
    ?assertEqual(1, erx_net_route:generation(T1)),
    %% The same row written with host bits set is the same row.
    T2 = erx_net_route:put(Row#{prefix := <<10, 1, 2, 3>>}, T1),
    ?assertEqual(1, erx_net_route:generation(T2)),
    T3 = erx_net_route:put(Row#{metric := 5}, T2),
    ?assertEqual(2, erx_net_route:generation(T3)),
    T4 = erx_net_route:delete_interface(eth0, T3),
    ?assertEqual(3, erx_net_route:generation(T4)),
    ?assertEqual(none, erx_net_route:lookup(<<10, 0, 0, 1>>, T4)),
    ?assertEqual(T4, erx_net_route:delete({<<10, 0, 0, 0>>, 8, eth0}, T4)).

bad_rows_refused_test() ->
    Row = #{prefix => <<10, 0, 0, 0>>, plen => 8, ifname => eth0, gateway => none, metric => 0},
    ?assertError(badarg, erx_net_route:put(Row#{plen := 33}, erx_net_route:new())),
    ?assertError(badarg, erx_net_route:put(Row#{prefix := <<1, 2, 3>>}, erx_net_route:new())),
    ?assertError(badarg, erx_net_route:put(Row#{gateway := <<0:128>>}, erx_net_route:new())).

%% --- erx_net_addr -----------------------------------------------------------

scope_test() ->
    ?assertEqual(2, erx_net_addr:scope(<<16#fe80:16, 0:96, 1:16>>)),
    ?assertEqual(2, erx_net_addr:scope(<<1:128>>)),
    ?assertEqual(5, erx_net_addr:scope(<<16#fec0:16, 0:112>>)),
    ?assertEqual(14, erx_net_addr:scope(<<16#2001:16, 16#db8:16, 0:96>>)),
    ?assertEqual(2, erx_net_addr:scope(<<16#ff02:16, 0:112>>)),
    ?assertEqual(14, erx_net_addr:scope(<<16#ff0f:16, 0:112>>)),
    ?assertEqual(5, erx_net_addr:scope(<<16#ff05:16, 0:112>>)),
    ?assert(erx_net_addr:is_link_local(<<16#febf:16, 0:112>>)),
    ?assertNot(erx_net_addr:is_link_local(<<16#fec0:16, 0:112>>)).

broadcast_and_on_link_test() ->
    Row = #{addr => <<192, 168, 1, 10>>, plen => 24, ifname => eth0, flags => [],
            preferred => infinity, valid => infinity, broadcast => <<192, 168, 1, 255>>},
    ?assert(erx_net_addr:is_broadcast(<<192, 168, 1, 255>>, eth0, [Row])),
    ?assertNot(erx_net_addr:is_broadcast(<<192, 168, 1, 255>>, eth1, [Row])),
    ?assert(erx_net_addr:is_broadcast(<<255, 255, 255, 255>>, eth1, [])),
    ?assertNot(erx_net_addr:is_broadcast(<<192, 168, 1, 255>>, eth0, [Row#{plen := 32}])),
    ?assert(erx_net_addr:is_on_link(<<192, 168, 1, 77>>, [Row])),
    ?assertNot(erx_net_addr:is_on_link(<<192, 168, 2, 77>>, [Row])),
    ?assertNot(erx_net_addr:is_on_link(<<127, 0, 0, 1>>, [Row])),
    ?assert(erx_net_addr:is_on_link(<<16#fe80:16, 0:112>>, [])),
    ?assert(erx_net_addr:is_local(<<192, 168, 1, 10>>, [Row])).

matchlen_test() ->
    ?assertEqual(128, erx_net_addr:matchlen(<<5:128>>, <<5:128>>)),
    ?assertEqual(0, erx_net_addr:matchlen(<<1:1, 0:127>>, <<0:128>>)),
    ?assertEqual(126, erx_net_addr:matchlen(<<1:128>>, <<2:128>>)).
