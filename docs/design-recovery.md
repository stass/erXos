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
  failures it absorbs. A failure climbs one rung; a client's operation
  that succeeds drops back to the bottom ([The ladder](#the-ladder)).
* **The smallest part goes first.** A fault attributed to one request,
  one pipe or one device tries that part's rungs before any rung that
  ends a neighbour.
* **Every reset is paced, never counted to a give-up.** The resets a
  device costs are admitted at a bounded rate that no success clears; a
  driver's start never touches its device, so every device fault is a
  fault of a running driver, which restarts at most once per its hold,
  for ever, as the network stack's links do. A device's faults never
  end its domain ([Restarts are paced](#restarts-are-paced)). The
  domain service paces a failing domain the same way instead of
  leaving it down.
* **Retry is an allow-list.** Only an operation its stack marks as safe
  to repeat is sent again, a bounded number of times inside the one
  deadline its caller gave it; the caller sees one answer. Anything else
  fails to its caller once ([Retry](#retry)).
* **Clients hold the service, not the driver.** What a client depends
  on (a window, a socket, a bond, a window on the screen) belongs to a
  service the driver runs under, so a driver restart loses only what the
  driver can rebuild from its device
  ([Who holds what](#who-holds-what)).
* **A recovery never breaks a promise silently.** An answer `ok` is a
  promise. A reset that may have dropped writes a window had answered
  ends that window, which every holder of it sees as it sees a removal:
  the file systems on it mount again from what the medium holds.
  Nothing is replayed above the process that held it ([Promises across
  a break](#promises-across-a-break)).
* **Identity decides names; a medium survives only what cannot have
  changed it.** A rung that resets a device reads its identity back and
  compares; a difference is a removal and a new attach. A medium
  survives a rung only where the identity read back is the medium's
  own and none of its transport's medium-ending events occurred;
  otherwise it is a new medium, and since nothing is replayed, no old
  write reaches it ([Identity](#identity)).
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
never for deferring a case that would lose data or answer wrongly,
and its rule on recovery makes this document binding for every
recoverable failure of a device or a peer, with a fault-injection test
for every rung, deadline and retry limit. The
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
failure 4 resets the controller, and failure 5 ends the process. A
client's operation that completes on the device after the last rung
sets the count to zero; a rung's own commands (the reset itself, the
readiness checks after it, the idle probe) never do, since a device can
answer its reset and still fail every command. This is Apple's rule
(a completed command clears the count), chosen over a window of time
(three in sixty seconds) because a device that works between failures is
not getting worse, and a window counts it as if it were. The count
decides only which rung comes next. How often rungs may run is the
admission's ([Restarts are paced](#restarts-are-paced)), and how often
one operation may be sent is its own attempt limit ([Retry](#retry)),
so neither bound rests on what clears the count.

**What ends a ladder.** A ladder ends in one of five ways, and in no
other:

* a client's operation succeeds, and the count returns to zero;
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
(admit while fewer than `Max` fell in the last `Window`, otherwise refuse
until the oldest leaves it, `erx_usb_bus_core.erl:925-934`), moves into
the same module as `admit/4`, so every stack counts and paces the same
way. The ladder's count and the admission's history are two values of
the core's state, and nothing that resets one touches the other.

### Restarts are paced

Three rules together bound what a device can cost per unit of time,
whatever it does.

**A driver's start never touches its device.** A driver process's start
takes its device record and its service's handle and nothing else;
bringing the device up (its reset, its feature negotiation, a card's
start sequence, a link's first carrier) is the first step of its core,
taken after the start has returned, under a deadline like any rung. A
device that never comes up is then a running driver whose first step
fails, and climbs as any failure does. So no device can make a start
fail, and the case of a failed start that escapes pacing does not
arise: a start that fails is a defect of the driver or of its
configuration, the same at every attempt.

**A driver lives at least its hold.** The network stack's links show the
construction (`erx_net_driver.erl:33-40`, `:152-162`): once its start
has returned, a driver lives at least its hold, one second there,
whatever ends it, and a crash sooner than that waits out the rest in
`terminate/2`. So a device that fails at every bring-up restarts its
driver at most once per hold, and the supervisor above derives its
intensity from the hold (`erx_net_driver:starts_within/1`), so that
holds alone never exhaust it. Every driver process follows that rule,
and every supervisor above drivers derives its intensity from its
children's holds. Each driver's hold is a `limit` of its stack's
`abi/formats` file. Where a pure core restarts a child itself (the USB
bus core restarting a function, starting an enumeration), it counts
every start, refused or not, by the window rule and holds a start past
the window's count until the oldest leaves it, as `attempt/4` already
does for a port's enumeration attempts
(`erx_usb_bus_core.erl:915-922`).

**Every break is admitted.** A device that fails at once, recovers at
once and then serves one request would clear its count each time and
never reach its hold. So every break (any rung from `protocol_reset`
up, [Promises across a break](#promises-across-a-break)) is admitted by
the window rule over the core's history of that device's breaks, which
no success clears. A break the rule refuses waits, as a state with its
admission time as its deadline; requests behind it wait within the
queue's bound and fail at their own deadlines. The history belongs to
the driver's incarnation: a new incarnation starts with an empty one,
but starts at most once per hold, so replacements add at most `Max`
breaks per hold, and the service keeps no history of its own. This
is chosen over a history the service keeps across replacements: the
hold already bounds how often an incarnation starts, so a history kept
by the service would add a protocol between each driver and its service
for a bound that holds without it.

So a failing device costs a bounded number of breaks and restarts per
unit of time, for as long as it is present, and its domain stays up.
What climbs to `domain_restart` is what the domain cannot fix in place:
a start that fails, a non-driver process crashing past its own
supervisor's intensity, and a fault of the runtime.

**A domain is paced too.** Past `restarts` in `restart_period_s`, the
domain service holds a configured domain's next start until the oldest
counted restart leaves the period, and after a row of boot timeouts,
which are counted in a row rather than in a period, until
`restart_period_s` after its last end; a start the domain library
refuses counts as a start that failed and is held the same way. The
timer is the domain service's, outside the failed domain; the inspector
shows when the next start is due, and each start is one log line
([design-system.md](design-system.md)). A domain marked `required`
resets the machine where another would be held, since the machine does
not run without it. Leaving a domain down instead would turn a flaky
card or controller into a dead subsystem until reboot, which a headless
board cannot repair. No `ctl` word starts a domain that is down: a held
domain starts by itself, and such a word, with its grammar, fuzz case
and authority, comes with the first consumer that cannot wait out a
period.

### Retry

An operation is sent again only if its kind is on its stack's allow-list
of operations safe to repeat, and only after the rung its failure caused
has succeeded, and only while the deadline its caller gave it lasts. The
caller sees one answer: the operation's success, or, at its deadline, at
its attempt limit or at the end of the process holding it, the last
failure. Retries are bounded twice, each bound the operation's own: by
the caller's deadline, and by its attempt limit, a `limit` of its
stack's `abi/formats` file (the Bulk-Only engine's four retries, as
FreeBSD's disk driver retries), so no other request's success can
extend them.

**Each send is an attempt, and a break retires attempts.** The core
keeps the attempts it has sent and not seen complete, and matches every
completion against them. A rung retires every attempt it stopped: a
`cancel` the one it cancelled, a break every attempt sent before it. A
retry is a new attempt. So a completion of a retired attempt, however
late it arrives, finds nothing and is dropped, and the only answer an
operation gets after a break is one its new attempt earned. For the
Bulk-Only Transport the attempt is its tag, which every retry takes
afresh; for a ring it is the descriptor and the ring's set-up, which a
device reset makes anew.

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
queue makes that true for every device: a request's sector range is
**reserved** from its first attempt until no attempt of it can still
reach the medium, that is until its last attempt has completed or a
break has stopped the device from acting on it, and a request whose
range overlaps a reserved one waits. The reservation outlives the
caller's answer: a write answered `{error, timeout}` while its attempt
is still on the wire keeps its range until the attempt completes or a
break retires it, so a later write of the same sectors is never
overtaken by the earlier one landing late. A `cancel` alone does not
release it, since nothing promises that a device stopped at the
transfer has stopped writing. SD and the Bulk-Only Transport run one
request at a time and meet the rule trivially; virtio-blk's queue
enforces it; and a window passes its client's requests one at a time.
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
| block | the block service: windows, each with its one fact of unflushed writes ([Promises across a break](#promises-across-a-break)); each medium's identity | the device process: its queue, its attempts, the admission's history |
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

The construction is **the window as the unit of promise, ended when a
break finds it unclean.** Each window keeps one fact: whether it holds
a write answered `ok` that no flush it sent after that answer has been
answered `ok` for. A write whose driver says its medium makes a write
durable before answering it never makes a window unclean; a driver that
cannot say so (USB, virtio-blk with a write-back cache, and SD until a
reading of the SD specification settles what its busy signal promises)
counts every write as unflushed. The transport tells each of its
windows of every break it takes, as one message in the same stream as
its answers, and the end of a driver process is a break each window
sees through its monitor of it. At a break a clean window carries on,
and an unclean one **ends**.

Order needs no tag. Erlang delivers the messages of one process to
another in the order they were sent, and an ended process's exit
reaches a monitor after every message it sent. So a window sees every
answer produced before a break before the break, and, since the break
retired every attempt sent before it ([Retry](#retry)), every answer it
sees after the break was earned after it. A pre-break answer can
neither arrive after the break nor be taken for a post-break one.

The rest follows:

* **A clean window crosses a break unseen.** In-flight requests are
  retried after the rung (they are on the allow-list), and the file
  system above notices nothing. This is what makes one checksum error,
  or one Bulk-Only reset, invisible.
* **An unclean window's end is the end a removal makes**, and every
  holder of the window sees it, idle or not, through the monitor it
  already keeps. On a drive, one window covers the whole medium and
  every volume of it, so the medium's supervisor ends every volume and
  the next walk mounts the medium afresh from its next window
  ([design-drives.md](design-drives.md#failure-handling)); no volume can
  take another's notice, since there is no notice to take. littlefs's
  next request fails and the storage domain ends, under its release
  contract ([design-stopgap.md](design-stopgap.md#release-contract)). Any other holder fails
  its operation. Each file system already recovers from a removal, since
  a stick can be pulled anyway; the model adds no second path and no new
  answer.
* **What a remount finds is what the medium holds.** Everything flushed
  is there; of what was written since, any part may be. A mount that
  finds its structures consistent has not restored lost file contents,
  and a remount is not a rollback to the last flush. Files opened before
  answer `eio`.
* **Separate windows of one device stay separate.** A flush is the
  device's, so one window's flush also makes another's writes durable,
  which the other does not learn; it may then end at a break it would
  have survived. That costs a remount and loses nothing.
* **A request outstanding when its driver process ends fails** to its
  caller with `eio`, once. Nothing outlives the process that held it,
  and a clean window does not resend it to the next incarnation; it
  sends its client's next request there.
* **No write queue above the driver, no buffer-cache rewrite.** The
  survey proposed that the volume service keep its unacknowledged writes
  and replay them to a restarted driver after reading the file system's
  UUID. It is not needed: in-process rungs already retry what is in
  flight, and a process end is the rare rung. It is also not safe: a
  queue of unacknowledged writes does not hold the writes the device
  answered and then dropped at the reset, so replaying it over a medium
  that lost its cache leaves the file system believing in blocks that
  are not there.

A window that carries on sends to the driver's next incarnation, and
nothing of the ended one reaches it afterwards, as a late serve of an
ended USB function already lands nowhere
([design-usb.md](design-usb.md#media-and-drives)).

### Identity

Identity is kept by not losing it. Every rung below `driver_restart`
keeps the device's record, place and grants, as Apple's device reset
keeps its driver object; a rung that resets the device reads its
identity back before anything is sent again:

| Kind | Its identity | Read back by |
| --- | --- | --- |
| an SD card | its CID register | the start sequence of `device_reset` |
| a USB device | its device and active configuration descriptors and its serial string where it has one: the reader's identity, never its medium's | re-addressing after the port reset |
| a virtio or platform device | its device record, fixed by the system manifest; a medium's capacity | the device's bring-up |
| a controller | its device record | configuration: the same by construction |
| a Bluetooth peer | its identity address, resolved through the bond's IRK | the link layer at reconnection ([design-bluetooth.md](design-bluetooth.md)) |
| a network interface | its device record and MAC address | the device's bring-up |

A difference is a removal followed by a new attach. A hub's connect
change during a rung is a removal too, so a stick swapped while its port
resets is never taken for the old one.

**A medium continues only where nothing can have changed it.** The same
device is not the same medium: a card reader keeps its descriptors,
serial and capacity when one card is swapped for another of equal size.
A medium survives a rung only when the rung keeps the transport's medium
(a `cancel`, a `protocol_reset`, or a `device_reset` whose identity read
back is the medium's own, an SD card's CID), and none of the
transport's own medium-ending events occurred: on USB any UNIT
ATTENTION, NOT READY, a sense that fails, an issued request past its
bound, a port reset, the transport's or the function's end
([design-usb.md](design-usb.md#media-and-drives)); on SD a card-detect
change. Those rules stand; the identity comparison adds to them and
never replaces one. Where continuity is uncertain the medium is new:
its windows end, its volumes mount afresh, and no write of the old
medium is sent to it. Retried writes follow the same rule, so a write is
never sent to a medium its volume did not mount.

**Reattach is the media layer's.** Whether the volumes on a medium carry
on across a reset is decided where the promise is kept, by the window's
one fact and the continuity rule above, and not inside the USB function
or any other transport: a transport keeps no medium of its own across a
reset that may have changed it, as the BOT function keeps none across a
port reset, and the bus core keeps only the device and its place. One
rule then serves every transport, and no transport judges for itself
what a reset may have cost.

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
| a Bulk-Only medium | the BOT engine's own steps, [design-usb.md](design-usb.md)'s: the stuck transfer cancelled, then the Bulk-Only reset recovery, each a `limit` deadline; the command sent again under a fresh tag within its attempt limit and its issue bound | the function's end, asking the bus for its port's reset | its mounts across a cancel, and across a reset recovery that finds its window clean; never across a port reset or any medium-ending event of [Identity](#identity) |

The Bulk-Only engine's steps, deadlines and retried outcomes are
[design-usb.md](design-usb.md)'s, and this document does not restate
them. They take the shared shape in four points: (1) its rungs carry
deadlines in the BOT core's state; (2) a retried command is an allow-listed
operation sent as a new attempt under a fresh tag, within the
operation's attempt limit and its issue bound, and a completion under a
retired tag changes nothing; (3) its reset recovery is a break, which
its transport tells the medium's window of in the stream of its answers,
so a window holding an unflushed write ends there and the medium mounts
afresh; and (4) every event design-usb lists as ending a medium ends it,
whatever the identity comparison says. [Where design and code
disagree](#where-design-and-code-disagree) lists what design-usb.md
says otherwise.

### Storage

| Part | In-process rungs | Above them | What clients keep |
| --- | --- | --- | --- |
| an SD card | `cancel` (stop command), `device_reset` twice (the start sequence again, CID compared), `controller_reset` | `driver_restart`, held | every clean window; a clean volume notices nothing |
| virtio-blk | a request deadline; `device_reset` (the device's reset and its queue set up again) | `driver_restart`, held | as for SD |
| a FAT volume in the media domain | none of its own: its window carries the transport's rungs | its window's end at a break that finds it unclean: every volume of the medium ends and mounts afresh at the next walk | its mount point; files open before the end answer `eio` |
| littlefs on `/data` | none of its own | its window's end at a break that finds it unclean, or a failed request, ends the storage domain under its release contract ([design-stopgap.md](design-stopgap.md#release-contract)) | across a break or a driver restart that finds its window clean with nothing outstanding, everything; across a domain restart, what the medium holds |

A FAT volume mounted again after its window ended with unflushed
changes finds its dirty flag set. Its mount clears the flag and mounts
writable only when nothing else is wrong: it runs `fsck_fat`'s checker
in its first-finding mode, within the ownership check's bounds, writes
only the repair steps that mark the volume clean and repairs nothing;
any finding, a bound, or a failed read, write or flush keeps it
read-only ([design-fsck-fat.md](design-fsck-fat.md#clearing-the-flag-at-mount)).
A volume cut while a file was growing has a lost chain, a
finding, and stays read-only for `fsck_fat`.

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
  (`erx_blk_sd.erl:30-38`, `erx_blk_sup.erl:16-20`, `:53`), and that
  supervisor starts the device process ahead of the service, so the
  device's end would take the service with it. virtio-blk has no request
  deadline (no timer in `erx_blk_virtio.erl`), and a device that fails a
  step of its bring-up makes `init/1` return `ignore`, so no driver runs
  and nothing tries again (`erx_blk_virtio.erl:18-19`). Nothing is
  retried. Each window is bound to the device process it first reached
  and answers `eio` once that process ends
  ([design-stopgap.md](design-stopgap.md)).
* **Bluetooth.** Deadlines are in state (`erx_bt_hci_core.erl:14-30`);
  the controller group restarts with a power cycle, 5 in 60 s
  (`erx_bt_host_sup.erl:36`); the store read at start stays `unknown` for
  the incarnation (`erx_bt_store.erl:28-30`). No idle probe: the core's
  `idle` slot has no deadline (`erx_bt_hci_core.erl:22`).
* **Networking.** As the model, except two points: no transmit watchdog
  in `erx_genet.erl` or `erx_genet_core.erl`, and a transport whose
  `init` fails is not held (`erx_net_driver.erl:38-40`), so a medium
  that fails its bring-up fails the driver's start.
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
| [design-storage.md](design-storage.md#failure-handling-diagnostics-and-debuggability): the virtio-blk device process has a deadline and the device service resets the device by starting a new device process | no deadline; a broken queue ends the domain | the design on the deadline. On the reset each side holds half: the code's reason not to reset in place (a reset may drop answered writes) is right, and ending the window a break finds unclean answers it, so the device resets in place and the storage table's rows follow this document |
| [design-display.md](design-display.md#failure-handling-diagnostics-and-debuggability): a display driver that stops answering keeps the last frame while clients wait, "or the driver ends and restarts" | the driver ends 5 s after a frame's first post | the code; the row names the deadline |
| [design-system.md](design-system.md): a domain the manifest marks `required` ends the machine past its intensity | the service cannot mark one (`docs/todo-domains.md`) | the design; it is the one domain for which pacing gives way to a reset of the machine ([Restarts are paced](#restarts-are-paced)) |
| [design-ssh.md](design-ssh.md#failure-handling): `erx_ssh` listens again when the grant answers after a network domain restart | `erx_ssh_dev` has no such code | the design; the 0.1 daemon follows it as a facet client |

Where another design's text prescribes something else, the owning
document is cited and not restated here:

| Statement | What this design asks | Which is right |
| --- | --- | --- |
| [design-usb.md](design-usb.md)'s BOT engine: its `reset_1` to `reset_3` steps end the operation failed; where its Recovery section retries instead, the medium is kept across every reset recovery | an allow-listed command is retried after a reset recovery that succeeded, and the reset recovery is a break the transport tells the medium's window of, so a window holding an unflushed write ends | this design. design-usb.md's retry under a fresh tag within the issue bound is this design's retry; what it adds is the break told to the window (point 3 of [USB](#usb)) |
| [design-usb.md](design-usb.md#media-and-drives): any UNIT ATTENTION, NOT READY, a failed sense, an issued request past its bound, the transport's or the function's end ends the medium; a port reset keeps no medium | a medium continues only where nothing can have changed it | design-usb.md; the identity comparison never keeps a medium past one of these ([Identity](#identity)) |
| [design-drives.md](design-drives.md#failure-handling): a FAT volume removed while written stays read-only until repaired on another machine | its mount clears the dirty flag when `fsck_fat`'s first-finding check finds nothing else | [design-fsck-fat.md](design-fsck-fat.md#clearing-the-flag-at-mount), which amends design-drives.md's writable rule |

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
  request still waits for the one before it, whose range stays reserved
  until a break retires its attempt.
* **Order between break and answer.** The transport tells a window of a
  break in the stream of its answers, after every answer earned before
  it, and the break retires every attempt sent before it; so the window
  judges the break on exactly the writes answered before it.
* **A caller's deadline during a rung.** The caller is answered
  `{error, timeout}` at its deadline; its attempt stays in the core, and
  its range reserved, until the rung retires it.
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
  take, and the sum of the in-process rungs' deadlines and of the
  admission's waits bounds how long a ladder runs before
  `driver_restart`.

## Refusals and error results

What a caller of a recovering stack can receive, beyond its stack's own
answers:

| Answer | When |
| --- | --- |
| `ok`, late | the operation was retried after a rung and succeeded within its deadline |
| `{error, timeout}` | the operation's deadline passed while the ladder ran, or while a break waited for admission |
| `{error, eio}` | the process holding the request ended, the operation is off the allow-list and failed, or its attempt limit is spent |
| the window's end, and `eio` on every request it held | a break found the window unclean: writes it had answered may be gone; its holders take it as a removal |
| the stack's removal answer (`no_medium`, a socket's `econnaborted`, a link's end) | the device went, a rung read back a different identity, or the medium's continuity is uncertain |
| `busy` | the queue's bound is reached during a rung |

## Security

* **Spend per unit of time stays bounded.** Every rung has a deadline,
  every break is admitted by a window that no success clears, every
  driver restart is held, and no device can make a start fail, so what a
  device can make its domain spend is bounded per second even though it
  is not bounded in total. This replaces "give up" as the answer to a
  hostile device: a device that fails on purpose, or that alternates
  failure and success, costs its domain the admission's rate, and the
  domain stays up for every other device.
* **Recovery never widens authority.** A device that reads back a
  different identity is new and holds nothing of the old one's grants or
  bonds. A returning Bluetooth peer is known only through its bond's
  identity address and IRK, never through an address it presents.
* **No write reaches a medium its volume did not mount.** Retried writes
  follow the medium's continuity, an uncertain continuity makes a new
  medium, and nothing is replayed after a detach.
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
  either there or its window has ended, for every holder of the window.

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
| rungs are taken in ladder order, and a client's success returns the count to zero | leave the count unchanged on success |
| a rung's own command never returns the count to zero | clear the count when a reset is answered |
| breaks are admitted at most `Max` per `Window`, whatever succeeds between them | clear the admission's history on a success |
| no operation is sent more than its attempt limit | let a success of another request reset the attempts |
| a completion of a retired attempt changes nothing | match completions by request instead of by attempt |
| an operation off the allow-list is never sent twice | add one such kind to the retry path |
| no write is sent after a break to a medium whose continuity is uncertain, and a medium-ending event always ends the medium | keep the medium on UNIT ATTENTION when the identity reads back the same |
| no two overlapping requests are in flight, and a range stays reserved until its last attempt completed or a break retired it, after its caller's answer too | release the range at the caller's `timeout` |
| the transport tells every window of a break after every answer it sent before it | send the break before the answers already earned |

`erx_ladder` and the window rule have unit tests of their own (four
failures reach the fourth rung and one success clears it; the window
holds the fourth start in 60 s until the first leaves it), seeded with a
dropped clear and an off-by-one in the window's comparison. A window's
promise is a state machine tested exhaustively over every interleaving,
to a depth bound, of its inputs: a write sent and answered, a flush sent
and answered, a break, the driver's end, a request from a second holder
of the same window, and the holder's deadline. Its property: after
every break, either every write answered `ok` before it was covered by a
flush sent after its answer, or the window has ended for every holder.
Seeds: cover a write by a flush sent before the write's answer; end only
the holder whose request met the break, keeping the window for the
others.

**Layer 2: one fault plan, the stand-ins the tree has.** The tree
already has a stand-in for most devices and transports; each gains the
same five fault modes instead of a fault vocabulary of its own. A test
module, `erx_fault_plan` in `test/erlang`, holds a plan: a list of
`{Match, Fault}`, where `Match` names an exchange by its kind, a term the
stand-in names it by (a command, a transfer, a request kind), taken by
the next exchange of that kind, or as `{nth, Kind, N}`, the Nth of them
counted from the plan's start; and `Fault` is one of `silent`,
`{late, Ms}`, `{error, Reason}`, `{wrong_once, Answer}` and `gone`. The
first rule that fits is taken, once. A `silent` exchange is never
answered and leaves the device's state where it was. A `{late, Ms}`
exchange takes its effect on the device when it completes, even after a
`cancel`, a deadline or the caller's answer, which is how a write still
on the wire lands late. `{wrong_once, Answer}` answers Answer, or, when
Answer is a function, that function of the right answer. `gone` lasts:
that exchange and every later one, of any kind, meet it. A stand-in asks
the plan at each exchange and does what it says, in its own form of an
answer; with an empty plan it behaves as it does without one, so no
existing test changes.

Every storage stand-in also keeps its contents in two parts, durable
and volatile, unless it is set to write through: an answered write
lands in the volatile part, an answered flush moves the volatile part to
the durable one, and a break drops the volatile part. The cases'
"nothing answered lost" check compares what reads back with what was
answered and flushed. Dropping the whole volatile part is one crash
state of many; every image a crash could leave of a recorded run, any
subset of the writes answered since the last flush, is enumerated and
checked by [design-crash-states.md](design-crash-states.md), whose
window recorder is the block window stand-in below.

| Stand-in | Exists as | Gains |
| --- | --- | --- |
| xHCI | `test/erlang/erx_usb_fake_xhci.erl` | a command or endpoint stop never answered, a port reset that times out, a transfer error, a device gone from its port |
| a USB stick over BOT | `test/erlang/erx_usb_fake_stick.erl`, which asks the plan at each `cbw`, `data_out`, `data_in` and `csw` transfer | a STALL, a NAK for ever (`silent`), a late CSW, a CSW with a bad signature or tag, a phase error, the stick gone in the middle of a command |
| an SD card | `test/erlang/erx_blk_sd_card_model.erl` | a CRC error on a read or a write, a command timeout, an R1 error bit, the card gone |
| a block window, for the volumes above | the fake window proxy of `test/erlang/erx_media_volume_tests.erl`, moved into its own module, serving two volumes of one medium | a request dropped or delayed, `eio`, the window's end |
| the Bluetooth line | `test/erlang/erx_bt_line_model.erl` | the controller silent, late, garbage bytes, a reset that is not answered |
| a network medium | `erx_net_pipe` over a test process, the transport the network stack's tests already use ([design-network-stack.md](design-network-stack.md)) | frames dropped or delayed, the far end silent, the link down, a transmit that never completes, a bring-up that fails |
| the display's devices | to write, over the device NIF's stand-in | a frame never answered, an input device whose bring-up fails at every attempt |
| the domain library | `test/erlang/erx_domain_fake_lib.erl` | a start that fails, a restart refused |

The cases this layer must hold, each with its seed:

| Case | Seeded fault |
| --- | --- |
| an SD read fails its checksum once; the read answers its data and the storage domain stays up | turn off the retry: the read answers `eio` |
| the SD card goes silent; the driver restarts within its hold; a file opened on a clean `/data` before it still reads | restore `erx_blk_sup`'s intensity 0: the open file answers `eio` |
| a write is answered, the card is reset before a flush and drops its volatile part; the window ends, littlefs's next request fails, and after the domain's restart every flushed file reads back | tell the window of the break before the write's answer: the window survives and the flush answers `ok` over the lost write |
| an SD card that fails its checksum past two card resets; the controller resets and the card serves again, and no driver restart is logged | leave `controller_reset` out of the ladder: the inspection record shows `driver_restart` |
| an SD card that never answers its start sequence; the driver's start returns, its bring-up fails, and it restarts once per hold while the storage domain stays up | bring the card up inside the start: the start fails and the supervisor gives up |
| a device that fails at once, recovers at once and then serves one request, over and over; its breaks stay within `Max` per `Window` | clear the admission's history on a success: the breaks follow the device's pace |
| a write attempt is cancelled at a rung and its completion arrives after the break; the retried write's answer is the only one, and with the volatile part dropped the read-back is still right | match completions by request: the late completion answers the write before the break is judged |
| a write's caller passes its deadline during a rung while its attempt lands late (`{late, Ms}`); an overlapping write of the same sectors waits for the break and reads back last | release the range at the caller's `timeout`: the late landing overwrites the newer write |
| two volumes on one whole-medium window: A's write is answered, B reads, a reset drops the volatile part; both volumes end and mount afresh, and A's flush is never answered `ok` | end only the volume whose request met the break: A's next flush answers `ok` |
| two partition windows of one device, B holding an answered write and A clean, when the card resets; B ends and A carries on | end every window at every break: A's open file answers `eio` |
| the fake stick goes silent in the middle of a read; the BOT engine recovers, the read answers its data, and the medium keeps its mount | remove the attempt deadline: the case's own deadline fires |
| the fake stick's medium is swapped behind the connected reader for one of equal capacity, reported by UNIT ATTENTION; the medium ends, and no write of the old one reaches the new | keep the medium when the reader's identity reads back the same: an old write lands on the new card |
| one device's endpoint stop is not answered; the keyboard on the same fake controller keeps its number and keeps delivering | end the controller on any command timeout: the keyboard's number is released |
| the fake controller's command ring does not stop; the controller resets and the keyboard re-identifies in place, keeping its number | restart the controller process instead: the keyboard's number is released and taken again |
| a FAT volume's window ends at a break that found it unclean; the volume mounts afresh and its mount point answers | keep the volume process across the window's end: its requests answer `eio` for ever |
| the GPU stand-in never answers a frame; the driver restarts after its hold and every window repaints | remove the frame's deadline: the case's own deadline fires |
| an input device fails its bring-up at every attempt; it restarts once per hold, and the GPU driver and the display domain stay up | put input drivers back under the display driver's supervisor: the display domain ends |
| the Bluetooth line goes silent while only advertising; the probe notices within its interval and the group restarts | remove the probe |
| storage is down when the Bluetooth domain starts; at the storage facet's successor the store and the controller group start again, read the state, and a bonded peer is admitted | the store does not follow the storage facet |
| the network medium's far end goes silent with a connection open; no driver failure is seen, the link does not restart, and TCP's own timers decide the connection | treat a silent peer as a driver failure: the link restarts |
| a transmit descriptor never completes while frames wait; the watchdog ends the link, which restarts within its hold, and the connection survives | remove the watchdog: the link never restarts and the connection stalls |
| a network medium fails its bring-up at every attempt; the link restarts once per hold and the interfaces supervisor never gives up | hold of zero: the interfaces supervisor gives up |
| a configured domain ends a sixth time in its period; its next start is held, then made | answer `no` past the intensity, as the code does |
| the domain library refuses a configured domain's restart; the refusal counts as a failed start and the next is held, then made | log the refusal and stop, as the code does |

**Layer 3: a fault-control interface for the QEMU harness.** One Ruby
module, `Erx::Faults` (`tools/lib/erx/faults.rb`), declares the closed
set of fault kinds the harness can inject, each with its action:

| Kind | Action | Status |
| --- | --- | --- |
| `unplug` | QMP `device_del` | in `tools/lib/erx/qmp.rb` |
| `eject` | QMP `eject`, forced | in `tools/lib/erx/qmp.rb` |
| `kill_domain` | a line typed at the guest's Erlang shell that kills the domain's ready incarnations, found as the domain suites find them (`PcieDomain::WAIT`, which the USB suite's restart cell uses) | in the tree |
| `power_cut` | QEMU's process ended at once, as the block-device suite's power cut after a sync ends it (`tools/lib/erx/block_device.rb`) | in the tree |
| `line_silent`, `line_late`, `line_garbage`, `line_cut` | a relay the harness owns between a socket chardev and its peer (the Bluetooth line's chardev connects to Bumble on the host's loopback, `tools/lib/erx/qemu.rb:107-116`): stop forwarding, delay, insert bytes, close | our own code; to write |
| `net_drop`, `net_silent` | the same relay on a socket or datagram network backend | our own code; to write |
| `link_down`, `link_up` | QMP `set_link` on the NIC's device id | probed: the guest's carrier goes and comes back, nothing else changes |
| `block_error` | QEMU's `blkdebug` block driver, whose rules are set when the drive is created | unverified |
| `block_stall` | QMP `block_set_io_throttle` on the disk's device id, reads limited to one byte a second, lifted by removing the limit | probed: a read is held and answers its data at the lift; not yet probed: that a held read stays held across the guest's reset of the device |
| `chardev_stop` | QMP `chardev-change` to a null backend, lifted by a change back to a socket the harness listens on | probed; needs a target form for the lift's socket |

QEMU's source is off limits; a command's presence in its documentation
or schema does not show that it does what the kind needs, so a probe
(`Erx::FaultProbe`, `tools/erx probe-faults`) settles each kind by its
behaviour: it boots the pinned QEMU with scratch devices under a stock
Linux guest whose small program issues the operation the kind targets,
and records that the injected fault stalls or fails exactly that
operation (a read of the chosen sector fails, a request stays unanswered past a
bound, frames stop), that the guest sees nothing else change, and, for a
kind that can be lifted (`block_stall`, `link_down`, `chardev_stop`),
that the operation completes once it is. A kind becomes usable only when
the probe's record for the pinned QEMU shows all of it; until then the
module refuses it with a plain message naming the kind.

**How a cell names its faults.** A cell declares the faults it injects
with its other facts, each a kind and its named targets: `faults:
[[:block_error, drive: :data, op: :read, nth: 3], [:kill_domain, domain:
:'network@erxos']]`. `Erx::Faults.declare` checks the declaration whole before
QEMU starts: a kind outside the set, a kind the probe has not shown or
whose relay is not written, a missing, extra or malformed target (a
target is a short name the module checks before it reaches a QMP command
or a typed line), and a fault declared twice each raise `Erx::Error`
naming it. The module derives what the boot needs from the declaration
(a QMP socket for a QMP kind, a `blkdebug` drive in place of a plain one,
a relay chardev in place of a direct socket), so nothing is said twice.
The cell's steps then call `faults.inject(kind, **targets)` at the moment
they choose, which refuses a fault the declaration does not hold, and
check the four outcomes of [the rule](#the-rule). A cell's record lists
the faults it injected, so a result says what was tested.

The QEMU cases, each with its seed:

* **Kill each serving domain, check every client by name.** After the
  network domain ends, SSH accepts a connection on its port, ntpd
  answers, the web front end serves; after the storage domain ends, the
  Bluetooth store and the login keys read again. Seed: one client that
  does not follow the facet's successor. Each client named here has a
  failure-table row in its own design saying that it follows the
  facet's successor ([design-ssh.md](design-ssh.md#failure-handling)
  for the SSH domain, [design-web.md](design-web.md#failure-handling-diagnostics-and-debuggability)
  for `erx_web_cowboy`); a client without one is a gap in its design
  before it is a gap in this case.
* **Link down and up** for virtio-net (`link_down`): a TCP connection
  survives and DHCP binds again at link up. Seed: an interface that
  ignores the link's state. A link that is down is the medium's state,
  not a driver failure; the transmit watchdog's fault, a descriptor that
  never completes, is a layer-2 case, since no kind here makes a device
  hold a descriptor.
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
   seed, and a table in its test module that maps every rung, deadline,
   attempt limit and admission bound of its ladder to the fault that
   triggers it, the layer that injects it and the seed that removes it.
   A row without all three does not land.

## Alternatives considered

* **Replay unacknowledged writes after a driver restart** (MINIX 3's
  rewrite from the buffer cache, the survey's queue). Not needed and not
  safe with a volatile cache ([Promises across a
  break](#promises-across-a-break)).
* **End every window at every break.** Simpler by one fact, and every
  reset would remount every volume and fail every open file, including
  on a clean volume that lost nothing. The window's one fact keeps a
  clean volume untouched.
* **Keep an unclean window and answer its next request `{error, reset}`
  once.** A window shared by the volumes of one medium hands that one
  answer to whichever volume asks first, and an idle volume whose writes
  were lost never hears of it; its next flush would answer `ok`. Ending
  the window tells every holder at once, through the monitor each
  already keeps, and needs no new answer.
* **A generation `{Incarnation, Resets}` on every answer.** It orders a
  break against answers, which Erlang's ordering of one process's
  messages to another already does once the break travels in the same
  stream and retires the attempts before it.
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
* **Pace failed starts at the parent.** The supervisor or the domain
  service would hold a start that failed, at the price of a second
  pacing rule for the same device. Keeping the device out of the start
  leaves one rule, the running driver's.
* **Opt-in client recovery** (QNX's client library). Every client of a
  facet follows its successor already through one call; making it
  optional would leave the clients that did not opt in dead.

## Open decisions

None.

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
  [design-web.md](design-web.md),
  [design-system.md](design-system.md): each stack's failure table.
* [design-fsck-fat.md](design-fsck-fat.md): the check that clears a FAT
  volume's dirty flag at mount.
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
