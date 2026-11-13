# The Raspberry Pi 4's SD controller (EMMC2): a clean-room facts record

A point-in-time record, written on 2026-11-12 on an Apple Silicon macOS
27.0.1 host, of what the published drivers for the BCM2711's EMMC2
controller (`brcm,bcm2711-emmc2`) do and require. It is the "dirty room"
half of a clean-room process: its author read GPL-licensed driver sources
(Linux, U-Boot) and BSD-licensed ones (FreeBSD) and wrote down facts and
working principles in his own words, so that the team that writes erXos's
driver can work from this record alone and never sees those sources. The
author of this record writes no erXos code for this driver.

The record contains no code, no quoted comments, no identifiers coined by
the drivers and no tables in their source form. Register and field names
are the SD Host Controller standard's names as used across all three
projects. Every fact cites the file and line range it came from, so a
reviewer can check it; the sources are listed with their hashes in
[Sources](#sources).

## Contents

1. [How to read this record](#how-to-read-this-record)
2. [Sources](#sources)
3. [The controller on the board](#the-controller-on-the-board)
4. [Register map](#register-map)
5. [Register access: width and spacing](#register-access-width-and-spacing)
6. [Quirks of the BCM2711 integration](#quirks-of-the-bcm2711-integration)
7. [Reset](#reset)
8. [Clocks](#clocks)
9. [Power and signalling voltage](#power-and-signalling-voltage)
10. [Interrupts](#interrupts)
11. [Issuing a command](#issuing-a-command)
12. [PIO data transfer](#pio-data-transfer)
13. [Card initialisation](#card-initialisation)
14. [Card detect and write protect](#card-detect-and-write-protect)
15. [Error recovery](#error-recovery)
16. [DMA, for a later design](#dma-for-a-later-design)
17. [Where the drivers disagree](#where-the-drivers-disagree)
18. [What only the board can settle](#what-only-the-board-can-settle)

## How to read this record

Each fact carries a confidence tag:

* **[Both]**: implemented the same way by Linux and FreeBSD (U-Boot noted
  where it also agrees).
* **[Linux]**, **[FreeBSD]**, **[U-Boot]**: only that project implements
  or states it; the others were read and do not, or were not checked for it.
* **[DT]**: stated by Linux's device tree for the board.
* **[Inferred]**: the author's conclusion from the cited facts; not stated
  by any source.
* **[Board]**: the sources leave it open or contradict each other; the
  board probe must settle it.

Citations use short prefixes: `L` is Linux v6.18, `U` is U-Boot v2025.01,
`F` is FreeBSD 14.3.0-RELEASE, each followed by the path in that tree and
a line range. "Linux's bcm2711 variant" means the `brcm,bcm2711-emmc2`
entry of `L drivers/mmc/host/sdhci-iproc.c`, which is the Linux driver for
this controller.

The SD Association's Physical Layer and Host Controller Simplified
Specifications were not downloaded for this record, and no fact here rests
on them; every fact cites a source file read for this record. Where the
drivers carry a value whose origin is the specifications (for example the
CMD8 check pattern), the record cites the driver.

## Sources

Read on 2026-11-12 as data; nothing in them was built or run. Fetched over
HTTPS with curl 8.7.1 into
`/private/tmp/claude-501/-Users-stas-erxos/930ef003-efa3-46c9-ae76-0c72af4a6d3b/scratchpad/cleanroom/src/`,
a scratch directory outside the tree, by
`~/erxos-scratch/tools/cleanroom_fetch.rb` and by hand for the last few.

* **Linux v6.18**, tag object `f7b88edb52c8dd01b7e576390d658ae6eef0e134`,
  commit `7d0a66e4bb9081d75c82ec4957c50034cb0ea449` (resolved with
  `git ls-remote` against git.kernel.org's torvalds tree), fetched from
  `https://raw.githubusercontent.com/torvalds/linux/7d0a66e4bb9081d75c82ec4957c50034cb0ea449/<path>`.
  License GPL-2.0.

  | Path | SHA-256 |
  |---|---|
  | `drivers/mmc/host/sdhci-iproc.c` | `f05fdbab5624a2564f4c56e6a1898dbc9f1fb0d06f9f0ad7d2391e118f9689fb` |
  | `drivers/mmc/host/sdhci.c` | `c727b227d77a3c5cdcb6ac409b82e118bc7f307362b8f4f881e1e484daad7d1a` |
  | `drivers/mmc/host/sdhci.h` | `09a4e8e970f2ef79477ac5cfff4df8d2f39112489572af9990f6a3b8a619dffc` |
  | `drivers/mmc/core/core.c` | `bb1b24227b5bef5af18346d9b2a60faef219b88c9543b5d2220577376bb06500` |
  | `drivers/mmc/core/host.c` | `822afe61a72e267e8da974990548859272038d464cf8423f075836d160f60b8d` |
  | `drivers/mmc/core/sd.c` | `70f3c63f37772a20d42e25d8e0b045f85248ce4f8f5ee273c2feedea3169f191` |
  | `drivers/mmc/core/sd_ops.c` | `3bfb765340ffd35196b70eaec3a95fde0c2912a2f8114537de6a302ac00c7bb9` |
  | `drivers/mmc/core/mmc_ops.c` | `21ce493f0638b9b778af03ed01be9780ca5bcff12ec0e365a112af0137ad193f` |
  | `include/linux/mmc/sd.h` | `44e70f65d4f9035f798a7f22a574be7016edf65aee298e5a96a606141e244f98` |
  | `include/linux/mmc/mmc.h` | `50a03b69f2a0c19c7c24d69d5a537fa76defdfc6a9cc7738a1c7d8751bdd5775` |
  | `arch/arm/boot/dts/broadcom/bcm2711.dtsi` | `b33a898bd3d841552699a90ca85153c32778dfd76e46ead50ee191c9e3f67520` |
  | `arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts` | `6bc587c46e263bf096ee5f402669bd985d95a6048f77991ffd96bf7a7e6c6d86` |
  | `arch/arm/boot/dts/broadcom/bcm2711-rpi.dtsi` | `13a42cdc5aa8e85a2bca0d058eced7fada8213203ea9eacaf8ad32e3eccfbb47` |
  | `arch/arm/boot/dts/broadcom/bcm283x.dtsi` | `999bc1a10e79136b30e1f87633ba4eb2eb9e5d2b79edece0b6d5133625167447` |

  The two device-tree files `bcm2711.dtsi` and `bcm2711-rpi-4-b.dts` were
  first read from the build's copy of deps.lock's `linux-dts` pin
  (`linux-6.18.tar.xz`, the board-tree source of the Pi card build), then
  fetched at the tag; the hashes of both copies are equal. The binding
  header `include/dt-bindings/clock/bcm2835.h` was read in the build copy
  only (line 62).
* **U-Boot v2025.01**, tag object `0592671fbba8c96df043d537d1f6415492de886e`,
  commit `6d41f0a39d6423c8e57e92ebbe9f8c0333a63f72` (resolved against
  source.denx.de), fetched from
  `https://raw.githubusercontent.com/u-boot/u-boot/6d41f0a39d6423c8e57e92ebbe9f8c0333a63f72/<path>`.
  License GPL-2.0+.

  | Path | SHA-256 |
  |---|---|
  | `drivers/mmc/bcm2835_sdhci.c` | `0167cc8ec0f47a893cea9838df07917e24a2288de964112002a7efc34f93e27b` |
  | `drivers/mmc/sdhci.c` | `59c832ddf03989c0adec07a3a5fa733dd6e2d246953091fb242224aef8d67e78` |
  | `include/sdhci.h` | `4c9fac17595b8eb3af7a851a52abab36d013d6814f82d520d18cdb80f6ab5c74` |
  | `arch/arm/mach-bcm283x/msg.c` | `292c0294126d5cd93583a88908a2bf716fda9af1e656a87e4b29596cc420d50f` |
  | `arch/arm/mach-bcm283x/include/mach/mbox.h` | `0474b63ae79263f0e73667dfe456ccefa48435681f8245e889441d796a588635` |

* **FreeBSD 14.3.0-RELEASE**, tag `release/14.3.0` object
  `ab74684c4debaec81dd8a1e57116cbd47f593e04`, commit
  `8c9ce319fef765890ce518cab85d3a470b669849` (resolved against
  github.com/freebsd/freebsd-src), fetched from
  `https://raw.githubusercontent.com/freebsd/freebsd-src/8c9ce319fef765890ce518cab85d3a470b669849/<path>`.
  License BSD-2-Clause.

  | Path | SHA-256 |
  |---|---|
  | `sys/arm/broadcom/bcm2835/bcm2835_sdhci.c` | `2928861d93c34d42a5cde74bf523e5f1018ee68de3c5c35f33620d2059952a92` |
  | `sys/arm/broadcom/bcm2835/bcm2835_mbox_prop.h` | `b03ab1c0993503b7370ee6cd9dd009860e3838d8c80ca3a02d5470bb3ef8ecd4` |
  | `sys/dev/sdhci/sdhci.c` | `f610ce62058120de45448333be459373e992d753c4a384d8222839459b3b1abc` |
  | `sys/dev/sdhci/sdhci.h` | `363ed505d9ec77603b1b0d46e689da80600e72ce5948d5b2efe70571059b2b78` |
  | `sys/dev/sdhci/sdhci_fdt.c` | `71439ab0aafdf17b5249d87f56fa1a0f3d66e29672d199b27fd960bd0fcd59e8` |
  | `sys/dev/mmc/mmc.c` | `738725016981e017ed31497938b4fd7744246c7046ba6a2962005931e4ba5dfa` |
  | `sys/dev/mmc/mmcreg.h` | `74ff2ab498265ad51188205858899a0122089a47c9924e61a3002808deb47829` |

  `sdhci_fdt.c` was fetched but not needed: the BCM2711 attaches through
  `bcm2835_sdhci.c` (F `sys/arm/broadcom/bcm2835/bcm2835_sdhci.c` 141-142).

## The controller on the board

* The Pi 4 Model B's microSD slot is wired to EMMC2. [DT] (L
  `arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts` 190-196)
* The controller's bus address is `0x7e340000` and its register window is
  `0x100` bytes (256). [DT] (L `bcm2711.dtsi` 426-428)
* EMMC2 sits on its own bus node, whose ranges map bus `0x7e000000` to CPU
  physical `0xfe000000` for `0x01800000` bytes, so the CPU sees the
  registers at `0xfe340000`. [DT] (L `bcm2711.dtsi` 418-423)
* The window is 256 bytes at the start of a 4 KiB page. No other node of
  the device tree lies in `0x7e340000`-`0x7e340fff`: the other SD
  controller of the SoC (`brcm,bcm2835-sdhost`) is at `0x7e202000`. [DT]
  for the addresses (L `bcm283x.dtsi` 314-315), [Inferred] that the page is
  EMMC2's alone; [Board] whether hardware decodes anything else in it.
* Its interrupt is GIC shared peripheral interrupt 126, level-triggered,
  active high. [DT] (L `bcm2711.dtsi` 429) [Inferred]: on the GIC-400
  this is interrupt ID 158 (shared interrupts start at 32).
* Its clock input is the SoC clock manager's EMMC2 clock (index 51 in
  Linux's binding numbering). [DT] (L `bcm2711.dtsi` 430; L
  `include/dt-bindings/clock/bcm2835.h` 62)
* The node carries no pin-control property, so neither Linux nor the
  device tree configures any GPIO function for it. [DT] (L
  `bcm2711.dtsi` 426-432; L `bcm2711-rpi-4-b.dts` 191-196) [Board]:
  whether the SD pins need any muxing that the firmware already did.
* The slot has two board regulators, both behind the firmware's GPIO
  expander (`raspberrypi,firmware-gpio`, reached through the VideoCore
  firmware, not through SoC GPIO registers): card power (`vcc-sd`, fixed
  3.3 V, enabled by expander line 6, named `SD_PWR_ON`, on at boot) and
  I/O voltage (`vdd-sd-io`, expander line 4, named `VDD_SD_IO_SEL`: line
  high gives 1.8 V, line low gives 3.3 V, settling time 5000 us, on at
  boot and always on). [DT] (L `bcm2711-rpi-4-b.dts` 26-48, 63-72, 191-193;
  L `bcm2711-rpi.dtsi` 46-50)
* The Pi 4 node is marked `broken-cd`: the controller's card-detect is not
  to be trusted for insertion events, and the host polls instead. [DT] (L
  `bcm2711-rpi-4-b.dts` 194); Linux turns it into polling (L
  `drivers/mmc/core/host.c` 313-332). See
  [Card detect](#card-detect-and-write-protect).
* The firmware rewrites EMMC2's `dma-ranges` at boot according to the SoC
  revision; that is why EMMC2 has a bus node of its own, found by the
  firmware through the `emmc2bus` alias. [DT] (L `bcm2711.dtsi` 412-424; L
  `bcm2711-rpi.dtsi` 14) See [DMA](#dma-for-a-later-design).
* Linux matches the controller as an SDHCI-standard controller with a
  small platform layer; so do U-Boot and FreeBSD. [Both] (L
  `sdhci-iproc.c` 322-323; U `drivers/mmc/bcm2835_sdhci.c` 234-244; F
  `bcm2835_sdhci.c` 129-142)

## Register map

The controller follows the SD Host Controller standard register layout.
Offsets agree between Linux's and FreeBSD's register headers. [Both] (L
`drivers/mmc/host/sdhci.h` 26-331; F `sys/dev/sdhci/sdhci.h` 102-342)

| Offset | Width | Register (standard name) |
|---|---|---|
| 0x00 | 32 | SDMA System Address / Argument 2 |
| 0x04 | 16 | Block Size |
| 0x06 | 16 | Block Count |
| 0x08 | 32 | Argument |
| 0x0C | 16 | Transfer Mode |
| 0x0E | 16 | Command |
| 0x10-0x1F | 4 x 32 | Response |
| 0x20 | 32 | Buffer Data Port |
| 0x24 | 32 | Present State |
| 0x28 | 8 | Host Control 1 |
| 0x29 | 8 | Power Control |
| 0x2A | 8 | Block Gap Control |
| 0x2B | 8 | Wakeup Control |
| 0x2C | 16 | Clock Control |
| 0x2E | 8 | Timeout Control |
| 0x2F | 8 | Software Reset |
| 0x30 | 32 | Normal (low 16 bits) and Error (high 16 bits) Interrupt Status |
| 0x34 | 32 | Interrupt Status Enable (same split) |
| 0x38 | 32 | Interrupt Signal Enable (same split) |
| 0x3C | 16 | Auto CMD Error Status |
| 0x3E | 16 | Host Control 2 |
| 0x40 | 32 | Capabilities (low word) |
| 0x44 | 32 | Capabilities (high word) |
| 0x48 | 32 | Maximum Current Capabilities |
| 0x54 | 8 | ADMA Error Status |
| 0x58 | 32 (+0x5C) | ADMA System Address |
| 0x64-0x6F | 16 each | Preset Values (high speed and UHS modes) |
| 0xFC | 16 | Slot Interrupt Status |
| 0xFE | 16 | Host Controller Version |

The "Width" column is the register's logical width. On this controller
every access must be 32 bits wide; see the next section.

Fields a PIO driver uses (bit numbers within the register; [Both] from the
same header ranges unless marked):

* **Block Size**: transfer block size in bits 11:0; SDMA buffer boundary
  in bits 14:12.
* **Transfer Mode**: bit 0 DMA enable; bit 1 block-count enable; bits 3:2
  auto-command select (bit 2 Auto CMD12, bit 3 Auto CMD23); bit 4 direction
  (1 = card to host, a read); bit 5 multiple-block select.
* **Command**: bits 1:0 response type (0 none, 1 136-bit, 2 48-bit,
  3 48-bit with busy); bit 3 response CRC check enable; bit 4 response
  index check enable; bit 5 data present; bits 7:6 command type (both set
  for an abort command); bits 13:8 command index.
* **Present State**: bit 0 command inhibit (CMD line in use); bit 1
  command inhibit for DAT (DAT line in use); bit 8 write transfer active;
  bit 9 read transfer active; bit 10 buffer write enable (space
  available); bit 11 buffer read enable (data available); bit 16 card
  inserted; bit 17 card state stable; bit 18 card-detect pin level;
  bit 19 write-protect pin level; bits 23:20 DAT[3:0] line levels; bit 24
  CMD line level.
* **Host Control 1**: bit 0 LED; bit 1 4-bit data width; bit 2 high-speed
  enable; bits 4:3 DMA select (0 SDMA, 2 32-bit ADMA2, 3 64-bit ADMA2);
  bit 5 8-bit data width.
* **Power Control**: bit 0 bus power on; bits 3:1 bus voltage select
  (7 = 3.3 V, 6 = 3.0 V, 5 = 1.8 V).
* **Clock Control**: bit 0 internal clock enable; bit 1 internal clock
  stable (read only); bit 2 SD clock enable (clock to the card); bit 3 PLL
  enable (version 4.10 and later); bit 5 clock generator select
  (programmable mode); bits 15:8 low 8 bits of the divider; bits 7:6 high
  2 bits of the divider (version 3.00 and later).
* **Software Reset**: bit 0 reset all; bit 1 reset CMD line; bit 2 reset
  DAT line.
* **Interrupt Status / Enable / Signal Enable**, normal half: bit 0
  command complete; bit 1 transfer complete; bit 2 block gap; bit 3 DMA
  interrupt; bit 4 buffer write ready; bit 5 buffer read ready; bit 6 card
  insertion; bit 7 card removal; bit 8 card interrupt; bit 15 error
  summary. Error half: bit 16 command timeout; bit 17 command CRC; bit 18
  command end bit; bit 19 command index; bit 20 data timeout; bit 21 data
  CRC; bit 22 data end bit; bit 23 current limit (bus power); bit 24 Auto
  CMD error; bit 25 ADMA error.
* **Host Control 2**: bits 2:0 UHS mode select; bit 3 1.8 V signalling
  enable; bits 5:4 driver strength; bit 15 preset value enable.
* **Capabilities, low word**: bits 5:0 timeout clock frequency, bit 7 its
  unit (1 = MHz, 0 = kHz); base clock frequency in MHz in bits 15:8 from
  version 3.00 (bits 13:8 before); bits 17:16 maximum block length; bit 18
  8-bit bus; bit 19 ADMA2; bit 21 high speed; bit 22 SDMA; bit 24 3.3 V;
  bit 25 3.0 V; bit 26 1.8 V; bit 28 64-bit system bus (bit 27 for
  version 4 mode).
* **Capabilities, high word**: bit 0 SDR50; bit 1 SDR104; bit 2 DDR50;
  bits 6:4 driver types A, C, D; bits 23:16 clock multiplier.
* **Host Controller Version**: the low byte is the specification version.
  FreeBSD's header names the codes: 2 is version 3.00, 3 is 4.00, 4 is
  4.10, 5 is 4.20. [FreeBSD] (F `sys/dev/sdhci/sdhci.h` 332-342)

## Register access: width and spacing

These are the facts most likely to bite.

1. **Only 32-bit accesses.** The controller must be accessed with 32-bit
   reads and writes only. A write to an 8- or 16-bit register is done by
   reading the containing aligned 32-bit word, replacing the target byte
   or half-word, and writing the whole word back; a narrow read is a
   32-bit read of the aligned word followed by a shift. [Both], U-Boot
   agrees. (L `sdhci-iproc.c` 34-69 for the read side, 147-155 for byte
   writes, 272-278 for their use on the bcm2711; F `bcm2835_sdhci.c`
   431-563; U `bcm2835_sdhci.c` 103-155) [Board]: what an 8- or 16-bit
   access actually does (fault, ignored, or corrupting) is not stated by
   any source; do not test it on a card holding data.
2. **Transfer Mode and Command share one 32-bit word (0x0C), and writing
   that word issues the command.** So Transfer Mode cannot be written on
   its own: the driver keeps the Transfer Mode value in memory and writes
   it together with the Command value in one 32-bit write. Reading Transfer
   Mode back must return the remembered value. [Both], U-Boot agrees. (L
   `sdhci-iproc.c` 43-62, 106-145; F `bcm2835_sdhci.c` 462-555; U
   `bcm2835_sdhci.c` 103-117)
3. **Block Size and Block Count also share a word (0x04).** Linux and
   FreeBSD keep both values in memory and write the combined word once,
   just before the Command write, so that two back-to-back writes to the
   same word cannot collide. [Both] (L `sdhci-iproc.c` 88-145; F
   `bcm2835_sdhci.c` 462-555) U-Boot does not hold them back; it relies
   on its write spacing (next point) instead. [U-Boot] (U
   `bcm2835_sdhci.c` 103-117)
4. **Successive writes need spacing.** All three projects carry the same
   erratum for the Broadcom controller family: two writes to registers
   that arrive within two SD-card clock periods of each other can lose the
   first one (a clock-domain-crossing fault). The Buffer Data Port (0x20)
   is exempt. They work around it differently:
   * Linux's bcm2711 variant waits after every 32-bit write, but only
     while the card clock is at or below 400 kHz: it waits four card-clock
     periods, rounded up to whole microseconds (10 us if the clock is off).
     Above 400 kHz it adds no delay, and relies on the shadowing of points
     2 and 3. [Linux] (L `sdhci-iproc.c` 71-85, 272-278)
   * FreeBSD waits two card-clock periods plus 1 us after every write
     except the data port, at every clock rate, whenever the card clock is
     running. [FreeBSD] (F `bcm2835_sdhci.c` 438-450; data-port bulk access
     without delay at 491-498 and 565-571)
   * U-Boot enforces at least 6 us between non-data-port writes (two
     periods of 400 kHz, plus 1 us), measured from the last write, at all
     clock rates. [U-Boot] (U `bcm2835_sdhci.c` 70-91, 196-208)

   [Inferred]: the safe rule for a first driver is FreeBSD's or U-Boot's
   (space every non-data write by at least two card-clock periods, with
   the slowest clock in use), plus Linux's and FreeBSD's coalescing of
   0x04 and 0x0C; Linux's cheaper rule is an optimisation to measure later.
   [Board]: whether the spacing is needed at all above 400 kHz on this
   SoC.

## Quirks of the BCM2711 integration

What Linux's bcm2711 variant declares, compared with the older BCM2835
controller entry in the same file (L `sdhci-iproc.c` 272-296 for the bcm2711,
252-269 for the BCM2835 entries):

* **Auto CMD12 for multi-block transfers.** The bcm2711 entry asks the
  generic layer to use the controller's Auto CMD12 to end multi-block
  transfers instead of a separately issued stop command. [Linux] (L
  `sdhci-iproc.c` 288-291; effect at L `sdhci.c` 4511-4512) FreeBSD's
  generic layer also sets Auto CMD12 on open-ended multi-block transfers
  that carry a stop command. [FreeBSD] (F `sys/dev/sdhci/sdhci.c`
  1725-1745)
* **Minimum card clock 200 kHz.** Linux reports 200 kHz as the lowest card
  clock for this SoC because of a known hang in the BCM2711 integration:
  with the SoC core clock at 500 MHz or more, probing an empty slot at
  100 kHz hangs the controller when the core-to-card clock ratio is too
  large. [Linux] (L `sdhci-iproc.c` 167-182, 282) Linux's card probe would
  otherwise retry at 300, 200 and 100 kHz after 400 kHz (L
  `drivers/mmc/core/core.c` 53, 2308-2316). [Board]: the core clock the
  firmware runs.
* **Card power through the power register even with regulators.** On this
  variant Linux writes the bus voltage select and bus power bits of Power
  Control even though board regulators supply the card. [Linux] (L
  `sdhci-iproc.c` 280; L `sdhci.c` 2192-2202, 2121-2190)
* **Not declared broken**, unlike the BCM2835 entry: card detection, high
  speed, data-timeout clock, preset values, SDMA and ADMA are not marked
  broken for the bcm2711, and its capability registers are read from the
  hardware rather than supplied by the driver. [Linux] (L `sdhci-iproc.c`
  293-296 against 252-269; capability read at 394-398) FreeBSD also reads
  the hardware capability registers for EMMC2 (its entry sets no quirks;
  F `bcm2835_sdhci.c` 129-135; F `sys/dev/sdhci/sdhci.c` 880-893), though
  its glue code fills a capability word of its own that only takes effect
  for controllers marked as lacking capabilities (F `bcm2835_sdhci.c`
  312-316).
* **DDR at 3.3 V.** Linux advertises 3.3 V DDR capability for this
  controller. [Linux] (L `sdhci-iproc.c` 295) Not needed by a PIO-first
  driver.

## Reset

* A reset is requested by writing the reset bits to Software Reset
  (0x2F); the controller clears each bit when its reset is done. Poll at
  about 10 us intervals for up to 100 ms. [Both] (L `sdhci.c` 204-235; F
  `sys/dev/sdhci/sdhci.c` 1270-1304)
* Reset-all turns the card's bus power off and stops the card clock, so
  after it the driver must set power and clock again. [Linux] (L
  `sdhci.c` 210-214)
* After a reset-all both drivers enable the same base set of interrupt
  status bits and signals: command complete, transfer complete, command
  timeout, CRC, end bit and index errors, data timeout, CRC and end bit
  errors, and current-limit error. FreeBSD also enables buffer ready, DMA,
  and Auto CMD error bits from the start; Linux enables the buffer-ready
  bits per transfer. [Both] (L `sdhci.c` 300-314, 362-385; F
  `sys/dev/sdhci/sdhci.c` 386-407)
* Remember that Software Reset is a byte inside the 32-bit word at 0x2C,
  shared with Clock Control and Timeout Control: a reset request is a
  read-modify-write of that word. [Inferred] from
  [Register access](#register-access-width-and-spacing) point 1 and the
  register map.

## Clocks

* **The base clock comes from the firmware.** The EMMC2 clock is set up by
  the VideoCore firmware. U-Boot asks the firmware for it through the
  mailbox property channel: first it powers on the SD power domain (power
  tag `0x00028001`, device 0, with the "on" and "wait" flags), then reads
  the current rate of clock 12 (tag `0x00030002`); if that is zero it
  reads the maximum rate (tag `0x00030004`). [U-Boot] (U
  `arch/arm/mach-bcm283x/msg.c` 55-116; U
  `arch/arm/mach-bcm283x/include/mach/mbox.h` 177, 187-209, 225-239; U
  `drivers/mmc/bcm2835_sdhci.c` 188-193, 234-244) FreeBSD does the same
  power-on and current-rate query with the same clock ID (12, `0xc`) and
  power device 0, falls back to a `clock-frequency` device-tree property,
  then to 100 MHz. [FreeBSD] (F `bcm2835_sdhci.c` 66-67, 129-135, 236-259;
  F `bcm2835_mbox_prop.h` 61, 130) Linux takes the rate of the device
  tree's clock (clock manager clock 51) from its clock framework.
  [Linux] (L `sdhci-iproc.c` 157-165, 388-392)
* **Which rate is the divider's input disagrees between the drivers.**
  Linux uses the clock framework's rate as the base clock; FreeBSD, for
  EMMC2, uses the base-clock field of the Capabilities register (the
  firmware rate it queries goes only into a capability word that EMMC2
  does not use). [Board]: read the Capabilities base-clock field and the
  firmware's current EMMC2 rate and compare them. (L `sdhci-iproc.c`
  157-165; F `sys/dev/sdhci/sdhci.c` 908-925; F `bcm2835_sdhci.c` 312-316)
* **Divider.** For controllers of version 3.00 and later, the card clock is
  the base clock divided by an even number: a divider field value N gives
  base / (2N), and N = 0 gives the base clock itself. The field is 10 bits
  (8 low bits in bits 15:8, 2 high bits in bits 7:6), so the largest
  divisor is 2046. For older versions the divisor is a power of two up to
  256 and only the 8 low bits exist. Choose the smallest divisor whose
  result does not exceed the wanted rate. [Both] (L `sdhci.c` 1916-2006;
  L `sdhci.h` 347-348; F `sys/dev/sdhci/sdhci.c` 159-160, 452-485)
  Linux also supports the programmable clock mode when the capability's
  clock multiplier is non-zero; [Board] whether it is (Capabilities high
  word, bits 23:16).
* **Changing the clock.** In order: stop the card clock (clear SD clock
  enable; Linux clears the whole Clock Control register); write the
  divider; set internal clock enable; poll internal clock stable; then set
  SD clock enable. Linux polls every 10 us for up to 150 ms; FreeBSD every
  1 ms for up to 10 ms. On version 4.10 and later in version-4 mode, Linux
  also sets PLL enable and waits for stability again before enabling the
  card clock. [Both] for the order (L `sdhci.c` 2008-2076; F
  `sys/dev/sdhci/sdhci.c` 409-507) [Board]: the stabilisation time and
  whether version-4 mode applies.
* **Card-identification clock: 400 kHz** in all three projects. [Both],
  U-Boot agrees. (L `core.c` 53, 2343; F `sys/dev/mmc/mmcreg.h` 536, F
  `sys/dev/mmc/mmc.c` 678-683; U `bcm2835_sdhci.c` 51) It must not go
  below 200 kHz on this SoC (see [Quirks](#quirks-of-the-bcm2711-integration)).
* **Data timeout counter.** The data timeout is a power of two of the
  timeout clock: a counter value C in Timeout Control gives
  2^(13 + C) timeout-clock periods. The timeout clock's rate is in the
  Capabilities register (bits 5:0 with the unit in bit 7). Linux's bcm2711
  variant uses that field as is (it does not declare the timeout clock to
  be the card clock); both drivers fall back to the largest counter value
  when the rate is unknown. [Both] (L `sdhci.c` 969-1030; F
  `sys/dev/sdhci/sdhci.c` 926-950) [Board]: the Capabilities timeout-clock
  value; the largest valid counter value is not stated in the files read.

## Power and signalling voltage

* **Turning card power on through the controller.** Clear Power Control;
  write the voltage select for the chosen voltage; then write it again with
  bus power on. FreeBSD retries the "on" write for up to 2 ms (20 tries,
  100 us apart) and checks that bus power reads back as on. [Both] (L
  `sdhci.c` 2121-2190; F `sys/dev/sdhci/sdhci.c` 510-562)
* **Settling delays at power-up.** Linux waits its power delay, 10 ms by
  default, after power on before starting the clock, then starts the clock
  at the identification rate and waits the same 10 ms again (at least
  74 clock cycles must pass before the first command). FreeBSD waits 1 ms
  and 2 ms at the same two points. [Both] for the order, values differ (L
  `core.c` 1337-1369; L `host.c` 583; F `sys/dev/mmc/mmc.c` 659-684)
* **Board regulators.** Card power (3.3 V) and I/O voltage are switched by
  the firmware GPIO expander lines 6 and 4 (see
  [The controller on the board](#the-controller-on-the-board)). Linux and
  FreeBSD enable both regulators at power-up and disable them at power-off.
  [Both] (L `sdhci.c` 2192-2202; F `bcm2835_sdhci.c` 394-423) [Board]: the
  firmware mailbox calls that drive expander lines 4 and 6; none of the
  files read for this record define them. A driver that never power-cycles
  the card and stays at 3.3 V signalling does not need them, provided the
  firmware leaves line 6 on and line 4 low.
* **Power cycle.** A full power cycle is power off, at least 1 ms, power
  on. [Linux] (L `core.c` 1371-1398)
* **Switching signalling to 1.8 V** (only for UHS-I, not needed by a
  PIO-first driver at default or high speed). Linux, for version 3.00 and
  later controllers: set the I/O regulator to 1.8 V first, then set the
  1.8 V signalling enable bit of Host Control 2, then check that the bit
  reads back as set. Back to 3.3 V: clear the bit, set the regulator to
  3.3 V, wait 5 ms, check the bit reads clear. The card clock is gated for
  at least 10 ms around the switch (the SD rule is 5 ms). [Linux] (L
  `sdhci.c` 2636-2730; L `core.c` 1187-1208, 1210-1260) FreeBSD's generic
  layer toggles the Host Control 2 bit with 5 ms waits and the card clock
  stopped; its BCM glue does not change the regulator voltage in the
  files read. [FreeBSD] (F `sys/dev/sdhci/sdhci.c` 1415-1450; F
  `bcm2835_sdhci.c` 394-423, 820-850)
* **A card that was not power-cycled may still be signalling at 1.8 V.**
  Linux detects this after selecting the card and either continues in a
  UHS-I mode or power-cycles the card and starts again. [Linux] (L `sd.c`
  1509-1525) [Board]: whether the Pi firmware or a previous kernel leaves
  the card in 1.8 V signalling when erXos starts. If it does, a 3.3 V-only
  driver must power-cycle the card through expander line 6.
* **Voltage window advertised to the card.** U-Boot advertises 3.2-3.4 V
  and 1.65-1.95 V. FreeBSD's glue fills a capability word with 3.3 V and
  1.8 V (unused for EMMC2, see above). Linux takes the window from the
  regulators and the Capabilities register. [U-Boot] (U `bcm2835_sdhci.c`
  216) [Board]: the Capabilities voltage bits 24-26.

## Interrupts

* Interrupt status bits are cleared by writing 1 to them. Linux reads the
  32-bit status, treats 0 or all-ones as "not this controller", and writes
  the handled bits back. [Both] (L `sdhci.c` 3556-3595; F
  `sys/dev/sdhci/sdhci.c` 2363-2400)
* Status Enable selects which events set status bits; Signal Enable selects
  which of them raise the interrupt line. Both drivers write the same mask
  to both. [Both] (L `sdhci.c` 300-314; F `sys/dev/sdhci/sdhci.c`
  403-406)
* Insertion and removal interrupts: Linux arms the one for the opposite of
  the current Present State card-inserted bit; FreeBSD enables both unless
  the slot is polled or non-removable. [Both] (L `sdhci.c` 156-175; F
  `sys/dev/sdhci/sdhci.c` 398-402) On the Pi 4 the device tree says card
  detect is broken (see below).
* A PIO-first driver may poll the status register instead of taking the
  interrupt. [Inferred]

## Issuing a command

In order (Linux, FreeBSD agree on the order; [Both] unless marked):

1. Wait until Present State shows command inhibit clear, and also DAT
   inhibit clear if the command uses the data lines or has a busy
   response. Stop commands sent during a data transfer do not wait for DAT.
   Linux retries for about 10 ms, 1 ms apart. (L `sdhci.c` 1653-1680,
   1756-1797)
2. For a data command: set the data timeout, Block Size and Block Count
   (held in memory, see access point 3). (L `sdhci.c` 1683-1693, 1207 on)
3. Write Argument (0x08). (L `sdhci.c` 1692-1698)
4. Compose Transfer Mode: for data commands, block-count enable; for
   multi-block, multi-block select plus Auto CMD12 if used; direction bit
   for reads; DMA bit only when DMA is used. For commands without data,
   Linux clears the auto-command bits. (L `sdhci.c` 1460-1500; F
   `sys/dev/sdhci/sdhci.c` 1725-1745)
5. Compose Command: index, response type (none; 136-bit; 48-bit; 48-bit
   with busy), CRC check and index check as the response type requires,
   and data present for data commands. (L `sdhci.c` 1709-1725)
6. Write Block Size/Count word (if held), then Transfer Mode and Command
   together as one 32-bit write to 0x0C. That write starts the command.
   (L `sdhci-iproc.c` 114-145; F `bcm2835_sdhci.c` 526-555)
7. Wait for command complete (or an error bit) in Interrupt Status; clear
   it.
8. Read the response. A 48-bit response is the 32-bit word at 0x10. A
   136-bit response (R2: CID, CSD) is stored without its CRC byte, so the
   four words at 0x10-0x1C are shifted: each word must be shifted left by
   8 bits with the top byte of the next lower word carried in to recover
   the standard 128-bit layout. [Both] (L `sdhci.c` 1798-1830; F
   `sys/dev/sdhci/sdhci.c` 1895-1910)
9. For a busy response without data (R1b), also wait for transfer complete
   (DAT0 released). U-Boot instead checks the DAT-active state for this
   controller family. [U-Boot] (U `drivers/mmc/sdhci.c` 305-313; quirk set
   at U `bcm2835_sdhci.c` 213-214)

U-Boot also adds a fixed 1 ms wait after each command on this controller
family. [U-Boot] (U `drivers/mmc/sdhci.c` 332-333; U `bcm2835_sdhci.c`
213-214) Neither Linux nor FreeBSD does. [Board]: whether it is needed.

The command numbers and argument formats the initialisation uses are
taken from Linux's headers, which carry them from the SD specification:
CMD0, 2, 3, 6, 7, 8, 9, 12, 13, 16, 17, 18, 24, 25, 55 and ACMD6, 41, 51.
(L `include/linux/mmc/mmc.h` 31-86; L `include/linux/mmc/sd.h` 14-44, 79)

## PIO data transfer

* The Buffer Data Port (0x20) is read or written 32 bits at a time; bytes
  are packed little-endian within each word (the first byte of the block is
  the low byte of the first word). [Both] (L `sdhci.c` 536-613; F
  `bcm2835_sdhci.c` 491-498, 565-571)
* Per block: wait for buffer read ready (bit 5 of status, or bit 11 of
  Present State) for a read, or buffer write ready (bit 4, or bit 10) for
  a write; then move one whole block (block size / 4 words). Repeat until
  the block count is done, then wait for transfer complete. [Both] (L
  `sdhci.c` 615-650; F `sys/dev/sdhci/sdhci.c` 565-700)
* Data-port accesses do not need the write spacing of
  [Register access](#register-access-width-and-spacing) point 4. [Both],
  U-Boot agrees. (F `bcm2835_sdhci.c` 438-450, 565-571; U
  `bcm2835_sdhci.c` 70-91)
* Block size: 512 bytes for data blocks; 8 bytes for the SCR (ACMD51);
  64 bytes for the CMD6 switch status. [Linux] (L `sd_ops.c` 309-351,
  363-410)
* FreeBSD's EMMC2 glue offers no write protect: it always reports the card
  writable. [FreeBSD] (F `bcm2835_sdhci.c` 425-429)

## Card initialisation

The sequence below is the author's description of what both Linux and
FreeBSD do for an SD memory card, with the values each uses. It is written
for one card, default speed then high speed, 4-bit bus, no UHS-I.

1. Reset the controller (reset all) and set up interrupts.
   ([Reset](#reset))
2. Power the card: 3.3 V voltage select and bus power on in Power Control,
   board regulators on; wait (Linux 10 ms, FreeBSD 1 ms). (L `core.c`
   1337-1356; F `sys/dev/mmc/mmc.c` 659-678)
3. Start the card clock at 400 kHz with a 1-bit bus and wait (Linux 10 ms,
   FreeBSD 2 ms) before the first command. (L `core.c` 1357-1369; F
   `sys/dev/mmc/mmc.c` 678-684)
4. CMD0 (go idle), no response, argument 0; wait 1 ms after it. Linux keeps
   the chip-select line high around it with 1 ms waits so the card does not
   enter SPI mode. (L `mmc_ops.c` 144-186; F `sys/dev/mmc/mmc.c` 564-586)
5. CMD8 (send interface condition), R7 response, argument: voltage supplied
   field 1 (2.7-3.6 V) in bits 11:8 and the check pattern `0xAA` in bits
   7:0. The card must echo the pattern; no response means an SD 1.x card
   (or no card). (L `sd_ops.c` 215-249; F `sys/dev/mmc/mmc.c` 643-657)
6. ACMD41 (CMD55 with argument 0, then CMD41) with argument 0, an R3
   response, to read the card's voltage window (OCR) without starting its
   initialisation. (L `sd.c` 1857-1876; F `sys/dev/mmc/mmc.c` 2039-2067)
   CMD55's argument is the card's RCA in bits 31:16, which is 0 before the
   RCA is known. (L `sd_ops.c` 54-57)
7. Choose the voltage the host and card share; CMD0 again; CMD8 again.
   (L `sd.c` 831-860; F `sys/dev/mmc/mmc.c` 2068-2098)
8. ACMD41 repeatedly with the chosen voltage window, plus bit 30 (host
   supports high capacity) if CMD8 succeeded; Linux also sets bit 28
   (maximum performance, SDXC) when the host can supply it and bit 24
   (request 1.8 V) only if the host can do UHS-I. Repeat until the card
   sets bit 31 (power-up done) in its response: Linux every 10 ms for up to
   2 s; FreeBSD every 10 ms for up to 1000 tries (10 s). The R3 response
   has no valid CRC or index, so those checks are off. (L `sd_ops.c` 28-29,
   141-195; L `sd.c` 858-881; L `include/linux/mmc/sd.h` 40-44; F
   `sys/dev/mmc/mmc.c` 588-612, 2094-2100; F `sys/dev/mmc/mmcreg.h`
   642-649)
9. If bit 30 (card capacity status) is set in the final response, the card
   is block-addressed (SDHC/SDXC): read and write addresses are block
   numbers, not byte offsets. (L `sd.c` 140-160; F
   `sys/dev/mmc/mmcreg.h` 648)
10. CMD2 (all send CID), R2 response: the card's identification. (L
    `sd.c` 904; L `mmc.h` 33)
11. CMD3 (send relative address), R6 response: the new RCA is in bits
    31:16 of the response. (L `sd_ops.c` 291-305)
12. CMD9 (send CSD) with the RCA in bits 31:16, R2 response. The CSD
    structure field is at bits 127:126. When it is 1 (SDHC/SDXC) or 2
    (SDUC), the capacity is (C_SIZE + 1) x 512 KiB, with C_SIZE a 22-bit
    field at CSD bits 69:48 for value 1 (28 bits from bit 48 for SDUC);
    the maximum transfer rate is encoded at bits 102:96 (mantissa 102:99,
    exponent 98:96). (L `sd.c` 107-185, 915)
13. CMD7 (select card) with the RCA, R1b response: the card moves to the
    transfer state. (L `sd.c` 1490-1497; L `mmc.h` 38)
14. ACMD51 (send SCR), one 8-byte data block, big-endian: the SD spec
    version is at SCR bits 59:56 and the supported bus widths at bits
    51:48; that field has one bit for 1-bit and one for 4-bit support,
    and Linux checks that both are set (which bit is which is
    defined in a Linux header not read for this record). (L `sd_ops.c`
    309-351; L
    `sd.c` 223-245)
15. Optionally switch to high speed: CMD6 in "set" mode for function 1 of
    group 1, reading a 64-byte status block; the switch took effect if the
    low nibble of status byte 16 is 1. The argument has bit 31 set for
    "set", every group's nibble set to 0xF ("no change") except group 1's.
    Only when the card's SCR version and CSD command classes allow it.
    Then set Host Control 1's high-speed bit and raise the clock. (L
    `sd.c` 380-420; L `sd_ops.c` 363-410) [Board]: high-speed timing with
    this controller; Linux's bcm2711 variant does not declare it broken.
16. Raise the card clock to the card's maximum (from the CSD, or the
    high-speed maximum after step 15). (L `sd.c` 1011-1022, 1544)
17. Switch to 4 bits: ACMD6 with argument 2, then set Host Control 1's
    4-bit bit. (L `sd_ops.c` 121-135; L `sd.c` 1553-1563; L
    `include/linux/mmc/sd.h` 79)
18. Read and write with CMD17/CMD18 and CMD24/CMD25, 512-byte blocks, with
    Auto CMD12 ending multi-block transfers (or CMD12 issued by the
    driver). (L `mmc.h` 43-64)

## Card detect and write protect

* The Pi 4's device tree marks card detect broken, and Linux then polls
  for the card about once a second. When polling, Linux's SDHCI layer
  still reads the Present State card-inserted bit to decide whether a card
  is present, because the bcm2711 variant does not mark its card detection
  broken in the driver. [Linux] (L `bcm2711-rpi-4-b.dts` 194; L `host.c`
  313-332; L `sdhci.c` 2513-2535; L `core.c` 2335) [Board]: whether the
  card-inserted bit, card-stable bit and card-detect level track a real
  insertion and removal on the Pi 4.
* Write protect: the microSD slot has none in the device tree, and FreeBSD
  reports every card writable. [DT], [FreeBSD] (F `bcm2835_sdhci.c`
  425-429)

## Error recovery

* After a command error, Linux resets the CMD line, then the DAT line, as
  two separate resets; after a data-only error it resets the DAT line.
  [Linux] (L `sdhci.c` 270-296) FreeBSD resets after errors as well; its
  exact policy was not checked for this record.
* All resets use the Software Reset poll of [Reset](#reset).
* A command that never completes is bounded by a software timer: Linux uses
  10 s by default, longer for long busy waits. [Linux] (L `sdhci.c`
  1727-1736)

## DMA, for a later design

* **Internal DMA (SDMA, ADMA2).** Linux uses the controller's own SDMA and
  ADMA2 engines for this variant if the Capabilities register advertises
  them, and 64-bit addressing if it advertises that (bit 28, or bit 27 in
  version-4 mode); otherwise it limits DMA addresses to 32 bits. [Linux]
  (L `sdhci-iproc.c` 293-296; L `sdhci.c` 4255-4264, 4300-4345,
  4110-4130) [Board]: Capabilities bits 19, 22, 27 and 28.
* **FreeBSD does not use the internal engines for EMMC2.** It moves data
  with the SoC's separate DMA controller, programming the controller's data
  port as the device end, with no DMA request line for EMMC2, in 512-byte
  units; transfers smaller than a block go by PIO. [FreeBSD] (F
  `bcm2835_sdhci.c` 59-90, 129-135, 309-350, 574-631, 752-780)
* **Address reach.** The default EMMC2 `dma-ranges` map bus addresses
  `0xc0000000`-`0xffffffff` to physical `0x0`-`0x3fffffff`: the device sees
  only the first GiB of RAM, at bus addresses offset by `0xc0000000`.
  [DT] (L `bcm2711.dtsi` 424; the same window for the SoC bus at 45) The
  firmware edits EMMC2's `dma-ranges` according to the SoC revision, so the
  value the kernel receives can differ. [DT] (L `bcm2711.dtsi` 412-417)
  [Board]: read the `dma-ranges` the firmware actually passes on the
  board's SoC revision.
* [Inferred]: a later DMA design should read `dma-ranges` from the tree
  the firmware hands over, not from the source tree, and keep buffers
  inside the window it gives.

## Where the drivers disagree

| Topic | Linux | FreeBSD | U-Boot |
|---|---|---|---|
| Write spacing | 4 card-clock periods after each write, only at or below 400 kHz | 2 periods + 1 us after each non-data write, at all rates | at least 6 us between non-data writes, at all rates |
| Block Size/Count | held until the command | held until the command | written directly |
| Base clock used for the divider | clock framework's rate of clock manager clock 51 | Capabilities base-clock field | firmware mailbox rate (clock 12) |
| Lowest card clock | 200 kHz (erratum) | base / 2046 | 400 kHz |
| Internal clock stable timeout | 150 ms | 10 ms | not checked |
| Power-up waits | 10 ms, then 10 ms | 1 ms, then 2 ms | not checked |
| ACMD41 polling limit | 2 s | 10 s | not checked |
| Extra wait after each command | none | none | 1 ms |
| DMA | internal SDMA/ADMA2 per Capabilities | SoC DMA controller | not checked |
| 1.8 V switch | regulator and Host Control 2 bit | Host Control 2 bit only (in the files read) | not checked |

Sources for each cell are in the sections above.

## What only the board can settle

The board probe should read and record, before any card command:

1. **Host Controller Version** (0xFE, low byte) and both Capabilities words
   (0x40, 0x44): version, base clock, timeout clock and unit, clock
   multiplier, voltages, high speed, SDMA, ADMA2, 64-bit, UHS modes.
2. **The EMMC2 clock rate** the firmware reports (mailbox clock 12,
   current and maximum), compared with the Capabilities base-clock field.
3. **32-bit-only access**: confirm 32-bit accesses work everywhere and
   record what a narrow access does, on a scratch card.
4. **Whether write spacing is needed above 400 kHz**, and how much below
   it.
5. **The state the firmware leaves**: Power Control, Clock Control, Host
   Control 1 and 2 (in particular whether 1.8 V signalling is enabled),
   Present State, and whether the card is still selected or in a UHS-I
   mode.
6. **Card detect**: whether Present State's card-inserted, stable and level
   bits follow insertion and removal on the Pi 4, given the tree's
   `broken-cd`.
7. **The firmware GPIO expander calls** for lines 4 (I/O voltage) and 6
   (card power), if the driver must power-cycle the card or switch voltage;
   no file read for this record defines them.
8. **The SoC core clock** the firmware runs, against the 200 kHz floor.
9. **Internal clock stabilisation time** after a divider change.
10. **The `dma-ranges` the firmware passes** for EMMC2 on this board's SoC
    revision (for the later DMA design).
11. Whether U-Boot's extra 1 ms wait after each command or its R1b
    handling is needed.
12. Whether anything else decodes inside EMMC2's 4 KiB page
    (`0xfe340000`-`0xfe340fff`).
