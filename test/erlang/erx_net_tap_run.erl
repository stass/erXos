%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The stack on a host's own stock OTP joined to a tap device through the tap
%% transport (docs/design-network-stack.md, "The tap transport", "FreeBSD's jails on the test host"). One
%% interface takes a static address on the tap's network, resolves a peer by ARP, and then
%% stays up for a while to answer the peer's ARP and ping, printing its counters at the
%% end. Each step prints one line; the node halts 0 when the stack resolved the peer.
%%
%%   erl -pa erx_net/ebin -noshell -run erx_net_tap_run main /dev/tap0 10.77.0.100 \
%%       10.77.0.10 30
-module(erx_net_tap_run).

-export([main/1]).

-define(LLADDR, <<16#02, 16#65, 16#72, 16#78, 0, 16#64>>).
-define(WAIT_MS, 10000).

main([Device, Addr, Peer, Seconds]) ->
    {ok, Own} = inet:parse_ipv4strict_address(Addr),
    {ok, PeerIp} = inet:parse_ipv4strict_address(Peer),
    {ok, _} = erx_net_sup:start_link(#{interfaces => [#{name => en0,
        ip4 => #{addr => ip4(Own), plen => 24},
        transport => {erx_tap, #{device => Device, lladdr => ?LLADDR}}}]}),
    {ok, #{pid := If}} = erx_net_tables:interface(en0),
    io:format("up ~s on ~s as ~s~n", [Addr, Device, mac(?LLADDR)]),
    Arp = arp(If, PeerIp),
    io:format("arp ~p~n", [Arp]),
    timer:sleep(list_to_integer(Seconds) * 1000),
    {ok, Counters} = erx_net_if:admin(current(), counters),
    io:format("counters ~p~n", [Counters]),
    halt(case Arp of {ok, _} -> 0; _ -> 1 end).

ip4({A, B, C, D}) -> <<A, B, C, D>>.

mac(Mac) -> lists:join($:, [io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Mac]).

current() ->
    {ok, #{pid := If}} = erx_net_tables:interface(en0),
    If.

%% A datagram to the peer makes the interface resolve it.
arp(If, PeerIp) ->
    {ok, Sock} = erx_gen_udp:open(0, [{active, false}, binary]),
    _ = erx_gen_udp:send(Sock, PeerIp, 9, <<"resolve">>),
    ok = erx_gen_udp:close(Sock),
    Deadline = erlang:monotonic_time(millisecond) + ?WAIT_MS,
    wait_neighbour(If, ip4(PeerIp), Deadline).

wait_neighbour(If, Peer, Deadline) ->
    case erx_net_tables:neighbour(If, Peer) of
        {<<_:48>> = Mac, fresh} ->
            {ok, lists:flatten(mac(Mac))};
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {timeout, Other};
                false -> timer:sleep(50), wait_neighbour(If, Peer, Deadline)
            end
    end.
