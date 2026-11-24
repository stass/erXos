# Appendix B. Reading the Design Documents

The book explains erXos; the design documents decide it. Behind the
chapters stand forty-eight documents named `design-*.md`, together more
than a hundred thousand lines, each the contract of one subsystem.
Each is written for the people who build or review its subsystem and
assumes they know the rest. A reader who opens one cold meets terms
defined three documents away. This appendix is the way in: what the
documents are, an order to read them in, what each is for, the layout
most share, where decisions are written down, and which chapter
prepares a reader for which documents.

## B.1 What the documents are, and what they are not

A design document states a contract. It says what a subsystem
promises, what it refuses, which invariants hold, who owns what, how
each part fails and how the claims are tested. When the book and a design document disagree, the
design document is right and the book is fixed
([README.md, Conventions](README.md#conventions)).

Three properties of the documents surprise a newcomer.

* **They describe the target, in the present tense.** A design
  document says how the subsystem works when it is complete. It is not
  trimmed to match the code and says nothing of what is finished. To
  learn what is built, read the root
  [README.md, Current status](../../README.md#current-status), the
  tree and its tests, and [TODO.md](../../TODO.md), which lists open
  defects and known gaps. The book's Built and Designed marks come from
  those, not from the design documents' tense.
* **Three describe the kernel interface in a stronger form than the
  system's kernel gives it.** [design-kernel.md](../design-kernel.md)
  defines the objects, capabilities and calls of the kernel interface
  of [chapter 8](08-kernel-interface.md) as a kernel that would hold
  every isolation property itself;
  [design-scheduler.md](../design-scheduler.md) describes CPU time in
  the same form, and
  [design-arch-aarch64.md](../design-arch-aarch64.md) binds that form
  to the processor. The system's kernel is Fiasco.
  [design-fiasco.md](../design-fiasco.md) says which of those
  properties Fiasco gives, how `liberx` carries the interface over it,
  and what the system does without the rest. Where they differ,
  design-fiasco.md describes the running system, and the book follows
  it.
* **They carry the project's planning notes.** The documents say in
  places how the work is staged; the book leaves those notes out, and
  [plan.md](../plan.md), the roadmap, holds them.

Around the design documents sit others with different jobs.
[overview.md](../overview.md) is a short introduction for a reader new
to the idea. [design.md](../design.md) is the architecture: the shape
of the system, every decision that constrains more than one
subsystem, and the [Document map](../design.md#document-map) from which
section B.3 is drawn. [style.md](../style.md) is the code style guide.
The research records, `research-*.md`, are dated reports of what was
measured or read, never edited after. The user guide,
[docs/guide/](../guide/README.md), says how to build and use the
system.

## B.2 A reading order

A reader who wants the documents without the book does best in this
order, in which each step defines terms the next one uses.

1. **[overview.md](../overview.md).** The idea in a few pages: why an
   operating system around Erlang, and what a user sees.
2. **[design.md](../design.md), five sections.**
   [Context](../design.md#context) and
   [Requirements](../design.md#requirements) say what problem the
   system solves. [The model](../design.md#the-model) defines the
   vocabulary every other document uses: domain, facet, lane, funnel,
   budget and the rest. [Overview](../design.md#overview) shows what
   runs where, and [Invariants](../design.md#invariants) lists the
   properties the system holds by construction. Leave the rest of
   design.md for later; it is a reference.
3. **[design-fiasco.md](../design-fiasco.md), the
   [Contract](../design-fiasco.md#contract) first.** What the kernel
   gives the system, how `liberx` carries the kernel interface over
   Fiasco, and what Fiasco does not give.
4. **[design-domains.md](../design-domains.md).** Domains, the pid
   space, connections, exports, the funnel and facets: how two walled
   groups of Erlang processes talk as one Erlang system.
5. **[design-system.md](../design-system.md).** The system domain: the
   root task, the system manifest, the domain library, devices and
   drivers, and the system services. It is long; read its opening and
   the sections on the manifest and the domain library, and return for
   the rest.
6. **[design-runtime.md](../design-runtime.md).** How ERTS runs in user
   mode on `liberx`, the runtime images, the device NIF and the C
   library seam.
7. **[design-files.md](../design-files.md).** Namespaces and the file
   protocol, which most services use to present themselves.
8. **The subsystem the reader came for**, from the table in section
   B.3.
9. **[design-generation.md](../design-generation.md),
   [design-abi.md](../design-abi.md) and
   [design-verification.md](../design-verification.md).** How the
   documents' tables become code and how their claims are checked.

design.md's [Decisions](../design.md#decisions) is
worth a skim after step 2 and a careful read after step 7, when its
rows name things the reader has met.

## B.3 What each document is for

The documents fall into groups that match the book's parts. Each row
gives the question the document settles.

| Document | What it settles |
| --- | --- |
| [design.md](../design.md) | The architecture: the model, the invariants and every decision that spans subsystems |
| [design-fiasco.md](../design-fiasco.md) | How the system runs on Fiasco: the `liberx` backend, the call table, the scheduler and budgets on Fiasco, and what Fiasco does not give |
| [design-kernel.md](../design-kernel.md) | The kernel model behind the kernel interface: objects, capabilities, budgets, memory, threads, IPC, interrupts, boot and L4 lineage |
| [design-scheduler.md](../design-scheduler.md) | The two levels of scheduling: groups and their CPU quotas in the kernel model, urgency, park and wake, service work, and the runtime contract |
| [design-arch-aarch64.md](../design-arch-aarch64.md) | The AArch64 binding of the kernel's port contract |
| [design-platforms.md](../design-platforms.md) | The boards: QEMU `virt`, the Raspberry Pi 4 and 5 |
| [design-runtime.md](../design-runtime.md) | Runtimes in user mode: ERTS recombined, runtime images, the device NIF, the C library seam, `liberx` |
| [design-shared-code.md](../design-shared-code.md) | One image of loaded code mapped into every domain |
| [design-domains.md](../design-domains.md) | Domains, the pid space, connections, exports, the funnel, frames and facets |
| [design-system.md](../design-system.md) | The root task, the system manifest, the domain library, devices and drivers, the system services and the vault |
| [design-programs.md](../design-programs.md) | Native programs and the POSIX-lite personality |
| [design-pipes.md](../design-pipes.md) | Pipes in user space |
| [design-files.md](../design-files.md) | Namespaces, the file protocol (9P2000.L), file servers and shared mappings |
| [design-tmp.md](../design-tmp.md) | The RAM file system at `/tmp` |
| [design-storage.md](../design-storage.md) | Partitions, the boot image, system partitions, EROFS, FAT and updates through two slots |
| [design-f2fs.md](../design-f2fs.md) | erXos's F2FS, the main read-write file system, in Erlang |
| [design-stopgap.md](../design-stopgap.md) | littlefs in the storage domain and its contract |
| [design-drives.md](../design-drives.md) | Drives: every medium but the boot card, served whole; its table, its formats and its volumes at `/media` |
| [design-shared-devices.md](../design-shared-devices.md) | Devices that share a register page or an interrupt line |
| [design-device-dma.md](../design-device-dma.md) | DMA by devices that are not cache-coherent, and the descriptor forms the device NIF drives |
| [design-device-tree.md](../design-device-tree.md) | The firmware's device tree in the root task |
| [design-pcie.md](../design-pcie.md) | PCIe: the enumerator, BAR placement, bus mastering and interrupts |
| [design-usb.md](../design-usb.md) | USB: xHCI, hubs, HID and mass storage |
| [design-header-io.md](../design-header-io.md) | The Raspberry Pi 4's 40-pin header: GPIO, I2C, SPI and PWM |
| [design-pinctrl.md](../design-pinctrl.md) | Pin control: a board's pin table, the pin driver, named pin states and plain GPIO |
| [design-rp1.md](../design-rp1.md) | RP1, the Raspberry Pi 5's I/O controller: its parts, interrupts, Ethernet and USB hosts |
| [design-board-sensors.md](../design-board-sensors.md) | The Raspberry Pi 4's firmware readings and `/proc/sensors` |
| [design-network-stack.md](../design-network-stack.md) | The TCP/IP stack, FreeBSD's behavior in Erlang, and its fast path |
| [design-time.md](../design-time.md) | Network time and the clock service |
| [design-wifi.md](../design-wifi.md) | WiFi on the Raspberry Pi 4's CYW43455 |
| [design-bluetooth.md](../design-bluetooth.md) | Bluetooth Low Energy, peripheral first, and `bleuart`, root's shell over Nordic's UART service |
| [design-crypto.md](../design-crypto.md) | Cryptography: OpenSSL in the runtime images, OTP's crypto applications, HTTPS clients |
| [design-ssh.md](../design-ssh.md) | SSH: the SSH domain, logins, keys and channels |
| [design-login.md](../design-login.md) | Logging in through a front end: the one `login` facet for SSH, the web and `bleuart`'s root line |
| [design-shell.md](../design-shell.md) | The command shell: rc's language, the command namespace, text pipelines, job control |
| [design-vi.md](../design-vi.md) | evi, the screen editor run as `vi` |
| [design-live.md](../design-live.md) | The live machine: console, ttys, attributed text, the inspector and `/proc`, tracing, the code store, the host link |
| [design-log.md](../design-log.md) | The system log |
| [design-display.md](../design-display.md) | Composition, input routing, window buffers, the draw protocol, the terminal, widget trees, kiosks, graphics hardware |
| [design-desktop-programs.md](../design-desktop-programs.md) | The desktop's own programs and the shared visual theme |
| [design-find-act.md](../design-find-act.md) | Find and act: the session's palette and routes from values to rc lines |
| [design-web.md](../design-web.md) | The web client and its two front ends |
| [design-book-site.md](../design-book-site.md) | The book on the website: Markdown rendered to static pages at build time, diagrams drawn from the book's Mermaid, typography and fonts |
| [design-apps.md](../design-apps.md) | Apps as principals, the start table and `service` |
| [design-packaging.md](../design-packaging.md) | Packages: one file per app, admission, install and update at run time, the SDK |
| [design-app-trees.md](../design-app-trees.md) | An app's own tree at `/svc/NAME` |
| [design-generation.md](../design-generation.md) | Generated bindings, inspection, catalogs, test scaffolding, and the hardware and terminal sources |
| [design-abi.md](../design-abi.md) | The declaration grammar, layouts, bounded readers and numeric assignments |
| [design-build.md](../design-build.md) | The build and host tooling: deadlines, source records, evidence boundaries |
| [design-host-oracle.md](../design-host-oracle.md) | Stock OTP as the test oracle, in an isolated Linux container |
| [design-verification.md](../design-verification.md) | Pure protocol cores, TLA+ models and the evidence that ties a model to its code |
| [design-bench.md](../design-bench.md) | The benchmarks: the record, the one clock, the comparison rule, the three hard limits and the other systems on the same board |

*Table B.1. The design documents, grouped by subject, drawn from
[design.md, Document map](../design.md#document-map).*

Sizes vary by a factor of sixty, from under 150 lines for littlefs to
over nine thousand for design-kernel.md; in a long one, read the table
of contents first.

## B.4 The common layout

Most design documents share one skeleton. The sections below
appear roughly in this order, as in
[design-pipes.md](../design-pipes.md); the counts say how many of the
forty-five carry each one under that name.

* **Context** (35). The problem, the consumers that need the subsystem
  and what breaks without it.
* **Requirements** (33). What the subsystem must do. Each requirement
  should name the consumer that needs it; one that names none is a
  defect in the document, since the project questions every
  requirement before building for it.
* **Overview** (22) or **The construction** (10). The parts, where
  each runs and who owns which state. A large subsystem gets one section
  per part instead, as in [design-wifi.md](../design-wifi.md).
* **Data model** (21) and **Interfaces** (24). The records, formats and
  calls, often as tables that a generator reads (chapter 7).
* **Algorithms and behavior** (19). How the parts act over time,
  usually as pure functions and state machines.
* **Invariants** (27). The properties that always hold, each stated
  so that a test or a build check can fail on it.
* **Concurrency** and **Failure handling, diagnostics and
  debuggability**, under these or shorter names: a Concurrency section in 17
  documents, a Failure section in 30.
  What runs at once, what each failure reaches, which supervisor restarts what, and what
  an operator sees.
* **Refusals and error results** (9) and **Untrusted input** (2). What
  the subsystem says no to, with which status, and which bytes from
  outside it parses.
* **Security** (31) and **Performance** (30). The threat each part
  faces and the costs that matter, with the measurement that settles
  each unmeasured one.
* **Verification** or **Verification and testing** (42 together). The
  tests, fuzz targets, models and build checks, each tied to the claim
  it checks.
* **Alternatives considered** (36). The designs that lost, and why.
* **Risks and open questions** (16) or **Open decisions** (8). What is
  not settled.
* **References** (36) or **Sources** (3). The specifications, papers
  and source code read, with versions.

Seven documents add a section **On Fiasco**, which says how the
subsystem's design is carried on the system's kernel; design-fiasco.md
holds the rest of that story. Two add a lineage section, on which Appendix E
draws. design-kernel.md records where the kernel model keeps L4's and
Fiasco's choices and where it departs; design-wifi.md, which idea came
from which WiFi implementation.

Two habits make the documents faster to read. First, read Context,
then Invariants, then Failure, then Verification: together they say
what the subsystem promises and how anyone would know, and the middle
sections become detail to look up. Second, follow the first link to a
term rather than guessing. The documents define each term once, in
[design.md, The model](../design.md#the-model) or in the document that
owns it, and use it exactly.

## B.5 Where decisions are recorded

Every decision has one home. The rule is the documents' own
application of "one source for every fact" (chapter 7): a decision
written in two places comes to say two things.

* **A decision that constrains more than one subsystem** is a row of
  [design.md, Decisions](../design.md#decisions): the decision, its
  rationale, and the document that specifies it. The two-level
  scheduling contract, a pid that names its owner domain and the use
  of FreeBSD's network
  behavior are rows there.
* **Any other decision** lives in the document it shapes, in the
  section the decision concerns. Eight documents also collect theirs in
  a **Decisions** section.
* **The designs that lost** are in each document's **Alternatives
  considered**, with the reason. design.md's
  [Alternatives considered](../design.md#alternatives-considered)
  holds the system-wide ones, such as running each domain as a stock
  node on a Linux-compatible layer. It answers most questions of the form
  "why not the familiar way?"
* **What is not yet decided** is in **Open decisions** or **Risks and
  open questions**, each with the options and, where there is one, a
  recommendation. design.md's
  [Tensions](../design.md#tensions) names the trade-offs the
  architecture accepts knowingly.
* **Simpler designs proposed and not adopted** wait in
  [todo-simplification.md](../todo-simplification.md) with their
  evidence. When one is adopted, it moves into its design document and
  leaves that file.
* **Defects and known gaps** are items of [TODO.md](../../TODO.md),
  each with a severity and a component.
* **Evidence** is in the dated research records that decisions cite.

When a decision changes, its text is edited in place. git holds the history,
and commit messages say what changed and why, so a design document
never says "now", "previously" or "as of": if it
does, that is a defect.

## B.6 From the book to the documents

Table B.2 gathers the design documents that each chapter's "Where to
read next" names.

| Chapter | Leads into |
| --- | --- |
| [1](01-operating-systems.md), [2](02-microkernels.md) | overview.md; design-fiasco.md; research-kernel-bases.md for the kernels compared |
| [3](03-erlang.md) | design-runtime.md; research-erts-internals.md |
| [4](04-history.md) | design.md (Context, Requirements, Decisions); design-fiasco.md; research-hierarchical-scheduling.md; research-prior-art.md |
| [5](05-overview.md) | overview.md; design.md; design-fiasco.md; design-domains.md; design-system.md |
| [6](06-construction.md) | design.md (Correct by construction in code); design-fiasco.md (Contract); design-device-dma.md; style.md |
| [7](07-one-source.md) | design-generation.md; design-abi.md; design-system.md (the manifest); design-device-dma.md; design-verification.md |
| [8](08-kernel-interface.md) | design-fiasco.md; design-runtime.md |
| [9](09-processes.md) | design-scheduler.md; design-fiasco.md (the scheduler on Fiasco); design-runtime.md; research-hierarchical-scheduling.md |
| [10](10-domains.md) | design-domains.md; design-runtime.md; design-system.md |
| [11](11-security.md) | design.md (Security); design-fiasco.md (security on Fiasco, rights); design-domains.md; design-files.md; design-time.md (who may set it); design-system.md (the vault); design-live.md (escape rules) |
| [12](12-memory.md) | design-fiasco.md (memory and budgets); design-system.md |
| [13](13-native-programs.md) | design-programs.md; design-pipes.md; design-shell.md; design-fiasco.md (vCPU upcalls on Fiasco) |
| [14](14-files.md) | design-files.md; design-tmp.md; design-app-trees.md; design-live.md (`/proc`) |
| [15](15-devices.md) | design-system.md (devices and drivers); design-runtime.md (the device NIF); design-device-dma.md; design-device-tree.md; design-shared-devices.md; design-pcie.md; design-usb.md; design-header-io.md; design-board-sensors.md |
| [16](16-storage.md) | design-storage.md; design-stopgap.md; design-drives.md; design-f2fs.md; design-platforms.md; design-fiasco.md (the end path) |
| [17](17-network.md) | design-network-stack.md; design-time.md |
| [18](18-wifi.md), [19](19-bluetooth.md) | design-wifi.md; design-bluetooth.md; design-shared-devices.md |
| [20](20-shell.md) | design-shell.md; design-vi.md; design-ssh.md; design-live.md (ttys); design-apps.md |
| [21](21-live-machine.md) | design-live.md; design-log.md; design-system.md (the crash record); design-fiasco.md (reporting kernel objects, the trace ring) |
| [22](22-display.md) | design-display.md; design-desktop-programs.md; design-find-act.md; design-web.md |
| [23](23-apps.md) | design-apps.md; design-packaging.md; design-app-trees.md; design-storage.md |
| [24](24-startup.md) | design-system.md; design-fiasco.md; design-kernel.md (boot); design-abi.md; design-platforms.md |
| [25](25-checking.md) | design-verification.md; design-host-oracle.md; design-build.md; design-bench.md; design-network-stack.md (its tests) |

*Table B.2. Which chapter prepares a reader for which documents, from
each chapter's "Where to read next" and the outline of chapters 24
and 25.*

design-arch-aarch64.md has no chapter: it binds design-kernel.md's
form of the interface to AArch64's registers and instructions, and is
for a reader of that document. Building and booting the
system is the subject of
[Appendix C](c-building.md), and
design.md's dependency table, with every component's license, of
[Appendix D](d-dependencies.md).

## Summary

The design documents are contracts, one per subsystem. They describe the complete design in
the present tense, so whether a thing is built is found in README's
Current status, the tree and TODO.md, not in their tense. Where a
document describes kernel properties, design-fiasco.md says what the
system's kernel, Fiasco, gives. A newcomer reads overview.md, part of
design.md and five core documents before the subsystem of interest. Most documents share one layout, and Context,
Invariants, Failure and Verification together give a document's
promise. Every decision has one home: design.md's Decisions for those
spanning subsystems, the shaping document for the rest, Alternatives
considered for what lost, Open decisions for what is not settled.
