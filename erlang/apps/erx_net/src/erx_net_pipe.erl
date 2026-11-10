%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_pipe).
-moduledoc """
The portable transport (docs/design-network-stack.md, "The driver", "The pipe"): Ethernet
frames, without their frame check sequence, exchanged with one far end, one frame per
datagram or Erlang message. The pipe parses nothing. On every end a frame longer than the
MTU and its 14-byte Ethernet header is dropped as `too_long`, and a send the far end cannot
take as `refused`.

* `{udp, Local, Peer}`, as QEMU's `dgram` network backend carries frames. The socket runs
  `{active, 64}`, set to 64 again at each `udp_passive`, so at most 64 datagrams wait in
  the driver's mailbox and the host's socket buffer is the only queue ahead of it; a batch
  is the datagrams waiting, up to 64 KiB. A datagram from any address but `Peer` is
  dropped as `stranger`. UDP has no carrier, so the link is `up` from `init` on.
* `{process, Far}`, a test: `Far` is a pid, or a registered name looked up once at
  `init`, so that a restarted driver finds the far end registered since. Each frame is a
  message `{erx_net_pipe, Pid, Frame}` in either direction, and the far end may also send
  `{erx_net_pipe, Pid, {frames, Frames}}`, which reaches the driver as one batch, as a burst a
  medium hands up at once (docs/design-network-fastpath.md, "Verification"); a `Frame`
  that is not a binary is dropped as `malformed` (a type check, not a parse), and one from
  another pid as `stranger`. The pipe monitors the far end and stops when it ends, which ends the
  driver. A name that names no other process stops the pipe at its first message.

The pipe reports its link `up` from `init` on; the far end's end stops it instead of
taking the link down, and the driver's supervisor starts the pipe again. A frame sent
after the far end has gone but before the driver has seen it is dropped as `refused`.

The pipe finishes no checksum (`finish` `none`) and drops a delayed frame as `malformed`,
except in the process end's offload mode, a test configuration that stands for a medium
whose copy sums (docs/design-network-stack.md, "Checksums in the copy"): there its
`finish` is `copy`, a delayed frame reaches the far end with its checksum finished
(`erx_net_frame:finish/1`), and each received frame is handed up as `{sum, S, Frame}`
with its network sum.

The configuration: `far`; `lladdr`, which must be a unicast address with the locally
administered bit set; `mtu`, from 1,280 to 9,000 (1,500 when absent); `tx_limit`, the
frames that may wait at the driver (256 when absent); and `offload`, true for the offload
mode of a process end (false when absent).
""".

-behaviour(erx_net_driver).

-export([init/1, event/2, transmit/2]).

-export_type([far/0]).

-define(ETHER_HDR_LEN, 14).
-define(ACTIVE, 64).
-define(BATCH_BYTES, 65536).
-define(MTU_DEFAULT, 1500).
-define(TX_LIMIT_DEFAULT, 256).

-doc "The far end of a pipe.".
-type far() :: {udp, Local :: {inet:ip_address(), inet:port_number()},
                     Peer :: {inet:ip_address(), inet:port_number()}}
             | {process, pid() | atom()}.

-record(udp, {socket :: gen_udp:socket(), peer :: {inet:ip_address(), inet:port_number()},
              mtu :: pos_integer()}).
-record(process, {pid :: pid() | undefined, ref :: reference(), mtu :: pos_integer(),
                  offload :: boolean()}).

-doc false.
init(#{far := Far, lladdr := Lladdr} = Config) ->
    Mtu = maps:get(mtu, Config, ?MTU_DEFAULT),
    Limit = maps:get(tx_limit, Config, ?TX_LIMIT_DEFAULT),
    Offload = maps:get(offload, Config, false),
    maybe
        ok ?= check(lladdr, Lladdr, is_local_unicast(Lladdr)),
        ok ?= check(mtu, Mtu, is_integer(Mtu) andalso Mtu >= 1280 andalso Mtu =< 9000),
        ok ?= check(tx_limit, Limit, is_integer(Limit) andalso Limit > 0),
        ok ?= check(offload, Offload, offload_allowed(Offload, Far)),
        {ok, T} ?= open(Far, Mtu, Offload),
        {ok, #{link => ethernet, lladdr => Lladdr, mtu => Mtu, state => up, tx_limit => Limit,
               finish => case Offload of true -> copy; false -> none end}, T}
    end.

check(_Key, _Value, true) -> ok;
check(Key, Value, false) -> {error, {Key, Value}}.

%% Only a process end has the offload mode.
offload_allowed(false, _Far) -> true;
offload_allowed(true, {process, _}) -> true;
offload_allowed(_Offload, _Far) -> false.

%% Unicast (the group bit clear) and locally administered (the next bit set).
is_local_unicast(<<_:6, 1:1, 0:1, _:40>>) -> true;
is_local_unicast(_) -> false.

open({udp, {LocalIp, LocalPort}, {_, _} = Peer}, Mtu, false) ->
    case gen_udp:open(LocalPort, [binary, {ip, LocalIp}, {active, ?ACTIVE}]) of
        {ok, Socket} -> {ok, #udp{socket = Socket, peer = Peer, mtu = Mtu}};
        {error, Reason} -> {error, {udp, Reason}}
    end;
open({process, Pid}, Mtu, Offload) when is_pid(Pid) ->
    {ok, #process{pid = Pid, ref = erlang:monitor(process, Pid), mtu = Mtu, offload = Offload}};
open({process, Name}, Mtu, Offload) when is_atom(Name) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= self() ->
            open({process, Pid}, Mtu, Offload);
        %% Nothing, a port or the driver itself: a far end that has ended, told as one.
        _ ->
            Ref = make_ref(),
            self() ! {'DOWN', Ref, process, Name, noproc},
            {ok, #process{pid = undefined, ref = Ref, mtu = Mtu, offload = Offload}}
    end;
open(Far, _Mtu, _Offload) ->
    {error, {far, Far}}.

-doc false.
event({udp, Socket, Ip, Port, Data}, #udp{socket = Socket} = T) ->
    {datagrams([{Ip, Port, Data}], byte_size(Data), T), T};
event({udp_passive, Socket}, #udp{socket = Socket} = T) ->
    ok = inet:setopts(Socket, [{active, ?ACTIVE}]),
    {[], T};
event({erx_net_pipe, Pid, Frame}, #process{pid = Pid} = T) when is_binary(Frame) ->
    {burst([Frame], T), T};
event({erx_net_pipe, Pid, {frames, Frames}}, #process{pid = Pid} = T) when is_list(Frames) ->
    {burst(Frames, T), T};
event({erx_net_pipe, Pid, _}, #process{pid = Pid} = T) ->
    {[{dropped, malformed}], T};
event({erx_net_pipe, _, _}, #process{} = T) ->
    {[{dropped, stranger}], T};
event({'DOWN', Ref, process, _, Reason}, #process{ref = Ref}) ->
    {stop, {far_end, Reason}};
event(_Msg, T) ->
    {[], T}.

%% The datagrams already waiting from the socket join the first, up to 64 KiB; each is a
%% frame when it comes from the peer and fits the MTU.
datagrams(Got, Bytes, #udp{socket = Socket} = T) when Bytes < ?BATCH_BYTES ->
    receive
        {udp, Socket, Ip, Port, Data} -> datagrams([{Ip, Port, Data} | Got], Bytes + byte_size(Data), T)
    after 0 ->
        split(lists:reverse(Got), T)
    end;
datagrams(Got, _Bytes, T) ->
    split(lists:reverse(Got), T).

split(Datagrams, #udp{peer = {PeerIp, PeerPort}, mtu = Mtu}) ->
    {Drops, Frames} =
        lists:foldr(fun({Ip, Port, _}, {D, F}) when {Ip, Port} =/= {PeerIp, PeerPort} ->
                            {[{dropped, stranger} | D], F};
                       ({_, _, Data}, {D, F}) when byte_size(Data) > Mtu + ?ETHER_HDR_LEN ->
                            {[{dropped, too_long} | D], F};
                       ({_, _, Data}, {D, F}) ->
                            {D, [Data | F]}
                    end, {[], []}, Datagrams),
    Drops ++ [{frames, Frames}].

%% The frames of one message from a process end as one batch, each that is a binary and fits
%% the MTU; the others dropped, by reason.
burst(Frames, #process{mtu = Mtu} = T) ->
    {Drops, Kept} = lists:foldr(fun(Frame, {D, K}) when not is_binary(Frame) ->
                                        {[{dropped, malformed} | D], K};
                                   (Frame, {D, K}) when byte_size(Frame) > Mtu + ?ETHER_HDR_LEN ->
                                        {[{dropped, too_long} | D], K};
                                   (Frame, {D, K}) ->
                                        {D, [received(Frame, T) | K]}
                                end, {[], []}, Frames),
    Drops ++ [{frames, Kept} || Kept =/= []].

%% In the offload mode a frame comes with its network sum, as from a medium whose copy sums.
received(<<_:?ETHER_HDR_LEN/binary, Above/binary>> = Frame, #process{offload = true}) ->
    {sum, erx_bytes:inet_csum(0, Above), Frame};
received(Frame, #process{}) ->
    Frame.

-doc false.
transmit({_Zone, _Packet}, T) ->
    {{drop, malformed}, T};
transmit({csum, _Start, _Field, Bytes} = Frame, #process{offload = true} = T) ->
    case erx_net_frame:finishable(Frame, iolist_size(Bytes)) of
        true -> transmit(erx_net_frame:finish(Frame), T);
        false -> {{drop, malformed}, T}
    end;
transmit({csum, _Start, _Field, _Bytes}, T) ->
    {{drop, malformed}, T};
transmit(Frame, T) ->
    case iolist_size(Frame) =< mtu(T) + ?ETHER_HDR_LEN of
        true -> send(Frame, T);
        false -> {{drop, too_long}, T}
    end.

send(Frame, #udp{socket = Socket, peer = {Ip, Port}} = T) ->
    case gen_udp:send(Socket, Ip, Port, Frame) of
        ok -> {ok, T};
        {error, _} -> {{drop, refused}, T}
    end;
send(_Frame, #process{pid = undefined} = T) ->
    {{drop, refused}, T};
send(Frame, #process{pid = Pid} = T) ->
    Pid ! {erx_net_pipe, self(), iolist_to_binary(Frame)},
    {ok, T}.

mtu(#udp{mtu = Mtu}) -> Mtu;
mtu(#process{mtu = Mtu}) -> Mtu.
