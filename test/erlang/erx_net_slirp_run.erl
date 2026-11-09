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

main([QemuPort, StackPort, EchoPort, TcpPort, ClosedPort]) ->
    Loopback = {127, 0, 0, 1},
    Far = {udp, {Loopback, list_to_integer(StackPort)}, {Loopback, list_to_integer(QemuPort)}},
    {ok, _} = erx_net_sup:start_link(#{interfaces => [#{name => en0, ip4 => dhcp,
        transport => {erx_net_pipe, #{far => Far, lladdr => <<16#52, 16#54, 0, 16#12, 16#34, 16#56>>}}}]}),
    Steps = [{lease, fun lease/1}, {arp, fun arp/1}, {ping, fun ping/1},
             {udp, fun(If) -> udp(If, list_to_integer(EchoPort)) end},
             {tcp_passive, fun(_) -> tcp_passive(list_to_integer(TcpPort)) end},
             {tcp_active, fun(_) -> tcp_active(list_to_integer(TcpPort)) end},
             {tcp_refused, fun(_) -> tcp_refused(list_to_integer(ClosedPort)) end},
             {tcp_whole_buffer, fun(_) -> tcp_whole_buffer(list_to_integer(TcpPort)) end},
             {tcp_short_tail, fun(_) -> tcp_short_tail(list_to_integer(TcpPort)) end}],
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

%% An echo request from an echo socket; slirp's reply comes back to the socket that
%% holds its identifier.
ping(_If) ->
    {ok, Sock} = erx_icmp_sock:open(#{}),
    Payload = <<"erx_net ping">>,
    Result = case erx_icmp_sock:send(Sock, {10, 0, 2, 2}, 1, #{data => Payload}) of
                 ok ->
                     case erx_icmp_sock:recv(Sock, ?WAIT_MS) of
                         {ok, {{10, 0, 2, 2}, _Ttl, 1, Payload}} -> ok;
                         Other -> Other
                     end;
                 Error -> Error
             end,
    ok = erx_icmp_sock:close(Sock),
    Result.

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

%% 1 MiB to the host's TCP echo server and back, in passive mode, a sender beside the
%% reader so that neither direction waits on the other, then a close; the time is printed.
tcp_passive(Port) ->
    Payload = pattern(1 bsl 20),
    Start = erlang:monotonic_time(millisecond),
    {ok, S} = erx_gen_tcp:connect({10, 0, 2, 2}, Port, [binary, {active, false}], ?WAIT_MS),
    Self = self(),
    _ = spawn_link(fun() -> Self ! {sent, gen_tcp:send(S, Payload)} end),
    Received = recv_all(S, byte_size(Payload), []),
    Sent = receive {sent, R} -> R after ?WAIT_MS -> timeout end,
    ok = gen_tcp:close(S),
    io:format("tcp_transfer_ms ~b~n", [erlang:monotonic_time(millisecond) - Start]),
    case {Sent, Received =:= Payload} of
        {ok, true} -> ok;
        Other -> {Other, byte_size(Received)}
    end.

recv_all(_S, 0, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
recv_all(S, Left, Acc) ->
    case gen_tcp:recv(S, 0, ?WAIT_MS) of
        {ok, Data} -> recv_all(S, Left - byte_size(Data), [Data | Acc]);
        {error, _} -> iolist_to_binary(lists:reverse(Acc))
    end.

%% 64 KiB in active mode: the data arrives as messages, the half close draws the server's
%% close, which arrives as tcp_closed after the last byte.
tcp_active(Port) ->
    Payload = pattern(1 bsl 16),
    {ok, S} = erx_gen_tcp:connect({10, 0, 2, 2}, Port, [binary, {active, true}], ?WAIT_MS),
    ok = gen_tcp:send(S, Payload),
    ok = gen_tcp:shutdown(S, write),
    Result = case active_all(S, []) of
                 {closed, Payload} -> ok;
                 {Why, Data} -> {Why, byte_size(Data)}
             end,
    ok = gen_tcp:close(S),
    Result.

active_all(S, Acc) ->
    receive
        {tcp, S, Data} -> active_all(S, [Data | Acc]);
        {tcp_closed, S} -> {closed, iolist_to_binary(lists:reverse(Acc))}
    after ?WAIT_MS -> {timeout, iolist_to_binary(lists:reverse(Acc))}
    end.

%% A port nobody listens on: slirp's RST to the SYN refuses the connect.
tcp_refused(Port) ->
    case erx_gen_tcp:connect({10, 0, 2, 2}, Port, [binary], ?WAIT_MS) of
        {error, econnrefused} -> ok;
        Other -> Other
    end.

%% Four reads of the whole receive buffer, 64 KiB each, of 256 KiB echoed: stock answers
%% each with exactly 64 KiB at once, and so must the stack. Its window closes short of the
%% full buffer when a waiting read counts against it, and only the sender's persist probes,
%% 5 s apart at the least, then complete the read; the reads must take less than that.
tcp_whole_buffer(Port) ->
    case {whole_buffer(erx, Port), whole_buffer(stock, Port)} of
        {Same, Same} -> ok;
        Differ -> Differ
    end.

whole_buffer(Stack, Port) ->
    Payload = pattern(4 * 65536),
    Start = erlang:monotonic_time(millisecond),
    {ok, S} = connect(Stack, Port),
    _ = spawn(fun() -> gen_tcp:send(S, Payload) end),
    Reads = [gen_tcp:recv(S, 65536, ?WAIT_MS) || _ <- lists:seq(1, 4)],
    Ms = erlang:monotonic_time(millisecond) - Start,
    ok = gen_tcp:close(S),
    io:format("tcp_whole_buffer_ms ~s ~b~n", [Stack, Ms]),
    {[size_of(R) || R <- Reads], iolist_to_binary([D || {ok, D} <- Reads]) =:= Payload,
     {within_persist, Ms < 2500}}.

%% 3000 bytes echoed and the server's close, read 1460 at a time: two full reads, then
%% `{error, closed}` for the 80 bytes left, on both. Then stock has discarded the 80 bytes
%% and its read side (`{error, enotconn}`); the stack keeps them for `recv(_, 0)`.
tcp_short_tail(Port) ->
    case {short_tail(erx, Port), short_tail(stock, Port)} of
        {{Same, {ok, 80}}, {Same, {error, enotconn}}} -> ok;
        Differ -> Differ
    end.

short_tail(Stack, Port) ->
    {ok, S} = connect(Stack, Port),
    ok = gen_tcp:send(S, pattern(3000)),
    ok = gen_tcp:shutdown(S, write),
    Reads = [size_of(gen_tcp:recv(S, 1460, ?WAIT_MS)) || _ <- lists:seq(1, 3)],
    After = size_of(gen_tcp:recv(S, 0, ?WAIT_MS)),
    ok = gen_tcp:close(S),
    {Reads, After}.

connect(erx, Port) ->
    erx_gen_tcp:connect({10, 0, 2, 2}, Port, [binary, {active, false}], ?WAIT_MS);
connect(stock, Port) ->
    gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], ?WAIT_MS).

size_of({ok, Data}) -> {ok, byte_size(Data)};
size_of(Error) -> Error.

pattern(N) ->
    << <<(I rem 251)>> || I <- lists:seq(0, N - 1) >>.
