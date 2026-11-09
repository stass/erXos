%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_virtio_net).
-moduledoc """
erXos's transport (docs/design-network-stack.md, "The driver"): a virtio-mmio network
device (section 5.1 of the virtio specification) over the device NIF, erx_device
(docs/design-runtime.md, "The device NIF"). Built only into erXos's images.

`init/1` runs one sequence at a start and at every restart, so a restarted driver finds
the device as its predecessor left it and resets it: open the record, check the
transport's magic, version and device id, create the receive and transmit queues,
`negotiate/2`, which resets the device and returns every buffer it held, bind the line,
read the configuration, and post a receive buffer in every entry of the receive queue.

* **Link information.** The device's address when it offers `VIRTIO_NET_F_MAC`, else a
  random locally administered unicast address drawn with `erx_net_clock:entropy/1`
  (section 5.1.5); its `mtu` when it offers `VIRTIO_NET_F_MTU`, at most 1,500, the
  frames the receive buffers hold, else 1,500; its link bit when it offers
  `VIRTIO_NET_F_STATUS`, read again at each configuration-change interrupt, else `up`;
  the transmit queue's size as `tx_limit`.
* **Receiving.** At each interrupt the receive queue's completions are taken until
  64 KiB are copied, one `frames` batch, and a buffer is posted again for each. A batch
  that reached 64 KiB leaves the rest for a message to itself, so the interface runs
  between batches. Each completion is a 12-byte `virtio_net_hdr` and a frame: one shorter
  than the header and an Ethernet header is dropped as `malformed`, one longer than the
  MTU and the Ethernet header as `too_long`. No other byte the device wrote is read.
* **Transmitting.** Each frame is posted as one request of at most four `out` segments:
  a zero `virtio_net_hdr`, then the frame's own binaries, all but the last two joined into
  the first when there are more than three, so a payload of one or two binaries is not
  joined in Erlang.
  A frame longer than the MTU and its Ethernet header is dropped as `too_long`, and a
  loopback frame, which names a zone, as `malformed`. A full queue is `full`; the
  interrupt that returns transmit entries is the `writable` event.
* **A broken queue**, a completion that does not match what is in flight, ends the
  driver: its restart resets the device, as the design's restart of a driver does.

The system domain drives the device in Phase 1, which is the stopgap placement: the
design places it in the network domain.
""".

-behaviour(erx_net_driver).

-export([interfaces/0]).
-export([init/1, event/2, transmit/2]).

-include("generated/erx_abi.hrl").

-define(RXQ, ?ERX_VIRTIO_NET_QUEUE_RX).
-define(TXQ, ?ERX_VIRTIO_NET_QUEUE_TX).
-define(QUEUE_SIZE, 64).
-define(IRQ_LINE, 0).
-define(HDR, ?ERX_VIRTIO_NET_HDR_SIZE).
-define(ETHER_HDR_LEN, 14).
-define(MAX_MTU, 1500).
-define(MIN_MTU, 68).
%% Every buffer of both queues holds a header and the largest frame the MTU allows.
-define(BUFFER, (?HDR + ?ETHER_HDR_LEN + ?MAX_MTU)).
-define(BATCH_BYTES, 65536).
-define(MAX_OUT, 4).
%% A frame's own segments after the device header, and how many of its last binaries
%% segments/1 posts as segments of their own, after the one that joins the rest.
-define(FRAME_SEGMENTS, (?MAX_OUT - 1)).
-define(OWN_SEGMENTS, (?FRAME_SEGMENTS - 1)).
-define(GENERATION_TRIES, 4).
-define(WANTED, ((1 bsl ?ERX_VIRTIO_NET_F_MAC) bor (1 bsl ?ERX_VIRTIO_NET_F_MTU)
                 bor (1 bsl ?ERX_VIRTIO_NET_F_STATUS))).
%% The names interfaces/0 gives the devices it finds, in record order, as FreeBSD names
%% its vtnet(4) devices. A record past the last name is left undriven.
-define(NAMES, [vtnet0, vtnet1, vtnet2, vtnet3]).

-record(t, {dev :: erx_device:device(), rx :: erx_device:queue(), tx :: erx_device:queue(),
            features :: non_neg_integer(), mtu :: pos_integer(),
            tag = 0 :: non_neg_integer(),     % the next request's tag, of either queue
            tx_full = false :: boolean()}).   % transmit/2 last answered full

%% --- The interfaces --------------------------------------------------------------

-doc """
One interface for each network device record, configured for DHCP: the value of the
`interfaces` key on erXos. No record gives none, and so does a record the reader
refuses, with one line in the kernel log. Whether a device is behind a record's
transport is `init/1`'s to find.
""".
-spec interfaces() -> [map()].
interfaces() ->
    case erx_device_record:find(net, virtio_mmio) of
        {ok, Specs} ->
            [#{name => Name, transport => {?MODULE, #{record => Spec}}, ip4 => dhcp}
             || {Name, Spec} <- lists:zip(?NAMES, Specs, trim)];
        {error, {bad_device_record, _Text}} ->
            log("the network device record is malformed", []),
            []
    end.

%% --- The transport ---------------------------------------------------------------

%% A device this transport cannot drive is no interface, not a fault: init/1 answers
%% ignore, so its link starts nothing and the stack starts without it, as erx_blk does
%% without a disk. An empty transport, a machine without the device, has no line, as an
%% absent device's probe prints nothing on FreeBSD; any other refusal, an exception of
%% the sequence included, has one.
-doc false.
init(#{record := Spec}) ->
    case try start(Spec) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, Info, T} ->
            log("virtio-mmio, mtu ~b, link ~s", [maps:get(mtu, Info), maps:get(state, Info)]),
            {ok, Info, T};
        %% Device id 0 is an empty transport: virtio's name for no device.
        {error, {device_id, 0}} ->
            ignore;
        {error, Reason} ->
            log("the network device is not driven: ~0p", [Reason]),
            ignore
    end.

%% The record, open, identify, the two queues, negotiate, irq_bind, the configuration
%% and the receive buffers, in that order; each step's refusal stops the sequence.
start(Spec) ->
    maybe
        {ok, Dev} ?= step(open, erx_device:open(Spec)),
        ok ?= identify(Dev),
        {ok, Rx} ?= step(queue_create, erx_device:queue_create(Dev, ?RXQ, ?QUEUE_SIZE, ?BUFFER)),
        {ok, Tx} ?= step(queue_create, erx_device:queue_create(Dev, ?TXQ, ?QUEUE_SIZE, ?BUFFER)),
        {ok, Features} ?= step(negotiate, erx_device:negotiate(Dev, ?WANTED)),
        ok ?= step(irq_bind, erx_device:irq_bind(Dev, ?IRQ_LINE)),
        {ok, Words} ?= config(Dev, ?GENERATION_TRIES),
        {ok, Mtu} ?= mtu(Features, Words),
        T0 = #t{dev = Dev, rx = Rx, tx = Tx, features = Features, mtu = Mtu},
        {ok, T} ?= refill(?QUEUE_SIZE, T0),
        {ok, #{link => ethernet, lladdr => lladdr(Features, Words), mtu => Mtu,
               state => link_state(Features, Words), tx_limit => ?QUEUE_SIZE}, T}
    end.

identify(Dev) ->
    case {erx_device:read(Dev, magic), erx_device:read(Dev, version), erx_device:read(Dev, device_id)} of
        {?ERX_VIRTIO_MMIO_MAGIC, ?ERX_VIRTIO_MMIO_VERSION, ?ERX_VIRTIO_ID_NET} -> ok;
        {?ERX_VIRTIO_MMIO_MAGIC, ?ERX_VIRTIO_MMIO_VERSION, Other} -> {error, {device_id, Other}};
        {?ERX_VIRTIO_MMIO_MAGIC, Version, _} -> {error, {version, Version}};
        {Magic, _, _} -> {error, {magic, Magic}}
    end.

%% The configuration's three words, read between two equal reads of the configuration
%% generation, so they come from one configuration (section 4.2.2.2).
config(_Dev, 0) ->
    {error, {config, unstable}};
config(Dev, Tries) ->
    Before = erx_device:read(Dev, config_generation),
    Words = [erx_device:read(Dev, {config, Index})
             || Index <- [?ERX_VIRTIO_NET_CONFIG_MAC_LOW, ?ERX_VIRTIO_NET_CONFIG_MAC_HIGH_STATUS,
                          ?ERX_VIRTIO_NET_CONFIG_PAIRS_MTU]],
    case erx_device:read(Dev, config_generation) of
        Before -> {ok, Words};
        _Changed -> config(Dev, Tries - 1)
    end.

offers(Features, Bit) -> Features band (1 bsl Bit) =/= 0.

lladdr(Features, [Low, High, _]) ->
    case offers(Features, ?ERX_VIRTIO_NET_F_MAC) of
        true -> <<Low:32/little, (High band 16#ffff):16/little>>;
        false -> local_unicast(erx_net_clock:entropy(6))
    end.

%% A random address with the locally administered bit set and the group bit clear.
local_unicast(<<High:6, _:2, Rest:40>>) -> <<High:6, 1:1, 0:1, Rest:40>>.

mtu(Features, [_, _, PairsMtu]) ->
    case offers(Features, ?ERX_VIRTIO_NET_F_MTU) of
        true ->
            case PairsMtu bsr 16 of
                Mtu when Mtu < ?MIN_MTU -> {error, {mtu, Mtu}};
                Mtu -> {ok, min(Mtu, ?MAX_MTU)}
            end;
        false ->
            {ok, ?MAX_MTU}
    end.

link_state(Features, [_, High, _]) ->
    case offers(Features, ?ERX_VIRTIO_NET_F_STATUS) of
        true when (High bsr 16) band ?ERX_VIRTIO_NET_S_LINK_UP =/= 0 -> up;
        true -> down;
        false -> up
    end.

step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

%% Posts N empty receive buffers.
refill(0, T) ->
    {ok, T};
refill(N, #t{dev = Dev, rx = Rx, tag = Tag} = T) ->
    case erx_device:post(Dev, Rx, Tag, [{in, ?BUFFER}]) of
        ok -> refill(N - 1, next_tag(T));
        {error, full} -> {ok, T};
        {error, Reason} -> {error, {post, Reason}}
    end.

next_tag(#t{tag = Tag} = T) -> T#t{tag = (Tag + 1) band 16#ffffffffffffffff}.

-doc false.
event({erx_irq, Dev, ?IRQ_LINE}, #t{dev = Dev} = T0) ->
    %% Acknowledge the device's interrupt, then unmask the line, before draining, so a
    %% completion that lands after the drain fires the line again.
    Status = erx_device:read(Dev, interrupt_status),
    ok = erx_device:write(Dev, interrupt_ack, Status band 3),
    ok = erx_device:irq_ack(Dev, ?IRQ_LINE),
    Link = [{link, State} || Status band 2 =/= 0, {ok, Words} <- [config(Dev, ?GENERATION_TRIES)],
                             State <- [link_state(T0#t.features, Words)]],
    {Writable, T1} = reclaim(T0),
    {Received, T} = receive_batch(T1),
    {Link ++ Writable ++ Received, T};
event({?MODULE, more}, T0) ->
    {Received, T} = receive_batch(T0),
    {Received, T};
event(_Msg, T) ->
    {[], T}.

%% Takes the transmit queue's completions, which carry no bytes; room after a `full`
%% answer is the `writable` event.
reclaim(#t{dev = Dev, tx = Tx} = T) ->
    case reclaimed(erx_device:complete(Dev, Tx), Dev, Tx, 0) of
        0 -> {[], T};
        _ when T#t.tx_full -> {[writable], T#t{tx_full = false}};
        _ -> {[], T}
    end.

reclaimed({ok, []}, _Dev, _Tx, N) -> N;
reclaimed({ok, Done}, Dev, Tx, N) -> reclaimed(erx_device:complete(Dev, Tx), Dev, Tx, N + length(Done));
reclaimed({error, broken}, _Dev, _Tx, _N) -> error({virtio_net, broken, tx}).

%% One batch: the receive queue's completions until 64 KiB, each made a frame or a drop,
%% and a buffer posted again for each.
receive_batch(T0) ->
    {Completions, More} = take(T0, [], 0),
    [self() ! {?MODULE, more} || More],
    {ok, T} = refill(length(Completions), T0),
    {Drops, Frames} = lists:foldr(fun(Bytes, Acc) -> frame(Bytes, T#t.mtu, Acc) end, {[], []}, Completions),
    {Drops ++ [{frames, Frames} || Frames =/= []], T}.

take(#t{dev = Dev, rx = Rx} = T, Got, Bytes) when Bytes < ?BATCH_BYTES ->
    case erx_device:complete(Dev, Rx) of
        {ok, []} ->
            {lists:append(lists:reverse(Got)), false};
        {ok, Done} ->
            Taken = [B || {_Tag, B} <- Done],
            take(T, [Taken | Got], Bytes + lists:sum([byte_size(B) || B <- Taken]));
        {error, broken} ->
            error({virtio_net, broken, rx})
    end;
take(_T, Got, _Bytes) ->
    {lists:append(lists:reverse(Got)), true}.

frame(<<_Header:?HDR/binary, Frame/binary>>, Mtu, {Drops, Frames}) when byte_size(Frame) >= ?ETHER_HDR_LEN ->
    case byte_size(Frame) =< Mtu + ?ETHER_HDR_LEN of
        true -> {Drops, [Frame | Frames]};
        false -> {[{dropped, too_long} | Drops], Frames}
    end;
frame(_Short, _Mtu, {Drops, Frames}) ->
    {[{dropped, malformed} | Drops], Frames}.

-doc false.
transmit({_Zone, _Packet}, T) ->
    {{drop, malformed}, T};
transmit(Frame, #t{mtu = Mtu} = T) ->
    case iolist_size(Frame) of
        Size when Size > Mtu + ?ETHER_HDR_LEN -> {{drop, too_long}, T};
        Size when Size < ?ETHER_HDR_LEN -> {{drop, malformed}, T};
        _ -> post(segments(Frame), T)
    end.

post(Segments, #t{dev = Dev, tx = Tx, tag = Tag} = T) ->
    case erx_device:post(Dev, Tx, Tag, [{out, <<0:(?HDR * 8)>>} | Segments]) of
        ok -> {ok, next_tag(T)};
        {error, full} -> {full, T#t{tx_full = true}};
        {error, broken} -> error({virtio_net, broken, tx})
    end.

%% The frame's segments after the device header (docs/design-network-stack.md, "The
%% driver"): its non-empty binaries in order, or, when it has more than FRAME_SEGMENTS,
%% all but its last OWN_SEGMENTS joined into the first. A frame of headers and a payload
%% of one or two binaries so posts its payload without a join in Erlang; the device NIF
%% copies every segment into its pool buffer.
segments(Frame) ->
    case leaves(Frame) of
        Leaves when length(Leaves) =< ?FRAME_SEGMENTS ->
            [{out, B} || B <- Leaves];
        Leaves ->
            {Joined, Own} = lists:split(length(Leaves) - ?OWN_SEGMENTS, Leaves),
            [{out, iolist_to_binary(Joined)} | [{out, B} || B <- Own]]
    end.

%% The binaries of an iodata term in order, a byte of a list as a binary of its own, an
%% empty binary as none.
leaves(<<>>) -> [];
leaves(B) when is_binary(B) -> [B];
leaves(Byte) when is_integer(Byte) -> [<<Byte>>];
leaves([]) -> [];
leaves([Head | Tail]) -> leaves(Head) ++ leaves(Tail).

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% transport's or erx_device's, never text the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_virtio_net: ", io_lib:format(Format, Arguments)]),
    ok.
