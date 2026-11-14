# PCIe: the enumerator, its bridges and the functions it gives

This document is erXos's PCIe design: how the PCIe domain finds the
functions behind each host bridge, where it places their BARs, how a
function's interrupt is routed and by whom, how the domain reaches
configuration space through QEMU `virt`'s ECAM bridge and the Raspberry
Pi 4's BCM2711 bridge alike, what it reports to the device service and
in which record, how a function is given to the domain the manifest
names, and what survives a restart of any party. It refines the PCIe
enumerator, units and gives of [design-system.md](design-system.md#devices),
the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule), the
MSI frames and PCIe bridges of
[design-platforms.md](design-platforms.md#pcie-bridges), the
`ERX_IRQ_MSI` object of [design-kernel.md](design-kernel.md#irq-objects)
and the device records of
[design-stopgap.md](design-stopgap.md#device-records), and says where
each of them changes.

Decisions every reader needs:

* **Configuration space is a projection of one record.** Each function
  has a **target**: its **layout**, fixed by the first report that lists
  it, and its **setting**, the mode and interrupt route its holder last
  asked for. The PCIe domain's only writes to a function are the
  difference between what configuration space reads and the target's
  projection, in one fixed order. The targets live in the system
  domain's domain library; the PCIe domain keeps nothing that outlives
  it.
* **A function masters only for a living holder that asked.** A function
  decodes its BARs from its holder's `open`, masters from its holder's
  `master`, which the driver sends after its own reset of the device, and
  returns to off when the holder ends.
* **MSI where the function offers it, MSI-X where it offers nothing
  else, INTx only on a closed bus.** MSI lies wholly in configuration
  space, so the enumerator programs all of it; MSI-X's table lies in a
  BAR, so the holder's device NIF writes it from the route the give
  made. A **closed bus**, the Raspberry Pi 4's, is one whose platform
  record fixes every position, so its INTx line is a line of its
  position's unit, as any device-tree line is. One message per function.
* **The layout is small on purpose.** Memory BARs go into the host
  bridge's 32-bit window, each rounded up to whole pages, packed
  largest first; bridges are root ports only; I/O BARs, ROMs, the 64-bit
  window, switches, hotplug and extended capabilities have no consumer
  and are left unused.
* **Two bridge drivers behind one access.** The walk, the placement and
  the projection are the same code for every bridge; a bridge driver
  supplies only its bring-up and one configuration access at a position.

## Contents

* [Context](#context): what is matched, what the tree does today, the
  consumers, sources
* [Requirements](#requirements)
* [The construction](#the-construction): targets, the projection and its
  order, what follows, what disappears
* [The PCIe domain](#the-pcie-domain): processes, the bridge seam, ECAM,
  the BCM2711 bridge, the walk, sizing, placement
* [Records](#records): the function, the setting, the bridge
* [Interrupts](#interrupts): the choice, who programs what and when, the
  MSI frame on the stopgap, the closed bus
* [DMA](#dma)
* [Facets](#facets)
* [The catalogue and gives](#the-catalogue-and-gives)
* [Concurrency](#concurrency)
* [Failure handling and restart](#failure-handling-and-restart)
* [Refusals and error results](#refusals-and-error-results)
* [On the stopgap](#on-the-stopgap)
* [Verification](#verification)
* [Changes to other designs](#changes-to-other-designs)
* [Alternatives considered](#alternatives-considered)
* [Open decisions](#open-decisions)
* [References](#references)

## Context

### What is matched

The behaviour matched is FreeBSD's PCI attach, redesigned as a pure core
in Erlang, not its structure. FreeBSD's `releng/15.1`
(`95719d8a895bf8170851e9844d9b4092b1d2b6fe`) is the reference, each file
with its SHA-256 in [References](#references):

* **The walk.** A slot is present when its function 0's vendor reads
  other than `0xffff`; a header type above 2 is skipped; functions 1 to 7
  are read only when function 0's header type has the multifunction bit
  (`pci.c:4242-4287`, `PCI_MAXHDRTYPE`, `PCIM_MFDEV`,
  `pcireg.h:51`, `:122`).
* **BAR sizing.** Decoding is turned off in the command register; all
  ones are written, to both halves of a 64-bit BAR before either is read
  back; the value is restored, then the command register
  (`pci_read_bar`, `pci.c:3154-3228`). The size is the lowest set bit of
  the read-back's base mask (`pci_mapsize`, `:601-616`); a memory BAR
  under 16 bytes or an I/O BAR under 4 is ignored, and a BAR that reads
  back what was written is treated as one firmware disabled
  (`pci_add_map`, `:3357-3430`).
* **MSI.** Address low, address high when the capability is 64-bit,
  data, then the enable bit (`pci_enable_msi_method`, `:2383-2408`);
  INTx is disabled in the command register while a message interrupt is
  in use (`:4924-4932`).
* **MSI-X.** Each table entry is written through the memory of the BAR
  that holds the table, which the driver must have mapped first
  (`pci_write_msix_entry`; `pci_alloc_msix_method`, `:1829-1880`).
  FreeBSD's xHCI attach takes MSI-X, then MSI, then INTx
  (`xhci_pci.c:357-393`).
* **Function-level reset.** Bus mastering off, a wait for pending
  transactions, the initiate bit, 100 ms; no register is saved or
  restored, so the caller programs the function again
  (`pcie_flr`, `pci.c:6741-6797`).
* **Bridges.** A bridge's windows are disabled by a base above its limit
  (`pcib_bridge_init`, `pci_pci.c:1617-1629`).
* **ECAM.** A configuration access outside the bridge's bus range or
  past device 31, function 7 or offset 4095 reads all ones; the offset
  is the ECAM layout (`generic_pcie_read_config`,
  `pci_host_generic.c:297-331`). A host bridge's `ranges` entry is three
  PCI cells, the first carrying the space code at bits 24 and 25, then
  the parent's address and the size (`parse_pci_mem_ranges`,
  `pci_host_generic_fdt.c:66-68`, `:179-230`). FreeBSD's FDT host takes
  buses 0 to 255 without reading `bus-range` (`:136-138`) and routes a
  pin through `interrupt-map` (`:248-276`).
* **The BCM2711.** The root port's configuration is at offset 0 of the
  bridge's registers, an endpoint's behind an index register and a data
  window (`bcm2838_pci.c:266-289`); "probing other slots and funcs on bus
  0 will lock up the memory controller" (`:291-307`); DMA is kept below
  960 MiB because the author saw corruption above it and calls the true
  limit unclear (`:92-106`).
* **The GICv2m frame.** `MSI_TYPER` at `0x008` gives the first line and
  the count, `MSI_SETSPI_NS` at `0x040` is the doorbell, the data is the
  line's interrupt id, and every line of the frame is configured
  edge-triggered (`gic.c:288-310`, `:1330-1365`, `:1418-1428`).
* **virtio over PCI.** The virtio 1.2 specification defines MSI-X
  vectors for configuration and queue interrupts and, without MSI-X, an
  ISR status read (sections 4.1.5.1.2 and 4.1.4.5); it defines no use of
  plain MSI. FreeBSD's virtio-pci driver takes MSI-X, else MSI, else
  INTx (`virtio_pci.c:161-164`, `:388-430`).

The clean-room facts record of the BCM2711's bridge and the VL805,
[research-brcmstb-pcie.md](research-brcmstb-pcie.md), gives the vendor's
bring-up from Linux's driver, the 100 ms between PERST#'s release and the
first configuration request, the CPU abort of a configuration access
with the link down, and the board's tree; this design cites it as "facts
record" by section. No Linux, QEMU or U-Boot source was read for this
design. The PCI specifications were not obtained; every register offset
and bit used here is FreeBSD's `pcireg.h`, and a statement that rests on
the specifications alone is marked unverified.

### What the tree does today

No PCIe domain exists. Property 3 of the manifest says the Raspberry Pi
4 drives no bridge ([design-system.md](design-system.md#the-manifest)),
and its Phase 1 row allows no holder of configuration space and places
no `pci` device on QEMU `virt`
([design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check)).
The manifest already has a `pci` selector: a row names its host bridge
by device-tree path and its bus, device and function
(`abi/manifest.txt`, `erx_mf_device`; the choice at `:452-461`), with
`base`, `size` and `line` zero ([design-abi.md](design-abi.md)). The
domain library's boot view gives such a row no range, no line and no
kind, so it is held and not driven (`liberx/system/dom_boot_view.c`,
`boot_devices`, `:340-418`; a `TODO.md` item). `erx_irq_create` of
`ERX_IRQ_MSI` is `ERX_ENOTSUP` on the stopgap
(`liberx/backend/fiasco/irq.c:188`), and the stopgap's
`erx_mem_create_contiguous` already takes a device address limit
(`liberx/backend/fiasco/service_stubs.c:233`). The device-tree reader
does not take a PCI host bridge's three-cell `dma-ranges`, so a PCIe
function gets no DMA range
([design-device-tree.md](design-device-tree.md#the-reader)), and it reads
no bridge's `ranges`, `bus-range` or `interrupt-map`. The device service,
`erx_devices`, hands on the library's catalogue and keeps no state. The
QEMU harness starts `virt` with `msi=gicv2m` under TCG and attaches no
PCIe function (`tools/lib/erx/qemu.rb`).

### The consumers

Each property below is built because a named consumer needs it.

| Consumer | Where | What it needs |
| --- | --- | --- |
| `qemu-xhci`, PCI `1b36:000d` | QEMU `virt`, on the root bus; the first USB ([design-usb.md](design-usb.md)) | one 64-bit memory BAR placed, one message; it offers MSI and MSI-X |
| the VL805, PCI `1106:3483` | the Pi 4, bus 1, device 0, behind the BCM2711's root port | bring-up of the bridge, a placed BAR in the 32-bit outbound window, its INTx line, DMA below the bridge's limit, its firmware notification |
| virtio-pci block and network | QEMU `virt` in a release build, confined behind the SMMU ([design-platforms.md](design-platforms.md#dma)) | placed BARs, MSI-X, since virtio defines no other per-vector interrupt |
| RP1 | the Pi 5, behind the BCM2712's root port | the BARs the bootloader assigned, kept ([design-platforms.md](design-platforms.md#pcie-bridges)); MSI-X |

No consumer needs I/O BARs, an expansion ROM, the 64-bit window, a
switch or any bridge below a root port, hotplug, ARI, SR-IOV, AER, ASPM
or power-state changes, so none is built. Each fails safe: the function
is reported with the part unplaced or `unsupported`, stays off, and the
next design that needs it adds it.

## Requirements

* **R1. Only the PCIe domain reaches configuration space**, and it holds
  nothing else (CLAUDE.md, Trust placement; property 3). The kernel
  touches none.
* **R2. One walk for every bridge.** The ECAM bridge and the BCM2711's
  index and data access are two drivers of one access; nothing above it
  differs between them.
* **R3. BARs are placed deterministically**, inside the bridge's windows,
  without overlap, in whole pages, so no two functions share a page.
* **R4. MSI is the rule.** A function interrupts by MSI or MSI-X; INTx
  only on a bus whose platform record closes it.
* **R5. A function masters only after its holder's driver has reset it,
  and only while that holder lives.**
* **R6. A restart of the PCIe domain changes no running function**, and
  a reset of a function, its link or its bridge restores its layout and
  its holder's setting.
* **R7. One record of a function**, generated for C and Erlang from one
  source: the PCIe domain writes it, the device service keeps it in the
  domain library, and the library plans the give from it.
* **R8. Untrusted input is parsed once.** Configuration space is parsed
  by binary matching in Erlang with a fuzz target; the report is checked
  once, at the library's intake, against the bridge's windows and every
  other device.
* **R9. Phases.** The same Erlang code runs on the stopgap and on erXos's
  kernel; on the stopgap the backend implements `ERX_IRQ_MSI` over the
  frame's lines, and every guarantee it cannot keep is a recorded
  residual.

## The construction

### Targets

A function's **target** is two records
([Records](#records)):

* its **layout**, `erx_pcie_function`: its place (host bridge, bus,
  device, function), its identity, its interrupt pin, its BARs with
  their sizes and PCI addresses, and its capabilities' offsets. The PCIe
  domain writes it once, at the first walk that finds the function with
  no target, and reports it; from then on it is fixed for the boot.
* its **setting**, `erx_pcie_setting`: a **mode**, `off`, `decoding` or
  `mastering`, and an interrupt **route**, `none`, `msi` with the
  doorbell address and data, `msix`, or `intx`. The give writes the
  route from the objects it made; the holder's requests choose the mode.

Both live in the domain library's device record of the function, in the
system domain, which outlives every other party. The PCIe domain gets
them with `targets` at each of its starts and with every `set` after
([Facets](#facets)).

### The projection and its order

The **projection** of a target is the value of each configuration field
the target decides:

| Mode | Command | MSI | MSI-X | INTx (`intx` route) |
| --- | --- | --- | --- | --- |
| `off` | memory space, bus master clear; interrupt disable set | enable clear | enable clear | disabled |
| `decoding` | memory space set; bus master clear; interrupt disable set | address and data written; enable clear | enable and function mask set | disabled |
| `mastering` | memory space and bus master set; interrupt disable set, except for `intx` | enable set | enable set, function mask clear | interrupt disable clear |

The BARs project to the layout's addresses in every mode. I/O space
enable is always clear. A route of `none` leaves every interrupt
disabled in every mode.

`erx_pcie_project:writes(Read, Target)` is a pure function from the
function's configuration as read (the parsed snapshot) and its target to
the list of writes that make one equal the other. It emits a write only
for a field that differs, in this fixed order:

1. clear bus master;
2. clear MSI enable, or set the MSI-X function mask;
3. clear memory space, when the mode is `off` or a BAR must change;
4. each BAR that differs, low word then high word, only with memory
   space clear;
5. MSI address low, address high, data;
6. MSI-X enable with the function mask set;
7. set memory space, with interrupt disable as the projection says;
8. the live step: MSI enable, MSI-X function mask clear, or interrupt
   disable clear for `intx`;
9. set bus master.

The effect layer performs the writes, then reads the command register
back. Every off-step precedes every on-step, BARs move only while the
function decodes nothing, and bus mastering comes last, so no prefix of
the list leaves a function mastering with a half-written route or
decoding a moving range.

### What follows

* **A restart changes no running function (R6).** A running function
  reads as its projection, so `writes/2` is empty and nothing is
  written. The PCIe domain needs no memory of its own for this: it takes
  the targets from the system domain at its start.
* **Every reset is the same restoration (R6).** A function-level reset, a
  link that fell and came back, and the BCM2711 bridge's reset all leave
  the function's configuration blank; the next projection writes its
  layout and its holder's setting again, at the same addresses, so the
  holder's register windows and DMA stay valid. FreeBSD's caller of
  `pcie_flr` saves and restores registers by hand; here there is nothing
  to save.
* **Mastering follows the holder (R5).** The mode is the holder's
  setting and only the holder's `master` raises it; the holder's end sets
  it to `off`.
* **Bridges hold no state.** A root port's bus numbers and memory window
  are a pure function of the layouts of the functions below it
  ([Placement](#placement)), so they are projected the same way.
* **Firmware's assignment and erXos's are one path.** A function without
  a target is placed; a BAR the firmware left valid is kept by the
  placement, so RP1's inherited BARs and QEMU's blank ones need no mode
  of their own.

### What disappears

| Special case | Why it is not needed |
| --- | --- |
| a save and restore around a function-level reset | the projection writes the target after any reset |
| a restart path that checks whether the bus is already laid out | the targets say; a matching function gets no write |
| re-enabling a function after its driver's reset | the driver's `master` sets the mode; there is no separate "again" |
| a record of the root port's windows | derived from the functions below it |
| a first-boot flag in the PCIe domain | a function is placed exactly when it has no target |
| keeping the bootloader's BARs as a platform mode | the placement keeps any valid BAR |

## The PCIe domain

### Processes

The PCIe domain, `pcie` (node `pcie@erxos`), runs one permanent
application, `erx_pcie` in `erlang/apps/erx_pcie/`, whose one process,
the **enumerator**, owns every bridge the domain holds and serves the
`pcie` facet. Its decisions are pure modules:

| Module | Pure function |
| --- | --- |
| `erx_pcie_cfg` | parses a configuration snapshot, 256 bytes, into the read value of a function or root port, and decodes BAR sizing answers |
| `erx_pcie_walk` | the walk as a state machine: each step takes the last access's answer and returns the next access or the walk's result |
| `erx_pcie_place` | the layout of every function without a target, given the bridge's windows and the targets |
| `erx_pcie_project` | the writes from a read value and a target |
| `erx_pcie_bcm2711_core` | the BCM2711 bridge's bring-up and keep-or-reset decision as a state machine over register reads |

The effects, every configuration access and every bridge register, go
through the bridge driver's `access` and the device NIF. Any crash of the
enumerator ends the application and so the domain, which the domain
service restarts within the row's intensity; the restarted domain asks
for the targets again. There is no supervisor below it: the domain's
restart is the recovery.

### The bridge seam

A **bridge driver** implements the `erx_pcie_bridge` behaviour:

```erlang
-callback start(Facts :: erx_pcie:bridge(), Device :: erx_device:dev()) ->
    {ok, State :: term()} | {error, Reason :: atom()}.
-callback access(Access, State :: term()) -> {Result, State :: term()}
    when Access :: {read, Place, Offset, Width}
                 | {write, Place, Offset, Width, Value},
         Place :: {Bus :: 0..255, Device :: 0..31, Function :: 0..7},
         Offset :: 0..255, Width :: 1 | 2 | 4,
         Result :: {ok, non_neg_integer()} | ok | {error, absent | link_down}.
-callback ready(Function :: erx_pcie:function(), State :: term()) ->
    {ok | not_ready, State :: term()}.
```

`start` brings the bridge up; `access` is one configuration access at a
place; `ready` lets a bridge hold back a function its board must start
first. The walk, sizing, placement and projection call nothing else, so
a third bridge is one more module. The enumerator chooses the module by
the bridge's given record's peripheral, `pci_ecam` or `bcm2711_pcie`,
rows of `include/erx/device_kinds.h` with role `configuration`.

**ECAM** (`erx_pcie_ecam`). `start` does nothing. An access at a place
whose bus lies outside the bridge's bus range, from the tree's
`bus-range` or 0 to 255 without one, answers `{error, absent}`; otherwise
it reads or writes at `(bus - first) << 20 | device << 15 | function << 12
| offset` in the configuration window, as FreeBSD's
`generic_pcie_read_config` does. A read of all ones at offset 0 is
`absent`. `ready` is always `ok`.

**The BCM2711** (`erx_pcie_bcm2711`). Its contract is this design's; its
register values are the facts record's:

* **Access.** The root port's configuration is at offset 0 of the
  bridge's registers; an endpoint's is reached by writing its place in
  ECAM layout to the index register at `0x9000` and accessing the data
  window at `0x8000` (facts record, section 3; `bcm2838_pci.c:266-289`).
  The two operations are one `access`, inside the one enumerator
  process, so no other access comes between them.
* **The link before every access.** An access below the root port reads
  `MISC_PCIE_STATUS` (`0x4068`) and goes on only with `PHYLINKUP` (bit 4)
  and `DL_ACTIVE` (bit 5) set, makes the access, and reads the status
  again, keeping the value only when the link is still up; otherwise it
  answers `{error, link_down}` (facts record, sections 3 and 8, item 10).
  A configuration access with the link down aborts the CPU; how that
  abort is taken on each kernel is in [Failure handling and
  restart](#failure-handling-and-restart).
* **Bring-up**, in the vendor's order (facts record, section 1): bridge
  reset and PERST# asserted, the SerDes powered, `MISC_CTRL`, the
  inbound window from the tree's `dma-ranges` (a power of two at PCI 0,
  4 GiB on the Pi 4's 3 GiB range), `BAR1` and `BAR3` disabled, the
  root port's class set to a PCI-to-PCI bridge, the outbound windows from
  `ranges`, no clock power management and no ASPM, then PERST# released,
  100 ms, and link-up polled every 5 ms for at most 100 ms more. The MSI
  decoder is not set up, since erXos drives the bridge's one endpoint by
  INTx ([The closed bus](#the-closed-bus)). Each step is a state of
  `erx_pcie_bcm2711_core`; each wait is a deadline the effect layer
  keeps. A bridge reset clears the windows and `MISC_CTRL` (facts
  record, section 6), so bring-up always runs whole.
* **Keep or reset.** At each `start`, the boot's first and every
  restart's, the driver reads the link and, with the link up, the
  VL805's firmware register (`0x50`) through the link check, and decides
  by those two facts alone: link up and firmware present (neither 0 nor
  all ones) keeps the bridge, writing only the windows and `MISC_CTRL`
  again with the values the tree gives; any other reading turns the
  bridge off cleanly, if its link is up, and runs bring-up. PERST# is
  asserted nowhere else, so a restart that finds the VL805 running takes
  nothing off its bus.
* **The endpoint's start.** The VL805 loses its firmware at every
  PERST# (facts record, section 6), so the last step of bring-up, after
  the root port's bus numbers are projected and the endpoint's place
  reads present, is the firmware notification through the narrow kernel
  operation the PCIe domain alone holds, then 1 ms, then a read of
  `0x50`. `ready` answers `not_ready` for `1106:3483` while `0x50` reads 0
  or all ones, so that function is reported `not_ready` and never
  catalogued with absent firmware (`bcm2838_xhci.c:113-175`). The
  operation's call, capability and manifest field are the USB design's
  ([design-usb.md](design-usb.md#the-vl805s-firmware)).
* **Its lines.** The bridge's two interrupts, SPIs 147 and 148 (INTIDs
  179 and 180), are lines of its own unit; the PCIe domain holds them
  and leaves them masked.

The handover question, whether the boot firmware leaves the VL805
running, belongs to the board's boot contract and is the USB design's
(the microSD-only boot order); this design's keep rests on it and adds
nothing to it.

### The walk

`erx_pcie_walk` reads; it writes only root ports' bus numbers and the
sizing sequence, and only where [Sizing](#sizing) allows. For each host
bridge, from the bridge's first bus:

1. **The root bus.** On an open bridge, devices 0 to 31; on a closed
   bridge, only device 0. For each device, function 0's vendor; absent
   ends the device. Its header type; a type above 1 is reported
   `unsupported`; the multifunction bit adds functions 1 to 7.
2. **Each function** is read whole: its 256-byte configuration space, a
   **snapshot**, which `erx_pcie_cfg:parse/1` turns into a read value.
3. **A type-1 header on the root bus** is a root port. It takes the next
   bus number in place order as its secondary and subordinate bus, and
   its bus numbers are projected at once, so the bus below it can be
   read. Below it, on an open bridge devices 0 to 31, and on a closed
   bridge only the devices the manifest's rows behind that bridge name,
   are read as in step 1. A type-1 header below a root port is reported
   `unsupported` and nothing below it is read.
4. **The function's place** is its bus, device and function; its
   requester id is `bus << 8 | device << 3 | function`, derived, never
   stored.

No step recurses and the topology has two levels, so the walk's length
is bounded by 32 devices times 8 functions on each of the root bus and
each root port's bus, at most `pcie_functions_max` functions per bridge
reported ([Records](#records)); a function past the bound is logged and
left off.

The parser follows the capability list from offset `0x34` only when the
status register's capability bit is set, takes each pointer with its low
two bits cleared, refuses a pointer below `0x40`, and stops after 48
capabilities, the most 192 bytes hold, so a list that loops ends. It
records the first MSI (`0x05`), MSI-X (`0x11`) and PCI Express (`0x10`)
capability (`pcireg.h:139-151`). Every offset it reports lies inside the
snapshot and every field it reads fits there, by binary matching that
cannot read past the bytes.

### Sizing

A function is sized only when it has no target. Sizing follows
FreeBSD's `pci_read_bar`: memory space off, all ones to the BAR (both
halves of a 64-bit BAR before either is read), read back, the original
value restored, the command register restored. A function without a
target has no holder, so sizing disturbs no driver; a function with a
target is never sized, since its sizes are in its layout. The ROM BAR is
not sized.

### Placement

`erx_pcie_place:layout(Windows, Targets, New)` places the BARs of the
functions without a target and returns each one's layout, or leaves a
BAR unplaced:

* **The window.** The host bridge's first memory window that is not
  prefetchable and whose PCI range lies below 4 GiB, from the tree's
  `ranges`. Every memory BAR goes there, 64-bit ones included, whose high
  word is then zero; prefetchable memory may lie in non-prefetchable
  space. I/O BARs are never placed.
* **Items.** Each memory BAR is an item whose size and alignment are its
  size rounded up to the page size, so no two BARs, and so no two
  functions, share a page: PCIe functions take no part in the unit
  rule's page relation, by construction. A root port's functions are
  laid out first, inside it, from offset 0; the root port is then one
  item whose size is that span rounded up to 1 MiB and whose alignment
  is the larger of 1 MiB and its largest BAR's.
* **Kept BARs.** A BAR of a function without a target that already
  holds an address inside the window, aligned to its rounded size and
  overlapping no target and no other kept BAR, is kept; firmware's
  assignment is kept that way. Every target's BARs are kept.
* **Packing.** The other items are sorted by alignment, largest first,
  then by place and BAR index, and each takes the lowest address from
  the window's base that is aligned to it and overlaps nothing placed.
  With no kept BARs, sorting by alignment packs without a gap, since
  every size is a multiple of its alignment, so the same functions
  always get the same addresses.
* **What does not fit** is unplaced, and the function is reported
  `unplaced`; its driver gets no window for that BAR.

A function with a target is placed nowhere: its layout is its target's.
New functions are placed only by a walk that has no targets at all, the
boot's first, or a later one whose first found nothing; a function that
appears in a later walk beside targets is reported `unplaced` and waits
for the next boot, so a later walk never has to move a root port's
window around running functions.

**A root port's projection**: primary bus, secondary and subordinate as
the walk numbered them; its memory base and limit, 1 MiB granular, to
its span; its prefetchable and I/O windows disabled, base above limit
(`pci_pci.c:1617-1629`); memory space and bus master set, which let it
forward its functions' accesses and DMA and make it master nothing
itself; its own interrupt disable set.

## Records

The records are layouts in a new ABI file, `abi/formats/pcie.txt`, as
`wire_le` layouts with the configuration-space constants the parser and
the projection use (offsets and bits from FreeBSD's `pcireg.h`) and the
limits below. The generator emits their C reader and struct and their
Erlang codec, as it does for the manifest's records
([design-abi.md](design-abi.md)), so the PCIe domain, the device service
and the domain library share one definition.

**`erx_pcie_function`**, the layout, which the PCIe domain reports:

| Field | Width | Meaning |
| --- | --- | --- |
| `bridge` | u32 | the manifest device row of its host bridge |
| `bus`, `device`, `function` | u8 each | its place; the requester id follows |
| `state` | u8 | `ready`, `not_ready` (its bridge's `ready` held it back), `unplaced` (a memory BAR did not fit, or it appeared beside targets), `unsupported` (a header type or level the walk does not take) |
| `vendor`, `device_id` | u16 each | its identity |
| `class` | u32 | base class, subclass and programming interface, bits 23 to 0 |
| `revision`, `header` | u8 each | revision; header type without the multifunction bit |
| `subsystem_vendor`, `subsystem` | u16 each | |
| `pin` | u8 | 0 for none, 1 to 4 for INTA to INTD |
| `bars` | 6 times `erx_pcie_bar` | in BAR register order |
| `msi` | u8 offset, u8 flags (64-bit, per-vector mask), u8 vectors capable as a power of two | offset 0 for none |
| `msix` | u8 offset, u16 table size, u8 table BAR, u32 table offset, u8 PBA BAR, u32 PBA offset | offset 0 for none |
| `express` | u8 offset, u8 device type, u8 flags (function-level reset) | offset 0 for none |

**`erx_pcie_bar`**: `kind` u8 (absent, memory, I/O; the upper half of a
64-bit BAR is absent), `flags` u8 (64-bit, prefetchable, placed),
`size_log2` u8, and `address` u64, the PCI address, 0 when not placed.

**`erx_pcie_setting`**: `mode` u8 (`off`, `decoding`, `mastering`),
`route` u8 (`none`, `msi`, `msix`, `intx`), `address` u64 and `data` u32,
the doorbell and value of the function's one message, zero for the other
routes.

**`erx_pcie_bridge`**, what the device service hands the PCIe domain of
each bridge it holds: `index` u32, its manifest device row; `bus_first`
and `bus_last` u8; `flags` u8 (closed); `windows`, at most
`pcie_windows_max` (4) of `pci` u64, `cpu` u64, `size` u64 and `flags`
(64-bit, prefetchable, I/O), from the tree's `ranges`; and, for a closed
bridge, `places`, the bus and device of each manifest row behind it, at
most `pcie_closed_max` (4).

Limits: `pcie_bridges_max` 2 per domain, `pcie_functions_max` 32 per
bridge. The generator checks each layout's offsets and size; the C reader
refuses a record whose enums are out of their sets, whose BAR is placed
but not a whole number of pages, or whose capability offsets lie outside
256 bytes, so the library's intake ([The catalogue and
gives](#the-catalogue-and-gives)) starts from a well-formed record.

**The catalogue entry** of a PCIe function is its manifest row, its
layout once reported, its setting, and `confirmed`, whether the latest
report listed it with that identity and layout. It lives in the domain
library's `erx_dom_device_t`, which gains the two records and the flag;
`erx_domain_lib:devices/0` shows them, with `/dev`'s `status` naming the
place, the identity, the BARs, the mode and the route.

## Interrupts

### The choice

For a function with a route, the give chooses by what the layout
reports and what the manifest row says:

| The row and the function | Route |
| --- | --- |
| the row names a line (a closed bus) | `intx`, the row's line |
| otherwise, the function has MSI | `msi`, one message |
| otherwise, the function has MSI-X | `msix`, table entry 0 |
| otherwise | `none`: no interrupt, and its driver polls, the rule of [design-system.md](design-system.md#devices) |

MSI comes before MSI-X because MSI lies wholly in configuration space:
the enumerator writes the address, the data and the enable bit, and no
register in the holder's window carries an interrupt address. MSI-X's
table lies in a BAR, which is the holder's window, so the holder's device
NIF writes table entry 0 from the doorbell and data its given record
carries, as it writes every address-bearing register itself and never
from Erlang ([design-system.md](design-system.md#drivers)). That adds
nothing to the MSI frame's residual: the frame does not identify its
writer, so a function that can write the frame, by its MSI or by DMA to
the doorbell its window maps, can already raise any of its lines
([design-kernel.md](design-kernel.md#dma-and-the-iommu)).

**One message per function.** Every consumer works with one: xHCI with
one interrupter, virtio-pci with every event on vector 0, which its
specification allows (section 4.1.5.1.2), and the VL805 by INTx. MSI's
multiple-message enable stays 0 and MSI-X entries past 0 stay masked. A
function whose MSI capability takes only 32-bit addresses needs a
doorbell below 4 GiB; the enumerator refuses a `set` whose route it
cannot write with `{error, route}`.

### Who programs what, and when

| Step | Who | What |
| --- | --- | --- |
| the give, in the holder's creation | the domain library | the function's register windows over its placed BARs, its IRQ object (`ERX_IRQ_MSI`, or `ERX_IRQ_LINE` for the closed bus's line), its DMA window or contiguous memory, its given record; it writes the setting's route from the IRQ object's doorbell and data; the mode stays `off` |
| the driver's start | the driver, by `pci:open` | the device service sets `decoding`; the enumerator writes the BARs if they differ, the MSI address and data, or MSI-X's enable and function mask, then memory space |
| the driver's reset of its device | the driver, by its registers | xHCI's `HCRST`, virtio's status 0; nothing of PCIe; for MSI-X the NIF writes the table now |
| the driver ready | the driver, by `pci:master` | `mastering`: MSI enable, or MSI-X's mask cleared, or INTx's disable cleared; then bus master |
| a reset the registers cannot do | the driver, by `pci:reset` | `off`; a function-level reset when the function offers one; then `decoding` again; the driver resets its device and sends `master` |
| the holder's end | the device service | `off` |

So an xHCI controller reset is not a PCIe request: the function stays
`mastering` through it, and the controller's own halt stops its DMA. A
driver process that its supervisor restarts sends `open` again, which
clears bus master, so the new driver resets a device that masters
nothing.

### The MSI frame on the stopgap

On erXos's kernel the kernel drives the frame and `ERX_IRQ_MSI` returns
the doorbell and value ([design-kernel.md](design-kernel.md#irq-objects)).
On the stopgap the backend implements the same call in the root, over
the frame's lines, which Fiasco binds as wired lines:

* **The range.** QEMU `virt`'s platform record names the frame,
  `msi_frame`: its base, the interrupt id of its first line and the
  count, which the packer copies into the manifest's platform part. The
  root may not read the frame's `MSI_TYPER`, since only `erx_device`
  reads device registers, so the record stands in for it; the QEMU suite
  checks the record by raising the first and the last line. Which range
  QEMU's frame serves is unverified (probe 4 of the USB design).
* **The call.** `erx_irq_create(budget, resource, ERX_IRQ_MSI, 0)`
  ignores the resource, as every stopgap device call does, takes the
  lowest free line of the range, sets it edge-triggered through Fiasco's
  `l4_icu_set_mode` with `L4_IRQ_F_POS_EDGE`
  (`fiasco/l4re-core/l4sys/include/icu.h:82`, `:266`), as FreeBSD sets
  every frame line (`gic.c:288-310`), binds it as `ERX_IRQ_LINE` binds a
  line, and answers the doorbell, the frame's base plus `0x40`, and the
  data, the line's interrupt id (`gic.c:1418-1428`). Whether the fork's
  GIC honours the mode for these lines is probe 4's second half.
* **The address the function writes.** The doorbell answered is the
  frame's CPU address, which is the address the function writes only
  where its host bridge maps the frame one to one. The give checks the
  doorbell against the function's DMA range and refuses a give where the
  bus and CPU addresses differ, so no route aims a function at the wrong
  address.
* **Exhaustion.** When every line of the range has an object, the call
  fails with `ERX_ELIMIT`, and the give with it. The manifest check
  proves that a manifest's `pci` rows without a line number at most the
  frame's count, and a holder's end deletes its object, so a manifest the
  check passed never meets it; the root's 256 IRQ slots are the existing
  residual.
* **Raising one without a device.** The `pcie` suite's test task maps the
  frame's page, as the `native_irq` suite maps a device page, binds an
  object the root made, and writes the object's data to the doorbell,
  which raises the line as a function's MSI does.

### The closed bus

INTx is refused everywhere else because a bridge's INTx line is shared by
every function behind it, and which functions those are is known only
after enumeration, so the line cannot be placed in one unit when the
manifest is written
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)). A
**closed** bridge removes that reason: its platform record marks it
closed, its root bus holds one root port at device 0, function 0, and
the walk reads below it only the devices the manifest's rows name. Every
function that can raise a line its tree routes is then a row the
manifest already places, so the line joins the unit rule's line relation
as a device-tree line does.

* **The row.** A `pci` row behind a closed bridge may name a line, the
  interrupt id its bridge's `interrupt-map` routes for the function's
  pin; on the Pi 4, INTA to INTD go to SPIs 143 to 146 under a mask that
  keeps only the pin (facts record, section 0), so the VL805's row names
  INTID 175 (SPI 143). A `pci` row elsewhere names none. The boot view
  puts such a row's line in the line relation, so a second row naming it
  is in the same unit or the view is refused.
* **At boot.** The root reads the bridge's `interrupt-map` for each pin
  into the bridge's catalogue entry. The give makes the line's IRQ object
  as for any device-tree line, after checking that the map routes the
  reported pin to the row's line; a mismatch gives the function no
  interrupt, with a log line naming both, and its driver polls.
* **The unit.** The VL805's unit is its row, whose registers come from the
  walk and whose line from the platform: no unit is composed of a
  device-tree row and an enumerated function, so the library needs no
  second kind of unit.

The Pi 4 is the only platform whose record closes a bridge. Its MSI
decoder shares a register page with the windows the PCIe domain programs,
so another domain could not clear a vector without a new mechanism, and
the closed bus makes INTx safe without one.

## DMA

A function on one of the machine's fixed buses that its bridge's
`iommu-map` covers is confined: the give creates its DMA window by its
requester id, and its bus mastering reaches only that window, whatever
the enumerator writes ([design-kernel.md](design-kernel.md#resources-dma-windows-and-consoles)).
Every other function is unconfined, its domain in the trusted base, and
its give makes its contiguous memory from the manifest row's
`dma_memory`.

An unconfined function's **DMA range** is its host bridge's: the reader
walks from the bridge's own `dma-ranges`, whose child addresses take the
three PCI cells that `ranges` takes, the first carrying the space code
(`pci_host_generic_fdt.c:66-68`, `:179-230`), an I/O entry skipped. The
range is then cut at the row's **`dma_limit`**, a new field of the
manifest's device row, 0 for none, which the packer copies from the
bridge's unit in the platform record into each `pci` row behind it. The
fact is the bridge's: FreeBSD keeps the bridge's DMA below `0x3c000000`
in the bridge's own driver (`bcm2838_pci.c:92-106`), where the tree
allows 3 GiB (facts record, section 2), and its VL805 driver calls even
the 32-bit DMA "a limitation of the PCI-e controller, not the VL805"
(`bcm2838_xhci.c:191`). The Pi 4's
platform record sets `0x3c000000` until the USB design's probe B5 shows
the bridge's true limit. The give passes the cut range's end as the
limit of `erx_mem_create_contiguous`, which the stopgap's root already
takes, so the function's memory lies below the limit by construction and
no driver has to remember it.

## Facets

Three interfaces, each a file of `abi/services/` whose first cited
section is this document's:

| Interface | Served by | Granted to | Operations |
| --- | --- | --- | --- |
| `pci_bus` | the system domain's device service | the PCIe domain alone | `targets() -> {ok, Bridges, Targets}`; `report(Functions) -> ok` |
| `pci` | the system domain's device service | each configured domain that holds a `pci` device, its scope the devices it holds, as `device` parameters | `open(Place) -> ok`; `master(Place) -> ok`; `reset(Place) -> {ok, flr \| none}` |
| `pcie` | the PCIe domain | the system domain alone | `set(Place, Setting) -> ok`; `reset(Place) -> {ok, flr \| none}` |

Each answer of an error is `{error, Reason}`
([Refusals and error results](#refusals-and-error-results)). `Place` is
`{BridgePath, Bus, Device, Function}`, the function's place as its
manifest row and its given record name it; the device service matches
it against the rows the facet's grantee holds and never trusts it
otherwise.

The directions follow from when each party can hold its facet. A facet
of a system-domain service reaches a grantee with its ready answer, before
`-run` starts its programs; a facet a configured domain serves is
installed whenever both parties are up
([design-system.md](design-system.md#facets-a-configured-domain-serves)).
So the PCIe domain and every holder call the system domain, and each has
its facet when its enumerator or driver starts; the system domain calls
`pcie` only on a holder's request, looks up `erx:cap(pcie)` then, and
answers the holder `{error, unavailable}` while no PCIe domain serves
one. The PCIe domain needs no notice of anything: at each of its starts
it asks for the targets and reports.

**The PCIe domain's start.** The enumerator calls `targets`, gets each
bridge's facts and every target, starts each bridge, walks, places,
projects every function to its target or, without one, to `off`, and
calls `report` with every function it found. Then it serves `pcie`.

**The manifest.** The check proves property 3 as amended below, and
that only the PCIe domain holds `pci_bus`, only the system domain holds
`pcie`, and a domain holds a `pci` facet exactly when it holds a `pci`
device, its scope those devices, as property 8 proves the driver-control
facet's grantee from the interface.

## The catalogue and gives

**Intake.** On `report`, the device service hands each function to the
domain library, `erx_domain_lib:pci_report(Index, Function)`, after
finding the manifest row by place and checking that its identity is the
row's compatible string, spelled `pci` and the vendor and device id in
four lowercase hexadecimal digits each, `pci1b36,000d`, erXos's own
spelling since no tree carries it. A function no row names is logged as
unlisted and stays off. The library's intake, `erx_dom_pci_report`, is
the boundary check of a report: every placed BAR is whole pages inside
its bridge's window and overlaps no other entry's BARs or register
ranges, the place is the row's, and the MSI-X table lies inside a placed
BAR. An entry with no layout takes the record of a function whose state
is `ready`, and no other; an entry with one is
confirmed when the record equals it and unconfirmed otherwise; an entry
the report does not list is unconfirmed. A refused record leaves the
entry as it was, with a log line naming the field.

**The give** of a `pci` device, `erx_dom_plan_unit_give`: an entry with
no layout, or not confirmed, gives nothing, as a device the machine
lacks, and its driver finds no record. Otherwise one register window per
placed memory BAR, its CPU range the BAR's PCI range translated by the
bridge's window; the IRQ object of [The choice](#the-choice); the DMA
window, or the contiguous memory below the DMA range; and the given
record, which names the function's place, each BAR's window, and for an
MSI-X route the doorbell, data and table location. The setting's route is
written; the mode stays `off`.

**The hold at boot.** The domain service starts a configured row whose
units hold a `pci` device only once the device service has the boot's
first report, holding its start as it holds a start for a principal's
ending domain; rows without one start in boot order meanwhile. The device
service releases the hold at the first report, or when the PCIe row ends
or fails to report ready within its boot timeout, or 30 s after its ready
answer, whichever is first; a row started after a failed hold gets
nothing of its `pci` devices. The check's boot order puts the PCIe domain
before every row holding a `pci` device.

**A holder's end.** The device service monitors the holder's domain pid
from its first `open`; at its end it sets the setting's mode `off` and
calls `pcie:set`. With no PCIe domain up, the library's setting says
`off`, and the next `targets` projects it.

## Concurrency

The enumerator is one process: every configuration access, a walk, a
`set` and a `reset` run one at a time in it, so the BCM2711's index and
data are never interleaved and no two projections of a function race. A
`set` or `reset` that arrives during the walk waits in the enumerator's
queue until the walk has reported. The device service's PCIe process is
one process that writes the library's settings and calls `pcie`, so the
setting the library holds and the one last sent are written in one
order. Its call to `pcie` has a deadline of 2 s, past the longest
`reset` (100 ms for pending transactions, 100 ms after the reset, 10 ms
more when transactions stayed pending); a timeout answers the holder
`{error, unavailable}` and leaves the library's setting as asked, which
the next `targets` projects. The walk's own deadlines are the bridge's
bring-up waits and one per access.

## Failure handling and restart

| Failure | Detected by | What happens |
| --- | --- | --- |
| the enumerator crashes | its application ends | the PCIe domain ends and is restarted; its start asks for the targets, projects each, and writes nothing to a running function |
| the PCIe domain ends past its intensity | the domain service | it stays down; functions keep their state; holders' `open`, `master` and `reset` answer `{error, unavailable}` |
| a configuration access with the link down, on erXos's kernel | a synchronous abort, a fault of the PCIe domain's thread, or an SError presumed the running thread's ([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)) | the PCIe domain ends and is restarted; the BCM2711's start finds the link down and resets the bridge; the projection restores every function |
| the same, on the stopgap | Fiasco's SError handler counts and returns (`fiasco/kernel/src/kern/arm/thread-jdb.cpp:96-106`) | the second link read discards the value; the access answers `{error, link_down}`; the function is reported missing and its entry unconfirmed |
| the link falls under a running function | its driver's accesses abort or time out | as for any device that stops answering its bus ([design-system.md](design-system.md#devices)); the next PCIe start restores it |
| a function reads absent or changed at a walk | the walk | it is not listed or listed with another identity; its entry is unconfirmed; its holder's requests answer `{error, gone}` |
| the VL805's firmware stays absent after the notification | `ready` | it is reported `not_ready` and stays out of the catalogue until a walk finds it ready |
| a holder ends while the PCIe domain is down | the device service's monitor | the library's setting says `off`; the next start projects it |
| the device service's PCIe process crashes | its supervisor | it restarts, reads every setting and holder from the library and monitors the holders again; a function whose holder has ended is set `off` |
| a function's report is refused at intake | the library | its entry stays as it was; a log line names the field |

A **restart keeps** nothing in the PCIe domain and everything in the
library: the layouts, the settings and the confirmed flags. It **re-reads**
every function's snapshot and the bridges' link state.

A wedged function that no function-level reset recovers stays unusable
until a reset of its link or the next boot; on the Pi 4 only a PERST#
cycle resets the VL805 further, and the bridge keeps a link whose
firmware reads present, so its holder's restarts end at its bound.

## Refusals and error results

| Where | Result | When |
| --- | --- | --- |
| `pci:open`, `master`, `reset` | `{error, badarg}` | a malformed place or request |
| | `{error, not_held}` | a place the grantee's scope does not hold |
| | `{error, gone}` | the entry is not confirmed |
| | `{error, unavailable}` | no PCIe domain serves `pcie`, or its call timed out |
| | `{error, order}` | `master` before `open` in the holder's incarnation |
| `pcie:set`, `reset` | `{error, gone}` | the function reads absent or changed, or the link is down |
| | `{error, route}` | the route does not fit the function: no such capability, or a doorbell beyond its MSI address width |
| | `{error, unknown}` | a place the enumerator has no target for |
| `pci_bus:report` | `ok` | always, after intake; refusals are per function, in the log and in `/dev` |
| `erx_dom_pci_report` | `ERX_EINVAL` | a BAR outside its window, not whole pages, or overlapping another device; a place not the row's; an MSI-X table outside a placed BAR |
| `erx_irq_create` of `ERX_IRQ_MSI` | `ERX_ELIMIT` | no free line of the frame, or the function past `ERX_MSI_MAX` |
| | `ERX_ENOMEM` | the stopgap root's IRQ slots are full |
| the give | refused, the creation with it | a doorbell the function's DMA range does not map one to one |
| the manifest check | the build fails, naming the property | a second holder of a bridge's unit; a `pcie` domain holding another unit; a `pci` row with a line behind an open bridge; a closed bus's line given apart from its row; more line-less `pci` rows than the frame's lines; a `pci_bus`, `pcie` or `pci` facet granted against the rule above |

## On the stopgap

The PCIe domain, the enumerator, both bridge drivers, the device
service's PCIe process and the three facets are the same code on the
stopgap and on erXos's kernel. The stopgap adds `ERX_IRQ_MSI` over the
frame's lines ([The MSI frame on the stopgap](#the-msi-frame-on-the-stopgap))
and the give of a `pci` device in the root, as for any device another
domain holds ([design-stopgap.md](design-stopgap.md#device-records)): its
BAR windows with `erx_mem_create_physical`, its IRQ object, and its
contiguous memory below its limit. The VL805's notification runs in the
root task. Its residuals:

* **No confinement.** The harness starts QEMU `virt` with no IOMMU on the
  stopgap and the Pi 4 has none, so every PCIe function is unconfined
  and its holder, with the PCIe domain, is in the trusted base.
* **No isolation between tasks.** The PCIe domain and the holders are
  apart by convention ([design-stopgap.md](design-stopgap.md#what-phase-1-code-must-not-assume)).
* **Bus errors are ignored.** Fiasco's SError handler returns, so an
  access over a fallen link completes with whatever the bus returned;
  the second link read keeps it from being used. A synchronous external
  abort takes Fiasco's user fault path, unverified for this kind.
* **The frame's range is a record**, not `MSI_TYPER`, and does not
  identify the writer.

## Verification

Each test below has a seeded failure that proves the code under test
ran; tests run where they are cheap, and the QEMU suite once per landing
that touches it.

### Host tests of the pure cores

| Test | Passing case | Seeded failure |
| --- | --- | --- |
| `erx_pcie_cfg` | snapshots of a type-0 and a type-1 header, MSI, MSI-X and Express capabilities, 32- and 64-bit BARs, decode to the expected values; a capability list that loops stops after 48 | the step bound removed: the looping fixture does not end within the test's deadline |
| `erx_pcie_place` | for generated sets of BARs: every placed BAR inside the window, page-aligned, no overlap; the same set in any order gives the same addresses; kept BARs stay | items sorted smallest first: the property test finds a misaligned or overlapping placement |
| `erx_pcie_project` | exhaustive over modes, routes and each field equal or differing: the writes make the read equal the target; equal gives no write; every off-step precedes every on-step; BARs only with memory space clear; bus master last | bus master set before memory space: the order check fails |
| `erx_pcie_walk` | against a model configuration space, an open root bus with multifunction devices and a root port, and a closed bridge with one endpoint: every function found, root ports numbered in place order | the closed bus read at device 1: the model records an access to a place no row names, and the test fails |
| `erx_pcie_bcm2711_core` | the keep-or-reset table, exhaustive over link and firmware readings; bring-up's order and each deadline | PERST# asserted on the keep path: the test of a kept link sees a PERST# write |
| the device service's PCIe process | `open`, `master`, `reset` for held and unheld places; a holder's end sets `off`; `unavailable` with no `pcie` | the monitor dropped: after the holder's end the stand-in `pcie` sees no `set` |
| `erx_dom_pci_report` (C, host) | a valid record is taken; a BAR outside the window, unaligned, overlapping another entry, an MSI-X table outside its BAR, each `ERX_EINVAL` | the overlap check removed: the overlapping fixture is admitted and the test fails |
| the stopgap's MSI line allocator (C, host) | lines from the range's first to its last, then `ERX_ELIMIT`; a freed line is taken again | the range's end off by one: the test's last allocation lies outside the range |

### Fuzz targets

Landing with their parsers, built for the host, run by `make check-fuzz`:
`erx_pcie_cfg:parse/1` over snapshots and their mutations, which must
never crash and whose offsets must lie inside the snapshot; and the
generated C reader of `erx_pcie_function`, over records and their
mutations, which the library's intake runs on what another domain sent.

### Build checks

The manifest check's seeded manifests, one per refusal of [Refusals and
error results](#refusals-and-error-results); the facet table's three
rows, each citing this document; the kinds table's rows for the two
bridges, with a seeded row whose peripheral has no SVD file.

### The `pcie` QEMU suite

A suite of its own, landing with the PCIe domain and before any USB
code, on QEMU `virt` with `qemu-xhci` attached, 1-CPU cells on HVF while
developing:

| Case | Checks | Seeded failure |
| --- | --- | --- |
| walk and report | the report's places, identities and BAR addresses equal QMP's `query-pci` answer, which the harness's QMP reader parses (its fields are to be confirmed against the pinned QEMU) | placement's alignment off by a page: QMP's region differs and the case fails |
| a test holder | a test domain holding `qemu-xhci` sends `open`, reads the capability length register through its window, sends `master`; the PCIe domain's inspection record shows the command register and MSI state | `open` not setting memory space: the register read returns all ones |
| restart | the PCIe domain killed while the test holder masters: after its restart the enumerator's count of writes to that function is zero and the holder's next register read succeeds | the projection writing every field: the count is nonzero |
| holder end | the test holder halts: the function's command register reads memory space and bus master clear | the device service's monitor dropped: the command still reads set |
| MSI frame | on the stopgap, a test task writes a made object's data to its doorbell and the object is delivered; the first and last line of the record's range both deliver | the backend's data off by one: the bound object sees no delivery within the deadline |
| hold | the test holder's row starts only after the report | the hold removed: the test holder's give finds no layout and its record is absent |

### Board probes

On the Pi 4, by hand: the root's device-tree line for the bridge prints
its `ranges`, `dma-ranges` and `interrupt-map`; the enumerator's dump of
the VL805's snapshot gives its header type, BARs and pin; the
keep-or-reset decision is logged at each start; the USB design's probes
B1, B2, B5 and B8 settle the firmware, the line, the DMA limit and the
abort's kind.

## Changes to other designs

Made in their owning documents with this design:

| Document | Change |
| --- | --- |
| [design.md](design.md) | the index row; SD1's summary: MSI except on a closed bus |
| [design-shared-devices.md](design-shared-devices.md) | the closed bus's exception to "MSI only" in the decisions, the unit rule's line relation, the PCIe INTx paragraph and SD1 |
| [design-system.md](design-system.md) | property 3: the Pi 4 drives its bridge, and a `pci` row's line only behind a closed bridge; the PCIe paragraph: the BCM2711's access, the layout and setting, the closed bus, the give enabling nothing, the holder's requests through `pci`, the restart as a projection; Resets: bus mastering and a PCIe function's reset through `pci`; Security: the enumerator's crash ends its domain |
| [design-platforms.md](design-platforms.md) | the Pi 4's PCIe bridge driven by the PCIe domain as a closed bus, in the platform table, the placement table, the Pi 4's section and PCIe bridges; the VL805 held by no domain, in the USB row, the bus masters row and the unconfined row; a PCIe function's DMA range cut at its `dma_limit`; the MSI frame's range on the stopgap |
| [design-stopgap.md](design-stopgap.md) | property 3's Phase 1 row: one `pcie` domain on QEMU `virt` and the Pi 4 |
| [design-abi.md](design-abi.md) | a `pci` row's `line` behind a closed bridge |

Required of other documents, each their own revision:

| Document | Change |
| --- | --- |
| [design-device-tree.md](design-device-tree.md) | the reader takes a PCI host bridge's three-cell `ranges` and `dma-ranges`, its `bus-range` and its `interrupt-map` by pin, with fuzz seeds; the DMA facts of a `pci` row cut at its `dma_limit` |
| `abi/manifest.txt`, [design-abi.md](design-abi.md) | `dma_limit` in `erx_mf_device`; the closed flag on a bridge's row; the manifest's `msi_frame` platform part on QEMU `virt`; the `dt` case's `base`, `size` and `line` made inactive for selector 2 except `line` behind a closed bridge (the `TODO.md` item) |
| [design-stopgap.md](design-stopgap.md) | `ERX_IRQ_MSI` over the frame's lines; the given record of a PCIe function (its place, a window per BAR, an MSI-X route's doorbell and table); the give in the root |
| [design-runtime.md](design-runtime.md#the-device-nif) | the NIF writes MSI-X table entry 0 from its record, and opens a record with several BAR windows |
| [design-hardware-generation.md](design-hardware-generation.md) | SVD files for the ECAM window and the BCM2711 bridge whose configuration-space views take 8-, 16- and 32-bit accesses at a computed offset, bounded by the window |
| [design-system.md](design-system.md) | the device service's PCIe process and its monitors; the hold of `pci` rows at boot; `/dev`'s PCIe fields |
| `include/erx/device_kinds.h` | rows `pci_ecam` (`pci-host-ecam-generic`) and `bcm2711_pcie` (`brcm,bcm2711-pcie`), role `configuration` |
| [design-usb.md](design-usb.md) | its sections on the PCIe domain, the BCM2711 bridge, the Pi 4's interrupt and the Phase 1 part cite this design for what they share: the give programs no MSI and enables nothing; `open` and `master` do |

## Alternatives considered

* **The device service programs the function at the give.** Enabling
  memory space, bus mastering and the MSI as the give finishes puts bus
  mastering before the driver has reset a device a previous holder left
  running, so a confined function could write stale addresses into its
  new window's fresh pages. Holder-driven modes put mastering after the
  reset by construction.
* **MSI-X first, as FreeBSD does.** It needs the table's page in the
  PCIe domain, against R1 and the unit rule, or a write in the holder;
  MSI first keeps the whole route in configuration space wherever the
  function allows it.
* **The PCIe domain keeps its layout itself.** A restart then needs the
  sizes of running functions, which only sizing gives and sizing
  disturbs; keeping the targets in the library makes the restart a
  projection.
* **Re-enumerate from scratch at every start.** Deterministic placement
  would reproduce the addresses, but sizing a running function turns its
  decoding off under its driver.
* **A 64-bit window and prefetchable placement.** No consumer's BAR needs
  them; a BAR that does not fit is refused, not misplaced.
* **A general walk over switches.** No platform has one; a second bridge
  level is reported `unsupported`.
* **INTx with a line owner across domains.** It needs the kernel to fan
  one line out to several untrusting holders, the mechanism the unit rule
  exists to avoid; the closed bus removes the need where INTx is used.
* **The BCM2711's MSI decoder for the VL805.** Its register page is the
  bridge's, which the PCIe domain holds; another domain could not clear a
  vector without a new mechanism.
* **One facet in each direction between the device service and the PCIe
  domain.** The device service would have to learn when each new PCIe
  incarnation's facet is installed; with the PCIe domain asking for its
  targets on `pci_bus`, each start begins the conversation itself.
* **The DMA limit on the function's kind.** FreeBSD names it the
  bridge's, so the platform record states it once, at the bridge.

## Open decisions

* **More than one message per function.** RP1 on the Pi 5 and
  multi-queue virtio-pci network want several. Recommendation: one until
  the first of them lands; the setting then carries a count and the give
  makes that many objects, up to `ERX_MSI_MAX`.
* **The 64-bit window.** Recommendation: unused until a function's BAR
  does not fit the 32-bit window, then placed there only for
  prefetchable BARs on the root bus.
* **MSI-X written by the holder's NIF.** It adds nothing to the frame's
  residual, but it is a route the PCIe domain does not write.
  Recommendation: accept; the alternative, giving an MSI-X-only function
  no interrupt, makes every virtio-pci driver poll.
* **The hold at boot versus a barrier.** Recommendation: hold only the
  rows that hold a `pci` device, so the others boot in parallel.
* **A `pcie` QEMU suite apart from `usb`.** Recommendation: yes, so the
  PCIe domain lands and is tested before any USB code runs.

## References

FreeBSD `releng/15.1` at `95719d8a895bf8170851e9844d9b4092b1d2b6fe`
(the tip of the branch and of `release/15.1.0-p6`), fetched over HTTPS
from the project's GitHub mirror, read as data:

| File | SHA-256 |
| --- | --- |
| `sys/dev/pci/pci.c` | `f9cb7ceb56747315984fa5485ba503eeda638a9bde2c4253f20d197a8bda022a` |
| `sys/dev/pci/pci_pci.c` | `376937a7ac18e6a14807fb99a27978342a7b98cf973dc651d57057fc0d9147d4` |
| `sys/dev/pci/pcireg.h` | `e807eb05747d6c47a5722ff7b2be385d09053b1d2a3acfc16af4a5ab08bd6507` |
| `sys/dev/pci/pci_host_generic.c` | `d89ad72f72c3ef3c218256468ef4035354e9b72185a8b50eeb22390a2fbd6034` |
| `sys/dev/pci/pci_host_generic_fdt.c` | `054d4c979103b417cbe5d427aa45fb05ffd62757e2ca280fe18bc9fbe2333994` |
| `sys/arm/broadcom/bcm2835/bcm2838_pci.c` | `10a983496e957f3cf01039f5076e189a817bdfc5da53e582f42dad525d1ac6a9` |
| `sys/arm/broadcom/bcm2835/bcm2838_xhci.c` | `ad6b745a07c7aa2d227f22f9839ce26fe2162df7cb2c4a41b815e5ba66d24a60` |
| `sys/dev/usb/controller/xhci_pci.c` | `d13585891d30fd9171c4c75929a2aa3e48a1bcf7dad6f791871247fbc02a779a` |
| `sys/dev/virtio/pci/virtio_pci.c` | `551322dffc0141532b963006063164db88d343128419a1413b4e0310eadb7679` |
| `sys/arm/arm/gic.c` | `e32059f306ff4ec09f83c1c814936f2ee2fa186777e1a7e2f18aaa9904814a33` |
| `sys/arm/arm/gic_fdt.c` | `c927b76c4f03c163681a6411f89215c92b7a341c7a817318e9eb6492c0951ace` |

The virtio specification, Virtual I/O Device (VIRTIO) Version 1.2,
Committee Specification Draft 01, OASIS,
`https://docs.oasis-open.org/virtio/virtio/v1.2/csd01/virtio-v1.2-csd01.html`,
SHA-256 `e18d68ee81b03bb9d8fb493356704fa77e3a9eac1c10f79111940cbd482f7bc1`.

The BCM2711 facts record,
[research-brcmstb-pcie.md](research-brcmstb-pcie.md), a clean-room
point-in-time record of Linux's and FreeBSD's BCM2711 bridge and VL805
drivers and the Pi 4's device trees, written by a separate agent.

erXos's own: [design-system.md](design-system.md#devices),
[design-shared-devices.md](design-shared-devices.md),
[design-platforms.md](design-platforms.md),
[design-kernel.md](design-kernel.md),
[design-device-tree.md](design-device-tree.md),
[design-stopgap.md](design-stopgap.md),
[design-domains.md](design-domains.md#facets), Fiasco's ICU interface
(`fiasco/l4re-core/l4sys/include/icu.h`).
