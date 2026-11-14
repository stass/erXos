# USB: host controllers, HID and mass storage

This document is erXos's USB host stack: which domain holds a USB host
controller, how the USB core in that domain finds, configures and serves
the devices behind it, the drivers of the host controllers erXos meets
first (xHCI, as QEMU `virt`'s `qemu-xhci` and the Raspberry Pi 4's VL805,
and DWC2, as QEMU `raspi4b`'s model), the HID and mass-storage class
drivers, and how what they produce reaches the display's input router and
the storage domains' file servers. It refines the drivers and devices of
[design-system.md](design-system.md#drivers), the device NIF of
[design-runtime.md](design-runtime.md#the-device-nif), the descriptor forms
of [design-device-dma.md](design-device-dma.md#the-three-descriptor-forms),
the input records of [design-display.md](design-display.md#input-events)
and the block service of [design-storage.md](design-storage.md#data-model),
and says where each of them changes.

Decisions every reader needs:

* **Hotplug ends at the controller's domain.** A USB device lives, from
  its attach to its detach, inside the domain that holds its host
  controller, as a sub-device of the controller's unit
  ([design-system.md](design-system.md#drivers), Units). What crosses a
  domain boundary is fixed by the system manifest and outlives every
  device: a fixed set of **input numbers**, each a file of input records
  the display reads, and a fixed set of **drives**, each a grant through
  which a storage domain's file server reaches whatever medium the drive
  holds. A device's arrival or departure changes what an input number or
  a drive carries, never which grants exist, so no domain but the
  controller's ever learns that a device came or went except through the
  data it reads.
* **A place outlives its occupant; a handle dies with it.** A HID
  function takes the lowest free input number and gives it back with a
  `release` record, which the input router already reads as "every key
  this source held is up". A mass-storage medium takes the lowest free
  drive, and the windows through which its sectors are read are processes
  that end with the medium, so a file server that mounted one medium can
  never write to the next one. Inside the domain, every transfer names
  its device through a handle that dies with the device, so a stale
  request never reaches the device that took its slot.
* **One owner, one pure step.** The controller process owns the
  controller, the bus process owns the topology (ports, hubs and each
  device's enumeration), and each function process owns one interface of
  one device. Each decides by a pure function of its state and an event
  and performs the actions it returns; the bus core, the xHCI queue core
  and the BOT core are protocol state machines, explored exhaustively on
  the host.
* **FreeBSD's decisions, translated; not its structure.** The order and
  timing of enumeration, hub and root-hub handling, xHCI's command and
  event handling, HID's item parser and its bounds, the usage-to-evdev
  table, BOT's transfer states and CSW checks and the disk's handling of
  a refused SYNCHRONIZE CACHE come from FreeBSD at `release/15.1.0-p6`
  (`95719d8a895bf8170851e9844d9b4092b1d2b6fe`), and each Erlang function
  that translates one names the FreeBSD function it comes from. FreeBSD's
  per-bus threads, busdma, `ugen`, device mode, isochronous transfers,
  CAM and its quirk tables are not translated.
* **xHCI is a fourth descriptor form of the device NIF.** Its transfer,
  command and event rings, its device and input contexts and its
  scratchpad are memory the NIF lays out once and owns, and every address
  in a TRB, a context or a register is the NIF's; Erlang chooses
  requests and parses what the controller wrote. DWC2 runs by programmed
  I/O through its FIFOs, with its DMA held off by the NIF, so it needs no
  form.
* **The SCSI subset leaves most quirks nothing to fix.** The
  mass-storage transport sends INQUIRY, TEST UNIT READY, REQUEST SENSE,
  READ CAPACITY, READ, WRITE and SYNCHRONIZE CACHE and nothing else, so
  the commands several of FreeBSD's `umass` and `da` quirks exist to
  avoid are never sent, and a refused SYNCHRONIZE CACHE is handled as
  FreeBSD handles it, from the sense data. No quirk table is kept until a
  device needs one.
* **The first controller is the one the stopgap can reach.** DWC2 on
  QEMU's `raspi4b` needs no PCIe and no MSI, so the USB core, HID and
  mass storage run on the stopgap first; xHCI on QEMU `virt` follows the
  PCIe domain and its MSIs, and the Pi 4's VL805 follows a driver for the
  Pi 4's PCIe bridge. The order is a proposal of
  [plan.md](plan.md#track-u-usb-proposed).

## Contents

* [Context](#context): what is matched, the hardware, what the tree
  offers today, the sources
* [Requirements](#requirements)
* [The construction](#the-construction): places and handles, owners and
  steps, every port a hub port, what disappears
* [Domains and authority](#domains-and-authority)
* [The USB core](#the-usb-core)
* [Host controllers](#host-controllers): xHCI, the TRB ring form, the
  VL805, DWC2
* [HID](#hid)
* [Mass storage](#mass-storage)
* [The PCIe dependency and the order of work](#the-pcie-dependency-and-the-order-of-work)
* [On the stopgap](#on-the-stopgap)
* [Changes to other designs](#changes-to-other-designs)
* [Concurrency](#concurrency), [Failure handling](#failure-handling),
  [Refusals and error results](#refusals-and-error-results)
* [Verification](#verification)
* [Performance](#performance), [Alternatives considered](#alternatives-considered),
  [Open decisions](#open-decisions), [The research questions](#the-research-questions),
  [References](#references)

## Context

### What is matched

erXos follows FreeBSD where UNIX systems differ, and its USB host stack
behaves like FreeBSD 15.1's for the devices in scope: a keyboard, a mouse
or a tablet types and points as it does under FreeBSD's `usbhid` and
`hkbd`, and a USB stick reads and writes as under `umass` and `da`. The
evidence each part rests on:

* **Enumeration and hubs.** FreeBSD's `uhub_reattach_port`
  (`sys/dev/usb/usb_hub.c:599-860`) waits for the port's power-up time,
  resets the port, reads its status again, retries once when the device
  vanished during the reset, takes the speed from the status, and calls
  `usb_alloc_device` (`usb_device.c:1752`), which sets the address
  (`:1908`), reads the device descriptor (`:1950`), sets the
  configuration (`:2019`) and attaches interface drivers
  (`usb_probe_and_attach`, `:1456`); on any failure it frees the device
  and disables the port, which stays disabled until its connection
  changes (`usb_hub.c:820-839`). Its timing constants allow for marginal
  devices: a 300 ms power-up delay, a 200 ms root-port reset, 20 ms of
  reset recovery and a 10 ms settle after SET_ADDRESS, against the
  specification's 100, 50, 10 and 2 ms (`usb.h:104-120`). A request
  times out after 5 s (`USB_DEFAULT_TIMEOUT`, `usbdi.h:88`). Hubs nest at
  most five deep (`USB_HUB_MAX_DEPTH`, `usb_freebsd.h:90`), which is also
  what the 20-bit route string of an xHCI slot context holds, four bits a
  tier (`XHCI_SCTX_0_ROUTE_SET`, `xhci.h:76`).
* **Descriptors.** A configuration descriptor's `wTotalLength` must be at
  least its header (`usb_request.c:1294`); each descriptor of the walk,
  and the one after it, must lie inside that length, and a `bLength`
  below 3 ends the walk (`usb_desc_foreach`, `usb_parse.c:73-110`).
* **xHCI.** FreeBSD's event loop walks the event ring by its cycle bit,
  stops after the ring has wrapped twice, and writes the dequeue pointer
  back with the busy bit (`xhci_interrupt_poll`, `xhci.c:1115-1200`). A
  transfer event's slot and endpoint numbers are range-checked and its
  TRB pointer matched against each pending transfer's TRBs before the
  residue is trusted (`xhci_check_transfer`, `xhci.c:960-1040`). Commands
  run one at a time with a timeout (`xhci_do_command`, `xhci.c:1202`).
  A transfer ring holds at most four transfers (`XHCI_MAX_TRANSFERS`,
  `xhci.h:38`). Clearing a halted endpoint resets the host's side first,
  then sends CLEAR_FEATURE(ENDPOINT_HALT) to the device
  (`usbd_clear_stall_callback`, `usb_transfer.c:3355-3400`). Intel's xHCI
  specification could not be fetched (HTTP 403), so FreeBSD's
  `xhcireg.h`, `xhci.h` and `xhci.c` are the reference, and the
  statements below that only the specification settles are marked
  unverified.
* **HID.** HID 1.11 defines the boot interface (subclass 1, protocol 1
  keyboard, 2 mouse; section 4.3), the class requests (section 7.2), the
  rule that the host sets the protocol it wants whenever it initialises
  a device (section 7.2.6), and the boot reports (Appendix B): the boot
  mouse reports buttons and **relative** X and Y only (Appendix B.2), so
  an absolute pointer such as QEMU's `usb-tablet` needs the report
  descriptor. A keyboard reports the keys held, not their edges, and
  reports ErrorRollOver in every array field when more keys are held than
  it can report (Appendix C). FreeBSD's item parser bounds a descriptor's
  usages to 64, its push depth to 4, its report ids to 16 and a field's
  count to 2048 (`hid.c:66-69`), and refuses a push beyond the depth
  (`hid.c:446-449`). FreeBSD maps a keyboard usage to an evdev key through
  one table of 256 entries (`evdev_usb_scancodes`, `evdev_utils.c:44`;
  `evdev_hid2key`, `:221`).
* **Mass storage.** The Mass Storage Specification Overview 1.4 assigns
  subclass 06h to the SCSI transparent command set and protocol 50h to
  Bulk-Only Transport, and discourages CBI for new designs (Tables 1 and
  2). BOT 1.0 fixes the CBW (31 bytes, signature 43425355h) and the CSW
  (13 bytes, signature 53425355h, the CBW's tag copied), the two class
  requests (Bulk-Only Mass Storage Reset, FFh; Get Max LUN, FEh), the
  status flow (read the CSW; on a STALL clear it and read once more;
  section 5.3.3, Figure 2), what makes a CSW valid (13 bytes, signature,
  tag; section 6.3.1) and meaningful (status 0 or 1 with a residue no
  larger than the transfer length, or status 2; section 6.3.2), and
  Reset Recovery: the reset, then CLEAR_FEATURE(HALT) to bulk-in, then
  to bulk-out (section 5.3.4), after a phase error or an invalid CSW
  (sections 5.3.3.1 and 6.5). FreeBSD's BOT is a nine-state transfer
  machine (`umass.c:185-194`) and its CSW checks follow the
  specification (`umass.c:1530-1610`). FreeBSD's disk driver polls a
  removable medium every 3 s (`DA_DEFAULT_POLL_PERIOD`,
  `scsi_da.c:1561`, `:3060-3065`), and when a device refuses
  SYNCHRONIZE CACHE with ILLEGAL REQUEST it reports that flush done and
  sends no more (`daerror`, `scsi_da.c:6249-6254`; `cmd6workaround`,
  `:4448-4457`).

### The hardware

**QEMU `virt`.** Its USB host controllers are all PCI functions: `-device
help` lists `qemu-xhci`, `nec-usb-xhci`, `usb-ehci`, the ICH9 and PIIX
UHCIs and `pci-ohci`, and no memory-mapped one (probe of the facts
record, QEMU 11.1.3). `qemu-xhci` is PCI `1b36:000d` with one 64-bit
memory BAR, MSI and MSI-X, four USB 2 and four USB 3 ports; QEMU's
documentation calls xHCI "the only controller you need"
(`docs/system/devices/usb.rst:12-26`). With `usb-kbd`, `usb-tablet` and
`usb-storage` attached, the keyboard and the tablet enumerate at 480 Mb/s
and the stick at 5000 Mb/s. Its capability registers (slot, interrupter,
scratchpad and port counts, `AC64`) are not documented and are read at
run time.

**QEMU `raspi4b`.** The model implements the "USB2 host controller (DWC2
and MPHI)" and lacks the PCIe root port
(`docs/system/arm/raspi.rst:30-45`), so the Pi 4's own USB-A path cannot
run under QEMU. The DWC2 sits at `0xfe980000`, 0x11000 bytes, its
registers in the first page and its channel FIFOs after them, with one
interrupt; QEMU puts a full-speed hub on its port and attaches
`usb-kbd` and `usb-tablet` behind it at 12 Mb/s (probe).

**The Raspberry Pi 4.** Its two USB 3 and two USB 2 ports are a VL805
xHCI controller, and the USB 2 lines of all four pass through one USB 2
hub inside it (Raspberry Pi documentation,
`usb-bus-on-raspberry-pi.adoc:34`), so a low- or full-speed keyboard
always sits behind a high-speed hub's transaction translator. The VL805
is a PCIe function at bus 1, device 0, function 0 behind the BCM2711's
PCIe bridge, `0x34831106`, which FreeBSD accepts only at that position
behind a `brcm,bcm2711` bridge (`bcm2838_xhci.c:81-104`). On newer boards
it cannot load its own firmware: the VideoCore loads it on the firmware
mailbox's `NOTIFY_XHCI_RESET` (tag `0x00030058`, one word, the function's
address as bus, slot and function), sent after the bridge is up, and
configuration register `0x50` reads 0 or all ones until it has
(`bcm2838_xhci.c:22-27`, `:69`, `:138-175`;
`bcm2835_mbox_prop.h:110-126`). Its DMA is 32-bit, "a limitation of the
PCI-e controller, not the VL805" (`bcm2838_xhci.c:191-192`), and FreeBSD
keeps PCIe DMA below 960 MiB because it saw corruption above
(`bcm2838_pci.c:92-106`). Only the kernel reaches the mailbox, since any
code that can reach it can read the board's device key
([design-platforms.md](design-platforms.md#device-secrets), PL2). The
Pi 4's older USB 2 controller, a DWC2, is on the USB-C power connector,
disabled and in device mode by default
(`usb-bus-on-raspberry-pi.adoc:36`; `config_txt/boot.adoc`, `otg_mode`),
and `otg_mode=1` puts "a more capable XHCI USB 2.0 controller" on that
connector instead (`config_txt/boot.adoc`). The BCM2711 has no IOMMU
([design-platforms.md](design-platforms.md#dma)).

**The stopgap.** On Fiasco, `ERX_IRQ_MSI` is `ERX_ENOTSUP`
(`liberx/backend/fiasco/irq.c:188-190`; MSIs are among what [Phase 1
defers](design-stopgap.md#what-phase-1-defers) to M9's kernel part), and QEMU `virt`
drives no PCIe bridge in Phase 1 (property 3 of [the Phase 1 manifest
check](design-stopgap.md#the-phase-1-manifest-check), whole again at
M9). A PCI host controller therefore has no domain and no interrupt on
the stopgap, while QEMU `raspi4b`'s DWC2 is memory-mapped with a wired
line.

### What the tree does today

No USB code or design exists. The plan lists "Graphics, USB, audio" as
not planned ([plan.md](plan.md#beyond-the-plan)); the Pi has "no USB
keyboard, since the Pi 4's USB host sits behind the PCIe bridge no domain
drives" ([plan.md](plan.md#1b-i-the-raspberry-pi-4-on-the-stopgap)); the
platform table's USB row is "none" for the Pi 4
([design-platforms.md](design-platforms.md#overview)); and whether a
PCIe domain drives the Pi 4's bridge is an open item of `TODO.md`. QEMU's
harness attaches virtio-input, not USB (`tools/lib/erx/qemu.rb`).

What the design reuses:

* drivers as supervised Erlang processes over the device NIF, registers
  by name from CMSIS-SVD files, and interrupts as messages
  ([design-system.md](design-system.md#drivers));
* the device NIF's queues, posting and completion, and its rule that the
  NIF writes every address and parses nothing a device wrote
  ([design-runtime.md](design-runtime.md#the-device-nif)), with the
  granule handoffs of [design-device-dma.md](design-device-dma.md);
* the input records and the router, and the file of records another
  domain serves the display
  ([design-display.md](design-display.md#the-display-device));
* the block transport contract, the write path and its trial rule (U4),
  the block service's windows, the removable-media rule and the FAT
  server ([design-storage.md](design-storage.md));
* the unit rule, by which a sub-device never crosses a domain
  ([design-system.md](design-system.md#drivers), Units), and the three
  homes of a new need: an inspection path, a file tree, a declared
  protocol ([design.md](design.md#decisions)).

What it lacks, and this design adds or asks of another design:

| Gap | Where it is filled |
| --- | --- |
| no descriptor form drives xHCI's rings, contexts or scratchpad | [The TRB ring form](#the-trb-ring-form) |
| a register's offset is fixed per peripheral, while xHCI's operational, runtime and doorbell registers sit at offsets the controller reports | [Registers at offsets the controller reports](#registers-at-offsets-the-controller-reports) |
| `region/3` is `enotsup` on a device that is not coherent | not needed: every xHCI structure is either posted or laid out at install ([The TRB ring form](#the-trb-ring-form)) |
| no device is added at run time; the catalogue holds manifest devices only | not needed: USB devices never enter the catalogue ([Hotplug ends at the controller's domain](#hotplug-ends-at-the-controllers-domain)) |
| no `usb` device role in the manifest; a window names a block device only | [Changes to other designs](#changes-to-other-designs) |
| a storage domain holds one block device, and the transport is the registered `erx_blk` | each medium runs its own transport under the controller's domain ([Media and drives](#media-and-drives)) |
| no medium arrival or change anywhere | [Media and drives](#media-and-drives) |
| the binary form of input records is declared but not yet in `abi/formats/input.txt` | a dependency, tracked in `TODO.md` ("Input from another domain") |
| no PCIe bridge driver on the Pi 4; no PCIe and no MSI on the stopgap | [The PCIe dependency](#the-pcie-dependency-and-the-order-of-work) |

### Sources

FreeBSD's source at `release/15.1.0-p6`
(`95719d8a895bf8170851e9844d9b4092b1d2b6fe`), from
`https://git.freebsd.org/src.git`: `sys/dev/usb` (the core, `controller/`,
`storage/umass.c`, `input/usbhid.c`), `sys/dev/hid`,
`sys/dev/evdev/evdev_utils.c`, `sys/cam/scsi` and
`sys/arm/broadcom/bcm2835`, each file with its SHA-256 in
[References](#references). The usb.org class specifications (HID 1.11,
HID Usage Tables 1.5, Mass Storage Bulk-Only Transport 1.0, Mass Storage
Specification Overview 1.4), QEMU 11.1.3's documentation and the
Raspberry Pi documentation and firmware wiki at the commits listed there.
No GPL source was read: not Linux, not QEMU's C, not U-Boot, not Linux's
device trees. A fact that only such a source holds, the Pi 4's PCIe
bridge bring-up, its device-tree nodes and the DWC2 node's properties
among them, waits for a clean-room facts record written by a separate
agent, and is marked so where it matters.

## Requirements

* **R1. Devices.** A USB keyboard, a relative mouse and an absolute
  tablet reach the display's input router as records; a USB mass-storage
  device of the SCSI transparent command set over Bulk-Only Transport
  reaches a FAT server as a medium. Hubs, USB 2 high-speed hubs with
  their transaction translators included, connect them.
* **R2. Controllers.** xHCI on QEMU `virt` (`qemu-xhci`) and on the
  Raspberry Pi 4 (the VL805); DWC2 in host mode on QEMU `raspi4b`.
* **R3. Hotplug.** A device attaches and detaches at any time, on any
  port, at any depth, without restarting anything outside its
  controller's domain.
* **R4. Containment.** A device that misbehaves, by its descriptors, its
  reports, its status blocks, its timing or its absence, takes down at
  most its own function, then its own port, and never another device or
  another domain. Only a fault of the controller itself, a command it
  never completes or an event the NIF refuses, resets the controller and
  with it every device behind it.
* **R5. Untrusted input.** Every byte a USB device returns and every
  word the controller writes is parsed in Erlang by binary matching with
  checked bounds, with a fuzz target landing with each parser; the NIF
  reads only what it must check to keep its own memory safe.
* **R6. Bounded cost.** What a device can make the domain spend, in
  memory, processes, controller slots, queue entries and time, is bounded
  by constants fixed before the device arrives.
* **R7. No new cross-domain mechanism.** HID reaches the display and
  media reach the file servers through mechanisms the design documents
  already have; what changes in them is named here.
* **R8. Authority.** Which domain drives which controller, and which
  domains receive its input and its media, is the system manifest's and
  nothing else's.
* **R9. Phases.** The stack runs on the stopgap as far as the stopgap
  reaches, and every guarantee it cannot keep there is a recorded
  residual.

## The construction

### Hotplug ends at the controller's domain

A USB device is a sub-device of its host controller's unit: its
registers are the controller's, its interrupts arrive on the controller's
line, and it is reached only through transfers the controller runs. The
unit rule already says that a sub-device never crosses a domain as
registers or a line, and that another domain reaches what it does only
through a file tree or a facet its holder serves
([design-system.md](design-system.md#drivers), Units). This design adds
no exception: no USB device enters the device catalogue, is named in the
manifest, or is given to a domain. Everything about a device, from the
port's connect to the slot's release, happens in the domain that holds
the controller.

What other domains see is a set of **places**, fixed when the domains
are configured and lasting as long as the controller's domain:

* an **input number**, `hid0` to `hid7`, a file of input records in the
  binary form of `abi/formats/input.txt`, served in the controller's
  domain's input tree, which the manifest grants a display domain read
  only ([design-display.md](design-display.md#the-display-device));
* a **drive**, `da0` to `da3`, named by the manifest's window rows on the
  controller's device, through whose **drive grants** a FAT server's
  domain asks for the window of one partition of whatever medium the
  drive holds.

A device's function **occupies** a place: a HID interface takes the
lowest free input number when its function starts, and a mass-storage
logical unit's medium takes the lowest free drive the manifest names
when it becomes ready. When the function or the medium ends, the place is
free again. Places are the only thing a reader outside the domain holds,
so the reader's grants are made once, at its domain's creation, by the
mechanisms that already make them, and no run-time device addition, no
arrival message and no new facet is needed.

What a place promises its reader, by construction:

* **Input.** Each input number carries one function's records at a time.
  When the function ends, for any reason, its number's file carries
  `release` before any record of the next occupant, and the router,
  which keeps what each source holds, takes every key, button and touch
  of that source up ([design-display.md](design-display.md#input-events)).
  The router's own per-source bookkeeping does the work; the controller's
  domain keeps no copy of it.
* **Media.** A window, the process that serves one partition of one
  medium, is started when the medium becomes ready and ends when the
  medium ends. A file server that mounted the medium holds that window's
  pid; once the medium is gone, every request to that pid fails, and the
  next medium in the drive has windows of its own, reachable only by
  asking the drive grant again. So a file server's cached blocks of one medium
  can never be written to another, which the alternative, a window that
  stays and changes media beneath it, could prevent only by every caller
  carrying the medium's identity in every request.

### Handles that die with the device

Inside the domain the same rule holds one level down. An xHCI slot
number, a DWC2 device address and a hub port are reused as devices come
and go. A function process therefore never names its device by any of
them: the bus process gives each attached device a fresh reference at
attach, and every transfer a function submits names a **pipe**,
`{Device, Endpoint}`, with that reference. The controller process holds
the map from a live device's reference to its slot or address and looks
every pipe up through it, so a request through a pipe of a detached
device answers `{error, gone}`, whatever device now has its slot. It is
the kernel's generation check on capabilities applied to USB: a stale
name never names a new object.

### One owner, one step

Three kinds of process own all of the stack's state in a controller's
domain, each deciding by a pure step and performing the actions it
returns, as the network stack's owners do
([design-network-stack.md](design-network-stack.md#one-owner-one-step)):

| Owner | Its state | Its pure core | Effects it performs |
| --- | --- | --- | --- |
| the **controller process**, one per host controller | the controller: its device record, its slots or device addresses, the pipes in flight and their requesters, the root hub's ports | `erx_xhci_core` or `erx_dwc2_core` | device NIF calls, register reads and writes, interrupt acknowledgement, replies to requesters |
| the **bus process**, one per controller | the topology: every hub's ports, every device's enumeration and its functions, the places each occupies | `erx_usb_bus_core` | port requests, control transfers, starting and stopping function processes, place assignments |
| a **function process**, one per claimed interface | one interface: a HID report layout and fold, a hub's status pipe, a BOT engine and its logical units | `erx_hid_core`, `erx_usb_hub_core`, `erx_usb_bot_core` | transfers on its pipes, records into its input number, media into drives |

Every timer is a deadline in the owner's state, and the step answers the
next deadline among its actions, as the network stack's owners do
([design-network-stack.md](design-network-stack.md#deadlines-not-timers)).

### Every port is a hub port

The bus core knows one kind of port, a hub's, and one set of port
operations: read the status, reset, clear a change, power on and off.
The root hub is answered by the controller process, which translates
each operation into the controller's port registers, as FreeBSD's
controller drivers emulate a root hub for `uhub`
(`xhci_roothub_exec` in `xhci.c`); an external hub's operations are hub
class requests on its control pipe. So connecting a device to a root port
and to the third port of a hub two tiers down runs the same states, and
the only difference the bus core sees is the route it hands the
controller when it addresses the device.

### What disappears

| Case that would need handling | Why it cannot arise |
| --- | --- |
| a domain must learn that a device arrived | nothing outside the controller's domain names a device; its places exist from the start |
| a new device needs a grant at run time | places are granted at configuration; a device occupies one |
| a reader of a removed keyboard keeps keys held | the function's end writes `release` into its input number before the next occupant |
| a file server writes one medium's cached blocks to the next | the window it holds ended with the first medium |
| a request reaches the device that reused a slot | pipes carry the device's reference, which the controller's map no longer holds |
| root ports and hub ports need two enumeration paths | the controller answers root-hub operations as a hub would |
| the event ring overflows | the TRB form's queue blocks hold fewer transfers than the event ring has entries ([The TRB ring form](#the-trb-ring-form)) |
| a device crafts a CSW for another command | BOT runs one command at a time and checks the CSW's tag against the CBW it built |
| a device's quirk breaks MODE SENSE, PREVENT ALLOW or START STOP | the transport sends none of them |

## Domains and authority

### Who holds a controller

A host controller is a device like any other: the manifest places its
unit on one configured domain, the **USB domain** of that controller,
whose creation gives it, and nothing else holds it
([design-system.md](design-system.md#devices)). The USB domain holds the
controller's unit and nothing else in a release build's manifest, and
runs the USB core, the controller's driver and the class drivers, and no
file system:

| Platform | Controller | Given as | DMA | The USB domain is |
| --- | --- | --- | --- | --- |
| QEMU `virt` | `qemu-xhci`, PCI `1b36:000d` on the root bus | a PCIe function by place, through the PCIe domain | confined by the IOMMU, which covers the root bus ([design-platforms.md](design-platforms.md#dma)) | outside the trusted base |
| Raspberry Pi 4 | the VL805, PCI `1106:3483` at bus 1, device 0, function 0 behind the `brcm,bcm2711-pcie` bridge | a PCIe function by place, through the PCIe domain | unconfined; the board has no IOMMU | in the trusted base, as every Pi 4 DMA device's domain is ([design.md](design.md#trust-placement)) |
| QEMU `raspi4b` | DWC2 | a device-tree unit: its register window and its line | none: the NIF holds the controller's DMA off | outside the trusted base |

A development build's manifest may put the controller in another domain,
the display domain for instance, as it may merge other driver domains
([design-system.md](design-system.md#devices)); nothing in the stack
changes, since a place's reader then reads a local process.

### HID reaches the display

The USB domain serves an **input tree** through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)) holding
the eight files `hid0` to `hid7`, each a stream of records in the binary
form of `abi/formats/input.txt`. The manifest grants the tree, an
instance of `files`, read only to the display domain that should receive
the controller's input, exactly as for any input device another domain
holds ([design-display.md](design-display.md#the-display-device)). The
display starts one reader for each file of a granted input tree; each
reader is a source of the router, with one read outstanding, and ends
only when its file ends or a read fails. The set of files never changes
while the USB domain lives, so the router's sources are fixed by the
manifest, as its bounds require
([design-display.md](design-display.md#the-input-router)).

A HID function takes the lowest free number when it starts and holds it
until it ends. Its file carries the function's records; when the
function ends, by detach, by crash or by its controller's reset, the
file carries `release`, then nothing until the number's next occupant.
The number's stream process monitors its occupant and writes the
`release` itself when the occupant's process ends, so no path by which a
function can end has to remember it.
A function that finds every number taken is not started, and the bus
process shows it in the device's inspection record as `no input number`.

The input tree is the USB domain's only grant to the display, and it has
the reach the display design gives any input source: that of a person at
the display, and no more ([design-display.md](design-display.md#security)).
A USB device that claims to be a keyboard types; which display receives
a controller's input at all is the manifest's grant.

### Mass storage reaches the file servers

A medium on a USB drive is served by the block service the storage
design already has: a transport process beneath, a partition process
that reads the medium's table under the removable-media rule, and a
window process for each partition a client was granted
([design-storage.md](design-storage.md#data-model)). The USB domain runs
one such block service for each ready medium. What the manifest names is
a **drive** of the controller: a window row whose device is the
controller's device row, whose role is `fat`, whose partition is the
primary entry to serve, and whose new `drive` field is the drive's
number. The device service introduces the row's holder to the USB domain
as it introduces any window's holder, and the grant it hands over is a
**drive grant**: a process of the USB domain, `erx_blk_drive`, made for
that one row and living as long as the USB domain.

A drive grant answers one request, `window`: `{ok, Window}`, the pid of
the window of its row's partition on the medium the drive holds now;
`{error, no_medium}` while the drive holds none; or `{error,
no_partition}` when the medium's table has no such entry the
removable-media rule serves. The window is an ordinary window of the
block service, answering `{read, Sector, Count}`, `{write, Sector,
Bytes}` and `flush` with the block service's answers, and it ends when
its medium ends. Holding a drive grant is holding that one partition of
that one drive, as holding a window is holding its sectors, so the grant
checks no caller and names nothing else.

The FAT server takes a drive where it took a window. It mounts lazily,
when a client first walks its tree, by asking the drive for the window
and mounting what the window serves; with no medium its root is an empty
read-only directory, and each walk asks again. When the window ends, the server
unmounts at once, answers `eio` to every fid of that mount, and mounts
again on the next walk. The FAT design's ordering of its writes keeps a
volume removed mid-write consistent up to the batch in flight
([design-storage.md](design-storage.md#removable-media-fat)).

Drives are numbered for the controller, not for the machine: two
controllers' `da0` are two drives, each named by its own controller's
device row. A logical unit whose medium becomes ready when every drive
its controller's rows name is occupied is not served, and the bus
process shows it as `no drive`.

### What the USB domain claims

The USB domain claims every device its controller reaches; no other
domain claims a USB device, and no program reaches a device's pipes,
since erXos has no counterpart of FreeBSD's `ugen`. A need for one is a
declared protocol with a design of its own
([design.md](design.md#decisions)).

Which interfaces it drives is one pure function of the configuration
descriptor, `erx_usb_claim:functions/1`, a closed table:

| Interface | Function | Needs |
| --- | --- | --- |
| class 03h, HID, any subclass and protocol | `erx_usb_hid` | one interrupt-IN endpoint |
| class 08h, mass storage, subclass 06h, protocol 50h | `erx_usb_bot` | one bulk-IN and one bulk-OUT endpoint |
| device class 09h, hub, or interface class 09h | `erx_usb_hub` | one interrupt-IN endpoint |
| anything else | none | |

The device's first configuration is set, as FreeBSD sets configuration
index 0 unless a quirk names another (`usb_device.c:1969-2019`), and each
interface's alternate setting 0 is used. Each interface the table names
is one function; a composite device's interfaces are claimed one by one.
A device none of whose interfaces the table names is configured anyway,
so its descriptors and state show in its inspection record, and runs no
function. CBI (protocols 00h and 01h), UAS (62h), the RBC, UFI and
SFF-8070i command sets, isochronous interfaces and every other class are
outside this design.

### What a device can make the domain spend

Every bound is a constant of the stack or of the controller's record,
fixed before any device arrives:

| Resource | Bound | Where it is fixed |
| --- | --- | --- |
| devices on a controller | 16: the slots an xHCI controller is configured with, and the device addresses DWC2's driver hands out | `usb_devices_max` |
| hub depth | 5 tiers below the root, FreeBSD's `USB_HUB_MAX_DEPTH`; a hub deeper than that is configured and its ports never powered | `usb_hub_depth_max` |
| configuration descriptor | 4 KiB: one control buffer; a longer `wTotalLength` refuses the device with `descriptor too long` | `usb_config_max` |
| HID report descriptor | 4 KiB, one control buffer; a longer one refuses the function | `hid_report_descriptor_max` |
| string descriptor | 255 bytes, `bLength`'s own bound, three strings a device | the descriptor format |
| endpoints a device may use | its claimed functions' endpoints, at most 8 with EP0 | `usb_endpoints_max` |
| xHCI queue blocks | 16 control, 16 interrupt and 4 bulk blocks per controller | the TRB ring form's record |
| transfers in flight | 1 on a control pipe, 4 on an interrupt pipe, 2 on a bulk pipe | the queue blocks' buffers |
| processes | one per claimed function, one per ready logical unit's transport, partition and windows | the claim table and the places |
| input numbers, drives | 8 input numbers; the drives the manifest names, at most 4 | `usb_input_max`, `usb_drives_max` |
| enumeration | one attempt and one retry if the device vanished during the port reset, then the port stays disabled until its connection changes, as FreeBSD's `uhub_reattach_port` | the bus core |
| time | every control transfer 5 s; every BOT command within the block transport's 28 s | [Failure handling](#failure-handling) |

A device that offers more than a bound is refused with a reason in its
inspection record and a log line, and costs nothing beyond its slot and
what its refusal read. These constants live in a new ABI file,
`abi/formats/usb.txt`, with the chapter 9, HID, BOT and SCSI constants
the stack reads ([The USB core](#descriptors)).

## The USB core

### The process tree

Each USB domain runs, for each controller it holds, one supervisor,
`erx_usb_sup`, with the `rest_for_one` strategy over two children in
order:

1. **The places**, `erx_usb_places_sup`: the input tree's server, one
   stream process per input number, and one drive grant per window row the
   manifest names. They hold no device state, so they survive every
   failure below them, and a reader outside the domain never sees its
   file end or its drive grant's pid die while the domain lives.
2. **The bus**, `erx_usb_bus_sup`, `one_for_all` over the controller
   process, the bus process and the function supervisor, whose children,
   one per function, are `temporary`. These three share the controller's
   state: a controller reset ends every device, so the controller's
   restart restarts the bus, which enumerates every port again, and every
   function, whose places it frees first.

A medium's block service runs under its BOT function, so it ends with
the function, and a medium's windows end with its block service.

### Ports, hubs and devices: the bus core

`erx_usb_bus_core:step(Event, State) -> {Actions, State}` holds the
whole topology. Its state is a map of hubs, the root hub among them, each
with its ports, and of devices, each with its place in the tree (the
route of port numbers from the root), its speed, its reference, its
enumeration state, its configuration and its functions. Each port is in
one of these states:

| Port state | Meaning | Leaves on |
| --- | --- | --- |
| `off` | not powered | power on: `settling` |
| `empty` | powered, nothing connected | a connect: `settling` |
| `settling` | connected, waiting the power-up delay, 300 ms | the deadline: `resetting`; a disconnect: `empty` |
| `resetting` | port reset issued | reset done and still connected: `enumerating`; connection changed during the reset: `settling` once, then `disabled` |
| `enumerating` | a device is being addressed and read | configured: `running`; any failure: `disabled` |
| `running` | the device is configured and its functions run | a disconnect, or a port disable reported by the hub: detach, then `empty` |
| `disabled` | given up until the connection changes | a connection change: `settling` or `empty` |

Every port is reset before its device is addressed, a USB 3 root port
as much as any other, as FreeBSD resets every port in host mode
(`usb_hub.c:703`) and its xHCI root hub turns a reset into the port's
reset bit whatever the port's protocol (`xhci_roothub_exec`,
`xhci.c:3681-3684`); so the bus core has no case for a port's speed.

A device's enumeration is a sequence of states inside `enumerating`, in
FreeBSD's order (`usb_alloc_device`, `usb_device.c:1752-2070`):

1. **Address.** On xHCI the controller assigns the address: enable a
   slot, then address it with an input context the controller process
   builds from what the bus core supplies, the route, the root port, the
   speed and, for a low- or full-speed device behind a high-speed hub,
   that hub's slot and port as its transaction translator
   (`XHCI_SCTX_2_TT_HUB_SID_SET`, `XHCI_SCTX_2_TT_PORT_NUM_SET`,
   `xhci.h:94-97`). On DWC2 the bus core sends SET_ADDRESS with the
   lowest free address and waits the 10 ms settle.
2. **Device descriptor**: the first 8 bytes, as FreeBSD reads first
   (`USB_MAX_IPACKET`, `usb.h:70`), with EP0's packet size at its
   speed's default, 8 at low and full speed, 64 at high speed and 512 at
   SuperSpeed (unverified: the USB base specifications were not
   fetched); then, once `bMaxPacketSize0` is known and EP0 updated with
   evaluate context on xHCI, all 18.
3. **Strings**: the language table, then the manufacturer, product and
   serial strings in US English (0409h) when the table offers it and in
   its first language otherwise; a failure leaves the string unknown and
   does not fail the device.
4. **Configuration descriptor**: its 9-byte header, then `wTotalLength`
   bytes, refused past `usb_config_max`.
5. **Claim**: `erx_usb_claim:functions/1`.
6. **Configure**: SET_CONFIGURATION with the first configuration's
   value, then, on xHCI, one Configure Endpoint command adding every
   endpoint the claimed functions need; for a hub, its slot context marks
   it a hub with its port count and, for a high-speed hub, its
   transaction translator's think time and whether it has one per port
   (`XHCI_SCTX_0_HUB_SET`, `XHCI_SCTX_0_MTT_SET`, `xhci.h:80-83`).
7. **Start**: one function process per claimed interface, each with its
   pipes.

Every step is one control transfer or one controller command, issued as
an action; its answer is the next event. A STALL, a timeout or a
malformed answer ends the enumeration as FreeBSD's error path does: the
device's slot or address is released, the port is disabled, and the
device's inspection record keeps the step and the reason until the
connection changes (`usb_hub.c:820-839`).

**Detach** is one transition from any device state: every function of
the device and of every device below it, if it is a hub, deepest first,
is stopped; each of their places is freed; the device's reference is
dropped from the controller's map; and, on xHCI, its slot is disabled,
which returns every transfer still posted on it. So a device's removal
in the middle of any step leaves nothing behind, and no list of steps
needs a removal case of its own.

**Hubs.** A hub function polls its interrupt endpoint, whose report is a
bitmap of the ports that changed, and sends `{changed, Hub, Ports}` to the
bus process; the bus core then reads each port's status with
GET_STATUS and clears the change bits it read, as the root hub's ports
are read from the controller. At a hub's start the bus core powers each
port, as FreeBSD does at attach. An over-current change is cleared and
logged once, and the port follows what its status then says, since the
hub, not software, cuts the port's power (FreeBSD's `uhub_explore`,
`usb_hub.c:1036-1046`); the over-current state shows in the port's
inspection record. The Pi 4's 1.2 A budget across its ports is the
board's to enforce; the stack keeps no power budget.

### Descriptors

`erx_usb_desc`, a pure module, decodes everything a device returns
during enumeration by binary matching, with the checks FreeBSD makes and
the bounds above:

* a device descriptor is exactly 18 bytes of type 1; a configuration's
  header 9 bytes of type 2 with `wTotalLength` from 9 to
  `usb_config_max`;
* the walk over a configuration takes one descriptor at a time, each
  with `bLength` at least 2 (FreeBSD's walk stops below 3,
  `usb_parse.c:105`; erXos takes 2, the smallest header, and skips a
  descriptor it does not use, so a 2-byte vendor descriptor ends nothing)
  and lying wholly inside `wTotalLength`; an interface descriptor at
  least 9 bytes, an endpoint descriptor at least 7, a HID descriptor at
  least 9 with its report descriptor's length, a hub descriptor at least
  7 with its port count from 1 to 15, the ports a tier's four bits of an
  xHCI route string can name;
* an endpoint's address, type, maximum packet size and interval are
  checked against what the claimed function accepts, and its maximum
  packet times its transactions per interval must fit one buffer of the
  queue block its type takes, so no transfer the device can make
  outgrows the memory laid out for it;
* a string descriptor's UTF-16LE is decoded to UTF-8, and an unpaired
  surrogate is replaced, so every string the stack keeps is valid UTF-8.

What a device's strings say reaches a log line, an inspection record or
`/proc` only through that sink's escaping, like every text from a device
([design.md](design.md#security)).

### Transfers and pipes

A function submits transfers through the controller process with
`erx_usb_pipe`:

* `control(Pipe, Setup, Data)`: `Setup` the 8 bytes of a request,
  `Data` `none`, `{in, Length}` or `{out, Binary}`; answers `{ok,
  Bytes}`, `{error, stall}`, `{error, timeout}`, `{error, gone}` or
  `{error, {controller, Code}}`;
* `interrupt_in(Pipe, Tag)`: posts one interrupt-IN transfer of the
  endpoint's packet size; its completion arrives as a message `{usb,
  Pipe, Tag, Result}`, so a HID function keeps its transfers posted and
  waits in its own receive;
* `bulk_in(Pipe, Tag, Length)` and `bulk_out(Pipe, Tag, Binary)`, whose
  completions arrive the same way;
* `clear_halt(Pipe)`: resets the host's side of a halted endpoint, then
  sends CLEAR_FEATURE(ENDPOINT_HALT) to the device, in FreeBSD's order
  (`usbd_clear_stall_callback`, `usb_transfer.c:3373-3392`), as one
  operation, so no function orders the two halves itself.

A control transfer on EP0 that stalls leaves the endpoint ready for the
next one: the controller process resets the host's side of EP0 before
answering, since every user of EP0 needs that and none should repeat it.
On xHCI the stall is taken to halt EP0 as it halts any endpoint, so the
reset is the halted queue's own (unverified without the
specification).
Only the BOT engine's write functions in `erx_blk_write` call
`bulk_out/3` ([The block transport](#the-block-transport)).

## Host controllers

### The xHCI driver

`erx_xhci`, the controller process, is an Erlang process over the device
NIF's TRB ring form. Its pure core, `erx_xhci_core`, decides; the
process performs.

**Start.** In the order of FreeBSD's `xhci_start_controller`
(`xhci.c:304-454`), which the form's install performs whole
([The TRB ring form](#the-trb-ring-form)):

1. read the capability registers: the slot, interrupter and port counts,
   the scratchpad count, `AC64`, the context size and the extended
   capabilities' offset;
2. walk the extended capabilities, each read through the register
   window, at most 64 of them and each inside the window, for the USB
   legacy support capability, whose OS-owned semaphore it sets and whose
   BIOS-owned semaphore it waits up to 1 s to clear, and for the
   supported-protocol capabilities, which say which ports are USB 2 and
   which USB 3;
3. `erx_device:negotiate/2`, the form's install: reset the controller,
   lay out and hand over the DCBAA, the scratchpad, the event ring and
   the command ring, configure `usb_devices_max` slots, and run;
4. power every root port, when the controller has port power switches,
   and read each port's status, so the bus core starts from what is
   connected.

**Ports.** The controller process answers the bus core's root-hub
operations from each port's `PORTSC`. A write to `PORTSC` keeps its
read-write bits, writes zero to every change bit it does not mean to
clear, and never writes the port-enable bit, whose 1 disables the port,
except to disable; FreeBSD writes a read value masked with
`XHCI_PS_CLEAR` for this (`xhcireg.h:146`), and erXos derives the same
mask from the access type of each field of the SVD source, so no
constant is copied by hand.

**Commands** run one at a time, each a post on the command queue whose
completion is the next command's start: enable slot, disable slot,
address device, configure endpoint, evaluate context (to update EP0's
packet size or a hub's slot context), reset endpoint, stop endpoint, set
TR dequeue pointer and reset device. A command that does not complete in
5 s fails the controller: the process ends, and its restart resets the
controller.

**Events.** An interrupt is a hint: the process calls
`erx_device:complete/2` until it answers `{ok, []}`, and acknowledges the
line. Each completion is a transfer's, with its tag, the bytes the
controller wrote and its completion code and residue; a command's, with
its tag, code and, for enable slot, the slot; or a port's change, with
the port. Erlang decodes the codes from the status words of the event,
whose layout is `abi/formats/xhci.txt`'s; every address field of the
event stays in the NIF.

**Halts.** A STALL or a transaction error halts an endpoint. The halting
transfer completes with its code; the others posted after it complete
`stopped` once the host's side is reset: the controller process issues
reset endpoint, then set TR dequeue pointer, which moves the controller
past them, and only then takes new transfers on that pipe, which the
queue's own state enforces. A function's `clear_halt/1` uses the same
pair before its CLEAR_FEATURE.

### The TRB ring form

xHCI moves everything through memory the controller reads and writes on
its own: a **command ring** and one **transfer ring** per endpoint, which
the CPU writes and the controller reads, each entry a 16-byte TRB whose
cycle bit tells the controller it is valid; an **event ring**, which the
controller writes; the **DCBAA**, an array of the device contexts'
addresses with the scratchpad array's in entry 0; a **device context**
per slot, which the controller writes; the **input context** a command
reads; and **scratchpad** pages only the controller uses
(`xhci.h:48-68`, `:228-312`, `:400-411`). Nearly every one of these holds
device addresses, and a cycle bit or a link TRB makes the controller
fetch from an address, so under the DMA rules the NIF builds all of it
([design-device-dma.md](design-device-dma.md#register-ownership)). The
form is the fourth beside the split ring, the register ring and ADMA2,
with a pure core, `erx_device_trb`, whose round function returns
observations and decisions to `run_call` like the others
([design-device-dma.md](design-device-dma.md#calls-observations-and-plans)).

**Memory, laid out once.** At install the form divides the record's DMA
memory into regions, each on a granule, by constants of the form and
counts read from the controller:

| Region | Size | Writer | Notes |
| --- | --- | --- | --- |
| DCBAA | one granule-aligned region of `usb_devices_max + 1` entries | the CPU | an entry is written when a slot is enabled and cleared when it is disabled |
| scratchpad array and pages | the count the controller asks for, at most 64 pages | the controller, from install to reset | never read by the CPU; install refuses a controller asking for more with `{error, enotsup}` |
| event ring segment table | one entry | the CPU | written at install |
| event ring | one segment of 256 TRBs | the controller | read by observation, dequeue published through `ERDP` |
| command ring | 16 TRBs, the last a link back | the CPU | one command in flight |
| input context | one, 33 contexts of the controller's context size | the CPU, handed to the controller with each command that reads it | the command queue's one buffer |
| device contexts | one per slot, 32 contexts | the controller, while the slot is enabled | zeroed and handed over at address device; never read by the CPU |
| queue blocks | 16 control, 16 interrupt and 4 bulk | per block: its ring the CPU's, each buffer the device's while posted | below |

A **queue block** is a transfer ring of 16 TRBs, the last a link TRB back
to the first, and a pool of buffers: a control block one 4 KiB buffer, an
interrupt block four 1 KiB buffers, a bulk block two 32 KiB buffers, each
buffer aligned to its size so that none crosses a 64 KiB boundary, which
a TRB's buffer may not. Nothing is allocated after install. With at
most 64 scratchpad pages, the record's memory is under 1 MiB, the
`dma_memory` its device row gives.

**The event ring cannot fill.** A control transfer causes at most two
events (a short packet on its data stage and the end of its status
stage), any other transfer one, a command one, and a port at most one
change event until the driver clears its change bits (unverified without
the xHCI specification). The blocks hold at most 16 control transfers
and 64 + 8 others, one command is in flight, and the install refuses a
controller whose port count would take 16 x 2 + 72 + 1 + ports past the
ring's 256 entries less one, that is more than 150 ports; QEMU's has
eight. So an event-ring-full condition is not a case the driver handles;
should a controller break the assumption, it reports the condition as an
event, the driver ends, and its restart resets the controller.

**Queues follow the controller's reports.** The queue of an endpoint is
named `{Slot, Dci}`, the slot and the endpoint's device context index.
It does not exist until a command that adds it succeeds, and it gives
its block back only when a command that removes it succeeds, so the
form needs no create or release call that a driver could misorder:

* address device takes a control block for `{Slot, 1}`, whose ring base
  the NIF writes into the input context's EP0 context;
* configure endpoint takes a block for each endpoint context its input
  control context adds, of the kind its endpoint type names (control,
  interrupt or bulk; isochronous is `badarg`), and gives back each it
  drops;
* disable slot gives back every block of the slot, with the slot's
  DCBAA entry.

A block is reserved when the command is posted and kept or returned when
its completion is read; a command that fails returns what it reserved. A
block given back may be taken by any later queue, of any slot, since the
controller's success on a command that removes it is its report that it
holds nothing of that ring, and every buffer still posted on it is
answered `stopped` in the same completion.

**What Erlang writes and what the NIF writes.** A command is posted as
`erx_device:post(Dev, command, Tag, Command)`:

| `Command` | What the NIF builds |
| --- | --- |
| `enable_slot` | the TRB |
| `{disable_slot, Slot}`, `{reset_device, Slot}` | the TRB, the slot checked enabled |
| `{address_device, Slot, Input}`, `{configure_endpoint, Slot, Input}`, `{evaluate_context, Slot, Input}` | the input context from `Input`, a binary of the input control context and the slot and endpoint contexts in the controller's context size, then the TRB pointing at it |
| `{reset_endpoint, Slot, Dci}`, `{stop_endpoint, Slot, Dci}` | the TRB |
| `{set_tr_dequeue, Slot, Dci}` | the TRB, with the queue's own enqueue position and cycle state as the pointer |

In `Input` the driver writes every field but the addresses: each
endpoint context's TR dequeue pointer and cycle state must be zero, and
the NIF writes them from the queue the context adds; every other field,
the slot context's route, speed, root port, hub and transaction
translator fields and each endpoint context's type, packet size,
interval and error count, is the driver's, since none of them changes
where the controller reads or writes or how many bytes it moves at an
address the NIF gave. A transfer is posted as `erx_device:post(Dev,
{Slot, Dci}, Tag, Transfer)`:

| `Transfer` | TRBs the NIF builds |
| --- | --- |
| `{control, Setup, none}` | a setup stage with the 8 bytes as immediate data, a status stage |
| `{control, Setup, {in, N}}` or `{control, Setup, {out, Bin}}` | a setup stage, a data stage over the block's buffer, a status stage in the other direction |
| `{normal, {in, N}}` or `{normal, {out, Bin}}` | one normal TRB over one buffer, interrupt on short packet and on completion |

The NIF writes every TRB's pointer, length, type, cycle, chain,
immediate-data, interrupt-on-completion and link fields; the driver
chooses only the request's direction, length and setup bytes. `N` and
`Bin` within the buffer and the setup's own length field equal to the
data stage's are checked, else `badarg`. The doorbell is the post's
publish, written by the NIF after the TRBs and their cache maintenance,
as virtio's available index is.

**Completing.** `complete/2` observes the event ring from the NIF's
dequeue position: each entry's cycle bit, then the entries it covers, at
most 32 a call. For each event it reads its type, slot, endpoint, TRB
pointer, completion code and residue, and checks them against its own
state: the slot enabled, the endpoint a queue of it, the pointer the
address of a TRB of a transfer posted on that queue (the last or, since
some controllers report the TRB before the link, the one before it, as
FreeBSD accepts, `xhci.c:1007-1016`), and the residue no larger than the
transfer's length. A passing transfer event retires the transfer,
copies `length - residue` bytes of its buffer into a fresh binary and
answers `{Tag, Bytes, Status}`, `Status` the event's two status words
with the pointer removed; a command completion answers `{Tag, Status}`
and applies the queue changes above; a port change answers `{port,
Status}`. An event that fails a check breaks the form, as a malformed
used entry breaks a virtio queue: the events before it are returned, and
every later call is `{error, broken}` until `negotiate/2` resets the
controller. The NIF writes `ERDP` with the busy bit after the events it
consumed, as FreeBSD does (`xhci.c:1193-1196`).

**Install.** `negotiate/2` stops the controller and resets it with
`HCRST`, waits for the controller to report itself halted and ready, at
most 1 s each, else `{error, ebusy}`; returns every posted buffer and
every block to the free lists; zeroes and lays out every region; writes
the slot count, `DCBAAP`, the event ring's size, dequeue pointer and,
last, segment table base, which makes the controller read the table
(FreeBSD writes it last for that reason, `xhci.c:383-395`), the command
ring's base with its cycle state, and enables the interrupter; then sets
run and waits for the controller to leave halted. The regions pass to
the device by the sequencer's handoffs: the rings, the DCBAA and the
segment table cleaned before the registers that name them are written,
the scratchpad handed over for good.

**Registers it owns.** `DCBAAP`, `CRCR`, `CONFIG`, `ERSTSZ`, `ERSTBA`,
`ERDP`, every doorbell, `USBCMD`'s run and reset bits and `IMAN`'s enable
bit are `ownedByNif` in `hw/svd/xhci/xhci.svd`: each changes where the
controller reads or writes, which entries it takes as valid, or which of
the DCBAA's entries it may follow. `PORTSC`, `USBSTS`'s change bits and
the extended capabilities' registers are the driver's.

**Address width.** TRBs and contexts carry 64-bit addresses; a
controller whose `AC64` is clear reaches 32 bits only, and the install
refuses, with `{error, erange}`, a record whose memory lies above that,
before it writes anything. The VL805's 32-bit limit is its bridge's
([The VL805](#the-vl805-on-the-raspberry-pi-4)).

### Registers at offsets the controller reports

xHCI's operational registers start at the capability registers'
`CAPLENGTH`, its runtime registers at `RTSOFF` and its doorbells at
`DBOFF` (`xhcireg.h:44-73`), and each controller reports its own. The
SVD source describes the four groups as clusters, and marks each of the
three movable clusters with the capability register and field its base
comes from, an erXos extension the generator checks. When the NIF opens
the record it reads the three values once, checks that each cluster lies
wholly inside the register window, and refuses the record with
`{error, einval}` otherwise; from then on every name resolves to a fixed
offset as for any peripheral. The ports, `PORTSC(n)` for `n` from 1 to
the port count, are an array of the operational cluster, checked the same
way. This is a change to the device NIF's register model, named in
[Changes to other designs](#changes-to-other-designs).

### `qemu-xhci` on QEMU `virt`

The PCIe enumerator gives the function's BAR 0 as its register window,
one MSI or MSI-X vector as its IRQ object, since one interrupter serves
the whole controller, and a DMA window on the function's IOMMU stream,
since it sits on the root bus. Which of MSI and MSI-X the enumerator
programs is the PCIe design's. Whether the function offers a function
reset is to be read from its capabilities; the driver's own reset is
`HCRST`, inside `negotiate/2`. The facts the documentation does not give,
the capability registers and the port layout, are read at start and shown
in the controller's inspection record; the first QEMU run records them in
the facts record.

### The VL805 on the Raspberry Pi 4

Everything particular to the VL805 is on the PCIe side; its xHCI is
generic (`bcm2838_xhci.c:22-27`):

* **Where it is.** The manifest names it by place, bus 1, device 0,
  function 0, behind the Pi 4's bridge, and its device-kinds row matches
  only `1106:3483` there, as FreeBSD's position check does, so a
  commodity VIA card behind a replaced bridge is not taken for it
  (`bcm2838_xhci.c:94-101`).
* **Its firmware.** The PCIe enumerator reads configuration register
  `0x50` before it reports the function, and reports it only when the
  value is neither 0 nor all ones. When the boot firmware has not loaded
  the VL805, loading it takes the mailbox's `NOTIFY_XHCI_RESET`, which
  only the kernel may send (PL2). Whether the firmware leaves the VL805
  loaded when erXos starts, and whether the bridge's bring-up must reset
  the link, are for a probe on a board; the decision that follows is
  [an open decision](#open-decisions).
* **Its reach.** Its DMA is 32-bit and FreeBSD keeps it below 960 MiB.
  Its record's DMA range comes from the bridge's `dma-ranges`, whose
  PCI addresses take three cells, which the DMA-range walk must learn to
  read
  ([design-platforms.md](design-platforms.md#dma)); its contiguous memory
  must lie below `0x3c000000` until a probe on a board shows where the
  bridge's limit really is. Both are requirements on the Pi 4 bridge's
  design.
* **Its interrupt.** The bridge decodes MSIs itself, at a fixed address,
  and raises its own line (`bcm2838_pci.c:378-505`); its INTx lines would
  be wired lines. Which reaches the USB domain is the bridge design's,
  from the clean-room facts record; this design needs one IRQ object that
  fires for the VL805's interrupter.
* **Its trust.** Its DMA is unconfined, so the USB domain is in the
  trusted base, holds the VL805's unit alone in a release build, and runs
  no file system, as property 9 asks of every unconfined device's domain
  ([design-system.md](design-system.md#devices)). The VL805 runs firmware
  the VideoCore loaded, which erXos neither chooses nor checks, as it
  trusts the firmware that boots the board
  ([design.md](design.md#residual-risks), "Closed firmware").
* **Its topology.** Every USB 2 device is behind the VL805's internal
  high-speed hub, so the Pi 4's keyboards and mice need the hub function
  and the transaction translator fields of
  [enumeration](#ports-hubs-and-devices-the-bus-core); no Pi-specific
  code follows from it.

The BCM2711's other xHCI, which `otg_mode=1` puts on the USB-C power
connector, would need no PCIe bridge and run the same driver; its
address, interrupt and DMA facts live only in the board's device tree,
so it waits for the clean-room facts record, and the connector also
powers the board ([Open decisions](#open-decisions)).

### DWC2 on QEMU `raspi4b`

`erx_dwc2` drives a DWC2 in host mode by programmed I/O, as FreeBSD's
`dwc_otg` does, through each host channel's registers and the channels'
data FIFOs, and never by DMA (FreeBSD's driver never programs a
channel's DMA address register; `dwc_otgreg.h:80-83` defines it and
`dwc_otg.c` does not use it). The SVD source, `hw/svd/dwc2/dwc2.svd`,
marks `GAHBCFG`'s DMA-enable field and every `HCDMA` register
`ownedByNif` and the NIF writes neither, so no driver can turn the
controller's DMA on, and the record carries no DMA memory: the DWC2 is
not a bus master for erXos, and its domain's trust does not depend on it.

Its scope is what QEMU's model runs: host mode, forced at start;
low- and full-speed devices, directly or behind a full-speed hub;
control, bulk and interrupt transfers; one transfer per channel, at most
the controller's channel count (FreeBSD's ceiling is 16,
`dwc_otg.h:35`). Split transactions through a high-speed hub's
transaction translator, high-speed devices, isochronous transfers,
device mode and DMA mode are outside it, since no target needs them:
the real Pi 4's DWC2 is a device-mode port on its power connector. A
high-speed device or hub on a DWC2 port is refused at enumeration with
`unsupported speed`.

Its pure core, `erx_dwc2_core`, schedules transfers on channels: a
control or bulk transfer takes a free channel and is moved packet by
packet through the FIFO, retried on NAK; an interrupt pipe's next
transfer is started at its interval's frame from the frame-number
register. The process feeds the core each channel interrupt's status and
the receive FIFO's status words, and performs the FIFO reads and writes
it answers. Each FIFO word is one register access, as the SD
controller's data port is ([design-storage.md](design-storage.md#the-sd-host-controller));
whether the process keeps up with a full-speed bus is measured, and a C
copy of the FIFO, a per-byte primitive of the NIF, is the measured
exception if it does not (on [the watch list](todo-performance.md)).
Whether QEMU's model runs slave mode as the hardware does, and attaches
`usb-storage` under DWC2, are for the first run (probes 6 and 10 of
[Verification](#qemu-suites)).

## HID

A HID function, `erx_usb_hid`, drives one HID interface: it reads the
interface's report descriptor, chooses the protocol, keeps interrupt-IN
transfers posted, folds each report into input records and writes them
into its input number. Its pure parts are `erx_hid_desc`, the report
descriptor's parser, and `erx_hid_core`, the fold.

### The report descriptor

`erx_hid_desc:parse/1` translates FreeBSD's item parser (`hid_get_item`,
`hid.c`) into binary matching over the descriptor: short items of 0, 1, 2
or 4 bytes of data and long items, which it skips (`hid.c:305-318`);
global items kept in a state with a push stack at most 4 deep, local
items reset at each main item, collections counted. Its bounds are
FreeBSD's: at most 64 usages a main item, 16 report ids and 2048 fields
a report (`hid.c:66-69`), with a push beyond the depth refusing the
descriptor (`hid.c:446-449`), and erXos adds two: a report of at most
the interrupt buffer, 1 KiB, and a descriptor of at most
`hid_report_descriptor_max`. Its result is a **layout**: for each
report id, the input fields in order, each a bit offset, a size from 1
to 32 bits, a count, a logical minimum and maximum, a usage page and its
usages or usage range, and the flags variable or array, relative or
absolute. Output and feature fields are parsed for their offsets and
otherwise ignored.

From the layout, `erx_hid_core:roles/1` finds what the function can
report, from its usages and not from its interface's protocol:

* **keys**: Keyboard/Keypad page (07h) fields, the modifiers as eight
  one-bit variables (usages E0h to E7h) and the rest as an array or as
  variables;
* **a pointer**: Generic Desktop X and Y (30h, 31h), relative or
  absolute;
* **buttons**: Button page (09h) usages 1 to 3, mapped to `BTN_LEFT`,
  `BTN_RIGHT` and `BTN_MIDDLE`, as FreeBSD's `hms` maps buttons from
  `BTN_MOUSE`, which is `BTN_LEFT` (`hms.c:93`);
* **a wheel**: Generic Desktop Wheel (38h).

A layout with none of these is not driven, and its function ends with
`no usable report`. Consumer-page keys and digitizers (touch screens)
are left for a later version, as [open items](#open-decisions).

### The protocol

HID 1.11 says that a device starts in the report protocol but the host
should set the one it wants (section 7.2.6), and only a boot interface
(subclass 1) supports SET_PROTOCOL at all (section 4.3). The function
therefore:

1. reads the report descriptor and parses it;
2. on a boot interface, sends SET_PROTOCOL(report) when the layout
   parsed and has a role, and SET_PROTOCOL(boot) when it did not, and
   then uses the boot layout of Appendix B.1 (keyboard) or B.2 (mouse),
   built in, as the layout;
3. on any other interface, uses the parsed layout or ends with the
   parser's reason;
4. on a keyboard, sends SET_IDLE(0), so it reports only on change, and
   ignores a STALL of it, as FreeBSD does.

So the boot protocol is the fallback for a descriptor the parser
refuses, not a mode of its own, and a tablet, which has no boot
protocol, works because the parser is always tried first.

### From reports to records

`erx_hid_core:step(Layout, Report, State) -> {Records, State}` decodes
the fields of one report at their offsets and compares them with the
last report's, which `State` keeps:

* **Keys.** The set of keys held is the modifier bits set and the
  array's usages, each mapped to an evdev code through the usage table
  below. Each key in the old set and not the new gives `{key, up,
  Code}`, then each in the new and not the old `{key, down, Code}`, in
  ascending code order, so a report that changes several keys gives a
  deterministic sequence. A report whose array fields all hold
  ErrorRollOver (usage 01h) is the phantom state of Appendix C and
  changes nothing. A usage the table maps to no code is dropped and
  counted.
* **Pointer.** A relative X and Y give `{pointer, rel, DX, DY}` when
  either is non-zero. An absolute X and Y are clamped to their logical
  range and normalized across it as `(V - Min) * 65535 div (Max - Min)`,
  as the virtio-input driver does
  ([design-display.md](design-display.md#the-display-device)), giving
  `{pointer, abs, X, Y}` when either changed; a range whose maximum is
  not above its minimum makes the layout's pointer role absent.
* **Buttons** give key records with their `BTN_` codes on each edge.
* **Wheel.** A non-zero wheel gives `{wheel, Steps}`, clamped to -128 to
  127.

Moves come before button edges within one report, so a click lands where
the report put the pointer. The fold keeps one report, so its state has
the same size however long the device reports.

The function keeps four interrupt-IN transfers posted. When one
completes it folds the report, writes the records into its input number
and posts the transfer again only once the number's stream has taken
them; a stream holds at most one read's worth, 64 KiB, so a display that
stops reading stops the function, whose device then waits with its
reports, as a virtio-input device waits on its full buffers
([design-display.md](design-display.md#the-display-device)). A report
shorter than its layout, or of a report id the layout lacks, is dropped
and counted; one the parser's offsets would read past is impossible,
since every field lies inside the report length the layout fixed.

Keyboard LEDs are not driven: the router owns the lock state and nothing
carries it back to a device. A Caps Lock keyboard's LED stays dark while
the lock works, a limitation recorded with the user-facing documentation.

### The usage table

A new ABI file, `abi/formats/hid.txt`, holds the HID constants the stack
reads (the class descriptor types 21h and 22h, the class requests, the
item tags, the usage pages and usages above) and the keyboard page's map
from usage to evdev name, entry by entry, in the form `map 0x04 key_a`.
Its entries are FreeBSD's `evdev_usb_scancodes`
(`evdev_utils.c:44-118`), BSD-2-Clause, translated into evdev names, and
a host test reads FreeBSD's table from the pinned source as data and
fails on any entry that differs. `abi/formats/evdev.txt` gains the key
codes the map names that it lacks today (keypad keys, F13 to F24,
`KEY_102ND`, `KEY_COMPOSE` and the others FreeBSD's table names), since
it holds every code erXos reads; a code with no row in a keymap is
dropped and counted by the router, as today
([design-display.md](design-display.md#input-events)).

## Mass storage

### The BOT engine

A mass-storage function, `erx_usb_bot`, drives one Bulk-Only interface
and its logical units. Its pure core, `erx_usb_bot_core`, translates
FreeBSD's nine transfer states (`umass.c:185-194`) into one state machine
whose events are the pipes' completions and whose actions are transfers:

| State | Transfer | Next |
| --- | --- | --- |
| `command` | the CBW on bulk-out | data, or status when the command moves no data; a STALL: reset |
| `data_in`, `data_out` | the data phase on bulk-in or bulk-out | status; a STALL: `clear_data` |
| `clear_data` | `clear_halt` on the data pipe | status |
| `status` | the CSW on bulk-in | idle, with the CSW checked; a STALL: `clear_status` |
| `clear_status` | `clear_halt` on bulk-in | `status_again` |
| `status_again` | the CSW on bulk-in, once more | idle, with the CSW checked; a STALL: reset |
| `reset_1`, `reset_2`, `reset_3` | the Bulk-Only Mass Storage Reset, then `clear_halt` on bulk-in, then on bulk-out | idle, the command failed |

The status states follow Figure 2 of BOT 1.0. A CSW is valid when it is
13 bytes, its signature is 53425355h and its tag is the CBW's (section
6.3.1), and meaningful when its status is 0 or 1 with a residue no
larger than the CBW's length, or 2 (section 6.3.2). An invalid CSW and a
phase error (status 2) go to reset (sections 5.3.3.1 and 6.5), as
FreeBSD's checks do (`umass.c:1530-1610`); a residue larger than the
length, which FreeBSD truncates, makes the CSW not meaningful, and the
engine resets too, since a device that cannot count its bytes is not
trusted with their meaning. Status 1 is a command that failed; the
transport then sends REQUEST SENSE. The tag is a counter the engine
keeps, so a CSW left over from an earlier command never matches. One
command is in flight on an interface at a time, so a card reader's
logical units share it in turn.

At the function's start it sends Get Max LUN; a STALL or any failure
means one unit, as BOT allows, and a value above 15 refuses the
interface. Each unit gets a transport process.

### The SCSI subset

The transport sends these commands and no others, each built in
`erx_blk_write` from the table of `abi/formats/usb.txt`:

| Command | When | What it decides |
| --- | --- | --- |
| INQUIRY, 36 bytes | the unit's start | a direct-access device (peripheral type 0, qualifier 0) is served; any other type is not, with its type in the inspection record; the removable bit decides polling |
| TEST UNIT READY | until ready, and every 3 s on a removable unit, as FreeBSD polls (`scsi_da.c:3060-3065`) | whether a medium is present |
| REQUEST SENSE, 18 bytes | after every failed command | the sense key and additional sense code |
| READ CAPACITY(10), and (16) when (10) answers all ones | when a medium becomes ready | capacity and block length; a block length other than 512 is not served |
| READ(10), WRITE(10), or READ(16), WRITE(16) past 2^32 sectors | each request | |
| SYNCHRONIZE CACHE(10) | each flush | |

The commands several of FreeBSD's quirks work around are never sent:
MODE SENSE, PREVENT ALLOW MEDIUM REMOVAL, START STOP UNIT, READ(6) and
WRITE(6), and INQUIRY's vital product data or more than its 36 bytes
(`NO_START_STOP`, `FORCE_SHORT_INQUIRY`, `NO_INQUIRY_EVPD`,
`NO_PREVENT_ALLOW`, `umass.c:334-385`; `DA_Q_NO_6_BYTE`,
`DA_Q_NO_PREVENT`, `scsi_da.c:154-156`). A write
protected medium is found when a write fails with DATA PROTECT, not
asked about. A device that refuses SYNCHRONIZE CACHE with ILLEGAL
REQUEST has its flush answered `ok`, and the transport stops sending it
to that medium, as FreeBSD's disk driver does: it marks the disk as one
that cannot flush and answers the flush done (`scsi_da.c:4448-4457`,
`:6249-6254`). What such a device keeps after a flush then rests on the
device, a residual recorded in [Failure handling](#failure-handling).
The quirks that concern commands the transport does send, a device that
fails TEST UNIT READY or INQUIRY, miscounts its residue, signs its CSW
wrongly or reports its capacity off by one, are not carried: such a
device fails safe, unserved, and the first one that matters adds a quirk
table as data to `abi/formats/usb.txt`, naming the device in its
comment.

### Media and drives

A unit's medium is the span from the unit's becoming ready to its
ceasing to be:

* **Ready**: TEST UNIT READY succeeds and READ CAPACITY answers a
  capacity and 512-byte blocks. The medium takes the lowest free drive
  the manifest names for the controller, and a block service starts for
  it under the function: the transport, the partition process, which
  reads the table under the removable-media rule, serving only primary
  entries inside the medium that overlap no other
  ([design-storage.md](design-storage.md#data-model)), and a window for
  each partition the drive's rows name that the table has.
* **Gone**: a TEST UNIT READY answering NOT READY with MEDIUM NOT
  PRESENT, any UNIT ATTENTION (the device's own word that its medium
  may have changed or it was reset), the transport's failure, the
  function's end or the device's detach. The block service ends, so
  every window of the medium ends; the drive is free.

UNIT ATTENTION always ends the medium, even at power-on, where it only
means the device was reset: a medium ended without need costs a remount,
while one kept across a change it could not see would be written with
another medium's blocks.

### The block transport

The transport, `erx_blk_bot`, is a block transport like the virtio and
SD ones, answering `read/2`, `write/2`, `flush/0` and `info/0` with the
transport contract's answers and closed error set
([design-storage.md](design-storage.md#data-model)), with three
differences that are changes to the storage design:

* it is started by the BOT function, one for each ready medium, not by
  `erx_blk:start_link/0` from a device record, and is not registered as
  `erx_blk`; the block service reaches its transport by pid, a device
  record's transport as well as a medium's, so one block service serves
  both;
* `info/0` names the transport `usb_bot`, its `max_sectors` is 64, one
  bulk buffer, and its `detail` holds the vendor and product ids and the
  INQUIRY's vendor and product text, decoded and escaped where they are
  shown;
* its errors map from the CSW and the sense data: a command that failed
  with MEDIUM ERROR, DATA PROTECT, NOT READY or any other key is
  `{error, {device, {sense, Key, Asc, Ascq}}}`, three integers, and
  ends the medium when the key is NOT READY or UNIT ATTENTION; a command
  whose engine went through reset recovery is `{error, {device,
  reset}}`.

**The write path.** The trial rule (U4) holds for USB media as for any
medium: every medium-writing act goes through `erx_blk_write`. For USB
the act is a CBW whose command writes the medium, followed by its data
phase on bulk-out, so `erx_blk_write` gains one function per BOT act,
each building what it sends: the CBW, from its SCSI table, with the
trial check before any WRITE, and the data phase of a write whose CBW
it built. The engine's `command` and `data_out` actions are performed
by calling them, so the engine names a request, `{read, Lun, Sector,
Count}` or `{write, Lun, Sector, Data}` among them, and never a CBW's
bytes, as the SD device process names its steps and never a command
word. They are the only callers of `erx_usb_pipe:bulk_out/3`, which
the chokepoint rule `device-posters` holds as it holds
`erx_device:post/4` ([design-storage.md](design-storage.md#data-model)),
with a seeded violation. HID and hubs use no bulk-out pipe, so the rule
costs them nothing.

**Deadlines.** The transport keeps the contract's bounds: a request is
issued within 10 s of its acceptance and complete within 18 s of its
issue. Each bulk transfer of a command, and the engine's reset recovery,
run within that issue bound; a request that passes it ends the
transport, and with it the medium, and the engine's next command starts
with a reset recovery. A full-speed bulk pipe moves 64 sectors in well
under a second, so the bound is the medium's slowness, not the bus's.

## The PCIe dependency and the order of work

### What this design needs from the PCIe domain

**On QEMU `virt`**, from the PCIe domain of M9's kernel part
([plan.md](plan.md#m9-a-driver-is-an-erlang-process)):

1. the function `1b36:000d` given by place to the USB domain, its BAR 0
   carved as the register window after the bridge-window check;
2. one MSI or MSI-X vector as an IRQ object on the platform's MSI frame
   ([design-platforms.md](design-platforms.md#msi-frames));
3. a DMA window on the function's IOMMU stream, since it sits on the root
   bus;
4. memory space and bus mastering enabled at the device service's
   request, at the first give and again after each reset the driver
   reports ([design-system.md](design-system.md#drivers), Resets).

**On the Raspberry Pi 4**, from a design of the Pi 4's PCIe bridge, which
`TODO.md`'s open platforms item asks for and which needs a clean-room
facts record of Linux's `pcie-brcmstb` driver and of the Pi 4's device
tree first:

1. the bridge brought up, or its link inherited from the boot firmware
   as the Pi 5's RP1 link is ([design-platforms.md](design-platforms.md#dma),
   "Reset boundary"), with one outbound window for the VL805's BAR;
2. configuration register `0x50` read before the VL805 is reported
   ([The VL805](#the-vl805-on-the-raspberry-pi-4)), and the firmware
   notification, if the probe shows it is needed;
3. the bridge's three-cell `dma-ranges` read into the VL805's DMA range,
   and its contiguous memory placed below 960 MiB;
4. one IRQ object that fires for the VL805.

### The proposed order

1. **Host-built cores**, with no hardware: `erx_usb_desc`,
   `erx_usb_bus_core`, `erx_hid_desc`, `erx_hid_core`,
   `erx_usb_bot_core`, the SCSI builders and their fuzz targets and
   exhaustive tests; and `erx_device_trb`, the TRB form's core, in C on
   the host.
2. **DWC2 on QEMU `raspi4b`, on the stopgap**: the controller, the bus,
   hubs, HID into a display domain on `raspi4b`, and mass storage into
   drives; the first usable USB, with no PCIe and no NIF form.
3. **xHCI on QEMU `virt`**, with the PCIe domain and its MSIs: at M9's
   kernel part on erXos's kernel, or earlier if a PCIe enumerator is
   brought onto the stopgap for QEMU `virt` ([Open decisions](#open-decisions)).
4. **The VL805 on the Pi 4**, after the Pi 4 bridge's design and the
   board probes it needs.

Mass storage's user-visible end, files on a stick, needs the FAT server,
which the plan places after M13
([plan.md](plan.md#beyond-the-plan)); until it lands, a drive's windows
are tested with a raw window client.

## On the stopgap

The USB core, the class drivers and DWC2's driver are the same code on
the stopgap and on erXos's kernel. On the stopgap:

* only DWC2 on QEMU `raspi4b` runs, since PCIe and MSIs are Phase 2's
  ([The hardware](#the-hardware));
* the DWC2's unit is given like any device-tree unit: its register
  window and its line's IRQ object, made by the root and passed to the
  USB domain ([design-system.md](design-system.md#devices), "On the
  stopgap"); it has no DMA memory;
* the stack relies on no kernel guarantee the stopgap defers, and since
  the DWC2 runs without DMA, its domain carries none of the unconfined
  DMA residual the stopgap's other drivers carry; a USB domain that
  faults is restarted by the domain service, which gives the unit again.

Phase 1's residuals for USB, each recorded here as the design's and
in `TODO.md` when the code lands:

* **DMA without an IOMMU.** On the Pi 4 the VL805 reaches all memory,
  on both kernels; its domain is in the trusted base. Whether the
  bridge's inbound window could confine it to its own memory is for a
  board probe; it would confine a window, not pages, and the PCIe domain
  would own it.
* **Firmware.** The VL805 runs firmware the VideoCore loads.
* **Hostile devices.** A USB device can type as a person at the display
  and can feed every parser of the stack; the parsers are fuzzed, and a
  hostile device under QEMU waits for the `usb-redir` probe
  ([Verification](#qemu-suites)).

## Changes to other designs

Each change below is required by this design and belongs to the document
named; none is made here.

| Document | Change |
| --- | --- |
| [design-system.md](design-system.md) and `abi/manifest.txt` | a `usb` device role; a `drive` field in `erx_mf_window`, set exactly when the window's device has the `usb` role; the manifest check proves at most `usb_drives_max` drives a controller, each (device, drive, partition) once, and a USB domain in a release build holding its controller's unit alone and serving no file system (property 9) |
| [design-system.md](design-system.md), "Units" | a sentence that a USB device is a sub-device of its controller's unit and enters no catalogue |
| `include/erx/device_kinds.h` | rows for `qemu-xhci`, the VL805 by PCI identity and position, and the DWC2 by its device-tree compatible, each with role `usb` and its SVD peripheral |
| [design-runtime.md](design-runtime.md#the-device-nif) | the TRB ring form's requests to `post/4` and answers of `complete/2`; register clusters whose base the controller reports, read once and bounds-checked at open |
| [design-device-dma.md](design-device-dma.md) | the fourth descriptor form, its regions and writers, its queue blocks and their lifetime by the controller's reports, its address width read from `AC64`, and its rows in the failure table |
| [design-storage.md](design-storage.md) | the transport as a pid, not the name `erx_blk`; the `usb_bot` transport started per medium; drive grants and their one request, `window`, in the block service's interface; the FAT server taking a drive, mounting on access and unmounting when its window ends; `erx_blk_write`'s BOT functions and the `device-posters` rule over `erx_usb_pipe:bulk_out/3` |
| [design-display.md](design-display.md) | a granted input tree may hold several files, and the display starts one reader for each |
| [design-platforms.md](design-platforms.md) | the USB row of the platform table: `qemu-xhci` on QEMU `virt`, the VL805 through the PCIe domain on the Pi 4; the DWC2 as `raspi4b`'s USB under QEMU |
| [design-kernel.md](design-kernel.md#dma-and-the-iommu) and [design-device-tree.md](design-device-tree.md) | the DMA-range walk reads a PCIe bridge's three-cell `dma-ranges` |
| `abi/formats/` | `usb.txt` (chapter 9, BOT and SCSI constants, the stack's bounds), `hid.txt` (HID constants and the usage map), `xhci.txt` (TRB, context, segment-table and event layouts), new `evdev.txt` codes, and the binary record form of `input.txt` that the display design already names |
| `hw/svd/` | `xhci/xhci.svd` and `dwc2/dwc2.svd`, written from FreeBSD's `xhcireg.h` and `dwc_otgreg.h`, with the owned registers above |
| `abi/inspection.txt` | the USB paths of [Failure handling](#failure-handling) |

The driver's own build check changes too: `tools/lib/erx/chokepoint_rules/device.rb`'s
`device-posters` rule names `erx_xhci` as a poster of `erx_device:post/4`
and `erx_blk_write` as the one caller of `erx_usb_pipe:bulk_out/3`, each
with a seeded violation, and only `erx_xhci` and `erx_dwc2` in
`erlang/apps/erx_usb/` name `erx_device`.

## Concurrency

The controller process is the only process that calls the device NIF
for its controller, so the NIF's device lock is never contended by two
of its callers; the lock still orders its calls against the NIF's own
completion path as for every form
([design-device-dma.md](design-device-dma.md#concurrency)). Every
request to the controller, a function's transfer, the bus core's command
or root-port operation, is a message in its mailbox, served in arrival
order; one command is in flight at a time, while transfers on different
pipes are in flight together, up to their blocks' buffers. Device calls
run on normal schedulers, so the stopgap's condition for non-coherent DMA,
that no thread moves between its maintenance and its barrier, holds for
this form as for the others.

The bus process is sequential: one event at a time, each a port's change,
a control transfer's answer, a command's completion, a deadline or a
function's end. A detach that arrives while an enumeration step's
transfer is in flight is applied at once; the transfer's late answer
names a device reference the state no longer holds and is dropped, and
the controller answers it `gone` anyway once the slot is disabled.

Function processes run concurrently and share nothing; they meet only
in the controller's mailbox and, for input, in their own number's stream,
which only they write. A drive grant answers from the window it was
last told of, which the medium's block service sends each of the
drive's grants as its windows start, and which the grant forgets when
it sees that window end; a file server that receives a window that ends a moment later
finds its first request failing and unmounts, the same as if the medium
had gone after the request.

## Failure handling

| Failure | Detected by | What ends | Recovery |
| --- | --- | --- | --- |
| a malformed or oversized descriptor, a STALL or a timeout during enumeration | `erx_usb_desc`, the pipe's answer | the enumeration | the port is disabled until its connection changes; the reason is in the port's inspection record |
| a device of no claimed class, or past a bound | the claim table, the bounds | nothing: configured with no function, or refused | the inspection record names the reason |
| a malformed HID report | the fold | nothing: the report is dropped and counted | none needed |
| a function process crashes | its supervisor link, seen by the bus | the function; its place is freed, an input number with `release` | the bus restarts the function, at most 3 times in 60 s; past that the device is detached and its port disabled until its connection changes |
| a halted endpoint | the completion's code | the transfer | `clear_halt`, then the class's own recovery (BOT's status flow or reset recovery) |
| an invalid CSW or a phase error | `erx_usb_bot_core` | the command, answered `{device, reset}` | reset recovery; a failed reset recovery ends the function, which the bus restarts as above |
| a block request past the 18 s issue bound | the transport | the transport and its medium; the windows end | the engine's next command starts with reset recovery; the medium is found again by TEST UNIT READY |
| a medium removed or changed | TEST UNIT READY, UNIT ATTENTION, the detach | the medium; its windows end | the FAT server unmounts and remounts on the next walk; FAT's ordered batches keep the volume consistent up to the batch in flight |
| a control transfer not answered in 5 s | the controller process's deadline | the transfer, answered `timeout` after stop endpoint | the caller's |
| a command not answered in 5 s, an event that fails the form's checks, the controller's host system error | the controller process | the controller process | the bus group restarts; `negotiate/2` resets the controller and returns every buffer; every device is enumerated again; places survive, so each input number carries `release` and each medium's windows end |
| a register access that aborts (the controller fell off its bus) | the kernel | the USB domain, by the fault | the domain service restarts the domain, which gets its unit again; the display's readers see their files end and start again when the tree is granted again, and each drive's holder is introduced again, as for a block driver's domain |
| an over-current change | the port's status | nothing | cleared and logged once; the port follows its status |
| a refused SYNCHRONIZE CACHE | the sense data | nothing: the flush is answered `ok` | none; a residual: what the device keeps after a flush then rests on the device |

The stack's state for inspection, each a path of the inspection schema
reported by the USB domain and shown under `/proc/usb`
([design.md](design.md#decisions)):

* `[usb, Controller]`: the controller's kind, ports, slots in use, queue
  blocks free of each kind, and restarts;
* `[usb, Controller, ports, Route]`: the port's state, speed, power and
  over-current, and its last failure with its step and reason;
* `[usb, Controller, devices, Route]`: the vendor and product ids, class,
  speed, the three strings, state, its functions each with its kind and
  its input number or drive, a refusal's reason, and counters of reports
  dropped, keys unmapped and resets.

Text a device supplied is a value of the record, escaped by whatever
sink shows it.

## Refusals and error results

| Call or input | Answer | When |
| --- | --- | --- |
| `erx_device:negotiate/2`, TRB form | `{error, ebusy}` | the controller does not halt, finish its reset or report ready within 1 s each |
| `erx_device:negotiate/2`, TRB form | `{error, enotsup}` | it asks for more than 64 scratchpad pages, or has more ports than the event ring's bound allows |
| `erx_device:negotiate/2`, TRB form | `{error, erange}` | `AC64` is clear and the record's memory lies above 4 GiB |
| opening an xHCI record | `{error, einval}` | `CAPLENGTH`, `RTSOFF` or `DBOFF` puts a register cluster or a port past the register window |
| `erx_device:post/4`, TRB form | `badarg` | a command or transfer of another shape; an input context of the wrong size or with a non-zero dequeue pointer; an isochronous endpoint; a length past the buffer; a setup whose length differs from its data stage |
| `erx_device:post/4`, TRB form | `{error, full}` | a command already in flight; no free buffer on the queue; no free block of the kind a command adds |
| `erx_device:post/4`, TRB form | `{error, halted}` | a transfer on a queue whose endpoint halted and is not yet past set TR dequeue pointer |
| `erx_device:post/4`, `complete/2`, TRB form | `{error, broken}` | an event failed the form's checks, until `negotiate/2` |
| `erx_usb_pipe` calls | `{error, gone}` | the pipe's device has detached |
| `erx_usb_pipe` calls | `{error, stall}`, `{error, timeout}`, `{error, {controller, Code}}` | the endpoint halted; no answer in 5 s; any other completion code |
| a drive grant's `window` | `{error, no_medium}`, `{error, no_partition}` | the drive holds no ready medium; the medium's table has no entry for the grant's partition that the removable-media rule serves |
| a window of a medium that has gone | no answer: the process has ended | the caller's monitor fires |
| the transport | `{error, {device, {sense, Key, Asc, Ascq}}}`, `{error, {device, reset}}`, `{error, {device, deadline}}` | a failed command; a reset recovery; the wait bound passed |
| a device at enumeration | refused, with `descriptor too long`, `malformed descriptor`, `unsupported speed`, `too deep`, `too many devices` or `endpoint too large` | the decoder or a bound |
| a function | not started, with `no input number`, `no drive`, `no usable report`, `not direct access`, `block length`, `max lun` | its place, its layout, its unit |
| the manifest check | the build fails | a window on a `usb` device with no drive, or a drive on another device; a drive named twice for one partition; more drives than `usb_drives_max`; a release manifest whose USB domain holds another unit or a file server |

## Verification

Each passing case below is paired with a seeded fault that must make it
fail, so a pass shows the code under test ran.

### Host tests of the cores

| Test | Passes when | Seeded fault that must fail it |
| --- | --- | --- |
| `erx_usb_bus_core`, explored exhaustively: every event in every reachable state to depth 10, over a root hub of two ports, one external hub of two ports and devices of one and two functions | every enabled slot belongs to a device whose port is enumerating or running; after a detach the device's reference, slot and places are gone; no action names a port that is `off` or `empty`; a connection is enumerated at most twice | the detach's disable-slot action dropped; `disabled` left on a deadline instead of a connection change |
| `erx_device_trb`, in C on the host, explored over two slots, three queues each, posts, completions of every code, command completions that succeed and fail, and disable slot, to depth 12; then under AddressSanitizer | a buffer returns to its pool only by a completion naming it, a command removing its queue, or install; every address a plan writes lies in the record; every decision passes `erx_device_dma_check`; the event bound's arithmetic holds | the TRB pointer's range check removed, so an event naming another queue's TRB retires a transfer still posted; the residue bound removed, so a copy passes its buffer |
| `erx_usb_desc` on the boot devices of HID 1.11 Appendix B and E, and on the descriptors QEMU's `usb-kbd`, `usb-tablet`, `usb-storage` and `usb-hub` return, captured once into small fixtures | each decodes to the expected interfaces and endpoints | the walk run over the bytes received instead of `wTotalLength`, with an interface descriptor in the trailing bytes, which is then claimed |
| `erx_hid_desc` against FreeBSD's `hid.c` compiled on the host as the oracle, over the fuzz corpus, comparing each input field's offset, size, count and usage | every descriptor either parses to the same fields as FreeBSD's or is refused by both | the push-depth bound removed: a descriptor of five pushes is accepted |
| `erx_hid_core` | a keyboard's held set gives ups then downs in code order; a rollover report changes nothing; an absolute position normalizes to 0 and 65535 at its range's ends | the ErrorRollOver check removed |
| the usage table | `abi/formats/hid.txt`'s map equals FreeBSD's `evdev_usb_scancodes`, read from the pinned source | one map entry changed |
| `erx_usb_bot_core`, explored exhaustively, and a table of BOT 1.0's thirteen cases (section 6.7) | after an invalid CSW the next three actions are the reset and the two clears in order; no command starts while one is in flight; a CSW whose tag is not the CBW's resets | the tag check removed |
| `erx_blk_write`'s BOT functions on a trial boot value | a WRITE(10) is refused `erofs` and nothing is sent | the trial check removed |
| the places, a property test over attach, detach, crash and restart sequences | each input number carries `release` between occupants; no window pid serves two media; a drive answers `no_medium` exactly while no medium is ready | `release` skipped on a crash; the window process kept across media |

The chokepoint rules carry their own seeded violations: a module of
`erx_usb` other than `erx_xhci` calling `erx_device:post/4`, and a module
other than `erx_blk_write` calling `erx_usb_pipe:bulk_out/3`.

### Fuzz targets

Each lands with its parser and builds the same sources for the host; the
Erlang ones run on the host's stock OTP, as the FAT decoders do:

* `erx_usb_desc`: device, configuration (interface, endpoint, HID, hub
  and SuperSpeed companion descriptors), language table and string;
* the hub's and the root hub's port status and change words;
* `erx_hid_desc`, the report descriptor;
* `erx_hid_core`, a report against a layout taken from the corpus;
* the BOT core's CSW, and the INQUIRY, READ CAPACITY(10) and (16) and
  REQUEST SENSE decoders;
* `erx_xhci_core`'s event status decoder and the extended-capability
  walk over fuzzed register values;
* `erx_device_trb`'s completion, in C, over a fuzzed event ring: the one
  C reader of memory a USB controller writes;
* `erx_dwc2_core`'s channel interrupt and receive-status decoders.

### QEMU suites

* **`usb` on QEMU `virt`**, once the PCIe domain exists: `qemu-xhci` with
  `usb-kbd`, `usb-tablet` and `usb-storage` over a raw image, and a
  `usb-hub` with a second keyboard behind it. Cases: the inspection
  records show each device, class and speed; keys sent with QMP's
  `input-send-event` arrive as `kbd` records in a test window; tablet
  positions arrive normalized; a raw window client reads known sectors,
  writes and reads back, and flushes; `device_add` and `device_del` of a
  keyboard while keys are held release them; `device_del` of the stick
  during writes ends its windows; a `restart` written to the controller's
  `/dev` `ctl` mid-typing releases every key and enumerates again.
  Seeded: SET_CONFIGURATION skipped, which must fail the typing case.
* **`usb` on QEMU `raspi4b`**, on the stopgap under TCG: DWC2 with
  `usb-kbd` and `usb-tablet` behind QEMU's hub, and `usb-storage` once
  probe 6 shows it attaches; the same cases. Seeded: the hub function's
  port power-on dropped, which must fail enumeration.
* **The FreeBSD oracle**, at the milestone gate: FreeBSD 15.1's QEMU
  image, the command shell's oracle guest already, boots on QEMU `virt`
  with the same devices, each with `pcap=` set, as does erXos. Every
  control request and SCSI command erXos sends a device is one FreeBSD
  sends it during attach, in the same relative order; the sectors read
  are equal; and the evdev codes FreeBSD reports for a scripted key
  sequence are the codes erXos's records carry.
* **A hostile device**, optional until a probe shows QEMU's `usb-redir`
  is built into the supported QEMU and the protocol's facts are
  gathered: a host test tool on the redirection channel plays a device
  whose descriptors, reports and CSWs are malformed, and the case passes
  when only that device's function or port ends.

Probes, each recorded in the facts record: the capability registers of
`qemu-xhci` (3); MSI against MSI-X (4); `usb-storage` under `raspi4b`'s
DWC2 (6); hotplug and its port events (7); the IOMMU stream (8); a `pcap`
reference of FreeBSD's enumeration (9); whether QEMU's DWC2 model runs
slave mode (10); and `usb-redir` (11). On a Pi 4 board: configuration
register `0x50` at erXos's start; the PCIe link as the firmware leaves
it; DMA above 960 MiB; and whether a narrowed inbound window blocks the
VL805 outside it.

## Performance

Unmeasured costs, each on [the watch list](todo-performance.md):

* DWC2's FIFO, one register access per 32-bit word on the controller
  process's core;
* the controller process as the one path for every transfer of its
  controller, and the TRB form's completion cost per event;
* a key's latency from the controller's interrupt to the router's step,
  through the controller, the function, the stream and the display's
  reader;
* mass-storage throughput at 64 sectors a request against FreeBSD's on
  the same QEMU device.

## Alternatives considered

* **A file per HID device and an arrival stream**, as 9front's `usbd`
  announces devices: the display would need an arrival protocol and a
  reader's life per device. Input numbers make arrival invisible, and
  `release` already says what a device's departure means.
* **One merged input file**, with the USB domain counting each key's
  holders across devices: it copies the router's per-source bookkeeping
  into the USB domain. Input numbers leave that bookkeeping where it is.
* **A window that stays while media change beneath it**, with a medium's
  identity in every request: every caller carries an obligation that a
  window ending with its medium removes.
* **Media as files**, `da0s1` in the USB domain's tree, as FreeBSD's
  `/dev/da0s1`: UNIX-like, but a second form of the block service, with
  its own partition reading, bounds and write path. The block service
  exists; drives reuse it.
* **USB devices in the catalogue**, given to other domains at run time:
  hotplug would cross every domain boundary and the unit rule would need
  an exception.
* **Class drivers in the consuming domains**, a HID driver in the display
  domain over a transfer facet: a live protocol per transfer, while the
  controller's domain must parse descriptors anyway.
* **xHCI through `region/3`**, Erlang writing TRBs into a region:
  addresses would reach Erlang, and `region/3` is refused on a device
  that is not coherent.
* **A native xHCI driver**, FreeBSD's `xhci.c` as a sub-space port: no
  measurement admits it, and without a row of the driver table none runs.
* **DWC2 by DMA**, through a channel form: it would make the DWC2 a bus
  master for nothing QEMU's tests need; a form for it waits for a board
  whose only host is a DWC2.
* **The boot protocol alone for HID**: the boot mouse is relative, so
  QEMU's tablet and every absolute pointer would be lost.
* **UAS**: FreeBSD has no UAS driver at the pin to translate, and the
  specification is T10's, not obtained.
* **xHCI only, no DWC2**: USB would wait for a PCIe domain on every
  platform; [Open decisions](#open-decisions) keeps the choice.

## Open decisions

1. **DWC2 in scope.** Keep DWC2 host mode by programmed I/O on QEMU's
   `raspi4b`, the only USB the stopgap can reach, or drop it and let USB
   wait for PCIe. Recommendation: keep it, within the scope of
   [DWC2](#dwc2-on-qemu-raspi4b); it carries the core, HID and mass
   storage through Phase 1, and no board needs more of it.
2. **xHCI on QEMU `virt` in Phase 1.** Bring a PCIe enumerator onto the
   stopgap for QEMU `virt`, with its MSI frame's interrupt bound as a wired
   line, which Fiasco offers, and unconfined DMA in development builds,
   or wait for M9's kernel part. Recommendation: wait; DWC2 exercises
   the stack meanwhile, and QEMU `virt` already has virtio input.
3. **The Pi 4's USB on the stopgap.** Write the Pi 4 bridge's design now
   and run the VL805 as a part of 1b-I, which needs the Phase 1 manifest
   check to admit a Pi 4 PCIe domain, or leave Pi 4 USB to M12 on
   erXos's kernel. Recommendation: the design now and the 1b-I part,
   since a USB keyboard is the Pi kiosk's missing input device and the
   bridge raises wired lines the stopgap can bind.
4. **Loading the VL805's firmware when the boot firmware has not.**
   Add a narrow kernel operation that sends the mailbox's
   `NOTIFY_XHCI_RESET` for the one PCI address the platform names,
   requested by the PCIe domain, or require a boot configuration under
   which the firmware loads it, or have no USB on such boards.
   Recommendation: probe first; if needed, the kernel operation, which
   sends one fixed tag with a checked value and reads nothing back, so
   PL2's reason, that the mailbox reads the device key, still holds.
5. **The xHCI specification.** Intel's site refuses a plain fetch.
   Recommendation: fetch it by hand before the TRB form is implemented,
   to settle the statements marked unverified (EP0's default packet
   sizes, at most one change event per port, and whether a STALL halts
   EP0 on xHCI as it halts other endpoints).
6. **A clean-room facts record** of Linux's `pcie-brcmstb` for the
   BCM2711, the VL805's handling in Linux's xHCI driver, and the Pi 4's
   device-tree nodes for PCIe, the DWC2 and the USB-C xHCI.
   Recommendation: commission it before the Pi 4 bridge's design.
7. **The USB-C xHCI of `otg_mode=1`** as a Pi 4 bring-up path with no
   PCIe, the board powered through its header. Recommendation: only as a
   bring-up aid, if the facts record shows a memory-mapped controller
   with a wired line; it is not a path a user can use.

Left for later and recorded when code lands, since each fails safe by
being absent: consumer-page keys and digitizers in HID, keyboard LEDs,
SuperSpeed hubs, media whose blocks are not 512 bytes, a medium with no
partition table, CBI and UAS.

## The research questions

The facts record's open questions, and where this design answers them:

| Question | Answer |
| --- | --- |
| 1. Which controller first | DWC2 on QEMU `raspi4b`, on the stopgap; then xHCI on QEMU `virt` with the PCIe domain; then the VL805 ([The proposed order](#the-proposed-order); decisions 1 to 3) |
| 2. A PCIe domain for the Pi 4, and who sends `NOTIFY_XHCI_RESET` | yes, for any Pi 4 USB-A; only the kernel may send it (PL2), and only if a board probe shows it is needed (decision 4) |
| 3. xHCI in the device NIF | a fourth descriptor form; `region/3` is not needed ([The TRB ring form](#the-trb-ring-form)) |
| 4. Run-time devices and the manifest | the drivers run in the controller's domain; input numbers and drives are fixed places granted by the manifest; arrival never leaves the domain ([The construction](#the-construction)) |
| 5. HID scope and the usage table | the report descriptor parser from the start, boot protocol as its fallback; the table in `abi/formats/hid.txt` from FreeBSD's `evdev_usb_scancodes`, checked against it ([HID](#hid)) |
| 6. Mass-storage scope and quirks | BOT and the SCSI transparent set; a command subset that leaves most quirks nothing to fix, and no quirk table until a device needs one; a refused SYNCHRONIZE CACHE as FreeBSD handles it ([Mass storage](#mass-storage)) |
| 7. Translate FreeBSD or redesign | translate the decisions, not the structure ([What is matched](#what-is-matched)) |
| 8. The Pi 4's DMA | the VL805's domain in the trusted base, alone in a release build; memory below 960 MiB and 32-bit; confinement by the inbound window a board probe ([The VL805](#the-vl805-on-the-raspberry-pi-4)) |
| 9. Port power and over-current | every port powered; an over-current change cleared and logged, the port following its status; no software budget ([Ports, hubs and devices](#ports-hubs-and-devices-the-bus-core)) |
| 10. Oracles and fuzz targets | FreeBSD as guest with `pcap=`, FreeBSD's `hid.c` and usage table on the host, and the fuzz targets listed ([Verification](#verification)) |
| 11. The xHCI specification and a clean-room record | decisions 5 and 6 |

## References

FreeBSD, `https://git.freebsd.org/src.git` at `release/15.1.0-p6`,
commit `95719d8a895bf8170851e9844d9b4092b1d2b6fe`, BSD-2-Clause but for
the ISC-licensed `bcm2838_xhci.c` and `bcm2838_pci.c`; SHA-256
of each file read:

```
ad6b745a07c7aa2d227f22f9839ce26fe2162df7cb2c4a41b815e5ba66d24a60  sys/arm/broadcom/bcm2835/bcm2838_xhci.c
10a983496e957f3cf01039f5076e189a817bdfc5da53e582f42dad525d1ac6a9  sys/arm/broadcom/bcm2835/bcm2838_pci.c
5155a952be0086a45df81895cd4fd99244ce48a322347108a756d43731cdca73  sys/arm/broadcom/bcm2835/bcm2835_mbox.c
5fddd7a02c70f4a014d65e5e6a3e20d9e69f77e961c035ba975572310350136f  sys/arm/broadcom/bcm2835/bcm2835_mbox_prop.h
572b55dedf2fbab549ecbaeb8b51f67e5729c7ccba46df52b360688c2c979b12  sys/dev/usb/controller/xhci.c
da0cf72e76e914d33be091df552b997e38059dfb12c324fe059b2213859225eb  sys/dev/usb/controller/xhci.h
aa6a4db443f69c08e708a45e754f5259cfc6cf8260aef1bd18239af69a25a13d  sys/dev/usb/controller/xhcireg.h
d13585891d30fd9171c4c75929a2aa3e48a1bcf7dad6f791871247fbc02a779a  sys/dev/usb/controller/xhci_pci.c
0c3330881ca3e22a843e610abac7f60e6c33b6cd3cb84526238e25b5b65909ed  sys/dev/usb/controller/dwc_otg_fdt.c
39c3041ed59517b5bfa516d2762dc5c6aaa5c3445005fd4b26501ac9a340009e  sys/dev/usb/controller/dwc_otgreg.h
ed340cc3fac91ce3f5b4919dad6436945dfa576324d97dbabd10ec9c7cf3f8c3  sys/dev/usb/controller/usb_controller.c
ee2f2d2e61b7da5fdb0cebc5b90ed21eb9b1c9ef5006e7b2efb7d48e0416d630  sys/dev/usb/usb_controller.h
36e0749c8dc237d607c9df9e5483b359b945328e21e388f4fbd976be72092e63  sys/dev/usb/usb_parse.c
2925610b09ad2d943d3e3ff1e6615483268f4c302689efe1331cdd59b99bc4c7  sys/dev/usb/usb_request.c
428127cba412a74c6aa14b96243ffb00eadd70d4a6e2a8e204aaf5f91a213035  sys/dev/usb/usb_device.c
7239012ed2ff4b5f457ca6a6114153330ec7d2c547a96bf3618e13fa2a91248a  sys/dev/usb/usb_hub.c
dfa245e576b4b29b7f0e828e289487afd6ae28e18221f418d4177432b13f99f4  sys/dev/usb/usb.h
f0baac345bac382f2a3543d2dfd136c32a8545a5fe14bd4159fb3982dcb64f4a  sys/dev/usb/storage/umass.c
5529e9eadd267cc629973ec26151c630ff3438d6c807bba4f9e353b46e0a9657  sys/dev/usb/input/usbhid.c
ae672e0c95a0a58650547725266b53ea1808ca3967ccd3f3822d1bc65c85589d  sys/dev/hid/hid.c
34a08de096120fc7f0b8d8deee3cf69037d7b953e97966ecb675cc486ba33a3f  sys/dev/hid/hkbd.c
a91849f3a871cac42ba1186bd34ab68779174b618bfe86f0fe916b49b0bfcc2a  sys/dev/evdev/evdev_utils.c
71c02b2ee77c5108e38e3e1019ca27d51965088f99e6eca4cbff0e8e978cc620  sys/cam/scsi/scsi_all.h
9bd577988d2ba9cccca593a8d7315886703f34440d66a625d019ab5714b4afbd  sys/cam/scsi/scsi_da.c
```

and, in the same checkout:

```
f1344bb3d4261679a141680a3532347115611673fc4afe3fcc7db57e73db1fb8  sys/dev/usb/usb_transfer.c
b866d807069181cb437b2cfa73a860cbd76517e13156b7c50f4222c824fbec36  sys/dev/usb/usbdi.h
6f685cc1f5bb2600bf06f23cc8c7d9b8cab9d0af59ce5384433ed4a59f8afbe4  sys/dev/usb/usb_freebsd.h
aa7cf55389300ddfc9ba8151e6ef019cea626f7178269e40067b9edfe6afb0f5  sys/dev/usb/controller/dwc_otg.c
88d16858fdece81a4be7bccb6030a4ff7633b16390336802655751792f38128b  sys/dev/usb/controller/dwc_otg.h
dca3afd10b022f053638977978e1105c99bcc4d00e84273fe3e34b9d70485f34  sys/dev/hid/hms.c
```

usb.org specifications, fetched 2026-11-13 without click-through:

```
32d5694aa5870b93117aca97f21f3db4943c7ff8288d3a15ceee3feaf4fdec71  hid1_11.pdf (Device Class Definition for HID 1.11, https://www.usb.org/sites/default/files/documents/hid1_11.pdf)
f4ead217b01134f89199155ed616d4eeae9ad40a5f73dad9544002b592c07db3  hut1_5.pdf (HID Usage Tables 1.5)
9137e8eefaf366ba32c7f081719a75a403c48004d47f4252ec36d711dda84a23  usbmassbulk_10.pdf (Mass Storage Class Bulk-Only Transport 1.0)
349a15d4283e4a744ee8bce569d6efd5f447e9ea993c03e6fcd9e9d1674d8491  Mass_Storage_Specification_Overview_v1.4_2-19-2010.pdf
```

QEMU 11.1.3's documentation,
`https://gitlab.com/qemu-project/qemu/-/raw/v11.1.3/<path>`:

```
13c4c6116e3ea270b39b0ccdfa7a962d8d5aedee6646e3c84bf0de98f9088bd3  docs/system/devices/usb.rst
9fbcc9fc3040ef695e3058cd4bab05e10f6282ab7ba0846a93ee9f524933e3e1  docs/system/arm/virt.rst
379cf16708455fe77de384fea8af12bbde68e66a49610976f3b64b7b7b9931d7  docs/system/arm/raspi.rst
```

Raspberry Pi documentation, `https://github.com/raspberrypi/documentation.git`
at `c6a64966af136da21a1e55551c5a395cb6987fce`, under
`documentation/asciidoc/computers/`:

```
b5ee38f0c0ea1c80896ff4bff0518d007694812f966cf0506c2ac9606d082721  raspberry-pi/usb-bus-on-raspberry-pi.adoc
d4be7bf9a1e29c09c4592176d04cd8bc4ff146d8f38fe03108e738fa5aa1fee3  config_txt/boot.adoc
57039700ff6803f9977bdd206ba2814b62618910730aa9a1fa4550b02ec6ad08  raspberry-pi/boot-eeprom.adoc
```

The facts record behind this design, with the QEMU probes and the
questions it left open, is kept outside the tree with the other research
notes of this design.

