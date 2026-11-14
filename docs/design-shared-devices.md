# Shared register pages and interrupt lines

Boards put several devices behind one register page or one interrupt
line. The kernel hands out device memory in whole pages and gives each
line one IRQ object, so a page or a line cannot be split between holders
without a kernel mechanism to share it. This document says how erXos
places such devices and how a domain drives them. It extends the unit of
[design-system.md](design-system.md#devices) and the platform invariant
PL2 of [design-platforms.md](design-platforms.md#invariants), and it owns
the line owner, the one process kind it adds.

Decisions every reader needs:

* **Sharing makes a unit.** Devices whose registers share a page, or whose
  interrupts arrive on one line, are one unit, and a unit goes whole to
  one domain. No register page and no line is ever held by two domains,
  so the kernel's rule of one MMIO object per page and one IRQ object per
  line is never contested and the kernel shares nothing.
* **A sub-device never crosses a domain as registers or a line.** Another
  domain that needs what a sub-device does reaches it through one of the
  homes the architecture already has: a file tree its holder serves, with
  a `ctl` file for one-shot control, or a facet of a declared service
  ([design.md](design.md#decisions)).
* **Inside the domain a page has one mapping.** Every device record whose
  window lies in a page uses that page's one mapping, and each record
  still reaches only its own registers, because every access is by a
  register name of its own peripheral at an offset below its window's
  size.
* **Inside the domain a shared line has one owner.** A line that two
  devices of a unit name is **shared**, and each device's record says so.
  It is bound once, by a supervised Erlang process, the **line owner**,
  which tells every driver joined to it of each firing, acknowledges the
  line when all of them have answered or exited, and tells them all again
  if the line fired in the meantime. A line that one device names is
  **direct**: its driver binds it, as any line is bound.
* **PCIe functions interrupt by MSI, except on a closed bus.** A
  bridge's INTx lines, which the functions behind it share, go to no
  domain, since which functions share a line is known only after
  enumeration. A bus whose platform record closes it, the Raspberry Pi
  4's, is the one exception: the record lists every place on the bus
  with the pin its function raises, and its bridge driver reaches no
  other place, so each line the bus routes is a line of its place's
  unit ([design-pcie.md](design-pcie.md#the-closed-bus)).

## Context

The hardware that shares, from the platform records
(`config/platforms/raspi4b.json`, `config/platforms/qemu-virt.json`) and
the boards' device trees:

| Hardware | Shares | Units |
| --- | --- | --- |
| the Raspberry Pi 4's five PL011s, 0x200 apart from `0x7e201000` | one page and one line, the record's 153 | one unit |
| the Raspberry Pi 4's auxiliary block: the mini UART at `0x7e215040`, two SPI controllers at `0x7e215080` and `0x7e2150c0`, and the block's own enable and interrupt-status registers at `0x7e215000` | one page and one line, the record's 125 | one unit |
| QEMU `virt`'s 32 virtio-mmio transports, 0x200 apart from `0x0a000000`, each on a line of its own | eight to a page | four units of eight |
| a GPIO controller, its pins and its banks' event lines | one device | one unit; its pins are functions, not devices |
| a clock or reset controller beside the devices it clocks | a page, on some boards | one unit with them |
| a PCIe bridge's INTx lines | every function behind the bridge | none: MSI, except on a closed bus |
| the Raspberry Pi 4's INTx lines, which its tree routes by pin, INTA to INTD, to SPIs 143 to 146 ([research](research-brcmstb-pcie.md), section 0) | the functions at the closed bus's one position, bus 1, device 0 | one unit: the position's row with the line its pin routes ([design-pcie.md](design-pcie.md#the-closed-bus)) |

The Raspberry Pi 4's console is its mini UART and its host link is UART3,
so the console's unit is the auxiliary block's and the host link's is the
PL011s'; both go to the system domain, which runs one driver in each,
and a second in the PL011s' for UART0, the Bluetooth controller's line,
where the manifest has it
([design-platforms.md](design-platforms.md#raspberry-pi-4-model-b)). On
QEMU `virt` the disks and the network device are given to different
domains, so they sit on transports of different pages: the harness puts
the disks on the top page and the network device on the page below
(`tools/lib/erx/qemu.rb`, `NIC_TRANSPORT`).

Systems that run drivers outside the kernel meet the same hardware.
FreeBSD drives a multi-port serial card through one parent driver that
owns the card's one interrupt (`puc(4)`), and lets several handlers share
a line marked `RF_SHAREABLE`, each filter saying whether its device
raised it. Genode's platform driver and Zircon's PCI bus driver fan one
shared legacy line out to several clients and unmask it only when every
client has acknowledged it. These descriptions come from those systems'
documentation and were not re-checked for this document. erXos takes the
parent's shape and the all-answered rule, inside one domain, and needs no
fan-out across domains because a unit never spans two.

## The unit rule

**The construction.** The machine's devices and two relations over them,
shares a register page and shares an interrupt line, form a graph. A
unit is closed under both relations: when two devices share a page or a
line, they are in one unit. The connected components of the graph are
the smallest units; a manifest may join components into one unit for a
reason of its own, as it may give a device and the controller of the bus
it sits on together, but it never splits one. PCIe functions take no
part in the page relation, since every BAR is placed in whole pages of
its own ([design-pcie.md](design-pcie.md#placement)), and none in the
line relation, since they interrupt by MSI, each MSI a line of the MSI
frame that no other function has, except a function behind a closed
bridge, whose manifest row names the INTx line its pin routes and joins
the line relation as a device-tree row does.

Each requirement follows from that one closure:

* **The kernel never meets a contested page or line.** A give makes the
  objects of a whole unit in the holder's budget
  ([design-system.md](design-system.md#devices)): one register window over
  each run of consecutive pages the unit's register ranges cover, and one
  IRQ object for each distinct line its devices name, a device of no kind
  adding no window and only a line a device of a kind in its unit
  names (below). Every page given is
  in one window and every line given in one object, so the kernel's refusal of a
  second MMIO object on a page or a second IRQ object on a line
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)) never fires on a
  give the boot view accepted.
* **No domain reaches another's device through a shared page or line.**
  A domain's mapping of a page covers only devices of units it holds,
  and each wired line and each MSI is allocated to one domain alone, so
  no line's IRQ object is held by two domains. Unique allocation does
  not stop a device from raising another domain's MSI: the supported
  platforms' MSI frames do not identify the writer, so a device that can
  write a frame can raise any of its lines
  ([design-platforms.md](design-platforms.md#security)), a residual that
  [design.md](design.md#residual-risks) records and an interrupt
  controller with per-device MSI translation closes.
* **Sharing inside a domain is the domain's business.** The device NIF
  shares mappings and IRQ objects among the records of one domain
  ([Pages inside a domain](#pages-inside-a-domain)), and the line owner
  shares a line among drivers ([Lines inside a
  domain](#lines-inside-a-domain)). Neither crosses a domain, so neither
  needs the kernel.
* **Whether a line is shared is a fact of the unit.** The relation that
  makes the unit also says which of its lines two devices name, so the
  device record carries it and no caller decides it.
* **A sub-device's function crosses by a home.** The system domain holds
  the auxiliary block's SPI controllers because they share the console's
  page, and runs no driver for them. A board on which a domain other than
  the holder needs such a function, a pin of a GPIO controller or a clock
  of a clock controller, gets it from the holder's driver: a file tree the
  holder serves, with a `ctl` file for one-shot control, or a facet of a
  service `abi/services` declares, never the registers or the line. The
  Raspberry Pi 4's legacy SD controller, the WiFi chip's SDIO host,
  shares EMMC2's line, so the storage domain drives it and serves its
  card to the WiFi domain through the `sdio` interface
  ([design-wifi.md](design-wifi.md#the-sdio-interface)); its driver
  polls with the controller's signal enable at zero, so the line keeps
  EMMC2's process as its one member and no round waits on the card.
* **A device of no kind is held, not driven.** A device whose role and
  compatible string are in no row of `include/erx/device_kinds.h` gets
  no `-erx_record given` record, so no driver opens it, and no register window
  of its own, DMA window or memory. Its registers on a page that a
  driven device of its unit shares lie in that device's window, as the
  auxiliary SPI controllers lie in the mini UART's on every row: sharing
  inside a domain is the domain's business, so the planner's overlap
  check (`life_overlaps`) refuses only a range that meets another unit's.
  Since no give makes its memory, the boot view refuses a row of
  no kind that asks for DMA memory. Its holder still holds
  it with its unit, and a configured domain's creation gives it only its
  resource: the unit's give makes the IRQ object of each line a device of
  a kind in the unit names, from the first such device, so that the line
  has its one object as the line rule above requires. A line that
  only devices of no kind name has no reader, so no give makes its object. The
  system domain's SPI controllers are such devices, and get no objects of
  their own: they lie in the mini UART's window and line.

**The check.** The domain library's boot view, which the build's
manifest check runs and the root runs again at boot, computes each
device's pages and line from the manifest's device rows and refuses the
whole view, naming both devices, when two devices that share a page or a
line are in two units (`liberx/system/dom_boot_view.c`, `boot_devices`).
At boot the device service computes the same relations from the
catalogue and the kernel's listing and gives a unit the machine splits
differently to no domain, with a diagnostic
([design-system.md](design-system.md#devices)). Within a unit, sharing
is allowed on every row, configured domains included, because the give
makes one window per run and one IRQ object per line.

**PCIe INTx.** Fanning a bridge's INTx line out to functions in several
domains would need the kernel to deliver one line to several holders and
unmask it only when all of them answered, a mechanism no other part of
erXos needs. A function is therefore given an MSI or MSI-X route and
never an INTx line, and a function that offers neither is given with no
interrupt, so its driver polls or the manifest leaves it out
([design-pcie.md](design-pcie.md#interrupts)).

A **closed bus** is the one exception, because the fan-out cannot arise
there: its platform record marks the bridge closed and lists every place
below its one root port with the pin its function raises, and its
bridge driver reaches no other place, so every function that can raise
a line its tree routes sits at a place known when the manifest is
written, whatever the manifest selects. A row at such a place names the
line its place's pin routes, the line joins the construction's line
relation, and the unit is given whole as any other; a tree that routes a
place's pin to one of the bridge's own lines makes the bridge and the
place one unit across two domains, which the boot view refuses. The Raspberry Pi 4's
bus is the only closed one; every other PCIe function interrupts by MSI
([design-pcie.md](design-pcie.md#the-closed-bus)).

The Raspberry Pi 4's bus is the one exception, because the fan-out
cannot arise there. Its bridge has one root port and one soldered
endpoint position, bus 1, device 0, and no MSI frame erXos drives: the
bridge's MSI decoder shares its register page with the windows the PCIe
domain programs. The platform record names that position and the INTx
line its pin routes, so every function that can raise the line is known
when the manifest is written; the line and those functions form one
unit by the construction above, given whole to one domain, and the line
is a direct line of that unit, made as any device-tree unit's line is.
The enumerator keeps the root port's own INTx disabled. No other
platform's record names such a bus, so every other PCIe function
interrupts by MSI ([design-usb.md](design-usb.md#interrupts)).

## Pages inside a domain

A record's window is the part of its pages that its own peripheral's
registers occupy, and the record reaches the device through that page
run's one mapping ([design-runtime.md](design-runtime.md#the-device-nif)).

**One mapping per run.** A given device's record names its unit's window
object and its own offset and size in it, and records of one run name one
object, since the domain library installs each object into a domain under
one handle. The system domain's physical records name the run's base and
length besides their own window. The NIF maps a run once, at the first
open of any record in it, and keeps the mapping for the boot, as it keeps
every record; each later record of the run takes its window at its offset
in that mapping. Opening the same window again is that record again, as
it is for any record.

**Confinement by name.** A record reaches only the registers its
peripheral's generated table names, each at an offset below the window's
size, so the other devices of the page are inside the mapping and outside
every name the record has. The generator refuses a register outside its
peripheral's address block, whose size is the window's, and the NIF
refuses a record whose window is smaller than that block, so a table
cannot name a sibling's register by accident.

**Registers that serve several sub-devices.** A register of the unit's
parent, such as the auxiliary block's enables, which switch the mini UART
and both SPI controllers on and off, belongs to the parent's record,
written only by the parent's driver. A sibling's driver that needs it
changed asks the parent's driver by message, inside the domain. The
Raspberry Pi 4's unit has no parent record: the firmware enables the mini
UART (`enable_uart=1`) and no driver changes the enables.

## Lines inside a domain

**Shared and direct lines.** A line is **shared** when two or more
devices of its unit name it, and **direct** when one does. The relation
is the one the boot view checks ([The unit rule](#the-unit-rule)), so
the device service writes it into each device's record beside the line,
for given and physical records alike, and the device NIF's entry for the
line carries it ([Interfaces](#interfaces)). No caller says whether a
line is shared, so no caller can say it wrongly. A shared line that one
driver uses is still shared: on the Raspberry Pi 4 the mini UART's line
125 is shared with the SPI controllers, which have no driver, and
UART3's line 153 with the other PL011s.

**The driver's side.** A driver attaches each of its lines with
`erx_irq_line:attach(Dev, Line)`, which returns a line handle, and
acknowledges with `erx_irq_line:ack(Handle)`. `attach` reads the line's
mark from the record. For a direct line attach is
`erx_device:irq_bind/2` and ack is `erx_device:irq_ack/2`, as for every
line ([design-runtime.md](design-runtime.md#the-device-nif)). For a
shared line attach is a join: it asks the NIF which process the line is
bound to, `erx_device:irq_holder/2`, and calls that process, a call that
monitors it, so an owner that ended after the lookup answers
`{error, unbound}` instead of leaving the driver waiting or handing it a
handle to a process that is gone. Ack on a shared line is a message to
the owner saying the driver is done. In both cases the driver receives
`{erx_irq, Dev, Line}`, with its own record and line, so a driver's
receive and service code does not depend on whether its line is shared,
and after attach it unmasks its device's interrupt and drains once, as
it does after a bind. A driver acknowledges once for each delivery and only after
receiving it. The owner takes an answer from a member it is not waiting
on as nothing, since the core's `done` outside a round's `W` is nothing,
so a stray answer is ignored; a second answer to one notice would count
for the next round, which the contract rules out as it rules out a second
`irq_ack/2` of one delivery on a direct line.

The NIF holds a shared line for its owner alone: `irq_bind/2` of a
shared line is `{error, shared}`, and `erx_device:irq_bind_owner/2`, the
owner's bind, of a direct line is `{error, direct}`. So a driver cannot
bind a shared line directly, by mistake or by a wrong argument, and take
its deliveries from the drivers that joined the owner.

**The owner.** A line owner is an Erlang process started before the
drivers on its line. It opens the record of the first driver on the
line, binds the line through it with `irq_bind_owner/2`, which moves any
binding a former owner left on that record and acknowledges the line
once, and then runs one pure state machine, `erx_irq_line_core`, whose
next action it performs: a notice to a driver or the line's
acknowledgement. Its state is the set of members and the round in
progress.

**A member is a monitor.** The owner answers a join by monitoring the
joining driver first, and the monitor's reference is the member: the
core's join event carries it, the driver's handle holds it, the driver's
done names it, and the monitor's down message removes it. The core has
no way to hold a member without a monitor, so a member's exit reaches
it in every state. A driver that joins for two of its records on one
line is two members, each told with its own record.

| State | Meaning |
| --- | --- |
| `idle` | no round is in progress |
| `{round, W, Again}` | the line fired; the owner told every member in `W`, which is not empty, and waits for each to answer or exit; `Again` says whether the line has fired since the round began |
| `held` | the line fired while there was no member; the owner does not acknowledge it until a member has answered or exited |

| Event | In `idle` | In `{round, W, Again}` | In `held` |
| --- | --- | --- | --- |
| the line fires | tell every member and go to `{round, members, false}`; with no member go to `held` | set `Again` | nothing |
| member `M` joins | add `M` | add `M`; it is told in the next round | add `M`, tell `M`, and go to `{round, {M}, false}` |
| member `M` is done | nothing | remove `M` from `W`; when `W` is empty, end the round | nothing |
| member `M` goes down | remove `M` | remove `M` from the members and from `W`; when `W` is empty, end the round | remove `M` |

**Ending a round.** The owner acknowledges the line and, when `Again` is
set, then acts as on a firing in `idle`: a new round tells every member,
those that joined during the last round included, or with no member the
line is held.

Every guarantee of the line follows from that machine:

* **The line is acknowledged once per round**, and only when every
  member told of the round has answered or gone down.
* **No firing goes untold.** A firing starts a round, holds the line, or
  sets `Again`, and `Again` starts a round that tells every member after
  the acknowledgement. Take members A and B, told of a firing: A answers,
  A's device raises the line again and the owner receives the delivery,
  B answers; the owner acknowledges and tells A and B again, so A
  services what its device raised.
* **Level and edge lines need no case of their own.** A level-sensitive
  line stays masked from its firing until the acknowledgement, so it
  fires during a round only as a stray hint, which costs one more round
  of looks. An edge line or an MSI, which the kernel leaves unmasked when
  it queues a delivery ([design-kernel.md](design-kernel.md#irq-objects)),
  can fire again during a round, and that firing gets its round.
* **A firing with nobody to tell holds the line.** The owner
  acknowledges nothing more until a driver joins and answers or exits, so it does
  not keep acknowledging into a level that is still asserted with nobody
  looking.
* **A late joiner misses nothing.** It is told in the next round, and it
  drains once after attach, as every driver does.

A delivery is a hint to look, never an event in itself
([design.md](design.md#drivers-and-dma)), so a driver told of a firing
its device did not raise reads its status, finds nothing and answers.

**Supervision.** Whoever starts a driver on a shared line starts the
line's owner first and stops it last: a `rest_for_one` supervisor with
the owners of the shared lines first, then the drivers. That order is
all the line asks for, and it is the same in every domain. A holder
domain's unit supervisor
([design-system.md](design-system.md#the-holders-driver-control-facet))
is such a supervisor, with a supervisor of the unit's drivers after the
owners, and a pure function, `erx_irq_line:owners/1`, says from the
drivers' records which owners it starts.

Sharing a line never changes what a failure restarts: each subsystem's
own supervisors decide that. The owner only drops a member that went
down, so a round it was told of ends without it. Where the subsystem
restarts a driver, the restarted driver joins again. Where it restarts
nothing, as the storage domain does, a block driver's end ends the
domain whether or not its line is shared
([design-stopgap.md](design-stopgap.md#littlefs-in-the-storage-domain)).
An owner's end unbinds the line, since a process's exit unbinds the
lines bound under its label, and `rest_for_one` ends every driver after
it, so no driver keeps a handle to an owner that is gone; whether the
owner and the drivers then start again, or the end escalates, is again
the subsystem's restart policy, and a new owner binds the line before
any driver joins it. The driver-control facet's `stop`, `start` and
`restart` of a unit act on the unit's supervisor
([design-system.md](design-system.md#the-holders-driver-control-facet)).

**The system domain.** The system domain's UART drivers are started by
the services they serve, the console, the host link and the line service
of the Bluetooth design
([design-bluetooth.md](design-bluetooth.md#the-controllers-line)), not
by a unit supervisor, and the owners of their shared lines are started
before those services, as the supervision rule above has it: a
`rest_for_one` supervisor with the owners first, which
`erx_irq_line:owners/1` computes from the records of every UART the
manifest's `console`, `hostlink` and `lines` fields name, each record
from its driver module's `console_records/0`, and then the services,
each starting its own driver, which joins its line's owner. So the
system domain's UARTs may share a line with each other, and a line has
one binder whichever services drive it (property 8 of
[design-system.md](design-system.md#the-manifest)). On the Raspberry
Pi 4 both lines are shared: the mini UART's owner has the console's
driver as its one member, and line 153's owner has the host link's
driver and, where the manifest has the Bluetooth line, the line
service's. The console takes its line's owner's end as its driver's,
which ends the runtime.

## The console

The console's UART is a sub-device like any other: on the Raspberry Pi 4
the mini UART is one device of the auxiliary block's unit, its driver
opens the mini UART's record in the page's one mapping, and its line 125
is shared, because the SPI controllers' records name it too, so the
console service starts the line's owner before the driver and the driver
joins it ([The system domain](#lines-inside-a-domain)). The kernel's
early console is separate: it writes the UART by polling, through a
mapping of its own, during boot and at a panic or an end, and uses no
interrupt ([design-platforms.md](design-platforms.md#uarts)), so neither
a shared page nor a shared line reaches it.

On the stopgap the root hands the kernel log to the console when the
console service first takes it, not when a page is first mapped
([design-stopgap.md](design-stopgap.md#the-console)), so a sibling's
mapping of the console's page hands nothing over.

## Interfaces

| Interface | Contract |
| --- | --- |
| `erx_irq_line:owners([{Driver, [Dev]}]) -> [{Dev, Line}]` | pure; from the records of the drivers one supervisor starts, each shared line they name, once, with the record of its first driver and the line's index there |
| `erx_irq_line:attach(Dev, Line) -> {ok, Handle} \| {error, Reason}` | reads the line's mark from the record; direct: `erx_device:irq_bind/2`; shared: a monitored join call to the process `irq_holder/2` names, `{error, unbound}` when no process holds the line or the holder ends before it answers |
| `erx_irq_line:ack(Handle) -> ok` | direct: `erx_device:irq_ack/2`; shared: `{erx_irq_done, Ref}` to the owner, `Ref` the member's monitor, a message that never waits |
| `erx_irq_line:start_owner(Dev, Line)` | opens `Dev`, binds `Line` with `irq_bind_owner/2`, runs `erx_irq_line_core` |
| `erx_irq_line:start_owners([{Driver, [Dev]}]) -> {ok, [pid()]} \| {error, Reason}` | starts the owners `owners/1` names, in order, each linked to the caller |
| `erx_irq_line_core:step(Event, State) -> {[Action], State}` | pure; events `fire`, `{join, Ref, Pid, Dev}`, `{done, Ref}`, `{down, Ref}`; actions `{notify, Pid, Dev}` and `ack` |
| `erx_device:irq_bind(Dev, Line)` | binds a direct line; `{error, shared}` on a shared line |
| `erx_device:irq_bind_owner(Dev, Line)` | binds a shared line for its owner; `{error, direct}` on a direct line |
| `erx_device:irq_holder(Dev, Line) -> {ok, pid()} \| {error, unbound}` | the process the line is bound to, read from the NIF's binding |

`erx_irq_line` and `erx_irq_line_core` belong to the `erx` application,
beside `erx_device`, and are among the modules that may name
`erx_device` ([design-system.md](design-system.md#drivers)).

The device NIF keeps, for each domain, one entry per line: the line's
IRQ object, whether it is shared, and its one binding
([design-runtime.md](design-runtime.md#the-device-nif)). Records that
name the same line share the entry. A bind through the record the line
is bound through moves the binding to the caller, so a restarted binder
takes the line from its predecessor; through any other record of a bound
line it is `{error, ebusy}`, so two owners of one line fail loudly at the
second bind instead of one silently taking the other's interrupts. A
direct line is named by one record, so its only binder is its driver.

## Refusals

* The boot view refuses the whole view, naming both devices, when two
  devices that share a page or a line are in two units; the build fails
  on it, and at boot the root ends the machine as for any refused view.
* The manifest check refuses a `console` and a `hostlink` UART on one
  line (property 8).
* `erx_device:open/1` of a record whose page run meets a mapped run
  without being it is `{error, ebusy}`.
* `erx_device:irq_bind/2` of a shared line is `{error, shared}`, and
  `irq_bind_owner/2` of a direct line is `{error, direct}`.
* A bind through another record of a bound line is `{error, ebusy}`.
* A shared attach is `{error, unbound}` when no process holds the line or
  the holder ends before it answers, and the owner answers
  `{error, badarg}` to a join for a record or line that is not its own;
  either fails the driver's start, which its supervisor sees as any
  failed start.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **SD1.** No register page and no interrupt line is held by two domains | units are closed under sharing a page and sharing a line; a give makes one window per page run and one IRQ object per line of the unit, in the one holder's budget; PCIe functions get MSIs, except a closed bus's rows, each of which names its INTx line as a device-tree row does | a unit row that splits a component; a give per device; an INTx line given on a bus no platform record closes, or apart from its row | the boot view's refusal, in the build and at boot, with a seeded split that shares only a line; the manifest check's seeded manifests that give the VL805's line apart from its function and an INTx line to `qemu-xhci` ([design-usb.md](design-usb.md#the-phase-1-part)) |
| **SD2.** A record reaches only its own device's registers | every access is a register name of its own peripheral below its window size; the generator refuses a table past the window | a raw offset in the interface; a table naming a register past the window | the NIF's host tests on two records of one page; the generator's refusal with a seeded oversized table |
| **SD3.** A line has at most one binder in a domain, and a shared line's binder is its owner | the NIF keeps one entry per line, whose binding is one process; the record's mark decides which bind the NIF accepts, `irq_bind/2` for a direct line and `irq_bind_owner/2` for a shared one; a bind through another record of a bound line is `ebusy`; only `erx_irq_line` calls the binds and `irq_ack/2` | a table keyed by record; a caller that says whether a line is shared; a driver that binds directly | the NIF's host tests with a seeded per-record table and a seeded mark the bind ignores; the device-callers source check, which reads every token of the Erlang sources, strings, quoted atoms and literal tables included, with seeded direct binds and acknowledgements; a pass over the driver applications' BEAM files, which would also see an atom spelled with escapes, is the target ([TODO.md](../TODO.md)) |
| **SD4.** A shared line is acknowledged once per round, after every member told of it answered or went down, and no firing goes untold | `erx_irq_line_core` decides every acknowledgement and every notice; a firing during a round sets `Again`, which starts another round; a member is its monitor, so every member's exit reaches the core; the owner performs only the actions the core returns | an acknowledgement at the first answer; a firing during a round dropped; a member the core holds without a monitor | exhaustive exploration of the core on the host, with seeded faults |

## Failure handling

| Failure | What happens | Recovery |
| --- | --- | --- |
| a driver crashes while told of a firing | its monitor's down message answers for it, and the line is acknowledged once the others answer | whatever its subsystem's supervisors do: a restarted driver joins again; the storage domain restarts nothing and ends |
| a driver hangs without answering | the line stays masked, and every driver on it hears nothing | the driver-control facet's `restart` of the unit, which `/dev`'s `ctl` reaches; a residual below |
| the owner crashes | its exit unbinds the line; drivers' answers to it are lost with it, and `rest_for_one` ends every driver after it | whatever the subsystem's supervisors do; a new owner binds and acknowledges the line once before any driver joins it |
| the owner ends between a driver's lookup and its join | the join call's monitor fires, and attach is `{error, unbound}` | the driver's start fails, and its supervisor sees a failed start |
| a device of the unit that no driver serves asserts a level on the line | every firing tells the members, who find nothing; the line fires again at once | a residual below |
| two owners of one line | the second `irq_bind_owner/2` is `{error, ebusy}` and its start fails | the manifest is corrected |
| a manifest splits a component, or pairs a `console` and `hostlink` UART on one line | the build fails, naming the devices and the property | the manifest is corrected |

**Residuals, Phase 1.** The owner keeps no timeout: a driver that hangs
holds every sharer of its line masked until an operator restarts the
unit, and a device without a driver that asserts its line keeps the
owner busy. Both are faults of a trusted domain's own driver or
configuration; the restart that already exists is the recovery, and a
deadline per firing, after which the owner restarts the slow driver,
belongs with the rest of the hostile-driver work
([TODO.md](../TODO.md)).

## Verification

Each passing case is paired with a seeded fault that proves the code
under test ran.

| Test | Passes when | Seeded fault, which must fail it |
| --- | --- | --- |
| the boot view's unit check, on a fixture of two devices on different pages and one line, placed in two units | the view is refused, naming both devices and the line | the line comparison removed: the view is accepted |
| the same check on a fixture of two adjacent virtio-mmio transports, 0x200 apart in one page, each on a line of its own, placed in two units | refused for the shared page | the page comparison removed: accepted |
| the NIF's host harness (`test/fixtures/erx_device_harness.c`), two physical PL011 records 0x200 apart in one page, each writing and reading back a register | both open over one physical object and one mapping, and each read returns its own record's value | the overlap refusal restored in the open: the second open is `ebusy` |
| the same harness, two physical records naming one line, with the fake kernel refusing a second IRQ object on a line | both open, and the harness counts one IRQ object | the line table keyed by record: the second open fails |
| the same harness, a record whose line is marked shared and one whose line is direct | `irq_bind/2` of the shared line is `{error, shared}` and `irq_bind_owner/2` binds it; the reverse holds for the direct line | the mark ignored by `irq_bind/2`: the shared line binds directly |
| a hosted test of two stand-in records on one soft line | a trigger reaches the process bound through the first; an owner bind through the second is `{error, ebusy}`; a rebind through the first moves the line | one binding per record: the second bind succeeds |
| `erx_irq_line_core`, every sequence of up to eight events over four members and the three states | SD4; every member in `W` told once per round; a firing during a round followed by a round that tells every member; `held` only while no member was told; and the named traces: A and B told, A done, the line fires, B done, which acknowledges and then tells A and B; a join and then that member's down, in `idle`, in a round and in `held`, which leaves no member and, from a round or `held`, acknowledges | acknowledging at the first `done`; `Again` dropped, so the named trace tells A nothing more; a `down` that leaves `W` unchanged; a join in `held` that does not add its member, so its `down` leaves the line masked; a firing with no member acknowledged at once |
| `erx_irq_line:owners/1` over sets of one to four drivers with shared and direct lines | each shared line named by any driver gets one owner, and no direct line does | one owner per record: a driver's two records on one line give two owners |
| a hosted test of two stand-in drivers joined to one owner, with a call trace on `erx_device:irq_ack/2` | each trigger reaches both drivers; the trace shows the acknowledgement only after the second answer; a trigger after the first answer gives both drivers a second notice after the acknowledgement; a killed driver answers by its exit | the owner acknowledging at the first answer: the trace shows it early; the owner ignoring a trigger during a round: no second notice |
| a hosted test that kills the owner after `irq_holder/2` returns and before the join | attach returns `{error, unbound}` within the test's deadline and no handle | the join as a plain send and receive with no monitor: attach hangs past the deadline |
| the source check that only `erx_irq_line` calls `erx_device:irq_bind/2`, `irq_bind_owner/2` and `irq_ack/2` | passes on the tree | a driver module calling `irq_bind/2` directly |

QEMU `virt` gives no device a shared line, so the hosted test's stand-in
is the line test, and the Raspberry Pi 4's PL011s and auxiliary block are
checked by hand on the board.

## Performance

A shared line costs each driver on it two messages inside the domain per
firing, the owner's notice and the driver's answer, on top of the
delivery the owner receives as any binder does, and the line stays masked
until the slowest driver answers. A firing during a round costs every
member one more round. A direct line costs nothing new. On the Raspberry
Pi 4 the console and the host link pay it, since both their lines are
shared. The cost is unmeasured and is on the watch list
([todo-performance.md](todo-performance.md)).

## Alternatives considered

**Fan-out in the device NIF.** The NIF could deliver one line to several
processes and count their acknowledgements, with no owner process and no
added messages. It needs the runtime's event table to deliver one label
to several sinks, a kind of sink it does not have, and puts a protocol
state machine in C where Erlang runs it in a supervised process. Taken
up only if the measurement above shows the messages matter.

**One driver process for every device of a unit.** One process serving
the PL011s would bind their line once, but `erx_pl011`'s transmit loop
waits for its FIFO, so one UART's output would delay another's input, and
the auxiliary block's mini UART and SPI controllers have nothing in
common to share a driver. The owner keeps one driver per device.

**An owner for every line.** It would remove the direct case, at two
messages per interrupt for every device, the network and block devices
included.

**Sharing decided by which drivers run.** A line two running drivers
use is the only line that needs an owner, and computing that from the
drivers would spare the Raspberry Pi 4's UARTs their owners. But it makes
sharing a word callers pass along, and a driver given the wrong word
binds the line directly and takes the others' deliveries. The record's
mark is a fact of the unit that no caller supplies.

**Telling only the pending sub-devices.** Where a unit's parent has a
register naming its pending sub-devices, as the auxiliary block's
interrupt-status register does, the owner could tell only those. It adds
a second path for choosing whom to tell, and no supported board has two
drivers on such a line, so the owner tells every member; a board that
needs it adds it.

**Sharing across domains in the kernel.** A kernel that fanned lines out
could give sub-devices to separate domains, at the price of a mechanism
whose acknowledgement waits on several untrusting holders, and a shared
page would still put one domain's registers in another's mapping. The
homes give another domain a sub-device's function without either.

## Open decisions

* **Console and host link on one line.** The manifest check refuses it.
  The alternative is to start the system domain's two UART drivers under
  one supervisor with the line's one owner, changing how the console and
  host link start their drivers. Recommendation: refuse until a board
  needs it.
* **A deadline per firing.** Recommendation: none in Phase 1, as above;
  revisit with erXos's kernel and hostile drivers.

## References

* [design-system.md](design-system.md#devices): units, gives, drivers and
  the driver-control facet.
* [design-runtime.md](design-runtime.md#the-device-nif): the device NIF's
  windows and interrupts.
* [design-platforms.md](design-platforms.md#invariants): PL2.
* [design-kernel.md](design-kernel.md#irq-objects): one IRQ object per
  line.
* FreeBSD `puc(4)`, `scc(4)` and `bus_setup_intr(9)`; Genode's platform
  driver; Zircon's interrupt objects and PCI bus driver.
