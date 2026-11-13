# The Raspberry Pi 4's Ethernet controller (GENET v5): a clean-room facts record

A point-in-time record, written on 2026-11-12 on an Apple Silicon macOS
27.0.1 host, of what the published drivers for the BCM2711's GENET v5
Ethernet controller do when they stop its DMA engines, reset the MAC and
read a received frame's status. It is the "dirty room" half of a
clean-room process: its author read the GPL-licensed Linux driver and the
BSD-licensed FreeBSD driver and wrote down facts and working principles in
his own words, so that the team that writes erXos's driver can work from
this record alone and never sees the Linux source. The author of this
record writes no erXos code and no design text for this driver.

The record contains no code, no quoted comments, no identifiers coined by
the drivers beyond register names and bit meanings, and no tables in their
source form. Register offsets are given the way FreeBSD's `if_genetreg.h`
numbers them: from the RX DMA block base (0x2000) and the TX DMA block base
(0x4000), or from the controller base where a register lies outside those
blocks. Every fact cites the file and line range it came from; the sources
are listed with their hashes in [Sources](#sources).

It answers the questions of the DMA design's GENET reset step: which
register reports that each direction's DMA has stopped, how Linux stops
and confirms it, what the MAC reset and the buffer flushes do around it,
and how a received frame's status word says to drop it.

## Contents

1. [How to read this record](#how-to-read-this-record)
2. [Sources](#sources)
3. [Layout of a DMA block](#layout-of-a-dma-block)
4. [The DMA status register](#the-dma-status-register)
5. [Stopping the DMA and confirming it stopped](#stopping-the-dma-and-confirming-it-stopped)
6. [MAC reset, RX buffer flush and TX flush](#mac-reset-rx-buffer-flush-and-tx-flush)
7. [Reinstalling the rings](#reinstalling-the-rings)
8. [The receive status word](#the-receive-status-word)
9. [Where the drivers disagree](#where-the-drivers-disagree)
10. [What only the board can settle](#what-only-the-board-can-settle)

## How to read this record

Each fact carries a confidence tag:

* **[Both]**: stated by the code of both Linux and FreeBSD in the same way.
* **[Linux]**, **[FreeBSD]**: stated by that project's code only; the
  other was read and does not do it, or does it differently (noted).
* **[Inferred]**: the author's conclusion from the cited facts; no source
  states it.
* **[Board]**: the sources leave it open or contradict each other; a probe
  on the board must settle it.

Citations use short prefixes: `L` is Linux v6.18, with `L.c` for
`drivers/net/ethernet/broadcom/genet/bcmgenet.c`, `L.h` for
`drivers/net/ethernet/broadcom/genet/bcmgenet.h`, `L.mii` for
`drivers/net/ethernet/broadcom/genet/bcmmii.c` and `L.umac` for
`drivers/net/ethernet/broadcom/unimac.h`; `F.c` is FreeBSD's
`sys/arm64/broadcom/genet/if_genet.c` and `F.h` its `if_genetreg.h`, at
FreeBSD commit `975e3605ebb1`. Each is followed by a line or line range.

No Broadcom documentation for GENET is public; nothing here rests on one.
Where a bit's meaning is known only from a register-field name in a
driver header, the record says so.

## Sources

Read on 2026-11-12 as data; nothing in them was built or run.

* **Linux v6.18**, from `linux-6.18.tar.xz`, the tarball deps.lock pins as
  `linux-dts` (URL `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.tar.xz`,
  SHA-256 `9106a4605da9e31ff17659d958782b815f9591ab308d03b0ee21aad6c7dced4b`).
  The copy used had been fetched earlier from that URL over HTTPS into a
  scratch directory outside the tree; its SHA-256 was checked against the
  pin before use, and the four files below were extracted from it into
  `~/erxos-scratch/dirty-room/genet/src/`. License GPL-2.0.

  | Path | SHA-256 |
  |---|---|
  | `drivers/net/ethernet/broadcom/genet/bcmgenet.c` | `ce0bfc2a9456102d47ce1c2e7651577132b95fe8bf8bb408c78de4630ac702d0` |
  | `drivers/net/ethernet/broadcom/genet/bcmgenet.h` | `6c856295ec4b166b73f956e550e0ed752f99b15ac1e0df36675e7b0d1b65f334` |
  | `drivers/net/ethernet/broadcom/genet/bcmmii.c` | `a4c17427d48bfad30db9638d7c405962bc02e7e526bf41f43baf82d242914860` |
  | `drivers/net/ethernet/broadcom/unimac.h` | `13c3bee85802e8421f72b5890a146f82313f92af615f5248d517d8a12a01a1dd` |

* **FreeBSD 16.0-CURRENT at commit `975e3605ebb1`**, the network stack's
  pin ([design-network-stack.md](design-network-stack.md)), files of
  `sys/arm64/broadcom/genet/` from a copy made for this task. License
  BSD-2-Clause.

  | Path | SHA-256 |
  |---|---|
  | `sys/arm64/broadcom/genet/if_genet.c` | `fbf5c90dd089fa759e04dd0c72f97e688bfc97e2855d65011cf42d4511cfd459` |
  | `sys/arm64/broadcom/genet/if_genetreg.h` | `5af53d306f839dc4742a52201059bdeadc7a305bee77cf686b45e8df69035b6e` |

## Layout of a DMA block

* **[Both]** Each direction has a block: RX at controller offset 0x2000,
  TX at 0x4000 (`L.c` 3754-3755, `F.h` 123-124). Linux uses these values
  for GENET v4 and v5 alike: the v4 parameter set is the default and the
  BCM2711's revision register reports major 6, which Linux treats as v5
  (`L.c` 3768-3790); FreeBSD names major 6 as v5 (`F.h` 43).
* **[Both]** A block begins with 256 descriptors of 12 bytes (three 32-bit
  words) each, 0xC00 bytes in all (`L.h` 25, `L.c` 56-64 and 3756,
  `F.h` 116-117). After them come 17 per-ring register sets of 0x40 bytes
  (rings 0 to 16, 0x440 bytes), and after those the block's common
  registers, so the common registers start at block offset
  0xC00 + 0x440 = 0x1040 (`L.h` 28 and 365-366, `L.c` 314-341,
  `F.h` 116-126 and 209-219).
* **[Both]** The common registers, from block offset 0x1040: ring
  configuration at 0x1040, DMA control at 0x1044, DMA status at 0x1048,
  bus burst size at 0x104C (`L.c` 216-220, `F.h` 209-219; FreeBSD does not
  define the status register). For the TX block only, the arbiter control
  is at 0x106C and three priority registers at 0x1070, 0x1074 and 0x1078
  (`L.c` 221-224); in the RX block the same offsets hold per-ring timeout
  registers (`L.c` 225-241). The two uses of 0x106C onward are
  direction-specific; Linux writes the arbiter and priorities only through
  the TX block (`L.c` 2906-2921). **[Linux]**
* **[Both]** DMA control: bit 0 enables the block's DMA; bits 1 to 17
  enable rings 0 to 16, ring *n* at bit *n* + 1 (`L.h` 397-399,
  `F.h` 211-212 and 217-218). Bit 20 is named as a status-block byte-swap
  enable (`L.h` 400); neither driver sets it. **[Linux]**
* **[Both]** The ring configuration register has one bit per ring, ring
  *n* at bit *n*, which marks the ring as a descriptor ring (`L.c`
  2924-2925 and 2992-2993, `F.c` 757 and 803).
* **[Both]** Per-ring registers on v4 and v5, from the ring set's start
  (ring set *n* at block offset 0xC00 + 0x40 × *n*): 0x00 and 0x04 the
  hardware's own pointer, low and high word (RX: write pointer; TX: read
  pointer); 0x08 the index the hardware advances (RX: producer; TX:
  consumer); 0x0C the index software advances (RX: consumer; TX:
  producer); 0x10 ring size (descriptor count in bits 31:16, buffer length
  in bits 15:0); 0x14 and 0x18 start, low and high; 0x1C and 0x20 end, low
  and high; 0x24 the TX done threshold; 0x28 TX flow period or RX XON/XOFF
  thresholds; 0x2C and 0x30 the software's pointer, low and high (RX: read
  pointer; TX: write pointer) (`L.c` 347-389, `F.h` 126-166).
* **[Both]** Start, end and the four pointers count 32-bit words into the
  descriptor area, not bytes: a ring of descriptors *s* to *e* − 1 has
  start 3*s* and end 3*e* − 1 (`L.c` 2740-2747 and 2792-2799,
  `F.c` 745-747 and 793-795).
* **[Linux]** On RX, the producer-index register carries a count of frames
  the hardware discarded in bits 31:16 beside the producer index in bits
  15:0; Linux clears the discard count by writing the register with 0
  (`L.h` 370-375, `L.c` 2319-2336).
* **[Linux]** Rings: GENET v5 as Linux sets it up has four TX priority
  rings plus a default ring and one RX ring (`L.c` 3742-3745). Linux uses
  rings 0 to 4 for TX and ring 0 for RX (`L.c` 2899-2929 and 2974-2997).
  **[FreeBSD]** uses ring 16 for both directions (`F.c` 833-836 and
  856-859, `F.h` 118).

## The DMA status register

* **[Linux]** Block offset 0x1048 in each direction: RX at controller
  offset 0x3048, TX at 0x5048 (`L.c` 216-220 and 314-341). FreeBSD does
  not define it and never reads it (`F.h` 209-219; no use in `F.c`).
* **[Linux]** Bit 0 reports the block's DMA disabled (`L.h` 403).
* **[Linux]** Bit 1 is named in the header as "descriptor RAM
  initialisation busy" (`L.h` 404); no code reads that name.
* **[Linux]** To confirm a stop, Linux builds a mask equal to the bits it
  just cleared in DMA control (bit 0 plus bit *n* + 1 for each ring it
  uses) and waits until every bit of that mask reads 1 in the status
  register (`L.c` 2843-2853 and 2866-2876). For GENET v5 that is bits 0
  to 5 on TX (rings 0 to 4) and bits 0 and 1 on RX (ring 0).
* **[Inferred]** The status register therefore mirrors the control
  register's layout: bit *n* + 1 reports ring *n* disabled, as bit 0
  reports the block disabled. No source states this; it follows from the
  poll succeeding on running hardware. It conflicts with the header's name
  for bit 1 (above), which Linux's RX poll also requires to read 1. See
  [What only the board can settle](#what-only-the-board-can-settle).
* **[Inferred]** For FreeBSD's ring 16, the matching status bit would be
  bit 17.

## Stopping the DMA and confirming it stopped

What Linux writes and polls, in order:

* **[Linux]** Stopping one direction: read DMA control, clear bit 0 and
  the enable bits of the rings in use in one write, then poll the status
  register for the same bits all set, once per microsecond, at most 5000
  times (`L.h` 425, `L.c` 2838-2882). The bound is therefore at least
  about 5 ms; on expiry the routine reports a timeout.
* **[Linux]** The two directions are stopped and confirmed separately,
  each with its own write and its own poll; TX always first (`L.c`
  3002-3022, 3052-3064).
* **[Linux]** On interface stop, the sequence is (`L.c` 3386-3416):
  1. stop queuing new frames to the transmit side;
  2. disable the hardware filter block (its control register written 0)
     and clear the MAC's receive enable, then sleep 1 to 2 ms, since the
     MAC stops on a frame boundary and a full-size frame must pass
     (`L.c` 2539-2561, 3393-3394);
  3. stop TX DMA and confirm it (above); a timeout is only warned about
     and the sequence continues (`L.c` 3006-3010);
  4. sleep 10 to 20 ms to let both directions drain (`L.c` 3012-3013);
  5. stop RX DMA and confirm it, again warning on timeout (`L.c`
     3015-3019);
  6. clear the MAC's transmit enable, which must follow the TX DMA stop
     (`L.c` 3401-3402), with the same 1 to 2 ms sleep;
  7. mask and clear all interrupts, then reclaim transmitted buffers and
     free the rings (`L.c` 3404-3415, 2576-2583).
* **[Linux]** The MAC enable/disable step is skipped while the MAC's
  software-reset bit is set (`L.c` 2544-2548).
* **[Linux]** Before installing rings (on open and on resume), Linux stops
  TX DMA then RX DMA, each confirmed, back to back with no sleep between;
  a timeout here aborts the bring-up with an error (`L.c` 3052-3064,
  3338-3342, 4249-4253).
* **[Linux]** TX can be stopped and reinstalled alone while RX keeps
  running: on resume from wake-on-LAN Linux stops only TX DMA, reinstalls
  the TX rings and re-enables TX DMA (`L.c` 4207-4211).
* **[FreeBSD]** FreeBSD clears DMA control's bit 0 and ring 16's enable on
  TX, then the same on RX, and does not poll or wait (`F.c` 594-607). On
  stop it first resets the MAC, then clears the MAC's receive and transmit
  enables, then stops the DMA (`F.c` 863-875); at attach it resets the MAC
  then stops the DMA (`F.c` 285-288).

## MAC reset, RX buffer flush and TX flush

The registers involved:

* **[Both]** UniMAC command register at controller offset 0x808 (UniMAC
  block at 0x800, register at 0x008): bit 0 transmit enable, bit 1
  receive enable, bit 6 CRC forward, bit 13 software reset, bit 15 local
  loopback (`L.umac` 10-28, `F.h` 75-90).
* **[Both]** UniMAC TX flush register at controller offset 0xB34
  (`L.umac` 64, `F.h` 96).
* **[Both]** RBUF flush control at controller offset 0x008, in the system
  block (`L.h` 329, `F.h` 49-50; Linux uses the system-block copy for
  every version but v1, `L.c` 123-137). Bit 1 is a reset (FreeBSD's name;
  Linux's comment names the field as the UniMAC software reset,
  `L.c` 2565). Bit 0 flushes the receive buffer (`L.c` 3071-3077; Linux
  uses it so, without a name). **[Linux]** for bit 0.

What Linux does, in order, when the interface opens (`L.c` 3306-3342):

* **[Linux]** Pulse RBUF flush control bit 1: set it, wait 10 µs, clear
  it, wait 10 µs (`L.c` 3254-3266, 3323).
* **[Linux]** Write RBUF flush control as 0 and wait 10 µs (working round
  a bad reset default on other chips), then write the UniMAC command
  register with only the software-reset bit set and wait 2 µs
  (`L.c` 2563-2574, 2613). This leaves the MAC held in reset with transmit
  and receive disabled. Linux also does this at probe (`L.c` 4081).
* **[Linux]** The MAC leaves reset only at link-up: the link handler,
  finding the reset bit set, writes the command register with it cleared,
  waits 2 µs, and writes it again with transmit and receive enabled
  (`L.mii` 79-91).
* **[Linux]** While the MAC is in reset, Linux clears the MIB counters,
  sets the maximum frame length, sets the TX buffer's 64-byte status-block
  enable, sets the RX buffer's 2-byte alignment and 64-byte status-block
  enables, sets receive checksumming, and masks and clears all interrupts
  (`L.c` 2615-2648).
* **[Linux]** Then, in the ring bring-up: stop and confirm TX DMA, stop
  and confirm RX DMA, write the TX flush register 1, wait 10 µs, write it
  0; then (on open, not on resume) pulse RBUF flush control bit 0 the same
  way, 10 µs each side (`L.c` 3052-3077).
* **[Inferred]** Linux does not rely on any of these resets or flushes to
  clear DMA registers: after them it rewrites every ring register it uses
  (next section). Whether the MAC reset or the flushes change DMA register
  contents is not stated by either driver.
* **[Inferred]** Linux issues the MAC reset at open and at probe without
  first stopping the DMA; it stops the DMA only later, before the flushes.
  The flushes, not the MAC reset, are what Linux places after a confirmed
  DMA stop.
* **[FreeBSD]** FreeBSD's reset: pulse RBUF flush control bit 1 (10 µs
  each side), write it 0 and wait 10 µs, write the command register 0,
  then software reset with local loopback, wait 10 µs, then 0 again
  (leaving the MAC out of reset, transmit and receive disabled), then clear
  the MIB counters (`F.c` 487-513). It never uses the TX flush register or
  RBUF flush bit 0.
* **[FreeBSD]** FreeBSD reads the MAC address registers only when RBUF
  flush control bit 1 reads clear (`F.c` 465-469). **[Inferred]** The MAC
  address registers are not meaningful while that reset is asserted.

## Reinstalling the rings

* **[Linux]** After the stop and flushes, for RX: write the burst size,
  then for each ring write producer and consumer index 0, ring size
  (count and 2048-byte buffer length), XON/XOFF thresholds, start, read
  pointer, write pointer (all three the ring's first word) and end; then
  write ring configuration with the ring bits and DMA control with the
  ring-enable bits only (bit 0 clear) (`L.c` 3107-3112, 2754-2800,
  2991-2997). Linux writes the producer index although the hardware
  advances it.
* **[Linux]** For TX: burst size, then for each ring producer and
  consumer index 0, done threshold 1, flow period (0 on ring 0, maximum
  frame size in bits 31:16 on the others), ring size, start, read pointer,
  write pointer and end; then arbiter, priorities, ring configuration and
  DMA control with ring-enable bits only (`L.c` 3121-3126, 2704-2747,
  2899-2929).
* **[Linux]** Last, set DMA control bit 0 on RX, then on TX (`L.c`
  3128-3135).
* **[Linux]** Linux never writes the high words of the per-ring pointers
  (offsets 0x04, 0x18, 0x20, 0x30). **[FreeBSD]** writes them all 0
  (`F.c` 739-755 and 785-801). **[Inferred]** These are word indices into
  on-chip descriptor memory, so the high words are expected to read 0;
  whether a reset clears them is not stated.
* **[Both]** Ring buffers are installed before DMA is enabled: Linux
  fills the RX descriptors during ring setup (`L.c` 2771-2773), FreeBSD
  just before enabling (`F.c` 805-813).

## The receive status word

Where the word comes from:

* **[Both]** With the RX buffer's 64-byte status-block enable set, the
  controller writes a 64-byte block at the start of each receive buffer;
  its first 32-bit word carries length and status in the same layout as
  the descriptor's status word (`L.h` 45-54, `L.c` 2355-2369, `F.h`
  195-202, `F.c` 1395-1399). Linux always sets that enable (`L.c`
  2629-2631) and reads the word from the buffer. FreeBSD sets it only when
  receive checksum offload is on and otherwise reads the status word of
  the descriptor in the controller (`F.c` 566-580, 1395-1400).

Bits of the word:

* **[Both]** Bits 31:16 the length; Linux takes all 16 bits (`L.c` 2369),
  FreeBSD masks 12 bits, 27:16 (`F.h` 169-171).
* **[Both]** Bit 14 end of packet, bit 13 start of packet (`L.h` 442-443,
  `F.h` 174-175).
* **[Both]** Bit 15 on received frames of v3 and later: checksum OK
  (`L.h` 453, `F.h` 173). Linux's receive path does not test it; FreeBSD
  takes it as a valid L4 checksum when the status block is on
  (`F.c` 1429-1435).
* **[Linux]** Bit 12 marks the ring's last descriptor (wrap) (`L.h` 444).
* **[Linux]** Bits 11:7 a filter index (5 bits) (`L.h` 462-463).
* **[Linux]** Bit 6 broadcast, bit 5 multicast (`L.h` 455-456; used only
  for counters, `L.c` 2438-2441).
* **[Linux]** Bit 4 oversize/length error, bit 3 non-octet-aligned frame,
  bit 2 receive error, bit 1 CRC error, bit 0 overflow (`L.h` 457-461).
  The meanings are from the header's short names and the counters Linux
  charges each to: length errors, frame errors, generic errors, CRC errors
  and overrun errors (`L.c` 2400-2413). The expansions of "LG", "NO" and
  "OV" are **[Inferred]**. FreeBSD names bit 2 a receive error
  (`F.h` 176) and no other error bit.

What drops a frame:

* **[Linux]** A frame is dropped and its buffer reused if the length
  exceeds 2048 (the programmed buffer length), if start or end of packet
  is clear (a frame spanning buffers), or if any of bits 4, 3, 2, 1 or 0
  is set (`L.c` 2376-2417).
* **[FreeBSD]** A frame is dropped if start or end of packet is clear or
  bit 2 is set; bits 0, 1, 3 and 4 are not checked, nor the length
  (`F.c` 1405-1414).
* **[Linux]** Either way the consumer index still advances past the
  dropped descriptor (`L.c` 2448-2456).

What the length counts:

* **[Linux]** The length includes the 64-byte status block and the 2-byte
  alignment pad: Linux removes 66 bytes from the front (`L.c` 2419-2423).
* **[Linux]** It includes the 4-byte FCS when the UniMAC forwards it (the
  command register's CRC-forward bit set): Linux then trims 4 bytes from
  the end (`L.c` 2425-2428). Linux learns the setting by reading the
  command register, not by setting it (`L.c` 805-807), and tells the RX
  checksum engine to skip the FCS when it is forwarded (`L.c` 2636-2643).
* **[FreeBSD]** Subtracts 64 only when the status block is on, then 2 for
  the pad if the length exceeds 2 (`F.c` 1429-1443); it never subtracts an
  FCS. FreeBSD's reset writes the command register 0 and never sets
  CRC forward (`F.c` 504-508), so **[Inferred]** the MAC strips the FCS
  under FreeBSD.
* **[Both]** The 2-byte pad comes from the RX buffer's 2-byte alignment
  enable, which both set (`L.c` 2630, `F.c` 523).

## Where the drivers disagree

* **Confirming the stop.** Linux polls the DMA status register for each
  direction, with a bound of about 5 ms; FreeBSD never reads it.
* **Order of MAC reset and DMA stop.** On stop, Linux disables MAC
  receive, stops TX DMA, drains 10 ms, stops RX DMA, then disables MAC
  transmit, and never resets the MAC on stop. FreeBSD resets the MAC
  first and stops the DMA last, unconfirmed.
* **Flushes.** Linux flushes the TX path (UniMAC TX flush) and the RX
  buffer (RBUF flush bit 0) after a confirmed DMA stop; FreeBSD does
  neither.
* **MAC reset state.** Linux leaves the MAC in software reset until
  link-up; FreeBSD releases it at once.
* **Rings.** Linux uses rings 0 to 4 (TX) and 0 (RX); FreeBSD ring 16 for
  both.
* **Drop rule.** Linux drops on any of five error bits and on length over
  2048; FreeBSD on bit 2 only.
* **FreeBSD's receive error path does not advance.** **[Inferred]** On a
  dropped frame, and on a failed buffer replacement, FreeBSD's receive
  loop continues without moving its ring index or writing the consumer
  index (`F.c` 1405-1426; the advance is at `F.c` 1459-1462). The same
  descriptor is examined again on every pass and the consumer index never
  moves past it, which would stall receive once one errored frame
  arrives. Linux advances in every case.
* **FreeBSD's interrupt disable unmasks.** **[Inferred]** FreeBSD writes
  all ones to the mask-set register and then to the mask-clear register
  (`F.c` 540-546, `F.h` 60-61), which leaves every interrupt unmasked.
  Linux writes the mask-set register and then the status-clear register
  (`L.c` 2576-2583, `L.h` 265-270).
* **FreeBSD header.** The CRC-forward bit is defined only in one branch of
  a conditional in `F.h` (79-90), so it is undefined in the other; FreeBSD
  does not use it.

## What only the board can settle

* **[Board]** Whether DMA status bits 1 to 17 report the corresponding
  ring disabled (as Linux's poll implies) or bit 1 reports descriptor-RAM
  initialisation busy (as Linux's header names it). A probe: read the
  status register with DMA enabled and with it disabled, rings enabled and
  not, on each direction.
* **[Board]** How long a stop takes to confirm in practice, against
  Linux's 5 ms bound.
* **[Board]** Whether the UniMAC software reset, RBUF flush control bit 1,
  RBUF flush bit 0 or the TX flush change any DMA register; neither driver
  depends on it, both rewrite the ring registers.
* **[Board]** The reset value of the command register's CRC-forward bit,
  which decides whether received lengths include the FCS when a driver
  does not set it. Linux reads it rather than choosing it.
