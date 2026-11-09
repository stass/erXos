%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_nd6 against FreeBSD's nd6.c and nd6_nbr.c: resolution and its multicast
%% solicitations, unreachability detection from stale through delay or a hint to probe,
%% nd6_ns_input's and nd6_na_input's rules (hop limit 255, the override rules of RFC 4861
%% 7.2.5), the reachable time's interval, and the cache's bound under random traffic.
-module(erx_nd6_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_ip6.hrl").

-define(ME, <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>).
-define(PEER, <<16#52, 16#54, 0, 16#AA, 16#BB, 16#CC>>).
-define(PEER2, <<16#52, 16#54, 0, 16#AA, 16#BB, 16#DD>>).
-define(LL, <<16#FE80:16, 0:48, 16#5054:16, 16#00FF:16, 16#FE12:16, 16#3456:16>>).
-define(GLOBAL, <<16#2001:16, 16#0DB8:16, 0:32, 0:48, 16#15:16>>).
-define(TENTATIVE, <<16#2001:16, 16#0DB8:16, 0:32, 0:48, 16#16:16>>).
-define(NB, <<16#FE80:16, 0:48, 16#5054:16, 16#00FF:16, 16#FEAA:16, 16#BBCC:16>>).
-define(SNM_NB, <<16#FF02:16, 0:64, 1:16, 16#FF, 16#AA, 16#BB, 16#CC>>).
-define(SNM_ME, <<16#FF02:16, 0:64, 1:16, 16#FF, 16#12, 16#34, 16#56>>).
-define(IFACE, #{lladdr => ?ME, onlink => [{<<16#2001:16, 16#0DB8:16, 0:96>>, 64}],
                 addrs => [{?LL, preferred}, {?GLOBAL, preferred}, {?TENTATIVE, tentative}]}).
-define(R, 4).
-define(S, 2).
-define(O, 1).

new() ->
    erx_nd6:new(erx_net_rand:new(<<7:128>>), 0, #{}).

ns(Src, Dst, Target, Opts) ->
    {#ip6{tclass = 0, flow = 0, hlim = 255, src = Src, dst = Dst, proto = ?IPPROTO_ICMPV6},
     #icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, Target, Opts}}}.

na(Src, Dst, Flags, Target, Opts) ->
    {#ip6{tclass = 0, flow = 0, hlim = 255, src = Src, dst = Dst, proto = ?IPPROTO_ICMPV6},
     #icmp6{type = ?ND_NEIGHBOR_ADVERT, code = 0, msg = {na, Flags, Target, Opts}}}.

input({Ip6, Icmp6}, Now, C) ->
    erx_nd6:input(Ip6, Icmp6, Now, ?IFACE, C).

our_ns(Src, Dst, Target) ->
    {send_nd, Src, Dst, #icmp6{type = ?ND_NEIGHBOR_SOLICIT, code = 0, msg = {ns, Target, #{slla => ?ME}}}}.

%% nd6_resolve_slow and nd6_llinfo_timer: a multicast solicitation from the held frame's
%% source, two more a second apart, then the entry goes and its oldest frame is returned.
resolution_fails_after_three_solicitations_test() ->
    {C1, A1} = erx_nd6:resolve(?NB, ?LL, f0, 0, ?IFACE, new()),
    ?assertEqual([our_ns(?LL, ?SNM_NB, ?NB)], A1),
    {C2, []} = erx_nd6:resolve(?NB, ?LL, f1, 500, ?IFACE, C1),
    {C3, A3} = erx_nd6:expired(1000, ?IFACE, C2),
    ?assertEqual([our_ns(?LL, ?SNM_NB, ?NB)], A3),
    {C4, [_]} = erx_nd6:expired(2000, ?IFACE, C3),
    {C5, A5} = erx_nd6:expired(3000, ?IFACE, C4),
    ?assertEqual([{unreachable, f0}], A5),
    ?assertEqual(0, erx_nd6:count(C5)),
    %% A held frame from a source that is not ours leaves the choice to the interface.
    {_, [{send_nd, select, ?SNM_NB, _}]} = erx_nd6:resolve(?NB, <<1:128>>, f, 0, ?IFACE, new()).

%% nd6_na_input on an incomplete entry: solicited makes it reachable and sends the held
%% frames; an advertisement without the target's address changes nothing.
solicited_advert_resolves_test() ->
    {C1, _} = erx_nd6:resolve(?NB, ?LL, f0, 0, ?IFACE, new()),
    {C2, _} = erx_nd6:resolve(?NB, ?LL, f1, 10, ?IFACE, C1),
    ?assertEqual({C2, []}, input(na(?NB, ?LL, ?S, ?NB, #{}), 20, C2)),
    {C3, A3} = input(na(?NB, ?LL, ?S bor ?O, ?NB, #{tlla => ?PEER}), 20, C2),
    ?assertEqual([{publish, ?NB, ?PEER, fresh}, {send, ?PEER, [f0, f1]}], A3),
    ?assertEqual(20 + erx_nd6:reachable_time(C3), erx_nd6:next_deadline(C3)),
    ?assertEqual({C3, [{send, ?PEER, [f2]}]}, erx_nd6:resolve(?NB, ?LL, f2, 30, ?IFACE, C3)).

%% Unreachability detection: reachable, then stale; a hint probes five seconds later by
%% unicast, three times, then the entry goes; a frame through the interface turns a stale
%% entry delay instead; an unused stale entry goes after a day.
unreachability_detection_test() ->
    {C1, _} = erx_nd6:resolve(?NB, ?LL, f0, 0, ?IFACE, new()),
    {C2, _} = input(na(?NB, ?LL, ?S, ?NB, #{tlla => ?PEER}), 0, C1),
    Reachable = erx_nd6:reachable_time(C2),
    {C3, A3} = erx_nd6:expired(Reachable, ?IFACE, C2),
    ?assertEqual([{publish, ?NB, ?PEER, stale}], A3),
    {Gone, [{unpublish, ?NB}]} = erx_nd6:expired(Reachable + 86400000, ?IFACE, C3),
    ?assertEqual(0, erx_nd6:count(Gone)),
    Hinted = erx_nd6:hint(?NB, Reachable + 100, C3),
    ?assertEqual(Hinted, erx_nd6:hint(?NB, Reachable + 200, Hinted)),
    {P1, A4} = erx_nd6:expired(Reachable + 5100, ?IFACE, Hinted),
    ?assertEqual([{publish, ?NB, ?PEER, fresh}, our_ns(select, ?NB, ?NB)], A4),
    {P2, [_]} = erx_nd6:expired(Reachable + 6100, ?IFACE, P1),
    {P3, [_]} = erx_nd6:expired(Reachable + 7100, ?IFACE, P2),
    {P4, [{unpublish, ?NB}]} = erx_nd6:expired(Reachable + 8100, ?IFACE, P3),
    ?assertEqual(0, erx_nd6:count(P4)),
    %% A frame through the interface: delay, then the same probe.
    {D1, [{publish, ?NB, ?PEER, fresh}, {send, ?PEER, [g]}]} =
        erx_nd6:resolve(?NB, ?LL, g, Reachable + 10, ?IFACE, C3),
    ?assertMatch({_, [{send_nd, select, ?NB, _}]}, erx_nd6:expired(Reachable + 5010, ?IFACE, D1)),
    %% A solicited advertisement while probing makes it reachable again.
    {R1, []} = input(na(?NB, ?LL, ?S, ?NB, #{}), Reachable + 5200, P1),
    ?assertEqual(Reachable + 5200 + Reachable, erx_nd6:next_deadline(R1)).

%% nd6_ns_input: a hop limit below 255, a source off-link, a target not ours or multicast,
%% and a DAD probe to anything but a solicited-node group are dropped; a solicitation from
%% a neighbour is answered solicited and with override, and teaches its source as stale; a
%% DAD probe for our address is answered to all nodes, unsolicited; one for a tentative
%% address goes to duplicate address detection.
ns_input_test() ->
    C0 = new(),
    {Ip6, Icmp6} = ns(?NB, ?SNM_ME, ?LL, #{slla => ?PEER}),
    ?assertEqual({C0, []}, erx_nd6:input(Ip6#ip6{hlim = 254}, Icmp6, 0, ?IFACE, C0)),
    ?assertEqual({C0, []}, input(ns(<<16#2001:16, 16#0DB9:16, 0:96>>, ?SNM_ME, ?LL, #{}), 0, C0)),
    ?assertEqual({C0, []}, input(ns(?NB, ?SNM_ME, ?NB, #{}), 0, C0)),
    ?assertEqual({C0, []}, input(ns(?NB, ?SNM_ME, ?SNM_ME, #{}), 0, C0)),
    ?assertEqual({C0, []}, input(ns(<<0:128>>, ?LL, ?LL, #{}), 0, C0)),
    ?assertEqual({C0, []}, input(ns(<<0:128>>, ?SNM_ME, ?LL, #{slla => ?PEER}), 0, C0)),
    ?assertEqual({C0, []}, input(ns(?NB, ?SNM_ME, ?LL, #{slla => <<1, 2, 3, 4, 5, 6, 7, 8>>}), 0, C0)),
    {C1, A1} = erx_nd6:input(Ip6, Icmp6, 0, ?IFACE, C0),
    ?assertEqual([{publish, ?NB, ?PEER, stale},
                  {send_nd, select, ?NB, #icmp6{type = ?ND_NEIGHBOR_ADVERT, code = 0,
                                                msg = {na, ?S bor ?O, ?LL, #{tlla => ?ME}}}}], A1),
    ?assertEqual(1, erx_nd6:count(C1)),
    %% Unicast: no override and no target address option; no entry without a source address.
    ?assertEqual({C0, [{send_nd, select, ?NB, #icmp6{type = ?ND_NEIGHBOR_ADVERT, code = 0,
                                                     msg = {na, ?S, ?LL, #{}}}}]},
                 input(ns(?NB, ?LL, ?LL, #{}), 0, C0)),
    ?assertEqual({C0, [{send_nd, select, <<16#FF02:16, 0:96, 1:16>>,
                        #icmp6{type = ?ND_NEIGHBOR_ADVERT, code = 0, msg = {na, ?O, ?LL, #{tlla => ?ME}}}}]},
                 input(ns(<<0:128>>, ?SNM_ME, ?LL, #{}), 0, C0)),
    ?assertEqual({C0, [{dad, {ns, ?TENTATIVE, <<1, 2, 3, 4, 5, 6>>}}]},
                 input(ns(<<0:128>>, <<16#FF02:16, 0:64, 1:16, 16#FF, 0, 0, 16#16>>, ?TENTATIVE,
                          #{nonce => <<1, 2, 3, 4, 5, 6>>}), 0, C0)),
    ?assertEqual({C0, []}, input(ns(?NB, ?SNM_ME, ?TENTATIVE, #{}), 0, C0)).

%% nd6_na_input's override rules (RFC 4861 7.2.5) on a resolved entry, and its refusals: an
%% unsolicited advertisement makes no entry, a solicited one to a multicast group is
%% dropped, one for our address is a conflict and one for a tentative address goes to DAD.
na_override_rules_test() ->
    {C1, _} = erx_nd6:resolve(?NB, ?LL, f0, 0, ?IFACE, new()),
    {Reach, _} = input(na(?NB, ?LL, ?S, ?NB, #{tlla => ?PEER}), 0, C1),
    %% (1) A new address without override: a reachable entry turns stale, keeping its address.
    ?assertMatch({_, [{publish, ?NB, ?PEER, stale}]}, input(na(?NB, ?LL, ?S, ?NB, #{tlla => ?PEER2}), 1, Reach)),
    %% (2a) A new address with override, unsolicited: taken, stale.
    ?assertMatch({_, [{publish, ?NB, ?PEER2, stale}]}, input(na(?NB, ?LL, ?O, ?NB, #{tlla => ?PEER2}), 1, Reach)),
    %% (2b) The same address, unsolicited: nothing changes.
    ?assertMatch({_, []}, input(na(?NB, ?LL, 0, ?NB, #{tlla => ?PEER}), 1, Reach)),
    %% The router flag cleared is reported.
    {Router, _} = input(na(?NB, ?LL, ?R bor ?S, ?NB, #{}), 2, Reach),
    ?assertMatch({_, [{not_router, ?NB}]}, input(na(?NB, ?LL, ?S, ?NB, #{}), 3, Router)),
    C0 = new(),
    ?assertEqual({C0, []}, input(na(?NB, ?LL, ?O, ?NB, #{tlla => ?PEER}), 0, C0)),
    ?assertEqual({C1, []}, input(na(?NB, <<16#FF02:16, 0:96, 1:16>>, ?S, ?NB, #{tlla => ?PEER}), 0, C1)),
    ?assertEqual({C0, [{conflict, ?GLOBAL, ?PEER}]}, input(na(?NB, ?LL, ?O, ?GLOBAL, #{tlla => ?PEER}), 0, C0)),
    ?assertEqual({C0, [{dad, {na, ?TENTATIVE}}]}, input(na(?NB, ?LL, ?O, ?TENTATIVE, #{}), 0, C0)).

%% ND_COMPUTE_RTIME's interval, half to one and a half times 30 seconds, drawn again every
%% two hours; the same key gives the same draws.
reachable_time_test() ->
    Times = [erx_nd6:reachable_time(erx_nd6:new(erx_net_rand:new(<<K:128>>), 0, #{})) || K <- lists:seq(1, 200)],
    ?assert(lists:all(fun(T) -> T >= 15000 andalso T < 45000 end, Times)),
    ?assert(length(lists:usort(Times)) > 150),
    C = new(),
    ?assertEqual(7200000, erx_nd6:next_deadline(C)),
    {C1, []} = erx_nd6:expired(7200000, ?IFACE, C),
    ?assertEqual(14400000, erx_nd6:next_deadline(C1)),
    ?assertEqual(erx_nd6:reachable_time(C), erx_nd6:reachable_time(new())).

%% Random traffic never takes the cache past its bound or an entry past 16 frames.
bounded_under_random_traffic_test() ->
    rand:seed(exsss, {3, 5, 7}),
    Max = 8,
    Final = lists:foldl(fun(Step, C) -> random_event(Step, C, Max) end,
                        erx_nd6:new(erx_net_rand:new(<<1:128>>), 0, #{max_entries => Max}),
                        lists:seq(1, 4000)),
    ?assertEqual(0, erx_nd6:count(drain(Final, 200))).

%% The cache after its deadlines have run, one look at each, until no entry is left.
drain(C, 0) ->
    C;
drain(C, Looks) ->
    case erx_nd6:count(C) of
        0 -> C;
        _ -> drain(element(1, erx_nd6:expired(erx_nd6:next_deadline(C), ?IFACE, C)), Looks - 1)
    end.

random_event(Step, C0, Max) ->
    Now = Step * 700,
    Ip = <<16#FE80:16, 0:104, (rand:uniform(20))>>,
    {C, Actions} =
        case rand:uniform(5) of
            1 -> erx_nd6:resolve(Ip, ?LL, Step, Now, ?IFACE, C0);
            2 -> input(ns(Ip, ?SNM_ME, ?LL, #{slla => ?PEER}), Now, C0);
            3 -> input(na(Ip, ?LL, rand:uniform(8) - 1, Ip, #{tlla => ?PEER2}), Now, C0);
            4 -> {erx_nd6:hint(Ip, Now, C0), []};
            5 -> erx_nd6:expired(Now, ?IFACE, C0)
        end,
    ?assert(erx_nd6:count(C) =< Max),
    [?assert(length(Frames) =< 16) || {send, _, Frames} <- Actions],
    C.

%% Findings of review: a full cache of unhinted stale entries makes room by withdrawing the
%% oldest; our own address never becomes an entry; case (1) of 7.2.5 changes only the state;
%% a conflict never carries an address of the wrong size; a message in a fragment is dropped.
review_regressions_test() ->
    C0 = erx_nd6:new(erx_net_rand:new(<<1:128>>), 0, #{max_entries => 2}),
    Nb = fun(N) -> <<16#FE80:16, 0:104, N>> end,
    {C1, _} = input(ns(Nb(1), ?SNM_ME, ?LL, #{slla => ?PEER}), 0, C0),
    {C2, _} = input(ns(Nb(2), ?SNM_ME, ?LL, #{slla => ?PEER}), 1, C1),
    {C3, [{unpublish, _}, {send_nd, ?LL, _, _}]} = erx_nd6:resolve(Nb(3), ?LL, f, 2, ?IFACE, C2),
    ?assertEqual(2, erx_nd6:count(C3)),
    ?assertMatch({_, [{send_nd, select, ?GLOBAL, _}]}, input(ns(?GLOBAL, ?SNM_ME, ?LL, #{slla => ?PEER}), 0, new())),
    {P1, _} = erx_nd6:resolve(?NB, ?LL, f0, 0, ?IFACE, new()),
    {Router, _} = input(na(?NB, ?LL, ?R bor ?S, ?NB, #{tlla => ?PEER}), 0, P1),
    ?assertMatch({_, [{publish, ?NB, ?PEER, stale}]}, input(na(?NB, ?LL, 0, ?NB, #{tlla => ?PEER2}), 1, Router)),
    ?assertEqual({new(), []}, input(na(?NB, ?LL, ?O, ?GLOBAL, #{tlla => <<0:112>>}), 0, new())),
    {Ip6, Icmp6} = ns(?NB, ?SNM_ME, ?LL, #{slla => ?PEER}),
    ?assertEqual({new(), []}, erx_nd6:input(Ip6#ip6{fragment = {0, false, 1}}, Icmp6, 0, ?IFACE, new())),
    ?assertEqual({new(), []}, erx_nd6:input(Ip6#ip6{exthdrs = [{fragment, 0, false, 1}]}, Icmp6, 0, ?IFACE, new())).
