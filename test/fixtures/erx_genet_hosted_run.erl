%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet_hosted_run).
-moduledoc """
The network stack over erx_genet over the hosted runtime's stand-in GENET
(test/integration/runtime_genet_test.rb). The stack has one interface, genet0 at
10.0.3.2/24, whose transport is erx_genet on a stand-in record; a wire process here runs the
stand-in's engine, `erx_device:stand_in_transmitted/1` and `erx_device:stand_in_receive/2`,
every millisecond, fires the line when it moved anything, and plays the far end, 10.0.3.9,
with no stack of its own:

* it answers ARP for 10.0.3.9;
* it echoes a UDP datagram by swapping the two addresses and the two ports, which leaves
  every checksum right, since a one's-complement sum does not depend on the order of its
  words;
* it is a TCP echo server on port 7 with a fixed window and no options: it answers a SYN, sends
  back each in-order segment's bytes with their acknowledgement, and answers a FIN with its
  own. Nothing is lost on this wire, so it never retransmits and drops what is out of order.

`run/0` prints `udp ok` and `tcp ok` when the stack's sockets get back what they sent, then
the wire's counts, and `ok` last when each way carried more frames than a descriptor ring
holds, so both rings wrapped.
""".

-export([run/0]).

-define(ME, {10, 0, 3, 2}).
-define(FAR, {10, 0, 3, 9}).
-define(FAR_MAC, <<16#02, 0, 0, 0, 0, 16#09>>).
-define(ECHO_PORT, 7).
-define(WAIT_MS, 10000).
-define(ISS, 16#10000).
%% The descriptors of each GENET ring (erx_device_genet.h's ERX_DEVICE_GENET_SIZE).
-define(RING, 256).
%% The TCP run's pieces: 160,000 bytes, about 300 segments of the far end's default MSS.
-define(TCP_PIECE, 8000).
-define(TCP_PIECES, 20).

run() ->
    Record = #{peripheral => genet, window => stand_in, lines => [0]},
    Genet0 = #{name => genet0, ip4 => #{addr => ip(?ME), plen => 24},
               transport => {erx_genet, #{record => Record}}},
    {ok, Stack} = erx_net_sup:start_link(#{interfaces => [Genet0]}),
    unlink(Stack),
    Dev = until(fun device/0),
    Wire = spawn_link(fun() -> wire(Dev, #{}, [], #{sent => 0, received => 0}) end),
    Udp = udp(),
    Tcp = tcp(),
    io:format("udp ~p~ntcp ~p~n", [Udp, Tcp]),
    Wire ! {counts, self()},
    Counts = receive {counts, C} -> C end,
    io:format("wire ~p~n", [Counts]),
    Wrapped = maps:get(sent, Counts) > ?RING andalso maps:get(received, Counts) > ?RING,
    case {Udp, Tcp, Wrapped} of
        {ok, ok, true} -> io:format("ok~n");
        _ -> io:format("failed~n")
    end.

%% A datagram of each size to the far end's echo port comes back from it.
udp() ->
    {ok, Sock} = erx_gen_udp:open(0, [{active, false}, binary]),
    %% The first datagram waits out the link coming up: one sent while it is down is dropped.
    First = until(fun() -> case udp_echo(Sock, payload(1), 200) of ok -> ok; _ -> false end end),
    Results = [First | [udp_echo(Sock, payload(Size), ?WAIT_MS) || Size <- [18, 1472]]],
    ok = erx_gen_udp:close(Sock),
    all_ok(Results).

udp_echo(Sock, Payload, Wait) ->
    ok = erx_gen_udp:send(Sock, ?FAR, ?ECHO_PORT, Payload),
    case erx_gen_udp:recv(Sock, 0, Wait) of
        {ok, {?FAR, ?ECHO_PORT, Payload}} -> ok;
        Other -> {udp, byte_size(Payload), Other}
    end.

%% TCP_PIECES pieces to the far end's echo server, in segments of its default MSS, each back
%% whole before the next is sent: the far end ignores the window the stack offers, so the
%% stack's receive buffer never holds more than one piece unread.
tcp() ->
    case erx_gen_tcp:connect(?FAR, ?ECHO_PORT, [binary, {active, false}], ?WAIT_MS) of
        {ok, S} ->
            Result = echo_pieces(S, ?TCP_PIECES),
            ok = gen_tcp:close(S),
            Result;
        Other ->
            {tcp, connect, Other}
    end.

%% Each piece's bytes start at a different place in payload/1's cycle, so a piece the ring
%% handed back stale differs from the one sent.
echo_pieces(_S, 0) ->
    ok;
echo_pieces(S, Left) ->
    Piece = binary:part(payload(?TCP_PIECE + Left), Left, ?TCP_PIECE),
    ok = gen_tcp:send(S, Piece),
    case recv_all(S, ?TCP_PIECE, []) of
        Piece -> echo_pieces(S, Left - 1);
        Got -> {tcp, Left, byte_size(Got)}
    end.

recv_all(_S, 0, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
recv_all(S, Left, Acc) ->
    case gen_tcp:recv(S, 0, ?WAIT_MS) of
        {ok, Bytes} when byte_size(Bytes) =< Left -> recv_all(S, Left - byte_size(Bytes), [Bytes | Acc]);
        _ -> iolist_to_binary(lists:reverse(Acc))
    end.

payload(Size) -> << <<(I rem 251)>> || I <- lists:seq(1, Size) >>.

all_ok(Results) ->
    case [R || R <- Results, R =/= ok] of
        [] -> ok;
        Failed -> Failed
    end.

%% --- The stack's side ----------------------------------------------------------------------

%% The driver's device, once the stack has started genet0's driver.
device() ->
    case erx_net_tables:driver(genet0) of
        {ok, Driver} -> erx_genet:device(erx_net_driver:transport_state(Driver));
        none -> false
    end.

%% Polls Check every 20 ms until it answers other than false, for at most WAIT_MS.
until(Check) -> until(Check, erlang:monotonic_time(millisecond) + ?WAIT_MS).

until(Check, Deadline) ->
    case Check() of
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> error(timeout);
                false -> timer:sleep(20), until(Check, Deadline)
            end;
        Answer ->
            Answer
    end.

%% --- The wire and the far end ----------------------------------------------------------------

%% Each round sends what the stack posted, hands the far end's answers to the receive ring,
%% keeping what does not fit for the next round, and fires the line if anything moved.
wire(Dev, Conns0, Backlog, Counts0) ->
    receive
        {counts, From} -> From ! {counts, Counts0}, wire(Dev, Conns0, Backlog, Counts0)
    after 1 ->
        Sent = erx_device:stand_in_transmitted(Dev),
        {Answers, Conns} = lists:foldl(fun(Frame, {Out, Conns1}) ->
                                               {More, Conns2} = far_end(Frame, Conns1),
                                               {Out ++ More, Conns2}
                                       end, {Backlog, Conns0}, Sent),
        Taken = erx_device:stand_in_receive(Dev, Answers),
        [ok = erx_device:stand_in_fire(Dev, 0) || Sent =/= [] orelse Taken > 0],
        Counts = #{sent => maps:get(sent, Counts0) + length(Sent),
                   received => maps:get(received, Counts0) + Taken},
        wire(Dev, Conns, lists:nthtail(Taken, Answers), Counts)
    end.

%% The far end's answers to one frame the stack sent.
far_end(<<_Dst:6/binary, Src:6/binary, 16#0806:16, 1:16, 16#0800:16, 6, 4, 1:16,
          Sha:6/binary, Spa:4/binary, _Tha:6/binary, Tpa:4/binary, _/binary>>, Conns) ->
    case Tpa =:= ip(?FAR) of
        true ->
            {[<<Src/binary, ?FAR_MAC/binary, 16#0806:16, 1:16, 16#0800:16, 6, 4, 2:16,
                ?FAR_MAC/binary, Tpa/binary, Sha/binary, Spa/binary>>], Conns};
        false ->
            {[], Conns}
    end;
far_end(<<Dst:6/binary, Src:6/binary, 16#0800:16, Ip/binary>>, Conns) when Dst =:= ?FAR_MAC ->
    ip_packet(Src, Ip, Conns);
far_end(_Other, Conns) ->
    {[], Conns}.

ip_packet(StackMac, <<4:4, 5:4, _Tos, Total:16, _/binary>> = Ip, Conns) when Total =< byte_size(Ip) ->
    <<Head:12/binary, Src:4/binary, Dst:4/binary, Rest:(Total - 20)/binary, _Pad/binary>> = Ip,
    <<_:9/binary, Proto, _/binary>> = Head,
    Frame = fun(Packet) -> <<StackMac/binary, ?FAR_MAC/binary, 16#0800:16, Packet/binary>> end,
    case {Dst =:= ip(?FAR), Proto, Rest} of
        {true, 17, <<Sport:16, ?ECHO_PORT:16, Udp/binary>>} ->
            {[Frame(<<Head/binary, Dst/binary, Src/binary, ?ECHO_PORT:16, Sport:16, Udp/binary>>)], Conns};
        {true, 6, <<Sport:16, ?ECHO_PORT:16, _/binary>>} ->
            {Segments, Conns1} = tcp_segment(Sport, Rest, Conns),
            {[Frame(ip4(Dst, Src, 6, Seg)) || Seg <- Segments], Conns1};
        _ ->
            {[], Conns}
    end;
ip_packet(_StackMac, _Ip, Conns) ->
    {[], Conns}.

%% The echo server's answer to one segment from the stack's port Sport, and its state for
%% that port: {SndNxt, RcvNxt}.
tcp_segment(Sport, <<_:32, Seq:32, _Ack:32, Off:4, _:4, Flags, _Win:16, _Sum:16, _Urg:16, _/binary>> = Seg,
            Conns) ->
    Data = binary:part(Seg, Off * 4, byte_size(Seg) - Off * 4),
    Syn = Flags band 16#02 =/= 0,
    Fin = Flags band 16#01 =/= 0,
    case maps:find(Sport, Conns) of
        _ when Syn ->
            Next = (Seq + 1) band 16#ffffffff,
            {[tcp(Sport, ?ISS, Next, 16#12, <<>>)], Conns#{Sport => {?ISS + 1, Next}}};
        {ok, {SndNxt, Seq}} when Data =/= <<>>; Fin ->
            RcvNxt = (Seq + byte_size(Data) + case Fin of true -> 1; false -> 0 end) band 16#ffffffff,
            Echo = [tcp(Sport, SndNxt, RcvNxt, 16#18, Data) || Data =/= <<>>],
            SndNxt1 = SndNxt + byte_size(Data),
            Close = [tcp(Sport, SndNxt1, RcvNxt, 16#11, <<>>) || Fin],
            {Echo ++ Close, Conns#{Sport => {SndNxt1 + length(Close), RcvNxt}}};
        _ ->
            {[], Conns}
    end.

%% A segment from the echo port to the stack's port, its checksum filled by ip4/4.
tcp(Dport, Seq, Ack, Flags, Data) ->
    <<?ECHO_PORT:16, Dport:16, Seq:32, Ack:32, 5:4, 0:4, Flags, 65535:16, 0:16, 0:16, Data/binary>>.

%% An IPv4 packet from Src to Dst carrying a TCP segment, with both checksums.
ip4(Src, Dst, Proto, Seg) ->
    Pseudo = <<Src/binary, Dst/binary, 0, Proto, (byte_size(Seg)):16>>,
    <<Before:16/binary, 0:16, After/binary>> = Seg,
    Sum = csum(<<Pseudo/binary, Seg/binary>>),
    Head0 = <<4:4, 5:4, 0, (20 + byte_size(Seg)):16, 0:16, 2:3, 0:13, 64, Proto, 0:16, Src/binary, Dst/binary>>,
    <<H1:10/binary, 0:16, H2/binary>> = Head0,
    <<H1/binary, (csum(Head0)):16, H2/binary, Before/binary, Sum:16, After/binary>>.

csum(Bytes) ->
    Padded = case byte_size(Bytes) rem 2 of 0 -> Bytes; 1 -> <<Bytes/binary, 0>> end,
    fold(lists:sum([W || <<W:16>> <= Padded])).

fold(Sum) when Sum > 16#ffff -> fold((Sum band 16#ffff) + (Sum bsr 16));
fold(Sum) -> bnot Sum band 16#ffff.

ip({A, B, C, D}) -> <<A, B, C, D>>.
