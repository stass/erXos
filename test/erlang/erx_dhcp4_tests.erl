%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_dhcp4_tests).
-moduledoc """
EUnit cases of the DHCP client: erx_dhcp4_wire's refusals and its long options, and
erx_dhcp4_core through a lease's whole life (discover, request, bound, renewing,
rebinding, expiry), its NAKs, the replies it must ignore, its backoff and its random
values from a fixed key.
""".

-include_lib("eunit/include/eunit.hrl").
-include("erx_dhcp4_wire.hrl").

-define(MAC, <<2, 0, 0, 0, 0, 1>>).
-define(SERVER, <<10, 0, 2, 2>>).
-define(ADDR, <<10, 0, 2, 15>>).
-define(ANY, <<0:32>>).

%% --- erx_dhcp4_wire ---

reply(Type, Xid, Options) ->
    #dhcp4{op = reply, xid = Xid, yiaddr = ?ADDR, chaddr = ?MAC,
           options = Options#{message_type => Type, server_id => ?SERVER}}.

round_trip_with_long_option_test() ->
    Routers = [<<10, 0, (I div 256), (I rem 256)>> || I <- lists:seq(1, 100)],
    Msg = reply(ack, 7, #{routers => Routers, lease_time => 3600, domain_name => [<<"example.org">>]}),
    Bytes = erx_dhcp4_wire:encode(Msg),
    %% 400 bytes of routers go out as two instances of option 3 (RFC 3396).
    ?assertEqual(2, length(binary:matches(Bytes, <<3, 255, 10, 0, 0, 1>>))
                    + length(binary:matches(Bytes, <<3, 145>>))),
    ?assertEqual({ok, Msg}, erx_dhcp4_wire:decode(Bytes)),
    ?assertEqual(300, byte_size(erx_dhcp4_wire:encode(reply(offer, 1, #{})))).

refusals_test() ->
    Good = erx_dhcp4_wire:encode(reply(ack, 7, #{})),
    <<Fixed:236/binary, _Cookie:4/binary, Options/binary>> = Good,
    Body = fun(Opts) -> <<Fixed/binary, 99, 130, 83, 99, Opts/binary>> end,
    ?assertEqual({error, too_short}, erx_dhcp4_wire:decode(binary:part(Good, 0, 239))),
    ?assertEqual({error, bad_cookie}, erx_dhcp4_wire:decode(<<Fixed/binary, 1, 2, 3, 4, Options/binary>>)),
    ?assertEqual({error, bad_op}, erx_dhcp4_wire:decode(<<3, (binary:part(Good, 1, byte_size(Good) - 1))/binary>>)),
    ?assertEqual({error, no_message_type}, erx_dhcp4_wire:decode(Body(<<255>>))),
    ?assertEqual({error, truncated_option}, erx_dhcp4_wire:decode(Body(<<53, 1, 5, 3, 8, 10, 0>>))),
    ?assertEqual({error, {bad_option, 1}}, erx_dhcp4_wire:decode(Body(<<53, 1, 5, 1, 4, 255, 0, 255, 0>>))),
    %% A bad optional option is dropped, not the message.
    ?assertMatch({ok, #dhcp4{options = #{message_type := ack} = O}} when map_size(O) =:= 1,
                 erx_dhcp4_wire:decode(Body(<<53, 1, 5, 15, 3, $a, 27, $b, 26, 2, 0, 67>>))),
    ?assertEqual({error, {bad_option, 53}}, erx_dhcp4_wire:decode(Body(<<53, 1, 9>>))),
    %% Without an end option the message ends the options; one final NUL leaves the domain.
    {ok, #dhcp4{options = Opts}} = erx_dhcp4_wire:decode(Body(<<53, 1, 5, 15, 4, $l, $a, $n, 0>>)),
    ?assertEqual(#{message_type => ack, domain_name => [<<"lan">>]}, Opts).

%% --- erx_dhcp4_core ---

new() -> new(<<0:128>>).
new(Key) -> erx_dhcp4_core:new(?MAC, 1500, erx_net_rand:new(Key), 0).

ack_options() -> #{lease_time => 3600, routers => [?SERVER, <<224, 0, 0, 1>>], dns => [?SERVER]}.

%% Selecting: the first DISCOVER at the start, answered by an OFFER.
bound_core() ->
    {C1, [{send, broadcast, ?ANY, #dhcp4{xid = X, options = #{message_type := discover}}}]} =
        erx_dhcp4_core:step(timeout, new(), 0),
    {C2, [{send, broadcast, ?ANY, Req}]} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 100),
    ?assertMatch(#dhcp4{xid = X, ciaddr = ?ANY,
                        options = #{message_type := request, requested_ip := ?ADDR,
                                    server_id := ?SERVER}}, Req),
    {C3, [{configure, Lease}]} = erx_dhcp4_core:step({reply, reply(ack, X, ack_options())}, C2, 200),
    ?assertEqual(#{addr => ?ADDR, mask => <<255, 0, 0, 0>>,
                   routes => [#{prefix => ?ANY, plen => 0, gateway => ?SERVER}], mtu => 1500,
                   dns => [?SERVER], search => [], server => ?SERVER}, Lease),
    ?assertEqual(none, erx_dhcp4_core:xid(C3)),
    {C3, X}.

lease_life_test() ->
    {Bound, X} = bound_core(),
    %% T1, T2 and expiry count from the REQUEST's send at 100.
    T1 = 100 + 1800 * 1000, T2 = 100 + 3150 * 1000, End = 100 + 3600 * 1000,
    ?assertEqual(T1, erx_dhcp4_core:next_deadline(Bound)),
    ?assertEqual({Bound, []}, erx_dhcp4_core:step(timeout, Bound, T1 - 1)),
    {Renewing, [{send, ?SERVER, ?ADDR, Renew}]} = erx_dhcp4_core:step(timeout, Bound, T1),
    ?assertMatch(#dhcp4{ciaddr = ?ADDR, options = #{message_type := request}}, Renew),
    ?assertNotEqual(X, Renew#dhcp4.xid),
    ?assertEqual(maps:get(server_id, Renew#dhcp4.options, none), none),
    %% Half the time left to T2.
    ?assertEqual(T1 + (T2 - T1) div 2, erx_dhcp4_core:next_deadline(Renewing)),
    {Rebinding, [{send, broadcast, ?ADDR, _}]} = erx_dhcp4_core:step(timeout, Renewing, T2),
    %% Under two minutes from the end, the wait is the minute's floor or the time left.
    {Late, [{send, broadcast, ?ADDR, _}]} = erx_dhcp4_core:step(timeout, Rebinding, End - 90000),
    ?assertEqual(End - 30000, erx_dhcp4_core:next_deadline(Late)),
    {Init, [unconfigure, {send, broadcast, ?ANY, #dhcp4{options = #{message_type := discover}}}]} =
        erx_dhcp4_core:step(timeout, Late, End),
    ?assertNotEqual(none, erx_dhcp4_core:xid(Init)).

renew_ack_and_nak_test() ->
    {Bound, _} = bound_core(),
    T1 = erx_dhcp4_core:next_deadline(Bound),
    {Renewing, [{send, _, _, #dhcp4{xid = X2}}]} = erx_dhcp4_core:step(timeout, Bound, T1),
    {Again, [{configure, #{addr := ?ADDR}}]} =
        erx_dhcp4_core:step({reply, reply(ack, X2, #{lease_time => 7200})}, Renewing, T1 + 5),
    ?assertEqual(T1 + 3600 * 1000, erx_dhcp4_core:next_deadline(Again)),
    {Init, [unconfigure]} = erx_dhcp4_core:step({reply, reply(nak, X2, #{})}, Renewing, T1 + 5),
    ?assertEqual(none, erx_dhcp4_core:xid(Init)).

ignored_replies_test() ->
    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
    Offer = reply(offer, X, #{}),
    Ignored = [Offer#dhcp4{xid = X + 1}, Offer#dhcp4{chaddr = <<2, 0, 0, 0, 0, 2>>},
               Offer#dhcp4{op = request}, Offer#dhcp4{yiaddr = <<224, 0, 0, 5>>},
               Offer#dhcp4{yiaddr = <<0:32>>}, reply(ack, X, ack_options()),
               Offer#dhcp4{options = maps:remove(server_id, Offer#dhcp4.options)}],
    [?assertEqual({C1, []}, erx_dhcp4_core:step({reply, M}, C1, 10)) || M <- Ignored],
    %% In requesting, an ACK without a lease time and a NAK from another server change nothing.
    {C2, _} = erx_dhcp4_core:step({reply, Offer}, C1, 10),
    Nak = reply(nak, X, #{}),
    [?assertEqual({C2, []}, erx_dhcp4_core:step({reply, M}, C2, 20))
     || M <- [reply(ack, X, #{}), Nak#dhcp4{options = (Nak#dhcp4.options)#{server_id => <<10, 0, 2, 3>>}}]],
    {C3, []} = erx_dhcp4_core:step({reply, Nak}, C2, 20),
    ?assertEqual(none, erx_dhcp4_core:xid(C3)),
    {_, [{send, broadcast, ?ANY, #dhcp4{options = #{message_type := discover}}}]} =
        erx_dhcp4_core:step(timeout, C3, erx_dhcp4_core:next_deadline(C3)).

backoff_test() ->
    Waits = backoff(new(), 0, 7, []),
    Bases = [4000, 8000, 16000, 32000, 64000, 64000, 64000],
    [?assert(abs(Wait - Base) =< 1000) || {Wait, Base} <- lists:zip(Waits, Bases)],
    %% Five REQUESTs without an answer start again with a DISCOVER.
    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
    {C2, _} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 0),
    Types = requests(C2, 4),
    ?assertEqual([request, request, request, request, discover], Types).

backoff(_, _, 0, Acc) -> lists:reverse(Acc);
backoff(Core, Now, N, Acc) ->
    {Next, [_]} = erx_dhcp4_core:step(timeout, Core, Now),
    Deadline = erx_dhcp4_core:next_deadline(Next),
    backoff(Next, Deadline, N - 1, [Deadline - Now | Acc]).

requests(Core, 0) ->
    {_, [{send, _, _, #dhcp4{options = #{message_type := Type}}}]} =
        erx_dhcp4_core:step(timeout, Core, erx_dhcp4_core:next_deadline(Core)),
    [Type];
requests(Core, N) ->
    {Next, [{send, _, _, #dhcp4{options = #{message_type := Type}}}]} =
        erx_dhcp4_core:step(timeout, Core, erx_dhcp4_core:next_deadline(Core)),
    [Type | requests(Next, N - 1)].

random_values_follow_the_key_test() ->
    Script = fun(Key) -> {C, Actions} = erx_dhcp4_core:step(timeout, new(Key), 0),
                         {Actions, erx_dhcp4_core:next_deadline(C)}
             end,
    ?assertEqual(Script(<<1:128>>), Script(<<1:128>>)),
    {[{send, _, _, #dhcp4{xid = X1}}], D1} = Script(<<1:128>>),
    {[{send, _, _, #dhcp4{xid = X2}}], D2} = Script(<<2:128>>),
    ?assertNotEqual(X1, X2),
    ?assertNotEqual(D1, D2).

infinite_lease_test() ->
    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
    {C2, _} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 0),
    {C3, [{configure, _}]} =
        erx_dhcp4_core:step({reply, reply(ack, X, #{lease_time => 16#ffffffff})}, C2, 0),
    ?assertEqual(infinity, erx_dhcp4_core:next_deadline(C3)).

%% --- erx_net_bind ---

ephemeral_search_test() ->
    {Start, _} = erx_net_bind:ephemeral_start(erx_net_rand:new(<<3:128>>)),
    ?assert(Start >= 10001 andalso Start =< 65535),
    Ports = walk(Start, Start, []),
    ?assertEqual(65535 - 10000 + 1, length(Ports)),
    ?assertEqual(lists:seq(10000, 65535), lists:sort(Ports)),
    ?assertEqual(10000, erx_net_bind:next_ephemeral(65535, 20000)),
    ?assertEqual(exhausted, erx_net_bind:next_ephemeral(10000, 10001)).

walk(Port, Start, Acc) ->
    case erx_net_bind:next_ephemeral(Port, Start) of
        exhausted -> [Port | Acc];
        Next -> walk(Next, Start, [Port | Acc])
    end.

%% A hostile lease: T1 of 0 falls back to the defaults, so renewal waits 30 s; the subnet's
%% broadcast address and a server identifier of loopback are refused; off-link, own and
%% broadcast routers are dropped and name servers are capped at three.
hostile_lease_test() ->
    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
    {C2, _} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 0),
    Mask = #{subnet_mask => <<255, 255, 255, 0>>},
    {C3, [{configure, Lease}]} =
        erx_dhcp4_core:step({reply, reply(ack, X, Mask#{lease_time => 60, t1 => 0, t2 => 1,
                                                        routers => [<<10, 0, 3, 1>>, ?ADDR,
                                                                    <<10, 0, 2, 255>>, ?SERVER],
                                                        dns => lists:duplicate(2, ?SERVER)
                                                               ++ [<<10, 0, 0, I>> || I <- [1, 2, 3]]})},
                            C2, 0),
    ?assertEqual(30000, erx_dhcp4_core:next_deadline(C3)),
    ?assertMatch(#{routes := [#{prefix := ?ANY, plen := 0, gateway := ?SERVER}],
                   dns := [?SERVER, <<10, 0, 0, 1>>, <<10, 0, 0, 2>>]}, Lease),
    %% The subnet's broadcast address as the lease's address, offered and acknowledged.
    Bcast = fun(Type) -> (reply(Type, X, Mask#{lease_time => 600}))#dhcp4{yiaddr = <<10, 0, 2, 255>>} end,
    {C4, _} = erx_dhcp4_core:step({reply, Bcast(offer)}, C1, 0),
    ?assertEqual({C4, []}, erx_dhcp4_core:step({reply, Bcast(ack)}, C4, 0)).

%% --- classless routes, overload, the search list ---

classless_routes_and_overload_test() ->
    %% 10.1.0.0/15 is sent with a bit past its length, which the decoder clears.
    Routes = <<0, 10, 0, 2, 2, 15, 10, 1, 10, 0, 2, 3, 32, 192, 0, 2, 7, 0, 0, 0, 0>>,
    Bad = binary:replace(Routes, <<32, 192>>, <<33, 192>>),
    Msg = fun(Opts, File, Sname) ->
                  <<Fixed:236/binary, _/binary>> = erx_dhcp4_wire:encode(reply(ack, 7, #{})),
                  <<Head:44/binary, _:192/binary>> = Fixed,
                  <<Head/binary, (field(Sname, 64))/binary, (field(File, 128))/binary,
                    99, 130, 83, 99, 53, 1, 5, Opts/binary, 255>>
          end,
    {ok, #dhcp4{options = #{classless_routes := Decoded}}} =
        erx_dhcp4_wire:decode(Msg(<<121, 21, Routes/binary>>, <<>>, <<>>)),
    ?assertEqual([{?ANY, 0, ?SERVER}, {<<10, 0, 0, 0>>, 15, <<10, 0, 2, 3>>},
                  {<<192, 0, 2, 7>>, 32, ?ANY}], Decoded),
    ?assertEqual({error, {bad_option, 121}}, erx_dhcp4_wire:decode(Msg(<<121, 21, Bad/binary>>, <<>>, <<>>))),
    ?assertEqual({error, {bad_option, 121}}, erx_dhcp4_wire:decode(Msg(<<121, 4, 0, 10, 0, 2>>, <<>>, <<>>))),
    %% Overload 3: the file field, then the sname field, continue the options field's options.
    {ok, #dhcp4{options = Over}} =
        erx_dhcp4_wire:decode(Msg(<<52, 1, 3, 6, 4, 10, 0, 0, 1>>, <<6, 4, 10, 0, 0, 2, 255, 1>>,
                                  <<6, 4, 10, 0, 0, 3>>)),
    ?assertEqual([<<10, 0, 0, 1>>, <<10, 0, 0, 2>>, <<10, 0, 0, 3>>], maps:get(dns, Over)),
    %% Without overload the fields are not read; a bad overload or an option running past
    %% its field refuses the message.
    {ok, #dhcp4{options = Plain}} = erx_dhcp4_wire:decode(Msg(<<>>, <<6, 4, 10, 0, 0, 2>>, <<>>)),
    ?assertNot(is_map_key(dns, Plain)),
    ?assertEqual({error, {bad_option, 52}}, erx_dhcp4_wire:decode(Msg(<<52, 1, 4>>, <<>>, <<>>))),
    ?assertEqual({error, truncated_option},
                 erx_dhcp4_wire:decode(Msg(<<52, 1, 2>>, <<>>, <<0:(62 * 8), 6, 4>>))).

field(Bytes, Size) -> <<Bytes/binary, 0:((Size - byte_size(Bytes)) * 8)>>.

search_list_test() ->
    Body = fun(Opts) ->
                   <<Fixed:236/binary, _/binary>> = erx_dhcp4_wire:encode(reply(ack, 7, #{})),
                   <<Fixed/binary, 99, 130, 83, 99, 53, 1, 5, 15, (byte_size(Opts)), Opts/binary>>
           end,
    Names = fun(Text) -> {ok, #dhcp4{options = O}} = erx_dhcp4_wire:decode(Body(Text)),
                         maps:get(domain_name, O, dropped)
            end,
    ?assertEqual([<<"lan">>, <<"corp.example">>], Names(<<" lan\tcorp.example ">>)),
    ?assertEqual(dropped, Names(<<"lan", 0, 0>>)),
    ?assertEqual(dropped, Names(<<"a b c d e f g">>)),
    ?assertEqual(dropped, Names(<<"-lan">>)),
    ?assertEqual(dropped, Names(<<"lan", 27, "[2J">>)),
    %% One trailing dot is dropped; an empty label or one over 63 bytes refuses the option.
    ?assertEqual([<<"corp.example">>, <<"lan">>], Names(<<"corp.example. lan">>)),
    ?assertEqual(dropped, Names(<<"corp..example">>)),
    ?assertEqual(dropped, Names(<<".">>)),
    ?assertEqual(dropped, Names(<<"lan_a">>)),
    ?assertEqual(dropped, Names(<<(binary:copy(<<"a">>, 64))/binary, ".lan">>)).

%% An ACK for an address or from a server other than the offer's is not the answer.
ack_against_offer_test() ->
    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
    {C2, _} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 0),
    Ack = reply(ack, X, #{lease_time => 600}),
    Other = Ack#dhcp4{options = (Ack#dhcp4.options)#{server_id => <<10, 0, 2, 3>>}},
    ?assertEqual({C2, []}, erx_dhcp4_core:step({reply, Ack#dhcp4{yiaddr = <<10, 0, 2, 16>>}}, C2, 0)),
    ?assertEqual({C2, []}, erx_dhcp4_core:step({reply, Other}, C2, 0)).

%% A renewal that gives the same lease does not configure the interface again.
unchanged_renewal_test() ->
    {Bound, _} = bound_core(),
    T1 = erx_dhcp4_core:next_deadline(Bound),
    {Renewing, [{send, _, _, #dhcp4{xid = X2}}]} = erx_dhcp4_core:step(timeout, Bound, T1),
    {Again, []} = erx_dhcp4_core:step({reply, reply(ack, X2, ack_options())}, Renewing, T1 + 5),
    ?assertEqual(T1 + 1800 * 1000, erx_dhcp4_core:next_deadline(Again)).

%% A hostile server's routes and MTU: option 121 overrides the routers; routes into
%% loopback, multicast and the subnet's own prefix, and through an off-link or own
%% gateway, are dropped; a /32 lease reaches its router through an on-link route; the MTU
%% is held to the device's.
hostile_routes_test() ->
    Lease = fun(Options) ->
                    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
                    {C2, _} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 0),
                    {_, [{configure, L}]} =
                        erx_dhcp4_core:step({reply, reply(ack, X, Options#{lease_time => 600})}, C2, 0),
                    L
            end,
    Mask = #{subnet_mask => <<255, 255, 255, 0>>},
    Gw = <<10, 0, 2, 3>>,
    #{routes := Routes, mtu := 1500} =
        Lease(Mask#{mtu => 9000, routers => [?SERVER],
                    classless_routes => [{<<127, 0, 0, 0>>, 8, Gw}, {<<224, 0, 0, 0>>, 4, Gw},
                                         {<<10, 0, 2, 0>>, 24, Gw}, {?ANY, 0, <<10, 0, 3, 1>>},
                                         {?ANY, 0, ?ADDR}, {<<172, 16, 0, 0>>, 12, Gw},
                                         {<<172, 16, 0, 0>>, 12, ?SERVER}, {?ANY, 0, Gw}]}),
    ?assertEqual([#{prefix => <<172, 16, 0, 0>>, plen => 12, gateway => Gw},
                  #{prefix => ?ANY, plen => 0, gateway => Gw}], Routes),
    Router = <<10, 0, 9, 1>>,
    #{routes := Host, mtu := 576} =
        Lease(#{subnet_mask => <<255, 255, 255, 255>>, mtu => 576,
                classless_routes => [{Router, 32, ?ANY}, {?ANY, 0, Router}]}),
    ?assertEqual([#{prefix => Router, plen => 32, gateway => none},
                  #{prefix => ?ANY, plen => 0, gateway => Router}], Host).

%% Gateways judged against the routes kept: an on-link route that a duplicate prefix
%% displaced reaches nothing; a next hop may be no prefix's network or broadcast address;
%% a /32 lease with only routers reaches the first through a host route.
next_hop_test() ->
    Lease = fun(Options) ->
                    {C1, [{send, _, _, #dhcp4{xid = X}}]} = erx_dhcp4_core:step(timeout, new(), 0),
                    {C2, _} = erx_dhcp4_core:step({reply, reply(offer, X, #{})}, C1, 0),
                    {_, [{configure, L}]} =
                        erx_dhcp4_core:step({reply, reply(ack, X, Options#{lease_time => 600})}, C2, 0),
                    maps:get(routes, L)
            end,
    Mask = #{subnet_mask => <<255, 255, 255, 0>>},
    Gw = <<10, 0, 2, 3>>,
    ?assertEqual([#{prefix => <<10, 9, 0, 0>>, plen => 16, gateway => Gw}],
                 Lease(Mask#{classless_routes => [{<<10, 9, 0, 0>>, 16, Gw}, {<<10, 9, 0, 0>>, 16, ?ANY},
                                                  {?ANY, 0, <<10, 9, 0, 7>>}]})),
    ?assertEqual([#{prefix => <<10, 0, 0, 0>>, plen => 16, gateway => none}],
                 Lease(Mask#{classless_routes => [{<<10, 0, 0, 0>>, 16, ?ANY}, {?ANY, 0, <<10, 0, 2, 255>>},
                                                  {?ANY, 0, <<10, 0, 2, 0>>}, {?ANY, 0, <<10, 0, 255, 255>>}]})),
    Router = <<10, 0, 9, 1>>,
    ?assertEqual([#{prefix => Router, plen => 32, gateway => none},
                  #{prefix => ?ANY, plen => 0, gateway => Router}],
                 Lease(#{subnet_mask => <<255, 255, 255, 255>>, routers => [?ADDR, Router]})).

%% Renewing takes an ACK only from the lease's server; rebinding from any server, and a
%% new server alone changes nothing the interface holds.
renewal_server_test() ->
    {Bound, _} = bound_core(),
    T1 = erx_dhcp4_core:next_deadline(Bound),
    {Renewing, [{send, _, _, #dhcp4{xid = X2}}]} = erx_dhcp4_core:step(timeout, Bound, T1),
    Other = fun(Xid) -> Ack = reply(ack, Xid, ack_options()),
                        Ack#dhcp4{options = (Ack#dhcp4.options)#{server_id => <<10, 0, 2, 3>>}}
            end,
    ?assertEqual({Renewing, []}, erx_dhcp4_core:step({reply, Other(X2)}, Renewing, T1 + 5)),
    T2 = 100 + 3150 * 1000,
    {Rebinding, [{send, broadcast, _, #dhcp4{xid = X3}}]} = erx_dhcp4_core:step(timeout, Renewing, T2),
    {Rebound, []} = erx_dhcp4_core:step({reply, Other(X3)}, Rebinding, T2 + 5),
    %% The lease counts from the exchange's first REQUEST, sent at T1.
    ?assertEqual(T1 + 1800 * 1000, erx_dhcp4_core:next_deadline(Rebound)).
