%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet).
-moduledoc """
erXos's transport (docs/design-network-stack.md, "The driver") for the Raspberry Pi 4's
Ethernet controller, GENET v5, over the device NIF, erx_device
(docs/design-runtime.md, "The device NIF"), with the controller's register ring
(docs/design-device-dma.md, "The register ring (GENET)"): queue 0 receives and queue 1
transmits, 256 buffers of 2 KiB each. Built only into erXos's images. Its decisions are
erx_genet_core's, its receive judgement erx_genet_rx's, its PHY erx_phy_c22's over
erx_mdio; this module carries them out.

`init/1` runs one sequence at a start and at every restart, so a restarted driver finds
the controller as its predecessor left it and resets it: open the record, check the
revision, read the address the firmware left before the reset, reset the MAC, set the
port, the address and the promiscuous filter, create the two queues, `negotiate/2`,
which stops both DMA directions, installs both rings and starts them (retried every
millisecond while it answers `ebusy`, within erx_genet_core's bound, after which the
device is not driven), enable the MAC and the interrupts, and bind the line. The PHY
starts at the driver's first message to itself, so every PHY result, a failure at the
reset included, comes through `event/2`.

* **Link information.** The address of erx_genet_core:lladdr/3; an MTU of 1,500; the link
  `down` until the PHY reports it up; the transmit ring's size as `tx_limit`; `finish`
  `none`, since no checksum offload is enabled.
* **The PHY** is a BCM54213PE at MDIO address 1 (the board's device tree; the board pass
  confirms it). Each request of erx_phy_c22 is carried out at once: an MDIO operation
  polls the command register at most erx_mdio's bound, 10 us apart, and a pause is a
  timer message. A link up sets the MAC's speed (erx_genet_core:link_up/1) and reports
  `{link, up}`; a link down reports `{link, down}`; a PHY failure ends the driver, which
  its supervisor restarts, resetting the PHY too.
* **Receiving.** At each interrupt the receive queue's completions are taken until
  64 KiB are copied, one `frames` batch; a batch that reached 64 KiB leaves the rest for a
  message to itself. The device NIF hands every buffer back itself, whether or not the
  frame is good, so nothing is posted here. Each completion is cut by
  erx_genet_core:frames/2.
* **Transmitting.** Each frame is posted as at most four pieces
  (erx_genet_core:pieces/1). A frame longer than the MTU and its Ethernet header is
  dropped as `too_long`, one shorter than an Ethernet header, a loopback frame, a delayed
  frame and a run as `malformed`. A full ring is `full`; the interrupt that returns
  transmit buffers is the `writable` event.
* **A broken queue**, a completion that does not match what is in flight, ends the
  driver: its restart resets the controller.

Every register goes by its name in hw/svd/genet/genet.svd. The design places the device
in the network domain; on the stopgap, whichever domain the manifest gives the record
drives it.
""".

-behaviour(erx_net_driver).

-export([interfaces/0]).
-export([init/1, event/2, transmit/2]).
-export([device/1]).

-include("generated/erx_abi.hrl").
-include("erx_net_frame.hrl").

-define(RXQ, 0).
-define(TXQ, 1).
-define(QUEUE_SIZE, ?ERX_GENET_RING_SIZE).
-define(BUFFER, 2048).
-define(IRQ_LINE, 0).
-define(PHY_ADDRESS, 1).
-define(ETHER_HDR_LEN, 14).
-define(MTU, 1500).
-define(BATCH_BYTES, 65536).
%% The names interfaces/0 gives the devices it finds, in record order, as FreeBSD names its
%% genet(4) devices. The Pi 4 has one.
-define(NAMES, [genet0]).

-record(t, {dev :: erx_device:device(), irq :: erx_irq_line:handle(),
            rx :: erx_device:queue(), tx :: erx_device:queue(),
            phy :: erx_phy_c22:state(),
            phy_first :: erx_phy_c22:request(), % the machine's first request, made at phy_begin
            tag = 0 :: non_neg_integer(),     % the next transmit post's tag
            tx_full = false :: boolean()}).   % transmit/2 last answered full

%% --- The interfaces ---------------------------------------------------------------

-doc """
One interface for each GENET record, configured for DHCP: the value of the `interfaces`
key on erXos for the Pi 4. No record gives none, and so does a record the reader refuses,
with one line in the kernel log.
""".
-spec interfaces() -> [map()].
interfaces() ->
    case erx_device_record:find(net, genet) of
        {ok, Specs} ->
            [#{name => Name, transport => {?MODULE, #{record => Spec}}, ip4 => dhcp}
             || {Name, Spec} <- lists:zip(?NAMES, Specs, trim)];
        {error, {bad_device_record, _Text}} ->
            log("the network device record is malformed", []),
            []
    end.

-doc """
The device of a transport state that `erx_net_driver:transport_state/1` gave, for tests
that drive a stand-in's engine (test/fixtures/erx_genet_hosted_run.erl).
""".
-spec device(term()) -> erx_device:device().
device(#t{dev = Dev}) -> Dev.

%% --- The transport ----------------------------------------------------------------

%% A controller this transport cannot drive is no interface, not a fault: init/1 answers
%% ignore with one line in the kernel log, so its link starts nothing and the stack starts
%% without it.
-doc false.
init(#{record := Spec}) ->
    case try start(Spec) catch Class:Raised -> {error, {Class, Raised}} end of
        {ok, Info, T} ->
            log("GENET v5, mtu ~b", [?MTU]),
            {ok, Info, T};
        {error, Reason} ->
            log("the network device is not driven: ~0p", [Reason]),
            ignore
    end.

%% The record, open, identify, the address, reset and configure, the two queues,
%% negotiate, start, attach and the PHY, in that order; each step's refusal stops the
%% sequence.
start(Spec) ->
    maybe
        {ok, Dev} ?= step(open, erx_device:open(Spec)),
        ok ?= erx_genet_core:identify(erx_device:read_field(Dev, sys_rev_ctrl, major)),
        Lladdr = erx_genet_core:lladdr(maps:get(mac, Spec, none), controller_mac(Dev),
                                       erx_net_clock:entropy(6)),
        ok = apply_steps(Dev, erx_genet_core:reset() ++ erx_genet_core:configure(Lladdr)),
        {ok, Rx} ?= step(queue_create, erx_device:queue_create(Dev, ?RXQ, ?QUEUE_SIZE, ?BUFFER)),
        {ok, Tx} ?= step(queue_create, erx_device:queue_create(Dev, ?TXQ, ?QUEUE_SIZE, ?BUFFER)),
        ok ?= negotiate(Dev, 1),
        ok = apply_steps(Dev, erx_genet_core:start()),
        {ok, Irq} ?= step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        {Phy, Request} = erx_phy_c22:start(),
        self() ! {?MODULE, phy_begin},
        T = #t{dev = Dev, irq = Irq, rx = Rx, tx = Tx, phy = Phy, phy_first = Request},
        {ok, #{link => ethernet, lladdr => Lladdr, mtu => ?MTU, state => down,
               tx_limit => ?QUEUE_SIZE, finish => none}, T}
    end.

%% The address registers, read before the reset, with whether the receive buffer's reset
%% held them meaningless.
controller_mac(Dev) ->
    #{flush_reset => erx_device:read_field(Dev, sys_rbuf_flush_ctrl, reset) =/= 0,
      mac0 => erx_device:read_field(Dev, umac_mac0, addr),
      mac1 => erx_device:read_field(Dev, umac_mac1, addr)}.

negotiate(Dev, Tries) ->
    case erx_device:negotiate(Dev, 0) of
        {ok, _Features} ->
            ok;
        {error, ebusy} ->
            case erx_genet_core:negotiate_retry(Tries) of
                {retry, Ms} -> timer:sleep(Ms), negotiate(Dev, Tries + 1);
                {error, Reason} -> {error, {negotiate, Reason}}
            end;
        {error, Reason} ->
            {error, {negotiate, Reason}}
    end.

step(_Name, ok) -> ok;
step(_Name, {ok, Value}) -> {ok, Value};
step(Name, {error, Reason}) -> {error, {Name, Reason}}.

%% Carries out erx_genet_core's steps in order.
apply_steps(Dev, Steps) ->
    lists:foreach(fun(Step) -> apply_step(Dev, Step) end, Steps).

apply_step(Dev, {write, Register, Value}) -> ok = erx_device:write(Dev, Register, Value);
apply_step(Dev, {field, Register, Field, Value}) -> ok = erx_device:write_field(Dev, Register, Field, Value);
apply_step(_Dev, {wait_us, Us}) -> spin_us(Us).

%% A pause shorter than a timer's millisecond, as FreeBSD's DELAY: the scheduler is held
%% for at most erx_mdio's bound on one operation, about 10 ms, and 10 us at a reset step.
spin_us(Us) ->
    spin_until(erlang:monotonic_time(microsecond) + Us).

spin_until(Deadline) ->
    case erlang:monotonic_time(microsecond) >= Deadline of
        true -> ok;
        false -> spin_until(Deadline)
    end.

%% --- The PHY --------------------------------------------------------------------------

%% Carries out PHY requests until one is a pause or the machine stops: the pause's timer
%% is armed, and the reports come back as transport events, or a failure as an error.
phy({wait, Ms}, T) ->
    _ = erlang:send_after(Ms, self(), {?MODULE, phy}),
    {ok, [], T};
phy(stop, T) ->
    {ok, [], T};
phy(Request, #t{phy = Phy0} = T0) ->
    {Phy, Next, Reports} = erx_phy_c22:step(Phy0, mdio(T0#t.dev, Request)),
    case reports(Reports, T0#t{phy = Phy}, []) of
        {ok, Events, T1} ->
            case phy(Next, T1) of
                {ok, More, T} -> {ok, Events ++ More, T};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

reports([], T, Events) ->
    {ok, lists:reverse(Events), T};
reports([{link, up, Speed} | Rest], T, Events) ->
    ok = apply_steps(T#t.dev, erx_genet_core:link_up(Speed)),
    log("link up, ~b Mb/s full duplex", [Speed]),
    reports(Rest, T, [{link, up} | Events]);
reports([{link, down} | Rest], T, Events) ->
    log("link down", []),
    reports(Rest, T, [{link, down} | Events]);
reports([{failed, Reason} | _], _T, _Events) ->
    {error, {phy, Reason}}.

%% One clause 22 operation through the MDIO command register: the command, then the start,
%% then polls until erx_mdio answers anything but wait.
mdio(Dev, {read, Reg}) -> mdio_op(Dev, {read, ?PHY_ADDRESS, Reg});
mdio(Dev, {write, Reg, Value}) -> mdio_op(Dev, {write, ?PHY_ADDRESS, Reg, Value}).

mdio_op(Dev, Op) ->
    Command = erx_mdio:command(Op),
    ok = erx_device:write(Dev, mdio_cmd, Command),
    ok = erx_device:write(Dev, mdio_cmd, erx_mdio:start(Command)),
    mdio_poll(Dev, Op, 1).

mdio_poll(Dev, Op, Polls) ->
    case erx_mdio:poll(Op, erx_device:read(Dev, mdio_cmd), Polls) of
        {wait, Next} -> spin_us(erx_mdio:poll_interval_us()), mdio_poll(Dev, Op, Next);
        Result -> Result
    end.

%% --- Events ---------------------------------------------------------------------------

-doc false.
event({erx_irq, Dev, ?IRQ_LINE}, #t{dev = Dev} = T0) ->
    %% Clear the controller's pending interrupts, then answer the line, before draining,
    %% so a completion that lands after the drain fires the line again.
    ok = erx_device:write(Dev, intrl2_cpu_clear, erx_device:read(Dev, intrl2_cpu_stat)),
    ok = erx_irq_line:ack(T0#t.irq),
    {Writable, T1} = reclaim(T0),
    {Received, T} = receive_batch(T1),
    {Writable ++ Received, T};
event({?MODULE, more}, T) ->
    receive_batch(T);
event({?MODULE, phy_begin}, T0) ->
    case phy(T0#t.phy_first, T0) of
        {ok, Events, T} -> {Events, T};
        {error, Reason} -> {stop, Reason}
    end;
event({?MODULE, phy}, #t{phy = Phy0} = T0) ->
    {Phy, Next, Reports} = erx_phy_c22:step(Phy0, ok),
    maybe
        {ok, Events, T1} ?= reports(Reports, T0#t{phy = Phy}, []),
        {ok, More, T} ?= phy(Next, T1),
        {Events ++ More, T}
    else
        {error, Reason} -> {stop, Reason}
    end;
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
reclaimed({error, broken}, _Dev, _Tx, _N) -> error({genet, broken, tx}).

%% One batch: the receive queue's completions until 64 KiB or a ring's worth, whichever
%% comes first, each made a frame or a drop. The count bounds a batch of empty
%% completions, which copy no bytes.
receive_batch(T) ->
    {Completions, More} = take(T, [], 0, 0),
    [self() ! {?MODULE, more} || More],
    {Drops, Frames} = erx_genet_core:frames(Completions, ?MTU),
    {Drops ++ [{frames, Frames} || Frames =/= []], T}.

take(#t{dev = Dev, rx = Rx} = T, Got, Bytes, Count) when Bytes < ?BATCH_BYTES, Count < ?QUEUE_SIZE ->
    case erx_device:complete(Dev, Rx) of
        {ok, []} ->
            {lists:append(lists:reverse(Got)), false};
        {ok, Done} ->
            take(T, [Done | Got], Bytes + lists:sum([byte_size(B) || {_Flags, B} <- Done]),
                 Count + length(Done));
        {error, broken} ->
            error({genet, broken, rx})
    end;
take(_T, Got, _Bytes, _Count) ->
    {lists:append(lists:reverse(Got)), true}.

-doc false.
transmit({_Zone, _Packet}, T) ->
    {{drop, malformed}, T};
%% Its finish is none: a delayed frame or a run is a shape it does not take.
transmit({csum, _Start, _Field, _Frame}, T) ->
    {{drop, malformed}, T};
transmit(#run{}, T) ->
    {{drop, malformed}, T};
transmit(Frame, T) ->
    case iolist_size(Frame) of
        Size when Size > ?MTU + ?ETHER_HDR_LEN -> {{drop, too_long}, T};
        Size when Size < ?ETHER_HDR_LEN -> {{drop, malformed}, T};
        _ -> post(erx_genet_core:pieces(Frame), T)
    end.

post(Pieces, #t{dev = Dev, tx = Tx, tag = Tag} = T) ->
    case erx_device:post(Dev, Tx, Tag, Pieces) of
        ok -> {ok, T#t{tag = (Tag + 1) band 16#ffffffffffffffff}};
        {error, full} -> {full, T#t{tx_full = true}};
        {error, broken} -> error({genet, broken, tx})
    end.

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% transport's, erx_device's or the PHY machine's, never text the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_genet: ", io_lib:format(Format, Arguments)]),
    ok.
