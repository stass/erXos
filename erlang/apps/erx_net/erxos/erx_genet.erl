%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet).
-moduledoc """
erXos's transport (docs/design-network-stack.md, "The driver") for the Raspberry Pi 4's
Ethernet controller, GENET v5, over the device NIF, erx_device
(docs/design-runtime.md, "The device NIF"), with the controller's register ring
(docs/design-device-dma.md, "The register ring (GENET)"): queue 0 receives and queue 1
transmits, 256 buffers each as long as the largest frame (erx_genet_core:buffer/0).
Built only into erXos's images. Its decisions are erx_genet_core's, its receive
judgement erx_genet_rx's, its PHY erx_phy_c22's over
erx_mdio; this module carries them out.

`init/1` runs one sequence at a start and at every restart, so a restarted driver finds
the controller as its predecessor left it and resets it: open the record, check the
revision, read the address the firmware left before the reset, create the two queues,
then erx_genet_core:reset/0: the MAC's receive and transmit off, both DMA directions
stopped and confirmed by erx_device:stop_register_ring/1, which needs both queues' records, the
receive buffer's reset and the MAC's, the largest frame and the buffers' settings,
and the settings read back (erx_genet_core:buffer_check/0);
set the port, the address, the promiscuous filter and the ring settings,
`negotiate/2`, which installs both rings and starts them, hold the MAC in software reset
with receive and transmit off and unmask the interrupts (erx_genet_core:start/0), and bind
the line. Nothing flushes the transmit path or the receive buffer (erx_genet_core).
erx_device:stop_register_ring/1 and `negotiate/2` are each retried every millisecond while they
answer `ebusy`, within erx_genet_core:stop_retry/1's bound, after which the device is
not driven. The PHY
starts at the driver's first message to itself, so every PHY result, a failure at the
reset included, comes through `event/2`.

* **Link information.** The address of erx_genet_core:lladdr/1; an MTU of 1,500; the link
  `down` until the PHY reports it up; the transmit ring's size as `tx_limit`; `finish`
  `none`, since no checksum offload is enabled.
* **The PHY** is a BCM54213PE at MDIO address 1 (the board's device tree; the board pass
  confirms it). Each request of erx_phy_c22 is carried out at once: an MDIO operation
  polls the command register at most erx_mdio's bound, 10 us apart, and a pause is a
  timer message. A link up holds the MAC, sets its speed, then releases it and enables
  receive and transmit (erx_genet_core:link_up/1), and reports `{link, up}`; a link down reports
  `{link, down}`; a PHY failure ends the driver, which its supervisor restarts, resetting
  the PHY too.
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
* **A broken queue**, an index the device NIF refuses, or a completion that
  does not match what is in flight, ends the driver with `{stop, {broken, Direction}}`, never
  a crash: one line names the bound a receive queue met as the controller's registers show
  it (erx_genet_core:rx_fault/1) and one line gives each register of
  erx_genet_core:evidence/0, then the driver's restart resets the controller. A stop
  that never shows, in erx_device:stop_register_ring/1 or `negotiate/2`, logs the same registers before
  the device is given up.

Every register goes by its name in hw/svd/genet/genet.svd. The design places the device
in the network domain; on Fiasco, whichever domain the manifest gives the record
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
-define(BUFFER, erx_genet_core:buffer()).
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

%% The record, open, identify, the address, the two queues, reset and configure,
%% negotiate, start, attach and the PHY, in that order; each step's refusal stops the
%% sequence. A line in the kernel log names each phase before it runs, and the log is
%% written synchronously, so when a register access ends the domain by a synchronous fault
%% the last such line names its phase. An asynchronous error (an SError on AArch64) may be
%% taken only at a later kernel entry, such as the next phase line, so for one the fault
%% lies in the last phase named or the one before it. Each register read of identify and
%% the address has a line of its own before it and after it (read_logged/3).
start(Spec) ->
    maybe
        ok = log_phase(open),
        {ok, Dev} ?= erx_step:step(open, erx_device:open(Spec)),
        ok = log_phase(identify),
        ok ?= erx_genet_core:identify(read_logged(Dev, sys_rev_ctrl, major)),
        ok = log_phase(address),
        Lladdr = address(Dev, erx_genet_core:lladdr(maps:get(mac, Spec, none))),
        ok = log_phase(queue_rx),
        {ok, Rx} ?= erx_step:step(queue_create,
                                  erx_device:queue_create(Dev, ?RXQ, ?QUEUE_SIZE, ?BUFFER)),
        ok = log_phase(queue_tx),
        {ok, Tx} ?= erx_step:step(queue_create,
                                  erx_device:queue_create(Dev, ?TXQ, ?QUEUE_SIZE, ?BUFFER)),
        ok = log_phase(reset),
        ok ?= apply_steps(Dev, erx_genet_core:reset()),
        ok ?= check_buffers(Dev),
        ok = log_phase(configure),
        ok = apply_steps(Dev, erx_genet_core:configure(Lladdr)),
        ok = log_phase(negotiate),
        {ok, _Features} ?= retry_busy(negotiate, fun() -> erx_device:negotiate(Dev, 0) end, Dev),
        ok = log_phase(hold),
        ok = apply_steps(Dev, erx_genet_core:start()),
        ok = log_phase(attach),
        {ok, Irq} ?= erx_step:step(attach, erx_irq_line:attach(Dev, ?IRQ_LINE)),
        {Phy, Request} = erx_phy_c22:start(),
        self() ! {?MODULE, phy_begin},
        T = #t{dev = Dev, irq = Irq, rx = Rx, tx = Tx, phy = Phy, phy_first = Request},
        {ok, #{link => ethernet, lladdr => Lladdr, mtu => ?MTU, state => down,
               tx_limit => ?QUEUE_SIZE, finish => none}, T}
    end.

%% Carries out erx_genet_core:lladdr/1's steps, before the reset: its reads and its draw.
address(_Dev, {done, Address}) -> Address;
address(Dev, {read, Register, Field, Next}) -> address(Dev, Next(read_logged(Dev, Register, Field)));
address(Dev, {entropy, Next}) -> address(Dev, Next(erx_net_clock:entropy(6))).

%% A read of the start, with a line in the kernel log before it naming the field and one
%% after it giving the value, so the last line before a fault in the read names its field.
read_logged(Dev, Register, Field) ->
    ok = log("read ~w ~s", [Register, Field]),
    Value = erx_device:read_field(Dev, Register, Field),
    ok = log("~w ~s = 16#~.16b", [Register, Field, Value]),
    Value.

%% Calls `Call`, erx_device:stop_register_ring/1 or negotiate/2, both of which answer ebusy until
%% both DMA engines show the stop, again while it answers ebusy, within
%% erx_genet_core:stop_retry/1's bound, and returns its success, `ok` or `{ok, Features}`.
%% A stop that never shows logs the evidence and is `{error, {Name, stop_timeout}}`; any
%% other refusal is `{error, {Name, Reason}}`.
retry_busy(Name, Call, Dev) ->
    retry_busy(Name, Call, Dev, 1).

retry_busy(Name, Call, Dev, Tries) ->
    case Call() of
        ok ->
            ok;
        {ok, Features} ->
            {ok, Features};
        {error, ebusy} ->
            case erx_genet_core:stop_retry(Tries) of
                {retry, Ms} -> timer:sleep(Ms), retry_busy(Name, Call, Dev, Tries + 1);
                {error, Reason} ->
                    ok = log_evidence(read_evidence(Dev)),
                    {error, {Name, Reason}}
            end;
        {error, Reason} ->
            {error, {Name, Reason}}
    end.

log_phase(Name) -> log("phase ~s", [Name]).

%% Carries out erx_genet_core's steps in order, to the end or to the first refusal, which
%% only a `dma_stop` makes.
apply_steps(_Dev, []) ->
    ok;
apply_steps(Dev, [Step | Rest]) ->
    case apply_step(Dev, Step) of
        ok -> apply_steps(Dev, Rest);
        {error, _} = Refused -> Refused
    end.

apply_step(Dev, {write, Register, Value}) -> ok = erx_device:write(Dev, Register, Value);
apply_step(Dev, {field, Register, Field, Value}) -> ok = erx_device:write_field(Dev, Register, Field, Value);
apply_step(_Dev, {wait_us, Us}) -> spin_us(Us);
apply_step(Dev, dma_stop) -> retry_busy(dma_stop, fun() -> erx_device:stop_register_ring(Dev) end, Dev).

%% Each buffer setting reset/0 wrote, read back after it; any that reads
%% otherwise fails the start, named with its register, field and the value read
%% (erx_genet_core:buffer_check/0).
check_buffers(Dev) ->
    Lost = [{Register, Field, Read} || {Register, Field, Value} <- erx_genet_core:buffer_check(),
                                       Read <- [erx_device:read_field(Dev, Register, Field)],
                                       Read =/= Value],
    case Lost of
        [] -> ok;
        _ -> log("buffer settings lost in the reset: ~0p", [Lost]), {error, {buffer_settings_lost, Lost}}
    end.

%% A pause spun, as FreeBSD's DELAY, not slept on a timer: the scheduler is held for at
%% most erx_mdio's bound on one operation, about 10 ms, 2 ms for the frame the reset lets
%% pass, and 10 us at the other reset steps.
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

%% A broken queue, thrown from wherever a call answers it, ends the driver here with its
%% evidence logged.
-doc false.
event(Msg, T) ->
    try transport_event(Msg, T)
    catch throw:{broken, Direction} -> {stop, log_broken(Direction, T)}
    end.

transport_event({erx_irq, Dev, ?IRQ_LINE}, #t{dev = Dev} = T0) ->
    %% Clear the controller's pending interrupts, then answer the line, before draining,
    %% so a completion that lands after the drain fires the line again.
    ok = erx_device:write(Dev, intrl2_cpu_clear, erx_device:read(Dev, intrl2_cpu_stat)),
    ok = erx_irq_line:ack(T0#t.irq),
    {Writable, T1} = reclaim(T0),
    {Received, T} = receive_batch(T1),
    {Writable ++ Received, T};
transport_event({?MODULE, more}, T) ->
    receive_batch(T);
transport_event({?MODULE, phy_begin}, T0) ->
    case phy(T0#t.phy_first, T0) of
        {ok, Events, T} -> {Events, T};
        {error, Reason} -> {stop, Reason}
    end;
transport_event({?MODULE, phy}, #t{phy = Phy0} = T0) ->
    {Phy, Next, Reports} = erx_phy_c22:step(Phy0, ok),
    maybe
        {ok, Events, T1} ?= reports(Reports, T0#t{phy = Phy}, []),
        {ok, More, T} ?= phy(Next, T1),
        {Events ++ More, T}
    else
        {error, Reason} -> {stop, Reason}
    end;
transport_event({?MODULE, broken, Direction}, _T) ->
    throw({broken, Direction});
transport_event(_Msg, T) ->
    {[], T}.

%% The reason a broken queue ends the driver with, after its lines in the kernel log: the
%% evidence's registers read once, the receive fault judged from those words, then the
%% words logged.
log_broken(rx, #t{dev = Dev}) ->
    Evidence = read_evidence(Dev),
    log("the receive queue is broken: ~0p", [erx_genet_core:rx_fault(Evidence)]),
    ok = log_evidence(Evidence),
    {broken, rx};
log_broken(tx, #t{dev = Dev}) ->
    log("the transmit queue is broken", []),
    ok = log_evidence(read_evidence(Dev)),
    {broken, tx}.

read_evidence(Dev) ->
    [{Reg, erx_device:read(Dev, Reg)} || Reg <- erx_genet_core:evidence()].

%% One line for each register of the evidence, its whole word.
log_evidence(Evidence) ->
    lists:foreach(fun({Reg, Word}) -> log("~0p = 16#~.16b", [Reg, Word]) end, Evidence).

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
reclaimed({error, broken}, _Dev, _Tx, _N) -> throw({broken, tx}).

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
            take(T, [Done | Got], Bytes + lists:sum([byte_size(B) || {_Status, B} <- Done]),
                 Count + length(Done));
        {error, broken} ->
            throw({broken, rx})
    end;
take(_T, Got, _Bytes, _Count) ->
    {lists:append(lists:reverse(Got)), true}.

%% A post the device NIF answers broken asks the driver, by a message to itself, to end
%% through event/2, and holds the frame meanwhile as `full`.
-doc false.
transmit(Frame, T) ->
    try transmit_frame(Frame, T)
    catch throw:{broken, tx} -> self() ! {?MODULE, broken, tx}, {full, T}
    end.

transmit_frame({_Zone, _Packet}, T) ->
    {{drop, malformed}, T};
%% Its finish is none: a delayed frame or a run is a shape it does not take.
transmit_frame({csum, _Start, _Field, _Frame}, T) ->
    {{drop, malformed}, T};
transmit_frame(#run{}, T) ->
    {{drop, malformed}, T};
transmit_frame(Frame, T) ->
    case iolist_size(Frame) of
        Size when Size > ?MTU + ?ETHER_HDR_LEN -> {{drop, too_long}, T};
        Size when Size < ?ETHER_HDR_LEN -> {{drop, malformed}, T};
        _ -> post(erx_genet_core:pieces(Frame), T)
    end.

post(Pieces, #t{dev = Dev, tx = Tx, tag = Tag} = T) ->
    case erx_device:post(Dev, Tx, Tag, Pieces) of
        ok -> {ok, T#t{tag = (Tag + 1) band 16#ffffffffffffffff}};
        {error, full} -> {full, T#t{tx_full = true}};
        {error, broken} -> throw({broken, tx})
    end.

%% One line of the kernel log. Every value in it is an integer or a fixed atom of this
%% transport's, erx_device's or the PHY machine's, never text the device wrote.
log(Format, Arguments) ->
    _ = erx_log:debug(["erx_genet: ", io_lib:format(Format, Arguments)]),
    ok.
