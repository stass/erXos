# PCIe: the enumerator, its bridges and the functions it gives

This document is erXos's PCIe design: how the PCIe domain finds the
functions behind each host bridge, where it places their BARs, how it
moves a function from what its configuration space reads to what its
holder asked for, how a function's interrupt is routed and by whom, how
the domain reaches configuration space through QEMU `virt`'s ECAM bridge
and the Raspberry Pi 4's BCM2711 bridge alike, what it reports to the
device service and in which record, how a function is given to the
domain the manifest names, and what survives a restart of any party. It
refines the PCIe enumerator, units and gives of
[design-system.md](design-system.md#devices), the unit rule of
[design-shared-devices.md](design-shared-devices.md#the-unit-rule), the
MSI frames and PCIe bridges of
[design-platforms.md](design-platforms.md#pcie-bridges), the
`ERX_IRQ_MSI` object of [design-kernel.md](design-kernel.md#irq-objects)
and the device records of
[design-stopgap.md](design-stopgap.md#device-records), and says where
each of them changes.

Decisions every reader needs:

* **One planner moves a function from what it reads to its target.**
  Each function has a **target**: its **layout**, fixed for the boot by
  its bridge's first report, and its **setting**, a mode and an
  interrupt route, which the give and its holder's requests choose. Both
  live in the system domain's domain library. One pure function,
  `erx_pcie_plan:plan/2`, turns a function's configuration as read and
  its target into the writes that reach the target: none when the
  function already reads as it; otherwise up to three stages, the
  switches lowered as far as the change needs, the data written, and the
  switches raised again, each with the state it leads to. The PCIe
  domain reads the function back after each stage and starts the next
  only when the function reads as that state.
* **Bus mastering is raised only by a living holder's `master`, and only
  from decoding.** A start of the PCIe domain keeps every function that
  reads exactly as its setting and turns every other one off, its layout
  written; it never raises one. So a reset of any kind, a function's, its
  link's or its bridge's, leaves the function off until its holder opens
  it and resets its device again.
* **MSI where the function offers it, MSI-X where it offers nothing
  else, INTx only on a closed bus.** MSI lies wholly in configuration
  space, so the enumerator writes all of it; MSI-X's table lies in a
  BAR, so the holder's device NIF writes the table from the route the
  give made, every entry, before the enumerator unmasks it. A **closed
  bus**, the Raspberry Pi 4's, is one whose platform record lists every
  place on it with the pin its function raises, and whose bridge driver
  reaches no other place, so each line it routes is a line of its
  place's unit, as any device-tree line is. One message per function.
* **The layout is small on purpose.** Memory BARs go into the host
  bridge's 32-bit window, each in whole pages of its own, packed largest
  first, every one placed by erXos; bridges are root ports only; I/O
  BARs, ROMs, the 64-bit window, firmware's BAR assignments, switches,
  hotplug and extended capabilities have no consumer and are not used.
* **Two bridge drivers behind one access.** The walk, the placement and
  the planner are the same code for every bridge; a bridge driver
  supplies only its bring-up, one configuration access at a place, and
  the refusal of every place its bridge must not be asked about.

## Contents

* [Context](#context): what is matched, what the tree does today, the
  consumers
* [Requirements](#requirements)
* [The construction](#the-construction): targets, the plan, what
  follows, what disappears
* [The PCIe domain](#the-pcie-domain): processes, the bridge seam, the
  walk, sizing, placement, root ports
* [Records](#records): the function, the setting, the bridge, the
  catalogue
* [Interrupts](#interrupts): the choice, who programs what and when, the
  MSI frame on the stopgap, the closed bus
* [DMA](#dma)
* [Facets](#facets): the three interfaces and the start's conversation
* [The catalogue and gives](#the-catalogue-and-gives)
* [Concurrency](#concurrency)
* [Failure handling and restart](#failure-handling-and-restart)
* [Refusals and error results](#refusals-and-error-results)
* [On the stopgap](#on-the-stopgap)
* [Verification](#verification)
* [Changes to other designs](#changes-to-other-designs)
* [Alternatives considered](#alternatives-considered)
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
  in use (`:4924-4932`). FreeBSD never writes the per-vector mask
  register, which `pcireg.h` places at `0x10` (`PCIR_MSI_MASK`, `:625`).
* **MSI-X.** A table entry is 16 bytes, address low and high, data and
  vector control, written through the memory of the BAR that holds the
  table (`pci_write_msix_entry`, `pci.c:1695-1706`; `pci_mask_msix`,
  `:1737-1753`). Allocation masks every entry before it enables MSI-X
  (`:1941-1947`), and resume masks every entry, writes and unmasks the
  ones in use, then writes the control register (`pci_resume_msix`,
  `:1792-1821`). FreeBSD's xHCI attach takes MSI-X, then MSI, then INTx
  (`xhci_pci.c:357-393`).
* **Function-level reset.** Bus mastering is turned off "to prevent
  generation of new transactions"; Transactions Pending in the device
  status is polled every 100 ms up to the caller's limit; then the
  initiate bit and 100 ms; no register is saved or restored, so the
  caller programs the function again (`pcie_flr`, `pci.c:6741-6797`;
  `pcie_wait_for_pending_transactions`, `:6585-6613`). With transactions
  still pending, a caller that does not force the reset gets no reset
  and its command register back; one that forces it waits 100 ms plus the
  larger of 10 ms and the function's completion timeout, which the
  device control register can set as high as 64 s (`:6620-6661`).
  FreeBSD's own bus reset waits 1000 ms and does not force
  (`pci_reset_child`, `:6874`).
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
`boot_devices`, `:363-442`; a `TODO.md` item). `erx_irq_create` of
`ERX_IRQ_MSI` is `ERX_ENOTSUP` on the stopgap
(`liberx/backend/fiasco/irq.c:188`). The stopgap's give makes a
device's memory with `erx_mem_create_contiguous_in` inside the DMA range
of the device's catalogue facts, CPU addresses `cpu` through `last`
seen by the device from `bus` (`liberx/system/dom_apply.c:420-425`,
`erx_boot_dma_range`; `liberx/backend/api.h:166-181`). The device-tree
reader does not take a PCI host bridge's three-cell `dma-ranges`, so a
PCIe function gets no DMA range
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

Two further consumers shape what is left open, and are served by the
designs that bring them:

* **virtio-pci block and network**, on QEMU `virt` in a release build,
  confined behind the SMMU ([design-platforms.md](design-platforms.md#dma)).
  A virtio-pci driver finds its common, notification, ISR and
  device-specific registers through vendor-specific capabilities
  (virtio 1.2, section 4.1.4), which only the PCIe domain can read, and
  interrupts by MSI-X, since virtio defines no other per-vector
  interrupt (section 4.1.5.1.2). The virtio-pci transport's design adds
  those capabilities, decoded and bounded, to the layout and the given
  record; this design gives it the MSI-X route.
* **RP1**, on the Pi 5, behind the BCM2712's root port, which keeps the
  BARs its bootloader assigned
  ([design-platforms.md](design-platforms.md#pcie-bridges)) and wants
  several messages. Its bridge driver, the placement of kept BARs and
  more than one message are the Pi 5 port's.

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
* **R5. A function's bus mastering is raised only by its holder's
  `master`**, which the holder sends after its `open` and its own reset
  of the device, and only while the function still decodes as that
  `open` left it; a holder's end turns the function off, at once while
  the PCIe domain serves and at its next start otherwise. Memory safety
  does not rest on that turn-off ([Concurrency](#concurrency)).
* **R6. A restart of the PCIe domain changes no function that reads as
  its setting, and raises none.** A function a reset disturbed keeps its
  layout and stays off until its holder opens it again.
* **R7. One record of a function**, generated for C and Erlang from one
  source: the PCIe domain writes it, the device service keeps it in the
  domain library, and the library plans the give from it.
* **R8. Untrusted input is parsed once.** Configuration space and BAR
  sizing answers are parsed by binary matching in Erlang with fuzz
  targets; the report is checked once, whole, at the library's intake,
  against the bridge's windows and every other device.
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
  their hardware sizes and PCI addresses, and its capabilities' offsets.
  The PCIe domain computes it at its bridge's **placing walk**, the walk
  of a bridge for which the library holds no layouts, which is the
  boot's first walk of it, or a later one if every earlier walk of it
  found nothing. The library keeps the layout of every function that
  walk reported, held or not, and from then on it is fixed for the boot.
* its **setting**, `erx_pcie_setting`: a **mode**, `off`, `decoding` or
  `mastering`, and an interrupt **route**, `none`, `msi` with the
  doorbell address and data, `msix` with the same, or `intx`. The give
  writes the route from the objects it made; the holder's requests
  choose the mode. A function no manifest row holds has the setting
  `off` with route `none`.

Both live in the domain library, in the system domain, which outlives
every other party: the layouts in the host bridge's catalogue entry, a
setting in the entry of the `pci` row that holds the function
([Records](#records)).

### The plan

The fields of configuration space a target decides are of two kinds:

* **Switches**, each a small ordered state, lowest first: memory space
  (off, on), bus master (off, on), INTx (disabled, live: the command
  register's interrupt disable set or clear), MSI (disabled, live: its
  enable bit), and MSI-X (disabled, masked, live: its enable bit clear;
  enable and function mask set; enable set and function mask clear).
  I/O space is a switch that is always off. A function is **quiet** when
  every switch is at its lowest.
* **Data**: each BAR's address bits, MSI's address and data, its
  multiple message enable, and its per-vector mask where the capability
  has one at an offset `pcireg.h` gives; for a root port, its bus
  numbers and its windows ([Root ports](#root-ports)).

The **projection** of a target decides them. Data depends on the layout
and the route alone, in every mode: each BAR holds its layout's address;
for an `msi` route MSI holds the route's address and data, multiple
message enable 0 and its vector 0 unmasked. Switches depend on the mode
and the route:

| Mode | Memory space | Bus master | INTx | MSI (`msi` route) | MSI-X (`msix` route) |
| --- | --- | --- | --- | --- | --- |
| `off` | off | off | disabled | disabled | disabled |
| `decoding` | on | off | disabled | disabled | masked |
| `mastering` | on | on | live for an `intx` route, disabled otherwise | live | live |

A capability the route does not use is disabled in every mode, so the
mechanism not chosen never fires. A **state** is a value of every switch
and data field the projection decides; a target's projection is one. A
function **reads as** a state when every one of those fields reads as
the state's value, and as a target when it reads as the target's
projection.

`erx_pcie_plan:plan(Read, Target)` is a pure function from the
function's configuration as read (the parsed snapshot) and its target
to `{ok, Stages}` or `{error, reset}`. A **stage** is a list of writes
and the state they lead to; a plan has at most three, in this order,
and leaves out an empty one:

1. **Nothing to do.** When the function reads as the target, the plan
   has no stage.
2. **The mastering rule.** A target of mode `mastering` is planned only
   from a function that reads as the same target at `decoding` or at
   `mastering`; from anything else the answer is `{error, reset}` and
   there is no plan. So bus mastering is never raised over a function
   that something reset or rewrote since its holder's `open`.
3. **The floor.** When any data field differs, the floor is quiet.
   Otherwise each switch's floor is the lower of what it reads and what
   the target decides.
4. **The descent**, the first stage. Each switch above its floor is
   lowered to it, in this order: bus master, MSI, MSI-X, INTx, memory and
   I/O space. Its state: every switch at its floor, the data as read.
5. **The data**, the second. Each differing data field is written, in
   register order, a 64-bit BAR low word then high word. Its state: the
   switches at the floor, the data the target's.
6. **The ascent**, the third. Each switch below the target's state is
   raised to it, in this order: memory space, MSI-X to masked, MSI,
   MSI-X to live, INTx, bus master. Its state: the target's projection.

Each write is the whole register as it stands after the writes before
it, so a command-register write that clears bus master carries the
memory-space and interrupt-disable bits as they are at that point, and
every later write is computed against that intermediate state. Command,
MSI control and MSI-X control are written 16 bits wide, so no status
bit is written; the data stage's write of MSI control, for its multiple
message enable, carries the enable bit at its floor. Since a plan to
`mastering` starts from `decoding` or above, a plan has at most one
write per switch on each side and one per data field.
`erx_pcie_plan:quiet(Read)` is the descent alone, every switch to its
lowest, its state quiet with the data as read; it needs no layout.

Five properties follow from the order, and the host tests check each
over every input ([Verification](#verification)):

* **Data moves only while the function is quiet**: no BAR changes under
  decoding, and no address or data changes under a live message or bus
  mastering. A mastering function whose BAR or MSI address is wrong is
  lowered all the way first, although its switches already equal the
  target's.
* **Every lowering precedes every raising.**
* **Bus master is raised last and lowered first**, since turning it off
  stops the function's new transactions, its messages among them
  (`pci.c:6757-6764`); that bus mastering gates a message write is
  unverified against the specification. Clearing it does not wait for
  the transactions already issued, and nothing here says it does:
  FreeBSD clears it and then waits for the pending transactions apart,
  before a function-level reset (`:6757-6766`), as `reset` below does,
  and a function's memory stays safe
  through the IOMMU window's deletion or the unconfined memory kept for
  the boot, never through bus master's being clear
  ([Concurrency](#concurrency)).
* **Every stage moves one way.** Each write of a stage carries every
  switch at a value between its value at the stage's start and its value
  in the stage's state, MSI-X's masked step on the way to live among
  them, and the data stage carries every switch at its floor. So
  whichever of a stage's writes take, and however a later write of the
  same register repeats one that did not, every switch lies between
  those two values, and a stage that took only in part leaves the
  function nowhere its two ends do not bound.
* **Every prefix of a plan is safe**: after any prefix no switch is
  above both what it read and what the target decides, no switch has
  been raised while a data field still differs from the target, and the
  next start's rule below takes the function on from there.

**Applying a plan.** The effect layer, `erx_pcie_apply`, reads the
function's snapshot and plans, then holds to one rule: **a stage is
confirmed before the next begins.** It makes a stage's writes, reads the
snapshot again and parses it, and starts the next stage only when the
function reads as the stage's state. So the floor is confirmed by a
readback before any data is written, and the data before any switch is
raised: a disable that did not take is seen before a BAR moves under it,
whatever later write of its register would have hidden it, and a BAR
that did not take is seen before decoding turns on at a wrong address.
A plan with no stage needs no readback, since the function read as its
target. The outcomes:

* the last stage's readback reads as its state, the target: `ok`;
* an access answers `link_down`: the enumerator exits at once, so its
  domain's restart is the bridge's recovery
  ([Failure handling](#failure-handling-and-restart)); whatever part of
  the plan was made, the next start decides from what it reads;
* a readback reads absent or with another identity: `{error, gone}`,
  and nothing more is written;
* a readback reads present with its identity but not as its stage's
  state, a write that did not take: no later stage is made. The
  enumerator logs the first field that differs and runs `quiet/1` from
  what it read, by the same rule. When the function then reads quiet the
  answer is `{error, gone}`; when it does not, a disable that did not
  take, the answer is `{error, stuck}`, with the field logged, and the
  function is left as it reads. Nothing claims a stuck function is
  quiet, and nothing needs it to be: its memory is safe as when the PCIe
  domain stays down ([Concurrency](#concurrency)). Its next request, or
  the next start, plans again from what it reads, and no data is ever
  written over a switch that will not lower, since the descent's
  readback stops the plan first.

**The start's rule.** At each start the target the enumerator applies to
a function is its target if the function reads as it, and otherwise the
same target in mode `off`. A running function's plan is then empty, and
a disturbed one gets its layout and route written with every switch
quiet. `erx_pcie_plan:start_target/2` is that choice. A function with no
layout, one that appeared beside its bridge's layouts, is only lowered
to quiet, by `quiet/1`.

**A function-level reset**, `pcie:reset`, is three steps around the
planner, each plan applied by the rule above and its error, if any, the
answer. First the plan to `off`. Then, when the layout's Express flags
offer the reset, Transactions Pending in the device status is polled
every 100 ms for at most 1000 ms, as FreeBSD's own bus reset waits
without forcing (`pci.c:6874`); with transactions still pending the
function is left off and the answer is `{error, busy}`, since a forced
reset would have to wait out a completion timeout the function may set
as high as 64 s (`:6620-6661`), which no consumer needs. Otherwise the
initiate bit, 100 ms, and a read that must find the function present
with its identity, else `{error, gone}`. Last the plan to `decoding`, and
the answer `{ok, flr}`, or `{ok, none}` for a function that offers no
reset, which the driver then resets by its registers. The longest
`reset` is so bounded by 1000 ms, 100 ms and its accesses.

### What follows

* **A restart changes no running function and raises none (R6).** A
  function that reads as its setting gets an empty plan; any other is
  turned off. The PCIe domain needs no memory of its own for this: the
  layouts and settings come from the system domain at its start.
* **Every disturbance has one outcome.** A function-level reset, a link
  that fell, the BCM2711 bridge's reset, a write that did not take, or
  anything else that leaves configuration space other than its setting
  leaves the function off with its layout at the next start, so its
  register windows and DMA stay valid, or, where a disable will not
  take, left as it reads with `{error, stuck}`. Its holder learns of it
  from its device, which stops answering, from `{error, reset}` at its
  next `master`, or from the `{error, gone}` or `{error, stuck}` of the
  request that met it, and its driver starts again with `open`. State
  outside configuration space, the MSI-X table and the device's own
  registers, is the holder's to write again; nothing claims a reset
  leaves it any particular way.
* **Mastering follows the holder (R5).** The mode rises only through the
  holder's requests, `master` only from `decoding`, and the holder's end
  sets it `off`.
* **Bridges hold no state.** A root port's bus numbers, windows and
  switches are a pure function of its place and the layouts below it
  ([Root ports](#root-ports)), and the same planner moves it.
* **An interrupted transition needs no recovery.** A plan cut short, by a
  fallen link or by the enumerator's end, leaves a prefix, which the next
  start either finds equal to the setting or turns off.

### What disappears

| Special case | Why it is not needed |
| --- | --- |
| a save and restore around a function-level reset | the plan writes the layout and route after any reset; the holder writes what lies outside configuration space as it starts again |
| a list of the resets a restart must recognize | a start keeps exactly what reads as its setting and turns everything else off, whatever disturbed it |
| a restart path that checks whether the bus is already laid out | the library's layouts say; a function that reads as its setting gets no write |
| re-enabling a function after its driver's reset | the driver's `master` raises the mode; there is no separate "again" |
| a recovery protocol for a plan cut short | every prefix is a state the next start handles |
| a readback after every write, or a list of the writes whose failure a later write would hide | each stage moves one way and carries the state it leads to, and apply confirms it before the next begins |
| a record of the root ports' windows | derived from the bridge's layouts |
| a first-boot flag in the PCIe domain | a bridge's walk places exactly when the library holds no layouts for it |
| a closed-bus case in the walk | the BCM2711's access answers `absent` for every place its bridge does not list |

## The PCIe domain

### Processes

The PCIe domain, `pcie` (node `pcie@erxos`), runs one permanent
application, `erx_pcie` in `erlang/apps/erx_pcie/`, whose one process,
the **enumerator**, owns every bridge the domain holds and serves the
`pcie` facet. Its decisions are pure modules:

| Module | Pure function |
| --- | --- |
| `erx_pcie_cfg` | parses a configuration snapshot, 256 bytes, into the read value of a function or root port, or refuses it; decodes BAR sizing answers |
| `erx_pcie_walk` | the walk as a state machine: each step takes the last access's answer and returns the next access or the walk's result |
| `erx_pcie_place` | the layouts of a placing walk's functions, given the bridge's windows |
| `erx_pcie_plan` | the plan's stages, each its writes and the state they lead to, from a read value and a target; the descent to quiet; whether a function reads as a state; the start's target |
| `erx_pcie_bcm2711_core` | the BCM2711 bridge's bring-up and keep-or-reset decision as a state machine over register reads |

The effects, every configuration access and every bridge register, go
through the bridge driver's `access` and the device NIF, and
`erx_pcie_apply` is the one caller of `plan/2`. Any crash of the
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
place, and answers `{error, absent}` without touching the hardware for
a place its bridge must not be asked about; `ready` lets a bridge hold
back a function its board must start first. The walk, sizing, placement
and planner call nothing else, so a third bridge is one more module. The
enumerator chooses the module by the bridge's given record's
peripheral, `pci_ecam` or `bcm2711_pcie`, rows of
`include/erx/device_kinds.h` with role `configuration`.

**ECAM** (`erx_pcie_ecam`). `start` does nothing. An access at a place
whose bus lies outside the bridge's bus range, from the tree's
`bus-range` or 0 to 255 without one, answers `{error, absent}`; otherwise
it reads or writes at `(bus - first) << 20 | device << 15 | function << 12
| offset` in the configuration window, as FreeBSD's
`generic_pcie_read_config` does. A read of all ones at offset 0 is
`absent`. `ready` is always `ok`.

**The BCM2711** (`erx_pcie_bcm2711`). Its contract is this design's; its
register values are the facts record's:

* **The places it reaches.** On bus 0 only the root port, at device 0,
  function 0, since any other place there "will lock up the memory
  controller" (facts record, section 3; `bcm2838_pci.c:291-307`); below
  it only the places the bridge's facts list, which its platform record
  gives ([The closed bus](#the-closed-bus)). Every other place answers
  `{error, absent}` before any register is touched, whatever the root
  port's header type or a configuration read says, so the accesses whose
  outcome no source gives (facts record, unknown 6) are never made.
* **Access.** The root port's configuration is at offset 0 of the
  bridge's registers; an endpoint's is reached by writing its place in
  ECAM layout to the index register at `0x9000` and accessing the data
  window at `0x8000` (facts record, section 3; `bcm2838_pci.c:266-289`).
  The two operations are one `access`, inside the one enumerator
  process, so no other access comes between them.
* **The link around every access.** An access below the root port reads
  `MISC_PCIE_STATUS` (`0x4068`) and goes on only with `PHYLINKUP` (bit 4)
  and `DL_ACTIVE` (bit 5) set, makes the access, and reads the status
  again, keeping the value only when the link is still up; otherwise it
  answers `{error, link_down}` (facts record, sections 3 and 8, item 10).
  The two reads keep an answer made while the link was down from being
  taken, not one made while it fell and came back between them; that
  residual and how the abort is taken on each kernel are in [Failure
  handling and restart](#failure-handling-and-restart).
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
  nothing off its bus. The keep path makes no notification, and needs
  none to learn whether the VL805 may be given: a timed-out notification
  is kept in the library, outside the PCIe domain, and excludes the
  bridge's functions there for the rest of the boot, whatever `0x50`
  reads at a later start (the next item).
* **The endpoint's firmware.** The VL805 loses its firmware at every
  PERST# (facts record, section 6), so the last step of bring-up, after
  the root port's bus numbers are written and the endpoint's place reads
  present, asks the device service for the firmware notification with
  `pci_bus:firmware/1` ([Facets](#facets)), then waits 1 ms and reads
  `0x50`. The device service makes the narrow kernel call through the
  domain library, `erx_domain_lib:pci_firmware(Bridge)`, over
  `erx_dom_pci_firmware` in C, with the resource the bridge's device
  record holds for its give; no capability for it reaches the PCIe
  domain, and the caller is the same in both phases
  ([design-usb.md](design-usb.md#the-vl805s-firmware)). When the call
  answers `ERX_ETIMEDOUT`, that library call marks the bridge's
  catalogue entry `firmware_lost` before it returns, so no crash of the
  device service or of the PCIe domain falls between the timeout and its
  mark ([The catalogue and gives](#the-catalogue-and-gives)). An error
  answer is logged as `vl805 firmware not loaded` and `0x50` is not read
  again. `ready` answers `not_ready` for `1106:3483` while `0x50` reads 0 or all
  ones, so that function is reported `not_ready` and never given with
  absent firmware (`bcm2838_xhci.c:113-175`).
* **Its lines.** The bridge's two interrupts, SPIs 147 and 148 (INTIDs
  179 and 180), are lines of its own unit; the PCIe domain holds them
  and leaves them masked.

The handover question, whether the boot firmware leaves the VL805
running, belongs to the board's boot contract and is the USB design's,
which lists the VL805's handover as unknown until its evidence is
recorded ([design-usb.md](design-usb.md#the-bcm2711-bridge)); this
design's keep rests on it and adds nothing to it.

### The walk

`erx_pcie_walk` reads; it writes only the root ports, through the
planner, and the sizing sequence, and only where [Sizing](#sizing)
allows. For each host bridge, from the bridge's first bus:

1. **The root bus**, devices 0 to 31. For each device, function 0's
   vendor; absent ends the device. Its header type; a type above 1 is
   reported `unsupported`; the multifunction bit adds functions 1 to 7.
   The bridge driver's `access` answers `absent` for a place it does not
   reach, so the walk is the same for every bridge.
2. **Each function** is read whole: its 256-byte configuration space, a
   **snapshot**, which `erx_pcie_cfg:parse/1` turns into a read value or
   refuses; a refused one is reported `malformed`, with the field, and
   gets one write, its command register with memory, I/O and bus master
   off and INTx disabled, which needs nothing the parser refused.
3. **A type-1 header on the root bus** is a root port. It takes the next
   bus number in place order as its secondary and subordinate bus, and
   its target is applied at once ([Root ports](#root-ports)), so the bus
   below it can be read. Below it, devices 0 to 31 are read as in step 1.
   A type-1 header below a root port is reported `unsupported` and
   nothing below it is read.
4. **The function's place** is its bus, device and function; its
   requester id is `bus << 8 | device << 3 | function`, derived, never
   stored.

No step recurses and the topology has two levels, so the walk's length
is bounded by 32 devices times 8 functions on each of the root bus and
each root port's bus, at most `pcie_functions_max` functions per bridge
reported ([Records](#records)); a function past the bound is logged and
left as it is.

**The parser** follows the capability list from offset `0x34` only when
the status register's capability bit is set, and takes each pointer with
its low two bits cleared. It refuses the snapshot, naming the field,
for: a pointer below `0x40`; a list of more than 48 capabilities, the
most 192 bytes hold, which a loop makes; a capability whose fields, by
its own control word, extend past offset 255; a 64-bit BAR in the last
BAR register, which has no upper half; an MSI-X table whose BAR
indicator is above 5 or names an absent, I/O or upper-half BAR; and an
MSI-X table whose offset plus 16 bytes per entry overflows 32 bits; and
a second MSI (`0x05`), MSI-X (`0x11`) or PCI Express (`0x10`) capability
(`pcireg.h:139-151`), where FreeBSD keeps whichever it reads last
(`pci.c:962-970`, `:1003`), so no record depends on which of two a
reader picks. Every offset it reports lies inside
the snapshot and every field it reads fits there, by binary matching
that cannot read past the bytes.

### Sizing

Only a placing walk sizes, and it sizes every function and root port it
finds, since the library holds no layout for any of them. Sizing
follows FreeBSD's `pci_read_bar`: memory space off, all ones to the BAR
(both halves of a 64-bit BAR before either is read), read back, the
original value restored, the command register restored.
`erx_pcie_cfg:size/2` decodes each answer into the BAR's hardware size.
It refuses a base mask whose set bits are not contiguous from the top,
naming the BAR, and the function is reported `malformed`; a 64-bit BAR
whose size needs the high word is a size the 32-bit window cannot hold,
and the function is reported `unplaced`. A memory BAR under 16 bytes is
ignored, as FreeBSD ignores it. A placing walk finds
no holder, since a function is given only once its bridge's layouts
exist, so sizing disturbs no driver; any later walk sizes nothing. The
ROM BAR is not sized.

### Placement

`erx_pcie_place:layout(Windows, Functions)` places the BARs of a placing
walk's functions and returns each one's layout, or leaves a BAR
unplaced:

* **The window.** The host bridge's first memory window that is not
  prefetchable and whose PCI range lies below 4 GiB, from the tree's
  `ranges`. Every memory BAR goes there, 64-bit ones included, whose high
  word is then zero; prefetchable memory may lie in non-prefetchable
  space. I/O BARs are never placed.
* **Items.** Each memory BAR is an item whose span is its hardware size
  rounded up to the page size, and whose alignment is that span, so no
  two BARs, and so no two functions, share a page: PCIe functions take
  no part in the unit rule's page relation, by construction. The layout
  keeps the hardware size; the span is derived from it wherever it is
  needed. A root port's functions are laid out first, inside it, from
  offset 0; the root port is then one item whose span is that extent
  rounded up to 1 MiB and whose alignment is the larger of 1 MiB and its
  largest item's.
* **Packing.** The items are sorted by alignment, largest first, then by
  place and BAR index, and each takes the lowest address from the
  window's base that is aligned to it and overlaps nothing placed. Since
  every span is a multiple of its alignment, this packs without a gap,
  and the same functions always get the same addresses. Each root port
  is one item, so the forwarding windows of two root ports never
  overlap.
* **What does not fit** is unplaced, and the function is reported
  `unplaced`; it is never given.

Every BAR is placed afresh, whatever an earlier stage of the boot left
in it: QEMU's are blank, and the VL805 is placed before any driver uses
it. Keeping a firmware's assignment is the Pi 5 port's addition, for RP1.

A function a later walk finds at a place its bridge's layouts do not
hold is reported `unplaced` and waits for the next boot, so a later walk
never moves a root port's window around running functions.

### Root ports

A root port is the bridge's forwarding state, not a function of the
catalogue: no manifest row holds it, it has no setting and no layout in
the library, and none of the rules for functions (sizing after the
placing walk, the start's turn to `off`, the give) apply to it. Its
target is derived from its place and from the bridge's layouts of the
functions below it:

* **Data:** primary bus, secondary and subordinate as the walk numbered
  them; its memory base and limit, 1 MiB granular, to the span of its
  functions' placed BARs, or disabled, base above limit, when it has no
  placed BAR below it; its prefetchable and I/O windows disabled
  (`pci_pci.c:1617-1629`).
* **Switches:** memory space and bus master on when its window is
  enabled, which let it forward its functions' accesses and DMA and make
  it master nothing itself, and off otherwise; INTx, MSI and MSI-X
  disabled.

The walk applies that target through `erx_pcie_apply` as soon as it
numbers the root port: at a placing walk, from no layouts, which gives
it its bus numbers and a closed window; once the placement is done, from
the new layouts, which opens its window. At every other walk the
layouts are the library's, so a running root port reads as its target
and gets no write; after a bridge reset it is written whole. A root
port whose own BAR reads back nonzero at the placing walk's sizing
implements a BAR, which no consumer's root port is known to; it is
reported `unsupported` with nothing below it read, and the BCM2711's
root port is read by probe B4.

## Records

The records are layouts in a new ABI file, `abi/formats/pcie.txt`, as
`wire_le` layouts with the configuration-space constants the parser and
the planner use (offsets and bits from FreeBSD's `pcireg.h`) and the
limits below. The generator emits their C reader and struct and their
Erlang codec, as it does for the manifest's records
([design-abi.md](design-abi.md)), so the PCIe domain, the device service
and the domain library share one definition.

**`erx_pcie_function`**, the layout, which the PCIe domain reports:

| Field | Width | Meaning |
| --- | --- | --- |
| `bridge` | u32 | the manifest device row of its host bridge |
| `bus`, `device`, `function` | u8 each | its place; the requester id follows |
| `state` | u8 | `ready`; `not_ready` (its bridge's `ready` held it back); `unplaced` (a memory BAR did not fit or did not size, or it appeared beside the bridge's layouts); `unsupported` (a header type, level or root-port BAR the walk does not take); `malformed` (its snapshot did not parse) |
| `vendor`, `device_id` | u16 each | its identity |
| `class` | u32 | base class, subclass and programming interface, bits 23 to 0 |
| `revision`, `header` | u8 each | revision; header type without the multifunction bit |
| `subsystem_vendor`, `subsystem` | u16 each | |
| `pin` | u8 | 0 for none, 1 to 4 for INTA to INTD |
| `bars` | 6 times `erx_pcie_bar` | in BAR register order |
| `msi` | u8 offset, u8 flags (64-bit, per-vector mask), u8 vectors capable as a power of two | offset 0 for none |
| `msix` | u8 offset, u16 table size, u8 table BAR, u32 table offset | offset 0 for none |
| `express` | u8 offset, u8 device type, u8 flags (function-level reset) | offset 0 for none |

**`erx_pcie_bar`**: `kind` u8 (absent, memory, I/O; the upper half of a
64-bit BAR is absent), `flags` u8 (64-bit, prefetchable, placed),
`size_log2` u8, the BAR's hardware size, and `address` u64, the PCI
address, 0 when not placed. Its span, the size rounded up to the page
size, is derived.

**`erx_pcie_setting`**: `mode` u8 (`off`, `decoding`, `mastering`),
`route` u8 (`none`, `msi`, `msix`, `intx`), `address` u64 and `data` u32,
the doorbell and value of the function's one message, zero for the other
routes.

**`erx_pcie_bridge`**, what the device service hands the PCIe domain of
each bridge it holds: `index` u32, its manifest device row; `bus_first`
and `bus_last` u8; `flags` u8 (closed); `windows`, at most
`pcie_windows_max` (4) of `pci` u64, `cpu` u64, `size` u64 and `flags`
(64-bit, prefetchable, I/O), from the tree's `ranges`; and, for a closed
bridge, `places`, every place below its root port that its platform
record lists, each a bus, device, function and pin, at most
`pcie_closed_max` (4).

Limits: `pcie_bridges_max` 2 per domain, `pcie_functions_max` 32 per
bridge. The generator checks each layout's offsets and size; the C reader
refuses a record whose enums are out of their sets, whose capability
offsets lie outside 256 bytes, or whose 64-bit BAR is not followed by an
absent upper half, so the library's intake ([The catalogue and
gives](#the-catalogue-and-gives)) starts from a well-formed record and
checks only what relates records to windows and to each other.

**The catalogue.** A host bridge's entry in the domain library's
`erx_dom_device_t` gains the bridge's **layouts**: every function its
placing walk reported, at most `pcie_functions_max`, each with its
latest reported `state` and `confirmed`, whether the latest report
listed it with its layout; **`firmware_lost`**, set when the bridge's
firmware notification answered `ERX_ETIMEDOUT` and never cleared in the
boot, since the kernel answers every later notification of the boot the
same way without making it
([design-usb.md](design-usb.md#the-vl805s-firmware)); and
**`answered`**, the domain id of the PCIe incarnation whose report the
device service last answered, 0 for none, which domain ids, never reused
in a boot, keep from naming a later incarnation
([Concurrency](#concurrency)). A `pci` row's entry gains its
**setting**. The row finds its function's layout by place in its
bridge's entry, so no layout is stored twice.
`erx_domain_lib:devices/0` shows them, with `/dev`'s `status` naming
the place, the identity, the BARs, the state, the mode and the route,
and the bridge's `firmware lost` when it is set.

## Interrupts

### The choice

For a function with a holder, the give chooses the route by what the
layout reports and what the manifest row says:

| The row and the function | Route |
| --- | --- |
| the row names a line (a closed bus) | `intx`, the row's line |
| otherwise, the function has MSI, with no per-vector mask or one at the offset `pcireg.h` gives | `msi`, one message |
| otherwise, the function has MSI-X | `msix`, table entry 0 |
| otherwise | `none`: no interrupt, and its driver polls, the rule of [design-system.md](design-system.md#devices) |

MSI comes before MSI-X because MSI lies wholly in configuration space:
the enumerator writes the address, the data, the mask and the enable
bit, and no register in the holder's window carries an interrupt
address. `pcireg.h` gives the per-vector mask only for a capability with
64-bit addresses (`PCIR_MSI_MASK`, `0x10`); for a 32-bit capability with
per-vector masking no source read gives the mask's offset, so such a
function is routed by MSI-X or not at all, since a mask the planner
cannot write could leave its vector masked under a live route.

MSI-X's table lies in a BAR, which is the holder's window, so the
holder's device NIF writes it from the doorbell and data its given
record carries, as it writes every address-bearing register itself and
never from Erlang ([design-system.md](design-system.md#drivers)): entry
0's address, data and vector control unmasked, and every other entry of
the table's size masked, as FreeBSD masks every entry before it enables
MSI-X (`pci.c:1941-1947`). That adds nothing to the MSI frame's
residual: the frame does not identify its writer, so a function that can
write the frame, by its MSI or by DMA to the doorbell, can already raise
any of its lines
([design-kernel.md](design-kernel.md#dma-and-the-iommu)).

**One message per function.** Each consumer this design serves works
with one: xHCI with one interrupter and the VL805 by INTx; a virtio-pci
driver can take every event on vector 0, which its specification allows
(section 4.1.5.1.2). MSI's multiple message enable is 0 and MSI-X
entries past 0 are masked. RP1 and multi-queue virtio-pci network want
several; the design that brings the first of them gives the setting a
count and the give that many objects, up to `ERX_MSI_MAX`. A function
whose MSI capability takes only 32-bit addresses needs a doorbell below
4 GiB; the enumerator refuses a `set` whose route it cannot write with
`{error, route}`.

### Who programs what, and when

| Step | Who | What |
| --- | --- | --- |
| the give, in the holder's creation | the domain library | the function's register windows over its placed BARs' spans, its IRQ object (`ERX_IRQ_MSI`, or `ERX_IRQ_LINE` for the closed bus's line), its DMA window or contiguous memory, its given record; it writes the setting's route from the IRQ object's doorbell and data; the mode stays `off`, and nothing is sent to the PCIe domain |
| the driver's start | the driver, by `pci:open` | the device service sets `decoding`; the enumerator's plan writes the BARs and the MSI address, data and mask if they differ, with the function quiet, then memory space and MSI-X masked |
| the driver's reset of its device | the driver, by its registers | xHCI's `HCRST`, virtio's status 0; nothing of PCIe; for an MSI-X route the NIF writes the whole table now and reads entry 0's data back, so the table's writes are made before the driver goes on |
| the driver ready | the driver, by `pci:master` | `mastering`, planned only from `decoding`: MSI live, or MSI-X live, or INTx live; then bus master |
| a reset the registers cannot do | the driver, by `pci:reset` | `off`; a function-level reset when the function offers one; then `decoding` again; the driver resets its device, writes its MSI-X table again and sends `master` |
| the holder's end | the device service | `off` |

So an xHCI controller reset is not a PCIe request: the function stays
`mastering` through it, and the controller's own halt stops its DMA. A
driver process that its supervisor restarts sends `open` again, which
turns bus mastering off, so the new driver resets a device that masters
nothing. That a read of the table returns only after the writes before
it have reached the function is the PCIe ordering rule, unverified
against the specification; FreeBSD's resume writes every entry before
it writes the control register (`pci.c:1792-1821`).

`open` followed by `master` proves the holder's order of calls, not that
it reset its device in between. A holder is trusted with its own
device: a confined function that masters without its reset reaches only
its own window, and the holder of an unconfined one is in the trusted
base already ([DMA](#dma)).

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
**closed** bridge removes that reason from the platform's topology
itself: its platform record marks it closed and lists every place below
its root port, each with the pin its function raises, its root bus holds
one root port at device 0, function 0, and its bridge driver's `access`
reaches no other place ([The bridge seam](#the-bridge-seam)). Every
function that can raise a line its tree routes is then at a listed
place, whatever the manifest selects, so each line is known when the
manifest is written and joins the unit rule's line relation as a
device-tree line does.

* **The row.** A `pci` row at a closed bridge's listed place names a
  line, the interrupt id its bridge's `interrupt-map` routes for the
  place's pin, which the packer copies from the platform record; on the
  Pi 4, INTA to INTD go to SPIs 143 to 146 under a mask that keeps only
  the pin (facts record, section 0), so the VL805's row names INTID 175
  (SPI 143). A `pci` row elsewhere names none. The boot view puts such a
  row's line in the line relation, so a second row naming it is in the
  same unit or the view is refused.
* **At boot.** The root reads the bridge's `interrupt-map` for each
  listed place's pin. The boot view refuses the bridge's unit and the
  place's when the map routes the pin to a line other than the row's, or
  to one of the bridge's own lines, since the bridge and the place would
  then be one unit split across two domains
  ([design-usb.md](design-usb.md#interrupts)); such a board runs with
  neither the bridge nor its function, with the boot view's diagnostic.
  Giving the function no interrupt would not help, since units follow
  from the lines devices share, not from which lines are given.
* **At the give.** A function whose reported pin is not its place's is
  not given, with a log line naming both, since it could raise a line
  its unit does not hold: the platform record's pin is wrong, and the
  record is corrected from probe B4.
* **A listed place no row holds** has no holder; its function stays off
  with INTx disabled, and its line is held by no domain.
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
manifest's device row, 0 for none: a device address, exclusive, so the
function reaches device addresses below it. The cut range is the
function's DMA facts in its catalogue entry, CPU addresses `cpu`
through `last`, seen by the function from `bus`, with `last` the
highest CPU address whose device address lies below `dma_limit`, so a
bridge that translates keeps its offset and its lower bound. The
packer copies `dma_limit` from the bridge's unit in the platform record
into each `pci` row behind it. The fact is the bridge's: FreeBSD keeps
the bridge's DMA below `0x3c000000` in the bridge's own driver
(`bcm2838_pci.c:92-106`), where the tree allows 3 GiB (facts record,
section 2), and its VL805 driver calls even the 32-bit DMA "a limitation
of the PCI-e controller, not the VL805" (`bcm2838_xhci.c:191`). The Pi
4's platform record sets `0x3c000000` until the USB design's probe B5
shows the bridge's true limit.

The give makes the memory as it makes every unconfined device's, from
those facts: on the stopgap with `erx_mem_create_contiguous_in`
(`liberx/system/dom_apply.c:420-425`), on erXos's kernel with
`erx_mem_create_contiguous` inside the windows `erx_dma_ranges` gives
the function's resource, cut at the same limit
([design-kernel.md](design-kernel.md#dma-and-the-iommu)). So the
function's memory lies inside its reach by construction and no driver
has to remember it.

`dma_limit` limits what erXos allocates, not what the hardware lets the
function reach: the Pi 4's inbound window is larger, and an unconfined
function can write any memory the window covers. Only an IOMMU makes the
limit a boundary, for a confined function.

## Facets

Three interfaces, each a file of `abi/services/` whose first cited
section is this document's:

| Interface | Served by | Granted to | Operations |
| --- | --- | --- | --- |
| `pci_bus` | the system domain's device service | the PCIe domain alone | `targets() -> {ok, Bridges, Layouts, Settings}`; `report(Functions) -> {ok, Settings}`; `firmware(Bridge) -> ok` |
| `pci` | the system domain's device service | each configured domain that holds a `pci` device, its scope the devices it holds, as `device` parameters | `open(Place) -> ok`; `master(Place) -> ok`; `reset(Place) -> {ok, flr \| none}` |
| `pcie` | the PCIe domain | the system domain alone | `set(Place, Setting) -> ok`; `reset(Place) -> {ok, flr \| none}` |

Each answer of an error is `{error, Reason}`
([Refusals and error results](#refusals-and-error-results)). `Place` is
`{BridgePath, Bus, Device, Function}`, the function's place as its
manifest row and its given record name it; the device service matches
it against the rows the facet's grantee holds and never trusts it
otherwise. `firmware(Bridge)` names a bridge the PCIe domain holds; the
device service makes `erx_firmware_notify` through
`erx_domain_lib:pci_firmware(Bridge)`, with the resource the bridge's
device record holds for its give, which marks the bridge `firmware_lost`
at `ERX_ETIMEDOUT` ([Records](#records)), and answers `ok` for `ERX_OK`
and `{error, Status}` naming any other status, as
[design-usb.md](design-usb.md#the-vl805s-firmware) defines the call.

The directions follow from when each party can hold its facet. A facet
of a system-domain service reaches a grantee with its ready answer, before
`-run` starts its programs; a facet a configured domain serves is
installed whenever both parties are up
([design-system.md](design-system.md#facets-a-configured-domain-serves)).
So the PCIe domain and every holder call the system domain, and each has
its facet when its enumerator or driver starts; the system domain calls
`pcie` only once the PCIe domain's start has been answered, as below.

**The PCIe domain's start.** The enumerator calls `targets`, gets each
bridge's facts, its layouts and every setting, starts each bridge,
walks, places a bridge that has no layouts, applies to each function
the start's target of its layout and setting ([The plan](#the-plan)),
and calls `report` with every function it found, each its record and
whether the start kept it at its setting. It applies each setting the
answer carries, which changes only the functions whose setting changed
since `targets`, and then serves `pcie`.

**The answer to `report`.** The device service takes the report through
the library's intake ([The catalogue and
gives](#the-catalogue-and-gives)), lowers to `off` the setting of every
function the start turned off, and answers with every setting, but only
once the system domain holds the reporting incarnation's `pcie` facet.
The incarnation is the domain id `D` that the report's `{erx_origin, D,
Msg}` envelope names, written by the connection. The device service
waits with `erx_domain:await_grant(pcie, D)`, which the domain service
answers at the first step of the mint core at which the system domain's
grant of `pcie` has settled for that incarnation:

* `{ok, Facet}` when the grant is installed with `D` as its server;
* `{error, failed}` when the grant failed with `D` as its server;
* `{error, ended}` when `D` has ended, or the grant carries another
  server;
* `{error, unprovided}` when `D` is ready and the grant is idle, since
  `D` provides no `pcie` and the mint core arms no deadline for it
  (`erx_domain_mints.erl:412-413`).

The request is sent, not waited on, as `erx_domain:system_namespace/0`'s
is, so the device service's PCIe process goes on taking holders' ends
and requests while it waits; the domain service keeps the waiting
callers beside those of `system_namespace/0`, which keeps its own rule
over every `files` grant, and answers both after every step
(`erx_domain_srv.erl:1372`). An operation in progress is bounded by the
mint core's 10 s deadline (`erx_domain_mints.erl:113`), and `D` before
its ready report by its row's boot timeout. On `{ok, Facet}` the device
service records `D` as `answered` in each of the incarnation's bridges'
catalogue entries ([Records](#records)), then answers, and calls
`pcie` on `Facet` from then on, never on what `erx:cap/1` finds, which
can still be a dead incarnation's pid until its successor's is
installed (`erx.erl:143-148`). On any error it answers `{error,
unavailable}` and the enumerator exits, so the domain restarts. So every
change of a setting after the answer reaches that incarnation by
`pcie`, and every change before it is in the answer: no incarnation
serves from a stale view, and none misses a holder's end.

**The manifest.** The check proves property 3 as amended below, and
that only the PCIe domain holds `pci_bus`, only the system domain holds
`pcie`, and a domain holds a `pci` facet exactly when it holds a `pci`
device, its scope those devices, as property 8 proves the driver-control
facet's grantee from the interface.

## The catalogue and gives

**Intake.** On `report`, the device service hands the whole report to
the domain library, `erx_domain_lib:pci_report(Bridge, Functions)`, after
finding each function's manifest row, if any, by place and checking that
its identity is the row's compatible string, spelled `pci` and the
vendor and device id in four lowercase hexadecimal digits each,
`pci1b36,000d`, erXos's own spelling since no tree carries it. A
function no row names is logged as unlisted and stays off. The
library's intake, `erx_dom_pci_report`, is the boundary check of a
report. It decides every entry of the bridge from the whole report and
only then writes them all at once, so no order of processing can leave
an earlier state in place:

* **A bridge with no layouts** takes the report's layouts, a record
  without its `state`, only if every record passes: each placed BAR is
  aligned to its span and lies inside its bridge's window; no two spans
  overlap each other or any other entry's register ranges; an MSI-X
  table lies inside its BAR's hardware size. One record that fails
  refuses the report's layouts whole, with a log line naming the record
  and the field, and the bridge stays without layouts, so its next walk
  places again. Since those checks are the placement's own rules, a
  failure is a defect of the PCIe domain, and taking part of a placement
  would leave its root ports' windows derived from layouts the library
  does not hold.
* **A bridge with layouts** checks each record against its layout
  alone, which passed those checks when it was taken: a function is
  confirmed when its record, without its `state`, equals its layout; one
  the report does not list, or lists with another record, is
  unconfirmed; a function at a place with no layout is `unplaced`.
* **Every function's state** is the latest report's, so a function the
  latest report found `not_ready`, missing or changed is never given on
  the strength of an earlier report; on a bridge marked
  `firmware_lost`, every function is `not_ready` whatever the report
  says, so the VL805 a late firmware answer brought up after its
  notification timed out is never given in that boot, however many
  starts of the PCIe domain keep the bridge and report it ready.

**The give** of a `pci` device, `erx_dom_plan_unit_give`: a function
with no layout, not confirmed, or not `ready` gives nothing, as a device
the machine lacks, and its driver finds no record; so does one at a
closed bridge's place whose reported pin is not the place's, with a log
line naming both ([The closed bus](#the-closed-bus)). Otherwise one
register window per placed memory BAR, over its span, its CPU range the
BAR's PCI range translated by the bridge's window; the IRQ object of
[The choice](#the-choice); the DMA window, or the contiguous memory
inside the DMA range; and the given record, which names the function's
place, each BAR's window and hardware size, and for an MSI-X route the
doorbell, data, table BAR, offset and size. The setting's route is
written; the mode stays `off`.

**The hold at boot.** The domain service starts a configured row whose
units hold a `pci` device only once the device service has answered the
boot's first report, holding its start as it holds a start for a
principal's ending domain; rows without one start in boot order
meanwhile. The device service releases the hold at that answer, or when
the PCIe row ends or fails to report ready within its boot timeout, or
30 s after its ready answer, whichever is first; a row started after a
failed hold gets nothing of its `pci` devices. The check's boot order
puts the PCIe domain before every row holding a `pci` device.

**A holder's end.** The device service monitors the holder's domain pid
from its give; at its end it sets the setting's mode `off` in the
library and then calls `pcie:set`, or, with no PCIe incarnation
answered, leaves it to the next start's `targets` or `report`.

## Concurrency

**The enumerator** is one process: every configuration access, a walk, a
`set` and a `reset` run one at a time in it, so the BCM2711's index and
data are never interleaved and no two plans for a function race. The
device service sends nothing on `pcie` before it answers `report`, and
the enumerator serves `pcie` only after it has applied that answer.

**The device service's PCIe process** is one process that writes the
library's settings and calls `pcie`, so the settings the library holds
and those sent are written in one order. Its decisions are a pure core,
`erx_devices_pci_core`, a state machine over three states:

| State | Means | A holder's request | A holder's end |
| --- | --- | --- | --- |
| `between` | no PCIe incarnation's report has been answered since the last one ended | waits | the setting lowered in the library; nothing sent |
| `synced` | the current incarnation's report was answered | handled | the setting lowered, then sent |
| `down` | 5 s in `between` | `{error, unavailable}` at once | as in `between` |

The answer to a report moves it to `synced`; the end of the answered
incarnation, which it monitors, to `between`, and a request whose `pcie`
call failed because that incarnation ended waits again; 5 s in
`between`, past one restart's bring-up and walk, to `down`. A process
its supervisor restarts cannot learn from a facet's presence whether a
report was answered, since the grant is installed whether or not it
was, so it reads the bridges' `answered` from the library: when an
entry names the incarnation that the bridge's device record names as
its holder, it asks `erx_domain:await_grant(pcie, D)` for that
incarnation's facet and begins in `synced` with it, monitoring it, and
otherwise begins in `between`. The answer is written to the library
before it is sent, so a crash between the two leaves a report that the
library calls answered and the enumerator never received; the
enumerator's call fails with the process, the enumerator exits, and
the new process sees that incarnation end and goes to `between`.

Two orders keep the library from saying more than the function was
asked for: a lowering (a holder's end, the first step of its `reset`) is
written to the library before it is sent, and a raise (`open`,
`master`) after the enumerator's `ok`. So the library says `mastering`
only between an acknowledged `master` and the holder's end, and the
start's rule never keeps mastering for a holder that is gone. The
device service's call to `pcie` has a deadline of 2 s, past the longest
`reset` (1000 ms for pending transactions, 100 ms after the reset, and
the accesses); a timeout answers the holder `{error, unavailable}`, and
the request stays in the enumerator's queue, where it is applied in
order with everything the device service sends after it. A timeout
cancels nothing and proves nothing: the request may still be applied
after its answer, and a timed-out raise is not written to the library,
so the function may be decoding or mastering beyond what the library
says until the holder's end sends its lowering, which the enumerator
applies after it, or the next start turns it off, since it does not
read as its setting.

**When the PCIe domain stays down**, past its intensity, nothing can
write configuration space: a holder's end lowers the library's setting,
and a function its holder left mastering goes on mastering. Memory stays
safe without the PCIe domain: an unconfined function's memory is its
own for the boot, never given to anyone else, and a confined function's
window is deleted at its holder's end, which aborts its stream
([design-system.md](design-system.md#invariants), A9). The next holder
of the function gets `{error, unavailable}` for its `open`, so its NIF
posts nothing and maps nothing for the device. The same two facts, and
not the function's switches, keep memory safe from a function `stuck`
at a disable ([The plan](#the-plan)) and from the transactions a
function issued before its bus master was cleared, which no lowering
waits for.

## Failure handling and restart

| Failure | Detected by | What happens |
| --- | --- | --- |
| the enumerator crashes | its application ends | the PCIe domain ends and is restarted; the device service goes `between`; the new start keeps every function that reads as its setting and turns every other one off |
| the PCIe domain ends past its intensity | the domain service | it stays down; functions keep their state; holders' requests answer `{error, unavailable}` after 5 s ([Concurrency](#concurrency)) |
| a configuration access with the link down, on erXos's kernel | a synchronous abort, a fault of the PCIe domain's thread, or an SError presumed the running thread's ([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)) | the PCIe domain ends and is restarted; the BCM2711's start finds the link down and resets the bridge; every function below it that no longer reads as its setting is turned off with its layout |
| the same, on the stopgap | the access's second link read, since Fiasco's SError handler counts and returns (`fiasco/kernel/src/kern/arm/thread-jdb.cpp:96-106`) | the access answers `{error, link_down}`, and the enumerator exits at once, so the domain restarts as above |
| the link falls under a running function, seen by its holder | its driver's accesses abort, read all ones or time out | the holder's driver ends and starts again ([design-system.md](design-system.md#devices)); its `open` makes the enumerator access the fallen link, which ends the PCIe domain as above; the `open` waits in `between` and is applied after the restart |
| a plan cut short | the enumerator's end | the next start reads the prefix and keeps the function or turns it off ([The plan](#the-plan)) |
| a write that does not take | the stage's readback | no later stage; the function is lowered to quiet by `quiet/1`; `{error, gone}`; the entry stays as the latest report left it |
| a disable that does not take, in that lowering | its readback | the function is left as it reads, the field logged; `{error, stuck}`; memory stays safe as when the PCIe domain stays down ([Concurrency](#concurrency)); each later plan stops at its descent |
| a function reads absent or changed at a walk | the walk and the intake | it is not listed or listed with another identity; it is unconfirmed; its holder's requests answer `{error, gone}` |
| a function no longer reads as `decoding` at `master` | the planner | `{error, reset}`; the enumerator turns it off; the driver starts again with `open` |
| transactions still pending at a function-level reset | the enumerator's 1000 ms wait | no reset; the function stays off; `{error, busy}` |
| the VL805's firmware stays absent after the notification | `ready` | it is reported `not_ready`; a later start resets the bridge and asks again |
| the notification times out | `erx_domain_lib:pci_firmware/1` | the bridge's entry is marked `firmware_lost` in the same call; every later report of the bridge is taken as `not_ready`, so the VL805 is not given until the next boot, even when a late answer loads its firmware and a later start keeps the bridge; a later bring-up's notification answers `ERX_ETIMEDOUT` at once ([design-usb.md](design-usb.md#the-vl805s-firmware)) |
| a holder ends while the PCIe domain is down | the device service's monitor | the library's setting says `off`; the next start applies it |
| the device service's PCIe process crashes | its supervisor | it restarts, reads every setting, holder and `answered` from the library and monitors the holders again; it begins in `synced` only with an answered incarnation that still holds its bridges ([Concurrency](#concurrency)); a function whose holder has ended is set `off` |
| a placing walk's record fails intake | the library | the bridge takes no layouts and places again at its next walk; nothing on it is given; a log line names the record and the field |
| a later report's record differs from its layout | the library | its function is unconfirmed and not given; its holder's requests answer `{error, gone}` |

A **restart keeps** nothing in the PCIe domain and everything in the
library: the layouts, the settings and the confirmations. It **re-reads**
every function's snapshot and the bridges' link state.

A wedged function that no function-level reset recovers stays unusable
until a reset of its link or the next boot; on the Pi 4 only a PERST#
cycle resets the VL805 further, and the bridge keeps a link whose
firmware reads present, so its holder's restarts end at its bound.

**The two link reads are not proof.** An access made while the link
falls, the access faults, and the link comes back, all between the two
status reads, passes both. On erXos's kernel the fault ends the PCIe
domain whatever the reads say. On the stopgap the bus error is ignored,
so such an answer is taken: a read across it may give a wrong value,
which the walk's identity check and the plan's readback catch only where
it differs from what they expect, and a write across it may not have
been made, which the readback catches. That is a stopgap residual
([On the stopgap](#on-the-stopgap)).

## Refusals and error results

| Where | Result | When |
| --- | --- | --- |
| `pci:open`, `master`, `reset` | `{error, badarg}` | a malformed place or request |
| | `{error, not_held}` | a place the grantee's scope does not hold |
| | `{error, gone}` | the function is not confirmed, or the enumerator found it absent, changed, or not taking a write |
| | `{error, stuck}` | the enumerator found a write not taking and then a disable not taking; the function is left as it reads |
| | `{error, unavailable}` | no PCIe incarnation answered within 5 s, or its call timed out |
| | `{error, order}` | `master` while the library's mode is `off`, so before an `open` since the last lowering |
| | `{error, reset}` | `master` of a function that no longer reads as its `open` left it; it is turned off |
| | `{error, busy}` | `reset` with transactions still pending after 1000 ms; the function is left off |
| | `{error, route}` | the route does not fit the function |
| `pcie:set`, `reset` | `{error, gone}` | the function reads absent or changed, or a write did not take and the function then read quiet |
| | `{error, stuck}` | a write did not take, and the lowering after it left the function not quiet |
| | `{error, reset}` | a `mastering` setting for a function that does not read as it at `decoding` or `mastering` |
| | `{error, busy}` | a function-level reset with transactions still pending after 1000 ms |
| | `{error, route}` | the route does not fit the function: no such capability, or a doorbell beyond its MSI address width |
| | `{error, unknown}` | a place the enumerator has no layout for |
| `pci_bus:report` | `{ok, Settings}` | after intake, once the system domain holds the incarnation's `pcie`; refusals are per function, in the log and in `/dev` |
| | `{error, unavailable}` | `erx_domain:await_grant(pcie, D)` answered an error: the grant failed or missed the mint core's deadline, the incarnation ended, or it provides no `pcie` |
| `pci_bus:firmware` | `{error, Status}` | the kernel call's status other than `ERX_OK`, such as `ERX_ENOTSUP`, `ERX_ETIMEDOUT` or `ERX_EBUSY` |
| `erx_pcie_cfg:parse/1`, `size/2` | `{error, Field}` | the parser's refusals ([The walk](#the-walk), [Sizing](#sizing)); the function is reported `malformed` or `unplaced` |
| `erx_dom_pci_report` | `ERX_EINVAL`, the placing walk's layouts refused whole | a BAR outside its window, not aligned to its span, or overlapping another device; an MSI-X table past its BAR's hardware size |
| `erx_irq_create` of `ERX_IRQ_MSI` | `ERX_ELIMIT` | no free line of the frame, or the function past `ERX_MSI_MAX` |
| | `ERX_ENOMEM` | the stopgap root's IRQ slots are full |
| the give | refused, the creation with it | a doorbell the function's DMA range does not map one to one |
| | nothing given, as a device the machine lacks | a function with no layout, unconfirmed or not `ready`; at a closed bridge's place, a reported pin that is not the place's |
| the boot view | the bridge's unit and the place's refused | a closed bridge's `interrupt-map` routing a listed place's pin to a line other than its row's, or to one of the bridge's own lines |
| the manifest check | the build fails, naming the property | a second holder of a bridge's unit; a `pcie` domain holding another unit; a `pci` row with a line at a place no closed bridge lists; a closed bus's line given apart from its row; more line-less `pci` rows than the frame's lines; a `pci_bus`, `pcie` or `pci` facet granted against the rule above |

## On the stopgap

The PCIe domain, the enumerator, both bridge drivers, the device
service's PCIe process and the three facets are the same code on the
stopgap and on erXos's kernel. The stopgap adds `ERX_IRQ_MSI` over the
frame's lines ([The MSI frame on the stopgap](#the-msi-frame-on-the-stopgap))
and the give of a `pci` device in the root, as for any device another
domain holds ([design-stopgap.md](design-stopgap.md#device-records)): its
BAR windows with `erx_mem_create_physical`, its IRQ object, and its
contiguous memory with `erx_mem_create_contiguous_in` inside its DMA
facts. The VL805's notification runs in the root task, where the device
service runs. Its residuals:

* **No confinement.** The harness starts QEMU `virt` with no IOMMU on the
  stopgap and the Pi 4 has none, so every PCIe function is unconfined
  and its holder, with the PCIe domain, is in the trusted base.
* **No isolation between tasks.** The PCIe domain and the holders are
  apart by convention ([design-stopgap.md](design-stopgap.md#what-phase-1-code-must-not-assume)).
* **Bus errors are ignored.** Fiasco's SError handler returns, so an
  access over a fallen link completes with whatever the bus returned.
  The second link read keeps an answer made with the link down from
  being used, and turns it into the enumerator's exit; an answer made
  while the link fell and came back between the reads is taken
  ([Failure handling and restart](#failure-handling-and-restart)). A
  synchronous external abort takes Fiasco's user fault path, unverified
  for this kind.
* **The frame's range is a record**, not `MSI_TYPER`, and does not
  identify the writer.

## Verification

Each test below has a seeded failure that proves the code under test
ran; tests run where they are cheap, and the QEMU suite once per landing
that touches it.

### Host tests of the pure cores

| Test | Passing case | Seeded failure |
| --- | --- | --- |
| `erx_pcie_plan` | exhaustive over every switch state of the read value, every mode and route, each data field equal or differing, and each capability present or absent, run against a model of configuration space: the plan has no stage exactly when the function reads as the target; after each stage the model reads as the stage's state, and after the last as the target; every stage moves one way, each of its writes carrying every switch between its values at the stage's start and in its state; every data write happens while the model is quiet; every lowering precedes every raising; bus master is the first lowering and the last raising; a `mastering` target from anything but `decoding` or `mastering` is `{error, reset}`; after every prefix of every plan, the start's target from that state is the setting only if the state reads as it, and `off` otherwise | the floor taken as the lower of read and target even when data differ, the rule of writing only what differs: a mastering function with a wrong MSI address gets its address written with bus master on, and the quiet check fails; bus master raised before the live step: the order check fails; the mastering rule removed: a blank function's plan to `mastering` is accepted |
| `erx_pcie_apply`, over a model bridge driver | every plan of the planner's inputs, run once with each of its writes ignored alone, a later write of the same register then repeating it, and once with each register ignoring every write from one write on: no data write is made while the model is not quiet; no switch is raised while a data field of the model differs from the target; the answer is `ok` only when the model reads as the target, `{error, gone}` only when it reads quiet, and `{error, stuck}` otherwise; after a stage that did not take, the only writes are the descent to quiet | one readback after the last stage: with the memory-space disable ignored, a BAR is written while the model decodes and the quiet check fails, and the answer is `ok`; the descent to quiet taken as done without its readback: with the command register ignoring writes, the answer is `{error, gone}` while the model is not quiet |
| `erx_pcie_cfg` | snapshots of a type-0 and a type-1 header, MSI, MSI-X and Express capabilities, 32- and 64-bit BARs, decode to the expected values; each refusal of [The walk](#the-walk) has a fixture that is refused naming its field; sizing answers for each BAR kind give their hardware sizes, a non-contiguous mask is refused | the step bound removed: the looping fixture does not end within the test's deadline; the table BAR bound removed: the fixture with indicator 6 is accepted |
| `erx_pcie_place` | for generated sets of BARs, with and without root ports: every placed BAR inside the window, aligned to its span, no two spans overlapping, no two root ports' windows overlapping; the same set in any order gives the same addresses; a fixed set of a 4 KiB, a 64 KiB and a 1 MiB BAR gives the addresses written in the test | the alignment rounding dropped: the 64 KiB BAR lands at 4 KiB and both the alignment property and the fixed addresses fail |
| `erx_pcie_walk` | against a model configuration space, an open root bus with multifunction devices and a root port, and a BCM2711 model whose root port sets the multifunction bit and whose bus 1 has devices at listed and unlisted places: every function found, root ports numbered in place order, and the model records no hardware access at a place the bridge does not list | the BCM2711 access's place check removed: the model records an access at bus 0, function 1 |
| `erx_pcie_bcm2711_core` | the keep-or-reset table, exhaustive over link and firmware readings; bring-up's order and each deadline | PERST# asserted on the keep path: the test of a kept link sees a PERST# write |
| `erx_devices_pci_core` | exhaustive over its states and events: requests in `between` are answered only after a report's answer, or at `down`; a holder's end in `between` lowers the setting and sends nothing; a lowering is written before it is sent and a raise after its `ok`; the report's answer is withheld until `await_grant` answers the incarnation's facet, and `answered` is written before the answer is sent; a restarted process begins in `synced` only when `answered` names the incarnation holding its bridges, and in `between` when it names an ended one or none; the sequence `targets` with a mastering setting, the holder's end, `report` leaves the model's function off | the answer's settings dropped: that sequence leaves the function mastering after its holder's end; a raise written before its `ok`: after a failed `set` the library says `mastering`; the restart's state taken from the facet's presence: a restart after the grant was installed and before the report was answered begins in `synced` |
| `erx_dom_pci_report` (C, host) | a valid placing report is taken whole; a BAR outside the window, unaligned, overlapping another entry, an MSI-X table past its BAR's size, each refuses the placing report whole with `ERX_EINVAL`; at a later report, a changed record, a missing one and a `not_ready` one each leave the function ungiven although an earlier report confirmed it; on a bridge marked `firmware_lost`, a report listing the VL805 `ready` leaves it ungiven; `erx_dom_pci_firmware` over a backend whose call answers `ERX_ETIMEDOUT` marks the entry before it returns, and over one answering `ERX_OK` or `ERX_ENOTSUP` does not | the overlap check removed: the overlapping fixture is admitted; the earlier confirmation kept when a record is missing: the missing function stays given; the mark not read at intake: the VL805 reported ready after the timeout is given |
| `erx_domain:await_grant/2`, the domain service over its mint core | a wait for incarnation `D` is answered `{ok, Facet}` with `D`'s facet once installed, `{error, failed}` when its grant fails, `{error, ended}` when `D` ends or the grant moves to another server, and `{error, unprovided}` when `D` is ready without `pcie`; the service answers other calls while it waits; `system_namespace/0` still waits for every `files` grant | the wait matched by service alone: a wait for `D` is answered with its predecessor's installed facet; the idle case dropped: the wait for an incarnation that provides no `pcie` is never answered within the test's deadline |
| the stopgap's MSI line allocator (C, host) | lines from the range's first to its last, then `ERX_ELIMIT`; a freed line is taken again | the range's end off by one: the test's last allocation lies outside the range |

### Fuzz targets

Landing with their parsers, built for the host, run by `make check-fuzz`:
`erx_pcie_cfg:parse/1` over snapshots and their mutations, which must
never crash, and whose read values' offsets must lie inside the
snapshot; `erx_pcie_cfg:size/2` over sizing answers and their mutations;
and the library's intake, the generated C reader of `erx_pcie_function`
and `erx_dom_pci_report`, over whole reports and mutations that move
BARs across windows and onto each other, change table indicators, sizes
and offsets, and drop or duplicate records, which must never crash and
must take only layouts that satisfy every check a placing report must
pass.

### Build checks

The manifest check's seeded manifests, one per refusal of [Refusals and
error results](#refusals-and-error-results); the facet table's three
rows, each citing this document; the kinds table's rows for the two
bridges, with a seeded row whose peripheral has no SVD file; and a
check that `erx_pcie_apply` is the only caller of `erx_pcie_plan:plan/2`
and the only module that writes configuration space outside the walk's
sizing, with a seeded second writer.

### The `pcie` QEMU suite

A suite of its own, landing with the PCIe domain and before any USB
code, on QEMU `virt` with `qemu-xhci` attached, 1-CPU cells on HVF while
developing. QEMU's device names and properties used below are to be
confirmed against the pinned QEMU's documentation.

| Case | Checks | Seeded failure |
| --- | --- | --- |
| walk and report | the report's places, identities and BAR addresses equal QMP's `query-pci` answer, which the harness's QMP reader parses (its fields are to be confirmed against the pinned QEMU) | placement's alignment off by a page: QMP's region differs and the case fails |
| a test holder | a test domain holding `qemu-xhci` sends `open`, reads the capability length register through its window, sends `master`; the PCIe domain's inspection record shows the command register and MSI state | `open` not setting memory space: the register read returns all ones |
| a device-generated MSI | the test holder has the function raise its interrupt, by a command whose completion posts an event, and its IRQ object is delivered within the deadline | the MSI enable left out of the ascent: no delivery |
| restart | the PCIe domain killed while the test holder masters: after its restart the enumerator's count of writes to that function is zero and the holder's next register read succeeds | the planner taking every field as differing: the count is nonzero |
| restart behind a root port | the same with `qemu-xhci` behind a root port the harness attaches: the root port's write count is zero too | the root port sized at every walk: its count is nonzero and the holder's read fails |
| holder end | the test holder halts: the function's command register reads memory space and bus master clear | the device service's monitor dropped: the command still reads set |
| holder end during a PCIe start | the PCIe domain killed, then the test holder halted before the new report: after the start the function reads off | the report's answer carrying no settings: the function still masters |
| interrupted transitions | the PCIe domain killed repeatedly while the test holder loops `open` and `master`: after each restart the function reads either as the library's setting or off, never mastering with another route | the start's rule replaced by the plan to the setting: a restart raises a function |
| function-level reset | where `qemu-xhci` offers one, `reset` answers `{ok, flr}` and the function reads `decoding` with its layout; where it does not, `{ok, none}` | the plan to `decoding` after the reset left out: the function reads without its layout |
| MSI frame | on the stopgap, a test task writes a made object's data to its doorbell and the object is delivered; the first and last line of the record's range both deliver | the backend's data off by one: the bound object sees no delivery within the deadline |
| hold | the test holder's row starts only after the report's answer | the hold removed: the test holder's give finds no layout and its record is absent |

The refusal of a function-level reset with transactions pending cannot
be provoked in QEMU and is covered by the planner's model in the
enumerator's host tests.

### Board probes

On the Pi 4, by hand: the root's device-tree line for the bridge prints
its `ranges`, `dma-ranges` and `interrupt-map`; the enumerator's dump of
the VL805's snapshot gives its header type, BARs and pin, and the root
port's BARs (probe B4); the keep-or-reset decision is logged at each
start; the USB design's probes B1, B2, B5 and B8 settle the firmware,
the line, the DMA limit and the abort's kind.

## Changes to other designs

Made in their owning documents with this design:

| Document | Change |
| --- | --- |
| [design.md](design.md) | the index row; SD1's summary: MSI except on a closed bus |
| [design-shared-devices.md](design-shared-devices.md) | the closed bus's exception to "MSI only" in the decisions, the unit rule's line relation, the PCIe INTx paragraph and SD1; a closed bus is one whose platform record lists every place on it with its pin |
| [design-system.md](design-system.md) | property 3: the Pi 4 drives its bridge, and a `pci` row's line only at a closed bridge's listed place; the PCIe paragraph: the BCM2711's access, the layout and setting, the closed bus, the give enabling nothing, the holder's requests through `pci`, the restart's rule; Resets: a PCIe function's reset after its `open`, and `reset` through `pci`; Security: the enumerator's crash ends its domain |
| [design-platforms.md](design-platforms.md) | the Pi 4's PCIe bridge driven by the PCIe domain as a closed bus, in the platform table, the placement table, the Pi 4's section and PCIe bridges; the VL805 driven through the PCIe domain, its handover unknown, in the bus masters row; a PCIe function's DMA range cut at its `dma_limit`; the MSI frame's range on the stopgap |
| [design-usb.md](design-usb.md) | its sections on the PCIe domain, the BCM2711 bridge, the Pi 4's interrupt and the Phase 1 part, and its VL805 firmware section, cite this design for what they share: the give programs no MSI and enables nothing, `open` and `master` do; the BCM2711's access refuses every place its platform record does not list; the notification is `pci_bus:firmware/1`, which the device service makes through `erx_domain_lib:pci_firmware/1`; a VL805 whose firmware stays absent is reported `not_ready` and stays out of the catalogue until a later start of the PCIe domain finds it loaded, which after a timed-out notification is the next boot, by the bridge's `firmware_lost` in the library, which the device service's call marks and the intake reads, so no keep of the bridge at a later start admits it; its contiguous memory is made from its DMA facts with `erx_mem_create_contiguous_in`, not with a limit passed to `erx_mem_create_contiguous` |
| [design-stopgap.md](design-stopgap.md) | property 3's Phase 1 row: one `pcie` domain on QEMU `virt` and the Pi 4 |
| [design-abi.md](design-abi.md) | a `pci` row's `line` at a closed bridge's listed place |
| [design-kernel.md](design-kernel.md) | `ERX_IRQ_MSI`: the enumerator writes an MSI route, the holder's NIF an MSI-X table; `erx_dma_ranges` reads a PCI host bridge's three-cell `dma-ranges` |
| [design-device-tree.md](design-device-tree.md) | the reader takes a PCI host bridge's three-cell `dma-ranges`, and its fixture translates a function through them |

Required of other documents, each their own revision:

| Document | Change |
| --- | --- |
| [design-device-tree.md](design-device-tree.md) | the reader takes a PCI host bridge's three-cell `ranges`, its `bus-range` and its `interrupt-map` by pin, with fuzz seeds; the DMA facts of a `pci` row cut at its `dma_limit` |
| `abi/manifest.txt`, [design-abi.md](design-abi.md) | `dma_limit` in `erx_mf_device`, a device address, exclusive; the closed flag on a bridge's row and its listed places and pins; the manifest's `msi_frame` platform part on QEMU `virt`; the `dt` case's `base`, `size` and `line` made inactive for selector 2 except `line` at a closed bridge's place (the `TODO.md` item) |
| [design-stopgap.md](design-stopgap.md) | `ERX_IRQ_MSI` over the frame's lines; the given record of a PCIe function (its place, a window per BAR with its hardware size, an MSI-X route's doorbell and table); the give in the root |
| [design-runtime.md](design-runtime.md#the-device-nif) | the NIF writes every MSI-X table entry from its record, entry 0 live and the rest masked, and reads entry 0 back; it opens a record with several BAR windows |
| [design-hardware-generation.md](design-hardware-generation.md) | SVD files for the ECAM window and the BCM2711 bridge whose configuration-space views take 8-, 16- and 32-bit accesses at a computed offset, bounded by the window |
| [design-system.md](design-system.md) | the device service's PCIe process, its core and its monitors; the hold of `pci` rows at boot; `/dev`'s PCIe fields; `erx_domain:await_grant/2`, the wait for a configured grant to the system domain bound to the server's incarnation ([Facets](#facets)), answered beside `erx_domain:system_namespace/0`'s callers |
| `include/erx/device_kinds.h` | rows `pci_ecam` (`pci-host-ecam-generic`) and `bcm2711_pcie` (`brcm,bcm2711-pcie`), role `configuration` |

## Alternatives considered

* **Write only the fields that differ, in a fixed order.** It writes
  nothing to a running function, but a mastering function with the
  right command register and a wrong BAR or MSI address gets that
  address written with bus mastering on, since no switch differs; and
  writing every disable unconditionally breaks the restart's promise of
  no writes. The planner's floor removes both.
* **Restore the holder's setting after any reset.** The projection would
  bring a reset function back to `mastering` before its holder has set
  up anything outside configuration space, its MSI-X table and its
  controller among them. Turning it off and letting the holder start
  again uses the restart the holder has anyway.
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
  disturbs; keeping the layouts in the library makes the restart a
  plan.
* **Re-enumerate from scratch at every start.** Deterministic placement
  would reproduce the addresses, but sizing a running function or root
  port turns its decoding off under its driver.
* **Keep a valid BAR firmware assigned.** It serves RP1, which this
  design does not reach, and makes a second placement problem, kept
  BARs whose root ports' windows must still enclose and avoid each
  other, for no consumer here.
* **A 64-bit window and prefetchable placement.** No consumer's BAR needs
  them; a BAR that does not fit is unplaced, not misplaced.
* **A general walk over switches.** No platform has one; a second bridge
  level is reported `unsupported`.
* **INTx with a line owner across domains.** It needs the kernel to fan
  one line out to several untrusting holders, the mechanism the unit rule
  exists to avoid; the closed bus removes the need where INTx is used.
* **The BCM2711's MSI decoder for the VL805.** Its register page is the
  bridge's, which the PCIe domain holds; another domain could not clear a
  vector without a new mechanism.
* **One facet in each direction between the device service and the PCIe
  domain**, the device service starting each incarnation with a
  `pcie:start`. It would order every setting through one sender, but
  the PCIe domain still needs the device service for the firmware
  notification, so `pci_bus` stays, and the answer to `report` gives the
  same order.
* **Resend missed settings by polling or retrying.** A setting that
  could not reach an incarnation would need a queue and a trigger to
  resend it; withholding the answer to `report` until the incarnation's
  `pcie` is held leaves nothing to resend.
* **Ask at each start whether a notification timed out.** It needs a
  kernel query, or a notification resent to learn the answer, for a
  fact the one call that meets the timeout can write into the library.
* **The DMA limit on the function's kind.** FreeBSD names it the
  bridge's, so the platform record states it once, at the bridge.
* **Pass a ceiling to `erx_mem_create_contiguous`.** A ceiling alone
  describes an identity range from 0, and loses a translating bridge's
  offset and lower bound; the cut range as the function's DMA facts
  goes through the create every device's give already uses.

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
[design-domains.md](design-domains.md#facets),
[design-usb.md](design-usb.md), Fiasco's ICU interface
(`fiasco/l4re-core/l4sys/include/icu.h`).
