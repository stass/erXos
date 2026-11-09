%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_net_tests).
-moduledoc """
EUnit cases of the command shell's `ifconfig` and `ping` (erx_cmd_ifconfig, erx_cmd_ping,
docs/design-shell.md, "Commands"): FreeBSD's layout of an interface, its flags with and
without a link, the selection of one by name; ping's options and their diagnostics, the
lines of a reply and of the statistics, and its matching of replies to the requests it
sent, by sequence number, with duplicates.
""".

-include_lib("eunit/include/eunit.hrl").

-define(US, 1000).    % one millisecond, in the record's microseconds

vtnet0(Link) ->
    #{name => vtnet0, lladdr => <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>, mtu => 1500,
      link => Link, config => dhcp,
      addrs => [#{addr => {10, 0, 2, 15}, plen => 24, broadcast => {10, 0, 2, 255}}],
      routes => [#{prefix => {0, 0, 0, 0}, plen => 0, gateway => {10, 0, 2, 2}}],
      dns => [{10, 0, 2, 3}], search => []}.

text(IoData) -> iolist_to_binary(IoData).

%% --- ifconfig --------------------------------------------------------------------

interface_in_freebsd_layout_test() ->
    ?assertEqual(<<"vtnet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500\n"
                   "\tether 52:54:00:12:34:56\n"
                   "\tinet 10.0.2.15 netmask 0xffffff00 broadcast 10.0.2.255\n"
                   "\tstatus: active\n">>,
                 text(erx_cmd_ifconfig:interface(vtnet0(up)))).

interface_without_a_link_or_address_test() ->
    Down = (vtnet0(down))#{addrs := [], mtu := 9000},
    ?assertEqual(<<"vtnet0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 9000\n"
                   "\tether 52:54:00:12:34:56\n"
                   "\tstatus: no carrier\n">>,
                 text(erx_cmd_ifconfig:interface(Down))).

netmask_follows_the_prefix_length_test() ->
    Narrow = (vtnet0(up))#{addrs := [#{addr => {192, 168, 86, 20}, plen => 30}]},
    ?assertMatch({_, _}, binary:match(text(erx_cmd_ifconfig:interface(Narrow)),
                                      <<"\tinet 192.168.86.20 netmask 0xfffffffc\n">>)).

selection_by_name_test() ->
    Two = [vtnet0(up), (vtnet0(up))#{name := vtnet1}],
    ?assertEqual({ok, Two}, erx_cmd_ifconfig:select([], Two)),
    ?assertMatch({ok, [#{name := vtnet1}]}, erx_cmd_ifconfig:select([<<"vtnet1">>], Two)),
    ?assertEqual({error, {no_interface, <<"vtnet9">>}}, erx_cmd_ifconfig:select([<<"vtnet9">>], Two)).

configuration_is_a_usage_error_test() ->
    ?assertEqual({error, usage}, erx_cmd_ifconfig:run([<<"vtnet0">>, <<"inet">>, <<"10.0.0.1">>], #{})),
    ?assertEqual({error, usage}, erx_cmd_ifconfig:run([<<"-z">>], #{})).

%% --- ping: options ---------------------------------------------------------------

options_and_their_defaults_test() ->
    ?assertMatch({ok, #{count := infinity, interval := 1000, size := 56, timeout := infinity,
                        host := {10, 0, 2, 2}, name := <<"10.0.2.2">>}},
                 erx_cmd_ping:options([<<"10.0.2.2">>])),
    ?assertMatch({ok, #{count := 3, interval := 250, size := 0, timeout := 5}},
                 erx_cmd_ping:options([<<"-c">>, <<"3">>, <<"-i0.25">>, <<"-s">>, <<"0">>,
                                       <<"-t">>, <<"5">>, <<"192.168.86.1">>])).

option_diagnostics_are_freebsds_test() ->
    Usage = fun(Args) ->
                    {error, {usage, Text}} = erx_cmd_ping:options(Args ++ [<<"10.0.2.2">>]),
                    text(Text)
            end,
    ?assertEqual(<<"invalid count of packets to transmit: `0'">>, Usage([<<"-c">>, <<"0">>])),
    ?assertEqual(<<"invalid timing interval: `1x'">>, Usage([<<"-i">>, <<"1x">>])),
    ?assertEqual(<<"packet size too large: 65508 > 65507">>, Usage([<<"-s">>, <<"65508">>])),
    ?assertEqual(<<"invalid packet size: `-1'">>, Usage([<<"-s">>, <<"-1">>])),
    ?assertEqual(<<"invalid timeout: `3601'">>, Usage([<<"-t">>, <<"3601">>])),
    %% A control byte in a value reaches the terminal escaped.
    ?assertEqual(nomatch, binary:match(Usage([<<"-c">>, <<"\e[2J">>]), <<"\e">>)),
    ?assertEqual({error, {no_host, <<"example.org">>}}, erx_cmd_ping:options([<<"example.org">>])),
    ?assertEqual({error, usage}, erx_cmd_ping:options([])),
    ?assertEqual({error, usage}, erx_cmd_ping:options([<<"10.0.2.2">>, <<"10.0.2.3">>])),
    ?assertEqual({error, usage}, erx_cmd_ping:options([<<"-f">>, <<"10.0.2.2">>])).

%% --- ping: matching and lines ------------------------------------------------------

payload_carries_the_time_and_freebsds_fill_test() ->
    <<_Time:8/binary, Fill/binary>> = erx_cmd_ping:payload(56, 123 * ?US),
    ?assertEqual(48, byte_size(Fill)),
    ?assertEqual(<<8, 9, 10>>, binary:part(Fill, 0, 3)),
    ?assertEqual(<<0, 0, 0>>, erx_cmd_ping:payload(3, 0)).

reply_line_and_round_trip_test() ->
    R0 = erx_cmd_ping:sent(0, 1000 * ?US, erx_cmd_ping:new(56)),
    {Line, R1} = erx_cmd_ping:reply({{10, 0, 2, 2}, 255, 0, <<0:(56 * 8)>>}, 1000 * ?US + 412, R0),
    ?assertEqual(<<"64 bytes from 10.0.2.2: icmp_seq=0 ttl=255 time=0.412 ms\n">>, text(Line)),
    ?assertEqual(<<"\n--- 10.0.2.2 ping statistics ---\n"
                   "1 packets transmitted, 1 packets received, 0.0% packet loss\n"
                   "round-trip min/avg/max/stddev = 0.412/0.412/0.412/0.000 ms\n">>,
                 text(erx_cmd_ping:statistics(#{name => <<"10.0.2.2">>}, R1))).

only_replies_to_remembered_requests_count_test() ->
    R0 = erx_cmd_ping:sent(1, 0, erx_cmd_ping:sent(0, 0, erx_cmd_ping:new(56))),
    %% A sequence number never sent, and one that shares a slot of the 1024 with a sent
    %% one, draw no line and change nothing.
    ?assertEqual({[], R0}, erx_cmd_ping:reply({{10, 0, 2, 2}, 64, 7, <<>>}, 5 * ?US, R0)),
    ?assertEqual({[], R0}, erx_cmd_ping:reply({{10, 0, 2, 2}, 64, 1025, <<>>}, 5 * ?US, R0)),
    {_, R1} = erx_cmd_ping:reply({{10, 0, 2, 2}, 64, 1, <<0:64>>}, 2 * ?US, R0),
    ?assertEqual(<<"\n--- h ping statistics ---\n"
                   "2 packets transmitted, 1 packets received, 50.0% packet loss\n"
                   "round-trip min/avg/max/stddev = 2.000/2.000/2.000/0.000 ms\n">>,
                 text(erx_cmd_ping:statistics(#{name => <<"h">>}, R1))).

duplicate_is_marked_and_counted_test() ->
    R0 = erx_cmd_ping:sent(0, 0, erx_cmd_ping:new(56)),
    {_, R1} = erx_cmd_ping:reply({{10, 0, 2, 2}, 64, 0, <<0:64>>}, 1 * ?US, R0),
    {Dup, R2} = erx_cmd_ping:reply({{10, 0, 2, 2}, 64, 0, <<0:64>>}, 3 * ?US, R1),
    ?assertEqual(<<"16 bytes from 10.0.2.2: icmp_seq=0 ttl=64 time=3.000 ms (DUP!)\n">>, text(Dup)),
    ?assertEqual(<<"\n--- h ping statistics ---\n"
                   "1 packets transmitted, 1 packets received, +1 duplicates, 0.0% packet loss\n"
                   "round-trip min/avg/max/stddev = 1.000/2.000/3.000/1.000 ms\n">>,
                 text(erx_cmd_ping:statistics(#{name => <<"h">>}, R2))).

small_requests_carry_no_time_test() ->
    R0 = erx_cmd_ping:sent(0, 0, erx_cmd_ping:new(4)),
    {Line, R1} = erx_cmd_ping:reply({{10, 0, 2, 2}, 64, 0, <<0:32>>}, 9 * ?US, R0),
    ?assertEqual(<<"12 bytes from 10.0.2.2: icmp_seq=0 ttl=64\n">>, text(Line)),
    ?assertEqual(<<"\n--- h ping statistics ---\n"
                   "1 packets transmitted, 1 packets received, 0.0% packet loss\n">>,
                 text(erx_cmd_ping:statistics(#{name => <<"h">>}, R1))).

no_reply_is_total_loss_test() ->
    R = erx_cmd_ping:sent(2, 0, erx_cmd_ping:sent(1, 0, erx_cmd_ping:sent(0, 0, erx_cmd_ping:new(56)))),
    ?assertEqual(<<"PING 10.0.2.9 (10.0.2.9): 56 data bytes\n">>,
                 text(erx_cmd_ping:header(#{host => {10, 0, 2, 9}, name => <<"10.0.2.9">>}, 56))),
    ?assertEqual(<<"\n--- 10.0.2.9 ping statistics ---\n"
                   "3 packets transmitted, 0 packets received, 100.0% packet loss\n">>,
                 text(erx_cmd_ping:statistics(#{name => <<"10.0.2.9">>}, R))).

%% --- ping: the loop ------------------------------------------------------------

%% A peer that keeps the socket's queue full, here with duplicates of the first reply,
%% must not hold back the interval timer: `-c 2` still sends its second request, waits
%% out the grace period and ends.
a_stream_of_replies_does_not_stop_the_count_test_() ->
    {timeout, 30, fun() ->
        Sock = spawn_link(fun flooding_socket/0),
        Opts = #{count => 2, interval => 10, size => 56, timeout => infinity,
                 host => {10, 0, 2, 2}, name => <<"10.0.2.2">>},
        Self = self(),
        Pinger = spawn_link(fun() ->
                                    Self ! {done, erx_cmd_ping:ping(Sock, Opts, #{stdout => null, stderr => null,
                                                                                  name => <<"ping">>})}
                            end),
        receive
            {done, Result} -> ?assertEqual(ok, Result)
        after 10000 ->
            unlink(Pinger),
            exit(Pinger, kill),
            ?assert(false)
        end
    end}.

%% Answers every recv at once with a reply to sequence number 0, and every send with ok.
flooding_socket() ->
    receive
        {'$gen_call', From, {recv, _}} ->
            gen_server:reply(From, {ok, {{10, 0, 2, 2}, 64, 0, <<0:64>>}}),
            flooding_socket();
        {'$gen_call', From, {send, _, _, _}} ->
            gen_server:reply(From, ok),
            flooding_socket();
        {'$gen_call', From, close} ->
            gen_server:reply(From, ok)
    end.
