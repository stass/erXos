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
* **Inside the domain a shared line has one owner.** A line that two of a
  unit's drivers use is bound once, by a supervised Erlang process, the
  **line owner**, which tells every driver on the line of each firing and
  acknowledges the line when all of them have answered or exited. A line
  that one driver uses is bound by that driver, as any line is.
* **PCIe functions interrupt by MSI only.** A bridge's INTx lines, which
  the functions behind it share, go to no domain.

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
| a PCIe bridge's INTx lines | every function behind the bridge | none: MSI only |

The Raspberry Pi 4's console is its mini UART and its host link is UART3,
so the console's unit is the auxiliary block's and the host link's is the
PL011s'; both go to the system domain, which runs one driver in each
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
part in the line relation, since they interrupt by MSI, each MSI a line
of the MSI frame that no other function has.

Each requirement follows from that one closure:

* **The kernel never meets a contested page or line.** A give makes the
  objects of a whole unit in the holder's budget
  ([design-system.md](design-system.md#devices)): one register window over
  each run of consecutive pages the unit's register ranges cover, and one
  IRQ object for each distinct line its devices name. Every page is in
  one window and every line in one object, so the kernel's refusal of a
  second MMIO object on a page or a second IRQ object on a line
  ([design-kernel.md](design-kernel.md#dma-and-the-iommu)) never fires on a
  give the boot view accepted.
* **No domain reaches another's device through a shared page or line.**
  A domain's mapping of a page covers only devices of units it holds,
  and its IRQ objects carry only lines no other domain's device raises.
* **Sharing inside a domain is the domain's business.** The device NIF
  shares mappings and IRQ objects among the records of one domain
  ([Pages inside a domain](#pages-inside-a-domain)), and the line owner
  shares a line among drivers ([Lines inside a
  domain](#lines-inside-a-domain)). Neither crosses a domain, so neither
  needs the kernel.
* **A sub-device's function crosses by a home.** The system domain holds
  the auxiliary block's SPI controllers because they share the console's
  page, and runs no driver for them. A board on which a domain other than
  the holder needs such a function, a pin of a GPIO controller or a clock
  of a clock controller, gets it from the holder's driver: a file tree the
  holder serves, with a `ctl` file for one-shot control, or a facet of a
  service `abi/services` declares, never the registers or the line.

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
erXos needs. The PCIe enumerator therefore programs MSI or MSI-X into
every function it reports, the device service gives a function its MSIs
and never an INTx line, and a function that offers neither is given with
no interrupt, so its driver polls or the manifest leaves it out.

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

**The plan.** The process that starts a unit's drivers, the unit's
supervisor in a holder domain
([design-system.md](design-system.md#the-holders-driver-control-facet)),
knows each driver's device records before it starts any of them. A pure
function, `erx_irq_line:plan/1`, takes the records' lines, each a line
object's handle or, for a physical record, a line number, and answers
which lines two or more of the drivers name. Each such line is
**shared**: the plan adds an owner for it, and tells each driver on it
that its line is shared. Every other line is **direct**.

**The driver's side.** A driver attaches each of its lines with
`erx_irq_line:attach(Dev, Line, Sharing)`, which returns a line handle,
and acknowledges with `erx_irq_line:ack(Handle)`. For a direct line
attach is `erx_device:irq_bind/2` and ack is `erx_device:irq_ack/2`, as
for every line ([design-runtime.md](design-runtime.md#the-device-nif)).
For a shared line attach is a join, a call to the line's owner, which the
NIF names as the process bound to the line, and ack is a message to the
owner saying the driver is done. In both cases the driver receives
`{erx_irq, Dev, Line}`, with its own record and line, so a driver's
receive and service code does not depend on whether its line is shared,
and after attach it unmasks its device's interrupt and drains once, as
it does after a bind.

**The owner.** A line owner is an Erlang process started before the
drivers on its line. It opens the record of the first driver on the line,
binds the line through it once, which moves any binding a former owner
left and acknowledges the line once, and then runs one pure state
machine, `erx_irq_line_core`, whose next action it performs: a message to
a driver, a monitor, or the line's acknowledgement. Its state is the set
of joined drivers and the firing in progress, one of:

| State | Meaning |
| --- | --- |
| `idle` | the line is unmasked and has not fired since the last acknowledgement |
| `{firing, W}` | the line fired; the owner told every driver in `W`, which is not empty, and waits for each to answer or exit |
| `held` | the line fired while no driver was joined; it stays masked |

| Event | In `idle` | In `{firing, W}` | In `held` |
| --- | --- | --- | --- |
| the line fires | tell every joined driver and go to `{firing, joined}`; with no driver joined go to `held` | nothing: the line is masked, so this is a stray hint, and every driver in `W` is about to look | nothing |
| driver `P` joins | add `P` and monitor it | add `P`; it is told at the next firing | add `P`, tell `P`, and go to `{firing, {P}}` |
| driver `P` is done | nothing | remove `P` from `W`; when `W` is empty, acknowledge and go to `idle` | nothing |
| driver `P` exits | remove `P` | remove `P` from the joined set and from `W`; when `W` is empty, acknowledge and go to `idle` | remove `P` |

So the line is acknowledged exactly once per firing that told anyone,
and only when every driver told of it has answered or exited, and a
firing nobody was told of keeps the line masked until a driver joins
rather than acknowledging into a level that is still asserted. A driver
that joins during a firing is not waited for; if its device asserts the
line, the line fires again at the acknowledgement and the driver is told
then. A delivery is a hint to look, never an event in itself
([design.md](design.md#drivers-and-dma)), so a driver told of a firing
its device did not raise reads its status, finds nothing and answers.

**A parent that knows which sub-device is pending.** Where a unit has a
parent record with a register naming the sub-devices that are pending,
such as the auxiliary block's interrupt-status register, the plan gives
the line's owner a pending function from the parent's driver module, and
the owner tells only the joined drivers it names. When it names none of
them, the owner tells every joined driver, so a firing is never
acknowledged unread. The parent's driver module supplies the function;
the owner stays generic.

**Supervision.** The unit's supervisor is `rest_for_one`: the owners of
the unit's shared lines first, then a `one_for_one` supervisor of the
unit's drivers. A driver's crash restarts that driver alone; its exit is
the owner's `exit` event, so the firing it held is answered for it. An
owner's crash ends its binding, since a process's exit unbinds the lines
bound under its label, and restarts every driver of the unit after the
new owner has bound the line, so each restarted driver joins the new
owner. The driver-control facet's `stop`, `start` and `restart` of the
unit act on the unit's supervisor
([design-system.md](design-system.md#the-holders-driver-control-facet)).

**The system domain.** The system domain's UART drivers are started by
the services they serve, the console and the host link, not by a unit
supervisor. The manifest check refuses a manifest whose `console` and
`hostlink` UARTs share a line (property 8 of
[design-system.md](design-system.md#the-manifest)), so each of the
system domain's drivers has a direct line. Neither supported board has
such a pair.

## The console

The console's UART is a sub-device like any other: on the Raspberry Pi 4
the mini UART is one device of the auxiliary block's unit, its driver
opens the mini UART's record in the page's one mapping, and its line is
direct because no other driver of the system domain names line 125. On a
board whose console shared a line with another driver of a unit, the
console's driver would join that line's owner as any driver does. The
kernel's early console is separate: it writes the UART by
polling, through a mapping of its own, during boot and at a panic or an
end, and uses no interrupt
([design-platforms.md](design-platforms.md#uarts)), so neither a shared
page nor a shared line reaches it.

On the stopgap the root hands the kernel log to the console when the
console service first takes it, not when a page is first mapped
([design-stopgap.md](design-stopgap.md#the-console)), so a sibling's
mapping of the console's page hands nothing over.

## Interfaces

| Interface | Contract |
| --- | --- |
| `erx_irq_line:plan([{Driver, [LineKey]}]) -> {Owners, #{Driver => [direct \| shared]}}` | pure; `LineKey` is a line object's handle or a physical line number from the driver's records; a key named by two or more drivers is shared and gets one entry in `Owners`, with the record of its first driver and the line's index there |
| `erx_irq_line:attach(Dev, Line, direct \| shared) -> {ok, Handle} \| {error, Reason}` | direct: `erx_device:irq_bind/2`; shared: a join call to the line's owner, `{error, unbound}` when no process holds the line |
| `erx_irq_line:ack(Handle) -> ok` | direct: `erx_device:irq_ack/2`; shared: `{erx_irq_done, self()}` to the owner, a message that never waits |
| `erx_irq_line:start_owner(Spec, Line, Pending)` | opens `Spec`, binds `Line`, runs `erx_irq_line_core`; `Pending` is `all` or a function of the parent's record |
| `erx_irq_line_core:step(Event, State) -> {[Action], State}` | pure; events `{fire, Pending}`, `{join, P}`, `{done, P}`, `{exit, P}`; actions `{notify, P}`, `{monitor, P}`, `ack` |
| `erx_device:irq_holder(Dev, Line) -> {ok, pid()} \| {error, unbound}` | the process the line is bound to, read from the NIF's binding |

`erx_irq_line` and `erx_irq_line_core` belong to the `erx` application,
beside `erx_device`, and are among the modules that may name
`erx_device` ([design-system.md](design-system.md#drivers)).

The device NIF keeps, for each domain, one entry per line: the line's
IRQ object and its one binding
([design-runtime.md](design-runtime.md#the-device-nif)). Records that
name the same line share the entry. `irq_bind/2` through the record the
line is bound through moves the binding to the caller, so a restarted
binder takes the line from its predecessor; through any other record of
a bound line it is `{error, ebusy}`, so two binders on one line fail
loudly at the second bind instead of one silently taking the other's
interrupts.

## Refusals

* The boot view refuses the whole view, naming both devices, when two
  devices that share a page or a line are in two units; the build fails
  on it, and at boot the root ends the machine as for any refused view.
* The manifest check refuses a `console` and a `hostlink` UART on one
  line (property 8).
* `erx_device:open/1` of a record whose page run meets a mapped run
  without being it is `{error, ebusy}`.
* `erx_device:irq_bind/2` through another record of a bound line is
  `{error, ebusy}`.
* A shared attach is `{error, unbound}` when no process holds the line,
  and the owner answers `{error, badarg}` to a join for a record or line
  that is not its own; either fails the driver's start, which its
  supervisor sees as any failed start.

## Invariants

| Invariant | Why it holds | What would break it | How it is checked |
| --- | --- | --- | --- |
| **SD1.** No register page and no interrupt line is held by two domains | units are closed under sharing a page and sharing a line; a give makes one window per page run and one IRQ object per line of the unit, in the one holder's budget; PCIe functions get MSIs only | a unit row that splits a component; a give per device; an INTx line given to a domain | the boot view's refusal, in the build and at boot, with a seeded split that shares only a line |
| **SD2.** A record reaches only its own device's registers | every access is a register name of its own peripheral below its window size; the generator refuses a table past the window | a raw offset in the interface; a table naming a register past the window | the NIF's host tests on two records of one page; the generator's refusal with a seeded oversized table |
| **SD3.** A line has at most one binder in a domain | the NIF keeps one entry per line, whose binding is one process; a bind through another record of a bound line is `ebusy`; only `erx_irq_line` calls `irq_bind/2` and `irq_ack/2` | a table keyed by record; a driver that binds directly | the NIF's host test with a seeded per-record table; a source check over the driver applications' BEAM files with a seeded direct bind |
| **SD4.** A shared line is acknowledged once per firing, after every driver told of it answered or exited | `erx_irq_line_core` decides every acknowledgement; its owner performs only the actions it returns | an acknowledgement at the first answer; an exit that does not count as an answer | exhaustive exploration of the core on the host, with seeded faults |

## Failure handling

| Failure | What happens | Recovery |
| --- | --- | --- |
| a driver crashes while told of a firing | its exit answers for it, and the line is acknowledged once the others answer | its supervisor restarts it, and it joins again |
| a driver hangs without answering | the line stays masked, and every driver on it hears nothing | the driver-control facet's `restart` of the unit, which `/dev`'s `ctl` reaches; a residual below |
| the owner crashes | its exit unbinds the line; drivers' answers to it are lost with it | the unit's supervisor restarts the owner, which binds and acknowledges the line once, then every driver of the unit, which join it |
| a device of the unit that no driver serves asserts a level on the line | every firing tells the joined drivers, who find nothing; the line fires again at once | a residual below |
| two binders on one line | the second `irq_bind/2` is `{error, ebusy}` and its driver's start fails | the manifest or the plan is corrected |
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
| the same check on the Raspberry Pi 4's record with the PL011s split across two units | refused for the shared page | the page comparison removed: accepted |
| the NIF's host harness (`test/fixtures/erx_device_harness.c`), two physical PL011 records 0x200 apart in one page, each writing and reading back a register | both open over one physical object and one mapping, and each read returns its own record's value | the overlap refusal restored in the open: the second open is `ebusy` |
| the same harness, two physical records naming one line, with the fake kernel refusing a second IRQ object on a line | both open, and the harness counts one IRQ object | the line table keyed by record: the second open fails |
| a hosted test of two stand-in records on one soft line | a trigger reaches the process bound through the first; a bind through the second is `{error, ebusy}`; a rebind through the first moves the line | one binding per record: the second bind succeeds |
| `erx_irq_line_core`, every sequence of up to eight events over four driver pids and the three states | SD4, every driver in `W` told exactly once per firing, and `held` only while no driver was told | acknowledging at the first `done`; an `exit` that leaves `W` unchanged; a firing with no driver acknowledged at once |
| `erx_irq_line:plan/1` over units of one to four drivers and lines | exactly the lines named twice are shared, each with one owner | counting a driver's own two records as two drivers |
| a hosted test of two stand-in drivers joined to one owner, with a call trace on `erx_device:irq_ack/2` | each trigger reaches both drivers; the trace shows the acknowledgement only after the second answer; a killed driver answers by its exit | the owner acknowledging at the first answer: the trace shows it early |
| the source check that only `erx_irq_line` calls `erx_device:irq_bind/2` and `irq_ack/2` | passes on the tree | a driver module calling `irq_bind/2` directly |

QEMU `virt` gives no device a shared line, so the hosted test's stand-in
is the line test, and the Raspberry Pi 4's PL011s and auxiliary block are
checked by hand on the board.

## Performance

A shared line costs each driver on it two messages inside the domain per
firing, the owner's notice and the driver's answer, on top of the
delivery the owner receives as any binder does, and the line stays masked
until the slowest driver answers. A direct line costs nothing new. The
cost is unmeasured and is on the watch list
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

**An owner for every line.** It would remove the plan and the direct
case, at two messages per interrupt for every device, the network and
block devices included.

**Sharing across domains in the kernel.** A kernel that fanned lines out
could give sub-devices to separate domains, at the price of a mechanism
whose acknowledgement waits on several untrusting holders, and a shared
page would still put one domain's registers in another's mapping. The
homes give another domain a sub-device's function without either.

## Open decisions

* **Console and host link on one line.** The manifest check refuses it.
  The alternative is to start the system domain's two UART drivers under
  one unit supervisor with a line owner, changing how the console and host
  link start their drivers. Recommendation: refuse until a board needs
  it.
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
