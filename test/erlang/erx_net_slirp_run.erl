%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The stack on stock OTP against QEMU's user networking (docs/design-network-stack.md,
%% "The stack on a development host"), run by test/integration/erx_net_slirp_test.rb: one
%% pipe interface over a `udp` far end to a QEMU that runs no machine, its `dgram` backend
%% and slirp joined on one hub. The run takes a DHCP lease, resolves the gateway by ARP,
%% pings it, and exchanges a datagram with a UDP echo server on the host, which slirp
%% reaches at 10.0.2.2. Each step prints one line; the node halts 0 when all pass.
-module(erx_net_slirp_run).

-export([main/1]).

-define(GATEWAY, <<10, 0, 2, 2>>).
-define(LEASED, <<10, 0, 2, 15>>).
-define(WAIT_MS, 15000).

main([QemuPort, StackPort, EchoPort]) ->
    Loopback = {127, 0, 0, 1},
    Far = {udp, {Loopback, list_to_integer(StackPort)}, {Loopback, list_to_integer(QemuPort)}},
    {ok, _} = erx_net_sup:start_link(#{interfaces => [#{name => en0, ip4 => dhcp,
        transport => {erx_net_pipe, #{far => Far, lladdr => <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>}}}]}),
    Steps = [{lease, fun lease/1}, {arp, fun arp/1}, {ping, fun ping/1},
             {udp, fun(If) -> udp(If, list_to_integer(EchoPort)) end}],
    {ok, #{pid := If}} = erx_net_tables:interface(en0),
    Results = [{Name, Step(If)} || {Name, Step} <- Steps],
    [io:format("~s ~p~n", [Name, Result]) || {Name, Result} <- Results],
    halt(case lists:all(fun({_, R}) -> R =:= ok end, Results) of true -> 0; false -> 1 end).

%% Polls Check until it answers ok, for at most WAIT_MS.
until(Check) -> until(Check, erlang:monotonic_time(millisecond) + ?WAIT_MS).

until(Check, Deadline) ->
    case Check() of
        ok -> ok;
        Other ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {timeout, Other};
                false -> timer:sleep(50), until(Check, Deadline)
            end
    end.

lease(_If) ->
    until(fun() ->
                  {ok, If} = current(),
                  case erx_net_if:admin(If, lease) of
                      {ok, #{addr := ?LEASED}} -> ok;
                      Other -> Other
                  end
          end).

current() ->
    {ok, #{pid := If}} = erx_net_tables:interface(en0),
    {ok, If}.

%% A datagram to the gateway makes the interface resolve it.
arp(If) ->
    {ok, Sock} = erx_udp_sock:open(0, #{active => false}),
    _ = erx_udp_sock:send(Sock, {10, 0, 2, 2}, 9, <<"resolve">>),
    ok = erx_udp_sock:close(Sock),
    until(fun() ->
                  case erx_net_tables:neighbour(If, ?GATEWAY) of
                      {<<_:48>>, fresh} -> ok;
                      Other -> Other
                  end
          end).

%% An echo request handed to the driver as any sender hands frames; slirp's reply reaches
%% the interface, which has no raw socket to give it to and counts it as `icmp_type'.
ping(If) ->
    Before = maps:get(icmp_type, counters(If), 0),
    {_, Snap} = erx_net_tables:configuration(),
    {ok, #{iface := #{driver := Driver, driver_credit := Tx}} = Path} =
        erx_net_frame:path(?GATEWAY, #{}, Snap),
    Request = erx_icmp4_wire:encode({icmp4, 8, 0, {echo, 16#e1, 1}}, <<"erx_net ping">>),
    {ok, Packets, _} = erx_net_frame:ip(Path, 1, Request, erx_net_rand:new(<<1:128>>)),
    {send, Frames} = erx_net_frame:address(Path, erx_net_tables:neighbour(If, ?GATEWAY), Packets),
    ok = erx_net_credit:hand(Driver, Tx, length(Frames), {transmit, Frames}),
    until(fun() ->
                  case maps:get(icmp_type, counters(If), 0) of
                      N when N > Before -> ok;
                      N -> {replies, N}
                  end
          end).

counters(If) ->
    {ok, Counters} = erx_net_if:admin(If, counters),
    Counters.

udp(_If, EchoPort) ->
    {ok, Sock} = erx_udp_sock:open(0, #{active => false}),
    Payload = <<"erx_net says hello">>,
    ok = erx_udp_sock:send(Sock, {10, 0, 2, 2}, EchoPort, Payload),
    Result = case erx_udp_sock:recv(Sock, ?WAIT_MS) of
                 {ok, {{10, 0, 2, 2}, EchoPort, Payload}} -> ok;
                 Other -> Other
             end,
    ok = erx_udp_sock:close(Sock),
    Result.
