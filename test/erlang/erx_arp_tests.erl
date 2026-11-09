%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_arp against FreeBSD's if_ether.c: resolution with its held frames and request pacing,
%% the entry's life from reachable through verify, in_arpinput's rules for which packets
%% create, update or are answered, and the table's bound under random traffic.
-module(erx_arp_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erx_arp_wire.hrl").

-define(ME, <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>).
-define(PEER, <<16#52, 16#54, 0, 16#AA, 16#BB, 16#CC>>).
-define(PEER2, <<16#52, 16#54, 0, 16#AA, 16#BB, 16#DD>>).
-define(BCAST, <<16#FF, 16#FF, 16#FF, 16#FF, 16#FF, 16#FF>>).
-define(IFACE, #{lladdr => ?ME, addrs => [{<<10, 0, 2, 15>>, 24}, {<<192, 168, 1, 1>>, 24}]}).
-define(GW, <<10, 0, 2, 2>>).

request(Spa, Tpa) ->
    #arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST, sha = ?PEER, spa = Spa, tha = <<0:48>>, tpa = Tpa}.

reply(Sha, Spa, Tpa) ->
    #arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REPLY, sha = Sha, spa = Spa, tha = ?ME, tpa = Tpa}.

our_request(Spa, Tpa) ->
    {send_arp, ?BCAST, #arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST, sha = ?ME, spa = Spa,
                            tha = <<0:48>>, tpa = Tpa}}.

%% arpresolve_full: a request on the first frame, none within the second, another after it,
%% the oldest frame dropped past 16, and every held frame sent in order on the reply.
resolve_holds_and_paces_requests_test() ->
    T0 = erx_arp:new(),
    {T1, A1} = erx_arp:resolve(?GW, f0, 0, ?IFACE, T0),
    ?assertEqual([our_request(<<10, 0, 2, 15>>, ?GW)], A1),
    {T2, []} = erx_arp:resolve(?GW, f1, 999, ?IFACE, T1),
    {T3, A3} = erx_arp:resolve(?GW, f2, 1000, ?IFACE, T2),
    ?assertEqual([our_request(<<10, 0, 2, 15>>, ?GW)], A3),
    T4 = lists:foldl(fun(N, T) -> element(1, erx_arp:resolve(?GW, {f, N}, 1500, ?IFACE, T)) end,
                     T3, lists:seq(3, 16)),
    {T5, A5} = erx_arp:input(reply(?PEER, ?GW, <<10, 0, 2, 15>>), 1600, ?IFACE, T4),
    ?assertEqual([{publish, ?GW, ?PEER, fresh},
                  {send, ?PEER, [f1, f2 | [{f, N} || N <- lists:seq(3, 16)]]}], A5),
    ?assertEqual({T5, [{send, ?PEER, [f17]}]}, erx_arp:resolve(?GW, f17, 1700, ?IFACE, T5)).

%% A request goes from the address on the neighbour's prefix, else from the last address.
request_source_test() ->
    {_, A} = erx_arp:resolve(<<192, 168, 1, 9>>, f, 0, ?IFACE, erx_arp:new()),
    ?assertEqual([our_request(<<192, 168, 1, 1>>, <<192, 168, 1, 9>>)], A),
    {_, B} = erx_arp:resolve(<<172, 16, 0, 1>>, f, 0, ?IFACE, erx_arp:new()),
    ?assertEqual([our_request(<<192, 168, 1, 1>>, <<172, 16, 0, 1>>)], B),
    ?assertEqual([], element(2, erx_arp:resolve(?GW, f, 0, #{lladdr => ?ME, addrs => []}, erx_arp:new()))).

%% arpt_down: an unanswered entry goes, with its frames, 20 seconds after its last request.
incomplete_entry_times_out_test() ->
    {T1, _} = erx_arp:resolve(?GW, f, 0, ?IFACE, erx_arp:new()),
    {T2, _} = erx_arp:resolve(?GW, g, 5000, ?IFACE, T1),
    ?assertEqual(25000, erx_arp:next_deadline(T2)),
    {T3, []} = erx_arp:expired(24999, ?IFACE, T2),
    ?assertEqual(1, erx_arp:count(T3)),
    {T4, []} = erx_arp:expired(25000, ?IFACE, T3),
    ?assertEqual(0, erx_arp:count(T4)),
    ?assertEqual(infinity, erx_arp:next_deadline(T4)).

%% arptimer: reachable for arpt_keep less five seconds, then verify and published stale;
%% unused it lapses at arpt_keep; hinted it refreshes once a second, five times at most.
entry_lifecycle_test() ->
    {T1, _} = erx_arp:input(request(?GW, <<10, 0, 2, 15>>), 0, ?IFACE, erx_arp:new()),
    ?assertEqual(1195000, erx_arp:next_deadline(T1)),
    {T2, A2} = erx_arp:expired(1195000, ?IFACE, T1),
    ?assertEqual([{publish, ?GW, ?PEER, stale}], A2),
    {T3, []} = erx_arp:expired(1196000, ?IFACE, T2),
    {Lapsed, A4} = erx_arp:expired(1200000, ?IFACE, lists:foldl(
                       fun(S, T) -> element(1, erx_arp:expired(S * 1000, ?IFACE, T)) end,
                       T3, lists:seq(1197, 1199))),
    ?assertEqual([{unpublish, ?GW}], A4),
    ?assertEqual(0, erx_arp:count(Lapsed)),
    Hinted = erx_arp:hint(?GW, T2),
    Refreshes = [element(2, erx_arp:expired(S * 1000, ?IFACE, T))
                 || {S, T} <- lists:zip(lists:seq(1196, 1200), states(Hinted, 1196, 1200))],
    ?assertEqual(lists:duplicate(5, [our_request(<<10, 0, 2, 15>>, ?GW)]), Refreshes),
    {Renewed, A5} = erx_arp:input(reply(?PEER, ?GW, <<10, 0, 2, 15>>), 1197500, ?IFACE, Hinted),
    ?assertEqual([{publish, ?GW, ?PEER, fresh}], A5),
    ?assertEqual(1197500 + 1195000, erx_arp:next_deadline(Renewed)).

%% The table before each second's look from First to Last.
states(T, First, Last) ->
    lists:reverse(element(2, lists:foldl(
        fun(S, {Tn, Acc}) -> {element(1, erx_arp:expired(S * 1000, ?IFACE, Tn)), [Tn | Acc]} end,
        {T, []}, lists:seq(First, Last)))).

%% in_arpinput: only a packet to our address creates an entry, and only from a sender on
%% our prefix; any packet updates an existing entry; only requests to us are answered, by
%% unicast.
input_rules_test() ->
    T0 = erx_arp:new(),
    %% An unsolicited reply, and a request for another host: nothing learnt or answered.
    ?assertEqual({T0, []}, erx_arp:input(reply(?PEER, ?GW, <<10, 0, 2, 99>>), 0, ?IFACE, T0)),
    ?assertEqual({T0, []}, erx_arp:input(request(?GW, <<10, 0, 2, 99>>), 0, ?IFACE, T0)),
    %% A request for us from off our prefixes is answered but makes no entry.
    {T0, [{send_arp, ?PEER, Answer}]} = erx_arp:input(request(<<172, 16, 0, 1>>, <<10, 0, 2, 15>>), 0, ?IFACE, T0),
    ?assertEqual(#arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REPLY, sha = ?ME, spa = <<10, 0, 2, 15>>,
                      tha = ?PEER, tpa = <<172, 16, 0, 1>>}, Answer),
    %% A request for us from our prefix makes an entry, and is answered.
    {T1, [{publish, ?GW, ?PEER, fresh}, {send_arp, ?PEER, _}]} =
        erx_arp:input(request(?GW, <<10, 0, 2, 15>>), 0, ?IFACE, T0),
    %% A gratuitous ARP of the neighbour moving updates its entry though it is not for us.
    {_, [{publish, ?GW, ?PEER2, fresh}]} =
        erx_arp:input(#arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST, sha = ?PEER2, spa = ?GW,
                           tha = <<0:48>>, tpa = ?GW}, 10, ?IFACE, T1),
    %% Our own packet, and a multicast or broadcast sender, are dropped.
    Own = (request(?GW, <<10, 0, 2, 15>>))#arp{sha = ?ME},
    ?assertEqual({T0, []}, erx_arp:input(Own, 0, ?IFACE, T0)),
    ?assertEqual({T1, []}, erx_arp:input(reply(?BCAST, ?GW, <<10, 0, 2, 15>>), 0, ?IFACE, T1)),
    ?assertEqual({T1, []}, erx_arp:input(reply(<<1, 0, 16#5E, 0, 0, 1>>, ?GW, <<10, 0, 2, 15>>), 0, ?IFACE, T1)),
    %% An interface without an address ignores everything.
    ?assertEqual({T0, []}, erx_arp:input(request(?GW, <<10, 0, 2, 15>>), 0,
                                         #{lladdr => ?ME, addrs => []}, T0)).

%% Another host claiming our address: reported, the table untouched, a request answered so
%% that the address is reclaimed; a link-local address is answered by broadcast.
conflict_and_link_local_test() ->
    T0 = erx_arp:new(),
    Claim = request(<<10, 0, 2, 15>>, <<10, 0, 2, 15>>),
    {T0, [{conflict, <<10, 0, 2, 15>>, ?PEER}, {send_arp, ?PEER, Reclaim}]} =
        erx_arp:input(Claim, 0, ?IFACE, T0),
    ?assertEqual(#arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REPLY, sha = ?ME, spa = <<10, 0, 2, 15>>,
                      tha = ?PEER, tpa = <<10, 0, 2, 15>>}, Reclaim),
    ?assertEqual({T0, [{conflict, <<10, 0, 2, 15>>, ?PEER}]},
                 erx_arp:input(Claim#arp{op = ?ARPOP_REPLY}, 0, ?IFACE, T0)),
    LinkLocal = #{lladdr => ?ME, addrs => [{<<169, 254, 7, 7>>, 16}]},
    {_, [_, {send_arp, ?BCAST, #arp{op = ?ARPOP_REPLY}}]} =
        erx_arp:input(request(<<169, 254, 1, 1>>, <<169, 254, 7, 7>>), 0, LinkLocal, T0),
    ?assertEqual([{send_arp, ?BCAST, #arp{hrd = ?ARPHRD_ETHER, op = ?ARPOP_REQUEST, sha = ?ME,
                                          spa = ?GW, tha = <<0:48>>, tpa = ?GW}}],
                 erx_arp:announce(?GW, ?IFACE)).

%% The bound: the oldest incomplete entry makes room, else the oldest resolved entry no
%% transmitter hinted, which is withdrawn; with every entry hinted, the frame is dropped.
bound_test() ->
    T0 = erx_arp:new(#{max_entries => 2}),
    {T1, _} = erx_arp:resolve(<<10, 0, 2, 3>>, a, 0, ?IFACE, T0),
    {T2, _} = erx_arp:input(request(?GW, <<10, 0, 2, 15>>), 1, ?IFACE, T1),
    {T3, [_]} = erx_arp:resolve(<<10, 0, 2, 4>>, b, 2, ?IFACE, T2),
    ?assertEqual(2, erx_arp:count(T3)),
    %% 10.0.2.3 was evicted: a reply from it that is not for us finds no entry to update.
    ?assertEqual({T3, []}, erx_arp:input(reply(?PEER2, <<10, 0, 2, 3>>, <<10, 0, 2, 99>>), 3, ?IFACE, T3)),
    {T4, _} = erx_arp:input(reply(?PEER2, <<10, 0, 2, 4>>, <<10, 0, 2, 15>>), 4, ?IFACE, T3),
    {_, [{unpublish, ?GW}, _Request]} = erx_arp:resolve(<<10, 0, 2, 5>>, c, 5, ?IFACE, T4),
    {T5, _} = erx_arp:expired(1195004, ?IFACE, T4),
    Hinted = erx_arp:hint(<<10, 0, 2, 4>>, erx_arp:hint(?GW, T5)),
    ?assertEqual({Hinted, []}, erx_arp:resolve(<<10, 0, 2, 5>>, c, 1195005, ?IFACE, Hinted)).

%% A packet from another of our own addresses makes or changes no entry (FreeBSD's static
%% entry for each interface address).
own_address_sender_test() ->
    T0 = erx_arp:new(),
    {T1, Actions} = erx_arp:input(request(<<192, 168, 1, 1>>, <<10, 0, 2, 15>>), 0, ?IFACE, T0),
    ?assertEqual(0, erx_arp:count(T1)),
    ?assertMatch([{send_arp, ?PEER, #arp{op = ?ARPOP_REPLY}}], Actions).

%% Random traffic never takes the table past its bound or an entry past 16 frames, and every
%% entry's deadline is the one next_deadline/1 and expired/3 see.
bounded_under_random_traffic_test() ->
    rand:seed(exsss, {7, 11, 13}),
    Max = 8,
    Final = lists:foldl(fun(Step, T) -> random_event(Step, T, Max) end,
                        erx_arp:new(#{max_entries => Max}), lists:seq(1, 4000)),
    ?assertEqual(0, erx_arp:count(drain(Final, 100))).

%% The table after its deadlines have run, one look at each, until none is left.
drain(T, 0) ->
    T;
drain(T, Looks) ->
    case erx_arp:next_deadline(T) of
        infinity -> T;
        Deadline -> drain(element(1, erx_arp:expired(Deadline, ?IFACE, T)), Looks - 1)
    end.

random_event(Step, T0, Max) ->
    Now = Step * 700,
    Ip = <<10, 0, 2, (rand:uniform(20))>>,
    {T, Actions} =
        case rand:uniform(5) of
            1 -> erx_arp:resolve(Ip, Step, Now, ?IFACE, T0);
            2 -> erx_arp:input(request(Ip, <<10, 0, 2, 15>>), Now, ?IFACE, T0);
            3 -> erx_arp:input(reply(?PEER, Ip, <<10, 0, 2, 77>>), Now, ?IFACE, T0);
            4 -> {erx_arp:hint(Ip, T0), []};
            5 -> erx_arp:expired(Now, ?IFACE, T0)
        end,
    ?assert(erx_arp:count(T) =< Max),
    [?assert(length(Frames) =< 16) || {send, _, Frames} <- Actions],
    T.
