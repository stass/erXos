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
* `{process, Pid}`, a test: each frame is a message `{erx_net_pipe, Pid, Frame}` in either
  direction; a `Frame` that is not a binary is dropped as `malformed` (a type check, not a
  parse), and one from another pid as `stranger`. The pipe monitors the far end and
  reports the link `down` when it ends.
* `{port, Device}`, a tap device through the tap helper `erx_net_tap`, a port program in
  this application's `priv/` (built by `make -C c_src`) that relays whole frames between
  the device and the port, each port message one frame. `port_command/2` suspends the
  driver while the port is busy, so the helper's input is the transmit backlog. The pipe
  monitors the port. A helper that fails closes its output and reads its input until the
  port has closed, so the port closes with reason normal and does not fail under a frame
  it is writing (with epipe, which would end the driver linked to it); only a helper
  killed by a signal can still end the driver that way. The link is `up`
  from `init` until the port closes, and `down` for good after: later frames are dropped
  as `refused`, and the link returns only when the driver is started again.

The configuration: `far`; `lladdr`, which must be a unicast address with the locally
administered bit set; `mtu`, from 1,280 to 9,000 (1,500 when absent); and `tx_limit`, the
frames that may wait at the driver (256 when absent).
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
             | {port, Device :: file:filename()}
             | {process, pid()}.

-record(udp, {socket :: gen_udp:socket(), peer :: {inet:ip_address(), inet:port_number()},
              mtu :: pos_integer()}).
-record(port, {port :: port(), ref :: reference(), up = true :: boolean(), mtu :: pos_integer()}).
-record(process, {pid :: pid(), ref :: reference(), up = true :: boolean(),
                  mtu :: pos_integer()}).

-doc false.
init(#{far := Far, lladdr := Lladdr} = Config) ->
    Mtu = maps:get(mtu, Config, ?MTU_DEFAULT),
    Limit = maps:get(tx_limit, Config, ?TX_LIMIT_DEFAULT),
    maybe
        ok ?= check(lladdr, Lladdr, is_local_unicast(Lladdr)),
        ok ?= check(mtu, Mtu, is_integer(Mtu) andalso Mtu >= 1280 andalso Mtu =< 9000),
        ok ?= check(tx_limit, Limit, is_integer(Limit) andalso Limit > 0),
        {ok, T} ?= open(Far, Mtu),
        {ok, #{link => ethernet, lladdr => Lladdr, mtu => Mtu, state => up, tx_limit => Limit}, T}
    end.

check(_Key, _Value, true) -> ok;
check(Key, Value, false) -> {error, {Key, Value}}.

%% Unicast (the group bit clear) and locally administered (the next bit set).
is_local_unicast(<<_:6, 1:1, 0:1, _:40>>) -> true;
is_local_unicast(_) -> false.

open({udp, {LocalIp, LocalPort}, {_, _} = Peer}, Mtu) ->
    case gen_udp:open(LocalPort, [binary, {ip, LocalIp}, {active, ?ACTIVE}]) of
        {ok, Socket} -> {ok, #udp{socket = Socket, peer = Peer, mtu = Mtu}};
        {error, Reason} -> {error, {udp, Reason}}
    end;
open({port, Device}, Mtu) when is_list(Device); is_binary(Device) ->
    case code:priv_dir(erx_net) of
        {error, Reason} ->
            {error, {port, {priv_dir, Reason}}};
        Priv ->
            Helper = filename:join(Priv, "erx_net_tap"),
            try open_port({spawn_executable, Helper}, [{args, [Device]}, {packet, 2}, binary]) of
                Port ->
                    %% Without exit_status the port closes, with reason normal, as soon
                    %% as the helper closes its standard output; the monitor's 'DOWN'
                    %% says so. The link closes the port when the driver ends.
                    {ok, #port{port = Port, ref = erlang:monitor(port, Port), mtu = Mtu}}
            catch
                error:Reason -> {error, {port, Reason}}
            end
    end;
open({process, Pid}, Mtu) when is_pid(Pid) ->
    {ok, #process{pid = Pid, ref = erlang:monitor(process, Pid), mtu = Mtu}};
open(Far, _Mtu) ->
    {error, {far, Far}}.

-doc false.
event({udp, Socket, Ip, Port, Data}, #udp{socket = Socket} = T) ->
    {datagrams([{Ip, Port, Data}], byte_size(Data), T), T};
event({udp_passive, Socket}, #udp{socket = Socket} = T) ->
    ok = inet:setopts(Socket, [{active, ?ACTIVE}]),
    {[], T};
event({Port, {data, Frame}}, #port{port = Port, mtu = Mtu} = T) ->
    case byte_size(Frame) =< Mtu + ?ETHER_HDR_LEN of
        true -> {[{frames, [Frame]}], T};
        false -> {[{dropped, too_long}], T}
    end;
event({'DOWN', Ref, port, _, _}, #port{ref = Ref} = T) ->
    {[{link, down}], T#port{up = false}};
event({erx_net_pipe, Pid, Frame}, #process{pid = Pid, mtu = Mtu} = T) when is_binary(Frame) ->
    case byte_size(Frame) =< Mtu + ?ETHER_HDR_LEN of
        true -> {[{frames, [Frame]}], T};
        false -> {[{dropped, too_long}], T}
    end;
event({erx_net_pipe, Pid, _}, #process{pid = Pid} = T) ->
    {[{dropped, malformed}], T};
event({erx_net_pipe, _, _}, #process{} = T) ->
    {[{dropped, stranger}], T};
event({'DOWN', Ref, process, _, _}, #process{ref = Ref} = T) ->
    {[{link, down}], T#process{up = false}};
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

-doc false.
transmit({_Zone, _Packet}, T) ->
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
send(_Frame, #port{up = false} = T) ->
    {{drop, refused}, T};
send(Frame, #port{port = Port} = T) ->
    %% The port may have closed with its 'DOWN' still on its way; port_command/2 then
    %% fails with badarg.
    try port_command(Port, Frame) of
        true -> {ok, T}
    catch
        error:badarg -> {{drop, refused}, T}
    end;
send(_Frame, #process{up = false} = T) ->
    {{drop, refused}, T};
send(Frame, #process{pid = Pid} = T) ->
    Pid ! {erx_net_pipe, self(), iolist_to_binary(Frame)},
    {ok, T}.

mtu(#udp{mtu = Mtu}) -> Mtu;
mtu(#port{mtu = Mtu}) -> Mtu;
mtu(#process{mtu = Mtu}) -> Mtu.
