# Platforms

A **platform** is a machine erXos boots on: a board, or a virtual machine
that plays one. This document is the platform binding: it states, for each
platform, the facts the kernel's platform layer (`kernel/platform/`)
depends on, which the generic designs leave out on purpose. erXos runs on
QEMU's `virt` machine first, under TCG and HVF, then on the Raspberry Pi 4
Model B, then on the Raspberry Pi 5. The key idea is that a board is data:
the kernel discovers every device from the device tree, drives a fixed set
of devices named in one generated table, and differs from one platform to
the next only in its early console, and the manifest says which domain
holds each other device, so adding a board adds table entries, drivers, a
manifest and this document's facts, never a branch in generic code. The
processor architecture these platforms share is described in its own
binding, [design-arch-aarch64.md](design-arch-aarch64.md), and the kernel
in [design-kernel.md](design-kernel.md).

Decisions every reader of this document needs:

* **Three platforms, in order.** QEMU `virt-11.1` under TCG and HVF, the
  Raspberry Pi 4 Model B, and the Raspberry Pi 5
  ([design.md](design.md#portability)).
* **One interrupt path under both accelerators.** The harness pins the
  machine type (`virt-11.1`), uses a GICv3 under TCG and HVF, gives TCG
  `msi=gicv2m` so that both route MSIs as HVF's in-kernel GIC does, and
  starts HVF guests with `-cpu host`; HVF's GIC offers a GICv3 without an
  ITS ([research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf),
  [research](research-hierarchical-scheduling.md#fiasco-under-hvf)).
* **Board facts come from the device tree.** The kernel reads devices,
  memory, the boot image's place and the boot arguments from the tree the
  loader passes; no board is recognised by name
  ([design-kernel.md](design-kernel.md#boot)).
* **One table of the devices the kernel drives.** `hw/kernel_devices.txt`
  names them by compatible string and role, and every list of them is
  generated from it or points at it
  ([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
  Every other device, the console's and the host link's UARTs included,
  goes, through the device service, to an Erlang driver over the device
  NIF in the domain the manifest names
  ([design-system.md](design-system.md#drivers)).
* **One kernel build per platform, differing only in the early console's
  kind and address**, those of the board's documented console UART, which
  the kernel writes by polling: its boot messages, its panic report, the
  crash record and the final line of every end of the machine. The boot
  stops unless `/chosen/stdout-path` names that UART, the console's,
  which the manifest's `console` field names too and the console's Erlang
  driver drives the rest of the time ([UARTs](#uarts)).
* **The system manifest says where each device goes.** Each platform's
  system manifest ([design-system.md](design-system.md#the-manifest))
  lists the devices the platform has and gives each to one domain: the
  block device to storage, the network device to network, the TPM, with
  the SPI controller it sits on, to the vault, the console's and the host
  link's UART units to the system domain, the other slow devices to the
  devices domain, PCIe configuration space alone to the PCIe domain, and,
  in a release build, each device whose DMA no IOMMU confines to a domain
  of its own. Whether a platform has an IOMMU decides which of its devices
  the manifest must treat as unconfined, and the platform's placement
  table marks which are `hostile` ([What the manifest
  says](#what-the-manifest-says)).
* **The same firmware interface everywhere.** Every platform starts CPUs
  and ends the machine through PSCI, from QEMU itself or from TF-A's BL31
  on the boards. A fault of the system domain and a missed deadline of
  the kernel's watchdog end the machine the same way, after a crash
  record, as `erx.panic` says: by `SYSTEM_RESET` in release builds, and
  by a halt in development builds, which a board's hardware watchdog
  turns into a reset ([The watchdog](#the-watchdog)).
* **The boards' DMA devices are unconfined.** No IOMMU covers them, so
  each of their drivers holds a device whose DMA reaches all memory. A
  release build's system manifest allows unconfined DMA only for the
  devices it names, and gives each such device a domain of its own, so no
  domain that parses hostile media or packets holds a device that is the
  whole machine; the build's manifest check fails on a manifest that does
  otherwise ([DMA](#dma)).
* **A boot is as trustworthy as its trust root.** QEMU's is the host; a
  board's is its boot ROM when secure boot is on, and nothing when it is
  off ([Trust in the boot](#trust-in-the-boot)).
* **A board's key is read once, at boot.** Code in the kernel's boot-only
  section, unmapped before the system domain starts, turns a provisioned
  board's OTP key into the device secret it hands the system domain, and
  never writes OTP ([Device secrets](#device-secrets)).

## Context

The kernel's platform layer owns device-tree discovery and the devices the
kernel drives itself: the interrupt controllers and MSI frames, the
timer, the real-time clock, the IOMMU, and on the boards the random
generator, the watchdog and the firmware's mailbox; and the early console,
which it only writes ([design-kernel.md](design-kernel.md#portability)).
Every other device goes to an Erlang driver, a supervised process over
the device NIF, in the domain the manifest names, through the device
service ([design-system.md](design-system.md#devices)); the drivers and
their table are in [design-system.md](design-system.md#the-driver-table),
and the manifest in [design-system.md](design-system.md#the-manifest).
The facts here come from the research records, which state the sources
they were checked against: [research-baselines.md](research-baselines.md)
for QEMU and [research-boards-storage.md](research-boards-storage.md) for
the boards; the facts about device secrets, TPMs and secure boot cite
their primary sources, Raspberry Pi's white papers, its `usbboot`
documentation and QEMU's TPM documentation, directly
([References](#references)).

## Requirements

1. Boot erXos on each platform by the boot protocol of its architecture
   ([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)), from the
   loader the platform has.
2. Drive each platform's devices of `hw/kernel_devices.txt`, and leave
   every other device to the device service and the Erlang drivers it
   places.
3. State, for each platform, which devices it has, which domain holds
   each by default, whether it has an IOMMU, and so which devices its
   manifest must treat as unconfined.
4. Give every platform the same kernel interface: no call, right or
   status code differs between platforms.
5. Start CPUs, turn the machine off and reset it through the firmware on
   every platform; request a system update's trial where the platform can.
6. Keep the firmware out of every driver's reach, and the operator's
   terminal out of every domain's but the one that holds the console.
7. Hand the system domain the platform's device secret where the board
   holds a key, and say that there is none where it does not.
8. State, for each platform, what checks a boot before the kernel runs,
   and what holds where nothing does.
9. End the machine as `erx.panic` says when the system runtime stops
   petting the kernel's watchdog or the system domain faults, after a
   crash record; on a board with a hardware watchdog, reset also when the
   kernel itself hangs or has halted; keep the crash record across the
   reset where the board can, and say where it cannot.

Non-goals: platforms of other architectures, which their own bindings
describe; boards beyond these three, which [plan.md](plan.md#beyond-the-plan)
lists; and the drivers of the boards' devices above the kernel, which
belong to the driver table of
[design-system.md](design-system.md#the-driver-table).

## Overview

| | QEMU `virt` | Raspberry Pi 4 Model B | Raspberry Pi 5 |
| --- | --- | --- | --- |
| SoC and cores | QEMU's `virt-11.1`, `-cpu host` under HVF | BCM2711, Cortex-A72 | BCM2712, Cortex-A76, with RP1 behind PCIe |
| Loader | QEMU's `-kernel` with the single bootable file, or with `-initrd` in the two-file form; U-Boot's `booti` | the Raspberry Pi firmware, the single file as `kernel8.img` | the Raspberry Pi firmware, the single file as `kernel_2712.img` |
| Interrupt controller | GICv3 | GIC-400, a GICv2 | GIC-400, a GICv2 |
| MSI frame | GICv2m | none used | MIP (`brcm,bcm2712-mip`) |
| Early console, also the console | PL011 | mini UART | debug PL011 |
| Host link | a second PL011 | UART3, a PL011 that `config.txt` routes | none |
| IOMMU | SMMUv3, for PCIe only | none described | none assigned to Ethernet, USB or the SD controllers |
| PCIe bridge | ECAM (`pci-host-ecam-generic`) | `brcm,bcm2711-pcie`, for the VL805 alone ([design-usb.md](design-usb.md#the-bcm2711-bridge)) | `brcm,bcm2712-pcie` |
| PCIe configuration space held by | the PCIe domain, alone | the PCIe domain, alone | the PCIe domain, alone |
| Random generator | none; `/chosen/rng-seed` | RNG200 | RNG200 |
| Watchdog | none; the kernel's timer alone | power-management watchdog | power-management watchdog |
| Crash record | the early console, whose log the harness keeps | the early console, and the crash region in RAM | the early console, and the crash region in RAM |
| Unconfined DMA devices, each in a domain of its own in a release build | the virtio-mmio devices | the SD controller, Ethernet, the VL805 | the SD controllers, RP1, a function on the external connector |
| USB | `qemu-xhci`, a PCIe function on the root bus ([design-usb.md](design-usb.md)) | the VL805, behind the BCM2711 bridge, through the PCIe domain ([design-usb.md](design-usb.md)) | RP1's two USB hosts |
| PSCI from | QEMU | TF-A's BL31, from the boot partition | TF-A's BL31, in the firmware |
| Trial request | the harness | the firmware's mailbox | the firmware's mailbox |
| Device secret | none | the OTP key, when provisioned | the OTP key, when provisioned |
| TPM | swtpm as `tpm-tis-device`, when the harness attaches one | an optional SPI module | an optional SPI module |
| Boot trust root | the host | the boot ROM with secure boot, otherwise none | the boot ROM with secure boot, otherwise none |

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **PL1.** Platforms differ only in data and in the early console's kind and address | the kernel discovers devices from the device tree and drives only the devices of `hw/kernel_devices.txt`, each by its compatible string; each platform's manifest is data the build packs; each platform's kernel build differs only in the early console's kind and address, and the boot stops unless the device tree's `/chosen/stdout-path` names that UART | a board check in generic code; a driver chosen by board name | a source check that generic code names no platform; the same conformance suite on every platform |
| **PL2.** No driver reaches the firmware, and only the system domain holds the console's UART | the kernel keeps the register pages of the devices it drives, the mailbox among them, and no other node whose registers touch a kept page enters the root resource; devices whose registers share a page or whose interrupts arrive on one line form one unit, which goes whole to the one domain the manifest places it on, so no page and no line is held by two domains ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)); every manifest places the console's UART unit in the system domain, and the build's manifest check fails on one that does not | a device table without the mailbox; a resource carved across a kept page; a unit split between two domains; a manifest that places the console's unit in another domain | the boot log names every node left out; a test that the left-out nodes appear in no resource; the boot test in which a manifest that splits a unit is refused for that unit; the build's refusal of a seeded manifest whose two units share only a line; the manifest test that seeds the console's unit into the devices domain and expects the build to fail |
| **PL3.** Every platform ends the machine and starts CPUs through PSCI | QEMU provides PSCI; the Pi 5's firmware carries BL31; the Pi 4's boot partition adds it; the kernel stops a boot that finds no PSCI node | a platform whose firmware lacks PSCI | the boot's PSCI check; the end tests of each platform |
| **PL4.** On a board with a hardware watchdog, a kernel that stops running resets the machine | the platform layer reloads the hardware watchdog only from the kernel's timer, for as long as the kernel runs, and never stops it, so a kernel that stops taking interrupts, or has halted after a crash record, stops reloading it | a reload from anywhere but the timer; a path that stops the watchdog; a timeout shorter than the timer's period | on each board, a kernel hung with interrupts masked resets and boots again; the chokepoint check that the watchdog's registers are written only in its driver, with a seeded second writer |

## Data model

**The device table.** `hw/kernel_devices.txt` lists, by compatible string
and role, every device the kernel drives on any platform; the kernel binds
each entry it finds in the device tree to its node and keeps the node's
register pages
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
The PCIe bridges are not among them: the PCIe enumerator, an Erlang
process in the PCIe domain, drives them and alone holds the
configuration window
([design-system.md](design-system.md#devices), [What the manifest
says](#what-the-manifest-says)). The entries for these platforms:

| Role | Compatible strings |
| --- | --- |
| interrupt controller | `arm,gic-v3`, `arm,gic-400` |
| MSI frame | `arm,gic-v2m-frame`, `brcm,bcm2712-mip` |
| timer | `arm,armv8-timer` |
| real-time clock | the PL031 |
| IOMMU | `arm,smmu-v3` |
| random generator | `brcm,bcm2711-rng200` |
| watchdog | `brcm,bcm2835-pm-wdt` |
| firmware mailbox | `brcm,bcm2835-mbox` |

The early console is not in the table: the platform's kernel build fixes
its kind and address, the kernel checks that the device tree's
`/chosen/stdout-path` names that UART, and it keeps none of its
registers, so the console's UART reaches the root resource and its
driver like any other device ([UARTs](#uarts)).

The table also records each machine's **fixed buses**, by the root node's
compatible string: the PCIe buses whose requester ids the machine's DMA
contract shows the fabric fixes ([DMA](#dma)). For QEMU `virt`
(`linux,dummy-virt`) that is its ECAM bridge's root bus. The boards record
none, and a machine the table does not name has none, so its PCIe
functions are unconfined.

**The crash region.** On the boards, each slot's device tree reserves a
region of RAM under `/reserved-memory`, compatible `erxos,crash-region`,
that a reset through `SYSTEM_RESET` leaves intact; the kernel leaves it
out of the direct map and of every budget, writes the crash record there
before the machine ends and reads it at the next boot
([The crash record](#the-crash-record)). QEMU `virt` reserves none: a
reset under `-no-reboot` exits the emulator, and the early console's log
is what survives. The kernel finds the region by its compatible string, as
it finds a device, so a board without one has no branch in generic code
(PL1).

**What the loader hands over.** The device tree's `/chosen` node gives the
boot arguments, the boot image's range, `rng-seed`, `kaslr-seed`,
`stdout-path`, and, from firmware that boots one of two slots,
`bootloader/partition` and `bootloader/tryboot`, from which the kernel
derives the boot value ([design-storage.md](design-storage.md#system-updates)).
Each is one 32-bit cell, as the Raspberry Pi firmware writes them: the
number of the partition booted, its entry's index in the master boot
record counted from 1, and 1 for a trial or 0 for any other boot. The
kernel maps the partition to a slot by `medium_slot_a_partition` and
`medium_slot_b_partition` of `abi/medium.txt`; a missing property, a
property of another length, a `tryboot` other than 0 or 1, or a partition that is not a slot
gives `unknown`.

## Algorithms and behavior

### QEMU virt

QEMU `virt-11.1` runs under TCG and under HVF on the primary host, with
`-cpu host` under HVF, a GICv3 with a GICv2m frame for MSIs, the EL1
virtual timer on INTID 27, a PL011 console at `0x09000000`, a PL031,
virtio-mmio devices, an ECAM PCIe bridge with an SMMUv3 that translates
only PCIe devices and offers stage 1, 4 KiB pages, 16-bit ASIDs, PSCI by
the device tree's method, and boot entropy from `/chosen/rng-seed`, 32
bytes ([research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf),
[measured](research-baselines.md#accelerator-capabilities)). The counter
runs at 62.5 MHz under TCG and 24 MHz under HVF. HVF enters the kernel at
EL1 and its CPU feature registers report no GIC, so the kernel finds the
interrupt controller only from the device tree. A second `-serial` option
creates the host-link UART, which QEMU's manifest names as the host link
by its device-tree path. The machine has no watchdog, so the kernel's
timer alone covers the system runtime ([The watchdog](#the-watchdog)), and
the harness plays the firmware's part in a trial.

### Raspberry Pi 4 Model B

The BCM2711, with Cortex-A72 cores and a GIC-400. The console is the mini
UART (`brcm,bcm2835-aux-uart`), the Pi 4's early console, on the header's
GPIO 14 and 15. The board wires UART0, the first PL011, to its Bluetooth
chip, and `enable_uart=1` puts GPIO 14 and 15 in the mini UART's function,
ALT5, whatever `gpio=` lines in `config.txt` ask for them; with
`enable_uart=0` neither UART reaches the header and nothing, BL31
included, prints (both seen on a 4 GB board). Linux's device tree for the
board names UART0 `serial0` and the mini UART `serial1`, the firmware
leaves those aliases as the card's tree has them, and BL31 points
`/chosen/stdout-path` at `serial0` (TF-A's `plat/rpi/rpi4/rpi4_setup.c`),
so the card's tree swaps the two aliases: `serial0` names the mini UART
and `serial1` UART0, and the build refuses a platform record whose
console is not the card's `serial0`. The mini UART's baud rate is divided from the core
clock, which the firmware may change at run time, so the board's
`config.txt` sets `enable_uart=1`, which has the firmware pin the core
clock and set the mini UART's line; the early console, Fiasco's
console on the stopgap and the Erlang mini-UART driver keep the divisor
the firmware set and never compute one, so no core clock rate reaches
the platform record. The PL011s' clock does: each PL011's entry in the
record carries its clock in hertz, from its node's `clocks`, and
`erx_pl011` divides 115200 baud from it for a PL011 the firmware leaves
unprogrammed, as it leaves UART3
([design-abi.md](design-abi.md#devices-and-partition-windows)). The host link is UART3, a PL011 on GPIO 4 and 5,
which `dtoverlay=uart3` in `config.txt` enables in the device tree; the
firmware sets no pins from an overlay, so `config.txt`'s `gpio=4=a4,pn`
and `gpio=5=a4,pu` lines put the pins in UART3's function; UART2, the other PL011
with pins of its own, sits on GPIO 0 and 1, the bus of a HAT's
identification EEPROM, which the firmware reads at boot. The manifest
names the host link by its device-tree path, so no `serialN` alias ever
makes it the console's UART. The five PL011s
share one register page and one interrupt line, and the mini UART shares
its page and its line with the auxiliary SPI controllers and the
auxiliary block's enable and interrupt-status registers, so each group is
one unit ([design-shared-devices.md](design-shared-devices.md#context)).
The manifest gives each unit whole to the domain of the UART it carries:
the system domain, for the console and for the host link. There each
unit has one driver, the mini UART's and UART3's, each on a line no other
driver of the domain names, and the system domain runs no driver for the
auxiliary SPI controllers or the other PL011s. The VideoCore's message interface shares the
mailbox's page, which the kernel keeps, so it goes to no driver (PL2,
[research](research-boards-storage.md#checks-against-local-copies)). The
devices erXos drives use wired interrupts. No IOMMU is described, so its
Ethernet controller (`brcm,bcm2711-genet-v5`) and its SD controller
(`brcm,bcm2711-emmc2`) are unconfined, and a release build's system
manifest gives each of them a domain of its own ([DMA](#dma)).

**The Ethernet controller's unit.** GENET is `/scb/ethernet@7d580000`:
`0x10000` bytes of registers at bus address `0x7d580000`, which `/scb`'s
`ranges` put at `0xfd580000`, and two level interrupts, GIC SPIs 157 and
158, which no other node names (Linux 6.18's `bcm2711.dtsi:545-551,
587-594`). The platform record's unit `net` is that register page and the
first line alone: FreeBSD's driver drives the default queue's interrupts
on the first and only logs the second (`if_genet.c:314-322, 1526-1531`),
so the second goes to no unit and no domain can wait on it. Its
device-kinds row makes its record `net genet`, the CMSIS-SVD peripheral
of `hw/svd/genet/genet.svd`, whose registers are FreeBSD's
(`if_genetreg.h`). The record marks the controller unconfined and
`hostile`, with 1 MiB of DMA memory: 256 receive and 256 transmit buffers
of 2 KiB. Its PHY is at MDIO address 1, with no interrupt, on RGMII with
the receive delay (`bcm2711-rpi-4-b.dts:198-208`); neither fact is in the
record.

**The framebuffer's unit.** The platform record's unit `framebuffer` is
one row of the `framebuffer` role at `/chosen` for a `simple-framebuffer`
child, with no line and no DMA
([design-device-tree.md](design-device-tree.md#facts-into-records)). Its
window is the memory between the RAM the firmware reports and the end of
the card's `total_mem`, 76 MiB from `0x3b400000` to `0x40000000`: the
1024 MiB `total_mem` less the 76 MiB of `gpu_mem`, which the firmware
keeps for the VideoCore out of the RAM it reports, as bootstrap's memory
line in the board pass shows. That the firmware puts the framebuffer
there is unverified; the board pass's `framebuffer absent outside BASE
SIZE` line, which names where it put it, settles it. The window meets no
register window and no RAM of the record, which the manifest check proves
of every framebuffer row, placed or not.

**The SD controller.** The microSD slot is EMMC2,
`/emmc2bus/mmc@7e340000`: `0x100` bytes of registers at bus address
`0x7e340000`, which the bus's `ranges` put at `0xfe340000`, a level
interrupt on GIC SPI 126, and a clock of the SoC's clock controller with
no frequency in the tree (Linux 6.18's `bcm2711.dtsi:418-432`). Its
device-kinds row makes its record `block sdhci`, and the block driver
drives it by programmed I/O
([design-storage.md](design-storage.md#the-sd-host-controller)) until
its record carries DMA memory, which it does on both kernels at the range
the firmware sets for the board, read from the tree the firmware hands
over ([design-device-tree.md](design-device-tree.md),
[design-device-dma.md](design-device-dma.md#device-addresses-and-reach)). The tree
marks its card-detect line broken and gives the card's supply and its
I/O voltage as regulators on the firmware's GPIO expander
(`bcm2711-rpi-4-b.dts:26-48, 190-196`), which no domain reaches (PL2):
the card is powered and at the signalling the firmware left. GIC SPI 126
is also the interrupt of the legacy SD controller, `&sdhci`
(`bcm2711.dtsi:1147-1149`), so by the unit rule the two controllers are
one unit, given whole to the storage domain
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)), and
the record marks the line shared. The SD device process attaches through
the line's owner, `erx_irq_line`, of which it is the one member, as every
driver on a shared line does
([design-shared-devices.md](design-shared-devices.md#lines-inside-a-domain));
the legacy controller has no driver, as the SPI controllers on the mini
UART's line have none. The platform record's unit `sd` holds both
windows, EMMC2's at `0xfe340000` and the legacy controller's,
`/soc/mmc@7e300000` (`bcm283x.dtsi:423-429`), at `0xfe300000`, each
`0x100` bytes on record line 158 (GIC SPI 126, at the binding's offset of 32,
unverified on the board). Its device-kinds row makes EMMC2's record
`block sdhci`, the CMSIS-SVD peripheral of `hw/svd/sdhci/sdhci.svd`;
the legacy controller, the board's Wi-Fi SDIO host (`non-removable`,
`mmc-pwrseq = <&wifi_pwrseq>` in the board's tree), matches no row and
gets no record; whether it can master the bus is for the board probe.
The record marks EMMC2 unconfined and `hostile`, with 1 MiB of DMA
memory for the ADMA2 mode, as the virtio block device's. A
manifest gives the unit to the storage domain as its unit `block`, the
name `storage_ctl` acts on. The VL805
USB controller sits behind the Pi 4's PCIe bridge, which the PCIe domain
drives; the USB domain holds it by its position, with the INTx line that
position routes, unconfined and `hostile`
([design-usb.md](design-usb.md#the-bcm2711-bridge)). Its cores have the CRC32
instructions but not the cryptography extension, so SHA-256, which every
EROFS block's check needs, runs in portable C on it
([design-storage.md](design-storage.md#performance)).

**The Ethernet controller.** GENET's driver decides in three pure
Erlang cores beside the network transports in
`erlang/apps/erx_net/erxos/`; the transport around them, which reads
and writes the registers, comes with the controller's own design.
Register facts are FreeBSD's (`if_genet.c`, `if_genetreg.h`,
`brgphy.c`, `brgphyreg.h`, `mii.h`, `miidevs`):

* `erx_genet_rx` reads one receive completion of the device NIF, the
  descriptor status's flags and the bytes the controller wrote, a
  private copy the frame keeps alive, into a frame or a drop with its
  reason. The length is the size of those bytes, so no length can
  disagree with them; it counts the two bytes of padding the controller
  writes before the frame, so a frame is at most the 2 KiB buffer less
  those two bytes. Flags with an error bit or without both start and end
  of packet, or fewer bytes than the padding and an Ethernet header, or
  more than the buffer, are dropped. The NIF consumes every descriptor,
  frame or drop, so a bad frame never stalls the ring, and refuses a
  producer index more than a ring ahead and a length past the buffer as
  controller faults ([design-device-dma.md, "The register ring (GENET)"](design-device-dma.md#the-three-descriptor-forms)).
* `erx_mdio` builds the MDIO command word of a clause 22 read or write
  (busy 29, read failed 28, read 27, write 26, PHY 25:21, register
  20:16, data 15:0) and decides each poll of it: wait while busy, up to
  1,000 polls 10 us apart, then the data, `read_failed` or `timeout`.
* `erx_phy_c22` is the PHY's state machine: a function from its state
  and the result of its last MDIO operation to its next state, its next
  operation and its reports. It resets the PHY, refuses any PHY but the
  BCM54213PE (OUI `0x18c086`, model `0x0a`) with its ID, sets the
  receive clock delay the board's `rgmii-rxid` wiring asks for
  (`RGMII_SKEW_EN` in auxiliary control shadow 7, `GTXCLK_EN` clear in
  shadow `0x1C`), advertises full duplex only, since the controller's
  command register has a speed field and no duplex field (FreeBSD's
  `if_genetreg.h:75-92`; unverified on the board), and autonegotiates. It then polls the link every
  second, reading the status register twice because its link bit
  latches low, and reports `{link, up, Speed}` for the auxiliary status
  register's full-duplex resolution with that register's link bit set, `{link, down}` at every drop, and
  `{failed, Reason}` at an MDIO error, after which the driver restarts.

### Raspberry Pi 5

The BCM2712, with Cortex-A76 cores and a GIC-400, and RP1, the I/O
controller, behind the BCM2712's PCIe root complex. RP1's devices
interrupt by MSI-X through Broadcom's MIP block, which raises SPIs 128 to
191 and which the kernel drives as it drives the GICv2m frame on QEMU
([research](research-boards-storage.md#raspberry-pi-5-bcm2712-and-rp1)).
The Pi 5's only PL011 outside RP1 is its debug UART, the console, and its
manifest names no host link, since RP1's UARTs belong to RP1's unit, which
holds RP1's DMA devices too: code from the host and the live tools do not
reach the Pi 5, development updates arrive over the network signed with
the build tree's development key
([design-storage.md](design-storage.md#system-updates)), and its first
image is written to its medium on the host. RP1's devices sit behind one
PCIe function, so RP1 is one unit, which the manifest places on one domain,
whose creation gives it whole ([design-system.md](design-system.md#drivers)). Its tree
assigns no IOMMU to RP1 or to the SD controllers, so a release build's
system manifest gives RP1 and each SD controller a domain of its own
([DMA](#dma)). Its cores have the AES, PMULL, SHA-1, SHA-2 and CRC32
instructions.

### Boot

Every platform boots the single bootable file, the first stage with the
archive inside it ([design-kernel.md](design-kernel.md#the-bootable-file)),
and the first stage finds the archive from its own boot locator.
QEMU's `-kernel` loads a file with an arm64 Image header whose
`text_offset` is 0 at `0x40200000` and passes the device tree's physical
address in `x0`; with no `-initrd`, the device tree sits at RAM base
plus the smaller of half the RAM and 128 MiB, `0x48000000` from 256 MiB
of RAM up ([measured](research-baselines.md#boot-conventions)), so a
single file up to 126 MiB long lies below it at those sizes. For a longer
file QEMU puts the device tree at the next 2 MiB boundary behind the file
([measured](research-baselines.md#boot-conventions)). The stand-in root
is a fixed image, and its place belongs to the machine an image is built
for (`ProductionImage::Machine`, through the one linker symbol
`liberx/backend/fiasco/root.ld` takes from the link). The development
machine, 512 MiB, links it 64 MiB into RAM, below the device tree at 128 MiB,
which bounds the single file to about 62 MiB and keeps the root inside small machines; below 256 MiB
the device tree sits at half of RAM, so on a machine of roughly 127 to
137 MiB it lands on the root and bootstrap refuses the boot with
`place_overlap`. The QEMU oracle's machine, 2 GiB, links it 192 MiB into
RAM, which bounds the single file to about 188 MiB. In the two-file
form, for debugging, `-initrd` on the oracle's machine places the boot
image at `0x48000000` with the device tree directly after it; the root
must lie clear of both, as the oracle's does above them, which bounds
that archive to about 63 MiB. Either way the
kernel reads every address and assumes none. U-Boot's `booti`
implements the same protocol. The Raspberry Pi firmware loads the single
file by the same protocol (`kernel8.img` on the Pi 4, `kernel_2712.img`
on the Pi 5), with no `initramfs` line in `config.txt`, and enters it at
EL2 with the device tree in `x0`. Whether the firmware honours
`image_size`, where it places the device tree relative to a file tens of
MiB long, the largest kernel file it loads, the CPU's state at entry and
the memory map are confirmed on each board by the boot probe at its
port's first boot, with a single file of the size the port's release
needs, and recorded in a research record as they were for QEMU, before
anything depends on them; the locator's overlap check stops a boot whose
device tree landed on the archive. The early console's kind
and address, the only difference between the platforms' kernel builds,
are on QEMU `virt` the PL011 at `0x09000000`, the one its `stdout-path`
names; each board port fixes its own ([UARTs](#uarts)). The kernel starts one user-mode task, the system
domain, from the root capabilities `liberx`'s root-task entry receives
([design-kernel.md](design-kernel.md#the-root-task)); the platform layer
contributes the device list of the root resource, the device-secret page
and, on the boards, the crash record of the boot before.

### The devices the kernel drives

The device table above lists them. A device whose registers share a page
with one of them stays out of the root resource and the boot log names it
(PL2); on the Raspberry Pi 4 that is the VideoCore's message interface
beside the mailbox. Devices whose registers share a page with each other,
and none with a kept device, or whose interrupts arrive on one line, form
one unit that goes to one domain, as the Raspberry Pi 4's PL011s do, and
its mini UART with the auxiliary SPI controllers
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).

### UARTs

The **early console** is the board's documented console UART, whose kind
and address the platform's kernel build fixes: on QEMU `virt` the PL011
at `0x09000000`, on the Raspberry Pi 4 the mini UART
(`brcm,bcm2835-aux-uart`), which `enable_uart=1` puts on the header's
console pins, and on
the Raspberry Pi 5 its debug PL011. The kernel writes it from the first
step of its boot, so every stop of the boot prints its reason, and stops
the boot, with a message on that UART, when `/chosen/stdout-path` names
another; the rule and its one cost are the kernel's
([design-kernel.md](design-kernel.md#console-log-and-panic)).
The kernel keeps no register page of it: it writes it by polling its
transmit register, through a mapping it makes for those writes, with a
bound on each byte, and never reads it: during boot, before it starts the
root task, and afterwards only at a panic and at an end of the machine,
after it has stopped every other CPU, for the report, the crash record and
the final line
([design-kernel.md](design-kernel.md#console-log-and-panic)). Between
those writes the UART belongs to its driver. A driver can leave the UART
in any state, so the bound per byte is what lets an end of the machine
finish whatever the driver did; the report is then lost on the console,
and on a board the crash region still keeps the record.

The **console** is the UART the manifest's `console` field names by its
device-tree path, and the **host link** the one its `hostlink` field
names likewise. Every manifest, release and bring-up alike, places both
UARTs' units in the system domain, and the build's manifest check fails
on one that places either anywhere else or names one UART for both. At
boot the device service refuses a manifest whose `console` path is not
the UART `/chosen/stdout-path` names, so the console is always the early
console's UART and the host link never is, whatever the tree's `serialN`
aliases say ([design-system.md](design-system.md#devices)). In
the system domain an Erlang UART driver over the device NIF feeds the
console service: a domain reads what the operator types only while its
session is connected, never a passphrase typed at the login prompt, and
writes to the operator only through a connected session's tty; the
host-link service
reads the host link's UART there too, on QEMU `virt` as on the Raspberry
Pi 4 ([design-system.md](design-system.md#drivers)). The console's line
carries a tty's bytes unread
([design-live.md](design-live.md#the-console)).

### MSI frames

QEMU `virt`'s GICv2m frame is written with the SPI number at its doorbell,
`MSI_SETSPI_NS` at offset `0x40`, and serves TCG (`msi=gicv2m`) and HVF,
whose in-kernel GIC has no ITS
([research](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf)). The
Raspberry Pi 5's MIP block raises SPIs 128 to 191. The Raspberry Pi 4's
devices that erXos drives use wired interrupts, so it needs no frame.

### DMA

A DMA device's driver is an Erlang process over the device NIF in the
domain the manifest names, and the device's capabilities, its register
windows, IRQ objects and DMA window or contiguous memory, are installed
into that domain and no other
([design-system.md](design-system.md#drivers)). What the device's DMA can
reach decides where the manifest may put it. A **confined** device reaches
only the memory its DMA window maps, so its driver may share a domain with
the service that uses it: the storage domain holds its block device, the
network domain its network device. An **unconfined** device, one without
an IOMMU stream, reaches all memory through its registers alone, so the
domain that holds its driver is in the trusted base however little code it
holds; a release build's system manifest gives such a device only when it
names it by path, and then to a domain of its own, holding that device's
unit, its drivers and nothing else, with the service that uses it, the
file system or the network stack that parses hostile media or packets, in
another domain reached over a connection. A development build's system
manifest may merge them. This is one rule of configuration and no
mechanism: a device goes where its capabilities are installed, the device
service installs them where the manifest says, and the build's manifest
check fails on a release build's system manifest that gives an unconfined
device to a domain that parses hostile input
([design-system.md](design-system.md#the-manifest)).

Confined devices are QEMU `virt`'s PCIe functions on its root bus, behind
its SMMUv3; its virtio-mmio devices are unconfined. No IOMMU is described
for the Pi 4, and the Pi 5's tree assigns its IOMMUs to neither RP1 nor
the SD controllers, so every DMA device on both boards is unconfined, and
a release build's system manifest for either names each one it gives and
gives its unit
a domain of its own. DMA devices see memory through the `dma-ranges` of
their buses: on the Pi 4 the SD controller and the legacy peripherals see
the first GiB of RAM at bus address `0xC0000000` in Linux's tree
(`bcm2711.dtsi:45, 424`), Ethernet, on `scb`, which has no `dma-ranges`,
sees RAM at the CPU's addresses (`bcm2711.dtsi:545-594`), and PCIe sees
3 GB ([research](research-boards-storage.md#checks-against-local-copies))
through its bridge's `dma-ranges`, whose PCI addresses take three cells,
which the walk of
[design-kernel.md](design-kernel.md#dma-and-the-iommu) reads at a PCIe
function's host bridge, so the VL805 behind the Pi 4's bridge gets that
range; its driver keeps every buffer below 960 MiB, the limit FreeBSD
found, until a board probe shows where the bridge's real limit is
([design-usb.md](design-usb.md#the-bcm2711-bridge)). The
firmware rewrites the SD controller's range according to the SoC's
revision, which the tree's `emmc2bus` alias asks of it
(`bcm2711.dtsi:411-417`, `bcm2711-rpi.dtsi:14`), so only the tree the
firmware hands over at boot gives that range for a given board. No
device in Linux's tree for the Pi 4 is `dma-coherent`, so every DMA device
of the board needs the device NIF's cache maintenance; QEMU `virt` marks
every virtio-mmio node `dma-coherent`, and its DMA is coherent. Each DMA
device's record carries its coherence and its range, read at boot from
the tree the firmware hands over, on the stopgap as on erXos's kernel
([design-device-tree.md](design-device-tree.md),
[design-device-dma.md](design-device-dma.md#device-addresses-and-reach)). The
contiguous pool, from the lowest RAM, serves devices with an address
limit, such as the Pi 4's legacy DMA below 1 GiB. The `dma-ranges` reader
is host-tested with the trees of QEMU `virt`, both BCM2711 steppings and
the BCM2712.

**The DMA contracts.** The kernel's DMA guarantees hold only for what an
IOMMU confines ([design-kernel.md](design-kernel.md#dma-and-the-iommu)),
so each platform states, for every bus master, what confines it and what
does not. A function behind an IOMMU is confined only on a bus whose
requester ids the contract shows the fabric fixes, so that no function
presents another's; the device table records those buses as the machine's
fixed buses, and every other function is unconfined
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
Every platform requires its loader to quiesce every bus master before
entry, as Linux's arm64 boot protocol requires, and to leave each IOMMU
with translation off and its queues stopped. The kernel stops the boot,
before it reclaims any memory, on an IOMMU it finds translating or with
a queue running, and on one that lacks a feature its driver needs. It
then makes the IOMMU abort every transaction, invalidates every
configuration and translation cache through its own queue while that
abort holds, and enables translation only after a completed sync. A
device whose reset fails is not given to another driver. A protocol
requirement is not evidence that a particular firmware meets it: source
evidence and pending loader and hardware tests are distinguished in [the
hardware-contract audit](research-hardware-contracts.md). A bus master
whose handover the recorded evidence does not establish is listed as
unknown, and a platform with one is admitted by build: development
builds boot on it, since they run trusted code only, say so in their
banner and never ship, and the gap is an open security residual in
`TODO.md`; release builds refuse the platform until the evidence its
contract names is recorded for each loader release the port supports
([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)).

**The SMMUv3 is QEMU's.** The kernel's SMMUv3 driver covers what QEMU
`virt`'s model needs: one SMMU, stage 1, 4 KiB pages and 16-bit ASIDs,
found with translation off. Taking over an SMMUv3 that firmware left
translating, waiting out its outstanding accesses, reading its error
records and the features QEMU's model lacks belong to the port of a board
that has one, behind the same driver interface
([design-kernel.md](design-kernel.md#dma-and-the-iommu)); neither
Raspberry Pi has one.

| | QEMU `virt` | Raspberry Pi 4 | Raspberry Pi 5 |
| --- | --- | --- | --- |
| Bus masters | PCIe functions behind the ECAM bridge; virtio-mmio devices, whose DMA QEMU performs for them | the SD controller, the legacy and large-address DMA engines, Ethernet, the VL805 USB controller behind the PCIe bridge, which the USB domain drives and whose handover is unknown: the EEPROM's boot order names the microSD card alone, so that the boot firmware has no reason to start it, but until the firmware's documented behaviour for that order and a reading at the kernel's entry are recorded for the supported firmware release, the VL805 counts as possibly running at entry ([design-usb.md](design-usb.md#the-bcm2711-bridge)), and the firmware, which stays resident with access to all memory ([Firmware](#firmware)); every master's handover is unknown until its evidence is recorded, so development builds boot on the board, the gap an open security residual, and release builds refuse it | RP1's devices behind PCIe, Ethernet and two USB hosts among them; the SD controllers; a function on the external PCIe connector; the media blocks behind the BCM2712 IOMMUs; the firmware, which stays resident with access to all memory ([research](research-boards-storage.md#raspberry-pi-5-bcm2712-and-rp1), [Firmware](#firmware)) |
| Translation | the SMMUv3, stage 1, for functions on the root bus, which the harness creates with `iommu=smmuv3`; nothing for virtio-mmio | none described ([research](research-boards-storage.md#raspberry-pi-4-model-b-bcm2711)) | none for Ethernet, USB, the SD controllers or the external connector; each BCM2712 IOMMU serves media blocks or RP1's camera and display paths, with one address space for all its devices |
| Bypass | none: the driver sets the global bypass to abort before anything else, and a stream without a window aborts | every master | the BCM2712 IOMMUs pass addresses below their windows through untranslated |
| Requester identity | fixed on the ECAM root bus: `smmu_get_sid` builds the id from the model's bus and `devfn`; `pcibus_num` fixes the root bus at zero, whereas a subordinate bus takes its number from writable bridge configuration. Each root-bus function is its own isolation group. This is source-checked in QEMU v11.1.2; the supported binary must pass the same contract tests before its confined profile is admitted ([audit](research-hardware-contracts.md)) | none used | none per device |
| Interrupts and MSI writers | MSIs through the GICv2m frame, which takes the line from the value written, so the functions that share it share one trust boundary for interrupts; wired lines for virtio-mmio | wired lines through the GIC-400; no MSI used | RP1's MSI-X through the MIP block, which takes the line from the value written, so RP1's devices share one trust boundary for interrupts |
| Reset boundary | a function's reset, or its link's, which the PCIe enumerator applies at the device service's request before the function's next window; which of QEMU's devices offer a function reset is *to confirm* | each device's own reset, *to confirm*; the firmware's power control is not used, since only the kernel reaches the mailbox, for the trial request, the boot-time key read and the VL805's firmware notification alone, and no kernel call controls a device's power; the VL805's is PERST#, which the PCIe domain's bridge driver asserts ([design-usb.md](design-usb.md#the-bcm2711-bridge)) | RP1 as a whole, whose link erXos inherits from the bootloader (`pciex4_reset=0`), so RP1's devices share a reset boundary; the other masters *to confirm* |
| Asynchronous errors | no error records read; the CPU's severity reports as TCG's model or the host's CPU gives them, *to confirm* | a Cortex-A72, without the RAS extension: no severity, no error records ([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)) | a Cortex-A76, with the RAS extension's severity; no error records read until the board's error-injection test shows what they report |
| What follows | the drivers of root-bus PCIe functions are confined and share domains as the manifest says; each virtio-mmio device is unconfined, and in a release build each unit of them, the transports of one page, has a domain of its own | every DMA device unconfined: in a release build the SD controller, Ethernet and each DMA engine the manifest names have a domain of its own, holding nothing else, and the firmware is in the trusted base always | every DMA device unconfined: in a release build each SD controller, RP1 and a function on the external connector have a domain of its own, and the firmware is in the trusted base always; RP1's devices share one reset and one interrupt boundary, so RP1 is one unit and a reset of one of its devices is a reset of all; confining all of RP1 as one group through a BCM2712 IOMMU may be possible, untested |

A release image for a board allows unconfined DMA only for the devices
its manifest names, whatever the profile asked for
([design-system.md](design-system.md#the-manifest)).
The release profile and inspector identify each device as confined or
unconfined, its DMA and interrupt trust boundaries, its reset boundary and
the evidence for those claims. On both Pi boards every domain that holds
an unconfined device is in the machine-wide trusted base: a domain of its
own keeps a parser of media or packets away from the device's registers,
but does not shrink the memory the device's DMA can corrupt. So is the
PCIe domain, whole, on every platform that drives a PCIe bridge, since
configuration space turns on any function's bus mastering; it holds that
space and no other device, so nothing else joins the trusted base with
it ([design-system.md](design-system.md#devices), [What the manifest
says](#what-the-manifest-says)).

### PCIe bridges

These are facts about the platforms for the PCIe enumerator, the Erlang
process in the PCIe domain that drives the bridges and alone holds
their configuration windows
([design-system.md](design-system.md#devices)); the kernel reads only a
bridge's memory windows and `iommu-map` from the device tree
([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
QEMU `virt`'s bridge is ECAM (`pci-host-ecam-generic`). The BCM2712's root
complex (`brcm,bcm2712-pcie`) reaches configuration space through an index
and a data register of its own rather than ECAM, and aborts an access
while its link is down
([research](research-boards-storage.md#pcie-on-the-raspberry-pi-5)), so
the enumerator checks the link before each access. An abort that still
comes, because the link dropped between the check and the access, is a
fault of the thread that ran the NIF's register access, which ends the
PCIe domain; the domain service restarts the domain from the manifest,
and the restarted enumerator re-reads configuration space and changes no
running function. An abort that arrives asynchronously, after the window
that would attribute it, is an error that the kernel can only presume to
be the thread's that runs then, unless an error record of the root
complex names its source, which this board's contract does not read
([design-kernel.md](design-kernel.md#interrupts-time-and-entropy)). Each
slot's `config.txt` sets `pciex4_reset=0`, so erXos inherits the link and
RP1's configuration from the bootloader, and the enumerator lists RP1 with
the BARs the bootloader assigned.

### What the manifest says

The **system manifest**
([design-system.md](design-system.md#the-manifest)), in this document
simply the manifest, is the one file of the system configuration, which
the build packs into the boot image. For each platform it lists the
devices the platform has, by device-tree path, and gives each unit to one
domain; the device service, the domain service and the boot sequence read
it and nothing else. The default holder follows from what a device is for:
the block device goes to the storage domain, the network device to the
network domain, a TPM, with the SPI controller it sits on, to the vault's
domain, the UARTs of the console and the host link to the system domain,
and every other slow device the kernel does not keep to the devices
domain. PCIe configuration space, on every platform that drives a PCIe
bridge, goes to exactly one domain, the **PCIe domain** (manifest
identifier `pcie`, node `pcie@erxos`), which runs the PCIe enumerator and
holds no other device. That space turns on any function's bus mastering,
so the PCIe domain is in the trusted base whole, and because it holds
nothing else, the devices domain and its slow devices' drivers stay out of
it. Because the console's and the host link's UART units go to the system
domain on every platform ([UARTs](#uarts)), the devices domain holds only
slow devices that no part of the trusted base depends on, and is outside
the trusted base without exception. A device the manifest does not name
goes to no domain.

Whether the platform has an IOMMU decides which devices the manifest must
treat as **unconfined**: every DMA device that no IOMMU translates. On a
platform without an IOMMU over its DMA devices, every one of them is
unconfined. A release build's system manifest gives each unit that holds
an unconfined device a domain of its own, holding that unit's drivers and
nothing else, so no domain that parses hostile media or packets holds it,
and the service that uses it reaches it over a connection; a development
build's system manifest may give it to the domain of the service that uses
it, as the storage domain holding the Pi 4's SD controller.

The table below is each platform's **placement table**: it states, for
each platform, where each device goes, which devices the manifest treats
as unconfined and which it marks **`hostile`**, a device whose driver
parses what arrives from outside the machine or from a pluggable device: a
block device or an SD controller, a network device, a USB host controller,
and a function on an external PCIe connector. Each platform's manifests
carry these marks on their device records, and the build's manifest check
reads the marks instead of keeping a list of device classes
([design-system.md](design-system.md#the-manifest)).

| | QEMU `virt` | Raspberry Pi 4 Model B | Raspberry Pi 5 |
| --- | --- | --- | --- |
| IOMMU | the SMMUv3, which the harness creates with `iommu=smmuv3`, over the root bus's PCIe functions | none | none over the devices erXos uses: the BCM2712 IOMMUs serve media blocks |
| Devices the manifest treats as unconfined | the virtio-mmio devices | every DMA device: the SD controller, Ethernet, the DMA engines and the VL805 behind the PCIe bridge | every DMA device: the SD controllers, RP1 and a function on the external connector |
| Devices the manifest marks `hostile` | the virtio block and network devices, on PCIe or MMIO; `qemu-xhci`, a USB host controller | the SD controller; Ethernet; the VL805, a USB host controller | the SD controllers; RP1, for its Ethernet and USB hosts; a function on the external connector |
| Storage domain | the block device, a virtio-pci function on the root bus, confined | in a release build, nothing directly: the SD controller has a domain of its own | in a release build, nothing directly: each SD controller has a domain of its own |
| Network domain | the network device, a virtio-pci function on the root bus, confined | in a release build, nothing directly: Ethernet (`brcm,bcm2711-genet-v5`) has a domain of its own | in a release build, nothing directly: RP1, whose Ethernet the network stack uses, has a domain of its own |
| Vault's domain | the TPM (`tcg,tpm-tis-mmio`), when the harness attaches one | the SPI controller a TPM module sits on, with the module | the SPI controller a TPM module sits on, with the module |
| PCIe domain | the ECAM bridge's configuration window | the BCM2711 bridge's unit, its register window with configuration access in it ([design-usb.md](design-usb.md#the-bcm2711-bridge)) | the root complex's configuration window |
| USB domain | `qemu-xhci`, a PCIe function on the root bus, confined | the VL805's unit: its functions at bus 1, device 0 and the INTx line that position routes, unconfined ([design-usb.md](design-usb.md#who-holds-a-controller)) | none of its own: RP1's USB hosts are in RP1's unit, whose domain holds them |
| System domain | the console's PL011 and the host link's PL011 | the mini UART's unit, the console's, with the auxiliary SPI controllers, which it leaves undriven; the PL011s' unit, with the host link | the debug PL011, the console |
| Devices domain | the remaining slow devices | GPIO, I2C and the SPI controllers outside the mini UART's unit | the slow devices outside RP1 other than the console |
| Domains of their own in a release build | each unit of virtio-mmio devices the manifest names, the transports of one page | the SD controller; Ethernet; each DMA engine the manifest names; the VL805's unit, which is the USB domain | each SD controller; RP1, one unit with its Ethernet, USB hosts and slow devices; a function on the external connector |
| Left out of every resource | none | the VideoCore's message interface, beside the mailbox (PL2) | none |

The manifest marks each DMA device confined or unconfined, and each device
`hostile` or not, from these facts, and the build's manifest check proves
its properties over the marks: in a release build, an unconfined device's
holder holds its unit and nothing else, so no domain that parses hostile
input holds an unconfined device unless that device's unit is all it
holds; every device it names has one holder; the console's and the host
link's UART units are in the system domain; and exactly one domain holds
PCIe configuration space, and that domain holds nothing else, from which
it follows that no domain parsing hostile input and no domain holding an
unconfined device holds configuration space. At boot the device service
gives a device marked confined only on an IOMMU stream the device tree
shows, and otherwise gives it to no domain, with a diagnostic, so a mark
the tree contradicts never places an unconfined device where the check
allowed only a confined one.

### Entropy sources

QEMU passes 32 bytes in `/chosen/rng-seed`. Both boards have an RNG200
random generator, which seeds the kernel's generator at boot, for which
the kernel waits at most 100 ms
([design-kernel.md](design-kernel.md#interrupts-time-and-entropy),
[research](research-boards-storage.md#raspberry-pi-5-bcm2712-and-rp1)).
Neither accelerator offers `RNDR`
([measured](research-baselines.md#accelerator-capabilities)).

### Device secrets

A **device secret** is 32 bytes that the board holds and its medium does
not, from which the vault's `device` backend derives its sealing secret
([design-system.md](design-system.md#the-vault)). At boot, before the
system domain starts, code in the kernel's boot-only section reads the
board's key, within 1 s, derives the device secret from it with
HMAC-SHA-256 keyed by the key, over the ABI file's `device_secret_label`, the
19 public bytes of the ASCII text `erXos device secret`, zeroes the key
and every buffer that held it, and writes the secret into the
**device-secret page**, a page among the root capabilities that `liberx`'s
root-task entry receives, whose capability carries no right to duplicate
or pass it, so no other space receives it
([design-kernel.md](design-kernel.md#the-root-task)). The firmware's
buffer for the read is the boot-only section's one page of data, which
the direct map leaves out and no allocator receives, and the kernel
unmaps the section before the system domain starts, so nothing after boot
reads the key again. A read that misses its deadline leaves that page to
the firmware: a completion after the deadline writes the key there alone,
where no mapping and no later use of memory reaches it. The page's layout
is the ABI file's `erx_device_secret_page_t`, 40 bytes, and the rest of the
page is zero:

| Offset | Field | Holds |
| --- | --- | --- |
| 0 | `status`, u32 | `ERX_DEVICE_SECRET_STATUS_PRESENT` (1), `_NO_KEY` (2), a platform without a key; `_NEVER_PROVISIONED` (3), rows never programmed; or `_READ_FAILED` (4), a read that failed or timed out |
| 4 | 4 bytes | zero |
| 8 | `secret`, 32 bytes | the device secret when the status is present, and zero otherwise |

A zero status is outside the enum, so a page the kernel never wrote reads as
no secret. The layout is a shared one, read through the page's own mapping,
so no generated decoder copies the secret into a frame the root-task entry
could not zero. The banner prints the status, so every platform has the same
interface and an operator can tell a board never provisioned from a read
that failed. The device secret itself appears in no log, banner, crash record
or inspection record. The platforms' keys are:

* **On the Raspberry Pi boards** the key is the board's device-specific
  private key in OTP: 256 bits on the Pi 4, and the first 256 of the Pi
  5's 512. The kernel reads it through the firmware's mailbox, which only
  the kernel reaches (PL2) and only the trial request, this read and, on
  the Pi 4, the VL805's firmware notification, which sends one fixed tag
  and value and reads back only its status
  ([design-usb.md](design-usb.md#the-vl805s-firmware)), use.
  Rows that are all zero were never programmed, and the board then has no
  device secret. Programming the key cannot be undone, so erXos never
  writes OTP: provisioning a board's key with Raspberry Pi's own tools is
  a step of installing erXos on it, as setting its bootloader's
  configuration is ([Slots and the boot-selection
  record](#slots-and-the-boot-selection-record)).
* **QEMU `virt`** has no key and no device secret.

What the device secret answers depends on who can read the key. Raspberry
Pi documents that its boards have no hardware-protected key store, that
secure boot's verified boot is what protects the key, that any code which
can reach the firmware's mailbox can otherwise read it, and that nothing
can stop code in kernel mode from reading the OTP hardware directly. So
the device secret keeps a medium read away from its board from being
guessed against offline; on a board with secure boot
([Trust in the boot](#trust-in-the-boot)) it also resists whoever holds
the board but cannot run code on it; it never resists code in kernel mode
on the board. Nor does it resist a disclosure of memory in user mode: the
device secret lives in the system domain's space and the sealing secret
derived from it in the vault's, so a defect that reads either's memory
yields the secret, and guessing is offline again. A kernel call that
computed the HMAC without showing the secret would keep such a disclosure
on the board; [design-system.md](design-system.md#alternatives-considered)
weighs it.

**TPMs.** A TPM 2.0 is an ordinary device: the kernel never drives it, and
an Erlang driver in the vault's domain does, over the device NIF, through
the device service, for the vault alone
([design-system.md](design-system.md#the-vault)):

* On QEMU `virt` the harness attaches one when a test asks: swtpm on the
  host, as `-device tpm-tis-device`, which QEMU describes in the device
  tree as `tcg,tpm-tis-mmio`, a TIS register block of 0x5000 bytes on its
  platform bus. The TPM's state is a directory on the host, so it is as
  safe as the host keeps it.
* A Raspberry Pi takes an optional TPM module on its SPI pins, which the
  module's device-tree overlay describes. The manifest gives the SPI
  controller the module sits on to the vault's domain with the TPM, so
  the TPM's bytes cross no other domain.

The vault starts a TPM that no firmware has started.

### The watchdog

The kernel keeps one watchdog over the system domain's runtime, configured
by `erx.watchdog=P,D,B`: the period `P` at which the system domain's
watchdog process pets it through a kernel call, the deadline `D` each pet
sets ahead, and the boot deadline `B`
([design-kernel.md](design-kernel.md#the-watchdog)). The kernel arms it
when it starts the root task, with the deadline `B` ahead, so a boot that
never reaches the system runtime's first pet ends as well; `B` covers the
system runtime's boot, which the board port measures on each board. The
watchdog process pets only once the services it lists have answered
([design-system.md](design-system.md#boot)), and in a partial boot, which
the `partial_boot` field of a development build's system manifest selects,
the root-task entry, which reads that field, pets it itself. A missed
deadline is a fault of the system domain and ends the machine as one does:
the kernel writes the crash record ([The crash record](#the-crash-record))
and ends the machine as `erx.panic` says, by `SYSTEM_RESET` in release
builds and by a halt in development builds, so the early console can be
read. The kernel checks the deadline from its own timer, so the kernel's
watchdog covers everything above the kernel and nothing in it. In
deterministic mode (`erx.det=1`) the watchdog is off.

**The hardware watchdog.** Both boards have the same power-management
watchdog (`brcm,bcm2835-pm-wdt`), whose range is about 16 s
([research](research-boards-storage.md#checks-against-local-copies)). The
platform layer arms it with a 4 s timeout before the kernel starts the
system domain, whether or not the firmware started it, and reloads it from
the kernel's timer, at least once a second, for as long as the kernel
runs; it never stops it (PL4). So a kernel that stops taking interrupts
stops reloading it and the hardware resets the board without a crash
record; a system runtime that stops petting reaches the kernel's deadline
first, which writes the crash record and ends the machine as `erx.panic`
says; and a development build's halt, in which the kernel reloads nothing,
becomes a reset within the 4 s timeout, after the record is on the early
console. The hardware never fires while the kernel runs, since the reload
period is far inside the timeout, and it is never reloaded from the root
task's pet. The same reload bounds a system update's trial: the kernel
takes over the watchdog from the firmware at its first decision on a trial
boot, and the boot reaches the kernel's timer far sooner than 4 s (an
estimate that the boot probe checks on each board). On the Pi 4, PSCI
`SYSTEM_RESET` itself resets through this watchdog, after 10 of its ticks
([Firmware](#firmware)). QEMU `virt` has no watchdog: the kernel's timer
alone covers the system runtime, a hang or a halt of the kernel itself
holds the guest until the harness's deadline kills it, and the harness
plays the firmware's part in a trial.

### The crash record

When the system domain faults, halts outside an ordered shutdown or
misses its watchdog deadline, and when the kernel panics, the kernel
writes one **crash record**, in the layout
[design-kernel.md](design-kernel.md#the-root-task) defines, in one of two
forms, which the record names: a release build's **brief** form, which
holds the cause, the program counter and the fault address, the build
identifier, the boot value and its slot, the uptime and the time since
the last pet, and no other
register, no stack and no text; and a development build's **full** form,
which adds the faulting thread's registers, the backtrace and the
kernel's final log lines. It then ends the machine through the firmware
as `erx.panic` says. Where the record goes is a platform fact:

* **On the boards** the kernel writes it to the early console and into the
  crash region ([Data model](#data-model)), with a check over the record.
  The next boot reads the region before anything else writes it, accepts
  the record only if its check matches and its form is the running
  build's, so memory a cold boot left behind is never shown as a crash and
  a release build never keeps a development build's full record, and hands
  it to the system domain among the root capabilities, where the inspector
  shows it as the end of the boot before, only to the system shell, which
  only a login at a secure console line opens
  ([design-system.md](design-system.md#the-crash-record)); a region
  without a valid record is shown as none. Whether the region survives a
  warm reset through `SYSTEM_RESET` on each board is a fact the boot probe
  confirms before the inspector relies on it, and a board where it does
  not has the early console alone, as QEMU has.
* **On QEMU `virt`** the kernel writes it to the early console; the
  harness keeps the serial log, and a reset under `-no-reboot` exits the
  emulator, so the log is where a test reads the record.

### Firmware

The Raspberry Pi firmware is Broadcom's binary: it loads the kernel and
stays resident for the machine's life, with access to all memory
([design.md](design.md#residual-risks)). The Pi 5's firmware carries TF-A's
BL31, which provides PSCI. The Pi 4's built-in stub provides none, so its
boot partition carries TF-A 2.15.0's BL31 as the armstub (`armstub=` in
`config.txt`), built with its console off once the kernel runs
(`RPI3_RUNTIME_UART=-1`); it advertises PSCI in the device tree, reserves
its own memory, and implements `CPU_ON`, `CPU_OFF`, `SYSTEM_RESET` and
`SYSTEM_OFF`; its `SYSTEM_RESET` is a full reset through the
power-management watchdog
([research](research-boards-storage.md#checks-against-local-copies)).
BL31 stays resident at EL3. TF-A builds the branch-target-injection
workaround into its Raspberry Pi 4 BL31
([design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)).

### Ending the machine

`ERX_END_OFF` calls PSCI `SYSTEM_OFF`, which on the Raspberry Pi boards
halts in the firmware, since they cannot turn themselves off
([research](research-boards-storage.md#checks-against-local-copies));
`ERX_END_RESET` calls `SYSTEM_RESET`. A fault of the system domain, a
missed deadline of the kernel's watchdog and a panic end as `erx.panic`
says, after the crash record ([The crash record](#the-crash-record)):
under `reset`, release builds' default, they call `SYSTEM_RESET` the same
way; under `halt`, development builds' default, the kernel halts, and a
board's hardware watchdog resets the machine within its timeout. Under
QEMU with `-no-reboot` every end exits the emulator
([design-kernel.md](design-kernel.md#console-log-and-panic)).

### Slots and the boot-selection record

Each platform provides the record and the one-shot trial request that a
system update uses, under the contract of
[design-storage.md](design-storage.md#system-updates). The record has two
states: `normal(C)` boots the committed slot C and lets the slot writer
write the spare; `trial(S)` boots the spare S once, and the next boot
reverts to C unless the trial commits by rewriting the record to name S.
Whether the spare holds a complete release is recorded nowhere: each boot
checks the spare against its **update manifest**, which the slot writer
stores in the spare's manifest window and writes last, so a spare whose
write was cut short has no matching update manifest, is not bootable, and
needs no state of its own. Each platform therefore provides a one-sector
record with exactly two encodings, one per committed slot, rewritten only
at a commit; a reset count in a sector of its own beside it; slots written
raw; a trial request the firmware clears as the trial starts; and the
booted slot reported in `/chosen`.

**The record's bytes** are the same on every platform, and the medium
layout of `abi/medium.txt` fixes them, so the slot writer, which is the
same code on every platform, writes one format; the Raspberry Pi's is
chosen because its firmware cannot read another. The record's partition
is the medium's first, 8 MiB long (`medium_record_sectors`), one FAT16
volume laid out in MiB regions, the layout's alignment and the erase unit
the medium assumes, so that the record and the reset count each have an
erase unit of their own. Counted from the partition's first sector:

* MiB 0 holds the boot sector and the start of the reserved area;
* MiB 1 is the reset count, its first sector, sector 2048
  (`medium_record_count_start`), inside the reserved area, which no FAT
  reader reads;
* MiB 2 holds the end of the reserved area, both FATs and the root
  directory;
* the data area starts at sector 6144, 3 MiB in, with `autoboot.txt`,
  whose one 512-byte cluster is the record (`medium_record_select_start`).

The 5 MiB data area in 512-byte clusters is 10,240 clusters, a FAT16 by
the cluster count the FAT specification sets
([design-storage.md](design-storage.md#references)). The partition
starts 1 MiB into the medium (`medium_record_start`), so it ends at
9 MiB, and slot A starts at 12 MiB (`medium_slot_a_start`, sector
24,576); `abi/medium.txt` holds these values and the later partitions'
starts. The record has two
encodings, `medium_record_a` while slot A, the medium's second partition,
is committed and `medium_record_b` while slot B, its third, is. Each is
followed by zeros to the end of the sector, and both have the same length,
since a commit rewrites the sector and never the FAT's directory entry
that records the file's length. Each is the Raspberry Pi firmware's
`autoboot.txt`; while A is committed it reads

```
[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
```

and while B is, the two numbers swap. A sector that is neither encoding,
byte for byte, is an unreadable record. The packer has fsimg write the
partition's FAT with `autoboot.txt` placed at the record's sector
(`-o place=/autoboot.txt@3145728`, sector 6144 as a byte offset of the
volume), a file of the text's length, 64 bytes,
in one cluster, so the firmware reads the record through the FAT and
every other reader, the slot writer and the QEMU harness, reads the
sector; it then writes the reset count's first value into its sector of
the reserved area, which fsimg leaves zero, and checks the placement as
[design-stopgap.md](design-stopgap.md#the-raspberry-pi-4) describes; and
it writes `normal(A)`, `medium_record_a`, to a new medium.

**On the Raspberry Pi** the record is the firmware's `autoboot.txt` and the
request its one-shot `tryboot` flag
([research](research-boards-storage.md#booting-a-chosen-partition-on-the-raspberry-pi)):

* `autoboot.txt` lives in the first FAT partition: `boot_partition` names
  the committed slot and, with `tryboot_a_b=1`, its `[tryboot]` section
  names the spare; its two encodings and its sector are the record's
  bytes above. `normal(C)` is the encoding naming C with the `tryboot` flag clear;
  `trial(S)` is the same encoding with the flag set, under which the
  firmware boots the slot the `[tryboot]` section names, S; and a commit
  writes the other encoding, which names S.
* Each slot is a boot partition the firmware reads, a FAT partition
  holding the firmware's files and the single bootable file as the
  kernel file, which carries the boot image inside it, followed in
  the same partition by the EROFS images, so no domain on the target
  parses that FAT. The packer refuses a slot image whose firmware predates
  the version that the board's port records as reporting the boot value
  and honouring `tryboot`.
* `ERX_END_TRIAL` sets the flag as [Trial requests](#trial-requests)
  describes, and the firmware reports the partition it booted and the
  flag under `/chosen/bootloader` ([Data model](#data-model)).
* **Supervision before the kernel.** The board's EEPROM configuration sets
  `BOOT_WATCHDOG_TIMEOUT` and each slot's `config.txt` sets
  `kernel_watchdog_timeout`, so the firmware runs the watchdog from
  power-on and hands it to the kernel, which keeps it running for the
  machine's life ([The watchdog](#the-watchdog),
  [research](research-boards-storage.md#booting-a-chosen-partition-on-the-raspberry-pi)).
  Each slot's `config.txt` leaves `kernel_watchdog_partition` unset, so a
  watchdog reset boots the slot `autoboot.txt` names, as every other reset
  does. Setting the EEPROM is part of installing erXos on a board, and
  each board's port records the bootloader version its trial path needs; the
  Raspberry Pi 4's is 2022-12-01 ([the card's checklist](#trying-a-card-on-a-board)).
* **The reset count**, the count of consecutive unordered ends
  ([design-storage.md](design-storage.md#system-updates)), is a sector of
  its own in the record partition's reserved area, alone in its MiB, which
  neither the firmware nor any FAT reader reads. So `autoboot.txt` keeps its two encodings and is rewritten
  only at a commit, and a torn write of the count, which the slot writer
  makes at every boot, never leaves the firmware a record it cannot read.

**On QEMU** the harness plays the firmware on the same medium layout: it
keeps the one-shot flag, reads the record, boots the chosen slot's
single bootable file with `-kernel` alone, and writes the same
`/chosen/bootloader` properties into
the device tree it passes. The reset count lies in its own sector beside
the record, as on the boards, and the harness never reads it; since every
end exits the emulator under `-no-reboot`, the harness, which starts the
guest again as the firmware would, also counts the consecutive ends whose
final line follows a crash record and stops a run that passes the
configured number as a reset loop, so a test never loops however the
guest's count behaves. The packer places the bootable file of
every slot at an offset the medium layout fixes (`medium_slot_boot_start`
of `abi/medium.txt`), inside the FAT's file, so
the harness finds them without parsing FAT. The file's length is the one
its boot header records, which in the single file is the file's exact
length (`image_size` of the header,
[design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)). The harness's
slot parser reads the record's sector and the chosen slot's boot header,
refuses an unreadable record, a header without its magic, and a length
shorter than the header or running past the slot's end, since a guest
may have written either, and has a fuzz target. The harness copies that
many bytes out of the slot into a file of its own for `-kernel`, attaches
the medium as the guest's raw block device, and writes
`bootloader/partition`, the chosen slot's partition number, and
`bootloader/tryboot`, 0 or 1 by the one-shot flag, into `/chosen` of
QEMU's own device tree, which it dumps with the boot's own machine,
memory, CPU and disk options and passes with `-dtb`. It learns that a trial was asked for from the
kernel's final line on the early console, which every end of the machine
writes last, after stopping every other CPU, so no domain's line can come
after it and pass for it; the line names the end the kernel takes, so a
trial request that K19 turned into a reset reads `erx: end reset`.

### Trial requests

`ERX_END_TRIAL` first makes sure the hardware watchdog runs with its 4 s
timeout where the board has one. On the Raspberry Pi it then sends the
firmware's reboot-flags property with the `tryboot` flag through the
mailbox, then its reboot notification, as Linux does, each polled at most
1 s, long enough for the first Pi 4 revisions, which keep the flag in
their EEPROM, to finish writing it (an estimate from SPI flash erase
times; the board port checks it), and calls `SYSTEM_RESET`. On QEMU its
final line on the early console tells the harness, which plays the
firmware. A mailbox error, a timeout or a `SYSTEM_RESET` that returns ends
in the watchdog's reset
([design-kernel.md](design-kernel.md#console-log-and-panic),
[design-storage.md](design-storage.md#system-updates)). A Pi 4 of revision
1.0 or 1.1 with a write-protected EEPROM drops the request, and the
machine boots the committed slot
([design.md](design.md#failure-handling)).

### Trust in the boot

A boot can be trusted, and with it the console's prompts and the root
hashes of the EROFS images that its boot image carries
([design-storage.md](design-storage.md#system-updates)), only as far as
the platform checks the boot image before the kernel runs:

| | QEMU `virt` | Raspberry Pi 4 | Raspberry Pi 5 |
| --- | --- | --- | --- |
| Trust root | the host, which chooses the kernel, the boot image and the medium | the boot ROM with secure boot on, which the BCM2711's B1 and C0 steppings alone offer; none with it off | the boot ROM with secure boot on; none with it off |
| What checks the boot image | nothing in the guest | with secure boot, the bootloader checks each slot's `boot.img`, a FAT image that holds the firmware, `config.txt`, the device tree, BL31, the kernel and the boot image, against `boot.sig`, an RSA-2048 signature by the board's key, whose hash is in OTP; without it, nothing | the same, the firmware living in the EEPROM rather than in `boot.img`; the boot ROM also requires the board's key to countersign the bootloader, so only bootloader versions the board's owner signed run |
| Rollback | the host's to allow | none in the firmware: Raspberry Pi states that an older signed image boots | none described in the documents read (unverified) |

With secure boot, each slot's FAT partition holds `boot.img` and
`boot.sig` in place of the files the firmware loads, and the firmware
loads `boot.img` whole into memory; in trial mode (`tryboot_a_b=1`) it
loads `boot.img` from the trial's partition, as it loads `config.txt` from
it. Checking `boot.img` costs boot time in proportion to its size, about
3.5 s for 9 MB on the Pi 4 by Raspberry Pi's figure, almost all of it
SHA-256, so the boot image stays small and the EROFS images, checked
through the root hashes it carries, hold the rest. The packer refuses a
`boot.img` larger than the board port's limit, which the port derives from
the checking rate it measures and the firmware watchdog's timeout, less a
margin, so a signed slot's check never runs the watchdog out before the
kernel takes it over; the port also records the bootloader version whose
trial path it has checked to load `boot.img` from the trial's partition.
The boot image's own hashes, the BLAKE3 hash of its index and of each
file ([design-kernel.md](design-kernel.md#the-boot-image)), are
integrity alone: they catch a damaged slot or a file cut short, never a
file someone wrote on purpose, since whoever writes the medium writes
matching hashes. Authenticity comes only from the trust root in the
table above, which with secure boot covers the whole bootable file, the
index hash with it.
Secure boot is an installation's choice: turning it on writes the hash of
the board's key into OTP, cannot be undone, and needs the board's owner to
sign each slot's `boot.img`, which the packer does with a key it is given
and never keeps, writing the slot's signature window alone, which the
update manifest leaves out of its hash
([design-storage.md](design-storage.md#data-model)). Without secure boot,
whoever can write the medium controls the machine, its console's prompts
included.

### Bring-up under QEMU

QEMU's `raspi4b` model, under TCG, has the GIC-400 but no PCIe or
Ethernet, and QEMU has no Pi 5 model
([research](research-boards-storage.md#qemus-raspberry-pi-models)).
Fiasco's support for both boards, which uses its GICv2 driver, is the
reference for their bring-up: the interrupt controller, the timer and the
UARTs of the early console
([research](research-boards-storage.md#fiascos-raspberry-pi-support)).

**The model's devices.** QEMU 11.1.3's model, as its monitor reports it
(`info qtree`, and `qom-get` on the first CPU), has four Cortex-A72 cores
that implement EL3 and EL2; a GIC-400 built without the security
extensions (`has-security-extensions = false`); 2 GiB of RAM (board
revision `0xb03115`); one PL011, UART0, on QEMU's first serial port; the
mini UART (`bcm2835-aux`) on its second; the power-management block
(`bcm2835-powermgt`), which holds the watchdog; and the SD controllers.
The harness therefore gives the console the second `-serial` option, the
first going to a null device. The model has no UART3, so the host link is
not checked on it, and its mini UART takes no clock, so neither is the
pinned core clock.

**BL31 on the model.** No firmware runs on the model. QEMU's generic
loader (`-device loader`) puts TF-A's Pi 4 BL31, built from its pinned
release, at address 0 and starts CPU 0 there (`cpu-num=0`); puts the
bootable file at the address BL31 enters; and puts the device tree where
BL31 expects it: the card's tree, with `config.txt`'s overlays applied
and the memory node written on the host, which is all the firmware does
to it. The card's `serial0` alias, which BL31 points
`/chosen/stdout-path` at, is the card's own, so the model picks the
console's UART from the very tree the board does. The chain is the board's: BL31 at EL3 enters the bootable file
at EL2 (`SPSR` `0x3c9`, MMU off, the device tree's address in `x0`), the
kernel starts the other three CPUs with PSCI's `CPU_ON` and ends them
with `CPU_OFF`, and resets the machine through BL31
([research](research-rpi4-bl31-qemu.md)). The harness's configuration
for it:

* four CPUs, no `-kernel` and no `-bios`: all four leave reset at
  address 0 in EL3, and BL31 parks CPUs 1 to 3 until `CPU_ON`;
* BL31 and the bootable file and device tree where the loader puts them,
  BL31 with its stub header at `0xf0` patched on the host, as the
  firmware patches it: `stub_magic` 0, the device tree's address and the
  bootable file's entry address (the build options `PRELOADED_*` alone
  do not do);
* `-global arm_gic.has-security-extensions=on`, which gives the model the
  GIC-400 of the board. Without it BL31 still runs, but the normal
  world reads the secure layout (`GICD_TYPER` `0x66`) and its
  interrupts arrive spurious; with it `GICD_TYPER` reads `0x466` and
  the timer's interrupt arrives as interrupt 30;
* `-no-reboot`: `SYSTEM_RESET` and `SYSTEM_OFF` both write the
  power-management watchdog, and QEMU exits with status 0. On a board
  `SYSTEM_OFF` halts instead, so the model shows a reset where the
  board halts;
* a device tree the host supplies, since QEMU generates none;
* TCG alone: the model's CPUs implement EL3, where BL31 runs, and HVF refuses a guest CPU with
  EL3 enabled (QEMU 11.1.3: "Cannot enable HVF when guest CPU has EL3 enabled"), so the
  `raspi4b` suite is the one QEMU suite that runs under TCG and not HVF;
* BL31 built with LLVM alone, and GNU sed on the path.

BL31's own console is the PL011 on the model, since its Pi 4 port picks
the mini UART only when GPIO14 is in ALT5. The model logs the mini
UART's line control and control registers as unsupported, which does not
stop it printing.

**The firmware's framebuffer under QEMU.** On the board the firmware asks
the VideoCore for the HDMI framebuffer and describes it in the device
tree as a `simple-framebuffer` node under `/chosen`, which the root reads
into [the framebuffer's unit](#raspberry-pi-4-model-b). The model runs no
firmware, but emulates the mailbox property interface (QEMU's
`docs/system/arm/raspi.rst`: "Frame Buffer", "MailBox controller
(MBOX)", "VideoCore firmware (property)"), so the `raspi4b` suite's
shell cell plays the firmware's part with a stand-in that is test
harness alone (`Raspi4bFirmwareFb`, `test/raspi4b/firmware_fb.c`).
erXos's own code never talks to the mailbox
([design-device-tree.md](design-device-tree.md#alternatives-considered)),
nothing of erXos links or packs the stand-in, and no card holds it.

* On the host, the harness copies the model's tree, adds the node with
  placeholder cells for its base, size, width, height and stride, and
  its format, and builds the stand-in with the address of each
  placeholder cell in the tree as the loader places it.
* QEMU's generic loader starts CPU 0 at the stand-in's ELF entry
  (`cpu-num=0`; QEMU's `docs/system/generic-loader.rst`) instead of in
  BL31. The stand-in sends one property request on mailbox channel 8
  (the firmware's "Mailbox property interface" page): set the physical
  and virtual size to 640x480, the depth to 32 and the pixel order to
  BGR, then allocate the buffer and get the pitch. It writes the answer
  into the placeholder cells and enters BL31 at address 0 with `x0` to
  `x3` zero, as reset leaves them. An answer that is not the screen
  asked for leaves the placeholders, which name a framebuffer outside
  every window, so the root refuses it, the display domain runs without
  a screen and the suite's screen check fails.
* QEMU 11.1.3 answers with the base `0x3c100000`, `0x12c000` bytes, 640
  by 480 and a pitch of 2560, inside the unit's window and above the
  RAM the tree reports. Under BGR the model shows a 32-bit word's bits
  23:16 as red, 15:8 as green and 7:0 as blue, so the node's format is
  `x8r8g8b8`; under RGB a probe's `0x00ff0000` shows blue.
* The suite then checks the root's `framebuffer 640x480 2560 x8r8g8b8`
  line, the driver's `erx_fb: framebuffer 640x480 stride 2560
  x8r8g8b8` line once, and the screen read through QMP: every pixel
  the empty layout's background, the colour `erx_screen` defines,
  which the harness reads from that source.

The stand-in proves erXos's side of the contract, from the node to the
pixels; that the firmware writes the node the root reads is what the
board pass settles.

**What the model never checks.** The Pi firmware runs on the VideoCore,
which QEMU does not emulate, so nothing on the model reads `config.txt`,
makes the firmware's edits to the device tree (the memory node as the
firmware computes it, the Ethernet MAC address), places the device tree
and the bootable file as the firmware does, or accepts or refuses a
bootable file by its size. QEMU's DMA is coherent, so a driver that
misses a cache clean or invalidate passes on the model. The model has no
Ethernet and no PCIe: nothing answers at GENET's window, so the network
domain's first read of its registers takes a synchronous external abort,
which ends that domain alone with a memory fault; the domain service
logs each end and restarts it within its intensity, then leaves it down
([design-system.md](design-system.md#boot)), and the `raspi4b` suite
expects that end. A stage proven on the model therefore counts only
once it has also passed on a board, and the model's runs are never
compared with the board's numbers.

**The model's SD controller.** QEMU 11.1.3 models EMMC2 as its generic
SDHCI at the board's address, specification version 3, with the
capabilities word `0x052134b4` (`hw/arm/bcm2838_peripherals.c:22,
83-94`): a 52 MHz base clock and a 52 MHz timeout clock, high speed, 3.3
and 1.8 V, and neither SDMA nor ADMA2 (the fields,
`hw/sd/sdhci-internal.h:208-224`), so the model tests programmed I/O
alone. It ORs EMMC2's interrupt with the legacy controller's into one
GIC line (`hw/arm/bcm2838_peripherals.c:97-104`; `hw/arm/bcm2838.c:198-204`).
Its card bus is empty unless a card is attached to it, so the harness
attaches the medium as an `sd-card` device on EMMC2's bus,
`-device sd-card,drive=...,bus=/generic-sdhci/sd-bus`, with a drive id
other than `sd0`, which the model's own card on the legacy controller
takes ([research-sdhci-qemu-model.md](research-sdhci-qemu-model.md)). The model's
card is standard capacity up to 2 GiB and high capacity above, and takes
an image of a power-of-two size up to 2 GiB and of a multiple of 512 KiB
above ([research-sdhci-qemu-model.md](research-sdhci-qemu-model.md#qemus-sd-card-model-how-it-sizes-a-medium)), so the harness pads the
medium to 2 GiB for a standard-capacity card and to 4 GiB for a
high-capacity one. The model's bus is not timed, so the base clock is checked on the
board alone.

### The Raspberry Pi 4 on the stopgap

Before erXos's kernel exists, the Raspberry Pi 4 runs the stopgap Fiasco
behind the same interface, booted by the same firmware and the same BL31,
with the console, the host link, the manifest and the Erlang drivers this
document gives it. Fiasco's generic platform takes PSCI from BL31 and its
devices from the device tree, and its `bootstrap` is built for RAM that
starts at 0. The kernel's platform items of this document are not there:
no hardware watchdog backs a hang, no crash region keeps a record across
a reset, no trial is requested, no device secret is read and the random
generator is not read. The early console's role passes to Fiasco's own
console on the same UART, and a board's end goes through BL31's PSCI as
it does on erXos's kernel. [design-stopgap.md](design-stopgap.md#the-raspberry-pi-4)
describes that shape, and M12 of [plan.md](plan.md#m12-storage-networking-boards)
adds the kernel's items on erXos's kernel.

#### Trying a card on a board

One pass on a real board checks what QEMU's model cannot: the firmware,
its device tree and its UART setup. It is done by hand, once per change
to the boot path.

**You need** a Raspberry Pi 4 (any memory size: `total_mem` makes the
board use 1 GB; the 4 GB board is the one tested), a microSD card of at least 4 GB (the card's image is 2 GiB), and a 3.3 V
USB-serial adapter (never a 5 V one). Wire it to the 40-pin header: the
adapter's ground to pin 6, its receive line to pin 8 (GPIO 14, the Pi's
transmit) and its transmit line to pin 10 (GPIO 15). Open it at 115200
baud, 8N1, no flow control, for example `screen -L /dev/cu.usbserial-XXXX
115200`, where `-L` logs everything it prints to `screenlog.0`. A second adapter on UART3, the
host link, is optional: ground to pin 9, receive to pin 7 (GPIO 4),
transmit to pin 29 (GPIO 5), also 115200 8N1.

**Build** the card's image on the development host:

```sh
make pack PLATFORM=raspi4b
```

It writes `build/production-image/raspi4b/sdcard.img`.

**The bootloader must be 2022-12-01 or later.** The card's partition 1
holds only `autoboot.txt` with `tryboot_a_b=1`, and each slot holds its
own `config.txt`. A bootloader older than the 2022-12-01 release does not
know `tryboot_a_b`: the 2022-10-18 beta first loaded `config.txt` in
that mode, and the 2022-12-01 release made it the default
([research](research-boards-storage.md#booting-a-chosen-partition-on-the-raspberry-pi)).
On a Pi 4 (board revision c03112) with such a bootloader the card
showed nothing at all on the UART and the green LED stayed on, with
or without a card, where the Raspberry Pi documentation has it flash
during card activity; after the reflash below the same card booted. A
card with one boot partition still boots on such a board, which tells a
bootloader that is too old from a bad card. To read a board's bootloader build date, boot a
Raspberry Pi OS that has it, or read
`/proc/device-tree/chosen/bootloader/build-timestamp`; or just reflash:

1. On the development host, open Raspberry Pi Imager and pick the
   Raspberry Pi 4 as the device.
2. As the operating system pick *Misc utility images > Bootloader > SD
   Card Boot*, and write it to a spare card (not the erXos card).
3. Put that card in the Pi and power it. Wait until the green LED flashes
   in a steady pattern (the documentation adds a green screen on an HDMI
   display), then power the Pi off.
4. Take the spare card out. The EEPROM now holds a current bootloader.

**Write the card** on macOS. Insert the card, then find it:

```sh
diskutil list
```

Pick the disk whose size is the card's, `/dev/diskN`, marked `external,
physical`. **Writing to the wrong disk destroys what is on it, your
Mac's own disk included: check the size and the name twice.** Then:

```sh
diskutil unmountDisk /dev/diskN
sudo dd if=build/production-image/raspi4b/sdcard.img of=/dev/rdiskN bs=4m
diskutil eject /dev/diskN
```

Put the card in the Pi, start logging on the adapter, then power the Pi.

**Expect**, in this order, on the console adapter:

1. BL31's banner, two lines: `NOTICE:  BL31: v2.15.0(release):v2.15.0`
   and `NOTICE:  BL31: Built : erXos`.
   BL31 writes the mini UART, since its Pi 4 port takes it when GPIO 14
   is in ALT5, where `enable_uart=1` puts it.
2. bootstrap's memory line, exactly
   `  Total RAM: 948.0 MiB; available for Bootstrap/Sigma0/Kernel: 948.0 MiB`:
   the 1024 MiB `total_mem` gives less the 76 MiB of `gpu_mem`.
3. `Starting kernel at`, then the erXos banner art, `erXos`, Fiasco's
   version lines and `development build: trusted code only`, then
   Fiasco's start-up lines, `DT Platform: Raspberry Pi 4 Model B` among
   them.
4. After a minute or less, a line that starts `rc: the command shell`
   and the command shell's `%` prompt. Type `erl` and Enter: the Erlang
   shell's `(root_1@erxos)1>` prompt comes up. Type `1 + 2.` and
   Enter: it answers `3`. Type `q().` to return to the command shell,
   then `dmesg`, which prints the kernel's and the system's log.
5. With a screen on the micro-HDMI port the board labels HDMI0, plugged
   in before power-on: the firmware's rainbow square and boot text give
   way, after the shell's prompt, to the display's empty layout, one
   colour over the whole screen, and the picture stays put. `dmesg`
   holds the root's line `erx: device tree: /chosen: framebuffer
   WIDTHxHEIGHT STRIDE FORMAT` and the display domain's `erx_fb:
   framebuffer WIDTHxHEIGHT stride STRIDE FORMAT`, with the same numbers,
   and no `configured domain display ... ended` line. `framebuffer absent
   outside BASE SIZE` instead names where the firmware put the
   framebuffer, outside the window of
   [the framebuffer's unit](#raspberry-pi-4-model-b); `erx_fb: the
   framebuffer is not driven:` names why the driver refused it.

**What the pass settles.** Typing works, so the mini UART raises its
receive interrupt with bits 3:2 of its interrupt-enable register set, as
the console driver sets them although Broadcom's manual marks those bits
reserved; anything at all after BL31 means the firmware loaded
`kernel8.img` at `kernel_address`, where bootstrap is linked; output
after BL31's banner means the card's `serial0` is the UART on the
adapter; and the memory line and the shell together show that the device
tree the firmware made from the partition's tree and `uart3` overlay is
the one erXos expects. Anything at all after BL31 on this card also means
the bootloader read `autoboot.txt` from the record's FAT16 in partition 1
and booted slot A's FAT32 in partition 2, since partition 1 holds no boot
files (slot A's volume covers only its partition's first 128 MiB); the
bootloader's version, from its own log or from a running system, goes
into the board's port as the oldest that honours `autoboot.txt`. A
board whose bootloader stops before BL31 with this card and boots an
older card of one FAT32 partition is one whose bootloader does not read
`autoboot.txt`.

**What a 4 GB board shows.** BL31 enters `kernel8.img` at `0x200000` in
EL2 with the device tree's address in `x0`; the firmware leaves the
card's serial aliases as they are; `enable_uart=1` puts GPIO 14 and 15 in
ALT5 even when `config.txt` has `gpio=14=a0` and `gpio=15=a0,pu` lines
after it, and `enable_uart=0` leaves the header's UART silent, BL31's
banner included. BL31's banner followed by silence on the adapter means
the card's `serial0` is not the mini UART: every stage after BL31 then
writes UART0, and the root task refuses the manifest.

**Send back** the whole serial log of the console adapter (and of the
second adapter, if one was wired), from power-on to `dmesg`'s output.
If the board stops early, the log up to the stop is what tells where.

#### The SD card and Ethernet on a board

A second pass by hand checks the two drivers QEMU's model runs only in
part or not at all: `erx_blk_sd` on the board's EMMC2 with a real card,
and `erx_genet` on the board's Ethernet. It is done once per change to
either driver, to the storage or network domain's rows of the manifest,
or to the network stack's DHCP client.

**What the model cannot check**, beside
[what it never checks](#bring-up-under-qemu): QEMU's `raspi4b` model has
no Ethernet controller, so `erx_genet` never runs there. Its SD card is QEMU's SD
model on programmed I/O, a 2 GiB card it presents as standard capacity,
so the order in which the BCM2711's controller raises its events, its
clock, a high-capacity card of the card's own size and what a real card
reports for a read past its end are seen only on a board. The suite's
run also ends at the machine's halt, so `/data` across a real reset is
checked only here.

**You need** the boot pass's board, card and console adapter, and an
Ethernet cable to a network with a DHCP server and a route to the
internet, such as a home router.

In the steps, `%` is the command shell's prompt, which the console
opens in root's session. Type each command as shown and press Enter.

1. **Write the card.** The card under test is the one built from the
   change: `make pack PLATFORM=raspi4b`'s `sdcard.img`, written as in
   **Write the card** above, or the same image compressed,
   `sdcard-DIGEST.img.xz` with its build record
   `sdcard-DIGEST.img.receipt.json`, as the website names a card, by the
   first 16 hexadecimal digits of the card image's SHA-256. Check a
   compressed card before writing it:

   ```sh
   xz -dc sdcard-DIGEST.img.xz | shasum -a 256
   ```

   prints the card's whole SHA-256 that its build record names, which
   starts with `DIGEST`. Find the card as in
   **Write the card** above (`diskutil list` on macOS; on FreeBSD,
   `geom disk list`, where it is `/dev/daN`), check its size and name
   twice, then on macOS:

   ```sh
   diskutil unmountDisk /dev/diskN
   xz -dc sdcard-DIGEST.img.xz | sudo dd of=/dev/rdiskN bs=1m
   diskutil eject /dev/diskN
   ```

   or on FreeBSD:

   ```sh
   xz -dc sdcard-DIGEST.img.xz | sudo dd of=/dev/daN bs=1m
   ```

   `dd` ends with `2147483648 bytes transferred`, the card image's 2 GiB.
2. **Boot.** Put the card in the Pi, plug the Ethernet cable in, start
   logging on the adapter, then power the Pi. Expect the boot pass's
   lines 1 to 4, ending with the `%` prompt.
3. **The card is identified.**

   ```sh
   dmesg | grep erx_blk
   ```

   prints a line that ends
   `erx_blk: SD card, high capacity, N sectors, 4-bit bus at F Hz`,
   where N times 512 is the card's size in bytes (about 62,500,000
   sectors for a 32 GB card), and a line that ends
   `erx_blk_service: partition table admitted; W windows`. Then
   `dmesg | grep erx_lfs` prints a line that ends `erx_lfs: volume mounted`.
   A line `erx_blk: the SD card is not driven: REASON` instead means the
   driver refused the card, and REASON says at which step.
4. **`/data` is the card's volume.** `/data` is the littlefs volume on
   the card's data partition. The storage domain serves it, and root's
   session reaches it through a grant, an entry of its namespace that
   names the storage domain's file service, so `mount` prints, among its
   lines, `PID:/data on /data (littlefs)`, where PID is the file
   service's process: the type `littlefs` is what the service answers
   statfs with, and the `PID:/data` source marks a tree another domain
   serves. A line `ended on /data (-)` means the service's grant has ended, and
   a `/data` line with another type means something else is mounted
   there. On a freshly
   written card `ls /data` prints nothing. Then

   ```sh
   echo written on the board > /data/hello
   cat /data/hello
   ```

   prints `written on the board`. Two errors mean the write never
   reached littlefs:
   * a read-only file system error (`erofs`): the session holds no
     `data` grant, so `/data` is the release image's own empty directory,
     and the release image is a read-only EROFS image;
   * an I/O error (`eio`): the grant is there but no volume is behind it,
     because the storage domain has no card or did not mount it, which
     step 3's lines explain.
5. **`/data` survives a reset.** Wait five seconds, then reset the
   machine from the system's own shell: press Ctrl-G, which prints
   `erx_console: Ctrl-G menu`; press `s`, which gives the system's
   command shell and its `%` prompt; type `erl` and Enter, then
   `init:reboot().` and Enter, which asks for the ordered end `reset`
   ([design-system.md](design-system.md#shutting-down)). The board
   resets and boots again from BL31's banner. (`erlang:halt().` asks
   for `off` instead, and the board then halts in the firmware.) If it
   stays silent for a minute, power it off and on, and send back the
   log. At the `%` prompt, `cat /data/hello` prints
   `written on the board`.
6. **`genet0`'s link is up.**

   ```sh
   dmesg | grep erx_genet
   ```

   prints a line that ends `erx_genet: GENET v5, mtu 1500` and then one
   that ends `erx_genet: link up, 1000 Mb/s full duplex` (100 or 10 Mb/s
   with a slower switch port). A line `erx_genet: the network device is
   not driven: REASON` means the driver refused the controller.
7. **A DHCP lease.**

   ```sh
   ifconfig genet0
   ```

   prints four lines in FreeBSD's layout:

   ```
   genet0: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
   	ether MAC
   	inet A netmask M broadcast B
   	status: active
   ```

   where MAC is the board's Ethernet address and A the address the
   network's DHCP server leased, which the router's list of leases
   shows under that MAC. With no `inet` line there is no lease yet: run
   the command again after 30 seconds. `status: no carrier` means the
   link is down.
8. **The gateway answers.** With G the router's address (its own pages
   show it; on many home networks it is A with its last number
   replaced by 1):

   ```sh
   ping -c 3 G
   ```

   prints three `64 bytes from G` lines and
   `3 packets transmitted, 3 packets received, 0.0% packet loss`.
9. **Names resolve.**

   ```sh
   host www.freebsd.org
   ```

   prints one or more lines `NAME has address X`, where NAME is
   `www.freebsd.org` or, when that is an alias, the name a line
   `www.freebsd.org is an alias for NAME.` gives before them (IPv6
   lines may follow). Then `ping -c 3 X`,
   with one of those addresses, shows replies from beyond the router.
   `;; connection timed out; no servers could be reached` means the
   lease named no name server that answers.

**When a step fails**, send back the whole console log from power-on,
with the failing command and what it printed, and the output of `dmesg`
typed right after it: it holds the drivers' lines (`erx_blk`,
`erx_blk_service`, `erx_lfs`, `erx_genet`) and, when a domain ends, the
system's line `erx_domain: configured domain NAME (domain N) ended,
REASON; restarting it`. While the storage domain serves no volume,
`/data` answers `eio`, so the start service's lines
`erx_starter: rc.conf cannot be read (failure N): eio` follow, at
failures 1, 2, 4, 8 and so on; they are a symptom of step 3's failure,
not a fault of their own. Name the card's make and size, and for an
Ethernet step the switch or router the cable goes to.

## Interfaces

* **`hw/kernel_devices.txt`**, the device table, read by the kernel's
  generator; an entry names a compatible string and a role.
* **The system manifest** of each platform, which the build packs into the
  boot image: the devices the platform has, by device-tree path, the
  domain that holds each, the console's and the host link's UARTs, each
  DMA device's mark, confined or unconfined, and each device's `hostile`
  mark ([What the manifest says](#what-the-manifest-says),
  [design-system.md](design-system.md#the-manifest)).
* **Boot arguments** a platform needs: `erx.trial_deadline`; the kernel's
  `erx.watchdog=P,D,B` and `erx.panic` decide when a hung system runtime
  ends the machine and how, while the boards' hardware watchdog backs the
  kernel itself
  ([design-kernel.md](design-kernel.md#configuration),
  [design-kernel.md](design-kernel.md#the-watchdog)).
* **Per-platform kernel builds**, which differ only in the early
  console's kind and address.
* **The crash region**, the `/reserved-memory` node compatible
  `erxos,crash-region` in each board's slot device tree
  ([The crash record](#the-crash-record)).
* **The boot-selection record**, the firmware's `autoboot.txt` on the
  Raspberry Pi and the same file read by the harness on QEMU
  ([Slots and the boot-selection record](#slots-and-the-boot-selection-record),
  [design-storage.md](design-storage.md#system-updates)).

## Compatibility and migration

No platform keeps a path for an earlier form. Until a release promises
compatibility, a change to a platform's binding, to
`hw/kernel_devices.txt`, to a platform's system manifest, to a boot
argument, to the crash record's layout or to the device-secret page's
layout replaces the old form outright, the layouts' as a new version of
the ABI file; a crash record of another version fails its check and is
shown as none. Platforms share one kernel interface, so adding one adds
table entries, drivers and a manifest without changing a call, a layout or
a boot argument.

## Failure handling, diagnostics and debuggability

| Failure | Detection | What remains | User-visible result |
| --- | --- | --- | --- |
| A malformed device tree | the early pass | nothing: the boot stops | a message on the early console |
| No PSCI node | the device pass | nothing: the boot stops | a message on the early console |
| A CPU that the firmware refuses or that does not reach its idle thread in 100 ms | the CPU start | the machine, with that CPU offline | the banner names it |
| A trial request that fails or times out | the kernel's poll of the mailbox | the watchdog's reset | the machine boots the committed slot |
| A node left out because it shares a kept page | the device pass | the node in no resource | a boot log line naming it |
| The board's key cannot be read within 1 s, or was never programmed | the kernel's read at boot, with its deadline | the machine, without a device secret; after a missed deadline, the firmware's buffer page, out of every mapping and never reused, for a completion that may still come | the banner says which; a vault configured for `device` answers logins `unavailable` |
| The system runtime stops petting the kernel's watchdog, or the system domain faults | the kernel's timer; the fault | the crash record, brief in release builds and full in development builds, on the early console and in the boards' crash region, and a machine that boots again, directly by `SYSTEM_RESET` or through the hardware watchdog after a development build's halt | the record on the UART, and in the inspector after the next boot on a board, to the system shell alone |
| The machine ends unordered at every boot | the reset count, in its own sector beside the boot-selection record ([Slots and the boot-selection record](#slots-and-the-boot-selection-record)) | a machine in its rescue configuration after the fourth such end | the console's login, and the crash record in the inspector |
| The kernel stops running on a board | the hardware watchdog | a machine that boots again, without a crash record | the inspector shows the boot before as ended without a record |
| The kernel stops running on QEMU `virt` | the harness's deadline | the serial log | the harness reports a timed-out run as such |
| A crash region without a valid record | the check at boot | nothing shown as a crash | the inspector shows none |
| A spare slot whose write was cut short | the check of the spare against its update manifest at boot | the committed slot, booting as before; the spare not bootable, so no trial of it is requested | the update service shows the spare as not bootable |
| A UART that its driver left unable to transmit when the kernel panics or ends the machine | the bound on each polled byte | the end completes; on a board, the record in the crash region | the report missing from the console |
| A device the manifest marks confined that the device tree gives no IOMMU stream | the device service at boot | the device given to no domain | a diagnostic naming it |
| A manifest that gives two devices of one unit to two domains | the device service at boot | the unit given to no domain | a diagnostic naming the unit |
| A manifest whose `console` path is not the UART `/chosen/stdout-path` names | the device service at boot | nothing: the system release does not boot, and the machine ends by `erx.panic` | a kernel log line naming both paths, with the crash record |
| A `/chosen/stdout-path` that names a UART of another kind or at another address than the kernel build's | the kernel's early pass | nothing: the boot stops | a message naming the path on the kernel build's own UART ([design-kernel.md](design-kernel.md#console-log-and-panic)) |
| A synchronous abort on a configuration access of the BCM2712's root complex | the fault of the thread that ran the NIF | the PCIe domain ended and restarted from the manifest | a `domain_down` for the PCIe domain; the restarted enumerator lists the same functions |

## Security

The trust boundaries are the kernel's
([design-kernel.md](design-kernel.md#security)); what the platforms add
are residual risks, which [design.md](design.md#residual-risks) records:
unconfined DMA on QEMU `virt`'s virtio-mmio devices and on both boards'
DMA devices, whose drivers' domains are part of the trusted base, each
holding one unit and nothing else in a release build, as is the PCIe
domain, which holds configuration space and nothing else; the boards'
closed boot firmware, resident with access to all memory, and BL31,
resident at EL3; and MSIs through the GICv2m frame or the MIP block, which
do not identify the writer, so a device can raise any line of the frame.
PL2 keeps the firmware's mailbox out of every driver's reach, and with it
the board's key, which the platform layer reads once at boot, and gives
the console's UART to the system domain alone, so a compromised devices
domain, which has no tty, can neither read a passphrase nor write to the
operator. The kernel
shares the console's UART with the system domain only for its polled
writes, which it makes during boot and, after stopping every other CPU, at
a panic or an end; it reads nothing from the UART, so the driver can at
worst lose the kernel's report, never change what the kernel decides. The
crash region holds what the kernel wrote at a crash, the system domain's
faulting registers and the kernel's log lines included, across a reset and
in plain memory; only the kernel writes it and only the next boot's system
domain reads it, the device-secret page is never in it, and whoever can
read the region can read all memory anyway, so it widens no boundary. What
a board's key and a TPM protect, and from whom, is in [Device
secrets](#device-secrets); how far a boot can be trusted on each platform,
with or without secure boot, and the rollback that no firmware refuses, is
in [Trust in the boot](#trust-in-the-boot).

## Verification and testing

* **Boot probe.** At each board port's first boot, a probe confirms where
  the firmware places a single bootable file of the release's size and
  the device tree beside it, whether it honours `image_size`, `/chosen`,
  the CPU's entry state and the memory map, that the boot reaches the kernel's timer well inside
  the hardware watchdog's timeout, how long the system runtime takes to
  its first pet, which `B` must cover, and whether the crash region
  survives `SYSTEM_RESET`; the results go into a research record.
* **The same suite everywhere.** The conformance suite runs on QEMU
  `virt` under HVF and on each board; a test that passes only on
  one accelerator is a bug until explained.
* **Device-tree tests.** The `dma-ranges` reader runs on the host over the
  trees of QEMU `virt`, both BCM2711 steppings and the BCM2712; the device
  pass's leaving out of nodes that share a kept page is tested with each
  tree, and so is the crash region's discovery, with a tree that has the
  node and one that lacks it.
* **Ends and trials.** Each end (off, reset, panic, trial) is tested on
  each platform with and without a lease, and on each board a trial that
  panics, hangs with interrupts masked or halts boots the committed slot.
  On QEMU and on each board, a spare whose write a test cuts short fails
  its check at boot and no trial of it is requested; the paired passing
  case writes the same spare whole and its trial boots.
* **The early console.** On QEMU and on each board, a panic forced while
  the console's driver runs puts the report and the final line in the
  serial log; the paired failure seeds an early-console writer that drops
  its bytes and expects neither. On each board, a panic forced after the
  driver has disabled the UART still ends the machine within the writer's
  bound, by `SYSTEM_RESET` in a release build; the paired failure seeds a
  writer without the bound and expects the machine to end only through
  the hardware watchdog. On QEMU, a device tree with a wrong magic, and
  one whose `stdout-path` names the host link's PL011, each stop the
  boot with their reason in the serial log; the paired failures seed an
  early-console writer that starts only at the device pass, which leaves
  the first log empty, and a hook that skips the check of `stdout-path`,
  after which the boot goes on and the test fails.
* **The watchdog.** On each platform, a system runtime told to stop
  petting ends the machine at the deadline with a crash record naming the
  watchdog, by a reset in a release build and, on each board, by a
  development build's halt that the hardware watchdog turns into a reset;
  a partial boot, selected by a development build's system manifest's
  `partial_boot` field, that outlives `B` runs on; the paired failure
  seeds a kernel whose timer skips the deadline check and expects the
  reset not to come. On each board, a kernel hung with interrupts masked
  resets within the hardware watchdog's timeout; the paired failure seeds
  a reload of the hardware watchdog from outside the timer and expects the
  reset not to come. A boot in deterministic mode runs past the deadline
  without a pet and does not reset.
* **The crash record.** On each board, a forced fault of the system domain
  resets the machine and the next boot's inspector shows the record with
  the fault's cause, in the brief form in a release build and the full
  form in a development build, to the system shell alone; the paired failures corrupt one byte of the region before the
  reset, and leave a development build's full record for a release
  build, and each expects the inspector to show none. On QEMU, the
  harness finds the record in the serial log before `erx: end reset`.
* **Reset loops.** On QEMU and on each board, a test-build hook that
  faults the system domain at every boot brings the fifth boot up in
  the rescue configuration; the paired failure seeds a slot writer that
  never advances the count and expects the harness to stop the run as a
  loop.
* **Device secrets and TPMs.** On each board, a key provisioned with
  Raspberry Pi's tool gives the same device secret at every boot and a
  different one on another board, and a board whose key was never
  programmed reports none. On the host, against a model of the firmware,
  every buffer that held the key holds zeros once the read returns, a
  model that never answers ends the read at its deadline and the boot goes
  on without a device secret, a model that answers after the deadline
  writes only the buffer page, which no mapping the boot made and no page
  the allocator hands out covers, and the derivation runs against fixed
  keys. Under QEMU, the vault's `tpm` backend runs against swtpm behind
  `tpm-tis-device`; on each board with a module, against the module.
* **The system manifests.** Each platform's system manifest for a release
  build passes the build's manifest check and boots with every device
  where [What the manifest says](#what-the-manifest-says) puts it, which a
  boot test reads back from the device service. The paired failures each
  fail the build with a diagnostic: a board's system manifest for a
  release build that gives the SD controller to the storage domain, QEMU's
  system manifest for a release build that gives a virtio-mmio device to
  the network domain, a manifest that gives PCIe configuration space to
  the devices domain, one that places the console's UART unit in the
  devices domain, one whose `hostlink` path is its `console` path, and a
  board's release manifest that gives an unconfined device marked
  `hostile` to a domain that also holds partition windows. A test reads
  each shipped manifest's `hostile` marks back from the packed manifest
  and compares them with the placement table, transcribed into the test;
  the paired failure drops one mark and expects the test to fail. At boot,
  a seeded manifest that gives the Raspberry Pi 4's mini UART and an
  auxiliary SPI controller to two domains, and one that marks a
  virtio-mmio device confined, are each refused for that unit with a
  diagnostic, while the rest boots; and a manifest whose `console` and
  `hostlink` paths are swapped, so that `console` is not the UART
  `stdout-path` names, ends the boot with both paths in the kernel log.
* **Secure boot.** On a board with secure boot on, a slot whose
  `boot.img` its owner did not sign does not boot, and a trial of a signed
  spare boots from the trial's partition; the board port records the cost
  of the check for the slot images' sizes.

## Performance

The counter runs at 62.5 MHz under TCG and 24 MHz under HVF
([measured](research-baselines.md#accelerator-capabilities)); the kernel's
timing tests and benchmarks run under HVF and on the boards, never
comparing TCG with HVF or with native numbers. The boards' random
generator delays boot by at most 100 ms. Each speculation mitigation's
cost on entry is measured on each board with `tools/erx bench nullcall`
([design-arch-aarch64.md](design-arch-aarch64.md#speculation-mitigations)).
A domain per unconfined unit costs one ERTS instance per unit on the
boards; the board port measures each driver's interrupt-to-handler latency
and throughput against gate G9's thresholds
([design-system.md](design-system.md#the-driver-table)).

## Portability

A new board adds its devices' entries to `hw/kernel_devices.txt`, drivers
for any device kind the table lacks, its early console, its manifest, its
trial request if it has one, its crash region if its RAM survives a reset,
and a section of this document; generic code does not change (PL1). A
platform of another architecture also needs that architecture's binding.

## Dependencies

No new dependencies: the Raspberry Pi firmware and TF-A's BL31 are in the
dependency table of [design.md](design.md#dependencies), with swtpm among
its test tools.

## Alternatives considered

**A board support package per board.** Each board would have C code that
knows its devices and their addresses. It loses: board facts come from the
device tree, so a board is data, and a branch per board in generic code
would grow with every board (PL1).

**Driving more of the boards' firmware.** The kernel could use the
firmware's mailbox for clocks, power and display. It loses: the firmware is
closed and resident, so the kernel reaches it only for the trial request
and, once at boot, the board's key, and keeps its mailbox out of every
driver's reach (PL2).

**The firmware's own cryptography service for the board's key.** Raspberry
Pi's firmware can sign and compute HMACs with the key without showing it
to the operating system's user space. It loses: in erXos only the kernel
reaches the mailbox, and code in kernel mode can read the OTP hardware
directly anyway, so the service would hide the key from no one who could
otherwise read it, and erXos would depend on a firmware interface for
every derivation instead of one read at boot.

**The Pi 4's own boot stub.** Booting the Pi 4 without TF-A would leave
its other CPUs on a spin table and its reset to the board's watchdog, two
paths in the kernel that no other platform needs. It loses: TF-A's BL31,
already trusted on the Pi 5, gives the Pi 4 the PSCI calls the other
platforms have, so every platform starts CPUs and ends the machine one way
([Firmware](#firmware)).

**The crash record on the medium.** The kernel could write the record to
a slot's partition before the reset. It loses: the block driver is an
Erlang process in a domain that has just ended with the system domain,
and the kernel drives no storage; a reserved region of RAM needs no
driver, and a board whose RAM does not survive a reset still has the
early console.

**A console in the kernel.** The kernel could drive the console's and
the host link's UARTs itself, with receive and transmit rings behind a
console object and calls to read, write and bind them. It loses: a byte
stream is device work like any other, which a driver in the system
domain does over the device NIF, so the kernel would carry a device
class, its buffers, its limits and its calls for no guarantee a driver
cannot give. What only the kernel can say, at boot and at a panic or an
end when nothing above it runs, needs a polled writer and nothing more.

**PCIe configuration space in the devices domain.** The devices domain
could hold configuration space and run the PCIe enumerator beside the
slow devices' drivers, saving a domain. It loses: configuration space
puts its holder in the trusted base whole, so every slow device's driver
would join the trusted base with it, on every platform. A PCIe domain
that holds that space and nothing else keeps the trusted base to the
enumerator, by one rule that needs no knowledge of the platform's IOMMU.

**The hardware watchdog reloaded from the system runtime's pet.** The
platform layer could reload the board's watchdog only when the runtime
pets the kernel's. It loses: before the first pet, the runtime's boot
would have to fit the hardware timeout, and a hang of the runtime would
be reset by the hardware before the kernel's deadline, without a crash
record. Reloading from the kernel's timer while the kernel's deadline
stands leaves the hardware watchdog exactly one job, a kernel that stops
running (PL4).

## Risks and open questions

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| The first Pi 4 revisions take longer than 1 s to store the trial flag | low | a trial request lost, the committed slot boots | the board port checks the timing; the watchdog resets anyway |
| The firmware places the device tree over the single file, refuses a kernel file that long, or describes `/chosen` differently than expected | low | the kernel's boot stops with a message | the boot probe confirms each board before anything depends on it |
| The BCM2712's link drops between the PCIe enumerator's check and a configuration access | low | the PCIe domain ends and is restarted, or an asynchronous abort stops an unrelated thread | the enumerator checks the link before each access; the board port measures whether the abort is synchronous; a restart of the PCIe domain re-reads configuration space and changes no running function |
| The crash region does not survive `SYSTEM_RESET` on a board, or the firmware clears it | medium | no crash record after a reset on that board; the early console alone | the boot probe checks it; the record's check rejects what the firmware left; the early console carries every record |
| A damaged record partition, or a slot without valid boot files, lets the bootloader's `PARTITION_WALK` boot another partition than the record names, or leaves the card unbootable | low | the wrong slot boots, or the board needs an installation | the record changes only at a commit and a torn record needs an installation ([design-storage.md](design-storage.md#risks-and-open-questions)); the board pass records the EEPROM's `BOOT_ORDER` and `PARTITION_WALK` and what a card with a damaged record partition boots |
| A reset through the power-management watchdog boots `kernel_watchdog_partition` rather than `autoboot.txt`'s slot | low | a reset boots the wrong slot | each slot's `config.txt` leaves the setting unset; the board port checks which slot a watchdog reset boots |
| The system runtime's first pet comes after the kernel's deadline on a board | medium | a boot loop | the board port measures the time to the first pet and checks that it fits `B` |
| A firmware version answers the mailbox's read of the key's rows differently, or not at all | low | the board has no device secret, and a vault configured for `device` serves no login | the board port records the firmware version its read needs, as it does for the trial request |
| Checking `boot.img` under secure boot lengthens every boot | high | seconds per boot, in proportion to the boot image's size | the boot image stays small, the EROFS images holding the rest; the board port measures it |
| The Pi firmware mishandles the extended partition in the fourth entry of the boot medium's table | low | the board does not boot the medium | the firmware boots only partitions of the first three entries; the boot probe checks the layout on each board before anything depends on it |
| The system domain's console driver leaves the UART unable to transmit when the kernel panics or ends the machine | low | the kernel's report lost on the console | the bound on each polled byte ends the machine regardless; on the boards the crash region keeps the record |
| RP1, one unit, puts the Raspberry Pi 5's Ethernet, USB hosts and RP1's slow devices in one domain | certain | a register abort of any of RP1's devices ends the domain and every RP1 driver with it, and a reset of one RP1 device resets all | the domain service restarts the domain from the manifest, and each RP1 driver resets its device as it starts; RP1's devices cannot be given apart, since they share one function, one reset and one interrupt boundary |
| An Erlang driver misses a board device's timing | medium | a device the Erlang driver cannot serve | gate G9's measurement per device; a native shim in a sub-space port of the driver's domain as the exception the driver table records ([design-system.md](design-system.md#the-driver-table)) |

Two questions are with the user, each decided provisionally in
[design.md](design.md#risks-and-open-questions): whether the device-secret
page, a departure from Fiasco that the kernel's
[L4 lineage](design-kernel.md#l4-lineage) records, stays as designed; and
whether a late asynchronous error on the Raspberry Pi 4, which reads no
error records, stops the thread a window presumes, as
[design-kernel.md](design-kernel.md#interrupts-time-and-entropy)
describes, or whether the board's devices are contained instead.

## References

* QEMU 11.1.2, the `virt` machine, under TCG and HVF, as measured in
  [research-baselines.md](research-baselines.md) and summarised in
  [research-kernel-bases.md](research-kernel-bases.md#qemu-virt-under-tcg-and-hvf).
* The Raspberry Pi 4 Model B and Raspberry Pi 5, their firmware, device
  trees and boot selection, TF-A 2.15.0's Raspberry Pi 4 port, RP1 and
  PCIe on the Pi 5, the power-management watchdog's range and TF-A's
  `SYSTEM_RESET` through it, as checked in
  [research-boards-storage.md](research-boards-storage.md).
* Arm Power State Coordination Interface (DEN 0022).
* Raspberry Pi, "Using one-time programmable (OTP) memory on Raspberry Pi
  SBCs", white paper RP-003611-WP, version 3, 2026-03-03 (the
  device-specific private key: 8 rows on the Pi 4, 16 on the Pi 5, read
  through the firmware's mailbox; no hardware-protected key store; the
  firmware's cryptography service); Raspberry Pi, "Raspberry Pi 4 Boot
  Security", white paper RP-004651-WP, version 1.4, 2023-05-31
  (`boot.img` and `boot.sig`, `tryboot.img`, the 3.5 s cost of checking a
  9 MB image, and no anti-rollback); Raspberry Pi, `usbboot`,
  `docs/secure-boot.md` (the chain of trust, the Pi 5's countersigned
  bootloader, and that code in kernel mode can read the OTP hardware
  directly); Raspberry Pi documentation, `autoboot.txt`
  (`tryboot_a_b=1` loads `config.txt` and `boot.img` from the trial's
  partition) and `config.txt`'s boot options (`kernel_watchdog_timeout`,
  `kernel_watchdog_partition`); all read 2026-10-31.
* QEMU, "QEMU TPM Device" (`docs/specs/tpm.rst`) and `hw/core/sysbus-fdt.c`
  (`tpm-tis-device` on the `virt` machine, `tcg,tpm-tis-mmio`, a 0x5000-byte
  register block), master branch, read 2026-10-31; swtpm 0.10.2,
  BSD-3-Clause.
* Linux's reading of `dma-ranges`, `of_dma_get_range` and
  `of_dma_configure_id`, as summarised in
  [research-boards-storage.md](research-boards-storage.md#linuxs-reading-of-dma-ranges).
* The boards' CPU features: for the Raspberry Pi 4's BCM2711, CRC32 but no
  ARMv8 cryptography extensions, the Raspberry Pi forums, "RPi4 BCM2711
  and ARMv8 Crypto Extensions?",
  https://forums.raspberrypi.com/viewtopic.php?t=243410, and
  meta-raspberrypi issue 964,
  https://github.com/agherzan/meta-raspberrypi/issues/964; for the
  Raspberry Pi 5's BCM2712, `aes pmull sha1 sha2 crc32` in its
  `/proc/cpuinfo`, hrw/arm-socs-table issue 96,
  https://github.com/hrw/arm-socs-table/issues/96 (all read 2026-10-31).
