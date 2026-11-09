%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%%
%% EUnit cases of erx_nd6_rtr, after the branches of nd6_ra_input,
%% defrtrlist_update, prelist_update, defrouter_select_fib and
%% in6_get_stableifid, and the bounds of 16 routers and 16 prefixes.

-module(erx_nd6_rtr_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PREFIX, <<16#2001:16, 16#db8:16, 0:96>>).
-define(ALL_NODES, <<16#ff02:16, 0:96, 1:16>>).
-define(MAC, <<2, 0, 0, 0, 0, 1>>).
-define(ONLINK_AUTO, 16#c0).

new() ->
    erx_nd6_rtr:new(#{ifname => <<"vtnet0">>, if_mtu => 1500,
                      gen => erx_net_rand:new(<<7:128>>)}).

router(N) -> <<16#fe80:16, 0:96, N:16>>.

pkt(Src) -> #{src => Src, dst => ?ALL_NODES, hlim => 255, fragmented => false}.

pi(Prefix, Valid, Preferred) ->
    #{len => 64, flags => ?ONLINK_AUTO, valid => Valid, preferred => Preferred, prefix => Prefix}.

ra(Lifetime, Opts) -> {ra, 64, 0, Lifetime, 0, 0, Opts}.

%% An advertisement of ?PREFIX from router 1 at Now.
advertise(Now, Valid, S) ->
    erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{prefixes => [pi(?PREFIX, Valid, Valid)]}), Now, S).

%% A digest whose first 8 bytes are the identifier Id.
digest(Id) -> <<Id:8/binary, 0:192>>.

%% Answers every identifier request among Actions with Id.
answer(Actions, Id, Now, S) ->
    lists:foldl(fun({ifid_request, Ref, _}, {Acc, St}) ->
                        {More, St2} = erx_nd6_rtr:ifid(Ref, digest(Id), Now, St),
                        {Acc ++ More, St2};
                   (_, Acc) -> Acc
                end, {[], S}, Actions).

requests(Actions) -> [Ref || {ifid_request, Ref, _} <- Actions].

ra_forms_router_prefix_and_address_test() ->
    {A1, S1} = advertise(0, 3600, new()),
    ?assertMatch([#{addr := _, pref := 0}], erx_nd6_rtr:routers(S1)),
    ?assertMatch([#{prefix := ?PREFIX, plen := 64, onlink := true}], erx_nd6_rtr:prefixes(S1)),
    ?assertEqual([{?PREFIX, 0}], requests(A1)),
    ?assert(lists:member({cache_lladdr, router(1), none}, A1)),
    %% The request is pending, so a second advertisement asks nothing more.
    {A2, S2} = advertise(10, 3600, S1),
    ?assertEqual([], requests(A2)),
    Id = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    {A3, S3} = answer(A1, Id, 20, S2),
    Addr = <<16#2001:16, 16#db8:16, 0:32, Id/binary>>,
    ?assertMatch([{dad, #{addr := Addr, flags := [tentative, autoconf]}}], A3),
    S4 = erx_nd6_rtr:dad_done(Addr, ok, S3),
    ?assertMatch([#{addr := Addr, flags := [autoconf], valid := 3600010}],
                 erx_nd6_rtr:addresses(S4)),
    %% The default route waits for a selected router.
    S5 = erx_nd6_rtr:select_router(fun(_) -> true end, S4),
    ?assert(lists:member(#{prefix => <<0:128>>, plen => 0, ifname => <<"vtnet0">>,
                           gateway => router(1), metric => 0}, erx_nd6_rtr:routes(S5))),
    %% The router's lifetime ends 1,800 s after its last advertisement,
    %% the address's and the prefix's 3,600 s after theirs.
    ?assertEqual(1800011, erx_nd6_rtr:next_deadline(S5)),
    {[], S6} = erx_nd6_rtr:tick(1800011, S5),
    ?assertEqual([], erx_nd6_rtr:routers(S6)),
    {[], S7} = erx_nd6_rtr:tick(3600011, S6),
    ?assertEqual([], erx_nd6_rtr:addresses(S7)),
    ?assertEqual([], erx_nd6_rtr:prefixes(S7)).

bad_advertisements_dropped_test() ->
    S = new(),
    Ra = ra(1800, #{prefixes => [pi(?PREFIX, 3600, 3600)]}),
    {[], S1} = erx_nd6_rtr:ra((pkt(router(1)))#{hlim := 254}, Ra, 0, S),
    {[], S2} = erx_nd6_rtr:ra(pkt(?PREFIX), Ra, 0, S1),
    {[], S3} = erx_nd6_rtr:ra((pkt(router(1)))#{fragmented := true}, Ra, 0, S2),
    ?assertEqual(2, maps:get(bad_ra, erx_nd6_rtr:stats(S3))),
    ?assertEqual([], erx_nd6_rtr:routers(S3)),
    %% A source link-layer address of the wrong length counts the
    %% advertisement bad after its router took effect, as FreeBSD orders it.
    {A4, S4} = erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{slla => <<1, 2, 3, 4, 5, 6, 7, 8>>}), 0, S3),
    ?assertEqual([], A4),
    ?assertEqual(3, maps:get(bad_ra, erx_nd6_rtr:stats(S4))),
    ?assertMatch([_], erx_nd6_rtr:routers(S4)),
    {A5, _} = erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{slla => ?MAC}), 0, S4),
    ?assertEqual([{cache_lladdr, router(1), ?MAC}], A5).

prefix_checks_test() ->
    Bad = [pi(<<16#fe80:16, 0:112>>, 3600, 3600), pi(<<16#ff02:16, 0:112>>, 3600, 3600),
           (pi(?PREFIX, 3600, 3600))#{len := 129}, pi(?PREFIX, 0, 0),
           (pi(?PREFIX, 3600, 3600))#{flags := 0}],
    {A, S} = erx_nd6_rtr:ra(pkt(router(1)), ra(0, #{prefixes => Bad}), 0, new()),
    ?assertEqual([], erx_nd6_rtr:prefixes(S)),
    ?assertEqual([], requests(A)),
    %% A preferred lifetime above the valid one lists the prefix but forms
    %% no address; a prefix that is not a /64 forms none either.
    {A2, S2} = erx_nd6_rtr:ra(pkt(router(1)),
                              ra(0, #{prefixes => [pi(?PREFIX, 60, 120),
                                                   (pi(<<16#2001:16, 1:16, 0:96>>, 60, 60))#{len := 48}]}),
                              0, new()),
    ?assertEqual(2, length(erx_nd6_rtr:prefixes(S2))),
    ?assertEqual([], requests(A2)).

lists_are_bounded_test() ->
    Prefixes = [pi(<<16#2001:16, N:16, 0:96>>, 3600, 3600) || N <- lists:seq(1, 17)],
    S = lists:foldl(fun(N, St) ->
                            {_, St2} = erx_nd6_rtr:ra(pkt(router(N)), ra(1800, #{}), 0, St),
                            St2
                    end, new(), lists:seq(1, 17)),
    {_, S2} = erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{prefixes => Prefixes}), 0, S),
    ?assertEqual(16, length(erx_nd6_rtr:routers(S2))),
    ?assertEqual(16, length(erx_nd6_rtr:prefixes(S2))),
    ?assertMatch(#{routers_ignored := 1, prefixes_ignored := 1}, erx_nd6_rtr:stats(S2)),
    %% A listed router keeps refreshing with the list full, and the
    %% seventeenth stays out.
    {_, S3} = erx_nd6_rtr:ra(pkt(router(2)), ra(9000, #{}), 1000, S2),
    ?assertMatch([#{expire := 9001000}],
                 [R || #{addr := A} = R <- erx_nd6_rtr:routers(S3), A =:= router(2)]),
    ?assertNot(lists:any(fun(#{addr := A}) -> A =:= router(17) end, erx_nd6_rtr:routers(S3))).

%% nd6.c:984-987 and :1041: an address is deprecated once its preferred lifetime has passed,
%% and preferred again when an advertisement extends that lifetime.
deprecation_test() ->
    Id = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    Advertise = fun(Now, S) ->
                        erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{prefixes => [pi(?PREFIX, 3600, 600)]}),
                                       Now, S)
                end,
    {A1, S1} = Advertise(0, new()),
    {_, S2} = answer(A1, Id, 0, S1),
    S3 = erx_nd6_rtr:dad_done(<<16#2001:16, 16#db8:16, 0:32, Id/binary>>, ok, S2),
    Flags = fun(St) -> [F || #{flags := F} <- erx_nd6_rtr:addresses(St)] end,
    ?assertEqual(600001, erx_nd6_rtr:next_deadline(S3)),
    {[], S4} = erx_nd6_rtr:tick(600000, S3),
    ?assertEqual([[autoconf]], Flags(S4)),
    {[], S5} = erx_nd6_rtr:tick(600001, S4),
    ?assertEqual({[[deprecated, autoconf]], 1800001}, {Flags(S5), erx_nd6_rtr:next_deadline(S5)}),
    {_, S6} = Advertise(700000, S5),
    ?assertEqual([[autoconf]], Flags(S6)).

two_hour_rule_test() ->
    Id = <<1, 2, 3, 4, 5, 6, 7, 8>>,
    {A1, S1} = advertise(0, 86400, new()),
    {_, S2} = answer(A1, Id, 0, S1),
    Valid = fun(St) -> [V || #{valid := V} <- erx_nd6_rtr:addresses(St)] end,
    %% Remaining 86,400 s, advertised 60 s: down to two hours.
    {_, S3} = advertise(0, 60, S2),
    ?assertEqual([7200000], Valid(S3)),
    %% Remaining within two hours, advertised less: unchanged.
    {_, S4} = advertise(1000000, 60, S3),
    ?assertEqual([7200000], Valid(S4)),
    %% Advertised more than remains: taken.
    {_, S5} = advertise(7000000, 3000, S4),
    ?assertEqual([10000000], Valid(S5)),
    %% Infinity.
    {_, S6} = advertise(7000000, 16#ffffffff, S5),
    ?assertEqual([infinity], Valid(S6)).

stable_identifier_message_test() ->
    {A1, S1} = advertise(0, 3600, new()),
    [{ifid_request, {?PREFIX, 0}, Message}] = [R || {ifid_request, _, _} = R <- A1],
    ?assertEqual(<<16#2001:16, 16#db8:16, 0:32, "vtnet0", 0:64, 0>>, Message),
    %% Reserved identifiers ask again with the next offset.
    Reserved = [<<0:64>>, <<2, 0, 16#5e, 16#ff, 16#fe, 1, 2, 3>>,
                <<16#fd, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#ff, 16#80>>],
    lists:foldl(fun(Id, {Offset, St}) ->
                        {[{ifid_request, {?PREFIX, Next}, Msg}], St2} =
                            erx_nd6_rtr:ifid({?PREFIX, Offset}, digest(Id), 0, St),
                        ?assertEqual(Offset + 1, Next),
                        ?assertEqual(Next, binary:last(Msg)),
                        {Next, St2}
                end, {0, S1}, Reserved),
    {[{dad, _}], _} = erx_nd6_rtr:ifid({?PREFIX, 0}, digest(<<16#fd, -1:48, 16#7f>>), 0, S1).

dad_failures_form_new_addresses_test() ->
    {A1, S1} = advertise(0, 3600, new()),
    %% Each duplicate counts a failure and the next advertisement asks
    %% again, with the count in the message, until three retries are spent.
    {Last, S5} =
        lists:foldl(fun(N, {Actions, St}) ->
                            [{ifid_request, Ref, Msg}] = [R || {ifid_request, _, _} = R <- Actions],
                            ?assertEqual(N, binary:decode_unsigned(binary:part(Msg, 14, 8), little)),
                            {[{dad, #{addr := Addr}}], St2} =
                                erx_nd6_rtr:ifid(Ref, digest(<<(N + 1), 0:56>>), 0, St),
                            St3 = erx_nd6_rtr:dad_done(Addr, duplicated, St2),
                            advertise(0, 3600, St3)
                    end, {A1, S1}, lists:seq(0, 3)),
    ?assertEqual([], requests(Last)),
    ?assertEqual(4, length(erx_nd6_rtr:addresses(S5))).

random_identifier_when_vault_unavailable_test() ->
    {A1, S1} = advertise(0, 3600, new()),
    [Ref] = requests(A1),
    {[{random_ifid, ?PREFIX}, {dad, #{addr := <<16#2001:16, 16#db8:16, 0:32, _:64>>}}], _} =
        erx_nd6_rtr:ifid_unavailable(Ref, 0, S1).

%% A successful detection resets the failure count, so the identifier of a
%% later prefix does not depend on an earlier collision.
dad_success_resets_failures_test() ->
    {A1, S1} = advertise(0, 3600, new()),
    {[{dad, #{addr := Dup}}], S2} = answer(A1, <<1, 0:56>>, 0, S1),
    {A3, S3} = advertise(0, 3600, erx_nd6_rtr:dad_done(Dup, duplicated, S2)),
    {[{dad, #{addr := Good}}], S4} = answer(A3, <<2, 0:56>>, 0, S3),
    Other = <<16#2001:16, 16#db8:16, 1:16, 0:80>>,
    {A5, _} = erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{prefixes => [pi(Other, 3600, 3600)]}), 0,
                             erx_nd6_rtr:dad_done(Good, ok, S4)),
    [{ifid_request, _, Msg}] = [R || {ifid_request, _, _} = R <- A5],
    ?assertEqual(<<Other:8/binary, "vtnet0", 0:64, 0>>, Msg).

%% An option for a /48 leaves the address formed from the /64 inside it.
other_length_prefix_leaves_address_test() ->
    {A1, S1} = advertise(0, 86400, new()),
    {_, S2} = answer(A1, <<1, 0:56>>, 0, S1),
    Wide = (pi(?PREFIX, 60, 0))#{len := 48},
    {_, S3} = erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{prefixes => [Wide]}), 0, S2),
    ?assertMatch([#{valid := 86400000, preferred := 86400000}], erx_nd6_rtr:addresses(S3)).

router_selection_test() ->
    High = 16#08,
    Low = 16#18,
    Ra = fun(N, Flags, St) ->
                 {_, St2} = erx_nd6_rtr:ra(pkt(router(N)), {ra, 64, Flags, 1800, 0, 0, #{}}, 0, St),
                 St2
         end,
    S = Ra(3, High, Ra(2, Low, Ra(1, 0, new()))),
    ?assertEqual([router(3), router(1), router(2)],
                 [A || #{addr := A} <- erx_nd6_rtr:routers(S)]),
    Gateway = fun(St) -> [G || #{plen := 0, gateway := G} <- erx_nd6_rtr:routes(St)] end,
    S1 = erx_nd6_rtr:select_router(fun(A) -> A =/= router(3) end, S),
    ?assertEqual([router(1)], Gateway(S1)),
    %% The installed router stays while reachable and no better one is.
    S2 = erx_nd6_rtr:select_router(fun(A) -> A =/= router(3) end, S1),
    ?assertEqual([router(1)], Gateway(S2)),
    %% A reachable router of higher preference takes over.
    S3 = erx_nd6_rtr:select_router(fun(_) -> true end, S2),
    ?assertEqual([router(3)], Gateway(S3)),
    %% With none reachable, round robin from the installed one.
    S4 = erx_nd6_rtr:select_router(fun(_) -> false end, S3),
    ?assertEqual([router(1)], Gateway(S4)),
    %% A router whose lifetime is zero leaves at once.
    {_, S5} = erx_nd6_rtr:ra(pkt(router(1)), ra(0, #{}), 0, S4),
    ?assertEqual([], Gateway(S5)).

link_parameters_test() ->
    S = new(),
    #{reachable := R0} = erx_nd6_rtr:params(S),
    ?assert(R0 >= 15000 andalso R0 =< 45000),
    {_, S1} = erx_nd6_rtr:ra(pkt(router(1)),
                             {ra, 70, 0, 0, 40000, 2000, #{mtu => 1400}}, 0, S),
    #{base_reachable := 40000, reachable := R1, retrans := 2000, cur_hlim := 70,
      link_mtu := 1400} = erx_nd6_rtr:params(S1),
    ?assert(R1 >= 20000 andalso R1 =< 60000),
    %% A lower hop limit, an MTU past the interface's and a reachable time
    %% past MAX_REACHABLE_TIME are ignored.
    {_, S2} = erx_nd6_rtr:ra(pkt(router(1)),
                             {ra, 30, 0, 0, 3600001, 0, #{mtu => 9000}}, 0, S1),
    ?assertMatch(#{base_reachable := 40000, cur_hlim := 70, link_mtu := 1400, retrans := 2000},
                 erx_nd6_rtr:params(S2)).

router_solicitations_test() ->
    {[{ifid_request, {<<16#fe80:16, 0:112>>, 0}, _}], S} = erx_nd6_rtr:start(0, new()),
    T1 = erx_nd6_rtr:next_deadline(S),
    ?assert(T1 >= 0 andalso T1 =< 1000),
    {[send_rs], S1} = erx_nd6_rtr:tick(T1, S),
    ?assertEqual(T1 + 4000, erx_nd6_rtr:next_deadline(S1)),
    {[send_rs], S2} = erx_nd6_rtr:tick(T1 + 4000, S1),
    {[send_rs], S3} = erx_nd6_rtr:tick(T1 + 8000, S2),
    ?assertEqual(none, erx_nd6_rtr:next_deadline(S3)),
    %% An advertisement with a router lifetime stops them.
    {_, S4} = erx_nd6_rtr:ra(pkt(router(1)), ra(1800, #{}), T1 + 1, S1),
    {[], _} = erx_nd6_rtr:tick(T1 + 4000, S4).
