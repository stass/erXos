%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_genet_core).
-moduledoc """
The Raspberry Pi 4 Ethernet controller's transport, erx_genet, as pure decisions
(docs/design-device-dma.md, "The register ring (GENET)"; docs/design-network-stack.md,
"The driver"): the register sequences it writes, the address it uses, how long it
retries `negotiate/2`, and what it makes of each receive completion and each frame to
send. Nothing here touches the device; erx_genet carries each step out through the
device NIF, which reaches every register and field by its name in the device's SVD
source (hw/svd/genet/genet.svd), so no step packs a bit by hand.

The sequences follow FreeBSD 975e3605ebb1, `sys/arm64/broadcom/genet/if_genet.c`:

1. `reset/0`, FreeBSD's `gen_reset` (`if_genet.c:488-514`): pulse the receive buffer's
   reset, write it 0, write the MAC's command register 0, hold the MAC in software
   reset with local loopback for 10 us, write it 0 again, which leaves CRC forward
   clear, so no frame check sequence is counted in a receive length, and clear the
   MIB counters. FreeBSD sets loopback and reset in one write; here they are two field
   writes, loopback first (unverified on the board).
2. `configure/1`, the part of `gen_init_locked` before the rings
   (`if_genet.c:915-927`, `gen_set_enaddr` `:1016-1035`, `gen_setup_rxfilter`
   `:977-1013`): the port in external gigabit PHY mode, the unicast address, and the
   filter promiscuous with the MDF table off, as plan 1b-I (c) begins. Then the part of
   `gen_init_txring` and `gen_init_rxring` that is the driver's, not the NIF's
   (hw/svd/genet/genet.svd; docs/design-device-dma.md, "GENET"): both directions'
   burst size, and ring 16's transmit done threshold, transmit flow period and receive
   XON/XOFF thresholds, written before `negotiate/2` enables the ring and the engine.
   FreeBSD writes them after it has stopped the engine (`if_genet.c:286-288, 873-875`);
   here the engine is first stopped inside `negotiate/2`, so they are written with it
   in whatever state the firmware or a previous driver left (TODO.md).
3. `negotiate/2` installs and starts both rings (the device NIF's sequence).
4. `start/0`: every interrupt masked and cleared first, as FreeBSD's `gen_disable_intr`
   does (`if_genet.c:538-544`), so no completion's interrupt is cleared after it lands;
   then `gen_enable` (`if_genet.c:516-536`, `gen_enable_intr` `:710-715`): the largest
   frame 1,536 bytes, the receive buffer's 2-byte alignment on and both status blocks
   off, the transmit buffer size, transmit and receive enabled, and the receive and
   transmit done interrupts unmasked.
5. `link_up/1` at each `{link, up, Speed}` of erx_phy_c22, `gen_update_link_locked`
   (`if_genet.c:1729-1781`): the RGMII out-of-band control on, its link bit set and
   ID mode left enabled, since the board's PHY is wired `rgmii-rxid` (the PHY delays
   the receive clock, erx_phy_c22), then the command register's speed. A link down
   writes nothing, as in FreeBSD.
""".

-export([identify/1, lladdr/3, reset/0, configure/1, start/0, link_up/1]).
-export([negotiate_retry/1, frames/2, pieces/1]).
-export_type([step/0, controller_mac/0]).

-include("generated/erx_abi.hrl").

-define(REV_MAJOR_V5, 6).
-define(PORT_MODE_EXT_GPHY, 3).
-define(MAX_FRAME_LEN, 1536).
-define(TBUF_SIZE, 1).
-define(ALL_IRQS, 16#ffffffff).
%% The ring the device NIF drives, FreeBSD's default queue (if_genetreg.h:118).
-define(RING, ?ERX_GENET_RING).
%% The ring settings FreeBSD writes at start (if_genet.c:738, 752-753, 784, 798-799),
%% taken as its values: no source read gives their units or meaning beyond the
%% register names (hw/svd/genet/genet.svd).
-define(SCB_BURST_SIZE, 8).
-define(TX_MBUF_DONE_THRES, 1).
-define(TX_FLOW_PERIOD, 0).
-define(RX_XON_XOFF_LO, 5).
%% FreeBSD's RX_DESC_COUNT >> 4: the ring's receive descriptors, 256 in FreeBSD as
%% here (if_genet.c:89, if_genetreg.h:116), over 16.
-define(RX_XON_XOFF_HI, (?ERX_GENET_RING_SIZE bsr 4)).
-define(RESET_US, 10).
%% An Ethernet header: destination, source and type.
-define(ETHER_HDR_LEN, 14).
%% The device NIF's limit on a transmit post's pieces.
-define(MAX_PIECES, ?ERX_GENET_PIECES_MAX).
-define(OWN_PIECES, (?MAX_PIECES - 1)).
%% The shortest frame on the wire without its FCS (IEEE 802.3's 64 bytes less 4).
-define(MIN_FRAME, 60).
%% negotiate/2 answers ebusy until both directions' DMA shows the stop. The one published
%% bound on a stop is 5,000 reads 1 us apart, about 5 ms (docs/design-device-dma.md,
%% "Stopping"); erx_genet retries every millisecond for four times that, then fails.
-define(NEGOTIATE_RETRY_MS, 1).
-define(NEGOTIATE_TRIES, 20).

-doc """
One effect on the controller: a whole register written, one named field written (a
read, the field replaced, a write, except on a one-to-clear field, which is one write),
or a pause of that many microseconds. A register is named as erx_device names it: an
atom, or `{Name, Element}` for one element of an array such as a ring's registers.
""".
-type step() :: {write, erx_device:register_name(), 0..16#ffffffff}
              | {field, erx_device:register_name(), atom(), non_neg_integer()}
              | {wait_us, pos_integer()}.

-doc """
The controller's address registers as read before the reset: whether the receive
buffer's reset bit read set, in which case they mean nothing (`if_genet.c:465-469`),
and the two words.
""".
-type controller_mac() :: #{flush_reset := boolean(), mac0 := 0..16#ffffffff, mac1 := 0..16#ffff}.

%% --- Identification and the address -----------------------------------------------

-doc "Whether the revision register's major field names GENET v5, the Pi 4's (`if_genet.c:264-268`).".
-spec identify(non_neg_integer()) -> ok | {error, {revision, non_neg_integer()}}.
identify(?REV_MAJOR_V5) -> ok;
identify(Major) when is_integer(Major), Major >= 0 -> {error, {revision, Major}}.

-doc """
The interface's address, in FreeBSD's order (`gen_get_eaddr`, `if_genet.c:446-485`):
the device tree's, which the device record carries as `mac`; else the one the firmware
left in the controller, MAC0 holding the first four bytes and MAC1's low half the last
two, unless the receive buffer's reset was set or both words are 0; else a random
locally administered unicast address from `Entropy`, six bytes. An address from the
record or the controller that is a group address or all zeros is not used.
""".
-spec lladdr(none | 1..16#ffffffffffff, controller_mac(), <<_:48>>) -> <<_:48>>.
lladdr(Record, Controller, <<_:48>> = Entropy) ->
    Candidates = [<<Mac:48>> || is_integer(Record), Mac <- [Record]]
                 ++ controller_address(Controller),
    case [Address || Address <- Candidates, unicast(Address)] of
        [Address | _] -> Address;
        [] -> local_unicast(Entropy)
    end.

controller_address(#{flush_reset := true}) -> [];
controller_address(#{flush_reset := false, mac0 := Mac0, mac1 := Mac1}) ->
    [<<Mac0:32, Mac1:16>>].

unicast(<<0:48>>) -> false;
unicast(<<_:7, Group:1, _:40>>) -> Group =:= 0.

%% A random address with the locally administered bit set and the group bit clear.
local_unicast(<<High:6, _:2, Rest:40>>) -> <<High:6, 1:1, 0:1, Rest:40>>.

%% --- The sequences ------------------------------------------------------------------

-doc "The reset, FreeBSD's `gen_reset`.".
-spec reset() -> [step()].
reset() ->
    [{field, sys_rbuf_flush_ctrl, reset, 1}, {wait_us, ?RESET_US},
     {field, sys_rbuf_flush_ctrl, reset, 0}, {wait_us, ?RESET_US},
     {write, sys_rbuf_flush_ctrl, 0}, {wait_us, ?RESET_US},
     {write, umac_cmd, 0},
     {field, umac_cmd, lcl_loop_en, 1}, {field, umac_cmd, sw_reset, 1}, {wait_us, ?RESET_US},
     {write, umac_cmd, 0},
     {field, umac_mib_ctrl, reset_runt, 1}, {field, umac_mib_ctrl, reset_rx, 1},
     {field, umac_mib_ctrl, reset_tx, 1}, {write, umac_mib_ctrl, 0}].

-doc """
The port, the address `Lladdr`, the promiscuous filter and the driver's ring settings,
before the rings.
""".
-spec configure(<<_:48>>) -> [step()].
configure(<<Mac0:32, Mac1:16>>) ->
    [{field, sys_port_ctrl, mode, ?PORT_MODE_EXT_GPHY},
     {field, umac_mac0, addr, Mac0}, {field, umac_mac1, addr, Mac1},
     {field, umac_cmd, promisc, 1}, {write, umac_mdf_ctrl, 0}]
        ++ ring_settings().

%% gen_init_txring's (if_genet.c:738, 752-753), then gen_init_rxring's (:784, 798-799).
ring_settings() ->
    [{write, tx_scb_burst_size, ?SCB_BURST_SIZE},
     {write, {tx_ring_mbuf_done_thres, ?RING}, ?TX_MBUF_DONE_THRES},
     {write, {tx_ring_flow_period, ?RING}, ?TX_FLOW_PERIOD},
     {write, rx_scb_burst_size, ?SCB_BURST_SIZE},
     {field, {rx_ring_xon_xoff_thres, ?RING}, lo, ?RX_XON_XOFF_LO},
     {field, {rx_ring_xon_xoff_thres, ?RING}, hi, ?RX_XON_XOFF_HI}].

-doc "The MAC's enables and the interrupts, after the rings.".
-spec start() -> [step()].
start() ->
    [{write, intrl2_cpu_set_mask, ?ALL_IRQS}, {write, intrl2_cpu_clear, ?ALL_IRQS},
     {field, umac_max_frame_len, length, ?MAX_FRAME_LEN},
     {field, rbuf_ctrl, status_64b, 0}, {field, rbuf_ctrl, align_2b, 1},
     {field, tbuf_ctrl, status_64b, 0},
     {field, rbuf_tbuf_size_ctrl, size, ?TBUF_SIZE},
     {field, umac_cmd, txen, 1}, {field, umac_cmd, rxen, 1},
     {field, intrl2_cpu_clear_mask, rxdma_done, 1}, {field, intrl2_cpu_clear_mask, txdma_done, 1}].

-doc "The MAC set for a link up at `Speed` Mb/s.".
-spec link_up(10 | 100 | 1000) -> [step()].
link_up(Speed) ->
    [{field, ext_rgmii_oob_ctrl, oob_disable, 0}, {field, ext_rgmii_oob_ctrl, rgmii_link, 1},
     {field, ext_rgmii_oob_ctrl, rgmii_mode_en, 1}, {field, ext_rgmii_oob_ctrl, id_mode_disable, 0},
     {field, umac_cmd, speed, speed_code(Speed)}].

%% The command register's speed field (if_genetreg.h:80-83).
speed_code(10) -> 0;
speed_code(100) -> 1;
speed_code(1000) -> 2.

-doc """
What to do after the `Tries`-th `negotiate/2` answered `{error, ebusy}`: wait that many
milliseconds and try again, or give up.
""".
-spec negotiate_retry(pos_integer()) -> {retry, pos_integer()} | {error, stop_timeout}.
negotiate_retry(Tries) when is_integer(Tries), Tries >= 1, Tries < ?NEGOTIATE_TRIES ->
    {retry, ?NEGOTIATE_RETRY_MS};
negotiate_retry(Tries) when is_integer(Tries), Tries >= ?NEGOTIATE_TRIES ->
    {error, stop_timeout}.

%% --- Frames ---------------------------------------------------------------------------

-doc """
The cut of a batch of receive completions into its drops and its frames, in order. Each
completion is the device NIF's `{Flags, Bytes}`, which erx_genet_rx:frame/2 judges: the
descriptor status's bits below its length field and the bytes the controller wrote, as
many as its length field said, the 2-byte alignment pad first. Both are untrusted. Its
drops pass through, and a frame longer than the MTU and its Ethernet header is dropped
as `too_long` as well.
""".
-spec frames([{erx_genet_rx:flags(), binary()}], pos_integer()) ->
          {[{dropped, erx_genet_rx:drop()}], [binary()]}.
frames(Completions, Mtu) ->
    lists:foldr(fun(Completion, Acc) -> frame(Completion, Mtu, Acc) end, {[], []}, Completions).

frame({Flags, Bytes}, Mtu, {Drops, Frames}) ->
    case erx_genet_rx:frame(Flags, Bytes) of
        {frame, Frame} when byte_size(Frame) =< Mtu + ?ETHER_HDR_LEN -> {Drops, [Frame | Frames]};
        {frame, _Long} -> {[{dropped, too_long} | Drops], Frames};
        {drop, Reason} -> {[{dropped, Reason} | Drops], Frames}
    end.

-doc """
A frame's pieces for a transmit post: its non-empty binaries in order, a frame shorter
than 60 bytes padded with zeros to 60, since whether and with what the controller pads
a short frame is unknown and a buffer it pads from may hold an earlier frame's bytes;
or, when it has
more than the device NIF takes, all but the last three joined into the first, so a frame
of headers and a payload of one or two binaries goes out with no join in Erlang.
""".
-spec pieces(iodata()) -> [{out, binary()}].
pieces(Frame) ->
    case leaves([Frame | pad(iolist_size(Frame))]) of
        Leaves when length(Leaves) =< ?MAX_PIECES ->
            [{out, B} || B <- Leaves];
        Leaves ->
            {Joined, Own} = lists:split(length(Leaves) - ?OWN_PIECES, Leaves),
            [{out, iolist_to_binary(Joined)} | [{out, B} || B <- Own]]
    end.

pad(Size) when Size < ?MIN_FRAME -> [<<0:((?MIN_FRAME - Size) * 8)>>];
pad(_Size) -> [].

%% The binaries of an iodata term in order, a byte of a list as a binary of its own, an
%% empty binary as none.
leaves(<<>>) -> [];
leaves(B) when is_binary(B) -> [B];
leaves(Byte) when is_integer(Byte) -> [<<Byte>>];
leaves([]) -> [];
leaves([Head | Tail]) -> leaves(Head) ++ leaves(Tail).
