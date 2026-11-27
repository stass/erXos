# Recovery

Every stack that waits on a device or a peer will sometimes wait on
something that does not answer: a USB stick that stays plugged in and
goes silent, an SD card that returns one bad checksum, a Bluetooth
controller that stops talking, a network driver that crashes. This
document is the one recovery model every such stack follows: who notices,
what it tries in what order, what it retries, what a client keeps while
the driver comes back, how a returning device is known to be the same
one, and how all of it is tested. Each stack's own design keeps its
failure table and its protocol's details; this document fixes the shape
those tables take. The Bulk-Only Transport engine's own steps are
[design-usb.md](design-usb.md)'s; the clock rule this model builds on is
the "Deadlines in state" decision of
[design.md](design.md#drivers-and-dma).

Decisions every reader needs:

* **A ladder is data.** Each stack's pure core holds an ordered list of
  recovery steps, the rungs, each with its deadline and the number of
  failures it absorbs. A failure climbs one rung; any success drops back
  to the bottom ([The ladder](#the-ladder)).
* **The smallest part goes first.** A fault attributed to one request,
  one pipe or one device tries that part's rungs before any rung that
  ends a neighbour.
* **Restarts are paced, never counted to a give-up.** A driver that ran
  and then failed restarts at most once per its hold, for ever, as the
  network stack's links do; so a device's faults never end its domain
  ([Restarts are paced](#restarts-are-paced)). Whether the domain
  service paces a failing domain instead of leaving it down is open
  decision 1.
* **Retry is an allow-list.** Only an operation its stack marks as safe
  to repeat is sent again, inside the one deadline its caller gave it;
  the caller sees one answer. Anything else fails to its caller once
  ([Retry](#retry)).
* **Clients hold the service, not the driver.** What a client depends
  on (a window, a socket, a bond, a window on the screen) belongs to a
  service the driver runs under, so a driver restart loses only what the
  driver can rebuild from its device
  ([Who holds what](#who-holds-what)).
* **A recovery never breaks a promise silently.** An answer `ok` is a
  promise. A reset that may have dropped writes the device had already
  answered makes the next answer `{error, reset}`, which the file system
  above takes as a power cut at that moment. Nothing is replayed above
  the process that held it ([Promises across a
  break](#promises-across-a-break)).
* **Identity decides names, never data.** A rung that resets a device
  reads its identity back and compares; a difference is a removal and a
  new attach. After a detach a device is new, and since nothing is
  replayed, no write ever depends on matching it to the old one
  ([Identity](#identity)).
* **Every rung is tested by injecting its fault.** Each rung, deadline
  and retry limit has a test that injects the fault that triggers it, in
  the pure core, against a stand-in device on the host, in QEMU or on
  the board, and checks the rung, its log line, the clients and the
  data; a seeded fault that removes the rung must fail it. No ladder
  lands without those tests ([Fault injection and
  tests](#fault-injection-and-tests)).

## Context

The model answers three bodies of evidence.

**The tree.** Each stack invented its own answer to a silent device
([What the code does](#what-the-code-does)), and they range from "never
gives up" to "until replug" and "until reboot". The network stack
restarts a failing link at most once a second for ever and keeps every
connection across it (`erlang/apps/erx_net/src/erx_net_sup.erl:40-54`,
`erx_net_driver.erl:33-40`); one checksum error on the SD card ends the
storage domain, which serves the system partition, `/data` and the login
keys (`erx_blk/src/erx_blk_sd.erl:30-38`, `erx_blk_sup.erl:16-20`); a
configured domain that ends five times in ten minutes stays down until
reboot (`erx_domain/src/erx_domain_srv.erl:1792-1812`). The fault that
started this work, a Raspberry Pi 4 USB stick that stays present and
stops answering, cannot be injected by any test in the tree: the QEMU
harness can eject, unplug, kill a process and cut power, and nothing
else (`tools/lib/erx/qmp.rb`).

**Other systems.** The survey read FreeBSD 14.2, OpenBSD and NetBSD's
USB mass storage drivers, Apple's IOUSBMassStorageClass, QNX 7.1's and
Genode's documentation and the MINIX 3 paper ([References](#references)).

* The BSDs stop at the Bulk-Only reset (class request, then clear halt
  on both pipes) and leave retry to the SCSI layer, which repeats every
  failed command, writes included, up to four times (FreeBSD
  `umass.c:1125-1225`, `scsi_da.c:1562`, `cam_periph.c:2005-2028`).
  OpenBSD's driver says a port reset should follow a failed reset; no
  code does it (`umass.c:893`).
* Apple has the only bounded ladder found: the Bulk-Only reset, then a
  USB device reset for a consecutive failure, and past five consecutive
  reset-aborted commands the driver gives the volume up; a completed
  command clears the count (`IOUSBMassStorageClass.cpp:66`, `:1448`,
  `:3046-3052`). Its device reset keeps the same driver object, so
  mounts survive and nothing has to be matched.
* QNX bounds resets per device (`devb-umass` `maxbresets`, default 0,
  past which the device is disabled), restarts critical processes from
  its High Availability Manager, and gives clients an opt-in recovery
  library that reopens what a restart broke.
* MINIX 3's reincarnation server replaces a failed driver with a fresh
  copy, under a policy that may back off exponentially, and the file
  server rewrites blocks from its buffer cache.
* No surveyed system shrinks a transfer size after a failure; Linux's
  documented quirks and Apple's per-device limits are static tables.

**The standing rules.** `CLAUDE.md` asks for the recovery that already
exists over new machinery, for deferring only what fails safely, and
never for deferring a case that would lose data or answer wrongly. The
model therefore reuses three mechanisms the tree already has: deadlines
in pure cores, the network stack's hold, and the capability registry's
wait for a successor facet (`otp/erts/preloaded/src/erx_facets.erl:129-165`).

## Requirements

1. **Every wait ends.** Every wait on a device or a peer, recovery
   steps included, has a deadline in the state of a pure core. Consumer:
   every caller of a driver; without it a silent device hangs its
   callers (virtio-blk today).
2. **A failure costs the least it can.** A request's failure tries
   that request's, pipe's and device's rungs before one that ends a
   neighbour. Consumer: the keyboard and every other drive on a USB
   controller, every file system in the storage domain.
3. **No device makes its subsystem stay dead.** A device that keeps
   failing is retried at a bounded rate for as long as it is present.
   Consumer: a headless board, where a dead subsystem is a dead machine.
4. **Nothing answered is lost unannounced.** A recovery never lets a
   flush answer `ok` over writes a reset may have dropped. Consumer:
   every file system; without it a recovery corrupts a volume silently.
5. **What survives is stated.** Each stack's table says what a client
   keeps across each rung. Consumer: the clients, who otherwise each
   write their own guess.
6. **What a device can make a domain spend stays bounded per unit of
   time.** Consumer: the security model: a hostile device's resets are
   spent at the ladder's pace, not at its own.
7. **Every rung is tested, with a seeded fault that proves the test
   reached it.** Every rung, deadline and retry limit is triggered by an
   injected fault, on the host or in QEMU, and on the board only where
   nothing else reaches it. Consumer: whoever changes a ladder next, and
   the Pi 4 fault that no test could make.

## The construction

The model is one ladder per stack, held as data by the stack's pure
core, over one rule about who holds what. The ladder decides what to
try; the holding rule decides what a client loses when a rung ends a
process. Everything else follows from the two.

### Deadlines

Every rung is a state of the core with its deadline inside it, as the
"Deadlines in state" decision gives every timeout: the core takes the
time as an input, answers its earliest deadline through
`next_deadline/1`, and leaving a rung drops its deadline. A rung that
waits on a device without a deadline is unrepresentable, because a rung
state carries its deadline as a field. Each rung's deadline is a `limit`
of the stack's `abi/formats` file, beside the bounds that file already
holds.

### The ladder

The rungs come from one closed set, in this order:

| Rung | What it does | What it keeps | What it ends |
| --- | --- | --- | --- |
| `cancel` | abort the operation in flight: a transfer abort, an SD stop command | the device, its configuration, every other operation | the one operation |
| `protocol_reset` | the protocol's own reset: the Bulk-Only reset, an endpoint reset, an HCI line reset | the device's address and configuration | every operation on that protocol |
| `device_reset` | reset the device and bring it back keeping its identity: a USB port reset and re-addressing, an SD card's start sequence again | the device's place, name and every client's grant, once its identity reads back the same | the device's soft state |
| `controller_reset` | the controller's own reset, then, where it sits on a bus, its bus's reset of it (a PCIe function-level reset through the PCIe domain) | every device that re-identifies in place | devices that do not re-identify, which detach |
| `driver_restart` | the driver process ends and its supervisor starts it again | everything its service holds | the driver's state |
| `domain_restart` | the domain service starts the domain again | what other domains hold for it: its grants, re-issued | everything in the domain |

A stack's ladder is an ordered subset, each rung with the number of
consecutive failures it absorbs: for an SD card,
`[{cancel, 1}, {device_reset, 2}, {controller_reset, 1}]`, then
`driver_restart`. The four rungs above `driver_restart` run inside the
driver process, in its core; `driver_restart` is its supervisor's;
`domain_restart` is the domain service's.

**Climbing.** The core keeps the ladder's position as one count of
consecutive failures. A failed operation, or a rung that fails or passes
its deadline, adds one, and the count selects the rung: with the SD
ladder above, failure 1 cancels, failures 2 and 3 reset the card,
failure 4 resets the controller, and failure 5 ends the process. Any
operation that succeeds sets the count to zero. This is Apple's rule
(a completed command clears the count), chosen over a window of time
(three in sixty seconds) because a device that works between failures is
not getting worse, and a window counts it as if it were.

**What ends a ladder.** A ladder ends in one of five ways, and in no
other:

* an operation succeeds, and the count returns to zero;
* the device goes: a card-detect change, a port's connect change, a
  removal; nothing is left to recover;
* a rung reads back a different identity, which is a removal and a new
  attach ([Identity](#identity));
* a final verdict: the device can never work (USB's `unusable`, an
  unsupported speed) or the hardware protects itself (an over-current);
  the port stays off and the verdict is shown;
* an operator stops the driver through its driver-control facet.

Past its last in-process rung a ladder does not end; it climbs to
`driver_restart`, whose pace is the subject of the next section.

**One implementation of climbing.** The rule above is one pure module,
`erx_ladder`, in the `erx` application every domain's runtime loads:
`new(Rungs)`, `failed(Ladder) -> {Rung, Ladder}`, `succeeded(Ladder)`,
`rung(Ladder)`. A stack's core holds the ladder value inside its state
and performs each rung's actions itself. The window rule a pure core
uses to pace restarts it decides itself, `erx_usb_bus_core:admit/4`
(admit while fewer than `Max` fell in the last `Window`, otherwise hold
until the oldest leaves it), moves into the same module, so every stack
counts and paces the same way.

### Restarts are paced

The network stack's links show the construction
(`erx_net_driver.erl:33-40`, `:154-162`). Once its start has succeeded, a
driver lives at least its hold, one second there, whatever ends it: a
crash sooner than that waits out the rest in `terminate/2`. So a device
that fails at every start restarts its driver at most once per hold, and
the supervisor above derives its intensity from the hold
(`erx_net_driver:starts_within/1`), so that holds alone never exhaust it.
A driver whose start fails is not held: it never ran, the device is not
usable at all, and repeated failed starts exhaust the supervisor and
climb to `domain_restart`.

Every driver process follows that rule, and every supervisor above
drivers derives its intensity from its children's holds. Where a pure
core restarts a child itself (the USB bus core restarting a function,
starting an enumeration), it uses the window rule and holds a start past
the window's count until the oldest leaves it, as `attempt/4` already
does for a port's enumeration attempts
(`erx_usb_bus_core.erl:907-922`). Either way a failing device costs a
bounded number of restarts per unit of time, for as long as it is
present, and its domain stays up.

What climbs to `domain_restart` is what the domain cannot fix in place:
a driver whose start fails, a non-driver process crashing past its own
supervisor's intensity, and a fault of the runtime. The domain service's
own pace is [open decision 1](#open-decisions).

### Retry

An operation is sent again only if its kind is on its stack's allow-list
of operations safe to repeat, and only after the rung its failure caused
has succeeded, and only while the deadline its caller gave it lasts. The
caller sees one answer: the operation's success, or, at its deadline or
at the end of the process holding it, the last failure. Retries are
bounded twice: by the caller's deadline, and by the ladder, since every
retry follows a rung and a ladder has finitely many rungs below
`driver_restart`.

On the allow-list: a block read; a block write, which writes the same
bytes to the same sectors; a flush; SCSI's TEST UNIT READY, READ
CAPACITY and INQUIRY; USB's GET_DESCRIPTOR and SET_CONFIGURATION; an HCI
command that only reads; a display frame, where the latest wins. Off it:
an HCI command that changes the controller's state, an ATT write, a
UART's transmitted bytes. An operation off the list fails to its caller
at its first failure, and the ladder still runs, because the device
needs recovering whatever happens to the operation. Protocols that
retransmit by their own rules, TCP and DHCP, keep them; the network
stack's retries are its protocols'.

**Writes are safe to repeat by construction.** A block write repeated
after a reset gives the medium the content its answer will claim only if
no later write to the same sectors was answered in between. The block
queue makes that true for every device: no two requests whose sector
ranges overlap are in flight at once, so a request waits while an
overlapping one is outstanding. SD and the Bulk-Only Transport run one
request at a time and meet it trivially; virtio-blk's queue enforces it.
Re-issuing every request outstanding at a reset, in any order, is then
the same as issuing them once.

### Who holds what

A driver is a child of the service its clients hold. The service owns
everything a client depends on; the driver owns only what it can rebuild
from its device: rings, the device's state, the operation in flight. So
a driver restart is, by construction, a loss of soft state, and nothing
a client holds names the driver process.

Inside a domain this is the network stack's arrangement
([design-network-stack.md](design-network-stack.md#what-fails-and-what-survives)):
the driver is the significant child of its link's supervisor, the link's
end restarts the driver and the interface's soft state, and the sockets,
with every connection and its unacknowledged data, live above the link
and survive. The model gives every device stack the same tree:

| Stack | The service (survives a driver restart) | The driver (rebuilt) |
| --- | --- | --- |
| block | the block service: windows, each medium's identity and generation ([Promises across a break](#promises-across-a-break)) | the device process: its queue, the request in flight |
| USB | the bus: places, input numbers, drive slots | the controller process and each function |
| Bluetooth | the host: bonds, GATT database, subscriptions, the pairing window | the controller group: line, HCI, link layer |
| network | the stack: sockets, connections, addresses | the driver and the interface's neighbours and reassembly |
| display | the screen: windows, layouts, the last frame | the GPU driver; each input driver |

Across domains a client holds a facet by its name in the capability
registry, never by a pid. When the serving domain ends, the client sees
the facet's server end through its monitor, waits for the successor with
`erx_facets:await(Name, EndedPid, infinity)`, and rebuilds what it held:
listens again, mounts again, subscribes again. That wait exists and is
documented for this use ("a waiter that must hear of the server's end
monitors the pid, and waits again with it as `Seen`",
`erx_facets.erl:129-143`); the model makes it the rule for every client
of a facet, and each client's design lists what it rebuilds. A client
that polls instead, as the input follower lists a tree again every
second (`erx_display/src/erx_input_follower.erl:55-62`), meets the rule
as long as its poll has a bound.

### Promises across a break

A **break** is any rung from `protocol_reset` up, or a new incarnation of
the driver: anything after which the device may have lost what it had
accepted. A device with a volatile write cache can drop, at a reset,
writes it has already answered `ok`; nothing in the virtio, SCSI or USB
specifications as read for this design promises otherwise, and the code
says the same (`erx_blk_virtio.erl:20-30`). A flush answered `ok` after
such a reset would then claim durability for writes that are gone.

The construction is a **generation on every answer**. The block service
keeps, for each medium, a generation `{Incarnation, Resets}`: it gives
each new driver incarnation the next `Incarnation`, and the driver adds
one to `Resets` at every break rung it takes. Every answer the driver
gives carries the generation it was produced under. Each window keeps
one fact: the generation of its oldest write answered `ok` and not yet
covered by a flush answered `ok`, or `clean`. When an answer arrives
under a newer generation than that, the window answers it, and every
request it then holds, `{error, reset}`, once, and becomes `clean`. A
write whose driver says its medium makes a write durable before
answering it never makes a window unclean; a driver that cannot say so
(USB, virtio-blk with a write-back cache, and SD until a reading of the
SD specification settles what its busy signal promises) counts every
write as unflushed.

The rest follows:

* **A clean window crosses a break unseen.** In-flight requests are
  retried after the rung (they are on the allow-list), and the file
  system above notices nothing. This is what makes one checksum error,
  or one Bulk-Only reset, invisible.
* **An unclean window turns the break into a power cut.** The file
  system receives `{error, reset}` and does what it does after a power
  cut: it mounts the volume again from the medium, in place, as of its
  last flush. Files opened before answer `eio`; everything flushed
  survives. Each file system already has this recovery, since a power
  cut can happen anyway; the model adds no second path.
* **A request outstanding when its driver process ends fails** to its
  caller with `eio`, once. Nothing outlives the process that held it,
  and the window does not resend it to the next incarnation.
* **No write queue above the driver, no buffer-cache rewrite.** The
  survey proposed that the volume service keep its unacknowledged writes
  and replay them to a restarted driver after reading the file system's
  UUID. It is not needed: in-process rungs already retry what is in
  flight, and a process end is the rare rung. It is also not safe: a
  queue of unacknowledged writes does not hold the writes the device
  answered and then dropped at the reset, so replaying it over a medium
  that lost its cache leaves the file system believing in blocks that
  are not there.

The generation rides on the answers, so no message about a reset has to
arrive before the answers that follow it, and a late answer from an ended
incarnation carries its old generation and is dropped, as a late serve of
an ended USB function already lands nowhere
([design-usb.md](design-usb.md#media-and-drives)).

### Identity

Identity is kept by not losing it. Every rung below `driver_restart`
keeps the device's record, place and grants, as Apple's device reset
keeps its driver object; a rung that resets the device reads its
identity back before anything is sent again:

| Kind | Its identity | Read back by |
| --- | --- | --- |
| an SD card | its CID register | the start sequence of `device_reset` |
| a USB device | vendor, product, device release and serial string where it has one; for a medium also its capacity | re-addressing after the port reset |
| a virtio or platform device | its device record, fixed by the system manifest; a medium's capacity | the driver's start |
| a controller | its device record | configuration: the same by construction |
| a Bluetooth peer | its identity address, resolved through the bond's IRK | the link layer at reconnection ([design-bluetooth.md](design-bluetooth.md)) |
| a network interface | its device record and MAC address | the driver's start |

A difference is a removal followed by a new attach. A hub's connect
change during a rung is a removal too, so a stick swapped while its port
resets is never taken for the old one. Retried writes follow the
comparison, so a write is never sent to a medium its volume did not
mount.

After a detach (a re-enumeration, a driver incarnation that finds a
different medium, a domain restart) a returning device is a new device.
Its name follows its place: a USB drive keeps its slot, an input device
its number, as the USB design's places already outlive a bus restart.
Because nothing is replayed, matching a returning device to its
predecessor decides only names; no write waits on it. The survey's rule
(serial, else the same port within ten seconds, then a UUID check before
replay) is not needed.

## The stacks

Each row is a stack's ladder in the model, with what it keeps. Its
design's failure table states the details; where that table disagrees
with a row here, [Where design and code disagree](#where-design-and-code-disagree)
says which is right.

### USB

| Part | In-process rungs | Above them | What clients keep |
| --- | --- | --- | --- |
| a control, interrupt or bulk transfer | `cancel` (stop the endpoint), `protocol_reset` (reset the endpoint) | the device's rungs | the device and its function |
| a device | `device_reset`: port reset, re-addressing in the same slot, identity read back | detach and enumerate again, the port's attempts paced by the window rule and never disabled except by a final verdict | its place, its number or drive slot |
| a command naming one slot (stop or reset endpoint, address or reset device) that times out | the slot's rungs: xHCI's command abort, then disabling the slot and enumerating its device again (the abort's behaviour is from memory, unverified against the xHCI specification) | `controller_reset` only when the command ring itself does not stop | every other device on the controller |
| the controller | `controller_reset`: the controller's reset, then the PCIe function-level reset through the PCIe domain | `driver_restart`, held | every place |
| a hub's port where the hub switches power | a power cycle of the port before detaching (which Pi 4 ports allow it is unverified) | as a device | as a device |
| a Bulk-Only medium | the BOT engine's own ladder in [design-usb.md](design-usb.md), which follows this shape: consecutive count, writes retried while the window is clean, `{error, reset}` across a break | the device's rungs | its mounts, across every rung that keeps its identity |

### Storage

| Part | In-process rungs | Above them | What clients keep |
| --- | --- | --- | --- |
| an SD card | `cancel` (stop command), `device_reset` twice (the start sequence again, CID compared), `controller_reset` | `driver_restart`, held; `domain_restart` only when starts fail | every window; a clean volume notices nothing |
| virtio-blk | a request deadline; `device_reset` (the device's reset and its queue set up again) | `driver_restart`, held | as for SD |
| a FAT volume in the media domain | none of its own: its window carries the transport's rungs | a power-cut remount on `{error, reset}` | its mount point; files open before a power cut answer `eio` |
| littlefs on `/data` | none of its own | its release contract: a failed block request ends the storage domain ([open decision 2](#open-decisions)) | nothing across a domain restart; a driver restart that answered it no failure is not seen |

A power-cut remount of a FAT volume that had unflushed changes finds its
dirty flag set, and the drives design mounts such a volume read-only
([design-drives.md](design-drives.md#failure-handling)). A bounded check
that clears the flag when the volume is consistent is [open decision
3](#open-decisions).

### Bluetooth

| Part | Rungs | What clients keep |
| --- | --- | --- |
| a command or the line | the command's deadline, then the line's reset ([design-bluetooth.md](design-bluetooth.md#failure-handling)) | everything above the controller group |
| the controller | the group's restart, a power cycle between two starts, held | bonds and subscriptions in the store; GATT handlers attach again through `erx_gatt`; links end, since a controller reset ends every radio link, and bonded phones reconnect by themselves |
| a controller that dies while idle | a probe: when nothing has been outstanding for a probe interval, a command that only reads, with its deadline; its failure is a failure of the line | as above |
| the bond store | `unknown` because storage was unavailable at its start (`store_unavailable`): it takes its next start, and the controller group's with it, when the storage facet's successor answers | bonded phones are refused only while storage is down |

The store stays `unknown` for its whole start for a reason: the identity
address it made for that start is not the one a stored state may name,
so a read in the middle would give bonds an address they were never
advertised under ([design-bluetooth.md](design-bluetooth.md)). The model
keeps that rule and moves the next start earlier: following the storage
facet's successor, the store ends itself and the controller group, and
their restart reads the state and programs its address in one bring-up.
A blob that does not decode (`store_unreadable`) would not decode again
and waits for `forget all`, as it does.

### Networking

The network stack is the model's source and keeps its ladder: a driver
crash or a broken queue ends the link, which restarts at most once a
second for ever; every connection survives; DHCP retransmits for ever and
starts afresh at each link up
([design-network-stack.md](design-network-stack.md#what-fails-and-what-survives)).
One rung is added: a **transmit watchdog**. A ring whose oldest
descriptor has not completed by its deadline, while descriptors wait, is
a failure of the driver, so a ring that stops completing without an
error is noticed (GENET, virtio-net).

### Display and input

| Part | Rungs | What clients keep |
| --- | --- | --- |
| a frame | its 5 s deadline (`erx_fb/src/erx_virtio_gpu.erl:56`) | the window; the screen repaints after the restart |
| the GPU driver | `driver_restart`, held | every window and layout; clients notice nothing |
| an input driver | `driver_restart`, held, under a supervisor of its own | its input number, with every held key released |
| the display domain | `domain_restart` | windows end; clients open again through the facet's successor |

Input drivers move under their own supervisor so that a failing keyboard
cannot spend the display driver's intensity
(`erx_fb/src/erx_fb_sup.erl:30-36`).

### Console and UARTs

A line's group restarts owner first (`erx_uart/src/erx_uart_sup.erl:64-80`)
and its services are held as drivers are. These run in the system
domain, whose end resets the machine; whether a line group past its
supervisor's intensity can end the system domain's permanent application
was not traced (unverified), and must not be possible: line noise is
input from outside, and nothing it does may reset the machine. Bytes in
flight at a line's restart are lost, never sent twice.

### PCIe

A function-level reset is the top in-process rung for a PCIe device, and
the USB controller asks for it through the PCIe domain's facet
([design-pcie.md](design-pcie.md#failure-handling-and-restart)). A
firmware notification that passes its deadline is asked again at the
PCIe domain's next start, a bounded number of times, instead of marking
the bridge `firmware_lost` for the boot.

### Services that listen

The SSH daemon, `ntpd` and the web front end are clients of the network
domain's `net` facet. When the network domain restarts, their sockets
close; each follows the facet's successor and listens again, as
[design-ssh.md](design-ssh.md#failure-handling) states for the SSH
domain. The same holds for every client of a storage facet (the login
keys, the SSH host key, the Bluetooth store).

## What the code does

The gaps between the code and this model, by stack:

* **USB.** Control transfers have a 5 s deadline and a timed-out one is
  answered `timeout` after its pipe is reset
  (`erx_usb/src/erx_xhci_core.erl:1145-1150`, `:1318-1334`); bulk and
  interrupt transfers have no controller deadline, by design, and each
  class brings its own (`:1145-1146`). Any command not answered by its
  deadline ends the controller process (`:528-536`), and the bus group
  is `one_for_all` with 3 restarts in 60 s (`erx_usb_bus_sup.erl:49-50`),
  so one stuck device re-enumerates every device on the controller. A
  function past 3 ends in 60 s gives up its device's port
  (`erx_usb_bus_core.erl:615-632`). A port past its enumeration attempts
  is held until the oldest leaves the window (`:907-922`), which is
  already the paced retry this model asks for.
* **Storage.** Any failure the SD transfer reports ends the device
  process, and `erx_blk_sup` restarts nothing, so the storage domain ends
  (`erx_blk_sd.erl:30-38`, `erx_blk_sup.erl:16-20`, `:53`). virtio-blk has
  no request deadline (no timer in `erx_blk_virtio.erl`). Nothing is
  retried. Each window is bound to the device process it first reached
  and answers `eio` once that process ends
  ([design-stopgap.md](design-stopgap.md)).
* **Bluetooth.** Deadlines are in state (`erx_bt_hci_core.erl:14-30`);
  the controller group restarts with a power cycle, 5 in 60 s
  (`erx_bt_host_sup.erl:36`); the store read at start stays `unknown` for
  the incarnation (`erx_bt_store.erl:28-30`). No idle probe: the core's
  `idle` slot has no deadline (`erx_bt_hci_core.erl:22`).
* **Networking.** As the model; no transmit watchdog in `erx_genet.erl`
  or `erx_genet_core.erl`.
* **Display.** A frame ends the driver after 5 s; the supervisor allows
  3 ends in 60 s, input drivers' ends among them, then the domain ends
  (`erx_fb_sup.erl:30-36`, `:54-59`).
* **SSH.** The 0.1 daemon, `erx_ssh_dev`, is started once by a process
  spawned at the session's boot and neither monitors its listener nor
  starts it again (`erx_session/src/erx_ssh_dev.erl:112-150`): after a
  network domain restart a headless board has no remote access until
  reboot.
* **Domains.** A configured domain past `restarts 5` in
  `restart_period_s 600` is left down and nothing starts it again
  (`erx_domain_srv.erl:1792-1812`); a restart the library refuses is
  logged and not retried (`docs/todo-domains.md`).

## Where design and code disagree

| Statement | The code | Which is right |
| --- | --- | --- |
| [design.md](design.md#failure-handling): a driver crash ends that driver, whose supervisor resets the device and restarts it | true for USB, Bluetooth, networking and display; the block drivers end the storage domain | the design. Its row also said clients see the driver's exit and reconnect; under this model they hold the service and see nothing, and the row says so |
| [design-storage.md](design-storage.md#failure-handling-diagnostics-and-debuggability): the virtio-blk device process has a deadline and the device service resets the device by starting a new device process | no deadline; a broken queue ends the domain | the design on the deadline. On the reset each side holds half: the code's reason not to reset in place (a reset may drop answered writes) is right, and the generation on every answer answers it, so the device resets in place and the storage table's rows follow this document |
| [design-display.md](design-display.md#failure-handling-diagnostics-and-debuggability): a display driver that stops answering keeps the last frame while clients wait, "or the driver ends and restarts" | the driver ends 5 s after a frame's first post | the code; the row names the deadline |
| [design-system.md](design-system.md): a domain the manifest marks `required` ends the machine past its intensity | the service cannot mark one (`docs/todo-domains.md`) | the design; under open decision 1 it is the one domain for which pacing gives way to a reset of the machine |
| [design-ssh.md](design-ssh.md#failure-handling): `erx_ssh` listens again when the grant answers after a network domain restart | `erx_ssh_dev` has no such code | the design; the 0.1 daemon follows it as a facet client |

## Adaptive limits

The survey proposed halving a medium's largest transfer after two wedges
on large writes. No surveyed system does it, and no measurement in the
tree shows a wedge that depends on transfer size. It is not part of the
model. If the Pi 4 trace shows such a dependence, the BOT engine gains a
per-device ceiling with the measurement as its reason; the ladder's log
line names each failed transfer's size so that the evidence collects
itself.

## Concurrency and failure

* **One process climbs each ladder.** The process at the edge of a pure
  core takes every rung in order; no two rungs of one device run at
  once. Requests that arrive during a rung wait within the queue's
  existing bound and are answered `busy` past it.
* **Order between rung and request.** A rung starts only when the
  operation that failed has been taken out of the queue; requests behind
  it are sent after the rung succeeds, in their order, and an overlapping
  request still waits for the one before it.
* **Removal wins.** A removal during a rung ends the ladder; the rung's
  late answers find no state and are dropped.
* **An operator's stop wins.** A stop through the driver-control facet
  ends the ladder; a start begins at the bottom.
* **The service outlives its driver.** The supervisor order puts the
  service first and the driver under it (`rest_for_one` with the service
  ahead, or the driver under a link supervisor the service starts), so a
  driver's end never restarts the service; a service's end ends its
  driver and every client's grant, which is a `domain_restart` for its
  clients.
* **A rung that fails is a failure.** It adds one to the count, and the
  next rung follows; a rung's deadline is the bound on how long it can
  take, and the sum of the in-process rungs' deadlines bounds how long a
  ladder runs before `driver_restart`.

## Refusals and error results

What a caller of a recovering stack can receive, beyond its stack's own
answers:

| Answer | When |
| --- | --- |
| `ok`, late | the operation was retried after a rung and succeeded within its deadline |
| `{error, timeout}` | the operation's deadline passed while the ladder ran |
| `{error, reset}` | a window was unclean at a break: writes it had answered may be gone; the file system remounts from its last flush |
| `{error, eio}` | the process holding the request ended, or the operation is off the allow-list and failed |
| the stack's removal answer (`no_medium`, a socket's `econnaborted`, a link's end) | the device went, or a rung read back a different identity |
| `busy` | the queue's bound is reached during a rung |

## Security

* **Spend per unit of time stays bounded.** Every rung has a deadline
  and a count, and restarts are paced by a hold or a window, so what a
  device can make its domain spend is bounded per second even though it
  is not bounded in total. This replaces "give up" as the answer to a
  hostile device: a device that fails on purpose costs its domain the
  ladder's rate, and the domain stays up for every other device.
* **Recovery never widens authority.** A device that reads back a
  different identity is new and holds nothing of the old one's grants or
  bonds. A returning Bluetooth peer is known only through its bond's
  identity address and IRK, never through an address it presents.
* **No write reaches a medium its volume did not mount.** Retried writes
  follow the identity comparison, and nothing is replayed after a detach.
* **The counters are inspection, not authority.** A ladder's position is
  shown in its stack's existing inspection record; nothing reads it to
  decide authority.

## On Fiasco

Recovery runs in user mode, in drivers and the domain service, and needs
nothing from the kernel that the domain library does not already give: a
device's reset is its driver's through the device NIF, and a domain's
restart is the domain service's. Nothing here differs on Fiasco.

## Fault injection and tests

A ladder that no test climbs is a guess. Every timeout, crash and delay
this document names is exercised by a test that injects it, on the host
or in QEMU, and on the board only where nothing else can reach it.

### The rule

Every rung of every ladder, every deadline and every retry limit has a
test that injects the fault that triggers it and checks four outcomes:

* **the right rung**: the stack's inspection record shows the rung and
  the count the ladder reached, and no rung above it ran;
* **the right log line**: the one line the rung writes, with its reason;
* **clients reattached**: every client the stack's table names is
  checked by name afterwards (a mount reads, a socket answers, a bonded
  peer is admitted, a key reaches the screen);
* **nothing answered lost**: data written and flushed before the fault
  reads back after it, and a write answered `ok` but not flushed is
  either there or announced by `{error, reset}`.

Each such test is paired with a seeded fault that removes or breaks the
rung (its deadline deleted, its count off by one, its retry dropped), and
the test must fail on it. A rung without such a pair does not land.

### Four places to inject

| Layer | What it runs | What it injects | What it proves |
| --- | --- | --- | --- |
| 1. the pure core | the stack's core alone, explored exhaustively | at every step: an answer, an error, silence (the clock moves to the core's next deadline), a removal; at every reset: the same or a different identity | every path is bounded and ordered: the properties below hold for every sequence up to the depth bound |
| 2. a stand-in on the host | the real driver and service processes over a fake device or transport | a fault plan: silent, late, error, wrong once, gone, at a chosen exchange | the processes, supervisors, windows and clients do what the core decided |
| 3. QEMU | the whole system | what QMP and the harness can do to a running guest | the boot image recovers end to end, across domains |
| 4. the board | the Raspberry Pi 4 by hand | the faults only hardware makes: the stick that goes silent, a pulled cable | the model matches the device that started this |

**Layer 1 properties.** An explorer in the manner of
`test/erlang/erx_tcp_explore.erl` drives each core with a ladder (the
xHCI and USB bus cores, the BOT core, the SD driver's core, the
virtio-blk core, the Bluetooth HCI core, the GENET core, the domain
service's restart decision) and checks at every transition:

| Property | Seeded fault that must break it |
| --- | --- |
| every operation is answered exactly once, by its deadline | delete one rung's deadline |
| `next_deadline/1` is a time whenever an operation or a rung is outstanding | answer `infinity` from one rung state |
| rungs are taken in ladder order, and a success returns the count to zero | leave the count unchanged on success |
| an operation off the allow-list is never sent twice | add one such kind to the retry path |
| no write is sent after a reset until the identity reads back the same | skip the comparison |
| no two overlapping requests are in flight | let the queue admit an overlap |

`erx_ladder` and the window rule have unit tests of their own (four
failures reach the fourth rung and one success clears it; the window
holds the fourth start in 60 s until the first leaves it), seeded with a
dropped clear and an off-by-one in the window's comparison. The window's
generation rule is a state machine of four inputs (a write answered, a
flush answered, an answer under a newer generation, a request), tested
exhaustively, seeded by clearing the oldest unflushed generation on a
write's answer instead of a flush's.

**Layer 2: one fault plan, the stand-ins the tree has.** The tree
already has a stand-in for most devices and transports; each gains the
same five fault modes instead of a fault vocabulary of its own. A test
module, `erx_fault_plan` in `test/erlang`, holds a plan: a list of
`{Match, Fault}`, where `Match` names an exchange (a command, a transfer,
a request kind, the Nth of them) and `Fault` is one of `silent`,
`{late, Ms}`, `{error, Reason}`, `{wrong_once, Answer}` and `gone`. A
stand-in asks the plan at each exchange and does what it says; with an
empty plan it behaves as it does now, so no existing test changes.

| Stand-in | Exists as | Gains |
| --- | --- | --- |
| xHCI | `test/erlang/erx_usb_fake_xhci.erl` | a command or endpoint stop never answered, a port reset that times out, a transfer error, a device gone from its port |
| a USB stick over BOT | `test/erlang/erx_usb_fake_stick.erl` | a STALL, a NAK for ever (`silent`), a late CSW, a CSW with a bad signature or tag, a phase error, the stick gone in the middle of a command |
| an SD card | `test/erlang/erx_blk_sd_card_model.erl` | a CRC error on a read or a write, a command timeout, an R1 error bit, the card gone |
| a block window, for the volumes above | the fake window proxy of `test/erlang/erx_media_volume_tests.erl`, moved into its own module | a request dropped or delayed, `eio`, `{error, reset}`, the window's end |
| the Bluetooth line | `test/erlang/erx_bt_line_model.erl` | the controller silent, late, garbage bytes, a reset that is not answered |
| a network medium | `erx_net_pipe` over a test process, the transport the network stack's tests already use ([design-network-stack.md](design-network-stack.md)) | frames dropped or delayed, the far end silent, the link down |
| the domain library | `test/erlang/erx_domain_fake_lib.erl` | a start that fails, a restart refused |

The cases this layer must hold, each with its seed:

| Case | Seeded fault |
| --- | --- |
| an SD read fails its checksum once; the read answers its data and the storage domain stays up | turn off the retry: the read answers `eio` |
| the SD card goes silent; the driver restarts within its hold; a file opened on a clean `/data` before it still reads | restore `erx_blk_sup`'s intensity 0: the open file answers `eio` |
| a write is answered, the card is reset before a flush; the next request answers `{error, reset}` and the volume remounts as of its last flush | leave out the generation on the driver's answers: the flush answers `ok` |
| the fake stick goes silent in the middle of a write; the BOT ladder recovers and the medium keeps its mount | remove the attempt deadline: the case's own deadline fires |
| one device's endpoint stop is not answered; the keyboard on the same fake controller keeps its number and keeps delivering | end the controller on any command timeout: the keyboard's number is released |
| a FAT volume's window answers `{error, reset}`; the volume remounts in place and its mount point answers | treat `reset` as `eio`: the volume stays failed |
| the Bluetooth line goes silent while only advertising; the probe notices within its interval and the group restarts | remove the probe |
| storage is down when the Bluetooth domain starts; at the storage facet's successor the store and the controller group start again, read the state, and a bonded peer is admitted | the store does not follow the storage facet |
| the network medium's far end goes silent with a connection open; the link restarts once a second and the connection survives | hold of zero: the interfaces supervisor gives up |
| a configured domain ends a sixth time in its period; its next start is held, then made | answer `no` past the intensity, as the code does |

**Layer 3: a fault-control interface for the QEMU harness.** One Ruby
module, `Erx::Faults` (`tools/lib/erx/faults.rb`), declares the closed
set of fault kinds the harness can inject, each with its action:

| Kind | Action | Status |
| --- | --- | --- |
| `unplug` | QMP `device_del` | in `tools/lib/erx/qmp.rb` |
| `eject` | QMP `eject`, forced | in `tools/lib/erx/qmp.rb` |
| `kill_domain` | the harness's domain kill that the USB suite's restart cell uses (`tools/lib/erx/usb_boot.rb`) | in the tree |
| `power_cut` | the block-device suite's cut after a sync (`tools/lib/erx/qemu_suites/block_device.rb`) | in the tree |
| `line_silent`, `line_late`, `line_garbage`, `line_cut` | a relay the harness owns between a socket chardev and its peer (the Bluetooth line's chardev connects to Bumble on the host's loopback, `tools/lib/erx/qemu.rb:107-116`): stop forwarding, delay, insert bytes, close | our own code; to write |
| `net_drop`, `net_silent` | the same relay on a socket or datagram network backend | our own code; to write |
| `link_down`, `link_up` | QMP `set_link` | unverified |
| `block_error`, `block_stall` | QEMU's `blkdebug` block driver, whose rules are set when the drive is created | unverified |
| `chardev_stop` | QMP's chardev removal or change | unverified |

A kind marked unverified rests on QEMU's documented interface remembered,
not read; QEMU's source is off limits and its documentation was not
fetched for this design. A probe settles each: a cell that boots the
pinned QEMU, asks it for `query-commands` and `query-qmp-schema`, and
records which commands and arguments exist. A kind becomes usable only
when the probe's record shows it; until then the module refuses it with
a plain message naming the kind.

**How a cell names its faults.** A cell declares the faults it injects
with its other facts: `faults: [[:block_error, drive: :data, op:
:read, nth: 3], [:kill_domain, :network]]`. The module derives what the
boot needs from that declaration (a `blkdebug` drive in place of a plain
one, a relay chardev in place of a direct socket), so nothing is said
twice, and a fault the cell did not declare, or a kind outside the set,
raises `Erx::Error` before QEMU starts. The cell's steps then call
`faults.inject(kind, ...)` at the moment they choose and check the four
outcomes of [the rule](#the-rule). A cell's record lists the faults it
injected, so a result says what was tested.

The QEMU cases, each with its seed:

* **Kill each serving domain, check every client by name.** After the
  network domain ends, SSH accepts a connection on its port, ntpd
  answers, the web front end serves; after the storage domain ends, the
  Bluetooth store and the login keys read again. Seed: one client that
  does not follow the facet's successor.
* **Link down and up** for virtio-net (`link_down`): a TCP connection
  survives and DHCP binds again at link up. Seed: an interface that
  ignores the link's state.
* **Block errors and stalls** for virtio-blk (`block_error`,
  `block_stall`): one read error is retried unseen; a stalled request
  meets its deadline and the device resets in place; a file flushed
  before the stall reads back. Seed: no request deadline.
* **A silent Bluetooth controller** (`line_silent`): the group restarts
  with its power cycle and the Bumble peer reconnects. Seed: no idle
  probe.
* **A medium unplugged in the middle of a write** (`unplug`): the volume
  ends, `/media` drops the drive, and a stick plugged back mounts
  afresh. Seed: a drive that keeps its window past the removal.

**Layer 4: the board.** No QEMU feature known to the harness makes a
present USB stick stop answering; that fault, the one that started this
work, is reproduced on the Raspberry Pi 4 with the stick that shows it,
and the board's manual checklist records the ladder's log lines and the
mount's state after it. A pulled Ethernet cable and a Bluetooth peer
switched off join the same checklist. SD card errors cannot be made by
hand on the boot medium and stay on layers 1 and 2.

### Order of work

No ladder lands without its fault tests. The packages that build the
tests come first or with the ladder they test:

1. `erx_fault_plan` and the stand-ins' five modes; `Erx::Faults` with the
   kinds already in the tree; the QMP probe.
2. The relay kinds, with the first stack whose cell needs them
   (Bluetooth's line, the network's backend).
3. Each stack's ladder package then carries its layer-1 properties, its
   layer-2 cases and the QEMU kinds the probe has confirmed, with every
   seed.

## Alternatives considered

* **Replay unacknowledged writes after a driver restart** (MINIX 3's
  rewrite from the buffer cache, the survey's queue). Not needed and not
  safe with a volatile cache ([Promises across a
  break](#promises-across-a-break)).
* **End the window at every break.** Simpler by one fact, and every
  reset would remount every volume and fail every open file, including
  on a clean volume that lost nothing. The generation costs one value per
  window and keeps a clean volume untouched.
* **Assume a protocol or port reset keeps the device's cache**, as
  Apple's driver resumes I/O after its device reset. Mounts would survive
  more breaks, and a device that does drop its cache would corrupt its
  volume silently. Rejected: data loss is never deferred.
* **Count failures in a window of time inside a ladder.** A device that
  works between rare failures would climb as if it were failing
  continuously; the consecutive count does not.
* **Give up past a bound** (QNX's `maxbresets`, Apple's five resets, the
  tree's "until replug"). Bounded spend comes from pacing instead, and a
  final verdict covers the device that can never work.
* **Opt-in client recovery** (QNX's client library). Every client of a
  facet follows its successor already through one call; making it
  optional would leave the clients that did not opt in dead.

## Open decisions

1. **A configured domain past its restart intensity.** It is left down
   until reboot (`erx_domain_srv.erl:1792-1812`), an accepted rule of
   [design-system.md](design-system.md) ("Boot failure"). The choices:
   * **Hold.** Past `restarts` in `restart_period_s`, the next start
     waits until the oldest counted restart leaves the period, the window
     rule USB already applies to a port's attempts; for a row of boot
     timeouts, which are counted in a row rather than in a period, the
     next start waits `restart_period_s` after the last end. A domain
     restarts at most `restarts` times per period, for ever, one log line
     each, and the inspector shows when the next start is due. A start
     the library refuses counts as a start that failed and is held the
     same way. A domain marked `required` resets the machine where
     another would be held, as the design already says.
   * **A `ctl` word.** `start NAME` written to `/svc/machine/ctl` starts
     a domain that is down. It needs a grammar, a fuzz case and the
     `machine` grant's authority, and a headless board has no operator to
     write it.
   * **Keep leaving it down.** A flaky card or controller then turns a
     recoverable fault into a dead subsystem until reboot.

   Recommendation: hold, without the `ctl` word; the word can come with
   the first consumer that cannot wait out a period.
2. **littlefs's release contract.** It says a block failure ends the
   storage domain ([design-stopgap.md](design-stopgap.md#release-contract)).
   Under this model a block driver that restarts with nothing of littlefs
   outstanding is not seen by littlefs at all. Recommendation: narrow
   the contract's "a block failure" to "a failed block request", which
   the model keeps as it is: littlefs's worker sees the failure and the
   domain ends, as contracted.
3. **A bounded FAT check at mount.** A power-cut remount of a FAT volume
   with unflushed changes finds its dirty flag set, and the volume is
   read-only "until repaired on another machine". Recommendation: yes,
   as a section of [design-drives.md](design-drives.md): at mount, a
   dirty volume whose FAT copies agree and whose chains are consistent,
   checked within a bound of time and memory, has its flag cleared and
   mounts read-write, as FreeBSD's `fsck_msdosfs` would clear it; any
   doubt keeps it read-only, and the check repairs nothing.
4. **A rule in `CLAUDE.md`.** "Every failure table names a bounded
   recovery ladder whose top rung is paced, not a give-up; every stack
   that talks to a device or a peer has a fault peer that can stop
   answering, and a test that uses it." Recommendation: add it under
   Design and Tests, so the model binds stacks not yet written.

## References

* [design.md](design.md): "Deadlines in state", "Recovery ladders" and
  the failure table.
* [design-network-stack.md](design-network-stack.md): the hold and what
  survives a driver restart.
* [design-usb.md](design-usb.md), [design-storage.md](design-storage.md),
  [design-drives.md](design-drives.md),
  [design-stopgap.md](design-stopgap.md),
  [design-bluetooth.md](design-bluetooth.md),
  [design-display.md](design-display.md),
  [design-pcie.md](design-pcie.md), [design-ssh.md](design-ssh.md),
  [design-system.md](design-system.md): each stack's failure table.
* [design-verification.md](design-verification.md): pure cores and their
  exploration.
* FreeBSD 14.2: `sys/dev/usb/storage/umass.c`, `sys/cam/scsi/scsi_da.c`,
  `sys/cam/cam_periph.c`, `sys/cam/scsi/scsi_all.c`.
* OpenBSD at commit `96a793b` and NetBSD 10 at commit `35be686`:
  `umass.c`.
* Apple IOUSBMassStorageClass (APSL): `IOUSBMassStorageClass.cpp`,
  `USBMassStorageClassBulkOnly.cpp`.
* QNX 7.1 documentation: `devb-umass`, the High Availability Manager and
  the client recovery library.
* The MINIX 3 paper on the reincarnation server, section 3.2.
* The survey that read these sources records each file's origin and
  SHA-256 beside its copy, outside the tree.
