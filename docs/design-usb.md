# USB: host controllers, HID and mass storage

This document is erXos's USB host stack: which domain holds a USB host
controller, how the USB core in that domain finds, configures and serves
the devices behind it, the xHCI driver for the two controllers erXos
meets first, QEMU `virt`'s `qemu-xhci` and the Raspberry Pi 4's VL805,
the PCIe domain both of them sit behind, the HID and mass-storage class
drivers, and how what they produce reaches the display's input router and
the storage domains' file servers. It refines the drivers, devices and
PCIe enumerator of [design-system.md](design-system.md#devices), the
device NIF of [design-runtime.md](design-runtime.md#the-device-nif), the
descriptor forms of
[design-device-dma.md](design-device-dma.md#the-descriptor-forms),
the input records of [design-display.md](design-display.md#input-events)
and the block service of [design-storage.md](design-storage.md#data-model).

Decisions every reader needs:

* **Hotplug ends at the controller's domain.** A USB device lives, from
  its attach to its detach, inside the domain that holds its host
  controller, as a sub-device of the controller's unit
  ([design-system.md](design-system.md#devices), Units). What crosses a
  domain boundary is fixed by the system manifest and outlives every
  device: a fixed set of **input numbers**, each a file of input records
  the display reads, and a fixed set of **drives**, each a grant through
  which a storage domain's file server reaches whatever medium the drive
  holds. A device's arrival or departure changes what an input number or
  a drive carries, never which grants exist.
* **A name dies at once; hardware is freed only on the controller's
  report.** A device's reference, a medium's reference and the windows of
  a medium end the moment the device or the medium ends, so no request
  made through them reaches whatever comes next. The slot, rings and
  buffers the controller used for the device go back to their pools only
  when the controller itself reports that it holds nothing of them: a
  stopped endpoint, a disabled slot, a completed transfer.
* **One owner, one pure step.** The controller process owns the
  controller and every endpoint's lifecycle, recovery and removal
  included; the bus process owns the topology; each function process
  owns one interface, and a mass-storage function owns its media. Each
  decides by a pure function of its state and an event and performs the
  actions it returns.
* **FreeBSD's decisions, redesigned; not its structure.** Enumeration and
  hub handling, xHCI's command, event and recovery handling, HID's item
  parser and its bounds, the usage-to-evdev table and BOT's transfer
  states come from FreeBSD at `release/15.1.0-p6`
  (`95719d8a895bf8170851e9844d9b4092b1d2b6fe`), and each Erlang function
  that takes a decision from one names the FreeBSD function it comes
  from. Intel's xHCI 1.2 specification settles what FreeBSD's code
  leaves implicit. The BCM2711 bridge's bring-up and the VL805's
  handling follow the clean-room facts record of Linux's and FreeBSD's
  drivers ([Sources](#sources)), which gives the vendor's sequence where
  FreeBSD's differs.
* **xHCI is a fourth descriptor form of the device NIF.** Its rings,
  contexts and scratchpad are memory the NIF lays out once and owns;
  every address and every field that changes how the controller reads
  memory is the NIF's, built from bounded parameters the driver names.
  Erlang chooses requests, sequences commands and parses what the
  controller and the devices wrote.
* **PCIe first, on both targets.** The first scope is a PCIe domain on
  QEMU `virt` and on the Raspberry Pi 4 and one xHCI driver for both
  controllers. On Fiasco, QEMU `virt`'s controller interrupts by MSI
  through its MSI frame, whose lines Fiasco binds as wired ones, and the
  Pi 4's VL805, the one function behind its bridge, by its INTx line,
  which the board's tree routes to a line of its own, apart from the
  bridge's two. The Pi 4's bus is the one place erXos admits INTx: its
  platform record fixes the bus's one position, so the line's sharers
  are known when the manifest is written; every other PCIe function
  interrupts by MSI ([Interrupts](#interrupts)). DWC2 on QEMU `raspi4b`
  is outside this design, planned work in `TODO.md` ([DWC2](#dwc2)).
  The order is [plan.md](plan.md#track-u-usb)'s.
* **The Pi 4 boots from its microSD card alone.** The board's EEPROM
  boot order names no USB device and no network boot, so the boot
  firmware has no reason to start the VL805. A VL805 the firmware left
  running anyway is part of the trusted loader until the PCIe domain's
  start clears its bus mastering and the xHCI driver resets it; its
  buffers and descriptors are installed only after that reset, and the
  window before it, in which it may write memory the kernel has handed
  out, is a [Medium] security residual
  ([The boot firmware's handover](#the-bcm2711-bridge)).

## Context

### What is matched

erXos follows FreeBSD where UNIX systems differ, and its USB host stack
behaves like FreeBSD 15.1's for the devices in scope: a keyboard, a mouse
or a tablet types and points as it does under FreeBSD's `usbhid` and
`hkbd`, and a USB stick reads and writes as under `umass` and `da`.
Only the behavior is FreeBSD's: erXos names a drive `disk0`, `disk1`, ...
for what it is, not `da` after FreeBSD's SCSI disk driver. The
evidence each part rests on:

* **Enumeration and hubs.** FreeBSD's `uhub_reattach_port`
  (`sys/dev/usb/usb_hub.c:599-860`) frees the port's old device first on
  any connection change (`:625-633`, called from `uhub_explore` whenever
  the change bit is set, `:1080-1084`), waits the power-up time, resets
  the port, takes the speed from the status, and calls `usb_alloc_device`
  (`usb_device.c:1752`), which sets the address (`:1908`), reads the
  device descriptor (`:1950`), sets the configuration (`:2019`) and
  attaches interface drivers (`usb_probe_and_attach`, `:1456`); on any
  failure it frees the device and disables the port until its connection
  changes (`usb_hub.c:820-839`). A port reset clears the reset change,
  sets the reset feature, polls the status every 50 ms until the reset
  change or the reset bit's end, gives up when the device disappears or
  after 1 s, clears the change and waits 20 ms of recovery
  (`usbd_req_reset_port`, `usb_request.c:805-863`). Its timing allows
  for marginal devices: a 300 ms power-up delay, a 200 ms root-port
  reset, 20 ms of reset recovery, a 10 ms settle after SET_ADDRESS and
  20 ms of extra power-up time, against the specification's 100, 50, 10,
  2 and 0 ms (`usb.h:104-125`). A hub's ports are powered at attach and
  given the hub's own power-on-to-good time, `bPwrOn2PwrGood` times
  2 ms plus the extra 20 ms (`usb_hub.c:1280-1281`, `:1512`); a
  multi-TT hub (device protocol 2) is switched to its alternate setting 1
  before anything else (`:1252-1258`). A request times out after 5 s
  (`USB_DEFAULT_TIMEOUT`, `usbdi.h:88`). Hubs nest at most five deep
  (`USB_HUB_MAX_DEPTH`, `usb_freebsd.h:90`), which is also what the
  20-bit route string of an xHCI slot context holds, four bits a tier.
* **Descriptors.** A configuration descriptor's `wTotalLength` must be at
  least its header (`usb_request.c:1294`); each descriptor of the walk,
  and the one after it, must lie inside that length, and a `bLength`
  below 3 ends the walk (`usb_desc_foreach`, `usb_parse.c:73-110`).
* **xHCI.** Intel's xHCI 1.2 specification (May 2019) and FreeBSD's
  `xhci.c`. The controller owns a TRB once its cycle bit matches the
  controller's cycle state, doorbell or not (section 4.9.2, p. 170).
  Every transfer error halts its endpoint, EP0's STALL included (4.10.2
  and 4.10.2.1, pp. 195-196). A control transfer is a setup, an optional
  data and a status TD, each of its own; a short data stage gives one
  event and the status stage another, and only the event of a TD's last
  TRB completes it (4.10.1.1.2, p. 193; 4.11.2.2, pp. 212-214). Stop
  Endpoint on a ring that is not halted always produces a transfer
  event before its command completion (4.6.9, pp. 134-135): Stopped or
  Stopped - Short Packet inside a TD, and otherwise a forced Stopped -
  Length Invalid event naming wherever the controller's dequeue pointer
  rests, which Table 4-2 (pp. 137-139) lists: the last TRB of a TD the
  controller has already completed, and reported with its own event; a
  Link TRB; or the first TRB the controller has not been given, the
  ring's enqueue position. A Stop Endpoint keeps a TD's partial state;
  aborting a TD takes Set TR Dequeue Pointer afterwards (p. 134).
  Configure Endpoint ignores EP0, whose add and drop flags must be clear
  (4.6.6, p. 116), so EP0 is never dropped and added. An Address Device
  that fails with USB Transaction Error behind a transaction translator
  needs a CLEAR_TT_BUFFER to that translator's hub (4.6.5, p. 115).
  The controller interrupts only with both `USBCMD.INTE` and the
  interrupter's `IMAN.IE` set (4.2, p. 82), and a host controller reset
  returns every operational register, `INTE` included, to its default,
  0 (5.4.1, p. 394). A periodic endpoint's payload per service
  interval, from which the controller reserves its bus time, goes by
  speed: a USB 2 endpoint's is its packet size times its burst plus
  one, the burst being zero-based, and a SuperSpeed endpoint's is its
  companion descriptor's `wBytesPerInterval`, at most 3 KiB for an
  interrupt endpoint (4.14.2, p. 259; 6.2.3.4, p. 455; 6.2.3.8,
  p. 457).
  Reset Endpoint is valid only on a halted endpoint; a pipe's reset is
  Reset Endpoint, CLEAR_TT_BUFFER to the transaction translator's hub for
  a control or bulk endpoint behind one, CLEAR_FEATURE(ENDPOINT_HALT) for
  any endpoint but a control one, then Set TR Dequeue Pointer; a toggle
  of an endpoint that is not halted is reset by dropping and adding it
  with Configure Endpoint (4.6.8, pp. 129-132). Disable Slot requires
  every endpoint of the slot stopped or idle and its events received
  (4.6.4, pp. 109-110). A root port raises one port event until every
  one of its change bits is cleared (4.19.2, pp. 320-322). FreeBSD's
  event loop walks the event ring by its cycle bit and writes the
  dequeue pointer back with the busy bit (`xhci_interrupt_poll`,
  `xhci.c:1115-1200`); it chooses a pipe's recovery by the endpoint's
  state (`xhci_configure_reset_endpoint`, `xhci.c:3880-3960`); and it
  publishes a transfer by flushing the chain before toggling the cycle
  bit that activates it (`xhci.c:3010-3043`).
* **HID.** HID 1.11 defines the boot interface (subclass 1, protocol 1
  keyboard, 2 mouse; section 4.3), the class requests (section 7.2), the
  rule that the host sets the protocol it wants (section 7.2.6), reports
  that span several transactions (section 8.4), and the boot reports
  (Appendix B): the boot mouse reports buttons and **relative** X and Y
  only (Appendix B.2), so an absolute pointer such as QEMU's `usb-tablet`
  needs the report descriptor. A keyboard reports the keys held, not
  their edges, and reports ErrorRollOver in every array field when more
  keys are held than it can report (Appendix C). FreeBSD's item parser
  bounds a main item's usages to 64, its push stack to 4 levels, the
  current one included, its report ids to 16 and a report count to 2048
  (`MAXUSAGE`, `MAXPUSH`, `MAXID`, `MAXLOCCNT`, `hid.c:66-69`), and stops
  parsing, as at the descriptor's end, at a fourth nested push
  (`hid.c:446-450`). FreeBSD sizes the interrupt transfer from the
  report descriptor's largest input report (`usbhid.c:380-384`), and its
  keyboard driver clears and sets only the keys of the report id it
  received (`hkbd.c:706-745`). FreeBSD maps a keyboard usage to an evdev
  key through one table of 256 entries (`evdev_usb_scancodes`,
  `evdev_utils.c:44`; `evdev_hid2key`, `:221`).
* **Mass storage.** The Mass Storage Specification Overview 1.4 assigns
  subclass 06h to the SCSI transparent command set and protocol 50h to
  Bulk-Only Transport (Tables 1 and 2). BOT 1.0 fixes the CBW and the
  CSW, the two class requests, the status flow (section 5.3.3, Figure 2),
  what makes a CSW valid (section 6.3.1) and meaningful (section 6.3.2),
  Reset Recovery (section 5.3.4), and the residue: for data out the
  bytes expected less those the device processed, for data in the bytes
  expected less the relevant bytes it sent (section 5.2, p. 15).
  FreeBSD's BOT is a nine-state transfer machine (`umass.c:185-194`)
  whose CSW checks follow the specification (`umass.c:1555-1620`).
  FreeBSD's disk driver polls a removable medium every 3 s
  (`DA_DEFAULT_POLL_PERIOD`, `scsi_da.c:1561`, `:3060-3065`), and when a
  device refuses SYNCHRONIZE CACHE with ILLEGAL REQUEST it reports that
  flush done and sends no more (`daerror`, `scsi_da.c:6249-6254`;
  `cmd6workaround`, `:4448-4457`). erXos keeps the second decision and
  not the first: it sends no more, and it never reports the flush done
  ([The SCSI subset](#the-scsi-subset)).
* **PCIe.** FreeBSD's BCM2711 bridge driver, `bcm2838_pci.c` (ISC), and
  its generic host driver, which reads a bridge's three-cell `ranges` and
  routes a function's INTx pin through the bridge's `interrupt-map`
  (`pci_host_generic_fdt.c:179-230`, `:246-276`). Its VL805 driver checks
  the firmware register and asks the VideoCore to load it
  (`bcm2838_xhci.c:113-175`). FreeBSD's xHCI attach takes MSI-X, then
  MSI, then the INTx line (`xhci_pci.c:357-393`). The clean-room facts
  record of the BCM2711's bridge and the VL805 ([Sources](#sources))
  gives the vendor's bring-up as Linux's driver runs it, the PCIe rule
  of 100 ms between PERST#'s release and the first configuration
  request (facts record, section 1, step 6c), the CPU abort that a
  configuration access with the link down causes (section 3), the
  VL805's loss of its firmware at every PERST# (section 6), the VL805's
  xHCI quirks in Linux's two trees (section 5), and the differences from
  FreeBSD (section 8).

### The hardware

**QEMU `virt`.** Its USB host controllers are all PCI functions: `-device
help` lists `qemu-xhci`, `nec-usb-xhci`, `usb-ehci`, the ICH9 and PIIX
UHCIs and `pci-ohci`, and no memory-mapped one (probe of the facts
record, QEMU 11.1.3). `qemu-xhci` is PCI `1b36:000d` with one 64-bit
memory BAR, MSI-X alone with its default properties (16 vectors in BAR
0, no MSI capability; [the QEMU facts
record](research-qemu-pcie-usb.md#qemu-xhci)), four USB 2 and four USB
3 ports; QEMU's
documentation calls xHCI "the only controller you need"
(`docs/system/devices/usb.rst:12-26`). With `usb-kbd`, `usb-tablet` and
`usb-storage` attached, the keyboard and the tablet enumerate at 480 Mb/s
and the stick at 5000 Mb/s. Its capability registers are read at run
time. The machine has an ECAM PCIe bridge and an MSI frame
([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)), which the harness
gives TCG and HVF alike
([design-platforms.md](design-platforms.md#msi-frames)).

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
(`bcm2838_xhci.c:22-27`, `:69`, `:113-175`;
`bcm2835_mbox_prop.h:110-126`). PERST# resets the VL805 and with it its
firmware, so the notification follows every PERST# cycle (facts record,
section 6). FreeBSD drives its DMA as 32-bit, "a limitation of the PCI-e
controller, not the VL805" (`bcm2838_xhci.c:191-192`). The board's tree limits
inbound DMA to the low 3 GiB, because the wrapper around the PCIe block
reaches no further, while FreeBSD keeps PCIe DMA below 960 MiB because
it saw corruption above and calls the true limit unclear
(`bcm2838_pci.c:92-106`; facts record, section 2). Only the kernel reaches the mailbox, since any
code that can reach it can read the board's device key
([design-platforms.md](design-platforms.md#device-secrets), PL2). The
BCM2711 has no IOMMU ([design-platforms.md](design-platforms.md#dma)).
QEMU's `raspi4b` lacks the PCIe root port
(`docs/system/arm/raspi.rst:30-45`), so the VL805 runs only on a board;
that model's USB is a DWC2, which [DWC2](#dwc2) covers.

**Fiasco.** A line's IRQ object is the root's alone to make.
Fiasco's own MSI support on this architecture serves a kind of
interrupt controller that neither accelerator offers (its MSI source
under `fiasco/kernel/src/kern/arm/`). QEMU `virt`'s MSI frame raises
ordinary wired lines, which Fiasco binds as it binds any line, so the
root can make an MSI as it makes a line; [The Phase 1 part](#the-phase-1-part)
says what the backend and the Phase 1 manifest check do with it
([design-fiasco.md](design-fiasco.md#the-phase-1-manifest-check)).

### What it builds on

* drivers as supervised Erlang processes over the device NIF, registers
  by name from CMSIS-SVD files, and interrupts as messages
  ([design-system.md](design-system.md#drivers));
* the PCIe enumerator in a domain that holds configuration space and
  nothing else, its reports to the device service, and the give that
  carves BARs inside the bridge's windows
  ([design-system.md](design-system.md#devices));
* the device NIF's queues, posting and completion, its sequencer and its
  check ([design-device-dma.md](design-device-dma.md));
* the unit rule, by which devices that share a page or a line go whole
  to one domain and a sub-device never crosses a domain
  ([design-shared-devices.md](design-shared-devices.md#the-unit-rule));
* the input records and the router, and the file of records another
  domain serves the display
  ([design-display.md](design-display.md#the-display-device));
* the block transport contract, the write path and its trial rule (U4),
  the block service's windows ([design-storage.md](design-storage.md)),
  and the media domain, which turns a drive's medium into files
  ([design-drives.md](design-drives.md));
* the three homes of a new need: an inspection path, a file tree, a
  declared protocol ([design.md](design.md#decisions)).

### Sources

FreeBSD's source at `release/15.1.0-p6`
(`95719d8a895bf8170851e9844d9b4092b1d2b6fe`), from
`https://git.freebsd.org/src.git`: `sys/dev/usb` (the core, `controller/`,
`storage/umass.c`, `input/usbhid.c`), `sys/dev/hid`,
`sys/dev/evdev/evdev_utils.c`, `sys/dev/pci/pci_host_generic_fdt.c`,
`sys/cam/scsi` and `sys/arm/broadcom/bcm2835`, each file with its
SHA-256 in [References](#references). Intel's xHCI Requirements
Specification, Revision 1.2, May 2019, obtained by hand and read as a
reference; nothing of it is copied into the tree. The usb.org class
specifications (HID 1.11, HID Usage Tables 1.5, Mass Storage Bulk-Only
Transport 1.0, Mass Storage Specification Overview 1.4), QEMU 11.1.3's
documentation and the Raspberry Pi documentation at the commits listed
there. The USB 2.0 and 3.x base specifications were not obtained; where a
statement rests on them alone it is marked unverified. No GPL source was
read for this design: not Linux, not QEMU's C, not U-Boot, not Linux's
device trees. What Linux's BCM2711 bridge driver, its VL805 handling and
the Pi 4's device trees hold comes from one clean-room **facts record**,
written by a separate agent from mainline Linux v7.3.4, the Raspberry Pi
tree's `rpi-6.18.y` at `ea17ae02ca28483e508b05c7c44190c01a1ef8eb` and
FreeBSD's `releng/15.1` at `95719d8a895bf8170851e9844d9b4092b1d2b6fe`,
each file with its SHA-256 in the record, which states hardware facts
and observed behaviour in its own words and holds no code; this design
cites it by section. The record is
[research-brcmstb-pcie.md](research-brcmstb-pcie.md), a point-in-time
research record. What neither
source settles waits for a board probe of erXos's own and is marked so
where it matters.

## Requirements

* **R1. Devices.** A USB keyboard, a relative mouse and an absolute
  tablet reach the display's input router as records; a USB mass-storage
  device of the SCSI transparent command set over Bulk-Only Transport
  reaches the media domain as a drive's medium
  ([design-drives.md](design-drives.md)). Hubs, USB 2 high-speed hubs with
  their transaction translators included, connect them.
* **R2. Controllers.** xHCI on QEMU `virt` (`qemu-xhci`) and on the
  Raspberry Pi 4 (the VL805), each behind a PCIe domain.
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
  word the controller writes is parsed by binary matching in Erlang with
  checked bounds, or, where the NIF must read it to keep its own memory
  safe, by a bounded C decoder; each parser has a fuzz target landing
  with it.
* **R6. Bounded cost.** What a device can make the domain spend, in
  memory, processes, controller slots, queue entries, commands, control
  requests and log lines, is bounded by constants fixed before the
  device arrives.
* **R7. No new cross-domain mechanism.** HID reaches the display and
  media reach the file servers through mechanisms the design documents
  already have; what changes in them is named here.
* **R8. Authority.** Which domain drives which controller, and which
  domains receive its input and its media, is the system manifest's and
  nothing else's.
* **R9. Phases.** The stack and the PCIe domain run on Fiasco on
  both targets, and every guarantee they cannot keep there is a recorded
  residual.

## The construction

### Hotplug ends at the controller's domain

A USB device is a sub-device of its host controller's unit: its
registers are the controller's, its interrupts arrive on the controller's
interrupt, and it is reached only through transfers the controller runs.
The unit rule already says that a sub-device never crosses a domain as
registers or a line, and that another domain reaches what it does only
through a file tree or a facet its holder serves
([design-system.md](design-system.md#devices), Units). This design adds
no exception: no USB device enters the device catalogue, is named in the
manifest, or is given to a domain.

What other domains see is a set of **places**, fixed when the domains
are configured and lasting as long as the controller's domain:

* an **input number**, `hid0` to `hid7`, a file of input records in the
  binary form of `abi/formats/input.txt`, served in the controller's
  domain's input tree, which the manifest grants a display domain read
  only ([design-display.md](design-display.md#the-display-device));
* a **drive**, `diskN`, one of at most `usb_drives_max` (four) that the
  manifest's window rows name on the domain's controllers' devices,
  numbered across the machine
  ([Mass storage reaches the file servers](#mass-storage-reaches-the-file-servers)),
  through whose **drive grants** the media domain asks for the window
  of whatever medium the drive holds, the medium whole.

A device's function **occupies** a place: a HID interface takes the
lowest free input number when its function starts, and a mass-storage
logical unit's medium takes the lowest free drive the manifest names
on any of the domain's controllers when it becomes ready. When the function or the medium ends, the place is
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
* **Media.** A window, the process that serves one medium whole, is
  started when the medium becomes ready and ends when the medium ends.
  The media domain, which mounted the medium, holds that window's pid;
  once the medium is gone, every request to that pid fails, and the next
  medium in the drive has a window of its own, reachable only by asking
  the drive grant again. Below the windows, every command the
  medium's transport queued carries the medium's reference, and the
  engine that sends commands refuses one whose medium has ended
  ([Media and drives](#media-and-drives)), so a file server's cached
  blocks of one medium can never be written to another, not even by a
  command accepted before the change.

### A name dies at once; hardware is freed only on the controller's report

Inside the domain the same rule holds one level down, with two
lifetimes kept apart.

**Names.** An xHCI slot number and a hub port are reused as devices come
and go. A function process therefore never names its device by either:
the bus process gives each attached device a fresh reference at attach,
and every transfer a function submits names a **pipe**,
`{Device, Endpoint}`, with that reference. The controller process holds
the map from a live device's reference to its slot and looks every pipe
up through it. Detach removes the reference from the map at once, so a
request through a pipe of a detached device answers `{error, gone}`
without reaching the NIF, whatever device later has its slot. It is the
kernel's generation check on capabilities applied to USB: a stale name
never names a new object.

**Hardware.** The controller may still be reading a detached device's
rings and writing its buffers when its name dies: transfers in flight
complete, and their events may arrive after the port's own change event
(xHCI 4.19.2, p. 321). So the slot, its rings and its buffers are not
freed when the name dies. The controller process stops each endpoint
that still has transfers posted, receives the events the stops produce,
then disables the slot; only the disable's success returns the slot, its
rings and its buffers (xHCI 4.6.4, pp. 109-110). Until then the slot is
held, so the controller cannot give its number to a new device, and an
event for it can only name a transfer of the old device, which the NIF
still holds. The same rule governs every ring and buffer of the TRB form:
each goes back to its pool only on an event or a command completion in
which the controller says it holds nothing of it
([The TRB ring form](#the-trb-ring-form)).

### One owner, one step

Three kinds of process own all of the stack's state in a controller's
domain, each deciding by a pure step and performing the actions it
returns, as the network stack's owners do
([design-network-stack.md](design-network-stack.md#one-owner-one-step)):

| Owner | Its state | Its pure core | Effects it performs |
| --- | --- | --- | --- |
| the **controller process**, one per host controller | the controller: its slots, every pipe's lifecycle (open, halted, resetting, torn down), the transfers in flight and their requesters, the root hub's ports | `erx_xhci_core` | device NIF calls, register reads and writes, interrupt acknowledgement, the control requests of a pipe's reset and of a failed address's cleanup, replies to requesters |
| the **bus process**, one per controller | the topology: every hub's ports, every device's enumeration and its functions, the places each occupies, the one port allowed at address zero | `erx_usb_bus_core` | port requests, control transfers, starting and stopping function processes, place assignments |
| a **function process**, one per claimed interface | one interface: a HID report layout and fold, a hub's status pipe, a BOT engine with its logical units and media | `erx_hid_core`, `erx_usb_hub_core`, `erx_usb_bot_core` | transfers on its pipes, records into its input number, media into drives |

Every timer is a deadline in the owner's state, and `next_deadline/1`
answers the earliest ([design.md](design.md#drivers-and-dma), "Deadlines in state").
No caller strings operations together: a function asks for one
`reset_pipe` and the controller runs every command and request of the
reset; the bus asks for one detach and the controller runs the whole
teardown.

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
| a file server writes one medium's cached blocks to the next | the window it holds ended with the first medium, and a command queued for the first carries its reference, which the engine refuses |
| a request reaches the device that reused a slot | pipes carry the device's reference, which the controller's map no longer holds; the slot itself is not reused until the controller reported it disabled |
| a late event names a buffer already given to another transfer | a buffer returns only on the event that completes its transfer or a command after which the controller holds nothing of its ring |
| a reconnect keeps the old device's identity | every connection change detaches the port's occupant before anything else ([The bus core](#ports-hubs-and-devices-the-bus-core)) |
| root ports and hub ports need two enumeration paths | the controller answers root-hub operations as a hub would |
| two devices answer at address zero | the bus core lets one port at a time hold the controller's address-zero turn |
| the event ring overflows | the event ring holds more entries than every source can have outstanding ([The TRB ring form](#the-trb-ring-form)) |
| a driver points the controller at memory of its choosing | the NIF builds every context from bounded parameters and forces streams off |
| a function orders a halt's recovery wrongly | `reset_pipe` is one operation of the controller process |
| a function's new instance meets its predecessor's transfers, halt or toggle | the bus resets a function's pipes after it ends and before it starts again ([A function's end](#ports-hubs-and-devices-the-bus-core)) |
| a stop's forced event names a transfer that has already completed | a stop's event completes nothing, and its span starts at the last TRB that completed ([Completing](#the-trb-ring-form)) |
| a controller is pointed at a link TRB as its dequeue pointer | the enqueue position, the only dequeue the NIF ever sets, never rests on a link |
| a reset of the bridge loses the VL805's firmware without asking for it again | PERST# is asserted only by the bring-up whose last step asks for the firmware ([The BCM2711 bridge](#the-bcm2711-bridge)) |
| a PCIe domain restart takes a running controller off its bus | the bridge is kept whenever it reads a link up with the VL805's firmware present |
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
file system. Its release script, `usb`, holds the base every domain boots and
`erx_usb`, the application that holds the stack:

| Platform | Controller | Given as | Interrupt | DMA | The USB domain is |
| --- | --- | --- | --- | --- | --- |
| QEMU `virt` | `qemu-xhci`, PCI `1b36:000d` on the root bus | a PCIe function by place, through the PCIe domain | one message on the MSI frame, by MSI-X | confined by the IOMMU on erXos's kernel, which covers the root bus; unconfined on Fiasco, whose harness starts no IOMMU | outside the trusted base on erXos's kernel; in it on Fiasco |
| Raspberry Pi 4 | the VL805, PCI `1106:3483` at bus 1, device 0, function 0 behind the `brcm,bcm2711-pcie` bridge | a PCIe function by place, with its INTx line as one unit | the bridge's INTx line for that position | unconfined; the board has no IOMMU | in the trusted base, as every Pi 4 DMA device's domain is ([design.md](design.md#trust-placement)) |
| Raspberry Pi 5 | RP1's two DWC3 hosts, parts `usb0` and `usb1` of RP1's function behind the BCM2712's `pcie2` | a part of RP1's unit: the xHCI registers of a host's 1 MiB in RP1's BAR 1, up to its DWC3 globals at `0xc100`, no PCIe place of its own ([design-rp1.md](design-rp1.md#the-usb-hosts)) | its own entry of RP1's MSI-X table, 31 and 36, edge | unconfined; the board has no IOMMU on RP1's path | the `rp1` domain, which holds RP1's unit and lends its Ethernet; in the trusted base |

On the Raspberry Pi 5 one domain runs two controllers: one `erx_usb_sup`
tree for each, each with its own drives and input tree, named by its own
part's row. RP1's function driver, not the controller process, opens
the function and runs each host's DWC3 step before its tree starts; the
controller process sends no `open`, and at step 4 sends its `master`
to RP1's function driver, `erx_rp1:master/1`, which answers once every
part of RP1 has reset its device and the function masters
([design-rp1.md](design-rp1.md#mastering)).

A development build's manifest may put the controller in another domain,
the display domain for instance, as it may merge other driver domains
([design-system.md](design-system.md#devices)). The places and the input
tree's mint start only with `erx_usb`'s application, which only the `usb`
release script boots ([The rows](#the-rows)), so a domain that holds a
controller under another script serves no input tree and never names
itself `usb_input`'s mint; such a domain runs no USB stack, since
`erx_usb_hid` writes only to the places, until a design names how a USB
function there feeds `erx_winfs:input/2` directly, as a virtio-input
driver does.

### HID reaches the display

The USB domain serves an **input tree** through `erx_fs`
([design-files.md](design-files.md#serving-the-erx_fs-behaviour)) holding
the eight files `hid0` to `hid7`, each a stream of records in the binary
form of `abi/formats/input.txt`, named by `input_tree` of
`abi/services/input.txt`. The tree is a service of the `input`
interface, whose grants are read-only by construction, and the manifest
grants it only to the display domain that should receive the
controller's input, exactly as for any input device another domain
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
function can end has to remember it. A stream holds at most one read's
worth of unread records ([From reports to records](#from-reports-to-records)),
and the `release` an end writes is never dropped, so a number is free only
when it has no occupant and less than one read's worth unread: a display
that has stopped reading a number keeps it taken, and each number's
unread bytes pass that bound by at most one `release`. A function that
finds every number taken is not started: its start fails as unusable,
with `no_input_number`, which the device's inspection record shows as
`no input number`
([the bus core](#ports-hubs-and-devices-the-bus-core)).

A read of a number's file takes whole records only, as many as its count
holds and the stream has, and a read of at least one byte whose count
holds no record is refused with `EINVAL`. So no read ends inside a record, and a reader that
ends, with the display's restart or a flush, never leaves the next one
reading from the middle of a record.

A USB domain has one set of places, which its application starts once,
so it serves one input tree, the files service `usb_input` of the
`input` interface, whatever controllers it holds. Its mint is
`erx_fs_mint`, the mint of every files service a configured domain
serves ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
and the places' last child: the boot script starts it, so it names
itself the service's mint before the domain reports ready, which no
process started after the report can do; only then, in its own process,
it mounts the tree on the places' streams;
for each mint request it starts one read-only grant of the tree whose
client is the display domain, which ends with the USB domain's
connection to the display. On QEMU `virt` the facet row `usb_input`
grants it to the display domain with `max_request` 131072, the floor
property 16 sets for a files interface, which the USB domain's
`max_frame` meets, and `in_flight` 16, above the eight reads the
display's follower keeps outstanding, one for each file
(`input_tree_files_max`).

The input tree is the USB domain's only grant to the display, and it has
the reach the display design gives any input source: that of a person at
the display, and no more ([design-display.md](design-display.md#security)).
A USB device that claims to be a keyboard types; which display receives
a controller's input at all is the manifest's grant.

### Mass storage reaches the file servers

A medium on a USB drive is served by the block service the storage
design already has, a transport process beneath and window processes
above it ([design-storage.md](design-storage.md#data-model)), with one
window covering the whole medium and no partition process: the USB
domain parses nothing a medium holds, and the media domain, which holds
no device, reads the medium's table and serves its volumes
([design-drives.md](design-drives.md)). The USB domain runs one such
block service for each ready medium. What the manifest names is a
**drive** of the USB domain: a window row whose device is the device row
of one of the domain's controllers, whose role is `drive`, which names
no partition, whose `drive` field is the drive's number, and whose
holder is the media domain. The row's device picks only the domain: a
drive is written against one of the domain's controllers, any one, and
serves media on all of them. The device service introduces the media
domain to the USB domain as it introduces any window's holder, and the
grant it hands over is a **drive grant**: a process of the USB domain,
`erx_blk_drive`, made for that one row and living as long as the USB
domain. The USB domain knows its rows from its records, one
`-erx_record drive usb N` for each drive the manifest names on its
controllers ([design-fiasco.md](design-fiasco.md#drive-records)): at
its start its places start one drive grant for each, and a medium that
becomes ready takes the lowest free of them, as a HID function takes
the lowest free input number. A domain whose drive records are refused
serves no drive, and its functions show each unit with a ready medium
as `no drive`.

A drive grant answers one request, `window`: `{ok, Window}`, the pid of
the window on the medium the drive holds now, or `{error, no_medium}`
while the drive holds none. Asked again for a window it already
answered, which only a restarted holder does, the grant first ends the
medium as a UNIT ATTENTION does, so the engine refuses every request of
the old reference before the medium is ready again under a fresh one,
and holds the ask until it sees the old window end. The medium becomes
ready again only after the engine's next poll of the unit, so the grant
then answers `{error, no_medium}`, and the holder's next walk asks again
and finds the medium, perhaps under another drive; so no medium is
mounted twice at once
([design-drives.md](design-drives.md#a-drive-and-its-medium)). The window is an ordinary window of the
block service, whose sectors are the medium's, answering `{read, Sector,
Count}`, `{write, Sector, Bytes}` and `flush` with the block service's
answers, and it ends when its medium ends. Holding a drive grant is
holding whatever medium that drive holds, whole, as holding a
window is holding its sectors, so the grant checks no caller and names nothing
else. What the media domain does with it, from the table to the files
at `/media/diskN`, is [design-drives.md](design-drives.md)'s.

Drive numbers name drives across the machine, as macOS's `diskN` does:
one number is one drive wherever its medium sits, and the manifest
check refuses a number that two controllers' rows name. A drive belongs
to the USB domain, not to the controller whose row names it: a medium on
any of the domain's controllers takes the lowest free number among all
the drives the manifest names for the domain's controllers, and its
number is free again when the medium ends, to be reused by the next
medium. The number is lowest free within the drives the manifest names,
so a manifest that names `disk0` upward without a gap, on a machine
whose drives are all one USB domain's, gives each medium the lowest free
drive number on the machine. What is bounded is how many
drives there are, not their names: the rows on all of a USB domain's
controllers name at most `usb_drives_max` drives, the media that domain
serves at once, under any numbers. A logical unit whose medium becomes
ready when every drive of its domain is occupied is not served: its
function's state shows the unit as `no drive`, and the medium stays
unserved, though a drive is freed later, until its device is attached
again, when the new function finds the lowest drive free then.

A drive's number names a place, not a medium: the same stick may come
back as another number. A script that must find one medium again finds
it by what the medium says of itself, each volume's label and serial
number, which its drive's `status` file shows
([design-drives.md](design-drives.md#status)).

### What the USB domain claims

The USB domain claims every device its controller reaches; no other
domain claims a USB device, and no program reaches a device's pipes,
since erXos has no counterpart of FreeBSD's `ugen`. A need for one is a
declared protocol with a design of its own
([design.md](design.md#decisions)).

Which interfaces it drives is one pure function of the device's speed
and its device and configuration descriptors,
`erx_usb_claim:functions/3`, a closed table, which names an interface
by its alternate setting 0:

| Interface | Function | Alternate setting | Needs |
| --- | --- | --- | --- |
| interface 0 (`bInterfaceNumber` 0) of a device of device class 09h, hub, whatever the interface's own class | `erx_usb_hub` at full or high speed; none at low and SuperSpeed | 1 on a multi-TT hub (device protocol 2), as FreeBSD's `uhub_attach` selects it (`usb_hub.c:1252-1258`); 0 otherwise | the first interrupt-IN endpoint |
| class 03h, HID, any subclass and protocol | `erx_usb_hid` | 0 | the first interrupt-IN endpoint |
| class 08h, mass storage, subclass 06h, protocol 50h | `erx_usb_bot` | 0 | the first bulk-IN and the first bulk-OUT endpoint |
| anything else, an interface of class 09h on a device of another class included | none | | |

A hub is a device, not an interface: FreeBSD's `uhub_probe` matches a
device of class 09h alone (`usb_hub.c:1134-1136`), and `uhub_attach`
selects the setting of interface index 0 (`usb_hub.c:1252-1253`), so a
hub runs one hub function, on interface 0, and its other interfaces are
claimed by the rows below the first. FreeBSD's index 0 is the first
interface in the configuration's order; the claim, which reads the
settings by number, takes `bInterfaceNumber` 0, the same interface on a
hub that numbers its interfaces from 0, and runs no hub function on one
that has no interface 0.

The device's first configuration is set, as FreeBSD sets configuration
index 0 unless a quirk names another (`usb_device.c:1969-2019`). Each
interface the table names is one function; a composite device's
interfaces are claimed one by one. An interface whose selected setting
lacks an endpoint its function needs runs no function. A device none of
whose interfaces the table names is configured anyway, so its descriptors and state show in
its inspection record, and runs no function. CBI (protocols 00h and
01h), UAS (62h), the RBC, UFI and SFF-8070i command sets, isochronous
interfaces and every other class are outside this design.

### What a device can make the domain spend

Every bound is a constant of the stack or of the controller's record,
fixed before any device arrives:

| Resource | Bound | Where it is fixed |
| --- | --- | --- |
| devices on a controller | 16 slots, those still being torn down included | `usb_devices_max` |
| hub depth | 5 tiers below the root, FreeBSD's `USB_HUB_MAX_DEPTH`; a hub deeper than that is configured and its ports never powered, so its hub function's first report is never answered and nothing below it is enumerated | `usb_hub_depth_max` |
| hub ports | 1 to 15, what a tier's four bits of the route string name; a hub claiming more is refused | the descriptor rules |
| configuration descriptor | 4 KiB: one control buffer; a longer `wTotalLength` refuses the device | `usb_config_max` |
| HID report descriptor | 4 KiB, one control buffer; a longer one refuses the function | `hid_report_descriptor_max` |
| string descriptor | 255 bytes, `bLength`'s own bound, three strings a device | the descriptor format |
| endpoints a device may use | its claimed functions' endpoints, at most 8 with EP0; a device whose functions claim more is refused (`too many endpoints`) | `usb_endpoints_max` |
| xHCI queue blocks | 16 control, 16 interrupt and 4 bulk blocks per controller | the TRB ring form's record |
| transfers in flight | 1 on a control pipe, 4 on an interrupt pipe, 2 on a bulk pipe | the queue blocks' buffers |
| commands | one in flight per controller; a device's teardown at most one Stop Endpoint per endpoint and one Disable Slot | the controller process |
| hub notifications | one status transfer posted per hub, and the next posted only when the bus core has handled every port the last one named; per port at most one operation in flight | [Hubs](#hubs) |
| enumeration | one port at a time between its reset and its device's address; one attempt per connection; an attempt starts when the port has settled, at most `usb_port_attempts_max` on a port in any `usb_port_attempt_window_ms`; past them a settled port is held in `settling` until its oldest attempt leaves that window; a hub attached again starts its ports' attempts afresh, which its own port's attempts bound | `usb_port_attempts_max`, `usb_port_attempt_window_ms` |
| function restarts | a function's pipes are reset before each restart, and a function is restarted at most 3 times in any 60 s; an end past them detaches its device and disables its port until its connection changes; an end as unusable is neither restarted nor counted ([Failure handling](#failure-handling)) | `usb_function_restarts_max`, `usb_function_restart_window_ms` |
| diagnostics | a port's failure is logged once per connection and an over-current change once per enumeration attempt, so at most one line more than the port's attempts; repeats count in the inspection record | the bus core |
| processes | one per claimed function, one per ready medium's transport, partition and windows | the claim table and the places |
| input numbers, drives | 8 input numbers; the drives the manifest names, at most 4 | `usb_input_max`, `usb_drives_max` |
| time | every control transfer 5 s; every command 5 s; every BOT command within the block transport's 28 s | [Failure handling](#failure-handling) |

A device that offers more than a bound is refused with a reason in its
inspection record and one log line, and costs nothing beyond its slot and
what its refusal read. These constants live in a new ABI file,
`abi/formats/usb.txt`, with the chapter 9, hub, HID, BOT and SCSI
constants the stack reads.

### The rows

On QEMU `virt` the USB domain is the configured row `usb` of the board
part of the development manifest,
`config/manifest/qemu-virt-development.txt`, after the PCIe domain's
unit ([design-pcie.md](design-pcie.md#the-rows-and-the-facets-limits)),
and the Raspberry Pi 4's part, `config/manifest/raspi4b-development.txt`,
has the same rows over the VL805:
an interpreter service domain on the `usb` release, holding the
platform's `xhci` unit and nothing else, with the `pci` facet
[design-pcie.md](design-pcie.md#facets) gives every holder of a `pci`
device, for its one function. The domain service starts it only once
the device service has answered the PCIe domain's report
([design-pcie.md](design-pcie.md#the-catalogue-and-gives), "The hold at boot"). The domain starts
in two steps, as the PCIe domain does
([design-pcie.md](design-pcie.md#processes)). The `usb` release script
starts `erx_usb`, whose top supervisor, registered `erx_usb`, starts the
places with the input tree's mint as their last child, before init's
ready report, so the mint names itself `usb_input`'s mint while it still
can. The row's `-eval ok=erx_usb:start_controllers()` runs once init
holds the ready answer's facets, `pci` among them, which a controller
needs to open its function: it reads the domain's function records once,
`erx_device_record:find(usb, xhci)`, and adds one bus group,
`erx_usb_bus_sup`, for each under the top supervisor; a record the
reader refuses fails the eval and so the domain's boot. The top
supervisor has intensity 0, so the end of the places or the mint ends
the domain and the domain service's restart is the recovery ([Failure
handling](#failure-handling)); a domain started before any PCIe report is taken, or
on a machine with no controller attached, holds no record and runs no
controller, and its input tree serves eight numbers no function
occupies. Its row `usb_input`
and the display's facet of it are those of [HID reaches the
display](#hid-reaches-the-display).

Its memory, 32 MiB and outer 1 MiB, is not measured yet; its grant is a
share of its own, 100 mcpu on CPU 0, out of what the system share's
reserve leaves the configured domains. The system principal's memory,
its domains quota, `max_domains`, `max_connections` and `root_memory`
count the row, its system connection and the function's 1 MiB of DMA
memory, and one more slot of the domains quota prices one more
`display_root` grant in the display's outer budget, as for the PCIe
domain. The website's manifest leaves the USB domain out with the PCIe
domain it depends on, and the `pcie` QEMU suite leaves it out too, since
its test holder holds the same unit.

## The PCIe domain

Both controllers are PCIe functions, so the first USB needs the PCIe
domain of [design-system.md](design-system.md#devices): an Erlang
enumerator in the domain `pcie`, which holds the bridge's configuration
window and nothing else, walks the bus, assigns BARs
([design-kernel.md](design-kernel.md), "Requirements"), reports
each function to the device service, and moves each function to the
setting its holder's requests choose. The domain library's give carves
the function's BARs inside the bridge's windows and writes its
interrupt route, but programs no MSI and enables nothing: the holder's
`open` and, after its own reset of the controller, `master`, sent
through the device service's `pci` facet, do
([design-pcie.md](design-pcie.md#the-plan)). This design adds the
BCM2711 bridge, the Pi 4's interrupt, and the part of all of it that
runs on Fiasco.

### On QEMU `virt`

The bridge is ECAM (`pci-host-ecam-generic`), as
[design-platforms.md](design-platforms.md#pcie-bridges) has it. Nothing
assigns BARs before erXos on QEMU `virt`, since no firmware runs, so the
enumerator assigns `qemu-xhci`'s BAR 0 from the bridge's 32-bit memory
window in the tree's `ranges`, aligned to its size. The give carves it as
the register window, creates one message on the MSI frame, which the
given record carries since the function offers MSI-X alone, and,
on erXos's kernel, the DMA window on the function's IOMMU stream; the
holder's NIF writes the message into table entry 0 after the driver's
reset, as [design-pcie.md](design-pcie.md#who-programs-what-and-when)
says. The driver needs one vector, since it uses one interrupter.

### The BCM2711 bridge

The Pi 4's bridge is the platform's second bridge kind beside QEMU's
ECAM. Its driver, `erx_pcie_bcm2711`, is an Erlang module beside the
enumerator in the PCIe domain, with a pure core that turns what the
bridge's registers read into the next writes and waits. The facts record
gives the sequence and its reasons from Linux's driver, the vendor's,
with FreeBSD's `bcm2838_pci.c` (ISC) as the second witness; where the two
differ, the record's section 8 says which difference matters, and the
driver takes the vendor's value unless a reason below says otherwise.

* **Identity and registers.** Compatible `brcm,bcm2711-pcie`, one
  register window of `0x9310` bytes (facts record, section 0; FreeBSD
  `:134-139`, `:166-178`). The record's register map is the source of the
  bridge's SVD file.
* **Configuration access.** The root port's own configuration space is
  at offset 0 of the window; an endpoint's is reached by writing its
  bus, device and function, in ECAM layout, to the index register at
  `0x9000` and accessing the data window at `0x8000`, one function at a
  time (facts record, section 3; FreeBSD `:266-289`). Any other position
  on bus 0 "will lock up the memory controller" (FreeBSD `:291-307`), so
  the bridge driver's access reaches bus 0 only at device 0, function 0.
  Below the root port it reaches only the places the platform record
  lists for the closed bus, bus 1, device 0, and answers every other
  place `absent` before any register is touched, whatever a header type
  says, so the accesses whose outcome no source gives, to devices 1 to
  31 of bus 1 and to unlisted functions (facts record, unknown 6), are
  never made ([design-pcie.md](design-pcie.md#the-bridge-seam)). Each access is two register
  operations, so the bridge driver serializes them in the one
  enumerator process.

**The link before every access.** A configuration access below the root
port while the link is down aborts the CPU; Linux checks the link before
every such access, FreeBSD once at attach (facts record, section 3 and
section 8, item 10). The bridge driver makes every access below the root
port one step: read `MISC_PCIE_STATUS` (`0x4068`) and go on only when
`PHYLINKUP` (bit 4) and `DL_ACTIVE` (bit 5) are both set; make the
access; read the status again, and keep the value only when the link is
still up. Otherwise the access answers `{error, link_down}`, and the
enumerator reports the function's position gone. The second read is what
keeps a value read across a link's fall from being taken as an answer
where the abort itself is not delivered. What the abort does depends on
the kernel:

* **On erXos's kernel**, a synchronous external abort from user mode is
  a fault of the PCIe domain's thread, and an asynchronous error taken in user mode or in
  the exit window is presumed to be the running thread's
  ([design-arch-aarch64.md](design-arch-aarch64.md#asynchronous-errors)):
  either way the PCIe domain ends, and the domain service restarts it,
  which finds the link down and resets the bridge as below. The Pi 4's
  Cortex-A72 has no RAS extension, so the presumption is all the kernel
  has, and an SError a posted write reports after its window may stop
  another thread, the residual that design already records.
* **On Fiasco**, an SError Fiasco takes in user mode ends the task
  of the thread that ran with a fault record of kind `async_error`,
  presumed its own (`arm_serror_user_entry`, `fiasco/kernel/src/kern/arm/thread-arm.cpp:713-735`), as erXos's kernel presumes in user mode; Fiasco's
  kernel runs with SErrors masked, so one raised while the CPU is in the
  kernel lands on the next thread to enter user mode, and the access
  completes with whatever the bus returned; the second link read
  keeps that value from being used. A synchronous abort takes
  Fiasco's user fault path, which is unverified for an external abort.
  Both are residuals of [On Fiasco](#on-fiasco).

Which of the two the BCM2711 raises is probe B8. The xHCI driver's own
register accesses, through the outbound window, abort the same way when
the link falls under it ([Failure handling](#failure-handling)).

**Bring-up**, in the vendor's order (facts record, section 1, steps 3
and 6), each wait a deadline of the core:

1. Assert the bridge reset (bit 1 of `0x9210`) and PERST# (bit 0), since
   the boot firmware may have left PERST# released; wait at least
   100 us, which the driver sleeps as 1 ms, since its waits are whole
   milliseconds; release the bridge reset; clear `SERDES_IDDQ` (bit 27
   of `0x4204`) and wait as long again for the SerDes to settle.
2. Set `MISC_CTRL` (`0x4008`), read-modify-write: `SCB_ACCESS_EN`,
   `CFG_READ_UR_MODE`, `MAX_BURST_SIZE` 0, the 128 bytes the vendor
   chooses for the BCM2711, `RCB_MPS_MODE` and `RCB_64B_MODE`. FreeBSD
   writes the whole register and leaves the RCB bits clear (section 8,
   item 3); no source says what they change, and the vendor's value is
   taken.
3. Program the inbound window from the tree's `dma-ranges`: `BAR2` with
   its CPU side at physical 0 and its PCI side at the range's lowest
   address, its size the range's size rounded up to a power of two;
   `BAR1` and `BAR3` disabled, `BAR1` because on this family it would
   map the SoC's own registers to the bus (section 2). On the Pi 4's
   3 GiB range this is a 4 GiB window at PCI 0; FreeBSD's fixed 8 GiB
   window covers the same memory (section 8, item 4).
4. Read the root-complex bit, bit 7 of `MISC_PCIE_STATUS`; clear, the
   block is an endpoint and bring-up fails with `endpoint mode`.
5. Set `SCB0_SIZE` in `MISC_CTRL` to match the inbound window; set the
   root port's class code (bits 23:0 of `0x43c`) to `0x060400`, a
   PCI-to-PCI bridge, since the block resets presenting an endpoint's;
   program one outbound window for each memory range of the tree's
   `ranges`, each in MiB with an inclusive end (section 2); set
   `ENDIAN_MODE_BAR2` (`0x188`) to little endian.

   Both windows are checked against the tree before any register is
   touched, so a tree they cannot carry leaves the bridge as it was. A
   `dma-ranges` range whose CPU side is not 0, which the window's fixed
   CPU side cannot map as the tree says, or whose window breaks the
   window's rules (64 KiB to 64 GiB, a PCI offset that is a multiple of
   the size and not between 2 and 4 GiB) fails bring-up with
   `dma-ranges`; `ranges` with no memory range, more than four, or one
   whose CPU base or size is not whole MiB or whose end lies past the
   40 bits the window registers hold, fails it with `ranges`.
6. Clear `CLKREQ_DEBUG_ENABLE` and `L1SS_ENABLE` in `0x4204`, the mode
   Linux calls "safe": no clock power management, so no internal-bus
   timeout to lengthen and no L1 substates that could stop the link
   (section 1). ASPM stays off. The MSI decoder is not set up (MSI,
   below).
7. Release PERST#; wait 100 ms, the PCIe rule before the first
   configuration request; then poll for link-up every 5 ms for at most
   100 ms more, past which bring-up fails with `link down` (section 1,
   step 6). FreeBSD polls from the release with no fixed wait (section 8,
   item 2); erXos follows the PCIe rule.
8. The walk reads the root port's link status from its PCI Express
   capability, through the bridge's `ROOT_PORT` configuration space as
   any function's, and the enumerator logs the speed and width.
   Spread-spectrum clocking, which Linux
   enables after link-up through the MDIO port, is an emission measure
   FreeBSD runs without (section 8, item 9), and is not enabled.
9. The enumerator programs the root port's bus numbers and its memory
   base and limit to the outbound window, then reads bus 1, device 0,
   and the VL805's firmware follows ([The VL805's firmware](#the-vl805s-firmware)).

A bridge reset clears the windows, `MISC_CTRL` and the MSI registers,
since every resume path writes them all again (section 6), so bring-up
runs whole after every reset and nothing of it is kept across one.

**Turn-off.** A reset taken while the link is up starts with the clean
shutdown of the facts record's section 6: request L23 (bit 0 of
`MISC_PCIE_CTRL`, `0x4064`) and poll `LINK_IN_L23` (bit 6 of `0x4068`)
up to 15 times 2 ms apart, going on past the last with one log line;
assert PERST#; clear the L23 request; set `SERDES_IDDQ`; assert the
bridge reset. Then bring-up runs from its step 1.

**Keep or reset, decided from what the bridge reads.** At each start of
the PCIe domain, the boot's first and every restart alike, the bridge
driver reads, in this order and each only when the one before allows:
the bridge's reset, bit 1 of `RGR1_SW_INIT_1` (`0x9210`); with the
reset clear, `SERDES_IDDQ`, bit 27 of `HARD_DEBUG` (`0x4204`); with the
SerDes powered, the link state; and, when the link is up, the VL805's
firmware register through the link check above. It decides by what it
read:

| Bridge | Link | Firmware register `0x50` | Decision |
| --- | --- | --- | --- |
| in reset, or its SerDes powered down | not read | not read | **reset**: bring-up, then the firmware notification |
| out of reset, SerDes powered | up | neither 0 nor all ones | **keep**: nothing is reset; the windows and `MISC_CTRL` are written again with the values derived from the tree, which a running VL805 already uses, and the enumerator re-reads configuration space, as [design-system.md](design-system.md#devices) requires of every enumerator restart |
| out of reset, SerDes powered | up | 0 or all ones | **reset**: turn-off, bring-up, then the firmware notification |
| out of reset, SerDes powered | down | not read | **reset**: bring-up, then the firmware notification |

A bridge in reset is touched only at `0x9210`, and one whose SerDes is
powered down only there and at `0x4204`, until bring-up has released
the one and powered the other. The vendor's order makes no other access
in those states: its probe releases the bridge reset before it touches
any other register, and its setup releases the reset and clears
`SERDES_IDDQ` before its first access to the rest of the block (facts
record, section 1, steps 2 and 3a to 3e). A turn-off leaves the bridge
in exactly those states, in reset with the SerDes powered down (section
6), and what the boot firmware leaves at handover the record does not
establish (its unknowns 8 and 9). On the Raspberry Pi 4 a read of
`MISC_PCIE_STATUS` made first, with the bridge as the boot firmware
leaves it, does not complete, and the board's watchdog resets the board
([TODO.md](../TODO.md), the bridge's start on the board). Such a
bridge goes to bring-up without the turn-off, whose L23 handshake reads
`MISC_PCIE_STATUS`, since bring-up's first steps read and write only
`0x9210` and `0x4204`, with waits between. The keep, which must read
the link and the firmware register before any reset, is the one
departure from the vendor's order, which reads nothing before it resets
the bridge; a state the record does not name that also gates the block
(the reference clock, its unknown 9) would meet that read.

PERST# is asserted nowhere else, and the notification is the last step
of the one sequence that releases it, so the VL805's firmware is asked
for after every PERST# cycle, by construction, as it must be (facts
record, section 6). A restart that finds the controller running resets
nothing, so a PCIe domain restart never takes a running controller off
its bus; this is the one departure from both drivers, which reset at
every attach. A restart meets a VL805 that erXos's own driver runs, whose
buffers the USB domain still owns, so keeping its link and writing the
same windows again changes nothing it uses.

**The boot firmware's handover.** The boot's first start is decided by
the same table, so a link the boot firmware left up with the VL805's
firmware loaded is kept (probes B1 and B3). The keep asks no proof that
the VL805 is stopped, and claims none: the VL805's own buffers and
descriptors are installed only after its reset, through `negotiate/2`
([The handover at entry](design-platforms.md#dma)), and what it writes
before that reset is a recorded residual. The PCIe domain's start turns
off every function that does not read as its setting, and the VL805's
is `off` until the USB domain opens it, so a VL805 the boot firmware
left mastering has its bus mastering cleared at the PCIe domain's first
start; the USB domain's xHCI driver then halts and resets the controller
in `negotiate/2` before it installs any ring, context or buffer
([Install](#install)), and asks for bus mastering only after
([design-system.md](design-system.md#drivers), Resets). Until its bus
mastering is cleared, a VL805 the firmware left running is part of the
trusted loader and may write memory the kernel has already handed out;
that window, from the kernel's entry until then, is the [Medium]
security residual that [the handover at
entry](design-platforms.md#dma) records. Neither the keep nor the
bridge's reset path closes it, since the reset path too runs after the
kernel has reclaimed memory.

**The Pi 4 boots from its microSD card alone.** The board's
installation, which already writes the EEPROM's configuration and each
slot's `config.txt`
([design-platforms.md](design-platforms.md#slots-and-the-boot-selection-record)),
sets the EEPROM's boot order to the microSD card alone, never USB mass
storage or the network, so the boot firmware has no USB device to boot
from and no reason to run the VL805's schedule. Nothing erXos runs needs
the firmware to touch the VL805: no first stage carries bridge or xHCI
code, only the PCIe enumerator reaches configuration space, as
[design-system.md](design-system.md#devices) says, and the notification
of [The VL805's firmware](#the-vl805s-firmware) gives the controller its
firmware after erXos's own bring-up. A board whose EEPROM names any
other boot order is not an installation the board port supports. The
cost is that erXos does not boot from USB or the network on the Pi 4.
The one exception is development: a board on the desk that boots each
build over Ethernet from the development host
([design-platforms.md](design-platforms.md#netbooting-from-a-mac)) has
the network ahead of the card in its boot order, which lets whatever
answers DHCP and TFTP choose its kernel, and that kernel then reads the
card's `/data`, the SSH host key and root's `authorized_keys` among it.
The exception holds only on a desk network that is trusted; the board
is not an installation, and it leaves the desk with the microSD-only
boot order restored. What the boot firmware does to the VL805 when it
boots from the network rather than the card is not recorded; probe B3
reads the handover on the card's boot order alone.

**Probe B3 reads what the firmware leaves.** At the PCIe domain's first
start in a test build, before the bridge driver writes anything, with a
USB keyboard and a USB drive attached, B3 reads the bridge's reset and
PERST# bits (bits 1 and 0 of `0x9210`), with the reset clear
`SERDES_IDDQ` (bit 27 of `0x4204`), with the SerDes powered too its
link state (`PHYLINKUP` and `DL_ACTIVE` in `0x4068`), in the order and
under the conditions of the keep-or-reset reads above, and, when the
link is up, the VL805's command
register through the bridge's configuration window and its `USBCMD` and
`USBSTS`. A VL805 found running, bus mastering set, `USBCMD.R/S` set or
`USBSTS.HCH` clear, shows that the window of that residual is open on that
board under that firmware, and its `TODO.md` record says so; nothing in
this design depends on the answer.

Every reset is followed by the firmware notification of
[The VL805's firmware](#the-vl805s-firmware); a VL805 whose firmware
still reads absent after it is reported `not_ready` and stays out of
the catalogue until a later start of the PCIe domain finds it loaded,
which after a timed-out notification is the next boot
([design-pcie.md](design-pcie.md#the-bridge-seam)); the bridge's
inspection record shows which.

**MSI, unused.** The bridge decodes MSIs written to a target address of
its own into 32 vectors at `0x4500` when `MISC_REVISION` (`0x406c`) is
`0x0303` or more, else 8 at `0x4300`, and raises the second of its two
interrupts; Linux acknowledges a vector by its clear register alone,
while FreeBSD also writes 1 to `0x4060` after each (facts record,
section 4; section 8, item 6). erXos drives the VL805 by INTx
([Interrupts](#interrupts)), so the decoder stays disabled, the
difference between the two acknowledgements is moot, and the bridge's
two interrupts are lines of its own unit, held by the PCIe domain and
left masked. Whoever drives the decoder first settles `0x4060` and the
layout on the board.

**DMA.** The inbound window maps physical address 0 to the PCI address
the handed-over tree's `dma-ranges` gives: PCI 0 in the facts record's
tree, PCI `0x4_0000_0000` in the tree the board's boot firmware hands
over, as one boot's line showed. The facts record's tree allows inbound DMA below 3 GiB and FreeBSD below 960 MiB,
a limit it found by corruption and calls unclear (facts record, section
2); the Pi 4's platform record sets the bridge's `dma_limit` to 960 MiB,
FreeBSD's `DMA_HIGH_LIMIT` (`:92-106`, `:627-633`), a ceiling on
physical addresses, so every PCIe function's memory is made below it
whatever PCI addresses the window puts in front of it
([design-pcie.md](design-pcie.md#dma)), until probe B5 shows where the
limit really is and on which side of the bridge it lies. Linux's 36-bit and 40-bit DMA masks for the VL805 lie above
the bridge's limit and change nothing here (section 5).

**What remains unknown**, the facts record's ten board unknowns merged
with this design's probes, each with what settles it:

| Unknown | Settled by |
| --- | --- |
| the bridge node's `reg`, `ranges`, `dma-ranges`, interrupts and `interrupt-map` in the tree the boot firmware hands over, and whether that firmware rewrote `dma-ranges` (record unknown 5) | B2: erXos's own device-tree reader prints the node at boot |
| that the VL805's INTA arrives on SPI 143 alone, apart from the bridge's SPI 147 and 148, as the tree says (record unknown 4), and what raises SPI 147 (unknown 3) | B2, with the VL805 driven: its line counted, the bridge's two read while masked |
| the VL805's header type, its functions and its interrupt pin | B4: the enumerator's configuration-space dump |
| the VL805's state at erXos's start: an EEPROM or none, `0x50` before and after the notification, what a missing notification looks like, and whether this board's boot firmware reloads firmware already present (unknown 7) | B1 |
| whether the boot firmware's handover leaves the VL805 running: bus mastering on, `USBCMD.R/S` set or `USBSTS.HCH` clear ([The boot firmware's handover](#the-bcm2711-bridge)); whether it leaves the link up and PERST# released (unknown 8); the bridge's `MISC_REVISION` (unknown 1) | B3, whose answer the residual of [the handover at entry](design-platforms.md#dma) records and nothing else depends on |
| the reference clock's source and whether anything must enable it (unknown 9) | B3: if bring-up finds no link, the clock is the first question, and no source answers it yet |
| the real DMA limit, against FreeBSD's 960 MiB and the facts record's tree's 3 GiB, and whether it depends on the CPU or the PCI address (unknown 5) | B5 |
| whether the VL805 reports `AC64`, which a window at PCI `0x4_0000_0000` needs ([Address width](#install)) | B7: its capability registers |
| whether a narrowed inbound window blocks the VL805 outside it | B6 |
| the VL805's xHCI capability registers and its firmware version | B7, with B1 |
| whether a configuration access with the link down raises a synchronous abort or an SError | B8: one access with PERST# held, on a board by hand |
| whether SPI 148 deasserts on the clear register alone, what `0x4060` is, and MSI-X through the decoder (unknowns 2 and 10) | not asked while the decoder is unused |

### Interrupts

**QEMU `virt`: a message on the MSI frame.** The give creates the
controller's one message as an `ERX_IRQ_MSI` IRQ object on the
platform's MSI frame, on erXos's kernel and on Fiasco alike.
`qemu-xhci` offers MSI-X alone, with no MSI capability ([the QEMU facts
record](research-qemu-pcie-usb.md#qemu-xhci)), so it takes the MSI-X
route and the holder's NIF writes that message into its table
([design-pcie.md](design-pcie.md#the-choice)). Fiasco uses the frame
too, and not the function's INTx line: QEMU's bus is not closed, since
the harness can put any function at any position, and a message over
the frame is the same call above `liberx` in both phases. How each
kernel makes the call and its message is design-pcie.md's
([The MSI frame on Fiasco](design-pcie.md#the-msi-frame-on-fiasco)),
so nothing above `liberx` changes between the phases. The frame's range on QEMU `virt`, and whether
Fiasco binds its lines with the edge trigger an MSI needs, are probe 4 ([the QEMU facts record](research-qemu-pcie-usb.md#probe-numbering)).

**Raspberry Pi 4: the INTx line of a closed bus.** The Pi 4 has no MSI
frame erXos drives: the bridge's MSI registers share their page with the
windows the PCIe domain programs, so another domain cannot clear a
vector without a new cross-domain mechanism, and the kernel cannot keep
the page without taking bring-up from the PCIe domain. So the VL805
interrupts by the INTx line of its pin, which the tree's
`interrupt-map` routes to an interrupt line, as FreeBSD's generic host
driver routes it (`pci_host_generic_fdt.c:246-276`). The board's tree
keeps only the pin in its `interrupt-map-mask` and routes INTA to INTD
straight to SPIs 143 to 146, level-high, apart from the bridge's own
SPI 147 and its MSI line, SPI 148. Linux's driver uses no INTx status,
mask or acknowledge register of the bridge, so the line is masked only
at the function's command register and at the interrupt controller
(facts record, sections 0 and 4); whether the bridge has such a
register at all is unknown.

PCIe functions interrupt by MSI, and the Pi 4's bus is the one exception
([design-shared-devices.md](design-shared-devices.md#the-unit-rule)).
The rule exists because an INTx line is shared by every function behind
a bridge, and which functions those are is known only after
enumeration, so the line cannot be put in one unit when the manifest is
written. The Pi 4's bus is closed: its bridge has one root port and one
soldered endpoint position, bus 1, device 0, so every function that can
raise the line its position routes sits at that position, which the
platform record lists with the pin its function raises, the line
following from the tree's `interrupt-map` by that pin
([design-pcie.md](design-pcie.md#the-closed-bus)). No other platform's record closes
a bus, so the exception reaches nothing else. On the Pi 4 the unit rule
applies unchanged: the functions at that position and the line form one
unit, which the manifest gives whole to the USB domain, and the
enumerator keeps the root port's own INTx disabled (the interrupt-disable
bit of its command register). The line is a direct line of that unit,
made and given as any device-tree unit's line is: on erXos's kernel by
the give, on Fiasco by the root, which alone makes lines there.
The tree answers the question of probe B2, whether the VL805's line is
also one of the bridge's, with no; B2 confirms it on the board.

**A shared line is refused.** Were the VL805's line also one of the
bridge's, the bridge and the VL805's position would be one unit, which
property 3 forbids splitting between the PCIe domain and the USB
domain, and which no placement could give whole without putting the
USB stack in the PCIe domain. That topology is refused, not worked
around: a tree that routes the position's INTx to one of the bridge's
lines makes the device service's unit check at boot find one unit split
across two domains, and it gives that unit to no domain with its
diagnostic ([design-shared-devices.md](design-shared-devices.md#the-unit-rule)),
so such a board runs with neither PCIe nor USB. Giving the VL805 no
interrupt and polling its event ring would not help, since units follow
from the lines devices share, not from which lines are given, and the
two would remain one unit. A B2 reading that contradicts the tree, the
VL805's interrupts raised on a line the tree does not name, is a defect
of the platform's facts: the platform record is corrected from it, and
the same check then refuses the unit.

### The Phase 1 part

The PCIe domain runs on Fiasco on both targets, as Track U's first
parts propose ([plan.md](plan.md#track-u-usb)):

* **Domains.** `pcie` holds the bridge's unit, the ECAM window on QEMU
  `virt` and the BCM2711's register window on the Pi 4, given at its
  creation like any device-tree unit, and holds nothing else. Its
  enumerator and the Pi 4's bridge driver are the same Erlang code as on
  erXos's kernel. The USB domain holds the controller's function by
  place. `pcie` starts before the USB domain, whose creation waits for
  its function's report, since the catalogue entry it is given from
  exists only then.
* **The give.** The domain library gives a PCIe function on a configured
  row: the boot view's arm for `pci` selectors, which `TODO.md` asks for,
  takes the function's kind from the kinds table by its identity and
  position, and the give's body creates the register window over the BAR
  the catalogue entry records, the IRQ object, and the device's
  contiguous memory, all in the root, as for any device another domain
  holds ([design-fiasco.md](design-fiasco.md#device-records)). The
  VL805's contiguous memory is made with `erx_mem_create_contiguous_in`
  inside the function's DMA facts, its bridge's DMA range cut at the
  row's `dma_limit` ([design-pcie.md](design-pcie.md#dma)), as the give
  makes every unconfined device's (`liberx/system/dom_apply.c:461`).
* **Interrupts.** QEMU `virt`'s MSI and the Pi 4's INTx line as
  [Interrupts](#interrupts) says.
* **DMA.** Unconfined on both targets: Fiasco's harness starts QEMU
  `virt` with no IOMMU, and the Pi 4 has none.

**What the Phase 1 manifest check must allow.** Property 3 changes from
"QEMU `virt` drives no bridge in Phase 1, so no holder is allowed and no
`pci` device is placed" to: on QEMU `virt` and on the Pi 4, exactly one
configured domain, `pcie`, holds the bridge's unit and holds nothing
else; a `pci` device is placed by position on one configured domain; on
the Pi 4 that device's unit is the functions at bus 1, device 0 with the
INTx line their position routes in the platform's tree, and no other
domain holds that line. Property 1 (one holder per unit) and property
9's development clause, which admits unconfined devices and reports
their domains in the trusted base, are kept as written. A seeded
manifest for each refusal: a second holder of the bridge's unit, a
`pcie` domain holding another unit, the VL805's line given apart from
its function, and an INTx line given to `qemu-xhci` on QEMU `virt`,
whose bus the platform record does not close.

### The VL805's firmware

The enumerator reads the VL805's configuration register `0x50`, its
firmware version, before it reports the function, and reports it
`ready` only when the value is neither 0 nor all ones, as FreeBSD's
check does (`bcm2838_xhci.c:113-136`), and `not_ready` otherwise, which
the domain library never gives
([design-pcie.md](design-pcie.md#the-catalogue-and-gives)). That check
and the bridge's `firmware_lost` mark below are the one gate: a
function is given only with its firmware running, on every path.

After a PERST# cycle the VL805 has no firmware unless an EEPROM on the
board gives it one; the VideoCore, whose own firmware holds both the
loader and the VL805's image, loads it on the mailbox's
`NOTIFY_XHCI_RESET` (facts record, sections 5 and 6). Linux sends that
notification after every PERST# cycle, once the function is enumerated
and before any xHCI register is touched, whether or not an EEPROM is
fitted; FreeBSD sends it only when `0x50` reads 0 or all ones, remarking
that boot firmware older than June 2020 cannot reload firmware already
installed (`:138-150`; facts record, section 8, item 16). erXos's rule
covers both: the notification is the last step of bring-up, so it
follows every PERST# cycle, the only time firmware is lost, and is sent
at no other time, so a kept link never asks a board's firmware to
reload what is present. The driver then waits 1 ms, as FreeBSD does
(Linux waits 200 to 1000 us), and reads `0x50` again (`:157-173`); a
value still 0 or all ones reports the function `not_ready`, and the
driver logs `vl805 firmware not loaded`. Probe B1
reads the register at erXos's start and again after a bring-up of
erXos's own, and records the firmware version, which the controller's
inspection record shows too.

The notification takes the mailbox, which only the kernel may reach
(PL2), so it is a narrow kernel call,
`erx_firmware_request(resource (CARVE), index)`. It sends the
notification at `index` among those the platform record lists for the
resource's device, here the VL805's one, index 0, that tag with the one
value the record gives, `bus << 20 | slot << 15 | function <<
12` for bus 1, device 0, function 0, that is `0x00100000`, and returns
a status alone, since the tag's answer is empty (facts record,
section 5). PL2's reason, that the mailbox can read the device key,
still holds: no driver reaches the mailbox, and the caller chooses
neither the tag nor the value. The call's contract, its deadline of
1 s, its answer checks, its one buffer page and its `ERX_EBUSY` beside
a request in flight, is
[design-kernel.md](design-kernel.md#firmware-requests)'s; what is the
VL805's:

* **Authority.** The resource is the bridge's own, carved with
  `ERX_CARVE_DEVICE` from the bridge's device entry, the one entry the
  platform record names with the notification, and carries `CARVE`, the
  right `erx_dma_create` takes for a device. Only the root task holds a
  resource, so the call is the device service's: the bridge driver
  asks for it with `pci_bus:firmware/1`, a facet only the PCIe domain
  holds, and the device service makes the call through the domain
  library, `erx_domain_lib:firmware(Bridge, bridge)`, with the resource the
  bridge's device record holds for its give, and answers with the
  result ([design-pcie.md](design-pcie.md#facets)). No new capability
  reaches the PCIe domain, and the call has the same caller in both
  phases. The call's other caller is the
  Bluetooth line's power cycle, two notifications of UART0's device on
  the Pi 4, which the device service makes from the same firmware worker
  through `erx_domain_lib:firmware(Device, {power, Phase})`, for a device
  record the system domain holds itself; `firmware(Bridge, bridge)` is
  that call for a bridge's first row, with the bridge's `firmware_lost` mark
  ([design-bluetooth.md](design-bluetooth.md#the-power-line)). Both
  are uses of `erx_domain_lib:firmware/2`, the one library call over
  the firmware's requests, which the board sensors' readings use too
  ([design-board-sensors.md](design-board-sensors.md#the-kernel-call)).
* **A timeout loses the VL805 for the boot.** After `ERX_ETIMEDOUT`
  every later firmware request of the boot answers `ERX_ETIMEDOUT` at
  once, so the VL805 stays out of the catalogue until the next boot,
  with `vl805 firmware not loaded`, as when its firmware does not load.
  The library call that meets `ERX_ETIMEDOUT` marks the bridge's
  catalogue entry `firmware_lost` before it returns, and the library's
  intake takes every function of a marked bridge as `not_ready`
  ([design-pcie.md](design-pcie.md#the-catalogue-and-gives)), so a late
  answer that loads the firmware after all, and a later start of the
  PCIe domain that then finds it present and keeps the bridge without a
  notification, still give nothing in that boot. Nothing asks the
  kernel again to learn of the timeout.
* **Against FreeBSD.** FreeBSD's property call waits 10 s
  (`bcm2835_mbox.c:244-247`); the 1 s is erXos's bound for every
  mailbox request, and probe B1 records how long this one takes.
  FreeBSD also checks the answer word against its request's buffer
  (`:348-351`), as erXos's kernel does, and its response code and the
  tag's response bit (`:352-374`); it frees its buffer after a
  timed-out read (`:424-436`), so a late answer there writes freed
  memory, where erXos never reuses the page.
* **Concurrency.** The device service makes every call from its one
  firmware worker
  ([design-system.md](design-system.md#devices), "Firmware requests"),
  so `ERX_EBUSY` arises only beside a trial request, or beside a call a
  restarted device service's old worker left in the kernel. A mailbox
  the trial request cannot take ends, as every failure of the trial
  request does, in the watchdog's reset.
* **The caller's end.** The device service runs in the root task, whose
  end ends the machine (K31). A PCIe domain that ends while its request
  is served loses only the answer; its successor's bring-up asks again
  after its own PERST# cycle.

On Fiasco the backend implements the call in the root task with the
same core and results; the root is the trusted base and Fiasco reads
no device secret. A call
that answers other than `ERX_OK` reports the function `not_ready`, with
`vl805 firmware not loaded`, and `0x50` is not read again. The
operation is what makes the bridge's reset path
work: without it, a reset would leave every board without the VL805's
EEPROM with no USB until the next boot, and under the microSD-only boot
order ([The boot firmware's handover](#the-bcm2711-bridge)) the boot
firmware may hand over a VL805 it never gave firmware. It is the mailbox's
third referrer in the kernel, beside the trial request and the
boot-time key read, and the chokepoint check that lists them names it.

Probe B1 is the operation's first boot on the board: the bridge driver
logs `0x50` at the bridge's start, again after the PERST# cycle, and
1 ms after the notification, with the notification's status and its
round trip in microseconds, one line each. Those lines record whether
the VL805's EEPROM is fitted, what `0x50` reads at erXos's start, the
firmware version the notification leaves, whether the boot firmware
reloads firmware already present, and a bound on how long the mailbox
took, since the round trip holds the facet's call and the device
service's queue; a boot of the test build that skips the
notification records what a missing notification looks like. The
operation's board test checks against those readings, so only its
expectations wait for the probe.

## The USB core

### The process tree

Each USB domain runs one top supervisor, `erx_usb`, registered under
that name, `one_for_one` with intensity 0, over two kinds of children,
started in two steps ([The rows](#the-rows)):

1. **The places**, `erx_usb_places_sup`, one per domain, which the boot
   script's start of `erx_usb` starts before init's ready report: one
   stream process per input number, one drive grant per window row the
   manifest names, and last the input tree's mint, `erx_fs_mint` of `usb_input`, whose mount
   reads the streams from the places once they have all started. They
   hold no device state, so they survive every failure beside them, and a
   reader outside the domain never sees its file end or its drive
   grant's pid die while the domain lives.
2. **A bus group**, `erx_usb_bus_sup`, for each controller the domain
   holds, which `erx_usb:start_controllers/0` adds once the ready answer
   brings the `pci` facet, given the places' pid; `one_for_all` over the
   controller process, the bus process and the function supervisor, whose
   children, one per function, are `temporary`. These three share the controller's
   state: a controller reset ends every device, so the controller's
   restart restarts the bus, which enumerates every port again, and every
   function, whose places it frees first.

The places never restart. `erx_usb_places_sup` and `erx_usb` both have
intensity 0 and every child of theirs is permanent but the bus groups,
so the end of a stream, of the mint or of the places ends the top
supervisor, the permanent application and the domain, whose restart is
the fresh try, as `erx_lfs_sup`'s end is the
storage domain's ([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)).
The domain service mints a service's grants only for a new incarnation
of its domain ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
so places made again within one incarnation would serve no reader. The
bus group restarts within itself at most `usb_bus_restarts_max` times
in any `usb_bus_restart_window_ms` (`abi/formats/usb.txt`), and is
`transient` under `erx_usb`: past its bound it ends with
`shutdown`, which is not restarted, so a controller that fails again
after every reset, a host controller error that returns, is given up
while the places stay, until the domain restarts. A
function instance is killed when it is stopped. Every driver starts
with `start_link/1` on one map: its claimed `function`, its device's EP0
as `control`, its own claimed `pipes` and the `places`, with the bus
process, the device's reference and the run number beside them and, for
a hub, its port count; it returns before any transfer and never calls
the bus process, which starts it in its own loop. Then it waits: the bus
process monitors the new instance and only then tells it to begin,
`{erx_usb_bus, go}`, and the driver's descriptor reads, its first
report and its first transfer all follow that message, so an instance
that ends at once still ends with its reason, never as a monitor's
`noproc`. A HID function may take its input number in its start, since
that touches no device. A device's reference names it within one bus
process's life; a restarted bus starts its references afresh, since
everything that held the old ones ended with it.

The bus process meets its controller through one module,
`erx_usb_bus_link`, which spells every message between the two. Once
started it finds the controller among its supervisor's children and
attaches to it; the controller answers with its root hub's port count
when its start reaches the bus (step 5 of [The controller
process](#the-controller-process)), and the bus core's first step powers
the root ports. From then on the bus process sends the core's requests as
the core makes them, and the controller sends root-port events and the
answers, each an event of the core.

A medium's block service runs under its BOT function, so it ends with
the function, and a medium's windows end with its block service.

### Ports, hubs and devices: the bus core

`erx_usb_bus_core:step(Event, Now, State) -> {State, Actions}` holds the
whole topology; `Now` is the time the event is handled at, from which
the step sets its deadlines. Its state is a map of hubs, the root hub among them, each
with its ports and its queue of ports to read, and of devices, each with its
place in the tree (the route of port numbers from the root), its speed,
its reference, its enumeration state, its configuration and its
functions; the **address-zero turn**, held from the start of one port's
reset until the controller answers its device's Address Device, follows
from the ports' states and from the one Address Device sent and not yet
answered, if any.

Each port is in one of these states. A **connection change** reported
for a port in any state first detaches the port's occupant, if it has
one, then moves the port to `settling` when its status says connected
and to `empty` otherwise, as FreeBSD's `uhub_reattach_port` frees the
old child before it reads the fresh status (`usb_hub.c:625-637`). So a
disconnect and a reconnect before the status is read never keep the
first device's reference, places or media; the table's last column lists
only the other ways out, and its times and counts are limits of
`abi/formats/usb.txt`:

| Port state | Meaning | Leaves on, besides a connection change |
| --- | --- | --- |
| `off` | not powered | the bus core's power-on request, one port of the hub at a time: `empty`; no port of the hub has its status read until the hub's power-good time has passed since the last port's answer |
| `empty` | powered, nothing connected | |
| `settling` | connected; waiting FreeBSD's power-up delay, `usb_power_up_delay_ms`, and, when `usb_port_attempts_max` attempts started on the port in the last `usb_port_attempt_window_ms`, until the oldest of them leaves that window | the deadline: `waiting`, an attempt started, or, past the attempts, `settling` with the later deadline |
| `waiting` | settled; waiting for the address-zero turn, in arrival order | the turn: `resetting` |
| `resetting` | port reset issued, holding the turn; deadline `usb_reset_deadline_ms` | reset done with the port enabled: `recovering`; reset done with the port disabled: `disabled`; the deadline or a speed the controller cannot run: `disabling` |
| `recovering` | FreeBSD's reset recovery, `usb_reset_recovery_ms`, holding the turn | the deadline: `enumerating` |
| `enumerating` | the device is addressed, read and configured; the turn passes to its Address Device when that is sent, and is released at that command's answer | configured: `running`; any failure: `disabling` |
| `disabling` | given up while its device may still be enabled: the occupant detached, the port being disabled at its hub; holding the turn if it, or a port below the hub on it, held it when given up | the hub's answer: `disabled` |
| `running` | the device's functions run | the port reported disabled by its hub: detach, `disabled`; a hub whose control pipe fails: `disabling` |
| `disabled` | given up; the port's last failure and its step are kept | none: only a connection change, whose settled port then waits for its attempts to allow another ([What a device can make the domain spend](#what-a-device-can-make-the-domain-spend)) |

Every port is reset before its device is addressed, a USB 3 root port
as much as any other, as FreeBSD resets every port in host mode
(`usb_hub.c:703`) and its xHCI root hub turns a reset into the port's
reset bit whatever the port's protocol (`xhci_roothub_exec`,
`xhci.c:3681-3684`), so the bus core has no case for a port's speed. A
root port's reset is done when its port event shows the reset change
(xHCI 4.3.1, p. 87); a hub port's when GET_STATUS, read every `usb_reset_poll_ms`,
shows the reset change or the reset bit clear, after which the change is
cleared, as `usbd_req_reset_port` does (`usb_request.c:805-863`).

The **address-zero turn** keeps one device at a time in the default
state, where every device answers address zero: a port takes the turn
when it starts its reset, the turn passes to its device's Address
Device when that command is sent, and it is given back when the
controller answers that Address Device, whatever the answer and whether
or not its device is still attached; the next `waiting` port takes it.
Until the command is sent a port holds the turn: the one in
`resetting`, `recovering`, `enumerating` before its Address Device, or
`disabling` after holding it. From then on the command holds it: the
state records the one Address Device sent and not yet answered, a fact
set only by the bus core's one function that makes requests, as it
makes that command, and cleared only by that command's answer. A
`waiting` port is granted the turn only when no port is in those states
and no Address Device is recorded. So a port that leaves those states by
any path, its hub's detach included, has given the turn back, and no
port path takes part in giving back the command's: a detach after the
command is sent applies at once, invalidating the device's reference,
functions and places, and leaves the turn with the command. The
controller answers every Address Device ([The controller
process](#the-controller-process), "A failed address"), and a command
past its 5 s deadline fails the controller, whose restart restarts the
bus, so the turn cannot hang. The answer is matched against the record
before the device's reference is looked up, so it is never dropped as
stale: for a detached device it gives back the turn and does nothing
more, except that `{error, {tt_clear, _}}` still detaches the
translator's hub. On xHCI the controller sends SET_ADDRESS itself
during Address Device (xHCI 4.3.4, p. 89); the turn still serializes
the resets, since two devices reset behind one hub would both answer
address zero.

A device's enumeration is a sequence of states inside `enumerating`, in
FreeBSD's order (`usb_alloc_device`, `usb_device.c:1752-2070`), each one
control transfer or one controller command whose answer is the next
event. Each request names the device's reference and the step it was
sent at, which the bus process attaches to the request it makes, and the
controller echoes both in the answer, never reading them from the device's
data; a device passes each step once, so
the two name one request, and an answer is taken only while the device
is at the step it names. An answer repeated, or arriving after its step
was left, is stale by construction and dropped, as a late answer for a
detached device is ([Concurrency](#concurrency)), except the Address
Device's answer, which gives back the turn; the bus core keeps no count
of what is in flight but that one Address Device. The steps:

1. **Address.** Enable a slot, then address it (Address Device with the
   block-set-address flag clear) from the parameters the bus core names:
   the route, the root port, the speed and, for a low- or full-speed
   device behind a high-speed hub, that hub's slot and port as its
   transaction translator and whether the hub runs one per port
   ([The TRB ring form](#the-trb-ring-form)). The command's completion
   answers the address the controller assigned, which the NIF reads from
   the slot's output context, as FreeBSD reads it (`xhci.c:1530`); the
   turn is released; FreeBSD's settle, `usb_set_address_settle_ms`, follows. A failed Address
   Device is answered only once the controller has cleaned up after it,
   the translator's buffer included ([The controller
   process](#the-controller-process), "A failed address"), and the turn
   is released only on that answer, so the translator serves no other
   device's enumeration before its buffer is clear.
2. **Device descriptor.** EP0 starts at its speed's packet size: 8 at
   low speed, 64 at high speed and 512 at SuperSpeed, "the only packet
   sizes allowed" there, and 8 at full speed, where the descriptor's
   `bMaxPacketSize0` decides (xHCI 4.3, p. 85; FreeBSD's
   `USB_MAX_IPACKET`, `usb.h:70`). So only a full-speed device has its
   first 8 bytes read first, as `usbd_setup_device_desc` does
   (`usb_request.c:1984-2026`), and when `bMaxPacketSize0` is not 8 an
   Evaluate Context updates EP0 (xHCI 4.8.2.1, p. 161); a value other
   than a power of two from 8 to `usb_ep0_packet_full_max`, the sizes
   FreeBSD's fallback tries (`usb_request.c:1998-2011`), refuses the
   device. Then all 18 bytes, which every other device has read at once.
   A hub at SuperSpeed is refused here (`superspeed_hub`).
3. **Strings.** The language table, then the manufacturer, product and
   serial strings in the table's first language whose primary language
   is English, its low byte 09h under the mask 00ffh, and in its first
   language when none is, as FreeBSD chooses (`usb_device.c:1717-1728`;
   `abi/formats/usb.txt`); a failure leaves the string unknown and
   does not fail the device.
4. **Configuration descriptor.** Its 9-byte header, then `wTotalLength`
   bytes, refused past `usb_config_max`, decoded and checked whole
   ([Descriptors](#descriptors)).
5. **Claim.** `erx_usb_claim:functions/3`.
6. **Configure.** SET_CONFIGURATION with the first configuration's value.
7. **Hub setup**, for a hub only: SET_INTERFACE to alternate setting 1 on
   a multi-TT hub; then the hub descriptor's 7-byte head,
   `usb_hub_descriptor_head`, which holds every field the stack reads;
   `uhub_attach` reads it again whole for 8 ports or more
   (`usb_hub.c:1262-1300`) for the port bitmaps after it, which erXos
   does not use. The slot's hub fields
   need it: xHCI's Configure Endpoint takes the hub flag, the port count
   from `bNbrPorts`, the think time from `wHubCharacteristics` and the
   multi-TT flag only once the multi-TT interface has been selected
   (xHCI 4.5.2, pp. 96-97).
8. **Endpoints.** One Configure Endpoint request adding every endpoint
   the claimed functions need, with the slot's hub fields for a hub
   (xHCI 4.3.5, p. 90: the request and the command together configure
   the device). The controller core posts it as Configure Endpoint
   commands of at most `xhci_configure_adds_max` adds each, one after
   the other, and answers the request once the last has succeeded, or
   with the first failure, after which no further part is posted
   ([What the DMA check judges](#what-the-dma-check-judges)).
9. **Start.** One function process per claimed interface, each with its
   pipes. A hub enters the bus core with every port `off`, and the bus
   core powers it as it powers the root hub: one port-power request at a
   time on the hub's control pipe, then the hub's power-good time,
   `bPwrOn2PwrGood` times 2 ms plus 20 ms (`usb_hub.c:1280-1281`), from
   the last port's answer, then every port's status. FreeBSD waits the
   time after each port (`usb_hub.c:1470-1513`); once after the last is
   enough, since every port's own time started earlier. So the bus core
   starts the next tier only once this hub and its transaction translator
   are set up, as xHCI asks (4.3, p. 87), and the hub's function only
   transfers on its status pipe. A port whose status agrees with the state the bus core
   holds for it is left as it is, so a hub function's restart re-reads
   its ports without disturbing the devices behind them.

**A function's end.** A function ends by its own decision, by a crash or
with its device. While the device stays, the bus core then asks the
controller for `reset_pipe` on each of the function's pipes other than
EP0, one at a time, and starts the function again only once every one
has answered `ok`: each reset answers the transfers its predecessor left
posted `stopped`, returning their buffers, and brings both sides of the
pipe back to the start of its toggle, so the new instance never meets a
transfer, a halt or a toggle of the old one. A reset that fails detaches
the device. Restarts are bounded as [Failure
handling](#failure-handling) says. A function never resets its own
pipes at start, so no class has to remember to. What a pipe reset
cannot restore is a class's own protocol state in the device: a BOT
device keeps the command its predecessor started, and every BOT
instance starts with its class's reset recovery for that reason
([The BOT engine](#the-bot-engine)).

Each instance of a function has a run number, which the bus core keeps
per function: 1 at the device's configuration, one more at each start
again. The core's start, `{start, Ref, Functions}`, pairs each function
with its number, and the bus process keeps the number with the instance
it starts and passes it back in that instance's end, `{function_ended,
Ref, Interface, Run, Reason}`, and, for a hub function, in each of its reports,
`{changed, Hub, Set, Run, Pid}`. The core takes an end or a report only
while the function runs as the instance it names, so one from an
earlier instance, repeated or late, is stale by construction and
changes nothing: it cannot reset a running instance's pipes and start a
second one, nor take `handled` from a hub function's successor, however
the bus process orders its messages. The numbers cannot stand in for an
end that never comes, so the bus process sends an instance's end at
least once: when its process ends, which its monitor gives, and when
its start fails.

An end carries its reason as it came, the reason the instance's process
ended or the Reason of the `{error, Reason}` its start answered, and the bus core alone reads
it. A function that cannot drive its interface, such as a HID
interface with no usable report, ends with `{shutdown, {unusable,
Reason}}`, or its start fails with that error, and the core takes that
end as final, as a FreeBSD driver whose probe answers ENXIO leaves the
interface unattached: it resets no pipe, starts no instance, counts the
end toward no bound and keeps the reason in the function's run, which
the device's inspection record shows. The function stays unused until
its device is enumerated again, and the device's other functions run
on, so a composite keyboard whose second interface carries only usages
no role takes keeps its keyboard. Every other end, a crash or a failed
transfer, is a failure, which the restarts bound ([Failure
handling](#failure-handling)). The end that goes past the bound is
named in the failure that gives the device's port up, which the port
keeps and the bus logs, by name only
([design-log.md](design-log.md#reports-carry-no-term)), so no frame's
arguments, report or buffer reaches the log:

| End | Named as | Example |
| --- | --- | --- |
| a shutdown made of atoms and integers | the end whole | `{shutdown, {transfer, stall}}` |
| any other shutdown | `shutdown` with its reason's leading atom | `{shutdown, transfer}` |
| a start that raised, `{'EXIT', Reason}` as the function supervisor answers it | `'EXIT'` with Reason's leading atom | `{'EXIT', undef}` |
| a crash | its reason's leading atom | `function_clause` |

Every end of the hub function is a
failure: it ends only on a failed transfer of its pipe or a crash.

A STALL, a timeout or a malformed answer ends the enumeration as
FreeBSD's error path does: the device is detached, the port is disabled
at its hub, by ClearPortFeature(PORT_ENABLE) or a root port's enable bit
(`usb_hub.c:827-832`), and holds the turn until the hub answers, so a
device left in the default state never meets the next port's reset,
and the port's inspection record keeps the step and the reason until its
connection changes (`usb_hub.c:820-839`).

**Detach** is one transition from any device state, and the only one
that ends a device: every function of the device and of every device
below it, if it is a hub, deepest first, is stopped; each of their places
is freed; each device's reference is dropped from the controller's map,
so its pipes answer `gone` from that moment; and the controller process
tears down each device's slot as
[the next section](#a-name-dies-at-once-hardware-is-freed-only-on-the-controllers-report)
says. The bus core waits for none of it: the port can take a new device
while the old slot drains, since the new device gets a slot of its own.
So a device's removal in the middle of any step leaves nothing behind,
and no list of steps needs a removal case of its own. One function writes
a port's occupancy, and it detaches the occupant a new state does not keep,
so the bus core holds a device exactly while a port holds it and no
path that moves a port can forget the device on it.

#### Hubs

A hub function keeps one status-change transfer posted on its interrupt
endpoint. Its report is a bitmap, bit 0 the hub itself and bit *n* port
*n*, at least as long as the hub's port count needs and decoded by
`erx_usb_hub_core`; bits above the port count are ignored, and a
shorter report names every port and the hub, as FreeBSD reads none of
the report and explores every port on any (`uhub_intr_callback`,
`usb_hub.c:185-218`, and `uhub_explore`, `usb_hub.c:993-1090`). The function
sends `{changed, Hub, Set, Pid}`, `Set` the ports and the hub the
bitmap names and `Pid` its own, to the bus process
and posts its next transfer only when the bus process answers
`{handled, Hub}`; a report that names nothing posts the next transfer at
once. The bus process gives the bus core the report with the run number
of the instance that sent it ([A function's
end](#ports-hubs-and-devices-the-bus-core)), and the core takes only the
running instance's. It keeps the pid of the report it is handling and
answers that pid alone, and drops it when the instance ends, so no
instance ever takes another's answer. Its first report, at
start, names the hub and every port, so each instance, a restarted one
included, has the bus core read every port's status once. The bus core
queues the ports of the bitmap the hub's queue does not hold yet, and
for each port in it, in turn, reads GET_STATUS, clears every change bit it read and
acts on what the status says; for bit 0 it reads and clears the hub's
own status. A read that saw a change queues its port again, behind the
ports already queued, so the port is read again after its last clear,
and only a read that sees no change takes it out: a change that latches between a read and its clear
is taken by the clear unseen, and only the read after the clear shows
what it left, as FreeBSD's `uhub_reattach_port` reads the port again
after it clears the connection change (`usb_hub.c:620-637`). When the
queue is empty it answers `handled`. A hub port's
GET_STATUS gives the speed of the device on it by the hub's own speed,
as FreeBSD's `uhub_reattach_port` reads it (`usb_hub.c:738-752`): on a
high-speed hub the high-speed bit, then the low-speed bit, else full
speed; on a full-speed hub the low-speed bit, else full speed. A root
port's words carry its PORTSC speed ID instead, and an ID other than
low, full, high or SuperSpeed refuses the device (`unsupported speed`);
the port's status and changes are still read and cleared, so its
disconnect is seen. The root hub
works the same way: the controller process turns a port event into
`{port_event, Port}`, and its port operations, register accesses of its
own, do not fail, so one that does ends the bus with its controller; and a root port raises no further event until
every one of its change bits is cleared (xHCI 4.19.2, p. 322). An
external hub's port operations are the hub class's GET_STATUS,
SET_FEATURE and CLEAR_FEATURE on the hub's EP0, which the bus process
sends to the controller as control requests tagged with the operation in
place of an enumeration step; the controller echoes the tag, and the
request's answer is the operation's.

So the work a hub can create is bounded by construction: one bitmap in
flight per hub, one queue per hub that holds each port at most
once, one operation in flight per hub, and one port at a time in
the address-zero turn. A hub that reports changes as fast as it can,
only waits longer for its next transfer. A port whose change bits set
again after every clear is read again behind the ports already queued,
so the root hub's other ports keep their turns; on an external hub it
also holds back `handled`, so while it keeps changing the hub reports
no other port, and the hub's EP0 carries its reads and clears back to
back.

An over-current change is cleared and logged once per enumeration
attempt, the first since the port's last attempt started, so a device
that reports connection and over-current changes on every read logs at
most one line more than its attempts, and
the port follows what its status then says, since the hub, not software,
cuts the port's power (FreeBSD's `uhub_explore`, `usb_hub.c:1036-1046`);
the over-current state and the count of changes show in the port's
inspection record. The Pi 4's 1.2 A budget across its ports is the
board's to enforce; the stack keeps no power budget.

### Descriptors

`erx_usb_desc`, a pure module, decodes everything a device returns
during enumeration by binary matching, with the checks FreeBSD makes, the
bounds above, and the rules that make a configuration one endpoint graph:

* a device descriptor is exactly 18 bytes of type 1; a configuration's
  header 9 bytes of type 2 with `wTotalLength` from 9 to
  `usb_config_max`;
* the walk takes one descriptor at a time, each with `bLength` at least
  2 and lying wholly inside `wTotalLength` (FreeBSD's walk stops below 3,
  `usb_parse.c:105`; erXos takes 2, the smallest header, and skips a
  descriptor it does not use, so a 2-byte vendor descriptor ends
  nothing); an interface descriptor is at least 9 bytes, an endpoint
  descriptor at least 7, a HID descriptor at least 9 with its report
  descriptor's length, a SuperSpeed endpoint companion at least 6, a hub
  descriptor at least 7 with its port count from 1 to 15; a hub
  descriptor arrives on its own request (enumeration step 7), so the
  walk skips one like any other descriptor it does not use, and only
  its 7-byte head, which holds every field the stack reads, is decoded,
  so a read cut short of `bLength` is enough;
* each endpoint descriptor belongs to the interface descriptor before
  it, and one before any interface descriptor refuses the configuration;
  `bNumEndpoints` is not trusted, the descriptors are; a SuperSpeed
  endpoint companion belongs to the endpoint descriptor just before it,
  and a companion anywhere else refuses the configuration; a HID
  descriptor belongs to the HID interface (class 03h) before it, one a
  setting, its first class descriptor the report descriptor, and a
  second one or another first class descriptor refuses the
  configuration; type 21h anywhere else, before any interface or under
  another class, is not HID's (DFU's functional descriptor, CCID's class
  descriptor) and is skipped, so it never refuses a composite device's
  HID function;
* the walk builds one map from `{interface number, alternate setting}`
  to that setting's descriptors, so a second definition of a key refuses
  the configuration (`duplicate interface`) instead of shadowing the
  first; the claim then looks up the one setting it selects for each
  interface number, and a setting it names that the map lacks, such as a
  multi-TT hub without alternate setting 1, refuses the configuration
  (`missing setting`);
* an endpoint descriptor whose address names endpoint 0, `0x00` or
  `0x80`, whatever its reserved bits 6:4 hold, refuses the configuration
  (`endpoint zero`), since its device context index would be EP0's, 1
  (xHCI 4.5.1, p. 96); an address is kept as its direction and number
  alone, so two that differ only in the reserved bits are one pipe;
  among the settings the claim selects every other endpoint address
  appears once, kept as the keys of a
  second map, and a duplicate refuses the configuration, so no two
  functions can claim the same pipe;
* an endpoint of a SuperSpeed device is followed by its companion, and a
  missing companion refuses the configuration; streams and the
  isochronous multiplier it may advertise are ignored, since the NIF
  forces both off;
* an endpoint's type, direction and interval are checked against what
  the claimed function accepts, and the four values the endpoint
  context takes are derived by speed and type, one function of the
  descriptor and the device's speed, `erx_usb_claim:parameters/2`:
  * the **packet size**, bits 10:0 of `wMaxPacketSize`, taken through
    FreeBSD's filter of standard sizes (`usbd_get_std_packet_size`,
    `usb_transfer.c:3525-3591`, applied at `:569-592`): an interrupt
    endpoint's at most 8 at low speed, 64 at full and 1024 at high and
    SuperSpeed; a bulk endpoint's 8, 16, 32 or 64 at full speed, 512 at
    high and 1024 at SuperSpeed, a value between them taken down to
    the size below;
  * the **burst**, zero-based: the companion's `bMaxBurst` at
    SuperSpeed; bits 12:11 of `wMaxPacketSize` on a high-speed interrupt
    endpoint, where 3, which FreeBSD calls an invalid packet count and
    clamps to 2 (`usb_transfer.c:502-513`), refuses the endpoint, since a
    value the device cannot mean is not one to guess at, as does a
    `bMaxBurst` above 15, which FreeBSD clamps (`usb_transfer.c:520-527`)
    and the context cannot hold, both with `malformed descriptor`; and 0
    on every other endpoint, as the context requires (xHCI 6.2.3.4,
    p. 455);
  * the **payload of one service interval**, by speed (4.14.2, p. 259).
    Below SuperSpeed, and on every bulk endpoint, it is the packet size
    times burst plus one (6.2.3.4, p. 455), computed with checked
    arithmetic, at most 1024 times 16. On a SuperSpeed interrupt
    endpoint it is the companion's `wBytesPerInterval`, which may be
    less than that product. A value above the product, which the
    endpoint's transfers cannot carry, or above 3 KiB, xHCI's largest
    SuperSpeed interrupt payload (4.14.2, p. 259), refuses the device
    with `endpoint too large`. A value of 0 is not one the sources call
    invalid, but erXos does not admit it, refusing the device with
    `zero interval payload`: the stack's interrupt endpoints are HID
    reports and hub status changes, so an interrupt endpoint that moves
    no bytes has no consumer in it. The same refusal meets a
    `wMaxPacketSize` whose bits 10:0 are 0, on any endpoint: FreeBSD
    raises it to the controller's largest packet before its filter
    (`usb_transfer.c:563-567`), a guess erXos does not make.
  * the **interval exponent**, the endpoint context's Interval, the
    period as a power of two of 125 us (xHCI 6.2.3.6 and Table 6-12,
    p. 456): on an interrupt endpoint at low and full speed, where
    `bInterval` counts milliseconds from 1 to 255, the base-2 logarithm
    of `bInterval` times 8 rounded down, 3 to 10; at high and SuperSpeed,
    where `bInterval` is 1 to 16, `bInterval` less one. A `bInterval`
    outside its speed's range, for which the table gives no period,
    refuses the device with `malformed descriptor`. A bulk endpoint's is
    0: the controller does not use it at SuperSpeed (6.2.3.6), and
    FreeBSD sets it only for periodic endpoints (`xhci.c:2463-2470`).
  The payload must fit one buffer of the queue block the endpoint's type
  takes, or the device is refused with `endpoint too large`. Its
  consumer is the controller's bandwidth reservation: the NIF writes the
  interval's payload into a periodic endpoint's context, and the
  controller reserves that much bus time each interval (4.14.2, p. 259;
  6.2.3.8, p. 457), so a device that declared more than its transfers
  can carry would take periodic bandwidth from every other device on the
  bus, and the product taken at SuperSpeed would reserve more than the
  device declared, or refuse an endpoint whose declared payload fits. The
  payload reaches the NIF as a parameter of its own, which the NIF checks
  against the packet size and burst it is given and against the queue's
  buffer ([What Erlang names and what the NIF
  builds](#the-trb-ring-form)). A bulk endpoint's largest payload,
  16 KiB, fits its 32 KiB buffer, so the rule never refuses one;
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
* `interrupt_in(Pipe, Tag, Length)`: posts one interrupt-IN transfer of
  up to `Length` bytes, at most the interrupt buffer; a transfer may span
  several packets and ends at a short packet, as xHCI schedules a TD
  (4.10.1.1, p. 191); it answers `ok`, and its completion, every failure
  included, a refusal of the pipe's state among them, arrives as a
  message `{usb, Pipe, Tag, Result}`, so a HID function keeps its
  transfers posted, waits in its own receive and has one failure path;
* `bulk_in(Pipe, Tag, Length)` and `bulk_out(Pipe, Tag, Binary)`, whose
  completions arrive the same way, each with the bytes the controller
  reports moved;
* `reset_pipe(Pipe)`: brings both sides of the pipe back to the start of
  its data toggle, whatever state the host's side is in, as one
  operation of the controller process
  ([The controller process](#the-controller-process)); answers `ok` or
  the error that ended it. New transfers on the pipe answer `{error,
  resetting}` until it finishes, and transfers still posted when the
  reset restarts the ring complete `{error, stopped}`, since the
  controller will never run them.

A non-control pipe that halts stays halted, its transfers answering
`{error, halted}`, until something resets it, since only the class
knows what its recovery is. Each class has one disposition for a
transfer that fails on its pipes, any answer but `ok`:

| Class | A failed transfer on its pipes | What follows |
| --- | --- | --- |
| HID | ends the function, with the failure as its reason | its input number's stream sees the end and writes `release`; the bus resets the pipes and starts the function again ([A function's end](#ports-hubs-and-devices-the-bus-core)) |
| hub | ends the function, with the failure as its reason | the same; the hub's ports and the devices behind them stay in the bus core's state, and the change bits a hub latches while no transfer is posted are reported by the new instance's first transfer |
| BOT | the engine's status flow or reset recovery ([The BOT engine](#the-bot-engine)), which calls `reset_pipe`; a failed reset recovery ends the function | the same as HID's once the function ends |

So no class keeps a pipe it cannot use: HID and hubs have no recovery
of their own to choose, and ending the function hands the pipes to the
one path that already resets them and bounds the restarts. EP0 is the
exception to all of it: every user of EP0 needs it open after a STALL,
so the controller process resets EP0 itself, by `reset_pipe`'s steps,
before it answers the stalled request `{error, stall}` (xHCI 4.10.2.1.2,
p. 196: a control endpoint's halt is cleared on the device by the next
SETUP), and a failed control request is an answer to its caller, never a
reason the pipe stays unusable.

Only the BOT engine's write functions in `erx_blk_write` call
`bulk_out/3` ([The block transport](#the-block-transport)).

## The xHCI driver

### The controller process

`erx_xhci`, the controller process, is an Erlang process over the device
NIF's TRB ring form. Its pure core, `erx_xhci_core`, decides; the
process performs.

**Start**, in the order of FreeBSD's `xhci_start_controller`
(`xhci.c:304-454`), every wait a deadline of the core and every NIF call
nonblocking:

1. for a controller that is a PCIe function, whose device record names
   its place, send `open` for that place through the domain's `pci`
   facet before the device is opened, so its window decodes and the
   function masters nothing while the driver resets it
   ([design-pcie.md](design-pcie.md#who-programs-what-and-when)); a
   refusal ends the start; a restarted controller sends it again;
2. read the capability registers: the slot, interrupter and port counts,
   the scratchpad count, the page size, `AC64`, the context size;
3. in the USB legacy support capability, set the OS-owned semaphore and
   wait for the BIOS-owned one to clear, at most 5 s, after which the
   driver goes on, as FreeBSD does (`xhci_pci.c:540-560`); read the
   supported-protocol capabilities, which say which ports are USB 2 and
   which USB 3;
4. `erx_device:negotiate/2`, the form's reset and install, called again
   with `continue` on a timer while it answers `{error, ebusy}`
   ([Install](#install)); the call that ends the reset writes a PCIe
   function's MSI-X table and answers `reset`, on which a PCIe
   function's controller sends `master` through the facet, which makes
   the route live and turns bus mastering on, and a part's controller
   calls its function's driver instead
   ([design-rp1.md](design-rp1.md#mastering)), and goes on at once with
   the call that installs, whose registers make the controller read and
   write memory; a refusal of `master` fails the controller as a refused
   install does;
5. answer its bus process, which attaches once its supervisor has
   started it ([The process tree](#the-process-tree)), with the root
   hub's port count, as soon as both the attach and this step have
   come, whichever comes last; the bus core
   powers and reads the root ports as it does any hub's, the controller
   turning the hub's port-power request into `PORTSC`'s port power bit,
   as FreeBSD's root hub does (`xhci_roothub_exec`, `xhci.c:3685-3687`),
   with the power-good time of FreeBSD's xHCI root hub descriptor, 10
   units (`xhci.c:3533`).

**Ports.** The controller process answers the bus core's root-hub
operations from each port's `PORTSC`. A write to `PORTSC` keeps its
read-write bits, writes zero to every change bit it does not mean to
clear, and never writes the port-enable bit, whose 1 disables the port,
except to disable; FreeBSD writes back the value it read with the bits
of `XHCI_PS_CLEAR` removed (`xhcireg.h:146`; `xhci.c:3633`), and erXos
derives the same mask from the access type of each field of the SVD
source, so no constant is copied by hand. A clear writes only those of
its change's bits that the port's last status read reported, so a bit
that set after that read, which the bus core has not seen, stays set for
the core's next read. The controller writes no `PORTSC` while it
is halted (xHCI 5.4.8, p. 405). A running controller answers an
operation on a port outside its port count `{error, badarg}`, and a
port event naming one is malformed and fails the controller, as any
malformed event does. The bus core reads a root port's changes
in the USB 2 hub words and clears each one it reads, and a root port
raises no further event until all of its change bits are clear (4.19.2,
p. 322), so every `PORTSC` change bit stands behind one USB 2 change: the
link state change behind the suspend change, which is how FreeBSD's
`C_PORT_SUSPEND` clears it (`xhci.c:3461-3463`); the warm reset change
behind the reset change, both the end of a reset
(`usb_hub.c:1091-1103`); and the configuration error change, a
SuperSpeed link that failed to come up, behind the enable change.

**Commands** run one at a time, each a post on the command queue whose
completion is the next command's start. A command not answered in 5 s
fails the controller: the process ends, and its restart resets it.

**Events.** An interrupt is a hint: the process clears `USBSTS`'s event
interrupt and `IMAN`'s interrupt pending, both write-one-to-clear, then
calls `erx_device:complete/2` until it answers `{ok, []}`, then
acknowledges the line, so a level-triggered INTx line is not left
asserted. A pass stops once it has read `xhci_events_per_interrupt`
events, two wraps of the event ring, where FreeBSD's `xhci_interrupt_poll`
stops (`xhci.c:1138`, `:1167-1176`), and acknowledges the line too. An
interrupt before the controller runs is held, not
acknowledged: a line the firmware left asserted, as the VL805's INTx
may be, stays masked until the install has reset the controller, and
its one acknowledgement goes out with the bus's start. A controller
that fails first does not acknowledge it, since the process's exit
unbinds the line, which masks it. Every controller of the kinds table is given with its
interrupt, an MSI or the Pi 4's INTx line
([A shared line is refused](#interrupts)), so events are never polled;
status is read about once a second. The process reads `USBSTS` on
every interrupt and, while the controller runs, every
`xhci_status_interval_ms` (1 s) whether interrupts come or not, and
fails the controller on a host system error (`HSE`), a host controller
error (`HCE`), which only a reset clears, or `HCH` set while it should be
running (xHCI 4.10.2.6, pp. 200-201; 4.24.1, p. 358; 5.4.2, pp.
397-399). A function that left the bus reads all ones, which
includes `HSE`, so a controller that stopped or vanished without an
interrupt fails within about a second rather than leaving its callers
waiting on completions that never come. Each completion is a transfer's, with its tag, completion code
and bytes; a command's, with its tag, code and, for enable slot, the
slot, for address device, the address; or a port's event, with the port.
Erlang names the codes from `abi/formats/xhci.txt`.

**Pipes.** The core keeps each pipe in one of four states, and every
operation on a pipe is a transition of this one machine, so recovery and
removal have one owner:

| Pipe state | Posts | Leaves on |
| --- | --- | --- |
| `open` | accepted | a transfer that halts: `halted`; `reset_pipe`: `resetting`; detach: `draining` |
| `halted` | `{error, halted}` | `reset_pipe`: `resetting`; detach: `draining` |
| `resetting` | `{error, resetting}` | the last step's success: `open`; a step's failure: `halted`, the requester answered with it; detach: `draining`, the requester answered `{error, gone}`, the step in flight's answer then stale: a request step names the device's reference, so its answer, which a CLEAR_TT_BUFFER on the hub's EP0 can bring after the slot is disabled and enabled again, never reaches the next device's reset |
| `draining` | `{error, gone}` | the slot's disable done: the pipe is gone |

`reset_pipe` chooses its steps by the queue's state as the NIF reports
it, as FreeBSD chooses by the endpoint's state
(`xhci_configure_reset_endpoint`, `xhci.c:3880-3960`), and in the order
xHCI 4.6.8 gives (pp. 130-132):

| Endpoint | Host side | Steps |
| --- | --- | --- |
| any | halted | Reset Endpoint, which resets the host's toggle; then, for a control or bulk endpoint of a low- or full-speed device behind a high-speed hub, CLEAR_TT_BUFFER on that hub's EP0 (wValue the endpoint number, the device's address, its direction and type; wIndex the hub port, or 1 on a single-TT hub; FreeBSD's `usbd_req_clear_tt_buffer`, `usb_request.c:2246-2270`); then, for any endpoint but a control one, CLEAR_FEATURE(ENDPOINT_HALT) on the device's EP0; then Set TR Dequeue Pointer to the queue's enqueue position, which every control endpoint needs after a reset (p. 131) |
| any | open with transfers posted | Stop Endpoint; then as stopped, or as halted when the stop answers a context state error because the endpoint halted meanwhile (4.6.9, p. 136) |
| EP0 | stopped | Set TR Dequeue Pointer to the queue's enqueue position, which drops what the stop kept of the request (4.6.9, p. 134); EP0 is never dropped and added, since Configure Endpoint ignores it (4.6.6, p. 116), and FreeBSD drops no control endpoint either (`xhci.c:3935-3944`) |
| EP0 | open with nothing posted | nothing: there is no request to drop, and the next one starts with its own setup stage |
| any other | stopped, or open with nothing posted | Configure Endpoint dropping and adding the endpoint, which resets the host's toggle of an endpoint that is not halted (p. 132); then CLEAR_FEATURE(ENDPOINT_HALT) |

So a halt is reset once, whoever asked; Reset Endpoint is issued only on
a halted endpoint, where it is valid (p. 129); and BOT's reset recovery,
which clears both bulk pipes whether or not they halted, resets each
host side the one way its state allows. Stop Endpoint answers a success
or a context state error; the only other code, a slot not enabled error,
cannot come for a slot the controller holds enabled (4.6.9, p. 140), so
it fails the controller, as a malformed answer does, and a pipe left
`halted` by a failed step never has a queue still running.

**Aborting a control request.** A control transfer not answered in 5 s
is aborted as xHCI asks (4.11.2.2, p. 214; 4.6.9, p. 134): EP0's pipe
goes to `resetting`, so new requests answer `{error, resetting}`; Stop
Endpoint; then the EP0 rows above, Set TR Dequeue Pointer to the
enqueue position on a stopped EP0 or the halted row's steps when the
stop finds it halted. EP0 carries one request at a time, so the
enqueue position lies past the whole aborted request, its setup, data
and status stages alike, and the controller never resumes any part of
it. At the last step's success the aborted request is answered
`{error, timeout}` and EP0 is `open` again; a step that fails or passes
its own 5 s fails the controller, as a command does.

**A failed address.** An Address Device that fails is cleaned up by the
controller core before the bus core hears of it. The core first
tears the slot down, the teardown below, whose Disable Slot is the
recovery xHCI gives for a USB Transaction Error there (4.6.5, p. 114);
there is one path to a disabled slot, not one for a failed address and
another for a detach. When the device sits behind a transaction
translator, the `tt` parameter of its Address Device, and the code is a
USB Transaction Error, the core then sends CLEAR_TT_BUFFER to the
translator's hub on that hub's EP0 for the default control endpoint at
address 0, the address the failed request was sent to: wValue endpoint
0, address 0, type control; wIndex the translator's port, or 1 on a
single-TT hub (4.6.5, p. 115), as FreeBSD clears a translator for a
device it enumerates again (`usbd_req_re_enumerate`,
`usb_request.c:2079-2101`), within the control request's 5 s. Only then
does it answer the Address Device `{error, {address, Code}}`, and the
bus core releases the address-zero turn on that answer, so no other
enumeration reaches the translator before its buffer is clear. A
CLEAR_TT_BUFFER that fails or passes its deadline answers `{error,
{tt_clear, Reason}}` instead, and the bus core detaches the hub whose
translator it is, as it detaches any device whose control pipe fails,
with every device behind it, whether or not the addressed device is
still attached; its port waits for a connection change or
a controller restart. On the Pi 4 that hub is the VL805's internal one,
so its USB 2 devices stay away until the controller's `restart`, which
the port's inspection record shows with the reason.

The controller answers every Address Device, since its answer is what
gives back the address-zero turn ([Ports, hubs and devices: the bus
core](#ports-hubs-and-devices-the-bus-core)). One still unposted when
the bus core detaches its device is answered `{error, gone}` and never
posted. One already posted is answered once it completes: with the
address on success, the teardown of the detached device's slot
following; after the cleanup above on failure. Its 5 s deadline holds
either way, so a command the controller never completes fails the
controller as any command does.

**Teardown** of a detached device's slot is the core's alone, as is the
reset of a pipe whose function ended: for each
queue of the slot open with transfers posted, Stop Endpoint, one command
at a time; a queue halted or stopped is left as it is. Once every queue
is stopped, halted or idle and every command for the slot has completed,
Disable Slot; at its success the NIF returns the slot's
buffers and blocks and clears its DCBAA entry. A stop that fails with a
context state error, because the endpoint halted meanwhile (xHCI 4.6.9,
p. 137), leaves the queue halted, which Disable Slot accepts as well. A
teardown is at most 8 stops and one disable, each bounded by the
command's 5 s; any other failure of either fails the controller. Since
commands run one at a time, a teardown's step is posted only when no
other command is in flight, and a command still waiting for the slot is
either a step of a reset of one of its pipes, which are `draining`, or a
bus command looked up through a reference no longer bound to the slot,
so none is ever posted after the teardown begins. A device detached
while its Enable Slot is posted leaves a slot nobody owns: the Enable
Slot is answered `{error, gone}`, and the slot is torn down the same way.

### The TRB ring form

xHCI moves everything through memory the controller reads and writes on
its own: a **command ring** and one **transfer ring** per endpoint, which
the CPU writes and the controller reads, each entry a 16-byte TRB whose
cycle bit tells the controller it is valid; an **event ring**, which the
controller writes; the **DCBAA**, an array of the device contexts'
addresses with the scratchpad array's in entry 0; a **device context**
per slot, which the controller writes; the **input context** a command
reads; and **scratchpad** pages only the controller uses. Nearly every
one of these holds device addresses, and a cycle bit or a link TRB makes
the controller fetch from an address, so under the DMA rules the NIF
builds all of it ([design-device-dma.md](design-device-dma.md#register-ownership)).
The form is the fourth beside the split ring, the register ring and
ADMA2, with a pure core, `erx_device_trb_form`, whose round function returns
observations and decisions to `run_call` like the others
([design-device-dma.md](design-device-dma.md#calls-observations-and-plans)).

**Memory, laid out once.** At install the form divides the record's DMA
memory into regions, each on a granule and each inside its 64 KiB
boundary (xHCI Table 6-1, pp. 439-440), by constants of the form and
counts read from the controller:

| Region | Size | Writer | Notes |
| --- | --- | --- | --- |
| DCBAA | `usb_devices_max + 1` entries | the CPU | written only by the sequencer: entry 0 at install; entry *k* at the publication of the Address Device that binds slot *k*'s EP0; and cleared when the core consumes Disable Slot's success (xHCI 6.1, p. 441; the note of 4.6.4, p. 110), never at its publication, while the controller still holds the slot; the controller reads no entry of a slot before its first Address Device or of a disabled one (6.1, p. 442); the DMA check never sees the DCBAA |
| scratchpad array | one entry for each page | the CPU | written at install, read only by the controller |
| scratchpad pages | the count the controller asks for, at most 64 pages of 4 KiB | the controller, from install to reset | never read by the CPU; install refuses a controller asking for more, or whose page size excludes 4 KiB (5.4.3, p. 400), with `{error, enotsup}` |
| event ring segment table | one entry | the CPU | written at install |
| event ring | one segment of 512 TRBs | the controller | read by observation, dequeue published through `ERDP` |
| command ring | 16 TRBs, the last a link back | the CPU | one command in flight |
| input context | one, 33 contexts of the controller's context size | the CPU, handed to the controller with each command that reads it | the command queue's one buffer |
| device contexts | one per slot, 32 contexts | the controller, while the slot is enabled | the controller's exactly while EP0 of the slot is bound in the ledger: zeroed and cleaned by the sequencer in the publication that binds EP0, before its doorbell (4.3.3 step 6, p. 89; 6.2.1, p. 443), and the CPU's again once Disable Slot's success ends that binding; the CPU reads one field, the slot's address after Address Device, and never an endpoint context's dequeue pointer or cycle state, which the VL805 writes back wrongly (facts record, section 5), since the NIF keeps both of its own |
| queue blocks | 16 control, 16 interrupt and 4 bulk | per block: its ring the CPU's, each buffer the device's while posted | below |

A **queue block** is a transfer ring of 16 TRBs, the last a link TRB back
to the first, and a pool of buffers: a control block one 4 KiB buffer, an
interrupt block four 1 KiB buffers, a bulk block two 32 KiB buffers, each
buffer aligned to its size so that none crosses a 64 KiB boundary, which
a TRB's buffer may not (6.4.1, p. 465). Nothing is allocated after
install. With at most 64 scratchpad pages, the record's memory is under
1 MiB, the `dma_memory` its device row gives. When a command binds a
block's ring to a new queue, the first time or a reuse, the sequencer
clears the ring, rebuilds its link, and sets its position to the ring's
base with cycle state 1 (4.3.3, p. 89; 6.2.3.1, p. 454). A ring is
bound only while no queue holds it, so a drop-and-add takes a free
block, and the old one is free again when the command succeeds. Set TR
Dequeue on an existing queue keeps the ring's position and cycle state.

**Two rules every ring keeps, on every controller.** Each is a quirk of
the VL805 that Linux handles for that controller alone (facts record,
section 5); here each is a property of the form, so no controller needs
a case of its own:

* **Every ring segment is followed by a pad of its own size**, inside
  the same 64 KiB boundary, zeroed at install and never written: the
  command ring, the event ring and each queue block's ring. The VL805
  prefetches past a segment's end, and with the pad what it reads there
  is memory of its own record, never a neighbour's buffer or another
  region. It costs about 17 KiB of the record.
* **A ring's position never rests on a link TRB.** A run whose last
  TRB lands just before the link takes the link with it, its cycle bit
  written with the run's later TRBs, behind the first, and the sequencer
  moves the ring's position to its first TRB with the cycle state
  toggled; its chain bit stays clear, since every TD the form builds is
  one TRB (3.2.9, p. 68), so a link stands alone between TDs (4.11.7,
  p. 235). Set TR Dequeue Pointer takes the ring's position from the
  ledger, so it never points the controller at a link TRB, which the
  VL805 misparses there.

**Queues and their states.** The queue of an endpoint is named
`{Slot, Dci}`, the slot and the endpoint's device context index
(xHCI 4.5.1, p. 96). It exists from the success of the command that adds
it, Address Device for EP0 and Configure Endpoint for the others, to the
success of the command that removes it, Configure Endpoint dropping it
or Disable Slot. The NIF keeps each queue's state from the controller's
own reports and accepts a command only in the states the specification
allows it, so the success of a removal is the controller's report that
it holds nothing of the ring:

| Queue state | Entered when | Posts | Commands the NIF accepts on it |
| --- | --- | --- | --- |
| `open` | the adding command succeeds; Set TR Dequeue or a drop-and-add succeeds | accepted | Stop Endpoint; drop-and-add or a drop only when nothing is posted |
| `stopping` | Stop Endpoint is posted | `{error, halted}` | none |
| `stopped` | Stop Endpoint or Reset Endpoint succeeds | `{error, halted}` | Set TR Dequeue; drop-and-add; drop |
| `halted` | a transfer event with an error code (every one halts, 4.10.2, p. 195) | `{error, halted}` | Reset Endpoint |

`erx_device:queue_state(Dev, {Slot, Dci})` reports a queue's state from
the NIF's own record, as the controller process chooses a reset's steps
by it ([The controller process](#the-controller-process)): `halted` and
`stopped` as the table has them, and an `open` or `stopping` queue
`busy` while a transfer is posted on it and `idle` otherwise, since a
stop changes the state only when its command completes; `badarg` for a
pair that names no queue.

Disable Slot is accepted when every queue of the slot is `stopped`,
`halted` or `open` with nothing posted, and no command for the slot is
in flight (4.6.4, pp. 109-110). When a command that restarts or removes
a ring succeeds, Set TR Dequeue to the enqueue position, a drop-and-add,
a drop or Disable Slot, every transfer still posted on that ring is
answered `stopped` and its buffer returns, since the controller will
never fetch those TRBs again; a removed queue's block returns with them.
Those answers are delivered ahead of the command's own completion, so
no transfer of a disabled slot is still in flight when its slot can be
enabled again for another device.
A command that fails changes no state and returns what it reserved.

**What Erlang names and what the NIF builds.** Commands are posted as
`erx_device:post(Dev, command, Tag, Command)`, each with bounded
parameters, from which the NIF writes every context and TRB:

| `Command` | Parameters | What the NIF builds |
| --- | --- | --- |
| `enable_slot` | | the TRB |
| `{address_device, Slot, Device}` | `route` (20 bits, four a tier, each tier 1 to 15), `root_port` (1 to the port count), `speed` (the port's speed number), `tt` (`none`, or the hub's slot, its port and whether it runs one TT per port), `ep0_packet` (8, 64 or 512) | the input control context adding the slot and EP0; the slot context with one context entry and interrupter 0; EP0's context: control type, the packet size, error count 3, interval 0, no streams, multiplier 0, average TRB length 8 (6.2.3, p. 454), its ring's base and cycle state 1 (4.3.3, pp. 88-89); the TRB with the block-set-address flag clear |
| `{evaluate_context, Slot, #{ep0_packet := P}}` | `P` 8 to 512 | the input control context adding EP0; EP0's whole context as Address Device builds it, with the new size and its bound ring's position and cycle state, since the sequencer writes every context the add flags name whole; accepted only while EP0 has nothing posted |
| `{configure_endpoints, Slot, Config}` | `add`: a list of endpoints, each with its number and direction, its type (control, bulk or interrupt; isochronous is `badarg`), its packet size, burst (0 to 15), interval exponent (0 to 15) and service-interval payload (1 to packet size times burst plus one, at most its queue block's buffer, and equal to that product unless the endpoint is an interrupt endpoint of a slot addressed at SuperSpeed); `drop`: a list of device context indexes; `hub`: `none` or its port count (1 to 15), think time (0 to 3) and multi-TT flag | the input control context's add and drop flags; the slot context with the fields Address Device addressed the slot with (route string, speed, root port, TT hub slot and port), the last valid index and the hub fields, a hub's think time and multi-TT flag only at high speed, where a slot at another speed keeps its addressed multi-TT flag and think time 0 (xHCI 6.2.2.2, p. 448); each added endpoint's context with error count 3, no streams (`MaxPStreams`, `LSA` and `HID` 0), multiplier 0, its ring's base and cycle state 1, the average TRB length, 8 for a control endpoint (6.2.3, p. 454) and otherwise an initial estimate of its packet size times its burst plus one, and the maximum service-interval payload from its payload parameter |
| `{stop_endpoint, Slot, Dci}`, `{reset_endpoint, Slot, Dci}` | | the TRB; Reset Endpoint with transfer-state-preserve clear |
| `{set_tr_dequeue, Slot, Dci}` | | the TRB, with the queue's own enqueue position and cycle state |
| `{disable_slot, Slot}` | | the TRB |

A parameter out of its range, a command on a queue in a state that does
not allow it, an add of a queue that exists, or an Address Device of a
slot no Enable Slot's success gave since its Disable Slot (4.6.5, p. 114)
is `badarg`. Erlang names no queue block: the NIF gives each added
endpoint the first block of its kind that no ring is bound to, and a
command with none left is `{error, full}`. No field that
says where the controller reads or writes, how it interprets an address
or how many bytes it moves there comes from Erlang: `MaxPStreams` above
0 would turn the dequeue pointer into the address of a stream context
array (6.2.3, p. 451), so the NIF writes it 0 on every context it
builds. A transfer is posted as `erx_device:post(Dev, {Slot, Dci}, Tag,
Transfer)`:

| `Transfer` | TRBs the NIF builds |
| --- | --- |
| `{control, Setup, none}` | a setup stage with the 8 bytes as immediate data, a status stage, interrupt on completion |
| `{control, Setup, {in, N}}` or `{control, Setup, {out, Bin}}` | a setup stage, a data stage over the block's buffer with interrupt on short packet, a status stage in the other direction with interrupt on completion (4.11.2.2, pp. 212-213) |
| `{normal, {in, N}}` or `{normal, {out, Bin}}` | one normal TRB over one buffer, interrupt on short packet and on completion |

The NIF writes every TRB's pointer, length, type, cycle, chain,
immediate-data, interrupt and link fields; the driver chooses only the
request's direction, length and setup bytes. `N` and `Bin` within the
buffer and the setup's own length equal to the data stage's are checked,
and a setup that is a standard SET_ADDRESS to the device is refused,
since xHCI answers it with a TRB error, which may halt the controller
(4.11.2.2, p. 214; 4.10.2.2, p. 197); each is `badarg`. The direction
is the form's to check, since the DMA check carries none
([design-device-dma.md](design-device-dma.md#the-rules)): a normal
transfer's direction must be its endpoint's, whose device context index
is its number times two plus the direction, 1 for IN and 0 for OUT
(4.5.1, p. 96), and a normal transfer on index 1, EP0, a control
endpoint, is refused; a control transfer's data stage must run in the
direction bit 7 of the setup's `bmRequestType` gives (4.11.2.2,
pp. 212-213; `usb_request_dir_in` of `abi/formats/usb.txt`); each is `badarg`. An added endpoint's
type comes from the same kind and direction that give its device
context index, so the context the NIF builds and the ring the queue
names never disagree on the direction.

**Publication.** A running controller takes a TRB as soon as its cycle
bit matches, doorbell or not (4.9.2, pp. 170-171), so the doorbell
cannot be the publication. The core describes a transfer's TRBs and
fills an `out` buffer's bytes; the sequencer writes the TRBs at the
ring's position, the first with its cycle bit still the controller's
old value and the rest, a link the run reaches included, behind it, and
cleans them; after the publish barrier it writes the first TRB's cycle
word, the run's activation, and cleans its line; then the doorbell,
after another barrier
([design-device-dma.md](design-device-dma.md#publication)). FreeBSD
publishes the same way: it flushes the chain, then toggles the one cycle
bit that activates it (`xhci.c:3010-3043`). A command is published the
same way on the command ring, with doorbell 0.

**Completing.** `complete(Dev, events)` acquires the event ring, at most 32 events a
call, and answers `{ok, Answers}` in the core's order, a transfer's
`{Tag, Code, Bytes}`, a command's `{Tag, Code, Extra}` and a root port's
`{port, Port}`: the sequencer, not the core, reads each event TRB's cycle word
from the ledger's consumer position, stops at the first not yet written,
and only then reads the events it covers whole, so the core is handed
only snapshots of events the controller had finished writing
([design-device-dma.md](design-device-dma.md#releases)). For each event
the core takes its type, slot, endpoint, TRB pointer, completion code,
length and event-data flag, and decides by its own state and the event
alone:

* A transfer event must name an enabled slot and one of its queues, have
  the event-data flag clear (the NIF builds no event data TRBs), and
  point at a TRB of the oldest transfer posted on that queue, since the
  controller runs a ring's TDs in order; a stop's event is the one
  exception below.
* **Short packet on a TRB that is not its transfer's last**, which only
  a control data stage can be: the bytes moved are that TRB's length
  less the event's residue; the transfer stays posted, since the status
  stage's event follows and only an event of the last TRB completes a TD
  (4.10.1.1.2, p. 193). A second such event for one transfer breaks the
  form.
* **Success or short packet on the transfer's last TRB** completes it.
  Its bytes are the data stage's recorded count when a short data event
  came, and otherwise its length less the event's residue.
* **An error code** on any TRB of the transfer completes it with that
  code and no bytes, and the queue becomes `halted` (4.10.2, p. 195).
  Its buffer stays the controller's in the ledger until a command that
  restarts or removes the ring succeeds, which a halted queue needs
  before it accepts a post again.
* **A stop's event**, Stopped, Stopped - Short Packet or Stopped - Length
  Invalid, is accepted only while a Stop Endpoint is in flight on its
  queue, at most one for each stop, and only when its pointer lies in
  the queue's **stop span**, and it completes nothing. The stop span is
  the run of ring positions from the queue's **retired position**, the
  last TRB of the transfer that most recently completed on it, or the
  position the ring last started at when none has completed since, up
  to and including the enqueue position, across the link. Every place
  Table 4-2 lets the controller rest when it stops lies in that run
  (pp. 137-139): the last TRB of a TD it already completed and reported,
  whose forced event follows that TD's own; a TRB inside a TD it was
  running; a link TRB, inside a TD or between two; and the enqueue
  position, the first TRB it has not been given. So a normal completion
  followed by the stop's forced event naming the same TRB is the common
  case, not an error. Keeping the span costs one ring position for each
  queue. A transfer a stop's event names stays posted, and is answered
  `stopped` with every other transfer of the ring when the command that
  restarts or removes the ring succeeds, as below; the NIF reads no
  length from a stop's event, so the difference between a residue and a
  count of bytes moved in those codes (4.6.9, p. 136) never reaches a
  decision. The stop's events precede its command completion (4.6.9,
  p. 134), and a halted ring's stop produces none (p. 139).
* A residue larger than its TRB's length, a pointer that names no TRB
  the rules allow, a stop's event with no stop in flight, outside the
  stop span or a second for one stop, an event of a
  type the NIF does not expect (an event ring full error among them) or
  a command completion that names no command in flight breaks the form,
  as a malformed used entry breaks a virtio queue: the events before it
  are returned, and every later call is `{error, broken}` until
  `negotiate/2` resets the controller.

A completed transfer copies its bytes into a fresh binary and answers
`{Tag, Code, Bytes}`; a command completion answers `{Tag, Code, Extra}`
and applies the state changes above; a port event answers `{port,
Port}`, with the port checked against the port count. Which buffers come
back is not the core's reading but the ledger's releases
([What the DMA check judges](#what-the-dma-check-judges)). The sequencer
writes `ERDP`, at the ledger's consumer position, with the busy bit
after the events a decision consumed, as FreeBSD does
(`xhci.c:1193-1196`) and the event ring's rules ask (4.9.4, p. 181).

**The event ring cannot fill.** A full event ring stops the controller's
rings until software advances `ERDP` and costs an entry for the error
event itself (4.9.4, Figure 4-12, p. 182). The ring is sized so that it
never fills, by counting what can be outstanding at once:

| Source | Events outstanding at most |
| --- | --- |
| control transfers: 16 blocks of one buffer, two events each (a short data stage and the status stage) | 32 |
| interrupt transfers: 16 blocks of four buffers, one event each | 64 |
| bulk transfers: 4 blocks of two buffers, one event each | 8 |
| the one command in flight: its completion, and, for Stop Endpoint, at most one stop's event beyond the transfers' own (4.6.9, Table 4-2, pp. 137-139) | 2 |
| root ports: one event each until its change bits are cleared (4.19.2, p. 322), at most 255 ports (5.3.3, p. 383) | 255 |
| total | 361 |

The ring's 512 entries hold 511 events (Figure 4-12, p. 182), so no
controller's port count can fill it and install refuses none for its
ports. The transfer rows hold by construction: the check's room rule
keeps a ring's TDs in flight below its block's buffers, though a
control transfer without a data stage names none, and the ledger takes
one command at a time
([design-device-dma.md](design-device-dma.md#the-ledger)). The NIF enables no other event: no microframe-index wrap, no
device notification, no event data. A controller that still reports a
full ring breaks the form, and its restart resets it.

#### What the DMA check judges

The core describes TRBs and input contexts; the sequencer writes them and
every other record the controller reads, and keeps the ledger of what
the controller holds
([design-device-dma.md](design-device-dma.md#the-check)). Fields and
marks come from `abi/formats/xhci.txt`. The TRB type (6.4.6, Table 6-91,
p. 511) is a TRB's selector, which the sequencer writes from the
meaning; a meaning the table does not offer is refused.

**What the core describes.**

| Table | Meanings | Names and lengths | Fixed or derived |
| --- | --- | --- | --- |
| each queue block's ring | normal, data stage, setup stage, status stage | normal and data stage: a buffer of the ring's own block and an offset, reaching the TRB's transfer length (6.4.1.1, p. 467; 6.4.1.2.2, p. 471); setup and status stage: none, the setup's parameter being its eight bytes (6.4.1.2.1, p. 469) | immediate data clear on normal and data stage, set on setup stage, and the setup stage's length 8 (FreeBSD's `xhci.c:1853`); chain clear; the interrupter target 0; the cycle bit, and the link at the segment's end, the sequencer's |
| the command ring | No Op, Enable Slot, Disable Slot, Stop Endpoint, Reset Endpoint, Address Device, Configure Endpoint, Evaluate Context, Set TR Dequeue Pointer | Address Device, Configure Endpoint and Evaluate Context: the input context, described in the same plan (6.4.3.4 to 6.4.3.6, pp. 490-492); Set TR Dequeue Pointer: its endpoint, whose bound ring's position and cycle state the sequencer writes as the pointer (6.4.3.9, pp. 494-495); No Op: nothing; the others: a slot and an endpoint, no address | block set address clear; Configure Endpoint's deconfigure, Reset Endpoint's transfer state preserve and Stop Endpoint's suspend clear; the stream ID 0; the slot and endpoint fields the sequencer's, from the command's reach |
| the input context | Address Device: the slot context and EP0's; Evaluate Context: EP0's; Configure Endpoint: the slot context, each endpoint it adds and the indexes it drops | each added endpoint context names a free queue block, whose ring the command binds to the endpoint; Evaluate Context's EP0 context points at EP0's bound ring | the add and drop flags, derived from the contexts carried: A0 and A1 alone for Address Device (4.6.5, p. 112), A1 for Evaluate Context, A0 and each added index for Configure Endpoint, with its drops (6.2.5.1, Tables 6-15 and 6-16, p. 461); each dequeue pointer the bound ring's position and cycle state (Table 6-10, p. 453); `MaxPStreams` 0, which otherwise makes the pointer a stream context array's (Table 6-8, p. 451), and `LSA`, `HID` and `Mult` 0; Configure Endpoint's slot context the fields the slot's last successful Address Device addressed it with, beside the stated hub fields, so it is refused on a slot with no such Address Device since its Disable Slot (6.2.2.2, p. 448); the interrupter target 0; Context Entries, the last index the slot's bindings leave valid (Table 6-4, p. 445); the average TRB length, 8 for a control endpoint (4.14.1.1, p. 258) and otherwise the packet times the burst plus one; each context at the controller's context size, 32 or 64 bytes (6.2.5, p. 460), which the layout holds from `HCCPARAMS1.CSZ`, written by the sequencer's one composition ([design-device-dma.md](design-device-dma.md#descriptions)) |

The interrupter target is 0 wherever it appears, since interrupter 0 is
the only one given an event ring, and events aimed at an interrupter
without one leave its ring undefined (5.5.2.3.1, p. 427).

**What the sequencer writes from the layout alone.** At install: DCBAA
entry 0, the scratchpad array's address (6.1, Table 6-3, p. 442); the
scratchpad array, one entry a page (6.6, Table 6-96, p. 516); the
segment table's one entry, the event ring's base and its 512 TRBs (6.5,
Tables 6-94 and 6-95, p. 515); `DCBAAP` (5.4.6, p. 403); `CONFIG`'s slot
count, the DCBAA's declared slot count (5.4.7, p. 404); `ERSTSZ` 1, since
0 leaves the primary event ring undefined (5.5.2.3.1, p. 427); `ERSTBA`,
the segment table (5.5.2.3.2, p. 428); `ERDP`, the event ring's first
TRB; `CRCR`, the command ring's first TRB with cycle state 1 (5.4.5,
p. 401); and every ring's link, its segment pointer its own ring's first
TRB, with toggle cycle set (6.4.4.1, pp. 504-505). Afterwards: slot *k*'s
device context zeroed and DCBAA entry *k* naming it, in the publication
that binds EP0 of slot *k*, and the entry cleared when the core consumes
Disable Slot's success (6.1, p. 441); every doorbell, with stream ID 0; `ERDP` after each decision
that consumes events.

**Bindings and holdings.**

* A transfer ring is bound to at most one endpoint, `{Slot, Dci}`.
  Only a command whose reach binds carries bindings, and Address Device
  and Configure Endpoint are separate reaches: Address Device binds EP0,
  index 1, and drops nothing (4.6.5, p. 112); Configure Endpoint adds
  and drops indexes 2 and up, since it ignores EP0's flags (4.6.6,
  p. 117). One command carries at most `ERX_DMA_BINDS_MAX` bindings,
  `xhci_configure_adds_max` of `abi/formats/xhci.txt`, 4, enough for a
  mass-storage interface's bulk IN and OUT or a composite device's
  interrupt endpoints; a configuration that adds more is added by
  several commands, and a failed one ends only its own bindings, so the
  earlier ones stay until the slot's Disable Slot. Each binds the named
  block's ring, which must be bound to nothing; no two bind one endpoint
  or one ring;
  and an endpoint already bound is bound again only by a command that
  drops it. A binding begins at the command's publication, and the
  sequencer initialises the ring then. A drop-and-add binds the new ring
  beside the old one, with the endpoint closed: success ends the old
  binding and retires its ring's transfers, and failure ends the new
  one. A failing command ends only its own bindings, but for a failed
  Address Device, which leaves its slot in the Default state (4.6.5,
  p. 114) with EP0 enabled on the ring the command named, so the
  controller may still hold it: that binding stays, EP0 `disabled`,
  until the Disable Slot that 4.6.5 recovers with (p. 114) succeeds and
  ends it. Until then EP0 takes no transfer, and no command that names
  it but Disable Slot: no stop, restart or drop, and no other Address
  Device binds it a ring. Every record that
  points an endpoint at a ring, Set TR
  Dequeue Pointer's and Evaluate Context's EP0 context, points it at a
  ring bound to it, so no endpoint is given another endpoint's ring, and
  with it another device's buffers.
* A transfer's TRBs name only buffers of their own ring's block. Its
  holding holds its TRBs, a link they reached, and its buffer.
* A command's holding holds its TRB and the input context it carries.
  One command is in flight at a time, the ledger's own fact: a table
  whose structure takes commands, one whose meanings have reaches in
  `abi/formats`, the command ring, takes a command only while no
  command's holding lives, and the hold sets it. The closure, a
  drop-and-add's two bindings and the answers below rest on it: one
  completion retires the transfers of one command.
* EP0's binding of slot *k* covers exactly the time the controller owns
  slot *k*'s device context, so the context needs no holding of its
  own. Address Device must bind EP0, an endpoint already bound is bound
  again only by a command that drops it, no command drops EP0, and only
  Disable Slot's success, or the controller's reset, ends that binding:
  every Address Device the check passes is the slot's first since its
  Disable Slot or the reset. Its publication zeroes and cleans the
  slot's device context and stores DCBAA entry *k*, naming the context,
  before the doorbell (xHCI 4.3.3 step 6, p. 89; 6.2.1, p. 443); when
  the core consumes Disable Slot's success, the completion's sequence
  zeroes entry *k* (6.1, p. 441; the note of 4.6.4, p. 110). A Disable
  Slot's publication writes no entry, since the controller holds the
  slot until the command completes. The DCBAA never enters the ledger:
  its places are the layout's, and the sequencer writes them
  (`erx_dma_publish_controller`, `erx_dma_clear_slot_entry`).
* A command's **reach** is its meaning's `reach` mark in
  `abi/formats/xhci.txt`, never a field a caller or the device supplies:
  `address` (Address Device), `configure` (Configure Endpoint), `stop`
  (Stop Endpoint and Reset Endpoint), `restart` (Set TR Dequeue
  Pointer), `disable` (Disable Slot), `evaluate` (Evaluate Context,
  which changes EP0's packet size and binds nothing, and holds EP0:
  running or stopped with nothing on its ring when it is published,
  as xHCI 1.2, 6.2.3.3 (p. 454) needs it running idle or stopped), or
  none (No Op and Enable Slot).
  The publication names the endpoints the reach acts on: the slot, the
  index a stop or a restart names, and the indexes a binding command
  drops, a mask of index bits. The ledger keeps them with the command's
  holding, and the sequencer writes the TRB's slot and endpoint fields
  from them, so the TRB names exactly the endpoints the ledger closes.
  Each reach's meaning (the endpoints it acts on, what it may bind and
  drop, what its success does to their rings and what its failure does
  to its own bindings) is one row of the ledger's reach rules, which
  the check, the closure and the completion all read; the generated list
  of reaches names a row for each, so a reach added to the marks does
  not build until it has one.
  While the command is in flight it **closes** the endpoints it acts on:
  those it binds or drops, the one it stops or restarts, EP0 for an
  evaluate, or every endpoint of its slot for a disable; a command with no reach closes
  nothing. A closed endpoint takes no transfer. The transfers a
  command's success retires are computed at its completion, every live
  holding on the rings it restarts or unbinds; since the closure admits
  no post in between, they are the ones live there at its publication.
  That is what makes the retired set exact: Set TR Dequeue Pointer moves
  the ring's dequeue to the pointer it was given, the ring's producer
  position at the publication (4.6.10, pp. 141-142), and a transfer
  published there afterwards, with its doorbell, would run although the
  completion said the ring had been moved past it. Stop Endpoint and
  Reset Endpoint retire nothing.
* An endpoint's **state** in the ledger is `disabled`, `running`,
  `stopped` or `halted`, the controller's states the form reaches
  (Figure 4-5, 4.8.3, p. 163), and changes only on what the trusted side
  did itself or consumed. An endpoint no ring is bound to is `disabled`.
  A binding's endpoint runs from its command's publication, closed
  until the command's success opens it (Figure 4-5, items 1, 2 and 6,
  p. 163), and is `disabled` again if the command fails, its binding
  ended, or for a failed Address Device kept as above. `running` is the
  queue table's `open`, the one state that takes a transfer; a consumed
  Stop Endpoint or Reset Endpoint success sets `stopped` (4.6.9, p. 140;
  4.6.8, p. 129), which takes none, so the controller never resumes a
  TD the form has answered, as it would resume the halted transfer a
  Reset Endpoint leaves on the ring; a consumed
  Disable Slot success sets every endpoint of its slot `disabled`, its
  bindings ended; a consumed transfer event with an error code sets
  `halted` (4.10.2, p. 195) and answers the ring's oldest live transfer
  with the code and no bytes, its holding kept until a command restarts
  or removes the ring. A Set TR Dequeue Pointer's success sets
  `running`, the queue open again: the controller's endpoint stays
  Stopped with its ring empty past the pointer until the next doorbell
  starts it (4.8.3, p. 165). Beyond its own bindings, a failed command
  changes no state: a
  Stop Endpoint that fails because
  the endpoint halted (4.8.3, p. 164) leaves it `halted` if the halting
  error event was consumed first, and otherwise `running` with the
  halting transfer live until that event is consumed. A transfer's
  holding ends only when its last event is consumed, so `running` with
  no live transfer is the specification's Running but idle: no transfer
  in progress, the ring empty and every event received (4.6.6, p. 117).
  The check's reach rule holds four rules on it:
  * no transfer is published on a closed endpoint, or on one that is not
    `running`: a `halted` one, whose doorbell the controller has
    disabled (4.6.8, p. 128), a `stopped` one, as the queue table
    refuses, or EP0 after a failed Address Device;
  * a Stop Endpoint names a `running` endpoint, a Reset Endpoint a
    `halted` one and a Set TR Dequeue Pointer a `stopped` one, the queue
    table's states (4.6.9, p. 140; 4.6.8, p. 129; 4.6.10, p. 141); the
    specification also defines Set TR Dequeue Pointer in the Error state
    a TRB Error enters (4.8.3, p. 164), which the ledger does not keep,
    since 4.10.2 (p. 195) halts the endpoint on every error. The controller
    answers any other with Context State Error, which changes nothing,
    but one that wrongly answered success, to a Set TR Dequeue Pointer on
    a running ring above all, would have the ledger retire transfers the
    device may still run and their buffers posted again, so the check
    refuses them itself;
  * a Configure Endpoint that drops an endpoint, alone or with an add, is
    published only when that endpoint is `stopped`, or `running` with no
    live transfer, the only states in which a drop is defined (4.6.6,
    p. 117; for drop-and-add, 4.6.8, p. 132), so a `halted` endpoint
    needs a successful Reset Endpoint first;
  * a Disable Slot is published only when no endpoint of its slot is
    `running` with a live transfer. It moves every endpoint of its slot
    from any state to Disabled, Halted named among them (Figure 4-5,
    item 4, p. 163; 4.8.3, p. 165), and a halted endpoint is out of the
    schedule with its doorbell disabled (4.6.8, p. 128); a running one
    must have nothing in progress and every event received (4.6.4,
    pp. 109-110).

  The core reads each endpoint's state and closure from the ledger to
  choose its commands, and the check refuses a plan that breaks any rule
  with `ERX_DMA_BREAKS_REACH`, which the core answers as `{error, halted}`
  for a transfer and `badarg` for a command, as the queue table's
  refusals are.

**Releases.** Each event is a snapshot the acquisition took at the event
ring's consumer position, after its cycle bit read as the ledger's
consumer cycle state there (4.9.4, p. 181; 4.11.3, p. 222), and is
consumed in order; the completion codes are Table 6-90's (p. 507).

| Event | Release |
| --- | --- |
| Transfer Event, Success or Short Packet, naming the last TRB of its ring's oldest live transfer, the ring bound to its slot and endpoint, since the controller runs a ring's TDs in order | that transfer's holding |
| any other Transfer Event: a short packet on a data stage, an error, a stop's, the last accepted only while a Stop Endpoint naming its endpoint is in flight and once for each stop | nothing: a transfer's holding ends only when the controller can no longer fetch it, its last TRB done or its ring moved past or removed |
| Command Completion naming the live command | the command's holding, on every code, and by the command and its code what the rows below add |
| Address Device or Configure Endpoint, failing | the bindings the command made, but a failed Address Device's, kept with EP0 `disabled` until Disable Slot succeeds (Bindings and holdings) |
| Configure Endpoint, succeeding | each binding of an endpoint it drops that was made before it, with the transfers its reach retires |
| Set TR Dequeue Pointer, succeeding | the transfers its reach retires, those live on the endpoint's ring at its publication |
| Disable Slot, succeeding | every binding of the slot, EP0's with it, so the slot's device context is the CPU's again and its DCBAA entry is cleared, and the transfers its reach retires |
| Port Status Change | nothing |
| the controller halted with its reset done, after the reset | every holding |

Stop Endpoint, Reset Endpoint and Evaluate Context release only their
own holding: the ring stays the endpoint's, and its transfers can be
fetched again. Each transfer a command's success retires is answered
`stopped` with no bytes under its own tag, before the command's own
answer, unless an error event answered it already, so the requester
waiting on the command, a pipe's reset among them, finds every transfer
of the ring answered when the command's answer reaches it; one completion
can give more answers than it has events: at most every holding but the
command's, which the ledger caps at `ERX_DMA_HOLDINGS_MAX` live holdings
across every ring, a Disable Slot's included. The core's reading of the same events gives each answer
and each queue's state, as [Completing](#the-trb-ring-form) says; where
the two meet, a transfer the core answers with bytes is one the event's
release returned, or the copy is refused.

#### Install

`negotiate/2` takes one step a call and answers `{error, ebusy}` while
the controller has not yet reported what the last step asked
([design-device-dma.md](design-device-dma.md#the-descriptor-forms)).
Each call begins a negotiation, whatever step the record keeps, as
virtio's and GENET's calls do, unless it passes `continue`, which only
the controller core's retry after `{error, ebusy}` does
(`erx_device:negotiate(Dev, continue)`). The record outlives the
controller process, but a restarted process starts from the core's
first state, whose first call cannot be a retry, so it begins afresh
rather than resuming its predecessor's step; and a retry that forgot
`continue` resets again on every call and fails at the deadline
instead of resuming silently. Its steps, each completed by a later
call: while the reset bit or the controller-not-ready bit reads set,
write nothing, so a reset under way, a predecessor's included, is
waited out rather than written over or begun again; while the
controller runs or its run bit reads set, clear run, on every call, so
a controller that missed one write is stopped by the next, and halted
comes within 16 ms (5.4.1, p. 393); once it reads halted with run
clear (run set could take it out of halted before the reset lands),
write the reset bit, allowed only once halted (p. 394); then wait for
the reset bit and the
controller-not-ready bit to clear before writing any other register
(p. 394; 4.2, p. 80); then, for a PCIe function's MSI-X route, write
its table from `hw/svd/pci_msix`, entry 0 the route's message unmasked
and every other entry masked, read entry 0's data back, and answer
`reset`, so the driver masters its function before any register lets
the controller read or write memory, as setting the segment table's
base does ([design-pcie.md](design-pcie.md#who-programs-what-and-when));
a controller with no route answers `reset` as well and its driver goes
on at once; then, on the next call, once the halted and
reset-done report has released every holding and every block is free,
the sequencer, in one decision, lays out and zeroes every region,
writes DCBAA entry 0, the scratchpad array, the segment table and the
command ring's link (a queue block's ring gets its link when a command
binds it), cleans them, and writes, each from the layout, the slot
count, `DCBAAP`, the event
ring's size and dequeue pointer, the segment table's base, the
interrupter's `IMAN.IE`, the command ring's base with its cycle state,
and `USBCMD` with run and `INTE`, in FreeBSD's order
(`xhci.c:329-428`, which writes `INTE` with run at `:427-428`). The
controller interrupts only with both gates open (4.2, p. 82), and a
reset closes `INTE` (5.4.1, p. 394), so both are written by this one
decision, which runs after every reset and opens both, since every
controller is given with its interrupt. `USBCMD.HSEE` stays clear: it
only signals a host system error out of band, on the bus, gated by
`SERR#` in the function's command register, which the PCIe domain
owns; the controller process reads it from `USBSTS` instead, on every
interrupt and about once a second ([The controller process](#the-controller-process)).
The segment table must be clean
before its base is written, since that write makes the controller read
the table and enables the event ring (4.2, p. 82), which is why FreeBSD
flushes first (`xhci.c:383-394`); the decision's handoffs clean every
region before the register that names it. The last step waits for the
controller to leave halted. Each wait is 1 s, as FreeBSD's loops
(`xhci.c:430-436`, `:469-477`, `:494-499`); since `{error, ebusy}` does
not say which wait it is in, the controller core holds one deadline for
the install, the three waits' sum from its first call, and fails the
controller past it. The scratchpad passes to the device for good.

**Registers it owns.** `DCBAAP`, `CRCR`, `CONFIG`, `ERSTSZ`, `ERSTBA`,
`ERDP`, every doorbell, `USBCMD`'s run bit and both resets (`HCRST` and
`LHCRST`), its save and restore bits (`CSS` and `CRS`), `USBCMD.INTE`,
`USBCMD.HSEE` and `IMAN.IE` are `ownedByNif` in `hw/svd/xhci/xhci.svd`:
the first group changes where the controller reads or writes, which
entries it takes as valid, or which of the DCBAA's entries it may
follow; a light reset returns the controller's state as `HCRST` does,
and a save or a restore moves that state to and from memory; and the
interrupt gates belong with the install that must open them again after
every reset, so no driver path can leave them closed on an
interrupt-driven controller. `PORTSC`, `USBSTS`'s change bits,
`IMAN`'s pending bit and the extended capabilities' registers are the
driver's.

**Address width.** TRBs and contexts carry 64-bit addresses; a
controller whose `AC64` is clear reaches 32 bits only, and the install
refuses, with `{error, erange}`, a record whose memory lies above that,
before it writes anything. The memory's addresses here are the ones the
device uses, its bus addresses, so a bridge that puts RAM above 4 GiB
on the bus, as the Pi 4's handed-over tree does at PCI `0x4_0000_0000`,
needs a controller with `AC64`. The VL805's narrower limit on physical
addresses is its bridge's ([The BCM2711 bridge](#the-bcm2711-bridge)).

### Registers at offsets the controller reports

xHCI's operational registers start at the capability registers'
`CAPLENGTH`, its runtime registers at `RTSOFF` and its doorbells at
`DBOFF` (`xhcireg.h:44-73`), and each controller reports its own. The
SVD source describes the four groups as clusters, and marks each of the
three movable clusters with the capability register and field its base
comes from, an erXos extension the generator checks. When the NIF opens
the record it reads the three values once, checks that each cluster lies
wholly inside the register window, and refuses the record with
`{error, {einval, {layout, Why, Read, Entries}}}` otherwise (the table
below); from then on every name resolves to a fixed
offset as for any peripheral. The ports, `PORTSC(n)` for `n` from 1 to
the port count, are an array of the operational cluster, and the
doorbells, `DB(n)` for `n` from 0 to `HCSPARAMS1`'s `MaxSlots`, one for
the command ring and one for each slot (4.7, 5.6, pp. 158 and 429), an
array of the doorbell cluster whose count is `MaxSlots` + 1; each is
checked the same way.

No two registers in different places share a byte. A place is the
registers at fixed offsets, or one instance of a movable cluster, and a
register's span in its place runs from its first element's first byte to
its last element's end; the generator keeps a place's own registers
apart. The gaps between a cluster's registers are free, so another
cluster may lie in them: the operational registers end at `CONFIG`, at
op + 0x38, and the ports start at op + 0x400 (`xhcireg.h:113-117`), and
the VL805 puts its doorbells, its runtime registers and its capability
list between the two. A register over another register, as runtime
registers at op + 0x400 over the first port, is refused.

The extended capabilities are a list whose head `HCCPARAMS1` names and
whose every entry names the next by a non-zero offset in words forward
from itself (7, p. 517). At open the NIF follows it once, at most 64
entries, each inside the window, and binds the legacy support capability
and the supported-protocol capabilities, at most 8, as clusters of the
same kind; since every step moves forward, the walk ends. A list longer
than 64 entries, an entry outside the window, a second legacy support
capability, a ninth supported protocol, or bases that put a register of
one cluster over one of another or over the capability registers
refuses the record the same way, and an entry of any other ID is passed over.

The refusal names its rule and the numbers it compared, so one boot of a
controller that is refused shows why. `Read` maps each register the open
read a base, a count or the list's head from (`caplength`, `hcsparams1`,
`hccparams1`, `dboff`, `rtsoff`) to the word it read, and `Entries` is
the list's entries followed, `{Offset, Id}` in list order, each offset in
bytes from the window's start. `Why` is one of:

| `Why` | The rule that failed |
| --- | --- |
| `{past_window, Register, Index, Offset, Bytes, WindowBytes}` | element `Index` of `Register` (0 for one that is not an array), `Bytes` wide at `Offset`, ends past the window's `WindowBytes`; `Offset` is `none` where the base and index give no 64-bit offset |
| `{unaligned, Register, Index, Offset, Bytes}` | that element's `Offset` is not a multiple of its width |
| `{overlap, Place, Place}` | two registers in different places, or a register and the span the NIF keeps, share a byte; each is named by its place and its span, `First` to `End`, from its first element's first byte to its last element's end there: `{fixed, First, End}` for one of the registers at fixed offsets, `{Cluster, Instance, First, End}` for one of an instance of a movable cluster (`operational`, `runtime`, `doorbell`, `legacy`, `protocol`), or `{msix_table, First, End}` for the span the NIF keeps |
| `{entry_past_window, Offset, WindowBytes}` | a list entry's word at `Offset` does not lie inside the window |
| `{list_too_long, 64}` | the list has more entries than the walk follows |
| `{too_many, Cluster, Instances}` | a list entry of `Cluster`'s capability past the `Instances` its cluster binds, the last of `Entries` |
| `{msix, Offset, Entries, WindowBytes}` | a PCIe function's MSI-X route the open does not bind: its table of `Entries` entries at `Offset` does not fit the window, `Offset` is not a multiple of 8, or `Entries` is more than the table declares |

Offsets are the device's own register offsets; no kernel handle or
address reaches the reason. The SVD
source declares the list's head once on the peripheral, and each kind of
capability as one cluster at offset 0 carrying its ID:
`LEGACY`, whose semaphores are two 8-bit registers, `BIOS_OWNED` at +2
and `OS_OWNED` at +3, each with its field `OWNED` in bit 0, since the
capability is written a byte at a time (7.1.1) and registers do not
overlap, and `PROTOCOL[%s]`, eight instances in list order, each with
`REVISION`, its word 0 with the major revision, and `PORTS`, its word 8
with the compatible port offset and count. The Erlang names are a
register's, an atom, and `{Name, Index}` for an instance, and
`erx_device:elements/2` says how many there are: `elements(Dev, revision)`
is the number of protocols bound and `elements(Dev, bios_owned)` 1 with a
legacy support capability and 0 without. This is a part of the device
NIF's register model
([design-runtime.md](design-runtime.md#the-device-nif)).

### `qemu-xhci` on QEMU `virt`

The PCIe enumerator assigns and reports the function's BAR 0, the give
carves it as the register window and creates one MSI
([On QEMU `virt`](#on-qemu-virt)). Whether the function offers a
function reset is read from its capabilities; the driver's own reset is
`HCRST`, inside `negotiate/2`. The facts the documentation does not
give, the capability registers and the port layout, are read at start
and shown in the controller's inspection record; the first QEMU run
records them in the facts record (probe 3,
[research-qemu-pcie-usb.md](research-qemu-pcie-usb.md#not-settled)).

### The VL805 on the Raspberry Pi 4

FreeBSD drives the VL805's xHCI as a generic one (`bcm2838_xhci.c:22-27`);
Linux's two trees carry quirks for it, which the next list takes one by
one. What is particular to it otherwise is on the PCIe side:

* **Where it is.** The manifest names it by place, bus 1, device 0,
  function 0, behind the Pi 4's bridge, and its device-kinds row matches
  only `1106:3483` there, as FreeBSD's position check does, so a
  commodity VIA card behind a replaced bridge is not taken for it
  (`bcm2838_xhci.c:94-101`).
* **Its firmware**, checked and if need be loaded by the PCIe domain
  ([The VL805's firmware](#the-vl805s-firmware)).
* **Its reach.** FreeBSD drives its DMA as 32-bit and keeps it below
  960 MiB, and Linux gives it a 36-bit or 40-bit mask; with the
  handed-over tree's window at PCI `0x4_0000_0000` it can run only if it
  reports `AC64` ([Address width](#install));
  its record's DMA range comes from the bridge's `dma-ranges`, whose PCI
  addresses take three cells, which the DMA-range walk reads
  ([design-device-tree.md](design-device-tree.md#the-reader));
  its contiguous memory lies below physical address `0x3c000000`, the
  bridge's `dma_limit` ([design-pcie.md](design-pcie.md#dma)), until probe B5
  shows where the limit really is. The bridge driver programs the inbound
  window from the same range.
* **Its interrupt**: the INTx line of its position
  ([Interrupts](#interrupts)).
* **Its trust.** Its DMA is unconfined, so the USB domain is in the
  trusted base, holds the VL805's unit alone in a release build, and runs
  no file system, as property 9 asks of every unconfined device's domain
  ([design-system.md](design-system.md#devices)). The VL805 runs firmware
  the VideoCore loaded, which erXos neither chooses nor checks, as it
  trusts the firmware that boots the board
  ([design.md](design.md#residual-risks), "Closed firmware, and verified
  boot only where secure boot is on").
* **Its topology.** Every USB 2 device is behind the VL805's internal
  high-speed hub, so the Pi 4's keyboards and mice need the hub function
  and the transaction translator fields of
  [enumeration](#ports-hubs-and-devices-the-bus-core); no Pi-specific
  code follows from it.
* **Its quirks** (facts record, section 5), each decided by whether
  erXos can meet the condition it fixes:

  | Quirk | Where Linux has it | erXos |
  | --- | --- | --- |
  | the controller prefetches past a ring segment's end | mainline: every segment allocated twice its size | every ring of the form is padded, on every controller ([Two rules every ring keeps](#the-trb-ring-form)) |
  | the dequeue cycle state written back into an endpoint context is wrong | the Pi tree: the cycle taken from the TRB at the hardware dequeue pointer | not met: the NIF never reads an endpoint context's dequeue pointer or cycle state, and keeps both itself |
  | a dequeue pointer set onto a link TRB is misparsed | the Pi tree: a moved dequeue pointer steps past a link | not met: the enqueue position, which Set TR Dequeue takes, never rests on a link, on every controller |
  | SuperSpeed bulk-out bursts fail for mass storage behind a hub | the Pi tree: burst 0 for such an endpoint when the route string is not 0 | not met: no SuperSpeed hub is driven ([What the USB domain claims](#what-the-usb-domain-claims)), so a SuperSpeed device has route 0; it comes with SuperSpeed hubs, as a row of the quirk set below |
  | a full-speed device on the internal translator can babble when a TD reaches an idle ring late in microframe 7, with firmware below `0x0138C0` | the Pi tree: before such a doorbell, wait up to 200 us until `MFINDEX`'s low three bits are not 0 | not carried: B1 records the board's firmware version, and the board checklist's full-speed keyboard shows port babble in its inspection record if it happens; only then does the wait enter, as a row of the quirk set |
  | USB 2 link power management, reset on resume | mainline | not met: erXos enables no link power management and does not suspend |

  So the VL805 needs no case in the driver. A quirk that erXos
  must one day carry has one home, the **quirk set**: a field of the
  controller's device-kinds row, read by the TRB form at install and
  applied inside the NIF's decisions, so it is never a check scattered
  through the Erlang driver. Nothing of it is built until a row needs a
  member.

## HID

A HID function, `erx_usb_hid`, drives one HID interface: it reads the
interface's report descriptor, chooses the protocol, keeps interrupt-IN
transfers posted, folds each report into input records and writes them
into its input number. Its pure parts are `erx_hid_desc`, the report
descriptor's parser, and `erx_hid_core`, the protocol's plan and the fold.
The bus process starts it with the claimed function, the device's
control pipe, the function's interrupt-IN pipe and the controller's
places; it takes its input number first, so a start that finds none
fails, as unusable, and does the rest once the bus process tells it to
go. It
ends by its own decision with `{shutdown, {transfer, Reason}}` on a
failed transfer, which the bus restarts, or `{shutdown, {unusable,
Reason}}` on a plan that cannot drive the interface, which the bus
takes as final, so an expected end such as a detach is not logged as a
crash.

### The report descriptor

`erx_hid_desc:parse/1` takes the decisions of FreeBSD's item parser
(`hid_get_item`, `hid.c`) and is written as binary matching over the
descriptor: short items of 0, 1, 2
or 4 bytes of data and long items, which it skips (`hid.c:305-318`);
global items kept in a state with a push stack of four levels, the
current one included, so at most three pushes outstanding; local items
reset at each main item; collections counted. Its bounds are FreeBSD's:
at most 64 usages a main item, 16 report ids and a report count of 2048
(`hid.c:66-69`). Where FreeBSD stops parsing at a fourth nested push and
keeps what it read (`hid.c:446-450`), erXos refuses the descriptor, so a
layout is never built from part of one. erXos adds two bounds: an input
report of at most the interrupt buffer, 1 KiB with its report-id byte,
and a descriptor of at most `hid_report_descriptor_max`. It also refuses
a report id of 0 or above 255, since a report carries its id in one byte
and HID 1.11 reserves 0 (section 6.2.2.7); input items, padding
included, both outside and inside numbered reports, since a report then
cannot say which it is; an item cut off by the descriptor's end, whose missing bytes
FreeBSD reads as zero; and a data input field wider than 32 bits. Its
result is a
**layout**: for each report id, the input fields in order, each a bit
offset, a size from 1 to 32 bits, a count, a logical minimum and maximum,
a usage page and its usages or usage range, and the flags variable or
array, relative or absolute; and the length of the largest input report.
Output and feature fields are parsed for their offsets and otherwise
ignored.

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
are left for a later version.

### The protocol

HID 1.11 says that a device starts in the report protocol but the host
should set the one it wants (section 7.2.6), and only a boot interface
(subclass 1) supports SET_PROTOCOL at all (section 4.3). The function
reads the report descriptor and parses it, then:

* on a boot interface whose descriptor parsed to a layout with a role,
  sends SET_PROTOCOL(report) and uses the parsed layout;
* on a boot interface whose descriptor the parser refused, whose layout
  has no role or whose read failed, sends SET_PROTOCOL(boot) and uses
  the boot layout of Appendix B.1 (keyboard) or B.2 (mouse), which has
  no report ids: the layout the parser makes of FreeBSD's boot
  descriptors (`hidrdesc.h:307-368`), so every layout comes from the one
  parser;
* on any other interface, uses the parsed layout or ends unusable with
  the parser's reason, `no_usable_report`, or the failed read's, except
  that a read that timed out or met a controller error ends the function
  with `{shutdown, {report_descriptor, Reason}}`, a counted failure the
  bus restarts within its bound, since the next read may succeed;
* on a keyboard, a layout with the keys role, sends SET_IDLE(0), so it
  reports only on change.

It ignores the answers of SET_PROTOCOL and SET_IDLE, as FreeBSD does
(`hkbd.c:1011-1025`): a device that refuses them still reports, and one
that has gone fails its first transfer. A keyboard is known by its
usages, as every role is, not by its interface's protocol, so a
keyboard that is not a boot interface is set idle too.

So the boot protocol is the fallback for a descriptor the parser
refuses, not a mode of its own, and a tablet, which has no boot
protocol, works because the parser is always tried first.

### From reports to records

The function keeps four interrupt-IN transfers posted, each of the
layout's largest input report, plus its report-id byte when the layout
has report ids, as FreeBSD sizes its interrupt transfer
(`usbhid.c:380-384`); a report longer than one packet arrives whole,
since a transfer ends only at its length or a short packet (HID 1.11,
section 8.4; xHCI 4.10.1.1, p. 191).

`erx_hid_core:step(Layout, Report, State) -> {State, Records}` keeps,
for each report id the layout has, what its last report of that id
left: the keys and buttons it held and its absolute position, not the
fields' values; and derives the held set, the keys and buttons held, as
the union over every id. A report of
id *k* replaces only id *k*'s entry, as FreeBSD's keyboard driver clears
and sets only the keys of the received id (`hkbd.c:706-745`), so a
report of id 2 never releases a key that id 1 holds. Then:

* **Keys.** Id *k*'s keys are its modifier bits set and its array's
  usages, each mapped to an evdev code through the usage table below.
  Each key in the old held set and not the new gives `{key, up, Code}`,
  then each in the new and not the old `{key, down, Code}`, in ascending
  code order, so a report that changes several keys gives a
  deterministic sequence. A report whose array values that name a
  Keyboard/Keypad page usage all hold ErrorRollOver (usage 01h) is the phantom state of
  Appendix C and changes nothing. An array value above the field's
  logical maximum still names a usage, the one at `v - min` of its
  usage ranges when they reach that far, since the fold checks only the
  minimum. A usage the table maps to no code is dropped and
  counted.
* **Pointer.** A relative X and Y give `{pointer, rel, DX, DY}` when
  either is non-zero. An absolute X and Y are clamped to their logical
  range and spread across a record's axis by `erx_input_codec:axis/3`,
  as the virtio-input driver does
  ([design-display.md](design-display.md#the-display-device)), giving
  `{pointer, abs, X, Y}` when either changed from its id's last report;
  a range whose maximum is not above its minimum makes the layout's
  pointer role absent.
* **Buttons** give key records with their `BTN_` codes on each edge of
  the held set.
* **Wheel.** A non-zero wheel gives `{wheel, Steps}`, clamped to -128 to
  127. A wheel field without the relative flag is read the same way, so
  it scrolls on every report in which it is non-zero.

Moves come before button edges within one report, so a click lands where
the report put the pointer. The state holds one entry per report id, at
most 16, each bounded by its fields, so its size is fixed by the layout
however long the device reports.

When a transfer completes the function folds the report, writes the
records into its input number and posts the transfer again only once the
number's stream has taken them; a stream holds at most one read's worth,
64 KiB, so a display that stops reading stops the function, whose device
then waits with its reports, as a virtio-input device waits on its full
buffers ([design-display.md](design-display.md#the-display-device)). A
report shorter than its id's fields, or of a report id the layout lacks,
is dropped and counted; one the parser's offsets would read past is
impossible, since every field lies inside the report length the layout
fixed.

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
fails on any entry that differs. `abi/formats/evdev.txt` holds every key
code the map names (keypad keys, F13 to F24,
`KEY_102ND`, `KEY_COMPOSE` and the others FreeBSD's table names), since
it holds every code erXos reads; a code with no row in a keymap is
dropped and counted by the router
([design-display.md](design-display.md#input-events)).

## Mass storage

### The BOT engine

A mass-storage function, `erx_usb_bot`, drives one Bulk-Only interface,
its logical units and their media. Its pure core, `erx_usb_bot_core`,
takes the protocol of FreeBSD's nine transfer states
(`umass.c:185-194`) as one state machine whose events are the pipes'
completions and the queued requests, and whose actions are transfers:

| State | Transfer | Next |
| --- | --- | --- |
| `command` | the CBW on bulk-out | data, or status when the command moves no data; a STALL: reset |
| `data_in`, `data_out` | the data phase on bulk-in or bulk-out | status; a STALL: `clear_data` |
| `clear_data` | `reset_pipe` on the data pipe | status |
| `status` | the CSW on bulk-in | the CSW checked: status 1 on the operation's own command, `command` for its REQUEST SENSE; otherwise the operation done; a STALL: `clear_status` |
| `clear_status` | `reset_pipe` on bulk-in | `status_again` |
| `status_again` | the CSW on bulk-in, once more | as `status`; a STALL: reset |
| `reset_1`, `reset_2`, `reset_3` | the Bulk-Only Mass Storage Reset, then `reset_pipe` on bulk-in, then on bulk-out | the operation done, failed; at the function's start (below), Get Max LUN |

The engine's unit of work is an **operation**: one request of the
queue, its command and, when that command fails, its REQUEST SENSE. The
engine takes the next request from the queue only once the current
operation is done, so nothing runs between a failed command and the
sense that explains it.

The status states follow Figure 2 of BOT 1.0. A CSW is valid when it is
13 bytes, its signature is 53425355h and its tag is the CBW's (section
6.3.1), and meaningful when its status is 0 or 1 with a residue no
larger than the CBW's length, or 2 (section 6.3.2). An invalid CSW and a
phase error (status 2) go to reset (sections 5.3.3.1 and 6.5), as
FreeBSD's checks do (`umass.c:1555-1620`); a residue larger than the
length, which FreeBSD truncates, makes the CSW not meaningful, and the
engine resets too, since a device that cannot count its bytes is not
trusted with their meaning. The tag is a counter the engine keeps, so a
CSW left over from an earlier command of the same instance never
matches; one left by a predecessor is not there to be read, since the
reset recovery every instance starts with readies the device for a new
CBW (below). One command is in
flight on an interface at a time, so a card reader's logical units share
it in turn.

**What a command moved.** For each command the engine knows its CBW's
length *L* and direction, the bytes *A* the data phase moved, as the
controller reported them, and the CSW's status and residue *R*:

* a READ succeeds only with status 0, *R* = 0 and *A* = *L*, and a WRITE
  only with status 0, *R* = 0, the device having processed every byte
  (BOT section 5.2, p. 15), and *A* = *L*; any other status-0 outcome is
  `{error, {device, short}}`, with the protocol still in step, so no
  reset follows;
* a command that reads metadata takes its relevant bytes, *L* - *R*,
  which must not exceed *A*, else the CSW is not meaningful and the
  engine resets; its decoder reads only those bytes and has a minimum:
  INQUIRY 5 bytes, for the device type and the removable bit, with the
  vendor and product text taken when 32 are there; REQUEST SENSE 14, in
  fixed format; READ CAPACITY(10) 8; READ CAPACITY(16) 12; fewer is
  `{error, {device, short}}`;
* a command with no data phase has *L* = 0, so *R* is 0.

**Autosense.** A CSW with status 1 says the command failed, and the
device holds the reason until the next command. So the operation stays
current and the engine runs REQUEST SENSE for the same unit through the
same states, its own CBW, an 18-byte data-in phase and its own CSW,
under the operation's deadline, as FreeBSD starts the sense from the
failed command's completion before it completes the request
(`umass.c:2588-2610`). The step that checks the sense's CSW completes
the operation:

* **A sense read**: status 0, at least 14 relevant bytes, and response
  code 70h or 71h, the fixed formats (`SSD_CURRENT_ERROR`,
  `SSD_DEFERRED_ERROR`, `scsi_all.h:3296-3297`). The request is answered
  `{error, {device, {sense, Key, Asc, Ascq}}}`, and when the key is NOT
  READY or UNIT ATTENTION the unit's medium ends in that same step
  ([Media and drives](#media-and-drives)), before the engine takes
  another request, so no queued request, a readiness poll included, runs
  against a medium the sense has just ended.
* **A sense that fails**: a CSW of status 1 or a phase error, an invalid
  CSW, a STALL, fewer than 14 bytes or another response code. The engine
  asks no sense for the sense: the operation ends there, after reset
  recovery when the CSW calls for it, the request is answered
  `{error, {device, no_sense}}`, and the unit's medium ends, since
  whatever the device meant to report is unknown and a medium kept
  across a change it could not see would be written with another
  medium's blocks.

**The start.** Every instance of the function begins with reset
recovery, the states `reset_1` to `reset_3` above, before it sends Get
Max LUN or any CBW. A predecessor that ended after the device accepted
its CBW, during its data phase or with its CSW still to be read leaves
the device inside that command, still expecting data or holding a CSW.
The bus core's pipe resets do not end that command: they clear halts
and toggles, which the device keeps through a class reset anyway (BOT
1.0, section 3.1, p. 7). A CBW is valid only after the device has sent
a CSW or after a reset (section 6.2.1, p. 17), and reset recovery is
the class reset, then a clear of bulk-in's halt, then of bulk-out's
(section 5.3.4, p. 16). The first instance runs the same recovery: it
costs one control request and two pipe resets at attach, and spares the
function knowing whether it replaces another, so no start is a special
case. A step that fails ends the function, which the bus restarts within
its bound before it detaches the device ([Failure
handling](#failure-handling)). Detaching the device whenever a BOT
function ends would restore the boundary too, but is not taken: a crash
would cost the drive until it is plugged in again, since a detached
port stays disabled until its connection changes, and the bus core
would carry a rule for one class.

Then the function sends Get Max LUN, a one-byte answer, decoded by
`erx_usb_bot_core`; a STALL or any failure means one unit, as BOT
allows, and a value above 15 refuses the interface.

### The SCSI subset

A BOT function sends these commands and no others, the first of them at
its unit's start, before any medium or block transport exists. `erx_blk_write`
builds each one's CBW from the table of `abi/formats/usb.txt`, and
`erx_usb_bot_core` decodes every answer it decides on: the CSW, Get Max
LUN's byte, and the data of INQUIRY, REQUEST SENSE and READ
CAPACITY(10) and (16). The split is SD's: `erx_blk_write` builds every
command word the card receives and `erx_blk_sd_card` parses every
response ([design-storage.md](design-storage.md#the-sd-host-controller)).

| Command | When | What it decides |
| --- | --- | --- |
| INQUIRY, 36 bytes | the unit's start | a direct-access device (peripheral type 0, qualifier 0) is served; any other type is not, with its type in the inspection record; the removable bit decides polling |
| TEST UNIT READY | until ready, and every 3 s on a removable unit, as FreeBSD polls (`scsi_da.c:3060-3065`) | whether a medium is present |
| REQUEST SENSE, 18 bytes | after every failed command, inside that command's operation | the sense key and additional sense code, and whether the medium ends |
| READ CAPACITY(10), and (16) when (10) answers all ones | when a medium becomes ready | capacity and block length; a block length other than 512 is not served |
| SYNCHRONIZE CACHE(10) | once when a medium becomes ready, before it takes a drive; then each flush of a medium that accepted it | whether the medium can flush |
| READ(10), WRITE(10), or READ(16), WRITE(16) past 2^32 sectors | each request | |

The commands several of FreeBSD's quirks work around are never sent:
MODE SENSE, PREVENT ALLOW MEDIUM REMOVAL, START STOP UNIT, READ(6) and
WRITE(6), and INQUIRY's vital product data or more than its 36 bytes
(`NO_START_STOP`, `FORCE_SHORT_INQUIRY`, `NO_INQUIRY_EVPD`,
`NO_PREVENT_ALLOW`, `umass.c:334-385`; `DA_Q_NO_6_BYTE`,
`DA_Q_NO_PREVENT`, `scsi_da.c:154-156`). A write-protected medium is
found when a write fails with DATA PROTECT, not asked about.

**A medium that cannot flush.** A device that answers the readiness
SYNCHRONIZE CACHE with ILLEGAL REQUEST is one that cannot flush, as
FreeBSD's disk driver judges it (`scsi_da.c:4448-4457`, `:6249-6254`).
erXos learns it before any write, and says so: the medium's `info/0`
carries `flush => false`, and its `flush/0` answers `{error, no_flush}`,
never `ok`, since the block contract defines `ok` as every earlier write
durable on the medium ([design-storage.md](design-storage.md#data-model))
and the FAT design's ordering of its writes rests on it. A window answers
`no_flush` as `enotsup`. Any other failure of the readiness command
leaves the medium not ready, to be tried again at the next poll.

The media domain mounts every volume of such a medium **read-only**.
Each writable volume sends one flush as it mounts, before it writes
anything, and that answer admits the mount by the drives' writable rule
([design-drives.md](design-drives.md#the-writable-rule)): `ok` lets a
volume of a format erXos writes mount writable, `{error, enotsup}`
mounts it read-only with `no flush` in its drive's `status`, and any
other answer, `{error, eio}`, which a failed SYNCHRONIZE CACHE and the
transport's deadline both become, or the window's end before it
answers, refuses the mount with nothing written, until the medium is
taken out and put back. FAT keeps no
journal and orders its batches by flushes alone, so on a medium that
cannot flush nothing keeps one batch's steps from reaching the medium
out of order, and an `fsync` could answer only a false success or an error most programs
take for lost data; read-only fails loudly and safely. The cost is that
the many sticks that refuse SYNCHRONIZE CACHE, which FreeBSD writes to,
are read-only on erXos; writing to them needs a mount option with
durability and `fsync` semantics of its own, which this design does not
define.

The quirks that concern commands the transport does send, a device that
fails TEST UNIT READY or INQUIRY, miscounts its residue, signs its CSW
wrongly or reports its capacity off by one, are not carried: such a
device fails safe, unserved, and the first one that matters adds a quirk
table as data to `abi/formats/usb.txt`, naming the device in its
comment.

### Media and drives

A unit's medium is the span from the unit's becoming ready to its
ceasing to be, and it is a value of the BOT function's state: a fresh
reference, its capacity and whether it flushes.

* **Ready**: TEST UNIT READY succeeds, READ CAPACITY answers a capacity
  and 512-byte blocks, and the readiness SYNCHRONIZE CACHE answers. The
  medium takes a fresh reference and the lowest free drive the manifest
  names for the domain's controllers, and a block service starts for it under the
  function: the transport, which carries the medium's reference, and
  one window covering the medium, which the drive's grant hands the
  media domain ([Mass storage reaches the file
  servers](#mass-storage-reaches-the-file-servers)).
* **Gone**: a sense of NOT READY, for TEST UNIT READY's MEDIUM NOT
  PRESENT among others, any UNIT ATTENTION (the device's own word that
  its medium may have changed or it was reset), a sense that fails, an
  issued request past its 18 s bound, the transport's end, the
  function's end or the device's detach.

**The medium's lifetime reaches the engine.** Every request a medium's
transport hands the function carries the medium's reference, and the
engine checks it against the unit's current medium when the request
reaches the head of the queue, before any CBW is built: a request of a
medium that has ended is answered `{error, {device, gone}}` and nothing
is sent. A medium ends in the same step of the core that observes its
end: the unit's current medium becomes none, every queued request of the
old reference is answered `gone`, and the block service is stopped, so
every window of the medium ends and the drive is free. A new medium on
that unit can become ready only through commands queued behind that
step, since the one engine sends every command, so no request accepted
for one medium is sent to the next, on any unit of the device.

UNIT ATTENTION always ends the medium, even at power-on, where it only
means the device was reset: a medium ended without need costs a remount,
while one kept across a change it could not see would be written with
another medium's blocks.

### The block transport

The transport, `erx_blk_usb`, is a block transport like the virtio and
SD ones, answering `read/2`, `write/2`, `flush/0` and `info/0` with the
transport contract's answers and closed error set
([design-storage.md](design-storage.md#data-model)), with four
differences that the storage design records:

* it is started by the BOT function, one for each ready medium, not by
  `erx_blk:start_link/0` from a device record, and is not registered as
  `erx_blk`; the block service reaches its transport by pid, a device
  record's transport as well as a medium's, so one block service serves
  both;
* `info/0` names the transport `usb_bot`, its `max_sectors` is 64, one
  bulk buffer, its `flush` says whether the medium flushes, and its
  `detail` holds the vendor and product ids and the INQUIRY's vendor and
  product text, decoded and escaped where they are shown;
* its errors are the BOT core's answers: a command that failed with
  MEDIUM ERROR, DATA PROTECT, NOT READY or any other key is
  `{error, {device, {sense, Key, Asc, Ascq}}}`, three integers, the
  medium having ended in the core when the key ends it
  ([Autosense](#the-bot-engine)); a command whose sense failed
  `{error, {device, no_sense}}`; a command whose engine went through
  reset recovery `{error, {device, reset}}`; a short transfer
  `{error, {device, short}}`; a request of an ended medium
  `{error, {device, gone}}`;
* `flush/0` on a medium that cannot flush answers `{error, no_flush}`,
  the member of the closed set that the transport contract keeps for
  such a medium and a window answers as `enotsup`
  ([design-storage.md](design-storage.md#data-model)); no virtio or SD
  transport answers it.

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

**Deadlines** are the BOT core's, one owner for every request: a request
still queued 10 s after its acceptance is answered `{error, {device,
deadline}}` and never sent; an issued request not complete 18 s after
its issue, its bulk transfers, its REQUEST SENSE and any reset recovery
included, ends its medium, and the engine's next command starts with a reset recovery. A
full-speed bulk pipe moves 64 sectors in well under a second, so the
bound is the medium's slowness, not the bus's.

## On Fiasco

The USB core, the class drivers, the xHCI driver, the PCIe enumerator and
the BCM2711 bridge driver are the same code on Fiasco and on erXos's
kernel; [The Phase 1 part](#the-phase-1-part) says what the backend and
the manifest check add. Phase 1's residuals for USB and PCIe, each
recorded here as the design's and in `TODO.md` when the code lands:

* **Isolation between tasks rests on Fiasco and the root.** A task holds
  only the capabilities the root placed in it, at the rights its
  creator's mask allowed, and the root checks every service call against
  its record of them, so a task that bypasses `liberx` with raw
  invocations or requests is held to the same rights
  ([design-fiasco.md](design-fiasco.md#who-holds-what)); what that
  isolation lacks against erXos's kernel is a row of
  [its downsides](design-fiasco.md#downsides-against-erxoss-kernel).
  The PCIe domain, the USB domain and the display domain are apart as any
  two domains are. The containment cases of R4 whose verdict is user-mode
  code's, a function's answer to a malformed descriptor, report or CSW,
  run and count on Fiasco.
* **Memory walls, no CPU bound.** The USB domain's budget is a wall at
  its guarantee, its kernel memory a Fiasco factory of its own (FD25), so
  an allocation past it fails with `ERX_ENOMEM` as on erXos's kernel; its
  CPU grant places its threads but bounds no time (FD15), so only the
  bands protect a neighbour's latency from it, and only from the USB
  domain's own threads: a request it sends a service runs at that
  service's band, and a doorbell it rings runs the holder's dispatcher
  at the holder's band, so it spends a higher band's CPU by asking
  ([design-fiasco.md](design-fiasco.md#downsides-against-erxoss-kernel),
  FD15 and FD31). The cases that check a
  CPU bound, a neighbour's latency within one band, report `unsupported`
  here. R6's bounds are the
  stack's own code and are tested on both phases alike: descriptor and
  report bounds, queue and block capacities, one bitmap in flight per
  hub, the enumeration throttle, process counts per function and medium,
  the NIF's bounded work per call, the event ring's bound and a stream's
  backpressure, storms included ([Verification](#verification)).
* **Bus errors.** An SError raised by a configuration access, or by an
  xHCI register access over a link that has fallen, ends the task of
  the next thread to enter user mode on that CPU, presumed its own
  ([On Fiasco](#on-fiasco));
  the bridge driver's second link read keeps a configuration value read
  that way from being used, and the xHCI driver's next event or command
  deadline fails the controller. A synchronous external abort takes
  Fiasco's user fault path, unverified for this kind. Probe B8 says which
  the BCM2711 raises.
* **DMA without an IOMMU.** `qemu-xhci` has no IOMMU window on
  Fiasco, since its harness starts none, and the VL805 reaches all
  memory on both kernels; on Fiasco the USB domain is in the trusted
  base on both targets, and the PCIe domain is in it everywhere. Whether
  the Pi 4 bridge's inbound window could confine the VL805 to its own
  memory is probe B6; it would confine a window, not pages, and the PCIe
  domain would own it.
* **The MSI frame does not identify the writer**, on either kernel
  ([design-shared-devices.md](design-shared-devices.md)), so a device
  that can write the frame can raise another domain's MSI.
* **Firmware.** The VL805 runs firmware the VideoCore loads, and the
  root on Fiasco, not a kernel operation, reaches the mailbox for the
  notification.
* **A wedged VL805.** A VL805 that no host controller reset brings back
  stays unusable until the next boot on both kernels, since only a
  PERST# cycle resets it further and the bridge driver keeps a link whose
  firmware reads present; the USB domain's restarts end at its
  supervisor's bound and its inspection record says so.
* **Hostile devices.** A USB device can type as a person at the display
  and can feed every parser of the stack; the parsers are fuzzed, and a
  hostile device under QEMU waits for the `usb-redir` probe
  ([Verification](#qemu-suites)).

## Concurrency

The controller process is the only process that calls the device NIF
for its controller, so the NIF's device lock is never contended by two
of its callers; the lock still orders its calls against the NIF's own
completion path as for every form
([design-device-dma.md](design-device-dma.md#concurrency)). Every request
to the controller, a function's transfer or `reset_pipe`, the bus core's
command, detach or root-port operation, is a message in its mailbox,
served in arrival order; one command is in flight at a time, while
transfers on different pipes are in flight together, up to their blocks'
buffers. No NIF call waits: `negotiate/2` answers `ebusy` and is called
again on a timer with `continue`. Device calls run on
normal schedulers, so Fiasco's condition for non-coherent DMA, that
no thread moves between its maintenance and its barrier, holds for this
form as for the others.

The bus process is sequential: one event at a time, each a port's change,
a control transfer's answer, a command's completion, a deadline, a hub's
bitmap or a function's end. A detach that arrives while an enumeration
step's transfer is in flight is applied at once; the transfer's late
answer names a device reference the state no longer holds and is
dropped. The controller answers `gone` what it has not yet posted,
since the reference left its map in the same detach; an Address Device
it has already posted it answers when that command completes
([The controller process](#the-controller-process), "A failed
address"). That answer is the one never dropped: it gives back the
address-zero turn whether or not its device is still attached
([Ports, hubs and devices: the bus
core](#ports-hubs-and-devices-the-bus-core)).

Function processes run concurrently and share nothing; they meet only
in the controller's mailbox and, for input, in their own number's stream,
which only they write. A drive grant answers from the window it was last
told of, which the medium's block service sends each of the drive's
grants as its windows start, and which the grant forgets when it sees
that window end; a media domain that receives a window that ends a
moment later finds its first request failing and ends that medium's
mounts, the same as if the medium had gone after the request.

## Failure handling

| Failure | Detected by | What ends | Recovery |
| --- | --- | --- | --- |
| a malformed or oversized descriptor, a STALL or a timeout during enumeration | `erx_usb_desc`, the pipe's answer | the enumeration; the device is detached | the port is disabled until its connection changes, within its attempts; the reason is in the port's inspection record |
| a device of no claimed class, or past a bound | the claim table, the bounds | nothing: configured with no function, or refused | the inspection record names the reason |
| a malformed HID report | the fold | nothing: the report is dropped and counted | none needed |
| a function process crashes, ends on a failed transfer of its HID or hub pipes, or, for HID, on a report descriptor read that timed out or met a controller error | its supervisor link, seen by the bus | the function; its place is freed, an input number with `release` | the bus resets the function's pipes, which answers what its predecessor left posted `stopped`, then restarts it, at most 3 times in 60 s; past that, or when a pipe's reset fails, the device is detached and its port disabled until its connection changes |
| an interface its function cannot drive; for HID, no usable report, a descriptor read refused with a stall or otherwise failed than by a timeout or a controller error, with no boot fallback, or no free input number | the function, which ends or fails its start with `{shutdown, {unusable, Reason}}` | that function, for good while its device stays; nothing else | none: it is not restarted and counts toward no restart bound, the device's other functions run on, and the reason is in the device's inspection record |
| a halted endpoint | the completion's code | the transfer; EP0 is reset by the controller, any other pipe stays halted | HID and hubs end the function, as above; BOT's own recovery through `reset_pipe` (its status flow or reset recovery) |
| a step of `reset_pipe` fails | the command's or request's answer | the reset; the pipe is `halted` | the class's recovery; for BOT a failed reset recovery ends the function, which the bus restarts as above |
| an Address Device that fails | the command's completion | the enumeration; the slot is disabled, and behind a transaction translator after a USB Transaction Error, the translator's buffer cleared before the answer | the port is disabled as for any failed enumeration; a CLEAR_TT_BUFFER that fails detaches the translator's hub and every device behind it |
| a failed command whose REQUEST SENSE fails | `erx_usb_bot_core` | the operation, answered `{device, no_sense}`; the unit's medium | reset recovery when the sense's CSW calls for it; the medium is found again by TEST UNIT READY |
| an invalid CSW or a phase error | `erx_usb_bot_core` | the command, answered `{device, reset}` | reset recovery |
| an issued request past its 18 s bound | the BOT core | the request, answered `{device, deadline}`; the medium; its windows end; queued requests of the medium answered `gone` | the engine's next command starts with reset recovery; the medium is found again by TEST UNIT READY |
| a medium's transport ends | the function's monitor of it | the medium; its windows end; queued requests of the medium answered `gone`; an operation already issued runs on as any operation, and its answer reaches a caller that is gone, or the unit's course | the unit's readiness sequence finds the medium again under a fresh reference, at most once a poll period however often its transport ends; the function and its other units run on |
| a medium removed or changed | TEST UNIT READY, UNIT ATTENTION, the detach | the medium; its window ends | the media domain ends the medium's volumes; the next medium mounts at the next walk ([design-drives.md](design-drives.md#failure-handling)) |
| a medium that cannot flush | the readiness SYNCHRONIZE CACHE | nothing: its flushes answer `no_flush` | none; the media domain mounts its volumes read-only, with `no flush` in the drive's `status` |
| a control transfer not answered in 5 s | the controller process's deadline | the transfer, answered `timeout` after Stop Endpoint and Set TR Dequeue Pointer past it | the caller's; EP0 is open again |
| a command not answered in 5 s, an event that fails the form's checks, the controller's host system error, host controller error or halt while it runs, read from `USBSTS` on an interrupt or once a second, an all-ones read from a function that left the bus among them, a wait of the install past its deadline | the controller process | the controller process | the bus group restarts; `negotiate/2` resets the controller and returns every buffer; every device is enumerated again; places survive, so each input number carries `release` and each medium's windows end; past `usb_bus_restarts_max` restarts in `usb_bus_restart_window_ms` the controller is given up, the places still served ([The process tree](#the-process-tree)) |
| a stream, the input tree's mint or the places end | `erx_usb_places_sup`, then `erx_usb`'s top supervisor, each of intensity 0 | the places, the top supervisor, the permanent application and the domain | the domain service restarts the domain, which holds its units again and runs every controller afresh. The domain ends rather than restart its places within itself because the places serve its input files, whose grants the domain service mints only for a new incarnation of the domain ([design-system.md](design-system.md#facets-a-configured-domain-serves)): places made again in the same incarnation would serve no reader |
| a register access that aborts (the controller fell off its bus) | the kernel, on erXos's kernel; on Fiasco an SError ends the task of the next thread to enter user mode on its CPU, which need not be the USB domain's, and the controller's next deadline fails it | the USB domain, by the fault, on erXos's kernel; the controller process on Fiasco | the domain service restarts the domain, which gets its unit again; the display's readers see their files end and start again when the tree is granted again, and each drive's holder is introduced again, as for a block driver's domain |
| a configuration access below the root port with the link down | the bridge driver's link reads, before and after | the access, answered `link_down`; the function's position is reported gone | none of its own; an abort that does arrive ends the PCIe domain on erXos's kernel, as the next row |
| the PCIe domain ends | the domain service | the enumerator and the bridge driver | the domain restarts; with the link up and the VL805's firmware present the bridge driver resets nothing and running functions are unchanged; otherwise it turns the link off cleanly, brings the bridge up again and asks for the firmware |
| an over-current change | the port's status | nothing | cleared and logged once per attempt; the port follows its status |

The stack's state for inspection, each a path of the inspection schema
reported by the USB domain and shown under `/proc/usb`
([design.md](design.md#decisions)):

* `[usb, Controller]`: the controller's kind, ports, slots in use and in
  teardown, queue blocks free of each kind, and restarts;
* `[usb, Controller, ports, Route]`: the port's state, speed, power and
  over-current, its attempts within the last 60 s, its over-current changes counted, and its last failure
  with its step and reason;
* `[usb, Controller, devices, Route]`: the vendor and product ids, class,
  speed, the three strings, state, its functions each with its kind and
  its input number or drive, or the reason it ended unusable, each pipe's state, a refusal's reason, and
  counters of reports dropped, keys unmapped and resets; for a medium,
  whether it flushes.

Text a device supplied is a value of the record, escaped by whatever
sink shows it.

## Refusals and error results

| Call or input | Answer | When |
| --- | --- | --- |
| `erx_device:negotiate/2`, TRB form | `{error, ebusy}` | the controller has not yet halted, finished its reset or started; the driver calls again on a timer, with `continue` |
| `erx_device:negotiate/2`, virtio or GENET form | `{error, einval}` | it passes `continue`: these forms' negotiations take no steps, and each call begins one |
| `erx_device:negotiate/2`, TRB form | `{error, enotsup}` | it asks for more than 64 scratchpad pages, or its page size excludes 4 KiB |
| `erx_device:negotiate/2`, TRB form | `{error, erange}` | `AC64` is clear and the record's memory lies above 4 GiB |
| opening an xHCI record | `{error, {einval, {layout, Why, Read, Entries}}}` | `CAPLENGTH`, `RTSOFF` or `DBOFF` puts a register cluster or a port past the register window, or an extended capability lies outside it ([Registers at offsets the controller reports](#registers-at-offsets-the-controller-reports) names each `Why`) |
| `erx_device:post/4`, TRB form | `badarg` | a command or transfer of another shape; a parameter out of its range; an isochronous endpoint; a command the queue's state does not accept; Disable Slot with a queue running; a length past the buffer; a setup whose length differs from its data stage; a data stage against its setup's direction; a normal transfer against its endpoint's direction; a SET_ADDRESS setup |
| `erx_device:post/4`, TRB form | `{error, full}` | a command already in flight; no free buffer on the queue; no free block of the kind a command adds |
| `erx_device:post/4`, TRB form | `{error, halted}` | a transfer on a queue that is not `open`, or that the command in flight holds: EP0 under Evaluate Context, a queue Configure Endpoint drops, every queue of the slot under Disable Slot |
| `erx_device:post/4`, `complete/2`, `queue_state/2`, TRB form | `{error, broken}` | an event failed the form's checks, until `negotiate/2` |
| `erx_device:post/4`, `complete/2`, `queue_state/2`, TRB form shapes | `{error, einval}` | the device is not an xHCI controller, or no `negotiate/2` has begun on it |
| `erx_usb_pipe` calls | `{error, gone}` | the pipe's device has detached |
| `erx_usb_pipe` calls | `{error, halted}`, `{error, resetting}`, `{error, stopped}` | the pipe halted and has not been reset; a reset is running; the transfer was still posted when a reset restarted the ring |
| `erx_usb_pipe` calls | `{error, stall}`, `{error, timeout}`, `{error, {controller, Code}}` | the endpoint halted on this transfer; no answer in 5 s; any other completion code |
| a drive grant's `window` | `{error, no_medium}` | the drive holds no ready medium |
| a window of a medium that has gone | no answer: the process has ended | the caller's monitor fires |
| the transport | `{error, {device, {sense, Key, Asc, Ascq}}}`, `{error, {device, no_sense}}`, `{error, {device, reset}}`, `{error, {device, short}}`, `{error, {device, gone}}`, `{error, {device, deadline}}`, `{error, no_flush}` | a failed command; a failed command whose REQUEST SENSE failed too; a reset recovery; a transfer that moved less than asked; a request of an ended medium; the wait bound passed; a flush of a medium that cannot flush |
| a device at enumeration | refused, with `descriptor too long`, `malformed descriptor`, `duplicate interface`, `missing setting`, `endpoint zero`, `duplicate endpoint`, `missing companion`, `unsupported speed`, `too deep`, `too many ports`, `too many devices`, `too many endpoints`, `endpoint too large` or `zero interval payload` | the decoder or a bound |
| an access of the bridge driver below the root port | `{error, link_down}` | the link was down before the access or after it |
| the bridge's bring-up | fails, with `link_down`, `endpoint_mode`, `dma_ranges` or `ranges` logged, and no function reported | no link 200 ms after PERST#'s release; the block is not a root complex; the tree's inbound range breaks the window's rules |
| the VL805's report | `not_ready`, never given, with `vl805 firmware not loaded` logged, and the bridge's `firmware lost` in `/dev`'s `status` after a timed-out notification | `0x50` reads 0 or all ones after the notification, or the notification's kernel call failed; for the rest of the boot after a timed-out notification, whatever `0x50` reads |
| a write to a volume on a medium that cannot flush | `erofs` | the media domain mounted it read-only, its window having answered the mount's flush `enotsup` |
| a walk into a volume whose mount the media domain refused | `eio`, the drive's `status` naming the failure | the mount's flush answered other than `ok` or `enotsup`, or the window ended before it answered |
| `erx_firmware_request` | `ERX_ENOTSUP`; `ERX_EPROTO`; `ERX_ERIGHTS`; `ERX_ETIMEDOUT`; `ERX_EBUSY`; `ERX_EWOULDBLOCK` | a resource of a device without notifications or a platform without one, an index past the device's list, or a tag the firmware ignored; an answer outside the interface; a resource without `CARVE`; no answer within 1 s, and every call after one in the boot; another mailbox request in flight; a call from an executor |
| the Pi 4's PCIe unit at boot | given to no domain, with the device service's diagnostic | the tree the firmware hands over routes the VL805's position to one of the bridge's lines, so one unit spans the PCIe domain and the USB domain |
| a function | not started, with `no input number`, `no drive`, `not direct access`, `block length`, `max lun`; or ended unusable, with `no usable report` | its place, its layout, its unit |
| the manifest check | the build fails | a window on a `usb` device that is not a `drive` window, or a `drive` window that names a partition or no drive; a drive named twice, or on two controllers; a drive held by a domain other than the media domain ([design-drives.md](design-drives.md#manifest-rows)); more drives on one USB domain's controllers than `usb_drives_max`; a release manifest whose USB domain holds another unit or a file server; a second holder of a bridge's unit, or a `pcie` domain holding another unit; the Pi 4's INTx line given apart from its function |

## Verification

Each passing case below is paired with a seeded fault that must make it
fail, so a pass shows the code under test ran. "Explored to a fixed
point" means every state reachable in the stated model is visited,
deduplicated, until no new one appears; where a model's states are too
many for that, the test names the depth it reached in its output and the
targeted traces carry the longer sequences.

### Host tests of the cores

| Test | Seeded fault that must fail it |
| --- | --- |
| `erx_usb_bus_core`, explored to a fixed point over a root hub of two ports, one external hub of two ports and devices of one and two functions, with references and slots drawn from small sets; then traces of 1,000 attach and detach cycles on one port, a connection storm, a hub detached during its child's enumeration, a chain of six hubs, four connects on one port within a minute, four ends of one function within a minute and a hub function's restart with a device behind it, a device unplugged and plugged in again between the read of its connection change and that change's clear; over-current changes read on a root port; and, at every quiet node of the exploration, every port agreeing with the world on whether something is connected; at every node, the end and the hub reports of every instance not running, the earlier ones and an ended one whose pipes are still being reset, changing nothing, and a restart starting the claimed function unchanged under a run number no earlier instance had; and every end as unusable, of either function of a two-function device, resetting, starting and detaching nothing, keeping its reason and leaving the device's other function as it was | a connection change with the port still connected not detaching the occupant; the address-zero turn released at the reset's end instead of the address; a port's new state dropping its occupant without detaching it; a port given up after its address keeping the turn; the turn released at a detach before the address answer, so a second device is reset while the first's Address Device is outstanding; an Address Device answer for a detached device dropped as stale, so the turn is never given back; a hub given up handing on the turn a port below it held; a hub six tiers below the root powering its ports; a full-speed device's EP0 left at 8 bytes when its descriptor says otherwise; a hub configured without its hub descriptor; a device's first request sent at its address answer, without the 10 ms settle; the step an answer echoes ignored, so a stale answer is taken at the step awaiting its kind; an unusable end taken as a failure, so the function is restarted and its device given up past the bound; a function restarted before its pipes' resets answer, so the new instance meets a transfer its predecessor posted; an end from a function's earlier instance taken, so a late end resets the running instance's pipes; a report from a hub function's ended instance taken, after its restart or while its pipe is still being reset; the report an ended hub instance was handling kept, so `handled` goes to it; a pipe's failed reset keeping the device; the restart bound removed; a port's failure logged at every move into a failure state; the attempt throttle removed; a port's attempts never leaving the window; an over-current change logged on every change; the over-current log not rearmed by an attempt; a read that saw changes taking its port off the queue, so a change latched before their clear is lost |
| `erx_usb_hub_core`, its machine explored to a fixed point for hubs of 1, 2, 7, 8 and 15 ports over every report of the port count's length with each port bit and the bits around it, a short report and a failed transfer; its decoders on written cases | a change report sent with the next transfer already posted; `handled` taken without posting the next transfer; the bits above the port count kept; a report shorter than the port count taken as naming nothing |
| the bus process, its supervision tree and the hub function, run whole under `erx_usb`'s top supervisor on the host against a fake controller speaking `erx_usb_bus_link` and `erx_usb_pipe`: a root port's device, a hub with a device plugged in behind it, a hub's removal, a device replaced before its port is read, a function's end and restart within its bounds, a start that fails, a hub function's restart, a report from an ended instance, a controller's failure, a controller that fails at every reset, a bus group's abnormal end ending the top supervisor, and the controllers started after the mint has named itself and init has reported | a start that fails sending no end; a detach leaving its device's functions running; a report passed on with the running instance's number whoever sent it; a hub port's connection change cleared by the wrong feature; a connection change on a port still connected not detaching its occupant; a bus group that gave up started again |
| `erx_xhci_core`'s pipe machine, teardown, control abort and failed address, explored to a fixed point over every queue state the NIF reports and every answer of each step, EP0 and other endpoints, behind a translator and not | `reset_pipe` issuing Reset Endpoint on a stopped queue; a stopped EP0 dropped and added; the abort answered after Stop Endpoint alone, so the next request finds EP0 stopped; the translator's clear skipped; Disable Slot issued before the stops answer; an Address Device whose device detached while it was posted left unanswered; a detached reference left bound, so a request reaches its slot's next device; a reset step's answer taken by a later reset of a pipe of the same name on a slot enabled again |
| `erx_xhci_core`'s start, explored to a fixed point with and without a legacy support capability over every answer of the BIOS's semaphore and of the install and an interrupt at any time, the clock moving to each deadline; a run that has not ended always has a next step | the install called while the BIOS still owns the controller; the BIOS's semaphore never polled again; an interrupt before the controller runs acknowledged at once, or with a failure |
| `erx_xhci_core`'s root ports and interrupt pass: every PORTSC write over many words, every change bit cleared by the name it shows as, a host system error, a pass bounded at two wraps of the event ring, `USBSTS` read once a second while running, each of those, a host controller error, a halt and an all-ones read failing the controller on an interrupt and on that read | a PORTSC write keeping the change and enable bits it read; the configuration error change behind no clear; a host system error ignored; a host controller error ignored; a halt ignored; a running controller's status never read between interrupts; an interrupt pass not bounded |
| the TRB form, `erx_device_trb_form`, in C on the host, explored to a fixed point over rings of six TRBs and a link, two slots, two queues each, one buffer a queue, events of every code and kind, stops, resets, dequeue moves, drops and disables, so ring wrap and slot reuse are reachable; then traces of 100,000 transfers with random completions and 1,000 slot reuses; then under AddressSanitizer | a short data-stage event treated as completing, so the status event names no transfer and breaks the form; the stop span narrowed to the oldest transfer's first TRB and the enqueue position, so a completion followed by its forced event breaks the form; the enqueue position left on the link after a post that ends before it; the ledger's endpoint state left `stopped` by a transfer's publication, so Disable Slot passes the check with a queue running; the drop test accepting `halted`, so a drop-and-add after a consumed halting error passes the check and the model takes a drop the specification leaves undefined; the TRB pointer's range check removed |
| the publication, in C on the host, against a model controller that takes a TRB the moment its cycle bit matches | the first TRB's cycle word written with the other TRBs |
| the releases, in C on the host, against the model controller writing each event's Dwords as separate stores, Dword 3 last, and running any transfer whose TRBs are live when its endpoint's doorbell rings | the acquisition reading events whole in its first phase, so a torn event releases another transfer's buffer; only the second phase's clean and invalidate removed, over a first-phase line holding the previous lap's pointer and the current cycle word, so the stale pointer releases another transfer's buffer; a command's retired holdings taken at its completion with no endpoint closed, so a transfer posted during Set TR Dequeue Pointer is returned while the model runs it |
| the event ring's bound | the forced stop event left out of the model's sources |
| the install, in C on the host, against a model controller that interrupts only with both gates open and closes `INTE` at every reset | the `INTE` write dropped, so the model raises nothing after install |
| `erx_usb_desc` on the boot devices of HID 1.11 Appendix B and E, and on the descriptors QEMU's `usb-kbd`, `usb-tablet`, `usb-storage` and `usb-hub` return, captured once into small fixtures | the walk run over the bytes received instead of `wTotalLength`, with an interface descriptor in the trailing bytes, which is then claimed |
| claiming and admission, a property test over fuzzed configurations through `erx_usb_desc`, `erx_usb_claim` and the endpoint parameters, with a fixture of a SuperSpeed interrupt endpoint of packet size 64, burst 0 and `wBytesPerInterval` 8 | the duplicate-address rule removed; the payload computed as packet size times burst, so a high-speed interrupt endpoint of 1024 bytes and one extra transaction is admitted to a 1 KiB buffer; the payload computed as the product at SuperSpeed, so the fixture's context says 64; the second definition of an interface setting kept over the first; a hub function claimed on every interface of a hub device; the high-speed interval's upper bound removed, so a `bInterval` of 17 gives an exponent past 15 |
| `erx_hid_desc` against FreeBSD's `hid.c` compiled on the host as the oracle, over the fuzz corpus, comparing each input field's offset, size, count and usage | the push-depth bound removed: a descriptor of four nested pushes is accepted |
| `erx_hid_core` | the ErrorRollOver check removed; the state reduced to one previous report; the interrupt length taken as the packet size |
| the usage table, `abi/formats/hid.txt`'s map compared with FreeBSD's `evdev_usb_scancodes` read from the pinned source | one map entry changed |
| `erx_usb_bot_core`, explored to a fixed point over two units, two media generations a unit and every CSW and sense outcome, and a table of BOT 1.0's thirteen cases (section 6.7) | the tag check removed; the residue rule removed; the medium reference check removed; the engine idle after status 1 with the sense queued behind it, so a queued write runs before a UNIT ATTENTION is seen; a failed sense answered by asking for sense again; a refused flush answered `ok` |
| a BOT function's replacement, on the host, through `erx_usb_bus_core`'s restart path and `erx_usb_bot_core`, against a model BOT device whose command state (waiting for a CBW, expecting data out, holding data in, holding a CSW) survives the function's end, changes only on a CBW, data, a CSW read or a class reset, and whose halts and toggles survive a class reset (BOT 1.0, section 3.1); the function killed after the device accepted a WRITE(10) CBW, halfway through a WRITE(10)'s data-out and a READ(10)'s data-in phase, and with a CSW not yet read | the start's reset recovery skipped, so the model takes the replacement's CBW as the write's data and no valid CSW answers it; the recovery's halt clears run before its class reset |
| `erx_blk_write`'s BOT functions on a trial boot value | the trial check removed |
| the HID function, `erx_usb_hid` with `erx_hid_core`'s plan, from a model device behind a stand-in of `erx_usb_pipe` through the places to the records a reader of the input tree decodes: a keyboard's attach and its requests, typing, removal with a key held, a stop mid-typing and the next instance, a refused descriptor on a boot keyboard, a report storm with no reader, and no free number | a transfer not posted again; one posted again before the stream took its records; SET_IDLE(0) not sent; a failed transfer posted again instead of ending; a refused descriptor kept in the report protocol |
| the places, a property test over attach, detach, crash, a halted interrupt pipe and restart sequences | `release` skipped on a crash; the window process kept across media |
| the BCM2711 bridge driver, against a model of its registers whose link can fall at any step and whose VL805 loses its firmware at every PERST# | the bus-0 rule removed; the link read after the access removed, so a value read across a fall is reported; the reset run on a link up with firmware present; the notification skipped after a reset; the 100 ms wait dropped; a bridge in reset taken as out of it, and a SerDes powered down taken as powered, so the model, which hangs on any other register of a bridge in those states, hangs |
| the stack's own bounds, on the host, and in the QEMU suite on both phases for the cases QEMU can drive | the enumeration throttle removed, so the storm's attempts exceed 3 in 60 s |
| the writable rule over a raw window whose flush answers in turn `ok`, `enotsup`, `eio`, and nothing before the window ends, landing with the media domain ([design-drives.md](design-drives.md#host-tests)) | the mount's flush skipped, so the first write is accepted on the `enotsup` window and the dirty flag is written on the `eio` one; every answer but `ok` taken as `enotsup`, so the `eio` window mounts read-only |
| the mailbox core behind `erx_firmware_request`, C17 built for the host, which Fiasco's root and erXos's kernel both use, against a model mailbox that answers a request at once, late or never, and can hold an answer to another buffer | the buffer's address match removed, so a late answer to a timed-out request completes the next one; the rule after a timeout removed, so a second call rewrites the buffer the firmware may still answer into |

The chokepoint rules carry their own seeded violations: a module of
`erx_usb` other than `erx_xhci` calling `erx_device:post/4`, and a module
other than `erx_blk_write` calling `erx_usb_pipe:bulk_out/3`. The
kernel's mailbox chokepoint names the VL805's notification as the third
referrer of the mailbox's registers, with a seeded fourth referrer that
must fail the build.

### Fuzz targets

Each lands with its parser and builds the same sources for the host; the
Erlang ones run on the host's stock OTP, as the FAT decoders do:

* `erx_usb_desc`: device, configuration (interface, endpoint, HID, hub
  and SuperSpeed companion descriptors), language table and string;
* the hub descriptor, the hub's status-change bitmap, and the hub's and
  the root hub's port status and change words;
* `erx_hid_desc`, the report descriptor;
* `erx_hid_core`, a report against a layout taken from the corpus;
* `erx_usb_bot_core`'s decoders, all of them: the CSW, Get Max LUN's
  answer, INQUIRY, READ CAPACITY(10) and (16) and REQUEST SENSE;
* `erx_xhci_core`'s decoders of completion codes and command answers;
* `erx_trb_form_complete`, the TRB form's completion, in C, over a fuzzed event ring and
  fuzzed output-context address byte: the one C reader of memory a USB
  controller writes;
* the NIF's extended-capability walk and cluster bounds, in C, over
  fuzzed register values;
* the PCIe enumerator's configuration parser, already a target of
  [design-system.md](design-system.md#devices), over snapshots of
  `qemu-xhci`'s and the VL805's configuration space, the latter from
  probe B4.

### QEMU suites

* **`usb` on QEMU `virt`**, on Fiasco under HVF and on erXos's kernel
  once M9's kernel part exists: `qemu-xhci` with `usb-kbd`, `usb-tablet`
  and `usb-storage` over a raw image, and a `usb-hub` with a second
  keyboard behind it. The cases cover each device's inspection record,
  keyboard and tablet input sent with QMP's `input-send-event`, sectors
  read, written, read back and flushed through a raw window client,
  `device_add` and `device_del` with keys held and during writes, a
  detach and attach on one port with no wait between, which must give
  the new device a new reference, and a `restart` written to the
  controller's `/dev` `ctl` mid-typing, after which keys still arrive,
  which shows the interrupt delivered after the install that follows a
  reset as well as after the first. Seeded: SET_CONFIGURATION skipped,
  which must fail the typing case; the install's `INTE` write dropped,
  which must fail it from the first key. The bound cases of
  [the host tests](#host-tests-of-the-cores) run here on both phases,
  and so do the drive cases of
  [design-drives.md](design-drives.md#qemu-cases): a stick of each
  served format mounted, listed and read against the harness's hashes,
  ejected and put back.
* **The FreeBSD oracle**, at the milestone gate: FreeBSD 15.1's QEMU
  image, the command shell's oracle guest already, boots on QEMU `virt`
  with the same devices, each with `pcap=` set, as does erXos. Every
  control request and SCSI command erXos sends a device is one FreeBSD
  sends it during attach, in the same relative order, except the
  readiness SYNCHRONIZE CACHE, a documented difference; the sectors read
  are equal; and the evdev codes FreeBSD reports for a scripted key
  sequence are the codes erXos's records carry.
* **A hostile device**, optional until a probe shows QEMU's `usb-redir`
  is built into the supported QEMU and the protocol's facts are
  gathered: a host test tool on the redirection channel plays a device
  whose descriptors, reports and CSWs are malformed, and the case passes
  when only that device's function or port ends.

The Pi 4 is tested by hand, with a checklist that ships with its board
package: a keyboard types into the kiosk through the VL805's internal
hub; a full-speed keyboard types too, and its port's inspection record
shows no babble; a mouse moves the pointer; a stick's partition is read
through a raw window client, a known pattern is written to the test
stick's scratch partition, flushed, and read back equal after the stick
is unplugged and plugged again, and the medium's inspection record says
whether it flushes; a stick unplugged during a stream of writes ends its
windows, leaves its slot's teardown finished in the controller's record
and is served again when plugged back; a keyboard unplugged with a key
held releases it; and the PCIe domain killed while a keyboard types
comes back with the keyboard still typing and the bridge's record
showing the link kept. The device NIF's DMA for a device that is not
coherent ([design-device-dma.md](design-device-dma.md)) is verified on
the VL805 too: its given record is not coherent and its contiguous
memory lies below the bridge's `dma_limit`; the stick's pattern above
is read back with every block checked, so both the clean before the
controller reads a buffer and the invalidation after it writes one are
exercised; and, unless the
Arm passage or the litmus test of
[Releases](design-device-dma.md#releases) has settled the acquisition's
premise first, that section's VL805 probe runs a stress of short
transfers, finds every second-phase event pointer naming the TRB the
ledger expects, and records how many events' two snapshots differed.
When the first start after a cold boot takes the
reset row, the bridge's record shows the firmware version read after
the notification, and a keyboard typing afterwards shows the
notification took effect; its seeded fault, a test build that skips the
notification, must leave the VL805 out of the catalogue with
`vl805 firmware not loaded`, on a board without the VL805's EEPROM.

Probes, each recorded in the facts record of this design's QEMU and
board findings (the QEMU ones so far in
[research-qemu-pcie-usb.md](research-qemu-pcie-usb.md)). Under QEMU: `qemu-xhci`'s capability registers and port
layout; the MSI frame's range of lines, Fiasco binding one of them with
the edge trigger, and an MSI from `qemu-xhci` arriving on it; hotplug
and its port events; the IOMMU stream, at M9's kernel part; a `pcap`
reference of FreeBSD's enumeration; and `usb-redir`. On a Pi 4 board,
probes B1 to B8 of [What remains unknown](#the-bcm2711-bridge), with the
mailbox's answer time for the notification under B1; B3's seeded fault
is the same reading taken after a PCIe domain restart under a running
USB domain, which it must report as running.

## Performance

Unmeasured costs, each on [the watch list](todo-performance.md):

* the controller process as the one path for every transfer of its
  controller, and the TRB form's completion cost per event;
* a key's latency from the controller's interrupt to the router's step,
  through the controller, the function, the stream and the display's
  reader;
* mass-storage throughput at 64 sectors a request against FreeBSD's on
  the same QEMU device.

## Outside this design

Each of these fails safe by being absent, and each becomes a `TODO.md`
item when the stack's code lands: consumer-page keys and digitizers in
HID, keyboard LEDs, SuperSpeed hubs and the VL805's bulk-out burst quirk
that comes with
them, the VL805's full-speed babble wait unless the board shows it,
media whose blocks are not 512 bytes,
CBI and UAS, the bridge's spread-spectrum clocking and its clock power
management and L1 substates, a VL805 that no host controller reset
recovers, and the BCM2711's other xHCI, which `otg_mode=1` puts on the
USB-C power connector, whose facts live only in the board's tree.

### DWC2

QEMU's `raspi4b` implements the "USB2 host controller (DWC2 and MPHI)"
and no PCIe root port (`docs/system/arm/raspi.rst:30-45`); the DWC2 sits
at `0xfe980000`, 0x11000 bytes, with one interrupt, and QEMU puts a
full-speed hub on its port with `usb-kbd` and `usb-tablet` behind it at
12 Mb/s (probe). On a real Pi 4 the DWC2 is on the USB-C power connector,
disabled and in device mode by default (`usb-bus-on-raspberry-pi.adoc:36`).
So DWC2 serves QEMU `raspi4b` alone and adds no board. It is planned
work in `TODO.md`, later than every part of Track U
([plan.md](plan.md#track-u-usb)).

When it is built, `erx_dwc2` drives the controller in host mode by
programmed I/O through each host channel's registers and the channels'
data FIFOs, as FreeBSD's `dwc_otg` does, never by DMA, beside
`erx_xhci` under the same USB core, whose bus core and address-zero turn
already cover a controller that sends SET_ADDRESS itself. Its design
then settles three rules this design records:

* **DMA off, established, not assumed.** The driver resets the core and
  writes `GAHBCFG` with DMA disabled, as FreeBSD writes only the global
  interrupt mask (`dwc_otg.c:3888-3893`, `:4046-4052`), and reads it
  back before any channel operation, at every start and restart;
  `GAHBCFG`'s DMA-enable field and every `HCDMA` register are
  `ownedByNif`, so no later write turns DMA on.
* **A channel is reused only once halted and drained.** A detached
  device's channels are halted and their receive-status entries drained
  before a channel or an address is used again, as FreeBSD refuses a
  channel still waiting for its halt (`dwc_otg.c:770-776`, `:828-836`).
* **Scope**: low- and full-speed devices, directly or behind a
  full-speed hub; control, bulk and interrupt transfers; one transfer a
  channel. Split transactions, high-speed devices, isochronous transfers
  and device mode are outside it. Each FIFO word is one register access,
  a cost measured before a C copy of the FIFO is considered.

## Alternatives considered

* **DWC2 first**, by programmed I/O on QEMU `raspi4b`, the one USB erXos on
  Fiasco could reach without PCIe: it covers QEMU alone, while the Pi 4,
  the board erXos targets, needs the PCIe domain and xHCI anyway; one
  xHCI driver behind one PCIe domain covers both targets.
* **A file per HID device and an arrival stream**, as 9front's `usbd`
  announces devices: the display would need an arrival protocol and a
  reader's life per device. Input numbers make arrival invisible, and
  `release` already says what a device's departure means.
* **One merged input file**, with the USB domain counting each key's
  holders across devices: it copies the router's per-source bookkeeping
  into the USB domain.
* **A window that stays while media change beneath it**, with a medium's
  identity in every request: every caller carries an obligation that a
  window ending with its medium removes; the identity is kept below the
  windows instead, between the transport and the engine, where one
  process checks it.
* **Media as files**, `disk0s1` in the USB domain's tree, as FreeBSD's
  `/dev/da0s1`: UNIX-like, but a second form of the block service, with
  its own partition reading, bounds and write path.
* **USB devices in the catalogue**, given to other domains at run time:
  hotplug would cross every domain boundary and the unit rule would need
  an exception.
* **Class drivers in the consuming domains**, a HID driver in the display
  domain over a transfer facet: a live protocol per transfer, while the
  controller's domain must parse descriptors anyway.
* **Raw input contexts from Erlang, checked field by field**: every field
  that changes how the controller reads an address (streams, their array
  kind, the dequeue pointer's meaning) would need its own check, and a
  new field of a later specification a new one; contexts built from
  bounded parameters leave nothing to check.
* **The doorbell as the publication**: a running controller takes a TRB
  by its cycle bit alone.
* **Halt recovery automatic in the controller for every pipe**, then a
  class's own clear on top: the second Reset Endpoint finds a stopped
  endpoint and fails; one `reset_pipe` that chooses its steps by state
  replaces both.
* **MSI through the BCM2711's own decoder**: its registers share a page
  with the windows the PCIe domain programs, so another domain would need
  a forwarding mechanism to clear its vector.
* **No interrupt for the VL805, its event ring polled**, so that MSI
  stays the only PCIe interrupt everywhere: it costs latency and CPU on
  the board that needs the keyboard, while the Pi 4's closed bus lets the
  unit rule hold its line unchanged. Nor does polling rescue a board whose
  VL805 shares a line with the bridge: the shared line still makes the
  two one unit, so that topology is refused instead.
* **INTx on QEMU `virt` on Fiasco**: it would need the closed-bus
  rule on a bus the harness can extend, and a path above `liberx` that
  erXos's kernel does not use; MSI over the frame is the same
  above `liberx` in both phases.
* **A flush answered `ok` on a medium that cannot flush**, as FreeBSD
  answers it: a wrong answer given as a right one, under a contract that
  defines `ok` as durable.
* **A medium that cannot flush mounted writable, its guarantee
  withdrawn**: nothing would keep a batch's steps from reaching the
  medium out of order, and its `fsync` could answer only a false success or an error most
  programs take for lost data.
* **Leaving the VL805's firmware to the boot firmware**, never resetting
  a link it left running: a board without the VL805's EEPROM would have
  no USB after any reset, and the microSD-only boot order may hand over a
  VL805 with no firmware at all.
* **The first stage stopping the VL805 before kernel entry**: without
  the firmware's rings it can only force a halt, which still needs a
  documented drain, and it would put bridge and xHCI code into two first
  stages and give configuration space a second reach.
* **xHCI through `region/3`**, Erlang writing TRBs into a region:
  addresses would reach Erlang, and `region/3` is refused on a device
  that is not coherent.
* **A native xHCI driver**, FreeBSD's `xhci.c` as a sub-space port: no
  measurement admits it, and without a row of the driver table none runs.
* **The boot protocol alone for HID**: the boot mouse is relative, so
  QEMU's tablet and every absolute pointer would be lost.
* **UAS**: FreeBSD has no UAS driver at the pin to translate, and the
  specification is T10's, not obtained.

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
054d4c979103b417cbe5d427aa45fb05ffd62757e2ca280fe18bc9fbe2333994  sys/dev/pci/pci_host_generic_fdt.c
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

Intel, "eXtensible Host Controller Interface for Universal Serial Bus
(xHCI) Requirements Specification", Revision 1.2, May 2019, obtained by
hand from Intel's site; its notice grants no license to intellectual
property, and it is read as a reference only:

```
9257ca24f34bff08e6020623f707c788ca0f0df657aa713309ff489a68b1731e  extensible-host-controler-interface-usb-xhci.pdf
```

USB-IF, "Universal Serial Bus Specification", Revision 2.0, from
`https://www.usb.org/sites/default/files/usb_20_20250603.zip`, fetched
without click-through; `usb_20.pdf` inside it:

```
5fe9c53c04033818af396e8852b3acbca5c3a76ba92fab549fd81cd0ea7b3692  usb_20_20250603.zip
d39698a33486c399124af92bd02e4f978fd9a836b5cf4e52e6e4633eb1d89f61  usb_20.pdf
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
notes of this design. The clean-room facts record of the BCM2711's PCIe
bridge and the VL805, dated 2026-11-14, is
[research-brcmstb-pcie.md](research-brcmstb-pcie.md), which lists the
SHA-256 of every Linux and FreeBSD file its writer read.

Fiasco's SError handlers are read in the tree, at
`fiasco/kernel/src/kern/arm/thread-arm.cpp:713-735` (user mode) and
`fiasco/kernel/src/kern/arm/thread-jdb.cpp:100-106` (the kernel, where
SErrors are masked).
