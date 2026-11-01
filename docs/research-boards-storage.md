# Research record: boards, network stacks and file systems

A point-in-time report on the facts behind four directions of erXos's
design: the first boards after QEMU (the Raspberry Pi 4 Model B, then the
Raspberry Pi 5), A/B updates of the system on those boards, the network
stack (lwIP first, then FreeBSD's) and the file systems (the EROFS format
for read-only images; littlefs, then erXos's own implementation of F2FS,
for read-write storage). It also records the licences that bear on them and
on the notices erXos ships, and the checks behind the cryptography
libraries, the toolbox, the command shell's oracle, PCIe on the Raspberry
Pi 5, device addresses and the kernel's speculation mitigations. The record
chooses nothing: the choices are the user's and live in
[design.md](design.md#decisions), [design-storage.md](design-storage.md)
and [design-shell.md](design-shell.md). Findings here are never edited in
place; a re-check gets a new record.

**Date:** 2026-10-30.
**Host:** Apple M4 Max, macOS 27.0.1.
**Sources read** over HTTP, from the installed QEMU, and from local copies
under `~/erxos-scratch/` (the L4Re snapshot 26.09.0, a clone of Fiasco at
`50bbe8a9`, a subset of FreeBSD 15.1-RELEASE-p6's `sys/`, littlefs 2.11.3,
the OTP 29.1.2 source tarball). No git command, script, makefile or binary
from any of them was run; commit identifiers come from reading refs over
HTTP.

## Method

A verification pass on 2026-10-30 checked a list of claims against primary
sources: device trees, data sheets, firmware and boot-stub sources, the
Raspberry Pi documentation, Fiasco's board support, QEMU's machine list and
source, the licence files and headers of each candidate, and the authors'
own pages. Further checks the same day: the SPDX identifiers of OTP 29.1.2
and of FreeBSD's network stack, counted with `grep`, `sort` and `uniq -c`;
littlefs's header and README; the Raspberry Pi firmware licence; the SPDX
lines of Linux's device trees for both boards and of its F2FS header; the
Raspberry Pi documentation of `tryboot` and `autoboot.txt`; the
Raspberry Pi kernel's reboot path; and, in local copies, two device trees,
two watchdog drivers and TF-A's Raspberry Pi 4 document
([Checks against local copies](#checks-against-local-copies)). Line
numbers ("l.") refer to the
versions under [Sources](#sources). "Could not verify" marks a claim no
primary source confirmed; "(inferred)" marks a conclusion drawn from
reading code.

## Raspberry Pi 4 Model B (BCM2711)

* **Interrupt controller.** A GIC-400, an implementation of GICv2: "contains
  an ARM GIC-400 interrupt controller, which is enabled by default" (BCM2711
  ARM Peripherals, §6.3, p.89), with 192 SPIs (§6.5.1, p.92) beside a
  legacy controller. Linux v7.3's `bcm2711.dtsi` l.56-66 declares
  `"arm,gic-400"`, mapped at `0xff841000` (l.41-43).
* **No IOMMU.** Neither upstream Linux v7.3 nor the Raspberry Pi kernel
  (`rpi-6.18.y` at `b3495ea4`, every file in the `bcm2711-rpi-4-b.dts`
  include chain) has an IOMMU or SMMU node. The peripherals document is
  silent, but it leaves out PCIe, Ethernet and the GPU. The PCIe
  controller's 3 GB inbound limit is a workaround for a hardware bug, not
  confinement (`bcm2711.dtsi` l.578-583), and the large-address DMA engines
  reach the full 35-bit address space (§1.2.2, p.5).
* **Kernel file.** The firmware loads `kernel8.img` by default; `kernel=`
  overrides it, and gzip-compressed images are accepted (Raspberry Pi
  documentation, `config_txt/boot.adoc` l.20-42).
* **Image header.** When the arm64 header's magic is present, "the text
  offset is read and honoured… an extra 2MB is added", so kernels load at
  `0x200000` (P. Elwell, raspberrypi/firmware issue 1415, 2020-06-25: an
  engineer's comment, not documentation). The default load address for
  64-bit kernels is `0x200000` (`legacy_config_txt/boot.adoc` l.38-40, a
  page marked "no longer officially supported"). Whether `image_size` and
  the flags are honoured: could not verify.
* **Entry.** The firmware's built-in stub (`armstubs/armstub8.S`) runs at
  EL3 with secure monitor calls disabled (l.59-66), so there is no PSCI; it
  drops to non-secure EL2 with interrupts masked (l.74-80, 143-148) and
  jumps to the kernel with `x0` holding the device tree's address and
  `x1` to `x3` zero (l.159-170). The other cores wait on a spin table at
  `0xd8` to `0xf0` (l.151-158, 175-191). This matches Linux v7.3's
  `Documentation/arch/arm64/booting.rst` l.82-88, 138-142, 163-165 and
  174-175.
* **Device tree licence.** Linux's `bcm2711-rpi-4-b.dts` is `GPL-2.0` (its
  SPDX line, master).

## Raspberry Pi 5 (BCM2712 and RP1)

* **Interrupt controller.** A GIC-400 (Linux v7.3 `bcm2712.dtsi`
  l.337-338; the Raspberry Pi kernel's `bcm2712.dtsi` l.266-277). Neither
  tree has an Arm SMMU.
* **IOMMUs that do not confine.** Only the Raspberry Pi kernel declares
  IOMMUs (`bcm2712-ds.dtsi` l.274-305), all `brcm,bcm2712-iommu` sharing one
  cache: one before the HEVC decoder and the ISP back end, one before the
  display controller, and one on the path from PCIe to RP1, which the
  Pi 5's tree assigns only to RP1's camera, DSI, DPI and composite-video
  blocks (`bcm2712-rpi-5-b.dts` l.240-265), not to its Ethernet or USB.
  Each has one address space for all its devices (`#iommu-cells = <0>`);
  the driver passes addresses below its window through untranslated
  (`drivers/iommu/bcm2712-iommu.c` l.181-203); RP1's devices reach "up to
  64GB system RAM" directly (dts l.138-166). A window based at zero turns
  pass-through off (driver l.655-658), so confining all of RP1 as one
  group might be possible (inferred, untested).
* **RP1.** RP1 carries the Ethernet controller (`"raspberrypi,rp1-gem",
  "cdns,macb"`, `rp1.dtsi` l.999) and two DWC3 USB hosts (l.1120, l.1136),
  and sits on PCIe as device `pci1de4,1` under `pcie2` (Linux v7.3
  `bcm2712-rpi-5-b.dts` l.21-42).
* **Mailbox, watchdog and random generator.** Linux v7.3's `bcm2712.dtsi`
  (SHA-256
  `18c5f6cd8cb6202900d7d07612b2b241a20e7ebac8811d0be3eb351b3c868b6b`,
  licensed `(GPL-2.0 OR MIT)` at l.1) describes the firmware's mailbox
  (`brcm,bcm2835-mbox` at `7c013880`, l.237-242), the power-management
  watchdog (`"brcm,bcm2712-pm", "brcm,bcm2835-pm-wdt"` at `7d200000`,
  l.254-261) and a random generator (`brcm,bcm2711-rng200` at `7d208000`,
  l.296-300), each compatible with the Pi 4's; seL4's older copy of the
  tree has no random-generator node
  ([Checks against local copies](#checks-against-local-copies)). The Pi 4's
  tree takes its mailbox from `bcm283x.dtsi` (Raspberry Pi kernel, l.101),
  which Linux v7.3's `bcm2711.dtsi` includes (l.2).
* **MSIs and PCIe windows.** In the same `bcm2712.dtsi`, the PCIe bridge
  that carries RP1 takes its MSIs from `mip0` (`brcm,bcm2712-mip`,
  l.629-636), whose `msi-ranges` are GIC SPIs 128 to 191. The bridge's
  `dma-ranges` (l.618-624) hold a 4 MiB window at PCIe address 0, a
  64 GiB window of RAM, and the 4 KiB window of the MIP's doorbell.
* **Kernel file.** `kernel_2712.img` by default, falling back to
  `kernel8.img` (`config_txt/boot.adoc` l.20-42).
* **Entry.** The firmware includes a TF-A BL31 that provides PSCI and
  enters the kernel at EL2 with `x0` holding the device tree's address
  (Raspberry Pi TF-A, `docs/plat/rpi5.rst` l.7-8, 73-76;
  `plat/rpi/common/rpi4_bl31_setup.c` l.152-164; `rpi3_common.c`
  l.192-200). The same document, l.10-13: "The SoC does not seem to
  feature a secure memory controller of any kind."
* **Device tree licence.** Linux's `bcm2712-rpi-5-b.dts` is
  `(GPL-2.0 OR MIT)` at its top; the files it includes were not checked,
  and the compiled copy in seL4 is labelled GPL-2.0-only
  ([Checks against local copies](#checks-against-local-copies)).

## Booting a chosen partition on the Raspberry Pi

From the Raspberry Pi documentation (`raspberry-pi.html`, "Fail-safe OS
updates", and `config_txt.html`):

* "All Raspberry Pi models support `tryboot`": a one-shot flag which, if
  set, "is cleared but causes `tryboot.txt` to be loaded instead of
  `config.txt`". Because the flag is cleared before the firmware starts, "a
  crash or reset will cause the original `config.txt` file" to load on the
  next boot. Linux sets it with `reboot '0 tryboot'`. On the Pi 4 Model B
  revisions 1.0 and 1.1 the flag is kept in the EEPROM, which must not be
  write-protected.
* `autoboot.txt` is "an optional configuration file placed in the initial
  boot partition" that selects the partition to boot (`boot_partition`).
  With `tryboot_a_b=1` the flag switches whole partitions, each with its
  normal `config.txt`; the `[tryboot]` filter "succeeds if the `tryboot`
  reboot flag was set" and is "intended for use in autoboot.txt to select a
  different `boot_partition` in `tryboot` mode for fail-safe OS updates".
  In the documented flow, an update is tested with a tryboot reboot; after a
  failure, a normal reboot "without altering `autoboot.txt`" returns to the
  old partition because "the `tryboot` flag is automatically cleared".
  On the Pi 5, a partition counts as bootable only if it holds a
  `config.txt`. The pages read state no model or bootloader version for
  `autoboot.txt` itself.
* The firmware reports the flag "at `/proc/device-tree/chosen/bootloader/tryboot`"
  and "the final partition number used for booting" at
  `/chosen/bootloader/partition`.
* Linux's path: `rpi_firmware_notify_reboot()` in the Raspberry Pi kernel's
  `drivers/firmware/raspberrypi.c` (`rpi-6.18.y`) sends the firmware
  property `RPI_FIRMWARE_SET_REBOOT_FLAGS` with the value `0x1` when the
  reboot argument contains `" tryboot"`, then `RPI_FIRMWARE_NOTIFY_REBOOT`.
* **Watchdogs before the operating system.** `config_txt/boot.adoc`
  (SHA-256
  `d0348cc8df9e117c037ff5b68e5e9cf04001d46993ff6c9a701269bf075655ce`)
  documents `kernel_watchdog_timeout`, which "enables a hardware watchdog
  timer that is handed over to the operating system (OS) at boot", resets
  the system if the OS does not "kick" it within the timeout, and adds
  `watchdog.open_timeout` to the kernel command line (l.242-260). "If both
  `BOOT_WATCHDOG_TIMEOUT` (EEPROM/bootloader setting, only supported on
  Raspberry Pi 4 and 5) and `kernel_watchdog_timeout` are set, the
  bootloader will seamlessly hand over from the bootloader watchdog to the
  kernel watchdog at the point the OS is started. This provides continuous
  watchdog coverage from power-on through to OS runtime" (l.253).
  `kernel_watchdog_partition` names the partition to boot after the
  watchdog fires (l.262-271). What the bootloader does at hand-over when
  only `BOOT_WATCHDOG_TIMEOUT` is set, and the longest timeout each
  setting accepts, are not stated in the lines read.

## Checks against local copies

Read on 2026-10-30 in copies under `~/erxos-scratch/borrow/`:

* **The Pi 4's device tree**, in seL4 16.0.0's `tools/dts/rpi4.dts`, which
  says it "is derived from an intermediate build stage of the Linux kernel"
  and is GPL-2.0-only:
  * `stdout-path = "serial1:115200n8"` (l.30), where `serial1` is the mini
    UART, `brcm,bcm2835-aux-uart` (l.23, 917); `serial0` is the PL011 at
    `7e201000` (l.22), one of five PL011s (l.827, 1086, 1096, 1106, 1116);
  * the legacy peripherals' and EMMC2's `dma-ranges` map bus address
    `0xc0000000` to the first GiB of RAM (l.74, 1400), and PCIe's inbound
    range covers 3 GB (l.1488);
  * a hardware random generator, `brcm,bcm2711-rng200` (l.1080-1081);
  * the Ethernet controller on the SoC, `brcm,bcm2711-genet-v5` (l.1506),
    and the SD controller, `brcm,bcm2711-emmc2` (l.1403);
  * the power-management watchdog, `brcm,bcm2835-pm-wdt`, at `7e100000`
    (l.1070-1071);
  * register pages shared between devices: the five PL011s at `7e201000`,
    `7e201400`, `7e201600`, `7e201800` and `7e201a00` lie in one 4 KiB page
    (l.826-828, 1085-1117); the mini UART at `7e215040` shares a page with
    the auxiliary enable register at `7e215000` and two SPI controllers at
    `7e215080` and `7e2150c0` (l.908-936); the mailbox at `7e00b880`
    (l.97-99) shares a page with the VideoCore's message interface,
    `brcm,bcm2835-vchiq`, at `7e00b840` (l.1342-1344).
* **The Pi 5's device tree**, in seL4's `tools/dts/rpi5b.dts`, also
  labelled GPL-2.0-only: one PL011 (l.241), the console `serial10` at
  `107d001000` (l.477, 481), and no random-generator node.
* **The watchdog's range.** OpenBSD 8.0's `sys/dev/fdt/bcm2835_dog.c` masks
  the timeout to 20 bits (`PM_WDOG_TIMEMASK 0x000fffff`, l.42) in units of
  1/65,536 s (l.146), so at most about 16 s; RTEMS 6.2's
  `bsps/aarch64/raspberrypi/start/watchdog.c` uses the same 65,536 ticks
  per second (l.53-54).
* **TF-A on the Pi 4.** TF-A 2.15.0's `docs/plat/rpi4.rst` describes a
  BL31-only port that the firmware loads as the armstub (`armstub=` in
  `config.txt`) at EL3. It drops to the kernel at EL2 with the device tree
  in `x0`, "will patch the provided device tree blob in memory to advertise
  PSCI support", and adds a reserved-memory node for itself. "This port
  isn't secure": "The SoC does not seem to feature a secure memory
  controller of any kind." The firmware "knows how to access the MMC
  controller and how to parse a FAT filesystem" and loads its components
  "from the first FAT partition on the SD card". Its licence is TF-A's
  BSD-3-Clause.
* **TF-A's PSCI operations on the Pi 4.** The local copy has no `plat/`
  directory, so two files were fetched at tag `v2.15.0`:
  `plat/rpi/rpi4/platform.mk` (SHA-256
  `dfb49638ad8f2fea8c8572f6a6cc1e0b1dd009f207c800b686fb4efea3118cb9`),
  whose l.30 builds `plat/rpi/common/rpi3_pm.c` (SHA-256
  `6e34170d207a5924f20eb32d403b5dbc88d085eb421f05d5dafe04b5c01add34`) into
  BL31. Its `plat_rpi3_psci_pm_ops` (l.270-279) implement `CPU_ON` by
  releasing the CPU from the firmware's hold area with a store and `sev`
  (l.146-166) and `CPU_OFF` by parking it again (l.135-140, 184-209).
  `SYSTEM_RESET` is a full reset through the power-management watchdog
  after 10 watchdog ticks (l.215-245). `SYSTEM_OFF` writes the halt value
  `0x555` into `PM_RSTS` and then resets the same way (l.247-265); the
  comment at l.254-257 says the board cannot turn itself off, and the
  value "tells the bootcode.bin firmware not to continue the regular
  bootflow and to stay in a low power mode". Whether the firmware's
  `tryboot` flag, set through the mailbox before the call, survives this
  reset was not checked.

## The Raspberry Pi firmware licence

`boot/LICENCE.broadcom` (raspberrypi/firmware, master), copyright Broadcom
Corporation (2006) and Raspberry Pi (Trading) Ltd (2015): redistribution and
use in binary form without modification, only "for the purposes of
developing for, running or using a Raspberry Pi device" (or an authorised
derivative), reproducing the copyright notice and disclaimer, without using
Broadcom's name for endorsement.

## Fiasco's Raspberry Pi support

The `rpi` board directory of the L4Re snapshot 26.09.0 is byte-identical to
Fiasco's at `50bbe8a9`. Its `Kconfig` l.2 reads "Raspberry Pi (Broadcom
283X, 2711, 2712)"; the Pi 4 option selects Cortex-A72, `ARM_GIC` and
`HAVE_ARM_GICV2` (l.43-49), the Pi 5 option 64-bit, Cortex-A76, `ARM_GIC`,
`HAVE_ARM_GICV2` and `ARM_PSCI` (l.51-60). `pic-arm-rpi.cpp` l.177-198
creates an `Irq_mgr_single_chip<Gic_v2>`, with `Gic_v2` defined in the
generic `src/kern/arm/gic_v2.cpp` l.7. `mem_layout-arm-rpi.cpp` l.35-63
places the GIC at `0xff841000` and `0xff842000` on the BCM2711 and at
`0x107fff9000` and `0x107fffa000` on the BCM2712. L4Re's `bootstrap` knows
both chips (`l4/pkg/bootstrap/server/src/platform/rpi.cc` l.129).

## QEMU's Raspberry Pi models

QEMU 11.1.2 (`-machine help`) offers `raspi0`, `raspi1ap`, `raspi2b`,
`raspi3ap`, `raspi3b` and `raspi4b` ("Raspberry Pi 4B (revision 1.5)"), and
no Pi 5; the v11.1.3 source agrees (`hw/arm/meson.build` l.29-33). The
`raspi4b` model lacks PCIe and the Ethernet controller
(`docs/system/arm/raspi.rst` l.40-45) and models the GIC-400
(`hw/arm/bcm2838.c` l.62). Whether it runs under HVF was not checked.

## Network stacks

* **FreeBSD's stack.** Of the 407 C files under `sys/net`, `sys/netinet`
  and `sys/netinet6` in the local FreeBSD 15.1 copy, 302 carry an SPDX tag:
  179 `BSD-3-Clause`, 116 `BSD-2-Clause` (one written
  `BSD-2-Clause-FreeBSD`), one `BSD-3-Clause AND BSD-2-Clause`, and six
  `BSD-4-Clause`, the advertising clause: `netinet/in_cksum.c`,
  `net/if_media.c`, `net/if_media.h`, `net/if_bridge.c`,
  `net/if_bridgevar.h` and `net/bridgestp.h`. The other 105 were not read.
* **The six BSD-4-Clause files**, read in the same copy with a script that
  prints each file's copyright and acknowledgement lines. `net/if_media.c`
  and `net/if_media.h` are Jonathan Stone's (1997), with an
  acknowledgement naming him (l.6, 19-21). `net/if_bridge.c`,
  `net/if_bridgevar.h` and `net/bridgestp.h` are Wasabi Systems' (2001),
  whose clause names Wasabi (l.6, 19-22), and Jason L. Wright's (1999,
  2000), whose block carries the clause in the two headers (l.41, 52-54)
  but not in `if_bridge.c` (l.41-49). `netinet/in_cksum.c` is the Regents
  of the University of California's (1988 to 1993) and Matt Thomas's
  (1996), under one clause naming Berkeley (l.4-7, 17-20). FreeBSD's
  `COPYRIGHT` (SHA-256
  `4bb0fdcd07d8a7774ba71faecf86d7db64d7a8574ee395f51a86d629c39f77cc`)
  reproduces Berkeley's letter of 22 July 1999, which deletes that clause
  from Berkeley's own files (l.95-123); it does not speak for other
  holders.
* **F-Stack** runs FreeBSD's stack in user space over DPDK. Its main code
  is BSD-2-Clause (LICENSE l.1); it bundles DPDK, FreeBSD code it labels
  BSD-4-Clause, and a GPL-2.0 microthread framework (l.50-52). Version 2.0
  was released on 2026-10-20, and its FreeBSD code reports version 1500068,
  the FreeBSD 15 line, though its README names 11.01 and 13.0.
* **libuinet** packaged FreeBSD 9.1's stack as a user-space library (README
  l.4-6). Its own code is BSD-2-Clause (`lib/libuinet/uinet_api.c`), with
  no top-level licence file; its last commit is of 2017-02-08, with no
  releases.

## File systems

* **EROFS.** Linux v7.3's `fs/erofs` has 15 files under GPL-2.0-only and 7
  under GPL-2.0-or-later, but the on-disk format header `erofs_fs.h` is MIT
  (l.1). The format is documented in `Documentation/filesystems/erofs.rst`
  ("On-disk details", l.167) and at erofs.docs.kernel.org (core format,
  extended attributes, chunked layout; no page for the compressed layout
  was found). erofs-utils v1.9.4's `COPYING` puts the library under
  "GPL-2.0+ OR MIT" and the rest under MIT, `mkfs/main.c` included, but
  `lib/hashmap.c` is GPL-2.0 and is built into the library
  (`lib/Makefile.am` l.46), so `mkfs.erofs` binaries contain GPL-2.0 code.
* **erofs-utils 1.9.4, file by file.** The SPDX lines of all 96 C sources
  and headers under `lib/`, `include/` and `mkfs/` of the v1.9.4 snapshot
  (SHA-256 `7d135aa2550326a5acf20f53c518aea5a8900015ce50700044e40f818c31dd80`),
  read with a script that prints each file's first SPDX line: 87
  `GPL-2.0+ OR MIT`; 3 `GPL-2.0`, namely `lib/hashmap.c`,
  `include/erofs/hashmap.h` and `include/erofs/flex-array.h`; 2 `MIT`,
  `include/erofs_fs.h` and `mkfs/main.c`; `lib/liberofs_xxhash.h`
  `BSD-2-Clause OR GPL-2.0+`; `lib/xxhash.c` `BSD-2-Clause OR
  GPL-2.0-only`; `lib/sha256.c` `Unlicense`; and `lib/liberofs_base64.h`,
  two prototypes, with no tag, which `COPYING` puts under MIT ("All other
  files use the MIT license unless explicitly stated otherwise").
  `flex-array.h` is included only by `hashmap.h`, and `hashmap.h` only by
  `lib/hashmap.c` and `lib/blobchunk.c`, the chunk deduplication, which
  uses the hash table's init, add, lookup by hash, remove, iteration and
  free. `configure.ac` makes every external library optional: LZ4,
  liblzma, zlib, libdeflate, libzstd, QPL, xxHash, libcurl, OpenSSL,
  libxml2, json-c, libnl3, liburing, FUSE, libuuid and libselinux.
* **Compression libraries**, from the Homebrew copies on the host: LZ4
  1.10.0's `LICENSE` puts "all files in the `lib` directory" under
  BSD-2-Clause and the rest under GPL-2.0-or-later; XZ Utils 5.8.4's
  `COPYING`: "liblzma is under the BSD Zero Clause License (0BSD)";
  Zstandard 1.5.7 is "dual BSD OR GPLv2" (`README.md` l.8, `LICENSE`
  BSD-3-Clause). zlib is under the Zlib licence. libdeflate was not
  checked.
* **F2FS.** Linux's F2FS is GPL-2.0 (every top-level file in v7.3;
  `fs/f2fs/f2fs.h` on master). The superblock's feature bits name what an
  image uses; `f2fs.h` on master defines seventeen: `ENCRYPT`, `BLKZONED`,
  `ATOMIC_WRITE`, `EXTRA_ATTR`, `PRJQUOTA`, `INODE_CHKSUM`,
  `FLEXIBLE_INLINE_XATTR`, `QUOTA_INO`, `INODE_CRTIME`, `LOST_FOUND`,
  `VERITY`, `SB_CHKSUM`, `CASEFOLD`, `COMPRESSION`, `RO`, `DEVICE_ALIAS`
  and `PACKED_SSA`.
* **F2FS's mount options**, in Linux's `Documentation/filesystems/f2fs.rst`
  as published on kernel.org (SHA-256
  `3f20673d6e11f2944a469eed96c339a8dc8581804601bba380c8d923643a37d0`):
  `checkpoint=disable`, "While disabled, any unmounting or unexpected
  shutdowns will cause the filesystem contents to appear as they did when
  the filesystem was mounted with that option", and the mount must collect
  garbage first, or may be given a share of the disk to give up
  (l.282-294); `disable_roll_forward` turns off "the roll-forward recovery
  routine" (l.126), and `norecovery` does so on a read-only mount,
  "mounted read-only (i.e., -o ro,disable_roll_forward)" (l.127-128); in
  `mode=lfs` "there should be no random writes towards main area"
  (l.232-234).
* **dm-verity's hash tree**, in Linux's
  `Documentation/admin-guide/device-mapper/verity.rst` as published on
  kernel.org (SHA-256
  `e3b8855669604f1e90aed5dbe70850318d2fb01dee95a3f007ccf83096b879c3`):
  format version 1, "the current format that should be used for new
  devices", prepends the salt when hashing and pads each digest "to the
  power of two" (l.20-29); hashes may follow the data on the same device
  (l.49-52); each tree node is the hash of a block of its children's
  hashes (l.196-207).
* **littlefs** 2.11.3 is BSD-3-Clause (`LICENSE.md`: Arm Limited 2017, the
  littlefs authors 2022). Its README: "if power is lost the filesystem will
  fall back to the last known good state"; "All POSIX operations, such as
  remove and rename, are atomic, even in event of power-loss"; file updates
  are committed only at sync or close; "RAM usage is strictly bounded" and
  "The filesystem contains no unbounded recursion". `lfs.h` limits files to
  `LFS_FILE_MAX` 2,147,483,647 bytes and names to `LFS_NAME_MAX` 255 bytes
  by default (l.51, l.58); its on-disk version is 2.1 (l.31).
* **QNX's power-safe file system.** QNX OS 8.0's System Architecture guide
  ("Copy-on-write filesystem", updated 2026-06-11): "Everything is COW: both
  metadata and user data"; it "maintains two superblocks: a stable
  superblock … a working superblock"; a commit writes a superblock with a
  higher sequence number and a CRC, and mounting picks the valid one with
  the higher number. Power safety holds only on drives that honour cache
  flushes, and changes since the last commit are not yet durable.
* **HAMMER2** is BSD-3-Clause (DragonFly at `1796b81a`, `sys/vfs/hammer2/`)
  with bundled LZ4, xxhash and zlib code. Ports exist for FreeBSD
  (FreshPorts `filesystems/hammer2` 1.2.13, "experimental write support"),
  NetBSD and OpenBSD (kusumi's repositories, v1.2.13 of 2025-08-22) and
  Linux (jdmanring/linux_hammer2, read-write, Linux 7.3 and later). None
  keeps the core unchanged: the ports carry edited copies of it behind OS
  shim headers, and the FreeBSD port's `hammer2_flush.c` and
  `hammer2_chain.c` differ from DragonFly's in 122 and 589 places, partly
  from upstream drift since the import.
* **UFS2** in FreeBSD 15.1 mixes BSD-3-Clause and BSD-2-Clause; soft updates
  and their journal live in `ffs_softdep.c`, under BSD-2-Clause.
* **OpenZFS** is CDDL-1.0 (`1547ff6b`, `LICENSE` and `META`), with per-file
  exceptions such as the GPL-2.0-or-later Linux SPL.
* **Reliance Edge** is "power-fail safe" and transactional, under GPLv2
  (version 2 only, per its headers) or a commercial licence
  (tuxera/reliance-edge at `da455bd5`, README l.3, 43-48, 88-96).
* **Other Linux file systems.** Btrfs is GPL-2.0; NILFS2 is mostly
  GPL-2.0-or-later (39 of 42 files); bcachefs left Linux after v6.17 and
  ships out of tree under GPLv2.

## Licences inside OTP 29.1.2

The SPDX tags under `lib/`, `erts/`, `bootstrap/` and `make/` of the
OTP 29.1.2 tarball: 6,254 `Apache-2.0`; 236 `Apache-2.0 AND
LicenseRef-scancode-wxwindows-free-doc-3`; 169 `Zlib`; 108 `BSD-3-Clause`;
91 `Apache-2.0 OR LGPL-2.1-or-later`; 36 `LicenseRef-IETF-MIB`; 11
`NOASSERTION` (test data, megaco's standards documents and ASN.1
specifications); 8 `MIT`; 5 `MPL-1.1` (dialyzer test data); 4
`BSD-2-Clause`; 2 `Apache-2.0 AND SGI-B-2.0`; one each of
`LicenseRef-RSA-PKCS5v2-0`, `LicenseRef-RSA-PKCS3` and `Apache-2.0 WITH
LLVM-exception AND BSL-1.0`. The tree has no `NOTICE` file; its licence
texts are `LICENSE.txt` and the files under `LICENSES/` and `FILE-HEADERS/`.

## Cryptography libraries

Checked over HTTP on 2026-10-30:

* **OpenSSL 3.5.** OpenSSL's release strategy says: "Version 3.5 will be
  supported until 2030-04-08 (LTS)". The `LICENSE.txt` on the
  `openssl-3.5` branch is the Apache License, Version 2.0.
* **Monocypher.** Its `LICENCE.md` on `master`: "Monocypher as a whole is
  dual-licensed", the two licences being "a regular 2-clause BSD licence"
  and "the CC-0 from Creative Commons"; "The files in `tests/externals/`
  were placed in the public domain by their respective authors." Its
  README offers SHA-512 and Ed25519 as optional code,
  `src/optional/monocypher-ed25519.c` and `monocypher-ed25519.h`, and names
  no release version on `master`.

## The toolbox

Checked over HTTP on 2026-10-30, with refs read from each repository:

* **toybox.** The `LICENSE` at `master` (`6a0c0ef5`; SHA-256
  `948039f91e7e23916019047a035c69214447323c5fc272aefc0fd21e505bf41d`)
  is the Zero-Clause BSD text: "Permission to use, copy, modify, and/or
  distribute this software for any purpose with or without fee is hereby
  granted." The newest tag is 0.8.15. Its awk, Ray Gardner's
  `toys/pending/awk.c` ("Copyright 2024 Ray Gardner"), is still in the
  pending directory at 0.8.15 and at `master`, the same file at both
  (SHA-256
  `45f80f6b7cb9a35f6fd282f24155d16b20f9d6a2a3fa542898db03d5e6ee96bc`),
  configured `default n`; neither has `toys/posix/awk.c`.
* **wak**, the standalone repository of the same awk: its `LICENSE` at
  `main` (`c757c495`) is the same Zero-Clause BSD text, "Copyright 2024
  Ray Gardner"; its tags are 24.8 and v24.10.
* **toybox's shell**, `toys/pending/sh.c`, is in the pending directory at
  0.8.15.
* **The Open POSIX Test Suite**, in the Linux Test Project's repository
  under `testcases/open_posix_testsuite`: its `COPYING` says "All
  sourcecode generated from scratch by Ngie Cooper is BSD 2-clause
  licensed. All legacy openposix test suite code is GPLv2+ licensed." The
  newest release tag is `20260930`.

## The command shell's oracle

Checked over HTTP on 2026-10-30, with refs read from each repository:

* **plan9port** (`github.com/9fans/plan9port`), `master` at `1f139691`.
  Its `LICENSE` (SHA-256
  `0596b18c65ebc9462dab21e6cded632fe2af56a93ca4c913431a8a45f1b7fa74`) is
  the MIT text under "Copyright © 2021 Plan 9 Foundation", with portions
  by Russ Cox and Google. rc's directory, `src/cmd/rc`, carries `test.rc`
  (93 lines; SHA-256
  `0b075271990f92ae080808d0f5db63997db96cc9c1ca56b5131ca2a34177c6d0`) and
  `checkparse` (31 lines; SHA-256
  `4a0b86198b1e7cd8a97ec0ac1cb7be6b47cd0491ab550d83c12799460b0c00d1`).
* **Homebrew** has no package for it: the formula API's
  `formulae.brew.sh/api/formula/plan9port.json` and `rc.json`, and the
  cask API's `plan9port.json`, each answer 404. The oracle is therefore
  built from the pinned source as a host test tool.
* **Byron Rakitzis's rc** (`github.com/rakitzis/rc`), a reimplementation
  of the same language under the zlib licence, carries `trip.rc`, "take a
  tour of rc" (729 lines at `master`; SHA-256
  `6146d49827f3c8971cdc33e7c80387d38002f2e33f8566d1b77b75f92158b2f9`),
  which also exercises that implementation's extensions.
* **tcsh** (`github.com/tcsh-org/tcsh`), for the later version: its
  `Copyright` file is the University of California's three-clause BSD
  licence, and its newest tag is `TCSH6_24_16`. The development host's
  `/bin/tcsh` reports 6.21.00.

## PCIe on the Raspberry Pi 5

* **`pciex4_reset`** (`config_txt/boot.adoc`, SHA-256 above, l.177-184),
  Raspberry Pi 5 only: "By default, the PCIe x4 controller used by `RP1`
  is reset before starting the operating system. If this parameter is set
  to `0` then the reset is disabled allowing operating system or bare
  metal code to inherit the PCIe configuration setup from the
  bootloader." Its default is 1.
* **Configuration space.** Linux v7.3's
  `drivers/pci/controller/pcie-brcmstb.c` (SHA-256
  `edd83fe0bd5d3ff0989119c6a35001bed63c802a29a7f1567fd18a43b392a9eb`)
  reaches the root port's own configuration space in the controller's
  registers, and every device's through an index register and a data
  window in those registers (`brcm_pcie_map_bus`, l.774-793), not through
  ECAM; it checks the link first because "An access to our HW w/o link-up
  will cause a CPU Abort" (l.786). The BCM2712 entry is `bcm2712_cfg`
  (l.1955-1962).
* **RP1.** Linux v7.3's `drivers/misc/rp1/rp1_pci.c` (SHA-256
  `d9ea659109272063bf40d396712cbcc4e449338788b6a87008f5e56b79946e6b`)
  maps RP1's peripherals through BAR 1 (l.222), refuses a BAR 1 of at most
  64 KiB with "Not initialized - is the firmware running?" (l.209-213),
  enables bus mastering (l.229) and allocates MSI-X vectors (l.231-232).

## Linux's reading of dma-ranges

Linux v7.3's `drivers/of/address.c` (SHA-256
`5a1b2dda196fd29ef3326c15a696eafabb85d7b1894358c6ef9d75eaec519257`),
`of_dma_get_range` (l.900-929), walks up from a device's bus: a level
whose `dma-ranges` is empty passes addresses unchanged ("Ignore empty
ranges, they imply no translation required"); the first level with a
non-empty `dma-ranges` defines the ranges; a level without the property,
once the walk has passed the device's own bus, ends the walk with
`-ENODEV` ("Once we find 'dma-ranges', then a missing one is an error"),
as does reaching the root without a defining level.
`drivers/of/device.c` (SHA-256
`f31c08b3ee0b70475258710980b110434c655480a57676bbab6ec772759ea0b1`),
`of_dma_configure_id` (l.102-116), then configures the device with no
range map, so its device addresses equal the CPU's (inferred: no map
means no offset).

## Linux's speculation mitigations on arm64

In Linux v7.3, read 2026-10-30:

* `arch/arm64/mm/context.c` (SHA-256
  `123d80b2ad9c37b6e9b58296c217744747c87f483cfbc424a1f4695a64cb9728`)
  applies branch-predictor hardening when a CPU switches address spaces
  (`arm64_apply_bp_hardening()`, l.263), and
  `arch/arm64/kernel/entry-common.c` (SHA-256
  `8916d97a8fe887cc12d9bc6659c88366feb6913613e642f5a6b1fc0e09f60d59`)
  on entries from EL0 whose fault address or PC is a kernel address
  (l.588, 641, 700, 715, 847), not on every entry.
* `arch/arm64/kernel/proton-pack.c` (SHA-256
  `bbf4c9d7566aa0ca76889a3b3867895e26f419e27de5c931dfd302d4b5c81ec9`)
  chooses a branch-history mitigation in this order: none where the CPU
  has ECBHB, the `CLRBHB` instruction, a clearing loop, the firmware's
  `ARCH_WORKAROUND_3` (l.1037-1083). The loop runs 8 times on the
  Cortex-A72 and 24 times on the Cortex-A76 (l.866-925). Store bypass is
  mitigated through `PSTATE.SSBS` where the CPU has it, and otherwise
  through the firmware's `ARCH_WORKAROUND_2` (l.348-358, 473-485).

## Sources

Every URL below was accessed on 2026-10-30.

| Source | Version, commit or date | URL |
| --- | --- | --- |
| Fiasco; L4Re snapshot | `50bbe8a981199e17865e8553a4eb02c387b339cf`; 26.09.0 | https://github.com/kernkonzept/fiasco |
| QEMU | 11.1.2 installed; v11.1.3 source | https://gitlab.com/qemu-project/qemu |
| Linux | v7.3; master (device-tree and F2FS SPDX lines, F2FS feature bits) | https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git ; https://raw.githubusercontent.com/torvalds/linux/master/arch/arm/boot/dts/broadcom/bcm2711-rpi-4-b.dts ; https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts ; https://raw.githubusercontent.com/torvalds/linux/master/fs/f2fs/f2fs.h |
| Raspberry Pi kernel | `rpi-6.18.y` at `b3495ea4`; `drivers/firmware/raspberrypi.c` on `rpi-6.18.y` | https://github.com/raspberrypi/linux |
| Raspberry Pi documentation | `7376533a`; the published pages; `config_txt/boot.adoc` with the SHA-256 above | https://github.com/raspberrypi/documentation ; https://www.raspberrypi.com/documentation/computers/raspberry-pi.html ; https://www.raspberrypi.com/documentation/computers/config_txt.html |
| Linux documentation: F2FS; dm-verity | as published on kernel.org, with the SHA-256s above | https://www.kernel.org/doc/Documentation/filesystems/f2fs.rst ; https://www.kernel.org/doc/Documentation/admin-guide/device-mapper/verity.rst |
| Raspberry Pi boot stubs | raspberrypi/tools `439b6198` | https://github.com/raspberrypi/tools |
| Raspberry Pi TF-A | `332b62e0` | https://github.com/raspberrypi/arm-trusted-firmware |
| TF-A | 2.15.0: a local partial copy (`docs/plat/rpi4.rst`), and `plat/rpi/rpi4/platform.mk` and `plat/rpi/common/rpi3_pm.c` fetched at tag `v2.15.0` | https://github.com/TrustedFirmware-A/trusted-firmware-a ; https://raw.githubusercontent.com/TrustedFirmware-A/trusted-firmware-a/v2.15.0/plat/rpi/common/rpi3_pm.c ; https://raw.githubusercontent.com/TrustedFirmware-A/trusted-firmware-a/v2.15.0/plat/rpi/rpi4/platform.mk |
| seL4 | 16.0.0, local copy (`tools/dts/rpi4.dts`, `tools/dts/rpi5b.dts`) | https://github.com/seL4/seL4 |
| OpenBSD | 8.0, local copy (`sys/dev/fdt/bcm2835_dog.c`) | https://github.com/openbsd/src |
| RTEMS | 6.2, local copy (`bsps/aarch64/raspberrypi/start/watchdog.c`) | https://gitlab.rtems.org/rtems/rtos/rtems |
| Raspberry Pi firmware: licence; issue 1415 | master; 2020-06-25 | https://github.com/raspberrypi/firmware/blob/master/boot/LICENCE.broadcom ; https://github.com/raspberrypi/firmware/issues/1415 |
| BCM2711 ARM Peripherals | release 4, 2022-01-18, build `cfcff44` | https://datasheets.raspberrypi.com/bcm2711/bcm2711-peripherals.pdf |
| F-Stack; libuinet | dev `52514377`; last commit 2017-02-08 | https://github.com/F-Stack/f-stack ; https://github.com/pkelsey/libuinet |
| FreeBSD | 15.1-RELEASE-p6 (`sys/` subset and `COPYRIGHT`, local) | https://git.freebsd.org/src.git |
| erofs-utils; EROFS documentation | v1.9.4 (tag object `20ca6747`, commit `f36cadb5`), snapshot `erofs-utils-1.9.4.tar.gz` with the SHA-256 above; - | https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git ; https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git/snapshot/erofs-utils-1.9.4.tar.gz ; https://erofs.docs.kernel.org/en/latest/ondisk/index.html |
| LZ4; XZ Utils; Zstandard | 1.10.0; 5.8.4; 1.5.7, as installed by Homebrew | https://github.com/lz4/lz4 ; https://tukaani.org/xz/ ; https://github.com/facebook/zstd |
| littlefs | 2.11.3 `6cb4e86540eca0d9ba62500a298385c9d863c8be` | https://github.com/littlefs-project/littlefs |
| QNX OS 8.0 System Architecture, "Copy-on-write filesystem" | updated 2026-06-11 | https://www.qnx.com/developers/docs/8.0/com.qnx.doc.neutrino.sys_arch/topic/fsys_COW_filesystem.html |
| HAMMER2: DragonFly; ports | `1796b81a`; v1.2.13 (2025-08-22) | https://github.com/DragonFlyBSD/DragonFlyBSD ; https://www.freshports.org/filesystems/hammer2 ; https://github.com/kusumi ; https://github.com/jdmanring/linux_hammer2 |
| OpenZFS | `1547ff6b` | https://github.com/openzfs/zfs |
| Reliance Edge | `da455bd5` | https://github.com/tuxera/reliance-edge |
| Erlang/OTP | 29.1.2 source tarball (SHA-256 in [design.md](design.md#references)) | https://github.com/erlang/otp |
| Linux v7.3: PCIe, RP1, DMA ranges, speculation | the files and SHA-256s above, at tag `v7.3` | https://raw.githubusercontent.com/torvalds/linux/v7.3/drivers/pci/controller/pcie-brcmstb.c ; https://raw.githubusercontent.com/torvalds/linux/v7.3/drivers/misc/rp1/rp1_pci.c ; https://raw.githubusercontent.com/torvalds/linux/v7.3/drivers/of/address.c ; https://raw.githubusercontent.com/torvalds/linux/v7.3/drivers/of/device.c ; https://raw.githubusercontent.com/torvalds/linux/v7.3/arch/arm64/mm/context.c ; https://raw.githubusercontent.com/torvalds/linux/v7.3/arch/arm64/kernel/entry-common.c ; https://raw.githubusercontent.com/torvalds/linux/v7.3/arch/arm64/kernel/proton-pack.c |
| OpenSSL | the release strategy page; `LICENSE.txt` on branch `openssl-3.5` | https://openssl-library.org/policies/releasestrat/index.html ; https://raw.githubusercontent.com/openssl/openssl/openssl-3.5/LICENSE.txt |
| Monocypher | `LICENCE.md` and `README.md` on `master` | https://raw.githubusercontent.com/LoupVaillant/Monocypher/master/LICENCE.md ; https://raw.githubusercontent.com/LoupVaillant/Monocypher/master/README.md |
| toybox | `master` `6a0c0ef5`; tag 0.8.15 | https://github.com/landley/toybox ; https://raw.githubusercontent.com/landley/toybox/master/LICENSE ; https://raw.githubusercontent.com/landley/toybox/0.8.15/toys/pending/awk.c |
| wak | `main` `c757c495`; tags 24.8, v24.10 | https://github.com/raygard/wak |
| Linux Test Project: the Open POSIX Test Suite | tag `20260930`; `testcases/open_posix_testsuite/COPYING` | https://github.com/linux-test-project/ltp |
| plan9port | `master` `1f139691`: `LICENSE`, `src/cmd/rc/test.rc`, `src/cmd/rc/checkparse`, with the SHA-256s above | https://github.com/9fans/plan9port |
| Homebrew's formula and cask APIs | `plan9port.json` and `rc.json`, answering 404 | https://formulae.brew.sh/api/formula/plan9port.json ; https://formulae.brew.sh/api/formula/rc.json ; https://formulae.brew.sh/api/cask/plan9port.json |
| rc, Byron Rakitzis's | `trip.rc` on `master`, with the SHA-256 above | https://github.com/rakitzis/rc |
| tcsh | tag `TCSH6_24_16`; `Copyright` | https://github.com/tcsh-org/tcsh |
